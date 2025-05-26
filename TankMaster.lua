--[[
TankMaster.lua v1.3 (2025-05-26)
Combined Aggro and Shield-Swap logic for EverQuest tanks.
Credit: Alektra <Lederhosen> | mjdeiter/EQ-TankMaster | MacroQuest/E3 Compatible
Usage: Place in your Lua scripts folder and load via /lua run TankMaster

Changelog:
- v1.3: Fixed inventory scanning to use 0-based indexing for bag slots and added FindItem fallback for shield detection
- v1.2: Added continuous loop, fixed syntax errors, and improved logging
- v1.1: Initial release with basic aggro and shield-swap functionality
--]]

local mq = require('mq')

-- Version banner
local SCRIPT_VERSION = "v1.3"
local SCRIPT_DATE = "2025-05-26"
mq.cmd(string.format('/echo \\agCredit: \\acAlektra <Lederhosen>\\ax | \\ayTankMaster.lua %s (%s)\\ax', SCRIPT_VERSION, SCRIPT_DATE))

--------------------------------------------------------
-- CONFIGURATION SECTION
--------------------------------------------------------

-- DEBUG MODE: Set to true for verbose logging
local DEBUG_MODE = true

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

local function debug_log(message)
    if DEBUG_MODE then
        log(message, "DEBUG")
    end
end

--------------------------------------------------------
-- UTILITY FUNCTIONS
--------------------------------------------------------

local function has_shield()
    local slot14 = mq.TLO.Me.Inventory(14)
    local result = slot14() ~= nil and slot14.Type() == "Shield"
    debug_log("has_shield() check: slot14 exists=" .. tostring(slot14() ~= nil) .. 
              ", type=" .. tostring(slot14() and slot14.Type() or "nil") .. 
              ", result=" .. tostring(result))
    return result
end

local function has_offhand()
    local slot14 = mq.TLO.Me.Inventory(14)
    local result = slot14() ~= nil and slot14.Type() ~= "Shield"
    debug_log("has_offhand() check: slot14 exists=" .. tostring(slot14() ~= nil) .. 
              ", type=" .. tostring(slot14() and slot14.Type() or "nil") .. 
              ", result=" .. tostring(result))
    return result
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
                log("triggered defensive action at " .. trigger.threshold .. "%")
            end
        end
    end
end

--------------------------------------------------------
-- COMPREHENSIVE INVENTORY DEBUGGING
--------------------------------------------------------

-- Debug function to print all inventory slots
local function debug_all_inventory()
    if not DEBUG_MODE then return end
    
    log("=== FULL INVENTORY DEBUG ===", "DEBUG")
    
    -- Check main equipment slots
    log("--- EQUIPMENT SLOTS ---", "DEBUG")
    local equipment_slots = {
        [0] = "Charm", [1] = "Left Ear", [2] = "Head", [3] = "Face", [4] = "Right Ear",
        [5] = "Neck", [6] = "Shoulders", [7] = "Arms", [8] = "Back", [9] = "Left Wrist",
        [10] = "Right Wrist", [11] = "Range", [12] = "Hands", [13] = "Primary", [14] = "Secondary",
        [15] = "Left Ring", [16] = "Right Ring", [17] = "Chest", [18] = "Legs", [19] = "Feet",
        [20] = "Waist", [21] = "Powersource", [22] = "Ammo"
    }
    
    for slot, name in pairs(equipment_slots) do
        local item = mq.TLO.Me.Inventory(slot)
        if item() then
            log(string.format("Slot %d (%s): %s (Type: %s, ID: %s)", slot, name, item.Name(), item.Type(), item.ID()), "DEBUG")
        end
    end
    
    -- Check general inventory slots (23-32)
    log("--- GENERAL INVENTORY SLOTS ---", "DEBUG")
    for i = 23, 32 do
        local item = mq.TLO.Me.Inventory(i)
        if item() then
            log(string.format("Slot %d: %s (Type: %s, ID: %s)", i, item.Name(), item.Type(), item.ID()), "DEBUG")
            
            -- Check if it's a container
            if item.Container() and item.Container() > 0 then
                log(string.format("  Container with %d slots:", item.Container()), "DEBUG")
                for j = 0, item.Container() - 1 do
                    local bag_item = item.Item(j)
                    if bag_item() then
                        log(string.format("    Bag slot %d: %s (Type: %s, ID: %s)", j, bag_item.Name(), bag_item.Type(), bag_item.ID()), "DEBUG")
                    else
                        log(string.format("    Bag slot %d: Empty", j), "DEBUG")
                    end
                end
            end
        end
    end
    
    -- Check additional slots
    log("--- ADDITIONAL SLOTS ---", "DEBUG")
    local additional_slots = {30, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109}
    for _, slot in ipairs(additional_slots) do
        local item = mq.TLO.Me.Inventory(slot)
        if item() then
            log(string.format("Slot %d: %s (Type: %s, ID: %s)", slot, item.Name(), item.Type(), item.ID()), "DEBUG")
        end
    end
    
    log("=== END INVENTORY DEBUG ===", "DEBUG")
