/*
 * Copyright (C) 2023, Inria
 * GRAPHDECO research group, https://team.inria.fr/graphdeco
 * All rights reserved.
 *
 * This software is free for non-commercial, research and evaluation use 
 * under the terms of the LICENSE.md file.
 *
 * For inquiries contact  george.drettakis@inria.fr
 */

#include "rasterizer_impl.h"
#include <iostream>
#include <fstream>
#include <algorithm>
#include <numeric>
#include <cuda.h>
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <cub/cub.cuh>
#include <cub/device/device_radix_sort.cuh>
#define GLM_FORCE_CUDA
#include <glm/glm.hpp>

#include <cooperative_groups.h>
#include <cooperative_groups/reduce.h>
namespace cg = cooperative_groups;

#include "auxiliary.h"
#include "forward.h"
#include "backward.h"

// Helper function to find the next-highest bit of the MSB
// on the CPU.
uint32_t getHigherMsb(uint32_t n)
{
	uint32_t msb = sizeof(n) * 4;
	uint32_t step = msb;
	while (step > 1)
	{
		step /= 2;
		if (n >> msb)
			msb += step;
		else
			msb -= step;
	}
	if (n >> msb)
		msb++;
	return msb;
}

// Wrapper method to call auxiliary coarse frustum containment test.
// Mark all Gaussians that pass it.
__global__ void checkFrustum(int P,
	const float* orig_points,
	const float* viewmatrix,
	const float* projmatrix,
	bool* present)
{
	auto idx = cg::this_grid().thread_rank();
	if (idx >= P)
		return;

	float3 p_view;
	present[idx] = in_frustum(idx, orig_points, viewmatrix, projmatrix, false, p_view);
}

// Generates one key/value pair for all Gaussian / tile overlaps. 
// Run once per Gaussian (1:N mapping).
__global__ void duplicateWithKeys(
	int P,
	const float2* points_xy,
	const float* depths,
	const uint32_t* offsets,
	uint64_t* gaussian_keys_unsorted,
	uint32_t* gaussian_values_unsorted,
	int* radii,
	dim3 grid)
{
	auto idx = cg::this_grid().thread_rank();
	if (idx >= P)
		return;

	// Generate no key/value pair for invisible Gaussians
	if (radii[idx] > 0)
	{
		// Find this Gaussian's offset in buffer for writing keys/values.
		uint32_t off = (idx == 0) ? 0 : offsets[idx - 1];
		uint2 rect_min, rect_max;

		getRect(points_xy[idx], radii[idx], rect_min, rect_max, grid);

		// For each tile that the bounding rect overlaps, emit a 
		// key/value pair. The key is |  tile ID  |      depth      |,
		// and the value is the ID of the Gaussian. Sorting the values 
		// with this key yields Gaussian IDs in a list, such that they
		// are first sorted by tile and then by depth. 
		for (int y = rect_min.y; y < rect_max.y; y++)
		{
			for (int x = rect_min.x; x < rect_max.x; x++)
			{
				uint64_t key = y * grid.x + x;
				key <<= 32;
				key |= *((uint32_t*)&depths[idx]);
				gaussian_keys_unsorted[off] = key;
				gaussian_values_unsorted[off] = idx;
				off++;
			}
		}
	}
}

// Check keys to see if it is at the start/end of one tile's range in 
// the full sorted list. If yes, write start/end of this tile. 
// Run once per instanced (duplicated) Gaussian ID.
__global__ void identifyTileRanges(int L, uint64_t* point_list_keys, uint2* ranges, int height , int width )
{
	auto idx = cg::this_grid().thread_rank();
	if (idx >= L)
		return;
	int numTilesX = (width + 16 - 1) / 16;
	uint64_t key = point_list_keys[idx];
	uint32_t currtile = key >> 32;
	uint32_t count = 0;

	if (idx == 0) {
		ranges[currtile].x = 0;
	} else {
		uint32_t prevtile = point_list_keys[idx - 1] >> 32;
		if (currtile != prevtile) {
			ranges[prevtile].y = idx;
			ranges[currtile].x = idx;
			count = idx - ranges[prevtile].x;
			int row = prevtile / numTilesX;
			int col = prevtile % numTilesX;	

			//printf("Tile %u has %d Gaussians\n, The position is %u, %u \n", prevtile, count, row * 16 ,  col * 16);

			
		}
	}
	if (idx == L - 1) {
		ranges[currtile].y = L;
		// Print the count for the last tile
		//printf("Tile %u has %d Gaussians\n", currtile, L - ranges[currtile].x);
	}
}


