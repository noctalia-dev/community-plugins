#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#include <sqlite3.h>
#include <libgen.h>
#include <ctype.h>
#include <time.h>

#define MAX_GAMES 4096
#define MAX_STR 1024
#define MAX_PATH 8192
#define MAX_RUN_CMD 4096

typedef struct {
    char id[MAX_STR];
    char name[MAX_STR];
    char runner[MAX_STR];
    char cover[MAX_PATH];
    char cover_url[MAX_PATH];
    char run_command[MAX_RUN_CMD];
    char slug[MAX_STR];
} Game;

typedef struct {
    Game *games;
    int count;
    int capacity;
} GameArray;

GameArray ga = {0};

void init_games() {
    ga.capacity = MAX_GAMES;
    ga.games = calloc(ga.capacity, sizeof(Game));
    ga.count = 0;
}

void free_games() {
    free(ga.games);
    ga.games = NULL;
    ga.count = 0;
    ga.capacity = 0;
}

int game_exists(const char *name) {
    for (int i = 0; i < ga.count; i++) {
        if (strcasecmp(ga.games[i].name, name) == 0) return 1;
    }
    return 0;
}

void add_game(const char *id, const char *name, const char *runner,
              const char *cover, const char *cover_url, const char *run_command, const char *slug) {
    if (ga.count >= ga.capacity) return;
    Game *g = &ga.games[ga.count++];
    strncpy(g->id, id, MAX_STR - 1);
    strncpy(g->name, name, MAX_STR - 1);
    strncpy(g->runner, runner, MAX_STR - 1);
    strncpy(g->cover, cover ? cover : "", MAX_PATH - 1);
    strncpy(g->cover_url, cover_url ? cover_url : "", MAX_PATH - 1);
    strncpy(g->run_command, run_command ? run_command : "", MAX_RUN_CMD - 1);
    strncpy(g->slug, slug ? slug : "", MAX_STR - 1);
}

void print_json_escaped(const char *s) {
    for (; *s; s++) {
        if (*s == '"' || *s == '\\') putchar('\\');
        putchar(*s);
    }
}

void print_json() {
    printf("[\n");
    for (int i = 0; i < ga.count; i++) {
        Game *g = &ga.games[i];
        printf("  {\n");
        printf("    \"id\": \"");
        print_json_escaped(g->id);
        printf("\",\n");
        printf("    \"name\": \"");
        print_json_escaped(g->name);
        printf("\",\n");
        printf("    \"runner\": \"");
        print_json_escaped(g->runner);
        printf("\",\n");
        printf("    \"cover\": \"");
        print_json_escaped(g->cover);
        printf("\",\n");
        printf("    \"cover_url\": \"");
        print_json_escaped(g->cover_url);
        printf("\",\n");
        printf("    \"run_command\": \"");
        print_json_escaped(g->run_command);
        printf("\",\n");
        printf("    \"slug\": \"");
        print_json_escaped(g->slug);
        printf("\"\n");
        printf("  }%s\n", i < ga.count - 1 ? "," : "");
    }
    printf("]\n");
}

char *get_home() {
    char *home = getenv("HOME");
    return home ? home : "";
}

char *get_xdg_data_home() {
    char *xdg = getenv("XDG_DATA_HOME");
    if (xdg && xdg[0]) return xdg;
    static char buf[MAX_PATH];
    snprintf(buf, sizeof(buf), "%s/.local/share", get_home());
    return buf;
}

char *get_xdg_config_home() {
    char *xdg = getenv("XDG_CONFIG_HOME");
    if (xdg && xdg[0]) return xdg;
    static char buf[MAX_PATH];
    snprintf(buf, sizeof(buf), "%s/.config", get_home());
    return buf;
}

char *get_xdg_cache_home() {
    char *xdg = getenv("XDG_CACHE_HOME");
    if (xdg) return xdg;
    static char buf[MAX_PATH];
    snprintf(buf, sizeof(buf), "%s/.cache", get_home());
    return buf;
}

int file_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

