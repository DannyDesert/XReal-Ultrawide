#pragma once
//
// Tiny ad-hoc JSON parser for XReal Air glasses' factory IMU calibration blob.
// The blob is streamed from on-device flash via the GET_CAL_DATA_LENGTH /
// CAL_DATA_GET_NEXT_SEGMENT HID message pair (see device_imu.c). Without it,
// Madgwick converges from identity calibration → ~1°/s residual gyro bias →
// visible head-locked drift.
//
// Targets only the ~10 keys we consume. Unknown keys are ignored. Tolerant to
// nested objects and array-of-arrays since values are extracted by raw
// substring match + float scan, not by a real grammar.
//

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// POD calibration data parsed from the JSON blob. Each *_present flag tells
/// whether the corresponding field was found and parsed successfully — the
/// caller decides whether to apply or fall back to identity defaults.
typedef struct {
    bool acc_bias_present;
    float acc_bias[3];
    bool acc_scale_present;
    float acc_scale[3];
    bool acc_misalignment_present;
    float acc_misalignment[9];   // row-major 3x3

    bool gyro_bias_present;
    float gyro_bias[3];
    bool gyro_scale_present;
    float gyro_scale[3];
    bool gyro_misalignment_present;
    float gyro_misalignment[9];

    bool mag_bias_present;
    float mag_bias[3];
    bool mag_scale_present;
    float mag_scale[3];
    bool mag_misalignment_present;
    float mag_misalignment[9];

    bool noises_present;
    float noises[4];
} cal_json_data;

/// Parse the calibration JSON blob into `out`. Returns true if at least one
/// gyro field was parsed (the minimum useful for drift correction). Unknown
/// keys / malformed values are silently skipped.
bool cal_json_parse(const char *json, size_t len, cal_json_data *out);

#ifdef __cplusplus
}
#endif
