# MekTownRecruit v2.0.0-beta

Finalization pass for Ascension WoW 3.3.5a (Interface 30300).

## Included release fixes

- Simplified permission model.
  - Tabs remain visible to all users.
  - Only Recruit tools, DKP modification, and Inactivity / kick actions are officer / GM restricted.
- Fixed Group Radar launch actions.
  - Member panel and config panel Group Radar buttons now call `MTR.OpenGroupRadar()`.
  - LFG posting buttons now route through `MTR.OpenFindGroup()`.
- Hard-separated Recruit and Group Radar detection.
  - Recruit scanner now ignores `lfm`, `lfg`, and generic `looking for` group-finder traffic.
  - Group-finder traffic is reserved for Group Radar.
- Guild tab containment pass.
  - Fixed-width scroll content.
  - Left-aligned layout.
  - Clip-safe panel containment.
- Profile tab cleanup.
  - Scroll-safe fixed-width layout.
  - Removed broken rank/feature permission UI.
  - Replaced with simple access summary for release stability.
- Added shared tooltip helper and collapsible section helper for further UI cleanup.

## Runtime target

- Client: WoW 3.3.5a
- Lua: 5.1
- UI: FrameXML / CreateFrame
- Server target: Ascension (classless)

## Notes

This pass is intentionally surgical and keeps existing systems intact.
SavedVariables structure was not redesigned.


## Access model

- Officer / Guild Master only: Guild Ads, Recruit, DKP write actions, Loot / auction administration, and Inactivity / kick tools.
- Guild members: Group Radar, Vault, standings, and other utility/member-facing views via the member panel.
