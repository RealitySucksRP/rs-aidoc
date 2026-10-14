RSAIDocAudio = {}

local lastByCategory = {}
local sessionPersona = nil
local poolCache = {}

local function categoryPool(category, persona)
    local categoryData = RSAIDocDialogue and RSAIDocDialogue[category]
    if not categoryData or #categoryData == 0 then return nil end

    local key = ('%s:%d'):format(category, persona)
    if poolCache[key] then return poolCache[key] end

    local filtered = {}
    for _, clip in ipairs(categoryData) do
        if clip.persona == persona then
            filtered[#filtered + 1] = clip
        end
    end

    poolCache[key] = filtered
    return filtered
end

local function configuredPersona()
    local setting = Config.Audio and Config.Audio.Persona
    local maxPersona = #(RSAIDocPersonas or {})

    if maxPersona < 1 then return nil end
    if setting == 'random' or setting == nil then
        return math.random(1, maxPersona)
    end

    local number = tonumber(setting)
    if number and number >= 1 and number <= maxPersona then
        return math.floor(number)
    end

    return 1
end

--- Lock exactly one AI Doc persona for the complete rescue.
--- Every later Play() call is restricted to that same persona.
function RSAIDocAudio.BeginSession()
    sessionPersona = configuredPersona()
    lastByCategory = {}
    return sessionPersona
end

function RSAIDocAudio.EndSession()
    sessionPersona = nil
    lastByCategory = {}
end

function RSAIDocAudio.GetSessionPersona()
    return sessionPersona
end

local function pick(category)
    if sessionPersona == nil then
        sessionPersona = configuredPersona()
    end
    if not sessionPersona then return nil end

    local pool = categoryPool(category, sessionPersona)

    -- Voice identity is more important than category specificity.
    -- If a future edit accidentally removes a category for this persona,
    -- fall back ONLY to this same persona's generic medical line.
    if not pool or #pool == 0 then
        if Config.Debug then
            print(('[rs-aidoc] persona %s has no %s audio; using same-persona generic fallback')
                :format(tostring(sessionPersona), tostring(category)))
        end
        pool = categoryPool('generic', sessionPersona)
    end

    if not pool or #pool == 0 then
        if Config.Debug then
            print(('[rs-aidoc] persona %s has no usable audio for %s')
                :format(tostring(sessionPersona), tostring(category)))
        end
        return nil
    end

    if #pool == 1 then return pool[1] end

    local index
    repeat
        index = math.random(1, #pool)
    until index ~= lastByCategory[category]

    lastByCategory[category] = index
    return pool[index]
end

-- Playback tracking so a line can be allowed to finish before the next starts.
-- The NUI reports back on 'ended'/'error'; token matching stops a late report
-- from a superseded clip releasing the wait for the current one.
local playToken = 0
local finishedToken = 0
local lastDuration = nil

-- Facial animation is COSMETIC only. Never request ped control, clear ped
-- tasks, or wait for face animation before a medical/dispatch step can proceed.
-- A facial idle override alone does not reliably open the mouth on GTA peds.
-- GTA voice resources use PlayFacialAnim('mic_chatter', 'mp_facial').
local speaker = nil
local faceToken = nil
local faceGeneration = 0
local facePed = nil
local faceApplied = false
local faceMethod = 'idle'
local faceAttemptCount = 0
local faceError = nil

local function nativeFace(ped, anim, dict)
    if not ped or not DoesEntityExist(ped) then return false end
    local ok = pcall(PlayFacialAnim, ped, anim, dict)
    return ok
end

local function stopTalking()
    -- Invalidate the previous clip's thread BEFORE touching its ped. Late NUI
    -- audioStarted/audioEnded messages cannot restart an older voice line.
    faceGeneration = faceGeneration + 1
    faceToken = nil
    local ped = facePed
    local hadFace = faceApplied
    facePed = nil
    faceApplied = false
    faceMethod = 'idle'
    if hadFace and ped and DoesEntityExist(ped) then
        -- Clear only a facial expression, never the kneeling/CPR body tasks.
        pcall(ClearFacialIdleAnimOverride, ped)
        nativeFace(ped, Config.Audio.RestingFace or 'mood_normal_1',
            Config.Audio.FacialDict or 'facials@gen_male@base')
    end
end

function RSAIDocAudio.SetSpeaker(ped)
    stopTalking()
    speaker = ped and DoesEntityExist(ped) and ped or nil
    if speaker and Config.Audio and Config.Audio.LipMovement then
        -- Warm both dictionaries without waiting or interfering with dispatch.
        pcall(RequestAnimDict, Config.Audio.MouthDict or 'mp_facial')
        pcall(RequestAnimDict, Config.Audio.FacialDict or 'facials@gen_male@base')
    end
end

function RSAIDocAudio.Diagnostics()
    local exists = speaker and DoesEntityExist(speaker)
    return { model = exists and GetEntityModel(speaker) or nil,
        jawBone = exists and GetPedBoneIndex(speaker, 46240) or -1,
        requested = faceToken ~= nil and faceToken == playToken,
        -- 'applied' means the facial native was called without a script error;
        -- whether the model's mouth VISIBLY moves still requires live testing.
        applied = faceApplied, method = faceMethod,
        attempts = faceAttemptCount, error = faceError,
        token = playToken, finished = finishedToken >= playToken }
end

RegisterNUICallback('audioStarted', function(data, cb)
    cb({ ok = true })
    if not Config.Audio.LipMovement or type(data) ~= 'table'
        or tonumber(data.token) ~= playToken or finishedToken >= playToken
        or not speaker or not DoesEntityExist(speaker) then return end

    stopTalking()
    faceToken = playToken
    facePed = speaker
    faceAttemptCount = 0
    faceError = nil
    local generation = faceGeneration
    local token = playToken
    local ped = facePed

    CreateThread(function()
        local mouthDict = Config.Audio.MouthDict or 'mp_facial'
        local mouthClip = Config.Audio.MouthAnim or 'mic_chatter'
        local backupDict = Config.Audio.FacialDict or 'facials@gen_male@base'
        local backupClip = Config.Audio.TalkingFace or 'mood_talking_1'
        local refresh = math.max(750, math.min(3000,
            tonumber(Config.Audio.MouthRefreshMs) or 1600))

        local function stillSpeaking()
            return generation == faceGeneration and token == faceToken
                and token == playToken and finishedToken < token
                and speaker == ped and DoesEntityExist(ped)
        end
        local function loadDict(dict, budget)
            local ok = pcall(RequestAnimDict, dict)
            if not ok then return false end
            local deadline = GetGameTimer() + budget
            while stillSpeaking() and not HasAnimDictLoaded(dict)
                and GetGameTimer() < deadline do Wait(50) end
            return stillSpeaking() and HasAnimDictLoaded(dict)
        end

        -- Main: GTA's built-in voice/mouth facial movement. A fallback talking
        -- expression is available if mp_facial is missing on this build.
        local dict, clip, method
        if loadDict(mouthDict, 1300) then
            dict, clip, method = mouthDict, mouthClip, 'mic_chatter'
        elseif loadDict(backupDict, 900) then
            dict, clip, method = backupDict, backupClip, 'talking_fallback'
        else
            if stillSpeaking() then
                faceError = 'facial_dict_unavailable'
                if Config.Debug then
                    print('[rs-aidoc] lip animation skipped: facial dictionaries unavailable')
                end
            end
            return
        end

        local first = true
        while stillSpeaking() do
            faceAttemptCount = faceAttemptCount + 1
            if nativeFace(ped, clip, dict) then
                faceApplied = true
                faceMethod = method
                if first and Config.Debug then
                    print(('[rs-aidoc] mouth animation requested: %s / %s (method=%s)')
                        :format(dict, clip, method))
                end
            elseif first then
                faceError = 'facial_native_failed'
                -- A facial failure must never abort the procedure or dialogue.
                if method == 'mic_chatter' and loadDict(backupDict, 500) then
                    dict, clip, method = backupDict, backupClip, 'talking_fallback'
                end
            end
            first = false
            -- The talking facial clip is separate from the full-body animation
            -- and is renewed periodically during lengthy ElevenLabs dialogue.
            local wake = GetGameTimer() + refresh
            while stillSpeaking() and GetGameTimer() < wake do Wait(100) end
        end
    end)
end)

RegisterNUICallback('audioMeta', function(data, cb)
    if type(data) == 'table' and tonumber(data.token) == playToken then
        lastDuration = tonumber(data.duration)
    end
    cb({ ok = true })
end)

RegisterNUICallback('audioEnded', function(data, cb)
    -- A stale, future or forged NUI completion must NEVER release another line.
    if type(data) == 'table' and tonumber(data.token) == playToken then
        finishedToken = playToken
        stopTalking()
        if Config.Debug then
            print(('[rs-aidoc] clip=%d finished reason=%s'):format(playToken, tostring(data.reason)))
        end
    end
    cb({ ok = true })
end)

function RSAIDocAudio.Play(category)
    if not Config.Audio.Enabled then return end

    local clip = pick(category)
    if not clip then return end

    stopTalking()
    playToken = playToken + 1
    lastDuration = nil

    SendNUIMessage({
        action = 'play',
        token = playToken,
        file = ('sounds/%s'):format(clip.file),
        volume = Config.Audio.Volume,
        subtitle = Config.Audio.Subtitles and clip.subtitle or nil,
        subtitleMs = Config.Audio.SubtitleMs,
    })
end

--- Block until the line currently playing finishes.
---
--- Always bounded. If a sound file is missing or the NUI never answers, the
--- timeout releases the caller -- a stalled wait here would freeze the whole
--- treatment sequence with the doctor stood still.
--- @param timeoutMs number|nil defaults to Config.Audio.MaxClipMs
--- @return number elapsed milliseconds actually waited
function RSAIDocAudio.WaitForFinish(timeoutMs)
    if not Config.Audio.Enabled then return 0 end

    local budget = tonumber(timeoutMs) or tonumber(Config.Audio and Config.Audio.MaxClipMs) or 15000
    local target = playToken
    local started = GetGameTimer()
    local deadline = started + math.max(500, budget)

    while playToken == target and finishedToken < target and GetGameTimer() < deadline do
        Wait(50)
    end

    local completed = (finishedToken >= target)
    if completed and target > 0 and playToken == target then
        local gap = math.max(0, math.min(2000, tonumber(Config.Audio.LineGapMs) or 0))
        if gap > 0 then Wait(gap) end
    end
    local elapsed = GetGameTimer() - started
    if not completed and Config.Debug then
        print(('[rs-aidoc] clip=%d timed out/superseded after %dms'):format(target, elapsed))
    end
    return elapsed, completed
end

--- True while a line is still speaking.
function RSAIDocAudio.IsPlaying()
    return finishedToken < playToken
end

function RSAIDocAudio.Stop()
    -- Stop is a terminal event for the current token, NOT a new voice line.
    finishedToken = playToken
    stopTalking()
    SendNUIMessage({ action = 'stop', token = playToken })
end
