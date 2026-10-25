# shellcheck shell=bash disable=SC2034  # the variables are used by the scripts that source this file
# Sourced by the scripts in this directory: settings, sha256 pins and shared checks.
HERE=$(dirname "$(readlink -f "$0")")
# shellcheck source=config.sh
. "${P2P_CONFIG:-$HERE/config.sh}"

SUBDIR=updates/p2p
DEPMOD_CONF=/etc/depmod.d/p2p.conf
P2P_CONF=/etc/modprobe.d/zz-nvidia-p2p.conf
BACKUP_BASE=/var/backups/p2p-modules
KDIR=/lib/modules/$KVER
DEST=$KDIR/$SUBDIR
declare -A SHA=()
MODS=()

run() { echo "+ $*"; [ "$DRY" = 1 ] || "$@"; }
die() { echo "ABORT: $*"; exit 1; }
loaded() { [ -d "/sys/module/$1" ]; }
param() { cat "/sys/module/$1/parameters/$2" 2>/dev/null; }

srcv() { cat /sys/module/nvidia/srcversion 2>/dev/null; }
# Directory of the stock nvidia module for $KVER (anywhere outside updates/p2p); empty if there is none.
stock_dir() { local f; f=$(find "$KDIR" -path "$DEST" -prune -o -name 'nvidia.ko*' -print | head -1); [ -z "$f" ] || dirname "$f"; }
# ko_in <dir> <module>: the module file in dir, compressed or not.
ko_in() { find "$1" -maxdepth 1 -name "$2.ko*" | head -1; }

# --yes or --dry-run, plus the flags a script allows ($1 = space-separated list); sets DRY and FLAGS.
parse_args() {
  local allowed=$1 a; shift
  DRY=; FLAGS=" "
  for a in "$@"; do
    case $a in
      --yes) DRY=0 ;;
      --dry-run) DRY=1 ;;
      *) [[ " $allowed " == *" $a "* ]] || { echo "refusing: unknown argument $a"; exit 2; }; FLAGS+="$a " ;;
    esac
  done
  [ -n "$DRY" ] || { echo "refusing: give --yes (or --dry-run to only print the plan)"; exit 2; }
}
has_flag() { [[ $FLAGS == *" $1 "* ]]; }

preflight_common() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  [ -n "$GPUS" ] || die "set GPUS in $HERE/config.sh"
  local g
  for g in $GPUS; do [ -e "/sys/bus/pci/devices/$g" ] || die "no PCI device $g"; done
  case $P2P_ENABLE in ""|0|1) ;; *) die "P2P_ENABLE must be empty, 0 or 1" ;; esac
}

