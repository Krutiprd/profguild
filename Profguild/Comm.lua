-- Profguild: Comm
-- Connects Sync to the GUILD addon channel: LibSerialize + LibDeflate encoding,
-- AceComm for splitting messages into 255-byte parts, ChatThrottleLib for the
-- per-prefix throttle (10 messages, then 1 per second).

local _, ns = ...

local Comm = {}
ns.Comm = Comm

Comm.PREFIX = "Profguild"
-- Size limits for received messages. The largest real message (a character with every
-- profession maxed) is about 11 kB encoded. LibDeflate cannot stop a decompression half way,
-- so the encoded size is what bounds the work for one message; a message that unpacks to more
-- than MAX_SERIALIZED is dropped before it is deserialized and its sender is ignored for
-- BLOCK_SECONDS, so highly compressible junk cannot be used to stall the game over and over.
Comm.MAX_TEXT = 24000
-- NPC data travels on its own prefix, so its bulk never queues behind (or is mistaken for) the
-- guild protocol; it has its own, smaller, size limit.
Comm.NPC_PREFIX = "ProfguildNPC"
Comm.NPC_MAX_TEXT = 6144
Comm.MAX_SERIALIZED = 262144
-- An NPC message unpacks to at most this (NpcInflate stops there, before more work is done): the
-- largest honest ones measured unpack to 6.6 kB (an NU filled with 8 of the most compressible full
-- sheets) and 4.2 kB (an NI of 600 sheets); a full trainer sheet alone 2.8 kB.
Comm.NPC_MAX_SERIALIZED = 16384
Comm.BLOCK_SECONDS = 600
Comm.blocked = {} -- sender name -> time until which its messages are ignored

local AceComm = LibStub("AceComm-3.0")
local LibSerialize = LibStub("LibSerialize")
local LibDeflate = LibStub("LibDeflate")

AceComm:Embed(Comm)

function Comm.Encode(msg)
	local serialized = LibSerialize:Serialize(msg)
	local compressed = LibDeflate:CompressDeflate(serialized)
	return LibDeflate:EncodeForWoWAddonChannel(compressed)
end

function Comm.Decode(text, max)
	if type(text) ~= "string" or #text > (max or Comm.MAX_TEXT) then return nil end
	local compressed = LibDeflate:DecodeForWoWAddonChannel(text)
	if not compressed then return nil end
	local serialized = LibDeflate:DecompressDeflate(compressed)
	if not serialized then return nil end
	if #serialized > Comm.MAX_SERIALIZED then return nil, "too large" end
	local ok, msg = LibSerialize:Deserialize(serialized)
	if not ok or type(msg) ~= "table" then return nil end
	return msg
end

function Comm:Init()
	if self.ready then return end
	self:RegisterComm(Comm.PREFIX, "OnCommReceived")
	self:RegisterComm(Comm.NPC_PREFIX, "OnCommReceived")
	self.ready = true
end

