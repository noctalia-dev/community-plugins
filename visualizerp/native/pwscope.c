/*
 * pwscope - PipeWire time-domain capture for the Noctalia "Scope" plugin.
 *
 * Taps an audio sink, reduces the stream to per-column signed min/max
 * envelopes and prints one text frame per line on stdout:
 *
 *   F <seq> <rms> <peak> <flags> <min0> <max0> <min1> <max1> ...
 *
 * Amplitudes are unsigned 0..255 with 128 as zero. Lines beginning with '#'
 * are diagnostics (runStream does not capture stderr, so diagnostics travel
 * over stdout and are forwarded to the Noctalia log by the service entry).
 */

#define _GNU_SOURCE

#include <errno.h>
#include <time.h>
#include <math.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <pipewire/pipewire.h>
#include <pipewire/stream.h>
#include <pipewire/extensions/metadata.h>
#include <spa/param/audio/format-utils.h>
#include <spa/param/buffers.h>
#include <spa/param/props.h>
#include <spa/pod/builder.h>
#include <spa/utils/dict.h>
#include <spa/utils/hook.h>

#define APP_ID "pwscope"
#define APP_NAME "PipeScope"
#define NODE_NAME "pwscope-capture"
#define NODE_DESC "PipeScope capture"

#define MAX_COLS 256
#define RING_BITS 17
#define RING_SIZE (1u << RING_BITS)
#define RING_MASK (RING_SIZE - 1u)
#define MAX_LINE (32 + MAX_COLS * 2 * 5)
#define WINDOW_SAMPLES 16

/* Trigger pipeline tuning, mirroring ReAmped's waveform.rs. */
#define MIN_FREQ 40.0f
#define MAX_FREQ 2000.0f
#define YIN_THRESHOLD 0.15f
#define YIN_WINDOW 2048
#define FIR_NUM_TAPS 31
#define TRIGGER_CUTOFF_MULT 2.5f
#define TRIGGER_CUTOFF_MIN 120.0f
#define TRIGGER_CUTOFF_MAX 2000.0f
#define FIR_REDESIGN_HYSTERESIS 10.0f
#define PERIOD_MULTIPLIER 4
#define MIN_PERIOD_SAMPLES 22.0f
#define MIN_WINDOW_SECS 0.015f

/* Samples pulled out of the ring for one trigger pass. Large enough for the
 * YIN window plus a four-period extraction at the lowest tracked pitch. */
#define ANALYSIS_SIZE 4096
#define YIN_LAGS (ANALYSIS_SIZE / 2 + 1)
#define PITCH_LOG_NS 2000000000ull

/* Ambient floor below which a window is considered silent. The sink may carry
 * a small noise floor from a microphone loopback or an unmuted input, and the
 * widget should sit flat instead of jittering forever. */
static const float DEFAULT_GATE = 0.0025f;

/* ------------------------------------------------------------------ config */

#define MAX_CANDIDATES 32

struct config {
	const char *target;
	int cols;
	double fps;
	double sensitivity;
	double smoothing;
	double gate;
};

struct state {
	struct pw_main_loop *loop;
	struct pw_context *context;
	struct pw_core *core;
	struct pw_registry *registry;
	struct pw_metadata *metadata;
	struct pw_stream *stream;
	struct spa_hook registry_listener;
	struct spa_hook core_listener;
	struct spa_hook stream_listener;
	struct spa_hook metadata_listener;

	struct config cfg;

	/* Candidate capture targets, filled during registry enumeration. */
	char sinks[MAX_CANDIDATES][256];
	int n_sinks;
	char monitors[MAX_CANDIDATES][256];
	int n_monitors;
	char default_sink[256];

	bool have_node;
	bool resolved;
	char node_name[256];

	uint32_t seq;

	uint32_t rate;
	uint32_t channels;
	bool format_ready;

	uint64_t last_emit_ns;
	uint64_t period_ns;

	float ring[RING_SIZE];
	uint32_t ring_count;
	uint32_t ring_head;

	double dc_mean;

	float smooth_min[MAX_COLS];
	float smooth_max[MAX_COLS];
	bool smooth_primed;

	float peak_hold;
	float raw_peak;
	float rms_level;

	/* Synchronised-oscilloscope pipeline, a port of the trigger pipeline in
	 * ReAmped's player-core/src/viz/waveform.rs. */
	float last_period;
	float pitch_hz;
	float last_window[ANALYSIS_SIZE];
	uint32_t last_window_len;
	float fir_coeffs[FIR_NUM_TAPS];
	float fir_cutoff;
	bool fir_valid;
	float mono[ANALYSIS_SIZE];
	float filtered[ANALYSIS_SIZE];
	float yin_d[YIN_LAGS];
	float yin_cmnd[YIN_LAGS];
	float sync[ANALYSIS_SIZE];
	uint32_t sync_len;
	float resampled[MAX_COLS * 2];
	uint64_t last_pitch_log_ns;

	uint64_t frames_received;
	uint64_t frames_emitted;
	uint64_t underruns;

	uint8_t out_min[MAX_COLS];
	uint8_t out_max[MAX_COLS];
	uint8_t out_rms;
	uint8_t out_peak;
	bool out_silent;
};

/* --------------------------------------------------------------- utilities */

static void note(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	fputs("# ", stdout);
	vfprintf(stdout, fmt, ap);
	fputc('\n', stdout);
	va_end(ap);
	fflush(stdout);
}

static void fail(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	fputs("#error ", stderr);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
}

static const char *prop_str(const struct spa_dict *props, const char *key)
{
	if (props == NULL)
		return NULL;

	return spa_dict_lookup(props, key);
}

/* Ring buffer of mono samples. */
static void ring_push(struct state *st, float sample)
{
	st->ring[st->ring_head] = sample;
	st->ring_head = (st->ring_head + 1u) & RING_MASK;
	if (st->ring_count < RING_SIZE)
		st->ring_count++;
}

/* Reads the i-th most recent sample without consuming it. */
static float ring_peek(const struct state *st, uint32_t back)
{
	if (back >= st->ring_count)
		return 0.0f;

	return st->ring[(st->ring_head - 1u - back) & RING_MASK];
}

static const struct pw_metadata_events metadata_events;

