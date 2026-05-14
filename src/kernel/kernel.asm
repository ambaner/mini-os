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
%define ASSERT_HAS_SCREEN
%include "debug.inc"

[BITS 16]
[ORG 0x5000]                        ; Loader loads us here

; =============================================================================
; KERNEL HEADER
; =============================================================================
kernel_magic    db 'MNKN'           ; Magic identifier — kernel
%ifdef DEBUG
kernel_sectors  dw 10               ; Kernel size in sectors (debug build)
%else
kernel_sectors  dw 7                ; Kernel size in sectors (release build)
%endif

; =============================================================================
; KERNEL ENTRY POINT
; =============================================================================
kernel_start:
%ifdef DEBUG
    call serial_init
    DBG "KERNEL: serial debug active"
%endif

    ; --- Install syscall handler at INT 0x80 ----------------------------------
    call install_syscalls

    mov si, msg_syscall
    call boot_ok
    DBG "KERNEL: INT 0x80 installed"

    ; --- Install CPU exception fault handlers --------------------------------
    call install_fault_handlers
    DBG "KERNEL: fault handlers installed (INT 0x00-0x07)"

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
    ASSERT_MAGIC LOADER_OFF, 'MNFS', "FS.BIN magic invalid after load"

    mov si, msg_fs
    call boot_ok
    DBG "KERNEL: FS.BIN loaded at 0x0800"

    ; --- Initialize FS.BIN (installs INT 0x81) --------------------------------
    ; FS.BIN's init entry point is at offset 6 (right after the 6-byte header).
    call LOADER_OFF + MNEX_HDR_SIZE
    jc .fs_init_fail
    ASSERT_CF_CLEAR "FS.BIN init returned error"

    mov si, msg_fs_init
    call boot_ok
    DBG "KERNEL: INT 0x81 filesystem ready"

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
    ASSERT_MAGIC SHELL_OFF, 'MNEX', "SHELL.BIN magic invalid after load"

    mov si, msg_shell
    call boot_ok
    DBG "KERNEL: SHELL.BIN loaded, jumping to shell"

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

%ifdef DEBUG
    ; --- Syscall trace: log function name + AX + original BX to serial ---
    push si
    push ax

    ; Look up syscall name from table
    mov si, .sc_trace_pfx           ; "[SYS] "
    call serial_puts

    movzx bx, ah
    cmp bx, SYSCALL_MAX
    ja .sc_trace_noname
    shl bx, 1                       ; word offset into name pointer table
    mov si, [cs:.sc_name_table + bx]
    test si, si
    jz .sc_trace_noname
    call serial_puts
    jmp .sc_trace_ax_part

.sc_trace_noname:
    mov si, .sc_trace_ah            ; "AH="
    call serial_puts
    mov al, ah
    call serial_hex8

.sc_trace_ax_part:
    mov si, .sc_trace_ax            ; " AX="
    call serial_puts
    pop ax                          ; restore AX for printing
    push ax                         ; re-save
    call serial_hex16

    mov si, .sc_trace_bx            ; " BX="
    call serial_puts
    mov ax, [cs:.sc_temp]           ; original BX
    call serial_hex16

    call serial_crlf
    pop ax
    mov bx, [cs:.sc_temp]           ; restore BX (was clobbered by name lookup)
    pop si
%endif

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

%ifdef DEBUG
.sc_trace_pfx: db '[SYS] ', 0
.sc_trace_ah:  db 'AH=', 0
.sc_trace_ax:  db ' AX=', 0
.sc_trace_bx:  db ' BX=', 0

; Syscall name strings (short, human-readable)
.sn_01: db 'PRINT_STRING', 0
.sn_02: db 'PRINT_CHAR', 0
.sn_03: db 'READ_KEY', 0
.sn_04: db 'READ_SECTOR', 0
.sn_05: db 'GET_VERSION', 0
.sn_06: db 'CLEAR_SCREEN', 0
.sn_07: db 'SET_CURSOR', 0
.sn_08: db 'GET_CURSOR', 0
.sn_09: db 'CHECK_A20', 0
.sn_0a: db 'GET_CONV_MEM', 0
.sn_0b: db 'GET_EXT_MEM', 0
.sn_0c: db 'GET_E820', 0
.sn_0d: db 'REBOOT', 0
.sn_0e: db 'GET_DRIVE_INFO', 0
.sn_0f: db 'GET_BIB', 0
.sn_10: db 'PRINT_HEX8', 0
.sn_11: db 'PRINT_HEX16', 0
.sn_12: db 'PRINT_DEC16', 0
.sn_13: db 'WAIT_KEY', 0
.sn_14: db 'GET_EQUIP', 0
.sn_15: db 'GET_VIDEO', 0
.sn_16: db 'GET_BDA_BYTE', 0
.sn_17: db 'GET_BDA_WORD', 0
.sn_18: db 'CPUID', 0
.sn_19: db 'CHECK_CPUID', 0
.sn_1a: db 'GET_EDD', 0
.sn_1b: db 'GET_IVT', 0
.sn_20: db 'DBG_PRINT', 0
.sn_21: db 'DBG_HEX16', 0
.sn_22: db 'DBG_REGS', 0

