# Plan: native, multi-account, bidirectional Google Drive for Omarchy

## Status of this repo (read this first)

This is v0.1, built the same way as its sister project
([omarchy-protondrive](https://github.com/spuder/omarchy-protondrive)) was
at the same stage: the shell (manifest, Panel/Service/Model, bar icon), the
CLI (`googledrive-accountctl`, `googledrive-status`, `googledrive-bisync`),
the systemd templates, and the install/uninstall scripts are all written
and internally consistent — `Model.js`'s parsing/formatting logic has unit
tests, `googledrive-status --demo` has a JSON-shape smoke test — but this
has **not yet been installed into a live `omarchy-shell` and exercised
against a real Google account**. Treat the panel/QML layer as unverified
until that happens; see Roadmap.

## Why this shape

Google has no official Linux Drive **sync** client to wrap (contrast
Omarchy's first-party Dropbox plugin, which wraps the real `dropboxd`).
[Google Drive for desktop](https://support.google.com/a/answer/7491144) is
Windows/macOS only; there is no official Drive CLI with sync or mount
commands. So, like the Proton Drive plugin, this one has to own more:

1. **Sync/transport**: [rclone's `drive` backend](https://rclone.org/drive/)
   handles Google's OAuth and the actual API calls. Not reimplemented here.
2. **Reconciliation**: [`rclone bisync`](https://rclone.org/bisync/), run
   periodically by a systemd **timer** (not a long-running process — bisync
   is designed as a run-to-completion pass, invoked on a schedule, the same
   way its own docs suggest cron). This is the actual point of difference
   from every comparable plugin surveyed (see README's Comparison table):
   a genuine two-way sync of real local files, not an on-demand FUSE view.
3. **Shell surface**: one Quickshell `bar-widget` plugin, structurally
   identical to the Proton Drive plugin's Panel/Service/Model split, itself
   modeled on the first-party Dropbox plugin
   (`/usr/share/omarchy/shell/plugins/panels/dropbox/`).
4. **File-manager surface**: out of scope for v0.1, same as Proton Drive's
   v0.1 — see Roadmap.

## Why `bisync` instead of `mount` (the actual design decision)

The Proton Drive plugin deliberately chose `rclone mount` over `bisync`
for Proton, reasoning that bisync was still beta and that an on-demand VFS
cache gets closer to a Dropbox-Smart-Sync feel than a full duplicate local
copy. That reasoning doesn't carry over to this plugin, for two reasons:

- **The explicit ask was bidirectional sync**, not a virtual drive. A
  mount is a live network view — reads fetch on demand, writes go straight
  through — which is a different product than "a folder that stays in sync
  and still works with the network off." `bisync` is rclone's own answer
  to that second thing: it maintains two independent listings (local and
  remote) and reconciles changes, deletes, and renames on both sides, each
  run.
- **Every existing Google Drive Omarchy plugin already does the mount
  approach.** edbron's, JoshuaFurman's, and wesleycole's are all `rclone
  mount`. JoshuaFurman's own README names the gap directly: *"A true
  offline folder needs `rclone bisync` and a conflict-resolution story."*
  That's this plugin's actual reason to exist rather than duplicate one of
  the three.

The real cost of this choice, tracked honestly:

- **Conflict resolution is `--conflict-resolve=newer`**, not a picker UI.
  When the same file changed on both sides between runs, the newer
  modification time wins and the older version is saved as a `.conflict`
  copy next to it. That's a real, silent-ish tradeoff — a person could miss
  a `.conflict` file sitting next to something they meant to keep — chosen
  for v0.1 because a conflict-resolution panel is real UI work, not because
  the tradeoff is invisible. Tracked below.
- **Sync is periodic, not instant.** A timer running every 5 minutes
  (configurable per account via `systemctl --user edit`) means a change can
  take up to that long to reach another device, unlike a mount's
  effectively-live view. Bisync doesn't have a watch/inotify mode of its
  own; a `--poll-interval`-driven continuous loop is possible future work
  (see Roadmap) but adds a long-running process to supervise, which is
  exactly the daemon-complexity bisync-on-a-timer avoids today.
- **Local disk usage is real**, not cache-bounded. Each account's synced
  folder holds a full local copy of everything under it (minus anything
  excluded via rclone filter files, not yet wired up — see Roadmap),
  unlike a VFS-cache mount that only keeps recently-used files on disk.

## Multi-account design

Same reasoning and same shape as `omarchy-protondrive`'s, because the
underlying problem is identical — Google Drive for Linux has no
multi-account story of its own to inherit, any more than Proton Drive or
Dropbox do:

- Each account gets a **fully separate rclone config file**
  (`~/.config/omarchy-google-drive/<id>/rclone.conf`), not shared sections
  in one file. Removing an account is a directory removal; a revoked token
  for one account can't touch another.
- Each account gets its **own `rclone bisync` pass**, via the templated
  `omarchy-google-drive-bisync@<id>.timer` + `@<id>.service` unit pair,
  rather than multiplexing several accounts through one process. A stuck
  or slow sync for `work` doesn't block `personal`'s timer from firing.
- Each account gets its **own local folder**
  (`~/GoogleDrive/<Display Name>/`), so bookmarks and any future
  file-manager integration can key off path prefix alone.
- `googledrive-status`'s account objects and `accounts.json` are keyed by
  `id` throughout, same as the Proton Drive plugin's `(account_id, path)`
  convention.
- Signing in twice with two different Google accounts works because each
  `add` is its own independent `rclone config create ... config_is_local=true`
  browser round trip — Google's own account chooser, not something this
  plugin has to arbitrate.

## Roadmap

**Phase 1 — this repo.** Manifest + bar/panel plugin, account CLI, systemd
timer+service templates, install/uninstall scripts, unit + smoke tests.
Done.

**Phase 2 — prove it live.** Not yet done, the actual gap between this and
"finished":
- Install into a real `omarchy-shell` (`omarchy plugin add` +
  `install.sh`) and confirm the bar icon, panel, and account rows render
  and react.
- A real, successful `googledrive-accountctl add` against an actual Google
  account: confirm the OAuth browser hand-off completes, `rclone about`
  reports quota correctly, and the first `--resync` pass produces a
  correct baseline in both directions.
- Confirm a genuine two-way edit (change a file locally, change a
  *different* file in the Drive web UI, wait for the next timer tick) ends
  up correct on both sides, and that a deliberately-conflicting edit
  produces the expected `.conflict` file rather than data loss.
- Add `docs/bar.png` / `docs/panel.png` once there's a real render to
  capture (README references none yet, deliberately, for the same reason
  the Proton Drive plugin didn't add screenshots until Phase 2).

**Phase 3 — conflict visibility.**
- Surface `.conflict` files in the panel (count + "review" action) instead
  of leaving them to be found in Nautilus.
- Optional: a `--conflict-resolve` choice in the widget's settings schema,
  for people who'd rather stop-and-ask than newest-wins.

**Phase 4 — filters and shared drives.**
- Wire up rclone filter files (`--filters-file`) so large/irrelevant trees
  (e.g. a huge shared folder) can be excluded per account instead of
  syncing everything under My Drive.
- Google Shared Drives support (rclone's `drive` backend can address them
  via `team_drive`) as an opt-in per-account setting, not the default.

**Phase 5 — file manager.**
- Nautilus emblems for synced / pending / conflict / error, keyed by which
  synced folder a file lives under (falls out of the per-account-folder
  design almost for free, same as the Proton Drive plugin's Phase 3 plan).
- GTK bookmark per account in `~/.config/gtk-3.0/bookmarks`.

**Phase 6 — packaging.**
- AUR package for the helper scripts + systemd units, so `install.sh`
  collapses to `omarchy-pkg-add omarchy-google-drives`.
- CI: run `test/model.test.js`, `test/status-fixture.sh`, and `omarchy
  plugin validate` on every push.

## Security notes

- Plugins run **unsandboxed** inside the long-lived `omarchy-shell` process
  — review `Service.qml` and the `bin/` scripts before enabling, same
  warning Omarchy itself shows on `plugin add`.
- `googledrive-accountctl` writes `accounts.json` atomically (temp file +
  `os.replace`) and refuses a symlinked target or state directory, matching
  the defensive pattern the first-party CPU plugin's `state-dir-safety`
  test checks for, and the same pattern `omarchy-protondrive` uses.
- Per-account directories are created `0700`; the `env` file consumed by
  systemd is `0600`.
- Secrets: rclone's own config-file encryption (`rclone config` with a
  config password) is not yet wired to the desktop keyring here — v0.1's
  per-account `rclone.conf` files are protected only by directory
  permissions, same starting point as `omarchy-protondrive`'s v0.1. Routing
  the config password through `libsecret`/`gnome-keyring` via rclone's
  `--password-command` (the approach edbron/omarchy-cloud-drives already
  ships) is a Phase 2/3 item, not yet done.
