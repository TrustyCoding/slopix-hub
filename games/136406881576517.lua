local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local Library = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/TrustyCoding/slopix-hub/main/ui/Library.lua"
))()
local Options = Library.Options
local Toggles = Library.Toggles

local Signals = ReplicatedStorage.Communication.ServerAndClient.Signals
local SignalFunction = require(Signals.SignalFunction)
local SignalEvent = require(Signals.SignalEvent)
local Clans = require(ReplicatedStorage.CAM.Clans)
local Utility = require(ReplicatedStorage.CAM.Global.Utility)
local SpinBalance = require(ReplicatedStorage.CAM.Global.SpinBalance)
local Items = require(ReplicatedStorage.CAM.Global.Collectibles.Items)
local Regions = require(ReplicatedStorage.Regions)
local Quests = require(ReplicatedStorage.CAM.Global.Subsets.Gameplay.Quests)
local Breathings = require(ReplicatedStorage.CAM.Global.Powers.Breathings)
local ItemRequirements = require(ReplicatedStorage.CAM.Global.Collectibles.ItemRequirements)
local gameSettings = require(ReplicatedStorage.CAM.Global.gameSettings)
local Shop = require(ReplicatedStorage.CAM.Global.Shop)
local Rarities = require(ReplicatedStorage.CAM.Global.Rarities)
local TimedVendor = require(ReplicatedStorage.CAM.Global.Subsets.Gameplay.TimedVendor)
local RotatingShop = require(ReplicatedStorage.CAM.Global.Subsets.Gameplay.RotatingShop)
local TimedEvents = require(ReplicatedStorage.CAM.Global.Subsets.Gameplay.TimedEvents)

local PENDING_ATTRIBUTE = "PendingClanSpin"
local FINALIZE_TIMEOUT = 3
local REDEEM_INTERVAL = 0.75
local IDLE_INTERVAL = 0.2
local DEFAULT_TARGET_RARITY = 6

local TOOLBAR_SLOTS = { "One", "Two", "Three", "Four", "Five" }
local POSITION_MODES = { "Behind", "Above", "Below" }
local SEARCH_INTERVAL = 0.4
local PUNCH_RETRY = 0.15
local TRAVEL_SETTLE = 2.5
local TRAVEL_HEIGHT = 8
local MAX_BEHIND_OFFSET = 6
local EQUIP_SETTLE = 0.5

local BOSS_TIMER_ROWS = 10
local QUEST_TASK_ROWS = 8
local TIMER_TICK = 1
local QUEST_ACCEPT_COOLDOWN = 31
local GIVER_OFFSET = Vector3.new(0, 3, 4)
local GIVER_SETTLE = 2.5
local GIVER_ACCEPT_WAIT = 2.5

local POTION_DRINK_TIME = 2.1
local HEAL_RETREAT_HEIGHT = 30
local HEAL_CHECK_INTERVAL = 0.25

local RegionRoot = workspace:WaitForChild("Humanoids"):WaitForChild("Regions")
local BossHunts = ReplicatedStorage:WaitForChild("BossHunts")
local ChestFolder = workspace:WaitForChild("Chests")
local CollectionService = game:GetService("CollectionService")
local VirtualUser = game:GetService("VirtualUser")

