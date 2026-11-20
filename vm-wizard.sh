#!/usr/bin/env bash
# =============================================================================
#  vm-wizard.sh - interactive VirtualBox VM creator for the terminal
#
#  What it does:
#    1. Checks your machine (CPU virtualization, RAM, threads, free disk, KVM,
#       VirtualBox kernel modules, Secure Boot)
#    2. Classifies it as LOW-END / MID-RANGE / HIGH-END and picks safe defaults
#    3. Asks which OS you want to run (Linux, Windows 10/11, ...)
#    4. Lets you browse your folders to point at the installer ISO
#    5. Asks for RAM, CPUs and disk size (press Enter to accept the default)
#    6. Asks for the network type (press Enter for NAT)
#    7. Shows a summary, creates the VM, and offers to start it
#
#  Usage:  chmod +x vm-wizard.sh && ./vm-wizard.sh
# =============================================================================
set -u

VM_CREATED=0
VM=""

# ---------- small helpers ----------------------------------------------------
ok()   { printf '  [ OK ]  %s\n' "$*"; }
warn() { printf '  [WARN]  %s\n' "$*"; }
bad()  { printf '  [FAIL]  %s\n' "$*"; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

die() {
  echo; bad "$*" >&2
  if (( VM_CREATED )) && [[ -n $VM ]]; then
    echo "  Cleaning up the half-created VM '$VM'..."
    vboxmanage unregistervm "$VM" --delete >/dev/null 2>&1
  fi
  exit 1
}
trap 'echo; die "Interrupted."' INT

# ask "prompt" default  -> REPLY
ask() {
  local p="$1" d="$2"
  read -r -p "$p [$d]: " REPLY
  REPLY="${REPLY:-$d}"
}

# ask_int "prompt" default min max  -> REPLY (validated whole number)
ask_int() {
  local p="$1" d="$2" lo="$3" hi="$4"
  (( hi < lo )) && hi=$lo
  while true; do
    read -r -p "$p [default $d, allowed $lo-$hi]: " REPLY
    REPLY="${REPLY:-$d}"
    if [[ $REPLY =~ ^[0-9]+$ ]] && (( REPLY >= lo && REPLY <= hi )); then return; fi
    echo "  Please enter a whole number between $lo and $hi."
  done
}

clamp() { # value lo hi
  local v=$1 lo=$2 hi=$3
  (( hi < lo )) && hi=$lo
  (( v < lo )) && v=$lo
  (( v > hi )) && v=$hi
  echo "$v"
}

# ---------- step 1: system checks -------------------------------------------
system_check() {
  echo; hr; echo " STEP 1: Checking your machine"; hr

  command -v vboxmanage >/dev/null || die "VirtualBox (vboxmanage) is not installed."
  ok "VirtualBox $(vboxmanage --version)"

  CPU_MODEL=$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//')
  THREADS=$(nproc)
  RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  ok "CPU: ${CPU_MODEL:-unknown} ($THREADS threads)"
  ok "RAM: $RAM_MB MB total"

  # Hardware virtualization (Intel VT-x = vmx, AMD-V = svm)
  if grep -Eq '(vmx|svm)' /proc/cpuinfo; then
    ok "Hardware virtualization (VT-x / AMD-V) is supported"
  else
    bad "No VT-x / AMD-V found. Enable it in BIOS/UEFI, otherwise 64-bit guests will not run."
    read -r -p "  Continue anyway? [y/N]: " a
    [[ $a =~ ^[Yy]$ ]] || exit 1
  fi

  # VirtualBox kernel module
  if lsmod | grep -q '^vboxdrv'; then
    ok "VirtualBox kernel driver (vboxdrv) is loaded"
  else
    warn "vboxdrv is not loaded. Try: sudo /sbin/vboxconfig"
    if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
      warn "Secure Boot is ON - it blocks unsigned VirtualBox modules. Sign them or disable Secure Boot."
    fi
  fi

  # KVM conflict
  if lsmod | grep -Eq '^kvm_(intel|amd)'; then
    warn "KVM is loaded; VirtualBox may run slower while KVM/libvirt VMs are active."
  fi

  # Machine folder (fix it if it points somewhere unusable)
  MF=$(vboxmanage list systemproperties | sed -n 's/^Default machine folder: *//p')
  if [[ -z $MF ]] || ! { mkdir -p "$MF" 2>/dev/null && [[ -w $MF ]]; }; then
    warn "VM folder '$MF' is not usable. Using $HOME/VirtualBox VMs instead."
    MF="$HOME/VirtualBox VMs"
    mkdir -p "$MF" || die "Cannot create $MF"
    vboxmanage setproperty machinefolder "$MF" || die "Could not set machine folder."
  fi
  FREE_MB=$(df -Pm "$MF" | awk 'NR==2{print $4}')
  FREE_GB=$(( FREE_MB / 1024 ))
  ok "VM folder: $MF  (${FREE_GB} GB free)"

  # Classify the machine
  if (( RAM_MB < 4096 || THREADS <= 2 )); then
    TIER=low
  elif (( RAM_MB >= 15000 && THREADS >= 8 )); then
    TIER=high
  else
    TIER=mid
  fi
  echo
  case $TIER in
    low)  echo "  Machine class: LOW-END  -> light settings, small disk, no audio, to keep things smooth." ;;
    mid)  echo "  Machine class: MID-RANGE -> balanced settings." ;;
    high) echo "  Machine class: HIGH-END -> generous RAM/CPU for a fast VM." ;;
  esac
  (( FREE_GB < 15 )) && warn "Low disk space: only ${FREE_GB} GB free. Disk will be kept small (it grows only as used)."
}

