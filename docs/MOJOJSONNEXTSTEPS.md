# mojo-json Performance Optimization - Next Steps

## Current State (v0.4.1)

### Achieved Performance

| Parser | Throughput | Speedup | Use Case |
|--------|------------|---------|----------|
| `parse()` | 14 MB/s | 1x | Small JSON, full tree |
| `parse_fast()` | 19 MB/s | 1.4x | API compatibility |
| `parse_lazy()` | 448 MB/s | **32x** | Selective access |
| `parse_to_tape()` | 450 MB/s | **32x** | Direct tape access |

### Nested Access Performance

| Depth | Lazy | Eager | Speedup |
|-------|------|-------|---------|
| 5 levels | 0 µs | 43 µs | 66x |
| 10 levels | 0 µs | 129 µs | 142x |
| 20 levels | 1 µs | 434 µs | 311x |
| 50 levels | 3 µs | 2,569 µs | **800x** |

### Key Implementations

1. **LazyJsonValue with ArcPointer** (`src/tape_parser.mojo`)
   - Zero-copy nested access via shared tape reference
   - Subscript operators: `lazy["key"]` and `lazy[index]`
   - On-demand value extraction

2. **Two-Stage Tape Parser** (`src/tape_parser.mojo`)
   - Stage 1: SIMD structural character scanning
   - Stage 2: Tape building from structural index

3. **String Builder Pattern** (`src/parser.mojo`)
   - O(n) string construction vs O(n²) concatenation
   - Pre-sized collections for arrays

---

## Next Steps

### Phase 1: Quick Wins (1-2 days)

#### 1.1 SIMD String Key Matching
**File:** `src/tape_parser.mojo` - `get_object_value()`

Currently uses byte-by-byte string comparison. SIMD can compare 16-32 bytes at once.

```mojo
# Current: O(n) per character
if found_key == key:

# Optimized: O(n/16) with SIMD
fn simd_string_eq(a: String, b: String) -> Bool:
    if len(a) != len(b):
        return False
    var i = 0
    while i + 16 <= len(a):
        var chunk_a = load_simd[16](a, i)
        var chunk_b = load_simd[16](b, i)
        if (chunk_a != chunk_b).reduce_or():
            return False
        i += 16
    # Handle remainder
    ...
```

**Expected improvement:** 2-4x faster object key lookup

#### 1.2 Lazy Array Iterator
**File:** `src/tape_parser.mojo`

Add iterator that yields `LazyJsonValue` without allocating a List:

```mojo
struct LazyArrayIterator:
    var tape: ArcPointer[JsonTape]
    var pos: Int
    var end_idx: Int

    fn __next__(inout self) -> Optional[LazyJsonValue]:
        if self.pos >= self.end_idx:
            return None
        var result = LazyJsonValue(self.tape, self.pos)
        self.pos = self.tape[].skip_value(self.pos)
        return result

# Usage:
for item in lazy_array.iter():
    print(item.as_int())
```

**Expected improvement:** Zero allocation for array iteration

#### 1.3 Number Parsing Optimization
**File:** `src/tape_parser.mojo` - `_fast_parse_int()`

Current SIMD path handles 8 digits. Extend to 16 digits for larger numbers:

```mojo
# Current: 8-digit SIMD
if digit_count >= 8:
    var chunk = SIMD[DType.uint8, 8]()
    ...

# Optimized: 16-digit SIMD
if digit_count >= 16:
    var chunk = SIMD[DType.uint8, 16]()
    # Process all 16 digits in parallel
```

**Expected improvement:** 2x faster for large integers

---

### Phase 2: GPU Acceleration (3-5 days)

#### 2.1 GPU Structural Scanning
**Files:** New `src/gpu/` directory

Use Metal compute shaders for Stage 1 structural character detection:

```
┌─────────────────────────────────────────────────────────────┐
│  GPU Stage 1 (Massively Parallel)                           │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐                       │
│  │Thread│ │Thread│ │Thread│ │Thread│  1000s of threads     │
│  │  0   │ │  1   │ │  2   │ │  3   │  scanning chunks      │
│  └──────┘ └──────┘ └──────┘ └──────┘                       │
│           ↓ Structural positions bitmap                     │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│  CPU Stage 2 (Sequential)                                   │
│  Build tape using GPU-computed structural positions         │
└─────────────────────────────────────────────────────────────┘
```

**Metal kernel structure:**
```metal
kernel void structural_scan(
    device const char* json [[buffer(0)]],
    device uint32_t* positions [[buffer(1)]],
    device atomic_uint* count [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    char c = json[tid];
    bool is_structural = (c == '{') | (c == '}') |
                         (c == '[') | (c == ']') |
                         (c == ':') | (c == ',') | (c == '"');
    if (is_structural) {
        uint idx = atomic_fetch_add_explicit(count, 1, memory_order_relaxed);
        positions[idx] = tid;
    }
}
```

