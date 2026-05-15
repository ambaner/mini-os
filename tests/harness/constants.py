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

# --- Heap / Memory Manager constants -----------------------------------------
HEAP_START       = 0x8000
HEAP_END         = 0x9000
HEAP_SIZE        = HEAP_END - HEAP_START  # 4096 bytes
MCB_SIZE_OFF     = 0
MCB_FLAGS_OFF    = 2
MCB_MAGIC_OFF    = 3
MCB_HDR_SIZE     = 4
MCB_MAGIC        = 0x4D    # 'M'
MCB_FLAG_USED    = 0x01
MCB_OWNER_SHIFT  = 1
MCB_MIN_BLOCK    = 8       # 4 header + 4 payload minimum

# --- MM stub entry points (offsets from CODE_BASE) ----------------------------
MM_ALLOC_ENTRY   = 0x00
MM_FREE_ENTRY    = 0x10
MM_AVAIL_ENTRY   = 0x20
MM_INFO_ENTRY    = 0x30
MM_INIT_ENTRY    = 0x40

# --- Run command data (relative to data segment in stub) ----------------------
# These are offsets within the stub binary's data area, set by the stub itself.
# The stub defines labels for run_fname_buf, run_ext_provided, etc.

# --- Test harness defaults ----------------------------------------------------
CODE_BASE        = 0x1000   # Where stub binaries are loaded
STACK_TOP        = 0xFFF0   # Initial SP
STRING_AREA      = 0x5000   # Where test input strings are placed
