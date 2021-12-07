#include <vector>
#include <math.h>
#include <iostream>

#include <cuda.h>
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cuda_profiler_api.h>

#include <ATen/ATen.h>
#include <ATen/cuda/CUDAContext.h>
#include <torch/extension.h>

#include "strided_batched_gemm.h"
#include "softmax.h"
#include "dropout.h"

// symbol to be automatically resolved by PyTorch libs
extern THCState *state;

namespace multihead_attn {
namespace self {
namespace attention_score {

std::vector<torch::Tensor> fwd_cuda(
		               bool                 is_training,
                               int                  heads,
                               torch::Tensor const& inputs,
                               const uint8_t*       attention_mask,
                               float                coeff,
                               float                dropout_prob
                             )
{

  // Embedding of Q, K and V
  const int   embed_dim      = inputs.size(2) / 3;
  const int   sequences      = inputs.size(1);
  const int   q_seq_len      = inputs.size(0);
  const int   k_seq_len      = q_seq_len;
  const int   head_dim       = embed_dim / heads;

  const int   attn_batches   = heads * sequences;
  const int   lead_dim       = attn_batches * 3 * head_dim;
  const int   batch_stride   = 3 * head_dim;

  const int   dropout_elems  = attn_batches * q_seq_len * k_seq_len;
  const float alpha          = 1.0;
  const float beta           = 0.0;
  const float scale          = 1.0 / (sqrt(static_cast<float>(head_dim)) * coeff);

  // There is no reason to use more than one stream as every kernel is
  // sequentially dependent
  cublasHandle_t handle = at::cuda::getCurrentCUDABlasHandle();
  cudaStream_t   stream = at::cuda::getCurrentCUDAStream().stream();
  cublasSetStream(handle, stream);

  auto act_options  = inputs.options().requires_grad(false);
  auto mask_options = act_options.dtype(torch::kUInt8);

  torch::Tensor softmax_results   = torch::empty({attn_batches, q_seq_len, k_seq_len},   act_options);
  torch::Tensor dropout_results   = torch::empty({attn_batches, q_seq_len, k_seq_len},   act_options);
  torch::Tensor dropout_mask      = torch::empty({attn_batches, q_seq_len, k_seq_len},   mask_options);
  torch::Tensor outputs           = torch::empty({q_seq_len, attn_batches, head_dim},    act_options);

  // Input Pointers to Q, K, and V
  void* inputs_q_ptr   = static_cast<void*>(inputs.data_ptr());
  void* inputs_k_ptr   = static_cast<void*>(static_cast<half*>(inputs.data_ptr()) + head_dim);
  void* inputs_v_ptr   = static_cast<void*>(static_cast<half*>(inputs.data_ptr()) + 2 * head_dim);

  // Intermediate Result Ptr
  void* matmul1_results_ptr = static_cast<void*>(softmax_results.data_ptr());

  char a_layout_t{'t'};
  char a_layout_n{'n'};
  char b_layout_n{'n'};

  BAGUA_CUDABLAS_CHECK(cublasSetMathMode(handle, CUBLAS_TENSOR_OP_MATH));

  // Matmul1
  gemm_switch_fp32accum(     state,
                             a_layout_t,
                             b_layout_n,
                             k_seq_len,
                             q_seq_len,
                             head_dim,
                             scale,
                             static_cast<const half*>(inputs_k_ptr),
                             lead_dim,
                             batch_stride,
                             static_cast<const half*>(inputs_q_ptr),
                             lead_dim,
                             batch_stride,
                             beta,
                             static_cast<half*>(matmul1_results_ptr),
                             k_seq_len,
                             k_seq_len * q_seq_len,
                             attn_batches);

  // Softmax & Dropout
  bool softmax_success = false;
  if (attention_mask == nullptr) {
    softmax_success = dispatch_softmax<half, half, float>(
                             reinterpret_cast<half*>(softmax_results.data_ptr()),
                             reinterpret_cast<const half*>(matmul1_results_ptr),
                             k_seq_len,
                             k_seq_len,
                             attn_batches * q_seq_len);

  } else {
    softmax_success = dispatch_masked_softmax<half, half, float>(
                             reinterpret_cast<half*>(softmax_results.data_ptr()),
                             reinterpret_cast<const half*>(matmul1_results_ptr),
                             attention_mask,
                             k_seq_len,
                             k_seq_len,
                             attn_batches * q_seq_len,
                             attn_batches * q_seq_len / sequences);
  }
  assert(softmax_success);

  if (is_training) {
    apex_fused_dropout_cuda<at::Half,float,uint32_t>(
                             static_cast<at::Half const*>(softmax_results.data_ptr()),
                             static_cast<at::Half*>(dropout_results.data_ptr()),
                             static_cast<uint8_t*>(dropout_mask.data_ptr()),
                             dropout_elems,
                             (1.0f - dropout_prob));
  } 
  
  // Matmul2
  gemm_switch_fp32accum(     state,
                             a_layout_n,
                             b_layout_n,
                             head_dim,
                             q_seq_len,
                             k_seq_len,
                             alpha,
                             static_cast<const half*>(inputs_v_ptr),
                             lead_dim,
                             batch_stride,
			     (is_training) ? static_cast<const half*>(dropout_results.data_ptr()) : static_cast<const half*>(softmax_results.data_ptr()) ,
                             k_seq_len,
                             k_seq_len * q_seq_len,
                             beta,
                             static_cast<half*>(outputs.data_ptr()),
                             head_dim * attn_batches,
                             head_dim,
                             attn_batches);

  BAGUA_CUDABLAS_CHECK(cublasSetMathMode(handle, CUBLAS_DEFAULT_MATH));

  return {
      softmax_results,
      dropout_results,
      dropout_mask,
      outputs
  };
}

std::vector<torch::Tensor> bwd_cuda(
                               int                  heads,
                               torch::Tensor const& output_grads,
                               torch::Tensor const& dropout_results,
                               torch::Tensor const& softmax_results,
                               torch::Tensor const& inputs,
                               float                coeff,
                               torch::Tensor const& dropout_mask,
                               float                dropout_prob
                                   )
{
  const int   embed_dim      = inputs.size(2) / 3;
  const int   sequences      = inputs.size(1);
  const int   q_seq_len      = inputs.size(0);
  const int   k_seq_len      = q_seq_len;
  const int   head_dim       = embed_dim / heads;

  const int   attn_batches   = heads * sequences;
  const int   lead_dim       = attn_batches * 3 * head_dim;
  const int   batch_stride   = 3 * head_dim;

  const int   dropout_elems  = attn_batches * q_seq_len * k_seq_len;
  const float alpha          = 1.0;
  const float beta           = 0.0;
  const float scale          = 1.0 / (sqrt(static_cast<float>(head_dim)) * coeff);

  // TODO: Streams can be used in Backprop but I haven't added more than one
  // in my first attempt to create the code
  cublasHandle_t handle = at::cuda::getCurrentCUDABlasHandle();
  cudaStream_t   stream = at::cuda::getCurrentCUDAStream().stream();
  cublasSetStream(handle, stream);

  // Output Tensor Allocations
  torch::Tensor inputs_grads   = torch::empty_like(inputs);

  // Intermediate Tensor Allocations
  at::Tensor dropout_results_grads          = torch::empty_like(dropout_results);

  auto inputs_q_ptr = static_cast<half*>(inputs.data_ptr());
  auto inputs_k_ptr = static_cast<half*>(inputs.data_ptr()) + head_dim;
  auto inputs_v_ptr = static_cast<half*>(inputs.data_ptr()) + 2 * head_dim;

  auto inputs_q_grads_ptr = static_cast<half*>(inputs_grads.data_ptr());
  auto inputs_k_grads_ptr = static_cast<half*>(inputs_grads.data_ptr()) + head_dim;
  auto inputs_v_grads_ptr = static_cast<half*>(inputs_grads.data_ptr()) + 2 * head_dim;

  char a_layout_n{'n'};
  char a_layout_t{'t'};
  char b_layout_n{'n'};
  char b_layout_t{'t'};

  BAGUA_CUDABLAS_CHECK(cublasSetMathMode(handle, CUBLAS_TENSOR_OP_MATH));

  // MatMul2 Dgrad1
  gemm_switch_fp32accum(     state,
                             a_layout_t,
                             b_layout_n,
                             k_seq_len,
                             q_seq_len,
                             head_dim,
                             alpha,
                             static_cast<const half*>(inputs_v_ptr),
                             lead_dim,
                             batch_stride,
                             static_cast<const half*>(output_grads.data_ptr()),
                             head_dim * attn_batches,
                             head_dim,
                             beta,
                             static_cast<half*>(dropout_results_grads.data_ptr()),
                             k_seq_len,
                             k_seq_len * q_seq_len,
                             attn_batches);

  // Matmul2 Dgrad2
  gemm_switch_fp32accum(     state,
                             a_layout_n,
                             b_layout_t,
                             head_dim,
                             k_seq_len,
                             q_seq_len,
                             alpha,
                             static_cast<const half*>(output_grads.data_ptr()),
                             head_dim * attn_batches,
                             head_dim,
                             static_cast<const half*>(dropout_results.data_ptr()),
                             k_seq_len,
                             k_seq_len * q_seq_len,
                             beta,
                             inputs_v_grads_ptr,
                             lead_dim,
                             batch_stride,
                             attn_batches);

  // Apply Dropout Mask and Scale by Dropout Probability
  apex_masked_scale_cuda<at::Half,float,uint32_t>(
                             static_cast<at::Half const*>(dropout_results_grads.data_ptr()),
                             static_cast<at::Half*>(dropout_results_grads.data_ptr()),
                             static_cast<uint8_t const*>(dropout_mask.data_ptr()),
                             dropout_elems,
                             (1.0 / (1.0 - dropout_prob)));

  // Softmax Grad
  bool softmax_success = false;
  softmax_success = dispatch_softmax_backward<half, half, float>(
                             static_cast<half*>(dropout_results_grads.data_ptr()),
                             static_cast<half*>(dropout_results_grads.data_ptr()),
                             reinterpret_cast<half const*>(softmax_results.data_ptr()),
                             k_seq_len,
                             k_seq_len,
                             attn_batches * q_seq_len);
  assert(softmax_success);

  // Matmul1 Dgrad1
  gemm_switch_fp32accum(     state,
                             a_layout_n,
                             b_layout_n,
                             head_dim,
                             q_seq_len,
                             k_seq_len,
                             scale,
                             inputs_k_ptr,
                             lead_dim,
                             batch_stride,
                             static_cast<half*>(dropout_results_grads.data_ptr()),
                             k_seq_len,
                             k_seq_len * q_seq_len,
                             beta,
                             inputs_q_grads_ptr,
                             lead_dim,
                             batch_stride,
                             attn_batches);

  // Matmul1 Dgrad2
  gemm_switch_fp32accum(     state,
                             a_layout_n,
                             b_layout_t,
                             head_dim,
                             k_seq_len,
                             q_seq_len,
                             scale,
                             inputs_q_ptr,
                             lead_dim,
                             batch_stride,
                             static_cast<half*>(dropout_results_grads.data_ptr()),
                             k_seq_len,
                             k_seq_len * q_seq_len,
                             beta,
                             inputs_k_grads_ptr,
                             lead_dim,
                             batch_stride,
                             attn_batches);

  BAGUA_CUDABLAS_CHECK(cublasSetMathMode(handle, CUBLAS_DEFAULT_MATH));

  return {
      inputs_grads,
  };
}

} // end namespace attention_score
} // end namespace self
} // end namespace multihead_attn
