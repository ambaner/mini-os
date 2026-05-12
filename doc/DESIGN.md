# Mini-OS Design Document

## 1. Project Overview

**Mini-OS** is a minimalistic operating system built from scratch, targeting the x86
architecture. The project is educational — designed so anyone can clone the repository,
build a bootable disk image, and run it in a Hyper-V virtual machine with no prior
OS-development experience.

The current milestone is **M5: 16-bit Kernel + Syscall Interface** — the MBR chain-loads a
minimal VBR, which loads a stage-2 loader (LOADER.BIN) that enables A20, which
loads a 16-bit kernel (KERNEL.BIN) that installs an INT 0x80 syscall handler and
loads the interactive shell (SHELL.BIN) — all shell hardware access goes through
kernel syscalls.

### Design Principles

| Principle | Rationale |
|-----------|-----------|
| **Zero proprietary tools** | All tooling is publicly available so the repo works for anyone who clones it from GitHub. |
| **Self-bootstrapping build** | `build.bat` downloads NASM automatically; no manual tool installation beyond PowerShell 7. |
| **One-command build** | `build.bat` produces a ready-to-boot VHD. |
| **One-command VM setup** | `setup-vm.bat` creates or updates a Hyper-V VM, including VHD deployment. |
| **Iterate fast** | Rebuild → re-run `setup-vm.bat` → boot. The VHD is swapped in-place; no manual VM reconfiguration. |

---

## 2. Architecture

### 2.1 Boot Sequence

```
┌─────────────┐     ┌──────────────────────────────┐     ┌────────────┐
│  BIOS POST  │────>│  Load MBR (sector 0, 512 B)  │────>│  mbr.asm   │
│             │     │  to 0x0000:0x7C00             │     │  executes  │
└─────────────┘     └──────────────────────────────┘     └────────────┘
                                                               │
                                            ┌──────────────────┘
                                            v
                                     ┌─────────────┐
                                     │  Set up      │
                                     │  segments &  │
                                     │  stack       │
                                     └──────┬──────┘
                                            │
                                            v
                                     ┌─────────────┐
                                     │  Clear       │
                                     │  screen      │
                                     │  (INT 10h)   │
                                     └──────┬──────┘
                                            │
                                            v
                                     ┌──────────────┐
                                     │  Print banner │
                                     │  "In MBR"     │
                                     └──────┬───────┘
                                            │
                                            v
                                     ┌──────────────────┐
                                     │  Scan partition   │
                                     │  table (4 entries)│
                                     │  Print each entry │
                                     └──────┬───────────┘
                                            │
                                            v
                                     ┌──────────────────┐
                                     │  Find active      │
                                     │  partition (0x80)  │
                                     └──────┬───────────┘
                                            │
                                   ┌────────┴────────┐
                                   v                 v
                            ┌────────────┐   ┌──────────────┐
                            │ INT 13h    │   │ "No active   │
                            │ AH=42h LBA │   │  partition"  │
                            │ read VBR   │   │  → halt      │
                            └─────┬──────┘   └──────────────┘
                                  │
                                  v
                            ┌────────────┐
                            │ Copy VBR   │
                            │ to 0x7C00  │
                            │ Jump to it │
                            └─────┬──────┘
                                  │
                                  v
                            ┌────────────┐
                            │  vbr.asm   │
                            │ Load LOADER│
                            │ from LBA+4 │
                            │ to 0x0800  │
                            └─────┬──────┘
                                  │
                                  v
                            ┌────────────┐
                            │ LOADER.BIN │
                            │ Enable A20 │
                            │ (3 methods)│
                            │Load KERNEL │
                            │ to 0x5000  │
                            └─────┬──────┘
                                  │
                                  v
                            ┌────────────┐
                            │ KERNEL.BIN │
                            │Install INT │
                            │   0x80     │
                            │ Load SHELL │
                            │ to 0x3000  │
                            └─────┬──────┘
                                  │
                                  v
                            ┌────────────┐
                            │ SHELL.BIN  │
                            │  mnos:\>   │
                            │ (via INT   │
                            │   0x80)    │
                            └────────────┘
```

