; =============================================================================
; Mini-OS Kernel (KERNEL.BIN) - 16-bit Real-Mode Kernel
;
; Loaded by LOADER.BIN into memory at 0x5000.  This is the first component
; in mini-os that acts as a proper kernel:
;
;   1. Installs a syscall handler at INT 0x80 in the IVT
;   2. Loads SHELL.BIN (an MNEX user-mode executable) from disk
;   3. Transfers control to the shell
;
; The shell and all user-mode programs interact with hardware exclusively
; through the INT 0x80 syscall interface.  The kernel wraps BIOS interrupts
; internally, establishing the architectural pattern that carries forward
; to 32-bit (IDT + ring 0) and 64-bit (SYSCALL instruction) modes.
;
; Syscall convention:
;   AH = function number
;   Other registers = function-specific arguments
;   Return: function-specific (AX = result, CF = error)
;
; The Boot Info Block (BIB) at 0x0600 is populated by earlier boot stages:
;   0x0600: boot_drive  (1 byte)  — BIOS drive number
;   0x0601: a20_status  (1 byte)  — A20 gate result (1=enabled, 0=failed)
;   0x0602: part_lba    (4 bytes) — partition start LBA
;
; Header layout (first 6 bytes):
;   Offset 0: 'MNKN'   Magic identifier (4 bytes)
;   Offset 4: dw N     Kernel size in sectors
;
; Assembled with:  nasm -f bin -o kernel.bin src/kernel/kernel.asm
; =============================================================================

[BITS 16]
[ORG 0x5000]                        ; Loader loads us here

; =============================================================================
; CONSTANTS
; =============================================================================
SHELL_SEG       equ 0x0000          ; Segment for SHELL.BIN load address
SHELL_OFF       equ 0x3000          ; Offset for SHELL.BIN load address
SHELL_PART_OFF  equ 36              ; Partition-relative sector offset for shell
SHELL_MAX_SEC   equ 32              ; Maximum sectors for SHELL.BIN

BIB_DRIVE       equ 0x0600          ; Boot drive (from VBR)
BIB_A20         equ 0x0601          ; A20 status (from loader)
BIB_PART_LBA    equ 0x0602          ; Partition start LBA (from VBR)

; --- Syscall function numbers ------------------------------------------------
SYS_PRINT_STRING equ 0x01           ; DS:SI = string pointer
SYS_PRINT_CHAR   equ 0x02           ; AL = character
SYS_READ_KEY     equ 0x03           ; Returns: AH=scancode, AL=ASCII
SYS_READ_SECTOR  equ 0x04           ; EAX=LBA, ES:BX=buffer, CL=count
SYS_GET_VERSION  equ 0x05           ; Returns: AH=major, AL=minor
SYS_CLEAR_SCREEN equ 0x06           ; No args
SYS_SET_CURSOR   equ 0x07           ; DH=row, DL=col
SYS_GET_CURSOR   equ 0x08           ; Returns: DH=row, DL=col
SYS_CHECK_A20    equ 0x09           ; Returns: AL=1 if enabled, 0 if not
SYS_GET_CONV_MEM equ 0x0A           ; Returns: AX=KB of conventional memory
SYS_GET_EXT_MEM  equ 0x0B           ; Returns: AX=KB of extended memory, CF=err
SYS_GET_E820     equ 0x0C           ; EBX=continuation, ES:DI=buf; Returns: EBX, CF
SYS_REBOOT       equ 0x0D           ; Warm reboot (does not return)
SYS_GET_DRIVE_INFO equ 0x0E         ; Returns drive geometry in registers
SYS_GET_BIB      equ 0x0F           ; Returns: ES:BX = BIB address
SYS_PRINT_HEX8   equ 0x10          ; AL = byte to print as hex
SYS_PRINT_HEX16  equ 0x11          ; AX = word to print as hex
SYS_PRINT_DEC16  equ 0x12          ; AX = word to print as decimal
SYS_WAIT_KEY     equ 0x13          ; Print "Press any key...", wait, clear screen
SYS_GET_EQUIP    equ 0x14          ; Returns: AX = equipment word (INT 11h)
SYS_GET_VIDEO    equ 0x15          ; Returns: AL=mode, AH=cols, BH=page
SYS_GET_BDA_BYTE equ 0x16          ; BX=BDA offset; Returns: AL=byte value
SYS_GET_BDA_WORD equ 0x17          ; BX=BDA offset; Returns: AX=word value
SYS_CPUID        equ 0x18          ; EDI=leaf; Returns: EAX,EBX,ECX,EDX
SYS_CHECK_CPUID  equ 0x19          ; Returns: AL=1 if CPUID supported, 0 if not
SYS_GET_EDD      equ 0x1A          ; DL=drive; Returns: EDD info, CF=err
SYS_GET_IVT      equ 0x1B          ; CL=vector#; Returns: AX=offset, DX=segment

