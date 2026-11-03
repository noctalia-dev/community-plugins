/*
 * noctalia-audio-monitor
 *
 * Monitors PipeWire output streams and prints one line on every change:
 *   "active" when any output stream is in the running state
 *   "idle"   when all output streams are idle/suspended/paused
 *
 * This avoids false positives from applications that keep an output stream
 * open while paused/idle (e.g. Brave, Spotify in "init" state). We care about
 * streams that are actually playing audio, not just open streams.
 *
 * The plugin service reads those lines with noctalia.runStream(). A pid file
 * with an exclusive lock keeps a single monitor per session, so a second copy
 * exits immediately instead of reporting the same transitions twice.
 *
 * Usage: noctalia-audio-monitor [--hysteresis-ms N] [--debug]
 */

#include <pipewire/pipewire.h>
#include <spa/utils/result.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <errno.h>
#include <getopt.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/prctl.h>

#define DEFAULT_HYSTERESIS_MS 500
#define MAX_STREAMS 32
#define NSEC_PER_SEC 1000000000ULL
#define NSEC_PER_MSEC 1000000ULL

static char *g_pid_file = NULL;

struct stream_node {
    uint32_t id;
    struct pw_node *proxy;
    struct spa_hook listener;
    enum pw_node_state state;
    bool used;
};

struct context {
    struct pw_main_loop *loop;
    struct pw_context *pw_context;
    struct pw_core *core;
    struct pw_registry *registry;
    struct spa_hook registry_listener;

    struct stream_node streams[MAX_STREAMS];

    int hysteresis_ms;
    bool debug;

    bool reported_active;
    struct spa_source *timer;
};

static struct context g_ctx;

/* ---------- helpers ---------- */

static char *get_default_pid_file(void)
{
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    const char *dir = runtime ? runtime : "/tmp";
    const char *suffix = "/noctalia-audio-monitor.pid";
    size_t len = strlen(dir) + strlen(suffix) + 1;
    char *path = malloc(len);
    if (path)
        snprintf(path, len, "%s%s", dir, suffix);
    return path;
}

static int acquire_pid_file(const char *path)
{
    int fd = open(path, O_RDWR | O_CREAT, 0644);
    if (fd < 0)
        return -1;

    /* The descriptor stays open for the process lifetime, so the lock is
     * released by the kernel when the monitor exits, even on a crash. */
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        close(fd);
        return -1;
    }

    ftruncate(fd, 0);
    dprintf(fd, "%d\n", getpid());
    return fd;
}

static void remove_pid_file(void)
{
    if (g_pid_file)
        unlink(g_pid_file);
}

static void report_state(struct context *ctx, bool active, bool force)
{
    if (!force && active == ctx->reported_active)
        return;

    const char *line = active ? "active" : "idle";

    printf("%s\n", line);
    fflush(stdout);
    ctx->reported_active = active;
}

static void cancel_idle_timer(struct context *ctx)
{
    if (ctx->timer) {
        pw_loop_destroy_source(pw_main_loop_get_loop(ctx->loop), ctx->timer);
        ctx->timer = NULL;
    }
}

static void idle_timer_cb(void *userdata, uint64_t expirations)
{
    (void)expirations;
    struct context *ctx = userdata;
    if (ctx->debug)
        fprintf(stderr, "[audio-monitor] idle timer fired\n");
    ctx->timer = NULL;
    report_state(ctx, false, false);
}

static void arm_idle_timer(struct context *ctx)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);

    if (!ctx->timer) {
        ctx->timer = pw_loop_add_timer(pw_main_loop_get_loop(ctx->loop),
                                       idle_timer_cb, ctx);
    }

    uint64_t target_ns = (uint64_t)ts.tv_sec * NSEC_PER_SEC + (uint64_t)ts.tv_nsec;
    target_ns += (uint64_t)ctx->hysteresis_ms * NSEC_PER_MSEC;
    struct timespec target;
    target.tv_sec = (time_t)(target_ns / NSEC_PER_SEC);
    target.tv_nsec = (long)(target_ns % NSEC_PER_SEC);
    pw_loop_update_timer(pw_main_loop_get_loop(ctx->loop), ctx->timer,
                         &target, NULL, true);
}

