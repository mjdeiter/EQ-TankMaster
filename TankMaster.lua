--[[
TankMaster.lua v1.0 (2025-05-25)
Combined Aggro and Shield-Swap logic for EverQuest tanks.
Credit: Alektra <Lederhosen> | mjdeiter/EQ-TankMaster | MacroQuest/E3 Compatible
Usage: Place in your Lua scripts folder and load via /lua run TankMaster
--]]

local mq = require('mq')

-- Version banner
local SCRIPT_VERSION = "v1.0"
local SCRIPT_DATE = "2025-05-25"
mq.cmd(string.format('/echo \\agCredit: \\acAlektra <Lederhosen>\\ax | \\ayTankMaster.lua %s (%s)\\ax', SCRIPT_VERSION, SCRIPT_DATE))

--------------------------------------------------------
-- CONFIGURATION SECTION
--------------------------------------------------------

-- User-editable: item and ability names, thresholds, etc.

local ABILITIES = {
    taunt = "Taunt",
    ae_taunts = { "Area Taunt", "Rampage Taunt" },
    battle_leap = "Battle Leap",
    knee_strike = "Knee Strike",
    throat_jab = "Throat Jab",
    bash = "Bash",
    kick = "Kick"
}

local CLICKIES = {
    { name = "Forsaken Sword of the Morning", condition = function() return lost_aggro() end },
    { name = "Forsaken Sword of Skyfire", condition = function() return lost_aggro() end },
}

local DEFENSIVES = {
    { threshold = 40, action = function() use_item("Forsaken Shieldstorm") end },
    { threshold = 25, action = function() use_ability("Armor of Experience") end },
}

-- How often (in seconds) to attempt shield/offhand swaps for Bash
local BASH_REQUEST_COOLDOWN = 4

--------------------------------------------------------
-- STATE
--------------------------------------------------------

local last_bash_request = 0

--------------------------------------------------------
-- LOGGING
--------------------------------------------------------

local function log(message, level)
    local prefix = os.date('%Y-%m-%d %H:%M:%S') .. " [TankMaster] "
    mq.cmdf('/echo %s%s: %s', prefix, level or "INFO", message)
end

--------------------------------------------------------
-- UTILITY FUNCTIONS
--------------------------------------------------------

local function has_shield()
    local slot14 = mq.TLO.Me.Inventory(14)
    return slot14() ~= nil and slot14.Type() == "Shield"
end

local function has_offhand()
    local slot14 = mq.TLO.Me.Inventory(14)
    return slot14() ~= nil and slot14.Type() ~= "Shield"
end

local function is_in_combat()
    return mq.TLO.Me.Combat()
end

local function safe_pct_aggro()
    local pct = mq.TLO.Me.PctAggro()
    if type(pct) ~= "number" then
        log("safe_pct_aggro(): PctAggro() returned nil or non-number!", "ERROR")
        return 0
    end
    return pct
end

local function is_tanking()
    return safe_pct_aggro() >= 99
end

function lost_aggro()
    local pct_aggro = safe_pct_aggro()
    local tot = mq.TLO.Me.TargetOfTarget()
    local tot_class = (tot and tot.Class and tot.Class.ShortName()) or ""
    return pct_aggro < 100 and not (tot_class:find("WAR") or tot_class:find("PAL") or tot_class:find("SHD"))
end

local function super_close()
    local dist = mq.TLO.Target.Distance()
    return dist and dist < 10 and mq.TLO.Me.CountSongs() < 19 and not mq.TLO.Me.Moving()
end

local function can_use_ability(name)
    local ok, ready = pcall(function() return mq.TLO.Me.AbilityReady(name)() end)
    if not ok then log("Failed to check ability: " .. name, "ERROR"); return false end
    return ready
end

local function use_ability(name)
    if can_use_ability(name) then
        log("Using ability: " .. name)
        mq.cmdf('/doability "%s"', name)
    end
end

local function can_use_item(name)
    local ok, ready = pcall(function() return mq.TLO.FindItem(name)() and mq.TLO.Me.ItemReady(name)() end)
    if not ok then log("Failed to check item: " .. name, "ERROR"); return false end
    return ready
end