static bool name_matches(const char *pattern, const char *name)
{
	size_t len;

	if (pattern == NULL || name == NULL)
		return false;

	len = strlen(pattern);
	if (len == 0)
		return true;

	/* Allow a trailing '*' for convenience. */
	if (pattern[len - 1] == '*')
		return strncmp(name, pattern, len - 1) == 0;

	return strcmp(pattern, name) == 0;
}

static void remember(char list[][256], int *count, const char *name)
{
	int i;

	for (i = 0; i < *count; i++)
		if (strcmp(list[i], name) == 0)
			return;

	if (*count >= MAX_CANDIDATES)
		return;

	snprintf(list[*count], 256, "%s", name);
	(*count)++;
}

static void registry_global(void *data, uint32_t id, uint32_t permissions,
		const char *type, uint32_t version, const struct spa_dict *props)
{
	struct state *st = data;
	const char *name, *cls;

	(void)id;
	(void)permissions;

	if (type == NULL)
		return;

	if (strcmp(type, PW_TYPE_INTERFACE_Metadata) == 0) {
		const char *mname = prop_str(props, "metadata.name");

		/* Only the session-manager "default" metadata carries
		 * default.audio.sink, and binding it is harmless. */
		if (mname == NULL || strcmp(mname, "default") != 0)
			return;
		if (st->metadata != NULL)
			return;

		st->metadata = pw_registry_bind(st->registry, id,
				PW_TYPE_INTERFACE_Metadata, PW_VERSION_METADATA, 0);
		if (st->metadata == NULL)
			return;
		pw_metadata_add_listener(st->metadata, &st->metadata_listener,
					 &metadata_events, st);
		return;
	}

	if (strcmp(type, PW_TYPE_INTERFACE_Node) != 0)
		return;

	name = prop_str(props, "node.name");
	cls = prop_str(props, "media.class");
	if (name == NULL || cls == NULL)
		return;

	if (strcmp(cls, "Audio/Sink") == 0) {
		remember(st->sinks, &st->n_sinks, name);
	} else if (strcmp(cls, "Audio/Source") == 0) {
		size_t len = strlen(name);

		if (len > 8 && strcmp(name + len - 8, ".monitor") == 0)
			remember(st->monitors, &st->n_monitors, name);
	}
}

static const struct pw_registry_events registry_events = {
	PW_VERSION_REGISTRY_EVENTS,
	.global = registry_global,
};

/* The session manager publishes the active output as a JSON blob:
 * {"name":"alsa_output.…sink"}. Pull the name out of it. */
static int metadata_property(void *data, uint32_t subject, const char *key,
		const char *type, const char *value)
{
	struct state *st = data;
	const char *name, *end;

	(void)subject;
	(void)type;

	if (key == NULL || value == NULL)
		return 0;

	if (strcmp(key, "default.audio.sink") != 0)
		return 0;

	name = strstr(value, "\"name\"");
	if (name == NULL)
		return 0;

	name = strchr(name + 6, '"');
	if (name == NULL)
		return 0;
	name++;

	end = strchr(name, '"');
	if (end == NULL || (size_t)(end - name) >= sizeof(st->default_sink))
		return 0;

	memcpy(st->default_sink, name, (size_t)(end - name));
	st->default_sink[end - name] = '\0';
	note("default sink: %s", st->default_sink);

	return 0;
}

static const struct pw_metadata_events metadata_events = {
	PW_VERSION_METADATA_EVENTS,
	.property = metadata_property,
};

static void core_done(void *data, uint32_t id, int seq)
{
	struct state *st = data;

	(void)id;
	(void)seq;

	/* Any 'done' means the server caught up with our sync. */
	st->resolved = true;
}

static void core_error(void *data, uint32_t id, int seq, int res,
		const char *message)
{
	struct state *st = data;

	(void)seq;

	if (id == PW_ID_CORE)
		note("core error %d: %s", res, message);
	st->underruns++;
}

/* ------------------------------------------------------------ audio intake */

static void consume_mono(struct state *st, const float *src, uint32_t samples)
{
	uint32_t i;

	for (i = 0; i < samples; i++) {
		/* DC removal. Music mixes are usually near zero-mean, but a
		 * sink fed by a hardware loopback can hold a real offset that
		 * would otherwise push the trace off-centre. */
		st->dc_mean += (src[i] - st->dc_mean) * 1e-4;
		ring_push(st, src[i] - (float)st->dc_mean);
	}
}

static void consume_buffer(struct state *st, struct spa_buffer *buf)
{
	uint32_t d;

	for (d = 0; d < buf->n_datas; d++) {
		struct spa_data *data = &buf->datas[d];
		const float *src;
		uint32_t offset, size, frames, c;

		if (data->data == NULL || data->chunk == NULL)
			continue;

		offset = data->chunk->offset;
		size = data->chunk->size;

		if (size == 0 || data->maxsize < offset + size)
			continue;

		src = (const float *)((uint8_t *)data->data + offset);
		frames = size / (sizeof(float) * st->channels);

		/* Downmix to mono by averaging channels. */
		if (st->channels == 1) {
			consume_mono(st, src, frames);
		} else {
			uint32_t f;
			float accum[WINDOW_SAMPLES * 8];

			if (frames > sizeof(accum) / sizeof(accum[0]))
				frames = sizeof(accum) / sizeof(accum[0]);

			for (f = 0; f < frames; f++) {
				float sum = 0.0f;

				for (c = 0; c < st->channels; c++)
					sum += src[f * st->channels + c];
				accum[f] = sum / (float)st->channels;
			}
			consume_mono(st, accum, frames);
		}
	}
}

/* ---------------------------------------------------------- frame reducing */

/* --------------------------------------------------------- trigger pipeline */

/*
 * Port of the synchronised oscilloscope trigger from ReAmped's
 * player-core/src/viz/waveform.rs, so the displayed wave locks to the same
 * phase every frame instead of scrolling past:
 *
 *   1. YIN pitch detection on a low-passed copy -> period
 *   2. windowed-sinc FIR low-pass with a cutoff that tracks the fundamental
 *   3. sub-sample rising zero crossing (cubic root) as the trigger
 *   4. polarity lock against the previously displayed window
 *
 * The difference function loop and the transient skip in the zero-crossing
 * search are kept as in the original, quirks included, so the phase decision
 * matches sample for sample.
 */

/* Cumulative mean-normalised difference (YIN). Returns false when nothing
 * crosses the threshold. */
