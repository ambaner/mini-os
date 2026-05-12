; =============================================================================
; Mini-OS Shell (SHELL.BIN) - Interactive Command Shell
;
; Loaded by LOADER.BIN into memory at 0x3000.  Provides the interactive
; command-line interface for mini-os.
;
; The Boot Info Block (BIB) at 0x0600 is populated by earlier boot stages:
;   0x0600: boot_drive  (1 byte)  — BIOS drive number
;   0x0601: a20_status  (1 byte)  — A20 gate result (1=enabled, 0=failed)
;   0x0602: part_lba    (4 bytes) — partition start LBA
;
; Header layout (first 6 bytes):
;   Offset 0: 'MNSH'   Magic identifier (4 bytes)
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

[BITS 16]
[ORG 0x3000]                        ; Loader loads us here

; =============================================================================
; CONSTANTS
; =============================================================================
BIB_DRIVE       equ 0x0600          ; Boot drive (from VBR)
BIB_A20         equ 0x0601          ; A20 status (from loader)
BIB_PART_LBA    equ 0x0602          ; Partition start LBA (from VBR)

; =============================================================================
; SHELL HEADER
; =============================================================================
shell_magic     db 'MNSH'           ; Magic identifier
shell_sectors   dw 10               ; Shell size in sectors (updated as needed)

; =============================================================================
; SHELL - Main command loop
;
; 1. Clear screen
; 2. Print banner (version string)
; 3. Show prompt "mnos:\>"
; 4. Read a line of input into cmd_buf
; 5. Match against known commands, dispatch or print error
; 6. After command completes, go back to step 3
; =============================================================================
shell_init:
    ; Clear screen (set video mode 3 = 80x25 color text)
    mov ax, 0x0003
    int 0x10

    ; Print banner
    mov si, msg_banner
    call puts

; --- Prompt loop (returns here after each command) ---------------------------
shell_prompt:
    mov si, msg_prompt
    call puts

    ; Read a line of user input into cmd_buf (up to 31 chars)
    call readline

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

    ; Unknown command
    mov si, msg_unknown
    call puts
    mov si, cmd_buf
    call puts
    mov si, msg_crlf
    call puts
    jmp shell_prompt

; =============================================================================
; COMMAND: cls
; Clear the screen and re-display the banner.
; =============================================================================
cmd_cls:
    jmp shell_init                  ; Re-init clears screen + prints banner

; =============================================================================
; COMMAND: reboot
; Perform a warm reboot by jumping to the BIOS reset vector.
; =============================================================================
cmd_reboot:
    mov word [0x0472], 0x1234       ; Warm-reboot flag
    jmp 0xFFFF:0x0000               ; Jump to BIOS reset entry point

; =============================================================================
; COMMAND: help
; Print a list of available commands with brief descriptions.
; =============================================================================
cmd_help:
    mov si, msg_help_text
    call puts
    jmp shell_prompt

; =============================================================================
; COMMAND: ver
; Print version and build information.
; =============================================================================
cmd_ver:
    mov si, msg_ver_text
    call puts
    jmp shell_prompt

; =============================================================================
; COMMAND: mem
; Display detailed memory information.
; =============================================================================
cmd_mem:
    mov si, msg_mem_hdr
    call puts

    ; --- Conventional memory (INT 12h) ---------------------------------------
    mov si, msg_conv_mem
    call puts
    int 0x12                        ; AX = conventional memory in KB
    call print_dec16
    mov si, msg_kb
    call puts

    ; --- Extended memory (INT 15h AH=88h) ------------------------------------
    mov si, msg_ext_mem
    call puts
    mov ah, 0x88
    int 0x15
    jc .mem_no_ext
    call print_dec16
    mov si, msg_kb
    call puts
    jmp .mem_a20

.mem_no_ext:
    mov si, msg_na
    call puts

.mem_a20:
    ; --- A20 gate status (from BIB, set by loader) ---------------------------
    mov si, msg_a20
    call puts

    cmp byte [BIB_A20], 1
    je .a20_show_on
    mov si, msg_a20_off
    call puts
    jmp .a20_verify

.a20_show_on:
    mov si, msg_a20_on
    call puts

