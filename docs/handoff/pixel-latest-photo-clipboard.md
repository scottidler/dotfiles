# Handoff: Pixel latest photo to clipboard

Branch: main

Written 2026-11-15 from a session on ripr. Nothing in this task has been built or configured yet. This is a fresh task, split out of the tab-switcher session so a separate agent can do it.

## Next action

1. Walk Scott through pairing his Pixel with Syncthing on ripr (steps 1-3 under "Plan"). One step per message: he does the phone side.
2. When a photo taken on the phone lands in `~/Pictures/pixel-camera/`, write `HOME/bin/latest-photo` in this repo (step 4).

## Goal (Scott's words)

> what about a button that could pull through a recent photo taken on my android pixel? would that be possible?

The use: take a photo on the Pixel, press one key on ripr, paste the photo into Google Messages web (Firefox), the Snapchat Chrome web app, or Claude.

## State on ripr (observed 2026-11-15)

| Fact | Command that proves it |
|---|---|
| Syncthing runs, config at `~/.local/state/syncthing/config.xml` | `ls ~/.local/state/syncthing/config.xml` |
| Syncthing devices: ripr, mini, ltl-7007, desk. No phone. | `grep -oE '<device [^>]*name="[^"]*"' ~/.local/state/syncthing/config.xml` |
| `~/Pictures` already syncs to the other machines | `grep -o 'path="[^"]*Pictures[^"]*"' ~/.local/state/syncthing/config.xml` |
| GSConnect and KDE Connect are not installed | `gnome-extensions list \| grep -iE 'gsconnect\|kdeconnect'; which kdeconnect-cli` (both empty) |
| `wl-copy` is installed (GNOME Wayland session) | `which wl-copy` |

Note: `desk` is retired (now `talos`). Do not add the phone folder to it.

## Plan

1. **Phone:** install Syncthing-Fork (the official Syncthing Android app was discontinued). Add ripr as a device.
2. **ripr:** accept the Pixel device. Accept the phone's `DCIM/Camera` folder as **receive-only**, path `~/Pictures/pixel-camera`.
   - Receive-only so ripr never edits or deletes phone photos.
   - Decide with Scott whether this folder should also reach mini and lappy. Because `~/Pictures` already syncs, a subfolder inside it may get pulled into that share. Check for nested-folder conflicts before accepting. If it would nest, pick a path outside `~/Pictures` (for example `~/Phone/camera`) and say why.
3. **Phone:** set the run conditions (Wi-Fi only, and so on) with Scott. The tradeoff: how fresh the photo is vs. battery use.
4. **Script `HOME/bin/latest-photo`** in this repo (`~/bin` links into `HOME/bin/` here, see `ls -l ~/bin/gpu-power`):
   - Find the newest image by mtime in the camera folder. Skip Syncthing temp files (`.syncthing.*.tmp`).
   - Copy it to the clipboard: `wl-copy --type <mime> < file`, with the MIME type from `file --mime-type -b`.
   - Show `notify-send` with the photo's time taken, so a stale photo is obvious before pasting.
   - `--path`: copy the file path instead (for upload dialogs).
   - If the folder is empty or missing, exit non-zero with a clear message. Fail loudly.
5. **Pad key:** a GNOME custom keybinding to `latest-photo` (Shift variant to `latest-photo --path`). The KB16 key choice is Scott's. GNOME must bind the keysym the key emits (F14 → `XF86Launch5`, and so on), not "F14". See the planner artifact below.

## Rejected

- **Google Photos API:** since 2025 the Library API only lets an app read items the app itself uploaded. Not rechecked on 2026-11-15; check if anyone reopens it.
- **KDE Connect / GSConnect:** the phone has to push each photo by hand, which defeats a one-key pull.
- **A tab-switcher subcommand:** this is not a tab-switcher job. It stays a separate script.

## Not verified

- Pixel photo format. Ultra HDR JPEG may paste differently in some apps. Test pasting into Google Messages web, Snapchat and Claude.
- Syncthing delay from shutter to file on ripr.

## Read first

1. This file.
2. `~/repos/scottidler/tab-switcher/docs/plan/2026-11-15-tab-switcher.md`: context only, the sibling work. Do not change it.
3. KB16 planner: https://claude.ai/artifact/GNCmuBXVmRtDMM1cgSDcfY (keysym mapping for pad keys).

## Suggested skills

- `dotfiles` if any config file needs moving under manifest.
- `rust-cli-coder` only if Scott wants this as Rust instead of a shell script. Default is a small script.

## Session-scoped

- Nothing. No background jobs, no cached credentials.
