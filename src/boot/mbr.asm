; =============================================================================
; Mini-OS Master Boot Record
; Reads the MBR partition table, prints partition info, loads the VBR from the
; active partition, and transfers control to it.
; Assembled with NASM:  nasm -f bin -o mbr.bin src/boot/mbr.asm
; =============================================================================

[BITS 16]
[ORG 0x7C00]

; The BIOS passes the boot drive number in DL — we preserve it throughout.

start:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00

    mov [boot_drive], dl

    ; Clear screen
    mov ax, 0x0003
    int 0x10

    mov si, msg_banner
    call puts

    ; --- Scan partition table ------------------------------------------------
    mov si, msg_reading
    call puts

    mov cx, 4
    mov di, part_table
    mov bl, '1'                 ; partition number character
    mov word [active_entry], 0

.scan:
    push cx

    ; Print "  P#: "
    mov al, ' '
    call putc
    call putc
    mov al, 'P'
    call putc
    mov al, bl
    call putc
    mov al, ':'
    call putc
    mov al, ' '
    call putc

    ; Check empty
    mov al, [di+4]
    test al, al
    jz .empty

    ; Check active
    cmp byte [di], 0x80
    jne .not_active
    mov [active_entry], di
    mov al, '*'
    call putc
    jmp .show_type
.not_active:
    mov al, ' '
    call putc

.show_type:
    ; "T=XX L=XXXXXXXX S=XXXXXXXX\r\n"
    mov al, 'T'
    call putc
    mov al, '='
    call putc
    mov al, [di+4]
    call puthex8

    mov al, ' '
    call putc
    mov al, 'L'
    call putc
    mov al, '='
    call putc
    mov al, [di+11]
    call puthex8
    mov al, [di+10]
    call puthex8
    mov al, [di+9]
    call puthex8
    mov al, [di+8]
    call puthex8

    mov al, ' '
    call putc
    mov al, 'S'
    call putc
    mov al, '='
    call putc
    mov al, [di+15]
    call puthex8
    mov al, [di+14]
    call puthex8
    mov al, [di+13]
    call puthex8
    mov al, [di+12]
    call puthex8
    jmp .eol

.empty:
    mov si, msg_none
    call puts
    jmp .next

.eol:
    mov si, msg_crlf
    call puts

.next:
    add di, 16
    inc bl
    pop cx
    dec cx
    jnz .scan

    ; --- Load VBR from active partition --------------------------------------
    mov si, [active_entry]
    test si, si
    jz .no_active

    mov si, msg_load
    call puts

    ; Fill DAP with active partition's LBA
    mov si, [active_entry]
    mov eax, [si+8]
    mov [dap_lba], eax

    mov dl, [boot_drive]
    mov si, dap
    mov ah, 0x42
    int 0x13
    jc .disk_err

    ; Copy VBR from 0x7E00 to 0x7C00 and jump
    cld
    mov si, 0x7E00
    mov di, 0x7C00
    mov cx, 256
    rep movsw
    mov dl, [boot_drive]
    jmp 0x0000:0x7C00

.no_active:
    mov si, msg_noact
    call puts
    jmp .halt
.disk_err:
    mov si, msg_derr
    call puts
.halt:
    cli
    hlt

; =============================================================================
; Subroutines
; =============================================================================

; puts — print NUL-terminated string at DS:SI
puts:
    lodsb
    test al, al
    jz .d
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    jmp puts
.d: ret

; putc — print char in AL
putc:
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    ret

; puthex8 — print AL as two hex digits
puthex8:
    push ax
    shr al, 4
    call .nib
    pop ax
    and al, 0x0F
.nib:
    add al, '0'
    cmp al, '9'
    jbe putc
    add al, 7
    jmp putc

; =============================================================================
; Data
; =============================================================================
msg_banner  db 'In MBR', 13, 10, 0
msg_reading db 'Partitions:', 13, 10, 0
msg_none    db '--', 13, 10, 0
msg_crlf    db 13, 10, 0
msg_load    db 'Loading VBR...', 0
msg_noact   db 'No active partition', 0
msg_derr    db 'Disk read error', 0

boot_drive  db 0
active_entry dw 0

; DAP for INT 13h AH=42h
dap:
    db 0x10, 0                  ; size, reserved
    dw 1                        ; sectors to read
    dw 0x7E00, 0x0000           ; offset:segment (load to 0x7E00)
dap_lba:
    dd 0, 0                     ; LBA (filled at runtime)

; Pad to partition table
times 0x1BE - ($ - $$) db 0

; Partition table — 4 × 16 bytes (filled by tools/create-disk.ps1)
part_table:
times 64 db 0

; Boot signature
dw 0xAA55