; =============================================================================
; KERNEL HEADER
; =============================================================================
kernel_magic    db 'MNKN'           ; Magic identifier — kernel
kernel_sectors  dw 4                ; Kernel size in sectors (updated as needed)

; =============================================================================
; KERNEL ENTRY POINT
; =============================================================================
kernel_start:
    ; --- Install syscall handler at INT 0x80 ----------------------------------
    call install_syscalls

    ; --- Load SHELL.BIN -------------------------------------------------------
    call load_shell
    jc .shell_fail

    ; --- Transfer control to shell --------------------------------------------
    ; The shell is a user-mode executable.  When it calls INT 0x80, the CPU
    ; jumps to our syscall_handler via the IVT entry we installed above.
    jmp SHELL_SEG:SHELL_OFF

.shell_fail:
    ; Shell load failed — print error using direct BIOS (syscalls are installed
    ; but we have no user-mode code to talk to)
    mov si, msg_shell_fail
    call bios_puts
.halt:
    cli
    hlt

; =============================================================================
; install_syscalls — Install the INT 0x80 handler into the IVT
;
; The IVT is a 256-entry array of far pointers at 0x0000:0x0000.
; Each entry is 4 bytes: [offset_lo, offset_hi, segment_lo, segment_hi].
; Vector 0x80 is at address 0x80 * 4 = 0x0200.
; =============================================================================
install_syscalls:
    cli                             ; Disable interrupts while modifying IVT
    push es

    xor ax, ax
    mov es, ax                      ; ES = 0x0000 (IVT segment)

    ; Install our handler at vector 0x80
    mov word [es:0x80*4],   syscall_handler  ; Offset
    mov word [es:0x80*4+2], cs               ; Segment

    pop es
    sti                             ; Re-enable interrupts
    ret

; =============================================================================
; syscall_handler — INT 0x80 dispatcher
;
; Routes syscalls based on AH function number.  Each handler returns via IRET.
; All handlers preserve registers except documented return values.
; =============================================================================
syscall_handler:
    cmp ah, SYS_PRINT_STRING
    je .fn_print_string
    cmp ah, SYS_PRINT_CHAR
    je .fn_print_char
    cmp ah, SYS_READ_KEY
    je .fn_read_key
    cmp ah, SYS_READ_SECTOR
    je .fn_read_sector
    cmp ah, SYS_GET_VERSION
    je .fn_get_version
    cmp ah, SYS_CLEAR_SCREEN
    je .fn_clear_screen
    cmp ah, SYS_SET_CURSOR
    je .fn_set_cursor
    cmp ah, SYS_GET_CURSOR
    je .fn_get_cursor
    cmp ah, SYS_CHECK_A20
    je .fn_check_a20
    cmp ah, SYS_GET_CONV_MEM
    je .fn_get_conv_mem
    cmp ah, SYS_GET_EXT_MEM
    je .fn_get_ext_mem
    cmp ah, SYS_GET_E820
    je .fn_get_e820
    cmp ah, SYS_REBOOT
    je .fn_reboot
    cmp ah, SYS_GET_DRIVE_INFO
    je .fn_get_drive_info
    cmp ah, SYS_GET_BIB
    je .fn_get_bib
    cmp ah, SYS_PRINT_HEX8
    je .fn_print_hex8
    cmp ah, SYS_PRINT_HEX16
    je .fn_print_hex16
    cmp ah, SYS_PRINT_DEC16
    je .fn_print_dec16
    cmp ah, SYS_WAIT_KEY
    je .fn_wait_key
    cmp ah, SYS_GET_EQUIP
    je .fn_get_equip
    cmp ah, SYS_GET_VIDEO
    je .fn_get_video
    cmp ah, SYS_GET_BDA_BYTE
    je .fn_get_bda_byte
    cmp ah, SYS_GET_BDA_WORD
    je .fn_get_bda_word
    cmp ah, SYS_CPUID
    je .fn_cpuid
    cmp ah, SYS_CHECK_CPUID
    je .fn_check_cpuid
    cmp ah, SYS_GET_EDD
    je .fn_get_edd
    cmp ah, SYS_GET_IVT
    je .fn_get_ivt

    ; Unknown function — set carry flag
    stc
    iret

