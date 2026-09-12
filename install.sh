#!/usr/bin/env bash
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
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
PLUGIN_DIR="$(pwd)"

echo "Installing rclone and fuse3..."
omarchy-pkg-add rclone fuse3

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
  mkdir -p "$(dirname "$dest")"
  if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ "$(readlink -f -- "$dest" 2>/dev/null)" == "$(readlink -f -- "$source")" ]]; then
      return 0  # already ours, nothing to do
    fi
    echo "install.sh: $dest already exists and isn't ours — leaving it alone." >&2
    echo "  Run $name from $source instead, or remove $dest yourself and re-run install.sh." >&2
    return 0
  fi
  ln -s "$source" "$dest"
}

echo "Linking helper scripts onto PATH (~/.local/bin)..."
link_or_skip googledrive-status
link_or_skip googledrive-accountctl
# googledrive-mount is intentionally NOT linked here — the systemd unit
# below executes it directly from this plugin's own directory instead of
# via a copy in a generic shared location. See the unit file's own comment.

echo "Installing the per-account systemd user template..."
install -Dm644 systemd/omarchy-google-drive-mount@.service \
  "$HOME/.config/systemd/user/omarchy-google-drive-mount@.service"
systemctl --user daemon-reload

echo "Adding Google Drives to the bar..."
omarchy-plugin-enable spuder.googledrive

cat <<MSG

Installed. Click the new "G" icon in the bar and choose "Add a Google Drive
account" to open a sign-in terminal (Google's own browser OAuth — nothing
is typed into this plugin), or from a terminal:

  googledrive-accountctl add alice@gmail.com

Either way, it mounts itself automatically as soon as sign-in verifies —
no extra command to run.

MSG
