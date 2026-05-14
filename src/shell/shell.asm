; =============================================================================
; Mini-OS Shell (SHELL.BIN) - Interactive Command Shell (User-Mode Executable)
;
; Loaded by KERNEL.BIN into memory at 0x3000.  Provides the interactive
; command-line interface for mini-os.
;
; This is a user-mode executable (MNEX).  ALL hardware access goes through
; the kernel's INT 0x80 syscall interface — no direct BIOS calls or port I/O.
;
; The Boot Info Block (BIB) is obtained via SYS_GET_BIB (not hard-coded).
;   Offset 0: boot_drive  (1 byte)  — BIOS drive number
;   Offset 1: a20_status  (1 byte)  — A20 gate result (1=enabled, 0=failed)
;   Offset 2: part_lba    (4 bytes) — partition start LBA
;
; Header layout (first 6 bytes):
;   Offset 0: 'MNEX'   Magic identifier (4 bytes)  — user-mode executable
;   Offset 4: dw N     Shell size in sectors
;
; Available commands:
;   sysinfo  - Display 5 pages of system information
;   mem      - Detailed memory info and layout
;   ver      - Show version and build info
;   help     - List available commands
;   cls      - Clear the screen
;   reboot   - Warm-reboot the system
;
; Assembled with:  nasm -f bin -o shell.bin src/shell/shell.asm
; =============================================================================

%include "syscalls.inc"
%include "mnfs.inc"

[BITS 16]
[ORG 0x3000]                        ; Kernel loads us here

; =============================================================================
; SHELL HEADER
; =============================================================================
shell_magic     db 'MNEX'           ; Magic identifier — user-mode executable
shell_sectors   dw 12               ; Shell size in sectors (updated as needed)

; =============================================================================
; SHELL INIT
;
; 1. Clear screen via syscall
; 2. Print banner
; 3. Fall through to prompt loop
; =============================================================================
shell_init:
    ; Clear screen via kernel syscall (sets video mode 3 = 80x25 color text)
    mov ah, SYS_CLEAR_SCREEN
    int 0x80

    ; Debug: shell starting
    mov bx, dbg_tag
    mov si, dbg_init
    mov ah, SYS_DBG_PRINT
    int 0x80

    ; Print banner via kernel syscall
    mov si, msg_banner
    mov ah, SYS_PRINT_STRING
    int 0x80

; --- Prompt loop (returns here after each command) ---------------------------
shell_prompt:
    ; Print the shell prompt
    mov si, msg_prompt
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; Read a line of user input into cmd_buf (up to 31 chars)
    call readline

    ; Debug: log the command entered
    mov bx, dbg_tag
    mov si, cmd_buf
    mov ah, SYS_DBG_PRINT
    int 0x80

    ; --- Command dispatch ----------------------------------------------------
    ; Empty input (just pressed Enter) -> re-prompt
    cmp byte [cmd_buf], 0
    je shell_prompt

    ; "sysinfo"
    mov si, cmd_buf
    mov di, str_sysinfo
    call strcmp
    je cmd_sysinfo

    ; "help"
    mov si, cmd_buf
    mov di, str_help
    call strcmp
    je cmd_help

    ; "mem"
    mov si, cmd_buf
    mov di, str_mem
    call strcmp
    je cmd_mem

    ; "cls"
    mov si, cmd_buf
    mov di, str_cls
    call strcmp
    je cmd_cls

    ; "ver"
    mov si, cmd_buf
    mov di, str_ver
    call strcmp
    je cmd_ver

    ; "reboot"
    mov si, cmd_buf
    mov di, str_reboot
    call strcmp
    je cmd_reboot

    ; "dir"
    mov si, cmd_buf
    mov di, str_dir
    call strcmp
    je cmd_dir

    ; Unknown command — print error and re-prompt
    mov bx, dbg_tag
    mov si, dbg_unknown
    mov ah, SYS_DBG_PRINT
    int 0x80
    mov si, msg_unknown
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov si, cmd_buf
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80
    jmp shell_prompt

; =============================================================================
; COMMAND: cls
; Clear the screen and re-display the banner.
; =============================================================================
cmd_cls:
    jmp shell_init                  ; Re-init clears screen + prints banner

; =============================================================================
; COMMAND: reboot
; Perform a warm reboot via kernel syscall.
; No direct memory writes — the kernel handles the reset vector.
; =============================================================================
cmd_reboot:
    mov ah, SYS_REBOOT              ; Ask kernel to warm-reboot
    int 0x80                        ; Does not return

; =============================================================================
; COMMAND: help
; Print a list of available commands with brief descriptions.
; =============================================================================
cmd_help:
    mov si, msg_help_text
    mov ah, SYS_PRINT_STRING
    int 0x80
    jmp shell_prompt

; =============================================================================
; COMMAND: ver
; Print version and build information.
; =============================================================================
cmd_ver:
    mov si, msg_ver_text
    mov ah, SYS_PRINT_STRING
    int 0x80
    jmp shell_prompt

; =============================================================================
; COMMAND: dir
; List files in the MNFS filesystem via INT 0x81 (FS.BIN).
;
; Calls FS_LIST_FILES to get the cached directory, then parses and displays
; each entry in a formatted table.
; =============================================================================
cmd_dir:
    ; Print header
    mov si, msg_dir_hdr
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; Call FS_LIST_FILES — copies directory into our buffer
    mov ah, FS_LIST_FILES
    push ds
    pop es                          ; ES = DS (our segment)
    mov bx, dir_buffer              ; ES:BX → 512-byte buffer
    int 0x81                        ; CL = file count

    ; Save file count
    movzx cx, cl
    test cx, cx
    jz .dir_empty
    mov [dir_file_count], cx

    ; Print column headers
    mov si, msg_dir_cols
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; SI → first directory entry (offset 32 in buffer = past header)
    mov si, dir_buffer + MNFS_HDR_SIZE
    mov cx, [dir_file_count]
    xor dx, dx                      ; DX = total bytes accumulator (low word)

