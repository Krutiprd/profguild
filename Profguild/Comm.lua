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

function Comm.Decode(text)
	if type(text) ~= "string" or #text > Comm.MAX_TEXT then return nil end
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
			elseif ns.sync then
				ns.sync:OnSendFailed(msg)
			end
		end
	end)
	ns.Debug("sent %s (%d bytes)", tostring(msg.t), #text)
end

function Comm:OnCommReceived(prefix, text, distribution, sender)
	if prefix ~= Comm.PREFIX or distribution ~= "GUILD" then return end
	local now = GetTime()
	if type(sender) == "string" and (Comm.blocked[sender] or 0) > now then return end
	local ok, msg, why = pcall(Comm.Decode, text)
	if not ok or not msg then
		if why == "too large" and type(sender) == "string" then
			Comm.blocked[sender] = now + Comm.BLOCK_SECONDS
			ns.Debug("oversized message from %s, ignoring the sender for %d s", sender, Comm.BLOCK_SECONDS)
		else
			ns.Debug("could not decode a message from %s", tostring(sender))
		end
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
	elseif ns.sync then
		ns.sync:OnMessage(msg, sender)
	end
end