# The per-device string, in the format 3080-20gb-rebar writes; P2P_ENABLE=0 adds the per-card opt-out.
dwords() {
  local g
  for g in $GPUS; do
    printf 'pci=%s;RMForceStaticBar1=0;' "$g"; [ "$P2P_ENABLE" != 0 ] || printf 'RMDynBar1P2PEnable=0;'
  done
}
# card_ok <per-device string> <card> [static]: the card's entry has RMForceStaticBar1=0 and, unless "static" is
# given, RMDynBar1P2PEnable=0 exactly when P2P_ENABLE=0. Prints what is wrong.
card_ok() {
  local s
  [[ $1 == *"pci=$2;"* ]] || { echo "no per-device entry for $2"; return 1; }
  s=${1#*"pci=$2;"}; s="${s%%pci=*};"
  [[ $s == *"RMForceStaticBar1=0;"* ]] || { echo "no RMForceStaticBar1=0 for $2"; return 1; }
  if [ "${3:-}" = static ]; then return 0
  elif [ "$P2P_ENABLE" = 0 ]; then
    [[ $s == *"RMDynBar1P2PEnable=0;"* ]] || { echo "P2P_ENABLE=0 but no RMDynBar1P2PEnable=0 for $2"; return 1; }
  else
    [[ $s != *"RMDynBar1P2PEnable=0;"* ]] || { echo "RMDynBar1P2PEnable=0 set for $2 (P2P off) but P2P_ENABLE is not 0"; return 1; }
  fi
}
nvidia_opts() {
  local o=("NVreg_RegistryDwordsPerDevice=$(dwords)" NVreg_EnableResizableBar=0)
  # shellcheck disable=SC2206  # EXTRA_NVIDIA_OPTS is a space-separated list
  o+=($EXTRA_NVIDIA_OPTS)
  printf '%s\n' "${o[@]}"
}
UVM_OPTS=(uvm_disable_hmm=1)

# Reads <dir>/SHA256SUMS (written by your build) into SHA[module]; nvidia-peermem is optional.
load_pins() {
  local f=$1/SHA256SUMS sum name m
  [ -r "$f" ] || die "$f missing: write it right after the build (README, Build and install)"
  while read -r sum name; do name=${name#\*}; name=${name##*/}; SHA[${name%.ko}]=$sum; done <"$f"
  MODS=(nvidia nvidia-modeset nvidia-drm nvidia-uvm)
  [ -z "${SHA[nvidia-peermem]:-}" ] || MODS+=(nvidia-peermem)
  for m in "${MODS[@]}"; do [ -n "${SHA[$m]:-}" ] || die "$f has no line for $m.ko"; done
}

# Every module in <dir> matches its pin, the kernel and the driver version.
verify_ko() {
  local m f s vm v
  for m in "${MODS[@]}"; do
    f=$1/$m.ko; [ -f "$f" ] || die "missing $f"
    s=$(sha256sum "$f" | cut -d' ' -f1); [ "$s" = "${SHA[$m]}" ] || die "$f sha256 $s is not the pinned ${SHA[$m]}"
    vm=$(modinfo -F vermagic "$f" | cut -d' ' -f1); v=$(modinfo -F version "$f")
    [ "$vm" = "$KVER" ] && [ "$v" = "$VER" ] || die "$f: vermagic $vm version $v, want $KVER $VER"
    echo "$f sha256 ok, version $v, vermagic $vm"
  done
}

holders() {
  local fd t p
  for fd in /proc/[0-9]*/fd/*; do
    t=$(readlink "$fd" 2>/dev/null)
    case $t in /dev/nvidia*|/dev/dri/*) p=${fd#/proc/}; p=${p%%/*}; echo "$p $(cat "/proc/$p/comm" 2>/dev/null) $t" ;; esac
  done | sort -u
}
events() {
  local k; k=$(dmesg 2>/dev/null)
  echo "Xid $(grep -c 'NVRM: Xid' <<<"$k") AER $(grep -cE 'AER: (Corrected|Uncorrected|Multiple)' <<<"$k") DMAR $(grep -cE 'DMAR: \[DMA' <<<"$k") RmInitAdapter $(grep -c RmInitAdapter <<<"$k")"
}

# Runs DRAIN_CMD, then waits up to 10 s for the GPUs to have no holders. Refuses (nothing unloaded) otherwise.
drain() {
  local h i
  [ -z "$DRAIN_CMD" ] || run sh -c "$DRAIN_CMD"
  for i in 1 2 3; do h=$(holders); [ -z "$h" ] || [ "$DRY" = 1 ] && break; [ "$i" = 3 ] || sleep 5; done
  [ -z "$h" ] && { echo "holders: none"; return 0; }
  echo "holders:"; echo "$h"
  [ "$DRY" = 1 ] && { echo "(dry run: --yes refuses while these hold the GPUs)"; return 0; }
  die "GPUs still held; nothing unloaded"
}
restore_services() { [ -z "$RESTORE_CMD" ] || run sh -c "$RESTORE_CMD"; }

# Pause udev (so no rule reloads a module mid-swap) and detach the console; undone by unpause, or by the trap.
pause() {
  trap unpause EXIT
  run udevadm control --stop-exec-queue || die "cannot pause udev"
  [ -z "$VTCON" ] || { echo "+ echo 0 > $VTCON"; [ "$DRY" = 1 ] || echo 0 >"$VTCON"; }
}
unpause() {
  trap - EXIT
  run udevadm control --start-exec-queue; run udevadm settle -t 30
  [ -z "$VTCON" ] || { echo "+ echo 1 > $VTCON"; [ "$DRY" = 1 ] || echo 1 >"$VTCON"; }
}
unload_stack() {
  local m
  for m in nvidia_peermem nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
    loaded "$m" || continue
    run rmmod "$m" || return 1
  done
}

# "<module> <file>" for each module as modules.dep resolves it.
resolution() {
  local m f
  for m in "${MODS[@]}"; do
    f=$(awk -F: -v m="/$m.ko" '{ n = length($1) - length(m) + 1 } n > 0 && substr($1, n) == m { print $1; exit }' "$KDIR/modules.dep")
    echo "$m ${f:-MISSING}"
  done
}

# The per-device option modprobe reads passes card_ok for every card; $1 = static checks RMForceStaticBar1=0 only.
per_device_configured() {
  local s g ok=0
  s=$(modprobe -c 2>/dev/null | awk '$1 == "options" && $2 == "nvidia"' | grep -o 'NVreg_RegistryDwordsPerDevice=[^ ]*' | tail -1)
  for g in $GPUS; do card_ok "$s" "$g" "${1:-}" || ok=1; done
  return $ok
}
