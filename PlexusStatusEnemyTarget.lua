local L = setmetatable({}, {__index = function(t, k) t[k] = k return k end})

if GetLocale()=="zhCN" then
    L["Enemy target"] = "敌方目标"
    L["Enemy incoming spell"] = "敌方施法目标"
    L["Target Raid Icon"] = "团员目标的标记"
    L['Update Interval'] = "刷新时间间隔"
elseif GetLocale()=="zhTW" then
    L["Enemy target"] = "怪物目標"
    L["Enemy incoming spell"] = "怪物施法目標"
    L["Target Raid Icon"] = "團員目標的標記"
elseif GetLocale()=="ruRU" then
    L["Enemy target"] = "Цель врага"
    L["Enemy incoming spell"] = "Цель заклинания"
end

local UnitCastingInfo = _G.UnitCastingInfo
local UnitChannelInfo = _G.UnitChannelInfo
local UnitGUID = _G.UnitGUID
local GetSpellInfo = _G.C_Spell and _G.C_Spell.GetSpellInfo or _G.GetSpellInfo
local UnitInRaid = _G.UnitInRaid
local UnitInParty = _G.UnitInParty
local GetTime = _G.GetTime
local wipe = _G.wipe
local GetRaidTargetIndex = _G.GetRaidTargetIndex

local Plexus = _G.Plexus
local PlexusRoster = Plexus:GetModule("PlexusRoster")

local PlexusStatusEnemyTarget = Plexus:GetModule("PlexusStatus"):NewModule("PlexusStatusEnemyTarget", "AceTimer-3.0")
PlexusStatusEnemyTarget.menuName = L["Enemy incoming spell"]

--{{{ AceDB defaults


PlexusStatusEnemyTarget.defaultDB = {
    interval = 0.1,
    debug = false,
    alert_et_target = {
        text =  "!!",
        enable = true,
        color = { r = 1, g = 1, b = 0, a = 1 },
        priority = 98,
        range = false,
    },
    alert_et_incoming = {
        text =  "->",
        enable = true,
        color = { r = 1, g = 1, b = 0, a = 1 },
        priority = 98,
        range = false,
    },
    raid_icon_target = {
        enable = false,
        color = { r = 1, g = 1, b = 0, a = 1 },
        priority = 50,
        range = false, --other options are raid_icon options
    },
}

--}}}

local options = {
    type = "group",
    name = L["Enemy incoming spell"],
    order = 1600,
    args = {
        update_interval = {
            type = 'range', min = 0.01, max = 0.3, step = 0.01,
            name = L['Update Interval'],
            get = function()
                return PlexusStatusEnemyTarget.db.profile.interval
            end,
            set = function(_, v)
                PlexusStatusEnemyTarget.db.profile.interval = v
                if PlexusStatusEnemyTarget.timer then
                    PlexusStatusEnemyTarget:CancelTimer(PlexusStatusEnemyTarget.timer)
                    PlexusStatusEnemyTarget.timer = PlexusStatusEnemyTarget:ScheduleRepeatingTimer("OnUpdate", PlexusStatusEnemyTarget.db.profile.interval)
                end
            end,
        }
    }
}

Plexus.options.args.PlexusStatusEnemyTarget = options

function PlexusStatusEnemyTarget:OnInitialize()
    self.super.OnInitialize(self)
    self:RegisterStatus("alert_et_target", L["Enemy target"], nil, false)
    self:RegisterStatus("alert_et_incoming", L["Enemy incoming spell"], nil, false)
    self:RegisterStatus("raid_icon_target", L["Target Raid Icon"], nil, false)
end

local spellstarts = {}          --save spell casting event, [CastingNpcGUID] -> spellnames
local spellstarts_channel = {}  --pairs with spellstarts, indicate channeling or not.
local incomings_time =   {}     --save incoming on raid members, [RosterGUID] -> timeLeft
local incomings_npc =   {}     --save incoming on raid members, [RosterGUID] -> CastingNpcGUID
local castings =    {}          --revert map of incomings, always match, [CastingNpcGUID] -> RosterGUID

function PlexusStatusEnemyTarget:IsHostileNpcUnit(guid, flag)
    --return true
    --flag == 0x1248
    --local bit3 = string.byte(guid, 5) if( bit3==51 or bit3==66 ) then return true end
    return not PlexusRoster:IsGUIDInRaid(guid)
end

local function getSpellName(spellid)
    return C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellid).name or GetSpellInfo(spellid)
end

local function getSpellIcon(spellid)
    return C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellid).iconID or select(3,GetSpellInfo(spellid))
