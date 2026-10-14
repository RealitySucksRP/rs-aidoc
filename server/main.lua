local sessions = {}
local cooldowns = {}
local availabilityQueries = {}

math.randomseed(os.time())

local function now()
    return os.time()
end

local function makeToken(src)
    return ('%s:%s:%s:%08x%08x'):format(src, now(), GetGameTimer(), math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
end

-- Length of the client-side procedure: face turn, examination, treatment bar.
-- Used to reject a client that claims completion early and to size the
-- janitor's grace period for a session that is already paid for.
local function expectedTreatmentMs()
    return 1200 + (tonumber(Config.Treatment.ExamineMs) or 0) + (tonumber(Config.Treatment.ReviveMs) or 0)
end

-- The client rescue flow has its own legitimate pre-treatment phases: model
-- loading, driving, exiting the ambulance and the on-foot approach.  The old
-- server timeout used Config.SessionTimeoutSeconds from the instant /medic was
-- accepted, which could expire while Graves was still walking toward the
-- patient.  dispatchDenied then made the client cleanup() both responder
-- entities, producing the visible "doctor and ambulance vanished" bug.
--
-- Keep SessionTimeoutSeconds as a configurable minimum, but never let the
-- server authorization window be shorter than the client flow it authorizes.
local function expectedDispatchSeconds()
    local configured = tonumber(Config.SessionTimeoutSeconds) or 180
    local drive = tonumber(Config.Dispatch and Config.Dispatch.RelocateAfterSeconds)
        or tonumber(Config.Dispatch and Config.Dispatch.FailsafeSeconds)
        or 90
    local approach = tonumber(Config.Dispatch and Config.Dispatch.ApproachTimeoutSeconds) or 60

    -- requestModel may spend up to 10s on the vehicle and another 10s on the
    -- doctor before active.started exists. The startup allowance also covers
    -- the server spawn reply, entity streaming/control, vehicle exit and recovery
    -- and normal frame/network jitter without allowing an abandoned call to
    -- live forever.
    local flowMinimum = drive + approach * 2 + 90
    return math.max(configured, flowMinimum)
end

local function isDead(src)
    if RSAIDocBridge.IsPlayerDown(src) then return true end

    local state = Player(src) and Player(src).state
    if state and (state.isDead == true or state.dead == true or state.laststand == true) then return true end

    local ped = GetPlayerPed(src)
    if ped and ped ~= 0 and DoesEntityExist(ped) and GetEntityHealth(ped) <= 0 then
        return true
    end

    local data = RSAIDocBridge.GetPlayerData(src)
    local metadata = data and data.metadata
    if metadata and (metadata.isdead == true or metadata.inlaststand == true or metadata.dead == true) then
        return true
    end

    return false
end

local function needsCare(src)
    return isDead(src) or RSAIDocMedical.IsInjured(src)
end

local function countEMS()
    local count = 0
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local job = RSAIDocBridge.GetJob(src)
        if job and Config.EMS.Jobs[job.name] then
            local onDuty = job.onduty
            if onDuty == nil then onDuty = job.onDuty end
            if not Config.EMS.OnDutyOnly or onDuty ~= false then
                count = count + 1
            end
        end
    end
    return count
end

local function canChargeWhileDown(src, account)
    local normalized = tostring(account or 'cash'):lower()
    if normalized ~= 'cash' and normalized ~= 'money' then return true end

    -- This Qbox install deliberately protects carried cash while the character
    -- is dead. Calling RemoveMoney anyway is guaranteed to fail and used to
    -- make the server deny treatment after Graves had already arrived, which
    -- made the client delete him in front of the patient. Bank remains billable
    -- by design. Respect the same convar here and select a usable account before
    -- the responder is ever dispatched.
    local framework = tostring(RSAIDocBridge.Framework() or 'standalone'):lower()
    if framework == 'qbx' or framework == 'qbx_core' then framework = 'qbox' end
    if framework == 'qbox'
        and GetConvarInt('qb_protect_cash_while_dead', 1) == 1
        and isDead(src) then
        return false
    end

    return true
end

local function choosePayment(src)
    if (tonumber(Config.Price) or 0) <= 0 then return 'free' end
    for _, account in ipairs(Config.PaymentPriority) do
        if canChargeWhileDown(src, account)
            and RSAIDocBridge.GetMoney(src, account) >= Config.Price then
            return account
        end
    end
    return nil
end

-- Refund only the original character; interrupted mutations stay in the journal.
local function refund(src, session, reason)
    if not session then return false end
    session.phase = 'refunding'
    return RSAIDocSettlements.Refund(src, session, reason)
end

local function deny(src, reason, kind, token, requestId)
    RSAIDocBridge.Notify(src, reason, kind or 'error', 6000)
    TriggerClientEvent('rs-aidoc:client:dispatchDenied', src, reason, token, requestId)
end

local function currentPatient(src, session)
    return sessions[src] == session and RSAIDocBridge.CharacterIdentity(src) == session.identity
        and GetPlayerRoutingBucket(src) == session.bucket
end

local function closeSession(src, session, reason, immediate)
    if sessions[src] == session then sessions[src] = nil end
    RSAIDocMedical.Cancel(src, session.token)
    if session.phase == 'charging' or session.phase == 'reviving' then
        RSAIDocSettlements.Review(session, reason .. ' during ' .. session.phase)
    elseif session.charged and session.phase ~= 'completed' and session.phase ~= 'refunding' then
        refund(src, session, reason)
    end
    if immediate then RSAIDocResponders.Delete(session) else RSAIDocResponders.Depart(session) end
end

-- Answers the down-state prompt. Cheap and read-only: it reports whether a /medic
-- call would be accepted right now under the same EMS rule requestDispatch uses.
RegisterNetEvent('rs-aidoc:server:queryAvailability', function()
    local src = source
    local tick = GetGameTimer()
    if availabilityQueries[src] and tick - availabilityQueries[src] < 1500 then return end
    availabilityQueries[src] = tick
    local emsOnline = countEMS()
    TriggerClientEvent('rs-aidoc:client:availability', src,
        emsOnline <= Config.EMS.MaxOnlineForAIDoc, emsOnline)
end)

RegisterNetEvent('rs-aidoc:server:requestDispatch', function(requestId)
    local src = source
    local t = now()

    if sessions[src] then
        -- A duplicate /medic request must NOT send dispatchDenied: that event
        -- tears down the already-authorized doctor's current patient session.
        RSAIDocBridge.Notify(src, 'A Graves response is already active for you.', 'inform', 3500)
        return
    end

    if cooldowns[src] and cooldowns[src] > t then
        return deny(src, ('Dr. Graves is sanitizing his tools. Try again in %d seconds.'):format(cooldowns[src] - t), nil, nil, requestId)
    end

    local identity = RSAIDocBridge.CharacterIdentity(src)
    if not identity then return deny(src, 'Load a character before requesting treatment.', nil, nil, requestId) end
    if not RSAIDocSettlements.Ready then return deny(src, 'The payment journal is unavailable.', nil, nil, requestId) end
    RSAIDocSettlements.Reconcile(src)
    if RSAIDocSettlements.HasPending(identity) then
        return deny(src, 'A previous treatment payment needs settlement. Contact an administrator.', nil, nil, requestId)
    end

    if Config.RequireDead and not isDead(src) then
        return deny(src, 'Dr. Graves currently requires a downed patient.', nil, nil, requestId)
    end
    if Config.RequireInjury ~= false and not needsCare(src) then
        return deny(src, 'Dr. Graves treats injured, laststand or dead patients, not healthy players.', nil, nil, requestId)
    end

    local emsOnline = countEMS()
    if emsOnline > Config.EMS.MaxOnlineForAIDoc then
        return deny(src, ('Real EMS is available (%d on duty). Try not to haunt them.'):format(emsOnline), 'inform', nil, requestId)
    end

    local account = choosePayment(src)
    if not account then
        return deny(src, ('Treatment requires $%d in a chargeable account (bank while down on protected Qbox).'):format(Config.Price), nil, nil, requestId)
    end

    local token = makeToken(src)
    if RSAIDocBridge.CharacterIdentity(src) ~= identity or sessions[src] then return end
    sessions[src] = {
        token = token,
        created = t,
        phase = 'dispatched',
        account = account,
        price = Config.Price,
        charged = false,
        identity = identity,
        bucket = GetPlayerRoutingBucket(src),
        requestId = type(requestId) == 'number' and requestId or nil,
    }
    cooldowns[src] = t + Config.CooldownSeconds

    TriggerClientEvent('rs-aidoc:client:dispatchApproved', src, {
        token = token,
        price = Config.Price,
        framework = RSAIDocBridge.Framework(),
        requestId = sessions[src].requestId,
    })
end)

RegisterNetEvent('rs-aidoc:server:spawnResponder', function(token, position)
    local src = source
    local session = sessions[src]
    if not session or session.token ~= token or session.phase ~= 'dispatched' or session.doctor then return end
    if not currentPatient(src, session) or now() - session.created > expectedDispatchSeconds() then
        closeSession(src, session, 'invalid spawn session', true)
        return deny(src, 'The response session ended.', nil, token)
    end
    session.phase = 'spawning'
    local ok, created = pcall(RSAIDocResponders.Create, src, session, position)
    if not ok or not created or not currentPatient(src, session) then
        closeSession(src, session, 'responder creation failed', true)
        return deny(src, 'Dr. Graves could not create a responder.', nil, token)
    end
    session.phase = 'dispatched'
    TriggerClientEvent('rs-aidoc:client:responderSpawned', src, token, {
        vehicleNet = session.vehicleNet, doctorNet = session.doctorNet
    })
end)

RegisterNetEvent('rs-aidoc:server:requestRelocation', function(token, reason, position)
    local src = source
    local session = sessions[src]
    if not session or session.token ~= token or session.phase ~= 'dispatched' or not currentPatient(src, session) then return end
    local ok, keepsVehicle = RSAIDocResponders.Relocate(src, session, reason, position)
    TriggerClientEvent('rs-aidoc:client:relocationResult', src, token, ok, reason, keepsVehicle)
end)

RegisterNetEvent('rs-aidoc:server:beginTreatment', function(token, trauma, observation)
    local src = source
    local session = sessions[src]
    if not session or session.token ~= token or session.phase ~= 'dispatched' then return end

    if not currentPatient(src, session) then
        closeSession(src, session, 'patient changed before treatment', true)
        return deny(src, 'The patient or routing bucket changed.', nil, token)
    end
    local responderOK, gateReason, gateDistance, gateOwner, gateInfo = RSAIDocResponders.Check(src, session, true, observation)
    if not responderOK then
        -- Keep legitimate approach/ownership races retryable, but report WHY
        -- authorization is withheld. Previously this returned silently until
        -- the client's ten-second timeout deleted Dr. Graves in front of you.
        local tick = GetGameTimer()
        if session.lastGate ~= gateReason or not session.lastGateAt
            or tick - session.lastGateAt >= 2000 then
            session.lastGate, session.lastGateAt = gateReason, tick
            TriggerClientEvent('rs-aidoc:client:treatmentCheckFailed', src, token, gateReason, gateInfo)
            if Config.Debug then
                print(('[rs-aidoc] beginTreatment waiting src=%d phase=%s gate=%s doc=%s car=%s clientDoc=%s patientSync=%s owner=%s')
                    :format(src, tostring(session.phase), gateReason,
                        tostring(gateDistance), tostring(gateInfo and gateInfo.ambulance),
                        tostring(gateInfo and gateInfo.reported), tostring(gateInfo and gateInfo.patientSync),
                        tostring(gateOwner)))
            end
        end
        return
    end
    session.lastGate = nil

    if Config.Debug and gateInfo and gateInfo.mode ~= 'server_doctor' then
        print(('[rs-aidoc] beginTreatment corroborated src=%s mode=%s doc=%s car=%s patientSync=%s'):format(
            src, gateInfo.mode, tostring(gateInfo.doctor), tostring(gateInfo.ambulance),
            tostring(gateInfo.patientSync)))
    end

    if now() - session.created > expectedDispatchSeconds() then
        closeSession(src, session, 'dispatch expired', false)
        return deny(src, 'The emergency response authorization expired.', nil, token)
    end

    if (Config.RequireDead and not isDead(src)) or (Config.RequireInjury ~= false and not needsCare(src)) then
        closeSession(src, session, 'patient no longer needs treatment', false)
        return deny(src, 'Patient is no longer injured. Treatment was cancelled before payment.', nil, token)
    end

    if session.price > 0 and RSAIDocBridge.GetMoney(src, session.account) < session.price then
        local newAccount = choosePayment(src)
        if not newAccount then
            closeSession(src, session, 'funds unavailable', false)
            return deny(src, 'Payment disappeared before treatment. Graves noticed.', nil, token)
        end
        session.account = newAccount
    end

    if not currentPatient(src, session) then
        closeSession(src, session, 'patient changed during payment lookup', true)
        return
    end
    if session.phase ~= 'dispatched' then return end

    -- Phase lock BEFORE any economy provider call: duplicate events cannot
    -- create two charge attempts if an export yields to the scheduler.
    session.phase = 'charging'
    if not RSAIDocSettlements.Record(session, 'charging', 'rs-aidoc-treatment') then
        session.phase = 'dispatched'
        closeSession(src, session, 'journal unavailable', false)
        return deny(src, 'Payment journal unavailable. No charge was requested.', nil, token)
    end
    if session.price > 0 then
        local charged, failure = RSAIDocBridge.RemoveMoney(src, session.account, session.price, 'rs-aidoc-treatment', session.identity)
        if not charged and failure == 'rejected' then
            -- A definitive provider rejection may use another funded account.
            -- Never retry after a thrown export, a nil receipt, or an ESX
            -- balance mismatch: the first attempt may already have charged.
            local replacement = choosePayment(src)
            if replacement and replacement ~= session.account and currentPatient(src, session) then
                session.account = replacement
                if not RSAIDocSettlements.Record(session, 'charging', 'alternate account') then
                    closeSession(src, session, 'alternate account journal failed', false)
                    return deny(src, 'Payment journal unavailable.', nil, token)
                end
                charged, failure = RSAIDocBridge.RemoveMoney(src, replacement, session.price, 'rs-aidoc-treatment', session.identity)
            end
        end
        if not charged then
            if failure == 'uncertain' then
                closeSession(src, session, 'payment outcome uncertain', false)
                return deny(src, 'Payment could not be confirmed. Contact an administrator before retrying.', nil, token)
            end
            RSAIDocSettlements.Record(session, 'rejected', 'payment rejected')
            session.phase = 'dispatched'
            closeSession(src, session, 'payment rejected', false)
            return deny(src, 'Payment could not be processed. Dr. Graves is leaving the scene.', nil, token)
        end
        session.charged = true
    end
    if not currentPatient(src, session) then
        closeSession(src, session, 'patient changed while charging', true)
        return
    end

    session.phase = 'paid'
    -- Anchor the paid procedure to the server-verified patient position. CPR
    -- may play for 20+ seconds while the ped's OneSync sync tree lags behind.
    session.treatmentPatientPosition = GetEntityCoords(GetPlayerPed(src))
    session.arrivalVerification = gateInfo and gateInfo.mode or 'server_doctor'
    if not RSAIDocSettlements.Record(session, 'paid', 'payment confirmed') then
        closeSession(src, session, 'journal failed after charge', false)
        return deny(src, 'Treatment payment needs reconciliation.', nil, token)
    end
    local allowedTrauma = {
        zombie = true, vehicle = true, drowning = true, fall = true,
        fire = true, ballistic = true, explosion = true, generic = true,
    }
    session.trauma = allowedTrauma[trauma] and trauma or 'generic'
    session.mode = isDead(src) and 'revive' or 'heal'
    session.treatmentStarted = GetGameTimer()
    session.treatmentDeadline = session.treatmentStarted + expectedTreatmentMs()
        + 3 * (tonumber(Config.Audio.MaxClipMs) or 15000) + 26000
        + 2 * (tonumber(Config.Treatment.AlignmentTimeoutMs) or 5000)
        + 4 * ((tonumber(Config.Treatment.AnimationLoadTimeoutMs) or 3000)
            + (tonumber(Config.Treatment.AnimationStartTimeoutMs) or 1000) + 1500)
    TriggerClientEvent('rs-aidoc:client:treatmentAuthorized', src, token, session.trauma, session.mode)
end)

RegisterNetEvent('rs-aidoc:server:completeTreatment', function(token)
    local src = source
    local session = sessions[src]
    if not session or session.token ~= token or session.phase ~= 'paid' then return end
    if not currentPatient(src, session) then
        closeSession(src, session, 'patient changed before completion', true)
        return
    end

    -- The client drives the procedure timing, so completion is only accepted
    -- once the treatment could plausibly have finished. Without this a client
    -- can chain beginTreatment -> completeTreatment and buy an instant revive.
    local elapsed = GetGameTimer() - (session.treatmentStarted or 0)
    if elapsed < expectedTreatmentMs() then
        -- Early completion is a hostile/out-of-order client event, not a
        -- cancellation. Keep the paid session so the legitimate UI can finish.
        if Config.Debug then
            print(('[rs-aidoc] premature complete src=%s elapsed=%d minimum=%d')
                :format(src, elapsed, expectedTreatmentMs()))
        end
        return
    end

    if (Config.RequireDead and not isDead(src)) or (Config.RequireInjury ~= false and not needsCare(src)) then
        closeSession(src, session, 'rs-aidoc-recovered-before-treatment-refund', false)
        return deny(src, 'You recovered before treatment finished. A refund was requested.', nil, token)
    end

    -- After payment was authorized, preserve identity and entity validation,
    -- but evaluate proximity against the ORIGINAL server-verified patient scene.
    -- Never cancel CPR just because the networked doctor's sync-tree position
    -- changes during a long facial/full-body animation.
    local responderOK, gateReason, gateDistance, gateOwner = RSAIDocResponders.Check(src, session, false)
    local currentPatientPos = GetEntityCoords(GetPlayerPed(src))
    local sceneMovement = session.treatmentPatientPosition
        and math.sqrt((currentPatientPos.x - session.treatmentPatientPosition.x)^2
            + (currentPatientPos.y - session.treatmentPatientPosition.y)^2
            + (currentPatientPos.z - session.treatmentPatientPosition.z)^2) or math.huge
    if responderOK and sceneMovement > (tonumber(Config.Treatment.MaxPatientMovementDuringTreatment) or 10.0) then
        responderOK, gateReason = false, 'patient_moved_during_treatment'
    end
    if not responderOK then
        if Config.Debug then
            print(('[rs-aidoc] completeTreatment denied src=%d gate=%s distance=%s owner=%s patientMove=%.1f')
                :format(src, tostring(gateReason), tostring(gateDistance), tostring(gateOwner), sceneMovement))
        end
        closeSession(src, session, 'responder verification: ' .. tostring(gateReason), false)
        return deny(src, 'Treatment interrupted: ' .. tostring(gateReason), nil, token)
    end

    -- The revive provider may yield for confirmation. Lock first so a second
    -- event cannot revive twice or issue a refund while verification is running.
    session.phase = 'reviving'
    if not RSAIDocSettlements.Record(session, 'reviving', 'medical dispatch intent') then
        session.phase = 'paid'
        closeSession(src, session, 'journal unavailable before revive', false)
        return deny(src, 'Treatment was cancelled before medical dispatch.', nil, token)
    end
    -- Re-check at completion: an injured, conscious patient might have become
    -- critically down during treatment. Never send a death/revive event to a
    -- conscious patient, and never send a heal-only event to a dead patient.
    session.mode = isDead(src) and 'revive' or 'heal'
    local medical = session.mode == 'revive' and RSAIDocMedical.Revive or RSAIDocMedical.Heal
    local recovered, provider, dispatched = medical(src, session, function() return currentPatient(src, session) end)
    if sessions[src] ~= session then return end
    if not recovered then
        if not dispatched then session.phase = 'paid' end
        closeSession(src, session, 'rs-aidoc-revive-unconfirmed', false)
        return deny(src, dispatched and 'Medical recovery was not confirmed. Your payment is recorded for administrator review.'
            or 'The medical provider rejected treatment. A refund was requested.', nil, token)
    end

    session.phase = 'completed'
    RSAIDocSettlements.Record(session, 'completed', 'medical provider and server confirmed ' .. session.mode)
    RSAIDocResponders.Depart(session)
    TriggerClientEvent('rs-aidoc:client:treatmentComplete', src, token, session.price, provider, session.mode)
    sessions[src] = nil
end)

RegisterNetEvent('rs-aidoc:server:cancelDispatch', function(token, reason)
    local src = source
    local session = sessions[src]
    if not session or session.token ~= token then return end

    -- Only paid sessions need a refund. Dispatch itself is not charged.
    if session.phase == 'reviving' or session.phase == 'charging' or session.phase == 'refunding' then return end
    -- If the existing doctor has reached the patient, a recoverable authorization
    -- timeout should not make the server delete him before the client can play
    -- a normal goodbye. Invalid spawns / owner loss still clean up immediately.
    local readableReason = type(reason) == 'string' and reason or 'unknown'
    local allowDeparture = readableReason == 'treatment_cancelled'
        or readableReason:sub(1, 32) == 'treatment_authorization_timeout:'
        or readableReason:sub(1, 13) == 'scene_failed:'
    closeSession(src, session, 'rs-aidoc-refund', not allowDeparture)
    if Config.Debug then
        print(('[rs-aidoc] dispatch cancelled src=%s reason=%s'):format(src, tostring(reason)))
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    local session = sessions[src]
    if session then
        if session.phase == 'paid' then
            RSAIDocSettlements.Record(session, 'refund_due', 'patient disconnected before revive')
        elseif session.phase == 'charging' or session.phase == 'reviving' or session.phase == 'refunding' then
            RSAIDocSettlements.Review(session, 'patient disconnected during ' .. session.phase)
        end
        RSAIDocMedical.Cancel(src, session.token)
    end
    RSAIDocResponders.CleanupSource(src)
    sessions[src] = nil
    cooldowns[src] = nil
    availabilityQueries[src] = nil
end)

local function playerUnloaded(playerId)
    local src = tonumber(playerId) or tonumber(source)
    if not src or src < 1 then return end
    local session = sessions[src]
    if session then closeSession(src, session, 'patient unloaded', true) end
    RSAIDocResponders.CleanupSource(src)
    cooldowns[src], availabilityQueries[src] = nil, nil
end
AddEventHandler('QBCore:Server:OnPlayerUnload', playerUnloaded)
AddEventHandler('esx:playerLogout', playerUnloaded)
AddEventHandler('QBCore:Server:OnPlayerLoaded', function()
    local src = source
    SetTimeout(500, function() RSAIDocSettlements.Reconcile(src) end)
end)

-- Sessions are only closed by the client reporting completion or cancellation.
-- A player who respawns on their own, crashes, or simply walks away would
-- otherwise keep a session open forever and never be able to call /medic
-- again. Expire them here, refunding anything already charged.
CreateThread(function()
    while true do
        Wait(10000)
        local t = now()
        for src, session in pairs(sessions) do
            local limit = expectedDispatchSeconds()
            local expired = session.phase == 'paid' and GetGameTimer() > session.treatmentDeadline
                or session.phase ~= 'paid' and t - session.created > limit

            -- In-flight mutations and revival belong to their phase owner.
            if session.phase ~= 'completed' and session.phase ~= 'reviving'
                and session.phase ~= 'charging' and session.phase ~= 'refunding' and expired then
                closeSession(src, session, 'rs-aidoc-timeout-refund', false)
                if GetPlayerName(src) then
                    deny(src, 'Dr. Graves gave up on the call.', nil, session.token)
                end
                if Config.Debug then
                    print(('[rs-aidoc] session expired src=%s phase=%s'):format(src, session.phase))
                end
            end
        end
    end
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    CreateThread(function()
        -- Provider resources may resolve a second or two after boot. Wait for
        -- the resource-owned adapter's real answer before reporting it.
        local deadline = GetGameTimer() + 20000
        local framework = RSAIDocBridge.Framework()
        while framework == 'standalone' and GetGameTimer() < deadline do
            Wait(500)
            framework = RSAIDocBridge.Framework()
        end
        print(('[rs-aidoc] Dr. Graves ready | framework=%s | external_bridge=%s'):format(
            framework, GetResourceState('rs_bridge')
        ))
        for _, playerId in ipairs(GetPlayers()) do RSAIDocSettlements.Reconcile(tonumber(playerId)) end
    end)
end)

-- Attempt online-player refunds before this resource stops. If the money
-- provider has already stopped, refund() records an explicit failure in logs.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for src, session in pairs(sessions) do
        closeSession(src, session, 'rs-aidoc-resource-stop', true)
    end
end)

