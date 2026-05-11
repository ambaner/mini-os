; =============================================================================
; Mini-OS Volume Boot Record (VBR)
;
; This is the second-stage bootloader.  The MBR finds the active partition in
; the partition table, then loads this code from the partition's first sector(s)
; into memory at 0x7C00 and jumps here.
;
; The VBR has a self-describing header that tells the MBR how many sectors to
; load.  Currently the boot area is 16 sectors (8 KB), giving us plenty of
; room for future features (protected mode switch, kernel loader, etc.).
; Only the first sector contains code right now — the other 15 are reserved.
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

; ---------------------------------------------------------------------------
; VBR Header — must be at the very start of the partition's first sector.
; The MBR reads vbr_sectors (offset 7) to know how many sectors to load.
; The JMP SHORT skips over the header so the CPU doesn't try to execute the
; header bytes as code.
; ---------------------------------------------------------------------------
    jmp short vbr_code              ; 2 bytes: EB xx — skip over header
    nop                             ; 1 byte:  90    — standard filler

vbr_magic       db 'MNOS'          ; 4-byte magic identifier for mini-os
vbr_sectors     dw 16              ; Boot area = 16 sectors = 8 KB
                                    ; MBR reads this to know how much to load.
                                    ; Increase as the VBR code grows.

; ---------------------------------------------------------------------------
; VBR Code — execution starts here after the JMP SHORT above.
;
; At this point, the MBR has already:
;   - Set DS, ES, SS to 0, SP to 0x7C00
;   - Placed the boot drive number in DL
;   - Loaded all 16 boot-area sectors and copied them to 0x7C00
; ---------------------------------------------------------------------------
vbr_code:
    mov si, msg_vbr                 ; SI → "In boot sector now\r\n"
    call print_string               ; Print via BIOS teletype

    mov si, msg_done                ; SI → "mini-os boot completed\r\n"
    call print_string

    cli                             ; Disable interrupts
    hlt                             ; Halt — nothing more to do (yet!)

; ---------------------------------------------------------------------------
; print_string — Print a NUL-terminated string via BIOS teletype output.
;   Input:  DS:SI → string to print
;   Clobbers: AX, BH
;   Uses INT 10h AH=0Eh for each character until a NUL (0x00) byte.
; ---------------------------------------------------------------------------
print_string:
    lodsb                           ; AL = next byte, SI++
    test al, al                     ; NUL terminator?
    jz .done                        ; Yes → we're done
    mov ah, 0x0E                    ; BIOS teletype output function
    xor bh, bh                     ; Display page 0
    int 0x10                        ; Print the character
    jmp print_string                ; Loop for next character
.done:
    ret

; ---------------------------------------------------------------------------
; Data — String constants
; ---------------------------------------------------------------------------
msg_vbr  db 13, 10, 'In boot sector now', 13, 10, 0
msg_done db 'mini-os boot completed', 13, 10, 0

; ---------------------------------------------------------------------------
; Pad to exactly 512 bytes (one sector) with boot signature.
; The 0xAA55 at bytes 510–511 marks this as a valid boot sector.
; As the VBR grows beyond one sector, this padding and signature can be
; moved to accommodate more code and data.
; ---------------------------------------------------------------------------
times 510 - ($ - $$) db 0
dw 0xAA55
