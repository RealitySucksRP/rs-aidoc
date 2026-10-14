RSAIDocBridge = {}

-- ------------------------------------------------------------ native fallback
--
-- rs_bridge is OPTIONAL and stays preferred. Without these, IsPlayerDown always
-- returned false on the client, so the death UI never came up for a player on a
-- server that had not installed rs_bridge.

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
    -- qbx_core FIRST: it declares provide 'qb-core', so checking qb-core first
    -- misidentifies a Qbox server as QBCore.
    if started('qbx_core') then frameworkCache = 'qbox'
    elseif started('qb-core') then frameworkCache = 'qbcore'
    elseif started('es_extended') then frameworkCache = 'esx'
    else frameworkCache = 'standalone' end
    return frameworkCache
end

-- Read provider data through its actual client API when possible. Qbox also
-- publishes its player data via the compatibility SetPlayerData event; retain a
-- resource-owned cache so a missing/changed export never breaks the death UI.
local cachedQboxData
RegisterNetEvent('QBCore:Player:SetPlayerData', function(data)
    if nativeFramework() ~= 'qbox' then return end
    if type(data) == 'table' then cachedQboxData = data end
end)
AddEventHandler('QBCore:Client:OnPlayerUnload', function()
    cachedQboxData = nil
end)

local function nativePlayerData()
    local fw = nativeFramework()

    if fw == 'qbox' then
        -- The export exists in current qbx_core source, although it is omitted
        -- from the public client-exports index. Failure is not fatal.
        local ok, data = pcall(function() return exports.qbx_core:GetPlayerData() end)
        if ok and type(data) == 'table' then return data end
        return cachedQboxData
    elseif fw == 'qbcore' then
        local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
        if ok and core and core.Functions and core.Functions.GetPlayerData then
            local got, data = pcall(function() return core.Functions.GetPlayerData() end)
            if got and type(data) == 'table' then return data end
        end
    elseif fw == 'esx' then
        local ok, core = pcall(function() return exports.es_extended:getSharedObject() end)
        if ok and core and core.GetPlayerData then
            local got, data = pcall(function() return core.GetPlayerData() end)
            if got and type(data) == 'table' then return data end
        end
    end

    return nil
end

function RSAIDocBridge.Framework()
    if Config.UseExternalBridge == true and started('rs_bridge') then
        local ok, value = pcall(function()
            return exports.rs_bridge:GetFramework()
        end)
        if ok and value and value ~= 'standalone' then return value end
    end
    return nativeFramework()
end

function RSAIDocBridge.GetPlayerData()
    if Config.UseExternalBridge == true and started('rs_bridge') then
        local ok, value = pcall(function()
            return exports.rs_bridge:GetPlayerData()
        end)
        if ok and value then return value end
    end
    return nativePlayerData()
end


function RSAIDocBridge.IsPlayerDown()
    if Config.UseExternalBridge == true and started('rs_bridge') then
        local ok, value = pcall(function()
            return exports.rs_bridge:IsPlayerDown()
        end)
        if ok and value ~= nil then return value == true end
    end

    local data = nativePlayerData()
    local meta = data and data.metadata or nil
    if meta and (meta.isdead == true or meta.inlaststand == true or meta.dead == true) then
        return true
    end

    -- LocalPlayer state is what qbx_medical and several ambulance scripts set,
    -- and it is also true for a plain unhandled death.
    local state = LocalPlayer and LocalPlayer.state or nil
    if state and (state.isDead == true or state.dead == true or state.laststand == true) then
        return true
    end

    return IsEntityDead(PlayerPedId())
end

-- Death-screen timers. nil means "this provider does not publish a clock", which
-- for qb-ambulancejob and esx_ambulancejob also means they are drawing their own
-- countdown already. The death readout only renders a line it actually receives,
-- so those setups never end up with two timers on screen.
local function bridgeNumber(name)
    if Config.UseExternalBridge ~= true or GetResourceState('rs_bridge') ~= 'started' then return nil end
    local ok, value = pcall(function()
        return exports.rs_bridge[name](exports.rs_bridge)
    end)
    if not ok then return nil end
    return tonumber(value)
end

function RSAIDocBridge.GetDeathTime()
    return bridgeNumber('GetDeathTime')
end

function RSAIDocBridge.GetLaststandTime()
    return bridgeNumber('GetLaststandTime')
end

function RSAIDocBridge.GetRespawnHoldTime()
    return bridgeNumber('GetRespawnHoldTime')
end

