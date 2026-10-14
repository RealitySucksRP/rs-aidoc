Config = {}

-- Framework access is owned by this resource; rs_bridge is only an optional
-- first provider when a server already runs it.
Config.Framework = 'auto'
-- Internal adapters are the default. External rs_bridge is optional opt-in.
Config.UseExternalBridge = false
Config.Command = 'medic'

Config.Price = 500
-- Qbox servers with qb_protect_cash_while_dead=1 automatically skip cash while
-- the patient is down and use the next funded account (normally bank).
Config.PaymentPriority = { 'cash', 'bank' }
Config.CooldownSeconds = 120
Config.SessionTimeoutSeconds = 180
-- Accept wounded players who are still conscious, as well as laststand/dead.
-- Set RequireDead=true to restore down-only calls. Healthy players remain blocked.
Config.RequireDead = false
Config.RequireInjury = true
Config.MinMissingHealth = 5 -- living ped: points below their maximum HP


Config.EMS = {
    Jobs = { ambulance = true, ems = true },
    OnDutyOnly = true,
    -- AI Doc is allowed when the number of available real medics is <= this value.
    MaxOnlineForAIDoc = 0,
}

Config.Dispatch = {
    PedModel = 'u_m_y_zombie_01',
    VehicleModel = 'ambulance',
    Plate = 'AIDOC',
    SpawnRadiusMin = 48.0,
    SpawnRadiusMax = 85.0,
    DriveSpeed = 21.0,

    -- Driving style is a bitfield. 786603 -- the old value -- decomposes to
    -- TakeShortestPath + AvoidHighways + StopAtTrafficLights(128) +
    -- AvoidObjects(32) + AvoidEmptyVehicles(8) + StopBeforePeds(2) +
    -- StopBeforeVehicles(1). Those three Stop* bits are why Graves sat at a
    -- red light while the patient bled out.
    --
    -- 786980 = TakeShortestPath + AvoidHighways + AllowGoingWrongWay(512) +
    -- AvoidObjects(32) + AvoidVehicles(4), and NO Stop* bits. He still steers
    -- around traffic and obstacles -- he just never yields to them. That is
    -- the behaviour you want from an emergency responder.
    --
    -- Do not simply drop AvoidObjects/AvoidVehicles to make him more direct:
    -- without them he rams scenery and ends up wedged, which is the exact
    -- 'stuck' failure this is meant to prevent.
    DrivingStyle = 786980,

    -- Full ability + aggression. A low-ability driver brakes early, takes
    -- corners wide and gives up on tight gaps -- indistinguishable from being
    -- stuck when you are watching from the floor.
    DriverAbility = 1.0,
    DriverAggressiveness = 1.0,

    -- Stuck recovery. If the ambulance is below StuckSpeed for StuckSeconds
    -- while still short of the patient, the drive task is re-issued. GTA's
    -- pathfinder sometimes abandons a route silently; re-tasking makes it
    -- pick a fresh one. After StuckRetries failed attempts he stops trying to
    -- drive and Graves continues on foot rather than idling forever.
    StuckSpeed = 0.6,
    StuckSeconds = 4,
    StuckRetries = 2,

    -- Early unreachable detection. If the nearest road node to the patient is
    -- further than this, no road goes there -- a river bed, a beach, deep
    -- inside a lot. Waiting the full RelocateAfterSeconds in that case just
    -- makes the player watch an ambulance circle uselessly, so the on-foot
    -- fallback is triggered straight away instead.
    --
    -- A vehicle cannot cross water at all. This is what handles that case.
    UnreachableNodeDistance = 45.0,
    ArrivalVehicleDistance = 14.0,
    ArrivalPedDistance = 1.8,
    -- If the ambulance cannot reach the patient in this many seconds, the
    -- existing doctor is safely moved beside them and resumes the normal
    -- arrival/treatment flow. 60-120 seconds is the intended range.
    RelocateIfUnreachable = true,
    RelocateAfterSeconds = 55,
    RelocateDistance = 3.0,
    -- If the ambulance arrives but Graves cannot finish the walk, this timer
    -- triggers the same one-time nearby relocation. A second failure cancels
    -- the call so a stuck responder cannot lock the player out of /medic.
    ApproachTimeoutSeconds = 35,
    -- After treatment Graves returns to the driver seat and leaves instead of
    -- disappearing beside the patient. If normal entry fails, he may be placed
    -- into the seat so a blocked door/path cannot stall cleanup forever.
    ReturnToVehicleAfterTreatment = true,
    DepartureRunTimeoutSeconds = 14,
    DepartureEnterTimeoutSeconds = 12,
    DepartureWarpIntoVehicle = true,
    DepartureDriveSpeed = 18.0,
    DepartureDriveDistance = 160.0,
    DepartureCleanupDistance = 100.0,
    DepartureTimeoutSeconds = 45,
    DepartureOnFootTimeoutSeconds = 25,
    InvincibleDoctor = true,
    UseSiren = true,
    BatteredVehicle = true,
}

