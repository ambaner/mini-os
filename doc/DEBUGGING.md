# Debugging Infrastructure — Design Document

**Version:** 1.1
**Status:** Partially implemented in v0.7.0 (see status table below)
**Audience:** mini-os developers

---

## 1. Motivation

The v0.6.0 development cycle exposed a class of bugs that were extremely
difficult to diagnose:

| Bug | Symptom | Root Cause | Debugging Time |
|-----|---------|------------|----------------|
| AH register overlap | FS init silently failed | `mov ah, SYS_xxx` clobbered LBA bits 8-15 | Hours |
| CF propagation | Error flag silently lost | `iret` restored caller's FLAGS, not handler's | Hours |
| Wrong `dir` values | All files showed 4610 sectors | Same AH overlap in print functions | 30+ min |

Each of these bugs had the same profile:

1. **Silent corruption** — no crash, no visible error, just wrong behavior.
2. **Distant effect** — the corruption happened in the kernel, but the symptom
   appeared in user-mode code.
3. **No trace** — with only screen output available, there was no way to see
   what registers contained at the moment of the bug.

Real operating systems solve this with layered debugging infrastructure.  This
document designs seven facilities for mini-os, ordered by impact.

---

## 2. Overview of Facilities

```
┌──────────────────────┬──────────────────────────────────────────┬───────────────┐
│                      │  Debugging Facilities                   │ Status        │
├──────────────────────┼──────────────────────────────────────────┼───────────────┤
│ § 3  Serial Debug Log│ COM1 (0x3F8) output for all debug msgs  │ ✅ v0.7.0     │
│ § 4  Syscall Tracing │ Log every INT 0x80/0x81 with names      │ ✅ v0.7.0     │
│ § 5  Assert Macros   │ Compile-time condition checks           │ 📋 Future     │
│ § 6  Fault Handlers  │ Trap CPU exceptions with state dump     │ 📋 Future     │
│ § 7  Machine Monitor │ Wozmon-style memory examine/deposit/run │ 📋 Future     │
│ § 8  Debug Build Mode│ %ifdef DEBUG conditional assembly       │ ✅ v0.7.0     │
│ § 9  Stack Canary    │ Corruption sentinel at stack floor      │ 📋 Future     │
└──────────────────────┴──────────────────────────────────────────┴───────────────┘
```

**Dependency graph:**

```
Debug Build Mode (§ 8) ──→ controls all others via %ifdef DEBUG
        │
        ├── Serial Debug Log (§ 3)  ←── foundation for all logging
        │       │
        │       ├── Syscall Tracing (§ 4)   ←── uses serial output
        │       ├── Assert Macros (§ 5)     ←── uses serial output
        │       ├── Fault Handlers (§ 6)    ←── uses serial output
        │       └── Stack Canary (§ 9)      ←── uses serial output
        │
        └── Machine Monitor (§ 7)  ←── always-on (uses screen, not serial)
```

Serial logging (§3) is the foundation — every other logging facility writes
its output through the serial port so it doesn't interfere with screen output.

---

## 3. Serial Debug Log

### 3.1 Why Serial?

Screen output (INT 10h / BIOS teletype) is the only output channel mini-os
currently has.  This creates two problems:

1. **Debug messages corrupt the user experience** — boot messages, syscall
   traces, and assert failures clutter the screen and scroll important output
   away.
2. **Output is ephemeral** — once text scrolls off the 25-row VGA screen,
   it's gone.  There's no scrollback, no log file, no history.

Serial port output solves both:

- **Invisible to the user** — serial data goes to COM1 (I/O port 0x3F8),
  completely independent of the VGA display.
- **Capturable** — Hyper-V can connect a VM's COM1 to a named pipe on the
  host.  Any terminal emulator (PuTTY, screen, PowerShell) can read the pipe
  and save it to a file.  You get a permanent, complete log of everything
  the OS did.
- **Works before everything** — serial output requires no BIOS, no INT 10h,
  no memory manager.  It's direct port I/O.  It works from the very first
  instruction of the MBR.

### 3.2 x86 Serial Port (UART 8250/16550) Primer

Every PC-compatible system has at least one UART (Universal Asynchronous
Receiver/Transmitter) mapped to I/O ports.  The standard assignments are:

| Port | Name | I/O Base | IRQ |
|------|------|----------|-----|
| COM1 | Serial Port 1 | 0x3F8 | IRQ 4 |
| COM2 | Serial Port 2 | 0x2F8 | IRQ 3 |
| COM3 | Serial Port 3 | 0x3E8 | IRQ 4 |
| COM4 | Serial Port 4 | 0x2E8 | IRQ 3 |

Each UART has 8 registers at consecutive I/O ports:

```
Offset  Register (DLAB=0)         Register (DLAB=1)
──────  ────────────────────────  ─────────────────────────
+0      THR (Transmit Hold)       DLL (Divisor Latch Low)
+1      IER (Interrupt Enable)    DLM (Divisor Latch High)
+2      IIR (Interrupt Identify)  FCR (FIFO Control)
+3      LCR (Line Control)
+4      MCR (Modem Control)
+5      LSR (Line Status)         ← Bit 5 = TX buffer empty
+6      MSR (Modem Status)
+7      Scratch Register
```

**DLAB** (Divisor Latch Access Bit) is bit 7 of the LCR register.  When set,
ports +0 and +1 become the baud rate divisor registers instead of THR/IER.

### 3.3 Initialization Sequence

Before sending any data, the UART must be configured.  The initialization
sequence:

```nasm
; =============================================================================
; serial_init — Initialize COM1 at 115200 baud, 8N1
;
; Must be called once during early boot (LOADER or KERNEL init).
; No BIOS calls needed — pure port I/O.
; =============================================================================

COM1_BASE   equ 0x3F8
COM1_THR    equ COM1_BASE + 0      ; Transmit Holding Register
COM1_IER    equ COM1_BASE + 1      ; Interrupt Enable Register
COM1_FCR    equ COM1_BASE + 2      ; FIFO Control Register
COM1_LCR    equ COM1_BASE + 3      ; Line Control Register
COM1_MCR    equ COM1_BASE + 4      ; Modem Control Register
COM1_LSR    equ COM1_BASE + 5      ; Line Status Register

serial_init:
    ; Step 1: Disable all UART interrupts
    ;   We're polling, not using IRQs.  Clear IER to prevent
    ;   spurious interrupts from the UART.
    mov dx, COM1_IER
    xor al, al                          ; 0x00 = no interrupts
    out dx, al

    ; Step 2: Set DLAB to access baud rate divisor
    ;   Writing 0x80 to LCR sets the DLAB bit.  Now ports +0/+1
    ;   become the divisor latch instead of THR/IER.
    mov dx, COM1_LCR
    mov al, 0x80                        ; DLAB = 1
    out dx, al

    ; Step 3: Set baud rate to 115200
    ;   The UART clock runs at 1.8432 MHz.  The divisor is:
    ;     divisor = 1843200 / (16 × baud_rate)
    ;   For 115200 baud: divisor = 1843200 / 1843200 = 1
    ;   Write low byte (1) to DLL, high byte (0) to DLM.
    mov dx, COM1_BASE                   ; DLL (port +0, DLAB=1)
    mov al, 1                           ; Divisor low byte = 1
    out dx, al
    mov dx, COM1_BASE + 1              ; DLM (port +1, DLAB=1)
    xor al, al                          ; Divisor high byte = 0
    out dx, al

    ; Step 4: Configure line format: 8 data bits, no parity, 1 stop bit (8N1)
    ;   LCR bits:
    ;     [1:0] = 11  → 8 data bits
    ;     [2]   = 0   → 1 stop bit
    ;     [5:3] = 000 → no parity
    ;     [7]   = 0   → clear DLAB (back to normal THR/IER)
    mov dx, COM1_LCR
    mov al, 0x03                        ; 8N1, DLAB = 0
    out dx, al

    ; Step 5: Enable and clear FIFOs
    ;   FCR bits:
    ;     [0] = 1 → enable FIFOs
    ;     [1] = 1 → clear receive FIFO
    ;     [2] = 1 → clear transmit FIFO
    ;     [7:6] = 11 → 14-byte trigger level
    mov dx, COM1_FCR
    mov al, 0xC7                        ; Enable + clear FIFOs, 14-byte trigger
    out dx, al

    ; Step 6: Configure modem control
    ;   MCR bits:
    ;     [0] = DTR (Data Terminal Ready)
    ;     [1] = RTS (Request To Send)
    ;     [3] = OUT2 (required for interrupts on some UARTs)
    ;   We set DTR + RTS + OUT2 even though we're polling — some
    ;   virtual COM implementations check DTR/RTS.
    mov dx, COM1_MCR
    mov al, 0x0B                        ; DTR + RTS + OUT2
    out dx, al

    ret
```

