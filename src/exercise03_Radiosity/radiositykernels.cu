#include "radiositykernels.h"
#include "opg/hostdevice/misc.h"

#pragma cuda_source_property_format=OBJ


__global__ void k_init_radiosity(
    glm::vec3       *radiosity,
    const glm::vec3 *emissions,
    uint32_t         count)
{
    uint32_t i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= count) return;

    // Initial radiosity is just the light emitted by the surface
    radiosity[i] = emissions[i];
}


__global__ void k_jacobi_iteration(
    glm::vec3       *radiosity_out,
    const glm::vec3 *radiosity_in,
    const glm::vec3 *emissions,
    const glm::vec3 *albedos,
    const float     *form_factor_matrix,
    uint32_t         values_count,
    float            lambda)
{
    uint32_t i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= values_count) return;


    glm::vec3 incoming_light(0.0f);
    
    const float* row_i = &form_factor_matrix[i * values_count];

    for (uint32_t j = 0; j < values_count; ++j)
    {
        float F_ij = row_i[j];
        if (F_ij > 0.0f) 
        {
            incoming_light += F_ij * radiosity_in[j];
        }
    }

    glm::vec3 target_radiosity = emissions[i] + albedos[i] * incoming_light;
    radiosity_out[i] = radiosity_in[i] + lambda * (target_radiosity - radiosity_in[i]);
}

void init_radiosity(
    glm::vec3       *radiosity,
    const glm::vec3 *emissions,
    uint32_t         count)
{
    dim3 block(512);
    dim3 grid((count + 511) / 512);
    k_init_radiosity<<<grid, block>>>(radiosity, emissions, count);
}

void jacobi_iteration(
    glm::vec3       *radiosity_out,
    const glm::vec3 *radiosity_in,
    const glm::vec3 *emissions,
    const glm::vec3 *albedos,
    const float     *form_factor_matrix,
    uint32_t         values_count,
    float            lambda)
{
    dim3 block(512);
    dim3 grid((values_count + 511) / 512);
    k_jacobi_iteration<<<grid, block>>>(
        radiosity_out, radiosity_in,
        emissions, albedos,
        form_factor_matrix,
        values_count, lambda);
}