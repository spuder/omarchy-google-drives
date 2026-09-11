#!/usr/bin/env bash
# Stops every configured account's sync timer, disables the bar widget, and
# removes the helper scripts and systemd units this plugin installed.
# Leaves ~/.config/omarchy-google-drive (accounts, rclone configs, sync
# state) and any synced files under ~/GoogleDrive untouched — remove those
# yourself once you've confirmed you don't need them.
set -euo pipefail

if command -v googledrive-accountctl >/dev/null 2>&1; then
  while IFS=$'\t' read -r id _rest; do
    [[ -n $id ]] || continue
    systemctl --user disable --now "omarchy-google-drive-bisync@${id}.timer" 2>/dev/null || true
    systemctl --user stop "omarchy-google-drive-bisync@${id}.service" 2>/dev/null || true
  done < <(googledrive-accountctl list 2>/dev/null | grep -v '^No accounts' || true)
fi

omarchy-plugin-disable spencerowen.googledrive || true

rm -f "$HOME/.local/bin/googledrive-status" \
      "$HOME/.local/bin/googledrive-accountctl" \
      "$HOME/.local/bin/googledrive-bisync" \
      "$HOME/.config/systemd/user/omarchy-google-drive-bisync@.service" \
      "$HOME/.config/systemd/user/omarchy-google-drive-bisync@.timer"
systemctl --user daemon-reload

echo "Uninstalled. Your accounts and synced files were left in place:"
echo "  ~/.config/omarchy-google-drive"
echo "  ~/GoogleDrive"
