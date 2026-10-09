/*
 * noctalia-audio-monitor
 *
 * A tiny PipeWire helper that reports whether the default audio sink is
 * currently playing sound. It creates a passive monitor capture stream on the
 * default sink, measures the audio level, and prints:
 *   "active" when the level exceeds the threshold
 *   "idle"   when the level stays below the threshold for the hysteresis window
 *
 * Usage: noctalia-audio-monitor [--threshold T] [--hysteresis-ms N] [--debug]
 */

#include <pipewire/pipewire.h>
#include <pipewire/extensions/metadata.h>
#include <spa/param/audio/format-utils.h>
#include <spa/param/props.h>
#include <spa/utils/result.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <errno.h>
#include <getopt.h>
#include <stdint.h>
#include <stdbool.h>
#include <math.h>

#define DEFAULT_THRESHOLD    0.001f
#define DEFAULT_HYSTERESIS_MS 500
#define DEFAULT_SAMPLE_RATE  48000
#define NSEC_PER_SEC         1000000000ULL
#define NSEC_PER_MSEC        1000000ULL

struct context {
    struct pw_main_loop *loop;
    struct pw_context *pw_context;
    struct pw_core *core;
    struct pw_registry *registry;
    struct spa_hook registry_listener;

    struct pw_metadata *metadata;
    struct spa_hook metadata_listener;
    uint32_t metadata_id;
    char *default_sink;

    struct pw_stream *stream;
    struct spa_hook stream_listener;
    struct spa_audio_info_raw format;
    bool format_set;

    float threshold;
    int hysteresis_ms;
    bool debug;

    bool reported_active;
    float smoothed_level;
    struct spa_source *timer;
};

static struct context g_ctx;

/* ---------- helpers ---------- */

static void report_state(struct context *ctx, bool active)
{
    if (active == ctx->reported_active)
        return;

    printf("%s\n", active ? "active" : "idle");
    fflush(stdout);
    ctx->reported_active = active;
}

static void nsec_to_timespec(uint64_t nsec, struct timespec *ts)
{
    ts->tv_sec = (time_t)(nsec / NSEC_PER_SEC);
    ts->tv_nsec = (long)(nsec % NSEC_PER_SEC);
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
    ctx->timer = NULL;
    report_state(ctx, false);
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
    nsec_to_timespec(target_ns, &target);
    pw_loop_update_timer(pw_main_loop_get_loop(ctx->loop), ctx->timer,
                         &target, NULL, false);
}

static void update_state(struct context *ctx)
{
    bool active = ctx->smoothed_level >= ctx->threshold;

    if (active) {
        cancel_idle_timer(ctx);
        report_state(ctx, true);
    } else {
        /* Level dropped. If we were active, start hysteresis. */
        if (ctx->reported_active)
            arm_idle_timer(ctx);
        else
            report_state(ctx, false);
    }
}

/* ---------- JSON helper (very small, fixed format) ---------- */

static char *extract_name_from_json(const char *json)
{
    const char *key = "\"name\"";
    const char *p = strstr(json, key);
    if (!p)
        return NULL;
    p += strlen(key);
    while (*p && (*p == ' ' || *p == ':' || *p == '"'))
        p++;
    if (!*p)
        return NULL;

    const char *end = p;
    while (*end && *end != '"')
        end++;
    if (end == p)
        return NULL;

    size_t len = (size_t)(end - p);
    char *name = malloc(len + 1);
    if (!name)
        return NULL;
    memcpy(name, p, len);
    name[len] = '\0';
    return name;
}

/* ---------- stream ---------- */

static void stream_process(void *userdata)
{
    struct context *ctx = userdata;
    struct pw_buffer *b;

    if (!(b = pw_stream_dequeue_buffer(ctx->stream)))
        return;

    struct spa_buffer *buf = b->buffer;
    float *samples = NULL;
    uint32_t n_samples = 0;

    if (buf->datas[0].data) {
        samples = buf->datas[0].data;
        n_samples = buf->datas[0].chunk->size / sizeof(float);
    }

    float peak = 0.0f;
    if (samples && n_samples > 0) {
        for (uint32_t i = 0; i < n_samples; i++) {
            float s = fabsf(samples[i]);
            if (s > peak)
                peak = s;
        }
    }

    /* Exponential smoothing for a less jittery response. */
    ctx->smoothed_level += (peak - ctx->smoothed_level) * 0.3f;

    if (ctx->debug && peak > 0.0f)
        fprintf(stderr, "[audio-monitor] peak=%.6f smoothed=%.6f\n",
                peak, ctx->smoothed_level);

    update_state(ctx);
    pw_stream_queue_buffer(ctx->stream, b);
}

