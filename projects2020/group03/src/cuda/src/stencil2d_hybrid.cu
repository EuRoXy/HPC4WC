#include <cassert>
#include <chrono>
#include <fstream>
#include <iostream>
#include <omp.h>
#include <cuda.h>

#ifdef CRAYPAT
#include "pat_api.h"
#endif
#include "utils.h"
#include "update_halo.h"
//#include "apply_diffusion.h"
#include "apply_stencil.cuh"
#include "apply_stencil_cpu.h"

void apply_diffusion_hybrid(Storage3D<realType>& inField,
                            Storage3D<realType>& outField,
                            Storage3D<realType>& buffer,
                            realType const alpha,
                            unsigned const numIter,
                            double const z_slices_on_cpu) {
  // Utils
  std::size_t const xSize = inField.xSize();
  std::size_t const ySize = inField.ySize();
  std::size_t const xMin = inField.xMin();
  std::size_t const yMin = inField.yMin();
  std::size_t const xMax = inField.xMax();
  std::size_t const yMax = inField.yMax();
  std::size_t const zMin = inField.zMin();
  std::size_t const zMax = inField.zMax();
  std::size_t const zMax_gpu = zMax - z_slices_on_cpu;
  std::size_t const size = sizeof(realType) * xSize * ySize * zMax_gpu;

  // Allocate space on device memory and copy data from host
  realType *infield, *outfield;
  //cuInit(0);
  cudaMalloc((void **)&infield, size);
  cudaMalloc((void **)&outfield, size);
  cudaMemcpy(infield, &inField(0, 0, 0), size, cudaMemcpyHostToDevice);

  dim3 blockDim(8, 8, 1);
  dim3 gridDim((xMax + blockDim.x - 1) / blockDim.x,
               (yMax + blockDim.y - 1) / blockDim.y,
               (zMax_gpu + blockDim.z - 1) / blockDim.z);

  //cudaEvent_t tic, toc;
  //cudaEventCreate(&tic);
  //cudaEventCreate(&toc);
  //cudaEventRecord(tic);

  //Storage3D<realType> buffer(x, y, 1, halo);

  for(std::size_t iter = 0; iter < numIter; ++iter) {
    // GPU code (Control returns directly to the CPU)
    apply_stencil<<<gridDim, blockDim>>>(infield, outfield, xMin, xMax, xSize, yMin, yMax, ySize, zMax_gpu, alpha);
    // CPU code (Overlaps with GPU code)
    updateHalo(inField, zMax_gpu);
    apply_stencil_cpu(inField, outField, buffer, alpha, iter, numIter, zMax_gpu);
    // Synchronize
    cudaDeviceSynchronize();
    if ( iter != numIter - 1 ) std::swap(infield, outfield);
  }

  //cudaEventRecord(toc);
  //cudaEventSynchronize(toc);
  //float telapsed = -1;
  //cudaEventElapsedTime(&telapsed, tic, toc);
  //std::cout << "telapsed: " << telapsed << std::endl;
  //cudaEventDestroy(tic);
  //cudaEventDestroy(toc);

  // Copy result from device to host and free device memory
  cudaMemcpy(&outField(0, 0, 0), outfield, size, cudaMemcpyDeviceToHost);
  cudaFree(infield);
  cudaFree(outfield);
}

void reportTime(const Storage3D<realType>& storage, int nIter, double diff) {
  std::cout << "# ranks nx ny ny nz num_iter time\ndata = np.array( [ \\\n";
  int size = 1;
#pragma omp parallel
  {
#pragma omp master
    { size = omp_get_num_threads(); }
  }
  std::cout << "[ " << size << ", " << storage.xMax() - storage.xMin() << ", "
            << storage.yMax() - storage.yMin() << ", " << storage.zMax() << ", " << nIter << ", "
            << diff << "],\n";
  std::cout << "] )" << std::endl;
}

int main(int argc, char const* argv[]) {
#ifdef CRAYPAT
  PAT_record(PAT_STATE_OFF);
#endif
  int x = atoi(argv[2]);
  int y = atoi(argv[4]);
  int z = atoi(argv[6]);
  int iter = atoi(argv[8]);
  int z_slices_on_cpu = atoi(argv[10]);
  int nHalo = 2;
  assert(x > 0 && y > 0 && z > 0 && iter > 0);
  assert(z_slices_on_cpu >= 0 && z_slices_on_cpu <= z);
  std::cout << "Offloaded " << z_slices_on_cpu << " / " << z << " slices on the CPU" << std::endl;
  Storage3D<realType> input(x, y, z, nHalo);
  input.initialize();
  Storage3D<realType> output(x, y, z, nHalo);
  output.initialize();

  realType alpha = 1. / 32.;

  std::ofstream fout;
  fout.open("in_field.dat", std::ios::binary | std::ofstream::trunc);
  input.writeFile(fout);
  fout.close();
#ifdef CRAYPAT
  PAT_record(PAT_STATE_ON);
#endif
  Storage3D<realType> buffer(x, y, 1, nHalo);
  // Synchronize the host and device so that the timings are accurate
  cudaDeviceSynchronize();
  auto start = std::chrono::steady_clock::now();

  apply_diffusion_hybrid(input, output, buffer, alpha, iter, z_slices_on_cpu);

  cudaDeviceSynchronize();
  auto end = std::chrono::steady_clock::now();
#ifdef CRAYPAT
  PAT_record(PAT_STATE_OFF);
#endif
  updateHalo(output);
  fout.open("out_field.dat", std::ios::binary | std::ofstream::trunc);
  output.writeFile(fout);
  fout.close();

  auto diff = end - start;
  double timeDiff = std::chrono::duration<double, std::milli>(diff).count() / 1000.;
  reportTime(output, iter, timeDiff);

  return 0;
}