; ─── SYS_PRINT_STRING (AH=0x01) ──────────────────────────────────────────────
; Input:  DS:SI = pointer to null-terminated string
; Output: none
; ──────────────────────────────────────────────────────────────────────────────
.fn_print_string:
    push ax
    push si
    push bx
.ps_loop:
    lodsb
    test al, al
    jz .ps_done
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    jmp .ps_loop
.ps_done:
    pop bx
    pop si
    pop ax
    iret

; ─── SYS_PRINT_CHAR (AH=0x02) ────────────────────────────────────────────────
; Input:  AL = character to print
; Output: none
; ──────────────────────────────────────────────────────────────────────────────
.fn_print_char:
    push ax
    push bx
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    pop bx
    pop ax
    iret

; ─── SYS_READ_KEY (AH=0x03) ──────────────────────────────────────────────────
; Input:  none
; Output: AH = scan code, AL = ASCII character
; ──────────────────────────────────────────────────────────────────────────────
.fn_read_key:
    xor ah, ah
    int 0x16                        ; BIOS keyboard: wait for keypress
    iret

; ─── SYS_READ_SECTOR (AH=0x04) ───────────────────────────────────────────────
; Input:  EAX = absolute LBA sector number
;         ES:BX = buffer to read into
;         CL = number of sectors to read
; Output: CF clear = success, CF set = error
; ──────────────────────────────────────────────────────────────────────────────
.fn_read_sector:
    push si
    push dx

    ; Set up the kernel's DAP
    mov [k_dap_lba], eax
    xor ch, ch
    mov [k_dap_sectors], cx
    mov [k_dap_buffer], bx
    mov [k_dap_buffer+2], es

    mov dl, [BIB_DRIVE]
    mov si, k_dap
    mov ah, 0x42
    int 0x13

    pop dx
    pop si
    iret                            ; CF is set/cleared by BIOS

; ─── SYS_GET_VERSION (AH=0x05) ───────────────────────────────────────────────
; Input:  none
; Output: AH = major version, AL = minor version
; ──────────────────────────────────────────────────────────────────────────────
.fn_get_version:
    mov ax, 0x0500                  ; Version 5.0 (v0.5.0)
    iret

; ─── SYS_CLEAR_SCREEN (AH=0x06) ──────────────────────────────────────────────
; Input:  none
; Output: none (clears screen, sets mode 3)
; ──────────────────────────────────────────────────────────────────────────────
.fn_clear_screen:
    push ax
    mov ax, 0x0003
    int 0x10
    pop ax
    iret

; ─── SYS_SET_CURSOR (AH=0x07) ────────────────────────────────────────────────
; Input:  DH = row, DL = column
; Output: none
; ──────────────────────────────────────────────────────────────────────────────
.fn_set_cursor:
    push ax
    push bx
    mov ah, 0x02
    xor bh, bh
    int 0x10
    pop bx
    pop ax
    iret