-- live-reload hands the script STATE as a local (Real's notes-getgenv-identity), so read it directly.
local RuntimeState = STATE
local alive = true

local state = {
    build = "slopix",
    running = false,
    spins = 0,
    farming = false,
    kills = 0,
    deaths = 0,
    target = nil,
}

local RARITY_BY_NAME = {}
local RARITY_NAMES = {}
for _, tier in ipairs(Clans.Rarities) do
    RARITY_BY_NAME[tier.name] = tier.rarity
    RARITY_NAMES[#RARITY_NAMES + 1] = tier.name
end

local setIdentity = setthreadidentity or set_thread_identity or setidentity or setthreadcontext

local function elevate()
    if setIdentity then
        pcall(setIdentity, 8)
    end
end

local function notify(title, description, time)
    elevate()
    Library:Notify({ Title = title, Description = description, Time = time })
end

local function getSlot()
    return Utility.GetData(LocalPlayer, true)
end

local function getClanName()
    local slot = getSlot()
    local clan = slot and slot:FindFirstChild("Clan")
    return clan and clan.Value or "None"
end

local function rarityOf(clanName)
    local data = clanName and Clans.GetClan(clanName)
    return data and data.rarity or 0
end

local function tierNameOf(clanName)
    local tier = Clans.TierOf(clanName)
    return tier and tier.name or "?"
end

local function getSpinCount()
    local slot = getSlot()
    if not slot then
        return 0
    end
    local ok, total = pcall(SpinBalance.Total, slot, true)
    return ok and total or 0
end

local function finalizePending(timeout)
    if LocalPlayer:GetAttribute(PENDING_ATTRIBUTE) == nil then
        return true
    end

    SignalEvent.ToServer("ClanSpinComplete")

    local started = os.clock()
    while alive and LocalPlayer:GetAttribute(PENDING_ATTRIBUTE) ~= nil do
        if os.clock() - started > (timeout or FINALIZE_TIMEOUT) then
            return false
        end
        task.wait(0.05)
    end
    return true
end

local function spinOnce()
    if not finalizePending(FINALIZE_TIMEOUT) then
        return false, "pending"
    end

    local ok, rolled = pcall(SignalFunction.ToServer, "ClanSpin")
    if not ok or type(rolled) ~= "string" then
        return false, "rejected"
    end

    state.spins += 1
    finalizePending(FINALIZE_TIMEOUT)
    return true, rolled, rarityOf(rolled)
end

local function redeemKnownCodes()
    local ok, status = pcall(SignalFunction.ToServer, "CodeStatus")
    if not ok or type(status) ~= "table" or type(status.codes) ~= "table" then
        notify("Codes", "Could not load the code list", 4)
        return
    end

    local redeemed, failed = 0, 0
    for code, info in pairs(status.codes) do
        if not info.redeemed then
            local sent, result = pcall(SignalFunction.ToServer, "RedeemCode", code)
            if sent and result then
                redeemed += 1
            else
                failed += 1
            end
            task.wait(REDEEM_INTERVAL)
        end
    end

    notify("Codes", string.format("Redeemed %d new code(s); %d unavailable", redeemed, failed), 5)
end

local punchFn = nil

local function getPunch()
    if punchFn then
        return punchFn
    end
    local scripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local cu = scripts and scripts:FindFirstChild("CU")
    local combatScript = cu and cu:FindFirstChild("Combat")
    if not combatScript then
        return nil
    end
    local ok, env = pcall(getsenv, combatScript)
    if ok and type(env) == "table" and type(env.punch) == "function" then
        punchFn = env.punch
    end
    return punchFn
end

local function getRoot()
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart"), char
end

local function hotbarItems(predicate)
    local slot = getSlot()
    local inventory = slot and slot:FindFirstChild("Inventory")
    local owned = inventory and inventory:FindFirstChild("Inventory")
    local toolbar = inventory and inventory:FindFirstChild("Toolbar")
    if not owned or not toolbar then
        return {}, {}
    end

    local nameById = {}
    for _, folder in ipairs(owned:GetChildren()) do
        local id = folder:FindFirstChild("Id")
        if id then
            nameById[id.Value] = folder.Name
        end
    end

    local names, slotByName = {}, {}
    for index, slotName in ipairs(TOOLBAR_SLOTS) do
        local entry = toolbar:FindFirstChild(slotName)
        local itemName = entry and nameById[entry.Value]
        local def = itemName and Items[itemName]
        if type(def) == "table" and predicate(itemName, def) then
            names[#names + 1] = itemName
            slotByName[itemName] = index
        end
    end
    return names, slotByName
end

local function toolbarWeapons()
    return hotbarItems(function(_, def)
        return def.HasCombat or def.CombatPreset
    end)
end

local function hotbarPotions()
    return hotbarItems(function(name, def)
        return def.Category == "Potions" and string.find(name, "Health", 1, true) ~= nil
    end)
end

local function itemCount(name)
    local slot = getSlot()
    local inventory = slot and slot:FindFirstChild("Inventory")
    local owned = inventory and inventory:FindFirstChild("Inventory")
    local item = owned and owned:FindFirstChild(name)
    if not item then
        return 0
    end
    local amount = item:FindFirstChild("Amount")
    return amount and amount.Value or 1
end

local weaponSlot = nil

-- quiet: the farm retries a failed equip before saying anything (a stun or respawn can refuse one).
local function equipWeapon(name, quiet)
    if not name or name == "" then
        return false
    end

    local _, slotByName = toolbarWeapons()
    local index = slotByName[name]
    weaponSlot = index
    if not index then
        if not quiet then
            notify("Auto Farm", string.format("%s is not on your hotbar - add it, then press Refresh", name), 6)
        end
        return false
    end

    local config = LocalPlayer:FindFirstChild("Items_Config")
    local equipped = config and config:FindFirstChild("Equipped")
    if not equipped then
        if not quiet then
            notify("Auto Farm", "Items_Config is not ready yet", 4)
        end
        return false
    end
    if equipped.Value == index then
        return true
    end

    if equipped.Value ~= 0 then
        equipped.Value = 0
        task.wait(EQUIP_SETTLE)
    end
    equipped.Value = index
    task.wait(EQUIP_SETTLE)

    if equipped.Value ~= index then
        if not quiet then
            notify("Auto Farm", string.format("The game refused to equip %s - pick another weapon", name), 6)
        end
        return false
    end
    return true
end

local function weaponReady(quiet)
    local config = LocalPlayer:FindFirstChild("Items_Config")
    local equipped = config and config:FindFirstChild("Equipped")
    if equipped and weaponSlot and equipped.Value == weaponSlot then
        return true
    end
    return equipWeapon(Options.FarmWeapon.Value, quiet)
end

local function mobNames()
    local seen, names = {}, {}
    for _, region in ipairs(RegionRoot:GetChildren()) do
        local active = region:FindFirstChild("ActiveNpcs")
        if active then
            for _, folder in ipairs(active:GetChildren()) do
                if not seen[folder.Name] then
                    seen[folder.Name] = true
                    names[#names + 1] = folder.Name
                end
            end
        end
    end
    table.sort(names)
    return names
end

local function selectedValues(option)
    local value = option and option.Value
    local wanted, count = {}, 0
    if type(value) == "table" then
        for name, picked in pairs(value) do
            if picked then
                wanted[name] = true
                count += 1
            end
        end
    elseif type(value) == "string" and value ~= "" then
        wanted[value] = true
        count = 1
    end
    return wanted, count
end

local function activeBossHunts()
    local hunts = {}
    for _, config in ipairs(BossHunts:GetChildren()) do
        local name = config:GetAttribute("Boss")
        local expires = config:GetAttribute("ExpiresAt")
        if name and expires then
            hunts[#hunts + 1] = {
                name = name,
                expires = expires,
                tier = config:GetAttribute("Tier") or "?",
                side = config:GetAttribute("Side") or "?",
            }
        end
    end
    table.sort(hunts, function(a, b)
        return a.expires < b.expires
    end)
    return hunts
end

local function bossNames()
    local seen, names = {}, {}
    for _, hunt in ipairs(activeBossHunts()) do
        if not seen[hunt.name] then
            seen[hunt.name] = true
            names[#names + 1] = hunt.name
        end
    end
    return names
end

local function playerLevel()
    local slot = getSlot()
    local goal = slot and slot:FindFirstChild("Exp") and slot.Exp:FindFirstChild("Goal")
    if not goal or not gameSettings.expPerLevel or gameSettings.expPerLevel == 0 then
        return 0
    end
    return math.floor(goal.Value / gameSettings.expPerLevel)
end

local function normalizeName(text)
    return (tostring(text):lower():gsub("[^%a%d]", ""))
end

local function npcNameForCode(code)
    if not code then
        return nil
    end
    local wanted = normalizeName(code)
    for _, region in ipairs(RegionRoot:GetChildren()) do
        local active = region:FindFirstChild("ActiveNpcs")
        if active then
            for _, folder in ipairs(active:GetChildren()) do
                if normalizeName(folder.Name) == wanted then
                    return folder.Name
                end
            end
        end
    end
    return nil
end

-- Side quests are everything the combat farm cannot finish by fighting (Dialogue, Fishing, ...).
-- The game allows one active quest per category, so a combat and a side quest can run together.
local function isSideQuest(definition)
    local category = definition and definition.Category or "Combat"
    return category ~= "Combat" and category ~= "BossHunt"
end

-- kind: "combat" or "side" to filter by category, nil for every active quest.
local function activeQuests(kind)
    local slot = getSlot()
    local questFolder = slot and slot:FindFirstChild("Quests")
    local holder = questFolder and questFolder:FindFirstChild("Holder")
    if not holder then
        return {}
    end

    local list = {}
    for _, folder in ipairs(holder:GetChildren()) do
        local questString = folder:FindFirstChild("QuestString")
        local taskFolder = folder:FindFirstChild("Tasks")
        local key = questString and questString.Value or folder.Name
        local side = isSideQuest(Quests.Holder[key])
        if kind == nil or (kind == "side") == side then
            local tasks = {}
            for _, task in ipairs(taskFolder and taskFolder:GetChildren() or {}) do
                local value = task:FindFirstChild("Value")
                local max = task:FindFirstChild("Max")
                local code = task:FindFirstChild("Code")
                tasks[#tasks + 1] = {
                    name = task.Name,
                    value = value and value.Value or 0,
                    max = max and max.Value or 1,
                    code = code and code.Value or nil,
                }
            end
            list[#list + 1] = {
                instance = folder.Name,
                key = key,
                folder = folder,
                tasks = tasks,
            }
        end
    end
    return list
end

local function questTargets()
    local wanted, count, blocked = {}, 0, {}
    for _, quest in ipairs(activeQuests("combat")) do
        for _, task in ipairs(quest.tasks) do
            if task.value < task.max then
                local npcName = npcNameForCode(task.code)
                if npcName then
                    if not wanted[npcName] then
                        wanted[npcName] = true
                        count += 1
                    end
                else
                    blocked[#blocked + 1] = task.name
                end
            end
        end
    end
    return wanted, count, blocked
end

local function resolveValue(container, path)
    local current = container
    for part in string.gmatch(path, "[^%.]+") do
        if not current then
            return nil
        end
        current = current:FindFirstChild(part)
    end
    return current
end

-- Returns false plus a short reason ("needs Lv 105", "Slayer/Hybrid only") when a rule fails.
local function requirementsPass(requirements)
    if requirements == nil then
        return true
    end
    local slot = getSlot()
    if not slot then
        return false, "data not loaded"
    end
    local perLevel = gameSettings.expPerLevel or 60

    for key, needed in pairs(requirements) do
        if key == "Level" and type(needed) == "number" then
            local goal = resolveValue(slot, "Exp.Goal")
            if not goal or goal.Value / perLevel < needed then
                return false, string.format("needs Lv %d", needed)
            end
        elseif key == "MaxLevel" and type(needed) == "number" then
            local goal = resolveValue(slot, "Exp.Goal")
            if not goal or needed < goal.Value / perLevel then
                return false, string.format("up to Lv %d only", needed)
            end
        elseif key == "Items" then
            local inventory = slot:FindFirstChild("Inventory")
            inventory = inventory and inventory:FindFirstChild("Inventory")
            local list = type(needed) == "table" and needed or { needed }
            local found = false
            for _, name in ipairs(list) do
                if inventory and type(name) == "string" and inventory:FindFirstChild(name) then
                    found = true
                    break
                end
            end
            if not found then
                return false, "needs " .. table.concat(list, " or ")
            end
        else
            local holder = resolveValue(slot, key)
            local value = holder and holder.Value or nil
            if type(needed) == "table" then
                if table.find(needed, value) == nil then
                    return false, key == "Race" and (table.concat(needed, "/") .. " only")
                        or string.format("needs %s %s", key, table.concat(needed, "/"))
                end
            elseif value ~= needed then
                return false, key == "Race" and (tostring(needed) .. " only")
                    or string.format("needs %s %s", key, tostring(needed))
            end
        end
    end
    return true
end

local function questEligible(key)
    local definition = Quests.Holder[key]
    if not definition then
        return false, "unknown quest"
    end
    local questState = Quests.GetPlayerQuestState(LocalPlayer, key)
    if questState == "Doing" then
        return false, "active"
    elseif questState ~= "None" then
        return false, "completed"
    end
    return requirementsPass(definition.Requirements)
end

-- One label map for both dropdowns; the lock map holds the reason for rows you cannot take.
local questKeyByLabel = {}
local questLockByLabel = {}
local questsTaken = 0
local BEST_QUEST_LABEL = "* Best for my level"

local function questExp(definition)
    return (definition.Rewards and definition.Rewards.Exp) or 0
end

local function questPowerName(definition)
    local power = definition.Rewards and definition.Rewards.Power
    if type(power) == "string" then
        return power
    end
    if type(power) == "table" then
        return power.Name
    end
    return nil
end

local function isBreathingQuest(definition)
    local power = questPowerName(definition)
    return power ~= nil and Breathings[power] ~= nil
end

local function powerAlreadyHeld(name)
    if not name then
        return true
    end
    local slot = getSlot()
    local powers = slot and slot:FindFirstChild("Powers")
    if not powers then
        return false
    end
    for _, value in ipairs(powers:GetChildren()) do
        if value:IsA("ValueBase") and value.Value == name then
            return true
        end
    end
    return false
end

-- Labels for the combat list (side = nil) or the side-quest list (side = true). Quests you can
-- take come first, then locked ones tagged with the reason, so a short list never looks broken.
-- Returns the labels and how many of them can actually be taken.
local function eligibleQuestLabels(side)
    side = side == true
    for label, key in pairs(questKeyByLabel) do
        if isSideQuest(Quests.Holder[key]) == side then
            questKeyByLabel[label] = nil
            questLockByLabel[label] = nil
        end
    end
    local open, locked = {}, {}
    for key, definition in pairs(Quests.Holder) do
        -- Side quests without a giver (Muzan's trainings) are started by other systems.
        local offered = not side or (definition.OfferNpc ~= nil and definition.OfferNpc ~= false)
        if offered and isSideQuest(definition) == side and not isBreathingQuest(definition) then
            local ok, why = questEligible(key)
            -- Locked boss hunts would add ~30 rows of noise; they only matter once you qualify.
            if ok or definition.Category ~= "BossHunt" then
                local level = (definition.Requirements and definition.Requirements.Level) or 0
                local power = questPowerName(definition)
                local suffix = ""
                if power and not powerAlreadyHeld(power) then
                    suffix = string.format("  (swaps to %s)", power)
                end
                if not ok then
                    suffix = string.format("%s  [%s]", suffix, tostring(why))
                end
                local label = string.format("Lv%d  %s  -  %d exp%s", level, tostring(definition.QuestInstance or key), questExp(definition), suffix)
                questKeyByLabel[label] = key
                questLockByLabel[label] = not ok and tostring(why) or nil
                local rows = ok and open or locked
                rows[#rows + 1] = { label = label, level = level }
            end
        end
    end

    local labels = { BEST_QUEST_LABEL }
    for _, rows in ipairs({ open, locked }) do
        table.sort(rows, function(a, b)
            if a.level ~= b.level then
                return a.level < b.level
            end
            return a.label < b.label
        end)
        for _, row in ipairs(rows) do
            labels[#labels + 1] = row.label
        end
    end
    elevate()
    return labels, #open
end

-- usable(key), when given, filters out quests that cannot be finished right now.
local function bestQuestKey(side, usable)
    side = side == true
    local bestKey, bestExp, bestSafe, bestLevel
    for label, key in pairs(questKeyByLabel) do
        local definition = Quests.Holder[key]
        if definition and not questLockByLabel[label] and isSideQuest(definition) == side
            and questEligible(key) and (usable == nil or usable(key)) then
            local exp = questExp(definition)
            local level = (definition.Requirements and definition.Requirements.Level) or 0
            local safe = powerAlreadyHeld(questPowerName(definition))
            local better = false
            if not bestKey then
                better = true
            elseif exp ~= bestExp then
                better = exp > bestExp
            elseif safe ~= bestSafe then
                better = safe
            else
                better = level > bestLevel
            end
            if better then
                bestKey, bestExp, bestSafe, bestLevel = key, exp, safe, level
            end
        end
    end
    return bestKey, bestExp
end

local function resolveQuestSelection()
    local picked = Options.QuestPick and Options.QuestPick.Value
    if picked == nil or picked == "" or picked == BEST_QUEST_LABEL then
        return bestQuestKey()
    end
    local key = questKeyByLabel[picked]
    if key and questEligible(key) then
        return key
    end
    return bestQuestKey()
end

local giverPositions = {}

local function findGiverPrompt(npcName)
    local debree = workspace:FindFirstChild("Debree")
    if not debree or not npcName then
        return nil
    end
    for _, instance in ipairs(debree:GetDescendants()) do
        if instance:IsA("ProximityPrompt") then
            local parent = instance.Parent
            local position = parent and (parent:IsA("Attachment") and parent.WorldPosition or parent:IsA("BasePart") and parent.Position)
            if position then
                giverPositions[instance.ObjectText] = position
            end
            if instance.ObjectText == npcName then
                return instance
            end
        end
    end
    return nil
end

findGiverPrompt("") -- Remember giver locations before travelling streams their prompts out.

local giverHold = nil

local function releaseGiverHold()
    if giverHold then
        giverHold:Disconnect()
        giverHold = nil
    end
end

local function holdAtGiver(prompt)
    releaseGiverHold()
    local anchorPart = prompt.Parent
    giverHold = RunService.Heartbeat:Connect(function()
        local hrp = getRoot()
        if hrp and anchorPart and anchorPart.Parent then
            hrp.CFrame = CFrame.new(anchorPart.Position + GIVER_OFFSET)
            hrp.AssemblyLinearVelocity = Vector3.zero
        end
    end)
    return giverHold
end

local function acceptQuest(key)
    local definition = Quests.Holder[key]
    if not definition then
        return false, "unknown quest"
    end
    if not requirementsPass(definition.Requirements) then
        local ok, why = pcall(ItemRequirements.Describe, definition.Requirements)
        return false, string.format("requires %s", ok and tostring(why) or "something you don't have")
    end
    local allowed, code, blocker = Quests.CanAddQuest(key)
    elevate()
    if not allowed then
        if code == true then
            return false, "quest cooldown is still active", true
        end
        if code == 2 then
            return false, "already completed"
        end
        return false, string.format("already doing %s", tostring(blocker))
    end

    local npcName = tostring(definition.OfferNpc)
    local prompt = findGiverPrompt(npcName)
    if not prompt and not giverPositions[npcName] then
        local ok, position = pcall(Regions.GetNpcSpawn, npcName)
        if ok and typeof(position) == "Vector3" then
            giverPositions[npcName] = position
        end
    end
    if not prompt and giverPositions[npcName] then
        local hrp = getRoot()
        if hrp then
            hrp.CFrame = CFrame.new(giverPositions[npcName] + GIVER_OFFSET)
            local deadline = os.clock() + 10
            repeat
                task.wait(0.25)
                prompt = findGiverPrompt(npcName)
            until prompt or not alive or os.clock() >= deadline
            elevate()
        end
    end
    if not prompt then
        return false, string.format("waiting for %s to load", npcName), true
    end

    holdAtGiver(prompt)
    task.wait(GIVER_SETTLE)
    pcall(fireproximityprompt, prompt)
    task.wait(0.4)
    SignalEvent.ToServer("AddQuest", key)
    task.wait(GIVER_ACCEPT_WAIT)
    releaseGiverHold()
    elevate()

    if Quests.GetPlayerQuestState(LocalPlayer, key) ~= "Doing" then
        return false, string.format("%s would not hand it over", npcName)
    end
    return true
end

local function formatCountdown(seconds)
    if seconds <= 0 then
        return "expired"
    end
    return string.format("%d:%02d", math.floor(seconds / 60), math.floor(seconds % 60))
end

local function isValidTarget(rig, wanted, wantedCount, hostileOnly)
    if not rig or not rig.Parent then
        return false
    end
    local humanoid = rig:FindFirstChildOfClass("Humanoid")
    local root = rig:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root or humanoid.Health <= 0 then
        return false
    end
    if hostileOnly and rig:GetAttribute("IsMob") ~= true then
        return false
    end
    if wantedCount > 0 and not wanted[rig.Name] then
        return false
    end
    return true
end

local function targetDied(rig)
    if not rig then
        return false
    end
    if not rig.Parent then
        return true
    end
    local humanoid = rig:FindFirstChildOfClass("Humanoid")
    return humanoid == nil or humanoid.Health <= 0
end

local function findTarget(wanted, wantedCount, hostileOnly, near, radius)
    local hrp = getRoot()
    if not hrp then
        return nil
    end
    local best, bestDistance
    for _, region in ipairs(RegionRoot:GetChildren()) do
        local active = region:FindFirstChild("ActiveNpcs")
        if active then
            for _, folder in ipairs(active:GetChildren()) do
                local rig = folder:FindFirstChild(folder.Name)
                if isValidTarget(rig, wanted, wantedCount, hostileOnly)
                    and (not near or (rig.HumanoidRootPart.Position - near).Magnitude <= radius) then
                    local distance = (rig.HumanoidRootPart.Position - hrp.Position).Magnitude
                    if not bestDistance or distance < bestDistance then
                        best, bestDistance = rig, distance
                    end
                end
            end
        end
    end
    return best
end

local function spawnPosition(wanted)
    for name in pairs(wanted) do
        local ok, position = pcall(Regions.GetNpcSpawn, name)
        if ok and typeof(position) == "Vector3" then
            return position, name
        end
    end
    return nil
end

local function attackCFrame(root, mode, distance)
    if mode == "Above" then
        return CFrame.lookAt(root.Position + Vector3.new(0, distance, 0), root.Position)
    elseif mode == "Below" then
        return CFrame.lookAt(root.Position - Vector3.new(0, distance, 0), root.Position)
    end
    local behind = math.min(distance, MAX_BEHIND_OFFSET)
    return CFrame.lookAt((root.CFrame * CFrame.new(0, 0, behind)).Position, root.Position)
end

local farmTarget = nil
local anchorPosition = nil
local anchorConnection = nil
local returnCFrame = nil
local noclipParts = {}
local activeFarm = nil
local lootPosition = nil
local healRetreat = nil

--// Loot drops: BaseParts tagged "LootDrop" in workspace.LootDrops, each with a LootDropPrompt
--// (range 10). The client keeps the prompt disabled while the drop flies to its rest spot
--// (DropTarget), and the server stamps DropClaimedBy on whoever takes it.
local Loot = {
    HOVER = Vector3.new(0, 3, 0),
    FLIGHT_WAIT = 4,
    -- The server checks the prompt's range against where it last saw us, which trails the teleport.
    SETTLE = 0.35,
    CLAIM_WAIT = 1.5,
    CLAIM_TRIES = 2,
    failed = setmetatable({}, { __mode = "k" }),
}

function Loot.eligible(drop)
    -- Mirrors the game's own LootDrop VisualBinder.isEligible check.
    local owner = drop:GetAttribute("DropOwnerUserId")
    if typeof(owner) == "number" and owner ~= LocalPlayer.UserId then
        return false
    end
    local reserved = drop:GetAttribute("DropReservedFor")
    if typeof(reserved) == "string" and not string.find(reserved, "," .. LocalPlayer.UserId .. ",", 1, true) then
        return false
    end
    return drop:GetAttribute("DropClaimedBy") == nil
end

function Loot.restPosition(drop)
    local target = drop:GetAttribute("DropTarget")
    return typeof(target) == "Vector3" and target or drop.Position
end

-- landedOnly skips drops still in flight (their prompt is disabled until they land).
local function lootNear(center, radius, landedOnly)
    local found = {}
    for _, drop in ipairs(CollectionService:GetTagged("LootDrop")) do
        local prompt = drop:IsA("BasePart") and drop.Parent and drop:FindFirstChildWhichIsA("ProximityPrompt")
        if prompt and not Loot.failed[drop] and Loot.eligible(drop)
            and (not landedOnly or prompt.Enabled)
            and (Loot.restPosition(drop) - center).Magnitude <= radius then
            found[#found + 1] = drop
        end
    end
    return found
end

function Loot.grab(drop)
    local prompt = drop:FindFirstChildWhichIsA("ProximityPrompt")
    if not prompt then
        return false
    end
    lootPosition = Loot.restPosition(drop) + Loot.HOVER
    local deadline = os.clock() + Loot.FLIGHT_WAIT
    repeat
        task.wait(0.1)
    until prompt.Enabled or not drop.Parent or os.clock() >= deadline
    task.wait(Loot.SETTLE)
    for _ = 1, Loot.CLAIM_TRIES do
        if not drop.Parent or drop:GetAttribute("DropClaimedBy") ~= nil then
            break
        end
        pcall(fireproximityprompt, prompt)
        deadline = os.clock() + Loot.CLAIM_WAIT
        repeat
            task.wait(0.1)
        until not drop.Parent or drop:GetAttribute("DropClaimedBy") ~= nil or os.clock() >= deadline
    end
    lootPosition = nil
    return not drop.Parent or drop:GetAttribute("DropClaimedBy") == LocalPlayer.UserId
end

local lootBusy = false

local function collectLoot(center, radius)
    if lootBusy then
        return 0
    end
    lootBusy = true
    local taken = 0
    for _ = 1, 20 do
        local drops = lootNear(center, radius)
        if #drops == 0 or not alive then
            break
        end
        if Loot.grab(drops[1]) then
            taken += 1
        else
            Loot.failed[drops[1]] = true
        end
    end
    lootPosition = nil
    lootBusy = false
    return taken
end

--// Chests: the server announces every chest to every player through the "ChestState" signal
--// ({ chestGuid, configId, position, state, openedByUserId }; states seen live: Spawned, Locked,
--// Opening, Opened, Despawned), and the first player to fire an unlocked chest's ChestPrompt
--// opens it for everyone - a Common Chest went 4s after it spawned. Sealed caches start Locked
--// behind three guards in the Temporary region and unlock once those die. workspace.Chests also
--// holds things that are not chests (Snow Mounds need a Shovel), so only models with a ChestGuid
--// count, and chests streamed out of range are still known from the signal.
local Chest = {
    ROWS = 6,
    GUARD_RADIUS = 120, -- captains leash 100 studs from their post
    NEAR_RADIUS = 60, -- guard search for chest types whose guard names are unknown
    GUARD_WAIT = 12, -- still Locked with no guard in sight for this long: give up on it for now
    STREAM_WAIT = 10, -- hovering over its spot and the model never streamed in
    BUDGET = 240, -- one chest, guards (and a respawn or two) included
    SKIP = 300,
    -- Respawning is instant, but three lives lost to one chest's guards (T3 at Lv77: three in
    -- 110s without clearing them) means it is not winnable yet, so stop feeding it.
    MAX_DEATHS = 3,
    TOO_STRONG_SKIP = 900,
    SWEEP_RADIUS = 120, -- guards die up to a leash from their chest, and their drops count too
    LOOT_WAIT = 3,
    OPEN_TRIES = 3,
    CLOSED = { Opening = true, Opened = true, Despawned = true },
    known = {}, -- tostring(guid) -> { guid, id, position, state, by, model }
    skipUntil = {},
    done = {},
    guardNames = {}, -- ChestId -> { [normalized guard name] = true }
    types = {},
    spawns = {}, -- every sealed cache spawn point, for finding caches that spawned before you joined
    SWEEP_INTERVAL = 120,
    current = nil, -- the entry being worked
    detour = nil, -- where the chest run started (another farm's spot, or where you stood)
    lastSpot = nil, -- the chest being worked, swept for loot before we leave it
    opening = false, -- keeps auto loot off a chest's drops while the chest run takes them
    status = "Off",
}

function Chest.record(payload)
    if type(payload) ~= "table" or payload.chestGuid == nil then
        return
    end
    local key = tostring(payload.chestGuid)
    if payload.state == "Despawned" then
        Chest.known[key] = nil
        Chest.done[key] = nil
        Chest.skipUntil[key] = nil
        return
    end
    local entry = Chest.known[key] or { guid = key }
    Chest.known[key] = entry
    entry.state = payload.state or entry.state
    entry.id = payload.configId or entry.id
    entry.by = payload.openedByUserId
    if typeof(payload.position) == "Vector3" then
        entry.position = payload.position
    end
end

do
    -- The game's ChestController keeps the last state of every chest announced since you joined.
    local ok, controller = pcall(require, ReplicatedStorage.CAM.Client.Controllers.ChestController)
    if ok and type(controller) == "table" then
        local states = type(controller.handleState) == "function" and select(2, pcall(debug.getupvalue, controller.handleState, 1))
        if type(states) == "table" then
            for _, payload in pairs(states) do
                Chest.record(payload)
            end
        end
        local idsOk, ids = pcall(controller.getChestIds)
        if idsOk and type(ids) == "table" then
            for _, id in ipairs(ids) do
                Chest.types[#Chest.types + 1] = tostring(id)
            end
        end
    end
    -- Guard rosters come from the world-event NPC definitions (Sealed Chest T1/T2/T3).
    local content = ReplicatedStorage:FindFirstChild("Ouwland") and ReplicatedStorage.Ouwland:FindFirstChild("Content")
    for _, module in ipairs(content and content:GetDescendants() or {}) do
        if module:IsA("ModuleScript") and module.Parent and module.Parent.Name == "Npcs"
            and (string.find(module.Name, "Chest", 1, true) or string.find(module.Name, "Cache", 1, true)) then
            local loaded, definition = pcall(require, module)
            local event = loaded and type(definition) == "table" and definition.WorldEvent
            if type(event) == "table" and event.ChestId and type(event.Guards) == "table" then
                local names = {}
                for _, guard in ipairs(event.Guards) do
                    for _, name in ipairs({ guard.NpcCode, guard.Config }) do
                        if type(name) == "string" then
                            names[normalizeName(name)] = true
                        end
                    end
                end
                Chest.guardNames[event.ChestId] = names
                for _, spawn in ipairs(type(definition.Spawns) == "table" and definition.Spawns or {}) do
                    if typeof(spawn) == "CFrame" then
                        Chest.spawns[#Chest.spawns + 1] = spawn.Position
                    end
                end
            end
        end
    end
    if #Chest.types == 0 then
        for id in pairs(Chest.guardNames) do
            Chest.types[#Chest.types + 1] = id
        end
        table.insert(Chest.types, "Common Chest")
        table.insert(Chest.types, "Rare Chest")
    end
    table.sort(Chest.types)
    local connection = SignalEvent:Connect(function(name, payload)
        if name == "ChestState" then
            Chest.record(payload)
        end
    end)
    if connection then
        Library:GiveSignal(connection)
    end
    elevate()
end

-- Folds in chest models that streamed in (some were announced before you joined).
function Chest.scan()
    for _, model in ipairs(ChestFolder:GetChildren()) do
        local guid = model:GetAttribute("ChestGuid")
        if guid ~= nil and model:IsA("Model") then
            local key = tostring(guid)
            local entry = Chest.known[key]
            if not entry then
                entry = { guid = key, state = model:GetAttribute("ChestState") }
                Chest.known[key] = entry
            end
            entry.model = model
            entry.id = model:GetAttribute("ChestId") or entry.id or model.Name
            entry.position = model:GetPivot().Position
        end
    end
    return Chest.known
end

function Chest.model(entry)
    local model = entry.model
    if model and model.Parent == ChestFolder then
        return model
    end
    entry.model = nil
    for _, candidate in ipairs(ChestFolder:GetChildren()) do
        if tostring(candidate:GetAttribute("ChestGuid")) == entry.guid then
            entry.model = candidate
            return candidate
        end
    end
    return nil
end

-- The signal only announces chests that change after you join, so caches already standing are
-- found by asking the game to stream in each spawn point in range; the character never moves.
function Chest.discover(from, range)
    for _, position in ipairs(Chest.spawns) do
        if not alive or not (Toggles.AutoChest and Toggles.AutoChest.Value) then
            break
        end
        local known = false
        for _, entry in pairs(Chest.known) do
            if entry.position and (entry.position - position).Magnitude < 20 then
                known = true
                break
            end
        end
        if not known and (position - from).Magnitude <= range then
            pcall(LocalPlayer.RequestStreamAroundAsync, LocalPlayer, position, 2)
            elevate()
            Chest.scan()
        end
    end
end

function Chest.stateOf(entry)
    local model = entry.model
    local live = model and model.Parent and model:GetAttribute("ChestState")
    -- The signal knows about Opening/Opened before (or without) the model attribute changing.
    if Chest.CLOSED[entry.state] then
        return entry.state
    end
    return live or entry.state or "?"
end

function Chest.isOpen(entry)
    local model = entry.model
    return Chest.CLOSED[Chest.stateOf(entry)] == true
        or (model ~= nil and model.Parent ~= nil and model:GetAttribute("IsOpen") == true)
end

function Chest.eligible(entry)
    if Chest.known[entry.guid] ~= entry or Chest.done[entry.guid] or not entry.position
        or (Chest.skipUntil[entry.guid] or 0) > os.clock() or Chest.isOpen(entry) then
        return false
    end
    local picked, count = selectedValues(Options.ChestTypes)
    if count > 0 and not picked[entry.id] then
        return false
    end
    if Toggles.ChestUnlockedOnly and Toggles.ChestUnlockedOnly.Value and Chest.stateOf(entry) == "Locked" then
        return false
    end
    return true
end

-- Optional (off by default, respawning is instant): below the leave threshold chests wait. The
-- chest is not dropped, it is picked up again once you have healed.
function Chest.lowHealth()
    local _, char = getRoot()
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    local limit = Options.ChestLeaveHealth and Options.ChestLeaveHealth.Value or 0
    return humanoid ~= nil and humanoid.MaxHealth > 0 and humanoid.Health / humanoid.MaxHealth * 100 < limit
end

-- Nearest chest worth a trip, counting range from where the chest run started.
function Chest.pick()
    Chest.scan()
    if Chest.lowHealth() then
        Chest.status = "HP too low for chest guards - waiting to heal"
        return nil
    end
    local current = Chest.current
    local keep = current and Chest.eligible(current)
    if keep and Chest.stateOf(current) ~= "Locked" then
        return current
    end
    local hrp = getRoot()
    if not hrp then
        return nil
    end
    local from = Chest.detour and Chest.detour.Position or hrp.Position
    local range = Options.ChestRange and Options.ChestRange.Value or math.huge
    local best, bestDistance, ready, readyDistance
    for _, entry in pairs(Chest.known) do
        if Chest.eligible(entry) then
            local distance = (entry.position - from).Magnitude
            if distance <= range then
                if not bestDistance or distance < bestDistance then
                    best, bestDistance = entry, distance
                end
                if Chest.stateOf(entry) ~= "Locked" and (not readyDistance or distance < readyDistance) then
                    ready, readyDistance = entry, distance
                end
            end
        end
    end
    -- An unlocked chest goes to whoever fires it first (a Common Chest lasted 4s), so it cuts in
    -- ahead of a guard fight, which is resumed afterwards.
    if ready then
        return ready
    end
    if keep then
        return current
    end
    if not best then
        Chest.status = "No chest in range - waiting for one to spawn"
    end
    return best
end

function Chest.isGuard(rig, entry, center)
    if not isValidTarget(rig, {}, 0, true) then
        return false
    end
    local distance = (rig.HumanoidRootPart.Position - center).Magnitude
    local names = Chest.guardNames[entry.id]
    if names then
        -- By name: a 3000 HP boss (Sumari) stands 95 studs from one T1 cache.
        return names[normalizeName(rig.Name)] == true and distance <= Chest.GUARD_RADIUS
    end
    return distance <= Chest.NEAR_RADIUS
end

function Chest.guard(entry, center)
    if Chest.isGuard(farmTarget, entry, center) then
        return farmTarget
    end
    local hrp = getRoot()
    local best, bestDistance
    for _, region in ipairs(RegionRoot:GetChildren()) do
        local active = region:FindFirstChild("ActiveNpcs")
        for _, folder in ipairs(active and active:GetChildren() or {}) do
            local rig = folder:FindFirstChild(folder.Name)
            if Chest.isGuard(rig, entry, center) then
                local distance = hrp and (rig.HumanoidRootPart.Position - hrp.Position).Magnitude or 0
                if not bestDistance or distance < bestDistance then
                    best, bestDistance = rig, distance
                end
            end
        end
    end
    return best
end

function Chest.skip(entry, why, seconds)
    Chest.skipUntil[entry.guid] = os.clock() + (seconds or Chest.SKIP)
    Chest.status = string.format("Skipped %s: %s", tostring(entry.id), why)
    if Chest.current == entry then
        Chest.current = nil
    end
    anchorPosition = nil
end

-- Takes every drop of ours within radius of center, first giving fresh drops up to spawnWait
-- seconds to appear. Auto loot stands off meanwhile so the two never fight over a drop.
function Chest.take(center, radius, spawnWait)
    Chest.opening = true
    local deadline = os.clock() + (spawnWait or 0)
    while alive and os.clock() < deadline and #lootNear(center, radius) == 0 do
        task.wait(0.2)
    end
    deadline = os.clock() + 5
    while lootBusy and alive and os.clock() < deadline do
        task.wait(0.1)
    end
    local taken = collectLoot(center, radius)
    Chest.opening = false
    state.looted = (state.looted or 0) + taken
    elevate()
    return taken
end

-- Loot first: before leaving a chest for the next one or for home, take every drop of ours still
-- around it - the chest's own and whatever its guards dropped up to a leash away.
function Chest.sweep()
    local spot = Chest.lastSpot
    Chest.lastSpot = nil
    if spot and #lootNear(spot, Chest.SWEEP_RADIUS) > 0 then
        Chest.status = "Picking up the loot before moving on..."
        farmTarget = nil
        anchorPosition = spot + Vector3.new(0, TRAVEL_HEIGHT, 0)
        Chest.take(spot, Chest.SWEEP_RADIUS, 0)
        anchorPosition = nil
    end
end

function Chest.open(entry, model, prompt)
    Chest.status = string.format("Opening %s...", tostring(entry.id))
    local anchor = prompt.Parent
    local spot = anchor and (anchor:IsA("Attachment") and anchor.WorldPosition or anchor:IsA("BasePart") and anchor.Position)
    if not spot then
        local pivot = model:GetPivot()
        spot = pivot.Position + pivot.LookVector * 4
    end
    anchorPosition = spot + Loot.HOVER
    task.wait(0.6)
    for _ = 1, Chest.OPEN_TRIES do
        pcall(fireproximityprompt, prompt)
        local deadline = os.clock() + 2
        repeat
            task.wait(0.1)
        until Chest.isOpen(entry) or not model.Parent or os.clock() >= deadline
        if Chest.isOpen(entry) or not model.Parent then
            break
        end
    end
    elevate()
    if not Chest.isOpen(entry) then
        Chest.skip(entry, "the game would not open it")
        return
    end
    Chest.done[entry.guid] = true
    if Chest.current == entry then
        Chest.current = nil
    end
    -- IsOpen can flip before the signal saying who opened it arrives.
    local deadline = os.clock() + 1.5
    while entry.by == nil and alive and os.clock() < deadline do
        task.wait(0.1)
    end
    local mine = entry.by == LocalPlayer.UserId
    if mine then
        state.chestsOpened = (state.chestsOpened or 0) + 1
    end
    local taken = Chest.take(model:GetPivot().Position, Chest.SWEEP_RADIUS, Chest.LOOT_WAIT)
    Chest.status = string.format("%s %s, took %d drop(s)", mine and "Opened" or "Someone else opened", tostring(entry.id), taken)
    anchorPosition = nil
end

-- One tick of work on a chest. Returns a guard to fight, or nil after travelling, waiting,
-- opening or giving up.
function Chest.step(entry)
    if Chest.current ~= entry then
        -- Loot first, then the next chest (even one somebody could open before we get there).
        Chest.sweep()
        if not Chest.detour then
            local hrp = getRoot()
            Chest.detour = hrp and hrp.CFrame
            -- Leaving the farm spot: take what already dropped there before flying off.
            if hrp and Toggles.AutoLoot.Value and #lootNear(hrp.Position, Options.LootRadius.Value) > 0 then
                Chest.status = "Picking up the loot before leaving..."
                Chest.take(hrp.Position, Options.LootRadius.Value, 0)
            end
        end
        Chest.current = entry
        entry.started = os.clock()
        entry.guardSeen = entry.started
        entry.streamAsked = false
    end
    local now = os.clock()
    Chest.lastSpot = entry.position
    if now - entry.started > Chest.BUDGET then
        Chest.skip(entry, "took too long")
        return nil
    end
    local model = Chest.model(entry)
    if not model then
        -- Chest models stream out a couple of hundred studs away, which a guard chase can reach:
        -- keep fighting from the known position, and only give up if it never loads over the spot.
        if Chest.stateOf(entry) == "Locked" then
            local guard = Chest.guard(entry, entry.position)
            if guard then
                entry.guardSeen = now
                entry.missingSince = nil
                Chest.status = string.format("Fighting the %s guards...", tostring(entry.id))
                return guard
            end
        end
        entry.missingSince = entry.missingSince or now
        Chest.status = string.format("Flying to %s...", tostring(entry.id))
        anchorPosition = entry.position + Vector3.new(0, TRAVEL_HEIGHT, 0)
        if not entry.streamAsked then
            entry.streamAsked = true
            pcall(LocalPlayer.RequestStreamAroundAsync, LocalPlayer, entry.position, 2)
            elevate()
        end
        if os.clock() - entry.missingSince > Chest.STREAM_WAIT then
            Chest.skip(entry, "it never loaded")
        end
        task.wait(SEARCH_INTERVAL)
        return nil
    end
    entry.missingSince = nil
    local center = model:GetPivot().Position
    if Chest.isOpen(entry) then
        -- Someone got there first; anything reserved for us is still worth taking.
        Chest.done[entry.guid] = true
        Chest.current = nil
        anchorPosition = center + Vector3.new(0, TRAVEL_HEIGHT, 0)
        Chest.take(center, Chest.SWEEP_RADIUS, Chest.LOOT_WAIT)
        Chest.status = string.format("Someone else opened %s", tostring(entry.id))
        anchorPosition = nil
        return nil
    end
    local prompt = model:FindFirstChild("ChestPrompt", true)
    if prompt and Chest.stateOf(entry) ~= "Locked" then
        Chest.open(entry, model, prompt)
        return nil
    end
    local guard = Chest.guard(entry, center)
    if guard then
        entry.guardSeen = now
        Chest.status = string.format("Fighting the %s guards...", tostring(entry.id))
        return guard
    end
    -- Hover over it so its guards stream in and come to us.
    Chest.status = string.format("Waiting for the %s guards...", tostring(entry.id))
    anchorPosition = center + Vector3.new(0, TRAVEL_HEIGHT, 0)
    if now - entry.guardSeen > Chest.GUARD_WAIT then
        Chest.skip(entry, prompt and "no guards showed up" or "it has no prompt")
    end
    task.wait(SEARCH_INTERVAL)
    return nil
end

-- Back from a chest run: put the character where it started (where another farm left off, or
-- where you stood), well clear of any guards still up.
function Chest.returnHome()
    Chest.sweep()
    local home = Chest.detour
    Chest.detour = nil
    Chest.current = nil
    farmTarget = nil
    state.target = nil
    anchorPosition = nil
    local hrp = getRoot()
    if hrp and home then
        hrp.CFrame = home
        hrp.AssemblyLinearVelocity = Vector3.zero
    end
end

local function farmConfig()
    if Toggles.AutoYeti and Toggles.AutoYeti.Value then
        -- Around 60s in, two Small Yetis appear and the Yeti takes no damage for ~90s (seen in
        -- both fights), so they go first while any is alive.
        local smalls = false
        local temporary = RegionRoot:FindFirstChild("Temporary")
        local active = temporary and temporary:FindFirstChild("ActiveNpcs")
        for _, folder in ipairs(active and active:GetChildren() or {}) do
            local rig = folder.Name == "Small Yeti" and folder:FindFirstChild(folder.Name)
            local humanoid = rig and rig:FindFirstChildOfClass("Humanoid")
            if humanoid and humanoid.Health > 0 then
                smalls = true
                break
            end
        end
        return {
            kind = "yeti",
            label = "Auto Yeti",
            wanted = smalls and { ["Small Yeti"] = true } or { ["Yeti Demon"] = true },
            count = 1,
            hostileOnly = true,
            position = Options.BossPosition.Value,
            distance = Options.BossDistance.Value,
            travel = false,
            toggle = Toggles.AutoYeti,
        }
    end
    local bossConfig
    if Toggles.AutoBoss and Toggles.AutoBoss.Value then
        local wanted, count = selectedValues(Options.BossTargets)
        bossConfig = {
            kind = "boss",
            label = "Boss Farm",
            wanted = wanted,
            count = count,
            hostileOnly = false,
            position = Options.BossPosition.Value,
            distance = Options.BossDistance.Value,
            travel = Toggles.BossTravel.Value,
            toggle = Toggles.AutoBoss,
        }
        -- A live hunt for a picked boss outranks chests: hunts expire, chests wait.
        for _, hunt in ipairs(activeBossHunts()) do
            if count == 0 or wanted[hunt.name] then
                return bossConfig
            end
        end
    end
    if Toggles.AutoChest and Toggles.AutoChest.Value then
        -- Beside another farm, chests only take over while one is in range, and that farm picks
        -- up where it was once they are done.
        local alongside = bossConfig ~= nil or (Toggles.AutoQuest and Toggles.AutoQuest.Value)
            or (Toggles.AutoFarm and Toggles.AutoFarm.Value) or false
        local entry = Chest.pick()
        if entry or not alongside then
            return {
                kind = "chest",
                label = "Auto Chest",
                chest = entry,
                wanted = {},
                count = 0,
                hostileOnly = true,
                position = Options.FarmPosition.Value,
                distance = Options.FarmDistance.Value,
                travel = true,
                toggle = Toggles.AutoChest,
            }
        end
    end
    if Toggles.AutoQuest and Toggles.AutoQuest.Value then
        local wanted, count = questTargets()
        return {
            kind = "quest",
            label = "Auto Quest",
            wanted = wanted,
            count = count,
            hostileOnly = false,
            position = Options.QuestPosition.Value,
            distance = Options.QuestDistance.Value,
            travel = true,
            toggle = Toggles.AutoQuest,
        }
    end
    if bossConfig then
        return bossConfig
    end
    if Toggles.AutoFarm and Toggles.AutoFarm.Value then
        local wanted, count = selectedValues(Options.FarmMobs)
        return {
            kind = "mob",
            label = "Auto Farm",
            wanted = wanted,
            count = count,
            hostileOnly = Toggles.HostileOnly.Value,
            position = Options.FarmPosition.Value,
            distance = Options.FarmDistance.Value,
            travel = Toggles.TravelToSpawn.Value,
            toggle = Toggles.AutoFarm,
        }
    end
    return nil
end

local function cacheNoclipParts()
    table.clear(noclipParts)
    local _, char = getRoot()
    if not char then
        return
    end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") and part.CanCollide then
            noclipParts[#noclipParts + 1] = part
        end
    end
end

local function restoreCollisions()
    for _, part in ipairs(noclipParts) do
        if part.Parent then
            part.CanCollide = true
        end
    end
    table.clear(noclipParts)
end

local function onAnchorStep()
    local hrp = getRoot()
    if not hrp then
        return
    end
    for _, part in ipairs(noclipParts) do
        if part.Parent then
            part.CanCollide = false
        end
    end
    local dodging = state.dodgeUntil and os.clock() < state.dodgeUntil and state.dodgePosition
    local hold = lootPosition or healRetreat or dodging or nil
    if hold then
        hrp.CFrame = CFrame.new(hold)
        hrp.AssemblyLinearVelocity = Vector3.zero
        return
    end
    if farmTarget and farmTarget.Parent and activeFarm then
        local root = farmTarget:FindFirstChild("HumanoidRootPart")
        if root then
            hrp.CFrame = attackCFrame(root, activeFarm.position, activeFarm.distance)
            hrp.AssemblyLinearVelocity = Vector3.zero
            return
        end
    end
    if anchorPosition then
        hrp.CFrame = CFrame.new(anchorPosition)
        hrp.AssemblyLinearVelocity = Vector3.zero
    end
end

local function startFarm()
    local hrp = getRoot()
    returnCFrame = hrp and hrp.CFrame or nil
    farmTarget = nil
    anchorPosition = nil
    state.farming = true
    weaponSlot = nil
    cacheNoclipParts()
    if anchorConnection then
        anchorConnection:Disconnect()
    end
    anchorConnection = RunService.Heartbeat:Connect(onAnchorStep)
end

local function stopFarm()
    state.farming = false
    farmTarget = nil
    state.target = nil
    activeFarm = nil
    anchorPosition = nil
    Chest.current = nil
    Chest.detour = nil
    Chest.lastSpot = nil
    releaseGiverHold()
    if anchorConnection then
        anchorConnection:Disconnect()
        anchorConnection = nil
    end
    restoreCollisions()
    local hrp = getRoot()
    if hrp and returnCFrame then
        hrp.CFrame = returnCFrame
    end
    returnCFrame = nil
end

local function drinkPotion(name)
    local _, slotByName = hotbarPotions()
    local index = slotByName[name]
    if not index then
        return false, string.format("%s is not on your hotbar", tostring(name))
    end
    local config = LocalPlayer:FindFirstChild("Items_Config")
    local equipped = config and config:FindFirstChild("Equipped")
    local hrp = getRoot()
    if not equipped or not hrp then
        return false, "Character is not ready"
    end
    local before = itemCount(name)
    local previous = equipped.Value
    state.healing = true
    if state.farming then
        healRetreat = hrp.Position + Vector3.new(0, HEAL_RETREAT_HEIGHT, 0)
    end
    if equipped.Value ~= index then
        if equipped.Value ~= 0 then
            equipped.Value = 0
            task.wait(EQUIP_SETTLE)
        end
        equipped.Value = index
        task.wait(EQUIP_SETTLE)
    end
    local drank = false
    if equipped.Value == index then
        -- The server drinks over ~1.85s after Down; an Up before that cancels it.
        SignalEvent.ToServer("Tool_Mouse", "Down", hrp.Position)
        task.wait(POTION_DRINK_TIME)
        SignalEvent.ToServer("Tool_Mouse", "Up", hrp.Position)
        local deadline = os.clock() + 1
        repeat
            task.wait(0.1)
        until itemCount(name) < before or os.clock() >= deadline
        drank = itemCount(name) < before
    end
    equipped.Value = 0
    task.wait(EQUIP_SETTLE)
    if previous ~= 0 and previous ~= index then
        equipped.Value = previous
        task.wait(EQUIP_SETTLE)
    end
    healRetreat = nil
    state.healing = false
    elevate()
    if not drank then
        return false, string.format("The game refused the %s", name)
    end
    return true
end

local Window = Library:CreateWindow({
    Title = "Slopix Hub",
    Footer = "Slayers 2",
    AutoShow = true,
    Center = true,
    Resizable = true,
    ShowCustomCursor = false,
    NotifySide = "Right",
})

-- Tabs are created up front so the sidebar order is fixed here, whatever order the
-- sections below fill them in.
local Tabs = {
    Home = Window:AddTab("Home", "house", "Welcome to Slopix Hub"),
    Farm = Window:AddTab("Farm", "swords", "Mobs, boss hunts and auto heal"),
    Quests = Window:AddTab("Quests", "scroll-text", "Accept, chain and complete quests"),
    Chests = Window:AddTab("Chests", "package", "Sealed caches and loot drops"),
    Fishing = Window:AddTab("Fishing", "fish", "Auto fishing with instant reel"),
    Market = Window:AddTab("Market", "store", "Black Marketer, shops and timed events"),
    Clan = Window:AddTab("Clan", "dices", "Clan spins"),
    Travel = Window:AddTab("Travel", "map", "Teleport to NPCs and shops"),
    Settings = Window:AddTab("Settings", "settings", "Menu, themes and configs"),
}

-- Groupboxes that more than one section adds to.
local Boxes = {
    Hub = Tabs.Home:AddGroupbox({ Side = "Left", Name = "Slopix Hub", IconName = "sparkles" }),
    Character = Tabs.Home:AddGroupbox({ Side = "Right", Name = "Character", IconName = "user" }),
    Codes = Tabs.Home:AddGroupbox({ Side = "Right", Name = "Codes", IconName = "gift" }),
}

do
    local DISCORD_INVITE = "https://discord.com/invite/WdPcxf5B83"
    Boxes.Hub:AddLabel(string.format("Welcome, %s.\nSlopix Hub for Slayers 2 (build %s).", LocalPlayer.DisplayName, state.build), true)
    Boxes.Hub:AddButton({
        Text = "Copy Discord invite",
        Func = function()
            if setclipboard then
                setclipboard(DISCORD_INVITE)
                notify("Slopix Hub", "Discord invite copied to your clipboard.", 4)
            else
                notify("Slopix Hub", DISCORD_INVITE, 10)
            end
        end,
    })
    Boxes.Hub:AddDivider()
end

local SpinGroup = Tabs.Clan:AddGroupbox({ Side = "Left", Name = "Clan auto spin", IconName = "refresh-cw" })

SpinGroup:AddDropdown("StopRarity", {
    Searchable = true,
    Text = "Stop at rarity",
    Values = RARITY_NAMES,
    Default = "Mythic",
    Multi = false,
})

SpinGroup:AddSlider("SpinDelay", {
    Text = "Spin delay",
    Default = 0.4,
    Min = 0.1,
    Max = 3,
    Rounding = 1,
    Suffix = "s",
})

SpinGroup:AddToggle("AutoSpin", {
    Text = "Auto spin",
    Default = false,
    Tooltip = "Rolls the clan remote directly (no UI). Stops at the selected rarity or when spins run out.",
})

SpinGroup:AddButton({
    Text = "Spin once",
    Func = function()
        if getSpinCount() <= 0 then
            notify("Auto Spin", "No clan spins left", 4)
            return
        end

        local ok, rolled = spinOnce()
        if ok then
            notify("Auto Spin", string.format("Rolled %s (%s)", rolled, tierNameOf(rolled)), 4)
        else
            notify("Auto Spin", "Roll rejected by server", 4)
        end
    end,
})

Boxes.Codes:AddButton({ Text = "Redeem all known codes", Func = function() task.spawn(redeemKnownCodes) end })
Boxes.Codes:AddLabel("Codes are read from the game's live catalog.", true)

local TargetGroup = Tabs.Farm:AddGroupbox({ Side = "Left", Name = "Mob farm", IconName = "crosshair" })
local WeaponGroup = Tabs.Farm:AddGroupbox({ Side = "Right", Name = "Weapon", IconName = "sword" })
Boxes.Positioning = Tabs.Farm:AddRightTabbox("Positioning")
local PositionGroup = Boxes.Positioning:AddTab("Mobs", "crosshair")

TargetGroup:AddDropdown("FarmMobs", {
    Searchable = true,
    Text = "Mobs",
    Values = mobNames(),
    Default = {},
    Multi = true,
    Tooltip = "Pick nothing to attack whatever hostile mob is nearest.",
})

TargetGroup:AddToggle("HostileOnly", {
    Text = "Hostile only",
    Default = true,
    Tooltip = "Only attack rigs the game flags as mobs, so quest NPCs and civilians are left alone.",
})

TargetGroup:AddToggle("TravelToSpawn", {
    Text = "Travel to spawn",
    Default = true,
    Tooltip = "When nothing is loaded, fly to the selected mob's spawn point and wait for it to appear.",
})

TargetGroup:AddToggle("AutoFarm", {
    Text = "Auto farm",
    Default = false,
    Tooltip = "Holds position on the target and swings with the equipped weapon.",
})

PositionGroup:AddDropdown("FarmPosition", {
    Searchable = true,
    Text = "Stand",
    Values = POSITION_MODES,
    Default = "Behind",
    Multi = false,
})

PositionGroup:AddSlider("FarmDistance", {
    Text = "Offset",
    Default = 5,
    Min = 3,
    Max = 10,
    Rounding = 1,
    Suffix = " studs",
})

PositionGroup:AddLabel(
    string.format("Behind is capped at %d studs - the game's swing box is shallow and stops landing past that. Above and Below reach further. Below needs the noclip Auto farm turns on for you.", MAX_BEHIND_OFFSET),
    true
)

local weaponNames = toolbarWeapons()
WeaponGroup:AddDropdown("FarmWeapon", {
    Searchable = true,
    Text = "Weapon",
    Values = weaponNames,
    Default = weaponNames[1] or "",
    Multi = false,
    Tooltip = "Owned weapons that are on your hotbar.",
})

WeaponGroup:AddButton({
    Text = "Equip selected",
    Func = function()
        if equipWeapon(Options.FarmWeapon.Value) then
            notify("Auto Farm", string.format("Equipped %s", Options.FarmWeapon.Value), 3)
        end
    end,
})

WeaponGroup:AddButton({
    Text = "Refresh lists",
    Func = function()
        local names = toolbarWeapons()
        Options.FarmWeapon:SetValues(names)
        Options.FarmMobs:SetValues(mobNames())
        notify("Auto Farm", string.format("%d weapon(s) on the hotbar", #names), 3)
    end,
})

WeaponGroup:AddLabel("This weapon is used by the boss farm too.", true)

local BossGroup = Tabs.Farm:AddGroupbox({ Side = "Left", Name = "Boss farm", IconName = "skull" })
local BossPositionGroup = Boxes.Positioning:AddTab("Bosses", "skull")
local TimerGroup = Tabs.Farm:AddGroupbox({ Side = "Left", Name = "Active hunts", IconName = "timer" })

BossGroup:AddDropdown("BossTargets", {
    Searchable = true,
    Text = "Bosses",
    Values = bossNames(),
    Default = {},
    Multi = true,
    Tooltip = "Only bosses with an active hunt are listed. Pick nothing and the farm takes the nearest one that is loaded.",
})

BossGroup:AddToggle("BossTravel", {
    Text = "Travel to boss",
    Default = true,
    Tooltip = "Fly to the boss spawn point and wait for it to appear.",
})

BossGroup:AddToggle("AutoBoss", {
    Text = "Auto boss farm",
    Default = false,
    Tooltip = "Same engine as the mob farm, aimed only at active boss hunts.",
})

BossGroup:AddButton({
    Text = "Refresh hunts",
    Func = function()
        local names = bossNames()
        Options.BossTargets:SetValues(names)
        notify("Boss Farm", string.format("%d active hunt(s)", #names), 3)
    end,
})

BossPositionGroup:AddDropdown("BossPosition", {
    Searchable = true,
    Text = "Stand",
    Values = POSITION_MODES,
    Default = "Above",
    Multi = false,
})

BossPositionGroup:AddSlider("BossDistance", {
    Text = "Offset",
    Default = 7,
    Min = 3,
    Max = 10,
    Rounding = 1,
    Suffix = " studs",
})

BossPositionGroup:AddLabel("Above keeps you off a boss's melee arc. Behind is still capped at 6 studs.", true)

local timerLabels = {}
for index = 1, BOSS_TIMER_ROWS do
    timerLabels[index] = TimerGroup:AddLabel("", true)
end
TimerGroup:AddDivider()
local timerFooter = TimerGroup:AddLabel("", true)

local function refreshTimers()
    local hunts = activeBossHunts()
    local now = os.time()
    for index = 1, BOSS_TIMER_ROWS do
        local hunt = hunts[index]
        local label = timerLabels[index]
        if hunt then
            label:SetText(string.format("%s  [%s / %s]  %s", hunt.name, hunt.tier, hunt.side, formatCountdown(hunt.expires - now)))
            label:SetVisible(true)
        else
            label:SetVisible(false)
        end
    end
    if #hunts == 0 then
        timerFooter:SetText("No active boss hunts right now.")
    elseif #hunts > BOSS_TIMER_ROWS then
        timerFooter:SetText(string.format("%d hunts active, showing the %d expiring soonest.", #hunts, BOSS_TIMER_ROWS))
    else
        timerFooter:SetText(string.format("%d active hunt(s), soonest first.", #hunts))
    end
end

local QuestGroup = Tabs.Quests:AddGroupbox({ Side = "Left", Name = "Combat quest", IconName = "swords" })
local QuestPositionGroup = Tabs.Quests:AddGroupbox({ Side = "Left", Name = "Positioning", IconName = "move-3d" })
local QuestProgressGroup = Tabs.Quests:AddGroupbox({ Side = "Right", Name = "Progress", IconName = "list-checks" })

local startingQuestLabels = eligibleQuestLabels()
QuestGroup:AddDropdown("QuestPick", {
    Searchable = true,
    Text = "Quest",
    Values = startingQuestLabels,
    Default = startingQuestLabels[1] or "",
    Multi = false,
    Tooltip = "Quests you can take come first. Locked ones follow with the reason in brackets, e.g. [Slayer/Hybrid only].",
})

QuestGroup:AddToggle("QuestChain", {
    Text = "Auto accept next",
    Default = false,
    Tooltip = "When the current quest finishes, take the next eligible one from the list.",
})

QuestGroup:AddToggle("AutoQuest", {
    Text = "Auto quest",
    Default = false,
    Tooltip = "Fights whatever your active quest's tasks point at.",
})


QuestGroup:AddButton({
    Text = "Accept selected",
    Func = function()
        task.spawn(function()
            elevate()
            local lock = questLockByLabel[Options.QuestPick.Value]
            if lock then
                notify("Auto Quest", string.format("That quest is locked: %s", lock), 5)
                return
            end
            local key = resolveQuestSelection()
            if not key then
                notify("Auto Quest", "Nothing you qualify for right now", 4)
                return
            end
            local definition = Quests.Holder[key]
            local name = definition and tostring(definition.QuestInstance) or key
            notify("Auto Quest", string.format("Going to %s...", tostring(definition.OfferNpc)), 3)
            local ok, why = acceptQuest(key)
            notify("Auto Quest", ok and string.format("Accepted %s (%d exp)", name, questExp(definition)) or string.format("Could not accept %s: %s", name, why), 5)
        end)
    end,
})

QuestGroup:AddButton({
    Text = "Refresh quest list",
    Func = function()
        local labels, openCount = eligibleQuestLabels()
        Options.QuestPick:SetValues(labels)
        local bestKey, bestExp = bestQuestKey()
        local definition = bestKey and Quests.Holder[bestKey]
        notify("Auto Quest", string.format("%d quest(s) available, %d locked. Best: %s (%d exp)",
            openCount, #labels - 1 - openCount,
            definition and tostring(definition.QuestInstance) or "none",
            bestExp or 0), 5)
    end,
})

QuestPositionGroup:AddDropdown("QuestPosition", {
    Searchable = true,
    Text = "Stand",
    Values = POSITION_MODES,
    Default = "Behind",
    Multi = false,
})

QuestPositionGroup:AddSlider("QuestDistance", {
    Text = "Offset",
    Default = 5,
    Min = 3,
    Max = 10,
    Rounding = 1,
    Suffix = " studs",
})

local questTaskLabels = {}
for index = 1, QUEST_TASK_ROWS do
    questTaskLabels[index] = QuestProgressGroup:AddLabel("", true)
end
QuestProgressGroup:AddDivider()
local questFooter = QuestProgressGroup:AddLabel("", true)

local function refreshQuestProgress()
    local rows = {}
    for _, quest in ipairs(activeQuests("combat")) do
        rows[#rows + 1] = { text = quest.instance .. ":", header = true }
        for _, task in ipairs(quest.tasks) do
            local done = task.value >= task.max
            local reachable = npcNameForCode(task.code) ~= nil
            local mark = done and "[x]" or (reachable and "[ ]" or "[!]")
            rows[#rows + 1] = {
                text = string.format("  %s %s  %d/%d", mark, task.name, task.value, task.max),
            }
        end
    end

    for index = 1, QUEST_TASK_ROWS do
        local row = rows[index]
        if row then
            questTaskLabels[index]:SetText(row.text)
            questTaskLabels[index]:SetVisible(true)
        else
            questTaskLabels[index]:SetVisible(false)
        end
    end

    if #rows == 0 then
        questFooter:SetText("No quest active. Pick one and press Accept.")
    else
        local _, count, blocked = questTargets()
        if count > 0 then
            questFooter:SetText(string.format("Auto quest can fight %d target(s). [!] = not a mob, do it yourself.", count))
        elseif #blocked > 0 then
            questFooter:SetText("Nothing here is a mob - this quest needs fishing, items or an NPC visit.")
        else
            questFooter:SetText("All tasks done. Turn it in, or enable Auto accept next.")
        end
    end
end

do
    local group = Tabs.Chests:AddGroupbox({ Side = "Left", Name = "Chests", IconName = "package" })
    local lootGroup = Tabs.Chests:AddGroupbox({ Side = "Left", Name = "Loot drops", IconName = "gem" })
    local listGroup = Tabs.Chests:AddGroupbox({ Side = "Right", Name = "Chests in world", IconName = "map-pin" })

    group:AddToggle("AutoChest", {
        Text = "Auto chests",
        Default = false,
        Tooltip = "Clears a chest's guards, opens it and picks up all your loot around it (guard drops too) before moving to the next chest. Beside the mob, boss or quest farm it only leaves for chests in range and puts you back where you were afterwards; a live boss hunt goes first.",
    })

    group:AddToggle("ChestUnlockedOnly", {
        Text = "Only open unlocked chests",
        Default = false,
        Tooltip = "Skip sealed caches whose guards are still up.",
    })

    group:AddDropdown("ChestTypes", {
        Searchable = true,
        Text = "Chest types",
        Values = Chest.types,
        Default = {},
        Multi = true,
        Tooltip = "Pick nothing to take every type. Sealed Cache T2 and T3 guards hit harder than T1.",
    })

    group:AddSlider("ChestRange", {
        Text = "Range",
        Default = 1000,
        Min = 100,
        Max = 6000,
        Rounding = 0,
        Suffix = " studs",
        Tooltip = "How far a chest may be, counted from where the chest run started (where another farm was, or where you stood).",
    })

    group:AddSlider("ChestLeaveHealth", {
        Text = "Leave chests below",
        Default = 0,
        Min = 0,
        Max = 90,
        Rounding = 0,
        Suffix = "% HP",
        Tooltip = "0 = never leave: respawning is instant and the chest run carries on after it. Above 0, chest guards are left alone below this HP and you go back until you have healed.",
    })

    local statusLabel = group:AddLabel("", true)
    group:AddLabel("Chests are first come, first served: whoever opens one opens it for everyone. Uses the Mob farm weapon and positioning.", true)

    lootGroup:AddToggle("AutoLoot", {
        Text = "Auto pick up loot",
        Default = false,
        Tooltip = "Grabs loot drops you are allowed to claim, mid-farm too (under a second each), then returns you to where you were.",
    })

    lootGroup:AddSlider("LootRadius", {
        Text = "Pickup radius",
        Default = 80,
        Min = 10,
        Max = 500,
        Rounding = 0,
        Suffix = " studs",
    })

    local rows = {}
    for index = 1, Chest.ROWS do
        rows[index] = listGroup:AddLabel("", true)
    end
    listGroup:AddDivider()
    local footer = listGroup:AddLabel("", true)

    Chest.refresh = function()
        statusLabel:SetText(Toggles.AutoChest.Value and Chest.status or "Off")
        local hrp = getRoot()
        local list = {}
        for _, entry in pairs(Chest.scan()) do
            if entry.position and not Chest.isOpen(entry) then
                list[#list + 1] = {
                    entry = entry,
                    distance = hrp and (entry.position - hrp.Position).Magnitude or 0,
                }
            end
        end
        table.sort(list, function(a, b)
            return a.distance < b.distance
        end)
        for index = 1, Chest.ROWS do
            local row = list[index]
            local label = rows[index]
            if row then
                local entry = row.entry
                local note = Chest.done[entry.guid] and "  (done)"
                    or (Chest.skipUntil[entry.guid] or 0) > os.clock() and "  (skipped)"
                    or not Chest.model(entry) and "  (not loaded)" or ""
                label:SetText(string.format("%s  [%s]  %d studs%s", tostring(entry.id), Chest.stateOf(entry), math.floor(row.distance), note))
                label:SetVisible(true)
            else
                label:SetVisible(false)
            end
        end
        if #list == 0 then
            footer:SetText(string.format("No unopened chests known right now. Opened: %d, loot taken: %d",
                state.chestsOpened or 0, state.looted or 0))
        else
            footer:SetText(string.format("%d unopened chest(s), nearest first. Opened: %d, loot taken: %d",
                #list, state.chestsOpened or 0, state.looted or 0))
        end
    end
end

--// Market: the Black Marketer and rotating shops are seeded from server time, so the
--// client can compute where he is, what he sells now, and what he will sell next visit.
-- Scoped in its own block: the main chunk is near Luau's 200-local limit.
local refreshMarket
do
    local MARKET_FORECAST_VISITS = 3
    local MARKET_FORECAST_CYCLES = 84
    local MARKET_TICK = 2
    local PURCHASE_WAIT = 3

    local MarketerDef = require(ReplicatedStorage.Ouwland.Content.Misc.Npcs["Black Marketer"])
    local MarketerVendor = MarketerDef.TimedVendor
    local ROTATING_SHOPS = {
        { label = "Elara (Mistfall Harbor)", path = { "Mistfall Harbor", "Npcs", "Elara" } },
        { label = "Lynx (Iceveil winter store)", path = { "Iceveil Valley", "Npcs", "Iceveil Settlement", "Winter Store Rep Lynx" } },
    }
    for _, shop in ipairs(ROTATING_SHOPS) do
        local node = ReplicatedStorage.Ouwland.Content
        for _, part in ipairs(shop.path) do
            node = node and node:FindFirstChild(part)
        end
        local ok, definition = pcall(require, node)
        shop.config = ok and type(definition) == "table" and definition.RotatingShop or nil
    end
    elevate()

    local function formatDuration(seconds)
        seconds = math.max(0, math.floor(seconds))
        local hours, minutes = seconds // 3600, (seconds % 3600) // 60
        if hours > 0 then
            return string.format("%d:%02d:%02d", hours, minutes, seconds % 60)
        end
        return string.format("%d:%02d", minutes, seconds % 60)
    end

    local function withCommas(number)
        local text = tostring(math.floor(number))
        while true do
            local changed
            text, changed = text:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
            if changed == 0 then
                return text
            end
        end
    end

    local function entryName(entry)
        return type(entry) == "table" and entry.Name or tostring(entry)
    end

    -- Returns the Wen price, or nil plus a label when the item costs Robux or is unknown.
    local function entryPrice(entry)
        local name = entryName(entry)
        local price = type(entry) == "table" and entry.Price or nil
        if typeof(price) ~= "table" then
            local listing = Shop.itemsforsale[name]
            price = listing and listing.Price
        end
        if typeof(price) ~= "table" then
            local definition = Items[name]
            price = definition and definition.Price
        end
        if typeof(price) ~= "table" then
            return nil, "?"
        end
        if price.Product or price.Gamepass then
            return nil, "Robux"
        end
        if type(price.Wen) == "number" then
            return price.Wen, "$" .. withCommas(price.Wen)
        end
        local currency, amount = next(price)
        return nil, string.format("%s %s", tostring(amount), tostring(currency))
    end

    local function rarityOfItem(name)
        local definition = Items[name]
        return definition and Rarities.Order[definition.Rarity] or "?"
    end

    local function describeEntry(entry)
        local name = entryName(entry)
        local _, priceText = entryPrice(entry)
        local owned = itemCount(name) > 0 and "  (owned)" or ""
        return string.format("%s  [%s]  %s%s", name, rarityOfItem(name), priceText, owned)
    end

    local marketerAlways = {}
    for _, entry in ipairs(MarketerVendor.Always or {}) do
        marketerAlways[entryName(entry)] = true
    end

    local function marketerCatalog()
        local names = {}
        for _, list in ipairs({ MarketerVendor.Always or {}, MarketerVendor.Stock or {} }) do
            for _, entry in ipairs(list) do
                local name = entryName(entry)
                if entryPrice(entry) and not table.find(names, name) then
                    names[#names + 1] = name
                end
            end
        end
        table.sort(names)
        return names
    end

    local function marketerStock(cycle)
        local ok, stock = pcall(TimedVendor.GetStock, MarketerVendor, cycle)
        return ok and stock or {}
    end

    local cachedMarketer
    local function marketerModel()
        if cachedMarketer and cachedMarketer:IsDescendantOf(workspace) then
            return cachedMarketer
        end
        local debree = workspace:FindFirstChild("Debree")
        local model = debree and debree:FindFirstChild("Black Marketer", true)
        cachedMarketer = model and model:IsA("Model") and model or nil
        return cachedMarketer
    end

    local function marketerStandPosition(cycle)
        local model = marketerModel()
        if model then
            return (model:GetPivot() * CFrame.new(0, 0, -4)).Position + Vector3.new(0, 2, 0)
        end
        local index = TimedVendor.GetSpotIndex(MarketerVendor, cycle, #MarketerDef.Spawns)
        local spot = MarketerDef.Spawns[index]
        return spot and spot.Position + Vector3.new(0, 4, 6)
    end

    -- Holds the character at a position for the duration of fn, then returns it home.
    local function visitPosition(position, fn)
        local hrp = getRoot()
        if not hrp or not position then
            return false
        end
        local home = hrp.CFrame
        lootBusy = true
        lootPosition = position
        local hold = not anchorConnection and RunService.Heartbeat:Connect(function()
            local root = getRoot()
            if root and lootPosition then
                root.CFrame = CFrame.new(lootPosition)
                root.AssemblyLinearVelocity = Vector3.zero
            end
        end)
        local ok, result = pcall(fn)
        lootPosition = nil
        lootBusy = false
        if hold then
            hold:Disconnect()
            local root = getRoot()
            if root then
                root.CFrame = home
            end
        end
        elevate()
        return ok and result
    end

    local function buyFromShop(name)
        -- Only ever spends Wen: a listing priced in Robux would open a real-money prompt.
        local listing = Shop.itemsforsale[name]
        local price = listing and listing.Price
        if typeof(price) ~= "table" then
            -- Vendor stock listed by name only (the Black Marketer's Frozen Heart) is priced on the item.
            local definition = Items[name]
            price = definition and definition.Price
        end
        if typeof(price) ~= "table" or type(price.Wen) ~= "number" or price.Product or price.Gamepass then
            return false, "not sold for Wen"
        end
        local slot = getSlot()
        local wen = slot and slot:FindFirstChild("Wen")
        if not wen or wen.Value < price.Wen then
            return false, string.format("needs $%s", withCommas(price.Wen))
        end
        local checked, allowed, reason = pcall(Shop.CanBuy, LocalPlayer, name, nil, 1)
        if checked and not allowed then
            return false, tostring(reason or "the shop refused")
        end
        local before = itemCount(name)
        SignalEvent.ToServer("PurchaseFromShop", name, 1)
        local deadline = os.clock() + PURCHASE_WAIT
        repeat
            task.wait(0.2)
        until itemCount(name) > before or os.clock() >= deadline
        if itemCount(name) > before then
            return true
        end
        return false, "no item arrived"
    end

    local MarketerGroup = Tabs.Market:AddGroupbox({ Side = "Left", Name = "Black Marketer", IconName = "venetian-mask" })
    local WishlistGroup = Tabs.Market:AddGroupbox({ Side = "Left", Name = "Auto buy", IconName = "shopping-cart" })
    local ForecastGroup = Tabs.Market:AddGroupbox({ Side = "Right", Name = "Upcoming visits", IconName = "calendar-clock" })
    local RotatingGroup = Tabs.Market:AddGroupbox({ Side = "Right", Name = "Rotating shops", IconName = "refresh-ccw" })
    local EventsGroup = Tabs.Market:AddGroupbox({ Side = "Right", Name = "Timed events", IconName = "timer" })

    local marketStatusLabel = MarketerGroup:AddLabel("", true)
    local marketStockLabel = MarketerGroup:AddLabel("", true)
    local marketReturnPoint
    MarketerGroup:AddButton({ Text = "Teleport to Black Marketer", Func = function()
        local root = getRoot()
        local stateNow = TimedVendor.GetState(MarketerVendor)
        local position = marketerStandPosition(stateNow.Cycle)
        if not root or not position then
            return
        end
        if not stateNow.Active then
            notify("Black Market", "He is away right now; this is where he appears next.", 4)
        end
        marketReturnPoint = marketReturnPoint or root.CFrame
        root.CFrame = CFrame.new(position)
        root.AssemblyLinearVelocity = Vector3.zero
    end })
    MarketerGroup:AddButton({ Text = "Return", Func = function()
        local root = getRoot()
        if root and marketReturnPoint then
            root.CFrame = marketReturnPoint
            root.AssemblyLinearVelocity = Vector3.zero
        end
        marketReturnPoint = nil
    end })
    MarketerGroup:AddToggle("MarketNotify", {
        Text = "Notify when he arrives",
        Default = true,
    })

    WishlistGroup:AddDropdown("MarketWishlist", {
        Searchable = true,
        Text = "Wishlist",
        Values = marketerCatalog(),
        Default = {},
        Multi = true,
        Tooltip = "Everything he can stock for Wen. Robux-priced items are never listed or bought.",
    })
    WishlistGroup:AddToggle("MarketAutoBuy", {
        Text = "Auto buy wishlist",
        Default = false,
        Tooltip = "When he is in town with a wishlist item, teleports to him, buys it once per visit, and returns you.",
    })
    local wishlistLabel = WishlistGroup:AddLabel("", true)

    local forecastLabel = ForecastGroup:AddLabel("", true)
    local rotatingLabel = RotatingGroup:AddLabel("", true)
    local eventsLabel = EventsGroup:AddLabel("", true)

    function refreshMarket()
        -- Calling into the game's own modules (TimedVendor, RotatingShop, Shop) strips this
        -- thread's UI capability even though getthreadidentity() still reports 8, so every
        -- label text is computed first and written after a single elevate().
        local pending = {}
        local stateNow = TimedVendor.GetState(MarketerVendor)
        local every = TimedVendor.GetEvery(MarketerVendor)

        if stateNow.Active then
            local position = marketerStandPosition(stateNow.Cycle)
            local root = getRoot()
            local distance = root and position and (position - root.Position).Magnitude or 0
            pending[marketStatusLabel] = (string.format("In town now - leaves in %s\n%d studs away", formatDuration(stateNow.NextEdgeIn), math.floor(distance)))
        else
            pending[marketStatusLabel] = (string.format("Away - arrives in %s", formatDuration(stateNow.NextEdgeIn)))
        end

        -- While he is away, show the stock he will bring next.
        local shownCycle = stateNow.Active and stateNow.Cycle or stateNow.Cycle + 1
        local lines = {}
        for _, entry in ipairs(marketerStock(shownCycle)) do
            if not marketerAlways[entryName(entry)] then
                lines[#lines + 1] = describeEntry(entry)
            end
        end
        pending[marketStockLabel] = ((stateNow.Active and "Selling now:\n" or "Next visit brings:\n")
            .. table.concat(lines, "\n") .. "\n+ Frozen Heart ($10,000) and Robux items every visit")

        local forecast = {}
        for offset = 1, MARKET_FORECAST_VISITS do
            local cycle = stateNow.Cycle + offset
            local startsIn = cycle * every - workspace:GetServerTimeNow()
            local names = {}
            for _, entry in ipairs(marketerStock(cycle)) do
                if not marketerAlways[entryName(entry)] then
                    names[#names + 1] = entryName(entry)
                end
            end
            forecast[#forecast + 1] = string.format("In %s: %s", formatDuration(startsIn), table.concat(names, ", "))
        end
        pending[forecastLabel] = (table.concat(forecast, "\n\n"))

        local wanted, wantedCount = selectedValues(Options.MarketWishlist)
        if wantedCount == 0 then
            pending[wishlistLabel] = ("Pick items to see when he next sells them.")
        else
            local found, wishLines = {}, {}
            for offset = stateNow.Active and 0 or 1, MARKET_FORECAST_CYCLES do
                local cycle = stateNow.Cycle + offset
                for _, entry in ipairs(marketerStock(cycle)) do
                    local name = entryName(entry)
                    if wanted[name] and not found[name] then
                        found[name] = cycle
                    end
                end
            end
            for name in pairs(wanted) do
                local cycle = found[name]
                if not cycle then
                    wishLines[#wishLines + 1] = string.format("%s: not within a week", name)
                elseif cycle == stateNow.Cycle and stateNow.Active then
                    wishLines[#wishLines + 1] = string.format("%s: IN STOCK NOW", name)
                else
                    wishLines[#wishLines + 1] = string.format("%s: in %s", name, formatDuration(cycle * every - workspace:GetServerTimeNow()))
                end
            end
            table.sort(wishLines)
            pending[wishlistLabel] = (table.concat(wishLines, "\n"))
        end

        local shopLines = {}
        for _, shop in ipairs(ROTATING_SHOPS) do
            if shop.config then
                local shopEvery = RotatingShop.GetEvery(shop.config)
                local cycle = RotatingShop.GetCycleIndex(shop.config)
                local now, upcoming = {}, {}
                for _, entry in ipairs(RotatingShop.GetRotation(shop.config, cycle)) do
                    local _, priceText = entryPrice(entry)
                    now[#now + 1] = string.format("%s %s", entryName(entry), priceText)
                end
                for _, entry in ipairs(RotatingShop.GetRotation(shop.config, cycle + 1)) do
                    upcoming[#upcoming + 1] = entryName(entry)
                end
                shopLines[#shopLines + 1] = string.format("%s - restock in %s\nNow: %s\nNext: %s",
                    shop.label,
                    formatDuration(shopEvery - workspace:GetServerTimeNow() % shopEvery),
                    table.concat(now, ", "),
                    table.concat(upcoming, ", "))
            end
        end
        pending[rotatingLabel] = (#shopLines > 0 and table.concat(shopLines, "\n\n") or "No rotating shops found.")

        local slot = getSlot()
        local finalSelection = TimedEvents.FinalSelection
        local requirement = finalSelection.Requirements or {}
        local qualifies = slot and slot.Race.Value == requirement.Race and playerLevel() >= (requirement.Level or 0)
        pending[eventsLabel] = (string.format("Final Selection in %s (%s)\nBoss hunt rotation in %s",
            formatDuration(finalSelection.Every - workspace:GetServerTimeNow() % finalSelection.Every),
            qualifies and "you qualify" or string.format("needs %s, Lv %d", tostring(requirement.Race), requirement.Level or 0),
            formatDuration(TimedEvents.BossHunt.Every - workspace:GetServerTimeNow() % TimedEvents.BossHunt.Every)))

        elevate()
        for label, text in pending do
            label:SetText(text)
        end
    end

    task.spawn(function()
        elevate()
        local announcedCycle = nil
        local attempted = {}
        while alive do
            elevate()
            task.wait(MARKET_TICK)
            elevate()
            if not alive then
                break
            end
            local ok, stateNow = pcall(TimedVendor.GetState, MarketerVendor)
            if not ok or not stateNow.Active then
                continue
            end

            local stock = marketerStock(stateNow.Cycle)
            local wanted = selectedValues(Options.MarketWishlist)
            if announcedCycle ~= stateNow.Cycle then
                announcedCycle = stateNow.Cycle
                attempted = {}
                if Toggles.MarketNotify.Value then
                    local hits = {}
                    for _, entry in ipairs(stock) do
                        if wanted[entryName(entry)] then
                            hits[#hits + 1] = entryName(entry)
                        end
                    end
                    notify("Black Market", string.format("The Black Marketer is in town for %s.%s",
                        formatDuration(stateNow.NextEdgeIn),
                        #hits > 0 and ("\nWishlist in stock: " .. table.concat(hits, ", ")) or ""), 8)
                end
            end

            if not Toggles.MarketAutoBuy.Value or lootBusy or state.fishing or state.healing then
                continue
            end
            local targets = {}
            for _, entry in ipairs(stock) do
                local name = entryName(entry)
                local tries = attempted[name]
                if wanted[name] and entryPrice(entry) and not (tries and (tries.done or tries.count >= 3 or os.clock() < tries.nextAt)) then
                    targets[#targets + 1] = name
                end
            end
            if #targets == 0 then
                continue
            end

            visitPosition(marketerStandPosition(stateNow.Cycle), function()
                task.wait(1.5) -- let him stream in before buying
                for _, name in ipairs(targets) do
                    -- Up to 3 tries per item per visit, 20s apart: right after he arrives the
                    -- shop has not registered his stock yet and refuses, so one try missed it.
                    local tries = attempted[name] or { count = 0, nextAt = 0 }
                    attempted[name] = tries
                    tries.count += 1
                    tries.nextAt = os.clock() + 20
                    local bought, why = buyFromShop(name)
                    tries.done = bought
                    if bought or tries.count >= 3 then
                        notify("Black Market", bought and ("Bought " .. name) or string.format("Could not buy %s: %s", name, tostring(why)), 6)
                    end
                end
            end)
        end
    end)
end

do
    local travel = Tabs.Travel:AddGroupbox({ Side = "Left", Name = "NPCs and shops", IconName = "map-pin" })
    local character = Boxes.Character
    local stats = character:AddLabel("Loading character...", true)
    local destinations = {}
    local content = ReplicatedStorage.Ouwland.Content
    for _, region in ipairs(content:GetChildren()) do
        local npcs = region:FindFirstChild("Npcs")
        if npcs then
            for _, npc in ipairs(npcs:GetChildren()) do
                local ok, position = pcall(Regions.GetNpcSpawn, npc.Name)
                if ok and typeof(position) == "Vector3" then
                    destinations[region.Name .. " / " .. npc.Name] = position
                end
            end
        end
    end
    elevate()
    local names = {}
    for name in pairs(destinations) do names[#names + 1] = name end
    table.sort(names)
    travel:AddDropdown("WorldDestination", { Searchable = true, Text = "Destination", Values = names, Default = names[1] })
    local returnPoint
    local function pauseFarms()
        elevate()
        if Toggles.AutoFish then Toggles.AutoFish:SetValue(false) end
        if Toggles.AutoSideQuest then Toggles.AutoSideQuest:SetValue(false) end
        Toggles.AutoFarm:SetValue(false)
        Toggles.AutoBoss:SetValue(false)
        Toggles.AutoQuest:SetValue(false)
        Toggles.AutoChest:SetValue(false)
        if Toggles.AutoYeti then Toggles.AutoYeti:SetValue(false) end
        Toggles.AutoLoot:SetValue(false)
    end
    travel:AddButton({ Text = "Travel to selected NPC", Func = function()
        local position = destinations[Options.WorldDestination.Value]
        if not position then return end
        pauseFarms()
        local root = getRoot()
        if root then
            returnPoint = root.CFrame
            root.CFrame = CFrame.new(position + Vector3.new(0, 3, 5))
            root.AssemblyLinearVelocity = Vector3.zero
        end
    end })
    travel:AddButton({ Text = "Return to previous location", Func = function()
        if not returnPoint then
            notify("Travel", "Travel somewhere first", 3)
            return
        end
        pauseFarms()
        local root = getRoot()
        if root then root.CFrame = returnPoint; root.AssemblyLinearVelocity = Vector3.zero end
        returnPoint = nil
    end })
    travel:AddLabel("Travel pauses combat automation. Shops and quest givers load when you arrive.", true)
    Boxes.Hub:AddButton({ Text = "Stop all automation", Func = function()
        pauseFarms()
        Toggles.AutoSpin:SetValue(false)
    end })
    Boxes.Hub:AddToggle("AntiAfk", {
        Text = "Anti AFK",
        Default = true,
        Tooltip = "Stops Roblox from kicking you after 20 idle minutes.",
    })

    local survival = Tabs.Farm:AddGroupbox({ Side = "Right", Name = "Auto heal", IconName = "heart-pulse" })
    local potionNames = hotbarPotions()
    survival:AddToggle("AutoHeal", {
        Text = "Auto heal",
        Default = false,
        Tooltip = "Drinks a potion from your hotbar when health drops below the threshold. Combat pauses while drinking.",
    })
    survival:AddSlider("HealThreshold", {
        Text = "Heal below",
        Default = 50,
        Min = 10,
        Max = 95,
        Rounding = 0,
        Suffix = "%",
    })
    survival:AddDropdown("HealPotion", {
        Searchable = true,
        Text = "Potion on hotbar",
        Values = potionNames,
        Default = potionNames[1] or "",
        Multi = false,
    })
    survival:AddButton({ Text = "Refresh potions", Func = function()
        local names = hotbarPotions()
        Options.HealPotion:SetValues(names)
        if not table.find(names, Options.HealPotion.Value) then
            Options.HealPotion:SetValue(names[1])
        end
        notify("Auto Heal", string.format("%d health potion(s) on the hotbar", #names), 3)
    end })
    survival:AddLabel("Put a Health Potion or Elixir on your hotbar. Paused while fishing.", true)
    task.spawn(function()
        while alive do
            elevate()
            local slot = getSlot()
            elevate()
            if not alive then break end
            if slot then
                local clan = getClanName()
                local text = string.format("Level %d  |  %s\nClan: %s (%s)\nWen: %s\nReputation: %s\nSkill points: %s",
                    playerLevel(), slot.Race.Value, clan, tierNameOf(clan), tostring(slot.Wen.Value),
                    tostring(slot.Reputation.Value), tostring(slot.SkillPoints.Value))
                elevate()
                stats:SetText(text)
            end
            task.wait(1)
        end
    end)
end

local cleanupFishing
do
    local group = Tabs.Fishing:AddGroupbox({ Side = "Left", Name = "Auto fishing", IconName = "fish" })
    local progress = Tabs.Fishing:AddGroupbox({ Side = "Right", Name = "Catch log", IconName = "list" })
    local statusLabel = progress:AddLabel("Idle", true)
    local catchLabel = progress:AddLabel("Items caught this session: 0", true)
    local rodSlots = {}
    local session = 0
    local fishingSlot
    local caught = 0
    local function status(text)
        state.fishingStatus = text
        if alive then
            elevate()
            statusLabel:SetText(text)
        end
    end
    local function rods()
        table.clear(rodSlots)
        local slot = getSlot()
        local inventory = slot and slot:FindFirstChild("Inventory")
        local owned = inventory and inventory:FindFirstChild("Inventory")
        local toolbar = inventory and inventory:FindFirstChild("Toolbar")
        local names = {}
        if owned and toolbar then
            for _, item in ipairs(owned:GetChildren()) do
                local definition = Items[item.Name]
                local id = item:FindFirstChild("Id")
                if definition and definition.ToolScript == "Rare Fishing Rod" and id then
                    for index, key in ipairs(TOOLBAR_SLOTS) do
                        local entry = toolbar:FindFirstChild(key)
                        if entry and entry.Value == id.Value then
                            rodSlots[item.Name] = index
                            names[#names + 1] = item.Name
                            break
                        end
                    end
                end
            end
        end
        table.sort(names)
        elevate()
        return names
    end
    local function pauseCombat()
        elevate()
        Toggles.AutoFarm:SetValue(false)
        Toggles.AutoBoss:SetValue(false)
        Toggles.AutoQuest:SetValue(false)
        Toggles.AutoChest:SetValue(false)
        if Toggles.AutoYeti then Toggles.AutoYeti:SetValue(false) end
    end
    group:AddDropdown("FishingRod", { Searchable = true, Text = "Rod on hotbar", Values = rods(), Default = 1 })
    group:AddButton({ Text = "Refresh rods", Func = function()
        local names = rods()
        Options.FishingRod:SetValues(names)
        if not rodSlots[Options.FishingRod.Value] then Options.FishingRod:SetValue(names[1]) end
    end })
    group:AddToggle("InstantReel", {
        Text = "Instant reel",
        Default = true,
        Tooltip = "Reports a won reel minigame straight to the server instead of playing it.",
    })
    group:AddToggle("AutoFish", { Text = "Auto fishing", Default = false })
    group:AddButton({ Text = "Travel to fishing dock", Func = function()
        Toggles.AutoFish:SetValue(false)
        pauseCombat()
        local ok, position = pcall(Regions.GetNpcSpawn, "Fisherman Jeso")
        local root = getRoot()
        if ok and typeof(position) == "Vector3" and root then
            root.CFrame = CFrame.new(position + Vector3.new(0, 3, 5))
            root.AssemblyLinearVelocity = Vector3.zero
            status("At the dock. Enable auto fishing when standing on the ground.")
        else
            status("Fishing dock is unavailable in this place.")
        end
    end })
    group:AddLabel("Uses your equipped bait, if any. Stand beside water with a rod on your hotbar. Catches are collected into your inventory.", true)

    local function inventoryCounts()
        local slot = getSlot()
        local inventory = slot and slot:FindFirstChild("Inventory")
        local owned = inventory and inventory:FindFirstChild("Inventory")
        local counts = {}
        if owned then
            for _, item in ipairs(owned:GetChildren()) do
                local amount = item:FindFirstChild("Amount")
                counts[item.Name] = amount and amount.Value or 1
            end
        end
        return counts
    end
    local function gainsSince(before)
        local gains, total = {}, 0
        for name, amount in pairs(inventoryCounts()) do
            local gain = amount - (before[name] or 0)
            if gain > 0 then
                total += gain
                gains[#gains + 1] = string.format("%s x%d", name, gain)
            end
        end
        table.sort(gains)
        return gains, total
    end
    local PortalEvent = ReplicatedStorage.CAM.Global.ServerClientPortal:WaitForChild("Event")
    local portalConnection
    local biteToken, biteMissed
    local function onPortal(channel, kind, token)
        if channel ~= "FishingRod" then return end
        if kind == "Bite" then
            biteToken = token
        elseif kind == "BiteMissed" then
            biteMissed = true
        end
    end
    local function closeBiteUi()
        -- BiteCancel tears the minigame down without it reporting a verdict, so it cannot overwrite the win.
        if not getconnections then return end
        for _, connection in ipairs(getconnections(PortalEvent.OnClientEvent)) do
            if connection.Function then
                pcall(connection.Function, "FishingRod", "BiteCancel")
            end
        end
    end
    local function newCatch(root, existing)
        local debree = workspace:FindFirstChild("Debree")
        local best, bestPrompt, bestDistance
        for _, model in ipairs(debree and debree:GetChildren() or {}) do
            if not existing[model] and model:GetAttribute("CatchItem") then
                local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
                local part = prompt and prompt.Parent
                if part and part:IsA("BasePart") then
                    local distance = (part.Position - root.Position).Magnitude
                    if not bestDistance or distance < bestDistance then
                        best, bestPrompt, bestDistance = model, prompt, distance
                    end
                end
            end
        end
        return best, bestPrompt, bestDistance
    end
    local function catchSnapshot()
        local debree = workspace:FindFirstChild("Debree")
        local existing = {}
        for _, model in ipairs(debree and debree:GetChildren() or {}) do
            existing[model] = true
        end
        return existing
    end
    local function waterTarget(root, char)
        local water = RaycastParams.new()
        water.FilterType = Enum.RaycastFilterType.Include
        water.BruteForceAllSlow = true
        local parts = {}
        for _, part in ipairs(game:GetService("CollectionService"):GetTagged("SwimParts")) do
            parts[#parts + 1] = part.Parent or part
        end
        water.FilterDescendantsInstances = parts
        local ground = RaycastParams.new()
        ground.FilterType = Enum.RaycastFilterType.Exclude
        local excluded = { char }
        local debree = workspace:FindFirstChild("Debree")
        if debree then excluded[#excluded + 1] = debree end
        ground.FilterDescendantsInstances = excluded
        for radius = 8, 32, 4 do
            for index = 0, 15 do
                local angle = index * math.pi / 8
                local origin = root.Position + Vector3.new(math.cos(angle) * radius, 50, math.sin(angle) * radius)
                local direction = Vector3.new(0, -150, 0)
                local hit = workspace:Raycast(origin, direction, water)
                local obstruction = workspace:Raycast(origin, direction, ground)
                if hit and (hit.Instance.Name == "Texture" or hit.Instance.Name == "TouchPart")
                    and (not obstruction or obstruction.Position.Y <= hit.Position.Y + 0.1) then
                    return hit.Position
                end
            end
        end
        return nil
    end
    local function active(token)
        return alive and session == token and Toggles.AutoFish and Toggles.AutoFish.Value
    end
    local function waitActive(seconds, token)
        local deadline = os.clock() + seconds
        repeat
            task.wait(0.05)
            if not active(token) then return false end
        until os.clock() >= deadline
        return true
    end
    local function reel(token)
        local lastY, lastTime, held, currentGui
        local deadline = os.clock() + 45
        while active(token) and LocalPlayer:GetAttribute("FishingBite") do
            if os.clock() >= deadline then return false, "Reeling timed out" end
            local misc = LocalPlayer.PlayerGui:FindFirstChild("Misc")
            local tracker = misc and misc:FindFirstChild("tracker", true)
            local bar = tracker and tracker.Parent:FindFirstChild("Bar")
            if bar then
                local gui = tracker:FindFirstAncestorOfClass("CanvasGroup")
                if currentGui ~= gui then lastY, lastTime, held = nil, nil, nil; currentGui = gui end
                local now = os.clock()
                local y = bar.AbsolutePosition.Y + bar.AbsoluteSize.Y / 2
                local target = tracker.AbsolutePosition.Y + tracker.AbsoluteSize.Y / 2
                local velocity = lastY and (y - lastY) / math.max(now - lastTime, 0.001) or 0
                local press = y + velocity * 0.18 > target
                if gui and press ~= held then
                    local invoked = false
                    for _, connection in ipairs(getconnections(press and gui.InputBegan or gui.InputEnded)) do
                        if connection.Function then
                            connection.Function({ UserInputType = Enum.UserInputType.MouseButton1 })
                            invoked = true
                        end
                    end
                    if not invoked then return false, "Fishing input handler is unavailable" end
                    held = press
                end
                lastY, lastTime = y, now
            end
            task.wait(0.025)
        end
        return active(token)
    end
    local function collectCatch(root, existing, token)
        -- A won bite hangs the catch off the rod tip behind a 2s "Collect" prompt.
        -- Recasting or unequipping before it is collected drops it on the ground to despawn.
        local model, prompt, distance
        local deadline = os.clock() + 3
        repeat
            if not waitActive(0.1, token) or biteMissed then return nil end
            model, prompt, distance = newCatch(root, existing)
        until model or os.clock() >= deadline
        if not model then return nil end
        local item = tostring(model:GetAttribute("CatchItem"))
        status(string.format("Pulling in %s...", item))
        deadline = os.clock() + 6
        while distance > prompt.MaxActivationDistance - 1 and os.clock() < deadline do
            if not waitActive(0.1, token) or not model.Parent then return false, item end
            distance = (prompt.Parent.Position - root.Position).Magnitude
        end
        status(string.format("Collecting %s...", item))
        if fireproximityprompt then
            pcall(fireproximityprompt, prompt)
            deadline = os.clock() + 1
            while model.Parent and os.clock() < deadline do
                if not waitActive(0.1, token) then return false, item end
            end
        end
        if model.Parent then
            pcall(prompt.InputHoldBegin, prompt)
            local held = waitActive(prompt.HoldDuration + 0.3, token)
            pcall(prompt.InputHoldEnd, prompt)
            if not held then return false, item end
            deadline = os.clock() + 1.5
            while model.Parent and os.clock() < deadline do
                task.wait(0.1)
            end
        end
        return model.Parent == nil, item
    end
    local function fishOnce(token)
        local root, char = getRoot()
        local humanoid = char and char:FindFirstChildOfClass("Humanoid")
        if not root or not humanoid or humanoid.Health <= 0 then return false, "Character is not ready" end
        -- Landing a catch can leave you airborne for a moment; only give up if you stay off the ground.
        local groundDeadline = os.clock() + 3
        while humanoid.FloorMaterial == Enum.Material.Air or (char:GetAttribute("SwimState") or 0) > 0 do
            if os.clock() >= groundDeadline then
                return false, "Stand on the dock or shore before fishing"
            end
            if not waitActive(0.2, token) then return false end
        end
        rods()
        local index = rodSlots[Options.FishingRod.Value]
        if not index then return false, "Put a fishing rod on your hotbar, then refresh rods" end
        local target = waterTarget(root, char)
        if not target then return false, "No open water nearby. Use Travel to fishing dock" end
        local before = inventoryCounts()
        if not active(token) then return false end
        local equipped = LocalPlayer.Items_Config.Equipped
        -- Unequipping clears the previous line and catch presentation before recasting.
        -- Right after a catch the server is still uncasting and reverts the equip, so retry.
        fishingSlot = index
        for _ = 1, 4 do
            equipped.Value = 0
            if not waitActive(0.7, token) then return false end
            equipped.Value = index
            if not waitActive(0.8, token) then return false end
            if equipped.Value == index then break end
        end
        if equipped.Value ~= index then return false, "The game refused to equip the selected rod" end
        local instant = Toggles.InstantReel.Value
        local function bitten()
            if instant then return biteToken ~= nil end
            return LocalPlayer:GetAttribute("FishingBite") == true
        end
        biteToken, biteMissed = nil, nil
        status("Casting...")
        SignalEvent.ToServer("Tool_Mouse", "Up", target)
        status("Waiting for a bite...")
        local deadline = os.clock() + 30
        repeat
            if not waitActive(0.1, token) then return false end
        until bitten() or os.clock() >= deadline
        if not bitten() then return false, "No bite received. Move closer to open water and retry" end
        local existing = catchSnapshot()
        status("Reeling...")
        if instant then
            -- The server takes the client's minigame verdict as-is.
            PortalEvent:FireServer("FishingRod", biteToken, true)
            local shown = os.clock() + 1
            repeat
                if not waitActive(0.05, token) then return false end
            until LocalPlayer:GetAttribute("FishingBite") or os.clock() >= shown
            closeBiteUi()
        else
            local ok, why = reel(token)
            if not ok then return false, why end
        end
        local collected, item = collectCatch(root, existing, token)
        if not active(token) then return false end
        local gains, total = gainsSince(before)
        deadline = os.clock() + (collected and 2 or 0)
        while total == 0 and os.clock() < deadline do
            if not waitActive(0.1, token) then return false end
            gains, total = gainsSince(before)
        end
        caught += total
        local outcome
        if total > 0 then
            outcome = table.concat(gains, ", ")
        elseif biteMissed then
            outcome = "The fish got away"
        elseif item then
            outcome = string.format("Could not collect %s", item)
        else
            outcome = "Nothing on the line"
        end
        elevate()
        catchLabel:SetText(string.format("Items caught this session: %d\nLast attempt: %s", caught, outcome))
        state.fishingCaught = caught
        return true
    end
    cleanupFishing = function()
        session += 1
        local config = LocalPlayer:FindFirstChild("Items_Config")
        local equipped = config and config:FindFirstChild("Equipped")
        if equipped and fishingSlot and (equipped.Value == fishingSlot or equipped.Value == 0) then
            equipped.Value = 0
        end
        fishingSlot = nil
        state.fishing = false
        if portalConnection then
            portalConnection:Disconnect()
            portalConnection = nil
        end
    end
    Toggles.AutoFish:OnChanged(function()
        elevate()
        if not Toggles.AutoFish.Value then
            cleanupFishing()
            status("Stopped")
            return
        end
        pauseCombat()
        session += 1
        local token = session
        state.fishing = true
        if portalConnection then portalConnection:Disconnect() end
        portalConnection = PortalEvent.OnClientEvent:Connect(onPortal)
        task.spawn(function()
            while active(token) do
                elevate()
                local success, ok, why = pcall(fishOnce, token)
                if not active(token) then break end
                if not success or not ok then
                    elevate()
                    Toggles.AutoFish:SetValue(false)
                    status(tostring(success and why or ok))
                    break
                end
            end
        end)
    end)
end

--// Side quests: Dialogue and Fishing quests, finished through the game's own progress remote.
--// Every task type reports with ("QuestProgress", questKey, taskName[, pickupIndex]) and the
--// server only checks that the character is standing in the right place: at the deposit spot,
--// the pickup spot, or in front of the NPC for a hand-in. Accepting still needs the giver's
--// prompt fired first. Scoped in its own block: the main chunk is near Luau's 200-local limit.
local refreshSideQuests
do
    local SIDE_TICK = 0.5
    local SIDE_ROWS = 9
    local DEPOSIT_INTERVAL = 0.2 -- the game's own deposit loop runs every 0.15s
    local NPC_SPAWN_WAIT = 2
    local FISH_STALL = 480
    local FISH_DOCK_NPC = "Fisherman Jeso"
    local SUPPORTED = { Deposit = true, Deliver = true, Pickup = true }

    local ItemSources
    pcall(function()
        ItemSources = require(ReplicatedStorage.CAM.Client.Modules.ItemSources)
    end)

    -- Every NPC's definition by display name. Wandering NPCs (like Estate Worker Niko) walk
    -- between their Spawns, so a single spawn point is not enough to find them.
    local npcDefs, sellerOf = {}, {}
    for _, region in ipairs(ReplicatedStorage.Ouwland.Content:GetChildren()) do
        local npcs = region:FindFirstChild("Npcs")
        for _, module in ipairs(npcs and npcs:GetChildren() or {}) do
            if module:IsA("ModuleScript") then
                local ok, definition = pcall(require, module)
                if ok and type(definition) == "table" and type(definition.Name) == "string" then
                    npcDefs[definition.Name] = definition
                    if type(definition.Shop) == "table" then
                        for item in pairs(definition.Shop) do
                            sellerOf[item] = sellerOf[item] or definition.Name
                        end
                    end
                end
            end
        end
    end
    elevate()

    local Side = {
        hold = nil, -- function returning the CFrame to pin the character to, or nil
        home = nil,
        active = {}, -- quest keys seen active last tick, to notice hand-ins
        fishing = false,
        finished = 0,
        status = "Idle",
        blocked = {}, -- quest key -> why it cannot progress, so the picker skips it
        tried = {}, -- pickup slots already attempted
    }

    function Side.on()
        return alive and Toggles.AutoSideQuest ~= nil and Toggles.AutoSideQuest.Value
    end

    -- Only pins while the runner is on, so a step still unwinding after a stop cannot hold you.
    Library:GiveSignal(RunService.Heartbeat:Connect(function()
        local target = Side.on() and Side.hold and Side.hold()
        local root = target and getRoot()
        if root then
            root.CFrame = target
            root.AssemblyLinearVelocity = Vector3.zero
        end
    end))

    -- Waits while the runner stays on; false means it was switched off meanwhile.
    function Side.wait(seconds)
        local deadline = os.clock() + seconds
        repeat
            task.wait(0.1)
        until not Side.on() or os.clock() >= deadline
        elevate()
        return Side.on()
    end

    function Side.waitFor(done, seconds)
        local deadline = os.clock() + seconds
        while not done() do
            if os.clock() >= deadline or not Side.wait(0.1) then
                return false
            end
        end
        return true
    end

    function Side.npcModel(name)
        local regions = workspace.Debree:FindFirstChild("Regions")
        for _, region in ipairs(regions and regions:GetChildren() or {}) do
            local stationary = region:FindFirstChild("StationaryNpcs")
            local model = stationary and stationary:FindFirstChild(name)
            if model and model:IsA("Model") then
                return model
            end
        end
        return nil
    end

    function Side.goTo(position)
        local target = CFrame.new(position + Vector3.new(0, 3, 0))
        Side.hold = function()
            return target
        end
        return Side.wait(1)
    end

    -- Stands in front of an NPC and follows it if it wanders. Returns the model or nil.
    -- Only streamed-in NPCs exist on the client, so walk its spawn points until it loads,
    -- starting where it was last seen: a wanderer is usually still near there.
    Side.lastSeen = {}
    function Side.goToNpc(name)
        local model = Side.npcModel(name)
        local definition = npcDefs[name]
        local points = {}
        for _, spawn in ipairs(definition and definition.Spawns or {}) do
            spawn = type(spawn) == "table" and spawn[1] or spawn -- route lists hold their points
            local position = typeof(spawn) == "CFrame" and spawn.Position or spawn
            if typeof(position) == "Vector3" then
                points[#points + 1] = position
            end
        end
        local seen = Side.lastSeen[name]
        if seen then
            table.sort(points, function(a, b)
                return (a - seen).Magnitude < (b - seen).Magnitude
            end)
            table.insert(points, 1, seen)
        end
        local index = 0
        while not model and index < #points do
            index += 1
            Side.goTo(points[index] + Vector3.new(0, 1, 0))
            local deadline = os.clock() + NPC_SPAWN_WAIT
            repeat
                if not Side.wait(0.2) then
                    return nil
                end
                model = Side.npcModel(name)
            until model or os.clock() >= deadline
        end
        if not model then
            return nil
        end
        Side.hold = function()
            if not model.Parent then
                return nil
            end
            local pivot = model:GetPivot()
            Side.lastSeen[name] = pivot.Position
            return CFrame.lookAt((pivot * CFrame.new(0, 0, -4)).Position, pivot.Position)
        end
        Side.wait(0.8)
        return model
    end

    function Side.taskFolder(quest, taskName)
        local tasks = quest.folder:FindFirstChild("Tasks")
        return tasks and tasks:FindFirstChild(taskName)
    end

    -- Task rows for an active quest, or zeroed rows from the template before accepting.
    function Side.tasksOf(definition, quest)
        if quest then
            return quest.tasks
        end
        local list = {}
        for _, task in ipairs(definition.QuestInstance.Tasks:GetChildren()) do
            local max = task:FindFirstChild("Max")
            list[#list + 1] = { name = task.Name, value = 0, max = max and max.Value or 1 }
        end
        return list
    end

    -- A task is ready once every task its marker lists under After (and its Need) is complete.
    function Side.ready(definition, quest, taskName)
        local marker = definition.Markers and definition.Markers[taskName]
        local before = marker and marker.After or {}
        local folder = Side.taskFolder(quest, taskName)
        local need = folder and folder:FindFirstChild("Need")
        if need and need.Value ~= "" then
            before = table.clone(before)
            before[#before + 1] = need.Value
        end
        for _, name in ipairs(before) do
            for _, task in ipairs(quest.tasks) do
                if task.name == name and task.value < task.max then
                    return false
                end
            end
        end
        return true
    end

    -- Next unfinished, ready task: pickups and deposits you can make first, hand-ins last.
    function Side.nextTask(definition, quest)
        local specs = definition.TaskSpecs or {}
        local best, bestScore
        for _, task in ipairs(quest.tasks) do
            if task.value < task.max and Side.ready(definition, quest, task.name) then
                local spec = specs[task.name]
                local kind = spec and spec.Type
                local score = 1
                if kind == "Pickup" or (kind == "Deposit" and itemCount(spec.RequiredItem) > 0) then
                    score = 3
                elseif kind ~= "Deliver" then
                    score = 2
                end
                if not bestScore or score > bestScore then
                    best, bestScore = { task = task, spec = spec }, score
                end
            end
        end
        return best
    end

    -- Items the unfinished tasks still need beyond what you hold, as { [item] = count }.
    function Side.missing(definition, quest)
        local need = {}
        local specs = definition.TaskSpecs or {}
        local tasks = Side.tasksOf(definition, quest)
        local hasPickup = false
        for _, task in ipairs(tasks) do
            hasPickup = hasPickup or (specs[task.name] and specs[task.name].Type == "Pickup") or false
        end
        for _, task in ipairs(tasks) do
            local spec = specs[task.name]
            local item = spec and spec.RequiredItem
            if item and task.value < task.max then
                if spec.Type == "Deposit" then
                    need[item] = (need[item] or 0) + (task.max - task.value)
                elseif spec.Type == "Deliver" and not (quest == nil and item == definition.GrantItemOnAccept) and not hasPickup then
                    -- Items handed over on accept, or found by the quest's own pickup, come for free.
                    need[item] = math.max(need[item] or 0, spec.Count or 1)
                end
            end
        end
        local short = {}
        for item, count in pairs(need) do
            local have = itemCount(item)
            if have < count then
                short[item] = count - have
            end
        end
        return short
    end

    -- How the runner can get an item: "buy", "fish" or nil, plus a hint for the player.
    function Side.source(item)
        local listing = Shop.itemsforsale[item]
        local price = listing and listing.Price
        if sellerOf[item] and typeof(price) == "table" and not price.Product and not price.Gamepass then
            return "buy", string.format("sold by %s", sellerOf[item])
        end
        local definition = Items[item]
        if type(definition) == "table" and definition.Category == "Fishing" then
            return "fish", "fished up"
        end
        local ok, sources = pcall(function()
            return ItemSources and ItemSources.Get(item)
        end)
        elevate()
        local where = ok and type(sources) == "table" and sources[1] and sources[1].Where
        return nil, where and tostring(where) or "no known source"
    end

    -- How many the player can pay for now. Wen or material prices only, never Robux.
    function Side.affordable(item)
        local listing = Shop.itemsforsale[item]
        local price = listing and listing.Price
        if typeof(price) ~= "table" or price.Product or price.Gamepass then
            return 0
        end
        local slot = getSlot()
        local count = math.huge
        for currency, cost in pairs(price) do
            if type(cost) ~= "number" or cost <= 0 then
                return 0
            end
            local have = currency == "Wen" and (slot and slot:FindFirstChild("Wen") and slot.Wen.Value or 0) or itemCount(currency)
            count = math.min(count, math.floor(have / cost))
        end
        return count == math.huge and 0 or count
    end

    function Side.questName(key)
        local definition = Quests.Holder[key]
        return definition and tostring(definition.QuestInstance) or tostring(key)
    end

    -- Whether the runner can take this quest and finish it with what you have or can get.
    function Side.finishable(key)
        local definition = Quests.Holder[key]
        if not definition or definition.ItemCostOnAccept or definition.WenCostOnAccept then
            return false, "costs something to accept"
        end
        for _, quest in ipairs(activeQuests("side")) do
            local other = Quests.Holder[quest.key]
            if other and other.Category == definition.Category then
                return false, string.format("you already have a %s quest", tostring(definition.Category))
            end
        end
        for _, task in ipairs(definition.QuestInstance.Tasks:GetChildren()) do
            local spec = definition.TaskSpecs and definition.TaskSpecs[task.Name]
            if not spec or not SUPPORTED[spec.Type] then
                return false, string.format("'%s' has to be done by hand", task.Name)
            end
        end
        for item, count in pairs(Side.missing(definition, nil)) do
            local how, hint = Side.source(item)
            if how == "fish" then
                if not Toggles.SideQuestFish.Value then
                    return false, string.format("needs %d %s (turn on Fish for missing fish)", count, item)
                end
            elseif how == "buy" then
                if not Toggles.SideQuestBuy.Value then
                    return false, string.format("needs %d %s (%s; turn on Buy missing items)", count, item, hint)
                elseif Side.affordable(item) < count then
                    return false, string.format("needs %d %s, you can afford %d", count, item, Side.affordable(item))
                end
            else
                return false, string.format("needs %d %s (%s)", count, item, hint)
            end
        end
        return true
    end

    -- Undoes everything the runner holds: position pin, loot lock, its own fishing, and returns home.
    function Side.release()
        Side.hold = nil
        lootBusy = false
        if Side.fishing then
            Side.fishing = false
            if Toggles.AutoFish and Toggles.AutoFish.Value then
                Toggles.AutoFish:SetValue(false)
            end
        end
        local root = getRoot()
        if root and Side.home then
            root.CFrame = Side.home
            root.AssemblyLinearVelocity = Vector3.zero
        end
        Side.home = nil
    end

    function Side.stop(message)
        if Toggles.AutoSideQuest and Toggles.AutoSideQuest.Value then
            Toggles.AutoSideQuest:SetValue(false) -- its OnChanged runs Side.release()
        end
        Side.release()
        if message then
            Side.status = message
            notify("Side Quests", message, 8)
        end
    end

    function Side.block(key, why)
        Side.blocked[key] = why
        Side.status = why
        notify("Side Quests", why, 8)
    end

    function Side.accept(key)
        local definition = Quests.Holder[key]
        Side.status = string.format("Going to %s for %s...", tostring(definition.OfferNpc), Side.questName(key))
        local model = Side.goToNpc(tostring(definition.OfferNpc))
        if not model then
            return false, string.format("could not find %s", tostring(definition.OfferNpc))
        end
        -- The server ignores AddQuest unless the giver's dialogue was opened first.
        local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
        if prompt then
            pcall(fireproximityprompt, prompt)
        end
        Side.wait(0.5)
        SignalEvent.ToServer("AddQuest", key)
        Side.waitFor(function()
            return Quests.GetPlayerQuestState(LocalPlayer, key) == "Doing"
        end, 3)
        elevate()
        if Quests.GetPlayerQuestState(LocalPlayer, key) ~= "Doing" then
            return false, string.format("%s would not hand it over", tostring(definition.OfferNpc))
        end
        return true
    end

    function Side.buy(item, amount)
        if not Side.goToNpc(sellerOf[item]) then
            return 0
        end
        local before = itemCount(item)
        local checked, allowed = pcall(Shop.CanBuy, LocalPlayer, item, nil, amount)
        elevate()
        if checked and not allowed then
            return 0
        end
        SignalEvent.ToServer("PurchaseFromShop", item, amount)
        Side.waitFor(function()
            return itemCount(item) >= before + amount
        end, 3)
        -- Fall back to single purchases if the shop only honours one at a time.
        while Side.on() and itemCount(item) < before + amount and itemCount(item) > before do
            local now = itemCount(item)
            SignalEvent.ToServer("PurchaseFromShop", item, 1)
            if not Side.waitFor(function()
                return itemCount(item) > now
            end, 3) then
                break
            end
        end
        return itemCount(item) - before
    end

    function Side.deposit(definition, quest, spec)
        if not Side.goTo(spec.Position + Vector3.new(0, 0, 3)) then
            return true
        end
        for _, task in ipairs(quest.tasks) do
            local other = definition.TaskSpecs[task.name]
            local folder = Side.taskFolder(quest, task.name)
            if other and other.Type == "Deposit" and folder and (other.Position - spec.Position).Magnitude < 1
                and Side.ready(definition, quest, task.name) then
                local refused = 0
                while Side.on() and folder.Parent and folder.Value.Value < folder.Max.Value and itemCount(other.RequiredItem) > 0 do
                    local before = folder.Value.Value
                    SignalEvent.ToServer("QuestProgress", quest.key, task.name)
                    if not Side.waitFor(function()
                        return not folder.Parent or folder.Value.Value > before
                    end, 1.5) then
                        refused += 1
                        if refused >= 3 then
                            return false, string.format("The server refused to stock %s", other.RequiredItem)
                        end
                    end
                    Side.wait(DEPOSIT_INTERVAL)
                end
            end
        end
        return true
    end

    function Side.deliver(quest, taskName, spec)
        local model = Side.goToNpc(spec.TargetNpc)
        if not model then
            return false, string.format("Could not find %s", spec.TargetNpc)
        end
        local folder = Side.taskFolder(quest, taskName)
        for _ = 1, 2 do
            SignalEvent.ToServer("QuestProgress", quest.key, taskName)
            if Side.waitFor(function()
                return not folder or not folder.Parent or folder.Value.Value >= folder.Max.Value
            end, 2.5) then
                return true
            end
            -- Fall back to opening the dialogue, in case a hand-in only counts from there.
            local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
            if prompt then
                pcall(fireproximityprompt, prompt)
                Side.wait(0.5)
            end
        end
        return false, string.format("%s did not take the hand-in", spec.TargetNpc)
    end

    function Side.pickup(quest, taskName, spec)
        local folder = Side.taskFolder(quest, taskName)
        local positions = spec.Positions
        local count = type(positions) == "table" and #positions or spec.SpawnCount or 1
        local progressed = false
        for index = 1, count do
            if not Side.on() or not folder or not folder.Parent or folder.Value.Value >= folder.Max.Value then
                break
            end
            local slotKey = string.format("%s/%s/%d", quest.key, taskName, index)
            local position = type(positions) == "table" and positions[index] or nil
            if type(positions) == "function" then
                local ok, result = pcall(positions, index)
                position = ok and result or nil
            end
            if typeof(position) == "Vector3" and not Side.tried[slotKey] then
                Side.tried[slotKey] = true
                Side.goTo(position)
                local before = folder.Value.Value
                SignalEvent.ToServer("QuestProgress", quest.key, taskName, index)
                if Side.waitFor(function()
                    return not folder.Parent or folder.Value.Value > before
                end, 1.5) then
                    progressed = true
                end
            end
        end
        if not progressed and spec.RespawnTime ~= nil then
            -- Respawning pickups come back; forget the attempts and try again later.
            for slotKey in pairs(Side.tried) do
                if string.find(slotKey, quest.key .. "/" .. taskName, 1, true) == 1 then
                    Side.tried[slotKey] = nil
                end
            end
            return true
        end
        return progressed
    end

    function Side.startFishing(quest)
        local ok, position = pcall(Regions.GetNpcSpawn, FISH_DOCK_NPC)
        elevate()
        if not ok or typeof(position) ~= "Vector3" then
            return Side.block(quest.key, "The fishing dock is not in this place")
        end
        Side.hold = nil
        local root = getRoot()
        if root then
            root.CFrame = CFrame.new(position + Vector3.new(0, 3, 5))
            root.AssemblyLinearVelocity = Vector3.zero
        end
        -- Auto fishing refuses to cast mid-air, so land first.
        Side.waitFor(function()
            local _, char = getRoot()
            local humanoid = char and char:FindFirstChildOfClass("Humanoid")
            return humanoid ~= nil and humanoid.FloorMaterial ~= Enum.Material.Air
        end, 5)
        if not Side.on() then
            return
        end
        Side.fishing = true
        Side.fishQuest = quest.key
        Side.fishLeft = nil
        Side.fishSince = os.clock()
        Toggles.AutoFish:SetValue(true)
    end

    function Side.watchFishing()
        local quest
        for _, active in ipairs(activeQuests("side")) do
            if active.key == Side.fishQuest then
                quest = active
            end
        end
        local definition = quest and Quests.Holder[quest.key]
        local left, parts = 0, {}
        for item, count in pairs(definition and Side.missing(definition, quest) or {}) do
            if type(Items[item]) == "table" and Items[item].Category == "Fishing" then
                left += count
                parts[#parts + 1] = string.format("%d %s", count, item)
            end
        end
        if left == 0 then
            Side.fishing = false
            if Toggles.AutoFish.Value then
                Toggles.AutoFish:SetValue(false)
            end
            Side.status = "Got the fish, going to stock them..."
            return
        end
        if not Toggles.AutoFish.Value then
            -- Auto fishing gave up (knocked off the dock, a refused equip...). Restart from the
            -- dock a few times before calling the quest blocked.
            Side.fishing = false
            Side.fishRetries = (Side.fishRetries or 0) + 1
            if Side.fishRetries <= 3 then
                Side.status = "Fishing stopped, restarting from the dock..."
                return Side.startFishing(quest)
            end
            return Side.block(quest.key, "Auto fishing stopped: " .. tostring(state.fishingStatus))
        end
        if not Side.fishLeft or left < Side.fishLeft then
            Side.fishRetries = 0
            Side.fishLeft, Side.fishSince = left, os.clock()
        elseif os.clock() - Side.fishSince > FISH_STALL then
            Side.fishing = false
            Toggles.AutoFish:SetValue(false)
            return Side.block(quest.key, string.format("No %s in %d minutes - your rod may not reach it",
                table.concat(parts, ", "), FISH_STALL // 60))
        end
        table.sort(parts)
        Side.status = "Fishing for " .. table.concat(parts, ", ")
    end

    -- Gets whatever the quest is short of: buys it, or goes fishing, or explains why it can't.
    function Side.acquire(definition, quest)
        local fishing = false
        for item, count in pairs(Side.missing(definition, quest)) do
            local how, hint = Side.source(item)
            if how == "buy" and Toggles.SideQuestBuy.Value and Side.affordable(item) >= count then
                Side.status = string.format("Buying %d %s from %s...", count, item, sellerOf[item])
                local got = Side.buy(item, count)
                if got < count and Side.on() then
                    return Side.block(quest.key, string.format("Bought %d of %d %s - the shop refused the rest", got, count, item))
                end
                return
            elseif how == "fish" and Toggles.SideQuestFish.Value then
                fishing = true
            else
                local reason = hint
                if how == "fish" then
                    reason = "turn on Fish for missing fish"
                elseif how == "buy" then
                    reason = Toggles.SideQuestBuy.Value and string.format("%s, you can afford %d", hint, Side.affordable(item))
                        or string.format("%s - turn on Buy missing items", hint)
                end
                return Side.block(quest.key, string.format("%s needs %d more %s (%s)", Side.questName(quest.key), count, item, reason))
            end
        end
        if fishing then
            return Side.startFishing(quest)
        end
    end

    function Side.work(quest)
        local definition = Quests.Holder[quest.key]
        if not definition then
            return Side.block(quest.key, "Unknown quest " .. tostring(quest.key))
        end
        local pick = Side.nextTask(definition, quest)
        if not pick then
            Side.status = string.format("Turning in %s...", Side.questName(quest.key))
            return
        end
        local task, spec = pick.task, pick.spec
        local kind = spec and spec.Type
        if not SUPPORTED[kind] then
            return Side.block(quest.key, string.format("'%s' has to be done by hand - use Go to current objective", task.name))
        end
        if kind == "Pickup" then
            Side.status = string.format("Picking up %s...", task.name)
            if not Side.pickup(quest, task.name, spec) and Side.on() then
                Side.block(quest.key, string.format("Could not pick up '%s'", task.name))
            end
            return
        end
        if spec.RequiredItem and itemCount(spec.RequiredItem) < (kind == "Deliver" and (spec.Count or 1) or 1) then
            return Side.acquire(definition, quest)
        end
        local ok, why
        if kind == "Deliver" then
            Side.status = string.format("Handing in to %s...", spec.TargetNpc)
            ok, why = Side.deliver(quest, task.name, spec)
        else
            Side.status = string.format("Stocking %s...", spec.RequiredItem)
            ok, why = Side.deposit(definition, quest, spec)
        end
        if not ok and Side.on() then
            Side.block(quest.key, why)
        end
    end

    function Side.pick()
        local labels = eligibleQuestLabels(true)
        Options.SideQuestPick:SetValues(labels)
        local picked = Options.SideQuestPick.Value
        local key = picked ~= BEST_QUEST_LABEL and questKeyByLabel[picked] or nil
        if key then
            if questLockByLabel[picked] then
                return nil, string.format("%s is locked: %s", Side.questName(key), questLockByLabel[picked])
            end
            if Side.blocked[key] then
                return nil, Side.blocked[key]
            end
            local ok, why = Side.finishable(key)
            if not ok then
                return nil, string.format("%s %s", Side.questName(key), why)
            end
            return key
        end
        key = bestQuestKey(true, function(candidate)
            return not Side.blocked[candidate] and (Side.finishable(candidate))
        end)
        return key, key == nil and "Nothing left that the runner can finish with what you have" or nil
    end

    function Side.step()
        if state.healing then
            return
        end
        local quests = activeQuests("side")
        local nowActive = {}
        for _, quest in ipairs(quests) do
            nowActive[quest.key] = true
        end
        for key in pairs(Side.active) do
            if not nowActive[key] then
                local definition = Quests.Holder[key]
                Side.finished += 1
                notify("Side Quests", string.format("Finished %s (+%d exp)", Side.questName(key),
                    definition and questExp(definition) or 0), 6)
                table.clear(Side.tried)
            end
        end
        Side.active = nowActive
        if Side.fishing then
            return Side.watchFishing()
        end

        -- Active quests first, and among them the ones that can move right now: a quick
        -- hand-in should not sit behind a long fishing trip.
        local fallback
        for _, quest in ipairs(quests) do
            local definition = Quests.Holder[quest.key]
            if definition and not Side.blocked[quest.key] then
                local pick = Side.nextTask(definition, quest)
                local spec = pick and pick.spec
                local short = spec and spec.RequiredItem and spec.Type ~= "Pickup"
                    and itemCount(spec.RequiredItem) < (spec.Type == "Deliver" and (spec.Count or 1) or 1)
                if not short then
                    return Side.work(quest)
                end
                fallback = fallback or quest
            end
        end
        if fallback then
            return Side.work(fallback)
        end

        -- Nothing active that can move: take a new one.
        if Side.finished > 0 and not Toggles.SideQuestChain.Value then
            return Side.stop(string.format("Finished %d side quest(s). Turn on Auto accept next to keep going.", Side.finished))
        end
        local slot = getSlot()
        local lastTime = slot and slot:FindFirstChild("Quests") and slot.Quests:FindFirstChild("LastTime")
        local cooldown = lastTime and Quests.QuestCD - (Utility.Tick() - lastTime.Value) or 0
        if cooldown > 0 then
            Side.status = string.format("Next quest in %ds (game cooldown)", math.ceil(cooldown))
            return
        end
        local key, why = Side.pick()
        elevate()
        if not key then
            local stuck = next(Side.blocked) and Side.blocked[next(Side.blocked)]
            return Side.stop(stuck and string.format("%s. %s", why, stuck) or why)
        end
        local ok, reason = Side.accept(key)
        if ok then
            Side.active[key] = true
            notify("Side Quests", string.format("Accepted %s (%d exp)", Side.questName(key), questExp(Quests.Holder[key])), 5)
        elseif Side.on() then
            Side.block(key, string.format("Could not accept %s: %s", Side.questName(key), reason))
        end
    end

    local group = Tabs.Quests:AddGroupbox({ Side = "Left", Name = "Side quests", IconName = "package-check" })
    local progress = Tabs.Quests:AddGroupbox({ Side = "Right", Name = "Side quest progress", IconName = "list-todo" })
    local startingLabels = eligibleQuestLabels(true)
    group:AddDropdown("SideQuestPick", {
        Searchable = true,
        Text = "Side quest",
        Values = startingLabels,
        Default = startingLabels[1],
        Multi = false,
        Tooltip = "Dialogue and fishing quests. Best picks the highest-exp one the runner can finish with what you have. Locked ones show why in brackets.",
    })
    group:AddToggle("SideQuestChain", {
        Text = "Auto accept next",
        Default = true,
        Tooltip = "After a hand-in, take the next side quest instead of stopping.",
    })
    group:AddToggle("SideQuestFish", {
        Text = "Fish for missing fish",
        Default = true,
        Tooltip = "Goes to the dock and runs Auto fishing until the quest's fish are in your bag. Needs a rod on your hotbar.",
    })
    group:AddToggle("SideQuestBuy", {
        Text = "Buy missing items",
        Default = false,
        Tooltip = "Buys task items from the NPC that sells them, only when you can afford every one. Pays Wen or materials (the infirmary elixirs cost 2 Demon Horns each). Never Robux.",
    })
    group:AddToggle("AutoSideQuest", {
        Text = "Auto side quests",
        Default = false,
        Tooltip = "Accepts, travels, stocks, picks up and hands in by itself. Turns the combat farms off while it runs.",
    })
    group:AddButton({ Text = "Refresh list", Func = function()
        local labels, openCount = eligibleQuestLabels(true)
        Options.SideQuestPick:SetValues(labels)
        local best = bestQuestKey(true, function(candidate)
            return (Side.finishable(candidate))
        end)
        elevate()
        notify("Side Quests", string.format("%d available, %d locked. Best you can finish: %s", openCount,
            #labels - 1 - openCount, best and Side.questName(best) or "none"), 6)
    end })
    group:AddButton({ Text = "Go to current objective", Func = function()
        task.spawn(function()
            elevate()
            local quest = activeQuests("side")[1]
            local definition = quest and Quests.Holder[quest.key]
            local pick = definition and Side.nextTask(definition, quest)
            if not pick then
                notify("Side Quests", "No side quest objective right now", 4)
                return
            end
            local spec = pick.spec or {}
            local marker = definition.Markers and definition.Markers[pick.task.name] or {}
            local position = spec.Position or (type(spec.Positions) == "table" and spec.Positions[1]) or marker.Position
            local npc = spec.TargetNpc or marker.Npc
            if typeof(position) ~= "Vector3" and npc then
                local ok, spawn = pcall(Regions.GetNpcSpawn, npc)
                position = ok and typeof(spawn) == "Vector3" and spawn or nil
            end
            elevate()
            if typeof(position) ~= "Vector3" then
                notify("Side Quests", string.format("No known location for '%s'", pick.task.name), 4)
                return
            end
            if Toggles.AutoSideQuest.Value then
                Toggles.AutoSideQuest:SetValue(false)
            end
            local root = getRoot()
            if root then
                root.CFrame = CFrame.new(position + Vector3.new(0, 4, 0))
                root.AssemblyLinearVelocity = Vector3.zero
            end
            notify("Side Quests", string.format("At '%s'", pick.task.name), 4)
        end)
    end })
    local statusLabel = group:AddLabel("Idle", true)

    local rowLabels = {}
    for index = 1, SIDE_ROWS do
        rowLabels[index] = progress:AddLabel("", true)
    end
    progress:AddDivider()
    local footer = progress:AddLabel("", true)

    function refreshSideQuests()
        local rows = {}
        for _, quest in ipairs(activeQuests("side")) do
            local definition = Quests.Holder[quest.key]
            local specs = definition and definition.TaskSpecs or {}
            local short = definition and Side.missing(definition, quest) or {}
            rows[#rows + 1] = quest.instance .. ":"
            for _, task in ipairs(quest.tasks) do
                local spec = specs[task.name]
                local done = task.value >= task.max
                local mark = done and "[x]" or (spec and SUPPORTED[spec.Type]) and "[ ]" or "[!]"
                local extra = ""
                if not done and spec and spec.RequiredItem and short[spec.RequiredItem] then
                    extra = string.format("  (need %d more %s)", short[spec.RequiredItem], spec.RequiredItem)
                end
                rows[#rows + 1] = string.format("  %s %s  %d/%d%s", mark, task.name, task.value, task.max, extra)
            end
        end
        elevate()
        for index = 1, SIDE_ROWS do
            if rows[index] then
                rowLabels[index]:SetText(rows[index])
                rowLabels[index]:SetVisible(true)
            else
                rowLabels[index]:SetVisible(false)
            end
        end
        footer:SetText(#rows == 0 and "No side quest active. Pick one and turn on Auto side quests."
            or "[!] = has to be done by hand. One quest per category (Dialogue, Fishing) can run at once.")
        statusLabel:SetText(string.format("%s\nFinished this run: %d", Side.status, Side.finished))
    end

    Toggles.AutoSideQuest:OnChanged(function()
        elevate()
        if not Toggles.AutoSideQuest.Value then
            Side.release()
            Side.status = "Stopped"
            return
        end
        -- The runner moves the character, so every other mover stands down first.
        for _, name in ipairs({ "AutoFarm", "AutoBoss", "AutoQuest", "AutoChest", "AutoFish", "AutoYeti" }) do
            if Toggles[name] and Toggles[name].Value then
                Toggles[name]:SetValue(false)
            end
        end
        local root = getRoot()
        Side.home = root and root.CFrame
        Side.finished = 0
        Side.fishing = false
        Side.fishRetries = 0
        table.clear(Side.active)
        table.clear(Side.blocked)
        table.clear(Side.tried)
        Side.status = "Starting..."
    end)

    task.spawn(function()
        elevate()
        while alive do
            elevate()
            task.wait(SIDE_TICK)
            elevate()
            if not alive then
                break
            end
            if Side.on() then
                lootBusy = true -- keeps auto loot and the market buyer from pulling the character away
                local ok, err = xpcall(Side.step, debug.traceback)
                elevate()
                if not ok then
                    state.uiErrors = state.uiErrors or {}
                    state.uiErrors.sideQuests = tostring(err)
                    Side.stop("Side quests hit an error: " .. tostring(err):match("^[^\n]*"))
                end
            end
        end
    end)
    state.side = Side
end

--// Final Selection: every 2 hours the server sends Level 45+ Humans who stand in the plains'
--// "Final Selection" safe zone into a minigame server, where passing the trial makes you a Slayer.
--// This gets you into the zone on time, and queues a scout that records the trial itself (its
--// content lives in the minigame place, not in this one) so it can be automated next.
do
    local ARRIVE_EARLY = 45
    local GIVE_UP_AFTER = 90
    local ZONE_SPOT = Vector3.new(-2625.6, 288, -185)
    local ZONE_MIN, ZONE_MAX = Vector2.new(-2717, -227), Vector2.new(-2533, 71)
    local SCOUT = [==[
if game.PlaceId == 136406881576517 or game.PlaceId == 16205713724 then return end
task.wait(5)
local Players = game:GetService("Players")
local lp = Players.LocalPlayer
local file = "slopix-finalselection-scout.txt"
local function log(line) pcall(appendfile, file, os.date("%H:%M:%S ") .. line .. "\n") end
pcall(writefile, file, "Final Selection scout, place " .. game.PlaceId .. " job " .. game.JobId .. "\n")
local VirtualUser = game:GetService("VirtualUser")
lp.Idled:Connect(function() pcall(function() VirtualUser:CaptureController() VirtualUser:ClickButton2(Vector2.zero) end) end)
local seen = {}
for pass = 1, 90 do
    local ok, err = pcall(function()
        if pass == 1 then
            local attrs = {}
            for k, v in pairs(workspace:GetAttributes()) do attrs[#attrs + 1] = k .. "=" .. tostring(v) end
            log("workspace attrs: " .. table.concat(attrs, ", "))
            local tops = {}
            for _, c in ipairs(workspace:GetChildren()) do tops[#tops + 1] = c.Name end
            log("workspace: " .. table.concat(tops, ", "))
        end
        for _, d in ipairs(workspace:GetDescendants()) do
            if not seen[d] then
                if d:IsA("ProximityPrompt") then
                    seen[d] = true
                    local p = d.Parent
                    local pos = p and (p:IsA("BasePart") and p.Position or p:IsA("Attachment") and p.WorldPosition)
                    log(string.format("prompt %s | %s / %s @ %s", d:GetFullName(), d.ObjectText, d.ActionText, tostring(pos)))
                elseif d:IsA("Model") and d:FindFirstChildOfClass("Humanoid") and not Players:GetPlayerFromCharacter(d) then
                    seen[d] = true
                    log(string.format("npc %s | mob=%s @ %s", d:GetFullName(), tostring(d:GetAttribute("IsMob")), tostring(d:GetPivot().Position)))
                end
            end
        end
        local Utility = require(game:GetService("ReplicatedStorage").CAM.Global.Utility)
        local slot = Utility.GetData(lp, true)
        for _, quest in ipairs(slot and slot.Quests.Holder:GetChildren() or {}) do
            local parts = {}
            for _, t in ipairs(quest:FindFirstChild("Tasks") and quest.Tasks:GetChildren() or {}) do
                parts[#parts + 1] = string.format("%s %s/%s", t.Name, tostring(t:FindFirstChild("Value") and t.Value.Value), tostring(t:FindFirstChild("Max") and t.Max.Value))
            end
            local line = "quest " .. quest.Name .. " | " .. table.concat(parts, "; ")
            if not seen[line] then seen[line] = true log(line) end
        end
        local root = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
        local humanoid = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
        log(string.format("me @ %s hp %s", tostring(root and root.Position), tostring(humanoid and math.floor(humanoid.Health))))
    end)
    if not ok then log("error " .. tostring(err)) end
    task.wait(10)
end
]==]

    local group = Tabs.Quests:AddGroupbox({ Side = "Right", Name = "Final Selection", IconName = "flower" })
    local label = group:AddLabel("", true)
    group:AddToggle("AutoFinalSelection", {
        Text = "Auto join",
        Default = false,
        Tooltip = "45s before each run, pauses your farms and stands you in the plains safe zone so the server sends you in. Also queues a scout that logs the trial to slopix-finalselection-scout.txt.",
    })
    local statusText = "Idle"

    local function inZone(position)
        return position.X >= ZONE_MIN.X and position.X <= ZONE_MAX.X and position.Z >= ZONE_MIN.Y and position.Z <= ZONE_MAX.Y
    end

    local function qualifies()
        local slot = getSlot()
        local requirement = TimedEvents.FinalSelection.Requirements or {}
        if not slot then
            return false, "data not loaded"
        end
        if slot.Race.Value ~= requirement.Race then
            return false, string.format("only for %s (you are %s)", tostring(requirement.Race), slot.Race.Value)
        end
        if playerLevel() < (requirement.Level or 0) then
            return false, string.format("needs Lv %d", requirement.Level or 0)
        end
        return true
    end

    local function goToZone()
        for _, name in ipairs({ "AutoFarm", "AutoBoss", "AutoQuest", "AutoChest", "AutoFish", "AutoSideQuest", "AutoLoot", "AutoYeti" }) do
            if Toggles[name] and Toggles[name].Value then
                Toggles[name]:SetValue(false)
            end
        end
        local root = getRoot()
        if root then
            root.CFrame = CFrame.new(ZONE_SPOT)
            root.AssemblyLinearVelocity = Vector3.zero
        end
    end

    group:AddButton({ Text = "Go to the plains now", Func = function()
        goToZone()
        notify("Final Selection", "Standing in the Final Selection safe zone.", 4)
    end })

    local waitingFor, home = nil, nil
    task.spawn(function()
        elevate()
        while alive do
            elevate()
            task.wait(1)
            elevate()
            if not alive then
                break
            end
            local every = TimedEvents.FinalSelection.Every
            local now = workspace:GetServerTimeNow()
            local cycle = math.floor(now / every)
            local sinceStart = now % every
            local untilNext = every - sinceStart
            local ok, why = qualifies()

            if Toggles.AutoFinalSelection.Value and ok then
                if not waitingFor then
                    if untilNext <= ARRIVE_EARLY then
                        waitingFor = cycle + 1
                    elseif sinceStart <= GIVE_UP_AFTER then
                        waitingFor = cycle
                    end
                    if waitingFor then
                        local root = getRoot()
                        home = root and root.CFrame
                        if queue_on_teleport then
                            pcall(queue_on_teleport, SCOUT)
                        end
                        goToZone()
                        notify("Final Selection", "Heading to the plains - stay put until you are sent in.", 6)
                    end
                end
                if waitingFor then
                    local root = getRoot()
                    if root and not inZone(root.Position) then
                        goToZone()
                    end
                    if cycle >= waitingFor and sinceStart > GIVE_UP_AFTER then
                        -- Still here well after the start: the server did not take us this round.
                        waitingFor = nil
                        statusText = "Was not sent in last run - check the requirements, or join at the start next time"
                        notify("Final Selection", statusText, 8)
                        if root and home then
                            root.CFrame = home
                        end
                        home = nil
                    else
                        statusText = cycle < waitingFor and string.format("In the safe zone, starts in %ds", math.ceil(untilNext))
                            or "Run started - waiting to be sent in..."
                    end
                end
            elseif waitingFor then
                waitingFor, home = nil, nil
                statusText = "Idle"
            end

            elevate()
            label:SetText(string.format("Next run in %d:%02d:%02d%s\n%s\n%s",
                untilNext // 3600, (untilNext % 3600) // 60, math.floor(untilNext % 60),
                sinceStart <= GIVE_UP_AFTER and string.format("  (last one started %ds ago)", math.floor(sinceStart)) or "",
                ok and "You qualify." or ("Not eligible: " .. tostring(why)),
                statusText))
        end
    end)
end

--// Freeze mobs: mid-fight the client simulates the target's physics (isnetworkowner was true on
--// ~99% of frames at melee range), so pinning its root in place replicates. A frozen mob cannot
--// walk off or be knocked away, which keeps a pack in one spot for the swing box. It does not
--// stop their attacks - the server decides those (measured: damage taken unchanged).
do
    local FREEZE_RADIUS = 25
    local SCAN_INTERVAL = 0.5
    local anchors = setmetatable({}, { __mode = "k" })
    local pinned = {}
    local nextScan = 0

    TargetGroup:AddToggle("FreezeMobs", {
        Text = "Freeze mobs",
        Default = false,
        Tooltip = "While farming, holds your target and every mob within 25 studs that your client simulates where it stands, so they cannot walk off or be knocked away. They can still attack.",
    })

    local function rescan(hrp)
        table.clear(pinned)
        local keep = {}
        for _, region in ipairs(RegionRoot:GetChildren()) do
            local active = region:FindFirstChild("ActiveNpcs")
            for _, folder in ipairs(active and active:GetChildren() or {}) do
                local rig = folder:FindFirstChild(folder.Name)
                local root = rig and rig:FindFirstChild("HumanoidRootPart")
                local humanoid = rig and rig:FindFirstChildOfClass("Humanoid")
                if root and humanoid and humanoid.Health > 0
                    and (rig == farmTarget or rig:GetAttribute("IsMob") == true)
                    and (root.Position - hrp.Position).Magnitude <= FREEZE_RADIUS then
                    pinned[#pinned + 1] = root
                    keep[root] = true
                end
            end
        end
        -- A mob that left range loses its spot, so it is never snapped back from afar later.
        for root in pairs(anchors) do
            if not keep[root] then
                anchors[root] = nil
            end
        end
    end

    -- A respawn must not snap mobs back to spots pinned during the previous life.
    Library:GiveSignal(LocalPlayer.CharacterAdded:Connect(function()
        table.clear(anchors)
        table.clear(pinned)
        nextScan = 0
    end))

    Library:GiveSignal(RunService.Heartbeat:Connect(function()
        -- The Yeti farm always freezes: pinned, the Yeti's melee stopped landing in testing.
        local wanted = (Toggles.FreezeMobs and Toggles.FreezeMobs.Value) or (activeFarm and activeFarm.kind == "yeti")
        if not (isnetworkowner and state.farming and wanted) then
            if next(anchors) then
                table.clear(anchors)
                table.clear(pinned)
            end
            return
        end
        local hrp = getRoot()
        if not hrp then
            return
        end
        if os.clock() >= nextScan then
            nextScan = os.clock() + SCAN_INTERVAL
            rescan(hrp)
        end
        for _, root in ipairs(pinned) do
            if root.Parent and isnetworkowner(root) then
                local anchor = anchors[root]
                if not anchor then
                    anchor = root.CFrame
                    anchors[root] = anchor
                end
                root.CFrame = anchor
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
            end
        end
    end))
end

--// Auto Yeti: a Frozen Heart returned to the ice block under the White Terror Lair wakes the Yeti
--// Demon (2790 HP) at the berg. Its only drop is the Emberheart Lantern (25%, Unique). Its melee
--// stops landing once it is frozen, but its special attacks (heat vision, Yeti Crash, snowballs,
--// ice walls) killed a Lv71 in testing, and dying despawns it and wastes the heart. They reach the
--// client as effect events the moment they start, so the farm steps clear until they finish.
local yetiIdle
do
    local BERG = Vector3.new(-1381.9, -32.8, 502.6)
    local BERG_STAND = BERG + Vector3.new(0, 3, 8)
    local DODGE_HEIGHT = 45
    -- The Yeti despawns the moment its summoner is ~150 studs away (a retreat that far cost a
    -- heart), while 45-stud dodges were fine, so backing off stays inside that.
    local RETREAT_HEIGHT = 40
    local RESUME_AT = 0.85
    -- Measured: Yeti Crash and snowballs deal nothing to a dodger; Heat Vision's beam tracks and
    -- still lands (~78 per cast), so dodging it only saves the opening hit.
    local YETI_ATTACKS = {
        ["Telegraph"] = 2.5, -- the Yeti's wind-up ("Start"), 0.2-0.5s before Crash / Heat Vision
        ["Heat_Vision_VFX"] = 2.5,
        ["Yeti Crash"] = 2.5,
        ["SnowballFX_effs"] = 2.5,
        ["IceWallFX_effs"] = 2,
    }
    local EffectsEvent = require(ReplicatedStorage.Communication.ServerAndClient.Effects.EffectsEvent)
    elevate()

    local group = Tabs.Farm:AddGroupbox({ Side = "Left", Name = "Yeti", IconName = "snowflake" })
    local statusLabel = group:AddLabel("", true)
    group:AddToggle("AutoYeti", {
        Text = "Auto Yeti",
        Default = false,
        Tooltip = "Summons the Yeti with your Frozen Hearts, kills it, dodges its special attacks and picks up the drop. Uses the Boss positioning.",
    })
    group:AddToggle("YetiDodge", {
        Text = "Dodge special attacks",
        Default = true,
        Tooltip = "Steps clear while heat vision, Yeti Crash, snowballs or ice walls are going off.",
    })
    group:AddToggle("YetiStopOnLantern", {
        Text = "Stop once I own the Lantern",
        Default = true,
        Tooltip = "The Emberheart Lantern is Unique, so more kills gain nothing once you have it.",
    })
    group:AddSlider("YetiRetreat", {
        Text = "Back off below",
        Default = 45,
        Min = 20,
        Max = 80,
        Rounding = 0,
        Suffix = "% HP",
    })
    group:AddLabel("Hearts: Black Marketer ($10,000), or 10% from rare chests and sealed caches. The Yeti leaves ~160s after it wakes, killed or not, and shrugs off damage for ~90s once its Small Yetis appear: it needs well over 20 damage per second to kill. A Lv71 dealing ~7/s lost 2 hearts.", true)

    local statusText = "Idle"

    local function yetiRig()
        for _, region in ipairs(RegionRoot:GetChildren()) do
            local active = region:FindFirstChild("ActiveNpcs")
            local folder = active and active:FindFirstChild("Yeti Demon")
            local rig = folder and folder:FindFirstChild("Yeti Demon")
            local humanoid = rig and rig:FindFirstChildOfClass("Humanoid")
            if humanoid and humanoid.Health > 0 then
                return rig
            end
        end
        return nil
    end

    Library:GiveSignal(EffectsEvent:Connect(function(name, source, stage)
        local duration = YETI_ATTACKS[name]
        if not duration or not (Toggles.AutoYeti and Toggles.AutoYeti.Value and Toggles.YetiDodge.Value) then
            return
        end
        -- Every boss sends Telegraph; only the Yeti's wind-up (not its "Cancel") counts here.
        if name == "Telegraph" and not (typeof(source) == "Instance" and source.Name == "Yeti Demon" and stage ~= "Cancel") then
            return
        end
        local rig = yetiRig()
        local root = rig and rig:FindFirstChild("HumanoidRootPart")
        local hrp = getRoot()
        if not root or not hrp or (root.Position - hrp.Position).Magnitude > 150 then
            return
        end
        if (state.dodgeUntil or 0) < math.huge then
            state.dodgePosition = root.Position + Vector3.new(0, DODGE_HEIGHT, 0)
            state.dodgeUntil = math.max(state.dodgeUntil or 0, os.clock() + duration)
        end
        state.yetiDodges = (state.yetiDodges or 0) + 1
        state.yetiLastAttack = name
    end))

    -- Low HP: back far off and regenerate instead of dying (a death despawns the Yeti).
    task.spawn(function()
        local retreating = false
        while alive do
            task.wait(0.25)
            local _, char = getRoot()
            local humanoid = char and char:FindFirstChildOfClass("Humanoid")
            local active = Toggles.AutoYeti and Toggles.AutoYeti.Value and state.farming
            if active and humanoid and humanoid.MaxHealth > 0 then
                local ratio = humanoid.Health / humanoid.MaxHealth
                if not retreating and ratio * 100 < Options.YetiRetreat.Value then
                    retreating = true
                    local rig = yetiRig()
                    state.dodgePosition = (rig and rig:GetPivot().Position or BERG) + Vector3.new(0, RETREAT_HEIGHT, 0)
                    state.dodgeUntil = math.huge
                    statusText = "Low HP - backing off to regenerate"
                elseif retreating and ratio >= RESUME_AT then
                    retreating = false
                    state.dodgeUntil = 0
                    statusText = "Back in the fight"
                end
            elseif retreating then
                retreating = false
                state.dodgeUntil = 0
            end
        end
    end)

    -- A death mid-fight has already cost the heart; stop before the next one goes the same way.
    Library:GiveSignal(LocalPlayer.CharacterAdded:Connect(function()
        if Toggles.AutoYeti and Toggles.AutoYeti.Value and os.clock() - (state.yetiSeenAt or -math.huge) < 20 then
            state.yetiFighting = false
            state.dodgeUntil = 0
            Toggles.AutoYeti:SetValue(false)
            notify("Auto Yeti", "You died and the Yeti despawned. Stopped so it does not spend another heart.", 8)
        end
    end))

    yetiIdle = function()
        state.yetiFighting = false
        if Toggles.YetiStopOnLantern.Value and itemCount("Emberheart Lantern") > 0 then
            Toggles.AutoYeti:SetValue(false)
            notify("Auto Yeti", "You own the Emberheart Lantern - stopping.", 6)
            return
        end
        -- The kill's drop lands at the berg; take it before anything else.
        if #lootNear(BERG, 150) > 0 then
            statusText = "Picking up the drop..."
            state.looted = (state.looted or 0) + collectLoot(BERG, 150)
            return
        end
        if itemCount("Frozen Heart") <= 0 then
            statusText = "No Frozen Heart. The Black Marketer sells them for $10,000."
            anchorPosition = nil
            task.wait(2)
            return
        end
        statusText = "Going to the berg..."
        anchorPosition = BERG_STAND
        local deadline = os.clock() + 8
        local prompt, berg
        repeat
            task.wait(0.3)
            local map = workspace:FindFirstChild("Map")
            berg = map and map:FindFirstChild("Map") and map.Map:FindFirstChild("FrozenYeti")
            prompt = berg and berg:FindFirstChildWhichIsA("ProximityPrompt", true)
        until prompt or os.clock() >= deadline or not alive
        if not prompt then
            if berg == nil then
                -- Once woken, the ice block stays gone from that server for a long while
                -- (still missing 39 min after a summon in testing), even if the Yeti despawned.
                statusText = "The berg is gone in this server (it was woken recently). Join another server or wait."
                anchorPosition = nil
                task.wait(10)
            else
                statusText = "Waiting for the berg to load..."
            end
            return
        end
        statusText = "Returning the heart..."
        pcall(fireproximityprompt, prompt)
        deadline = os.clock() + 8
        repeat
            task.wait(0.3)
        until yetiRig() or os.clock() >= deadline or not alive
        if yetiRig() then
            state.yetiSummons = (state.yetiSummons or 0) + 1
            statusText = "Yeti summoned - fighting"
        else
            statusText = "The berg did not wake - retrying"
        end
    end

    task.spawn(function()
        while alive do
            task.wait(1)
            -- Unload clears Toggles, and this tick may already be past the loop check.
            if not alive or not Toggles.AutoYeti then
                break
            end
            local rig = yetiRig()
            local humanoid = rig and rig:FindFirstChildOfClass("Humanoid")
            state.yetiFighting = Toggles.AutoYeti.Value and state.farming and humanoid ~= nil or false
            if state.yetiFighting then
                state.yetiSeenAt = os.clock()
            end
            elevate()
            statusLabel:SetText(string.format("%s\nHearts: %d  |  Lantern: %s\nYeti: %s  |  summoned %d, dodged %d",
                Toggles.AutoYeti.Value and statusText or "Off",
                itemCount("Frozen Heart"),
                itemCount("Emberheart Lantern") > 0 and "owned" or "not yet",
                humanoid and string.format("%d / %d HP", math.floor(humanoid.Health), humanoid.MaxHealth) or "not up",
                state.yetiSummons or 0, state.yetiDodges or 0))
        end
    end)
end

local SaveManager
do
    local MenuGroup = Tabs.Settings:AddGroupbox({ Side = "Left", Name = "Menu", IconName = "sliders-horizontal" })
    MenuGroup:AddDropdown("NotificationSide", {
        Searchable = true,
        Text = "Notification side",
        Values = { "Left", "Right" },
        Default = "Right",
        Callback = function(Value)
            Library:SetNotifySide(Value)
        end,
    })
    MenuGroup:AddDropdown("DPIScale", {
        Searchable = true,
        Text = "DPI scale",
        Values = { "50%", "75%", "100%", "125%", "150%", "175%", "200%" },
        Default = "100%",
        Callback = function(Value)
            Library:SetDPIScale(tonumber((Value:gsub("%%", ""))))
        end,
    })
    MenuGroup:AddDivider()
    MenuGroup:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", {
        Default = "RightShift",
        NoUI = true,
        Text = "Menu keybind",
    })
    MenuGroup:AddButton("Unload", function() Library:Unload() end)
    Library.ToggleKeybind = Options.MenuKeybind

    -- Official Obsidian addons (docs.mspaint.cc/obsidian): ThemeManager for themes,
    -- SaveManager for named configs and autoload. A failed download leaves the hub usable.
    local AddonRepo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/addons/"
    local themeOk, ThemeManager = pcall(function()
        return loadstring(game:HttpGet(AddonRepo .. "ThemeManager.lua"))()
    end)
    local saveOk, LoadedSaveManager = pcall(function()
        return loadstring(game:HttpGet(AddonRepo .. "SaveManager.lua"))()
    end)
    elevate()

    if saveOk and LoadedSaveManager then
        SaveManager = LoadedSaveManager
        SaveManager:SetLibrary(Library)
        SaveManager:IgnoreThemeSettings()
        SaveManager:SetIgnoreIndexes({ "MenuKeybind" })
        SaveManager:SetFolder("SlopixHub/Slayers2")
        SaveManager:BuildConfigSection(Tabs.Settings)
    else
        notify("Slopix Hub", "Could not load the config manager: " .. tostring(LoadedSaveManager), 6)
    end

    if themeOk and ThemeManager then
        ThemeManager:SetLibrary(Library)
        ThemeManager:SetFolder("SlopixHub")
        -- The crimson palette becomes the "Default" theme, so it also applies on the stock library.
        ThemeManager:SetDefaultTheme({
            BackgroundColor = "0d0c12",
            MainColor = "1e1b28",
            AccentColor = "eb4060",
            OutlineColor = "302b3e",
            FontColor = "f0eef6",
            FontFace = "BuilderSans", -- must be one of the Font Face dropdown's values
        })
        ThemeManager:ApplyToTab(Tabs.Settings)
        -- Without a saved default, select "Default" so the pickers and font dropdown match
        -- the active theme instead of the dropdown's hard-coded "Code".
        local _, hasSavedDefault = ThemeManager:GetDefaultTheme()
        if hasSavedDefault then
            ThemeManager:LoadDefault()
        else
            Options.ThemeManager_ThemeList:SetValue("Default")
        end
    else
        notify("Slopix Hub", "Could not load the theme manager: " .. tostring(ThemeManager), 6)
    end
    elevate()
end
getgenv().__Slayers2Hub = { Library = Library, Options = Options, Toggles = Toggles, State = state, SaveManager = SaveManager, Chest = Chest }

local function stopAutoSpin(description, time)
    Toggles.AutoSpin:SetValue(false)
    notify("Auto Spin", description, time)
end

Toggles.AutoSpin:OnChanged(function()
    state.running = Toggles.AutoSpin.Value
end)

local switchingFarm = false

local function bindFarmToggle(toggle, others)
    toggle:OnChanged(function()
        if switchingFarm then
            return
        end
        if toggle.Value then
            if Toggles.AutoFish and Toggles.AutoFish.Value then Toggles.AutoFish:SetValue(false) end
            if Toggles.AutoSideQuest and Toggles.AutoSideQuest.Value then Toggles.AutoSideQuest:SetValue(false) end
            if toggle == Toggles.AutoQuest then
                questsTaken = #activeQuests("combat") > 0 and 1 or 0
            end
            local hadOther = false
            switchingFarm = true
            for _, other in ipairs(others) do
                if other.Value then
                    other:SetValue(false)
                    hadOther = true
                end
            end
            switchingFarm = false
            if hadOther then
                stopFarm()
            end
            activeFarm = farmConfig()
            -- Auto chests rides along with another farm; joining one already running must not
            -- reset its return point or target.
            if not state.farming then
                startFarm()
            end
        else
            -- Only stop the engine once no farm is left on (chests can run beside another).
            local anyOn = false
            for _, name in ipairs({ "AutoFarm", "AutoBoss", "AutoQuest", "AutoChest", "AutoYeti" }) do
                if Toggles[name] and Toggles[name].Value then
                    anyOn = true
                end
            end
            if not anyOn then
                stopFarm()
            end
        end
    end)
end

-- Mob, boss and quest farms share one target, so only one runs; Auto chests runs beside any of
-- them (farmConfig gives it the fight only while a chest is up), and Auto Yeti runs alone.
bindFarmToggle(Toggles.AutoFarm, { Toggles.AutoBoss, Toggles.AutoQuest, Toggles.AutoYeti })
bindFarmToggle(Toggles.AutoBoss, { Toggles.AutoFarm, Toggles.AutoQuest, Toggles.AutoYeti })
bindFarmToggle(Toggles.AutoQuest, { Toggles.AutoFarm, Toggles.AutoBoss, Toggles.AutoYeti })
bindFarmToggle(Toggles.AutoChest, { Toggles.AutoYeti })
bindFarmToggle(Toggles.AutoYeti, { Toggles.AutoFarm, Toggles.AutoBoss, Toggles.AutoQuest, Toggles.AutoChest })

local idleConnection = LocalPlayer.Idled:Connect(function()
    if Toggles.AntiAfk and Toggles.AntiAfk.Value then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.zero)
        end)
    end
end)

-- GiveSignal lets Library:Unload disconnect these; raw connections outlived the menu and
-- kept firing into the cleared Options table after every reload.
Library:GiveSignal(BossHunts.ChildAdded:Connect(function()
    Options.BossTargets:SetValues(bossNames())
end))

Library:GiveSignal(BossHunts.ChildRemoved:Connect(function()
    Options.BossTargets:SetValues(bossNames())
end))

task.spawn(function()
    elevate()
    while alive do
        elevate()
        -- Panel errors are kept in state.uiErrors instead of vanishing inside pcall.
        state.uiErrors = state.uiErrors or {}
        for name, refresh in { timers = refreshTimers, quests = refreshQuestProgress, chests = Chest.refresh, market = refreshMarket, side = refreshSideQuests } do
            -- A panel that yields drops thread identity for whatever runs after it.
            elevate()
            local ok, err = xpcall(refresh, debug.traceback)
            state.uiErrors[name] = not ok and tostring(err) or nil
        end
        task.wait(TIMER_TICK)
    end
end)

task.spawn(function()
    elevate()
    local lastAccept = 0
    while alive do
        elevate()
        task.wait(IDLE_INTERVAL)
        elevate()
        if not alive then
            break
        end
        if not Toggles.AutoQuest.Value then
            continue
        end
        if #activeQuests("combat") > 0 then
            continue
        end
        if questsTaken > 0 and not Toggles.QuestChain.Value then
            Toggles.AutoQuest:SetValue(false)
            notify("Auto Quest", "Quest finished. Turn on Auto accept next to keep going.", 6)
            continue
        end
        if os.clock() - lastAccept < QUEST_ACCEPT_COOLDOWN then
            continue
        end
        local slot = getSlot()
        local lastTime = slot and slot:FindFirstChild("Quests") and slot.Quests:FindFirstChild("LastTime")
        if lastTime and Utility.Tick() - lastTime.Value <= Quests.QuestCD then
            continue
        end

        Options.QuestPick:SetValues(eligibleQuestLabels())
        local key = resolveQuestSelection()
        if not key then
            Toggles.AutoQuest:SetValue(false)
            notify("Auto Quest", "No quests left that you qualify for", 6)
            continue
        end

        local definition = Quests.Holder[key]
        local name = definition and tostring(definition.QuestInstance) or key
        lastAccept = os.clock()
        local ok, why, retry = acceptQuest(key)
        elevate()
        state.questStatus = ok and "Accepted" or tostring(why)
        if ok then
            questsTaken += 1
            notify("Auto Quest", string.format("Accepted %s (%d exp)", name, questExp(definition)), 5)
        elseif not retry then
            Toggles.AutoQuest:SetValue(false)
            notify("Auto Quest", string.format("Could not accept %s: %s", name, why), 6)
        end
    end
end)

Options.FarmWeapon:OnChanged(function()
    weaponSlot = nil
    if state.farming then
        task.spawn(equipWeapon, Options.FarmWeapon.Value)
    end
end)

Library:GiveSignal(LocalPlayer.CharacterAdded:Connect(function()
    farmTarget = nil
    local entry = Chest.current
    if entry and Chest.stateOf(entry) == "Locked" then
        entry.deaths = (entry.deaths or 0) + 1
        if entry.deaths >= Chest.MAX_DEATHS then
            entry.deaths = 0
            Chest.skip(entry, string.format("its guards are too strong (died %d times)", Chest.MAX_DEATHS), Chest.TOO_STRONG_SKIP)
        end
    end
    if state.farming then
        task.wait(1)
        cacheNoclipParts()
    end
end))

Library:OnUnload(function()
    elevate()
    alive = false
    if cleanupFishing then cleanupFishing() end
    state.running = false
    switchingFarm = true
    Toggles.AutoFarm:SetValue(false)
    Toggles.AutoBoss:SetValue(false)
    Toggles.AutoQuest:SetValue(false)
    Toggles.AutoChest:SetValue(false)
    Toggles.AutoYeti:SetValue(false)
    switchingFarm = false
    stopFarm()
    idleConnection:Disconnect()
    lootPosition = nil
    healRetreat = nil
    Chest.opening = false
    getgenv().__Slayers2Hub = nil
end)

task.spawn(redeemKnownCodes)

task.spawn(function()
    elevate()
    while alive do
        elevate()
        if not Toggles.AutoSpin.Value then
            task.wait(IDLE_INTERVAL)
            continue
        end

        local target = RARITY_BY_NAME[Options.StopRarity.Value] or DEFAULT_TARGET_RARITY
        local current = getClanName()

        if rarityOf(current) >= target then
            stopAutoSpin(
                string.format("Stopped: already have %s (%s or better)", current, Options.StopRarity.Value),
                6
            )
            continue
        end

        if getSpinCount() <= 0 then
            stopAutoSpin("No clan spins left", 5)
            continue
        end

        local ok, rolled, rolledRarity = spinOnce()
        if not ok then
            if getSpinCount() <= 0 then
                stopAutoSpin("No clan spins left", 5)
            else
                stopAutoSpin("Roll rejected - open the clan spin screen / rejoin", 6)
            end
            continue
        end

        if rolledRarity >= target then
            stopAutoSpin(
                string.format("Got %s (%s) after %d spins", rolled, tierNameOf(rolled), state.spins),
                8
            )
            continue
        end

        task.wait(Options.SpinDelay.Value)
    end
end)

task.spawn(function()
    elevate()
    local function farmTick()
        local config = farmConfig()
        if not config then
            task.wait(IDLE_INTERVAL)
            return
        end
        activeFarm = config

        if state.healing or (state.dodgeUntil and os.clock() < state.dodgeUntil) then
            task.wait(0.05)
            return
        end

        -- Dead or mid-respawn: the game's punch() indexes HumanoidRootPart and throws.
        local hrp, char = getRoot()
        local humanoid = char and char:FindFirstChildOfClass("Humanoid")
        if not hrp or not humanoid or humanoid.Health <= 0 then
            farmTarget = nil
            state.target = nil
            task.wait(0.5)
            return
        end

        -- Back from a chest run: another farm picks up where it was, or you stand where you were.
        if (config.kind ~= "chest" or not config.chest) and Chest.detour then
            Chest.returnHome()
        end

        if config.kind == "chest" then
            if not config.chest then
                Chest.current = nil
                if not Chest.lowHealth() then
                    Chest.status = "No chest in range - waiting for one to spawn"
                end
                farmTarget = nil
                state.target = nil
                anchorPosition = nil
                task.wait(SEARCH_INTERVAL)
                return
            end
            local guard = Chest.step(config.chest)
            elevate()
            if farmTarget ~= guard and targetDied(farmTarget) then
                state.kills += 1
            end
            farmTarget = guard
            state.target = guard
            if not guard then
                return
            end
        else
            if config.kind == "quest" and config.count == 0 then
                farmTarget = nil
                state.target = nil
                anchorPosition = nil
                task.wait(SEARCH_INTERVAL)
                return
            end

            if not isValidTarget(farmTarget, config.wanted, config.count, config.hostileOnly) then
                if targetDied(farmTarget) then
                    state.kills += 1
                end
                farmTarget = findTarget(config.wanted, config.count, config.hostileOnly)
                state.target = farmTarget
            end

            if not farmTarget and config.kind == "yeti" then
                -- No Yeti up: loot, then summon another if there is a heart to spend.
                yetiIdle()
                elevate()
                return
            end

            if not farmTarget then
                if config.travel and config.count > 0 then
                    local position, name = spawnPosition(config.wanted)
                    if position then
                        anchorPosition = position + Vector3.new(0, TRAVEL_HEIGHT, 0)
                        task.wait(TRAVEL_SETTLE)
                    else
                        notify(config.label, string.format("No spawn point known for %s", name or "that target"), 4)
                        task.wait(SEARCH_INTERVAL)
                    end
                else
                    anchorPosition = nil
                    task.wait(SEARCH_INTERVAL)
                end
                return
            end
        end

        anchorPosition = nil

        -- One refused equip (stunned, ragdolled, just respawned) used to switch the whole farm
        -- off mid-fight; only a weapon that keeps refusing stops it now.
        if not weaponReady(true) then
            state.equipFails = (state.equipFails or 0) + 1
            if state.equipFails >= 5 then
                state.equipFails = 0
                config.toggle:SetValue(false)
                notify(config.label, string.format("Could not equip %s five times in a row - stopped. Check it is on your hotbar.", tostring(Options.FarmWeapon.Value)), 8)
            else
                task.wait(1)
            end
            return
        end
        state.equipFails = 0

        local punch = getPunch()
        if not punch then
            config.toggle:SetValue(false)
            notify(config.label, "Could not reach the game's combat script", 6)
            return
        end

        local cooldown = punch()
        task.wait(type(cooldown) == "number" and cooldown or PUNCH_RETRY)
    end

    while alive do
        elevate()
        -- One bad tick (a death mid-swing threw out of the game's punch()) used to end this
        -- thread for good, leaving every farm frozen on a dead target until a re-execute.
        local ok, err = xpcall(farmTick, debug.traceback)
        if not ok then
            state.uiErrors = state.uiErrors or {}
            state.uiErrors.farm = tostring(err)
            farmTarget = nil
            state.target = nil
            if Chest.opening then
                -- It died mid-sweep: free the loot lock or auto loot would stay off for good.
                Chest.opening = false
                lootBusy = false
                lootPosition = nil
            end
            task.wait(0.5)
        end
    end
end)

task.spawn(function()
    elevate()
    local warned = false
    while alive do
        elevate()
        task.wait(HEAL_CHECK_INTERVAL)
        elevate()
        if not alive then
            break
        end
        if not Toggles.AutoHeal.Value or state.healing or state.fishing then
            continue
        end
        local _, char = getRoot()
        local humanoid = char and char:FindFirstChildOfClass("Humanoid")
        if not humanoid or humanoid.Health <= 0 or humanoid.MaxHealth <= 0 then
            continue
        end
        if humanoid.Health / humanoid.MaxHealth * 100 > Options.HealThreshold.Value then
            continue
        end
        local ok, why = drinkPotion(Options.HealPotion.Value)
        elevate()
        if ok then
            state.heals = (state.heals or 0) + 1
            warned = false
        else
            if not warned then
                notify("Auto Heal", why, 5)
                warned = true
            end
            task.wait(3)
        end
    end
end)

task.spawn(function()
    elevate()
    while alive do
        elevate()
        task.wait(0.5)
        elevate()
        if not alive then
            break
        end
        if not Toggles.AutoLoot.Value or lootBusy or Chest.opening or state.healing or state.fishing then
            continue
        end
        -- Only landed drops pull us off a live target: a grab takes well under a second and the
        -- farm anchor puts us straight back. Waiting for a gap between kills never worked, since
        -- the farm re-targets the instant one dies.
        local hrp = getRoot()
        if not hrp or #lootNear(hrp.Position, Options.LootRadius.Value, true) == 0 then
            continue
        end
        local home = hrp.CFrame
        -- The farm anchor already honours lootPosition; outside a farm hold the character ourselves.
        local hold = not anchorConnection and RunService.Heartbeat:Connect(function()
            local root = getRoot()
            if root and lootPosition then
                root.CFrame = CFrame.new(lootPosition)
                root.AssemblyLinearVelocity = Vector3.zero
            end
        end)
        state.looted = (state.looted or 0) + collectLoot(hrp.Position, Options.LootRadius.Value)
        if hold then
            hold:Disconnect()
            local root = getRoot()
            if root then
                root.CFrame = home
            end
        end
    end
end)

task.spawn(function()
    elevate()
    local nextSweep = 0
    while alive do
        elevate()
        task.wait(1)
        elevate()
        if not alive then
            break
        end
        -- (OnChanged would replace bindFarmToggle's handler, so a fresh switch-on is spotted here.)
        if not Toggles.AutoChest.Value then
            nextSweep = 0
        elseif os.clock() >= nextSweep then
            nextSweep = os.clock() + Chest.SWEEP_INTERVAL
            local hrp = getRoot()
            local from = Chest.detour and Chest.detour.Position or hrp and hrp.Position
            if from then
                Chest.discover(from, Options.ChestRange.Value)
            end
        end
    end
end)

if SaveManager then
    -- Last, so every toggle's OnChanged handler is bound before a config switches it on.
    local ok, err = pcall(SaveManager.LoadAutoloadConfig, SaveManager)
    elevate()
    if not ok then
        notify("Slopix Hub", "Autoload failed: " .. tostring(err), 6)
    end
end

if RuntimeState then
    RuntimeState.onCleanup(function()
        elevate()
        alive = false
        state.running = false
        pcall(stopFarm)
        pcall(function() Library:Unload() end)
    end)
end
