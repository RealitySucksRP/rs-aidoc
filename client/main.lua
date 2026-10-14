local active = nil
local requesting = false
local pendingToken
local spawnResult
local relocationResult
local relocationVehicleKept
local requestGeneration = 0
local departAfterTreatment -- forward declaration: used by cancellation path above its definition

local function rescueActive(token)
    return active and active.token == token and not active.denied
        and not active.completed and not active.departing
end

local firearmGroups = {
    [joaat('GROUP_PISTOL')] = true,
    [joaat('GROUP_SMG')] = true,
    [joaat('GROUP_RIFLE')] = true,
    [joaat('GROUP_MG')] = true,
    [joaat('GROUP_SHOTGUN')] = true,
    [joaat('GROUP_SNIPER')] = true,
}

local function requestModel(model)
    local hash = type(model) == 'number' and model or joaat(model)
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local timeout = GetGameTimer() + 10000
    while not HasModelLoaded(hash) and GetGameTimer() < timeout do Wait(25) end
    if not HasModelLoaded(hash) then return nil end
    return hash
end

local function requestAnim(dict, timeoutMs, valid)
    RequestAnimDict(dict)
    local timeout = GetGameTimer() + math.max(500, tonumber(timeoutMs) or 3000)
    while not HasAnimDictLoaded(dict) and GetGameTimer() < timeout and (not valid or valid()) do Wait(25) end
    return HasAnimDictLoaded(dict)
end

local function localDead()
    if RSAIDocBridge.IsPlayerDown() then return true end

    local ped = PlayerPedId()
    if IsEntityDead(ped) or GetEntityHealth(ped) <= 0 then return true end

    local data = RSAIDocBridge.GetPlayerData()
    if not data then return false end

    local metadata = data.metadata
    if metadata and (metadata.isdead == true or metadata.inlaststand == true or metadata.dead == true) then
        return true
    end

    -- Current ESX Legacy exposes its ambulance death state on player data.
    return data.dead == true
end

local function classifyTrauma()
    local ped = PlayerPedId()
    local source = GetPedSourceOfDeath(ped)
    if source and source ~= 0 and DoesEntityExist(source) and IsEntityAPed(source) then
        if GetEntityModel(source) == joaat('u_m_y_zombie_01') then
            return 'zombie'
        end
    end

    local cause = GetPedCauseOfDeath(ped)
    if cause == joaat('WEAPON_RUN_OVER_BY_CAR') or cause == joaat('WEAPON_RAMMED_BY_CAR') then return 'vehicle' end
    if cause == joaat('WEAPON_DROWNING') or cause == joaat('WEAPON_DROWNING_IN_VEHICLE') then return 'drowning' end
    if cause == joaat('WEAPON_FALL') then return 'fall' end
    if cause == joaat('WEAPON_FIRE') or cause == joaat('WEAPON_MOLOTOV') or cause == joaat('WEAPON_PETROLCAN') then return 'fire' end

    local group = GetWeapontypeGroup(cause)
    if firearmGroups[group] then return 'ballistic' end
    if group == joaat('GROUP_HEAVY') then return 'explosion' end
    return 'generic'
end

local function nearestRoad(loc)
    local found, node = GetClosestVehicleNode(loc.x, loc.y, loc.z, 1, 3.0, 0)
    if found and node and math.abs(node.z - loc.z) <= 8.0 then return node end
    return nil
end

local function findSpawn(loc)
    local minR, maxR = tonumber(Config.Dispatch.SpawnRadiusMin) or 50.0,
        tonumber(Config.Dispatch.SpawnRadiusMax) or 90.0
    local best, heading, bestScore = nil, nil, math.huge
    -- Select an actual drivable node. Reject cliff/highway levels above or below
    -- the patient; a random node found on the first attempt may be inaccessible.
    for _ = 1, 24 do
        local radius = minR + math.random() * math.max(0, maxR - minR)
        local angle = math.random() * math.pi * 2.0
        local x, y = loc.x + math.cos(angle) * radius, loc.y + math.sin(angle) * radius
        local found, pos, direction = GetClosestVehicleNodeWithHeading(x, y, loc.z, 1, 3.0, 0)
        if found and pos and math.abs(pos.z - loc.z) <= 12.0 then
            local distance = #(pos - loc)
            if distance >= 18.0 and distance <= maxR + 25.0 then
                local score = math.abs(distance - (minR + maxR) * 0.5)
                if score < bestScore then best, heading, bestScore = pos, direction, score end
            end
        end
    end
    if best then return best, heading end
    local fallback = nearestRoad(loc)
    if fallback and #(fallback - loc) >= 15.0 then
        return fallback, GetEntityHeading(PlayerPedId())
    end
    -- The server validates spawn proximity; never claim a raw player-relative
    -- offset is drivable when the map contains no road data.
    return nil, nil
end

local function patientRoadGoal(loc)
    local node = nearestRoad(loc)
    if not node then return nil, math.huge end
    return node, #(node - loc)
end

--- @param immediate boolean|nil true when called from onResourceStop, where a
--- Wait() may never resume because the Lua VM is already being torn down.
local function cleanup(immediate)
    local previous = active
    active = nil
    pendingToken, spawnResult, relocationResult, relocationVehicleKept = nil, nil, nil, nil
    requesting = false
    requestGeneration = requestGeneration + 1
    RSAIDocMedical.Clear()
    RSAIDocBridge.CancelProgress()
    RSAIDocAudio.Stop()
    RSAIDocAudio.EndSession()
    RSAIDocAudio.SetSpeaker(nil)
    if previous then
        if previous.ped and DoesEntityExist(previous.ped) then FreezeEntityPosition(previous.ped, false) end
        if previous.blip and DoesBlipExist(previous.blip) then RemoveBlip(previous.blip) end
        -- The doctor ped and ambulance are both created networked, so they can
        -- only be deleted by the client that owns them. A bare DeleteEntity
        -- no-ops without ownership and leaks the pair on every single call.
        RSBridge.DeleteEntitiesSafe({ previous.ped, previous.vehicle }, immediate and 0 or nil)
        if not immediate then TriggerServerEvent('rs-aidoc:server:responderDeparted', previous.token) end
    end
end

local function makeBattered(vehicle)
    if not Config.Dispatch.BatteredVehicle then return end
    SetVehicleDirtLevel(vehicle, 15.0)
    SetVehicleBodyHealth(vehicle, 720.0)
    SetVehicleEngineHealth(vehicle, 860.0)
    SmashVehicleWindow(vehicle, 1)
    SmashVehicleWindow(vehicle, 3)
    SetVehicleDoorBroken(vehicle, 5, true)
end

local function protectDoctor(doc)
    if not doc or not DoesEntityExist(doc) then return end

    SetBlockingOfNonTemporaryEvents(doc, true)
    SetPedCanBeDraggedOut(doc, false)
    SetPedCanBeKnockedOffVehicle(doc, 1)

    if Config.Dispatch.InvincibleDoctor then
        -- Invincibility alone prevents health loss but does not stop every hit
        -- reaction. These companion flags keep attacks, critical hits and
        -- ragdolls from killing Graves or interrupting the CPR animation.
        SetEntityInvincible(doc, true)
        SetEntityCanBeDamaged(doc, false)
        SetPedDiesWhenInjured(doc, false)
        SetPedSuffersCriticalHits(doc, false)
        SetPedCanBeTargetted(doc, false)
        SetPedCanRagdoll(doc, false)
        SetPedCanRagdollFromPlayerImpact(doc, false)
    end
end

local function relocationEnabled()
    -- Missing means enabled so an older carried-over config still gets the
    -- safety recovery that used to be hard-coded as FailsafeSeconds.
    return Config.Dispatch.RelocateIfUnreachable ~= false
end

local function relocationWaitMs()
    -- FailsafeSeconds is retained as a read-only compatibility fallback for
    -- servers that update client/main.lua without replacing their config.lua.
    local seconds = tonumber(Config.Dispatch.RelocateAfterSeconds)
        or tonumber(Config.Dispatch.FailsafeSeconds)
        or 90
    return math.max(1, seconds) * 1000
end

