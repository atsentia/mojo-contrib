"""Test mojo-tape implementation."""

from src.tape import Tape, TapeEntry, TAPE_STRING, TAPE_INT64, TAPE_TRUE, TAPE_NULL


fn test_tape_entry() raises -> Bool:
    """Test TapeEntry creation and access."""
    print("Testing TapeEntry...")

    # Create entry with type and payload
    var entry = TapeEntry.create(TAPE_STRING, 12345)
    if entry.type_tag() != TAPE_STRING:
        print("  FAIL: Wrong type tag")
        return False
    if entry.payload() != 12345:
        print("  FAIL: Wrong payload")
        return False

    print("  OK: type_tag =", chr(Int(entry.type_tag())), "payload =", entry.payload())
    return True


fn test_tape_scalars() raises -> Bool:
    """Test tape with scalar values."""
    print("\nTesting scalar values...")

    var tape = Tape()
    tape.append_root()
    tape.append_null()
    tape.append_true()
    tape.append_false()
    tape.append_int64(42)
    tape.append_double(3.14159)
    tape.finalize()

    print("  Tape length:", len(tape))
    print("  Memory usage:", tape.memory_usage(), "bytes")

    # Check values
    var int_val = tape.get_int64(4)  # Index 4 is the INT64 entry
    if int_val != 42:
        print("  FAIL: Wrong int64 value:", int_val)
        return False

    print("  OK: int64 =", int_val)
    return True


fn test_tape_strings() raises -> Bool:
    """Test tape with string values."""
    print("\nTesting strings...")

    var tape = Tape()
    tape.append_root()
    _ = tape.append_string("hello")
    _ = tape.append_string("world")
    _ = tape.append_string("mojo-tape")
    tape.finalize()

    print("  Tape length:", len(tape))
    print("  String buffer size:", len(tape.string_buffer))

    # Check strings
    var entry1 = tape.get_entry(1)
    var s1 = tape.get_string(entry1.payload())
    if s1 != "hello":
        print("  FAIL: Wrong string:", s1)
        return False

    var entry2 = tape.get_entry(2)
    var s2 = tape.get_string(entry2.payload())
    if s2 != "world":
        print("  FAIL: Wrong string:", s2)
        return False

    print("  OK: strings =", s1, ",", s2)
    return True


fn test_tape_array() raises -> Bool:
    """Test tape with array structure."""
    print("\nTesting array...")

    # Build tape for [1, 2, 3]
    var tape = Tape()
    tape.append_root()
    var arr_start = tape.start_array()
    tape.append_int64(1)
    tape.append_int64(2)
    tape.append_int64(3)
    tape.end_array(arr_start)
    tape.finalize()

    print("  Tape length:", len(tape))

    # Check array bounds are linked
    var start_entry = tape.get_entry(1)  # START_ARRAY
    var end_entry = tape.get_entry(start_entry.payload())  # END_ARRAY

    if start_entry.type_tag() != ord('['):
        print("  FAIL: Wrong start tag")
        return False

    if end_entry.type_tag() != ord(']'):
        print("  FAIL: Wrong end tag")
        return False

    print("  OK: array start->end linked correctly")
    return True


fn test_tape_object() raises -> Bool:
    """Test tape with object structure."""
    print("\nTesting object...")

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

    print("  Tape length:", len(tape))

    # Dump for visual inspection
    tape.dump()

    print("  OK")
    return True


fn test_skip_value() raises -> Bool:
    """Test skip_value navigation."""
    print("\nTesting skip_value...")

    # Build tape for [1, [2, 3], 4]
    var tape = Tape()
    tape.append_root()
    var outer_start = tape.start_array()
    tape.append_int64(1)           # Index 2-3
    var inner_start = tape.start_array()  # Index 4
    tape.append_int64(2)           # Index 5-6
    tape.append_int64(3)           # Index 7-8
    tape.end_array(inner_start)    # Index 9
    tape.append_int64(4)           # Index 10-11
    tape.end_array(outer_start)    # Index 12
    tape.finalize()

    # Skip over the first int (1)
    var idx = 2  # Start at first element
    var next_idx = tape.skip_value(idx)
    print("  Skip int64 at", idx, "-> next at", next_idx)

    # Skip over the inner array [2, 3]
    idx = 4  # Inner array start
    next_idx = tape.skip_value(idx)
    print("  Skip array at", idx, "-> next at", next_idx)

    # Should land on int 4
    if next_idx != 10:
        print("  FAIL: Expected next at 10, got", next_idx)
        return False

    print("  OK")
    return True


fn main() raises:
    print("=" * 70)
    print("mojo-tape Tests")
    print("=" * 70)

    var all_passed = True

    all_passed = test_tape_entry() and all_passed
    all_passed = test_tape_scalars() and all_passed
    all_passed = test_tape_strings() and all_passed
    all_passed = test_tape_array() and all_passed
    all_passed = test_tape_object() and all_passed
    all_passed = test_skip_value() and all_passed

    print("\n" + "=" * 70)
    if all_passed:
        print("All mojo-tape tests PASSED")
    else:
        print("Some tests FAILED")
    print("=" * 70)
