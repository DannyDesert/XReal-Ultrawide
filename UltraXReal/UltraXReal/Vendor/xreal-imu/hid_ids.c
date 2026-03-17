//
// Created by wheaney on 12.11.23.
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

#include "hid_ids.h"

#ifndef __cplusplus
#include <stdbool.h>
#endif

#ifndef __cplusplus
#include <stdint.h>
#else
#include <cstdint>
#endif

const uint16_t xreal_vendor_id = 0x3318;
const uint16_t xreal_product_ids[NUM_SUPPORTED_PRODUCTS] = {
    0x0424, // XREAL Air
    0x0428, // XREAL Air 2
    0x0432, // XREAL Air 2 Pro
    0x0426  // XREAL Air 2 Ultra
};

const int xreal_imu_interface_ids[NUM_SUPPORTED_PRODUCTS] = {
    3, // XREAL Air
    3, // XREAL Air 2
    3, // XREAL Air 2 Pro
    2  // XREAL Air 2 Ultra
};

const int xreal_mcu_interface_ids[NUM_SUPPORTED_PRODUCTS] = {
    4,  // XREAL Air
    4,  // XREAL Air 2
    4,  // XREAL Air 2 Pro
    0   // XREAL Air 2 Ultra MCU
};

static int xreal_product_index(uint16_t product_id) {
    for (int i = 0; i < NUM_SUPPORTED_PRODUCTS; i++) {
        if (xreal_product_ids[i] == product_id) {
            return i;
        }
    }

    return -1;
}

bool is_xreal_product_id(uint16_t product_id) {
    return xreal_product_index(product_id) >= 0;
}

int xreal_imu_interface_id(uint16_t product_id) {
    const int index = xreal_product_index(product_id);

    if (index >= 0) {
        return xreal_imu_interface_ids[index];
    } else {
        return -1;
    }
}

int xreal_mcu_interface_id(uint16_t product_id) {
    const int index = xreal_product_index(product_id);

    if (index >= 0) {
        return xreal_mcu_interface_ids[index];
    } else {
        return -1;
    }
}
