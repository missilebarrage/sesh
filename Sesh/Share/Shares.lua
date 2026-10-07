local _, ns = ...

--- What other Sesh users may open: the sessions and levels this character shared in chat
--- during the last 30 days. Anything else is refused when someone asks for it.
---@class SeshShares
local Shares = ns.Shares
local Database = ns.Database

-- Shared things can be opened by other players for this long after the share.
local LIFETIME_SECONDS = 30 * 86400

-- Where each kind's share times are kept in SeshCharDB, by id (session id or level).
local TABLES = { session = "shared", level = "sharedLevels" }

---@alias SeshShareKind "session"|"level"

---@param kind SeshShareKind
---@return table<integer, integer>?
local function List(kind)
	local char = Database.Char()
	return char and char[TABLES[kind]]
end

--- Whether something may be served to other players: it was shared in the last 30 days.
---@param kind SeshShareKind
---@param id integer
---@param now integer
---@return boolean
function Shares.IsShared(kind, id, now)
	local list = List(kind)
	local sharedAt = list and list[id]
	return sharedAt ~= nil and now - sharedAt <= LIFETIME_SECONDS
end

--- Marks something as shared at `now`, and forgets expired shares of the same kind.
---@param kind SeshShareKind
---@param id integer
---@param now integer
function Shares.Mark(kind, id, now)
	local list = List(kind)
	if not list then
		return
	end
	list[id] = now
	for sharedID, sharedAt in pairs(list) do
		if now - sharedAt > LIFETIME_SECONDS then
			list[sharedID] = nil
		end
	end
end

---@param kind SeshShareKind
---@param id integer
function Shares.Forget(kind, id)
	local list = List(kind)
	if list then
		list[id] = nil
	end
end

---@param kind SeshShareKind
function Shares.ForgetAll(kind)
	local list = List(kind)
	if list then
		wipe(list)
	end
end
