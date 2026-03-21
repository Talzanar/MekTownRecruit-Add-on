# MekTown Recruit 2.1.1 - The Sync & Ledger Update

This is the big stability release! We've spent the last few weeks hardening the sync engine and fixing the Guild Bank Ledger so it actually behaves like a proper ledger.

## What's New

### The Guild Bank Ledger Actually Works
- **No more upside-down logs:** The newest transactions now correctly stay at the top of the list.
- **Gold tracking:** Added a dedicated "Gold" filter button to the ledger. Since the realm's money API can be buggy, the addon now automatically watches the bank balance while you have it open and records the gold deltas.
- **No more duplicates:** The deduplication logic was rewritten around unique transaction IDs. Multiple officers scanning the same bank tab will no longer flood the ledger with duplicates.
- **Better timestamps:** Instead of older transactions looking like they "just happened" when you scan them, the addon now accurately calculates "X days ago" based on Blizzard's rough log data.

### Bulletproof Sync
- **No more mismatch spam:** We fixed the bug where the `GuildTree` and `GuildBank` syncs would scream about "hash mismatches" during heavy traffic.
- **True Convergence:** DKP, Recruits, Kick Logs, the Inactivity Whitelist, and the Guild Tree now reliably sync their revisions across all online officers using a strict hash-matching system.
- **Member Safety:** Regular guild members can receive all this synced data (like the Vault snapshot and DKP standings) but are strictly blocked from accidentally broadcasting scans or sync pings.

### Quality of Life Tweaks
- **Auto-Close for Raiders:** Added toggles in the Profile tab to automatically close all addon windows the second you enter combat or zone into an instance. No more dying because you were looking at the DKP standings.
- **Quick Links:** Added "Open Guild Tree" and "Open Guild Bank" shortcut buttons to the Guild Workspace so officers don't have to menu-dive.
- **Quiet Testing:** Added an adaptive debug mode (`/mek debug module ledger on` with `/mek debug chat off`) so officers can test things without flooding their chat boxes.

## Codebase Overhaul
- The entire project folder was gutted and restructured into proper `Core`, `UI`, `Modules`, and `Commands` directories. It's much cleaner for future development.
- Stripped out hundreds of lines of dead code and old text-scraping functions that we no longer need.

*Update your addons, reload your UI, and enjoy the WAAAGH!*
