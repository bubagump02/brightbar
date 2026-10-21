# BrightBar

A menu bar app and CLI that read and set the MacBook built-in display brightness the same way Lunar does.
They call the private DisplayServices API first and fall back to CoreDisplay.
See [LUNAR_BRIGHTNESS_RE.md](LUNAR_BRIGHTNESS_RE.md) for the reverse-engineering notes.

## Layout

| Path | What |
|---|---|
| `Sources/BrightnessKit` | Library: private API bindings, `BuiltinControl`, `BrightnessObserver`, `Appearance` / `NightShift` / `TrueTone` |
| `Sources/BrightBar` | SwiftUI `MenuBarExtra` app |
| `Sources/brightness` | CLI |
| `scripts/make-app.sh` | Builds `build/BrightBar.app`, signed with "BrightBar Local", menu bar only |
| `scripts/install.sh` | Builds, installs `/Applications/BrightBar.app` and relaunches it from there |

## Build and run

Install, or update after a code change:

```bash
./scripts/install.sh
```

The script quits the running copy, replaces `/Applications/BrightBar.app` and relaunches it.

**Open at login.** The app registers itself as a login item through `SMAppService.mainApp`. This happens automatically on the first launch from `/Applications`. The "Ouvrir à l'ouverture de session" checkbox in the panel turns it on or off, and it also shows up in System Settings → General → Login Items.

The login item points at the installed copy, so it is greyed out when the app runs from `build/`.

CLI only:

```bash
swift build -c release --product brightness
```

## App

A sun icon sits in the menu bar. Click it to open the panel. The panel replaces the Display module of Control Center:

- **Header**: the display name. Click it to open Displays settings.
- **Slider**: sets the brightness immediately while you drag.
- **Dark Mode / Night Shift / True Tone**: round toggles, as in Control Center. Their state follows changes made elsewhere: System Settings, the Night Shift schedule, Control Center.
- **Displays settings…**: opens System Settings → Displays.
- The footer shows which brightness API is in use.

The icon starts about 300 pt from the right edge, so it doesn't land behind the notch. ⌘-drag it to move it.

### Below the minimum (sub-zero) and above 100 % (XDR)

The built-in slider covers an extended range, as Lunar does (paid features there, reimplemented here):

| Range | What happens |
|---|---|
| −100 … 0 (**Sous zéro**) | Native backlight at its **lowest lit value**. On this panel an exact 0 switches the backlight off (linear brightness 0.0000, while 0.00001 still gives 0.0048), so BrightBar never sends less than 0.001. The picture is darkened through the gamma table. The curve is exponential in **perceived luminance**, from 100 % down to 0.1 % of the native minimum: −25 → 18 %, −50 → 3.2 %, −75 → 0.56 %, −100 → 0.1 %. It is converted back to a gamma factor with `^(1/2.2)`, because the table acts on the encoded signal. With the keys, this range has its own finer resolution: 32 steps (64 with ⌥⇧), about −19 % of light per step. |
| 0 … 100 | Native backlight only (DisplayServices). |
| 100 … 200 (**XDR**) | Native backlight at 100, plus a click-through full-screen window whose Metal layer (`rgba16Float`, `extendedLinearSRGB`, `wantsExtendedDynamicRangeContent`, `compositingFilter = multiplyBlendMode`) shows a color > 1.0. macOS raises the backlight to render that EDR content, and the multiply brightens everything. Measured headroom on a 14" M1 Pro: **3.2×**, i.e. 1600 / 500 nits. |

- **Bottom of the range = black**: at the minimum (0 without sub-zero, −100 with it), the native value is sent as an exact 0, which switches the backlight off, as on macOS. Every level above it stays lit.
- **Toggles**: the "Sous zéro" (on by default) and "XDR" (off by default) checkboxes under the slider. XDR is greyed out if the screen has no EDR headroom.
- **No system change.** Unlike Lunar's "Full Range" method (`SLSDisplaySetPresetData`), no display preset is modified. Quitting BrightBar restores gamma and removes the overlay.
- **XDR costs**: more battery and more heat. macOS may limit the gain when the Mac is hot.
- **Sub-zero and Night Shift / True Tone**: no conflict on Apple Silicon, since those don't go through the gamma table. f.lux, which uses gamma, would conflict.
- **Auto modes**: they drive the native backlight and leave the sub-zero/XDR range. A manual change into sub-zero or XDR pauses them, as usual.