.dir_loop:
    push cx
    push dx

    ; Print "  " indent
    push si
    mov si, msg_dir_indent
    mov ah, SYS_PRINT_STRING
    int 0x80
    pop si

    ; Print filename (8 bytes) — SI → entry name field
    push si
    mov cx, 8
.dir_print_name:
    lodsb
    mov ah, SYS_PRINT_CHAR
    int 0x80
    dec cx
    jnz .dir_print_name

    ; Print dot between name and extension
    mov al, '.'
    mov ah, SYS_PRINT_CHAR
    int 0x80

    ; Print extension (3 bytes)
    mov cx, 3
.dir_print_ext:
    lodsb
    mov ah, SYS_PRINT_CHAR
    int 0x80
    dec cx
    jnz .dir_print_ext
    pop si                          ; Restore SI to entry start

    ; Print spaces + attribute type
    push si
    mov si, msg_dir_space
    mov ah, SYS_PRINT_STRING
    int 0x80
    pop si

    ; Check attributes at entry + 11
    mov al, [si + MNFS_ENT_ATTR]
    test al, MNFS_ATTR_SYSTEM
    jnz .dir_sys
    test al, MNFS_ATTR_EXEC
    jnz .dir_exe
    ; Data file
    push si
    mov si, msg_dir_dat
    mov ah, SYS_PRINT_STRING
    int 0x80
    pop si
    jmp .dir_size

.dir_sys:
    push si
    mov si, msg_dir_sys
    mov ah, SYS_PRINT_STRING
    int 0x80
    pop si
    jmp .dir_size

.dir_exe:
    push si
    mov si, msg_dir_exe
    mov ah, SYS_PRINT_STRING
    int 0x80
    pop si

.dir_size:
    ; Print size in sectors, right-justified in 3-char field
    mov dx, [si + MNFS_ENT_SECTORS]
    mov cl, 3
    call rjust_dec16

    push si
    mov si, msg_dir_sec_suffix
    mov ah, SYS_PRINT_STRING
    int 0x80
    pop si

    ; Print size in bytes, right-justified in 6-char field
    mov dx, [si + MNFS_ENT_BYTES]
    push dx                         ; Save for total accumulation
    mov cl, 6
    call rjust_dec16

    push si
    mov si, msg_dir_bytes_suffix
    mov ah, SYS_PRINT_STRING
    int 0x80
    pop si

    ; Accumulate total bytes
    pop ax                          ; AX = this file's size (low word)
    pop dx                          ; DX = running total
    add dx, ax
    push dx

    ; Advance to next entry
    add si, MNFS_ENTRY_SIZE
    pop dx
    pop cx
    dec cx
    jnz .dir_loop

    ; Print summary line
    push dx                         ; Save total bytes
    mov si, msg_dir_sep
    mov ah, SYS_PRINT_STRING
    int 0x80

    mov dx, [dir_file_count]
    mov ah, SYS_PRINT_DEC16
    int 0x80

    mov si, msg_dir_summary
    mov ah, SYS_PRINT_STRING
    int 0x80

    pop dx                          ; DX = total bytes
    mov ah, SYS_PRINT_DEC16
    int 0x80

    mov si, msg_dir_total_bytes
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; --- Disk space statistics via FS_GET_INFO --------------------------------
    mov ah, FS_GET_INFO             ; Returns: DX=used sectors, BX=capacity
    int 0x81

    ; Save returned values
    mov [dir_used_sec], dx
    mov [dir_cap_sec], bx

    ; "  Used:  X KB / Y KB"
    mov si, msg_dir_used
    mov ah, SYS_PRINT_STRING
    int 0x80

    mov dx, [dir_used_sec]
    shr dx, 1                       ; Sectors → KB (÷2)
    mov cl, 6
    call rjust_dec16

    mov si, msg_dir_of
    mov ah, SYS_PRINT_STRING
    int 0x80

    mov dx, [dir_cap_sec]
    shr dx, 1                       ; Sectors → KB
    mov ah, SYS_PRINT_DEC16
    int 0x80

    mov si, msg_dir_kb
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; "  Free:  X KB"
    mov si, msg_dir_free
    mov ah, SYS_PRINT_STRING
    int 0x80

    mov dx, [dir_cap_sec]
    sub dx, [dir_used_sec]
    shr dx, 1                       ; Sectors → KB
    mov cl, 6
    call rjust_dec16

    mov si, msg_dir_kb
    mov ah, SYS_PRINT_STRING
    int 0x80

    jmp shell_prompt

.dir_empty:
    mov si, msg_dir_empty
    mov ah, SYS_PRINT_STRING
    int 0x80
    jmp shell_prompt

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

; =============================================================================
; COMMAND: sysinfo
; Display 5 pages of system information, pausing between each page.
; All hardware queries go through INT 0x80 syscalls.
; =============================================================================
cmd_sysinfo:
    ; =========================================================================
    ; PAGE 1 — CPU Information (CPUID via syscall)
    ; =========================================================================
    mov ah, SYS_CLEAR_SCREEN        ; Clear screen for page 1
    int 0x80

    mov si, msg_page1_hdr
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; --- Check CPUID support via kernel syscall ------------------------------
    mov ah, SYS_CHECK_CPUID         ; Returns AL=1 if CPUID supported
    int 0x80
    test al, al
    jz .no_cpuid

    ; --- CPUID leaf 0: Vendor string via SYS_CPUID ---------------------------
    ; Leaf number goes in EDI (kernel moves it to EAX before executing CPUID)
    xor edi, edi                    ; EDI = 0 (leaf 0: vendor string)
    mov ah, SYS_CPUID
    int 0x80
    ; Returns: EBX:EDX:ECX = vendor string (12 bytes)
    mov [cpuid_vendor], ebx
    mov [cpuid_vendor+4], edx
    mov [cpuid_vendor+8], ecx
    mov byte [cpuid_vendor+12], 0

    mov si, msg_cpu_vendor
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov si, cpuid_vendor
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; --- CPUID leaf 1: Version and feature flags -----------------------------
    mov edi, 1                      ; EDI = 1 (leaf 1: version info)
    mov ah, SYS_CPUID
    int 0x80
    ; Returns: EAX=version, EDX=feature flags, ECX=extended features
    mov [cpuid_ver], eax
    mov [cpuid_feat_edx], edx
    mov [cpuid_feat_ecx], ecx

    ; Print CPU family
    mov si, msg_cpu_family
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov eax, [cpuid_ver]
    shr eax, 8
    and ax, 0x0F
    mov dx, ax
    mov ah, SYS_PRINT_DEC16
    int 0x80
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; Print CPU model
    mov si, msg_cpu_model
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov eax, [cpuid_ver]
    shr eax, 4
    and ax, 0x0F
    mov dx, ax
    mov ah, SYS_PRINT_DEC16
    int 0x80
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; Print CPU stepping
    mov si, msg_cpu_step
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov eax, [cpuid_ver]
    and ax, 0x0F
    mov dx, ax
    mov ah, SYS_PRINT_DEC16
    int 0x80
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; --- Feature flags -------------------------------------------------------
    mov si, msg_cpu_feat
    mov ah, SYS_PRINT_STRING
    int 0x80

    mov edx, [cpuid_feat_edx]

    test edx, 1                     ; Bit 0: FPU
    jz .no_fpu
    mov si, msg_f_fpu
    mov ah, SYS_PRINT_STRING
    int 0x80
