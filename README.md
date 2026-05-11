# mini-os

A minimalistic operating system, built from scratch.
Currently: MBR reads the partition table, chain-loads a multi-sector VBR, and the VBR
drops into an interactive shell (`mnos:\>`) where you can run commands like `sysinfo`
to display system information.

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
2. Assemble the MBR and VBR (16 sectors / 8 KB)
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
  MNOS v0.2.5

mnos:\>
```

Type `help` for a list of commands, or `sysinfo` for system information.

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
│   └── boot/
│       ├── mbr.asm           # MBR — partition table scan + VBR chain-load
│       └── vbr.asm           # VBR — interactive shell + sysinfo (16 sectors)
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

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT — see [LICENSE](LICENSE).
