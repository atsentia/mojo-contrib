# mojo-json Complete Optimization Plan

**Goal**: Achieve 1,000+ MB/s JSON parsing throughput (matching orjson, approaching simdjson)

**Current State**: 12 MB/s | **Target**: 1,000+ MB/s | **Stretch**: 2,500+ MB/s with GPU

---

## Executive Summary

Based on deep analysis of simdjson (C++), orjson (Rust), and mojo-metal (GPU), this plan outlines a three-phase optimization strategy:

| Phase | Target | Key Technique | Timeline |
|-------|--------|---------------|----------|
| Phase 1 | 100 MB/s | Two-stage SIMD parsing | Week 1-2 |
| Phase 2 | 500 MB/s | Tape data structure (mojo-tape) | Week 3-4 |
| Phase 3 | 2,000 MB/s | GPU acceleration (mojo-metal) | Week 5-6 |

---

## Research Findings

### simdjson Architecture (2,500-5,000 MB/s)

**Key insight**: Two-stage architecture with structural index

```
Stage 1: Structural Discovery (SIMD parallel)
├── Process 64 bytes per iteration
├── Character classification via lookup tables
├── Build bitmasks: quotes, operators, whitespace
├── Output: structural_indexes[] array
└── Speed: 3-5 GB/s (memory bandwidth limited)

Stage 2: Value Extraction (sequential)
├── Walk structural indexes
├── Extract values at marked positions
├── Build tape (flat array of type+offset pairs)
└── Speed: 1-2 GB/s
```

**Critical simdjson files studied**:
- `src/arm64.cpp` - NEON character classification (lines 40-92)
- `src/generic/stage1/json_structural_indexer.h` - Bit indexing (lines 24-125)
- `src/generic/stage1/json_escape_scanner.h` - Escape handling (lines 44-142)
- `include/simdjson/internal/tape_type.h` - Tape format

**Tape format** (64-bit entries):
```
[8-bit type tag | 56-bit payload]

Types: ROOT='r', START_ARRAY='[', END_ARRAY=']', START_OBJECT='{',
       END_OBJECT='}', STRING='"', INT64='l', DOUBLE='d', TRUE='t',
       FALSE='f', NULL='n'
```

### orjson Techniques (718 MB/s)

**Key insight**: Pragmatic optimizations over architectural complexity

1. **yyjson backend** - Fast C library for core parsing
2. **Feature flags** - `OPT_PASSTHROUGH_DATACLASS`, `OPT_SERIALIZE_NUMPY`
3. **Type-aware serialization** - Special paths for datetime, UUID, numpy
4. **Minimal allocations** - Reuse buffers, avoid intermediate objects