void scan_steam_shortcuts() {
    char base[MAX_PATH];
    const char *data_home = get_xdg_data_home();

    const char *steam_bases[] = {
        "/Steam/userdata",
        "/.steam/root/userdata",
        "/.var/app/com.valvesoftware.Steam/.local/share/Steam/userdata",
        NULL
    };

    for (int b = 0; steam_bases[b]; b++) {
        snprintf(base, sizeof(base), "%s%s", data_home, steam_bases[b]);

        DIR *ud = opendir(base);
        if (!ud) continue;

        struct dirent *entry;
        while ((entry = readdir(ud))) {
            if (entry->d_name[0] == '.') continue;

            char config_path[MAX_PATH];
            snprintf(config_path, sizeof(config_path), "%s/%s/config/shortcuts.vdf",
                     base, entry->d_name);

            FILE *f = fopen(config_path, "rb");
            if (!f) continue;

            fseek(f, 0, SEEK_END);
            long fsize = ftell(f);
            rewind(f);

            char *buf = malloc(fsize + 1);
            if (!buf) { fclose(f); continue; }
            size_t nread = fread(buf, 1, fsize, f);
            buf[nread] = '\0';
            fclose(f);

            char *p = buf;
            while ((p = strstr(p, "\"AppName\""))) {
                char *vstart = p + 9;
                while (*vstart && *vstart != '"') vstart++;
                if (*vstart != '"') { p++; continue; }
                vstart++;
                char *vend = strchr(vstart, '"');
                if (!vend) { p++; continue; }

                char appname[MAX_STR];
                size_t nlen = vend - vstart;
                if (nlen >= MAX_STR) nlen = MAX_STR - 1;
                strncpy(appname, vstart, nlen);
                appname[nlen] = '\0';

                if (game_exists(appname)) { p = vend; continue; }

                char *appid_p = strstr(vend, "\"appid\"");
                if (!appid_p) { p = vend; continue; }

                appid_p += 7;
                while (*appid_p && *appid_p != '"') appid_p++;
                if (*appid_p == '"') {
                    appid_p++;
                    char *appid_end = strchr(appid_p, '"');
                    if (appid_end) {
                        char appid_str[32];
                        size_t idlen = appid_end - appid_p;
                        if (idlen >= sizeof(appid_str)) idlen = sizeof(appid_str) - 1;
                        strncpy(appid_str, appid_p, idlen);
                        appid_str[idlen] = '\0';

                        unsigned long long appid = strtoull(appid_str, NULL, 10);
                        unsigned long long short_appid = appid & 0xFFFFFFFFULL;
                        unsigned long long long_id = (short_appid << 32) | 0x02000000ULL;

        char run_command[MAX_RUN_CMD];
                         snprintf(run_command, sizeof(run_command),
                                  "steam://rungameid/%llu", long_id);

                        add_game(appid_str, appname, "steam", "", "", run_command, "");
                    }
                }
                p = appid_p;
            }

            free(buf);
        }
        closedir(ud);
    }
}

static void steam_acf_parse_value(const char *pos, const char *key,
                                  char *out, size_t out_size) {
    char search_key[64];
    snprintf(search_key, sizeof(search_key), "\"%s\"", key);
    const char *kp = strstr(pos, search_key);
    if (!kp) { out[0] = '\0'; return; }
    kp += strlen(search_key);
    while (*kp && *kp != '"') kp++;
    if (*kp++ != '"') { out[0] = '\0'; return; }
    const char *end = strchr(kp, '"');
    if (!end) { out[0] = '\0'; return; }
    size_t len = end - kp;
    if (len >= out_size) len = out_size - 1;
    strncpy(out, kp, len);
    out[len] = '\0';
}

int should_exclude_steam(const char *name) {
    const char *excludes[] = {
        "Proton", "Steam Runtime", "Steamworks", "Steam Client",
        "Steam", "SteamVR", "Steam Linux Runtime", NULL
    };
    for (int i = 0; excludes[i]; i++) {
        if (strcasestr(name, excludes[i])) return 1;
    }
    return 0;
}