Config.Treatment = {
    ExamineMs = 3500,
    ReviveMs = 20000,
    CPRDialogueMinMs = 5500,
    CPRDialogueMaxMs = 8500,
    -- Requested chest aim reference: SKEL_Spine1 (visual, not a distance gate).
    ChestBone = 24816,
    -- Classic clips below come from rs-aidoc-oldone.zip, the known in-game
    -- working sequence. Set these to the Alternate clips to try the newer pose
    -- first; the original clips can then be used as fallback instead.
    KneelAnimDict = 'amb@medic@standing@tendtodead@base',
    KneelAnim = 'base',
    CPRAnimDict = 'mini@cpr@char_a@cpr_str',
    CPRAnim = 'cpr_pumpchest',
    -- Requested special cinematic clips remain available as a fallback.
    FallbackKneelAnimDict = 'rcmfanatic3',
    FallbackKneelAnim = 'kneel_idle_a',
    FallbackCPRAnimDict = 'missheistfbi3b_ig8_2',
    FallbackCPRAnim = 'cpr_loop_paramedic',
    AnimationLoadTimeoutMs = 3000,
    AnimationStartTimeoutMs = 1200,
    AnimationRecoveryAttempts = 3,
    -- Server rechecks the same patient location after CPR; does not require the
    -- moving doctor's network sync tree to remain within 4.5m for 20 seconds.
    MaxPatientMovementDuringTreatment = 10.0,

}

Config.Audio = {
    -- GTA facial animation follows the real NUI audio playback lifecycle.
    -- Uses a talking expression rather than changing the full-body task.
    LipMovement = true,
    -- GTA speech-face animation; unlike an idle expression it actively moves
    -- the mouth. This affects facial bones only, not Dr. Graves' CPR tasks.
    MouthDict = 'mp_facial',
    MouthAnim = 'mic_chatter',
    MouthRefreshMs = 1600,
    -- Used as a fallback for rigs/builds without the above facial dictionary.
    FacialDict = 'facials@gen_male@base',
    TalkingFace = 'mood_talking_1',
    RestingFace = 'mood_normal_1',
    Enabled = true,
    Volume = 0.78,
    Subtitles = true,
    SubtitleMs = 15000, -- failsafe only; captions follow the real clip duration
    LineGapMs = 350, -- small natural pause after each completed spoken line

    -- Safety cap on waiting for a line to finish. Dialogue is allowed to run to
    -- its natural end rather than being cut off by a fixed timer, but if a sound
    -- file is missing the NUI never reports 'ended', so this releases the wait
    -- instead of freezing the treatment sequence. Raise it only if you add
    -- clips longer than this.
    MaxClipMs = 15000,

    -- Persona identity is locked for one complete /medic call.
    -- 'random' = choose one of the 8 AI Doc personas per rescue.
    -- 1..8     = always use that persona.
    --
    -- Every persona has dialogue in every category. Audio selection NEVER falls
    -- back to another persona, so dispatch -> arrival -> diagnosis -> CPR ->
    -- revive -> goodbye always uses the same ElevenLabs voice identity.
    Persona = 'random',
}

-- On-screen prompt shown while you are down, so players know Dr. Graves exists.
--
-- OFF on this server by design: qbx_ambulancejob owns the death text, and the
-- /medic prompt lives in its locale (locales/en.json -> info.bleed_out and
-- info.respawn_revive) so there is exactly one thing drawing on the death screen.
-- Turn this on only if qbx_ambulancejob is removed -- qbx_medical alone draws no
-- death UI at all, which would otherwise leave the screen blank.
Config.DeathHint = {
    Enabled = false,
    -- Only advertise Graves when he would actually accept the call, using the same
    -- EMS rule the server enforces in Config.EMS.
    OnlyWhenNoEMS = true,
    Text = 'No medics available - type ~g~/medic~s~ to call Dr. Graves',
    EMSText = '~y~EMS is on duty.~s~ Sit tight for a real medic.',

    -- Respawn / bleed-out countdown.
    -- qbx_medical runs these timers but ships no death UI at all, so with only
    -- qbx_medical installed nothing renders them unless this does -- set true then.
    -- qbx_ambulancejob DOES draw them (client/setdownedstate.lua, the same
    -- respawn_txt / bleed_out / bleed_out_help strings qb-ambulancejob used), so
    -- with it installed this stays false or you get two countdowns.
    ShowRespawnTimer = false,
    LaststandText = 'YOU WILL BLEED OUT IN: ~r~%d~s~ SECONDS',
    RespawnText = 'RESPAWN IN: ~r~%d~s~ SECONDS',
    HoldText = 'HOLD [~r~E~s~] TO RESPAWN',

    RefreshSeconds = 10,
    -- Sits directly above qbx_ambulancejob's death text. Its qbx.drawText2d call
    -- uses coords vec2(1.0, 1.44) with default width/height 1.0, which resolves to
    -- screen (0.5, 0.945); the "PRESS [G] TO REQUEST HELP" line lands at (0.5, 0.905).
    -- At 0.84 this line and its backing rect clear both.
    X = 0.5,
    Y = 0.84,
    LineHeight = 0.034,
    Scale = 0.42,
    Font = 4,
    Background = true,
}

-- All required provider adapters are local in bridge/. The external rs_bridge
-- remains optional and is never a required dependency. Medical providers:
-- qbx_medical, qb-ambulancejob, esx_ambulancejob or native fallback.

Config.Debug = false -- Set true temporarily to see treatment-gate reasons in F8 and server console
