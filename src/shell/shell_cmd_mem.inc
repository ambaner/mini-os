
; =============================================================================
; COMMAND: mem
; Display detailed memory information using kernel syscalls.
; =============================================================================
cmd_mem:
    mov si, msg_mem_hdr
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; --- Conventional memory (SYS_GET_CONV_MEM) ------------------------------
    mov si, msg_conv_mem
    mov ah, SYS_PRINT_STRING
    int 0x80

    mov ah, SYS_GET_CONV_MEM        ; Returns AX = conventional KB
    int 0x80
    mov dx, ax
    mov ah, SYS_PRINT_DEC16         ; Print DX as decimal
    int 0x80

    mov si, msg_kb
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; --- Extended memory (SYS_GET_EXT_MEM) -----------------------------------
    mov si, msg_ext_mem
    mov ah, SYS_PRINT_STRING
    int 0x80

    mov ah, SYS_GET_EXT_MEM         ; Returns AX = extended KB, CF=err
    int 0x80
    jc .mem_no_ext

    mov dx, ax
    mov ah, SYS_PRINT_DEC16         ; Print DX as decimal
    int 0x80
    mov si, msg_kb
    mov ah, SYS_PRINT_STRING
    int 0x80
    jmp .mem_a20

.mem_no_ext:
    mov si, msg_na
    mov ah, SYS_PRINT_STRING
    int 0x80

.mem_a20:
    ; --- A20 gate status (from BIB via syscall) ------------------------------
    mov si, msg_a20
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; Get BIB pointer via syscall (not hard-coded address)
    mov ah, SYS_GET_BIB             ; Returns ES:BX = BIB base
    int 0x80
    ; BIB+1 = a20_status byte
    cmp byte [es:bx+1], 1
    je .a20_show_on

    mov si, msg_a20_off
    mov ah, SYS_PRINT_STRING
    int 0x80
    jmp .a20_verify

.a20_show_on:
    mov si, msg_a20_on
    mov ah, SYS_PRINT_STRING
    int 0x80

.a20_verify:
    ; Live A20 verification via kernel syscall
    mov si, msg_a20_live
    mov ah, SYS_PRINT_STRING
    int 0x80

    mov ah, SYS_CHECK_A20           ; Returns AL=1 if enabled, 0 if not
    int 0x80
    test al, al
    jnz .a20_live_on

    mov si, msg_a20_off_short
    mov ah, SYS_PRINT_STRING
    int 0x80
    jmp .a20_section_done

.a20_live_on:
    mov si, msg_a20_on_short
    mov ah, SYS_PRINT_STRING
    int 0x80

.a20_section_done:

    ; --- Real-mode memory layout ---------------------------------------------
    mov si, msg_layout_hdr
    mov ah, SYS_PRINT_STRING
    int 0x80
    ; Print "    0x00800-0x027FF" — but now it's FS.BIN at runtime
    mov si, msg_layout
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; --- E820 Memory Map via SYS_GET_E820 ------------------------------------
    mov si, msg_e820_hdr
    mov ah, SYS_PRINT_STRING
    int 0x80

    xor ebx, ebx                    ; EBX = 0 (start of enumeration)
    mov di, e820_buf                ; ES:DI = buffer for one E820 entry

.mem_e820_loop:
    ; Call kernel E820 syscall: EBX=continuation, ES:DI=buffer
    mov ah, SYS_GET_E820
    int 0x80

    jc .mem_e820_done               ; CF set = end of map or error

    push ebx                        ; Save continuation value

    ; Print base address (4 bytes, big-endian display)
    mov si, msg_e820_base
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov al, [e820_buf+3]
    mov ah, SYS_PRINT_HEX8
    int 0x80
    mov al, [e820_buf+2]
    mov ah, SYS_PRINT_HEX8
    int 0x80
    mov al, [e820_buf+1]
    mov ah, SYS_PRINT_HEX8
    int 0x80
    mov al, [e820_buf]
    mov ah, SYS_PRINT_HEX8
    int 0x80

    ; Print length (4 bytes at offset 8)
    mov si, msg_e820_len
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov al, [e820_buf+11]
    mov ah, SYS_PRINT_HEX8
    int 0x80
    mov al, [e820_buf+10]
    mov ah, SYS_PRINT_HEX8
    int 0x80
    mov al, [e820_buf+9]
    mov ah, SYS_PRINT_HEX8
    int 0x80
    mov al, [e820_buf+8]
    mov ah, SYS_PRINT_HEX8
    int 0x80

    ; Print type number
    mov si, msg_e820_type
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov al, [e820_buf+16]
    add al, '0'                     ; Convert type number to ASCII digit
    mov ah, SYS_PRINT_CHAR
    int 0x80

    ; Print type name string
    mov al, [e820_buf+16]
    mov si, msg_type_usable
    cmp al, 1
    je .mem_print_type
    mov si, msg_type_reserved
    cmp al, 2
    je .mem_print_type
    mov si, msg_type_acpi
    cmp al, 3
    je .mem_print_type
    mov si, msg_type_nvs
    cmp al, 4
    je .mem_print_type
    mov si, msg_type_bad
    cmp al, 5
    je .mem_print_type
    mov si, msg_type_unknown
.mem_print_type:
    mov ah, SYS_PRINT_STRING
    int 0x80

    pop ebx                         ; Restore continuation value
    test ebx, ebx                   ; EBX=0 means end of map
    jnz .mem_e820_loop

.mem_e820_done:
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80
    jmp shell_prompt