void scan_steam() {
    const char *data_home = get_xdg_data_home();

    const char *steam_roots[] = {
        "/Steam",
        "/.steam/steam",
        "/.var/app/com.valvesoftware.Steam/.local/share/Steam",
        NULL
    };

    char (*steamapps_paths)[MAX_PATH] = calloc(MAX_GAMES, MAX_PATH);
    if (!steamapps_paths) return;
    int num_steamapps = 0;

    for (int r = 0; steam_roots[r]; r++) {
        char sp[MAX_PATH];
        snprintf(sp, sizeof(sp), "%s%s/steamapps", data_home, steam_roots[r]);
        if (file_exists(sp)) {
            strncpy(steamapps_paths[num_steamapps++], sp, MAX_PATH - 1);
        }
    }

    for (int r = 0; steam_roots[r]; r++) {
        char vdf_path[MAX_PATH];
        snprintf(vdf_path, sizeof(vdf_path), "%s%s/steamapps/libraryfolders.vdf",
                 data_home, steam_roots[r]);

        FILE *f = fopen(vdf_path, "r");
        if (!f) continue;

        fseek(f, 0, SEEK_END);
        long len = ftell(f);
        rewind(f);
        char *content = malloc(len + 1);
        if (!content) { fclose(f); continue; }
        fread(content, 1, len, f);
        content[len] = '\0';
        fclose(f);

        char *p = content;
        while ((p = strstr(p, "\"path\""))) {
            p += 6;
            while (*p && *p != '"') p++;
            if (*p++ != '"') continue;
            char *end = strchr(p, '"');
            if (!end) continue;

            char path_buf[MAX_PATH];
            size_t plen = end - p;
            if (plen >= sizeof(path_buf)) plen = sizeof(path_buf) - 1;
            strncpy(path_buf, p, plen);
            path_buf[plen] = '\0';

            char sa[MAX_PATH];
            snprintf(sa, sizeof(sa), "%s/steamapps", path_buf);
            if (file_exists(sa)) {
                int found = 0;
                for (int i = 0; i < num_steamapps; i++) {
                    if (strcmp(steamapps_paths[i], sa) == 0) { found = 1; break; }
                }
                if (!found && num_steamapps < MAX_GAMES) {
                    strncpy(steamapps_paths[num_steamapps++], sa, MAX_PATH - 1);
                }
            }

            p = end;
        }
        free(content);
    }

    if (num_steamapps == 0) { free(steamapps_paths); return; }

    for (int s = 0; s < num_steamapps; s++) {
        DIR *dir = opendir(steamapps_paths[s]);
        if (!dir) continue;

        struct dirent *entry;
        while ((entry = readdir(dir))) {
            if (strncmp(entry->d_name, "appmanifest_", 12) != 0) continue;
            if (strcmp(entry->d_name + strlen(entry->d_name) - 4, ".acf") != 0) continue;

            char acf_path[MAX_PATH];
            snprintf(acf_path, sizeof(acf_path), "%s/%s",
                     steamapps_paths[s], entry->d_name);

            FILE *f = fopen(acf_path, "r");
            if (!f) continue;

            fseek(f, 0, SEEK_END);
            long flen = ftell(f);
            rewind(f);
            char *acf_content = malloc(flen + 1);
            if (!acf_content) { fclose(f); continue; }
            fread(acf_content, 1, flen, f);
            acf_content[flen] = '\0';
            fclose(f);

            char appid_str[32], name[MAX_STR];
            steam_acf_parse_value(acf_content, "appid", appid_str, sizeof(appid_str));
            steam_acf_parse_value(acf_content, "name", name, sizeof(name));

            free(acf_content);

            if (!appid_str[0] || !name[0] || should_exclude_steam(name)) continue;
            if (game_exists(name)) continue;

            char header[MAX_PATH] = "";
            char candidates[MAX_PATH];

            snprintf(candidates, sizeof(candidates), "%s/../appcache/librarycache/%s_header.jpg",
                     steamapps_paths[s], appid_str);
            if (file_exists(candidates)) strncpy(header, candidates, MAX_PATH - 1);

            if (!header[0]) {
                snprintf(candidates, sizeof(candidates),
                         "%s/../appcache/librarycache/%s/library_600x900.jpg",
                         steamapps_paths[s], appid_str);
                if (file_exists(candidates)) strncpy(header, candidates, MAX_PATH - 1);
            }

            if (!header[0]) {
                snprintf(candidates, sizeof(candidates), "%s/gamelauncher/steam/%s.jpg",
                         get_xdg_cache_home(), appid_str);
                if (file_exists(candidates)) strncpy(header, candidates, MAX_PATH - 1);
            }

            char run_command[MAX_RUN_CMD];
            snprintf(run_command, sizeof(run_command), "steam://rungameid/%s", appid_str);

            add_game(appid_str, name, "steam", header, "", run_command, "");
        }
        closedir(dir);
    }
    free(steamapps_paths);
}