# ---------- step 2: choose the OS -------------------------------------------
# Sets: OS_NAME OSTYPE MIN_RAM REC_RAM MIN_CPU REC_CPU MIN_DISK REC_DISK EFI TPM GFX IS_WIN
set_profile() {
  IS_WIN=0; TPM=0; EFI=1; GFX=vmsvga
  case "$1" in
    1) OS_NAME="Debian Linux";           OSTYPE=Debian_64;    MIN_RAM=1024; REC_RAM=4096; MIN_CPU=1; REC_CPU=2; MIN_DISK=10; REC_DISK=30 ;;
    2) OS_NAME="Ubuntu Linux";           OSTYPE=Ubuntu_64;    MIN_RAM=2048; REC_RAM=4096; MIN_CPU=1; REC_CPU=2; MIN_DISK=15; REC_DISK=30 ;;
    3) OS_NAME="Kali Linux";             OSTYPE=Debian_64;    MIN_RAM=2048; REC_RAM=4096; MIN_CPU=1; REC_CPU=2; MIN_DISK=20; REC_DISK=50 ;;
    4) OS_NAME="Other Linux (64-bit)";   OSTYPE=Linux_64;     MIN_RAM=1024; REC_RAM=2048; MIN_CPU=1; REC_CPU=2; MIN_DISK=10; REC_DISK=30; EFI=0 ;;
    5) OS_NAME="Windows 10 (64-bit)";    OSTYPE=Windows10_64; MIN_RAM=2048; REC_RAM=4096; MIN_CPU=2; REC_CPU=2; MIN_DISK=40; REC_DISK=60; EFI=0; GFX=vboxsvga; IS_WIN=1 ;;
    6) OS_NAME="Windows 11 (64-bit)";    OSTYPE=Windows11_64; MIN_RAM=4096; REC_RAM=8192; MIN_CPU=2; REC_CPU=4; MIN_DISK=64; REC_DISK=80; EFI=1; TPM=1; GFX=vboxsvga; IS_WIN=1 ;;
    7) OS_NAME="FreeBSD (64-bit)";       OSTYPE=FreeBSD_64;   MIN_RAM=1024; REC_RAM=2048; MIN_CPU=1; REC_CPU=2; MIN_DISK=10; REC_DISK=20; EFI=0 ;;
    *) OS_NAME="Other / not sure";       OSTYPE=Other_64;     MIN_RAM=1024; REC_RAM=2048; MIN_CPU=1; REC_CPU=2; MIN_DISK=10; REC_DISK=30; EFI=0 ;;
  esac
}

