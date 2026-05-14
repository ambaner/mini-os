syscall_handler:
    ; --- Stack canary check (debug only) -------------------------------------
    ; Verify the canary at 0x7000 is intact before dispatching.  This catches
    ; stack overflows that occurred during the previous syscall handler or in
    ; user-mode code between syscalls.  CANARY_CHECK preserves all registers
    ; and FLAGS, so AH (function number) and all arguments are untouched.
    ; In release builds, CANARY_CHECK expands to nothing (0 bytes).
    CANARY_CHECK

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
    mov ax, 0x0801                  ; Version 8.1 (v0.8.1)
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