### 2.2 Memory Layout

> **📄 Deep dive**: See [MEMORY-LAYOUT.md](MEMORY-LAYOUT.md) for the exhaustive
> memory map — every region's purpose, lifetime, stack analysis, reclaimable
> memory, and the roadmap to protected-mode addressing.

| Address | Contents |
|---------|----------|
| `0x0000:0x0000` – `0x0000:0x03FF` | Real-mode Interrupt Vector Table (IVT) |
| `0x0000:0x0400` – `0x0000:0x04FF` | BIOS Data Area (BDA) |
| `0x0000:0x0600` – `0x0000:0x060F` | **Boot Info Block (BIB)** — shared parameters |
| `0x0000:0x0800` – `0x0000:0x27FF` | **LOADER.BIN** (8 KB max) |
| `0x0000:0x3000` – `0x0000:0x4FFF` | **SHELL.BIN** (8 KB max, loaded by kernel) |
| `0x0000:0x5000` – `0x0000:0x6FFF` | **KERNEL.BIN** (8 KB max, 4 sectors used) |
| `0x0000:0x7C00` – `0x0000:0x7FFF` | **VBR** (2 sectors, boot-time only) |
| `0x0000:0x7BFE` ↓ | Stack (grows downward from 0x7C00) |
| `0x0000:0x7E00` – `0x0000:0x9DFF` | VBR load buffer (MBR uses this temporarily) |

#### Boot Info Block (BIB) — 0x0600

The BIB is a fixed-address parameter block populated by early boot stages and
read by later stages:

| Offset | Size | Field | Set by |
|--------|------|-------|--------|
| 0 | 1 | `boot_drive` | VBR |
| 1 | 1 | `a20_status` | LOADER (1=enabled, 0=failed) |
| 2 | 4 | `part_lba` | VBR (partition start LBA) |

### 2.3 MBR Binary Format

```
Offset   Size   Description
───────  ─────  ──────────────────────────────
0x000    446    Boot code (padded with 0x00)
0x1BE     64    Partition table (4 × 16-byte entries)
0x1FE      2    Boot signature: 0x55, 0xAA
```

#### Partition Table Entry Format (16 bytes)

| Offset | Size | Field           | Description                          |
|--------|------|-----------------|--------------------------------------|
| 0      | 1    | Status          | `0x80` = active/bootable, `0x00` = inactive |
| 1      | 3    | CHS First       | CHS of first sector (`0xFEFFFF` for LBA) |
| 4      | 1    | Type            | Partition type (`0x7F` = mini-os)    |
| 5      | 3    | CHS Last        | CHS of last sector (`0xFEFFFF` for LBA) |
| 8      | 4    | LBA Start       | Starting sector (little-endian)      |
| 12     | 4    | Size            | Number of sectors (little-endian)    |

The partition table is stamped into the MBR binary by `tools/create-disk.ps1` at build
time. The MBR code scans all 4 entries, prints their info, and chain-loads the VBR
from the first entry marked active (`0x80`).

### 2.4 Volume Boot Record (VBR)

> **📄 Design rationale**: See [BOOT-LAYOUT-RATIONALE.md](BOOT-LAYOUT-RATIONALE.md)
> for why three stages, comparisons with DOS/Windows/Linux boot chains, the LBA
> gap debate, and clobber protection analysis.

The VBR (`src/boot/vbr.asm`) is a minimal loader at the start of the active
partition. It has a self-describing header and loads LOADER.BIN from a fixed
partition offset:

```
VBR Header (starts at byte 0 of the partition):
  Offset 0:   EB xx      JMP SHORT past header
  Offset 2:   90         NOP
  Offset 3:   'MNOS'     Magic identifier (4 bytes)
  Offset 7:   dw 2       VBR size in sectors
  Offset 9:   dd N       Partition start LBA (stamped by create-disk.ps1)
```