### 3.4 Sending a Character

Sending a byte requires waiting for the transmit buffer to be empty (bit 5
of the Line Status Register), then writing the byte to the Transmit Holding
Register:

```nasm
; =============================================================================
; serial_putc — Send one character to COM1
;
; Input:  AL = character to send
; Output: none
; Clobbers: DX (saved/restored if caller needs it preserved)
; =============================================================================
serial_putc:
    push dx
    push ax                             ; Save the character

    ; Wait for transmit buffer empty (LSR bit 5)
    mov dx, COM1_LSR
.wait_tx:
    in al, dx                           ; Read Line Status Register
    test al, 0x20                       ; Bit 5: Transmit Holding Register Empty?
    jz .wait_tx                         ; Spin until ready

    ; Send the character
    pop ax                              ; Restore character
    mov dx, COM1_THR
    out dx, al                          ; Write byte to transmit register

    pop dx
    ret
```

### 3.5 Higher-Level Logging Functions

Building on `serial_putc`, we create a family of helpers:

```nasm
; serial_puts — Send NUL-terminated string to COM1
;   Input: SI = pointer to string
serial_puts:
    push ax
    push si
.loop:
    lodsb                               ; AL = [SI], SI++
    test al, al
    jz .done
    call serial_putc
    jmp .loop
.done:
    pop si
    pop ax
    ret

; serial_hex16 — Send AX as 4-digit hex string to COM1
;   Input: AX = 16-bit value
serial_hex16:
    push cx
    push ax
    mov cx, 4
.hex_loop:
    rol ax, 4                           ; Rotate highest nibble into lowest
    push ax
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jbe .digit
    add al, 7                           ; 'A'-'9'-1 = 7
.digit:
    call serial_putc
    pop ax
    dec cx
    jnz .hex_loop
    pop ax
    pop cx
    ret

; serial_hex8 — Send AL as 2-digit hex string to COM1
;   Input: AL = 8-bit value
serial_hex8:
    push ax
    push cx
    mov cx, 2
    rol al, 4                           ; High nibble first
.hex8_loop:
    push ax
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jbe .hex8_digit
    add al, 7
.hex8_digit:
    call serial_putc
    pop ax
    rol al, 4
    dec cx
    jnz .hex8_loop
    pop cx
    pop ax
    ret

; serial_crlf — Send CR+LF to COM1
serial_crlf:
    push ax
    mov al, 13
    call serial_putc
    mov al, 10
    call serial_putc
    pop ax
    ret
```

### 3.6 The `DBG` Macro

All debug logging should go through a single macro so it can be compiled
out in release builds:

```nasm
; --- In debug.inc ---

%ifdef DEBUG

; DBG — Print a debug message to serial (compile-time string)
;   Usage:  DBG "Loading FS.BIN"
;   Output: [DBG] Loading FS.BIN\r\n    (to COM1)
;
; This macro generates an inline string constant and calls serial_puts.
; The string is embedded in the code stream with a jmp to skip over it.
%macro DBG 1
    jmp %%after
    %%msg: db '[DBG] ', %1, 13, 10, 0
%%after:
    push si
    mov si, %%msg
    call serial_puts
    pop si
%endmacro

; DBG_REG — Print a register name and its hex value to serial
;   Usage:  DBG_REG "AX", ax
;   Output: AX=1234    (to COM1, no newline)
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

; DBG_REGS — Dump all general-purpose registers to serial
;   Usage:  DBG_REGS
;   Output: AX=xxxx BX=xxxx CX=xxxx DX=xxxx SI=xxxx DI=xxxx\r\n
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
; Release build — all debug macros expand to nothing
%macro DBG 1
%endmacro
%macro DBG_REG 2
%endmacro
%macro DBG_REGS 0
%endmacro
%endif
```

### 3.7 Hyper-V COM1 Setup

COM1 is automatically configured by `setup-vm.bat` — no manual steps needed.
The setup script runs `Set-VMComPort` to map COM1 to `\\.\pipe\minios-serial`
on both new and existing VMs.

#### Reading serial output

Use the included `read-serial.bat` (requires admin):

```cmd
read-serial.bat              :: uses VM name "mini-os"
read-serial.bat my-vm        :: custom VM name
```

The script:
1. Stops the VM (if running)
2. Starts the VM fresh
3. Immediately connects to the COM1 pipe — capturing boot messages from the
   very first byte
4. Auto-reconnects on VM reboot or reset (waits up to 30 seconds)
5. Press Ctrl+C to stop

> **Note:** The Hyper-V Manager thumbnail may appear gray while
> `read-serial.bat` is connected.  The VM is running normally — open the
> console with `vmconnect localhost mini-os` (or double-click the VM in
> Hyper-V Manager) to see the display output alongside the serial log.

> **Note:** PuTTY cannot connect to Windows named pipes.  Use
> `read-serial.bat` or the PowerShell snippet below.

For manual use without the helper script:

```powershell
# Read the pipe in real-time (VM must already be running)
$pipe = [System.IO.Pipes.NamedPipeClientStream]::new(".", "minios-serial",
    [System.IO.Pipes.PipeDirection]::In)
$pipe.Connect(5000)
$reader = [System.IO.StreamReader]::new($pipe)
while (-not $reader.EndOfStream) { $reader.ReadLine() }
```

**Actual output** from a debug boot (v0.7.0):

```
[DBG] KERNEL: serial debug active       ← serial_init completed, COM1 ready
[DBG] KERNEL: INT 0x80 installed        ← syscall jump table wired into IVT
[SYS] READ_SECTOR AX=0400 BX=0983      ← FS.BIN loading directory sector
[DBG] KERNEL: FS.BIN loaded at 0x0800   ← filesystem module in memory
[DBG] KERNEL: INT 0x81 filesystem ready ← FS INT 0x81 handler installed
[DBG] KERNEL: SHELL.BIN loaded          ← shell binary loaded at 0x3000
[SYS] CLEAR_SCREEN AX=060C BX=0000     ← shell clearing screen
[SYS] PRINT_STRING AX=010C BX=0000     ← shell printing banner
[SYS] PRINT_STRING AX=010C BX=0000     ← shell printing prompt
[SYS] READ_KEY AX=030C BX=0000         ← shell waiting for keypress
```

### 3.8 Size Budget

The serial infrastructure adds code to every binary that includes it:

| Component | Size |
|-----------|------|
| `serial_init` | ~40 bytes |
| `serial_putc` | ~20 bytes |
| `serial_puts` | ~16 bytes |
| `serial_hex16` | ~30 bytes |
| `serial_hex8` | ~24 bytes |
| `serial_crlf` | ~12 bytes |
| Per `DBG` call | ~20 bytes (jmp + string + push/call/pop) |

Under `%ifdef DEBUG`, all of this exists.  In release builds, it compiles to
exactly 0 bytes.

---

## 4. Syscall Tracing

### 4.1 The Problem

When the shell calls `INT 0x80` with `AH=0x04` (read sector), the kernel's
handler executes.  If the handler receives wrong input (as happened with the
AH clobber bug), there is no record of what was passed.  By the time the
caller notices something is wrong, the original register values are lost.

### 4.2 The Solution: Named Trace on Entry

The syscall dispatcher (`syscall_handler` in kernel.asm) is the single point
through which every syscall passes.  Adding a trace here captures every call
with human-readable function names:

```nasm
syscall_handler:
    mov [cs:.sc_temp], bx               ; Save BX (existing)

%ifdef DEBUG
    ; Look up syscall name from pointer table, print:
    ;   [SYS] PRINT_STRING AX=010C BX=0000
    ; Falls back to [SYS] AH=xx for unknown function numbers.
    ;
    ; Name table: 28 dw pointers to NUL-terminated strings,
    ; indexed by AH value (0x00–0x1B).
%endif

    movzx bx, ah                        ; BX = function number (existing)
    cmp bx, SYSCALL_MAX
    ja .sc_unknown
    ; ... rest of dispatch ...
```

The name table adds ~370 bytes in debug builds (27 name strings + 28-entry
pointer table) but makes output immediately readable without a reference card.

