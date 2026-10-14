RSAIDocMedical = {}
local pending = {}

function RSAIDocMedical.Cancel(src, token)
    local request = pending[src]
    if request and request.token == token then
        pending[src] = nil
        TriggerClientEvent('rs-aidoc:client:stopReviveObservation', src, token)
    end
end

RegisterNetEvent('rs-aidoc:server:reviveObserved', function(token, nonce)
    local src = source
    local request = pending[src]
    if not request or request.mode ~= 'revive' or request.token ~= token or request.nonce ~= nonce or not request.dispatched
        or not request.valid() or RSAIDocBridge.CharacterIdentity(src) ~= request.identity then return end
    if RSAIDocBridge.IsPlayerRevived(src) then request.observed = true end
end)

function RSAIDocMedical.Revive(src, session, valid)
    if not valid() then return false, 'patient-changed', false end
    local request = {
        token = session.token, identity = session.identity, valid = valid, mode = 'revive',
        nonce = ('%08x%08x'):format(math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
    }
    pending[src] = request
    local selected = RSAIDocBridge.MedicalProvider()
    if not valid() then RSAIDocMedical.Cancel(src, session.token); return false, 'patient-changed', false end
    TriggerClientEvent('rs-aidoc:client:observeRevive', src, request.token, request.nonce, selected)
    local accepted, provider, uncertain = RSAIDocBridge.RevivePlayer(src)
    request.dispatched = accepted or uncertain == true
    if not accepted then
        RSAIDocMedical.Cancel(src, session.token)
        return false, provider or 'medical-provider-failed', request.dispatched
    end
    local deadline = GetGameTimer() + 8000
    while pending[src] == request and valid() and GetGameTimer() < deadline do
        Wait(250)
        if request.observed and valid() and RSAIDocBridge.IsPlayerRevived(src) then
            RSAIDocMedical.Cancel(src, session.token)
            return true, provider, true
        end
    end
    RSAIDocMedical.Cancel(src, session.token)
    return false, (provider or 'medical') .. '-unconfirmed', true
end

-- Conscious-player treatment uses a HEAL, not a REVIVE. Qbox's documented
-- Heal export also clears bleeding/limb injuries. Fallback restores native HP
-- only, and never pretends it cleared another provider's private injury data.
local function qboxStatus(src)
    if GetResourceState('qbx_medical') ~= 'started' then return nil end
    local ok, status = pcall(function() return exports.qbx_medical:GetPlayerStatus(src) end)
    return ok and type(status) == 'table' and status or nil
end

local function maxHealth(ped)
    local ok, value = pcall(function() return GetEntityMaxHealth(ped) end)
    if ok and type(value) == 'number' and value > 0 then return value end
    return nil -- unknown maximum is not evidence of injury or recovery
end

function RSAIDocMedical.IsInjured(src)
    local ped = GetPlayerPed(src)
    if ped == 0 or not DoesEntityExist(ped) then return false end
    local hp = GetEntityHealth(ped)
    if hp <= 0 then return true end
    local missing = math.max(1, tonumber(Config.MinMissingHealth) or 5)
    local maximum = maxHealth(ped)
    if maximum and hp <= maximum - missing then return true end
    local status = qboxStatus(src)
    if status then
        if (tonumber(status.bleedLevel) or 0) > 0 then return true end
        if type(status.injuries) == 'table' and next(status.injuries) then return true end
    end
    return false
end

local function livingHealed(src, provider)
    if RSAIDocBridge.IsPlayerDown(src) then return false end
    local state = Player(src) and Player(src).state
    if state and (state.isDead == true or state.dead == true or state.laststand == true) then return false end
    local ped = GetPlayerPed(src)
    if ped == 0 or not DoesEntityExist(ped) then return false end
    local maximum = maxHealth(ped)
    if not maximum or GetEntityHealth(ped) <= 0 or GetEntityHealth(ped) < maximum - 1 then return false end
    if provider == 'qbox-heal' then
        local status = qboxStatus(src)
        if not status then return false end
        if (tonumber(status.bleedLevel) or 0) > 0 then return false end
        if type(status.injuries) == 'table' and next(status.injuries) then return false end
    end
    return true
end

RegisterNetEvent('rs-aidoc:server:healObserved', function(token, nonce)
    local src = source
    local request = pending[src]
    if not request or request.mode ~= 'heal' or request.token ~= token or request.nonce ~= nonce
        or not request.dispatched or not request.valid()
        or RSAIDocBridge.CharacterIdentity(src) ~= request.identity then return end
    if livingHealed(src, request.provider) then request.observed = true end
end)

function RSAIDocMedical.Heal(src, session, valid)
    if not valid() then return false, 'patient-changed', false end
    local ped = GetPlayerPed(src)
    if ped == 0 or not DoesEntityExist(ped) then return false, 'no-patient-ped', false end
    local provider = GetResourceState('qbx_medical') == 'started' and 'qbox-heal' or 'native-heal'
    local request = { token = session.token, identity = session.identity, valid = valid, mode = 'heal',
        provider = provider, nonce = ('%08x%08x'):format(math.random(0, 0x7fffffff), math.random(0, 0x7fffffff)) }
    pending[src] = request
    TriggerClientEvent('rs-aidoc:client:observeHeal', src, request.token, request.nonce, provider)
    if provider == 'qbox-heal' then
        local ok, result = pcall(function() return exports.qbx_medical:Heal(src) end)
        request.dispatched = ok and result ~= false or not ok
        if not ok or result == false then
            RSAIDocMedical.Cancel(src, session.token)
            return false, 'qbox-heal-failed', request.dispatched
        end
    end
    if not valid() then
        RSAIDocMedical.Cancel(src, session.token)
        return false, 'patient-changed-after-heal-dispatch', request.dispatched == true
    end
    -- This installed Qbox Heal resets wounds/bleeding but not native HP.
    -- Complement it with authenticated HP restoration, never resurrection.
    local ok = pcall(function() TriggerClientEvent('rs-aidoc:client:healLiving', src, session.token) end)
    request.dispatched = true
    if not ok then
        RSAIDocMedical.Cancel(src, session.token)
        return false, provider .. '-dispatch-error', true
    end
    local deadline = GetGameTimer() + 8000
    while pending[src] == request and valid() and GetGameTimer() < deadline do
        Wait(250)
        if request.observed and valid() and livingHealed(src, provider) then
            RSAIDocMedical.Cancel(src, session.token)
            return true, provider, true
        end
    end
    RSAIDocMedical.Cancel(src, session.token)
    return false, provider .. '-unconfirmed', true
end
