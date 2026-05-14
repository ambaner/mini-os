# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [0.7.4] — 2026-05-13

### Changed
- **CPU fault handlers now present in both release and debug builds** — a CPU
  exception in any build produces a full crash screen instead of silently looping:
  - Exception name (e.g., `#DE Divide Error`)
  - Faulting CS:IP address
  - Full register dump (AX, BX, CX, DX, SI, DI, BP, SP, DS, ES, SS, FLAGS)
  - Top 4 stack words
  - "System halted." message, then `cli; hlt`
- Debug builds additionally log all fault info to serial (COM1)
- **Master PIC (8259A) remapped**: IRQ 0–7 moved from INT 0x08–0x0F to
  INT 0x20–0x27, freeing INT 0x08 for #DF (Double Fault) exception handler.
  BIOS ISRs are copied to the new vectors transparently.
- 7 vectors now trapped: #DE, #DB, #OF, #BR, #UD, #NM, #DF
- KERNEL.BIN release sector count: 6 → 7 (fault handlers + PIC remap code)
- KERNEL.BIN debug sector count: 9 → 10 (serial output in fault_common)

---

## [0.7.3] — 2026-05-13

### Added
- **CPU exception fault handlers** (debug build only) — trap 7 exception
  vectors and produce a diagnostic dump instead of silently triple-faulting:
  - `#DE` (INT 0x00) — Divide Error
  - `#DB` (INT 0x01) — Debug / Single Step
  - `#OF` (INT 0x04) — Overflow
  - `#BR` (INT 0x05) — Bound Range Exceeded
  - `#UD` (INT 0x06) — Invalid Opcode
  - `#NM` (INT 0x07) — Device Not Available
  - `#DF` (INT 0x08) — Double Fault *(PIC remap added in v0.7.4)*
- On exception: prints `*** CPU EXCEPTION: <name>` with faulting CS:IP to
  both serial and screen, dumps all registers to serial, then halts (`cli; hlt`)
- `install_fault_handlers` subroutine called during kernel init (after INT 0x80)
- Screen hex display helper for fault address output

### Changed
- KERNEL.BIN debug sector count: 8 → 9 (fault handler code adds ~300 bytes)
- Release builds unchanged — all fault handler code under `%ifdef DEBUG`

---

## [0.7.2] — 2026-05-13

### Added
- **Assert macros** (`src/include/debug.inc`) — three compile-time assertion
  macros for fail-fast debugging in debug builds:
  - `ASSERT reg, cond, val, "msg"` — halt if a register comparison fails
  - `ASSERT_CF_CLEAR "msg"` — halt if carry flag is set after an operation
  - `ASSERT_MAGIC reg, 'XXXX', "msg"` — halt if 4-byte magic at [reg] mismatches
- **Strategic assert placements**:
  - Kernel: after FS.BIN load (magic check), after FS init (CF check), after
    SHELL.BIN load (magic check)
  - FS.BIN: after directory sector read (CF check), after directory magic
    validation
- `ASSERT_HAS_SCREEN` opt-in define — enables screen output on assertion failure
  for binaries that provide a `puts` subroutine (kernel has it, FS does not)
- All assertion failures dump full register state to serial via `DBG_REGS`
- On failure: logs to serial (+ screen if available), dumps registers, then
  `cli; hlt` — CPU halts permanently to prevent corrupted state propagation

### Changed
- FS.BIN debug sector count: 3 → 4 (assert code adds ~150 bytes)
- KERNEL.BIN debug sector count: 7 → 8 (assert code adds ~60 bytes)
- Release builds unchanged — all assert macros compile to 0 bytes

---

## [0.7.1] — 2026-05-13

### Added
- **User-mode debug syscalls** — three new INT 0x80 functions (AH=0x20–0x22)
  allow user-mode programs to emit debug output through the kernel's serial
  port without direct COM1 access:
  - `SYS_DBG_PRINT` (0x20) — print a tagged message: `[TAG] message`
  - `SYS_DBG_HEX16` (0x21) — print a tagged hex value: `[TAG] NNNN`
  - `SYS_DBG_REGS`  (0x22) — dump all registers with tag: `[TAG] AX=... DI=...`
- **Caller-supplied tag** — DS:BX points to a NUL-terminated tag string
  (e.g., `"SHL"`, `"FS"`).  If BX=0, defaults to `"USR"`.
- **Shell debug tracing** — shell.asm now emits `[SHL]` tagged debug messages
  at init, command dispatch (logs the typed command), and unknown-command path
- All debug syscall handlers are **no-ops in release builds** (zero overhead)

### Changed
- `SYSCALL_MAX` raised from 0x1B to 0x22 (jump table extended with gap
  entries 0x1C–0x1F pointing to `sc_unknown`)
- Syscall name table extended with `DBG_PRINT`, `DBG_HEX16`, `DBG_REGS`
  entries for serial trace output

---

## [0.7.0] — 2026-05-17

### Added
- **Serial debug logging** — COM1 output at 115200 baud, 8N1 via pure port I/O
  (`src/include/serial.inc`): `serial_init`, `serial_putc`, `serial_puts`,
  `serial_hex8`, `serial_hex16`, `serial_crlf`
- **Debug macros** (`src/include/debug.inc`): `DBG "msg"`, `DBG_REG "name", reg`,
  `DBG_REGS` — inline string + call pattern, zero bytes in release builds