; ─── SYS_GET_CURSOR (AH=0x08) ────────────────────────────────────────────────
; Input:  none
; Output: DH = row, DL = column
; ──────────────────────────────────────────────────────────────────────────────
.fn_get_cursor:
    push ax
    push bx
    mov ah, 0x03
    xor bh, bh
    int 0x10                        ; Returns DH=row, DL=col
    pop bx
    pop ax
    iret

; ─── SYS_CHECK_A20 (AH=0x09) ─────────────────────────────────────────────────
; Input:  none
; Output: AL = 1 if A20 enabled, 0 if disabled
; ──────────────────────────────────────────────────────────────────────────────
.fn_check_a20:
    push ds
    push es
    push cx

    xor ax, ax
    mov ds, ax
    mov ax, 0xFFFF
    mov es, ax

    mov al, [ds:0x0500]
    push ax
    mov al, [es:0x0510]
    push ax

    mov byte [es:0x0510], 0x13
    mov byte [ds:0x0500], 0x37

    cmp byte [es:0x0510], 0x37
    je .a20_off
    mov cl, 1
    jmp .a20_restore
.a20_off:
    xor cl, cl

.a20_restore:
    pop ax
    mov [es:0x0510], al
    pop ax
    mov [ds:0x0500], al

    pop cx
    pop es
    pop ds
    mov al, cl
    iret

; ─── SYS_GET_CONV_MEM (AH=0x0A) ──────────────────────────────────────────────
; Input:  none
; Output: AX = conventional memory in KB
; ──────────────────────────────────────────────────────────────────────────────
.fn_get_conv_mem:
    int 0x12                        ; AX = KB of conventional memory
    iret

; ─── SYS_GET_EXT_MEM (AH=0x0B) ───────────────────────────────────────────────
; Input:  none
; Output: AX = extended memory in KB, CF set on error
; ──────────────────────────────────────────────────────────────────────────────
.fn_get_ext_mem:
    mov ah, 0x88
    int 0x15                        ; AX = KB, CF on error
    iret

; ─── SYS_GET_E820 (AH=0x0C) ──────────────────────────────────────────────────
; Input:  EBX = continuation value (0 to start), ES:DI = 20-byte buffer
; Output: EBX = next continuation (0 = done), CF set on error
;         Buffer filled with one E820 entry
; ──────────────────────────────────────────────────────────────────────────────
.fn_get_e820:
    push edx
    mov eax, 0x0000E820
    mov ecx, 20
    mov edx, 0x534D4150             ; 'SMAP'
    int 0x15
    ; Check signature — if EAX != 'SMAP', set CF
    cmp eax, 0x534D4150
    je .e820_ok
    stc
.e820_ok:
    pop edx
    iret

; ─── SYS_REBOOT (AH=0x0D) ────────────────────────────────────────────────────
; Input:  none
; Output: does not return (warm reboot)
; ──────────────────────────────────────────────────────────────────────────────
.fn_reboot:
    mov word [0x0472], 0x1234       ; Warm-reboot flag
    jmp 0xFFFF:0x0000               ; BIOS reset vector

; ─── SYS_GET_DRIVE_INFO (AH=0x0E) ────────────────────────────────────────────
; Input:  none (uses boot drive from BIB)
; Output: CH=cyl_low, CL=sec|cyl_hi, DH=heads, DL=drives, CF on error
; ──────────────────────────────────────────────────────────────────────────────
.fn_get_drive_info:
    mov dl, [BIB_DRIVE]
    mov ah, 0x08
    int 0x13
    iret

; ─── SYS_GET_BIB (AH=0x0F) ───────────────────────────────────────────────────
; Input:  none
; Output: BX = BIB offset (0x0600), ES = 0x0000
; ──────────────────────────────────────────────────────────────────────────────
.fn_get_bib:
    xor ax, ax
    mov es, ax
    mov bx, 0x0600
    iret

; ─── SYS_PRINT_HEX8 (AH=0x10) ───────────────────────────────────────────────
; Input:  AL = byte to print as two hex digits
; Output: none
; ──────────────────────────────────────────────────────────────────────────────
.fn_print_hex8:
    push ax
    push bx
    ; High nibble
    push ax
    shr al, 4
    call .hex_nibble
    pop ax
    ; Low nibble
    and al, 0x0F
    call .hex_nibble
    pop bx
    pop ax
    iret

