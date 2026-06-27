#include <cuda_runtime.h>
#include <optix.h>
#include "opg/raytracing/optixglm.h"

#include "bdptraygenerator.cuh"

#include "opg/hostdevice/ray.h"
#include "opg/hostdevice/color.h"
#include "opg/hostdevice/binarysearch.h"
#include "opg/scene/utility/interaction.cuh"
#include "opg/scene/utility/trace.cuh"
#include "opg/scene/interface/bsdf.cuh"
#include "opg/scene/interface/emitter.cuh"

__constant__ PathtracingLaunchParams params;

extern "C" __global__ void __miss__main()
{
    SurfaceInteraction *si = getPayloadDataPointer<SurfaceInteraction>();

    const glm::vec3 world_ray_origin = optixGetWorldRayOriginGLM();
    const glm::vec3 world_ray_dir    = optixGetWorldRayDirectionGLM();
    const float     tmax             = optixGetRayTmax();

    si->incoming_ray_dir = world_ray_dir;

    // No valid interaction found, set incoming_distance to NaN
    si->set_invalid();
}

extern "C" __global__ void __miss__occlusion()
{
    setOcclusionPayload(false);
}

// The context of a ray holds all relevant variables that need to "survive" each ray tracing iteration.
struct RayContext
{
    // Is the ray valid and should we continue tracing?
    bool        valid;
    // The ray that we are currently shooting through the scene.
    opg::Ray    ray;
    // How much is the radiance going to be attenuated between the current ray and the camera (based on all previous interactions).
    glm::vec3   throughput;
    // The depth of this ray, i.e. the number of bounces between the camera and this ray
    uint32_t    depth;
};

__forceinline__ __device__ float solidAngleToAreaPdf(float pdf_solid_angle, const glm::vec3 &dir, const glm::vec3 &to_normal, float dist_squared)
{
    float cos_theta = glm::abs(glm::dot(dir, to_normal));
    return pdf_solid_angle * cos_theta / glm::max(dist_squared, 1e-12f);
}


__forceinline__ __device__ float multiple_importance_weight(float this_pdf, float other_pdf)
{
    // Power heuristic with p=2
    //this_pdf *= this_pdf;
    //other_pdf *= other_pdf;
    //return this_pdf / (this_pdf + other_pdf);

    // Balance heuristic with p=1
    return this_pdf / (this_pdf + other_pdf);
}

__forceinline__ __device__ void trace_subpath(RayContext &ray_ctx, opg::Vector<PathVertex, MAX_SUB_PATH_VERTEX_COUNT> *subpath, PCG32 &rng)
{
    // Bound the number of trace operations that are executed in any case.
    // Accidentally creating infinite loops on the GPU is unpleasant.
    for (int i = 0; i < MAX_TRACE_OPS; ++i)
    {
        if (!ray_ctx.valid)
            break;

        // Trace current ray
        SurfaceInteraction si;
        traceWithDataPointer<SurfaceInteraction>(
                params.traversable_handle,
                ray_ctx.ray.origin,
                ray_ctx.ray.direction,
                params.scene_epsilon,                   // tmin: Start ray at ray_origin + tmin * ray_direction
                std::numeric_limits<float>::infinity(), // tmax: End ray at ray_origin + tmax * ray_direction
                params.surface_interaction_trace_params,
                &si
        );

        // Terminate this ray
        if (!si.is_finite())
        {
            ray_ctx.valid = false;
            break;
        }

        if (si.bsdf == nullptr)
        {
            ray_ctx.valid = false;
            break;
        }

        // No further indirect bounces for this surface interaction if ray depth is exceeded
        if (ray_ctx.depth >= MAX_TRACE_DEPTH)
        {
            ray_ctx.valid = false;
            break;
        }

        // Add a path vertex to subpath
        PathVertex vertex;
        vertex.si = si;
        vertex.throughput_weight = ray_ctx.throughput;
        subpath->push_back(vertex);
        if (subpath->full())
        {
            ray_ctx.valid = false;
            break;
        }

        // Increase ray depth for recursive ray.
        ray_ctx.depth += 1;

        // BSDF sampling, generate next ray
        BSDFSamplingResult bsdf_sampling_result = si.bsdf->sampleBSDF(si, +BSDFComponentFlag::Any, rng);
        if (bsdf_sampling_result.sampling_pdf == 0)
        {
            ray_ctx.valid = false;
            break;
        }

        ray_ctx.ray.direction = glm::normalize(bsdf_sampling_result.outgoing_ray_dir);
        ray_ctx.ray.origin = si.position;
        ray_ctx.throughput *= bsdf_sampling_result.bsdf_weight;

        // Check if the sampled ray is inconsistent wrt. geometric and shading normal...
        if (glm::dot(ray_ctx.ray.direction, si.geom_normal) * glm::dot(ray_ctx.ray.direction, si.normal) <= 0)
        {
            ray_ctx.valid = false;
            break;
        }
    }
}