function RSAIDocBridge.Notify(message, kind, duration)
    if Config.UseExternalBridge == true and GetResourceState('rs_bridge') == 'started' then
        local ok = pcall(function()
            exports.rs_bridge:Notify(message, kind or 'inform', duration or 5000, 'Dr. Graves')
        end)
        if ok then return end
    end
    TriggerEvent('chat:addMessage', { args = { 'Dr. Graves', message } })
end

local progressRun

function RSAIDocBridge.CancelProgress()
    local run = progressRun
    if not run then return end
    progressRun = nil
    if run.provider == 'progressbar' and not run.finished then pcall(function() exports.progressbar:Cancel(true) end) end
end

function RSAIDocBridge.Progress(data)
    if progressRun then return false end
    local run = { started = GetGameTimer(), duration = math.max(1, tonumber(data.duration) or 1000) }
    progressRun = run
    if Config.UseExternalBridge == true and GetResourceState('rs_bridge') == 'started' then
        local ok, result = pcall(function() return exports.rs_bridge:ProgressBar(data) end)
        if progressRun ~= run then return false end
        if ok then progressRun = nil; return result ~= false end
    end
    if GetResourceState('progressbar') == 'started' then
        run.provider = 'progressbar'
        local ok, accepted = pcall(function()
            return exports.progressbar:Progress({
                name = 'rs_aidoc_treatment', label = data.label, duration = run.duration,
                useWhileDead = data.useWhileDead == true, canCancel = false,
                controlDisables = { disableMovement = data.disableMove == true,
                    disableCarMovement = data.disableMove == true,
                    disableMouse = false, disableCombat = data.disableCombat == true }
            }, function(cancelled)
                if not run.forcedStop then run.cancelled = cancelled == true end
                run.finished = true
            end)
        end)
        if not ok or accepted == false then run.provider = nil; run.finished = false; run.cancelled = false end
    end
    -- A local HUD covers missing or busy progress providers.
    while progressRun == run and GetGameTimer() - run.started < run.duration do
        if data.valid and not data.valid() then RSAIDocBridge.CancelProgress(); return false end
        if run.finished and run.cancelled then progressRun = nil; return false end
        if not run.provider then
            local fraction = math.min(1.0, (GetGameTimer() - run.started) / run.duration)
            DrawRect(0.5, 0.89, 0.32, 0.06, 10, 14, 12, 220)
            DrawRect(0.34 + 0.16 * fraction, 0.915, 0.32 * fraction, 0.004, 125, 190, 80, 255)
            SetTextFont(0); SetTextScale(0.30, 0.30); SetTextColour(240, 245, 235, 255); SetTextCentre(true)
            BeginTextCommandDisplayText('STRING'); AddTextComponentSubstringPlayerName(data.label or 'Dr. Graves is treating you...')
            EndTextCommandDisplayText(0.5, 0.875)
        end
        if data.disableCombat then DisablePlayerFiring(PlayerId(), true) end
        if data.disableMove then
            DisableControlAction(0, 21, true) -- sprint
            DisableControlAction(0, 30, true) -- horizontal movement
            DisableControlAction(0, 31, true) -- vertical movement
            DisableControlAction(0, 32, true) -- forward
            DisableControlAction(0, 33, true) -- backward
            DisableControlAction(0, 34, true) -- left
            DisableControlAction(0, 35, true) -- right
        end
        Wait(run.provider and 50 or 0)
    end
    if progressRun ~= run then return false end
    local callbackDeadline = GetGameTimer() + 2000
    while run.provider and not run.finished and progressRun == run and GetGameTimer() < callbackDeadline do
        if data.valid and not data.valid() then RSAIDocBridge.CancelProgress(); return false end
        Wait(50)
    end
    if progressRun ~= run then return false end
    if run.provider and not run.finished then
        run.forcedStop = true
        pcall(function() exports.progressbar:Cancel(true) end)
    end
    progressRun = nil
    return not run.cancelled
end

-- Last-resort revive, fired by the server only when no ambulance script was
-- detected (see RSAIDocBridge.RevivePlayer). A server running qbx_medical,
-- qb-ambulancejob or esx_ambulancejob never reaches this -- letting their own
-- revive run keeps their death state in sync, which this cannot do.
RegisterNetEvent('rs-aidoc:client:nativeRevive', function()
    -- Never accept same-context calls to a server-owned revive event.
    if source ~= 65535 then return end
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)

    NetworkResurrectLocalPlayer(coords.x, coords.y, coords.z, heading, true, false)
    SetPlayerInvincible(PlayerId(), false)
    ClearPedBloodDamage(ped)
    SetEntityHealth(ped, GetEntityMaxHealth(ped))

    if LocalPlayer and LocalPlayer.state then
        LocalPlayer.state:set('isDead', false, true)
        LocalPlayer.state:set('dead', false, true)
    end
end)