static void update_state(struct context *ctx)
{
    bool active = false;

    for (int i = 0; i < MAX_STREAMS; i++) {
        if (ctx->streams[i].used && ctx->streams[i].state == PW_NODE_STATE_RUNNING) {
            active = true;
            break;
        }
    }

    if (ctx->debug)
        fprintf(stderr, "[audio-monitor] update_state active=%d reported=%d\n",
                active, ctx->reported_active);

    if (active) {
        cancel_idle_timer(ctx);
        report_state(ctx, true, false);
    } else {
        if (ctx->reported_active)
            arm_idle_timer(ctx);
        else
            report_state(ctx, false, false);
    }
}

/* ---------- node state ---------- */

static const char *node_state_name(enum pw_node_state state)
{
    switch (state) {
    case PW_NODE_STATE_RUNNING:   return "running";
    case PW_NODE_STATE_IDLE:      return "idle";
    case PW_NODE_STATE_SUSPENDED: return "suspended";
    case PW_NODE_STATE_CREATING:  return "creating";
    case PW_NODE_STATE_ERROR:     return "error";
    default:                      return "unknown";
    }
}

static bool is_output_stream(const struct spa_dict *props)
{
    const char *media_class = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
    return media_class && strcmp(media_class, "Stream/Output/Audio") == 0;
}

static void stream_info_cb(void *data, const struct pw_node_info *info)
{
    struct stream_node *stream = data;
    if (!info)
        return;

    stream->state = info->state;
    if (g_ctx.debug)
        fprintf(stderr, "[audio-monitor] stream %u state=%s\n",
                stream->id, node_state_name(info->state));

    update_state(&g_ctx);
}

static const struct pw_node_events stream_node_events = {
    PW_VERSION_NODE_EVENTS,
    .info = stream_info_cb,
};

/* ---------- registry ---------- */

static struct stream_node *find_stream_slot(struct context *ctx)
{
    for (int i = 0; i < MAX_STREAMS; i++) {
        if (!ctx->streams[i].used)
            return &ctx->streams[i];
    }
    return NULL;
}

static struct stream_node *find_stream_by_id(struct context *ctx, uint32_t id)
{
    for (int i = 0; i < MAX_STREAMS; i++) {
        if (ctx->streams[i].used && ctx->streams[i].id == id)
            return &ctx->streams[i];
    }
    return NULL;
}

static void add_stream(struct context *ctx, uint32_t id)
{
    struct stream_node *stream = find_stream_slot(ctx);
    if (!stream)
        return;

    stream->proxy = pw_registry_bind(ctx->registry, id, PW_TYPE_INTERFACE_Node,
                                     PW_VERSION_NODE, 0);
    if (!stream->proxy)
        return;

    stream->id = id;
    stream->state = PW_NODE_STATE_CREATING;
    stream->used = true;

    pw_node_add_listener(stream->proxy, &stream->listener,
                         &stream_node_events, stream);
}

static void registry_global(void *data, uint32_t id, uint32_t permissions,
                            const char *type, uint32_t version,
                            const struct spa_dict *props)
{
    (void)permissions;
    (void)version;
    struct context *ctx = data;

    if (strcmp(type, PW_TYPE_INTERFACE_Node) != 0)
        return;

    if (find_stream_by_id(ctx, id))
        return;

    if (!is_output_stream(props))
        return;

    add_stream(ctx, id);
}

static void registry_global_remove(void *data, uint32_t id)
{
    struct context *ctx = data;

    struct stream_node *stream = find_stream_by_id(ctx, id);
    if (!stream)
        return;

    spa_hook_remove(&stream->listener);
    pw_proxy_destroy((struct pw_proxy *)stream->proxy);
    memset(stream, 0, sizeof(*stream));
    update_state(ctx);
}

