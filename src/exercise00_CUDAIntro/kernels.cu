#include <cuda_runtime.h>
#include "opg/hostdevice/random.h"
#include "opg/glmwrapper.h"
#include "opg/hostdevice/misc.h"
#include "opg/exception.h"

#include <cstdint>

#include "kernels.h"


// By default, .cu files are compiled into .ptx files in our framework, that are then loaded by OptiX and compiled
// into a ray-tracing pipeline. In this case, we want the kernels.cu to be compiled as a "normal" .obj file that is
// linked against the application such that we can simply call the functions defined in the kernels.cu file.
// The following custom pragma notifies our build system that this file should be compiled into a "normal" .obj file.
#pragma cuda_source_property_format=OBJ

// //
__global__ void multiplyKernel(int* data, int N, int factor)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;

    if (idx < N)
    {
        data[idx] *= factor;
    }
}

__global__ void pass1_sobel_dx(const float* in, float* out, int w, int h)
{

    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= w || y >= h) return;

    int idx = y * w + x;

    float left  = (x > 0)     ? in[y*w + (x-1)] : 0.0f;
    float right = (x < w-1)   ? in[y*w + (x+1)] : 0.0f;

    out[idx] = (-1.0f * left) + (0.0f) + (1.0f * right);
}

__global__ void pass1_sobel_dy(const float* in, float* out, int w, int h)
{

    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= w || y >= h) return;

    int idx = y * w + x;

    float up   = (y > 0)     ? in[(y-1)*w + x] : 0.0f;
    float down = (y < h-1)   ? in[(y+1)*w + x] : 0.0f;

    out[idx] = (-1.0f * up) + (0.0f) + (1.0f * down);
}

__global__ void pass2_sobel_smooth_y(const float* in, float* out, int w, int h)
{

    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= w || y >= h) return;

    int idx = y * w + x;

    float up   = (y > 0)     ? in[(y-1)*w + x] : 0.0f;
    float mid  = in[idx];
    float down = (y < h-1)   ? in[(y+1)*w + x] : 0.0f;

    out[idx] = (1.0f * up) + (2.0f * mid) + (1.0f * down);
}

__global__ void pass2_sobel_smooth_x(const float* in, float* out, int w, int h)
{

    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= w || y >= h) return;

    int idx = y * w + x;

    float left  = (x > 0)     ? in[y*w + (x-1)] : 0.0f;
    float mid   = in[idx];
    float right = (x < w-1)   ? in[y*w + (x+1)] : 0.0f;

    out[idx] = (1.0f * left) + (2.0f * mid) + (1.0f * right);
}

__global__ void magnitude(const float* gx, const float* gy, uint8_t* out, int N)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= N) return;

    float val = sqrtf(gx[i]*gx[i] + gy[i]*gy[i]);
    out[i] = (uint8_t)min(val, 255.0f);
}

__global__ void grayScaleConverterKernel(uint8_t* in, float* out, int w, int h, int size)
{
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= w || y >= h) return;

    int idx = y * w + x;

    uint8_t r = in[idx * 3 + 0];
    uint8_t g = in[idx * 3 + 1];
    uint8_t b = in[idx * 3 + 2];
    out[idx] = (r + g + b) / 3;
}

__global__ void count(int* counter, int N, float threshold)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= N) return;

    uint32_t seed = sampleTEA32(idx, 0);

    PCG32 rng(seed);

    float r = rng.nextFloat();

    if (r > threshold)
    {
        atomicAdd(counter, 1);
    }
}

__global__ void matrixMultiplicationKernel(float* lhs, float* rhs, float* output, int lhsRows, int lhsCols, int rhsRows, int rhsCols)
{
    int row = blockIdx.y * blockDim.y + threadIdx.y;
    int col = blockIdx.x * blockDim.x + threadIdx.x;

    if (row < lhsRows && col < rhsCols)
    {
        float value = 0.0f;
        for (int k = 0; k < lhsCols; ++k)
        {
            value += lhs[row * lhsCols + k] * rhs[k * rhsCols + col];
        }
        output[row * rhsCols + col] = value;
    }
}

void launchMultiplyKernel(int* d_data, int N, int factor)
{
    int blockSize = 256;
    int gridSize = (N + blockSize - 1) / blockSize;

    multiplyKernel<<<gridSize, blockSize>>>(d_data, N, factor);

    cudaDeviceSynchronize();
}

void launchGrayScaleConverterKernel(uint8_t* d_input, float* d_output, int w, int h, int size)
{
    dim3 blockSize(16, 16);
    dim3 gridSize((w + blockSize.x - 1) / blockSize.x, (h + blockSize.y - 1) / blockSize.y);

    grayScaleConverterKernel<<<gridSize, blockSize>>>(d_input, d_output, w, h, size);
}

void launchSeparableSobelKernel(float* d_input, uint8_t* d_output, float* d_tmp, float* d_gx, float* d_gy, int w, int h, int size)
{
    dim3 blockSize(16, 16);
    dim3 gridSize((w + blockSize.x - 1) / blockSize.x, (h + blockSize.y - 1) / blockSize.y);

    pass1_sobel_dx<<<gridSize, blockSize>>>(d_input, d_tmp, w, h);
    CUDA_SYNC_CHECK();  

    pass2_sobel_smooth_y<<<gridSize, blockSize>>>(d_tmp, d_gx, w, h);
    CUDA_SYNC_CHECK();   

    pass1_sobel_dy<<<gridSize, blockSize>>>(d_input, d_tmp, w, h);
    CUDA_SYNC_CHECK(); 

    pass2_sobel_smooth_x<<<gridSize, blockSize>>>(d_tmp, d_gy, w, h);
    CUDA_SYNC_CHECK();  

    // ================= MAGNITUDE =================
    int block1D = 256;
    int grid1D  = (size + block1D - 1) / block1D;

    magnitude<<<grid1D, block1D>>>(d_gx, d_gy, d_output, size);
    CUDA_SYNC_CHECK();
}

void launchCounterKernel(int* d_counter, int N, float threshold)
{
    int blockSize = 256;
    int gridSize = (N + blockSize - 1) / blockSize;

    count<<<gridSize, blockSize>>>(d_counter, N, threshold);
}

void launchMatrixMultiplicationKernel(float* d_lhs, float* d_rhs, float* d_output, int lhsRows, int lhsCols, int rhsRows, int rhsCols)
{
    dim3 blockSize(16, 16);
    dim3 gridSize((rhsCols + blockSize.x - 1) / blockSize.x, (lhsRows + blockSize.y - 1) / blockSize.y);

    matrixMultiplicationKernel<<<gridSize, blockSize>>>(d_lhs, d_rhs, d_output, lhsRows, lhsCols, rhsRows, rhsCols);
    CUDA_SYNC_CHECK();
}