; =============================================================================
; Mini-OS Volume Boot Record (VBR) — System Information Display
;
; This is the second-stage bootloader.  The MBR finds the active partition in
; the partition table, then loads this code from the partition's first sector(s)
; into memory at 0x7C00 and jumps here.
;
; The VBR has a self-describing header that tells the MBR how many sectors to
; load.  The boot area is 16 sectors (8 KB), giving us plenty of room.
;
; After printing a banner, this VBR queries the BIOS and hardware to display
; four pages of system information:
;
;   Page 1 — CPU & Memory    (INT 12h, INT 15h AH=88h, E820 memory map)
;   Page 2 — BIOS Data Area  (COM/LPT ports, equipment word, video info)
;   Page 3 — Video & Disk    (video mode, cursor, boot drive geometry)
;   Page 4 — IVT Sample      (first 8 interrupt vectors)
;
; Each page pauses with "Press any key..." so the user can read it.
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
; VBR HEADER  (Sector 0 — first 512 bytes)
;
; The header occupies sector 0.  Because code + data exceed 510 bytes, the
; actual code lives in sector 1 onward.  A near-jump trampoline at offset 9
; reaches past the boot signature into sector 1.
; =============================================================================
    jmp short vbr_trampoline        ; 2 bytes: EB 07 — skip header fields
    nop                             ; 1 byte:  90    — standard filler

vbr_magic       db 'MNOS'          ; 4-byte magic identifier for mini-os
vbr_sectors     dw 16              ; Boot area = 16 sectors = 8 KB

vbr_trampoline:
    jmp near vbr_code              ; 3 bytes: E9 xx xx — near jump to sector 1

; Pad sector 0 and place the boot signature at offset 510
times 510 - ($ - $$) db 0
dw 0xAA55

; =============================================================================
; VBR CODE — Sector 1+ (offset 512 onward)
;
; At this point, the MBR has already:
;   - Set DS, ES, SS to 0, SP to 0x7C00
;   - Placed the boot drive number in DL
;   - Loaded all 16 boot-area sectors and copied them to 0x7C00
; =============================================================================
vbr_code:
    mov [boot_drive], dl            ; Save boot drive before we clobber DL

    ; --- Banner --------------------------------------------------------------
    mov si, msg_banner
    call puts

    ; =========================================================================
    ; PAGE 1 — CPU & Memory
    ; =========================================================================
    mov si, msg_page1_hdr
    call puts

    ; --- Conventional memory (INT 12h) ---------------------------------------
    ; INT 12h returns the amount of contiguous low memory in KB (in AX).
    ; Typically 640 KB (0x280).  This is the memory below the 1 MB boundary
    ; that is usable by real-mode programs.
    mov si, msg_conv_mem
    call puts
    int 0x12                        ; AX = conventional memory in KB
    call print_dec16                ; Print AX as decimal
    mov si, msg_kb
    call puts

    ; --- Extended memory (INT 15h AH=88h) ------------------------------------
    ; Returns extended memory size in KB (memory above 1 MB, up to ~64 MB).
    ; This is a legacy call; E820 below gives the full picture.
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
    ; This is the standard way to query the full system memory map.  Each call
    ; returns one memory region descriptor (20+ bytes) and a continuation value
    ; in EBX.  When EBX = 0, we've seen all regions.
    ;
    ; Each entry contains:
    ;   Bytes 0-7:   Base address (64-bit)
    ;   Bytes 8-15:  Length in bytes (64-bit)
    ;   Bytes 16-19: Type (1=usable, 2=reserved, 3=ACPI reclaimable,
    ;                      4=ACPI NVS, 5=bad memory)
    ;
    ; We store each entry in a temporary buffer at `e820_buf`.
    mov si, msg_e820_hdr
    call puts

    xor ebx, ebx                   ; EBX = 0 to start enumeration
    mov di, e820_buf                ; ES:DI -> buffer for one entry

