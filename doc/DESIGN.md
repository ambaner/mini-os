# Mini-OS Design Document

## 1. Project Overview

**Mini-OS** is a minimalistic operating system built from scratch, targeting the x86
architecture. The project is educational — designed so anyone can clone the repository,
build a bootable disk image, and run it in a Hyper-V virtual machine with no prior
OS-development experience.

The current milestone is **M2: Interactive Shell** — the MBR reads and displays
the partition table, chain-loads the multi-sector VBR, and the VBR drops into an
interactive command shell with a `mnos:\>` prompt.  Commands include `sysinfo`,
`mem`, `help`, `cls`, and `reboot`.

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
                            │  Shell     │
                            │  mnos:\>   │
                            │  (sysinfo, │
                            │  help...)  │
                            └────────────┘
```

### 2.2 Memory Layout (at MBR execution)

| Address       | Contents                           |
|---------------|------------------------------------|
| `0x0000:0x0000` – `0x0000:0x03FF` | Real-mode Interrupt Vector Table (IVT) |
| `0x0000:0x0400` – `0x0000:0x04FF` | BIOS Data Area (BDA)               |
| `0x0000:0x7C00` – `0x0000:0x7DFF` | **MBR code (512 bytes)** → later overwritten by VBR |
| `0x0000:0x7E00` – `0x0000:0x9DFF` | VBR load buffer (N sectors, before copy to 0x7C00) |
| `0x0000:0x7BFE` ↓                 | Stack (grows downward from 0x7C00) |

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

The VBR (`src/boot/vbr.asm`) occupies the boot area at the start of the active
partition. It has a self-describing header that the MBR reads to determine how
many sectors to load:

```
VBR Header (starts at byte 0 of the partition):
  Offset 0:   EB xx      JMP SHORT past header
  Offset 2:   90         NOP
  Offset 3:   'MNOS'     Magic identifier (4 bytes)
  Offset 7:   dw N       Boot area size in sectors (currently 16 = 8 KB)
```

The MBR performs a two-phase load:
1. **Phase 1** — Read the first sector to `0x7E00` and parse the header.
2. **Phase 2** — Re-read all N sectors (from the header) to `0x7E00`.
3. Copy N sectors from `0x7E00` to `0x7C00` and jump.

#### VBR Sector Layout

Sector 0 contains the header, a near-jump trampoline, and the boot signature
(`0xAA55`) at offset 510. The actual VBR code begins in sector 1 (offset 512),
since the code + data exceed 510 bytes.

### 2.5 Disk Layout

```
Sector 0                → MBR (code + partition table + 0xAA55)
Sectors 1–2047          → Gap (zeroed, reserved)
Sector 2048             → VBR sector 0 (header + code, active partition start)
Sectors 2049–2063       → VBR sectors 1–15 (reserved boot area, zeroed)
Sectors 2064–32767      → Partition data (zeroed, future use)
```

The MBR is a flat 512-byte binary. NASM's `-f bin` output format produces a raw binary
with no headers — exactly what the BIOS expects.

---

## 3. Interactive Shell

After the MBR chain-loads the VBR, the VBR clears the screen, displays a version
banner (`MNOS v0.2.7`), and enters an interactive command loop with a `mnos:\>`
prompt.

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
- **A20 gate status** — Tests the address line by writing to 0x0000:0x0500 and
  0xFFFF:0x0510; if they alias, A20 is disabled (addresses wrap at 1 MB)
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

When we later switch to protected mode, we will explicitly enable A20 as a
safety measure (in case any environment leaves it off), using the keyboard
controller method (port 0x64/0x60) or the fast A20 method (port 0x92).

### 3.5 `ver` Command

Displays static version and build information:

```
  MNOS v0.2.7
  Arch:      x86 real mode (16-bit)
  Assembler: NASM
  Platform:  Hyper-V Gen 1
  Boot:      MBR -> VBR (16 sectors / 8 KB)
  Disk:      16 MB fixed VHD
  Source:    github.com/ambaner/mini-os
```

### 3.6 VBR Subroutines

| Routine | Description |
|---------|-------------|
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
| `tools/build.ps1` | Assemble MBR + VBR, create disk image + VHD | Not required |
| `tools/setup-vm.ps1` | Create/update Hyper-V VM | **Admin required** |
| `tools/create-disk.ps1` | Stamp partition table + VBR into raw image | Not required (called by build.ps1) |
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
     │      └─ 8192 bytes (16 sectors): header + system info + 0xAA55
     │
     ├─ 4. tools/create-disk.ps1 — build raw disk image
     │      └─ Stamps partition table into MBR, writes VBR at partition LBA
     │
     └─ 5. tools/create-vhd.ps1 — wrap as VHD
            └─ Appends 512-byte VHD footer
```

### 6.2 Build Outputs

| File | Size | Description |
|------|------|-------------|
| `build/boot/mbr.bin` | 512 B | Raw MBR binary (before partition table stamp) |
| `build/boot/vbr.bin` | 8 KB (16 × 512) | Raw VBR binary (multi-sector) |
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
│   └── boot/
│       ├── mbr.asm               MBR — partition table scan + VBR chain-load
│       └── vbr.asm               VBR — interactive shell + sysinfo (16 sectors)
├── tools/
│   ├── build.ps1                 Build logic
│   ├── create-disk.ps1           Raw disk image with partition table + VBR
│   ├── create-vhd.bat            VHD tool — batch wrapper
│   ├── create-vhd.ps1            Raw image → fixed VHD converter
│   ├── setup-vm.ps1              Hyper-V VM create/update logic
│   └── nasm/                     Auto-downloaded NASM (gitignored)
├── build/                        Build output (gitignored)
│   └── boot/
│       ├── mbr.bin               Assembled MBR binary
│       ├── vbr.bin               Assembled VBR binary
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
| **M1** ✅ | Partition table scan, VBR chain-load, multi-sector boot area (16 sectors / 8 KB) |
| **M1+** ✅ | VBR system information display (5 pages: CPU, memory, BDA, video/disk, IVT) |
| **M2** ✅ | Interactive shell (`mnos:\>`) with command dispatch, `sysinfo` as first command |
| **M3** | A20 gate enable + kernel binary load from disk |
| **M4** | Switch to 32-bit protected mode |
| **M5** | Basic kernel with screen output (direct VGA framebuffer) |
| **M6** | Simple memory manager |

---

## 10. References

- [NASM Manual](https://www.nasm.us/xdoc/2.16.03/html/nasmdoc0.html)
- [VHD Specification (Microsoft)](https://learn.microsoft.com/en-us/windows/win32/vstor/about-vhd)
- [OSDev Wiki — Boot Sequence](https://wiki.osdev.org/Boot_Sequence)
- [OSDev Wiki — MBR](https://wiki.osdev.org/MBR_(x86))
- [INT 10h — BIOS Video Services](https://en.wikipedia.org/wiki/INT_10H)
- [Hyper-V Generation 1 vs 2](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/plan/should-i-create-a-generation-1-or-2-virtual-machine-in-hyper-v)
