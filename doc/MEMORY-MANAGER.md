# MNMM — Mini-OS Memory Manager

**Version:** 2.0 (Design + Implementation)
**Status:** Implemented — v0.9.0
**Author:** mini-os project
**Date:** 2026-05-13

---

## 1. Overview

MNMM (Mini-OS Memory Manager) provides **dynamic memory allocation** for
mini-os.  It manages a contiguous heap region in conventional memory, offering
allocate/free semantics through `INT 0x82` software interrupts.

Today, every mini-os component uses statically placed memory — KERNEL at 0x5000,
SHELL at 0x3000, FS.BIN at 0x0800.  This works when the number of components is
fixed and known at build time.  But the moment you need a variable-size buffer,
a dynamically loaded program, or a data structure that grows at runtime, static
placement breaks down.

MNMM bridges that gap: it turns the large block of unused RAM above the boot
area into a managed heap where any component can request and release memory at
runtime.

### 1.1 Key Specifications

| Property             | Value                                            |
|----------------------|--------------------------------------------------|
| Heap region          | `0x8000`–`0xF7FF` (30 KB)                        |
| Minimum allocation   | 4 bytes usable (8-byte block including header)    |
| Alignment            | Word-aligned (2-byte)                             |
| Algorithm            | First-fit with forward coalescing                 |
| Binary               | `MM.BIN` loaded at `0x2800` (max 2 KB)            |
| Interface            | `INT 0x82` (AH = function selector)               |
| Overhead per block   | 4 bytes (size + flags + magic)                    |

### 1.2 Design Goals

1. **Educational clarity** — Every data structure is visible in memory and
   inspectable via `mnmon`.  A student should be able to examine the heap,
   see block headers, walk the free list, and understand what happened.

2. **Zero external dependencies** — MNMM needs no filesystem, no display, and
   no kernel services to function.  It manages raw RAM.

3. **Defensive** — Detects double-free, invalid pointers, and heap corruption
   via magic numbers, bounds checking, and optional fill patterns.

4. **Small** — Target: < 800 bytes of code + data.  Fits comfortably in the
   2 KB slot at `0x2800`.

5. **Debuggable** — Optional serial logging in debug builds, fill patterns for
   detecting use-after-free, and a heap-walk routine that `mnmon` can invoke.

### 1.3 What MNMM Is NOT

- **Not a virtual memory system** — There is no paging, no address translation,
  no demand loading.  Every pointer is a physical address.
- **Not a process memory manager** — There are no per-process heaps, no memory
  protection between callers.  Any code can corrupt any address.
- **Not a memory-mapped I/O manager** — Hardware regions (video memory, BIOS)
  are outside the heap and not managed by MNMM.

These limitations are appropriate for a real-mode educational OS.  The design
deliberately mirrors early microcomputer memory managers (CP/M BDOS, Apple II
ProDOS) where simplicity enabled understanding.

---

## 2. Motivation & Use Cases

### 2.1 Why Now?

The v0.7.0 debugging infrastructure (DEBUGGING.md) does **not** require
dynamic allocation — serial logging uses I/O ports, fault handlers are static
code, and `mnmon` accesses raw addresses.  So why design a memory manager?

Because the **next wave of features** will:

| Feature                 | Why it needs dynamic memory                     |
|-------------------------|--------------------------------------------------|
| File read buffer        | `cat` / `type` command needs a buffer for file   |
|                         | contents; file sizes vary                         |
| Loadable programs       | User programs loaded from disk at runtime need    |
|                         | a place to live                                   |
| Command history         | Shell history buffer grows with usage             |
| Environment variables   | Key-value pairs of arbitrary size                 |
| mnmon deposit buffer    | Assembling a program in RAM before running it     |
| Disk write buffer       | Future `FS_WRITE_FILE` needs a staging buffer     |
| String processing       | Any string manipulation beyond fixed-size buffers |

Without a memory manager, every feature requires a new hardcoded address,
careful manual sizing, and a documentation update.  With MNMM, a feature just
calls `INT 0x82` and gets a pointer.

### 2.2 Historical Context

Dynamic memory allocation is one of the oldest problems in computer science.
Here's how some systems solved it:

| System (Year)       | Approach                    | Heap Size   |
|---------------------|-----------------------------|-------------|
| CP/M 2.2 (1979)     | Transient Program Area      | ~52 KB      |
| Apple II DOS (1978)  | HIMEM/LOMEM pointers        | ~38 KB      |
| MS-DOS 1.0 (1981)   | PSP + Memory Control Block  | ~256 KB     |
| Commodore 64 (1982)  | BASIC heap (FRE function)   | ~38 KB      |
| Minix 1.0 (1987)     | First-fit free list         | ~640 KB     |

MNMM sits in this tradition — a simple, understandable allocator for a
constrained environment.

---

## 3. Memory Map Integration

### 3.1 Where Does the Heap Live?

After the boot sequence completes, the following regions are **dead** (no longer
needed):

```
Address Range   Size    Original Purpose          Status After Boot
─────────────────────────────────────────────────────────────────────
0x7C00–0x7DFF    512 B  VBR code                  Dead (LOADER took over)
0x7E00–0x9DFF   8 KB    VBR load buffer           Dead (staging area)
```

Combined with the RAM above the VBR load buffer (0x9E00 onward), there is a
large contiguous block of unused memory in segment 0:

```
0x7C00 ─ 0xFFFF  =  33,792 bytes  ≈  33 KB
```

However, the first 2 KB of this (0x7C00–0x7FFF) overlaps with the old VBR area
and sits just above the stack.  For cleanliness and a nice round boundary, MNMM
claims:

```
Heap start:  0x8000   (32 KB mark — clean boundary)
Heap end:    0xF7FF   (inclusive; 0xF800–0xFFFF reserved)
Heap size:   0x77FF   =  30,720 bytes  =  30 KB exactly
```

The reserved 2 KB at 0xF800–0xFFFF provides:
- A **guard zone** between heap and the segment wrap boundary
- Space for future MNMM metadata if the data area at 0x2800 becomes tight
- Protection against off-by-one errors at the heap top

### 3.2 Updated Memory Map (v0.8.0)

```
Address       Size      Contents                 Lifetime
─────────────────────────────────────────────────────────────────
0x0000:0x0000  1024 B   IVT (256 × 4-byte ptrs)  Permanent (BIOS)
0x0000:0x0400   256 B   BIOS Data Area (BDA)      Permanent (BIOS)
0x0000:0x0500   256 B   Free (BIOS-safe area)     Available

0x0000:0x0600    16 B   Boot Info Block (BIB)     Permanent

0x0000:0x0610   496 B   (Unused gap)              Available

0x0000:0x0800  8192 B   FS.BIN                    Permanent (runtime)
               (8 KB)    INT 0x81 filesystem       (LOADER.BIN here at boot,
                                                    then overwritten by kernel)

0x0000:0x2800  2048 B   MNMM.BIN   ← NEW         Permanent (runtime)
               (2 KB)    INT 0x82 memory manager   Loaded by KERNEL after
                                                    FS.BIN, before SHELL

0x0000:0x3000  8192 B   SHELL.BIN                 Permanent (runtime)
               (8 KB)

0x0000:0x5000  8192 B   KERNEL.BIN                Permanent (runtime)
               (8 KB)

0x0000:0x7000  3072 B   Stack (grows ↓)           Active
               (3 KB)    SP starts at 0x7C00

0x0000:0x7C00   512 B   (Dead — was VBR)          Reclaimable
0x0000:0x7E00  8192 B   (Dead — was load buffer)  Reclaimable

0x0000:0x8000 30720 B   ═══ MNMM HEAP ═══        Managed by MNMM
              (30 KB)    Dynamic allocation pool   INT 0x82 alloc/free
                         First-fit, 8-byte aligned

0x0000:0xF800  2048 B   (Guard / reserved)        Unused
               (2 KB)

0x0000:0xFFFF            End of Segment 0
```