void scan_lutris() {
    char db_paths[8][MAX_PATH];
    int num_dbs = 0;
    const char *data_home = get_xdg_data_home();

    const char *paths[] = {
        "/lutris/pga.db",
        "/lutris/lutris.db",
        "/lutris/db.sqlite",
        NULL
    };

    for (int i = 0; paths[i]; i++) {
        snprintf(db_paths[num_dbs], MAX_PATH, "%s%s", data_home, paths[i]);
        num_dbs++;
    }

    char flatpak_path[MAX_PATH];
    snprintf(flatpak_path, sizeof(flatpak_path),
             "%s/.var/app/net.lutris.Lutris/data/lutris/pga.db", get_home());
    if (file_exists(flatpak_path))
        strncpy(db_paths[num_dbs++], flatpak_path, MAX_PATH - 1);

    snprintf(flatpak_path, sizeof(flatpak_path),
             "%s/.var/app/net.lutris.Lutris/data/lutris/lutris.db", get_home());
    if (file_exists(flatpak_path))
        strncpy(db_paths[num_dbs++], flatpak_path, MAX_PATH - 1);

    snprintf(flatpak_path, sizeof(flatpak_path),
             "%s/.var/app/net.lutris.Lutris/data/lutris/db.sqlite", get_home());
    if (file_exists(flatpak_path))
        strncpy(db_paths[num_dbs++], flatpak_path, MAX_PATH - 1);

    char *chosen_db = NULL;
    time_t newest = 0;

    for (int i = 0; i < num_dbs; i++) {
        if (!file_exists(db_paths[i])) continue;
        struct stat st;
        stat(db_paths[i], &st);
        if (st.st_mtime > newest) {
            newest = st.st_mtime;
            chosen_db = db_paths[i];
        }
    }

    if (!chosen_db) {
        const char *lutris_dirs[] = {
            "/lutris",
            "/.var/app/net.lutris.Lutris/data/lutris",
            NULL
        };

        for (int d = 0; lutris_dirs[d]; d++) {
            char dir_path[MAX_PATH];
            snprintf(dir_path, sizeof(dir_path), "%s%s", data_home, lutris_dirs[d]);

            DIR *dir = opendir(dir_path);
            if (!dir) continue;

            struct dirent *entry;
            while ((entry = readdir(dir))) {
                char *dot = strrchr(entry->d_name, '.');
                if (!dot || strcmp(dot, ".db") != 0) continue;

                char fp[MAX_PATH];
                snprintf(fp, sizeof(fp), "%s/%s", dir_path, entry->d_name);

                struct stat st;
                stat(fp, &st);
                if (st.st_mtime > newest) {
                    newest = st.st_mtime;
                    chosen_db = fp;
                }
            }
            closedir(dir);
        }
    }

    if (!chosen_db) return;

    sqlite3 *db;
    int rc = sqlite3_open_v2(chosen_db, &db, SQLITE_OPEN_READONLY, NULL);
    if (rc != SQLITE_OK) return;

    sqlite3_stmt *stmt;

    const char *query =
        "SELECT id, name, slug, runner "
        "FROM games WHERE installed = 1";

    rc = sqlite3_prepare_v2(db, query, -1, &stmt, NULL);

    if (rc != SQLITE_OK) {
        const char *alt_queries[] = {
            "SELECT id, name, slug, runner FROM installed_game",
            "SELECT id, name, slug, runner FROM game WHERE installed = 1",
            NULL
        };

        for (int q = 0; alt_queries[q]; q++) {
            rc = sqlite3_prepare_v2(db, alt_queries[q], -1, &stmt, NULL);
            if (rc == SQLITE_OK) break;
        }

        if (rc != SQLITE_OK) {
            sqlite3_close(db);
            return;
        }
    }

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *id = (const char *)sqlite3_column_text(stmt, 0);
        const char *name = (const char *)sqlite3_column_text(stmt, 1);
        const char *slug = (const char *)sqlite3_column_text(stmt, 2);
        const char *runner = (const char *)sqlite3_column_text(stmt, 3);

        if (!name || !slug) continue;
        if (game_exists(name)) continue;

        char cover[MAX_PATH] = "";
        const char *cover_dirs[] = {
            "/.local/share/lutris/coverart",
            "/.var/app/net.lutris.Lutris/data/lutris/coverart",
            "/.cache/lutris/coverart",
            NULL
        };

        for (int c = 0; cover_dirs[c]; c++) {
            char cd[MAX_PATH];
            snprintf(cd, sizeof(cd), "%s%s", get_home(), cover_dirs[c]);

            const char *exts[] = {".jpg", ".png", ".jpeg", NULL};
            for (int e = 0; exts[e]; e++) {
                char fp[MAX_PATH];
                snprintf(fp, sizeof(fp), "%s/%s%s", cd, slug, exts[e]);
                if (file_exists(fp)) {
                    strncpy(cover, fp, MAX_PATH - 1);
                    break;
                }
            }
            if (cover[0]) break;
        }

        char run_command[MAX_RUN_CMD];
        snprintf(run_command, sizeof(run_command), "lutris:rungame/%s", slug);

        if (!id) id = "0";
        if (!runner) runner = "linux";

        add_game(id, name, "lutris", cover, "", run_command, slug ? slug : "");
    }

    sqlite3_finalize(stmt);
    sqlite3_close(db);
}

void scan_lutris_manual_files() {
    const char *data_home = get_xdg_data_home();
    char games_dir[MAX_PATH];
    snprintf(games_dir, sizeof(games_dir), "%s/lutris/games", data_home);

    DIR *dir = opendir(games_dir);
    if (!dir) return;

    struct dirent *entry;
    while ((entry = readdir(dir))) {
        char *dot = strrchr(entry->d_name, '.');
        if (!dot || (strcmp(dot, ".yml") != 0 && strcmp(dot, ".yaml") != 0)) continue;

        char fp[MAX_PATH];
        snprintf(fp, sizeof(fp), "%s/%s", games_dir, entry->d_name);

        FILE *f = fopen(fp, "r");
        if (!f) continue;

        char name[MAX_STR] = "";
        char line[1024];
        while (fgets(line, sizeof(line), f)) {
            if (strncmp(line, "name:", 5) == 0) {
                const char *v = line + 5;
                while (*v == ' ') v++;
                size_t l = strlen(v);
                while (l > 0 && (v[l - 1] == '\n' || v[l - 1] == '\r')) l--;
                if (l >= MAX_STR) l = MAX_STR - 1;
                strncpy(name, v, l);
                name[l] = '\0';
                break;
            }
        }
        fclose(f);

        if (!name[0]) continue;
        if (game_exists(name)) continue;

        char slug[MAX_STR];
        for (int si = 0; name[si]; si++) {
            slug[si] = isalnum((unsigned char)name[si]) ?
                       tolower((unsigned char)name[si]) : '-';
            slug[si + 1] = '\0';
        }

        char run_command[MAX_RUN_CMD];
        snprintf(run_command, sizeof(run_command), "lutris:rungame/%s", slug);

        add_game("0", name, "lutris", "", "", run_command, slug);
    }
    closedir(dir);
}

typedef struct {
    char **keys;
    char **values;
    int count;
    int cap;
} KVMap;

void kv_init(KVMap *m) {
    m->keys = NULL;
    m->values = NULL;
    m->count = 0;
    m->cap = 0;
}

