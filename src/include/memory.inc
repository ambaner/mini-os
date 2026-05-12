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