; Name pointer table (indexed by AH, 0x00–0x1B)
.sc_name_table:
    dw 0            ; 0x00 — unused
    dw .sn_01       ; 0x01
    dw .sn_02       ; 0x02
    dw .sn_03       ; 0x03
    dw .sn_04       ; 0x04
    dw .sn_05       ; 0x05
    dw .sn_06       ; 0x06
    dw .sn_07       ; 0x07
    dw .sn_08       ; 0x08
    dw .sn_09       ; 0x09
    dw .sn_0a       ; 0x0A
    dw .sn_0b       ; 0x0B
    dw .sn_0c       ; 0x0C
    dw .sn_0d       ; 0x0D
    dw .sn_0e       ; 0x0E
    dw .sn_0f       ; 0x0F
    dw .sn_10       ; 0x10
    dw .sn_11       ; 0x11
    dw .sn_12       ; 0x12
    dw .sn_13       ; 0x13
    dw .sn_14       ; 0x14
    dw .sn_15       ; 0x15
    dw .sn_16       ; 0x16
    dw .sn_17       ; 0x17
    dw .sn_18       ; 0x18
    dw .sn_19       ; 0x19
    dw .sn_1a       ; 0x1A
    dw .sn_1b       ; 0x1B
    dw 0            ; 0x1C — reserved
    dw 0            ; 0x1D — reserved
    dw 0            ; 0x1E — reserved
    dw 0            ; 0x1F — reserved
    dw .sn_20       ; 0x20
    dw .sn_21       ; 0x21
    dw .sn_22       ; 0x22
%endif

; --- Syscall jump table (35 entries: 0x00–0x22, gap 0x1C–0x1F reserved) ------
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
    dw .sc_unknown          ; 0x1C — reserved
    dw .sc_unknown          ; 0x1D — reserved
    dw .sc_unknown          ; 0x1E — reserved
    dw .sc_unknown          ; 0x1F — reserved
    dw .fn_dbg_print        ; 0x20 — SYS_DBG_PRINT
    dw .fn_dbg_hex16        ; 0x21 — SYS_DBG_HEX16
    dw .fn_dbg_regs         ; 0x22 — SYS_DBG_REGS

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
    mov ax, 0x0704                  ; Version 7.4 (v0.7.4)
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

; ─── SYS_DBG_PRINT (AH=0x20) ──────────────────────────────────────────────────
; Input:  DS:SI = NUL-terminated message string
;         DS:BX = NUL-terminated tag string (e.g., "SHL"); BX=0 → default "USR"
; Output: none
; Note:   No-op in release builds.  In debug builds, outputs:
;         [TAG] message\r\n
; ──────────────────────────────────────────────────────────────────────────────
.fn_dbg_print:
%ifdef DEBUG
    push si
    push ax
    call .dbg_emit_tag              ; print "[TAG] "
    pop ax
    pop si
    push si
    push ax
    call serial_puts                ; print the message
    call serial_crlf
    pop ax
    pop si
%endif
    iret

; ─── SYS_DBG_HEX16 (AH=0x21) ─────────────────────────────────────────────────
; Input:  DX = 16-bit value to display
;         DS:BX = NUL-terminated tag string; BX=0 → default "USR"
; Output: none
; Note:   No-op in release builds.  In debug builds, outputs:
;         [TAG] 0xNNNN\r\n
; ──────────────────────────────────────────────────────────────────────────────
.fn_dbg_hex16:
%ifdef DEBUG
    push ax
    push si
    call .dbg_emit_tag              ; print "[TAG] "
    mov ax, dx
    call serial_hex16               ; print DX as hex
    call serial_crlf
    pop si
    pop ax
%endif
    iret

