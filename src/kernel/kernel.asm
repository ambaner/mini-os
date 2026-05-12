; =============================================================================
; Mini-OS Kernel (KERNEL.BIN) - 16-bit Real-Mode Kernel
;
; Loaded by LOADER.BIN into memory at 0x5000.  This is the first component
; in mini-os that acts as a proper kernel:
;
;   1. Installs a syscall handler at INT 0x80 in the IVT
;   2. Finds and loads FS.BIN (filesystem module) from the MNFS directory
;   3. Calls FS.BIN init to install INT 0x81
;   4. Finds and loads SHELL.BIN (user-mode executable) from the MNFS directory
;   5. Transfers control to the shell
;
; The shell and all user-mode programs interact with hardware exclusively
; through the INT 0x80 syscall interface.  Filesystem operations use INT 0x81
; (provided by FS.BIN).
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

%include "bib.inc"
%include "memory.inc"
%include "mnfs.inc"
%include "syscalls.inc"

[BITS 16]
[ORG 0x5000]                        ; Loader loads us here

; =============================================================================
; KERNEL HEADER
; =============================================================================
kernel_magic    db 'MNKN'           ; Magic identifier — kernel
kernel_sectors  dw 6                ; Kernel size in sectors (updated as needed)

; =============================================================================
; KERNEL ENTRY POINT
; =============================================================================
kernel_start:
    ; --- Install syscall handler at INT 0x80 ----------------------------------
    call install_syscalls

    mov si, msg_syscall
    call boot_ok

    ; --- Load FS.BIN (filesystem module) at 0x0800 ---------------------------
    ; FS.BIN replaces LOADER.BIN in memory (LOADER's job is done).
    ; Use 0x3000 (shell area) as scratch buffer for directory read.
    mov bx, SHELL_OFF               ; Scratch buffer (shell not loaded yet)
    mov si, fname_fs                ; "FS      BIN"
    call find_file
    jc .fs_find_fail

    ; EAX = partition-relative start sector, CX = size in sectors
    mov bx, LOADER_OFF              ; Load FS.BIN at 0x0800 (LOADER's old slot)
    mov ecx, 'MNFS'                 ; Expected magic signature
    mov dh, 16                      ; Maximum sector count
    call load_mnex
    jc .fs_load_fail

    mov si, msg_fs
    call boot_ok

    ; --- Initialize FS.BIN (installs INT 0x81) --------------------------------
    ; FS.BIN's init entry point is at offset 6 (right after the 6-byte header).
    call LOADER_OFF + MNEX_HDR_SIZE
    jc .fs_init_fail

    mov si, msg_fs_init
    call boot_ok

    ; --- Load SHELL.BIN at 0x3000 --------------------------------------------
    ; Use 0x2000 as scratch buffer for directory read (safe — between LOADER
    ; area and SHELL area, and FS.BIN at 0x0800 is only ~1 KB).
    mov bx, 0x2000                  ; Scratch buffer
    mov si, fname_shell             ; "SHELL   BIN"
    call find_file
    jc .shell_find_fail

    ; EAX = partition-relative start sector, CX = size in sectors
    mov bx, SHELL_OFF               ; Load address (segment 0x0000)
    mov ecx, 'MNEX'                 ; Expected magic signature
    mov dh, 32                      ; Maximum sector count
    call load_mnex
    jc .shell_load_fail

    mov si, msg_shell
    call boot_ok

    ; --- Transfer control to shell --------------------------------------------
    ; The shell is a user-mode executable.  When it calls INT 0x80, the CPU
    ; jumps to our syscall_handler via the IVT entry we installed above.
    ; Skip the 6-byte MNEX header (magic + sector count) to reach shell code.
    jmp SHELL_SEG:SHELL_OFF + MNEX_HDR_SIZE

.fs_find_fail:
    mov si, msg_fs_find
    call boot_fail

.fs_load_fail:
    mov si, msg_fs_load
    call boot_fail

.fs_init_fail:
    mov si, msg_fs_initf
    call boot_fail

.shell_find_fail:
    mov si, msg_sh_find
    call boot_fail

.shell_load_fail:
    mov si, msg_sh_load
    call boot_fail

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
; syscall_handler — INT 0x80 dispatcher (O(1) jump table)
;
; Routes syscalls based on AH function number using a jump table instead of
; a linear comparison chain.  Each handler returns via IRET.
; All handlers preserve registers except documented return values.
;
; Dispatch uses BX as a scratch register for the table lookup.  BX is
; saved/restored via a kernel-local memory word, and the handler address
; is stored there for the indirect jump.  This leaves all registers intact
; when the handler begins executing.
;
; CF propagation: Handlers that return CF as a status indicator MUST use
; syscall_ret_cf instead of iret.  Plain iret restores the caller's
; original FLAGS, silently discarding any CF changes made by the handler.
; syscall_ret_cf uses retf 2 to preserve the handler's FLAGS.
; =============================================================================

; Macro: return from INT 0x80 handler preserving current FLAGS (including CF).
; Plain iret pops the caller's saved FLAGS, discarding the handler's CF.
; retf 2 pops IP and CS, then skips the saved FLAGS (SP += 2), so the
; current FLAGS register (with the handler's CF) remains in effect.
; sti re-enables interrupts (the CPU clears IF on INT).
%macro syscall_ret_cf 0
    sti
    retf 2
%endmacro

syscall_handler:
    mov [cs:.sc_temp], bx           ; Save BX in kernel data area

    movzx bx, ah                    ; BX = function number (zero-extended)
    cmp bx, SYSCALL_MAX
    ja .sc_unknown

    add bx, bx                      ; BX = function number * 2 (word offset)
    mov bx, [cs:.sc_table + bx]     ; BX = handler address from jump table
    xchg bx, [cs:.sc_temp]          ; BX = original value, .sc_temp = handler
    jmp [cs:.sc_temp]               ; Jump to handler with all regs intact

.sc_unknown:
    mov bx, [cs:.sc_temp]           ; Restore BX
    stc
    syscall_ret_cf                  ; Must propagate CF to caller

; Temporary storage for syscall dispatch (single-threaded real mode,
; so no reentrancy concerns — interrupts are masked during INT handlers).
.sc_temp: dw 0

; --- Syscall jump table (28 entries: 0x00 unused + 0x01–0x1B) ----------------
.sc_table:
    dw .sc_unknown          ; 0x00 — unused
    dw .fn_print_string     ; 0x01 — SYS_PRINT_STRING
    dw .fn_print_char       ; 0x02 — SYS_PRINT_CHAR
    dw .fn_read_key         ; 0x03 — SYS_READ_KEY
    dw .fn_read_sector      ; 0x04 — SYS_READ_SECTOR
    dw .fn_get_version      ; 0x05 — SYS_GET_VERSION
    dw .fn_clear_screen     ; 0x06 — SYS_CLEAR_SCREEN
    dw .fn_set_cursor       ; 0x07 — SYS_SET_CURSOR
    dw .fn_get_cursor       ; 0x08 — SYS_GET_CURSOR
    dw .fn_check_a20        ; 0x09 — SYS_CHECK_A20
    dw .fn_get_conv_mem     ; 0x0A — SYS_GET_CONV_MEM
    dw .fn_get_ext_mem      ; 0x0B — SYS_GET_EXT_MEM
    dw .fn_get_e820         ; 0x0C — SYS_GET_E820
    dw .fn_reboot           ; 0x0D — SYS_REBOOT
    dw .fn_get_drive_info   ; 0x0E — SYS_GET_DRIVE_INFO
    dw .fn_get_bib          ; 0x0F — SYS_GET_BIB
    dw .fn_print_hex8       ; 0x10 — SYS_PRINT_HEX8
    dw .fn_print_hex16      ; 0x11 — SYS_PRINT_HEX16
    dw .fn_print_dec16      ; 0x12 — SYS_PRINT_DEC16
    dw .fn_wait_key         ; 0x13 — SYS_WAIT_KEY
    dw .fn_get_equip        ; 0x14 — SYS_GET_EQUIP
    dw .fn_get_video        ; 0x15 — SYS_GET_VIDEO
    dw .fn_get_bda_byte     ; 0x16 — SYS_GET_BDA_BYTE
    dw .fn_get_bda_word     ; 0x17 — SYS_GET_BDA_WORD
    dw .fn_cpuid            ; 0x18 — SYS_CPUID
    dw .fn_check_cpuid      ; 0x19 — SYS_CHECK_CPUID
    dw .fn_get_edd          ; 0x1A — SYS_GET_EDD
    dw .fn_get_ivt          ; 0x1B — SYS_GET_IVT

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
; Input:  EDI = absolute LBA sector number
;         ES:BX = buffer to read into
;         CL = number of sectors to read
; Output: CF clear = success, CF set = error
;
; NOTE: LBA is passed in EDI (not EAX) because AH carries the syscall
; function number, and AH is bits 8-15 of EAX — they would collide.
; ──────────────────────────────────────────────────────────────────────────────
.fn_read_sector:
    push si
    push dx

    ; Set up the kernel's DAP
    mov [dap_lba], edi
    xor ch, ch
    mov [dap_sectors], cx
    mov [dap_buffer], bx
    mov [dap_buffer+2], es

    mov dl, [BIB_DRIVE]
    mov si, dap
    mov ah, 0x42
    int 0x13

    pop dx
    pop si
    syscall_ret_cf                  ; Propagate CF from INT 0x13 to caller

; ─── SYS_GET_VERSION (AH=0x05) ───────────────────────────────────────────────
; Input:  none
; Output: AH = major version, AL = minor version
; ──────────────────────────────────────────────────────────────────────────────
.fn_get_version:
    mov ax, 0x0600                  ; Version 6.0 (v0.6.0)
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
    syscall_ret_cf

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
    syscall_ret_cf

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
    syscall_ret_cf

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
; Input:  DX = word to print as four hex digits
; Output: none
;
; NOTE: Value passed in DX (not AX) because AH carries the syscall number.
; ──────────────────────────────────────────────────────────────────────────────
.fn_print_hex16:
    push ax
    push bx
    push dx
    mov al, dh
    ; High byte, high nibble
    push ax
    shr al, 4
    call .hex_nibble
    pop ax
    and al, 0x0F
    call .hex_nibble
    ; Low byte
    mov al, dl
    push ax
    shr al, 4
    call .hex_nibble
    pop ax
    and al, 0x0F
    call .hex_nibble
    pop dx
    pop bx
    pop ax
    iret

; ─── SYS_PRINT_DEC16 (AH=0x12) ──────────────────────────────────────────────
; Input:  DX = word to print as unsigned decimal
; Output: none
;
; NOTE: Value passed in DX (not AX) because AH carries the syscall number.
; ──────────────────────────────────────────────────────────────────────────────
.fn_print_dec16:
    push ax
    push bx
    push cx
    push dx
    mov ax, dx                      ; Work in AX for division
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
    call puts
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
    syscall_ret_cf

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
; Shared subroutines (from src/include/)
; =============================================================================
%include "find_file.inc"
%include "load_binary.inc"
%define BOOT_REGDUMP
%include "boot_msg.inc"

; =============================================================================
; puts — Direct BIOS print (used by boot messages and kernel)
; =============================================================================
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

; =============================================================================
; DATA
; =============================================================================
msg_syscall     db 'Syscall handler (INT 0x80)', 0
msg_fs          db 'FS.BIN loaded', 0
msg_fs_init     db 'Filesystem (INT 0x81)', 0
msg_fs_find     db 'FS.BIN not found', 0
msg_fs_load     db 'FS.BIN load', 0
msg_fs_initf    db 'FS.BIN init', 0
msg_shell       db 'SHELL.BIN loaded', 0
msg_sh_find     db 'SHELL.BIN not found', 0
msg_sh_load     db 'SHELL.BIN load', 0
msg_anykey      db 13, 10, '  Press any key...', 0

; 11-byte "8.3" filenames for directory lookup
fname_fs        db 'FS      BIN'
fname_shell     db 'SHELL   BIN'

; --- Disk Address Packet (DAP) for INT 13h AH=42h ----------------------------
; Used by both load_mnex (during init) and SYS_READ_SECTOR (during runtime).
; These never run concurrently, so sharing one DAP is safe.
dap:
    db 0x10, 0
dap_sectors:
    dw 0
dap_buffer:
    dw 0, 0
dap_lba:
    dd 0, 0

; =============================================================================
; PADDING — fill to 6 sectors (3072 bytes)
; =============================================================================
times (6 * 512) - ($ - $$) db 0
