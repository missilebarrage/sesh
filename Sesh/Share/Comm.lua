local _, ns = ...

--- Whisper-based transfer of shared sessions and levels between Sesh users.
---
---   R <version> <request> <S|L> <id>               request a shared session (S) or level (L)
---   D <version> <request> <seq> <total> <data>     one slice of the encoded payload
---   E <version> <request> <reason>                 refusal: OFF NF RL VER LOCK
---
--- Fields are tab-separated. The payload is serialized (CBOR), compressed and base64
--- encoded by the client, then sent in slices that fit the 255-byte message limit.
--- Only what its owner explicitly shared is served, with per-sender rate limits.
---@class SeshComm
local Comm = ns.Comm
local Database = ns.Database
local History = ns.History
local Leveling = ns.Leveling
local Recorder = ns.Recorder
local Session = ns.Session
local Shares = ns.Shares
local Payload = ns.Payload
local Names = ns.Names
local Events = ns.Events

Comm.PROTOCOL = 2

-- Request letters for what can be shared.
local KIND_LETTERS = { session = "S", level = "L" }
local LETTER_KINDS = { S = "session", L = "level" }

local SLICE_BYTES = 230
local MAX_SLICES = 40
local MAX_ENCODED_BYTES = MAX_SLICES * SLICE_BYTES
local MAX_DECODED_BYTES = 64 * 1024
local SEND_INTERVAL = 0.15
local FIRST_REPLY_TIMEOUT = 10
local SLICE_TIMEOUT = 8
local TOTAL_TIMEOUT = 45
-- A requester waits FIRST_REPLY_TIMEOUT for the first slice; retrying longer is pointless.
local LOCKDOWN_RETRY_SECONDS = 10
local RATE_WINDOW = 60
local MAX_REQUESTS_PER_SENDER = 3
local MAX_REQUESTS_TOTAL = 12
local MAX_ACTIVE_TRANSFERS = 2

Comm.REASONS = { OFF = true, NF = true, RL = true, VER = true, LOCK = true, TIMEOUT = true, BAD = true }

local Result = Enum.SendAddonMessageResult or {}
local THROTTLED = {}
THROTTLED[Result.AddonMessageThrottle or 3] = true
THROTTLED[Result.ChannelThrottle or 8] = true
local LOCKDOWN = Result.AddOnMessageLockdown or 11
local SUCCESS = Result.Success or 0

---@class SeshOutgoingMessage
---@field target string
---@field text string
---@field transfer string? request token of the transfer this message belongs to
---@field attempts integer
---@field firstTriedAt number?
---@field notBefore number?

local queue = {} ---@type SeshOutgoingMessage[]
local pump
local requests = {} ---@type table<string, table> outgoing requests by token
local requestsByKey = {} ---@type table<string, table> outgoing requests by owner, kind and id
local watchdog
local recentRequests = {} ---@type {at: number, sender: string}[]
local lastRefusal = {} ---@type table<string, number>

-- Encoding ----------------------------------------------------------------------------

--- Serializes, compresses and base64-encodes a table. Returns nil on failure.
---@param data table
---@return string?
function Comm.Encode(data)
	local ok, encoded = pcall(function()
		local serialized = C_EncodingUtil.SerializeCBOR(data)
		local compressed = C_EncodingUtil.CompressString(
			serialized,
			Enum.CompressionMethod.Deflate,
			Enum.CompressionLevel.OptimizeForSize
		)
		return C_EncodingUtil.EncodeBase64(compressed)
	end)
	return ok and encoded or nil
end

--- Reverses Encode with size limits; never throws.
---@param text string
---@return any
function Comm.Decode(text)
	if #text > MAX_ENCODED_BYTES then
		return nil
	end
	local ok, data = pcall(function()
		local compressed = C_EncodingUtil.DecodeBase64(text)
		local serialized = C_EncodingUtil.DecompressString(compressed, Enum.CompressionMethod.Deflate)
		if #serialized > MAX_DECODED_BYTES then
			return nil
		end
		return C_EncodingUtil.DeserializeCBOR(serialized)
	end)
	return ok and data or nil
end

-- Sending -----------------------------------------------------------------------------

--- Removes the message at the head of the queue and, if it belonged to a transfer, the
--- rest of that transfer (a transfer missing a slice is useless to the receiver).
local function DiscardHead()
	local message = table.remove(queue, 1)
	if message and message.transfer then
		for index = #queue, 1, -1 do
			if queue[index].transfer == message.transfer then
				table.remove(queue, index)
			end
		end
	end
end

local function StopPump()
	if pump then
		pump:Cancel()
		pump = nil
	end
end

