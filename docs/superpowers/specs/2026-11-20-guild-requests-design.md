# 0.4.0 – Guild item requests (design)

Approved by the user on 2026-11-20 (in Slovak, in chat).

## Intent

A guildmate asks the guild for something to be crafted; another one takes it and crafts it. The
guild charges no fees inside, so a request only shows an estimate of the reagent cost. The user
wants it before testing 0.3.0 with the guild.

Non-goals: payments, bidding, choosing between volunteers, mail or trade automation.

## Behaviour (decided with the user)

- **Create:** a button "Požiadať guildu" in the recipe details opens a small box: count and a
  short note. Works for any recipe of the catalog, also one nobody in the guild knows.
- **View "Požiadavky"** next to Recipes / Leveling / Members: list of item, count, requester,
  state, crafter; details with reagents, the estimated reagent cost and who knows the recipe.
- **States:** open → taken → done; cancelled.
  - Open: anybody except the requester takes it ("Vyrobím to"). **The first one wins**; when two
    take it at the same time, the earlier take wins on every client.
  - Taken: the crafter gives it back ("Vzdať sa") → open; the requester or the crafter marks it
    done ("Hotovo").
  - The requester cancels it at any time. Nobody else changes a request.
- **Chat notices:** the requester when somebody takes the request; a player who knows the recipe
  when a new request for it arrives.
- **Limits:** 20 open requests per player (user asked why 5; small guild), 200 in the guild. Open
  requests disappear after 7 days, done and cancelled ones after 2 days.

## Sync (my call)

Requests are few, so the digest lists every request as id + time of its last change. A client
asks the sender for the requests it lacks or holds older; the answer carries whole records;
everybody who hears it merges. A client that holds something newer or missing from a digest
answers with its own digest (rate-limited), as in GuildPrices. Offline players get them on login.

Merge of two versions of the same request: the version with the later change wins, except for
takes: of two takes of the same open request the earlier take wins. Only valid transitions by the
allowed player are accepted (requester / crafter checked against the record's guids; the sender
of a message is not proven, as in the rest of Profguild).

## Left to the builder

Message formats and limits, pacing, the exact UI layout and wording, notices throttling.
