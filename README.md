# mini-os

A minimalistic operating system, built from scratch — currently at **v0.4.0**.
MBR reads the partition table, chain-loads a VBR which loads a stage-2 loader
(A20 gate enablement), which loads the interactive shell (`mnos:\>`) with
commands for system info, CPU details, memory diagnostics, version info, and more.

![mini-os booting in Hyper-V](doc/booted.gif)

[![Build](../../actions/workflows/build.yml/badge.svg)](../../actions/workflows/build.yml)

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| **NASM** | x86 assembler | [nasm.us](https://www.nasm.us/) — or let `build.bat` download it automatically |
| **PowerShell 7+** | Build system & VHD creation | [aka.ms/powershell](https://aka.ms/powershell) |

## Quick Start

```cmd
build.bat
```

The build script will:
1. Download NASM into `tools/nasm/` if not already installed
2. Assemble MBR, VBR, LOADER, and SHELL binaries
3. Create `build/boot/mini-os.vhd` (16 MB fixed VHD with partition table)

## Running in Hyper-V

```cmd
:: First time — creates the VM and attaches the VHD (requires Admin)
setup-vm.bat

:: After rebuilding — updates the VM's VHD in-place
build.bat
setup-vm.bat
```

The script will prompt for a VM name and location (defaults are fine), then create a Gen 1 / 32 MB RAM VM with no network adapter. On repeat runs it stops the VM, swaps in the latest VHD, and leaves it ready to start.

You should see the MBR banner and partition table info, then the shell:

```
  MNOS v0.4.0

mnos:\>
```

Type `help` for a list of commands:

| Command | Description |
|---------|-------------|
| `sysinfo` | 5 pages of hardware info (CPU/CPUID, memory/E820, BDA, video/disk/EDD, IVT) |
| `mem` | Memory diagnostics — conventional/extended RAM, A20 gate, layout, E820 map |
| `ver` | Version, architecture, platform, and build info |
| `help` | List available commands |
| `cls` | Clear screen |
| `reboot` | Warm reboot |

```powershell
Start-VM -Name 'mini-os'           # start the VM
vmconnect localhost 'mini-os'      # open the console
```

## Project Structure

```
mini-os/
├── .github/
│   ├── ISSUE_TEMPLATE/       # Bug report & feature request templates
│   └── workflows/
│       ├── build.yml         # CI — build & verify on push/PR
│       └── release.yml       # CD — package & release on version tags
├── doc/
│   └── DESIGN.md             # Architecture & design document
├── src/
│   ├── boot/
│   │   ├── mbr.asm           # MBR — partition table scan + VBR chain-load
│   │   └── vbr.asm           # VBR — loads LOADER.BIN (2 sectors)
│   ├── loader/
│   │   └── loader.asm        # Stage-2 loader — A20 gate, loads SHELL.BIN
│   └── shell/
│       └── shell.asm         # Interactive shell + all commands
├── tools/
│   ├── build.ps1             # Build logic (called by build.bat)
│   ├── create-disk.ps1       # Partitioned raw disk image creator
│   ├── create-vhd.bat        # VHD tool — batch wrapper
│   ├── create-vhd.ps1        # Raw image → VHD converter (pure PowerShell)
│   ├── setup-vm.ps1          # Hyper-V VM create/update logic
│   └── nasm/                 # Auto-downloaded NASM (gitignored)
├── build/                    # Build output (gitignored)
│   └── boot/
│       ├── mbr.bin
│       ├── vbr.bin
│       ├── loader.bin
│       ├── shell.bin
│       ├── mini-os.img
│       └── mini-os.vhd
├── build.bat                 # Build entry point
├── setup-vm.bat              # Hyper-V VM setup entry point
├── CHANGELOG.md
├── CODE_OF_CONDUCT.md
├── CONTRIBUTING.md
├── LICENSE
└── README.md
```

## Design & Architecture

See **[doc/DESIGN.md](doc/DESIGN.md)** for the full architecture document — boot sequence,
memory layout, VHD format, shell internals, disk layout, and project roadmap.

## Version History

Each version is a tagged release you can checkout to see the project at that stage.

| Tag | Description | What you'll see |
|-----|-------------|-----------------|
| `v0.1.0` | **M0 — Hello World** | MBR prints "mini-os" and halts |
| `v0.2.0` | **M1 — Partition table + VBR** | MBR scans partition table, chain-loads VBR from active partition |
| `v0.2.1` | **Multi-sector boot area** | VBR header (`MNOS` magic + sector count), MBR two-phase load, heavily commented code |
| `v0.2.2` | **System info display** | VBR shows 4 pages of hardware info (memory, BDA, video/disk, IVT) |
| `v0.2.5` | **M2 — Interactive shell** | `mnos:\>` prompt with `sysinfo`, `help`, `cls`, `reboot` commands |
| `v0.2.6` | **`mem` command** | Detailed memory info: conventional/extended RAM, A20 gate status, memory layout, E820 map |
| `v0.2.7` | **`ver` + CPU/EDD sysinfo** | Version command, CPUID details page, EDD disk info, sysinfo now 5 pages |
| `v0.3.0` | **A20 gate enablement** | VBR enables A20 at boot (BIOS/8042/Fast A20 fallbacks), full memory access above 1 MB |
| `v0.4.0` | **Three-stage boot chain** | VBR → LOADER.BIN → SHELL.BIN split; A20 in loader, shell as separate binary, BIB at 0x0600 |

```cmd
git checkout v0.1.0      # see the project at any prior milestone
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT — see [LICENSE](LICENSE).
