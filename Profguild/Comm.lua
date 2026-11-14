-- Profguild: Comm
-- Connects Sync to the GUILD addon channel: LibSerialize + LibDeflate encoding,
-- AceComm for splitting messages into 255-byte parts, ChatThrottleLib for the
-- per-prefix throttle (10 messages, then 1 per second).

local _, ns = ...

local Comm = {}
ns.Comm = Comm

Comm.PREFIX = "Profguild"
Comm.MAX_TEXT = 40000 -- largest real message is a few kB; also caps decompression size

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
			if ns.sync then ns.sync:OnSendFailed(msg) end
		end
	end)
	ns.Debug("sent %s (%d bytes)", tostring(msg.t), #text)
end

function Comm:OnCommReceived(prefix, text, distribution, sender)
	if prefix ~= Comm.PREFIX or distribution ~= "GUILD" then return end
	local ok, msg = pcall(Comm.Decode, text)
	if not ok or not msg then
		ns.Debug("could not decode a message from %s", tostring(sender))
		return
	end
	-- Remember how the game names the sender: that is the name a whisper needs.
	if type(msg.s) == "string" and type(sender) == "string" and ns.guildDB then
		ns.guildDB.names = ns.guildDB.names or {}
		ns.guildDB.names[msg.s] = sender
	end
	if ns.sync then ns.sync:OnMessage(msg) end
end
