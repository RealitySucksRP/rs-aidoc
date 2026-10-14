RSAIDocBridge = {}

local function bridgeReady()
    return Config.UseExternalBridge == true and GetResourceState('rs_bridge') == 'started'
end

-- ------------------------------------------------------------ native fallback
--
-- rs_bridge is OPTIONAL and stays preferred. Before this existed every function
-- below returned a placeholder when rs_bridge was absent, and those placeholders
-- were the resource: IsPlayerDown returned false so Dr. Graves never saw a
-- downed player, RevivePlayer returned false, and GetMoney returned 0 so he
-- could never be paid. Nothing errored; nothing worked.

local function started(name)
    return GetResourceState(name) == 'started'
end

local frameworkCache
local function nativeFramework()
    -- Respect explicit framework selection, but never report a missing provider.
    local preference = tostring(Config.Framework or 'auto'):lower()
    if preference ~= 'auto' then
        local aliases = { qbx = 'qbox', qbx_core = 'qbox', qb = 'qbcore', ['qb-core'] = 'qbcore', es_extended = 'esx' }
        local selected = aliases[preference] or preference
        if selected == 'qbox' then return started('qbx_core') and 'qbox' or 'standalone' end
        if selected == 'qbcore' then return started('qb-core') and 'qbcore' or 'standalone' end
        if selected == 'esx' then return started('es_extended') and 'esx' or 'standalone' end
        if selected == 'standalone' then return 'standalone' end
    end
    if frameworkCache and frameworkCache ~= 'standalone' then return frameworkCache end
    -- qbx_core FIRST: it declares provide 'qb-core', so exports['qb-core']
    -- resolves on Qbox and testing qb-core first misidentifies the framework.
    if started('qbx_core') then frameworkCache = 'qbox'
    elseif started('qb-core') then frameworkCache = 'qbcore'
    elseif started('es_extended') then frameworkCache = 'esx'
    else frameworkCache = 'standalone' end
    return frameworkCache
end

local qbCache, esxCache

local function qbCore()
    if qbCache then return qbCache end
    local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if ok and type(core) == 'table' then qbCache = core end
    return qbCache
end

local function esxCore()
    if esxCache then return esxCache end
    local ok, core = pcall(function() return exports.es_extended:getSharedObject() end)
    if ok and type(core) == 'table' then esxCache = core end
    return esxCache
end

--- Returns (player, kind) where kind is 'qb' or 'esx'.
local function nativePlayer(src)
    src = tonumber(src)
    if not src then return nil end
    local fw = nativeFramework()

    if fw == 'qbox' then
        local ok, player = pcall(function() return exports.qbx_core:GetPlayer(src) end)
        if ok and player then return player, 'qb' end
    elseif fw == 'qbcore' then
        local core = qbCore()
        if core and core.Functions then
            local ok, player = pcall(function() return core.Functions.GetPlayer(src) end)
            if ok and player then return player, 'qb' end
        end
    elseif fw == 'esx' then
        local core = esxCore()
        if core and core.GetPlayerFromId then
            local ok, player = pcall(function() return core.GetPlayerFromId(src) end)
            if ok and player then return player, 'esx' end
        end
    end

    return nil
end

local function nativeAccount(account)
    -- ESX cash is stored in the 'money' account; Qbox/QBCore use 'cash'.
    if account == 'cash' or account == 'money' or account == nil then return 'money' end
    return account
end

local function validAmount(amount)
    local n = tonumber(amount)
    -- Whole, finite, positive currency units only; never let Lua coerce NaN,
    -- infinity or fractional requests into provider account operations.
    return n and n == n and n ~= math.huge and n ~= -math.huge
        and n > 0 and n == math.floor(n) and n <= 1000000000 and n or nil
end

local function esxBalance(player, account)
    local name = nativeAccount(account)
    if name == 'money' then
        if type(player.getAccount) == 'function' then
            local ok, acc = pcall(function() return player.getAccount('money') end)
            if ok and type(acc) == 'table' and tonumber(acc.money) then
                return tonumber(acc.money)
            end
        end
        if type(player.getMoney) == 'function' then
            local ok, value = pcall(function() return player.getMoney() end)
            if ok then return tonumber(value) end
        end
        return nil
    end
    if type(player.getAccount) ~= 'function' then return nil end
    local ok, acc = pcall(function() return player.getAccount(name) end)
    return ok and type(acc) == 'table' and tonumber(acc.money) or nil
