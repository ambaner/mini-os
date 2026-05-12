; =============================================================================
; syscalls.inc — INT 0x80 syscall function numbers
;
; These constants define the function numbers passed in AH before executing
; INT 0x80.  The kernel dispatches based on AH and performs the actual
; BIOS/hardware access on behalf of user-mode code.
;
; Convention (16-bit real mode):
;   AH = function number (from this file)
;   Other registers = function-specific arguments (see doc/SYSTEM-CALLS.md)
;   Return: function-specific (typically AX = result, CF = error)
;
; IMPORTANT: These numbers are a STABLE ABI.  Once assigned, a number never
; changes.  New syscalls are appended at the end.  See SYSTEM-CALLS.md §7.3.
; =============================================================================

SYS_PRINT_STRING  equ 0x01          ; DS:SI = NUL-terminated string
SYS_PRINT_CHAR    equ 0x02          ; AL = character to print
SYS_READ_KEY      equ 0x03          ; Returns: AH=scancode, AL=ASCII
SYS_READ_SECTOR   equ 0x04          ; EDI=LBA, ES:BX=buffer, CL=count
SYS_GET_VERSION   equ 0x05          ; Returns: AH=major, AL=minor
SYS_CLEAR_SCREEN  equ 0x06          ; No arguments
SYS_SET_CURSOR    equ 0x07          ; DH=row, DL=column
SYS_GET_CURSOR    equ 0x08          ; Returns: DH=row, DL=col
SYS_CHECK_A20     equ 0x09          ; Returns: AL=1 if enabled, 0 if not
SYS_GET_CONV_MEM  equ 0x0A          ; Returns: AX=KB of conventional memory
SYS_GET_EXT_MEM   equ 0x0B          ; Returns: AX=KB of extended, CF=error
SYS_GET_E820      equ 0x0C          ; EBX=continuation, ES:DI=buf
SYS_REBOOT        equ 0x0D          ; Warm reboot (does not return)
SYS_GET_DRIVE_INFO equ 0x0E         ; Returns: drive geometry, CF=error
SYS_GET_BIB       equ 0x0F          ; Returns: ES:BX = BIB address
SYS_PRINT_HEX8    equ 0x10          ; AL = byte to print as hex
SYS_PRINT_HEX16   equ 0x11          ; DX = word to print as hex
SYS_PRINT_DEC16   equ 0x12          ; DX = word to print as decimal
SYS_WAIT_KEY      equ 0x13          ; Print prompt, wait, clear screen
SYS_GET_EQUIP     equ 0x14          ; Returns: AX = equipment word
SYS_GET_VIDEO     equ 0x15          ; Returns: AL=mode, AH=cols, BH=page
SYS_GET_BDA_BYTE  equ 0x16          ; BX=BDA offset; Returns: AL=byte
SYS_GET_BDA_WORD  equ 0x17          ; BX=BDA offset; Returns: AX=word
SYS_CPUID         equ 0x18          ; EDI=leaf; Returns: EAX,EBX,ECX,EDX
SYS_CHECK_CPUID   equ 0x19          ; Returns: AL=1 if supported
SYS_GET_EDD       equ 0x1A          ; DL=drive; Returns: EDD info, CF=err
SYS_GET_IVT       equ 0x1B          ; CL=vector#; Returns: AX=off, DX=seg

SYSCALL_MAX       equ 0x1B          ; Highest valid syscall number
