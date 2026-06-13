#include "lightsources.cuh"

#include "opg/scene/interface/emitter.cuh"
#include "opg/scene/utility/interaction.cuh"
#include "opg/hostdevice/binarysearch.h"
#include "opg/hostdevice/coordinates.h"

#include <optix.h>


extern "C" __device__ EmitterSamplingResult __direct_callable__pointlight_sampleLight(const Interaction &si, PCG32 &unused_rng)
{
    const PointLightData *sbt_data = *reinterpret_cast<const PointLightData **>(optixGetSbtDataPointer());

    glm::vec3 dir_to_light = sbt_data->position - si.position;

    EmitterSamplingResult result;
    result.radiance_weight_at_receiver = sbt_data->intensity / glm::dot(dir_to_light, dir_to_light);
    result.direction_to_light = glm::normalize(dir_to_light);
    result.distance_to_light = glm::length(dir_to_light);
    result.sampling_pdf = 1;
    return result;
}

extern "C" __device__ EmitterSamplingResult __direct_callable__directionallight_sampleLight(const Interaction &si, PCG32 &unused_rng)
{
    const DirectionalLightData *sbt_data = *reinterpret_cast<const DirectionalLightData **>(optixGetSbtDataPointer());

    glm::vec3 dir_to_light = sbt_data->direction;

    EmitterSamplingResult result;
    result.radiance_weight_at_receiver = sbt_data->irradiance_at_receiver;
    result.direction_to_light = glm::normalize(dir_to_light);
    result.distance_to_light = std::numeric_limits<float>::infinity();
    result.sampling_pdf = 1;
    return result;
}


//



extern "C" __device__ glm::vec3 __direct_callable__spherelight_evalLight(const SurfaceInteraction &si)
{
    const SphereLightData *sbt_data = *reinterpret_cast<const SphereLightData **>(optixGetSbtDataPointer());
    // We can assume that si is actually on the surface of the light source

    // The emitted radiance is constant across the light source
    return sbt_data->radiance;
}

extern "C" __device__ EmitterSamplingResult __direct_callable__spherelight_sampleLight(const Interaction &si, PCG32 &rng)
{
    const SphereLightData *sbt_data = *reinterpret_cast<const SphereLightData **>(optixGetSbtDataPointer());

    // Some useful quantities
    glm::vec3 light_center_dir = glm::normalize(sbt_data->position - si.position);
    float light_center_distance = glm::length(sbt_data->position - si.position);
    float cap_height = 1 - glm::sqrt(light_center_distance*light_center_distance - sbt_data->radius*sbt_data->radius) / light_center_distance;

    // A transformation matrix that rotates the z axis to the light_center_dir
    glm::mat3 local_frame = opg::compute_local_frame(light_center_dir);


    EmitterSamplingResult result;
    result.sampling_pdf = 0; // initialize with invalid sample

    /* Implement:
     * - Sample the direction from the given shading point (si) towards a random point on the sphere that is the light source.
     * Hint: From the point of view of the given shading point (si), the sphere light source simply looks like a uniform disk on the sky.
     * Consider the spherical cap [1] that corresponds to the projection of the light source onto the sphere of all directions at the given surface interaction.
     * [1] https://en.wikipedia.org/wiki/Spherical_cap
     */

    // TODO implement
    if (light_center_distance <= sbt_data->radius)
        return result;

    glm::vec2 u = rng.next2d();

    float cos_theta = 1.0f - cap_height * u.x;
    float sin_theta = glm::sqrt(glm::max(0.0f, 1.0f - cos_theta * cos_theta));
    float phi = 2.0f * glm::pi<float>() * u.y;

    glm::vec3 local_dir(
        sin_theta * glm::cos(phi),
        sin_theta * glm::sin(phi),
        cos_theta
    );

    glm::vec3 dir_to_light = glm::normalize(local_frame * local_dir);

    float pdf = 1.0f / (2.0f * glm::pi<float>() * cap_height);

    glm::vec3 oc = si.position - sbt_data->position;
    float b = glm::dot(oc, dir_to_light);
    float c = glm::dot(oc, oc) - sbt_data->radius * sbt_data->radius;
    float discr = b * b - c;

    if (discr < 0.0f)
        return result;

    float t = -b - glm::sqrt(discr);
    if (t <= 0.0f)
        return result;

    glm::vec3 light_position = si.position + t * dir_to_light;

    result.direction_to_light = dir_to_light;
    result.distance_to_light = t;
    result.normal_at_light = glm::normalize(light_position - sbt_data->position);
    result.sampling_pdf = pdf;
    result.radiance_weight_at_receiver = sbt_data->radiance / pdf;
    //

    return result;
}

