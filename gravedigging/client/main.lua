if not GraveDigging or not GraveDigging.Enable then return end

local Callbacks, Targeting, Progress, Notification

local IsRobbing = false
local ActiveGraveId = nil
local Coffins = {}
local Peds = {}

local _depsReady = false
local _spawnReady = false
local _zonesRegistered = false

local TryInit
local RegisterGraves

AddEventHandler('GraveDigging:Shared:DependencyUpdate', function()
    if _depsReady then
        return
    end

    Callbacks = exports['mythic-base']:FetchComponent('Callbacks')
    Targeting = exports['mythic-base']:FetchComponent('Targeting')
    Progress = exports['mythic-base']:FetchComponent('Progress')
    Notification = exports['mythic-base']:FetchComponent('Notification')

    _depsReady = true
    print('[GraveDigging] Dependencies Ready')
end)

AddEventHandler('Core:Shared:Ready', function()
    exports['mythic-base']:RequestDependencies('GraveDigging', {
        'Callbacks',
        'Targeting',
        'Progress',
        'Notification',
    }, function(error)
        if #error > 0 then
            return
        end
        TriggerEvent('GraveDigging:Shared:DependencyUpdate')

        CreateThread(function()
            while not _depsReady do
                Wait(50)
            end
            TryInit()
        end)

        CreateThread(function()
            while not _spawnReady do
                if LocalPlayer and LocalPlayer.state and (LocalPlayer.state.loggedIn or LocalPlayer.state.Character ~= nil) then
                    _spawnReady = true
                    print('[GraveDigging] Detected Logged In State')
                    break
                end
                Wait(250)
            end
            TryInit()
        end)
    end)
end)

local function LoadModel(model)
    local modelHash = model
    if type(model) == 'string' then
        modelHash = GetHashKey(model)
    end

    RequestModel(modelHash)
    while not HasModelLoaded(modelHash) do
        Wait(0)
    end

    return modelHash
end

TryInit = function()
    if _zonesRegistered then
        return
    end
    if not _depsReady or not _spawnReady then
        return
    end

    _zonesRegistered = true
    Callbacks:ServerCallback('GraveDigging:Server:GetConfig', {}, function(serverConfig)
        if serverConfig then
            GraveDigging = serverConfig
        end

        if RegisterGraves then
            RegisterGraves()
        end
    end, tostring(GetGameTimer()))
end

local function RemoveWeapons(npc)
    for _, weapon in ipairs(GraveDigging.AngryPedWeapons) do
        RemoveWeaponFromPed(npc, GetHashKey(weapon))
    end
end

