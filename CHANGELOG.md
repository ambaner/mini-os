# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [0.2.6] — 2026-05-11

### Added
- **`mem` command** — detailed memory information display:
  - Conventional memory (INT 12h)
  - Extended memory (INT 15h AH=88h)
  - A20 gate status (wrap-around test at 0x0000:0x0500 vs 0xFFFF:0x0510)
  - Real-mode memory layout map (IVT, BDA, free area, boot area, video, ROM)
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
