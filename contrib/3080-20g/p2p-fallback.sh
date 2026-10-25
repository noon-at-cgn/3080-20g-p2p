#!/bin/bash
# Undo p2p-install.sh: the next load of nvidia for $KVER uses the stock modules again.
# Moves /etc/depmod.d/p2p.conf, /etc/modprobe.d/zz-nvidia-p2p.conf and $KVER's updates/p2p into
# /var/backups/p2p-modules/<time>-fallback/ (nothing is deleted) and runs depmod. The per-card RMForceStaticBar1=0
# option stays. Without --live nothing is unloaded: reboot to finish. --live also swaps the running driver at once
# (p2p-rollback.sh).
# Usage: p2p-fallback.sh --dry-run | --yes [--live]
set -u
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
parse_args "--live" "$@"
BK=$BACKUP_BASE/$(date +%Y%m%d-%H%M%S)-fallback
MODS=(nvidia nvidia-modeset nvidia-drm nvidia-uvm)

echo "== preflight (read-only)"
preflight_common
stock=$(stock_dir)
[ -n "$stock" ] || die "no stock nvidia module for $KVER outside $SUBDIR; reinstall the stock driver first"
echo "stock: $stock"
per_device_configured static || die "restore the RMForceStaticBar1=0 option first (stock would load without it)"
echo "modules.dep resolves:"; resolution | sed 's/^/  /'

echo "== move the install aside to $BK"
run mkdir -p "$BK/lib/modules/$KVER"
for p in "$DEPMOD_CONF" "$P2P_CONF"; do
  if [ -e "$p" ]; then run mkdir -p "$BK$(dirname "$p")"; run mv "$p" "$BK$p"; else echo "($p absent)"; fi
done
if [ -e "$DEST" ]; then run mv "$DEST" "$BK/lib/modules/$KVER/"; else echo "($DEST absent)"; fi
run cp -a "$KDIR"/modules.* "$BK/lib/modules/$KVER/"
[ "$DRY" = 1 ] || cat >"$BK/RESTORE.txt" <<EOF
# Moved aside by p2p-fallback.sh. To put the install back (or run p2p-install.sh --yes again):
[ -d '$BK/lib/modules/$KVER/p2p' ] && cp -a '$BK/lib/modules/$KVER/p2p' '$KDIR/updates/'
[ -e '$BK$DEPMOD_CONF' ] && cp -a '$BK$DEPMOD_CONF' '$DEPMOD_CONF'
[ -e '$BK$P2P_CONF' ] && cp -a '$BK$P2P_CONF' '$P2P_CONF'
depmod -a '$KVER'
EOF
run depmod -a "$KVER" || die "depmod failed (backup $BK)"

echo "== verify"
if [ "$DRY" = 0 ]; then
  ok=1
  while read -r m f; do
    case $f in MISSING|"$SUBDIR/"*|*"/$SUBDIR/"*) echo "  $m -> $f (WANT stock)"; ok=0 ;; *) echo "  $m -> $f" ;; esac
  done < <(resolution)
  modprobe -c | grep -qE '^options nvidia(_uvm)? .*(uvm_disable_hmm|NVreg_EnableResizableBar)' &&
    { echo "  zz-nvidia-p2p.conf options still configured"; ok=0; }
  [ $ok = 1 ] || die "verification failed (backup $BK)"
  echo "STOCK at the next load of nvidia for $KVER. Backup: $BK"
fi
has_flag --live || { echo "The running driver is unchanged. Reboot, or swap the running driver: $0 --yes --live"; exit 0; }

echo "== live swap"
if [ "$DRY" = 1 ]; then echo "+ exec $HERE/p2p-rollback.sh --yes"; exit 0; fi
exec "$HERE/p2p-rollback.sh" --yes
