#!/bin/bash
# Unload the nvidia modules that are loaded (any build) and load a target stack. Never changes /lib/modules or /etc:
# a boot install (p2p-install.sh, updates/p2p) stays in place; p2p-fallback.sh removes it.
#   default          the stock driver: modprobe if modprobe resolves to it, otherwise (boot install present) insmod by
#                    path from the stock module directory with the per-device RMForceStaticBar1=0 string
#   --to-installed   whatever modprobe resolves, which must be the boot install in updates/p2p (with its config)
# Usage: p2p-rollback.sh --dry-run | --yes [--to-installed]
set -u
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
parse_args "--to-installed" "$@"

echo "== preflight (read-only)"
preflight_common
resolved=$(modinfo -k "$KVER" -F filename nvidia 2>/dev/null)
sdir=$(stock_dir)
[ -n "$sdir" ] || die "no stock nvidia module for $KVER outside $SUBDIR"
BY_PATH=0
if has_flag --to-installed; then
  case $resolved in */$SUBDIR/nvidia.ko*) ;; *) die "--to-installed: modprobe resolves '$resolved', not a boot install in $SUBDIR" ;; esac
  target=$resolved
  echo "target: the boot install $target, loaded by modprobe with its config"
else
  target=$(ko_in "$sdir" nvidia)
  if [ "$resolved" = "$target" ]; then echo "target: stock $target, by modprobe"
  else
    BY_PATH=1
    for m in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do
      f=$(ko_in "$sdir" "$m"); [ -n "$f" ] && [ "$(modinfo -F version "$f")" = "$VER" ] || die "stock $sdir/$m.ko missing or not $VER"
    done
    echo "target: stock $target, by path; modprobe resolves $resolved (a boot install, which stays in place)"
  fi
fi
target_srcv=$(modinfo -F srcversion "$target")
per_device_configured static || die "restore the RMForceStaticBar1=0 option before loading a driver"
if loaded nvidia && [ "$(srcv)" = "$target_srcv" ]; then echo "target already loaded"; restore_services; exit 0; fi
echo "events before: $(events)"

echo "== drain"
drain

echo "== swap"
pause
unload_stack || { lsmod | grep '^nvidia'; unpause; die "rmmod failed; left as is, a reboot loads $resolved"; }
if [ $BY_PATH = 1 ]; then
  DEPS=$(for m in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do modinfo -F depends "$(ko_in "$sdir" "$m")"; done | tr ',' '\n' | grep -v '^nvidia' | sort -u)
  # shellcheck disable=SC2086  # DEPS is a list of module names
  [ -z "$DEPS" ] || run modprobe -a $DEPS
  mapfile -t opts < <(nvidia_opts | grep -v '^NVreg_EnableResizableBar=')   # per-device string + EXTRA_NVIDIA_OPTS
  run insmod "$(ko_in "$sdir" nvidia)" "${opts[@]}" || { unpause; die "insmod of the stock nvidia failed; a reboot loads $resolved"; }
  for m in nvidia-modeset nvidia-drm nvidia-uvm; do run insmod "$(ko_in "$sdir" "$m")"; done
else
  run modprobe -v nvidia || { unpause; die "modprobe nvidia failed; a reboot loads $resolved"; }
  run modprobe -a nvidia_drm nvidia_uvm
fi
unpause
[ "$DRY" = 1 ] && { echo "(dry run: nothing changed; end of plan)"; exit 0; }
[ "$(srcv)" = "$target_srcv" ] || die "loaded nvidia (srcversion $(srcv)) is not $target"
p=$(grep -E '^RegistryDwordsPerDevice:' /proc/driver/nvidia/params)
for g in $GPUS; do card_ok "$p" "$g" static >/dev/null || die "RMForceStaticBar1=0 for $g not in /proc/driver/nvidia/params"; done
head -1 /proc/driver/nvidia/version
echo "events after: $(events)"
restore_services