**Why orjson is 3-4x slower than simdjson**:
- No two-stage architecture
- No structural indexing
- Sequential UTF-8 validation
- Standard float parsing (not Lemire's algorithm)

### mojo-metal GPU Patterns

**Key insight**: Apple Silicon unified memory enables GPU at 100KB (not 1MB+)

**Architecture studied**:
- `/Users/amund/mojo-contrib-experimental/mojo-metal/src/device/metal_device.mojo`
- `/Users/amund/mojo-contrib-experimental/mojo-metal/src/kernels/`
- `/Users/amund/mojo-contrib-experimental/mojo-metal/src/simd/vectorize.mojo`

**GPU crossover points** (Apple M3 Ultra):
| File Size | CPU SIMD | GPU Hybrid | Winner |
|-----------|----------|------------|--------|
| 10 KB | 10 μs | 28 μs | CPU |
| 100 KB | 100 μs | 50 μs | **GPU** |
| 1 MB | 1000 μs | 200 μs | **GPU 5x** |
| 10 MB | 10000 μs | 1500 μs | **GPU 7x** |

---

## Phase 1: Two-Stage SIMD Parsing (Target: 100 MB/s)

### 1.1 Structural Index Builder

**File**: `src/parser.mojo` (new function)

```mojo
struct StructuralIndex:
    """Positions of all structural characters in JSON."""
    var positions: List[Int]
    var characters: List[UInt8]
    var count: Int

fn build_structural_index(data: String) -> StructuralIndex:
    """SIMD scan to find all structural positions.

    Processes 16 bytes per iteration using NEON-style operations.
    """
    var index = StructuralIndex()
    var pos = 0
    var n = len(data)

    while pos + 16 <= n:
        # Load 16 bytes
        var chunk = load_simd_chunk(data, pos)

        # Character classification (two-nibble lookup, ARM-friendly)
        var structural_mask = classify_structural(chunk)
        var quote_mask = classify_quotes(chunk)

        # Extract positions where mask bits are set
        var combined = structural_mask | quote_mask
        var bit_count = combined.reduce_add()

        if bit_count > 0:
            @parameter
            for i in range(16):
                if combined[i] == 1:
                    index.positions.append(pos + i)
                    index.characters.append(chunk[i])
                    index.count += 1

        pos += 16

    # Scalar tail
    while pos < n:
        var c = ord(data[pos])
        if is_structural_char(c):
            index.positions.append(pos)
            index.characters.append(UInt8(c))
            index.count += 1
        pos += 1

    return index^
```

### 1.2 Two-Nibble Character Classification

**Pattern from simdjson ARM64** (replaces PSHUFB):

```mojo
alias SIMD_WIDTH = 16

# Lookup tables for character classification
# Each byte split into nibbles, each nibble indexes 16-entry table
alias TABLE1 = SIMD[DType.uint8, 16](16, 0, 0, 0, 0, 0, 0, 0, 0, 8, 12, 1, 2, 9, 0, 0)
alias TABLE2 = SIMD[DType.uint8, 16](8, 0, 18, 4, 0, 1, 0, 1, 0, 0, 0, 3, 2, 1, 0, 0)

@always_inline
fn classify_structural(chunk: SIMD[DType.uint8, 16]) -> SIMD[DType.uint8, 16]:
    """Classify bytes as structural operators using two-nibble lookup."""
    var low_nibble = chunk & 0x0F
    var high_nibble = chunk >> 4

    # Lookup in both tables
    var result1 = lookup_16(low_nibble, TABLE1)
    var result2 = lookup_16(high_nibble, TABLE2)

    # AND results: both must indicate structural
    return result1 & result2

@always_inline
fn lookup_16(indices: SIMD[DType.uint8, 16], table: SIMD[DType.uint8, 16]) -> SIMD[DType.uint8, 16]:
    """16-entry table lookup (NEON vqtbl1q equivalent)."""
    var result = SIMD[DType.uint8, 16]()
    @parameter
    for i in range(16):
        var idx = Int(indices[i]) & 0x0F
        result[i] = table[idx]
    return result
```

### 1.3 Index-Based Value Extraction

```mojo
fn parse_with_index(data: String, index: StructuralIndex) raises -> JsonValue:
    """Parse JSON using pre-computed structural index.

    No character-by-character scanning - jump directly to positions.
    """
    var idx_pos = 0

    fn next_structural() -> Tuple[Int, UInt8]:
        if idx_pos < index.count:
            var pos = index.positions[idx_pos]
            var char = index.characters[idx_pos]
            idx_pos += 1
            return (pos, char)
        return (-1, UInt8(0))

    # Parse using structural positions
    return parse_value_indexed(data, next_structural)
```

### 1.4 Escape Sequence Handling

**simdjson algorithm** (alternating bit pattern detection):

```mojo
alias ODD_BITS: UInt64 = 0xAAAAAAAAAAAAAAAA

fn find_escaped_chars(backslash_mask: UInt64) -> UInt64:
    """Identify which characters are escaped using parity detection.

    Example: \\\\n (4 backslashes + n)
    - Backslashes at positions 0,1,2,3
    - n at position 4 is NOT escaped (even number of backslashes)
    """
    var potential_escape = backslash_mask
    var maybe_escaped = potential_escape << 1
    var maybe_escaped_and_odd = maybe_escaped | ODD_BITS
    var even_series = maybe_escaped_and_odd - potential_escape
    return even_series ^ ODD_BITS
```

### 1.5 Fast Float Parsing (Lemire's Algorithm)

```mojo
fn parse_float_fast(data: String, start: Int, end: Int) -> Float64:
    """Fast float parsing using integer operations.

    Avoids slow atof() by building mantissa/exponent directly.
    """
    var mantissa: Int64 = 0
    var exponent: Int = 0
    var negative = False
    var pos = start

    # Sign
    if data[pos] == '-':
        negative = True
        pos += 1

    # Integer part (SIMD digit accumulation)
    while pos < end and is_digit(data[pos]):
        mantissa = mantissa * 10 + (ord(data[pos]) - ord('0'))
        pos += 1

    # Fractional part
    if pos < end and data[pos] == '.':
        pos += 1
        while pos < end and is_digit(data[pos]):
            mantissa = mantissa * 10 + (ord(data[pos]) - ord('0'))
            exponent -= 1
            pos += 1

    # Exponent part
    if pos < end and (data[pos] == 'e' or data[pos] == 'E'):
        pos += 1
        var exp_sign = 1
        if data[pos] == '-':
            exp_sign = -1
            pos += 1
        elif data[pos] == '+':
            pos += 1

        var exp_val = 0
        while pos < end and is_digit(data[pos]):
            exp_val = exp_val * 10 + (ord(data[pos]) - ord('0'))
            pos += 1
        exponent += exp_sign * exp_val

    # Combine mantissa and exponent
    var result = Float64(mantissa) * pow10(exponent)
    return -result if negative else result
```

---

## Phase 2: Tape Data Structure (Target: 500 MB/s)

### 2.1 mojo-tape Library

**New library**: `/Users/amund/mojo-contrib/data-structures/mojo-tape/`

```mojo
"""Flat tape data structure for high-performance parsing.

Eliminates Dict/List allocations by storing all data in contiguous memory.
Works efficiently on both CPU and GPU (unified memory on Apple Silicon).
"""

alias TAPE_ROOT: UInt8 = ord('r')
alias TAPE_START_ARRAY: UInt8 = ord('[')
alias TAPE_END_ARRAY: UInt8 = ord(']')
alias TAPE_START_OBJECT: UInt8 = ord('{')
alias TAPE_END_OBJECT: UInt8 = ord('}')
alias TAPE_STRING: UInt8 = ord('"')
alias TAPE_INT64: UInt8 = ord('l')
alias TAPE_DOUBLE: UInt8 = ord('d')
alias TAPE_TRUE: UInt8 = ord('t')
alias TAPE_FALSE: UInt8 = ord('f')
alias TAPE_NULL: UInt8 = ord('n')

struct TapeEntry:
    """64-bit tape entry: 8-bit type + 56-bit payload."""
    var data: UInt64

    @always_inline
    fn type_tag(self) -> UInt8:
        return UInt8(self.data >> 56)

    @always_inline
    fn payload(self) -> Int:
        return Int(self.data & 0x00FFFFFFFFFFFFFF)

    @staticmethod
    fn create(type_tag: UInt8, payload: Int) -> Self:
        return TapeEntry(UInt64(payload) | (UInt64(type_tag) << 56))

struct Tape:
    """Flat array of tape entries representing parsed JSON."""
    var entries: List[TapeEntry]
    var string_buffer: List[UInt8]  # All strings concatenated
    var current_pos: Int

    fn __init__(out self, capacity: Int = 1024):
        self.entries = List[TapeEntry](capacity=capacity)
        self.string_buffer = List[UInt8](capacity=capacity * 8)
        self.current_pos = 0

    @always_inline
    fn append(mut self, type_tag: UInt8, payload: Int):
        self.entries.append(TapeEntry.create(type_tag, payload))

    @always_inline
    fn append_string(mut self, s: String) -> Int:
        """Append string to buffer, return offset."""
        var offset = len(self.string_buffer)
        for i in range(len(s)):
            self.string_buffer.append(ord(s[i]))
        self.string_buffer.append(0)  # Null terminator
        return offset

    fn get_string(self, offset: Int) -> String:
        """Get string at offset from buffer."""
        var end = offset
        while self.string_buffer[end] != 0:
            end += 1
        var result = String("")
        for i in range(offset, end):
            result += chr(Int(self.string_buffer[i]))
        return result
```

### 2.2 Tape-Based Parser

```mojo
fn parse_to_tape(data: String) raises -> Tape:
    """Parse JSON directly to tape format.

    No intermediate JsonValue objects - 10x less allocation.
    """
    var index = build_structural_index(data)
    var tape = Tape(capacity=index.count * 2)

    tape.append(TAPE_ROOT, 0)  # Root marker

    var idx = 0
    while idx < index.count:
        var pos = index.positions[idx]
        var c = index.characters[idx]

        if c == ord('{'):
            tape.append(TAPE_START_OBJECT, 0)
        elif c == ord('}'):
            tape.append(TAPE_END_OBJECT, 0)
        elif c == ord('['):
            tape.append(TAPE_START_ARRAY, 0)
        elif c == ord(']'):
            tape.append(TAPE_END_ARRAY, 0)
        elif c == ord('"'):
            # Extract string
            var end_pos = find_string_end(data, pos + 1)
            var str_offset = tape.append_string(data[pos+1:end_pos])
            tape.append(TAPE_STRING, str_offset)
        # ... handle other types

        idx += 1

    return tape^
```

### 2.3 Lazy Value Access

```mojo
struct LazyJsonValue:
    """On-demand value extraction from tape.

    Only parses when accessed - O(1) random access.
    """
    var tape: Pointer[Tape]
    var entry_index: Int

    fn as_string(self) -> String:
        var entry = self.tape[].entries[self.entry_index]
        if entry.type_tag() == TAPE_STRING:
            return self.tape[].get_string(entry.payload())
        return ""

    fn as_int(self) -> Int64:
        var entry = self.tape[].entries[self.entry_index]
        if entry.type_tag() == TAPE_INT64:
            # Next entry contains actual value
            var next = self.tape[].entries[self.entry_index + 1]
            return Int64(next.data)
        return 0

    fn __getitem__(self, key: String) -> LazyJsonValue:
        """O(n) key lookup in object - could be optimized with hash table."""
        # Walk object entries to find key
        ...

    fn __getitem__(self, index: Int) -> LazyJsonValue:
        """O(1) array access."""
        # Jump to index-th element in array
        ...
```

---

## Phase 3: GPU Acceleration (Target: 2,000 MB/s)

### 3.1 Adaptive Strategy Selection

```mojo
enum ParseStrategy:
    CPU_SCALAR = 0      # < 1 KB
    CPU_SIMD = 1        # 1 KB - 100 KB
    GPU_HYBRID = 2      # > 100 KB

struct AdaptiveParser:
    var device: MetalDevice
    var cpu_parser: SIMDParser

    fn parse(self, data: String) raises -> Tape:
        var size = len(data)

        if size < 1024:
            return self.cpu_parser.parse_scalar(data)
        elif size < 100 * 1024:
            return self.cpu_parser.parse_simd(data)
        else:
            return self.parse_gpu_hybrid(data)

    fn parse_gpu_hybrid(self, data: String) raises -> Tape:
        """GPU Stage 1 + CPU Stage 2."""

        # Stage 1: GPU structural discovery
        var structural_mask = self.gpu_structural_scan(data)

        # Stage 2: CPU value extraction using mask
        return self.cpu_extract_values(data, structural_mask)
```

### 3.2 GPU Structural Scan Kernel

```mojo
# Metal kernel for parallel structural character detection
fn structural_scan_kernel(
    input: DeviceBuffer[DType.uint8],
    output: DeviceBuffer[DType.uint8],  # Bitmask output
    size: Int,
):
    """Each thread processes 4 bytes, marks structural chars."""
    var tid = block_idx.x * block_dim.x + thread_idx.x
    var byte_offset = tid * 4

    if byte_offset >= size:
        return

    # Load 4 bytes as uint32
    var word = input.load[DType.uint32](byte_offset)

    # Extract and classify each byte
    var b0 = (word >> 0) & 0xFF
    var b1 = (word >> 8) & 0xFF
    var b2 = (word >> 16) & 0xFF
    var b3 = (word >> 24) & 0xFF

    # Check structural: { } [ ] " : ,
    var m0 = is_structural_gpu(b0)
    var m1 = is_structural_gpu(b1)
    var m2 = is_structural_gpu(b2)
    var m3 = is_structural_gpu(b3)

    # Pack into output byte (4 bits used)
    var result = (m0 << 0) | (m1 << 1) | (m2 << 2) | (m3 << 3)
    output.store(tid, result)

@always_inline
fn is_structural_gpu(c: UInt32) -> UInt32:
    """GPU-friendly structural check (no branching)."""
    var is_quote = (c == 0x22)
    var is_brace = (c == 0x7B) | (c == 0x7D)
    var is_bracket = (c == 0x5B) | (c == 0x5D)
    var is_colon = (c == 0x3A)
    var is_comma = (c == 0x2C)
    return is_quote | is_brace | is_bracket | is_colon | is_comma
```

### 3.3 Unified Memory Integration

```mojo
fn gpu_structural_scan(self, data: String) -> DeviceBuffer[DType.uint8]:
    """Launch GPU kernel for structural scanning."""

    # Allocate in unified memory (no explicit copy needed)
    var input_buf = self.device.allocate_unified(len(data))
    var output_buf = self.device.allocate_unified((len(data) + 3) // 4)

    # Copy input (fast on unified memory: ~1 μs/KB)
    input_buf.copy_from(data.as_bytes())

    # Calculate grid dimensions
    var threads_per_block = 256
    var num_blocks = (len(data) // 4 + threads_per_block - 1) // threads_per_block

    # Launch kernel
    self.device.launch_kernel[structural_scan_kernel](
        input_buf, output_buf, len(data),
        grid_dim=num_blocks,
        block_dim=threads_per_block,
    )

    # Synchronize (wait for GPU completion)
    self.device.synchronize()

    return output_buf
```

---

## Implementation Roadmap

### Week 1-2: Phase 1 (Two-Stage SIMD)

| Day | Task | Files | Target |
|-----|------|-------|--------|
| 1 | Implement structural index builder | `parser.mojo` | Compiles |
| 2 | Two-nibble character classification | `parser.mojo` | 500 MB/s scan |
| 3 | Index-based value extraction | `parser.mojo` | 50 MB/s parse |
| 4 | Escape sequence handling | `parser.mojo` | Passes tests |
| 5 | Fast float parsing (Lemire) | `parser.mojo` | 10x atof speed |
| 6-7 | Integration + benchmarks | `benchmarks/` | 100 MB/s |

### Week 3-4: Phase 2 (mojo-tape)

| Day | Task | Files | Target |
|-----|------|-------|--------|
| 8 | Create mojo-tape library skeleton | `mojo-tape/` | Compiles |
| 9 | Implement TapeEntry and Tape | `mojo-tape/src/` | Unit tests pass |
| 10 | Tape-based parser | `mojo-json/` | 200 MB/s |
| 11 | Lazy value access API | `mojo-tape/src/` | O(1) access |
| 12 | String buffer optimization | `mojo-tape/src/` | Zero-copy strings |
| 13-14 | Integration + benchmarks | `benchmarks/` | 500 MB/s |

### Week 5-6: Phase 3 (GPU Acceleration)

| Day | Task | Files | Target |
|-----|------|-------|--------|
| 15 | Adaptive strategy selection | `parser.mojo` | Routing works |
| 16 | GPU structural scan kernel | `mojo-metal/` | Kernel compiles |
| 17 | Unified memory integration | `mojo-metal/` | No-copy transfer |
| 18 | CPU-GPU handoff | `parser.mojo` | End-to-end works |
| 19 | Crossover tuning | `benchmarks/` | Optimal thresholds |
| 20-21 | Full integration + polish | All | 2,000 MB/s |

---

## Success Metrics

| Metric | Current | Phase 1 | Phase 2 | Phase 3 |
|--------|---------|---------|---------|---------|
| Throughput | 12 MB/s | 100 MB/s | 500 MB/s | 2,000 MB/s |
| vs Python json | 0.04x | 0.33x | 1.6x | 6.5x |
| vs orjson | 0.02x | 0.14x | 0.7x | 2.8x |
| vs simdjson | 0.003x | 0.03x | 0.14x | 0.57x |
| Memory (1MB file) | 10 MB | 5 MB | 2 MB | 2 MB |
| Latency (1KB) | 80 μs | 10 μs | 5 μs | 5 μs |

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Mojo SIMD limitations | Use element-wise `@parameter for` loops as fallback |
| GPU kernel complexity | Start with CPU-only tape, add GPU later |
| Unicode edge cases | Port simdjson UTF-8 validation algorithm |
| API breaking changes | Provide both old (JsonValue) and new (Tape) APIs |

---

## Dependencies

### New Libraries to Create

1. **mojo-tape** (`/Users/amund/mojo-contrib/data-structures/mojo-tape/`)
   - Flat tape data structure
   - Lazy value access API
   - CPU/GPU compatible (unified memory)

2. **mojo-simd-utils** (optional, in mojo-tape or separate)
   - Lookup table operations
   - Bitmask extraction
   - Leading/trailing zero count

### Existing Libraries to Leverage

- **mojo-metal** - GPU device abstraction, kernel launching
- **mojo-json** - Existing parser (to be optimized)

---

## References

- [simdjson paper](https://arxiv.org/abs/1902.08318) - "Parsing Gigabytes of JSON per Second"
- [simdjson source](https://github.com/simdjson/simdjson) - Studied: `src/arm64.cpp`, `stage1/`, `stage2/`
- [orjson](https://github.com/ijl/orjson) - Rust/yyjson patterns
- [Lemire's fast float parsing](https://lemire.me/blog/2021/01/29/number-parsing-at-a-gigabyte-per-second/)
- mojo-metal: `/Users/amund/mojo-contrib-experimental/mojo-metal/`
- mojo-json benchmarks: `/Users/amund/mojo-contrib/serialization/mojo-json/benchmarks/`