static bool yin_pitch_detection(const float *samples, uint32_t len, float rate,
				float *d, float *cmnd, float *out_hz)
{
	uint32_t min_period = (uint32_t)(rate / MAX_FREQ);
	uint32_t max_period = (uint32_t)(rate / MIN_FREQ);
	uint32_t max_lag, min_lag, tau, n, i;
	uint32_t best_tau;
	float best_value, running_sum = 0.0f;
	float tau_f, a, b, c, denom, shift;
	bool found_threshold = false;

	if (min_period < 1u)
		min_period = 1u;

	max_lag = max_period < len / 2u ? max_period : len / 2u;
	min_lag = min_period < max_lag ? min_period : max_lag;

	if (max_lag < 2u || len < max_lag + 2u)
		return false;

	n = len - max_lag - 1u;
	if (n == 0u)
		return false;

	for (tau = 0; tau <= max_lag; tau++) {
		float sum = 0.0f;

		for (i = 0; i < n; i++) {
			float delta = samples[i] - samples[i + tau];

			sum += delta * delta;
		}
		d[tau] = sum;
	}

	cmnd[0] = 1.0f;
	for (tau = 1; tau <= max_lag; tau++) {
		running_sum += d[tau];
		cmnd[tau] = running_sum == 0.0f ? 1.0f
					       : d[tau] * (float)tau / running_sum;
	}

	best_tau = min_lag;
	best_value = cmnd[min_lag];

	for (tau = min_lag; tau <= max_lag; tau++) {
		float v = cmnd[tau];

		if (v < best_value) {
			best_value = v;
			best_tau = tau;
		}
		if (v < YIN_THRESHOLD) {
			best_tau = tau;
			best_value = v;
			found_threshold = true;
			break;
		}
	}

	if (!found_threshold && best_value >= YIN_THRESHOLD * 2.0f)
		return false;

	tau_f = (float)best_tau;
	if (best_tau > 0u && best_tau < max_lag) {
		a = cmnd[best_tau - 1];
		b = cmnd[best_tau];
		c = cmnd[best_tau + 1];
		denom = a + c - 2.0f * b;
		if (fabsf(denom) > 1e-12f) {
			shift = (a - c) / (2.0f * denom);
			if (shift > 1.0f)
				shift = 1.0f;
			if (shift < -1.0f)
				shift = -1.0f;
			tau_f = (float)best_tau + shift;
			if (tau_f < 1.0f)
				tau_f = 1.0f;
		}
	}

	*out_hz = tau_f >= 1.0f ? rate / tau_f : 0.0f;
	return *out_hz >= 1.0f;
}

/* Windowed-sinc low-pass with a Blackman window, normalised for unity DC gain. */
static void design_lowpass_fir(float cutoff_hz, float rate, uint32_t taps,
			       float *coeffs)
{
	uint32_t i;
	float fc = cutoff_hz / rate;
	float half = (float)taps / 2.0f;
	float sum = 0.0f;

	for (i = 0; i < taps; i++) {
		float n = (float)i - half;
		float bm;

		if (fabsf(n) < 1e-8f)
			coeffs[i] = 2.0f * fc;
		else
			coeffs[i] = sinf(2.0f * (float)M_PI * fc * n) /
				    ((float)M_PI * n);

		bm = 0.42f -
		     0.5f * cosf(2.0f * (float)M_PI * (float)i /
				 (float)(taps - 1)) +
		     0.08f * cosf(4.0f * (float)M_PI * (float)i /
				 (float)(taps - 1));
		coeffs[i] *= bm;
		sum += coeffs[i];
	}

	if (fabsf(sum) > 1e-12f) {
		for (i = 0; i < taps; i++)
			coeffs[i] /= sum;
	}
}

/* Direct-form convolution; out-of-range taps are skipped (implicit zero pad). */
static void apply_fir_filter(const float *in, uint32_t len, const float *coeffs,
			     uint32_t taps, float *out)
{
	uint32_t delay = taps / 2u;
	uint32_t i, j;

	for (i = 0; i < len; i++) {
		float sum = 0.0f;

		for (j = 0; j < taps; j++) {
			int64_t idx = (int64_t)i + (int64_t)j - (int64_t)delay;

			if (idx >= 0 && idx < (int64_t)len)
				sum += in[idx] * coeffs[j];
		}
		out[i] = sum;
	}
}

/* Low-pass with an adaptive cutoff, re-designing only once the cutoff has
 * drifted past the hysteresis band. */
static void apply_trigger_filter(struct state *st, const float *in, uint32_t len,
				 float cutoff_hz, float rate, float *out)
{
	if (!st->fir_valid || fabsf(st->fir_cutoff - cutoff_hz) >
					   FIR_REDESIGN_HYSTERESIS) {
		st->fir_cutoff = cutoff_hz;
		st->fir_valid = true;
		design_lowpass_fir(cutoff_hz, rate, FIR_NUM_TAPS,
				   st->fir_coeffs);
	}
	apply_fir_filter(in, len, st->fir_coeffs, FIR_NUM_TAPS, out);
}

/* Catmull-Rom interpolation at a fractional index. */
static float cubic_interpolate(const float *s, uint32_t len, float idx)
{
	int64_t i = (int64_t)idx;
	float t = idx - (float)i;
	float y0, y1, y2, y3, c0, c1, c2, c3;

	if (len == 0u)
		return 0.0f;
	if (i < 0)
		i = 0;
	if (i > (int64_t)len - 1)
		i = (int64_t)len - 1;

	{
		int64_t i0 = i - 1, i1 = i, i2 = i + 1, i3 = i + 2;
		int64_t last = (int64_t)len - 1;

		if (i0 < 0)
			i0 = 0;
		if (i1 < 0)
			i1 = 0;
		if (i2 > last)
			i2 = last;
		if (i3 > last)
			i3 = last;

		y0 = s[i0];
		y1 = s[i1];
		y2 = s[i2];
		y3 = s[i3];
	}

	c0 = y1;
	c1 = 0.5f * (-y0 + y2);
	c2 = 0.5f * (2.0f * y0 - 5.0f * y1 + 4.0f * y2 - y3);
	c3 = 0.5f * (-y0 + 3.0f * y1 - 3.0f * y2 + y3);

	return ((c3 * t + c2) * t + c1) * t + c0;
}