### 3.3 Why Segment 0?

All mini-os code runs in segment 0 (DS = ES = SS = 0x0000).  Heap pointers
are plain 16-bit offsets within this segment.  This means:

- **No segment arithmetic** — pointers are just unsigned 16-bit integers
- **Maximum addressable**: 0xFFFF (64 KB total in segment 0)
- **No far pointers needed** — every component shares the same segment
- **Compatible with `mnmon`** — the monitor examines segment 0 by default

Future expansion beyond 64 KB would require segment manipulation or a move to
protected mode — that's a separate design decision documented in MEMORY-LAYOUT.md §6.

### 3.4 Relationship to Stack

The stack and heap do **not** grow toward each other:

```
         0x5000                    0x7000      0x7C00     0x8000
         ┌──────────┐              ┌─────────────┐       ┌──────────────┐
         │ KERNEL   │              │   STACK ↓   │       │   HEAP →     │
         │          │              │ SP=0x7C00    │       │              │
         └──────────┘              │ grows to     │       │ grows by     │
                                   │ 0x7000       │       │ splitting    │
                                   └─────────────┘       │ free blocks  │
                                                          └──────────────┘
```

The stack occupies 0x7000–0x7C00 (fixed bounds, grows downward).  The heap
occupies 0x8000–0xF7FF (fixed bounds, managed internally).  There is a 2 KB
gap (0x7C00–0x7FFF, the old VBR area) separating them.

**Stack overflow cannot corrupt the heap**, and heap allocation cannot
interfere with the stack.  The stack canary (DEBUGGING.md §9) at 0x7000
detects stack overflow independently.

---

## 4. Architecture

### 4.1 MNMM.BIN — The Memory Manager Binary

MNMM follows the same modular pattern as FS.BIN:

| Property        | FS.BIN                    | MNMM.BIN                  |
|-----------------|---------------------------|----------------------------|
| Load address    | 0x0800                    | 0x2800                     |
| Max size        | 8 KB (8192 bytes)         | 2 KB (2048 bytes)          |
| Interrupt       | INT 0x81                  | INT 0x82                   |
| IVT entry       | 0x0000:0x0204             | 0x0000:0x0208              |
| Loaded by       | KERNEL (direct disk I/O)  | KERNEL (via INT 0x81)      |
| Initialized by  | KERNEL calls entry point  | KERNEL calls entry point   |

The IVT entry for INT 0x82 is at offset `0x82 × 4 = 0x0208`.  MNMM writes
its handler address there during initialization, just like FS.BIN does for
INT 0x81.

### 4.2 Interrupt Vector Table

```
Interrupt    IVT Offset    Handler               Service
───────────────────────────────────────────────────────────
INT 0x80     0x0200        KERNEL (0x5000+)      Kernel syscalls
INT 0x81     0x0204        FS.BIN (0x0800+)      Filesystem
INT 0x82     0x0208        MNMM.BIN (0x2800+)    Memory manager  ← NEW
```

### 4.3 Boot Chain Update

The kernel initialization sequence gains one new step:

```
KERNEL init (0x5000):
  1.  Install INT 0x80 handler (kernel syscalls)
  2.  Load FS.BIN → 0x0800 (direct disk I/O via BIOS INT 13h)
  3.  Call FS.BIN init → installs INT 0x81
  4.  Load MNMM.BIN → 0x2800 (via INT 0x81 FS_READ_FILE)      ← NEW
  5.  Call MNMM.BIN init → installs INT 0x82, initializes heap ← NEW
  6.  Load SHELL.BIN → 0x3000 (via INT 0x81 FS_READ_FILE)
  7.  Jump to SHELL.BIN entry point
```

MNMM depends on FS.BIN (to load itself from disk) but has **no runtime
dependency** on FS.  Once loaded and initialized, MNMM operates on pure RAM
with no disk or display I/O.

### 4.4 Dependency Graph

```
                 ┌─────────┐
                 │   MBR   │
                 └────┬────┘
                      │ loads
                 ┌────▼────┐
                 │   VBR   │
                 └────┬────┘
                      │ loads
                 ┌────▼────┐
                 │ LOADER  │
                 └────┬────┘
                      │ loads
                 ┌────▼────┐
          ┌──────│ KERNEL  │──────────┐──────────┐
          │      └─────────┘          │          │
          │ loads (direct)     loads (INT 0x81)  │ loads (INT 0x81)
     ┌────▼────┐          ┌────▼────┐       ┌────▼────┐
     │ FS.BIN  │          │MNMM.BIN │       │ SHELL   │
     │INT 0x81 │          │INT 0x82 │       │         │
     └─────────┘          └─────────┘       └─────────┘
          │                    │                 │
          │  FS depends on     │  MNMM has NO    │  SHELL may use
          │  INT 0x80 for      │  runtime deps   │  INT 0x80 (kernel)
          │  disk I/O          │  (pure RAM)     │  INT 0x81 (FS)
          │                    │                 │  INT 0x82 (memory)
          └────────────────────┴─────────────────┘
```

---

## 5. Heap Layout

### 5.1 Initial State

When MNMM initializes, the entire heap is a single free block:

```
0x8000                                                          0xF800
┌───────────────────────────────────────────────────────────────────┐
│                                                                   │
│                     One Free Block (30,720 bytes)                 │
│                                                                   │
│  Header (4 bytes)          Usable space (30,716 bytes)           │
│  ┌──────────────┐  ┌────────────────────────────────────────┐    │
│  │ size = 30720 │  │           (uninitialized)               │    │
│  │ flags = FREE │  │                                         │    │
│  │ magic = 'M'  │  │                                         │    │
│  │              │  │  next_free = 0x0000 (end of list)       │    │
│  └──────────────┘  └────────────────────────────────────────┘    │
└───────────────────────────────────────────────────────────────────┘
```

### 5.2 Block Structure

Every block — whether allocated or free — begins with a 4-byte **block header**:

```
Offset   Size   Field           Description
───────────────────────────────────────────────────────────────
+0       2 B    block_size      Total size in bytes (header + data)
+2       1 B    flags           Bit 0: 1 = allocated, 0 = free
+3       1 B    magic           Always 0x4D ('M') — corruption detector
```

**Why 4 bytes?**  It's the minimum needed to track a block reliably.  The
2-byte size field supports blocks up to 65,535 bytes (well beyond our 30 KB
heap).  The magic byte catches corruption — if a pointer is invalid or a buffer
overflows into an adjacent block header, the magic byte will be wrong.

#### 5.2.1 Free Block Layout

A free block stores the **next free pointer** in the first 2 bytes of its data
area.  This means the minimum block size is 6 bytes (4-byte header + 2-byte
next pointer), rounded up to 8 for alignment:

```
  ┌─────────────────────────────────────────────────────┐
  │  +0:  block_size  (2 bytes)                         │
  │  +2:  flags = 0x00 (free)                           │  HEADER
  │  +3:  magic = 0x4D ('M')                            │
  ├─────────────────────────────────────────────────────┤
  │  +4:  next_free   (2 bytes) — offset of next free   │  DATA AREA
  │  +6:  (unused padding to meet alignment)            │  (minimum 4 B)
  │  ...                                                │
  └─────────────────────────────────────────────────────┘
```

#### 5.2.2 Allocated Block Layout

An allocated block has no free-list pointer.  The entire data area after the
header belongs to the caller:

```
  ┌─────────────────────────────────────────────────────┐
  │  +0:  block_size  (2 bytes)                         │
  │  +2:  flags = 0x01 (allocated)                      │  HEADER
  │  +3:  magic = 0x4D ('M')                            │
  ├─────────────────────────────────────────────────────┤
  │  +4:  ┌───────────────────────────────────────┐     │
  │       │  USER DATA (block_size - 4 bytes)     │     │  ← returned pointer
  │       │                                       │     │
  │       └───────────────────────────────────────┘     │
  └─────────────────────────────────────────────────────┘
```

