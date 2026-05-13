; =============================================================================
; debug.inc — Debug logging macros for mini-os
;
; Provides DBG, DBG_REG, and DBG_REGS macros that output to the serial port.
; All macros are conditional on %ifdef DEBUG — in release builds they expand
; to exactly 0 bytes.
;
; Prerequisites:
;   - serial.inc must be %included in the same file (provides serial_*)
;   - serial_init must have been called before any macro is used
;
; Usage:
;   %include "serial.inc"
;   %include "debug.inc"
;
;   DBG "Loading FS.BIN"          ; → [DBG] Loading FS.BIN\r\n  (to COM1)
;   DBG_REG "AX", ax              ; → AX=1234                   (to COM1)
;   DBG_REGS                       ; → AX=xxxx BX=xxxx ... \r\n (to COM1)
;
; See doc/DEBUGGING.md §3 for full specification.
; =============================================================================

%ifdef DEBUG

; -----------------------------------------------------------------------------
; DBG — Print a debug message to serial (compile-time string constant)
;
; Generates an inline string with a jmp to skip over it.
; Output format: [DBG] <message>\r\n
;
; Usage:  DBG "Loading FS.BIN"
; -----------------------------------------------------------------------------
%macro DBG 1
    jmp %%after
    %%msg: db '[DBG] ', %1, 13, 10, 0
%%after:
    push si
    mov si, %%msg
    call serial_puts
    pop si
%endmacro

; -----------------------------------------------------------------------------
; DBG_REG — Print a register name and its hex value to serial
;
; Output format: <name>=<hex_value><space>  (no newline)
;
; Usage:  DBG_REG "AX", ax
;         DBG_REG "DI", di
; -----------------------------------------------------------------------------
%macro DBG_REG 2
    jmp %%after
    %%lbl: db %1, '=', 0
%%after:
    push si
    push ax
    mov si, %%lbl
    call serial_puts
    mov ax, %2
    call serial_hex16
    mov al, ' '
    call serial_putc
    pop ax
    pop si
%endmacro

; -----------------------------------------------------------------------------
; DBG_REGS — Dump all general-purpose registers to serial
;
; Output format: AX=xxxx BX=xxxx CX=xxxx DX=xxxx SI=xxxx DI=xxxx\r\n
;
; Usage:  DBG_REGS
; -----------------------------------------------------------------------------
%macro DBG_REGS 0
    DBG_REG "AX", ax
    DBG_REG "BX", bx
    DBG_REG "CX", cx
    DBG_REG "DX", dx
    DBG_REG "SI", si
    DBG_REG "DI", di
    call serial_crlf
%endmacro

%else
; =============================================================================
; Release build — all debug macros expand to nothing (0 bytes)
; =============================================================================
%macro DBG 1
%endmacro
%macro DBG_REG 2
%endmacro
%macro DBG_REGS 0
%endmacro

%endif ; DEBUG