void kv_free(KVMap *m) {
    for (int i = 0; i < m->count; i++) {
        free(m->keys[i]);
        free(m->values[i]);
    }
    free(m->keys);
    free(m->values);
    m->keys = NULL;
    m->values = NULL;
    m->count = 0;
    m->cap = 0;
}

void kv_add(KVMap *m, const char *key, const char *value) {
    if (m->count >= m->cap) {
        m->cap = m->cap ? m->cap * 2 : 16;
        m->keys = realloc(m->keys, m->cap * sizeof(char *));
        m->values = realloc(m->values, m->cap * sizeof(char *));
    }
    m->keys[m->count] = strdup(key);
    m->values[m->count] = strdup(value);
    m->count++;
}

char *kv_get(KVMap *m, const char *key) {
    for (int i = 0; i < m->count; i++) {
        if (strcmp(m->keys[i], key) == 0) return m->values[i];
    }
    return NULL;
}

char *json_extract_string(const char *json, const char *key) {
    char search[128];
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *p = strstr(json, search);
    if (!p) return NULL;
    p += strlen(search);
    while (*p && *p != '"') p++;
    if (*p != '"') return NULL;
    p++;
    size_t max_len = 65536;
    char *result = malloc(max_len);
    if (!result) return NULL;
    size_t o = 0;
    while (*p && *p != '"' && o < max_len - 1) {
        if (*p == '\\' && *(p + 1)) {
            p++;
            switch (*p) {
                case 'n': result[o++] = '\n'; break;
                case 'r': result[o++] = '\r'; break;
                case 't': result[o++] = '\t'; break;
                case '/': result[o++] = '/'; break;
                default:  result[o++] = *p; break;
            }
        } else {
            result[o++] = *p;
        }
        p++;
    }
    result[o] = '\0';
    return result;
}

int json_extract_bool(const char *json, const char *key) {
    char search[128];
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *p = strstr(json, search);
    if (!p) return 0;
    p += strlen(search);
    while (*p && *p != 't' && *p != 'f') p++;
    return (strncmp(p, "true", 4) == 0);
}

void heroic_scan_sideloaded(const char *config_home) {
    char path[MAX_PATH];
    snprintf(path, sizeof(path), "%s/heroic/sideload_apps/library.json", config_home);
    if (!file_exists(path)) return;
    FILE *f = fopen(path, "r");
    if (!f) return;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    rewind(f);
    char *content = malloc(len + 1);
    if (!content) { fclose(f); return; }
    fread(content, 1, len, f);
    content[len] = '\0';
    fclose(f);
    char *p = content;
    int brace_depth = 0;
    while (*p) {
        p = strstr(p, "\"games\"");
        if (!p) break;
        p += 7;
        while (*p && *p != '[') p++;
        if (*p != '[') continue;
        p++;
        brace_depth = 0;
        char *obj_start = NULL;
        while (*p) {
            if (*p == '{') {
                if (brace_depth == 0) obj_start = p;
                brace_depth++;
            } else if (*p == '}') {
                brace_depth--;
                if (brace_depth == 0 && obj_start) {
                    size_t obj_len = p - obj_start + 1;
                    char *obj = malloc(obj_len + 1);
                    strncpy(obj, obj_start, obj_len);
                    obj[obj_len] = '\0';
                    char *app_name = json_extract_string(obj, "app_name");
                    char *title = json_extract_string(obj, "title");
                    int installed = json_extract_bool(obj, "is_installed");
                    char *art_cover = json_extract_string(obj, "art_cover");
                    if (title && installed && !game_exists(title)) {
                        char cover_path[MAX_PATH] = "";
                        char cover_url[MAX_PATH] = "";
                        if (art_cover && strstr(art_cover, "http")) {
                            strncpy(cover_url, art_cover, MAX_PATH - 1);
                        } else if (art_cover) {
                            strncpy(cover_path, art_cover, MAX_PATH - 1);
                        }
                        char run_command[MAX_RUN_CMD];
                        snprintf(run_command, sizeof(run_command),
                                 "heroic://launch/sideload/%s", app_name ? app_name : "");
                        add_game(app_name ? app_name : "", title, "heroic",
                                 cover_path, cover_url, run_command, "");
                    }
                    free(app_name); free(title); free(art_cover); free(obj);
                    obj_start = NULL;
                }
            }
            if (*p) p++;
        }
    }
    free(content);
}

