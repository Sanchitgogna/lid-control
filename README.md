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

- **Stay on when the lid is closed:** keep music, downloads or a server running with the lid shut, even on battery. The menu bar icon turns into a ☕ while it's on.
- **⌥⌘L keyboard shortcut:** flip the lid setting from any app, with an on-screen confirmation.
- **Power buttons:** Sleep, Screen off, Restart and Shut Down.
- **Schedule:** turn the Mac on and shut it down at set times on chosen days.
- **No password prompts (optional):** enter your password once and lid and schedule changes apply instantly.

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
| Stay on with lid closed | `pmset -a disablesleep 1` (and `0` to turn it off) |
| Schedule | `pmset repeat wakeorpoweron … shutdown …` |
| Sleep / Screen off | `pmset sleepnow` / `pmset displaysleepnow` |
| Restart / Shut Down | asks System Events, so apps can save your work first |

**"Don't ask for my password"** adds a single rule at `/etc/sudoers.d/lidcontrol` that lets *your* account run only those exact `pmset` commands without a password. Nothing else gets elevated rights. Turning the switch off deletes the rule.

> ⚠️ With "Stay on" enabled your Mac keeps running in a bag. Turn it off before you pack the Mac away, or it may get hot.

## Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/Sanchitgogna/lid-control.git
cd lid-control
bash install.command
```

`install.command` builds the app, copies it to `/Applications`, and can add it to your login items. `bash build.sh` only builds `Lid Control.app` and `Lid Control.dmg` in the project folder.

## Uninstall

1. In the panel, turn **off** "Stay on when lid is closed" and "Don't ask for my password".
2. Quit Lid Control and drag it from Applications to the Bin.

## Releasing a new version (maintainers)

1. Bump `CFBundleShortVersionString` in `Info.plist` and push to `main`.
2. On GitHub, open **Actions → Build → Run workflow**, enter the version (e.g. `1.3.0`) and click **Run workflow**.
   Pushing a tag such as `v1.3.0` works too.

GitHub Actions builds a universal app on macOS and publishes a release with `LidControl.dmg` attached. The download link above always points at the newest release.

## License

[MIT](LICENSE)