.no_fpu:
    test edx, (1<<4)                ; Bit 4: TSC
    jz .no_tsc
    mov si, msg_f_tsc
    mov ah, SYS_PRINT_STRING
    int 0x80
.no_tsc:
    test edx, (1<<5)                ; Bit 5: MSR
    jz .no_msr
    mov si, msg_f_msr
    mov ah, SYS_PRINT_STRING
    int 0x80
.no_msr:
    test edx, (1<<8)                ; Bit 8: CX8
    jz .no_cx8
    mov si, msg_f_cx8
    mov ah, SYS_PRINT_STRING
    int 0x80
.no_cx8:
    test edx, (1<<13)               ; Bit 13: PGE
    jz .no_pge
    mov si, msg_f_pge
    mov ah, SYS_PRINT_STRING
    int 0x80
.no_pge:
    test edx, (1<<15)               ; Bit 15: CMOV
    jz .no_cmov
    mov si, msg_f_cmov
    mov ah, SYS_PRINT_STRING
    int 0x80
.no_cmov:
    test edx, (1<<23)               ; Bit 23: MMX
    jz .no_mmx
    mov si, msg_f_mmx
    mov ah, SYS_PRINT_STRING
    int 0x80
.no_mmx:
    test edx, (1<<25)               ; Bit 25: SSE
    jz .no_sse
    mov si, msg_f_sse
    mov ah, SYS_PRINT_STRING
    int 0x80
.no_sse:
    test edx, (1<<26)               ; Bit 26: SSE2
    jz .no_sse2
    mov si, msg_f_sse2
    mov ah, SYS_PRINT_STRING
    int 0x80
.no_sse2:

    mov ecx, [cpuid_feat_ecx]

    test ecx, 1                     ; Bit 0: SSE3
    jz .no_sse3
    mov si, msg_f_sse3
    mov ah, SYS_PRINT_STRING
    int 0x80
.no_sse3:
    test ecx, (1<<19)               ; Bit 19: SSE4.1
    jz .no_sse41
    mov si, msg_f_sse41
    mov ah, SYS_PRINT_STRING
    int 0x80
.no_sse41:
    test ecx, (1<<20)               ; Bit 20: SSE4.2
    jz .no_sse42
    mov si, msg_f_sse42
    mov ah, SYS_PRINT_STRING
    int 0x80
.no_sse42:

    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; --- Hypervisor detection ------------------------------------------------
    mov ecx, [cpuid_feat_ecx]
    test ecx, (1<<31)               ; Bit 31: Hypervisor present
    jz .no_hypervisor

    mov si, msg_hv_yes
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; CPUID leaf 0x40000000: hypervisor vendor string via syscall
    mov edi, 0x40000000             ; EDI = hypervisor info leaf
    mov ah, SYS_CPUID
    int 0x80
    mov [cpuid_vendor], ebx
    mov [cpuid_vendor+4], ecx
    mov [cpuid_vendor+8], edx
    mov byte [cpuid_vendor+12], 0

    mov si, msg_hv_vendor
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov si, cpuid_vendor
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80
    jmp .cpuid_done

.no_hypervisor:
    mov si, msg_hv_no
    mov ah, SYS_PRINT_STRING
    int 0x80
    jmp .cpuid_done

.no_cpuid:
    mov si, msg_no_cpuid
    mov ah, SYS_PRINT_STRING
    int 0x80

.cpuid_done:
    ; Wait for keypress, then clear screen for next page
    mov ah, SYS_WAIT_KEY
    int 0x80

    ; =========================================================================
    ; PAGE 2 — Memory
    ; =========================================================================
    mov si, msg_page2_hdr
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; Conventional memory via syscall
    mov si, msg_conv_mem
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov ah, SYS_GET_CONV_MEM        ; Returns AX = conventional KB
    int 0x80
    mov dx, ax
    mov ah, SYS_PRINT_DEC16
    int 0x80
    mov si, msg_kb
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; Extended memory via syscall
    mov si, msg_ext_mem
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov ah, SYS_GET_EXT_MEM         ; Returns AX = extended KB, CF=err
    int 0x80
    jc .no_ext
    mov dx, ax
    mov ah, SYS_PRINT_DEC16
    int 0x80
    mov si, msg_kb
    mov ah, SYS_PRINT_STRING
    int 0x80
    jmp .e820_start
.no_ext:
    mov si, msg_na
    mov ah, SYS_PRINT_STRING
    int 0x80

.e820_start:
    ; E820 memory map via SYS_GET_E820
    mov si, msg_e820_hdr
    mov ah, SYS_PRINT_STRING
    int 0x80

    xor ebx, ebx                    ; Start E820 enumeration
    mov di, e820_buf

