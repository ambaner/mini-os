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

[BITS 16]                           ; 16-bit real mode
[ORG 0x7C00]                        ; MBR copies us here before jumping

; =============================================================================
; CONSTANTS
; =============================================================================
LOADER_SEG      equ 0x0000          ; Segment for LOADER.BIN load address
LOADER_OFF      equ 0x0800          ; Offset for LOADER.BIN load address
LOADER_PART_OFF equ 4               ; Partition-relative sector offset
LOADER_MAX_SEC  equ 16              ; Maximum sectors for LOADER.BIN

BIB_ADDR        equ 0x0600          ; Boot Info Block base address
BIB_DRIVE       equ 0x0600          ; 1 byte: boot drive
BIB_A20         equ 0x0601          ; 1 byte: A20 status (set by loader)
BIB_PART_LBA    equ 0x0602          ; 4 bytes: partition start LBA

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

    ; --- Calculate absolute LBA of LOADER.BIN --------------------------------
    ; LOADER.BIN starts at partition offset LOADER_PART_OFF sectors
    add eax, LOADER_PART_OFF        ; EAX = partition_lba + loader_offset
    mov [dap_lba], eax              ; Store in DAP for disk read

    ; --- Load LOADER.BIN to 0x0800 ------------------------------------------
    mov word [dap_sectors], 1       ; First: load just sector 0 (header)
    mov word [dap_buffer], LOADER_OFF
    mov word [dap_buffer+2], LOADER_SEG

    mov dl, [BIB_DRIVE]
    mov si, dap
    mov ah, 0x42                    ; Extended Read Sectors
    int 0x13
    jc .disk_err

    ; --- Verify LOADER.BIN magic ('MNLD') ------------------------------------
    cmp dword [LOADER_OFF], 'MNLD'
    jne .bad_loader

    ; --- Read sector count from LOADER.BIN header and reload all sectors -----
    mov cx, [LOADER_OFF + 4]        ; CX = loader sector count
    test cx, cx
    jz .bad_loader
    cmp cx, LOADER_MAX_SEC
    ja .bad_loader

    mov [dap_sectors], cx           ; Load all loader sectors
    mov eax, [BIB_PART_LBA]
    add eax, LOADER_PART_OFF
    mov [dap_lba], eax              ; Reset LBA (same as before)

    mov dl, [BIB_DRIVE]
    mov si, dap
    mov ah, 0x42
    int 0x13
    jc .disk_err

    ; --- Jump to LOADER.BIN -------------------------------------------------
    jmp LOADER_SEG:LOADER_OFF       ; Far jump to loader at 0x0000:0x0800

; --- Error handlers ----------------------------------------------------------
.disk_err:
    mov si, msg_derr
    jmp .err_print
.bad_loader:
    mov si, msg_noload
.err_print:
    call puts
.halt:
    cli
    hlt

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
msg_derr    db 'VBR: Disk err', 0
msg_noload  db 'VBR: No loader', 0

; --- Disk Address Packet (DAP) for INT 13h AH=42h ---------------------------
dap:
    db 0x10, 0                      ; Size = 16 bytes, reserved = 0
dap_sectors:
    dw 1                            ; Sectors to read (updated at runtime)
dap_buffer:
    dw LOADER_OFF, LOADER_SEG       ; Load to LOADER_SEG:LOADER_OFF
dap_lba:
    dd 0, 0                         ; LBA — computed at runtime

; Pad to exactly 2 sectors (1024 bytes)
times (2 * 512) - ($ - $$) db 0