// Mark Gaussians as visible/invisible, based on view frustum testing
void CudaRasterizer::Rasterizer::markVisible(
	int P,
	float* means3D,
	float* viewmatrix,
	float* projmatrix,
	bool* present)
{
	checkFrustum << <(P + 255) / 256, 256 >> > (
		P,
		means3D,
		viewmatrix, projmatrix,
		present);
}

CudaRasterizer::GeometryState CudaRasterizer::GeometryState::fromChunk(char*& chunk, size_t P)
{
	GeometryState geom;
	obtain(chunk, geom.depths, P, 128);
	obtain(chunk, geom.clamped, P * 3, 128);
	obtain(chunk, geom.internal_radii, P, 128);
	obtain(chunk, geom.means2D, P, 128);
	obtain(chunk, geom.cov3D, P * 6, 128);
	obtain(chunk, geom.conic_opacity, P, 128);
	obtain(chunk, geom.rgb, P * 3, 128);
	obtain(chunk, geom.tiles_touched, P, 128);
	cub::DeviceScan::InclusiveSum(nullptr, geom.scan_size, geom.tiles_touched, geom.tiles_touched, P);
	obtain(chunk, geom.scanning_space, geom.scan_size, 128);
	obtain(chunk, geom.point_offsets, P, 128);
	return geom;
}

CudaRasterizer::ImageState CudaRasterizer::ImageState::fromChunk(char*& chunk, size_t N)
{
	ImageState img;
	obtain(chunk, img.accum_alpha, N, 128);
	obtain(chunk, img.n_contrib, N, 128);
	obtain(chunk, img.ranges, N, 128);
	return img;
}

CudaRasterizer::BinningState CudaRasterizer::BinningState::fromChunk(char*& chunk, size_t P)
{
	BinningState binning;
	obtain(chunk, binning.point_list, P, 128);
	obtain(chunk, binning.point_list_unsorted, P, 128);
	obtain(chunk, binning.point_list_keys, P, 128);
	obtain(chunk, binning.point_list_keys_unsorted, P, 128);
	cub::DeviceRadixSort::SortPairs(
		nullptr, binning.sorting_size,
		binning.point_list_keys_unsorted, binning.point_list_keys,
		binning.point_list_unsorted, binning.point_list, P);
	obtain(chunk, binning.list_sorting_space, binning.sorting_size, 128);
	return binning;
}




