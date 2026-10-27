# Installing BrightBar

BrightBar is built from source. There is no prebuilt download.

## Requirements

- macOS 14 or later (developed on macOS 26, Apple Silicon).
- Xcode Command Line Tools with Swift 5.9 or later: `xcode-select --install`.
- Optional: full Xcode, selected with `xcode-select`. Its `actool` compiles the Liquid Glass app icon. Without Xcode the build uses the prebuilt `Resources/AppIcon.icns`, so the icon shows in Finder and the Applications folder either way.
- Apple Silicon for external monitor control over DDC/CI. On Intel Macs the built-in display, the sub-zero range and the gamma fallback still work.

## Install

```bash
git clone https://github.com/bubagump02/brightbar.git
cd brightbar
./scripts/install.sh
```

The script builds a release binary, wraps it in `build/BrightBar.app`, signs it, copies it to `/Applications/BrightBar.app` and launches it. A sun icon appears in the menu bar, about 300 pt from the right edge. ⌘-drag it to move it.

The first build takes about a minute. Linker warnings about missing `CommandLineTools/Developer` search paths are harmless.

### If `/Applications` is not writable

Build only, then copy the app where you want it:

```bash
./scripts/make-app.sh
cp -R build/BrightBar.app ~/Applications/
open ~/Applications/BrightBar.app
```

The "open at login" option is registered automatically only from `/Applications`. From another folder, tick the checkbox in the settings window instead.

## First launch

1. **Accessibility.** macOS asks once. It is needed for the brightness keys (F1/F2, ⌃F1/⌃F2). Grant it in System Settings → Privacy & Security → Accessibility → BrightBar. Without it, the keys stay with macOS and the panel shows an "Autoriser…" button.
2. **Open at login.** On the first launch from `/Applications` the app registers itself as a login item. Toggle it with the "Ouvrir à l'ouverture de session" checkbox in the settings window (⚙︎ button in the panel), or in System Settings → General → Login Items.
3. **Replace the macOS modules (optional).** To let BrightBar take the place of Control Center's Display and Keyboard Brightness modules, set both to *Don't Show in Menu Bar* in System Settings → Control Center.

## Keep the Accessibility permission across rebuilds

Without a stable signing identity the script signs ad hoc, and macOS forgets the Accessibility permission after every rebuild. To avoid it, create a self-signed code-signing certificate named **BrightBar Local** in your login keychain. `make-app.sh` uses it automatically when it exists. The recipe is in the README, section "Brightness keys".

## Update

```bash
cd brightbar
git pull
./scripts/install.sh
```

## CLI only

```bash
swift build -c release --product brightness
.build/release/brightness info
```

See the README for the list of commands.

## Uninstall

1. Quit BrightBar from the settings window (⚙︎), or press ⌘Q while the panel is open.
2. Delete `/Applications/BrightBar.app` (or the copy you made).
3. Remove BrightBar from System Settings → Privacy & Security → Accessibility, and from General → Login Items.
4. Optional, to delete the saved settings: `defaults delete local.brightbar`.

Quitting BrightBar restores gamma and removes the XDR overlay, and the app makes no other system change.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `swift: command not found` | Install the Command Line Tools: `xcode-select --install`. |
| `no actool` note during the build | Harmless. The build falls back to `Resources/AppIcon.icns`. Select full Xcode with `xcode-select -s` to get the Liquid Glass icon on macOS 26. |
| App icon is blank in the Applications folder | Run `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/BrightBar.app`, then relaunch Finder (`killall Finder`). |
| Brightness keys do nothing | Grant Accessibility (see First launch). After a rebuild with ad hoc signing, remove BrightBar from the list and add it again. |
| External monitor slider shows a `logiciel` badge | The monitor does not answer over DDC, so BrightBar dims in software. A USB-C → DisplayPort cable usually gets DDC working. |
| XDR checkbox is greyed out | The screen has no EDR headroom. XDR needs a MacBook Pro with a mini-LED display. |
| Panel warns about "Automatically adjust brightness" | Turn it off in System Settings → Displays, it fights the auto mode. |
