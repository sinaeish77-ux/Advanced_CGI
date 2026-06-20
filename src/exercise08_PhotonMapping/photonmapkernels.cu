#include "photonmapkernels.h"

#include "opg/hostdevice/misc.h"
#include "opg/hostdevice/color.h"
#include "opg/memory/stack.h"
#include "opg/kernels/launch.h"
#include <stdio.h>
#include <algorithm>

#pragma cuda_source_property_format=OBJ

//
// Photon gathering
//
__global__ void resetPhotonGatherDataKernel(opg::BufferView<PhotonGatherData> gather_data, float gather_radius_sq)
{
    const uint32_t gather_index = threadIdx.x + blockIdx.x * blockDim.x;

    if (gather_index >= gather_data.count)
        return;

    // Reset "internal" state
    gather_data[gather_index].gather_radius_sq = gather_radius_sq;
    gather_data[gather_index].photon_count = 0;
    gather_data[gather_index].total_power = glm::vec3(0.0f);
}

void resetPhotonGatherData(opg::BufferView<PhotonGatherData> gather_data, float gather_radius_sq)
{
    const int blockSize  = 512; // 512 is a size that works well with modern GPUs.
    const int blockCount = ceil_div<int>(gather_data.count, blockSize); // Spawn enough blocks such that each pair of elements is added in in its own thread.

    // Launch the kernel on the GPU!
    resetPhotonGatherDataKernel<<<blockCount, blockSize>>>(gather_data, gather_radius_sq);
}

__device__ __forceinline__ void accumulatePhoton( const PhotonData &photon,
                        const glm::vec3 &gather_position,
                        const glm::vec3 &gather_normal,
                        const glm::vec3 &gather_throughput,
                        const float &gather_radius_sq,
                        uint32_t& acc_photon_count, glm::vec3& acc_weight )
{
    glm::vec3 dist = gather_position - photon.position;
    if (glm::dot(dist, dist) < gather_radius_sq)
    {
        float cos_theta = glm::dot(photon.normal, gather_normal);

        if ( cos_theta > 0.8f ) // TODO threshold on curved surfaces!
        {
            glm::vec3 weight = photon.irradiance_weight * gather_throughput;
            acc_photon_count++;
            acc_weight += weight;
        }
    }
}

#define MAX_DEPTH 32 

__global__ void gatherPhotonsKernel(
    opg::BufferView<PhotonData> photon_map,
    opg::BufferView<PhotonGatherData> gather_data,
    opg::BufferView<glm::vec3> output_radiance,
    PhotonMapStoreCount *photon_map_store_count_ptr,
    uint32_t *total_emitted_photon_count_ptr,
    float alpha
    )
{
    const uint32_t gather_index = threadIdx.x + blockIdx.x * blockDim.x;

    if (gather_index >= gather_data.count)
        return;

    glm::vec3 gather_position   = gather_data[gather_index].position;
    glm::vec3 gather_normal     = gather_data[gather_index].normal;
    glm::vec3 gather_throughput = gather_data[gather_index].throughput;

    float  gather_radius_sq     = gather_data[gather_index].gather_radius_sq;
    float  gather_photon_count  = gather_data[gather_index].photon_count;
    glm::vec3 gather_total_power = gather_data[gather_index].total_power;

    // Stack of nodes used to traverse KD-tree
    opg::Stack<uint32_t, MAX_DEPTH> stack;
    uint32_t node = 0u; // Start at the root node

    uint32_t new_photon_count = 0u;
    glm::vec3 new_power = glm::vec3(0.0f);
    while (true)
    {
        if (node >= photon_map.count)
            printf("BAD NODE %u\n", node);
        if (node >= photon_map.count)
        {
            if (stack.empty()) break;
            node = stack.pop();
            continue;
        }

        const PhotonData &photon = photon_map[node];

        if (photon.node_type == KDNodeType::Leaf)
        {
            accumulatePhoton(photon, gather_position, gather_normal, gather_throughput,
                             gather_radius_sq, new_photon_count, new_power);
                }
        else if (photon.node_type == KDNodeType::DoubleLeaf)
                {
                    // Accumulate the first photon sitting at the root position
                    accumulatePhoton(photon, gather_position, gather_normal, gather_throughput,
                                    gather_radius_sq, new_photon_count, new_power);

                    // CPU stored the second photon at root + 1 instead of standard binary indexing
                    uint32_t flat_sibling = node + 1u; 
                    if (flat_sibling < photon_map.count)
                    {
                        const PhotonData &photon2 = photon_map[flat_sibling];
                        if (photon2.node_type == KDNodeType::Leaf)
                        {
                            accumulatePhoton(photon2, gather_position, gather_normal, gather_throughput,
                                            gather_radius_sq, new_photon_count, new_power);
                        }
                    }
                }

        if (photon.node_type == KDNodeType::AxisX ||
            photon.node_type == KDNodeType::AxisY ||
            photon.node_type == KDNodeType::AxisZ)
        {
            accumulatePhoton(photon, gather_position, gather_normal, gather_throughput,
                             gather_radius_sq, new_photon_count, new_power);

            int split_axis = static_cast<int>(photon.node_type) - static_cast<int>(KDNodeType::AxisX);
            float signed_dist = gather_position[split_axis] - photon.position[split_axis];

            uint32_t left_child  = 2u * node + 1u;
            uint32_t right_child = 2u * node + 2u;

            uint32_t near_child = (signed_dist < 0.0f) ? left_child  : right_child;
            uint32_t far_child  = (signed_dist < 0.0f) ? right_child : left_child;

            if ((signed_dist * signed_dist) < gather_radius_sq && far_child < photon_map.count)
            {
                stack.push(far_child);
            }

            node = near_child;
            continue; 
        }

        if (stack.empty())
            break;

        node = stack.pop();
    }

    float discarded_scaling = 1.0f;
    if (photon_map_store_count_ptr->actual_count > 0)
    {
        discarded_scaling = static_cast<float>(photon_map_store_count_ptr->desired_count) / 
                            static_cast<float>(photon_map_store_count_ptr->actual_count);
    }
    new_power *= discarded_scaling;

    //
    // Progressive Photon Mapping Core Loop Update
    //
    if (new_photon_count > 0)
    {
        float N = gather_photon_count;                          
        float M = static_cast<float>(new_photon_count); 

        float N_new = N + alpha * M;
        float ratio = (N + M) > 0.0f ? (N_new / (N + M)) : 1.0f;

        gather_radius_sq *= ratio;
        
        // Accumulate and balance energy metrics
        gather_total_power = (gather_total_power + new_power) * ratio;
        gather_photon_count = N_new;
    }
    else
    {
        gather_total_power += new_power; 
    }

    float total_emitted = static_cast<float>(*total_emitted_photon_count_ptr);
    glm::vec3 gathered_radiance = glm::vec3(0.0f);
    
    if (gather_radius_sq > 0.0f && total_emitted > 0.0f)
    {
        gathered_radiance = gather_total_power / (glm::pi<float>() * gather_radius_sq * total_emitted);
    }
    output_radiance[gather_index] = gathered_radiance;

    // Flush active register changes down onto global frame execution buffers
    gather_data[gather_index].gather_radius_sq = gather_radius_sq;
    gather_data[gather_index].photon_count     = gather_photon_count;
    gather_data[gather_index].total_power      = gather_total_power;
}