// Forward rendering procedure for differentiable rasterization
// of Gaussians.
int CudaRasterizer::Rasterizer::forward(
	std::function<char* (size_t)> geometryBuffer,
	std::function<char* (size_t)> binningBuffer,
	std::function<char* (size_t)> imageBuffer,
	const int P, int D, int M,
	const float* background,
	const int width, int height,
	const float* means3D,
	const float* shs,
	const float* colors_precomp,
	const float* opacities,
	const float* scales,
	const float scale_modifier,
	const float* rotations,
	const float* cov3D_precomp,
	const float* viewmatrix,
	const float* projmatrix,
	const float* cam_pos,
	const float tan_fovx, float tan_fovy,
	const bool prefiltered,
	float* out_color,
	int* radii,
	bool debug)
{
	const float focal_y = height / (2.0f * tan_fovy);
	const float focal_x = width / (2.0f * tan_fovx);

	size_t chunk_size = required<GeometryState>(P);
	char* chunkptr = geometryBuffer(chunk_size);
	GeometryState geomState = GeometryState::fromChunk(chunkptr, P);

	if (radii == nullptr)
	{
		radii = geomState.internal_radii;
	}

	dim3 tile_grid((width + BLOCK_X - 1) / BLOCK_X, (height + BLOCK_Y - 1) / BLOCK_Y, 1);
	dim3 block(BLOCK_X, BLOCK_Y, 1);

	// Dynamically resize image-based auxiliary buffers during training
	size_t img_chunk_size = required<ImageState>(width * height);
	char* img_chunkptr = imageBuffer(img_chunk_size);
	ImageState imgState = ImageState::fromChunk(img_chunkptr, width * height);

	if (NUM_CHANNELS != 3 && colors_precomp == nullptr)
	{
		throw std::runtime_error("For non-RGB, provide precomputed Gaussian colors!");
	}
	
	// Run preprocessing per-Gaussian (transformation, bounding, conversion of SHs to RGB)
	CHECK_CUDA(FORWARD::preprocess(
		P, D, M,
		means3D,
		(glm::vec3*)scales,
		scale_modifier,
		(glm::vec4*)rotations,
		opacities,
		shs,
		geomState.clamped,
		cov3D_precomp,
		colors_precomp,
		viewmatrix, projmatrix,
		(glm::vec3*)cam_pos,
		width, height,
		focal_x, focal_y,
		tan_fovx, tan_fovy,
		radii,
		geomState.means2D,
		geomState.depths,
		geomState.cov3D,
		geomState.rgb,
		geomState.conic_opacity,
		tile_grid,
		geomState.tiles_touched,
		prefiltered
	), debug)

	// Compute prefix sum over full list of touched tile counts by Gaussians
	// E.g., [2, 3, 0, 2, 1] -> [2, 5, 5, 7, 8]
	CHECK_CUDA(cub::DeviceScan::InclusiveSum(geomState.scanning_space, geomState.scan_size, geomState.tiles_touched, geomState.point_offsets, P), debug)

	// Retrieve total number of Gaussian instances to launch and resize aux buffers
	int num_rendered;
	CHECK_CUDA(cudaMemcpy(&num_rendered, geomState.point_offsets + P - 1, sizeof(int), cudaMemcpyDeviceToHost), debug);

	size_t binning_chunk_size = required<BinningState>(num_rendered);
	char* binning_chunkptr = binningBuffer(binning_chunk_size);
	BinningState binningState = BinningState::fromChunk(binning_chunkptr, num_rendered);

	// For each instance to be rendered, produce adequate [ tile | depth ] key 
	// and corresponding dublicated Gaussian indices to be sorted
	duplicateWithKeys << <(P + 255) / 256, 256 >> > (
		P,
		geomState.means2D,
		geomState.depths,
		geomState.point_offsets,
		binningState.point_list_keys_unsorted,
		binningState.point_list_unsorted,
		radii,
		tile_grid)
	CHECK_CUDA(, debug)

	int bit = getHigherMsb(tile_grid.x * tile_grid.y);

	// Sort complete list of (duplicated) Gaussian indices by keys
	CHECK_CUDA(cub::DeviceRadixSort::SortPairs(
		binningState.list_sorting_space,
		binningState.sorting_size,
		binningState.point_list_keys_unsorted, binningState.point_list_keys,
		binningState.point_list_unsorted, binningState.point_list,
		num_rendered, 0, 32 + bit), debug)

	CHECK_CUDA(cudaMemset(imgState.ranges, 0, tile_grid.x * tile_grid.y * sizeof(uint2)), debug);

	// Identify start and end of per-tile workloads in sorted list
	if (num_rendered > 0)
		identifyTileRanges << <(num_rendered + 255) / 256, 256 >> > (
			num_rendered,
			binningState.point_list_keys,
			imgState.ranges,height,width);
	CHECK_CUDA(, debug)

  
  

	// Let each tile blend its range of Gaussians independently in parallel
	const float* feature_ptr = colors_precomp != nullptr ? colors_precomp : geomState.rgb;

  // // Allocate memory for output on device
  // int* d_output;
  // size_t output_size = num_rendered * 2 * sizeof(int); // Each entry has 2 ints (tile ID and Gaussian ID)
  // cudaMalloc(&d_output, output_size);

  // // Define kernel execution configuration
  // dim3 blockSize(256); // You can adjust this based on your GPU's capabilities
  // dim3 gridSize((num_rendered + blockSize.x - 1) / blockSize.x);

  // // Launch the kernel
  // extractTileGaussianIDs<<<gridSize, blockSize>>>(binningState.point_list_keys, binningState.point_list, num_rendered, d_output);

  // // Copy the results back to the host
  // int* h_output = new int[num_rendered * 2];
  // cudaMemcpy(h_output, d_output, output_size, cudaMemcpyDeviceToHost);

  // // Open a file for writing
  // std::ofstream outputFile("/content/output.txt");

  // // Write the results to the file
  // for (int i = 0; i < num_rendered; ++i) {
  //     int tile_id = h_output[i * 2];
  //     int gaussian_id = h_output[i * 2 + 1];
  //     outputFile << "Tile ID: " << tile_id << ", Gaussian ID: " << gaussian_id << std::endl;
  // }

  // // Close the file
  // outputFile.close();

  // // Free memory
  // cudaFree(d_output);
  // delete[] h_output;
  

	
	
	// int numGaussians = P;

	// // Allocate CPU memory for all parameters
	// glm::vec2* means2D_cpu = new glm::vec2[numGaussians];
	// float* cov3D_cpu = new float[numGaussians * 6]; // 6 values for each symmetric 3x3 covariance matrix
	// float* depths_cpu = new float[numGaussians];
	// bool* clamped_cpu = new bool[numGaussians];
	// int* internal_radii_cpu = new int[numGaussians];
	// glm::vec4* conic_opacity_cpu = new glm::vec4[numGaussians];
	// float* rgb_cpu = new float[numGaussians * 3]; // 3 values for RGB
	// uint32_t* point_offsets_cpu = new uint32_t[numGaussians];
	// uint32_t* tiles_touched_cpu = new uint32_t[numGaussians];

	// // Transfer the data from GPU to CPU
	// cudaMemcpy(point_offsets_cpu, geomState.point_offsets, numGaussians * sizeof(uint32_t), cudaMemcpyDeviceToHost);
	// cudaMemcpy(tiles_touched_cpu, geomState.tiles_touched, numGaussians * sizeof(uint32_t), cudaMemcpyDeviceToHost);

	// // Transfer the data from GPU to CPU
	// cudaMemcpy(means2D_cpu, geomState.means2D, numGaussians * sizeof(glm::vec2), cudaMemcpyDeviceToHost);
	// cudaMemcpy(cov3D_cpu, geomState.cov3D, numGaussians * 6 * sizeof(float), cudaMemcpyDeviceToHost);
	// cudaMemcpy(depths_cpu, geomState.depths, numGaussians * sizeof(float), cudaMemcpyDeviceToHost);
	// cudaMemcpy(clamped_cpu, geomState.clamped, numGaussians * sizeof(bool), cudaMemcpyDeviceToHost);
	// cudaMemcpy(internal_radii_cpu, geomState.internal_radii, numGaussians * sizeof(int), cudaMemcpyDeviceToHost);
	// cudaMemcpy(conic_opacity_cpu, geomState.conic_opacity, numGaussians * sizeof(glm::vec4), cudaMemcpyDeviceToHost);
	// cudaMemcpy(rgb_cpu, geomState.rgb, numGaussians * 3 * sizeof(float), cudaMemcpyDeviceToHost);

	// // Open a file for writing
	// std::ofstream file("/content/geometry_data.txt");
	// if (!file.is_open()) {
	// 	std::cerr << "Error opening file for writing." << std::endl;
	// 	// Handle error (possibly exit or return)
	// }

	// // Writing all geometry state parameters to the file
	// for (int i = 0; i < numGaussians; ++i) {

	// 	file << "Gaussian " << i << std::endl;
	// 	file << "2D Mean: (" << means2D_cpu[i].x << ", " << means2D_cpu[i].y << ")\n";
	// 	file << "Covariance: [";
	// 	for (int j = 0; j < 6; ++j) {
  //   		file << cov3D_cpu[i * 6 + j] << (j < 5 ? ", " : "");
	// 	}
	// 	file << "]" << std::endl;


	// 	file << "Depth: " << depths_cpu[i] << std::endl;
	// 	file << "Clamped: " << (clamped_cpu[i] ? "true" : "false") << std::endl;
	// 	file << "Internal Radii: " << internal_radii_cpu[i] << std::endl;
	// 	 file << "Conic Opacity: (" << conic_opacity_cpu[i].x << ", "
  //        << conic_opacity_cpu[i].y << ", "
  //        << conic_opacity_cpu[i].z << ", "
  //        << conic_opacity_cpu[i].w << ")" << std::endl;
	// 	file << "RGB: (" << rgb_cpu[i * 3] << ", "
	// 		<< rgb_cpu[i * 3 + 1] << ", "
	// 		<< rgb_cpu[i * 3 + 2] << ")" << std::endl;
	// 	// Write point offsets
  //   	file << "Point Offset: " << point_offsets_cpu[i] << std::endl;

  //   	// Write tiles touched
  //   	file << "Tiles Touched: " << tiles_touched_cpu[i] << std::endl;


	// 	file << "---------------------" << std::endl;
	// }

	// // Close the file
	// file.close();

	// // Free the allocated CPU memory
	// delete[] means2D_cpu;
	// delete[] cov3D_cpu;
	// delete[] depths_cpu;
	// delete[] clamped_cpu;
	// delete[] internal_radii_cpu;
	// delete[] conic_opacity_cpu;
	// delete[] rgb_cpu;
	// delete[] point_offsets_cpu;
	// delete[] tiles_touched_cpu;


	CHECK_CUDA(FORWARD::render(
		tile_grid, block,
		imgState.ranges,
		binningState.point_list,
		width, height,
		geomState.means2D,
		feature_ptr,
		geomState.conic_opacity,
		imgState.accum_alpha,
		imgState.n_contrib,
		background,
		out_color), debug)

	// // Determine the number of Gaussians (assuming you have this information)
	// int numGaussians = P; // P is the number of Gaussians

	// // Allocate CPU memory to store the Gaussians' 2D means and covariances
	// glm::vec2* means2D_cpu = new glm::vec2[numGaussians];
	// float* cov3D_cpu = new float[numGaussians * 6]; // 6 values for each symmetric 3x3 covariance matrix

	// // Transfer the data from GPU to CPU
	// cudaMemcpy(means2D_cpu, geomState.means2D, numGaussians * sizeof(glm::vec2), cudaMemcpyDeviceToHost);
	// cudaMemcpy(cov3D_cpu, geomState.cov3D, numGaussians * 6 * sizeof(float), cudaMemcpyDeviceToHost);

	// // Write the data to the file
	// for (int i = 0; i < numGaussians; ++i) {
	// 	file << "Gaussian " << i << " - 2D Mean: (" << means2D_cpu[i].x << ", " << means2D_cpu[i].y << ")\n";
	// 	file << "Covariance: [";
	// 	for (int j = 0; j < 6; ++j) {
	// 		file << cov3D_cpu[i * 6 + j] << (j < 5 ? ", " : "]");
	// 	}
	// 	file << std::endl;
	// }

	// // Close the file
	// file.close();

	// // Free the allocated CPU memory
	// delete[] means2D_cpu;
	// delete[] cov3D_cpu;

	
	// // Print the data
	// for (int i = 0; i < numGaussians; ++i) {
	// 	std::cout << "Gaussian " << i << " - 2D Mean: (" << means2D_cpu[i].x << ", " << means2D_cpu[i].y << ")\n";
	// 	std::cout << "Covariance: [";
	// 	for (int j = 0; j < 6; ++j) {
	// 		std::cout << cov3D_cpu[i * 6 + j] << (j < 5 ? ", " : "]");
	// 	}
	// 	std::cout << std::endl;
	// }
	// 

	// // Open a file for writing
	// std::ofstream file("/content/gaussians_data.txt");

	// // Check if the file is open
	// if (!file.is_open()) {
	// 	std::cerr << "Error opening file for writing." << std::endl;
	
	// }

	

	return num_rendered;
}

