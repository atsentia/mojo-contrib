# mojo-tokenizer: Full Implementation & Optimization Plan

A comprehensive plan to achieve 100% feature parity with HuggingFace tokenizers and optimize for maximum performance.

## Executive Summary

**Goal**: Build a production-grade tokenizer in pure Mojo that:
1. Achieves feature parity with HuggingFace tokenizers
2. Matches or exceeds HuggingFace Rust performance (~50k tokens/sec)
3. Targets 100k+ tokens/sec through SIMD optimization

**Current State**: v0.2.0 - Full infrastructure complete
- 3,759 lines of Mojo code across 26 files
- BPE tokenization with tiktoken and HuggingFace format support
- Word-level LRU caching (80%+ hit rate target)
- SIMD-optimized whitespace/special char detection
- 10 chat template formats
- HuggingFace-compatible pipeline stages
- Benchmark framework

**Target**: v1.0 production-ready with benchmarks

---

## Part A: Feature Parity Implementation

### The 4-Stage Pipeline

HuggingFace tokenizers use a 4-stage pipeline. We must implement all stages:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        TOKENIZATION PIPELINE                        │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   Raw Text                                                          │
│      │                                                              │
│      ▼                                                              │
│   ┌─────────────────┐                                               │
│   │  1. NORMALIZER  │  Unicode normalization, lowercase, accents   │
│   └────────┬────────┘                                               │
│            │                                                        │
│            ▼                                                        │
│   ┌─────────────────┐                                               │
│   │ 2. PRE-TOKENIZER│  Split into "words" (whitespace, regex)      │
│   └────────┬────────┘                                               │
│            │                                                        │
│            ▼                                                        │
│   ┌─────────────────┐                                               │
│   │    3. MODEL     │  BPE / WordPiece / Unigram algorithm         │
│   └────────┬────────┘                                               │
│            │                                                        │
│            ▼                                                        │
│   ┌─────────────────┐                                               │
│   │ 4. POST-PROCESS │  Add special tokens, create masks            │
│   └────────┬────────┘                                               │
│            │                                                        │
│            ▼                                                        │
│   Token IDs + Attention Mask + Offsets                              │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Phase 1: Core Infrastructure (Week 1)

**1.1 File I/O & Base64**

```mojo
# src/io/file.mojo
fn read_file(path: String) raises -> String:
    """Read entire file as string."""
    ...

fn read_lines(path: String) raises -> List[String]:
    """Read file line by line."""
    ...

# src/encoding/base64.mojo
fn base64_decode(encoded: String) raises -> List[UInt8]:
    """Decode base64 string to bytes."""
    # Standard base64 alphabet
    # Handle padding (=)
    ...
```

**1.2 JSON Parser Integration**

Use mojo-json for HuggingFace format:

```mojo
# src/formats/huggingface.mojo
from mojo_json import parse, JsonValue

fn load_huggingface(path: String) raises -> (Vocabulary, SpecialTokens, Config):
    var content = read_file(path)
    var json = parse(content)

    # Extract model section
    var model = json["model"]
    var vocab = parse_vocab(model["vocab"])
    var merges = parse_merges(model["merges"])

    # Extract special tokens
    var added_tokens = json["added_tokens"]
    var special = parse_special_tokens(added_tokens)

    # Extract config
    var config = parse_config(json)

    return (vocab, special, config)
```

**1.3 Complete Tiktoken Loader**

```mojo
# src/formats/tiktoken.mojo
fn load_tiktoken(path: String) raises -> (Vocabulary, List[MergeRule]):
    """
    Tiktoken format:
    <base64-token> <rank>

    Example:
    IQ== 0
    Ig== 1
    """
    var vocab = Vocabulary()
    var merges = List[MergeRule]()

    var lines = read_lines(path)
    for i in range(len(lines)):
        var parts = lines[i].split(" ")
        var token_bytes = base64_decode(parts[0])
        var token = bytes_to_string(token_bytes)
        var rank = int(parts[1])

        vocab.add_token(token, rank)

        # Build merge rules from consecutive tokens
        if i > 0:
            # Infer merge from vocabulary ordering
            ...

    return (vocab, merges)
```

### Phase 2: Pipeline Stages (Week 2)

**2.1 Normalizer**