static void stream_param_changed(void *userdata, uint32_t id, const struct spa_pod *param)
{
    struct context *ctx = userdata;

    if (param == NULL || id != SPA_PARAM_Format)
        return;

    spa_format_audio_raw_parse(param, &ctx->format);
    ctx->format_set = true;

    if (ctx->debug)
        fprintf(stderr, "[audio-monitor] format: rate=%d channels=%d\n",
                ctx->format.rate, ctx->format.channels);
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .param_changed = stream_param_changed,
    .process = stream_process,
};

static void connect_monitor_stream(struct context *ctx)
{
    if (!ctx->default_sink)
        return;

    if (ctx->stream) {
        pw_stream_disconnect(ctx->stream);
        pw_stream_destroy(ctx->stream);
        spa_hook_remove(&ctx->stream_listener);
        ctx->stream = NULL;
    }

    const struct spa_pod *params[1];
    uint8_t buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));

    params[0] = spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat,
        &SPA_AUDIO_INFO_RAW_INIT(
            .format = SPA_AUDIO_FORMAT_F32,
            .channels = 2,
            .rate = DEFAULT_SAMPLE_RATE,
            .position = { SPA_AUDIO_CHANNEL_FL, SPA_AUDIO_CHANNEL_FR }
        ));

    struct pw_properties *props = pw_properties_new(
        PW_KEY_MEDIA_TYPE,        "Audio",
        PW_KEY_MEDIA_CATEGORY,    "Capture",
        PW_KEY_MEDIA_CLASS,       "Stream/Input/Audio",
        PW_KEY_STREAM_MONITOR,    "true",
        PW_KEY_STREAM_CAPTURE_SINK, "true",
        PW_KEY_NODE_PASSIVE,      "true",
        PW_KEY_TARGET_OBJECT,     ctx->default_sink,
        PW_KEY_NODE_NAME,         "noctalia-audio-monitor",
        PW_KEY_MEDIA_NAME,        "Noctalia Audio Sticker Monitor",
        NULL);

    ctx->stream = pw_stream_new(ctx->core, "noctalia-audio-monitor", props);
    pw_stream_add_listener(ctx->stream, &ctx->stream_listener, &stream_events, ctx);
    pw_stream_connect(ctx->stream,
                      PW_DIRECTION_INPUT,
                      PW_ID_ANY,
                      PW_STREAM_FLAG_AUTOCONNECT |
                      PW_STREAM_FLAG_MAP_BUFFERS |
                      PW_STREAM_FLAG_RT_PROCESS,
                      params, 1);

    if (ctx->debug)
        fprintf(stderr, "[audio-monitor] connected monitor to %s\n", ctx->default_sink);
}

/* ---------- metadata ---------- */

static int metadata_property(void *data, uint32_t subject,
                             const char *key, const char *type,
                             const char *value)
{
    (void)subject;
    (void)type;
    struct context *ctx = data;

    if (!key || !value)
        return 0;
    if (strcmp(key, "default.audio.sink") != 0)
        return 0;

    char *name = extract_name_from_json(value);
    if (!name)
        return 0;

    if (ctx->debug)
        fprintf(stderr, "[audio-monitor] default sink changed: %s\n", name);

    free(ctx->default_sink);
    ctx->default_sink = name;

    connect_monitor_stream(ctx);
    return 0;
}

static const struct pw_metadata_events metadata_events = {
    PW_VERSION_METADATA_EVENTS,
    .property = metadata_property,
};

/* ---------- registry ---------- */