local function findNearbyPatientPosition(player)
    local patient = GetEntityCoords(player)
    local distance = math.min(3.0, math.max(2.0, tonumber(Config.Dispatch.RelocateDistance) or 3.0))
    local offsets = {
        { distance, 0.75 },
        { -distance, 0.75 },
        { distance, -0.75 },
        { -distance, -0.75 },
    }

    -- Prefer a navmesh-safe point on the same floor as the patient. The height
    -- check prevents rooftop/interior rescues from snapping Graves to the road
    -- or terrain far below the player.
    for _, offset in ipairs(offsets) do
        local candidate = GetOffsetFromEntityInWorldCoords(player, offset[1], offset[2], 0.0)
        local found, safe = GetSafeCoordForPed(candidate.x, candidate.y, candidate.z, true, 16)
        if found and safe then
            local dx, dy = safe.x - patient.x, safe.y - patient.y
            local horizontal = math.sqrt(dx * dx + dy * dy)
            if horizontal >= 1.25 and horizontal <= distance + 0.25
                and math.abs(safe.z - patient.z) <= 1.0 then
                return safe
            end
        end
    end

    -- The patient area is already streamed. If the navmesh cannot provide a
    -- point (common in custom interiors), keep the patient's floor height and
    -- use a simple player-relative offset instead.
    local fallback = GetOffsetFromEntityInWorldCoords(player, distance, 0.75, 0.0)
    return vector3(fallback.x, fallback.y, patient.z)
end

-- Force the configured driving style onto the ped's LIVE drive task.
--
-- TaskVehicleDriveToCoordLongrange takes a style argument but is the cross-map
-- pathfinder and drives largely to its own conservative rules -- which is why
-- an ambulance configured to ignore traffic lights still sits at them.
--
-- SetDriveTaskDrivingStyle applies to whatever drive task the ped currently
-- has, whichever native created it, so the style stops being advisory. The
-- cruise speed is set for the same reason: the task's own speed argument gets
-- clamped by the pathfinder on long routes.
local function enforceDriveStyle(ped, speed)
    if not ped or not DoesEntityExist(ped) then return end
    local style = tonumber(Config.Dispatch.DrivingStyle) or 786980
    pcall(function()
        SetDriveTaskDrivingStyle(ped, style)
        SetDriveTaskCruiseSpeed(ped, tonumber(speed) or tonumber(Config.Dispatch.DriveSpeed) or 21.0)
    end)
end

local function relocateDoctorToPatient(reason)
    if not relocationEnabled() or not active or (active.relocated and reason ~= 'final_approach') or active.relocating then
        return false
    end

    local token = active.token
    local doc = active.ped
    local vehicle = active.vehicle
    if not doc or not DoesEntityExist(doc) then return false end

    active.relocating = true

    if active.blip and DoesBlipExist(active.blip) then RemoveBlip(active.blip) end
    active.blip = nil

    -- Extract the existing doctor before deleting the ambulance. Deleting the
    -- occupied vehicle first can invalidate or strand its ped occupant.
    if vehicle and DoesEntityExist(vehicle) then
        if Config.Dispatch.UseSiren then SetVehicleSiren(vehicle, false) end
        TaskVehicleTempAction(doc, vehicle, 27, 500)
        TaskLeaveVehicle(doc, vehicle, 16)
        local exitDeadline = GetGameTimer() + 1500
        while rescueActive(token) and IsPedInVehicle(doc, vehicle, false)
            and GetGameTimer() < exitDeadline do
            Wait(50)
        end
    end

    if not rescueActive(token) or not DoesEntityExist(doc) then return false end

    local player = PlayerPedId()
    local destination = findNearbyPatientPosition(player)
    local patient = GetEntityCoords(player)
    relocationResult, relocationVehicleKept = nil, nil
    TriggerServerEvent('rs-aidoc:server:requestRelocation', token, reason,
        { x = destination.x, y = destination.y, z = destination.z + 0.05 })
    local authorizationDeadline = GetGameTimer() + 5000
    while rescueActive(token) and relocationResult == nil and GetGameTimer() < authorizationDeadline do Wait(50) end
    if not rescueActive(token) then return false end
    if relocationResult ~= true then active.relocating = false; return false end
    RequestCollisionAtCoord(destination.x, destination.y, destination.z)
    ClearPedTasksImmediately(doc)
    SetEntityCoordsNoOffset(doc, destination.x, destination.y, destination.z + 0.05, false, false, false)
    SetEntityVelocity(doc, 0.0, 0.0, 0.0)
    SetEntityCollision(doc, true, true)
    FreezeEntityPosition(doc, false)
    SetEntityVisible(doc, true, false)
    SetEntityHeading(doc, GetHeadingFromVector_2d(patient.x - destination.x, patient.y - destination.y))
    Wait(0)

    -- Use the SERVER decision: client vehicle coords may lag behind the server
    -- after a OneSync migration. Never disagree on whether to delete it.
    if vehicle and DoesEntityExist(vehicle) and not relocationVehicleKept then
        RSBridge.DeleteEntitySafe(vehicle)
    end
    if not rescueActive(token) then return false end
    if not relocationVehicleKept then active.vehicle = nil end

    if not rescueActive(token) or not DoesEntityExist(doc) then return false end
    active.relocated = true
    active.relocating = false

    if Config.Debug then
        print(('[rs-aidoc] relocated existing doctor near patient reason=%s token=%s')
            :format(tostring(reason), tostring(token)))
    end
    RSAIDocBridge.Notify('Dr. Graves could not reach the scene and appeared nearby.', 'inform', 5000)
    return true
end

local function sceneFailure(token, reason)
    if not rescueActive(token) then return end
    if active.stage == 'awaiting_medical_confirmation' then
        active.sceneFailure = reason
        print('[rs-aidoc] scene interrupted after medical dispatch: ' .. reason)
        return
    end
    local doc = active.ped
    active.denied, active.sceneFailure = true, reason
    active.animDict, active.animClip, active.animTransition = nil, nil, false
    if doc and DoesEntityExist(doc) then FreezeEntityPosition(doc, false) end
    RSAIDocBridge.CancelProgress()
    print(('[rs-aidoc] SCENE FAILED stage=%s reason=%s'):format(tostring(active.stage), reason))
    TriggerServerEvent('rs-aidoc:server:cancelDispatch', token, 'scene_failed:' .. reason)
    RSAIDocAudio.Stop()
    RSAIDocAudio.Play('departure')
    CreateThread(function()
        if active and active.token == token then departAfterTreatment(token) end
    end)
end

-- Restored treatment choreography from the known working build.
-- The OneSync responder is already close enough after the approach stage.
-- Chest alignment and exact hand-bone distances are *visual diagnostics*,
-- not permission gates: different patient states, interiors and zombie rigs
-- make fixed 0.3m tolerances unsuitable for gameplay.
local function chestPosition(patient)
    return GetPedBoneCoords(patient, tonumber(Config.Treatment.ChestBone) or 24816, 0.0, 0.0, 0.0)
end