```mojo
# src/pipeline/normalizer.mojo

trait Normalizer:
    fn normalize(self, text: String) -> String

struct NFCNormalizer(Normalizer):
    """Unicode NFC normalization."""
    fn normalize(self, text: String) -> String:
        # NFC: Canonical Decomposition, followed by Canonical Composition
        ...

struct LowercaseNormalizer(Normalizer):
    fn normalize(self, text: String) -> String:
        return text.lower()

struct StripAccentsNormalizer(Normalizer):
    fn normalize(self, text: String) -> String:
        # Remove combining diacritical marks
        ...

struct SequenceNormalizer(Normalizer):
    """Chain multiple normalizers."""
    var normalizers: List[Normalizer]

    fn normalize(self, text: String) -> String:
        var result = text
        for n in self.normalizers:
            result = n[].normalize(result)
        return result
```

**2.2 Pre-Tokenizer**

```mojo
# src/pipeline/pre_tokenizer.mojo

struct PreToken:
    var text: String
    var start: Int  # Character offset in original
    var end: Int

trait PreTokenizer:
    fn pre_tokenize(self, text: String) -> List[PreToken]

struct WhitespacePreTokenizer(PreTokenizer):
    """Split on whitespace."""
    fn pre_tokenize(self, text: String) -> List[PreToken]:
        var result = List[PreToken]()
        var start = 0
        var in_word = False

        for i in range(len(text)):
            var is_ws = is_whitespace(text[i])
            if in_word and is_ws:
                result.append(PreToken(text[start:i], start, i))
                in_word = False
            elif not in_word and not is_ws:
                start = i
                in_word = True

        if in_word:
            result.append(PreToken(text[start:], start, len(text)))

        return result

struct ByteLevelPreTokenizer(PreTokenizer):
    """GPT-2 style byte-level pre-tokenization with regex."""
    var add_prefix_space: Bool
    var pattern: String  # Regex pattern

    fn pre_tokenize(self, text: String) -> List[PreToken]:
        # GPT-2 pattern: 's|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+
        ...

struct MetaspacePreTokenizer(PreTokenizer):
    """SentencePiece style with ▁ for spaces."""
    var replacement: String  # Usually "▁"
    var add_prefix_space: Bool
```

**2.3 Model Algorithms**

```mojo
# src/models/bpe.mojo

struct BPEModel:
    var vocab: Vocabulary
    var merges: Dict[String, Int]  # pair -> rank
    var byte_encoder: Dict[Int, String]
    var byte_decoder: Dict[String, Int]
    var cache: Dict[String, List[Int]]  # Token cache
    var cache_capacity: Int

    fn tokenize(self, pre_token: PreToken) -> List[Int]:
        """Apply BPE to a single pre-token."""
        var word = pre_token.text

        # Check cache first
        if word in self.cache:
            return self.cache[word]

        # Convert to byte representation
        var tokens = self._bytes_to_unicode(word)

        # Apply merges iteratively
        while len(tokens) > 1:
            var best_pair = self._find_best_pair(tokens)
            if best_pair.rank < 0:
                break
            tokens = self._apply_merge(tokens, best_pair)

        # Convert to IDs
        var ids = List[Int]()
        for t in tokens:
            ids.append(self.vocab.get_id(t[]))

        # Cache result
        if len(self.cache) < self.cache_capacity:
            self.cache[word] = ids

        return ids

# src/models/wordpiece.mojo

struct WordPieceModel:
    var vocab: Vocabulary
    var unk_token: String
    var continuing_subword_prefix: String  # "##"
    var max_input_chars_per_word: Int

    fn tokenize(self, pre_token: PreToken) -> List[Int]:
        """Greedy longest-match-first tokenization."""
        var word = pre_token.text

        if len(word) > self.max_input_chars_per_word:
            return List[Int](self.vocab.get_id(self.unk_token))

        var tokens = List[Int]()
        var start = 0

        while start < len(word):
            var end = len(word)
            var found = False

            while start < end:
                var substr = word[start:end]
                if start > 0:
                    substr = self.continuing_subword_prefix + substr

                if self.vocab.has_token(substr):
                    tokens.append(self.vocab.get_id(substr))
                    found = True
                    break

                end -= 1

            if not found:
                tokens.append(self.vocab.get_id(self.unk_token))
                break

            start = end

        return tokens

# src/models/unigram.mojo

struct UnigramModel:
    var vocab: Vocabulary
    var scores: Dict[String, Float64]  # Token -> log probability
    var unk_token: String

    fn tokenize(self, pre_token: PreToken) -> List[Int]:
        """Viterbi algorithm for optimal segmentation."""
        var text = pre_token.text
        var n = len(text)

        # Dynamic programming: best[i] = (score, backpointer)
        var best = List[(Float64, Int)]()
        for _ in range(n + 1):
            best.append((-inf, -1))
        best[0] = (0.0, 0)

        for end in range(1, n + 1):
            for start in range(end):
                var substr = text[start:end]
                if substr in self.scores:
                    var score = best[start][0] + self.scores[substr]
                    if score > best[end][0]:
                        best[end] = (score, start)

        # Backtrack to find tokens
        var tokens = List[Int]()
        var pos = n
        while pos > 0:
            var start = best[pos][1]
            var token = text[start:pos]
            tokens.insert(0, self.vocab.get_id(token))
            pos = start

        return tokens
```