void gatherPhotons(
    opg::BufferView<PhotonData> photon_map,
    opg::BufferView<PhotonGatherData> gather_data,
    opg::BufferView<glm::vec3> output_radiance,
    PhotonMapStoreCount *photon_map_store_count_ptr,
    uint32_t *total_emitted_photon_count_ptr,
    float alpha
    )
{
    const int blockSize  = 512; // 512 is a size that works well with modern GPUs.
    const int blockCount = ceil_div<int>(gather_data.count, blockSize); // Spawn enough blocks such that each pair of elements is added in in its own thread.

    // Launch the kernel on the GPU!
    gatherPhotonsKernel<<<blockCount, blockSize>>>(photon_map, gather_data, output_radiance, photon_map_store_count_ptr, total_emitted_photon_count_ptr, alpha);
}


__global__ void combineOutputRadianceKernel(glm::uvec2 thread_count, opg::TensorView<glm::vec3, 2> output_tensor_view, opg::TensorView<glm::vec3, 2> accum_path_tensor_view, opg::TensorView<glm::vec3, 2> accum_photon_tensor_view)
{
    glm::uvec3 thread_index = cuda2glm(threadIdx) + cuda2glm(blockIdx) * cuda2glm(blockDim);
    if (thread_index.x >= thread_count.x || thread_index.y >= thread_count.y || thread_index.z >= 1)
        return;

    glm::uvec2 pixel_index = glm::xy(thread_index);

    glm::vec3 path_radiance = accum_path_tensor_view(pixel_index).value();
    glm::vec3 photon_radiance = accum_photon_tensor_view(pixel_index).value();
    glm::vec3 output_radiance = path_radiance + photon_radiance;

    output_tensor_view(pixel_index).value() = output_radiance;
}

void combineOutputRadiance(opg::TensorView<glm::vec3, 2> output_tensor_view, opg::TensorView<glm::vec3, 2> accum_path_tensor_view, opg::TensorView<glm::vec3, 2> accum_photon_tensor_view)
{
    uint32_t output_width = output_tensor_view.counts[1];
    uint32_t output_height = output_tensor_view.counts[0];
    glm::uvec2 thread_count(output_width, output_height);
    // Launch the kernel on the GPU!
    opg::launch_2d_kernel(combineOutputRadianceKernel, thread_count, output_tensor_view, accum_path_tensor_view, accum_photon_tensor_view);
}

