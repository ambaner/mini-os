; =============================================================================
; Mini-OS Volume Boot Record (VBR) - Interactive Shell
;
; This is the second-stage bootloader.  The MBR finds the active partition in
; the partition table, then loads this code from the partition's first sector(s)
; into memory at 0x7C00 and jumps here.
;
; The VBR has a self-describing header that tells the MBR how many sectors to
; load.  The boot area is 16 sectors (8 KB), giving us plenty of room.
;
; After clearing the screen, the VBR displays a banner and drops into an
; interactive command shell.  Available commands:
;
;   sysinfo  - Display 5 pages of system information
;   help     - List available commands
;   cls      - Clear the screen
;   reboot   - Warm-reboot the system
;
; VBR Header layout (starts at byte 0 of the partition):
;   Offset 0:   EB xx      JMP SHORT past the header
;   Offset 2:   90         NOP (standard boot sector padding)
;   Offset 3:   'MNOS'     Magic identifier (4 bytes)
;   Offset 7:   dw 16      Boot area size in sectors (MBR reads this)
;
; Assembled with:  nasm -f bin -o vbr.bin src/boot/vbr.asm
; =============================================================================

[BITS 16]                           ; 16-bit real mode
[ORG 0x7C00]                        ; MBR copies us here before jumping

; =============================================================================
; VBR HEADER  (Sector 0 - first 512 bytes)
;
; The header occupies sector 0.  Because code + data exceed 510 bytes, the
; actual code lives in sector 1 onward.  A near-jump trampoline at offset 9
; reaches past the boot signature into sector 1.
; =============================================================================
    jmp short vbr_trampoline        ; 2 bytes: EB 07 - skip header fields
    nop                             ; 1 byte:  90    - standard filler

vbr_magic       db 'MNOS'          ; 4-byte magic identifier for mini-os
vbr_sectors     dw 16              ; Boot area = 16 sectors = 8 KB

vbr_trampoline:
    jmp near vbr_code              ; 3 bytes: E9 xx xx - near jump to sector 1

; Pad sector 0 and place the boot signature at offset 510
times 510 - ($ - $$) db 0
dw 0xAA55

; =============================================================================
; VBR CODE - Sector 1+ (offset 512 onward)
;
; At this point, the MBR has already:
;   - Set DS, ES, SS to 0, SP to 0x7C00
;   - Placed the boot drive number in DL
;   - Loaded all 16 boot-area sectors and copied them to 0x7C00
; =============================================================================
vbr_code:
    mov [boot_drive], dl            ; Save boot drive before we clobber DL

; =============================================================================
; A20 GATE ENABLEMENT
;
; Enable the A20 address line so the CPU can access memory above 1 MB.
; Without A20, addresses wrap at the 1 MB boundary (8086 compatibility).
;
; We try three methods in order of preference:
;   1. BIOS INT 15h AX=2401h  (cleanest, most portable)
;   2. Keyboard controller     (classic AT method, port 0x64/0x60)
;   3. Fast A20 via port 0x92  (quick but not universal)
;
; After each attempt we verify A20 is actually enabled.  If all three
; methods fail, we record the failure but continue (shell still works
; in the low 1 MB).
; =============================================================================
enable_a20:
    ; --- Check if A20 is already enabled -------------------------------------
    call check_a20
    jnz .a20_ok                     ; Already enabled, skip everything

    ; --- Method 1: BIOS INT 15h AX=2401h ------------------------------------
    mov ax, 0x2401
    int 0x15
    call check_a20
    jnz .a20_ok

    ; --- Method 2: Keyboard controller (8042) --------------------------------
    ; Send "write output port" command to the 8042, set the A20 bit.
    call .a20_wait_cmd              ; Wait for input buffer empty
    mov al, 0xAD                    ; Disable keyboard
    out 0x64, al

    call .a20_wait_cmd
    mov al, 0xD0                    ; Command: read output port
    out 0x64, al

    call .a20_wait_data             ; Wait for data to be available
    in al, 0x60                     ; Read current output port value
    push ax                         ; Save it

    call .a20_wait_cmd
    mov al, 0xD1                    ; Command: write output port
    out 0x64, al

    call .a20_wait_cmd
    pop ax
    or al, 0x02                     ; Set A20 bit (bit 1)
    out 0x60, al                    ; Write new output port value

    call .a20_wait_cmd
    mov al, 0xAE                    ; Re-enable keyboard
    out 0x64, al
    call .a20_wait_cmd

    call check_a20
    jnz .a20_ok

    ; --- Method 3: Fast A20 (port 0x92) -------------------------------------
    in al, 0x92
    or al, 0x02                     ; Set A20 bit (bit 1)
    and al, 0xFE                    ; Clear bit 0 (avoid system reset!)
    out 0x92, al

    call check_a20
    jnz .a20_ok

    ; --- All methods failed --------------------------------------------------
    mov byte [a20_status], 0        ; Record failure
    jmp shell_init