**2.4 Post-Processor**

```mojo
# src/pipeline/post_processor.mojo

struct EncodingResult:
    var input_ids: List[Int]
    var attention_mask: List[Int]
    var token_type_ids: List[Int]
    var offsets: List[(Int, Int)]  # (start, end) in original text

trait PostProcessor:
    fn process(self, tokens: List[Int], offsets: List[(Int, Int)]) -> EncodingResult

struct TemplateProcessor(PostProcessor):
    """Add special tokens based on template."""
    var single_template: String  # "[CLS] $A [SEP]"
    var pair_template: String    # "[CLS] $A [SEP] $B:1 [SEP]:1"
    var special_tokens: Dict[String, Int]

    fn process(self, tokens: List[Int], offsets: List[(Int, Int)]) -> EncodingResult:
        var result = EncodingResult()

        # Parse template and insert special tokens
        # $A = input tokens
        # :1 = token_type_id 1
        ...

        # Generate attention mask (all 1s for now)
        for _ in range(len(result.input_ids)):
            result.attention_mask.append(1)
            result.token_type_ids.append(0)

        return result
```

### Phase 3: Chat Templates (Week 3)

**3.1 Simple Template Engine**

```mojo
# src/templates/chat.mojo

struct Message:
    var role: String      # "user", "assistant", "system"
    var content: String

struct ChatTemplate:
    """Simplified Jinja2-like template for chat formatting."""
    var template: String
    var bos_token: String
    var eos_token: String

    fn apply(self, messages: List[Message], add_generation_prompt: Bool = True) -> String:
        """Apply template to messages."""
        var result = String()

        # Common patterns:
        # Mistral: [INST] user [/INST] assistant
        # ChatML: <|im_start|>role\ncontent<|im_end|>
        # Llama: <s>[INST] <<SYS>>system<</SYS>> user [/INST] assistant </s>

        for msg in messages:
            result += self._format_message(msg[])

        if add_generation_prompt:
            result += self._generation_prompt()

        return result

    fn _format_message(self, msg: Message) -> String:
        # Template variable substitution
        # {{ message.role }} -> msg.role
        # {{ message.content }} -> msg.content
        ...

# Pre-defined templates for common models
fn mistral_template() -> ChatTemplate:
    return ChatTemplate(
        template="[INST] {{ message.content }} [/INST]",
        bos_token="<s>",
        eos_token="</s>"
    )

fn chatml_template() -> ChatTemplate:
    return ChatTemplate(
        template="<|im_start|>{{ message.role }}\n{{ message.content }}<|im_end|>\n",
        bos_token="",
        eos_token="<|im_end|>"
    )

fn llama_template() -> ChatTemplate:
    return ChatTemplate(
        template="<s>[INST] <<SYS>>\n{{ system }}\n<</SYS>>\n\n{{ message.content }} [/INST]",
        bos_token="<s>",
        eos_token="</s>"
    )
```

### Phase 4: Padding & Truncation (Week 3)

