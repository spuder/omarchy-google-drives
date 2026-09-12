# Plan: native, multi-account Google Drive for Omarchy

## Status of this repo (read this first)

This is v0.1. The shell (manifest, Panel/Service/Model, bar icon), the CLI
(`googledrive-accountctl`, `googledrive-status`, `googledrive-mount`), the
systemd template, and the install/uninstall scripts are all written and
internally consistent — `Model.js`'s parsing/formatting logic has unit
tests, `googledrive-status --demo` has a JSON-shape smoke test.

**Installed and exercised live**, not just statically reviewed: running in
a real `omarchy-shell`, symlinked (`ln -sfn ~/Projects/omarchy-google-drives
~/.config/omarchy/plugins/spuder.googledrive`) so source edits apply
after `omarchy restart shell` without a full reinstall. Two real Google
accounts signed in end to end (browser OAuth, email-derived id, auto-start)
and mounted simultaneously — see the panel screenshot at the top of the
README, taken from this actual run: both accounts showing real storage
usage (81 GB of 2.2 TB; 31.5 MB of 16.1 GB) and files. This flushed out two
real systemd unit bugs (StartLimit* silently ignored in the wrong section;
a failed `ExecStop` counted as the whole unit failing and triggering an
unwanted restart loop right after a fresh mount) — both fixed, see git
history. Not yet exercised: the VFS cache actually evicting under load
(mounted accounts so far are small enough that eviction hasn't been
forced), and the remove button/keyboard-confirm flow (added after the
screenshot above).

This repo went through one architecture change before reaching this state:
v0.1 originally used `rclone bisync` for genuine two-way, offline-capable
sync instead of a mount. That was reverted once the actual consequence of
"bisync requires a full local replica of everything in scope" was worked
through against a large-Drive/small-disk scenario. See "Why mount, not
bisync" below for the full reasoning — kept in detail because the same
tradeoff will look tempting again the next time someone wants genuine
offline sync back.

## Why this shape

