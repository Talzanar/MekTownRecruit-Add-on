# MekTown Recruit

> **⚠️ Updated March 2026** — This release includes sync fixes, UI improvements, and a comprehensive test suite.

<img width="500" alt="MTR Cover" src="https://github.com/user-attachments/assets/b835e5d3-df79-450f-a4fb-2234559eb538" />

The ultimate utility and guild management tool, originally built for MekTown Choppaz on WoW Ascension (Area 52). I designed this addon to make running a massive, active guild a bit easier for everyone.

MekTown Recruit packs all the core guild operations—recruiting, DKP tracking, attendance, guild bank ledgers, and group-finder tools—into one unified addon. Instead of wrestling with a dozen different addons and Google Sheets, officers and members can see everything in one place.

<img width="1024" height="1536" alt="MTR UI" src="https://github.com/user-attachments/assets/814b659b-cc70-4102-91fd-6709ab58a32b" />

## Support the Project

I built this project entirely solo to help the Ascension community manage their guilds better. If you love using MekTown Recruit and want to support my work, you can buy me a coffee here:

**[Donate via PayPal](https://paypal.me/talzanar)**

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
- **Peer-to-Peer Sync:** The addon silently syncs data (DKP, recruits, bank ledgers) between online officers to keep everyone's records identical.

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

The addon uses a strict two-tier permission model:

- **Officers / Guild Masters:** Full access to everything including DKP writes, inactivity tools, and sync controls.
- **Regular Members:** Can view DKP standings, use the group radar, and access the character vault—but cannot modify guild data.

The permission check runs on every action. Even if a regular member somehow triggers an officer-only command, it's silently ignored.
