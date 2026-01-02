# mojo-tokenizer: Technical Design

A pure Mojo tokenizer library for LLM inference, filling the gap in the MAX Engine ecosystem.

## Strategic Context

### The Problem

MAX Engine currently uses Python-wrapped HuggingFace tokenizers for text preprocessing:

```
Text → Python → HuggingFace (Rust) → Token IDs → MAX Engine → Inference
```

This creates:
- **Python interpreter overhead** in the inference hot path
- **Cross-language marshaling** costs (Python ↔ Rust ↔ C++)
- **Deployment complexity** (requires Python environment)
- **Cold start latency** (Python + Rust library initialization)

### The Solution

Pure Mojo tokenization eliminates these costs:

```
Text → mojo-tokenizer → Token IDs → MAX Engine → Inference
```

Benefits:
- **Single binary** — No Python, no external dependencies
- **Native performance** — Compiles to optimized machine code
- **Simplified deployment** — One artifact, no environment setup
- **Faster cold start** — No interpreter initialization

## Architecture

### Core Design Principles

1. **Trait-based extensibility** — `Tokenizer` trait allows multiple implementations
2. **Format compatibility** — Load existing tiktoken and HuggingFace vocabularies
3. **Zero dependencies** — Pure Mojo, no Python or C libraries
4. **Production-ready** — Special tokens, batch processing, error handling

### Module Structure

```
mojo-tokenizer/
├── src/
│   ├── __init__.mojo           # Public API exports
│   ├── tokenizer.mojo          # Tokenizer trait, Token struct
│   ├── bpe.mojo                # BPE algorithm implementation
│   ├── vocab.mojo              # Vocabulary management
│   ├── special_tokens.mojo     # Special token handling
│   └── formats/
│       ├── tiktoken.mojo       # OpenAI tiktoken loader
│       └── huggingface.mojo    # HuggingFace JSON loader
├── tests/
│   └── test_tokenizer.mojo
└── examples/
    └── basic_usage.mojo
```

### Core Types

```mojo
# All tokenizers implement this trait
trait Tokenizer:
    fn encode(self, text: String) raises -> List[Int]
    fn decode(self, tokens: List[Int]) raises -> String
    fn vocab_size(self) -> Int

# Individual token representation
struct Token:
    var id: Int
    var text: String
    var is_special: Bool

# BPE implementation
struct BPETokenizer(Tokenizer):
    var vocab: Vocabulary
    var special_tokens: SpecialTokens

    @staticmethod
    fn from_tiktoken(path: String) raises -> Self

    @staticmethod
    fn from_huggingface(path: String) raises -> Self

    fn encode_batch(self, texts: List[String]) raises -> List[List[Int]]
```

## BPE Algorithm

Byte Pair Encoding as used by GPT-2, GPT-3, GPT-4:

```
Algorithm: encode(text)
─────────────────────────────────────────────────────
1. Extract special tokens (preserve intact)
2. Convert remaining text to UTF-8 bytes
3. Map bytes to BPE unicode characters
4. Initialize tokens as individual characters

5. WHILE merges available:
   a. Find highest-priority adjacent pair
   b. If pair has merge rule:
      - Replace all occurrences with merged token
   c. Else: break

6. Look up final tokens in vocabulary
7. Return token IDs
─────────────────────────────────────────────────────
```

### Merge Priority

BPE merge rules have priority (rank). Lower rank = higher priority = applied first.

Example merges:
```
Rank 0: "a" + "b" → "ab"     (applied first)
Rank 1: "c" + "d" → "cd"
Rank 2: "ab" + "cd" → "abcd" (applied after 0 and 1)
```

## Format Compatibility

### Tiktoken Format

OpenAI's format used by GPT-3.5, GPT-4, GPT-4o:

```
File: cl100k_base.tiktoken
Format: <base64-encoded-token> <rank>

IQ== 0
Ig== 1
Iw== 2
...
```

Loading:
```mojo
var tokenizer = BPETokenizer.from_tiktoken("cl100k_base.tiktoken")
```

### HuggingFace JSON Format

Used by most Hugging Face models:

```json
{
  "version": "1.0",
  "model": {
    "type": "BPE",
    "vocab": {"token": id, ...},
    "merges": ["first second", ...]
  },
  "added_tokens": [
    {"content": "<s>", "id": 0, "special": true},
    {"content": "</s>", "id": 1, "special": true}
  ]
}
```

Loading:
```mojo
var tokenizer = BPETokenizer.from_huggingface("tokenizer.json")
```

## Special Token Handling

Special tokens are never split during tokenization:

```mojo
# Register special tokens
tokenizer.add_special_token("<|endoftext|>", 50256)
tokenizer.add_special_token("<|im_start|>", 100264)
tokenizer.add_special_token("<|im_end|>", 100265)

# Encoding preserves special tokens
tokenizer.encode("Hello<|endoftext|>World")
# → [15496, 50256, 14957]
#    Hello  EOT    World
```

Common special tokens by model:

| Model Family | BOS | EOS | PAD | Special |
|--------------|-----|-----|-----|---------|
| GPT-2/3/4 | — | `<\|endoftext\|>` | — | — |
| Llama | `<s>` | `</s>` | `<pad>` | — |
| ChatML | — | — | — | `<\|im_start\|>`, `<\|im_end\|>` |
| BERT | `[CLS]` | `[SEP]` | `[PAD]` | `[MASK]` |

## Performance Targets

| Metric | Target | Comparison |
|--------|--------|------------|
| Encode throughput | >100k tokens/sec | HuggingFace Rust: ~50k |
| Memory (vocab) | <10MB | SentencePiece: 6MB |
| Cold start | <100ms | Python tokenizers: 500ms+ |
| Binary size | <5MB | Standalone deployment |

### Optimization Strategies

1. **Efficient data structures** — Dict for O(1) token/merge lookup
2. **Byte mapping cache** — Precomputed byte ↔ unicode mapping
3. **Batch processing** — Amortize overhead across multiple texts
4. **SIMD where applicable** — Mojo's vectorization for byte operations

## Roadmap

### v0.1 (Foundation)
- [x] Core types (Token, Vocabulary, SpecialTokens)
- [x] BPE algorithm implementation
- [x] Tiktoken format loader (stub)
- [x] Basic tests and examples

### v0.2 (Format Support)
- [ ] Complete tiktoken loading (file I/O, base64)
- [ ] HuggingFace JSON loading (JSON parser)
- [ ] Chat template support

### v0.3 (Production)
- [ ] Batch encoding optimization
- [ ] SentencePiece format support
- [ ] Performance benchmarks

### v1.0 (Full Feature)
- [ ] Training from corpus
- [ ] Regex pre-tokenization
- [ ] Full parity with HuggingFace tokenizers

## Integration with MAX Engine

### Current State (Python tokenizers)

```python
from transformers import AutoTokenizer
tokenizer = AutoTokenizer.from_pretrained("meta-llama/Llama-2-7b")
tokens = tokenizer.encode("Hello, world!")
# → Pass to MAX Engine
```

### Future State (mojo-tokenizer)

```mojo
from mojo_tokenizer import BPETokenizer

var tokenizer = BPETokenizer.from_huggingface("tokenizer.json")
var tokens = tokenizer.encode("Hello, world!")
# → Pass directly to MAX Engine (no Python boundary)
```

### Benefits for MAX Serve

1. **Lower latency** — No Python in request path
2. **Higher throughput** — No GIL contention
3. **Simpler deployment** — Single Mojo binary
4. **Better scaling** — Pure compute, no interpreter overhead

## Dependencies

**None.** This library is pure Mojo with no external dependencies.

Future optional integrations:
- `mojo-json` — For HuggingFace JSON parsing
- `mojo-http` — For downloading vocabularies

## Repository

- **Location**: https://github.com/atsentia/mojo-tokenizer (private)
- **License**: Apache 2.0 with LLVM Exceptions
- **Part of**: mojo-contrib ecosystem

## References

- [OpenAI tiktoken](https://github.com/openai/tiktoken) — Reference BPE implementation
- [HuggingFace tokenizers](https://github.com/huggingface/tokenizers) — Rust tokenizer library
- [minbpe](https://github.com/karpathy/minbpe) — Minimal BPE implementation
- [minbpe.mojo](https://github.com/dorjeduck/minbpe.mojo) — Mojo port of minbpe
