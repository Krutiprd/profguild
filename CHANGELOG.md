# Changelog

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
