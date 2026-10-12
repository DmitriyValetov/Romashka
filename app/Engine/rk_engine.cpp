// rk_engine.cpp — движок обхода дерева каталогов для «Ромашки».
//
// Основа — проверенный прототип bench/fastscan.cpp: обход через getattrlistbulk(2)
// (атрибуты каталога читаются пачкой, а не stat'ом на каждый файл), пул потоков,
// дедупликация жёстких ссылок, два размера (занято на диске и логический).
//
// Три вещи, на которых легко ошибиться и которые здесь закрыты (ловились инвариантом
// дерева в прототипе):
//   1) узел, который не удалось открыть, обязан быть закрыт в дереве — иначе не сходятся
//      суммы у всех его предков;
//   2) узел отдаёт размер родителю только когда закрыты все его потомки (closeNode);
//   3) «size += own» — это load/add/store и теряет параллельный вклад ребёнка; нужен
//      атомарный fetch_add.

#include "rk_engine.h"

#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <deque>
#include <mutex>
#include <atomic>
#include <thread>
#include <condition_variable>
#include <unordered_set>
#include <algorithm>
#include <chrono>

static const uint32_t NODE_CAP = 4u << 20;      // до 4 млн каталогов
static const size_t   BUFSZ    = 128 * 1024;    // буфер getattrlistbulk на уровень рекурсии
static const size_t   QCAP     = 512;           // предел открытых fd в очереди

struct BufPool {                                 // своя память на каждый уровень рекурсии
    std::vector<char *> v;
    ~BufPool() { for (char *p : v) free(p); }
    char *get(size_t depth) {
        while (v.size() <= depth) v.push_back((char *)malloc(BUFSZ));
        return v[depth];
    }
};

struct rk_bigfile {
    uint64_t size;
    int64_t  mtime;
    std::string name;
    uint32_t node;
};

struct rk_scan {
    // конфигурация
    std::string root;
    std::vector<std::string> exclusions;
    int jobs = 4;
    uint64_t bigMin = 200ull * 1024 * 1024;

    // арена узлов (calloc: страницы не трогаются, пока не понадобятся)
    rk_node *nodes = nullptr;
    uint32_t *pending = nullptr;
    std::atomic<uint32_t> nnodes{0};
    std::vector<char> names;
    std::mutex treeMu;                            // защищает структуру узлов и буфер имён

    // очередь задач
    struct Task { int fd; uint32_t node; };
    std::deque<Task> q;
    std::mutex qmu;
    std::condition_variable qcv;
    std::atomic<int> pendingTasks{0};
    std::atomic<bool> cancelFlag{false};

    // счётчики
    std::atomic<uint64_t> nfiles{0}, ndirs{0}, nerr{0}, totalAlloc{0}, totalLogical{0}, nlinks{0};
    std::mutex hlMu;
    std::unordered_set<uint64_t> hardlinks;
    std::mutex bigMu;
    std::vector<rk_bigfile> bigs;

    // жизненный цикл
    std::vector<std::thread> threads;
    std::atomic<int> workersLeft{0};
    std::atomic<bool> started{false};
    std::atomic<double> elapsed{0};
    std::chrono::steady_clock::time_point t0;
    std::string error;
    std::vector<uint32_t> remap;                  // черновик перепривязки индексов для снимков

    // ---- построение дерева
    uint32_t addNode(uint32_t parent, const char *name, size_t len, uint32_t depth) {
        uint32_t i = nnodes.fetch_add(1, std::memory_order_relaxed);
        if (i >= NODE_CAP) { nnodes.fetch_sub(1, std::memory_order_relaxed); return UINT32_MAX; }
        std::lock_guard<std::mutex> lk(treeMu);
        rk_node &n = nodes[i];
        n.parent = parent;
        n.depth = depth;
        n.denied = 0;
        n.flags = 0;
        n.size = n.logical = n.own = 0;
        n.nameOff = (uint32_t)names.size();
        n.nameLen = (uint32_t)len;
        names.insert(names.end(), name, name + len);
        pending[i] = 1;                                   // своё сканирование
        if (parent != UINT32_MAX) __atomic_fetch_add(&pending[parent], 1u, __ATOMIC_RELAXED);
        return i;
    }