// Sample a new photon uniformly from all light sources in the scene.
// This implies that large light sources are sampled more frequently and brighter light sources are sampled more frequently.
// The relative weighting of the light sources is handled via the params.lights_cdf.
__device__ EmitterPhotonSamplingResult samplePhotonFromAllEmitters(PCG32 &rng)
{
    // Choose a light source using binary search in CDF values
    uint32_t emitter_index = opg::binary_search(params.emitters_cdf, rng.next1d());
    // The selected emitter
    const EmitterVPtrTable *emitter = params.emitters[emitter_index];
    // Probability of selecting this emitter:
    float emitter_selection_pdf = params.emitters_cdf[emitter_index] - (emitter_index > 0 ? params.emitters_cdf[emitter_index-1] : 0.0f);
    EmitterPhotonSamplingResult sampling_result = emitter->samplePhoton(rng);
    // Adjust sampling result for emitter selection probability
    sampling_result.radiance_weight /= emitter_selection_pdf;
    sampling_result.sampling_pdf *= emitter_selection_pdf;
    return sampling_result;
}


extern "C" __global__ void __raygen__camera()
{
    const glm::uvec3 launch_idx  = optixGetLaunchIndexGLM();
    const glm::uvec3 launch_dims = optixGetLaunchDimensionsGLM();

    // Index of current pixel
    const glm::uvec2 pixel_index = glm::uvec2(launch_idx.x, launch_idx.y);
    const uint32_t linear_pixel_index = pixel_index.y * params.image_width + pixel_index.x;

    // Initialize the random number generator.
    // Want to have different seed in different raygen methods.
    uint64_t seed = sampleTEA64(linear_pixel_index + 0*params.image_height*params.image_width, params.subframe_index);
    PCG32 rng = PCG32(seed);

    //
    // Spawn camera ray
    //

    RayContext ray_ctx;
    {
        ray_ctx.valid = true;

        // Spawn the initial camera ray
        {
            // Choose uv coordinate uniformly at random within the pixel.
            glm::vec2 uv = (glm::vec2(pixel_index) + rng.next2d()) / glm::vec2(params.image_width, params.image_height);
            uv = 2.0f*uv - 1.0f; // [0, 1] -> [-1, 1]

            spawn_camera_ray(params.camera, uv, ray_ctx.ray.origin, ray_ctx.ray.direction);
        }

        // Initialize remainder of the context
        ray_ctx.throughput = glm::vec3(1);
        ray_ctx.depth = 0;
        //ray_ctx.output_radiance = glm::vec3(0);
    }

    //
    // Add the camera vertex
    //

    PathVertex camera_vertex;
    camera_vertex.si.position = ray_ctx.ray.origin;
    // Treat camera ray as dirac-delta sampled (not actually the case, we are integrating over a single pixel...)
    // We don't directly connect to camera, so the throughput is unused.
    //camera_vertex.throughput_weight = ray_ctx.throughput; // NOTE: ray_ctx.throughput is at next vertex already!!! (does not matter for camera vertex...)
    // TODO more attributes?!
    

    params.per_pixel_data(pixel_index).value().camera_subpath.clear();
    params.per_pixel_data(pixel_index).value().camera_subpath.push_back(camera_vertex);

    //
    // Trace the camera subpath
    //

    trace_subpath(ray_ctx, &params.per_pixel_data(pixel_index).value().camera_subpath, rng);
}

