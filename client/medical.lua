RSAIDocMedical = {}
RSAIDocMedical.CanHeal = function() return false end
local pending

function RSAIDocMedical.Clear()
    pending = nil
end

RegisterNetEvent('rs-aidoc:client:healLiving', function(token)
    if source ~= 65535 or type(token) ~= 'string' or not RSAIDocMedical.CanHeal(token) then return end
    if RSAIDocBridge.IsPlayerDown() then return end
    local ped = PlayerPedId()
    if IsEntityDead(ped) or GetEntityHealth(ped) <= 0 then return end
    SetEntityHealth(ped, GetEntityMaxHealth(ped))
    ClearPedBloodDamage(ped)
    if pending and pending.token == token and pending.mode == 'heal' then pending.hpApplied = true end
end)

local function observe(token, nonce, provider, mode)
    if source ~= 65535 or type(token) ~= 'string' or type(nonce) ~= 'string'
        or not RSAIDocMedical.CanHeal(token) then return end
    local request = { token = token, nonce = nonce, provider = provider, mode = mode, ped = PlayerPedId() }
    pending = request
    CreateThread(function()
        local deadline = GetGameTimer() + 10000
        while pending == request and RSAIDocMedical.CanHeal(token) and GetGameTimer() < deadline do
            Wait(250)
            local ped = PlayerPedId()
            local recovered = not IsEntityDead(ped) and GetEntityHealth(ped) > 0 and not RSAIDocBridge.IsPlayerDown()
            if mode == 'heal' then
                recovered = recovered and ped == request.ped and request.hpApplied
                    and GetEntityHealth(ped) >= GetEntityMaxHealth(ped)
                    and (provider ~= 'qbox-heal' or request.providerEvent)
            else
                recovered = recovered and request.providerEvent
                if recovered and provider == 'qbox' then
                    local ok, ready = pcall(function()
                        return not exports.qbx_medical:IsDead() and not exports.qbx_medical:IsLaststand()
                            and LocalPlayer.state.invBusy == false and GetEntityHealth(ped) >= GetEntityMaxHealth(ped)
                    end)
                    recovered = ok and ready
                end
            end
            if pending == request and recovered then
                TriggerServerEvent(mode == 'heal' and 'rs-aidoc:server:healObserved' or 'rs-aidoc:server:reviveObserved', token, nonce)
            end
        end
    end)
end

RegisterNetEvent('rs-aidoc:client:observeRevive', function(token, nonce, provider) observe(token, nonce, provider, 'revive') end)
RegisterNetEvent('rs-aidoc:client:observeHeal', function(token, nonce, provider) observe(token, nonce, provider, 'heal') end)

RegisterNetEvent('qbx_medical:client:heal', function(kind)
    if source == 65535 and kind == 'full' and pending and pending.mode == 'heal' and pending.provider == 'qbox-heal' then
        pending.providerEvent = true
    end
end)

for event, provider in pairs({
    ['qbx_medical:client:playerRevived'] = 'qbox',
    ['hospital:client:Revive'] = 'qbcore',
    ['esx_ambulancejob:revive'] = 'esx',
    ['rs-aidoc:client:nativeRevive'] = 'native'
}) do
    local expectedProvider = provider
    RegisterNetEvent(event, function()
        if source == 65535 and pending and pending.mode == 'revive'
            and (pending.provider == expectedProvider or pending.provider == 'external') then pending.providerEvent = true end
    end)
end

RegisterNetEvent('rs-aidoc:client:stopReviveObservation', function(token)
    if source == 65535 and pending and pending.token == token then pending = nil end
end)
AddEventHandler('QBCore:Client:OnPlayerUnload', RSAIDocMedical.Clear)
AddEventHandler('esx:onPlayerLogout', RSAIDocMedical.Clear)