.e820_loop:
    mov ah, SYS_GET_E820            ; EBX=continuation, ES:DI=buffer
    int 0x80

    jc .e820_done
    push ebx

    ; Print base address (4 bytes)
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

    ; Print type number and name
    mov si, msg_e820_type
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov al, [e820_buf+16]
    add al, '0'
    mov ah, SYS_PRINT_CHAR
    int 0x80

    mov al, [e820_buf+16]
    mov si, msg_type_usable
    cmp al, 1
    je .print_type
    mov si, msg_type_reserved
    cmp al, 2
    je .print_type
    mov si, msg_type_acpi
    cmp al, 3
    je .print_type
    mov si, msg_type_nvs
    cmp al, 4
    je .print_type
    mov si, msg_type_bad
    cmp al, 5
    je .print_type
    mov si, msg_type_unknown
.print_type:
    mov ah, SYS_PRINT_STRING
    int 0x80

    pop ebx
    test ebx, ebx
    jnz .e820_loop

.e820_done:
    mov ah, SYS_WAIT_KEY            ; Wait for keypress, clear screen
    int 0x80

    ; =========================================================================
    ; PAGE 3 — BIOS Data Area (via SYS_GET_BDA_BYTE / SYS_GET_BDA_WORD)
    ;
    ; Instead of reading memory at 0x0400+ directly, we use kernel syscalls
    ; that safely read BDA values for us.
    ; =========================================================================
    mov si, msg_page3_hdr
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; --- COM ports (BDA 0x0400, 0x0402, 0x0404, 0x0406) ----------------------
    mov si, msg_com_hdr
    mov ah, SYS_PRINT_STRING
    int 0x80

    mov cx, 4                       ; 4 COM ports
    mov word [bda_offset], 0x0400   ; Starting BDA offset for COM1

.com_loop:
    push cx
    mov si, msg_indent
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; Print "COM" label
    mov al, 'C'
    mov ah, SYS_PRINT_CHAR
    int 0x80
    mov al, 'O'
    mov ah, SYS_PRINT_CHAR
    int 0x80
    mov al, 'M'
    mov ah, SYS_PRINT_CHAR
    int 0x80

    ; Print port number (5 - cx = 1,2,3,4)
    mov al, 5
    pop cx
    push cx
    sub al, cl
    add al, '0'
    mov ah, SYS_PRINT_CHAR
    int 0x80
    mov al, ':'
    mov ah, SYS_PRINT_CHAR
    int 0x80
    mov al, ' '
    mov ah, SYS_PRINT_CHAR
    int 0x80

    ; Read COM port address from BDA via syscall
    mov bx, [bda_offset]
    mov ah, SYS_GET_BDA_WORD        ; BX=BDA offset; Returns AX=word
    int 0x80
    test ax, ax
    jz .com_none

    ; Port present — print its I/O address as hex
    mov dx, ax
    mov ah, SYS_PRINT_HEX16
    int 0x80
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80
    jmp .com_next

.com_none:
    mov si, msg_not_present
    mov ah, SYS_PRINT_STRING
    int 0x80

.com_next:
    add word [bda_offset], 2        ; Next COM port offset
    pop cx
    dec cx
    jnz .com_loop

    ; --- LPT ports (BDA 0x0408, 0x040A, 0x040C) -----------------------------
    mov si, msg_lpt_hdr
    mov ah, SYS_PRINT_STRING
    int 0x80

    mov cx, 3                       ; 3 LPT ports
    mov word [bda_offset], 0x0408   ; Starting BDA offset for LPT1

.lpt_loop:
    push cx
    mov si, msg_indent
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; Print "LPT" label
    mov al, 'L'
    mov ah, SYS_PRINT_CHAR
    int 0x80
    mov al, 'P'
    mov ah, SYS_PRINT_CHAR
    int 0x80
    mov al, 'T'
    mov ah, SYS_PRINT_CHAR
    int 0x80

    ; Print port number (4 - cx = 1,2,3)
    mov al, 4
    pop cx
    push cx
    sub al, cl
    add al, '0'
    mov ah, SYS_PRINT_CHAR
    int 0x80
    mov al, ':'
    mov ah, SYS_PRINT_CHAR
    int 0x80
    mov al, ' '
    mov ah, SYS_PRINT_CHAR
    int 0x80

    ; Read LPT port address from BDA via syscall
    mov bx, [bda_offset]
    mov ah, SYS_GET_BDA_WORD        ; BX=BDA offset; Returns AX=word
    int 0x80
    test ax, ax
    jz .lpt_none

    mov dx, ax
    mov ah, SYS_PRINT_HEX16
    int 0x80
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80
    jmp .lpt_next

.lpt_none:
    mov si, msg_not_present
    mov ah, SYS_PRINT_STRING
    int 0x80

