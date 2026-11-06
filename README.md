# Hushlist

Free DNS blocklists with a setup guide for every device, hosted on GitHub Pages.
Visitors choose their device or ad blocker from a dropdown and get step-by-step instructions with your list links filled in.

## One-time setup

1. Create a free account at <https://github.com> and a new **public** repository (e.g. `hushlist`).
2. On the repo page click **Add file → Upload files** and drag in everything from this folder,
   including the hidden `.github` folder (press `Cmd + Shift + .` in Finder to show it). Click **Commit changes**.
3. Go to **Settings → Pages** and set **Source** to **GitHub Actions**.
4. Open the **Actions** tab, pick **Publish site**, and click **Run workflow**.

Your site will be at `https://<your-username>.github.io/<repo-name>/`.

## Updating the main list

The main list is `lists/hushlist.txt`, kept in this repo. To update it, upload a new version of that file
(**Add file → Upload files** in the `lists` folder) and commit. Keep the `# Credit:` and `# License:` lines at the top.

## Adding a list by link (sources.ini)

Use this for lists hosted elsewhere. On GitHub, open `sources.ini`, click the pencil icon, add a block and commit:

```ini
[my-new-list]
url = https://example.com/list.txt
title = My New List
description = What it blocks.
credit = Who made it
license = The list's licence
```

The site downloads it, converts it to hosts format and publishes it at
`.../lists/my-new-list.txt` within a few minutes. Every source is checked for updates every 6 hours.

- Keep the `[name]` the same once people use it. It's part of their subscription address.
- Only add lists whose licence allows redistribution, and keep the credit and licence lines.
  GPL-licensed lists can be shared as long as the credit and licence stay in the file (they aren't shown on the website).
- If a source is down, its last good version is **not** kept (the build makes a fresh copy each time),
  so it disappears from the site until the source is back.

## Uploading your own list file

Open the `lists` folder on GitHub → **Add file → Upload files** → drag in your `.txt` → **Commit changes**.
Add `# Title:` and `# Description:` lines at the top to set what the site shows.

## Installers (Windows / Mac)

`install/` has one-click installers that add the main list (`lists/hushlist.txt`) to the device's hosts file
and then refresh it every hour in the background (a launchd job on Mac, a scheduled task on Windows).
The site links to them in the dropdown. They keep a backup of the hosts file and can uninstall.
To point them at a different list, change `hushlist.txt` in both installer files.

iPhones can't take a hosts file, so the iPhone guide uses the AdGuard app with your list link.

## Changing the text

- Site name, headline, footer: the `SITE` block near the bottom of `index.html`.
- Dropdown entries and their steps: the `BLOCKERS` list right below it.
- FAQ: search for `EDIT ME` in `index.html`.

## Preview locally

```bash
python3 scripts/sync_upstream.py && python3 scripts/build_manifest.py && python3 -m http.server 8000
```

Then open <http://localhost:8000>. (Installer links only work once the site is published.)

## Good to know

- GitHub pauses scheduled runs if the repo has had no activity for 60 days. Re-enable it in the **Actions** tab, or make any commit.
- Files must be under 100 MB each. The main list is about 6.4 MB.
