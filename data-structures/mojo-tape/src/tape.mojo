"""
mojo-tape: Flat Tape Data Structure for High-Performance Parsing

A simdjson-inspired tape data structure for efficient data representation.
Works on both CPU and GPU via Apple Silicon unified memory.

Key Benefits:
- Zero allocation during parsing (pre-allocated tape)
- O(1) random access to any element
- Flat memory layout (GPU-friendly)
- Cache-efficient iteration

Tape Entry Format (64-bit):
  [8-bit type tag | 56-bit payload]

Type Tags:
  'r' = ROOT (payload: tape length)
  '[' = START_ARRAY (payload: matching ] position)
  ']' = END_ARRAY (payload: matching [ position)
  '{' = START_OBJECT (payload: matching } position)
  '}' = END_OBJECT (payload: matching { position)
  '"' = STRING (payload: string buffer offset)
  'l' = INT64 (next entry contains value)
  'd' = DOUBLE (next entry contains value)
  't' = TRUE
  'f' = FALSE
  'n' = NULL

Example tape for {"name": "Alice", "age": 30}:
  [0] ROOT (len=12)
  [1] START_OBJECT (end=11)
  [2] STRING "name"
  [3] STRING "Alice"
  [4] STRING "age"
  [5] INT64
  [6] <raw int value: 30>
  [7] END_OBJECT (start=1)
"""

from memory import bitcast

# Type tag constants (8-bit, fits in high byte of UInt64)
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

# Payload mask (56 bits)
alias PAYLOAD_MASK: UInt64 = 0x00FFFFFFFFFFFFFF


@register_passable("trivial")
struct TapeEntry:
    """
    A single 64-bit tape entry.

    Layout: [type_tag (8 bits) | payload (56 bits)]
    """
    var data: UInt64

    fn __init__(out self, data: UInt64 = 0):
        """Create from raw data."""
        self.data = data

    @staticmethod
    fn create(type_tag: UInt8, payload: Int = 0) -> Self:
        """Create entry with type and payload."""
        var tag_shifted = UInt64(type_tag) << 56
        var payload_masked = UInt64(payload) & PAYLOAD_MASK
        return TapeEntry(tag_shifted | payload_masked)

    @always_inline
    fn type_tag(self) -> UInt8:
        """Get the 8-bit type tag."""
        return UInt8(self.data >> 56)

    @always_inline
    fn payload(self) -> Int:
        """Get the 56-bit payload as Int."""
        return Int(self.data & PAYLOAD_MASK)

    @always_inline
    fn raw_u64(self) -> UInt64:
        """Get raw 64-bit value (for storing int/float values)."""
        return self.data

    fn is_container_start(self) -> Bool:
        """Check if this is start of array or object."""
        var tag = self.type_tag()
        return tag == TAPE_START_ARRAY or tag == TAPE_START_OBJECT

    fn is_container_end(self) -> Bool:
        """Check if this is end of array or object."""
        var tag = self.type_tag()
        return tag == TAPE_END_ARRAY or tag == TAPE_END_OBJECT

    fn is_string(self) -> Bool:
        """Check if this is a string entry."""
        return self.type_tag() == TAPE_STRING

    fn is_number(self) -> Bool:
        """Check if this is a number entry."""
        var tag = self.type_tag()
        return tag == TAPE_INT64 or tag == TAPE_DOUBLE

    fn type_name(self) -> String:
        """Get human-readable type name."""
        var tag = self.type_tag()
        if tag == TAPE_ROOT:
            return "root"
        elif tag == TAPE_START_ARRAY:
            return "["
        elif tag == TAPE_END_ARRAY:
            return "]"
        elif tag == TAPE_START_OBJECT:
            return "{"
        elif tag == TAPE_END_OBJECT:
            return "}"
        elif tag == TAPE_STRING:
            return "string"
        elif tag == TAPE_INT64:
            return "int64"
        elif tag == TAPE_DOUBLE:
            return "double"
        elif tag == TAPE_TRUE:
            return "true"
        elif tag == TAPE_FALSE:
            return "false"
        elif tag == TAPE_NULL:
            return "null"
        else:
            return "unknown"


