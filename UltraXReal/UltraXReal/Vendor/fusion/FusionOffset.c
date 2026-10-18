/**
 * @file FusionOffset.c
 * @author Seb Madgwick
 * @brief Gyroscope offset correction algorithm for run-time calibration of the
 * gyroscope offset.
 */

//------------------------------------------------------------------------------
// Includes

#include "FusionOffset.h"
#include <math.h> // fabsf

//------------------------------------------------------------------------------
// Definitions

/**
 * @brief Cutoff frequency in Hz.
 */
#define CUTOFF_FREQUENCY (0.02f)

/**
 * @brief Timeout in seconds.
 */
#define TIMEOUT (5)

/**
 * @brief Threshold in degrees per second.
 */
#define THRESHOLD (3.0f)

//------------------------------------------------------------------------------
// Functions

/**
 * @brief Initialises the gyroscope offset algorithm.
 * @param offset Gyroscope offset algorithm structure.
 * @param sampleRate Sample rate in Hz.
 */
void FusionOffsetInitialise(FusionOffset *const offset, const unsigned int sampleRate) {
    offset->sampleRate = sampleRate > 0 ? sampleRate : 1000;
    offset->filterCoefficient = 2.0f * (float) M_PI * CUTOFF_FREQUENCY * (1.0f / (float) offset->sampleRate);
    offset->timeout = TIMEOUT * offset->sampleRate;
    offset->timer = 0;
    offset->gyroscopeOffset = FUSION_VECTOR_ZERO;
    offset->calibrationState = FusionOffsetCalibrationIdle;
    offset->calibrationSamples = 0;
    offset->calibrationMean = FUSION_VECTOR_ZERO;
    offset->calibrationM2 = FUSION_VECTOR_ZERO;
    offset->manualBias = false;
}

void FusionOffsetBeginCalibration(FusionOffset *const offset) {
    offset->calibrationSamples = 0;
    offset->calibrationMean = FUSION_VECTOR_ZERO;
    offset->calibrationM2 = FUSION_VECTOR_ZERO;
    offset->calibrationState = FusionOffsetCalibrationCollecting;
}

void FusionOffsetCancelCalibration(FusionOffset *const offset) {
    offset->calibrationState = FusionOffsetCalibrationIdle;
}

FusionOffsetCalibrationState FusionOffsetGetCalibrationState(const FusionOffset *const offset) {
    return offset->calibrationState;
}

FusionVector FusionOffsetGetBias(const FusionOffset *const offset) {
    return offset->gyroscopeOffset;
}

void FusionOffsetSetBias(FusionOffset *const offset, float x, float y, float z) {
    offset->gyroscopeOffset = (FusionVector) {.axis = {.x = x, .y = y, .z = z}};
    // Slow intentional turns must not be learned as sensor bias after calibration.
    offset->manualBias = true;
    offset->timer = 0;
}

/**
 * @brief Updates the gyroscope offset algorithm and returns the corrected
 * gyroscope measurement.
 * @param offset Gyroscope offset algorithm structure.
 * @param gyroscope Gyroscope measurement in degrees per second.
 * @return Corrected gyroscope measurement in degrees per second.
 */
FusionVector FusionOffsetUpdate(FusionOffset *const offset, FusionVector gyroscope) {

    if (offset->calibrationState == FusionOffsetCalibrationCollecting) {
        offset->calibrationSamples++;
        for (unsigned int axis = 0; axis < 3; axis++) {
            const float value = gyroscope.array[axis];
            if (!isfinite(value) || fabsf(value) > THRESHOLD) {
                offset->calibrationState = FusionOffsetCalibrationMoved;
                break;
            }
            const float delta = value - offset->calibrationMean.array[axis];
            offset->calibrationMean.array[axis] += delta / offset->calibrationSamples;
            offset->calibrationM2.array[axis] += delta * (value - offset->calibrationMean.array[axis]);
        }
        if (offset->calibrationState == FusionOffsetCalibrationCollecting &&
            offset->calibrationSamples >= 2 * offset->sampleRate) {
            bool still = true;
            for (unsigned int axis = 0; axis < 3; axis++) {
                // Reject variance above (0.08 degrees/second)^2.
                still = still && offset->calibrationM2.array[axis] /
                    (offset->calibrationSamples - 1) < 0.0064f;
            }
            if (still) {
                FusionOffsetSetBias(offset, offset->calibrationMean.axis.x,
                                    offset->calibrationMean.axis.y, offset->calibrationMean.axis.z);
                offset->calibrationState = FusionOffsetCalibrationComplete;
            } else {
                offset->calibrationState = FusionOffsetCalibrationMoved;
            }
        }
        return FusionVectorSubtract(gyroscope, offset->gyroscopeOffset);
    }

    // Subtract offset from gyroscope measurement
    gyroscope = FusionVectorSubtract(gyroscope, offset->gyroscopeOffset);

    if (offset->manualBias) { return gyroscope; }

    // Reset timer if gyroscope not stationary
    if ((fabsf(gyroscope.axis.x) > THRESHOLD) || (fabsf(gyroscope.axis.y) > THRESHOLD) || (fabsf(gyroscope.axis.z) > THRESHOLD)) {
        offset->timer = 0;
        return gyroscope;
    }

    // Increment timer while gyroscope stationary
    if (offset->timer < offset->timeout) {
        offset->timer++;
        return gyroscope;
    }

    // Adjust offset if timer has elapsed
    offset->gyroscopeOffset = FusionVectorAdd(offset->gyroscopeOffset, FusionVectorMultiplyScalar(gyroscope, offset->filterCoefficient));
    return gyroscope;
}

//------------------------------------------------------------------------------
// End of file
