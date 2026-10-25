#!/bin/bash
# Install the patched build for one kernel ($KVER) so that every later load, including the boot, uses it.
# - Refuses unless every .ko in $OUT matches the SHA256SUMS of your build, the kernel and version 615.71.09.
# - Keeps the stock modules where they are: /etc/depmod.d/p2p.conf overrides the five module names for $KVER only,
#   so another kernel still loads its own stock modules, and p2p-fallback.sh returns to stock in one command.
# - Writes /etc/modprobe.d/zz-nvidia-p2p.conf with the options below; the per-card RMForceStaticBar1=0 line from
#   3080-20gb-rebar stays where it is and must already be in place.
# - Backs up what it replaces into /var/backups/p2p-modules/<time>/ (RESTORE.txt). Loads and unloads nothing.
# Usage: p2p-install.sh --dry-run | --yes
set -u
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
parse_args "" "$@"
BK=$BACKUP_BASE/$(date +%Y%m%d-%H%M%S)

echo "== preflight (read-only)"
preflight_common
[ -n "$OUT" ] || die "set OUT in $HERE/config.sh"
[ -d "$KDIR/kernel" ] || die "kernel $KVER is not installed"
load_pins "$OUT"
verify_ko "$OUT"
stock=$(stock_dir)
[ -n "$stock" ] || die "no stock nvidia module for $KVER outside $SUBDIR: there would be no fallback"
echo "stock fallback: $stock"
per_device_configured || die "fix the per-device line in modprobe.d (3080-20gb-rebar's zz-nvidia-static-bar1.conf) first"
other=$(find /etc/modprobe.d /run/modprobe.d /usr/local/lib/modprobe.d /usr/lib/modprobe.d /lib/modprobe.d -maxdepth 1 \
          -name '*.conf' ! -path "$P2P_CONF" 2>/dev/null | sort -u |
        xargs -r grep -HnE 'NVreg_RegistryDwords=|NVreg_EnableResizableBar|uvm_disable_hmm|^[[:space:]]*(install|remove)[[:space:]]+nvidia')
