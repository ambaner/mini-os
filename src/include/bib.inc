; =============================================================================
; bib.inc — Boot Info Block (BIB) field addresses
;
; The BIB is a shared data structure at a fixed memory address, populated by
; the VBR and used by all subsequent boot stages.  It provides essential
; boot-time information without requiring each stage to re-discover it.
;
; Layout (6 bytes starting at 0x0600):
;   Offset 0: boot_drive  (1 byte)  — BIOS drive number (from MBR's DL)
;   Offset 1: a20_status  (1 byte)  — A20 gate result (1=enabled, 0=failed)
;   Offset 2: part_lba    (4 bytes) — partition start LBA (from VBR header)
; =============================================================================

BIB_DRIVE    equ 0x0600             ; 1 byte: BIOS boot drive number
BIB_A20      equ 0x0601             ; 1 byte: A20 gate status
BIB_PART_LBA equ 0x0602             ; 4 bytes: partition start LBA