.hex_nibble:
    add al, '0'
    cmp al, '9'
    jbe .hex_print
    add al, 7
.hex_print:
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    ret

; ─── SYS_PRINT_HEX16 (AH=0x11) ──────────────────────────────────────────────
; Input:  AX = word to print as four hex digits
; Output: none
; ──────────────────────────────────────────────────────────────────────────────
.fn_print_hex16:
    push ax
    push bx
    push ax
    mov al, ah
    ; High byte, high nibble
    push ax
    shr al, 4
    call .hex_nibble
    pop ax
    and al, 0x0F
    call .hex_nibble
    ; Low byte
    pop ax
    push ax
    shr al, 4
    call .hex_nibble
    pop ax
    and al, 0x0F
    call .hex_nibble
    pop bx
    pop ax
    iret

; ─── SYS_PRINT_DEC16 (AH=0x12) ──────────────────────────────────────────────
; Input:  AX = word to print as unsigned decimal
; Output: none
; ──────────────────────────────────────────────────────────────────────────────
.fn_print_dec16:
    push ax
    push bx
    push cx
    push dx
    xor cx, cx

.dec_div:
    xor dx, dx
    mov bx, 10
    div bx
    push dx
    inc cx
    test ax, ax
    jnz .dec_div

.dec_print:
    pop ax
    add al, '0'
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    dec cx
    jnz .dec_print

    pop dx
    pop cx
    pop bx
    pop ax
    iret

; ─── SYS_WAIT_KEY (AH=0x13) ──────────────────────────────────────────────────
; Input:  none
; Output: none (prints prompt, waits, clears screen)
; ──────────────────────────────────────────────────────────────────────────────
.fn_wait_key:
    push ax
    push si
    push bx
    mov si, msg_anykey
    call bios_puts
    xor ah, ah
    int 0x16                        ; Wait for keypress
    mov ax, 0x0003                  ; Clear screen
    int 0x10
    pop bx
    pop si
    pop ax
    iret

; ─── SYS_GET_EQUIP (AH=0x14) ─────────────────────────────────────────────────
; Input:  none
; Output: AX = equipment word
; ──────────────────────────────────────────────────────────────────────────────
.fn_get_equip:
    int 0x11
    iret

; ─── SYS_GET_VIDEO (AH=0x15) ─────────────────────────────────────────────────
; Input:  none
; Output: AL = current video mode, AH = columns, BH = active page
; ──────────────────────────────────────────────────────────────────────────────
.fn_get_video:
    mov ah, 0x0F
    int 0x10
    iret

; ─── SYS_GET_BDA_BYTE (AH=0x16) ──────────────────────────────────────────────
; Input:  BX = offset within BDA (0x0400–0x04FF)
; Output: AL = byte at that BDA offset
; ──────────────────────────────────────────────────────────────────────────────
.fn_get_bda_byte:
    push ds
    push ax
    xor ax, ax
    mov ds, ax
    pop ax
    mov al, [ds:bx]
    pop ds
    iret

; ─── SYS_GET_BDA_WORD (AH=0x17) ──────────────────────────────────────────────
; Input:  BX = offset within BDA (0x0400–0x04FF)
; Output: AX = word at that BDA offset
; ──────────────────────────────────────────────────────────────────────────────
.fn_get_bda_word:
    push ds
    xor ax, ax
    mov ds, ax
    mov ax, [ds:bx]
    pop ds
    iret

; ─── SYS_CPUID (AH=0x18) ─────────────────────────────────────────────────────
; Input:  EDI = CPUID leaf number (EAX is used by the dispatcher for AH,
;         so the caller passes the leaf in EDI to avoid the conflict)
; Output: EAX, EBX, ECX, EDX = CPUID result
; ──────────────────────────────────────────────────────────────────────────────
.fn_cpuid:
    mov eax, edi                    ; Move leaf from EDI into EAX
    cpuid
    iret