.a20_verify:
    ; Live verification — re-test wrap-around
    mov si, msg_a20_live
    call puts
    call check_a20
    jnz .a20_live_on
    mov si, msg_a20_off_short
    call puts
    jmp .a20_section_done
.a20_live_on:
    mov si, msg_a20_on_short
    call puts

.a20_section_done:

    ; --- Real-mode memory layout ---------------------------------------------
    mov si, msg_layout_hdr
    call puts
    mov si, msg_layout
    call puts

    ; --- E820 Memory Map -----------------------------------------------------
    mov si, msg_e820_hdr
    call puts

    xor ebx, ebx
    mov di, e820_buf

.mem_e820_loop:
    mov eax, 0x0000E820
    mov ecx, 20
    mov edx, 0x534D4150             ; 'SMAP'
    int 0x15

    jc .mem_e820_done
    cmp eax, 0x534D4150
    jne .mem_e820_done

    push ebx

    mov si, msg_e820_base
    call puts
    mov al, [e820_buf+3]
    call puthex8
    mov al, [e820_buf+2]
    call puthex8
    mov al, [e820_buf+1]
    call puthex8
    mov al, [e820_buf]
    call puthex8

    mov si, msg_e820_len
    call puts
    mov al, [e820_buf+11]
    call puthex8
    mov al, [e820_buf+10]
    call puthex8
    mov al, [e820_buf+9]
    call puthex8
    mov al, [e820_buf+8]
    call puthex8

    mov si, msg_e820_type
    call puts
    mov al, [e820_buf+16]
    add al, '0'
    call putc

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
    call puts

    pop ebx
    test ebx, ebx
    jnz .mem_e820_loop

.mem_e820_done:
    mov si, msg_crlf
    call puts
    jmp shell_prompt

; =============================================================================
; COMMAND: sysinfo
; Display 5 pages of system information, pausing between each page.
; =============================================================================
cmd_sysinfo:
    ; =========================================================================
    ; PAGE 1 — CPU Information (CPUID)
    ; =========================================================================
    mov ax, 0x0003
    int 0x10

    mov si, msg_page1_hdr
    call puts

    ; --- Check CPUID support -------------------------------------------------
    pushfd
    pop eax
    mov ecx, eax                    ; ECX = original EFLAGS
    xor eax, 0x00200000             ; Flip ID bit (bit 21)
    push eax
    popfd
    pushfd
    pop eax
    push ecx                        ; Restore original EFLAGS
    popfd
    xor eax, ecx
    test eax, 0x00200000
    jz .no_cpuid

    ; --- CPUID leaf 0: Vendor string -----------------------------------------
    xor eax, eax
    cpuid
    mov [cpuid_vendor], ebx
    mov [cpuid_vendor+4], edx
    mov [cpuid_vendor+8], ecx
    mov byte [cpuid_vendor+12], 0

    mov si, msg_cpu_vendor
    call puts
    mov si, cpuid_vendor
    call puts
    mov si, msg_crlf
    call puts

    ; --- CPUID leaf 1: Version and feature flags -----------------------------
    mov eax, 1
    cpuid
    mov [cpuid_ver], eax
    mov [cpuid_feat_edx], edx
    mov [cpuid_feat_ecx], ecx

    ; Print family
    mov si, msg_cpu_family
    call puts
    mov eax, [cpuid_ver]
    shr eax, 8
    and ax, 0x0F
    call print_dec16
    mov si, msg_crlf
    call puts

    ; Print model
    mov si, msg_cpu_model
    call puts
    mov eax, [cpuid_ver]
    shr eax, 4
    and ax, 0x0F
    call print_dec16
    mov si, msg_crlf
    call puts

    ; Print stepping
    mov si, msg_cpu_step
    call puts
    mov eax, [cpuid_ver]
    and ax, 0x0F
    call print_dec16
    mov si, msg_crlf
    call puts

    ; --- Feature flags -------------------------------------------------------
    mov si, msg_cpu_feat
    call puts

    mov edx, [cpuid_feat_edx]

    test edx, 1                     ; Bit 0: FPU
    jz .no_fpu
    mov si, msg_f_fpu
    call puts