choose_os() {
  echo; hr; echo " STEP 2: What do you want to run in the VM?"; hr
  cat <<'EOF'
   1) Debian Linux
   2) Ubuntu Linux
   3) Kali Linux
   4) Other Linux (64-bit)
   5) Windows 10
   6) Windows 11
   7) FreeBSD
   8) Other / not sure
EOF
  local c
  while true; do
    read -r -p "Choose [1]: " c; c="${c:-1}"
    [[ $c =~ ^[1-8]$ ]] && break
    echo "  Enter a number from 1 to 8."
  done
  set_profile "$c"
  echo "  -> $OS_NAME"
  (( IS_WIN )) && echo "  Note: Windows needs an ISO you download yourself from Microsoft."
  (( TPM )) && echo "  Note: Windows 11 needs EFI + TPM 2.0; the wizard enables both."
}

# ---------- step 3: browse for the ISO --------------------------------------
browse_iso() {
  local dir="$1" i sel name p it
  [[ -d $dir ]] || dir="$HOME"
  ISO_PATH=""
  echo; hr; echo " STEP 3: Point me to the installer ISO"; hr
  while true; do
    mapfile -t _dirs < <(find "$dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' 2>/dev/null | sort -f)
    mapfile -t _isos < <(find "$dir" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -iname '*.iso' -printf '%f\n' 2>/dev/null | sort -f)
    echo; echo "  Current folder: $dir"
    echo "  [u] go up   [p] type a full path   [n] skip (attach an ISO later)"
    i=1; _items=()
    for name in "${_isos[@]}"; do printf '  [%d] ISO  %s\n' "$i" "$name"; _items+=("f:$name"); ((i++)); done
    for name in "${_dirs[@]}"; do printf '  [%d] DIR  %s/\n' "$i" "$name"; _items+=("d:$name"); ((i++)); done
    (( ${#_items[@]} == 0 )) && echo "  (nothing here - no folders or ISO files)"
    read -r -p "  Choose: " sel
    case "$sel" in
      u|U) dir="$(dirname "$dir")" ;;
      n|N) return ;;
      p|P)
        read -r -e -p "  Full path to the ISO file: " p
        p="${p/#\~/$HOME}"
        if [[ -f $p ]]; then ISO_PATH="$(readlink -f "$p")"; return; else echo "  That is not a file."; fi ;;
      ''|*[!0-9]*) echo "  Invalid choice." ;;
      *)
        if (( sel >= 1 && sel <= ${#_items[@]} )); then
          it="${_items[sel-1]}"
          case "${it%%:*}" in
            d) dir="$dir/${it#*:}" ;;
            f) ISO_PATH="$dir/${it#*:}"; echo "  Selected: $ISO_PATH"; return ;;
          esac
        else
          echo "  Invalid choice."
        fi ;;
    esac
  done
}

