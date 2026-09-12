#!/usr/bin/env bash
# Stops every configured account's mount unit, disables the bar widget, and
# removes the helper scripts and systemd unit this plugin installed.
# Leaves ~/.config/omarchy-google-drive (accounts, rclone configs) and any
# mounted files under ~/GoogleDrive untouched — remove those yourself once
# you've confirmed you don't need them.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
PLUGIN_DIR="$(pwd)"

if command -v googledrive-accountctl >/dev/null 2>&1; then
  while IFS=$'\t' read -r id _rest; do
    [[ -n $id ]] || continue
    systemctl --user disable --now "omarchy-google-drive-mount@${id}.service" 2>/dev/null || true
  done < <(googledrive-accountctl list 2>/dev/null | grep -v '^No accounts' || true)
fi

omarchy-plugin-disable spuder.googledrive || true

# Only remove a ~/.local/bin entry if it's still the symlink install.sh
# made, pointing back into this exact plugin directory — install.sh
# already refuses to overwrite anything it didn't create, so mirror that
# here: never delete a file this plugin didn't put there.
unlink_if_ours() {  # unlink_if_ours <name>
  local name="$1"
  local source="$PLUGIN_DIR/bin/$name" dest="$HOME/.local/bin/$name"
  [[ -L "$dest" ]] || return 0
  [[ "$(readlink -f -- "$dest" 2>/dev/null)" == "$(readlink -f -- "$source")" ]] || return 0
  rm -f "$dest"
}

unlink_if_ours googledrive-status
unlink_if_ours googledrive-accountctl
rm -f "$HOME/.config/systemd/user/omarchy-google-drive-mount@.service"
systemctl --user daemon-reload

echo "Uninstalled. Your accounts and mounted files were left in place:"
echo "  ~/.config/omarchy-google-drive"
echo "  ~/GoogleDrive"
