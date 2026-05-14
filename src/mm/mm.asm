; =============================================================================
; Mini-OS Memory Manager (MM.SYS) — MNMM Heap Allocator
;
; Loaded by KERNEL.SYS into memory at 0x2800.  Provides dynamic memory
; allocation services via INT 0x82 — fully decoupled from the kernel's
; INT 0x80 and the filesystem's INT 0x81.
;
; Architecture:
;   User mode (SHELL)  →  INT 0x82  →  MM.SYS  →  manages heap at 0x8000
;
; The heap is a contiguous region from 0x8000 to 0xF7FF (30 KB).  It is
; managed as a linked list of Memory Control Blocks (MCBs).  Each block
; has a 4-byte header:
;
;   Offset 0: size   (word)  — total block size INCLUDING this header
;   Offset 2: flags  (byte)  — bit 0: 1=allocated, 0=free
;   Offset 3: magic  (byte)  — 'M' (0x4D) for integrity checking
;
; Allocation uses first-fit with forward coalescing on free.  All sizes
; are rounded up to the nearest even number (word-aligned) to keep
; pointers naturally aligned for 16-bit code.
;
; Initialization:
;   The kernel calls our init entry point (offset 6) after loading.
;   Init installs INT 0x82 in the IVT and sets up the initial free block.
;
; Header layout (first 6 bytes):
;   Offset 0: 'MNMM'  Magic identifier (4 bytes)
;   Offset 4: dw N    Module size in sectors
;
; INT 0x82 functions (AH = function number):
;   0x01  MEM_ALLOC  — Allocate CX bytes → BX = pointer, CF on error
;   0x02  MEM_FREE   — Free block at BX → CF on error
;   0x03  MEM_AVAIL  — Query free memory → AX=largest, DX=total
;   0x04  MEM_INFO   — Heap statistics → AX=total, BX=used, CX=free, DX=blocks
;
; CF propagation: Handlers use `sti; retf 2` to preserve CF across iret,
; matching the kernel and FS syscall convention.
;
; See doc/MEMORY-MANAGER.md for the complete specification.
;
; Assembled with:  nasm -f bin -o mm.sys src/mm/mm.asm
; =============================================================================

%include "memory.inc"
%include "debug.inc"

[BITS 16]
[ORG MM_OFF]                         ; Loaded at 0x2800

; =============================================================================
; MM.SYS HEADER
; =============================================================================
mm_magic        db 'MNMM'           ; Magic identifier — memory manager
%ifdef DEBUG
mm_sectors      dw 2                 ; Module size in sectors (debug build)
%else
mm_sectors      dw 1                 ; Module size in sectors (release build)
%endif

; =============================================================================
; mm_init — Initialize the memory manager
;
; Called by the kernel after loading MM.SYS into memory.
;   1. Installs INT 0x82 handler in the IVT
;   2. Initializes the heap as a single free block spanning 0x8000–0xF7FF
;
; The initial heap state is one MCB at 0x8000:
;   size  = HEAP_SIZE (30720 bytes = entire heap)
;   flags = 0x00 (free)
;   magic = 'M'
;
; Input:  none
; Output: CF clear = success
; Clobbers: AX, BX, ES
; =============================================================================
mm_init:
    ; --- Install INT 0x82 handler in IVT ------------------------------------
    cli                              ; Disable interrupts while modifying IVT
    push es

    xor ax, ax
    mov es, ax                       ; ES = 0x0000 (IVT segment)

    ; Vector 0x82 is at 0x82 * 4 = 0x0208
    mov word [es:0x82*4],   mm_isr   ; Offset of our handler
    mov word [es:0x82*4+2], cs       ; Segment (same as our code segment)

    pop es
    sti                              ; Re-enable interrupts

    DBG "MM: INT 0x82 installed"

    ; --- Initialize heap with single free block -----------------------------
    ; Write the initial MCB header at HEAP_START (0x8000)
    mov bx, HEAP_START
    mov word [bx + MCB_SIZE_OFF], HEAP_SIZE   ; Size = entire heap
    mov byte [bx + MCB_FLAGS_OFF], 0x00       ; Free
    mov byte [bx + MCB_MAGIC_OFF], MCB_MAGIC  ; 'M'

    DBG "MM: heap initialized 0x8000-0xF7FF"

    clc                              ; Success
    ret

