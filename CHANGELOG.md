# Hushlist app changelog

Installed copies update themselves within about an hour of a release.

## Version 5 (2026-11-14)

New look: the installer opens with HUSHLIST spelled in digits and shows animated progress while it installs.

## Version 4 (2026-11-14)

New signing key (devices on version 3 need the installer run once more). Smaller list format (under 5 MB) with 8,310 new domains. Stability: download time limits, one run at a time, every list line validated, cleanup after failures, Windows retries when antivirus holds the hosts file, faster Windows processing.

## Version 3 (2026-11-07)

Safer, lighter updates: the list downloads only when it changes and is integrity-checked; updates self-test before installing; hosts writes are atomic; essential names are never blocked. Windows: fixes the installer not starting on double-click and locks down the updater folder.

## Version 2 (2026-11-06)

Installed copies now update themselves with signed releases. Updates are only installed if they carry the Hushlist signature, are newer than the installed version and pass a syntax check.