end

-- Debug command handler
local function debug_inventory_command()
    debug_log("Running debug_inventory_command")
    debug_all_inventory()
end

mq.bind('/tankdebug', debug_inventory_command)
log("Debug command registered: /tankdebug", "INFO")

--------------------------------------------------------
-- ENHANCED INVENTORY SCANNING
--------------------------------------------------------

local function scan_inventory_for_type(item_type)
    debug_log("scan_inventory_for_type: Looking for type '" .. item_type .. "'")
    local found_items = {}
    
    for i = 23, 32 do
        local item = mq.TLO.Me.Inventory(i)
        if item() then
            debug_log(string.format("Checking slot %d: %s (Type: %s, ID: %s)", i, item.Name(), item.Type(), item.ID()))
            if item.Type() == item_type then
                table.insert(found_items, {slot = i, name = item.Name(), item = item})
            end
            
            if item.Container() and item.Container() > 0 then
                debug_log(string.format("Slot %d is container with %d slots", i, item.Container()))
                for j = 0, item.Container() - 1 do
                    local bag_item = item.Item(j)
                    if bag_item() then
                        debug_log(string.format("Found item in bag slot %d of slot %d: %s (Type: %s, ID: %s)", j, i, bag_item.Name(), bag_item.Type(), bag_item.ID()))
                        if bag_item.Type() == item_type then
                            table.insert(found_items, {slot = i, bag_slot = j, name = bag_item.Name(), item = bag_item})
                        end
                    else
                        debug_log(string.format("Bag slot %d of slot %d is empty", j, i))
                    end
                end
            end
        end
    end
    debug_log("scan_inventory_for_type: Found " .. #found_items .. " items of type '" .. item_type .. "'")
    return found_items
end

local function find_shield_in_inventory()
    debug_log("find_shield_in_inventory: Starting search")
    
    local equipped_secondary = mq.TLO.Me.Inventory(14)
    if equipped_secondary() then
        debug_log("Secondary slot (14) has item: " .. equipped_secondary.Name() .. " (Type: " .. equipped_secondary.Type() .. ", ID: " .. equipped_secondary.ID() .. ")")
        if equipped_secondary.Type() == "Shield" then
            log("Shield already equipped: " .. equipped_secondary.Name() .. " (slot 14)")
            return {slot = 14, name = equipped_secondary.Name(), item = equipped_secondary, equipped = true}
        end
    else
        debug_log("Secondary slot (14) is empty")
    end
    
    local shields = scan_inventory_for_type("Shield")
    if #shields > 0 then
        log("Found " .. #shields .. " shield(s) in inventory")
        for i, shield in ipairs(shields) do
            local location = shield.bag_slot and ("bag slot " .. shield.bag_slot .. " of slot " .. shield.slot) or ("slot " .. shield.slot)
            log("  Shield " .. i .. ": " .. shield.name .. " (" .. location .. ", ID: " .. shield.item.ID() .. ")")
        end
        return shields[1]
    end
    
    -- Fallback using FindItem if no shields found
    debug_log("No shields found via scan, trying FindItem fallback")
    local shield = mq.TLO.FindItem("=Shield")
    if shield() then
        local slot = shield.ItemSlot()
        local bag_slot = shield.ItemSlot2()
        local location = (bag_slot >= 0) and ("bag slot " .. (bag_slot + 1) .. " of inventory slot " .. (slot + 1)) or ("inventory slot " .. (slot + 1))
        log("Found shield via FindItem: " .. shield.Name() .. " in " .. location .. " (ID: " .. shield.ID() .. ")")
        return {slot = slot, bag_slot = bag_slot, name = shield.Name(), item = shield}
    end
    
    debug_log("find_shield_in_inventory: No shields found")
    return nil
end

local function find_offhand_weapon_in_inventory()
    debug_log("find_offhand_weapon_in_inventory: Starting search")
    
    local equipped_secondary = mq.TLO.Me.Inventory(14)
    if equipped_secondary() then
        local item_type = equipped_secondary.Type()
        debug_log("Secondary slot (14) has item: " .. equipped_secondary.Name() .. " (Type: " .. item_type .. ", ID: " .. equipped_secondary.ID() .. ")")
        
        local acceptable_types = {"1HB", "1HS", "1HP", "Piercing", "Hand2Hand", "2HB", "2HS", "2HP", "1H Blunt", "1H Slash", "1H Pierce"}
        
        for _, acceptable in ipairs(acceptable_types) do
            if item_type == acceptable then
                log("Weapon already equipped: " .. equipped_secondary.Name() .. " (slot 14, type: " .. item_type .. ")")
                return {slot = 14, name = equipped_secondary.Name(), item = equipped_secondary, equipped = true}
            end
        end
    else
        debug_log("Secondary slot (14) is empty")
    end
    
    local weapon_types = {"1HB", "1HS", "1HP", "Piercing", "Hand2Hand", "2HB", "2HS", "2HP", "1H Blunt", "1H Slash", "1H Pierce"}
    
    for _, weapon_type in ipairs(weapon_types) do
        debug_log("Searching for weapon type: " .. weapon_type)
        local weapons = scan_inventory_for_type(weapon_type)
        if #weapons > 0 then
            log("Found " .. #weapons .. " " .. weapon_type .. " weapon(s) in inventory")
            for i, weapon in ipairs(weapons) do
                local location = weapon.bag_slot and ("bag slot " .. weapon.bag_slot .. " of slot " .. weapon.slot) or ("slot " .. weapon.slot)
                log("  " .. weapon_type .. " " .. i .. ": " .. weapon.name .. " (" .. location .. ")")
            end
            return weapons[1]
        end
    end
    
    debug_log("find_offhand_weapon_in_inventory: No weapons found")
    return nil
end

--------------------------------------------------------
-- SHIELD/OFFHAND SWAP LOGIC (ENHANCED)
--------------------------------------------------------

-- Equip shield in secondary slot using item ID
local function equip_shield()
    debug_log("equip_shield: Starting")
    local shield = find_shield_in_inventory()
    if shield then
        if shield.equipped then
            log("AutoShield: Shield already equipped: " .. shield.name)
            return true
        else
            local item_id = shield.item.ID()
            log("AutoShield: Equipping shield: " .. shield.name .. " with ID: " .. item_id)
            mq.cmdf('/exchange %d 14', item_id)
            mq.delay(1000) -- Give time for the swap
            return true
        end
    else
        log("AutoShield: No shield found in inventory (including bags)!", "WARN")
        return false
    end
end

-- Equip first non-shield weapon in secondary slot using item ID
local function equip_offhand()
    debug_log("equip_offhand: Starting")
    local weapon = find_offhand_weapon_in_inventory()
    if weapon then
        if weapon.equipped then
            log("AutoShield: Weapon already equipped: " .. weapon.name)
            return true
        else
            local item_id = weapon.item.ID()
            log("AutoShield: Equipping offhand weapon: " .. weapon.name .. " with ID: " .. item_id)
            mq.cmdf('/exchange %d 14', item_id)
            mq.delay(1000) -- Give time for the swap
            return true
        end
    else
        log("AutoShield: No offhand weapon found in inventory (including bags)!", "WARN")
        return false
    end
end

--------------------------------------------------------
-- MAIN LOOP
--------------------------------------------------------

-- Test finding a specific shield
local test_shield = mq.TLO.FindItem("Shield of the Lightning Lord")
if test_shield() then
    log("Test: Found shield: " .. test_shield.Name() .. " (ID: " .. test_shield.ID() .. ", Type: " .. test_shield.Type() .. ")", "DEBUG")
else
    log("Test: Shield not found", "DEBUG")
end

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
