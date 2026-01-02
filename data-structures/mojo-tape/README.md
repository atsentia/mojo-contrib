# mojo-tape

A high-performance flat tape data structure for Mojo, inspired by simdjson.

## Overview

mojo-tape provides a flat, contiguous data structure for representing parsed data (like JSON) without Dict/List allocations. It's designed to work efficiently on both **CPU and GPU** via Apple Silicon's unified memory architecture.

## Key Features

- **Zero Allocation Parsing**: Pre-allocate tape once, reuse for parsing
- **O(1) Random Access**: Jump to any value directly via tape indices
- **Flat Memory Layout**: GPU-friendly, cache-efficient
- **Unified Memory Support**: Works on Apple Silicon CPU and GPU without copying

## Performance

| Operation | Traditional (Dict/List) | mojo-tape |
|-----------|------------------------|-----------|
| Parse 1MB JSON | 10+ MB allocations | 2MB flat buffer |
| Access nested value | O(depth) lookups | O(1) direct access |
| Memory locality | Scattered pointers | Contiguous cache-friendly |

## Tape Format

Each entry is 64 bits: `[8-bit type tag | 56-bit payload]`

```
Type Tags:
  'r' = ROOT (payload: tape length)
  '[' = START_ARRAY (payload: matching ] index)
  ']' = END_ARRAY (payload: matching [ index)
  '{' = START_OBJECT (payload: matching } index)
  '}' = END_OBJECT (payload: matching { index)
  '"' = STRING (payload: string buffer offset)
  'l' = INT64 (next entry contains raw value)
  'd' = DOUBLE (next entry contains raw value)
  't' = TRUE
  'f' = FALSE
  'n' = NULL
```

## Example

```mojo
from mojo_tape import Tape

# Build tape for {"name": "Alice", "age": 30}
var tape = Tape()
tape.append_root()
var obj_start = tape.start_object()
_ = tape.append_string("name")
_ = tape.append_string("Alice")
_ = tape.append_string("age")
tape.append_int64(30)
tape.end_object(obj_start)
tape.finalize()

# Access values directly
tape.dump()
# Output:
# [0] root (len=8)
# [1] { (end=7)
# [2] string -> "name"
# [3] string -> "Alice"
# [4] string -> "age"
# [5] int64 = 30
# [6] <raw value>
# [7] } (start=1)
```

## GPU Usage (Apple Silicon)

mojo-tape is designed for Apple Silicon's unified memory:

```mojo
# Allocate in unified memory (accessible by both CPU and GPU)
var tape = Tape(capacity=100000)

# GPU kernel can read tape entries directly
fn gpu_process_tape(tape_ptr: Pointer[TapeEntry], n: Int):
    var tid = thread_idx.x + block_idx.x * block_dim.x
    if tid < n:
        var entry = tape_ptr[tid]
        # Process entry...

# No explicit CPU→GPU copy needed on Apple Silicon
```

## Integration with mojo-json

mojo-tape will be used by mojo-json for Phase 3 optimization:

```mojo
from mojo_json import parse_to_tape
from mojo_tape import Tape

var tape = parse_to_tape('{"key": "value"}')
# Now access values via tape without Dict/List overhead
```

## Status

- [x] Core `Tape` and `TapeEntry` structures
- [x] Builder methods (append_*, start/end_array/object)
- [x] Reader methods (get_string, get_int64, get_double)
- [x] Navigation (skip_value)
- [ ] GPU kernel examples
- [ ] mojo-json integration
- [ ] Lazy value access API

## License

Apache 2.0 (same as mojo-contrib)