-- Read-only release diagnostic (server console or ACE-permitted administrator).
-- No session token is printed; no client-controlled values are trusted.
RegisterCommand('aidocdiag', function(src)
    local total, paidCount = 0, 0
    for _, session in pairs(sessions) do
        total = total + 1
        if session.charged then paidCount = paidCount + 1 end
    end
    local line = ('[rs-aidoc] diag framework=%s ems=%d active=%d charged=%d price=%s externalBridge=%s')
        :format(tostring(RSAIDocBridge.Framework()), countEMS(), total, paidCount,
            tostring(Config.Price), tostring(Config.UseExternalBridge == true))
    print(line)
    for patient, session in pairs(sessions) do
        local responderOK, gate, dist, owner = RSAIDocResponders.Check(patient, session, false)
        local gateText = session.lastGate or 'none'
        print(('[rs-aidoc] session player=%d phase=%s mode=%s age=%ds actorValid=%s actorCheck=%s nearDistance=%s owner=%s lastTreatmentGate=%s charged=%s')
            :format(patient, tostring(session.phase), tostring(session.mode), math.max(0, now() - session.created),
                tostring(responderOK), tostring(gate), tostring(dist and math.floor(dist * 10) / 10),
                tostring(owner), gateText, tostring(session.charged)))
    end
    if src ~= 0 then RSAIDocBridge.Notify(src, 'RS AI Doc diagnostics recorded in server console.', 'inform') end
end, true)
