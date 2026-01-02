# Mojo Performance Best & Worst Practices

Lessons learned from optimizing mojo-json (Mojo 0.25.7, January 2026).

## Executive Summary

| Pattern | Impact | Recommendation |
|---------|--------|----------------|
| Move semantics for containers | **4x speedup** | Always use |
| String slicing vs char-by-char | **3-5x speedup** | Always use |
| Pre-sized collections | **2x speedup** | Use when size known |
| Avoid deep copies on access | **2-3x speedup** | Return references |
| SIMD for bulk operations | **3-4x speedup** | Use for >16 bytes |

---

## Best Practices

### 1. Use Move Semantics for Containers

**Cost savings: 2-4x faster**

```mojo
# GOOD: Move the container (no copy)
fn from_array_move(owned value: List[JsonValue]) -> JsonValue:
    var v = JsonValue()
    v._array_val = value^  # Move, not copy
    return v^

# In parser:
return JsonValue.from_array_move(arr^)
```

```mojo
# BAD: Copy the container
fn from_array(value: List[JsonValue]) -> JsonValue:
    var v = JsonValue()
    v._array_val = value.copy()  # Expensive!
    return v^
```

**Measured impact (mojo-json):**
- Before (copy): 3 MB/s parsing throughput
- After (move): 12 MB/s parsing throughput
- **4x improvement**

---

### 2. Use String Slicing, Not Character-by-Character

**Cost savings: 3-5x faster**

```mojo
# GOOD: Slice the string
result += self.source[start:end]  # Single allocation
```

```mojo
# BAD: Character-by-character concatenation
for i in range(start, end):
    result += self.source[i]  # O(n²) allocations!
```

**Measured impact:**
| Size | Char-by-char | Slice | Speedup |
|------|--------------|-------|---------|
| 100 chars | 0.039 ms | 0.009 ms | 4.3x |
| 1000 chars | 0.20 ms | 0.04 ms | 5.0x |

---

### 3. Pre-size Collections When Possible

```mojo
# GOOD: Pre-allocate capacity
var buffer = List[UInt8](capacity=estimated_size)
var result = List[JsonValue](capacity=element_count)
```

```mojo
# BAD: Grow dynamically
var buffer = List[UInt8]()  # Will resize multiple times
for i in range(1000):
    buffer.append(data[i])  # Potential reallocation each time
```

---

### 4. Avoid Deep Copies on Access

**Cost savings: 2-3x faster for repeated access**

```mojo
# GOOD: Return reference (when Mojo supports it)
fn as_array(self) -> ref [self._array_val] List[JsonValue]:
    return self._array_val

# GOOD: Provide both copy and reference versions
fn as_array_copy(self) -> List[JsonValue]:
    return self._array_val.copy()

fn as_array_ref(self) -> ref [self._array_val] List[JsonValue]:
    return self._array_val
```

```mojo
# BAD: Always copy on access
fn as_array(self) -> List[JsonValue]:
    return self._array_val.copy()  # Called every access!
```

---

### 5. SIMD for Bulk Character Operations

**Cost savings: 3-4x faster for strings >16 bytes**

```mojo
alias SIMD_WIDTH = 16

# GOOD: Process 16 bytes at once
fn skip_whitespace_simd(data: String, start: Int) -> Int:
    var pos = start
    while pos + SIMD_WIDTH <= len(data):
        var chunk = SIMD[DType.uint8, SIMD_WIDTH]()
        @parameter
        for i in range(SIMD_WIDTH):
            chunk[i] = ord(data[pos + i])

        var ws_mask = create_whitespace_mask(chunk)
        if ws_mask.reduce_add() == SIMD_WIDTH:
            pos += SIMD_WIDTH  # All whitespace, skip entire chunk
        else:
            # Find first non-whitespace
            @parameter
            for i in range(SIMD_WIDTH):
                if ws_mask[i] == 0:
                    return pos + i
    # Scalar tail...
    return pos
```

**SIMD patterns that work in Mojo 0.25.7:**
- `reduce_add()` for counting matches
- `@parameter for` loops for element-wise operations
- Element access via `chunk[i]`

**Not available in Mojo 0.25.7:**
- PSHUFB (shuffle bytes)
- CLMUL (carry-less multiply)
- Direct SIMD comparison returning SIMD[DType.bool]

---