The MBR performs a two-phase load:
1. **Phase 1** — Read the first sector to `0x7E00` and parse the header.
2. **Phase 2** — Re-read all N sectors (from the header) to `0x7E00`.
3. Copy N sectors from `0x7E00` to `0x7C00` and jump.

The VBR then:
1. Populates the Boot Info Block (BIB) at 0x0600
2. Loads LOADER.BIN from partition offset 4 to 0x0800
3. Verifies the 'MNLD' magic
4. Jumps to LOADER.BIN

### 2.5 LOADER.BIN

The loader (`src/loader/loader.asm`) is loaded by the VBR to 0x0800.  It has a
self-describing header:

```
LOADER Header:
  Offset 0:   'MNLD'    Magic identifier (4 bytes)
  Offset 4:   dw N      Loader size in sectors
```

The loader:
1. Enables the A20 gate (3 fallback methods, see §3.7)
2. Loads SHELL.BIN from partition offset 20 to 0x3000
3. Verifies the 'MNSH' magic
4. Jumps to SHELL.BIN

### 2.6 SHELL.BIN

The shell (`src/shell/shell.asm`) is loaded by the loader to 0x3000.  It provides
the interactive command-line interface.  Header:

```
SHELL Header:
  Offset 0:   'MNSH'    Magic identifier (4 bytes)
  Offset 4:   dw N      Shell size in sectors
```

### 2.7 Disk Layout

> **📄 Design rationale**: See [BOOT-LAYOUT-RATIONALE.md](BOOT-LAYOUT-RATIONALE.md)
> for how this layout compares to DOS, Windows, and Linux, and why fixed
> partition offsets were chosen over the LBA gap or a filesystem.

```
Sector 0                → MBR (code + partition table + 0xAA55)
Sectors 1–2047          → Gap (zeroed, reserved)
Sector 2048             → Partition start: VBR (2 sectors)
Sector 2050–2051        → Reserved (VBR growth room)
Sector 2052             → LOADER.BIN (at partition offset 4)
Sectors 2054–2067       → Reserved (loader growth room)
Sector 2068             → SHELL.BIN (at partition offset 20)
Sectors 2078–32767      → Partition data (zeroed, future use)
```

The MBR is a flat 512-byte binary. NASM's `-f bin` output format produces a raw binary
with no headers — exactly what the BIOS expects.

---

## 3. Interactive Shell

After the three-stage boot chain (MBR → VBR → LOADER → SHELL), the shell
clears the screen, displays a version banner (`MNOS v0.4.0`), and enters an
interactive command loop with a `mnos:\>` prompt.

The shell reads boot parameters (boot drive, A20 status) from the Boot Info
Block (BIB) at 0x0600.

### 3.1 Shell Architecture

The shell is a simple read-eval-print loop:

1. Display the prompt `mnos:\>`
2. Read a line of input via `readline` (INT 16h, with backspace and auto-lowercase)
3. Compare the input against known command strings via `strcmp`
4. Dispatch to the matching handler, or print `Unknown command: <input>`
5. After the command completes, return to step 1

### 3.2 Commands

| Command | Description |
|---------|-------------|
| `sysinfo` | Display 5 pages of system information (CPU, memory, BDA, video/disk, IVT) |
| `mem` | Detailed memory info: conventional/extended RAM, A20 status, layout, E820 map |
| `ver` | Version, architecture, assembler, platform, boot chain, disk, source URL |
| `help` | List available commands |
| `cls` | Clear the screen and re-display banner |
| `reboot` | Warm-reboot the system (BIOS reset vector) |

Unknown commands print `Unknown command: <input>` and re-prompt.

### 3.3 `sysinfo` Command

Displays five pages of system information, with "Press any key..." between each
page and a screen clear before each new page:

| Page | Title | Information |
|------|-------|-------------|
| 1 | CPU Information | CPUID vendor string, family/model/stepping, feature flags (FPU, TSC, MSR, CX8, PGE, CMOV, MMX, SSE/2/3/4.1/4.2), hypervisor detection + vendor |
| 2 | Memory | INT 12h conventional memory, INT 15h AH=88h extended memory, E820 memory map |
| 3 | BIOS Data Area | COM/LPT port addresses, equipment word, video mode, columns, page size |
| 4 | Video & Disk | Current video mode, cursor position, video memory base, boot drive geometry, EDD version/total sectors/bytes per sector |
| 5 | IVT Sample | First 8 interrupt vectors (INT 0-7) with descriptions |

#### CPUID Detection

The CPUID instruction (available on 486+) is detected by attempting to flip bit 21
(the ID flag) in EFLAGS.  If the bit toggles, CPUID is supported.  Leaf 0
returns the 12-byte vendor string; leaf 1 returns the CPU family, model, stepping,
and feature flags in EDX/ECX.  When the hypervisor-present flag (ECX bit 31) is
set, leaf 0x40000000 returns the hypervisor vendor string (e.g., "Microsoft Hv").

#### EDD (Enhanced Disk Drive)

INT 13h AH=41h checks for EDD extension support.  If present, AH=48h returns
an extended parameter block with total sector count (64-bit) and bytes per sector,
providing more detail than the legacy CHS geometry from AH=08h.

### 3.4 `mem` Command

Displays detailed memory information on a single page:

- **Conventional memory** — INT 12h (typically 640 KB)
- **Extended memory** — INT 15h AH=88h (memory above 1 MB)
- **A20 gate status** — Shows the boot-time enablement result and performs a
  live wrap-around re-test to confirm A20 is still active
- **Real-mode memory layout** — Static map showing IVT, BDA, free area, boot
  area, video RAM, ROM area, and extended area
- **E820 memory map** — Full BIOS-reported memory map with base, length, and type

#### A20 Gate — Background

The A20 gate controls whether the CPU's 21st address line (A20) is active.  On
the original IBM PC/AT (1984), this line was disabled at boot to maintain backward
compatibility with the 8086, which only had 20 address lines and naturally wrapped
addresses above 1 MB.  Some old DOS programs relied on this wrapping behavior.

The A20 detection works by testing if two addresses that differ only in bit 20
(0x0000:0x0500 = linear 0x00500, and 0xFFFF:0x0510 = linear 0x100500) point to
the same physical byte.  If writing to one changes the other, addresses are
wrapping — A20 is disabled.

**In practice, most modern systems (including Hyper-V, QEMU, and modern BIOS
firmware) enable A20 by default during POST.**  The A20 gate is essentially a
legacy concern.  You would only see "Disabled" on vintage hardware or emulators
configured for strict 8086 compatibility.

### 3.7 A20 Gate Enablement

As of v0.3.0 (now in LOADER.BIN since v0.4.0), the A20 line is explicitly enabled
at boot before loading the shell.  This ensures access to memory above 1 MB
regardless of the platform.  Three methods are attempted in order, with a
wrap-around verification after each:

| Method | Mechanism | Notes |
|--------|-----------|-------|
| 1. BIOS | INT 15h AX=2401h | Cleanest, supported by modern BIOSes |
| 2. Keyboard controller | 8042 ports 0x64/0x60, set bit 1 of output port | Classic AT method, most compatible |
| 3. Fast A20 | Port 0x92, set bit 1 (clear bit 0 to avoid reset) | Quick but not available on all hardware |

The `check_a20` subroutine performs the wrap-around test: it writes different
values to 0x0000:0x0500 and 0xFFFF:0x0510, then checks if they alias.  The result
is stored in `a20_status` (1 = enabled, 0 = failed) and displayed by the `mem`
command.  If all three methods fail, the shell still runs (within the low 1 MB)
but prints a warning.

### 3.5 `ver` Command

Displays static version and build information:

```
  MNOS v0.4.0
  Arch:      x86 real mode (16-bit)
  Assembler: NASM
  Platform:  Hyper-V Gen 1
  Boot:      MBR -> VBR -> LOADER -> SHELL
  Disk:      16 MB fixed VHD
  Source:    github.com/ambaner/mini-os
```