/* Newton iteration for the root of the cubic Hermite through y0..y3. */
static float find_cubic_root(float y0, float y1, float y2, float y3)
{
	float c0 = y1;
	float c1 = 0.5f * (-y0 + y2);
	float c2 = 0.5f * (2.0f * y0 - 5.0f * y1 + 4.0f * y2 - y3);
	float c3 = 0.5f * (-y0 + 3.0f * y1 - 3.0f * y2 + y3);
	float t = -y1 / (y2 - y1);
	int i;

	if (t > 1.0f)
		t = 1.0f;
	if (t < 0.0f)
		t = 0.0f;

	for (i = 0; i < 8; i++) {
		float ft = ((c3 * t + c2) * t + c1) * t + c0;
		float fpt = (3.0f * c3 * t + 2.0f * c2) * t + c1;

		if (fabsf(ft) < 1e-8f)
			break;
		if (fabsf(fpt) < 1e-12f)
			break;
		t -= ft / fpt;
		if (t > 1.0f)
			t = 1.0f;
		if (t < 0.0f)
			t = 0.0f;
	}

	return t;
}

/* First rising-edge (negative -> non-negative) crossing at sub-sample
 * precision, skipping the FIR transient unless nothing else is found. */
static bool sub_sample_zero_crossing(const float *s, uint32_t len,
				     uint32_t start, float *out)
{
	uint32_t i = start < 1u ? 1u : start;
	bool first_set = false;
	float first = 0.0f;

	while (i + 2u < len) {
		if (s[i - 1u] < 0.0f && s[i] >= 0.0f) {
			float y0 = i >= 2u ? s[i - 2u] : s[i - 1u];
			float y1 = s[i - 1u];
			float y2 = s[i];
			float y3 = i + 1u < len ? s[i + 1u] : s[i];
			float pos = (float)(i - 1u) +
				    find_cubic_root(y0, y1, y2, y3);

			if (!first_set) {
				first = pos;
				first_set = true;
				if (i >= 15u) {
					*out = first;
					return true;
				}
			}
			if (i >= 15u) {
				*out = pos;
				return true;
			}
		}
		i++;
	}

	if (first_set) {
		*out = first;
		return true;
	}
	return false;
}

/* Window of n samples from `trigger` onwards, cubic interpolated; positions
 * past the end are zero filled. */
static void extract_window(const float *s, uint32_t len, float trigger,
			   uint32_t n, float *out)
{
	uint32_t i;

	for (i = 0; i < n; i++) {
		float pos = trigger + (float)i;

		if (pos < 0.0f || pos >= (float)(len - 1u))
			out[i] = 0.0f;
		else
			out[i] = cubic_interpolate(s, len, pos);
	}
}

/* Snap a trigger to the nearest rising crossing within half a period. */
static float snap_to_rising_zero(const float *s, uint32_t len, float trigger,
				 float period)
{
	int64_t search, center, start, end, i;
	float best_dist = 1e30f;
	float best_pos = trigger;

	if (len < 4u || period < 2.0f)
		return trigger;

	search = (int64_t)ceilf(period * 0.5f);
	center = (int64_t)roundf(trigger);
	start = center - search;
	if (start < 1)
		start = 1;
	end = center + search;
	if (end > (int64_t)len - 2)
		end = (int64_t)len - 2;

	for (i = start; i <= end && i < (int64_t)len - 1; i++) {
		if (s[i - 1] < 0.0f && s[i] >= 0.0f) {
			float y0 = i >= 2 ? s[i - 2] : s[i - 1];
			float y1 = s[i - 1];
			float y2 = s[i];
			float y3 = i + 1 < (int64_t)len ? s[i + 1] : s[i];
			float pos = (float)(i - 1) +
				    find_cubic_root(y0, y1, y2, y3);
			float dist = fabsf(pos - trigger);

			if (dist < best_dist) {
				best_dist = dist;
				best_pos = pos;
			}
		}
	}

	return best_pos;
}

static float compute_rms(const float *s, uint32_t len)
{
	float sum = 0.0f;
	uint32_t i;

	if (len == 0u)
		return 0.0f;

	for (i = 0; i < len; i++)
		sum += s[i] * s[i];

	return sqrtf(sum / (float)len);
}

/* Fold a period that landed an octave off the previous frame back onto it. */
static float correct_octave(float p, float prev)
{
	float ratio;

	if (prev <= 0.0f)
		return p;

	ratio = p / prev;
	if (ratio > 1.7f && ratio < 2.35f)
		return p * 0.5f;
	if (ratio > 0.4f && ratio < 0.6f)
		return p * 2.0f;
	return p;
}

/* Copy the most recent samples out of the ring, oldest first. */
static uint32_t ring_read_recent(const struct state *st, uint32_t want,
				 float *out)
{
	uint32_t n = st->ring_count < want ? st->ring_count : want;
	uint32_t i;

	for (i = 0; i < n; i++)
		out[i] = ring_peek(st, n - 1u - i);

	return n;
}

/* Run the trigger pipeline and leave the phase-locked window in st->sync.
 * Returns the window length in samples. */