function use_item(name)
    if can_use_item(name) then
        log("Using item: " .. name)
        mq.cmdf('/useitem "%s"', name)
    end
end

-- Health-based defensive logic
local function safe_pct_hps()
    local hp = mq.TLO.Me.PctHPs()
    if type(hp) ~= "number" then
        log("safe_pct_hps(): PctHPs() returned nil or non-number!", "ERROR")
        return 100
    end
    return hp
end

local function check_defensive_triggers()
    local hp = safe_pct_hps()
    for _, trigger in ipairs(DEFENSIVES) do
        if hp <= trigger.threshold then
            local ok, err = pcall(trigger.action)
            if not ok then
                log("Error executing defensive action at "..trigger.threshold.."%: "..tostring(err), "ERROR")
            else
                log("Triggered defensive action at "..trigger.threshold.."%")
            end
        end
    end
end

--------------------------------------------------------
-- SHIELD/OFFHAND SWAP LOGIC
--------------------------------------------------------

-- Equip shield in secondary slot
local function equip_shield()
    -- Find a shield in inventory (not equipped) and equip it
    for i=23,32 do
        local item = mq.TLO.Me.Inventory(i)
        if item() and item.Type() == "Shield" then
            log("AutoShield: Equipping shield: "..item.Name())
            mq.cmdf('/exchange "%s" 14', item.Name())
            mq.delay(300) -- Let the swap happen
            return true
        end
    end
    log("AutoShield: No shield found in inventory!", "WARN")
    return false
end

-- Equip first non-shield weapon in secondary slot
local function equip_offhand()
    for i=23,32 do
        local item = mq.TLO.Me.Inventory(i)
        if item() and item.Type() ~= "Shield" and item() ~= nil then
            log("AutoShield: Equipping offhand non-shield: "..item.Name())
            mq.cmdf('/exchange "%s" 14', item.Name())
            mq.delay(300)
            return true
        end
    end
    log("AutoShield: No offhand (non-shield) found in inventory!", "WARN")
    return false
end

--------------------------------------------------------
-- MAIN LOOP
--------------------------------------------------------

while true do
    local status, err = pcall(function()
        local group_members = mq.TLO.Group.Members()
        local target_id = mq.TLO.Target.ID()
        local target_pcthps = mq.TLO.Target.PctHPs()
        local target_beneficial = mq.TLO.Target.Beneficial()
        if is_in_combat() and
           group_members and group_members > 1 and
           target_id and target_pcthps and target_pcthps > 0 and
           not target_beneficial then

            -- AGGRO ABILITIES
            use_ability(ABILITIES.taunt)
            for _, ae in ipairs(ABILITIES.ae_taunts) do
                use_ability(ae)
            end

            -- SHIELD/OFFHAND SWAP: For Bash
            if can_use_ability(ABILITIES.bash) then
                local now = os.time()
                local diff = now - last_bash_request

                -- If Bash is up but no shield is equipped, equip shield for Bash
                if not has_shield() and diff > BASH_REQUEST_COOLDOWN then
                    log("Requesting shield swap for Bash.")
                    equip_shield()
                    last_bash_request = now
                elseif has_shield() then
                    use_ability(ABILITIES.bash)
                    log("Requesting offhand swap after Bash.")
                    equip_offhand()
                    last_bash_request = now
                end
            end

            -- Tanking logic
            if is_tanking() then
                if has_shield() then
                    use_ability(ABILITIES.knee_strike)
                    use_ability(ABILITIES.throat_jab)
                end
            else
                if has_offhand() then use_ability(ABILITIES.battle_leap) end
                use_ability(ABILITIES.kick)
            end

            -- Proximity logic
            if super_close() then use_ability(ABILITIES.battle_leap) end

            -- Clicky logic
            for _, clicky in ipairs(CLICKIES) do
                local ok, want_to_use = pcall(clicky.condition)
                if not ok then
                    log("Error evaluating clicky condition for " .. clicky.name, "ERROR")
                elseif want_to_use then
                    use_item(clicky.name)
                end
            end

            -- Health-based defense
            check_defensive_triggers()
        end
    end)
    if not status then
        log("Main loop error: "..tostring(err), "ERROR")
    end
    mq.delay(2000)
end
