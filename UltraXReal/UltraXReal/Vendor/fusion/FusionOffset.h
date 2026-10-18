/**
 * @file FusionOffset.h
 * @author Seb Madgwick
 * @brief Gyroscope offset correction algorithm for run-time calibration of the
 * gyroscope offset.
 */

#ifndef FUSION_OFFSET_H
#define FUSION_OFFSET_H

//------------------------------------------------------------------------------
// Includes

#include "FusionMath.h"

//------------------------------------------------------------------------------
// Definitions

/**
 * @brief Gyroscope offset algorithm structure.  Structure members are used
 * internally and must not be accessed by the application.
 */
typedef enum {
    FusionOffsetCalibrationIdle,
    FusionOffsetCalibrationCollecting,
    FusionOffsetCalibrationComplete,
    FusionOffsetCalibrationMoved,
} FusionOffsetCalibrationState;

typedef struct {
    float filterCoefficient;
    unsigned int timeout;
    unsigned int timer;
    FusionVector gyroscopeOffset;
    unsigned int sampleRate;
    unsigned int calibrationSamples;
    FusionVector calibrationMean;
    FusionVector calibrationM2;
    FusionOffsetCalibrationState calibrationState;
    bool manualBias;
} FusionOffset;

//------------------------------------------------------------------------------
// Function declarations

void FusionOffsetInitialise(FusionOffset *const offset, const unsigned int sampleRate);

FusionVector FusionOffsetUpdate(FusionOffset *const offset, FusionVector gyroscope);

/** Explicit two-second stationary calibration. Motion rejects the entire window. */
void FusionOffsetBeginCalibration(FusionOffset *const offset);
void FusionOffsetCancelCalibration(FusionOffset *const offset);
FusionOffsetCalibrationState FusionOffsetGetCalibrationState(const FusionOffset *const offset);
FusionVector FusionOffsetGetBias(const FusionOffset *const offset);
void FusionOffsetSetBias(FusionOffset *const offset, float x, float y, float z);

#endif

//------------------------------------------------------------------------------
// End of file
