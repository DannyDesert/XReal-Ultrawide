#include "cal_json.h"

#include <stdlib.h>
#include <string.h>

// Find the first occurrence of "key" (quoted) inside [start, end), and return
// a pointer to the byte right after the closing quote. NULL on miss.
static const char *find_quoted(const char *start, const char *end, const char *key) {
    const size_t klen = strlen(key);
    while (start && start + klen + 2 <= end) {
        const char *q = (const char *)memchr(start, '"', (size_t)(end - start));
        if (!q) return NULL;
        if (q + 1 + klen + 1 <= end &&
            memcmp(q + 1, key, klen) == 0 &&
            q[1 + klen] == '"') {
            return q + 1 + klen + 1;
        }
        start = q + 1;
    }
    return NULL;
}

// Skip JSON whitespace, ':' separator, '[' opening brackets, and ',' separators.
// Returns the position of the next numeric character, or NULL on EOF / non-numeric.
static const char *skip_to_number(const char *p, const char *end) {
    while (p < end) {
        const char c = *p;
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' ||
            c == ':' || c == '[' || c == ',') {
            p++;
        } else if (c == '-' || c == '+' || c == '.' || (c >= '0' && c <= '9')) {
            return p;
        } else {
            return NULL;  // hit a key, brace, etc. — done with this array
        }
    }
    return NULL;
}

// Read up to `n` floats starting at `p`, ignoring brackets / commas / whitespace.
// Returns the number of floats actually read.
static int read_floats(const char *p, const char *end, float *out, int n) {
    int got = 0;
    while (got < n && p && p < end) {
        p = skip_to_number(p, end);
        if (!p) break;
        char *tail = NULL;
        const float v = strtof(p, &tail);
        if (tail == p) break;
        out[got++] = v;
        p = tail;
    }
    return got;
}

// Locate `key` after `section` (if non-NULL). The section anchor lets us
// distinguish "bias" inside acc/gyro/mag without parsing the JSON tree.
// Returns true and fills `dst` with `n` floats on success.
static bool extract_array(const char *json, size_t len,
                          const char *section, const char *key,
                          float *dst, int n) {
    const char *p = json;
    const char *end = json + len;

    if (section) {
        p = find_quoted(p, end, section);
        if (!p) return false;
    }
    p = find_quoted(p, end, key);
    if (!p) return false;

    return read_floats(p, end, dst, n) == n;
}

bool cal_json_parse(const char *json, size_t len, cal_json_data *out) {
    if (!json || !out || len == 0) return false;
    memset(out, 0, sizeof(*out));

    // Common XReal naming variants. We try section names in order of
    // preference; whichever anchor is found first wins for downstream key
    // lookup. "acc"/"gyro"/"mag" matches both bare and IMU.acc dotted forms
    // because find_quoted matches any quoted token.
    static const char *acc_sections[]  = {"acc", "accelerometer", "ACC", NULL};
    static const char *gyro_sections[] = {"gyro", "gyroscope",    "GYRO", NULL};
    static const char *mag_sections[]  = {"mag",  "magnetometer", "MAG",  NULL};

    static const char *bias_keys[]   = {"bias",         "offset",      NULL};
    static const char *scale_keys[]  = {"scale",        "sensitivity", NULL};
    static const char *misa_keys[]   = {"misalignment", "alignment",   NULL};

    // Helper macro: try every (section, key) combination until one succeeds.
    #define TRY_ARR(section_arr, key_arr, dst, n, present_flag) do {           \
        for (int si = 0; section_arr[si] && !out->present_flag; si++) {        \
            for (int ki = 0; key_arr[ki] && !out->present_flag; ki++) {        \
                if (extract_array(json, len, section_arr[si], key_arr[ki],     \
                                  dst, n)) {                                   \
                    out->present_flag = true;                                  \
                }                                                              \
            }                                                                  \
        }                                                                      \
    } while (0)

    TRY_ARR(acc_sections,  bias_keys,  out->acc_bias,         3, acc_bias_present);
    TRY_ARR(acc_sections,  scale_keys, out->acc_scale,        3, acc_scale_present);
    TRY_ARR(acc_sections,  misa_keys,  out->acc_misalignment, 9, acc_misalignment_present);

    TRY_ARR(gyro_sections, bias_keys,  out->gyro_bias,         3, gyro_bias_present);
    TRY_ARR(gyro_sections, scale_keys, out->gyro_scale,        3, gyro_scale_present);
    TRY_ARR(gyro_sections, misa_keys,  out->gyro_misalignment, 9, gyro_misalignment_present);

    TRY_ARR(mag_sections,  bias_keys,  out->mag_bias,         3, mag_bias_present);
    TRY_ARR(mag_sections,  scale_keys, out->mag_scale,        3, mag_scale_present);
    TRY_ARR(mag_sections,  misa_keys,  out->mag_misalignment, 9, mag_misalignment_present);

    // "noises" is top-level, no section anchor.
    if (extract_array(json, len, NULL, "noises", out->noises, 4)) {
        out->noises_present = true;
    } else if (extract_array(json, len, NULL, "noise", out->noises, 4)) {
        out->noises_present = true;
    }

    #undef TRY_ARR

    // We declare success if we got at least the gyro bias — that's the field
    // primarily responsible for visible head-tracker drift.
    return out->gyro_bias_present;
}