struct Tape(Movable, Sized):
    """
    A flat tape of 64-bit entries representing parsed data.

    The tape plus string buffer together form a complete representation
    of the parsed document. No Dict/List allocations needed.

    Memory Layout:
    - entries[]: Array of 64-bit TapeEntry values
    - string_buffer[]: Concatenated null-terminated strings

    GPU Compatibility:
    - Flat contiguous memory (no pointers except buffer pointers)
    - Fixed-size entries (8 bytes each)
    - Suitable for unified memory on Apple Silicon
    """

    var entries: List[TapeEntry]
    """Tape entries (type + payload)."""

    var string_buffer: List[UInt8]
    """Concatenated string data (null-terminated)."""

    var current_depth: Int
    """Current nesting depth during construction."""

    fn __init__(out self, capacity: Int = 1024):
        """Create empty tape with pre-allocated capacity."""
        self.entries = List[TapeEntry](capacity=capacity)
        self.string_buffer = List[UInt8](capacity=capacity * 8)
        self.current_depth = 0

    fn __moveinit__(out self, deinit other: Self):
        """Move constructor."""
        self.entries = other.entries^
        self.string_buffer = other.string_buffer^
        self.current_depth = other.current_depth

    fn __len__(self) -> Int:
        """Return number of tape entries."""
        return len(self.entries)

    # =========================================================================
    # Tape Building Methods
    # =========================================================================

    fn append_root(mut self):
        """Append ROOT entry (placeholder, updated at end)."""
        self.entries.append(TapeEntry.create(TAPE_ROOT, 0))

    fn append_null(mut self):
        """Append NULL entry."""
        self.entries.append(TapeEntry.create(TAPE_NULL, 0))

    fn append_true(mut self):
        """Append TRUE entry."""
        self.entries.append(TapeEntry.create(TAPE_TRUE, 0))

    fn append_false(mut self):
        """Append FALSE entry."""
        self.entries.append(TapeEntry.create(TAPE_FALSE, 0))

    fn append_int64(mut self, value: Int64):
        """Append INT64 entry (uses two entries for full value)."""
        self.entries.append(TapeEntry.create(TAPE_INT64, 0))
        # Second entry contains raw value
        self.entries.append(TapeEntry(UInt64(value)))

    fn append_double(mut self, value: Float64):
        """Append DOUBLE entry (uses two entries for full value)."""
        self.entries.append(TapeEntry.create(TAPE_DOUBLE, 0))
        # Second entry contains raw bits
        self.entries.append(TapeEntry(bitcast[DType.uint64](value)))

    fn append_string(mut self, s: String) -> Int:
        """
        Append STRING entry and store string data.

        Returns the string buffer offset for the stored string.
        """
        var offset = len(self.string_buffer)

        # Store string bytes
        for i in range(len(s)):
            self.string_buffer.append(ord(s[i]))
        # Null terminator
        self.string_buffer.append(0)

        self.entries.append(TapeEntry.create(TAPE_STRING, offset))
        return offset

    fn append_string_from_bytes(mut self, data: String, start: Int, end: Int) -> Int:
        """
        Append STRING entry from byte range in source data.

        More efficient than creating intermediate String.
        """
        var offset = len(self.string_buffer)
        var ptr = data.unsafe_ptr()

        # Copy bytes directly
        for i in range(start, end):
            self.string_buffer.append(ptr[i])
        # Null terminator
        self.string_buffer.append(0)

        self.entries.append(TapeEntry.create(TAPE_STRING, offset))
        return offset

    fn start_array(mut self) -> Int:
        """
        Start an array. Returns index to update with end position later.
        """
        var idx = len(self.entries)
        self.entries.append(TapeEntry.create(TAPE_START_ARRAY, 0))
        self.current_depth += 1
        return idx

    fn end_array(mut self, start_idx: Int):
        """End an array, linking back to start."""
        var end_idx = len(self.entries)
        self.entries.append(TapeEntry.create(TAPE_END_ARRAY, start_idx))
        # Update start entry with end position
        self.entries[start_idx] = TapeEntry.create(TAPE_START_ARRAY, end_idx)
        self.current_depth -= 1

    fn start_object(mut self) -> Int:
        """
        Start an object. Returns index to update with end position later.
        """
        var idx = len(self.entries)
        self.entries.append(TapeEntry.create(TAPE_START_OBJECT, 0))
        self.current_depth += 1
        return idx

    fn end_object(mut self, start_idx: Int):
        """End an object, linking back to start."""
        var end_idx = len(self.entries)
        self.entries.append(TapeEntry.create(TAPE_END_OBJECT, start_idx))
        # Update start entry with end position
        self.entries[start_idx] = TapeEntry.create(TAPE_START_OBJECT, end_idx)
        self.current_depth -= 1

    fn finalize(mut self):
        """Finalize tape by updating ROOT entry with length."""
        if len(self.entries) > 0:
            self.entries[0] = TapeEntry.create(TAPE_ROOT, len(self.entries))

    # =========================================================================
    # Tape Reading Methods
    # =========================================================================

    fn get_entry(self, idx: Int) -> TapeEntry:
        """Get tape entry at index."""
        return self.entries[idx]

    fn get_string(self, offset: Int) -> String:
        """Get string from buffer at offset."""
        # Find null terminator
        var end = offset
        while end < len(self.string_buffer) and self.string_buffer[end] != 0:
            end += 1

        # Build string
        var result = String("")
        for i in range(offset, end):
            result += chr(Int(self.string_buffer[i]))
        return result

    fn get_int64(self, idx: Int) -> Int64:
        """Get INT64 value from tape (reads next entry too)."""
        var entry = self.entries[idx]
        if entry.type_tag() == TAPE_INT64 and idx + 1 < len(self.entries):
            return Int64(self.entries[idx + 1].raw_u64())
        return 0

    fn get_double(self, idx: Int) -> Float64:
        """Get DOUBLE value from tape (reads next entry too)."""
        var entry = self.entries[idx]
        if entry.type_tag() == TAPE_DOUBLE and idx + 1 < len(self.entries):
            return bitcast[DType.float64](self.entries[idx + 1].raw_u64())
        return 0.0

    fn skip_value(self, idx: Int) -> Int:
        """
        Skip over a value and return index of next value.

        For containers, jumps to matching end bracket.
        For scalars, advances by 1 (or 2 for int64/double).
        """
        var entry = self.entries[idx]
        var tag = entry.type_tag()

        if tag == TAPE_START_ARRAY or tag == TAPE_START_OBJECT:
            # Jump to matching end bracket + 1
            return entry.payload() + 1
        elif tag == TAPE_INT64 or tag == TAPE_DOUBLE:
            # Skip type entry + value entry
            return idx + 2
        else:
            # Single entry value
            return idx + 1

    # =========================================================================
    # Debug / Statistics
    # =========================================================================

    fn memory_usage(self) -> Int:
        """Return total memory usage in bytes."""
        var entries_bytes = len(self.entries) * 8  # 8 bytes per entry
        var string_bytes = len(self.string_buffer)
        return entries_bytes + string_bytes

    fn dump(self, max_entries: Int = 20):
        """Print tape contents for debugging."""
        print("Tape: ", len(self.entries), " entries, ", self.memory_usage(), " bytes")
        print("-" * 50)

        var count = min(len(self.entries), max_entries)
        for i in range(count):
            var entry = self.entries[i]
            var tag = entry.type_tag()
            var payload = entry.payload()

            var line = String("[") + String(i) + "] " + entry.type_name()

            if tag == TAPE_STRING:
                line += " -> \"" + self.get_string(payload) + "\""
            elif tag == TAPE_INT64 and i + 1 < len(self.entries):
                line += " = " + String(self.get_int64(i))
            elif tag == TAPE_DOUBLE and i + 1 < len(self.entries):
                line += " = " + String(self.get_double(i))
            elif tag == TAPE_START_ARRAY or tag == TAPE_START_OBJECT:
                line += " (end=" + String(payload) + ")"
            elif tag == TAPE_END_ARRAY or tag == TAPE_END_OBJECT:
                line += " (start=" + String(payload) + ")"
            elif tag == TAPE_ROOT:
                line += " (len=" + String(payload) + ")"

            print(line)

        if len(self.entries) > max_entries:
            print("... (", len(self.entries) - max_entries, " more entries)")