### 4.3 Trace Output — Boot Sequence Reference

A debug build produces the following serial output during a normal boot.
Each line is explained:

```
[DBG] KERNEL: serial debug active       ← serial_init completed, COM1 ready
[DBG] KERNEL: INT 0x80 installed        ← syscall jump table wired into IVT
[SYS] READ_SECTOR AX=0400 BX=0983      ← FS.BIN loading directory sector
[DBG] KERNEL: FS.BIN loaded at 0x0800   ← filesystem module in memory
[FS]  LIST_FILES                        ← FS caching directory during init
[DBG] KERNEL: INT 0x81 filesystem ready ← FS INT 0x81 handler installed
[DBG] KERNEL: SHELL.BIN loaded          ← shell binary loaded at 0x3000
[SYS] CLEAR_SCREEN AX=060C BX=0000     ← shell clearing screen
[SYS] PRINT_STRING AX=010C BX=0000     ← shell printing banner
[SYS] PRINT_STRING AX=010C BX=0000     ← shell printing prompt
[SYS] READ_KEY AX=030C BX=0000         ← shell waiting for keypress
```

**Trace format:**

| Prefix | Source | Format | Example |
|--------|--------|--------|---------|
| `[DBG]` | `DBG` macro | `[DBG] <message>` | `[DBG] KERNEL: INT 0x80 installed` |
| `[SYS]` | INT 0x80 dispatcher | `[SYS] <NAME> AX=xxxx BX=xxxx` | `[SYS] READ_SECTOR AX=0400 BX=2000` |
| `[FS]`  | INT 0x81 dispatcher | `[FS] <NAME>` | `[FS] FIND_FILE` |

**INT 0x80 syscall name reference (AH → name):**