The pointer returned to the caller is `block_address + 4`.  The caller never
sees the header.

#### 5.2.3 Minimum Block Size

```
Minimum block size = header (4) + next_free pointer (2) + padding (2) = 8 bytes
Minimum usable allocation = 8 - 4 = 4 bytes
```

Any allocation request for fewer than 4 bytes still uses an 8-byte block.
This wastes at most 4 bytes per tiny allocation — acceptable for simplicity.

### 5.3 Free List

MNMM maintains a **singly-linked free list** sorted by address (ascending).
Address-ordered sorting is critical for efficient coalescing (§7.2).

```
free_list ──→ [Free block A] ──→ [Free block B] ──→ [Free block C] ──→ NULL
               (lowest addr)                          (highest addr)
```

**Invariants** (must always hold):

1. Every block on the free list has `flags = 0` and `magic = 0x4D`.
2. Free blocks are sorted by ascending address.
3. No two adjacent free blocks exist — they must be coalesced.
4. Every free block has `block_size >= 8`.
5. `free_list = 0x0000` means the heap is completely full.

### 5.4 Example: After Several Operations

After allocating 64 bytes, 128 bytes, and then freeing the 64-byte block:

```
0x8000          0x8048      0x80CC                                0xF800
┌──────────────┬────────────┬──────────────────────────────────────┐
│ FREE (72 B)  │ ALLOC      │ FREE (remaining ~30,580 B)          │
│              │ (132 B)    │                                      │
│ hdr: 72      │ hdr: 132   │ hdr: 30580                          │
│ flg: FREE    │ flg: ALLOC │ flg: FREE                           │
│ mgc: 'M'     │ mgc: 'M'   │ mgc: 'M'                            │
│ nxt: →0x80CC │            │ nxt: NULL                            │
└──────────────┴────────────┴──────────────────────────────────────┘

free_list → 0x8000 → 0x80CC → NULL
```

Note: The 64-byte request became a 72-byte block (64 + 4 header, rounded to
8-byte alignment = 68, then... actually 64 + 4 = 68, rounded to 72).

---

## 6. Allocation Algorithm

### 6.1 Overview: First-Fit

MNMM uses **first-fit**: walk the free list from the beginning, and use the
first block whose size is ≥ the requested amount.

**Why first-fit?**

| Algorithm   | Pros                           | Cons                       |
|-------------|--------------------------------|----------------------------|
| First-fit   | Fast (stops at first match)    | Tends to fragment the front |
| Best-fit    | Minimizes wasted space         | Slow (must scan entire list)|
| Worst-fit   | Leaves large remainders        | Fastest fragmentation       |
| Next-fit    | Distributes fragments evenly   | More complex (cursor state) |

First-fit is the classic educational choice.  It's fast, simple, and
well-studied.  The free list is short (30 KB / 8-byte minimum = 3,840 blocks
absolute maximum, but typically < 50 in practice).

### 6.2 Algorithm Steps

```
MEM_ALLOC(requested_bytes):
    1.  If requested_bytes == 0, return error (CF set, AX = 0)

    2.  Compute actual block size:
            actual = requested_bytes + 4          (add header)
            actual = ALIGN_UP(actual, 8)          (round to 8-byte boundary)
            if actual < 8: actual = 8             (enforce minimum)

    3.  Walk the free list (prev = NULL, curr = free_list):
            while curr != NULL:
                if curr->block_size >= actual:
                    goto FOUND
                prev = curr
                curr = curr->next_free

    4.  If no block found: return error (CF set, AX = 0)

    5.  FOUND — decide whether to split:
            remainder = curr->block_size - actual
            if remainder >= 8:
                SPLIT: create new free block at (curr + actual)
            else:
                NO SPLIT: use entire block (waste remainder bytes)

    6.  Remove curr from free list (or replace with split block)

    7.  Mark curr as allocated:
            curr->block_size = actual  (or unchanged if no split)
            curr->flags = 0x01
            curr->magic = 0x4D

    8.  Return pointer = curr + 4 (past header)
            AX = pointer, CF clear
```

### 6.3 Block Splitting

When a free block is larger than needed, MNMM **splits** it into two:

```
BEFORE (free block, 200 bytes):
┌──────────────────────────────────────────────────┐
│ hdr: 200 | FREE | 'M' | next_free | ... unused  │
└──────────────────────────────────────────────────┘

AFTER allocating 64 bytes (actual = 72 with header + alignment):

┌───────────────────┬──────────────────────────────┐
│ ALLOCATED (72 B)  │ FREE (128 B)                 │
│ hdr: 72           │ hdr: 128                     │
│ flg: ALLOC        │ flg: FREE                    │
│ mgc: 'M'          │ mgc: 'M'                     │
│ (user data: 68B)  │ nxt: (inherits old next_free)│
└───────────────────┴──────────────────────────────┘
```

The split only occurs if the remainder is ≥ 8 bytes (minimum block size).
Otherwise, the entire free block is used, wasting at most 7 bytes — the
**internal fragmentation** ceiling.

### 6.4 Alignment

All block sizes are rounded up to multiples of 8 bytes.  This ensures:

1. **Word-aligned access** — 16-bit reads/writes are always aligned.
2. **DWORD-aligned data** — Useful if storing 32-bit values.
3. **Predictable layout** — Block boundaries are always at 0x8000, 0x8008,
   0x8010, etc.

The alignment formula in NASM:

```nasm
; Round BX up to next multiple of 8
    add bx, 7              ; BX = requested + 7
    and bx, 0xFFF8         ; clear bottom 3 bits
```

### 6.5 Walk-Through Example

Starting from a fresh heap (one 30,720-byte free block):

**Step 1: Allocate 100 bytes**

```
requested = 100
actual = 100 + 4 = 104, ALIGN_UP(104, 8) = 104  (already aligned)

Free block at 0x8000 (size 30720) >= 104 ✓
Remainder = 30720 - 104 = 30616 >= 8 ✓ → SPLIT

Result:
  0x8000: ALLOC, size=104, user_ptr=0x8004 (100 bytes usable)
  0x8068: FREE,  size=30616, next=NULL

Returned: AX = 0x8004
```

**Step 2: Allocate 256 bytes**

```
requested = 256
actual = 256 + 4 = 260, ALIGN_UP(260, 8) = 264

Free block at 0x8068 (size 30616) >= 264 ✓ → SPLIT

Result:
  0x8000: ALLOC, size=104
  0x8068: ALLOC, size=264, user_ptr=0x806C (260 bytes usable)
  0x8170: FREE,  size=30352, next=NULL

Returned: AX = 0x806C
```

**Step 3: Free the 100-byte allocation (pointer 0x8004)**

```
Block header at 0x8004 - 4 = 0x8000
Validate: magic = 'M' ✓, flags = ALLOC ✓, within heap bounds ✓

Mark free, coalesce with neighbors:
  Previous: none (0x8000 is heap start)
  Next block at 0x8000 + 104 = 0x8068: ALLOC → no coalesce

Result:
  0x8000: FREE,  size=104, next=0x8170
  0x8068: ALLOC, size=264
  0x8170: FREE,  size=30352, next=NULL

free_list → 0x8000 → 0x8170 → NULL
```

**Step 4: Free the 256-byte allocation (pointer 0x806C)**

