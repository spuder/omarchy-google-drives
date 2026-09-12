#!/usr/bin/bash
# Stops every configured account's mount unit, disables the bar widget, and
# removes the helper scripts and systemd unit this plugin installed.
# Leaves ~/.config/omarchy-google-drive (accounts, rclone configs) and any
# mounted files under ~/GoogleDrive untouched — remove those yourself once
# you've confirmed you don't need them.

# Same closed-environment re-exec as install.sh, and for the same reasons
# (see its own comment for the full explanation, including why the shebang
# above is `#!/usr/bin/bash` rather than `#!/usr/bin/env bash`): nothing
# here crosses a privilege boundary the way omarchy-pkg-add does, but
# omarchy-plugin-disable and systemctl are still resolved below and need
# the same trusted, pinned environment rather than whatever the caller's
# shell had. XDG_RUNTIME_DIR/DBUS_SESSION_BUS_ADDRESS are required for
# `systemctl --user`, and OMARCHY_PATH for omarchy-plugin-disable (it
# shells out to omarchy-shell, which refuses to run without it) — both
# confirmed live, not optional. PATH is /usr/bin only: nothing this script
# calls lives in /usr/local/bin, so it isn't trusted unverified.
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
# otherwise — see install.sh's matching comment for why.
DIRNAME=/usr/bin/dirname
GREP=/usr/bin/grep
READLINK=/usr/bin/readlink
RM=/usr/bin/rm
SYSTEMCTL=/usr/bin/systemctl
PYTHON3=/usr/bin/python3
OMARCHY_PLUGIN_DISABLE=/usr/share/omarchy/bin/omarchy-plugin-disable

cd "$("$DIRNAME" "${BASH_SOURCE[0]}")"
PLUGIN_DIR="$(pwd)"
# Called by its own absolute, plugin-owned path — not the ~/.local/bin
# symlink install.sh makes, which this script is about to remove and which
# PATH no longer includes here on purpose (see the re-exec above).
ACCOUNTCTL="$PLUGIN_DIR/bin/googledrive-accountctl"

if [[ -x "$ACCOUNTCTL" ]]; then
  while IFS=$'\t' read -r id _rest; do
    [[ -n $id ]] || continue
    "$SYSTEMCTL" --user disable --now "omarchy-google-drive-mount@${id}.service" 2>/dev/null || true
  done < <("$PYTHON3" -I "$ACCOUNTCTL" list 2>/dev/null | "$GREP" -v '^No accounts' || true)
fi

"$OMARCHY_PLUGIN_DISABLE" spuder.googledrive || true

# Only remove a ~/.local/bin entry if it's still the symlink install.sh
# made, pointing back into this exact plugin directory — install.sh
# already refuses to overwrite anything it didn't create, so mirror that
# here: never delete a file this plugin didn't put there.
unlink_if_ours() {  # unlink_if_ours <name>
  local name="$1"
  local source="$PLUGIN_DIR/bin/$name" dest="$HOME/.local/bin/$name"
  [[ -L "$dest" ]] || return 0
  [[ "$("$READLINK" -f -- "$dest" 2>/dev/null)" == "$("$READLINK" -f -- "$source" 2>/dev/null)" ]] || return 0
  "$RM" -f "$dest"
}

unlink_if_ours googledrive-status
unlink_if_ours googledrive-accountctl
"$RM" -f "$HOME/.config/systemd/user/omarchy-google-drive-mount@.service"
"$SYSTEMCTL" --user daemon-reload

echo "Uninstalled. Your accounts and mounted files were left in place:"
echo "  ~/.config/omarchy-google-drive"
echo "  ~/GoogleDrive"
