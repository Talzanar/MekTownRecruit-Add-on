# MekTown Recruit

Guild operations addon for **WoW 3.3.5a / Ascension (Classless)**.

MekTown Recruit combines recruiting, DKP, attendance, guild bank history, group-finder tools, and officer sync workflows into one addon package.

<img width="1024" height="1536" alt="MTR" src="https://github.com/user-attachments/assets/814b659b-cc70-4102-91fd-6709ab58a32b" />

## Version

- Addon version: `2.1.1-pre`
- Interface: `30300`
- SavedVariables: `MekTownRecruitDB`

## What This Addon Does

- Recruit scanner with keyword matching and invite support.
- DKP ledger with award/deduct/set/publish/snapshot sync.
- Attendance and boss-kill tracking.
- Guild Tree (main/alt mapping) with sync.
- Guild Ads posting tools.
- Group Radar and LFG helper views for members.
- Character Vault + Guild Bank snapshot.
- Guild Bank Ledger with long retention (far beyond default bank log window).
- Inactivity and kick tracking with whitelist sync.
- Cross-officer sync audit and repair tools.

## Key Improvements In Current Build

- Unified guild-scoped sync framework with revision/hash/ACK tracking.
- Better stale snapshot handling and conflict damping.
- Guild bank ledger dedupe hardened with transaction IDs.
- Ledger sorting corrected to keep newest entries at top.
- Ledger time model aligned to practical gameplay needs:
  - Rough time for recent entries (within 24h).
  - Day-based age style for older entries.
- Adaptive debug routing:
  - Per-module debug toggles.
  - Optional chat output.
  - Buffered logs for quiet testing.

## Installation (Ascension / WoW 3.3.5a)

1. Close the game client.
2. Copy the addon folder into your client addons directory:
   - `World of Warcraft 3.3.5a/Interface/AddOns/MekTownRecruit`
3. Start the game and open character selection.
4. Click **AddOns** and verify **MekTown Recruit** is enabled.
5. Enter game and run:
   - `/mek help`
   - `/mek config`

## Quick Start

1. Open settings: `/mek config`
2. Validate guild identity: `/mtrid`
3. Check sync baseline: `/mek sync status`
4. Open member tools:
   - `/mek radar`
   - `/mek lfg`
5. Open vault tools:
   - `/mek chars`

## Core Commands

### General

- `/mek help`
- `/mek config`
- `/mek on` / `/mek off`
- `/mtrid`

### Debug (adaptive)

- `/mek debug on|off`
- `/mek debug chat on|off`
- `/mek debug module <name> on|off`
- `/mek debug status`
- `/mek ledgerdebug on|off|show|clear`

Suggested quiet ledger test mode:

```text
/mek debug on
/mek debug chat off
/mek debug module ledger on
```

### Sync Health

- `/mek sync status`
- `/mek sync verify`
- `/mek sync repair [dkp|guildtree|recruit|kick|inactivewl|gbank|ledger|all]`

### DKP

- `/mek dkp award <name> <points> [reason]`
- `/mek dkp deduct <name> <points> [reason]`
- `/mek dkp set <name> <points>` (GM only)
- `/mek dkp balance <name>`
- `/mek dkp standings`
- `/mek dkp publish [channel]`
- `/mek dkp snapshot`

### Attendance

- `/mek att start [zone]`
- `/mek att boss <count>`
- `/mek att check <name>`
- `/mek att end`

### Guild Utilities

- `/mek gads start|stop|now`
- `/mek inactive kick`
- `/mek inactive whitelist add <name>`
- `/mek inactive whitelist remove <name>`
- `/mek chars`
- `/mek radar`
- `/mek lfg`

## Permissions Model

Tabs are visible to all users, but actions are rank-gated.

- Officer/GM write actions:
  - Recruit write flows
  - DKP write flows
  - Loot/auction administration
  - Inactivity and kick actions
  - Guild Ads control
- Member-facing actions:
  - Group Radar
  - Vault/member views
  - Standings and utility reads

## Guild Bank Ledger Behavior

- Keeps a persistent, synced ledger beyond Blizzard's short tab-history limit.
- Deduplicates by internal transaction identity.
- Maintains newest-first list ordering.
- Uses practical timing presentation:
  - Recent items: rough within-day time.
  - Older items: day-based age text.

Note: Blizzard's legacy 3.3.5 API does not always provide exact absolute timestamps for every row. The addon uses best-available information and synchronized canonical timing to keep officer clients consistent.

## Project Layout

- `Core.lua` - shared runtime, db/profile helpers, debug controls.
- `GuildData.lua` - shared guild-scoped sync envelope helpers.
- `DKP.lua` - DKP balances/history/sync.
- `Recruit.lua` - recruit logging/sync.
- `Inactivity.lua` - inactivity tools + whitelist sync.
- `GuildTree.lua` - main/alt model + sync.
- `CharVault.lua` - vault snapshot + guild bank ledger/sync.
- `UI_Config.lua` / `UI_Member.lua` / `UI_CharVault.lua` - main UI.
- `Commands.lua` - slash command handlers.

## Compatibility

- Target client: WoW 3.3.5a
- Lua: 5.1
- Frame API: classic FrameXML / `CreateFrame`
- Ascension classless friendly (no retail-only APIs)

## QA Recommendations Before Release

- Use at least 2-3 guild clients (GM/officer/member).
- Run `/mek sync status` on each client after DKP, recruit, kick, and ledger activity.
- Validate guild bank ledger ordering after a fresh scan.
- Validate role-gated actions from a member account.

See also:

- `LAUNCHER_RELEASE_CHECKLIST.md`
- `RELEASE_NOTES_2.1.1_PRERELEASE.md`

## Credits

- MekTown Choppaz guild officers and testers.
- Ascension-focused UI and sync hardening contributors.
