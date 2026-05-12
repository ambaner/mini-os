# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [0.5.0] — 2026-05-11

### Added
- **16-bit kernel** (`KERNEL.BIN`) — loaded by LOADER at 0x5000 (partition offset 20),
  installs an INT 0x80 syscall handler with 27 functions wrapping all BIOS services
- **INT 0x80 syscall interface** — shell no longer makes direct BIOS calls; all
  hardware access goes through kernel syscalls (AH = function number)
- **CPUID syscall (0x18)** — leaf passed via EDI to avoid conflict with AH dispatch byte
- **MNKN magic** — kernel binary self-identifies with 'MNKN' header (4 sectors / 2 KB)

### Changed
- Boot chain extended: MBR → VBR → LOADER → **KERNEL** → SHELL
- LOADER now loads KERNEL.BIN (was SHELL.BIN); kernel loads SHELL.BIN
- Shell refactored to pure **user-mode executable** — magic changed from MNSH to MNEX
- All direct BIOS calls in shell replaced with INT 0x80 syscalls
- Disk layout: kernel at partition offset 20, shell moved to partition offset 36
- build.ps1 assembles 5 binaries: MBR (512 B), VBR (1 KB), LOADER (1 KB),
  KERNEL (2 KB), SHELL (5 KB)
- create-disk.ps1 updated with new `-KernelPath` parameter
- Memory layout: SHELL.BIN at 0x3000 (8 KB max), KERNEL.BIN at 0x5000–0x57FF
- Version banner updated to v0.5.0

## [0.4.0] — 2026-05-11

### Added
- **Three-stage boot chain** — refactored from monolithic VBR to:
  - **VBR** (2 sectors / 1 KB): loads LOADER.BIN from fixed partition offset
  - **LOADER.BIN** (2 sectors / 1 KB): A20 gate enablement, loads SHELL.BIN
  - **SHELL.BIN** (10 sectors / 5 KB): interactive shell with all commands
- **Boot Info Block (BIB)** at 0x0600 — shared parameter block passed between
  boot stages (boot drive, A20 status, partition LBA)
- **Binary headers** — LOADER uses 'MNLD' magic, SHELL uses 'MNSH' magic,
  each with self-describing sector count
- **Partition LBA stamping** — create-disk.ps1 writes the partition start LBA
  into the VBR header at offset 9, enabling partition-relative addressing

### Changed
- VBR shrunk from 16 sectors (8 KB) to 2 sectors (1 KB) — now a pure loader
- A20 enablement moved from VBR to LOADER.BIN
- Shell and all commands moved from VBR to SHELL.BIN (separate binary)
- Memory layout updated: LOADER at 0x0800, SHELL at 0x3000, BIB at 0x0600
- `mem` command layout display updated for new memory map
- `ver` command updated: boot chain shows "MBR -> VBR -> LOADER -> SHELL"
- Version banner updated to v0.4.0

### Fixed
- **MBR boot drive bug** — DL was being restored from memory after `rep movsw`
  had overwritten the MBR data section; now saved to register before the copy

### Technical
- Partition disk layout: VBR at offset 0, LOADER at offset 4, SHELL at offset 20
- Build system: build.ps1 now assembles 4 binaries; create-disk.ps1 places all 3
  within the partition; build.yml validates all binaries
- Shell has room to grow: 10 sectors used of 32 max (16 KB)

## [0.3.0] — 2026-05-11

### Added
- **A20 gate enablement** — VBR now enables the A20 address line at boot, unlocking
  access to memory above 1 MB.  Uses three fallback methods:
  1. BIOS INT 15h AX=2401h (cleanest, most portable)
  2. Keyboard controller 8042 (classic AT method, ports 0x64/0x60)
  3. Fast A20 via port 0x92 (quick but not universal)
- **`check_a20` subroutine** — reusable wrap-around A20 verification used at boot
  and by the `mem` command
- **`mem` command A20 verification** — now shows boot-time result and performs a
  live re-test to confirm A20 is still active

### Changed
- Version banner updated to v0.3.0

## [0.2.7] — 2026-05-11

### Added
- **`ver` command** — displays version, architecture, assembler, platform, boot chain, disk, and source URL
- **`sysinfo` CPU page** — new Page 1 with CPUID-based information:
  - Vendor string (e.g., "GenuineIntel")
  - Family, model, stepping numbers
  - Feature flags (FPU, TSC, MSR, CX8, PGE, CMOV, MMX, SSE, SSE2, SSE3, SSE4.1, SSE4.2)
  - Hypervisor detection and vendor string (e.g., "Microsoft Hv")
- **`sysinfo` EDD disk info** — Enhanced Disk Drive support on the disk page:
  - EDD version number
  - Total sector count (32-bit hex)
  - Bytes per sector