Google has no official Linux Drive **sync** client to wrap (contrast
Omarchy's first-party Dropbox plugin, which wraps the real `dropboxd`).
[Google Drive for desktop](https://support.google.com/a/answer/7491144) is
Windows/macOS only; there is no official Drive CLI with sync or mount
commands. So, like the Proton Drive plugin, this one has to own more:

1. **Sync/transport**: [rclone's `drive` backend](https://rclone.org/drive/)
   handles Google's OAuth and the actual API calls. Not reimplemented here.
2. **Filesystem**: `rclone mount --vfs-cache-mode=full` per account — FUSE,
   on-demand fetch, a local cache bounded by `--vfs-cache-max-size` (see
   below) rather than a full local copy.
3. **Shell surface**: one Quickshell `bar-widget` plugin, structurally
   identical to the Proton Drive plugin's Panel/Service/Model split, itself
   modeled on the first-party Dropbox plugin
   (`/usr/share/omarchy/shell/plugins/panels/dropbox/`).
4. **File-manager surface**: deliberately minimal — see "No standard
   Finder" below for why this plugin doesn't chase per-file-manager
   integrations the way a single-DE app could.

## Why mount, not bisync (decision history)

**The original plan used `rclone bisync`.** The reasoning at the time: the
actual ask was bidirectional sync, and a mount is a live network view, not
"a folder that stays in sync and still works with the network off." Every
existing Google Drive Omarchy plugin already does the mount approach —
JoshuaFurman's own README names the gap directly: *"A true offline folder
needs `rclone bisync` and a conflict-resolution story."* Building genuine
bisync-based two-way sync looked like the actual differentiator worth
having over the three mount-based competitors.

**That plan was reverted after working through what happens when the Drive
account holds more data than the local disk has free** — the concrete
scenario: a 2 TB Google Drive account, a laptop with a 500 GB disk.
Checked directly against rclone's own documentation, not assumption:

- `bisync` has **no disk-space awareness, no quota, no partial or
  streaming mode, and no documented behavior for running out of local
  disk mid-sync.** It requires a full local replica of everything in its
  scope, because two-way reconciliation means diffing two complete
  listings — there is no way to make it store less than 100% of whatever
  it's told to sync. Scoping it to a subfolder (which bisync does support,
  via ordinary subpaths or `--filters-file`) only moves the same problem
  to whatever subset is chosen; it doesn't remove it. A 2 TB account
  syncing everything under My Drive to a 500 GB disk doesn't get slower or
  degraded, it fails outright once the disk fills, or silently exhausts
  the disk and *then* fails for everything else running on the machine.
- `rclone mount`'s VFS cache, by contrast, has three real disk-bounding
  flags (`--vfs-cache-max-size`, `--vfs-cache-max-age`,
  `--vfs-cache-min-free-space`) with least-recently-used eviction. Content
  that isn't opened never touches disk. This is why every one of the three
  existing Google Drive plugins uses mount, and it's also literally what
  Google's own Drive for desktop client does by default: its "Stream"
  mode ("uses almost no computer space") is the recommended default
  specifically because its "Mirror" mode ("downloads a full copy... can
  fill up your hard drive") requires exactly the free disk space bisync
  would have silently demanded here.

**A hybrid was seriously considered before dropping bisync entirely**: keep
mount as the default whole-Drive view, and add an opt-in "pin this folder
to always be available offline" feature backed by a separate, explicitly
scoped `bisync` pass per pinned folder — the same shape Dropbox's Smart
Sync and OneDrive's Files On-Demand use (online-only by default, specific
folders marked always-local). This is real, buildable, and not ruled out
for a future version — but it roughly doubles the moving parts (a second
unit type per pin, size-checking before allowing a pin, a second local
root so the pinned copy and the mount's view of the same subtree don't
collide) for a guarantee — "this specific folder is always available
offline" — that nothing in the original ask actually required once framed
as a size problem instead of an offline-access problem. Deferred rather
than built; see Roadmap.

**Net decision**: plain `rclone mount`, bounded VFS cache, no bisync. This
converges this plugin's sync engine with the three existing competitors —
worth being honest about, since it was the main hoped-for differentiator
— but it's the only choice here that doesn't have a "starts silently
filling your disk" failure mode. See README's Comparison section for what
still *does* differentiate this plugin (multi-account isolation, generic
file-manager handling) now that the sync engine itself matches the field.

### No standard Finder

Because the mount is a real POSIX directory, no file manager needs any
special support to browse it — Nautilus, Dolphin, Thunar, Nemo,
PCManFM-Qt, a terminal, all just work, unlike an app that has to be
individually taught about each one. The one place this plugin *does* pick
a specific action is the panel's "open folder" button, and there — since
Omarchy isn't tied to one desktop environment the way GNOME or KDE are, so
there's no single default file manager to assume — it shells out to
`xdg-open` rather than hardcoding a specific app (an earlier version of
this code, like wesleycole's plugin, hardcoded `nautilus`). `xdg-open`
resolves to whatever the current session has actually registered as its
default folder handler.

Two things this deliberately does *not* attempt, because they don't have a
cross-desktop answer:
- **Sidebar bookmarks.** GTK file managers (Nautilus, Nemo, partially
  Thunar) read `~/.config/gtk-3.0/bookmarks`, a plain-text list. KDE's
  Dolphin/Konqueror instead read a different XML format,
  `~/.local/share/user-places.xbel`, and ignore the GTK file entirely.
  Supporting both is possible but is real, deliberate scope — not
  attempted in v0.1.
- **Emblems/status overlays** (a synced/error badge on files, the kind of
  thing the Proton Drive plugin's PLAN.md sketches for its own Phase 3).
  `nautilus-python` only loads inside Nautilus; Dolphin has a separate,
  incompatible KDE overlay-icon plugin API; Thunar and Nemo have no public
  equivalent at all. There is no single extension point that covers more
  than one file manager here — genuine support would mean N separate,
  maintained integrations. Out of scope for v0.1; not on the near-term
  roadmap either, since the mount already satisfies "browsable anywhere"
  without it.

## Multi-account design

Same reasoning and same shape as `omarchy-protondrive`'s, because the
underlying problem is identical — Google Drive for Linux has no
multi-account story of its own to inherit, any more than Proton Drive or
Dropbox do:

- Each account gets a **fully separate rclone config file**
  (`~/.config/omarchy-google-drive/<id>/rclone.conf`), not shared sections
  in one file. Removing an account is a directory removal; a revoked token
  for one account can't touch another.
- Each account gets its **own `rclone mount` process**, via the templated
  `omarchy-google-drive-mount@<id>.service` unit, rather than multiplexing
  several mounts through one `rclone rcd`. Costs a little more memory;
  buys crash isolation (`work`'s mount hanging doesn't take `personal`
  down with it).
- Each account gets its **own mount point**
  (`~/GoogleDrive/<Display Name>/`), so file-manager bookmarks and any
  future integration can key off path prefix alone.
- `googledrive-status`'s account objects and `accounts.json` are keyed by
  `id` throughout, same as the Proton Drive plugin's `(account_id, path)`
  convention.
- Signing in twice with two different Google accounts works because each
  `add` is its own independent `rclone config create ... config_is_local=true`
  browser round trip — Google's own account chooser, not something this
  plugin has to arbitrate.

### Sign-in UX: email as the label, auto-start, no manual finish step

`add` asks for the account's email rather than an invented short id — a
person naturally thinks of "my work Google account" as an email address,
not a slug they have to make up on the spot. That email becomes the
displayName shown in the panel and the mount folder name (`@`/`.` are
ordinary filename characters, no issue there). It deliberately does **not**
become the id used for the rclone remote name, the systemd instance, or
the state directory: `omarchy-google-drive-mount@alice@gmail.com.service`
reads badly — two `@`s, genuinely ambiguous which one is systemd's own
template separator — and would put the full address in `systemctl`/
`journalctl` output for no benefit. `slugify_email` takes just the part
before `@` (sanitized to the id-safe charset); `unique_id` appends `-2`,
`-3`, ... in the rare case two accounts share a local part
(`alice@gmail.com` and `alice@work.com` would otherwise collide).

Once sign-in verifies, `add` runs `systemctl --user enable --now` itself
and fires a desktop notification, rather than printing a command and
leaving the terminal to be found again. This was reported friction, not a
guess: Google's OAuth consent screen takes over the whole browser window,
and coming back afterward to a small floating terminal just to read and
copy a systemctl invocation by hand is exactly the kind of "hard to get
back to finish setup" complaint a plugin should not have. There's no
manual step left after approving in the browser — if the mount unit fails
to start, the account is still saved (not rolled back over a systemd
hiccup) and the notification says to check `systemctl --user status`
instead.

Considered and not built: removing the terminal entirely by driving
rclone's OAuth flow over its `rc` HTTP API instead of the blocking CLI
(the technique edbron/omarchy-cloud-drives already uses for its own iCloud
sign-in — a private unix socket + `rclone rcd`), so the panel could show
"Sign in with Google" as a button instead of opening a terminal at all.
Real and buildable, just more code (an RC client + state-machine walking)
for a gain that's smaller once the terminal auto-completes and gets out of
the way on its own — revisit if the terminal itself, not just the
afterward-friction, turns out to bother people.

## Roadmap

**Phase 1 — this repo.** Manifest + bar/panel plugin, account CLI, systemd
template, install/uninstall scripts, unit + smoke tests. Done.

**Phase 2 — prove it live.**
- Done: installed into a real `omarchy-shell` (symlinked plugin dir +
  `install.sh`); bar icon, panel, and account rows confirmed rendering and
  reacting.
- Done: a real, successful `googledrive-accountctl add` against two actual
  Google accounts — OAuth browser hand-off, email-derived id, auto-start,
  `rclone about` quota all confirmed working. Not yet confirmed: surviving
  a reboot/suspend cycle.
- Done: `preview.png` in the README, a real capture of the panel with two
  mounted accounts.
- Still open: confirm the disk-bounding actually holds under load — mount
  an account with more data than local free space, browse enough of it to
  fill the cache cap, and confirm eviction keeps disk usage at the
  configured ceiling rather than growing unbounded. Everything mounted so
  far has been small enough that eviction was never actually forced.

**Phase 3 — optional offline pinning (deferred, not committed).**
- Revisit the hybrid design sketched above: an explicit, opt-in "keep this
  folder available offline" action per account, backed by a separately
  scoped `rclone bisync` pass with its own size check before it's allowed
  to run and its own local root so it doesn't collide with the mount's
  view of the same subtree. Only worth building if real usage shows the
  LRU-eviction mount genuinely isn't enough for some folders (e.g. a
  project you need on a flight) — not being built speculatively.

**Phase 4 — file manager polish.**
- GTK bookmark (`~/.config/gtk-3.0/bookmarks`) and KDE places
  (`~/.local/share/user-places.xbel`) entries per account, written to both
  formats rather than assuming one desktop.
- Nautilus emblem/context-menu extension for GNOME-family file managers
  specifically (accepting that Dolphin/Thunar/Nemo would need separate,
  unbuilt integrations to get the same badges — see "No standard Finder").

**Phase 5 — packaging.**
- AUR package for the helper scripts + systemd unit, so `install.sh`
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
  ships) is a later item, not yet done.

### Marketplace security review fixes (2026-09-12)

Three concrete findings from the marketplace submission's security review
([issue #6454](https://github.com/omacom/omarchy-plugin-marketplace/issues/6454)),
all fixed:

- **Path hijack via a copy in a generic shared directory.** `install.sh`
  copied `googledrive-mount` into `~/.local/bin`, and the persistent,
  auto-restarting systemd unit executed it from there — anything else
  running as the same user could overwrite that file, and the unit would
  then run whatever replaced it. Fixed by pointing `ExecStart` at this
  plugin's own installed directory instead
  (`%h/.config/omarchy/plugins/spuder.googledrive/bin/googledrive-mount`),
  which is collision-free by construction since it's namespaced by the
  plugin's own globally-unique manifest id. The two CLI helpers that are
  still placed in `~/.local/bin` for terminal convenience
  (`googledrive-status`, `googledrive-accountctl`) switched from blind
  `install -Dm755` copies to collision-checked symlinks: `install.sh`
  refuses to overwrite anything already at that path that isn't its own
  prior symlink (warns and skips instead), and `uninstall.sh` mirrors that
  check before removing anything, so it can never delete a file it didn't
  create.
- **PATH-order hijack.** Service.qml launched bare `"python3"`, and the
  Python/bash helpers resolved `rclone`/`systemctl` via whatever `PATH`
  the calling process inherited. Fixed by pinning resolution to a fixed,
  trusted set of directories throughout: `/usr/bin/python3` hardcoded in
  Service.qml's `Process.command` arrays and in both scripts' shebang
  lines; `shutil.which(..., path="/usr/bin:/usr/local/bin")` for
  `rclone`/`notify-send` instead of an unrestricted lookup;
  `/usr/bin/systemctl` hardcoded outright (as stable a path as exists on
  any systemd distro).
- **Unbounded output collection.** The QML `StdioCollector` instances
  retained complete stdout/stderr with no size cap. Added a 64KB
  (`maxCollectedChars`) truncation in `Service.qml`'s `capText()`, applied
  to all four collectors before the text is stored on `Item` properties.
  Worth being precise about what this does and doesn't cover: Quickshell's
  `StdioCollector` (with `waitForEnd: true`) buffers the entire stream
  internally before `onStreamFinished` ever fires, so this bounds what
  gets *propagated* into this plugin's own state, not the collector's own
  peak memory while reading. A true pre-buffer cap would mean reading the
  stream incrementally instead of collecting it whole — not done, since
  both helper scripts only ever print a small, bounded amount by design
  (one JSON status object, or a short status line); this exists as a
  defensive ceiling against the unexpected, not a response to either
  script actually approaching the limit.

One unrelated bug caught while writing the collision-check fix, not from
the review: `local name="$1" source="...$name" dest="...$name"` on one
line doesn't work under `set -u` — bash expands every word on a command
line before any of that line's assignments take effect, so `$name` inside
the same `local` statement it's being assigned in is still unbound.
Reproduced directly, then split into two `local` statements in both
`install.sh` and `uninstall.sh`.
