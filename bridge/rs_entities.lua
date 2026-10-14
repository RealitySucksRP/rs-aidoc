-- =============================================================================
-- VENDORED FROM rs_bridge -- DO NOT EDIT HERE
-- =============================================================================
-- Verbatim copy of rs_bridge/client/entities.lua.
--
-- It lives inside this resource so the resource has NO hard load-time
-- dependency on rs_bridge. '@rs_bridge/client/entities.lua' in client_scripts is
-- resolved by FiveM at load, which means the resource will not start at all
-- when rs_bridge is missing -- fine on the RS servers, wrong for a resource
-- that ships to other people.
--
-- Every FiveM resource gets its own Lua state, so this copy cannot collide with
-- a running rs_bridge: the RSBridge global is per-resource.
--
-- To update: re-copy from rs_bridge rather than editing this file, so the two
-- do not silently drift.
-- =============================================================================

RSBridge = RSBridge or {}

-- =====================================================================
-- Networked entity ownership
--
-- Under OneSync an entity created with isNetwork = true is registered on
-- the server, and ONLY the client that currently owns it may delete it.
-- Calling DeleteEntity without ownership silently does nothing: the entity
-- stays registered server-side forever. A resource that spawns and despawns
-- networked peds/vehicles/props in a loop therefore leaks an entity per
-- cycle, and the server degrades until it dies.
--
-- This was the proven cause of the rs-phone open/close crash and the
-- rs-weaponshops target-practice crash. These helpers exist so every RS
-- resource fixes it the same way instead of hand-rolling the dance.
--
-- Pure natives, so this is framework-agnostic and safe on Qbox, QBCore
-- and ESX alike.
-- =====================================================================

local DEFAULT_TIMEOUT = 500

-- Once our owning resource begins stopping, yielding is unsafe: a Wait() may
-- never resume because the Lua VM is already being torn down, which would
-- abandon the rest of the cleanup and leak every remaining entity.
--
-- Resources route teardown through the same cleanup functions they use during
-- normal play, so the call sites cannot tell which context they are in. This
-- flag lets them stay unchanged and still degrade to non-blocking automatically.
--
-- This file is listed FIRST in each consumer's client_scripts, so this handler
-- registers first and therefore runs before the resource's own stop handler.
local stopping = false

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then stopping = true end
end)

local function isNetworked(entity)
    if not NetworkGetEntityIsNetworked then return false end
    local ok, networked = pcall(NetworkGetEntityIsNetworked, entity)
    return ok and networked == true
end

local function alive(entity)
    return entity and entity ~= 0 and DoesEntityExist(entity)
end

--- Take network ownership of an entity so it can be safely deleted/modified.
--- @param entity number
--- @param timeoutMs number|nil milliseconds to keep asking. Pass 0 to make a
---        single non-blocking request and return immediately -- required from
---        onResourceStop, where a Wait() may never resume because the Lua VM
---        is already being torn down.
--- @return boolean owned
local function RequestEntityControl(entity, timeoutMs)
    if not alive(entity) then return false end
    if not isNetworked(entity) then return true end
    if NetworkHasControlOfEntity(entity) then return true end

    local budget = tonumber(timeoutMs) or DEFAULT_TIMEOUT
    if stopping then budget = 0 end
    if budget <= 0 then
        NetworkRequestControlOfEntity(entity)
        return NetworkHasControlOfEntity(entity)
    end

    local deadline = GetGameTimer() + budget
    while GetGameTimer() < deadline do
        NetworkRequestControlOfEntity(entity)
        if NetworkHasControlOfEntity(entity) then return true end
        Wait(0)
    end
    return NetworkHasControlOfEntity(entity)
end

--- Delete one entity, taking ownership first when it is networked.
--- Safe to call with nil, 0, or an already-deleted handle.
--- @param entity number
--- @param timeoutMs number|nil see RequestEntityControl. Pass 0 on resource stop.
--- @return boolean deleted
local function DeleteEntitySafe(entity, timeoutMs)
    if not alive(entity) then return true end

    RequestEntityControl(entity, timeoutMs)

    if DoesEntityExist(entity) then
        pcall(function() SetEntityAsMissionEntity(entity, true, true) end)
        pcall(function() DeleteEntity(entity) end)
    end

    if DoesEntityExist(entity) then
        -- Ownership never arrived. Drop our mission claim so the engine can
        -- reap it instead of it lingering pinned for the rest of the session.
        pcall(function() SetEntityAsNoLongerNeeded(entity) end)
        return false
    end
    return true
end

