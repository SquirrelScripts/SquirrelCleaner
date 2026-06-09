# SquirrelCleaner 🐿️

> One command. Clears the cache crud off a Windows box, tells you how much it freed. That's the whole pitch.

A quick-and-dirty Windows cache cleaner in pure PowerShell — the spiritual descendant of old-school CCleaner, before it got bloated. No install, no dependencies, one file.

```
  🐿️  SquirrelScripts — Cache Cleaner
  -----------------------------------
  User temp                  1.2 GB
  Internet cache             184 MB
  Chrome cache               412 MB
  Edge cache                 96 MB
  --------------------------------
  Freed 1.87 GB  🐿️
```

## Run it

Downloaded `.ps1` files come into Windows **blocked** (Mark-of-the-Web), so unblock it first, then run. From the folder you saved it in:

```powershell
# 1. unblock the downloaded file
Unblock-File .\Invoke-SquirrelCleaner.ps1

# 2. dry run first — see what it'd clean, delete nothing
powershell -ExecutionPolicy Bypass -File .\Invoke-SquirrelCleaner.ps1 -WhatIf

# 3. for real
powershell -ExecutionPolicy Bypass -File .\Invoke-SquirrelCleaner.ps1
```

Always do the `-WhatIf` pass first. It shows you every target and how much it'd reclaim, and touches nothing.

## What it cleans

By default (no admin needed):

- Your user temp folder (`%TEMP%`)
- Windows internet cache (`INetCache`)
- Browser caches — **Chrome, Edge, Brave, Vivaldi, Firefox** — across *every* profile, not just the default one

Opt-in extras (see switches below):

- `C:\Windows\Temp` (system temp)
- The Windows Update download cache
- The Recycle Bin

## Switches

| Switch | What it does | Needs admin? |
|--------|--------------|:---:|
| `-WhatIf` | Preview only — deletes nothing | – |
| `-Confirm` | Prompt before each target | – |
| `-SkipBrowsers` | Leave browser caches alone | – |
| `-IncludeSystem` | Also clear `C:\Windows\Temp` | yes |
| `-IncludeWindowsUpdate` | Stop the update service, clear its download cache, restart it | yes |
| `-EmptyRecycleBin` | Empty the Recycle Bin | – |

For the admin switches, run from an **elevated** PowerShell. Without admin, the script warns and skips them rather than failing.

```powershell
# the works (run elevated)
powershell -ExecutionPolicy Bypass -File .\Invoke-SquirrelCleaner.ps1 -IncludeSystem -IncludeWindowsUpdate -EmptyRecycleBin
```

## Is it safe?

Reasonable thing to ask before running a stranger's script with admin:

- It only touches cache and temp directories — the stuff Windows and your browsers regenerate on their own. No documents, no settings, no saved logins, no bookmarks.
- It **won't** force-close your browser. If one's open, it skips the files that are locked and tells you to close it for a deeper clean.
- `-WhatIf` shows you exactly what it'd remove before you commit. Read the code — it's ~260 lines and not minified.
- It's **junction/symlink-aware** — it won't follow reparse points, so a symlink dropped in `%TEMP%` by a sketchy installer can't redirect the delete loop at real data elsewhere on disk.

## Requirements

Windows, PowerShell 5.1 or newer (works on PowerShell 7 too).

---

Part of **[SquirrelScripts](https://squirrelscripts.github.io)** — a stash of small, sharp tools for sysadmins.

If it saved you a headache: ☕ **[Buy me a coffee](https://buymeacoffee.com/eblank)**

<sub>Built in a tree.</sub>
