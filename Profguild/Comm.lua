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
function Comm.SendNpc(msg, done)
	local ok, text = pcall(Comm.Encode, msg)
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

function Comm:OnCommReceived(prefix, text, distribution, sender)
	local isNpc = prefix == Comm.NPC_PREFIX
	if (prefix ~= Comm.PREFIX and not isNpc) or distribution ~= "GUILD" then return end
	local now = GetTime()
	if type(sender) == "string" and (Comm.blocked[sender] or 0) > now then return end
	local ok, msg, why = pcall(Comm.Decode, text, isNpc and Comm.NPC_MAX_TEXT or nil)
	if not ok or not msg then
		if why == "too large" and type(sender) == "string" then
			Comm.blocked[sender] = now + Comm.BLOCK_SECONDS
			ns.Debug("oversized message from %s, ignoring the sender for %d s", sender, Comm.BLOCK_SECONDS)
		else
			ns.Debug("could not decode a message from %s", tostring(sender))
		end
		return
	end
	if isNpc then
		if ns.npcSync then ns.npcSync:OnMessage(msg, sender, #text) end
		return
	end
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
