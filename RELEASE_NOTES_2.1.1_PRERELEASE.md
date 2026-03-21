# MekTownRecruit 2.1.1 Pre-Release Notes

## Focus

This pre-release consolidates sync hardening and guild bank ledger stabilization for Ascension WoW 3.3.5a.

## Included Updates

- Guild bank ledger now keeps newest transactions at the top consistently.
- Ledger dedupe strengthened around internal transaction identity (`txid`) to reduce duplicate persistence.
- Ledger time handling aligned for practical readability:
  - Recent events show rough same-day time behavior.
  - Older events degrade to day-level age reporting.
- Guild bank scan flow updated to reduce UI takeover while still supporting controlled sweep behavior.
- Cross-domain sync logic kept aligned with revision/hash/ACK workflow.
- Adaptive debug routing added for quieter testing:
  - Master debug toggle
  - Chat on/off toggle
  - Module-level debug toggles

## Commands Useful In This Pre-Release

- `/mek sync status`
- `/mek sync verify`
- `/mek sync repair [dkp|guildtree|recruit|kick|inactivewl|gbank|ledger|all]`
- `/mek debug on|off`
- `/mek debug chat on|off`
- `/mek debug module ledger on|off`
- `/mek ledgerdebug show|clear|on|off`

## Notes

- Runtime target remains WoW 3.3.5a (`Interface: 30300`).
- Some legacy guild bank timestamp data is coarse from Blizzard APIs; addon normalization is used for stable cross-client display.
