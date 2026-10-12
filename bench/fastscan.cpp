// fastscan — прототип движка сканирования для приложения «Ромашка».
// Обход дерева каталогов через getattrlistbulk(2) + пул потоков.
// Задача: измерить реальную скорость обхода и получить дерево размеров.
//
// usage: fastscan [-j N] [-m MIN_MB] [--json FILE] ROOT
#include <sys/attr.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cinttypes>
#include <cstdint>
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
#include <memory>

static std::atomic<int> g_firstErr{0};
static const uint32_t NODE_CAP = 1u << 22;      // до 4M каталогов
static const size_t   BUFSZ    = 128 * 1024;

struct BufPool {                      // буфер на каждый уровень рекурсии: walk родителя не затирается
    std::vector<std::unique_ptr<char[]>> v;
    char *get(size_t depth) {
        while (v.size() <= depth) v.emplace_back(new char[BUFSZ]);
        return v[depth].get();
    }
};
static const size_t   QCAP     = 512;           // предел одновременно открытых fd в очереди

struct Node {
    uint32_t parent;      // UINT32_MAX для корня
    uint32_t nameOff;
    uint32_t nameLen;
    uint32_t depth;
    uint32_t denied;      // каталог есть, но открыть не дали (TCC/права) — в дереве помечается отдельно
    uint64_t size;        // allocated bytes: свои файлы + поддерево (валидно после закрытия узла)
    uint64_t logical;
    uint64_t own;                    // файлы непосредственно в этом каталоге (пишет только свой поток)
    std::atomic<uint32_t> pending;   // 1 (своё сканирование) + число созданных подкаталогов
};
static_assert(sizeof(Node) == 56, "Node layout");

struct AttrBuf {                       // разбор одной записи getattrlistbulk
    const char *name = nullptr;
    uint32_t objtype = 0;
    uint64_t fileid = 0;
    uint64_t logical = 0;
    uint64_t alloc = 0;
    uint32_t nlink = 1;
    bool ok = true;
};

class Scanner {
public:
    explicit Scanner(int jobs, uint32_t minDepth) : njobs_(jobs), minDepth_(minDepth) {
        nodes_.reset(new Node[NODE_CAP]);
        memset(nodes_.get(), 0, sizeof(Node) * NODE_CAP);
        names_.reserve(1 << 22);
    }

    struct Task { int fd; uint32_t node; };
    std::deque<Task> q;
    std::mutex qmu;
    std::condition_variable qcv;
    std::atomic<int> pending{0};

    void run(const std::vector<std::string> &roots) {
        t0_ = std::chrono::steady_clock::now();
        for (const auto &r : roots) {
            int fd = ::open(r.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
            if (fd < 0) { nerr_.fetch_add(1); fprintf(stderr, "open %s: %s\n", r.c_str(), strerror(errno)); continue; }
            uint32_t idx = addNode(UINT32_MAX, r.c_str(), strlen(r.c_str()), 0);
            ndirs_.fetch_add(1);
            pending.fetch_add(1);
            q.push_back({fd, idx});
        }
        std::vector<std::thread> th;
        for (int i = 0; i < njobs_; i++) th.emplace_back([this]{ worker(); });
        for (auto &t : th) t.join();
        elapsed_ = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0_).count();
        std::sort(bigFiles_.begin(), bigFiles_.end(),
                  [](const auto &a, const auto &b){ return a.first > b.first; });
    }

    // ---- результаты
    double elapsed() const { return elapsed_; }
    uint64_t nfiles() const { return nfiles_.load(); }
    uint64_t ndirs() const { return ndirs_.load(); }
    uint64_t nerr() const { return nerr_.load(); }
    uint64_t totalAlloc() const { return totalAlloc_.load(); }
    uint64_t totalLogical() const { return totalLogical_.load(); }
    uint64_t nlinks() const { return nlinks_.load(); }
    uint32_t nodeCount() const { return nnodes_.load(); }
    const Node *nodes() const { return nodes_.get(); }
    const std::vector<std::pair<uint64_t, std::string>> &bigFiles() const { return bigFiles_; }
    uint64_t bigMin() const { return bigMin_; }
    std::string pathOf(uint32_t i) const {
        std::string s;
        std::vector<uint32_t> chain;
        while (i != UINT32_MAX) { chain.push_back(i); i = nodes_[i].parent; }
        for (auto it = chain.rbegin(); it != chain.rend(); ++it) {
            if (!s.empty() && s.back() != '/') s.push_back('/');
            s.append(names_.data() + nodes_[*it].nameOff, nodes_[*it].nameLen);
        }
        return s;
    }

private:
    int njobs_;
    uint32_t minDepth_;
    std::unique_ptr<Node[]> nodes_;
    std::atomic<uint32_t> nnodes_{0};
    std::vector<char> names_;
    std::mutex nameMu_;
    std::atomic<uint64_t> nfiles_{0}, ndirs_{0}, nerr_{0}, totalAlloc_{0}, totalLogical_{0}, nlinks_{0};
    std::mutex bigMu_;
    std::vector<std::pair<uint64_t, std::string>> bigFiles_;   // (размер, каталог) для файлов >= порога
    std::mutex hlMu_;
    std::unordered_set<uint64_t> hardlinks_;
    double elapsed_ = 0;
    uint64_t bigMin_ = 200ull * 1024 * 1024;
    std::chrono::steady_clock::time_point t0_;