.lpt_next:
    add word [bda_offset], 2
    pop cx
    dec cx
    jnz .lpt_loop

    ; --- Equipment word via SYS_GET_EQUIP ------------------------------------
    mov si, msg_equip
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov ah, SYS_GET_EQUIP           ; Returns AX = equipment word
    int 0x80
    mov dx, ax
    mov ah, SYS_PRINT_HEX16
    int 0x80
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; --- Video mode from BDA (offset 0x0449) via syscall ---------------------
    mov si, msg_vid_mode_bda
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov bx, 0x0449                  ; BDA offset for current video mode
    mov ah, SYS_GET_BDA_BYTE        ; Returns AL = byte at BDA offset
    int 0x80
    mov ah, SYS_PRINT_HEX8          ; Print video mode as hex
    int 0x80
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; --- Screen columns from BDA (offset 0x044A) ----------------------------
    mov si, msg_vid_cols
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov bx, 0x044A                  ; BDA offset for screen columns
    mov ah, SYS_GET_BDA_WORD        ; Returns AX = word
    int 0x80
    mov dx, ax
    mov ah, SYS_PRINT_DEC16
    int 0x80
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; --- Video page size from BDA (offset 0x044C) ----------------------------
    mov si, msg_vid_pagesz
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov bx, 0x044C                  ; BDA offset for video page size
    mov ah, SYS_GET_BDA_WORD
    int 0x80
    mov dx, ax
    mov ah, SYS_PRINT_DEC16
    int 0x80
    mov si, msg_bytes
    mov ah, SYS_PRINT_STRING
    int 0x80

    mov ah, SYS_WAIT_KEY            ; Wait for keypress, clear screen
    int 0x80

    ; =========================================================================
    ; PAGE 4 — Video & Disk
    ; =========================================================================
    mov si, msg_page4_hdr
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; --- Active video mode via SYS_GET_VIDEO ---------------------------------
    mov si, msg_vid_active
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov ah, SYS_GET_VIDEO           ; Returns AL=mode, AH=cols, BH=page
    int 0x80
    push bx                         ; Save BH=display page
    push ax                         ; Save AL=video mode
    mov ah, SYS_PRINT_HEX8          ; Print video mode (AL) as hex
    int 0x80
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; --- Active display page -------------------------------------------------
    mov si, msg_vid_page
    mov ah, SYS_PRINT_STRING
    int 0x80
    pop ax                          ; Restore saved AX (balance stack)
    pop bx                          ; BH = display page
    mov al, bh
    mov ah, SYS_PRINT_HEX8
    int 0x80
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; --- Video memory base (determined from BDA video mode) ------------------
    mov si, msg_vid_base
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov bx, 0x0449                  ; BDA offset for video mode
    mov ah, SYS_GET_BDA_BYTE
    int 0x80
    cmp al, 0x07                    ; Mode 7 = monochrome
    je .mono_base
    mov si, msg_b8000
    jmp .print_vbase
.mono_base:
    mov si, msg_b0000
.print_vbase:
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; --- Cursor position via SYS_GET_CURSOR ----------------------------------
    mov si, msg_cursor
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov ah, SYS_GET_CURSOR          ; Returns DH=row, DL=col
    int 0x80
    mov al, dh                      ; Print row
    mov ah, SYS_PRINT_HEX8
    int 0x80
    mov al, ','
    mov ah, SYS_PRINT_CHAR
    int 0x80
    mov al, dl                      ; Print column
    mov ah, SYS_PRINT_HEX8
    int 0x80
    mov si, msg_cursor_rc
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; --- Boot drive info (from BIB via SYS_GET_BIB) --------------------------
    mov si, msg_boot_drv
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov ah, SYS_GET_BIB             ; Returns ES:BX = BIB base
    int 0x80
    mov al, [es:bx]                 ; BIB+0 = boot drive number
    mov ah, SYS_PRINT_HEX8
    int 0x80
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; --- Drive geometry via SYS_GET_DRIVE_INFO -------------------------------
    mov si, msg_drv_geom
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; Get boot drive from BIB for the geometry query
    push es
    push bx
    mov ah, SYS_GET_BIB
    int 0x80
    mov dl, [es:bx]                 ; DL = boot drive number
    pop bx
    pop es

    mov ah, SYS_GET_DRIVE_INFO      ; Returns: CH,CL,DH,DL geometry; CF=err
    int 0x80
    jc .no_geom

    push dx                         ; Save DH=max head number

    ; Cylinders (CH = low 8 bits, CL bits 7-6 = high 2 bits)
    mov si, msg_drv_cyl
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov al, cl
    shr al, 6                       ; High 2 bits of cylinder count
    mov ah, SYS_PRINT_HEX8
    int 0x80
    mov al, ch                      ; Low 8 bits of cylinder count
    mov ah, SYS_PRINT_HEX8
    int 0x80
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; Sectors per track (CL bits 5-0)
    mov si, msg_drv_sec
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov al, cl
    and al, 0x3F                    ; Mask to 6 bits = sectors/track
    movzx dx, al
    mov ah, SYS_PRINT_DEC16
    int 0x80
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; Heads (DH = max head number, +1 = count)
    pop dx
    mov si, msg_drv_head
    mov ah, SYS_PRINT_STRING
    int 0x80
    mov al, dh
    inc al                          ; DH is max head index, +1 = total heads
    movzx dx, al
    mov ah, SYS_PRINT_DEC16
    int 0x80
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80
    jmp .geom_done

.no_geom:
    mov si, msg_na
    mov ah, SYS_PRINT_STRING
    int 0x80

.geom_done:

    ; --- EDD support via SYS_GET_EDD -----------------------------------------
    ; Only basic EDD check (installation check).  Extended params skipped
    ; because there is no syscall for INT 13h AH=48h.
    mov si, msg_edd_hdr
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; Get boot drive from BIB
    push es
    push bx
    mov ah, SYS_GET_BIB
    int 0x80
    mov dl, [es:bx]                 ; DL = boot drive
    pop bx
    pop es

    mov ah, SYS_GET_EDD             ; DL=drive; Returns BX,AH,CX; CF=err
    int 0x80
    jc .no_edd
    cmp bx, 0xAA55                  ; EDD signature check
    jne .no_edd

    ; EDD supported — print version (AH has EDD version from BIOS)
    push ax                         ; Save AH=EDD version
    mov si, msg_edd_ver
    mov ah, SYS_PRINT_STRING
    int 0x80
    pop ax
    mov al, ah                      ; EDD version byte
    mov ah, SYS_PRINT_HEX8
    int 0x80
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; (Extended EDD params skipped — no syscall for INT 13h AH=48h)
    mov si, msg_edd_ext_skip
    mov ah, SYS_PRINT_STRING
    int 0x80
    jmp .edd_done

.no_edd:
    mov si, msg_edd_none
    mov ah, SYS_PRINT_STRING
    int 0x80

.edd_done:
    mov ah, SYS_WAIT_KEY
    int 0x80

    ; =========================================================================
    ; PAGE 5 — IVT Sample (Interrupt Vector Table via SYS_GET_IVT)
    ;
    ; Uses SYS_GET_IVT to read IVT entries instead of direct memory access.
    ; =========================================================================
    mov si, msg_page5_hdr
    mov ah, SYS_PRINT_STRING
    int 0x80

    mov byte [ivt_index], 0         ; Reset loop counter