static uint32_t build_sync_window(struct state *st, uint32_t rate)
{
	uint32_t n, yin_len, window_size, min_window, actual, i;
	float rate_f = (float)rate;
	float pitch = 0.0f;
	float new_period;
	float period, fundamental_hz, trigger_cutoff, trigger, remaining;
	float rms;

	n = ring_read_recent(st, ANALYSIS_SIZE, st->mono);
	if (n < 8u) {
		st->sync_len = n;
		return n;
	}

	rms = compute_rms(st->mono, n);
	if (rms < 0.001f) {
		st->sync_len = 0u;
		return 0u;
	}

	/* YIN runs on a low-passed copy so 1 kHz-20 kHz content cannot fool it
	 * into locking onto a harmonic. The cutoff follows the previous
	 * period, 800 Hz until one is known. */
	{
		float yin_cutoff = st->last_period > 0.0f
					   ? (rate_f / st->last_period *
					      TRIGGER_CUTOFF_MULT)
					   : 800.0f;

		if (yin_cutoff < TRIGGER_CUTOFF_MIN)
			yin_cutoff = TRIGGER_CUTOFF_MIN;
		if (yin_cutoff > TRIGGER_CUTOFF_MAX)
			yin_cutoff = TRIGGER_CUTOFF_MAX;

		apply_trigger_filter(st, st->mono, n, yin_cutoff, rate_f,
				     st->filtered);
	}

	yin_len = n < (uint32_t)YIN_WINDOW ? n : (uint32_t)YIN_WINDOW;
	if (yin_pitch_detection(st->filtered, yin_len, rate_f, st->yin_d,
				st->yin_cmnd, &pitch)) {
		new_period = rate_f / pitch;
		if (new_period < MIN_PERIOD_SAMPLES)
			new_period = MIN_PERIOD_SAMPLES;

		if (st->last_period <= 0.0f) {
			st->last_period = new_period;
		} else {
			float corrected = correct_octave(new_period,
							 st->last_period);

			st->last_period = st->last_period * 0.85f +
					  corrected * 0.15f;
		}
		st->pitch_hz = pitch;
	} else {
		st->pitch_hz = 0.0f;
	}

	if (st->last_period < MIN_PERIOD_SAMPLES)
		st->last_period = MIN_PERIOD_SAMPLES;

	period = st->last_period;

	/* The trigger filter tracks the fundamental so the phase decision
	 * stays consistent when the EQ boosts harmonics. */
	fundamental_hz = rate_f / (period > 1.0f ? period : 1.0f);
	trigger_cutoff = fundamental_hz * TRIGGER_CUTOFF_MULT;
	if (trigger_cutoff < TRIGGER_CUTOFF_MIN)
		trigger_cutoff = TRIGGER_CUTOFF_MIN;
	if (trigger_cutoff > TRIGGER_CUTOFF_MAX)
		trigger_cutoff = TRIGGER_CUTOFF_MAX;

	min_window = (uint32_t)(rate_f * MIN_WINDOW_SECS);
	window_size = (uint32_t)ceilf((float)PERIOD_MULTIPLIER * period);
	if (window_size < min_window)
		window_size = min_window;
	if (window_size > n / 2u)
		window_size = n / 2u;

	apply_trigger_filter(st, st->mono, n, trigger_cutoff, rate_f,
			     st->filtered);

	if (!sub_sample_zero_crossing(st->filtered, n, 0u, &trigger))
		trigger = 0.0f;

	/* Trigger is located on the filtered signal, but the window is taken
	 * from the raw one, so the FIR group delay (15 taps) and its reshaping
	 * of the slope leave the trace starting slightly off a true zero
	 * crossing. Snapping on the raw signal removes that offset. */
	// trigger = snap_to_rising_zero(st->filtered, n, trigger, period);
	trigger = snap_to_rising_zero(st->mono, n, trigger, period);

	remaining = (float)n - trigger;
	actual = window_size;
	if ((float)actual > remaining)
		actual = (uint32_t)remaining;
	if (actual < 4u)
		actual = 4u;
	if (actual > ANALYSIS_SIZE)
		actual = ANALYSIS_SIZE;

	extract_window(st->mono, n, trigger, actual, st->sync);

	/* Polarity lock: a window that anti-correlates with the one on screen
	 * means the trigger landed half a period away, so flip it back instead
	 * of letting the wave turn over on harmonically dense material. */
	if (st->last_window_len > 0u) {
		uint32_t k, common = actual < st->last_window_len
					     ? actual
					     : st->last_window_len;

		if (common >= 8u) {
			float dot = 0.0f, norm = 0.0f;

			for (k = 0; k < common; k++)
				dot += st->sync[k] * st->last_window[k];
			for (k = 0; k < st->last_window_len; k++)
				norm += st->last_window[k] * st->last_window[k];

			if (norm < 1e-9f)
				norm = 1e-9f;

			if (dot / norm < 0.0f) {
				for (k = 0; k < actual; k++)
					st->sync[k] = -st->sync[k];
			}
		}
	}

	st->last_window_len = actual;
	for (i = 0; i < actual; i++)
		st->last_window[i] = st->sync[i];

	st->sync_len = actual;
	return actual;
}

static uint8_t to_byte(float value)
{
	float scaled = value * 127.0f;

	if (scaled > 127.0f)
		scaled = 127.0f;
	if (scaled < -128.0f)
		scaled = -128.0f;

	return (uint8_t)(int)lrintf(scaled + 128.0f);
}

