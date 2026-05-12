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
;   sysinfo  - Display 4 pages of system information
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
    ; Test whether the A20 address line is enabled by checking if memory
    ; wraps around at the 1 MB boundary.
    ;
    ; How it works:
    ;   Linear address 0x0000:0x0500 and 0xFFFF:0x0510 map to:
    ;     0x00000500  and  0x00100500 (if A20 enabled)
    ;     0x00000500  and  0x00000500 (if A20 disabled — wraps around)
    ;
    ;   We save the byte at [0x0000:0x0500], write a test value to
    ;   [0xFFFF:0x0510], and check if [0x0000:0x0500] changed.
    ;   If it changed, A20 is disabled (addresses wrap).
    mov si, msg_a20
    call puts

    push ds
    push es

    xor ax, ax
    mov ds, ax                      ; DS = 0x0000
    mov ax, 0xFFFF
    mov es, ax                      ; ES = 0xFFFF

    ; Save original bytes at both locations
    mov al, [ds:0x0500]
    push ax                         ; Save [0x0000:0x0500]
    mov al, [es:0x0510]
    push ax                         ; Save [0xFFFF:0x0510]

    ; Write test pattern
    mov byte [es:0x0510], 0x13      ; Write to 0xFFFF:0x0510
    mov byte [ds:0x0500], 0x37      ; Write different value to 0x0000:0x0500

    ; If A20 is disabled, writing to 0x0000:0x0500 also changed 0xFFFF:0x0510
    cmp byte [es:0x0510], 0x37
    je .a20_disabled

    ; A20 is enabled (the two addresses are independent)
    mov si, msg_a20_on
    jmp .a20_restore

.a20_disabled:
    mov si, msg_a20_off

.a20_restore:
    ; Restore original bytes
    pop ax
    mov [es:0x0510], al
    pop ax
    mov [ds:0x0500], al

    pop es
    pop ds

    call puts

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
; Display 4 pages of system information, pausing between each page.
; This is the same system info display from v0.2.2, now wrapped as a command.
; =============================================================================
cmd_sysinfo:
    ; =========================================================================
    ; PAGE 1 - CPU & Memory
    ; =========================================================================
    ; Clear screen for page 1
    mov ax, 0x0003
    int 0x10

    mov si, msg_page1_hdr
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
    ; PAGE 2 - BIOS Data Area (BDA)
    ;
    ; The BDA lives at linear 0x0400-0x04FF.  We read it directly.
    ; =========================================================================
    mov si, msg_page2_hdr
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
    ; PAGE 3 - Video & Disk
    ; =========================================================================
    mov si, msg_page3_hdr
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
    call wait_key

    ; =========================================================================
    ; PAGE 4 - IVT Sample (Interrupt Vector Table)
    ;
    ; The IVT occupies the first 1024 bytes of memory (0x0000-0x03FF).
    ; Each of the 256 entries is a 4-byte far pointer (offset:segment).
    ; We display the first 8 vectors (INT 00h-07h).
    ; =========================================================================
    mov si, msg_page4_hdr
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
                db '  MNOS v0.2.6', 13, 10
                db 13, 10, 0

msg_prompt      db 'mnos:\>', 0

msg_unknown     db 'Unknown command: ', 0

msg_help_text   db 'Available commands:', 13, 10
                db '  sysinfo  - Display system information (4 pages)', 13, 10
                db '  mem      - Detailed memory info and layout', 13, 10
                db '  help     - Show this help message', 13, 10
                db '  cls      - Clear the screen', 13, 10
                db '  reboot   - Restart the system', 13, 10, 0

; --- Command name strings (for strcmp) ----------------------------------------
str_sysinfo     db 'sysinfo', 0
str_help        db 'help', 0
str_mem         db 'mem', 0
str_cls         db 'cls', 0
str_reboot      db 'reboot', 0

; --- Sysinfo page headers ----------------------------------------------------
msg_page1_hdr   db '--- Page 1: CPU & Memory ---', 13, 10, 0
msg_page2_hdr   db 13, 10, '--- Page 2: BIOS Data Area ---', 13, 10, 0
msg_page3_hdr   db 13, 10, '--- Page 3: Video & Disk ---', 13, 10, 0
msg_page4_hdr   db 13, 10, '--- Page 4: IVT (Interrupt Vector Table) ---', 13, 10, 0

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
msg_a20_on      db 'Enabled (normal for Hyper-V)', 13, 10, 0
msg_a20_off     db 'Disabled (addresses wrap at 1 MB)', 13, 10, 0

msg_layout_hdr  db 13, 10, '  Real-mode memory layout:', 13, 10, 0
msg_layout      db '    0x00000-0x003FF  1 KB    IVT (Interrupt Vector Table)', 13, 10
                db '    0x00400-0x004FF  256 B   BDA (BIOS Data Area)', 13, 10
                db '    0x00500-0x07BFF  30 KB   Free (usable by OS)', 13, 10
                db '    0x07C00-0x09FFF  9 KB    Boot area (MBR/VBR + stack)', 13, 10
                db '    0x0A000-0x0BFFF  8 KB    Video RAM (EGA/VGA)', 13, 10
                db '    0x0B800-0x0BFFF  2 KB    Color text video memory', 13, 10
                db '    0x0C000-0x0FFFF  16 KB   ROM area (BIOS, VGA BIOS)', 13, 10
                db '    0x10000-0xFFFFF  960 KB  Extended area (requires A20)', 13, 10, 0

; --- Shared strings ----------------------------------------------------------
msg_crlf        db 13, 10, 0
msg_indent      db '    ', 0
msg_anykey      db 13, 10, '  Press any key...', 0

; =============================================================================
; RUNTIME DATA - Variables filled at runtime
; =============================================================================
boot_drive      db 0                ; Saved boot drive number (from MBR via DL)

; Command input buffer (32 bytes: 31 chars + NUL)
cmd_buf         times 32 db 0
cmd_len         db 0

; E820 buffer - one memory map entry (20 bytes)
e820_buf        times 20 db 0

; =============================================================================
; PADDING - fill remainder of 16-sector (8 KB) boot area with zeros
; (Boot signature is at offset 510 in sector 0, placed by the header above.)
; =============================================================================
times (16 * 512) - ($ - $$) db 0
