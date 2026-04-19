#pragma once

// Declare your kernel functions here:
void launchMultiplyKernel(int* d_data, int N, int factor);
void launchSeparableSobelKernel(float* d_input, uint8_t* d_output, float* d_tmp, float* d_gx, float* d_gy, int w, int h, int size);
void launchGrayScaleConverterKernel(uint8_t* d_input, float* d_output, int w, int h, int size);
void launchCounterKernel(int* d_counter, int N, float threshold);
void launchMatrixMultiplicationKernel(float* d_lhs, float* d_rhs, float* d_output, int lhsRows, int lhsCols, int rhsRows, int rhsCols);