#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include "sqlite_reader.h"

static int sq_get16(const unsigned char *p) { return (p[0] << 8) | p[1]; }
static int sq_get32(const unsigned char *p) { return ((p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]); }

static long long sq_varint(const unsigned char *p, int *len) {
    long long v = 0;
    int i;
    for (i = 0; i < 8; i++) {
        v = (v << 7) | (p[i] & 0x7f);
        if (!(p[i] & 0x80)) { i++; break; }
    }
    if (i == 8) { v = (v << 8) | p[8]; i = 9; }
    *len = i;
    return v;
}

int sq_open(SqliteDb *db, const char *path) {
    memset(db, 0, sizeof(*db));
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return 0; }
    long sz = ftell(f);
    rewind(f);
    if (sz < 100) { fclose(f); return 0; }
    db->data = malloc((size_t)sz);
    if (!db->data) { fclose(f); return 0; }
    if (fread(db->data, 1, (size_t)sz, f) != (size_t)sz) { free(db->data); db->data = NULL; fclose(f); return 0; }
    fclose(f);
    db->size = (size_t)sz;
    if (memcmp(db->data, "SQLite format 3", 16) != 0) { free(db->data); db->data = NULL; return 0; }
    int ps = sq_get16(db->data + 16);
    db->page_size = (ps == 1) ? 65536 : ps;
    db->reserved = db->data[20];
    return 1;
}

void sq_close(SqliteDb *db) {
    if (db->data) { free(db->data); db->data = NULL; }
}

static size_t sq_page_base(SqliteDb *db, int page) {
    return (size_t)(page - 1) * (size_t)db->page_size;
}

static size_t sq_btree_off(SqliteDb *db, int page) {
    return sq_page_base(db, page) + (page == 1 ? 100 : 0);
}

static int sq_serial_size(long long st) {
    switch (st) {
        case 0: return 0;
        case 1: return 1;
        case 2: return 2;
        case 3: return 3;
        case 4: return 4;
        case 5: return 6;
        case 6: return 8;
        case 7: return 8;
        case 8: return 0;
        case 9: return 0;
        default: return (int)((st - 12) / 2);
    }
}

int sq_parse_header(const unsigned char *rec, int reclen, SqliteRecHeader *h) {
    if (reclen < 1) return 0;
    int vl;
    long long hlen = sq_varint(rec, &vl);
    if (hlen < 1 || hlen > reclen) return 0;
    int pos = vl, i = 0;
    while (pos < hlen && i < SQ_MAX_COLS) {
        h->serial[i++] = sq_varint(rec + pos, &vl);
        pos += vl;
    }
    if (pos != hlen) return 0;
    h->n = i;
    return 1;
}

int sq_col_text(const SqliteRecHeader *h, const unsigned char *rec, int reclen, int col, char *out, int outsz) {
    out[0] = 0;
    if (col < 0 || col >= h->n) return 0;
    long long st = h->serial[col];
    if (st == 0) return 0;
    int vl;
    long long hlen = sq_varint(rec, &vl);
    int off = (int)hlen;
    for (int j = 0; j < col; j++) off += sq_serial_size(h->serial[j]);
    int sz = sq_serial_size(st);
    if (off + sz > reclen) return 0;
    const unsigned char *p = rec + off;
    if (st >= 12) {
        int n = sz;
        if (n > outsz - 1) n = outsz - 1;
        memcpy(out, p, (size_t)n);
        out[n] = 0;
        return 1;
    }
    if (st >= 1 && st <= 6) {
        long long v = 0;
        for (int i = 0; i < sz; i++) v = (v << 8) | p[i];
        int bits = sz * 8;
        if (bits < 64) { long long sign = 1LL << (bits - 1); if (v & sign) v -= (1LL << bits); }
        snprintf(out, (size_t)outsz, "%lld", v);
        return 1;
    }
    if (st == 7) { snprintf(out, (size_t)outsz, "%g", (double)*((double*)p)); return 1; }
    if (st == 8) { snprintf(out, (size_t)outsz, "0"); return 1; }
    if (st == 9) { snprintf(out, (size_t)outsz, "1"); return 1; }
    return 0;
}