.no_fpu:
    test edx, (1<<4)                ; Bit 4: TSC
    jz .no_tsc
    mov si, msg_f_tsc
    call puts
.no_tsc:
    test edx, (1<<5)                ; Bit 5: MSR
    jz .no_msr
    mov si, msg_f_msr
    call puts
.no_msr:
    test edx, (1<<8)                ; Bit 8: CX8
    jz .no_cx8
    mov si, msg_f_cx8
    call puts
.no_cx8:
    test edx, (1<<13)               ; Bit 13: PGE
    jz .no_pge
    mov si, msg_f_pge
    call puts
.no_pge:
    test edx, (1<<15)               ; Bit 15: CMOV
    jz .no_cmov
    mov si, msg_f_cmov
    call puts
.no_cmov:
    test edx, (1<<23)               ; Bit 23: MMX
    jz .no_mmx
    mov si, msg_f_mmx
    call puts
.no_mmx:
    test edx, (1<<25)               ; Bit 25: SSE
    jz .no_sse
    mov si, msg_f_sse
    call puts
.no_sse:
    test edx, (1<<26)               ; Bit 26: SSE2
    jz .no_sse2
    mov si, msg_f_sse2
    call puts
.no_sse2:

    mov ecx, [cpuid_feat_ecx]

    test ecx, 1                     ; Bit 0: SSE3
    jz .no_sse3
    mov si, msg_f_sse3
    call puts
.no_sse3:
    test ecx, (1<<19)               ; Bit 19: SSE4.1
    jz .no_sse41
    mov si, msg_f_sse41
    call puts
.no_sse41:
    test ecx, (1<<20)               ; Bit 20: SSE4.2
    jz .no_sse42
    mov si, msg_f_sse42
    call puts
.no_sse42:

    mov si, msg_crlf
    call puts

    ; --- Hypervisor detection ------------------------------------------------
    mov ecx, [cpuid_feat_ecx]
    test ecx, (1<<31)
    jz .no_hypervisor

    mov si, msg_hv_yes
    call puts

    ; CPUID leaf 0x40000000: hypervisor vendor string
    mov eax, 0x40000000
    cpuid
    mov [cpuid_vendor], ebx
    mov [cpuid_vendor+4], ecx
    mov [cpuid_vendor+8], edx
    mov byte [cpuid_vendor+12], 0

    mov si, msg_hv_vendor
    call puts
    mov si, cpuid_vendor
    call puts
    mov si, msg_crlf
    call puts
    jmp .cpuid_done

.no_hypervisor:
    mov si, msg_hv_no
    call puts
    jmp .cpuid_done

.no_cpuid:
    mov si, msg_no_cpuid
    call puts

.cpuid_done:
    call wait_key

    ; =========================================================================
    ; PAGE 2 — Memory
    ; =========================================================================
    mov si, msg_page2_hdr
    call puts

    mov si, msg_conv_mem
    call puts
    int 0x12
    call print_dec16
    mov si, msg_kb
    call puts

    mov si, msg_ext_mem
    call puts
    mov ah, 0x88
    int 0x15
    jc .no_ext
    call print_dec16
    mov si, msg_kb
    call puts
    jmp .e820_start
.no_ext:
    mov si, msg_na
    call puts

.e820_start:
    mov si, msg_e820_hdr
    call puts

    xor ebx, ebx
    mov di, e820_buf

.e820_loop:
    mov eax, 0x0000E820
    mov ecx, 20
    mov edx, 0x534D4150
    int 0x15

    jc .e820_done
    cmp eax, 0x534D4150
    jne .e820_done

    push ebx

    mov si, msg_e820_base
    call puts
    mov al, [e820_buf+3]
    call puthex8
    mov al, [e820_buf+2]
    call puthex8
    mov al, [e820_buf+1]
    call puthex8
    mov al, [e820_buf]
    call puthex8

    mov si, msg_e820_len
    call puts
    mov al, [e820_buf+11]
    call puthex8
    mov al, [e820_buf+10]
    call puthex8
    mov al, [e820_buf+9]
    call puthex8
    mov al, [e820_buf+8]
    call puthex8

    mov si, msg_e820_type
    call puts
    mov al, [e820_buf+16]
    add al, '0'
    call putc

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
    call puts

    pop ebx
    test ebx, ebx
    jnz .e820_loop