.ivt_loop:
    cmp byte [ivt_index], 8
    jge .ivt_done

    mov si, msg_indent
    mov ah, SYS_PRINT_STRING
    int 0x80

    ; Print "INT " prefix
    mov al, 'I'
    mov ah, SYS_PRINT_CHAR
    int 0x80
    mov al, 'N'
    mov ah, SYS_PRINT_CHAR
    int 0x80
    mov al, 'T'
    mov ah, SYS_PRINT_CHAR
    int 0x80
    mov al, ' '
    mov ah, SYS_PRINT_CHAR
    int 0x80

    ; Print vector number as hex
    mov al, [ivt_index]
    mov ah, SYS_PRINT_HEX8
    int 0x80
    mov al, 'h'
    mov ah, SYS_PRINT_CHAR
    int 0x80
    mov al, ':'
    mov ah, SYS_PRINT_CHAR
    int 0x80
    mov al, ' '
    mov ah, SYS_PRINT_CHAR
    int 0x80

    ; Read IVT entry via SYS_GET_IVT
    mov cl, [ivt_index]             ; CL = vector number
    mov ah, SYS_GET_IVT             ; Returns AX=offset, DX=segment
    int 0x80
    push ax                         ; Save offset

    ; Print segment:offset — DX = segment from SYS_GET_IVT
    mov ah, SYS_PRINT_HEX16
    int 0x80
    mov al, ':'
    mov ah, SYS_PRINT_CHAR
    int 0x80
    pop dx                          ; Restore offset into DX
    mov ah, SYS_PRINT_HEX16
    int 0x80

    ; Print interrupt name from lookup table
    push bx
    xor bh, bh
    mov bl, [ivt_index]
    shl bx, 1                      ; Each entry is a word (2 bytes)
    mov si, [ivt_names_table + bx]
    mov ah, SYS_PRINT_STRING
    int 0x80
    pop bx

    inc byte [ivt_index]
    jmp .ivt_loop

.ivt_done:
    mov si, msg_sysinfo_done
    mov ah, SYS_PRINT_STRING
    int 0x80

    mov ah, SYS_WAIT_KEY
    int 0x80
    jmp shell_init

; =============================================================================
; SUBROUTINES
;
; Only pure-logic routines remain here.  All I/O routines (puts, putc,
; puthex8, print_hex16, print_dec16, wait_key, check_a20) have been removed
; because the kernel provides equivalent syscalls.
; =============================================================================

; ---------------------------------------------------------------------------
; readline — Read a line of input into cmd_buf (up to 31 chars).
;
; Uses SYS_READ_KEY for keyboard input and SYS_PRINT_CHAR for echo.
; Handles Enter (submit), Backspace (delete), and printable ASCII.
; Converts uppercase to lowercase for case-insensitive command matching.
; ---------------------------------------------------------------------------
readline:
    xor cx, cx                      ; CX = character count

.read_char:
    mov ah, SYS_READ_KEY            ; Wait for keypress via kernel syscall
    int 0x80                        ; Returns AH=scancode, AL=ASCII
    ; Note: AH now has scancode, not the syscall number anymore

    cmp al, 0x0D                    ; Enter key?
    je .read_done

    cmp al, 0x08                    ; Backspace?
    je .read_bs

    cmp al, 0x20                    ; Below space = control char -> skip
    jb .read_char
    cmp al, 0x7E                    ; Above '~' -> skip
    ja .read_char

    cmp cx, 31                      ; Buffer full?
    jge .read_char

    ; Convert uppercase to lowercase for case-insensitive matching
    cmp al, 'A'
    jb .no_lower
    cmp al, 'Z'
    ja .no_lower
    add al, 32
.no_lower:

    ; Store character in buffer
    mov bx, cmd_buf
    add bx, cx
    mov [bx], al
    inc cx

    ; Echo the character to screen via SYS_PRINT_CHAR
    mov ah, SYS_PRINT_CHAR
    int 0x80
    jmp .read_char

.read_bs:
    test cx, cx                     ; Nothing to delete?
    jz .read_char

    dec cx                          ; Remove last character

    ; Backspace echo: move cursor back, print space, move back again
    mov al, 0x08                    ; Backspace character
    mov ah, SYS_PRINT_CHAR
    int 0x80
    mov al, ' '                     ; Overwrite with space
    mov ah, SYS_PRINT_CHAR
    int 0x80
    mov al, 0x08                    ; Move cursor back again
    mov ah, SYS_PRINT_CHAR
    int 0x80
    jmp .read_char

.read_done:
    ; NUL-terminate the input buffer
    mov bx, cmd_buf
    add bx, cx
    mov byte [bx], 0
    mov [cmd_len], cl

    ; Print newline after the entered command
    mov si, msg_crlf
    mov ah, SYS_PRINT_STRING
    int 0x80
    ret

; ---------------------------------------------------------------------------
; strcmp — Compare two NUL-terminated strings (case-sensitive).
;   Input:  DS:SI -> string 1, DS:DI -> string 2
;   Output: ZF set if strings are equal
;
; Pure logic — no hardware access, no syscalls needed.
; ---------------------------------------------------------------------------
strcmp:
    push si
    push di
.cmp_loop:
    lodsb
    mov ah, [di]
    inc di
    cmp al, ah
    jne .cmp_ne
    test al, al
    jnz .cmp_loop
    pop di
    pop si
    ret                             ; ZF is set (equal)

.cmp_ne:
    pop di
    pop si
    or al, 1                        ; Clear ZF (not equal)
    ret

; ---------------------------------------------------------------------------
; rjust_dec16 — Print DX as unsigned decimal, right-justified in CL-wide field
;
; Input:  DX = value to print, CL = minimum field width
; Output: none
; Preserves: AX, BX, CX, DX, SI, DI
; ---------------------------------------------------------------------------
rjust_dec16:
    push ax
    push bx
    push cx
    push dx

    ; Count digits of DX
    mov ax, dx
    xor ch, ch                      ; CH = digit count
