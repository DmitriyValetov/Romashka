// rk_engine.h — C-API движка обхода дерева каталогов для приложения «Ромашка».
// Реализация: rk_engine.cpp (getattrlistbulk + пул потоков).
// Заголовок намеренно чистый C: Swift импортирует его через bridging header.
#ifndef RK_ENGINE_H
#define RK_ENGINE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Узел дерева. Раскладка — часть контракта: Swift читает эти поля напрямую.
typedef struct {
    uint32_t parent;    // индекс родителя, UINT32_MAX для корня
    uint32_t nameOff;   // смещение имени в буфере имён снимка
    uint32_t nameLen;   // длина имени без нуля
    uint32_t depth;     // 0 у корня
    uint32_t denied;    // 0 ок, 1 нет доступа (TCC/права), 2 ошибка чтения, 3 другой том
    uint32_t flags;     // зарезервировано, сейчас всегда 0
    uint64_t size;      // занято на диске: свои файлы + поддерево
    uint64_t logical;   // логический размер того же поддерева
    uint64_t own;       // занято на диске файлами непосредственно в этом каталоге
} rk_node;

typedef struct rk_scan rk_scan;

// Создаёт обход. jobs — число потоков (4–6 оптимум), bigfile_min — порог «крупного файла»
// в байтах, exclusions — массив абсолютных путей, которые не обходим (может быть NULL).
rk_scan *rk_new(const char *root, int jobs, uint64_t bigfile_min,
                const char *const *exclusions, int n_exclusions);
void rk_free(rk_scan *s);

// Запускает обход и сразу возвращает управление: работа идёт в пуле потоков.
void rk_start(rk_scan *s);
void rk_cancel(rk_scan *s);          // мягкая отмена: потоки сворачиваются в пределах каталога
void rk_wait(rk_scan *s);            // дождаться завершения (нужно CLI-режимам)
bool rk_running(rk_scan *s);

typedef struct {
    uint64_t files, dirs, alloc, logical, errors, hardlinks;
    double elapsed;
    bool running;
    bool cancelled;
} rk_progress;
void rk_progress_get(rk_scan *s, rk_progress *out);

// Снимок дерева для интерфейса. Копирует под блокировкой, поэтому структура согласована.
// min_size — отсечка: берутся узлы с size >= min_size (и всегда корень).
// orig — куда писать исходные индексы узлов (нужно вызывающему для перепривязки родителей).
// Возвращает число записанных узлов.
uint64_t rk_snapshot(rk_scan *s, rk_node *nodes, uint32_t *orig, char *names,
                     uint64_t node_cap, uint64_t names_cap, uint64_t min_size);

// Размеры арен на текущий момент — по ним вызывающий выделяет буферы под снимок.
uint64_t rk_node_count(rk_scan *s);
uint64_t rk_names_length(rk_scan *s);
uint32_t rk_root_index(rk_scan *s);

// Крупные файлы текстом: строки "size\tmtime\tпуть\n". Память выделяет движок, освобождает
// вызывающий через rk_free_text.
char *rk_bigfiles_text(rk_scan *s, uint64_t *len_out);
void rk_free_text(char *p);

// Проверка инварианта дерева size == own + Σ(детей). 0 — держится.
uint64_t rk_verify(rk_scan *s, char *first_bad_path, uint64_t cap);

const char *rk_root(rk_scan *s);
const char *rk_error(rk_scan *s);    // причина отказа открыть корень, иначе NULL

#ifdef __cplusplus
}
#endif

#endif