.a20_ok:
    mov byte [a20_status], 1        ; Record success
    jmp shell_init

; --- A20 helper: wait for 8042 input buffer to be empty ----------------------
.a20_wait_cmd:
    in al, 0x64
    test al, 0x02                   ; Bit 1 = input buffer full
    jnz .a20_wait_cmd
    ret

; --- A20 helper: wait for 8042 output buffer to have data --------------------
.a20_wait_data:
    in al, 0x64
    test al, 0x01                   ; Bit 0 = output buffer has data
    jz .a20_wait_data
    ret

; ---------------------------------------------------------------------------
; check_a20 - Test if the A20 line is enabled (wrap-around method).
;
;   Writes different values to 0x0000:0x0500 and 0xFFFF:0x0510.
;   If A20 is disabled these map to the same physical byte (aliased).
;   Saves and restores the original memory contents.
;
;   Output:  ZF=0 (NZ) if A20 enabled, ZF=1 (Z) if disabled
;   Clobbers: AX, CL
; ---------------------------------------------------------------------------
check_a20:
    push ds
    push es

    xor ax, ax
    mov ds, ax                      ; DS = 0x0000
    mov ax, 0xFFFF
    mov es, ax                      ; ES = 0xFFFF

    ; Save original bytes at both test locations
    mov al, [ds:0x0500]
    push ax
    mov al, [es:0x0510]
    push ax

    ; Write different test patterns
    mov byte [es:0x0510], 0x13
    mov byte [ds:0x0500], 0x37

    ; Check: did writing to 0x0500 also change 0x0510?
    ; If yes → addresses wrapped → A20 is disabled
    cmp byte [es:0x0510], 0x37
    je .chk_a20_off
    mov cl, 1                       ; Different → A20 is enabled
    jmp .chk_a20_restore
.chk_a20_off:
    mov cl, 0                       ; Same → A20 is disabled (wrapped)

