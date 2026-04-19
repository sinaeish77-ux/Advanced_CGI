#include <iostream>
#include <vector>
#include <algorithm>

#include <cuda_runtime.h>

#include "opg/opg.h"
#include "opg/imagedata.h"
#include "opg/memory/devicebuffer.h"
#include "opg/glmwrapper.h"
// #include "opg/hostdevice/misc.h"
#include <glm/gtx/string_cast.hpp>
#include "kernels.h"
// #include "kernels.cu"
// #include "kernels.cu"
// #pragma cuda_source_property_format=OBJ

void taskA()
{
    /* Task:
     * Using the GLM math library:
     * - Consider the equation $<n, x> + d = 0$ in 3d space that holds for all points on a plane, where n is a unit-length vector and d is a scalar.
     *   Determine the parameters n, d that describes the plane spanned by the given plane points.
     * - Swap the y and z components of the plane normal.
     * - Find the intersection point between the *new* plane (modified n, old d) and the ray.
     *    - Note: the ray parameters are given as CUDA-builtin float3 vectors.
     *    - Convert the ray parameters to glm::vec3 using the cuda2glm() function.
     *    - Implement the ray-plane intersection.
     *    - Convert the intersection point back to a CUDA-builtin float3 vector using the glm2cuda() function.
     */

    std::cout << "taskA output:" << std::endl;

    // Plane equiation: dot(n, x) + d = 0
    glm::vec3 plane_point_1 = glm::vec3(3, 0, 2);
    glm::vec3 plane_point_2 = glm::vec3(4, 3, 2);
    glm::vec3 plane_point_3 = glm::vec3(1, 2, 4);

    // TODO implement
    glm::vec3 plane_normal;
    glm::vec3 p12 = plane_point_2 - plane_point_1;
    glm::vec3 p23 = plane_point_3 - plane_point_2;
    plane_normal = glm::normalize(glm::cross(p12, p23));
    float  plane_d = -glm::dot(plane_normal, plane_point_1);


    //

    std::cout << "\tplane normal:             " << glm::to_string(plane_normal) << ", plane offset: " << plane_d << std::endl;

    // TODO swap plane_normal y,z components
    plane_normal = glm::vec3(
        plane_normal.x,
        plane_normal.z,
        plane_normal.y
    );
    //

    std::cout << "\tswizzled plane normal:    " << glm::to_string(plane_normal) << std::endl;

    // Ray equation: x = origin + t * dir
    float3 ray_origin_cudafloat3 = make_float3(1, 4, 2);
    float3 ray_dir_cudafloat3 = make_float3(2, 4, 3);

    float3 intersection_cudafloat3;
    // TOOD:
    // - convert ray parameters to GLM vectors using cuda2glm() function.
    glm::vec3 ray_origin = cuda2glm(ray_origin_cudafloat3);
    glm::vec3 ray_dir    = cuda2glm(ray_dir_cudafloat3);

    // - implement ray-plane intersection.
    float t = -(glm::dot(plane_normal, ray_origin) + plane_d) / glm::dot(plane_normal, ray_dir);
    // - convert intersection point back to float3 type using glm2cuda() function.
    if (t <= 0)
    {
        std::cout << "\tno intersection or ray is parallel to plane(no intersection or infinite)" << std::endl;
        return;
    }
    glm::vec3 intersection = ray_origin + t * ray_dir;
    intersection_cudafloat3 = glm2cuda(intersection);

    std::cout << "\tray-plane intersection at (" << intersection_cudafloat3.x << " " << intersection_cudafloat3.y << " " << intersection_cudafloat3.z << ")" << std::endl;
}

void taskB()
{
    /* Task:
     * - Generate an array containing integer numbers 1..1e7 and copy it to the GPU.
     * - Use a CUDA kernel to multiply each number by a constant in parallel.
     * - Copy the result back to the CPU host memory.
     */

    // Use dataArray as your host memory
    std::vector<int> dataArray;
    for (int i = 1; i <= 10000000; ++i)
    {
        dataArray.push_back(i);
    }
    // Use d_dataArray as a pointer to device memory
    int *d_dataArray;
    cudaMalloc(&d_dataArray, dataArray.size() * sizeof(int));
    cudaMemcpy(d_dataArray, dataArray.data(), dataArray.size() * sizeof(int), cudaMemcpyHostToDevice);

    int blockSize = 256;
    int gridSize = (dataArray.size() + blockSize - 1) / blockSize;

    int factor = 3;

    // multiplyKernel<<<gridSize, blockSize>>>(d_dataArray, dataArray.size(), factor);
    launchMultiplyKernel(d_dataArray, dataArray.size(), factor);
    cudaMemcpy(dataArray.data(), d_dataArray, dataArray.size() * sizeof(int), cudaMemcpyDeviceToHost);
    cudaFree(d_dataArray);

    std::cout << "taskB output:" << std::endl;
    std::cout << "\tfirst 10 entries:";
    for (int i = 0; i < std::min<int>(dataArray.size(), 10); ++i)
    {
        std::cout << " " << dataArray[i];
    }
    std::cout << std::endl;
    std::cout << "\tlast 10 entries:";
    for (int i = std::max<int>(dataArray.size()-10, 0); i < dataArray.size(); ++i)
    {
        std::cout << " " << dataArray[i];
    }
    std::cout << std::endl;
}

