# GPU Acceleration for Mojo on Apple Silicon

Analysis of GPU acceleration approaches for high-performance Mojo libraries on macOS.
Based on research into MLX, Mojo's GPU compiler, and Metal shader approaches.

**Date:** January 2026
**Context:** mojo-json GPU acceleration (Phase 3 optimization)

---

## Executive Summary

| Approach | Status | Throughput Potential | Complexity |
|----------|--------|---------------------|------------|
| Mojo GPU Compiler | Blocked | Unknown | Low |
| MLX Framework (via FFI) | Viable | 2,000+ MB/s | Medium |
| Raw Metal Shaders (via FFI) | Viable | 2,000+ MB/s | High |
| CPU SIMD (current) | Working | 500-1,000 MB/s | Already done |

**Recommendation:** Use MLX for GPU operations via Mojo FFI. MLX is the best-of-breed
Metal/GPU library for Apple Silicon with extensive optimization and active development.

---

## Background: Why GPU for JSON Parsing?

JSON structural scanning (Stage 1) is embarrassingly parallel:
- Each character can be classified independently
- GPU can process thousands of characters simultaneously
- Crossover point: GPU faster for files >64KB

### Two-Stage Pipeline

```
JSON String (>64KB)
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│  GPU Stage 1a: Character Classification                 │
│  - Classify each byte: { } [ ] " : , \ whitespace other │
│  - Fully parallel (one thread per character)            │
│  - O(1) per character, O(n/threads) total               │
└─────────────────────────────────────────────────────────┘
    │ Classification array
    ▼
┌─────────────────────────────────────────────────────────┐
│  CPU Stage 1b: Build Structural Index                   │
│  - Track string state (sequential dependency)          │
│  - Handle escape sequences                              │
│  - Build positions/characters arrays                    │
└─────────────────────────────────────────────────────────┘
    │
    ▼
StructuralIndex → Stage 2 (Value Extraction)
```

---

## Approach 1: Mojo GPU Compiler

### Description

Mojo 0.25.7 includes experimental GPU support via `gpu.host.DeviceContext` and
`LayoutTensor` for Metal compute shaders.

### Code Pattern

```mojo
from gpu.host import DeviceContext
from gpu import block_idx, block_dim, thread_idx
from layout import Layout, LayoutTensor

alias chunk_layout = Layout.row_major(65536)  # Fixed size at compile time

fn classify_kernel(
    input_tensor: LayoutTensor[DType.uint8, chunk_layout, MutableAnyOrigin],
    output_tensor: LayoutTensor[DType.uint8, chunk_layout, MutableAnyOrigin],
):
    var tid = block_idx.x * block_dim.x + thread_idx.x
    if tid < 65536:
        var ch = input_tensor[tid]
        # Classification logic...
        output_tensor[tid] = classify_char(ch)

fn main() raises:
    var ctx = DeviceContext()
    var input_dev = ctx.enqueue_create_buffer[DType.uint8](65536)
    var output_dev = ctx.enqueue_create_buffer[DType.uint8](65536)
    # ... buffer setup ...
    ctx.enqueue_function[classify_kernel](in_tensor, out_tensor, grid_dim=256, block_dim=256)
    ctx.synchronize()
```

### Status: BLOCKED

The Mojo Metal compiler crashes with:

```
Metal Compiler failed to compile metallib. Please submit a bug report.
```

This appears to be a compiler bug in Mojo 0.25.7 Metal codegen. The crash occurs during
the `.metal` → `.metallib` compilation step internal to Mojo.

### Lessons Learned

1. **LayoutTensor requires compile-time sizes** - Cannot use dynamic `len(data)`
2. **`MutableAnyOrigin` deprecated** - Use `MutAnyOrigin` (warning only)
3. **Kernel functions** - Can be nested or module-level, both crash
4. **Chunk-based processing** - Fixed 64KB chunks work around dynamic size limitation

### Recommendation