### Changed
- Sysinfo expanded from 4 pages to 5 pages (CPU, Memory, BDA, Video & Disk, IVT)
- Help text updated to include `ver` command
- Version banner updated to v0.2.7

## [0.2.6] — 2026-05-11

### Added
- **`mem` command** — detailed memory information display:
  - Conventional memory (INT 12h)
  - Extended memory (INT 15h AH=88h)
  - A20 gate status (wrap-around test at 0x0000:0x0500 vs 0xFFFF:0x0510)
  - Real-mode memory layout map with sizes (IVT, BDA, free area, boot area, video, ROM)
  - E820 BIOS memory map with type labels

### Changed
- Help text updated to include `mem` command
- Version banner updated to v0.2.6

## [0.2.5] — 2026-05-11

### Added
- **Interactive command shell** — VBR now boots into a `mnos:\>` prompt with keyboard input
- **Shell commands**: `sysinfo`, `help`, `cls`, `reboot`
- **Input handling**: `readline` subroutine with backspace support, case-insensitive (auto-lowercase)
- **String comparison**: `strcmp` subroutine for command dispatch
- **`sysinfo` command** — the 4-page system info display is now invoked on demand (was automatic)

### Changed
- VBR clears screen on boot and displays `MNOS v0.2.5` banner before shell prompt
- System info display moved from boot-time to `sysinfo` shell command
- `reboot` uses warm-reboot (0x0472 flag + far jump to BIOS reset vector)
- After `sysinfo` completes, returns to shell prompt (no longer halts)

## [0.2.2] — 2026-05-11

### Added
- **4-page system information display** — VBR now queries BIOS/hardware and displays:
  - Page 1: CPU & Memory (INT 12h, INT 15h AH=88h, E820 memory map)
  - Page 2: BIOS Data Area (COM/LPT ports, equipment word, video info from BDA)
  - Page 3: Video & Disk (video mode, cursor, video memory base, boot drive geometry)
  - Page 4: IVT Sample (first 8 interrupt vectors with descriptions)
- **VBR subroutines**: `print_hex16`, `print_dec16`, `wait_key`, `puthex8` — reusable utility functions
- **Inter-page navigation**: "Press any key..." between pages with screen clear

### Changed
- VBR now uses full 16-sector (8 KB) boot area — code+data spans sectors 0–1, rest zero-padded
- VBR sector 0 contains header + trampoline + boot signature; code starts in sector 1
- `create-disk.ps1` writes full multi-sector VBR binary (was only writing 512 bytes)
- CI verifies VBR binary size matches header-declared sector count
- Fixed em dash (U+2014) in VBR banner — replaced with ASCII hyphen for correct BIOS rendering

## [0.2.1] — 2026-05-11

### Added
- **Multi-sector VBR loading** — MBR reads boot-area sector count from VBR header, loads all N sectors (default 16 = 8 KB)
- **VBR header** — self-describing format: `JMP SHORT` + `NOP` + `'MNOS'` magic + sector count at offset 7
- CI verification of VBR header magic (`MNOS`) and sector count validity

### Changed
- MBR uses two-phase disk read: load 1 sector → parse header → reload all boot-area sectors
- Heavily commented both `mbr.asm` and `vbr.asm` for educational readability
- Trimmed MBR error messages to fit new loading code within 446-byte limit (17 bytes free)

## [0.2.0] — 2026-05-11

### Added
- **Partition table support** — MBR scans all 4 partition entries and prints type, LBA, size, active status
- **Volume Boot Record (VBR)** — `src/boot/vbr.asm`, chain-loaded from the active partition
- **Disk image tool** — `tools/create-disk.ps1` stamps partition table into MBR and writes VBR at partition LBA
- **LBA extended read** — MBR uses `INT 13h AH=42h` (DAP) for LBA-based disk reads

### Changed
- Build pipeline now: assemble MBR + VBR → create partitioned raw image → wrap as VHD
- CI workflow verifies VBR signature and partition table presence
- Release zip now includes `vbr.bin` alongside `mbr.bin`

## [0.1.0] — 2026-05-09

### Added
- **Master Boot Record** — 16-bit x86 bootloader that prints `In MBR` and halts
- **VHD creation tool** — pure-PowerShell fixed VHD 1.0 image generator (`tools/create-vhd.ps1`)
- **Build system** — `build.bat` / `tools/build.ps1` with automatic NASM download
- **Hyper-V VM setup** — `setup-vm.bat` / `tools/setup-vm.ps1` creates or updates a Gen 1 VM
- **Design document** — `doc/DESIGN.md` covering architecture, VHD format, toolchain, and roadmap
- **GitHub workflows** — CI build on push/PR, release on version tags
- **Community files** — LICENSE (MIT), CONTRIBUTING, CODE_OF_CONDUCT, issue templates