### 3.8 Shell Subroutines

These subroutines live in SHELL.BIN and are available to all commands:

| Routine | Description |
|---------|-------------|
| `check_a20` | Test A20 status via wrap-around; ZF=0 if enabled, ZF=1 if disabled |
| `readline` | Read line of input into buffer (backspace, auto-lowercase) |
| `strcmp` | Compare two NUL-terminated strings, set ZF if equal |
| `puts` | Print NUL-terminated string via INT 10h AH=0Eh |
| `putc` | Print single character |
| `puthex8` | Print AL as two hex digits |
| `print_hex16` | Print AX as four hex digits |
| `print_dec16` | Print AX as unsigned decimal |
| `wait_key` | Print prompt, wait for keypress, clear screen |

---

## 4. Disk Image: VHD Format

### 4.1 Why VHD?

Hyper-V natively supports VHD (Virtual Hard Disk) files. The **fixed-size VHD** format
is the simplest variant: raw disk data followed by a 512-byte footer. No dynamic
allocation, no differencing chains, no BAT — just:

```
┌──────────────────────────────────────┐
│        Raw disk data                 │  ← disk_size bytes (16 MB)
│        (MBR at byte 0, rest zeroed)  │
├──────────────────────────────────────┤
│        VHD Footer (512 bytes)        │  ← identifies file as VHD
└──────────────────────────────────────┘
```

### 4.2 VHD Footer Structure

The footer follows the **VHD 1.0 specification** (originally by Connectix, later
Microsoft). Key fields:

| Offset | Size | Field              | Value                       |
|--------|------|--------------------|-----------------------------|
| 0      | 8    | Cookie             | `conectix`                  |
| 8      | 4    | Features           | `0x00000002` (reserved)     |
| 12     | 4    | Format Version     | `0x00010000` (v1.0)         |
| 16     | 8    | Data Offset        | `0xFFFFFFFFFFFFFFFF` (fixed) |
| 24     | 4    | Timestamp          | Seconds since 2000-01-01    |
| 28     | 4    | Creator App        | `mnos`                      |
| 36     | 4    | Creator Host OS    | `Wi2k` (Windows)            |
| 40     | 8    | Original Size      | Disk size in bytes           |
| 48     | 8    | Current Size       | Disk size in bytes           |
| 56     | 4    | Disk Geometry      | CHS (computed per spec)     |
| 60     | 4    | Disk Type          | `2` (Fixed)                 |
| 64     | 4    | Checksum           | One's complement of sum     |
| 68     | 16   | Unique ID          | Random UUID                 |
| 84     | 1    | Saved State        | `0`                         |

### 4.3 CHS Geometry

The VHD spec requires CHS geometry derived from total sector count. The algorithm
(implemented in `create-vhd.ps1`) selects sectors/track from {17, 31, 63, 255} and
heads from {4..16} to stay within the 1024-cylinder BIOS limit where possible.

For 16 MB (32,768 sectors): **C/H/S = 481/4/17**.

### 4.4 Disk Size

The default disk size is **16 MB**. Hyper-V supports VHDs as small as 3 MB, so 16 MB is
well within range. The size is configurable via `build.bat` (edit `tools/build.ps1` to change `-DiskSizeMB`).

---

## 5. Toolchain

### 5.1 NASM (Netwide Assembler)

- **Version**: 2.16.03 (win64)
- **Role**: Assembles 16-bit x86 real-mode code into flat binary (`-f bin`).
- **Acquisition**: `build.bat` auto-downloads from `nasm.us` into `tools/nasm/` if not
  found on PATH. The downloaded copy is gitignored.

### 5.2 PowerShell 7+

All build and deployment scripts require **PowerShell 7.0 or later**. Each script
includes a `#Requires -Version 7.0` directive that produces a clear error on older
versions.