long long sq_col_int(const SqliteRecHeader *h, const unsigned char *rec, int reclen, int col) {
    char buf[128];
    if (!sq_col_text(h, rec, reclen, col, buf, sizeof(buf))) return 0;
    return atoll(buf);
}

static int sq_get_payload(SqliteDb *db, const unsigned char *ppos, long long plen, unsigned char *out) {
    int usable = db->page_size - db->reserved;
    int X = usable - 35;
    int M = ((usable - 12) * 32 / 255) - 23;
    int local;
    if (plen <= X) local = (int)plen;
    else {
        local = M + (int)((plen - M) % (usable - 4));
        if (local > X) local = X;
    }
    long long got = 0;
    if (local > 0) { memcpy(out, ppos, (size_t)local); got = local; }
    int next = 0;
    if (got < plen) next = sq_get32(ppos + local);
    int guard = 0;
    while (got < plen && next && guard++ < 100000) {
        size_t off = (size_t)(next - 1) * (size_t)db->page_size;
        if (off + 4 > db->size) return 0;
        const unsigned char *p = db->data + off;
        int chunk = usable - 4;
        long long rem = plen - got;
        int n = (rem < chunk) ? (int)rem : chunk;
        memcpy(out + got, p + 4, (size_t)n);
        got += n;
        next = sq_get32(p);
    }
    return got == plen;
}

static int sq_walk_page(SqliteDb *db, int page, sq_row_cb cb, void *ctx, int depth) {
    if (depth > 64) return 0;
    size_t boff = sq_btree_off(db, page);
    if (boff + 8 > db->size) return 0;
    const unsigned char *bh = db->data + boff;
    int type = bh[0];
    int ncell = sq_get16(bh + 3);
    size_t base = sq_page_base(db, page);
    if (type == 5) {
        int right = sq_get32(bh + 8);
        for (int i = 0; i < ncell; i++) {
            if (boff + 12 + i * 2 + 2 > db->size) return 0;
            int coff = sq_get16(db->data + boff + 12 + i * 2);
            const unsigned char *cell = db->data + base + coff;
            int child = sq_get32(cell);
            if (!sq_walk_page(db, child, cb, ctx, depth + 1)) return 0;
        }
        if (right && !sq_walk_page(db, right, cb, ctx, depth + 1)) return 0;
        return 1;
    }
    if (type == 13) {
        for (int i = 0; i < ncell; i++) {
            if (boff + 8 + i * 2 + 2 > db->size) return 0;
            int coff = sq_get16(db->data + boff + 8 + i * 2);
            const unsigned char *cell = db->data + base + coff;
            int vl = 0, vl2 = 0;
            long long plen = sq_varint(cell, &vl);
            long long rowid = sq_varint(cell + vl, &vl2);
            int hdr = vl + vl2;
            if (plen < 0 || plen > (long long)db->size) return 0;
            unsigned char *rec = malloc((size_t)plen + 1);
            if (!rec) return 0;
            int ok = sq_get_payload(db, cell + hdr, plen, rec);
            rec[plen] = 0;
            if (!ok) { free(rec); return 0; }
            int r = cb(ctx, rowid, rec, (int)plen);
            free(rec);
            if (r) return 1;
        }
        return 1;
    }
    return 0;
}

int sq_walk_table(SqliteDb *db, int rootpage, sq_row_cb cb, void *ctx) {
    return sq_walk_page(db, rootpage, cb, ctx, 0);
}

static int sq_is_kw(const char *w) {
    static const char *kws[] = {"PRIMARY", "UNIQUE", "CHECK", "FOREIGN", "CONSTRAINT", "CONSTRAINTS", NULL};
    for (int i = 0; kws[i]; i++) if (strcasecmp(w, kws[i]) == 0) return 1;
    return 0;
}