local function playDoctorAnim(token, primaryDict, primaryClip, fallbackDict, fallbackClip)
    if not rescueActive(token) then return false end
    local context, doc = active, active.ped
    if not DoesEntityExist(doc) then return false end
    context.animTransition = true
    context.animDict, context.animClip = nil, nil
    context.animEpoch = (context.animEpoch or 0) + 1
    local epoch = context.animEpoch
    -- Request control opportunistically but do not require it before attempting
    -- TaskPlayAnim. That was one of the Codex-only rejection conditions.
    local control = RSBridge.RequestEntityControl(doc, 450)
    if not rescueActive(token) or active ~= context then return false end
    if Config.Debug and not control then
        print('[rs-aidoc] treatment ped ownership pending; trying animation anyway')
    end
    local seen = {}
    local lastSubmittedDict, lastSubmittedClip
    for _, choice in ipairs({ { primaryDict, primaryClip }, { fallbackDict, fallbackClip } }) do
        local dict, clip = choice[1], choice[2]
        local key = tostring(dict) .. '/' .. tostring(clip)
        if dict and clip and not seen[key] then
            seen[key] = true
            if requestAnim(dict, Config.Treatment.AnimationLoadTimeoutMs, function()
                return rescueActive(token) and active == context
            end) then
                if not rescueActive(token) or active ~= context then return false end
                FreezeEntityPosition(doc, false)
                TaskPlayAnim(doc, dict, clip, 4.0, -4.0, -1, 1, 0.0, false, false, false)
                lastSubmittedDict, lastSubmittedClip = dict, clip
                local deadline = GetGameTimer() + math.max(850,
                    tonumber(Config.Treatment.AnimationStartTimeoutMs) or 1000)
                repeat
                    Wait(75)
                    if not rescueActive(token) or active ~= context or not DoesEntityExist(doc) then return false end
                    if IsEntityPlayingAnim(doc, dict, clip, 3) then
                        context.animDict, context.animClip = dict, clip
                        context.animSettledAt, context.animRetries = GetGameTimer(), 0
                        context.animTransition = false
                        if Config.Debug then
                            print(('[rs-aidoc] treatment animation %s (%s/%s)'):format(tostring(context.stage), dict, clip))
                        end
                        return true
                    end
                until GetGameTimer() >= deadline
            end
            print(('[rs-aidoc] treatment clip did not start: %s / %s; trying fallback'):format(dict, clip))
        end
    end
    if active == context then
        context.animTransition = false
        if lastSubmittedDict then
            -- Match the original build's best-effort semantics. Networked GTA
            -- animation state can report a late start; do not abort a paid,
            -- authorized rescue on a cosmetic confirmation timeout.
            context.animDict, context.animClip = lastSubmittedDict, lastSubmittedClip
            context.animSettledAt, context.animRetries = GetGameTimer(), 0
            context.animPlaying = false
            print(('[rs-aidoc] animation submitted but not confirmed yet: %s / %s'):format(
                lastSubmittedDict, lastSubmittedClip))
            return true
        end
    end
    return false
end

local function holdDoctorAnim(token, durationMs)
    local deadline = GetGameTimer() + math.max(0, durationMs)
    while rescueActive(token) and GetGameTimer() < deadline do
        if not DoesEntityExist(active.ped) then return false end
        Wait(math.min(200, math.max(1, deadline - GetGameTimer())))
    end
    return rescueActive(token)
end

-- The old choreography simply turned toward the patient and animated.
-- Avoid GetSafeCoordForPed, exact navmesh arrival and mandatory hand-bone checks.
-- Those fail for downed/ragdolled peds and MLO interiors before kneeling begins.
local function alignDoctorToChest(token)
    if not rescueActive(token) then return false end
    local context, doc, patient = active, active.ped, PlayerPedId()
    if not DoesEntityExist(doc) or not DoesEntityExist(patient) then return false end
    context.scenePatient = patient
    local here = GetEntityCoords(doc)
    local chest = chestPosition(patient)
    context.chestAnchor = chest
    context.chestDistance = math.sqrt((here.x - chest.x)^2 + (here.y - chest.y)^2)
    -- The player was already within the arrival radius when the server
    -- authorized the procedure; gently face them rather than resuming a path.
    ClearPedTasks(doc)
    TaskTurnPedToFaceEntity(doc, patient, 1000)
    Wait(1050)
    if not rescueActive(token) or active ~= context then return false end
    if DoesEntityExist(doc) and DoesEntityExist(patient) then
        local pos, target = GetEntityCoords(doc), chestPosition(patient)
        SetEntityHeading(doc, GetHeadingFromVector_2d(target.x - pos.x, target.y - pos.y))
        context.chestAnchor = target
    end
    return true
end

-- Animation recovery never cancels an already-authorized rescue for a pose
-- mismatch. Try to resume the known clip, logging persistent native failures.
local function monitorDoctorScene(token)
    local context, doc = active, active.ped
    CreateThread(function()
        local lostAt, lastAttempt = nil, 0
        while rescueActive(token) and active == context and DoesEntityExist(doc) do
            local dict, clip = context.animDict, context.animClip
            if dict and clip and not context.animTransition
                and GetGameTimer() - (context.animSettledAt or 0) >= 1000 then
                if IsEntityPlayingAnim(doc, dict, clip, 3) then
                    lostAt = nil
                    context.animPlaying = true
                else
                    context.animPlaying = false
                    lostAt = lostAt or GetGameTimer()
                    if GetGameTimer() - lostAt >= 1200 and GetGameTimer() - lastAttempt >= 2500 then
                        if (context.animRetries or 0) < (tonumber(Config.Treatment.AnimationRecoveryAttempts) or 3) then
                            context.animRetries = (context.animRetries or 0) + 1
                            RSBridge.RequestEntityControl(doc, 350)
                            if not rescueActive(token) or active ~= context then return end
                            TaskPlayAnim(doc, dict, clip, 4.0, -4.0, -1, 1, 0.0, false, false, false)
                            lastAttempt, lostAt = GetGameTimer(), nil
                            if Config.Debug then
                                print(('[rs-aidoc] resumed %s animation (attempt %d)'):format(
                                    tostring(context.stage), context.animRetries))
                            end
                        elseif not context.animationWarned then
                            context.animationWarned = true
                            print('[rs-aidoc] animation interrupted repeatedly; medical treatment continues')
                        end
                    end
                end
            else
                lostAt = nil
            end
            Wait(350)
        end
    end)
end

local function startProcedure(token, trauma, mode)
    if not rescueActive(token) then return end
    local doc, patient = active.ped, PlayerPedId()
    if not DoesEntityExist(doc) or not DoesEntityExist(patient) then
        TriggerServerEvent('rs-aidoc:server:cancelDispatch', token, 'doctor_or_patient_missing')
        cleanup()
        return
    end
    protectDoctor(doc)
    ResetPedMovementClipset(doc, 0.5)
    CreateThread(function()
        while rescueActive(token) do
            if not localDead() then
                for _, control in ipairs({ 21, 30, 31, 32, 33, 34, 35, 22, 23 }) do DisableControlAction(0, control, true) end
            end
            Wait(0)
        end
    end)
    active.stage = 'aligning_to_chest'
    if not alignDoctorToChest(token) then sceneFailure(token, 'doctor_or_patient_missing'); return end

    -- The exact visible examination -> CPR sequence from the working version.
    -- Config defaults to the original working clips; alternate animations remain
    -- selectable and are tried automatically if the primary cannot play.
    active.stage = 'kneel_examination'
    if not playDoctorAnim(token, Config.Treatment.KneelAnimDict, Config.Treatment.KneelAnim,
        Config.Treatment.FallbackKneelAnimDict, Config.Treatment.FallbackKneelAnim) then
        sceneFailure(token, 'kneel_animation_failed'); return
    end
    if not rescueActive(token) then return end
    monitorDoctorScene(token)
    RSAIDocAudio.WaitForFinish()
    if not rescueActive(token) then return end
    RSAIDocAudio.Play(trauma)
    local timeStarted = GetGameTimer()
    local spoken = RSAIDocAudio.WaitForFinish()
    if not rescueActive(token) then return end
    local minimumExamine = math.max(1000, tonumber(Config.Treatment.ExamineMs) or 3500)
    local elapsed = GetGameTimer() - timeStarted
    if elapsed < minimumExamine and not holdDoctorAnim(token, minimumExamine - elapsed) then return end
    if not rescueActive(token) then return end

    active.stage = 'cpr_transition'
    if not playDoctorAnim(token, Config.Treatment.CPRAnimDict, Config.Treatment.CPRAnim,
        Config.Treatment.FallbackCPRAnimDict, Config.Treatment.FallbackCPRAnim) then
        sceneFailure(token, 'cpr_animation_failed'); return
    end
    if not rescueActive(token) then return end
    active.stage = 'cpr_treatment'
    -- Chest bone is a visual aim reference, not a hard 30cm gate.
    active.chestAnchor = chestPosition(patient)

    local talking, voiceBusy = true, false
    CreateThread(function()
        Wait(900)
        while talking and rescueActive(token) do
            voiceBusy = true
            RSAIDocAudio.Play(mode == 'revive' and 'cpr' or 'generic')
            RSAIDocAudio.WaitForFinish()
            voiceBusy = false
            if not talking then break end
            local pause = math.random(Config.Treatment.CPRDialogueMinMs, Config.Treatment.CPRDialogueMaxMs)
            while talking and pause > 0 and rescueActive(token) do
                local step = math.min(100, pause)
                Wait(step)
                pause = pause - step
            end
        end
    end)

    local treatmentStart = GetGameTimer()
    local completed = RSAIDocBridge.Progress({
        label = mode == 'revive' and ('Dr. Graves is treating %s trauma...'):format(trauma)
            or 'Dr. Graves is treating your injuries...',
        duration = Config.Treatment.ReviveMs,
        canCancel = false,
        useWhileDead = true,
        disableCombat = true,
        disableMove = mode ~= 'revive',
        valid = function() return rescueActive(token) end,
    })
    local minimum = math.max(1000, tonumber(Config.Treatment.ReviveMs) or 20000)
    -- Progress providers may return instantly; and animation tasks can be
    -- interrupted by OneSync or nearby AI. Maintain CPR for the entire period.
    while completed and rescueActive(token) and GetGameTimer() - treatmentStart < minimum do
        Wait(350)
    end
    talking = false
    while voiceBusy and rescueActive(token) do Wait(50) end
    if not rescueActive(token) then return end
    if not completed then
        TriggerServerEvent('rs-aidoc:server:cancelDispatch', token, 'treatment_cancelled')
        RSAIDocAudio.Stop()
        RSAIDocAudio.Play('departure')
        CreateThread(function() departAfterTreatment(token) end)
        return
    end
    local expected = 1050 + math.max(0, tonumber(Config.Treatment.ExamineMs) or 3500) + minimum
    local safeAt = (active.treatmentAuthorizedAt or treatmentStart) + expected + 250
    while rescueActive(token) and GetGameTimer() < safeAt do Wait(75) end
    if not rescueActive(token) then return end
    active.stage = 'awaiting_medical_confirmation'
    -- Do NOT ClearPedTasks here. That used to stop CPR BEFORE the server had
    -- confirmed the revive. The doctor stands up after the result arrives.
    TriggerServerEvent('rs-aidoc:server:completeTreatment', token)