```mojo
# src/pipeline/padding.mojo

struct PaddingConfig:
    var max_length: Int
    var pad_id: Int
    var pad_token: String
    var padding_side: String  # "left" or "right"
    var pad_to_multiple_of: Int  # e.g., 8 for GPU efficiency

struct TruncationConfig:
    var max_length: Int
    var truncation_side: String  # "left" or "right"
    var stride: Int  # Overlap for sliding window

fn pad_batch(
    encodings: List[EncodingResult],
    config: PaddingConfig
) -> List[EncodingResult]:
    """Pad all encodings to same length."""

    # Find max length in batch
    var max_len = 0
    for enc in encodings:
        max_len = max(max_len, len(enc[].input_ids))

    # Round up to multiple
    if config.pad_to_multiple_of > 0:
        max_len = ((max_len + config.pad_to_multiple_of - 1)
                   // config.pad_to_multiple_of) * config.pad_to_multiple_of

    # Apply max_length limit
    max_len = min(max_len, config.max_length)

    # Pad each encoding
    var result = List[EncodingResult]()
    for enc in encodings:
        result.append(pad_single(enc[], max_len, config))

    return result

fn truncate(encoding: EncodingResult, config: TruncationConfig) -> EncodingResult:
    """Truncate encoding to max length."""
    if len(encoding.input_ids) <= config.max_length:
        return encoding

    var result = EncodingResult()

    if config.truncation_side == "right":
        result.input_ids = encoding.input_ids[:config.max_length]
        result.attention_mask = encoding.attention_mask[:config.max_length]
    else:  # left
        var start = len(encoding.input_ids) - config.max_length
        result.input_ids = encoding.input_ids[start:]
        result.attention_mask = encoding.attention_mask[start:]

    return result
```

### Phase 5: Full Tokenizer API (Week 4)

```mojo
# src/tokenizer_full.mojo

struct Tokenizer:
    """Full-featured tokenizer with HuggingFace parity."""

    # Pipeline components
    var normalizer: Optional[Normalizer]
    var pre_tokenizer: PreTokenizer
    var model: TokenizerModel  # BPE, WordPiece, or Unigram
    var post_processor: Optional[PostProcessor]
    var decoder: Decoder

    # Configuration
    var padding: Optional[PaddingConfig]
    var truncation: Optional[TruncationConfig]
    var chat_template: Optional[ChatTemplate]

    # Special tokens
    var special_tokens: SpecialTokens
    var bos_token_id: Optional[Int]
    var eos_token_id: Optional[Int]
    var pad_token_id: Optional[Int]
    var unk_token_id: Optional[Int]

    @staticmethod
    fn from_file(path: String) raises -> Tokenizer:
        """Load from tokenizer.json or .tiktoken file."""
        if path.endswith(".json"):
            return load_from_huggingface(path)
        elif path.endswith(".tiktoken"):
            return load_from_tiktoken(path)
        else:
            raise Error("Unknown tokenizer format: " + path)

    fn encode(
        self,
        text: String,
        add_special_tokens: Bool = True,
        return_offsets: Bool = False
    ) raises -> EncodingResult:
        """Encode single text."""

        # Stage 1: Normalize
        var normalized = text
        if self.normalizer:
            normalized = self.normalizer.value().normalize(text)

        # Stage 2: Pre-tokenize
        var pre_tokens = self.pre_tokenizer.pre_tokenize(normalized)

        # Stage 3: Tokenize each pre-token
        var all_ids = List[Int]()
        var all_offsets = List[(Int, Int)]()

        for pt in pre_tokens:
            var ids = self.model.tokenize(pt[])
            for id in ids:
                all_ids.append(id[])
            if return_offsets:
                # Map token offsets back to original text
                all_offsets.append((pt[].start, pt[].end))

        # Stage 4: Post-process
        var result: EncodingResult
        if add_special_tokens and self.post_processor:
            result = self.post_processor.value().process(all_ids, all_offsets)
        else:
            result = EncodingResult()
            result.input_ids = all_ids
            result.offsets = all_offsets
            for _ in all_ids:
                result.attention_mask.append(1)

        return result

    fn encode_batch(
        self,
        texts: List[String],
        add_special_tokens: Bool = True,
        padding: Bool = True,
        truncation: Bool = True
    ) raises -> List[EncodingResult]:
        """Encode multiple texts with optional padding/truncation."""

        var results = List[EncodingResult]()

        # Encode each text
        for text in texts:
            var enc = self.encode(text[], add_special_tokens)

            # Apply truncation
            if truncation and self.truncation:
                enc = truncate(enc, self.truncation.value())

            results.append(enc)

        # Apply padding
        if padding and self.padding:
            results = pad_batch(results, self.padding.value())

        return results

    fn decode(
        self,
        ids: List[Int],
        skip_special_tokens: Bool = True
    ) -> String:
        """Decode token IDs to text."""
        var tokens = List[String]()

        for id in ids:
            if skip_special_tokens and self.special_tokens.is_special_id(id[]):
                continue
            tokens.append(self.model.id_to_token(id[]))

        return self.decoder.decode(tokens)

    fn apply_chat_template(
        self,
        messages: List[Message],
        add_generation_prompt: Bool = True,
        tokenize: Bool = True
    ) raises -> EncodingResult:
        """Apply chat template and optionally tokenize."""

        if not self.chat_template:
            raise Error("No chat template configured")

        var text = self.chat_template.value().apply(messages, add_generation_prompt)

        if tokenize:
            return self.encode(text)
        else:
            var result = EncodingResult()
            # Return text only (for debugging)
            return result

    fn vocab_size(self) -> Int:
        return self.model.vocab_size() + self.special_tokens.size()
```