end

-- ESX removeAccountMoney/addAccountMoney have NO success return. Confirm exact
-- post-balance delta; a successful pcall only means Lua did not throw.
-- Unknown/partial changes are marked uncertain: NEVER retry another account.
local function esxMutate(player, account, amount, reason, debit)
    local name = nativeAccount(account)
    local before = esxBalance(player, account)
    if before == nil then return false, 'unavailable' end
    if debit and before < amount then return false, 'rejected' end

    local action = debit and 'removeAccountMoney' or 'addAccountMoney'
    local callAccount = true
    if name == 'money' then
        -- Older ESX builds expose separate cash mutators but no 'money'
        -- getAccount entry. Use those instead, still checking getMoney's delta.
        local hasAccount, accountData = pcall(function() return player.getAccount('money') end)
        if type(player.getAccount) ~= 'function' or not hasAccount or not accountData then
            action = debit and 'removeMoney' or 'addMoney'
            callAccount = false
        end
    end
    if type(player[action]) ~= 'function' then return false, 'unavailable' end
    local ok, err = pcall(function()
        if callAccount then
            player[action](name, amount, reason or 'rs-aidoc')
        else
            player[action](amount, reason or 'rs-aidoc')
        end
    end)
    local after = esxBalance(player, account)
    local expected = debit and before - amount or before + amount
    if ok and after ~= nil and after == expected then return true end
    print(('[rs-aidoc] MONEY MUTATION UNCONFIRMED action=%s account=%s before=%s after=%s amount=%s err=%s')
        :format(action, name, tostring(before), tostring(after), tostring(amount), tostring(err)))
    return false, 'uncertain'
end

function RSAIDocBridge.Framework()
    if bridgeReady() then
        local ok, value = pcall(function()
            return exports.rs_bridge:GetFramework()
        end)
        if ok and value and value ~= 'standalone' then return value end
    end
    return nativeFramework()
end

function RSAIDocBridge.GetPlayerData(src)
    if bridgeReady() then
        local ok, value = pcall(function()
            return exports.rs_bridge:GetPlayerData(src)
        end)
        if ok and value then return value end
    end

    local player, kind = nativePlayer(src)
    if not player then return nil end
    if kind == 'qb' then return player.PlayerData end

    local identifier = player.identifier
    return {
        source = tonumber(src),
        identifier = identifier,
        citizenid = identifier,
        job = player.job,
        metadata = player.variables or {}
    }
end

function RSAIDocBridge.GetJob(src)
    if bridgeReady() then
        local ok, value = pcall(function()
            return exports.rs_bridge:GetJob(src)
        end)
        if ok and value then return value end
    end

    local player, kind = nativePlayer(src)
    if not player then return nil end
    if kind == 'qb' then return player.PlayerData and player.PlayerData.job end

    -- ESX grade is a flat number; present it in the nested shape callers expect.
    local job = player.job
    if not job then return nil end
    return {
        name = job.name,
        label = job.label,
        grade = { level = tonumber(job.grade) or 0, name = job.grade_name, label = job.grade_label },
        onduty = true
    }
end

function RSAIDocBridge.CharacterIdentity(src)
    if not GetPlayerName(src) then return end
    local framework = RSAIDocBridge.Framework()
    local data = RSAIDocBridge.GetPlayerData(src)
    local id = data and (data.citizenid or data.identifier)
    if type(id) == 'string' and id ~= '' then return framework .. ':' .. id end
    if framework == 'standalone' and GetPlayerName(src) then
        local license = GetPlayerIdentifierByType(src, 'license')
        if license then return 'standalone:' .. license end
    end
end