```
Block header at 0x806C - 4 = 0x8068
Validate: magic = 'M' ✓, flags = ALLOC ✓

Mark free, coalesce:
  Previous free block: 0x8000, ends at 0x8000 + 104 = 0x8068 → ADJACENT! → merge
  Next block at 0x8068 + 264 = 0x8170: FREE → ADJACENT! → merge

Triple merge: 0x8000 absorbs 0x8068 and 0x8170
  New size = 104 + 264 + 30352 = 30720 (original heap size!)

Result:
  0x8000: FREE, size=30720, next=NULL

Heap is fully recovered — zero fragmentation.
```

This demonstrates how **immediate coalescing** prevents fragmentation when
allocations are freed in any order.

---

## 7. Free Algorithm

### 7.1 Validation

Before freeing, MNMM performs four safety checks:

```
MEM_FREE(user_ptr):
    1.  If user_ptr == 0: no-op (return success)
        Rationale: like C's free(NULL), this is safe and convenient.

    2.  Compute block_addr = user_ptr - 4
        Check: block_addr >= heap_start AND block_addr < heap_end
        If not: error — pointer outside heap bounds

    3.  Check: block_addr->magic == 0x4D ('M')
        If not: error — corrupted header or invalid pointer

    4.  Check: block_addr->flags == 0x01 (allocated)
        If flags == 0x00: error — double free detected
        If flags is any other value: error — corruption
```

Each check catches a different class of bug:

| Check              | Catches                                          |
|--------------------|--------------------------------------------------|
| NULL pointer       | Accidental free of uninitialized pointer          |
| Bounds check       | Free of stack variable, code address, etc.        |
| Magic number       | Buffer overflow into adjacent block header        |
| Flags check        | Double free, free of padding bytes                |

### 7.2 Coalescing

After validation, the freed block must be **merged with any adjacent free
blocks** to prevent fragmentation.  This is the most complex part of the
allocator.

Because the free list is sorted by address, we can find the **predecessor**
(the free block just before our block in memory) and the **successor** (the
free block just after) by walking the free list:

```
COALESCE(block):
    Walk free list to find insertion point:
        prev_free = last free block with address < block
        next_free = first free block with address > block

    Case 1: Neither neighbor is adjacent
        Insert block into free list between prev_free and next_free

    Case 2: Next block is adjacent (block + block->size == next_free)
        Merge: block->size += next_free->size
        Remove next_free from free list

    Case 3: Previous block is adjacent (prev_free + prev_free->size == block)
        Merge: prev_free->size += block->size
        (block is absorbed — not inserted into free list)

    Case 4: Both neighbors are adjacent
        Merge all three into prev_free:
        prev_free->size += block->size + next_free->size
        Remove next_free from free list
```

### 7.3 Coalescing Diagram

```
BEFORE free(B):

free_list → [A (free)] ───→ [C (free)] ───→ NULL

     A (FREE)        B (ALLOC)        C (FREE)        D (ALLOC)
  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐
  │ size: 100  │  │ size: 200  │  │ size: 300  │  │ size: 400  │
  │ FREE       │  │ ALLOC      │  │ FREE       │  │ ALLOC      │
  └────────────┘  └────────────┘  └────────────┘  └────────────┘
  ^               ^               ^
  A_addr          B_addr          C_addr

  A_addr + 100 == B_addr?  YES → A is adjacent to B
  B_addr + 200 == C_addr?  YES → B is adjacent to C
  → Case 4: triple merge!

AFTER free(B):

free_list → [A (free, size=600)] ───→ NULL

     A+B+C (FREE)                                    D (ALLOC)
  ┌─────────────────────────────────────────────┐  ┌────────────┐
  │ size: 600  (100 + 200 + 300)                │  │ size: 400  │
  │ FREE                                        │  │ ALLOC      │
  └─────────────────────────────────────────────┘  └────────────┘
```

### 7.4 Why Address-Ordered Free List?

An **unordered** free list (insert at head) would be simpler for `free()` — just
prepend the block.  But coalescing becomes O(n²) because you'd have to scan the
entire list to find adjacent blocks.

An **address-ordered** free list makes coalescing O(n) — you walk the list once
to find the insertion point, and the predecessor/successor are immediately
available for adjacency checks.

The cost is that `free()` requires a linear scan to find the insertion point.
But with a 30 KB heap and typical allocation patterns, the free list rarely
exceeds a few dozen entries.  The scan is trivially fast.

---

## 8. Syscall Reference — INT 0x82

### 8.1 Overview

```
┌───────────────────────────────────────────────────────────────┐
│                   INT 0x82 — Memory Manager                   │
├──────┬────────────────┬──────────────────┬────────────────────┤
│  AH  │  Function      │  Input           │  Output            │
├──────┼────────────────┼──────────────────┼────────────────────┤
│ 0x01 │ MEM_ALLOC      │ BX = size (bytes)│ AX = ptr (0=fail)  │
│ 0x02 │ MEM_FREE       │ BX = ptr         │ CF = error         │
│ 0x03 │ MEM_AVAIL      │ (none)           │ AX = largest free  │
│      │                │                  │ BX = total free    │
│ 0x04 │ MEM_INFO       │ (none)           │ AX = heap start    │
│      │                │                  │ BX = heap end      │
│      │                │                  │ CX = alloc count   │
│      │                │                  │ DX = free count    │
└──────┴────────────────┴──────────────────┴────────────────────┘
```

### 8.2 MEM_ALLOC (AH = 0x01)

Allocate a contiguous block of memory.

```
Input:
    AH    = 0x01
    BX    = requested size in bytes (1–30716)

Output (success):
    AX    = pointer to usable memory (block_addr + 4)
    CF    = clear

Output (failure):
    AX    = 0x0000
    CF    = set

Failure reasons:
    - BX = 0 (zero-size allocation)
    - No free block large enough (out of memory / fragmented)
```

**Usage example:**

```nasm
; Allocate a 512-byte buffer for file I/O
    mov ah, 0x01            ; MEM_ALLOC
    mov bx, 512             ; request 512 bytes
    int 0x82
    jc .alloc_failed        ; CF set = out of memory
    mov [file_buf], ax      ; save pointer

    ; Use the buffer...
    mov di, [file_buf]
    mov byte [di], 'H'      ; write to allocated memory

.alloc_failed:
    ; Handle error — print message, etc.
```

**Behavior notes:**

- The returned pointer is **always 8-byte aligned** and points past the
  internal 4-byte header.  The caller does not see or manage the header.
- Allocated memory is **not zeroed** in release builds.  Contents are
  undefined.  In debug builds, memory is filled with `0xCC` (see §10.1).
- The actual allocated size may be slightly larger than requested (due to
  alignment rounding).  The caller must not depend on this.

### 8.3 MEM_FREE (AH = 0x02)

Release a previously allocated block back to the heap.

```
Input:
    AH    = 0x02
    BX    = pointer returned by MEM_ALLOC

Output (success):
    CF    = clear

Output (failure):
    CF    = set
    AX    = error code:
            0x01 = pointer outside heap bounds
            0x02 = corrupted block header (bad magic)
            0x03 = double free (block already free)

Special case:
    BX = 0x0000 → no-op (success, CF clear)
```

**Usage example:**

```nasm
; Free the file buffer
    mov ah, 0x02            ; MEM_FREE
    mov bx, [file_buf]      ; pointer from MEM_ALLOC
    int 0x82
    jc .free_failed         ; shouldn't happen unless heap corrupted
    mov word [file_buf], 0  ; NULL out the pointer (good practice)

.free_failed:
    ; AX = error code — log or halt
```

**Behavior notes:**

- Freeing NULL (BX = 0) is always safe and does nothing.  This matches the
  C convention and simplifies cleanup paths.
- In debug builds, freed memory is filled with `0xDD` (see §10.1) to catch
  use-after-free bugs.
- The block is immediately coalesced with any adjacent free blocks.
- After freeing, the pointer is **invalid**.  Any access through it is a bug.

### 8.4 MEM_AVAIL (AH = 0x03)

Query available memory without allocating.

