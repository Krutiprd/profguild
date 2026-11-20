# Bug reports relayed through the guild (0.5.0)

## Why
Guildmates test Profguild. When something is wrong they press the bug button (0.2.2), but the
report stays in their own SavedVariables. The author wants the reports in his own addon,
without asking anybody to send files.

## What
- A report saved with the button or `/pg bug <text>` is also handed to the guild, when one of the
  receivers is a member of the guild.
- Receivers: the author's characters, fixed in the code (`Reports.RECEIVERS`, name + realm):
  Krutiprd, Miestny, Bubliprd, Zlatan (Whychuck), Fiona (Vajcak), Bubli (Prd). Later it may become
  the guild master and officers.
- Store and forward: every guildmate with Profguild keeps the reports it heard (it does not show
  them) and hands them on, so a report reaches the receiver even when the reporter and the
  receiver are never online together.
- The receiver gets the report in an inbox (`ProfguildDB.inbox`, account-wide, so every receiver
  character sees it), a chat notice, `/pg bug inbox` lists the newest ones.
- When a receiver has a report, it is marked delivered; the mark spreads, holders drop the text,
  and the reporter gets a chat notice that the report was delivered.
- Non-goals: no reply to the reporter, no automatic sending of Lua errors without a report (the
  newest errors are part of every report already), no window for the inbox (chat + file).
- Anti-goal: other guilds that installed the addon from CurseForge must not carry reports around
  for nobody: without a receiver in the roster nothing is shared.

## Approaches
1. Whisper to the receiver when both are online; queue at the reporter otherwise. Simple, but a
   report may wait for days.
2. **Store and forward through the guild (chosen by the user)**: the same anti-entropy as item
   requests (`Requests.lua`), much simpler because a report never changes: a record is either
   held (with its text) or delivered (a tombstone without text).

## Design
- New module `Reports.lua`, object per guild like `Requests` (adapter: send, canSend, now, clock,
  after, random, myGuid, isReceiver, onChanged). Saved in `guildDB.reports`.
- Shared report: `{ id = reporterGuid .. ":" .. n, by, who, t, v, text, ctx, errors, log }`, every
  field limited (text 1000 letters, ctx 20 lines, errors 5 with stack 600, log 15 lines, line 200
  characters). Only the known fields are kept (`clean`).
- State per id: `h` (held, with the report) or `d` (delivered, no text, keeps `t` and `d` time).
  Delivered beats held. Records go 14 days after `t` (both kinds).
- Limits: 60 records held per guild, 10 per reporter; the oldest go first; tombstones are cheap
  and are not counted against the reporters.
- Messages (GUILD): `BU {q = {report}}` (at most 2 per message, the text is the bulk),
  `BD {x = {id, state, ...}}` digest after every hello, `BR {to, ids}` asks a holder. Same rules
  as requests: one answer at a time, ANSWER_COOLDOWN 30, ASK_AGAIN 60, an answering digest at most
  every 60 s.
- A receiver that hears a report (or writes one) copies it to the inbox and marks it delivered
  locally; its next digest spreads the mark. Marks from anybody are accepted (the sender of a
  message is not proven anywhere in Profguild; the cost is a report not delivered).
- Reporter: `ProfguildDB.bugs[i].shared = id`, `delivered = time` when the mark arrives (chat
  notice once).
- Gate: the guild roster (GetGuildRosterInfo names) contains a receiver; checked when sharing a
  report and when answering. Our own state is held regardless, a later roster with a receiver
  sends it.
- `/pg status` line: reports held / delivered, traffic. `/pg bug inbox [clear confirm]`.

## Left to the builder
Exact message pacing, notice texts (EN + SK), test layout.