# ---------- step 4: resources ------------------------------------------------
choose_resources() {
  echo; hr; echo " STEP 4: Resources (press Enter to accept the recommended value)"; hr

  # Recommended values, adjusted for the machine class
  local rec_ram=$REC_RAM rec_cpu=$REC_CPU rec_disk=$REC_DISK
  case $TIER in
    low)  rec_ram=$(( REC_RAM / 2 )); (( rec_ram < MIN_RAM )) && rec_ram=$MIN_RAM
          rec_cpu=$MIN_CPU; rec_disk=$MIN_DISK; VRAM=32; AUDIO=0 ;;
    mid)  VRAM=64;  AUDIO=1 ;;
    high) rec_ram=$(( REC_RAM * 3 / 2 )); rec_cpu=$(( REC_CPU * 2 )); VRAM=128; AUDIO=1 ;;
  esac
  (( IS_WIN && VRAM < 64 )) && VRAM=64

  # Never recommend more than half of the host
  local ram_budget=$(( RAM_MB / 2 )); (( ram_budget < 512 )) && ram_budget=512
  local cpu_budget=$(( THREADS / 2 )); (( cpu_budget < 1 )) && cpu_budget=1
  local disk_budget=$(( FREE_GB * 70 / 100 ))
  rec_ram=$(clamp "$rec_ram" 512 "$ram_budget")
  rec_cpu=$(clamp "$rec_cpu" 1 "$cpu_budget")
  rec_disk=$(clamp "$rec_disk" 5 "$disk_budget")

  echo "  Minimum for $OS_NAME: ${MIN_RAM} MB RAM, ${MIN_CPU} CPU, ${MIN_DISK} GB disk"
  (( rec_ram  < MIN_RAM  )) && warn "Your machine can't comfortably give the minimum RAM; the VM may be slow."
  (( rec_cpu  < MIN_CPU  )) && warn "$OS_NAME wants at least $MIN_CPU CPUs; your machine is small."
  (( rec_disk < MIN_DISK )) && warn "Free disk is below the ${MIN_DISK} GB minimum for $OS_NAME."
  echo

  ask_int "  RAM in MB"   "$rec_ram"  256 $(( RAM_MB * 80 / 100 ));  RAM=$REPLY
  ask_int "  CPU cores"   "$rec_cpu"  1   "$THREADS";                CPUS=$REPLY
  ask_int "  Disk in GB"  "$rec_disk" 5   $(( FREE_GB * 90 / 100 )); DISK_GB=$REPLY

  (( RAM  > RAM_MB / 2 ))  && warn "That is over half your RAM; your host may lag while the VM runs."
  (( CPUS > THREADS / 2 )) && warn "That is over half your CPU threads; your host may lag."
  echo "  (The disk is dynamic: it only uses real space as the VM fills it.)"
}

# ---------- step 5: network --------------------------------------------------
choose_network() {
  NET_ARGS=(--nic1 nat); NET_DESC="NAT"
  echo; hr; echo " STEP 5: Network type (press Enter if you don't know)"; hr
  cat <<'EOF'
   1) NAT        - VM can use the internet; simplest, works everywhere  (default)
   2) Bridged    - VM gets its own IP on your network, like a real PC
   3) Host-only  - private link between you and the VM, no internet
   4) Internal   - isolated network between VMs only