void heroic_load_installed_ids(const char *config_home, char installed_ids[][64], int *count) {
    const char *install_files[] = {
        "/heroic/store_cache/legendary_install_info.json",
        "/heroic/store_cache/gog_install_info.json",
        "/heroic/store_cache/nile_install_info.json",
        NULL
    };
    *count = 0;
    for (int f = 0; install_files[f]; f++) {
        char path[MAX_PATH];
        snprintf(path, sizeof(path), "%s%s", config_home, install_files[f]);
        if (!file_exists(path)) continue;
        FILE *fp = fopen(path, "r");
        if (!fp) continue;
        fseek(fp, 0, SEEK_END);
        long len = ftell(fp);
        rewind(fp);
        char *content = malloc(len + 1);
        if (!content) { fclose(fp); continue; }
        fread(content, 1, len, fp);
        content[len] = '\0';
        fclose(fp);
        char *p = content;
        while (*p) {
            while (*p && *p != '"') p++;
            if (!*p) break;
            p++;
            char *end = strchr(p, '"');
            if (!end) break;
            size_t id_len = end - p;
            if (id_len > 0 && id_len < 64 && strcmp(p, "__timestamp") != 0) {
                if (*count < MAX_GAMES) {
                    strncpy(installed_ids[*count], p, id_len);
                    installed_ids[*count][id_len] = '\0';
                    (*count)++;
                }
            }
            p = end + 1;
        }
        free(content);
    }
}

void heroic_load_library_map(const char *path, KVMap *titles, KVMap *covers) {
    if (!file_exists(path)) return;
    FILE *f = fopen(path, "r");
    if (!f) return;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    rewind(f);
    char *content = malloc(len + 1);
    if (!content) { fclose(f); return; }
    fread(content, 1, len, f);
    content[len] = '\0';
    fclose(f);
    char *p = content;
    int brace_depth = 0;
    while (*p) {
        p = strstr(p, "\"library\"");
        if (!p) {
            p = content;
            brace_depth = 0;
            char *obj_start = NULL;
            while (*p) {
                if (*p == '{') {
                    if (brace_depth == 0) obj_start = p;
                    brace_depth++;
                } else if (*p == '}') {
                    brace_depth--;
                    if (brace_depth == 0 && obj_start) {
                        size_t olen = p - obj_start + 1;
                        char *obj = malloc(olen + 1);
                        strncpy(obj, obj_start, olen);
                        obj[olen] = '\0';
                        char *app_name = json_extract_string(obj, "app_name");
                        char *title = json_extract_string(obj, "title");
                        char *art_cover = json_extract_string(obj, "art_cover");
                        if (app_name && title) kv_add(titles, app_name, title);
                        if (app_name && art_cover) kv_add(covers, app_name, art_cover);
                        free(app_name); free(title); free(art_cover); free(obj);
                        obj_start = NULL;
                    }
                }
                if (*p) p++;
            }
            break;
        }
        p += 8;
        while (*p && *p != '[') p++;
        if (*p++ != '[') break;
        brace_depth = 0;
        char *obj_start = NULL;
        while (*p) {
            if (*p == '{') {
                if (brace_depth == 0) obj_start = p;
                brace_depth++;
            } else if (*p == '}') {
                brace_depth--;
                if (brace_depth == 0 && obj_start) {
                    size_t olen = p - obj_start + 1;
                    char *obj = malloc(olen + 1);
                    strncpy(obj, obj_start, olen);
                    obj[olen] = '\0';
                    char *app_name = json_extract_string(obj, "app_name");
                    char *title = json_extract_string(obj, "title");
                    char *art_cover = json_extract_string(obj, "art_cover");
                    if (app_name && title) kv_add(titles, app_name, title);
                    if (app_name && art_cover) kv_add(covers, app_name, art_cover);
                    free(app_name); free(title); free(art_cover); free(obj);
                    obj_start = NULL;
                }
            }
            if (*p) p++;
        }
        break;
    }
    free(content);
}