---

## Part B: Performance Optimization

### Optimization Strategy (Inspired by mojo-json)

```
┌─────────────────────────────────────────────────────────────────────┐
│                    PERFORMANCE OPTIMIZATION LAYERS                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Layer 1: ALGORITHM OPTIMIZATION                                    │
│  ├── Token cache (avoid re-computing common words)                  │
│  ├── Efficient merge lookup (perfect hashing)                       │
│  └── Early termination (no more merges possible)                    │
│                                                                     │
│  Layer 2: SIMD OPTIMIZATION (16-64 byte chunks)                     │
│  ├── Whitespace detection                                           │
│  ├── Special character finding                                      │
│  ├── Byte-to-unicode mapping                                        │
│  └── UTF-8 validation                                               │
│                                                                     │
│  Layer 3: MEMORY OPTIMIZATION                                       │
│  ├── Pre-allocated buffers                                          │
│  ├── String interning for tokens                                    │
│  └── Contiguous memory layout                                       │
│                                                                     │
│  Layer 4: BATCH OPTIMIZATION                                        │
│  ├── Parallel encoding (multiple texts)                             │
│  ├── Shared vocabulary lookups                                      │
│  └── Amortized allocation                                           │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### SIMD Patterns for Tokenization

**Pattern 1: Fast Whitespace Detection**

```mojo
# src/simd/whitespace.mojo

alias SIMD_WIDTH: Int = 16

@always_inline
fn skip_whitespace_simd(data: String, start: Int) -> Int:
    """Skip whitespace using SIMD. Returns position of first non-whitespace."""
    var pos = start
    var n = len(data)

    # Process 16 bytes at a time
    while pos + SIMD_WIDTH <= n:
        var chunk = SIMD[DType.uint8, SIMD_WIDTH]()

        @parameter
        for i in range(SIMD_WIDTH):
            chunk[i] = UInt8(ord(data[pos + i]))

        # Create whitespace mask (space, tab, newline, carriage return)
        var ws_mask = create_whitespace_mask(chunk)

        # Quick check: all whitespace?
        if ws_mask.reduce_add() == SIMD_WIDTH:
            pos += SIMD_WIDTH
            continue

        # Find first non-whitespace
        @parameter
        for i in range(SIMD_WIDTH):
            if ws_mask[i] == 0:
                return pos + i

        pos += SIMD_WIDTH

    # Scalar tail
    while pos < n and is_whitespace(data[pos]):
        pos += 1

    return pos

@always_inline
fn create_whitespace_mask(chunk: SIMD[DType.uint8, 16]) -> SIMD[DType.uint8, 16]:
    """Create mask: 1 for whitespace, 0 otherwise."""
    alias SPACE: UInt8 = 32
    alias TAB: UInt8 = 9
    alias NEWLINE: UInt8 = 10
    alias CR: UInt8 = 13

    var mask = SIMD[DType.uint8, 16]()

    @parameter
    for i in range(SIMD_WIDTH):
        var c = chunk[i]
        mask[i] = 1 if (c == SPACE or c == TAB or c == NEWLINE or c == CR) else 0

    return mask
```

**Pattern 2: Fast Special Token Detection**

```mojo
# src/simd/special.mojo