[ -z "$other" ] || die "other modprobe.d lines set the options this install owns, or hook nvidia:
$other"
for d in /lib/modules/*/"$SUBDIR"; do
  [ -e "$d" ] && [ "$d" != "$DEST" ] && die "$d exists for another kernel; run p2p-fallback.sh for that kernel first"
done
if [ -e "$DEPMOD_CONF" ] && grep -E '^[[:space:]]*override' "$DEPMOD_CONF" | grep -vqE "[[:space:]]${KVER}[[:space:]]"; then
  die "$DEPMOD_CONF has override lines for another kernel; run p2p-fallback.sh for that kernel first"
fi
if command -v lsinitramfs >/dev/null; then initrd=$(lsinitramfs "/boot/initrd.img-$KVER" 2>/dev/null)
elif command -v lsinitrd >/dev/null; then initrd=$(lsinitrd "/boot/initramfs-$KVER.img" 2>/dev/null)
else initrd=; echo "note: no lsinitramfs or lsinitrd; check yourself that the initramfs holds no nvidia module"; fi
! grep -qE '(^|/)nvidia(-drm|-modeset|-uvm|-peermem)?\.ko' <<<"$initrd" ||
  die "the initramfs carries an nvidia module; the driver must load from the root file system, after the BAR1 resize"
echo "modules.dep resolves:"; resolution | sed 's/^/  /'

echo "== backup to $BK"
run mkdir -p "$BK/lib/modules/$KVER"
for p in "$DEPMOD_CONF" "$P2P_CONF"; do [ -e "$p" ] && run install -D -m 0644 "$p" "$BK$p"; done
[ -e "$DEST" ] && run cp -a "$DEST" "$BK/lib/modules/$KVER/"
run cp -a "$KDIR"/modules.* "$BK/lib/modules/$KVER/"
[ "$DRY" = 1 ] || cat >"$BK/RESTORE.txt" <<EOF
# State before p2p-install.sh. To put it back (or run p2p-fallback.sh --yes for stock):
rm -rf '$DEST' '$DEPMOD_CONF' '$P2P_CONF'
[ -d '$BK/lib/modules/$KVER/p2p' ] && cp -a '$BK/lib/modules/$KVER/p2p' '$KDIR/updates/'
[ -e '$BK$DEPMOD_CONF' ] && cp -a '$BK$DEPMOD_CONF' '$DEPMOD_CONF'
[ -e '$BK$P2P_CONF' ] && cp -a '$BK$P2P_CONF' '$P2P_CONF'
depmod -a '$KVER'
EOF

echo "== install"
[ -e "$DEST" ] && run rm -rf "$DEST"
for m in "${MODS[@]}"; do run install -D -m 0644 "$OUT/$m.ko" "$DEST/$m.ko"; done
run install -m 0644 "$OUT/SHA256SUMS" "$DEST/SHA256SUMS"
[ "$DRY" = 1 ] || verify_ko "$DEST" >/dev/null
depmod_text="# Written by p2p-install.sh. Kernel $KVER only: load the patched NVIDIA modules from $SUBDIR.
# Names must be the file names (with dashes). Remove with p2p-fallback.sh --yes."
for m in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem; do
  [ -f "$OUT/$m.ko" ] && depmod_text+=$'\n'"override $m $KVER $SUBDIR"
done
p2p_text="# Written by p2p-install.sh. The per-device line (RMForceStaticBar1=0, and RMDynBar1P2PEnable=0 to turn P2P off)
# stays in its own file; no global NVreg_RegistryDwords. Remove with p2p-fallback.sh --yes.
options nvidia NVreg_EnableResizableBar=0
options nvidia_uvm ${UVM_OPTS[*]}"
for pair in "$DEPMOD_CONF|$depmod_text" "$P2P_CONF|$p2p_text"; do
  p=${pair%%|*}; t=${pair#*|}
  echo "+ write $p:"; printf '%s\n' "$t" | sed 's/^/    /'
  [ "$DRY" = 1 ] || { mkdir -p "$(dirname "$p")" && printf '%s\n' "$t" >"$p"; } || die "cannot write $p"
done
run depmod -a "$KVER" || die "depmod failed; restore: sh $BK/RESTORE.txt"

echo "== verify"
[ "$DRY" = 1 ] && { echo "(dry run: nothing changed; end of plan)"; exit 0; }
ok=1
while read -r m f; do
  case $f in "$SUBDIR/$m.ko"|*"/$SUBDIR/$m.ko") echo "  $m -> $f" ;; *) echo "  $m -> $f (WANT $SUBDIR)"; ok=0 ;; esac
done < <(resolution)
deps=$(modprobe -S "$KVER" --show-depends -a nvidia-drm nvidia-uvm 2>&1)
nv=$(grep -m1 -E '^insmod .*/nvidia\.ko' <<<"$deps"); uvm=$(grep -m1 -E '^insmod .*/nvidia-uvm\.ko' <<<"$deps")
printf '  %s\n  %s\n' "$nv" "$uvm"
[[ $nv == *"/$SUBDIR/nvidia.ko"*" NVreg_EnableResizableBar=0"* ]] || { echo "  WANT nvidia.ko from $SUBDIR with NVreg_EnableResizableBar=0"; ok=0; }
[[ $uvm == *"/$SUBDIR/nvidia-uvm.ko"*" uvm_disable_hmm=1"* ]] || { echo "  WANT nvidia-uvm.ko from $SUBDIR with uvm_disable_hmm=1"; ok=0; }
[[ $nv != *"NVreg_RegistryDwords="* ]] || { echo "  UNEXPECTED global NVreg_RegistryDwords"; ok=0; }
per_device_configured || ok=0
[ $ok = 1 ] || die "verification failed; restore: sh $BK/RESTORE.txt (or p2p-fallback.sh --yes)"
echo "INSTALLED for $KVER; the running driver is unchanged. Reboot, then run $HERE/p2p-check.sh"
echo "Back to stock: $HERE/p2p-fallback.sh --yes   (add --live to swap the running driver too)"
