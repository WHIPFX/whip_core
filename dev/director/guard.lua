-- Memory guard for any offline Lua test: lua54 -e "dofile('guard.lua')" <test.lua> <args>, or
-- lua54 guard.lua <test.lua> <args>. Past the cap (MEMCAP_MB, 256 by default, never above 1024) it stops at once;
-- hooked in the main thread and in every coroutine (hooks are per coroutine in Lua 5.4).
local CAP_KB = math.min(tonumber(os.getenv('MEMCAP_MB')) or 256, 1024) * 1024
local function guard()
    if collectgarbage('count') > CAP_KB then
        io.stderr:write(('STOPPED: memory over %d MB\n'):format(CAP_KB // 1024))
        os.exit(3)
    end
end
debug.sethook(guard, '', 20000)
local rawCreate, rawWrap = coroutine.create, coroutine.wrap
rawset(coroutine, 'create', function(fn) return rawCreate(function(...) debug.sethook(guard, '', 20000) return fn(...) end) end)
rawset(coroutine, 'wrap', function(fn) return rawWrap(function(...) debug.sethook(guard, '', 20000) return fn(...) end) end)
-- Run as `lua54 guard.lua <test> ...`: the test gets its own arg list.
if arg and arg[0] and arg[0]:match('guard%.lua$') and arg[1] then
    local test = arg[1]
    local rest = {}
    for i = 2, #arg do rest[#rest + 1] = arg[i] end
    rest[0] = test
    arg = rest
    dofile(test)
end
