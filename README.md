# thinkpad-acpi-fix

Fixes for older ThinkPads, IBM and early Lenovo models, whose firmware has
its own volume control (the "console audio" of the Linux `thinkpad_acpi`
driver). On these laptops, under Linux:

- the **volume buttons** (up, down, mute) change only the firmware's volume;
  the desktop never sees them, so there is no on-screen volume and the
  panel's volume does not follow;
- the **firmware volume** can stay muted or low, which silences the speakers
  whatever the desktop's volume says, and also the **ThinkPad's own beeps**
  (charger plugged in, low battery).

`thinkpad-acpi-fix.sh` makes the volume buttons reach the desktop and keeps the
firmware volume at full, muted only while the sound is muted. It works in
every desktop session (LXDE, Xfce, MATE and others) and changes nothing on
computers that do not need it.

> [!WARNING]
> **Use at your own risk.** The script changes kernel module options and
> udev rules as root. It is provided "as is", without warranty of any kind
> (see [LICENSE](LICENSE)). The authors accept no responsibility for a broken
> system, lost data, security issues or any other damage.

## Quick start

Requirements: a ThinkPad with `thinkpad_acpi`'s console audio
(`/proc/acpi/ibm/volume` exists); Debian or another distribution with apt,
udev and systemd; a normal user account with sudo rights.

```bash
git clone https://github.com/b1ack0p/thinkpad-acpi-fix.git
cd thinkpad-acpi-fix
bash thinkpad-acpi-fix.sh
```

Restart the computer when asked: `thinkpad_acpi` reads its options only
when it starts.

| Command                              | Does                                        |
|--------------------------------------|---------------------------------------------|
| `bash thinkpad-acpi-fix.sh`              | Install the fixes (safe to run again)       |
| `bash thinkpad-acpi-fix.sh --status`     | Show the model, firmware volume and masks   |
| `bash thinkpad-acpi-fix.sh --uninstall`  | Remove everything it installed              |
| `bash thinkpad-acpi-fix.sh --no-keys`    | Install without the volume-button part      |
| `bash thinkpad-acpi-fix.sh --no-reboot`  | Do not offer to restart at the end          |

## Which ThinkPads

The script has no list of models: it asks the `thinkpad_acpi` driver what the
laptop has, and applies only what fits.

| The driver reports                                   | Fix                                       | Typical models |
|------------------------------------------------------|-------------------------------------------|----------------|
| Console audio (`/proc/acpi/ibm/volume`)              | Firmware volume at full, muted with the sound | IBM T2x to T4x, X2x to X4x, R3x to R5x; Lenovo T60/X60/R60, T61/X61/R61 |
| Volume buttons it can report but leaves out         | Buttons read from NVRAM and reported      | The same era |
| Neither                                              | Nothing; "Nothing to do"                  | X200, T400 and later |

If one press of a volume button changes the volume twice, the buttons were
already reaching the desktop on that model: run
`bash thinkpad-acpi-fix.sh --no-keys`.

**Tested on:** IBM ThinkPad X40 (2371) on its X4 UltraBase, Debian 10:
volume buttons, sound, the firmware's beeps and mute following the sound.
Other models are detected from what the driver reports, but are untested;
reports are welcome.

### BIOS beeps

The firmware's beeps also depend on the BIOS (F1 at power-on, **Config →
Beep and Alarm** or **Alarm**). For example, with **Volume beep** disabled
the volume buttons stay silent, and with **Power control beep** enabled the
ThinkPad beeps when the charger is plugged in or out. The fixes only make
sure that the firmware volume does not silence the beeps the BIOS enables.

## How it works

| File | Purpose |
|------|---------|
| `/etc/modprobe.d/thinkpad-acpi-fix.conf` | `options thinkpad_acpi volume_control=1`: the firmware volume becomes a mixer control (`ThinkPadEC`, `Console`) |
| `/etc/udev/rules.d/90-thinkpad-acpi-fix.rules` | Runs `hotkeys on` when `thinkpad_acpi` starts |
| `/usr/local/lib/thinkpad-acpi-fix/hotkeys` | Adds the volume buttons that the driver can report but leaves out to `hotkey_mask`, and to `hotkey_source_mask`, so that they are read from NVRAM |
| `/usr/local/lib/thinkpad-acpi-fix/console-audio` | In each session: keeps the firmware volume at 100%, muted only while the sound server's default output is muted, and puts it back whenever a button or the desktop changes it. It ends with the login session |
| `/etc/xdg/autostart/thinkpad-acpi-fix.desktop` | Starts `console-audio` in every desktop session |

It also installs `alsa-utils` (for `amixer`) when it is missing. The volume
buttons then arrive as ordinary volume keys (`XF86AudioRaiseVolume`,
`XF86AudioLowerVolume`, `XF86AudioMute`), which the desktop's volume control
handles.

`--uninstall` removes every file above and the volume buttons control the
firmware volume alone again after a restart; the firmware volume keeps its
current level.

## Licence

MIT; see [LICENSE](LICENSE).
