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
  retained complete stdout/stderr with no size cap. First pass: a 64KB
  truncation applied after `StdioCollector`'s `onStreamFinished`. Correctly
  called out as insufficient in round 2 below (`StdioCollector` had
  already buffered the whole stream internally by that point) — see that
  section for the actual fix.

One unrelated bug caught while writing the collision-check fix, not from
the review: `local name="$1" source="...$name" dest="...$name"` on one
line doesn't work under `set -u` — bash expands every word on a command
line before any of that line's assignments take effect, so `$name` inside
the same `local` statement it's being assigned in is still unbound.
Reproduced directly, then split into two `local` statements in both
`install.sh` and `uninstall.sh`.

### Round 2: incremental output capping and environment isolation (2026-09-12)

The first pass's `capText()` was accurately called out as treating the
symptom, not the cause: `StdioCollector` (`waitForEnd: true`) buffers the
*entire* stream internally before `onStreamFinished` fires, so truncating
in that handler bounds only what gets copied into this plugin's own
properties afterward, not Quickshell's own peak memory while reading. The
absolute-path `python3` fix was also called out as incomplete: an absolute
path pins *which* interpreter runs, not what environment it starts with —
inherited `PYTHONPATH`/`PYTHONHOME`/`LD_PRELOAD`/etc. could still shape
its startup.