| AH | Name | Description |
|----|------|-------------|
| 0x01 | `PRINT_STRING` | Print NUL-terminated string at DS:SI |
| 0x02 | `PRINT_CHAR` | Print character in AL |
| 0x03 | `READ_KEY` | Wait for keypress, returns AH=scan AL=ASCII |
| 0x04 | `READ_SECTOR` | Read disk sector (EDI=LBA, ES:BX=buf, CL=count) |
| 0x05 | `GET_VERSION` | Returns AH=major, AL=minor |
| 0x06 | `CLEAR_SCREEN` | Clear display |
| 0x07 | `SET_CURSOR` | Set cursor position (DH=row, DL=col) |
| 0x08 | `GET_CURSOR` | Get cursor position |
| 0x09 | `CHECK_A20` | Returns AL=1 if A20 enabled |
| 0x0A | `GET_CONV_MEM` | Returns AX=KB conventional memory |
| 0x0B | `GET_EXT_MEM` | Returns AX=KB extended memory |
| 0x0C | `GET_E820` | BIOS memory map enumeration |
| 0x0D | `REBOOT` | Warm reboot (does not return) |
| 0x0E | `GET_DRIVE_INFO` | Returns drive geometry |
| 0x0F | `GET_BIB` | Returns ES:BX = Boot Info Block address |
| 0x10 | `PRINT_HEX8` | Print AL as 2-digit hex |
| 0x11 | `PRINT_HEX16` | Print DX as 4-digit hex |
| 0x12 | `PRINT_DEC16` | Print DX as decimal |
| 0x13 | `WAIT_KEY` | Print prompt, wait, clear screen |
| 0x14 | `GET_EQUIP` | Returns AX = BIOS equipment word |
| 0x15 | `GET_VIDEO` | Returns AL=mode, AH=cols, BH=page |
| 0x16 | `GET_BDA_BYTE` | Read byte from BDA (BX=offset) |
| 0x17 | `GET_BDA_WORD` | Read word from BDA (BX=offset) |
| 0x18 | `CPUID` | Execute CPUID (EDI=leaf) |
| 0x19 | `CHECK_CPUID` | Returns AL=1 if CPUID supported |
| 0x1A | `GET_EDD` | EDD drive info (DL=drive) |
| 0x1B | `GET_IVT` | Read IVT entry (CL=vector#) |

**INT 0x81 filesystem name reference (AH → name):**

| AH | Name | Description |
|----|------|-------------|
| 0x01 | `LIST_FILES` | Copy cached directory to ES:BX buffer |
| 0x02 | `FIND_FILE` | Search for file by 8.3 name (DS:SI) |
| 0x03 | `READ_FILE` | Read file contents into ES:BX buffer |
| 0x04 | `GET_INFO` | Return filesystem metadata |

### 4.3.1 The AH Overlap Bug — How Tracing Found It

Consider the AH overlap bug that caused FS init to fail.  The FS module calls:

```nasm
    mov eax, [partition_lba]            ; EAX = 0x00000802 (LBA 2050)
    mov ah, SYS_READ_SECTOR             ; AH = 0x04 → EAX becomes 0x00000402!
    int 0x80
```

**Without tracing:** FS init fails.  `[FAIL] FS.BIN`.  Why?  No idea.

**With tracing (serial output):**

```
[SYS] READ_SECTOR AX=0402 BX=0800
                      ^^^^
                      Expected 0802, got 0402.  AH=04 clobbered bits 8-15.
                      Bug found in seconds.
```

### 4.4 INT 0x81 (Filesystem) Tracing

The same technique applies to the FS.BIN dispatcher, with its own 4-entry
name table:

```nasm
; In fs.asm, INT 0x81 handler:
fs_handler:
%ifdef DEBUG
    ; Look up FS function name and print:
    ;   [FS] LIST_FILES
    ;   [FS] FIND_FILE
    ; Falls back to [FS] AH=xx for unknown function numbers.
%endif
    ; ... existing dispatch ...
```

### 4.5 Selective Tracing with Verbosity Levels

Full syscall tracing can be noisy (every keypress, every character printed).
A verbosity level lets you control the volume:

```nasm
; In debug.inc:
%ifdef DEBUG
    DBG_LEVEL equ 2                     ; 0=off, 1=errors only,
                                        ; 2=syscalls, 3=everything
%endif
```

Level 1 only logs when CF is set on return (errors).
Level 2 logs all syscall entries.
Level 3 adds entry AND exit (with return values).

### 4.6 How This Would Have Caught Each Bug

| Bug | What the trace would show | Time to find |
|-----|---------------------------|--------------|
| AH/LBA overlap | `[SYS] READ_SECTOR AX=0402` — expected `AX=0802` | Seconds |
| CF propagation | No `[SYS] ERROR: CF set` after failed INT 13h | Minutes |
| Print value clobber | `[SYS] PRINT_DEC16 AX=1202` — expected `AX=0002` | Seconds |

---

## 5. Assert Macros

### 5.1 Concept

An assertion is a compile-time or runtime check that says "this condition
MUST be true here — if it's not, something is fundamentally wrong and we
should stop immediately rather than continue with corrupted state."

In C:
```c
assert(magic == 0x4D4E4653);   // "MNFS"
```

In mini-os assembly, we build the same concept as macros.

### 5.2 ASSERT — General Condition Check

```nasm
; ASSERT — Halt with message if condition is false
;
; Usage:
;   ASSERT <reg>, <op>, <value>, "message"
;
; Example:
;   ASSERT ax, e, 0x4D4E, "MNFS magic mismatch (first word)"
;   → If AX != 0x4D4E, print message + dump registers + halt.
;
; The <op> maps to a conditional jump:
;   e  → je  (equal)         ne → jne (not equal)
;   b  → jb  (below/less)    a  → ja  (above/greater)
;   z  → jz  (zero)          nz → jnz (not zero)

%ifdef DEBUG
%macro ASSERT 4
    cmp %1, %3
    j%2 %%ok                            ; Jump OVER the failure path if true
    ; Assertion failed — log and halt
    jmp %%failmsg_after
    %%failmsg: db '[ASSERT FAIL] ', %4, 13, 10, 0
%%failmsg_after:
    push si
    mov si, %%failmsg
    call serial_puts                    ; Log to serial
    call puts                           ; Also print to screen
    pop si
    DBG_REGS                            ; Dump all registers to serial
    cli
    hlt
%%ok:
%endmacro
%else
%macro ASSERT 4
%endmacro
%endif
```

### 5.3 ASSERT_CF — Check Carry Flag

Many operations in mini-os signal errors via CF (carry flag).  After a disk
read or BIOS call, you want to assert that CF is clear:

```nasm
%ifdef DEBUG
%macro ASSERT_CF_CLEAR 1
    jnc %%ok
    jmp %%failmsg_after
    %%failmsg: db '[ASSERT FAIL] CF set: ', %1, 13, 10, 0
%%failmsg_after:
    push si
    mov si, %%failmsg
    call serial_puts
    call puts
    pop si
    DBG_REGS
    cli
    hlt
%%ok:
%endmacro
%else
%macro ASSERT_CF_CLEAR 1
%endmacro
%endif
```

**Usage:**

```nasm
    ; Read MNFS directory sector
    mov edi, [part_lba]
    add edi, MNFS_DIR_SECTOR
    mov ah, SYS_READ_SECTOR
    mov cl, 1
    int 0x80
    ASSERT_CF_CLEAR "Failed to read MNFS directory sector"

    ; Verify magic
    cmp dword [es:bx], 'MNFS'
    ASSERT ax, e, ax, "MNFS magic not found in directory header"
    ; (above is a trivial always-true to demonstrate; the real check is:)
    ; We need a different form for memory comparisons — see ASSERT_MEM below
```

### 5.4 ASSERT_MAGIC — Verify a 4-byte Magic Value

Magic number validation is so common in mini-os (MNOS, MNLD, MNKN, MNEX,
MNFS) that it deserves its own macro:

```nasm
%ifdef DEBUG
%macro ASSERT_MAGIC 3
    ; %1 = segment:offset of magic location (e.g., es:bx)
    ; %2 = expected 4-byte magic (e.g., 'MNFS')
    ; %3 = message string
    push eax
    mov eax, [%1]
    cmp eax, %2
    je %%ok
    ; Failed — log expected vs actual
    jmp %%failmsg_after
    %%failmsg: db '[ASSERT FAIL] Magic mismatch: ', %3, 13, 10, 0
%%failmsg_after:
    push si
    mov si, %%failmsg
    call serial_puts
    call puts
    pop si
    ; Print expected and actual
    push si
    jmp %%exp_after
    %%exp_lbl: db '  Expected: ', 0
%%exp_after:
    mov si, %%exp_lbl
    call serial_puts
    mov eax, %2
    call serial_hex16                   ; High word
    shr eax, 16
    call serial_hex16                   ; Low word
    call serial_crlf
    jmp %%act_after
    %%act_lbl: db '  Actual:   ', 0
%%act_after:
    mov si, %%act_lbl
    call serial_puts
    mov eax, [%1]
    call serial_hex16
    shr eax, 16
    call serial_hex16
    call serial_crlf
    pop si
    DBG_REGS
    pop eax
    cli
    hlt
%%ok:
    pop eax
%endmacro
%else
%macro ASSERT_MAGIC 3
%endmacro
%endif
```

**Usage (in kernel after loading FS.BIN):**

```nasm
    ; Load FS.BIN to 0x0800
    call load_mnex
    ASSERT_MAGIC es:bx, 'MNFS', "FS.BIN header"
```

### 5.5 Real-World Example: How Asserts Would Have Caught v0.6.0 Bugs

**Bug 1 — FS init reading wrong sector:**

```nasm
; In fs_init:
    mov edi, [part_lba]
    add edi, MNFS_DIR_SECTOR            ; EDI = correct LBA
    DBG_REG "EDI", edi                  ; Serial: "EDI=00000802"

    mov ah, SYS_READ_SECTOR             ; ← THIS CLOBBERS EDI... wait, no.
                                        ;    EDI is safe.  But EAX isn't.
    ; With the old ABI (EAX = LBA):
    ;   DBG_REG "EAX", eax              ; Would show "EAX=00000402" ← CAUGHT!
    int 0x80
    ASSERT_CF_CLEAR "FS: directory read failed"
    ASSERT_MAGIC es:bx, 'MNFS', "FS: directory sector"  ; ← Would fire!
```

**Bug 2 — CF not propagated:**

```nasm
; In the kernel's .fn_read_sector:
    int 0x13                            ; BIOS disk read
    ASSERT_CF_CLEAR "Disk read INT 13h failed"
    ; Even if we don't assert, the serial trace would show:
    ;   [SYS] AH=04 AX=0402 → returned with CF=1
    ; And the assert would catch it before the error propagates.
```

---

## 6. Fault Handlers

### 6.1 The Problem

When the CPU encounters an error condition (divide by zero, invalid opcode,
general protection fault), it triggers an exception through the IVT.  In
mini-os, these IVT entries still point to BIOS default handlers which
typically do nothing useful — the system silently hangs or reboots.

### 6.2 Exception Vectors

The first 32 IVT entries (INT 0x00 through INT 0x1F) are reserved for CPU
exceptions.  The most relevant ones for mini-os:

| Vector | Name | Common Cause |
|--------|------|--------------|
| 0x00 | Divide Error | `div` by zero, quotient overflow |
| 0x01 | Debug/Single Step | TF flag set (debuggers use this) |
| 0x04 | Overflow | `INTO` when OF=1 |
| 0x05 | Bound Range Exceeded | `BOUND` instruction fails |
| 0x06 | Invalid Opcode | CPU encounters undefined instruction |
| 0x08 | Double Fault | Exception during exception handling |

### 6.3 Installing Fault Handlers

Each fault handler is registered by writing to the IVT during kernel init:

```nasm
; In kernel init, after installing INT 0x80:
%ifdef DEBUG
    ; Install fault handlers into IVT
    ; IVT entry format: offset (word) + segment (word) at vector × 4
    xor ax, ax
    mov es, ax                          ; ES = 0x0000 (IVT segment)

    ; INT 0x00 — Divide Error
    mov word [es:0x00], fault_div0
    mov word [es:0x02], cs

    ; INT 0x06 — Invalid Opcode
    mov word [es:0x18], fault_ud
    mov word [es:0x1A], cs
%endif
```

### 6.4 Fault Handler Implementation

Each handler dumps the exception name, the faulting address (from the stack
frame pushed by the CPU), and all registers:

```nasm
%ifdef DEBUG

; ─── Common fault handler core ────────────────────────────────────
; Called by each specific handler after pushing the exception name.
; Stack at entry:
;   [SP+0] = return address (back to specific handler's halt)
;   [SP+2] = pointer to exception name string
;   Beneath that, the CPU's exception frame:
;     [SP+4] = faulting IP
;     [SP+6] = faulting CS
;     [SP+8] = faulting FLAGS

fault_common:
    ; Print exception banner
    push si
    mov si, .fault_banner
    call serial_puts
    call puts                           ; Also to screen
    pop si

    ; Print exception name (passed on stack)
    mov si, [sp + 2]
    call serial_puts
    call puts
    call serial_crlf

    ; Print faulting address CS:IP
    push si
    mov si, .fault_at
    call serial_puts
    call puts
    pop si

    ; CS is at [sp + 6], IP is at [sp + 4]
    mov ax, [sp + 6]                    ; Faulting CS
    call serial_hex16
    mov al, ':'
    call serial_putc
    mov ax, [sp + 4]                    ; Faulting IP
    call serial_hex16
    call serial_crlf

    ; Dump all registers
    DBG_REGS

    ; Halt
    cli
.fault_halt:
    hlt
    jmp .fault_halt

.fault_banner: db 13, 10, '*** CPU EXCEPTION: ', 0
.fault_at:     db '  Fault at CS:IP = ', 0

; ─── Specific fault handlers ─────────────────────────────────────

fault_div0:
    push .div0_name
    jmp fault_common
.div0_name: db 'DIVIDE BY ZERO (#DE, INT 0)', 13, 10, 0

fault_ud:
    push .ud_name
    jmp fault_common
.ud_name: db 'INVALID OPCODE (#UD, INT 6)', 13, 10, 0

%endif
```

### 6.5 Example Output

If the shell accidentally executes `div bx` when BX=0:

```
*** CPU EXCEPTION: DIVIDE BY ZERO (#DE, INT 0)
  Fault at CS:IP = 0000:3142
AX=0000 BX=0000 CX=0005 DX=0000 SI=3500 DI=0800
```

This immediately tells you: division by zero at shell address 0x3142.  Without
the fault handler, the system would silently reboot or hang with no indication.

---

## 7. Machine Monitor (`mnmon` Command)

### 7.1 Heritage: The Woz Monitor

In 1976, Steve Wozniak wrote the **Woz Monitor** (Wozmon) for the Apple I.
In just 256 bytes of 6502 assembly, it provided everything a developer needed
to interact with bare hardware: examine memory, write bytes, and run code.
No assembler, no OS, no file system — just a prompt and hex.

The Apple I shipped with Wozmon in ROM.  When you powered on, you saw:

```
\
```

That backslash was the entire user interface.  From there, you could:

```
FF00            ← Examine: show byte at address FF00
FF00.FF0F       ← Range:   show bytes from FF00 through FF0F
0300: A9 01     ← Deposit: write A9 then 01 starting at 0300
0300R           ← Run:     jump to address 0300 and execute
```

That's it.  Four operations.  Enough to bootstrap an entire computer.

### 7.2 Why a Monitor Instead of `dump`

A simple `dump` command is read-only — you can look but not touch.  A
monitor gives you superpowers:

| Capability | `dump` command | Wozmon-style monitor |
|------------|---------------|---------------------|
| Read memory | ✓ | ✓ |
| Read a range | ✓ | ✓ |
| Write memory | ✗ | ✓ (deposit bytes) |
| Execute code | ✗ | ✓ (run at address) |
| Patch live bugs | ✗ | ✓ (write new opcodes) |
| Test hardware | ✗ | ✓ (write to I/O-mapped memory) |
| Enter programs | ✗ | ✓ (type in machine code) |

With a monitor, you can:
- **Inspect the BIB** to verify boot_drive and partition LBA
- **Read the IVT** to confirm INT 0x80/0x81 vectors are installed correctly
- **Examine the MNFS directory** to verify file entries
- **Patch a byte** in a kernel handler to test a fix without rebuilding
- **Write a small test program** directly into unused memory and run it
- **Verify stack contents** to debug calling convention issues

### 7.3 mini-os Monitor Design: `mnmon`

Our monitor — `mnmon` (Mini-OS Monitor) — adapts Wozmon's syntax for x86-16.
It's entered via the `mnmon` shell command and has its own prompt:

```
mnos:\> mnmon

mnmon v1.0 — type ? for help, q to quit

*
```

The `*` prompt (matching Wozmon's `\` — we use `*` because it's more visible)
indicates the monitor is ready for input.

### 7.4 Command Syntax

The monitor accepts four operations, all hex-based:

#### 7.4.1 Examine — Show a Single Address

```
*0600
0600: 80
```

Type a hex address, press Enter.  The monitor displays the byte at that
address.  The **current address** advances to 0x0601, so pressing Enter
again shows the next byte:

```
*
0601: 01
*
0602: 00
```

This "sticky address" behavior lets you walk through memory by just pressing
Enter repeatedly — exactly like Wozmon.

#### 7.4.2 Range — Show a Block of Memory

```
*0600.060F
0600: 80 01 00 08 00 00 00 00 00 00 00 00 00 00 00 00
```

A period separates start and end addresses.  The monitor displays all bytes
in the range, 16 per line.  For larger ranges, the output continues with
address prefixes:

```
*0800.083F
0800: 4D 4E 46 53 01 04 17 00 FE 77 00 00 00 00 00 00
0810: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
0820: 4C 4F 41 44 45 52 20 20 42 49 4E 01 03 00 00 00
0830: 02 00 00 04 00 00 00 00 00 00 00 00 00 00 00 00
```

That's the MNFS directory header + first file entry, visible byte-by-byte.
You can read 'LOADER  BIN' at 0x0820 in the ASCII values (4C=L, 4F=O, ...).

#### 7.4.3 Deposit — Write Bytes to Memory

```
*0700: 48 65 6C 6C 6F 00
```

A colon after the address switches to deposit mode.  All subsequent hex
bytes are written starting at the given address.  In this example:

- 0x0700 ← 0x48 ('H')
- 0x0701 ← 0x65 ('e')
- 0x0702 ← 0x6C ('l')
- 0x0703 ← 0x6C ('l')
- 0x0704 ← 0x6F ('o')
- 0x0705 ← 0x00 (NUL terminator)

You can deposit on multiple lines.  After a deposit, the current address
is updated, so a bare colon continues writing:

```
*0700: 48 65 6C
*: 6C 6F 00
```

This writes the same 6 bytes — the second line continues from 0x0703.

#### 7.4.4 Run — Execute at Address

```
*0700R
```

The `R` suffix jumps to the specified address using a `call`, so if the
code at that address ends with `ret`, control returns to the monitor.

**Safety note**: Running arbitrary addresses can crash the system.  That's
expected — the monitor is a power tool, not a safe sandbox.  If the code
hangs or crashes, reboot and try again.  This is exactly how Wozniak
intended it.

#### 7.4.5 Help and Quit

```
*?           ← Show command summary
*q           ← Return to shell prompt
```

### 7.5 Full Command Reference

```
┌─────────────────────────────────────────────────────────────────┐
│                    mnmon Command Reference                      │
├─────────────┬───────────────────────────────────────────────────┤
│ Command     │ Description                                      │
├─────────────┼───────────────────────────────────────────────────┤
│ XXXX        │ Examine byte at address XXXX                     │
│ (Enter)     │ Examine next byte (auto-increment)               │
│ XXXX.YYYY   │ Show bytes from XXXX through YYYY                │
│ XXXX: BB .. │ Write bytes BB ... starting at XXXX              │
│ : BB ..     │ Continue writing from current address            │
│ XXXXR       │ Call address XXXX (ret returns to monitor)       │
│ ?           │ Show help                                        │
│ q           │ Quit monitor, return to shell                    │
└─────────────┴───────────────────────────────────────────────────┘

  XXXX = 1-4 hex digits (case-insensitive)
  BB   = 1-2 hex digits per byte
```

### 7.6 Implementation

The monitor is a self-contained routine within `shell.asm`.  It uses
only INT 0x80 syscalls (no direct BIOS calls) — true user-mode code.

#### 7.6.1 Data Structures

```nasm
; Monitor state
mon_addr:   dw 0                        ; Current address (sticky)
mon_buf:    times 80 db 0               ; Input line buffer
mon_len:    db 0                        ; Current input length
```

#### 7.6.2 Main Loop

```nasm
; ─── cmd_mon — Enter the machine monitor ─────────────────────────
cmd_mon:
    ; Print banner
    mov ah, SYS_PRINT_STRING
    mov si, .mon_banner
    int 0x80

.mon_loop:
    ; Print prompt
    mov ah, SYS_PRINT_CHAR
    mov al, '*'
    int 0x80

    ; Read a line of input into mon_buf
    call mon_readline                   ; Returns: mon_buf filled, CX = length

    ; Empty line → examine next byte (auto-increment)
    test cx, cx
    jz .mon_next_byte

    ; Parse the line
    mov si, mon_buf

    ; Check for '?' (help)
    cmp byte [si], '?'
    je .mon_help

    ; Check for 'q' (quit)
    cmp byte [si], 'q'
    je .mon_quit

    ; Check for ':' at start (continue deposit)
    cmp byte [si], ':'
    je .mon_cont_deposit

    ; Must start with a hex digit — parse address
    call parse_hex16                    ; AX = address, SI advanced
    mov [mon_addr], ax                  ; Update current address

    ; What follows the address?
    cmp byte [si], 0                    ; End of line → examine
    je .mon_examine

    cmp byte [si], '.'                  ; Period → range examine
    je .mon_range

    cmp byte [si], ':'                  ; Colon → deposit
    je .mon_deposit

    ; Check for 'R' or 'r' (run)
    mov al, [si]
    or al, 0x20                         ; To lowercase
    cmp al, 'r'
    je .mon_run

    ; Unknown syntax — show error
    mov ah, SYS_PRINT_STRING
    mov si, .mon_err
    int 0x80
    jmp .mon_loop

; ─── Examine single byte ────────────────────────────────────────
.mon_examine:
    call mon_show_addr                  ; Print "XXXX: "
    mov di, [mon_addr]
    mov al, [di]
    mov ah, SYS_PRINT_HEX8
    int 0x80
    call mon_newline
    inc word [mon_addr]                 ; Auto-increment
    jmp .mon_loop

; ─── Examine next byte (Enter on empty line) ────────────────────
.mon_next_byte:
    jmp .mon_examine

; ─── Range examine ──────────────────────────────────────────────
.mon_range:
    inc si                              ; Skip '.'
    call parse_hex16                    ; AX = end address
    mov bx, ax                          ; BX = end address
    mov di, [mon_addr]                  ; DI = start address

.mon_range_line:
    ; Print address prefix
    mov dx, di
    mov ah, SYS_PRINT_HEX16
    int 0x80
    mov ah, SYS_PRINT_CHAR
    mov al, ':'
    int 0x80

    ; Print up to 16 bytes per line
    mov cx, 16
.mon_range_byte:
    cmp di, bx
    ja .mon_range_done                  ; Past end address

    mov ah, SYS_PRINT_CHAR
    mov al, ' '
    int 0x80

    mov al, [di]
    mov ah, SYS_PRINT_HEX8
    int 0x80

    inc di
    dec cx
    jnz .mon_range_byte

    call mon_newline
    jmp .mon_range_line

.mon_range_done:
    call mon_newline
    mov [mon_addr], di                  ; Update current address
    jmp .mon_loop

; ─── Deposit bytes ──────────────────────────────────────────────
.mon_deposit:
    inc si                              ; Skip ':'
    mov di, [mon_addr]

.mon_dep_loop:
    ; Skip spaces
    call mon_skip_spaces
    cmp byte [si], 0                    ; End of line?
    je .mon_dep_done

    ; Parse hex byte (1-2 hex digits)
    call parse_hex8                     ; AL = byte value
    mov [di], al                        ; Write to memory
    inc di
    jmp .mon_dep_loop

.mon_dep_done:
    mov [mon_addr], di                  ; Update current address
    jmp .mon_loop

; ─── Continue deposit (line starts with ':') ────────────────────
.mon_cont_deposit:
    jmp .mon_deposit                    ; mon_addr already set from last deposit

; ─── Run at address ─────────────────────────────────────────────
.mon_run:
    mov ax, [mon_addr]
    ; We use an indirect call so 'ret' returns to us
    mov [.mon_run_addr], ax
    call far [.mon_run_addr]            ; Far call to address
                                        ; (if code does 'ret', we continue here)
    jmp .mon_loop

.mon_run_addr:
    dw 0                                ; Offset (filled at runtime)
    dw 0x0000                           ; Segment (always 0 for flat real mode)

; ─── Help ───────────────────────────────────────────────────────
.mon_help:
    mov ah, SYS_PRINT_STRING
    mov si, .mon_help_text
    int 0x80
    jmp .mon_loop

; ─── Quit ───────────────────────────────────────────────────────
.mon_quit:
    call mon_newline
    ret                                 ; Return to shell command loop

; ─── Helpers ────────────────────────────────────────────────────

mon_show_addr:
    mov dx, [mon_addr]
    mov ah, SYS_PRINT_HEX16
    int 0x80
    mov ah, SYS_PRINT_STRING
    mov si, .mon_colon_sp
    int 0x80
    ret

mon_newline:
    mov ah, SYS_PRINT_STRING
    mov si, .mon_crlf
    int 0x80
    ret

mon_skip_spaces:
.mss_loop:
    cmp byte [si], ' '
    jne .mss_done
    inc si
    jmp .mss_loop
.mss_done:
    ret

; ─── parse_hex8 — Parse 1-2 hex digits into AL ─────────────────
;   Input:  SI = pointer to hex chars
;   Output: AL = byte value, SI advanced past digits
parse_hex8:
    push bx
    xor ax, ax
    ; First digit (required)
    call .ph8_digit
    jc .ph8_done                        ; Not a hex digit — return 0
    mov al, bl
    ; Second digit (optional)
    call .ph8_digit
    jc .ph8_done                        ; Only one digit
    shl al, 4
    or al, bl
.ph8_done:
    pop bx
    ret

.ph8_digit:
    movzx bx, byte [si]
    cmp bl, '0'
    jb .ph8_not_hex
    cmp bl, '9'
    jbe .ph8_d09
    or bl, 0x20                         ; lowercase
    cmp bl, 'a'
    jb .ph8_not_hex
    cmp bl, 'f'
    ja .ph8_not_hex
    sub bl, 'a' - 10
    inc si
    clc
    ret
.ph8_d09:
    sub bl, '0'
    inc si
    clc
    ret
.ph8_not_hex:
    stc
    ret

; ─── parse_hex16 — Parse 1-4 hex digits into AX ────────────────
;   Input:  SI = pointer to hex chars
;   Output: AX = 16-bit value, SI advanced past digits
parse_hex16:
    xor ax, ax
    push bx
.ph16_loop:
    movzx bx, byte [si]
    cmp bl, '0'
    jb .ph16_done
    cmp bl, '9'
    jbe .ph16_d09
    or bl, 0x20                         ; lowercase
    cmp bl, 'a'
    jb .ph16_done
    cmp bl, 'f'
    ja .ph16_done
    sub bl, 'a' - 10
    jmp .ph16_add
.ph16_d09:
    sub bl, '0'
.ph16_add:
    shl ax, 4
    or al, bl
    inc si
    jmp .ph16_loop
.ph16_done:
    pop bx
    ret

; ─── String constants ───────────────────────────────────────────

.mon_banner:
    db 13, 10, 'mnmon v1.0', 13, 10
    db 'Type ? for help, q to quit', 13, 10, 13, 10, 0

.mon_help_text:
    db 'Commands:', 13, 10
    db '  XXXX        Examine byte at address', 13, 10
    db '  (Enter)     Show next byte', 13, 10
    db '  XXXX.YYYY   Show range of bytes', 13, 10
    db '  XXXX: BB .. Write bytes at address', 13, 10
    db '  : BB ..     Continue writing', 13, 10
    db '  XXXXR       Run code at address', 13, 10
    db '  q           Quit to shell', 13, 10, 0

.mon_err:       db '?', 13, 10, 0      ; Classic monitor error: just '?'
.mon_colon_sp:  db ': ', 0
.mon_crlf:      db 13, 10, 0
```

#### 7.6.3 Monitor Input Routine

The monitor needs its own readline that's simpler than the shell's — no
auto-lowercase (hex addresses are case-insensitive, but we need uppercase
for 'R'):

```nasm
; ─── mon_readline — Read a line into mon_buf ────────────────────
;   Output: mon_buf filled, CX = character count
;   Handles: printable chars, backspace, Enter
mon_readline:
    xor cx, cx                          ; CX = character count
    mov di, mon_buf

.mrl_key:
    mov ah, SYS_READ_KEY
    int 0x80                            ; AL = ASCII character

    ; Enter → done
    cmp al, 13
    je .mrl_done

    ; Backspace
    cmp al, 8
    je .mrl_bs

    ; Printable character (buffer full?)
    cmp cx, 78                          ; Max line length
    jae .mrl_key                        ; Ignore if full

    ; Store and echo
    mov [di], al
    inc di
    inc cx
    mov ah, SYS_PRINT_CHAR
    int 0x80
    jmp .mrl_key

.mrl_bs:
    test cx, cx
    jz .mrl_key                         ; Nothing to delete
    dec di
    dec cx
    ; Erase on screen: backspace + space + backspace
    mov ah, SYS_PRINT_CHAR
    mov al, 8
    int 0x80
    mov al, ' '
    int 0x80
    mov al, 8
    int 0x80
    jmp .mrl_key

.mrl_done:
    mov byte [di], 0                    ; NUL-terminate
    call mon_newline                    ; Echo newline
    ret
```

### 7.7 Complete Interactive Session Example

Here's a realistic debugging session using `mnmon` to diagnose the AH
overlap bug that we hit during v0.6.0 development:

```
mnos:\> mnmon

mnmon v1.0
Type ? for help, q to quit

*0600.060F
0600: 80 01 00 08 00 00 00 00 00 00 00 00 00 00 00 00
                                        ← BIB: drive=0x80, A20=yes,
                                           part_lBA=0x00000800 (LE)

*0200.0207
0200: 78 50 00 00 00 00 00 00
                                        ← IVT[0x80]: handler at 0000:5078
                                           (kernel syscall_handler)

*0204.0207
0204: 78 08 00 00
                                        ← IVT[0x81]: handler at 0000:0878
                                           (FS.BIN fs_handler)

*0800.081F
0800: 4D 4E 46 53 01 04 17 00 FE 77 00 00 00 00 00 00
0810: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
                                        ← MNFS directory header:
                                           Magic='MNFS', ver=1, 4 files,
                                           23 sectors used, 30718 capacity

*0820.085F
0820: 4C 4F 41 44 45 52 20 20 42 49 4E 01 03 00 00 00
0830: 02 00 00 04 00 00 00 00 00 00 00 00 00 00 00 00
0840: 46 53 20 20 20 20 20 20 42 49 4E 01 05 00 00 00
0850: 02 00 00 04 00 00 00 00 00 00 00 00 00 00 00 00
                                        ← Entry 0: "LOADER  BIN" sector 3
                                           Entry 1: "FS      BIN" sector 5

Now let's enter a tiny test program at an unused address and run it.
This program prints 'X' to the screen and returns:

*0700: B4 02 B0 58 CD 80 C3
                                        ← Deposited 7 bytes:
                                           B4 02     mov ah, 0x02 (PRINT_CHAR)
                                           B0 58     mov al, 'X'  (0x58)
                                           CD 80     int 0x80
                                           C3        ret

*0700.0706
0700: B4 02 B0 58 CD 80 C3
                                        ← Verify: bytes are correct

*0700R
X                                       ← It printed 'X' and returned!

*q

mnos:\>
```

### 7.8 Safety Considerations

The monitor gives you unrestricted memory access.  This is intentional —
it's a debugging tool, not a user application.  Some things to be aware of:

| Action | Risk | Result |
|--------|------|--------|
| Write to IVT (0x0000-0x03FF) | Redirects interrupts | System may hang |
| Write to kernel (0x5000+) | Corrupts syscall handlers | Undefined behavior |
| Write to VGA (0xB8000+) | Modifies display directly | Garbled screen |
| Run at random address | Executes unknown code | Crash, hang, or reboot |
| Write to BIB (0x0600) | Changes boot parameters | Future disk I/O may fail |

**Recovery**: If the monitor crashes the system, just reboot.  No persistent
damage can occur — all changes are in RAM only.  The disk image is read-only
after boot.

### 7.9 Educational Value

The Wozmon-style monitor is not just a debugging tool — it's a teaching
instrument.  It demonstrates:

1. **Memory-mapped I/O** — students can read the IVT, BDA, VGA memory
2. **Machine code** — deposit and run raw opcodes, see exactly what the
   CPU executes
3. **Data structures in memory** — browse the MNFS directory, BIB, stack
4. **How an OS organizes memory** — walk from 0x0000 to 0xFFFFF and see
   what's where
5. **Historical computing** — this is how all programs were entered in the
   1970s, before assemblers and editors existed

### 7.10 Size Budget

The monitor is compact — true to Wozmon's spirit:

| Component | Size |
|-----------|------|
| Main loop + dispatch | ~120 bytes |
| Examine + range | ~80 bytes |
| Deposit | ~60 bytes |
| Run | ~20 bytes |
| parse_hex16 + parse_hex8 | ~80 bytes |
| mon_readline | ~60 bytes |
| String constants | ~200 bytes |
| **Total** | **~620 bytes** |

Wozniak's original was 256 bytes on the 6502.  Our x86 version is larger
(x86 instructions are longer, we have more features, and we include help
text), but still fits comfortably within SHELL.BIN's growth room.

### 7.11 Always-On vs Debug-Only

**Recommended: Always available.**

The monitor is not conditional (`%ifdef DEBUG`).  Reasons:

1. It's educational — the whole point of mini-os is learning
2. It's useful in release builds — inspect memory without rebuilding
3. It's compact (~620 bytes) — well within the shell's 2 KB growth room
4. Wozmon was in ROM — always available on every Apple I, no opt-in needed

The only debug-only addition would be optional serial echo: in debug builds,
all monitor I/O is also logged to COM1 for capture.

---

## 8. Debug Build Mode

### 8.1 The `%ifdef DEBUG` Pattern

All debugging facilities are conditionally assembled.  The build system
controls whether `DEBUG` is defined:

```nasm
; In build.ps1, when assembling any binary:
if ($DebugBuild) {
    $nasmFlags += '-dDEBUG'             ; -d defines a preprocessor symbol
}
```

This passes `-dDEBUG` to NASM, which is equivalent to writing `%define DEBUG`
at the top of every source file.

### 8.2 Build System Integration

```powershell
# tools/build.ps1 — uses -DebugBuild switch
# (can't use -Debug — conflicts with CmdletBinding common parameter)
param(
    [switch]$DebugBuild
)

# Build each binary with optional DEBUG define
function Build-Binary {
    param([string]$Source, [string]$Output)

    $flags = @('-f', 'bin', '-I', 'src/include/', '-o', $Output, $Source)
    if ($DebugBuild) {
        $flags = @('-dDEBUG') + $flags
        Write-Host "[mini-os] DEBUG build: $Source"
    }
    & $NasmPath @flags
}
```

```batch
:: build.bat — /debug option
@echo off
if "%1"=="/debug" (
    pwsh -ExecutionPolicy Bypass -File tools\build.ps1 -DebugBuild
) else (
    pwsh -ExecutionPolicy Bypass -File tools\build.ps1
)
```

Output files are named separately so both VHDs can coexist:

| Build | Raw image | VHD |
|-------|-----------|-----|
| Release | `build/boot/mini-os.img` | `build/boot/mini-os.vhd` |
| Debug | `build/boot/mini-os-debug.img` | `build/boot/mini-os-debug.vhd` |

`setup-vm.bat` prompts which VHD to attach when both are present.

### 8.3 What Each Mode Includes

| Facility | `build.bat` (release) | `build.bat /debug` |
|----------|----------------------|-------------------|
| Serial init + putc/puts | ✗ | ✓ |
| `DBG` macros | ✗ (expand to nothing) | ✓ |
| Syscall tracing | ✗ | ✓ |
| Assert macros | ✗ (expand to nothing) | ✓ |
| Fault handlers | ✗ | ✓ |
| Stack canary | ✗ | ✓ |
| `mnmon` command (monitor) | ✓ (always on) | ✓ |
| Boot messages `[OK]/[FAIL]` | ✓ (always on) | ✓ |
| Register dump on `[FAIL]` | ✓ (always on) | ✓ |

Boot messages are NOT conditional — they're lightweight and valuable in all
builds.  Only the heavy instrumentation is debug-only.

### 8.4 Binary Size Impact

Measured size increase with DEBUG enabled (v0.7.0):

| Binary | Release | Debug | Increase | Max region |
|--------|---------|-------|----------|------------|
| LOADER.BIN | 1 KB (2 sec) | 1 KB (2 sec) | 0 B (no debug instrumentation yet) | 8 KB |
| FS.BIN | 1 KB (2 sec) | 1.5 KB (3 sec) | +512 B (serial funcs + FS tracing) | 8 KB |
| KERNEL.BIN | 3 KB (6 sec) | 3.5 KB (7 sec) | +512 B (serial funcs + boot DBGs + syscall tracing) | 8 KB |
| SHELL.BIN | 6 KB (12 sec) | 6 KB (12 sec) | 0 B (no debug instrumentation yet) | 8 KB |

All binaries remain well within their 8 KB maximum allocation.  The sector
counts in each binary's header are conditional (`%ifdef DEBUG`), so the loader
and kernel read the correct size at runtime.

### 8.5 Memory Layout: Identical Across Build Types

**Important**: The runtime memory layout is the same for release and debug
builds.  Every component loads at its hardcoded address regardless of build
type:

```
Component    Load address    Release size    Debug size     Region end
─────────────────────────────────────────────────────────────────────
FS.BIN       0x0800          1 KB (2 sec)    1.5 KB (3 sec) 0x27FF (8 KB max)
SHELL.BIN    0x3000          6 KB (12 sec)   6 KB (12 sec)  0x4FFF (8 KB max)
KERNEL.BIN   0x5000          3 KB (6 sec)    3.5 KB (7 sec) 0x6FFF (8 KB max)
```

The addresses are compile-time constants in `src/include/memory.inc` and set
via `ORG` directives — they never change.  Debug builds simply use more space
**within** each pre-allocated region.  No regions overlap, and ample growth
room remains.

What **does** differ is the **disk layout**.  The MNFS directory records
different sector counts for debug binaries, so files are packed at different
disk offsets:

```
                Release disk layout              Debug disk layout
Sector 2048:    VBR (2 sec)                      VBR (2 sec)
Sector 2050:    MNFS directory                   MNFS directory
Sector 2051:    LOADER.BIN (2 sec)               LOADER.BIN (2 sec)
Sector 2053:    FS.BIN (2 sec)                   FS.BIN (3 sec)
Sector 2055:    KERNEL.BIN (6 sec)               Sector 2056: KERNEL.BIN (7 sec)
Sector 2061:    SHELL.BIN (12 sec)               Sector 2063: SHELL.BIN (12 sec)
                23 total sectors                 25 total sectors
```

This is handled automatically by the build pipeline — `create-disk.ps1` reads
each binary's size and packs them contiguously.  The loader and kernel look up
file locations from the MNFS directory at runtime, so the different disk
offsets are transparent.

---

## 9. Stack Canary

### 9.1 The Problem

The mini-os stack starts at 0x7C00 and grows downward.  The stack zone
extends to approximately 0x7000 (3 KB).  Below that is the kernel at
0x5000–0x5BFF.  If a bug causes excessive stack usage (deep recursion,
large local buffers), the stack silently overwrites kernel code or data.

### 9.2 The Canary

A **stack canary** is a known magic value written to the bottom of the stack
zone.  Periodically, we check if it's been overwritten:

```nasm
STACK_CANARY_ADDR   equ 0x7000         ; Bottom of stack zone
STACK_CANARY_VALUE  equ 0xDEAD         ; Arbitrary recognizable value

; ─── canary_init — Plant the stack canary ────────────────────────
;   Call once during kernel init.
%ifdef DEBUG
canary_init:
    mov word [STACK_CANARY_ADDR], STACK_CANARY_VALUE
    mov word [STACK_CANARY_ADDR + 2], STACK_CANARY_VALUE
    ret

; ─── canary_check — Verify the stack canary is intact ────────────
;   Call periodically (e.g., on every syscall return, or in shell loop).
;   If the canary is dead, the stack has overflowed.
canary_check:
    cmp word [STACK_CANARY_ADDR], STACK_CANARY_VALUE
    jne .canary_dead
    cmp word [STACK_CANARY_ADDR + 2], STACK_CANARY_VALUE
    jne .canary_dead
    ret

.canary_dead:
    ; Stack overflow detected!
    push si
    mov si, .canary_msg
    call serial_puts
    call puts                           ; Also to screen
    pop si
    DBG_REGS
    cli
.canary_halt:
    hlt
    jmp .canary_halt

.canary_msg: db 13, 10, '*** STACK OVERFLOW: canary at 0x7000 destroyed!', 13, 10, 0
%endif
```

### 9.3 When to Check

The canary is checked at low-overhead points:

1. **Every syscall return** — add `call canary_check` just before `iret` or
   `syscall_ret_cf` in the kernel dispatcher.  This catches overflow during
   any syscall handler.

2. **Every shell command loop iteration** — the shell's main loop calls
   `canary_check` before prompting for the next command.

3. **Never in tight loops** — don't check inside `serial_putc` or `puts`.
   The overhead would be excessive and the check is unnecessary for leaf
   functions.

### 9.4 Canary Layout

```
0x6FFE  ┌──────────────┐
        │ 0xDEAD       │  ← canary word 1 (first to be overwritten)
0x7000  ├──────────────┤
        │ 0xDEAD       │  ← canary word 2
0x7002  ├──────────────┤
        │              │
        │  Stack zone  │  ← SP grows downward from 0x7BFF
        │  (3 KB)      │
        │              │
0x7C00  └──────────────┘  ← Initial SP
```

If the stack grows past 0x7000, it overwrites 0xDEAD with stack data.
The next `canary_check` call detects this and halts with a diagnostic.

---

## 10. Implementation Plan

### 10.1 File Organization

```
src/include/
├── debug.inc           ← NEW: DBG, DBG_REG, DBG_REGS, ASSERT macros
├── serial.inc          ← NEW: serial_init, serial_putc, serial_puts,
│                              serial_hex8, serial_hex16, serial_crlf
├── syscalls.inc        (existing — add SYS_* for new debug syscalls if any)
├── bib.inc             (existing)
├── memory.inc          (existing)
├── mnfs.inc            (existing)
├── find_file.inc       (existing)
├── load_binary.inc     (existing)
└── boot_msg.inc        (existing — may be updated to use serial for [FAIL])
```

### 10.2 Integration Points

| Binary | Changes |
|--------|---------|
| LOADER | `%include "serial.inc"` + `%include "debug.inc"` + call `serial_init` early + add DBG calls |
| KERNEL | `%include "serial.inc"` + `%include "debug.inc"` + syscall tracing in dispatcher + fault handlers + canary_init |
| FS.BIN | `%include "debug.inc"` (serial funcs from kernel via far call or duplicated) + DBG/ASSERT calls |
| SHELL | `%include "debug.inc"` + `mnmon` command (always-on) + canary_check in main loop |

### 10.3 Implementation Status

| # | Item | Status |
|---|------|--------|
| 1 | `serial.inc` — serial port init + putc/puts/hex | ✅ Done (v0.7.0) |
| 2 | `debug.inc` — DBG, DBG_REG, DBG_REGS macros | ✅ Done (v0.7.0) |
| 3 | Build system — `build.bat /debug` and `-dDEBUG` flag | ✅ Done (v0.7.0) |
| 4 | Kernel syscall tracing — named trace in `syscall_handler` | ✅ Done (v0.7.0) |
| 5 | FS tracing — named trace in `fs_syscall_handler` | ✅ Done (v0.7.0) |
| 6 | Hyper-V COM1 setup — `setup-vm.ps1` + `read-serial.bat` | ✅ Done (v0.7.0) |
| 7 | Separate VHDs — `mini-os.vhd` + `mini-os-debug.vhd` | ✅ Done (v0.7.0) |
| 8 | Assert macros — ASSERT, ASSERT_MAGIC, ASSERT_CF_CLEAR | 📋 Future |
| 9 | Fault handlers — INT 0 (div-by-zero), INT 6 (invalid opcode) | 📋 Future |
| 10 | Stack canary — canary_init in kernel, canary_check in dispatcher | 📋 Future |
| 11 | `mnmon` command — Wozmon-style machine monitor in shell | 📋 Future |

### 10.4 Backwards Compatibility

- **Release builds are unchanged** — without `-dDEBUG`, every macro expands
  to nothing.  Binary sizes, memory layout, and behavior are identical.
- **No new syscalls required** — all debug infrastructure is kernel-internal
  (serial port I/O is direct, not via INT 0x80).
- **`mnmon` command** is always-available (not conditional on DEBUG).  It's a
  learning tool in the Wozmon tradition and adds ~620 bytes to the shell.

---

## 11. Hyper-V Serial Debugging Walkthrough

### 11.1 VM Setup

COM1 is automatically configured by `setup-vm.bat`.  No manual steps needed.

### 11.2 Capture Session

Use `read-serial.bat` — it manages the entire lifecycle:

```cmd
:: Build debug VHD, set up VM (first time), then capture serial:
build.bat /debug
setup-vm.bat          :: select "debug" when prompted for VHD variant
read-serial.bat       :: stops VM, restarts, captures from first byte
```

The reader auto-reconnects on VM reboot/reset.  Press Ctrl+C to stop.

Open the VM console separately to see display output:
```cmd
vmconnect localhost mini-os
```

### 11.3 Actual Debug Output (v0.7.0)

```
[DBG] KERNEL: serial debug active       ← serial_init completed, COM1 ready
[DBG] KERNEL: INT 0x80 installed        ← syscall jump table wired into IVT
[SYS] READ_SECTOR AX=0400 BX=0983      ← FS.BIN loading directory sector
[DBG] KERNEL: FS.BIN loaded at 0x0800   ← filesystem module in memory
[DBG] KERNEL: INT 0x81 filesystem ready ← FS INT 0x81 handler installed
[DBG] KERNEL: SHELL.BIN loaded          ← shell binary loaded at 0x3000
[SYS] CLEAR_SCREEN AX=060C BX=0000     ← shell clearing screen
[SYS] PRINT_STRING AX=010C BX=0000     ← shell printing banner
[SYS] PRINT_STRING AX=010C BX=0000     ← shell printing prompt
[SYS] READ_KEY AX=030C BX=0000         ← shell waiting for keypress
```

---

## 12. Future Extensions

These are not planned for v0.7.0 but would be natural additions later:

| Feature | Description |
|---------|-------------|
| **Breakpoint (INT 3)** | Single-byte `0xCC` instruction, handler dumps state + waits for keypress to continue |
| **Single-step mode** | Set TF (trap flag) to trace one instruction at a time |
| **Watchpoint** | Monitor a memory address for changes (check on every syscall) |
| **Ring buffer** | Keep last N debug messages in memory; dump on fault |
| **GDB stub** | Implement the GDB remote protocol over serial for source-level debugging |
| **Memory map command** | Display the live memory map (which regions are in use) |
| **I/O port dump** | Read and display UART, PIC, PIT, keyboard controller registers |