.e820_done:
    call wait_key

    ; =========================================================================
    ; PAGE 3 — BIOS Data Area (BDA)
    ; =========================================================================
    mov si, msg_page3_hdr
    call puts

    ; --- COM ports ---
    mov si, msg_com_hdr
    call puts

    mov cx, 4
    mov bx, 0x0400
.com_loop:
    push cx
    mov si, msg_indent
    call puts
    mov al, 'C'
    call putc
    mov al, 'O'
    call putc
    mov al, 'M'
    call putc
    mov al, 5
    pop cx
    push cx
    sub al, cl
    add al, '0'
    call putc
    mov al, ':'
    call putc
    mov al, ' '
    call putc

    mov ax, [bx]
    test ax, ax
    jz .com_none
    call print_hex16
    mov si, msg_crlf
    call puts
    jmp .com_next
.com_none:
    mov si, msg_not_present
    call puts
.com_next:
    add bx, 2
    pop cx
    dec cx
    jnz .com_loop

    ; --- LPT ports ---
    mov si, msg_lpt_hdr
    call puts

    mov cx, 3
    mov bx, 0x0408
.lpt_loop:
    push cx
    mov si, msg_indent
    call puts
    mov al, 'L'
    call putc
    mov al, 'P'
    call putc
    mov al, 'T'
    call putc
    mov al, 4
    pop cx
    push cx
    sub al, cl
    add al, '0'
    call putc
    mov al, ':'
    call putc
    mov al, ' '
    call putc

    mov ax, [bx]
    test ax, ax
    jz .lpt_none
    call print_hex16
    mov si, msg_crlf
    call puts
    jmp .lpt_next
.lpt_none:
    mov si, msg_not_present
    call puts
.lpt_next:
    add bx, 2
    pop cx
    dec cx
    jnz .lpt_loop

    ; --- Equipment word ---
    mov si, msg_equip
    call puts
    int 0x11
    call print_hex16
    mov si, msg_crlf
    call puts

    ; --- Video info from BDA ---
    mov si, msg_vid_mode_bda
    call puts
    mov al, [0x0449]
    call puthex8
    mov si, msg_crlf
    call puts

    mov si, msg_vid_cols
    call puts
    mov ax, [0x044A]
    call print_dec16
    mov si, msg_crlf
    call puts

    mov si, msg_vid_pagesz
    call puts
    mov ax, [0x044C]
    call print_dec16
    mov si, msg_bytes
    call puts

    call wait_key

    ; =========================================================================
    ; PAGE 4 — Video & Disk
    ; =========================================================================
    mov si, msg_page4_hdr
    call puts

    ; --- Active video mode ---
    mov si, msg_vid_active
    call puts
    mov ah, 0x0F
    int 0x10
    push bx
    call puthex8
    mov si, msg_crlf
    call puts

    ; --- Active display page ---
    mov si, msg_vid_page
    call puts
    pop bx
    mov al, bh
    call puthex8
    mov si, msg_crlf
    call puts

    ; --- Video memory base ---
    mov si, msg_vid_base
    call puts
    mov al, [0x0449]
    cmp al, 0x07
    je .mono_base
    mov si, msg_b8000
    jmp .print_vbase
.mono_base:
    mov si, msg_b0000
.print_vbase:
    call puts

    ; --- Cursor position ---
    mov si, msg_cursor
    call puts
    mov ah, 0x03
    xor bh, bh
    int 0x10
    mov al, dh
    call puthex8
    mov al, ','
    call putc
    mov al, dl
    call puthex8
    mov si, msg_cursor_rc
    call puts

    ; --- Boot drive info ---
    mov si, msg_boot_drv
    call puts
    mov al, [BIB_DRIVE]             ; Read from BIB instead of local variable
    call puthex8
    mov si, msg_crlf
    call puts

    ; --- Drive geometry ---
    mov si, msg_drv_geom
    call puts
    mov dl, [BIB_DRIVE]
    mov ah, 0x08
    int 0x13
    jc .no_geom

    push dx

    mov si, msg_drv_cyl
    call puts
    mov al, cl
    shr al, 6
    call puthex8
    mov al, ch
    call puthex8
    mov si, msg_crlf
    call puts

    mov si, msg_drv_sec
    call puts
    mov al, cl
    and al, 0x3F
    xor ah, ah
    call print_dec16
    mov si, msg_crlf
    call puts

    pop dx
    mov si, msg_drv_head
    call puts
    mov al, dh
    inc al
    xor ah, ah
    call print_dec16
    mov si, msg_crlf
    call puts
    jmp .geom_done

