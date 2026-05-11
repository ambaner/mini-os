; =============================================================================
; Mini-OS Volume Boot Record (VBR)
; Loaded by the MBR from the first sector of the active partition.
; Prints a message and halts.
; Assembled with NASM:  nasm -f bin -o vbr.bin src/boot/vbr.asm
; =============================================================================

[BITS 16]
[ORG 0x7C00]

vbr_start:
    ; Segments and stack are already set up by the MBR.
    ; DL contains the boot drive number.

    mov si, msg_vbr
    call print_string

    mov si, msg_done
    call print_string

    cli
    hlt

; -----------------------------------------------------------------------------
; print_string — write NUL-terminated string at DS:SI via BIOS teletype
; -----------------------------------------------------------------------------
print_string:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    jmp print_string
.done:
    ret

; -----------------------------------------------------------------------------
; Data
; -----------------------------------------------------------------------------
msg_vbr db 13, 10, 'In boot sector now', 13, 10, 0
msg_done db 'mini-os boot completed', 13, 10, 0

; Pad to 512 bytes with boot signature
times 510 - ($ - $$) db 0
dw 0xAA55
