# Mojo 0.25.7 Migration Guide

## Overview

Mojo 0.25.7 introduces several breaking changes that affect the mojo-contrib libraries. This document outlines the required changes and provides patterns for migration.

**Status**: In Progress
**Priority**: mojo-json → mojo-tokenizer → other libs

---

## Breaking Changes Summary

| Change | Impact | Fix |
|--------|--------|-----|
| Tuple type syntax | High | `(A, B)` → `Tuple[A, B]` |
| Struct traits for List | High | Add `Copyable, Movable` |
| `owned` keyword | Medium | Replace with `deinit` |
| Global variables | Medium | Use functions/constants |
| `time.now` | Low | Use `time.perf_counter_ns` |
| `UnsafePointer` | Low | Specify `mut` parameter |

---

## Detailed Migration Patterns

### 1. Tuple Return Types

**Before (broken):**
```mojo
fn load_data() -> (Vocabulary, SpecialTokens):
    return (vocab, special)
```

**After (fixed):**
```mojo
fn load_data() -> Tuple[Vocabulary, SpecialTokens]:
    return Tuple(vocab^, special^)
```

**Notes:**
- Type annotation changes from `(A, B)` to `Tuple[A, B]`
- Return statement changes from `(a, b)` to `Tuple(a, b)`
- Use `^` for move semantics when returning owned values
- Tuple unpacking syntax: `var result = fn(); var a = result[0]; var b = result[1]`

### 2. Struct Trait Conformance

**Before (broken):**
```mojo
struct MyStruct:
    var name: String
    var value: Int
```

**After (fixed):**
```mojo
struct MyStruct(Copyable, Movable):
    var name: String
    var value: Int

    fn __copyinit__(out self, existing: Self):
        self.name = existing.name
        self.value = existing.value

    fn __moveinit__(out self, owned existing: Self):
        self.name = existing.name^
        self.value = existing.value
```

**When needed:**
- Any struct used in `List[T]`
- Any struct used in `Tuple[T, ...]`
- Any struct returned by value that might need copying

**Pattern for fields:**
- String: Use `^` for move, no suffix for copy
- Int/Float/Bool: No `^` needed (trivially copyable)
- Dict/List: Use `^` for move

### 3. `owned` → `deinit` Keyword

**Before:**
```mojo
fn __moveinit__(out self, owned existing: Self):
```

**After:**
```mojo
fn __moveinit__(out self, deinit existing: Self):
```

### 4. Global Variables Not Supported

**Before (broken):**
```mojo
var _decode_table: List[Int]
_decode_table = _init_table()
```

**After (fixed):**
```mojo
fn _get_decode_table() -> List[Int]:
    var table = List[Int](capacity=256)
    # Initialize...
    return table^

# Or use compile-time alias for constants:
alias DECODE_TABLE_SIZE = 256
```

### 5. Time Functions

**Before:**
```mojo
from time import now
var start = now()
```

**After:**
```mojo
from time import perf_counter_ns
var start = perf_counter_ns()
```

### 6. UnsafePointer Changes

**Before:**
```mojo
var ptr: UnsafePointer[MyType]
```

**After:**
```mojo
# For immutable pointer:
var ptr: UnsafePointer[MyType, mut=False]

# Or avoid UnsafePointer when possible by copying data
```

---

## Library-Specific Status

### mojo-json

| File | Status | Issues |
|------|--------|--------|
| parser.mojo | ✅ Fixed | Doc warnings only |
| serializer.mojo | ✅ Fixed | Doc warnings only |
| value.mojo | ✅ Fixed | - |
| error.mojo | ✅ Fixed | Doc warnings only |
| structural_index.mojo | ✅ Fixed | Doc warning only |
| lazy_parser.mojo | ⚠️ WIP | UnsafePointer syntax |

### mojo-tokenizer

| File | Status | Issues |
|------|--------|--------|
| bpe.mojo | ⚠️ Partial | Performance optimizations done, needs trait fixes |
| vocab.mojo | ⚠️ Partial | Needs Copyable/Movable |
| special_tokens.mojo | ❌ Pending | Needs Copyable/Movable |
| formats/tiktoken.mojo | ⚠️ Partial | Tuple syntax fixed |
| formats/huggingface.mojo | ⚠️ Partial | Tuple syntax fixed |
| chat/template.mojo | ⚠️ Partial | ChatMessage fixed |
| benchmark/runner.mojo | ❌ Pending | Multiple issues |
| encoding/base64.mojo | ❌ Pending | Global var issue |

### Other Libraries

| Library | Status | Priority |
|---------|--------|----------|
| mojo-base64 | ❌ Pending | Medium |
| mojo-msgpack | ❌ Pending | Medium |
| mojo-crypto | ❌ Pending | Low |
| mojo-http | ❌ Pending | Low |

---

## Automated Migration Script (TODO)

```bash
# Find all tuple return types
grep -rn "-> (" --include="*.mojo" src/

# Find all structs needing traits
grep -rn "struct.*:" --include="*.mojo" src/ | grep -v "Copyable"

# Find owned keyword usage
grep -rn "owned " --include="*.mojo" src/

# Find global variables
grep -rn "^var " --include="*.mojo" src/
```

---

## Testing After Migration

```bash
# Build package
mojo package src -o /tmp/package.mojopkg

# Run tests (if available)
mojo run tests/test_*.mojo

# Check for warnings (should be minimal)
mojo build src/__init__.mojo 2>&1 | grep -c "warning"
```

---

## Notes

1. **Prioritize core functionality**: Fix parse/serialize before lazy_parser
2. **Document warnings are OK**: Mojo is strict about docstring formatting
3. **Test incrementally**: Build after each major change
4. **Keep backwards compatibility**: Don't change public API signatures

---

*Last updated: January 2026*