static void emit_frame(struct state *st, uint64_t now_ns)
{
	float attack, release;
	uint32_t cols = (uint32_t)st->cfg.cols;
	uint32_t sync_len, points, c;
	uint32_t i;
	float peak = 0.0f;
	bool primed = st->smooth_primed;
	char line[MAX_LINE];
	int n = 0;

	/* One-pole smoothing with a faster attack than release, so transients
	 * stay visible while decays stay readable instead of strobing. */
	attack = 1.0f - (float)st->cfg.smoothing * 0.85f;
	release = 1.0f - (float)st->cfg.smoothing * 0.92f;

	if (!primed) {
		for (c = 0; c < cols; c++) {
			st->smooth_min[c] = 0.0f;
			st->smooth_max[c] = 0.0f;
		}
		st->smooth_primed = true;
	}

/* Phase-locked window, resampled to two points per column so each
	 * column carries the sub-column spread the graph draws as its band. */
	sync_len = build_sync_window(st, st->rate);
	if (sync_len == 0u) {
		for (c = 0; c < cols; c++) {
			st->out_min[c] = 128;
			st->out_max[c] = 128;
		}
		st->rms_level = 0.0f;
		st->peak_hold = 0.0f;
		st->raw_peak = 0.0f;
		st->out_silent = true;
	} else {
		points = cols * 2u;
		for (i = 0; i < points; i++) {
			float pos = sync_len > 1u
					    ? (float)i * (float)(sync_len - 1u) /
						      (float)(points - 1u)
					    : 0.0f;

			st->resampled[i] = sync_len > 0u
						   ? cubic_interpolate(st->sync, sync_len, pos)
						   : 0.0f;
		}

		for (c = 0; c < cols; c++) {
			float lo = st->resampled[c * 2u];
			float hi = st->resampled[c * 2u + 1u];

			if (lo > hi) {
				float t = lo;

				lo = hi;
				hi = t;
			}

			lo *= (float)st->cfg.sensitivity;
			hi *= (float)st->cfg.sensitivity;

			if (lo < -1.0f)
				lo = -1.0f;
			if (hi > 1.0f)
				hi = 1.0f;

			{
				float a = (hi - st->smooth_max[c]) > (st->smooth_min[c] - lo)
						? attack
						: release;
				float b = (hi - st->smooth_max[c]) > (st->smooth_min[c] - lo)
						? release
						: attack;

				st->smooth_max[c] += (hi - st->smooth_max[c]) * a;
				st->smooth_min[c] += (lo - st->smooth_min[c]) * b;
			}

			st->out_min[c] = to_byte(st->smooth_min[c]);
			st->out_max[c] = to_byte(st->smooth_max[c]);

			{
				float lo_m = st->smooth_min[c] < 0.0f ? -st->smooth_min[c]
									 : st->smooth_min[c];
				float hi_m = st->smooth_max[c] < 0.0f ? -st->smooth_max[c]
									 : st->smooth_max[c];

				if (hi_m > peak)
					peak = hi_m;
				if (lo_m > peak)
					peak = lo_m;
			}
		}

		st->rms_level = compute_rms(st->sync, sync_len);

		/* Report the locked pitch occasionally so the trigger can be sanity
		 * checked from the plugin log. */
		if (st->pitch_hz > 0.0f && now_ns - st->last_pitch_log_ns > PITCH_LOG_NS) {
			st->last_pitch_log_ns = now_ns;
			note("pitch %.1f Hz (period %.1f samples, window %u)", st->pitch_hz,
			     st->last_period, sync_len);
		}

		/* Peak decays slowly so a transient stays readable for a moment. */
		if (peak >= st->peak_hold)
			st->peak_hold = peak;
		else
			st->peak_hold += (peak - st->peak_hold) * 0.12f;

		/* Fast-decay raw peak for responsive silence detection. */
		if (peak >= st->raw_peak)
			st->raw_peak = peak;
		else
			st->raw_peak += (peak - st->raw_peak) * 0.5f;

		{
			/* gate == 0 se trata como "auto": umbral proporcional a la sensibilidad
			 * para que el ruido residual no evite el silenciamiento. */
			float effective_gate = st->cfg.gate > 0.0f
						 ? (float)st->cfg.gate
						 : 0.0025f * (float)st->cfg.sensitivity;
			/* Use raw_peak (fast decay) for gate so silence triggers promptly. */
			bool silent = st->raw_peak < effective_gate;

			if (silent) {
				for (c = 0; c < cols; c++) {
					st->out_min[c] = 128;
					st->out_max[c] = 128;
					st->smooth_min[c] = 0.0f;
					st->smooth_max[c] = 0.0f;
				}
				st->peak_hold = 0.0f;
				st->raw_peak = 0.0f;
				st->rms_level = 0.0f;
				st->out_silent = true;
				/* Drop the polarity reference so the next sound picks
				 * its own phase orientation. */
				st->last_window_len = 0u;
			} else {
				st->out_silent = false;
			}
		}
	}

	st->out_rms = to_byte(st->rms_level);
	st->out_peak = to_byte(st->peak_hold);

	n = snprintf(line, sizeof(line), "F %u %u %u %d", st->seq,
		     st->out_rms, st->out_peak, st->out_silent ? 1 : 0);
		for (c = 0; c < cols && n < (int)sizeof(line) - 6; c++)
			n += snprintf(line + n, sizeof(line) - (size_t)n, " %u %u",
				      st->out_min[c], st->out_max[c]);
		line[n++] = '\n';
		fwrite(line, 1, (size_t)n, stdout);
		/* stdout is a pipe under the plugin runtime, where libc would
		 * otherwise hold frames in its buffer until it fills up. */
		fflush(stdout);

	st->seq++;
	st->frames_emitted++;
}

static void stream_process(void *user_data)
{
	struct state *st = user_data;
	struct pw_buffer *pwbuf;
	struct spa_buffer *buf;
	uint32_t n_samples = 0;
	uint32_t d;
	uint64_t now;

	pwbuf = pw_stream_dequeue_buffer(st->stream);
	if (pwbuf == NULL)
		return;

	buf = pwbuf->buffer;
	if (buf == NULL) {
		pw_stream_queue_buffer(st->stream, pwbuf);
		return;
	}

	/* Frame timing rides the graph clock so the cadence follows the real
	 * sample rate instead of wall time. */
	now = pw_stream_get_nsec(st->stream);
	if (now == 0)
		now = st->last_emit_ns + st->period_ns;

	for (d = 0; d < buf->n_datas; d++)
		if (buf->datas[d].chunk != NULL)
			n_samples += buf->datas[d].chunk->size / sizeof(float) /
				     (st->channels ? st->channels : 1);

	if (n_samples > 0) {
		consume_buffer(st, buf);
		st->frames_received++;
	}

	pw_stream_queue_buffer(st->stream, pwbuf);

	if (n_samples > 0 && now - st->last_emit_ns >= st->period_ns) {
		st->last_emit_ns = now;
		emit_frame(st, now);
	}
}

/* ------------------------------------------------------ format negotiation */

static void stream_param_changed(void *user_data, uint32_t id,
		const struct spa_pod *param)
{
	struct state *st = user_data;
	struct spa_audio_info_raw info = { 0 };

	if (id != SPA_PARAM_EnumFormat && id != SPA_PARAM_Format)
		return;

	if (param == NULL || !spa_pod_is_object(param))
		return;

	if (spa_format_audio_raw_parse(param, &info) < 0)
		return;

	if (info.channels == 0)
		return;

	/* We only know how to read interleaved or planar f32; anything else
	 * is worth surfacing rather than silently misreading. */
	if (info.format != SPA_AUDIO_FORMAT_F32 &&
	    info.format != SPA_AUDIO_FORMAT_F32P) {
		note("unsupported format 0x%x, expected f32", info.format);
		return;
	}

	st->rate = info.rate ? info.rate : 48000;
	st->channels = info.channels;
	st->format_ready = true;

	st->period_ns = (uint64_t)(1000000000.0 / st->cfg.fps);
	if (st->period_ns == 0)
		st->period_ns = 1000000;

	note("format: f32 %u ch @ %u Hz, period %llu ns", st->channels,
	     st->rate, (unsigned long long)st->period_ns);

	/* We advertise exactly one format, so the only EnumFormat we can be
	 * handed is our own; there is nothing left to negotiate. */
	if (id == SPA_PARAM_EnumFormat)
		return;
}

