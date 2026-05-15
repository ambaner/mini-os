; =============================================================================
; Mini-OS Filesystem Module (FS.SYS) - MNFS Driver
;
; Loaded by KERNEL.SYS into memory at 0x0800 (reusing LOADER.SYS's slot).
; Provides filesystem services via INT 0x81 — fully decoupled from the
; kernel's INT 0x80 interface.
;
; FS.SYS uses the kernel's INT 0x80 SYS_READ_SECTOR for disk I/O, creating
; a clean layered architecture:
;   User mode (SHELL)  →  INT 0x81  →  FS.SYS  →  INT 0x80  →  KERNEL  →  BIOS
;
; Initialization:
;   The kernel calls our init entry point (offset 6) after loading.
;   Init installs INT 0x81 in the IVT and caches the MNFS directory.
;
; Header layout (first 6 bytes):
;   Offset 0: 'MNFS'   Magic identifier (4 bytes)
;   Offset 4: dw N     Module size in sectors
;
; INT 0x81 functions (AH = function number):
;   0x01  FS_LIST_FILES  — Copy cached directory to caller's buffer
;   0x02  FS_FIND_FILE   — Search for file by 8.3 name
;   0x03  FS_READ_FILE   — Read file contents into buffer
;   0x04  FS_GET_INFO    — Return filesystem metadata
;
; See doc/FILESYSTEM.md for the complete specification.
;
; Assembled with:  nasm -f bin -o fs.sys src/fs/fs.asm
; =============================================================================

%include "bib.inc"
%include "mnfs.inc"
%include "syscalls.inc"
%include "debug.inc"

[BITS 16]
[ORG 0x0800]                        ; Loaded at LOADER's old address

; =============================================================================
; FS.SYS HEADER
; =============================================================================
fs_magic        db 'MNFS'           ; Magic identifier — filesystem module
%ifdef DEBUG
fs_sectors      dw 4                ; Module size in sectors (debug build)
%else
fs_sectors      dw 2                ; Module size in sectors (release build)
%endif

; =============================================================================
; fs_init — Initialize the filesystem module
;
; Called by the kernel after loading FS.SYS into memory.
;   1. Installs INT 0x81 handler in the IVT
;   2. Reads the MNFS directory via INT 0x80 SYS_READ_SECTOR
;   3. Validates the directory magic
;   4. Caches the directory data internally
;
; Input:  none
; Output: CF clear = success, CF set = error
; Clobbers: AX, CX
; =============================================================================
fs_init:
    ; --- Install INT 0x81 handler in the IVT ---------------------------------
    cli                             ; Disable interrupts while modifying IVT
    push es

    xor ax, ax
    mov es, ax                      ; ES = 0x0000 (IVT segment)

    ; Vector 0x81 is at address 0x81 * 4 = 0x0204
    mov word [es:0x81*4],   fs_syscall_handler  ; Offset
    mov word [es:0x81*4+2], cs                   ; Segment

    pop es
    sti                             ; Re-enable interrupts

    ; --- Read MNFS directory sector via kernel's SYS_READ_SECTOR -------------
    ; The directory is at partition sector MNFS_DIR_SECTOR.  We need the
    ; absolute LBA = partition_lba + MNFS_DIR_SECTOR.
    mov edi, [BIB_PART_LBA]
    add edi, MNFS_DIR_SECTOR        ; EDI = absolute LBA of directory

    push ds
    pop es                          ; ES = DS (our segment)
    mov bx, dir_cache               ; ES:BX → our internal cache buffer
    mov cl, MNFS_DIR_SECTORS        ; Read 1 sector

    mov ah, SYS_READ_SECTOR         ; Kernel syscall for disk read
    int 0x80
    jc .init_fail                   ; Disk read error
    ASSERT_CF_CLEAR "FS directory sector read failed"

    ; --- Validate MNFS magic in the cached directory -------------------------
    cmp dword [dir_cache], MNFS_MAGIC
    jne .init_fail
    ASSERT_MAGIC dir_cache, MNFS_MAGIC, "MNFS directory magic mismatch"

    ; --- Cache the file count for quick access --------------------------------
    mov al, [dir_cache + MNFS_HDR_COUNT]
    mov [cached_count], al

    ; --- Success -------------------------------------------------------------
    clc
    ret

.init_fail:
    stc
    ret

; =============================================================================
; fs_syscall_handler — INT 0x81 dispatcher
;
; Dispatches filesystem syscalls based on AH function number.
; All functions operate on the cached directory data (no disk reads
; needed except FS_READ_FILE which reads file contents).
; =============================================================================
fs_syscall_handler:
%ifdef DEBUG
    inc byte [cs:BIB_INT_DEPTH]        ; Track total INT nesting (shared counter)
    push si
    push ax
    push bx

    mov si, .fs_trace_pfx           ; "[FS] "
    call serial_puts

    movzx bx, ah
    cmp bx, 4
    ja .fs_trace_noname
    shl bx, 1
    mov si, [cs:.fs_name_table + bx]
    test si, si
    jz .fs_trace_noname
    call serial_puts
    jmp .fs_trace_done

.fs_trace_noname:
    mov si, .fs_trace_ah            ; "AH="
    call serial_puts
    mov al, ah
    call serial_hex8

.fs_trace_done:
    call serial_crlf
    pop bx
    pop ax
    pop si
%endif

    cmp ah, FS_LIST_FILES
    je .fn_list_files
    cmp ah, FS_FIND_FILE
    je .fn_find_file
    cmp ah, FS_READ_FILE
    je .fn_read_file
    cmp ah, FS_GET_INFO
    je .fn_get_info

    ; Unknown function
    jmp fs_iret_cf_set

%ifdef DEBUG
.fs_trace_pfx: db '[FS] ', 0
.fs_trace_ah:  db 'AH=', 0
.fsn_01: db 'LIST_FILES', 0
.fsn_02: db 'FIND_FILE', 0
.fsn_03: db 'READ_FILE', 0
.fsn_04: db 'GET_INFO', 0
.fs_name_table:
    dw 0            ; 0x00 — unused
    dw .fsn_01      ; 0x01
    dw .fsn_02      ; 0x02
    dw .fsn_03      ; 0x03
    dw .fsn_04      ; 0x04
%endif

; ─── FS_LIST_FILES (AH=0x01) ─────────────────────────────────────────────────
; Copy the cached 512-byte directory sector to the caller's buffer.
; Input:  ES:BX = 512-byte destination buffer
; Output: CL = file count, CF clear
; ──────────────────────────────────────────────────────────────────────────────
.fn_list_files:
    push ax
    push si
    push di
    push cx
    push ds

    ; Set up source: DS:SI → our cached directory
    push cs
    pop ds                          ; DS = CS (FS.SYS's segment)
    mov si, dir_cache

    ; Set up destination: ES:BX → caller's buffer
    mov di, bx

    ; Copy 512 bytes (256 words)
    mov cx, 256
    rep movsw

    pop ds
    pop cx
    mov cl, [cs:cached_count]       ; CL = file count
    pop di
    pop si
    pop ax
    jmp fs_iret_cf_clear

; ─── FS_FIND_FILE (AH=0x02) ──────────────────────────────────────────────────
; Search cached directory for a file by 11-byte 8.3 name.
; Input:  DS:SI = pointer to 11-byte filename (8+3, space-padded, uppercase)
; Output: CF clear = found:
;           EAX = start sector (partition-relative)
;           CX  = size in sectors
;           EDX = size in bytes
;           DL (low byte of EDX) also available; DH clobbered
;           BL  = attribute byte
;         CF set = not found
; ──────────────────────────────────────────────────────────────────────────────
.fn_find_file:
    push di
    push bx

    ; Save caller's filename pointer
    mov [cs:.ff_caller_si], si

    ; Set up search through cached directory
    movzx cx, byte [cs:cached_count]
    test cx, cx
    jz .ff_not_found

    ; DI → first entry in cache (CS-relative)
    ; We need to compare DS:SI (caller's name) with CS:entry
    ; Use ES:DI for our cache since caller owns DS
    push es
    push cs
    pop es                          ; ES = CS (our cache segment)
    mov di, dir_cache + MNFS_HDR_SIZE

.ff_loop:
    push cx
    push di

    ; Compare 11 bytes: DS:SI (caller) vs ES:DI (our cache entry)
    mov si, [cs:.ff_caller_si]      ; Restore SI each iteration
    mov cx, MNFS_NAME_LEN
    repe cmpsb
    je .ff_match

    pop di
    pop cx
    add di, MNFS_ENTRY_SIZE
    dec cx
    jnz .ff_loop

    pop es
    jmp .ff_not_found

.ff_match:
    pop di                          ; DI → matching entry start
    pop cx                          ; Discard count

    ; Save attribute byte to temp (before we clobber registers)
    push ax
    mov al, [es:di + MNFS_ENT_ATTR]
    mov [cs:.ff_attr_tmp], al
    pop ax

    ; Extract fields from the matched entry (ES:DI relative)
    mov eax, [es:di + MNFS_ENT_START]
    mov cx, [es:di + MNFS_ENT_SECTORS]
    mov edx, [es:di + MNFS_ENT_BYTES]

    pop es                          ; Restore caller's ES
    pop bx
    pop di

    ; Return attribute in BL
    mov bl, [cs:.ff_attr_tmp]
    jmp fs_iret_cf_clear

.ff_not_found:
    pop bx
    pop di
    jmp fs_iret_cf_set

.ff_caller_si: dw 0                 ; Saved caller's filename pointer
.ff_attr_tmp:  db 0                 ; Temp storage for attribute byte

; ─── FS_READ_FILE (AH=0x03) ──────────────────────────────────────────────────
; Read a file's contents from disk into the caller's buffer.
; Internally finds the file, then uses INT 0x80 SYS_READ_SECTOR.
; Input:  DS:SI = 11-byte filename
;         ES:BX = buffer to read into
;         CX    = maximum sectors to read
; Output: CF clear = success, CX = sectors actually read
;         CF set   = error (file not found or disk I/O error)
; ──────────────────────────────────────────────────────────────────────────────
.fn_read_file:
    push dx
    push ax

    ; Save caller's buffer and max sectors
    mov [cs:.rf_buf_off], bx
    mov [cs:.rf_buf_seg], es
    mov [cs:.rf_max], cx

    ; Find the file first (reuse our own find logic)
    ; DS:SI already points to filename
    push di
    push bx
    movzx cx, byte [cs:cached_count]
    test cx, cx
    jz .rf_not_found

    push es
    push cs
    pop es
    mov di, dir_cache + MNFS_HDR_SIZE

.rf_search:
    push cx
    push di
    push si                         ; Save SI for each iteration

    mov cx, MNFS_NAME_LEN
    repe cmpsb
    je .rf_found

    pop si
    pop di
    pop cx
    add di, MNFS_ENTRY_SIZE
    dec cx
    jnz .rf_search

    pop es
    jmp .rf_not_found

.rf_found:
    pop si                          ; Discard saved SI
    pop di                          ; DI → matched entry
    pop cx                          ; Discard count

    ; Read sectors BEFORE loading EDI (which clobbers DI)
    mov cx, [es:di + MNFS_ENT_SECTORS]
    mov edi, [es:di + MNFS_ENT_START]
    pop es                          ; Restore caller's ES

    ; Clamp to caller's max sectors
    jbe .rf_size_ok
    mov cx, [cs:.rf_max]
.rf_size_ok:
    mov [cs:.rf_actual], cx

    ; Calculate absolute LBA = partition_lba + start_sector
    add edi, [BIB_PART_LBA]

    ; Read via direct INT 0x13 (avoids nested INT 0x80 which causes DMA errors
    ; in Hyper-V due to triple-nested interrupt context)
    xor ch, ch
    mov cl, [cs:.rf_actual]         ; CX = sectors to read
    mov [cs:.rf_dap_lba], edi
    mov [cs:.rf_dap_sectors], cx
    mov ax, [cs:.rf_buf_off]
    mov [cs:.rf_dap_buf], ax
    mov ax, [cs:.rf_buf_seg]
    mov [cs:.rf_dap_buf+2], ax

%ifdef DEBUG
    ; --- DAP dump before INT 0x13 ---
    push cx
    push si
    mov si, fs_dbg_dap_pfx          ; "[FS] DAP: "
    call serial_puts
    mov si, .rf_dap
    mov cx, 16
.rf_dap_dump:
    lodsb
    call serial_hex8
    mov al, ' '
    call serial_putc
    loop .rf_dap_dump
    call serial_crlf
    pop si
    pop cx
%endif

    mov si, .rf_dap                 ; DS:SI → our DAP (DS=0, flat model)
    mov dl, [BIB_DRIVE]
    mov ah, 0x42
    sti                             ; BIOS needs interrupts for DMA
    int 0x13
    jc .rf_disk_err

%ifdef DEBUG
    push si
    mov si, fs_dbg_read_ok
    call serial_puts
    call serial_crlf
    pop si
%endif

    ; Success
    mov cx, [cs:.rf_actual]
    pop bx
    pop di
    pop ax
    pop dx
    jmp fs_iret_cf_clear

.rf_not_found:
%ifdef DEBUG
    push si
    mov si, fs_dbg_rf_nf            ; "[FS] RF: not_found"
    call serial_puts
    call serial_crlf
    pop si
%endif
    pop bx
    pop di
    pop ax
    pop dx
    jmp fs_iret_cf_set

.rf_disk_err:
%ifdef DEBUG
    push si
    push ax
    mov si, fs_dbg_disk_err         ; "[FS] INT13 ERR AH="
    call serial_puts
    mov al, ah
    call serial_hex8
    call serial_crlf
    pop ax
    pop si
%endif
    pop bx
    pop di
    pop ax
    pop dx
    jmp fs_iret_cf_set

.rf_buf_off:  dw 0
.rf_buf_seg:  dw 0
.rf_max:      dw 0
.rf_actual:   dw 0

; Local DAP for direct INT 0x13 (avoids nested INT 0x80)
.rf_dap:
    db 0x10, 0                      ; Size=16, reserved=0
.rf_dap_sectors:
    dw 0                            ; Sector count
.rf_dap_buf:
    dw 0, 0                         ; Buffer offset, segment
.rf_dap_lba:
    dd 0, 0                         ; 64-bit LBA

; ─── FS_GET_INFO (AH=0x04) ───────────────────────────────────────────────────
; Return filesystem metadata.
; Input:  none
; Output: AL = MNFS version, CL = file count, CH = max entries (15)
;         DX = total sectors used, BX = total data area capacity (sectors)
; ──────────────────────────────────────────────────────────────────────────────
.fn_get_info:
    mov al, [cs:dir_cache + MNFS_HDR_VERSION]
    mov cl, [cs:cached_count]
    mov ch, MNFS_MAX_ENTRIES
    mov dx, [cs:dir_cache + MNFS_HDR_TOTAL]
    mov bx, [cs:dir_cache + MNFS_HDR_CAPACITY]
    jmp fs_iret_cf_clear

; =============================================================================
; DATA
; =============================================================================
cached_count:  db 0                  ; Cached file count (from directory header)

; --- Directory cache (512 bytes — holds the full MNFS directory sector) -------
; This is read once during init and used for all subsequent lookups.
dir_cache:
    times 512 db 0

; =============================================================================
; IRET Helpers — properly propagate CF via the interrupt stack frame
;
; Problem: `clc; iret` does NOT work because `iret` pops FLAGS from the stack
; (the caller's saved FLAGS), ignoring the current FLAGS register.
; Solution: Use `retf 2` which pops IP and CS but DISCARDS the saved FLAGS
; (adds 2 to SP), preserving the handler's current FLAGS (including CF).
; `sti` is needed because `int` clears IF on entry.
;
; This matches the kernel's syscall_ret_cf pattern (see kernel.asm §comment).
; =============================================================================

; Clear CF in handler FLAGS and return from interrupt
fs_iret_cf_clear:
%ifdef DEBUG
    push si
    mov si, fs_dbg_ret_ok
    call serial_puts
    call serial_crlf
    pop si
    dec byte [cs:BIB_INT_DEPTH]        ; Track total INT nesting
%endif
    clc
    sti
    retf 2

; Set CF in handler FLAGS and return from interrupt
fs_iret_cf_set:
%ifdef DEBUG
    push si
    mov si, fs_dbg_ret_err
    call serial_puts
    call serial_crlf
    pop si
    dec byte [cs:BIB_INT_DEPTH]        ; Track total INT nesting
%endif
    stc
    sti
    retf 2

%ifdef DEBUG
fs_dbg_ret_ok:   db '[FS] -> OK', 0
fs_dbg_ret_err:  db '[FS] -> ERR (CF=1)', 0
fs_dbg_read_ok:  db '[FS] READ_SECTOR OK', 0
fs_dbg_dap_pfx:  db '[FS] DAP: ', 0
fs_dbg_disk_err: db '[FS] INT13 ERR AH=', 0
fs_dbg_rf_nf:    db '[FS] RF: not_found', 0
%endif

; =============================================================================
; Serial I/O functions (debug build only — placed after FS code to avoid
; polluting the header at offset 0)
; =============================================================================
%include "serial.inc"

; =============================================================================
; PADDING — fill to sector boundary
; =============================================================================
%ifdef DEBUG
times (4 * 512) - ($ - $$) db 0
%else
times (2 * 512) - ($ - $$) db 0
%endif
