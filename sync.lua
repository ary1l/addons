-- sync
addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '0.1'
addon.desc    = 'Alliance-safe Engage/Follow sync'

require('common')
local imgui = require('imgui')

------------------------------------------------------------
-- Settings
------------------------------------------------------------
local enabled = true
local ui_open = { true }
local DEBUG = false

local HS_TP_THRESHOLD   = 350
local HS_COOLDOWN       = 62
local STEP_TP_THRESHOLD = 100
local STEP_COOLDOWN     = 6
local LOST_TARGET_INTERVAL = 3.0
local RETRY_DELAY          = 0.7
local TICK_INTERVAL        = 0.3   
local lastTick = 0

local chars = {
    { name='muunch', engage=false, follow=false, hs_enabled=false, bs_enabled=false, qs_enabled=false, lastTarget=0, engaged=false, lastEngageTime=0, currentFollowState=nil, partyIndex=nil, retry=nil, hs_lastcast=-HS_COOLDOWN, bs_lastcast=-STEP_COOLDOWN, qs_lastcast=-STEP_COOLDOWN },
    { name='slowpoke', engage=false, follow=false, hs_enabled=false, bs_enabled=false, qs_enabled=false, lastTarget=0, engaged=false, lastEngageTime=0, currentFollowState=nil, partyIndex=nil, retry=nil, hs_lastcast=-HS_COOLDOWN, bs_lastcast=-STEP_COOLDOWN, qs_lastcast=-STEP_COOLDOWN },
    { name='goomy', engage=false, follow=false, hs_enabled=false, bs_enabled=false, qs_enabled=false, lastTarget=0, engaged=false, lastEngageTime=0, currentFollowState=nil, partyIndex=nil, retry=nil, hs_lastcast=-HS_COOLDOWN, bs_lastcast=-STEP_COOLDOWN, qs_lastcast=-STEP_COOLDOWN },
}

local uiState = {}
for _, c in ipairs(chars) do
    uiState[c.name] = { follow=c.follow, engage=c.engage, hs=c.hs_enabled, bs=c.bs_enabled, qs=c.qs_enabled }
end
local uiInitialized = false

local mm = AshitaCore:GetMemoryManager()
local qcmd = function(cmd) AshitaCore:GetChatManager():QueueCommand(1, cmd) end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function debugLog(msg) if DEBUG then print(msg) end end

local function setFollow(c, state)
    if c.currentFollowState ~= state then
        qcmd(string.format('/mst %s /ms follow %s', c.name, state and 'on' or 'off'))
        c.currentFollowState = state
        debugLog(c.name .. ' follow ' .. (state and 'on' or 'off'))
    end
end

local function disengage(c, party, ent)
    if not c.partyIndex or not party or not ent then return end
    local idx = party:GetMemberTargetIndex(c.partyIndex)
    if idx and idx > 0 and ent:GetStatus(idx) == 1 then
        qcmd(string.format('/mst %s /attack off', c.name))
        debugLog(c.name .. ' disengaged')
    end
    c.lastTarget = 0; c.engaged = false; c.lastEngageTime = 0
end

local function updatePartyIndex(c, party)
    if not party then return nil end
    for idx=0,17 do
        local member = party:GetMemberName(idx)
        if member and member:lower() == c.name:lower() then return idx end
    end
    return nil
end

local function getPlayerInfo(party, ent, targ)
    if not ent or not targ then return {status=0, target=0} end
    local selfIdx = party and party:GetMemberTargetIndex(0) or 0
    local status  = (selfIdx > 0) and ent:GetStatus(selfIdx) or 0
    local ok, tIdx = pcall(function() return targ:GetTargetIndex(0) end)
    local target = (ok and tIdx and tIdx > 0) and tIdx or 0
    return {status=status, target=target}
end

local function hasBuff(buffId, party, partyIndex)
    if not party or not partyIndex then return false end
    local success, buffs = pcall(function() return party:GetMemberBuffs(partyIndex) end)
    if not success or not buffs then return false end
    for _, b in ipairs(buffs) do if b==buffId then return true end end
    return false
end

local function queueRetry(c, cmd, now) c.retry = { cmd=cmd, time=now+RETRY_DELAY } end
local function processRetry(c, now) if c.retry and now>=c.retry.time then qcmd(c.retry.cmd); c.retry=nil end end

local function handleAction(c, ability, enabled, tpThreshold, lastcastField, checkBuff, party, now, playerZone)
    if not enabled or not c.engaged or not c.partyIndex or not party then return end
    if party:GetMemberZone(c.partyIndex) ~= playerZone then return end
    local ok, tp = pcall(function() return party:GetMemberTP(c.partyIndex) end)
    local muleTP = (ok and tp) or 0
    local last = c[lastcastField] or -STEP_COOLDOWN
    if muleTP >= tpThreshold and (now-last) >= (ability=="Haste Samba" and HS_COOLDOWN or STEP_COOLDOWN) then
        if ability=="Haste Samba" and checkBuff and hasBuff(370, party, c.partyIndex) then return end
        local cmd = string.format('/mst %s /ja "%s" %s', c.name, ability, ability=="Haste Samba" and '<me>' or '<t>')
        qcmd(cmd)
        queueRetry(c, cmd, now)
        c[lastcastField] = now
        debugLog(c.name..' used '..ability..' (TP='..muleTP..')')
    end
