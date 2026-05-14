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