- **Syscall tracing** — kernel INT 0x80 handler logs `[SYS] AH=xx AX=xxxx BX=xxxx`
  to serial for every syscall invocation (debug build only)
- **Filesystem tracing** — FS.BIN INT 0x81 handler logs `[FS] AH=xx` to serial
  for every filesystem syscall (debug build only)
- **Debug build mode** — `build.bat /debug` or `pwsh tools/build.ps1 -DebugBuild`
  passes `-dDEBUG` to NASM; all debug code compiles to zero bytes in release
- **Separate debug/release VHDs** — release builds produce `mini-os.vhd`, debug
  builds produce `mini-os-debug.vhd`; both can coexist in `build/boot/`
- **Boot milestone logging** — kernel prints serial messages at each init stage:
  serial init, INT 0x80 installed, FS.BIN loaded, INT 0x81 ready, SHELL.BIN loaded
- **Serial reader script** — `read-serial.bat` / `tools/read-serial.ps1` connects
  to the Hyper-V COM1 named pipe and streams debug output to the console

### Changed
- Build scripts (`tools/build.ps1`, `build.bat`) updated for `-DebugBuild` switch
- `setup-vm.ps1` now auto-configures COM1 as named pipe (`\\.\pipe\minios-serial`)
  on both new and existing VMs; prompts for VHD variant (release/debug) when both
  VHDs are present
- Kernel sector count: conditional 6 (release) / 7 (debug) via `%ifdef DEBUG`
- FS.BIN sector count: conditional 2 (release) / 3 (debug) via `%ifdef DEBUG`
- `serial.inc` placed at end of kernel.asm and fs.asm (after all code/data)
  to avoid polluting binary headers at offset 0
- Shell monitor command renamed from `mon` to `mnmon` in DEBUGGING.md
  (follows `mn` prefix convention: mnos, mnfs, mnex, mnmon)

---

## [0.6.0] — 2026-05-12

### Added
- **MNFS Flat Filesystem** — 1-sector directory table at partition sector 2,
  up to 15 files, 32-byte entries with 8.3 names, attributes, and size tracking
- **FS.BIN kernel module** (`src/fs/fs.asm`) — loaded at 0x0800, owns INT 0x81
  filesystem syscall interface with 4 functions:
  - `FS_LIST_FILES (0x01)` — copy cached directory to caller buffer
  - `FS_FIND_FILE (0x02)` — search by 8.3 name, return sector/size
  - `FS_READ_FILE (0x03)` — read file contents via kernel INT 0x80 disk I/O
  - `FS_GET_INFO (0x04)` — return FS version, file count, max entries, used/capacity sectors
- **`dir` shell command** — lists all files on disk with name, type, sectors, bytes,
  total size summary, and disk space statistics (used/free/total KB)
- **`find_file.inc`** — bootstrap directory lookup subroutine used by VBR, LOADER,
  and KERNEL to find files by name without hardcoded offsets
- **`mnfs.inc`** — shared constants for MNFS directory format, entry fields, and
  INT 0x81 syscall numbers
- **`doc/FILESYSTEM.md`** — complete MNFS specification (14 sections)
- **Linux-style boot messages** — `[OK]`/`[FAIL]` status indicators during boot
  with enhanced 12-register dump (AX-DX, SI/DI/SP/BP, DS/ES/SS/FL) on failure
- **MNFS_HDR_CAPACITY** — directory header field at offset 8 stores partition
  data capacity; stamped by `create-disk.ps1`, returned by `FS_GET_INFO`

### Changed
- **No more hardcoded disk offsets** — all binaries are located via MNFS directory
  lookup at boot time; adding or resizing a file requires no source code changes
- Boot chain now loads FS.BIN before SHELL: MBR → VBR → LOADER → KERNEL → FS.BIN → SHELL
- KERNEL loads FS.BIN at 0x0800 (reuses LOADER's memory), calls init (installs INT 0x81),
  then loads SHELL — both found via `find_file` directory search
- VBR finds LOADER.BIN via directory lookup (was hardcoded partition offset 4)
- LOADER finds KERNEL.BIN via directory lookup (was hardcoded partition offset 20)
- `create-disk.ps1` completely rewritten: packs files contiguously after directory
  sector, generates MNFS directory table automatically from binary sizes
- `build.ps1` assembles 6 binaries (added FS.BIN)
- `disk.inc` replaced by `mnfs.inc` (partition offsets eliminated)
- KERNEL.BIN grew from 4 to 6 sectors (added find_file.inc + fname strings)
- SHELL.BIN grew from 10 to 12 sectors (dir command + 512-byte directory buffer)
- Version banner updated to v0.6.0

### Fixed
- **AH register overlap bugs** — systemic class where `mov ah, SYS_xxx` clobbers
  bits 8-15 of AX/EAX when the same register holds data. Three instances fixed:
  - `SYS_READ_SECTOR` (0x04): LBA input moved from EAX to **EDI**
  - `SYS_PRINT_DEC16` (0x12): value input moved from AX to **DX**
  - `SYS_PRINT_HEX16` (0x11): value input moved from AX to **DX**
- **CF propagation through INT/IRET** — `iret` restores the caller's saved FLAGS,
  silently discarding the handler's carry flag. Created `syscall_ret_cf` macro
  (`sti; retf 2`) applied to 6 CF-returning kernel handlers
- **`dir` column alignment** — numeric columns now right-justified with leading
  spaces via `rjust_dec16` helper routine

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