**Expected throughput:** 2,000-5,000 MB/s for files >100KB

#### 2.2 Adaptive Parser Selection
**File:** `src/__init__.mojo`

```mojo
fn parse_adaptive(json: String) raises -> LazyJsonValue:
    """Automatically select best parser based on input size."""
    var size = len(json)
    if size < 16 * 1024:        # < 16KB
        return parse_lazy(json)  # CPU is faster (no GPU overhead)
    elif size < 100 * 1024:     # 16KB - 100KB
        return parse_lazy(json)  # CPU SIMD
    else:                        # > 100KB
        return parse_gpu(json)   # GPU hybrid
```

#### 2.3 GPU-CPU Pipeline
**File:** `src/gpu/pipeline.mojo`

For streaming large files:

```mojo
struct GpuJsonPipeline:
    """Double-buffered GPU-CPU pipeline for streaming JSON."""
    var gpu_buffer_a: MetalBuffer
    var gpu_buffer_b: MetalBuffer
    var cpu_tape: JsonTape

    fn process_chunk(inout self, chunk: Span[UInt8]):
        # GPU: Scan chunk A while CPU processes chunk B
        self.gpu_scan_async(chunk, self.gpu_buffer_a)
        self.cpu_build_tape(self.gpu_buffer_b)
        # Swap buffers
        swap(self.gpu_buffer_a, self.gpu_buffer_b)
```

---

### Phase 3: Advanced Optimizations (1-2 weeks)

#### 3.1 On-Demand String Unescaping
**File:** `src/tape_parser.mojo`

Currently strings are unescaped during tape building. Defer to access time:

```mojo
struct LazyString:
    """String that unescapes only when converted to String."""
    var tape: ArcPointer[JsonTape]
    var offset: Int
    var needs_unescape: Bool  # Set during scanning if \ found

    fn to_string(self) -> String:
        if not self.needs_unescape:
            return self.tape[].get_string_raw(self.offset)  # Zero-copy!
        return self.tape[].get_string_unescaped(self.offset)
```

**Expected improvement:** 10-20% faster for JSON with few escaped strings

#### 3.2 Parallel Tape Building
**File:** `src/tape_parser.mojo`

For very large arrays/objects, build tape segments in parallel:

```mojo
fn build_tape_parallel(index: StructuralIndex) -> JsonTape:
    # Split structural index into chunks
    var chunks = split_at_top_level(index)

    # Build tape segments in parallel
    var segments = parallel_map(chunks, build_tape_segment)

    # Merge segments
    return merge_tape_segments(segments)
```

#### 3.3 Memory-Mapped Parsing
**File:** `src/mmap_parser.mojo`

For files larger than RAM:

```mojo
fn parse_mmap(path: String) raises -> LazyJsonValue:
    """Parse JSON file using memory mapping."""
    var mapping = mmap(path, read_only=True)
    var tape = parse_to_tape_from_bytes(mapping.data())
    return LazyJsonValue(tape, 1)
```

---

## Performance Targets

| Phase | Target | Technique |
|-------|--------|-----------|
| Current | 450 MB/s | Tape parser + lazy access |
| Phase 1 | 600 MB/s | SIMD key matching, lazy iteration |
| Phase 2 | 2,000 MB/s | GPU structural scanning |
| Phase 3 | 3,000+ MB/s | Parallel tape + on-demand unescape |

### Comparison with Other Libraries

| Library | Language | Throughput | Notes |
|---------|----------|------------|-------|
| simdjson | C++ | 2,500-5,000 MB/s | Best-in-class |
| orjson | Rust | 700-900 MB/s | Python binding |
| sonic | Go | 400-600 MB/s | JIT-based |
| **mojo-json** | **Mojo** | **450 MB/s** | **Current** |
| **mojo-json** | **Mojo** | **2,000+ MB/s** | **Target (GPU)** |

---

## File Structure

```
mojo-json/
├── src/
│   ├── __init__.mojo          # Public API
│   ├── parser.mojo            # Recursive descent parser
│   ├── tape_parser.mojo       # Tape-based parser + LazyJsonValue
│   ├── structural_index.mojo  # SIMD structural scanning
│   ├── value.mojo             # JsonValue type
│   ├── serializer.mojo        # JSON serialization
│   └── gpu/                   # [NEW] GPU acceleration
│       ├── metal_scanner.mojo # Metal compute shaders
│       ├── pipeline.mojo      # GPU-CPU pipeline
│       └── adaptive.mojo      # Automatic parser selection
├── benchmarks/
│   ├── bench_lazy.mojo        # Parser comparison
│   ├── bench_nested_access.mojo # Nested access benchmark
│   └── data/                  # Test JSON files
└── docs/
    └── PARSER_PERFORMANCE_INVESTIGATION.md
```

