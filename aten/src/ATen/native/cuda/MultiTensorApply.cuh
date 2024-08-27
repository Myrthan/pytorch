#pragma once
#include <ATen/core/Tensor.h>
#include <ATen/cuda/CUDAContext.h>
#include <c10/cuda/CUDAGuard.h>
#include <ATen/native/cuda/Loops.cuh>
#include <ATen/native/cuda/MemoryAccess.cuh>
#include <vector>

namespace at::native {

namespace {

static constexpr int64_t kILP = 4;
static constexpr int64_t kChunkSize = 65536;
static constexpr int64_t kBlockSize = 512;

// NOTE: [32KB kernel argument size support]
// 32KB kernel argument size support is available only when CUDART_VERSION >=
// 12010 and the driver version is >= 530. Only the former condition can be
// checked at compile time. This implies:
//
// - If CUDART_VERSION < 12010, kernels for the 32KB kernel argument size will
// not be built.
//
// - If CUDART_VERSION >= 12010, kernels for both 4KB and 32KB kernel argument
// sizes will be built. However, due to CUDA's minor version compatibility,
// even when CUDART_VERSION >= 12010, the driver may not support 32KB.
// Therefore, a runtime check is necessary to determine the appropriate kernel
// to dispatch.
//
// - TODO(yifu): once there's a CUDART version that is not compatible with any
// driver version below 530, we can determine at compile time to not compile
// the kernels for 4KB kernel argument size.
//
// https://developer.nvidia.com/blog/cuda-12-1-supports-large-kernel-parameters/

__global__ void dummy_kernel(void*) {}

bool supports_large_kernel_arg() {
#if !defined(USE_ROCM) && defined(CUDART_VERSION) && CUDART_VERSION >= 12010
  static std::optional<bool> supports_large_kernel_arg_ = std::nullopt;
  if (!supports_large_kernel_arg_.has_value()) {
    int driver_ver = 0;
    cudaDriverGetVersion(&driver_ver);
    cudaDeviceProp* prop = at::cuda::getCurrentDeviceProperties();
    cudaFuncAttributes func_attr;
    cudaFuncGetAttributes(&func_attr, (void*)dummy_kernel);
    *supports_large_kernel_arg_ = (driver_ver >= 12010) && prop->major >= 7 &&
        func_attr.binaryVersion >= 70;
    // LOG(WARNING) << "binary version: " << func_attr.binaryVersion;
    // LOG(WARNING) << "ptx version: " << func_attr.ptxVersion;
  }
  return *supports_large_kernel_arg_;
#else
  return false;
#endif
}

#if !defined(USE_ROCM) && defined(CUDART_VERSION) && CUDART_VERSION >= 12010
#define DISPATCH_MULTI_TENSOR_APPLY(...)                \
  if (supports_large_kernel_arg()) {                    \
    constexpr bool large_kernel_arg C10_UNUSED = true;  \
    __VA_ARGS__();                                      \
  } else {                                              \
    constexpr bool large_kernel_arg C10_UNUSED = false; \
    __VA_ARGS__();                                      \
  }
#else
#define DISPATCH_MULTI_TENSOR_APPLY(...)                \
  do {                                                  \
    constexpr bool large_kernel_arg C10_UNUSED = false; \
    __VA_ARGS__();                                      \
  } while (0);
#endif

template <bool large_kernel_arg>
struct DepthToMaxConfig;

template <>
struct DepthToMaxConfig<false> {
  static constexpr int depth_to_max_tensors[5] = {110, 64, 48, 36, 30};
  static constexpr int depth_to_max_blocks[5] = {320, 320, 320, 320, 320};
  static constexpr int depth_to_max_tensors_scalarlist[5] =
      {96, 64, 48, 36, 30};
  static constexpr int depth_to_max_tensors_scalarlist_of_complex_double[2] = {
      72,
      60};
  using TensorIdxType = unsigned char;
};

// #if defined(__CUDA_ARCH__) && __CUDA_ARCH__ < 700
// template <>
// struct DepthToMaxConfig<true> : DepthToMaxConfig<false> {};
// #else
template <>
struct DepthToMaxConfig<true> {
  // TODO(yifu): These values are not yet optimally tuned. I simply multiplied
  // the values tuned for 4KB kernel argument size limit by 7 (the kernel
  // argument size limit increased by 8x but we need to change the type of
  // block_to_tensor from unsigned char to uint16_t to support larger number of
  // tensors).
  static constexpr int depth_to_max_tensors[5] = {770, 448, 336, 252, 210};
  static constexpr int depth_to_max_blocks[5] = {2240, 2240, 2240, 2240, 2240};
  static constexpr int depth_to_max_tensors_scalarlist[5] =
      {672, 448, 336, 252, 210};
  static constexpr int depth_to_max_tensors_scalarlist_of_complex_double[2] = {
      504,
      420};
  using TensorIdxType = uint16_t;
};
// #endif

template <typename T>
__device__ __forceinline__ bool is_aligned(T* p) {
  return ((uint64_t)p) % (kILP * sizeof(T)) == 0;
}

template <typename T>
__device__ __forceinline__ void load_store(
    T* dst,
    T* src,
    int64_t dst_offset,
    int64_t src_offset) {
  using LT = at::native::memory::aligned_vector<T, kILP>;
  ((LT*)dst)[dst_offset] = ((LT*)src)[src_offset];
}

template <int n, bool large_kernel_arg>
struct TensorListMetadata {
  using Conf = DepthToMaxConfig<large_kernel_arg>;
  const void* addresses[n][Conf::depth_to_max_tensors[n - 1]];
  int64_t numel_for_tensor[Conf::depth_to_max_tensors[n - 1]];
  typename Conf::TensorIdxType
      block_to_tensor[Conf::depth_to_max_blocks[n - 1]];
  int block_to_chunk[Conf::depth_to_max_blocks[n - 1]];
  int start_tensor_this_launch;
};

template <typename scalar_vals_t, int n, bool large_kernel_arg>
struct TensorListScalarListMetadata {
  using Conf = DepthToMaxConfig<large_kernel_arg>;
  const void* addresses[n][Conf::depth_to_max_tensors_scalarlist[n - 1]];
  int64_t numel_for_tensor[Conf::depth_to_max_tensors_scalarlist[n - 1]];
  scalar_vals_t scalar_vals[Conf::depth_to_max_tensors_scalarlist[n - 1]];
  typename Conf::TensorIdxType
      block_to_tensor[Conf::depth_to_max_blocks[n - 1]];
  int block_to_chunk[Conf::depth_to_max_blocks[n - 1]];
};

// note(mkozuki): `n` of 1&2 violate the limit of cuda kernel argument size of
// 4kb with `c10::complex<double>`
template <bool large_kernel_arg>
struct TensorListScalarListMetadata<c10::complex<double>, 1, large_kernel_arg> {
  using Conf = DepthToMaxConfig<large_kernel_arg>;
  const void*
      addresses[1][Conf::depth_to_max_tensors_scalarlist_of_complex_double[0]];
  int64_t numel_for_tensor
      [Conf::depth_to_max_tensors_scalarlist_of_complex_double[0]];
  c10::complex<double>
      scalar_vals[Conf::depth_to_max_tensors_scalarlist_of_complex_double[0]];
  typename Conf::TensorIdxType
      block_to_tensor[Conf::depth_to_max_blocks[1 - 1]];
  int block_to_chunk[Conf::depth_to_max_blocks[1 - 1]];
};

template <bool large_kernel_arg>
struct TensorListScalarListMetadata<c10::complex<double>, 2, large_kernel_arg> {
  using Conf = DepthToMaxConfig<large_kernel_arg>;
  const void*
      addresses[2][Conf::depth_to_max_tensors_scalarlist_of_complex_double[1]];
  int64_t numel_for_tensor
      [Conf::depth_to_max_tensors_scalarlist_of_complex_double[1]];
  c10::complex<double>
      scalar_vals[Conf::depth_to_max_tensors_scalarlist_of_complex_double[1]];
  typename Conf::TensorIdxType
      block_to_tensor[Conf::depth_to_max_blocks[2 - 1]];
  int block_to_chunk[Conf::depth_to_max_blocks[2 - 1]];
};

// NOTE(crcrpar): This is a conservative resolution to handle `state_steps`
// whose each element is `at::Tensor` of 1 element representing the number of
// `step`s called so far.
template <int n, bool large_kernel_arg>
struct FusedOptimizerTensorListMetadata {
  using Conf = DepthToMaxConfig<large_kernel_arg>;
  const void* addresses[n][Conf::depth_to_max_tensors[n - 1]];
  int64_t numel_for_tensor[Conf::depth_to_max_tensors[n - 1]];
  const void*
      state_steps_addresses[Conf::depth_to_max_tensors_scalarlist[n - 1]];
  typename Conf::TensorIdxType
      block_to_tensor[Conf::depth_to_max_blocks[n - 1]];
  int block_to_chunk[Conf::depth_to_max_blocks[n - 1]];
  int start_tensor_this_launch;
};

// Kernels with 32KB argument - always build host code but only build device
// code for __CUDA_ARCH__ >= 700.
#if !defined(__CUDA_ARCH__) || __CUDA_ARCH__ >= 700
template <typename T, typename U, typename... ArgTypes>
C10_LAUNCH_BOUNDS_1(kBlockSize)
__global__ typename std::enable_if<U::use_large_kernel_arg, void>::type
    multi_tensor_apply_kernel(T tensorListMeta, U callable, ArgTypes... args) {
  // Hand the chunk information to the user-supplied functor to process however
  // it likes.
  callable(kChunkSize, tensorListMeta, args...);
}
#else
#pragma nv_diag_suppress 114
template <typename T, typename U, typename... ArgTypes>
C10_LAUNCH_BOUNDS_1(kBlockSize)
__global__ typename std::enable_if<U::use_large_kernel_arg, void>::type
    multi_tensor_apply_kernel(T tensorListMeta, U callable, ArgTypes... args);
#pragma nv_diag_default 114
#endif

template <typename T, typename U, typename... ArgTypes>
C10_LAUNCH_BOUNDS_1(kBlockSize)
__global__ typename std::enable_if<!U::use_large_kernel_arg, void>::type
    multi_tensor_apply_kernel(T tensorListMeta, U callable, ArgTypes... args) {
  callable(kChunkSize, tensorListMeta, args...);
}

} // namespace

// multi_tensor_apply enables horizontal fusion across lists of tensors.
// For example, whereas you once had a for-loop of a + b = c, where a, b,
// and c are individual tensors in lists as, bs, and cs, you can now with
// fewer kernel launches compute as + bs = cs.
//
// You can also imagine bs to be a scalar list vs a tensor list.
//
// The function below takes in tensor lists, scalars, and a callable and
// chunks up the computation to launch as few kernels as possible by iterating
// through every "chunk" in every tensor (thus the nested for loops). In the
// simplest case, everything gets bundled into just one kernel launch, but
// due to blocksize constraints, we may need to launch multiple kernels.
// Each kernel launch is defined by one tensorListMeta construct, which we
// use to track and reset the necessary metadata for each launch.
template <int depth, typename scalar_T, typename T, typename... ArgTypes>
void multi_tensor_apply(
    std::vector<std::vector<at::Tensor>>& tensor_lists,
    at::ArrayRef<Scalar> scalars,
    T callable,
    ArgTypes... args) {
  TORCH_CHECK(
      tensor_lists.size() == depth,
      "Number of tensor lists has to match the depth.");
  const size_t n_tensors = tensor_lists[0].size();
  using scalar_vals_t = typename T::opmath_t;
  using TensorListMeta = TensorListScalarListMetadata<
      scalar_vals_t,
      depth,
      T::use_large_kernel_arg>;
  auto tensorListMeta = std::make_unique<TensorListMeta>();

  using Conf = DepthToMaxConfig<T::use_large_kernel_arg>;

  int loc_block_info = 0;
  int loc_tensor_info = 0;
  for (size_t t = 0; t < n_tensors; t++) {
    // short-circuit to avoid adding empty tensors to tensorListMeta
    if (tensor_lists[0][t].numel() == 0) {
      continue;
    }
    tensorListMeta->scalar_vals[loc_tensor_info] = scalars[t].to<scalar_T>();
    tensorListMeta->numel_for_tensor[loc_tensor_info] =
        tensor_lists[0][t].numel();
    for (int d = 0; d < depth; d++) {
      tensorListMeta->addresses[d][loc_tensor_info] =
          tensor_lists[d][t].const_data_ptr();
    }
    loc_tensor_info++;

    // now we enter [chunking territory].
    // we will launch a kernel when EITHER the blocks get filled up OR
    // the tensors get filled up. There will always be at least one block
    // per tensor since the zero-sized ones will not enter the loop, so
    // the nested forloop within represents iterating through the chunks
    // of a single tensor.
    const auto numel = tensor_lists[0][t].numel();
    const auto chunks = numel / kChunkSize + (numel % kChunkSize != 0);
    for (auto chunk = 0; chunk < chunks; chunk++) {
      tensorListMeta->block_to_tensor[loc_block_info] = loc_tensor_info - 1;
      tensorListMeta->block_to_chunk[loc_block_info] = chunk;
      loc_block_info++;

      // a tensor is not considered full unless all its chunks have been
      // processed
      const bool tensors_full =
          (loc_tensor_info ==
               Conf::depth_to_max_tensors_scalarlist[depth - 1] &&
           chunk == chunks - 1);
      const bool blocks_full =
          (loc_block_info == Conf::depth_to_max_blocks[depth - 1]);

      if (tensors_full || blocks_full) {
        void* kernel_args[] = {tensorListMeta.get(), &callable, &args...};
        cudaLaunchKernel(
            (void*)multi_tensor_apply_kernel<TensorListMeta, T, ArgTypes...>,
            loc_block_info,
            kBlockSize,
            kernel_args,
            0,
            at::cuda::getCurrentCUDAStream());
        C10_CUDA_KERNEL_LAUNCH_CHECK();

        // Reset.
        loc_block_info = 0;
        // all chunks have already been handled in the kernel
        if (chunk == chunks - 1) {
          loc_tensor_info = 0;
        } else { // blocks were full and tensor chunks remain
          tensorListMeta->numel_for_tensor[0] =
              tensorListMeta->numel_for_tensor[loc_tensor_info - 1];
          tensorListMeta->scalar_vals[0] =
              tensorListMeta->scalar_vals[loc_tensor_info - 1];
          for (int d = 0; d < depth; d++) {
            tensorListMeta->addresses[d][0] =
                tensorListMeta->addresses[d][loc_tensor_info - 1];
          }
          loc_tensor_info = 1;
        }
      }
    }
  }

  // note: [finishing what we started]
  // if there's remaining work to be done but the tensors/blocks aren't full
  // yet we are at the end, submit the kernel to do the work!
  if (loc_block_info != 0) {
    void* kernel_args[] = {tensorListMeta.get(), &callable, &args...};
    cudaLaunchKernel(
        (void*)multi_tensor_apply_kernel<TensorListMeta, T, ArgTypes...>,
        loc_block_info,
        kBlockSize,
        kernel_args,
        0,
        at::cuda::getCurrentCUDAStream());
    C10_CUDA_KERNEL_LAUNCH_CHECK();
  }
}

template <int depth, typename T, typename... ArgTypes>
void multi_tensor_apply(
    std::vector<std::vector<at::Tensor>>& tensor_lists,
    T callable,
    ArgTypes... args) {
  TORCH_CHECK(
      tensor_lists.size() == depth,
      "Number of tensor lists has to match the depth.");
  const size_t n_tensors = tensor_lists[0].size();
  using TensorListMeta = TensorListMetadata<depth, T::use_large_kernel_arg>;
  auto tensorListMeta = std::make_unique<TensorListMeta>();
  tensorListMeta->start_tensor_this_launch = 0;

  using Conf = DepthToMaxConfig<T::use_large_kernel_arg>;

  int loc_block_info = 0;
  int loc_tensor_info = 0;
  for (size_t t = 0; t < n_tensors; t++) {
    // short-circuit to avoid adding empty tensors to tensorListMeta
    if (tensor_lists[0][t].numel() == 0) {
      continue;
    }
    tensorListMeta->numel_for_tensor[loc_tensor_info] =
        tensor_lists[0][t].numel();
    for (int d = 0; d < depth; d++) {
      tensorListMeta->addresses[d][loc_tensor_info] =
          tensor_lists[d][t].const_data_ptr();
    }
    loc_tensor_info++;

    // see note: [chunking territory].
    const auto numel = tensor_lists[0][t].numel();
    const auto chunks = numel / kChunkSize + (numel % kChunkSize != 0);
    for (auto chunk = 0; chunk < chunks; chunk++) {
      tensorListMeta->block_to_tensor[loc_block_info] = loc_tensor_info - 1;
      tensorListMeta->block_to_chunk[loc_block_info] = chunk;
      loc_block_info++;

      const bool tensors_full =
          (loc_tensor_info == Conf::depth_to_max_tensors[depth - 1] &&
           chunk == chunks - 1);
      const bool blocks_full =
          (loc_block_info == Conf::depth_to_max_blocks[depth - 1]);

      if (tensors_full || blocks_full) {
        void* kernel_args[] = {tensorListMeta.get(), &callable, &args...};
        cudaLaunchKernel(
            (void*)multi_tensor_apply_kernel<TensorListMeta, T, ArgTypes...>,
            loc_block_info,
            kBlockSize,
            kernel_args,
            0,
            at::cuda::getCurrentCUDAStream());
        C10_CUDA_KERNEL_LAUNCH_CHECK();

        // Reset.
        loc_block_info = 0;
        if (chunk == chunks - 1) {
          loc_tensor_info = 0;
          tensorListMeta->start_tensor_this_launch = t + 1;
        } else {
          tensorListMeta->numel_for_tensor[0] =
              tensorListMeta->numel_for_tensor[loc_tensor_info - 1];
          for (int d = 0; d < depth; d++) {
            tensorListMeta->addresses[d][0] =
                tensorListMeta->addresses[d][loc_tensor_info - 1];
          }
          loc_tensor_info = 1;
          tensorListMeta->start_tensor_this_launch = t;
        }
      }
    }
  }

  // see note: [finishing what we started]
  if (loc_block_info != 0) {
    void* kernel_args[] = {tensorListMeta.get(), &callable, &args...};
    cudaLaunchKernel(
        (void*)multi_tensor_apply_kernel<TensorListMeta, T, ArgTypes...>,
        loc_block_info,
        kBlockSize,
        kernel_args,
        0,
        at::cuda::getCurrentCUDAStream());
    C10_CUDA_KERNEL_LAUNCH_CHECK();
  }
}

template <int depth, typename T, typename... ArgTypes>
void multi_tensor_apply_for_fused_optimizer(
    std::vector<std::vector<at::Tensor>>& tensor_lists,
    at::TensorList state_steps,
    T callable,
    ArgTypes... args) {
  TORCH_CHECK(
      tensor_lists.size() == depth,
      "Number of tensor lists has to match the depth");
  const auto num_tensors = tensor_lists[0].size();
  using TensorListMeta =
      FusedOptimizerTensorListMetadata<depth, T::use_large_kernel_arg>;
  auto tensorListMeta = std::make_unique<TensorListMeta>();

  using Conf = DepthToMaxConfig<T::use_large_kernel_arg>;

  int loc_block_info = 0;
  int loc_tensor_info = 0;
  for (const auto& tensor_index : c10::irange(num_tensors)) {
    // short-circuit to avoid adding empty tensors to tensorListMeta
    if (tensor_lists[0][tensor_index].numel() == 0) {
      continue;
    }
    tensorListMeta->state_steps_addresses[loc_tensor_info] =
        state_steps[tensor_index].const_data_ptr();
    tensorListMeta->numel_for_tensor[loc_tensor_info] =
        tensor_lists[0][tensor_index].numel();
    for (const auto& d : c10::irange(depth)) {
      tensorListMeta->addresses[d][loc_tensor_info] =
          tensor_lists[d][tensor_index].const_data_ptr();
    }
    loc_tensor_info++;

    // see above note: [chunking territory]
    const auto numel = tensor_lists[0][tensor_index].numel();
    const auto chunks = numel / kChunkSize + (numel % kChunkSize != 0);
    TORCH_CHECK(chunks > -1);
    for (const auto& chunk : c10::irange(chunks)) {
      tensorListMeta->block_to_tensor[loc_block_info] = loc_tensor_info - 1;
      tensorListMeta->block_to_chunk[loc_block_info] = chunk;
      loc_block_info++;

      const auto tensor_full =
          (loc_tensor_info == Conf::depth_to_max_tensors[depth - 1] &&
           chunk == chunks - 1);
      const auto blocks_full =
          loc_block_info == Conf::depth_to_max_blocks[depth - 1];

      if (tensor_full || blocks_full) {
        void* kernel_args[] = {tensorListMeta.get(), &callable, &args...};
        cudaLaunchKernel(
            (void*)multi_tensor_apply_kernel<TensorListMeta, T, ArgTypes...>,
            loc_block_info,
            kBlockSize,
            kernel_args,
            0,
            at::cuda::getCurrentCUDAStream());
        C10_CUDA_KERNEL_LAUNCH_CHECK();

        // Reset.
        loc_block_info = 0;
        if (chunk == chunks - 1) {
          loc_tensor_info = 0;
        } else {
          tensorListMeta->numel_for_tensor[0] =
              tensorListMeta->numel_for_tensor[loc_tensor_info - 1];
          tensorListMeta->state_steps_addresses[0] =
              tensorListMeta->state_steps_addresses[loc_tensor_info - 1];
          for (const auto& d : c10::irange(depth)) {
            tensorListMeta->addresses[d][0] =
                tensorListMeta->addresses[d][loc_tensor_info - 1];
          }
          loc_tensor_info = 1;
        }
      }
    }
  }

  // see above note: [finishing what we've started]
  if (loc_block_info != 0) {
    void* kernel_args[] = {tensorListMeta.get(), &callable, &args...};
    cudaLaunchKernel(
        (void*)multi_tensor_apply_kernel<TensorListMeta, T, ArgTypes...>,
        loc_block_info,
        kBlockSize,
        kernel_args,
        0,
        at::cuda::getCurrentCUDAStream());
    C10_CUDA_KERNEL_LAUNCH_CHECK();
  }
}

} // namespace at::native
