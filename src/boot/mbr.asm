; =============================================================================
; Mini-OS Master Boot Record
; A minimal 16-bit x86 bootloader that prints "mini-os" and halts.
; Assembled with NASM:  nasm -f bin -o mbr.bin src/boot/mbr.asm
; =============================================================================

[BITS 16]
[ORG 0x7C00]

start:
    ; Set up a known-good segment environment
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00              ; stack grows downward from load address

    ; Clear the screen (set video mode 3 — 80x25 text)
    mov ax, 0x0003
    int 0x10

    ; Print the banner
    mov si, msg
    call print_string

    ; Nothing left to do — halt the CPU
    cli
    hlt

; -----------------------------------------------------------------------------
; print_string — write a NUL-terminated string at DS:SI via BIOS teletype
; -----------------------------------------------------------------------------
print_string:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0E                ; BIOS teletype output
    xor bh, bh                  ; page 0
    int 0x10
    jmp print_string
.done:
    ret

; -----------------------------------------------------------------------------
; Data
; -----------------------------------------------------------------------------
msg db 'mini-os', 13, 10, 0     ; CR+LF after the string

; Pad the rest of the 512-byte sector with zeroes and stamp the boot signature
times 510 - ($ - $$) db 0
dw 0xAA55