extern "C" __global__ void __raygen__light()
{
    const glm::uvec3 launch_idx  = optixGetLaunchIndexGLM();
    const glm::uvec3 launch_dims = optixGetLaunchDimensionsGLM();

    // Index of current pixel
    const glm::uvec2 pixel_index = glm::uvec2(launch_idx.x, launch_idx.y);
    const uint32_t linear_pixel_index = pixel_index.y * params.image_width + pixel_index.x;

    // Initialize the random number generator.
    // Want to have different seed in different raygen methods.
    uint64_t seed = sampleTEA64(linear_pixel_index + 1*params.image_height*params.image_width, params.subframe_index);
    PCG32 rng = PCG32(seed);

    //
    // Spawn light ray
    //

    RayContext ray_ctx;
    ray_ctx.valid = true;

    // Spawn initial ray from light source
    EmitterPhotonSamplingResult emitter_sampling_result = samplePhotonFromAllEmitters(rng);
    ray_ctx.ray.origin = emitter_sampling_result.position;
    ray_ctx.ray.direction = emitter_sampling_result.direction;
    ray_ctx.throughput = emitter_sampling_result.radiance_weight;
    ray_ctx.depth = 0;


    //
    // Add the light vertex
    //

    PathVertex light_vertex;
    light_vertex.si.position = emitter_sampling_result.position;
    light_vertex.si.normal = emitter_sampling_result.normal_at_light;
    // Compute radiance weight before direction sampling. (without cos(theta) on light)
    // NOTE: emitter_sampling_result.radiance_weight, ray_ctx.throughput importance samples Le*cos(theta_o)
    // I.e. the function already samples the position x_0 **and** the direction w_0 with p(w_0 | x_0) = cos(theta_o)/pi.
    // After a change of variables to surface area measure, this is equivalent to sampling positions x_0 and x_1 with p(x1 | x0) = cos(theta_i at x_1) * cos(theta_o at x_0) / (pi * ||x_1 - x_0||^2).
    // We have f(x_0, p_0)/p(x_0, w_0) = Le * cos(theta_o) / (cos(theta_o) / pi) = Le * pi.
    // To get f(x_0) / p(x_0) = Le we simply need to divide emitter_sampling_result.radiance_weight by pi.
    light_vertex.throughput_weight = emitter_sampling_result.radiance_weight / glm::pi<float>();
    // TODO more attributes?!

    params.per_pixel_data(pixel_index).value().light_subpath.clear();
    params.per_pixel_data(pixel_index).value().light_subpath.push_back(light_vertex);

    //
    // Trace the light subpath
    //

    trace_subpath(ray_ctx, &params.per_pixel_data(pixel_index).value().light_subpath, rng);
}

