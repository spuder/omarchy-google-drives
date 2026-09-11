# Google Drives

Real, two-way sync for Google Drive, for as many accounts as you have. A bar
widget for [Omarchy](https://omarchy.org/) that keeps `~/GoogleDrive/<account>`
in sync with Drive in both directions — not a browser tab, not a one-way
backup, and not just an on-demand virtual folder.

## Why this one

Google has never shipped an official Google Drive **sync** client for
Linux — [Google Drive for desktop](https://support.google.com/a/answer/7491144)
is Windows/macOS only, and there is no official Drive CLI with a sync or
mount command. So, like the other rclone-based Omarchy plugins, this one
doesn't reinvent that: [rclone](https://rclone.org/drive/)'s Google Drive
backend does the actual transfer and OAuth. What's different is *how* it's
used:

- **Real bidirectional sync, not just a mount.** This plugin runs
  [`rclone bisync`](https://rclone.org/bisync/) — rclone's dedicated
  two-way sync engine — on a timer, per account. Local edits go up, remote
  edits come down, deletes and renames are reconciled both ways, and the
  result is an actual local folder full of actual files that keeps working
  offline. That's a different tool from `rclone mount`, which is an
  on-demand virtual filesystem: convenient, but not what most people mean
  by "sync," and not what any of the three comparable Omarchy Google Drive
  plugins currently do (see [Comparison](#comparison) below — one of them
  says so directly).
- **Multiple accounts, at once, fully isolated.** Personal, work, whatever
  else: each gets its own rclone config file, its own sync folder, its own
  systemd timer, and its own pause/resume toggle in the panel. One
  account's expired token or corrupted state can't touch another's.
- **rclone under the hood, so it's proven.** No custom, reinvented
  transfer or diffing logic — rclone has done the OAuth, the API calls, and
  (as of recent versions) the bidirectional reconciliation logic for
  years.

## Install

```bash
omarchy plugin add https://github.com/spuder/omarchy-google-drives.git --enable
~/.config/omarchy/plugins/spencerowen.googledrive/install.sh
```

The first line clones and enables the widget; the second installs rclone
and the helper scripts it needs. No manual `git clone` required.

Click "Add a Google Drive account" in the panel. That opens a terminal
running rclone's own browser sign-in — pick a Google account, approve
access, done. This plugin never sees your Google password: unlike the
sister Proton Drive plugin below, there's no in-panel credential form here
at all, because Drive's OAuth hand-off means there's nothing for one to
collect. Add as many accounts as you like; each shows up as its own row,
and each is a separate trip through Google's account chooser, so you can
pick a different account every time.

Remove with `~/.config/omarchy/plugins/spencerowen.googledrive/uninstall.sh`
(your signed-in accounts and synced files are left alone; see the script
for exactly what it does and doesn't touch).

### Google OAuth client ID

rclone's shared Google Drive OAuth client is being retired during 2026.
Each user should create a personal **Desktop app** OAuth client by
following [rclone's client ID guide](https://rclone.org/drive/#making-your-own-client-id)
and pass it to `rclone config create` (or `rclone config reconnect <id>:`
to update an existing account). This plugin doesn't ship or reuse a shared
client ID, and never reads the client ID, secret, or token directly —
rclone owns that configuration, same as every other rclone-based plugin
listed below.

## How syncing works

Each account gets:

- Its own rclone remote, in its own config file
  (`~/.config/omarchy-google-drive/<id>/rclone.conf`).
- Its own local folder (`~/GoogleDrive/<Display Name>/`).
- Its own `omarchy-google-drive-bisync@<id>.timer` — every 5 minutes by
  default, running `rclone bisync` for just that account.

The **first** sync for an account does a full baseline scan
(`--resync`, required by bisync itself — see
[rclone's docs](https://rclone.org/bisync/#resync)); every run after that
is incremental. A same-file-changed-on-both-sides conflict is resolved by
keeping whichever side is newer and saving the other as a `.conflict` copy
(`--conflict-resolve=newer`) — see [PLAN.md](PLAN.md) for why that's a
deliberate v0.1 tradeoff rather than a conflict-picker UI.

## Configure

Settings are stored inline with the widget entry in
`~/.config/omarchy/shell.json` and can be changed with `omarchy bar set`:

```sh
omarchy bar set spencerowen.googledrive refreshIntervalSec 60 --json
omarchy bar set spencerowen.googledrive syncRoot "$HOME/GoogleDrive"
omarchy bar set spencerowen.googledrive showQuota false --json
```

The sync interval itself (how often the timer fires, 5 minutes by default)
is a systemd property, not a shell setting — override per account with:

```sh
systemctl --user edit omarchy-google-drive-bisync@<id>.timer
```

## CLI

Everything the panel does is also a plain command:

```sh
googledrive-accountctl list
googledrive-accountctl add work "Work"        # opens rclone's browser sign-in
googledrive-accountctl pause work              # stop the timer
googledrive-accountctl resume work             # start the timer
googledrive-accountctl sync-now work           # trigger one pass immediately
googledrive-accountctl remove work             # forget the account (keeps local files)

systemctl --user status omarchy-google-drive-bisync@work.timer
journalctl --user -u omarchy-google-drive-bisync@work.service -f
```

## Comparison

There's a real sister project to this one for Proton Drive:
[spuder/omarchy-protondrive](https://github.com/spuder/omarchy-protondrive).
Same author, same architecture (per-account isolated rclone config,
per-account systemd unit, one bar-widget panel), same reasoning for using
rclone instead of a hand-rolled sync engine. The two differ where the
providers themselves differ:

| | This plugin (Google Drive) | [omarchy-protondrive](https://github.com/spuder/omarchy-protondrive) |
|---|---|---|
| Sync engine | `rclone bisync` on a systemd **timer** — real two-way sync of actual local files | `rclone mount` (FUSE) — on-demand virtual filesystem with a VFS cache |
| Why | Google ships no Linux sync client at all, and no offline-capable one existed for this plugin to build on, so bisync's actual two-way reconciliation is the closer fit to "sync" | Chosen deliberately over bisync (still beta at the time) to get Dropbox-Smart-Sync-style on-demand fetch instead of a full duplicate local copy |
| Login | Browser OAuth (rclone opens/prints a Google consent link) — no credentials ever reach this plugin | In-panel form: id/email/password/2FA/mailbox password, sent over stdin — Proton's rclone backend does its own SRP login, so there's a real password to collect |
| Multi-account isolation | Separate rclone config + local folder + systemd unit per account | Same pattern |

And three existing Omarchy plugins cover Google Drive already:

- **[edbron/omarchy-cloud-drives](https://github.com/edbron/omarchy-cloud-drives)**
  — `rclone mount` for Google Drive, OneDrive, and iCloud Drive, each at
  one **fixed path** per provider (`~/Cloud/GoogleDrive`). One Google
  account at a time; a second one has to replace the first.
- **[JoshuaFurman/omarchy-cloud-plugin](https://github.com/JoshuaFurman/omarchy-cloud-plugin)**
  — a more general `rclone mount` wizard covering many backends. Its own
  README calls out the gap this plugin fills, verbatim: *"Offline sync.
  Only cached files work offline. A true offline folder needs `rclone
  bisync` and a conflict-resolution story."*
- **[wesleycole/omarchy-google-drive](https://github.com/wesleycole/omarchy-google-drive)**
  — Google Drive specifically, also `rclone mount`, also one remote
  (`gdrive` by default). Thin and well-documented, but explicitly a mount
  browser, not a sync tool, and doesn't manage rclone config itself (you
  run `rclone config` yourself first).

None of the three run `bisync`, and none support more than one Google
account mounted at once. That's the actual gap this plugin exists to
close — matching what `omarchy-protondrive` already does for account
isolation, applied to the sync model Google Drive itself actually needs.

## Security and privileges

Omarchy plugins run **unsandboxed** with your user permissions — review
`Service.qml` and the `bin/` scripts before enabling any plugin, this one
included.

- OAuth tokens live in rclone's own per-account config file
  (`~/.config/omarchy-google-drive/<id>/rclone.conf`, directory `0700`)
  and are never read directly by this plugin — only ever passed by
  reference (`--config <path>`) to `rclone` itself.
- `googledrive-accountctl` writes `accounts.json` atomically (temp file +
  `os.replace`) and refuses a symlinked target or state directory.
- Commands are run as argument arrays, never interpolated shell strings.
- Revoke access any time from your
  [Google Account security page](https://myaccount.google.com/permissions).

## Requirements

- Omarchy with the Quickshell/Quattro shell plugin runtime
- `rclone`, installed automatically by `install.sh`
- Nautilus, for opening a synced folder from the panel
- A browser, for Google's OAuth sign-in

## Developing

Pulled a code change into an already-installed copy with `omarchy plugin
update`? Also run `omarchy restart shell` — an active bar widget doesn't
reload its QML from a plugin rescan alone, and `Model.js` (a `.pragma
library`) doesn't reload at all short of that restart.

```sh
node --test test/                 # Model.js unit tests
./test/status-fixture.sh           # googledrive-status --demo smoke test
omarchy plugin validate .          # manifest against the Omarchy schema
```

The fuller design writeup — why bisync, the multi-account approach, and
what's still on the roadmap — lives in [PLAN.md](PLAN.md).

## License

MIT, see [LICENSE](LICENSE).