.e820_loop:
    mov eax, 0x0000E820            ; Function: query memory map
    mov ecx, 20                     ; Buffer size: 20 bytes per entry
    mov edx, 0x534D4150            ; 'SMAP' magic (required by BIOS)
    int 0x15

    jc .e820_done                   ; CF set = error or end of list

    ; Verify the BIOS returned 'SMAP' in EAX (sanity check)
    cmp eax, 0x534D4150
    jne .e820_done

    ; Print this entry: "  Base=XXXXXXXX Len=XXXXXXXX Type=X"
    push ebx                        ; Save continuation value

    mov si, msg_e820_base
    call puts

    ; Print base address (we show low 32 bits — high 32 are usually 0)
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

    ; Print length (low 32 bits)
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

    ; Print type as single digit (1-5)
    mov al, [e820_buf+16]
    add al, '0'
    call putc

    ; Print type name
    mov al, [e820_buf+16]           ; Type value (1-5)
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

    pop ebx                         ; Restore continuation value
    test ebx, ebx                   ; EBX = 0 means last entry
    jnz .e820_loop

.e820_done:
    call wait_key                   ; "Press any key..."

    ; =========================================================================
    ; PAGE 2 — BIOS Data Area (BDA)
    ;
    ; The BIOS Data Area lives at segment 0x0040 (linear 0x0400-0x04FF).
    ; It contains hardware info detected during POST.  We read it directly
    ; from memory using absolute addresses (DS = 0, so 0x0400+ works).
    ; =========================================================================
    mov si, msg_page2_hdr
    call puts

    ; --- COM ports (serial) at BDA 0x0400-0x0407 ----------------------------
    ; Up to 4 COM port base I/O addresses, each a 16-bit word.
    ; 0x0000 means the port is not present.
    mov si, msg_com_hdr
    call puts

    mov cx, 4                       ; 4 COM ports max
    mov bx, 0x0400                  ; BDA offset for COM1
.com_loop:
    push cx
    mov si, msg_indent
    call puts
    ; Print "COMn: "
    mov al, 'C'
    call putc
    mov al, 'O'
    call putc
    mov al, 'M'
    call putc
    mov al, 5                       ; 5 - cx gives us 1,2,3,4
    pop cx
    push cx
    sub al, cl
    add al, '0'
    call putc
    mov al, ':'
    call putc
    mov al, ' '
    call putc

    mov ax, [bx]                    ; Read port address from BDA
    test ax, ax
    jz .com_none
    call print_hex16                ; Print as 4-digit hex
    mov si, msg_crlf
    call puts
    jmp .com_next
.com_none:
    mov si, msg_not_present
    call puts
.com_next:
    add bx, 2                       ; Next COM port entry
    pop cx
    dec cx
    jnz .com_loop

    ; --- LPT ports (parallel) at BDA 0x0408-0x040D --------------------------
    mov si, msg_lpt_hdr
    call puts

    mov cx, 3                       ; 3 LPT ports max
    mov bx, 0x0408                  ; BDA offset for LPT1
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
    ; Returns a 16-bit bitmask describing installed hardware:
    ;   Bit 0:    Floppy drive(s) installed
    ;   Bit 1:    Math coprocessor present
    ;   Bits 2-3: System board RAM size (obsolete)
    ;   Bits 4-5: Initial video mode (00=EGA/VGA, 01=40x25 CGA, 10=80x25 CGA)
    ;   Bits 6-7: Number of floppy drives - 1 (if bit 0 set)
    ;   And more...
    mov si, msg_equip
    call puts
    int 0x11                        ; AX = equipment word
    call print_hex16
    mov si, msg_crlf
    call puts

    ; --- Video info from BDA -------------------------------------------------
    ; BDA 0x0449: current video mode
    ; BDA 0x044A: number of screen columns (word)
    ; BDA 0x044C: video page size in bytes (word)
    ; BDA 0x0462: current active display page
    mov si, msg_vid_mode_bda
    call puts
    mov al, [0x0449]                ; Current video mode
    call puthex8
    mov si, msg_crlf
    call puts

    mov si, msg_vid_cols
    call puts
    mov ax, [0x044A]                ; Screen columns
    call print_dec16
    mov si, msg_crlf
    call puts

    mov si, msg_vid_pagesz
    call puts
    mov ax, [0x044C]                ; Page size in bytes
    call print_dec16
    mov si, msg_bytes
    call puts

    call wait_key

    ; =========================================================================
    ; PAGE 3 — Video & Disk
    ; =========================================================================
    mov si, msg_page3_hdr
    call puts

    ; --- Active video mode (INT 10h AH=0Fh) ----------------------------------
    mov si, msg_vid_active
    call puts
    mov ah, 0x0F                    ; Get current video mode
    int 0x10                        ; AL=mode, AH=columns, BH=page
    push bx                         ; Save page number
    call puthex8                    ; Print mode in AL
    mov si, msg_crlf
    call puts

    ; --- Active display page --------------------------------------------------
    mov si, msg_vid_page
    call puts
    pop bx
    mov al, bh                      ; Page number from INT 10h
    call puthex8
    mov si, msg_crlf
    call puts

    ; --- Video memory base address -------------------------------------------
    ; In text mode 03h, the VGA text buffer is at linear address 0xB8000
    ; (segment 0xB800).  In monochrome mode (07h), it's 0xB0000.
    mov si, msg_vid_base
    call puts
    mov al, [0x0449]                ; Current video mode
    cmp al, 0x07                    ; Monochrome?
    je .mono_base
    mov si, msg_b8000               ; Color text: 0xB8000
    jmp .print_vbase
