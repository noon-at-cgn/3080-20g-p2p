#!/bin/bash
# Load the patched build in $OUT by insmod, with the options from config.sh. Starts from the stock driver or from this
# build (installed or not), so it also switches a running build between P2P on and off. Nothing is installed and no
# config file is written: a reboot loads what modprobe resolves; p2p-rollback.sh --yes loads stock without a reboot.
# Usage: p2p-load.sh --dry-run | --yes
set -u
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
parse_args "" "$@"

echo "== preflight (read-only)"
preflight_common
[ -n "$OUT" ] || die "set OUT in $HERE/config.sh"
[ "$(uname -r)" = "$KVER" ] || die "running kernel $(uname -r), the build is for $KVER"
load_pins "$OUT"
verify_ko "$OUT"
loaded nvidia || die "nvidia is not loaded; this script swaps from a running driver"
sdir=$(stock_dir); stock_srcv=; [ -z "$sdir" ] || stock_srcv=$(modinfo -F srcversion "$(ko_in "$sdir" nvidia)")
case "$(srcv)" in
  "$stock_srcv") echo "start: the stock driver ($sdir)" ;;
  "$(modinfo -F srcversion "$OUT/nvidia.ko")") echo "start: this build; modprobe resolves $(modinfo -k "$KVER" -F filename nvidia)" ;;
  *) die "loaded nvidia (srcversion $(srcv)) is neither the stock driver nor the build in $OUT" ;;
esac
mapfile -t NV_OPTS < <(nvidia_opts)
DEPS=$(for m in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do modinfo -F depends "$OUT/$m.ko"; done | tr ',' '\n' | grep -v '^nvidia' | sort -u)
echo "events before: $(events)"

echo "== drain"
drain

echo "== swap"
pause
if ! unload_stack; then
  echo "rmmod failed; reloading what modprobe resolves"; lsmod | grep '^nvidia'
  run modprobe -a nvidia_drm nvidia_uvm; unpause; exit 1
fi
# shellcheck disable=SC2086  # DEPS is a list of module names
[ -z "$DEPS" ] || run modprobe -a $DEPS
ok=1
run insmod "$OUT/nvidia.ko" "${NV_OPTS[@]}" || ok=0
[ $ok = 1 ] && { run insmod "$OUT/nvidia-modeset.ko" || ok=0; }
[ $ok = 1 ] && { run insmod "$OUT/nvidia-drm.ko" || ok=0; }
[ $ok = 1 ] && { run insmod "$OUT/nvidia-uvm.ko" "${UVM_OPTS[@]}" || ok=0; }
if [ $ok = 1 ] && [ "$DRY" = 0 ]; then
  chk() { if [ "$2" = "$3" ]; then echo "check $1: $2"; else echo "CHECK FAILED $1: '$2' (want '$3')"; ok=0; fi; }
  chk EnableResizableBar "$(grep -E '^EnableResizableBar:' /proc/driver/nvidia/params)" "EnableResizableBar: 0"
  chk nv_dynbar1_calib "$(param nvidia nv_dynbar1_calib)" 0
  chk nv_dynbar1_delta "$(param nvidia nv_dynbar1_delta)" 0
  chk uvm_disable_hmm "$(param nvidia_uvm uvm_disable_hmm)" Y
  chk uvm_bar1_gate_trips "$(param nvidia_uvm uvm_bar1_gate_trips)" 0
  for m in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do
    chk "$m srcversion" "$(cat "/sys/module/$m/srcversion" 2>/dev/null)" "$(modinfo -F srcversion "$OUT/${m//_/-}.ko")"
  done
  p=$(grep -E '^RegistryDwordsPerDevice:' /proc/driver/nvidia/params)
  for g in $GPUS; do
    e=$(card_ok "$p" "$g") || { echo "CHECK FAILED $e"; ok=0; }
    chk "$g driver" "$(basename "$(readlink "/sys/bus/pci/devices/$g/driver")")" nvidia
  done
fi
if [ $ok = 0 ]; then
  echo "LOAD OR CHECK FAILED; dmesg tail:"; dmesg | tail -30
  [ "$DRY" = 1 ] && exit 1
  trap - EXIT; exec "$HERE/p2p-rollback.sh" --yes
fi
unpause

echo "== state"
[ "$DRY" = 1 ] && { echo "(dry run: nothing changed; end of plan)"; exit 0; }
head -1 /proc/driver/nvidia/version
grep -E '^(RegistryDwords|RegistryDwordsPerDevice|EnableResizableBar):' /proc/driver/nvidia/params
for g in $GPUS; do
  echo "$g $(nvidia-smi -q -d MEMORY -i "$g" | grep -A2 -E 'FB Memory Usage|BAR1 Memory Usage' | grep -E 'Total|Used' | tr -s ' ' | tr '\n' ' ')"
done
nvidia-smi topo -p2p r; nvidia-smi topo -p2p w
echo "events after: $(events)"
restore_services
echo "Back to stock: $HERE/p2p-rollback.sh --yes"