static void stream_state_changed(void *user_data, enum pw_stream_state old,
		enum pw_stream_state state, const char *error)
{
	struct state *st = user_data;

	if (state == PW_STREAM_STATE_ERROR) {
		note("stream error: %s", error ? error : "unknown");
		pw_main_loop_quit(st->loop);
	} else if (state == PW_STREAM_STATE_UNCONNECTED) {
		note("stream unconnected (target %s)", st->node_name);
	} else if (old == PW_STREAM_STATE_UNCONNECTED &&
		   (state == PW_STREAM_STATE_CONNECTING ||
		    state == PW_STREAM_STATE_PAUSED)) {
		note("stream connecting");
	}
}

static const struct pw_stream_events stream_events = {
	PW_VERSION_STREAM_EVENTS,
	.state_changed = stream_state_changed,
	.param_changed = stream_param_changed,
	.process = stream_process,
};

/* ------------------------------------------------------------------- setup */

/* Picks the node to capture, preferring the session manager's default output
 * and falling back to any sink. Returns false when there is nothing to tap. */
static bool resolve_target(struct state *st)
{
	int i;

	if (st->cfg.target != NULL) {
		for (i = 0; i < st->n_sinks; i++) {
			if (name_matches(st->cfg.target, st->sinks[i])) {
				snprintf(st->node_name, sizeof(st->node_name), "%s",
					 st->sinks[i]);
				st->have_node = true;
				note("target (explicit): %s", st->node_name);
				return true;
			}
		}
		for (i = 0; i < st->n_monitors; i++) {
			if (name_matches(st->cfg.target, st->monitors[i])) {
				snprintf(st->node_name, sizeof(st->node_name), "%s",
					 st->monitors[i]);
				st->have_node = true;
				note("target (explicit): %s", st->node_name);
				return true;
			}
		}
		note("target %s not found", st->cfg.target);
		return false;
	}

	/* The default sink, if the metadata told us which one it is. */
	if (st->default_sink[0] != '\0') {
		for (i = 0; i < st->n_sinks; i++) {
			if (strcmp(st->sinks[i], st->default_sink) != 0)
				continue;

			snprintf(st->node_name, sizeof(st->node_name), "%s",
				 st->sinks[i]);
			st->have_node = true;
			note("target (default sink): %s", st->node_name);
			return true;
		}
	}

	/* Otherwise the first sink we saw. */
	if (st->n_sinks > 0) {
		snprintf(st->node_name, sizeof(st->node_name), "%s",
			 st->sinks[0]);
		st->have_node = true;
		note("target (first sink): %s", st->node_name);
		return true;
	}

	/* A monitor with no owning sink is still capturable. */
	if (st->n_monitors > 0) {
		snprintf(st->node_name, sizeof(st->node_name), "%s",
			 st->monitors[0]);
		st->have_node = true;
		note("target (monitor): %s", st->node_name);
		return true;
	}

	return false;
}

/* Blocks until the core reports it has processed everything we queued, so
 * registry globals and metadata are populated before we pick a target. */
static int core_roundtrip(struct state *st)
{
	struct pw_loop *loop = pw_main_loop_get_loop(st->loop);

	st->resolved = false;
	pw_core_sync(st->core, 0, 0);
	while (!st->resolved)
		pw_loop_iterate(loop, 20);

	/* Metadata props are published on their own round trip, so a second
	 * barrier is needed before default.audio.sink can be trusted. */
	if (st->default_sink[0] == '\0') {
		st->resolved = false;
		pw_core_sync(st->core, 0, 0);
		while (!st->resolved)
			pw_loop_iterate(loop, 20);
	}

	return resolve_target(st) ? 0 : -1;
}

/* The format pod is processed asynchronously by pw_stream_connect, which
 * keeps referencing the built pod, so it must outlive this function. */
static struct spa_pod *format_pod = NULL;
static uint8_t format_space[1024];
static struct spa_pod_builder format_builder;

static void build_format(const struct spa_pod **param)
{
	struct spa_audio_info_raw info = SPA_AUDIO_INFO_RAW_INIT(
			.format = SPA_AUDIO_FORMAT_F32,
			.rate = 48000,
			.channels = 1,
			.flags = SPA_AUDIO_FLAG_UNPOSITIONED);

	if (format_pod == NULL) {
		format_builder = (struct spa_pod_builder)SPA_POD_BUILDER_INIT(
				format_space, sizeof(format_space));
		format_pod = spa_format_audio_raw_build(&format_builder,
				SPA_PARAM_EnumFormat, &info);
	}

	*param = format_pod;
}

static int connect_stream(struct state *st)
{
	struct pw_properties *props;
	const char *target = st->have_node ? st->node_name : NULL;

	props = pw_properties_new(
		PW_KEY_MEDIA_CATEGORY, "Capture",
		PW_KEY_MEDIA_TYPE, "Audio",
		PW_KEY_MEDIA_ROLE, "Music",
		PW_KEY_APP_NAME, APP_NAME,
		PW_KEY_NODE_NAME, NODE_NAME,
		PW_KEY_NODE_DESCRIPTION, NODE_DESC,
		PW_KEY_NODE_LATENCY, "256/48000",
		/* Route the capture to the sink's monitor instead of a mic. */
		PW_KEY_STREAM_CAPTURE_SINK, "true",
		PW_KEY_STREAM_MONITOR, "true",
		NULL);

	if (target == NULL) {
		fail("no audio sink found; pass --target <node> or start audio output");
		pw_properties_free(props);
		return -1;
	}

	/* Targeting the sink lets the session manager route through a monitor;
	 * naming one directly is the fallback when --target is given. */
	pw_properties_set(props, PW_KEY_TARGET_OBJECT, target);

	st->stream = pw_stream_new(st->core, APP_NAME, props);
	/* pw_stream_new takes ownership of props (it does NOT copy), so we must
	 * not free them here; pw-cat does the same and keeps them alive. */
	props = NULL;

	if (st->stream == NULL) {
		fail("pw_stream_new failed");
		return -1;
	}

	pw_stream_add_listener(st->stream, &st->stream_listener, &stream_events,
			       st);

	st->seq = 0;
	st->frames_received = 0;
	st->frames_emitted = 0;
	st->underruns = 0;
	st->ring_count = 0;
	st->ring_head = 0;
	st->dc_mean = 0.0;
	st->last_emit_ns = 0;
	st->period_ns = (uint64_t)(1000000000.0 / st->cfg.fps);
	st->format_ready = false;
	st->smooth_primed = false;
	st->peak_hold = 0.0f;
	st->rms_level = 0.0f;

	{
		const struct spa_pod *params[1];
		uint32_t n_params = 0;

		build_format(&params[0]);
		n_params = 1;

		if (pw_stream_connect(st->stream, PW_DIRECTION_INPUT, PW_ID_ANY,
				      PW_STREAM_FLAG_AUTOCONNECT |
				      PW_STREAM_FLAG_MAP_BUFFERS,
				      params, n_params) < 0) {
			fail("pw_stream_connect failed");
			pw_stream_destroy(st->stream);
			st->stream = NULL;
			return -1;
		}
		note("pw_stream_connect returned");
	}

	return 0;
}