    uint32_t addNode(uint32_t parent, const char *name, size_t len, uint32_t depth) {
        uint32_t i = nnodes_.fetch_add(1);
        if (i >= NODE_CAP) { nnodes_.fetch_sub(1); return UINT32_MAX; }
        Node &n = nodes_[i];
        n.parent = parent; n.depth = depth;
        n.pending.store(1);
        if (parent != UINT32_MAX) nodes_[parent].pending.fetch_add(1);   // ребёнок зарегистрирован до старта
        std::lock_guard<std::mutex> lk(nameMu_);
        n.nameOff = (uint32_t)names_.size(); n.nameLen = (uint32_t)len;
        names_.insert(names_.end(), name, name + len);
        return i;
    }

    static bool parseRecord(char *p, char *end, AttrBuf &out) {
        if (p + 4 > end) return false;
        uint32_t reclen; memcpy(&reclen, p, 4);
        if (reclen < 4 || p + reclen > end) { if (getenv("FS_DEBUG")) fprintf(stderr,"[dbg] bad reclen=%u\n", reclen); return false; }
        char *rp = p + 4;
        attribute_set_t ret; memcpy(&ret, rp, sizeof ret); rp += sizeof ret;
        const char *recEnd = p + reclen;
        if (ret.commonattr & ATTR_CMN_NAME) {
            attrreference_t ar; memcpy(&ar, rp, sizeof ar);
            out.name = rp + ar.attr_dataoffset;      // offset считается от самой структуры
            rp += sizeof ar;
        }
        if (ret.commonattr & ATTR_CMN_OBJTYPE) { memcpy(&out.objtype, rp, 4); rp += 4; }
        if (ret.commonattr & ATTR_CMN_FILEID)  { memcpy(&out.fileid, rp, 8); rp += 8; }
        if (ret.fileattr & ATTR_FILE_LINKCOUNT) { memcpy(&out.nlink, rp, 4); rp += 4; }
        if (ret.fileattr & ATTR_FILE_TOTALSIZE) { memcpy(&out.logical, rp, 8); rp += 8; }
        if (ret.fileattr & ATTR_FILE_ALLOCSIZE) { memcpy(&out.alloc, rp, 8); rp += 8; }
        if (rp > recEnd) { out.ok = false; if (getenv("FS_DEBUG")) fprintf(stderr,"[dbg] rp>recEnd rp=%td recEnd=%td\n", rp-p, recEnd-p); return false; }
        if (out.name && (out.name < p || out.name >= recEnd)) {
            out.ok = false;
            if (getenv("FS_DEBUG")) fprintf(stderr, "[dbg] badname reclen=%u nameOff=%td common=0x%08x file=0x%08x\n",
                                             reclen, out.name-p, ret.commonattr, ret.fileattr);
            return false;
        }
        return true;                                                         // имя лежит в хвосте записи
    }

    void pushOrRecurse(int dirfd, uint32_t node, uint32_t depth, bool &queued) {
        bool push;
        { std::lock_guard<std::mutex> lk(qmu); push = q.size() < QCAP; }
        if (push) {
            pending.fetch_add(1);
            { std::lock_guard<std::mutex> lk(qmu); q.push_back({dirfd, node}); }
            qcv.notify_one();
            queued = true;
        } else {
            scanDir(dirfd, node, depth);          // очередь полна — идём вглубь сами
            ::close(dirfd);
            queued = false;
        }
    }