end

local function requestTreatment(token)
    if not rescueActive(token) or active.treatmentRequested then return end
    active.treatmentRequested = true
    active.trauma = classifyTrauma()
    active.treatmentGate = nil
    local doctor = active.ped
    CreateThread(function()
        if not rescueActive(token) then return end
        RSBridge.RequestEntityControl(doctor, 1500)
        local deadline = GetGameTimer() + 10000
        while rescueActive(token) and not active.procedureStarted and GetGameTimer() < deadline do
            -- Witnessed positions are corroboration only. Server still requires
            -- this session's own responder plus nearby server-observed ambulance
            -- (or server-approved relocation), matching patient and bucket.
            local player = PlayerPedId()
            local observedDoctor = DoesEntityExist(doctor) and GetEntityCoords(doctor) or nil
            local observedPatient = DoesEntityExist(player) and GetEntityCoords(player) or nil
            local observation = observedDoctor and observedPatient and {
                doctorNet = NetworkGetNetworkIdFromEntity(doctor),
                doctor = { x = observedDoctor.x, y = observedDoctor.y, z = observedDoctor.z },
                patient = { x = observedPatient.x, y = observedPatient.y, z = observedPatient.z },
            } or nil
            TriggerServerEvent('rs-aidoc:server:beginTreatment', token, active.trauma, observation)
            Wait(250)
        end
        if rescueActive(token) and not active.procedureStarted then
            local gate = active.treatmentGate or 'no_server_authorization'
            print(('[rs-aidoc] treatment authorization timed out | gate=%s | patientDown=%s | doctorExists=%s')
                :format(gate, tostring(localDead()), tostring(DoesEntityExist(doctor))))
            TriggerServerEvent('rs-aidoc:server:cancelDispatch', token, 'treatment_authorization_timeout:' .. gate)
            RSAIDocBridge.Notify('Dr. Graves could not start treatment (' .. gate .. '). Check F8 and server logs.', 'error')
            -- Do not instantly erase an existing actor; let the regular
            -- denial handler play the departure, or use a local bounded fallback.
            local waitUntil = GetGameTimer() + 2500
            while rescueActive(token) and GetGameTimer() < waitUntil do Wait(50) end
            if rescueActive(token) then
                active.denied = true
                RSAIDocAudio.Stop()
                RSAIDocAudio.Play('departure')
                departAfterTreatment(token)
            end
        end
    end)
end

local function doctorOnFoot()
    if not active then return end
    local token = active.token
    local doc = active.ped
    if not DoesEntityExist(doc) then return end
    RSBridge.RequestEntityControl(doc, 1500)
    if not rescueActive(token) then return end
    active.stage = 'approaching_patient'

    local anim = 'move_m@drunk@verydrunk'
    RequestAnimSet(anim)
    local timeout = GetGameTimer() + 5000
    while rescueActive(token) and not HasAnimSetLoaded(anim) and GetGameTimer() < timeout do Wait(25) end
    if not rescueActive(token) then return end
    if HasAnimSetLoaded(anim) then SetPedMovementClipset(doc, anim, 0.5) end

    -- Dispatch may still be speaking when the ambulance reaches the scene.
    RSAIDocAudio.WaitForFinish()
    if not rescueActive(token) then return end
    RSAIDocAudio.Play('arrival')
    -- Fallback keeps an upgraded install working if config.lua was carried over.
    local deadline = GetGameTimer() + (Config.Dispatch.ApproachTimeoutSeconds or 60) * 1000
    while rescueActive(token) and DoesEntityExist(doc) do
        -- Re-read the ped every pass: a respawn hands out a new handle and the
        -- stale one reports garbage coords, which sends Graves to nowhere.
        local player = PlayerPedId()
        local loc = GetEntityCoords(player)
        local dloc = GetEntityCoords(doc)
        local dist = #(loc - dloc)
        if dist <= Config.Dispatch.ArrivalPedDistance then
            active.stage = 'patient_reached'
            ClearPedTasks(doc)
            TaskTurnPedToFaceEntity(doc, player, 1000)
            requestTreatment(token)
            return
        end

        if GetGameTimer() > deadline then
            if relocateDoctorToPatient('approach_timeout') then
                doc = active.ped
                deadline = GetGameTimer() + math.max(1,
                    tonumber(Config.Dispatch.ApproachTimeoutSeconds) or 60) * 1000
            else
                -- LAST RESORT: close the gap, do not delete the doctor.
                --
                -- This branch used to call cleanup(), which deletes the ped --
                -- so a Graves who could not physically reach the patient simply
                -- vanished mid-walk after sixty seconds. To the player on the
                -- floor that is the resource breaking, not a story beat.
                --
                -- The final placement is a separate, server-authorized retry.
                if not rescueActive(token) then return end
                if relocateDoctorToPatient('final_approach') and rescueActive(token) and DoesEntityExist(doc) then
                    TaskTurnPedToFaceEntity(doc, player, 1000)
                    requestTreatment(token)
                    return
                end

                if not rescueActive(token) then return end

                TriggerServerEvent('rs-aidoc:server:cancelDispatch', active.token, 'approach_timeout')
                RSAIDocBridge.Notify('Dr. Graves lost your trail and shuffled off.', 'error')
                cleanup()
                return
            end
        end

        -- TaskFollowNavMeshToCoord MUST be allowed to finish a path. The old
        -- 750ms re-task loop constantly restarted navigation at fences/kerbs.
        local tick = GetGameTimer()
        local moved = not active.walkGoal or #(loc - active.walkGoal) > 3.0
        local noProgress = active.walkLastDistance and dist >= active.walkLastDistance - 0.65
        if not active.walkLastSample or tick - active.walkLastSample >= 3500 then
            if noProgress then active.walkStall = (active.walkStall or 0) + 1
            else active.walkStall = 0 end
            active.walkLastDistance, active.walkLastSample = dist, tick
        end
        if not active.walkTaskAt or moved or tick - active.walkTaskAt >= 6500
            or (active.walkStall or 0) >= 2 then
            if (active.walkStall or 0) >= 2 then
                -- Try a different approach to the player's shoulder when the
                -- direct navmesh route reports no progress.
                local side = findNearbyPatientPosition(player)
                TaskFollowNavMeshToCoord(doc, side.x, side.y, side.z, 1.65, 6500, 0.65, false, 4)
                active.walkStall = 0
            else
                TaskFollowNavMeshToCoord(doc, loc.x, loc.y, loc.z, 1.65, 7000, 0.85, false, 4)
            end
            active.walkGoal, active.walkTaskAt = loc, tick
        end
        Wait(350)
    end
