; =============================================================================
; Mini-OS Volume Boot Record (VBR) - Stage 1 Loader
;
; This is the first-stage bootloader within the partition.  The MBR loads
; this code from the partition's first sector(s) into memory at 0x7C00.
;
; The VBR's only job is to load LOADER.BIN from a fixed offset within the
; partition, populate the Boot Info Block (BIB), and transfer control to it.
;
; VBR Header layout (starts at byte 0 of the partition):
;   Offset 0:   EB xx      JMP SHORT past the header
;   Offset 2:   90         NOP (standard boot sector padding)
;   Offset 3:   'MNOS'     Magic identifier (4 bytes)
;   Offset 7:   dw 2       Boot area size in sectors (MBR reads this)
;   Offset 9:   dd 0       Partition start LBA (stamped by create-disk.ps1)
;
; Boot Info Block (BIB) at 0x0600:
;   Offset 0:   boot_drive  (1 byte)  — BIOS drive number from DL
;   Offset 1:   a20_status  (1 byte)  — set by LOADER.BIN
;   Offset 2:   part_lba    (4 bytes) — partition start LBA
;
; Partition disk layout:
;   Offset 0:  VBR         (2 sectors)
;   Offset 4:  LOADER.BIN  (up to 16 sectors)
;   Offset 20: KERNEL.BIN  (up to 16 sectors)
;   Offset 36: SHELL.BIN   (up to 32 sectors)
;
; Assembled with:  nasm -f bin -o vbr.bin src/boot/vbr.asm
; =============================================================================

%include "bib.inc"
%include "memory.inc"
%include "disk.inc"

[BITS 16]                           ; 16-bit real mode
[ORG 0x7C00]                        ; MBR copies us here before jumping

; =============================================================================
; VBR HEADER  (Sector 0 — first 512 bytes)
; =============================================================================
    jmp short vbr_trampoline        ; 2 bytes: EB 0B — skip header fields
    nop                             ; 1 byte:  90    — standard filler

vbr_magic       db 'MNOS'          ; 4-byte magic identifier for mini-os
vbr_sectors     dw 2               ; Boot area = 2 sectors = 1 KB
vbr_part_lba    dd 0               ; Partition start LBA (stamped at build)

vbr_trampoline:
    jmp near vbr_code              ; 3 bytes: E9 xx xx — near jump to sector 1

; Pad sector 0 and place the boot signature at offset 510
times 510 - ($ - $$) db 0
dw 0xAA55

; =============================================================================
; VBR CODE — Sector 1 (offset 512 onward)
;
; At this point, the MBR has already:
;   - Set DS, ES, SS to 0, SP to 0x7C00
;   - Placed the boot drive number in DL
;   - Loaded all VBR sectors and copied them to 0x7C00
; =============================================================================
vbr_code:
    ; --- Populate Boot Info Block (BIB) at 0x0600 ----------------------------
    mov [BIB_DRIVE], dl             ; Save boot drive from MBR

    mov eax, [vbr_part_lba]         ; Read partition LBA from our header
    mov [BIB_PART_LBA], eax         ; Store in BIB for loader and shell

    mov byte [BIB_A20], 0           ; Clear A20 status (loader will set it)

    ; --- Load LOADER.BIN using shared load_mnex subroutine -------------------
    mov eax, LOADER_PART_OFF        ; Partition-relative sector offset
    mov bx, LOADER_OFF              ; Load address (segment 0x0000)
    mov ecx, 'MNLD'                 ; Expected magic signature
    mov dh, LOADER_MAX_SEC          ; Maximum sector count
    call load_mnex
    jc .load_err

    ; --- Jump to LOADER.BIN -------------------------------------------------
    jmp LOADER_SEG:LOADER_OFF       ; Far jump to loader at 0x0000:0x0800

; --- Error handler -----------------------------------------------------------
.load_err:
    mov si, msg_err
    call puts
.halt:
    cli
    hlt

; --- Shared binary loader (from src/include/load_binary.inc) -----------------
%include "load_binary.inc"

; --- Subroutines (minimal, just what VBR needs) ------------------------------

; puts — Print NUL-terminated string at DS:SI
puts:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    jmp puts
.done:
    ret

; --- Data --------------------------------------------------------------------
msg_err     db 'VBR: Load error', 0

; --- Disk Address Packet (DAP) for INT 13h AH=42h ---------------------------
dap:
    db 0x10, 0                      ; Size = 16 bytes, reserved = 0
dap_sectors:
    dw 1                            ; Sectors to read (updated at runtime)
dap_buffer:
    dw 0, 0                         ; Buffer address (set by load_mnex)
dap_lba:
    dd 0, 0                         ; LBA — computed at runtime

; Pad to exactly 2 sectors (1024 bytes)
times (2 * 512) - ($ - $$) db 0