    void dumpBuf(const char *why, char *buf, int n, int i, size_t bufsz) {
        fprintf(stderr, "[dbg] %s dir=%s n=%d badIndex=%d bufws=%zu\n", why,
                nodeIdx_ ? pathOf(nodeIdx_).c_str() : "?", n, i, bufsz);
        char *q = buf; int lim = n < 4 ? n : 4;
        for (int k = 0; k < lim; k++) {
            unsigned rl; memcpy(&rl, q, 4);
            fprintf(stderr, "   rec%d reclen=%u raw=", k, rl);
            for (unsigned j = 0; j < rl && j < 72 && q + j < buf + bufsz; j++) fprintf(stderr, "%02x", (unsigned char)q[j]);
            fprintf(stderr, "\n");
            if (rl < 4) break;
            q += rl;
        }
    }
    uint32_t nodeIdx_ = 0;

    void scanDir(int fd, uint32_t nodeIdx, uint32_t depth) {
        nodeIdx_ = nodeIdx;
        struct attrlist al;
        memset(&al, 0, sizeof al);
        al.bitmapcount = ATTR_BIT_MAP_COUNT;
        al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID;
        al.fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE;

        struct stat dst;
        if (fstat(fd, &dst) == 0 && nodeIdx != UINT32_MAX)
            __atomic_fetch_add(&nodes_[nodeIdx].size, (uint64_t)dst.st_blocks * 512, __ATOMIC_RELAXED);

        thread_local BufPool pool;
        char *buf = pool.get(depth);
        uint64_t own = 0, ownLogical = 0;

        for (;;) {
            int n = getattrlistbulk(fd, &al, buf, BUFSZ, 0);
            if (n < 0) {
                if (errno != ENOENT) nerr_.fetch_add(1);
                break;
            }
            if (n == 0) break;
            char *p = buf, *end = buf + BUFSZ;
            ssize_t consumed = 0;
            for (int i = 0; i < n; i++) {
                AttrBuf a;
                uint32_t reclen; memcpy(&reclen, p, 4);
                if (p + 4 > end || reclen < 4 || p + reclen > end) {
                    if (getenv("FS_DEBUG") && g_firstErr.fetch_add(1) < 3) dumpBuf("drift", buf, n, i, BUFSZ);
                    break;
                }
                consumed += reclen;
                if (!parseRecord(p, end, a) || a.name == nullptr) {
                    if (getenv("FS_DEBUG") && nerr_.load() < 3) fprintf(stderr,"[dbg] rec fail i=%d reclen=%u name=%p\n", i, reclen, (void*)a.name);
                    nerr_.fetch_add(1);
                    p += reclen ? reclen : 4;
                    continue;
                }
                if (a.objtype == 2 /*VDIR*/) {
                    uint32_t idx = addNode(nodeIdx, a.name, strlen(a.name), depth + 1);
                    ndirs_.fetch_add(1);
                    if (idx == UINT32_MAX) { p += reclen; continue; }
                    int cfd = openat(fd, a.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                    if (cfd < 0) {                      // узел уже создан — его обязательно надо закрыть
                        nerr_.fetch_add(1);
                        nodes_[idx].denied = (errno == EACCES || errno == EPERM) ? 1 : 2;
                        closeNode(idx);
                        p += reclen; continue;
                    }
                    struct stat cs;
                    if (fstat(cfd, &cs) == 0 && cs.st_dev != dst.st_dev) {   // не уходим на другой том
                        ::close(cfd);
                        nodes_[idx].denied = 3;               // другой том — не считаем
                        closeNode(idx);
                        p += reclen; continue;
                    }
                    bool queued = false;
                    pushOrRecurse(cfd, idx, depth + 1, queued);
                    (void)queued;
                } else if (a.objtype == 1 /*VREG*/) {
                    nfiles_.fetch_add(1);
                    if (a.nlink > 1) {
                        std::lock_guard<std::mutex> lk(hlMu_);
                        if (!hardlinks_.insert(a.fileid).second) { p += reclen; continue; }
                        nlinks_.fetch_add(1);
                    }
                    own += a.alloc; ownLogical += a.logical;
                    if (a.alloc >= bigMin_) {
                        std::lock_guard<std::mutex> lk(bigMu_);
                        bigFiles_.emplace_back(a.alloc, std::string(a.name) + "\x1f" + std::to_string(nodeIdx));
                    }
                }
                p += reclen;
            }
        }
        nodes_[nodeIdx].own = own;
        // именно atomic fetch_add: «size += own» это load/add/store и теряет
        // вклад ребёнка, пришедший в это окно (ловится инвариантом дерева)
        __atomic_fetch_add(&nodes_[nodeIdx].size, own, __ATOMIC_RELAXED);
        __atomic_fetch_add(&nodes_[nodeIdx].logical, ownLogical, __ATOMIC_RELAXED);
        totalAlloc_.fetch_add(own);
        totalLogical_.fetch_add(ownLogical);
        closeNode(nodeIdx);          // размер уходит наверх только когда закрыты все потомки
    }

    // Узел закрыт, когда завершено своё сканирование и закрыты все его подкаталоги.
    // Закрываясь, узел отдаёт финальный размер родителю и уменьшает его счётчик.
    void closeNode(uint32_t idx) {
        for (;;) {
            if (nodes_[idx].pending.fetch_sub(1) != 1) return;      // у узла ещё есть незакрытые дети
            uint32_t p = nodes_[idx].parent;
            if (p == UINT32_MAX) return;
            __atomic_fetch_add(&nodes_[p].size, nodes_[idx].size, __ATOMIC_RELAXED);
            __atomic_fetch_add(&nodes_[p].logical, nodes_[idx].logical, __ATOMIC_RELAXED);
            idx = p;
        }
    }

    void worker() {
        for (;;) {
            Task t;
            {
                std::unique_lock<std::mutex> lk(qmu);
                qcv.wait(lk, [this]{ return !q.empty() || pending.load() == 0; });
                if (q.empty()) return;
                t = q.back(); q.pop_back();
            }
            scanDir(t.fd, t.node, nodes_[t.node].depth);
            ::close(t.fd);
            if (pending.fetch_sub(1) == 1) { std::lock_guard<std::mutex> lk(qmu); qcv.notify_all(); }
        }
    }
};

static std::string human(uint64_t b) {
    char out[64];
    const char *u[] = {"B", "KB", "MB", "GB", "TB"};
    double v = (double)b; int i = 0;
    while (v >= 1024 && i < 4) { v /= 1024; i++; }
    snprintf(out, sizeof out, "%.2f %s", v, u[i]);
    return out;
}
static std::string esc(const std::string &s) {
    std::string o; for (char c : s) { if (c == '"' || c == '\\') o += '\\'; o += c; } return o;
}

int main(int argc, char **argv) {
    int jobs = (int)std::thread::hardware_concurrency();
    int minMb = 200; const char *jsonPath = nullptr;
    std::vector<std::string> roots;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-j" && i + 1 < argc) jobs = atoi(argv[++i]);
        else if (a == "-m" && i + 1 < argc) minMb = atoi(argv[++i]);
        else if (a == "--json" && i + 1 < argc) jsonPath = argv[++i];
        else roots.push_back(a);
    }
    if (roots.empty()) { fprintf(stderr, "usage: fastscan [-j N] [-m MIN_MB] [--json FILE] ROOT...\n"); return 2; }

    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0) { rl.rlim_cur = rl.rlim_max; setrlimit(RLIMIT_NOFILE, &rl); }

    Scanner sc(jobs, 1);
    sc.run(roots);
    double el = sc.elapsed();
    uint64_t files = sc.nfiles(), dirs = sc.ndirs();
    printf("roots=%zu jobs=%d elapsed=%.2fs files=%" PRIu64 " dirs=%" PRIu64 " objects=%" PRIu64
           " rate=%.0f obj/s errors=%" PRIu64 " hardlinks_dedup=%" PRIu64 "\n",
           roots.size(), jobs, el, files, dirs, files + dirs, (files + dirs) / (el > 0 ? el : 1),
           sc.nerr(), sc.nlinks());
    printf("allocated=%s (%" PRIu64 " B) logical=%s (%" PRIu64 " B)\n",
           human(sc.totalAlloc()).c_str(), sc.totalAlloc(),
           human(sc.totalLogical()).c_str(), sc.totalLogical());

    const Node *nd = sc.nodes();
    // инвариант дерева: корень == своё + все потомки; сумма детей <= размер родителя
    uint64_t bad = 0; std::string firstBad;
    {
        std::vector<uint64_t> kids(sc.nodeCount(), 0);
        for (uint32_t i = 0; i < sc.nodeCount(); i++)
            if (nd[i].parent != UINT32_MAX && nd[i].parent < sc.nodeCount()) kids[nd[i].parent] += nd[i].size;
        for (uint32_t i = 0; i < sc.nodeCount(); i++) {
            uint64_t expect = nd[i].own + kids[i];
            uint64_t got = __atomic_load_n(&nd[i].size, __ATOMIC_RELAXED);
            if (expect != got) { if (!bad) firstBad = sc.pathOf(i) + " own=" + std::to_string(nd[i].own) + " kids=" + std::to_string(kids[i]) + " got=" + std::to_string(got); bad++; }
        }
    }
    printf("проверка инварианта size==own+sum(children): нарушений %llu из %u узлов%s%s\n",
           (unsigned long long)bad, sc.nodeCount(), bad ? " | первый: " : "", bad ? firstBad.c_str() : "");
    for (uint32_t i = 0; i < sc.nodeCount(); i++) {
        if (nd[i].depth != 0) continue;
        uint64_t kids = 0; uint32_t nkids = 0;
        for (uint32_t k = 0; k < sc.nodeCount(); k++)
            if (nd[k].parent == i) { kids += nd[k].size; nkids++; }
        printf("root=%s tree_alloc=%s own=%s pending=%u (%.2f%% от суммы файлов) children=%u sum_children=%s %s\n",
               sc.pathOf(i).c_str(), human(nd[i].size).c_str(), human(nd[i].own).c_str(),
               nd[i].pending.load(),
               100.0 * (double)nd[i].size / (double)(sc.totalAlloc() ? sc.totalAlloc() : 1),
               nkids, human(kids).c_str(), kids <= nd[i].size ? "OK: дети <= родитель" : "ОШИБКА: дети > родителя");
    }
    std::vector<uint32_t> idx;
    for (uint32_t i = 0; i < sc.nodeCount(); i++)
        if (nd[i].depth >= 1 && nd[i].depth <= 6 && nd[i].size >= (uint64_t)minMb * 1024 * 1024) idx.push_back(i);
    std::sort(idx.begin(), idx.end(), [&](uint32_t a, uint32_t b){ return nd[a].size > nd[b].size; });
    printf("--- топ каталогов (>= %d MB, глубина 1..6), всего таких %zu:\n", minMb, idx.size());
    for (size_t i = 0; i < idx.size() && i < 40; i++)
        printf("%10s  d%-2u  %s\n", human(nd[idx[i]].size).c_str(), nd[idx[i]].depth, sc.pathOf(idx[i]).c_str());

    {
        printf("--- файлы >= %llu МБ: всего %zu, крупнейшие:\n",
               (unsigned long long)(sc.bigMin() / 1024 / 1024), sc.bigFiles().size());
        for (size_t i = 0; i < sc.bigFiles().size() && i < 25; i++) {
            const std::string &tag = sc.bigFiles()[i].second;
            auto pos = tag.find('\x1f');
            std::string nm = tag.substr(0, pos);
            uint32_t ni = (uint32_t)atoi(tag.c_str() + pos + 1);
            printf("%10s  %s/%s\n", human(sc.bigFiles()[i].first).c_str(), sc.pathOf(ni).c_str(), nm.c_str());
        }
    }
    if (jsonPath) {
        FILE *f = fopen(jsonPath, "w");
        if (!f) { perror("json"); return 1; }
        fprintf(f, "{\"roots\":[");
        for (size_t r = 0; r < roots.size(); r++) fprintf(f, "%s\"%s\"", r ? "," : "", esc(roots[r]).c_str());
        fprintf(f, "],\"elapsed\":%.3f,\"files\":%" PRIu64 ",\"dirs\":%" PRIu64 ",\"errors\":%" PRIu64
                   ",\"alloc\":%" PRIu64 ",\"logical\":%" PRIu64 ",\"nodes\":[",
                el, files, dirs, sc.nerr(), sc.totalAlloc(), sc.totalLogical());
        bool first = true;
        uint64_t jmin = (uint64_t)atoll(getenv("FS_JSON_MIN") ? getenv("FS_JSON_MIN") : "1") * 1024 * 1024;
        for (uint32_t i = 0; i < sc.nodeCount(); i++) {
            if (nd[i].depth == 0 || nd[i].size < jmin) continue;
            fprintf(f, "%s{\"p\":\"%s\",\"s\":%" PRIu64 ",\"l\":%" PRIu64 ",\"d\":%u,\"own\":%" PRIu64 ",\"den\":%u}",
                    first ? "" : ",", esc(sc.pathOf(i)).c_str(), nd[i].size, nd[i].logical, nd[i].depth,
                    nd[i].own, nd[i].denied);
            first = false;
        }
        fprintf(f, "]}\n");
        fclose(f);
        printf("json: %s (nodes=%u, все каталоги)\n", jsonPath, sc.nodeCount());
    }
    return 0;
}
