# Probe result (NpcProbe, live WoW Forever client, 2026-11-26)

Log: `WTF/Account/<account>/SavedVariables/NpcProbe.lua` of the user's Horde character (Thunder Bluff). Visits:
Alchemy trainer Bena Winterhoof twice with a relog between, Mani Winterhoof (vials) twice, Kray (trainer, 0 services),
Nata Dawnstrider (enchanting supplies with recipes). Not visited yet: trainer with all filters on, vendor with another
currency, limited-stock recipe, two reputations, `/npcprobe pin`.

## Gate: NPC ID — passed

`UnitGUID("npc")` gives `Creature-0-<server>-1-<zone instance>-<npcID>-<spawn>`:

```
Creature-0-55165-1-15571149-3009-DB04E5BC4A   Bena Winterhoof, before relog
Creature-0-14234-1-8751246-3009-EA3BC7AD78    Bena Winterhoof, after relog
Creature-0-14179-1-5712002-3010-69680F65EA    Mani Winterhoof
Creature-0-21094-1-8674439-3010-C36EC7115E    Mani Winterhoof, later
```

The sixth field (3009, 3010) is stable; server, instance and spawn change. Only `Creature` GUIDs are used.

## Trainer

- `IsTradeskillTrainer()` true. Globals present: `GetNumTrainerServices`, `GetTrainerServiceInfo`, `GetTrainerServiceSkillReq`,
  `GetTrainerServiceCost`, `GetTrainerServiceItemLink`, `GetTrainerServiceTypeFilter`, `GetTrainerServiceSkillLine`,
  `GetTrainerServiceLevelReq`, `GetTrainerServiceDescription`, `GetTrainerServiceIcon`, `C_Trainer.GetTrainerType`.
- At TRAINER_SHOW `GetNumTrainerServices()` is 0; at TRAINER_UPDATE (same moment) and 0.5 s later it is filled.
- One service, raw:
  - `GetTrainerServiceInfo(i)` = `"Elixir of Fire Power", "available", 134835, 0, "" (nil at the event), "Elixirs"` (6th: the category).
  - `GetTrainerServiceSkillReq(i)` = `"Alchemy", 140, true`.
  - `GetTrainerServiceCost(i)` = `2700` (copper).
  - `GetTrainerServiceItemLink(i)` = the crafted item's link (`item:6373`), nil at the event, filled 0.5 s later. No spell ID of the service.
- Filters as the player had them: available true, unavailable false, used false — so only 1 service was listed. With the default
  filters a reading holds only what the reader can learn now; others are seen when somebody has other filters or skill.
- Kray (another trainer) listed 0 services: an empty reading must make no sheet.

## Merchant

- `GetMerchantItemInfo` is missing; `C_MerchantFrame.GetItemInfo(i)` works and returns a table
  `{ name (sometimes absent), price, stackCount, numAvailable (-1 unlimited, 2-3 limited), isPurchasable, isUsable, hasExtendedCost, texture }`.
- `GetMerchantItemID(i)` gives the item ID; `GetMerchantItemLink(i)` is sometimes empty at the event.
- `GetItemInfoInstant(id)` gives class name `"Recipe"` and subclass name (`"Enchanting"`, `"Tailoring"`), plus class and subclass IDs.
- Extended cost: none seen (`hasExtendedCost` false, `GetMerchantItemCostInfo` 0). Other currencies still unverified.
- `GetMerchantFilter()` = 2 at both vendors.
- Example recipe rows (Nata Dawnstrider, npc 3012): items 6377, 6349, 20758, 20752, 20753, 6342 (Enchanting) and 22307 (Tailoring),
  prices 900 / 450 / 450 / 2700 / 3600 / 270 / 5400 copper, all unlimited.

## Place

`C_Map.GetBestMapForUnit("player")` = 1456 (Thunder Bluff); `C_Map.GetPlayerMapPosition` gives fractions 0-1
(0.473, 0.339). Stored as whole percent per the design.

## Names of recipe spells

`C_Spell.GetSpellName` exists. 14 of 2501 Data.lua spells have no name at login and still none 60 s later:
2330, 2337, 3447, 6619, 7181, 11457, 17556, 22434, 1277779-1277784. They are left out of name matching.

## Open (not visited yet)

Map pin APIs (`/npcprobe pin`), vendor with another currency, limited-stock recipe, reputation price, trainer with all filters.
The reader's code for these follows the design; its tests use guessed mocks until a later visit.