### 6. Minimize Function Call Overhead in Hot Paths

```mojo
# GOOD: Inline small functions
@always_inline
fn is_whitespace(c: UInt8) -> Bool:
    return c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D

# GOOD: Avoid function calls in tight loops
while pos < n:
    var c = ord(data[pos])
    if c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D:
        pos += 1
    else:
        break
```

```mojo
# BAD: Function call per character
while pos < n:
    if is_whitespace_complex(data[pos]):  # Function call overhead
        pos += 1
    else:
        break
```

---

## Worst Practices (Avoid These)

### 1. Allocating Unused Fields in Variants

```mojo
# BAD: Every JsonValue allocates List AND Dict
struct JsonValue:
    var _type: Int
    var _array_val: List[JsonValue]   # Allocated even for null!
    var _object_val: Dict[String, JsonValue]  # Allocated even for null!

    fn __init__(out self):
        self._array_val = List[JsonValue]()   # Unnecessary allocation
        self._object_val = Dict[String, JsonValue]()  # Unnecessary allocation
```

**Impact:** 1.8 μs overhead per value creation

**Solution:** Use Optional or pointer-based variants (when Mojo supports them better), or accept the overhead and optimize elsewhere.

---

### 2. String Concatenation in Loops

```mojo
# BAD: O(n²) time complexity
var result = String("")
for i in range(n):
    result += char  # New allocation each iteration
```

**Impact:** Quadratic slowdown for large strings

---

### 3. Copying Containers When Moving Would Work

```mojo
# BAD: Unnecessary copy
var arr = build_array()
return JsonValue.from_array(arr)  # Copies arr

# GOOD: Move instead
var arr = build_array()
return JsonValue.from_array_move(arr^)  # Moves arr, no copy
```

---

### 4. Using atof() for Integer-like Numbers

```mojo
# BAD: atof is 10x slower than atol
var f = atof("12345")  # 140 ns

# GOOD: Use atol for integers
var i = atol("12345")  # 14 ns
```

**Measured costs (10,000 iterations):**
- `atol("12345")`: 0.143 ms (14.3 ns/call)
- `atof("123.456")`: 1.406 ms (140.6 ns/call)

---

### 5. Deep Nesting Without Structural Index

```mojo
# BAD: Re-scan entire string for each nested value
fn parse_value(data: String, pos: Int) -> JsonValue:
    # Scans from pos to find structure
    # Child values scan again from their positions
    # O(n * depth) complexity
```

**Solution:** Build structural index first (simdjson approach):
```mojo
struct StructuralIndex:
    var positions: List[Int]      # Where structural chars are
    var characters: List[UInt8]   # Which char at each position

fn parse_with_index(data: String, index: StructuralIndex) -> JsonValue:
    # Jump directly to positions, no scanning
```

---

## Operation Cost Reference (Mojo 0.25.7)

Measured on Apple M3 Ultra, 10,000 iterations:

| Operation | Cost | Notes |
|-----------|------|-------|
| Empty loop iteration | ~0 ns | Optimized away |
| Char access `s[i]` | 1.8 ns | Very fast |
| `ord(s[i])` | 2.0 ns | Minimal overhead |
| String slice `s[a:b]` | 2.9 ns | Efficient |
| String concat `a + b` | 50.8 ns | Allocates new string |
| Dict lookup | 2.7 ns | Fast after creation |
| Dict create + 3 inserts | 95.7 ns | Initial allocation |
| List create + 10 appends | 208.7 ns | Dynamic resizing |
| `atol()` | 14.3 ns | Integer parsing |
| `atof()` | 140.6 ns | Float parsing (10x slower) |
| Char comparison | ~0 ns | Optimized |
| String comparison | ~0 ns | Short-circuit for small strings |

---

## Benchmarking Methodology

### 1. Always Warm Up

```mojo
# Warmup (excluded from timing)
for _ in range(WARMUP_ITERATIONS):
    var _ = parse(data)

# Measured iterations
var start = perf_counter_ns()
for _ in range(ITERATIONS):
    var result = parse(data)
    _ = result  # Prevent optimization
var elapsed = perf_counter_ns() - start
```

### 2. Test Multiple Sizes

```mojo
var sizes = List[Int]()
sizes.append(100)
sizes.append(1000)
sizes.append(10000)

for size in sizes:
    benchmark_at_size(size)
```

