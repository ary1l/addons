-- sync.lua (v7.56-combat-only)
addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '7.56-combat-only'
addon.desc    = 'Zone-safe Engage/Follow sync'

require('common')
local imgui = require('imgui')

------------------------------------------------------------
-- Settings
------------------------------------------------------------
local enabled = true
local ui_open = { true }
local DEBUG = false

local HS_TP_THRESHOLD = 350
local HS_COOLDOWN = 62 -- Haste Samba cooldown
local STEP_TP_THRESHOLD = 100
local STEP_COOLDOWN = 6 -- Box Step / Quick Step cooldown
local LOST_TARGET_INTERVAL = 3.0
local RETRY_DELAY = 0.7

local chars = {
    {
        name = '',
        engage = true, follow = true,
        hs_enabled = false, bs_enabled = false, qs_enabled = false,
        lastTarget = 0, engaged = false, lastEngageTime = 0, currentFollowState = nil,
        partyIndex = nil, retry = nil,
        hs_lastcast = -HS_COOLDOWN, bs_lastcast = -STEP_COOLDOWN, qs_lastcast = -STEP_COOLDOWN
    },
    {
        name = '',
        engage = true, follow = true,
        hs_enabled = false, bs_enabled = false, qs_enabled = false,
        lastTarget = 0, engaged = false, lastEngageTime = 0, currentFollowState = nil,
        partyIndex = nil, retry = nil,
        hs_lastcast = -HS_COOLDOWN, bs_lastcast = -STEP_COOLDOWN, qs_lastcast = -STEP_COOLDOWN
    },
}

local mm = AshitaCore:GetMemoryManager()
local qcmd = function(cmd) AshitaCore:GetChatManager():QueueCommand(1, cmd) end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function debugLog(msg)
    if DEBUG then print(msg) end
end

-- Safe disengage: only sends /attack off if mule is actually engaged
local function disengage(c)
    -- Out-of-zone or partyIndex nil: just reset state
    if not c.partyIndex then
        c.lastTarget = 0
        c.engaged = false
        c.lastEngageTime = 0
        return
    end

    local party = mm:GetParty()
    local ent = mm:GetEntity()
    if not party or not ent then
        c.lastTarget = 0
        c.engaged = false
        c.lastEngageTime = 0
        return
    end

    local idx = party:GetMemberTargetIndex(c.partyIndex)
    if idx and idx > 0 then
        local status = ent:GetStatus(idx)
        if status == 1 then
            local cmd = string.format('/mst %s /attack off', c.name)
            qcmd(cmd)
            if queueRetry then
                pcall(function() queueRetry(c, cmd) end)
            end
            debugLog(c.name .. ' forced disengage')
        end
    end

    -- Always reset local state
    c.lastTarget = 0
    c.engaged = false
    c.lastEngageTime = 0
end

local function setFollow(c, state)
    if c.currentFollowState ~= state then
        qcmd(string.format('/mst %s /ms follow %s', c.name, state and 'on' or 'off'))
        c.currentFollowState = state
        debugLog(c.name .. ' follow ' .. (state and 'on' or 'off'))
    end
end

local function getPlayerInfo()
    if not mm then return { status = 0, target = 0 } end
    local ent = mm:GetEntity()
    local targ = mm:GetTarget()
    if not ent or not targ then return { status = 0, target = 0 } end

    local selfIdx = mm:GetParty() and mm:GetParty():GetMemberTargetIndex(0) or 0
    local status = (selfIdx and selfIdx > 0) and ent:GetStatus(selfIdx) or 0

    local ok, tIdx = pcall(function() return targ:GetTargetIndex(0) end)
    local target = (ok and tIdx and tIdx > 0) and tIdx or 0

    return { status = status, target = target }
end

local function updatePartyIndex(c)
    local party = mm:GetParty()
    if not party then return nil end
    for idx = 0, 5 do
        local member = party:GetMemberName(idx)
        if member and member:lower() == c.name:lower() then
            return idx
        end
    end
    return nil
end

local function hasBuff(buffId, partyIndex)
    if not mm or not partyIndex then return false end
    local party = mm:GetParty()
    if not party then return false end
    local success, buffs = pcall(function() return party:GetMemberBuffs(partyIndex) end)
    if not success or not buffs then return false end
    for _, b in ipairs(buffs) do
        if b == buffId then return true end
    end
    return false
end

local function queueRetry(c, cmd)
    c.retry = { cmd = cmd, time = os.clock() + RETRY_DELAY }
end

local function processRetry(c)
    if c.retry and os.clock() >= c.retry.time then
        qcmd(c.retry.cmd)
        c.retry = nil
    end
end