```
Input:
    AH    = 0x03

Output:
    AX    = size of largest contiguous free block (bytes, usable)
    BX    = total free memory across all free blocks (bytes, usable)
    CF    = clear (always succeeds)
```

The "usable" values subtract the 4-byte header from each free block's size.
This tells the caller the maximum they can allocate (AX) and total available
(BX), matching what `MEM_ALLOC` would actually give them.

**Usage example:**

```nasm
; Check available memory before a large allocation
    mov ah, 0x03            ; MEM_AVAIL
    int 0x82
    cmp ax, 4096            ; need 4 KB contiguous
    jb .not_enough
    ; Proceed with allocation...

.not_enough:
    ; Print "Insufficient memory" message
```

**Shell integration** — The `mem` or `sysinfo` command could use this to
display heap statistics:

```
mnos:\> mem
Heap:   0x8000 – 0xF7FF  (30 KB)
Used:   1,280 bytes  (5 blocks)
Free:   29,440 bytes (largest: 28,672 bytes)
```

### 8.5 MEM_INFO (AH = 0x04)

Return detailed heap metadata for diagnostics.

```
Input:
    AH    = 0x04

Output:
    AX    = heap start address (0x8000)
    BX    = heap end address (0xF800, exclusive)
    CX    = number of allocated blocks
    DX    = number of free blocks
    CF    = clear (always succeeds)
```

**Usage example — heap walk in `mnmon`:**

```
*8000
0x8000:  48 00 01 4D  48 65 6C 6C   H..MHell  ← Block: size=72, ALLOC, magic='M'
         6F 20 57 6F  72 6C 64 00   o World.     Data: "Hello World"
```

The first two bytes (`48 00` = 0x0048 = 72) are the block size.  The third byte
(`01`) is the allocated flag.  The fourth byte (`4D` = 'M') is the magic.
Everything after offset +4 is user data.  This is inspectable with `mnmon`
at any time.

---

## 9. Edge Cases & Error Handling

### 9.1 Zero-Size Allocation

```
MEM_ALLOC(BX = 0)  →  CF set, AX = 0
```

**Rationale:** A zero-size allocation is meaningless.  Rather than returning a
valid pointer to zero bytes (which C `malloc(0)` does on some platforms), MNMM
treats it as an error.  This catches bugs where a size variable was
accidentally zero.

### 9.2 Oversized Allocation

```
MEM_ALLOC(BX = 31000)  →  CF set, AX = 0  (heap is only 30,720 bytes)
```

Even with a completely empty heap, the maximum usable allocation is
`30720 - 4 = 30716` bytes (the 4-byte header is overhead).  Any request
larger than the largest free block (minus 4) will fail.

### 9.3 Fragmentation Failure

```
Scenario: Total free = 10,000 bytes, but split across 20 small blocks.
MEM_ALLOC(BX = 5000) → CF set, AX = 0
```

Even though there's enough total memory, no single contiguous block is large
enough.  This is **external fragmentation** — the defining weakness of
variable-size allocators.  MNMM's coalescing mitigates this but cannot
eliminate it entirely.

**Mitigation strategies** (for the programmer, not the allocator):

1. **Allocate early, free late** — reduce interleaving
2. **Use fixed-size pools** for same-type objects
3. **Reuse buffers** instead of alloc/free cycles
4. **Use `MEM_AVAIL`** to check before large allocations

### 9.4 Double Free

```
MEM_FREE(ptr) → success
MEM_FREE(ptr) → CF set, AX = 0x03 (double free)
```

The second call sees `flags = 0x00` (already free) and returns an error.
This catches a common class of bugs immediately, rather than silently
corrupting the free list.

### 9.5 Invalid Pointer

```
MEM_FREE(0x5000) → CF set, AX = 0x01  (0x5000 is KERNEL, not heap)
MEM_FREE(0x1234) → CF set, AX = 0x01  (random address)
```

The bounds check (`heap_start <= ptr - 4 < heap_end`) catches any pointer
that doesn't fall within the managed region.

### 9.6 Corrupted Header

```
; Bug: buffer overflow writes past allocation into next header
MEM_FREE(next_block) → CF set, AX = 0x02 (bad magic)
```

If a buffer overflow corrupts the header of an adjacent block, the magic byte
(`0x4D`) will be overwritten.  MEM_FREE detects this and refuses to operate
on the corrupted block.

**Important limitation:** MNMM detects corruption on the block being freed,
but it cannot detect corruption on *other* blocks until they are freed or
examined.  The heap walk (§10.3) scans all blocks and is the definitive
corruption detector.

### 9.7 Allocation During Interrupt

MNMM is **not reentrant**.  If an interrupt handler calls `MEM_ALLOC` while
a user-mode `MEM_ALLOC` is in progress, the free list could be corrupted.

**Rule:** Do not call INT 0x82 from within an interrupt handler (INT 0x80 or
INT 0x81 handlers).  Only call from "user mode" code (SHELL or loaded
programs).

In practice, this is not a problem because:
- Kernel syscalls (INT 0x80) don't need dynamic memory
- FS syscalls (INT 0x81) use their own static buffer
- Only SHELL (and future user programs) call INT 0x82

If reentrancy becomes necessary in the future, MNMM would need to disable
interrupts (CLI) around free list mutations — a 4-instruction change.

### 9.8 Heap Exhaustion Recovery

When `MEM_ALLOC` fails:

1. The heap is unchanged — no partial allocation occurred.
2. The caller receives CF set and AX = 0.
3. The caller should:
   - Free any unnecessary allocations
   - Try a smaller allocation
   - Or report "out of memory" to the user

There is no automatic garbage collection, compaction, or swap file.  If the
heap is full, the only remedy is to free existing allocations.

---

## 10. Debug Support

### 10.1 Fill Patterns

In debug builds (`-dDEBUG`), MNMM fills allocated and freed memory with
recognizable byte patterns:

| Operation     | Fill byte | Pattern         | Purpose                    |
|---------------|-----------|-----------------|----------------------------|
| After alloc   | `0xCC`    | `CC CC CC CC…`  | Detect use-before-init     |
| After free    | `0xDD`    | `DD DD DD DD…`  | Detect use-after-free      |
| Guard zone    | `0xFD`    | `FD FD FD FD…`  | Detect buffer overflow     |

These patterns are chosen to be:
- **Distinctive in `mnmon`** — easy to spot in a hex dump
- **Likely to crash if executed** — `0xCC` is `INT 3` (breakpoint) on x86,
  `0xDD` and `0xFD` are invalid/unusual opcodes
- **Historical** — Microsoft's MSVC CRT uses the same values for the same
  purposes (`_CLEAN_BLOCK`, `_DEAD_BLOCK`, `_ALIGNMENT_BLOCK`)

**Example:** Inspecting freed memory in `mnmon`:

```
*8004
0x8004:  DD DD DD DD  DD DD DD DD   ........  ← This memory was freed
0x800C:  DD DD DD DD  DD DD DD DD   ........     All 0xDD = use-after-free
```

**Implementation:**

```nasm
%ifdef DEBUG
; Fill CX bytes at ES:DI with AL
.fill_block:
    cld
    rep stosb
    ret
%endif
```

### 10.2 Serial Logging

In debug builds, every allocation and free is logged to the serial port:

```
[MNMM] alloc 512 → 0x806C (blk=516 free=29204)
[MNMM] alloc 100 → 0x8274 (blk=104 free=29100)
[MNMM] free  0x806C (blk=516 free=29616 coal=0)
[MNMM] free  0x8274 (blk=104 free=30720 coal=2)   ← coalesced with 2 neighbors
[MNMM] alloc 40000 → FAIL (largest=30716 total=30716)
```

Each log line shows:
- Operation (alloc/free)
- Size requested (alloc) or pointer (free)
- Result pointer (alloc) or block size recovered (free)
- Running total free bytes
- Coalescing count (free)