Wait for Mojo Metal compiler fixes. Monitor:
- Mojo changelog for GPU/Metal fixes
- Modular GitHub issues for Metal compiler bugs

---

## Approach 2: MLX Framework (Recommended)

### Description

[MLX](https://github.com/ml-explore/mlx) is Apple's production-grade ML framework
optimized for Apple Silicon. It provides:

- **High-performance Metal kernels** - Extensively optimized
- **Python + C++ APIs** - Can be called from Mojo via FFI
- **Custom kernel support** - Define new Metal operations
- **Automatic memory management** - Unified memory model
- **JIT compilation** - On-demand kernel compilation

### MLX Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  MLX Python/C++ API                                     │
├─────────────────────────────────────────────────────────┤
│  Operation Dispatch (lazy evaluation)                   │
├─────────────────────────────────────────────────────────┤
│  Metal Backend                                          │
│  ├── Pre-compiled kernels (mlx.metallib)               │
│  ├── JIT kernels (runtime compilation)                 │
│  └── Custom kernels (user-defined .metal)              │
├─────────────────────────────────────────────────────────┤
│  Metal Performance Shaders (MPS)                       │
├─────────────────────────────────────────────────────────┤
│  Apple Silicon GPU (M1-M5)                              │
└─────────────────────────────────────────────────────────┘
```

### Key MLX Techniques

#### 1. Pre-compiled Metal Libraries

MLX compiles all kernels to `mlx.metallib` at build time:

```bash
# Compilation flow (from MLX CMakeLists.txt)
xcrun -sdk macosx metal -c kernel.metal -o kernel.air
xcrun -sdk macosx metallib *.air -o mlx.metallib
```

The metallib is loaded at runtime:
```cpp
MTL::Library* lib = device->newLibrary(NS::String::string(path, NS::UTF8StringEncoding), &error);
```

#### 2. JIT Compilation

For dynamic operations, MLX generates Metal source at runtime:

```cpp
// From mlx/backend/metal/custom_kernel.cpp
std::string kernel_source;
kernel_source += "[[kernel]] void " + func_name + "(\n";
kernel_source += "  device const uint8_t* input [[buffer(0)]],\n";
kernel_source += "  device uint8_t* output [[buffer(1)]],\n";
// ... dynamic parameter binding
```

#### 3. Lookup Table Optimization

For classification operations, MLX uses constant memory lookup tables:

```metal
constant uint8_t CHAR_LOOKUP[256] = {
    // Pre-computed classification for each byte value
    9, 9, 9, 9, 9, 9, 9, 9, 9, 0, 0, 9, 9, 0, 9, 9,  // 0x00-0x0F
    // ... full 256-byte table
};

[[kernel]] void classify(
    device const uint8_t* input [[buffer(0)]],
    device uint8_t* output [[buffer(1)]],
    uint index [[thread_position_in_grid]]
) {
    output[index] = CHAR_LOOKUP[input[index]];  // Single lookup per thread
}
```

#### 4. Vectorized Processing

Process multiple elements per thread to reduce dispatch overhead:

```metal
[[kernel]] void classify_vec8(
    device const uint8_t* input [[buffer(0)]],
    device uint8_t* output [[buffer(1)]],
    uint index [[thread_position_in_grid]]
) {
    uint base = index * 8;
    // Unrolled: 8 bytes per thread
    output[base]     = CHAR_LOOKUP[input[base]];
    output[base + 1] = CHAR_LOOKUP[input[base + 1]];
    // ... 6 more
}
```

### Integration with Mojo

#### Option A: Python Bridge (Simplest)

```mojo
from python import Python

fn gpu_classify(data: String) raises -> List[UInt8]:
    var mx = Python.import_module("mlx.core")
    var arr = mx.array(data.as_bytes(), dtype=mx.uint8)

    # Use MLX's custom_kernel or write custom op
    var result = mx.custom_kernel(
        source="...",  # Our classification kernel
        inputs=[arr],
        output_dtype=mx.uint8
    )
    return to_mojo_list(result)
```

#### Option B: C FFI (Better Performance)

```mojo
# In ffi/mlx_bridge.mojo
from sys.ffi import c_void, external_call

alias MLXArray = c_void

@external_call["mlx_create_array"]
fn mlx_create_array(data: UnsafePointer[UInt8], size: Int) -> MLXArray: ...

@external_call["mlx_run_kernel"]
fn mlx_run_kernel(name: StringLiteral, input: MLXArray, output: MLXArray) -> Bool: ...
```

### Recommendation

1. **Short term:** Use MLX Python bridge for prototyping
2. **Medium term:** Create C wrapper for critical path operations
3. **Long term:** Contribute Mojo bindings to MLX upstream

---

## Approach 3: Raw Metal Shaders

### Description

Bypass Mojo's GPU compiler by writing Metal shaders directly and loading via FFI.

### Implementation

#### 1. Metal Shader (json_classify.metal)

```metal
#include <metal_stdlib>
using namespace metal;

constant uint8_t CHAR_LOOKUP[256] = { /* pre-computed */ };

[[kernel]] void json_classify_lookup_vec8(
    device const uint8_t* input [[buffer(0)]],
    device uint8_t* output [[buffer(1)]],
    constant const uint32_t& size [[buffer(2)]],
    uint index [[thread_position_in_grid]]
) {
    uint base = index * 8;
    if (base + 7 < size) {
        output[base]     = CHAR_LOOKUP[input[base]];
        output[base + 1] = CHAR_LOOKUP[input[base + 1]];
        output[base + 2] = CHAR_LOOKUP[input[base + 2]];
        output[base + 3] = CHAR_LOOKUP[input[base + 3]];
        output[base + 4] = CHAR_LOOKUP[input[base + 4]];
        output[base + 5] = CHAR_LOOKUP[input[base + 5]];
        output[base + 6] = CHAR_LOOKUP[input[base + 6]];
        output[base + 7] = CHAR_LOOKUP[input[base + 7]];
    }
}
```

#### 2. Compilation Script

```bash
#!/bin/bash
# Compile to metallib (same as MLX build process)
xcrun -sdk macosx metal -c json_classify.metal -o json_classify.air
xcrun -sdk macosx metallib json_classify.air -o json_classify.metallib
```

#### 3. C Bridge (metal_bridge.c)

```c
#import <Metal/Metal.h>

typedef struct {
    id<MTLDevice> device;
    id<MTLLibrary> library;
    id<MTLFunction> kernel;
    id<MTLComputePipelineState> pipeline;
    id<MTLCommandQueue> queue;
} MetalContext;

MetalContext* metal_init(const char* metallib_path) {
    MetalContext* ctx = malloc(sizeof(MetalContext));
    ctx->device = MTLCreateSystemDefaultDevice();

    NSError* error = nil;
    NSURL* url = [NSURL fileURLWithPath:@(metallib_path)];
    ctx->library = [ctx->device newLibraryWithURL:url error:&error];

    ctx->kernel = [ctx->library newFunctionWithName:@"json_classify_lookup_vec8"];
    ctx->pipeline = [ctx->device newComputePipelineStateWithFunction:ctx->kernel error:&error];
    ctx->queue = [ctx->device newCommandQueue];

    return ctx;
}

void metal_classify(MetalContext* ctx, const uint8_t* input, uint8_t* output, uint32_t size) {
    id<MTLBuffer> input_buf = [ctx->device newBufferWithBytes:input
                                                       length:size
                                                      options:MTLResourceStorageModeShared];
    id<MTLBuffer> output_buf = [ctx->device newBufferWithLength:size
                                                        options:MTLResourceStorageModeShared];

    id<MTLCommandBuffer> cmd = [ctx->queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [cmd computeCommandEncoder];

    [encoder setComputePipelineState:ctx->pipeline];
    [encoder setBuffer:input_buf offset:0 atIndex:0];
    [encoder setBuffer:output_buf offset:0 atIndex:1];
    [encoder setBytes:&size length:sizeof(size) atIndex:2];

    NSUInteger threads_per_group = ctx->pipeline.maxTotalThreadsPerThreadgroup;
    NSUInteger num_groups = (size / 8 + threads_per_group - 1) / threads_per_group;

    [encoder dispatchThreadgroups:MTLSizeMake(num_groups, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(threads_per_group, 1, 1)];
    [encoder endEncoding];

    [cmd commit];
    [cmd waitUntilCompleted];

    memcpy(output, output_buf.contents, size);
}
```

#### 4. Mojo FFI Wrapper

```mojo
from sys.ffi import c_void, external_call

alias MetalContext = c_void

@external_call["metal_init"]
fn metal_init(metallib_path: UnsafePointer[Int8]) -> UnsafePointer[MetalContext]: ...

@external_call["metal_classify"]
fn metal_classify(
    ctx: UnsafePointer[MetalContext],
    input: UnsafePointer[UInt8],
    output: UnsafePointer[UInt8],
    size: UInt32
): ...

fn gpu_classify_chars(data: String) -> List[UInt8]:
    """GPU-accelerated character classification."""
    var ctx = metal_init("json_classify.metallib".unsafe_ptr())

    var n = len(data)
    var output = List[UInt8](capacity=n)
    output.resize(n, 0)

    metal_classify(ctx, data.unsafe_ptr(), output.unsafe_ptr(), UInt32(n))

    return output^
```

### Tradeoffs

| Aspect | Pro | Con |
|--------|-----|-----|
| Control | Full control over kernel code | Must maintain C bridge |
| Performance | Optimal - direct Metal API | Manual memory management |
| Portability | None - macOS only | N/A for Metal |
| Complexity | Moderate | Requires Obj-C knowledge |

---

## Performance Expectations

### Theoretical GPU Throughput

Apple M3 Max GPU specifications:
- 40 GPU cores, up to 4,096 threads
- 400+ GB/s memory bandwidth
- ~14 TFLOPS compute

For byte classification (memory-bound):
- Theoretical: 400 GB/s / 2 (read+write) = 200 GB/s
- Practical: ~50-100 GB/s with overhead
- Expected: **50,000-100,000 MB/s** for pure GPU

### Hybrid CPU/GPU Pipeline

| Stage | Location | Throughput | Notes |
|-------|----------|------------|-------|
| Classification | GPU | 50,000 MB/s | Memory-bound |
| Index building | CPU | 2,000 MB/s | Sequential |
| **Total** | Hybrid | **~2,000 MB/s** | CPU-bound |

The sequential index-building step is the bottleneck. GPU parallelism
only helps with classification.

### When GPU is Worth It

| File Size | GPU Benefit | Recommendation |
|-----------|-------------|----------------|
| < 16 KB | None | CPU SIMD only |
| 16-64 KB | Marginal | CPU SIMD |
| 64-256 KB | Moderate | GPU if available |
| > 256 KB | Significant | Always GPU |
| > 1 MB | Large | GPU required |

---

## Conclusion

1. **Mojo GPU compiler is currently broken** - Wait for fixes
2. **MLX is the production-ready option** - Use for real workloads
3. **Raw Metal is viable** - For maximum control
4. **CPU SIMD is already fast** - 500+ MB/s sufficient for most use cases

### Next Steps for mojo-json

1. Continue using CPU SIMD implementation (~500 MB/s)
2. Add MLX-based GPU path for files > 256KB
3. Monitor Mojo GPU compiler progress
4. Consider contributing to mojo-metal experimental library

---

## References

- [MLX GitHub](https://github.com/ml-explore/mlx)
- [MLX Documentation](https://ml-explore.github.io/mlx/)
- [Metal Shading Language Specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf)
- [simdjson](https://github.com/simdjson/simdjson) - Inspiration for two-stage architecture
- [mojo-metal (experimental)](/Users/amund/mojo-contrib-experimental/mojo-metal)
