#!/usr/bin/env bash
# =============================================================================
# Title       : thinkpad-acpi-fix.sh
# Description : Fixes for older ThinkPads (IBM and early Lenovo models, such
#               as the X40, T40 to T61, X60 and R50 to R61) whose firmware
#               has its own volume, the "console audio" of thinkpad_acpi:
#               - the volume buttons reach the desktop (volume plugin, OSD)
#               - the firmware volume stays at full and is muted only with
#                 the sound, so that the speakers and the ThinkPad's own beeps
#                 (charger, low battery) are no longer silenced by it
#               It works in every desktop session.
#               Other computers are left as they are.
#
# Usage       : bash thinkpad-acpi-fix.sh              install the fixes
#               bash thinkpad-acpi-fix.sh --status     show the ThinkPad's state
#               bash thinkpad-acpi-fix.sh --uninstall  remove the fixes
#               bash thinkpad-acpi-fix.sh --help       show this text
#               Safe to run again.
#
# Options     :     --no-keys        leave the volume buttons to the firmware
#                                    (if each press changes the volume twice)
#                   --no-reboot      do not offer to restart the computer
#
# Installs    : /etc/modprobe.d/thinkpad-acpi-fix.conf   volume_control=1
#               /etc/udev/rules.d/90-thinkpad-acpi-fix.rules
#               /etc/xdg/autostart/thinkpad-acpi-fix.desktop
#               /usr/local/lib/thinkpad-acpi-fix/        hotkeys, console-audio
#               and alsa-utils (amixer), if missing.
#
# Requires    : a ThinkPad with thinkpad_acpi's console audio
#               (/proc/acpi/ibm/volume); Debian or another distribution with
#               apt, udev and systemd; a normal user with sudo rights.
#
# Disclaimer  : Use at your own risk. This script changes kernel module
#               options and udev rules as root. It is provided "as is",
#               without warranty of any kind (see LICENSE). The authors accept
#               no responsibility for a broken system, lost data, security
#               issues or any other damage.
# =============================================================================

set -Eeuo pipefail
umask 022

readonly APP_NAME="thinkpad-acpi-fix"
readonly APP_VERSION="0.1.0"
readonly LIB="/usr/local/lib/$APP_NAME"
readonly MODPROBE="/etc/modprobe.d/$APP_NAME.conf"
readonly UDEV_RULE="/etc/udev/rules.d/90-$APP_NAME.rules"
readonly AUTOSTART="/etc/xdg/autostart/$APP_NAME.desktop"
readonly TP="/sys/devices/platform/thinkpad_acpi"
readonly EC_VOLUME="/proc/acpi/ibm/volume"

O_MODE=install O_KEYS=1 O_NO_REBOOT=0

