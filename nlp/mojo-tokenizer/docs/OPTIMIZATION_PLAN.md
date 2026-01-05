# mojo-tokenizer Optimization Plan

Adapting mojo-json's 6.5 GB/s optimization techniques to build the world's fastest tokenizer.

## Executive Summary

mojo-json achieved 52% faster performance than simdjson (C++) through systematic application of 13 optimization techniques. This document outlines how to adapt these techniques for mojo-tokenizer to potentially outperform the current fastest tokenizers (rs-bpe, GitHub's bpe crate) which achieve 3-6x speedups over tiktoken.

**Target**: 10M+ tokens/sec (10x current ~100k tokens/sec)

---

## Part 1: Competitor Analysis

### Current Tokenizer Landscape (2024-2025)

| Library | Language | Performance | Notes |
|---------|----------|-------------|-------|
| **rs-bpe** | Rust | 6M tokens/sec | Fastest as of March 2025, 3x tiktoken |
| **GitHub bpe** | Rust | 4x tiktoken | Open source `bpe` and `bpe-openai` crates |
| **kitoken** | Rust | 2-3x tiktoken | Compatible with SentencePiece, Tiktoken, Tekken |
| **tiktoken** | Rust+Python | 2M tokens/sec | OpenAI's official tokenizer |
| **HuggingFace tokenizers** | Rust+Python | 1GB/20sec training | Industry standard, <1M tokens/sec |
| **sentencepiece** | C++ | ~500k tokens/sec | Google's original implementation |

### Why Rust Tokenizers Are Fast

1. **Aho-Corasick for special tokens** - O(n) multi-pattern matching
2. **Hash-based merge lookup** - O(1) instead of O(vocab) for pair lookups
3. **Byte-level preprocessing** - Avoid UTF-8 decoding overhead
4. **Batch parallelism** - Process multiple texts concurrently

### Opportunity for Mojo

Mojo combines:
- **Python syntax** with **C++ performance**
- **Native SIMD** without FFI overhead (unlike Rust+Python)
- **Zero-copy semantics** with ownership model
- **GPU compilation** for future batch acceleration

If mojo-json can beat simdjson, mojo-tokenizer can beat rs-bpe.

---

## Part 2: mojo-json Optimization Techniques

### Techniques Applicable to Tokenization

| Technique | mojo-json Speedup | Tokenizer Application | Priority |
|-----------|-------------------|----------------------|----------|
| NEON SIMD FFI | 3-4x | Character classification, boundary detection | P0 |
| Two-stage architecture | 2-3x | Stage 1: find boundaries, Stage 2: extract tokens | P0 |
| Branchless lookup tables | 1.2x | ASCII classification (alpha/digit/punct/space) | P0 |
| Prefix-XOR string tracking | 64x | Skip quoted regions in source code | P1 |
| Wide SIMD (32-byte) | 1.3x | Process more characters per cycle | P1 |
| Zero-copy StringSlice | 13.6x | Return token references, not copies | P0 |
| SWAR number parsing | 4x | Parse numeric literals 8 digits at once | P2 |
| Fast-path chunk skipping | 1.2-1.3x | Skip chunks with no delimiters | P1 |
| Prefetch hints | 1.1x | Pre-load vocabulary entries | P2 |
| Adaptive algorithm selection | 1-1.2x | Different strategies for different text types | P2 |
| Parallelism | Nx threads | Multi-text batch processing | P1 |

### Detailed Technique Adaptations

#### 1. Two-Stage Architecture (P0)

**mojo-json approach**:
- Stage 1: SIMD scan for structural characters `{}[]":,`
- Stage 2: Build tape from pre-indexed positions

**Tokenizer adaptation**:
```
Stage 1: SIMD Boundary Detection
├── Find all whitespace positions (word boundaries)
├── Find all punctuation positions (subword boundaries)
├── Find special token markers (<|, |>, [, ])
└── Output: List[(position, boundary_type)]

Stage 2: Token Extraction
├── Jump to boundary positions (O(1) access)
├── Extract token spans (zero-copy)
├── Apply BPE merges on extracted spans
└── Output: List[token_id]
```

**Expected speedup**: 2-3x by eliminating re-scanning

#### 2. NEON SIMD for Character Classification (P0)

**mojo-json approach**:
- 64-byte chunks via ARM NEON intrinsics
- Parallel comparison of 16 characters
- Branchless mask generation

**Tokenizer adaptation**:
```mojo
# Classify 16 characters simultaneously
fn classify_chunk_simd(chunk: SIMD[DType.uint8, 16]) -> SIMD[DType.uint8, 16]:
    # Check ranges in parallel
    var is_alpha_lower = (chunk >= ord('a')) & (chunk <= ord('z'))
    var is_alpha_upper = (chunk >= ord('A')) & (chunk <= ord('Z'))
    var is_digit = (chunk >= ord('0')) & (chunk <= ord('9'))
    var is_space = (chunk == ord(' ')) | (chunk == ord('\t')) | (chunk == ord('\n'))

    # Combine into classification mask
    var alpha_mask = is_alpha_lower | is_alpha_upper
    var alnum_mask = alpha_mask | is_digit

    return alnum_mask  # 0xFF = alphanumeric, 0x00 = boundary
```

**Current bottleneck** (bpe.mojo lines 240-268):
```mojo
# Character-by-character - SLOW
for i in range(len(text)):
    var c = text[i]
    if c >= 'a' and c <= 'z' or c >= 'A' and c <= 'Z':
        # ... alphanumeric
    else:
        # ... boundary
```

**Expected speedup**: 5-10x for boundary detection

#### 3. Zero-Copy Token Slices (P0)

**mojo-json approach**:
- `StringSlice` struct: (source_ref, start, length)
- No allocation until `to_string()` called
- NDJSON extraction: 13.6x faster than copying

**Tokenizer adaptation**:
```mojo
struct TokenSpan:
    var source: String      # Reference to input text
    var start: Int          # Start position
    var length: Int         # Token length
    var token_id: Int       # Vocabulary ID (computed lazily)

    fn text(self) -> StringSlice:
        """Zero-copy access to token text."""
        return StringSlice(self.source, self.start, self.length)

    fn __eq__(self, vocab_entry: String) -> Bool:
        """Compare without copying."""
        if self.length != len(vocab_entry):
            return False
        for i in range(self.length):
            if self.source[self.start + i] != vocab_entry[i]:
                return False
        return True
```

**Expected speedup**: 5-10x for token extraction, 2x memory reduction

#### 4. Branchless Lookup Table (P0)

**mojo-json approach**:
- 256-byte table for ASCII classification
- Single memory access + bitwise AND
- L1 cache hit rate >99%

**Tokenizer adaptation**:
```mojo
# Classification bits
alias CHAR_ALPHA: UInt8 = 1      # a-z, A-Z
alias CHAR_DIGIT: UInt8 = 2      # 0-9
alias CHAR_SPACE: UInt8 = 4      # space, tab, newline
alias CHAR_PUNCT: UInt8 = 8      # punctuation
alias CHAR_SPECIAL: UInt8 = 16   # <, >, |, [, ]

fn build_char_table() -> InlineArray[UInt8, 256]:
    var table = InlineArray[UInt8, 256](fill=0)
    # Lowercase letters
    for c in range(ord('a'), ord('z') + 1):
        table[c] = CHAR_ALPHA
    # Uppercase letters
    for c in range(ord('A'), ord('Z') + 1):
        table[c] = CHAR_ALPHA
    # Digits
    for c in range(ord('0'), ord('9') + 1):
        table[c] = CHAR_DIGIT
    # Whitespace
    table[ord(' ')] = CHAR_SPACE
    table[ord('\t')] = CHAR_SPACE
    table[ord('\n')] = CHAR_SPACE
    table[ord('\r')] = CHAR_SPACE
    # Special token markers
    table[ord('<')] = CHAR_SPECIAL
    table[ord('>')] = CHAR_SPECIAL
    table[ord('|')] = CHAR_SPECIAL
    return table

# Usage: O(1) classification
alias CHAR_TABLE = build_char_table()

@always_inline
fn is_word_char(c: UInt8) -> Bool:
    return (CHAR_TABLE[Int(c)] & (CHAR_ALPHA | CHAR_DIGIT)) != 0
```

**Expected speedup**: 1.2-1.5x by eliminating branches

#### 5. Prefix-XOR for Quoted Regions (P1)

**mojo-json approach**:
- `vmull_p64` carry-less multiply for O(1) string detection
- 64 characters in single instruction

**Tokenizer adaptation**:
- Skip content inside quoted strings (for code tokenization)
- Detect special token boundaries (`<|...|>`)
- Handle escape sequences

```mojo
fn find_quoted_regions(text: String) -> List[Tuple[Int, Int]]:
    """Find all quoted regions in O(n/64) time using prefix-XOR."""
    var quote_mask: UInt64 = 0
    var regions = List[Tuple[Int, Int]]()

    for chunk_start in range(0, len(text), 64):
        # Build 64-bit mask of quote positions
        var chunk_quotes: UInt64 = 0
        for i in range(min(64, len(text) - chunk_start)):
            if text[chunk_start + i] == '"':
                chunk_quotes |= (1 << i)

        # Prefix-XOR via carry-less multiply (NEON vmull_p64)
        var inside_mask = prefix_xor(chunk_quotes)

        # Extract region boundaries from mask transitions
        # ...

    return regions
```

**Expected speedup**: 10-50x for code tokenization with many strings

#### 6. Optimized BPE Merge Loop (P0 - Critical Path)

**Current bottleneck** (bpe.mojo lines 308-340):
```mojo
# O(n²) - finds best merge by scanning all pairs
while len(tokens) > 1:
    var best_rank = Int.MAX
    var best_idx = -1
    for i in range(len(tokens) - 1):
        var pair = tokens[i] + tokens[i + 1]  # String allocation!
        var rank = self.merge_cache.get(pair)
        if rank < best_rank:
            best_rank = rank
            best_idx = i
    if best_idx == -1:
        break
    # Merge tokens[best_idx] and tokens[best_idx + 1]
```

**Optimized approach** (from rs-bpe/GitHub bpe):
```mojo
struct MergeHeap:
    """Priority queue for O(log n) merge selection."""
    var heap: List[Tuple[Int, Int, Int]]  # (rank, position, generation)
    var generation: Int  # Invalidation counter

    fn push(inout self, rank: Int, pos: Int):
        # Add merge candidate to heap
        heapq.heappush(self.heap, (rank, pos, self.generation))

    fn pop_valid(inout self, tokens: List[TokenSpan]) -> Optional[Int]:
        """Pop highest-priority valid merge."""
        while len(self.heap) > 0:
            var rank, pos, gen = heapq.heappop(self.heap)
            # Check if this merge is still valid (tokens not already merged)
            if gen == self.generation and pos < len(tokens) - 1:
                return pos
        return None

fn bpe_encode_optimized(text: String, vocab: Vocabulary) -> List[Int]:
    var tokens = split_to_bytes(text)  # Initial byte tokens
    var heap = MergeHeap()

    # Initialize heap with all adjacent pairs
    for i in range(len(tokens) - 1):
        var rank = vocab.merge_rank(tokens[i], tokens[i + 1])
        if rank != -1:
            heap.push(rank, i)

    # O(n log n) merging instead of O(n²)
    while True:
        var best_pos = heap.pop_valid(tokens)
        if best_pos is None:
            break

        # Perform merge
        var merged = merge_tokens(tokens, best_pos)
        tokens = merged
        heap.generation += 1

        # Add new merge candidates for neighbors
        if best_pos > 0:
            heap.push(vocab.merge_rank(tokens[best_pos-1], tokens[best_pos]), best_pos-1)
        if best_pos < len(tokens) - 1:
            heap.push(vocab.merge_rank(tokens[best_pos], tokens[best_pos+1]), best_pos)

    return [vocab.token_to_id(t) for t in tokens]
```

**Expected speedup**: 5-20x for long texts (O(n log n) vs O(n²))

---

## Part 3: Implementation Roadmap

### Phase 1: Foundation (Week 1-2)

**Goal**: 2-3x speedup with low-risk changes

1. **Zero-copy TokenSpan** (P0)
   - Replace string copies with slice references
   - Lazy token text extraction
   - Estimated: 2-3x memory reduction, 1.5x speed

2. **Branchless lookup table** (P0)
   - 256-byte ASCII classification table
   - Replace if/else chains in boundary detection
   - Estimated: 1.2x speed

3. **SIMD whitespace detection** (P0)
   - Extend existing `simd/whitespace.mojo`
   - 16-byte chunk processing
   - Estimated: 3-5x for pre-tokenization

**Phase 1 Target**: 300k tokens/sec (3x baseline)

### Phase 2: SIMD Acceleration (Week 3-4)

**Goal**: 5-10x speedup with SIMD

1. **NEON SIMD FFI** (P0)
   - Port mojo-json's neon_json.c pattern
   - Character classification in 64-byte chunks
   - Boundary detection at 3-4 GB/s

2. **Two-stage architecture** (P0)
   - Stage 1: SIMD boundary scan
   - Stage 2: Token extraction from indices
   - Decouple scanning from extraction

3. **SIMD special token detection** (P1)
   - Find `<|`, `|>`, `[CLS]` patterns
   - Multi-pattern matching in SIMD

**Phase 2 Target**: 1M tokens/sec (10x baseline)

### Phase 3: Algorithm Optimization (Week 5-6)

**Goal**: Match rs-bpe performance

1. **Heap-based BPE merging** (P0)
   - Replace O(n²) scan with O(n log n) heap
   - Generation-based invalidation
   - Estimated: 5-20x for long texts

2. **String interning for merges** (P1)
   - Cache merged token strings
   - Avoid repeated string allocation
   - Hash-based deduplication

3. **Prefix-XOR quoted regions** (P1)
   - Skip string literals in code
   - Handle escape sequences correctly

**Phase 3 Target**: 5M tokens/sec (50x baseline)

### Phase 4: Batch & Parallel (Week 7-8)

**Goal**: Exceed rs-bpe performance

1. **Parallel batch encoding** (P1)
   - Process multiple texts concurrently
   - Thread pool with work stealing
   - Estimated: Nx for N texts

2. **Prefetch optimization** (P2)
   - Pre-load vocabulary entries
   - Cache-aware merge lookup

3. **Adaptive algorithm selection** (P2)
   - Short text: simple loop
   - Long text: heap-based
   - Code: with quoted region skipping

**Phase 4 Target**: 10M+ tokens/sec (100x baseline)

---

## Part 4: Benchmark Strategy

### Comparison Libraries

| Library | Installation | Benchmark Command |
|---------|--------------|-------------------|
| **tiktoken** | `pip install tiktoken` | Python timing harness |
| **HuggingFace tokenizers** | `pip install tokenizers` | Python timing harness |
| **rs-bpe** | `pip install rs-bpe` | Python timing harness |
| **sentencepiece** | `pip install sentencepiece` | Python timing harness |

### Benchmark Datasets

#### Standard NLP Benchmarks

| Dataset | Size | Characteristics | Source |
|---------|------|-----------------|--------|
| **WikiText-2** | 10MB | Natural language, Wikipedia | [Salesforce](https://huggingface.co/datasets/wikitext) |
| **WikiText-103** | 500MB | Large-scale Wikipedia | [Salesforce](https://huggingface.co/datasets/wikitext) |
| **OpenWebText** | 40GB | Web text, diverse topics | [OpenAI reproduction](https://huggingface.co/datasets/openwebtext) |
| **The Pile (subset)** | 1GB | Mixed: code, web, books, papers | [EleutherAI](https://pile.eleuther.ai/) |
| **C4** | 800GB | Common Crawl, cleaned | [Google](https://huggingface.co/datasets/c4) |

#### Code Benchmarks

| Dataset | Size | Characteristics | Source |
|---------|------|-----------------|--------|
| **CodeParrot** | 50GB | Python source code | [HuggingFace](https://huggingface.co/datasets/codeparrot/codeparrot-clean) |
| **The Stack** | 3TB | Multi-language code | [BigCode](https://huggingface.co/datasets/bigcode/the-stack) |
| **GitHub Code** | Subset | Mixed languages | Custom extraction |

#### JSON Benchmarks (from mojo-json)

These files test tokenization of structured data and provide cross-validation with mojo-json performance:

| Dataset | Size | Characteristics | Location |
|---------|------|-----------------|----------|
| **twitter.json** | 617 KB | Web API payloads, Unicode, nested | `mojo-json/benchmarks/data/` |
| **canada.json** | 2.2 MB | GeoJSON, heavy numerics | `mojo-json/benchmarks/data/` |
| **citm_catalog.json** | 1.7 MB | Deeply nested, mixed types | `mojo-json/benchmarks/data/` |
| **api_response_10mb.json** | 10 MB | Large API payload | `mojo-json/benchmarks/data/` |

#### Adversarial Benchmarks

| Dataset | Size | Characteristics | Source |
|---------|------|-----------------|--------|
| **BPE-knockout** | 1MB | Pathological merge patterns | [GitHub bpe paper](https://github.blog/ai-and-ml/llms/so-many-tokens-so-little-time-introducing-a-faster-more-flexible-byte-pair-tokenizer/) |
| **Repeated patterns** | Synthetic | `aaaa...`, `abab...` | Generate programmatically |
| **Long tokens** | Synthetic | Force deep merge trees | Generate programmatically |
| **Unicode edge cases** | 100KB | Emoji, CJK, RTL, combining chars | Custom collection |

#### Recommended Test Suite

**Quick validation** (< 1 minute):
```
benchmarks/
├── small/
│   ├── wikitext2_sample.txt     # 100KB Wikipedia
│   ├── code_sample.py           # 50KB Python code
│   ├── twitter.json             # 617KB JSON
│   └── adversarial_basic.txt    # 10KB pathological
```

**Full benchmark** (5-10 minutes):
```
benchmarks/
├── standard/
│   ├── wikitext103_valid.txt    # 500KB validation set
│   ├── openwebtext_sample.txt   # 10MB sample
│   ├── pile_sample.txt          # 10MB mixed content
│   └── codeparrot_sample.py     # 10MB Python
├── json/
│   ├── twitter.json             # 617KB
│   ├── canada.json              # 2.2MB
│   └── citm_catalog.json        # 1.7MB
├── adversarial/
│   ├── bpe_knockout.txt         # 1MB pathological
│   ├── repeated_aa.txt          # 1MB repeated chars
│   └── unicode_stress.txt       # 100KB Unicode
```

**Cross-library validation**:
```python
# Ensure 100% token match with tiktoken
import tiktoken
enc = tiktoken.get_encoding("cl100k_base")

for file in benchmark_files:
    text = open(file).read()
    tiktoken_tokens = enc.encode(text)
    mojo_tokens = mojo_tokenizer.encode(text)
    assert tiktoken_tokens == mojo_tokens, f"Mismatch in {file}"
```

### Metrics

1. **Throughput**: tokens/second, chars/second, MB/s
2. **Latency**: p50, p95, p99 for single text
3. **Memory**: peak RSS, allocations/token
4. **Correctness**: 100% match with reference tokenizer

### Benchmark Harness

```mojo
fn benchmark_tokenizer(
    tokenizer: Tokenizer,
    texts: List[String],
    warmup: Int = 5,
    iterations: Int = 20
) -> BenchmarkResult:
    # Warmup
    for _ in range(warmup):
        for text in texts:
            _ = tokenizer.encode(text)

    # Benchmark
    var total_tokens = 0
    var total_chars = 0
    var start = perf_counter_ns()

    for _ in range(iterations):
        for text in texts:
            var tokens = tokenizer.encode(text)
            total_tokens += len(tokens)
            total_chars += len(text)

    var elapsed_ns = perf_counter_ns() - start
    var tokens_per_sec = Float64(total_tokens) / Float64(elapsed_ns) * 1e9
    var chars_per_sec = Float64(total_chars) / Float64(elapsed_ns) * 1e9

    return BenchmarkResult(tokens_per_sec, chars_per_sec, elapsed_ns / iterations)
```

---

## Part 5: Risk Assessment

### Technical Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| NEON FFI complexity | Medium | High | Start with pure Mojo SIMD, FFI as optimization |
| BPE correctness | Low | Critical | Extensive test suite against tiktoken output |
| Memory overhead | Medium | Medium | Profile early, optimize hot paths |
| Mojo compiler bugs | Low | Medium | Pin Mojo version, report issues |

### Performance Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Rust already optimal | Medium | High | Focus on unique Mojo advantages (GPU, syntax) |
| Diminishing returns | Medium | Medium | Prioritize P0 optimizations first |
| Adversarial inputs | Low | Medium | Test with GitHub bpe adversarial suite |

---

## Part 6: Success Criteria

### Minimum Viable Performance (MVP)

- [ ] 1M tokens/sec (10x current baseline)
- [ ] Correct output matching tiktoken cl100k_base
- [ ] Memory usage <2x tiktoken
- [ ] Support tiktoken and HuggingFace formats

### Stretch Goals

- [ ] 5M tokens/sec (match rs-bpe)
- [ ] 10M+ tokens/sec (beat rs-bpe)
- [ ] GPU batch acceleration
- [ ] Streaming tokenization API

### Validation

1. **Unit tests**: Token-by-token match with tiktoken
2. **Integration tests**: Full document encoding match
3. **Benchmark suite**: Reproducible performance comparison
4. **Adversarial tests**: GitHub bpe pathological cases

---

## References

### Tokenizer Implementations
- [rs-bpe](https://github.com/gweidart/rs-bpe) - Fastest Python BPE (Rust)
- [GitHub bpe](https://github.blog/ai-and-ml/llms/so-many-tokens-so-little-time-introducing-a-faster-more-flexible-byte-pair-tokenizer/) - 4x tiktoken performance
- [kitoken](https://github.com/Systemcluster/kitoken) - Multi-format compatible
- [tiktoken](https://github.com/openai/tiktoken) - OpenAI's official tokenizer
- [HuggingFace tokenizers](https://github.com/huggingface/tokenizers) - Industry standard

### Optimization Techniques
- [simdjson](https://simdjson.org/) - SIMD JSON parsing (basis for mojo-json)
- [mojo-json](https://github.com/atsentia/mojo-json) - 6.5 GB/s JSON parsing in Mojo

### Papers
- "BPE-knockout" (2023) - Adversarial BPE analysis
- "Fast WordPiece Tokenization" (2021) - Google's optimization paper

---

## Appendix: mojo-json Optimization Details

See companion document for full analysis of mojo-json's 13 optimization techniques:
- Two-stage parsing architecture
- NEON SIMD via C FFI (3-4 GB/s)
- Wide SIMD processing (16/32-byte chunks)
- Branchless character classification
- Prefix-XOR string tracking
- Value position tracking
- SWAR number parsing
- SIMD multiplication for extraction
- Fast-path chunk skipping
- Zero-copy StringSlice
- Prefetch hints
- Adaptive algorithm selection
- NDJSON parallelism

Each technique has direct application to tokenizer optimization as detailed in Part 2.