void scan_heroic() {
    const char *config_home = get_xdg_config_home();
    heroic_scan_sideloaded(config_home);
    char installed_ids[MAX_GAMES][64];
    int num_installed = 0;
    heroic_load_installed_ids(config_home, installed_ids, &num_installed);
    if (num_installed == 0) return;
    KVMap titles, covers;
    kv_init(&titles);
    kv_init(&covers);
    const char *lib_files[] = { "legendary_library.json", "gog_library.json", "nile_library.json", NULL };
    for (int i = 0; lib_files[i]; i++) {
        char path[MAX_PATH];
        snprintf(path, sizeof(path), "%s/heroic/store_cache/%s", config_home, lib_files[i]);
        heroic_load_library_map(path, &titles, &covers);
    }
    char games_config[MAX_PATH];
    snprintf(games_config, sizeof(games_config), "%s/heroic/GamesConfig", config_home);
    DIR *dir = opendir(games_config);
    if (!dir) { kv_free(&titles); kv_free(&covers); return; }
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        char *dot = strrchr(entry->d_name, '.');
        if (!dot || strcmp(dot, ".json") != 0) continue;
        char app_id[64];
        size_t nlen = dot - entry->d_name;
        if (nlen >= sizeof(app_id)) nlen = sizeof(app_id) - 1;
        strncpy(app_id, entry->d_name, nlen);
        app_id[nlen] = '\0';
        int found_installed = 0;
        for (int i = 0; i < num_installed; i++) {
            if (strcmp(installed_ids[i], app_id) == 0) { found_installed = 1; break; }
        }
        if (!found_installed) continue;
        char *title = kv_get(&titles, app_id);
        if (!title) {
            char cfg_path[MAX_PATH];
            snprintf(cfg_path, sizeof(cfg_path), "%s/%s", games_config, entry->d_name);
            FILE *cf = fopen(cfg_path, "r");
            if (cf) {
                fseek(cf, 0, SEEK_END);
                long clen = ftell(cf);
                rewind(cf);
                char *cc = malloc(clen + 1);
                if (cc) {
                    fread(cc, 1, clen, cf);
                    cc[clen] = '\0';
                    char *t = json_extract_string(cc, "name");
                    if (!t) t = json_extract_string(cc, "title");
                    if (t) title = t;
                    free(cc);
                }
                fclose(cf);
            }
        }
        if (!title) continue;
        if (game_exists(title)) continue;
        char cover[MAX_PATH] = "";
        char cover_url[MAX_PATH] = "";
        char icon_path[MAX_PATH];
        snprintf(icon_path, sizeof(icon_path), "%s/heroic/icons/%s.jpg", config_home, app_id);
        if (file_exists(icon_path)) strncpy(cover, icon_path, MAX_PATH - 1);
        else {
            char cache_path[MAX_PATH];
            snprintf(cache_path, sizeof(cache_path), "%s/gamelauncher/heroic", get_xdg_cache_home());
            DIR *cache_dir = opendir(cache_path);
            if (cache_dir) {
                struct dirent *ce;
                while ((ce = readdir(cache_dir))) {
                    if (strstr(ce->d_name, app_id)) {
                        snprintf(cover, sizeof(cover), "%s/%s", cache_path, ce->d_name);
                        break;
                    }
                }
                closedir(cache_dir);
            }
        }
        if (!cover[0]) {
            char *art = kv_get(&covers, app_id);
            if (art) {
                if (strstr(art, "http")) {
                    strncpy(cover_url, art, MAX_PATH - 1);
                } else {
                    strncpy(cover, art, MAX_PATH - 1);
                }
            }
        }
        char run_command[MAX_RUN_CMD];
        snprintf(run_command, sizeof(run_command), "heroic://launch/%s", app_id);
        add_game(app_id, title, "heroic", cover, cover_url, run_command, "");
    }
    closedir(dir);
    kv_free(&titles); kv_free(&covers);
}

int cache_valid() {
    char ts_path[MAX_PATH];
    snprintf(ts_path, sizeof(ts_path), "%s/gamelauncher/cache_ts", get_xdg_cache_home());
    FILE *f = fopen(ts_path, "r");
    if (!f) return 0;
    long cached_ts;
    if (fscanf(f, "%ld", &cached_ts) != 1) { fclose(f); return 0; }
    fclose(f);

    char games_path[MAX_PATH];
    snprintf(games_path, sizeof(games_path), "%s/gamelauncher/games.json", get_xdg_cache_home());
    struct stat gs;
    if (stat(games_path, &gs) != 0) return 0;

    struct stat st;
    const char *data_home = get_xdg_data_home();
    const char *config_home = get_xdg_config_home();

    const char *steam_roots[] = {
        "/Steam", "/.steam/steam",
        "/.var/app/com.valvesoftware.Steam/.local/share/Steam", NULL
    };
    for (int r = 0; steam_roots[r]; r++) {
        char sp[MAX_PATH];
        snprintf(sp, sizeof(sp), "%s%s/steamapps", data_home, steam_roots[r]);
        if (stat(sp, &st) == 0 && st.st_mtime > cached_ts) return 0;
        char vdf_path[MAX_PATH];
        snprintf(vdf_path, sizeof(vdf_path), "%s%s/steamapps/libraryfolders.vdf", data_home, steam_roots[r]);
        if (stat(vdf_path, &st) == 0 && st.st_mtime > cached_ts) return 0;
    }

    const char *lutris_dbs[] = {
        "/lutris/pga.db", "/lutris/lutris.db", "/lutris/db.sqlite", NULL
    };
    for (int i = 0; lutris_dbs[i]; i++) {
        char lp[MAX_PATH];
        snprintf(lp, sizeof(lp), "%s%s", data_home, lutris_dbs[i]);
        if (stat(lp, &st) == 0 && st.st_mtime > cached_ts) return 0;
    }

    char hp[MAX_PATH];
    snprintf(hp, sizeof(hp), "%s/heroic/GamesConfig", config_home);
    if (stat(hp, &st) == 0 && st.st_mtime > cached_ts) return 0;
    snprintf(hp, sizeof(hp), "%s/heroic/sideload_apps/library.json", config_home);
    if (stat(hp, &st) == 0 && st.st_mtime > cached_ts) return 0;

    for (int r = 0; steam_roots[r]; r++) {
        char vdf_path[MAX_PATH];
        snprintf(vdf_path, sizeof(vdf_path), "%s%s/steamapps/libraryfolders.vdf", data_home, steam_roots[r]);
        FILE *f = fopen(vdf_path, "r");
        if (!f) continue;
        fseek(f, 0, SEEK_END);
        long len = ftell(f);
        rewind(f);
        char *content = malloc(len + 1);
        if (!content) { fclose(f); continue; }
        fread(content, 1, len, f);
        content[len] = '\0';
        fclose(f);
        char *p = content;
        while ((p = strstr(p, "\"path\""))) {
            p += 6;
            while (*p && *p != '"') p++;
            if (*p++ != '"') continue;
            char *end = strchr(p, '"');
            if (!end) continue;
            char path_buf[MAX_PATH];
            size_t plen = end - p;
            if (plen >= sizeof(path_buf)) plen = sizeof(path_buf) - 1;
            strncpy(path_buf, p, plen);
            path_buf[plen] = '\0';
            char sa[MAX_PATH];
            snprintf(sa, sizeof(sa), "%s/steamapps", path_buf);
            if (stat(sa, &st) == 0 && st.st_mtime > cached_ts) { free(content); return 0; }
            p = end;
        }
        free(content);
    }

    return 1;
}

