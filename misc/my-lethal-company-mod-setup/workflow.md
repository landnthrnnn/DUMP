# Lethal Company Sync Workflow

## Big Picture

The setup has 2 layers:

1. **Thunderstore profile code**
   - Handles installed mods
   - Exact mod versions
   - Enabled / disabled states

2. **Git passover**
   - Handles configs
   - Custom files/assets
   - Deleted/replaced mod files
   - Terminal videos
   - TooManyEmotes save data
   - Other manual/custom setup changes

---

# Landon Workflow

## Normal Config / Custom File Changes

1. Make and test changes in my live `Default-extras` profile.
2. Run:

   `landn-tools\update-n-passover.bat`

3. It:
   - Compares the live profile against the passover
   - Detects config/custom changes
   - Updates the passover
   - Updates `profile-configs-n-customs.json`
   - Rebuilds `payload-sha256.txt`
   - Detects any other changes anywhere inside `my-lethal-company-mod-setup`
   - Lets me commit + push everything to GitHub

4. Tell Carter to run:
   - `pull-in.bat`
   - then `update.bat`

---

## When Mods Are Updated / Added / Removed

1. Make the Thunderstore changes on my setup first.
2. Run:

   `landn-tools\mod-update-checker.bat`

3. Use:
   - **Scan for mod/config changes**
   - Review anything that changed/reset
   - Fix configs if needed

4. Test the game.

5. Run:

   `landn-tools\update-n-passover.bat`

6. Push the finalized setup.

7. Update the mod-update-checker baseline once the new setup is confirmed good.

8. Give Carter a fresh Thunderstore profile code if the actual mod list/version/enabled state changed.

---

# Carter - First Time Setup

1. Import my current Thunderstore profile code so his `Default-extras` has the same:
   - Mods
   - Versions
   - Enabled / disabled states

2. Give Carter:

   `carter-tools\initial-setup.bat`

   and:

   `carter-tools\scripts\initial-setup.ps1`

3. Carter runs:

   `initial-setup.bat`

4. This creates his local sparse Git checkout containing the sync project.

5. Carter then runs:

   `pull-in.bat`

6. Then:

   `update.bat`

7. `update.bat` verifies his Thunderstore mod state matches mine before applying the passover.

---

# Carter - Future Updates

Whenever I tell Carter there is an update:

1. Run:

   `pull-in.bat`

   This pulls the newest `my-lethal-company-mod-setup` from GitHub.

2. Run:

   `update.bat`

   This applies the latest configs/custom files to his `Default-extras` profile.

If Carter has manually changed files inside his local sync repo, `pull-in.ps1` stops instead of silently overwriting/merging them.

---

# File Overview

## Landon Tools

- `landn-tools\update-n-passover.bat`
  - Launcher for the main Landon sync/update script.

- `landn-tools\scripts\update-n-passover.ps1`
  - Main Landon updater.
  - Compares the live profile to the passover.
  - Updates approved passover content.
  - Updates package state.
  - Rebuilds hashes.
  - Detects any Git changes inside the entire project.
  - Commits and pushes approved changes.

- `landn-tools\mod-update-checker.bat`
  - Launcher for the mod/config update checker.

- `landn-tools\scripts\mod-update-checker.ps1`
  - Tracks mod versions, enabled states, and config changes after Thunderstore updates.

- `landn-tools\data\mod-update-state.json`
  - Baseline used by the mod update checker.

- `landn-tools\data\mod-update-report.md`
  - Generated when config changes are detected.

- `landn-tools\data\mod-index.md`
  - Optional exported readable mod inventory.

---

## Carter Tools

- `carter-tools\initial-setup.bat`
  - Carter's one-time setup launcher.

- `carter-tools\scripts\initial-setup.ps1`
  - Creates Carter's sparse Git checkout and verifies required sync files exist.

- `carter-tools\pull-in.bat`
  - Launcher for pulling my latest GitHub changes.

- `carter-tools\scripts\pull-in.ps1`
  - Pulls the latest project from GitHub.
  - Refuses to pull if Carter has local project edits.

- `carter-tools\update.bat`
  - Launcher for applying the latest passover.

- `carter-tools\scripts\update.ps1`
  - Verifies Carter's Thunderstore package state.
  - Verifies passover hashes.
  - Applies configs/custom files.
  - Post-verifies the result.

---

# Passover Files

- `passover\profile-configs-n-customs.json`
  - Snapshot of my Thunderstore package state.
  - Contains all mods, exact versions, and enabled/disabled states.
  - Carter must match this before `update.ps1` applies anything.

- `passover\destination-map.json`
  - Permanent mapping rules telling Carter's updater where passover content belongs.

- `passover\payload-sha256.txt`
  - SHA-256 manifest for everything inside the passover.
  - Used to verify files are intact before Carter applies them.

- `passover\profile\`
  - Files that directly map into the Thunderstore profile.
  - Includes configs, custom songs, PizzaTower escape files, Kouky custom sounds, etc.

- `passover\shared\terminal-videos\`
  - Single master copy of terminal videos.
  - Applied to both terminal-video mod locations.

- `passover\external\TooManyEmotes_LocalSaveData`
  - TooManyEmotes save/favorites data stored outside the Thunderstore profile.

---

# Other

- `.gitattributes`
  - Prevents Git from modifying passover files through text normalization.

---

# Simple Rule To Remember

### Me
**Change/Test → `update-n-passover.bat` → Push**

### Carter
**Profile code if mods changed → `pull-in.bat` → `update.bat`**

### After mod updates
**Update mods → `mod-update-checker.bat` → fix/test → `update-n-passover.bat` → update baseline**