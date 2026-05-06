#pragma once

#include "opg/glmwrapper.h"

#include <cuda_runtime.h>


void init_radiosity(
    glm::vec3       *radiosity,
    const glm::vec3 *emissions,
    uint32_t         count);


void jacobi_iteration(
    glm::vec3       *radiosity_out,     
    const glm::vec3 *radiosity_in,      
    const glm::vec3 *emissions,
    const glm::vec3 *albedos,
    const float     *form_factor_matrix,
    uint32_t         values_count,                
    float            lambda);