@always_inline
fn find_special_char(data: String, start: Int, chars: String) -> Int:
    """Find first occurrence of any char in chars using SIMD."""
    var pos = start
    var n = len(data)

    while pos + SIMD_WIDTH <= n:
        var chunk = SIMD[DType.uint8, SIMD_WIDTH]()

        @parameter
        for i in range(SIMD_WIDTH):
            chunk[i] = UInt8(ord(data[pos + i]))

        # Check each special character
        var found_mask = SIMD[DType.uint8, 16](0)
        for c in chars:
            var char_val = UInt8(ord(c))
            @parameter
            for i in range(SIMD_WIDTH):
                if chunk[i] == char_val:
                    found_mask[i] = 1

        # Any matches?
        if found_mask.reduce_add() > 0:
            @parameter
            for i in range(SIMD_WIDTH):
                if found_mask[i] == 1:
                    return pos + i

        pos += SIMD_WIDTH

    # Scalar tail
    while pos < n:
        for c in chars:
            if data[pos] == c:
                return pos
        pos += 1

    return -1  # Not found
```

**Pattern 3: Batch Byte-to-Unicode Mapping**

```mojo
# src/simd/byte_mapping.mojo

struct ByteMapper:
    """SIMD-optimized byte to unicode mapping for BPE."""
    var mapping: InlinedFixedVector[String, 256]

    fn __init__(out self):
        # Initialize GPT-2 style byte mapping
        self._init_gpt2_mapping()

    fn map_bytes_simd(self, data: List[UInt8]) -> String:
        """Map bytes to unicode using SIMD where possible."""
        var result = String()
        var pos = 0
        var n = len(data)

        # For bytes in printable ASCII range, direct mapping
        while pos + SIMD_WIDTH <= n:
            var chunk = SIMD[DType.uint8, SIMD_WIDTH]()

            @parameter
            for i in range(SIMD_WIDTH):
                chunk[i] = data[pos + i]

            # Check if all in printable range (33-126)
            var all_printable = True
            @parameter
            for i in range(SIMD_WIDTH):
                if chunk[i] < 33 or chunk[i] > 126:
                    all_printable = False
                    break

            if all_printable:
                # Fast path: direct char conversion
                @parameter
                for i in range(SIMD_WIDTH):
                    result += chr(Int(chunk[i]))
                pos += SIMD_WIDTH
            else:
                # Slow path: use lookup table
                @parameter
                for i in range(SIMD_WIDTH):
                    result += self.mapping[Int(chunk[i])]
                pos += SIMD_WIDTH

        # Scalar tail
        while pos < n:
            result += self.mapping[Int(data[pos])]
            pos += 1

        return result
```

**Pattern 4: Parallel Merge Finding**

```mojo
# src/simd/merge.mojo

struct MergeFinder:
    """Find best merge pair efficiently."""
    var merge_ranks: Dict[UInt64, Int]  # Hash(pair) -> rank

    fn find_best_merge(self, tokens: List[String]) -> (Int, Int, Int):
        """Find highest priority merge. Returns (pos, pos+1, rank) or (-1, -1, -1)."""
        var best_pos = -1
        var best_rank = -1

        # Could parallelize this for very long token lists
        for i in range(len(tokens) - 1):
            var pair_hash = self._hash_pair(tokens[i], tokens[i + 1])
            if pair_hash in self.merge_ranks:
                var rank = self.merge_ranks[pair_hash]
                if best_rank < 0 or rank < best_rank:
                    best_rank = rank
                    best_pos = i

        return (best_pos, best_pos + 1 if best_pos >= 0 else -1, best_rank)

    @always_inline
    fn _hash_pair(self, a: String, b: String) -> UInt64:
        """Fast hash for token pair lookup."""
        # FNV-1a hash
        var hash: UInt64 = 14695981039346656037
        for c in a:
            hash ^= UInt64(ord(c))
            hash *= 1099511628211
        hash ^= UInt64(0xFF)  # Separator
        hash *= 1099511628211
        for c in b:
            hash ^= UInt64(ord(c))
            hash *= 1099511628211
        return hash
```

### Token Cache for Common Words

```mojo
# src/cache/token_cache.mojo

struct TokenCache:
    """LRU cache for tokenized words."""
    var cache: Dict[String, List[Int]]
    var access_order: List[String]  # For LRU eviction
    var capacity: Int
    var hits: Int
    var misses: Int

    fn __init__(out self, capacity: Int = 10000):
        self.cache = Dict[String, List[Int]]()
        self.access_order = List[String]()
        self.capacity = capacity
        self.hits = 0
        self.misses = 0

    fn get(mut self, key: String) -> Optional[List[Int]]:
        if key in self.cache:
            self.hits += 1
            self._move_to_front(key)
            return self.cache[key]
        self.misses += 1
        return None

    fn put(mut self, key: String, value: List[Int]):
        if len(self.cache) >= self.capacity:
            self._evict_lru()
        self.cache[key] = value
        self.access_order.append(key)

    fn hit_rate(self) -> Float64:
        var total = self.hits + self.misses
        if total == 0:
            return 0.0
        return Float64(self.hits) / Float64(total)
