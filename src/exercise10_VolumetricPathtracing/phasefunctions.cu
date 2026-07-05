#include "phasefunctions.cuh"
#include "opg/scene/utility/interaction.cuh"
#include "opg/hostdevice/coordinates.h"


__forceinline__ __device__ glm::vec3 warp_square_to_sphere_uniform(const glm::vec2 uv)
{
    float z   = uv.x * 2 - 1;
    float phi = uv.y * 2 * glm::pi<float>();

    float r = glm::sqrt( glm::max(0.0f, 1 - z*z) );
    float x = r * glm::cos(phi);
    float y = r * glm::sin(phi);

    return glm::vec3(x, y, z);
}

__forceinline__ __device__ float warp_square_to_sphere_uniform_pdf(const glm::vec3 &dir)
{
    return 1 / (4 * glm::pi<float>());
}


// 


extern "C" __device__ PhaseFunctionEvalResult __direct_callable__henyeygreenstein_evalPhaseFunction(const MediumInteraction &interaction, const glm::vec3 &outgoing_ray_dir)
{
    const HenyeyGreensteinPhaseFunctionData *sbt_data = *reinterpret_cast<const HenyeyGreensteinPhaseFunctionData **>(optixGetSbtDataPointer());

    /* Implement:
     * - Compute the phase-function value for `outgoing_ray_dir`.
     * - Compute the sampling probability of generating the `outgoing_ray_dir` using phase-function importance sampling.
     */

    float g = sbt_data->g;
    float cos_theta = glm::dot(glm::normalize(interaction.incoming_ray_dir), glm::normalize(outgoing_ray_dir));
    cos_theta = glm::clamp(cos_theta, -1.0f, 1.0f);
    
    float denom = 1.0f + g * g - 2.0f * g * cos_theta;
    float phase_value = (1.0f - g * g) / (4.0f * glm::pi<float>() * denom * glm::sqrt(denom));
    
    PhaseFunctionEvalResult result;
    result.phase_function_value = glm::vec3(phase_value);
    result.sampling_pdf = phase_value;
    
    return result;
}

extern "C" __device__ PhaseFunctionSamplingResult __direct_callable__henyeygreenstein_samplePhaseFunction(const MediumInteraction &interaction, PCG32 &rng)
{
    const HenyeyGreensteinPhaseFunctionData *sbt_data = *reinterpret_cast<const HenyeyGreensteinPhaseFunctionData **>(optixGetSbtDataPointer());

    /* Implement:
     * - Sample a direction from the henyey greenstein phase function using the g-parameter stored in the sbt_data.
     * - Compute the respective phase function value.
     * - Compute the respective sampling probability.
     */

    //

    float g = sbt_data->g;
    glm::vec2 uv = rng.next2d();

    float cos_theta;
    if (glm::abs(g) < 1e-4f)
    {
        cos_theta = 2.0f * uv.x - 1.0f;
    }
    else
    {
        float t = (1.0f - g * g) / (1.0f - g + 2.0f * g * uv.x);
        cos_theta = (1.0f + g * g - t * t) / (2.0f * g);
    }
    cos_theta = glm::clamp(cos_theta, -1.0f, 1.0f);

    float sin_theta = glm::sqrt(glm::max(0.0f, 1.0f - cos_theta * cos_theta));
    float phi = 2.0f * glm::pi<float>() * uv.y;

    glm::vec3 local_dir(sin_theta * glm::cos(phi), sin_theta * glm::sin(phi), cos_theta);

    glm::vec3 forward = glm::normalize(interaction.incoming_ray_dir);
    glm::mat3 local_frame = opg::compute_local_frame(forward);

    PhaseFunctionSamplingResult result;
    result.outgoing_ray_dir = glm::normalize(local_frame * local_dir);

    float denom = 1.0f + g * g - 2.0f * g * cos_theta;
    float phase_value = (1.0f - g * g) / (4.0f * glm::pi<float>() * denom * glm::sqrt(denom));

    result.sampling_pdf = phase_value;
    result.phase_function_weight = result.sampling_pdf > 0.0f
            ? glm::vec3(phase_value / result.sampling_pdf)
            : glm::vec3(0);

    return result;
}