local function Pump()
	local message = queue[1]
	if not message then
		StopPump()
		return
	end
	local now = GetTime()
	if message.notBefore and message.notBefore > now then
		return
	end
	message.firstTriedAt = message.firstTriedAt or now
	local result = C_ChatInfo.SendAddonMessage(ns.COMM_PREFIX, message.text, "WHISPER", message.target)
	if result == nil or result == true or result == SUCCESS then
		table.remove(queue, 1)
	elseif THROTTLED[result] then
		message.attempts = message.attempts + 1
		if message.attempts > 3 then
			DiscardHead()
		else
			message.notBefore = now + 2 ^ (message.attempts - 1)
		end
	elseif result == LOCKDOWN and now - message.firstTriedAt < LOCKDOWN_RETRY_SECONDS then
		message.notBefore = now + 2
	else
		-- Offline target or another permanent failure: give up on this message's transfer.
		DiscardHead()
	end
end

local function Enqueue(target, text, transfer)
	queue[#queue + 1] = { target = target, text = text, transfer = transfer, attempts = 0 }
end

--- Starts sending queued messages. Call after queueing a whole transfer, so a failure
--- on its first message can drop the rest of it.
local function Flush()
	if not pump and queue[1] then
		pump = C_Timer.NewTicker(SEND_INTERVAL, Pump)
		Pump()
	end
end

local function ActiveTransfers()
	local transfers, count = {}, 0
	for _, message in ipairs(queue) do
		if message.transfer and not transfers[message.transfer] then
			transfers[message.transfer] = true
			count = count + 1
		end
	end
	return count
end

-- Serving -----------------------------------------------------------------------------

local function Refuse(target, request, reason)
	local now = GetTime()
	-- One refusal per sender per window: refusals must not become an amplifier.
	if lastRefusal[target] and now - lastRefusal[target] < RATE_WINDOW then
		return
	end
	lastRefusal[target] = now
	Enqueue(target, string.format("E\t%d\t%s\t%s", Comm.PROTOCOL, request, reason))
	Flush()
end

local function IsRateLimited(sender)
	local now = GetTime()
	while recentRequests[1] and now - recentRequests[1].at > RATE_WINDOW do
		table.remove(recentRequests, 1)
	end
	local fromSender = 0
	for _, entry in ipairs(recentRequests) do
		if Names.Same(entry.sender, sender) then
			fromSender = fromSender + 1
		end
	end
	if fromSender >= MAX_REQUESTS_PER_SENDER or #recentRequests >= MAX_REQUESTS_TOTAL then
		return true
	end
	recentRequests[#recentRequests + 1] = { at = now, sender = sender }
	return false
end

--- The view of a session or level that may be served to others, or nil.
---@param kind SeshShareKind
local function SharedView(kind, id, now)
	if not Shares.IsShared(kind, id, now) then
		return nil
	end
	if kind == "level" then
		return Leveling.View(id, now)
	end
	local active = Recorder.Current()
	if active and active.id == id then
		return Session.LiveView(active, now)
	end
	local record = History.Get(id)
	return record and Session.View(record)
end

local function HandleRequest(sender, version, request, target)
	-- While chat is locked down nothing can be sent, not even a refusal.
	if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
		return
	end
	if version ~= Comm.PROTOCOL then
		Refuse(sender, request, "VER")
		return
	end
	local letter, id = target:match("^(%u)\t(%d+)$")
	local kind = LETTER_KINDS[letter]
	if not kind then
		return
	end
	if not Database.Get("allowLinkRequests") then
		Refuse(sender, request, "OFF")
		return
	end
	if IsRateLimited(sender) or ActiveTransfers() >= MAX_ACTIVE_TRANSFERS then
		Refuse(sender, request, "RL")
		return
	end
	local now = GetServerTime()
	local view = SharedView(kind, tonumber(id), now)
	local encoded = view and Comm.Encode(Payload.Build(view, now))
	local slices = encoded and math.ceil(#encoded / SLICE_BYTES)
	if not encoded or slices > MAX_SLICES then
		Refuse(sender, request, "NF")
		return
	end
	ns.Count("sharesServed")
	for index = 1, slices do
		local slice = encoded:sub((index - 1) * SLICE_BYTES + 1, index * SLICE_BYTES)
		Enqueue(sender, string.format("D\t%d\t%s\t%d\t%d\t%s", Comm.PROTOCOL, request, index, slices, slice), request)
	end
	Flush()
end

-- Requesting --------------------------------------------------------------------------

local TOKEN_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

local function NewToken()
	local chars = {}
	for index = 1, 6 do
		local position = math.random(1, #TOKEN_CHARS)
		chars[index] = TOKEN_CHARS:sub(position, position)
	end
	return table.concat(chars)
end

local function Finish(request)
	requests[request.token] = nil
	requestsByKey[request.key] = nil
	if not next(requests) and watchdog then
		watchdog:Cancel()
		watchdog = nil
	end
end

local function Fail(request, reason)
	Finish(request)
	if request.listener.OnError then
		request.listener.OnError(reason)
	end
end

local function CheckTimeouts()
	local now = GetTime()
	for _, request in pairs(requests) do
		local silentFor = now - (request.lastSliceAt or request.startedAt)
		if
			now - request.startedAt > TOTAL_TIMEOUT
			or (not request.lastSliceAt and silentFor > FIRST_REPLY_TIMEOUT)
			or (request.lastSliceAt and silentFor > SLICE_TIMEOUT)
		then
			Fail(request, "TIMEOUT")
		end
	end
end

---@class SeshRequestListener
---@field OnProgress fun(received: integer, total: integer)?
---@field OnComplete fun(view: SeshView)
---@field OnError fun(reason: string)?

--- Asks another player for a session or level they shared.
---@param owner string the player who shared it, as chat named them (also the whisper target)
---@param kind SeshShareKind
---@param id integer the session id or level from the link
---@param listener SeshRequestListener
function Comm.Request(owner, kind, id, listener)
	local key = owner:lower() .. ":" .. kind .. ":" .. id
	local existing = requestsByKey[key]
	if existing then
		existing.listener = listener
		return
	end
	if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
		if listener.OnError then
			listener.OnError("LOCK")
		end
		return
	end
	local token = NewToken()
	local request = {
		token = token,
		key = key,
		owner = owner,
		slices = {},
		received = 0,
		bytes = 0,
		startedAt = GetTime(),
		listener = listener,
	}
	requests[token] = request
	requestsByKey[key] = request
	if not watchdog then
		watchdog = C_Timer.NewTicker(1, CheckTimeouts)
	end
	Enqueue(owner, string.format("R\t%d\t%s\t%s\t%d", Comm.PROTOCOL, token, KIND_LETTERS[kind], id))
	Flush()
end

local function Complete(request)
	local slices = {}
	for index = 1, request.total do
		slices[index] = request.slices[index]
	end
	local data = Comm.Decode(table.concat(slices))
	local view = data and Payload.Read(data, GetServerTime())
	if not view then
		Fail(request, "BAD")
		return
	end
	Finish(request)
	request.listener.OnComplete(view)
end

local function HandleSlice(sender, version, token, index, total, slice)
	local request = requests[token]
	-- Only accept slices we asked for, from the player we asked.
	if not request or not Names.Same(request.owner, sender) then
		return
	end
	if version ~= Comm.PROTOCOL then
		Fail(request, "VER")
		return
	end
	if total < 1 or total > MAX_SLICES or index < 1 or index > total or (request.total and request.total ~= total) then
		Fail(request, "BAD")
		return
	end
	request.total = total
	if request.slices[index] then
		return
	end
	request.bytes = request.bytes + #slice
	if request.bytes > MAX_ENCODED_BYTES then
		Fail(request, "BAD")
		return
	end
	request.slices[index] = slice
	request.received = request.received + 1
	request.lastSliceAt = GetTime()
	if request.received == total then
		Complete(request)
	elseif request.listener.OnProgress then
		request.listener.OnProgress(request.received, total)
	end
end

local function HandleRefusal(sender, version, token, reason)
	local request = requests[token]
	if not (request and Names.Same(request.owner, sender)) then
		return
	end
	if version ~= Comm.PROTOCOL then
		-- Whatever the reason, the owner's Sesh speaks another version.
		Fail(request, "VER")
	else
		Fail(request, Comm.REASONS[reason] and reason or "BAD")
	end
end

-- Receiving ---------------------------------------------------------------------------

local function OnAddonMessage(prefix, text, channel, sender)
	if prefix ~= ns.COMM_PREFIX then
		return
	end
	text, sender = ns.Str(text), ns.Str(sender)
	if not (text and sender) or sender == "" or channel ~= "WHISPER" then
		return
	end
	local kind = text:sub(1, 1)
	if kind == "R" then
		-- The version comes first, so requests in another format still get a VER refusal.
		local version, token, target = text:match("^R\t(%d+)\t(%w+)\t(.*)$")
		if version and #token <= 12 then
			HandleRequest(sender, tonumber(version), token, target)
		end
	elseif kind == "D" then
		local version, token, index, total, slice = text:match("^D\t(%d+)\t(%w+)\t(%d+)\t(%d+)\t([%w%+/=]+)$")
		if version then
			HandleSlice(sender, tonumber(version), token, tonumber(index), tonumber(total), slice)
		end
	elseif kind == "E" then
		local version, token, reason = text:match("^E\t(%d+)\t(%w+)\t(%u+)$")
		if version then
			HandleRefusal(sender, tonumber(version), token, reason)
		end
	end
end

--- Registers the message prefix and starts listening. Called at PLAYER_LOGIN.
function Comm.Init()
	C_ChatInfo.RegisterAddonMessagePrefix(ns.COMM_PREFIX)
	Events.On("CHAT_MSG_ADDON", OnAddonMessage)
end