static void registry_global(void *data, uint32_t id, uint32_t permissions,
                            const char *type, uint32_t version,
                            const struct spa_dict *props)
{
    (void)permissions;
    struct context *ctx = data;

    if (strcmp(type, PW_TYPE_INTERFACE_Metadata) != 0)
        return;

    const char *name = spa_dict_lookup(props, "metadata.name");
    if (!name || strcmp(name, "default") != 0)
        return;

    /* Already bound? */
    if (ctx->metadata)
        return;

    ctx->metadata_id = id;
    ctx->metadata = pw_registry_bind(ctx->registry, id, type, version, 0);
    if (!ctx->metadata)
        return;

    pw_metadata_add_listener(ctx->metadata, &ctx->metadata_listener,
                             &metadata_events, ctx);
}

static void registry_global_remove(void *data, uint32_t id)
{
    struct context *ctx = data;
    if (ctx->metadata_id != id)
        return;

    spa_hook_remove(&ctx->metadata_listener);
    pw_proxy_destroy((struct pw_proxy *)ctx->metadata);
    ctx->metadata = NULL;
    ctx->metadata_id = 0;
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
            "Usage: %s [--threshold T] [--hysteresis-ms N] [--debug]\n"
            "  --threshold T    audio level threshold (0.0-1.0), default %.4f\n"
            "  --hysteresis-ms N  idle delay in ms, default %d\n",
            prog, DEFAULT_THRESHOLD, DEFAULT_HYSTERESIS_MS);
}

int main(int argc, char *argv[])
{
    memset(&g_ctx, 0, sizeof(g_ctx));
    g_ctx.threshold = DEFAULT_THRESHOLD;
    g_ctx.hysteresis_ms = DEFAULT_HYSTERESIS_MS;
    g_ctx.smoothed_level = 0.0f;

    static struct option long_options[] = {
        { "threshold",     required_argument, 0, 't' },
        { "hysteresis-ms", required_argument, 0, 'h' },
        { "debug",         no_argument,       0, 'd' },
        { "help",          no_argument,       0, '?' },
        { 0, 0, 0, 0 }
    };

    int c;
    while ((c = getopt_long(argc, argv, "t:h:d", long_options, NULL)) != -1) {
        switch (c) {
        case 't':
            g_ctx.threshold = (float)atof(optarg);
            if (g_ctx.threshold < 0.0f)
                g_ctx.threshold = 0.0f;
            if (g_ctx.threshold > 1.0f)
                g_ctx.threshold = 1.0f;
            break;
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

    pw_init(&argc, &argv);

    g_ctx.loop = pw_main_loop_new(NULL);
    if (!g_ctx.loop) {
        fprintf(stderr, "Failed to create PipeWire main loop\n");
        return 1;
    }

    g_ctx.pw_context = pw_context_new(pw_main_loop_get_loop(g_ctx.loop), NULL, 0);
    if (!g_ctx.pw_context) {
        fprintf(stderr, "Failed to create PipeWire context\n");
        return 1;
    }

    g_ctx.core = pw_context_connect(g_ctx.pw_context, NULL, 0);
    if (!g_ctx.core) {
        fprintf(stderr, "Failed to connect to PipeWire: %s\n", strerror(errno));
        return 1;
    }

    g_ctx.registry = pw_core_get_registry(g_ctx.core, PW_VERSION_REGISTRY, 0);
    if (!g_ctx.registry) {
        fprintf(stderr, "Failed to get PipeWire registry\n");
        return 1;
    }

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

    /* Print initial idle state so the consumer knows we're alive. */
    printf("idle\n");
    fflush(stdout);

    pw_main_loop_run(g_ctx.loop);

    /* Cleanup */
    cancel_idle_timer(&g_ctx);

    if (g_ctx.stream) {
        spa_hook_remove(&g_ctx.stream_listener);
        pw_stream_disconnect(g_ctx.stream);
        pw_stream_destroy(g_ctx.stream);
    }

    if (g_ctx.metadata) {
        spa_hook_remove(&g_ctx.metadata_listener);
        pw_proxy_destroy((struct pw_proxy *)g_ctx.metadata);
    }

    pw_proxy_destroy((struct pw_proxy *)g_ctx.registry);
    pw_core_disconnect(g_ctx.core);
    pw_context_destroy(g_ctx.pw_context);
    pw_main_loop_destroy(g_ctx.loop);
    pw_deinit();

    free(g_ctx.default_sink);

    return 0;
}
