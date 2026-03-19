MekTownRecruit v2.0.0-beta

This beta focuses on stability, cleaner access control, scalable guild tools, and release readiness for Ascension WoW 3.3.5a.


Installation guide - 
-Press the green CODE button and download .zip
-Extract the contents of that file and change the folder name to MektownRecruit and place inside interface/addons folder
-Reload game & Enjoy

Highlights
- Standardized settings persistence for critical Guild tab controls
- Simplified sync identity to guild key only: realm|guildName
- Cleaned member vs officer access model
- Reworked Guild Tree into a more scalable readable layout
- Fixed Guild Bank sync/render regressions
- Removed dead/conflicting UI routes and improved overall polish

Access model
- Officer / GM only:
  - Recruit and Guild Ads admin tools
  - DKP modification
  - Loot / auction admin actions
  - Inactivity / kick actions
  - Guild Tree management actions
- Member accessible:
  - Group Radar
  - LFG posting
  - Radar settings
  - Vault
  - Guild Tree view
  - DKP/standings read access
  - Roll tool access for group/raid use

UI / UX
- Member Panel cleaned up and relabeled for clarity
- Home navigation now reflects actual purpose
- Group Radar entry points corrected
- Guild tab rebuilt around a cleaner save path
- Guild Tree redesigned for better readability and filtering
- Rank filtering now uses available space properly
- Large-panel flow and general usability improved

Persistence / Config
- Critical Guild settings now persist correctly across reloads
- Direct profile save path used for important Guild tab controls
- Reduced conflicting save logic in problem areas
- Save behavior improved for release workflow

Sync / Data Scope
- Shared addon data now uses guild-key scoping
- Identity simplified to realm + guild name
- Intended to prevent unrelated guild/community data mixing
- Guild Bank sync path corrected

Guild Tree
- Reworked to a scalable tree-oriented layout
- Better rank filtering
- Better space usage
- Right-click support groundwork added for main/alt actions
- View remains member-safe, management stays officer/GM only

Notes
- Guild identity now relies on guild key instead of a separate generated guild ID
- This was chosen for stability and simpler real-world debugging on Ascension 3.3.5a
