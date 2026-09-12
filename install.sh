#!/usr/bin/bash
# Installs this plugin's runtime dependencies and helper scripts, then
# enables the bar widget. Not wired into `omarchy install service ...`,
# that dispatcher only scans Omarchy's own /usr/bin, which is reserved for
# first-party services (see the omarchy.* id restriction in
# omarchy-plugin-validate). Third-party plugins install themselves.
#
# Usage, run once, after `omarchy plugin add <this repo> --enable`:
#   ~/.config/omarchy/plugins/spuder.googledrive/install.sh
# Safe to run from anywhere: everything below is relative to this script's
# own directory, not the caller's.

# Re-exec under a closed environment before doing anything else.
# omarchy-pkg-add below crosses a privilege boundary (it runs `sudo
# pacman` internally) — if it, or anything it calls in turn, resolved by
# bare name through whatever PATH the caller's shell happened to have, a
# shadowed command earlier in that PATH could run with that same
# escalation. `env -i` clears the entire inherited environment; only HOME
# and a pinned, single-directory PATH are put back — /usr/bin only, not
# also /usr/local/bin: nothing this script or anything it calls actually
# lives there (checked directly), so it's dropped rather than trusted
# unverified. Omarchy's own tools (omarchy-pkg-add, omarchy-plugin-enable)
# are called by absolute path below instead of relying on PATH for them.
# The shebang above is `#!/usr/bin/bash`, not `#!/usr/bin/env bash` —
# `env` would itself resolve `bash` through the *caller's* inherited PATH,
# before a single line here runs, ahead of this re-exec guard entirely.
# Checked directly too: this session has no SUDO_ASKPASS/polkit graphical
# prompt configured, so a plain terminal `sudo` password prompt needs
# neither — env -i doesn't touch the TTY, only environment variables.
# HOME/XDG_RUNTIME_DIR/DBUS_SESSION_BUS_ADDRESS aren't secret — they're
# session-location info any process in this login session already has —
# but `systemctl --user` below (and the mount units it manages) genuinely
# needs the latter two: confirmed live, `env -i` without them fails with
# "Failed to connect to user scope bus via local transport: ...not
# defined". OMARCHY_PATH is required too, also live-discovered —
# omarchy-plugin-enable calls omarchy-shell, which refuses to run at all
# without it ("OMARCHY_PATH is not set"). Both fixed, non-secret values,
# confirmed on this machine, not guessed.
if [[ -z "${GOOGLEDRIVE_INSTALL_REEXECED:-}" ]]; then
  exec /usr/bin/env -i \
    GOOGLEDRIVE_INSTALL_REEXECED=1 \
    HOME="$HOME" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    OMARCHY_PATH="/usr/share/omarchy" \
    PATH="/usr/bin:/usr/share/omarchy/bin" \
    /usr/bin/bash "$0" "$@"
fi

set -euo pipefail

# Named absolute paths for every command this script calls by bare name
# otherwise, not just the ones that cross a privilege boundary — the
# re-exec above already pins PATH to two trusted directories, but naming
# each one explicitly means nothing here still depends on PATH resolution
# actually finding the right binary, only on these specific paths existing
# (verified via `command -v` on the machine this was written on).
DIRNAME=/usr/bin/dirname
CAT=/usr/bin/cat
MKDIR=/usr/bin/mkdir
READLINK=/usr/bin/readlink
LN=/usr/bin/ln
INSTALL=/usr/bin/install
SYSTEMCTL=/usr/bin/systemctl
OMARCHY_PKG_ADD=/usr/share/omarchy/bin/omarchy-pkg-add
OMARCHY_PLUGIN_ENABLE=/usr/share/omarchy/bin/omarchy-plugin-enable

cd "$("$DIRNAME" "${BASH_SOURCE[0]}")"
PLUGIN_DIR="$(pwd)"

echo "Installing rclone and fuse3..."
"$OMARCHY_PKG_ADD" rclone fuse3

# Symlink (not copy) the two CLI helpers onto PATH, and only if nothing
# unrelated already occupies that name — ~/.local/bin is a generic, shared,
# user-writable directory, so blindly overwriting whatever's there could
# clobber a pre-existing unrelated tool. A symlink back into this plugin's
# own directory also means a `git pull` here is immediately live, no
# reinstall needed, and uninstall.sh can safely tell "ours" from "not ours"
# before removing anything.
link_or_skip() {  # link_or_skip <name>
  local name="$1"
  local source="$PLUGIN_DIR/bin/$name" dest="$HOME/.local/bin/$name"
  "$MKDIR" -p "$("$DIRNAME" "$dest")"
  if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ "$("$READLINK" -f -- "$dest" 2>/dev/null)" == "$("$READLINK" -f -- "$source")" ]]; then
      return 0  # already ours, nothing to do
    fi
    echo "install.sh: $dest already exists and isn't ours — leaving it alone." >&2
    echo "  Run $name from $source instead, or remove $dest yourself and re-run install.sh." >&2
    return 0
  fi
  "$LN" -s "$source" "$dest"
}

echo "Linking helper scripts onto PATH (~/.local/bin)..."
link_or_skip googledrive-status
link_or_skip googledrive-accountctl
# googledrive-mount is intentionally NOT linked here — the systemd unit
# below executes it directly from this plugin's own directory instead of
# via a copy in a generic shared location. See the unit file's own comment.

echo "Installing the per-account systemd user template..."
"$INSTALL" -Dm644 systemd/omarchy-google-drive-mount@.service \
  "$HOME/.config/systemd/user/omarchy-google-drive-mount@.service"
"$SYSTEMCTL" --user daemon-reload

echo "Adding Google Drives to the bar..."
"$OMARCHY_PLUGIN_ENABLE" spuder.googledrive

"$CAT" <<MSG

Installed. Click the new "G" icon in the bar and choose "Add a Google Drive
account" to open a sign-in terminal (Google's own browser OAuth — nothing
is typed into this plugin), or from a terminal:

  googledrive-accountctl add alice@gmail.com

Either way, it mounts itself automatically as soon as sign-in verifies —
no extra command to run.

MSG
