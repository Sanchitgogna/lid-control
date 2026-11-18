<p align="center">
  <img src="docs/icon.png" width="128" alt="Lid Control icon">
</p>

<h1 align="center">Lid Control</h1>

<p align="center">
  A tiny macOS menu bar app to keep your Mac running with the lid closed,<br>
  sleep / restart / shut down in one click, and schedule power on and off.
</p>

<p align="center">
  <a href="https://github.com/Sanchitgogna/lid-control/releases/latest/download/LidControl.dmg"><b>⬇ Download Lid Control</b></a>
  &nbsp;·&nbsp; macOS 13 Ventura or later · Apple Silicon and Intel
</p>

---

## Features

- **Keep Mac awake:** one big switch. While it's on, your Mac won't sleep or lock, with the lid open or closed, even on battery. The menu bar icon turns into a ☕.
- **⌥⌘L shortcut:** switch it from any app, with an on-screen confirmation.
- **Battery safety:** turns Keep awake off and sleeps the Mac if the battery runs low (10–30%, you choose) or the Mac gets hot.
- **Quit reminder:** warns you if you quit while Keep awake is on, and reminds you on launch if it was left on.
- **Schedule:** wake or turn the Mac on and shut it down at set times on chosen days.
- **Skip password prompts (optional):** approve once and the switch works instantly.
- **Start at login** and **update alerts** when a new version is released here.

## Install

1. [Download `LidControl.dmg`](https://github.com/Sanchitgogna/lid-control/releases/latest/download/LidControl.dmg) and open it.
2. Drag **Lid Control** onto the **Applications** folder.
3. Open Lid Control from Applications. A laptop icon appears in your menu bar.

### "Apple could not verify Lid Control…"

Lid Control isn't signed with a paid Apple Developer certificate, so macOS warns you the first time. To open it anyway:

1. Click **Done** on the warning.
2. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to Lid Control.
3. Confirm with your password.

Or run this once in Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Lid Control.app"
```

## How it works

Lid Control is a thin front end for macOS's own `pmset` power tool:

| Feature | What it runs |
| --- | --- |
| Keep awake | `pmset -a disablesleep 1` (and `0` to turn it off) |
| Schedule | `pmset repeat wakeorpoweron … shutdown …` |
| Keep screen on | an IOKit display-sleep assertion, held only while Keep awake is on |

**"Skip password prompts"** adds a single rule at `/etc/sudoers.d/lidcontrol` that lets *your* account run only those exact `pmset` commands without a password. Nothing else gets elevated rights. Turning the switch off deletes the rule.

> ⚠️ With Keep awake on, your Mac keeps running in a bag. Turn it off before you pack the Mac away, or rely on Battery safety.

## Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/Sanchitgogna/lid-control.git
cd lid-control
bash install.command
```

`install.command` builds the app, copies it to `/Applications` and opens it. `bash build.sh` only builds `Lid Control.app` and `Lid Control.dmg` in the project folder.

## Uninstall

1. In the panel, turn **off** Keep awake, and in Settings turn off "Skip password prompts" and "Start at login".
2. Quit Lid Control and drag it from Applications to the Bin.

## Releasing a new version (maintainers)

1. Bump `CFBundleShortVersionString` in `Info.plist` and push to `main`.
2. On GitHub, open **Actions → Build → Run workflow**, enter the version (e.g. `1.3.0`) and click **Run workflow**.
   Pushing a tag such as `v1.3.0` works too.

GitHub Actions builds a universal app on macOS and publishes a release with `LidControl.dmg` attached. The download link above always points at the newest release.

## License

[MIT](LICENSE)