```

### Benchmark Framework

```mojo
# benchmarks/bench_tokenizer.mojo

alias WARMUP = 5
alias ITERATIONS = 20

struct BenchResult:
    var name: String
    var text_size: Int
    var tokens: Int
    var time_ms: Float64
    var throughput_tokens_per_sec: Float64
    var throughput_mb_per_sec: Float64

fn benchmark_encode(tokenizer: Tokenizer, text: String, iterations: Int) -> BenchResult:
    """Benchmark encoding throughput."""
    var total_ns: Int = 0
    var token_count = 0

    # Warmup
    for _ in range(WARMUP):
        var result = tokenizer.encode(text)
        token_count = len(result.input_ids)

    # Timed iterations
    for _ in range(iterations):
        var start = perf_counter_ns()
        var result = tokenizer.encode(text)
        var end = perf_counter_ns()
        total_ns += Int(end - start)
        _ = result  # Prevent optimization

    var avg_ms = Float64(total_ns) / Float64(iterations) / 1_000_000.0
    var tokens_per_sec = Float64(token_count) / (avg_ms / 1000.0)
    var mb_per_sec = (Float64(len(text)) / 1024.0 / 1024.0) / (avg_ms / 1000.0)

    return BenchResult(
        name="encode",
        text_size=len(text),
        tokens=token_count,
        time_ms=avg_ms,
        throughput_tokens_per_sec=tokens_per_sec,
        throughput_mb_per_sec=mb_per_sec
    )

fn benchmark_batch(tokenizer: Tokenizer, texts: List[String], iterations: Int) -> BenchResult:
    """Benchmark batch encoding."""
    var total_ns: Int = 0
    var total_tokens = 0
    var total_size = 0

    for t in texts:
        total_size += len(t[])

    # Warmup
    for _ in range(WARMUP):
        var results = tokenizer.encode_batch(texts)
        total_tokens = 0
        for r in results:
            total_tokens += len(r[].input_ids)

    # Timed iterations
    for _ in range(iterations):
        var start = perf_counter_ns()
        var results = tokenizer.encode_batch(texts)
        var end = perf_counter_ns()
        total_ns += Int(end - start)
        _ = results

    var avg_ms = Float64(total_ns) / Float64(iterations) / 1_000_000.0
    var tokens_per_sec = Float64(total_tokens) / (avg_ms / 1000.0)
    var mb_per_sec = (Float64(total_size) / 1024.0 / 1024.0) / (avg_ms / 1000.0)

    return BenchResult(
        name="encode_batch",
        text_size=total_size,
        tokens=total_tokens,
        time_ms=avg_ms,
        throughput_tokens_per_sec=tokens_per_sec,
        throughput_mb_per_sec=mb_per_sec
    )

fn main() raises:
    print("=== mojo-tokenizer Benchmark Suite ===\n")

    # Load tokenizer
    var tokenizer = Tokenizer.from_file("gpt2.json")

    # Test data
    var short_text = "Hello, world!"
    var medium_text = "The quick brown fox jumps over the lazy dog. " * 100
    var long_text = read_file("benchmarks/data/article.txt")

    # Run benchmarks
    print("Single text encoding:")
    print("  Short:", benchmark_encode(tokenizer, short_text, ITERATIONS))
    print("  Medium:", benchmark_encode(tokenizer, medium_text, ITERATIONS))
    print("  Long:", benchmark_encode(tokenizer, long_text, ITERATIONS))

    # Batch benchmark
    var batch = List[String]()
    for _ in range(100):
        batch.append(medium_text)

    print("\nBatch encoding (100 texts):")
    print("  ", benchmark_batch(tokenizer, batch, ITERATIONS))

    # Cache stats
    print("\nCache hit rate:", tokenizer.model.cache.hit_rate())