extern "C" __device__ float __direct_callable__spherelight_evalLightSamplingPDF(const Interaction &si, const SurfaceInteraction &si_on_light)
{
    const SphereLightData *sbt_data = *reinterpret_cast<const SphereLightData **>(optixGetSbtDataPointer());
    // We can assume that outgoing ray dir actually intersects the light source.

    // Some useful quantities
    float light_center_distance = glm::length(sbt_data->position - si.position);
    float cap_height = 1 - glm::sqrt(light_center_distance*light_center_distance - sbt_data->radius*sbt_data->radius) / light_center_distance;

    /* Implement:
     * - Compute the probability of sampling the direction towards the surface interaction on the light source (si_on_light) from the surface interaction at a shading point (si) via light source sampling.
     */

    float sampling_pdf = 0;

    // TODO implement
    if (light_center_distance <= sbt_data->radius || cap_height <= 0.0f)
        return 0.0f;

    sampling_pdf = 1.0f / (2.0f * glm::pi<float>() * cap_height);
    //

    return sampling_pdf;
}


extern "C" __device__ glm::vec3 __direct_callable__meshlight_evalLight(const SurfaceInteraction &si)
{
    const MeshLightData *sbt_data = *reinterpret_cast<const MeshLightData **>(optixGetSbtDataPointer());
    // We can assume that si is actually on the surface of the light source

    // The emitted radiance is constant across the light source
    return sbt_data->radiance;
}