### 3. Isolate Operations

```mojo
# Test individual operations, not entire pipeline
fn benchmark_dict_insert():
    var start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var d = Dict[String, Int]()
        d["key"] = 1
    return perf_counter_ns() - start
```

### 4. Calculate Throughput

```mojo
var bytes = len(data)
var seconds = Float64(elapsed_ns) / 1_000_000_000.0
var throughput_mbps = Float64(bytes) / (1024.0 * 1024.0) / seconds
print("Throughput:", Int(throughput_mbps), "MB/s")
```

---

## Architecture Recommendations

### For Maximum Performance: Tape-Based Parsing

```
┌─────────────────────────────────────────────────────────────┐
│  Stage 1: Build Structural Index (SIMD/GPU parallelizable)  │
│  Input: Raw JSON bytes                                       │
│  Output: Tape of (type, offset) pairs                        │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│  Stage 2: On-Demand Value Extraction                         │
│  Only parse values when accessed                             │
│  Use tape offsets to jump directly to data                   │
└─────────────────────────────────────────────────────────────┘
```

**Benefits:**
- No Dict/List allocations during parsing
- O(1) random access to any value
- GPU-friendly (flat memory layout)
- Works with Apple Silicon unified memory

---

## Performance Targets

| Level | Throughput | Technique |
|-------|------------|-----------|
| Baseline | 3 MB/s | Naive implementation |
| Good | 50 MB/s | Move semantics, slicing |
| Better | 300 MB/s | Structural index |
| Best | 1,000+ MB/s | Tape + SIMD + lazy parsing |
| Optimal | 2,000+ MB/s | GPU Stage 1 for large files |

---

## Official Mojo Optimization Techniques (From Modular)

These techniques are from Modular's official documentation and blog posts.

### 1. Compile-Time Parameterization

Use `@parameter` to evaluate loops at compile time, eliminating runtime branching:

```mojo
# GOOD: Compile-time loop unrolling
@parameter
for i in range(16):
    result[i] = chunk[i] + 1  # Unrolled at compile time

# Also good: Compile-time conditionals
@parameter
if simd_width >= 32:
    use_avx512_path()
else:
    use_sse_path()
```

**From Modular docs:** "Compiling only the code paths used for a particular piece of hardware avoids run-time branching and allows full utilization of an accelerator or CPU."

---

### 2. SIMD Width Selection

Match SIMD width to hardware. Query at compile time:

```mojo
# GOOD: Query hardware capability
alias simd_width = simd_width_of[DType.float32]()

# GOOD: Common safe widths
alias SIMD_16 = 16  # Works everywhere (SSE, NEON)
alias SIMD_32 = 32  # AVX2
alias SIMD_64 = 64  # AVX-512

# WARNING: Don't use >2x hardware width
# If you declare SIMD[32] on 16-wide hardware,
# performance degrades significantly
```

**From Modular docs:** "You should avoid using a vector that's more than 2x the hardware's vector register size because the resulting code will perform poorly."

---

### 3. Use `vectorize()` for Automatic SIMD

Mojo's `vectorize` function handles bounds checking and remainder loops:

```mojo
from algorithm import vectorize

# GOOD: Automatic vectorization with safety
fn add_arrays[T: DType](a: Buffer[T], b: Buffer[T], out: Buffer[T], size: Int):
    @parameter
    fn add_impl[simd_width: Int](i: Int):
        out.store[width=simd_width](i, a.load[width=simd_width](i) + b.load[width=simd_width](i))

    vectorize[add_impl, simd_width_of[T]()](size)
```

**Benefits over manual SIMD:**
- Built-in bounds checking
- Automatic remainder handling
- Safer than explicit index calculations

---

### 4. Always Inline Hot Functions

```mojo
@always_inline
fn is_structural_char(c: UInt8) -> Bool:
    return c == 0x7B or c == 0x7D or c == 0x5B or c == 0x5D or c == 0x22

# In tight loop
while pos < n:
    if is_structural_char(byte_ptr[pos]):  # Inlined, no call overhead
        process_structural(pos)
    pos += 1
```

---

### 5. Memory Layout for Coalesced Access

When multiple threads/SIMD lanes access memory, ensure contiguous access:

```mojo
# GOOD: Threads access contiguous memory
# Thread 0 → data[0], Thread 1 → data[1], etc.
var idx = thread_idx.x
var value = data[idx]

# BAD: Strided access (cache thrashing)
# Thread 0 → data[0], Thread 1 → data[stride], etc.
var idx = thread_idx.x * stride
var value = data[idx]
```

**From GPU matmul tutorial:** "Adjacent threads access values in the same row, which are contiguous in memory."

---

### 6. GPU: Persistent Kernels & Work Scheduling

For GPU kernels, use software-controlled work distribution:

```mojo
# GOOD: Keep threads resident, feed work continuously
fn persistent_kernel():
    while True:
        var work_tile = get_next_work_tile()
        if work_tile.is_done():
            break
        process_tile(work_tile)
        barrier()

# BAD: Launch new kernel per work unit (high overhead)
for tile in tiles:
    launch_kernel(tile)  # Each launch has overhead
```

---

### 7. GPU: Tiling Strategy (Block → Warp → Thread)

Three-level tiling hierarchy for optimal cache usage:

```mojo
# Level 1: Block tiles (shared memory, ~48KB per block)
alias BM = 128  # Block rows
alias BN = 128  # Block cols
alias BK = 32   # K dimension

# Level 2: Warp tiles (register level)
alias WM = 64   # Warp rows
alias WN = 64   # Warp cols

# Level 3: Thread tiles
alias TM = 8    # Thread rows
alias TN = 8    # Thread cols
```

---

### 8. GPU: Async Memory Operations

Overlap computation with memory transfers:

```mojo
# GOOD: Pipeline memory and compute
copy_dram_to_sram_async(next_tile)  # Start loading
compute(current_tile)                # Work on current
async_copy_wait_all()               # Sync when needed
barrier()
swap(current_tile, next_tile)
```

---

### 9. Autotune for Hardware-Specific Optimization

Use Mojo's autotune to find optimal parameters:

```mojo
from autotune import autotune, search

# Define candidates
alias tile_sizes = (16, 32, 64, 128)

@autotune(tile_sizes)
fn matmul[tile_size: Int](...):
    # Implementation uses tile_size
    ...

# At compile time, autotune evaluates each candidate
# and selects the best for target hardware
```

**From Modular docs:** "The autotuning API forks compilation to evaluate each of the provided values."

---

### 10. Byte-Level String Access for UTF-8

**IMPORTANT (Mojo 0.25.7 Bug):** `ord(string[i])` returns incorrect values for UTF-8 continuation bytes. Use `unsafe_ptr()` for correct byte access:

```mojo
# GOOD: Direct byte access
var ptr = data.unsafe_ptr()
var byte = ptr[pos]  # Correct UTF-8 byte

# BAD: ord() on multi-byte UTF-8
var c = data[pos]
var byte = ord(c)  # May return garbage for continuation bytes!
```

---

## SOTA Results: Mojo on NVIDIA Blackwell (2025)

Modular achieved state-of-the-art performance on NVIDIA Blackwell GPUs:

| Metric | Result | Comparison |
|--------|--------|------------|
| Matmul performance | 1772 TFLOPs | Exceeds cuBLAS SOTA |
| Gemma 3 27B | +6% vs SOTA | Via autotuning |
| Platform | Unified CPU+GPU | Works on Apple, NVIDIA, AMD |

**Key optimizations used:**
- Persistent kernels with software work scheduling
- Three-level tiling (Block → Warp → Thread)
- Tensor Core utilization
- Async prefetching with pipeline staging

---

## References

- [simdjson paper](https://arxiv.org/abs/1902.08318) - "Parsing Gigabytes of JSON per Second"
- [orjson](https://github.com/ijl/orjson) - Fast Python JSON with Rust
- [Mojo GPU Optimization Tutorial](https://docs.modular.com/max/develop/custom-ops-matmul) - Modular official
- [Mojo Parameters & Metaprogramming](https://docs.modular.com/mojo/manual/parameters/) - Compile-time specialization
- [Blackwell SOTA Blog](https://www.modular.com/blog/matrix-multiplication-on-blackwell-part-4---breaking-sota) - 1772 TFLOPs achievement
- [Mojo GPU Basics](https://docs.modular.com/mojo/manual/gpu/basics/) - Thread management, memory patterns
- mojo-json benchmarks: `/mojo-contrib/serialization/mojo-json/benchmarks/`