.rj_count:
    inc ch
    xor dx, dx
    mov bx, 10
    div bx
    test ax, ax
    jnz .rj_count

    ; Print (CL - CH) leading spaces
    sub cl, ch
    jbe .rj_print
.rj_pad:
    push cx
    mov al, ' '
    mov ah, SYS_PRINT_CHAR
    int 0x80
    pop cx
    dec cl
    jnz .rj_pad

.rj_print:
    pop dx                          ; Restore original value
    mov ah, SYS_PRINT_DEC16
    int 0x80

    pop cx
    pop bx
    pop ax
    ret

; =============================================================================
; DATA — String constants
; =============================================================================

; --- Shell strings -----------------------------------------------------------
msg_banner      db 13, 10
                db '  MNOS v0.7.2', 13, 10
                db 13, 10, 0

msg_prompt      db 'mnos:\>', 0

msg_unknown     db 'Unknown command: ', 0

msg_help_text   db 'Available commands:', 13, 10
                db '  sysinfo  - Display system information (5 pages)', 13, 10
                db '  mem      - Detailed memory info and layout', 13, 10
                db '  dir      - List files on disk (MNFS)', 13, 10
                db '  ver      - Show version and build info', 13, 10
                db '  help     - Show this help message', 13, 10
                db '  cls      - Clear the screen', 13, 10
                db '  reboot   - Restart the system', 13, 10, 0

; --- Command name strings (for strcmp) ----------------------------------------
str_sysinfo     db 'sysinfo', 0
str_help        db 'help', 0
str_mem         db 'mem', 0
str_ver         db 'ver', 0
str_cls         db 'cls', 0
str_reboot      db 'reboot', 0
str_dir         db 'dir', 0

; --- ver command strings -----------------------------------------------------
msg_ver_text    db '  MNOS v0.7.2', 13, 10
                db '  Arch:      x86 real mode (16-bit)', 13, 10
                db '  Assembler: NASM', 13, 10
                db '  Platform:  Hyper-V Gen 1', 13, 10
                db '  Boot:      MBR -> VBR -> LOADER -> KERNEL -> SHELL', 13, 10
                db '  Filesystem: MNFS v1 (flat, INT 0x81)', 13, 10
                db '  Disk:      16 MB fixed VHD', 13, 10
                db '  Source:    github.com/ambaner/mini-os', 13, 10, 0

; --- Sysinfo page headers ----------------------------------------------------
msg_page1_hdr   db '--- Page 1: CPU Information ---', 13, 10, 0
msg_page2_hdr   db 13, 10, '--- Page 2: Memory ---', 13, 10, 0
msg_page3_hdr   db 13, 10, '--- Page 3: BIOS Data Area ---', 13, 10, 0
msg_page4_hdr   db 13, 10, '--- Page 4: Video & Disk ---', 13, 10, 0
msg_page5_hdr   db 13, 10, '--- Page 5: IVT (Interrupt Vector Table) ---', 13, 10, 0

; --- Memory strings ----------------------------------------------------------
msg_conv_mem    db '  Conv. memory: ', 0
msg_ext_mem     db '  Ext. memory:  ', 0
msg_kb          db ' KB', 13, 10, 0
msg_na          db 'N/A', 13, 10, 0
msg_e820_hdr    db '  E820 Memory Map:', 13, 10, 0
msg_e820_base   db '    Base=', 0
msg_e820_len    db ' Len=', 0
msg_e820_type   db ' Type=', 0

; E820 type names
msg_type_usable   db ' (Usable)', 13, 10, 0
msg_type_reserved db ' (Reserved)', 13, 10, 0
msg_type_acpi     db ' (ACPI)', 13, 10, 0
msg_type_nvs      db ' (ACPI NVS)', 13, 10, 0
msg_type_bad      db ' (Bad)', 13, 10, 0
msg_type_unknown  db ' (?)', 13, 10, 0

; --- BDA strings -------------------------------------------------------------
msg_com_hdr     db '  COM Ports:', 13, 10, 0
msg_lpt_hdr     db '  LPT Ports:', 13, 10, 0
msg_equip       db '  Equipment word: ', 0
msg_vid_mode_bda db '  Video mode (BDA): ', 0
msg_vid_cols    db '  Screen columns:   ', 0
msg_vid_pagesz  db '  Video page size:  ', 0
msg_bytes       db ' bytes', 13, 10, 0
msg_not_present db 'N/A', 13, 10, 0

; --- Video & Disk strings ----------------------------------------------------
msg_vid_active  db '  Video mode:    ', 0
msg_vid_page    db '  Display page:  ', 0
msg_vid_base    db '  Video mem base: ', 0
msg_b8000       db '0xB8000 (color)', 13, 10, 0
msg_b0000       db '0xB0000 (mono)', 13, 10, 0
msg_cursor      db '  Cursor pos:    ', 0
msg_cursor_rc   db ' (row,col)', 13, 10, 0
msg_boot_drv    db '  Boot drive:    ', 0
msg_drv_geom    db '  Drive geometry:', 13, 10, 0
msg_drv_cyl     db '    Cylinders: ', 0
msg_drv_sec     db '    Sectors:   ', 0
msg_drv_head    db '    Heads:     ', 0

; --- EDD strings -------------------------------------------------------------
msg_edd_hdr     db '  EDD Support:', 13, 10, 0
msg_edd_ver     db '    Version:       ', 0
msg_edd_ext_skip db '    (Extended params not available via syscall)', 13, 10, 0
msg_edd_none    db '    Not available', 13, 10, 0

; --- IVT strings -------------------------------------------------------------
ivt_names_table:
    dw msg_ivt_00, msg_ivt_01, msg_ivt_02, msg_ivt_03
    dw msg_ivt_04, msg_ivt_05, msg_ivt_06, msg_ivt_07

msg_ivt_00      db '  Divide/0', 13, 10, 0
msg_ivt_01      db '  Debug', 13, 10, 0
msg_ivt_02      db '  NMI', 13, 10, 0
msg_ivt_03      db '  Breakpoint', 13, 10, 0
msg_ivt_04      db '  Overflow', 13, 10, 0
msg_ivt_05      db '  BOUND/PrtSc', 13, 10, 0
msg_ivt_06      db '  Invalid Op', 13, 10, 0
msg_ivt_07      db '  No Coproc', 13, 10, 0

