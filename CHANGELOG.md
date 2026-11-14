# Changelog

## Unreleased

- Self-heal keeps data: an owner who lost SavedVariables (or plays from a second PC) takes over
  the recipes of not yet rescanned professions from the guild's copy instead of overwriting it.
  A hello that shows a newer own version first asks for that copy (republishes without it after
  20 s). Holders that see the owner announce a version they hold with different content send
  their copy back, so the collision is no longer hidden when both sides count from 1.
- Former guild members are pruned by name when the roster has no GUIDs, but only when the own
  character is found in the roster under the same name form.
- Update debounce only moves a pending update earlier: steady skill-ups no longer postpone it
  forever and no longer hold back a learned recipe.
- Whisper and item link fall back to `ChatFrameUtil` and to opening the chat box; if nothing
  works, the chat says what to type.
- `/pg debug` runs each section protected: an API that errors is reported and the rest is still
  printed and saved. Also reports the chat functions and the roster's last-online data.
- Test runner fails when a test file does not compile instead of skipping it.
- A hello that claims an impossible version of our own record (fractional, above the maximum)
  no longer pushes our version out of the valid range, which stopped the character from
  publishing for good. Such versions are dropped from every hello, the own version is capped at
  the maximum, and a saved version that is already out of range is repaired at the next snapshot.
- Names received from guildmates are stripped of UI escape sequences (`|`) and control
  characters; a class that is not a plain class file name is dropped.
- Roster without GUIDs: online state and the 30-day rule now match names in normalized form,
  so a realm suffix in the roster no longer hides the match.

## 0.1.0 – 2026-11-14

First version for WoW Forever (Interface 16001).

- Own professions and skill read at login; recipes read when a profession window is opened and
  added automatically on `NEW_RECIPE_LEARNED`.
- Peer-to-peer guild sync (hello / request / data) with versioned records, relaying of offline
  members, duplicate suppression, owner self-heal and a queue while sending is blocked.
- Dropped professions removed after two consistent snapshots; former guild members pruned when the
  roster is complete; members offline for 30 days hidden.
- Window with search, Recipes and Members views, online filter, whisper and link on click.
- "Crafted by" line in item tooltips.
- English and Slovak texts; `/pg status` and `/pg debug` diagnostics.
