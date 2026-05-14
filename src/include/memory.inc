; =============================================================================
; memory.inc — Memory layout constants
;
; Defines the segment:offset load addresses for each boot-chain component.
; All components use segment 0x0000 (flat real-mode addressing).
;
; Memory map (low → high):
;   0x0600  Boot Info Block (BIB)   — 6 bytes, shared boot data
;   0x0800  LOADER.BIN              — up to 8 KB (16 sectors)
;   0x3000  SHELL.BIN               — up to 8 KB (16 sectors)
;   0x5000  KERNEL.BIN              — up to 8 KB (16 sectors)
;   0x7C00  VBR (boot-time only)    — 1 KB (2 sectors)
;
; See doc/MEMORY-LAYOUT.md for the complete memory map.
; =============================================================================

LOADER_SEG   equ 0x0000             ; Segment for LOADER.BIN
LOADER_OFF   equ 0x0800             ; Offset for LOADER.BIN

KERNEL_SEG   equ 0x0000             ; Segment for KERNEL.BIN
KERNEL_OFF   equ 0x5000             ; Offset for KERNEL.BIN

SHELL_SEG    equ 0x0000             ; Segment for SHELL.BIN
SHELL_OFF    equ 0x3000             ; Offset for SHELL.BIN

; =============================================================================
; Stack canary constants
;
; The stack grows downward from 0x7C00.  The safe stack floor is 0x7000,
; giving ~3 KB of stack space.  We place a 4-byte sentinel ("canary") at
; the very bottom of the stack zone.  If the stack ever grows past 0x7004
; and overwrites the canary, we know a stack overflow occurred.
;
; Layout:
;   0x7000–0x7003  Canary (4 bytes: two copies of 0xDEAD)
;   0x7004–0x7BFF  Usable stack (~3068 bytes)
;   0x7C00         Initial SP (set by MBR, never moved)
;
; The canary value 0xDEAD was chosen because it is visually distinctive
; in hex dumps and unlikely to appear as a legitimate stack value.
; =============================================================================
STACK_CANARY_ADDR  equ 0x7000        ; Linear address of canary (stack floor)
STACK_CANARY_VALUE equ 0xDEAD        ; Sentinel value (written as two words)
STACK_CANARY_SIZE  equ 4             ; Total canary size in bytes

; =============================================================================
; Memory Manager (MNMM) constants
;
; MM.BIN is loaded by the kernel at 0x2800, between the FS.BIN max boundary
; and SHELL.BIN at 0x3000.  It provides heap allocation via INT 0x82.
;
; The heap occupies the unused RAM above all static components:
;   0x8000–0xF7FF (30 KB), managed as a linked list of MCB blocks.
;
; See doc/MEMORY-MANAGER.md for the complete specification.
; =============================================================================
MM_SEG          equ 0x0000           ; Segment for MM.BIN (flat model)
MM_OFF          equ 0x2800           ; Offset for MM.BIN
MM_MAX_SECTORS  equ 4                ; Max 4 sectors (2 KB) before SHELL

HEAP_START      equ 0x8000           ; Heap region start
HEAP_END        equ 0xF800           ; Heap end (exclusive: last usable = 0xF7FF)
HEAP_SIZE       equ HEAP_END - HEAP_START  ; 30,720 bytes (30 KB)

; --- MCB (Memory Control Block) header layout --------------------------------
; Each heap block starts with a 4-byte header:
;   Offset 0: size    (2 bytes) — total block size INCLUDING header
;   Offset 2: flags   (1 byte)  — bit 0: 1=allocated, 0=free
;   Offset 3: magic   (1 byte)  — 'M' (0x4D) for integrity checking
MCB_SIZE_OFF    equ 0                ; Offset of size field in MCB
MCB_FLAGS_OFF   equ 2                ; Offset of flags field in MCB
MCB_MAGIC_OFF   equ 3                ; Offset of magic field in MCB
MCB_HDR_SIZE    equ 4                ; Header size in bytes
MCB_MAGIC       equ 0x4D             ; 'M' — block magic byte
MCB_FLAG_USED   equ 0x01             ; Flag bit: block is allocated
MCB_MIN_BLOCK   equ 8                ; Minimum block: 4 header + 4 payload

; --- INT 0x82 function numbers -----------------------------------------------
; AH = function number before INT 0x82.
;
; MEM_ALLOC: CX = requested size in bytes
;            Returns: BX = pointer to usable memory (past MCB header)
;            CF set on failure (out of memory or invalid size)
;
; MEM_FREE:  BX = pointer previously returned by MEM_ALLOC
;            CF set on failure (invalid pointer, double free, corruption)
;
; MEM_AVAIL: Returns: AX = largest contiguous free block (usable bytes)
;                     DX = total free bytes (usable)
;
; MEM_INFO:  Returns: AX = total heap size, BX = bytes used,
;                     CX = bytes free, DX = total block count
MEM_ALLOC       equ 0x01             ; Allocate memory
MEM_FREE        equ 0x02             ; Free memory
MEM_AVAIL       equ 0x03             ; Query available memory
MEM_INFO        equ 0x04             ; Query heap statistics

MEM_SYSCALL_MAX equ 0x04             ; Highest valid MM syscall number