Checked Quickshell's actual `Quickshell.Io` source
([process.hpp](https://github.com/quickshell-mirror/quickshell/blob/master/src/io/process.hpp),
[datastream.hpp](https://github.com/quickshell-mirror/quickshell/blob/master/src/io/datastream.hpp))
directly rather than guess at API that might not exist:

- **Incremental capping.** `StdioCollector` isn't the only
  `DataStreamParser` — `SplitParser` emits its `read(data)` signal per
  chunk as data arrives, and setting `splitMarker: ""` makes it emit
  immediately per raw read (no delimiter search, so nothing is held
  waiting for one). `Service.qml` now defines `BoundedCollector`, a
  `SplitParser` that accumulates into its own bounded `text` property and,
  the moment `maxCollectedChars` (64KB) is exceeded, truncates *and calls
  `proc.signal(9)`* on the owning `Process` — the process is killed
  outright the instant it produces too much output, not just after the
  fact.
- **Hard deadline.** A `Timer` per `Process`, bound to that process's own
  `running` property (so it restarts fresh on every invocation and cancels
  itself if the process exits first), fires `proc.signal(9)` after
  `hardDeadlineMs` (30s) regardless of output size — the size cap catches
  a noisy process, this catches a hung one.
- **Environment isolation.** `Process.clearEnvironment: true` rebuilds
  each helper's environment from nothing rather than inheriting the shell
  process's; `environment: minimalEnvironment` then passes through exactly
  four variables — `PATH` (to our own trusted value, not the inherited
  one), and `HOME`/`XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` as `null`
  (Quickshell's `clearEnvironment` semantics: `null` means "pass the
  system value through" instead of its normal "remove this"), because
  `Path.home()` and `systemctl --user`'s session addressing need them and
  none of the three are secret. Everything else — `LD_PRELOAD`,
  `PYTHONPATH`, `PYTHONHOME`, etc. — is simply absent. `python3` also
  gained `-I` (isolated mode: ignores `PYTHONPATH`/`PYTHONHOME`/user
  site-packages/`.pth` files), closing the gap an absolute interpreter
  path alone left open.

**Honest gap, not silently dropped:** the reviewer specifically asked for
"a hard deadline/process-tree cleanup." The deadline is real; process-tree
cleanup is not, and can't be built from what `Quickshell.Io.Process`
actually exposes — `signal()` targets only the tracked child PID, there's
no process-group/session-kill primitive in the header. If `googledrive-
status`/`googledrive-accountctl` had already spawned `rclone`/`systemctl`
via a blocking `subprocess.run(..., timeout=N)` call at the exact moment
the parent is killed, that grandchild isn't taken down by killing the
parent — though every such call already carries its own short timeout
(3-30s) that Python's own `subprocess` module enforces independently by
killing the child itself on expiry, which bounds the exposure window
regardless of the parent's fate. A true process-group kill would need
launching the child into its own process group (e.g. via a `setsid`
wrapper) and signaling the group, which isn't achievable through the QML
API alone — flagged here rather than claimed as done.

### Round 3: the installation boundary and detached launches (2026-09-12)

Round 2 fixed the QML-launched helpers; this round's finding was that the
*installation* boundary had the identical problem one level up:
`install.sh`/`uninstall.sh` resolve `omarchy-pkg-add`, `mkdir`, `readlink`,
`ln`, `install`, `systemctl`, and `omarchy-plugin-enable`/`-disable` by
bare name through the caller's inherited environment, and `Service.qml`'s
two `Quickshell.execDetached()` calls (`uwsm-app`, `xdg-open`,
`omarchy-launch-floating-terminal-with-presentation`) do the same. The
sharper point specifically named: `omarchy-pkg-add` runs `sudo pacman`
internally — confirmed by reading it directly
(`/usr/share/omarchy/bin/omarchy-pkg-add`) — so a shadowed command ahead
of it in a tainted `PATH` doesn't just get user-level code execution, it
can ride along into that `sudo` call.

**install.sh / uninstall.sh**: both now re-exec themselves through
`/usr/bin/env -i` as the very first thing, before any other line runs —
the entire inherited environment is discarded and rebuilt from nothing.
Verified every command each script actually calls, then hardcoded
absolute paths for the ones that matter (`omarchy-pkg-add`,
`omarchy-plugin-enable`/`-disable`, `systemctl`, `mkdir`, `readlink`,
`ln`, `install`) — command paths checked directly on the machine this was
written on (`command -v`), not assumed. Coreutils this script calls but
doesn't name explicitly (`grep`, `rm`, `cd`, `dirname`) are still safe
without individual hardcoding: the re-exec already pinned `PATH` to
`/usr/bin:/usr/local/bin:/usr/share/omarchy/bin`, so there's nothing else
on it to resolve to.

`uninstall.sh` also stopped resolving `googledrive-accountctl` through
the `~/.local/bin` symlink at all (which the closed environment's `PATH`
no longer includes, by design) — it now calls the plugin's own
`bin/googledrive-accountctl` by absolute, plugin-owned path directly, one
less thing depending on a symlink the script is itself about to remove.

**This was live-tested, not just `bash -n`-checked, and that caught two
real bugs the syntax check couldn't**: the first `env -i` re-exec attempt
immediately broke `systemctl --user daemon-reload` ("Failed to connect to
user scope bus... $DBUS_SESSION_BUS_ADDRESS and $XDG_RUNTIME_DIR not
defined") and then, once that was fixed, broke `omarchy-plugin-enable`
too ("OMARCHY_PATH is not set" — traced into `omarchy-shell`, which
refuses to run without it). Both are non-secret, fixed-value session/
install-location info, now passed through explicitly in the `env -i`
invocation alongside `HOME`. Re-ran end to end after each fix until
`install.sh` completed cleanly (`Enabled spuder.googledrive`, exit 0) —
this is exactly the failure mode a "looks right, never actually run"
security fix produces, worth remembering next time.

**Service.qml's two `execDetached` calls** switched from a plain command
array to the object form (`{command, environment, clearEnvironment}` —
confirmed via `Quickshell.execDetached`'s own header that it accepts the
same shape `Process.exec()` does), with absolute paths for `uwsm-app`,
`xdg-open`, and `omarchy-launch-floating-terminal-with-presentation`, and
a `desktopEnvironment` allowlist wider than the two helper processes'
`minimalEnvironment` (adds `WAYLAND_DISPLAY`, `XDG_CURRENT_DESKTOP`,
`XDG_DATA_DIRS`, `XDG_CONFIG_DIRS` — a real GUI app needs more than the
three session-location variables the headless helpers do). Verified
empirically before committing to it, not assumed: ran `xdg-open` and the
exact `uwsm-app -- xdg-open` combination under `env -i` with only that
allowlist and confirmed the real default file manager (Strata, on this
machine) opened successfully.

**`python3 -I` now also applies on the direct-shebang execution path**,
not just Service.qml's explicit `Process.command` invocations: both
scripts' shebangs changed to `#!/usr/bin/python3 -I` (confirmed this
particular single-flag form is honored correctly by this kernel's
binfmt_script handling, live, before relying on it) — otherwise
`beginAddAccount()`'s terminal-launched `googledrive-accountctl` and
`uninstall.sh`'s direct call would have bypassed isolated mode entirely
depending on invocation path.

### Round 4: a self-review, plus the maintainer's fourth pass (2026-09-12)

Asked for a fresh read of the whole codebase for simplification/security/
bugs before the marketplace review even got to round 4 — worth noting
which findings came from which source, since two arrived independently
and agreed:

**Found first in the self-review, confirmed still worth fixing:**

- **A killed status check could silently blank the account list instead
  of showing an error.** `onExited(exitCode)` never inspected whether the
  process had actually been killed by this plugin's own size-cap or
  deadline timers (both call `signal(9)`) — only `exitCode`, which is
  implementation-defined for a signal-killed process. `googledrive-status`
  prints its one JSON payload only at the very end of a run, so a mid-run
  kill leaves stdout empty; `Model.parseAccounts("")` returns `{ok: true,
  accounts: []}` by design (a separate, correct, tested contract for its
  own use case) — so a killed process whose `exitCode` happened to read 0
  would have looked exactly like "no accounts configured." Fixed with an
  explicit `killed` property on each `Process`, set by whichever kill path
  fires *before* `signal(9)` is sent, and checked in `onExited` ahead of
  trusting anything the process produced — deliberately not relying on
  Quickshell's `exited(exitCode, exitStatus)` `exitStatus` parameter
  instead, since this plugin has never confirmed how that enum is exposed
  to QML and a second unverified API assumption wasn't worth trading for
  the first.
- **The 30s hard deadline didn't scale with account count.**
  `googledrive-status` checks every account *sequentially*, each with up
  to ~9s of its own timeout (6s `rclone about` + 3s `systemctl is-active`)
  when a quota cache has expired. With the 3 real accounts this was
  already tested against, a simultaneous cache-expiry refresh could
  approach ~27s — uncomfortably close to a flat 30s kill threshold for
  entirely legitimate work, and worse for anyone with more accounts.
  Split into `controlHardDeadlineMs` (flat 15s, fine for pause/resume/
  remove's single systemctl call) and `statusHardDeadlineMs`
  (`Math.max(30000, accounts.length * 10000 + 10000)`).
- **Confirm-to-remove could silently no-op.** `attemptRemove()` cleared
  `confirmRemoveId` *before* calling `removeAccount()`, which itself
  no-ops while another control action is in flight (`controlProcess.
  running`) — click ✕ to confirm while a different account's pause/resume
  was still running, and the removal was silently dropped with the
  confirmation state already gone and no feedback at all. Fixed by
  guarding `attemptRemove()` on `gdrive.busy` up front, and made the ✕
  button itself `enabled: !gdrive.busy` (matching the `ToggleSwitch`'s own
  busy-awareness, which it had never had) plus gave it the tooltip the
  toggle already had and this button never did.
- **`mountRoot`/`showQuota` in `manifest.json`'s settings schema did
  nothing.** `Service.qml` only ever read `refreshIntervalSec`;
  `MOUNT_ROOT` was a hardcoded constant in `googledrive-accountctl`
  regardless of what `omarchy bar set ... mountRoot` was told, and nothing
  checked `showQuota` before rendering usage text. Wired up properly
  rather than deleted: `showQuota` is read directly in `Panel.qml` now
  (falls back to the account's own `statusText` when off, rather than
  going blank); `mountRoot` reaches `googledrive-accountctl` via a new
  `GOOGLEDRIVE_MOUNT_ROOT` environment variable set in `beginAddAccount()`
  — the same env-var-override pattern `GOOGLEDRIVE_CACHE_MAX_SIZE` already
  used for `googledrive-mount` — so calling `add` directly from a
  terminal, with no override present, behaves exactly as it always has.
- **An unverified assumption about the single most important flow.** The
  round-3 environment lockdown was applied to `beginAddAccount()` without
  ever confirming the OAuth sign-in itself still worked under it — only
  the simpler "open folder" `xdg-open` path had been checked. Verified
  properly this time, live: ran `rclone config create ... drive
  scope=drive config_is_local=true` under the exact `desktopEnvironment`
  allowlist (a throwaway config path, killed after a few seconds, never
  completed) and confirmed a real "Sign in - Google Accounts" browser tab
  opened — `WAYLAND_DISPLAY` alone was sufficient; no `DISPLAY` (X11) or
  `BROWSER` variable was needed. Also verified
  `omarchy-launch-floating-terminal-with-presentation` itself opens a
  terminal window correctly under the same allowlist. No code change
  resulted from this one — it confirmed round 3's environment was already
  sufficient — but it closes a real verification gap rather than an
  actual defect, and is exactly the kind of check that should have
  happened *before* round 3 shipped, not after.
- Two lower-priority items addressed alongside the above:
  `minimalEnvironment`/`desktopEnvironment` no longer duplicate four keys
  verbatim (`desktopEnvironment` now builds on `minimalEnvironment` via
  `Object.assign`); `googledrive-status`/`googledrive-accountctl`'s
  identical `TRUSTED_PATH`/`SYSTEMCTL` constants gained an explicit
  cross-file comment instead of a shared-module refactor, which would
  have cost the "standalone, independently-runnable script" property this
  project deliberately keeps; `Model.js`'s currently-unreachable
  `aggregateState` fallback branch gained a comment explaining why it's
  intentionally still there.

**From the maintainer's fourth review pass, at commit `c9f7a42`, and
correct:**

- **The shebang itself resolves through the caller's `PATH`, before the
  `env -i` re-exec guard ever runs.** `#!/usr/bin/env bash` means the
  kernel's script loader runs `/usr/bin/env`, which resolves `bash`
  through the *inherited* `PATH` — a shadowed `bash` earlier in it would
  interpret this entire script, re-exec guard included, before any of
  this plugin's own code executes. Fixed: `#!/usr/bin/bash` directly, no
  `env` indirection, in `install.sh`, `uninstall.sh`, and
  `googledrive-mount` (the Python helpers were already `#!/usr/bin/python3
  -I`, a direct path with no equivalent gap).
- **`/usr/local/bin` was kept in the trusted `PATH` sets without
  verifying it belongs there, and several coreutils (`dirname`, `grep`,
  `cat`, `rm`, `mkdir`, `rclone`) were still resolved by bare name through
  it.** Checked directly: nothing this plugin calls, anywhere, actually
  lives in `/usr/local/bin` on this system — dropped from every trusted
  `PATH` value (QML and shell-script sides both) rather than kept and
  unverified. Every remaining bare-name command in `install.sh`/
  `uninstall.sh`/`googledrive-mount` now has an explicit hardcoded
  absolute-path variable, not just the ones that cross a privilege
  boundary.

**Not fixed, on purpose, and worth deciding explicitly rather than by
default:** the maintainer's fourth pass also asked to "prove that every
directory and executable in that lookup path is root-owned and
non-writable... or explicitly validate ownership/mode/ancestry before
use." That's not implemented. Round 1's `ExecStart`-relocation fix (moving
off `~/.local/bin`) protects against *accidental* collision with another
tool sharing a generic namespace — it was never true protection against a
genuinely malicious process already running as this user, since
`~/.config/omarchy/plugins/spuder.googledrive/` is exactly as
user-writable as `~/.local/bin` was. Stat-checking every ancestor
directory of `/usr/bin`, `/usr/share/omarchy/bin`, etc. would be
theater against that same actual threat model: arbitrary code execution
as the user who owns this account can already rewrite any file that user
owns, `.gitconfig` and this plugin's own source included, and Arch's
package manager already guarantees system-directory ownership more
reliably than an ad hoc stat check in a bash script would. Each round so
far has found something real and worth fixing; this specific ask reads as
the point where further hardening trades real value for the appearance of
thoroughness. Flagged for a human decision rather than either silently
skipped or silently implemented.

## Third-party Omarchy-plugin skills (2026-09-12)

Used the 12 canonical skills from
[tcballard/build-omarchy-plugins](https://github.com/tcballard/build-omarchy-plugins)
v0.3.1 to review this codebase, via a user-level install rather than
vendoring them into this repo — they're a general Omarchy-plugin-authoring
toolkit, not something specific to this plugin, so they belong installed
once for the user (`build-omarchy-plugins-skills-0.3.1.zip`, verified
against that release's own `SHA256SUMS`) rather than duplicated into every
plugin repo that happens to use them. MIT licensed (Tom Ballard); no files
from that release are checked in here. Notable, and part of why this
seemed worth doing beyond generic best practice: that release's own
research draws on 6,531 marketplace issue/PR records including 6,286
comments specifically by `HANCORE-linux` — the same reviewer this repo's
own submission (issue #6454) has been going back and forth with across
four rounds.

Read through the skills relevant to an existing `bar-widget` plugin
(`omarchy-bar-widget`, `omarchy-qml-patterns`, `omarchy-service-ipc`, and
their `references/`) against this codebase as it already stood after the
round-4 fixes. Most of what they prescribe was already true here — bounded
output, whole-operation deadlines, absolute executable paths, minimal
environments, argument arrays, no nested settings object, `allowMultiple:
false`, plain-text rendering on every dynamic `Text` element (checked: all
7 already had it) — which is itself useful confirmation that four rounds
of review pressure converged on roughly the same place this toolkit's
independent research did. Three concrete gaps did turn up, all fixed and
verified live rather than just read about:

- **`config_has_token()` read the OAuth token's actual value into memory
  just to check it was non-blank**, where `parser.has_option(section,
  "token")` answers the same question without ever touching the value —
  matches `process-safety.md`'s "do not read tokens from config files,
  copy them into QML state, or print them to diagnostics" (this plugin
  never did the QML/diagnostics part, but reading the value at all for a
  pure existence check was more than necessary). Fixed: check presence
  first, only inspect the value inline (never bound to a named variable)
  to reject a blank one.
- **`notify()` passed user-supplied text (an account's email) as a bare
  positional argument to `notify-send`, without a `--` end-of-options
  marker.** `reviewer-boundaries.md` names this pattern directly: "A list
  of arguments prevents shell interpretation but does not prevent a tool
  from treating attacker-controlled data as an option." Verified this was
  a real, reproducible defect, not theoretical, before fixing it:
  `notify-send --app-name=x --urgency=normal "-h looks like a flag" "body"`
  fails outright with `Unknown option -h looks like a flag`; the identical
  call with a `--` inserted before the positional arguments exits 0. An
  email an account owner chooses for their own account isn't really
  "attacker-controlled" in the usual sense, but it's still user-typed text
  this plugin doesn't otherwise validate the shape of beyond looking
  roughly email-shaped, and the fix is free.
- **`atomic_write_accounts()` and `save_cache()` both wrote to a
  predictable fixed name (`<file>.json.tmp`) rather than an exclusively
  created, unpredictable one** before renaming it into place —
  `reviewer-boundaries.md` again: "Create private temporary files
  exclusively and unpredictably, then replace relative to the retained
  parent." Both now use `tempfile.mkstemp()` in the same directory (so the
  final `os.replace()`/`.replace()` stays an atomic same-filesystem
  rename), with cleanup on any exception. Same caveat as round 4's
  unaddressed ownership-verification ask: `STATE_HOME` is already a
  private `0700` directory only this user can write to in the first
  place, so this raises the bar against a *predictable-name* race
  specifically rather than against a co-resident malicious process in
  general — worth doing regardless since `mkstemp()` costs nothing extra
  over a fixed suffix.

Also verified with the skill's own bundled tooling, not just this repo's
existing tests: `omarchy-plugin-test`'s `validate_plugin.py --json
--security .`, run from the user-level install against this repo, reports
`"valid": true` and no structural errors. (Running it from inside a
checkout of the skills repo itself, rather than against this plugin, does
throw a `needs-fixes` finding and stray capability flags — the validator
matching its own detection-pattern strings, and its reference docs'
teaching examples about sudo/pkexec/cargo, against its own source. Not
something that can happen here now that the skills aren't checked into
this tree, but worth remembering if it ever comes up again elsewhere: a
security-pattern scanner run over the tree it lives in will find itself.)

Reviewed, no code change needed: `omarchy-bar-widget`'s guidance to design
both horizontal and vertical bar forms ("a vertical bar should not merely
rotate a long horizontal label") — this plugin's bar surface is a bare
icon with no text label, so there's no long label to rotate incorrectly in
the first place.