-- Sends a protocol message to the guild. Failed parts (e.g. the game started blocking
-- addon messages mid-transfer) hand the message back to Sync to be queued again.
function Comm.Send(msg)
	local ok, text = pcall(Comm.Encode, msg)
	if not ok or not text then
		ns.Debug("encode failed: %s", tostring(text))
		return
	end
	local failed = false
	Comm:SendCommMessage(Comm.PREFIX, text, "GUILD", nil, "BULK", function(_, _, _, didSend)
		if didSend == false and not failed then
			failed = true
			if msg.t == "KD" or msg.t == "KR" or msg.t == "KL" then
				if ns.catalog then ns.catalog:OnSendFailed(msg) end
			elseif msg.t == "PU" or msg.t == "PD" or msg.t == "PR" then
				if ns.guildPrices then ns.guildPrices:OnSendFailed(msg) end
			elseif msg.t == "TU" or msg.t == "TD" or msg.t == "TR" then
				if ns.requests then ns.requests:OnSendFailed(msg) end
			elseif msg.t == "BU" or msg.t == "BD" or msg.t == "BR" then
				if ns.reports then ns.reports:OnSendFailed(msg) end
			elseif ns.sync then
				ns.sync:OnSendFailed(msg)
			end
		end
	end)
	ns.Debug("sent %s (%d bytes)", tostring(msg.t), #text)
end

-- Sends an NPC data message. done(ok) is called once: true when the last part has left,
-- false on the first failed part (or when the message cannot be encoded).
-- The last NPC message encoded (NpcSync sizes a message just before it sends it): not encoded twice.
local lastNpc, lastNpcText = nil, nil
function Comm.EncodeNpc(msg)
	if msg ~= lastNpc then
		lastNpc, lastNpcText = nil, nil
		lastNpcText = Comm.Encode(msg)
		lastNpc = msg
	end
	return lastNpcText
end

function Comm.SendNpc(msg, done)
	local ok, text = pcall(Comm.EncodeNpc, msg)
	lastNpc, lastNpcText = nil, nil
	if not ok or not text then
		ns.Debug("npc encode failed: %s", tostring(text))
		if done then done(false) end
		return
	end
	local finished = false
	Comm:SendCommMessage(Comm.NPC_PREFIX, text, "GUILD", nil, "BULK", function(_, sent, total, didSend)
		if finished then return end
		if didSend == false then
			finished = true
			if done then done(false) end
		elseif sent >= total then
			finished = true
			if done then done(true) end
		end
	end)
	ns.Debug("sent npc %s (%d bytes)", tostring(msg.t), #text)
end

-- Decodes a received text; nil when it cannot be (an oversized one blocks its sender).
local function decodeFrom(text, sender, max)
	local ok, msg, why = pcall(Comm.Decode, text, max)
	if not ok or not msg then
		if why == "too large" and type(sender) == "string" then
			Comm.blocked[sender] = GetTime() + Comm.BLOCK_SECONDS
			ns.Debug("oversized message from %s, ignoring the sender for %d s", sender, Comm.BLOCK_SECONDS)
		else
			ns.Debug("could not decode a message from %s", tostring(sender))
		end
		return nil
	end
	return msg
end

-- An NPC text decoded: yield(units, kind) is called before each part of the work (the base
-- decoding, the inflating in parts of a few hundred symbols, the deserializing in parts of
-- DESER_ITEMS values), so that a caller in a coroutine can spread it over frames (NpcWork). Never
-- more than NPC_MAX_SERIALIZED is unpacked: nil, "too large" then.
Comm.DESER_ITEMS = 1024
local function decodeNpcBody(text, yield)
	-- refused before any work (not counted against the sender)
	if type(text) ~= "string" or #text > Comm.NPC_MAX_TEXT then return nil, "length" end
	yield(#text, "text")
	local compressed = LibDeflate:DecodeForWoWAddonChannel(text)
	if not compressed then return nil end
	local serialized, why = ns.NpcInflate.Inflate(compressed, Comm.NPC_MAX_SERIALIZED, function(units)
		yield(units, "inflate")
	end)
	if not serialized then return nil, why == "too large" and "too large" or nil end
	local ok, msg
	if LibSerialize.DeserializeAsync then
		local items = Comm.DESER_ITEMS
		local handler = LibSerialize:DeserializeAsync(serialized, { yieldCheck = function(t)
			t.n = (t.n or 0) + 1
			if t.n >= items then
				t.n = 0
				return true
			end
			return false
		end })
		while true do
			yield(items, "deserialize")
			local done
			done, ok, msg = handler()
			if done then break end
		end
	else
		-- an older LibSerialize loaded by another addon: in one part
		yield(#serialized / 4, "deserialize")
		ok, msg = LibSerialize:Deserialize(serialized)
	end
	if not ok or type(msg) ~= "table" then return nil end
	return msg
end

local function noYield() end

-- Decodes an NPC text at once (outside the NPC work); nil[, "too large"] when it cannot be.
function Comm.DecodeNpc(text)
	local ok, msg, why = pcall(decodeNpcBody, text, noYield)
	if not ok then return nil end
	return msg, why
end

-- The same inside a job of work: the decoding runs in a coroutine of its own (whose errors are
-- caught like pcall's) and the job paces between its parts, outside any pcall.
local function decodeNpcInJob(text, work)
	local co = coroutine.create(decodeNpcBody)
	local ok, a, b = coroutine.resume(co, text, coroutine.yield)
	while ok and coroutine.status(co) == "suspended" do
		work:Pace(a, b)
		ok, a, b = coroutine.resume(co)
	end
	if not ok then return nil end
	return a, b
end

-- A sender this session ignores: Comm's block (an oversized message) or NpcSync's (an NU over its
-- bounds); checked before anything is decoded.
-- Counted as NpcSync counts what it ignores (stats.capped); Comm's own block silently, as before.
local function npcBlocked(sender, sync)
	if type(sender) ~= "string" then return false end
	if (Comm.blocked[sender] or 0) > GetTime() then return true end
	if sync and sync.Blocked and sync:Blocked(sender) then
		if sync.stats then sync.stats.capped = (sync.stats.capped or 0) + 1 end
		return true
	end
	return false
end

-- Rule of NpcSync's queue (QUEUE_NU) for the texts Comm queues: an NU is dropped (and counted)
-- when at least QUEUE_NU NUs were still waiting when it came. Which waiting texts are NUs is known
-- only once they are decoded, in order: an NU that started at arrival count `start` was waiting
-- when every text up to that count came (nuStarts: the starts of the NUs taken, oldest first).
Comm.npcSeq = 0
local nuStarts = {}
local function nuOverflow(seq)
	while nuStarts[1] and nuStarts[1] < seq do table.remove(nuStarts, 1) end
	local cap = ns.NpcSync and ns.NpcSync.QUEUE_NU or 20
	return #nuStarts >= cap
end

-- sync: the npcSync of the time the text came (a stopped one, of a guild left meanwhile, reads
-- nothing)
local function receiveNpc(text, sender, sync, work, seq, start)
	if not sync then return end
	if npcBlocked(sender, sync) then return end
	-- logout: what guildmates sent is not decoded (the next login's sync brings it again)
	if work and work.Flushing and work:Flushing() then
		if sync.stats then sync.stats.flushed = (sync.stats.flushed or 0) + 1 end
		return
	end
	local msg, why
	if work and work:InJob() then msg, why = decodeNpcInJob(text, work) else msg, why = Comm.DecodeNpc(text) end
	if not msg then
		-- oversized or broken: the sender is ignored for a while, so that junk cannot cost the
		-- decoding again and again (an honest client never sends either)
		if why == "length" then return end
		if type(sender) == "string" then Comm.blocked[sender] = GetTime() + Comm.BLOCK_SECONDS end
		ns.Debug("%s message from %s, ignoring the sender for %d s", why == "too large" and "oversized" or "undecodable",
			tostring(sender), Comm.BLOCK_SECONDS)
		return
	end
	if seq and msg.t == "NU" then
		if nuOverflow(seq) then
			if sync.stats then sync.stats.overflow = (sync.stats.overflow or 0) + 1 end
			return
		end
		nuStarts[#nuStarts + 1] = start
	end
	-- an unexpected error in the NPC code is recorded (Bugs), not thrown at every message; inside a
	-- job NpcWork records it (a job may wait for the next frame, which no pcall may stand between)
	local work = ns.npcWork
	if (work and work:InJob()) or not ns.Bugs then sync:OnMessage(msg, sender, #text)
	else ns.Bugs.Call(sync.OnMessage, sync, msg, sender, #text) end
end

-- NPC texts are decoded as jobs of the NPC work (ns.npcWork, NpcWork), behind the loading and
-- merges, so that many arriving in one frame do not hold it up. At most NPC_QUEUE wait; the
-- excess is dropped and counted (npcSync.stats.overflow). Honest traffic queues a few at most.
Comm.NPC_QUEUE = 100
Comm.npcQueued = 0

function Comm:OnCommReceived(prefix, text, distribution, sender)
	local isNpc = prefix == Comm.NPC_PREFIX
	if (prefix ~= Comm.PREFIX and not isNpc) or distribution ~= "GUILD" then return end
	if type(sender) == "string" and (Comm.blocked[sender] or 0) > GetTime() then return end
	if isNpc then
		local work = ns.npcWork
		local sync = ns.npcSync
		if not work or work:InJob() or type(text) ~= "string" then return receiveNpc(text, sender, sync, work) end
		if npcBlocked(sender, sync) then return end
		if Comm.npcQueued >= Comm.NPC_QUEUE then
			if sync then sync.stats.overflow = (sync.stats.overflow or 0) + 1 end
			return
		end
		Comm.npcQueued = Comm.npcQueued + 1
		Comm.npcSeq = Comm.npcSeq + 1
		local seq = Comm.npcSeq
		work:Run(function()
			Comm.npcQueued = Comm.npcQueued - 1
			receiveNpc(text, sender, sync, work, seq, Comm.npcSeq)
		end)
		return
	end
	local msg = decodeFrom(text, sender)
	if not msg then return end
	-- Remember how the game names the sender: that is the name a whisper needs.
	if type(msg.s) == "string" and type(sender) == "string" and ns.guildDB then
		ns.guildDB.names = ns.guildDB.names or {}
		ns.guildDB.names[msg.s] = sender
	end
	if msg.t == "Q" or msg.t == "C" then
		if ns.reagents then ns.reagents:OnMessage(msg) end
	elseif msg.t == "KD" or msg.t == "KR" or msg.t == "KL" then
		if ns.catalog then ns.catalog:OnMessage(msg) end
	elseif msg.t == "PU" or msg.t == "PD" or msg.t == "PR" then
		if ns.guildPrices then ns.guildPrices:OnMessage(msg) end
	elseif msg.t == "TU" or msg.t == "TD" or msg.t == "TR" then
		if ns.requests then ns.requests:OnMessage(msg) end
	elseif msg.t == "BU" or msg.t == "BD" or msg.t == "BR" then
		if ns.reports then ns.reports:OnMessage(msg) end
	elseif ns.sync then
		ns.sync:OnMessage(msg, sender)
	end
end
