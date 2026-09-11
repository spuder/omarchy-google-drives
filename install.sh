#!/usr/bin/env bash
# Installs this plugin's runtime dependencies and helper scripts, then
# enables the bar widget. Not wired into `omarchy install service ...`,
# that dispatcher only scans Omarchy's own /usr/bin, which is reserved for
# first-party services (see the omarchy.* id restriction in
# omarchy-plugin-validate). Third-party plugins install themselves.
#
# Usage, run once, after `omarchy plugin add <this repo> --enable`:
#   ~/.config/omarchy/plugins/spencerowen.googledrive/install.sh
# Safe to run from anywhere: everything below is relative to this script's
# own directory, not the caller's.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "Installing rclone and fuse3..."
omarchy-pkg-add rclone fuse3

echo "Installing helper scripts to ~/.local/bin..."
install -Dm755 bin/googledrive-status "$HOME/.local/bin/googledrive-status"
install -Dm755 bin/googledrive-accountctl "$HOME/.local/bin/googledrive-accountctl"
install -Dm755 bin/googledrive-mount "$HOME/.local/bin/googledrive-mount"

echo "Installing the per-account systemd user template..."
install -Dm644 systemd/omarchy-google-drive-mount@.service \
  "$HOME/.config/systemd/user/omarchy-google-drive-mount@.service"
systemctl --user daemon-reload

echo "Adding Google Drives to the bar..."
omarchy-plugin-enable spencerowen.googledrive

cat <<MSG

Installed. Click the new "G" icon in the bar and choose "Add a Google Drive
account" to open a sign-in terminal (Google's own browser OAuth — nothing
is typed into this plugin), or from a terminal:

  googledrive-accountctl add personal "Personal"

Either way, once signed in, mount it with:

  systemctl --user enable --now omarchy-google-drive-mount@personal.service

MSG
