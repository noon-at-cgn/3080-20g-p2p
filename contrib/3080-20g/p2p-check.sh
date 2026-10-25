#!/bin/bash
# Read-only check after a boot (or after p2p-load.sh): which build is loaded, its options, BAR1, P2P and the kernel
# log. Loads nothing, writes nothing, creates no CUDA context. Exit status = number of FAIL lines.
# Usage: p2p-check.sh
set -u
export LC_ALL=C
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
FAILS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
want() { local p=$1 f=$2; shift 2; if "$@"; then pass "$p"; else fail "$f"; fi; }
[ "$(id -u)" = 0 ] || die "must run as root"
[ -n "$GPUS" ] || die "set GPUS in $HERE/config.sh"

echo "== modules (kernel $(uname -r))"
if [ -r "$DEST/SHA256SUMS" ]; then src=$DEST; elif [ -n "$OUT" ]; then src=$OUT; else die "not installed in $DEST and OUT is not set"; fi
load_pins "$src"
for m in "${MODS[@]}"; do
  f=$src/$m.ko
  [ "$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)" = "${SHA[$m]}" ] || fail "$f does not match SHA256SUMS"
  [ "$m" = nvidia-peermem ] && continue
  l=$(cat "/sys/module/${m//-/_}/srcversion" 2>/dev/null)
  want "$m loaded from the patched build ($src)" "$m loaded: '${l:-not loaded}', not the srcversion of $f" \
    [ "$l" = "$(modinfo -F srcversion "$f")" ]
done
[ "$src" = "$DEST" ] && echo "modprobe resolves nvidia to $(modinfo -k "$KVER" -F filename nvidia)"
head -1 /proc/driver/nvidia/version

echo "== driver parameters"
P=/proc/driver/nvidia/params
grep -E '^(RegistryDwords|RegistryDwordsPerDevice|EnableResizableBar):' "$P"
pd=$(grep -E '^RegistryDwordsPerDevice:' "$P")
for g in $GPUS; do
  if e=$(card_ok "$pd" "$g"); then pass "per-device entry for $g (P2P_ENABLE='$P2P_ENABLE')"; else fail "$e"; fi
done
# shellcheck disable=SC2329  # called through want
no_global_key() { ! grep -q '^RegistryDwords:.*RMDynBar1P2PEnable' "$P"; }
want "no global RMDynBar1P2PEnable" "RegistryDwords sets RMDynBar1P2PEnable globally; use the per-device line" no_global_key
want "EnableResizableBar: 0" "EnableResizableBar is not 0" grep -qx 'EnableResizableBar: 0' "$P"
for c in "nvidia nv_dynbar1_calib 0" "nvidia nv_dynbar1_delta 0" "nvidia nv_hugetlb_pin_fast_path 0" \
         "nvidia_uvm uvm_disable_hmm Y" "nvidia_uvm uvm_bar1_gate_trips 0"; do
  read -r mod p exp <<<"$c"; v=$(param "$mod" "$p")
  want "$mod.$p=$v" "$mod.$p='$v' (want $exp)" [ "$v" = "$exp" ]
done
echo "counters: nvidia.nv_dynbar1_rm_p2p_refused=$(param nvidia nv_dynbar1_rm_p2p_refused)" \
  "nvidia_uvm.uvm_bar1_gate_pairs=$(param nvidia_uvm uvm_bar1_gate_pairs)"

echo "== GPUs"
for g in $GPUS; do
  drv=$(basename "$(readlink "/sys/bus/pci/devices/$g/driver" 2>/dev/null)" 2>/dev/null)
  bt=$(nvidia-smi -i "$g" -q -d MEMORY 2>/dev/null | awk '/BAR1 Memory Usage/ { s = 1; next } s && /Total/ { print $3; exit }')
  echo "$g driver ${drv:-none}, BAR1 Total ${bt:-?} MiB, lspci $(lspci -vv -s "$g" 2>/dev/null | grep -m1 -o 'Region 1:.*' | grep -o 'size=[0-9A-Z]*')"
  want "$g bound to nvidia" "$g bound to '${drv:-none}'" [ "$drv" = nvidia ]
  want "$g BAR1 32768 MiB" "$g BAR1 Total '${bt:-?}' MiB (want 32768)" [ "$bt" = 32768 ]
done

echo "== P2P (nvidia-smi topo)"
# Topology matrix rows only; the header row also starts with GPU0. Both are called through want.
# shellcheck disable=SC2016,SC2329
all_ok() { awk '$1 ~ /^GPU[0-9]+$/ && $2 !~ /^GPU/ { n++; for (i = 2; i <= NF; i++) if ($i != "X" && $i != "OK") bad = 1 } END { exit !(n > 1 && !bad) }'; }
# shellcheck disable=SC2016,SC2329
none_ok() { ! awk '$1 ~ /^GPU[0-9]+$/ && $2 !~ /^GPU/ { for (i = 2; i <= NF; i++) if ($i == "OK") ok = 1 } END { exit !ok }'; }
for k in r w; do
  t=$(nvidia-smi topo -p2p "$k" 2>&1); printf '%s\n' "$t"
  if [ "$P2P_ENABLE" = 0 ]; then
    want "topo -p2p $k: off, as P2P_ENABLE=0 asks" "topo -p2p $k shows OK although P2P_ENABLE=0" none_ok <<<"$t"
  else
    want "topo -p2p $k: OK between every pair" "topo -p2p $k is not OK between every pair" all_ok <<<"$t"
  fi
done

echo "== kernel log this boot"
k=$(dmesg 2>/dev/null)
for pair in "Xid|NVRM:.*Xid" "AER|AER:.*(Corrected|Uncorrected|Fatal)" "DMAR|DMAR: \[DMA|DMAR:.*fault" "init failures|RmInitAdapter"; do
  n=$(grep -cE "${pair#*|}" <<<"$k")
  if [ "$n" = 0 ]; then pass "${pair%%|*} lines: 0"; else fail "${pair%%|*} lines: $n"; grep -E "${pair#*|}" <<<"$k" | tail -3; fi
done
echo "unixCallVideoBIOS 'vesa call failed' lines: $(grep -c 'vesa call failed' <<<"$k") (benign, logged at nvidia_drm unload)"

if [ "$FAILS" = 0 ]; then echo "ALL PASS"; else echo "$FAILS FAIL line(s). Back to stock: $HERE/p2p-fallback.sh --yes --live"; fi
exit "$FAILS"