local function handleAction(c, ability, enabledFlag, tpThreshold, lastcastField, checkBuff)
    if enabledFlag and c.engaged then
        local party = mm:GetParty()
        if not party then return end
        local muleTP = party:GetMemberTP(c.partyIndex)
        local last = c[lastcastField] or -STEP_COOLDOWN
        local now = os.clock()
        if muleTP and muleTP >= tpThreshold and (now - last) >= (ability == "Haste Samba" and HS_COOLDOWN or STEP_COOLDOWN) then
            if ability == "Haste Samba" and checkBuff and hasBuff(370, c.partyIndex) then return end
            local cmd = string.format('/mst %s /ja "%s" <t>', c.name, ability)
            if ability == "Haste Samba" then cmd = string.format('/mst %s /ja "%s" <me>', c.name, ability) end
            qcmd(cmd)
            queueRetry(c, cmd)
            c[lastcastField] = now
            debugLog(c.name .. ' used ' .. ability .. ' (TP='..muleTP..')')
        end
    end
end

------------------------------------------------------------
-- Main Loop
------------------------------------------------------------
ashita.events.register('d3d_present', 'sync_main_loop', function()
    if not enabled then return end
    local info = getPlayerInfo()
    local playerEngaged = (info.status == 1)
    local playerTarget = info.target
    local engageCommands = {}

    for _, c in ipairs(chars) do
        c.partyIndex = updatePartyIndex(c)
        if not c.partyIndex then
            debugLog(c.name .. ' is out of zone, skipping')
            goto continue
        end

        setFollow(c, c.follow)

        -- Master disengaged -> force mule disengage
        if not playerEngaged then
            disengage(c)
        end

        -- Engage logic
        if playerEngaged and c.engage then
            local masterTargetValid = playerTarget ~= 0
            local lostTarget = c.lastTarget ~= playerTarget
            local now = os.clock()
            if (lostTarget and masterTargetValid) or not c.engaged or (now - (c.lastEngageTime or 0) >= LOST_TARGET_INTERVAL) then
                local cmd = string.format('/mst %s /attack [t]', c.name)
                table.insert(engageCommands, cmd)
                queueRetry(c, cmd)
                c.lastTarget = playerTarget
                c.engaged = true
                c.lastEngageTime = now
                debugLog(c.name .. ' engage triggered')
            end
        elseif not c.engage and c.engaged then
            disengage(c)
        end

        -- Only cast abilities if in combat (TP > 0)
        local party = mm:GetParty()
        local muleTP = party and party:GetMemberTP(c.partyIndex) or 0
        local inCombat = muleTP > 0
        if inCombat then
            handleAction(c, "Haste Samba", c.hs_enabled, HS_TP_THRESHOLD, "hs_lastcast", true)
            handleAction(c, "Box Step",   c.bs_enabled, STEP_TP_THRESHOLD, "bs_lastcast", false)
            handleAction(c, "Quick Step", c.qs_enabled, STEP_TP_THRESHOLD, "qs_lastcast", false)
        end

        processRetry(c)
        ::continue::
    end

    for _, cmd in ipairs(engageCommands) do
        qcmd(cmd)
    end

    -- UI
    if ui_open[1] and imgui.Begin('Sync##sync', ui_open, ImGuiWindowFlags_AlwaysAutoResize) then
        for i, c in ipairs(chars) do
            imgui.PushID(i)
            imgui.Text(c.name); imgui.SameLine()

            local cb_follow = { c.follow }
            if imgui.Checkbox('F##'..i, cb_follow) then
                c.follow = cb_follow[1]
                setFollow(c, c.follow)
            end
            imgui.SameLine()

            local cb_engage = { c.engage }
            if imgui.Checkbox('E##'..i, cb_engage) then
                c.engage = cb_engage[1]
                disengage(c)
            end
            imgui.SameLine()

            local cb_hs = { c.hs_enabled }
            if imgui.Checkbox('HS##'..i, cb_hs) then
                c.hs_enabled = cb_hs[1]
            end
            imgui.SameLine()

            local cb_bs = { c.bs_enabled }
            if imgui.Checkbox('BS##'..i, cb_bs) then
                c.bs_enabled = cb_bs[1]
            end
            imgui.SameLine()

            local cb_qs = { c.qs_enabled }
            if imgui.Checkbox('QS##'..i, cb_qs) then
                c.qs_enabled = cb_qs[1]
            end

            imgui.PopID()
        end
        imgui.End()
    end
end)

------------------------------------------------------------
-- Commands
------------------------------------------------------------
ashita.events.register('command', 'command_cb', function(e)
    local args = e.command:args()
    if #args > 0 and args[1]:lower() == '/sync' then
        e.blocked = true
        if #args == 1 then ui_open[1] = not ui_open[1] end
    end
end)

------------------------------------------------------------
-- On Load: Auto-followme
------------------------------------------------------------
ashita.events.register('load', 'sync_load', function()
    qcmd('/ms followme on')

end)

