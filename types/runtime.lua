---@meta
-- ============================================
-- whip_core — corrections to the FiveM runtime's own annotations
-- ============================================
--
-- The CfxLua natives extension types an export's function as `fun(...): any`, one answer. whip's exports answer
-- `ok, why` (and some a third value), and FiveM hands every one of them across, so with that annotation every
-- `return false, why` in an exports('Name', function ... end) was a redundant-return-value warning. This overload
-- lets the function answer as many values as it returns. It adds to the extension's `exports`; it replaces nothing.

---@overload fun(name: string, method: fun(...): ...)
exports = {}

-- ============================================
-- Server natives that take a player
-- ============================================
--
-- The extension types these natives' player as a string (`playerSrc`), but they take the server id as a number just
-- as well, and whip passes the number it has. These overloads say so; they add to the extension's natives and
-- replace nothing. A native not listed here gets its line the same way when whip first calls it with a number.

---@param playerSrc string|integer
---@param reason string
function DropPlayer(playerSrc, reason) end

---@param playerSrc string|integer
---@return integer
function GetNumPlayerIdentifiers(playerSrc) end

---@param playerSrc string|integer
---@param identiferIndex integer
---@return string
function GetPlayerIdentifier(playerSrc, identiferIndex) end

---@param playerSrc string|integer
---@param identifierType string
---@return string
function GetPlayerIdentifierByType(playerSrc, identifierType) end

---@param playerSrc string|integer
---@return integer
function GetPlayerPing(playerSrc) end

---@param playerSrc string|integer
---@return integer
function GetPlayerRoutingBucket(playerSrc) end

---@param playerSrc string|integer
---@param object string
---@return boolean
function IsPlayerAceAllowed(playerSrc, object) end

---@param playerSrc string|integer
---@param bucket integer
function SetPlayerRoutingBucket(playerSrc, bucket) end

---@param eventName string
---@param eventTarget string|integer
---@param eventPayload string
---@param payloadLength integer
function TriggerClientEventInternal(eventName, eventTarget, eventPayload, payloadLength) end

-- ============================================
-- The scheduler
-- ============================================

--- Run `callback` in a new thread after `msec`. Answers the timeout's id, for ClearTimeout. (The extension declares
--- no answer.)
---@param msec number
---@param callback fun()
---@return integer id
function Citizen.SetTimeout(msec, callback) end

---@param msec number
---@param callback fun()
---@return integer id
function SetTimeout(msec, callback) end

--- Cancel a SetTimeout that has not run yet, by the id SetTimeout answered. The extension declares SetTimeout only.
---@param id integer
function ClearTimeout(id) end