.mono_base:
    mov si, msg_b0000               ; Mono text: 0xB0000
.print_vbase:
    call puts

    ; --- Cursor position (INT 10h AH=03h) ------------------------------------
    mov si, msg_cursor
    call puts
    mov ah, 0x03                    ; Get cursor position
    xor bh, bh                     ; Page 0
    int 0x10                        ; DH=row, DL=column
    mov al, dh                      ; Row
    call puthex8
    mov al, ','
    call putc
    mov al, dl                      ; Column
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
    ; Returns disk geometry for the boot drive:
    ;   CH = low 8 bits of max cylinder number
    ;   CL = max sector number (bits 0-5), high 2 bits of cylinder (bits 6-7)
    ;   DH = max head number
    ;   DL = number of drives
    mov si, msg_drv_geom
    call puts
    mov dl, [boot_drive]
    mov ah, 0x08                    ; Get drive parameters
    int 0x13
    jc .no_geom                     ; CF set = error

    push dx                         ; Save heads/drives

    ; Cylinders: combine CH (low 8 bits) and CL bits 6-7 (high 2 bits)
    mov si, msg_drv_cyl
    call puts
    mov al, cl
    shr al, 6                       ; High 2 bits of cylinder count
    call puthex8
    mov al, ch                      ; Low 8 bits
    call puthex8
    mov si, msg_crlf
    call puts

    ; Sectors per track (CL bits 0-5)
    mov si, msg_drv_sec
    call puts
    mov al, cl
    and al, 0x3F                    ; Mask to 6 bits
    xor ah, ah
    call print_dec16
    mov si, msg_crlf
    call puts

    ; Heads
    pop dx
    mov si, msg_drv_head
    call puts
    mov al, dh                      ; Max head number
    inc al                          ; Heads = max head + 1
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
    ; PAGE 4 — IVT Sample (Interrupt Vector Table)
    ;
    ; The IVT occupies the first 1024 bytes of memory (0x0000-0x03FF).
    ; Each of the 256 entries is a 4-byte far pointer (offset:segment).
    ; We display the first 8 vectors (INT 00h-07h):
    ;   INT 00h = Divide by zero
    ;   INT 01h = Single step (debug)
    ;   INT 02h = NMI
    ;   INT 03h = Breakpoint
    ;   INT 04h = Overflow
    ;   INT 05h = BOUND range exceeded / Print Screen
    ;   INT 06h = Invalid opcode
    ;   INT 07h = Device not available (no coprocessor)
    ; =========================================================================
    mov si, msg_page4_hdr
    call puts

    xor bx, bx                     ; BX = IVT offset (starts at 0x0000)
    xor cl, cl                      ; CL = interrupt number (0x00)