| Script | Purpose | Elevation |
|--------|---------|-----------|
| `tools/build.ps1` | Assemble MBR + VBR + LOADER + SHELL, create disk image + VHD | Not required |
| `tools/setup-vm.ps1` | Create/update Hyper-V VM | **Admin required** |
| `tools/create-disk.ps1` | Stamp partition table + VBR + LOADER + SHELL into raw image | Not required (called by build.ps1) |
| `tools/create-vhd.ps1` | Raw image → VHD conversion | Not required (called by build.ps1) |

### 5.3 No Other Dependencies

There is no C compiler, no linker, no Python, no WSL requirement. The entire toolchain
is PowerShell + NASM.

---

## 6. Build System

### 6.1 Build Pipeline

```
 build.bat
     │
     ├─ 1. Locate or download NASM
     │
     ├─ 2. nasm -f bin -o build/boot/mbr.bin src/boot/mbr.asm
     │      └─ 512 bytes: code + empty partition table + 0xAA55
     │
     ├─ 3. nasm -f bin -o build/boot/vbr.bin src/boot/vbr.asm
     │      └─ 1024 bytes (2 sectors): header + loader chain + 0xAA55
     │
     ├─ 4. nasm -f bin -o build/boot/loader.bin src/loader/loader.asm
     │      └─ 1024 bytes (2 sectors): A20 enablement + shell chain
     │
     ├─ 5. nasm -f bin -o build/boot/shell.bin src/shell/shell.asm
     │      └─ 5120 bytes (10 sectors): interactive shell + commands
     │
     ├─ 6. tools/create-disk.ps1 — build raw disk image
     │      └─ Stamps partition table into MBR, partition LBA into VBR,
     │         writes VBR/LOADER/SHELL at partition offsets 0/4/20
     │
     └─ 7. tools/create-vhd.ps1 — wrap as VHD
            └─ Appends 512-byte VHD footer
```

### 6.2 Build Outputs

| File | Size | Description |
|------|------|-------------|
| `build/boot/mbr.bin` | 512 B | Raw MBR binary (before partition table stamp) |
| `build/boot/vbr.bin` | 1 KB (2 × 512) | Raw VBR binary |
| `build/boot/loader.bin` | 1 KB (2 × 512) | LOADER.BIN with A20 enablement |
| `build/boot/shell.bin` | 5 KB (10 × 512) | SHELL.BIN with all commands |
| `build/boot/mini-os.img` | 16 MB | Partitioned raw disk image |
| `build/boot/mini-os.vhd` | 16 MB + 512 B | Bootable fixed VHD |

### 6.3 Clean Build

```cmd
build.bat clean
```

Removes the `build/` directory before assembling.

---

## 7. VM Deployment (setup-vm.bat)

### 7.1 First Run

1. Prompts for VM name (default: `mini-os`) and file location.
2. Creates `<location>/HDD/` and copies `build/boot/mini-os.vhd` there.
3. Creates a Generation 1 VM:
   - 32 MB static RAM
   - IDE 0:0 → `HDD/mini-os.vhd`
   - No network adapter
   - Checkpoints disabled
4. Prints `Start-VM` / `vmconnect` commands.

### 7.2 Subsequent Runs (Update Flow)

1. Detects existing VM by name.
2. Stops the VM if running (`Stop-VM -TurnOff`).
3. Overwrites the VHD in the `HDD/` folder with the latest build.
4. Ensures IDE 0:0 points to the updated VHD.
5. VM is ready to start again.

This makes the edit → build → test cycle seamless:

```
edit mbr.asm  →  build.bat  →  setup-vm.bat  →  Start-VM
```

---

## 8. Project Structure