__forceinline__ __device__ float sum_bdpt_weights(
        float current_weight,
        bool active_is_light_subpath,
        uint32_t active_subpath_vertex_count,
        const PathVertex *active_subpath_vertices,
        uint32_t other_subpath_vertex_count,
        const PathVertex *other_subpath_vertices
    )
{
    float weight_sum = 0;

    // Start at the last vertex
    uint32_t max_vertex_index = active_subpath_vertex_count-1;
    // For light subpaths, we want to consider vertices >= 1 (excliding the light vertex)
    // For camera subpaths we want to consinder verticess >= 2 (excluding the camera vertex and directly visible vertex).
    uint32_t min_vertex_index = active_is_light_subpath ? 1 : 2;

    // NOTE: we need to restrict the begin and end vertex, because we only want to take paths into account where camera_subpath_vertex_count and light_subpath_vertex_count are BOTH <= MAX_SUB_PATH_VERTEX_COUNT!
    // max_other_vertex_count = other_subpath_vertex_count + (max_vertex_index - min_vertex_index + 1) <= MAX_SUB_PATH_VERTEX_COUNT
    // => other_subpath_vertex_count + max_vertex_index + 1 - MAX_SUB_PATH_VERTEX_COUNT <= min_vertex_index
    if (other_subpath_vertex_count + max_vertex_index + 1 > MAX_SUB_PATH_VERTEX_COUNT)
        min_vertex_index = glm::max(min_vertex_index, other_subpath_vertex_count + max_vertex_index + 1 - MAX_SUB_PATH_VERTEX_COUNT);

    // Move connection segment from real connecting end of subpath towards camera/light.
    for (uint32_t i = max_vertex_index; i >= min_vertex_index; --i)
    {
        // Input: vertex i connects to vertex i+1.
        // vertex i **was** sampled from vertex i-1 (and i-2).
        // Output: vertex i-1 connects to vertex i.
        // vertex i **will be** sampled from vertex i+1 (and i+2).
        // Divide by old PDF and multiply with new PDF!

        bool prev_si_is_light = active_is_light_subpath && (i-1 == 0);
        bool next_si_is_light = !active_is_light_subpath && (i == active_subpath_vertex_count-1 && other_subpath_vertex_count == 1);

        /* Implement:
         * - Comptue the (relative) pdf_weight after "swapping" the connection edge from vertex i to i+1 to vertex i-1 to i. (See comment above).
         * - Evaluate the sampling pdf to sample the current vertex i from the previous and next vertex wrt. surface area measure.
         * - Divide `current_weight` by the old pdf and multiply with the new pdf.
         * - Accumualte the weights in `weight_sum`.
         * Hint: if the previous or ntext vertex is a light source you must not evaluate the BSDF, but assume a diffuse light emission.
         * Hint: rho(prev.w_i, prev.w_o) * cos(prev.theta_i) domega = rho(prev.w_i, prev.w_o) * cos(prev.theta_i) * cos(curr.theta_o) / ||prev-curr||^2 dA
         */
        // old_path 
        const PathVertex &vertex_i = active_subpath_vertices[i];
        const PathVertex &vertex_prev = active_subpath_vertices[i-1];
        glm::vec3 dir_prev_to_i = glm::normalize(vertex_i.si.position - vertex_prev.si.position);
        float distance_squared = glm::dot(dir_prev_to_i, dir_prev_to_i);
        glm::vec3 dir_prev_to_i_normalized = dir_prev_to_i / glm::sqrt(distance_squared);

        float old_pdf = 0;
        if(prev_si_is_light)
        {
            float cos_theta_i = glm::dot(dir_prev_to_i_normalized, vertex_prev.si.normal);
            if (cos_theta_i <=0)
            {
                old_pdf = 0;
            }
            else
            {
                old_pdf = cos_theta_i / glm::pi<float>(); 
            }
        }
        else
        {
            const BSDFEvalResult prev = vertex_prev.si.bsdf->evalBSDF(vertex_prev.si, dir_prev_to_i_normalized, +BSDFComponentFlag::Any);
            old_pdf = prev.sampling_pdf;;
        }

        float old_pdf_area = solidAngleToAreaPdf(old_pdf, dir_prev_to_i_normalized, vertex_prev.si.normal, distance_squared);

        bool next_vertex_current = i < active_subpath_vertex_count - 1;
        const PathVertex &vertex_next = next_vertex_current ? active_subpath_vertices[i+1] : other_subpath_vertices[0];

        glm::vec3 dir_i_to_next = glm::normalize(vertex_next.si.position - vertex_i.si.position);
        float distance_squared_next = glm::dot(dir_i_to_next, dir_i_to_next);
        glm::vec3 dir_i_to_next_normalized = dir_i_to_next / glm::sqrt(distance_squared_next);

        float new_pdf = 0;
        if(next_si_is_light)
        {
            float cos_theta_next = glm::dot(dir_i_to_next_normalized, vertex_next.si.normal);
            if (cos_theta_next <=0)
            {
                new_pdf = 0;
            }
            else
            {
                new_pdf = cos_theta_next / glm::pi<float>(); 
            }
        }
        else
        {
            SurfaceInteraction next_si;
            glm::vec3 incoming_dir_at_next;
            if(next_vertex_current){
                next_si = active_subpath_vertices[i+1].si;
                if (i+1 < active_subpath_vertex_count - 1)
                    incoming_dir_at_next = glm::normalize(active_subpath_vertices[i+1].si.position - active_subpath_vertices[i+2].si.position);
                else
                    incoming_dir_at_next = glm::normalize(active_subpath_vertices[i+1].si.position - other_subpath_vertices[0].si.position);
            }
            else{
                next_si = other_subpath_vertices[0].si;

                incoming_dir_at_next = glm::normalize(other_subpath_vertices[0].si.position - other_subpath_vertices[1].si.position);
            }
            next_si.incoming_ray_dir = incoming_dir_at_next;
            BSDFEvalResult eval = next_si.bsdf->evalBSDF(next_si, dir_i_to_next, +BSDFComponentFlag::Any);
            new_pdf = eval.sampling_pdf;
        }
        float new_pdf_area = solidAngleToAreaPdf(new_pdf, dir_i_to_next_normalized, vertex_next.si.normal, distance_squared_next);

        current_weight *= new_pdf_area / old_pdf_area;
        weight_sum += current_weight;
    }
    return weight_sum;
}

