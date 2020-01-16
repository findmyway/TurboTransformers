#include <cuda_runtime.h>
#include <numeric>
#include "fast_transformers/layers/kernels/gpu_common.h"
#include "fast_transformers/layers/kernels/gpu_layer_norm_kernel.h"

namespace fast_transformers {
namespace layers {
namespace kernels {

inline __device__ void get_mean_variance(float val, float* s_mean,
                                         float* s_variance, int n, int tid) {
  float sum1 = val, sum2 = val * val;
  blockReduceSumTwoElemInline(&sum1, &sum2);
  float mean = sum1 / n;
  float mean_2 = sum2 / n;

  if (tid == 0) {
    *s_mean = mean;
    *s_variance = rsqrtf(mean_2 - mean * mean + 1e-6f);
  }
  __syncthreads();
}

template <bool isAdd>
static __global__ void layer_norm_kernel(float* out, const float* input,
                                         const float* bias, const float* gamma,
                                         const float* beta, int m, int n) {
  int tid = threadIdx.x;
  __shared__ float s_mean;
  __shared__ float s_variance;
  float mean = 0.0f;
  float variance = 0.0f;

  float local_out = 0.0f;
  if (isAdd) {
    for (int i = tid; i < n; i += blockDim.x) {
      local_out +=
          out[blockIdx.x * n + i] + input[blockIdx.x * n + i] + __ldg(&bias[i]);
    }
  } else {
    for (int i = tid; i < n; i += blockDim.x) {
      local_out += (out[blockIdx.x * n + i]);
    }
  }

  get_mean_variance(local_out, &s_mean, &s_variance, n, tid);
  for (int i = tid; i < n; i += blockDim.x) {
    out[blockIdx.x * n + i] =
        (local_out - s_mean) * s_variance * __ldg(&gamma[i]) + __ldg(&beta[i]);
  }
}

template <>
void GPUAddBiasLayerNorm(float* out, const float* input, const float* bias,
                         const float* gamma, const float* beta, int m, int n,
                         cudaStream_t stream) {
  dim3 grid(m);
  dim3 block(n);
  if (n > 1024) {
    throw std::runtime_error(
        "GPUAddBiasLayerNorm thread block size large than 1024");
  }
  layer_norm_kernel<true>
      <<<grid, block, 0, stream>>>(out, input, bias, gamma, beta, m, n);
}

template <>
void GPULayerNorm(float* out, const float* gamma, const float* beta, int m,
                  int n, cudaStream_t stream) {
  dim3 grid(m);
  dim3 block(n);
  if (n > 1024) {
    throw std::runtime_error(
        "GPUAddBiasLayerNorm thread block size large than 1024");
  }
  float* dummy = nullptr;
  layer_norm_kernel<false>
      <<<grid, block, 0, stream>>>(out, out, dummy, gamma, beta, m, n);
}

}  // namespace kernels
}  // namespace layers
}  // namespace fast_transformers
