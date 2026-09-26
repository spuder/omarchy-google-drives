# Changelog

All notable changes to this plugin. Versions match `manifest.json`.

## 0.2.0 — 2026-09-26

### Added
- **No separate install step.** `omarchy plugin add … --enable` is now the
  whole install. `omarchy plugin add` has no post-install hook, so the first
  "Add a Google Drive account" runs `install.sh` in its terminal before
  sign-in whenever rclone, fuse3, or the systemd template is missing. It asks
  for your sudo password once, for pacman. (#10)
- **"Finish setup" row in the panel**, shown while setup is incomplete. It
  runs the same install without adding an account, e.g. after rclone was
  removed. Click it, press Enter on it, or press `i`. (#9, #11)
- **Per-account logs and reconnect.** `googledrive-accountctl logs <id>` and
  `reauth <id>`, also in the panel as `L` (logs) and `c` (reconnect).
- `CHANGELOG.md`.

### Fixed
- Every terminal the panel opened failed with "`/logo.txt`: No such file or
  directory". `OMARCHY_PATH` is now set for them. (#8)
- `rclone about` output is bounded, and the whole process group is killed
  when it's cut off.

### Changed
- `install.sh` rejects unknown arguments instead of silently doing a full
  run.
- Terminal commands launched from the panel are shell-quoted word by word,
  so a home directory with spaces or quotes no longer breaks them.
- Opening a second setup terminal within 60 seconds of the first is
  ignored, so the second doesn't fail on pacman's database lock.
- The panel's cursor starts on "Finish setup" while it's showing, and
  moves off it reliably when setup completes.
- `SECURITY.md` added (vulnerability contact and self-review process). It
  now lists both panel actions that can run `install.sh`.

## 0.1.1 — 2026-09-13

### Fixed
- Marketplace security review findings
  ([omarchy-plugin-marketplace#6454](https://github.com/omacom/omarchy-plugin-marketplace/issues/6454)):
  closed-environment install boundary (`env -i` re-exec), hardened
  detached launches, incremental output capping, and environment isolation.
- Three gaps found by the build-omarchy-plugins skills.

## 0.1.0 — 2026-09-11

- First release: multi-account Google Drive mounts via `rclone mount` with a
  bounded VFS cache, one systemd user unit per account, and a bar widget
  showing status, storage, pause/resume, open folder, and remove.