EOF
  local n x def pick
  read -r -p "Choose [1]: " n; n="${n:-1}"
  case $n in
    2)
      mapfile -t _ifs < <(vboxmanage list bridgedifs | sed -n 's/^Name: *//p')
      if (( ${#_ifs[@]} == 0 )); then warn "No usable network adapter found. Using NAT."; return; fi
      def=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
      pick=""
      for x in "${_ifs[@]}"; do [[ $x == "$def" ]] && pick=$x; done
      [[ -z $pick ]] && pick=${_ifs[0]}
      NET_ARGS=(--nic1 bridged --bridgeadapter1 "$pick"); NET_DESC="Bridged via $pick"
      [[ $pick == w* ]] && warn "Bridging over Wi-Fi can be unreliable. NAT is safer if it fails." ;;
    3)
      mapfile -t _his < <(vboxmanage list hostonlyifs | sed -n 's/^Name: *//p')
      if (( ${#_his[@]} == 0 )); then
        vboxmanage hostonlyif create >/dev/null 2>&1
        mapfile -t _his < <(vboxmanage list hostonlyifs | sed -n 's/^Name: *//p')
      fi
      if (( ${#_his[@]} == 0 )); then warn "Could not set up a host-only adapter. Using NAT."; return; fi
      NET_ARGS=(--nic1 hostonly --hostonlyadapter1 "${_his[0]}"); NET_DESC="Host-only (${_his[0]})" ;;
    4) NET_ARGS=(--nic1 intnet --intnet1 labnet); NET_DESC="Internal (labnet)" ;;
    1) ;;
    *) warn "Unknown choice. Using NAT." ;;
  esac
  echo "  -> $NET_DESC"
}

# ---------- step 6: name, summary, create -----------------------------------
choose_name() {
  local def; def="$(echo "$OS_NAME" | sed 's/ (.*//; s/[^A-Za-z0-9]/-/g')-VM"
  echo; hr; echo " STEP 6: Name your VM"; hr
  while true; do
    ask "  VM name" "$def"; VM="$REPLY"
    if [[ $VM == */* || -z $VM ]]; then echo "  Names can't contain '/'."; continue; fi
    if vboxmanage list vms | grep -q "^\"$VM\" "; then echo "  A VM called '$VM' already exists. Pick another name."; continue; fi
    break
  done
}

summary() {
  echo; hr; echo " SUMMARY"; hr
  printf '  Name     : %s\n  OS       : %s (%s)\n  CPUs     : %s\n  RAM      : %s MB\n  Disk     : %s GB (dynamic)\n  Video    : %s MB\n  Firmware : %s\n  TPM 2.0  : %s\n  Network  : %s\n  ISO      : %s\n' \
    "$VM" "$OS_NAME" "$OSTYPE" "$CPUS" "$RAM" "$DISK_GB" "$VRAM" \
    "$( (( EFI )) && echo EFI || echo BIOS )" "$( (( TPM )) && echo yes || echo no )" \
    "$NET_DESC" "${ISO_PATH:-(none - attach later)}"
  hr
  read -r -p "Create this VM? [Y/n]: " a
  [[ ${a:-Y} =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
}

create_vm() {
  echo; echo ">> Creating VM '$VM'..."
  vboxmanage createvm --name "$VM" --ostype "$OSTYPE" --register >/dev/null || die "createvm failed."
  VM_CREATED=1

  local args=(--cpus "$CPUS" --memory "$RAM" --vram "$VRAM" --graphicscontroller "$GFX"
              --ioapic on --clipboard-mode bidirectional --draganddrop bidirectional
              --boot1 dvd --boot2 disk --boot3 none --boot4 none)
  if (( EFI )); then args+=(--firmware efi); else args+=(--firmware bios); fi
  (( TPM )) && args+=(--tpm-type 2.0)
  if (( AUDIO )); then args+=(--audio-driver default --audio-controller hda --audio-enabled on)
  else args+=(--audio-enabled off); fi
  args+=("${NET_ARGS[@]}")
  vboxmanage modifyvm "$VM" "${args[@]}" || die "modifyvm failed."

  echo ">> Creating ${DISK_GB} GB disk..."
  local disk="$MF/$VM/$VM.vdi"
  vboxmanage createmedium disk --filename "$disk" --size $(( DISK_GB * 1024 )) --format VDI >/dev/null \
    || die "Could not create the disk (not enough space?)."

  echo ">> Attaching storage..."
  vboxmanage storagectl "$VM" --name SATA --add sata --controller IntelAhci --portcount 2 --bootable on || die "storagectl failed."
  vboxmanage storageattach "$VM" --storagectl SATA --port 0 --device 0 --type hdd --medium "$disk" || die "Could not attach disk."
  if [[ -n $ISO_PATH ]]; then
    vboxmanage storageattach "$VM" --storagectl SATA --port 1 --device 0 --type dvddrive --medium "$ISO_PATH" || die "Could not attach ISO."
  else
    vboxmanage storageattach "$VM" --storagectl SATA --port 1 --device 0 --type dvddrive --medium emptydrive
  fi
  VM_CREATED=0   # success: don't clean up on exit

  echo; hr; echo " DONE - '$VM' is ready."; hr
  echo "  After installing the OS, eject the ISO with:"
  echo "    vboxmanage storageattach \"$VM\" --storagectl SATA --port 1 --device 0 --type dvddrive --medium emptydrive"
  echo "  Delete the VM later with:"
  echo "    vboxmanage unregistervm \"$VM\" --delete"
  echo
  read -r -p "Start the VM now? [Y/n]: " a
  if [[ ${a:-Y} =~ ^[Yy]$ ]]; then vboxmanage startvm "$VM"; fi
}

# ---------- main -------------------------------------------------------------
echo "============================================================"
echo "   VirtualBox VM Wizard  -  create a VM from the terminal"
echo "============================================================"
system_check
choose_os
if [[ -d $HOME/Downloads ]]; then browse_iso "$HOME/Downloads"; else browse_iso "$HOME"; fi
choose_resources
choose_network
choose_name
summary
create_vm
