# 0.3.0 – Guild price sharing (design)

Plan agreed with the user in the doc "Profguild – stav a plán 0.3.0". The user asked to build it
and decide open points alone; decisions taken here are marked *(call)*.

## Intent

When one guildmate refreshes auction prices (the AKTUALIZOVAŤ CENY button or a full scan), the
whole guild gets those prices. The newer price always wins. Prices are only the items Profguild
needs (reagents, crafted items, recipe items), not Auctionator's whole database.

Non-goals: writing into Auctionator, sharing price history, cross-faction prices.
Anti-goal: an old price (this morning's scan) overwriting a guildmate's newer one.

## What Auctionator offers (checked in its source)

- Prices are kept per day only (`l`/`h`/`a` keyed by scan day, `m` = last minimum price); there is
  no time of day per item. `GetAuctionAgeByItemID` returns whole days.
- `SavedState.TimeOfLastGetAllScan` is the start of the last full scan (internal, not API).
- `API.v1.RegisterForDBUpdate(caller, fn)` calls `fn` after every search result
  (`Search.Events.PricesProcessed`) and after a full scan (`FullScan.Events.ScanComplete`).

So Profguild stamps its own time: *(call)* an item gets the current server time when Profguild
sees its Auctionator value change, or when Profguild itself searched it, or right after a full
scan when Auctionator saw it today.

## Data

`ProfguildDB.guilds[guild].prices[itemID] = { p = copper, n = pieces, t = server time, w = guid }`.
`ProfguildDB.guilds[guild].ahSnap[itemID] = "price:pieces:day"` – the last Auctionator value seen,
to tell a change from an old value. At login the snapshot is refreshed without stamping, so data
from earlier sessions is never announced as new.

Limits: price 1c–999 999g, pieces 0–100 000, time not older than 30 days and at most 1 h ahead
of our server time, 5 000 entries; entries older than 14 days are dropped at login.

## Messages (GUILD channel, protocol 1 of the price module)

- `PU { t="PU", pv, s, i = { id, p, n, t, id, p, n, t, ... } }` – up to 100 items. Sent after a
  harvest stamped items (in parts, 1 per second) and as the answer to a request.
- `PD { t="PD", pv, s, m = newest time held, c = entries }` – after every hello.
- `PR { t="PR", pv, s, to = guid, since = our newest time }` – to the holder of a digest newer
  than ours. Only `to` answers, with every entry newer than `since`; everybody who hears the PU
  merges it, so one answer serves all. A request seen for the same holder with `since` ≤ ours
  replaces our own; a holder answers one holder-request at most every 60 s *(call)*.

Merge: an incoming entry replaces ours only when its `t` is newer.

## Use

`Prices.Get` returns the newer of Auctionator's price (time = own stamp if it matches, else the
start of the day of its age) and the guild price. The extra returns say who and when. The
details show the source: "od Ana, pred 2 h" in the value line and in the reagent tooltip.
`/pg status` shows the count, the newest price and message counts.

## Approaches considered

1. **Own stamps from Auctionator changes (chosen).** Exact enough, no Auctionator internals.
2. Use `TimeOfLastGetAllScan` for everything seen today: wrong for single searches, internal.
3. Send Auctionator's day only: two prices of the same day cannot be ordered.

## Left to the builder

Message pacing details, debounce times, the exact UI wording.

## Revision after review round 1

Round 1 found that stamping from change detection and Auctionator's days was unreliable (UTC
vs. local days, items without auctions, searched items stamped before their result arrived) and
that a newest-time digest loses a backlog. Changes:

- **Readings from `Database:ProcessScan`** (hooksecurefunc): every search and full scan passes
  `{ [dbKey] = { { price, available }, ... } }`; Profguild takes the lowest price and the sum of
  pieces (as Auctionator does) for plain item keys of wanted items and records them with the time
  now. No snapshot, no day maths for sending. `localTime` (when our own Auctionator price was
  read) is `SCAN_DAY_0 + newest day * 86400`.
- **Complete time** (`pricesComplete`): advanced by the last part of an answer (`r`, `m`, `e`)
  to a request from no later than it; after that, in the same session, also by live updates and
  own readings (in sync). Digests newer than it trigger a request `since = complete`.
- **Answering digest** for a newcomer's older digest (as Catalog), `DIGEST_GAP` 600 s.
- **Limits**: only wanted items are stored; when full the oldest entry is evicted; one answer per
  asker per 10 min; a stopped object (guild change) sends nothing.

## Revision after review round 2

The "complete time" could move past prices a client never got (an answer from a holder that was
not complete itself, only the last parts of an answer heard, prices dropped by the interest
filter). Replaced by anti-entropy over day buckets:

- `PD { b = { day, count, sum, ... } }` for the days of the last 14 days; sum over
  `itemID * 7 + t + p` mod 2^31-1.
- A receiver asks the sender (`PR { to, d = { day, ... } }`) for every day where the sender has
  prices and the bucket differs from its own; the holder answers with all its prices of those
  days (newest first, one answer a minute, days of several askers merged). A request heard for
  the same holder removes those days from ours. A receiver that holds a differing or missing day
  sends its own digest (at most every 10 min), so the exchange runs both ways.
- Every valid price is stored (no interest filter), equal times resolve to the lower price, so
  all tables can become equal; MAX_AHEAD 120 s. Losses heal at the next digest.
- Tests: three clients reading while the others are offline, a lost part plus a half-heard
  answer, blocked sends, exchange in both directions, 20 clients settling (traffic bound).

## Revision after review round 3

- Eviction by one total order (newer first, then the lower item ID): a new price that would rank
  below the lowest held is rejected, so full tables keep the same prices and stop differing.
  The same order inside MAX_PER_FINDER (3000 prices read by one guildmate).
- Answers: one at a time; the cooldown starts when the last part left; a day answered within
  ANSWER_SKIP (10 min) whose bucket did not change is not sent again.
- Requests: keyed by the holder's (count, sum) of the day; the same key is asked once per
  ASK_SAME_AGAIN (5 min) by anybody in the guild (a heard PR counts).
- Bucket sum over a mixed per-entry hash, so differences cannot cancel out.
- Simulated (800 B/s per sender, latency): a 3000-item full scan in a guild of 30 costs about
  3x the scan; a newcomer with a 3-day-old table about 2x; full tables converge; one request a
  minute keeps at most one answer in flight.
