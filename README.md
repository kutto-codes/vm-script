# VM Wizard

An interactive, prompt-driven terminal tool that creates VirtualBox virtual machines. It checks your hardware, adapts its recommendations to your machine, and walks you through every choice. Press **Enter** at any prompt to accept the default.

Built for Debian/Linux hosts running VirtualBox 7.x.

## Features

- **System checks** – CPU virtualization (VT-x / AMD-V), RAM, CPU threads, free disk space, VirtualBox kernel driver, Secure Boot, and KVM conflicts
- **Hardware classes** – detects low-end, mid-range, or high-end machines and picks sensible defaults for each
- **OS profiles** – Debian, Ubuntu, Kali, other Linux, Windows 10, Windows 11, FreeBSD, or "not sure", each with its own minimums, firmware, and video settings
- **ISO browser** – navigate your folders to select the installer ISO, type a full path, or skip and attach one later
- **Resource prompts** – RAM, CPU cores, and disk size with validation and warnings when you over-allocate
- **Network choices** – NAT (default), Bridged, Host-only, or Internal, with automatic fallback to NAT if setup fails
- **Safe failure** – cleans up a half-created VM if something goes wrong

## Requirements

- Debian (or another Linux distribution) with **VirtualBox 7.x** installed
- `vboxmanage` available in your `PATH`
- Bash 4+
- Hardware virtualization enabled in BIOS/UEFI
- An installer ISO for the OS you want to run

## Installation

```bash
git clone <your-repo-url>
cd <your-repo>
chmod +x vm-wizard.sh
```

Or just download `vm-wizard.sh` and make it executable.

## Usage

```bash
./vm-wizard.sh
```

### Walkthrough

| Step | What happens |
|------|--------------|
| 1. Machine check | Reports CPU, RAM, disk, and virtualization status, and classifies your machine |
| 2. Choose OS | Pick from a numbered list (default: Debian) |
| 3. Find the ISO | Browse folders starting in `~/Downloads`. `u` = go up, `p` = type a path, `n` = skip |
| 4. Resources | Set RAM (MB), CPU cores, and disk size (GB) |
| 5. Network | Pick a network type, or press Enter for NAT |
| 6. Name | Name your VM, or press Enter for a suggested name |
| Summary | Review everything, then confirm to create |

## Hardware classes and defaults

| Class | Condition | Behavior |
|-------|-----------|----------|
| Low-end | Under 4 GB RAM, or 2 or fewer threads | Minimum safe resources, small disk, audio off, 32 MB video memory |
| Mid-range | Anything between | Balanced settings, 64 MB video memory |
| High-end | 15 GB+ RAM and 8+ threads | Generous RAM and CPU, 128 MB video memory |

Recommendations never exceed half of your RAM or CPU threads, or 70% of free disk space. You can still enter higher values, but the wizard warns you.

To tune these thresholds, edit the tier logic in `system_check()` and the defaults in `choose_resources()`.

## OS profiles

| OS | Min RAM | Min CPU | Min disk | Notes |
|----|---------|---------|----------|-------|
| Debian | 1 GB | 1 | 10 GB | EFI |
| Ubuntu | 2 GB | 1 | 15 GB | EFI |
| Kali | 2 GB | 1 | 20 GB | EFI |
| Other Linux | 1 GB | 1 | 10 GB | BIOS |
| Windows 10 | 2 GB | 2 | 40 GB | BIOS, you supply the ISO |
| Windows 11 | 4 GB | 2 | 64 GB | EFI + TPM 2.0 enabled |
| FreeBSD | 1 GB | 1 | 10 GB | BIOS |

Windows ISOs must be downloaded from Microsoft yourself.

## Network types

| Type | Use it when |
|------|-------------|
| **NAT** (default) | You just want the VM to reach the internet. Works almost everywhere. |
| **Bridged** | The VM should appear as its own device on your network. May be unreliable over Wi-Fi. |
| **Host-only** | You want a private link between your PC and the VM, with no internet. |
| **Internal** | You want an isolated network between VMs only. |

## After the VM is created

Start it:

```bash
vboxmanage startvm "<vm-name>"
```

After installing the guest OS, eject the ISO so it boots from the disk:

```bash
vboxmanage storageattach "<vm-name>" --storagectl SATA --port 1 --device 0 --type dvddrive --medium emptydrive
```

Delete the VM and its disk:

```bash
vboxmanage unregistervm "<vm-name>" --delete
```

For clipboard sharing and automatic screen resizing, install **Guest Additions** inside the VM.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `vboxmanage: command not found` | Install VirtualBox (use Oracle's apt repository on Debian 13) |
| `kernel driver not installed` | Run `sudo /sbin/vboxconfig`. Install `dkms` and `linux-headers-$(uname -r)` first |
| Modules won't load | Secure Boot may be blocking them. Check with `mokutil --sb-state` and sign the modules or disable Secure Boot |
| No VT-x / AMD-V detected | Enable Intel VT-x or AMD-V in BIOS/UEFI |
| VM is slow | Close KVM/libvirt VMs, or give the VM fewer resources than half of your host |
| `VERR_ACCESS_DENIED` creating the VM | The VM folder is invalid. Fix it with `vboxmanage setproperty machinefolder ~/VirtualBox-VMs` (the wizard also repairs this itself) |
| VM name already exists | Pick a different name, or remove the old VM with `unregistervm --delete` |
| Bridged network not working | Switch to NAT, especially if you are on Wi-Fi |

## Project structure

```
.
├── vm-wizard.sh    # the interactive wizard
├── create-vm.sh    # simple non-interactive version (2 CPU, 4 GB RAM, 50 GB disk)
└── README.md
```

### `create-vm.sh` (optional simple version)

```bash
./create-vm.sh /path/to/installer.iso [VM_NAME] [OSTYPE]
```

Creates a VM with fixed settings in one command. List valid OS types with `vboxmanage list ostypes | grep '^ID'`.

## Limitations

- Linux hosts only (uses `/proc`, `lsmod`, and `nproc`)
- Creates a single network adapter
- Does not install the guest OS for you; it prepares the VM and attaches the ISO
- Tested against VirtualBox 7.2 on Debian 13

## License

MIT, or choose your own. Add a `LICENSE` file if you publish this.