; ─── SYS_CHECK_CPUID (AH=0x19) ───────────────────────────────────────────────
; Input:  none
; Output: AL = 1 if CPUID supported, 0 if not
; ──────────────────────────────────────────────────────────────────────────────
.fn_check_cpuid:
    pushfd
    pop eax
    mov ecx, eax
    xor eax, 0x00200000             ; Flip ID bit (bit 21)
    push eax
    popfd
    pushfd
    pop eax
    push ecx
    popfd                           ; Restore original EFLAGS
    xor eax, ecx
    test eax, 0x00200000
    jz .no_cpuid_support
    mov al, 1
    iret
.no_cpuid_support:
    xor al, al
    iret

; ─── SYS_GET_EDD (AH=0x1A) ───────────────────────────────────────────────────
; Input:  DL = drive number
; Output: BX = 0xAA55 if EDD supported, AH=version, CX=interface support
;         CF set if not supported
; ──────────────────────────────────────────────────────────────────────────────
.fn_get_edd:
    mov bx, 0x55AA
    mov ah, 0x41
    int 0x13
    iret

; ─── SYS_GET_IVT (AH=0x1B) ───────────────────────────────────────────────────
; Input:  CL = vector number (0x00–0xFF)
; Output: AX = offset, DX = segment of the IVT entry
; ──────────────────────────────────────────────────────────────────────────────
.fn_get_ivt:
    push ds
    push bx
    xor ax, ax
    mov ds, ax
    xor bh, bh
    mov bl, cl
    shl bx, 2                      ; BX = vector * 4
    mov ax, [ds:bx]                 ; Offset
    mov dx, [ds:bx+2]              ; Segment
    pop bx
    pop ds
    iret

; =============================================================================
; load_shell — Load SHELL.BIN from disk and verify its magic
;
; Output: CF clear on success, CF set on error
; =============================================================================
load_shell:
    ; Calculate absolute LBA of SHELL.BIN
    mov eax, [BIB_PART_LBA]
    add eax, SHELL_PART_OFF
    mov [k_dap_lba], eax

    ; Load first sector to read header
    mov word [k_dap_sectors], 1
    mov word [k_dap_buffer], SHELL_OFF
    mov word [k_dap_buffer+2], SHELL_SEG

    mov dl, [BIB_DRIVE]
    mov si, k_dap
    mov ah, 0x42
    int 0x13
    jc .ls_fail

    ; Verify SHELL.BIN magic ('MNEX')
    cmp dword [SHELL_OFF], 'MNEX'
    jne .ls_fail

    ; Read sector count from header and reload all sectors
    mov cx, [SHELL_OFF + 4]
    test cx, cx
    jz .ls_fail
    cmp cx, SHELL_MAX_SEC
    ja .ls_fail

    mov [k_dap_sectors], cx
    mov eax, [BIB_PART_LBA]
    add eax, SHELL_PART_OFF
    mov [k_dap_lba], eax

    mov dl, [BIB_DRIVE]
    mov si, k_dap
    mov ah, 0x42
    int 0x13
    jc .ls_fail

    clc                             ; Success
    ret

.ls_fail:
    stc
    ret

; =============================================================================
; bios_puts — Direct BIOS print (used before/outside syscall context)
; =============================================================================
bios_puts:
    lodsb
    test al, al
    jz .bp_done
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    jmp bios_puts
.bp_done:
    ret

; =============================================================================
; DATA
; =============================================================================
msg_shell_fail  db 'KERNEL: No shell', 0
msg_anykey      db 13, 10, '  Press any key...', 0

; --- Kernel's Disk Address Packet (DAP) for INT 13h AH=42h -------------------
k_dap:
    db 0x10, 0
k_dap_sectors:
    dw 1
k_dap_buffer:
    dw SHELL_OFF, SHELL_SEG
k_dap_lba:
    dd 0, 0

; =============================================================================
; PADDING — fill to 4 sectors (2048 bytes)
; =============================================================================
times (4 * 512) - ($ - $$) db 0
