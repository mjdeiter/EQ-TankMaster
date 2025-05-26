# TankMaster.lua v1.6

**Description:**  
This Lua script is designed for tanking in EverQuest, providing automated aggro management, shield swapping, and a group rescue feature to protect group members under attack.

---

## Usage

- **Load the Script**:  
  In-game, type `/lua run TankMaster` to start the script.

- **Toggle Group Rescue**:  
  Use `/tankrescue on` to enable or `/tankrescue off` to disable the group rescue feature.

- **Debug Mode**:  
  Set `DEBUG_MODE = true` in the script to enable verbose logging, including rescue attempt messages. Set to `false` to disable.

---

## Changelog

- **v1.6**: Added optional messages for group rescue attempts, controlled by `DEBUG_MODE`.
- **v1.5**: Improved group rescue with a health threshold (50%) and target checking, reduced main loop delay to 1 second.
- **v1.4**: Added modular group rescue feature to switch targets if a mob attacks another group member.
- **v1.3**: Fixed inventory scanning to use 0-based indexing for bag slots.
- **v1.2**: Added continuous loop and improved logging.
- **v1.1**: Initial release with basic aggro and shield-swap functionality.

---

## Script Code

```lua
--[[
TankMaster.lua v1.6 (2025-05-26)
Combined Aggro and Shield-Swap logic for EverQuest tanks with improved group rescue feature and optional rescue messages.
Credit: Alektra <Lederhosen> | mjdeiter/EQ-TankMaster | MacroQuest/E3 Compatible
Usage: Place in your Lua scripts folder and load via /lua run TankMaster

Changelog:
- v1.6: Added optional messages for group rescue attempts, controlled by DEBUG_MODE
- v1.5: Improved group rescue with health threshold (50%) and target checking, reduced main loop delay to 1 second
- v1.4: Added modular group rescue feature to switch targets if a mob attacks another group member
- v1.3: Fixed inventory scanning to use 0-based indexing for bag slots
- v1.2: Added continuous loop and improved logging
- v1.1: Initial release with basic aggro and shield-swap functionality
--]]

local mq = require('mq')

-- Version banner
local SCRIPT_VERSION = "v1.6"
local SCRIPT_DATE = "2025-05-26"
mq.cmd(string.format('/echo \\agCredit: \\acAlektra <Lederhosen>\\ax | \\ayTankMaster.lua %s (%s)\\ax', SCRIPT_VERSION, SCRIPT_DATE))

--------------------------------------------------------
-- CONFIGURATION SECTION
--------------------------------------------------------

-- DEBUG MODE: Set to true for verbose logging, including rescue messages
local DEBUG_MODE = true

-- Group Rescue Configuration (Modular Feature)
local enable_group_rescue = true         -- Toggle to enable/disable group rescue
local group_rescue_cooldown = 5          -- Cooldown in seconds to prevent spamming
local rescue_health_threshold = 50       -- Health percentage below which rescue triggers
local last_group_rescue = 0              -- Tracks last use to enforce cooldown

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
    if DEBUG_MODE then log(message, "DEBUG") end
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
    return type(pct) == "number" and pct or 0
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
    return ok and ready or false
end

local function use_ability(name)
    if can_use_ability(name) then
        log("Using ability: " .. name)
        mq.cmdf('/doability "%s"', name)
    end
end

local function can_use_item(name)
    local ok, ready = pcall(function() return mq.TLO.FindItem(name)() and mq.TLO.Me.ItemReady(name)() end)
    return ok and ready or false
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
    return type(hp) == "number" and hp or 100
end

local function check_defensive_triggers()
    local hp = safe_pct_hps()
    for _, trigger in ipairs(DEFENSIVES) do
        if hp <= trigger.threshold then
            pcall(trigger.action)
        end
    end
end

--------------------------------------------------------
-- MODULAR GROUP RESCUE FEATURE
--------------------------------------------------------

-- Check if a group member is being attacked and low on health, then switch targets
local function check_group_aggro()
    if not enable_group_rescue then return false end
    local now = os.time()
    if now - last_group_rescue < group_rescue_cooldown then return false end
    
    for i = 1, mq.TLO.Group.Members() do
        local member = mq.TLO.Group.Member(i)
        if member() and member.ID() ~= mq.TLO.Me.ID() and member.PctHPs() < rescue_health_threshold then
            local tot = member.TargetOfTarget()
            if tot and tot.Type() == "NPC" then
                local mob_id = tot.ID()
                local mob_name = tot.Name() or "Unknown Mob"
                local member_name = member.Name()
                if mq.TLO.Target.ID() == mob_id then
                    debug_log("Attempting to rescue " .. member_name .. " from " .. mob_name .. " (already targeted)")
                    use_ability(ABILITIES.taunt)
                else
                    debug_log("Attempting to rescue " .. member_name .. " from " .. mob_name .. " (switching target)")
                    mq.cmdf('/target id %d', mob_id)
                    mq.delay(500) -- Wait for target switch
                    use_ability(ABILITIES.taunt)
                end
                last_group_rescue = now
                return true
            end
        end
    end
    return false
end

-- Toggle group rescue feature on/off
local function toggle_group_rescue(arg)
    if arg == "on" then
        enable_group_rescue = true
        log("Group rescue enabled")
    elseif arg == "off" then
        enable_group_rescue = false
        log("Group rescue disabled")
    else
        log("Usage: /tankrescue on|off")
    end
end

-- Bind the toggle command
mq.bind('/tankrescue', function(arg) toggle_group_rescue(arg) end)

--------------------------------------------------------
-- INVENTORY MANAGEMENT (SIMPLIFIED FOR BREVITY)
--------------------------------------------------------

local function equip_shield()
    local shield = mq.TLO.FindItem("=Shield")
    if shield() and not has_shield() then
        log("Equipping shield: " .. shield.Name())
        mq.cmdf('/exchange %d 14', shield.ID())
        mq.delay(1000)
        return true
    end
    return has_shield()
end

local function equip_offhand()
    local weapon = mq.TLO.FindItem("=1HS") or mq.TLO.FindItem("=1HB")
    if weapon() and not has_offhand() then
        log("Equipping offhand: " .. weapon.Name())
        mq.cmdf('/exchange %d 14', weapon.ID())
        mq.delay(1000)
        return true
    end
    return has_offhand()
end

--------------------------------------------------------
-- MAIN LOOP
--------------------------------------------------------

while true do
    pcall(function()
        if is_in_combat() and mq.TLO.Group.Members() > 1 and mq.TLO.Target.ID() then
            -- Check group rescue first (modular feature)
            if enable_group_rescue then
                check_group_aggro()
            end

            -- Existing aggro and swap logic
            use_ability(ABILITIES.taunt)
            for _, ae in ipairs(ABILITIES.ae_taunts) do use_ability(ae) end

            if can_use_ability(ABILITIES.bash) then
                local now = os.time()
                if now - last_bash_request > BASH_REQUEST_COOLDOWN then
                    if not has_shield() then
                        equip_shield()
                    else
                        use_ability(ABILITIES.bash)
                        equip_offhand()
                    end
                    last_bash_request = now
                end
            end

            if is_tanking() then
                if has_shield() then
                    use_ability(ABILITIES.knee_strike)
                    use_ability(ABILITIES.throat_jab)
                end
            else
                if has_offhand() then use_ability(ABILITIES.battle_leap) end
                use_ability(ABILITIES.kick)
            end

            if super_close() then use_ability(ABILITIES.battle_leap) end

            for _, clicky in ipairs(CLICKIES) do
                if clicky.condition() then use_item(clicky.name) end
            end

            check_defensive_triggers()
        end
    end)
    mq.delay(1000) -- Reduced to 1 second for faster response
end
```

---

## Known Issues

- The script may not always detect items inside certain containers due to server-specific inventory handling.
- Group rescue might not trigger in time if a group member is killed too quickly (e.g., in under 1 second).

---

## Future Improvements

- Add support for area-of-effect (AoE) taunts to handle multiple mobs more effectively.
- Implement a priority system for group rescue based on roles (e.g., prioritize healers).
- Optimize performance for larger groups or high-mob-count encounters.

---

## Configuration Options

- **`DEBUG_MODE`**: Set to `true` to enable verbose logging, including rescue attempt messages. Set to `false` to disable.
- **`enable_group_rescue`**: Set to `true` to enable the group rescue feature. Set to `false` to disable.
- **`group_rescue_cooldown`**: Cooldown in seconds between group rescue attempts (default: 5).
- **`rescue_health_threshold`**: Health percentage below which the group rescue feature triggers (default: 50).
- **`BASH_REQUEST_COOLDOWN`**: Cooldown in seconds between Bash ability usage attempts (default: 4).

---

## Updating the Script

To update the script to a newer version:
1. Stop the current script if it's running: `/lua stop TankMaster`
2. Replace the existing `TankMaster.lua` file in your Lua scripts folder with the updated version.
3. Reload the script: `/lua run TankMaster`

---