.chk_a20_restore:
    ; Restore original bytes (reverse order of push)
    pop ax
    mov [es:0x0510], al
    pop ax
    mov [ds:0x0500], al

    pop es
    pop ds

    test cl, cl                     ; Set ZF: NZ if enabled, Z if disabled
    ret

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
    ; Compare the input buffer against each known command string.
    ; If it matches, jump to the command handler.  Otherwise print an error.

    ; Empty input (just pressed Enter) -> re-prompt
    cmp byte [cmd_buf], 0
    je shell_prompt

    ; "sysinfo" -> display system information
    mov si, cmd_buf
    mov di, str_sysinfo
    call strcmp
    je cmd_sysinfo

    ; "help" -> display help
    mov si, cmd_buf
    mov di, str_help
    call strcmp
    je cmd_help

    ; "mem" -> detailed memory information
    mov si, cmd_buf
    mov di, str_mem
    call strcmp
    je cmd_mem

    ; "cls" -> clear screen and re-show banner
    mov si, cmd_buf
    mov di, str_cls
    call strcmp
    je cmd_cls

    ; "ver" -> version info
    mov si, cmd_buf
    mov di, str_ver
    call strcmp
    je cmd_ver

    ; "reboot" -> warm reboot
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
; Setting the word at 0x0472 to 0x1234 tells the BIOS to skip the POST
; memory test (warm reboot).
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
; Display detailed memory information:
;   - Conventional memory (INT 12h)
;   - Extended memory (INT 15h AH=88h)
;   - A20 gate status (wrap-around test)
;   - Real-mode memory layout map
;   - E820 BIOS memory map
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
    ; --- A20 gate status -----------------------------------------------------
    ; The VBR enables A20 at boot using up to three methods (BIOS, 8042,
    ; Fast A20).  The result is stored in a20_status.  We also re-verify
    ; the current state with a live wrap-around test.
    mov si, msg_a20
    call puts

    cmp byte [a20_status], 1
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
; This is the same system info display from v0.2.2, now wrapped as a command.
; =============================================================================
cmd_sysinfo:
    ; =========================================================================
    ; PAGE 1 - CPU Information (CPUID)
    ; =========================================================================
    mov ax, 0x0003
    int 0x10

    mov si, msg_page1_hdr
    call puts

    ; --- Check CPUID support -------------------------------------------------
    ; Try to flip the ID bit (bit 21) in EFLAGS.  If the CPU allows the flip,
    ; the CPUID instruction is available (486+).
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
    xor eax, ecx                    ; Did bit 21 change?
    test eax, 0x00200000
    jz .no_cpuid

    ; --- CPUID leaf 0: Vendor string -----------------------------------------
    ; Returns 12-byte vendor ID in EBX:EDX:ECX (e.g. "GenuineIntel").
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
    ; EAX bits 11-8 = family, 7-4 = model, 3-0 = stepping
    ; EDX/ECX = feature flag bitmasks
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
    ; Print a compact line of supported features from EDX and ECX.
    mov si, msg_cpu_feat
    call puts

    mov edx, [cpuid_feat_edx]

    test edx, 1                     ; Bit 0: FPU (x87)
    jz .no_fpu
    mov si, msg_f_fpu
    call puts
.no_fpu:
    test edx, (1<<4)                ; Bit 4: TSC (timestamp counter)
    jz .no_tsc
    mov si, msg_f_tsc
    call puts
.no_tsc:
    test edx, (1<<5)                ; Bit 5: MSR (model-specific regs)
    jz .no_msr
    mov si, msg_f_msr
    call puts
.no_msr:
    test edx, (1<<8)                ; Bit 8: CMPXCHG8B
    jz .no_cx8
    mov si, msg_f_cx8
    call puts
.no_cx8:
    test edx, (1<<13)               ; Bit 13: PTE Global Bit
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
    ; ECX bit 31 from CPUID leaf 1 indicates a hypervisor is present.
    mov ecx, [cpuid_feat_ecx]
    test ecx, (1<<31)
    jz .no_hypervisor

    mov si, msg_hv_yes
    call puts

    ; CPUID leaf 0x40000000: hypervisor vendor string (EBX:ECX:EDX)
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
    ; PAGE 2 - Memory
    ; =========================================================================
    mov si, msg_page2_hdr
    call puts

    ; --- Conventional memory (INT 12h) ---------------------------------------
    ; INT 12h returns the amount of contiguous low memory in KB (in AX).
    ; Typically 640 KB (0x280).
    mov si, msg_conv_mem
    call puts
    int 0x12                        ; AX = conventional memory in KB
    call print_dec16
    mov si, msg_kb
    call puts

    ; --- Extended memory (INT 15h AH=88h) ------------------------------------
    ; Returns extended memory size in KB (above 1 MB, up to ~64 MB).
    mov si, msg_ext_mem
    call puts
    mov ah, 0x88
    int 0x15                        ; AX = extended memory in KB
    jc .no_ext                      ; CF set = not supported
    call print_dec16
    mov si, msg_kb
    call puts
    jmp .e820_start
.no_ext:
    mov si, msg_na
    call puts

.e820_start:
    ; --- E820 Memory Map (INT 15h EAX=E820h) ---------------------------------
    ; Each call returns one memory region descriptor (20 bytes).
    ; EBX = 0 to start, EBX = 0 on return means last entry.
    ;   Bytes 0-7:   Base address (64-bit)
    ;   Bytes 8-15:  Length in bytes (64-bit)
    ;   Bytes 16-19: Type (1=usable, 2=reserved, 3=ACPI, 4=NVS, 5=bad)
    mov si, msg_e820_hdr
    call puts

    xor ebx, ebx                   ; EBX = 0 to start enumeration
    mov di, e820_buf                ; ES:DI -> buffer for one entry