// Produce necessary gradients for optimization, corresponding
// to forward render pass
void CudaRasterizer::Rasterizer::backward(
	const int P, int D, int M, int R,
	const float* background,
	const int width, int height,
	const float* means3D,
	const float* shs,
	const float* colors_precomp,
	const float* scales,
	const float scale_modifier,
	const float* rotations,
	const float* cov3D_precomp,
	const float* viewmatrix,
	const float* projmatrix,
	const float* campos,
	const float tan_fovx, float tan_fovy,
	const int* radii,
	char* geom_buffer,
	char* binning_buffer,
	char* img_buffer,
	const float* dL_dpix,
	float* dL_dmean2D,
	float* dL_dconic,
	float* dL_dopacity,
	float* dL_dcolor,
	float* dL_dmean3D,
	float* dL_dcov3D,
	float* dL_dsh,
	float* dL_dscale,
	float* dL_drot,
	bool debug)
{
	GeometryState geomState = GeometryState::fromChunk(geom_buffer, P);
	BinningState binningState = BinningState::fromChunk(binning_buffer, R);
	ImageState imgState = ImageState::fromChunk(img_buffer, width * height);

	if (radii == nullptr)
	{
		radii = geomState.internal_radii;
	}

	const float focal_y = height / (2.0f * tan_fovy);
	const float focal_x = width / (2.0f * tan_fovx);

	const dim3 tile_grid((width + BLOCK_X - 1) / BLOCK_X, (height + BLOCK_Y - 1) / BLOCK_Y, 1);
	const dim3 block(BLOCK_X, BLOCK_Y, 1);

	// Compute loss gradients w.r.t. 2D mean position, conic matrix,
	// opacity and RGB of Gaussians from per-pixel loss gradients.
	// If we were given precomputed colors and not SHs, use them.
	const float* color_ptr = (colors_precomp != nullptr) ? colors_precomp : geomState.rgb;
	CHECK_CUDA(BACKWARD::render(
		tile_grid,
		block,
		imgState.ranges,
		binningState.point_list,
		width, height,
		background,
		geomState.means2D,
		geomState.conic_opacity,
		color_ptr,
		imgState.accum_alpha,
		imgState.n_contrib,
		dL_dpix,
		(float3*)dL_dmean2D,
		(float4*)dL_dconic,
		dL_dopacity,
		dL_dcolor), debug)

	// Take care of the rest of preprocessing. Was the precomputed covariance
	// given to us or a scales/rot pair? If precomputed, pass that. If not,
	// use the one we computed ourselves.
	const float* cov3D_ptr = (cov3D_precomp != nullptr) ? cov3D_precomp : geomState.cov3D;
	CHECK_CUDA(BACKWARD::preprocess(P, D, M,
		(float3*)means3D,
		radii,
		shs,
		geomState.clamped,
		(glm::vec3*)scales,
		(glm::vec4*)rotations,
		scale_modifier,
		cov3D_ptr,
		viewmatrix,
		projmatrix,
		focal_x, focal_y,
		tan_fovx, tan_fovy,
		(glm::vec3*)campos,
		(float3*)dL_dmean2D,
		dL_dconic,
		(glm::vec3*)dL_dmean3D,
		dL_dcolor,
		dL_dcov3D,
		dL_dsh,
		(glm::vec3*)dL_dscale,
		(glm::vec4*)dL_drot), debug)
}