### 10.3 Heap Walk

A **heap walk** iterates over every block in the heap sequentially (by
address, not by free list).  This is possible because blocks are contiguous —
the next block starts at `current + current->block_size`.

```
HEAP_WALK:
    addr = heap_start
    while addr < heap_end:
        validate: addr->magic == 0x4D
        print: address, size, status (alloc/free)
        addr = addr + addr->block_size
```

If a magic byte is wrong, the walk stops and reports corruption at that
address.

**`mnmon` integration:**

A dedicated `mnmon` command (e.g., `h` for heap) could invoke the heap walk:

```
*h
MNMM Heap Walk (0x8000 - 0xF7FF):
  0x8000:  72 B  ALLOC
  0x8048: 264 B  ALLOC
  0x8150:  48 B  FREE
  0x8180: 30400 B  FREE
Total: 4 blocks (2 alloc, 2 free), 336 B used, 30384 B free
```

This is invaluable for debugging fragmentation, leaks, and corruption.

### 10.4 Heap Visualization

For the truly adventurous, a graphical heap map using VGA text characters:

```
mnos:\> heapmap
0x8000 ████████░░░░████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
       ^^^^^^^^    ^^^^                                     free
       alloc       alloc

█ = allocated    ░ = free    Each char = ~512 bytes
```

This is a future enhancement — probably v0.9.0 — but worth designing for.

---

## 11. Implementation Reference

### 11.1 MNMM Data Segment

```nasm
; ─── MNMM internal data (within MNMM.BIN at 0x2800) ───────────
MNMM_HEAP_START  equ 0x8000     ; first byte of managed heap
MNMM_HEAP_END    equ 0xF800     ; first byte past heap (exclusive)
MNMM_HEAP_SIZE   equ (MNMM_HEAP_END - MNMM_HEAP_START)  ; 30720
MNMM_MIN_BLOCK   equ 8          ; minimum block size (bytes)
MNMM_MAGIC       equ 0x4D       ; 'M' — block header magic
MNMM_FLAG_FREE   equ 0x00
MNMM_FLAG_ALLOC  equ 0x01

; ─── Block header offsets ──────────────────────────────────────
BLK_SIZE         equ 0          ; word: total block size
BLK_FLAGS        equ 2          ; byte: 0=free, 1=allocated
BLK_MAGIC        equ 3          ; byte: always 0x4D
BLK_NEXT_FREE    equ 4          ; word: next free block (free blocks only)
BLK_HEADER_SIZE  equ 4          ; header is 4 bytes

; ─── MNMM state ───────────────────────────────────────────────
free_list_head:  dw 0           ; offset of first free block (0 = empty)
```

### 11.2 Initialization

```nasm
; ─── mnmm_init ────────────────────────────────────────────────
; Called once by KERNEL during boot.
; Creates one free block spanning the entire heap.
; Installs INT 0x82 handler in IVT.
;
; Input:  none
; Output: none
; Clobbers: AX, DI
; ──────────────────────────────────────────────────────────────
mnmm_init:
    ; Install INT 0x82 handler
    xor ax, ax
    mov es, ax
    mov word [es:0x0208], mnmm_isr      ; offset
    mov word [es:0x020A], cs             ; segment (= 0x0000)

    ; Initialize heap: one big free block
    mov di, MNMM_HEAP_START
    mov word [di + BLK_SIZE], MNMM_HEAP_SIZE
    mov byte [di + BLK_FLAGS], MNMM_FLAG_FREE
    mov byte [di + BLK_MAGIC], MNMM_MAGIC
    mov word [di + BLK_NEXT_FREE], 0     ; end of free list

    mov word [free_list_head], di

%ifdef DEBUG
    ; Fill heap data area with 0xCC (uninitialized marker)
    push di
    add di, BLK_HEADER_SIZE + 2          ; skip header + next_free
    mov cx, MNMM_HEAP_SIZE - BLK_HEADER_SIZE - 2
    mov al, 0xCC
    cld
    rep stosb
    pop di

    ; Log initialization
    DBG "[MNMM] init heap=0x8000-0xF7FF (30720 B)"
%endif

    ret
```

### 11.3 INT 0x82 Dispatcher

```nasm
; ─── mnmm_isr ────────────────────────────────────────────────
; Software interrupt handler for INT 0x82.
; Dispatches to function based on AH register.
;
; AH=0x01: MEM_ALLOC    AH=0x02: MEM_FREE
; AH=0x03: MEM_AVAIL    AH=0x04: MEM_INFO
; ──────────────────────────────────────────────────────────────
mnmm_isr:
    cmp ah, 0x01
    je .do_alloc
    cmp ah, 0x02
    je .do_free
    cmp ah, 0x03
    je .do_avail
    cmp ah, 0x04
    je .do_info
    stc                     ; unknown function → error
    iret

.do_alloc:
    call mnmm_alloc
    iret

.do_free:
    call mnmm_free
    iret

.do_avail:
    call mnmm_avail
    iret

.do_info:
    call mnmm_info
    iret
```

Note: `MEM_ALLOC` and `MEM_FREE` need to return CF to the caller.  Like the
kernel's `syscall_ret_cf` macro (see SYSTEM-CALLS.md §7.3.2), the dispatcher
must use `sti; retf 2` instead of `iret` for CF-returning functions, or the
handler must manipulate the FLAGS word on the stack.

The recommended approach is to manipulate FLAGS on the stack:

```nasm
.do_alloc:
    call mnmm_alloc
    ; Propagate CF to caller's flags on stack
    pushf
    pop ax                  ; AX = current flags
    and word [sp+4], ~0x01  ; clear CF in saved FLAGS on stack
    push ax
    popf
    jnc .alloc_noerr
    or word [sp+4], 0x01    ; set CF in saved FLAGS
.alloc_noerr:
    iret
```

Or more simply, use the same `syscall_ret_cf` macro from the kernel:

```nasm
%macro syscall_ret_cf 0
    sti
    retf 2                  ; skip saved FLAGS — use current CF
%endmacro
```

### 11.4 Allocation Core