--- Delete many entities against ONE shared deadline.
---
--- Always prefer this over looping DeleteEntitySafe: a per-entity timeout
--- multiplies, so tearing down 12 peds at 500ms each would stall the thread
--- for six seconds. Here the whole batch shares the budget.
--- @param entities table array of entity handles
--- @param timeoutMs number|nil total budget for the batch. Pass 0 on resource stop.
--- @return number deleted, number failed
local function DeleteEntitiesSafe(entities, timeoutMs)
    if type(entities) ~= 'table' then return 0, 0 end

    -- pairs, not ipairs: callers build these as literals like
    -- { phantomPed, phantomVeh }, and a nil first handle makes ipairs stop
    -- immediately -- pending stays empty and every later entity leaks silently.
    -- The pending list below is built densely, so its own ipairs loops are fine.
    local pending = {}
    for _, entity in pairs(entities) do
        if alive(entity) then pending[#pending + 1] = entity end
    end
    if #pending == 0 then return 0, 0 end

    local budget = tonumber(timeoutMs) or DEFAULT_TIMEOUT
    if stopping then budget = 0 end
    if budget <= 0 then
        for _, entity in ipairs(pending) do
            if isNetworked(entity) and not NetworkHasControlOfEntity(entity) then
                NetworkRequestControlOfEntity(entity)
            end
        end
    else
        local deadline = GetGameTimer() + budget
        local outstanding = true
        while outstanding and GetGameTimer() < deadline do
            outstanding = false
            for _, entity in ipairs(pending) do
                if DoesEntityExist(entity)
                    and isNetworked(entity)
                    and not NetworkHasControlOfEntity(entity) then
                    NetworkRequestControlOfEntity(entity)
                    outstanding = true
                end
            end
            if outstanding then Wait(0) end
        end
    end

    local deleted, failed = 0, 0
    for _, entity in ipairs(pending) do
        -- Control is already resolved above; 0 keeps this pass non-blocking.
        if DeleteEntitySafe(entity, 0) then deleted = deleted + 1 else failed = failed + 1 end
    end

    if failed > 0 then
        local warn = ('DeleteEntitiesSafe: %d/%d entities could not be deleted (no ownership)')
            :format(failed, #pending)
        if RSBridge.debug then RSBridge.debug(warn) else print('[rs_bridge] ' .. warn) end
    end
    return deleted, failed
end

-- =====================================================================
-- Scripted camera teardown
--
-- RenderScriptCams(false, true, N, ...) starts an N-millisecond eased blend
-- back to gameplay. Calling DestroyCam in the same frame frees the camera the
-- blend is still reading from -- on GTA V Enhanced that is a hard crash. This
-- was the proven cause of the hospital check-in crash.
--
-- The handle is released only after the blend has actually finished. On
-- resource stop the blend is skipped entirely and the camera torn down at
-- once, because a deferred thread would never get to run.
-- =====================================================================

--- @param cam number camera handle
--- @param easeMs number|nil blend duration; 0/nil tears down immediately
local function ReleaseScriptCam(cam, easeMs)
    local ease = tonumber(easeMs) or 0

    local function destroy()
        if cam and DoesCamExist(cam) then
            pcall(function() SetCamActive(cam, false) end)
            pcall(function() DestroyCam(cam, false) end)
        end
    end

    if stopping or ease <= 0 then
        pcall(function() RenderScriptCams(false, false, 0, true, true) end)
        destroy()
        return
    end

    pcall(function() RenderScriptCams(false, true, ease, true, true) end)
    CreateThread(function()
        Wait(ease + 60)   -- clear the blend, plus a frame of margin
        destroy()
    end)
end

RSBridge.RequestEntityControl = RequestEntityControl
RSBridge.DeleteEntitySafe = DeleteEntitySafe
RSBridge.DeleteEntitiesSafe = DeleteEntitiesSafe
RSBridge.ReleaseScriptCam = ReleaseScriptCam

-- This file is dual-mode.
--
-- PREFERRED: consumers add '@rs_bridge/client/entities.lua' to their own
-- client_scripts. The code then runs inside the consumer's Lua VM, so the
-- Wait() in the control loop yields that resource's own thread -- no
-- cross-resource call, no load-order dependency. Call RSBridge.DeleteEntitiesSafe.
--
-- FALLBACK: exports.rs_bridge:DeleteEntitiesSafe(...). Works, but yielding
-- across a resource boundary is fragile, so prefer the include.
--
-- Exports are only registered when this actually IS rs_bridge; otherwise an
-- including resource would advertise bridge exports it does not own.
if GetCurrentResourceName() == 'rs_bridge' then
    exports('RequestEntityControl', RequestEntityControl)
    exports('DeleteEntitySafe', DeleteEntitySafe)
    exports('DeleteEntitiesSafe', DeleteEntitiesSafe)
    exports('ReleaseScriptCam', ReleaseScriptCam)
end
