#!/usr/bin/env bash
# Stops every configured account's mount unit, disables the bar widget, and
# removes the helper scripts and systemd unit this plugin installed.
# Leaves ~/.config/omarchy-google-drive (accounts, rclone configs) and any
# mounted files under ~/GoogleDrive untouched — remove those yourself once
# you've confirmed you don't need them.
set -euo pipefail

if command -v googledrive-accountctl >/dev/null 2>&1; then
  while IFS=$'\t' read -r id _rest; do
    [[ -n $id ]] || continue
    systemctl --user disable --now "omarchy-google-drive-mount@${id}.service" 2>/dev/null || true
  done < <(googledrive-accountctl list 2>/dev/null | grep -v '^No accounts' || true)
fi

omarchy-plugin-disable spencerowen.googledrive || true

rm -f "$HOME/.local/bin/googledrive-status" \
      "$HOME/.local/bin/googledrive-accountctl" \
      "$HOME/.local/bin/googledrive-mount" \
      "$HOME/.config/systemd/user/omarchy-google-drive-mount@.service"
systemctl --user daemon-reload

echo "Uninstalled. Your accounts and mounted files were left in place:"
echo "  ~/.config/omarchy-google-drive"
echo "  ~/GoogleDrive"