```
mini-os/
├── .github/
│   ├── ISSUE_TEMPLATE/           Bug report & feature request templates
│   └── workflows/
│       ├── build.yml             CI — build & verify on push/PR
│       └── release.yml           CD — package & release on version tags
├── doc/
│   └── DESIGN.md                 ← this document
├── src/
│   ├── boot/
│   │   ├── mbr.asm               MBR — partition table scan + VBR chain-load
│   │   └── vbr.asm               VBR — header + loads LOADER.BIN (2 sectors)
│   ├── loader/
│   │   └── loader.asm            LOADER — A20 enablement + loads SHELL.BIN
│   └── shell/
│       └── shell.asm             SHELL — interactive shell + all commands
├── tools/
│   ├── build.ps1                 Build logic (assembles 4 binaries)
│   ├── create-disk.ps1           Raw disk image with MBR + VBR + LOADER + SHELL
│   ├── create-vhd.bat            VHD tool — batch wrapper
│   ├── create-vhd.ps1            Raw image → fixed VHD converter
│   ├── setup-vm.ps1              Hyper-V VM create/update logic
│   └── nasm/                     Auto-downloaded NASM (gitignored)
├── build/                        Build output (gitignored)
│   └── boot/
│       ├── mbr.bin               Assembled MBR binary (512 B)
│       ├── vbr.bin               Assembled VBR binary (1 KB)
│       ├── loader.bin            Assembled LOADER binary (1 KB)
│       ├── shell.bin             Assembled SHELL binary (5 KB)
│       ├── mini-os.img           Partitioned raw disk image
│       └── mini-os.vhd           Bootable VHD
├── build.bat                     Build entry point
├── setup-vm.bat                  Hyper-V VM setup entry point
├── CHANGELOG.md
├── CODE_OF_CONDUCT.md
├── CONTRIBUTING.md
├── LICENSE
├── README.md
└── .gitignore
```

---

## 9. Future Roadmap

This document will be updated as the project evolves. Planned milestones:

| Milestone | Description |
|-----------|-------------|
| **M0** ✅ | Boot MBR, print banner, halt |
| **M1** ✅ | Partition table scan, VBR chain-load, multi-sector boot area |
| **M1+** ✅ | VBR system information display (5 pages: CPU, memory, BDA, video/disk, IVT) |
| **M2** ✅ | Interactive shell (`mnos:\>`) with command dispatch, `sysinfo` as first command |
| **M3** ✅ | A20 gate enablement (BIOS / 8042 / Fast A20 with fallbacks) |
| **M4** ✅ | Three-stage boot chain (VBR → LOADER.BIN → SHELL.BIN), Boot Info Block |
| **M5** | Switch to 32-bit protected mode (see [MEMORY-LAYOUT.md §8](MEMORY-LAYOUT.md#8-future-beyond-1-mb)) |
| **M6** | Basic kernel with screen output (direct VGA framebuffer) |
| **M7** | Simple memory manager |
| **M8** | File system support (/boot partition) |

---

## 10. References

- [NASM Manual](https://www.nasm.us/xdoc/2.16.03/html/nasmdoc0.html)
- [VHD Specification (Microsoft)](https://learn.microsoft.com/en-us/windows/win32/vstor/about-vhd)
- [OSDev Wiki — Boot Sequence](https://wiki.osdev.org/Boot_Sequence)
- [OSDev Wiki — MBR](https://wiki.osdev.org/MBR_(x86))
- [INT 10h — BIOS Video Services](https://en.wikipedia.org/wiki/INT_10H)
- [Hyper-V Generation 1 vs 2](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/plan/should-i-create-a-generation-1-or-2-virtual-machine-in-hyper-v)
- [Boot Layout Design Rationale](BOOT-LAYOUT-RATIONALE.md) — why three stages, DOS/Windows/Linux comparisons, LBA gap analysis
- [Memory Layout Design Document](MEMORY-LAYOUT.md) — exhaustive memory map, stack analysis, A20/protected mode roadmap
- [CPU Modes and Transitions](CPU-MODES-AND-TRANSITIONS.md) — 16→32→64-bit journey, GDT/IDT/paging, hardware drivers, BIOS vs UEFI
- [MNEX Binary Format & Toolchain](MNEX-BINARY-FORMAT.md) — custom binary format spec, NASM+Clang toolchain, build pipeline, header layout
- [System Calls](SYSTEM-CALLS.md) — user↔kernel boundary, IVT/IDT/SYSCALL mechanisms, ring transitions, syscall table