end

function PlexusStatusEnemyTarget:COMBAT_LOG_EVENT_UNFILTERED()
    local timestamp, event, hideCaster, sid, sname, sflag, srflag, tid, tname, tflag, trflag, spellid = _G.CombatLogGetCurrentEventInfo()
    if event=="SPELL_CAST_START" then
        if self:IsHostileNpcUnit(sid, sflag) then
            spellstarts[sid] = getSpellName(spellid)   --save spell name for next checking target of the caster GUID
            spellstarts_channel[sid] = nil
        end
    elseif event=="SPELL_CAST_SUCCESS" then
        local spell_name = getSpellName(spellid)
        if castings[sid] then  --normal cast, success is finish casting
            self:TryToStop(sid)
        elseif self:IsHostileNpcUnit(sid, sflag) then
            spellstarts[sid] = spell_name
            spellstarts_channel[sid] = true
        end
    elseif event=="SPELL_INTERRUPT" then
        self:TryToStop(tid)
    elseif event=="UNIT_DIED" then
        self:TryToStop(tid)
    end
end

function PlexusStatusEnemyTarget:TryToStop(npcguid)
    local roster_guid = castings[npcguid]
    if(roster_guid) then
        PlexusStatusEnemyTarget.core:SendStatusLost(roster_guid, "alert_et_incoming")
        incomings_time[roster_guid] = nil
        incomings_npc[roster_guid] = nil
        castings[npcguid] = nil
    end
end

function PlexusStatusEnemyTarget:UnitCastStop(unitid, name, rank)
    self:TryToStop(UnitGUID(unitid))
end

function PlexusStatusEnemyTarget:ResetVariables()
    wipe(spellstarts)
    wipe(spellstarts_channel)
    for guid, v in pairs(castings) do
        self:TryToStop(guid)
    end
end


function PlexusStatusEnemyTarget:OnStatusEnable(status)
    --thanks onyxmaster for finding a way to make alert_et_incoming independent.
    if (status=="alert_et_incoming" or status=="alert_et_target") then
        if not PlexusStatusEnemyTarget.timer then
            PlexusStatusEnemyTarget.timer = self:ScheduleRepeatingTimer("OnUpdate", PlexusStatusEnemyTarget.db.profile.interval)
        end

        if (status=="alert_et_incoming") then
            self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
            self:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP", "UnitCastStop") --caster stop manually, only for players.
            self:RegisterEvent("UNIT_SPELLCAST_STOP", "UnitCastStop")
            self:RegisterEvent("PLAYER_REGEN_DISABLED", "ResetVariables")
            self:RegisterEvent("PLAYER_REGEN_ENABLED", "ResetVariables")
        end
    end
end

function PlexusStatusEnemyTarget:OnStatusDisable(status)

    if (status=="alert_et_target" or status=="alert_et_incoming") then
        if not PlexusStatusEnemyTarget.db.profile["alert_et_target"].enable and not PlexusStatusEnemyTarget.db.profile["alert_et_incoming"].enable then
            if PlexusStatusEnemyTarget.timer then
                self:CancelTimer(PlexusStatusEnemyTarget.timer)
                PlexusStatusEnemyTarget.timer = nil
            end
        end

        if (status=="alert_et_incoming") then
            self:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
            self:UnregisterEvent("UNIT_SPELLCAST_CHANNEL_STOP") --caster stop manually, only for players.
            self:UnregisterEvent("UNIT_SPELLCAST_STOP")
            self:UnregisterEvent("PLAYER_REGEN_DISABLED")
            self:UnregisterEvent("PLAYER_REGEN_ENABLED")
        end
    end
end

local newcount = {}

--cache for string concat, learn from LibBanzai
local targets = setmetatable({}, {__index = function(self, key) self[key] = key .. "target" return self[key] end})