C_Y="" C_R="" C_G="" C_C="" C_B="" C_0=""
if [[ -t 2 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
	C_B=$'\e[1m' C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_C=$'\e[1;96m' C_0=$'\e[0m'
fi
log()  { printf '%s\n' "$*" >&2; }
info() { printf '%s::%s %s\n' "$C_C" "$C_0" "$*" >&2; }
ok()   { printf '%s✔%s %s\n' "$C_G" "$C_0" "$*" >&2; }
warn() { printf '%s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s✘ error:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

# Ask a yes/no question on the terminal; without one, the default is taken.
# Usage: ask QUESTION y|n
ask() {
	local ans hint="[y/N]"
	[[ $2 == y ]] && hint="[Y/n]"
	{ : </dev/tty; } 2>/dev/null || { [[ $2 == y ]]; return; }
	read -r -p "$(printf '%s?%s %s %s ' "$C_C" "$C_0" "$1" "$hint")" ans </dev/tty || ans=""
	ans=${ans,,}; [[ -n $ans ]] || ans=$2
	[[ $ans == y || $ans == yes ]]
}

usage() { sed -n '/^# Usage/,/^# ====/{/^# ====/q;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }

# Write stdin to a root-owned file.
put() { sudo install -D -m "${2:-0644}" /dev/stdin "$1"; }

# Print the ThinkPad's model, as thinkpad_acpi or DMI names it.
model() {
	local v n
	v=$(cat /sys/class/dmi/id/product_version 2>/dev/null || true)
	n=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
	if [[ $v == *ThinkPad* ]]; then echo "$v ($n)"; else echo "${n:-unknown}"; fi
}

# Succeed if this is a ThinkPad that needs the fixes.
needs_fixes() { [[ -d $TP && -e $EC_VOLUME ]]; }

status() {
	local m
	log "${C_B}  $APP_NAME $APP_VERSION${C_0} — fixes for older ThinkPads"
	log "  Model          $(model)"
	if [[ ! -d $TP ]]; then log "  thinkpad_acpi  not loaded: not a ThinkPad, or the driver is missing"; return 0; fi
	log "  BIOS           $(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo ?)"
	if [[ -e $EC_VOLUME ]]; then
		log "  Console audio  $(awk -F':[ \t]*' '$1 == "level" { l = $2 } $1 == "mute" { m = $2 } END { printf "level %s of 14, mute %s", l, m }' "$EC_VOLUME")"
		log "                 volume_control=$(cat /sys/module/thinkpad_acpi/parameters/volume_control 2>/dev/null || echo ?)"
	else
		log "  Console audio  none: this ThinkPad does not need these fixes"
	fi
	log "  Hotkey mask    $(cat "$TP/hotkey_mask" 2>/dev/null || echo ?) (recommended $(cat "$TP/hotkey_recommended_mask" 2>/dev/null || echo ?))"
	log "  Polled keys    $(cat "$TP/hotkey_source_mask" 2>/dev/null || echo ?)"
	for m in "$MODPROBE" "$UDEV_RULE" "$AUTOSTART" "$LIB/hotkeys" "$LIB/console-audio"; do
		if [[ -e $m ]]; then log "  Installed      $m"; fi
	done
	if pgrep -f "$LIB/console-audio watch" >/dev/null 2>&1; then log "  Watcher        running"; fi
}

# The hotkeys helper, run as root by udev when thinkpad_acpi starts: the
# volume buttons, which the firmware of these models reports to no one, are
# read from the NVRAM (hotkey_source_mask) and reported like the other keys.
# Only the buttons that the driver can report but leaves out are added, so
# that a model whose buttons already reach the desktop is not changed.
write_hotkeys() {
	put "$LIB/hotkeys" 0755 <<'EOF'
#!/bin/sh
# Written by thinkpad-acpi-fix.sh. Usage: hotkeys [on|off]
d=/sys/devices/platform/thinkpad_acpi
vol=$((0x00700000))
[ -w "$d/hotkey_source_mask" ] && [ -w "$d/hotkey_mask" ] && [ -r "$d/hotkey_recommended_mask" ] || exit 0
all=$(($(cat "$d/hotkey_all_mask"))) rec=$(($(cat "$d/hotkey_recommended_mask")))
src=$(($(cat "$d/hotkey_source_mask"))) mask=$(($(cat "$d/hotkey_mask")))
want=$((all & vol & ~rec))
[ "$want" -ne 0 ] || exit 0
if [ "${1:-on}" = off ]; then
	printf '0x%08x\n' $((src & ~want)) >"$d/hotkey_source_mask"
	printf '0x%08x\n' $((mask & ~want)) >"$d/hotkey_mask"
else
	printf '0x%08x\n' $((src | want)) >"$d/hotkey_source_mask"
	printf '0x%08x\n' $((mask | want)) >"$d/hotkey_mask"
fi
EOF
	put "$UDEV_RULE" <<EOF
# Written by thinkpad-acpi-fix.sh: the volume buttons of this older ThinkPad
# reported to the desktop. Remove with: bash thinkpad-acpi-fix.sh --uninstall
ACTION=="add", SUBSYSTEM=="platform", KERNEL=="thinkpad_acpi", RUN+="$LIB/hotkeys on"
EOF
}

# The console-audio helper, run in each desktop session: the firmware volume
# at full, and muted only while the sound is muted. The firmware still changes
# its volume when a button is pressed; the helper puts it back whenever the
# sound server's volume or mute changes, or the firmware volume does. It ends
# with the login session.
write_console_audio() {
	put "$LIB/console-audio" 0755 <<'EOF'
#!/bin/sh
# Written by thinkpad-acpi-fix.sh. Usage: console-audio [set|watch]
command -v amixer >/dev/null || exit 0
amixer -c ThinkPadEC sget Console >/dev/null 2>&1 || exit 0
set_ec() {
	m=unmute
	if command -v pactl >/dev/null; then
		case $(pactl list sinks 2>/dev/null | awk -v d="$(pactl info 2>/dev/null | sed -n 's/^Default Sink: //p')" \
			'/^\tName: / { s = ($2 == d) } s && /^\tMute: / { print $2; exit }') in yes) m=mute ;; esac
	fi
	amixer -q -c ThinkPadEC sset Console 100% "$m" 2>/dev/null
}
set_ec
[ "${1:-}" = watch ] || exit 0
# One watcher per user; it leads its own process group, so that ending it
# ends its pactl and amixer as well
for g in $(pgrep -u "$(id -u)" -f "^/bin/sh $0 watch\$"); do
	[ "$g" = $$ ] || kill -TERM "-$g" 2>/dev/null
done
sid=${XDG_SESSION_ID:-}
if [ -n "$sid" ] && command -v loginctl >/dev/null; then
	(
		while sleep 10; do
			case $(loginctl show-session "$sid" -p State --value 2>/dev/null) in
				active|online) ;;
				*) kill -TERM -$$ 2>/dev/null; exit 0 ;;
			esac
		done
	) &
fi
# The firmware volume changed by a button
(amixer -c ThinkPadEC events 2>/dev/null | while read -r l; do
	case $l in *Console*) set_ec ;; esac
done) &
# The sound changed in the volume plugin or elsewhere; retried while the sound
# server starts at login
n=0
while command -v pactl >/dev/null && [ $n -lt 12 ]; do
	t=$(date +%s)
	pactl subscribe 2>/dev/null | while read -r l; do
		case $l in *" on sink #"*|*" on server"*) set_ec ;; esac
	done
	[ $(($(date +%s) - t)) -lt 30 ] || n=0
	n=$((n + 1)); sleep 5