.ivt_loop:
    cmp cl, 8                       ; Done after 8 entries?
    jge .ivt_done

    ; Print "  INT XXh: SSSS:OOOO"
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
    mov al, cl                      ; Interrupt number
    call puthex8
    mov al, 'h'
    call putc
    mov al, ':'
    call putc
    mov al, ' '
    call putc

    ; Each IVT entry is 4 bytes: offset (word), then segment (word)
    mov ax, [bx+2]                  ; Segment
    call print_hex16
    mov al, ':'
    call putc
    mov ax, [bx]                    ; Offset
    call print_hex16

    ; Print description
    push cx
    push bx
    xor ch, ch                      ; CX = interrupt number
    shl cx, 1                       ; x 2 for word-size table lookup
    mov bx, ivt_names_table
    add bx, cx
    mov si, [bx]                    ; SI -> description string
    call puts
    pop bx
    pop cx

    add bx, 4                       ; Next IVT entry (4 bytes each)
    inc cl                          ; Next interrupt number
    jmp .ivt_loop

.ivt_done:

    ; --- Final message -------------------------------------------------------
    mov si, msg_final
    call puts

    cli                             ; Disable interrupts
    hlt                             ; Halt — boot complete

; =============================================================================
; SUBROUTINES
; =============================================================================

; ---------------------------------------------------------------------------
; puts — Print a NUL-terminated string via BIOS teletype output.
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
; putc — Print a single character.
;   Input:  AL = character
; ---------------------------------------------------------------------------
putc:
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    ret

; ---------------------------------------------------------------------------
; puthex8 — Print AL as two hex digits (e.g. AL=0x7F -> "7F").
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
; print_hex16 — Print AX as four hex digits (e.g. AX=0x03F8 -> "03F8").
; ---------------------------------------------------------------------------
print_hex16:
    push ax
    mov al, ah                      ; Print high byte first
    call puthex8
    pop ax
    call puthex8                    ; Print low byte
    ret

; ---------------------------------------------------------------------------
; print_dec16 — Print AX as an unsigned decimal number (0-65535).
;
; Algorithm: repeatedly divide AX by 10, push remainders onto the stack,
; then pop and print them in reverse order.
; ---------------------------------------------------------------------------
print_dec16:
    push cx
    push dx
    xor cx, cx                      ; CX = digit counter

.div_loop:
    xor dx, dx                      ; DX:AX = dividend
    mov bx, 10
    div bx                          ; AX = quotient, DX = remainder
    push dx                         ; Push remainder (0-9)
    inc cx                          ; Count digits
    test ax, ax
    jnz .div_loop                   ; More digits?

.print_loop:
    pop ax                          ; Get digit (in reverse order)
    add al, '0'                     ; Convert to ASCII
    call putc
    dec cx
    jnz .print_loop

    pop dx
    pop cx
    ret

; ---------------------------------------------------------------------------
; wait_key — Print "Press any key..." and wait for a keypress, then clear
;            the screen for the next page.
; ---------------------------------------------------------------------------
wait_key:
    mov si, msg_anykey
    call puts

    ; INT 16h AH=00h: Wait for keypress.  Blocks until a key is pressed.
    xor ah, ah
    int 0x16                        ; AH = scan code, AL = ASCII char

    ; Clear screen for next page (set video mode 3 = 80x25 text)
    mov ax, 0x0003
    int 0x10
    ret

; =============================================================================
; DATA — String constants
; =============================================================================

; --- Banner & page headers ---------------------------------------------------
msg_banner      db 13, 10, 'mini-os VBR - System Information', 13, 10
                db '================================', 13, 10, 0

msg_page1_hdr   db 13, 10, '--- Page 1: CPU & Memory ---', 13, 10, 0
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
; IVT description table — one string pointer per interrupt (0-7)
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

; --- Shared strings ----------------------------------------------------------
msg_crlf        db 13, 10, 0
msg_indent      db '    ', 0
msg_anykey      db 13, 10, '  Press any key...', 0
msg_final       db 13, 10, 'mini-os boot completed.', 13, 10
                db 'System halted.', 13, 10, 0

; =============================================================================
; RUNTIME DATA — Variables filled at runtime
; =============================================================================
boot_drive      db 0                ; Saved boot drive number (from MBR via DL)

; E820 buffer — one memory map entry (20 bytes)
e820_buf        times 20 db 0

; =============================================================================
; PADDING — fill remainder of 16-sector (8 KB) boot area with zeros
; (Boot signature is at offset 510 in sector 0, placed by the header above.)
; =============================================================================
times (16 * 512) - ($ - $$) db 0