static void sq_add_col(SqliteTable *t, const char *start, const char *end) {
    while (start < end && isspace((unsigned char)*start)) start++;
    while (end > start && isspace((unsigned char)end[-1])) end--;
    if (start >= end || t->ncols >= SQ_MAX_COLS) return;
    char w[128];
    int n = 0;
    const char *p = start;
    if (*p == '"' || *p == '`' || *p == '[') {
        char q = *p;
        char close = (q == '[') ? ']' : q;
        p++;
        while (p < end && n < 127) {
            if (*p == close) break;
            w[n++] = *p++;
        }
        w[n] = 0;
        if (n) { memcpy(t->colnames[t->ncols], w, (size_t)n + 1); t->ncols++; }
        return;
    }
    while (p < end && n < 127 && !isspace((unsigned char)*p) && *p != '(' && *p != ',') w[n++] = *p++;
    w[n] = 0;
    if (n == 0) return;
    if (sq_is_kw(w)) return;
    memcpy(t->colnames[t->ncols], w, (size_t)n + 1);
    t->ncols++;
}

static int sq_parse_create(SqliteTable *t, const char *sql) {
    t->ncols = 0;
    const char *p = sql;
    char q = 0;
    int depth = 0;
    const char *open = NULL;
    for (; *p; p++) {
        char c = *p;
        if (q) { if (c == q) q = 0; continue; }
        if (c == '\'' || c == '"' || c == '`') { q = c; continue; }
        if (c == '(') { if (depth == 0 && !open) open = p; depth++; continue; }
        if (c == ')') { if (depth > 0) depth--; if (depth == 0 && open) break; }
    }
    if (!open) return 0;
    const char *end = p;
    int d = 0;
    char qq = 0;
    const char *seg = open + 1;
    for (const char *s = open + 1; s < end; s++) {
        char c = *s;
        if (qq) { if (c == qq) qq = 0; continue; }
        if (c == '\'' || c == '"' || c == '`') { qq = c; continue; }
        if (c == '(') { d++; continue; }
        if (c == ')') { if (d > 0) d--; continue; }
        if (c == ',' && d == 0) { sq_add_col(t, seg, s); seg = s + 1; }
    }
    sq_add_col(t, seg, end);
    for (int i = 0; i < t->ncols; i++) {
        if (strcmp(t->colnames[i], "id") == 0 && strcasestr(sql, "INTEGER PRIMARY KEY")) {
            t->id_is_rowid = 1;
            break;
        }
    }
    return t->ncols > 0;
}

typedef struct {
    SqliteDb *db;
    const char *name;
    SqliteTable *out;
    int found;
} FindTableCtx;

static int find_table_cb(void *ctxp, long long rowid, const unsigned char *rec, int reclen) {
    (void)rowid;
    FindTableCtx *c = ctxp;
    SqliteRecHeader h;
    if (!sq_parse_header(rec, reclen, &h)) return 0;
    char type[32], name[128];
    if (!sq_col_text(&h, rec, reclen, 0, type, sizeof(type))) return 0;
    if (strcmp(type, "table") != 0) return 0;
    if (!sq_col_text(&h, rec, reclen, 1, name, sizeof(name))) return 0;
    if (strcmp(name, c->name) != 0) return 0;
    long long rp = sq_col_int(&h, rec, reclen, 3);
    char sql[8192];
    if (!sq_col_text(&h, rec, reclen, 4, sql, sizeof(sql))) return 0;
    c->out->rootpage = (int)rp;
    sq_parse_create(c->out, sql);
    c->found = 1;
    return 1;
}

int sq_find_table(SqliteDb *db, const char *name, SqliteTable *out) {
    FindTableCtx ctx = { db, name, out, 0 };
    sq_walk_page(db, 1, find_table_cb, &ctx, 0);
    return ctx.found;
}

int sq_column_index(const SqliteTable *t, const char *name) {
    for (int i = 0; i < t->ncols; i++) {
        if (strcmp(t->colnames[i], name) == 0) return i;
    }
    return -1;
}
