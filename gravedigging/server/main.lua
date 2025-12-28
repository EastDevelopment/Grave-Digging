if not GraveDigging or not GraveDigging.Enable then return end

local Callbacks, Fetch, Inventory, Execute, EmergencyAlerts

local _graves = {}

AddEventHandler('GraveDigging:Shared:DependencyUpdate', function()
    Callbacks = exports['mythic-base']:FetchComponent('Callbacks')
    Fetch = exports['mythic-base']:FetchComponent('Fetch')
    Inventory = exports['mythic-base']:FetchComponent('Inventory')
    Execute = exports['mythic-base']:FetchComponent('Execute')
    EmergencyAlerts = exports['mythic-base']:FetchComponent('EmergencyAlerts')
end)

local function GetPoliceCount()
    return GlobalState['Duty:police'] or 0
end

local function HasAnyDigItem(source)
    local plyr = Fetch:Source(source)
    if not plyr then return false end
    local char = plyr:GetData('Character')
    if not char then return false end

    local sid = char:GetData('SID')
    for _, v in ipairs(GraveDigging.DigItems or {}) do
        local item = v
        local count = 1
        if type(v) == 'table' then
            item = v.item
            count = v.count or 1
        end
        if item and Inventory.Items:Has(sid, 1, item, count) then
            return true
        end
    end

    return false
end

local function EnsureGraveState(graveId)
    if _graves[graveId] == nil then
        _graves[graveId] = {
            robbed = false,
            searched = false,
        }
    end
end

local function GetGraveById(graveId)
    if not GraveDigging or not GraveDigging.Graves then
        return nil
    end
    for _, grave in ipairs(GraveDigging.Graves) do
        if grave.id == graveId then
            return grave
        end
    end
    return nil
end

local function IsNearGrave(source, graveId)
    local grave = GetGraveById(graveId)
    if not grave or not grave.coords then
        return false
    end
    local ped = GetPlayerPed(source)
    if not ped then
        return false
    end
    local coords = GetEntityCoords(ped)
    local dist = #(coords - vector3(grave.coords.x, grave.coords.y, grave.coords.z))
    return dist <= (GraveDigging.InteractDistance or 3.0)
end

AddEventHandler('Core:Shared:Ready', function()
    exports['mythic-base']:RequestDependencies('GraveDigging', {
        'Callbacks',
        'Fetch',
        'Inventory',
        'Execute',
        'EmergencyAlerts',
    }, function(error)
        if #error > 0 then
            return
        end
        TriggerEvent('GraveDigging:Shared:DependencyUpdate')

        Callbacks:RegisterServerCallback('GraveDigging:Server:GetConfig', function(source, data, cb)
            cb(GraveDigging)
        end)

        Callbacks:RegisterServerCallback('GraveDigging:Server:CanDigGrave', function(source, data, cb)
            local graveId = data.graveId or (type(data) == 'table' and data[1])
            if not graveId then
                cb(false, 'Invalid Grave')
                return
            end

            EnsureGraveState(graveId)

            if not IsNearGrave(source, graveId) then
                cb(false, 'Too Far Away')
                return
            end

            if _graves[graveId].robbed then
                cb(false, 'This grave has been disturbed recently.')
                return
            end

            if GraveDigging.RequirePolice and GetPoliceCount() < (GraveDigging.RequiredPoliceCount or 0) then
                cb(false, 'Not enough police on duty.')
                return
            end

            if not HasAnyDigItem(source) then
                cb(false, "You don't have the right tool.")
                return
            end

            cb(true)
        end)
    end)
end)

RegisterServerEvent('GraveDigging:Server:SetGraveRobbed', function(graveId, state)
    EnsureGraveState(graveId)

    if not IsNearGrave(source, graveId) then
        return
    end

    _graves[graveId].robbed = state and true or false
    if _graves[graveId].robbed then
        _graves[graveId].searched = false
    end
    TriggerClientEvent('GraveDigging:Client:SetGraveRobbed', -1, graveId, _graves[graveId].robbed)

    if _graves[graveId].robbed then
        CreateThread(function()
            SetTimeout(1000 * 60 * (GraveDigging.ResetTime or 15), function()
                EnsureGraveState(graveId)
                _graves[graveId].robbed = false
                _graves[graveId].searched = false
                TriggerClientEvent('GraveDigging:Client:SetGraveRobbed', -1, graveId, false)
            end)
        end)
    end
end)

local function MaybeAlertPolice(src)
    if not EmergencyAlerts then
        return
    end

    if not GraveDigging.PoliceAlertChance or GraveDigging.PoliceAlertChance <= 0 then
        return
    end

    if math.random(1, 100) > GraveDigging.PoliceAlertChance then
        return
    end

    local ped = GetPlayerPed(src)
    if not ped then return end
    local coords = GetEntityCoords(ped)

    EmergencyAlerts:Create(
        '10-31',
        'Grave Robbery',
        1,
        { x = coords.x, y = coords.y, z = coords.z },
        'Suspicious activity reported at the graveyard.',
        false,
        {
            icon = 66,
            size = 0.9,
            color = 30,
            duration = (60 * 3),
        },
        nil,
        false,
        false,
        { type = 'gravedigging' }
    )
end

RegisterServerEvent('GraveDigging:Server:GraveLoot', function(graveId)
    local src = source

    EnsureGraveState(graveId)

    if not IsNearGrave(src, graveId) then
        return
    end

    if not _graves[graveId].robbed then
        Execute:Client(src, 'Notification', 'Error', 'You need to dig the grave first.')
        return
    end

    if _graves[graveId].searched then
        Execute:Client(src, 'Notification', 'Error', 'You already searched this coffin.')
        return
    end

    if not HasAnyDigItem(src) then
        Execute:Client(src, 'Notification', 'Error', "You don't have the right tool.")
        return
    end

    local plyr = Fetch:Source(src)
    if not plyr then return end
    local char = plyr:GetData('Character')
    if not char then return end

    local sid = char:GetData('SID')

    if math.random(1, 100) <= (GraveDigging.NothingFoundChance or 0) then
        Execute:Client(src, 'Notification', 'Error', 'You found nothing.')
        _graves[graveId].searched = true
        MaybeAlertPolice(src)
        return
    end

    local commonDrops = math.random(1, 2)
    for i = 1, commonDrops do
        local item = GraveDigging.GraveItems[math.random(1, #GraveDigging.GraveItems)]
        if item then
            Inventory:AddItem(sid, item, math.random(1, 2), {}, 1)
        end
    end

    if math.random(1, 100) <= (GraveDigging.RareItemDropChance or 0) then
        local item = GraveDigging.RareItems[math.random(1, #GraveDigging.RareItems)]
        if item then
            Inventory:AddItem(sid, item, 1, {}, 1)
        end
    end

    _graves[graveId].searched = true

    MaybeAlertPolice(src)
end)
