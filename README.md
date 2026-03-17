# MekTown Recruit — Guild Suite

> **v2.0.0-beta** · WoW Ascension · Area 52 Free-Pick · Interface `30300` (WotLK 3.3.5a client, TBC content)

The complete guild operations toolkit for Ascension guilds. Originally built for **MekTown Choppa'z**, now updated to be more portable and configurable for broader guild use. One addon covering recruitment, DKP, loot distribution, character vaulting, inactivity management, guild bank, group radar, and more — with synchronized officer data, custom permission controls, and a significantly improved UI containment pass.

---

## Overview

MekTown Recruit is a full guild management suite written in Lua 5.1 for the WoW 3.3.5a client on Ascension private server. It provides officer tools covering the full guild lifecycle: recruit detection, automated invites and messaging, DKP distribution, loot handling, inactivity control, guild bank tracking, character vaulting, and group radar.

All data is stored in a single account-wide `SavedVariable` (`MekTownRecruitDB`). Profile settings are separated cleanly from account-wide systems such as the character vault and guild bank. The addon supports synchronized officer workflows and a role-based permission model:

- **Guild Master** always has full access
- **Officer access** is configurable by the Guild Master using the guild’s live rank names
- **Regular members** see a restricted member panel with only their own relevant information

Recent updates also introduced:
- a custom guild bank ledger system
- portable officer-rank assignment for any guild structure
- stronger UI containment so data no longer bleeds outside addon panels
- safer manual-only ledger scanning to avoid hijacking the guild bank UI

## Requirements

- WoW client: **3.3.5a**
- Server: **Ascension — Area 52 Free-Pick**
- Interface: **30300**
- Lua: **5.1**
- Required texture: `MTCWallpaper.tga`

## Installation

1. Download the latest release ZIP.
2. Extract `MekTownRecruit` into your `Interface/AddOns/` folder.
3. Verify this path exists:

```text
WoW/Interface/AddOns/MekTownRecruit/MekTownRecruit.toc
```

4. Launch the game and use `/mek config`.

## Core Systems

- Recruitment scanner and whisper automation
- Guild auto-invite and guild messaging tools
- DKP ledger, standings, and officer actions
- Auction and roll loot systems
- Attendance tracking and boss kill awards
- Inactivity scan, whitelist, safe ranks, and kick logging
- Character vault with item, gear, gold, and profession tracking
- Guild bank snapshot + extended ledger tooling
- Group Radar for LFG/LFM detection and posting
- Guild Tree main/alt management

## Permission Model

- **Guild Master (rank index 0)** always has full access
- **Officer-access ranks** are assigned by the Guild Master from the live guild rank list
- **Members** fall back to the member-only panel

## Tech Stack

- **Language:** Lua 5.1
- **Runtime:** WoW 3.3.5a client (single-threaded, event-driven)
- **UI:** FrameXML / `CreateFrame` / Blizzard templates
- **Persistence:** `SavedVariables` via `MekTownRecruitDB`
- **Communication:** `SendAddonMessage`, `SendChatMessage`
- **Scheduling:** addon-local `OnUpdate` scheduler via `MTR.TickAdd()` and `MTR.After()`

## Architecture Notes

- Modular subsystem layout under the global `MekTownRecruit` namespace (`MTR`)
- Single scheduler for timed work
- Profile-based configuration with account-wide vault/bank data
- Scroll-contained UI for large data sets
- Defensive handling for Ascension/Wrath API limitations

## Recent Changes in v2.0.0-beta

- Guild bank ledger retention fixed for missing/invalid Ascension timestamps
- Ledger date display improved with relative-age fallback
- Ledger no longer hijacks guild bank inventory usage during passive bank interaction
- Profile officer-rank assignment updated for large guild rank lists with capped scrolling
- Permission system generalized so the GM assigns officer-access ranks using live rank names
- UI containment pass added to prevent panels from flowing outside addon bounds
- Debug output centralized behind an explicit enable toggle
- Release packaging cleaned up to a single `README.md`

## Known Constraints

- No `C_Timer` on this client; use the addon scheduler
- No `table.unpack`; use `unpack()`
- CheckButtons return `nil` when unchecked; coerce to explicit booleans
- Some Ascension guild bank APIs provide incomplete timestamps; ledger falls back to capture-age display

## Commands

Examples:

```text
/mek config
/mek chars
/mek radar
/mek dkp standings
/mek inactive scan
/mek gads start
```

## License

This addon targets Ascension private server (`Interface 30300`) and was originally developed for MekTown Choppa'z. Adjust repository licensing terms as needed for your public release.