    void closeNode(uint32_t idx) {
        for (;;) {
            if (__atomic_fetch_sub(&pending[idx], 1u, __ATOMIC_ACQ_REL) != 1) return;
            uint32_t p = nodes[idx].parent;
            if (p == UINT32_MAX) return;
            __atomic_fetch_add(&nodes[p].size,
                               __atomic_load_n(&nodes[idx].size, __ATOMIC_RELAXED), __ATOMIC_RELAXED);
            __atomic_fetch_add(&nodes[p].logical,
                               __atomic_load_n(&nodes[idx].logical, __ATOMIC_RELAXED), __ATOMIC_RELAXED);
            idx = p;
        }
    }

    std::string pathOf(uint32_t i) const {                 // только под treeMu
        std::vector<uint32_t> chain;
        while (i != UINT32_MAX && chain.size() < 256) { chain.push_back(i); i = nodes[i].parent; }
        std::string s;
        for (auto it = chain.rbegin(); it != chain.rend(); ++it) {
            const rk_node &n = nodes[*it];
            if (n.nameLen && (uint64_t)n.nameOff + n.nameLen <= names.size()) {
                if (!s.empty() && s.back() != '/') s.push_back('/');
                s.append(names.data() + n.nameOff, n.nameLen);
            }
        }
        return s;
    }

    bool excluded(uint32_t parentIdx, const char *name, uint32_t childDepth) {
        if (exclusions.empty() || childDepth > 3) return false;
        std::lock_guard<std::mutex> lk(treeMu);      // pathOf читает арену имён
        std::string p = pathOf(parentIdx);
        if (p.empty() || p.back() != '/') p.push_back('/');
        p += name;
        for (const auto &e : exclusions)
            if (p == e || (p.size() > e.size() && p.compare(0, e.size(), e) == 0 && p[e.size()] == '/'))
                return true;
        return false;
    }

    static bool parseRecord(char *p, char *end, const char *&name, uint32_t &objtype,
                            uint64_t &fileid, uint32_t &nlink, uint64_t &logical, uint64_t &alloc) {
        if (p + 4 > end) return false;
        uint32_t reclen; memcpy(&reclen, p, 4);
        if (reclen < 4 || p + reclen > end) return false;
        char *rp = p + 4;
        attribute_set_t ret; memcpy(&ret, rp, sizeof ret); rp += sizeof ret;
        const char *recEnd = p + reclen;
        name = nullptr;
        if (ret.commonattr & ATTR_CMN_NAME) {
            attrreference_t ar; memcpy(&ar, rp, sizeof ar);
            name = rp + ar.attr_dataoffset;          // смещение от самой структуры; имя — в хвосте записи
            rp += sizeof ar;
        }
        if (ret.commonattr & ATTR_CMN_OBJTYPE) { memcpy(&objtype, rp, 4); rp += 4; }
        if (ret.commonattr & ATTR_CMN_FILEID)  { memcpy(&fileid, rp, 8); rp += 8; }
        if (ret.fileattr & ATTR_FILE_LINKCOUNT) { memcpy(&nlink, rp, 4); rp += 4; }
        if (ret.fileattr & ATTR_FILE_TOTALSIZE) { memcpy(&logical, rp, 8); rp += 8; }
        if (ret.fileattr & ATTR_FILE_ALLOCSIZE) { memcpy(&alloc, rp, 8); rp += 8; }
        if (rp > recEnd) return false;
        if (name && (name < p || name >= recEnd)) return false;
        return true;
    }

    void pushOrRecurse(int dirfd, uint32_t node, uint32_t depth) {
        bool push;
        { std::lock_guard<std::mutex> lk(qmu); push = q.size() < QCAP; }
        if (push) {
            pendingTasks.fetch_add(1, std::memory_order_relaxed);
            { std::lock_guard<std::mutex> lk(qmu); q.push_back({dirfd, node}); }
            qcv.notify_one();
        } else {
            scanDir(dirfd, node, depth);              // очередь полна — идём вглубь сами
            ::close(dirfd);
        }
    }