.e820_loop:
    mov eax, 0x0000E820            ; Function: query memory map
    mov ecx, 20                     ; Buffer size: 20 bytes per entry
    mov edx, 0x534D4150            ; 'SMAP' magic
    int 0x15

    jc .e820_done                   ; CF set = error or end of list
    cmp eax, 0x534D4150
    jne .e820_done

    push ebx                        ; Save continuation value

    ; Print: "  Base=XXXXXXXX Len=XXXXXXXX Type=N (name)"
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

    ; Print type name
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
    ; PAGE 3 - BIOS Data Area (BDA)
    ;
    ; The BDA lives at linear 0x0400-0x04FF.  We read it directly.
    ; =========================================================================
    mov si, msg_page3_hdr
    call puts

    ; --- COM ports (serial) at BDA 0x0400-0x0407 ----------------------------
    mov si, msg_com_hdr
    call puts

    mov cx, 4                       ; 4 COM ports max
    mov bx, 0x0400                  ; BDA offset for COM1
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

    ; --- LPT ports (parallel) at BDA 0x0408-0x040D --------------------------
    mov si, msg_lpt_hdr
    call puts

    mov cx, 3                       ; 3 LPT ports max
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

    ; --- Equipment word (INT 11h) --------------------------------------------
    mov si, msg_equip
    call puts
    int 0x11                        ; AX = equipment word
    call print_hex16
    mov si, msg_crlf
    call puts

    ; --- Video info from BDA -------------------------------------------------
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
    ; PAGE 4 - Video & Disk
    ; =========================================================================
    mov si, msg_page4_hdr
    call puts

    ; --- Active video mode (INT 10h AH=0Fh) ----------------------------------
    mov si, msg_vid_active
    call puts
    mov ah, 0x0F
    int 0x10                        ; AL=mode, AH=columns, BH=page
    push bx
    call puthex8
    mov si, msg_crlf
    call puts

    ; --- Active display page --------------------------------------------------
    mov si, msg_vid_page
    call puts
    pop bx
    mov al, bh
    call puthex8
    mov si, msg_crlf
    call puts

    ; --- Video memory base address -------------------------------------------
    mov si, msg_vid_base
    call puts
    mov al, [0x0449]
    cmp al, 0x07                    ; Monochrome?
    je .mono_base
    mov si, msg_b8000
    jmp .print_vbase
.mono_base:
    mov si, msg_b0000
.print_vbase:
    call puts

    ; --- Cursor position (INT 10h AH=03h) ------------------------------------
    mov si, msg_cursor
    call puts
    mov ah, 0x03
    xor bh, bh
    int 0x10                        ; DH=row, DL=column
    mov al, dh
    call puthex8
    mov al, ','
    call putc
    mov al, dl
    call puthex8
    mov si, msg_cursor_rc
    call puts

    ; --- Boot drive info ------------------------------------------------------
    mov si, msg_boot_drv
    call puts
    mov al, [boot_drive]
    call puthex8
    mov si, msg_crlf
    call puts

    ; --- Drive geometry (INT 13h AH=08h) -------------------------------------
    mov si, msg_drv_geom
    call puts
    mov dl, [boot_drive]
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

    ; --- EDD (Enhanced Disk Drive) support -----------------------------------
    ; INT 13h AH=41h checks if EDD extensions are available.
    ; AH=48h returns extended parameters: total sectors, bytes/sector.
    mov si, msg_edd_hdr
    call puts
    mov dl, [boot_drive]
    mov bx, 0x55AA
    mov ah, 0x41
    int 0x13
    jc .no_edd
    cmp bx, 0xAA55
    jne .no_edd

    ; EDD is supported - AH = version number
    push ax                         ; Save AH (version)

    mov si, msg_edd_ver
    call puts
    pop ax
    mov al, ah                      ; Version in AH
    call puthex8
    mov si, msg_crlf
    call puts

    ; Get extended drive parameters (AH=48h)
    ; DS:SI -> result buffer, first word = buffer size
    mov ah, 0x48
    mov dl, [boot_drive]
    mov si, edd_buf
    mov word [edd_buf], 30          ; Buffer size (26 minimum for v1.x)
    int 0x13
    jc .edd_no_params

    ; Total sectors (low 32 bits at offset 16-19, little-endian)
    mov si, msg_edd_sectors
    call puts
    mov ax, [edd_buf+18]            ; High word of low 32 bits
    call print_hex16
    mov ax, [edd_buf+16]            ; Low word of low 32 bits
    call print_hex16
    mov si, msg_crlf
    call puts

    ; Bytes per sector (offset 24-25)
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
    ; PAGE 5 - IVT Sample (Interrupt Vector Table)
    ;
    ; The IVT occupies the first 1024 bytes of memory (0x0000-0x03FF).
    ; Each of the 256 entries is a 4-byte far pointer (offset:segment).
    ; We display the first 8 vectors (INT 00h-07h).
    ; =========================================================================
    mov si, msg_page5_hdr
    call puts

    xor bx, bx                     ; BX = IVT offset (starts at 0x0000)
    xor cl, cl                      ; CL = interrupt number (0x00)

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

    ; Each IVT entry: offset (word) then segment (word)
    mov ax, [bx+2]                  ; Segment
    call print_hex16
    mov al, ':'
    call putc
    mov ax, [bx]                    ; Offset
    call print_hex16

    ; Print description from table
    push cx
    push bx
    xor ch, ch
    shl cx, 1                       ; x2 for word-size lookup
    mov bx, ivt_names_table
    add bx, cx
    mov si, [bx]
    call puts
    pop bx
    pop cx

    add bx, 4                       ; Next IVT entry
    inc cl
    jmp .ivt_loop