; =============================================================================
; mm_isr — INT 0x82 dispatcher
;
; Routes memory management syscalls based on AH function number using a
; jump table.  Invalid function numbers return CF set.
;
; All handlers return via syscall_ret_mm (sti; retf 2) to preserve CF.
; =============================================================================
mm_isr:
%ifdef DEBUG
    ; --- Syscall trace: log function number ----------------------------------
    push si
    push ax
    mov si, mm_trace_pfx            ; "[MM] AH="
    call serial_puts
    mov al, ah
    call serial_hex8
    call serial_crlf
    pop ax
    pop si
%endif

    ; --- Validate function number -------------------------------------------
    cmp ah, MEM_SYSCALL_MAX
    ja .mm_bad_func

    ; --- Save caller's BX, use AH as table index ---------------------------
    push si
    movzx si, ah                     ; SI = function number (1-based)
    dec si                           ; Convert to 0-based index
    shl si, 1                        ; SI = index * 2 (word table)
    jmp [cs:mm_table + si]           ; Jump to handler (CS: since we're in ISR)

.mm_bad_func:
    stc                              ; Invalid function
    sti
    retf 2

; Jump table for INT 0x82 functions (0-based: alloc=0, free=1, avail=2, info=3)
mm_table:
    dw mm_alloc                      ; AH=0x01 → MEM_ALLOC
    dw mm_free                       ; AH=0x02 → MEM_FREE
    dw mm_avail                      ; AH=0x03 → MEM_AVAIL
    dw mm_info                       ; AH=0x04 → MEM_INFO

; =============================================================================
; mm_alloc — Allocate CX bytes from the heap
;
; Uses first-fit: walks the MCB chain from HEAP_START, finds the first free
; block large enough, optionally splits it, marks it allocated.
;
; Input:  CX = requested size in bytes (must be > 0)
;         DL = owner ID (0-7, stored in MCB flags bits 1-3)
; Output: BX = pointer to usable memory (past MCB header)
;         CF clear = success, CF set = failure (no block large enough)
; Clobbers: AX
; Preserves: CX, DX, SI, DI, DS, ES
; =============================================================================
mm_alloc:
    ; --- Validate request ---------------------------------------------------
    test cx, cx
    jz .alloc_fail                   ; Reject zero-size allocation

    ; --- Round up to even (word-aligned) ------------------------------------
    ; aligned = (cx + 1) & 0xFFFE
    mov ax, cx
    inc ax                           ; AX = CX + 1
    and ax, 0xFFFE                   ; Round up to even
    ; Handle the case where CX was already even: inc makes it odd, AND makes
    ; it the next even.  If CX was odd, inc makes it even, AND keeps it.
    ; Special case: if CX is even, (CX+1)&~1 = CX+1-1 = CX.  Wait, no:
    ;   CX=4: (5) & 0xFFFE = 4.  Correct.
    ;   CX=5: (6) & 0xFFFE = 6.  Correct.

    ; --- Calculate total block size needed ----------------------------------
    ; block_size = aligned_payload + MCB_HDR_SIZE (4)
    add ax, MCB_HDR_SIZE             ; AX = total block size needed

    ; Overflow check: if AX wrapped around or exceeds heap, fail
    cmp ax, HEAP_SIZE
    ja .alloc_fail

    ; Enforce minimum block size
    cmp ax, MCB_MIN_BLOCK
    jae .alloc_size_ok
    mov ax, MCB_MIN_BLOCK            ; At least 8 bytes (4 hdr + 4 payload)
.alloc_size_ok:

    ; AX = required block size (including header)
    ; Now walk the heap to find a free block >= AX

    push di
    push dx
    mov di, HEAP_START               ; DI = current block pointer

.alloc_walk:
    ; --- Check if we've gone past the heap ----------------------------------
    cmp di, HEAP_END
    jae .alloc_oom                   ; Walked past end → out of memory

    ; --- Validate MCB magic -------------------------------------------------
    cmp byte [di + MCB_MAGIC_OFF], MCB_MAGIC
    jne .alloc_oom                   ; Corrupted heap — treat as OOM

    ; --- Skip allocated blocks ----------------------------------------------
    test byte [di + MCB_FLAGS_OFF], MCB_FLAG_USED
    jnz .alloc_next

    ; --- Free block found — is it large enough? -----------------------------
    cmp [di + MCB_SIZE_OFF], ax
    jae .alloc_found                 ; This block is big enough

.alloc_next:
    ; Advance to next block: DI += block size
    add di, [di + MCB_SIZE_OFF]
    jmp .alloc_walk

.alloc_found:
    ; DI = pointer to free MCB that fits
    ; AX = required block size
    ; Check if we should split: remainder >= MCB_MIN_BLOCK?
    mov dx, [di + MCB_SIZE_OFF]      ; DX = current block size
    sub dx, ax                       ; DX = remainder after allocation
    cmp dx, MCB_MIN_BLOCK
    jb .alloc_no_split

    ; --- Split: create a new free block after the allocated portion ----------
    ; New block starts at DI + AX
    push bx
    mov bx, di
    add bx, ax                       ; BX = address of new free block

    mov [bx + MCB_SIZE_OFF], dx      ; Remainder size
    mov byte [bx + MCB_FLAGS_OFF], 0x00   ; Free
    mov byte [bx + MCB_MAGIC_OFF], MCB_MAGIC
    pop bx

    ; Update current block size to exactly what was requested
    mov [di + MCB_SIZE_OFF], ax
    jmp .alloc_mark

.alloc_no_split:
    ; Use the entire block (no split — remainder too small)

.alloc_mark:
    ; --- Mark block as allocated with owner ID --------------------------------
    ; flags = MCB_FLAG_USED | (DL << MCB_OWNER_SHIFT)
    push cx
    mov cl, dl
    and cl, 0x07                     ; Mask to 3-bit owner (0-7)
    shl cl, MCB_OWNER_SHIFT          ; Shift into bits 1-3
    or  cl, MCB_FLAG_USED            ; Set allocated bit
    mov byte [di + MCB_FLAGS_OFF], cl
    pop cx

    ; --- Return pointer past the header -------------------------------------
    mov bx, di
    add bx, MCB_HDR_SIZE             ; BX = usable memory pointer

    pop dx
    pop di
    pop si                           ; Restore SI saved by dispatcher

%ifdef DEBUG
    ; Log: "[MM] alloc sz=XXXX ptr=XXXX own=X"
    push si
    push ax
    mov si, mm_alloc_ok             ; "[MM] alloc sz="
    call serial_puts
    mov ax, cx
    call serial_hex16
    mov si, mm_ptr_eq               ; " ptr="
    call serial_puts
    mov ax, bx
    call serial_hex16
    mov si, mm_own_eq               ; " own="
    call serial_puts
    mov al, dl
    and al, 0x07
    add al, '0'                     ; Convert to ASCII digit
    call serial_putc
    call serial_crlf
    pop ax
    pop si
%endif

    clc                              ; Success
    sti
    retf 2

.alloc_oom:
    pop dx
    pop di
.alloc_fail:
    pop si                           ; Restore SI saved by dispatcher

%ifdef DEBUG
    push si
    push ax
    mov si, mm_alloc_fail_msg       ; "[MM] alloc FAIL sz="
    call serial_puts
    mov ax, cx
    call serial_hex16
    call serial_crlf
    pop ax
    pop si
%endif

    stc                              ; Out of memory
    sti
    retf 2

; =============================================================================
; mm_free — Free a previously allocated block
;
; Validates the pointer, marks the block as free, then coalesces with the
; next block if it is also free (forward coalescing).
;
; Input:  BX = pointer returned by MEM_ALLOC (points past MCB header)
; Output: CF clear = success, CF set = error (invalid pointer)
; Clobbers: AX
; Preserves: BX, CX, DX, SI, DI, DS, ES
; =============================================================================
mm_free:
    ; --- Validate pointer range ---------------------------------------------
    ; The usable pointer must be within HEAP_START+4 .. HEAP_END-4
    cmp bx, HEAP_START + MCB_HDR_SIZE
    jb .free_fail                    ; Below heap
    cmp bx, HEAP_END
    jae .free_fail                   ; Above heap

    ; --- Step back to the MCB header ----------------------------------------
    push di
    mov di, bx
    sub di, MCB_HDR_SIZE             ; DI = MCB header address

    ; --- Validate MCB magic -------------------------------------------------
    cmp byte [di + MCB_MAGIC_OFF], MCB_MAGIC
    jne .free_fail_di                ; Not a valid MCB

    ; --- Check that block is currently allocated ----------------------------
    test byte [di + MCB_FLAGS_OFF], MCB_FLAG_USED
    jz .free_fail_di                 ; Already free (double free)

    ; --- Mark as free -------------------------------------------------------
    mov byte [di + MCB_FLAGS_OFF], 0x00

    ; --- Forward coalesce: merge with next block if free --------------------
    ; Next block is at DI + block_size
    push ax
    push dx

.free_coalesce:
    mov ax, [di + MCB_SIZE_OFF]      ; AX = current block size
    mov dx, di
    add dx, ax                       ; DX = next block address

    ; Check bounds
    cmp dx, HEAP_END
    jae .free_done                   ; At end of heap — nothing to merge

    ; Check next block's magic
    push bx
    mov bx, dx
    cmp byte [bx + MCB_MAGIC_OFF], MCB_MAGIC
    jne .free_coalesce_end           ; Next block corrupted — stop

    ; Check if next block is free
    test byte [bx + MCB_FLAGS_OFF], MCB_FLAG_USED
    jnz .free_coalesce_end           ; Next block is allocated — stop

    ; --- Merge: absorb next block's size into current -----------------------
    mov ax, [bx + MCB_SIZE_OFF]      ; AX = next block size
    add [di + MCB_SIZE_OFF], ax      ; Current size += next size

    ; Invalidate the absorbed block's magic (optional, aids debugging)
    mov byte [bx + MCB_MAGIC_OFF], 0x00

    pop bx
    jmp .free_coalesce               ; Check for more adjacent free blocks

.free_coalesce_end:
    pop bx

.free_done:
    pop dx
    pop ax
    pop di
    pop si                           ; Restore SI saved by dispatcher

%ifdef DEBUG
    push si
    push ax
    mov si, mm_free_ok              ; "[MM] free ptr="
    call serial_puts
    mov ax, bx
    call serial_hex16
    call serial_crlf
    pop ax
    pop si
%endif

    clc                              ; Success
    sti
    retf 2

.free_fail_di:
    pop di
.free_fail:
    pop si                           ; Restore SI saved by dispatcher

%ifdef DEBUG
    push si
    push ax
    mov si, mm_free_fail_msg        ; "[MM] free FAIL ptr="
    call serial_puts
    mov ax, bx
    call serial_hex16
    call serial_crlf
    pop ax
    pop si
%endif

    stc                              ; Error
    sti
    retf 2

; =============================================================================
; mm_avail — Query available heap memory
;
; Walks the entire MCB chain and reports:
;   AX = largest contiguous free block (usable bytes, excluding header)
;   DX = total free bytes (usable, excluding headers)
;
; Input:  none
; Output: AX = largest free block usable bytes, DX = total free usable bytes
;         CF always clear
; Clobbers: AX, DX
; Preserves: BX, CX, SI, DI, DS, ES
; =============================================================================
mm_avail:
    push di
    push cx

    xor ax, ax                       ; AX = largest free block (usable)
    xor dx, dx                       ; DX = total free (usable)
    mov di, HEAP_START

.avail_walk:
    cmp di, HEAP_END
    jae .avail_done

    cmp byte [di + MCB_MAGIC_OFF], MCB_MAGIC
    jne .avail_done                  ; Corrupted — stop walking

    ; Check if free
    test byte [di + MCB_FLAGS_OFF], MCB_FLAG_USED
    jnz .avail_next                  ; Skip allocated blocks

    ; Free block: usable = size - header
    mov cx, [di + MCB_SIZE_OFF]
    sub cx, MCB_HDR_SIZE             ; CX = usable bytes in this block
    add dx, cx                       ; Total free += usable

    ; Update largest
    cmp cx, ax
    jbe .avail_next
    mov ax, cx                       ; New largest

.avail_next:
    add di, [di + MCB_SIZE_OFF]
    jmp .avail_walk

.avail_done:
    pop cx
    pop di
    pop si                           ; Restore SI saved by dispatcher
    clc
    sti
    retf 2

; =============================================================================
; mm_info — Query heap statistics
;
; Walks the MCB chain and reports:
;   AX = total heap size (HEAP_SIZE constant)
;   BX = bytes used (allocated blocks, including headers)
;   CX = bytes free (free blocks, including headers)
;   DX = total block count
;
; Input:  none
; Output: AX, BX, CX, DX as above.  CF always clear.
; Clobbers: AX, BX, CX, DX
; Preserves: SI, DI, DS, ES
; =============================================================================
mm_info:
    push di

    mov ax, HEAP_SIZE                ; AX = total heap size
    xor bx, bx                      ; BX = bytes used
    xor cx, cx                       ; CX = bytes free
    xor dx, dx                       ; DX = block count
    mov di, HEAP_START

.info_walk:
    cmp di, HEAP_END
    jae .info_done

    cmp byte [di + MCB_MAGIC_OFF], MCB_MAGIC
    jne .info_done                   ; Corrupted — stop

    inc dx                           ; Count this block

    test byte [di + MCB_FLAGS_OFF], MCB_FLAG_USED
    jz .info_free

    ; Allocated block
    add bx, [di + MCB_SIZE_OFF]      ; Used += block size
    jmp .info_next

.info_free:
    add cx, [di + MCB_SIZE_OFF]      ; Free += block size

.info_next:
    add di, [di + MCB_SIZE_OFF]
    jmp .info_walk

.info_done:
    pop di
    pop si                           ; Restore SI saved by dispatcher
    clc
    sti
    retf 2

; =============================================================================
; Debug trace strings (debug build only)
; =============================================================================
%ifdef DEBUG
mm_trace_pfx       db '[MM] AH=', 0
mm_alloc_ok        db '[MM] alloc sz=', 0
mm_alloc_fail_msg  db '[MM] alloc FAIL sz=', 0
mm_free_ok         db '[MM] free ptr=', 0
mm_free_fail_msg   db '[MM] free FAIL ptr=', 0
mm_ptr_eq          db ' ptr=', 0
mm_own_eq          db ' own=', 0
%endif

; =============================================================================
; Serial I/O functions (debug build only)
; =============================================================================
%include "serial.inc"

; =============================================================================
; PADDING — fill to sector boundary
; =============================================================================
%ifdef DEBUG
times (2 * 512) - ($ - $$) db 0
%else
times (1 * 512) - ($ - $$) db 0
%endif