.no_geom:
    mov si, msg_na
    call puts

.geom_done:

    ; --- EDD support ---
    mov si, msg_edd_hdr
    call puts
    mov dl, [BIB_DRIVE]
    mov bx, 0x55AA
    mov ah, 0x41
    int 0x13
    jc .no_edd
    cmp bx, 0xAA55
    jne .no_edd

    push ax

    mov si, msg_edd_ver
    call puts
    pop ax
    mov al, ah
    call puthex8
    mov si, msg_crlf
    call puts

    ; Extended params
    mov ah, 0x48
    mov dl, [BIB_DRIVE]
    mov si, edd_buf
    mov word [edd_buf], 30
    int 0x13
    jc .edd_no_params

    mov si, msg_edd_sectors
    call puts
    mov ax, [edd_buf+18]
    call print_hex16
    mov ax, [edd_buf+16]
    call print_hex16
    mov si, msg_crlf
    call puts

    mov si, msg_edd_bps
    call puts
    mov ax, [edd_buf+24]
    call print_dec16
    mov si, msg_crlf
    call puts
    jmp .edd_done

.edd_no_params:
    mov si, msg_na
    call puts

.no_edd:
    mov si, msg_edd_none
    call puts

.edd_done:
    call wait_key

    ; =========================================================================
    ; PAGE 5 — IVT Sample (Interrupt Vector Table)
    ; =========================================================================
    mov si, msg_page5_hdr
    call puts

    xor bx, bx
    xor cl, cl

.ivt_loop:
    cmp cl, 8
    jge .ivt_done

    mov si, msg_indent
    call puts
    mov al, 'I'
    call putc
    mov al, 'N'
    call putc
    mov al, 'T'
    call putc
    mov al, ' '
    call putc
    mov al, cl
    call puthex8
    mov al, 'h'
    call putc
    mov al, ':'
    call putc
    mov al, ' '
    call putc

    mov ax, [bx+2]                  ; Segment
    call print_hex16
    mov al, ':'
    call putc
    mov ax, [bx]                    ; Offset
    call print_hex16

    push cx
    push bx
    xor ch, ch
    shl cx, 1
    mov bx, ivt_names_table
    add bx, cx
    mov si, [bx]
    call puts
    pop bx
    pop cx

    add bx, 4
    inc cl
    jmp .ivt_loop

.ivt_done:
    mov si, msg_sysinfo_done
    call puts
    call wait_key
    jmp shell_init

; =============================================================================
; SUBROUTINES
; =============================================================================

; ---------------------------------------------------------------------------
; readline — Read a line of input into cmd_buf (up to 31 chars).
; ---------------------------------------------------------------------------
readline:
    xor cx, cx

.read_char:
    xor ah, ah
    int 0x16

    cmp al, 0x0D
    je .read_done

    cmp al, 0x08
    je .read_bs

    cmp al, 0x20
    jb .read_char
    cmp al, 0x7E
    ja .read_char

    cmp cx, 31
    jge .read_char

    ; Convert uppercase to lowercase
    cmp al, 'A'
    jb .no_lower
    cmp al, 'Z'
    ja .no_lower
    add al, 32
.no_lower:

    mov bx, cmd_buf
    add bx, cx
    mov [bx], al
    inc cx

    mov ah, 0x0E
    xor bh, bh
    int 0x10
    jmp .read_char

.read_bs:
    test cx, cx
    jz .read_char

    dec cx

    mov ah, 0x0E
    mov al, 0x08
    xor bh, bh
    int 0x10
    mov al, ' '
    int 0x10
    mov al, 0x08
    int 0x10
    jmp .read_char