.ivt_done:
    ; Done with sysinfo - wait for key, then return to shell
    mov si, msg_sysinfo_done
    call puts

    call wait_key
    jmp shell_init                  ; Return to shell (clear + banner + prompt)

; =============================================================================
; SUBROUTINES
; =============================================================================

; ---------------------------------------------------------------------------
; readline - Read a line of input from the keyboard into cmd_buf.
;
; Reads characters one at a time via INT 16h AH=00h (blocking keyboard read).
; Echoes each character to screen.  Handles:
;   - Enter (0x0D): terminate the string with NUL and return
;   - Backspace (0x08): erase last character if buffer is not empty
;   - Printable ASCII (0x20-0x7E): append to buffer
;
; Output: cmd_buf contains NUL-terminated lowercase string
;         cmd_len contains the length (excluding NUL)
; ---------------------------------------------------------------------------
readline:
    xor cx, cx                      ; CX = current buffer index (0)

.read_char:
    xor ah, ah
    int 0x16                        ; AH=scan code, AL=ASCII char

    ; --- Enter pressed? ------------------------------------------------------
    cmp al, 0x0D
    je .read_done

    ; --- Backspace pressed? --------------------------------------------------
    cmp al, 0x08
    je .read_bs

    ; --- Printable character? ------------------------------------------------
    cmp al, 0x20
    jb .read_char                   ; Ignore control chars
    cmp al, 0x7E
    ja .read_char                   ; Ignore chars above '~'

    ; --- Buffer full? (max 31 chars to leave room for NUL) -------------------
    cmp cx, 31
    jge .read_char                  ; Ignore if buffer full

    ; --- Convert uppercase to lowercase --------------------------------------
    cmp al, 'A'
    jb .no_lower
    cmp al, 'Z'
    ja .no_lower
    add al, 32                      ; 'A'->'a', 'B'->'b', etc.
.no_lower:

    ; Store character and echo it
    mov bx, cmd_buf
    add bx, cx
    mov [bx], al
    inc cx

    ; Echo the character to screen
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    jmp .read_char

.read_bs:
    ; Backspace: only if we have characters to erase
    test cx, cx
    jz .read_char                   ; Nothing to erase

    dec cx                          ; Remove last char from buffer

    ; Move cursor back, print space (erase), move cursor back again
    mov ah, 0x0E
    mov al, 0x08                    ; Backspace
    xor bh, bh
    int 0x10
    mov al, ' '                     ; Overwrite with space
    int 0x10
    mov al, 0x08                    ; Move back again
    int 0x10
    jmp .read_char