extern "C" __global__ void __raygen__combine()
{
    const glm::uvec3 launch_idx  = optixGetLaunchIndexGLM();
    const glm::uvec3 launch_dims = optixGetLaunchDimensionsGLM();

    // Index of current pixel
    const glm::uvec2 pixel_index = glm::uvec2(launch_idx.x, launch_idx.y);
    const uint32_t linear_pixel_index = pixel_index.y * params.image_width + pixel_index.x;

    // Want to have different seed in different raygen methods.
    uint64_t seed = sampleTEA64(linear_pixel_index + 2*params.image_height*params.image_width, params.subframe_index);
    PCG32 rng(seed);

    // Get a *reference* to the per_pixel_data memory of the current pixel.
    PerPixelData &per_pixel_data = params.per_pixel_data(pixel_index).value();

    //
    // Iterate over all combinations of light and camera path vertices O(N^2)
    //

    glm::vec3 output_radiance = glm::vec3(0);

    // Do not connect directly to camera (this would require to scatter radiance into an arbitrary pixel, which we could do but don't want to...)
    for (uint32_t s = 1; s < per_pixel_data.camera_subpath.size(); ++s)
    {
        for (uint32_t t = 0; t < per_pixel_data.light_subpath.size(); ++t)
        {
            // connect subpaths!
            const auto &vertex_to_camera = per_pixel_data.camera_subpath[s];
            const auto &vertex_to_light = per_pixel_data.light_subpath[t];

            // Connection "ray" from camera subpath to light subpath
            glm::vec3 connection_origin = vertex_to_camera.si.position;
            glm::vec3 connection_direction_unnomralized = vertex_to_light.si.position - vertex_to_camera.si.position;
            glm::vec3 connection_direction = glm::normalize(connection_direction_unnomralized);
            float connection_distance_squared = glm::dot(connection_direction_unnomralized, connection_direction_unnomralized);
            float connection_distance = glm::sqrt(connection_distance_squared);

            /* Implement:
             * - Connect the last vertex of the camera subpath (of length s+1) with the last vertex of the light subpath (of length t+1).
             * - Check if the paths can be connected by checking for correct surface orientations and occlusions.
             * - Compute the full path throughput divided by the full path sampling PDF (resulting from the two subpaths).
             * - Compute the multiple importance sampling weights for the current (s,t) sampling strategy.
             * - Accumulate the contribution in output_radiance.
             * Hint: If the light vertex is a light source, there is no BSDF, and we assume that the light is emitted diffusely.
             * Hint: When evaluating our BSDFs, this already includes the NdotL and NdotV terms of the geometry term.
             * Hint: For the MIS weights, you can assume that the current sampling strategy (s,t) has a pdf weight of 1,
             *       and compute the weights for (s+i, t-i) strategies that can produce the same path relative to the current strategy.
             * Hint: You can use the **incomplete** `sum_bdpt_weights()` function to compute the weights of the other relevant sampling strategies.
             */

            // TODO implement

            //
            bool camera_side_valid =
                glm::dot(connection_direction, vertex_to_camera.si.geom_normal) *
                glm::dot(connection_direction, vertex_to_camera.si.normal) > 0.0f;
            
            bool light_side_valid;
            float light_cos = 0.0f;
            if (t == 0)
            {
                light_cos = glm::dot(vertex_to_light.si.normal, -connection_direction);
                light_side_valid = light_cos > 0.0f;
            }
            else
            {
                light_side_valid =
                    glm::dot(-connection_direction, vertex_to_light.si.geom_normal) *
                    glm::dot(-connection_direction, vertex_to_light.si.normal) > 0.0f;
            }

            if(light_side_valid && camera_side_valid)
            {
               bool occluded = traceOcclusion(
                    params.traversable_handle,
                    connection_origin,
                    connection_direction,
                    params.scene_epsilon,
                    connection_distance - params.scene_epsilon,
                    params.occlusion_trace_params
                );


                if (!occluded)
                {
                    BSDFEvalResult eval_camera = vertex_to_camera.si.bsdf->evalBSDF(vertex_to_camera.si, connection_direction, +BSDFComponentFlag::Any);

                    glm::vec3 f_light;
                    if (t == 0)
                    {

                        f_light = glm::vec3(light_cos);
                    }
                    else
                    {
                        BSDFEvalResult eval_light = vertex_to_light.si.bsdf->evalBSDF(vertex_to_light.si, -connection_direction, +BSDFComponentFlag::Any);
                        f_light = eval_light.bsdf_value;
                    }

                    float G = 1.0f / connection_distance_squared;

                    glm::vec3 path_throughput =
                        vertex_to_camera.throughput_weight *
                        eval_camera.bsdf_value *
                        G *
                        f_light *
                        vertex_to_light.throughput_weight;

                    if (path_throughput.x > 0.0f || path_throughput.y > 0.0f || path_throughput.z > 0.0f)
                    {

                        PathVertex reversed_light_subpath[MAX_SUB_PATH_VERTEX_COUNT];
                        for (uint32_t k = 0; k <= t; ++k)
                            reversed_light_subpath[k] = per_pixel_data.light_subpath[t - k];

                        PathVertex reversed_camera_subpath[MAX_SUB_PATH_VERTEX_COUNT];
                        for (uint32_t k = 0; k <= s; ++k)
                            reversed_camera_subpath[k] = per_pixel_data.camera_subpath[s - k];

                        float sum_cam_strategies = sum_bdpt_weights(
                            1.0f,
                            /*active_is_light_subpath=*/ false,
                            /*active_subpath_vertex_count=*/ s+1,
                            /*active_subpath_vertices=*/ &per_pixel_data.camera_subpath[0],
                            /*other_subpath_vertex_count=*/ t+1,
                            /*other_subpath_vertices=*/ reversed_light_subpath
                        );
                        float sum_light_strategies = sum_bdpt_weights(
                            1.0f,
                            /*active_is_light_subpath=*/ true,
                            /*active_subpath_vertex_count=*/ t+1,
                            /*active_subpath_vertices=*/ &per_pixel_data.light_subpath[0],
                            /*other_subpath_vertex_count=*/ s+1,
                            /*other_subpath_vertices=*/ reversed_camera_subpath
                        );

                        float mis_weight = 1.0f / (1.0f + sum_cam_strategies + sum_light_strategies);

                        output_radiance += mis_weight * path_throughput;
                }

            }

        }
    
        }
    }

    //
    // Update results
    //

    // Write linear output color
    params.output_radiance(pixel_index).value() = output_radiance;
}