```nasm
; ─── mnmm_alloc ───────────────────────────────────────────────
; First-fit allocation with block splitting.
;
; Input:  BX = requested size in bytes
; Output: AX = pointer to user data (0 on failure)
;         CF = set on failure, clear on success
; Clobbers: CX, DX, SI, DI
; ──────────────────────────────────────────────────────────────
mnmm_alloc:
    ; Reject zero-size
    test bx, bx
    jz .fail

    ; Compute actual block size (add header, align to 8)
    add bx, BLK_HEADER_SIZE        ; add 4-byte header
    add bx, 7                      ; prepare for alignment
    and bx, 0xFFF8                 ; round up to 8-byte boundary
    cmp bx, MNMM_MIN_BLOCK
    jae .size_ok
    mov bx, MNMM_MIN_BLOCK        ; enforce minimum
.size_ok:

    ; First-fit search
    xor si, si                     ; SI = prev free block (0 = none)
    mov di, [free_list_head]       ; DI = current free block

.search:
    test di, di
    jz .fail                       ; end of free list — no memory

    cmp [di + BLK_SIZE], bx        ; current->size >= needed?
    jae .found

    mov si, di                     ; prev = current
    mov di, [di + BLK_NEXT_FREE]   ; current = current->next_free
    jmp .search

.found:
    ; Check if we can split
    mov ax, [di + BLK_SIZE]        ; AX = current block size
    mov cx, ax
    sub cx, bx                     ; CX = remainder after split
    cmp cx, MNMM_MIN_BLOCK         ; room for a new block?
    jb .no_split

    ; ─── SPLIT ─────────────────────────────────────────────
    ; Create new free block at (DI + BX)
    mov dx, di
    add dx, bx                     ; DX = remainder block address

    mov [dx + BLK_SIZE], cx        ; remainder.size = leftover
    mov byte [dx + BLK_FLAGS], MNMM_FLAG_FREE
    mov byte [dx + BLK_MAGIC], MNMM_MAGIC
    mov ax, [di + BLK_NEXT_FREE]   ; inherit next_free from current
    mov [dx + BLK_NEXT_FREE], ax

    ; Update free list: replace current with remainder
    test si, si
    jz .split_head
    mov [si + BLK_NEXT_FREE], dx   ; prev->next = remainder
    jmp .mark_alloc
.split_head:
    mov [free_list_head], dx       ; free_list = remainder
    jmp .mark_alloc

.no_split:
    ; ─── USE ENTIRE BLOCK ──────────────────────────────────
    mov bx, ax                     ; use full block size (no remainder)
    mov ax, [di + BLK_NEXT_FREE]   ; get next_free
    test si, si
    jz .nosplit_head
    mov [si + BLK_NEXT_FREE], ax   ; prev->next = current->next
    jmp .mark_alloc
.nosplit_head:
    mov [free_list_head], ax       ; free_list = current->next

.mark_alloc:
    ; Mark block as allocated
    mov [di + BLK_SIZE], bx
    mov byte [di + BLK_FLAGS], MNMM_FLAG_ALLOC
    mov byte [di + BLK_MAGIC], MNMM_MAGIC

%ifdef DEBUG
    ; Fill user data with 0xCC (uninitialized)
    push di
    push cx
    lea di, [di + BLK_HEADER_SIZE]
    mov cx, bx
    sub cx, BLK_HEADER_SIZE
    mov al, 0xCC
    cld
    rep stosb
    pop cx
    pop di
%endif

    ; Return pointer to user data
    lea ax, [di + BLK_HEADER_SIZE]
    clc                            ; success
    ret

.fail:
    xor ax, ax                     ; AX = 0
    stc                            ; CF = error
    ret
```

### 11.5 Free Core

```nasm
; ─── mnmm_free ────────────────────────────────────────────────
; Free an allocated block with immediate coalescing.
;
; Input:  BX = pointer returned by MEM_ALLOC (or 0 for no-op)
; Output: CF = set on error, clear on success
;         AX = error code on failure (see §8.3)
; Clobbers: CX, DX, SI, DI
; ──────────────────────────────────────────────────────────────
mnmm_free:
    ; Free(NULL) is a no-op
    test bx, bx
    jz .ok

    ; Compute block address from user pointer
    sub bx, BLK_HEADER_SIZE        ; BX = block header address

    ; Bounds check
    cmp bx, MNMM_HEAP_START
    jb .err_bounds
    cmp bx, MNMM_HEAP_END
    jae .err_bounds

    ; Magic check
    cmp byte [bx + BLK_MAGIC], MNMM_MAGIC
    jne .err_corrupt

    ; Double-free check
    cmp byte [bx + BLK_FLAGS], MNMM_FLAG_ALLOC
    jne .err_double

    ; Mark as free
    mov byte [bx + BLK_FLAGS], MNMM_FLAG_FREE

%ifdef DEBUG
    ; Fill user data with 0xDD (freed marker)
    push bx
    push cx
    mov di, bx
    add di, BLK_HEADER_SIZE
    mov cx, [bx + BLK_SIZE]
    sub cx, BLK_HEADER_SIZE
    mov al, 0xDD
    cld
    rep stosb
    pop cx
    pop bx
%endif

    ; ─── COALESCE ──────────────────────────────────────────
    ; Find insertion point in address-ordered free list
    ; SI = prev free block (0 = none), DI = next free block
    xor si, si
    mov di, [free_list_head]

.find_insert:
    test di, di
    jz .insert_here                ; end of list
    cmp di, bx
    ja .insert_here                ; found: DI is the first block after BX
    mov si, di
    mov di, [di + BLK_NEXT_FREE]
    jmp .find_insert

.insert_here:
    ; BX goes between SI (prev) and DI (next)

    ; Try coalesce with NEXT (DI)
    mov ax, bx
    add ax, [bx + BLK_SIZE]        ; AX = end of freed block
    cmp ax, di                     ; adjacent to next free block?
    jne .no_coalesce_next

    ; Merge with next: absorb DI into BX
    mov cx, [di + BLK_SIZE]
    add [bx + BLK_SIZE], cx        ; grow our block
    mov di, [di + BLK_NEXT_FREE]   ; skip DI in chain

.no_coalesce_next:
    ; Link BX into free list (BX->next = DI)
    mov [bx + BLK_NEXT_FREE], di

    ; Try coalesce with PREVIOUS (SI)
    test si, si
    jz .no_coalesce_prev           ; no previous block

    mov ax, si
    add ax, [si + BLK_SIZE]        ; AX = end of prev block
    cmp ax, bx                     ; adjacent?
    jne .no_coalesce_prev_link

    ; Merge with prev: absorb BX into SI
    mov cx, [bx + BLK_SIZE]
    add [si + BLK_SIZE], cx        ; grow prev block
    mov ax, [bx + BLK_NEXT_FREE]
    mov [si + BLK_NEXT_FREE], ax   ; prev->next = BX->next
    jmp .ok

.no_coalesce_prev_link:
    ; No merge with prev, but link BX after SI
    mov [si + BLK_NEXT_FREE], bx
    jmp .ok

.no_coalesce_prev:
    ; BX becomes new head of free list
    mov [free_list_head], bx

.ok:
    clc
    ret

.err_bounds:
    mov ax, 0x01
    stc
    ret

.err_corrupt:
    mov ax, 0x02
    stc
    ret

.err_double:
    mov ax, 0x03
    stc
    ret
```

### 11.6 Availability Query

```nasm
; ─── mnmm_avail ───────────────────────────────────────────────
; Scan free list to find total and largest free block.
;
; Input:  none
; Output: AX = largest contiguous free (usable bytes)
;         BX = total free (usable bytes)
; ──────────────────────────────────────────────────────────────
mnmm_avail:
    xor ax, ax                     ; AX = largest = 0
    xor bx, bx                     ; BX = total = 0
    mov di, [free_list_head]

.walk:
    test di, di
    jz .done

    mov cx, [di + BLK_SIZE]
    sub cx, BLK_HEADER_SIZE        ; usable = block_size - header
    add bx, cx                     ; total += usable
    cmp cx, ax
    jbe .not_larger
    mov ax, cx                     ; largest = this block
.not_larger:
    mov di, [di + BLK_NEXT_FREE]
    jmp .walk

.done:
    clc
    ret
```

### 11.7 Info Query

```nasm
; ─── mnmm_info ────────────────────────────────────────────────
; Return heap metadata.
;
; Input:  none
; Output: AX = heap start, BX = heap end
;         CX = alloc block count, DX = free block count
; ──────────────────────────────────────────────────────────────
mnmm_info:
    mov ax, MNMM_HEAP_START
    mov bx, MNMM_HEAP_END
    xor cx, cx                     ; alloc count
    xor dx, dx                     ; free count

    mov di, MNMM_HEAP_START
.walk:
    cmp di, MNMM_HEAP_END
    jae .done
    cmp byte [di + BLK_MAGIC], MNMM_MAGIC
    jne .done                      ; corruption — stop walk

    cmp byte [di + BLK_FLAGS], MNMM_FLAG_ALLOC
    jne .is_free
    inc cx
    jmp .next
.is_free:
    inc dx
.next:
    add di, [di + BLK_SIZE]
    jmp .walk

.done:
    clc
    ret
```

### 11.8 Size Budget