done
# Without a sound server, only the firmware's own changes are followed
command -v pactl >/dev/null && kill -TERM -$$ 2>/dev/null
wait
EOF
	put "$AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=ThinkPad console audio
Comment=Keeps the ThinkPad's firmware volume at full, muted with the sound
Exec=setsid $LIB/console-audio watch
NoDisplay=true
X-GNOME-Autostart-Phase=Applications
EOF
}

install_mode() {
	local -a pkgs=()
	needs_fixes || {
		status
		log ""
		ok "Nothing to do: this computer has no ThinkPad console audio (only older ThinkPads need these fixes)."
		exit 0
	}
	status
	log ""
	warn "${C_B}Use at your own risk.${C_0} This changes kernel module options and udev rules as root;"
	log "  it is provided \"as is\", without warranty of any kind (see LICENSE)."
	log ""
	log "  Installs:"
	log "    - thinkpad_acpi volume_control=1: the firmware volume as a mixer control"
	(( O_KEYS )) && log "    - the volume buttons reported to the desktop (NVRAM polling)"
	log "    - a helper in every desktop session: firmware volume at full, muted with the sound"
	command -v amixer >/dev/null || pkgs+=(alsa-utils)
	(( ${#pkgs[@]} == 0 )) || log "    - packages: ${pkgs[*]}"
	ask "Proceed" y || die "aborted"
	sudo -v || die "sudo rights are needed"
	if (( ${#pkgs[@]} )); then sudo apt-get install -y --no-install-recommends "${pkgs[@]}"; fi
	put "$MODPROBE" <<EOF
# Written by thinkpad-acpi-fix.sh: the firmware volume of this ThinkPad as a mixer
# control, which the session keeps at full. Remove with: bash thinkpad-acpi-fix.sh --uninstall
options thinkpad_acpi volume_control=1
EOF
	if (( O_KEYS )); then
		write_hotkeys
		sudo udevadm control --reload 2>/dev/null || true
		sudo "$LIB/hotkeys" on
	else
		[[ ! -x $LIB/hotkeys ]] || sudo "$LIB/hotkeys" off
		sudo rm -f -- "$UDEV_RULE" "$LIB/hotkeys"
	fi
	write_console_audio
	ok "Installed"
	# volume_control is read when thinkpad_acpi loads, which is at boot: it is
	# in use by the sound and radio drivers while the computer runs
	if [[ $(cat /sys/module/thinkpad_acpi/parameters/volume_control 2>/dev/null) == Y ]]; then
		"$LIB/console-audio" set || true
		setsid "$LIB/console-audio" watch >/dev/null 2>&1 </dev/null &
		ok "Active now"
		return 0
	fi
	warn "A restart is needed to finish: thinkpad_acpi reads volume_control when it starts."
	(( O_NO_REBOOT )) && return 0
	if ask "Restart the computer now" n; then sudo systemctl reboot; fi
	info "Restart the computer when you are ready."
}

uninstall_mode() {
	local f any=0
	for f in "$MODPROBE" "$UDEV_RULE" "$AUTOSTART" "$LIB"; do [[ -e $f ]] && any=1; done
	(( any )) || { ok "Not installed; nothing to remove."; return 0; }
	log "  Removes the ThinkPad fixes: $MODPROBE, $UDEV_RULE, $AUTOSTART, $LIB"
	ask "Continue" n || die "aborted"
	sudo -v || die "sudo rights are needed"
	[[ ! -x $LIB/hotkeys ]] || sudo "$LIB/hotkeys" off || true
	pkill -f "$LIB/console-audio watch" 2>/dev/null || true
	sudo rm -rf -- "$MODPROBE" "$UDEV_RULE" "$AUTOSTART" "$LIB"
	sudo udevadm control --reload 2>/dev/null || true
	ok "Removed. The firmware volume keeps its current level; the volume buttons control it alone again after a restart."
}

main() {
	while (( $# )); do
		case $1 in
			--status)    O_MODE=status ;;
			--uninstall) O_MODE=uninstall ;;
			--no-keys)   O_KEYS=0 ;;
			--no-reboot) O_NO_REBOOT=1 ;;
			-h|--help)   usage; exit 0 ;;
			-V|--version) echo "$APP_NAME $APP_VERSION"; exit 0 ;;
			*) die "unknown argument '$1'; see: bash $0 --help" ;;
		esac
		shift
	done
	(( EUID != 0 )) || die "do not run this as root: run it as your normal user, which needs sudo rights"
	case $O_MODE in
		status)    status ;;
		uninstall) uninstall_mode ;;
		*)         install_mode ;;
	esac
}

main "$@"