int load_cached_games() {
    char path[MAX_PATH];
    snprintf(path, sizeof(path), "%s/gamelauncher/games.json", get_xdg_cache_home());
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char buf[65536];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    if (n <= 0) return 0;
    buf[n] = '\0';
    fwrite(buf, 1, n, stdout);
    return 1;
}

void write_cache() {
    char dir[MAX_PATH];
    snprintf(dir, sizeof(dir), "%s/gamelauncher", get_xdg_cache_home());
    mkdir(dir, 0755);
    char steam_dir[MAX_PATH];
    snprintf(steam_dir, sizeof(steam_dir), "%s/steam", dir);
    mkdir(steam_dir, 0755);
    char heroic_dir[MAX_PATH];
    snprintf(heroic_dir, sizeof(heroic_dir), "%s/heroic", dir);
    mkdir(heroic_dir, 0755);

    char ts_path[MAX_PATH];
    snprintf(ts_path, sizeof(ts_path), "%s/cache_ts", dir);
    FILE *f = fopen(ts_path, "w");
    if (f) { fprintf(f, "%ld\n", (long)time(NULL)); fclose(f); }

    char games_path[MAX_PATH];
    snprintf(games_path, sizeof(games_path), "%s/games.json", dir);
    f = fopen(games_path, "w");
    if (!f) return;
    fprintf(f, "[\n");
    for (int i = 0; i < ga.count; i++) {
        Game *g = &ga.games[i];
        fprintf(f, "  {\n");
        fprintf(f, "    \"id\": \"");
        for (const char *s = g->id; *s; s++) {
            if (*s == '"' || *s == '\\') putc('\\', f);
            putc(*s, f);
        }
        fprintf(f, "\",\n");
        fprintf(f, "    \"name\": \"");
        for (const char *s = g->name; *s; s++) {
            if (*s == '"' || *s == '\\') putc('\\', f);
            putc(*s, f);
        }
        fprintf(f, "\",\n");
        fprintf(f, "    \"runner\": \"");
        for (const char *s = g->runner; *s; s++) {
            if (*s == '"' || *s == '\\') putc('\\', f);
            putc(*s, f);
        }
        fprintf(f, "\",\n");
        fprintf(f, "    \"cover\": \"");
        for (const char *s = g->cover; *s; s++) {
            if (*s == '"' || *s == '\\') putc('\\', f);
            putc(*s, f);
        }
        fprintf(f, "\",\n");
        fprintf(f, "    \"cover_url\": \"");
        for (const char *s = g->cover_url; *s; s++) {
            if (*s == '"' || *s == '\\') putc('\\', f);
            putc(*s, f);
        }
        fprintf(f, "\",\n");
        fprintf(f, "    \"run_command\": \"");
        for (const char *s = g->run_command; *s; s++) {
            if (*s == '"' || *s == '\\') putc('\\', f);
            putc(*s, f);
        }
        fprintf(f, "\",\n");
        fprintf(f, "    \"slug\": \"");
        for (const char *s = g->slug; *s; s++) {
            if (*s == '"' || *s == '\\') putc('\\', f);
            putc(*s, f);
        }
        fprintf(f, "\"\n");
        fprintf(f, "  }%s\n", i < ga.count - 1 ? "," : "");
    }
    fprintf(f, "]\n");
    fclose(f);
}

int compare_names(const void *a, const void *b) {
    return strcasecmp(((const Game *)a)->name, ((const Game *)b)->name);
}

int main(int argc, char *argv[]) {
    int use_steam = 0, use_heroic = 0, use_lutris = 0, force = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--steam") == 0) use_steam = 1;
        if (strcmp(argv[i], "--heroic") == 0) use_heroic = 1;
        if (strcmp(argv[i], "--lutris") == 0) use_lutris = 1;
        if (strcmp(argv[i], "--no-lutris") == 0) use_lutris = 0;
        if (strcmp(argv[i], "--force") == 0) force = 1;
    }

    if (!force && cache_valid()) {
        if (load_cached_games()) return 0;
    }

    init_games();
    if (use_lutris) { scan_lutris(); scan_lutris_manual_files(); }
    if (use_steam) { scan_steam(); scan_steam_shortcuts(); }
    if (use_heroic) { scan_heroic(); }
    qsort(ga.games, ga.count, sizeof(Game), compare_names);
    print_json();
    write_cache();
    free_games();
    return 0;
}