end

local function spawnResponder(payload)
    local generation = requestGeneration
    pendingToken = payload.token
    local player = PlayerPedId()
    local loc = GetEntityCoords(player)
    local vehHash = requestModel(Config.Dispatch.VehicleModel)
    local pedHash = requestModel(Config.Dispatch.PedModel)
    if pendingToken ~= payload.token or requestGeneration ~= generation then return end
    if not vehHash or not pedHash then
        TriggerServerEvent('rs-aidoc:server:cancelDispatch', payload.token, 'invalid_model')
        RSAIDocBridge.Notify('Dr. Graves could not materialize. Check responder models.', 'error')
        cleanup()
        return
    end

    local spawn, heading = findSpawn(loc)
    if not spawn then
        TriggerServerEvent('rs-aidoc:server:cancelDispatch', payload.token, 'no_vehicle_spawn_node')
        RSAIDocBridge.Notify('No safe road is available to dispatch Dr. Graves.', 'error')
        cleanup()
        return
    end
    spawnResult = nil
    TriggerServerEvent('rs-aidoc:server:spawnResponder', payload.token,
        { x = spawn.x, y = spawn.y, z = spawn.z, heading = heading })
    local deadline = GetGameTimer() + 10000
    while pendingToken == payload.token and generation == requestGeneration and not spawnResult
        and GetGameTimer() < deadline do Wait(50) end
    if pendingToken ~= payload.token or generation ~= requestGeneration then return end
    if not spawnResult then
        TriggerServerEvent('rs-aidoc:server:cancelDispatch', payload.token, 'spawn_timeout')
        cleanup()
        return
    end
    local vehicle, doc
    deadline = GetGameTimer() + 15000
    repeat
        if pendingToken ~= payload.token or generation ~= requestGeneration then return end
        vehicle, doc = NetToVeh(spawnResult.vehicleNet), NetToPed(spawnResult.doctorNet)
        if not DoesEntityExist(vehicle) or not DoesEntityExist(doc) then Wait(50) end
    until (DoesEntityExist(vehicle) and DoesEntityExist(doc)) or GetGameTimer() >= deadline
    if not DoesEntityExist(vehicle) or not DoesEntityExist(doc)
        or not RSBridge.RequestEntityControl(vehicle, 1500) or not RSBridge.RequestEntityControl(doc, 1500) then
        TriggerServerEvent('rs-aidoc:server:cancelDispatch', payload.token, 'control_unavailable')
        cleanup()
        return
    end
    if pendingToken ~= payload.token or generation ~= requestGeneration then return end
    SetPedIntoVehicle(doc, vehicle, -1)

    SetEntityAsMissionEntity(vehicle, true, true)
    SetVehicleOnGroundProperly(vehicle)
    SetVehicleNumberPlateText(vehicle, tostring(Config.Dispatch.Plate or 'AIDOC'):sub(1, 8))
    SetVehicleEngineOn(vehicle, true, true, false)
    makeBattered(vehicle)
    if Config.Dispatch.UseSiren then SetVehicleSiren(vehicle, true) end

    if DoesEntityExist(doc) then
        -- An emergency driver, not a civilian one. Without these he drives to
        -- the configured style but with default civilian competence.
        pcall(function()
            SetDriverAbility(doc, tonumber(Config.Dispatch.DriverAbility) or 1.0)
            SetDriverAggressiveness(doc, tonumber(Config.Dispatch.DriverAggressiveness) or 1.0)
            -- Do not abandon the vehicle or flee at the first scare; a panicked
            -- responder bailing mid-route reads to the player as 'stuck'.
            SetBlockingOfNonTemporaryEvents(doc, true)
            SetPedFleeAttributes(doc, 0, false)
            SetPedCanBeDraggedOut(doc, false)
        end)
    end
    if not DoesEntityExist(doc) then
        RSBridge.DeleteEntitySafe(vehicle)
        TriggerServerEvent('rs-aidoc:server:cancelDispatch', payload.token, 'ped_spawn_failed')
        requesting = false
        return
    end

    SetEntityAsMissionEntity(doc, true, true)
    protectDoctor(doc)

    local blip = AddBlipForEntity(vehicle)
    SetBlipSprite(blip, 280)
    SetBlipColour(blip, 2)
    SetBlipFlashes(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString('Dr. Graves - Infected Medical Unit')
    EndTextCommandSetBlipName(blip)

    active = {
        token = payload.token,
        vehicle = vehicle,
        ped = doc,
        blip = blip,
        started = GetGameTimer(),
        relocated = false,
        relocating = false,
    }
    pendingToken = nil
    SetModelAsNoLongerNeeded(vehHash)
    SetModelAsNoLongerNeeded(pedHash)

    -- Lock one explicit AI Doc persona before the first line. Every audio stage
    -- in this rescue remains on this exact persona branch.
    local persona = RSAIDocAudio.BeginSession()
    RSAIDocAudio.SetSpeaker(doc)
    if Config.Debug then
        print(('[rs-aidoc] locked audio persona %s for token %s')
            :format(tostring(persona), tostring(payload.token)))
    end
    RSAIDocAudio.Play('dispatch')
    RSAIDocBridge.Notify(('Dr. Graves is en route. Treatment estimate: $%d.'):format(payload.price), 'inform', 6000)

    local goal, roadDistance = patientRoadGoal(loc)
    active.driveGoal = goal
    active.driveGoalPatient = loc
    if Config.Debug then print(('[rs-aidoc] route initialized roadOffset=%.1fm'):format(roadDistance)) end
    if goal then
        TaskVehicleDriveToCoordLongrange(doc, vehicle, goal.x, goal.y, goal.z,
            Config.Dispatch.DriveSpeed, Config.Dispatch.DrivingStyle, 6.5)
        enforceDriveStyle(doc, Config.Dispatch.DriveSpeed)
    end
    active.stage = 'ambulance_en_route'

    CreateThread(function()
        while rescueActive(payload.token) and DoesEntityExist(doc) do
            if not DoesEntityExist(vehicle) then
                TriggerServerEvent('rs-aidoc:server:cancelDispatch', payload.token, 'vehicle_lost')
                cleanup()
                return
            end
            local tick = GetGameTimer()
            local ploc = GetEntityCoords(PlayerPedId())
            local vloc = GetEntityCoords(vehicle)
            local dist = #(ploc - vloc)
            local goal = active.driveGoal
            local goalDistance = goal and #(goal - vloc) or math.huge
            local maxRoadOffset = tonumber(Config.Dispatch.UnreachableNodeDistance) or 45.0
            local roadOffset = goal and #(goal - ploc) or math.huge
            local arrival = tonumber(Config.Dispatch.ArrivalVehicleDistance) or 14.0

            -- Arrive either beside the patient OR on the nearest accessible
            -- road and finish on foot. Waiting for the ambulance to drive off
            -- road into a building made its AI keep circling the block.
            if dist <= arrival or (goal and goalDistance <= 12.0 and roadOffset <= maxRoadOffset) then
                active.stage = 'ambulance_arrived'
                if Config.Dispatch.UseSiren then SetVehicleSiren(vehicle, false) end
                TaskVehicleTempAction(doc, vehicle, 27, 850)
                Wait(900)
                if not rescueActive(payload.token) then return end
                TaskLeaveVehicle(doc, vehicle, 0)
                local leaveTimeout = GetGameTimer() + 4500
                while rescueActive(payload.token) and IsPedInVehicle(doc, vehicle, false)
                    and GetGameTimer() < leaveTimeout do Wait(100) end
                if not rescueActive(payload.token) then return end
                if IsPedInVehicle(doc, vehicle, false) then TaskLeaveVehicle(doc, vehicle, 16); Wait(600) end
                if not rescueActive(payload.token) then return end
                if IsPedInVehicle(doc, vehicle, false) then
                    if not relocateDoctorToPatient('exit_blocked') then
                        TriggerServerEvent('rs-aidoc:server:cancelDispatch', payload.token, 'unable_to_exit_vehicle')
                        cleanup()
                        return
                    end
                end
                active.stage = 'doctor_on_foot'
                doctorOnFoot()
                return
            end

            if not active.reachChecked then
                active.reachChecked = true
                if not goal or roadOffset > maxRoadOffset then
                    -- No drivable road near the victim: authorized rescue
                    -- relocates only the doctor, with a bounded retry.
                    if relocateDoctorToPatient('no_road_access') then
                        active.stage = 'doctor_on_foot'
                        doctorOnFoot()
                        return
                    end
                end
            end
            if not rescueActive(payload.token) then return end

            -- A player can move during the response. Refresh the GPS waypoint
            -- only when their nearest road node changes materially.
            if active.driveGoalPatient and #(ploc - active.driveGoalPatient) > 15.0 then
                local newGoal = patientRoadGoal(ploc)
                if newGoal and (not goal or #(goal - newGoal) > 8.0) then
                    active.driveGoal = newGoal
                    goal = newGoal
                    active.driveGoalPatient = ploc
                    TaskVehicleDriveToCoordLongrange(doc, vehicle, goal.x, goal.y, goal.z,
                        Config.Dispatch.DriveSpeed, Config.Dispatch.DrivingStyle, 6.5)
                    enforceDriveStyle(doc, Config.Dispatch.DriveSpeed)
                    active.driveTaskAt = tick
                    active.lastProgressDistance, active.lastProgressAt = nil, tick
                    active.stuckRetries = 0
                    if Config.Debug then print('[rs-aidoc] ambulance waypoint updated for moving patient') end
                elseif newGoal then
                    -- Do not repeatedly query the road graph when the player
                    -- moved within the same road node's catchment area.
                    active.driveGoalPatient = ploc
                end
            end
            -- Mark genuine progress toward the mapped road destination, not
            -- just speed: vehicles can spin in place or circle a block quickly.
            local progressDistance = goal and #(goal - vloc) or dist
            if not active.lastProgressDistance or progressDistance < active.lastProgressDistance - 3.5 then
                active.lastProgressDistance, active.lastProgressAt = progressDistance, tick
                active.stuckRetries = 0
            end
            active.lastProgressAt = active.lastProgressAt or tick
            local stuckMs = (tonumber(Config.Dispatch.StuckSeconds) or 4) * 1000
            if not active.lastMotionPosition or #(vloc - active.lastMotionPosition) >= 1.5 then
                active.lastMotionPosition, active.lastMotionAt = vloc, tick
            end
            active.lastMotionAt = active.lastMotionAt or tick
            -- Taking a corner can temporarily increase distance to the target.
            -- Recover only a stationary route; the absolute route budget bounds circles.
            if tick - active.lastMotionAt >= stuckMs then
                active.stuckRetries = (active.stuckRetries or 0) + 1
                active.lastProgressAt = tick
                active.lastMotionAt = tick
                if Config.Debug then
                    print(('[rs-aidoc] route stall retry=%d distance=%.1fm speed=%.2f goal=%.1fm')
                        :format(active.stuckRetries, dist, GetEntitySpeed(vehicle), progressDistance))
                end
                if active.stuckRetries <= (tonumber(Config.Dispatch.StuckRetries) or 2) and goal then
                    -- Reverse briefly to release a blocked collision, then
                    -- re-plan once. Never issue the drive task every tick.
                    if GetEntitySpeed(vehicle) < (tonumber(Config.Dispatch.StuckSpeed) or 0.6) then
                        TaskVehicleTempAction(doc, vehicle, 22, 700)
                        Wait(750)
                        if not rescueActive(payload.token) then return end
                    end
                    TaskVehicleDriveToCoordLongrange(doc, vehicle, goal.x, goal.y, goal.z,
                        Config.Dispatch.DriveSpeed, Config.Dispatch.DrivingStyle, 6.5)
                    enforceDriveStyle(doc, Config.Dispatch.DriveSpeed)
                else
                    if relocateDoctorToPatient('stuck') then
                        active.stage = 'doctor_on_foot'
                        doctorOnFoot()
                        return
                    end
                end
            end
            if not rescueActive(payload.token) then return end
            if tick - active.started >= relocationWaitMs() then
                if relocateDoctorToPatient('drive_timeout') then
                    active.stage = 'doctor_on_foot'
                    doctorOnFoot()
                elseif rescueActive(payload.token) then
                    TriggerServerEvent('rs-aidoc:server:cancelDispatch', active.token, 'drive_timeout')
                    RSAIDocBridge.Notify('Dr. Graves could not reach the scene.', 'error')
                    cleanup()
                end
                return
            end
            Wait(500)
        end
    end)
end

local function departureDestination(vehicle)
    local vehicleLoc = GetEntityCoords(vehicle)
    local patientLoc = GetEntityCoords(PlayerPedId())
    local dx, dy = vehicleLoc.x - patientLoc.x, vehicleLoc.y - patientLoc.y
    local length = math.sqrt(dx * dx + dy * dy)

    if length < 0.1 then
        local forward = GetEntityForwardVector(vehicle)
        dx, dy = forward.x, forward.y
        length = math.sqrt(dx * dx + dy * dy)
    end
    if length < 0.1 then dx, dy, length = 1.0, 0.0, 1.0 end

    local distance = math.max(60.0, tonumber(Config.Dispatch.DepartureDriveDistance) or 160.0)
    local targetX = vehicleLoc.x + (dx / length) * distance
    local targetY = vehicleLoc.y + (dy / length) * distance
    local found, node = GetClosestVehicleNode(targetX, targetY, vehicleLoc.z, 1, 3.0, 0)
    if found and node then return node end
    return vector3(targetX, targetY, vehicleLoc.z)
end

local function leaveOnFoot(token, doc)
    if doc and DoesEntityExist(doc) then
        ResetPedMovementClipset(doc, 0.5)
        ClearPedTasks(doc)
        TaskWanderStandard(doc, 10.0, 10)
        SetPedKeepTask(doc, true)
    end

    local timeout = math.max(5, tonumber(Config.Dispatch.DepartureOnFootTimeoutSeconds) or 25) * 1000
    local deadline = GetGameTimer() + timeout
    while active and active.token == token and doc and DoesEntityExist(doc)
        and GetGameTimer() < deadline do
        if #(GetEntityCoords(doc) - GetEntityCoords(PlayerPedId())) >= 35.0 then break end
        Wait(500)
    end
    if active and active.token == token then cleanup() end
end

departAfterTreatment = function(token)
    if not active or active.token ~= token or active.departing then return end
    active.departing = true
    -- Release the CPR loop and stand up BEFORE speaking the goodbye line.
    -- Otherwise Graves stays kneeling throughout two complete voice clips.
    local standingDoc = active.ped
    if standingDoc and DoesEntityExist(standingDoc) then
        RSBridge.RequestEntityControl(standingDoc, 1500)
        if not active or active.token ~= token then return end
        FreezeEntityPosition(standingDoc, false)
        ClearPedTasks(standingDoc)
        TaskStandStill(standingDoc, 600)
    end
    active.stage = 'standing_up'
    -- Finish the departure line before driving away or cleaning up the actor.
    RSAIDocAudio.WaitForFinish()
    if not active or active.token ~= token then return end
    local doc = active.ped
    local vehicle = active.vehicle

    if not doc or not DoesEntityExist(doc) then
        cleanup()
        return
    end
    protectDoctor(doc)

    local controlled = RSBridge.RequestEntityControl(doc, 1500)
    if not active or active.token ~= token then return end
    if Config.Dispatch.ReturnToVehicleAfterTreatment == false
        or not controlled or not vehicle or not DoesEntityExist(vehicle) then
        leaveOnFoot(token, doc)
        return
    end

    active.stage = 'running_back_to_ambulance'
    ResetPedMovementClipset(doc, 0.5)
    ClearPedTasks(doc) -- release kneel/CPR; GTA blends to stand before running
    SetVehicleDoorsLocked(vehicle, 1)
    if Config.Dispatch.UseSiren then SetVehicleSiren(vehicle, false) end
    -- Run to the vehicle first; TaskEnterVehicle from 20m away usually walks.
    -- Time-box the navmesh path so a blocked door cannot trap the session.
    local near = GetEntityCoords(vehicle)
    local runUntil = GetGameTimer() + math.max(3,
        tonumber(Config.Dispatch.DepartureRunTimeoutSeconds) or 14) * 1000
    local runTarget = GetOffsetFromEntityInWorldCoords(vehicle, -1.5, -0.5, 0.0)
    if #(GetEntityCoords(doc) - near) > 5.0 then
        TaskFollowNavMeshToCoord(doc, runTarget.x, runTarget.y, runTarget.z, 3.0, 10000, 2.1, false, 4)
        while active and active.token == token and DoesEntityExist(vehicle) and DoesEntityExist(doc)
            and GetGameTimer() < runUntil and #(GetEntityCoords(doc) - near) > 4.0 do
            SetPedMoveRateOverride(doc, 1.2)
            Wait(350)
        end
    end
    if not active or active.token ~= token then return end
    active.stage = 'boarding_ambulance'
    TaskEnterVehicle(doc, vehicle, -1, -1, 2.6, 1, 0)

    local enterSeconds = math.max(2, tonumber(Config.Dispatch.DepartureEnterTimeoutSeconds) or 12)
    local enterDeadline = GetGameTimer() + enterSeconds * 1000
    local nextRetry = GetGameTimer() + 4000
    while active and active.token == token and DoesEntityExist(doc) and DoesEntityExist(vehicle)
        and not IsPedInVehicle(doc, vehicle, false) and GetGameTimer() < enterDeadline do
        if GetGameTimer() >= nextRetry then
            TaskEnterVehicle(doc, vehicle, -1, -1, 1.6, 1, 0)
            nextRetry = GetGameTimer() + 4000
        end
        Wait(200)
    end

    if active and active.token == token and DoesEntityExist(doc) and DoesEntityExist(vehicle)
        and not IsPedInVehicle(doc, vehicle, false)
        and Config.Dispatch.DepartureWarpIntoVehicle ~= false
        and IsVehicleSeatFree(vehicle, -1) then
        -- Last-resort recovery for a blocked ambulance door or broken navmesh.
        -- The normal enter animation always gets the configured first attempt.
        SetPedIntoVehicle(doc, vehicle, -1)
        Wait(0)
    end

    if not active or active.token ~= token then return end
    if not DoesEntityExist(doc) or not DoesEntityExist(vehicle)
        or not IsPedInVehicle(doc, vehicle, false) then
        leaveOnFoot(token, doc)
        return
    end

    active.stage = 'driving_away'
    for door = 0, 5 do SetVehicleDoorShut(vehicle, door, false) end
    SetVehicleHandbrake(vehicle, false)
    SetVehicleUndriveable(vehicle, false)
    SetVehicleEngineOn(vehicle, true, true, false)
    SetPedKeepTask(doc, true)

    local destination = departureDestination(vehicle)
    local speed = tonumber(Config.Dispatch.DepartureDriveSpeed) or 18.0
    local style = tonumber(Config.Dispatch.DepartureDrivingStyle)
        or tonumber(Config.Dispatch.DrivingStyle)
        or 786603
    TaskVehicleDriveToCoordLongrange(doc, vehicle, destination.x, destination.y, destination.z,
        speed, style, 8.0)

    local cleanupDistance = math.max(40.0,
        tonumber(Config.Dispatch.DepartureCleanupDistance) or 100.0)
    local driveSeconds = math.max(10, tonumber(Config.Dispatch.DepartureTimeoutSeconds) or 45)
    local driveDeadline = GetGameTimer() + driveSeconds * 1000
    while active and active.token == token and DoesEntityExist(doc) and DoesEntityExist(vehicle)
        and GetGameTimer() < driveDeadline do
        if #(GetEntityCoords(vehicle) - GetEntityCoords(PlayerPedId())) >= cleanupDistance then break end
        Wait(500)
    end

    if active and active.token == token then cleanup() end
end

local function requestAIDoc()
    if requesting or active then
        return RSAIDocBridge.Notify('Dr. Graves is already handling your case.', 'error')
    end
    if Config.RequireDead and not localDead() then
        return RSAIDocBridge.Notify('You need to be down before calling Dr. Graves.', 'error')
    end
    requesting = true
    requestGeneration = requestGeneration + 1
    local generation = requestGeneration
    TriggerServerEvent('rs-aidoc:server:requestDispatch', generation)
    SetTimeout(15000, function()
        if requesting and not active and not pendingToken and requestGeneration == generation then requesting = false end
    end)
end

RegisterCommand(Config.Command, requestAIDoc, false)
RegisterCommand('aidocdiag', function()
    if not active then print('[rs-aidoc] no active medical call'); return end
    local a = active
    local player = PlayerPedId()
    local docOK = a.ped and DoesEntityExist(a.ped)
    local carOK = a.vehicle and DoesEntityExist(a.vehicle)
    local dist = docOK and #(GetEntityCoords(a.ped) - GetEntityCoords(player)) or -1
    local vehDist = carOK and #(GetEntityCoords(a.vehicle) - GetEntityCoords(player)) or -1
    local playing = docOK and a.animDict and IsEntityPlayingAnim(a.ped, a.animDict, a.animClip, 3) or false
    print(('[rs-aidoc] stage=%s doctor=%.1fm car=%.1fm retry=%s animation=%s/%s playing=%s gate=%s')
        :format(tostring(a.stage), dist, vehDist, tostring(a.stuckRetries or 0),
            tostring(a.animDict), tostring(a.animClip), tostring(playing), tostring(a.treatmentGate)))
    if type(a.treatmentGateInfo) == 'table' then
        local info = a.treatmentGateInfo
        print(('[rs-aidoc] SERVER proximity doctor=%s car=%s clientReported=%s patientSyncGap=%s owner=%s')
            :format(tostring(info.doctor), tostring(info.ambulance), tostring(info.reported),
                tostring(info.patientSync), tostring(info.owner)))
    end
    local face = RSAIDocAudio.Diagnostics()
    print(('[rs-aidoc] chestBone=%s chestGap=%s handsGap=%s handsVertical=%s animFrame=%s transition=%s animRetries=%s sceneFailure=%s faceRequested=%s jawBone=%s model=%s')
        :format(tostring(Config.Treatment.ChestBone or 24818), tostring(a.chestDistance), tostring(a.handChestDistance),
            tostring(a.handVerticalGap), tostring(a.animLastTime), tostring(a.animTransition), tostring(a.animRetries or 0), tostring(a.sceneFailure),
            tostring(face.requested), tostring(face.jawBone), tostring(face.model)))
end, false)

RegisterNetEvent('rs-aidoc:client:dispatchApproved', function(payload)
    if source ~= 65535 then return end
    if type(payload) ~= 'table' or type(payload.token) ~= 'string' then return end
    if pendingToken == payload.token then return end
    if not requesting or active or payload.requestId ~= requestGeneration then
        TriggerServerEvent('rs-aidoc:server:cancelDispatch', payload.token, 'stale_approval')
        return
    end
    spawnResponder(payload)
end)

RegisterNetEvent('rs-aidoc:client:responderSpawned', function(token, data)
    if source == 65535 and token == pendingToken and type(data) == 'table'
        and type(data.vehicleNet) == 'number' and type(data.doctorNet) == 'number' then spawnResult = data end
end)
RegisterNetEvent('rs-aidoc:client:relocationResult', function(token, ok, reason, keepsVehicle)
    if source == 65535 and rescueActive(token) and active.relocating then
        relocationVehicleKept = keepsVehicle == true
        relocationResult = ok == true
    end
end)

RegisterNetEvent('rs-aidoc:client:dispatchDenied', function(reason, token, requestId)
    if source ~= 65535 then return end
    if token and token ~= pendingToken and (not active or active.token ~= token) then return end
    if requestId and requestId ~= requestGeneration then return end
    -- A denial can arrive mid-flow (expired session, payment gone, revive
    -- failed). The old handler called cleanup() here, visibly deleting Graves
    -- as he reached the patient. Keep cleanup for spawn/ownership failure, but
    -- let a responder who exists return to the ambulance and leave naturally.
    if Config.Debug then
        print(('[rs-aidoc] dispatch denied/cancelled by server reason=%s active=%s token=%s')
            :format(tostring(reason), tostring(active ~= nil), tostring(active and active.token)))
    end
    if active then
        if active.denied or active.completed then return end
        local token = active.token
        active.denied = true
        RSAIDocBridge.CancelProgress()
        RSAIDocAudio.Stop()
        CreateThread(function()
            Wait(250)
            if active and active.token == token then
                RSAIDocAudio.Play('departure')
                departAfterTreatment(token)
            end
        end)
    else
        pendingToken = nil
        requesting = false
    end
end)

-- Informational, bounded status from the server. Never lets a client decide
-- whether billing or a revive is authorized.
RegisterNetEvent('rs-aidoc:client:treatmentCheckFailed', function(token, reason, info)
    if source ~= 65535 or not rescueActive(token) or not active.treatmentRequested then return end
    if type(reason) ~= 'string' or #reason > 80 then return end
    active.treatmentGate = reason
    if type(info) == 'table' then active.treatmentGateInfo = info end
    if Config.Debug and active.loggedGate ~= reason then
        active.loggedGate = reason
        print(('[rs-aidoc] awaiting treatment authorization | reason=%s'):format(reason))
    end
end)

RegisterNetEvent('rs-aidoc:client:treatmentAuthorized', function(token, trauma, mode)
    if source ~= 65535 then return end
    if not active or active.token ~= token or active.procedureStarted or active.denied then return end
    active.procedureStarted = true
    active.treatmentAuthorizedAt = GetGameTimer()
    active.mode = mode == 'heal' and 'heal' or 'revive'
    active.treatmentGate = nil
    if Config.Debug then print('[rs-aidoc] treatment authorized by server; examination/CPR starting') end
    local treatmentMode = active.mode
    CreateThread(function() startProcedure(token, trauma, treatmentMode) end)
end)

RegisterNetEvent('rs-aidoc:client:treatmentComplete', function(token, price, provider, mode)
    if source ~= 65535 then return end
    if not active or active.token ~= token or active.completed or active.denied then return end
    active.completed = true
    active.stage = 'medical_complete'
    local context, doc = active, active.ped
    CreateThread(function()
        if doc and DoesEntityExist(doc) then
            local controlled = RSBridge.RequestEntityControl(doc, 1500)
            if active ~= context then return end
            if controlled then
                FreezeEntityPosition(doc, false)
                ClearPedTasks(doc)
                TaskStandStill(doc, 600)
            else
                print('[rs-aidoc] recovery confirmed but doctor control is pending for departure')
            end
        end
        if active ~= context then return end
        RSAIDocAudio.Play(mode == 'heal' and 'generic' or 'revive')
        RSAIDocBridge.Notify(('%s complete. Dr. Graves charged $%d.'):format(mode == 'heal' and 'Healing' or 'Revival', price), 'success', 6500)
        if Config.Debug then print(('[rs-aidoc] medical provider=%s trauma=%s'):format(tostring(provider), tostring(context.trauma))) end
        RSAIDocAudio.WaitForFinish()
        if active ~= context then return end
        Wait(800)
        if active ~= context then return end
        RSAIDocAudio.Play('departure')
        departAfterTreatment(token)
    end)
end)

RSAIDocMedical.CanHeal = function(token)
    return active and active.token == token and active.procedureStarted
        and not active.denied and not active.completed
end

-- Down-state prompt ---------------------------------------------------------
-- Players have no way to discover /medic on their own. While you are down and no
-- Graves call is running, advertise it here. Availability is answered by the
-- server so the prompt tells the truth about the EMS rule it will be judged by.

local hintDown = false
local hintAvailable = nil
local hintEmsOnline = 0

RegisterNetEvent('rs-aidoc:client:availability', function(available, emsOnline)
    if source ~= 65535 then return end
    hintAvailable = available == true
    hintEmsOnline = tonumber(emsOnline) or 0
end)

local function hintEnabled()
    return Config.DeathHint and Config.DeathHint.Enabled == true
end

-- Provider timers are read through exports, so they are sampled a few times a
-- second rather than every frame. A one-second countdown does not need more.
local timerCache = { at = 0, death = nil, laststand = nil, hold = nil }

local function refreshTimers()
    local now = GetGameTimer()
    if now - timerCache.at < 250 then return end
    timerCache.at = now
    timerCache.death = RSAIDocBridge.GetDeathTime()
    timerCache.laststand = RSAIDocBridge.GetLaststandTime()
    timerCache.hold = RSAIDocBridge.GetRespawnHoldTime()
end

local function hintLines()
    local cfg = Config.DeathHint
    local lines = {}

    if cfg.ShowRespawnTimer then
        refreshTimers()
        if timerCache.laststand and timerCache.laststand > 0 then
            lines[#lines + 1] = cfg.LaststandText:format(math.ceil(timerCache.laststand))
        elseif timerCache.death and timerCache.death > 0 then
            lines[#lines + 1] = cfg.RespawnText:format(math.ceil(timerCache.death))
        end
        if timerCache.hold then
            lines[#lines + 1] = cfg.HoldText
        end
    end

    if cfg.OnlyWhenNoEMS then
        -- Stay silent until the server has answered, rather than advertising
        -- Graves for a moment on a server that has medics on duty.
        if hintAvailable == true then
            lines[#lines + 1] = cfg.Text
        elseif hintAvailable == false then
            lines[#lines + 1] = cfg.EMSText
        end
    else
        lines[#lines + 1] = cfg.Text
    end

    return lines
end

local function drawDeathHint()
    local cfg = Config.DeathHint
    local lines = hintLines()
    if #lines == 0 then return end

    local x = cfg.X or 0.5
    local y = cfg.Y or 0.84
    local lh = cfg.LineHeight or 0.034

    -- Background first: GTA draws in call order, so a rect after the text hides it.
    if cfg.Background then
        DrawRect(x, y + (lh * (#lines - 1)) * 0.5 + 0.012, 0.42, lh * #lines + 0.024, 0, 0, 0, 120)
    end

    for index, line in ipairs(lines) do
        SetTextFont(cfg.Font or 4)
        SetTextScale(cfg.Scale or 0.42, cfg.Scale or 0.42)
        SetTextColour(255, 255, 255, 220)
        SetTextCentre(true)
        SetTextOutline()
        SetTextEntry('STRING')
        AddTextComponentSubstringPlayerName(line)
        DrawText(x, y + (index - 1) * lh)
    end
end

CreateThread(function()
    while true do
        Wait(750)
        if not hintEnabled() then
            hintDown = false
        else
            local down = (not active) and (not requesting) and localDead()
            if down and not hintDown then
                -- Just went down: ask once immediately so the first frame is right.
                hintAvailable = nil
                TriggerServerEvent('rs-aidoc:server:queryAvailability')
            end
            hintDown = down
        end
    end
end)

CreateThread(function()
    local lastQuery = 0
    while true do
        if hintDown then
            local now = GetGameTimer()
            local refresh = (tonumber(Config.DeathHint.RefreshSeconds) or 10) * 1000
            if now - lastQuery > refresh then
                lastQuery = now
                TriggerServerEvent('rs-aidoc:server:queryAvailability')
            end
            drawDeathHint()
            Wait(0)
        else
            lastQuery = 0
            Wait(300)
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then cleanup(true) end
end)

local function playerUnloaded()
    local token = active and active.token or pendingToken
    if token then TriggerServerEvent('rs-aidoc:server:cancelDispatch', token, 'player_unloaded') end
    cleanup()
end
AddEventHandler('QBCore:Client:OnPlayerUnload', playerUnloaded)
AddEventHandler('esx:onPlayerLogout', playerUnloaded)