end

------------------------------------------------------------
-- Main Loop
------------------------------------------------------------
ashita.events.register('d3d_present', 'sync_main_loop', function()
    local now = os.clock()
    if now - lastTick < TICK_INTERVAL then return end
    lastTick = now

    local party = mm:GetParty()
    local ent   = mm:GetEntity()
    local targ  = mm:GetTarget()
    local playerInfo = getPlayerInfo(party, ent, targ)
    local playerEngaged = (playerInfo.status==1)
    local playerTarget  = playerInfo.target
    local playerZone = party and party:GetMemberZone(0) or nil
    local leaderHP = 100
    if party and ent then
        local selfIdx = party:GetMemberTargetIndex(0)
        if selfIdx and selfIdx>0 then leaderHP = ent:GetHPPercent(selfIdx) end
    end

    for _, c in ipairs(chars) do
        c.partyIndex = updatePartyIndex(c, party)
        if c.partyIndex then
            local muleZone = party:GetMemberZone(c.partyIndex)
            setFollow(c, c.follow)
            if muleZone == playerZone then
                if not playerEngaged and leaderHP>0 then disengage(c, party, ent)
                elseif playerEngaged and c.engage then
                    if c.lastTarget~=playerTarget or not c.engaged then
                        qcmd(string.format('/mst %s /attack [t]', c.name))
                        c.lastTarget = playerTarget; c.engaged=true; c.lastEngageTime=now
                        debugLog(c.name..' engaged')
                    end
                elseif not c.engage and c.engaged then
                    disengage(c, party, ent)
                end
                handleAction(c,"Haste Samba",c.hs_enabled,HS_TP_THRESHOLD,"hs_lastcast",true,party,now,playerZone)
                handleAction(c,"Box Step",c.bs_enabled,STEP_TP_THRESHOLD,"bs_lastcast",false,party,now,playerZone)
                handleAction(c,"Quick Step",c.qs_enabled,STEP_TP_THRESHOLD,"qs_lastcast",false,party,now,playerZone)
            end
            processRetry(c, now)
        end
    end
end)

------------------------------------------------------------
-- UI (flicker-free)
------------------------------------------------------------
ashita.events.register('d3d_present', 'sync_ui_render', function()
    if not ui_open[1] then return end
    if imgui.Begin('Sync##sync', ui_open, ImGuiWindowFlags_AlwaysAutoResize) then
        if not uiInitialized then
            pcall(function() imgui.SetWindowPos(50,50); imgui.SetWindowSize(300,200) end)
            uiInitialized=true
        end
        for i,c in ipairs(chars) do
            imgui.PushID(i)
            imgui.Text(c.name); imgui.SameLine()
            local cb=uiState[c.name]

            local tmp={cb.follow}
            if imgui.Checkbox('F##'..i,tmp) then cb.follow=tmp[1]; c.follow=cb.follow; setFollow(c,c.follow) end

            imgui.SameLine()
            tmp={cb.engage}
            if imgui.Checkbox('E##'..i,tmp) then
                local wasEngaged=c.engage
                cb.engage=tmp[1]; c.engage=cb.engage
                if not c.engage and wasEngaged then disengage(c, mm:GetParty(), mm:GetEntity()) end
            end

            imgui.SameLine()
            tmp={cb.hs}
            if imgui.Checkbox('HS##'..i,tmp) then cb.hs=tmp[1]; c.hs_enabled=cb.hs end

            imgui.SameLine()
            tmp={cb.bs}
            if imgui.Checkbox('BS##'..i,tmp) then cb.bs=tmp[1]; c.bs_enabled=cb.bs end

            imgui.SameLine()
            tmp={cb.qs}
            if imgui.Checkbox('QS##'..i,tmp) then cb.qs=tmp[1]; c.qs_enabled=cb.qs end

            imgui.PopID()
        end
        imgui.End()
    end
end)

------------------------------------------------------------
-- Commands
------------------------------------------------------------
ashita.events.register('command', 'command_cb', function(e)
    local args=e.command:args()
    if #args>0 and args[1]:lower()=='/sync' then
        e.blocked=true
        if #args==1 then ui_open[1]=not ui_open[1] end
    end
end)

------------------------------------------------------------
-- On Load: Auto-followme
------------------------------------------------------------
ashita.events.register('load','sync_load',function()
    qcmd('/ms followme on')
end)