### Auto mode

The **Manual / Schedule / Sensor** picker sits under the slider. A status line shows the target. The ⚙︎ button opens the settings window.

| Mode | Behaviour |
|---|---|
| Schedule | Linear interpolation between time points, checked every 30 s. Default: 06:30 → 35 %, 08:00 → 70 %, 10:00 → 90 %, 17:00 → 90 %, 20:00 → 60 %, 22:30 → 35 %, flat through the night. Points are edited in the window, with a 24 h preview chart. |
| Sensor | Built-in ambient light sensor, read every second and smoothed. The curve runs on log10(lux): 0 lux → 15 %, 10 → 30 %, 100 → 55 %, 500 → 80 %, ≥ 2000 → 100 %. A "darker / brighter" slider shifts it by ±30. Small variations (< 3 %) are ignored. |

- **Manual change** (slider, F1/F2, Control Center): pauses the auto mode until the next schedule point, or for 30 minutes in sensor mode. "Resume" restarts it immediately.
- **External monitors**: they follow if "Follow the MacBook brightness" is on. When the lid is closed, the auto mode drives them directly.
- **macOS "Automatically adjust brightness"**: if it is on, the panel shows a warning, because it would fight the auto mode. Detection uses `DisplayServicesAmbientLightCompensationEnabled(id, &bool)`; the result comes back through the out-parameter, as Lunar calls it.
- **Light sensor**: read like Lunar does, through `IOHIDEventSystemClient` (usage 0xff00/4), the ambient-light event (type 12), and `IOHIDEventGetFloatValue` on field `12 << 16`.

### External monitors (DDC/CI)

The **External displays** section only appears when a monitor is connected. Each monitor gets its own slider.

- **"Follow the MacBook brightness (F1/F2)"**: copies the built-in brightness to every monitor. Use it when the brightness keys should drive the external monitors too. The setting is saved.
- **Software fallback (`logiciel` badge)**: used when the monitor doesn't answer over DDC.
  The picture is darkened through the gamma table (`CGSetDisplayTransferByTable`), as Lunar's "Software" control does.
  - The backlight doesn't change, so this only darkens. For more light, set the monitor to its maximum in its OSD menu.
  - 0 % applies a 10 % floor so the screen never goes fully black.
  - The level is saved per monitor (vendor:model:serial).
  - It is reapplied after a reconfiguration or a wake, because macOS resets gamma tables then.
  - macOS restores the original gamma when BrightBar quits.
- **Apple Silicon only.** Intel Macs use a different I²C path that isn't implemented.

**Observed:** Dell P2219H on the built-in HDMI port of a 14" M1 Pro MacBook Pro (internal DP→HDMI converter).
DDC reads return only null messages (`6E 80 BE`), and writes are acknowledged but ignored.
The gamma fallback takes over.
A USB-C → DisplayPort cable usually gets DDC working.

| Step | Detail (same as Lunar) |
|---|---|
| Port | `DCPAVServiceProxy` with `Location = External` → `IOAVServiceCreateWithService` |
| Monitor matching | EDID (`IOAVServiceCopyEDID`) vendor/product/serial vs `CGDisplayVendorNumber`/`ModelNumber`/`SerialNumber`; with a single monitor and an unreadable EDID, the leftover port is used |
| Read | write `[0x82, 0x01, vcp, chk]` to chip 0x37 / address 0x51, wait 40 ms, read 12 bytes |
| Write | `[0x84, 0x03, vcp, hi, lo, chk]`, sent twice 15 ms apart |
| Checksum | `0x6E ^ 0x51 ^` XOR of the bytes |

All I²C traffic for a monitor is serialized on its own queue. Slider writes are coalesced: only the latest value is sent.

Limit: two identical monitors with no EDID serial number may be swapped.

### Brightness keys

BrightBar intercepts F1/F2 before macOS does, as Lunar does with `MediaKeyTap`.
It uses a session event tap on `NSSystemDefined` events, subtype 8, with `NX_KEYTYPE_BRIGHTNESS_UP/DOWN` = 2/3.
The keys are swallowed, so the macOS indicator no longer shows. BrightBar applies the change and shows **its own indicator** at the top right for 1.5 s.

