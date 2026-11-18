#ifndef GAME_LAUNCHER_SQLITE_READER_H
#define GAME_LAUNCHER_SQLITE_READER_H

#include <stddef.h>

#define SQ_MAX_COLS 64

typedef struct {
    unsigned char *data;
    size_t size;
    int page_size;
    int reserved;
} SqliteDb;

typedef struct {
    int rootpage;
    int ncols;
    char colnames[SQ_MAX_COLS][64];
    int id_is_rowid;
} SqliteTable;

typedef struct {
    long long serial[SQ_MAX_COLS];
    int n;
} SqliteRecHeader;

int sq_open(SqliteDb *db, const char *path);
void sq_close(SqliteDb *db);

int sq_find_table(SqliteDb *db, const char *name, SqliteTable *out);
int sq_column_index(const SqliteTable *t, const char *name);

typedef int (*sq_row_cb)(void *ctx, long long rowid, const unsigned char *rec, int reclen);
int sq_walk_table(SqliteDb *db, int rootpage, sq_row_cb cb, void *ctx);

int sq_parse_header(const unsigned char *rec, int reclen, SqliteRecHeader *h);
int sq_col_text(const SqliteRecHeader *h, const unsigned char *rec, int reclen, int col, char *out, int outsz);
long long sq_col_int(const SqliteRecHeader *h, const unsigned char *rec, int reclen, int col);

#endif
