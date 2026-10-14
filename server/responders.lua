RSAIDocResponders = {}
local responders = {}

local function finite(value)
    return type(value) == 'number' and value == value and math.abs(value) < 100000
end

local function distance(a, b)
    local x, y, z = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(x*x + y*y + z*z)
end

local function validEntity(entity, net, model, bucket)
    return entity and entity ~= 0 and DoesEntityExist(entity)
        and NetworkGetNetworkIdFromEntity(entity) == net
        and GetEntityModel(entity) == GetHashKey(model)
        and GetEntityRoutingBucket(entity) == bucket
end

function RSAIDocResponders.Create(src, session, position)
    if type(position) ~= 'table' or not finite(position.x) or not finite(position.y)
        or not finite(position.z) or not finite(position.heading) then return false end
    local patient = GetPlayerPed(src)
    if patient == 0 or not DoesEntityExist(patient) then return false end
    local origin = GetEntityCoords(patient)
    local range = distance(origin, position)
    if range < 15 or range > (tonumber(Config.Dispatch.SpawnRadiusMax) or 115) + 80 then return false end
    local vehicle = CreateVehicleServerSetter(GetHashKey(Config.Dispatch.VehicleModel), 'automobile',
        position.x, position.y, position.z, position.heading)
    if vehicle == 0 or not DoesEntityExist(vehicle) then return false end
    session.vehicle, session.vehicleNet = vehicle, NetworkGetNetworkIdFromEntity(vehicle)
    responders[session.token] = { source = src, session = session }
    SetEntityRoutingBucket(vehicle, session.bucket)
    SetEntityOrphanMode(vehicle, 2)
    -- Apply plate from the server as well as the owning client; OneSync can
    -- move the vehicle's owner after it spawns.
    pcall(function() SetVehicleNumberPlateText(vehicle, tostring(Config.Dispatch.Plate or 'AIDOC'):sub(1, 8)) end)
    local doctor = CreatePed(4, GetHashKey(Config.Dispatch.PedModel), position.x + 1.0,
        position.y, position.z + 0.5, position.heading, true, true)
    if doctor == 0 or not DoesEntityExist(doctor) then DeleteEntity(vehicle); return false end
    session.doctor = doctor
    session.doctorNet = NetworkGetNetworkIdFromEntity(doctor)
    SetEntityRoutingBucket(doctor, session.bucket)
    SetEntityOrphanMode(doctor, 2)
    session.spawnedAt = GetGameTimer()
    session.relocations = 0
    return true
end

-- Authenticate this session's server-created responder first. Entity owner is
-- diagnostic: OneSync may move ownership while the patient sees the doctor
-- complete the approach. The server sync-tree ped position can lag that view.
-- A stale-ped fallback NEVER accepts a client's distance alone: require the
-- registered ambulance within a short server-measured radius, corroborated
-- player coordinates and a matching doctor net ID from this very session.
local function reportedPosition(value)
    if type(value) ~= 'table' or not finite(value.x) or not finite(value.y)
        or not finite(value.z) then return nil end
    return value
end

function RSAIDocResponders.Check(src, session, nearPatient, observation)
    if GetPlayerRoutingBucket(src) ~= session.bucket then return false, 'bucket_mismatch' end
    if not validEntity(session.doctor, session.doctorNet, Config.Dispatch.PedModel, session.bucket) then
        return false, 'doctor_missing_or_changed'
    end
    if session.vehicle and not validEntity(session.vehicle, session.vehicleNet, Config.Dispatch.VehicleModel, session.bucket) then
        return false, 'ambulance_missing_or_changed'
    end

    local patient = GetPlayerPed(src)
    if patient == 0 or not DoesEntityExist(patient) then return false, 'patient_ped_missing' end
    local patientPos = GetEntityCoords(patient)
    local doctorDistance = distance(patientPos, GetEntityCoords(session.doctor))
    local owner = NetworkGetEntityOwner(session.doctor)
    local ambulanceDistance = session.vehicle and distance(patientPos, GetEntityCoords(session.vehicle)) or nil
    local report = type(observation) == 'table' and observation or {}
    local reportPatient, reportDoctor = reportedPosition(report.patient), reportedPosition(report.doctor)
    local reportDistance = reportPatient and reportDoctor and distance(reportPatient, reportDoctor) or nil
    local patientSyncGap = reportPatient and distance(reportPatient, patientPos) or nil
    local info = { doctor = doctorDistance, ambulance = ambulanceDistance,
        reported = reportDistance, patientSync = patientSyncGap, owner = owner,
        mode = 'server_doctor' }

    local directThreshold = math.max(4.5, (tonumber(Config.Dispatch.ArrivalPedDistance) or 1.8) + 2.0)
    if not nearPatient or doctorDistance <= directThreshold then
        return true, 'ok', doctorDistance, owner, info
    end

    -- Corroboration is deliberately narrower than the general ambulance spawn
    -- radius. It cannot authorize treatment with a remotely parked ambulance.
    local arrivalCarRadius = math.min(30.0, math.max(22.0,
        (tonumber(Config.Dispatch.ArrivalVehicleDistance) or 14.0) + 12.0))
    local clientDoctorRadius = math.min(3.75,
        (tonumber(Config.Dispatch.ArrivalPedDistance) or 1.8) + 1.25)
    local validObservation = report.doctorNet == session.doctorNet
        and reportDistance and reportDistance <= clientDoctorRadius
        and patientSyncGap and patientSyncGap <= 6.0
        and math.abs(reportPatient.z - patientPos.z) <= 3.5
    -- The dispatcher must have actually completed a drive or a server-approved
    -- relocation; don't authorize treatment while the ambulance is spawning.
    local dispatchAge = GetGameTimer() - (session.spawnedAt or GetGameTimer())
    local nearbyAmbulance = ambulanceDistance and ambulanceDistance <= arrivalCarRadius
    local relocatedHere = session.relocations and session.relocations > 0
        and session.relocatedPatient and distance(patientPos, session.relocatedPatient) <= 8.0
        and GetGameTimer() - (session.relocatedAt or 0) <= 90000
    if validObservation and dispatchAge >= 2000
        and (nearbyAmbulance or relocatedHere)
        and doctorDistance <= math.max(135.0, (tonumber(Config.Dispatch.SpawnRadiusMax) or 85) + 50.0) then
        info.mode = nearbyAmbulance and 'corroborated_ambulance' or 'corroborated_relocation'
        return true, 'ok', doctorDistance, owner, info
    end
    return false, 'doctor_too_far', doctorDistance, owner, info