.read_done:
    ; NUL-terminate the buffer
    mov bx, cmd_buf
    add bx, cx
    mov byte [bx], 0
    mov [cmd_len], cl

    ; Print newline after Enter
    mov si, msg_crlf
    call puts
    ret

; ---------------------------------------------------------------------------
; strcmp - Compare two NUL-terminated strings (case-sensitive).
;   Input:  DS:SI -> string 1, DS:DI -> string 2
;   Output: ZF set if strings are equal, cleared if different
; ---------------------------------------------------------------------------
strcmp:
    push si
    push di
.cmp_loop:
    lodsb                           ; AL = [SI], SI++
    mov ah, [di]
    inc di
    cmp al, ah
    jne .cmp_ne                     ; Characters differ
    test al, al
    jnz .cmp_loop                   ; Not end of string, keep comparing
    ; Both strings ended with NUL at the same position -> equal
    pop di
    pop si
    ret                             ; ZF is set (from test al,al where al=0)

.cmp_ne:
    pop di
    pop si
    ; Clear ZF to indicate not-equal
    or al, 1                        ; Guarantees ZF=0
    ret

; ---------------------------------------------------------------------------
; puts - Print a NUL-terminated string via BIOS teletype output.
;   Input:  DS:SI -> string
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
; putc - Print a single character.
;   Input:  AL = character
; ---------------------------------------------------------------------------
putc:
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    ret

; ---------------------------------------------------------------------------
; puthex8 - Print AL as two hex digits (e.g. AL=0x7F -> "7F").
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
; print_hex16 - Print AX as four hex digits (e.g. AX=0x03F8 -> "03F8").
; ---------------------------------------------------------------------------
print_hex16:
    push ax
    mov al, ah
    call puthex8
    pop ax
    call puthex8
    ret

; ---------------------------------------------------------------------------
; print_dec16 - Print AX as an unsigned decimal number (0-65535).
; ---------------------------------------------------------------------------
print_dec16:
    push cx
    push dx
    xor cx, cx

.div_loop:
    xor dx, dx
    mov bx, 10
    div bx                          ; AX = quotient, DX = remainder
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
; wait_key - Print "Press any key..." and wait for a keypress, then clear
;            the screen for the next page.
; ---------------------------------------------------------------------------
wait_key:
    mov si, msg_anykey
    call puts
    xor ah, ah
    int 0x16                        ; Wait for keypress
    ; Clear screen
    mov ax, 0x0003
    int 0x10
    ret

; =============================================================================
; DATA - String constants
; =============================================================================

; --- Shell strings -----------------------------------------------------------
msg_banner      db 13, 10
                db '  MNOS v0.3.0', 13, 10
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
msg_ver_text    db '  MNOS v0.3.0', 13, 10
                db '  Arch:      x86 real mode (16-bit)', 13, 10
                db '  Assembler: NASM', 13, 10
                db '  Platform:  Hyper-V Gen 1', 13, 10
                db '  Boot:      MBR -> VBR (16 sectors / 8 KB)', 13, 10
                db '  Disk:      16 MB fixed VHD', 13, 10
                db '  Source:    github.com/ambaner/mini-os', 13, 10, 0

; --- Sysinfo page headers ----------------------------------------------------
msg_page1_hdr   db '--- Page 1: CPU Information ---', 13, 10, 0
msg_page2_hdr   db 13, 10, '--- Page 2: Memory ---', 13, 10, 0
msg_page3_hdr   db 13, 10, '--- Page 3: BIOS Data Area ---', 13, 10, 0
msg_page4_hdr   db 13, 10, '--- Page 4: Video & Disk ---', 13, 10, 0
msg_page5_hdr   db 13, 10, '--- Page 5: IVT (Interrupt Vector Table) ---', 13, 10, 0

; --- Page 1 strings ----------------------------------------------------------
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

; --- Page 2 strings ----------------------------------------------------------
msg_com_hdr     db '  COM Ports:', 13, 10, 0
msg_lpt_hdr     db '  LPT Ports:', 13, 10, 0
msg_equip       db '  Equipment word: ', 0
msg_vid_mode_bda db '  Video mode (BDA): ', 0
msg_vid_cols    db '  Screen columns:   ', 0
msg_vid_pagesz  db '  Video page size:  ', 0
msg_bytes       db ' bytes', 13, 10, 0
msg_not_present db 'N/A', 13, 10, 0

