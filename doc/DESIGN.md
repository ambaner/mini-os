# Mini-OS Design Document

## 1. Project Overview

**Mini-OS** is a minimalistic operating system built from scratch, targeting the x86
architecture. The project is educational — designed so anyone can clone the repository,
build a bootable disk image, and run it in a Hyper-V virtual machine with no prior
OS-development experience.

The current milestone is **M1: Partition Table & VBR** — the MBR reads and displays
the partition table, then chain-loads the Volume Boot Record (VBR) from the active
partition.

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
                            │  "In boot  │
                            │  sector"   │
                            │  → halt    │
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

Currently the VBR code fits in one sector; the remaining 15 are reserved for
future features (protected mode switch, kernel loader, etc.). As the code
grows, the VBR binary simply gets larger — no build changes needed.

Currently the VBR prints `"In boot sector now"` followed by
`"mini-os boot completed"` and halts.

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

## 3. Disk Image: VHD Format

### 3.1 Why VHD?

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

### 3.2 VHD Footer Structure

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

### 3.3 CHS Geometry

The VHD spec requires CHS geometry derived from total sector count. The algorithm
(implemented in `create-vhd.ps1`) selects sectors/track from {17, 31, 63, 255} and
heads from {4..16} to stay within the 1024-cylinder BIOS limit where possible.

For 16 MB (32,768 sectors): **C/H/S = 481/4/17**.

### 3.4 Disk Size

The default disk size is **16 MB**. Hyper-V supports VHDs as small as 3 MB, so 16 MB is
well within range. The size is configurable via `build.bat` (edit `tools/build.ps1` to change `-DiskSizeMB`).

---

## 4. Toolchain

### 4.1 NASM (Netwide Assembler)

- **Version**: 2.16.03 (win64)
- **Role**: Assembles 16-bit x86 real-mode code into flat binary (`-f bin`).
- **Acquisition**: `build.bat` auto-downloads from `nasm.us` into `tools/nasm/` if not
  found on PATH. The downloaded copy is gitignored.

### 4.2 PowerShell 7+

All build and deployment scripts require **PowerShell 7.0 or later**. Each script
includes a `#Requires -Version 7.0` directive that produces a clear error on older
versions.

| Script | Purpose | Elevation |
|--------|---------|-----------|
| `tools/build.ps1` | Assemble MBR + VBR, create disk image + VHD | Not required |
| `tools/setup-vm.ps1` | Create/update Hyper-V VM | **Admin required** |
| `tools/create-disk.ps1` | Stamp partition table + VBR into raw image | Not required (called by build.ps1) |
| `tools/create-vhd.ps1` | Raw image → VHD conversion | Not required (called by build.ps1) |

### 4.3 No Other Dependencies

There is no C compiler, no linker, no Python, no WSL requirement. The entire toolchain
is PowerShell + NASM.

---

## 5. Build System

### 5.1 Build Pipeline

```
 build.bat
     │
     ├─ 1. Locate or download NASM
     │
     ├─ 2. nasm -f bin -o build/boot/mbr.bin src/boot/mbr.asm
     │      └─ 512 bytes: code + empty partition table + 0xAA55
     │
     ├─ 3. nasm -f bin -o build/boot/vbr.bin src/boot/vbr.asm
     │      └─ 512 bytes: VBR code + 0xAA55
     │
     ├─ 4. tools/create-disk.ps1 — build raw disk image
     │      └─ Stamps partition table into MBR, writes VBR at partition LBA
     │
     └─ 5. tools/create-vhd.ps1 — wrap as VHD
            └─ Appends 512-byte VHD footer
```

### 5.2 Build Outputs

| File | Size | Description |
|------|------|-------------|
| `build/boot/mbr.bin` | 512 B | Raw MBR binary (before partition table stamp) |
| `build/boot/vbr.bin` | 512 B | Raw VBR binary |
| `build/boot/mini-os.img` | 16 MB | Partitioned raw disk image |
| `build/boot/mini-os.vhd` | 16 MB + 512 B | Bootable fixed VHD |

### 5.3 Clean Build

```cmd
build.bat clean
```

Removes the `build/` directory before assembling.

---

## 6. VM Deployment (setup-vm.bat)

### 6.1 First Run

1. Prompts for VM name (default: `mini-os`) and file location.
2. Creates `<location>/HDD/` and copies `build/boot/mini-os.vhd` there.
3. Creates a Generation 1 VM:
   - 32 MB static RAM
   - IDE 0:0 → `HDD/mini-os.vhd`
   - No network adapter
   - Checkpoints disabled
4. Prints `Start-VM` / `vmconnect` commands.

### 6.2 Subsequent Runs (Update Flow)

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

## 7. Project Structure

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
│       └── vbr.asm               VBR — loaded from active partition
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

## 8. Future Roadmap

This document will be updated as the project evolves. Planned milestones:

| Milestone | Description |
|-----------|-------------|
| **M0** ✅ | Boot MBR, print banner, halt |
| **M1** ✅ | Partition table scan, VBR chain-load, multi-sector boot area (16 sectors / 8 KB) |
| **M2** | Switch to 32-bit protected mode |
| **M3** | Basic kernel with screen output (direct VGA framebuffer) |
| **M4** | Interrupt handling (keyboard input) |
| **M5** | Simple memory manager |
| **M6** | Basic shell / command prompt |

---

## 9. References

- [NASM Manual](https://www.nasm.us/xdoc/2.16.03/html/nasmdoc0.html)
- [VHD Specification (Microsoft)](https://learn.microsoft.com/en-us/windows/win32/vstor/about-vhd)
- [OSDev Wiki — Boot Sequence](https://wiki.osdev.org/Boot_Sequence)
- [OSDev Wiki — MBR](https://wiki.osdev.org/MBR_(x86))
- [INT 10h — BIOS Video Services](https://en.wikipedia.org/wiki/INT_10H)
- [Hyper-V Generation 1 vs 2](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/plan/should-i-create-a-generation-1-or-2-virtual-machine-in-hyper-v)