```

### Performance Targets

| Metric | v0.1 (Current) | v0.5 (SIMD) | v1.0 (Optimized) | HuggingFace Rust |
|--------|----------------|-------------|------------------|------------------|
| Encode (tokens/sec) | ~10k | ~50k | **100k+** | ~50k |
| Batch encode | ~20k | ~80k | **150k+** | ~80k |
| Memory (vocab) | ~20MB | ~15MB | **<10MB** | ~15MB |
| Cold start | ~200ms | ~150ms | **<100ms** | ~100ms |
| Cache hit rate | N/A | 60% | **80%+** | N/A |

---

## Implementation Roadmap

### Week 1: Core Infrastructure ✓ COMPLETE
- [x] File I/O (read_file, read_lines) - `src/io/file.mojo`
- [x] Base64 decoder - `src/encoding/base64.mojo`
- [x] Complete tiktoken loader - `src/formats/tiktoken.mojo`
- [x] JSON-based HuggingFace loader - `src/formats/huggingface.mojo`, `src/json/parser.mojo`
- [x] Unit tests for loaders - `tests/test_tokenizer.mojo`

### Week 2: Pipeline Stages ✓ COMPLETE
- [x] Normalizer trait + implementations (NFC, lowercase, strip, whitespace) - `src/pipeline/normalizer.mojo`
- [x] PreTokenizer trait + implementations (Whitespace, ByteLevel, Punctuation, Digit) - `src/pipeline/pretokenizer.mojo`
- [x] Complete BPE model with proper merge application - `src/bpe.mojo`
- [ ] WordPiece model (v0.3)
- [x] PostProcessor with template support - `src/pipeline/postprocessor.mojo`

### Week 3: Advanced Features ✓ COMPLETE
- [x] Chat template engine - `src/chat/template.mojo`
- [x] 10 chat formats (ChatML, Llama 2/3, Mistral, Alpaca, Vicuna, Phi-3, Gemma, Zephyr) - `src/chat/formats.mojo`
- [x] Attention mask generation - `src/pipeline/postprocessor.mojo`
- [x] Batch encoding API - `src/bpe.mojo`
- [ ] Unigram model (SentencePiece) (v0.3)

### Week 4: Optimization ✓ COMPLETE
- [x] SIMD whitespace detection (16-byte chunks) - `src/simd/whitespace.mojo`
- [x] SIMD special char detection - `src/simd/special.mojo`
- [x] Token cache implementation (LRU, 10k entries) - `src/cache/token_cache.mojo`
- [x] Merge cache (FNV-1a hash, O(1) lookup) - `src/cache/token_cache.mojo`
- [x] Benchmark framework - `src/benchmark/runner.mojo`, `src/benchmark/stats.mojo`

### Week 5: Polish & Release - IN PROGRESS
- [x] Basic test suite - `tests/test_tokenizer.mojo`
- [ ] Benchmark comparison with HuggingFace
- [x] Documentation - README.md updated
- [x] v0.2.0 released

### Remaining for v1.0:
- [ ] WordPiece model
- [ ] Unigram/SentencePiece model
- [ ] GPU acceleration
- [ ] Streaming tokenization
- [ ] Training from corpus

---

## Dependencies

| Dependency | Purpose | Status |
|------------|---------|--------|
| mojo-json | Parse HuggingFace tokenizer.json | Available in mojo-contrib |
| mojo-base64 | Decode tiktoken format | Available in mojo-contrib |
| (none else) | Pure Mojo implementation | - |

---

## Test Strategy

### Unit Tests
- Each pipeline stage independently
- Each tokenizer model (BPE, WordPiece, Unigram)
- Special token handling
- Edge cases (empty input, Unicode, long text)

### Integration Tests
- Full pipeline encode/decode roundtrip
- Comparison with HuggingFace reference outputs
- Chat template formatting

### Performance Tests
- Throughput benchmarks
- Memory usage
- Cache effectiveness

### Compatibility Tests
- Load GPT-2 tokenizer, verify outputs match
- Load Llama tokenizer, verify outputs match
- Load Mistral tokenizer, verify outputs match

---

## References

- [HuggingFace Tokenizers](https://github.com/huggingface/tokenizers) - Rust reference
- [tiktoken](https://github.com/openai/tiktoken) - OpenAI's tokenizer
- [minbpe](https://github.com/karpathy/minbpe) - Educational BPE
- [mojo-json benchmarks](../serialization/mojo-json/benchmarks/) - Performance patterns