void taskC()
{
    opg::ImageData imageData;
    std::string filename = opg::getRootPath() + "/data/exercise00_CUDAIntro/Valve.png";
    opg::readImage(filename.c_str(), imageData);
    uint32_t channelSize  = opg::getImageFormatChannelSize(imageData.format);
    uint32_t channelCount = opg::getImageFormatChannelCount(imageData.format);
    OPG_CHECK(channelSize == 1);
    int w    = imageData.width;
    int h    = imageData.height;
    int size = w * h;

    uint8_t *d_input, *d_output;
    float   *d_avg, *d_tmp, *d_gx, *d_gy;

    cudaMalloc(&d_input,  size * channelCount);
    cudaMalloc(&d_output, size);
    cudaMalloc(&d_avg,    size * sizeof(float));
    cudaMalloc(&d_tmp,    size * sizeof(float));
    cudaMalloc(&d_gx,     size * sizeof(float));
    cudaMalloc(&d_gy,     size * sizeof(float));

    cudaMemcpy(d_input, imageData.data.data(), size * channelCount, cudaMemcpyHostToDevice);

    launchGrayScaleConverterKernel(d_input, d_avg, w, h, size);
    CUDA_SYNC_CHECK();

    launchSeparableSobelKernel(d_avg, d_output, d_tmp, d_gx, d_gy, w, h, size);
    CUDA_SYNC_CHECK();

    std::vector<uint8_t> gray(size);
    cudaMemcpy(gray.data(), d_output, size, cudaMemcpyDeviceToHost);

    for (int i = 0; i < size; i++)
        for (uint32_t c = 0; c < channelCount; c++)
            imageData.data[i * channelCount + c] = gray[i];

    cudaFree(d_input);
    cudaFree(d_output);
    cudaFree(d_avg);
    cudaFree(d_tmp);
    cudaFree(d_gx);
    cudaFree(d_gy);

    std::cout << "taskC output written." << std::endl;
    opg::writeImagePNG("taskC_output.png", imageData);
}

void taskD()
{

    /* Task:
     * - Create an array of uniformly distributed (pseudo) random floats in [0, 1] on the GPU.
     *   You can use tea<4>(a, b) to initialize a random number generator, and rnd(seed) to generate a pseudo random number on the GPU. (See sutil/cuda/random.h)
     * - Count all entries that are greater than 0.5 in parallel.
     */
    float threshold = 0.5f;
    int totalCount = 10000000;
    int aboveThresholdCount = 0;

    int* d_counter;
    cudaMalloc(&d_counter, sizeof(int));
    cudaMemset(d_counter, 0, sizeof(int));

    int blockSize = 256;
    int gridSize = (totalCount + blockSize - 1) / blockSize;

    launchCounterKernel(d_counter, totalCount, threshold);
    // Copy result back
    cudaMemcpy(&aboveThresholdCount, d_counter, sizeof(uint32_t ), cudaMemcpyDeviceToHost);

    cudaFree(d_counter);

    std::cout << "taskD output:" << std::endl;
    std::cout << "\t" << aboveThresholdCount << "/" << totalCount
              << " values are greater than " << threshold << std::endl;
}


void taskE()
{
    /* Task:
     * - Implement a matrix multiplication in a CUDA kernel.
     *   Store your matrices in row major order (https://en.wikipedia.org/wiki/Row-_and_column-major_order).
     */

    int lhsRows = 4;
    int lhsCols = 10;
    std::vector<float> lhs = { // 4x10
        97, 95, 80, 31, 31, 72,  1,  2, 88, 93,
        46, 58, 54, 94, 84, 59, 75,  4, 78, 62,
        44, 92, 14, 83, 82, 47, 78, 88, 28, 12,
        22, 96, 61, 93, 95, 77, 27, 35, 58, 53
    };
    int rhsRows = 10;
    int rhsCols = 3;
    std::vector<float> rhs = { // 10x3
        79, 64, 67,
        67, 14, 43,
        68, 17, 43,
        75,  4,  3,
        94, 81, 83,
         1, 56, 18,
        52, 59,  0,
        88, 89, 96,
        93, 66, 76,
        38, 33, 12
    };
    int outputRows = 4;
    int outputCols = 3;
    std::vector<float> output;

    int outputSize = outputRows * outputCols;
    float* d_lhs, *d_rhs, *d_output;
    cudaMalloc(&d_lhs, lhs.size() * sizeof(float));
    cudaMalloc(&d_rhs, rhs.size() * sizeof(float));
    cudaMalloc(&d_output, outputSize * sizeof(float));

    cudaMemcpy(d_lhs, lhs.data(), lhs.size() * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(d_rhs, rhs.data(), rhs.size() * sizeof(float), cudaMemcpyHostToDevice);

    launchMatrixMultiplicationKernel(d_lhs, d_rhs, d_output, lhsRows, lhsCols, rhsRows, rhsCols);
    cudaMemcpy(output.data(), d_output, output.size() * sizeof(float), cudaMemcpyDeviceToHost);

    cudaFree(d_lhs);
    cudaFree(d_rhs);
    cudaFree(d_output);

    output.resize(outputRows * outputCols);
    // Expected output:
    // 36725, 24679, 25982,
    // 40059, 27133, 23270,
    // 39432, 28626, 26127,
    // 40192, 26453, 26179

    //

    std::cout << "taskE output:" << std::endl;
    for (int r = 0; r < outputRows; ++r)
    {
        std::cout << "\t";
        for (int c = 0; c < outputCols; ++c)
        {
            std::cout << " " << output[r * outputCols + c];
        }
        std::cout << std::endl;
    }
}

int main()
{
    taskA();
    taskB();
    taskC();
    taskD();
    taskE();
}