; ─── SYS_DBG_REGS (AH=0x22) ──────────────────────────────────────────────────
; Input:  DS:BX = NUL-terminated tag string; BX=0 → default "USR"
;         All other registers are the values to dump.
; Output: none
; Note:   No-op in release builds.  In debug builds, outputs:
;         [TAG] AX=xxxx BX=xxxx CX=xxxx DX=xxxx SI=xxxx DI=xxxx\r\n
;         AX will show AH=0x22 (the syscall number is part of AX).
;         BX shows the original value (saved by dispatcher in .sc_temp).
; ──────────────────────────────────────────────────────────────────────────────
.fn_dbg_regs:
%ifdef DEBUG
    push ax
    push si
    ; Save values we want to print before we clobber them
    mov [cs:.dbg_save_cx], cx
    mov [cs:.dbg_save_dx], dx
    mov [cs:.dbg_save_si], si
    mov [cs:.dbg_save_di], di

    call .dbg_emit_tag              ; print "[TAG] "

    mov si, .dbg_lbl_ax
    call serial_puts
    pop si                          ; pop saved SI
    pop ax                          ; pop saved AX (caller's AX with AH=0x22)
    push ax
    push si
    call serial_hex16

    mov si, .dbg_lbl_bx
    call serial_puts
    mov ax, [cs:.sc_temp]           ; original BX (saved by dispatcher)
    call serial_hex16

    mov si, .dbg_lbl_cx
    call serial_puts
    mov ax, [cs:.dbg_save_cx]
    call serial_hex16

    mov si, .dbg_lbl_dx
    call serial_puts
    mov ax, [cs:.dbg_save_dx]
    call serial_hex16

    mov si, .dbg_lbl_si
    call serial_puts
    mov ax, [cs:.dbg_save_si]
    call serial_hex16

    mov si, .dbg_lbl_di
    call serial_puts
    mov ax, [cs:.dbg_save_di]
    call serial_hex16

    call serial_crlf
    pop si
    pop ax
%endif
    iret

%ifdef DEBUG
; ─── .dbg_emit_tag — print "[TAG] " to serial ────────────────────────────────
; Input:  DS:BX = tag string (NUL-terminated); BX=0 → use "USR"
; Clobbers: SI (caller must save)
; ──────────────────────────────────────────────────────────────────────────────
.dbg_emit_tag:
    push ax
    mov al, '['
    call serial_putc
    test bx, bx
    jz .dbg_default_tag
    mov si, bx
    call serial_puts
    jmp .dbg_tag_close
.dbg_default_tag:
    mov si, .dbg_tag_usr
    call serial_puts
.dbg_tag_close:
    mov al, ']'
    call serial_putc
    mov al, ' '
    call serial_putc
    pop ax
    ret

.dbg_tag_usr:  db 'USR', 0
.dbg_lbl_ax:   db 'AX=', 0
.dbg_lbl_bx:   db ' BX=', 0
.dbg_lbl_cx:   db ' CX=', 0
.dbg_lbl_dx:   db ' DX=', 0
.dbg_lbl_si:   db ' SI=', 0
.dbg_lbl_di:   db ' DI=', 0
.dbg_save_cx:  dw 0
.dbg_save_dx:  dw 0
.dbg_save_si:  dw 0
.dbg_save_di:  dw 0
%endif

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
; CPU EXCEPTION FAULT HANDLERS (debug build only)
;
; In real mode, the CPU dispatches exceptions through the IVT just like any
; other interrupt.  Without custom handlers, exceptions either go to BIOS
; stubs (which do nothing useful) or triple-fault the CPU (instant reboot).
;
; These handlers catch the most common x86 exceptions, log the exception name
; and faulting CS:IP to both serial and screen, dump all registers, then halt.
; This turns invisible crashes into diagnosable events.
;
; See doc/DEBUGGING.md §6 for full specification.
; =============================================================================
; =============================================================================
; CPU EXCEPTION FAULT HANDLERS (both release and debug builds)
;
; On any trapped CPU exception, the handler:
;   - Prints exception name + faulting CS:IP to screen
;   - Dumps all registers + FLAGS to screen
;   - Dumps top 4 stack words to screen
;   - (Debug only) Also logs everything to serial
;   - Halts the CPU permanently
; =============================================================================

; =============================================================================
; install_fault_handlers — Install CPU exception handlers into IVT vectors 0-8
;
; Must be called with interrupts safe to disable (early kernel init).
; =============================================================================
install_fault_handlers:
    cli
    push es

    xor ax, ax
    mov es, ax                          ; ES = 0x0000 (IVT segment)

    ; INT 0x00 — Divide Error (#DE)
    mov word [es:0x00*4],   fault_de
    mov word [es:0x00*4+2], cs

    ; INT 0x01 — Debug / Single Step (#DB)
    mov word [es:0x01*4],   fault_db
    mov word [es:0x01*4+2], cs

    ; INT 0x04 — Overflow (#OF)
    mov word [es:0x04*4],   fault_of
    mov word [es:0x04*4+2], cs

    ; INT 0x05 — Bound Range Exceeded (#BR)
    mov word [es:0x05*4],   fault_br
    mov word [es:0x05*4+2], cs

    ; INT 0x06 — Invalid Opcode (#UD)
    mov word [es:0x06*4],   fault_ud
    mov word [es:0x06*4+2], cs

    ; INT 0x07 — Device Not Available (#NM)
    mov word [es:0x07*4],   fault_nm
    mov word [es:0x07*4+2], cs

    ; NOTE: INT 0x08 (#DF Double Fault) is NOT installed because in real mode
    ; the PIC maps IRQ0 (hardware timer) to INT 0x08. Installing a handler
    ; here would clobber the timer ISR and hang the system.

    pop es
    sti
    ret

; =============================================================================
; fault_common — Shared exception handler core
;
; Each specific handler pushes the address of its name string, then jumps here.
;
; Stack frame on entry:
;   SP+0  = name pointer (pushed by stub)
;   SP+2  = faulting IP  (pushed by CPU)
;   SP+4  = faulting CS  (pushed by CPU)
;   SP+6  = faulting FLAGS (pushed by CPU)
;
; After saving 7 registers (14 bytes):
;   SP+0  = BP   SP+2  = DI   SP+4  = SI   SP+6  = DX
;   SP+8  = CX   SP+10 = BX   SP+12 = AX   SP+14 = name ptr
;   SP+16 = IP   SP+18 = CS   SP+20 = FLAGS
;   SP+22 = original stack top (pre-fault)
; =============================================================================
fault_common:
    ; Save all registers at the moment of fault
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push bp

%ifdef DEBUG
    ; --- Serial output (debug builds) ----------------------------------------
    mov si, .fault_banner
    call serial_puts

    ; Print exception name to serial
    mov bx, sp
    mov si, [ss:bx + 14]               ; Name pointer
    call serial_puts

    ; Print " at XXXX:XXXX" to serial
    mov si, .fault_at
    call serial_puts
    mov ax, [ss:bx + 18]               ; Faulting CS
    call serial_hex16
    mov al, ':'
    call serial_putc
    mov bx, sp
    mov ax, [ss:bx + 16]               ; Faulting IP
    call serial_hex16
    call serial_crlf

    ; Dump registers to serial (using saved values)
    DBG_REGS
%endif

    ; --- Screen output (both builds) -----------------------------------------
    ; Line 1: "*** FAULT: <name>"
    mov si, .fault_banner
    call puts

    mov bx, sp
    mov si, [ss:bx + 14]               ; Name pointer
    call puts

    ; Line 2: "at XXXX:XXXX"
    mov si, .fault_at
    call puts
    mov bx, sp
    mov ax, [ss:bx + 18]               ; Faulting CS
    call .screen_hex16
    mov al, ':'
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    mov bx, sp
    mov ax, [ss:bx + 16]               ; Faulting IP
    call .screen_hex16

    mov si, .fault_crlf
    call puts

    ; Line 3+: Register dump on screen
    ; AX
    mov si, .reg_ax
    call puts
    mov bx, sp
    mov ax, [ss:bx + 12]
    call .screen_hex16

    ; BX
    mov si, .reg_bx
    call puts
    mov bx, sp
    mov ax, [ss:bx + 10]
    call .screen_hex16

    ; CX
    mov si, .reg_cx
    call puts
    mov bx, sp
    mov ax, [ss:bx + 8]
    call .screen_hex16

    ; DX
    mov si, .reg_dx
    call puts
    mov bx, sp
    mov ax, [ss:bx + 6]
    call .screen_hex16

    mov si, .fault_crlf
    call puts

    ; SI
    mov si, .reg_si
    call puts
    mov bx, sp
    mov ax, [ss:bx + 4]
    call .screen_hex16

    ; DI
    mov si, .reg_di
    call puts
    mov bx, sp
    mov ax, [ss:bx + 2]
    call .screen_hex16

    ; BP
    mov si, .reg_bp
    call puts
    mov bx, sp
    mov ax, [ss:bx + 0]
    call .screen_hex16

    ; SP (original = current SP + 22)
    mov si, .reg_sp
    call puts
    mov ax, sp
    add ax, 22
    call .screen_hex16

    mov si, .fault_crlf
    call puts

    ; DS
    mov si, .reg_ds
    call puts
    mov ax, ds
    call .screen_hex16

    ; ES
    mov si, .reg_es
    call puts
    mov ax, es
    call .screen_hex16

    ; SS
    mov si, .reg_ss
    call puts
    mov ax, ss
    call .screen_hex16

    ; FLAGS
    mov si, .reg_fl
    call puts
    mov bx, sp
    mov ax, [ss:bx + 20]
    call .screen_hex16

    mov si, .fault_crlf
    call puts

    ; Line 4: Stack dump (top 4 words from original stack)
    mov si, .stack_lbl
    call puts

    mov bx, sp
    mov ax, [ss:bx + 22]               ; Stack word 0
    call .screen_hex16
    mov al, ' '
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    mov bx, sp
    mov ax, [ss:bx + 24]               ; Stack word 1
    call .screen_hex16
    mov al, ' '
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    mov bx, sp
    mov ax, [ss:bx + 26]               ; Stack word 2
    call .screen_hex16
    mov al, ' '
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    mov bx, sp
    mov ax, [ss:bx + 28]               ; Stack word 3
    call .screen_hex16

    mov si, .fault_crlf
    call puts

    ; Final message
    mov si, .fault_halted
    call puts

    ; Halt permanently
    cli
.fault_halt:
    hlt
    jmp .fault_halt

; --- Screen hex16 helper (print AX as 4-digit hex via BIOS teletype) ----------
.screen_hex16:
    push cx
    push ax
    mov cx, 4
.sh16_loop:
    rol ax, 4
    push ax
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jbe .sh16_digit
    add al, 7
.sh16_digit:
    mov ah, 0x0E
    push bx
    xor bx, bx
    int 0x10
    pop bx
    pop ax
    dec cx
    jnz .sh16_loop
    pop ax
    pop cx
    ret

; --- Fault handler data strings -----------------------------------------------
.fault_banner:  db 13, 10, '*** FAULT: ', 0
.fault_at:      db ' at ', 0
.fault_crlf:    db 13, 10, 0
.fault_halted:  db 'System halted.', 13, 10, 0
.reg_ax:        db 'AX=', 0
.reg_bx:        db ' BX=', 0
.reg_cx:        db ' CX=', 0
.reg_dx:        db ' DX=', 0
.reg_si:        db 'SI=', 0
.reg_di:        db ' DI=', 0
.reg_bp:        db ' BP=', 0
.reg_sp:        db ' SP=', 0
.reg_ds:        db 'DS=', 0
.reg_es:        db ' ES=', 0
.reg_ss:        db ' SS=', 0
.reg_fl:        db ' FL=', 0
.stack_lbl:     db 'Stack: ', 0

; =============================================================================
; Specific fault handler stubs
; Each pushes its name string pointer, then jumps to fault_common.
; =============================================================================

fault_de:                               ; INT 0x00 — Divide Error
    push word .de_name
    jmp fault_common
.de_name: db '#DE Divide Error', 0

fault_db:                               ; INT 0x01 — Debug / Single Step
    push word .db_name
    jmp fault_common
.db_name: db '#DB Debug', 0

fault_of:                               ; INT 0x04 — Overflow
    push word .of_name
    jmp fault_common
.of_name: db '#OF Overflow', 0

fault_br:                               ; INT 0x05 — Bound Range Exceeded
    push word .br_name
    jmp fault_common
.br_name: db '#BR Bound Range', 0

fault_ud:                               ; INT 0x06 — Invalid Opcode
    push word .ud_name
    jmp fault_common
.ud_name: db '#UD Invalid Opcode', 0

fault_nm:                               ; INT 0x07 — Device Not Available
    push word .nm_name
    jmp fault_common
.nm_name: db '#NM No Device', 0

; NOTE: No fault_df stub — INT 0x08 conflicts with IRQ0 (timer) in real mode.

; =============================================================================
; Serial I/O functions (debug build only — placed after kernel code to avoid
; polluting the header at offset 0)
; =============================================================================
%include "serial.inc"

; =============================================================================
; PADDING — fill to sector boundary
; =============================================================================
%ifdef DEBUG
times (10 * 512) - ($ - $$) db 0
%else
times (7 * 512) - ($ - $$) db 0
%endif