static const struct pw_registry_events registry_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = registry_global,
    .global_remove = registry_global_remove,
};

/* ---------- lifecycle ---------- */

static void on_signal(int sig)
{
    (void)sig;
    pw_main_loop_quit(g_ctx.loop);
}

static void print_usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s [--hysteresis-ms N] [--debug]\n"
            "  --hysteresis-ms N  delay before reporting idle, in ms, default %d\n"
            "  --debug            log node state transitions to stderr\n",
            prog, DEFAULT_HYSTERESIS_MS);
}

int main(int argc, char *argv[])
{
    memset(&g_ctx, 0, sizeof(g_ctx));
    g_ctx.hysteresis_ms = DEFAULT_HYSTERESIS_MS;

    static struct option long_options[] = {
        { "hysteresis-ms", required_argument, 0, 'h' },
        { "debug",         no_argument,       0, 'd' },
        { "help",          no_argument,       0, '?' },
        { 0, 0, 0, 0 }
    };

    int c;
    while ((c = getopt_long(argc, argv, "h:d", long_options, NULL)) != -1) {
        switch (c) {
        case 'h':
            g_ctx.hysteresis_ms = atoi(optarg);
            if (g_ctx.hysteresis_ms < 0)
                g_ctx.hysteresis_ms = 0;
            break;
        case 'd':
            g_ctx.debug = true;
            break;
        default:
            print_usage(argv[0]);
            return 1;
        }
    }

    g_pid_file = get_default_pid_file();
    if (g_pid_file && acquire_pid_file(g_pid_file) < 0) {
        if (g_ctx.debug)
            fprintf(stderr, "[audio-monitor] another instance is already running\n");
        free(g_pid_file);
        g_pid_file = NULL;
        return 0;
    }

    /* The service runs this monitor from a small shell loop. When that shell
     * goes away (plugin reload, shell restart) the kernel sends us SIGTERM, so
     * no orphan keeps holding the pid lock. */
    prctl(PR_SET_PDEATHSIG, SIGTERM);
    if (getppid() == 1) {
        remove_pid_file();
        free(g_pid_file);
        return 0;
    }

    pw_init(&argc, &argv);

    g_ctx.loop = pw_main_loop_new(NULL);
    g_ctx.pw_context = pw_context_new(pw_main_loop_get_loop(g_ctx.loop), NULL, 0);
    g_ctx.core = pw_context_connect(g_ctx.pw_context, NULL, 0);
    if (!g_ctx.core) {
        fprintf(stderr, "[audio-monitor] failed to connect to PipeWire: %s\n", strerror(errno));
        return 1;
    }

    g_ctx.registry = pw_core_get_registry(g_ctx.core, PW_VERSION_REGISTRY, 0);
    pw_registry_add_listener(g_ctx.registry, &g_ctx.registry_listener,
                             &registry_events, &g_ctx);

    pw_core_sync(g_ctx.core, PW_ID_CORE, 0);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    /* Initial idle until streams report their state. */
    report_state(&g_ctx, false, true);

    pw_main_loop_run(g_ctx.loop);

    /* Cleanup */
    cancel_idle_timer(&g_ctx);

    for (int i = 0; i < MAX_STREAMS; i++) {
        if (!g_ctx.streams[i].used)
            continue;
        spa_hook_remove(&g_ctx.streams[i].listener);
        pw_proxy_destroy((struct pw_proxy *)g_ctx.streams[i].proxy);
    }

    pw_proxy_destroy((struct pw_proxy *)g_ctx.registry);
    pw_core_disconnect(g_ctx.core);
    pw_context_destroy(g_ctx.pw_context);
    pw_main_loop_destroy(g_ctx.loop);
    pw_deinit();

    remove_pid_file();
    free(g_pid_file);

    return 0;
}
