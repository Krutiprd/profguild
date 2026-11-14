# Profguild

Guild profession directory for **World of Warcraft: Forever**. Every member running the addon
shares their professions, skill and known recipes with the guild over the hidden addon channel.
No server, no website, no setup. Everyone keeps a full copy, including members who are offline.

- Search recipes, items, professions or members: `/pg`
- "Crafted by" line in item tooltips (online crafters in green)
- Recipes are read once per profession; new recipes are added automatically when learned
- Dropped professions and former guild members disappear for everyone
- Members inactive for 30 days are hidden
- English and Slovak (`/pg lang sk`)

## Install

Copy the `Profguild` folder to `World of Warcraft\_forever_\Interface\AddOns\` (the `.toc` file must
be directly inside `AddOns\Profguild\`). Then open each of your professions once.

## Commands

| Command | What it does |
| --- | --- |
| `/pg` | Open or close the window |
| `/pg sync` | Ask the guild for updates |
| `/pg status` | Database size, guildmates seen, queue, traffic, last error |
| `/pg debug` | Print what the game API returns (saved to `ProfguildDB.debug`) |
| `/pg debug on` / `off` | Verbose logging in chat |
| `/pg lang en` / `sk` | Language |
| `/pg reset confirm` | Clear data received from guildmates and download it again |

## How sync works

Each character has one record `{ guid, name, class, account, version, time, professions }`.
Only the owner changes it and raises its version; everybody stores and forwards whole records.

| Message | Content | Sent |
| --- | --- | --- |
| `H` hello | guid → version of every record the sender holds | 15–25 s after login, every 15 min, `/pg sync` |
| `R` request | guids the sender is missing | after a hello that showed newer data |
| `D` data | one full record | after an own change, or as an answer |

Answers wait a random 1–4 s (the owner 0.3–0.8 s) and are cancelled when someone else sends the
same record first, so each record is usually sent once per need. Higher version always wins. If the
owner sees its own record with a higher version (lost SavedVariables, forged data), it jumps above it
and republishes. Nothing is sent in instances, in combat or from trial accounts; messages wait in a
queue and go out afterwards.

Messages are serialized with LibSerialize, compressed with LibDeflate and split by AceComm /
ChatThrottleLib into 255-byte parts within the game's limit (10 messages, then 1 per second per prefix).

## Development

```
lua5.1 tests/run.lua        # unit tests, simulated 20-member guild, full addon load in a fake client
tools/package.sh            # builds dist/Profguild-<version>.zip
```

| File | Role |
| --- | --- |
| `Store.lua` | Records, validation, versions, digests, pruning, search index (pure Lua) |
| `Sync.lua` | H/R/D protocol, duplicate suppression, queue (pure Lua, adapter-based) |
| `Scanner.lua` | Reads own professions, recipes and the guild roster from the game |
| `Comm.lua` | Encoding and the GUILD addon channel |
| `Core.lua` | Startup, events, slash commands, status and debug |
| `UI.lua`, `Tooltip.lua`, `Locale.lua` | Window, tooltip line, English/Slovak texts |

Libraries (bundled, see `Libs/VERSIONS.txt`): LibStub, CallbackHandler-1.0, AceComm-3.0 with
ChatThrottleLib, LibSerialize, LibDeflate. Each keeps its own license file.

## License

MIT, see `LICENSE`.
