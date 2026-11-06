⚡ DNS Blocklists, hush the noise with Hushlist.

** What is this project? **

A comprehensive collection of DNS blocklists designed to protect your network from unwanted content, including advertisements, trackers, telemetry, phishing attempts, malware, scams and other malicious or intrusive domains.

Designed for universal compatibility, these lists work across all regions and integrate with virtually any commonly used DNS provider, ad blocker or content filtering solution.

See hushlist.online for how-tos.

## Installer updates (for maintainers)

The Mac and Windows installers update themselves: every hour, installed copies check for a newer
version and install it **only if it's signed with your private key**. Anything else is ignored,
including edits pushed to GitHub that weren't released with the script below.

- One time: `python3 scripts/release.py keygen` creates your key at `~/.hushlist/signing-key.pem`.
  Back it up somewhere safe and never commit or share it. If it's lost, installed copies can't be updated
  until people reinstall.
- To ship a fix or feature: edit `install/hushlist-mac.command` and/or `install/hushlist-windows.ps1`,
  then on the Mac with the key run `python3 scripts/release.py publish "What changed"`.
  It bumps the version, signs both installers, updates `CHANGELOG.md`, commits and pushes.
- The site build runs `scripts/release.py verify` and won't deploy installers that aren't signed.