function RSAIDocBridge.GetMoney(src, account)
    if bridgeReady() then
        local ok, value = pcall(function()
            return exports.rs_bridge:GetMoney(src, account)
        end)
        if ok and tonumber(value) then return tonumber(value) end
    end

    if nativeFramework() == 'qbox' then
        local ok, value = pcall(function() return exports.qbx_core:GetMoney(src, account or 'cash') end)
        return ok and (tonumber(value) or 0) or 0
    end

    local player, kind = nativePlayer(src)
    if not player then return 0 end
    if kind == 'qb' then
        local money = player.PlayerData and player.PlayerData.money or {}
        return tonumber(money[account or 'cash']) or 0
    end

    return esxBalance(player, account) or 0
end

local function paymentPlayer(src, expectedIdentity)
    local player, kind = nativePlayer(src)
    if not player then return end
    local id = kind == 'qb' and player.PlayerData and player.PlayerData.citizenid or player.identifier
    if expectedIdentity and (not GetPlayerName(src)
        or nativeFramework() .. ':' .. tostring(id) ~= expectedIdentity) then return end
    return player, kind, id
end

function RSAIDocBridge.RemoveMoney(src, account, amount, reason, expectedIdentity)
    amount = validAmount(amount)
    if not amount then return false, 'invalid-amount' end

    if bridgeReady() then
        if expectedIdentity and RSAIDocBridge.CharacterIdentity(src) ~= expectedIdentity then return false, 'rejected' end
        local ok, value = pcall(function()
            return exports.rs_bridge:RemoveMoney(src, account, amount, reason)
        end)
        -- An attempted mutation cannot safely fall back to another provider.
        if not ok then return false, 'uncertain' end
        return value == true, value == false and 'rejected' or 'uncertain'
    end

    local player, kind, id = paymentPlayer(src, expectedIdentity)
    if not player then return false, 'unavailable' end
    if nativeFramework() == 'qbox' then
        local ok, value = pcall(function()
            -- Qbox accepts citizen IDs; never resolve a recycled source at mutation time.
            return exports.qbx_core:RemoveMoney(id, account or 'cash', amount, reason or 'rs-aidoc')
        end)
        if not ok then return false, 'uncertain' end
        return value == true, value == false and 'rejected' or 'uncertain'
    end

    if kind == 'qb' then
        local ok, value = pcall(function()
            return player.Functions.RemoveMoney(account or 'cash', amount, reason)
        end)
        if not ok then return false, 'uncertain' end
        return value == true, value == false and 'rejected' or 'uncertain'
    end

    return esxMutate(player, account, amount, reason, true)
end

function RSAIDocBridge.AddMoney(src, account, amount, reason, expectedIdentity)
    amount = validAmount(amount)
    if not amount then return false, 'invalid-amount' end

    if bridgeReady() then
        if expectedIdentity and RSAIDocBridge.CharacterIdentity(src) ~= expectedIdentity then return false, 'rejected' end
        local ok, value = pcall(function()
            return exports.rs_bridge:AddMoney(src, account, amount, reason)
        end)
        if not ok then return false, 'uncertain' end
        return value == true, value == false and 'rejected' or 'uncertain'
    end

    local player, kind, id = paymentPlayer(src, expectedIdentity)
    if not player then return false, 'unavailable' end
    if nativeFramework() == 'qbox' then
        local ok, value = pcall(function()
            return exports.qbx_core:AddMoney(id, account or 'cash', amount, reason or 'rs-aidoc')
        end)
        if not ok then return false, 'uncertain' end
        return value == true, value == false and 'rejected' or 'uncertain'
    end

    if kind == 'qb' then
        local ok, value = pcall(function()
            return player.Functions.AddMoney(account or 'cash', amount, reason)
        end)
        if not ok then return false, 'uncertain' end
        return value == true, value == false and 'rejected' or 'uncertain'
    end

    return esxMutate(player, account, amount, reason, false)
end


function RSAIDocBridge.IsPlayerDown(src)
    if bridgeReady() then
        local ok, value = pcall(function()
            return exports.rs_bridge:IsPlayerDown(src)
        end)
        if ok and value ~= nil then return value == true end
    end

    local player, kind = nativePlayer(src)
    if not player then return false end

    if kind == 'qb' then
        -- Qbox/QBCore ambulance scripts all record the state in metadata; the
        -- key differs by script, so check every conventional one.
        local meta = player.PlayerData and player.PlayerData.metadata or {}
        return meta.isdead == true or meta.inlaststand == true or meta.dead == true
    end

    local ok, dead = pcall(function() return player.get('dead') end)
    if ok and dead ~= nil then return dead == true end
    local gotStatus, status = pcall(function() return player.getMeta('dead') end)
    return gotStatus and status == true or false