local function MakePedHatePlayer(npc)
    local weapon = GraveDigging.AngryPedWeapons[math.random(1, #GraveDigging.AngryPedWeapons)]
    GiveWeaponToPed(npc, GetHashKey(weapon), 1, false, true)
    SetCurrentPedWeapon(npc, GetHashKey(weapon), true)
    SetPedMaxHealth(npc, 200)
    SetPedArmour(npc, 200)
    SetCanAttackFriendly(npc, false, true)
    TaskCombatPed(npc, PlayerPedId(), 0, 16)
    SetPedCombatAttributes(npc, 46, true)
    SetPedCombatAttributes(npc, 0, false)
    SetPedCombatAbility(npc, 100)
    SetPedRelationshipGroupHash(npc, `HATES_PLAYER`)
    SetPedAccuracy(npc, 60)
    SetPedFleeAttributes(npc, 0, 0)
    SetPedKeepTask(npc, true)
    SetBlockingOfNonTemporaryEvents(npc, true)
end

local function CleanupEntities()
    for _, v in ipairs(Coffins) do
        if DoesEntityExist(v) then
            DeleteEntity(v)
        end
    end
    Coffins = {}

    for _, v in ipairs(Peds) do
        if DoesEntityExist(v) then
            RemoveWeapons(v)
            DeleteEntity(v)
        end
    end
    Peds = {}
end

local function CanDigNow()
    if IsPedInAnyVehicle(PlayerPedId(), false) then
        return false, 'You cannot dig a grave while in a vehicle.'
    end

    if GraveDigging.OnlyDigAtNight then
        local hour = GetClockHours()
        if hour < GraveDigging.DigStartTime and hour >= GraveDigging.DigEndTime then
            return false, "I'm not doing this in daylight.."
        end
    end

    return true
end

RegisterGraves = function()
    if not GraveDigging or not GraveDigging.Graves then
        return
    end

    for _, grave in ipairs(GraveDigging.Graves) do
        if grave.robbed == nil then
            grave.robbed = false
        end

        Targeting.Zones:AddBox(grave.id, "person-digging", vector3(grave.coords.x, grave.coords.y, grave.coords.z), 2.5, 2.5, {
            heading = grave.coords.w,
            minZ = grave.coords.z - 3.0,
            maxZ = grave.coords.z + 2.0,
        }, {
            {
                icon = 'person-digging',
                text = 'Dig Grave',
                event = 'GraveDigging:Client:DigGrave',
                data = { graveId = grave.id, grave = grave },
                isEnabled = function()
                    return not IsRobbing and not grave.robbed
                end,
                minDist = 2.0,
            },
            {
                icon = 'magnifying-glass',
                text = 'Search Coffin',
                event = 'GraveDigging:Client:SearchGrave',
                data = { graveId = grave.id, grave = grave },
                isEnabled = function()
                    return IsRobbing and ActiveGraveId == grave.id and grave.robbed
                end,
                minDist = 2.0,
            },
        }, 3.0, true)
    end

    print(string.format('[GraveDigging] Registered %s Graves', #GraveDigging.Graves))
end

RegisterNetEvent('GraveDigging:Client:DigGrave', function(_, data)
    if IsRobbing then
        return
    end

    local ok, reason = CanDigNow()
    if not ok then
        Notification:Error(reason)
        return
    end

    data = data or {}
    local grave = data.grave
    local graveId = data.graveId
    Callbacks:ServerCallback('GraveDigging:Server:CanDigGrave', { graveId = graveId }, function(canDig, reason)
        print(string.format('[GraveDigging] CanDigGrave(%s) = %s (%s)', tostring(graveId), tostring(canDig), tostring(reason)))
        if not canDig then
            Notification:Error(reason or "You can't dig this grave right now")
            return
        end

        IsRobbing = true
        ActiveGraveId = graveId

        TaskTurnPedToFaceCoord(PlayerPedId(), grave.coords.x, grave.coords.y, grave.coords.z, 1000)
        Wait(1000)

        local digDuration = 1000 * GraveDigging.DigTime
        local coffin = nil
        local coffinHash = nil
        local coffinEndCoords = nil
        local coffinStartZ = nil
        local digStart = nil

        Progress:ProgressWithStartAndTick({
            name = 'gravedigging_dig',
            duration = digDuration,
            label = 'Digging Grave',
            useWhileDead = false,
            canCancel = true,
            ignoreModifier = true,
            controlDisables = {
                disableMovement = true,
                disableCarMovement = true,
                disableMouse = false,
                disableCombat = true,
            },
            animation = {
                animDict = 'random@burial',
                anim = 'a_burial',
                flags = 1,
            },
            prop = {
                model = 'prop_tool_shovel',
                bone = 28422,
                coords = {
                    x = 0.0,
                    y = 0.0,
                    z = 0.24,
                },
                rotation = {
                    x = 0.0,
                    y = 0.0,
                    z = 0.0,
                },
            },
        }, function()
            digStart = GetGameTimer()
            local coffinModel = GraveDigging.CoffinModels[math.random(1, #GraveDigging.CoffinModels)] or 'prop_coffin_02'
            coffinHash = LoadModel(coffinModel)
            coffin = CreateObject(coffinHash, grave.coords.x, grave.coords.y, grave.coords.z - 1.0, true, true, true)
            Coffins[#Coffins + 1] = coffin
            SetEntityHeading(coffin, grave.coords.w + (GraveDigging.CoffinHeadingBase or 180.0) + (GraveDigging.CoffinHeadingOffset or 0.0))
            PlaceObjectOnGroundProperly(coffin)
            local placed = GetEntityCoords(coffin)
            coffinEndCoords = vector3(placed.x, placed.y, placed.z)
            coffinStartZ = coffinEndCoords.z - 1.0
            SetEntityCoordsNoOffset(coffin, coffinEndCoords.x, coffinEndCoords.y, coffinStartZ, false, false, false)
            FreezeEntityPosition(coffin, true)
            SetModelAsNoLongerNeeded(coffinHash)
        end, function()
            if not coffin or not DoesEntityExist(coffin) or not coffinEndCoords or not coffinStartZ or not digStart then
                return
            end
            local p = (GetGameTimer() - digStart) / digDuration
            if p < 0.0 then p = 0.0 end
            if p > 1.0 then p = 1.0 end
            local z = coffinStartZ + ((coffinEndCoords.z - coffinStartZ) * p)
            SetEntityCoordsNoOffset(coffin, coffinEndCoords.x, coffinEndCoords.y, z, false, false, false)
        end, function(cancelled)
            if not cancelled then
                if coffin and DoesEntityExist(coffin) and coffinEndCoords then
                    SetEntityCoordsNoOffset(coffin, coffinEndCoords.x, coffinEndCoords.y, coffinEndCoords.z, false, false, false)
                    FreezeEntityPosition(coffin, true)
                end
                TriggerServerEvent('GraveDigging:Server:SetGraveRobbed', graveId, true)
            else
                IsRobbing = false
                ActiveGraveId = nil
                CleanupEntities()
            end
        end)
    end, tostring(GetGameTimer()))
end)

RegisterNetEvent('GraveDigging:Client:SearchGrave', function(_, data)
    data = data or {}
    local grave = data.grave
    local graveId = data.graveId

    TaskTurnPedToFaceCoord(PlayerPedId(), grave.coords.x, grave.coords.y, grave.coords.z, 1000)
    Wait(1000)

    Progress:Progress({
        name = 'gravedigging_search',
        duration = 1000 * GraveDigging.SearchTime,
        label = 'Searching Coffin',
        useWhileDead = false,
        canCancel = false,
        ignoreModifier = true,
        controlDisables = {
            disableMovement = true,
            disableCarMovement = true,
            disableMouse = false,
            disableCombat = true,
        },
        animation = {
            animDict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
            anim = 'machinic_loop_mechandplayer',
            flags = 1,
        },
    }, function(cancelled)
        if not cancelled then
            CleanupEntities()
            IsRobbing = false
            ActiveGraveId = nil

            TriggerServerEvent('GraveDigging:Server:GraveLoot', graveId)

            if math.random(1, 100) <= GraveDigging.AngryPedSpawnChance then
                LoadModel('a_m_m_hillbilly_01')
                local spawnCoords = vec3(grave.coords.x + math.random(-20, 20), grave.coords.y + math.random(-20, 20), grave.coords.z)
                local npc = CreatePed(4, GetHashKey('a_m_m_hillbilly_01'), spawnCoords.x, spawnCoords.y, spawnCoords.z, 0.0, true, false)
                Peds[#Peds + 1] = npc
                PlaceObjectOnGroundProperly(npc)
                MakePedHatePlayer(npc)

                if math.random(1, 100) <= GraveDigging.SecondAngryPedChance then
                    local spawnCoords2 = vec3(grave.coords.x + math.random(-20, 20), grave.coords.y + math.random(-20, 20), grave.coords.z)
                    local npc2 = CreatePed(4, GetHashKey('a_m_m_hillbilly_01'), spawnCoords2.x, spawnCoords2.y, spawnCoords2.z, 0.0, true, false)
                    Peds[#Peds + 1] = npc2
                    PlaceObjectOnGroundProperly(npc2)
                    MakePedHatePlayer(npc2)
                end
            end
        end
    end)
end)

RegisterNetEvent('GraveDigging:Client:SetGraveRobbed', function(graveId, state)
    for _, grave in ipairs(GraveDigging.Graves) do
        if grave.id == graveId then
            grave.robbed = state
            break
        end
    end
end)

AddEventHandler('Characters:Client:Spawn', function()
    Wait(1000)
    _spawnReady = true
    print('[GraveDigging] Character Spawned')
    TryInit()
end)

AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then
        return
    end

    CreateThread(function()
        Wait(500)
        if LocalPlayer and LocalPlayer.state and (LocalPlayer.state.loggedIn or LocalPlayer.state.Character ~= nil) then
            _spawnReady = true
            TryInit()
        end
    end)
end)

AddEventHandler('Characters:Client:Logout', function()
    CleanupEntities()
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        CleanupEntities()
    end
end)
