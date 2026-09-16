# Security

## Reporting a vulnerability

Open a [GitHub issue](https://github.com/spuder/omarchy-google-drives/issues)
or contact the maintainer directly through their GitHub profile
([@spuder](https://github.com/spuder)) if the issue shouldn't be public yet.
There's no bug bounty here — this is a small, unpaid Omarchy plugin — but
real reports are read and acted on.

## What this plugin actually touches

Short version; the full trace lives in [PLAN.md](PLAN.md)'s "Security
notes" section and its per-round self-review entries:

- Runs `rclone` (per-account OAuth config, one process per account) and
  `systemctl --user` for its own mount units — nothing else, no other
  package installs or services after `install.sh` finishes.
- Stores each account's rclone config and a small quota cache under
  `~/.config/omarchy-google-drive/<id>/`, `0700`, one subdirectory per
  account, never shared between accounts.
- Never reads, logs, or holds an OAuth token itself — sign-in is entirely
  rclone's own browser OAuth hand-off; this plugin only checks whether a
  token is *present*, never its value.
- The one privileged step is `install.sh`'s call to Omarchy's own
  `omarchy-pkg-add` (which runs `sudo pacman` internally) to install
  `rclone`/`fuse3` — this plugin never calls `sudo`, `pkexec`, or `doas`
  directly, and has no sudoers rule of its own.

## Process

This repo runs a security self-review before every marketplace submission
or update, using the
[`omarchy-plugin-security-review`](https://github.com/tcballard/build-omarchy-plugins)-style
checklist (trust-boundary mapping, command/argument safety, credential and
local-data storage, network access, privilege/service/package changes,
dependency and release supply chain) — kept as a user-level Claude Code
skill rather than duplicated in this file, so it can't drift out of date
here while staying current elsewhere. Every round's findings, fixes, and
the exact commit they were verified at are recorded in
[PLAN.md](PLAN.md); the most recent is "Security self-review (2026-09-16)".

This doesn't replace, and isn't a claim equivalent to, the marketplace's
own [validation](https://plugins.omarchy.org/publish.html) or
[Automated Security Baseline](https://github.com/HANCORE-linux/omarchy-plugin-marketplace/blob/main/SECURITY_BASELINE.md) —
see the live review history on
[issue #6454](https://github.com/omacom/omarchy-plugin-marketplace/issues/6454)
for those. Like any Omarchy plugin, this one runs as unsandboxed code
under your own user account; no self-review changes that.