    void scanDir(int fd, uint32_t nodeIdx, uint32_t depth) {
        struct attrlist al;
        memset(&al, 0, sizeof al);
        al.bitmapcount = ATTR_BIT_MAP_COUNT;
        al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID;
        al.fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE;

        struct stat dst;
        bool haveDst = (fstat(fd, &dst) == 0);
        if (haveDst && nodeIdx != UINT32_MAX)
            __atomic_fetch_add(&nodes[nodeIdx].size, (uint64_t)dst.st_blocks * 512, __ATOMIC_RELAXED);

        thread_local BufPool pool;
        char *buf = pool.get(depth);
        uint64_t own = 0, ownLogical = 0;

        for (;;) {
            if (cancelFlag.load(std::memory_order_relaxed)) break;
            int n = getattrlistbulk(fd, &al, buf, BUFSZ, 0);
            if (n < 0) { if (errno != ENOENT) nerr.fetch_add(1); break; }
            if (n == 0) break;
            char *p = buf, *end = buf + BUFSZ;
            for (int i = 0; i < n; i++) {
                if (p + 4 > end) break;
                uint32_t reclen; memcpy(&reclen, p, 4);
                if (reclen < 4 || p + reclen > end) break;      // разбор уехал — дальше не идём
                const char *name = nullptr;
                uint32_t objtype = 0, nlink = 1;
                uint64_t fileid = 0, logical = 0, alloc = 0;
                if (!parseRecord(p, end, name, objtype, fileid, nlink, logical, alloc) || !name || !*name) {
                    nerr.fetch_add(1);
                    p += reclen;
                    continue;
                }
                if (objtype == 2 /*VDIR*/) {
                    if (excluded(nodeIdx, name, depth + 1)) { p += reclen; continue; }
                    uint32_t idx = addNode(nodeIdx, name, strlen(name), depth + 1);
                    ndirs.fetch_add(1);
                    if (idx == UINT32_MAX) { p += reclen; continue; }
                    int cfd = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                    if (cfd < 0) {
                        nerr.fetch_add(1);
                        nodes[idx].denied = (errno == EACCES || errno == EPERM) ? 1 : 2;
                        closeNode(idx);                          // узел создан — обязан закрыться
                        p += reclen;
                        continue;
                    }
                    struct stat cs;
                    if (haveDst && fstat(cfd, &cs) == 0 && cs.st_dev != dst.st_dev) {
                        ::close(cfd);
                        nodes[idx].denied = 3;                   // другой том — не считаем
                        closeNode(idx);
                        p += reclen;
                        continue;
                    }
                    pushOrRecurse(cfd, idx, depth + 1);
                } else if (objtype == 1 /*VREG*/) {
                    nfiles.fetch_add(1);
                    if (nlink > 1) {
                        std::lock_guard<std::mutex> lk(hlMu);
                        if (!hardlinks.insert(fileid).second) { p += reclen; continue; }
                        nlinks.fetch_add(1);
                    }
                    own += alloc; ownLogical += logical;
                    if (alloc >= bigMin) {
                        struct stat fs;
                        int64_t mt = (fstatat(fd, name, &fs, AT_SYMLINK_NOFOLLOW) == 0) ? (int64_t)fs.st_mtime : 0;
                        std::lock_guard<std::mutex> lk(bigMu);
                        bigs.push_back({alloc, mt, std::string(name), nodeIdx});
                    }
                }
                p += reclen;
            }
        }
        nodes[nodeIdx].own = own;
        __atomic_fetch_add(&nodes[nodeIdx].size, own, __ATOMIC_RELAXED);
        __atomic_fetch_add(&nodes[nodeIdx].logical, ownLogical, __ATOMIC_RELAXED);
        totalAlloc.fetch_add(own);
        totalLogical.fetch_add(ownLogical);
        closeNode(nodeIdx);
    }

    void worker() {
        for (;;) {
            Task t;
            {
                std::unique_lock<std::mutex> lk(qmu);
                qcv.wait(lk, [this] { return !q.empty() || pendingTasks.load() == 0; });
                if (q.empty()) break;
                t = q.back(); q.pop_back();
            }
            if (cancelFlag.load(std::memory_order_relaxed)) closeNode(t.node);   // сбрасываем счётчик узла
            else scanDir(t.fd, t.node, nodes[t.node].depth);
            ::close(t.fd);
            if (pendingTasks.fetch_sub(1) == 1) { std::lock_guard<std::mutex> lk(qmu); qcv.notify_all(); }
        }
    }
};