static void on_signal(void *user_data, int signal_number)
{
	struct state *st = user_data;

	(void)signal_number;
	note("stopping after %llu buffers, %llu frames", 
	     (unsigned long long)st->frames_received,
	     (unsigned long long)st->frames_emitted);
	pw_main_loop_quit(st->loop);
}

static void usage(void)
{
	fprintf(stderr,
		"usage: pwscope [options]\n"
		"  --target <id|name>   node to capture (default: first audio sink)\n"
		"  --cols <n>           1..%d output columns (default 32)\n"
		"  --fps <n>            frames per second (default 60)\n"
		"  --sensitivity <x>    gain multiplier (default 1.0)\n"
		"  --smoothing <0..1>   attack/release smoothing (default 0)\n"
		"  --gate <0..1>        silence threshold (default %.4f)\n"
		"  --help\n",
		MAX_COLS, DEFAULT_GATE);
}

static int parse_args(struct config *cfg, int argc, char **argv)
{
	int i;

	cfg->target = NULL;
	cfg->cols = 32;
	cfg->fps = 60.0;
	cfg->sensitivity = 1.0;
	cfg->smoothing = 0.0;
	cfg->gate = DEFAULT_GATE;

	for (i = 1; i < argc; i++) {
		const char *a = argv[i];
		const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;

#define NEED_VALUE()                                                        \
	do {                                                               \
		if (v == NULL) {                                          \
			fprintf(stderr, "missing value for %s\n", a);      \
			return -1;                                         \
		}                                                          \
		i++;                                                      \
	} while (0)

		if (strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0) {
			usage();
			return 1;
		} else if (strcmp(a, "--target") == 0) {
			NEED_VALUE();
			cfg->target = v;
		} else if (strcmp(a, "--cols") == 0) {
			NEED_VALUE();
			cfg->cols = atoi(v);
			if (cfg->cols < 1 || cfg->cols > MAX_COLS) {
				fprintf(stderr, "--cols must be 1..%d\n", MAX_COLS);
				return -1;
			}
		} else if (strcmp(a, "--fps") == 0) {
			NEED_VALUE();
			cfg->fps = atof(v);
			if (cfg->fps <= 0.0 || cfg->fps > 1000.0) {
				fprintf(stderr, "--fps out of range\n");
				return -1;
			}
		} else if (strcmp(a, "--sensitivity") == 0) {
			NEED_VALUE();
			cfg->sensitivity = atof(v);
		} else if (strcmp(a, "--smoothing") == 0) {
			NEED_VALUE();
			cfg->smoothing = atof(v);
		} else if (strcmp(a, "--gate") == 0) {
			NEED_VALUE();
			cfg->gate = atof(v);
		} else {
			fprintf(stderr, "unknown option %s\n", a);
			return -1;
		}
#undef NEED_VALUE
	}

	return 0;
}

int main(int argc, char **argv)
{
	struct config cfg;
	struct state st;
	int rc;

	memset(&cfg, 0, sizeof(cfg));
	rc = parse_args(&cfg, argc, argv);
	if (rc != 0)
		return rc < 0 ? 1 : 0;

	memset(&st, 0, sizeof(st));
	st.cfg = cfg;
	st.period_ns = (uint64_t)(1000000000.0 / cfg.fps);
	if (st.period_ns == 0)
		st.period_ns = 1000000;

	signal(SIGPIPE, SIG_IGN);
	setvbuf(stdout, NULL, _IOLBF, 0);

	pw_init(&argc, &argv);

	st.loop = pw_main_loop_new(NULL);
	if (st.loop == NULL) {
		fail("pw_main_loop_new failed");
		return 1;
	}

	st.context = pw_context_new(pw_main_loop_get_loop(st.loop),
				    pw_properties_new(NULL, NULL), 0);
	if (st.context == NULL) {
		fail("pw_context_new failed");
		return 1;
	}

	st.core = pw_context_connect(st.context, NULL, 0);
	if (st.core == NULL) {
		fail("pw_context_connect failed");
		return 1;
	}

	pw_core_add_listener(st.core, &st.core_listener, &(struct pw_core_events){
		.version = PW_VERSION_CORE_EVENTS,
		.done = core_done,
		.error = core_error,
	}, &st);

	st.registry = pw_core_get_registry(st.core, PW_VERSION_REGISTRY, 0);
	pw_registry_add_listener(st.registry, &st.registry_listener,
				&registry_events, &st);

	pw_loop_add_signal(pw_main_loop_get_loop(st.loop), SIGINT, on_signal, &st);
	pw_loop_add_signal(pw_main_loop_get_loop(st.loop), SIGTERM, on_signal, &st);

	/* Registry globals and metadata arrive asynchronously, so discovery
	 * needs a real barrier before we can pick a target. */
	if (core_roundtrip(&st) < 0) {
		fail("no audio sink found; pass --target <node> or start audio output");
		return 1;
	}

	if (connect_stream(&st) < 0)
		return 1;

	note("streaming from %s", st.node_name);
	pw_main_loop_run(st.loop);

	if (st.stream != NULL) {
		pw_stream_destroy(st.stream);
		st.stream = NULL;
	}
	pw_core_disconnect(st.core);
	pw_context_destroy(st.context);
	pw_main_loop_destroy(st.loop);

	return 0;
}