- **Step**: 1/16 in the native range (as on macOS), 1/32 in sub-zero. ⌥⇧ halves each step. The value snaps to that grid.
- **Target screen**: the one under the mouse pointer.
  - External monitor: DDC or gamma.
  - Otherwise the built-in, with the native animation.
- **Auto mode**: a key press counts as a manual change, so the auto mode pauses.
- **Permission**: needs **Accessibility** (System Settings → Privacy & Security → Accessibility → BrightBar).
  - macOS asks once at first launch.
  - Without the permission, the keys stay with macOS. The panel then shows an "Autoriser…" button.
  - `make-app.sh` signs with the local self-signed identity **"BrightBar Local"** (login keychain, code-signing usage). The designated requirement is then `identifier "local.brightbar" and certificate leaf = H"…"`, which is stable, so the permission survives rebuilds.
  - Without that identity, the script signs ad hoc. The requirement is then the cdhash, which changes with every build, so macOS forgets the permission each time.
  - To recreate the identity: generate a self-signed certificate with EKU `codeSigning`, export it as a legacy PKCS#12 (`-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1`, which OpenSSL ≥ 3 needs), then `security import … -T /usr/bin/codesign`.

BrightBar defines no shortcuts of its own: the earlier ⌃⌥ ones collided with Magnet.

### Hiding the macOS Display module

System Settings → Control Center → **Display** → *Don't Show in Menu Bar*.
BrightBar then takes its place.

| Toggle | Private API (same as Lunar, except True Tone) |
|---|---|
| Dark Mode | SkyLight `SLSGetAppearanceThemeLegacy` / `SLSSetAppearanceThemeLegacy`; change notification `AppleInterfaceThemeChangedNotification` |
| Night Shift | CoreBrightness `CBBlueLightClient` `getBlueLightStatus:` / `setEnabled:` / `setStatusNotificationBlock:` |
| True Tone | CoreBrightness `CBTrueToneClient` `supported` / `available` / `enabled` / `setEnabled:` |

## CLI

```
brightness [--method ds|cd] <command>
  get                     print brightness (0-100)
  set <0-100>             set immediately
  smooth <0-100> [secs]   animated transition: native without secs,
                          manual stepped loop over <secs> with it
  watch [--raw]           print external brightness changes until Ctrl-C
  info                    show display id, available APIs and probe results
  status                  Dark Mode, Night Shift, True Tone state
  dark|night|truetone on|off
  lux                     ambient light (lux) and the sensor mode's target
  schedule                schedule mode's target now, for the default points
  ddc list                external displays and their DDC brightness
  ddc set <n> <0-100>     set brightness of external display <n> (from list)
  gamma <n> <0-100> [secs]  software-dim external display <n>; macOS undoes
                          it when this process exits, so it holds for <secs>
                          (default: until Ctrl-C)
```

`--method` forces DisplayServices (`ds`) or CoreDisplay (`cd`).
If you leave it out, the tool picks the method as Lunar does.

## How it works

- Symbols are resolved at runtime with `dlopen`/`dlsym`. Nothing links against private frameworks.
- Method selection mirrors Lunar's `AppleNativeControl`:
  1. If `DisplayServicesCanChangeBrightness(id)` returns true, use DisplayServices.
  2. Otherwise run a write-probe: read the value, write it ±0.01, read it back, then restore it.
  3. If DisplayServices fails, run the same probe on CoreDisplay.
- `DisplayServicesSetBrightnessSmooth(id, target - current)` takes a delta.
  The system runs the animation in the background for about 0.2 to 0.5 s.
  `DisplayServicesGetBrightness` already returns the target during that time.
  A write issued before the animation ends is overwritten by it.
- Change notifications use `DisplayServicesRegisterForBrightnessChangeNotifications(id, observer, callback)`.
  Lunar passes the display id as the observer pointer, and so does this tool.
  The callback's `userInfo` is `{ value = <0.0…1.0> }`.
  A native smooth transition produces one notification, carrying the final value.

## Observed on macOS 26.6.2 (Apple Silicon, M1 Pro)

- DisplayServices works for get, set, smooth and notifications.
- `CoreDisplay_Display_SetUserBrightness` has no effect on the built-in panel.
- `CoreDisplay_Display_GetUserBrightness` always returns `1.0`.
- So the CoreDisplay probe fails, and `--method cd` exits with `no usable brightness API`.