; --- Sysinfo done message ----------------------------------------------------
msg_sysinfo_done db 13, 10, '  System info complete.', 13, 10, 0

; --- mem command strings -----------------------------------------------------
msg_mem_hdr     db 13, 10, '--- Memory Information ---', 13, 10, 0

msg_a20         db '  A20 gate:     ', 0
msg_a20_on      db 'Enabled (set by loader at boot)', 13, 10, 0
msg_a20_off     db 'FAILED - all 3 methods failed', 13, 10, 0
msg_a20_live    db '  A20 verify:   ', 0
msg_a20_on_short  db 'OK', 13, 10, 0
msg_a20_off_short db 'FAIL (wrap detected)', 13, 10, 0

msg_layout_hdr  db 13, 10, '  Real-mode memory layout:', 13, 10, 0
msg_layout      db '    0x00000-0x003FF  1 KB    IVT (Interrupt Vector Table)', 13, 10
                db '    0x00400-0x004FF  256 B   BDA (BIOS Data Area)', 13, 10
                db '    0x00500-0x005FF  256 B   Free (BIOS scratch)', 13, 10
                db '    0x00600-0x0060F  16 B    Boot Info Block (BIB)', 13, 10
                db '    0x00800-0x027FF  8 KB    FS.BIN (INT 0x81)', 13, 10
                db '    0x03000-0x04FFF  8 KB    SHELL.BIN (this code)', 13, 10
                db '    0x05000-0x06FFF  8 KB    KERNEL.BIN (INT 0x80)', 13, 10
                db '    0x07000-0x07BFF  3 KB    Stack', 13, 10
                db '    0x07C00-0x07FFF  1 KB    VBR (boot only)', 13, 10
                db '    0x0A000-0x0BFFF  8 KB    Video RAM', 13, 10
                db '    0x0C000-0x0FFFF  16 KB   ROM area (BIOS, VGA)', 13, 10
                db '    0x10000-0xFFFFF  960 KB  Extended (requires A20)', 13, 10, 0

; --- CPU information strings --------------------------------------------------
msg_cpu_vendor  db '  Vendor:     ', 0
msg_cpu_family  db '  Family:     ', 0
msg_cpu_model   db '  Model:      ', 0
msg_cpu_step    db '  Stepping:   ', 0
msg_cpu_feat    db '  Features:   ', 0
msg_no_cpuid    db '  CPUID not supported (pre-486 CPU)', 13, 10, 0

; Feature flag tags
msg_f_fpu       db 'FPU ', 0
msg_f_tsc       db 'TSC ', 0
msg_f_msr       db 'MSR ', 0
msg_f_cx8       db 'CX8 ', 0
msg_f_pge       db 'PGE ', 0
msg_f_cmov      db 'CMOV ', 0
msg_f_mmx       db 'MMX ', 0
msg_f_sse       db 'SSE ', 0
msg_f_sse2      db 'SSE2 ', 0
msg_f_sse3      db 'SSE3 ', 0
msg_f_sse41     db 'SSE4.1 ', 0
msg_f_sse42     db 'SSE4.2 ', 0

; Hypervisor detection
msg_hv_yes      db '  Hypervisor: Yes', 13, 10, 0
msg_hv_no       db '  Hypervisor: No', 13, 10, 0
msg_hv_vendor   db '  HV Vendor:  ', 0

; --- Shared strings ----------------------------------------------------------
msg_crlf        db 13, 10, 0
msg_indent      db '    ', 0
msg_anykey      db 13, 10, '  Press any key...', 0

; =============================================================================
; RUNTIME DATA
; =============================================================================
cmd_buf         times 32 db 0       ; Command input buffer (31 chars + NUL)
cmd_len         db 0
e820_buf        times 20 db 0       ; E820 buffer (one entry)
bda_offset      dw 0                ; Temp storage for BDA offset in loops

; CPUID scratch space
cpuid_vendor    times 13 db 0       ; 12-byte vendor string + NUL
cpuid_ver       dd 0
cpuid_feat_edx  dd 0
cpuid_feat_ecx  dd 0

; --- dir command strings -------------------------------------------------------
msg_dir_hdr     db 13, 10, '  Volume: MNFS v1', 13, 10, 0
msg_dir_cols    db '  Name          Type   Sec    Bytes', 13, 10
                db '  -----------------------------------', 13, 10, 0
msg_dir_indent  db '  ', 0
msg_dir_space   db '   ', 0
msg_dir_sys     db 'SYS  ', 0
msg_dir_exe     db 'EXE  ', 0
msg_dir_dat     db '---  ', 0
msg_dir_sec_suffix db ' sec', 0
msg_dir_bytes_suffix db 13, 10, 0
msg_dir_sep     db '  -----------------------------------', 13, 10, '  ', 0
msg_dir_summary db ' file(s)           ', 0
msg_dir_total_bytes db ' bytes', 13, 10, 0
msg_dir_used    db '  Used: ', 0
msg_dir_free    db '  Free: ', 0
msg_dir_of      db ' / ', 0
msg_dir_kb      db ' KB', 13, 10, 0
msg_dir_empty   db '  (no files)', 13, 10, 0

; --- dir command data ---------------------------------------------------------
dir_file_count  dw 0                ; File count for dir command
dir_used_sec    dw 0                ; Used sectors (from FS_GET_INFO)
dir_cap_sec     dw 0                ; Capacity sectors (from FS_GET_INFO)
dir_buffer      times 512 db 0      ; Buffer for MNFS directory data

; IVT loop counter
ivt_index       db 0

; --- Debug syscall tag and messages -------------------------------------------
dbg_tag         db 'SHL', 0
dbg_init        db 'shell starting', 0
dbg_unknown     db 'unknown command', 0

; =============================================================================
; PADDING — fill to sector boundary (12 sectors = 6144 bytes)
; =============================================================================
times (12 * 512) - ($ - $$) db 0

