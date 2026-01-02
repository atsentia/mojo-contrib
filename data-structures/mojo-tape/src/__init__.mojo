"""mojo-tape: Flat tape data structure for high-performance parsing."""

from .tape import Tape, TapeEntry
from .tape import TAPE_ROOT, TAPE_START_ARRAY, TAPE_END_ARRAY
from .tape import TAPE_START_OBJECT, TAPE_END_OBJECT
from .tape import TAPE_STRING, TAPE_INT64, TAPE_DOUBLE
from .tape import TAPE_TRUE, TAPE_FALSE, TAPE_NULL
