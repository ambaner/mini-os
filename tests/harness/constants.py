"""Memory constants mirroring src/include/memory.inc and syscalls.inc.

Keep these in sync with the assembly definitions.  If a constant changes in
the .inc file, update it here too.
"""

# --- Shell ABI region (0x7F00–0x7FFF) ----------------------------------------
SHELL_SAVED_SP   = 0x7FFE
SHELL_ARGS_PTR   = 0x7FFC

# --- Parsed argument table (Layer 2) -----------------------------------------
ARGV_TABLE       = 0x7F00
ARGV_ARGC        = 0x7F00  # 1 byte: argument count
ARGV_PTRS        = 0x7F02  # 16 word pointers (32 bytes)
ARGV_STORAGE     = 0x7F22  # NUL-separated arg strings
ARGV_STORAGE_END = 0x7FFB
ARGV_MAX_ARGS    = 15

# --- Run command data (relative to data segment in stub) ----------------------
# These are offsets within the stub binary's data area, set by the stub itself.
# The stub defines labels for run_fname_buf, run_ext_provided, etc.

# --- Test harness defaults ----------------------------------------------------
CODE_BASE        = 0x1000   # Where stub binaries are loaded
STACK_TOP        = 0xFFF0   # Initial SP
STRING_AREA      = 0x5000   # Where test input strings are placed