---

## Getting Started

```mojo
from mojo_json import parse_lazy, LazyJsonValue

# Fast parsing (450 MB/s)
var lazy = parse_lazy(huge_json)

# Zero-copy nested access (800x faster than eager)
var name = lazy["users"][0]["profile"]["name"].as_string()

# Convert to JsonValue only when needed
var user = lazy["users"][0].to_json_value()
```

---

## Additional Optimization Ideas

### Speculative Parsing
Pre-parse common JSON patterns (ISO dates, UUIDs, URLs) during structural scan:

```mojo
struct SpeculativeHints:
    var date_positions: List[Int]      # ISO 8601 date strings
    var uuid_positions: List[Int]      # UUID strings
    var numeric_strings: List[Int]     # Strings containing only digits
```

### Schema-Aware Parsing
For known JSON schemas, generate optimized parsers:

```mojo
@json_schema
struct User:
    var name: String
    var age: Int
    var email: String

# Generates optimized parser that knows field positions
var user = parse_typed[User](json)  # Skips unknown fields efficiently
```

### Vectorized UTF-8 Validation
Validate UTF-8 encoding using SIMD during structural scan:

```mojo
fn validate_utf8_simd(chunk: SIMD[DType.uint8, 16]) -> Bool:
    # Check for invalid UTF-8 sequences in parallel
    var high_bits = chunk & 0x80
    var continuation = (chunk & 0xC0) == 0x80
    # ... vectorized validation
```

### Branch-Free Number Classification
Determine number type (int vs float) without branches:

```mojo
fn classify_number(chunk: SIMD[DType.uint8, 16]) -> NumberType:
    var has_dot = (chunk == ord('.')).reduce_or()
    var has_e = ((chunk == ord('e')) | (chunk == ord('E'))).reduce_or()
    # Branch-free: FLOAT if has_dot or has_e, else INT
    return NumberType(Int(has_dot) | Int(has_e))
```

### Tape Compression
For repeated strings (common in arrays of objects), store string once:

```mojo
struct CompressedTape:
    var entries: List[TapeEntry]
    var string_table: Dict[String, Int]  # Deduplicated strings
    var string_refs: List[Int]           # References to string_table
```

### Streaming Parser
Parse JSON as it arrives (network streams, large files):

```mojo
struct StreamingParser:
    var partial_tape: JsonTape
    var state: ParserState
    var buffer: List[UInt8]

    fn feed(inout self, chunk: Span[UInt8]) -> List[JsonEvent]:
        """Process chunk, emit events for complete values."""
        # Returns: ObjectStart, Key, Value, ObjectEnd, etc.
```

### JIT-Compiled Accessors
For hot paths, JIT-compile accessor chains:

```mojo
# Instead of: lazy["users"][0]["name"].as_string()
# Generate optimized accessor:
var get_first_user_name = compile_accessor("users.0.name")
var name = get_first_user_name(lazy)  # Single optimized call
```

### SIMD JSON Pointer
Implement RFC 6901 JSON Pointer with SIMD:

```mojo
fn get_pointer(lazy: LazyJsonValue, pointer: String) -> LazyJsonValue:
    """Get value at JSON Pointer path: /users/0/name"""
    # SIMD-accelerated path parsing and traversal
```

### Prefetch Optimization
For predictable access patterns, prefetch tape entries:

```mojo
fn prefetch_children(lazy: LazyJsonValue):
    """Prefetch tape entries for all direct children."""
    var end_idx = lazy._tape[].get_entry(lazy._idx).payload()
    for pos in range(lazy._idx, min(lazy._idx + 64, end_idx)):
        prefetch(lazy._tape[].entries.data() + pos)
```

---

## Benchmark Suite Expansion

### Add Benchmarks For:

1. **Real-world JSON samples:**
   - GitHub API responses
   - AWS CloudWatch logs
   - Kubernetes manifests
   - GeoJSON (heavy coordinates)

2. **Edge cases:**
   - Deeply nested (100+ levels)
   - Wide objects (10,000+ keys)
   - Long strings (1MB+ values)
   - Unicode-heavy content

3. **Comparative benchmarks:**
   - vs Python json
   - vs orjson (via Python)
   - vs simdjson (via C FFI)

---

## References

- [simdjson paper](https://arxiv.org/abs/1902.08318) - Parsing Gigabytes of JSON per Second
- [mojo-json optimization plan](./MOJO_JSON_OPTIMIZATION_PLAN.md)
- [GPU acceleration analysis](./GPU_ACCELERATION_ANALYSIS.md)
- [Performance best practices](./PERFORMANCE_BEST_PRACTICES.md)