end

-- This is intentionally different from IsPlayerDown(): a missing or stale
-- death flag is NOT evidence that the target completed an ambulance revive.
function RSAIDocBridge.IsPlayerRevived(src)
    src = tonumber(src)
    if not src or not GetPlayerName(src) then return false end

    local state = Player(src) and Player(src).state
    if state and (state.isDead == true or state.dead == true or state.laststand == true) then
        return false
    end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or not DoesEntityExist(ped) or GetEntityHealth(ped) <= 0 then
        return false
    end

    local framework = nativeFramework()
    local player, kind = nativePlayer(src)
    if framework == 'qbox' or framework == 'qbcore' then
        local meta = player and player.PlayerData and player.PlayerData.metadata
        if not meta then return false end
        if meta.isdead == true or meta.inlaststand == true or meta.dead == true then return false end
        -- A known false from the framework, not nil, proves the revive state.
        return meta.isdead == false and meta.inlaststand == false
    end
    if framework == 'esx' then
        -- Modern esx_ambulancejob sets the replicated isDead flag. Without it,
        -- a revived-looking ped may still be medically down; fail closed.
        if not state or state.isDead ~= false then return false end
        -- Check independent server-owned ESX flags when custom medical
        -- providers expose them; never let one cleared state mask a true one.
        if player and type(player.get) == 'function' then
            local ok, dead = pcall(function() return player.get('dead') end)
            if ok and dead == true then return false end
        end
        if player and type(player.getMeta) == 'function' then
            local ok, dead = pcall(function() return player.getMeta('dead') end)
            if ok and dead == true then return false end
        end
        return true
    end
    -- Standalone has no external medical state to reconcile.
    return true
end

function RSAIDocBridge.MedicalProvider()
    if bridgeReady() then return 'external' end
    if started('qbx_medical') then return 'qbox' end
    if started('hospital') or started('qb-ambulancejob') then return 'qbcore' end
    if started('esx_ambulancejob') then return 'esx' end
    return 'native'
end

function RSAIDocBridge.RevivePlayer(src)
    if bridgeReady() then
        local ok, value = pcall(function()
            return exports.rs_bridge:RevivePlayer(src)
        end)
        return ok and value ~= false, 'external', not ok
    end

    src = tonumber(src)
    if not src then return false end

    -- Ambulance scripts do not share one revive API, so try the conventional
    -- ones in turn. Each is guarded: an install running none of them falls
    -- through and reports failure rather than erroring.
    if started('qbx_medical') then
        local ok, result = pcall(function() return exports.qbx_medical:Revive(src) end)
        -- nil is the documented return of qbx_medical Revive; a Lua error or
        -- explicit false is a provider failure, not permission to native-revive.
        return ok and result ~= false, 'qbox', not ok
    end

    if started('hospital') or started('qb-ambulancejob') then
        local ok = pcall(function() TriggerClientEvent('hospital:client:Revive', src) end)
        return ok, 'qbcore', not ok
    end

    if started('esx_ambulancejob') then
        local ok = pcall(function() TriggerClientEvent('esx_ambulancejob:revive', src) end)
        return ok, 'esx', not ok
    end

    -- Last resort: revive on the client with the game's own natives.
    local ok = pcall(function() TriggerClientEvent('rs-aidoc:client:nativeRevive', src) end)
    return ok, 'native', not ok
end

function RSAIDocBridge.Notify(src, message, kind, duration)
    if bridgeReady() then
        local ok = pcall(function()
            exports.rs_bridge:Notify(src, message, kind or 'inform', duration or 5000, 'Dr. Graves')
        end)
        if ok then return end
    end
    TriggerClientEvent('chat:addMessage', src, { args = { 'Dr. Graves', message } })
end