extern "C" {

rk_scan *rk_new(const char *root, int jobs, uint64_t bigfile_min,
                const char *const *exclusions, int n_exclusions) {
    rk_scan *s = new rk_scan();
    s->root = root ? root : "";
    s->jobs = jobs > 0 ? jobs : 4;
    s->bigMin = bigfile_min;
    for (int i = 0; i < n_exclusions; i++) if (exclusions[i]) s->exclusions.push_back(exclusions[i]);
    s->nodes = (rk_node *)calloc(NODE_CAP, sizeof(rk_node));
    s->pending = (uint32_t *)calloc(NODE_CAP, sizeof(uint32_t));
    s->names.reserve(64u << 20);
    s->remap.assign(1u << 16, UINT32_MAX);
    if (!s->nodes || !s->pending) { s->error = "не хватило памяти под арену узлов"; }
    return s;
}

void rk_free(rk_scan *s) {
    if (!s) return;
    rk_cancel(s);
    rk_wait(s);
    free(s->nodes);
    free(s->pending);
    delete s;
}

void rk_start(rk_scan *s) {
    if (!s || s->started.exchange(true)) return;
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0) { rl.rlim_cur = rl.rlim_max; setrlimit(RLIMIT_NOFILE, &rl); }

    int fd = ::open(s->root.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) {
        s->error = std::string("не удалось открыть ") + s->root + ": " + strerror(errno);
        s->started = false;
        s->workersLeft.store(0);
        return;
    }
    s->t0 = std::chrono::steady_clock::now();
    uint32_t idx = s->addNode(UINT32_MAX, s->root.c_str(), s->root.size(), 0);
    s->ndirs.fetch_add(1);
    s->pendingTasks.fetch_add(1, std::memory_order_relaxed);
    s->q.push_back({fd, idx});

    s->workersLeft.store(s->jobs);
    for (int i = 0; i < s->jobs; i++) {
        s->threads.emplace_back([s] {
            s->worker();
            s->workersLeft.fetch_sub(1);
        });
    }
}

void rk_cancel(rk_scan *s) { if (s) s->cancelFlag.store(true); }

bool rk_running(rk_scan *s) { return s && s->started.load() && s->workersLeft.load() > 0; }

void rk_wait(rk_scan *s) {
    if (!s) return;
    for (auto &t : s->threads) if (t.joinable()) t.join();
    s->threads.clear();
    if (s->t0.time_since_epoch().count())
        s->elapsed.store(std::chrono::duration<double>(std::chrono::steady_clock::now() - s->t0).count());
}

void rk_progress_get(rk_scan *s, rk_progress *out) {
    if (!s || !out) return;
    out->files = s->nfiles.load();
    out->dirs = s->ndirs.load();
    out->alloc = s->totalAlloc.load();
    out->logical = s->totalLogical.load();
    out->errors = s->nerr.load();
    out->hardlinks = s->nlinks.load();
    out->running = rk_running(s);
    out->cancelled = s->cancelFlag.load();
    // Приложение не зовёт rk_wait (оно не должно блокироваться), поэтому время считаем от t0,
    // если обход уже завершился, а rk_wait так и не вызвали.
    double elapsed = s->elapsed.load();
    if (s->t0.time_since_epoch().count()) {
        double live = std::chrono::duration<double>(std::chrono::steady_clock::now() - s->t0).count();
        if (rk_running(s) || elapsed <= 0) elapsed = live;
    }
    out->elapsed = elapsed;
}

uint64_t rk_node_count(rk_scan *s) { return s ? s->nnodes.load() : 0; }
uint64_t rk_names_length(rk_scan *s) { std::lock_guard<std::mutex> lk(s->treeMu); return s->names.size(); }
uint32_t rk_root_index(rk_scan *s) { (void)s; return 0; }