end

function RSAIDocResponders.Relocate(src, session, reason, position)
    if Config.Dispatch.RelocateIfUnreachable == false or not RSAIDocResponders.Check(src, session, false)
        or session.relocations >= 2 or type(position) ~= 'table'
        or not finite(position.x) or not finite(position.y) or not finite(position.z) then return false end
    local elapsed = GetGameTimer() - session.spawnedAt
    local approach = math.max(1, tonumber(Config.Dispatch.ApproachTimeoutSeconds) or 60) * 1000
    local minimums = {
        no_road_access = 0,
        stuck = math.max(1, tonumber(Config.Dispatch.StuckSeconds) or 6)
            * ((tonumber(Config.Dispatch.StuckRetries) or 3) + 1) * 1000,
        drive_timeout = math.max(1, tonumber(Config.Dispatch.RelocateAfterSeconds)
            or tonumber(Config.Dispatch.FailsafeSeconds) or 90) * 1000,
        approach_timeout = approach,
        final_approach = approach,
        exit_blocked = 0
    }
    if not minimums[reason] or elapsed < minimums[reason] then return false end
    if reason == 'exit_blocked' then
        if not session.vehicle or not DoesEntityExist(session.vehicle)
            or distance(GetEntityCoords(session.vehicle), GetEntityCoords(GetPlayerPed(src)))
                > math.max(18.0, (tonumber(Config.Dispatch.UnreachableNodeDistance) or 45.0) + 12.0) then
            return false
        end
    end
    if session.relocations > 0 and (reason ~= 'final_approach'
        or GetGameTimer() - session.relocatedAt < approach) then return false end
    local patient = GetEntityCoords(GetPlayerPed(src))
    if distance(patient, position) > 8.0 or math.abs(patient.z - position.z) > 3.0 then return false end
    session.relocations = session.relocations + 1
    session.relocatedAt = GetGameTimer()
    session.relocatedPatient = { x = patient.x, y = patient.y, z = patient.z }
    local keepVehicle = false
    if session.vehicle and DoesEntityExist(session.vehicle) then
        keepVehicle = distance(GetEntityCoords(session.vehicle), patient) <= 40.0
    end
    SetEntityCoords(session.doctor, position.x, position.y, position.z, false, false, false, false)
    -- Preserve a nearby ambulance for the scripted running return. When the
    -- stranded vehicle is truly far away, delete it and depart on foot instead.
    if not keepVehicle then
        if session.vehicle and DoesEntityExist(session.vehicle) then DeleteEntity(session.vehicle) end
        session.vehicle, session.vehicleNet = nil, nil
    end
    return true, keepVehicle
end

function RSAIDocResponders.Delete(session)
    if session.doctor and DoesEntityExist(session.doctor)
        and NetworkGetNetworkIdFromEntity(session.doctor) == session.doctorNet then DeleteEntity(session.doctor) end
    if session.vehicle and DoesEntityExist(session.vehicle)
        and NetworkGetNetworkIdFromEntity(session.vehicle) == session.vehicleNet then DeleteEntity(session.vehicle) end
    responders[session.token] = nil
end

function RSAIDocResponders.Depart(session)
    local entry = responders[session.token]
    if entry then
        local drive = tonumber(Config.Dispatch.DepartureTimeoutSeconds) or 45
        local foot = tonumber(Config.Dispatch.DepartureOnFootTimeoutSeconds) or 25
        entry.expires = GetGameTimer() + (math.max(drive, foot)
            + (tonumber(Config.Dispatch.DepartureRunTimeoutSeconds) or 14)
            + (tonumber(Config.Dispatch.DepartureEnterTimeoutSeconds) or 12)
            + 2 * (tonumber(Config.Audio.MaxClipMs) or 15000) / 1000 + 10) * 1000
    end
end

RegisterNetEvent('rs-aidoc:server:responderDeparted', function(token)
    local entry = responders[token]
    if entry and entry.source == source and entry.expires then RSAIDocResponders.Delete(entry.session) end
end)

function RSAIDocResponders.CleanupSource(src)
    for _, entry in pairs(responders) do
        if entry.source == src then RSAIDocResponders.Delete(entry.session) end
    end
end

CreateThread(function()
    while true do
        Wait(5000)
        for _, entry in pairs(responders) do
            if entry.expires and GetGameTimer() >= entry.expires then RSAIDocResponders.Delete(entry.session) end
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for _, entry in pairs(responders) do RSAIDocResponders.Delete(entry.session) end
end)