; --- Page 3 strings ----------------------------------------------------------
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

; --- Page 4 strings ----------------------------------------------------------
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

; --- mem command strings ------------------------------------------------------
msg_mem_hdr     db 13, 10, '--- Memory Information ---', 13, 10, 0

msg_a20         db '  A20 gate:     ', 0
msg_a20_on      db 'Enabled (set by VBR at boot)', 13, 10, 0
msg_a20_off     db 'FAILED - all 3 methods failed', 13, 10, 0
msg_a20_live    db '  A20 verify:   ', 0
msg_a20_on_short  db 'OK', 13, 10, 0
msg_a20_off_short db 'FAIL (wrap detected)', 13, 10, 0

msg_layout_hdr  db 13, 10, '  Real-mode memory layout:', 13, 10, 0
msg_layout      db '    0x00000-0x003FF  1 KB    IVT (Interrupt Vector Table)', 13, 10
                db '    0x00400-0x004FF  256 B   BDA (BIOS Data Area)', 13, 10
                db '    0x00500-0x07BFF  30 KB   Free (usable by OS)', 13, 10
                db '    0x07C00-0x09FFF  9 KB    Boot area (MBR/VBR + stack)', 13, 10
                db '    0x0A000-0x0BFFF  8 KB    Video RAM (EGA/VGA)', 13, 10
                db '    0x0B800-0x0BFFF  2 KB    Color text video memory', 13, 10
                db '    0x0C000-0x0FFFF  16 KB   ROM area (BIOS, VGA BIOS)', 13, 10
                db '    0x10000-0xFFFFF  960 KB  Extended area (requires A20)', 13, 10, 0

; --- CPU information strings --------------------------------------------------
msg_cpu_vendor  db '  Vendor:     ', 0
msg_cpu_family  db '  Family:     ', 0
msg_cpu_model   db '  Model:      ', 0
msg_cpu_step    db '  Stepping:   ', 0
msg_cpu_feat    db '  Features:   ', 0
msg_no_cpuid    db '  CPUID not supported (pre-486 CPU)', 13, 10, 0

; Feature flag tag strings (printed inline, space-separated)
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

; Hypervisor detection strings
msg_hv_yes      db '  Hypervisor: Yes', 13, 10, 0
msg_hv_no       db '  Hypervisor: No', 13, 10, 0
msg_hv_vendor   db '  HV Vendor:  ', 0

; --- EDD (Enhanced Disk Drive) strings ---------------------------------------
msg_edd_hdr     db '  EDD Support:', 13, 10, 0
msg_edd_ver     db '    Version:       ', 0
msg_edd_sectors db '    Total sectors: ', 0
msg_edd_bps     db '    Bytes/sector:  ', 0
msg_edd_none    db '    Not available', 13, 10, 0

; --- Shared strings ----------------------------------------------------------
msg_crlf        db 13, 10, 0
msg_indent      db '    ', 0
msg_anykey      db 13, 10, '  Press any key...', 0

; =============================================================================
; RUNTIME DATA - Variables filled at runtime
; =============================================================================
boot_drive      db 0                ; Saved boot drive number (from MBR via DL)
a20_status      db 0                ; A20 enablement result (1=enabled, 0=failed)

; Command input buffer (32 bytes: 31 chars + NUL)
cmd_buf         times 32 db 0
cmd_len         db 0

; E820 buffer - one memory map entry (20 bytes)
e820_buf        times 20 db 0

; CPUID scratch space
cpuid_vendor    times 13 db 0       ; 12-byte vendor string + NUL
cpuid_ver       dd 0                ; Version info (family/model/stepping)
cpuid_feat_edx  dd 0                ; Feature flags (EDX from leaf 1)
cpuid_feat_ecx  dd 0                ; Feature flags (ECX from leaf 1)

; EDD extended drive parameters buffer (30 bytes)
edd_buf         times 30 db 0

; =============================================================================
; PADDING - fill remainder of 16-sector (8 KB) boot area with zeros
; (Boot signature is at offset 510 in sector 0, placed by the header above.)
; =============================================================================
times (16 * 512) - ($ - $$) db 0