uint64_t rk_snapshot(rk_scan *s, rk_node *out, uint32_t *orig, char *outNames,
                     uint64_t node_cap, uint64_t names_cap, uint64_t min_size) {
    if (!s || !out) return 0;
    std::lock_guard<std::mutex> lk(s->treeMu);
    uint32_t n = s->nnodes.load();
    if (n > NODE_CAP) n = NODE_CAP;
    if (s->remap.size() < n) s->remap.assign(n + (1u << 16), UINT32_MAX);
    else std::fill(s->remap.begin(), s->remap.begin() + n, UINT32_MAX);

    uint64_t written = 0, nlen = 0;
    bool wantRoot = true;
    for (uint32_t i = 0; i < n; i++) {
        const rk_node &src = s->nodes[i];
        bool isRoot = (src.parent == UINT32_MAX);
        if (isRoot && !wantRoot) { s->remap[i] = 0; continue; }
        if (!isRoot && (src.nameLen == 0 || src.size < min_size)) continue;   // пустой = узел ещё не заполнен
        if (written >= node_cap) break;
        rk_node &d = out[written];
        d = src;
        bool fits = (nlen + src.nameLen) <= names_cap;
        if (fits) {
            memcpy(outNames + nlen, s->names.data() + src.nameOff, src.nameLen);
            d.nameOff = (uint32_t)nlen;
            d.nameLen = src.nameLen;
            nlen += src.nameLen;
        } else {
            d.nameOff = 0;
            d.nameLen = 0;
        }
        if (orig) orig[written] = i;
        s->remap[i] = (uint32_t)written;
        if (isRoot) wantRoot = false;
        written++;
    }
    // перепривязка родителей к новым индексам (родитель мог не попасть в снимок)
    for (uint64_t k = 0; k < written; k++) {
        uint32_t p = out[k].parent;
        if (p == UINT32_MAX) continue;
        uint32_t mapped = UINT32_MAX;
        while (p != UINT32_MAX && p < n) {
            if (s->remap[p] != UINT32_MAX) { mapped = s->remap[p]; break; }
            p = s->nodes[p].parent;
        }
        out[k].parent = (mapped == UINT32_MAX) ? 0 : mapped;
    }
    return written;
}

char *rk_bigfiles_text(rk_scan *s, uint64_t *len_out) {
    if (len_out) *len_out = 0;
    if (!s) return nullptr;
    std::vector<rk_bigfile> copy;
    { std::lock_guard<std::mutex> lk(s->bigMu); copy = s->bigs; }
    std::sort(copy.begin(), copy.end(),
              [](const rk_bigfile &a, const rk_bigfile &b) { return a.size > b.size; });
    std::string buf;
    buf.reserve(copy.size() * 96 + 64);
    {
        std::lock_guard<std::mutex> lk(s->treeMu);
        char line[64];
        for (const auto &b : copy) {
            std::string dir = s->pathOf(b.node);
            buf += std::to_string(b.size);
            buf += '\t';
            buf += std::to_string(b.mtime);
            buf += '\t';
            buf += dir;
            if (!dir.empty() && dir.back() != '/') buf += '/';
            buf += b.name;
            buf += '\n';
        }
        (void)line;
    }
    char *out = (char *)malloc(buf.size() + 1);
    if (!out) return nullptr;
    memcpy(out, buf.data(), buf.size());
    out[buf.size()] = 0;
    if (len_out) *len_out = buf.size();
    return out;
}

void rk_free_text(char *p) { free(p); }

uint64_t rk_verify(rk_scan *s, char *first_bad_path, uint64_t cap) {
    if (!s) return 0;
    std::lock_guard<std::mutex> lk(s->treeMu);
    uint32_t n = s->nnodes.load();
    if (n > NODE_CAP) n = NODE_CAP;
    std::vector<uint64_t> kids(n, 0);
    for (uint32_t i = 0; i < n; i++) {
        uint32_t p = s->nodes[i].parent;
        if (p != UINT32_MAX && p < n) kids[p] += s->nodes[i].size;
    }
    uint64_t bad = 0;
    for (uint32_t i = 0; i < n; i++) {
        uint64_t expect = s->nodes[i].own + kids[i];
        uint64_t got = s->nodes[i].size;
        if (expect != got) {
            if (bad == 0 && first_bad_path && cap) {
                std::string p = s->pathOf(i);
                snprintf(first_bad_path, cap, "%s own=%" PRIu64 " kids=%" PRIu64 " size=%" PRIu64,
                         p.c_str(), s->nodes[i].own, kids[i], got);
            }
            bad++;
        }
    }
    return bad;
}

const char *rk_root(rk_scan *s) { return s ? s->root.c_str() : ""; }
const char *rk_error(rk_scan *s) {
    if (!s || s->error.empty()) return nullptr;
    return s->error.c_str();
}

}  // extern "C"
