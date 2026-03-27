# MekTown Recruit

The official guild suite for MekTown Choppaz on WoW Ascension (Area 52), designed to make running a massive, active guild a bit easier for everyone.

MekTown Recruit packs all our core guild operations—recruiting, DKP tracking, attendance, guild bank ledgers, and group-finder tools—into one unified addon. Instead of wrestling with a dozen different addons and Google Sheets, officers and members can see everything in one place.

<img width="1024" height="1536" alt="MTR" src="https://github.com/user-attachments/assets/814b659b-cc70-4102-91fd-6709ab58a32b" />

## Addon Info

- **Current Version:** `2.1.1`
- **Target Client:** `30300` (WoW 3.3.5a)
- **SavedVariables:** `MekTownRecruitDB`

## Features

- **Recruit Scanner:** Automatically spots and invites players looking for a guild based on keyword matching, with built-in welcome whispers.
- **DKP System:** Full ledger for awarding, deducting, and syncing DKP. Includes an in-game auctioneer and roll tracker.
- **Attendance Tracking:** Easily snapshot raid attendance and boss kills.
- **Guild Tree:** Maps alts to mains so everyone knows who is who.
- **Member Tools:** Group Radar and LFG helpers to make finding dungeon and raid groups painless.
- **Character Vault & Guild Bank Ledger:** A persistent, searchable history of guild bank items and gold that goes way past Blizzard's short default log limit.
- **Inactivity Management:** Tracks inactive players and syncs a safe whitelist across all officers.
- **Peer-to-Peer Sync:** The addon silently syncs data (DKP, recruits, bank ledgers) between all guild members to keep everyone's records identical.

## Installation

Since we're on a 3.3.5a client (Ascension), you install this exactly like any classic addon:

1. Close your game client.
2. Download and drop the `MekTownRecruit` folder directly into your client's AddOns directory:
   `World of Warcraft/Interface/AddOns/MekTownRecruit`
3. Launch the game, click **AddOns** at the character select screen, and make sure **MekTown Recruit** is checked.
4. Once in-game, type `/mek config` to open the main window.

## Getting Started

1. **Check Settings:** Type `/mek config` and look through the options.
2. **Verify Sync:** Type `/mek sync status` to ensure your addon is talking to other guild members.
3. **Check the Vault:** Type `/mek chars` to view your character vault and the guild bank ledger.
4. **Find a Group:** Type `/mek radar` or `/mek lfg` to open the member-facing group tools.

## Command Reference

### General
- `/mek help` - Shows all available commands.
- `/mek config` - Opens the main UI.
- `/mek on` / `/mek off` - Toggles the main recruiting scanner.
- `/mtrid` - Shows your current guild identity mapping.

### DKP & Raiding
- `/mek dkp standings` - View current DKP balances.
- `/mek dkp balance <name>` - Check a specific player.
- `/mek att start [zone]` - Begin attendance tracking.
- `/mek att end` - End tracking.

### Utilities
- `/mek chars` - Open Character Vault.
- `/mek radar` - Open Group Radar.
- `/mek lfg` - Post LFG.

### Officer Commands (Restricted)
- `/mek dkp award <name> <points> [reason]`
- `/mek dkp deduct <name> <points> [reason]`
- `/mek dkp set <name> <points>` (GM only)
- `/mek dkp snapshot`
- `/mek inactive kick`
- `/mek inactive whitelist add/remove <name>`
- `/mek sync repair all` - Force a manual sync request to other officers.

## How Permissions Work

We built this so tabs are visible to everyone, but buttons that actually change guild data are restricted.

**Officers & Guild Master:**
Can use the Recruit scanner, modify DKP, run Loot/Auctions, perform inactivity kicks, and manually force sync repairs.

**Members:**
Can view the Guild Tree, DKP Standings, Character Vault, Guild Bank Ledger, and use the Group Radar / LFG tools freely.

## The Guild Bank Ledger

Because the default 3.3.5 bank log is notoriously short and easily wiped, our addon keeps a permanent, synced ledger of both items and gold.

- It deduplicates transactions automatically so multiple officers scanning doesn't create duplicate entries.
- It displays exact dates when the game provides them, and smartly calculates "days ago" when it doesn't.
- Gold logs are tracked natively, with a fallback that watches the bank balance directly if the realm's money API bugs out.

## Under the Hood

The codebase is built strictly for the 3.3.5a engine limits. We don't use retail `C_Timer` mixins, and all heavy sync operations are chunked to respect legacy 255-byte chat limits.

```text
MekTownRecruit/
├── Core.lua         (Init, settings, utilities)
├── GuildData.lua    (Guild identity, sync primitives)
├── DKP.lua          (DKP system & sync)
├── Recruit.lua      (Scanner & invites)
├── GuildTree.lua    (Alt/main tracking)
├── CharVault.lua    (Character vault & bank ledger)
├── GroupRadar.lua   (LFG tools)
├── Attendance.lua   (Raid tracking)
├── Inactivity.lua   (Kick whitelist)
├── Commands.lua     (Slash router)
└── UI_*.lua         (Interface panels)
```

## Credits

Massive thanks to the MekTown Choppaz guild officers and testers for breaking this repeatedly until it worked, and to the Ascension UI dev community for the 3.3.5a workarounds.

*FOR GORK N MORK!*