function PlexusStatusEnemyTarget:OnUpdate()
    for guid, v in pairs(incomings_time) do
        v = v - PlexusStatusEnemyTarget.db.profile.interval
        incomings_time[guid] = v
        if (v<=0) then
            PlexusStatusEnemyTarget.core:SendStatusLost(guid,"alert_et_incoming")
            castings[incomings_npc[guid]] = nil
            incomings_time[guid] = nil
            incomings_npc[guid] = nil
        end
    end

    table.wipe(newcount)

    self:UpdateUnit("focus")
    self:UpdateUnit("mouseover")
    self:UpdateUnit("boss1") self:UpdateUnit("boss2") self:UpdateUnit("boss3") self:UpdateUnit("boss4")
    self:UpdateUnit("arena1") self:UpdateUnit("arena2") self:UpdateUnit("arena3") self:UpdateUnit("arena4") self:UpdateUnit("arena5")
    for guid, unitid in PlexusRoster:IterateRoster() do
        self:UpdateUnit(targets[unitid])
    end

    if (PlexusStatusEnemyTarget.db.profile["alert_et_target"].enable) then
        for guid, unitid in PlexusRoster:IterateRoster() do
            if(newcount[guid]) then
                local settings = PlexusStatusEnemyTarget.db.profile.alert_et_target
                PlexusStatusEnemyTarget.core:SendStatusGained(
                    guid,
                    "alert_et_target",
                    settings.priority,
                    nil, --(settings.range and 40),
                    settings.color,
                    settings.text,
                    nil,
                    nil,
                    settings.icon
                )
            else
                PlexusStatusEnemyTarget.core:SendStatusLost(guid, "alert_et_target")
            end
        end
    end

    if (PlexusStatusEnemyTarget.db.profile["raid_icon_target"].enable) then
        for guid, unitid in PlexusRoster:IterateRoster() do
            local target = targets[unitid]
            local i = GetRaidTargetIndex(target)
            if i and not (UnitInRaid(target) or UnitInParty(target)) then
                self.PlexusStatusRaidIcon = self.PlexusStatusRaidIcon or Plexus:GetModule("PlexusStatus"):GetModule("PlexusStatusRaidIcon").db
                local settings = PlexusStatusEnemyTarget.db.profile.raid_icon_target
                local settings2 = self.PlexusStatusRaidIcon.profile.raid_icon
                PlexusStatusEnemyTarget.core:SendStatusGained( guid, "raid_icon_target",
                    settings.priority,
                    nil, --(settings.range and 40),
                    settings2.color[i],
                    settings2.text[i],
                    nil,
                    nil,
                    settings2.icon[i]
                )
            else
                PlexusStatusEnemyTarget.core:SendStatusLost(guid, "raid_icon_target")
            end
        end
    end
end

local icon_map
if Plexus:IsRetailWow() or Plexus:IsWrathWow() or Plexus:IsCataWow() then
    icon_map = {
        [getSpellName(70541)] = getSpellIcon(528), --invest for lichking
    }
end
if Plexus:IsClassicWow() then
    icon_map = {
        --[getSpellName(70541)] = select(3, GetSpellInfo(528)), --invest for lichking
    }
end

local ICON_TEX_COORDS = { left = 0.06, right = 0.94, top = 0.06, bottom = 0.94 }

--find all possible unit and their casting info
function PlexusStatusEnemyTarget:UpdateUnit(npcunit)
    local spell, _, _, icon, startTime, endTime
    local npcguid = UnitGUID(npcunit)
    if( npcguid and self:IsHostileNpcUnit(npcguid) ) then
        local guid = UnitGUID(targets[npcunit])
        if guid and PlexusRoster:IsGUIDInRaid(guid) then
            newcount[guid]=true  --for alert_et_target

            local spell_name = spellstarts[npcguid]
            if(spell_name) then
                --if(spellstarts_channel[npcguid]) then
                --    spell, _, _, icon, startTime, endTime = UnitChannelInfo(npcunit)
                --else
                --    spell, _, _, icon, startTime, endTime = UnitCastingInfo(npcunit)
                --end

                if(spellstarts_channel[npcguid]) then
                    spell, _, icon, startTime, endTime = UnitChannelInfo(npcunit)
                else
                    spell, _, icon, startTime, endTime = UnitCastingInfo(npcunit)
                end
                spellstarts[npcguid] = nil
                spellstarts_channel[npcguid] = nil

                if(spell and spell == spell_name) then
                    icon = icon_map[spell_name] or icon
                    incomings_time[guid] = endTime/1000-GetTime()
                    incomings_npc[guid] = npcguid
                    castings[npcguid] = guid

                    local settings = PlexusStatusEnemyTarget.db.profile.alert_et_incoming
                    PlexusStatusEnemyTarget.core:SendStatusGained(
                        guid,
                        "alert_et_incoming",
                        settings.priority,
                        nil, --(settings.range and 40),
                        settings.color,
                        settings.text,
                        nil,
                        nil,
                        icon,
                        startTime/1000,
                        (endTime-startTime)/1000 + PlexusStatusEnemyTarget.db.profile.interval/2, --add interval to avoid a blink before hide.
                        nil,
                        ICON_TEX_COORDS
                    )
                end
            end
        end
    end
end
