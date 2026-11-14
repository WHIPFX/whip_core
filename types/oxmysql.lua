---@meta
-- ============================================
-- whip_core — oxmysql's MySQL, as whip uses it
-- ============================================
--
-- '@oxmysql/lib/MySQL.lua' (fxmanifest.lua's server_scripts) makes the MySQL global at run time, and it carries no
-- annotations of its own; without these the editor took MySQL's shape from dev/director/harness.lua's stand-in, whose
-- functions take no arguments. Only the calls whip makes are typed in full. The .await forms wait, so call them from a
-- thread or a handler; a failed query raises an error instead of returning nil, and a transaction that fails is rolled
-- back and returns false.

---@alias WhipSqlParams table|nil Positional (`?`) values in order, or named (`@name`, `:name`) values by name

---@class WhipMySQLMethod
---@overload fun(query: string|integer, params?: WhipSqlParams|fun(result: any), cb?: fun(result: any))
local Method = {}

---@class WhipMySQLQuery: WhipMySQLMethod
local Query = {}
--- Every row, or for an INSERT/UPDATE/DELETE the driver's result (affectedRows, insertId).
---@async
---@param query string|integer
---@param params? WhipSqlParams
---@return table
function Query.await(query, params) end

---@class WhipMySQLScalar: WhipMySQLMethod
local Scalar = {}
--- The first column of the first row, or nil when there is no row.
---@async
---@param query string|integer
---@param params? WhipSqlParams
---@return any
function Scalar.await(query, params) end

---@class WhipMySQLSingle: WhipMySQLMethod
local Single = {}
--- The first row, or nil when there is none.
---@async
---@param query string|integer
---@param params? WhipSqlParams
---@return table|nil
function Single.await(query, params) end

---@class WhipMySQLInsert: WhipMySQLMethod
local Insert = {}
--- The new row's id (insertId).
---@async
---@param query string|integer
---@param params? WhipSqlParams
---@return integer
function Insert.await(query, params) end

---@class WhipMySQLUpdate: WhipMySQLMethod
local Update = {}
--- How many rows changed (affectedRows).
---@async
---@param query string|integer
---@param params? WhipSqlParams
---@return integer
function Update.await(query, params) end

---@class WhipMySQLTransaction
---@overload fun(queries: table, params?: WhipSqlParams|fun(ok: boolean), cb?: fun(ok: boolean))
local Transaction = {}
--- Runs every query or none: true when they all ran, false when one failed and they were rolled back.
---@async
---@param queries table A list: of { query = sql, values = params }, of { sql, params }, or of SQL strings that all take `params`
---@param params? WhipSqlParams Shared values for every query
---@return boolean
function Transaction.await(queries, params) end

---@class WhipMySQLReady
---@overload fun(cb: fun())
local Ready = {}
--- Wait until oxmysql has connected.
---@async
---@return true
function Ready.await() end

---@class WhipMySQL
---@field query WhipMySQLQuery
---@field scalar WhipMySQLScalar
---@field single WhipMySQLSingle
---@field insert WhipMySQLInsert
---@field update WhipMySQLUpdate
---@field transaction WhipMySQLTransaction
---@field ready WhipMySQLReady
---@field startTransaction fun(cb: fun(query: function): boolean|nil): any
---@field Async table The older callback forms (MySQL.Async.fetchAll, .execute...)
---@field Sync table The older blocking forms (MySQL.Sync.fetchAll, .execute...)
---@field [string] any Any other name is passed on to oxmysql's export of that name (prepare, rawExecute...)
MySQL = {}