```
Component                 Estimated Size
─────────────────────────────────────────
Constants + data           ~30 bytes
mnmm_init                  ~60 bytes
mnmm_isr (dispatcher)      ~50 bytes
mnmm_alloc                ~140 bytes
mnmm_free                 ~160 bytes
mnmm_avail                 ~40 bytes
mnmm_info                  ~50 bytes
Debug fills (conditional)  ~40 bytes
Debug logging (conditional)~80 bytes
─────────────────────────────────────────
Total (release):          ~530 bytes
Total (debug):            ~650 bytes
```

This fits comfortably in the 2 KB slot at 0x2800, leaving room for future
functions like `MEM_REALLOC` or heap compaction.

---

## 12. Integration Plan

### 12.1 New Files

| File                       | Purpose                                    |
|----------------------------|--------------------------------------------|
| `src/mm/mnmm.asm`         | Memory manager binary (assembles to MNMM.BIN) |
| `src/include/memory.inc`   | MEM_* constants for INT 0x82 callers       |

### 12.2 Modified Files

| File                       | Change                                     |
|----------------------------|--------------------------------------------|
| `src/kernel/kernel.asm`    | Add MNMM.BIN load + init between FS and SHELL |
| `tools/create-disk.ps1`    | Add MNMM.BIN to MNFS directory             |
| `build.bat`                | Assemble `mnmm.asm` → `MNMM.BIN`          |
| `doc/MEMORY-LAYOUT.md`     | Add 0x2800 MNMM.BIN entry, 0x8000 heap     |
| `doc/SYSTEM-CALLS.md`      | Add INT 0x82 reference                     |
| `CHANGELOG.md`             | v0.8.0 entry                               |
| `.copilot-context.md`      | Update component list                      |

### 12.3 Implementation Order

1. **`memory.inc`** — Define `MEM_ALLOC`, `MEM_FREE`, `MEM_AVAIL`, `MEM_INFO`
   constants.  No dependencies.
2. **`mnmm.asm`** — Implement init, dispatcher, alloc, free, avail, info.
   Test with `mnmon` (examine heap at 0x8000).
3. **Build system** — Add NASM assembly step and disk inclusion.
4. **Kernel integration** — Load and initialize MNMM.BIN after FS.BIN.
5. **Shell `mem` command** — Display heap statistics via INT 0x82.
6. **Documentation** — Update all docs.

### 12.4 Testing Strategy

**Unit testing via `mnmon`:**

```
; 1. Verify initial heap state
*8000
0x8000:  00 78 00 4D  00 00 ...     ← size=0x7800=30720, FREE, magic='M'

; 2. Allocate 16 bytes from shell (or hand-enter test code):
;    Deposit a test program at 0x9000:
*9000: B4 01 BB 10 00 CD 82 C3
;    (mov ah,01 / mov bx,16 / int 0x82 / ret)
*9000R
;    Check AX for returned pointer

; 3. Examine allocated block
*8000
0x8000:  18 00 01 4D  ...           ← size=24 (16+4=20, aligned to 24), ALLOC

; 4. Free and verify coalescing
*9010: B4 02 BB 04 80 CD 82 C3
;    (mov ah,02 / mov bx,[returned ptr] / int 0x82 / ret)
*9010R
*8000
0x8000:  00 78 00 4D  ...           ← back to one big free block
```

**Automated test (future):**

A `test_mnmm` shell command could run a battery of alloc/free sequences and
report pass/fail — similar to how real OS kernels have built-in allocator
tests.

---

## 13. Fragmentation Analysis

### 13.1 Best Case: LIFO Allocation

When allocations are freed in **reverse order** (Last-In-First-Out), coalescing
is always possible and the heap returns to one large free block:

```
alloc A → alloc B → alloc C → free C → free B → free A
Result: one free block (perfect, no fragmentation)
```

### 13.2 Worst Case: Alternating Free

When every other allocation is freed, the heap becomes a checkerboard of
small free blocks separated by allocated blocks:

```
alloc A → alloc B → alloc C → alloc D → alloc E
free A → free C → free E

Result:
[FREE] [B alloc] [FREE] [D alloc] [FREE]
```

No coalescing is possible because free blocks are not adjacent.  The largest
free block is smaller than the original, even though total free memory is high.

### 13.3 Quantifying Fragmentation

A useful metric:

```
fragmentation_ratio = 1 - (largest_free / total_free)
```

- `0.0` = no fragmentation (one big free block)
- `1.0` = maximum fragmentation (many tiny blocks, no usable large block)

The `MEM_AVAIL` syscall returns both values, allowing callers to compute this.

### 13.4 Mitigation in Practice

For mini-os with 30 KB of heap and typically < 10 active allocations:

1. **Coalescing handles most cases** — blocks freed adjacent to other free
   blocks are merged immediately.
2. **Short-lived allocations** — most buffers are allocated, used, and freed
   within a single command.  The heap resets between commands.
3. **Fixed-size patterns** — reading files uses a standard 512-byte buffer.
   These produce uniform blocks that fit well into freed slots.

Fragmentation is primarily a problem for long-running systems with diverse
allocation sizes.  A mini-os session is typically short and predictable.

---

## 14. Future Directions

### 14.1 MEM_REALLOC (AH = 0x05)

Resize an existing allocation, copying data if the block must move:

```
Input:  BX = existing pointer, CX = new size
Output: AX = new pointer (may be same or different)
```

This avoids the alloc-copy-free dance for growing buffers.

### 14.2 Named Regions

Associate a 4-byte tag with each allocation for debugging:

```
; Tag allocations by subsystem
mov ah, 0x06            ; MEM_ALLOC_TAGGED
mov bx, 512             ; size
mov cx, 'FS'            ; tag: filesystem
int 0x82
```

The heap walk could then show which subsystem owns each block.

### 14.3 Slab Allocator

For frequently allocated/freed objects of the same size (e.g., 32-byte
directory entries), a **slab allocator** pre-divides a large block into
fixed-size slots.  No headers, no splitting, no coalescing — just bitmap
tracking.

This would be a layer on top of MNMM: allocate a slab from the heap, then
sub-allocate within it.

### 14.4 Memory-Mapped File I/O

Combine MNMM with MNFS to provide `mmap`-like semantics:

```
mov ah, 0x07            ; MEM_MAP_FILE
mov bx, file_handle
int 0x82
; AX = pointer to file contents in heap
```

The manager allocates a buffer, reads the file into it, and returns the
pointer.  A single syscall replaces the alloc + read + offset dance.

### 14.5 Protected Mode Considerations

If mini-os ever moves to protected mode (i386+), the memory manager
architecture changes significantly:

- **Paging** — 4 KB page granularity, page tables, virtual addresses
- **Per-process address spaces** — each program gets its own virtual memory
- **Demand paging** — pages loaded from disk on first access
- **Memory protection** — page-level read/write/execute permissions

MNMM's first-fit allocator would become the **physical page allocator** (like
Linux's buddy allocator), with a new virtual memory layer on top.  The INT 0x82
interface could remain the same from the caller's perspective — only the
implementation changes.

---

## 15. Summary

MNMM is a simple, educational, and defensive memory manager that:

1. Manages 30 KB of heap at `0x8000`–`0xF7FF`
2. Uses first-fit allocation with 8-byte alignment
3. Coalesces adjacent free blocks immediately on free
4. Detects corruption, double-free, and invalid pointers
5. Exposes 4 syscalls through `INT 0x82`
6. Fits in ~530 bytes (release) or ~650 bytes (debug)
7. Integrates with `mnmon` for interactive heap inspection

It follows the mini-os tradition of modular, interrupt-driven services
(INT 0x80 kernel, INT 0x81 filesystem, INT 0x82 memory) and provides the
foundation for every future feature that needs dynamic memory.

---

*"Dynamic storage allocation has been a fundamental problem since the
earliest days of computing.  The first-fit algorithm was described by
Knuth in 1968 and remains competitive with far more complex approaches."*
— Donald Knuth, *The Art of Computer Programming*, Vol. 1