extern "C" __device__ EmitterSamplingResult __direct_callable__meshlight_sampleLight(const Interaction &si, PCG32 &rng)
{
    const MeshLightData *sbt_data = *reinterpret_cast<const MeshLightData **>(optixGetSbtDataPointer());

    /* Implement:
     * - Sample the direction from the given shading point (si) towards a random point on the mesh that is the light source.
     *     - Select a (random) triangle from the mesh with probability proportional to its surface area.
     *     - Compute the barycentric coordinates of a random point on the unit triangle.
     *     - Fill the `EmitterSamplingResult` structure at the end of this method.
     * Hint: Do a binary search in the cummulative probability distribution over the triangles (sbt_data->mesh_cdf).
     *       The selected triangle and barycentric coordinates on the unit triangle are subsequently used to construct the corresponding point on the triangle in world space.
     */

    // Select the triangle to sample a direction from uniformly at random, proportional to its surface area
    uint32_t triangle_index = 0;
    // Sample the barycentric coordinates on the triangle uniformly.
    glm::vec2 triangle_barys = glm::vec2(0, 0);

    // TODO implement
    triangle_index = opg::binary_search(sbt_data->mesh_cdf, rng.next1d());

    glm::vec2 u = rng.next2d();
    float sqrt_u = glm::sqrt(u.x);

    triangle_barys = glm::vec2(
        sqrt_u * (1.0f - u.y),
        sqrt_u * u.y
    );
    // 


    // Compute the `light_position` using the triangle_index and the triangle_barys on the mesh:

    // Indices of triangle vertices in the mesh
    glm::uvec3 vertex_indices = glm::uvec3(0u);
    if (sbt_data->mesh_indices.elmt_byte_size == sizeof(glm::u32vec3))
    {
        // Indices stored as 32-bit unsigned integers
        const glm::u32vec3* indices = reinterpret_cast<glm::u32vec3*>(sbt_data->mesh_indices.data);
        vertex_indices = glm::uvec3(indices[triangle_index]);
    }
    else
    {
        // Indices stored as 16-bit unsigned integers
        const glm::u16vec3* indices = reinterpret_cast<glm::u16vec3*>(sbt_data->mesh_indices.data);
        vertex_indices = glm::uvec3(indices[triangle_index]);
    }

    // Vertex positions of selected triangle
    glm::vec3 P0 = sbt_data->mesh_positions[vertex_indices.x];
    glm::vec3 P1 = sbt_data->mesh_positions[vertex_indices.y];
    glm::vec3 P2 = sbt_data->mesh_positions[vertex_indices.z];

    // Compute local position
    glm::vec3 local_light_position = (1.0f-triangle_barys.x-triangle_barys.y)*P0 + triangle_barys.x*P1 + triangle_barys.y*P2;
    // Transform local position to world position
    glm::vec3 light_position = glm::vec3(sbt_data->local_to_world * glm::vec4(local_light_position, 1));

    // Compute local normal
    glm::vec3 local_light_normal = glm::cross(P1-P0, P2-P0);
    // Normals are transformed by (A^-1)^T instead of A
    glm::vec3 light_normal = glm::normalize(glm::transpose(glm::mat3(sbt_data->world_to_local)) * local_light_normal);


    // Assemble sampling result

    EmitterSamplingResult result;
    result.sampling_pdf = 0; // initialize with invalid sample

    // TODO implement
    glm::vec3 dir_to_light = light_position - si.position;
    float distance_squared = glm::dot(dir_to_light, dir_to_light);
    float distance = glm::sqrt(distance_squared);

    if (distance <= 0.0f)
        return result;

    dir_to_light /= distance;

    // This codebase treats mesh lights as double-sided.
    float cos_theta_light = glm::abs(glm::dot(light_normal, -dir_to_light));

    if (cos_theta_light <= 0.0f)
        return result;

    float area_pdf = 1.0f / sbt_data->total_surface_area;
    float direction_pdf = area_pdf * distance_squared / cos_theta_light;

    result.direction_to_light = dir_to_light;
    result.distance_to_light = distance;
    result.normal_at_light = light_normal;
    result.sampling_pdf = direction_pdf;
    result.radiance_weight_at_receiver = sbt_data->radiance / direction_pdf;
    //

    return result;
}

extern "C" __device__ float __direct_callable__meshlight_evalLightSamplingPDF(const Interaction &si, const SurfaceInteraction &si_on_light)
{
    const MeshLightData *sbt_data = *reinterpret_cast<const MeshLightData **>(optixGetSbtDataPointer());
    // We can assume that outgoing ray dir actually intersects the light source.

    // Some useful quantities
    glm::vec3 light_normal = si_on_light.normal;
    glm::vec3 light_ray_dir = si_on_light.incoming_ray_dir; // glm::normalize(si_on_light.position - si.position);
    float light_ray_length = si_on_light.incoming_distance; // glm::length(si_on_light.position - si.position);

    /* Implement:
     * - Compute the probability of sampling the direction towards the surface interaction on the light source (si_on_light) from the surface interaction at a shading point (si) via light source sampling.
     */

    float light_direction_pdf = 0;

    // TODO implement
    float cos_theta_light = glm::abs(glm::dot(light_normal, -light_ray_dir));

    if (cos_theta_light <= 0.0f)
        return 0.0f;

    float area_pdf = 1.0f / sbt_data->total_surface_area;
    light_direction_pdf = area_pdf * light_ray_length * light_ray_length / cos_theta_light;
    //

    return light_direction_pdf;
}