.read_done:
    mov bx, cmd_buf
    add bx, cx
    mov byte [bx], 0
    mov [cmd_len], cl

    mov si, msg_crlf
    call puts
    ret

; ---------------------------------------------------------------------------
; strcmp — Compare two NUL-terminated strings (case-sensitive).
;   Input:  DS:SI -> string 1, DS:DI -> string 2
;   Output: ZF set if strings are equal
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
; puts — Print NUL-terminated string at DS:SI.
; ---------------------------------------------------------------------------
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

; ---------------------------------------------------------------------------
; putc — Print a single character in AL.
; ---------------------------------------------------------------------------
putc:
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    ret

; ---------------------------------------------------------------------------
; puthex8 — Print AL as two hex digits.
; ---------------------------------------------------------------------------
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

; ---------------------------------------------------------------------------
; print_hex16 — Print AX as four hex digits.
; ---------------------------------------------------------------------------
print_hex16:
    push ax
    mov al, ah
    call puthex8
    pop ax
    call puthex8
    ret

; ---------------------------------------------------------------------------
; print_dec16 — Print AX as unsigned decimal (0–65535).
; ---------------------------------------------------------------------------
print_dec16:
    push cx
    push dx
    xor cx, cx

.div_loop:
    xor dx, dx
    mov bx, 10
    div bx
    push dx
    inc cx
    test ax, ax
    jnz .div_loop

.print_loop:
    pop ax
    add al, '0'
    call putc
    dec cx
    jnz .print_loop

    pop dx
    pop cx
    ret

; ---------------------------------------------------------------------------
; wait_key — Print "Press any key..." and wait, then clear screen.
; ---------------------------------------------------------------------------
wait_key:
    mov si, msg_anykey
    call puts
    xor ah, ah
    int 0x16
    mov ax, 0x0003
    int 0x10
    ret

; ---------------------------------------------------------------------------
; check_a20 — Test if A20 is enabled (wrap-around method).
;   Output: ZF=0 (NZ) if enabled, ZF=1 (Z) if disabled
;   Clobbers: AX, CL
; ---------------------------------------------------------------------------
check_a20:
    push ds
    push es

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
    je .chk_off
    mov cl, 1
    jmp .chk_restore
.chk_off:
    mov cl, 0

.chk_restore:
    pop ax
    mov [es:0x0510], al
    pop ax
    mov [ds:0x0500], al

    pop es
    pop ds

    test cl, cl
    ret

; =============================================================================
; DATA — String constants
; =============================================================================

; --- Shell strings -----------------------------------------------------------
msg_banner      db 13, 10
                db '  MNOS v0.4.0', 13, 10
                db 13, 10, 0

msg_prompt      db 'mnos:\>', 0

msg_unknown     db 'Unknown command: ', 0

msg_help_text   db 'Available commands:', 13, 10
                db '  sysinfo  - Display system information (5 pages)', 13, 10
                db '  mem      - Detailed memory info and layout', 13, 10
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

; --- ver command strings -----------------------------------------------------
msg_ver_text    db '  MNOS v0.4.0', 13, 10
                db '  Arch:      x86 real mode (16-bit)', 13, 10
                db '  Assembler: NASM', 13, 10
                db '  Platform:  Hyper-V Gen 1', 13, 10
                db '  Boot:      MBR -> VBR -> LOADER -> SHELL', 13, 10
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
msg_edd_sectors db '    Total sectors: ', 0
msg_edd_bps     db '    Bytes/sector:  ', 0
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
                db '    0x00800-0x027FF  8 KB    LOADER.BIN', 13, 10
                db '    0x03000-0x06FFF  16 KB   SHELL.BIN (this code)', 13, 10
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

; CPUID scratch space
cpuid_vendor    times 13 db 0       ; 12-byte vendor string + NUL
cpuid_ver       dd 0
cpuid_feat_edx  dd 0
cpuid_feat_ecx  dd 0

; EDD extended drive parameters buffer
edd_buf         times 30 db 0

; =============================================================================
; PADDING — fill to sector boundary
; =============================================================================
times (10 * 512) - ($ - $$) db 0
