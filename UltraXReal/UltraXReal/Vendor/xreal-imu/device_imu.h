#pragma once
//
// Created by thejackimonster on 30.03.23.
//
// Copyright (c) 2023-2024 thejackimonster. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//

#ifndef __cplusplus
#include <stdbool.h>
#endif

#ifndef __cplusplus
#include <stdint.h>
#else
#include <cstdint>
#endif

#define DEVICE_IMU_MSG_GET_CAL_DATA_LENGTH 0x14
#define DEVICE_IMU_MSG_CAL_DATA_GET_NEXT_SEGMENT 0x15
#define DEVICE_IMU_MSG_ALLOCATE_CAL_DATA_BUFFER 0x16
#define DEVICE_IMU_MSG_WRITE_CAL_DATA_SEGMENT 0x17
#define DEVICE_IMU_MSG_FREE_CAL_BUFFER 0x18
#define DEVICE_IMU_MSG_START_IMU_DATA 0x19
#define DEVICE_IMU_MSG_GET_STATIC_ID 0x1A
#define DEVICE_IMU_MSG_UNKNOWN 0x1D

#ifdef __cplusplus
extern "C"
{
#endif

	enum device_imu_error_t
	{
		DEVICE_IMU_ERROR_NO_ERROR = 0,
		DEVICE_IMU_ERROR_NO_DEVICE = 1,
		DEVICE_IMU_ERROR_NO_HANDLE = 2,
		DEVICE_IMU_ERROR_NO_ALLOCATION = 3,
		DEVICE_IMU_ERROR_WRONG_SIZE = 4,
		DEVICE_IMU_ERROR_FILE_NOT_OPEN = 5,
		DEVICE_IMU_ERROR_FILE_NOT_CLOSED = 6,
		DEVICE_IMU_ERROR_LOADING_FAILED = 7,
		DEVICE_IMU_ERROR_SAVING_FAILED = 8,
		DEVICE_IMU_ERROR_UNPLUGGED = 9,
		DEVICE_IMU_ERROR_UNEXPECTED = 10,
		DEVICE_IMU_ERROR_WRONG_SIGNATURE = 11,
		DEVICE_IMU_ERROR_INVALID_VALUE = 12,
		DEVICE_IMU_ERROR_NOT_INITIALIZED = 13,
		DEVICE_IMU_ERROR_PAYLOAD_FAILED = 14,
		DEVICE_IMU_ERROR_UNKNOWN = 15,
	};

	struct __attribute__((__packed__)) device_imu_packet_t
	{
		uint8_t signature[2];
		uint8_t temperature[2];
		uint64_t timestamp;
		uint8_t angular_multiplier[2];
		uint8_t angular_divisor[4];
		uint8_t angular_velocity_x[3];
		uint8_t angular_velocity_y[3];
		uint8_t angular_velocity_z[3];
		uint8_t acceleration_multiplier[2];
		uint8_t acceleration_divisor[4];
		uint8_t acceleration_x[3];
		uint8_t acceleration_y[3];
		uint8_t acceleration_z[3];
		uint8_t magnetic_multiplier[2];
		uint8_t magnetic_divisor[4];
		uint8_t magnetic_x[2];
		uint8_t magnetic_y[2];
		uint8_t magnetic_z[2];
		uint32_t checksum;
		uint8_t _padding[6];
	};

	enum device_imu_event_t
	{
		DEVICE_IMU_EVENT_UNKNOWN = 0,
		DEVICE_IMU_EVENT_INIT = 1,
		DEVICE_IMU_EVENT_UPDATE = 2,
	};

	struct device_imu_ahrs_t;
	struct device_imu_calibration_t;

	struct device_imu_vec3_t
	{
		float x;
		float y;
		float z;
	};

	struct device_imu_quat_t
	{
		float x;
		float y;
		float z;
		float w;
	};

	struct device_imu_euler_t
	{
		float roll;
		float pitch;
		float yaw;
	};

	typedef enum device_imu_error_t device_imu_error_type;
	typedef struct device_imu_packet_t device_imu_packet_type;
	typedef enum device_imu_event_t device_imu_event_type;

	typedef struct device_imu_ahrs_t device_imu_ahrs_type;
	typedef struct device_imu_calibration_t device_imu_calibration_type;

	typedef struct device_imu_vec3_t device_imu_vec3_type;
	typedef struct device_imu_quat_t device_imu_quat_type;
	typedef struct device_imu_euler_t device_imu_euler_type;

	typedef void (*device_imu_event_callback)(
			uint64_t timestamp,
			device_imu_event_type event,
			const device_imu_ahrs_type *ahrs);

	struct device_imu_t
	{
		uint16_t vendor_id;
		uint16_t product_id;
		char *serial_number;

		void *handle;

		uint32_t static_id;

		uint64_t last_timestamp;
		float temperature; // (in °C)

		void *offset;
		device_imu_ahrs_type *ahrs;

		device_imu_event_callback callback;
		device_imu_calibration_type *calibration;
	};

	typedef struct device_imu_t device_imu_type;

	device_imu_error_type device_imu_open(device_imu_type *device, device_imu_event_callback callback);

	device_imu_error_type device_imu_reset_calibration(device_imu_type *device);

	device_imu_error_type device_imu_load_calibration(device_imu_type *device, const char *path);

	device_imu_error_type device_imu_save_calibration(device_imu_type *device, const char *path);

	device_imu_error_type device_imu_clear(device_imu_type *device);

	device_imu_error_type device_imu_calibrate(device_imu_type *device, uint32_t iterations, bool gyro, bool accel, bool magnet);

	device_imu_error_type device_imu_read(device_imu_type *device, int timeout);

	device_imu_vec3_type device_imu_get_earth_acceleration(const device_imu_ahrs_type *ahrs);

	device_imu_vec3_type device_imu_get_linear_acceleration(const device_imu_ahrs_type *ahrs);

	device_imu_quat_type device_imu_get_orientation(const device_imu_ahrs_type *ahrs);

	device_imu_euler_type device_imu_get_euler(device_imu_quat_type quat);

	device_imu_error_type device_imu_close(device_imu_type *device);

#ifdef __cplusplus
} // extern "C"
#endif
