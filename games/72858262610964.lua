-- Slopix Hub (Tap Simulator), built 2026-10-17 12:37 UTC by build.py. Edit the files in src/, not this one.
local __modules, __cache, __loading = {}, {}, {}
local function use(name)
    local cached = __cache[name]
    if cached ~= nil then
        return cached
    end
    local loader = __modules[name]
    if not loader then
        error("Slopix: no module named " .. tostring(name), 2)
    end
    if __loading[name] then
        error("Slopix: circular use of " .. tostring(name), 2)
    end
    __loading[name] = true
    -- A module that errors is unmarked, so the next use() reports its error, not a cycle.
    local trace = debug and type(debug.traceback) == 'function' and debug.traceback or tostring
    local ok, result = xpcall(loader, trace, use)
    __loading[name] = nil
    if not ok then
        error(result, 0)
    end
    if result == nil then
        result = true
    end
    __cache[name] = result
    return result
end
__modules["core/env"] = function(use) -- src/games/tapsim/core/env.luau
-- Tap Simulator: Reborn. The game's data and remotes; everything else comes from shared/env.
--
-- Player data is a MadStudio Replica, read through the client's DataController
-- (ReplicatedStorage.Controllers.Core.DataController): Env.data() is its live Data table. Nothing
-- here writes it -- the server owns it and replicates down -- so every feature works by firing the
-- game's own request remotes and watching the replica change.
--
-- Remotes use sleitnick Comm: each service is a folder under ReplicatedStorage.RemoteServices with
-- an RE subfolder (RemoteEvents) and an RF subfolder (RemoteFunctions). Env.remote resolves either.

local Env = use("shared/env")

Env.checkMissing({
    { "queue_on_teleport", Env.queueOnTeleport },
    { "setclipboard", Env.setClipboard },
})
for _, name in ipairs({ "readfile", "writefile", "isfile", "isfolder", "makefolder", "listfiles", "delfile" }) do
    Env.checkMissing({ { name, Env.files[name] } })
end
table.sort(Env.missing)

local RS = Env.ReplicatedStorage

-- The DataController singleton, required lazily (it is loaded by the game long before the hub).
local dataController
local function controller()
    if dataController == nil then
        local ok, module = Env.call(function()
            local core = Env.need(Env.need(RS, "Controllers", 20), "Core", 10)
            return require(Env.need(core, "DataController", 10))
        end)
        dataController = ok and module or false
    end
    return dataController or nil
end
Env.preloadData = controller

-- The player's Replica, or nil before it has replicated.
function Env.replica()
    local dc = controller()
    if not dc then
        return nil
    end
    local ok, replica = Env.call(function()
        return dc.GetReplica and dc:GetReplica() or dc.Get and dc:Get()
    end)
    return ok and replica or nil
end

-- The live player Data table (Currencies, Progression, Eggs, Pets, Upgrades, ...), or nil.
function Env.data()
    local replica = Env.replica()
    return replica and replica.Data or nil
end

-- One field of Currencies (Coins, Gems, Tokens, PaidTokens), as a number, or 0.
function Env.currency(name)
    local data = Env.data()
    local value = data and type(data.Currencies) == "table" and data.Currencies[name]
    return tonumber(value) or 0
end

-- A RemoteEvent or RemoteFunction under RemoteServices.<service>.(RE|RF).<name>, cached.
local remotes = {}
function Env.remote(service, name)
    local key = service .. "/" .. name
    local found = remotes[key]
    if not found or not found.Parent then
        local svc = Env.need(Env.need(RS, "RemoteServices", 30), service, 15)
        local node
        local deadline = os.clock() + 10
        repeat
            local re, rf = svc:FindFirstChild("RE"), svc:FindFirstChild("RF")
            node = (re and re:FindFirstChild(name)) or (rf and rf:FindFirstChild(name))
            if not node then
                task.wait(0.1)
            end
        until node or os.clock() >= deadline
        Env.elevate()
        assert(node, "Slopix: remote " .. key .. " is missing")
        remotes[key] = node
        found = node
    end
    return found
end

-- Fires a RemoteEvent request (RemoteServices.<service>.RE.<name>) with one payload table.
function Env.fire(service, name, payload)
    local remote = Env.remote(service, name)
    Env.elevate()
    remote:FireServer(payload)
end

-- Invokes a RemoteFunction (RemoteServices.<service>.RF.<name>) and restores the thread after.
-- Returns ok, ... like pcall. InvokeServer has no timeout of its own, and one reply that never
-- comes would otherwise stall the feature that asked (and anything waiting on it), so after
-- INVOKE_TIMEOUT seconds this gives up with false, "timeout"; a late reply is dropped.
local INVOKE_TIMEOUT = 10
function Env.invoke(service, name, ...)
    local remote = Env.remote(service, name)
    local args = table.pack(...)
    local done, result = false, nil
    task.spawn(function()
        result = table.pack(Env.call(function()
            return remote:InvokeServer(table.unpack(args, 1, args.n))
        end))
        done = true
    end)
    local deadline = os.clock() + INVOKE_TIMEOUT
    while not done and os.clock() < deadline do
        task.wait(0.03)
    end
    Env.elevate()
    if not done then
        return false, "timeout"
    end
    return table.unpack(result, 1, result.n)
end

-- Where the hub's own overlays go, out of the game's PlayerGui.
function Env.guiParent()
    local ok, hidden = pcall(function()
        return gethui and gethui()
    end)
    return ok and hidden or game:GetService("CoreGui")
end

return Env
end
__modules["core/ready"] = function(use) -- src/games/tapsim/core/ready.luau
-- Waits until the game has loaded what the hub reads, before any feature is built. Executed on
-- join, the hub used to start while the replica and character were still on their way.

local Env = use("core/env")

local Ready = {}

local MAX_WAIT = 180
local NOTE_EVERY = 15

local StarterGui = game:GetService("StarterGui")
local RS = Env.ReplicatedStorage
local lp = Env.LocalPlayer

local function notify(text, duration)
    pcall(StarterGui.SetCore, StarterGui, "SendNotification", {
        Title = "Slopix Hub",
        Text = text,
        Duration = duration or 5,
    })
    Env.elevate()
end

local function characterReady()
    local char = lp.Character
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    return char ~= nil and char:FindFirstChild("HumanoidRootPart") ~= nil and humanoid ~= nil and humanoid.Health > 0
end

local CHECKLIST = {
    { "the game's remotes", function()
        return RS:FindFirstChild("RemoteServices") ~= nil and RS:FindFirstChild("Controllers") ~= nil
    end },
    { "your save data", function()
        local data = Env.data()
        return data ~= nil and type(data.Currencies) == "table"
    end },
    { "your character", characterReady },
}

-- Blocks until the game is ready (or MAX_WAIT passed). Returns the labels that never became ready.
function Ready.wait()
    local started = os.clock()
    task.spawn(pcall, Env.preloadData)
    local nextNote = started + 3
    local missing
    while true do
        missing = {}
        for _, entry in ipairs(CHECKLIST) do
            local ok, done = pcall(entry[2])
            if not ok or not done then
                missing[#missing + 1] = entry[1]
            end
        end
        Env.elevate()
        if #missing == 0 then
            break
        end
        local now = os.clock()
        if now - started >= MAX_WAIT then
            notify(string.format("Still no %s after %ds. Loading anyway.", table.concat(missing, ", "), MAX_WAIT), 10)
            break
        end
        if now >= nextNote then
            notify(string.format("Waiting for the game to load: %s (%ds)", table.concat(missing, ", "), math.floor(now - started)), 5)
            nextNote = now + NOTE_EVERY
        end
        task.wait(0.5)
    end
    return missing
end

return Ready
end
__modules["core/ui"] = function(use) -- src/games/tapsim/core/ui.luau
-- Tap Simulator's window and tabs.

local Ui = use("shared/ui")

return Ui.create({
    library = function() return use("vendor/ui") end,
    icons = use("vendor/icons"),
    footer = "Tap Simulator",
    tabs = {
        { "Home", "house", "Welcome to Slopix Hub" },
        { "Tapping", "hand", "Auto tap, auto clicker, rebirth and upgrades" },
        { "Pets", "egg", "Auto hatch eggs, equip your strongest pets and feed them treats" },
        { "Craft", "hammer", "Golden, Diamond and Rainbow machines, and potions" },
        { "Skills", "git-branch", "Auto unlock the skill tree" },
        { "Rewards", "gift", "Offline earnings, quests, Pet Index, chests, spins, ducks, balloons and digging" },
        { "Settings", "settings", "Menu, themes and configs" },
    },
})
end
__modules["features/craft"] = function(use) -- src/games/tapsim/features/craft.luau
-- Craft tab: the pet machines (Normal -> Golden -> Diamond -> Rainbow). Potions are features/potions.
--
-- Golden and Diamond take same-name pets of the source tier and roll a chance that rises with how
-- many go in (MachineConfig.Chances, plus the Golden mastery bonus, scaled by your enchant craft
-- bonus). A failed roll destroys every pet put in, so the cheapest safe batch is the fewest pets
-- that already reach 100%; "Best value" instead takes the lowest expected pets per success.
-- Rainbow (the "Shiny" machine) is a timed queue of up to three: Durations[count], and 5 Diamonds
-- finish in 30 seconds where 2 take five hours.
--
-- The game's own Craft All (MachineCraftRequested { Action = "CraftAll" }) does up to 60 of those
-- 100% batches in one request, keeping equipped, team, locked, mutated, enchanted, signed and
-- Secret pets (Shared.Pets.CraftAllPlan), so "Never fail" uses it and asks that same plan whether
-- there is anything to craft before flying anywhere.
--
-- The server checks distance ("You must be near the Golden Machine"), and the machines' interaction
-- points only exist once streamed in, so a pass teleports to each machine that has work, waits for
-- its InteractionPoint, stands in it, crafts, and goes back to where you were.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local Options = Ui.Options
local RS = Env.ReplicatedStorage
local tab = Ui.Tabs.Craft

-- Rules ----------------------------------------------------------------------------------------

-- The values from the shipped MachineConfig, used only if the module cannot be required.
local FALLBACK_CONFIG = {
    Golden = { SourceTier = "Normal", Chances = { 13, 32, 40, 63, 80, 100 } },
    Diamond = { SourceTier = "Golden", Chances = { 20, 40, 60, 80, 100 } },
    Shiny = { SourceTier = "Diamond", MinPets = 2, MaxQueue = 3, Durations = { 28800, 18000, 9000, 3600, 30 } },
}

local MachineConfig, Mastery, EnchantFormula, CraftAllPlan
do
    local okPlan, plan = Env.call(function()
        local module = RS.Shared.Pets:FindFirstChild("CraftAllPlan")
        return module and require(module)
    end)
    CraftAllPlan = okPlan and type(plan) == "table" and plan or nil
    local ok, config = Env.call(function()
        return require(RS.Shared.Pets.MachineConfig)
    end)
    MachineConfig = ok and type(config) == "table" and config.Golden and config or FALLBACK_CONFIG
    local okMastery, mastery = Env.call(function()
        return require(RS.Shared.Progression.MasteryFormula)
    end)
    Mastery = okMastery and mastery or nil
    local okEnchant, formula = Env.call(function()
        return require(RS.Shared.Pets.EnchantFormula)
    end)
    EnchantFormula = okEnchant and formula or nil
end

-- Where each machine stands; a machine can stand in several places and the nearest one is used.
-- `model` is the machine's model (its pivot is readable once it exists, even far away); `fallback`
-- is where its interaction point was when the hub was written. The Shadow Realm has its own Golden
-- machine beside the Rainbow one and the Void egg, so a hatch-and-craft loop barely moves.
local MACHINES = {
    Golden = { label = "Golden", point = "Golden", places = {
        { model = { "Ts2Islands", "Shadow Realm", "Folder", "GoldenMachine" }, fallback = Vector3.new(47, 7679, -1723) },
        { model = { "GoldenMachine" }, fallback = Vector3.new(14.5, -516, -1885.6) },
    } },
    Diamond = { label = "Diamond", point = "Diamond", places = {
        { model = { "DiamondMachine" }, fallback = Vector3.new(-186.6, 5444.4, -2002.3) },
    } },
    Shiny = { label = "Rainbow", point = "Rainbow", places = {
        { model = { "Ts2Islands", "Shadow Realm", "Folder", "RainbowMachine" }, fallback = Vector3.new(90.7, 7677.6, -1933.5) },
    } },
}
local ORDER = { "Golden", "Diamond", "Shiny" } -- low tier first, so one pass chains upward

local NEVER_FAIL, BEST_VALUE = "Never fail (fewest pets at 100%)", "Best value (fewest pets per success)"
local RAINBOW_SPEEDS = { "5 pets - 30s", "4 pets - 1h", "3 pets - 2.5h", "2 pets - 5h" }
local RAINBOW_COUNT = { ["5 pets - 30s"] = 5, ["4 pets - 1h"] = 4, ["3 pets - 2.5h"] = 3, ["2 pets - 5h"] = 2 }
local RAINBOW_WAIT = 35 -- stay at the machine for a craft finishing this soon instead of flying back later

-- The chance the machine will roll, computed the way the game's own machine screen does.
local function chance(key, count, data)
    local base = MachineConfig[key].Chances[count]
    if type(base) ~= "number" then
        return 0
    end
    if key == "Golden" and Mastery then
        local ok, bonus = Env.call(Mastery.GetBonus, data, "MachineGoldenChance")
        if ok and type(bonus) == "number" then
            base += math.floor(bonus * 100 + 0.5)
        end
    end
    if EnchantFormula then
        local ok, scaled = Env.call(EnchantFormula.ApplyCraftChance, data, base)
        if ok and type(scaled) == "number" then
            return scaled
        end
    end
    return math.clamp(base, 0, 100)
end

-- How many pets go into one Golden or Diamond craft, and the chance that gives.
local function batchSize(key, data)
    local max = #MachineConfig[key].Chances
    if Options.CraftStrategy.Value ~= BEST_VALUE then
        for count = 1, max do
            local roll = chance(key, count, data)
            if roll >= 100 then
                return count, roll
            end
        end
        return max, chance(key, max, data)
    end
    local best, bestCost, bestRoll
    for count = 1, max do
        local roll = chance(key, count, data)
        if roll > 0 then
            local cost = count / (roll / 100)
            -- On a tie the surer roll wins: same pets per success, less variance.
            if not best or cost < bestCost - 1e-9 or (math.abs(cost - bestCost) <= 1e-9 and roll > bestRoll) then
                best, bestCost, bestRoll = count, cost, roll
            end
        end
    end
    return best or max, bestRoll or 0
end

local function rainbowCount()
    return RAINBOW_COUNT[Options.RainbowSpeed.Value] or 5
end

-- Pets of `tier` that may be crafted, grouped by name, each group in the order the game itself
-- sacrifices them: unequipped, unmutated, lowest level, lowest XP.
local function groups(tier, data)
    local equipped = {}
    for _, id in pairs(type(data.Pets.Equipped) == "table" and data.Pets.Equipped or {}) do
        equipped[id] = true
    end
    local never = Options.CraftNever.Value or {}
    local keepEquipped, keepMutated = Ui.on("CraftKeepEquipped"), Ui.on("CraftKeepMutated")
    local byName = {}
    for id, pet in pairs(type(data.Pets.Owned) == "table" and data.Pets.Owned or {}) do
        if type(pet) == "table" and pet.Tier == tier and pet.Locked ~= true and pet.Frozen == nil
            and not never[pet.Name]
            and not (keepEquipped and equipped[id])
            and not (keepMutated and pet.Mutation ~= nil) then
            local group = byName[pet.Name]
            if not group then
                group = { name = pet.Name, entries = {} }
                byName[pet.Name] = group
            end
            group.entries[#group.entries + 1] = { id = id, pet = pet, equipped = equipped[id] == true }
        end
    end
    local list = {}
    for _, group in pairs(byName) do
        table.sort(group.entries, function(a, b)
            if a.equipped ~= b.equipped then
                return not a.equipped
            end
            local mutatedA, mutatedB = a.pet.Mutation ~= nil, b.pet.Mutation ~= nil
            if mutatedA ~= mutatedB then
                return not mutatedA
            end
            local levelA, levelB = a.pet.Level or 1, b.pet.Level or 1
            if levelA ~= levelB then
                return levelA < levelB
            end
            local xpA, xpB = a.pet.XP or 0, b.pet.XP or 0
            if xpA ~= xpB then
                return xpA < xpB
            end
            return tostring(a.id) < tostring(b.id)
        end)
        list[#list + 1] = group
    end
    -- Biggest pile first: that is the one most worth turning into the next tier.
    table.sort(list, function(a, b)
        if #a.entries ~= #b.entries then
            return #a.entries > #b.entries
        end
        return a.name < b.name
    end)
    return list
end

-- The next batch of `count` same-name pet ids for `key`, or nil.
local function nextBatch(key, count, data)
    for _, group in ipairs(groups(MachineConfig[key].SourceTier, data)) do
        if #group.entries >= count then
            local ids = {}
            for index = 1, count do
                ids[index] = group.entries[index].id
            end
            return ids, group.name
        end
    end
    return nil
end

local function rainbowQueue(data)
    local shiny = type(data.Machines) == "table" and data.Machines.Shiny
    local queue = type(shiny) == "table" and type(shiny.Queue) == "table" and shiny.Queue or {}
    local now = workspace:GetServerTimeNow()
    local entries, ready, soonest = 0, {}, nil
    for id, craft in pairs(queue) do
        entries += 1
        local ends = type(craft) == "table" and tonumber(craft.EndTime) or 0
        if ends <= now then
            ready[#ready + 1] = id
        else
            soonest = math.min(soonest or math.huge, ends - now)
        end
    end
    return entries, ready, soonest
end

-- Craft All ------------------------------------------------------------------------------------

-- Craft All unlocks per machine with its mastery ("Reach Goldens Mastery Lv. 4 to unlock Craft
-- All!"). A refusal parks it for that machine a while, so every pass is not one wasted request.
local craftAllBlocked = {} -- machine key -> os.clock() until which single batches are used
local CRAFT_ALL_RETRY = 600

local function useCraftAll(key)
    return CraftAllPlan ~= nil and Options.CraftStrategy.Value ~= BEST_VALUE and os.clock() >= (craftAllBlocked[key] or 0)
end

-- The pet names Craft All may use: every source-tier name outside the "Never craft" list, or nil
-- (all of them) when that list is empty.
local function allowedNames(key, data)
    local never = Options.CraftNever.Value or {}
    if next(never) == nil then
        return nil
    end
    local names, seen = {}, {}
    local tier = MachineConfig[key].SourceTier
    for _, pet in pairs(type(data.Pets.Owned) == "table" and data.Pets.Owned or {}) do
        if type(pet) == "table" and pet.Tier == tier and not never[pet.Name] and not seen[pet.Name] then
            seen[pet.Name] = true
            names[#names + 1] = pet.Name
        end
    end
    return names
end

-- Whether the game's own Craft All plan would make at least one batch right now.
local function craftAllReady(key, data)
    local needed = batchSize(key, data)
    local names = allowedNames(key, data)
    local tier = MachineConfig[key].SourceTier
    local ok, ready = Env.call(function()
        if names == nil then
            return CraftAllPlan.Ready(data, tier, needed)
        end
        local set = {}
        for _, name in ipairs(names) do
            set[name] = true
        end
        local plan = CraftAllPlan.Build(data, tier, needed, set)
        return type(plan) == "table" and type(plan.Batches) == "table" and #plan.Batches > 0
    end)
    return ok and ready == true
end

-- Whether a machine has anything to do right now (checked before flying anywhere).
local function hasWork(key, data)
    if key == "Shiny" then
        local entries, ready = rainbowQueue(data)
        return #ready > 0 or (entries < (MachineConfig.Shiny.MaxQueue or 3) and nextBatch("Shiny", rainbowCount(), data) ~= nil)
    end
    if useCraftAll(key) then
        return craftAllReady(key, data)
    end
    return nextBatch(key, (batchSize(key, data)), data) ~= nil
end

-- Movement -------------------------------------------------------------------------------------

local function root()
    local character = Env.LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function modelPivot(path)
    local node = workspace
    for _, name in ipairs(path) do
        node = node and node:FindFirstChild(name)
    end
    if not node then
        return nil
    end
    local ok, pivot = pcall(node.GetPivot, node)
    return ok and pivot.Position or nil
end

local function findPoint(name, near)
    local best, bestDistance
    local function consider(part)
        if part and part:IsA("BasePart") and part.Name == name then
            local distance = (part.Position - near).Magnitude
            if distance < 400 and (not best or distance < bestDistance) then
                best, bestDistance = part, distance
            end
        end
    end
    for _, part in ipairs(Env.CollectionService:GetTagged("InteractionPoint")) do
        consider(part)
    end
    local folder = workspace:FindFirstChild("InteractionPoints")
    consider(folder and folder:FindFirstChild(name))
    return best
end

local function teleport(cframe)
    local hrp = root()
    if not hrp then
        return false
    end
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.CFrame = cframe
    return true
end

-- Stands in a machine's interaction point, trying its places nearest first. False when none of
-- them streamed in.
local function goTo(def)
    local hrp = root()
    if not hrp then
        return false
    end
    local here = hrp.Position
    local places = {}
    for _, place in ipairs(def.places) do
        places[#places + 1] = modelPivot(place.model) or place.fallback
    end
    table.sort(places, function(a, b)
        return (a - here).Magnitude < (b - here).Magnitude
    end)
    for _, target in ipairs(places) do
        local point = findPoint(def.point, target)
        if not point then
            pcall(function()
                Env.LocalPlayer:RequestStreamAroundAsync(target, 10)
            end)
            Env.elevate()
            if not teleport(CFrame.new(target + Vector3.new(0, 6, 0))) then
                return false
            end
            local deadline = os.clock() + 8
            while Life.alive and os.clock() < deadline and not point do
                Life.wait(0.2)
                point = findPoint(def.point, target)
            end
        end
        if point then
            teleport(point.CFrame)
            Life.wait(0.35) -- give the server a beat to see us inside before the first request
            return true
        end
    end
    return false
end

-- Requests -------------------------------------------------------------------------------------

-- One machine request at a time, answered on MachineCraftResult, the way the machine screen does.
local waiting
Life.spawn("craft:results", function()
    local remote = Env.remote("MachineService", "MachineCraftResult")
    Life.connect(remote.OnClientEvent, function(payload)
        if waiting and type(payload) == "table" and payload.Machine == waiting.machine then
            waiting.result = payload
        end
    end, "craft:result")
end)

local function request(machine, payload)
    local slot = { machine = machine }
    waiting = slot
    Env.fire("MachineService", "MachineCraftRequested", payload)
    local deadline = os.clock() + 6
    while Life.alive and not slot.result and os.clock() < deadline do
        Life.wait(0.05)
    end
    if waiting == slot then
        waiting = nil
    end
    return slot.result
end

local function tooFar(result)
    return type(result) == "table" and string.find(string.lower(tostring(result.Reason or "")), "near", 1, true) ~= nil
end

-- UI -------------------------------------------------------------------------------------------

local box = tab:AddGroupbox({ Side = "Left", Name = "Pet machines", IconName = "hammer" })
box:AddToggle("AutoCraft", {
    Text = "Auto craft pets",
    Default = false,
    Tooltip = "Turns duplicates into Golden, Golden into Diamond and Diamond into Rainbow pets. Teleports to each machine that has work and brings you back.",
})
Ui.automation("AutoCraft")
box:AddDropdown("CraftMachines", {
    Text = "Machines",
    Values = { "Golden", "Diamond", "Rainbow" },
    Multi = true,
    Default = { "Golden", "Diamond", "Rainbow" },
})
box:AddDropdown("CraftStrategy", {
    Text = "Golden / Diamond",
    Values = { NEVER_FAIL, BEST_VALUE },
    Default = NEVER_FAIL,
    Tooltip = "A failed roll destroys every pet put in. 'Never fail' uses the fewest pets that already reach 100%. 'Best value' gambles when that costs fewer pets per success on average.",
})
box:AddDropdown("RainbowSpeed", {
    Text = "Rainbow",
    Values = RAINBOW_SPEEDS,
    Default = RAINBOW_SPEEDS[1],
    Tooltip = "Pets per Rainbow craft. 5 finishes in 30 seconds; 2 uses fewer Diamonds but takes five hours.",
})
box:AddToggle("CraftKeepEquipped", {
    Text = "Keep equipped pets",
    Default = true,
    Tooltip = "Never puts a pet from your team into a machine. In 'Never fail' the game's Craft All keeps equipped, team, locked, mutated, enchanted and Secret pets anyway.",
})
box:AddToggle("CraftKeepMutated", {
    Text = "Keep mutated pets",
    Default = true,
})
box:AddDropdown("CraftNever", {
    Text = "Never craft",
    Values = {},
    Multi = true,
    Searchable = true,
    Default = {},
    Tooltip = "Pets that are never put into a machine, whatever their tier.",
})
box:AddSlider("CraftEvery", {
    Text = "Check every",
    Default = 10,
    Min = 3,
    Max = 120,
    Rounding = 0,
    Suffix = "s",
})
box:AddToggle("CraftReturn", {
    Text = "Return to where I was",
    Default = true,
})

local statusBox = tab:AddGroupbox({ Side = "Right", Name = "Crafting", IconName = "activity" })
local panel = Ui.panel(statusBox, 5)

-- The "Never craft" list follows the pets you own.
local nameSignature
Life.loop("craft:names", 5, function()
    local data = Env.data()
    if not data or type(data.Pets) ~= "table" then
        return
    end
    local seen, names = {}, {}
    for _, pet in pairs(type(data.Pets.Owned) == "table" and data.Pets.Owned or {}) do
        if type(pet) == "table" and type(pet.Name) == "string" and not seen[pet.Name] then
            seen[pet.Name] = true
            names[#names + 1] = pet.Name
        end
    end
    table.sort(names)
    local joined = table.concat(names, "\0")
    if joined ~= nameSignature then
        nameSignature = joined
        Env.elevate()
        Options.CraftNever:SetValues(names)
    end
end)

-- Passes ---------------------------------------------------------------------------------------

local session = { Golden = 0, Diamond = 0, Shiny = 0, failed = 0 }
local lastNote = "Idle."
local busy = false

local function machineOn(key)
    local picked = Options.CraftMachines.Value or {}
    return picked[MACHINES[key].label] == true
end

local function keepGoing(manual)
    return Life.alive and (manual or Ui.on("AutoCraft"))
end

-- Every Golden or Diamond batch there is, at that machine: Craft All requests (60 batches each)
-- in "Never fail", single batches in "Best value" or if the server refuses Craft All this pass.
local function runTier(key, manual)
    local def = MACHINES[key]
    local arrived, retried = false, false
    local craftAll = useCraftAll(key)
    while keepGoing(manual) do
        local data = Env.data()
        if not data then
            return
        end
        local count, roll = batchSize(key, data)
        local ids, name
        if craftAll then
            if not craftAllReady(key, data) then
                return
            end
        else
            ids, name = nextBatch(key, count, data)
            if not ids then
                return
            end
        end
        if not arrived then
            Ui.status = "Going to the " .. def.label .. " machine"
            if not goTo(def) then
                lastNote = def.label .. " machine did not load; will try again next pass."
                return
            end
            arrived = true
        end
        local result
        if craftAll then
            Ui.status = string.format("Crafting all at the %s machine (%d per craft)", def.label, count)
            result = request(key, { Action = "CraftAll", Machine = key, Names = allowedNames(key, data) })
        else
            Ui.status = string.format("Crafting %s x%d at %d%%", name, count, roll)
            result = request(key, { Action = "Craft", Machine = key, PetIds = ids })
        end
        if not result then
            lastNote = def.label .. ": the server did not answer."
            return
        end
        if result.Success then
            if craftAll then
                local made = tonumber(result.Crafted) or (result.Crafted and 1) or 0
                session[key] += made
                if made <= 0 then
                    return -- the plan said yes but nothing was made: do not spin on it
                end
            elseif result.Crafted then
                session[key] += 1
            else
                session.failed += 1
            end
        elseif tooFar(result) and not retried then
            retried, arrived = true, false
        elseif craftAll then
            lastNote = string.format("%s: %s Crafting single batches meanwhile.", def.label, tostring(result.Reason or "Craft All refused."))
            craftAllBlocked[key] = os.clock() + CRAFT_ALL_RETRY
            craftAll = false
        else
            lastNote = def.label .. ": " .. tostring(result.Reason or "refused")
            return
        end
        Life.wait(0.15)
    end
end

-- Claims finished Rainbows and keeps the queue full, staying for crafts that are nearly done.
local function runRainbow(manual)
    local def = MACHINES.Shiny
    local arrived = false
    local maxQueue = MachineConfig.Shiny.MaxQueue or 3
    while keepGoing(manual) do
        local data = Env.data()
        if not data then
            return
        end
        local entries, ready, soonest = rainbowQueue(data)
        local count = rainbowCount()
        local ids, name = nextBatch("Shiny", count, data)
        local canStart = ids ~= nil and entries < maxQueue
        if #ready == 0 and not canStart then
            -- Nothing to claim or start: wait here only if a craft is about to finish, and only when
            -- auto hatch is off -- otherwise hatching is worth more than the wait, and a later pass
            -- comes back for the claim.
            if not (arrived and soonest and soonest <= RAINBOW_WAIT and keepGoing(manual) and not Ui.on("AutoHatch")) then
                return
            end
            Ui.status = string.format("Waiting %ds for a Rainbow", math.ceil(soonest))
            Life.wait(math.min(soonest + 0.5, RAINBOW_WAIT))
            continue
        end
        if not arrived then
            Ui.status = "Going to the Rainbow machine"
            if not goTo(def) then
                lastNote = "Rainbow machine did not load; will try again next pass."
                return
            end
            arrived = true
        end
        if #ready > 0 then
            local result = request("Shiny", { Machine = "Shiny", Action = "Claim", CraftId = ready[1] })
            if result and result.Success then
                session.Shiny += 1
            elseif result then
                lastNote = "Rainbow claim: " .. tostring(result.Reason or "refused")
                return
            else
                lastNote = "Rainbow: the server did not answer."
                return
            end
        elseif canStart then
            Ui.status = string.format("Starting Rainbow %s x%d", name, count)
            local result = request("Shiny", { Machine = "Shiny", Action = "Start", PetIds = ids })
            if not (result and result.Success) then
                lastNote = "Rainbow start: " .. tostring(result and result.Reason or "no answer")
                return
            end
        end
        Life.wait(0.2)
    end
end

local function runPass(manual)
    -- Auto hatch walking to its egg, or an enchant trip, owns the character until it is done.
    if busy or Ui.hatchMoving or Ui.travelling then
        return
    end
    local data = Env.data()
    if not data or type(data.Pets) ~= "table" then
        return
    end
    local work = {}
    if manual or Ui.on("AutoCraft") then
        for _, key in ipairs(ORDER) do
            if machineOn(key) and hasWork(key, data) then
                work[#work + 1] = key
            end
        end
    end
    if #work == 0 then
        return
    end
    busy = true
    Ui.travelling = true -- auto hatch sends nothing new from here on
    local settle = os.clock() + 6
    while Ui.hatchInFlight and os.clock() < settle do
        Life.wait(0.05)
    end
    local hrp = root()
    local home = hrp and hrp.CFrame
    local ok, err = pcall(function()
        -- The whole order, not just `work`: Golden crafted this pass can give Diamond its batch.
        for _, key in ipairs(ORDER) do
            if machineOn(key) and keepGoing(manual) then
                if key == "Shiny" then
                    runRainbow(manual)
                else
                    runTier(key, manual)
                end
            end
        end
    end)
    Env.elevate()
    if not ok then
        Life.errors["craft:pass"] = tostring(err)
    end
    if home and Ui.on("CraftReturn") then
        teleport(home)
    end
    Ui.travelling = false
    busy = false
    if Ui.status and (Ui.status:find("Crafting") or Ui.status:find("machine") or Ui.status:find("Rainbow")) then
        Ui.status = "Idle"
    end
end

box:AddButton({
    Text = "Craft everything now",
    Func = function()
        Life.spawn("craft:manual", runPass, true)
    end,
})

Life.spawn("craft:auto", function()
    local last = -math.huge
    while Life.alive do
        local every = math.clamp(tonumber(Options.CraftEvery.Value) or 10, 3, 120)
        if Ui.on("AutoCraft") and os.clock() - last >= every then
            last = os.clock()
            runPass(false)
        end
        Life.wait(0.5)
    end
end)

-- What each machine would do with the pets you have right now.
Life.loop("craft:panel", 1, function()
    local data = Env.data()
    if not data or type(data.Pets) ~= "table" then
        panel.set({ "Waiting for your data..." })
        return
    end
    local lines = {}
    for _, key in ipairs({ "Golden", "Diamond" }) do
        local count, roll = batchSize(key, data)
        local batches = 0
        for _, group in ipairs(groups(MachineConfig[key].SourceTier, data)) do
            batches += math.floor(#group.entries / count)
        end
        lines[#lines + 1] = string.format("%s: %d pets per craft at %d%%, %d crafts available", key, count, roll, batches)
    end
    local entries, ready, soonest = rainbowQueue(data)
    local count = rainbowCount()
    local batches = 0
    for _, group in ipairs(groups(MachineConfig.Shiny.SourceTier, data)) do
        batches += math.floor(#group.entries / count)
    end
    lines[#lines + 1] = string.format("Rainbow: queue %d/%d, %d ready%s, %d crafts available", entries,
        MachineConfig.Shiny.MaxQueue or 3, #ready, soonest and string.format(", next in %ds", math.ceil(soonest)) or "", batches)
    lines[#lines + 1] = string.format("Session: %d Golden, %d Diamond, %d Rainbow, %d failed rolls",
        session.Golden, session.Diamond, session.Shiny, session.failed)
    lines[#lines + 1] = lastNote
    panel.set(lines, busy and "Crafting now..." or "")
end)

Life.onCleanup(function()
    Ui.travelling = false
end)

return {}
end
__modules["features/defense"] = function(use) -- src/games/tapsim/features/defense.luau
-- Rewards tab: Pet Defense, the wave defense on Mushroom island (ColosseumService in the game's
-- code). Pets walk three tracks toward your bone pit; a tap hits the one closest to it, and every
-- few seconds a critical does 10x damage and pushes it back. Three escapes end the run. Every
-- cleared wave raises the relic you win (a ring with click multiplier and other boosts) and adds
-- treats, dials and, from wave 11, totems. One run every 30 minutes (Data.Colosseum.Cooldown).
--
-- A run is played through the game's own Pet Defense screen so you can watch it:
--   start     the controller's WaveDefenseForceStart handler (its attemptStartGame: the arena door,
--             StartWaveDefense, the board, the critical buttons). It needs you at the arena
--             entrance, so the hub stands you there first; the server then puts you in the arena.
--   taps      ColosseumClientAdapter.Signals "PlayerTapped", the game's own tap button: it picks
--             the pet closest to the pit, keeps the game's 0.14s tap cooldown and shows the hit.
--   critical  the critical button the game spawns every 5-10 seconds, pressed through its own
--             handler.
-- Without getconnections the same run is played on the remotes directly (StartWaveDefense,
-- AttackOpponent, CriticalAttackOpponent), and the fight is not drawn.
--
-- When the run ends the pending reward is claimed: ClaimMinigameReward "replace" takes the new
-- relic, "keep" keeps yours, and the treats and items come either way.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local Options = Ui.Options
local RS = Env.ReplicatedStorage
local tab = Ui.Tabs.Rewards

local COOLDOWN = 1800
local TAP_GAP = 0.15 -- the game's own cooldown is ClickCooldown - grace + 0.02 = 0.14s
local RUN_LIMIT = 20 * 60
local ENTRANCE_FALLBACK = Vector3.new(-170, 2020, -1795)
local RING_ORDER = { BronzeRing = 1, SilverRing = 2, GoldRing = 3, PlatinumRing = 4, DiamondRing = 5 }

local function load(...)
    local path = { ... }
    local ok, module = Env.call(function()
        local node = RS
        for _, part in ipairs(path) do
            node = node:FindFirstChild(part)
        end
        return node and require(node)
    end)
    return ok and type(module) == "table" and module or nil
end

local World = load("Shared", "Minigames", "ColosseumWorld")
local Adapter = load("Controllers", "Minigames", "ColosseumClientAdapter")

local KEEP_BETTER, LET_ME = "Keep the better ring", "Let me choose"
local box = tab:AddGroupbox({ Side = "Left", Name = "Pet Defense", IconName = "shield" })
box:AddToggle("AutoDefense", {
    Text = "Auto Pet Defense",
    Default = false,
    Tooltip = "Plays Pet Defense on Mushroom island every 30 minutes, to the last heart, and comes back. Auto hatch pauses while a run lasts (a few minutes).",
})
Ui.automation("AutoDefense", false)
box:AddSlider("DefenseStopAt", {
    Text = "Stop at wave",
    Default = 0,
    Min = 0,
    Max = 60,
    Rounding = 0,
    Tooltip = "0 plays until the last heart. A lower stop banks the run sooner (the relic is rolled from the wave you reach).",
})
box:AddDropdown("DefenseRelic", {
    Text = "New relic",
    Values = { KEEP_BETTER, LET_ME },
    Default = KEEP_BETTER,
    Tooltip = "Keep the better ring: a higher ring wins (Bronze, Silver, Gold, Platinum, Diamond), then the bigger click multiplier. Let me choose leaves the game's reward screen open.",
})
box:AddToggle("DefenseReturn", {
    Text = "Return to where I was",
    Default = true,
})
local label = box:AddLabel("Auto Pet Defense is off.", true)

local session = { runs = 0, best = 0, last = nil, note = "" }

local function colosseum(data)
    return data and type(data.Colosseum) == "table" and data.Colosseum or {}
end

local function readyIn(data)
    local cooldown = tonumber(colosseum(data).Cooldown) or 0
    return math.max(0, cooldown + COOLDOWN - os.time())
end

local function root()
    local character = Env.LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

-- The game's own handler on one of its remotes (ReplicatedStorage code, not the hub's).
local function gameHandler(signal)
    if type(getconnections) ~= "function" then
        return nil
    end
    local ok, connections = pcall(getconnections, signal)
    for _, connection in ipairs(ok and type(connections) == "table" and connections or {}) do
        local fine, source = pcall(function()
            return connection.Function and debug.info(connection.Function, "s")
        end)
        if fine and type(source) == "string" and source:find("^ReplicatedStorage%.") then
            return connection.Function
        end
    end
    return nil
end

local function standAtEntrance()
    local hrp = root()
    if not hrp then
        return false
    end
    local entrance = World and World.GetEntrance()
    if not entrance then
        pcall(function()
            Env.LocalPlayer:RequestStreamAroundAsync(ENTRANCE_FALLBACK, 10)
        end)
        Env.elevate()
        hrp.CFrame = CFrame.new(ENTRANCE_FALLBACK + Vector3.new(0, 4, 0))
        local deadline = os.clock() + 8
        while Life.alive and not entrance and os.clock() < deadline do
            Life.wait(0.2)
            entrance = World and World.GetEntrance()
        end
    end
    if not entrance then
        return false
    end
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.CFrame = entrance.CFrame + Vector3.new(0, 3, 0)
    Life.wait(0.8)
    return true
end

-- The game's Pet Defense screens. Its wave events show the wave board whether or not its own
-- controller started the run, and only that controller hides it again, so a run it did not draw
-- (the direct mode, a run cut short) would leave the board over the screen. Outside a run the
-- game has these off.
local SCREENS = { "WaveDefense", "WaveStartMessage" }
local function clearScreens()
    if Env.LocalPlayer:GetAttribute("ColosseumActive") == true then
        return
    end
    local gui = Env.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    for _, name in ipairs(SCREENS) do
        local screen = gui and gui:FindFirstChild(name)
        if screen and screen:IsA("ScreenGui") and screen.Enabled then
            screen.Enabled = false
        end
    end
end

-- The run, as the server tells it.
local run
local function newRun()
    return { active = true, over = false, wave = 0, hearts = 3, opponents = {}, result = nil }
end

Life.spawn("defense:events", function()
    local function on(name, handler)
        Life.connect(Env.remote("ColosseumService", name).OnClientEvent, function(payload)
            if run and type(payload) == "table" then
                handler(payload)
            end
        end)
    end
    on("WaveDefenseOpponentSpawned", function(opponent)
        if opponent.Id ~= nil then
            run.opponents[opponent.Id] = opponent
        end
    end)
    on("WaveDefenseOpponentDefeated", function(event)
        run.opponents[event.OpponentId] = nil
    end)
    on("WaveDefenseHeartLost", function(event)
        run.opponents[event.OpponentId] = nil
        run.hearts = tonumber(event.Hearts) or run.hearts
    end)
    on("WaveDefenseWaveComplete", function(event)
        run.wave = tonumber(event.WaveCompleted) or run.wave
        run.hearts = tonumber(event.Hearts) or run.hearts
    end)
    on("WaveDefenseGameOver", function(event)
        run.over = true
        run.result = event
    end)
end)

-- The pet nearest the pit, for the direct mode.
local function urgent()
    local now = workspace:GetServerTimeNow()
    local best
    for _, opponent in pairs(run.opponents) do
        if (tonumber(opponent.SpawnTime) or 0) <= now
            and (not best or (tonumber(opponent.ArrivalTime) or math.huge) < (tonumber(best.ArrivalTime) or math.huge)) then
            best = opponent
        end
    end
    return best
end

-- Presses the game's critical button if one is up: "pressed", "none", or "unreachable" when its
-- handler cannot be read (the run then sends criticals itself).
local function pressCritical()
    local gui = Env.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local hud = gui and gui:FindFirstChild("WaveDefense")
    local criticals = hud and hud:FindFirstChild("WaveHUD") and hud.WaveHUD:FindFirstChild("Criticals")
    local active = criticals and criticals:FindFirstChild("CriticalActive")
    local button = active and active:FindFirstChild("Button")
    if not button then
        return "none"
    end
    local handler = gameHandler(button.Activated)
    if handler then
        Life.spawn("defense:critical", handler)
        return "pressed"
    end
    return "unreachable"
end

local function attackDirect(critical)
    local target = urgent()
    if not target then
        return
    end
    local ok, result = Env.invoke("ColosseumService", critical and "CriticalAttackOpponent" or "AttackOpponent", target.Id)
    if ok and type(result) == "table" then
        if result.Defeated then
            run.opponents[target.Id] = nil
        elseif result.NewArrivalTime then
            target.ArrivalTime = result.NewArrivalTime
        end
    end
end

-- Plays one run to its end. Returns true when it was played.
local function playRun()
    local forceStart = gameHandler(Env.remote("ColosseumService", "WaveDefenseForceStart").OnClientEvent)
    local visual = forceStart ~= nil and Adapter ~= nil and type(Adapter.Signals) == "table"
    run = newRun()
    if visual then
        Life.spawn("defense:start", forceStart)
        local deadline = os.clock() + 15
        while Life.alive and os.clock() < deadline and Env.LocalPlayer:GetAttribute("ColosseumActive") ~= true do
            Life.wait(0.2)
        end
        if Env.LocalPlayer:GetAttribute("ColosseumActive") ~= true then
            session.note = "The game did not start the run."
            run = nil
            return false
        end
    else
        local ok, start = Env.invoke("ColosseumService", "StartWaveDefense")
        if not ok or type(start) ~= "table" or start.Error or start.OnCooldown then
            session.note = "Start refused: " .. tostring(type(start) == "table" and (start.Error or "on cooldown") or start)
            run = nil
            return false
        end
        run.hearts = tonumber(start.Hearts) or 3
        for _, opponent in ipairs(type(start.PendingSpawns) == "table" and start.PendingSpawns or {}) do
            if opponent.Id ~= nil then
                run.opponents[opponent.Id] = opponent
            end
        end
    end
    Ui.status = "Playing Pet Defense"
    local started = os.clock()
    local nextCritical = os.clock() + 5 + math.random() * 3
    local ownCriticals = not visual
    while Life.alive and not run.over and os.clock() - started < RUN_LIMIT do
        local stopAt = tonumber(Options.DefenseStopAt.Value) or 0
        if not Ui.on("AutoDefense") or (stopAt > 0 and run.wave >= stopAt) then
            Env.invoke("ColosseumService", "EndWaveDefense")
            break
        end
        if visual then
            Env.call(Adapter.Signals.Fire, "PlayerTapped")
            if pressCritical() == "unreachable" then
                ownCriticals = true
            end
        end
        if ownCriticals and os.clock() >= nextCritical then
            nextCritical = os.clock() + 5 + math.random() * 3
            attackDirect(true)
        elseif not visual then
            attackDirect(false)
        end
        if not visual then
            clearScreens() -- a board with no pets on it is only in the way
        end
        Life.wait(TAP_GAP)
    end
    if not run.over and os.clock() - started >= RUN_LIMIT then
        Env.invoke("ColosseumService", "EndWaveDefense")
    end
    local deadline = os.clock() + 8
    while Life.alive and not run.over and os.clock() < deadline do
        Life.wait(0.2)
    end
    local reached = tonumber(type(run.result) == "table" and run.result.WavesCompleted) or run.wave
    session.runs += 1
    session.best = math.max(session.best, reached)
    session.last = reached
    if not visual then
        Env.invoke("ColosseumService", "ReturnFromArena")
    end
    run = nil
    return true
end

-- A ring's worth: its tier first, then its click multiplier, then everything else it gives.
local function ringScore(relic)
    if type(relic) ~= "table" then
        return -1
    end
    local click, rest = 0, 0
    for _, boost in ipairs(type(relic.Boosts) == "table" and relic.Boosts or {}) do
        local value = tonumber(boost.Value) or 0
        if boost.Type == "ClickMultiplier" then
            click += value
        else
            rest += value
        end
    end
    return (RING_ORDER[relic.Name] or 0) * 1000 + click * 100 + rest
end

local function claimReward()
    if Options.DefenseRelic.Value == LET_ME then
        return
    end
    local deadline = os.clock() + 10
    local pending
    repeat
        pending = colosseum(Env.data()).PendingReward
        if not pending then
            Life.wait(0.3)
        end
    until pending or not Life.alive or os.clock() > deadline
    if type(pending) ~= "table" then
        return
    end
    local current = colosseum(Env.data()).Relic
    local choice = ringScore(pending.NewRelic) > ringScore(current) and "replace" or "keep"
    local ok, result = Env.invoke("ColosseumService", "ClaimMinigameReward", choice)
    if ok and result then
        local relic = type(pending.NewRelic) == "table" and pending.NewRelic.Name or "relic"
        session.note = choice == "replace" and ("Took the new " .. tostring(relic) .. ".")
            or ("Kept your ring over the new " .. tostring(relic) .. ".")
    else
        session.note = "Reward claim refused; it is waiting in the game's reward screen."
    end
end

local busy = false
local function trip()
    if busy or Ui.hatchMoving or Ui.travelling then
        return
    end
    busy = true
    Ui.travelling = "defense"
    local settle = os.clock() + 6
    while Ui.hatchInFlight and os.clock() < settle do
        Life.wait(0.05)
    end
    local hrp = root()
    local home = hrp and hrp.CFrame
    local ok, err = pcall(function()
        Ui.status = "Going to Pet Defense"
        if not standAtEntrance() then
            session.note = "Could not reach the Pet Defense arena."
            return
        end
        if playRun() then
            Life.wait(3) -- the game's own end screen and its trip out of the arena
            claimReward()
        end
    end)
    Env.elevate()
    if not ok then
        Life.errors["defense:trip"] = tostring(err)
        session.note = "Pet Defense error: " .. tostring(err)
    end
    run = nil
    -- The game's end screen runs ~4s (banner, fade, its trip out of the arena); then nothing of the
    -- run may stay on screen.
    local settled = os.clock() + 6
    while Life.alive and Env.LocalPlayer:GetAttribute("ColosseumActive") == true and os.clock() < settled do
        Life.wait(0.2)
    end
    clearScreens()
    if home and Ui.on("DefenseReturn") then
        local back = root()
        if back then
            back.AssemblyLinearVelocity = Vector3.zero
            back.CFrame = home
        end
    end
    if Ui.status == "Playing Pet Defense" or Ui.status == "Going to Pet Defense" then
        Ui.status = "Idle"
    end
    Ui.travelling = false
    busy = false
end

local nextTry = 0
Life.loop("defense:auto", 1, function()
    local data = Env.data()
    if not data then
        return
    end
    -- Leftovers from a run that was not drawn (an older hub, a cut-short run) are cleared outside
    -- a run, whether or not auto Pet Defense is on.
    if not busy then
        clearScreens()
    end
    local wait = readyIn(data)
    local best = tonumber(colosseum(data).BestWave) or 0
    local lines = {}
    if run then
        lines[1] = string.format("Wave %d, %d hearts left.", run.wave + 1, run.hearts)
    elseif wait > 0 then
        lines[1] = string.format("Next run in %d:%02d. Best wave %d.", wait // 60, wait % 60, best)
    else
        lines[1] = string.format("A run is ready. Best wave %d.", best)
    end
    if session.runs > 0 then
        lines[#lines + 1] = string.format("%d runs this session, last reached wave %d.", session.runs, session.last or 0)
    end
    if session.note ~= "" then
        lines[#lines + 1] = session.note
    end
    if not Ui.on("AutoDefense") then
        label:SetText("Off. " .. table.concat(lines, "\n"))
        return
    end
    label:SetText(table.concat(lines, "\n"))
    -- A reward left from an earlier run (or one played by hand) is claimed where you stand.
    if colosseum(data).PendingReward and not busy and not run and Options.DefenseRelic.Value ~= LET_ME
        and os.clock() >= nextTry then
        nextTry = os.clock() + 30
        Life.spawn("defense:claim", claimReward)
        return
    end
    if wait == 0 and not busy and os.clock() >= nextTry and not colosseum(data).PendingReward then
        nextTry = os.clock() + 60 -- a refused start is not retried at once
        Life.spawn("defense:trip", trip)
    end
end)

Life.onCleanup(function()
    if busy then
        Ui.travelling = false
    end
end)

return {}
end
__modules["features/dig"] = function(use) -- src/games/tapsim/features/dig.luau
-- Rewards tab: the Autumn island dig site. Ten digs an hour, each a timing game: a cursor sweeps a
-- bar and a hit inside the highlighted zone takes one layer off the buried treat (RegularTreat or
-- BagOfTreats); a miss puts two back.
--
-- DigService.Begin() starts a dig (or resumes the treat already buried for you) and answers with
-- the round: Epoch, Phase, Speed, Center, Width and a Sequence. Hit(Id, Sequence, time) is judged
-- at that server time with the game's own DigConfig.Cursor, so the hit is timed for the moment the
-- cursor crosses the middle of the zone, never sooner than MinHitInterval after the last one. The
-- server only accepts hits from someone standing on the dig site (DigWorld.Contains), so a dig is
-- a trip like a craft: auto hatch pauses, the dig runs, and you go back where you were.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local RunService = game:GetService("RunService")
local tab = Ui.Tabs.Rewards

local DigConfig, DigWorld
do
    local ok, config = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Minigames.DigConfig)
    end)
    DigConfig = ok and type(config) == "table" and config or nil
    local ok2, world = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Minigames.DigWorld)
    end)
    DigWorld = ok2 and type(world) == "table" and world or nil
end

-- The dig site is Persistent for streaming once loaded, but a fresh server may not have sent it.
local SITE_FALLBACK = Vector3.new(-82, 873, -1623)
-- How close to the zone's middle a hit aims, as a share of its width; the zone shrinks as the
-- cursor speeds up, so the middle leaves room for the request's travel time.
local AIM = { 0.25, 0.6, 1 }

local box = tab:AddGroupbox({ Side = "Right", Name = "Dig site", IconName = "shovel" })
box:AddToggle("AutoDig", {
    Text = "Auto dig",
    Default = false,
    Tooltip = "Goes to the Autumn dig site whenever a dig is free (10 an hour), plays it without missing, and comes back. Each dig gives a Treat or a Bag of Treats.",
})
Ui.automation("AutoDig", false)
box:AddToggle("DigReturn", {
    Text = "Return to where I was",
    Default = true,
})
local label = box:AddLabel("Auto dig is off.", true)

local function root()
    local character = Env.LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function digging(data)
    return data and type(data.Digging) == "table" and data.Digging or nil
end

-- Digs left this hour and seconds until the hour resets.
local function allowance(data)
    local state = digging(data)
    if not (state and DigConfig) then
        return 0, 0
    end
    local ok, left, wait = Env.call(DigConfig.Allowance, state, os.time())
    if ok and type(left) == "number" then
        return left, tonumber(wait) or 0
    end
    return 0, 0
end

local function digZone()
    local site = DigWorld and DigWorld.GetSite()
    return site and site:FindFirstChild("DigZone")
end

local function standOnSite()
    local hrp = root()
    if not hrp then
        return false
    end
    local zone = digZone()
    if not zone then
        pcall(function()
            Env.LocalPlayer:RequestStreamAroundAsync(SITE_FALLBACK, 10)
        end)
        Env.elevate()
        hrp.CFrame = CFrame.new(SITE_FALLBACK + Vector3.new(0, 4, 0))
        local deadline = os.clock() + 8
        while Life.alive and not zone and os.clock() < deadline do
            Life.wait(0.2)
            zone = digZone()
        end
    end
    if not zone then
        return false
    end
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.CFrame = zone.CFrame * CFrame.new(0, 3, 0)
    local deadline = os.clock() + 3
    while Life.alive and os.clock() < deadline do
        Life.wait(0.15)
        local character = Env.LocalPlayer.Character
        if character and DigWorld.Contains(zone, character) then
            Life.wait(0.3) -- let the server see us there too
            return true
        end
    end
    return false
end

-- The first server time after `from` at which the cursor is within `share` of the zone's middle.
local function aimAt(round, from)
    for _, share in ipairs(AIM) do
        local half = round.Width * share / 2
        for t = from, from + 8, 0.004 do
            if math.abs(DigConfig.Cursor(round, t) - round.Center) <= half then
                return t
            end
        end
    end
    return nil
end

local session = { digs = 0, hits = 0, misses = 0, treats = {} }
local note = ""

-- Plays one dig to the end. Returns the reward name, or nil and why not. A dig that stops early is
-- cancelled, as the game's Stop button does; the treat stays buried for the next one.
local function playDig()
    local ok, state = Env.invoke("DigService", "Begin")
    if not ok or type(state) ~= "table" then
        return nil, "the dig did not start"
    end
    local id = state.Id
    local function stop(why)
        if id then
            Env.invoke("DigService", "Cancel", id)
        end
        return nil, why
    end
    local lastHit = workspace:GetServerTimeNow()
    for _ = 1, 60 do
        if not Life.alive then
            return stop("unloaded")
        end
        if state.Complete then
            return tostring(state.Reward or "a treat")
        end
        if state.Error then
            return stop(tostring(state.Error))
        end
        local round = state.Round
        if type(round) ~= "table" or not state.Id then
            return stop("unexpected answer from the dig site")
        end
        id = state.Id
        local from = math.max(workspace:GetServerTimeNow() + 0.06, round.Epoch + 0.02,
            lastHit + DigConfig.MinHitInterval + 0.02)
        local target = aimAt(round, from)
        if not target then
            return stop("no hit window found")
        end
        while workspace:GetServerTimeNow() < target do
            RunService.Heartbeat:Wait()
        end
        local at = workspace:GetServerTimeNow()
        if DigConfig.IsHit(round, at) then
            session.hits += 1
        else
            session.misses += 1
        end
        lastHit = at
        local ok2, answer = Env.invoke("DigService", "Hit", id, round.Sequence, at)
        if not ok2 or type(answer) ~= "table" then
            return stop("a hit got no answer")
        end
        if answer.Error == "TooSoon" or answer.Error == "Busy" then
            Life.wait(0.2) -- same round again
        else
            state = answer
        end
    end
    return stop("the dig never finished")
end

local busy = false
local function digTrip()
    if busy or Ui.hatchMoving or Ui.travelling then
        return
    end
    busy = true
    Ui.travelling = "dig"
    local settle = os.clock() + 6
    while Ui.hatchInFlight and os.clock() < settle do
        Life.wait(0.05)
    end
    local hrp = root()
    local home = hrp and hrp.CFrame
    local ok, err = pcall(function()
        Ui.status = "Digging"
        if not standOnSite() then
            note = "Could not reach the dig site."
            return
        end
        while Life.alive and Ui.on("AutoDig") and allowance(Env.data()) > 0 do
            local reward, why = playDig()
            if not reward then
                note = "Last dig stopped: " .. tostring(why) .. "."
                break
            end
            session.digs += 1
            session.treats[reward] = (session.treats[reward] or 0) + 1
            note = "Last dig: " .. reward .. "."
            Life.wait(0.6)
        end
    end)
    Env.elevate()
    if not ok then
        Life.errors["dig:trip"] = tostring(err)
        note = "Dig error: " .. tostring(err)
    end
    if home and Ui.on("DigReturn") then
        local back = root()
        if back then
            back.AssemblyLinearVelocity = Vector3.zero
            back.CFrame = home
        end
    end
    if Ui.status == "Digging" then
        Ui.status = "Idle"
    end
    Ui.travelling = false
    busy = false
end

local nextTry = 0
Life.loop("dig:auto", 1, function()
    local data = Env.data()
    local left, wait = allowance(data)
    local pending = digging(data) and digging(data).PendingReward
    local parts = {}
    for name, count in pairs(session.treats) do
        parts[#parts + 1] = string.format("%d %s", count, name)
    end
    table.sort(parts)
    local status = left > 0 and string.format("%d digs free now", left)
        or string.format("next digs in %dm %02ds", math.floor(wait / 60), math.floor(wait % 60))
    local summary = string.format("%s. %d digs this session%s (%d hits, %d misses).%s%s", status, session.digs,
        #parts > 0 and (": " .. table.concat(parts, ", ")) or "", session.hits, session.misses,
        pending and ("\nBuried for you: " .. tostring(pending) .. ".") or "", note ~= "" and ("\n" .. note) or "")
    if not (DigConfig and DigWorld) then
        label:SetText("The game's dig config could not be read.")
        return
    end
    if not Ui.on("AutoDig") then
        label:SetText("Off. " .. summary)
        return
    end
    label:SetText(summary)
    if left > 0 and os.clock() >= nextTry and not busy then
        nextTry = os.clock() + 20 -- a failed trip is not retried at once
        Life.spawn("dig:trip", digTrip)
    end
end)

Life.onCleanup(function()
    if busy then
        Ui.travelling = false
    end
end)

return {}
end
__modules["features/enchant"] = function(use) -- src/games/tapsim/features/enchant.luau
-- Pets tab: auto enchant, run by the game's own server-side enchant loop.
--
-- EnchantService takes one table per call: AutoStart { PetId, Slot, Replace } rolls that pet's
-- slot over and over at your enchant speed until it lands a trait in your keep list (SetFilters,
-- a list of names), then stops with AutoEvent { Kind = "Stop", Reason }; Claim() hands the pet back.
-- Replace is not a flag: the game leaves it out, and only sends the current trait's name to confirm
-- rolling over a protected (rare) one -- anything else is refused as InvalidRequest. Each roll costs
-- gems (EnchantConfig.GetRollPrice), and the server only starts it while you stand in the Enchant
-- machine's interaction point ("VisitEnchantMachine"); once started it keeps rolling wherever you
-- go, so the hub walks you there, starts it, and goes straight back to what you were doing.
--
-- "Equipped team" works through your equipped pets strongest first, skipping any whose slot
-- already holds a kept enchant, so the whole team ends up with the traits you chose.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local Options = Ui.Options
local tab = Ui.Tabs.Pets

local EnchantConfig
do
    local ok, module = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Pets.EnchantConfig)
    end)
    EnchantConfig = ok and type(module) == "table" and module or nil
end

local POINT, POINT_FALLBACK = "Enchant", Vector3.new(127, 7687, -1803) -- Shadow Realm

-- Data -----------------------------------------------------------------------------------------

local function enchanting(data)
    return type(data.Enchanting) == "table" and data.Enchanting or {}
end

local function keptSet(data)
    local set = {}
    local filters = enchanting(data).Filters
    if type(filters) == "table" then
        for key, value in pairs(filters) do
            if type(key) == "string" and value == true then
                set[key] = true
            elseif type(value) == "string" then
                set[value] = true
            end
        end
    end
    return set
end

local function slotCount(pet)
    if EnchantConfig then
        local ok, count = Env.call(EnchantConfig.GetSlotCount, pet)
        if ok and type(count) == "number" then
            return count
        end
    end
    return 1
end

local function rollPrice(pet)
    if EnchantConfig then
        local ok, price = Env.call(EnchantConfig.GetRollPrice, pet)
        if ok and type(price) == "number" then
            return price
        end
    end
    return 25000
end

-- Every trait the keep list can hold, rarest first.
local function enchantNames()
    local names = {}
    if EnchantConfig and type(EnchantConfig.Enchants) == "table" then
        for name in pairs(EnchantConfig.Enchants) do
            local ok, filterable = Env.call(EnchantConfig.IsFilterable, name)
            if type(name) == "string" and (not ok or filterable ~= false) then
                names[#names + 1] = name
            end
        end
    end
    local function rank(name)
        local ok, value = Env.call(EnchantConfig.RankOf, name)
        return ok and tonumber(value) or 0
    end
    table.sort(names, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then
            return ra > rb
        end
        return a < b
    end)
    return names
end

-- UI -------------------------------------------------------------------------------------------

local TEAM, CHOSEN = "Equipped team, one by one", "Chosen pet"

local box = tab:AddGroupbox({ Side = "Right", Name = "Auto enchant", IconName = "wand-sparkles" })
box:AddToggle("AutoEnchant", {
    Text = "Auto enchant",
    Default = false,
    Tooltip = "Walks to the Enchant machine, starts the game's own enchant loop on a pet and claims it once it lands a trait you keep. Rolls cost gems.",
})
Ui.automation("AutoEnchant")
box:AddDropdown("EnchantMode", {
    Text = "Pets",
    Values = { TEAM, CHOSEN },
    Default = TEAM,
})
local petIds = {}
box:AddDropdown("EnchantPet", {
    Text = "Chosen pet",
    Values = {},
    Searchable = true,
    Tooltip = "Used when Pets is set to Chosen pet. Strongest first.",
})
box:AddSlider("EnchantSlot", {
    Text = "Slot",
    Default = 1,
    Min = 1,
    Max = 2,
    Rounding = 0,
    Tooltip = "The second slot only exists on pets strong enough to have it.",
})
local initialKeep = {}
do
    local data = Env.data()
    for name in pairs(data and keptSet(data) or {}) do
        initialKeep[#initialKeep + 1] = name
    end
end
box:AddDropdown("EnchantKeep", {
    Text = "Keep these enchants",
    Values = enchantNames(),
    Multi = true,
    Searchable = true,
    Default = initialKeep,
    Tooltip = "The loop stops on the first of these it rolls. Saved to the game, the same list as the machine's Filters.",
})
box:AddToggle("EnchantReplace", {
    Text = "Reroll over a trait not on the list",
    Default = true,
    Tooltip = "A pet whose slot holds a trait you do not keep gets rolled again. Off skips those pets instead.",
})
local panel = Ui.panel(box, 4)

-- Pets for the dropdown, strongest first, refreshed as your inventory changes.
local petSignature
Life.loop("enchant:pets", 5, function()
    local data = Env.data()
    local owned = data and type(data.Pets) == "table" and data.Pets.Owned
    if type(owned) ~= "table" then
        return
    end
    local list = {}
    for id, pet in pairs(owned) do
        if type(pet) == "table" then
            list[#list + 1] = { id = id, pet = pet }
        end
    end
    table.sort(list, function(a, b)
        return (tonumber(a.pet.Power) or 0) > (tonumber(b.pet.Power) or 0)
    end)
    local labels = {}
    table.clear(petIds)
    for index = 1, math.min(#list, 60) do
        local entry = list[index]
        local label = string.format("%s [%s] %s", tostring(entry.pet.Name), tostring(entry.pet.Tier or "Normal"), tostring(entry.pet.Power or "?"))
        while petIds[label] do
            label ..= " "
        end
        petIds[label] = entry.id
        labels[#labels + 1] = label
    end
    local joined = table.concat(labels, "\0")
    if joined ~= petSignature then
        petSignature = joined
        Env.elevate()
        Options.EnchantPet:SetValues(labels)
    end
end)

-- The keep list goes to the server a moment after you stop clicking.
local filtersDirty, filtersChangedAt = false, 0
Options.EnchantKeep:OnChanged(function()
    filtersDirty, filtersChangedAt = true, os.clock()
end)
local function keepList()
    local list = {}
    for name, on in pairs(Options.EnchantKeep.Value or {}) do
        if on then
            list[#list + 1] = name
        end
    end
    table.sort(list)
    return list
end
local function pushFilters()
    filtersDirty = false
    return Env.invoke("EnchantService", "SetFilters", keepList())
end
Life.loop("enchant:filters", 0.5, function()
    if filtersDirty and os.clock() - filtersChangedAt >= 1 then
        pushFilters()
    end
end)

-- Choosing the pet -----------------------------------------------------------------------------

local skipped = {} -- petId -> true when the server will not take it this session

local function slotKey(slot)
    return slot == 2 and "Enchant2" or "Enchant"
end

local function needsWork(pet, slot, kept)
    if type(pet) ~= "table" or slotCount(pet) < slot then
        return false
    end
    local current = pet[slotKey(slot)]
    if current == nil then
        return true
    end
    return not kept[current] and Ui.on("EnchantReplace")
end

-- The next pet to enchant and the slot, or nil plus a reason.
local function target(data)
    local slot = math.clamp(math.floor(tonumber(Options.EnchantSlot.Value) or 1), 1, 2)
    local kept = keptSet(data)
    local owned = type(data.Pets) == "table" and data.Pets.Owned or {}
    if Options.EnchantMode.Value == CHOSEN then
        local id = petIds[Options.EnchantPet.Value or ""]
        local pet = id and owned[id]
        if not pet then
            return nil, "Pick a pet."
        end
        if not needsWork(pet, slot, kept) then
            return nil, string.format("%s already has a kept enchant in slot %d (or no slot %d).", tostring(pet.Name), slot, slot)
        end
        return id, slot
    end
    local team = {}
    for _, id in pairs(type(data.Pets.Equipped) == "table" and data.Pets.Equipped or {}) do
        if owned[id] and not skipped[id] then
            team[#team + 1] = id
        end
    end
    table.sort(team, function(a, b)
        return (tonumber(owned[a].Power) or 0) > (tonumber(owned[b].Power) or 0)
    end)
    for _, id in ipairs(team) do
        if needsWork(owned[id], slot, kept) then
            return id, slot
        end
    end
    return nil, string.format("Every team pet has a kept enchant in slot %d.", slot)
end

-- Moving ---------------------------------------------------------------------------------------

local function root()
    local character = Env.LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function findPoint()
    local best, bestDistance
    for _, part in ipairs(Env.CollectionService:GetTagged("InteractionPoint")) do
        if part:IsA("BasePart") and part.Name == POINT and part:IsDescendantOf(workspace) then
            local distance = (part.Position - POINT_FALLBACK).Magnitude
            if not best or distance < bestDistance then
                best, bestDistance = part, distance
            end
        end
    end
    return best
end

local function standAtMachine()
    local hrp = root()
    if not hrp then
        return false
    end
    local point = findPoint()
    if not point then
        pcall(function()
            Env.LocalPlayer:RequestStreamAroundAsync(POINT_FALLBACK, 10)
        end)
        Env.elevate()
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.CFrame = CFrame.new(POINT_FALLBACK + Vector3.new(0, 6, 0))
        local deadline = os.clock() + 8
        while Life.alive and os.clock() < deadline and not point do
            Life.wait(0.2)
            point = findPoint()
        end
    end
    hrp = root()
    if not point or not hrp then
        return false
    end
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.CFrame = point.CFrame
    Life.wait(0.35)
    return true
end

-- The loop -------------------------------------------------------------------------------------

local state = { running = nil, rolls = 0, landed = 0, stop = nil, note = "Auto enchant is off." }

Life.spawn("enchant:events", function()
    local remote = Env.remote("EnchantService", "AutoEvent")
    Life.connect(remote.OnClientEvent, function(event)
        if type(event) ~= "table" then
            return
        end
        if event.Kind == "Roll" then
            state.rolls += 1
        elseif event.Kind == "Stop" then
            state.stop = event
        end
    end, "enchant:event")
end)

local function invoke(name, payload)
    local ok, result = Env.invoke("EnchantService", name, payload)
    if not ok then
        return false, "Connection"
    end
    if type(result) == "table" and result.Success then
        return true, result
    end
    return false, type(result) == "table" and result.Reason or "Unknown"
end

-- The confirmation the game sends with AutoStart: the current trait's name when it is a protected
-- (rare) one being rolled over, otherwise nothing.
local function replaceToken(petId, slot)
    local data = Env.data()
    local pet = data and type(data.Pets) == "table" and data.Pets.Owned[petId]
    local current = type(pet) == "table" and pet[slotKey(slot)] or nil
    if current == nil or not EnchantConfig then
        return nil
    end
    local ok, protected = Env.call(EnchantConfig.IsProtected, current)
    return ok and protected == true and current or nil
end

-- One trip: walk to the machine, start the loop on `petId`, walk back. Returns ok, reason.
local function start(petId, slot)
    local settle = os.clock() + 6
    Ui.travelling = "enchant"
    while Ui.hatchInFlight and os.clock() < settle do
        Life.wait(0.05)
    end
    local hrp = root()
    local home = hrp and hrp.CFrame
    local ok, reason = false, "VisitEnchantMachine"
    local pcallOk, err = pcall(function()
        if not standAtMachine() then
            reason = "VisitEnchantMachine"
            return
        end
        for _ = 1, 3 do
            ok, reason = invoke("AutoStart", { PetId = petId, Slot = slot, Replace = replaceToken(petId, slot) })
            if ok then
                return
            end
            if reason == "ClaimFirst" or reason == "Pending" or reason == "EnchantPending" then
                invoke("Claim")
            elseif reason == "AutoRunning" then
                invoke("AutoStop")
                Life.wait(0.3)
                invoke("Claim")
            elseif reason == "NoFilters" then
                pushFilters()
            elseif reason == "VisitEnchantMachine" then
                standAtMachine()
            else
                return
            end
            Life.wait(0.3)
        end
    end)
    Env.elevate()
    if not pcallOk then
        reason = tostring(err)
    end
    if home and root() then
        root().AssemblyLinearVelocity = Vector3.zero
        root().CFrame = home
    end
    Ui.travelling = false
    return ok, reason
end

local REASONS = {
    InsufficientGems = "Not enough gems for a roll.",
    VisitEnchantMachine = "Could not reach the Enchant machine.",
    ConfirmReplace = "That slot already has a trait (turn on reroll to replace it).",
    InvalidSlot = "That pet does not have this slot.",
    Reserved = "That pet is in a trade.",
    Frozen = "That pet is unavailable.",
    UnknownPet = "That pet is gone.",
    NoFilters = "Pick the enchants to keep first.",
}

Life.spawn("enchant:auto", function()
    while Life.alive do
        if not Ui.on("AutoEnchant") then
            if state.running then
                invoke("AutoStop")
                invoke("Claim")
                state.running = nil
            end
            state.note = "Auto enchant is off."
            Life.wait(0.3)
            continue
        end
        local data = Env.data()
        if not data then
            Life.wait(0.5)
            continue
        end
        -- A loop that has stopped: take the pet back and move on.
        if state.running and state.stop then
            local event = state.stop
            state.stop = nil
            invoke("Claim")
            if event.Reason == "Matched" then
                state.landed += 1
                state.note = string.format("%s got %s.", tostring(event.Pet or "Pet"), tostring(event.Enchant or "a kept enchant"))
            elseif event.Reason == "Gems" then
                state.note = "Out of gems; waiting for more."
            else
                state.note = "Stopped: " .. tostring(event.Reason)
            end
            state.running = nil
        end
        if state.running then
            Life.wait(0.3)
            continue
        end
        if #keepList() == 0 then
            state.note = "Pick the enchants to keep first."
            Life.wait(1)
            continue
        end
        local petId, slot = target(data)
        if not petId then
            state.note = slot
            Life.wait(2)
            continue
        end
        local pet = data.Pets.Owned[petId]
        local gems = tonumber(type(data.Currencies) == "table" and data.Currencies.Gems) or 0
        if gems < rollPrice(pet) then
            state.note = "Not enough gems for a roll."
            Life.wait(3)
            continue
        end
        -- Another trip (craft) or hatch walking owns the character: wait for it.
        if Ui.travelling or Ui.hatchMoving then
            Life.wait(0.3)
            continue
        end
        if filtersDirty then
            pushFilters()
        end
        Ui.status = "Starting auto enchant on " .. tostring(pet.Name)
        local ok, reason = start(petId, slot)
        if ok then
            state.running = petId
            state.stop = nil
            state.failures = 0
            state.note = string.format("Enchanting %s, slot %d.", tostring(pet.Name), slot)
        else
            state.note = REASONS[reason] or ("Could not start: " .. tostring(reason))
            if reason == "ConfirmReplace" or reason == "InvalidSlot" or reason == "Reserved" or reason == "Frozen" or reason == "UnknownPet" then
                skipped[petId] = true
            end
            -- Every attempt is a round trip to the machine: back off instead of bouncing there.
            state.failures = (state.failures or 0) + 1
            Life.wait(math.min(30, 2 ^ state.failures))
        end
        if Ui.status and Ui.status:find("^Starting auto enchant") then
            Ui.status = "Idle"
        end
    end
end)

Life.loop("enchant:panel", 0.5, function()
    local data = Env.data()
    local gems = data and tonumber(type(data.Currencies) == "table" and data.Currencies.Gems) or 0
    local running = state.running and data and data.Pets.Owned[state.running]
    panel.set({
        running and string.format("Running on %s", tostring(running.Name)) or "Not running",
        string.format("Rolls seen: %d, kept enchants landed: %d", state.rolls, state.landed),
        string.format("Gems: %s", tostring(math.floor(gems))),
        state.note,
    })
end)

Life.onCleanup(function()
    if state.running then
        pcall(Env.invoke, "EnchantService", "AutoStop")
    end
end)

return {}
end
__modules["features/hatch"] = function(use) -- src/games/tapsim/features/hatch.luau
-- Pets tab: auto hatch, done the way the game's own auto hatch does it, minus the waiting.
--
-- EggService.EggHatchRequested { Egg, Count, Auto, Seq } is answered on EggHatchResult with the
-- same Seq. The server paces hatching itself -- it holds the answer ("Held") until the egg may be
-- opened again -- so the fastest rate that never trips RateLimited is one request in flight and the
-- next sent the moment its answer lands. A timer either wastes time or gets refused.
--
-- The server only hatches an egg you stand next to (Error "TooFar"), so the hub walks you to it:
-- every egg is a model in workspace.Eggs whose pivot is readable even before it streams in.
-- Count follows the game's rule: 8 with the x8 pass or an OctoHatch boost, else 3, else 1, each
-- only if affordable. Auto = true is what the real auto hatch sends, so secret pity keeps building.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local Options = Ui.Options
local RS = Env.ReplicatedStorage
local tab = Ui.Tabs.Pets

-- Rules ----------------------------------------------------------------------------------------

-- Egg name -> { price, island, pets = { name = chance% } } from LaunchEggConfig.
local EGGS = {}
local EggPricing, GamepassPerks, BoostFormula
do
    local ok, cfg = Env.call(function()
        return require(RS.Shared.Pets.LaunchEggConfig)
    end)
    if ok and type(cfg) == "table" then
        for name, def in pairs(cfg) do
            -- Test has no stand anywhere in the world; it is what the first version kept picking.
            if type(def) == "table" and name ~= "Test" then
                EGGS[name] = {
                    price = tonumber(def.Price) or 0,
                    island = def.Island,
                    pets = type(def.Pets) == "table" and def.Pets or {},
                }
            end
        end
    end
    local function load(path)
        local found, module = Env.call(function()
            local node = RS
            for _, part in ipairs(path) do
                node = node:FindFirstChild(part)
            end
            return node and require(node)
        end)
        return found and module or nil
    end
    EggPricing = load({ "Shared", "Pets", "EggPricing" })
    GamepassPerks = load({ "Shared", "Monetization", "GamepassPerks" })
    BoostFormula = load({ "Shared", "Items", "BoostFormula" })
end

local SECRET_PITY_SECONDS, SECRET_PITY_MAX = 86400, 4 -- HatchRulesConfig
local STAND_RANGE = 9 -- the client counts you as at an egg within 10 studs

local function unitPrice(data, egg)
    local price = EGGS[egg].price
    if EggPricing then
        local ok, value = Env.call(EggPricing.GetUnitPrice, data, egg, price)
        if ok and type(value) == "number" then
            return value
        end
    end
    return price
end

local function totalPrice(data, egg, count)
    local price = EGGS[egg].price
    if EggPricing then
        local ok, value = Env.call(EggPricing.GetTotal, data, egg, price, count)
        if ok and type(value) == "number" then
            return value
        end
    end
    return price * count
end

local function canOcto(data)
    local function has(module, method, key)
        if not module then
            return false
        end
        local ok, value = Env.call(module[method], data, key)
        return ok and value == true
    end
    return has(GamepassPerks, "Has", "x8Egg") or has(BoostFormula, "HasType", "OctoHatch")
end

-- The game's own pickAutoHatchCount: the biggest batch you have the pass and the coins for.
local function hatchCount(data, egg)
    local coins = tonumber(type(data.Currencies) == "table" and data.Currencies.Coins) or 0
    if canOcto(data) and totalPrice(data, egg, 8) <= coins then
        return 8
    end
    if totalPrice(data, egg, 3) <= coins then
        return 3
    end
    if unitPrice(data, egg) <= coins then
        return 1
    end
    return nil
end

-- workspace.Eggs is streamed: in a fresh server it can be empty until you have been near each egg,
-- so where each one stands is also kept here (read from the map when the hub was written).
local EGG_POSITIONS = {
    Basic = Vector3.new(6, -511, -1833),
    Spotted = Vector3.new(-5, -511, -1822),
    Spiked = Vector3.new(-23, -513, -1707),
    Sky = Vector3.new(-88, -48, -1904),
    Nimbus = Vector3.new(-97, -48, -1891),
    Pumpkin = Vector3.new(-143, 881, -1833),
    Forest = Vector3.new(-297, 1228, 267),
    Mushroom = Vector3.new(-6, 2032, -1925),
    Mycelium = Vector3.new(-21, 2032, -1932),
    Snowman = Vector3.new(-258, 2547, 345),
    Cactus = Vector3.new(-203, 3632, -1863),
    Crystal = Vector3.new(-53, 5438, -1992),
    Geode = Vector3.new(-68, 5438, -1987),
    Void = Vector3.new(-204, 7676, -1885),
}

local function eggModel(egg)
    local folder = workspace:FindFirstChild("Eggs")
    return folder and folder:FindFirstChild(egg)
end

-- Where the egg is: the live model when it has streamed in, else the recorded spot.
local function eggPosition(egg)
    local model = eggModel(egg)
    if model then
        local ok, pivot = pcall(model.GetPivot, model)
        if ok then
            return pivot.Position
        end
    end
    return EGG_POSITIONS[egg]
end

-- Unlocked, on an unlocked island, and standing somewhere in the world.
local function hatchable(data, egg)
    local eggs = type(data.Eggs) == "table" and data.Eggs.Unlocked
    if type(eggs) ~= "table" or eggs[egg] ~= true or not eggPosition(egg) then
        return false
    end
    local island = EGGS[egg].island
    local islands = type(data.Progression) == "table" and data.Progression.UnlockedIslands
    return island == nil or island == "Spawn" or (type(islands) == "table" and islands[island] == true)
end

-- Choosing the egg -----------------------------------------------------------------------------

local BEST, CHOSEN, ISLAND = "Best egg I can afford", "Chosen egg", "Egg on my island"
local UPGRADE_BUFFER = 5 -- move up to a pricier egg only with this many full batches of it in the bank

local current -- the egg being hatched now
local refused = {} -- egg -> os.clock() until which it is skipped (NotEnoughCoins, IslandLocked)

local function eggsByPrice(data)
    local list = {}
    for egg in pairs(EGGS) do
        if hatchable(data, egg) and os.clock() >= (refused[egg] or 0) then
            list[#list + 1] = egg
        end
    end
    table.sort(list, function(a, b)
        return EGGS[a].price > EGGS[b].price
    end)
    return list
end

local function chooseEgg(data)
    local mode = Options.HatchMode.Value
    if mode == CHOSEN then
        local egg = Options.HatchEgg.Value
        return egg and EGGS[egg] and hatchable(data, egg) and egg or nil
    end
    local list = eggsByPrice(data)
    if mode == ISLAND then
        local island = Env.LocalPlayer:GetAttribute("CurrentIsland")
        for _, egg in ipairs(list) do
            if EGGS[egg].island == island and hatchCount(data, egg) then
                return egg
            end
        end
        return nil
    end
    -- Best affordable, with a buffer before moving up so a coin balance hovering at one egg's price
    -- does not fly you back and forth (and split secret pity) every few hatches.
    local coins = tonumber(type(data.Currencies) == "table" and data.Currencies.Coins) or 0
    local stay = current and EGGS[current] and hatchable(data, current) and hatchCount(data, current) ~= nil
    for _, egg in ipairs(list) do
        if stay and egg == current then
            return current
        end
        local count = hatchCount(data, egg)
        if count then
            local better = stay and EGGS[egg].price > EGGS[current].price
            if not better or coins >= totalPrice(data, egg, count) * UPGRADE_BUFFER then
                return egg
            end
        end
    end
    return stay and current or nil
end

-- Moving to the egg ----------------------------------------------------------------------------

local function root()
    local character = Env.LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function eggCenter(model)
    local part = model:FindFirstChild("Egg")
    if part and part:IsA("BasePart") then
        return part.Position
    end
    local ok, pivot = pcall(model.GetPivot, model)
    return ok and pivot.Position or nil
end

local function nearEgg(egg)
    local model, hrp = eggModel(egg), root()
    local center = model and eggCenter(model)
    return hrp ~= nil and center ~= nil and (hrp.Position - center).Magnitude <= STAND_RANGE
end

-- Solid ground in a ring around the egg (its pedestal does not collide), facing the egg.
local function standSpot(model, center)
    local ignore = { model }
    for _, player in ipairs(Env.Players:GetPlayers()) do
        if player.Character then
            ignore[#ignore + 1] = player.Character
        end
    end
    for _, name in ipairs({ "GoldPets", "RainbowPets", "Pets", "PlayerPets" }) do
        local folder = workspace:FindFirstChild(name)
        if folder then
            ignore[#ignore + 1] = folder
        end
    end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = ignore
    for step = 0, 7 do
        local angle = step * math.pi / 4
        local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * 5.5
        local hit = workspace:Raycast(center + offset + Vector3.new(0, 4, 0), Vector3.new(0, -20, 0), params)
        if hit and hit.Instance.CanCollide and hit.Normal.Y > 0.6 then
            local spot = hit.Position + Vector3.new(0, 3, 0)
            if (spot - center).Magnitude <= STAND_RANGE then
                return CFrame.lookAt(spot, Vector3.new(center.X, spot.Y, center.Z))
            end
        end
    end
    return CFrame.new(center + Vector3.new(0, -1, 5))
end

-- Ui.hatchMoving tells auto craft not to start a trip while this one is under way, and a craft trip
-- (Ui.travelling) cuts this one short: two features teleporting at once fight over the character.
local function goToEgg(egg)
    local target, hrp = eggPosition(egg), root()
    if not target or not hrp or Ui.travelling then
        return false
    end
    Ui.hatchMoving = true
    local arrived = false
    pcall(function()
        pcall(function()
            Env.LocalPlayer:RequestStreamAroundAsync(target, 10)
        end)
        Env.elevate()
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.CFrame = CFrame.new(target + Vector3.new(0, 6, 0))
        -- The model (and its Egg part) stream in once we are here.
        local model
        local deadline = os.clock() + 8
        while Life.alive and not Ui.travelling and os.clock() < deadline do
            model = eggModel(egg)
            if model and model:FindFirstChild("Egg") then
                break
            end
            Life.wait(0.2)
        end
        local center = model and eggCenter(model)
        hrp = root()
        if center and hrp and not Ui.travelling then
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.CFrame = standSpot(model, center)
            Life.wait(0.3)
            arrived = true
        end
    end)
    Env.elevate()
    Ui.hatchMoving = false
    return arrived
end

-- Requests -------------------------------------------------------------------------------------

local seq = 7000000 -- well clear of the game client's own counter
local waiting
Life.spawn("hatch:results", function()
    local remote = Env.remote("EggService", "EggHatchResult")
    Life.connect(remote.OnClientEvent, function(payload)
        if waiting and type(payload) == "table" and (payload.Seq == waiting.seq or (payload.Seq == nil and payload.Egg == waiting.egg)) then
            waiting.result = payload
        end
    end, "hatch:result")
end)

-- Ui.hatchInFlight: the server holds a request until the egg may open again and only then checks
-- distance, so a craft trip must wait for it to land or the held request comes back TooFar.
local function hatch(egg, count)
    seq += 1
    local slot = { seq = seq, egg = egg }
    waiting = slot
    Ui.hatchInFlight = true
    Env.fire("EggService", "EggHatchRequested", { Egg = egg, Count = count, Auto = true, Seq = slot.seq })
    local deadline = os.clock() + 12 -- the client's own give-up time
    while Life.alive and not slot.result and os.clock() < deadline do
        Life.wait(0.03)
    end
    Ui.hatchInFlight = false
    if waiting == slot then
        waiting = nil
    end
    return slot.result
end

-- Auto delete: the game's own per-egg list, filled with every pet at or above a drop chance.
local appliedDelete = {}
local function applyAutoDelete(egg)
    local threshold = tonumber(Options.HatchDeleteAbove.Value) or 0
    if threshold <= 0 or appliedDelete[egg] == threshold then
        return
    end
    local names = {}
    for name, chance in pairs(EGGS[egg].pets) do
        if tonumber(chance) and chance >= threshold then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    Env.fire("EggService", "AutoDeleteRequested", { Egg = egg, Entries = names })
    appliedDelete[egg] = threshold
end

-- UI -------------------------------------------------------------------------------------------

local function shortNumber(n)
    for _, unit in ipairs({ { 1e18, "Qi" }, { 1e15, "Q" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
        if n >= unit[1] then
            return string.format("%.1f%s", n / unit[1], unit[2])
        end
    end
    return tostring(math.floor(n))
end

local function eggChoices()
    local data = Env.data()
    local names = {}
    for egg in pairs(EGGS) do
        if not data or hatchable(data, egg) then
            names[#names + 1] = egg
        end
    end
    table.sort(names, function(a, b)
        return EGGS[a].price > EGGS[b].price
    end)
    return names
end

local box = tab:AddGroupbox({ Side = "Left", Name = "Auto hatch", IconName = "egg" })
box:AddToggle("AutoHatch", {
    Text = "Auto hatch",
    Default = false,
    Tooltip = "Walks you to the egg and hatches as fast as the server allows: the next hatch goes the instant the last one lands.",
})
Ui.automation("AutoHatch")
box:AddDropdown("HatchMode", {
    Text = "Egg",
    Values = { BEST, CHOSEN, ISLAND },
    Default = BEST,
    Tooltip = "Best egg I can afford moves up as your coins grow and drops down instead of stopping when they run low.",
})
local initialEggs = eggChoices()
box:AddDropdown("HatchEgg", {
    Text = "Chosen egg",
    Values = initialEggs,
    Default = initialEggs[1],
    Searchable = true,
    Tooltip = "Used when Egg is set to Chosen egg. Priciest first.",
})
box:AddToggle("HatchTeleport", {
    Text = "Teleport to the egg",
    Default = true,
    Tooltip = "The server only hatches an egg you stand next to.",
})
box:AddSlider("HatchDeleteAbove", {
    Text = "Auto delete pets above",
    Default = 0,
    Min = 0,
    Max = 50,
    Rounding = 1,
    Suffix = "%",
    Tooltip = "0 keeps your in-game auto delete. Otherwise the egg's auto delete is set to every pet with at least this drop chance, so only rarer hatches reach your storage.",
})

local panelBox = tab:AddGroupbox({ Side = "Left", Name = "Hatching", IconName = "activity" })
local panel = Ui.panel(panelBox, 5)

local signature
Life.loop("hatch:eggs", 5, function()
    local values = eggChoices()
    local joined = table.concat(values, "\0")
    if joined ~= signature then
        signature = joined
        Env.elevate()
        Options.HatchEgg:SetValues(values)
    end
end)

-- The loop -------------------------------------------------------------------------------------

local stats = { eggs = 0, spent = 0, started = nil }
local recent = {} -- os.clock() of each hatched egg in the last minute, for the rate
local note = "Auto hatch is off."
local active = false -- the server believes we are auto hatching

local function stop()
    if active then
        active = false
        pcall(Env.fire, "EggService", "StopOfflineHatch")
    end
end

local function pause(text, seconds)
    note = text
    Life.wait(seconds)
end

Life.spawn("hatch:auto", function()
    local tooFar = 0
    while Life.alive do
        -- A craft trip stands you somewhere else; hatching resumes (and walks back) after it.
        if not Ui.on("AutoHatch") or Ui.travelling then
            stop()
            if not Ui.on("AutoHatch") then
                note = "Auto hatch is off."
                if Ui.status and (Ui.status:find("^Auto hatching") or Ui.status:find("^Walking to the")) then
                    Ui.status = "Idle"
                end
            end
            Life.wait(0.2)
            continue
        end
        local data = Env.data()
        if not data then
            Life.wait(0.5)
            continue
        end
        local egg = chooseEgg(data)
        if not egg then
            pause("No egg you can afford right now. Waiting for coins.", 1)
            continue
        end
        if egg ~= current then
            current, tooFar = egg, 0
        end
        local count = hatchCount(data, egg)
        if not count then
            pause("Not enough coins for the " .. egg .. " egg.", 0.5)
            continue
        end
        if Ui.on("HatchTeleport") and not nearEgg(egg) then
            Ui.status = "Walking to the " .. egg .. " egg"
            if not goToEgg(egg) then
                pause("Could not reach the " .. egg .. " egg.", 2)
                continue
            end
        end
        applyAutoDelete(egg)
        Ui.status = "Auto hatching " .. egg
        local result = hatch(egg, count)
        active = true
        if not result then
            pause("The server did not answer; retrying.", 0.5)
        elseif result.Success then
            tooFar = 0
            local got = tonumber(result.Rolls) or (type(result.Pets) == "table" and #result.Pets > 0 and #result.Pets) or count
            stats.eggs += got
            stats.spent += tonumber(result.Spent) or 0
            stats.started = stats.started or os.clock()
            local now = os.clock()
            for _ = 1, got do
                recent[#recent + 1] = now
            end
            note = string.format("Hatched %s x%d.", egg, got)
        elseif result.Error == "RateLimited" then
            Life.wait(0.4)
        elseif result.Error == "Cancelled" then
            Life.wait(0.1)
        elseif result.Error == "TooFar" then
            tooFar += 1
            if tooFar >= 3 or not Ui.on("HatchTeleport") then
                pause("Too far from the " .. egg .. " egg. Stand next to it.", 2)
            else
                goToEgg(egg)
            end
        elseif result.Error == "StorageFull" then
            pause(string.format("Storage full: this hatch needs %s free slot(s). Auto craft or auto delete frees space.", tostring(result.Needed or count)), 2)
        elseif result.Error == "NotEnoughCoins" then
            refused[egg] = os.clock() + 5
            Life.wait(0.25)
        elseif result.Error == "IslandLocked" then
            refused[egg] = os.clock() + 60
            note = egg .. " is on an island you have not unlocked."
        else
            pause("Hatch refused: " .. tostring(result.Error or result.Reason or "unknown"), 1)
        end
    end
end)

Life.loop("hatch:panel", 0.5, function()
    local data = Env.data()
    if not data then
        return
    end
    local cutoff = os.clock() - 60
    while recent[1] and recent[1] < cutoff do
        table.remove(recent, 1)
    end
    local lines = {}
    if current and EGGS[current] then
        local count = hatchCount(data, current) or 0
        lines[#lines + 1] = string.format("Egg: %s (%s each), %d per hatch", current, shortNumber(unitPrice(data, current)), count)
        local drought = type(data.Eggs) == "table" and type(data.Eggs.SecretDroughtSeconds) == "table"
            and tonumber(data.Eggs.SecretDroughtSeconds[current]) or 0
        local fill = math.clamp(drought / SECRET_PITY_SECONDS, 0, 1)
        lines[#lines + 1] = string.format("Secret pity: %d%% (luck x%.2f)", math.floor(fill * 100), 1 + (SECRET_PITY_MAX - 1) * fill)
    end
    local window = stats.started and math.min(60, os.clock() - stats.started) or 0
    lines[#lines + 1] = string.format("Rate: %d eggs/min, %d this session, %s coins spent",
        window > 1 and math.floor(#recent * 60 / window) or 0, stats.eggs, shortNumber(stats.spent))
    local owned = 0
    for _ in pairs(type(data.Pets) == "table" and type(data.Pets.Owned) == "table" and data.Pets.Owned or {}) do
        owned += 1
    end
    lines[#lines + 1] = string.format("Storage: %d / %s", owned, tostring(type(data.Pets) == "table" and data.Pets.StorageLimit or "?"))
    lines[#lines + 1] = note
    panel.set(lines)
end)

Life.onCleanup(stop)

return {}
end
__modules["features/home"] = function(use) -- src/games/tapsim/features/home.luau
-- Home tab: the shared welcome box plus your live currencies and progress.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")
local Home = use("shared/home")

local _, statusLabel = Home.build()
local statsBox = Ui.Tabs.Home:AddGroupbox({ Side = "Right", Name = "You", IconName = "user" })
local stats = statsBox:AddLabel("Loading...", true)

local function comma(n)
    local text = string.format("%d", math.floor(tonumber(n) or 0))
    local out = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

Life.loop("home:stats", 1, function()
    statusLabel:SetText("Doing: " .. tostring(Ui.status or "Idle"))
    local data = Env.data()
    if not data then
        stats:SetText("Waiting for your data to load...")
        return
    end
    local prog = type(data.Progression) == "table" and data.Progression or {}
    local rebirths = type(data.Statistics) == "table" and data.Statistics.Rebirths
    stats:SetText(string.format(
        "Coins: %s\nGems: %s   Tokens: %s\nWorld: %s   Island: %s\nZone: %s%s",
        comma(Env.currency("Coins")),
        comma(Env.currency("Gems")), comma(Env.currency("Tokens")),
        tostring(prog.World or "?"), tostring(prog.Island or "?"),
        tostring(prog.Zone or "?"),
        rebirths and ("\nRebirths: " .. comma(rebirths)) or ""))
end)

return {}
end
__modules["features/mining"] = function(use) -- src/games/tapsim/features/mining.luau
-- Rewards tab: the mine under Crystal Cave (MiningService). A 20 x 20 x 25 block mine per player,
-- fresh every day. Ores fill your bag; selling them gives mining coins, which buy better pickaxes
-- and bags and, in the daily shop, packs of real Coins and Gems. Clearing 25/50/75/100% of the
-- mine pays milestone Coins and Gems once a day (MiningConfig.Milestones).
--
-- Everything goes through the game's own mine so it shows as you would play it:
--   enter   standing in the portal makes the game's MiningController travel in (Enter) and draw
--           the mine;
--   mine    the controller's TouchTapInWorld handler is the game's "tap a block" input: the camera
--           is pointed at the chosen block for that one call and put back, and the game aims,
--           checks reach, sight and pickaxe power, sends Hit and breaks the block on screen;
--   pets    your equipped pets mine blocks near you by themselves (the server's PetMine), which is
--           most of the speed;
--   sell    standing on the Sell pad makes the game sell the bag;
--   shop    Purchase("BuyTool" | "BuyStorage", name) and DailyBuy(id) on their pads;
--   leave   the Exit pad.
-- Without getconnections the hub sends Hit itself, and broken blocks are not removed on screen
-- until the mine is redrawn.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local Options = Ui.Options
local RS = Env.ReplicatedStorage
local UserInputService = game:GetService("UserInputService")
local tab = Ui.Tabs.Rewards

local function load(...)
    local path = { ... }
    local ok, module = Env.call(function()
        local node = RS
        for _, part in ipairs(path) do
            node = node:FindFirstChild(part)
        end
        return node and require(node)
    end)
    return ok and type(module) == "table" and module or nil
end

local MiningWorld = load("Shared", "Minigames", "Mining", "MiningWorld")
local MiningConfig = load("Shared", "Minigames", "Mining", "MiningConfig")
local DailyShop = load("Shared", "Minigames", "Mining", "DailyShop")

local CRYSTAL_CAVE = Vector3.new(-53, 5445, -1992)
local SKIP_SECONDS = 60
local DAILY_ALL, DAILY_COINS, DAILY_GEMS, DAILY_OFF = "Coins and Gems packs", "Coins packs", "Gems packs", "Off"

local box = tab:AddGroupbox({ Side = "Right", Name = "Mine", IconName = "pickaxe" })
box:AddToggle("AutoMine", {
    Text = "Auto mine",
    Default = false,
    Tooltip = "Goes into the Crystal Cave mine and mines with you and your pets, selling whenever the bag is full. Auto hatch and other trips wait while it runs; turn it off to come back.",
})
Ui.automation("AutoMine", false)
box:AddToggle("MineUpgrades", {
    Text = "Buy pickaxes and bags",
    Default = true,
    Tooltip = "Spends mining coins on the next pickaxe or bag as soon as one is affordable. Better pickaxes break harder ore; the Copper Pickaxe is the only one that breaks Hardened Stone and the rare ores.",
})
box:AddDropdown("MineDaily", {
    Text = "Daily shop",
    Values = { DAILY_ALL, DAILY_COINS, DAILY_GEMS, DAILY_OFF },
    Default = DAILY_ALL,
    Tooltip = "Once every pickaxe and bag is bought, spare mining coins buy the daily shop's packs of real Coins or Gems (the Mining Legend title is never bought).",
})
local label = box:AddLabel("Auto mine is off.", true)

local session = { sold = 0, earned = 0, bought = {}, note = "" }

local function root()
    local character = Env.LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function controller()
    local module = RS:FindFirstChild("Controllers") and RS.Controllers:FindFirstChild("Minigames")
    module = module and module:FindFirstChild("MiningController")
    if not module then
        return nil
    end
    local ok, result = Env.call(require, module)
    return ok and type(result) == "table" and result or nil
end

local function mineState()
    local mining = controller()
    if not mining or type(mining.GetState) ~= "function" then
        return nil
    end
    local ok, state = Env.call(mining.GetState, mining)
    return ok and type(state) == "table" and state or nil
end

local function inMine()
    return Env.LocalPlayer:GetAttribute("MiningActive") == true
end

local function teleport(cframe)
    local hrp = root()
    if hrp then
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.CFrame = cframe
    end
end

-- The game's own "tap a block" handler, once the mine's code has loaded.
local tapHandler
local function findTapHandler()
    if tapHandler or type(getconnections) ~= "function" then
        return tapHandler
    end
    local ok, connections = pcall(getconnections, UserInputService.TouchTapInWorld)
    for _, connection in ipairs(ok and type(connections) == "table" and connections or {}) do
        local fine, source = pcall(function()
            return connection.Function and debug.info(connection.Function, "s")
        end)
        if fine and type(source) == "string" and source:find("MiningController") then
            tapHandler = connection.Function
        end
    end
    Env.elevate()
    return tapHandler
end

local function enter()
    if inMine() then
        return true
    end
    pcall(function()
        Env.LocalPlayer:RequestStreamAroundAsync(CRYSTAL_CAVE, 10)
    end)
    Env.elevate()
    teleport(CFrame.new(CRYSTAL_CAVE))
    local portal
    local deadline = os.clock() + 10
    repeat
        Life.wait(0.3)
        portal = MiningWorld and MiningWorld.Portal()
    until portal or not Life.alive or os.clock() > deadline
    if not portal then
        session.note = "Could not find the mine portal on Crystal Cave."
        return false
    end
    teleport(portal.CFrame)
    deadline = os.clock() + 20
    repeat
        Life.wait(0.3)
    until inMine() or not Life.alive or os.clock() > deadline
    Life.wait(1.5) -- the game's fade and the first blocks being drawn
    return inMine()
end

local function onPad(name, until_, seconds)
    local pad = MiningWorld and MiningWorld.Part(name)
    if not pad then
        return false
    end
    teleport(pad.CFrame + Vector3.new(0, 4, 0))
    local deadline = os.clock() + (seconds or 6)
    repeat
        Life.wait(0.3)
    until not until_ or until_() or not Life.alive or os.clock() > deadline
    return true
end

local function ask(name, ...)
    local ok, result = Env.invoke("MiningService", name, ...)
    if ok and type(result) == "table" and not result.Error then
        return result
    end
    return nil, tostring(ok and type(result) == "table" and result.Error or result)
end

-- The next pickaxe or bag above what you use, if you can pay for it now.
local function nextUpgrade(state)
    if not MiningConfig then
        return nil
    end
    local balance = tonumber(state.Balance) or 0
    local best
    for _, kind in ipairs({ "Tool", "Bag" }) do
        local list = kind == "Tool" and MiningConfig.Tools or MiningConfig.Bags
        local current = tonumber(kind == "Tool" and state.Tool or state.Backpack) or 1
        local item = list[current + 1]
        if item and (not best or item.Price < best.price) then
            best = { kind = kind, name = item.Name, price = item.Price, affordable = item.Price <= balance }
        end
    end
    return best
end

-- The dearest daily-shop pack of the chosen kind you can pay for, or nil.
local dailySkip = {} -- id -> day it sold out for you
local function nextDaily(state)
    local pick = Options.MineDaily.Value
    if not DailyShop or pick == DAILY_OFF then
        return nil
    end
    local day = DailyShop.Day(os.time())
    local offers = {}
    local ok, rotating = Env.call(DailyShop.Rotating, day)
    for _, offer in ipairs(ok and type(rotating) == "table" and rotating or {}) do
        offers[#offers + 1] = offer
    end
    for _, offer in ipairs(DailyShop.PermanentOffers()) do
        offers[#offers + 1] = offer
    end
    local balance = tonumber(state.Balance) or 0
    local best
    for _, offer in ipairs(offers) do
        local kindOk = (offer.Kind == "Clicks" and pick ~= DAILY_GEMS) or (offer.Kind == "Gems" and pick ~= DAILY_COINS)
        if kindOk and dailySkip[offer.Id] ~= day and (tonumber(offer.Price) or math.huge) <= balance
            and (not best or offer.Price > best.Price) then
            best = offer
        end
    end
    return best, day
end

local function spend()
    local state = mineState()
    if not state then
        return
    end
    if Ui.on("MineUpgrades") then
        local upgrade = nextUpgrade(state)
        while upgrade and upgrade.affordable and Life.alive do
            onPad("Shop")
            local result, why = ask("Purchase", upgrade.kind == "Tool" and "BuyTool" or "BuyStorage", upgrade.name)
            if not result then
                session.note = string.format("Could not buy the %s: %s.", upgrade.name, why)
                return
            end
            session.bought[#session.bought + 1] = upgrade.name
            session.note = "Bought the " .. upgrade.name .. "."
            Life.wait(0.6)
            state = mineState() or state
            upgrade = nextUpgrade(state)
        end
        if upgrade then
            return -- saving for the next upgrade before anything else
        end
    end
    local offer, day = nextDaily(state)
    while offer and Life.alive do
        onPad("Daily")
        local result, why = ask("DailyBuy", offer.Id)
        if not result then
            dailySkip[offer.Id] = day
            session.note = string.format("Daily shop: %s (%s).", offer.Name, why)
        else
            session.bought[#session.bought + 1] = offer.Name
            session.note = "Daily shop: bought a " .. offer.Name .. "."
        end
        Life.wait(0.6)
        state = mineState() or state
        offer, day = nextDaily(state)
    end
end

local function sellAndSpend()
    local before = mineState()
    local balance = before and tonumber(before.Balance) or 0
    onPad("Sell", function()
        local state = mineState()
        return state and (tonumber(state.Count) or 0) == 0
    end, 8)
    local after = mineState()
    if after and (tonumber(after.Count) or 0) == 0 then
        session.sold += 1
        session.earned += math.max(0, (tonumber(after.Balance) or 0) - balance)
    end
    spend()
end

-- Mining ---------------------------------------------------------------------------------------

local skipped = {} -- key -> skip until (os.clock)

-- Ores at least this valuable are taken before plain rock wherever they are uncovered: Copper (20)
-- and up. Dirt is worth 1, Stone 3, Coal 10; gems 250-650 (BlockStats).
local ORE_VALUE = 20

-- The block to mine: one the game has drawn (drawn blocks are the exposed ones near you) that your
-- pickaxe can break and that has open space above it. The most valuable uncovered ore first, then
-- plain rock top layers first (the mine is Dirt for 3 layers, Stone down to 20, Hardened Stone
-- below), then the nearest.
local function chooseTarget(state, marker)
    local folder = workspace:FindFirstChild("LocalMiningBlocks")
    if not folder or not MiningConfig then
        return nil
    end
    local tool = MiningConfig.Tools[tonumber(state.Tool) or 1]
    local power = tool and tool.Power or 1
    local drawn = {}
    for _, block in ipairs(folder:GetChildren()) do
        if block.Name:match("^%d+:%d+:%d+$") then
            drawn[block.Name] = block
        end
    end
    local hrp = root()
    local here = hrp and hrp.Position or marker.Position
    local now = os.clock()
    local best
    local function better(candidate)
        if not best then
            return true
        end
        local oreA, oreB = candidate.value >= ORE_VALUE, best.value >= ORE_VALUE
        if oreA ~= oreB then
            return oreA
        end
        if oreA and candidate.value ~= best.value then
            return candidate.value > best.value
        end
        if not oreA and candidate.y ~= best.y then
            return candidate.y < best.y
        end
        return candidate.distance < best.distance
    end
    for key, block in pairs(drawn) do
        if (skipped[key] or 0) <= now then
            local x, y, z = key:match("^(%d+):(%d+):(%d+)$")
            x, y, z = tonumber(x), tonumber(y), tonumber(z)
            local above = y > 0 and MiningConfig.Key(x, y - 1, z) or nil
            if not (above and drawn[above]) then
                local ok, _, stats = pcall(MiningConfig.Ore, state.Seed, x, y, z)
                if ok and stats and (tonumber(stats.pickaxeRequirement) or 0) <= power then
                    local position = MiningConfig.Position(marker, x, y, z)
                    local candidate = { key = key, x = x, y = y, z = z, position = position, block = block,
                        health = tonumber(stats.health) or 10, value = tonumber(stats.value) or 0,
                        distance = (position - here).Magnitude }
                    if better(candidate) then
                        best = candidate
                    end
                end
            end
        end
    end
    return best, tool
end

local function stillThere(target)
    return target.block.Parent ~= nil and target.block.Name == target.key
end

-- One swing at the target through the game's own input, or the remote when that is out of reach.
local function swing(state, target)
    local handler = findTapHandler()
    if handler then
        local camera = workspace.CurrentCamera
        local hrp = root()
        if not (camera and hrp) then
            return
        end
        local saved = camera.CFrame
        camera.CFrame = CFrame.lookAt(hrp.Position + Vector3.new(0, 1.5, 0), target.position)
        local center = camera.ViewportSize / 2
        pcall(handler, Vector2.new(center.X, center.Y), false)
        camera.CFrame = saved
        Env.elevate()
    else
        Env.invoke("MiningService", "Hit", state.Id, target.x, target.y, target.z)
    end
end

local function mineOne(state, marker)
    local target, tool = chooseTarget(state, marker)
    if not target then
        return false
    end
    local stand = target.position + Vector3.new(0, MiningConfig.BlockSize + 1, 0)
    local hrp = root()
    if hrp and (hrp.Position - stand).Magnitude > 3 then
        teleport(CFrame.new(stand))
        Life.wait(0.2)
    end
    local damage = tool and tool.Damage or 1
    local interval = tool and tool.Interval or 0.45
    local swings = math.ceil(target.health / math.max(damage, 1)) + 4
    for _ = 1, swings do
        if not (Life.alive and Ui.on("AutoMine") and stillThere(target)) then
            break
        end
        local current = mineState()
        if current and (tonumber(current.Count) or 0) >= (tonumber(current.Capacity) or math.huge) then
            return true -- the bag filled up mid-block
        end
        swing(state, target)
        Life.wait(interval + 0.03)
    end
    if stillThere(target) then
        skipped[target.key] = os.clock() + SKIP_SECONDS
    end
    return true
end

local busy = false
local function run()
    busy = true
    Ui.travelling = "mining"
    local settle = os.clock() + 6
    while Ui.hatchInFlight and os.clock() < settle do
        Life.wait(0.05)
    end
    local hrp = root()
    local home = hrp and hrp.CFrame
    local ok, err = pcall(function()
        Ui.status = "Mining"
        if not enter() then
            session.note = session.note ~= "" and session.note or "Could not get into the mine."
            return
        end
        local idle = 0
        while Life.alive and Ui.on("AutoMine") do
            if not inMine() and not enter() then
                break
            end
            local state = mineState()
            local marker = MiningWorld and MiningWorld.Marker()
            if not (state and marker and state.Seed) then
                Life.wait(0.5)
            elseif (tonumber(state.Count) or 0) >= (tonumber(state.Capacity) or math.huge) then
                sellAndSpend()
            elseif not mineOne(state, marker) then
                -- nothing drawn to mine right here: let the pets work and look again
                idle += 1
                Life.wait(1)
                if idle % 10 == 0 then
                    table.clear(skipped)
                end
            else
                idle = 0
            end
        end
        if inMine() then
            if (tonumber((mineState() or {}).Count) or 0) > 0 then
                sellAndSpend()
            end
            onPad("Exit", function()
                return not inMine()
            end, 12)
        end
    end)
    Env.elevate()
    if not ok then
        Life.errors["mining:run"] = tostring(err)
        session.note = "Mining error: " .. tostring(err)
    end
    Life.wait(1)
    if home then
        teleport(home)
    end
    if Ui.status == "Mining" then
        Ui.status = "Idle"
    end
    Ui.travelling = false
    busy = false
end

local function short(n)
    for _, unit in ipairs({ { 1e6, "M" }, { 1e3, "K" } }) do
        if n >= unit[1] then
            return string.format("%.1f%s", n / unit[1], unit[2])
        end
    end
    return tostring(math.floor(n))
end

Life.loop("mining:auto", 1, function()
    local data = Env.data()
    local mining = data and type(data.Mining) == "table" and data.Mining or {}
    local state = inMine() and mineState() or nil
    local lines = {}
    local tools = MiningConfig and MiningConfig.Tools or {}
    local bags = MiningConfig and MiningConfig.Bags or {}
    local tool = tools[tonumber(mining.Tool) or 1]
    local bag = bags[tonumber(mining.Backpack) or 1]
    lines[1] = string.format("%s, %s. %s mining coins.", tool and tool.Name or "?", bag and bag.Name or "?",
        short(tonumber(mining.Coins) or 0))
    if state then
        local total = tonumber(state.Total) or 10000
        local mined = tonumber(state.Mined) or 0
        lines[#lines + 1] = string.format("Mine %.1f%% cleared (%d / %d), bag %d/%d.", mined / total * 100, mined, total,
            tonumber(state.Count) or 0, tonumber(state.Capacity) or 0)
    end
    if session.sold > 0 then
        lines[#lines + 1] = string.format("%d sales this session for %s mining coins.", session.sold, short(session.earned))
    end
    if session.note ~= "" then
        lines[#lines + 1] = session.note
    end
    if not Ui.on("AutoMine") then
        label:SetText("Off. " .. table.concat(lines, "\n"))
        return
    end
    label:SetText(table.concat(lines, "\n"))
    if not busy and not Ui.travelling and not Ui.hatchMoving and MiningWorld and MiningConfig then
        Life.spawn("mining:run", run)
    end
end)

Life.onCleanup(function()
    if busy then
        Ui.travelling = false
    end
end)

return {}
end
__modules["features/performance"] = function(use) -- src/games/tapsim/features/performance.luau
-- Home tab, Performance: the shared performance mode (see shared/performance) plus Tap Simulator's
-- own quality settings, which is where this game spends its frames: the hatch reveal that plays for
-- every auto hatch, pets following everyone, tap pop-ups and screen shake.
--
-- The game keeps those settings on the server (SettingsService.UpdateSetting { Name, Value },
-- definitions in Shared.Core.SettingsConfig), so the game itself skips the work instead of the hub
-- fighting it. Your own values are read before anything changes and put back when performance mode
-- goes off or the hub unloads.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local group = use("shared/performance").build(Ui.Tabs.Home)

local KEEP = "Keep my setting"
local PET_VALUES = { [KEEP] = nil, ["Hide other players' pets"] = 2, ["Hide all pets"] = 3 }

-- What performance mode sets, besides the pets choice below.
local GAME_SETTINGS = {
    PerformanceMode = 3, -- "Potato"
    HatchAnimation = 3, -- "Off": only drops the slow rare reveal, see "Hide hatching" below
    HideClicks = true,
    HideFlashes = true,
    ScreenShake = false,
    BlobShadows = false,
    HideTitles = true,
}

group:AddToggle("PerfGameSettings", {
    Text = "Use the game's lowest settings",
    Default = true,
    Tooltip = "While performance mode is on: Potato graphics, rare hatch reveal off, tap pop-ups, flashes, screen shake, blob shadows and titles hidden. Your settings come back afterwards.",
})
group:AddToggle("PerfHideHatching", {
    Text = "Hide hatching and crafting",
    Default = true,
    Tooltip = getconnections and "While performance mode is on, eggs you hatch and pets you craft no longer play their animation (the game has no setting for this). Hatching and crafting still happen."
        or "Your executor has no getconnections, so hatching cannot be hidden.",
})
group:AddDropdown("PerfHidePets", {
    Text = "Pets",
    Values = { KEEP, "Hide other players' pets", "Hide all pets" },
    Default = "Hide other players' pets",
    Tooltip = "Pets following players are a large share of what gets drawn and moved each frame.",
})

-- setting name -> the value it had before performance mode changed it. The game keeps settings on
-- the server, so if a session ends without switching performance mode off (a crash, a rejoin) the
-- next one would read "Potato" as your setting. The originals are kept on disk until put back.
local saved = {}
local FOLDER = "SlopixHub/TapSimulator"
local FILE = FOLDER .. "/game-settings.json"
local files = Env.files

local function persist()
    if not (files.writefile and files.isfolder and files.makefolder) then
        return
    end
    pcall(function()
        local path = ""
        for part in FOLDER:gmatch("[^/]+") do
            path = path == "" and part or path .. "/" .. part
            if not files.isfolder(path) then
                files.makefolder(path)
            end
        end
        files.writefile(FILE, Env.HttpService:JSONEncode(saved))
    end)
    Env.elevate()
end

do
    local ok, stored = pcall(function()
        return files.isfile and files.isfile(FILE) and Env.HttpService:JSONDecode(files.readfile(FILE))
    end)
    Env.elevate()
    if ok and type(stored) == "table" then
        for name, value in pairs(stored) do
            if type(name) == "string" and (type(value) == "number" or type(value) == "boolean") then
                saved[name] = value
            end
        end
    end
end

local SettingsConfig
do
    local ok, module = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Core.SettingsConfig)
    end)
    SettingsConfig = ok and type(module) == "table" and module or nil
end
local UserInputService = game:GetService("UserInputService")

-- The value the game is using. A setting you never changed is not stored at all, so its value is
-- the game's default (which differs on PC for some), read the same way the game reads it.
local function current(name)
    local data = Env.data()
    local settings = data and type(data.Settings) == "table" and data.Settings or nil
    if settings and settings[name] ~= nil then
        return settings[name]
    end
    if SettingsConfig then
        local pc = UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled
        local ok, value = Env.call(SettingsConfig.Read, settings, name, pc)
        if ok then
            return value
        end
    end
    return nil
end

-- Several changes in a row get refused now and then (a restore once silently left one behind), so
-- each write is spaced out and retried. task.wait, not Life.wait: this also runs while unloading.
local function write(name, value)
    for attempt = 1, 4 do
        local ok, result = Env.invoke("SettingsService", "UpdateSetting", { Name = name, Value = value })
        if ok and (type(result) ~= "table" or result.Success ~= false) then
            task.wait(0.15)
            return true
        end
        task.wait(0.4 * attempt)
    end
    return false
end

local function wanted()
    local list = {}
    if Ui.on("PerfGameSettings") then
        for name, value in pairs(GAME_SETTINGS) do
            list[name] = value
        end
    end
    local pets = PET_VALUES[Ui.Options.PerfHidePets.Value]
    if pets then
        list.HidePets = pets
    end
    return list
end

local function restore()
    for name, value in pairs(saved) do
        write(name, value)
    end
    table.clear(saved)
    persist()
end

-- Brings the game's settings in line with the toggles: changes what performance mode wants (saving
-- the old value the first time) and puts back anything it no longer wants.
local function apply()
    if not Ui.on("PerfMode") then
        restore()
        return
    end
    local want = wanted()
    local changed = false
    for name, value in pairs(want) do
        local now = current(name)
        if now ~= value then
            if saved[name] == nil and now ~= nil then
                saved[name] = now
                changed = true
            end
            write(name, value)
        end
    end
    for name, value in pairs(saved) do
        if want[name] == nil then
            write(name, value)
            saved[name] = nil
            changed = true
        end
    end
    if changed then
        persist()
    end
end

local pending = false
local function schedule()
    if pending then
        return
    end
    pending = true
    Life.spawn("performance:game-settings", function()
        apply()
        pending = false
    end)
end

-- Hatching and crafting on screen ---------------------------------------------------------------
--
-- The game's Hatch Animation setting only chooses which rarities get the slow reveal: every hatch
-- still plays its egg and pet card (HatchRenderer), and every craft its machine roll. The only way
-- to keep them off the screen is to stop the game's own handlers for those results. Their
-- connections are disabled while this is on and enabled again afterwards. Only functions from the
-- game's ReplicatedStorage scripts are touched, so the hub's own result handlers keep working.

local VISUAL_EVENTS = {
    { "EggService", "EggHatchResult" },
    { "EggService", "ForcedHatchResult" },
    { "EggService", "SecretSkyFireworks" },
    { "EggService", "SecretEggFlash" },
    { "EggService", "SecretCelebration" },
    { "EggService", "ExclusiveEggHatchObserved" },
    { "MachineService", "MachineCraftResult" },
}
local muted = {} -- connection -> true

local function findRemote(service, name)
    local services = Env.ReplicatedStorage:FindFirstChild("RemoteServices")
    local folder = services and services:FindFirstChild(service)
    local events = folder and folder:FindFirstChild("RE")
    return events and events:FindFirstChild(name)
end

local function fromGame(connection)
    local ok, source = pcall(function()
        local fn = connection.Function
        return fn and debug.info(fn, "s")
    end)
    return ok and type(source) == "string" and source:find("^ReplicatedStorage%.") ~= nil
end

local function muteVisuals()
    for _, pair in ipairs(VISUAL_EVENTS) do
        local remote = findRemote(pair[1], pair[2])
        local ok, connections = false, nil
        if remote then
            ok, connections = pcall(getconnections, remote.OnClientEvent)
        end
        for _, connection in ipairs(ok and type(connections) == "table" and connections or {}) do
            if not muted[connection] and fromGame(connection) and pcall(function()
                connection:Disable()
            end) then
                muted[connection] = true
            end
        end
    end
    Env.elevate()
end

local function unmuteVisuals()
    for connection in pairs(muted) do
        pcall(function()
            connection:Enable()
        end)
    end
    table.clear(muted)
    Env.elevate()
end

local function refreshVisuals()
    if type(getconnections) == "function" and Ui.on("PerfMode") and Ui.on("PerfHideHatching") then
        muteVisuals()
    elseif next(muted) ~= nil then
        unmuteVisuals()
    end
end

-- The library keeps one Changed handler per control; shared/performance already owns PerfMode's.
local sharedHandler = Ui.Toggles.PerfMode.Changed
Ui.Toggles.PerfMode:OnChanged(function(...)
    if type(sharedHandler) == "function" then
        sharedHandler(...)
    end
    schedule()
    refreshVisuals()
end)
Ui.Toggles.PerfGameSettings:OnChanged(schedule)
Ui.Options.PerfHidePets:OnChanged(schedule)
Ui.Toggles.PerfHideHatching:OnChanged(refreshVisuals)
-- A handler the game connects later (after a respawn, a menu opening) is caught on the next pass.
Life.loop("performance:visuals", 3, refreshVisuals)
Life.onCleanup(unmuteVisuals)

-- A previous session that never put your settings back: do it now, unless the saved config is
-- about to switch performance mode on (that keeps them, and puts them back when it goes off).
Life.spawn("performance:repair", function()
    Life.wait(3) -- after the config autoload has had its say
    if next(saved) ~= nil and not Ui.on("PerfMode") then
        restore()
    end
end)

Life.onCleanup(restore)

return {}
end
__modules["features/pets"] = function(use) -- src/games/tapsim/features/pets.luau
-- Pets tab (right): keep your strongest pets equipped. The game ranks and swaps them for you with
-- PetActionRequested { Action = "EquipBest" }, so firing it as new pets hatch means the team is
-- always your highest-power four without opening the inventory.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local tab = Ui.Tabs.Pets
local box = tab:AddGroupbox({ Side = "Right", Name = "Auto equip", IconName = "star" })

local function equipBest()
    Env.fire("PetService", "PetActionRequested", { Action = "EquipBest" })
end

box:AddToggle("AutoEquipBest", {
    Text = "Auto equip best pets",
    Default = false,
    Tooltip = "Keeps your highest-power pets equipped. Re-checks as you hatch so new strong pets go on automatically.",
})
Ui.automation("AutoEquipBest", true)
box:AddSlider("EquipEvery", {
    Text = "Re-equip every",
    Default = 5,
    Min = 2,
    Max = 30,
    Rounding = 0,
    Suffix = "s",
})
box:AddButton({
    Text = "Equip best now",
    Func = function()
        equipBest()
        Ui.notify("Tap Simulator", "Equipped your strongest pets.", 3)
    end,
})
local label = box:AddLabel("Auto equip is off.", true)

-- A compact read of what is on the team, so the label reflects the swap.
local function teamSummary()
    local data = Env.data()
    local pets = data and type(data.Pets) == "table" and data.Pets
    if not pets or type(pets.Owned) ~= "table" or type(pets.Equipped) ~= "table" then
        return nil
    end
    local names, best = {}, 0
    for _, petId in pairs(pets.Equipped) do
        local pet = pets.Owned[petId]
        if type(pet) == "table" then
            names[#names + 1] = string.format("%s (%s)", tostring(pet.Name), tostring(pet.Power or "?"))
            best = math.max(best, tonumber(pet.Power) or 0)
        end
    end
    return names, best
end

local lastEquip = 0
Life.loop("pets:equip", 1, function()
    if not Ui.on("AutoEquipBest") then
        return
    end
    local every = math.clamp(tonumber(Ui.Options.EquipEvery.Value) or 5, 2, 30)
    if os.clock() - lastEquip >= every then
        lastEquip = os.clock()
        equipBest()
        Ui.status = "Equipping best pets"
    end
    local names = teamSummary()
    if names then
        label:SetText("Equipped: " .. (table.concat(names, ", ")):sub(1, 140))
    end
end)

return {}
end
__modules["features/pickups"] = function(use) -- src/games/tapsim/features/pickups.luau
-- Rewards tab: the things that show up on screen to be clicked. The Lucky Ducky flying across the
-- screen, and the Balloon Party and "Pigs could fly" world events.
--
-- Lucky Ducky (LuckyDuckyService): once you have an hour of playtime, the server sends Spawn { Id,
-- Lifetime, Why } every 20-30 minutes and the duck crosses the screen for ~10 seconds. Claim(Id)
-- rolls x2 coins for 2 min (60%), a pile of coins (27%), x3 coins for 2 min (10%) or 1 in 4
-- hatches Golden for 1 min (3%). The server refuses a claim sooner than 0.3s after the spawn, so
-- the catch waits a human moment, then goes through the game's own LuckyDuckyController:CatchShown
-- (its animation, claim and reward banner); Claim(Id) is sent directly only if no duck was drawn.
--
-- Balloon Party (BalloonPartyService), every 45 minutes for 2 minutes: balloons launch around each
-- player (Launched { Uid, Origin, Rise, Phase, LaunchedAt, Size }) and rise on a path anyone can
-- compute (Shared.Admin.BalloonFlight). Hit(Uid) counts a tap from up to HitRange (150) studs, once
-- per HitCooldown per balloon; Size sets how many taps it takes. The server confirms each tap on
-- Hit (Uid, Taken, UserId), and Popped / Rewarded follow.
--
-- Pigs could fly (PigsCouldFlyService): pigs circle each player on PigFlight paths; one Hit(Uid)
-- from within 120 studs catches one, Caught (Uid, UserId) and Rewarded follow, Retired ends one.
--
-- Both events spawn around you, so nothing here moves the character: it taps what is in range.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local RunService = game:GetService("RunService")
local tab = Ui.Tabs.Rewards
local RS = Env.ReplicatedStorage

local function load(...)
    local path = { ... }
    local ok, module = Env.call(function()
        local node = RS
        for _, part in ipairs(path) do
            node = node:FindFirstChild(part)
        end
        return node and require(node)
    end)
    return ok and type(module) == "table" and module or nil
end

local DuckController = load("Controllers", "Game", "LuckyDuckyController")
local WorldEventConfig = load("Shared", "Admin", "WorldEventConfig")
local BalloonFlight = load("Shared", "Admin", "BalloonFlight")
local PigFlight = load("Shared", "Admin", "PigFlight")
local BalloonRules = WorldEventConfig and WorldEventConfig.Balloon or {}
local PigRules = WorldEventConfig and WorldEventConfig.Pig or {}

-- Inside the game's own ranges, so a tap is never judged out of reach on the server's clock.
local BALLOON_RANGE = (tonumber(BalloonRules.HitRange) or 150) - 15
local BALLOON_GAP = (tonumber(BalloonRules.HitCooldown) or 0.1) + 0.06
local PIG_RANGE = (tonumber(PigRules.HitRange) or 120) - 15
local PIG_GAP = 0.6
local TAP_GAP = 0.09 -- between any two taps, about as fast as a quick thumb

local box = tab:AddGroupbox({ Side = "Left", Name = "Pickups", IconName = "sparkles" })
box:AddToggle("AutoDuck", {
    Text = "Catch the Lucky Ducky",
    Default = true,
    Tooltip = "Catches the duck that flies across your screen every 20-30 minutes (after an hour of playtime): x2 or x3 coins for 2 minutes, a pile of coins, or Golden hatches for a minute.",
})
Ui.automation("AutoDuck", true)
box:AddToggle("AutoBalloons", {
    Text = "Pop Balloon Party balloons",
    Default = true,
    Tooltip = "During the Balloon Party event (every 45 minutes, 2 minutes long), taps every balloon within reach until it pops. Balloons give coins and gems.",
})
Ui.automation("AutoBalloons", true)
box:AddToggle("AutoPigs", {
    Text = "Catch flying pigs",
    Default = true,
    Tooltip = "During the \"Pigs could fly\" event, catches every pig within reach for coins and gems.",
})
Ui.automation("AutoPigs", true)
local label = box:AddLabel("Waiting for a duck, balloons or pigs.", true)

local session = { ducks = 0, duckNote = nil, balloons = 0, pigs = 0, coins = 0, gems = 0 }

local function root()
    local character = Env.LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function short(n)
    for _, unit in ipairs({ { 1e18, "Qi" }, { 1e15, "Q" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
        if n >= unit[1] then
            return string.format("%.1f%s", n / unit[1], unit[2])
        end
    end
    return tostring(math.floor(n))
end

local function addReward(reward)
    if type(reward) ~= "table" then
        return
    end
    session.coins += tonumber(reward.Coins) or 0
    session.gems += tonumber(reward.Gems) or 0
end

-- Lucky Ducky ----------------------------------------------------------------------------------

local function catchDuck(payload)
    Life.wait(0.7 + math.random() * 0.8)
    if not Ui.on("AutoDuck") then
        return
    end
    local caught = false
    if DuckController and type(DuckController.CatchShown) == "function" then
        local ok, result = Env.call(DuckController.CatchShown, DuckController)
        caught = ok and result == true
    end
    if caught then
        session.ducks += 1
        session.duckNote = "caught"
        return
    end
    local ok, result = Env.invoke("LuckyDuckyService", "Claim", payload.Id)
    if ok and type(result) == "table" and result.Success == true then
        session.ducks += 1
        session.duckNote = tostring(result.Title or result.Reward or "caught")
        if type(result.Coins) == "number" then
            session.coins += result.Coins
        end
    else
        session.duckNote = "got away: " .. tostring(type(result) == "table" and result.Reason or result)
    end
end

Life.spawn("pickups:duck", function()
    local remote = Env.remote("LuckyDuckyService", "Spawn")
    Life.connect(remote.OnClientEvent, function(payload)
        if Ui.on("AutoDuck") and type(payload) == "table" and payload.Id ~= nil then
            Life.spawn("pickups:duck-catch", catchDuck, payload)
        end
    end)
end)

-- Balloons and pigs ----------------------------------------------------------------------------

local balloons = {} -- uid -> { flight, needed, taken, last }
local pigs = {} -- uid -> { flight, last }
-- uids this hub tapped: Rewarded is only counted for those, whoever else it may reach.
local tappedByMe = {}

local function trackBalloon(flight)
    if type(flight) ~= "table" or type(flight.Uid) ~= "string" or balloons[flight.Uid] then
        return
    end
    if typeof(flight.Origin) ~= "Vector3" or type(flight.Rise) ~= "number" or type(flight.LaunchedAt) ~= "number" then
        return
    end
    local size = type(BalloonRules.Sizes) == "table" and BalloonRules.Sizes[flight.Size]
    balloons[flight.Uid] = {
        flight = flight,
        needed = size and tonumber(size.Hits) or 1,
        taken = 0,
        last = 0,
    }
end

local function trackPig(flight)
    if type(flight) ~= "table" or type(flight.Uid) ~= "string" or pigs[flight.Uid] then
        return
    end
    if typeof(flight.Centre) ~= "Vector3" or typeof(flight.Pass) ~= "Vector3" or type(flight.LaunchedAt) ~= "number" then
        return
    end
    pigs[flight.Uid] = { flight = flight, last = 0 }
end

Life.spawn("pickups:balloon-events", function()
    Life.connect(Env.remote("BalloonPartyService", "Launched").OnClientEvent, trackBalloon)
    Life.connect(Env.remote("BalloonPartyService", "Hit").OnClientEvent, function(uid, taken)
        local balloon = type(uid) == "string" and balloons[uid]
        if balloon and type(taken) == "number" then
            balloon.taken = math.max(balloon.taken, taken)
        end
    end)
    Life.connect(Env.remote("BalloonPartyService", "Popped").OnClientEvent, function(uid)
        if type(uid) == "string" then
            balloons[uid] = nil
        end
    end)
    Life.connect(Env.remote("BalloonPartyService", "Rewarded").OnClientEvent, function(uid, reward)
        if tappedByMe[uid] then
            tappedByMe[uid] = nil
            session.balloons += 1
            addReward(reward)
        end
    end)
    -- A party already running when the hub loads.
    local ok, active = Env.invoke("BalloonPartyService", "GetActive")
    for _, flight in ipairs(ok and type(active) == "table" and active or {}) do
        trackBalloon(flight)
    end
end)

Life.spawn("pickups:pig-events", function()
    Life.connect(Env.remote("PigsCouldFlyService", "Launched").OnClientEvent, trackPig)
    local function gone(uid)
        if type(uid) == "string" then
            pigs[uid] = nil
        end
    end
    Life.connect(Env.remote("PigsCouldFlyService", "Caught").OnClientEvent, gone)
    Life.connect(Env.remote("PigsCouldFlyService", "Retired").OnClientEvent, gone)
    Life.connect(Env.remote("PigsCouldFlyService", "Rewarded").OnClientEvent, function(uid, reward)
        if tappedByMe[uid] then
            tappedByMe[uid] = nil
            session.pigs += 1
            addReward(reward)
        end
    end)
    local ok, active = Env.invoke("PigsCouldFlyService", "GetActive")
    for _, flight in ipairs(ok and type(active) == "table" and active or {}) do
        trackPig(flight)
    end
end)

-- Where a balloon is now, or nil once it has flown off.
local function balloonAt(balloon, now)
    local age = now - balloon.flight.LaunchedAt
    if not BalloonFlight or age >= (BalloonFlight.Lifetime or 25) then
        return nil
    end
    local ok, position = pcall(BalloonFlight.Position, balloon.flight, age)
    return ok and typeof(position) == "Vector3" and position or nil
end

local function pigAt(pig, now)
    local age = now - pig.flight.LaunchedAt
    if not PigFlight or age >= (PigFlight.Lifetime or 40) then
        return nil
    end
    local ok, position = pcall(PigFlight.Position, pig.flight, age)
    return ok and typeof(position) == "Vector3" and position or nil
end

-- The next tap: a pig first (one tap catches it), then the balloon closest to popping, so a
-- tap is never spread thin across a sky full of half-hit balloons.
local function nextTap(here, now, clock)
    if Ui.on("AutoPigs") then
        for uid, pig in pairs(pigs) do
            local at = pigAt(pig, now)
            if not at then
                pigs[uid] = nil
            elseif clock - pig.last >= PIG_GAP and (at - here).Magnitude <= PIG_RANGE then
                return "PigsCouldFlyService", uid, pig
            end
        end
    end
    if Ui.on("AutoBalloons") then
        local best, bestUid, bestLeft
        for uid, balloon in pairs(balloons) do
            local at = balloonAt(balloon, now)
            if not at then
                balloons[uid] = nil
            elseif clock - balloon.last >= BALLOON_GAP and (at - here).Magnitude <= BALLOON_RANGE then
                local left = balloon.needed - balloon.taken
                if left > 0 and (not best or left < bestLeft) then
                    best, bestUid, bestLeft = balloon, uid, left
                end
            end
        end
        if best then
            return "BalloonPartyService", bestUid, best
        end
    end
    return nil
end

Life.spawn("pickups:tap", function()
    while Life.alive do
        local hrp = root()
        local tapped = false
        if hrp and (next(balloons) or next(pigs)) then
            local clock = os.clock()
            local service, uid, target = nextTap(hrp.Position, workspace:GetServerTimeNow(), clock)
            if service then
                target.last = clock
                tappedByMe[uid] = true
                Env.fire(service, "Hit", uid)
                tapped = true
            end
        end
        if tapped then
            Life.wait(TAP_GAP)
        else
            Life.wait(0.15)
        end
    end
end)

Life.loop("pickups:panel", 1, function()
    local live = 0
    for _ in pairs(balloons) do
        live += 1
    end
    local pigsLive = 0
    for _ in pairs(pigs) do
        pigsLive += 1
    end
    local lines = {
        string.format("Ducks caught: %d%s", session.ducks, session.duckNote and (" (last " .. session.duckNote .. ")") or ""),
        string.format("Balloons popped: %d, pigs caught: %d", session.balloons, session.pigs),
    }
    if session.coins > 0 or session.gems > 0 then
        lines[#lines + 1] = string.format("From them: %s coins, %s gems", short(session.coins), short(session.gems))
    end
    if live > 0 or pigsLive > 0 then
        lines[#lines + 1] = string.format("In the sky now: %d balloons, %d pigs", live, pigsLive)
    end
    label:SetText(table.concat(lines, "\n"))
end)

return {}
end
__modules["features/potions"] = function(use) -- src/games/tapsim/features/potions.luau
-- Craft tab (right): the potion machine on Spawn, and drinking what it makes.
--
-- PotionMachineService (Shared.Items.PotionBrewConfig, PotionCraftConfig):
--   Brew(name, slot)  starts a Coins, Luck or Gems Potion I in one of 3 slots. It takes 5 minutes
--                     and costs PotionBrewConfig.GetPrice(rebirths) gems (1 + 5% of your rebirths).
--   ClaimAll()        collects every finished slot.
--   Craft(output)     merges 3 of a Potion I into its Potion II.
-- All three answer { Success, Error } and refuse with "TooFar" unless you stand at the machine, so
-- the machine is a trip like a craft: auto hatch pauses, one visit claims, merges and refills the
-- slots, and you go back where you were.
--
-- BoostService.Use(name) drinks a potion from anywhere. Active boosts of one type add up
-- (Shared.Items.BoostFormula sums every active potion's Multi), so each chosen potion is drunk
-- again as soon as its own timer (Data.ActiveBoosts[name], > 0 while it runs) is out.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local Options = Ui.Options
local RS = Env.ReplicatedStorage
local tab = Ui.Tabs.Craft

local function load(...)
    local path = { ... }
    local ok, module = Env.call(function()
        local node = RS
        for _, part in ipairs(path) do
            node = node:FindFirstChild(part)
        end
        return node and require(node)
    end)
    return ok and type(module) == "table" and module or nil
end

local BrewConfig = load("Shared", "Items", "PotionBrewConfig")
local CraftConfig = load("Shared", "Items", "PotionCraftConfig")
local BoostConfig = load("Shared", "Items", "BoostConfig")

local RECIPES = CraftConfig and CraftConfig.Recipes or {}
local SLOTS = BrewConfig and BrewConfig.SlotCount or 3
local BREWABLE = BrewConfig and BrewConfig.Potions or { "Coins Potion I", "Luck Potion I", "Gems Potion I" }
local MACHINE = { "Map1", "PotionMachine" }
local MACHINE_FALLBACK = Vector3.new(-354, -524, -12047) -- moved in the Oct 16 update

-- Everything drinkable: the six potions first, then the rarer boosts you might hold.
local DRINKABLE, DEFAULT_DRINKS = {}, {}
do
    local definitions = BoostConfig and BoostConfig.Definitions or {}
    local potions, others = {}, {}
    for name, def in pairs(definitions) do
        if type(def) == "table" and (tonumber(def.Duration) or 0) > 0 then
            if name:find("Potion") then
                potions[#potions + 1] = name
            elseif name == "Octo Incubator" or name == "Enchant Overclocker" then
                others[#others + 1] = name
            end
        end
    end
    table.sort(potions)
    table.sort(others)
    for _, name in ipairs(potions) do
        DRINKABLE[#DRINKABLE + 1] = name
        DEFAULT_DRINKS[#DEFAULT_DRINKS + 1] = name
    end
    for _, name in ipairs(others) do
        DRINKABLE[#DRINKABLE + 1] = name
    end
end

local box = tab:AddGroupbox({ Side = "Right", Name = "Potions", IconName = "flask-conical" })
box:AddToggle("AutoBrew", {
    Text = "Auto brew potions",
    Default = false,
    Tooltip = "Keeps the potion machine's 3 slots brewing and collects each potion when it is done (5 minutes each). Each brew costs gems: 1 plus 5% of your rebirths.",
})
Ui.automation("AutoBrew")
box:AddDropdown("BrewPicks", {
    Text = "Brew these",
    Values = BREWABLE,
    Multi = true,
    Default = BREWABLE,
    Tooltip = "Each empty slot gets the chosen potion you have fewest of.",
})
box:AddToggle("AutoCraftPotions", {
    Text = "Auto upgrade potions",
    Default = false,
    Tooltip = "Turns 3 tier I potions into 1 tier II at the potion machine whenever you have enough.",
})
Ui.automation("AutoCraftPotions")
box:AddToggle("AutoDrink", {
    Text = "Auto drink potions",
    Default = false,
    Tooltip = "Drinks each chosen potion again as soon as it runs out, from anywhere. Potions of the same kind add up, so a Coins I and a Coins II both count.",
})
Ui.automation("AutoDrink", true)
box:AddDropdown("DrinkPicks", {
    Text = "Drink these",
    Values = #DRINKABLE > 0 and DRINKABLE or { "Coins Potion I" },
    Multi = true,
    Default = DEFAULT_DRINKS,
    Tooltip = "Octo Incubator (hatch 8 at once) and Enchant Overclocker are here too, off by default.",
})
local label = box:AddLabel("Idle.", true)

local session = { brewed = 0, claimed = 0, merged = 0, drunk = 0 }
local note = ""

local function boosts(data)
    return type(data.Boosts) == "table" and data.Boosts or {}
end

local function slots(data)
    local machine = type(data.PotionMachine) == "table" and data.PotionMachine or {}
    return type(machine.Slots) == "table" and machine.Slots or {}
end

local function brewPrice(data)
    if not BrewConfig then
        return math.huge
    end
    local rebirths = tonumber(type(data.Statistics) == "table" and data.Statistics.Rebirths) or 0
    local ok, price = Env.call(BrewConfig.GetPrice, rebirths)
    return ok and tonumber(price) or math.huge
end

local function gems(data)
    return tonumber(type(data.Currencies) == "table" and data.Currencies.Gems) or 0
end

-- What a visit to the machine would do now: finished slots, empty slots it can fill, merges.
local function machineWork(data)
    local ready, empty = 0, 0
    local now = os.time()
    for slot = 1, SLOTS do
        local entry = slots(data)[tostring(slot)]
        if type(entry) ~= "table" then
            empty += 1
        elseif (tonumber(entry.ReadyAt) or math.huge) <= now then
            ready += 1
        end
    end
    local brew = Ui.on("AutoBrew") and next(Options.BrewPicks.Value or {}) ~= nil
    local work = {
        claim = brew and ready > 0,
        fill = brew and empty > 0 and gems(data) >= brewPrice(data),
        merge = false,
    }
    if Ui.on("AutoCraftPotions") then
        local owned = boosts(data)
        for _, recipe in ipairs(RECIPES) do
            if (tonumber(owned[recipe.Input]) or 0) >= (recipe.Required or 3) then
                work.merge = true
            end
        end
    end
    return work, ready, empty
end

-- The chosen brewable potion you hold the fewest of, counting what is already brewing.
local function nextBrew(data)
    local picks = Options.BrewPicks.Value or {}
    local counts = {}
    for name, count in pairs(boosts(data)) do
        counts[name] = tonumber(count) or 0
    end
    for _, entry in pairs(slots(data)) do
        if type(entry) == "table" and entry.Name then
            counts[entry.Name] = (counts[entry.Name] or 0) + 1
        end
    end
    local best, fewest
    for _, name in ipairs(BREWABLE) do
        if picks[name] and (not best or (counts[name] or 0) < fewest) then
            best, fewest = name, counts[name] or 0
        end
    end
    return best
end

local function root()
    local character = Env.LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function machinePosition()
    local node = workspace
    for _, name in ipairs(MACHINE) do
        node = node and node:FindFirstChild(name)
    end
    local ok, pivot = false, nil
    if node then
        ok, pivot = pcall(node.GetPivot, node)
    end
    return ok and pivot.Position or MACHINE_FALLBACK
end

local function ask(name, ...)
    local ok, result = Env.invoke("PotionMachineService", name, ...)
    if ok and type(result) == "table" and result.Error == "RateLimited" then
        Life.wait(1)
        ok, result = Env.invoke("PotionMachineService", name, ...)
    end
    if ok and type(result) == "table" and result.Success then
        return result
    end
    return nil, tostring(ok and type(result) == "table" and result.Error or result)
end

local function atMachine()
    local data = Env.data()
    if not data then
        return
    end
    local work, ready = machineWork(data)
    if work.claim then
        local claimed, why = ask("ClaimAll")
        if claimed then
            session.claimed += ready
        else
            note = "Collect refused: " .. why .. "."
        end
        Life.wait(0.4)
    end
    if Ui.on("AutoCraftPotions") then
        for _, recipe in ipairs(RECIPES) do
            while Life.alive and Ui.on("AutoCraftPotions") do
                local current = Env.data()
                if not current or (tonumber(boosts(current)[recipe.Input]) or 0) < (recipe.Required or 3) then
                    break
                end
                local merged, why = ask("Craft", recipe.Output)
                if not merged then
                    note = "Upgrade refused: " .. why .. "."
                    break
                end
                session.merged += 1
                Life.wait(0.3)
            end
        end
    end
    if Ui.on("AutoBrew") then
        for slot = 1, SLOTS do
            local current = Env.data()
            if not current then
                break
            end
            if type(slots(current)[tostring(slot)]) ~= "table" then
                local potion = nextBrew(current)
                if not potion then
                    break
                end
                if gems(current) < brewPrice(current) then
                    note = "Not enough gems to brew."
                    break
                end
                local brewed, why = ask("Brew", potion, slot)
                if not brewed then
                    note = "Brew refused: " .. why .. "."
                    break
                end
                session.brewed += 1
                Life.wait(0.4)
            end
        end
    end
end

local busy = false
local function trip()
    if busy or Ui.hatchMoving or Ui.travelling then
        return
    end
    busy = true
    Ui.travelling = "potions"
    local settle = os.clock() + 6
    while Ui.hatchInFlight and os.clock() < settle do
        Life.wait(0.05)
    end
    local hrp = root()
    local home = hrp and hrp.CFrame
    local ok, err = pcall(function()
        Ui.status = "At the potion machine"
        local target = machinePosition()
        pcall(function()
            Env.LocalPlayer:RequestStreamAroundAsync(target, 10)
        end)
        Env.elevate()
        local here = root()
        if not here then
            return
        end
        here.AssemblyLinearVelocity = Vector3.zero
        here.CFrame = CFrame.new(target + Vector3.new(0, 4, 6))
        Life.wait(0.6)
        atMachine()
    end)
    Env.elevate()
    if not ok then
        Life.errors["potions:trip"] = tostring(err)
        note = "Potion trip error: " .. tostring(err)
    end
    -- The Craft tab's "Return to where I was" covers every machine trip.
    if home and (not Ui.Toggles.CraftReturn or Ui.on("CraftReturn")) then
        local back = root()
        if back then
            back.AssemblyLinearVelocity = Vector3.zero
            back.CFrame = home
        end
    end
    if Ui.status == "At the potion machine" then
        Ui.status = "Idle"
    end
    Ui.travelling = false
    busy = false
end

local nextTrip = 0
Life.loop("potions:machine", 2, function()
    if not (Ui.on("AutoBrew") or Ui.on("AutoCraftPotions")) or busy or os.clock() < nextTrip then
        return
    end
    local data = Env.data()
    if not data then
        return
    end
    local work = machineWork(data)
    if work.claim or work.fill or work.merge then
        nextTrip = os.clock() + 15 -- one visit at a time, and a refused one is not retried at once
        Life.spawn("potions:trip", trip)
    end
end)

-- Drinking --------------------------------------------------------------------------------------

local drinkRefused = {} -- name -> retry after (os.clock)
Life.loop("potions:drink", 2, function()
    if not Ui.on("AutoDrink") then
        return
    end
    local data = Env.data()
    if not data then
        return
    end
    local owned = boosts(data)
    local active = type(data.ActiveBoosts) == "table" and data.ActiveBoosts or {}
    local picks = Options.DrinkPicks.Value or {}
    for _, name in ipairs(DRINKABLE) do
        if picks[name] and (tonumber(owned[name]) or 0) > 0 and not ((tonumber(active[name]) or 0) > 0)
            and (drinkRefused[name] or 0) <= os.clock() then
            local ok, result = Env.invoke("BoostService", "Use", name)
            if ok and type(result) == "table" and result.Success then
                session.drunk += 1
                note = "Drank " .. name .. "."
            else
                drinkRefused[name] = os.clock() + 30
                note = string.format("Could not drink %s: %s.", name,
                    tostring(ok and type(result) == "table" and result.Error or result))
            end
            Life.wait(0.5)
        end
    end
end)

-- Panel -----------------------------------------------------------------------------------------

Life.loop("potions:panel", 1, function()
    local data = Env.data()
    if not data then
        return
    end
    local now = os.time()
    local parts = {}
    for slot = 1, SLOTS do
        local entry = slots(data)[tostring(slot)]
        if type(entry) ~= "table" then
            parts[#parts + 1] = "empty"
        else
            local left = (tonumber(entry.ReadyAt) or now) - now
            local short = tostring(entry.Name or "?"):gsub(" Potion", "")
            parts[#parts + 1] = left > 0 and string.format("%s %d:%02d", short, left // 60, left % 60)
                or (short .. " ready")
        end
    end
    local lines = {
        "Slots: " .. table.concat(parts, ", "),
        string.format("This session: %d brewed, %d collected, %d upgraded, %d drunk", session.brewed,
            session.claimed, session.merged, session.drunk),
    }
    if note ~= "" then
        lines[#lines + 1] = note
    end
    label:SetText(table.concat(lines, "\n"))
end)

Life.onCleanup(function()
    if busy then
        Ui.travelling = false
    end
end)

return {}
end
__modules["features/rewards"] = function(use) -- src/games/tapsim/features/rewards.luau
-- Rewards tab: everything the game hands out for free. Offline earnings, finished quests, tap
-- chests and the event spin wheel. Each claim is the game's own remote, fired only when the data
-- says there is something to take, so nothing spams a server that would just reject it.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local tab = Ui.Tabs.Rewards

-- Offline earnings -----------------------------------------------------------------------------

local offlineBox = tab:AddGroupbox({ Side = "Left", Name = "Offline earnings", IconName = "moon" })

local function claimOffline(instant)
    return (Env.invoke("OfflineRewardsService", "Claim", instant == true))
end

offlineBox:AddToggle("AutoClaimOffline", {
    Text = "Claim offline earnings on load",
    Default = true,
    Tooltip = "Claims whatever you banked while away as soon as the hub starts.",
})
offlineBox:AddButton({
    Text = "Claim now",
    Func = function()
        local ok = claimOffline(true)
        Ui.notify("Tap Simulator", ok and "Offline earnings claimed." or "Nothing to claim.", 4)
    end,
})
offlineBox:AddButton({
    Text = "Acknowledge offline hatches",
    Func = function()
        Env.invoke("OfflineRewardsService", "AcknowledgeHatches")
        Ui.notify("Tap Simulator", "Offline hatches acknowledged.", 3)
    end,
})

-- Quests -------------------------------------------------------------------------------------

local questBox = tab:AddGroupbox({ Side = "Left", Name = "Quests", IconName = "scroll-text" })
questBox:AddToggle("AutoClaimQuests", {
    Text = "Auto claim finished quests",
    Default = true,
    Tooltip = "Claims every quest that is complete but unclaimed.",
})
Ui.automation("AutoClaimQuests", true)
local questLabel = questBox:AddLabel("Idle.", true)

local claimedQuests = 0
Life.loop("rewards:quests", 2, function()
    if not Ui.on("AutoClaimQuests") then
        return
    end
    local data = Env.data()
    local quests = data and type(data.Quests) == "table" and data.Quests
    if not quests then
        return
    end
    local pending = 0
    for id, quest in pairs(quests) do
        if type(quest) == "table" and quest.Completed and not quest.Claimed then
            pending += 1
            local ok, res = Env.invoke("QuestService", "ClaimQuest", { Quest = id })
            if ok and (res == nil or type(res) ~= "table" or res.Success ~= false) then
                claimedQuests += 1
            end
            Life.wait(0.3)
        end
    end
    questLabel:SetText(pending > 0
        and string.format("Claimed %d quests this session.", claimedQuests)
        or string.format("No quests ready. %d claimed this session.", claimedQuests))
end)

-- Pet Index rewards ----------------------------------------------------------------------------
--
-- Each egg pays gems once you have found every pet it hatches, again for every pet in Golden,
-- Diamond and Rainbow, and "Secrets" pays when every secret pet is found. The Index screen's Claim
-- button sends PetIndexService.RewardClaimRequested(egg) and the server pays every tier that egg has
-- finished. A refused claim makes the game itself flash "No rewards to claim." with a sound, so this
-- only asks for an egg with a finished, unclaimed tier, and an egg the server turned down is not
-- asked again until you find another of its pets.

local LaunchEggConfig, PetIndexRewardConfig
do
    local ok, eggs = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Pets.LaunchEggConfig)
    end)
    LaunchEggConfig = ok and type(eggs) == "table" and eggs or nil
    local ok2, rewards = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Pets.PetIndexRewardConfig)
    end)
    PetIndexRewardConfig = ok2 and type(rewards) == "table" and rewards or nil
end

-- Reward tiers as PetIndexRewardConfig names them; IndexTiers keys the Rainbow tier "Shiny".
local INDEX_TIERS = { "Normal", "Golden", "Diamond", "Shiny" }

local function petFound(pets, name, tier)
    if tier == "Normal" then
        return type(pets.Index) == "table" and pets.Index[name] == true
    end
    local tiers = type(pets.IndexTiers) == "table" and pets.IndexTiers or {}
    return tiers[name .. "_" .. tier] == true or (tier == "Shiny" and tiers[name .. "_Rainbow"] == true)
end

local function tierClaimed(pets, egg, tier)
    local claimed = type(pets.IndexRewards) == "table" and pets.IndexRewards[egg]
    return type(claimed) == "table" and claimed[tier] == true
end

-- Every egg (plus "Secrets") with a finished tier the server has not paid yet, and how much of its
-- index is found, so a refusal can be remembered until that changes.
local function claimableIndex(pets)
    local list = {}
    if not (LaunchEggConfig and PetIndexRewardConfig) then
        return list
    end
    local secrets, secretsFound = 0, 0
    for egg, def in pairs(LaunchEggConfig) do
        if type(egg) == "string" and type(def) == "table" and type(def.Pets) == "table" then
            local found, ready = 0, false
            local rewards = PetIndexRewardConfig[egg]
            for _, tier in ipairs(INDEX_TIERS) do
                local have, total = 0, 0
                for name in pairs(def.Pets) do
                    total += 1
                    if petFound(pets, name, tier) then
                        have += 1
                    end
                end
                found += have
                if type(rewards) == "table" and type(rewards[tier]) == "number" and total > 0 and have == total
                    and not tierClaimed(pets, egg, tier) then
                    ready = true
                end
            end
            if ready then
                list[#list + 1] = { egg = egg, found = found }
            end
            for name in pairs(type(def.Secrets) == "table" and def.Secrets or {}) do
                secrets += 1
                if petFound(pets, name, "Normal") then
                    secretsFound += 1
                end
            end
        end
    end
    local secretReward = PetIndexRewardConfig.Secrets
    if secrets > 0 and secretsFound == secrets and type(secretReward) == "table"
        and type(secretReward.Complete) == "number" and not tierClaimed(pets, "Secrets", "Complete") then
        list[#list + 1] = { egg = "Secrets", found = secretsFound }
    end
    table.sort(list, function(a, b)
        return a.egg < b.egg
    end)
    return list
end

local indexBox = tab:AddGroupbox({ Side = "Left", Name = "Pet Index", IconName = "book-open" })
indexBox:AddToggle("AutoClaimIndex", {
    Text = "Auto claim index rewards",
    Default = true,
    Tooltip = "Claims the gems for every egg whose index you finish (Normal, Golden, Diamond and Rainbow) and the secret completion reward. Works from anywhere.",
})
Ui.automation("AutoClaimIndex", true)
local indexLabel = indexBox:AddLabel("Idle.", true)

local indexClaimed, indexLast = 0, nil
local indexRefused = {} -- egg -> pets found when the server last refused it
local indexWaiting -- the egg whose answer is pending
Life.spawn("rewards:index-results", function()
    local remote = Env.remote("PetIndexService", "RewardClaimResult")
    Life.connect(remote.OnClientEvent, function(result)
        if not indexWaiting then
            return
        end
        indexWaiting.result = type(result) == "table" and result or { Success = false }
    end)
end)

local function claimIndex(entry)
    local waiting = { egg = entry.egg }
    indexWaiting = waiting
    Env.fire("PetIndexService", "RewardClaimRequested", entry.egg)
    local deadline = os.clock() + 5
    while Life.alive and not waiting.result and os.clock() < deadline do
        Life.wait(0.1)
    end
    indexWaiting = nil
    if waiting.result and waiting.result.Success == true then
        indexClaimed += 1
        indexLast = entry.egg
        indexRefused[entry.egg] = nil
        return true
    end
    indexRefused[entry.egg] = entry.found
    return false
end

local function sweepIndex()
    local data = Env.data()
    local pets = data and type(data.Pets) == "table" and data.Pets
    if not pets then
        return 0
    end
    local claimed = 0
    for _, entry in ipairs(claimableIndex(pets)) do
        if indexRefused[entry.egg] ~= entry.found then
            if claimIndex(entry) then
                claimed += 1
            end
            Life.wait(0.5)
        end
    end
    return claimed
end

indexBox:AddButton({
    Text = "Claim now",
    Func = function()
        Life.spawn("rewards:index-manual", function()
            table.clear(indexRefused)
            local claimed = sweepIndex()
            Ui.notify("Tap Simulator", claimed > 0 and string.format("Claimed %d index rewards.", claimed)
                or "No index rewards to claim.", 4)
        end)
    end,
})

Life.loop("rewards:index", 5, function()
    if not Ui.on("AutoClaimIndex") then
        indexLabel:SetText("Off.")
        return
    end
    if not (LaunchEggConfig and PetIndexRewardConfig) then
        indexLabel:SetText("The game's index config could not be read.")
        return
    end
    sweepIndex()
    indexLabel:SetText(string.format("%d claimed this session%s.", indexClaimed,
        indexLast and (", last: " .. indexLast) or ""))
end)

-- Tap chests ---------------------------------------------------------------------------------

local chestBox = tab:AddGroupbox({ Side = "Right", Name = "Tap chests", IconName = "box" })
chestBox:AddToggle("AutoClaimChests", {
    Text = "Auto claim tap chests",
    Default = true,
    Tooltip = "Claims any tap chest the server shows as ready for you.",
})
Ui.automation("AutoClaimChests", true)
local chestLabel = chestBox:AddLabel("Idle.", true)

local claimedChests = 0
Life.loop("rewards:chests", 3, function()
    if not Ui.on("AutoClaimChests") then
        return
    end
    local data = Env.data()
    local chests = data and type(data.TapChests) == "table" and data.TapChests
    if not chests then
        return
    end
    local any = false
    for id in pairs(chests) do
        any = true
        local ok = Env.invoke("TapChestService", "Claim", id)
        if ok then
            claimedChests += 1
        end
        Life.wait(0.3)
    end
    chestLabel:SetText(any
        and string.format("Tried; %d chests claimed this session.", claimedChests)
        or "No tap chests ready.")
end)

-- Event spin wheel ---------------------------------------------------------------------------

local spinBox = tab:AddGroupbox({ Side = "Right", Name = "Spin wheel", IconName = "disc-3" })
spinBox:AddToggle("AutoSpin", {
    Text = "Auto spin event wheel",
    Default = false,
    Tooltip = "Spins each active event wheel on a timer. The server only gives a spin when one is free.",
})
Ui.automation("AutoSpin", true)
spinBox:AddSlider("SpinEvery", {
    Text = "Spin every",
    Default = 10,
    Min = 3,
    Max = 60,
    Rounding = 0,
    Suffix = "s",
})
local spinLabel = spinBox:AddLabel("Idle.", true)

local lastSpin, spins = 0, 0
Life.loop("rewards:spin", 1, function()
    if not Ui.on("AutoSpin") then
        return
    end
    local every = math.clamp(tonumber(Ui.Options.SpinEvery.Value) or 10, 3, 60)
    if os.clock() - lastSpin < every then
        return
    end
    local data = Env.data()
    local wheels = data and type(data.Spinwheels) == "table" and data.Spinwheels
    if not wheels then
        return
    end
    lastSpin = os.clock()
    local any = false
    for wheel in pairs(wheels) do
        any = true
        local ok = Env.invoke("EventWheelService", "Spin", { WheelType = wheel })
        if ok then
            spins += 1
        end
        Life.wait(0.3)
    end
    spinLabel:SetText(any and string.format("%d spins attempted this session.", spins) or "No event wheel active.")
end)

return {
    afterLoad = function()
        if Ui.on("AutoClaimOffline") then
            Life.spawn("rewards:offline", function()
                Life.wait(1)
                claimOffline(false)
            end)
        end
    end,
}
end
__modules["features/settings"] = function(use) -- src/games/tapsim/features/settings.luau
-- Settings tab (see shared/settings): Tap Simulator configs, and what each missing function changes.

use("core/ui")
local Settings = use("shared/settings")

return Settings.build({
    folder = "TapSimulator",
    effects = {
        queue_on_teleport = "the hub does not come back after a teleport: run the loader again",
        writefile = "configs, themes and the offline cache cannot be saved",
        readfile = "saved configs and cached downloads cannot be read",
        isfile = "saved configs and cached downloads cannot be located",
        isfolder = "config folders cannot be managed",
        makefolder = "config folders cannot be created",
        listfiles = "saved configs and themes cannot be listed",
        delfile = "saved configs cannot be deleted",
        setclipboard = "copy buttons display their text instead",
    },
})
end
__modules["features/skilltree"] = function(use) -- src/games/tapsim/features/skilltree.luau
-- Skills tab: buys the whole skill tree for you. Nodes cost gems and gate each other
-- (SubtreeLocked), so this walks every node in the game's config, unlocks the ones you can afford
-- now, and keeps trying -- a node that is SubtreeLocked today opens once its parent is bought.
--
-- SkillTreeService.Unlock { Name } answers { Success, Reason, Price, Missing }. The strong nodes
-- for a tapper are Click Power, Critical, Auto Clicker and Pet Power; auto-unlock just takes them
-- in config order as gems allow.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local tab = Ui.Tabs.Skills
local box = tab:AddGroupbox({ Side = "Left", Name = "Skill tree", IconName = "git-branch" })

-- Every node name in the game's skill tree config (all branches).
local NODES = {}
do
    local ok, cfg = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Progression.SkillTreeConfig)
    end)
    if ok and type(cfg) == "table" then
        local seen = {}
        local function walk(node)
            for _, value in pairs(node) do
                if type(value) == "table" then
                    local name = value.Name
                    if type(name) == "string" and not seen[name] then
                        seen[name] = true
                        NODES[#NODES + 1] = name
                    end
                    walk(value)
                end
            end
        end
        walk(cfg)
    end
end

box:AddToggle("AutoSkillTree", {
    Text = "Auto unlock skill tree",
    Default = false,
    Tooltip = "Buys every skill node you can afford. Nodes cost gems; locked subtrees open as their parent nodes are bought.",
})
Ui.automation("AutoSkillTree", true)
box:AddButton({
    Text = "Unlock all affordable now",
    Func = function()
        Ui.set("AutoSkillTree", true)
        Ui.notify("Tap Simulator", "Unlocking everything you can afford...", 4)
    end,
})
local label = box:AddLabel(string.format("%d skill nodes in the tree.", #NODES), true)

local PACE = 0.3
local unlockedCount = 0

local function isUnlocked(data, node)
    local tree = data and type(data.SkillTree) == "table" and data.SkillTree.Unlocked
    return type(tree) == "table" and tree[node] == true
end

Life.spawn("skills:auto", function()
    while Life.alive do
        if not Ui.on("AutoSkillTree") or #NODES == 0 then
            Life.wait(0.4)
            continue
        end
        local data = Env.data()
        local progressed, blocked, remaining = false, {}, 0
        for _, node in ipairs(NODES) do
            if not (Life.alive and Ui.on("AutoSkillTree")) then
                break
            end
            if not isUnlocked(data, node) then
                remaining += 1
                local ok, res = Env.invoke("SkillTreeService", "Unlock", { Name = node })
                if ok and type(res) == "table" then
                    if res.Success then
                        progressed = true
                        unlockedCount += 1
                        Ui.status = "Unlocking skills"
                        label:SetText(string.format("Unlocked %s (%d this session).", node, unlockedCount))
                        data = Env.data() -- refresh so a freed subtree is seen this pass
                    else
                        local reason = res.Reason or "unavailable"
                        blocked[reason] = (blocked[reason] or 0) + 1
                    end
                end
                Life.wait(PACE)
            end
        end
        if remaining == 0 then
            label:SetText(string.format("Whole skill tree unlocked (%d this session).", unlockedCount))
            Life.wait(5)
        elseif not progressed then
            -- Nothing affordable right now: show why and wait for gems to build up.
            local notes = {}
            for reason, count in pairs(blocked) do
                notes[#notes + 1] = string.format("%s x%d", reason, count)
            end
            table.sort(notes)
            label:SetText(string.format("%d nodes left. Waiting: %s", remaining,
                (table.concat(notes, ", ")):sub(1, 110)))
            Life.wait(3)
        end
    end
end)

return {}
end
__modules["features/tap"] = function(use) -- src/games/tapsim/features/tap.luau
-- Tapping tab: auto tap (the coin engine), the game's own auto clicker, and auto rebirth.
--
-- A tap is TapService.TapRequested { Auto, ClientSequence, Source }: the server credits coins for
-- each one at the player's current tap power, so firing them on a timer is the whole trick. Source
-- names what was pressed ("button" is the tap button, as the game's own client sends it). The
-- server counts at most one tap per GameConfig.ManualTapInterval (0.1s) and drops the rest, so the
-- rate tops out at 10 a second, and the gaps are only ever stretched by the jitter, never shortened
-- below that interval (a real player's taps are never perfectly periodic either).

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local Options = Ui.Options
local tab = Ui.Tabs.Tapping

-- Auto tap -------------------------------------------------------------------------------------

local MIN_GAP = 0.1
do
    local ok, config = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Core.GameConfig)
    end)
    local interval = ok and type(config) == "table" and tonumber(config.ManualTapInterval)
    if interval and interval > 0 then
        MIN_GAP = interval
    end
end
local MAX_RATE = math.max(1, math.floor(1 / MIN_GAP + 1e-6))

local tapBox = tab:AddGroupbox({ Side = "Left", Name = "Auto tap", IconName = "hand" })
tapBox:AddToggle("AutoTap", {
    Text = "Auto tap",
    Default = false,
    Tooltip = "Fires taps on a timer. Earns coins exactly as tapping does, at your current tap power.",
})
Ui.automation("AutoTap", true)
tapBox:AddSlider("TapRate", {
    Text = "Taps per second",
    Default = MAX_RATE,
    Min = 1,
    Max = MAX_RATE,
    Rounding = 0,
    Suffix = "/s",
    Tooltip = string.format("The server counts at most %d taps a second and throws faster ones away.", MAX_RATE),
})
local tapLabel = tapBox:AddLabel("Auto tap is off.", true)

-- The server only takes a tap whose ClientSequence is above the last one it took from you this
-- session, and drops the rest without a word. A reloaded hub that counted from 0 again was ignored
-- until it caught up with the copy before it, so the count lives in the executor's globals and
-- carries on across reloads. Every accepted tap is answered on TapResult; if a run of taps gets no
-- answer (the game's own taps or another script got ahead), the count jumps forward until they do.
local SEQUENCE_KEY = "__SlopixTapSequence"
local STALL_TAPS, STALL_SECONDS = 25, 2
local sequence = tonumber(Env.genv[SEQUENCE_KEY]) or 0
local lastAnswer, unanswered, resyncs = os.clock(), 0, 0

Life.spawn("tap:results", function()
    local results = Env.remote("TapService", "TapResult")
    Life.connect(results.OnClientEvent, function(result)
        if type(result) == "table" and result.ClientSequence ~= nil then
            lastAnswer, unanswered = os.clock(), 0
        end
    end)
end)

Life.spawn("tap:auto", function()
    local remote = Env.remote("TapService", "TapRequested")
    local session = 0
    while Life.alive do
        if Ui.on("AutoTap") then
            if unanswered >= STALL_TAPS and os.clock() - lastAnswer > STALL_SECONDS then
                sequence = math.max(sequence * 2, sequence + 1000000)
                lastAnswer, unanswered = os.clock(), 0
                resyncs += 1
            end
            sequence += 1
            session += 1
            unanswered += 1
            Env.genv[SEQUENCE_KEY] = sequence
            Env.elevate()
            remote:FireServer({ Auto = false, ClientSequence = sequence, Source = "button" })
            -- Tapping runs under everything else; it only names itself when nothing else has.
            if not Ui.status or Ui.status == "Idle" or Ui.status == "Off" then
                Ui.status = "Auto tapping"
            end
            if session % 11 == 0 then
                tapLabel:SetText(string.format("Tapped %d times this session.%s", session,
                    os.clock() - lastAnswer > STALL_SECONDS and "\nThe server is not answering taps; re-syncing."
                        or resyncs > 0 and string.format(" Re-synced %d times.", resyncs) or ""))
            end
            local rate = math.clamp(tonumber(Options.TapRate.Value) or MAX_RATE, 1, MAX_RATE)
            -- Jitter only lengthens a gap: one under the server's interval is a tap thrown away.
            local gap = math.max(1 / rate, MIN_GAP * 1.04)
            Life.wait(gap * (1 + math.random() * 0.12))
        else
            if Ui.status == "Auto tapping" then
                Ui.status = "Idle"
            end
            Life.wait(0.2)
        end
    end
end)

-- Auto clicker (the game's own) -----------------------------------------------------------------

local clickBox = tab:AddGroupbox({ Side = "Left", Name = "Auto clicker", IconName = "mouse-pointer-click" })
clickBox:AddToggle("AutoClicker", {
    Text = "Enable auto clicker",
    Default = false,
    Tooltip = "Turns on the game's built-in auto clicker (needs the auto-clicker unlock or gamepass).",
})
clickBox:AddLabel("Uses the game's own auto clicker. If you do not own it, the server ignores this.", true)

Ui.Toggles.AutoClicker:OnChanged(function(on)
    Env.fire("AutoClickService", "AutoClickRequested", { Enabled = on == true })
end)

-- Auto rebirth ---------------------------------------------------------------------------------
--
-- RebirthRequested { Index } buys 5^(Index-1) rebirths, all at the price for your current rebirth
-- count (Shared.Progression.RebirthConfig), so the biggest pack you can afford is the cheapest per
-- rebirth; any single pack can be pinned instead. The game has GetMaximumOptions(world) buttons (14
-- on the main world) and you have unlocked 1 + Upgrades.RebirthButtons of them (RebirthButtonConfig).
-- Every button is listed, but a locked one is never pressed. With the Auto Rebirth skill the request
-- is flagged Auto, exactly as the game's own auto rebirth sends it, and never more often than its
-- 1.5 seconds.

local function shared(...)
    local path = { ... }
    local ok, module = Env.call(function()
        local node = Env.ReplicatedStorage.Shared
        for _, part in ipairs(path) do
            node = node:FindFirstChild(part)
        end
        return node and require(node)
    end)
    return ok and module or nil
end
local RebirthConfig = shared("Progression", "RebirthConfig")
local RebirthButtonConfig = shared("Progression", "RebirthButtonConfig")
local SkillTreeFormula = shared("Progression", "SkillTreeFormula")

local REBIRTH_GAP = 1.5

local function worldOf(data)
    return data and type(data.Progression) == "table" and data.Progression.World or "Main"
end

local function coinsOf(data)
    return tonumber(type(data.Currencies) == "table" and data.Currencies.Coins) or 0
end

-- How many buttons you have unlocked.
local function buttonCount(data)
    local upgrades = type(data.Upgrades) == "table" and data.Upgrades.RebirthButtons or 0
    if RebirthButtonConfig then
        local ok, count = Env.call(function()
            local world = worldOf(data)
            return RebirthButtonConfig.GetOptionCount(RebirthButtonConfig.GetUnlockedCount(upgrades, world), world)
        end)
        if ok and type(count) == "number" then
            return count
        end
    end
    return 1 + math.clamp(math.floor(tonumber(upgrades) or 0), 0, 13)
end

-- How many buttons the game has on this world, unlocked or not.
local function allButtons(data)
    if RebirthButtonConfig then
        local ok, count = Env.call(RebirthButtonConfig.GetMaximumOptions, worldOf(data))
        if ok and type(count) == "number" then
            return count
        end
    end
    return 14
end

local function packAmount(index)
    if RebirthConfig then
        local ok, amount = Env.call(RebirthConfig.GetAmountFromIndex, index)
        if ok and type(amount) == "number" then
            return amount
        end
    end
    return 5 ^ (index - 1)
end

local function packPrice(data, index)
    if not RebirthConfig then
        return nil
    end
    local rebirths = tonumber(type(data.Statistics) == "table" and data.Statistics.Rebirths) or 0
    local ok, price = Env.call(RebirthConfig.GetPrice, packAmount(index), rebirths)
    return ok and type(price) == "number" and price or nil
end

-- The biggest unlocked pack you can afford now, or nil.
local function bestPack(data)
    local coins = coinsOf(data)
    for index = buttonCount(data), 1, -1 do
        local price = packPrice(data, index)
        if price and price <= coins then
            return index
        end
    end
    return nil
end

local function hasAutoRebirth(data)
    if not SkillTreeFormula then
        return false
    end
    local ok, value = Env.call(SkillTreeFormula.HasAutoRebirth, data)
    return ok and value == true
end

local function short(n)
    for _, unit in ipairs({ { 1e33, "Dc" }, { 1e30, "No" }, { 1e27, "Oc" }, { 1e24, "Sp" }, { 1e21, "Sx" }, { 1e18, "Qi" },
        { 1e15, "Q" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
        if n >= unit[1] then
            return string.format("%.1f%s", n / unit[1], unit[2])
        end
    end
    return tostring(math.floor(n))
end

local BIGGEST = "Biggest I can afford"
local packLabels, packIndex = { BIGGEST }, {}
for index = 1, allButtons(Env.data()) do
    local label = string.format("x%s rebirths (button %d)", short(packAmount(index)), index)
    packLabels[#packLabels + 1] = label
    packIndex[label] = index
end

local rebirthBox = tab:AddGroupbox({ Side = "Right", Name = "Rebirth", IconName = "rotate-ccw" })
rebirthBox:AddToggle("AutoRebirth", {
    Text = "Auto rebirth",
    Default = false,
    Tooltip = "Presses the chosen rebirth pack whenever you can afford it, as often as the game allows.",
})
Ui.automation("AutoRebirth", true)
rebirthBox:AddDropdown("RebirthPack", {
    Text = "Pack",
    Values = packLabels,
    Default = BIGGEST,
    Tooltip = "Every rebirth button in the game. 'Biggest I can afford' is the cheapest per rebirth, since a pack is priced at your current rebirth count. A pinned pack waits until you can afford it; a locked one (more come from the Rebirth Buttons upgrade) is never pressed.",
})
local rebirthLabel = rebirthBox:AddLabel("Auto rebirth is off.", true)

-- The pack to press now, or nil and why not.
local function choosePack(data)
    local pinned = packIndex[Options.RebirthPack.Value or ""]
    if not pinned then
        local index = bestPack(data)
        return index, index == nil and "saving coins for x1" or nil
    end
    local unlocked = buttonCount(data)
    if pinned > unlocked then
        return nil, string.format("button %d is locked (you have %d; the Rebirth Buttons upgrade unlocks more)", pinned, unlocked)
    end
    local price = packPrice(data, pinned)
    if not price then
        return nil, "rebirth prices are unavailable"
    end
    if price > coinsOf(data) then
        return nil, string.format("saving for x%s (%s coins)", short(packAmount(pinned)), short(price))
    end
    return pinned
end

local lastRebirth, rebirthed = -math.huge, 0
local function rebirthNow(data)
    local index, why = choosePack(data)
    if not index then
        return false, why
    end
    lastRebirth = os.clock()
    local payload = hasAutoRebirth(data) and { Auto = true, Index = index } or { Index = index }
    Env.fire("RebirthService", "RebirthRequested", payload)
    rebirthed += packAmount(index)
    return true, index
end

rebirthBox:AddButton({
    Text = "Rebirth now",
    Func = function()
        local data = Env.data()
        if not data then
            return
        end
        local ok, result = rebirthNow(data)
        Ui.notify("Tap Simulator", ok and string.format("Rebirthing x%s (button %d).", short(packAmount(result)), result)
            or ("Not rebirthing: " .. tostring(result) .. "."), 3)
    end,
})

Life.loop("tap:rebirth", 0.25, function()
    local data = Env.data()
    if not data then
        return
    end
    local index, why = choosePack(data)
    local upcoming = index and string.format("x%s for %s coins (button %d of %d)", short(packAmount(index)),
        short(packPrice(data, index) or 0), index, buttonCount(data)) or why
    if not Ui.on("AutoRebirth") then
        rebirthLabel:SetText("Off. Next: " .. tostring(upcoming) .. ".")
        return
    end
    if index and os.clock() - lastRebirth >= REBIRTH_GAP then
        rebirthNow(data)
    end
    rebirthLabel:SetText(string.format("%s this session. Next: %s.", short(rebirthed), tostring(upcoming)))
end)

return {}
end
__modules["features/treats"] = function(use) -- src/games/tapsim/features/treats.luau
-- Pets tab (right): feed treats to the team. Treats (from digging, quests and drops) give pet XP,
-- and a pet's level multiplies its power, so they are worth more on the pets you actually use.
--
-- ItemService.UseOnPet { Item, PetId, Amount } is what the game sends when you drag a treat onto a
-- pet; it answers { Success, Kind, Amount, LevelsGained, Level, ... }. Only items the game marks as
-- pet treats or pet levels (Shared.Items.ItemBehaviorConfig) are offered, one at a time to the
-- lowest-level equipped pet that is below its rarity's cap (Shared.Pets.PetLevelConfig), so the
-- whole team climbs together. Pet levels unlock once the bridge is lowered.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local Options = Ui.Options
local tab = Ui.Tabs.Pets

local ItemBehaviorConfig, PetLevelConfig
do
    local ok, items = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Items.ItemBehaviorConfig)
    end)
    ItemBehaviorConfig = ok and type(items) == "table" and items or nil
    local ok2, levels = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Pets.PetLevelConfig)
    end)
    PetLevelConfig = ok2 and type(levels) == "table" and levels or nil
end

local TREAT_KINDS = { PetTreat = true, PetLevels = true }
-- The plain XP treats digging and quests hand out; fruits and shards are rarer and left to you.
local DEFAULT_PICKS = { RegularTreat = true, BagOfTreats = true }
local PACE = 0.35

local treatNames, defaults = {}, {}
for name, behavior in pairs(ItemBehaviorConfig or {}) do
    if type(behavior) == "table" and TREAT_KINDS[behavior.Kind] and behavior.Availability == "Active" then
        treatNames[#treatNames + 1] = name
    end
end
table.sort(treatNames)
for _, name in ipairs(treatNames) do
    if DEFAULT_PICKS[name] then
        defaults[#defaults + 1] = name
    end
end

local box = tab:AddGroupbox({ Side = "Right", Name = "Treats", IconName = "cookie" })
box:AddToggle("AutoTreats", {
    Text = "Auto feed treats",
    Default = false,
    Tooltip = "Feeds the chosen treats to your equipped pets, lowest level first, skipping pets at their level cap.",
})
Ui.automation("AutoTreats", true)
box:AddDropdown("TreatPicks", {
    Text = "Use these",
    Values = #treatNames > 0 and treatNames or { "RegularTreat", "BagOfTreats" },
    Multi = true,
    Default = defaults,
    Tooltip = "Treat and Bag of Treats come from digging. Fruits, Golden Apples and shards are rarer; pick them only if you mean to spend them.",
})
local label = box:AddLabel("Auto feed is off.", true)

local function maxLevel(pet)
    if PetLevelConfig then
        local ok, cap = Env.call(PetLevelConfig.GetMaxLevel, pet.Rarity or "Common")
        if ok and type(cap) == "number" then
            return cap
        end
    end
    return 50
end

-- Equipped pets below their cap, lowest level (then least XP) first.
local function hungryPets(data)
    local pets = type(data.Pets) == "table" and data.Pets
    if not pets or type(pets.Equipped) ~= "table" or type(pets.Owned) ~= "table" then
        return {}
    end
    local list = {}
    for _, id in pairs(pets.Equipped) do
        local pet = pets.Owned[id]
        if type(pet) == "table" and (tonumber(pet.Level) or 1) < maxLevel(pet) then
            list[#list + 1] = { id = id, pet = pet }
        end
    end
    table.sort(list, function(a, b)
        local la, lb = tonumber(a.pet.Level) or 1, tonumber(b.pet.Level) or 1
        if la ~= lb then
            return la < lb
        end
        return (tonumber(a.pet.XP) or 0) < (tonumber(b.pet.XP) or 0)
    end)
    return list
end

local session = { fed = 0, levels = 0, used = {} }
local refused = {} -- item .. "|" .. pet id -> retry after (os.clock)
local note = ""

local function feedOnce(data)
    local owned = type(data.Items) == "table" and type(data.Items.Owned) == "table" and data.Items.Owned or {}
    local picks = Options.TreatPicks.Value or {}
    local pets = hungryPets(data)
    if #pets == 0 then
        return false, "Every equipped pet is at its level cap."
    end
    for _, item in ipairs(treatNames) do
        if picks[item] and (tonumber(owned[item]) or 0) > 0 then
            for _, entry in ipairs(pets) do
                local key = item .. "|" .. entry.id
                if (refused[key] or 0) <= os.clock() then
                    local ok, result = Env.invoke("ItemService", "UseOnPet", { Item = item, PetId = entry.id, Amount = 1 })
                    if ok and type(result) == "table" and result.Success == true then
                        session.fed += 1
                        session.levels += tonumber(result.LevelsGained) or 0
                        session.used[item] = (session.used[item] or 0) + 1
                        note = string.format("Last: %s on %s (level %s).", item, tostring(entry.pet.Name), tostring(result.Level or entry.pet.Level))
                        return true
                    end
                    refused[key] = os.clock() + 60
                    note = string.format("%s on %s refused: %s.", item, tostring(entry.pet.Name),
                        tostring(type(result) == "table" and (result.Reason or result.Error) or result))
                end
            end
        end
    end
    return false, "No chosen treats left."
end

Life.spawn("pets:treats", function()
    while Life.alive do
        local data = Env.data()
        local wait = 1
        if not Ui.on("AutoTreats") then
            label:SetText("Off.")
        elseif not ItemBehaviorConfig then
            label:SetText("The game's item config could not be read.")
        elseif data and PetLevelConfig and type(data.Progression) == "table" and data.Progression.BridgeLowered ~= true then
            label:SetText("Pet levels unlock once the bridge is lowered.")
        elseif data then
            local fed, why = feedOnce(data)
            local parts = {}
            for item, count in pairs(session.used) do
                parts[#parts + 1] = string.format("%d %s", count, item)
            end
            table.sort(parts)
            label:SetText(string.format("%s%d treats fed this session (+%d levels)%s.%s",
                fed and "" or (tostring(why) .. "\n"), session.fed, session.levels,
                #parts > 0 and (": " .. table.concat(parts, ", ")) or "", note ~= "" and ("\n" .. note) or ""))
            wait = fed and PACE or 3
        end
        Life.wait(wait)
    end
end)

return {}
end
__modules["features/upgrades"] = function(use) -- src/games/tapsim/features/upgrades.luau
-- Upgrades (Tapping tab, right): buys the tap upgrades for you. ClickMultiplier and CriticalChance
-- raise what every tap is worth, so keeping them maxed is the biggest lever after auto tap itself.
--
-- UpgradeService.Purchase { Name } answers { Success, Reason, Current }. The server rate-limits
-- purchases and locks some behind zones (Reason "RateLimited" / "ZoneLocked"), so this paces itself
-- and skips what it cannot buy yet instead of hammering a locked upgrade.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local Options = Ui.Options
local tab = Ui.Tabs.Tapping
local box = tab:AddGroupbox({ Side = "Right", Name = "Upgrades", IconName = "trending-up" })

-- The buyable upgrades, from the game's own config when it is readable.
local ORDER = { "FreeAutoClicker", "ClickMultiplier", "HatchSpeed", "CriticalChance", "AutoClickerSpeed", "Teleport" }
local ok, cfg = Env.call(function()
    return require(Env.ReplicatedStorage.Shared.Progression.UpgradeConfig)
end)
if ok and type(cfg) == "table" and type(cfg.Order) == "table" and #cfg.Order > 0 then
    ORDER = cfg.Order
end

box:AddToggle("AutoUpgrade", {
    Text = "Auto buy upgrades",
    Default = false,
    Tooltip = "Buys the chosen upgrades whenever you can afford one. Skips upgrades locked to a zone you have not reached.",
})
Ui.automation("AutoUpgrade", true)
box:AddDropdown("UpgradePicks", {
    Text = "Buy these",
    Values = ORDER,
    Multi = true,
    Default = ORDER, -- everything by default
    Tooltip = "ClickMultiplier and CriticalChance pay back fastest for a tapper.",
})
local label = box:AddLabel("Auto buy is off.", true)

local PACE = 0.4 -- seconds between purchase attempts (the server rate-limits)
local bought, blocked = 0, {}

Life.spawn("tap:upgrades", function()
    while Life.alive do
        if not Ui.on("AutoUpgrade") then
            Life.wait(0.3)
            continue
        end
        local picks = Options.UpgradePicks.Value or {}
        local progressed = false
        for _, name in ipairs(ORDER) do
            if not (Life.alive and Ui.on("AutoUpgrade")) then
                break
            end
            if picks[name] then
                local ok2, res = Env.invoke("UpgradeService", "Purchase", { Name = name })
                if ok2 and type(res) == "table" then
                    if res.Success then
                        bought += 1
                        progressed = true
                        blocked[name] = nil
                        Ui.status = "Bought " .. name
                        label:SetText(string.format("Bought %s (level %s). %d upgrades this session.",
                            name, tostring(res.Current or "?"), bought))
                    elseif res.Reason == "RateLimited" then
                        Life.wait(0.3)
                    else
                        blocked[name] = res.Reason or "unavailable"
                    end
                end
                Life.wait(PACE)
            end
        end
        if not progressed then
            -- Nothing bought this pass: report why and wait a little longer before trying again.
            local notes = {}
            for name, reason in pairs(blocked) do
                notes[#notes + 1] = name .. ": " .. reason
            end
            table.sort(notes)
            if #notes > 0 then
                label:SetText("Waiting: " .. table.concat(notes, ", "):sub(1, 120))
            end
            Life.wait(2)
        end
    end
end)

return {}
end
__modules["main"] = function(use) -- src/games/tapsim/main.luau
-- Entry point. Core first, then features in tab order, then settings (autoload last).

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Env = use("core/env")

-- Nothing is built until the replica and character are there (see core/ready).
use("core/ready").wait()

-- The whole hub reads the player's Replica through the game's DataController. An executor that
-- cannot require it cannot run the hub, so that is said once here instead of every feature failing.
local canRead, readError = pcall(function()
    return Env.preloadData() ~= nil
end)
Env.elevate()
if not canRead or not Env.data() then
    error("could not read your game data (Replica/DataController): " .. tostring(readError), 0)
end

-- A copy already running is closed first (two hubs fighting over the UI).
local previous = Env.genv.__SlopixHub
if type(previous) == "table" and type(previous.Ui) == "table" and previous.Ui.Library then
    pcall(previous.Ui.Library.Unload, previous.Ui.Library)
    Env.genv.__SlopixHub = nil
    Env.elevate()
end

local Life = use("shared/life")
local Ui = use("core/ui")

local FEATURES = {
    "features/home",
    "features/performance",
    "features/tap",
    "features/upgrades",
    "features/hatch",
    "features/pets",
    "features/treats",
    "features/enchant",
    "features/craft",
    "features/potions",
    "features/skilltree",
    "features/rewards",
    "features/pickups",
    "features/dig",
    "features/defense",
    "features/mining",
}

local function load(name)
    local ok, result = xpcall(use, debug.traceback, name)
    Env.elevate()
    if not ok then
        Life.errors["load:" .. name] = tostring(result)
        Ui.notify("Slopix Hub", string.format("%s failed to load; the rest still works.", name), 8)
        warn("[Slopix] " .. name .. ": " .. tostring(result))
    end
    return ok and result or nil
end

local loaded = {}
for _, name in ipairs(FEATURES) do
    loaded[name] = load(name)
end

local Settings = load("features/settings")
if Settings then
    Settings.finish()
end

-- After the autoload, so a saved "Claim offline earnings on load: off" is respected.
local Rewards = loaded["features/rewards"]
if Rewards and type(Rewards.afterLoad) == "function" then
    pcall(Rewards.afterLoad)
end

Env.genv.__SlopixHub = {
    Ui = Ui,
    Life = Life,
    Features = loaded,
}
Life.onCleanup(function()
    Env.genv.__SlopixHub = nil
end)

if Env.RuntimeState then
    Env.RuntimeState.onCleanup(function()
        Env.elevate()
        pcall(function()
            Ui.Library:Unload()
        end)
    end)
end

return "Slopix Hub loaded"
end
__modules["shared/env"] = function(use) -- src/shared/env.luau
-- Services, the local player, and the executor, the same for every game. Each game's core/env
-- extends this table with what only that game has (its ModuleScripts, its places).
--
-- Two Real quirks shape everything here:
--  * Calling into one of the game's modules, or yielding, can leave the thread without the
--    capability the UI needs ("lacking capability Plugin") while getthreadidentity() still says
--    8. Env.elevate() puts it back; Env.call() wraps a game call and elevates afterwards.
--  * Game modules are required lazily (Env.modules), so a feature only pays for what it uses.

local Env = {}

Env.Players = game:GetService("Players")
Env.ReplicatedStorage = game:GetService("ReplicatedStorage")
Env.RunService = game:GetService("RunService")
Env.CollectionService = game:GetService("CollectionService")
Env.VirtualUser = game:GetService("VirtualUser")
Env.TeleportService = game:GetService("TeleportService")
Env.HttpService = game:GetService("HttpService")
Env.LocalPlayer = Env.Players.LocalPlayer
if not Env.LocalPlayer then
    local deadline = os.clock() + 30
    repeat
        task.wait(0.05)
        Env.LocalPlayer = Env.Players.LocalPlayer
    until Env.LocalPlayer or os.clock() >= deadline
    assert(Env.LocalPlayer, "Slopix: local player is not ready; run the script again once the game loads")
end

local function first(...)
    for index = 1, select("#", ...) do
        local fn = select(index, ...)
        if type(fn) == "function" then return fn end
    end
end

local setIdentity = first(setthreadidentity, set_thread_identity, setidentity, setthreadcontext)

function Env.elevate()
    if setIdentity then
        pcall(setIdentity, 8)
    end
end

-- Calls fn (usually a game-module function) and restores the thread afterwards.
-- Returns ok, ... like pcall.
function Env.call(fn, ...)
    local results = table.pack(pcall(fn, ...))
    Env.elevate()
    return table.unpack(results, 1, results.n)
end

-- Executor functions -------------------------------------------------------------------------
-- Functions are optional unless the feature actually needs them. An executor's name or sUNC
-- score does not establish that any particular operation will succeed on this client.
-- The hub must not break where a function is
-- missing or goes by another name: everything executor-specific is looked up here once, and a
-- feature that cannot work without one says so instead of silently doing nothing.

local executorEnv = getfenv()
local function member(container, key)
    return type(container) == "table" and container[key] or nil
end
local syn, fluxus = executorEnv.syn, executorEnv.fluxus
local envOk, globalEnv = pcall(function() return getgenv() end)
Env.genv = envOk and type(globalEnv) == "table" and globalEnv or _G
Env.request = first(request, http_request, member(http, "request"), member(syn, "request"), member(fluxus, "request"))
Env.queueOnTeleport = first(queue_on_teleport, queueonteleport, member(syn, "queue_on_teleport"), member(fluxus, "queue_on_teleport"))
Env.setClipboard = first(setclipboard, toclipboard, set_clipboard, member(Clipboard, "set"))
Env.loadstring = first(loadstring)
Env.files = {}
for _, name in ipairs({ "readfile", "writefile", "isfile", "isfolder", "makefolder", "listfiles", "delfile" }) do
    Env.files[name] = first(executorEnv[name], Env.genv[name])
end
Env.canCache = Env.files.readfile ~= nil and Env.files.isfile ~= nil
Env.canSave = true
for _, name in ipairs({ "readfile", "writefile", "isfile", "isfolder", "makefolder", "listfiles", "delfile" }) do
    if not Env.files[name] then Env.canSave = false end
end
Env.traceback = debug and first(debug.traceback) or tostring
local executorOk, executorName = pcall(function()
    return identifyexecutor()
end)
Env.executor = executorOk and type(executorName) == "string" and executorName or "Unknown"

-- Missing functions that switch a feature off or change how it works, for the Settings tab.
-- A list, not a map: a map literal drops the missing (nil) ones before they can be counted.
-- Each game names the functions it cares about (Env.checkMissing), since what one needs another
-- never calls.
Env.missing = {}
local missingSet = {}
function Env.checkMissing(entries)
    for _, entry in ipairs(entries) do
        if type(entry[2]) ~= "function" and not missingSet[entry[1]] then
            missingSet[entry[1]] = true
            Env.missing[#Env.missing + 1] = entry[1]
        end
    end
end

-- Triggers a ProximityPrompt. Without fireproximityprompt it is pressed the way a player would,
-- with its hold lifted for the moment: that only takes while the prompt is on screen, i.e. in
-- range, which every caller already stands within (the server checks range either way).
function Env.firePrompt(prompt)
    if fireproximityprompt and pcall(fireproximityprompt, prompt) then
        Env.elevate()
        return true
    end
    local hold, sight = prompt.HoldDuration, prompt.RequiresLineOfSight
    local ok = pcall(function()
        prompt.HoldDuration = 0
        prompt.RequiresLineOfSight = false
        task.wait(0.1)
        prompt:InputHoldBegin()
        task.wait()
        prompt:InputHoldEnd()
    end)
    pcall(function()
        prompt.HoldDuration, prompt.RequiresLineOfSight = hold, sight
    end)
    Env.elevate()
    return ok
end

-- Simulates a touch (start then end) of `part` by `by`. False where the executor cannot.
function Env.touch(by, part)
    if not firetouchinterest then
        return false
    end
    local began = pcall(firetouchinterest, by, part, 0)
    task.wait() -- some executors only register the touch on the next physics step
    pcall(firetouchinterest, by, part, 1)
    return began
end

-- True when this client simulates `part`'s physics (so moving it replicates). Nil when the
-- executor cannot tell.
function Env.ownsPart(part)
    if not isnetworkowner then
        return nil
    end
    local ok, owns = pcall(isnetworkowner, part)
    return ok and owns == true
end

-- parent:WaitForChild(name) that gives up after `seconds` (30 by default) with an error naming
-- what is missing, so one absent folder fails its own feature instead of freezing the hub.
function Env.need(parent, name, seconds)
    local child = parent:WaitForChild(name, seconds or 30)
    Env.elevate()
    if not child then
        error(string.format("%s.%s is missing", parent:GetFullName(), name), 2)
    end
    return child
end

-- A lazy table of the game's ModuleScripts: modules.Name is required on first use and cached.
-- `paths` maps each name to its path under `root` (a list of child names).
--
-- Also returns load(name), the same loader as a plain function. Indexing runs it inside __index,
-- and Luau cannot yield there ("attempt to yield across metamethod/C-call boundary"), which a
-- module does while it waits on the game: right after a teleport from the main menu the client
-- controllers wait for the character and inventory. Load those with load() (Env.preload) first.
function Env.modules(root, paths)
    local cache, pending = {}, {}
    local function load(name)
        local loaded = rawget(cache, name)
        if loaded ~= nil then
            return loaded
        end
        local path = paths[name]
        assert(path, "Slopix: unknown game module " .. tostring(name))
        if Env.stopped then error("Slopix: hub unloaded", 2) end
        local work = pending[name]
        if not work then
            work = {}
            pending[name] = work
            task.spawn(function()
                work.result = table.pack(Env.call(function()
                    local node = root
                    local deadline = os.clock() + 30
                    for _, part in ipairs(path) do
                        node = Env.need(node, part, math.max(0.1, deadline - os.clock()))
                    end
                    return require(node)
                end))
                work.done = true
            end)
        end
        local deadline = os.clock() + 30
        repeat
            if work.done then break end
            task.wait(0.05)
        until Env.stopped or os.clock() >= deadline
        Env.elevate()
        if Env.stopped then error("Slopix: hub unloaded", 2) end
        if not work.done then
            error("Slopix: game module " .. name .. " is still loading; try again after the game finishes loading", 2)
        end
        pending[name] = nil
        if not work.result[1] then error(work.result[2], 2) end
        local module = work.result[2]
        rawset(cache, name, module)
        return module
    end
    return setmetatable(cache, {
        __index = function(_, name)
            return load(name)
        end,
    }), load
end

-- The live-reload handle when Real's live-reload started us (nil from the GitHub loader).
Env.RuntimeState = getfenv().STATE

return Env
end
__modules["shared/home"] = function(use) -- src/shared/home.luau
-- The part of the Home tab every game has: welcome, Discord invite, stop-all and anti-AFK.
-- Home.build returns the groupbox and a "Doing: ..." label the game's own Home keeps up to date.

local Env = use("shared/env")
local Life = use("shared/life")
local Ui = use("shared/ui")

local DISCORD_INVITE = "https://discord.com/invite/WdPcxf5B83"

local Home = {}

-- notes: extra lines shown under the welcome (where you are, what works there).
function Home.build(notes)
    local hub = Ui.Tabs.Home:AddGroupbox({ Side = "Left", Name = "Slopix Hub", IconName = "sparkles" })
    hub:AddLabel(string.format("Welcome, %s.", Env.LocalPlayer.DisplayName), true)
    for _, note in ipairs(notes or {}) do
        hub:AddLabel(note, true)
    end
    local statusLabel = hub:AddLabel("Doing: Idle", true)
    hub:AddButton({
        Text = "Copy Discord invite",
        Func = function()
            if Env.setClipboard and pcall(Env.setClipboard, DISCORD_INVITE) then
                Ui.notify("Slopix Hub", "Discord invite copied to your clipboard.", 4)
            else
                Ui.notify("Slopix Hub", DISCORD_INVITE, 10)
            end
        end,
    })
    hub:AddButton({
        Text = "Stop all automation",
        Func = function()
            Ui.stopAll()
            Ui.notify("Slopix Hub", "Everything is switched off.", 3)
        end,
    })
    hub:AddToggle("AntiAfk", {
        Text = "Anti AFK",
        Default = true,
        Tooltip = "Stops Roblox from kicking you after 20 idle minutes.",
    })

    local function nudge()
        if Ui.on("AntiAfk") then
            pcall(function()
                Env.VirtualUser:CaptureController()
                Env.VirtualUser:ClickButton2(Vector2.zero)
            end)
        end
    end
    local _, idleCallback = Life.connect(Env.LocalPlayer.Idled, nudge, "home:idle")

    -- Belt and braces: the idle kick itself listens on Idled too. Where the executor has
    -- getconnections (Real, Volt), those listeners are switched off while Anti AFK is on and
    -- switched back on when it goes off or the hub unloads.
    local silenced = {}
    local function silenceIdle(off)
        if off and type(getconnections) == "function" then
            local ok, connections = pcall(getconnections, Env.LocalPlayer.Idled)
            for _, connection in ipairs(ok and type(connections) == "table" and connections or {}) do
                local inspected, eligible = pcall(function()
                    return type(connection.Function) == "function" and connection.Function ~= idleCallback
                        and connection.Enabled == true and type(connection.Disable) == "function"
                end)
                if inspected and eligible and pcall(connection.Disable, connection) then
                    silenced[#silenced + 1] = connection
                end
            end
        elseif not off then
            for _, connection in ipairs(silenced) do
                pcall(function() connection:Enable() end)
            end
            table.clear(silenced)
        end
    end
    Ui.Toggles.AntiAfk:OnChanged(function(on)
        silenceIdle(false)
        silenceIdle(on)
    end)
    silenceIdle(Ui.on("AntiAfk"))
    Life.onCleanup(function()
        silenceIdle(false)
    end)

    return hub, statusLabel
end

return Home
end
__modules["shared/http"] = function(use) -- src/shared/http.luau
-- Downloads the hub's own dependencies (the UI library and its addons), with a file cache.
--
-- Real's game:HttpGet does not throw when a request fails: it returns the status as the body
-- ("429: Too Many Requests", "404: Not Found"), loadstring of that is nil, and calling it killed
-- the whole hub with "attempt to call a nil value". GitHub answers like that now and then, most
-- often on the reload right after a teleport. So every download is checked and retried, the last
-- good copy is kept, and that copy is used when GitHub will not answer.

local Env = use("shared/env")

local Http = {}

local CACHE = "SlopixHub/cache"
local TRIES = 3

local files = Env.files
local canWrite = files.writefile and files.isfolder and files.makefolder
local pending = {}
local memory = {}

-- The body at url, or nil and the reason. Tries the executor's request first (it reports the
-- status code), then game:HttpGet.
local function download(url)
    local reason
    if Env.request then
        local ok, res = Env.call(Env.request, { Url = url, Method = "GET" })
        if ok and type(res) == "table" and res.StatusCode ~= nil then
            if tonumber(res.StatusCode) == 200 and res.Success ~= false and type(res.Body) == "string" and res.Body ~= "" then
                return res.Body
            end
            reason = "HTTP " .. tostring(res.StatusCode)
        else
            reason = ok and "invalid HTTP response" or tostring(res)
        end
    end
    local ok, body = Env.call(function() return game:HttpGet(url) end)
    if not ok then
        return nil, reason or tostring(body)
    end
    if type(body) ~= "string" or body == "" then
        return nil, "empty response"
    end
    local status = body:match("^%d%d%d: [^\n]*")
    if status then
        return nil, status
    end
    return body
end

local function get(url)
    local work = pending[url]
    if not work then
        work = {}
        pending[url] = work
        task.spawn(function()
            local ok, body, err = pcall(download, url)
            work.body, work.error = ok and body or nil, ok and err or tostring(body)
            work.done = true
        end)
    end
    local deadline = os.clock() + 15
    while not work.done and os.clock() < deadline do task.wait(0.05) end
    Env.elevate()
    if not work.done then
        -- Leave this one in flight. Reloading an addon must not spawn duplicate hung requests.
        return nil, "download timed out", true
    end
    pending[url] = nil
    return work.body, work.error
end

local function save(path, body)
    local dir = ""
    for part in CACHE:gmatch("[^/]+") do
        dir = dir == "" and part or dir .. "/" .. part
        if not files.isfolder(dir) then
            files.makefolder(dir)
        end
    end
    files.writefile(path, body)
end

local function compile(body, name)
    if not Env.loadstring then return nil, "loadstring is unavailable" end
    if type(body) ~= "string" or body == "" then return nil, "empty source" end
    local ok, chunk, reason = Env.call(Env.loadstring, body, "@" .. name)
    if not ok then return nil, tostring(chunk) end
    if type(chunk) ~= "function" then return nil, reason or "compilation failed" end
    return chunk
end

-- Downloads url and compiles it (chunk name `name`). Falls back to the cached copy saved under
-- `name` by an earlier load. Returns the compiled chunk; errors with the reason when neither works.
function Http.load(url, name)
    if not Env.loadstring then error("Slopix: loadstring is unavailable; optional downloads cannot be loaded", 0) end
    local path = CACHE .. "/" .. name
    local reason
    if memory[url] then
        local chunk = compile(memory[url], name)
        if chunk then return chunk end
    end
    for attempt = 1, TRIES do
        local body, err, timedOut = get(url)
        Env.elevate()
        if body then
            local chunk, compileError = compile(body, name)
            if chunk then
                memory[url] = body
                if canWrite then
                    pcall(save, path, body)
                end
                return chunk
            end
            err = compileError -- a cut-off download
        end
        reason = err
        if timedOut then break end
        if attempt < TRIES then
            task.wait(attempt)
        end
    end
    local ok, cached = pcall(function()
        return Env.canCache and files.isfile(path) and files.readfile(path)
    end)
    local chunk = ok and compile(cached, name)
    if chunk then
        warn(string.format("[Slopix] %s: %s, using the cached copy", name, tostring(reason)))
        return chunk
    end
    error(string.format("could not download %s (%s)", name, tostring(reason)), 0)
end

return Http
end
__modules["shared/life"] = function(use) -- src/shared/life.luau
-- Lifecycle: one "alive" flag for the whole hub, a teardown list, and guarded loops.
--
-- Every background loop goes through Life.loop so it elevates the thread on each pass, stops on
-- unload, and records its last error in Life.errors[name] instead of dying silently inside a
-- task.spawn (which is how panels used to break without anyone noticing).

local Env = use("shared/env")

local Life = {
    alive = true,
    errors = {},
}

local cleanups = {}
local workers = {}
local connectionId = 0

function Life.onCleanup(fn)
    if not Life.alive then
        pcall(fn)
        return
    end
    cleanups[#cleanups + 1] = fn
end

function Life.call(name, fn, ...)
    if not Life.alive then return false, "hub unloaded" end
    Env.elevate()
    local result = table.pack(xpcall(fn, Env.traceback, ...))
    Env.elevate()
    Life.errors[name] = not result[1] and tostring(result[2]) or nil
    return table.unpack(result, 1, result.n)
end

function Life.spawn(name, fn, ...)
    local args = table.pack(...)
    -- defer lets us track the thread before its first instruction (including a shutdown).
    local thread
    thread = task.defer(function()
        Life.call(name, fn, table.unpack(args, 1, args.n))
        workers[thread] = nil
    end)
    workers[thread] = true
    return thread
end

function Life.connect(signal, fn, name)
    connectionId += 1
    name = name or ("event:" .. connectionId)
    local function guarded(...)
        Life.call(name, fn, ...)
    end
    local connection = signal:Connect(guarded)
    Life.onCleanup(function()
        connection:Disconnect()
    end)
    return connection, guarded
end

-- Runs fn every `interval` seconds (a number, or a function returning one) until unload.
function Life.loop(name, interval, fn)
    Life.spawn("loop:" .. name, function()
        local failures = 0
        while Life.alive do
            local ok = Life.call(name, fn)
            failures = ok and 0 or math.min(failures + 1, 5)
            if not Life.alive then
                break
            end
            local intervalOk, delay = pcall(function()
                return type(interval) == "function" and interval() or interval
            end)
            delay = intervalOk and tonumber(delay) or 1
            if not delay or delay ~= delay or delay == math.huge then delay = 1 end
            -- A broken API should not be hammered several times per frame.
            task.wait(math.max(0.05, delay, failures > 0 and 2 ^ (failures - 1) or 0))
        end
    end)
end

-- Waits up to `seconds`, returning early (false) once the hub is unloading.
function Life.wait(seconds)
    local deadline = os.clock() + seconds
    repeat
        -- In slices of at most 0.1s so an unload is noticed, but never past the deadline: a full
        -- 0.1s slice after a 0.11s wait's first one made it 0.2s.
        task.wait(math.min(0.1, math.max(0, deadline - os.clock())))
    until not Life.alive or os.clock() >= deadline
    Env.elevate()
    return Life.alive
end

function Life.shutdown()
    if not Life.alive then
        return
    end
    Life.alive = false
    for thread in pairs(workers) do
        if thread ~= coroutine.running() then pcall(task.cancel, thread) end
    end
    table.clear(workers)
    for index = #cleanups, 1, -1 do
        pcall(cleanups[index])
    end
    table.clear(cleanups)
end

return Life
end
__modules["shared/performance"] = function(use) -- src/shared/performance.luau
-- Performance mode, for long AFK farming: cuts what the client draws. Every property it changes is
-- written down first and put back when it goes off or the hub unloads, so nothing sticks.
--   Performance mode   shadows, post effects (bloom, blur, sun rays, colour correction, depth of
--                      field), particles, beams, trails and fire, water waves and reflections, the
--                      render quality, and the frame rate (the FPS limit)
--   3D rendering off   Roblox stops drawing the world at all; the hub's window still shows
-- Effects the game adds while it is on (weather, lightning, hatches) are switched off as they come.

local Env = use("shared/env")
local Life = use("shared/life")
local Ui = use("shared/ui")

local Performance = {}

local EFFECTS = { "ParticleEmitter", "Trail", "Beam", "Fire", "Smoke", "Sparkles", "PostEffect", "Clouds" }
local DEFAULT_FPS = 60 -- what the frame rate goes back to where the executor cannot say what it was

local saved = setmetatable({}, { __mode = "k" }) -- instance -> { property -> original value }
local savedFps
local active = false

local function set(instance, property, value)
    local ok, current = pcall(function()
        return instance[property]
    end)
    if not ok or current == value then
        return
    end
    local entry = saved[instance]
    if not entry then
        entry = {}
        saved[instance] = entry
    end
    if entry[property] == nil then
        entry[property] = current
    end
    pcall(function()
        instance[property] = value
    end)
end

local function isEffect(instance)
    for _, class in ipairs(EFFECTS) do
        if instance:IsA(class) then
            return true
        end
    end
    return false
end

local function quiet(instance)
    if isEffect(instance) then
        set(instance, "Enabled", false)
    end
end

local function applyFps()
    if active and setfpscap then
        pcall(setfpscap, Ui.Options.PerfFps.Value)
    end
end

local function enable()
    if active then
        return
    end
    active = true
    if setfpscap then
        local ok, cap = pcall(function()
            return getfpscap and getfpscap()
        end)
        savedFps = ok and tonumber(cap) or DEFAULT_FPS
        applyFps()
    end
    local lighting = game:GetService("Lighting")
    set(lighting, "GlobalShadows", false)
    local terrain = workspace:FindFirstChildOfClass("Terrain")
    if terrain then
        set(terrain, "WaterWaveSize", 0)
        set(terrain, "WaterWaveSpeed", 0)
        set(terrain, "WaterReflectance", 0)
        set(terrain, "Decoration", false)
    end
    pcall(function()
        set(settings().Rendering, "QualityLevel", Enum.QualityLevel.Level01)
    end)
    for _, root in ipairs({ lighting, workspace }) do
        for index, instance in ipairs(root:GetDescendants()) do
            if not active then
                return
            end
            quiet(instance)
            if index % 4000 == 0 then
                task.wait() -- a big map in one go is a visible hitch
            end
        end
    end
end

local function disable()
    active = false
    for instance, properties in pairs(saved) do
        for property, value in pairs(properties) do
            pcall(function()
                instance[property] = value
            end)
        end
    end
    table.clear(saved)
    if savedFps and setfpscap then
        pcall(setfpscap, savedFps)
        savedFps = nil
    end
end

local function setRendering(on)
    pcall(Env.RunService.Set3dRenderingEnabled, Env.RunService, on)
end

-- The "Performance" box on `tab`.
function Performance.build(tab)
    local group = tab:AddGroupbox({ Side = "Left", Name = "Performance", IconName = "gauge" })
    group:AddToggle("PerfMode", {
        Text = "Performance mode",
        Default = false,
        Tooltip = "Turns off shadows, post effects, particles and water animation, lowers the render quality and limits the frame rate. All of it comes back when you switch it off.",
    })
    group:AddSlider("PerfFps", {
        Text = "FPS limit",
        Default = 30,
        Min = 5,
        Max = 240,
        Rounding = 0,
        Tooltip = setfpscap and "The frame rate while performance mode is on. Below about 15 the automation reacts more slowly."
            or "Your executor has no setfpscap, so the frame rate cannot be limited.",
    })
    group:AddToggle("PerfNoRender", {
        Text = "Turn off 3D rendering",
        Default = false,
        Tooltip = "The world is no longer drawn (a blank screen with the hub on it): the biggest saving while AFK. Everything keeps running.",
    })

    Ui.Toggles.PerfMode:OnChanged(function(on)
        if on then
            task.spawn(enable)
        else
            disable()
        end
    end)
    Ui.Options.PerfFps:OnChanged(applyFps)
    Ui.Toggles.PerfNoRender:OnChanged(function(on)
        setRendering(not on)
    end)

    for _, root in ipairs({ game:GetService("Lighting"), workspace }) do
        Life.connect(root.DescendantAdded, function(instance)
            if active then
                quiet(instance)
            end
        end)
    end
    Life.onCleanup(function()
        disable()
        setRendering(true)
    end)
    return group
end

return Performance
end
__modules["shared/settings"] = function(use) -- src/shared/settings.luau
-- Settings tab: menu options, the official Obsidian ThemeManager and SaveManager addons.
-- Each game's features/settings calls Settings.build with its config folder and what a missing
-- executor function changes there. Settings.finish() loads the autoload config; main calls it
-- after every feature is built so a saved config can switch toggles on only once their handlers
-- exist.

local Env = use("shared/env")
local Http = use("shared/http")
local Ui = use("shared/ui")
local Life = use("shared/life")

local ADDONS = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/addons/"

local Settings = {}

local function fetch(file)
    local ok, result = pcall(function()
        return Http.load(ADDONS .. file, file)()
    end)
    Env.elevate()
    return ok and result or nil, result
end

-- options.folder: where this game's configs are saved (under SlopixHub/).
-- options.effects: { [executor function] = "what goes missing without it" }.
function Settings.build(options)
    local Library, Options = Ui.Library, Ui.Options
    local tab = Ui.Tabs.Settings

    local menu = tab:AddGroupbox({ Side = "Left", Name = "Menu", IconName = "sliders-horizontal" })
    menu:AddDropdown("NotificationSide", {
        Text = "Notification side",
        Values = { "Left", "Right" },
        Default = "Right",
        Callback = function(value)
            Library:SetNotifySide(value)
        end,
    })
    menu:AddDropdown("DPIScale", {
        Text = "DPI scale",
        Values = { "50%", "75%", "100%", "125%", "150%", "175%", "200%" },
        Default = "100%",
        Callback = function(value)
            Library:SetDPIScale(tonumber((value:gsub("%%", ""))))
        end,
    })
    menu:AddDivider()
    menu:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", {
        Default = "RightShift",
        NoUI = true,
        Text = "Menu keybind",
    })
    menu:AddButton("Unload", function()
        Library:Unload()
    end)
    Library.ToggleKeybind = Options.MenuKeybind

    -- What this executor lacks and what that changes, so a bug report says it up front.
    local compat = tab:AddGroupbox({ Side = "Left", Name = "Compatibility", IconName = "cpu" })
    local lines = { "Executor: " .. Env.executor }
    for _, name in ipairs(Env.missing) do
        lines[#lines + 1] = string.format("No %s: %s.", name, options.effects[name] or "some features are limited")
    end
    if #Env.missing == 0 then
        lines[#lines + 1] = "Required function names are available. Runtime support depends on the executor."
    end
    compat:AddLabel(table.concat(lines, "\n"), true)
    local runtimeLabel = compat:AddLabel("Runtime: ready.", true)
    Life.loop("settings:runtime", 2, function()
        local messages = {}
        for name, reason in pairs(Env.requestIssues or {}) do
            messages[#messages + 1] = name .. ": " .. reason
        end
        for name, reason in pairs(Life.errors) do
            if name ~= "settings:runtime" then
                messages[#messages + 1] = name .. ": " .. (tostring(reason):match("^[^\n]+") or "unavailable")
            end
        end
        table.sort(messages)
        local extra = math.max(0, #messages - 4)
        while #messages > 4 do table.remove(messages) end
        if extra > 0 then messages[#messages + 1] = string.format("%d more runtime messages.", extra) end
        runtimeLabel:SetText(#messages > 0 and table.concat(messages, "\n") or "Runtime: ready.")
    end)

    if not Env.canSave or not Env.loadstring then
        local storage = tab:AddGroupbox({ Side = "Right", Name = "Saved settings", IconName = "save" })
        storage:AddLabel("Saved configs and custom themes are unavailable on this executor. You can still change the controls for this session.", true)
        function Settings.finish() end
        return Settings
    end

    -- Each addon is set up under pcall: one that breaks (no file functions, an upstream change)
    -- costs its own section, not the whole Settings tab.
    local SaveManager, saveError = fetch("SaveManager.lua")
    if SaveManager then
        local ok, err = pcall(function()
            SaveManager:SetLibrary(Library)
            SaveManager:IgnoreThemeSettings()
            SaveManager:SetIgnoreIndexes({ "MenuKeybind" })
            SaveManager:SetFolder("SlopixHub/" .. options.folder)
            SaveManager:BuildConfigSection(tab)
        end)
        Env.elevate()
        if not ok then
            SaveManager, saveError = nil, err
        end
    end
    if not SaveManager then
        Ui.notify("Slopix Hub", "Could not load the config manager: " .. tostring(saveError), 6)
    end

    local ThemeManager, themeError = fetch("ThemeManager.lua")
    if ThemeManager then
        local ok, err = pcall(function()
            ThemeManager:SetLibrary(Library)
            ThemeManager:SetFolder("SlopixHub")
            -- The crimson palette as "Default"; FontFace must be one of the Font Face dropdown values.
            ThemeManager:SetDefaultTheme({
                BackgroundColor = "0d0c12",
                MainColor = "1e1b28",
                AccentColor = "eb4060",
                OutlineColor = "302b3e",
                FontColor = "f0eef6",
                FontFace = "BuilderSans",
            })
            ThemeManager:ApplyToTab(tab)
            local _, hasSavedDefault = ThemeManager:GetDefaultTheme()
            if hasSavedDefault then
                ThemeManager:LoadDefault()
            else
                Options.ThemeManager_ThemeList:SetValue("Default")
            end
        end)
        Env.elevate()
        if not ok then
            ThemeManager, themeError = nil, err
        end
    end
    if not ThemeManager then
        Ui.notify("Slopix Hub", "Could not load the theme manager: " .. tostring(themeError), 6)
    end
    Env.elevate()

    function Settings.finish()
        if SaveManager then
            local ok, err = pcall(SaveManager.LoadAutoloadConfig, SaveManager)
            Env.elevate()
            if not ok then
                Ui.notify("Slopix Hub", "Autoload failed: " .. tostring(err), 6)
            end
        end
    end

    return Settings
end

return Settings
end
__modules["shared/ui"] = function(use) -- src/shared/ui.luau
-- The window, its tabs, notifications, and small helpers features build their panels from.
-- Each game's core/ui calls Ui.create once with its footer and tabs, then returns this table.
--
-- The library is the Crimson Obsidian fork. Its public methods re-elevate the thread themselves,
-- so UI writes after a game-module call are safe without extra care in feature code.

local Env = use("shared/env")
local Life = use("shared/life")
local Http = use("shared/http")

local LIBRARY_URL = "https://raw.githubusercontent.com/TrustyCoding/slopix-hub/main/ui/Library.lua"

local Ui = {}

-- options.footer: the game's name under the title.
-- options.tabs: { { name, icon, description }, ... } in sidebar order.
-- options.only: a set of tab names to create (the rest are skipped), or nil for all of them.
-- options.icons: a bundled icon registry, installed before any window controls are created.
function Ui.create(options)
    local Library = options.library and options.library() or Http.load(LIBRARY_URL, "Library.lua")()
    Env.elevate()
    assert(type(Library) == "table" and type(Library.CreateWindow) == "function", "Slopix: UI library did not load")
    if options.icons then
        Library:SetIconModule(options.icons)
    end
    Ui.Library = Library
    Ui.Options = Library.Options
    Ui.Toggles = Library.Toggles

    -- Register before constructing the window, so failed startup can also tear it down.
    Library:OnUnload(function()
        Env.elevate()
        Life.shutdown()
    end)

    Ui.Window = Library:CreateWindow({
        Title = "Slopix Hub",
        Footer = options.footer,
        AutoShow = true,
        Center = true,
        Resizable = true,
        ShowCustomCursor = false,
        NotifySide = "Right",
    })

    -- Created up front so the sidebar order is fixed here, whatever order features load in.
    Ui.Tabs = {}
    for _, entry in ipairs(options.tabs) do
        if not options.only or options.only[entry[1]] then
            Ui.Tabs[entry[1]] = Ui.Window:AddTab(entry[1], entry[2], entry[3])
        end
    end

    return Ui
end

function Ui.notify(title, text, seconds)
    if not Life.alive or not Ui.Library then return end
    Env.elevate()
    Ui.Library:Notify({ Title = title, Description = text, Time = seconds or 5 })
end

-- A fixed stack of labels plus a footer, for lists that change size (tasks, timers, chests).
function Ui.panel(groupbox, rows)
    local labels = {}
    for index = 1, rows do
        labels[index] = groupbox:AddLabel("", true)
        labels[index]:SetVisible(false)
    end
    groupbox:AddDivider()
    local footer = groupbox:AddLabel("", true)
    local panel = {}
    function panel.set(lines, footerText)
        if not Life.alive then return end
        Env.elevate()
        for index = 1, rows do
            local line = lines[index]
            labels[index]:SetVisible(line ~= nil)
            if line ~= nil then
                labels[index]:SetText(line)
            end
        end
        footer:SetText(footerText or "")
    end
    return panel
end

-- Toggle value that is safe to read during unload (the library clears Toggles).
function Ui.on(name)
    local toggle = Ui.Library.Toggles[name]
    return toggle ~= nil and toggle.Value == true
end

function Ui.set(name, value)
    local toggle = Ui.Library.Toggles[name]
    if toggle and toggle.Value ~= value then
        toggle:SetValue(value)
    end
end

-- Toggles that start automation. `stays` marks ones that never pull the character somewhere
-- else (clan spins, auto heal), which travelling can leave running.
local automation = {}

function Ui.automation(name, stays)
    automation[#automation + 1] = { name = name, stays = stays == true }
end

-- Switches automation off: everything, or with moversOnly just what would move the character.
function Ui.stopAll(moversOnly)
    for _, entry in ipairs(automation) do
        if not (moversOnly and entry.stays) then
            Ui.set(entry.name, false)
        end
    end
end

return Ui
end
__modules["shared/webhook"] = function(use) -- src/shared/webhook.luau
-- Discord webhook alerts: the URL, a user to ping, a test button, a disconnect alert, and a queue
-- that posts one message at a time through the executor's request (Roblox's own HttpService
-- cannot reach Discord). Each game's features/webhooks calls Webhook.build and adds its alerts.
--
-- Discord allows 5 posts per webhook every 2 seconds and answers 429 with retry_after past that.
-- The queue keeps a second between posts and waits out a 429. It holds at most 20 messages: in an
-- alert storm the oldest are dropped rather than everything arriving minutes late.

local Env = use("shared/env")
local Life = use("shared/life")
local Ui = use("shared/ui")

local Webhook = {}

local SPACING = 1.1 -- seconds between two posts
local MAX_QUEUE = 20

local queue = {}
local gameName = "Roblox"
local statusLabel

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function url()
    local option = Ui.Options.WebhookUrl
    return trim(option and option.Value)
end

-- The Discord user to ping, digits only, or nil.
local function pingId()
    local option = Ui.Options.WebhookUserId
    local id = trim(option and option.Value):gsub("%D", "")
    return id ~= "" and id or nil
end

function Webhook.ready()
    return Env.request ~= nil and url():match("^https?://.+") ~= nil
end

local function setStatus(text)
    if statusLabel then
        statusLabel:SetText(text)
    end
end

-- Posts one body. Returns true, or false, why, and how long Discord asked to wait.
local function post(body)
    local ok, res = pcall(Env.request, {
        Url = url(),
        Method = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body = Env.HttpService:JSONEncode(body),
    })
    Env.elevate()
    if not ok or type(res) ~= "table" then
        return false, tostring(res)
    end
    local status = tonumber(res.StatusCode) or 0
    if status >= 200 and status < 300 then
        return true
    end
    if status == 429 then
        local decoded, data = pcall(Env.HttpService.JSONDecode, Env.HttpService, res.Body or "")
        return false, "rate limited", decoded and type(data) == "table" and tonumber(data.retry_after) or 2
    end
    return false, "HTTP " .. status
end

task.spawn(function()
    while Life.alive do
        local body = queue[1]
        if body and Webhook.ready() then
            table.remove(queue, 1)
            local ok, why, retry = post(body)
            if retry then
                table.insert(queue, 1, body)
                Life.wait(retry)
            elseif ok then
                setStatus("Last message sent at " .. os.date("%H:%M:%S"))
            else
                setStatus("Last message failed: " .. tostring(why))
            end
            Life.wait(SPACING)
        else
            Life.wait(0.25)
        end
    end
end)

-- Queues an alert. message: { title, description, color, fields = { { name, value, inline } },
-- ping = ping the user set, urgent = ahead of everything already waiting }. Does nothing while
-- no webhook is set.
function Webhook.send(message)
    if not Webhook.ready() then
        return false
    end
    local id = message.ping and pingId() or nil
    local fields = {}
    for _, field in ipairs(message.fields or {}) do
        fields[#fields + 1] = { name = tostring(field[1]), value = tostring(field[2]):sub(1, 1024), inline = field[3] ~= false }
    end
    local body = {
        username = "Slopix Hub",
        content = id and ("<@" .. id .. ">") or nil,
        allowed_mentions = { parse = {}, users = id and { id } or {} },
        embeds = {
            {
                title = tostring(message.title):sub(1, 256),
                description = message.description and tostring(message.description):sub(1, 4096) or nil,
                color = message.color or 0xEB4060,
                fields = #fields > 0 and fields or nil,
                footer = { text = string.format("%s · %s", Env.LocalPlayer.Name, gameName) },
                timestamp = DateTime.now():ToIsoDate(),
            },
        },
    }
    if message.urgent then
        table.insert(queue, 1, body)
    else
        queue[#queue + 1] = body
    end
    while #queue > MAX_QUEUE do
        table.remove(queue, message.urgent and #queue or 1)
    end
    return true
end

-- The "Discord webhook" box on `tab`. options.game: the game's name for the message footer.
function Webhook.build(tab, options)
    gameName = options.game or gameName
    local group = tab:AddGroupbox({ Side = "Left", Name = "Discord webhook", IconName = "webhook" })
    group:AddInput("WebhookUrl", {
        Text = "Webhook URL",
        Default = "",
        Placeholder = "https://discord.com/api/webhooks/...",
        Finished = true,
        ClearTextOnFocus = false,
        Tooltip = "In Discord: Server settings > Integrations > Webhooks > New webhook > Copy webhook URL.",
    })
    group:AddInput("WebhookUserId", {
        Text = "Your Discord user ID (to be pinged)",
        Default = "",
        Placeholder = "optional, e.g. 123456789012345678",
        Finished = true,
        ClearTextOnFocus = false,
        Tooltip = "Rare finds and disconnects ping you. Discord: Settings > Advanced > Developer mode, then right-click your name > Copy User ID.",
    })
    group:AddToggle("WebhookDisconnect", {
        Text = "Alert when disconnected or kicked",
        Default = true,
    })
    group:AddButton({ Text = "Send a test message", Func = function()
        if not Env.request then
            Ui.notify("Webhook", "Your executor has no request function, so nothing can be sent.", 6)
        elseif not Webhook.ready() then
            Ui.notify("Webhook", "Paste your webhook URL first.", 4)
        else
            Webhook.send({
                title = "Slopix Hub is connected",
                description = "Alerts for " .. gameName .. " will arrive here.",
                fields = { { "Executor", Env.executor } },
                ping = true,
                urgent = true,
            })
            Ui.notify("Webhook", "Test message queued.", 3)
        end
    end })
    statusLabel = group:AddLabel(Env.request and "Nothing sent yet" or "Your executor has no request function: webhooks cannot be sent.", true)

    -- The error screen of a kick or a lost connection: scripts still run behind it for a moment.
    local GuiService = game:GetService("GuiService")
    Life.connect(GuiService.ErrorMessageChanged, function()
        local ok, text = pcall(GuiService.GetErrorMessage, GuiService)
        text = ok and trim(text) or ""
        if text ~= "" and Ui.on("WebhookDisconnect") then
            Webhook.send({
                title = "Disconnected",
                description = text,
                color = 0x808080,
                ping = true,
                urgent = true,
            })
        end
    end)
    return Webhook
end

return Webhook
end
__modules["vendor/icons"] = function(use) -- ../repo/ui/vendor/Lucide.lua
-- Lucide icon registry, bundled for Slopix Hub.
-- Source: https://github.com/mstudio45/lucide-roblox-direct/blob/main/source.lua
-- Retrieved 2026-10-04; upstream registry version 2026-10-01.
-- Uses upstream Roblox sprite asset IDs; no executor filesystem or HTTP calls.
--[[
MIT License

Copyright (c) 2025 deividcomsono

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

local Lucide = {}

local icons = {{"align-vertical-distribute-center","chevron-down","list-restart","table-cells-split","gavel","dna-off","refresh-ccw-dot","venus","bean","circle-question-mark","folder-code","bolt","heater","feather","align-horizontal-distribute-center","grip-vertical","pill-bottle","person-standing","badge-swiss-franc","between-horizontal-end","file-braces-corner","rotate-cw","house-plus","bus-front","shield-ellipsis","between-vertical-end","globe-lock","tags","concierge-bell","bookmark-minus","plant-pot","file-down","picture-in-picture","messages-square","scissors","file-check-corner","phone-call","anchor","hand-helping","text-wrap","birdhouse","wifi-off","cloud-alert","message-square","cloud-download","folder-plus","cctv-off","notebook-dot","mirror-round","user-round","pointer","between-horizontal-start","chevrons-up-down","brush","message-circle-more","parentheses","book-up-2","flame","chevrons-up","square-dashed","square-mouse-pointer","superscript","signal","wifi-cog","hexagon","navigation-2-off","eye-off","arrows-up-from-line","file-code-corner","square-centerline-dashed-horizontal","panels-right-bottom","scaling","hash","arrow-left-from-line","ship","ticket-percent","calendar-clock","x","non-binary","voicemail","presentation","tree-palm","badge","captions-off","align-vertical-justify-center","download","mouse-right","lens-convex","shrimp-off","focus","diamond-percent","arrow-big-up","volume-x","mouse-pointer-click","face-slightly-smiling-plus","hard-drive","grid-2x2-x","package-minus","cloud","pipette","corner-left-down","badge-cent","cloud-lightning","user-round-pen","arrow-left-to-line","book-open-text","monitor-cloud","parking-meter","cat","heart-handshake","dam","trees","ham","circle-pause","chess-king","bean-off","clef-alto","separator-horizontal","ambulance","globe-code","citrus","phone-missed","calendar-off","chart-column","battery-medium","square-minus","star-check","decimals-arrow-left","folder-output","menu","bangladeshi-taka","image-down","terminal","building-complex-plus","circle-dot-dashed","medal","cake-slice","git-graph","armchair","tickets","qr-code","copy","goal","book-bookmark","trending-down","creative-commons","layers-arrow-down","ev-charger","user-star","road","nfc","align-center-horizontal","car","notebook-tabs","ear","videotape","sun-moon","chart-scatter","podium","toolbox","calendar","calendar-cog","gallery-horizontal","clipboard-x","list-sort-ascending","book-open","circle-pile","rectangle-ellipsis","badge-plus","badge-info","file-headphone","bow-arrow","clipboard-pen-line","user-round-key","folder-search","utensils-crossed","arrow-up","arrow-up-from-dot","align-vertical-justify-start","layers-minus","pause","shrub","flag","biceps-flexed","align-horizontal-distribute-end","donut","calendar-plus-2","move-vertical","file-pen-line","badge-russian-ruble","radius","pilcrow","corner-left-up","georgian-lari","cable","book-user","square-arrow-down","circle-plus","view","cctv","circle-arrow-left","square-off","octagon-alert","panel-bottom-dashed","book-a","align-end-vertical","thumbs-up","globe","rabbit","layers-plus","door-stairwell","banknote-arrow-down","message-square-off","dice-4","message-circle-x","folder-x","message-circle-warning","map","move","arrow-up-left","award","arrow-down-wide-narrow","unfold-horizontal","lens-concave","zoom-out","motorbike","music-4","zoom-in","shield-x","file-volume","disc-3","file-signal","columns-4","archive-x","zodiac-virgo","square-dashed-kanban","mouse-pointer-2","clock-arrow-up","clock-fading","pencil-sparkles","library-big","vegan","star-plus","file-check","clef-bass","message-circle-plus","user-key","credit-card-plus","zodiac-pisces","fast-forward","user-pen","chess-knight","wifi-pen","files","send-to-back","alarm-clock","microscope","zodiac-libra","zodiac-leo","zodiac-gemini","shopping-basket","send","smartphone","square-dashed-bottom","zodiac-aries","zodiac-aquarius","land-plot","wind-arrow-down","germ-off","brush-cleaning","skip-back","x-line-top","book-audio","octagon-minus","file-scan","cupcake","midi-port","message-square-dashed","shield-check","worm","chevrons-left","workflow","umbrella","skip-forward","clipboard-copy","map-pin-off","arrow-up-from-line","circle-chevron-up","wine-off","wine","circle-small","align-vertical-space-between","lamp-desk","circle-arrow-up","zap","beaker","timeline","panel-left-right-dashed","wifi-sync","paintbrush","sliders-vertical","broccoli","wifi-high","wifi","chevron-up","triangles-centerline-dashed-horizontal","whistle","pen-tool","database-check","wheat-off","form","pencil-ruler","dna","arrow-big-down-dash","chart-area","bug-off","wheat","weight-tilde","card-sim","weight","server-crash","map-pin-search","flask-round","eye-dashed","webcam-off","ellipse","spell-check","webcam","waypoints","popcorn","blocks","waves-vertical","layer-arrow-up","microchip","waves-ladder","badge-minus","cloud-sun","circle","shield-alert","waves-horizontal","phone-incoming","map-minus","waves-arrow-down","watch","separator-vertical","washing-machine","heart-minus","scan-square","ampersands","wand-sparkles","user-search","magnet","fence","wallpaper","square-user-round","wallet-minimal","wallet-cards","sunrise","strikethrough","calendar-days","folder-bookmark","wallet","banknote-arrow-up","layout-arrow-right","vote","dollar-sign","message-square-quote","volume-off","ruler-dimension-line","volume-1","list-minus","cloud-hail","volume","eye-closed","app-window-mac","volleyball","ellipsis","copy-check","clock-arrow-right","satellite","bookmark-plus","virus","folder-key","coffee","circle-power","ligature","hourglass","tickets-plane","folder-git","video","bomb","layers-2","battery-full","sparkle","line-dot-bottom-vertical","chart-gantt","folder-tree","command","badge-dollar-sign","align-start-vertical","briefcase-conveyor-belt","message-circle-question-mark","vibrate","bluetooth-off","venus-and-mars","square-square","cannabis","equal-approximately-not","book","grip-horizontal","circle-minus","audio-waveform","moon-star","arrow-down-narrow-wide","ghost","database-backup","wand","receipt-turkish-lira","vector-polygon","calendar-minus-2","copy-minus","vault","folder-input","book-image","badge-x","mouse-left","tag-plus","shirt","van","server-off","move-up","message-circle-dashed","utensils","plug-2","users-round","chess-rook","brackets","calendar-heart","list-ordered","users","star-x","mic-off","user-x","arrow-big-left","square-split-horizontal","triangle-alert","user-round-x","clover","sun-snow","sofa","user-round-search","handbag","funnel-x","map-pin","clock-2","calendar-fold","fish-off","baby","database-x","fold-vertical","user-round-group","hop","face-angry","user-round-cog","cigarette","calendar-chevrons-right","user-round-check","user-round-arrow-left","diamond-plus","refrigerator","file-chart-column","triangle-dashed","git-pull-request-closed","badge-check","user-minus","user-lock","layers-arrow-up","plug-zap","heading-4","chess-queen","graduation-cap","grid-3x2","zodiac-sagittarius","square-dashed-x-corner","square-dashed-bottom-code","clock-7","ethernet-port","scan-text","user-group","shower-head","equal-not","user-cog","move-down","clock-arrow-down","ticket-slash","ruler","settings-2","user","circle-user-round","usb-c-port","layers","list-filter","map-pin-check","egg-off","upload","cog","dog","unplug","swords","spotlight","panel-right-dashed","signal-zero","paper-bag","truck-electric","unlink","check-line","university","bubbles","bot","chart-bar-increasing","ungroup","playing-card","air-vent","unfold-vertical","dot","ice-cream-cone","mouth","file-symlink","clipboard-paste","chevron-last","book-heart","undo-2","circle-parking","globe-check","cloud-check","panel-left","circle-chevron-right","undo","underline","squares-unite","arrow-down-up","git-fork","forward","brain-circuit","between-vertical-start","database","panel-right","umbrella-off","type-outline","flower","log-out","git-branch-plus","clipboard-minus","file-text","trending-up","fire-extinguisher","fan","table-rows-split","milk-off","tv-minimal","cloud-upload","banknote","turntable","message-circle-dashed-check","drumstick","turkish-lira","calendar-search","tube-lotion","line-dot-top-vertical","bell-ring","circle-chevron-left","truck","arrow-down","arrow-up-down","folder-dot","trophy","case-lower","whole-word","monitor","disc-2","trending-up-down","folder-cog","user-shield","triangle","tv-minimal-play","circle-stop","align-vertical-space-around","switch-camera","tree-deciduous","square-chart-gantt","arrow-big-down","circle-parking-off","calendar-x-2","user-plus","move-diagonal-2","bandage","gallery-horizontal-end","panel-top-dashed","transgender","chess-bishop","tram-front","train-front-tunnel","train-front","refresh-cw-off","audio-lines","traffic-cone","tractor","toothbrush","tower-control","rocket","fish","ear-off","touchpad-off","save-check","touchpad","torus","printer","megaphone-off","tornado","arrow-big-right","section","file-clock","toothbrush-sparkles","toy-brick","square-chevron-down","dice-1","drill","app-window","robot-vacuum","hand-metal","tool-case","spell-check-2","toilet","squirrel","list-plus","toggle-left","rotate-ccw-key","timer-reset","chart-pie","paw-print","timer","copy-slash","wind","ticket-x","layout-panel-left","moon","circle-percent","ticket-minus","circle-arrow-out-down-right","square-x","italic","chart-column-increasing","layout-freeform","step-forward","message-square-diff","a-arrow-down","broom-sparkles","sticker","tic-tac-toe","move-left","thermometer-sun","thermometer-snowflake","thermometer","theater","import","badge-turkish-lira","square-terminal","file-music","logs","beef","faucet","file-user","text-quote","square-radical","lightbulb","image-upscale","book-type","text-cursor-input","signpost-big","text-cursor","cloudy","helicopter","square-percent","text-align-justify","navigation-off","arrow-left","car-taxi-front","text-align-end","mouth-off","chevrons-right-left","text-align-center","test-tubes","test-tube-diagonal","brick-wall-fire","square-stack","tent","square-dimensions","face-slightly-smiling","align-end-horizontal","layer-arrow-down","equal","megaphone","calendar-x","telescope","ice-cream-bowl","egg","tangent","save-off","ship-cargo","circle-pound-sterling","video-off","japanese-yen","tally-3","tag","tally-1","library","file-terminal","circle-chevron-down","accessibility","route","square-library","amphora","hourglass-cog","tally-2","tablets","tablet-smartphone","building-complex","remove-formatting","sheet","circle-check-big","table-properties","table-of-contents","map-pinned","corner-down-left","circuit-board","table-columns-split","table-cells-merge","table-2","table","folder-open-dot","book-dashed","syringe","lasso","bluetooth","tree-pine","receipt-indian-rupee","swiss-franc","shield-plus","sunset","sun-medium","sun-dim","can-soda","flask-conical","power","funnel","square-star","folder-sync","monitor-pc","zodiac-ophiuchus","subscript","stretch-vertical","arrow-up-narrow-wide","fishing-hook","stretch-horizontal","maximize-2","stone","frame","calendar-arrow-down","clock-12","star-minus","heart","sticky-note-x","images","lollipop","book-text","chart-no-axes-column-increasing","lamp-floor","file-plus-corner","image","equal-approximately","badge-euro","bike","angle","gap-vertical","sticky-note-check","sticky-note","stethoscope","step-back","star-off","option","banknote-check","scroll-text","server-plus","repeat","star","stamp","toggle-right","file-x","ferris-wheel","camera-off","squircle","search-slash","repeat-off","squares-exclude","square-user","group","square-text","battery","mic-audio-lines","tent-tree","square-split-vertical","rectangle-horizontal","spade","square-slash","screen-share-off","bitcoin","square-scissors","battery-plus","database-search","square-round-corner","file-diff","joystick","square-plus","square-play","spline-pointer","square-pilcrow","axis-3d","square-pi","message-square-share","binoculars","square-pause","calendar-range","square-parking","rose","euro","mail-minus","square-m","square-kanban","square-function","pyramid","clipboard-pen","bottle-wine","alarm-clock-off","square-equal","list","square-dot","square-arrow-right","dome","badge-pound-sterling","bookmark-check","square-divide","wrench-off","shopping-bag","a-arrow-up","clock-check","shrink","chevrons-down","vibrate-off","face-grinning","zodiac-cancer","square-code","file-code","square-chevron-up","carton-off","credit-card-reader","paintbrush-vertical","cassette-tape","battery-low","square-chevron-left","receipt-japanese-yen","signpost","snail","calendar-arrow-up","landmark","fish-symbol","trash-off","loader","bold","dice-2","file-type","clipboard-clock","beer","lectern","square-centerline-dashed-vertical","square-bottom-dashed-scissors","square-bookmark","binary","move-diagonal","square-asterisk","door-closed","square-arrow-up-right","layout-template","rows-4","piano","square-arrow-right-exit","bookmark-off","hand-heart","square-arrow-right-enter","scan-qr-code","message-square-check","square-arrow-out-up-right","square-arrow-out-up-left","monitor-play","brain","square-arrow-out-down-left","server-cog","square-arrow-down-right","key","clock-11","gap-horizontal","ticket-plus","arrow-up-0-1","bell-electric","square","heading","book-open-check","panel-top-close","lasso-select","sprout","spray-can","sport-shoe","shield-off","bus","search-alert","audio-lines-x","chart-no-axes-gantt","file-spreadsheet","percent","clipboard-list","speech","contact-round","speaker","keyboard-off","sparkles","file-badge","battery-warning","mail-question-mark","arrow-down-from-line","briefcase","biohazard","rectangle-circle","braces","scale-3d","panel-top-bottom-dashed","mail-x","square-dashed-mouse-pointer","square-sparkles","lock-open","file-play","pizza","list-indent-decrease","arrow-up-wide-narrow","soup","clock-5","solar-panel","rotate-ccw","align-horizontal-justify-center","soap-dispenser-droplet","antenna","memory-stick","scan-eye","snowflake","square-check","heart-plus","smartphone-nfc","map-pin-minus-inside","git-merge","gallery-vertical-end","square-dashed-plus","hand-coins","zodiac-capricorn","wifi-low","sliders-horizontal","clock","file-pen","git-compare-arrows","cloud-sun-rain","align-horizontal-justify-start","power-off","mail-badge","skull","calendar-plus","siren","arrow-down-z-a","bath","signature","unlink-2","signal-medium","shopping-cart-minus","folder-check","signal-low","book-key","ribbon","microwave","calculator","gallery-vertical","sigma","shuffle","square-dashed-text","map-pin-pen","move-up-left","shrimp","folder-heart","hard-drive-upload","monitor-speaker","shopping-cart-plus","arrow-up-a-z","package","square-dashed-top-solid","ship-wheel","shield-user","shield-question-mark","swatch-book","receipt-cent","spool","folder-archive","folder-symlink","can","ban","message-square-x","paint-roller","git-pull-request-draft","archive","shield-lock","shield-keyhole","shield-half","circle-slash-2","shield-cog-corner","cake","cloud-rain","chart-bar","shield-cog","wrench","shield-ban","shield","shelving-unit","flag-triangle-right","shell","gamepad-directional","bell","share","shapes","music-3","chart-bar-big","user-check","proportions","settings","plane","webhook-off","carrot","square-arrow-left","file-cog","circle-dashed","server","send-horizontal","search-x","germ","squares-subtract","search-code","dices","split","list-sort-descending","search","forklift","scroll","alarm-clock-minus","heart-x","eraser","square-sigma","screen-share","bluetooth-connected","rotate-ccw-square","chart-no-axes-column","cannabis-off","folder-kanban","lighthouse","mars-stroke","roller-coaster","school","scan-search","file-box","pickaxe","paint-bucket","glass-water","mic","glasses","piggy-bank","scan-face","cuboid","cloud-off","check-check","activity","axe","plane-takeoff","scan-box","cloud-rain-wind","scan-barcode","scan","copy-x","file-axis-3d","radical","chart-column-decreasing","play-off","bug-play","align-vertical-distribute-start","save-plus","waves-arrow-up","tally-5","headset","save","saudi-riyal","circle-divide","satellite-dish","sandwich","salad","life-buoy","sailboat","external-link","volume-2","battery-charging","russian-ruble","square-arrow-up-left","brick-wall-shield","footprints","rows-3","building","rows-2","router","route-off","tag-x","book-alert","link-2","astroid","bell-minus","image-up","closed-caption","drum","arrow-up-z-a","sun","rotate-cw-fading-clock","rotate-cw-clock","file-key","rotate-ccw-clock","rotate-3d","scissors-line-dashed","house-wifi","robot-arm","rewind","ticket-check","combine","reply","replace-all","mountain","mars","picture-in-picture-2","radio-off","flower-2","replace","squares-intersect","repeat-2","repeat-1","keyboard-music","star-half","playing-cards-fan","code-xml","pencil-line","mails","brain-cog","tablet","regex","pi","trash","book-down","hdmi-port","trailer","case-upper","circle-fading-arrow-up","refresh-cw","croissant","phone","computer","barcode","pin","redo","bed","circle-arrow-right","divide","grape","rectangle-vertical","party-popper","file-chart-pie","rectangle-goggles","file-x-corner","dice-6","receipt-swiss-franc","blender","receipt-russian-ruble","zap-off","square-check-big","receipt-euro","receipt","ratio","laptop-minimal","rat","rainbow","map-pin-minus","omega","chart-spline","message-square-more","radio-receiver","chart-candlestick","radio","arrow-down-a-z","radiation","radar","move-horizontal","file-sliders","quote","square-exclamation-point","cup-soda","puzzle","projector","sword","printer-check","map-pin-x","earth","slice","dice-3","milk","mouse-pointer-ban","crown","circle-slash","circle-star","rotate-cw-square","atom","package-x","bed-double","pound-sterling","circle-dot","file-exclamation-point","hand-fist","message-circle-code","folder-git-2","message-square-code","popsicle","towel-rack","layout-grid","arrow-big-left-dash","plus","dumbbell","plug","playing-cards","houses","scale","play","flashlight","panel-top-open","plane-landing","pin-off","notebook","redo-2","pill","square-menu","pilcrow-left","monitor-smartphone","laptop","scan-line","clock-4","square-arrow-up","book-minus","file-question-mark","chevrons-left-right","phone-off","save-pen","arrow-down-to-line","phone-forwarded","refresh-ccw","venetian-mask","calendar-check-2","phi","spline","banknote-x","git-pull-request-create-arrow","pentagon","circle-check","pencil-off","caravan","pen-off","pen-line","hand-platter","pc-case","timer-off","arrow-big-right-dash","bed-single","parasol","paperclip","backpack","calendar-minus","panels-left-bottom","panel-top","panel-right-open","mic-signal","arrow-down-right","panel-right-close","letters","wifi-zero","panel-left-open","panel-left-dashed","map-pin-plus","hard-drive-download","image-off","panel-bottom-close","panel-bottom","panda","engine","square-chevron-right","mail-search","package-search","bone-fracture","package-plus","package-open","crop","package-2","lambda","ampersand","ad","shopping-cart","align-vertical-justify-end","origami","alarm-smoke","orbit","file-input","clock-8","hand-grab","cloud-cog","blend","hd","radio-tower","list-tree","droplet","line-squiggle","eye","octagon-pause","square-dashed-x","banana","gpu","message-square-heart","nut-off","circle-equal","face-slightly-frowning","nut","notepad-text-dashed","notepad-text","text-initial","arrow-up-right","maximize","leafy-green","message-square-dot","file-chart-line","columns-3-cog","newspaper","network","minimize-2","nepali-rupee","navigation-2","cone","navigation","file-image","music-2","palette","barrel","gallery-thumbnails","move-up-right","cpu","move-right","thumbs-down","merge","hamburger","move-down-right","hat-glasses","code","move-down-left","move-3d","mail-check","mouse-pointer","carton","mouse-off","kanban","bone","apple","rocking-chair","bot-off","circle-arrow-out-down-left","database-arrow-down","folder","circle-arrow-out-up-left","mop","cable-car","arrow-down-left","square-activity","message-square-text","cigarette-off","monitor-up","message-circle","circle-arrow-out-up-right","car-battery","monitor-stop","fold-horizontal","shovel","calendar-1","cloud-moon","square-arrow-out-down-right","monitor-pause","clock-plus","circle-euro","cloud-snow","anvil","arrow-big-up-dash","monitor-off","log-in","monitor-dot","monitor-cog","monitor-check","list-checks","chevrons-down-up","clipboard-plus","circle-x","list-end","minus","list-collapse","chevrons-right","audio-lines-off","message-square-reply","corner-down-right","milestone","summary","lamp-wall-down","mic-vocal","layout-arrow-down","ellipsis-vertical","globe-off","square-stop","arrow-up-1-0","align-horizontal-justify-end","scan-heart","align-vertical-distribute-end","heart-crack","airplay","case-sensitive","messages-circle","message-square-warning","monitor-x","bell-check","database-minus","square-pen","message-square-plus","message-square-lock","dice-5","octagon","ticket","folder-lock","message-circle-off","briefcase-plus","bookmark","message-circle-heart","utility-pole","message-circle-check","chart-bar-decreasing","database-plus","calendar-sync","funnel-plus","store","circle-arrow-down","notebook-pen","egg-fried","compass","keyboard","corner-right-up","map-pin-x-inside","printer-3d","user-round-plus","panel-left-close","crosshair","pilcrow-right","user-round-minus","mailbox","indian-rupee","mail-plus","mail-pen","bell-off","mail-clock","mouse-pointer-2-off","drone","slash","credit-card-x","aperture","arrow-right-left","mail","vector-square","circle-gauge","circle-alert","check","text-search","arrow-down-to-dot","monitor-down","lock-keyhole-open","chef-hat","lock-keyhole","lock","file-archive","signal-high","inbox","locate-fixed","locate","image-play","align-horizontal-space-between","loader-pinwheel","calendar-check","database-zap","droplets","loader-circle","broom","corner-right-down","layout-list","file-search","list-video","alarm-clock-plus","circle-dollar-sign","usb","house","receipt-pound-sterling","list-music","list-indent-increase","id-card","mouse","minimize","list-clock","list-chevrons-up-down","galaxy","list-chevrons-down-up","book-x","mirror-rectangular","list-check","link-2-off","link","headphone-off","asterisk","line-style","octagon-x","languages","line-dot-right-horizontal","alarm-clock-check","guitar","dock","beer-off","scooter","square-parking-off","notebook-text","arrow-right-to-line","clef-treble","tally-4","zodiac-taurus","leaf","door-open","flag-triangle-left","grid-3x3","file","layout-panel-top","pocket-knife","book-copy","castle","car-front","clock-alert","reply-all","cloud-moon-rain","clipboard-type","layout-dashboard","list-todo","printer-x","bird","list-start","lamp-wall-up","a-large-small","lamp-ceiling","lamp","map-plus","key-square","file-chart-column-increasing","kayak","database-arrow-up","arrow-right-from-line","flame-kindling","square-power","iv-bag","bring-to-front","iteration-cw","iteration-ccw","bell-plus","inspection-panel","info","infinity","folders","mail-warning","image-plus","image-minus","id-card-lanyard","bridge","chart-line","file-lock","cast","circle-fading-plus","clock-10","undo-dot","target","list-filter-plus","house-plug","drama","house-heart","baseline","martini","contrast","hotel","candy-off","hospital","book-check","heart-off","book-lock","highlighter","briefcase-medical","calendars","text-align-start","heart-pulse","hop-off","warehouse","sticky-notes","drafting-compass","save-all","file-braces","heading-6","heading-5","heading-3","heading-2","fishing-rod","book-headphones","credit-card","heading-1","haze","hard-hat","shredder","panel-bottom-open","door-closed-package","eject","credit-card-check","balloon","map-pin-plus-inside","bookmark-x","badge-question-mark","pen","hand","candy-cane","hammer","grip","gamepad-2","file-type-corner","grid-2x2-check","grid-2x2","globe-x","shield-minus","circle-off","dessert","eclipse","church","git-pull-request-create","cylinder","badge-japanese-yen","columns-3","receipt-text","git-merge-conflict","git-compare","git-commit-vertical","git-commit-horizontal","file-output","disc-album","circle-ellipsis","arrow-down-0-1","captions","git-branch","gift","philippine-peso","badge-alert","gem","folder-pen","cross","gauge","chevron-right","sticky-note-minus","square-arrow-down-left","share-2","gamepad","fullscreen","fuel","folder-up","folder-search-2","folder-root","chess-pawn","folder-open","briefcase-business","folder-minus","message-circle-reply","cloud-sync","triangle-right","folder-clock","folder-closed","mop-sparkles","type","webhook","flask-conical-off","align-horizontal-distribute-start","flashlight-off","flag-off","pointer-off","turtle","camera","fingerprint-pattern","film","git-pull-request","bluetooth-searching","arrow-up-to-line","squircle-dashed","clock-3","badge-percent","face-expressionless","file-video-camera","file-up","grid-2x2-plus","file-stack","box","file-search-corner","clock-1","file-heart","house-cog","space","file-minus-corner","file-minus","file-digit","corner-up-left","clock-6","zodiac-scorpio","key-round","headphones","tv","factory","face-neutral","rss","expand","at-sign","map-pin-check-inside","sticky-note-off","music","handshake","earth-lock","circle-user","copy-plus","droplet-off","virus-off","line-dot-left-horizontal","disc","diff","search-check","clipboard-check","columns-2","diamond-minus","clipboard","align-center-vertical","diameter","delete","club","cloud-fog","mosque","currency","map-pin-house","package-check","chevron-first","pencil","boxes","list-x","copyright","copyleft","corner-up-right","cookie","clock-arrow-left","container","contact","badge-indian-rupee","construction","redo-dot","component","align-start-horizontal","chart-column-stacked","file-plus","git-pull-request-arrow","coins","decimals-arrow-right","bell-dot","folder-down","cloud-drizzle","cloud-backup","align-horizontal-space-around","door-closed-locked","clock-9","diamond","blinds","clapperboard","circle-play","book-search","git-branch-minus","circle-dashed-check","recycle","mountain-snow","luggage","chevrons-left-right-ellipsis","bot-message-square","phone-outgoing","smartphone-charging","chevron-left","train-track","cherry","chart-bar-stacked","sticky-note-plus","chart-no-axes-column-decreasing","chart-network","chart-column-big","chart-no-axes-combined","metronome","triangles-centerline-dashed-vertical","arrow-down-1-0","credit-card-minus","candy","arrow-left-right","lightbulb-off","panels-top-left","beef-off","locate-off","bug","test-tube","brick-wall","cooking-pot","boom-box","book-up","book-plus","laptop-minimal-check","mail-open","park","baggage-claim","variable","arrow-right","archive-restore"},{"rbxassetid://104502745253902","rbxassetid://89421818506275"},{[48]={{1,{24,24},{175,0}},{1,{24,24},{650,0}},{1,{24,24},{850,250}},{2,{24,24},{150,0}},{1,{24,24},{250,700}},{1,{24,24},{600,225}},{1,{24,24},{575,800}},{2,{24,24},{225,225}},{1,{24,24},{50,350}},{1,{24,24},{675,25}},{1,{24,24},{500,425}},{1,{24,24},{50,400}},{1,{24,24},{75,925}},{1,{24,24},{825,50}},{1,{24,24},{50,75}},{1,{24,24},{175,800}},{1,{24,24},{375,925}},{1,{24,24},{850,450}},{1,{24,24},{325,50}},{1,{24,24},{100,325}},{1,{24,24},{650,225}},{1,{24,24},{950,475}},{1,{24,24},{725,300}},{1,{24,24},{425,125}},{1,{24,24},{650,850}},{1,{24,24},{50,375}},{1,{24,24},{550,425}},{2,{24,24},{50,125}},{1,{24,24},{25,725}},{1,{24,24},{300,200}},{1,{24,24},{825,500}},{1,{24,24},{300,575}},{1,{24,24},{500,800}},{1,{24,24},{950,225}},{1,{24,24},{525,925}},{1,{24,24},{500,375}},{1,{24,24},{775,525}},{1,{24,24},{100,100}},{1,{24,24},{900,100}},{2,{24,24},{200,50}},{1,{24,24},{325,125}},{2,{24,24},{100,400}},{1,{24,24},{175,550}},{1,{24,24},{175,975}},{1,{24,24},{75,650}},{1,{24,24},{100,825}},{1,{24,24},{225,375}},{1,{24,24},{525,700}},{1,{24,24},{500,675}},{2,{24,24},{225,200}},{1,{24,24},{500,825}},{1,{24,24},{75,350}},{1,{24,24},{325,325}},{1,{24,24},{50,475}},{1,{24,24},{775,375}},{1,{24,24},{600,675}},{1,{24,24},{450,50}},{1,{24,24},{900,25}},{1,{24,24},{300,350}},{1,{24,24},{775,900}},{1,{24,24},{775,925}},{2,{24,24},{50,50}},{1,{24,24},{750,800}},{2,{24,24},{175,325}},{1,{24,24},{25,975}},{1,{24,24},{750,475}},{1,{24,24},{250,600}},{1,{24,24},{250,75}},{1,{24,24},{425,450}},{1,{24,24},{925,725}},{1,{24,24},{725,550}},{1,{24,24},{875,575}},{1,{24,24},{650,350}},{1,{24,24},{100,175}},{1,{24,24},{800,725}},{2,{24,24},{250,25}},{1,{24,24},{100,450}},{2,{24,24},{225,300}},{1,{24,24},{550,675}},{2,{24,24},{0,450}},{1,{24,24},{350,975}},{2,{24,24},{25,300}},{1,{24,24},{250,125}},{1,{24,24},{50,525}},{1,{24,24},{100,75}},{1,{24,24},{275,550}},{1,{24,24},{525,675}},{1,{24,24},{775,300}},{1,{24,24},{550,975}},{1,{24,24},{700,225}},{1,{24,24},{150,650}},{1,{24,24},{150,100}},{2,{24,24},{375,100}},{1,{24,24},{575,625}},{1,{24,24},{75,775}},{1,{24,24},{700,300}},{1,{24,24},{300,675}},{1,{24,24},{775,475}},{1,{24,24},{475,275}},{1,{24,24},{950,375}},{1,{24,24},{350,425}},{1,{24,24},{250,100}},{1,{24,24},{750,0}},{2,{24,24},{325,100}},{1,{24,24},{50,225}},{1,{24,24},{75,400}},{1,{24,24},{450,725}},{1,{24,24},{550,725}},{1,{24,24},{250,350}},{1,{24,24},{250,750}},{1,{24,24},{575,225}},{2,{24,24},{350,0}},{1,{24,24},{75,900}},{1,{24,24},{125,550}},{1,{24,24},{100,525}},{1,{24,24},{75,325}},{1,{24,24},{350,350}},{1,{24,24},{650,825}},{1,{24,24},{200,0}},{1,{24,24},{575,400}},{1,{24,24},{400,300}},{1,{24,24},{700,600}},{1,{24,24},{525,50}},{1,{24,24},{550,75}},{1,{24,24},{200,200}},{1,{24,24},{800,900}},{1,{24,24},{950,875}},{1,{24,24},{300,500}},{1,{24,24},{150,775}},{1,{24,24},{950,200}},{1,{24,24},{100,275}},{1,{24,24},{525,500}},{2,{24,24},{0,200}},{1,{24,24},{500,50}},{1,{24,24},{425,250}},{1,{24,24},{200,925}},{1,{24,24},{325,225}},{1,{24,24},{875,100}},{1,{24,24},{75,150}},{2,{24,24},{100,175}},{1,{24,24},{775,575}},{1,{24,24},{475,300}},{1,{24,24},{450,525}},{1,{24,24},{375,100}},{2,{24,24},{325,25}},{1,{24,24},{175,600}},{1,{24,24},{300,750}},{1,{24,24},{375,475}},{2,{24,24},{150,275}},{1,{24,24},{750,650}},{1,{24,24},{575,650}},{1,{24,24},{0,100}},{1,{24,24},{550,50}},{1,{24,24},{475,750}},{1,{24,24},{850,0}},{2,{24,24},{100,350}},{2,{24,24},{50,25}},{1,{24,24},{300,325}},{1,{24,24},{550,775}},{2,{24,24},{200,100}},{1,{24,24},{325,250}},{1,{24,24},{75,475}},{1,{24,24},{500,450}},{1,{24,24},{25,675}},{1,{24,24},{825,275}},{1,{24,24},{50,425}},{1,{24,24},{75,600}},{1,{24,24},{775,600}},{1,{24,24},{25,325}},{1,{24,24},{125,225}},{1,{24,24},{250,625}},{1,{24,24},{50,450}},{1,{24,24},{125,575}},{2,{24,24},{375,50}},{1,{24,24},{25,900}},{2,{24,24},{25,400}},{1,{24,24},{275,50}},{1,{24,24},{125,175}},{1,{24,24},{50,125}},{1,{24,24},{250,800}},{1,{24,24},{500,775}},{1,{24,24},{925,625}},{1,{24,24},{0,900}},{1,{24,24},{0,425}},{1,{24,24},{25,100}},{1,{24,24},{450,375}},{1,{24,24},{500,75}},{1,{24,24},{900,325}},{1,{24,24},{0,875}},{1,{24,24},{350,25}},{1,{24,24},{525,825}},{1,{24,24},{400,900}},{1,{24,24},{325,450}},{1,{24,24},{200,750}},{1,{24,24},{350,200}},{1,{24,24},{400,100}},{1,{24,24},{950,675}},{1,{24,24},{25,650}},{2,{24,24},{75,375}},{1,{24,24},{200,400}},{1,{24,24},{150,500}},{1,{24,24},{750,950}},{1,{24,24},{300,925}},{1,{24,24},{450,800}},{1,{24,24},{450,25}},{1,{24,24},{75,50}},{2,{24,24},{50,200}},{1,{24,24},{475,500}},{1,{24,24},{725,625}},{1,{24,24},{225,825}},{1,{24,24},{325,500}},{1,{24,24},{75,300}},{1,{24,24},{375,775}},{1,{24,24},{0,800}},{1,{24,24},{625,525}},{1,{24,24},{875,75}},{1,{24,24},{650,500}},{1,{24,24},{350,775}},{1,{24,24},{875,350}},{1,{24,24},{75,225}},{1,{24,24},{25,300}},{1,{24,24},{175,100}},{2,{24,24},{50,325}},{1,{24,24},{800,275}},{2,{24,24},{250,300}},{1,{24,24},{775,425}},{1,{24,24},{800,425}},{2,{24,24},{275,275}},{1,{24,24},{900,625}},{1,{24,24},{400,500}},{1,{24,24},{700,125}},{1,{24,24},{700,200}},{1,{24,24},{175,575}},{1,{24,24},{125,100}},{2,{24,24},{300,250}},{1,{24,24},{950,725}},{1,{24,24},{625,575}},{1,{24,24},{325,400}},{1,{24,24},{275,450}},{1,{24,24},{950,350}},{1,{24,24},{725,350}},{2,{24,24},{300,150}},{1,{24,24},{850,975}},{1,{24,24},{475,400}},{1,{24,24},{325,375}},{1,{24,24},{725,425}},{2,{24,24},{150,250}},{1,{24,24},{100,675}},{2,{24,24},{400,150}},{1,{24,24},{875,0}},{2,{24,24},{75,325}},{1,{24,24},{75,550}},{2,{24,24},{75,425}},{1,{24,24},{300,600}},{1,{24,24},{700,775}},{1,{24,24},{50,50}},{1,{24,24},{750,425}},{2,{24,24},{450,100}},{2,{24,24},{475,75}},{2,{24,24},{50,475}},{1,{24,24},{725,800}},{1,{24,24},{675,800}},{1,{24,24},{825,750}},{1,{24,24},{975,700}},{2,{24,24},{125,400}},{2,{24,24},{150,375}},{1,{24,24},{575,475}},{2,{24,24},{450,75}},{1,{24,24},{175,775}},{1,{24,24},{75,450}},{1,{24,24},{625,925}},{2,{24,24},{250,275}},{1,{24,24},{400,75}},{1,{24,24},{275,950}},{1,{24,24},{775,125}},{1,{24,24},{650,150}},{1,{24,24},{700,475}},{1,{24,24},{525,625}},{1,{24,24},{725,775}},{2,{24,24},{325,200}},{1,{24,24},{400,250}},{2,{24,24},{350,175}},{2,{24,24},{175,200}},{1,{24,24},{600,950}},{1,{24,24},{225,475}},{1,{24,24},{600,525}},{1,{24,24},{100,200}},{1,{24,24},{550,125}},{2,{24,24},{400,125}},{2,{24,24},{375,150}},{1,{24,24},{600,100}},{1,{24,24},{0,175}},{1,{24,24},{700,350}},{1,{24,24},{0,650}},{2,{24,24},{175,350}},{1,{24,24},{100,300}},{2,{24,24},{75,200}},{1,{24,24},{300,950}},{2,{24,24},{50,450}},{1,{24,24},{550,700}},{1,{24,24},{900,675}},{1,{24,24},{150,375}},{2,{24,24},{150,350}},{2,{24,24},{475,50}},{1,{24,24},{525,125}},{2,{24,24},{150,200}},{2,{24,24},{225,275}},{1,{24,24},{375,900}},{1,{24,24},{475,325}},{2,{24,24},{275,225}},{1,{24,24},{750,200}},{1,{24,24},{975,325}},{1,{24,24},{575,250}},{1,{24,24},{50,175}},{1,{24,24},{175,425}},{1,{24,24},{0,525}},{2,{24,24},{250,250}},{2,{24,24},{325,175}},{1,{24,24},{500,100}},{2,{24,24},{300,200}},{1,{24,24},{575,900}},{1,{24,24},{500,625}},{1,{24,24},{775,150}},{1,{24,24},{275,575}},{2,{24,24},{425,75}},{1,{24,24},{650,200}},{1,{24,24},{875,725}},{2,{24,24},{400,100}},{2,{24,24},{450,50}},{1,{24,24},{475,850}},{1,{24,24},{200,250}},{2,{24,24},{475,25}},{1,{24,24},{350,700}},{1,{24,24},{775,400}},{2,{24,24},{0,475}},{1,{24,24},{75,275}},{1,{24,24},{550,200}},{1,{24,24},{450,250}},{1,{24,24},{775,725}},{2,{24,24},{25,450}},{1,{24,24},{725,575}},{1,{24,24},{750,375}},{2,{24,24},{75,400}},{2,{24,24},{100,375}},{1,{24,24},{625,850}},{2,{24,24},{125,350}},{1,{24,24},{225,775}},{1,{24,24},{650,800}},{1,{24,24},{150,50}},{2,{24,24},{200,275}},{2,{24,24},{200,225}},{1,{24,24},{250,850}},{1,{24,24},{800,75}},{2,{24,24},{225,250}},{1,{24,24},{875,900}},{2,{24,24},{275,200}},{2,{24,24},{300,175}},{2,{24,24},{100,0}},{2,{24,24},{0,25}},{1,{24,24},{50,500}},{1,{24,24},{600,325}},{2,{24,24},{250,225}},{1,{24,24},{50,325}},{1,{24,24},{150,900}},{2,{24,24},{325,150}},{1,{24,24},{500,325}},{1,{24,24},{325,825}},{2,{24,24},{400,75}},{1,{24,24},{750,675}},{2,{24,24},{450,25}},{1,{24,24},{950,150}},{1,{24,24},{0,725}},{2,{24,24},{350,125}},{1,{24,24},{300,550}},{1,{24,24},{225,0}},{2,{24,24},{475,0}},{1,{24,24},{600,250}},{1,{24,24},{600,175}},{1,{24,24},{350,375}},{1,{24,24},{575,850}},{1,{24,24},{250,250}},{2,{24,24},{25,425}},{1,{24,24},{275,650}},{1,{24,24},{325,425}},{1,{24,24},{700,0}},{1,{24,24},{650,425}},{1,{24,24},{825,200}},{2,{24,24},{125,150}},{1,{24,24},{375,550}},{2,{24,24},{125,325}},{1,{24,24},{25,425}},{1,{24,24},{325,725}},{1,{24,24},{250,150}},{1,{24,24},{600,975}},{1,{24,24},{550,525}},{1,{24,24},{525,100}},{1,{24,24},{925,25}},{1,{24,24},{125,625}},{1,{24,24},{200,150}},{1,{24,24},{0,150}},{1,{24,24},{275,250}},{1,{24,24},{700,450}},{2,{24,24},{175,275}},{1,{24,24},{150,300}},{2,{24,24},{250,200}},{1,{24,24},{800,950}},{1,{24,24},{75,500}},{1,{24,24},{550,300}},{1,{24,24},{350,150}},{1,{24,24},{200,775}},{1,{24,24},{225,450}},{1,{24,24},{50,275}},{1,{24,24},{900,300}},{1,{24,24},{0,250}},{1,{24,24},{125,825}},{1,{24,24},{500,300}},{2,{24,24},{175,300}},{1,{24,24},{850,525}},{2,{24,24},{350,100}},{1,{24,24},{575,0}},{1,{24,24},{575,200}},{2,{24,24},{375,75}},{1,{24,24},{325,600}},{1,{24,24},{200,275}},{1,{24,24},{275,100}},{1,{24,24},{700,500}},{2,{24,24},{125,50}},{1,{24,24},{775,750}},{2,{24,24},{425,25}},{1,{24,24},{550,925}},{1,{24,24},{925,300}},{1,{24,24},{825,325}},{2,{24,24},{0,425}},{1,{24,24},{675,650}},{2,{24,24},{75,350}},{1,{24,24},{0,625}},{1,{24,24},{500,25}},{1,{24,24},{0,550}},{1,{24,24},{900,200}},{2,{24,24},{50,375}},{1,{24,24},{975,875}},{1,{24,24},{875,300}},{2,{24,24},{125,300}},{1,{24,24},{250,0}},{1,{24,24},{850,900}},{2,{24,24},{250,100}},{2,{24,24},{250,175}},{1,{24,24},{425,325}},{2,{24,24},{25,50}},{1,{24,24},{725,850}},{2,{24,24},{275,150}},{1,{24,24},{800,200}},{1,{24,24},{600,350}},{1,{24,24},{425,700}},{1,{24,24},{625,100}},{1,{24,24},{25,525}},{1,{24,24},{200,700}},{1,{24,24},{325,25}},{1,{24,24},{375,425}},{1,{24,24},{650,275}},{2,{24,24},{400,25}},{1,{24,24},{925,100}},{1,{24,24},{200,650}},{2,{24,24},{425,0}},{1,{24,24},{225,425}},{1,{24,24},{125,425}},{2,{24,24},{0,400}},{2,{24,24},{25,375}},{1,{24,24},{125,675}},{1,{24,24},{475,900}},{1,{24,24},{575,300}},{2,{24,24},{225,125}},{1,{24,24},{775,200}},{1,{24,24},{225,125}},{2,{24,24},{100,300}},{2,{24,24},{125,275}},{1,{24,24},{275,775}},{1,{24,24},{650,675}},{1,{24,24},{450,550}},{1,{24,24},{25,600}},{1,{24,24},{400,575}},{1,{24,24},{250,725}},{2,{24,24},{375,175}},{1,{24,24},{825,850}},{1,{24,24},{675,975}},{1,{24,24},{500,225}},{1,{24,24},{425,425}},{1,{24,24},{625,825}},{2,{24,24},{175,225}},{1,{24,24},{600,925}},{1,{24,24},{500,350}},{2,{24,24},{200,200}},{1,{24,24},{300,900}},{1,{24,24},{400,325}},{2,{24,24},{200,75}},{1,{24,24},{725,700}},{1,{24,24},{975,525}},{2,{24,24},{100,325}},{1,{24,24},{525,175}},{2,{24,24},{275,125}},{1,{24,24},{200,850}},{1,{24,24},{125,950}},{1,{24,24},{700,425}},{1,{24,24},{725,125}},{2,{24,24},{300,100}},{1,{24,24},{300,450}},{1,{24,24},{525,300}},{2,{24,24},{325,75}},{2,{24,24},{75,50}},{1,{24,24},{725,875}},{1,{24,24},{950,325}},{1,{24,24},{775,775}},{1,{24,24},{675,600}},{2,{24,24},{75,275}},{2,{24,24},{350,50}},{1,{24,24},{225,400}},{2,{24,24},{400,0}},{1,{24,24},{25,500}},{1,{24,24},{100,400}},{1,{24,24},{100,500}},{2,{24,24},{0,375}},{1,{24,24},{750,575}},{1,{24,24},{75,0}},{2,{24,24},{25,350}},{1,{24,24},{300,525}},{1,{24,24},{600,425}},{1,{24,24},{450,750}},{1,{24,24},{600,300}},{1,{24,24},{150,550}},{1,{24,24},{600,50}},{1,{24,24},{225,250}},{2,{24,24},{125,250}},{1,{24,24},{150,525}},{1,{24,24},{600,375}},{1,{24,24},{125,600}},{1,{24,24},{275,975}},{1,{24,24},{575,100}},{2,{24,24},{75,300}},{2,{24,24},{150,225}},{1,{24,24},{900,900}},{1,{24,24},{200,75}},{1,{24,24},{900,75}},{1,{24,24},{725,225}},{1,{24,24},{475,50}},{1,{24,24},{25,400}},{1,{24,24},{325,475}},{1,{24,24},{900,375}},{2,{24,24},{200,175}},{2,{24,24},{250,125}},{1,{24,24},{725,200}},{1,{24,24},{350,750}},{1,{24,24},{50,900}},{1,{24,24},{175,525}},{1,{24,24},{550,350}},{2,{24,24},{275,75}},{1,{24,24},{225,675}},{1,{24,24},{0,850}},{2,{24,24},{50,100}},{1,{24,24},{650,525}},{2,{24,24},{300,75}},{1,{24,24},{500,250}},{1,{24,24},{400,0}},{2,{24,24},{375,0}},{1,{24,24},{850,300}},{1,{24,24},{50,775}},{2,{24,24},{0,350}},{1,{24,24},{425,150}},{2,{24,24},{25,325}},{1,{24,24},{475,600}},{1,{24,24},{150,275}},{1,{24,24},{600,75}},{2,{24,24},{50,300}},{1,{24,24},{125,150}},{1,{24,24},{150,150}},{1,{24,24},{450,475}},{2,{24,24},{100,250}},{1,{24,24},{400,200}},{2,{24,24},{200,300}},{1,{24,24},{925,275}},{1,{24,24},{725,100}},{2,{24,24},{300,50}},{1,{24,24},{475,450}},{2,{24,24},{175,250}},{2,{24,24},{175,175}},{2,{24,24},{325,50}},{1,{24,24},{550,150}},{1,{24,24},{25,150}},{2,{24,24},{125,0}},{2,{24,24},{50,275}},{1,{24,24},{875,775}},{1,{24,24},{25,200}},{1,{24,24},{175,500}},{1,{24,24},{375,200}},{2,{24,24},{50,350}},{1,{24,24},{400,800}},{1,{24,24},{125,250}},{1,{24,24},{525,425}},{1,{24,24},{825,450}},{2,{24,24},{125,200}},{1,{24,24},{125,500}},{2,{24,24},{150,175}},{2,{24,24},{225,100}},{2,{24,24},{200,125}},{1,{24,24},{525,850}},{1,{24,24},{75,250}},{2,{24,24},{275,50}},{2,{24,24},{300,25}},{2,{24,24},{150,150}},{2,{24,24},{0,300}},{1,{24,24},{675,725}},{1,{24,24},{150,750}},{1,{24,24},{0,825}},{2,{24,24},{75,225}},{1,{24,24},{500,925}},{2,{24,24},{50,250}},{2,{24,24},{100,200}},{1,{24,24},{900,450}},{1,{24,24},{175,950}},{2,{24,24},{125,175}},{1,{24,24},{200,50}},{1,{24,24},{750,725}},{1,{24,24},{450,425}},{2,{24,24},{175,125}},{2,{24,24},{325,0}},{1,{24,24},{800,850}},{1,{24,24},{75,725}},{1,{24,24},{200,625}},{1,{24,24},{200,25}},{1,{24,24},{700,700}},{1,{24,24},{875,125}},{2,{24,24},{225,75}},{1,{24,24},{900,700}},{2,{24,24},{250,50}},{1,{24,24},{825,975}},{1,{24,24},{875,225}},{2,{24,24},{300,0}},{1,{24,24},{525,875}},{2,{24,24},{25,250}},{1,{24,24},{325,300}},{1,{24,24},{475,800}},{2,{24,24},{0,275}},{1,{24,24},{525,250}},{2,{24,24},{425,100}},{2,{24,24},{175,100}},{1,{24,24},{950,125}},{1,{24,24},{875,325}},{1,{24,24},{100,575}},{2,{24,24},{275,0}},{1,{24,24},{100,550}},{1,{24,24},{825,950}},{1,{24,24},{150,875}},{1,{24,24},{600,25}},{1,{24,24},{100,950}},{1,{24,24},{900,950}},{1,{24,24},{500,650}},{1,{24,24},{0,0}},{1,{24,24},{125,400}},{1,{24,24},{975,900}},{2,{24,24},{25,225}},{1,{24,24},{250,950}},{2,{24,24},{125,125}},{2,{24,24},{150,100}},{2,{24,24},{100,150}},{2,{24,24},{175,75}},{1,{24,24},{300,725}},{1,{24,24},{300,75}},{1,{24,24},{925,850}},{1,{24,24},{50,825}},{1,{24,24},{325,775}},{1,{24,24},{375,50}},{1,{24,24},{850,25}},{1,{24,24},{450,450}},{2,{24,24},{250,0}},{1,{24,24},{750,975}},{1,{24,24},{600,475}},{1,{24,24},{375,650}},{1,{24,24},{475,25}},{2,{24,24},{50,175}},{1,{24,24},{700,850}},{2,{24,24},{25,200}},{1,{24,24},{450,300}},{1,{24,24},{50,950}},{1,{24,24},{900,825}},{2,{24,24},{100,125}},{1,{24,24},{700,525}},{1,{24,24},{25,250}},{1,{24,24},{575,25}},{2,{24,24},{125,100}},{1,{24,24},{475,725}},{1,{24,24},{375,275}},{2,{24,24},{150,75}},{2,{24,24},{175,50}},{2,{24,24},{225,0}},{1,{24,24},{400,125}},{1,{24,24},{775,975}},{2,{24,24},{25,175}},{1,{24,24},{750,925}},{1,{24,24},{50,800}},{1,{24,24},{100,25}},{1,{24,24},{375,675}},{1,{24,24},{475,375}},{1,{24,24},{150,975}},{1,{24,24},{350,225}},{2,{24,24},{75,125}},{1,{24,24},{625,400}},{1,{24,24},{700,150}},{2,{24,24},{125,75}},{1,{24,24},{475,950}},{1,{24,24},{850,675}},{1,{24,24},{0,675}},{2,{24,24},{150,300}},{1,{24,24},{50,975}},{2,{24,24},{200,0}},{2,{24,24},{75,100}},{2,{24,24},{25,150}},{1,{24,24},{700,375}},{1,{24,24},{575,325}},{1,{24,24},{625,50}},{1,{24,24},{50,0}},{1,{24,24},{900,525}},{1,{24,24},{875,825}},{1,{24,24},{125,75}},{1,{24,24},{850,175}},{2,{24,24},{0,175}},{2,{24,24},{150,25}},{2,{24,24},{0,150}},{1,{24,24},{475,75}},{1,{24,24},{425,950}},{1,{24,24},{850,650}},{1,{24,24},{675,0}},{2,{24,24},{75,75}},{2,{24,24},{100,50}},{1,{24,24},{400,725}},{1,{24,24},{400,375}},{1,{24,24},{425,275}},{2,{24,24},{125,25}},{2,{24,24},{0,125}},{2,{24,24},{25,100}},{2,{24,24},{25,125}},{1,{24,24},{200,725}},{1,{24,24},{300,175}},{2,{24,24},{50,75}},{1,{24,24},{400,650}},{1,{24,24},{100,350}},{2,{24,24},{0,325}},{1,{24,24},{375,975}},{2,{24,24},{0,100}},{1,{24,24},{975,550}},{2,{24,24},{75,25}},{2,{24,24},{75,0}},{2,{24,24},{0,50}},{1,{24,24},{225,350}},{1,{24,24},{800,125}},{1,{24,24},{375,950}},{1,{24,24},{575,375}},{1,{24,24},{975,800}},{1,{24,24},{950,0}},{1,{24,24},{300,875}},{2,{24,24},{425,125}},{2,{24,24},{50,0}},{2,{24,24},{25,0}},{1,{24,24},{50,250}},{1,{24,24},{125,775}},{2,{24,24},{0,0}},{1,{24,24},{250,875}},{1,{24,24},{950,975}},{1,{24,24},{700,250}},{1,{24,24},{225,325}},{1,{24,24},{650,75}},{1,{24,24},{900,925}},{1,{24,24},{100,900}},{1,{24,24},{950,950}},{1,{24,24},{325,700}},{1,{24,24},{300,800}},{1,{24,24},{500,0}},{1,{24,24},{425,200}},{1,{24,24},{675,375}},{1,{24,24},{850,50}},{1,{24,24},{350,675}},{1,{24,24},{525,325}},{1,{24,24},{175,175}},{1,{24,24},{450,0}},{1,{24,24},{75,125}},{1,{24,24},{300,650}},{1,{24,24},{950,925}},{1,{24,24},{925,975}},{1,{24,24},{875,975}},{1,{24,24},{925,925}},{1,{24,24},{875,950}},{1,{24,24},{900,350}},{1,{24,24},{25,350}},{1,{24,24},{950,525}},{1,{24,24},{525,950}},{1,{24,24},{925,475}},{1,{24,24},{950,900}},{1,{24,24},{975,850}},{2,{24,24},{275,25}},{1,{24,24},{350,550}},{1,{24,24},{775,100}},{1,{24,24},{275,300}},{1,{24,24},{850,950}},{1,{24,24},{825,650}},{1,{24,24},{950,450}},{1,{24,24},{975,825}},{1,{24,24},{850,925}},{1,{24,24},{125,850}},{1,{24,24},{900,875}},{1,{24,24},{125,275}},{1,{24,24},{900,275}},{2,{24,24},{50,150}},{1,{24,24},{825,925}},{1,{24,24},{725,650}},{1,{24,24},{625,950}},{1,{24,24},{900,850}},{1,{24,24},{475,975}},{1,{24,24},{300,150}},{1,{24,24},{950,800}},{1,{24,24},{175,225}},{1,{24,24},{400,400}},{1,{24,24},{975,775}},{1,{24,24},{350,525}},{1,{24,24},{975,75}},{1,{24,24},{800,925}},{1,{24,24},{825,900}},{1,{24,24},{850,750}},{1,{24,24},{850,875}},{1,{24,24},{350,0}},{1,{24,24},{875,850}},{1,{24,24},{275,875}},{1,{24,24},{400,50}},{1,{24,24},{950,775}},{1,{24,24},{450,125}},{1,{24,24},{975,750}},{1,{24,24},{600,800}},{1,{24,24},{400,450}},{1,{24,24},{150,950}},{1,{24,24},{850,850}},{1,{24,24},{900,800}},{1,{24,24},{925,775}},{1,{24,24},{800,550}},{1,{24,24},{100,600}},{1,{24,24},{75,425}},{1,{24,24},{100,0}},{1,{24,24},{975,725}},{1,{24,24},{650,450}},{1,{24,24},{700,975}},{1,{24,24},{750,875}},{1,{24,24},{475,350}},{1,{24,24},{0,350}},{1,{24,24},{325,175}},{1,{24,24},{725,950}},{2,{24,24},{300,225}},{1,{24,24},{750,775}},{1,{24,24},{25,0}},{1,{24,24},{300,425}},{1,{24,24},{950,600}},{1,{24,24},{475,175}},{2,{24,24},{200,250}},{1,{24,24},{150,700}},{2,{24,24},{100,425}},{1,{24,24},{700,950}},{1,{24,24},{400,475}},{1,{24,24},{725,925}},{1,{24,24},{450,150}},{1,{24,24},{75,700}},{1,{24,24},{575,675}},{1,{24,24},{325,275}},{1,{24,24},{225,175}},{1,{24,24},{775,875}},{1,{24,24},{975,400}},{1,{24,24},{675,875}},{1,{24,24},{800,775}},{1,{24,24},{200,350}},{1,{24,24},{550,500}},{1,{24,24},{175,725}},{2,{24,24},{100,225}},{1,{24,24},{575,525}},{1,{24,24},{75,375}},{1,{24,24},{50,750}},{1,{24,24},{500,400}},{1,{24,24},{250,450}},{1,{24,24},{325,100}},{1,{24,24},{825,250}},{1,{24,24},{900,750}},{1,{24,24},{950,700}},{1,{24,24},{975,675}},{1,{24,24},{425,25}},{1,{24,24},{375,825}},{1,{24,24},{650,975}},{1,{24,24},{375,450}},{1,{24,24},{700,925}},{1,{24,24},{900,175}},{1,{24,24},{800,625}},{1,{24,24},{575,725}},{1,{24,24},{775,850}},{1,{24,24},{275,225}},{1,{24,24},{925,75}},{1,{24,24},{800,825}},{1,{24,24},{700,750}},{1,{24,24},{575,575}},{1,{24,24},{825,800}},{1,{24,24},{850,775}},{1,{24,24},{275,900}},{1,{24,24},{425,100}},{1,{24,24},{900,725}},{1,{24,24},{600,875}},{1,{24,24},{975,650}},{1,{24,24},{850,200}},{1,{24,24},{675,50}},{1,{24,24},{325,625}},{2,{24,24},{225,50}},{1,{24,24},{225,75}},{1,{24,24},{250,175}},{1,{24,24},{800,975}},{1,{24,24},{375,625}},{1,{24,24},{100,375}},{1,{24,24},{850,425}},{1,{24,24},{425,625}},{1,{24,24},{675,925}},{1,{24,24},{700,900}},{1,{24,24},{750,850}},{1,{24,24},{525,975}},{1,{24,24},{400,150}},{1,{24,24},{900,575}},{1,{24,24},{100,225}},{1,{24,24},{350,275}},{1,{24,24},{650,250}},{1,{24,24},{875,425}},{1,{24,24},{200,500}},{1,{24,24},{925,675}},{1,{24,24},{750,25}},{1,{24,24},{950,650}},{1,{24,24},{800,250}},{1,{24,24},{975,625}},{1,{24,24},{700,175}},{1,{24,24},{150,250}},{1,{24,24},{925,200}},{1,{24,24},{50,200}},{1,{24,24},{200,325}},{1,{24,24},{375,75}},{1,{24,24},{800,575}},{1,{24,24},{525,0}},{1,{24,24},{925,525}},{1,{24,24},{875,400}},{1,{24,24},{850,275}},{1,{24,24},{925,750}},{1,{24,24},{875,875}},{1,{24,24},{425,675}},{1,{24,24},{875,25}},{1,{24,24},{925,400}},{1,{24,24},{100,975}},{1,{24,24},{325,0}},{1,{24,24},{675,900}},{1,{24,24},{550,175}},{1,{24,24},{700,875}},{1,{24,24},{475,925}},{1,{24,24},{150,0}},{1,{24,24},{750,825}},{1,{24,24},{50,150}},{1,{24,24},{975,175}},{1,{24,24},{800,650}},{1,{24,24},{775,800}},{1,{24,24},{825,825}},{1,{24,24},{175,825}},{1,{24,24},{850,725}},{1,{24,24},{650,475}},{1,{24,24},{825,150}},{1,{24,24},{450,500}},{1,{24,24},{900,775}},{1,{24,24},{0,975}},{2,{24,24},{75,450}},{2,{24,24},{125,375}},{1,{24,24},{925,650}},{1,{24,24},{225,500}},{1,{24,24},{900,0}},{1,{24,24},{950,25}},{1,{24,24},{575,175}},{1,{24,24},{100,50}},{1,{24,24},{400,925}},{1,{24,24},{225,875}},{1,{24,24},{575,975}},{1,{24,24},{475,100}},{1,{24,24},{650,900}},{1,{24,24},{150,125}},{1,{24,24},{300,100}},{1,{24,24},{725,825}},{2,{24,24},{375,25}},{1,{24,24},{800,750}},{1,{24,24},{700,825}},{1,{24,24},{575,350}},{1,{24,24},{825,725}},{1,{24,24},{175,300}},{1,{24,24},{775,625}},{1,{24,24},{725,450}},{1,{24,24},{275,275}},{1,{24,24},{425,525}},{1,{24,24},{875,675}},{1,{24,24},{900,650}},{1,{24,24},{875,800}},{1,{24,24},{575,550}},{1,{24,24},{975,250}},{1,{24,24},{975,575}},{1,{24,24},{350,575}},{1,{24,24},{725,275}},{1,{24,24},{225,950}},{1,{24,24},{675,850}},{1,{24,24},{175,125}},{1,{24,24},{650,600}},{1,{24,24},{850,825}},{1,{24,24},{825,700}},{1,{24,24},{925,600}},{1,{24,24},{950,575}},{2,{24,24},{25,75}},{1,{24,24},{425,925}},{1,{24,24},{775,825}},{1,{24,24},{625,300}},{1,{24,24},{0,925}},{1,{24,24},{200,375}},{1,{24,24},{175,200}},{1,{24,24},{200,950}},{1,{24,24},{600,650}},{1,{24,24},{700,275}},{1,{24,24},{100,125}},{1,{24,24},{575,925}},{1,{24,24},{600,900}},{1,{24,24},{625,875}},{1,{24,24},{650,50}},{1,{24,24},{700,800}},{1,{24,24},{300,250}},{1,{24,24},{625,125}},{1,{24,24},{50,550}},{1,{24,24},{675,825}},{2,{24,24},{275,250}},{1,{24,24},{750,750}},{1,{24,24},{875,650}},{1,{24,24},{800,700}},{1,{24,24},{25,875}},{1,{24,24},{825,675}},{1,{24,24},{375,575}},{1,{24,24},{125,300}},{1,{24,24},{875,625}},{1,{24,24},{925,575}},{1,{24,24},{825,400}},{1,{24,24},{150,450}},{2,{24,24},{225,175}},{1,{24,24},{850,500}},{1,{24,24},{950,550}},{1,{24,24},{850,475}},{2,{24,24},{375,125}},{1,{24,24},{475,125}},{1,{24,24},{925,700}},{1,{24,24},{375,500}},{1,{24,24},{500,175}},{1,{24,24},{500,975}},{1,{24,24},{725,750}},{1,{24,24},{800,675}},{1,{24,24},{150,800}},{1,{24,24},{925,875}},{1,{24,24},{850,625}},{1,{24,24},{775,50}},{1,{24,24},{800,800}},{1,{24,24},{800,300}},{1,{24,24},{775,700}},{1,{24,24},{775,175}},{1,{24,24},{925,550}},{1,{24,24},{0,75}},{1,{24,24},{125,875}},{1,{24,24},{450,400}},{1,{24,24},{925,825}},{1,{24,24},{975,500}},{1,{24,24},{175,275}},{1,{24,24},{500,900}},{1,{24,24},{400,225}},{1,{24,24},{100,475}},{1,{24,24},{300,625}},{1,{24,24},{575,500}},{1,{24,24},{325,800}},{1,{24,24},{625,775}},{1,{24,24},{575,875}},{1,{24,24},{675,775}},{1,{24,24},{675,200}},{1,{24,24},{550,750}},{1,{24,24},{625,625}},{1,{24,24},{650,325}},{1,{24,24},{800,375}},{1,{24,24},{625,350}},{1,{24,24},{475,825}},{1,{24,24},{775,675}},{1,{24,24},{700,100}},{1,{24,24},{675,75}},{1,{24,24},{250,375}},{1,{24,24},{25,25}},{1,{24,24},{0,325}},{1,{24,24},{875,450}},{1,{24,24},{825,625}},{1,{24,24},{650,100}},{1,{24,24},{850,600}},{1,{24,24},{600,850}},{1,{24,24},{500,275}},{1,{24,24},{725,150}},{1,{24,24},{650,700}},{1,{24,24},{625,0}},{1,{24,24},{800,525}},{1,{24,24},{550,0}},{1,{24,24},{125,50}},{1,{24,24},{975,475}},{2,{24,24},{50,425}},{2,{24,24},{150,50}},{1,{24,24},{300,700}},{1,{24,24},{950,500}},{1,{24,24},{550,875}},{1,{24,24},{475,200}},{1,{24,24},{600,825}},{1,{24,24},{625,800}},{1,{24,24},{650,775}},{1,{24,24},{675,400}},{1,{24,24},{675,750}},{1,{24,24},{325,525}},{2,{24,24},{425,50}},{1,{24,24},{275,125}},{1,{24,24},{700,725}},{1,{24,24},{725,900}},{1,{24,24},{375,150}},{1,{24,24},{800,150}},{1,{24,24},{825,600}},{1,{24,24},{450,100}},{1,{24,24},{850,575}},{1,{24,24},{875,550}},{1,{24,24},{925,500}},{2,{24,24},{100,75}},{1,{24,24},{425,50}},{1,{24,24},{375,700}},{1,{24,24},{200,125}},{1,{24,24},{225,200}},{1,{24,24},{400,625}},{1,{24,24},{200,525}},{1,{24,24},{75,750}},{1,{24,24},{300,25}},{2,{24,24},{0,75}},{1,{24,24},{425,975}},{1,{24,24},{450,950}},{1,{24,24},{150,725}},{1,{24,24},{550,850}},{1,{24,24},{575,825}},{1,{24,24},{550,900}},{1,{24,24},{700,325}},{1,{24,24},{725,675}},{1,{24,24},{800,600}},{2,{24,24},{0,250}},{1,{24,24},{150,600}},{1,{24,24},{825,575}},{1,{24,24},{900,500}},{1,{24,24},{725,475}},{1,{24,24},{300,825}},{1,{24,24},{525,775}},{1,{24,24},{625,725}},{1,{24,24},{750,175}},{1,{24,24},{875,525}},{1,{24,24},{950,850}},{1,{24,24},{975,425}},{1,{24,24},{400,975}},{1,{24,24},{825,225}},{1,{24,24},{925,900}},{1,{24,24},{725,600}},{1,{24,24},{375,375}},{1,{24,24},{325,950}},{1,{24,24},{775,350}},{1,{24,24},{450,75}},{2,{24,24},{175,0}},{1,{24,24},{450,925}},{1,{24,24},{600,700}},{2,{24,24},{75,250}},{1,{24,24},{275,200}},{1,{24,24},{550,450}},{2,{24,24},{250,75}},{1,{24,24},{350,250}},{1,{24,24},{300,375}},{1,{24,24},{500,875}},{1,{24,24},{0,775}},{1,{24,24},{625,675}},{1,{24,24},{50,700}},{1,{24,24},{375,25}},{1,{24,24},{975,350}},{1,{24,24},{600,775}},{1,{24,24},{425,0}},{1,{24,24},{25,625}},{1,{24,24},{625,200}},{1,{24,24},{375,600}},{1,{24,24},{700,675}},{1,{24,24},{525,750}},{1,{24,24},{525,350}},{1,{24,24},{750,625}},{1,{24,24},{375,525}},{1,{24,24},{800,25}},{1,{24,24},{900,475}},{1,{24,24},{250,200}},{1,{24,24},{925,450}},{2,{24,24},{200,325}},{1,{24,24},{850,800}},{1,{24,24},{400,950}},{1,{24,24},{825,550}},{1,{24,24},{450,900}},{1,{24,24},{475,575}},{1,{24,24},{475,875}},{1,{24,24},{500,850}},{1,{24,24},{625,500}},{1,{24,24},{925,325}},{1,{24,24},{275,350}},{1,{24,24},{400,750}},{1,{24,24},{600,750}},{1,{24,24},{25,575}},{1,{24,24},{550,800}},{1,{24,24},{75,175}},{1,{24,24},{675,675}},{1,{24,24},{700,650}},{1,{24,24},{275,925}},{1,{24,24},{675,225}},{1,{24,24},{750,600}},{1,{24,24},{950,750}},{1,{24,24},{675,125}},{1,{24,24},{825,525}},{1,{24,24},{875,475}},{2,{24,24},{100,25}},{1,{24,24},{950,400}},{1,{24,24},{450,675}},{1,{24,24},{800,50}},{1,{24,24},{950,625}},{1,{24,24},{25,775}},{1,{24,24},{625,550}},{1,{24,24},{600,600}},{1,{24,24},{725,75}},{1,{24,24},{625,75}},{1,{24,24},{575,125}},{1,{24,24},{975,450}},{1,{24,24},{150,175}},{1,{24,24},{675,575}},{1,{24,24},{25,375}},{1,{24,24},{425,900}},{1,{24,24},{400,275}},{1,{24,24},{275,600}},{1,{24,24},{975,25}},{1,{24,24},{875,275}},{1,{24,24},{400,525}},{1,{24,24},{550,600}},{1,{24,24},{450,875}},{2,{24,24},{25,275}},{1,{24,24},{75,975}},{1,{24,24},{0,225}},{1,{24,24},{600,725}},{1,{24,24},{25,800}},{1,{24,24},{625,700}},{1,{24,24},{700,625}},{1,{24,24},{650,375}},{1,{24,24},{900,550}},{1,{24,24},{775,550}},{1,{24,24},{850,75}},{1,{24,24},{800,475}},{1,{24,24},{900,425}},{1,{24,24},{325,975}},{1,{24,24},{425,800}},{1,{24,24},{650,725}},{1,{24,24},{350,950}},{1,{24,24},{825,875}},{1,{24,24},{450,850}},{1,{24,24},{250,925}},{1,{24,24},{450,600}},{1,{24,24},{725,725}},{1,{24,24},{575,150}},{1,{24,24},{675,950}},{1,{24,24},{125,350}},{1,{24,24},{800,100}},{1,{24,24},{425,225}},{1,{24,24},{675,625}},{1,{24,24},{450,975}},{1,{24,24},{225,50}},{1,{24,24},{750,550}},{1,{24,24},{550,825}},{2,{24,24},{275,175}},{1,{24,24},{175,375}},{1,{24,24},{825,475}},{1,{24,24},{825,775}},{1,{24,24},{0,375}},{1,{24,24},{750,225}},{1,{24,24},{900,400}},{1,{24,24},{650,25}},{1,{24,24},{300,975}},{1,{24,24},{525,75}},{1,{24,24},{400,875}},{1,{24,24},{425,850}},{1,{24,24},{850,150}},{1,{24,24},{450,825}},{2,{24,24},{50,225}},{1,{24,24},{225,25}},{1,{24,24},{0,400}},{1,{24,24},{625,650}},{1,{24,24},{650,625}},{1,{24,24},{300,50}},{1,{24,24},{550,25}},{1,{24,24},{750,525}},{1,{24,24},{775,500}},{1,{24,24},{925,350}},{1,{24,24},{850,325}},{1,{24,24},{275,0}},{1,{24,24},{975,300}},{1,{24,24},{750,325}},{2,{24,24},{25,475}},{1,{24,24},{325,925}},{1,{24,24},{350,900}},{1,{24,24},{525,600}},{1,{24,24},{750,250}},{1,{24,24},{475,550}},{1,{24,24},{475,775}},{1,{24,24},{400,850}},{1,{24,24},{500,750}},{1,{24,24},{575,275}},{1,{24,24},{750,900}},{1,{24,24},{900,225}},{1,{24,24},{700,550}},{1,{24,24},{0,450}},{1,{24,24},{725,525}},{1,{24,24},{750,500}},{1,{24,24},{800,0}},{1,{24,24},{825,425}},{1,{24,24},{750,300}},{1,{24,24},{175,25}},{1,{24,24},{0,50}},{1,{24,24},{650,875}},{1,{24,24},{75,100}},{1,{24,24},{850,400}},{1,{24,24},{25,75}},{1,{24,24},{875,375}},{1,{24,24},{175,700}},{1,{24,24},{475,250}},{1,{24,24},{950,50}},{1,{24,24},{100,625}},{1,{24,24},{275,175}},{1,{24,24},{575,425}},{1,{24,24},{575,775}},{1,{24,24},{725,375}},{1,{24,24},{125,700}},{1,{24,24},{450,625}},{1,{24,24},{225,625}},{1,{24,24},{250,975}},{1,{24,24},{800,875}},{1,{24,24},{150,225}},{1,{24,24},{425,550}},{1,{24,24},{450,700}},{1,{24,24},{350,875}},{1,{24,24},{350,325}},{1,{24,24},{100,750}},{1,{24,24},{325,900}},{1,{24,24},{400,825}},{1,{24,24},{375,850}},{2,{24,24},{0,225}},{1,{24,24},{25,275}},{1,{24,24},{225,900}},{1,{24,24},{850,225}},{1,{24,24},{475,675}},{1,{24,24},{550,325}},{1,{24,24},{225,525}},{1,{24,24},{600,625}},{1,{24,24},{625,600}},{1,{24,24},{600,575}},{1,{24,24},{650,575}},{1,{24,24},{725,500}},{1,{24,24},{0,750}},{1,{24,24},{675,550}},{1,{24,24},{200,675}},{1,{24,24},{850,375}},{1,{24,24},{525,725}},{1,{24,24},{350,50}},{1,{24,24},{475,475}},{1,{24,24},{950,275}},{1,{24,24},{200,575}},{1,{24,24},{225,975}},{2,{24,24},{75,175}},{1,{24,24},{925,225}},{1,{24,24},{50,925}},{1,{24,24},{325,875}},{1,{24,24},{625,375}},{1,{24,24},{350,400}},{1,{24,24},{350,850}},{1,{24,24},{425,775}},{1,{24,24},{200,900}},{1,{24,24},{550,650}},{1,{24,24},{425,175}},{1,{24,24},{675,525}},{1,{24,24},{950,100}},{1,{24,24},{475,0}},{1,{24,24},{175,50}},{1,{24,24},{650,750}},{1,{24,24},{125,375}},{1,{24,24},{125,525}},{1,{24,24},{550,250}},{1,{24,24},{850,100}},{1,{24,24},{75,575}},{1,{24,24},{825,375}},{1,{24,24},{375,175}},{1,{24,24},{25,225}},{1,{24,24},{650,950}},{1,{24,24},{250,900}},{1,{24,24},{250,400}},{1,{24,24},{975,225}},{1,{24,24},{600,550}},{1,{24,24},{50,600}},{1,{24,24},{0,575}},{1,{24,24},{200,975}},{1,{24,24},{675,250}},{1,{24,24},{625,900}},{1,{24,24},{250,300}},{1,{24,24},{700,50}},{1,{24,24},{875,750}},{1,{24,24},{325,850}},{1,{24,24},{250,475}},{1,{24,24},{325,350}},{1,{24,24},{600,150}},{1,{24,24},{25,175}},{1,{24,24},{175,75}},{1,{24,24},{350,825}},{1,{24,24},{375,725}},{1,{24,24},{400,775}},{1,{24,24},{425,750}},{1,{24,24},{475,700}},{1,{24,24},{300,775}},{1,{24,24},{500,150}},{1,{24,24},{75,625}},{1,{24,24},{475,225}},{1,{24,24},{175,900}},{1,{24,24},{550,625}},{1,{24,24},{200,875}},{1,{24,24},{350,300}},{1,{24,24},{125,200}},{1,{24,24},{300,850}},{1,{24,24},{375,400}},{1,{24,24},{675,500}},{2,{24,24},{25,25}},{1,{24,24},{650,400}},{1,{24,24},{825,350}},{1,{24,24},{175,875}},{1,{24,24},{625,225}},{1,{24,24},{525,450}},{1,{24,24},{950,825}},{1,{24,24},{200,100}},{1,{24,24},{125,25}},{1,{24,24},{750,700}},{1,{24,24},{150,25}},{1,{24,24},{275,725}},{1,{24,24},{50,25}},{1,{24,24},{375,225}},{1,{24,24},{975,200}},{1,{24,24},{225,925}},{1,{24,24},{950,250}},{1,{24,24},{300,125}},{1,{24,24},{450,350}},{1,{24,24},{925,800}},{1,{24,24},{350,800}},{1,{24,24},{425,725}},{1,{24,24},{825,0}},{1,{24,24},{950,300}},{2,{24,24},{150,125}},{1,{24,24},{250,675}},{1,{24,24},{750,400}},{1,{24,24},{225,300}},{1,{24,24},{200,300}},{1,{24,24},{800,350}},{2,{24,24},{450,0}},{1,{24,24},{900,250}},{1,{24,24},{125,475}},{1,{24,24},{425,375}},{1,{24,24},{400,175}},{1,{24,24},{625,325}},{1,{24,24},{975,975}},{1,{24,24},{175,475}},{1,{24,24},{500,725}},{1,{24,24},{750,100}},{1,{24,24},{100,650}},{1,{24,24},{775,275}},{1,{24,24},{275,500}},{1,{24,24},{475,650}},{1,{24,24},{975,375}},{2,{24,24},{300,125}},{1,{24,24},{375,875}},{1,{24,24},{750,50}},{1,{24,24},{425,875}},{2,{24,24},{350,75}},{1,{24,24},{800,325}},{1,{24,24},{250,775}},{1,{24,24},{950,175}},{1,{24,24},{975,150}},{1,{24,24},{200,225}},{1,{24,24},{175,925}},{1,{24,24},{650,550}},{1,{24,24},{175,650}},{1,{24,24},{975,600}},{1,{24,24},{50,725}},{1,{24,24},{0,200}},{1,{24,24},{300,0}},{1,{24,24},{825,300}},{2,{24,24},{325,125}},{1,{24,24},{250,425}},{1,{24,24},{200,450}},{1,{24,24},{200,425}},{2,{24,24},{225,25}},{1,{24,24},{250,25}},{1,{24,24},{375,800}},{1,{24,24},{475,625}},{1,{24,24},{175,450}},{1,{24,24},{450,650}},{1,{24,24},{400,700}},{1,{24,24},{750,125}},{1,{24,24},{850,700}},{1,{24,24},{275,750}},{1,{24,24},{550,550}},{1,{24,24},{500,600}},{1,{24,24},{450,575}},{1,{24,24},{50,100}},{1,{24,24},{600,500}},{1,{24,24},{150,400}},{1,{24,24},{350,450}},{1,{24,24},{100,725}},{1,{24,24},{625,475}},{1,{24,24},{100,425}},{1,{24,24},{300,475}},{1,{24,24},{975,100}},{1,{24,24},{725,175}},{1,{24,24},{700,400}},{1,{24,24},{75,25}},{1,{24,24},{450,225}},{2,{24,24},{250,150}},{1,{24,24},{675,350}},{1,{24,24},{950,425}},{1,{24,24},{925,175}},{1,{24,24},{975,125}},{1,{24,24},{550,475}},{1,{24,24},{500,700}},{1,{24,24},{575,600}},{1,{24,24},{225,850}},{1,{24,24},{250,825}},{1,{24,24},{550,400}},{1,{24,24},{275,800}},{1,{24,24},{375,125}},{1,{24,24},{525,650}},{1,{24,24},{325,750}},{1,{24,24},{400,675}},{1,{24,24},{350,725}},{1,{24,24},{350,650}},{1,{24,24},{225,100}},{1,{24,24},{425,650}},{1,{24,24},{975,275}},{1,{24,24},{525,525}},{1,{24,24},{500,575}},{1,{24,24},{25,50}},{1,{24,24},{100,875}},{1,{24,24},{550,275}},{1,{24,24},{350,75}},{1,{24,24},{500,950}},{1,{24,24},{725,975}},{1,{24,24},{450,775}},{1,{24,24},{275,25}},{1,{24,24},{300,400}},{2,{24,24},{175,25}},{2,{24,24},{325,225}},{1,{24,24},{875,200}},{1,{24,24},{350,475}},{1,{24,24},{50,850}},{1,{24,24},{225,750}},{1,{24,24},{325,575}},{1,{24,24},{925,150}},{1,{24,24},{575,750}},{1,{24,24},{325,150}},{1,{24,24},{275,325}},{1,{24,24},{600,0}},{1,{24,24},{425,300}},{1,{24,24},{850,550}},{1,{24,24},{725,25}},{1,{24,24},{50,650}},{1,{24,24},{125,925}},{1,{24,24},{750,350}},{1,{24,24},{925,425}},{1,{24,24},{350,100}},{1,{24,24},{775,325}},{1,{24,24},{625,425}},{1,{24,24},{0,25}},{1,{24,24},{725,325}},{1,{24,24},{600,450}},{1,{24,24},{375,750}},{1,{24,24},{875,175}},{1,{24,24},{600,275}},{1,{24,24},{925,125}},{1,{24,24},{525,275}},{1,{24,24},{0,275}},{1,{24,24},{925,0}},{1,{24,24},{775,950}},{1,{24,24},{75,950}},{1,{24,24},{175,350}},{1,{24,24},{100,925}},{1,{24,24},{125,900}},{1,{24,24},{175,250}},{1,{24,24},{175,850}},{1,{24,24},{200,825}},{1,{24,24},{225,800}},{1,{24,24},{825,125}},{1,{24,24},{875,250}},{1,{24,24},{425,600}},{1,{24,24},{500,525}},{1,{24,24},{575,450}},{1,{24,24},{325,200}},{1,{24,24},{500,125}},{1,{24,24},{125,750}},{1,{24,24},{300,300}},{1,{24,24},{275,400}},{1,{24,24},{700,25}},{2,{24,24},{100,275}},{2,{24,24},{100,100}},{1,{24,24},{150,925}},{1,{24,24},{750,275}},{1,{24,24},{225,600}},{1,{24,24},{775,250}},{1,{24,24},{325,75}},{1,{24,24},{275,850}},{1,{24,24},{675,100}},{1,{24,24},{875,150}},{1,{24,24},{150,425}},{1,{24,24},{900,125}},{1,{24,24},{350,125}},{1,{24,24},{200,800}},{1,{24,24},{150,325}},{1,{24,24},{975,50}},{1,{24,24},{250,275}},{1,{24,24},{300,275}},{2,{24,24},{75,150}},{1,{24,24},{150,850}},{1,{24,24},{950,75}},{2,{24,24},{150,325}},{1,{24,24},{975,950}},{1,{24,24},{250,575}},{1,{24,24},{525,900}},{1,{24,24},{625,250}},{1,{24,24},{400,600}},{1,{24,24},{425,575}},{1,{24,24},{475,525}},{1,{24,24},{500,500}},{1,{24,24},{100,800}},{1,{24,24},{250,225}},{1,{24,24},{25,750}},{1,{24,24},{525,475}},{1,{24,24},{600,400}},{1,{24,24},{675,325}},{1,{24,24},{575,950}},{1,{24,24},{425,825}},{1,{24,24},{400,425}},{1,{24,24},{675,175}},{1,{24,24},{150,625}},{1,{24,24},{200,175}},{1,{24,24},{550,575}},{1,{24,24},{225,275}},{1,{24,24},{375,0}},{1,{24,24},{350,925}},{1,{24,24},{825,175}},{1,{24,24},{175,400}},{1,{24,24},{25,950}},{1,{24,24},{150,825}},{1,{24,24},{400,550}},{1,{24,24},{525,375}},{1,{24,24},{350,625}},{1,{24,24},{275,700}},{1,{24,24},{500,475}},{1,{24,24},{550,950}},{1,{24,24},{200,475}},{1,{24,24},{225,575}},{1,{24,24},{775,75}},{1,{24,24},{275,375}},{1,{24,24},{725,250}},{1,{24,24},{600,200}},{1,{24,24},{100,250}},{1,{24,24},{200,550}},{1,{24,24},{875,500}},{1,{24,24},{850,125}},{1,{24,24},{925,50}},{1,{24,24},{975,0}},{1,{24,24},{0,950}},{1,{24,24},{25,850}},{1,{24,24},{675,150}},{1,{24,24},{375,300}},{1,{24,24},{125,125}},{1,{24,24},{25,550}},{1,{24,24},{25,925}},{1,{24,24},{100,850}},{1,{24,24},{800,500}},{1,{24,24},{275,75}},{1,{24,24},{225,725}},{1,{24,24},{125,800}},{1,{24,24},{775,25}},{1,{24,24},{275,675}},{1,{24,24},{550,100}},{1,{24,24},{925,950}},{1,{24,24},{625,975}},{1,{24,24},{900,600}},{1,{24,24},{350,600}},{1,{24,24},{650,300}},{1,{24,24},{675,275}},{1,{24,24},{900,50}},{1,{24,24},{50,875}},{1,{24,24},{75,850}},{1,{24,24},{50,575}},{1,{24,24},{175,750}},{1,{24,24},{300,225}},{1,{24,24},{225,700}},{1,{24,24},{675,475}},{1,{24,24},{525,225}},{2,{24,24},{200,150}},{1,{24,24},{550,375}},{1,{24,24},{525,400}},{1,{24,24},{850,350}},{2,{24,24},{225,150}},{2,{24,24},{350,150}},{1,{24,24},{825,100}},{1,{24,24},{0,125}},{1,{24,24},{875,50}},{1,{24,24},{75,825}},{1,{24,24},{525,800}},{2,{24,24},{350,25}},{1,{24,24},{250,325}},{1,{24,24},{250,650}},{1,{24,24},{275,625}},{1,{24,24},{675,300}},{1,{24,24},{125,325}},{1,{24,24},{0,300}},{1,{24,24},{875,925}},{1,{24,24},{600,125}},{1,{24,24},{50,300}},{1,{24,24},{175,675}},{1,{24,24},{425,475}},{1,{24,24},{475,425}},{1,{24,24},{325,650}},{1,{24,24},{625,275}},{1,{24,24},{25,475}},{1,{24,24},{750,150}},{1,{24,24},{725,0}},{1,{24,24},{225,650}},{1,{24,24},{800,225}},{1,{24,24},{650,925}},{1,{24,24},{100,775}},{1,{24,24},{75,800}},{1,{24,24},{325,550}},{1,{24,24},{250,525}},{1,{24,24},{525,200}},{2,{24,24},{350,200}},{1,{24,24},{900,150}},{1,{24,24},{325,675}},{2,{24,24},{275,100}},{1,{24,24},{25,825}},{1,{24,24},{125,725}},{1,{24,24},{775,650}},{1,{24,24},{350,500}},{1,{24,24},{175,150}},{1,{24,24},{725,400}},{1,{24,24},{900,975}},{1,{24,24},{775,450}},{1,{24,24},{775,225}},{1,{24,24},{825,25}},{1,{24,24},{500,200}},{1,{24,24},{550,225}},{1,{24,24},{150,675}},{2,{24,24},{50,400}},{1,{24,24},{525,550}},{1,{24,24},{650,175}},{1,{24,24},{750,75}},{1,{24,24},{875,600}},{1,{24,24},{275,425}},{1,{24,24},{250,500}},{1,{24,24},{175,625}},{1,{24,24},{0,700}},{1,{24,24},{125,0}},{1,{24,24},{200,600}},{1,{24,24},{250,550}},{1,{24,24},{400,350}},{1,{24,24},{25,700}},{1,{24,24},{800,400}},{1,{24,24},{625,175}},{1,{24,24},{675,450}},{1,{24,24},{800,450}},{1,{24,24},{625,25}},{1,{24,24},{925,375}},{1,{24,24},{0,500}},{1,{24,24},{675,425}},{1,{24,24},{425,350}},{1,{24,24},{450,325}},{1,{24,24},{225,550}},{1,{24,24},{650,125}},{1,{24,24},{375,350}},{1,{24,24},{700,75}},{1,{24,24},{725,50}},{1,{24,24},{150,200}},{1,{24,24},{775,0}},{1,{24,24},{625,750}},{1,{24,24},{75,675}},{1,{24,24},{25,125}},{1,{24,24},{575,50}},{1,{24,24},{825,75}},{1,{24,24},{800,175}},{1,{24,24},{275,475}},{1,{24,24},{275,525}},{1,{24,24},{275,150}},{1,{24,24},{425,500}},{1,{24,24},{50,675}},{1,{24,24},{150,575}},{1,{24,24},{75,75}},{1,{24,24},{425,400}},{1,{24,24},{450,275}},{1,{24,24},{100,700}},{1,{24,24},{225,225}},{1,{24,24},{375,325}},{1,{24,24},{50,625}},{1,{24,24},{0,475}},{1,{24,24},{75,875}},{1,{24,24},{525,150}},{1,{24,24},{675,700}},{1,{24,24},{750,450}},{1,{24,24},{275,825}},{1,{24,24},{450,200}},{1,{24,24},{150,350}},{1,{24,24},{650,650}},{1,{24,24},{875,700}},{1,{24,24},{575,75}},{2,{24,24},{175,150}},{1,{24,24},{150,475}},{1,{24,24},{75,525}},{1,{24,24},{975,925}},{1,{24,24},{450,175}},{1,{24,24},{475,150}},{1,{24,24},{0,600}},{1,{24,24},{375,250}},{1,{24,24},{925,250}},{2,{24,24},{125,225}},{1,{24,24},{100,150}},{1,{24,24},{125,650}},{1,{24,24},{125,450}},{1,{24,24},{75,200}},{1,{24,24},{625,450}},{1,{24,24},{700,575}},{1,{24,24},{400,25}},{1,{24,24},{525,575}},{1,{24,24},{525,25}},{2,{24,24},{200,25}},{1,{24,24},{350,175}},{1,{24,24},{625,150}},{1,{24,24},{175,325}},{1,{24,24},{425,75}},{1,{24,24},{25,450}},{1,{24,24},{500,550}},{1,{24,24},{125,975}},{1,{24,24},{575,700}},{1,{24,24},{225,150}},{2,{24,24},{400,50}},{1,{24,24},{250,50}},{1,{24,24},{150,75}}}}}
local iconIndices: { string } = icons[1]
local idIndices: { string } = icons[2]
local iconRegistry: { [number]: { number | { number } } } = icons[3]

Lucide.Icons = iconIndices
function Lucide.GetAsset(name: string)
	local size = 48

	local iconIndex = table.find(iconIndices, name)

	if not iconIndex then
		return nil
	end

	local currentDifference = math.huge
	local currentSize = size

	for registrySize, _ in iconRegistry do
		local diff = math.abs(size - registrySize)

		if diff < currentDifference then
			currentDifference = diff
			currentSize = registrySize
		end
	end

	local icon = iconRegistry[currentSize][iconIndex]
	if icon then
		return {
			IconName = name,
			Url = idIndices[icon[1]],
			ImageRectSize = Vector2.new(icon[2][1], icon[2][2]),
			ImageRectOffset = Vector2.new(icon[3][1], icon[3][2]),
		}
	end

	return nil
end

return Lucide
end
__modules["vendor/ui"] = function(use) -- ../repo/ui/Library.lua
-- Obsidian UI, Crimson restyle for Slopix Hub. Fork of github.com/deividcomsono/Obsidian, rebased on
-- upstream fb0b7b2 (2026-09-28: nested tabboxes/groupboxes, button icons, sizing fixes).
local CloneRef = type(cloneref) == "function" and cloneref or clonereference
local function cloneref(instance: any)
if type(CloneRef) == "function" then
local Ok, Reference = pcall(CloneRef, instance)
if Ok and typeof(Reference) == "Instance" then return Reference end
end
return instance
end
local CoreGui: CoreGui = cloneref(game:GetService("CoreGui"))
local GuiService: GuiService = cloneref(game:GetService("GuiService"))
local Players: Players = cloneref(game:GetService("Players"))
local RunService: RunService = cloneref(game:GetService("RunService"))
local SoundService: SoundService = cloneref(game:GetService("SoundService"))
local UserInputService: UserInputService = cloneref(game:GetService("UserInputService"))
local TextService: TextService = cloneref(game:GetService("TextService"))
local Teams: Teams = cloneref(game:GetService("Teams"))
local TweenService: TweenService = cloneref(game:GetService("TweenService"))
local GlobalEnvGetter = getgenv
local GlobalEnv = _G
if type(GlobalEnvGetter) == "function" then
local Ok, Value = pcall(GlobalEnvGetter)
if Ok and type(Value) == "table" then GlobalEnv = Value end
end
local function getgenv() return GlobalEnv end
local setclipboard = type(setclipboard) == "function" and setclipboard or toclipboard
local protectgui = protectgui or (type(syn) == "table" and syn.protect_gui) or function() end
local SetThreadIdentity = setthreadidentity or set_thread_identity or setidentity or setthreadcontext
local function Elevate()
if type(SetThreadIdentity) == "function" then
pcall(SetThreadIdentity, 8)
end
end
local gethui = gethui or get_hidden_gui or function()
return CoreGui
end
local PlayerDeadline = os.clock() + 30
while not Players.LocalPlayer and os.clock() < PlayerDeadline do task.wait(0.05) end
local LocalPlayer = assert(Players.LocalPlayer, "Slopix: local player is still loading; run the script again")
local Mouse = cloneref(LocalPlayer:GetMouse())
local Labels = {}
local Buttons = {}
local Toggles = {}
local Options = {}
local Tooltips = {}
local BaseURL = "https://raw.githubusercontent.com/deividcomsono/Obsidian/refs/heads/main/"
local CustomImageManager = {}
local CustomImageManagerAssets = {
TransparencyTexture = {
RobloxId = 139785960036434,
Path = "Obsidian/assets/TransparencyTexture.png",
URL = BaseURL .. "assets/TransparencyTexture.png",
Id = nil,
},
SaturationMap = {
RobloxId = 4155801252,
Path = "Obsidian/assets/SaturationMap.png",
URL = BaseURL .. "assets/SaturationMap.png",
Id = nil,
},
LoadingIcon = {
RobloxId = 97544096941083,
Path = "Obsidian/assets/LoadingIcon.png",
URL = BaseURL .. "assets/LoadingIcon.png",
Id = nil,
},
CheckIcon = {
RobloxId = 97682394690683,
Path = "Obsidian/assets/CheckIcon.png",
URL = BaseURL .. "assets/CheckIcon.png",
Id = nil,
},
}
do
local function RecursiveCreatePath(Path: string, IsFile: boolean?)
if type(isfolder) ~= "function" or type(makefolder) ~= "function" then
return
end
local Segments = Path:split("/")
local TraversedPath = ""
if IsFile then
table.remove(Segments, #Segments)
end
for _, Segment in ipairs(Segments) do
if not isfolder(TraversedPath .. Segment) then
makefolder(TraversedPath .. Segment)
end
TraversedPath = TraversedPath .. Segment .. "/"
end
return TraversedPath
end
function CustomImageManager.AddAsset(
AssetName: string,
RobloxAssetId: number,
URL: string,
ForceRedownload: boolean?
)
if CustomImageManagerAssets[AssetName] ~= nil then
error(string.format("Asset %q already exists", AssetName))
end
assert(typeof(RobloxAssetId) == "number", "RobloxAssetId must be a number")
CustomImageManagerAssets[AssetName] = {
RobloxId = RobloxAssetId,
Path = string.format("Obsidian/custom_assets/%s", AssetName),
URL = URL,
Id = nil,
}
CustomImageManager.DownloadAsset(AssetName, ForceRedownload)
end
function CustomImageManager.GetAsset(AssetName: string)
if not CustomImageManagerAssets[AssetName] then
return nil
end
local AssetData = CustomImageManagerAssets[AssetName]
if AssetData.Id then
return AssetData.Id
end
local AssetID = string.format("rbxassetid://%s", AssetData.RobloxId)
if type(getcustomasset) == "function" then
local Success, NewID = pcall(getcustomasset, AssetData.Path)
if Success and NewID then
AssetID = NewID
end
end
AssetData.Id = AssetID
return AssetID
end
function CustomImageManager.DownloadAsset(AssetName: string, ForceRedownload: boolean?)
if type(getcustomasset) ~= "function" or type(writefile) ~= "function" or type(isfile) ~= "function" then
return false, "missing functions"
end
local success, errorMessage = pcall(function()
local AssetData = CustomImageManagerAssets[AssetName]
RecursiveCreatePath(AssetData.Path, true)
if ForceRedownload ~= true and isfile(AssetData.Path) then return end
writefile(AssetData.Path, game:HttpGet(AssetData.URL))
end)
return success, errorMessage
end
-- Built-in Roblox asset IDs work without a filesystem or network. Download custom copies only
-- when explicitly requested through DownloadAsset/AddAsset, never on the menu's startup path.
end
local Library = {
LocalPlayer = LocalPlayer,
IsRobloxFocused = true,
DevicePlatform = nil,
IsMobile = false,
ScreenGui = nil,
Floats = nil,
Overlay = nil,
Window = nil,
WindowContainer = nil,
SearchText = "",
Searching = false,
GlobalSearch = false,
LastSearchTab = nil,
ActiveTab = nil,
PreviousTab = nil,
Tabs = {},
TabButtons = {},
DependencyBoxes = {},
KeybindFrame = nil,
KeybindContainer = nil,
KeybindToggles = {},
Notifications = {},
NotifySide = "Right",
NotifyTweenInfo = TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
Dialogues = {},
ActiveDialog = nil,
ActiveLoading = nil,
ContextMenus = {},
Corners = {},
SpecificCorners = {},
TweenInfo = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
TabTransitionInfo = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
TabSwipeOffset = 26,
TabSwipeFrom = "bottom",
WindowAnimationInfo = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
DropdownTransitionInfo = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
KeyPickerTransitionInfo = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
GroupboxTweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
RotatingChevronTweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
Animations = {
ToggleWindow = false,
TabSwitch = false,
Groupbox = false,
Dropdown = false,
KeyPicker = false
},
Toggled = false,
Unloaded = false,
Labels = Labels,
Buttons = Buttons,
Toggles = Toggles,
Options = Options,
ToggleKeybind = Enum.KeyCode.RightControl,
ShowToggleFrameInKeybinds = true,
NotifyOnError = false,
ShowCustomCursor = true,
ForceCheckbox = false,
CantDragForced = false,
DraggableElements = {},
PopOutSnapDistance = 80,
PopOutDragThreshold = 8,
PopOutHoldTime = 0.15,
Signals = {},
UnloadSignals = {},
OriginalMinSize = Vector2.new(480, 360),
MinSize = Vector2.new(480, 360),
DPIScale = 1,
CornerRadius = 8,
IsLightTheme = false,
Scheme = {
BackgroundColor = Color3.fromRGB(13, 12, 18),
MainColor = Color3.fromRGB(30, 27, 40),
AccentColor = Color3.fromRGB(235, 64, 96),
OutlineColor = Color3.fromRGB(48, 43, 62),
FontColor = Color3.fromRGB(240, 238, 246),
Font = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Medium),
RedColor = Color3.fromRGB(255, 50, 50),
DestructiveColor = Color3.fromRGB(220, 38, 38),
DarkColor = Color3.new(0, 0, 0),
WhiteColor = Color3.new(1, 1, 1),
BackgroundImage = ""
},
Registry = {},
Scales = {},
ScalesOffset = {},
OriginalMouseIconEnabled = UserInputService.MouseIconEnabled,
ShowCursorBinding = string.sub(tostring({}), 10),
ImageManager = CustomImageManager,
Notify = nil, Toggle = nil -- we love luau lsp
}
if RunService:IsStudio() then
if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
Library.IsMobile = true
Library.OriginalMinSize = Vector2.new(480, 240)
else
Library.IsMobile = false
Library.OriginalMinSize = Vector2.new(480, 360)
end
else
pcall(function()
Library.DevicePlatform = UserInputService:GetPlatform()
end)
Library.IsMobile = (Library.DevicePlatform == Enum.Platform.Android or Library.DevicePlatform == Enum.Platform.IOS)
Library.OriginalMinSize = Library.IsMobile and Vector2.new(480, 240) or Vector2.new(480, 360)
end
local Templates = {
Frame = {
BorderSizePixel = 0,
},
ImageLabel = {
BackgroundTransparency = 1,
BorderSizePixel = 0,
},
ImageButton = {
AutoButtonColor = false,
BorderSizePixel = 0,
},
ScrollingFrame = {
BorderSizePixel = 0,
},
TextLabel = {
BorderSizePixel = 0,
FontFace = "Font",
RichText = true,
TextColor3 = "FontColor",
},
TextButton = {
AutoButtonColor = false,
BorderSizePixel = 0,
FontFace = "Font",
RichText = true,
TextColor3 = "FontColor",
},
TextBox = {
BorderSizePixel = 0,
FontFace = "Font",
PlaceholderColor3 = function()
local H, S, V = Library.Scheme.FontColor:ToHSV()
return Color3.fromHSV(H, S, V / 2)
end,
Text = "",
TextColor3 = "FontColor",
},
UIListLayout = {
SortOrder = Enum.SortOrder.LayoutOrder,
},
UIStroke = {
ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
},
Window = {
Title = "No Title",
Footer = "No Footer",
Position = UDim2.fromOffset(6, 6),
Size = UDim2.fromOffset(720, 600),
IconSize = UDim2.fromOffset(30, 30),
AutoShow = true,
Center = true,
Resizable = true,
AlwaysOnTop = false,
Snapping = false,
SnapDistance = 28,
SnapMargin = 8,
SnapAvoidCoreGui = true,
SearchbarSize = UDim2.fromScale(1, 1),
GlobalSearch = false,
CornerRadius = 8,
NotifySide = "Right",
ShowCustomCursor = true,
Font = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Medium),
ToggleKeybind = Enum.KeyCode.RightControl,
ShowMobileButtons = true,
MobileButtonsSide = "Left",
UnlockMouseWhileOpen = true,
Intro = true,
ShowProfile = true,
FloatingButton = true,
EnableSidebarResize = false,
EnableCompacting = true,
DisableCompactingSnap = false,
SidebarCompacted = false,
MinContainerWidth = 256,
MinSidebarWidth = 128,
SidebarCompactWidth = 48,
SidebarCollapseThreshold = 0.5,
CompactWidthActivation = 128,
BackgroundImage = "",
Animations = {
ToggleWindow = true,
TabSwitch = true,
Groupbox = true,
Dropdown = true,
KeyPicker = true,
},
TabTransitionTime = 0.22,
TabSwipeOffset = 26,
TabSwipeFrom = "bottom",
TabButtonsStyle = {
Gap = 4,
Padding = 8,
CornerRadius = 8,
Indicator = true,
IndicatorWidth = 3,
IndicatorHeight = 18,
},
},
Groupbox = {
Side = 1,
Name = "Groupbox",
IconName = nil,
Description = nil,
Visible = true,
Collapsed = false,
DisableCollapsing = false,
PopOut = true,
MaxPopOutHeight = nil,
PopOutWidth = nil,
},
Tabbox = {
Side = 1,
Name = nil,
PopOut = true,
MaxPopOutHeight = nil,
PopOutWidth = nil,
},
Dialog = {
Title = "Dialog",
Description = "Description",
AutoDismiss = true,
OutsideClickDismiss = true,
FooterButtons = {}
},
Loading = {
Title = "mspaint",
Icon = 95816097006870,
IconSize = UDim2.fromOffset(30, 30),
LoadingIcon = CustomImageManager.GetAsset("LoadingIcon"),
LoadingIconColor = nil,
LoadingIconTweenTime = 1,
CurrentStep = 0,
TotalSteps = 10,
ShowSidebar = false,
AutoResizeHeight = false,
AlwaysOnTop = true,
WindowWidth = 450,
WindowHeight = 275,
ContentWidth = 450,
SidebarWidth = 250,
},
Toggle = {
Text = "Toggle",
Default = false,
Callback = function() end,
Changed = function() end,
Risky = false,
Disabled = false,
Visible = true,
},
Input = {
Text = "Input",
Default = "",
Finished = false,
Numeric = false,
ClearTextOnFocus = true,
ClearTextOnBlur = false,
Placeholder = "",
AllowEmpty = true,
EmptyReset = "---",
Callback = function() end,
Changed = function() end,
VerifyValue = nil,
Disabled = false,
Visible = true,
},
Slider = {
Text = "Slider",
Default = 0,
Min = 0,
Max = 100,
Rounding = 0,
Prefix = "",
Suffix = "",
Callback = function() end,
Changed = function() end,
Disabled = false,
Visible = true,
AllowRightClickInput = true
},
Dropdown = {
Values = {},
DisabledValues = {},
ValueImages = {},
Multi = false,
DragSelect = false,
MaxVisibleDropdownItems = 8,
KeepDisabledValuePosition = false,
Callback = function() end,
Changed = function() end,
Disabled = false,
Visible = true,
},
Viewport = {
Object = nil,
Camera = nil,
Clone = true,
AutoFocus = true,
Interactive = false,
Height = 200,
Visible = true,
},
Image = {
Image = "",
Transparency = 0,
BackgroundTransparency = 0,
Color = Color3.new(1, 1, 1),
RectOffset = Vector2.zero,
RectSize = Vector2.zero,
ScaleType = Enum.ScaleType.Fit,
Height = 200,
Visible = true,
},
Video = {
Video = "",
Looped = false,
Playing = false,
Volume = 1,
Height = 200,
Visible = true,
},
UIPassthrough = {
Instance = nil,
Height = 24,
Visible = true,
},
KeyPicker = {
Text = "KeyPicker",
Default = "None",
DefaultModifiers = {},
Blacklisted = {},
BlacklistedModifiers = {},
Whitelisted = {},
WhitelistedModifiers = {},
Mode = "Toggle",
Modes = { "Always", "Toggle", "Hold" },
SyncToggleState = false,
Callback = function() end,
ChangedCallback = function() end,
Changed = function() end,
Clicked = function() end,
},
ColorPicker = {
Default = Color3.new(1, 1, 1),
Resizable = true,
Callback = function() end,
Changed = function() end,
},
}
local Places = {
Bottom = { 0, 1 },
Right = { 1, 0 },
}
local Sizes = {
Left = { 0.5, 1 },
Right = { 0.5, 1 },
}
local SideIndex = {
left = 1,
right = 2,
}
local SchemeReplaceAlias = {
RedColor = "Red",
WhiteColor = "White",
DarkColor = "Dark"
}
local SchemeAlias = {
Red = "RedColor",
White = "WhiteColor",
Dark = "DarkColor"
}
local function GetSchemeValue(Index)
if not Index then
return nil
end
local ReplaceAliasIndex = SchemeReplaceAlias[Index]
if ReplaceAliasIndex and Library.Scheme[ReplaceAliasIndex] ~= nil then
Library.Scheme[Index] = Library.Scheme[ReplaceAliasIndex]
Library.Scheme[ReplaceAliasIndex] = nil
return Library.Scheme[Index]
end
local AliasIndex = SchemeAlias[Index]
if AliasIndex and Library.Scheme[AliasIndex] ~= nil then
warn(string.format("Scheme Value %q is deprecated, please use %q instead.", Index, AliasIndex))
return Library.Scheme[AliasIndex]
end
return Library.Scheme[Index]
end
local function WaitForEvent(Event, Timeout, Condition)
local Bindable = Instance.new("BindableEvent")
local Connection = Event:Once(function(...)
if not Condition or typeof(Condition) == "function" and Condition(...) then
Bindable:Fire(true)
else
Bindable:Fire(false)
end
end)
task.delay(Timeout, function()
Connection:Disconnect()
Bindable:Fire(false)
end)
local Result = Bindable.Event:Wait()
Bindable:Destroy()
return Result
end
local function IsMouseInput(Input: InputObject, IncludeM2: boolean?)
return Input.UserInputType == Enum.UserInputType.MouseButton1
or (IncludeM2 == true and Input.UserInputType == Enum.UserInputType.MouseButton2)
or Input.UserInputType == Enum.UserInputType.Touch
end
local function IsClickInput(Input: InputObject, IncludeM2: boolean?)
return IsMouseInput(Input, IncludeM2)
and Input.UserInputState == Enum.UserInputState.Begin
and Library.IsRobloxFocused
end
local function IsHoverInput(Input: InputObject)
return (Input.UserInputType == Enum.UserInputType.MouseMovement or Input.UserInputType == Enum.UserInputType.Touch)
and Input.UserInputState == Enum.UserInputState.Change
end
local function IsDragInput(Input: InputObject, IncludeM2: boolean?)
return IsMouseInput(Input, IncludeM2)
and (Input.UserInputState == Enum.UserInputState.Begin or Input.UserInputState == Enum.UserInputState.Change)
and Library.IsRobloxFocused
end
local function IsMouseClickInput(Input: InputObject)
return Input.UserInputType == Enum.UserInputType.MouseButton1 or
Input.UserInputType == Enum.UserInputType.MouseButton2 or
Input.UserInputType == Enum.UserInputType.MouseButton3
end
local function IsMovementInput(Input: InputObject)
return (Input.UserInputType == Enum.UserInputType.MouseMovement or Input.UserInputType == Enum.UserInputType.Touch)
and Library.IsRobloxFocused
end
local function GetTableSize(Table: { [any]: any })
local Size = 0
for _, _ in Table do
Size += 1
end
return Size
end
local function IsSequentialArray(Table: { [any]: any })
for Key in Table do
if typeof(Key) ~= "number" or Key < 1 or Key % 1 ~= 0 then
return false
end
end
return true
end
local function StopTween(Tween: TweenBase, Destroy: boolean?)
if not Tween then
return
end
if Tween.PlaybackState == Enum.PlaybackState.Playing then
Tween:Cancel()
end
if Destroy == true then
pcall(Tween.Destroy, Tween)
end
end
local function Trim(Text: string)
return Text:match("^%s*(.-)%s*$")
end
local function Round(Value, Rounding)
assert(Rounding >= 0, "Invalid rounding number.")
if Rounding == 0 then
return math.floor(Value)
end
return tonumber(string.format("%." .. Rounding .. "f", Value))
end
local function FuzzyScore(Text: string, Search: string): (boolean, number)
if Search == "" then
return true, 0
end
if Text == "" then
return false, 0
end
local ExactIdx = Text:find(Search, 1, true)
if ExactIdx then
local PrevChar = ExactIdx > 1 and Text:sub(ExactIdx - 1, ExactIdx - 1) or ""
local AtBoundary = ExactIdx == 1 or PrevChar:match("[%s%p_]") ~= nil
return true, 1e5 - ExactIdx + (AtBoundary and 500 or 0) + (Search:len() * 5)
end
local TextLen, SearchLen = Text:len(), Search:len()
if SearchLen > TextLen then
return false, 0
end
local SearchIdx = 1
local Score = 0
local RunLength = 0
local LastMatchIdx = 0
for TextIdx = 1, TextLen do
if SearchIdx > SearchLen then
break
end
if Text:sub(TextIdx, TextIdx) == Search:sub(SearchIdx, SearchIdx) then
local PrevChar = TextIdx > 1 and Text:sub(TextIdx - 1, TextIdx - 1) or ""
local AtBoundary = TextIdx == 1 or PrevChar:match("[%s%p_]") ~= nil
RunLength = (LastMatchIdx == TextIdx - 1) and (RunLength + 1) or 1
Score += 1 + (AtBoundary and 6 or 0) + math.min(RunLength - 1, 5) * 3
LastMatchIdx = TextIdx
SearchIdx += 1
end
end
if SearchIdx <= SearchLen then
return false, 0 --// Not every Search character was found, in order
end
Score -= (LastMatchIdx - SearchLen) * 0.05 --// Slightly favour tighter matches
return true, Score
end
local function NormalizeSearch(Search: string): string
return (Search:gsub("%s+", ""))
end
local function TryFuzzyMatch(Text: any, Search: string): (boolean, number)
if typeof(Text) ~= "string" or Text == "" then
return false, 0
end
return FuzzyScore(Text:lower(), Search)
end
local function FuzzyMatchScore(Text: any, Search: string): number
if typeof(Text) ~= "string" or Text == "" then
return 0
end
local Normalized = NormalizeSearch(Text:lower())
local Matched, Score = FuzzyScore(Normalized, Search)
if not Matched then
return 0
end
if Normalized == Search then
Score += 1000
end
return Score
end
local function MatchesSearch(ElementInfo, Search: string, ForceMatch: boolean?): boolean
if not ElementInfo then
return false
end
if ForceMatch then
return true
end
if TryFuzzyMatch(ElementInfo.Text, Search) then
return true
end
if TryFuzzyMatch(ElementInfo.Tooltip, Search) then
return true
end
if TryFuzzyMatch(ElementInfo.DisabledTooltip, Search) then
return true
end
if typeof(ElementInfo.Values) == "table" then
local Checked = 0
for Key, Value in ElementInfo.Values do
Checked += 1
if Checked > 200 then
break
end
if TryFuzzyMatch(Value, Search) or (typeof(Value) ~= "string" and TryFuzzyMatch(tostring(Value), Search)) then
return true
end
if typeof(Key) == "string" and TryFuzzyMatch(Key, Search) then
return true
end
end
end
return false
end
local function GetPlayers(ExcludeLocalPlayer: boolean?)
local PlayerList = Players:GetPlayers()
if ExcludeLocalPlayer then
local Idx = table.find(PlayerList, LocalPlayer)
if Idx then
table.remove(PlayerList, Idx)
end
end
table.sort(PlayerList, function(Player1, Player2)
return Player1.Name:lower() < Player2.Name:lower()
end)
return PlayerList
end
local function GetTeams()
local TeamList = Teams:GetTeams()
table.sort(TeamList, function(Team1, Team2)
return Team1.Name:lower() < Team2.Name:lower()
end)
return TeamList
end
function Library:UpdateDependencyBoxes()
for _, Depbox in Library.DependencyBoxes do
Depbox:Update(true)
end
if Library.Searching then
Library:UpdateSearch(Library.SearchText)
end
end
function Library:UpdateAddons(Parent)
if not Parent or not Parent.Addons then
return
end
for _, Addon in Parent.Addons do
Addon:Update()
end
end
local function CheckDepbox(Box, Search, ForceVisible: boolean?)
local VisibleElements = 0
local BestScore = 0
for _, ElementInfo in Box.Elements do
if ElementInfo.Type == "Divider" then
ElementInfo.Holder.Visible = false
continue
elseif ElementInfo.SubButton then
local Visible = false
if MatchesSearch(ElementInfo, Search, ForceVisible) and ElementInfo.Visible then
Visible = true
BestScore = math.max(BestScore, FuzzyMatchScore(ElementInfo.Text, Search))
else
ElementInfo.Base.Visible = false
end
if MatchesSearch(ElementInfo.SubButton, Search, ForceVisible) and ElementInfo.SubButton.Visible then
Visible = true
BestScore = math.max(BestScore, FuzzyMatchScore(ElementInfo.SubButton.Text, Search))
else
ElementInfo.SubButton.Base.Visible = false
end
ElementInfo.Holder.Visible = Visible
if Visible then
VisibleElements += 1
end
continue
end
if ElementInfo.Text and MatchesSearch(ElementInfo, Search, ForceVisible) and ElementInfo.Visible then
ElementInfo.Holder.Visible = true
VisibleElements += 1
BestScore = math.max(BestScore, FuzzyMatchScore(ElementInfo.Text, Search))
else
ElementInfo.Holder.Visible = false
end
end
for _, Depbox in Box.DependencyBoxes do
if not Depbox.Visible then
continue
end
local DepVisible, DepScore = CheckDepbox(Depbox, Search, ForceVisible)
VisibleElements += DepVisible
if DepScore > BestScore then
BestScore = DepScore
end
end
Box.Holder.Visible = VisibleElements > 0
return VisibleElements, BestScore
end
local function RestoreDepbox(Box)
for _, ElementInfo in Box.Elements do
ElementInfo.Holder.Visible = ElementInfo.Visible ~= false
if ElementInfo.SubButton then
ElementInfo.Base.Visible = ElementInfo.Visible
ElementInfo.SubButton.Base.Visible = ElementInfo.SubButton.Visible
end
end
Box:Resize()
Box.Holder.Visible = true
for _, Depbox in Box.DependencyBoxes do
if not Depbox.Visible then
continue
end
RestoreDepbox(Depbox)
end
end
function SyncPopOutVisibility(Box: any)
if not Box.PopOutFloat then
return
end
Box.PopOutFloat.Visible = Box.BoxHolder.Visible ~= false and Box.Visible ~= false
end
local function DimPopOutClone(Root: GuiObject)
for _, Descendant in Root:QueryDescendants("TextLabel, TextButton, TextBox") do
Descendant.TextTransparency = math.max(Descendant.TextTransparency, 0.45)
end
for _, Descendant in Root:QueryDescendants("ImageLabel, ImageButton") do
Descendant.ImageTransparency = math.max(Descendant.ImageTransparency, 0.45)
end
for _, Descendant in Root:QueryDescendants("GuiButton") do
Descendant.Active = false
Descendant.AutoButtonColor = false
end
end
local function IsScreenPointOutsideMain(Point: Vector2): boolean
local MainFrame = Library.Window and Library.Window.MainFrame
if not MainFrame or not Library.Toggled or not MainFrame.Visible then
return true
end
return not Library:MouseIsOverFrame(MainFrame, Point)
end
local function GetTopFloatAt(Point: Vector2): GuiObject?
local Best: GuiObject? = nil
local BestOrder = -math.huge
local Floats = Library.Floats
for _, Surface in Library.DraggableElements do
if not Surface or not Surface.Parent or not Surface.Visible then
continue
end
if Floats and Surface.Parent ~= Floats then
continue
end
if not Library:MouseIsOverFrame(Surface, Point) then
continue
end
local SiblingIndex = tonumber(select(2, pcall(function() return Surface:GetSiblingIndex() end))) or 0
local Order = Surface.ZIndex * 100000 + SiblingIndex
if Order >= BestOrder then
BestOrder = Order
Best = Surface
end
end
return Best
end
local function GetPopOutBodyMaxHeight(Box: any, Reserved: number): number
local Float = Box.PopOutFloat
local ScreenGui = Library.ScreenGui
if not Float or not ScreenGui then
return math.huge
end
local Gap = 12 * Library.DPIScale
local MaxBottom = ScreenGui.AbsolutePosition.Y + ScreenGui.AbsoluteSize.Y - Gap
local Available = math.min(MaxBottom - Float.AbsolutePosition.Y, ScreenGui.AbsoluteSize.Y * 0.9)
local ScreenMax = math.max(0, Available / Library.DPIScale - Reserved)
local CustomMax = Box.PopOutMaxHeight
if typeof(CustomMax) == "number" then
return math.min(ScreenMax, math.max(0, CustomMax))
end
return ScreenMax
end
local function ApplySearchToTab(Tab, Search)
if not Tab then
return false, 0
end
local HasVisible = false
local BestScore = 0
local TabMatches = TryFuzzyMatch(Tab.Name, Search) or TryFuzzyMatch(Tab.Description, Search)
BestScore = math.max(BestScore, FuzzyMatchScore(Tab.Name, Search), FuzzyMatchScore(Tab.Description, Search))
for _, Groupbox in Tab.Groupboxes do
if Groupbox.Visible == false then
continue
end
local GroupboxMatches = TabMatches or (TryFuzzyMatch(Groupbox.Name, Search) or TryFuzzyMatch(Groupbox.Description, Search))
BestScore = math.max(BestScore, FuzzyMatchScore(Groupbox.Name, Search), FuzzyMatchScore(Groupbox.Description, Search))
local VisibleElements = 0
for _, ElementInfo in Groupbox.Elements do
if ElementInfo.Type == "Divider" then
ElementInfo.Holder.Visible = false
continue
elseif ElementInfo.SubButton then
local Visible = false
if MatchesSearch(ElementInfo, Search, GroupboxMatches) and ElementInfo.Visible then
Visible = true
BestScore = math.max(BestScore, FuzzyMatchScore(ElementInfo.Text, Search))
else
ElementInfo.Base.Visible = false
end
if MatchesSearch(ElementInfo.SubButton, Search, GroupboxMatches) and ElementInfo.SubButton.Visible then
Visible = true
BestScore = math.max(BestScore, FuzzyMatchScore(ElementInfo.SubButton.Text, Search))
else
ElementInfo.SubButton.Base.Visible = false
end
ElementInfo.Holder.Visible = Visible
if Visible then
VisibleElements += 1
end
continue
end
if ElementInfo.Text and MatchesSearch(ElementInfo, Search, GroupboxMatches) and ElementInfo.Visible then
ElementInfo.Holder.Visible = true
VisibleElements += 1
BestScore = math.max(BestScore, FuzzyMatchScore(ElementInfo.Text, Search))
else
ElementInfo.Holder.Visible = false
end
end
for _, Depbox in Groupbox.DependencyBoxes do
if not Depbox.Visible then
continue
end
local DepVisible, DepScore = CheckDepbox(Depbox, Search, GroupboxMatches)
VisibleElements += DepVisible
if DepScore > BestScore then
BestScore = DepScore
end
end
if VisibleElements > 0 then
Groupbox:Resize()
HasVisible = true
end
Groupbox.BoxHolder.Visible = VisibleElements > 0
SyncPopOutVisibility(Groupbox)
end
for _, Tabbox in Tab.Tabboxes do
local VisibleTabs = 0
local VisibleElements = {}
local SubTabScores = {}
for _, SubTab in Tabbox.Tabs do
VisibleElements[SubTab] = 0
local SubTabMatches = TabMatches or TryFuzzyMatch(SubTab.Name, Search)
local SubScore = FuzzyMatchScore(SubTab.Name, Search)
BestScore = math.max(BestScore, SubScore)
for _, ElementInfo in SubTab.Elements do
if ElementInfo.Type == "Divider" then
ElementInfo.Holder.Visible = false
continue
elseif ElementInfo.SubButton then
local Visible = false
if MatchesSearch(ElementInfo, Search, SubTabMatches) and ElementInfo.Visible then
Visible = true
local ElementScore = FuzzyMatchScore(ElementInfo.Text, Search)
SubScore = math.max(SubScore, ElementScore)
BestScore = math.max(BestScore, ElementScore)
else
ElementInfo.Base.Visible = false
end
if MatchesSearch(ElementInfo.SubButton, Search, SubTabMatches) and ElementInfo.SubButton.Visible then
Visible = true
local ElementScore = FuzzyMatchScore(ElementInfo.SubButton.Text, Search)
SubScore = math.max(SubScore, ElementScore)
BestScore = math.max(BestScore, ElementScore)
else
ElementInfo.SubButton.Base.Visible = false
end
ElementInfo.Holder.Visible = Visible
if Visible then
VisibleElements[SubTab] += 1
end
continue
end
if ElementInfo.Text and MatchesSearch(ElementInfo, Search, SubTabMatches) and ElementInfo.Visible then
ElementInfo.Holder.Visible = true
VisibleElements[SubTab] += 1
local ElementScore = FuzzyMatchScore(ElementInfo.Text, Search)
SubScore = math.max(SubScore, ElementScore)
BestScore = math.max(BestScore, ElementScore)
else
ElementInfo.Holder.Visible = false
end
end
for _, Depbox in SubTab.DependencyBoxes do
if not Depbox.Visible then
continue
end
local DepVisible, DepScore = CheckDepbox(Depbox, Search, SubTabMatches)
VisibleElements[SubTab] += DepVisible
SubScore = math.max(SubScore, DepScore)
BestScore = math.max(BestScore, DepScore)
end
SubTabScores[SubTab] = SubScore
end
local BestSubTab = nil
local BestSubScore = -1
for SubTab, Visible in VisibleElements do
SubTab.ButtonHolder.Visible = Visible > 0
if Visible > 0 then
VisibleTabs += 1
HasVisible = true
local SubScore = SubTabScores[SubTab] or 0
if SubScore > BestSubScore then
BestSubScore = SubScore
BestSubTab = SubTab
end
end
end
local ActiveSubTab = Tabbox.ActiveTab
local ActiveSubVisible = ActiveSubTab and (VisibleElements[ActiveSubTab] or 0) > 0
local ActiveSubScore = ActiveSubTab and (SubTabScores[ActiveSubTab] or -1) or -1
if ActiveSubVisible and ActiveSubScore >= BestSubScore then
ActiveSubTab:Resize()
elseif BestSubTab then
BestSubTab:Show()
end
Tabbox.BoxHolder.Visible = VisibleTabs > 0
SyncPopOutVisibility(Tabbox)
end
return HasVisible, BestScore
end
local function ResetTab(Tab)
if not Tab then
return
end
for _, Groupbox in Tab.Groupboxes do
for _, ElementInfo in Groupbox.Elements do
ElementInfo.Holder.Visible = ElementInfo.Visible ~= false
if ElementInfo.SubButton then
ElementInfo.Base.Visible = ElementInfo.Visible
ElementInfo.SubButton.Base.Visible = ElementInfo.SubButton.Visible
end
end
for _, Depbox in Groupbox.DependencyBoxes do
if not Depbox.Visible then
continue
end
RestoreDepbox(Depbox)
end
Groupbox:Resize()
Groupbox.BoxHolder.Visible = Groupbox.Visible ~= false
SyncPopOutVisibility(Groupbox)
end
for _, Tabbox in Tab.Tabboxes do
for _, SubTab in Tabbox.Tabs do
for _, ElementInfo in SubTab.Elements do
ElementInfo.Holder.Visible = ElementInfo.Visible ~= false
if ElementInfo.SubButton then
ElementInfo.Base.Visible = ElementInfo.Visible
ElementInfo.SubButton.Base.Visible = ElementInfo.SubButton.Visible
end
end
for _, Depbox in SubTab.DependencyBoxes do
if not Depbox.Visible then
continue
end
RestoreDepbox(Depbox)
end
SubTab.ButtonHolder.Visible = true
end
if Tabbox.ActiveTab then
Tabbox.ActiveTab:Resize()
end
Tabbox.BoxHolder.Visible = true
SyncPopOutVisibility(Tabbox)
end
end
function Library:UpdateSearch(SearchText)
Library.SearchText = SearchText
local TabsToSearch = {}
for _, Tab in Library.Tabs do
if typeof(Tab) == "table" and not Tab.IsKeyTab then
table.insert(TabsToSearch, Tab)
end
end
for _, Tab in TabsToSearch do
ResetTab(Tab)
end
local Search = NormalizeSearch(SearchText:lower())
if Trim(Search) == "" then
Library.Searching = false
Library.LastSearchTab = nil
return
end
if not Library.GlobalSearch and Library.ActiveTab and Library.ActiveTab.IsKeyTab then
Library.Searching = false
Library.LastSearchTab = nil
return
end
Library.Searching = true
local BestTab = nil
local BestScore = -1
local ActiveScore = -1
local ActiveHasVisible = false
for _, Tab in TabsToSearch do
local HasVisible, Score = ApplySearchToTab(Tab, Search)
if not HasVisible then
continue
end
if Tab == Library.ActiveTab then
ActiveHasVisible = true
ActiveScore = Score
end
if Score > BestScore then
BestScore = Score
BestTab = Tab
end
end
if not Library.GlobalSearch then
for _, Tab in TabsToSearch do
if Tab ~= BestTab then
ResetTab(Tab)
end
end
end
local StayOnActive = ActiveHasVisible and ActiveScore >= BestScore
if StayOnActive and Library.ActiveTab then
Library.ActiveTab:RefreshSides()
elseif BestTab then
local SearchMarker = SearchText
task.defer(function()
if Library.SearchText ~= SearchMarker then
return
end
if Library.ActiveTab ~= BestTab then
BestTab:Show()
elseif Library.ActiveTab then
Library.ActiveTab:RefreshSides()
end
end)
end
Library.LastSearchTab = nil
end
function Library:AddToRegistry(Instance, Properties)
Library.Registry[Instance] = Properties
end
function Library:RemoveFromRegistry(Instance)
Library.Registry[Instance] = nil
end
function Library:UpdateColorsUsingRegistry()
for Instance, Properties in Library.Registry do
for Property, Index in Properties do
local SchemeValue = GetSchemeValue(Index)
if SchemeValue or typeof(Index) == "function" then
Instance[Property] = SchemeValue or Index()
end
end
end
end
function Library:SetDPIScale(DPIScale: number)
Library.DPIScale = DPIScale / 100
Library.MinSize = Library.OriginalMinSize * Library.DPIScale
for _, UIScale in Library.Scales do
UIScale.Scale = Library.DPIScale - (tonumber(Library.ScalesOffset[UIScale]) or 0)
end
for _, Option in Options do
if Option.Type == "Dropdown" then
Option:RecalculateListSize()
Option:RefreshPool()
end
end
for _, Notification in Library.Notifications do
Notification:Resize()
end
end
function Library:GiveSignal(Connection: RBXScriptConnection | RBXScriptSignal)
local ConnectionType = typeof(Connection)
if Connection and (ConnectionType == "RBXScriptConnection" or ConnectionType == "RBXScriptSignal") then
table.insert(Library.Signals, Connection)
end
return Connection
end
function IsValidCustomIcon(Icon: string)
return typeof(Icon) == "string" and (Icon:match("^rbxasset://textures/") or Icon:match("roblox%.com/asset/%?id=") or Icon:match("rbxthumb://type="))
end
local function IsCustomAssetIcon(Icon: string, IncludeAssetId: boolean)
return typeof(Icon) == "string" and (Icon:match("^content://") or (Icon:match("^rbxasset://%x+/") or Icon:match("^rbxasset://[^/]+/")) or (IncludeAssetId == true and Icon:match("^rbxassetid://")))
end
type Icon = {
Url: string,
Id: number,
IconName: string,
ImageRectOffset: Vector2,
ImageRectSize: Vector2,
}
type IconModule = {
Icons: { string },
GetAsset: (Name: string) -> Icon?,
}
local FetchIcons = false
local Icons: IconModule | nil = nil
function Library:GetIcon(IconName: string)
if not FetchIcons or not Icons then
return
end
local Success, Icon = pcall(Icons.GetAsset, IconName)
if not Success then
return
end
return Icon
end
function Library:GetCustomIcon(IconName: string): any
if not IconName then
return nil
end
if tonumber(IconName) then
IconName = string.format("rbxassetid://%s", tostring(IconName))
end
if IsCustomAssetIcon(IconName, true) then
return {
Url = IconName,
ImageRectOffset = Vector2.zero,
ImageRectSize = Vector2.zero,
}
elseif IsValidCustomIcon(IconName) then
return {
Url = IconName,
ImageRectOffset = Vector2.zero,
ImageRectSize = Vector2.zero,
Custom = true,
}
end
local LucideIcon = Library:GetIcon(IconName)
if LucideIcon then
return LucideIcon
end
return nil
end
function Library:ApplyLucideIcon(ImageGui: any, Icon: any, Rotation: number?)
if not ImageGui or not Icon then
return
end
if not (ImageGui:IsA("ImageLabel") or ImageGui:IsA("ImageButton")) then
return
end
ImageGui.Image = Icon.Url or ImageGui.Image
ImageGui.ImageRectOffset = Icon.ImageRectOffset or ImageGui.ImageRectOffset
ImageGui.ImageRectSize = Icon.ImageRectSize or ImageGui.ImageRectSize
ImageGui.Rotation = Rotation or ImageGui.Rotation
end
function Library:Validate(Table: { [string]: any }, Template: { [string]: any }): { [string]: any }
if typeof(Table) ~= "table" then
return Template
end
for k, v in Template do
if typeof(k) == "number" then
continue
end
if typeof(v) == "table" then
Table[k] = Library:Validate(Table[k], v)
elseif Table[k] == nil then
Table[k] = v
end
end
return Table
end
local function FillInstance(Table: { [string]: any }, Instance: GuiObject)
local ThemeProperties = Library.Registry[Instance] or {}
for key, value in Table do
if key ~= "Text" then
local SchemeValue = GetSchemeValue(value)
if SchemeValue or typeof(value) == "function" then
ThemeProperties[key] = value
value = SchemeValue or value()
else
ThemeProperties[key] = nil
end
end
Instance[key] = value
end
if GetTableSize(ThemeProperties) > 0 then
Library.Registry[Instance] = ThemeProperties
end
end
local function New(ClassName: string, Properties: { [string]: any }): any
local Instance = Instance.new(ClassName)
if Templates[ClassName] then
FillInstance(Templates[ClassName], Instance)
end
FillInstance(Properties, Instance)
if Properties["Parent"] and not Properties["ZIndex"] then
pcall(function()
Instance.ZIndex = Properties.Parent.ZIndex
end)
end
return Instance
end
local function SafeParentUI(Instance: Instance, Parent: Instance | () -> Instance)
local success, _error = pcall(function()
if not Parent then
Parent = CoreGui
end
local DestinationParent
if typeof(Parent) == "function" then
DestinationParent = Parent()
else
DestinationParent = Parent
end
Instance.Parent = DestinationParent
end)
if not (success and Instance.Parent) then
local PlayerGui = Library.LocalPlayer:WaitForChild("PlayerGui", 15)
assert(PlayerGui, "Slopix: PlayerGui is still loading; run the script again")
Instance.Parent = PlayerGui
end
end
local function ParentUI(UI: Instance, SkipHiddenUI: boolean?)
if SkipHiddenUI then
SafeParentUI(UI, CoreGui)
return
end
pcall(protectgui, UI)
SafeParentUI(UI, gethui)
end
local function SetAlwaysOnTop(Gui: ScreenGui, Enabled: boolean)
if not Gui then
return
end
pcall(function()
if sethiddenproperty then
sethiddenproperty(Gui, "OnTopOfCoreBlur", Enabled)
elseif setscriptable then
setscriptable(Gui, "OnTopOfCoreBlur", true)
Gui.OnTopOfCoreBlur = Enabled
setscriptable(Gui, "OnTopOfCoreBlur", false)
end
end)
end
local ScreenGui = New("ScreenGui", {
Name = "Obsidian",
DisplayOrder = 998,
ResetOnSpawn = false,
ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
ParentUI(ScreenGui)
Library.ScreenGui = ScreenGui
ScreenGui.DescendantRemoving:Connect(function(Instance)
task.defer(function()
if Instance.Parent and Instance:IsDescendantOf(ScreenGui) then
return
end
Library:RemoveFromRegistry(Instance)
end)
end)
local ModalElement = New("TextButton", {
BackgroundTransparency = 1,
Modal = false,
Size = UDim2.fromScale(0, 0),
AnchorPoint = Vector2.zero,
Text = "",
ZIndex = -999,
Parent = ScreenGui,
})
local Floats = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 1),
ZIndex = 10,
Active = false,
Parent = ScreenGui,
})
local Overlay = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 1),
ZIndex = 20,
Active = false,
Parent = ScreenGui,
})
Library.Floats = Floats
Library.Overlay = Overlay
local Cursor
local CursorCross
local InnerCross = {}
local CursorCustomImage
do
Cursor = New("Frame", {
AnchorPoint = Vector2.new(0.5, 0.5),
BackgroundTransparency = 1,
Size = UDim2.fromOffset(1, 1),
Visible = false,
ZIndex = 11000,
Parent = ScreenGui,
})
CursorCross = New("Frame", {
AnchorPoint = Vector2.new(0.5, 0.5),
BackgroundTransparency = 1,
Position = UDim2.fromScale(0.5, 0.5),
Size = UDim2.fromOffset(11, 11),
Parent = Cursor,
})
New("Frame", {
AnchorPoint = Vector2.new(0.5, 0.5),
BackgroundColor3 = "DarkColor",
Position = UDim2.fromScale(0.5, 0.5),
Size = UDim2.new(1, 0, 0, 3),
ZIndex = 1,
Parent = CursorCross,
})
table.insert(InnerCross, New("Frame", {
AnchorPoint = Vector2.new(0.5, 0.5),
BackgroundColor3 = "WhiteColor",
Position = UDim2.fromScale(0.5, 0.5),
Size = UDim2.new(1, -2, 0, 1),
ZIndex = 2,
Parent = CursorCross,
}))
New("Frame", {
AnchorPoint = Vector2.new(0.5, 0.5),
BackgroundColor3 = "DarkColor",
Position = UDim2.fromScale(0.5, 0.5),
Size = UDim2.new(0, 3, 1, 0),
ZIndex = 1,
Parent = CursorCross,
})
table.insert(InnerCross, New("Frame", {
AnchorPoint = Vector2.new(0.5, 0.5),
BackgroundColor3 = "WhiteColor",
Position = UDim2.fromScale(0.5, 0.5),
Size = UDim2.new(0, 1, 1, -2),
ZIndex = 2,
Parent = CursorCross,
}))
CursorCustomImage = New("ImageLabel", {
AnchorPoint = Vector2.new(0.5, 0.5),
BackgroundTransparency = 1,
Position = UDim2.fromScale(0.5, 0.5),
Size = UDim2.fromOffset(20, 20),
ZIndex = 3,
Visible = false,
Parent = Cursor,
})
end
local function RestoreMouseIcon()
pcall(function()
RunService:UnbindFromRenderStep(Library.ShowCursorBinding)
RunService.RenderStepped:Wait()
end)
UserInputService.MouseIconEnabled = Library.OriginalMouseIconEnabled
if Cursor then Cursor.Visible = false end
end
local NotificationArea
local NotifyOrder = {}
do
NotificationArea = New("Frame", {
AnchorPoint = Vector2.new(1, 0),
BackgroundTransparency = 1,
Position = UDim2.new(1, -6, 0, 6),
Size = UDim2.new(0, 300, 1, -6),
ZIndex = 200,
Parent = ScreenGui,
})
table.insert(
Library.Scales,
New("UIScale", {
Parent = NotificationArea,
})
)
end
local CheckIcon, ArrowIcon, ResizeIcon, KeyIcon, MoveIcon, PopOutIcon, CloseIcon
function Library:SetIconModule(module: IconModule)
FetchIcons = true
Icons = module
CheckIcon = Library:GetIcon("check")
ArrowIcon = Library:GetIcon("chevron-up")
ResizeIcon = Library:GetIcon("move-diagonal-2")
KeyIcon = Library:GetIcon("key")
MoveIcon = Library:GetIcon("move")
PopOutIcon = Library:GetIcon("square-arrow-down-left")
CloseIcon = Library:GetIcon("x")
end
-- Icons are optional. A blocked HTTP call must not prevent the hub window from opening.
task.defer(function()
if Icons or Library.Unloaded then return end
local OnlineFetchIcons, OnlineIcons = pcall(function()
local Source = game:HttpGet("https://raw.githubusercontent.com/mstudio45/lucide-roblox-direct/refs/heads/main/source.lua")
local Compile = type(loadstring) == "function" and loadstring(Source)
return Compile and Compile()
end)
if not Icons and not Library.Unloaded and OnlineFetchIcons and type(OnlineIcons) == "table" then
pcall(Library.SetIconModule, Library, OnlineIcons)
end
end)
Library.Cursor = {}
function Library.Cursor:ResetCross()
for _, Inner in InnerCross do
Library.Registry[Inner].BackgroundColor3 = "WhiteColor"
Inner.BackgroundColor3 = Library.Scheme.WhiteColor
end
end
function Library.Cursor:ResetIcon()
CursorCross.Visible = true
CursorCustomImage.Visible = false
CursorCustomImage.ImageColor3 = Color3.new(1, 1, 1)
CursorCustomImage.Size = UDim2.fromOffset(20, 20)
end
function Library.Cursor:ResetCursor()
Library.Cursor:ResetCross()
Library.Cursor:ResetIcon()
end
function Library.Cursor:ChangeCrossColor(Color: Color3)
assert(typeof(Color) == "Color3", "Color3 expected.")
for _, Inner in InnerCross do
Inner.BackgroundColor3 = Color
Library.Registry[Inner].BackgroundColor3 = nil
end
end
function Library.Cursor:ChangeIcon(ImageId: string)
if not ImageId or ImageId == "" then
Library.Cursor:ResetIcon()
return
end
local Icon = Library:GetCustomIcon(ImageId)
assert(Icon, "Image must be a valid Roblox asset or a valid URL or a valid lucide icon.")
CursorCross.Visible = false
CursorCustomImage.Visible = true
Library:ApplyLucideIcon(CursorCustomImage, Icon)
end
function Library.Cursor:ChangeIconColor(Color: Color3)
assert(typeof(Color) == "Color3", "Color3 expected.")
CursorCustomImage.ImageColor3 = Color
end
function Library.Cursor:ChangeIconSize(Size: UDim2)
assert(typeof(Size) == "UDim2", "UDim2 expected.")
CursorCustomImage.Size = Size
end
function Library:ChangeCursorCrossColor(Color: Color3)
warn("Obsidian:ChangeCursorCrossColor is deprecated, please use Obsidian.Cursor:ChangeCrossColor instead.")
Library.Cursor:ChangeCrossColor(Color)
end
function Library:ResetCursorCross()
warn("Obsidian:ResetCursorCross is deprecated, please use Obsidian.Cursor:ResetCross instead.")
Library.Cursor:ResetCross()
end
function Library:ChangeCursorIcon(ImageId: string)
warn("Obsidian:ChangeCursorIcon is deprecated, please use Obsidian.Cursor:ChangeIcon instead.")
Library.Cursor:ChangeIcon(ImageId)
end
function Library:ChangeCursorIconColor(Color: Color3)
warn("Obsidian:ChangeCursorIconColor is deprecated, please use Obsidian.Cursor:ChangeIconColor instead.")
Library.Cursor:ChangeIconColor(Color)
end
function Library:ChangeCursorIconSize(Size: UDim2)
warn("Obsidian:ChangeCursorIconSize is deprecated, please use Obsidian.Cursor:ChangeIconSize instead.")
Library.Cursor:ChangeIconSize(Size)
end
function Library:ResetCursorIcon()
warn("Obsidian:ResetCursorIcon is deprecated, please use Obsidian.Cursor:ResetIcon instead.")
Library.Cursor:ResetIcon()
end
function Library:GetBetterColor(Color: Color3, Add: number): Color3
Add = Add * (Library.IsLightTheme and -4 or 2)
return Color3.fromRGB(
math.clamp(Color.R * 255 + Add, 0, 255),
math.clamp(Color.G * 255 + Add, 0, 255),
math.clamp(Color.B * 255 + Add, 0, 255)
)
end
function Library:GetAccentSequence(): ColorSequence
local H, S, V = Library.Scheme.AccentColor:ToHSV()
return ColorSequence.new(Library.Scheme.AccentColor, Color3.fromHSV((H + 0.07) % 1, S, V))
end
function Library:AddAccentLine(Line: Frame, FadeOut: boolean?)
Library.Registry[Line].BackgroundColor3 = "WhiteColor"
Line.BackgroundColor3 = Library.Scheme.WhiteColor
return New("UIGradient", {
Color = function()
if FadeOut then
return ColorSequence.new(Library.Scheme.AccentColor, Library.Scheme.OutlineColor)
end
return Library:GetAccentSequence()
end,
Transparency = FadeOut and NumberSequence.new(0) or NumberSequence.new({
NumberSequenceKeypoint.new(0, 0),
NumberSequenceKeypoint.new(0.65, 0.45),
NumberSequenceKeypoint.new(1, 1),
}),
Parent = Line,
})
end
function Library:MakeBadge(Parent: GuiObject, Size: number, Icon: any?, Text: string?)
local Holder = New("Frame", {
BackgroundColor3 = "WhiteColor",
Size = UDim2.fromOffset(Size, Size),
Parent = Parent,
})
New("UICorner", {
CornerRadius = UDim.new(0, math.floor(Size * 0.28)),
Parent = Holder,
})
New("UIGradient", {
Color = function()
return Library:GetAccentSequence()
end,
Rotation = 45,
Parent = Holder,
})
local Glyph
local ParsedIcon = Icon and Library:GetCustomIcon(Icon)
if ParsedIcon then
Glyph = New("ImageLabel", {
AnchorPoint = Vector2.new(0.5, 0.5),
ImageColor3 = "WhiteColor",
Position = UDim2.fromScale(0.5, 0.5),
Size = UDim2.fromScale(0.58, 0.58),
Parent = Holder,
})
Library:ApplyLucideIcon(Glyph, ParsedIcon)
else
Glyph = New("TextLabel", {
BackgroundTransparency = 1,
FontFace = function()
return Font.new(Library.Scheme.Font.Family, Enum.FontWeight.Bold)
end,
Size = UDim2.fromScale(1, 1),
Text = string.upper(string.sub(tostring(Text or "?"), 1, 1)),
TextColor3 = "WhiteColor",
TextSize = math.floor(Size * 0.56),
Parent = Holder,
})
end
return { Holder = Holder, Glyph = Glyph }
end
function Library:GetLighterColor(Color: Color3): Color3
local H, S, V = Color:ToHSV()
return Color3.fromHSV(H, math.max(0, S - 0.1), math.min(1, V + 0.1))
end
function Library:GetDarkerColor(Color: Color3): Color3
local H, S, V = Color:ToHSV()
return Color3.fromHSV(H, S, V / 2)
end
function Library:GetKeyString(KeyCode: Enum.KeyCode)
if KeyCode.EnumType == Enum.KeyCode and KeyCode.Value > 33 and KeyCode.Value < 127 then
return string.char(KeyCode.Value)
end
return KeyCode.Name
end
function Library:GetTextBounds(Text: string, Font: Font, Size: number, Width: number?): (number, number)
local Scale = Library.DPIScale
local Params = Instance.new("GetTextBoundsParams")
Params.Text = Text
Params.RichText = true
Params.Font = Font
Params.Size = Size * Scale
if Width then
Params.Width = Width * Scale
else
Params.Width = workspace.CurrentCamera.ViewportSize.X - 32
end
local Bounds = TextService:GetTextBoundsAsync(Params)
return math.ceil(Bounds.X / Scale), math.ceil(Bounds.Y / Scale)
end
function Library:MouseIsOverFrame(Frame: GuiObject, Mouse: Vector2): boolean
local AbsPos, AbsSize = Frame.AbsolutePosition, Frame.AbsoluteSize
return Mouse.X >= AbsPos.X
and Mouse.X <= AbsPos.X + AbsSize.X
and Mouse.Y >= AbsPos.Y
and Mouse.Y <= AbsPos.Y + AbsSize.Y
end
function Library:IsInsideFrame(ParentFrame: GuiObject, Frame: GuiObject)
local GuiPos = Frame.AbsolutePosition
local GuiSize = Frame.AbsoluteSize
local FramePos = ParentFrame.AbsolutePosition
local FrameSize = ParentFrame.AbsoluteSize
return GuiPos.X >= FramePos.X
and GuiPos.X + GuiSize.X <= FramePos.X + FrameSize.X
and GuiPos.Y >= FramePos.Y
and GuiPos.Y + GuiSize.Y <= FramePos.Y + FrameSize.Y
end
function Library:SafeCallback(Func: (...any) -> ...any, ...: any)
if not (Func and typeof(Func) == "function") then
return
end
local Result = table.pack(xpcall(Func, function(Error)
task.defer(error, debug.traceback(Error, 2))
if Library.NotifyOnError and Library.Notify then
Library:Notify(Error)
end
return Error
end, ...))
Elevate()
if not Result[1] then
return nil
end
return table.unpack(Result, 2, Result.n)
end
function GetOverlappingDraggable(UI: GuiObject, TargetPos: Vector2?)
local Pos1 = TargetPos or UI.AbsolutePosition
local Size1 = UI.AbsoluteSize
for _, Other in ipairs(Library.DraggableElements) do
if Other == UI or not Other.Visible or not Other.Parent then
continue
end
local Pos2 = Other.AbsolutePosition
local Size2 = Other.AbsoluteSize
if Pos1.X < Pos2.X + Size2.X and
Pos1.X + Size1.X > Pos2.X and
Pos1.Y < Pos2.Y + Size2.Y and
Pos1.Y + Size1.Y > Pos2.Y then
return Other
end
end
return nil
end
function GetNonOverlappingPosition(UI: GuiObject, StartPos: UDim2?)
local ScreenSize = (workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)) - Vector2.new(100, 100)
local Start = StartPos and Vector2.new(StartPos.X.Offset, StartPos.Y.Offset) or Vector2.new(6, 6)
local Padding = 6
local CurrentX = Start.X
local CurrentY = Start.Y
local Size = UI.AbsoluteSize
if Size.X == 0 and Size.Y == 0 then
RunService.RenderStepped:Wait()
Size = UI.AbsoluteSize
end
if Size.X == 0 then Size = Vector2.new(150, 40) end
local MaxXInColumn = Size.X
while true do
local Obstacle = GetOverlappingDraggable(UI, Vector2.new(CurrentX, CurrentY))
if not Obstacle then
break
end
if Obstacle.AbsoluteSize.X > MaxXInColumn then
MaxXInColumn = Obstacle.AbsoluteSize.X
end
local NextY = Obstacle.AbsolutePosition.Y + Obstacle.AbsoluteSize.Y + Padding
if NextY + Size.Y > ScreenSize.Y - Padding then
local NextX = CurrentX + MaxXInColumn + Padding
if NextX + Size.X > ScreenSize.X - Padding then
break
end
CurrentY = Start.Y
CurrentX = NextX
MaxXInColumn = Size.X
else
CurrentY = NextY
end
end
return UDim2.fromOffset(CurrentX, CurrentY)
end
function PositionDraggable(UI: GuiObject, StartPos: UDim2?)
UI.Position = GetNonOverlappingPosition(UI, StartPos)
end
local function GetCoreGuiInset(): (Vector2, Vector2)
local Success, TopLeft, BottomRight = pcall(function()
return GuiService:GetGuiInset()
end)
if Success and TopLeft and BottomRight then
return TopLeft, BottomRight
end
return Vector2.zero, Vector2.zero
end
local function GetSnapEdges(ElemSize: Vector2, ViewportSize: Vector2, Margin: number, AvoidCoreGui: boolean)
local SafeMin, SafeMax = Vector2.zero, ViewportSize
if AvoidCoreGui then
local TopLeftInset, BottomRightInset = GetCoreGuiInset()
SafeMin = TopLeftInset
SafeMax = ViewportSize - BottomRightInset
end
local TargetsX = {
LeftEdge = SafeMin.X + Margin,
Center = SafeMin.X + (SafeMax.X - SafeMin.X - ElemSize.X) / 2,
RightEdge = SafeMax.X - ElemSize.X - Margin,
}
local TargetsY = {
TopEdge = SafeMin.Y + Margin,
Center = SafeMin.Y + (SafeMax.Y - SafeMin.Y - ElemSize.Y) / 2,
BottomEdge = SafeMax.Y - ElemSize.Y - Margin,
}
return TargetsX, TargetsY
end
local function GetClosestSnapTarget(Value: number, Targets: { [string]: number }, Distance: number): (number?, string?)
local ClosestName, ClosestValue, ClosestDist = nil, nil, Distance
for Name, Target in Targets do
local Dist = math.abs(Value - Target)
if Dist <= ClosestDist then
ClosestDist = Dist
ClosestName = Name
ClosestValue = Target
end
end
return ClosestValue, ClosestName
end
local function GetSnapGuideOffset(Name: string, SnappedValue: number, ElemDimension: number): number
if Name == "RightEdge" or Name == "BottomEdge" then
return SnappedValue + ElemDimension
elseif Name == "Center" then
return SnappedValue + ElemDimension / 2
end
return SnappedValue -- LeftEdge / TopEdge
end
function Library:MakeDraggable(
UI: GuiObject,
DragFrame: GuiObject,
IgnoreToggled: boolean?,
IsMainWindow: boolean?,
SnapConfig: { Enabled: boolean, Distance: number?, Margin: number?, AvoidCoreGui: boolean? }?
)
local StartPos
local FramePos
local Dragging = false
local Changed
local InputBegan
local InputChanged
local SnapGuideX, SnapGuideY
local function GetSnapGuides()
if not SnapGuideX then
SnapGuideX = New("Frame", {
BackgroundColor3 = "AccentColor",
BackgroundTransparency = 0.25,
BorderSizePixel = 0,
AnchorPoint = Vector2.new(0.5, 0),
Size = UDim2.new(0, 2, 1, 0),
Visible = false,
ZIndex = 10000,
Parent = ScreenGui,
})
end
if not SnapGuideY then
SnapGuideY = New("Frame", {
BackgroundColor3 = "AccentColor",
BackgroundTransparency = 0.25,
BorderSizePixel = 0,
AnchorPoint = Vector2.new(0, 0.5),
Size = UDim2.new(1, 0, 0, 2),
Visible = false,
ZIndex = 10000,
Parent = ScreenGui,
})
end
return SnapGuideX, SnapGuideY
end
local function HideSnapGuides()
if SnapGuideX then
SnapGuideX.Visible = false
end
if SnapGuideY then
SnapGuideY.Visible = false
end
end
InputBegan = DragFrame.InputBegan:Connect(function(Input: InputObject)
if not IsClickInput(Input) or IsMainWindow and Library.CantDragForced then
return
end
StartPos = Input.Position
FramePos = UI.Position
Dragging = true
Changed = Input.Changed:Connect(function()
if Input.UserInputState ~= Enum.UserInputState.End then
return
end
Dragging = false
HideSnapGuides()
if Changed and Changed.Connected then
Changed:Disconnect()
Changed = nil
end
end)
end)
InputChanged = UserInputService.InputChanged:Connect(function(Input: InputObject)
if
(not IgnoreToggled and not Library.Toggled)
or (IsMainWindow and Library.CantDragForced)
or not (ScreenGui and ScreenGui.Parent)
then
Dragging = false
HideSnapGuides()
if Changed and Changed.Connected then
Changed:Disconnect()
Changed = nil
end
return
end
if Dragging and IsHoverInput(Input) then
local Delta = Input.Position - StartPos
local NewX = FramePos.X.Offset + Delta.X
local NewY = FramePos.Y.Offset + Delta.Y
if SnapConfig and SnapConfig.Enabled then
local ViewportSize = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
local Distance = SnapConfig.Distance or 28
local Margin = SnapConfig.Margin or 8
local AbsX = FramePos.X.Scale * ViewportSize.X + NewX
local AbsY = FramePos.Y.Scale * ViewportSize.Y + NewY
local ElemSize = UI.AbsoluteSize
local TargetsX, TargetsY = GetSnapEdges(ElemSize, ViewportSize, Margin, SnapConfig.AvoidCoreGui ~= false)
local SnappedX, SnappedXName = GetClosestSnapTarget(AbsX, TargetsX, Distance)
local SnappedY, SnappedYName = GetClosestSnapTarget(AbsY, TargetsY, Distance)
if SnappedX then
NewX = SnappedX - FramePos.X.Scale * ViewportSize.X
end
if SnappedY then
NewY = SnappedY - FramePos.Y.Scale * ViewportSize.Y
end
local GuideX, GuideY = GetSnapGuides()
GuideX.Visible = SnappedX ~= nil
if SnappedX then
GuideX.Position = UDim2.fromOffset(GetSnapGuideOffset(SnappedXName, SnappedX, ElemSize.X), 0)
end
GuideY.Visible = SnappedY ~= nil
if SnappedY then
GuideY.Position = UDim2.fromOffset(0, GetSnapGuideOffset(SnappedYName, SnappedY, ElemSize.Y))
end
end
UI.Position = UDim2.new(FramePos.X.Scale, NewX, FramePos.Y.Scale, NewY)
end
end)
Library:GiveSignal(InputChanged)
Library:GiveSignal(InputBegan)
UI.Destroying:Once(function()
if InputChanged and InputChanged.Connected then
InputChanged:Disconnect()
end
if InputBegan and InputBegan.Connected then
InputBegan:Disconnect()
end
if Changed and Changed.Connected then
Changed:Disconnect()
end
if SnapGuideX then
SnapGuideX:Destroy()
end
if SnapGuideY then
SnapGuideY:Destroy()
end
local IdxChanged = table.find(Library.Signals, InputChanged)
if IdxChanged then
table.remove(Library.Signals, IdxChanged)
end
local IdxBegan = table.find(Library.Signals, InputBegan)
if IdxBegan then
table.remove(Library.Signals, IdxBegan)
end
end)
end
function Library:MakeResizable(UI: GuiObject, DragFrame: GuiObject, Callback: () -> ()?)
local StartPos
local FrameSize
local Dragging = false
local Changed
local InputBegan
local InputChanged
InputBegan = DragFrame.InputBegan:Connect(function(Input: InputObject)
if not IsClickInput(Input) then
return
end
StartPos = Input.Position
FrameSize = UI.Size
Dragging = true
Changed = Input.Changed:Connect(function()
if Input.UserInputState ~= Enum.UserInputState.End then
return
end
Dragging = false
if Changed and Changed.Connected then
Changed:Disconnect()
Changed = nil
end
end)
end)
InputChanged = UserInputService.InputChanged:Connect(function(Input: InputObject)
if not UI.Visible or not (ScreenGui and ScreenGui.Parent) then
Dragging = false
if Changed and Changed.Connected then
Changed:Disconnect()
Changed = nil
end
return
end
if Dragging and IsHoverInput(Input) then
local Delta = Input.Position - StartPos
UI.Size = UDim2.new(
FrameSize.X.Scale,
math.clamp(FrameSize.X.Offset + Delta.X, Library.MinSize.X, math.huge),
FrameSize.Y.Scale,
math.clamp(FrameSize.Y.Offset + Delta.Y, Library.MinSize.Y, math.huge)
)
if Callback then
Library:SafeCallback(Callback)
end
end
end)
Library:GiveSignal(InputChanged)
Library:GiveSignal(InputBegan)
UI.Destroying:Once(function()
if InputChanged and InputChanged.Connected then
InputChanged:Disconnect()
end
if InputBegan and InputBegan.Connected then
InputBegan:Disconnect()
end
if Changed and Changed.Connected then
Changed:Disconnect()
end
local IdxChanged = table.find(Library.Signals, InputChanged)
if IdxChanged then
table.remove(Library.Signals, IdxChanged)
end
local IdxBegan = table.find(Library.Signals, InputBegan)
if IdxBegan then
table.remove(Library.Signals, IdxBegan)
end
end)
end
function Library:MakeCover(Holder: GuiObject, Place: string)
local Pos = Places[Place] or { 0, 0 }
local Size = Sizes[Place] or { 1, 0.5 }
local Cover = New("Frame", {
AnchorPoint = Vector2.new(Pos[1], Pos[2]),
BackgroundColor3 = Holder.BackgroundColor3,
Position = UDim2.fromScale(Pos[1], Pos[2]),
Size = UDim2.fromScale(Size[1], Size[2]),
Parent = Holder,
})
return Cover
end
function Library:MakeLine(Frame: GuiObject, Info)
local Line = New("Frame", {
AnchorPoint = Info.AnchorPoint or Vector2.zero,
BackgroundColor3 = "OutlineColor",
LayoutOrder = Info.LayoutOrder or 0,
Position = Info.Position,
Size = Info.Size,
ZIndex = Info.ZIndex or Frame.ZIndex,
Parent = Frame,
})
return Line
end
function Library:AddOutline(Frame: GuiObject)
local OutlineStroke = New("UIStroke", {
Color = "OutlineColor",
Thickness = 1,
ZIndex = 2,
Parent = Frame,
})
local ShadowStroke = New("UIStroke", {
Color = "DarkColor",
Thickness = 1.5,
ZIndex = 1,
Parent = Frame,
})
return OutlineStroke, ShadowStroke
end
function Library:AddBlank(Frame: GuiObject, Size: UDim2)
return New("Frame", {
BackgroundTransparency = 1,
Size = Size or UDim2.fromScale(0, 0),
Parent = Frame,
})
end
local TransparencyCache = {}
local ActiveTabTweens = setmetatable({}, { __mode = "k" })
function Library:PlayTabAnimation(Tab, Showing: boolean, OnComplete: (() -> ())?)
if type(Tab) ~= "table" or not Tab.Container then
if OnComplete then
OnComplete()
end
return
end
local TabContainer = Tab.Container :: Frame
local Existing = ActiveTabTweens[TabContainer]
if Existing then
StopTween(Existing, true)
ActiveTabTweens[TabContainer] = nil
end
local BaseZIndex = TabContainer.ZIndex
if not (Library.Animations and Library.Animations.TabSwitch) then
TabContainer.Visible = Showing
TabContainer.Position = UDim2.fromScale(0, 0)
TabContainer.ZIndex = BaseZIndex
if OnComplete then
OnComplete()
end
return
end
if Showing then
local TweenInfo = Library.TabTransitionInfo or TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local Offset = Library.TabSwipeOffset or 26
local SwipeFrom = string.lower(Library.TabSwipeFrom or "bottom")
local StartPosition
local StartingPositions = {
Left = UDim2.fromOffset(-Offset, 0),
Right = UDim2.fromOffset(Offset, 0),
Top = UDim2.fromOffset(0, -Offset),
Bottom = UDim2.fromOffset(0, Offset),
}
if SwipeFrom == "auto" and Library.PreviousTab then
local CurrentOrder = Tab.Button.LayoutOrder
local PreviousOrder = Library.PreviousTab.Button.LayoutOrder
if CurrentOrder and PreviousOrder then -- this may be unnecessary but oh well
StartPosition = CurrentOrder > PreviousOrder and StartingPositions.Top or StartingPositions.Bottom -- bigger order means its under the current button
else
StartPosition = StartingPositions.Bottom
end
elseif SwipeFrom == "left" then
StartPosition = StartingPositions.Left
elseif SwipeFrom == "top" then
StartPosition = StartingPositions.Top
elseif SwipeFrom == "right" then
StartPosition = StartingPositions.Right
else -- bottom (Default)
StartPosition = StartingPositions.Bottom
end
TabContainer.ZIndex = BaseZIndex + 1
TabContainer.Position = StartPosition
TabContainer.Visible = true
local Tween = TweenService:Create(TabContainer, TweenInfo, {
Position = UDim2.fromScale(0, 0)
})
ActiveTabTweens[TabContainer] = Tween
Tween:Play()
local Connection; Connection = Tween.Completed:Connect(function(PlaybackState)
if Connection then
Connection:Disconnect()
end
if ActiveTabTweens[TabContainer] == Tween then
ActiveTabTweens[TabContainer] = nil
end
if PlaybackState == Enum.PlaybackState.Cancelled then
return
end
TabContainer.ZIndex = BaseZIndex
if OnComplete then
OnComplete()
end
end)
else
TabContainer.Visible = false
TabContainer.Position = UDim2.fromScale(0, 0)
TabContainer.ZIndex = BaseZIndex
if OnComplete then
OnComplete()
end
end
end
function Library:MakeBoxPopOut(Box: any, Options: {
Enabled: boolean?,
Header: GuiObject?,
Children: (() -> { GuiObject })?,
Before: (() -> ())?,
After: (() -> ())?,
MaxPopOutHeight: number?,
PopOutWidth: number?,
})
Box.PoppedOut = false
Box.PopOutEnabled = Options.Enabled ~= false
Box.PopOutFloat = nil
Box.PopOutPlaceholder = nil
Box.PopOutMaxHeight = if typeof(Options.MaxPopOutHeight) == "number" then Options.MaxPopOutHeight else nil
Box.PopOutWidth = if typeof(Options.PopOutWidth) == "number" then Options.PopOutWidth else nil
if not Box.PopOutEnabled then
function Box:SetPoppedOut(_Value: boolean, _SetPoppedOut: UDim2) end
function Box:TogglePoppedOut() end
function Box:RefreshPopOutPlaceholder() end
function Box:SetMaxPopOutHeight(_Height: number?) end
function Box:SetPopOutWidth(_Width: number?) end
return
end
local BoxHolder = Box.BoxHolder
local Holder = Box.Holder
local Header = Options.Header
local Placeholder
local PlaceholderHeader
local Float
local FloatScale
local HandledChildren: { GuiObject } = {}
local OriginalParents: { [GuiObject]: Instance? } = {}
local OriginalLayoutOrders: { [GuiObject]: number } = {}
local DragState: "Idle" | "Holding" | "Dragging" = "Idle"
local DragInput: InputObject?
local PressMouse: Vector2?
local DragStartPos: UDim2?
local DragChanged: RBXScriptConnection?
local DragDidMove = false
local function GetPopOutWidth(): number
if typeof(Box.PopOutWidth) == "number" then
return math.max(50, math.floor(Box.PopOutWidth + 0.5))
end
if typeof(Box.PopOutDockedWidth) == "number" then
return math.max(50, math.floor(Box.PopOutDockedWidth + 0.5))
end
local Width = Holder.AbsoluteSize.X / Library.DPIScale
if Width < 50 then
Width = 200
end
return math.max(50, math.floor(Width + 0.5))
end
local function ApplyPopOutWidth()
if not (Box.PoppedOut and Float) then
return
end
Float.Size = UDim2.fromOffset(GetPopOutWidth(), Float.Size.Y.Offset)
if Box.Resize then
Box:Resize()
end
end
local function RaiseFloat()
if not Float or not Floats then
return
end
local MaxZ = Float.ZIndex
for _, Child in Floats:GetChildren() do
if Child:IsA("GuiObject") and Child ~= Float then
MaxZ = math.max(MaxZ, Child.ZIndex)
end
end
Float.ZIndex = MaxZ + 1
if Float.Parent == Floats then
Float.Parent = Overlay
end
Float.Parent = Floats
end
local function CreatePlaceholder()
local Frame = New("Frame", {
AutomaticSize = Enum.AutomaticSize.Y,
BackgroundColor3 = "BackgroundColor",
BackgroundTransparency = 0.12,
ClipsDescendants = true,
Size = UDim2.new(1, 0, 0, 0),
Parent = BoxHolder,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius),
Parent = Frame,
})
)
Library:AddOutline(Frame)
PlaceholderHeader = Header:Clone()
PlaceholderHeader.Parent = Frame
DimPopOutClone(PlaceholderHeader)
if PopOutIcon then
local PlaceholderDockIcon = New("ImageButton", {
AutoButtonColor = false,
AnchorPoint = Vector2.new(1, 0.5),
BackgroundTransparency = 1,
ImageColor3 = "WhiteColor",
Position = UDim2.new(1, -8, 0.5, 0),
Size = UDim2.fromOffset(22, 22),
ZIndex = PlaceholderHeader.ZIndex + 1,
Parent = Frame,
})
Library:ApplyLucideIcon(PlaceholderDockIcon, PopOutIcon)
PlaceholderDockIcon.MouseButton1Click:Connect(function()
Box:SetPoppedOut(false)
end)
end
return Frame
end
function Box:RefreshPopOutPlaceholder()
if not Box.PoppedOut or not Placeholder or not Header then
return
end
if PlaceholderHeader then
PlaceholderHeader:Destroy()
PlaceholderHeader = nil
end
PlaceholderHeader = Header:Clone()
PlaceholderHeader.Parent = Placeholder
DimPopOutClone(PlaceholderHeader)
end
function Box:SetPoppedOut(Value: boolean, FloatPosition: UDim2?)
if not Box.PopOutEnabled or Box.Destroyed then
return
end
Value = Value == true
if Box.PoppedOut == Value then
if Value and FloatPosition and Float then
Float.Position = FloatPosition
end
return
end
if Value then
if Options.Before then
Options.Before()
end
local BoxChildren = if Options.Children then Options.Children() else { Holder }
HandledChildren = {}
table.clear(OriginalParents)
table.clear(OriginalLayoutOrders)
for _, Child in BoxChildren do
if not Child or not Child.Parent then
continue
end
table.insert(HandledChildren, Child)
OriginalParents[Child] = Child.Parent
OriginalLayoutOrders[Child] = Child.LayoutOrder
end
if #HandledChildren == 0 then
return
end
local DockedWidth = Holder.AbsoluteSize.X / Library.DPIScale
if DockedWidth < 50 then
DockedWidth = 200
end
Box.PopOutDockedWidth = math.max(50, math.floor(DockedWidth + 0.5))
local Width = GetPopOutWidth()
local AbsolutePosition = Holder.AbsolutePosition
Placeholder = CreatePlaceholder()
Box.PopOutPlaceholder = Placeholder
Float = New("Frame", {
Active = true,
AutomaticSize = Enum.AutomaticSize.Y,
BackgroundTransparency = 1,
Position = FloatPosition or UDim2.fromOffset(
AbsolutePosition.X / Library.DPIScale,
AbsolutePosition.Y / Library.DPIScale
),
Size = UDim2.fromOffset(Width, 0),
ZIndex = 1,
Parent = Floats,
})
FloatScale = New("UIScale", {
Parent = Float,
})
table.insert(Library.Scales, FloatScale)
FloatScale.Scale = Library.DPIScale - (tonumber(Library.ScalesOffset[FloatScale]) or 0)
New("UIListLayout", {
Padding = UDim.new(0, 6),
Parent = Float,
})
for _, Child in HandledChildren do
Child.Parent = Float
end
if not table.find(Library.DraggableElements, Float) then
table.insert(Library.DraggableElements, Float)
end
Box.PopOutFloat = Float
Box.PoppedOut = true
SyncPopOutVisibility(Box)
RaiseFloat()
Float:GetPropertyChangedSignal("AbsolutePosition"):Connect(function()
Box:Resize()
end)
if Options.After then
Options.After()
end
return
end
if Float then
local DraggableIndex = table.find(Library.DraggableElements, Float)
if DraggableIndex then
table.remove(Library.DraggableElements, DraggableIndex)
end
end
if FloatScale then
local ScaleIndex = table.find(Library.Scales, FloatScale)
if ScaleIndex then
table.remove(Library.Scales, ScaleIndex)
end
FloatScale = nil
end
for _, Child in HandledChildren do
if not Child or not Child.Parent then
continue
end
Child.Parent = OriginalParents[Child] or BoxHolder
Child.LayoutOrder = OriginalLayoutOrders[Child] or 0
end
if Placeholder then
Placeholder:Destroy()
Placeholder = nil
end
PlaceholderHeader = nil
if Float then
Float:Destroy()
Float = nil
end
Box.PopOutFloat = nil
Box.PopOutPlaceholder = nil
Box.PopOutDockedWidth = nil
Box.PoppedOut = false
table.clear(HandledChildren)
table.clear(OriginalParents)
table.clear(OriginalLayoutOrders)
if Options.After then
Options.After()
end
end
function Box:TogglePoppedOut()
Box:SetPoppedOut(not Box.PoppedOut)
end
function Box:SetMaxPopOutHeight(Height: number?)
if Height ~= nil then
assert(typeof(Height) == "number", "Height must be a number or nil")
assert(Height >= 0, "Height must be higher than 0")
end
Box.PopOutMaxHeight = Height
if Box.PoppedOut and Box.Resize then
Box:Resize()
end
end
function Box:SetPopOutWidth(Width: number?)
if Width ~= nil then
assert(typeof(Width) == "number", "Width must be a number or nil")
assert(Width >= 0, "Width must be higher than 0")
end
Box.PopOutWidth = Width
ApplyPopOutWidth()
end
local function StopDrag()
if DragState == "Idle" then
return
end
local WasDragging = DragState == "Dragging"
local DidMove = DragDidMove
DragState = "Idle"
DragInput = nil
PressMouse = nil
DragStartPos = nil
DragDidMove = false
if DragChanged and DragChanged.Connected then
DragChanged:Disconnect()
DragChanged = nil
end
if not WasDragging or not Box.PoppedOut or not Float then
return
end
local FloatCenter = Float.AbsolutePosition + (Float.AbsoluteSize * 0.5)
local NearPlaceholder = false
if Library.Toggled and Placeholder and Placeholder.Parent then
local PlaceholderCenter = Placeholder.AbsolutePosition + (Placeholder.AbsoluteSize * 0.5)
NearPlaceholder = (FloatCenter - PlaceholderCenter).Magnitude <= Library.PopOutSnapDistance
end
if NearPlaceholder or (DidMove and not IsScreenPointOutsideMain(FloatCenter)) then
Box:SetPoppedOut(false)
end
end
local function BeginDrag(Input: InputObject)
if DragState ~= "Idle" or Box.Destroyed or not (ScreenGui and ScreenGui.Parent) then
return
end
local Point = Vector2.new(Input.Position.X, Input.Position.Y)
local Top = GetTopFloatAt(Point)
if Box.PoppedOut then
if not Float or Top ~= Float then
return
end
elseif Top ~= nil and not Header:IsDescendantOf(Top) then
return
end
DragState = "Holding"
DragInput = Input
PressMouse = Vector2.new(Input.Position.X, Input.Position.Y)
DragStartPos = nil
DragDidMove = false
if Box.PoppedOut and Float then
RaiseFloat()
end
DragChanged = Input.Changed:Connect(function()
if Input.UserInputState == Enum.UserInputState.End then
StopDrag()
end
end)
task.delay(Library.PopOutHoldTime, function()
if (DragState :: any) ~= "Holding" or DragInput ~= Input then
return
end
DragState = "Dragging"
if Box.PoppedOut and Float then
RaiseFloat()
DragStartPos = Float.Position
end
end)
end
local function UpdateDrag(Input: InputObject)
if DragState ~= "Dragging" or not PressMouse then
return
end
if not (ScreenGui and ScreenGui.Parent) then
StopDrag()
return
end
local MousePosition = Vector2.new(Input.Position.X, Input.Position.Y)
local Delta = MousePosition - PressMouse
if not Box.PoppedOut then
if Delta.Magnitude < Library.PopOutDragThreshold then
return
end
Box:SetPoppedOut(true)
if not Float then
return
end
RaiseFloat()
DragStartPos = Float.Position
DragDidMove = true
elseif Delta.Magnitude >= Library.PopOutDragThreshold then
DragDidMove = true
end
if Float and DragStartPos then
Float.Position = UDim2.new(
DragStartPos.X.Scale,
DragStartPos.X.Offset + Delta.X,
DragStartPos.Y.Scale,
DragStartPos.Y.Offset + Delta.Y
)
end
end
local function BindDragSource(Gui: GuiObject)
Library:GiveSignal(Gui.InputBegan:Connect(function(Input: InputObject)
if IsClickInput(Input) then
BeginDrag(Input)
end
end))
end
BindDragSource(Header)
for _, Descendant in Header:QueryDescendants("GuiObject:not(ImageButton)") do
BindDragSource(Descendant)
end
Library:GiveSignal(Header.DescendantAdded:Connect(function(Descendant)
if Descendant:IsA("GuiObject") and not Descendant:IsA("ImageButton") then
BindDragSource(Descendant)
end
end))
Library:GiveSignal(UserInputService.InputChanged:Connect(function(Input: InputObject)
if IsHoverInput(Input) then
UpdateDrag(Input)
end
end))
end
function Library:MakeOutline(Frame: GuiObject, Corner: number?, ZIndex: number?)
warn("Obsidian:MakeOutline is deprecated, please use Obsidian:AddOutline instead.")
local Holder = New("Frame", {
BackgroundColor3 = "DarkColor",
Position = UDim2.fromOffset(-2, -2),
Size = UDim2.new(1, 4, 1, 4),
ZIndex = ZIndex,
Parent = Frame,
})
local Outline = New("Frame", {
BackgroundColor3 = "OutlineColor",
Position = UDim2.fromOffset(1, 1),
Size = UDim2.new(1, -2, 1, -2),
ZIndex = ZIndex,
Parent = Holder,
})
if Corner and Corner > 0 then
New("UICorner", {
CornerRadius = UDim.new(0, Corner + 1),
Parent = Holder,
})
New("UICorner", {
CornerRadius = UDim.new(0, Corner),
Parent = Outline,
})
end
return Holder, Outline
end
function Library:AddDraggableLabel(...)
local Params = select(1, ...)
local Text
local Icon
local IconPosition = "left"
if typeof(Params) == "table" then
Text = Params.Text
Icon = Params.Icon
IconPosition = Params.IconPosition or "left"
elseif typeof(Params) == "string" then
Text = Params
Icon = select(2, ...)
IconPosition = select(3, ...) or "left"
end
if typeof(IconPosition) ~= "string" then
IconPosition = "left"
end
IconPosition = string.lower(IconPosition)
assert(IconPosition == "left" or IconPosition == "right", "Icon Position needs to be either 'left' or 'right'.")
local DraggableLabel = {
Connections = {},
Destroyed = false
}
local IconImage
local Label = New("TextLabel", {
AutomaticSize = Enum.AutomaticSize.XY,
BackgroundColor3 = "BackgroundColor",
Size = UDim2.fromOffset(0, 0),
Position = UDim2.fromOffset(6, 6),
Text = Text,
TextSize = 15,
ZIndex = 1,
Parent = Floats,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius),
Parent = Label,
})
)
local Padding = New("UIPadding", {
PaddingBottom = UDim.new(0, 6),
PaddingLeft = UDim.new(0, 12),
PaddingRight = UDim.new(0, 12),
PaddingTop = UDim.new(0, 6),
Parent = Label,
})
table.insert(
Library.Scales,
New("UIScale", {
Parent = Label,
})
)
Library:AddOutline(Label)
Library:MakeDraggable(Label, Label, true)
function DraggableLabel:SetText(Text: string)
Label.Text = Text
end
function DraggableLabel:SetIcon(NewIcon: string)
Icon = NewIcon
local IsNotEmpty = Icon and Trim(tostring(Icon)) ~= ""
if IsNotEmpty then
local CustomIcon = Library:GetCustomIcon(Icon)
assert(CustomIcon, "Icon must be a valid Roblox asset or a valid URL or a valid lucide icon.")
IconImage = IconImage or New("ImageLabel", {
BackgroundTransparency = 1,
ImageColor3 = "FontColor",
Size = UDim2.fromOffset(16, 16),
ZIndex = 2,
Parent = Label,
})
Library:ApplyLucideIcon(IconImage, CustomIcon)
end
if IconImage then IconImage.Visible = IsNotEmpty end
DraggableLabel:SetIconPosition(IconPosition)
end
function DraggableLabel:SetIconPosition(NewPosition: string)
IconPosition = string.lower(NewPosition)
assert(IconPosition == "left" or IconPosition == "right", "Icon Position needs to be either 'left' or 'right'.")
local IsNotEmpty = Icon and Trim(tostring(Icon)) ~= ""
Padding.PaddingLeft = UDim.new(0, (IsNotEmpty and IconPosition == "left") and 34 or 12)
Padding.PaddingRight = UDim.new(0, (IsNotEmpty and IconPosition == "right") and 34 or 12)
if IconImage then
if IconPosition == "left" then
IconImage.AnchorPoint = Vector2.new(0, 0.5)
IconImage.Position = UDim2.new(0, -22, 0.5, 0)
else
IconImage.AnchorPoint = Vector2.new(1, 0.5)
IconImage.Position = UDim2.new(1, 22, 0.5, 0)
end
end
end
function DraggableLabel:SetVisible(Visible: boolean)
Label.Visible = Visible
end
DraggableLabel:SetIcon(Icon)
DraggableLabel.Label = Label
if not table.find(Library.DraggableElements, Label) then
table.insert(Library.DraggableElements, Label)
end
PositionDraggable(Label, Label.Position)
function DraggableLabel:Destroy()
DraggableLabel.Destroyed = true
if DraggableLabel.Connections then
for _, connection in DraggableLabel.Connections do
connection:Disconnect()
end
end
local ElemIdx = table.find(Library.DraggableElements, Label)
if ElemIdx then
table.remove(Library.DraggableElements, ElemIdx)
end
if Label then
Label:Destroy()
end
end
return DraggableLabel
end
function Library:AddDraggableButton(...)
local Params = select(1, ...)
local Text
local Func
local ExcludeScaling
local ExcludeDragging
if typeof(Params) == "table" then
Text = Params.Text
Func = Params.Callback or Params.Func
ExcludeScaling = Params.ExcludeScaling
ExcludeDragging = Params.ExcludeDragging
elseif typeof(Params) == "string" then
Text = Params
Func = select(2, ...)
ExcludeScaling = select(3, ...)
ExcludeDragging = select(4, ...)
end
local DraggableButton = {
Connections = {},
Destroyed = false
}
local Button = New("TextButton", {
BackgroundColor3 = "BackgroundColor",
Position = UDim2.fromOffset(6, 6),
TextSize = 16,
ZIndex = 1,
Parent = Floats,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius),
Parent = Button,
})
)
if not ExcludeScaling then
table.insert(
Library.Scales,
New("UIScale", {
Parent = Button,
})
)
end
Library:AddOutline(Button)
local MaxClickDistance = ExcludeDragging and 12 or math.huge
Button.InputBegan:Connect(function(Input: InputObject)
if not IsClickInput(Input) then
return
end
local StartPos = Input.Position
local Changed
Changed = Input.Changed:Connect(function()
if Input.UserInputState ~= Enum.UserInputState.End then
return
end
if (Input.Position - StartPos).Magnitude <= MaxClickDistance then
Library:SafeCallback(Func, DraggableButton)
end
if Changed and Changed.Connected then
Changed:Disconnect()
Changed = nil
end
end)
end)
function DraggableButton:SetText(Text: string)
local X, Y = Library:GetTextBounds(Text, Library.Scheme.Font, 16)
Button.Text = Text
Button.Size = UDim2.fromOffset(X * 2, Y * 2)
end
Library:MakeDraggable(Button, Button, true)
DraggableButton:SetText(Text)
DraggableButton.Button = Button
if not table.find(Library.DraggableElements, Button) then
table.insert(Library.DraggableElements, Button)
end
PositionDraggable(Button, Button.Position)
function DraggableButton:Destroy()
DraggableButton.Destroyed = true
if DraggableButton.Connections then
for _, connection in DraggableButton.Connections do
connection:Disconnect()
end
end
local ElemIdx = table.find(Library.DraggableElements, Button)
if ElemIdx then
table.remove(Library.DraggableElements, ElemIdx)
end
if Button then
Button:Destroy()
end
end
return DraggableButton
end
function Library:AddDraggableMenu(Name: string)
local Holder = New("Frame", {
AutomaticSize = Enum.AutomaticSize.XY,
BackgroundColor3 = "BackgroundColor",
Position = UDim2.fromOffset(6, 6),
Size = UDim2.fromOffset(0, 0),
ZIndex = 1,
Parent = Floats,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius),
Parent = Holder,
})
)
table.insert(
Library.Scales,
New("UIScale", {
Parent = Holder,
})
)
Library:AddOutline(Holder)
Library:MakeLine(Holder, {
Position = UDim2.fromOffset(0, 34),
Size = UDim2.new(1, 0, 0, 1),
})
local Label = New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 34),
Text = Name,
TextSize = 15,
TextXAlignment = Enum.TextXAlignment.Left,
Parent = Holder,
})
New("UIPadding", {
PaddingLeft = UDim.new(0, 12),
PaddingRight = UDim.new(0, 12),
Parent = Label,
})
local Container = New("Frame", {
BackgroundTransparency = 1,
Position = UDim2.fromOffset(0, 35),
Size = UDim2.new(1, 0, 1, -35),
Parent = Holder,
})
New("UIListLayout", {
Padding = UDim.new(0, 7),
Parent = Container,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 7),
PaddingLeft = UDim.new(0, 7),
PaddingRight = UDim.new(0, 7),
PaddingTop = UDim.new(0, 7),
Parent = Container,
})
Library:MakeDraggable(Holder, Label, true)
if not table.find(Library.DraggableElements, Holder) then
table.insert(Library.DraggableElements, Holder)
end
PositionDraggable(Holder, Holder.Position)
return Holder, Container
end
function Library:AddDraggableImageButton(...)
local Params = select(1, ...)
local Icon
local IconSize
local Func
local ExcludeScaling
local ExcludeDragging
if typeof(Params) == "table" then
Icon = Params.Icon
IconSize = Params.IconSize or 24
Func = Params.Callback or Params.Func
ExcludeScaling = Params.ExcludeScaling
ExcludeDragging = Params.ExcludeDragging
elseif typeof(Params) == "string" or typeof(Params) == "number" then
Icon = Params
IconSize = select(2, ...)
Func = select(3, ...)
ExcludeScaling = select(4, ...)
ExcludeDragging = select(5, ...)
end
local DraggableImageButton = {}
local Button = New("TextButton", {
BackgroundColor3 = "BackgroundColor",
Position = UDim2.fromOffset(6, 6),
Size = UDim2.fromOffset(IconSize + 12, IconSize + 12),
Text = "",
ZIndex = 1,
Parent = Floats,
})
local IconImage = New("ImageLabel", {
BackgroundTransparency = 1,
AnchorPoint = Vector2.new(0.5, 0.5),
Position = UDim2.fromScale(0.5, 0.5),
Size = UDim2.fromOffset(IconSize, IconSize),
ImageColor3 = "FontColor",
ZIndex = 2,
Parent = Button,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius),
Parent = Button,
})
)
if not ExcludeScaling then
table.insert(
Library.Scales,
New("UIScale", {
Parent = Button,
})
)
end
Library:AddOutline(Button)
local MaxClickDistance = ExcludeDragging and 12 or math.huge
Button.InputBegan:Connect(function(Input: InputObject)
if not IsClickInput(Input) then
return
end
local StartPos = Input.Position
local Changed
Changed = Input.Changed:Connect(function()
if Input.UserInputState ~= Enum.UserInputState.End then
return
end
if (Input.Position - StartPos).Magnitude <= MaxClickDistance then
Library:SafeCallback(Func, DraggableImageButton)
end
if Changed and Changed.Connected then
Changed:Disconnect()
Changed = nil
end
end)
end)
function DraggableImageButton:SetIcon(NewIcon: string)
Icon = NewIcon or Icon
local CustomIcon = Library:GetCustomIcon(Icon)
assert(CustomIcon, "Icon must be a valid Roblox asset or a valid URL or a valid lucide icon.")
Library:ApplyLucideIcon(IconImage, CustomIcon)
end
function DraggableImageButton:SetIconSize(NewSize: number)
IconSize = NewSize
IconImage.Size = UDim2.fromOffset(IconSize, IconSize)
Button.Size = UDim2.fromOffset(IconSize + 12, IconSize + 12)
end
Library:MakeDraggable(Button, Button, true)
DraggableImageButton:SetIcon(Icon)
DraggableImageButton.Button = Button
if not table.find(Library.DraggableElements, Button) then
table.insert(Library.DraggableElements, Button)
end
PositionDraggable(Button, Button.Position)
return DraggableImageButton
end
do
local WatermarkLabel = Library:AddDraggableLabel("")
WatermarkLabel:SetVisible(false)
function Library:SetWatermark(Text: string)
warn("Watermark is deprecated, please use Library:AddDraggableLabel instead.")
WatermarkLabel:SetText(Text)
end
function Library:SetWatermarkVisibility(Visible: boolean)
warn("Watermark is deprecated, please use Library:AddDraggableLabel instead.")
WatermarkLabel:SetVisible(Visible)
end
end
local CurrentMenu
function Library:AddContextMenu(
Holder: GuiObject,
Size: UDim2 | () -> (),
Offset: { [number]: number } | () -> {},
List: number?,
ActiveCallback: (Active: boolean) -> ()?,
IgnoreCornerRadius: boolean?,
SpecificCornersOnly: ("top" | "bottom" | "no_left" | "no_top_left")?, -- stupid way of doing this
AnimationType: ("Dropdown" | "KeyPicker" | "none")?
)
local Menu
local HolderGui = Holder:FindFirstAncestorOfClass("ScreenGui")
local ParentGui = Overlay
if HolderGui and HolderGui ~= ScreenGui and Library.ActiveLoading and HolderGui == Library.ActiveLoading.ScreenGui then
ParentGui = HolderGui
end
if List then
Menu = New("ScrollingFrame", {
AutomaticCanvasSize = Enum.AutomaticSize.None,
AutomaticSize = List == 1 and Enum.AutomaticSize.Y or Enum.AutomaticSize.None,
BackgroundColor3 = "BackgroundColor",
BottomImage = "rbxasset://textures/ui/Scroll/scroll-middle.png",
CanvasSize = UDim2.fromOffset(0, 0),
ScrollBarImageColor3 = "OutlineColor",
ScrollBarThickness = List == 2 and 2 or 0,
Size = typeof(Size) == "function" and Size() or Size,
TopImage = "rbxasset://textures/ui/Scroll/scroll-middle.png",
Visible = false,
ZIndex = 1,
Parent = ParentGui,
})
else
Menu = New("Frame", {
BackgroundColor3 = "BackgroundColor",
Size = typeof(Size) == "function" and Size() or Size,
Visible = false,
ZIndex = 1,
Parent = ParentGui,
})
end
table.insert(
Library.Scales,
New("UIScale", {
Parent = Menu,
})
)
New("UIStroke", {
Color = "OutlineColor",
Parent = Menu,
})
local Corner;
if IgnoreCornerRadius ~= true then
if SpecificCornersOnly == "top" then
Corner = New("UICorner", {
TopLeftRadius = UDim.new(0, Library.CornerRadius / 2),
TopRightRadius = UDim.new(0, Library.CornerRadius / 2),
BottomRightRadius = UDim.new(0, 0),
BottomLeftRadius = UDim.new(0, 0),
Parent = Menu,
}); table.insert(Library.SpecificCorners, Corner)
elseif SpecificCornersOnly == "bottom" then
Corner = New("UICorner", {
TopLeftRadius = UDim.new(0, 0),
TopRightRadius = UDim.new(0, 0),
BottomRightRadius = UDim.new(0, Library.CornerRadius / 2),
BottomLeftRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = Menu,
}); table.insert(Library.SpecificCorners, Corner)
elseif SpecificCornersOnly == "no_left" then
Corner = New("UICorner", {
TopLeftRadius = UDim.new(0, 0),
TopRightRadius = UDim.new(0, Library.CornerRadius / 2),
BottomRightRadius = UDim.new(0, Library.CornerRadius / 2),
BottomLeftRadius = UDim.new(0, 0),
Parent = Menu,
}); table.insert(Library.SpecificCorners, Corner)
elseif SpecificCornersOnly == "no_top_left" then
Corner = New("UICorner", {
TopLeftRadius = UDim.new(0, 0),
TopRightRadius = UDim.new(0, Library.CornerRadius / 2),
BottomRightRadius = UDim.new(0, Library.CornerRadius / 2),
BottomLeftRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = Menu,
}); table.insert(Library.SpecificCorners, Corner)
else
Corner = New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = Menu,
}); table.insert(Library.Corners, Corner)
end
end
local Table = {
Connections = {},
Destroyed = false,
Active = false,
ActiveCallback = ActiveCallback,
Holder = Holder,
Menu = Menu,
Corner = Corner,
List = nil,
Signal = nil,
Size = Size,
AutoSizeY = List == 1,
OpenCloseTween = nil,
Animated = function()
if not AnimationType or AnimationType == "none" then
return false
end
if not (Library.Animations and Library.Animations[AnimationType] == true) then
return false
end
return true, Library[string.format("%sTransitionInfo", AnimationType)] or TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
end
}
if List == 1 then
Table.List = New("UIListLayout", {
Parent = Menu,
})
end
function Table:Open()
if CurrentMenu == Table then
return
elseif CurrentMenu then
CurrentMenu:Close()
end
CurrentMenu = Table
Table.Active = true
Menu.ZIndex = 1
local TargetParent = if ParentGui == Overlay then Overlay else ParentGui
Menu.Parent = nil
Menu.Parent = TargetParent
if typeof(Offset) == "function" then
Menu.Position = UDim2.fromOffset(
math.floor(Holder.AbsolutePosition.X + Offset()[1]),
math.floor(Holder.AbsolutePosition.Y + Offset()[2])
)
else
Menu.Position = UDim2.fromOffset(
math.floor(Holder.AbsolutePosition.X + Offset[1]),
math.floor(Holder.AbsolutePosition.Y + Offset[2])
)
end
local TargetSize = typeof(Table.Size) == "function" and Table.Size() or Table.Size
if typeof(ActiveCallback) == "function" then
Library:SafeCallback(ActiveCallback, true)
end
if Table.OpenCloseTween then
StopTween(Table.OpenCloseTween, true)
Table.OpenCloseTween = nil
end
local IsAnimated, TweenInfo = Table.Animated()
if IsAnimated == true then
local OpenSize = TargetSize
if Table.AutoSizeY then
local FullHeight = Menu.AbsoluteSize.Y
Menu.AutomaticSize = Enum.AutomaticSize.None
OpenSize = UDim2.new(TargetSize.X.Scale, TargetSize.X.Offset, 0, FullHeight)
end
Menu.Size = UDim2.new(OpenSize.X.Scale, OpenSize.X.Offset, 0, 0)
Menu.Visible = true
local Tween = TweenService:Create(Menu, TweenInfo, { Size = OpenSize })
Table.OpenCloseTween = Tween
local Connection; Connection = Library:GiveSignal(Tween.Completed:Once(function()
if Connection then
Connection:Disconnect()
end
if Table.OpenCloseTween == Tween then
StopTween(Table.OpenCloseTween, true)
Table.OpenCloseTween = nil
if Table.AutoSizeY then
Menu.AutomaticSize = Enum.AutomaticSize.Y
end
end
end))
Tween:Play()
else
Menu.Size = TargetSize
Menu.Visible = true
end
Table.Signal = Holder:GetPropertyChangedSignal("AbsolutePosition"):Connect(function()
if typeof(Offset) == "function" then
Menu.Position = UDim2.fromOffset(
math.floor(Holder.AbsolutePosition.X + Offset()[1]),
math.floor(Holder.AbsolutePosition.Y + Offset()[2])
)
else
Menu.Position = UDim2.fromOffset(
math.floor(Holder.AbsolutePosition.X + Offset[1]),
math.floor(Holder.AbsolutePosition.Y + Offset[2])
)
end
local HolderAllowed = Library:IsInsideFrame(Library.WindowContainer, Holder)
if not HolderAllowed then
for _, Surface in Library.DraggableElements do
if not (Surface and Library:IsInsideFrame(Surface, Holder)) then
continue
end
HolderAllowed = true
break
end
end
if not HolderAllowed and Table.Active then
Table:Close()
end
end)
end
function Table:Close()
if CurrentMenu ~= Table then
return
end
if Table.Signal then
Table.Signal:Disconnect()
Table.Signal = nil
end
Table.Active = false
CurrentMenu = nil
if typeof(ActiveCallback) == "function" then
Library:SafeCallback(ActiveCallback, false)
end
if Table.OpenCloseTween then
StopTween(Table.OpenCloseTween, true)
Table.OpenCloseTween = nil
end
local IsAnimated, TweenInfo = Table.Animated()
if IsAnimated == true then
if Table.AutoSizeY then
Menu.AutomaticSize = Enum.AutomaticSize.None
end
local CurrentSize = Menu.Size
local CollapsedSize = UDim2.new(CurrentSize.X.Scale, CurrentSize.X.Offset, 0, 0)
local Tween = TweenService:Create(Menu, TweenInfo, { Size = CollapsedSize })
Table.OpenCloseTween = Tween
local Connection; Connection = Library:GiveSignal(Tween.Completed:Once(function(PlaybackState)
if Connection then
Connection:Disconnect()
end
if Table.OpenCloseTween == Tween then
StopTween(Table.OpenCloseTween, true)
Table.OpenCloseTween = nil
Menu.Visible = false
if Table.AutoSizeY then
Menu.AutomaticSize = Enum.AutomaticSize.Y
end
end
end))
Tween:Play()
else
Menu.Visible = false
end
end
function Table:Toggle()
if Table.Active then
Table:Close()
else
Table:Open()
end
end
function Table:SetSize(Size)
Table.Size = Size
Menu.Size = typeof(Size) == "function" and Size() or Size
end
function Table:Destroy()
Table.Destroyed = true
if Table.Connections then
for _, Connection in Table.Connections do
Connection:Disconnect()
end
end
if CurrentMenu == Table then
Table:Close()
end
if Table.OpenCloseTween then
StopTween(Table.OpenCloseTween, true)
Table.OpenCloseTween = nil
end
local MenuIndex = table.find(Library.ContextMenus, Table)
if MenuIndex then
table.remove(Library.ContextMenus, MenuIndex)
end
if Menu then
Menu:Destroy()
end
end
table.insert(Library.ContextMenus, Table)
return Table
end
Library:GiveSignal(UserInputService.InputBegan:Connect(function(Input: InputObject)
if Library.Unloaded then
return
end
if IsClickInput(Input, true) then
local Location = Input.Position
if
CurrentMenu
and not (
Library:MouseIsOverFrame(CurrentMenu.Menu, Location)
or Library:MouseIsOverFrame(CurrentMenu.Holder, Location)
)
then
CurrentMenu:Close()
end
end
end))
local TooltipLabel = New("TextLabel", {
BackgroundColor3 = "BackgroundColor",
TextSize = 14,
TextWrapped = true,
Visible = false,
ZIndex = 30,
Parent = ScreenGui,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 2),
PaddingLeft = UDim.new(0, 4),
PaddingRight = UDim.new(0, 4),
PaddingTop = UDim.new(0, 2),
Parent = TooltipLabel,
})
table.insert(
Library.Scales,
New("UIScale", {
Parent = TooltipLabel,
})
)
New("UIStroke", {
Color = "OutlineColor",
Parent = TooltipLabel,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = TooltipLabel,
})
)
local TooltipMeasureId = 0
local LastTooltipText = ""
local LastTooltipMaxWidth = 0
local function UpdateTooltipSize(Force: boolean?)
if Library.Unloaded or not TooltipLabel.Visible then
return
end
local MaxWidth = math.max(
40,
(workspace.CurrentCamera.ViewportSize.X - TooltipLabel.AbsolutePosition.X - 8) / Library.DPIScale
)
if
not Force
and TooltipLabel.Text == LastTooltipText
and math.abs(MaxWidth - LastTooltipMaxWidth) < 1
and TooltipLabel.Size.X.Offset > 0
then
return
end
TooltipMeasureId += 1
local MeasureId = TooltipMeasureId
local Text = TooltipLabel.Text
local X, Y = Library:GetTextBounds(Text, TooltipLabel.FontFace, TooltipLabel.TextSize, MaxWidth)
if MeasureId ~= TooltipMeasureId or TooltipLabel.Text ~= Text then
return
end
LastTooltipText = Text
LastTooltipMaxWidth = MaxWidth
TooltipLabel.Size = UDim2.fromOffset(X + 8, Y + 4)
end
TooltipLabel:GetPropertyChangedSignal("AbsolutePosition"):Connect(function()
UpdateTooltipSize(false)
end)
local CurrentHoverInstance
function Library:AddTooltip(InfoStr: string, DisabledInfoStr: string, HoverInstance: GuiObject)
local TooltipTable = {
Disabled = false,
Hovering = false,
Signals = {},
}
local function DoHover()
if
CurrentHoverInstance == HoverInstance
or Library.ActiveDialog
or (CurrentMenu and Library:MouseIsOverFrame(CurrentMenu.Menu, Mouse))
or (TooltipTable.Disabled and typeof(DisabledInfoStr) ~= "string")
or (not TooltipTable.Disabled and typeof(InfoStr) ~= "string")
then
return
end
CurrentHoverInstance = HoverInstance
local HolderGui = HoverInstance:FindFirstAncestorOfClass("ScreenGui")
if HolderGui and HolderGui ~= ScreenGui and Library.ActiveLoading and HolderGui == Library.ActiveLoading.ScreenGui then
TooltipLabel.Parent = HolderGui
else
TooltipLabel.Parent = ScreenGui
end
TooltipLabel.Text = TooltipTable.Disabled and DisabledInfoStr or InfoStr
TooltipLabel.Position = UDim2.fromOffset(
Mouse.X + (Library.ShowCustomCursor and 8 or 14),
Mouse.Y + (Library.ShowCustomCursor and 8 or 12)
)
TooltipLabel.Visible = true
UpdateTooltipSize(true)
while
(Library.Toggled or Library.ActiveLoading)
and not Library.ActiveDialog
and Library:MouseIsOverFrame(HoverInstance, Mouse)
and not (CurrentMenu and Library:MouseIsOverFrame(CurrentMenu.Menu, Mouse))
do
TooltipLabel.Position = UDim2.fromOffset(
Mouse.X + (Library.ShowCustomCursor and 8 or 14),
Mouse.Y + (Library.ShowCustomCursor and 8 or 12)
)
RunService.RenderStepped:Wait()
end
TooltipLabel.Visible = false
CurrentHoverInstance = nil
end
local function GiveSignal(Connection: RBXScriptConnection | RBXScriptSignal)
local ConnectionType = typeof(Connection)
if Connection and (ConnectionType == "RBXScriptConnection" or ConnectionType == "RBXScriptSignal") then
table.insert(TooltipTable.Signals, Connection)
end
return Connection
end
GiveSignal(HoverInstance.MouseEnter:Connect(DoHover))
GiveSignal(HoverInstance.MouseMoved:Connect(DoHover))
GiveSignal(HoverInstance.MouseLeave:Connect(function()
if CurrentHoverInstance ~= HoverInstance then
return
end
TooltipLabel.Visible = false
CurrentHoverInstance = nil
end))
function TooltipTable:Destroy()
for Index = #TooltipTable.Signals, 1, -1 do
local Connection = table.remove(TooltipTable.Signals, Index)
if Connection and Connection.Connected then
Connection:Disconnect()
end
end
if CurrentHoverInstance == HoverInstance then
if TooltipLabel then
TooltipLabel.Visible = false
end
CurrentHoverInstance = nil
end
end
table.insert(Tooltips, TooltipLabel)
return TooltipTable
end
function Library:OnUnload(Callback)
table.insert(Library.UnloadSignals, Callback)
end
local BaseAddons = {}
do
local Funcs = {}
function Funcs:AddKeyPicker(Idx, Info)
if self.Destroyed then return nil end
Info = Library:Validate(Info, Templates.KeyPicker)
local ParentObj = self
local ToggleLabel = ParentObj.TextLabel
if ParentObj.Type == "Button" or ParentObj.Type == "SubButton" then
assert(Info.Mode == "Press", "KeyPicker on Buttons can only be applied with the 'Press' mode.")
ToggleLabel = ParentObj.Base
end
local KeyPicker = {
Connections = {},
Text = Info.Text,
Value = Info.Default, -- Key
Modifiers = Info.DefaultModifiers, -- Modifiers
DisplayValue = Info.Default, -- Picker Text
Blacklisted = Info.Blacklisted,
BlacklistedModifiers = Info.BlacklistedModifiers,
Whitelisted = Info.Whitelisted,
WhitelistedModifiers = Info.WhitelistedModifiers,
Toggled = false,
Mode = Info.Mode,
SyncToggleState = Info.SyncToggleState,
MenuVisible = Info.NoUI ~= true,
Callback = Info.Callback,
ChangedCallback = Info.ChangedCallback,
Changed = Info.Changed,
Clicked = Info.Clicked,
Type = "KeyPicker",
}
if KeyPicker.Mode == "Press" then
assert(ParentObj.Type == "Label" or ParentObj.Type == "Button" or ParentObj.Type == "SubButton", "KeyPicker with the mode 'Press' can be only applied on Labels and Buttons.")
KeyPicker.SyncToggleState = false
Info.Modes = { "Press" }
Info.Mode = "Press"
end
if KeyPicker.SyncToggleState then
Info.Modes = { "Toggle", "Hold" }
if not table.find(Info.Modes, Info.Mode) then
Info.Mode = "Toggle"
end
end
local Picking = false
local IsForButton = ParentObj.Type == "Button" or ParentObj.Type == "SubButton"
local SpecialKeys = {
["MB1"] = Enum.UserInputType.MouseButton1,
["MB2"] = Enum.UserInputType.MouseButton2,
["MB3"] = Enum.UserInputType.MouseButton3,
}
local SpecialKeysInput = {
[Enum.UserInputType.MouseButton1] = "MB1",
[Enum.UserInputType.MouseButton2] = "MB2",
[Enum.UserInputType.MouseButton3] = "MB3",
}
local Modifiers = {
["LAlt"] = Enum.KeyCode.LeftAlt,
["RAlt"] = Enum.KeyCode.RightAlt,
["LCtrl"] = Enum.KeyCode.LeftControl,
["RCtrl"] = Enum.KeyCode.RightControl,
["LShift"] = Enum.KeyCode.LeftShift,
["RShift"] = Enum.KeyCode.RightShift,
["Tab"] = Enum.KeyCode.Tab,
["CapsLock"] = Enum.KeyCode.CapsLock,
}
local ModifiersInput = {
[Enum.KeyCode.LeftAlt] = "LAlt",
[Enum.KeyCode.RightAlt] = "RAlt",
[Enum.KeyCode.LeftControl] = "LCtrl",
[Enum.KeyCode.RightControl] = "RCtrl",
[Enum.KeyCode.LeftShift] = "LShift",
[Enum.KeyCode.RightShift] = "RShift",
[Enum.KeyCode.Tab] = "Tab",
[Enum.KeyCode.CapsLock] = "CapsLock",
}
local IsModifierInput = function(Input)
return Input.UserInputType == Enum.UserInputType.Keyboard and ModifiersInput[Input.KeyCode] ~= nil
end
local GetActiveModifiers = function()
local ActiveModifiers = {}
for Name, Input in Modifiers do
if table.find(ActiveModifiers, Name) then
continue
end
if not UserInputService:IsKeyDown(Input) then
continue
end
table.insert(ActiveModifiers, Name)
end
return ActiveModifiers
end
local AreModifiersHeld = function(Required)
if not (typeof(Required) == "table" and GetTableSize(Required) > 0) then
return true
end
local ActiveModifiers = GetActiveModifiers()
local Holding = true
for _, Name in Required do
if table.find(ActiveModifiers, Name) then
continue
end
Holding = false
break
end
return Holding
end
local IsInputDown = function(Input)
if not Input then
return false
end
if SpecialKeysInput[Input.UserInputType] ~= nil then
return UserInputService:IsMouseButtonPressed(Input.UserInputType)
and not UserInputService:GetFocusedTextBox()
elseif Input.UserInputType == Enum.UserInputType.Keyboard then
return UserInputService:IsKeyDown(Input.KeyCode) and not UserInputService:GetFocusedTextBox()
else
return false
end
end
local ConvertToInputModifiers = function(CurrentModifiers)
local InputModifiers = {}
for _, name in CurrentModifiers do
table.insert(InputModifiers, Modifiers[name])
end
return InputModifiers
end
local VerifyModifiers = function(CurrentModifiers)
if typeof(CurrentModifiers) ~= "table" then
return {}
end
local ValidModifiers = {}
for _, name in CurrentModifiers do
if not Modifiers[name] then
continue
end
table.insert(ValidModifiers, name)
end
return ValidModifiers
end
KeyPicker.Modifiers = VerifyModifiers(KeyPicker.Modifiers)
local SlideOverflow = true
local LastDisplayText = nil
local MaxPickerWidth = 85
local SlidingLabel
local SlideForwardTween
local SlideBackTween
local HandleForwardTween = function(State)
if State ~= Enum.PlaybackState.Completed then
return
end
task.wait(1.5)
if SlideBackTween then
SlideBackTween:Play()
end
end
local HandleBackTween = function(State)
if State ~= Enum.PlaybackState.Completed then
return
end
task.wait(1.5)
if SlideForwardTween then
SlideForwardTween:Play()
end
end
local SlideForwardConn, SlideBackConn
local CancelSlidingTweens = function()
if SlideForwardConn then
SlideForwardConn:Disconnect()
SlideForwardConn = nil
end
if SlideBackConn then
SlideBackConn:Disconnect()
SlideBackConn = nil
end
if SlideForwardTween then
StopTween(SlideForwardTween, true)
SlideForwardTween = nil
end
if SlideBackTween then
StopTween(SlideBackTween, true)
SlideBackTween = nil
end
RunService.RenderStepped:Wait()
end
local Picker = New("TextButton", {
BackgroundColor3 = "MainColor",
Size = UDim2.fromOffset(18, 18),
Text = (IsForButton and SlideOverflow) and "" or KeyPicker.Value,
TextSize = 14,
TextTransparency = 0.4,
Parent = ToggleLabel,
})
if IsForButton and SlideOverflow then
Picker.ClipsDescendants = true
SlidingLabel = New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 1, 0),
Position = UDim2.new(0, 0, 0, 0),
Text = KeyPicker.Value,
TextSize = 14,
FontFace = Picker.FontFace,
TextXAlignment = Enum.TextXAlignment.Center,
Parent = Picker,
})
Library:AddToRegistry(SlidingLabel, {
TextColor3 = "FontColor",
})
end
New("UIStroke", {
Color = "OutlineColor",
Parent = Picker,
})
local PickerCorner = New("UICorner", {
TopLeftRadius = UDim.new(0, Library.CornerRadius / 2),
TopRightRadius = UDim.new(0, Library.CornerRadius / 2),
BottomRightRadius = UDim.new(0, Library.CornerRadius / 2),
BottomLeftRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = Picker,
}); table.insert(Library.SpecificCorners, PickerCorner)
local PickerHoverTween = nil
local function ApplyPickerTextTransparency(Transparency: number)
StopTween(PickerHoverTween)
PickerHoverTween = nil
Picker.TextTransparency = Transparency
if SlidingLabel then
SlidingLabel.TextTransparency = Transparency
end
end
local function TweenPickerTextTransparency(Transparency: number)
StopTween(PickerHoverTween)
PickerHoverTween = TweenService:Create(Picker, Library.TweenInfo, {
TextTransparency = Transparency,
})
PickerHoverTween:Play()
if SlidingLabel then
TweenService:Create(SlidingLabel, Library.TweenInfo, {
TextTransparency = Transparency,
}):Play()
end
end
table.insert(KeyPicker.Connections, Picker.MouseEnter:Connect(function()
if ParentObj.Disabled then
return
end
TweenPickerTextTransparency(0)
end))
table.insert(KeyPicker.Connections, Picker.MouseLeave:Connect(function()
if ParentObj.Disabled then
return
end
TweenPickerTextTransparency(0.4)
end))
if IsForButton then
local Holder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 21),
Parent = ToggleLabel.Parent,
})
New("UIListLayout", {
FillDirection = Enum.FillDirection.Horizontal,
Padding = UDim.new(0, 9),
Parent = Holder,
})
New("UIFlexItem", {
FlexMode = Enum.UIFlexMode.Fill,
Parent = ToggleLabel,
})
ToggleLabel.Parent = Holder
Picker.Parent = Holder
Picker.Size = UDim2.new(0, 18, 1, 0)
end
local KeybindsToggle = { Normal = KeyPicker.Mode ~= "Toggle" }
do
local Holder = New("TextButton", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 16),
Text = "",
Visible = not Info.NoUI,
Parent = Library.KeybindContainer,
})
local Label = New("TextLabel", {
AutomaticSize = Enum.AutomaticSize.X,
BackgroundTransparency = 1,
Size = UDim2.fromScale(0, 1),
Text = "",
TextSize = 14,
TextTransparency = 0.5,
Parent = Holder,
})
local Checkbox = New("Frame", {
AnchorPoint = Vector2.new(0, 0.5),
BackgroundColor3 = "MainColor",
Position = UDim2.fromScale(0, 0.5),
Size = UDim2.fromOffset(14, 14),
SizeConstraint = Enum.SizeConstraint.RelativeYY,
Parent = Holder,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = Checkbox,
})
)
New("UIStroke", {
Color = "OutlineColor",
Parent = Checkbox,
})
local CheckImage = New("ImageLabel", {
ImageColor3 = "FontColor",
ImageTransparency = 1,
Position = UDim2.fromOffset(2, 2),
Size = UDim2.new(1, -4, 1, -4),
Parent = Checkbox,
})
if CheckIcon then
Library:ApplyLucideIcon(CheckImage, CheckIcon)
end
function KeybindsToggle:Display(State)
Label.TextTransparency = State and 0 or 0.5
CheckImage.ImageTransparency = State and 0 or 1
end
function KeybindsToggle:SetText(Text)
Label.Text = Text
end
function KeybindsToggle:SetVisibility(Visibility)
Holder.Visible = Visibility
end
function KeybindsToggle:SetNormal(Normal)
KeybindsToggle.Normal = Normal
Holder.Active = not Normal
Label.Position = Normal and UDim2.fromOffset(0, 0) or UDim2.fromOffset(22, 0)
Checkbox.Visible = not Normal
end
KeyPicker.DoClick = function(...) end --// make luau lsp shut up
table.insert(KeyPicker.Connections, Holder.MouseButton1Click:Connect(function()
if KeybindsToggle.Normal then
return
end
KeyPicker.Toggled = not KeyPicker.Toggled
KeyPicker:DoClick()
KeyPicker:Update()
end))
KeybindsToggle.Holder = Holder
KeybindsToggle.Label = Label
KeybindsToggle.Checkbox = Checkbox
KeybindsToggle.Loaded = true
table.insert(Library.KeybindToggles, KeybindsToggle)
end
local ModeButtons = {}
local ModeCorners = {}
local TotalModeButtons = GetTableSize(Info.Modes)
local MenuCornersOnly = if TotalModeButtons == 1 then "no_left" else "no_top_left"
local MenuTable
MenuTable = Library:AddContextMenu(Picker, UDim2.fromOffset(62, 0), function()
return { Picker.AbsoluteSize.X + 1.5, 0.5 }
end, 1, function(Active: boolean)
local Half = UDim.new(0, Library.CornerRadius / 2)
local Zero = UDim.new(0, 0)
PickerCorner.TopLeftRadius = Half
PickerCorner.BottomLeftRadius = Half
PickerCorner.TopRightRadius = Active and Zero or Half
PickerCorner.BottomRightRadius = Active and Zero or Half
local MenuCorner = MenuTable and MenuTable.Corner
if MenuCorner then
if MenuCornersOnly == "no_left" then
MenuCorner.TopLeftRadius = Zero
MenuCorner.BottomLeftRadius = Zero
MenuCorner.TopRightRadius = Half
MenuCorner.BottomRightRadius = Half
else
MenuCorner.TopLeftRadius = Zero
MenuCorner.TopRightRadius = Half
MenuCorner.BottomRightRadius = Half
MenuCorner.BottomLeftRadius = Half
end
end
for _, Entry in ModeCorners do
local Corner = Entry.Corner
if Entry.Style == "single" then
Corner.TopLeftRadius = Zero
Corner.BottomLeftRadius = Zero
Corner.TopRightRadius = Half
Corner.BottomRightRadius = Half
elseif Entry.Style == "first" then
Corner.TopLeftRadius = Zero
Corner.TopRightRadius = Half
Corner.BottomLeftRadius = Zero
Corner.BottomRightRadius = Zero
elseif Entry.Style == "last" then
Corner.TopLeftRadius = Zero
Corner.TopRightRadius = Zero
Corner.BottomLeftRadius = Half
Corner.BottomRightRadius = Half
end
end
end, false, MenuCornersOnly, "KeyPicker")
KeyPicker.Menu = MenuTable
for Index, Mode in Info.Modes do
local ModeButton = {}
local Button = New("TextButton", {
BackgroundColor3 = "MainColor",
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, IsForButton and 21 or (TotalModeButtons == 1 and 18 or 19)),
Text = Mode,
TextSize = 14,
TextTransparency = 0.5,
Parent = MenuTable.Menu,
})
if Index == 1 and TotalModeButtons == 1 then
local Corner = New("UICorner", {
TopLeftRadius = UDim.new(0, 0),
TopRightRadius = UDim.new(0, Library.CornerRadius / 2),
BottomLeftRadius = UDim.new(0, 0),
BottomRightRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = Button,
})
table.insert(Library.SpecificCorners, Corner)
table.insert(ModeCorners, { Corner = Corner, Style = "single" })
elseif Index == 1 then
local Corner = New("UICorner", {
TopLeftRadius = UDim.new(0, 0),
TopRightRadius = UDim.new(0, Library.CornerRadius / 2),
BottomLeftRadius = UDim.new(0, 0),
BottomRightRadius = UDim.new(0, 0),
Parent = Button,
})
table.insert(Library.SpecificCorners, Corner)
table.insert(ModeCorners, { Corner = Corner, Style = "first" })
elseif Index == TotalModeButtons then
local Corner = New("UICorner", {
TopLeftRadius = UDim.new(0, 0),
TopRightRadius = UDim.new(0, 0),
BottomLeftRadius = UDim.new(0, Library.CornerRadius / 2),
BottomRightRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = Button,
})
table.insert(Library.SpecificCorners, Corner)
table.insert(ModeCorners, { Corner = Corner, Style = "last" })
end
function ModeButton:Select()
for _, Button in ModeButtons do
Button:Deselect()
end
KeyPicker.Mode = Mode
Button.BackgroundTransparency = 0
Button.TextTransparency = 0
MenuTable:Close()
if KeyPicker.Update then
KeyPicker:Update()
end
end
function ModeButton:Deselect()
KeyPicker.Mode = nil
Button.BackgroundTransparency = 1
Button.TextTransparency = 0.5
end
table.insert(KeyPicker.Connections, Button.MouseButton1Click:Connect(function()
ModeButton:Select()
end))
table.insert(KeyPicker.Connections, Button.MouseEnter:Connect(function()
if KeyPicker.Mode == Mode then
return
end
TweenService:Create(Button, Library.TweenInfo, {
BackgroundTransparency = 0.7,
TextTransparency = 0.1,
}):Play()
end))
table.insert(KeyPicker.Connections, Button.MouseLeave:Connect(function()
if KeyPicker.Mode == Mode then
return
end
TweenService:Create(Button, Library.TweenInfo, {
BackgroundTransparency = 1,
TextTransparency = 0.5,
}):Play()
end))
if KeyPicker.Mode == Mode then
ModeButton:Select()
end
ModeButtons[Mode] = ModeButton
end
local SetPickingState = function(State, SkipUpdate: boolean?)
Picking = State
Library.IsPicking = State
if ParentObj then
ParentObj.AnyKeyPickerPicking = Picking
end
if IsForButton then
ToggleLabel.Visible = not Picking
LastDisplayText = nil
RunService.RenderStepped:Wait()
end
if SkipUpdate ~= true then
(KeyPicker :: any):Update()
end
end
function KeyPicker:Display(PickerText)
if Library.Unloaded then
return
end
local DisplayText = PickerText or KeyPicker.DisplayValue
if IsForButton and SlideOverflow then
local X, _Y = Library:GetTextBounds(
DisplayText,
Picker.FontFace,
Picker.TextSize,
10000
)
local OffsetScale = X + 9
local TextChanged = LastDisplayText ~= DisplayText
local LabelWidth
SlidingLabel.Text = DisplayText
LastDisplayText = DisplayText
if Picking then
Picker.Size = UDim2.new(1, 0, 1, 0)
RunService.RenderStepped:Wait()
LabelWidth = Picker.AbsoluteSize.X
if LabelWidth <= 0 then
LabelWidth = MaxPickerWidth
end
else
LabelWidth = math.min(OffsetScale, MaxPickerWidth)
Picker.Size = UDim2.new(0, LabelWidth, 1, 0)
end
if OffsetScale > LabelWidth then
SlidingLabel.TextXAlignment = Enum.TextXAlignment.Left
SlidingLabel.Size = UDim2.new(0, OffsetScale, 1, 0)
local OverflowDistance = OffsetScale - LabelWidth - 4.5
if OverflowDistance > 0 then
if TextChanged or not SlideForwardTween then
SlidingLabel.Position = UDim2.fromOffset(4.5, 0)
CancelSlidingTweens()
local Duration = math.max(OverflowDistance / 25, 0.35)
local TweenInfo = TweenInfo.new(
Duration,
Enum.EasingStyle.Linear,
Enum.EasingDirection.InOut
)
SlideForwardTween = TweenService:Create(SlidingLabel, TweenInfo, {
Position = UDim2.fromOffset(-OverflowDistance, 0),
})
SlideBackTween = TweenService:Create(SlidingLabel, TweenInfo, {
Position = UDim2.fromOffset(4.5, 0),
})
SlideForwardTween:Play()
if SlideForwardConn then
SlideForwardConn:Disconnect()
end
if SlideBackConn then
SlideBackConn:Disconnect()
end
SlideForwardConn = SlideForwardTween.Completed:Connect(HandleForwardTween)
SlideBackConn = SlideBackTween.Completed:Connect(HandleBackTween)
end
else
CancelSlidingTweens()
SlidingLabel.TextXAlignment = Enum.TextXAlignment.Center
SlidingLabel.Size = UDim2.new(1, 0, 1, 0)
SlidingLabel.Position = UDim2.new(0, 0, 0, 0)
end
else
CancelSlidingTweens()
SlidingLabel.TextXAlignment = Enum.TextXAlignment.Center
SlidingLabel.Size = UDim2.new(1, 0, 1, 0)
SlidingLabel.Position = UDim2.new(0, 0, 0, 0)
end
else
local X, Y = Library:GetTextBounds(
DisplayText,
Picker.FontFace,
Picker.TextSize,
ToggleLabel.AbsoluteSize.X / Library.DPIScale
)
Picker.Text = DisplayText
Picker.Size = IsForButton and UDim2.new(0, X + 9, 1, 0) or UDim2.fromOffset((X + 9), (Y + 4))
end
end
function KeyPicker:Update()
local Disabled = ParentObj.Disabled == true
if Disabled and Picking then
SetPickingState(false, true)
end
KeyPicker:Display()
Picker.Active = not Disabled
ApplyPickerTextTransparency(Disabled and 0.8 or 0.4)
if Disabled then
if MenuTable.Active then
MenuTable:Close()
end
end
if KeyPicker.Mode == "Toggle" and ParentObj.Type == "Toggle" and ParentObj.Disabled then
KeybindsToggle:SetVisibility(false)
return
end
local State = KeyPicker:GetState()
local ShowToggle = Library.ShowToggleFrameInKeybinds and KeyPicker.Mode == "Toggle"
if KeyPicker.SyncToggleState and ParentObj.Value ~= State then
ParentObj:SetValue(State)
end
if Info.NoUI then
return
end
if KeybindsToggle.Loaded then
if ShowToggle then
KeybindsToggle:SetNormal(false)
else
KeybindsToggle:SetNormal(true)
end
KeybindsToggle:SetText(("[%s] %s (%s)"):format(KeyPicker.DisplayValue, KeyPicker.Text, KeyPicker.Mode))
KeybindsToggle:SetVisibility(KeyPicker.MenuVisible ~= false)
KeybindsToggle:Display(State)
end
end
function KeyPicker:GetState()
if KeyPicker.Mode == "Always" then
return true
elseif KeyPicker.Mode == "Hold" then
local Key = KeyPicker.Value
if Key == "None" then
return false
end
if not AreModifiersHeld(KeyPicker.Modifiers) then
return false
end
if Picking then
return false
end
if SpecialKeys[Key] ~= nil then
if Library.Toggled then
return false
end
return UserInputService:IsMouseButtonPressed(SpecialKeys[Key])
and not UserInputService:GetFocusedTextBox()
else
return UserInputService:IsKeyDown(Enum.KeyCode[Key] :: any) and not UserInputService:GetFocusedTextBox()
end
else
return KeyPicker.Toggled
end
end
function KeyPicker:OnChanged(Func)
KeyPicker.Changed = Func
end
function KeyPicker:OnClick(Func)
KeyPicker.Clicked = Func
end
function KeyPicker:DoClick()
if Picking or ParentObj.Disabled then
return
end
if KeyPicker.Mode == "Press" then
if KeyPicker.Toggled and Info.WaitForCallback == true then
return
end
KeyPicker.Toggled = true
end
Library:SafeCallback(KeyPicker.Callback, KeyPicker.Toggled)
Library:SafeCallback(KeyPicker.Clicked, KeyPicker.Toggled)
if IsForButton then
Library:SafeCallback(ParentObj.Func, KeyPicker.Toggled)
end
if Library.ToggleKeybind == KeyPicker and Library.Toggle then
Library:Toggle()
end
if KeyPicker.Mode == "Press" then
KeyPicker.Toggled = false
end
end
function KeyPicker:RunChanged(IsKeyValid, KeyCode)
if ParentObj.Disabled then
return
end
if IsKeyValid == nil or KeyCode == nil then
IsKeyValid, KeyCode = pcall(function()
if KeyPicker.Value == "None" then
return nil
end
if SpecialKeys[KeyPicker.Value] == nil then
return Enum.KeyCode[KeyPicker.Value]
end
return SpecialKeys[KeyPicker.Value]
end)
end
local NewModifiers = ConvertToInputModifiers(KeyPicker.Modifiers)
Library:SafeCallback(KeyPicker.ChangedCallback, KeyCode, NewModifiers)
Library:SafeCallback(KeyPicker.Changed, KeyCode, NewModifiers)
end
function KeyPicker:SetValue(Data)
local Key, Mode, Modifiers = Data[1], Data[2], Data[3]
local IsKeyValid, KeyCode = pcall(function()
if Key == "None" then
Key = nil
return nil
end
if SpecialKeys[Key] == nil then
return Enum.KeyCode[Key]
end
return SpecialKeys[Key]
end)
if Key == nil then
KeyPicker.Value = "None"
elseif IsKeyValid then
KeyPicker.Value = Key
else
KeyPicker.Value = "Unknown"
end
KeyPicker.Modifiers =
VerifyModifiers(if typeof(Modifiers) == "table" then Modifiers else KeyPicker.Modifiers)
KeyPicker.DisplayValue = if GetTableSize(KeyPicker.Modifiers) > 0
then (table.concat(KeyPicker.Modifiers, " + ") .. " + " .. KeyPicker.Value)
else KeyPicker.Value
if ModeButtons[Mode] then
ModeButtons[Mode]:Select()
end
KeyPicker:Update()
KeyPicker:RunChanged(IsKeyValid, KeyCode)
end
function KeyPicker:SetText(Text)
KeybindsToggle:SetText(Text)
KeyPicker:Update()
end
function KeyPicker:SetMenuVisibility(Visible: boolean)
assert(typeof(Visible) == "boolean", "Visible must be a boolean")
KeyPicker.MenuVisible = Visible
KeyPicker:Update()
end
table.insert(KeyPicker.Connections, Picker.MouseButton1Click:Connect(function()
if Picking or Library.IsPicking or ParentObj.Disabled then
return
end
SetPickingState(true)
if IsForButton and SlideOverflow then
KeyPicker:Display("...")
else
Picker.Text = "..."
Picker.Size = IsForButton and UDim2.new(0, 29, 1, 0) or UDim2.fromOffset(29, 18)
end
local ActiveModifiers = {}
local CurrentInput = nil
local IsValidInput = function(InputObj)
if InputObj.KeyCode == Enum.KeyCode.Escape then
return true
end
local IsMod = IsModifierInput(InputObj)
local KeyName
if SpecialKeysInput[InputObj.UserInputType] ~= nil then
KeyName = SpecialKeysInput[InputObj.UserInputType]
elseif InputObj.UserInputType == Enum.UserInputType.Keyboard then
if IsMod then
KeyName = ModifiersInput[InputObj.KeyCode]
else
KeyName = InputObj.KeyCode.Name
end
end
if KeyName then
if IsMod then
if KeyPicker.WhitelistedModifiers and #KeyPicker.WhitelistedModifiers > 0 and not table.find(KeyPicker.WhitelistedModifiers, KeyName) then
return false
end
if KeyPicker.BlacklistedModifiers and table.find(KeyPicker.BlacklistedModifiers, KeyName) then
return false
end
else
if KeyPicker.Whitelisted and #KeyPicker.Whitelisted > 0 and not table.find(KeyPicker.Whitelisted, KeyName) then
return false
end
if KeyPicker.Blacklisted and table.find(KeyPicker.Blacklisted, KeyName) then
return false
end
end
end
return true
end
while true do
local InputObj = UserInputService.InputBegan:Wait()
if UserInputService:GetFocusedTextBox() ~= nil then
SetPickingState(false)
return
end
if IsValidInput(InputObj) then
CurrentInput = InputObj
break
end
end
while IsModifierInput(CurrentInput) do
if CurrentInput.KeyCode == Enum.KeyCode.Escape then
break
end
local ModName = ModifiersInput[CurrentInput.KeyCode]
if ModName then
local text = if #ActiveModifiers > 0 then table.concat(ActiveModifiers, " + ") .. " + " .. ModName .. " + ..." else ModName .. " + ..."
KeyPicker:Display(text)
end
local NextInput = nil
local Released = false
local BeganConn
local EndedConn
BeganConn = UserInputService.InputBegan:Connect(function(InputObj)
if UserInputService:GetFocusedTextBox() ~= nil then
return
end
if IsValidInput(InputObj) then
NextInput = InputObj
end
end)
EndedConn = UserInputService.InputEnded:Connect(function(InputObj)
if InputObj.KeyCode == CurrentInput.KeyCode then
Released = true
end
end)
repeat
task.wait()
until Released or NextInput or UserInputService:GetFocusedTextBox() ~= nil or Library.Unloaded
if BeganConn then BeganConn:Disconnect() end
if EndedConn then EndedConn:Disconnect() end
if UserInputService:GetFocusedTextBox() ~= nil or Library.Unloaded then
SetPickingState(false)
return
end
if Released then
break -- Use modifier key as bind
elseif NextInput then
local OldModName = ModifiersInput[CurrentInput.KeyCode]
if OldModName and not table.find(ActiveModifiers, OldModName) then
ActiveModifiers[#ActiveModifiers + 1] = OldModName
end
CurrentInput = NextInput
if CurrentInput.KeyCode == Enum.KeyCode.Escape then
break
end
end
end
local Key = "Unknown"
if SpecialKeysInput[CurrentInput.UserInputType] ~= nil then
Key = SpecialKeysInput[CurrentInput.UserInputType]
elseif CurrentInput.UserInputType == Enum.UserInputType.Keyboard then
Key = CurrentInput.KeyCode == Enum.KeyCode.Escape and "None" or CurrentInput.KeyCode.Name
end
ActiveModifiers = if CurrentInput.KeyCode == Enum.KeyCode.Escape or Key == "Unknown" then {} else ActiveModifiers
KeyPicker.Toggled = if ParentObj.Type == "Toggle" then ParentObj.Value else false
KeyPicker:SetValue({ Key, KeyPicker.Mode, ActiveModifiers })
repeat
task.wait()
until not IsInputDown(CurrentInput) or UserInputService:GetFocusedTextBox()
SetPickingState(false)
end))
table.insert(KeyPicker.Connections, Picker.MouseButton2Click:Connect(function()
if ParentObj.Disabled then
return
end
MenuTable:Toggle()
end))
table.insert(KeyPicker.Connections, UserInputService.InputBegan:Connect(function(Input: InputObject)
if Library.Unloaded then
return
end
local IsMouse = IsMouseClickInput(Input)
if
ParentObj.Disabled
or KeyPicker.Mode == "Always"
or KeyPicker.Value == "Unknown"
or KeyPicker.Value == "None"
or Picking
or Library.IsPicking
or UserInputService:GetFocusedTextBox()
or (IsMouse and Library.Toggled)
then
return
end
local Key = KeyPicker.Value
local HoldingModifiers = AreModifiersHeld(KeyPicker.Modifiers)
local HoldingKey = false
if
Key
and HoldingModifiers == true
and (
SpecialKeysInput[Input.UserInputType] == Key
or (Input.UserInputType == Enum.UserInputType.Keyboard and Input.KeyCode.Name == Key)
)
then
HoldingKey = true
end
if HoldingKey then
if KeyPicker.Mode == "Toggle" then
KeyPicker.Toggled = not KeyPicker.Toggled
KeyPicker:DoClick()
elseif KeyPicker.Mode == "Press" then
KeyPicker:DoClick()
elseif KeyPicker.Mode == "Hold" then
InputChanged = Input.Changed:Connect(function()
if KeyPicker:GetState() then
return
end
KeyPicker:Update()
if InputChanged and InputChanged.Connected then
InputChanged:Disconnect()
InputChanged = nil
end
end)
end
KeyPicker:Update()
end
end))
KeyPicker:Update()
if not ParentObj.Addons then
ParentObj.Addons = {}
end
table.insert(ParentObj.Addons, KeyPicker)
KeyPicker.Default = KeyPicker.Value
KeyPicker.DefaultModifiers = table.clone(KeyPicker.Modifiers or {})
function KeyPicker:Destroy()
KeyPicker.Destroyed = true
if SlideForwardConn then
SlideForwardConn:Disconnect()
SlideForwardConn = nil
end
if SlideBackConn then
SlideBackConn:Disconnect()
SlideBackConn = nil
end
if KeyPicker.Connections then
for _, Connection in KeyPicker.Connections do
Connection:Disconnect()
end
end
if KeybindsToggle and KeybindsToggle.Loaded then
if KeybindsToggle.Holder then
KeybindsToggle.Holder:Destroy()
end
local KTIdx = table.find(Library.KeybindToggles, KeybindsToggle)
if KTIdx then
table.remove(Library.KeybindToggles, KTIdx)
end
end
if MenuTable then
MenuTable:Destroy()
end
if IsForButton and SlideOverflow then
if SlideForwardTween then
SlideForwardTween:Destroy()
end
if SlideBackTween then
SlideBackTween:Destroy()
end
end
if Picker then
Picker:Destroy()
end
if ParentObj and ParentObj.Addons then
local AddonIdx = table.find(ParentObj.Addons, KeyPicker)
if AddonIdx then
table.remove(ParentObj.Addons, AddonIdx)
end
end
Options[Idx] = nil
end
Options[Idx] = KeyPicker
return self
end
local HueSequenceTable = {}
for Hue = 0, 1, 0.1 do
table.insert(HueSequenceTable, ColorSequenceKeypoint.new(Hue, Color3.fromHSV(Hue, 1, 1)))
end
function Funcs:AddColorPicker(Idx, Info)
if self.Destroyed then return nil end
Info = Library:Validate(Info, Templates.ColorPicker)
local ParentObj = self
local ToggleLabel = ParentObj.TextLabel
local ColorPicker = {
Connections = {},
Destroyed = false,
Value = Info.Default,
Transparency = Info.Transparency or 0,
Title = Info.Title,
Callback = Info.Callback,
Changed = Info.Changed,
Type = "ColorPicker",
}
ColorPicker.Hue, ColorPicker.Sat, ColorPicker.Vib = ColorPicker.Value:ToHSV()
local Holder = New("TextButton", {
BackgroundColor3 = ColorPicker.Value,
Size = UDim2.fromOffset(18, 18),
Text = "",
Parent = ToggleLabel,
})
local HolderStroke = New("UIStroke", {
Color = Library:GetDarkerColor(ColorPicker.Value),
Parent = Holder,
})
local ColorPickerCorner = New("UICorner", {
TopLeftRadius = UDim.new(0, Library.CornerRadius / 2),
TopRightRadius = UDim.new(0, Library.CornerRadius / 2),
BottomRightRadius = UDim.new(0, Library.CornerRadius / 2),
BottomLeftRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = Holder,
}); table.insert(Library.SpecificCorners, ColorPickerCorner)
local HolderTransparency = New("ImageLabel", {
Image = CustomImageManager.GetAsset("TransparencyTexture"),
ImageTransparency = (1 - ColorPicker.Transparency),
ScaleType = Enum.ScaleType.Tile,
Position = UDim2.new(0, -1, 0, -1),
Size = UDim2.new(1, 2, 1, 2),
TileSize = UDim2.fromOffset(9, 9),
Parent = Holder,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = HolderTransparency,
})
)
local MapSize = Library.IsMobile and 140 or 200
local BarWidth = 16
local MenuWidth = MapSize + BarWidth + 6 + 12
if Info.Transparency then
MenuWidth += BarWidth + 6
end
local ColorMenu
local FooterCorner
ColorMenu = Library:AddContextMenu(
Holder,
UDim2.fromOffset(MenuWidth, 0),
function()
return { 0.5, Holder.AbsoluteSize.Y + 1.5 }
end,
1, function(Active: boolean)
local Half = UDim.new(0, Library.CornerRadius / 2)
local Zero = UDim.new(0, 0)
ColorPickerCorner.TopLeftRadius = Half
ColorPickerCorner.TopRightRadius = Half
ColorPickerCorner.BottomRightRadius = Active and Zero or Half
ColorPickerCorner.BottomLeftRadius = Active and Zero or Half
local MenuCorner = ColorMenu and ColorMenu.Corner
if MenuCorner then
MenuCorner.TopLeftRadius = Zero
MenuCorner.TopRightRadius = Half
MenuCorner.BottomRightRadius = Half
MenuCorner.BottomLeftRadius = Half
end
if FooterCorner then
FooterCorner.TopLeftRadius = Zero
FooterCorner.TopRightRadius = Zero
FooterCorner.BottomLeftRadius = Half
FooterCorner.BottomRightRadius = Half
end
end, false, "no_top_left")
ColorMenu.List.Padding = UDim.new(0, 0)
ColorPicker.ColorMenu = ColorMenu
local ContentHolder = New("Frame", {
AutomaticSize = Enum.AutomaticSize.Y,
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 0),
Parent = ColorMenu.Menu,
})
New("UIListLayout", {
Padding = UDim.new(0, 8),
Parent = ContentHolder,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 6),
PaddingLeft = UDim.new(0, 6),
PaddingRight = UDim.new(0, 6),
PaddingTop = UDim.new(0, 6),
Parent = ContentHolder,
})
local FooterHeight = Library.IsMobile and 30 or 22
local FooterBackground = New("Frame", {
BackgroundColor3 = function()
return Library:GetBetterColor(Library.Scheme.BackgroundColor, 4)
end,
Size = UDim2.new(1, 0, 0, FooterHeight),
Parent = ColorMenu.Menu,
})
FooterCorner = New("UICorner", {
TopLeftRadius = UDim.new(0, 0),
TopRightRadius = UDim.new(0, 0),
BottomLeftRadius = UDim.new(0, Library.CornerRadius / 2),
BottomRightRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = FooterBackground,
})
table.insert(Library.SpecificCorners, FooterCorner)
Library:MakeLine(FooterBackground, {
Position = UDim2.fromScale(0, 0),
Size = UDim2.new(1, 0, 0, 1),
})
local FooterBar = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 1),
Parent = FooterBackground,
})
New("UIPadding", {
PaddingLeft = UDim.new(0, 6),
PaddingRight = UDim.new(0, Info.Resizable and (FooterHeight + 4) or 6),
Parent = FooterBar,
})
local FooterInfoLabel = New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 1),
Text = "",
TextSize = 14,
TextTransparency = 0.5,
TextTruncate = Enum.TextTruncate.AtEnd,
TextXAlignment = Enum.TextXAlignment.Center,
Parent = FooterBar,
})
local function RefreshFooterInfo()
FooterInfoLabel.Text = string.format(
"#%s • %d, %d, %d",
ColorPicker.Value:ToHex(),
math.floor(ColorPicker.Value.R * 255),
math.floor(ColorPicker.Value.G * 255),
math.floor(ColorPicker.Value.B * 255)
)
end
RefreshFooterInfo()
if typeof(ColorPicker.Title) == "string" then
New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 8),
Text = ColorPicker.Title,
TextSize = 14,
TextXAlignment = Enum.TextXAlignment.Left,
Parent = ContentHolder,
})
end
local ColorHolder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, MapSize),
Parent = ContentHolder,
})
New("UIListLayout", {
FillDirection = Enum.FillDirection.Horizontal,
Padding = UDim.new(0, 6),
Parent = ColorHolder,
})
local SatVipMap = New("ImageButton", {
BackgroundColor3 = ColorPicker.Value,
Image = CustomImageManager.GetAsset("SaturationMap"),
Size = UDim2.fromOffset(MapSize, MapSize),
Parent = ColorHolder,
})
local SatVibCursor = New("Frame", {
AnchorPoint = Vector2.new(0.5, 0.5),
BackgroundColor3 = "WhiteColor",
Size = UDim2.fromOffset(6, 6),
Parent = SatVipMap,
})
New("UICorner", {
CornerRadius = UDim.new(1, 0),
Parent = SatVibCursor,
})
New("UIStroke", {
Color = "DarkColor",
Parent = SatVibCursor,
})
local HueSelector = New("TextButton", {
Size = UDim2.fromOffset(BarWidth, MapSize),
Text = "",
Parent = ColorHolder,
})
New("UIGradient", {
Color = ColorSequence.new(HueSequenceTable),
Rotation = 90,
Parent = HueSelector,
})
local HueCursor = New("Frame", {
AnchorPoint = Vector2.new(0.5, 0.5),
BackgroundColor3 = "WhiteColor",
BorderColor3 = "DarkColor",
BorderSizePixel = 1,
Position = UDim2.fromScale(0.5, ColorPicker.Hue),
Size = UDim2.new(1, 2, 0, 1),
Parent = HueSelector,
})
local TransparencySelector, TransparencyColor, TransparencyCursor
if Info.Transparency then
TransparencySelector = New("ImageButton", {
Image = CustomImageManager.GetAsset("TransparencyTexture"),
ScaleType = Enum.ScaleType.Tile,
Size = UDim2.fromOffset(BarWidth, MapSize),
TileSize = UDim2.fromOffset(8, 8),
Parent = ColorHolder,
})
TransparencyColor = New("Frame", {
BackgroundColor3 = ColorPicker.Value,
Size = UDim2.fromScale(1, 1),
Parent = TransparencySelector,
})
New("UIGradient", {
Rotation = 90,
Transparency = NumberSequence.new({
NumberSequenceKeypoint.new(0, 0),
NumberSequenceKeypoint.new(1, 1),
}),
Parent = TransparencyColor,
})
TransparencyCursor = New("Frame", {
AnchorPoint = Vector2.new(0.5, 0.5),
BackgroundColor3 = "WhiteColor",
BorderColor3 = "DarkColor",
BorderSizePixel = 1,
Position = UDim2.fromScale(0.5, ColorPicker.Transparency),
Size = UDim2.new(1, 2, 0, 1),
Parent = TransparencySelector,
})
end
local ResizeGrabber
if Info.Resizable then
local BaseMapSize = 200
local BaseBarWidth = BarWidth
local BasePadding = 6
local MinMapSize = 140
ColorPicker.MapWidth = MapSize
ColorPicker.MapHeight = MapSize
local function GetBarWidth(MapWidth)
return math.clamp(math.floor((MapWidth / BaseMapSize) * BaseBarWidth + 0.5), 12, 24)
end
local function GetContentWidth(MapWidth)
local CurrentBarWidth = GetBarWidth(MapWidth)
local Width = MapWidth + CurrentBarWidth + BasePadding
if Info.Transparency then
Width += (CurrentBarWidth + BasePadding)
end
return Width + 12
end
local FixedVerticalOverhead = 6 + 6 + 8 + 20 + 8 + 20 + FooterHeight
if typeof(ColorPicker.Title) == "string" then
FixedVerticalOverhead += 8 + 8
end
local function ClampToViewport(NewWidth, NewHeight)
local Camera = workspace.CurrentCamera
if not Camera then
return NewWidth, NewHeight
end
local ViewportSize = Camera.ViewportSize
local ScreenMargin = 12
local MaxWidth = ViewportSize.X - ColorMenu.Menu.AbsolutePosition.X - ScreenMargin
local MaxHeight = ViewportSize.Y - ColorMenu.Menu.AbsolutePosition.Y - ScreenMargin - FixedVerticalOverhead
while NewWidth > MinMapSize and GetContentWidth(NewWidth) > MaxWidth do
NewWidth -= 4
end
if NewHeight > MaxHeight then
NewHeight = math.max(MinMapSize, math.floor(MaxHeight))
end
return NewWidth, NewHeight
end
local function UpdateColorMenuSize(NewWidth, NewHeight)
NewWidth = math.max(MinMapSize, math.floor(NewWidth + 0.5))
NewHeight = math.max(MinMapSize, math.floor(NewHeight + 0.5))
NewWidth, NewHeight = ClampToViewport(NewWidth, NewHeight)
if NewWidth == ColorPicker.MapWidth and NewHeight == ColorPicker.MapHeight then
return
end
local CurrentBarWidth = GetBarWidth(NewWidth)
local CursorSize = math.clamp(math.floor((math.min(NewWidth, NewHeight) / BaseMapSize) * 6 + 0.5), 4, 10)
ColorHolder.Size = UDim2.new(1, 0, 0, NewHeight)
SatVipMap.Size = UDim2.fromOffset(NewWidth, NewHeight)
SatVibCursor.Size = UDim2.fromOffset(CursorSize, CursorSize)
HueSelector.Size = UDim2.new(0, CurrentBarWidth, 0, NewHeight)
if TransparencySelector then
TransparencySelector.Size = UDim2.new(0, CurrentBarWidth, 0, NewHeight)
end
ColorPicker.MapWidth = NewWidth
ColorPicker.MapHeight = NewHeight
ColorMenu:SetSize(UDim2.new(0, GetContentWidth(NewWidth), 0, 0))
end
ResizeGrabber = New("TextButton", {
AnchorPoint = Vector2.new(1, 0),
BackgroundTransparency = 1,
Position = UDim2.new(1, -Library.CornerRadius / 4, 0, 0),
Size = UDim2.fromScale(1, 1),
SizeConstraint = Enum.SizeConstraint.RelativeYY,
Text = "",
Parent = FooterBackground,
})
local ResizeGrabberIcon = New("ImageLabel", {
ImageColor3 = "FontColor",
ImageTransparency = 0.5,
Position = UDim2.fromOffset(2, 2),
Size = UDim2.new(1, -4, 1, -4),
Parent = ResizeGrabber,
})
if ResizeIcon then
Library:ApplyLucideIcon(ResizeGrabberIcon, ResizeIcon)
end
table.insert(ColorPicker.Connections, ResizeGrabber.InputBegan:Connect(function(Input: InputObject)
Library.CantDragForced = true
local StartMouse = Vector2.new(Mouse.X, Mouse.Y)
local StartWidth = ColorPicker.MapWidth
local StartHeight = ColorPicker.MapHeight
while IsDragInput(Input) and not ColorPicker.Destroyed do
local Delta = Vector2.new(Mouse.X, Mouse.Y) - StartMouse
UpdateColorMenuSize(StartWidth + Delta.X, StartHeight + Delta.Y)
RunService.RenderStepped:Wait()
end
Library.CantDragForced = false
end))
end
local InfoHolder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 20),
Parent = ContentHolder,
})
New("UIListLayout", {
FillDirection = Enum.FillDirection.Horizontal,
HorizontalFlex = Enum.UIFlexAlignment.Fill,
Padding = UDim.new(0, 8),
Parent = InfoHolder,
})
local HueBox = New("TextBox", {
BackgroundColor3 = "MainColor",
ClearTextOnFocus = false,
Size = UDim2.fromScale(1, 1),
Text = "#??????",
TextSize = 14,
Parent = InfoHolder,
})
local HueBoxStroke = New("UIStroke", {
Color = "OutlineColor",
Parent = HueBox,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = HueBox,
})
)
local RgbBox = New("TextBox", {
BackgroundColor3 = "MainColor",
ClearTextOnFocus = false,
Size = UDim2.fromScale(1, 1),
Text = "?, ?, ?",
TextSize = 14,
Parent = InfoHolder,
})
local RgbBoxStroke = New("UIStroke", {
Color = "OutlineColor",
Parent = RgbBox,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = RgbBox,
})
)
local ContextMenu
ContextMenu = Library:AddContextMenu(Holder, UDim2.fromOffset(93, 0), function()
return { Holder.AbsoluteSize.X + 1.5, 0.5 }
end, 1, function(Active: boolean)
local Half = UDim.new(0, Library.CornerRadius / 2)
local Zero = UDim.new(0, 0)
ColorPickerCorner.TopLeftRadius = Half
ColorPickerCorner.BottomLeftRadius = Half
ColorPickerCorner.TopRightRadius = Active and Zero or Half
ColorPickerCorner.BottomRightRadius = Active and Zero or Half
local MenuCorner = ContextMenu and ContextMenu.Corner
if MenuCorner then
MenuCorner.TopLeftRadius = Zero
MenuCorner.TopRightRadius = Half
MenuCorner.BottomRightRadius = Half
MenuCorner.BottomLeftRadius = Half
end
end, false, "no_top_left")
ColorPicker.ContextMenu = ContextMenu
ContextMenu.List.Padding = UDim.new(0, 6)
do
local function CreateButton(Text, Func)
local Button = New("TextButton", {
BackgroundColor3 = "MainColor",
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 21),
Text = Text,
TextSize = 14,
Parent = ContextMenu.Menu,
})
table.insert(ColorPicker.Connections, Button.MouseButton1Click:Connect(function()
Library:SafeCallback(Func)
ContextMenu:Close()
end))
table.insert(ColorPicker.Connections, Button.MouseEnter:Connect(function()
TweenService:Create(Button, Library.TweenInfo, {
BackgroundTransparency = 0.7,
}):Play()
end))
table.insert(ColorPicker.Connections, Button.MouseLeave:Connect(function()
TweenService:Create(Button, Library.TweenInfo, {
BackgroundTransparency = 1,
}):Play()
end))
end
CreateButton("Copy color", function()
Library.CopiedColor = { ColorPicker.Value, ColorPicker.Transparency }
end)
ColorPicker.SetValueRGB = function(...) end --// make luau lsp shut up
CreateButton("Paste color", function()
if not Library.CopiedColor then
return
end
ColorPicker:SetValueRGB(Library.CopiedColor[1], Library.CopiedColor[2])
end)
if setclipboard then
CreateButton("Copy Hex", function()
setclipboard(tostring(ColorPicker.Value:ToHex()))
end)
CreateButton("Copy RGB", function()
setclipboard(table.concat({
math.floor(ColorPicker.Value.R * 255),
math.floor(ColorPicker.Value.G * 255),
math.floor(ColorPicker.Value.B * 255),
}, ", "))
end)
end
end
local ActionHolder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 20),
Parent = ContentHolder,
})
New("UIListLayout", {
FillDirection = Enum.FillDirection.Horizontal,
HorizontalFlex = Enum.UIFlexAlignment.Fill,
Padding = UDim.new(0, 8),
Parent = ActionHolder,
})
local CopyColorButton = New("TextButton", {
BackgroundColor3 = "MainColor",
Size = UDim2.fromScale(1, 1),
Text = "Copy color",
TextSize = 14,
Parent = ActionHolder,
})
New("UIStroke", {
Color = "OutlineColor",
Parent = CopyColorButton,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = CopyColorButton,
})
)
local PasteColorButton = New("TextButton", {
BackgroundColor3 = "MainColor",
Size = UDim2.fromScale(1, 1),
Text = "Paste color",
TextSize = 14,
Parent = ActionHolder,
})
New("UIStroke", {
Color = "OutlineColor",
Parent = PasteColorButton,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = PasteColorButton,
})
)
local CopyColorOriginalText = CopyColorButton.Text
local PasteColorOriginalText = PasteColorButton.Text
local CopyColorResetId = 0
local PasteColorResetId = 0
table.insert(ColorPicker.Connections, CopyColorButton.MouseEnter:Connect(function()
TweenService:Create(CopyColorButton, Library.TweenInfo, {
BackgroundColor3 = Library:GetBetterColor(Library.Scheme.MainColor, 10),
}):Play()
end))
table.insert(ColorPicker.Connections, CopyColorButton.MouseLeave:Connect(function()
TweenService:Create(CopyColorButton, Library.TweenInfo, {
BackgroundColor3 = Library.Scheme.MainColor,
}):Play()
end))
table.insert(ColorPicker.Connections, PasteColorButton.MouseEnter:Connect(function()
TweenService:Create(PasteColorButton, Library.TweenInfo, {
BackgroundColor3 = Library:GetBetterColor(Library.Scheme.MainColor, 10),
}):Play()
end))
table.insert(ColorPicker.Connections, PasteColorButton.MouseLeave:Connect(function()
TweenService:Create(PasteColorButton, Library.TweenInfo, {
BackgroundColor3 = Library.Scheme.MainColor,
}):Play()
end))
table.insert(ColorPicker.Connections, CopyColorButton.MouseButton1Click:Connect(function()
Library.CopiedColor = { ColorPicker.Value, ColorPicker.Transparency }
CopyColorResetId += 1
local ThisResetId = CopyColorResetId
CopyColorButton.Text = "Copied color"
task.delay(1, function()
if ColorPicker.Destroyed or ThisResetId ~= CopyColorResetId then
return
end
CopyColorButton.Text = CopyColorOriginalText
end)
end))
table.insert(ColorPicker.Connections, PasteColorButton.MouseButton1Click:Connect(function()
PasteColorResetId += 1
local ThisResetId = PasteColorResetId
if not Library.CopiedColor then
PasteColorButton.Text = "Nothing to paste"
else
ColorPicker:SetValueRGB(Library.CopiedColor[1], Library.CopiedColor[2])
PasteColorButton.Text = "Pasted color"
end
task.delay(1, function()
if ColorPicker.Destroyed or ThisResetId ~= PasteColorResetId then
return
end
PasteColorButton.Text = PasteColorOriginalText
end)
end))
function ColorPicker:SetHSVFromRGB(Color)
ColorPicker.Hue, ColorPicker.Sat, ColorPicker.Vib = Color:ToHSV()
end
function ColorPicker:Display()
if Library.Unloaded then
return
end
ColorPicker.Value = Color3.fromHSV(ColorPicker.Hue, ColorPicker.Sat, ColorPicker.Vib)
SatVipMap.BackgroundColor3 = Color3.fromHSV(ColorPicker.Hue, 1, 1)
if TransparencyColor then
TransparencyColor.BackgroundColor3 = ColorPicker.Value
end
SatVibCursor.Position = UDim2.fromScale(ColorPicker.Sat, 1 - ColorPicker.Vib)
HueCursor.Position = UDim2.fromScale(0.5, ColorPicker.Hue)
if TransparencyCursor then
TransparencyCursor.Position = UDim2.fromScale(0.5, ColorPicker.Transparency)
end
HueBox.Text = "#" .. ColorPicker.Value:ToHex()
RgbBox.Text = table.concat({
math.floor(ColorPicker.Value.R * 255),
math.floor(ColorPicker.Value.G * 255),
math.floor(ColorPicker.Value.B * 255),
}, ", ")
RefreshFooterInfo()
end
local function ApplyHolderVisual(Disabled: boolean)
Holder.Active = not Disabled
HolderStroke.Transparency = Disabled and 0.5 or 0
Holder.BackgroundTransparency = Disabled and 0.5 or 0
if Disabled then
Holder.BackgroundColor3 = ColorPicker.Value:Lerp(Library.Scheme.BackgroundColor, 0.5)
HolderTransparency.ImageTransparency = math.clamp((1 - ColorPicker.Transparency) + 0.5, 0, 1)
else
Holder.BackgroundColor3 = ColorPicker.Value
HolderStroke.Color = Library:GetDarkerColor(ColorPicker.Value)
HolderTransparency.ImageTransparency = (1 - ColorPicker.Transparency)
end
end
function ColorPicker:RunChanged()
if ParentObj.Disabled then
return
end
Library:SafeCallback(ColorPicker.Callback, ColorPicker.Value)
Library:SafeCallback(ColorPicker.Changed, ColorPicker.Value)
end
function ColorPicker:Update()
ColorPicker:Display()
local Disabled = ParentObj.Disabled == true
ApplyHolderVisual(Disabled)
if Disabled then
if ColorMenu.Active then
ColorMenu:Close()
end
if ContextMenu.Active then
ContextMenu:Close()
end
end
ColorPicker:RunChanged()
end
function ColorPicker:OnChanged(Func)
ColorPicker.Changed = Func
end
function ColorPicker:SetValue(HSV, Transparency)
if typeof(HSV) == "Color3" then
ColorPicker:SetValueRGB(HSV, Transparency)
return
end
local Color = Color3.fromHSV(HSV[1], HSV[2], HSV[3])
ColorPicker.Transparency = Info.Transparency and Transparency or 0
ColorPicker:SetHSVFromRGB(Color)
ColorPicker:Update()
end
function ColorPicker:SetValueRGB(Color, Transparency)
ColorPicker.Transparency = Info.Transparency and Transparency or 0
ColorPicker:SetHSVFromRGB(Color)
ColorPicker:Update()
end
table.insert(ColorPicker.Connections, Holder.MouseButton1Click:Connect(function()
if ParentObj.Disabled then
return
end
ColorMenu:Toggle()
end))
table.insert(ColorPicker.Connections, Holder.MouseButton2Click:Connect(function()
if ParentObj.Disabled then
return
end
ContextMenu:Toggle()
end))
table.insert(ColorPicker.Connections, SatVipMap.InputBegan:Connect(function(Input: InputObject)
while IsDragInput(Input) and not ColorPicker.Destroyed do
local MinX = SatVipMap.AbsolutePosition.X
local MaxX = MinX + SatVipMap.AbsoluteSize.X
local LocationX = math.clamp(Mouse.X, MinX, MaxX)
local MinY = SatVipMap.AbsolutePosition.Y
local MaxY = MinY + SatVipMap.AbsoluteSize.Y
local LocationY = math.clamp(Mouse.Y, MinY, MaxY)
local OldSat = ColorPicker.Sat
local OldVib = ColorPicker.Vib
ColorPicker.Sat = (LocationX - MinX) / (MaxX - MinX)
ColorPicker.Vib = 1 - ((LocationY - MinY) / (MaxY - MinY))
if ColorPicker.Sat ~= OldSat or ColorPicker.Vib ~= OldVib then
ColorPicker:Update()
end
RunService.RenderStepped:Wait()
end
end))
table.insert(ColorPicker.Connections, HueSelector.InputBegan:Connect(function(Input: InputObject)
while IsDragInput(Input) and not ColorPicker.Destroyed do
local Min = HueSelector.AbsolutePosition.Y
local Max = Min + HueSelector.AbsoluteSize.Y
local Location = math.clamp(Mouse.Y, Min, Max)
local OldHue = ColorPicker.Hue
ColorPicker.Hue = (Location - Min) / (Max - Min)
if ColorPicker.Hue ~= OldHue then
ColorPicker:Update()
end
RunService.RenderStepped:Wait()
end
end))
if TransparencySelector then
table.insert(ColorPicker.Connections, TransparencySelector.InputBegan:Connect(function(Input: InputObject)
while IsDragInput(Input) and not ColorPicker.Destroyed do
local Min = TransparencySelector.AbsolutePosition.Y
local Max = TransparencySelector.AbsolutePosition.Y + TransparencySelector.AbsoluteSize.Y
local Location = math.clamp(Mouse.Y, Min, Max)
local OldTransparency = ColorPicker.Transparency
ColorPicker.Transparency = (Location - Min) / (Max - Min)
if ColorPicker.Transparency ~= OldTransparency then
ColorPicker:Update()
end
RunService.RenderStepped:Wait()
end
end))
end
table.insert(ColorPicker.Connections, HueBox.FocusLost:Connect(function(Enter)
if not Enter then
return
end
local Success, Color = pcall(Color3.fromHex, HueBox.Text)
if Success and typeof(Color) == "Color3" then
ColorPicker.Hue, ColorPicker.Sat, ColorPicker.Vib = Color:ToHSV()
end
ColorPicker:Update()
end))
table.insert(ColorPicker.Connections, RgbBox.FocusLost:Connect(function(Enter)
if not Enter then
return
end
local R, G, B = RgbBox.Text:match("(%d+),%s*(%d+),%s*(%d+)")
if R and G and B then
ColorPicker:SetHSVFromRGB(Color3.fromRGB(R, G, B))
end
ColorPicker:Update()
end))
for _, BoxPair in {
{ HueBox, HueBoxStroke },
{ RgbBox, RgbBoxStroke }
} do
local TextBoxInstance, Stroke = BoxPair[1], BoxPair[2]
table.insert(ColorPicker.Connections, TextBoxInstance.Focused:Connect(function()
Library.Registry[Stroke].Color = "AccentColor"
TweenService:Create(Stroke, Library.TweenInfo, {
Color = Library.Scheme.AccentColor,
}):Play()
end))
table.insert(ColorPicker.Connections, TextBoxInstance.FocusLost:Connect(function()
Library.Registry[Stroke].Color = "OutlineColor"
TweenService:Create(Stroke, Library.TweenInfo, {
Color = Library.Scheme.OutlineColor,
}):Play()
end))
end
ColorPicker:Update()
if not ParentObj.Addons then
ParentObj.Addons = {}
end
table.insert(ParentObj.Addons, ColorPicker)
ColorPicker.Default = ColorPicker.Value
function ColorPicker:Destroy()
ColorPicker.Destroyed = true
if ColorPicker.Connections then
for _, Connection in ColorPicker.Connections do
Connection:Disconnect()
end
end
if ColorMenu then
ColorMenu:Destroy()
end
if ResizeGrabber then
ResizeGrabber:Destroy()
end
if ContextMenu then
ContextMenu:Destroy()
end
if Holder then
Holder:Destroy()
end
if ParentObj and ParentObj.Addons then
local AddonIdx = table.find(ParentObj.Addons, ColorPicker)
if AddonIdx then
table.remove(ParentObj.Addons, AddonIdx)
end
end
Options[Idx] = nil
end
Options[Idx] = ColorPicker
return self
end
BaseAddons.__index = Funcs
BaseAddons.__namecall = function(_, Key, ...)
return Funcs[Key](...)
end
end
local BaseGroupbox = {}
do
local Funcs = {}
function Funcs:AddDivider(...)
if self.Destroyed then return nil end
local Params = select(1, ...)
local Text
local MarginTop = 0
local MarginBottom = 0
if typeof(Params) == "table" then
Text = Params.Text
MarginTop = Params.MarginTop or Params.Margin or 0
MarginBottom = Params.MarginBottom or Params.Margin or 0
elseif typeof(Params) == "string" then
Text = Params
end
local Groupbox = self
local Container = Groupbox.Container
local Holder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 6 + MarginTop + MarginBottom),
Parent = Container,
})
local InnerHolder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 1, 0),
Parent = Holder,
})
New("UIPadding", {
PaddingTop = UDim.new(0, MarginTop),
PaddingBottom = UDim.new(0, MarginBottom),
Parent = Holder,
})
if Text then
local TextLabel = New("TextLabel", {
AutomaticSize = Enum.AutomaticSize.X,
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 0),
Text = Text,
TextSize = 14,
TextTransparency = 0.5,
TextXAlignment = Enum.TextXAlignment.Center,
Parent = InnerHolder,
})
local X, _ = Library:GetTextBounds(Text, TextLabel.FontFace, TextLabel.TextSize, TextLabel.AbsoluteSize.X / Library.DPIScale)
local SizeX = X // 2 + 10
New("Frame", {
AnchorPoint = Vector2.new(0, 0.5),
BackgroundColor3 = "MainColor",
BorderColor3 = "OutlineColor",
BorderSizePixel = 1,
Position = UDim2.fromScale(0, 0.5),
Size = UDim2.new(0.5, -SizeX, 0, 2),
Parent = InnerHolder,
})
New("Frame", {
AnchorPoint = Vector2.new(1, 0.5),
BackgroundColor3 = "MainColor",
BorderColor3 = "OutlineColor",
BorderSizePixel = 1,
Position = UDim2.fromScale(1, 0.5),
Size = UDim2.new(0.5, -SizeX, 0, 2),
Parent = InnerHolder,
})
else
New("Frame", {
AnchorPoint = Vector2.new(0, 0.5),
BackgroundColor3 = "MainColor",
BorderColor3 = "OutlineColor",
BorderSizePixel = 1,
Position = UDim2.fromScale(0, 0.5),
Size = UDim2.new(1, 0, 0, 2),
Parent = InnerHolder,
})
end
Groupbox:Resize()
local Divider = {
Connections = {},
Destroyed = false,
Holder = Holder,
Text = Text,
MarginTop = MarginTop,
MarginBottom = MarginBottom,
Type = "Divider",
Parent = Groupbox,
}
function Divider:SetVisible(Value)
Holder.Visible = Value == true
Groupbox:Resize()
end
function Divider:Destroy()
Divider.Destroyed = true
if Divider.Connections then
for _, Connection in Divider.Connections do
Connection:Disconnect()
end
end
if Holder then
Holder:Destroy()
end
local ElemIdx = table.find(Groupbox.Elements, Divider)
if ElemIdx then
table.remove(Groupbox.Elements, ElemIdx)
end
Groupbox:Resize()
end
table.insert(Groupbox.Elements, Divider)
return Divider
end
function Funcs:AddLabel(...)
if self.Destroyed then return nil end
local Data = {}
local Addons = {}
local First = select(1, ...)
local Second = select(2, ...)
if typeof(First) == "table" or typeof(Second) == "table" then
local Params = typeof(First) == "table" and First or Second
Data.Text = Params.Text or ""
Data.DoesWrap = Params.DoesWrap or false
Data.Size = Params.Size or 14
Data.Visible = if typeof(Params.Visible) == "boolean" then Params.Visible else true
Data.Idx = typeof(Second) == "table" and First or nil
else
Data.Text = First or ""
Data.DoesWrap = Second or false
Data.Size = 14
Data.Visible = true
Data.Idx = select(3, ...) or nil
end
local Groupbox = self
local Container = Groupbox.Container
local Label = {
Connections = {},
Destroyed = false,
Text = Data.Text,
DoesWrap = Data.DoesWrap,
Addons = Addons,
Visible = Data.Visible,
Type = "Label",
Parent = Groupbox,
}
local TextLabel = New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 18),
Text = Label.Text,
TextSize = Data.Size,
TextWrapped = Label.DoesWrap,
TextXAlignment = Groupbox.IsKeyTab and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left,
Visible = Label.Visible,
Parent = Container,
})
function Label:Display()
if not Label.DoesWrap then
return
end
local Width = TextLabel.AbsoluteSize.X / Library.DPIScale
if Width <= 0 then return end
local _, Y = Library:GetTextBounds(Label.Text, TextLabel.FontFace, TextLabel.TextSize, Width)
TextLabel.Size = UDim2.new(1, 0, 0, Y + 4)
end
function Label:SetVisible(Visible: boolean)
Label.Visible = Visible
TextLabel.Visible = Label.Visible
Groupbox:Resize()
end
function Label:SetText(Text: string)
Label.Text = Text
TextLabel.Text = Text
Label:Display()
Groupbox:Resize()
end
if Label.DoesWrap then
Label:Display()
local Last = TextLabel.AbsoluteSize
table.insert(Label.Connections, TextLabel:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
if TextLabel.AbsoluteSize == Last then
return
end
Label:Display()
Last = TextLabel.AbsoluteSize
Groupbox:Resize()
end))
else
New("UIListLayout", {
FillDirection = Enum.FillDirection.Horizontal,
HorizontalAlignment = Enum.HorizontalAlignment.Right,
Padding = UDim.new(0, 6),
Parent = TextLabel,
})
end
Groupbox:Resize()
Label.TextLabel = TextLabel
Label.Container = Container
if not Data.DoesWrap then
setmetatable(Label, BaseAddons)
end
Label.Holder = TextLabel
table.insert(Groupbox.Elements, Label)
if Data.Idx then
Labels[Data.Idx] = Label
else
table.insert(Labels, Label)
end
function Label:Destroy()
Label.Destroyed = true
if Label.Connections then
for _, Connection in Label.Connections do
Connection:Disconnect()
end
end
if Label.Addons then
for Index = #Label.Addons, 1, -1 do
local Addon = table.remove(Label.Addons, Index)
if Addon and Addon.Destroy then
Addon:Destroy()
end
end
end
if TextLabel then
TextLabel:Destroy()
end
local ElemIdx = table.find(Groupbox.Elements, Label)
if ElemIdx then
table.remove(Groupbox.Elements, ElemIdx)
end
Groupbox:Resize()
if Data.Idx then
Labels[Data.Idx] = nil
else
local LblIdx = table.find(Labels, Label)
if LblIdx then
table.remove(Labels, LblIdx)
end
end
end
return Label
end
function Funcs:AddButton(...)
if self.Destroyed then return nil end
local function GetInfo(...)
local Info = {}
local First = select(1, ...)
local Second = select(2, ...)
if typeof(First) == "table" or typeof(Second) == "table" then
local Params = typeof(First) == "table" and First or Second
Info.Text = Params.Text or ""
Info.Func = Params.Func or Params.Callback or function() end
Info.DoubleClick = Params.DoubleClick
Info.Icon = Params.Icon or Params.IconName
Info.Tooltip = Params.Tooltip
Info.DisabledTooltip = Params.DisabledTooltip
Info.Risky = Params.Risky or false
Info.Disabled = Params.Disabled or false
Info.Visible = if typeof(Params.Visible) == "boolean" then Params.Visible else true
Info.Idx = typeof(Second) == "table" and First or nil
else
Info.Text = First or ""
Info.Func = Second or function() end
Info.DoubleClick = false
Info.Icon = nil
Info.Tooltip = nil
Info.DisabledTooltip = nil
Info.Risky = false
Info.Disabled = false
Info.Visible = true
Info.Idx = select(3, ...) or nil
end
return Info
end
local Info = GetInfo(...)
local Groupbox = self
local Container = Groupbox.Container
local Button = {
Connections = {},
Destroyed = false,
Text = Info.Text,
Func = Info.Func,
DoubleClick = Info.DoubleClick,
Icon = Info.Icon,
Tooltip = Info.Tooltip,
DisabledTooltip = Info.DisabledTooltip,
TooltipTable = nil,
Risky = Info.Risky,
Disabled = Info.Disabled,
Visible = Info.Visible,
Locked = false,
Base = nil,
Stroke = nil,
Content = nil,
Label = nil,
IconImage = nil,
Tween = nil,
Type = "Button",
Parent = Groupbox,
}
local Holder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 21),
Parent = Container,
})
New("UIListLayout", {
FillDirection = Enum.FillDirection.Horizontal,
HorizontalFlex = Enum.UIFlexAlignment.Fill,
Padding = UDim.new(0, 9),
Parent = Holder,
})
local function ApplyButtonIcon(Button, IconName)
local Content = Button.Content
if not Content then
return
end
local ParsedIcon = Library:GetCustomIcon(IconName)
if ParsedIcon then
local ColorKey = Button.Risky and "RedColor" or (ParsedIcon.Custom and "WhiteColor" or "FontColor")
if not Button.IconImage then
Button.IconImage = New("ImageLabel", {
BackgroundTransparency = 1,
ImageColor3 = ColorKey,
LayoutOrder = 0,
Size = UDim2.fromOffset(14, 14),
Parent = Content,
})
else
Button.IconImage.ImageColor3 = Library.Scheme[ColorKey]
Library.Registry[Button.IconImage].ImageColor3 = ColorKey
end
Button.IconImage.ImageTransparency = Button.Disabled and 0.8 or 0.4
Button.IconImage.Visible = true
Library:ApplyLucideIcon(Button.IconImage, ParsedIcon)
elseif Button.IconImage then
Button.IconImage.Visible = false
end
end
local function CreateButton(Button)
local Base = New("TextButton", {
Active = not Button.Disabled,
BackgroundColor3 = Button.Disabled and "BackgroundColor" or "MainColor",
Size = UDim2.fromScale(1, 1),
Text = "",
Visible = Button.Visible,
Parent = Holder,
})
local Stroke = New("UIStroke", {
Color = "OutlineColor",
Transparency = Button.Disabled and 0.5 or 0,
Parent = Base,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = Base,
})
)
local Content = New("Frame", {
AnchorPoint = Vector2.new(0.5, 0.5),
AutomaticSize = Enum.AutomaticSize.X,
BackgroundTransparency = 1,
Position = UDim2.fromScale(0.5, 0.5),
Size = UDim2.fromOffset(0, 16),
Parent = Base,
})
New("UIListLayout", {
FillDirection = Enum.FillDirection.Horizontal,
HorizontalAlignment = Enum.HorizontalAlignment.Center,
VerticalAlignment = Enum.VerticalAlignment.Center,
Padding = UDim.new(0, 6),
Parent = Content,
})
New("UIPadding", {
PaddingLeft = UDim.new(0, 8),
PaddingRight = UDim.new(0, 8),
Parent = Content,
})
Button.Content = Content
Button.Label = New("TextLabel", {
AutomaticSize = Enum.AutomaticSize.X,
BackgroundTransparency = 1,
LayoutOrder = 1,
Size = UDim2.fromOffset(0, 16),
Text = Button.Text,
TextSize = 14,
TextTransparency = Button.Disabled and 0.8 or 0.4,
Parent = Content,
})
if Button.Risky then
Button.Label.TextColor3 = Library.Scheme.RedColor
Library.Registry[Button.Label].TextColor3 = "RedColor"
end
ApplyButtonIcon(Button, Button.Icon)
return Base, Stroke
end
local function InitEvents(Button)
table.insert(Button.Connections, Button.Base.MouseEnter:Connect(function()
if Button.Disabled then
return
end
Button.Tween = TweenService:Create(Button.Label, Library.TweenInfo, {
TextTransparency = 0,
})
Button.Tween:Play()
if Button.IconImage and Button.IconImage.Visible then
TweenService:Create(Button.IconImage, Library.TweenInfo, {
ImageTransparency = 0,
}):Play()
end
end))
table.insert(Button.Connections, Button.Base.MouseLeave:Connect(function()
if Button.Disabled then
return
end
Button.Tween = TweenService:Create(Button.Label, Library.TweenInfo, {
TextTransparency = 0.4,
})
Button.Tween:Play()
if Button.IconImage and Button.IconImage.Visible then
TweenService:Create(Button.IconImage, Library.TweenInfo, {
ImageTransparency = 0.4,
}):Play()
end
end))
table.insert(Button.Connections, Button.Base.MouseButton1Click:Connect(function()
if Button.Disabled or Button.Locked then
return
end
if Button.DoubleClick then
Button.Locked = true
local IconWasVisible = false
if Button.IconImage then
IconWasVisible = Button.IconImage.Visible
Button.IconImage.Visible = false
end
Button.Label.Text = "Are you sure?"
Button.Label.TextColor3 = Library.Scheme.AccentColor
Library.Registry[Button.Label].TextColor3 = "AccentColor"
local Clicked = WaitForEvent(Button.Base.MouseButton1Click, 0.5)
Button.Label.Text = Button.Text
Button.Label.TextColor3 = Button.Risky and Library.Scheme.RedColor or Library.Scheme.FontColor
Library.Registry[Button.Label].TextColor3 = Button.Risky and "RedColor" or "FontColor"
if Button.IconImage then
Button.IconImage.Visible = IconWasVisible
end
if Clicked then
Library:SafeCallback(Button.Func)
end
RunService.RenderStepped:Wait()
Button.Locked = false
return
end
Library:SafeCallback(Button.Func)
end))
end
Button.Base, Button.Stroke = CreateButton(Button)
InitEvents(Button)
function Button:AddButton(...)
local Info = GetInfo(...)
local SubButton = {
Connections = {},
Destroyed = false,
Text = Info.Text,
Func = Info.Func,
DoubleClick = Info.DoubleClick,
Icon = Info.Icon,
Tooltip = Info.Tooltip,
DisabledTooltip = Info.DisabledTooltip,
TooltipTable = nil,
Risky = Info.Risky,
Disabled = Info.Disabled,
Visible = Info.Visible,
Locked = false,
Base = nil,
Stroke = nil,
Content = nil,
Label = nil,
IconImage = nil,
Tween = nil,
Type = "SubButton",
}
Button.SubButton = SubButton
SubButton.Base, SubButton.Stroke = CreateButton(SubButton)
InitEvents(SubButton)
function SubButton:UpdateColors()
if Library.Unloaded then
return
end
StopTween(SubButton.Tween)
SubButton.Base.BackgroundColor3 = SubButton.Disabled and Library.Scheme.BackgroundColor or Library.Scheme.MainColor
SubButton.Label.TextTransparency = SubButton.Disabled and 0.8 or 0.4
SubButton.Stroke.Transparency = SubButton.Disabled and 0.5 or 0
if SubButton.IconImage and SubButton.IconImage.Visible then
SubButton.IconImage.ImageTransparency = SubButton.Disabled and 0.8 or 0.4
end
Library.Registry[SubButton.Base].BackgroundColor3 = SubButton.Disabled and "BackgroundColor"
or "MainColor"
end
function SubButton:SetDisabled(Disabled: boolean)
SubButton.Disabled = Disabled
if SubButton.TooltipTable then
SubButton.TooltipTable.Disabled = SubButton.Disabled
end
SubButton.Base.Active = not SubButton.Disabled
SubButton:UpdateColors()
Library:UpdateAddons(SubButton)
end
function SubButton:SetVisible(Visible: boolean)
SubButton.Visible = Visible
SubButton.Base.Visible = SubButton.Visible
Groupbox:Resize()
end
function SubButton:SetText(Text: string)
SubButton.Text = Text
SubButton.Label.Text = Text
end
function SubButton:SetIcon(Icon: string?)
SubButton.Icon = Icon
ApplyButtonIcon(SubButton, Icon)
end
if typeof(SubButton.Tooltip) == "string" or typeof(SubButton.DisabledTooltip) == "string" then
SubButton.TooltipTable =
Library:AddTooltip(SubButton.Tooltip, SubButton.DisabledTooltip, SubButton.Base)
SubButton.TooltipTable.Disabled = SubButton.Disabled
end
SubButton:UpdateColors()
if Info.Idx then
Buttons[Info.Idx] = SubButton
else
table.insert(Buttons, SubButton)
end
SubButton.AddKeyPicker = BaseAddons.__index.AddKeyPicker
function SubButton:Destroy()
SubButton.Destroyed = true
if SubButton.Connections then
for _, Connection in SubButton.Connections do
Connection:Disconnect()
end
end
if SubButton.TooltipTable then
SubButton.TooltipTable:Destroy()
end
if SubButton.Tween then
SubButton.Tween:Destroy()
end
if SubButton.Base then
SubButton.Base:Destroy()
end
if Info.Idx then
Buttons[Info.Idx] = nil
else
local BIdx = table.find(Buttons, SubButton)
if BIdx then
table.remove(Buttons, BIdx)
end
end
end
return SubButton
end
function Button:UpdateColors()
if Library.Unloaded then
return
end
StopTween(Button.Tween)
Button.Base.BackgroundColor3 = Button.Disabled and Library.Scheme.BackgroundColor or Library.Scheme.MainColor
Button.Label.TextTransparency = Button.Disabled and 0.8 or 0.4
Button.Stroke.Transparency = Button.Disabled and 0.5 or 0
if Button.IconImage and Button.IconImage.Visible then
Button.IconImage.ImageTransparency = Button.Disabled and 0.8 or 0.4
end
Library.Registry[Button.Base].BackgroundColor3 = Button.Disabled and "BackgroundColor" or "MainColor"
end
function Button:SetDisabled(Disabled: boolean)
Button.Disabled = Disabled
if Button.TooltipTable then
Button.TooltipTable.Disabled = Button.Disabled
end
Button.Base.Active = not Button.Disabled
Button:UpdateColors()
Library:UpdateAddons(Button)
end
function Button:SetVisible(Visible: boolean)
Button.Visible = Visible
Holder.Visible = Button.Visible
Groupbox:Resize()
end
function Button:SetText(Text: string)
Button.Text = Text
Button.Label.Text = Text
end
function Button:SetIcon(Icon: string?)
Button.Icon = Icon
ApplyButtonIcon(Button, Icon)
end
if typeof(Button.Tooltip) == "string" or typeof(Button.DisabledTooltip) == "string" then
Button.TooltipTable = Library:AddTooltip(Button.Tooltip, Button.DisabledTooltip, Button.Base)
Button.TooltipTable.Disabled = Button.Disabled
end
Button:UpdateColors()
Groupbox:Resize()
Button.Holder = Holder
table.insert(Groupbox.Elements, Button)
if Info.Idx then
Buttons[Info.Idx] = Button
else
table.insert(Buttons, Button)
end
Button.AddKeyPicker = BaseAddons.__index.AddKeyPicker
function Button:Destroy()
Button.Destroyed = true
if Button.Connections then
for _, Connection in Button.Connections do
Connection:Disconnect()
end
end
if Button.TooltipTable then
Button.TooltipTable:Destroy()
end
if Button.Tween then
Button.Tween:Destroy()
end
if Button.SubButton then
Button.SubButton:Destroy()
end
if Holder then
Holder:Destroy()
end
local ElemIdx = table.find(Groupbox.Elements, Button)
if ElemIdx then
table.remove(Groupbox.Elements, ElemIdx)
end
Groupbox:Resize()
if Info.Idx then
Buttons[Info.Idx] = nil
else
local BIdx = table.find(Buttons, Button)
if BIdx then
table.remove(Buttons, BIdx)
end
end
end
return Button
end
function Funcs:AddCheckbox(Idx, Info)
if self.Destroyed then return nil end
Info = Library:Validate(Info, Templates.Toggle)
local Groupbox = self
local Container = Groupbox.Container
local Toggle = {
Connections = {},
Destroyed = false,
Text = Info.Text,
Value = Info.Default,
Tooltip = Info.Tooltip,
DisabledTooltip = Info.DisabledTooltip,
TooltipTable = nil,
Callback = Info.Callback,
Changed = Info.Changed,
Risky = Info.Risky,
Disabled = Info.Disabled,
Visible = Info.Visible,
Addons = {},
AnyKeyPickerPicking = false,
Variant = "Checkbox",
Type = "Toggle",
Parent = Groupbox,
}
local Button = New("TextButton", {
Active = not Toggle.Disabled,
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 18),
Text = "",
Visible = Toggle.Visible,
Parent = Container,
})
local Label = New("TextLabel", {
BackgroundTransparency = 1,
Position = UDim2.fromOffset(26, 0),
Size = UDim2.new(1, -26, 1, 0),
Text = Toggle.Text,
TextSize = 14,
TextTransparency = 0.4,
TextXAlignment = Enum.TextXAlignment.Left,
Parent = Button,
})
New("UIListLayout", {
FillDirection = Enum.FillDirection.Horizontal,
HorizontalAlignment = Enum.HorizontalAlignment.Right,
Padding = UDim.new(0, 6),
Parent = Label,
})
local Checkbox = New("Frame", {
BackgroundColor3 = "MainColor",
Size = UDim2.fromScale(1, 1),
SizeConstraint = Enum.SizeConstraint.RelativeYY,
Parent = Button,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = Checkbox,
})
)
local CheckboxStroke = New("UIStroke", {
Color = "OutlineColor",
Parent = Checkbox,
})
local CheckImage = New("ImageLabel", {
ImageColor3 = "FontColor",
ImageTransparency = 1,
Position = UDim2.fromOffset(2, 2),
Size = UDim2.new(1, -4, 1, -4),
Parent = Checkbox,
})
if CheckIcon then
Library:ApplyLucideIcon(CheckImage, CheckIcon)
end
function Toggle:UpdateColors()
Toggle:Display()
end
function Toggle:Display()
if Library.Unloaded then
return
end
CheckboxStroke.Transparency = Toggle.Disabled and 0.5 or 0
if Toggle.Disabled then
Label.TextTransparency = 0.8
CheckImage.ImageTransparency = Toggle.Value and 0.8 or 1
Checkbox.BackgroundColor3 = Library.Scheme.BackgroundColor
Library.Registry[Checkbox].BackgroundColor3 = "BackgroundColor"
return
end
TweenService:Create(Label, Library.TweenInfo, {
TextTransparency = Toggle.Value and 0 or 0.4,
}):Play()
TweenService:Create(CheckImage, Library.TweenInfo, {
ImageTransparency = Toggle.Value and 0 or 1,
}):Play()
Checkbox.BackgroundColor3 = Library.Scheme.MainColor
Library.Registry[Checkbox].BackgroundColor3 = "MainColor"
end
function Toggle:OnChanged(Func)
Toggle.Changed = Func
end
function Toggle:RunChanged()
if Toggle.Disabled then
return
end
Library:SafeCallback(Toggle.Callback, Toggle.Value)
Library:SafeCallback(Toggle.Changed, Toggle.Value)
end
function Toggle:SetValue(Value)
Toggle.Value = Value
Toggle:Display()
for _, Addon in Toggle.Addons do
if Addon.Type == "KeyPicker" and Addon.SyncToggleState then
Addon.Toggled = Toggle.Value
Addon:Update()
end
end
if not Toggle.Disabled then
Library:UpdateDependencyBoxes()
end
if not Toggle.AnyKeyPickerPicking then
Toggle:RunChanged()
end
end
function Toggle:SetDisabled(Disabled: boolean)
Toggle.Disabled = Disabled
if Toggle.TooltipTable then
Toggle.TooltipTable.Disabled = Toggle.Disabled
end
Library:UpdateAddons(Toggle)
Button.Active = not Toggle.Disabled
Toggle:Display()
Library:UpdateDependencyBoxes()
end
function Toggle:SetVisible(Visible: boolean)
Toggle.Visible = Visible
Button.Visible = Toggle.Visible
Groupbox:Resize()
end
function Toggle:SetText(Text: string)
Toggle.Text = Text
Label.Text = Text
end
table.insert(Toggle.Connections, Button.MouseButton1Click:Connect(function()
if Toggle.Disabled then
return
end
Toggle:SetValue(not Toggle.Value)
end))
if typeof(Toggle.Tooltip) == "string" or typeof(Toggle.DisabledTooltip) == "string" then
Toggle.TooltipTable = Library:AddTooltip(Toggle.Tooltip, Toggle.DisabledTooltip, Button)
Toggle.TooltipTable.Disabled = Toggle.Disabled
end
if Toggle.Risky then
Label.TextColor3 = Library.Scheme.RedColor
Library.Registry[Label].TextColor3 = "RedColor"
end
Toggle:Display()
Groupbox:Resize()
Toggle.TextLabel = Label
Toggle.Container = Container
setmetatable(Toggle, BaseAddons)
Toggle.Holder = Button
table.insert(Groupbox.Elements, Toggle)
Toggle.Default = Toggle.Value
Toggles[Idx] = Toggle
function Toggle:Destroy()
Toggle.Destroyed = true
if Toggle.Connections then
for _, Connection in Toggle.Connections do
Connection:Disconnect()
end
end
if Toggle.TooltipTable then
Toggle.TooltipTable:Destroy()
end
if Button then
Button:Destroy()
end
if Toggle.Addons then
for Index = #Toggle.Addons, 1, -1 do
local Addon = table.remove(Toggle.Addons, Index)
if Addon and Addon.Destroy then
Addon:Destroy()
end
end
end
local ElemIdx = table.find(Groupbox.Elements, Toggle)
if ElemIdx then
table.remove(Groupbox.Elements, ElemIdx)
end
Groupbox:Resize()
Toggles[Idx] = nil
end
return Toggle
end
function Funcs:AddToggle(Idx, Info)
if self.Destroyed then return nil end
if Library.ForceCheckbox then
return Funcs.AddCheckbox(self, Idx, Info)
end
Info = Library:Validate(Info, Templates.Toggle)
local Groupbox = self
local Container = Groupbox.Container
local Toggle = {
Connections = {},
Destroyed = false,
Text = Info.Text,
Value = Info.Default,
Tooltip = Info.Tooltip,
DisabledTooltip = Info.DisabledTooltip,
TooltipTable = nil,
Callback = Info.Callback,
Changed = Info.Changed,
Risky = Info.Risky,
Disabled = Info.Disabled,
Visible = Info.Visible,
Addons = {},
AnyKeyPickerPicking = false,
Variant = "Switch",
Type = "Toggle",
Parent = Groupbox,
}
local Button = New("TextButton", {
Active = not Toggle.Disabled,
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 18),
Text = "",
Visible = Toggle.Visible,
Parent = Container,
})
local Label = New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.new(1, -40, 1, 0),
Text = Toggle.Text,
TextSize = 14,
TextTransparency = 0.4,
TextXAlignment = Enum.TextXAlignment.Left,
Parent = Button,
})
New("UIListLayout", {
FillDirection = Enum.FillDirection.Horizontal,
HorizontalAlignment = Enum.HorizontalAlignment.Right,
Padding = UDim.new(0, 6),
Parent = Label,
})
local Switch = New("Frame", {
AnchorPoint = Vector2.new(1, 0),
BackgroundColor3 = "MainColor",
Position = UDim2.fromScale(1, 0),
Size = UDim2.fromOffset(32, 18),
Parent = Button,
})
New("UICorner", {
CornerRadius = UDim.new(1, 0),
Parent = Switch,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 2),
PaddingLeft = UDim.new(0, 2),
PaddingRight = UDim.new(0, 2),
PaddingTop = UDim.new(0, 2),
Parent = Switch,
})
local SwitchStroke = New("UIStroke", {
Color = "OutlineColor",
Parent = Switch,
})
local Ball = New("Frame", {
BackgroundColor3 = "FontColor",
Size = UDim2.fromScale(1, 1),
SizeConstraint = Enum.SizeConstraint.RelativeYY,
Parent = Switch,
})
New("UICorner", {
CornerRadius = UDim.new(1, 0),
Parent = Ball,
})
function Toggle:UpdateColors()
Toggle:Display()
end
function Toggle:Display()
if Library.Unloaded then
return
end
local Offset = Toggle.Value and 1 or 0
Switch.BackgroundTransparency = Toggle.Disabled and 0.75 or 0
SwitchStroke.Transparency = Toggle.Disabled and 0.75 or 0
Switch.BackgroundColor3 = Toggle.Value and Library.Scheme.AccentColor or Library.Scheme.MainColor
SwitchStroke.Color = Toggle.Value and Library.Scheme.AccentColor or Library.Scheme.OutlineColor
Library.Registry[Switch].BackgroundColor3 = Toggle.Value and "AccentColor" or "MainColor"
Library.Registry[SwitchStroke].Color = Toggle.Value and "AccentColor" or "OutlineColor"
if Toggle.Disabled then
Label.TextTransparency = 0.8
Ball.AnchorPoint = Vector2.new(Offset, 0)
Ball.Position = UDim2.fromScale(Offset, 0)
Ball.BackgroundColor3 = Library:GetDarkerColor(Library.Scheme.FontColor)
Library.Registry[Ball].BackgroundColor3 = function()
return Library:GetDarkerColor(Library.Scheme.FontColor)
end
return
end
TweenService:Create(Label, Library.TweenInfo, {
TextTransparency = Toggle.Value and 0 or 0.4,
}):Play()
TweenService:Create(Ball, Library.TweenInfo, {
AnchorPoint = Vector2.new(Offset, 0),
Position = UDim2.fromScale(Offset, 0),
}):Play()
Ball.BackgroundColor3 = Library.Scheme.FontColor
Library.Registry[Ball].BackgroundColor3 = "FontColor"
end
function Toggle:OnChanged(Func)
Toggle.Changed = Func
end
function Toggle:RunChanged()
if Toggle.Disabled then
return
end
Library:SafeCallback(Toggle.Callback, Toggle.Value)
Library:SafeCallback(Toggle.Changed, Toggle.Value)
end
function Toggle:SetValue(Value)
Toggle.Value = Value
Toggle:Display()
for _, Addon in Toggle.Addons do
if Addon.Type == "KeyPicker" and Addon.SyncToggleState then
Addon.Toggled = Toggle.Value
Addon:Update()
end
end
if not Toggle.Disabled then
Library:UpdateDependencyBoxes()
end
if not Toggle.AnyKeyPickerPicking then
Toggle:RunChanged()
end
end
function Toggle:SetDisabled(Disabled: boolean)
Toggle.Disabled = Disabled
if Toggle.TooltipTable then
Toggle.TooltipTable.Disabled = Toggle.Disabled
end
Library:UpdateAddons(Toggle)
Button.Active = not Toggle.Disabled
Toggle:Display()
Library:UpdateDependencyBoxes()
end
function Toggle:SetVisible(Visible: boolean)
Toggle.Visible = Visible
Button.Visible = Toggle.Visible
Groupbox:Resize()
end
function Toggle:SetText(Text: string)
Toggle.Text = Text
Label.Text = Text
end
table.insert(Toggle.Connections, Button.MouseButton1Click:Connect(function()
if Toggle.Disabled then
return
end
Toggle:SetValue(not Toggle.Value)
end))
if typeof(Toggle.Tooltip) == "string" or typeof(Toggle.DisabledTooltip) == "string" then
Toggle.TooltipTable = Library:AddTooltip(Toggle.Tooltip, Toggle.DisabledTooltip, Button)
Toggle.TooltipTable.Disabled = Toggle.Disabled
end
if Toggle.Risky then
Label.TextColor3 = Library.Scheme.RedColor
Library.Registry[Label].TextColor3 = "RedColor"
end
Toggle:Display()
Groupbox:Resize()
Toggle.TextLabel = Label
Toggle.Container = Container
setmetatable(Toggle, BaseAddons)
Toggle.Holder = Button
table.insert(Groupbox.Elements, Toggle)
Toggle.Default = Toggle.Value
Toggles[Idx] = Toggle
function Toggle:Destroy()
Toggle.Destroyed = true
if Toggle.Connections then
for _, Connection in Toggle.Connections do
Connection:Disconnect()
end
end
if Toggle.TooltipTable then
Toggle.TooltipTable:Destroy()
end
if Button then
Button:Destroy()
end
if Toggle.Addons then
for Index = #Toggle.Addons, 1, -1 do
local Addon = table.remove(Toggle.Addons, Index)
if Addon and Addon.Destroy then
Addon:Destroy()
end
end
end
local ElemIdx = table.find(Groupbox.Elements, Toggle)
if ElemIdx then
table.remove(Groupbox.Elements, ElemIdx)
end
Groupbox:Resize()
Toggles[Idx] = nil
end
return Toggle
end
function Funcs:AddInput(Idx, Info)
if self.Destroyed then return nil end
if typeof(Info) == "table" and (typeof(Info.VerifyValue) == "function" and Info.Finished ~= true) then
Info.Finished = true
end
Info = Library:Validate(Info, Templates.Input)
local Groupbox = self
local Container = Groupbox.Container
local Input = {
Connections = {},
Destroyed = false,
Text = Info.Text,
Value = Info.Default,
Finished = Info.Finished,
Numeric = Info.Numeric,
ClearTextOnFocus = Info.ClearTextOnFocus,
ClearTextOnBlur = Info.ClearTextOnBlur,
Placeholder = Info.Placeholder,
AllowEmpty = Info.AllowEmpty,
EmptyReset = Info.EmptyReset,
Tooltip = Info.Tooltip,
DisabledTooltip = Info.DisabledTooltip,
TooltipTable = nil,
Callback = Info.Callback,
Changed = Info.Changed,
VerifyValue = Info.VerifyValue,
Disabled = Info.Disabled,
Visible = Info.Visible,
Type = "Input",
}
local Holder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 39),
Visible = Input.Visible,
Parent = Container,
})
local Label = New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 14),
Text = Input.Text,
TextSize = 14,
TextXAlignment = Enum.TextXAlignment.Left,
Parent = Holder,
})
local Box = New("TextBox", {
AnchorPoint = Vector2.new(0, 1),
BackgroundColor3 = "MainColor",
ClearTextOnFocus = not Input.Disabled and Input.ClearTextOnFocus,
PlaceholderText = Input.Placeholder,
Position = UDim2.fromScale(0, 1),
Size = UDim2.new(1, 0, 0, 21),
Text = Input.Value,
TextEditable = not Input.Disabled,
TextScaled = true,
TextXAlignment = Enum.TextXAlignment.Left,
Parent = Holder,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 3),
PaddingLeft = UDim.new(0, 8),
PaddingRight = UDim.new(0, 8),
PaddingTop = UDim.new(0, 4),
Parent = Box,
})
local BoxStroke = New("UIStroke", {
Color = "OutlineColor",
Parent = Box,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = Box,
})
)
function Input:UpdateColors()
if Library.Unloaded then
return
end
Label.TextTransparency = Input.Disabled and 0.8 or 0
Box.TextTransparency = Input.Disabled and 0.8 or 0
BoxStroke.Transparency = Input.Disabled and 0.5 or 0
Box.BackgroundColor3 = Input.Disabled and Library.Scheme.BackgroundColor or Library.Scheme.MainColor
Library.Registry[Box].BackgroundColor3 = Input.Disabled and "BackgroundColor" or "MainColor"
end
function Input:OnChanged(Func)
Input.Changed = Func
end
function Input:RunChanged()
if Input.Disabled then
return
end
Library:SafeCallback(Input.Callback, Input.Value)
Library:SafeCallback(Input.Changed, Input.Value)
end
function Input:SetValue(Text)
if not Input.AllowEmpty and Trim(Text) == "" then
Text = Input.EmptyReset
end
if Info.MaxLength and #Text > Info.MaxLength then
Text = Text:sub(1, Info.MaxLength)
end
if Input.Numeric then
if #tostring(Text) > 0 and not tonumber(Text) then
Text = Input.Value
end
end
if typeof(Info.VerifyValue) == "function" and (Text ~= Input.EmptyReset and Info.VerifyValue(Text) ~= true) then
Text = Input.EmptyReset
end
Input.Value = Text
Box.Text = Text
Input:RunChanged()
end
function Input:SetDisabled(Disabled: boolean)
Input.Disabled = Disabled
if Input.TooltipTable then
Input.TooltipTable.Disabled = Input.Disabled
end
Box.ClearTextOnFocus = not Input.Disabled and Input.ClearTextOnFocus
Box.TextEditable = not Input.Disabled
Input:UpdateColors()
end
function Input:SetVisible(Visible: boolean)
Input.Visible = Visible
Holder.Visible = Input.Visible
Groupbox:Resize()
end
function Input:SetText(Text: string)
Input.Text = Text
Label.Text = Text
end
if Input.Finished then
table.insert(Input.Connections, Box.FocusLost:Connect(function(Enter)
if not Enter then
if Input.ClearTextOnBlur then
Box.Text = Input.Value
end
return
end
Input:SetValue(Box.Text)
end))
else
table.insert(Input.Connections, Box:GetPropertyChangedSignal("Text"):Connect(function()
if Box.Text == Input.Value then return end
Input:SetValue(Box.Text)
end))
end
table.insert(Input.Connections, Box.Focused:Connect(function()
if Input.Disabled then
return
end
Library.Registry[BoxStroke].Color = "AccentColor"
TweenService:Create(BoxStroke, Library.TweenInfo, {
Color = Library.Scheme.AccentColor,
}):Play()
end))
table.insert(Input.Connections, Box.FocusLost:Connect(function()
if Input.Disabled then
return
end
Library.Registry[BoxStroke].Color = "OutlineColor"
TweenService:Create(BoxStroke, Library.TweenInfo, {
Color = Library.Scheme.OutlineColor,
}):Play()
end))
if typeof(Input.Tooltip) == "string" or typeof(Input.DisabledTooltip) == "string" then
Input.TooltipTable = Library:AddTooltip(Input.Tooltip, Input.DisabledTooltip, Box)
Input.TooltipTable.Disabled = Input.Disabled
end
Groupbox:Resize()
Input.Holder = Holder
table.insert(Groupbox.Elements, Input)
Input.Default = Input.Value
if typeof(Info.VerifyValue) == "function" and (Input.Default ~= Input.EmptyReset and Info.VerifyValue(Input.Default) ~= true) then
Input:SetValue(Input.EmptyReset)
Input.Default = Input.EmptyReset
end
Input:UpdateColors()
Options[Idx] = Input
function Input:Destroy()
Input.Destroyed = true
if Input.Connections then
for _, Connection in Input.Connections do
Connection:Disconnect()
end
end
if Input.TooltipTable then
Input.TooltipTable:Destroy()
end
if Holder then
Holder:Destroy()
end
local ElemIdx = table.find(Groupbox.Elements, Input)
if ElemIdx then
table.remove(Groupbox.Elements, ElemIdx)
end
Groupbox:Resize()
Options[Idx] = nil
end
return Input
end
function Funcs:AddSlider(Idx, Info)
if self.Destroyed then return nil end
Info = Library:Validate(Info, Templates.Slider)
local Groupbox = self
local Container = Groupbox.Container
local Slider = {
Connections = {},
Destroyed = false,
Text = Info.Text,
Value = Info.Default,
Min = Info.Min,
Max = Info.Max,
Prefix = Info.Prefix,
Suffix = Info.Suffix,
Compact = Info.Compact,
Rounding = Info.Rounding,
HideMax = Info.HideMax,
Tooltip = Info.Tooltip,
DisabledTooltip = Info.DisabledTooltip,
TooltipTable = nil,
Callback = Info.Callback,
Changed = Info.Changed,
Disabled = Info.Disabled,
Visible = Info.Visible,
AllowRightClickInput = Info.AllowRightClickInput,
Type = "Slider",
}
local Holder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, Info.Compact and 15 or 33),
Visible = Slider.Visible,
Parent = Container,
})
local SliderLabel
if not Info.Compact then
SliderLabel = New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 14),
Text = Slider.Text,
TextSize = 14,
TextXAlignment = Enum.TextXAlignment.Left,
Parent = Holder,
})
end
local Bar = New("TextButton", {
Active = not Slider.Disabled,
AnchorPoint = Vector2.new(0, 1),
BackgroundColor3 = "MainColor",
Position = UDim2.fromScale(0, 1),
Size = UDim2.new(1, 0, 0, 15),
Text = "",
Parent = Holder,
})
New("UIStroke", {
Color = "OutlineColor",
Parent = Bar,
})
local DisplayLabel = New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 1),
Text = "",
TextSize = 14,
ZIndex = Bar.ZIndex + 2,
Parent = Bar,
})
New("UIStroke", {
ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
Color = "DarkColor",
LineJoinMode = Enum.LineJoinMode.Miter,
Parent = DisplayLabel,
})
local InputTextBox
local InputTextBoxStroke
if Info.AllowRightClickInput then
InputTextBox = New("TextBox", {
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 1),
Text = "",
TextSize = 14,
ZIndex = Bar.ZIndex + 3,
Visible = false,
ClearTextOnFocus = false,
Parent = Bar,
})
InputTextBoxStroke = New("UIStroke", {
ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
Color = "DarkColor",
LineJoinMode = Enum.LineJoinMode.Miter,
Parent = InputTextBox,
})
end
local Fill = New("Frame", {
BackgroundColor3 = "AccentColor",
Size = UDim2.fromScale(0.5, 1),
ZIndex = Bar.ZIndex + 1,
Parent = Bar,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = Bar,
})
)
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = Fill,
})
)
function Slider:UpdateColors()
if Library.Unloaded then
return
end
if SliderLabel then
SliderLabel.TextTransparency = Slider.Disabled and 0.8 or 0
end
DisplayLabel.TextTransparency = Slider.Disabled and 0.8 or 0
if Info.AllowRightClickInput then
InputTextBox.TextTransparency = Slider.Disabled and 0.8 or 0
end
Fill.BackgroundColor3 = Slider.Disabled and Library.Scheme.OutlineColor or Library.Scheme.AccentColor
Library.Registry[Fill].BackgroundColor3 = Slider.Disabled and "OutlineColor" or "AccentColor"
end
function Slider:Display()
if Library.Unloaded then
return
end
local CustomDisplayText = nil
if Info.FormatDisplayValue then
CustomDisplayText = Info.FormatDisplayValue(Slider, Slider.Value)
end
if CustomDisplayText then
DisplayLabel.Text = tostring(CustomDisplayText)
else
if Info.Compact then
DisplayLabel.Text =
string.format("%s: %s%s%s", Slider.Text, Slider.Prefix, Slider.Value, Slider.Suffix)
elseif Info.HideMax then
DisplayLabel.Text = string.format("%s%s%s", Slider.Prefix, Slider.Value, Slider.Suffix)
else
DisplayLabel.Text = string.format(
"%s%s%s/%s%s%s",
Slider.Prefix,
Slider.Value,
Slider.Suffix,
Slider.Prefix,
Slider.Max,
Slider.Suffix
)
end
end
local X = (Slider.Value - Slider.Min) / (Slider.Max - Slider.Min)
Fill.Size = UDim2.fromScale(X, 1)
end
function Slider:OnChanged(Func)
Slider.Changed = Func
end
function Slider:SetMax(Value)
assert(Value > Slider.Min, "Max value cannot be less than the current min value.")
Slider:SetValue(math.clamp(Slider.Value, Slider.Min, Value))
Slider.Max = Value
Slider:Display()
end
function Slider:SetMin(Value)
assert(Value < Slider.Max, "Min value cannot be greater than the current max value.")
Slider:SetValue(math.clamp(Slider.Value, Value, Slider.Max))
Slider.Min = Value
Slider:Display()
end
function Slider:RunChanged()
if Slider.Disabled then
return
end
Library:SafeCallback(Slider.Callback, Slider.Value)
Library:SafeCallback(Slider.Changed, Slider.Value)
end
function Slider:SetValue(Str)
local Num = tonumber(Str)
if not Num or Num == Slider.Value then
return
end
Num = math.clamp(Num, Slider.Min, Slider.Max)
Slider.Value = Num
Slider:Display()
Slider:RunChanged()
end
function Slider:SetDisabled(Disabled: boolean)
Slider.Disabled = Disabled
if Slider.TooltipTable then
Slider.TooltipTable.Disabled = Slider.Disabled
end
Bar.Active = not Slider.Disabled
Slider:UpdateColors()
end
function Slider:SetVisible(Visible: boolean)
Slider.Visible = Visible
Holder.Visible = Slider.Visible
Groupbox:Resize()
end
function Slider:SetText(Text: string)
Slider.Text = Text
if SliderLabel then
SliderLabel.Text = Text
return
end
Slider:Display()
end
function Slider:SetPrefix(Prefix: string)
Slider.Prefix = Prefix
Slider:Display()
end
function Slider:SetSuffix(Suffix: string)
Slider.Suffix = Suffix
Slider:Display()
end
if Info.AllowRightClickInput then
local LastValidText = ""
table.insert(Slider.Connections, InputTextBox:GetPropertyChangedSignal("Text"):Connect(function()
local Text = InputTextBox.Text
local AsNum = tonumber(Text)
if #tostring(Text) > 0 and not AsNum and Text ~= "-" then
InputTextBox.Text = LastValidText
else
if Slider.Rounding == 0 and Text:find("%.") then
InputTextBox.Text = LastValidText
return
end
local DecimalPos = Text:find("%.")
if DecimalPos and Slider.Rounding > 0 then
local Decimals = #Text - DecimalPos
if Decimals > Slider.Rounding then
InputTextBox.Text = LastValidText
return
end
end
LastValidText = Text
if AsNum then
if AsNum > Slider.Max then
InputTextBox.Text = tostring(Slider.Max)
elseif AsNum < Slider.Min then
InputTextBox.Text = tostring(Slider.Min)
end
end
end
end))
table.insert(Slider.Connections, InputTextBox.FocusLost:Connect(function()
InputTextBox.Visible = false
DisplayLabel.Visible = true
local Num = tonumber(InputTextBox.Text)
if not Num then
return
end
Num = Round(Num, Slider.Rounding)
Slider:SetValue(Num)
end))
table.insert(Slider.Connections, InputTextBox.Focused:Connect(function()
if Slider.Disabled then
return
end
Library.Registry[InputTextBoxStroke].Color = "AccentColor"
TweenService:Create(InputTextBoxStroke, Library.TweenInfo, {
Color = Library.Scheme.AccentColor,
}):Play()
end))
table.insert(Slider.Connections, InputTextBox.FocusLost:Connect(function()
if Slider.Disabled then
return
end
Library.Registry[InputTextBoxStroke].Color = "DarkColor"
TweenService:Create(InputTextBoxStroke, Library.TweenInfo, {
Color = Library.Scheme.DarkColor,
}):Play()
end))
end
local LastTap = 0
table.insert(Slider.Connections, Bar.InputBegan:Connect(function(Input: InputObject)
local ValidInput = IsClickInput(Input) or Input.UserInputType == Enum.UserInputType.MouseButton2
if not ValidInput or Slider.Disabled then
return
end
if Info.AllowRightClickInput then
local IsRightClick = Input.UserInputType == Enum.UserInputType.MouseButton2
local IsDoubleTap = false
if Library.IsMobile and Input.UserInputType == Enum.UserInputType.Touch then
if tick() - LastTap < 0.3 then
IsDoubleTap = true
end
LastTap = tick()
end
if IsRightClick or IsDoubleTap then
InputTextBox.Text = tostring(Slider.Value)
InputTextBox.Visible = true
DisplayLabel.Visible = false
task.spawn(InputTextBox.CaptureFocus, InputTextBox)
return
end
end
if not IsClickInput(Input) then
return
end
if Library.ActiveTab then
for _, Side in Library.ActiveTab.Sides do
Side.ScrollingEnabled = false
end
end
if Library.ActiveLoading and Library.ActiveLoading.Sidebar then
Library.ActiveLoading.Sidebar.Container.ScrollingEnabled = false
end
while IsDragInput(Input) and not Slider.Destroyed do
local Location = Mouse.X
local Scale = math.clamp((Location - Bar.AbsolutePosition.X) / Bar.AbsoluteSize.X, 0, 1)
local OldValue = Slider.Value
Slider.Value = Round(Slider.Min + ((Slider.Max - Slider.Min) * Scale), Slider.Rounding)
Slider:Display()
if Slider.Value ~= OldValue then
Slider:RunChanged()
end
RunService.RenderStepped:Wait()
end
if Library.ActiveTab then
for _, Side in Library.ActiveTab.Sides do
Side.ScrollingEnabled = true
end
end
if Library.ActiveLoading and Library.ActiveLoading.Sidebar then
Library.ActiveLoading.Sidebar.Container.ScrollingEnabled = true
end
end))
if typeof(Slider.Tooltip) == "string" or typeof(Slider.DisabledTooltip) == "string" then
Slider.TooltipTable = Library:AddTooltip(Slider.Tooltip, Slider.DisabledTooltip, Bar)
Slider.TooltipTable.Disabled = Slider.Disabled
end
Slider:UpdateColors()
Slider:Display()
Groupbox:Resize()
Slider.Holder = Holder
table.insert(Groupbox.Elements, Slider)
Slider.Default = Slider.Value
Options[Idx] = Slider
function Slider:Destroy()
Slider.Destroyed = true
if Slider.Connections then
for _, Connection in Slider.Connections do
Connection:Disconnect()
end
end
if Slider.TooltipTable then
Slider.TooltipTable:Destroy()
end
if Holder then
Holder:Destroy()
end
local ElemIdx = table.find(Groupbox.Elements, Slider)
if ElemIdx then
table.remove(Groupbox.Elements, ElemIdx)
end
Groupbox:Resize()
Options[Idx] = nil
end
return Slider
end
function Funcs:AddDropdown(Idx, Info)
if self.Destroyed then return nil end
Info = Library:Validate(Info, Templates.Dropdown)
local Groupbox = self
local Container = Groupbox.Container
if Info.SpecialType == "Player" then
Info.Values = GetPlayers(Info.ExcludeLocalPlayer)
Info.AllowNull = true
elseif Info.SpecialType == "Team" then
Info.Values = GetTeams()
Info.AllowNull = true
end
local Dropdown = {
Connections = {},
Destroyed = false,
Text = typeof(Info.Text) == "string" and Info.Text or nil,
Value = Info.Multi and {} or nil,
Values = Info.Values,
DisabledValues = Info.DisabledValues,
ValueImages = Info.ValueImages,
Multi = Info.Multi,
DragSelect = Info.Multi and not Library.IsMobile and Info.DragSelect == true,
KeepDisabledValuePosition = Info.KeepDisabledValuePosition == true,
SpecialType = Info.SpecialType,
ExcludeLocalPlayer = Info.ExcludeLocalPlayer,
EnablePlayerImages = Info.EnablePlayerImages,
Tooltip = Info.Tooltip,
DisabledTooltip = Info.DisabledTooltip,
TooltipTable = nil,
Callback = Info.Callback,
Changed = Info.Changed,
Disabled = Info.Disabled,
Visible = Info.Visible,
Type = "Dropdown",
}
local Holder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, Dropdown.Text and 39 or 21),
Visible = Dropdown.Visible,
Parent = Container,
})
local Label = New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 14),
Text = Dropdown.Text,
TextSize = 14,
TextXAlignment = Enum.TextXAlignment.Left,
Visible = not not Info.Text,
ZIndex = 3,
Parent = Holder,
})
local DisplayContainer = New("TextButton", {
AnchorPoint = Vector2.new(0, 1),
BackgroundColor3 = "MainColor",
Position = UDim2.fromScale(0, 1),
Size = UDim2.new(1, 0, 0, 21),
Text = "",
TextTransparency = 1,
ZIndex = 2,
Parent = Holder,
})
New("UIPadding", {
PaddingLeft = UDim.new(0, 8),
PaddingRight = UDim.new(0, 4),
Parent = DisplayContainer,
})
local DisplayStroke = New("UIStroke", {
Color = "OutlineColor",
Parent = DisplayContainer,
})
local DropdownCorner = New("UICorner", {
TopLeftRadius = UDim.new(0, Library.CornerRadius / 2),
TopRightRadius = UDim.new(0, Library.CornerRadius / 2),
BottomRightRadius = UDim.new(0, Library.CornerRadius / 2),
BottomLeftRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = DisplayContainer,
}); table.insert(Library.SpecificCorners, DropdownCorner)
local DisplayImage = New("ImageLabel", {
BackgroundTransparency = 1,
Position = UDim2.fromOffset(-4, 3),
Size = UDim2.fromOffset(16, 16),
Image = "",
ImageTransparency = 1,
ZIndex = 2,
Parent = DisplayContainer,
})
local DisplayButton = New("TextButton", {
Active = not Dropdown.Disabled,
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 21),
Text = "---",
TextSize = 14,
TextXAlignment = Enum.TextXAlignment.Left,
ZIndex = 2,
Parent = DisplayContainer,
})
local ArrowImage = New("ImageLabel", {
AnchorPoint = Vector2.new(1, 0.5),
ImageColor3 = "FontColor",
ImageTransparency = 0.5,
Position = UDim2.fromScale(1, 0.5),
Size = UDim2.fromOffset(16, 16),
Parent = DisplayContainer,
})
if ArrowIcon then
Library:ApplyLucideIcon(ArrowImage, ArrowIcon)
end
local SearchBox
if Info.Searchable then
SearchBox = New("TextBox", {
BackgroundTransparency = 1,
PlaceholderText = "Search...",
Position = UDim2.fromOffset(-8, 0),
Size = UDim2.new(1, -12, 1, 0),
TextSize = 14,
TextXAlignment = Enum.TextXAlignment.Left,
Visible = false,
Parent = DisplayButton,
})
New("UIPadding", {
PaddingLeft = UDim.new(0, 8),
Parent = SearchBox,
})
table.insert(Dropdown.Connections, SearchBox.Focused:Connect(function()
Library.Registry[DisplayStroke].Color = "AccentColor"
TweenService:Create(DisplayStroke, Library.TweenInfo, {
Color = Library.Scheme.AccentColor,
}):Play()
end))
table.insert(Dropdown.Connections, SearchBox.FocusLost:Connect(function()
Library.Registry[DisplayStroke].Color = "OutlineColor"
TweenService:Create(DisplayStroke, Library.TweenInfo, {
Color = Library.Scheme.OutlineColor,
}):Play()
end))
end
local GetValueImage = function(Value, RawValue)
if not Value then
return nil
end
local ValueImage = nil
if Dropdown.SpecialType == "Player" and Dropdown.EnablePlayerImages == true then
local PlayerValue = Value
if typeof(PlayerValue) ~= "Instance" and RawValue ~= nil then
PlayerValue = RawValue
end
if typeof(PlayerValue) == "Instance" and PlayerValue:IsA("Player") then
ValueImage = { Url = string.format("rbxthumb://type=AvatarHeadShot&id=%s&w=48&h=48", tostring(PlayerValue.UserId)) }
end
end
if Dropdown.ValueImages then
local IconRef = Dropdown.ValueImages[Value]
if IconRef == nil and RawValue ~= nil then
IconRef = Dropdown.ValueImages[RawValue]
end
if IconRef then
ValueImage = Library:GetCustomIcon(IconRef)
end
end
return ValueImage
end
local MenuTable
MenuTable = Library:AddContextMenu(
DisplayContainer,
function()
return UDim2.fromOffset((DisplayContainer.AbsoluteSize.X / Library.DPIScale), 0)
end,
function()
return { 0.5, DisplayContainer.AbsoluteSize.Y + 1.5 }
end,
2,
function(Active: boolean)
DisplayButton.TextTransparency = (Active and SearchBox) and 1 or 0
ArrowImage.ImageTransparency = Active and 0 or 0.5
ArrowImage.Rotation = Active and 180 or 0
if SearchBox then
SearchBox.Text = ""
SearchBox.Visible = Active
end
local Half = UDim.new(0, Library.CornerRadius / 2)
local Zero = UDim.new(0, 0)
DropdownCorner.TopLeftRadius = Half
DropdownCorner.TopRightRadius = Half
DropdownCorner.BottomRightRadius = Active and Zero or Half
DropdownCorner.BottomLeftRadius = Active and Zero or Half
local MenuCorner = MenuTable and MenuTable.Corner
if MenuCorner then
MenuCorner.TopLeftRadius = Zero
MenuCorner.TopRightRadius = Zero
MenuCorner.BottomRightRadius = Half
MenuCorner.BottomLeftRadius = Half
end
end,
false,
"bottom",
"Dropdown"
)
Dropdown.Menu = MenuTable
local ItemHeight = 21
local PoolSize = math.max(1, Info.MaxVisibleDropdownItems + 2)
local Pool = {}
local FilteredEntries = {}
function Dropdown:RecalculateListSize(Count)
local ItemCount = Count or #FilteredEntries
local Y = math.clamp(ItemCount * ItemHeight, 0, Info.MaxVisibleDropdownItems * ItemHeight)
MenuTable.Menu.CanvasSize = UDim2.fromOffset(0, ItemCount * ItemHeight)
MenuTable:SetSize(function()
return UDim2.fromOffset((DisplayContainer.AbsoluteSize.X / Library.DPIScale), Y)
end)
end
function Dropdown:UpdateColors()
if Library.Unloaded then
return
end
Label.TextTransparency = Dropdown.Disabled and 0.8 or 0
DisplayButton.TextTransparency = Dropdown.Disabled and 0.8 or 0
DisplayImage.ImageTransparency = Dropdown.Disabled and 0.8 or 0
ArrowImage.ImageTransparency = Dropdown.Disabled and 0.8 or MenuTable.Active and 0 or 0.5
end
function Dropdown:Display()
if Library.Unloaded then
return
end
local Str = ""
local ValueImage = nil
local IsDictionary = not IsSequentialArray(Dropdown.Values)
if Info.Multi then
for Key, RawValue in Dropdown.Values do
local Value = IsDictionary and Key or RawValue
if Dropdown.Value[Value] then
if not ValueImage then
ValueImage = GetValueImage(Value, RawValue)
end
Str = Str
.. (Info.FormatDisplayValue and tostring(Info.FormatDisplayValue(RawValue)) or tostring(RawValue))
.. ", "
end
end
Str = Str:sub(1, #Str - 2)
else
local DisplayValue = Dropdown.Value
if IsDictionary and Dropdown.Value ~= nil then
DisplayValue = Dropdown.Values[Dropdown.Value]
end
ValueImage = GetValueImage(Dropdown.Value, DisplayValue)
Str = DisplayValue and tostring(DisplayValue) or ""
if Str ~= "" and Info.FormatDisplayValue then
Str = tostring(Info.FormatDisplayValue(Str))
end
end
if #Str > 25 then
Str = Str:sub(1, 22) .. "..."
end
DisplayButton.Text = (Str == "" and "---" or Str)
if ValueImage then
Library:ApplyLucideIcon(DisplayImage, ValueImage)
DisplayImage.ImageTransparency = 0
else
DisplayImage.Image = ""
DisplayImage.ImageTransparency = 1
end
DisplayButton.Size = ValueImage and UDim2.new(1, -8, 0, 21) or UDim2.new(1, 0, 0, 21)
DisplayButton.Position = ValueImage and UDim2.fromOffset(14, 0) or UDim2.fromOffset(0, 0)
end
function Dropdown:OnChanged(Func)
Dropdown.Changed = Func
end
function Dropdown:GetActiveValues(ReturnCount)
local Table = {}
if Info.Multi then
for Value, _ in Dropdown.Value do
table.insert(Table, Value)
end
else
if Dropdown.Value then
table.insert(Table, Dropdown.Value)
end
end
return ReturnCount == true and GetTableSize(Table) or Table
end
local DragSelecting = false
local DragStartIndex = nil
local DragPrevMin = nil
local DragPrevMax = nil
local DragLastIndex = nil
local DragInitialValues = {}
local DragInputEndedConn = nil
local DragInputChangedConn = nil
local function RecomputeFilteredEntries()
local Values = Dropdown.Values
local DisabledValues = Dropdown.DisabledValues
local IsDictionary = not IsSequentialArray(Values)
local SearchQuery = SearchBox and NormalizeSearch(SearchBox.Text:lower()) or ""
local IsSearching = SearchQuery ~= ""
local EnabledList, DisabledList = {}, {}
local Pending = {}
for Key, RawValue in Values do
local Value = IsDictionary and Key or RawValue
local FormattedValue = tostring(Info.FormatListValue and Info.FormatListValue(RawValue) or RawValue)
local MatchScore = 0
if IsSearching then
local Matched, Score = FuzzyScore(FormattedValue:lower(), SearchQuery)
if not Matched then
continue
end
MatchScore = Score
end
local IsDisabled = table.find(DisabledValues, Value) ~= nil
or (RawValue ~= nil and RawValue ~= Value and table.find(DisabledValues, RawValue) ~= nil)
local Entry = {
Value = Value,
RawValue = RawValue,
FormattedValue = FormattedValue,
IsDisabled = IsDisabled,
ValueImage = GetValueImage(Value, RawValue),
SortKey = Key,
MatchScore = MatchScore,
Order = #Pending + 1,
}
table.insert(Pending, Entry)
end
if IsSearching then
table.sort(Pending, function(A, B)
if A.MatchScore ~= B.MatchScore then
return A.MatchScore > B.MatchScore
end
return A.Order < B.Order
end)
elseif not IsDictionary then
table.sort(Pending, function(A, B)
return A.SortKey < B.SortKey
end)
end
table.clear(FilteredEntries)
if Dropdown.KeepDisabledValuePosition then
for _, Entry in Pending do
table.insert(FilteredEntries, Entry)
end
return
end
for _, Entry in Pending do
if Entry.IsDisabled then
table.insert(DisabledList, Entry)
else
table.insert(EnabledList, Entry)
end
end
for _, Entry in EnabledList do
table.insert(FilteredEntries, Entry)
end
for _, Entry in DisabledList do
table.insert(FilteredEntries, Entry)
end
end
local function GetFirstVisibleIndex()
local Total = #FilteredEntries
if Total <= PoolSize then
return 1
end
local MaxFirst = Total - PoolSize + 1
local ScrollY = MenuTable.Menu.CanvasPosition.Y / Library.DPIScale
local Index = math.floor(ScrollY / ItemHeight) + 1
return math.clamp(Index, 1, MaxFirst)
end
function Dropdown:RefreshPool()
local Total = #FilteredEntries
local First = GetFirstVisibleIndex()
for SlotIndex, Row in Pool do
local DataIndex = First + SlotIndex - 1
local Entry = FilteredEntries[DataIndex]
Row.Entry = Entry
Row.Index = Entry and DataIndex or nil
if not Entry then
Row.Container.Visible = false
continue
end
Row.Container.Visible = true
Row.Container.Position = UDim2.fromOffset(0, (DataIndex - 1) * ItemHeight)
local IsLast = DataIndex == Total
Row.Corner.BottomRightRadius = IsLast and UDim.new(0, Library.CornerRadius / 2) or UDim.new(0, 0)
Row.Corner.BottomLeftRadius = IsLast and UDim.new(0, Library.CornerRadius / 2) or UDim.new(0, 0)
Row.Button.Text = Entry.FormattedValue
if Entry.ValueImage then
Row.Image.Visible = true
Library:ApplyLucideIcon(Row.Image, Entry.ValueImage)
Row.Button.Size = UDim2.new(1, -18, 0, ItemHeight)
Row.Button.Position = UDim2.fromOffset(18, 0)
else
Row.Image.Visible = false
Row.Button.Size = UDim2.new(1, 0, 0, ItemHeight)
Row.Button.Position = UDim2.fromOffset(0, 0)
end
Row:UpdateButton()
end
end
function Dropdown:RunChanged()
if Dropdown.Disabled then
return
end
Library:SafeCallback(Dropdown.Callback, Dropdown.Value)
Library:SafeCallback(Dropdown.Changed, Dropdown.Value)
end
local function StopDragSelect()
DragSelecting = false
DragStartIndex = nil
DragPrevMin = nil
DragPrevMax = nil
DragLastIndex = nil
table.clear(DragInitialValues)
if DragInputEndedConn then
DragInputEndedConn:Disconnect()
DragInputEndedConn = nil
end
if DragInputChangedConn then
DragInputChangedConn:Disconnect()
DragInputChangedConn = nil
end
end
local DragActiveCount = 0
local function ApplyDragIndex(Index, InRange)
local Entry = FilteredEntries[Index]
if not Entry or Entry.IsDisabled then
return
end
local Try = DragInitialValues[Entry.Value]
if InRange then
Try = not Try
end
local WantActive = Try and true or false
local IsActive = Dropdown.Value[Entry.Value] and true or false
if WantActive == IsActive then
return
end
if not WantActive and DragActiveCount == 1 and not Info.AllowNull then
return
end
Dropdown.Value[Entry.Value] = WantActive and true or nil
DragActiveCount += WantActive and 1 or -1
end
local function ApplyDragRange(From, To, InRange)
for Index = From, To do
ApplyDragIndex(Index, InRange)
end
end
local function UpdateDrag(CurrentIndex)
if CurrentIndex == nil or CurrentIndex == DragLastIndex then
return
end
DragLastIndex = CurrentIndex
local Min = math.min(DragStartIndex, CurrentIndex)
local Max = math.max(DragStartIndex, CurrentIndex)
DragActiveCount = Dropdown:GetActiveValues(true)
if DragPrevMin == nil then
ApplyDragRange(Min, Max, true)
else
if DragPrevMin < Min then
ApplyDragRange(DragPrevMin, Min - 1, false)
end
if DragPrevMax > Max then
ApplyDragRange(Max + 1, DragPrevMax, false)
end
if Min < DragPrevMin then
ApplyDragRange(Min, DragPrevMin - 1, true)
end
if Max > DragPrevMax then
ApplyDragRange(DragPrevMax + 1, Max, true)
end
end
DragPrevMin = Min
DragPrevMax = Max
for _, OtherRow in Pool do
OtherRow:UpdateButton()
end
end
local function CreatePoolRow()
local Row = {
Entry = nil,
Index = nil
}
local Container = New("Frame", {
BackgroundColor3 = "MainColor",
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, ItemHeight),
Visible = false,
Parent = MenuTable.Menu,
})
local Corner = New("UICorner", {
TopLeftRadius = UDim.new(0, 0),
TopRightRadius = UDim.new(0, 0),
BottomRightRadius = UDim.new(0, 0),
BottomLeftRadius = UDim.new(0, 0),
Parent = Container,
}); table.insert(Library.SpecificCorners, Corner)
local Image = New("ImageLabel", {
BackgroundTransparency = 1,
Image = "",
ImageTransparency = 0.5,
Size = UDim2.fromOffset(16, 16),
Position = UDim2.fromOffset(4, 3),
Visible = false,
Parent = Container,
})
local Button = New("TextButton", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, ItemHeight),
Text = "",
TextSize = 14,
TextTransparency = 0.5,
TextXAlignment = Enum.TextXAlignment.Left,
Parent = Container,
})
New("UIPadding", {
PaddingLeft = UDim.new(0, 7),
PaddingRight = UDim.new(0, 7),
Parent = Button,
})
Row.Container = Container
Row.Corner = Corner
Row.Image = Image
Row.Button = Button
function Row:UpdateButton()
local Entry = Row.Entry
if not Entry then
return
end
local Selected
if Info.Multi then
Selected = Dropdown.Value[Entry.Value]
else
Selected = Dropdown.Value == Entry.Value
end
Row.Selected = Selected and true or false
Container.BackgroundTransparency = Selected and 0 or 1
Button.TextTransparency = Entry.IsDisabled and 0.8 or Selected and 0 or 0.5
if Entry.ValueImage then
Image.ImageTransparency = Entry.IsDisabled and 0.8 or Selected and 0 or 0.5
end
end
table.insert(Dropdown.Connections, Button.MouseButton1Click:Connect(function()
local Entry = Row.Entry
if not Entry or Entry.IsDisabled or DragSelecting then
return
end
local Selected
if Info.Multi then
Selected = Dropdown.Value[Entry.Value]
else
Selected = Dropdown.Value == Entry.Value
end
local Try = not Selected
if not (Dropdown:GetActiveValues(true) == 1 and not Try and not Info.AllowNull) then
Selected = Try
if Info.Multi then
Dropdown.Value[Entry.Value] = Selected and true or nil
else
Dropdown.Value = Selected and Entry.Value or nil
end
for _, OtherRow in Pool do
OtherRow:UpdateButton()
end
end
Row:UpdateButton()
Dropdown:Display()
Library:UpdateDependencyBoxes()
Dropdown:RunChanged()
end))
table.insert(Dropdown.Connections, Button.MouseEnter:Connect(function()
local Entry = Row.Entry
if not Entry or Entry.IsDisabled then
return
end
if Row.Selected then
return
end
TweenService:Create(Container, Library.TweenInfo, {
BackgroundTransparency = 0.85,
}):Play()
TweenService:Create(Button, Library.TweenInfo, {
TextTransparency = 0.25,
}):Play()
if Image then
TweenService:Create(Image, Library.TweenInfo, {
ImageTransparency = 0.25,
}):Play()
end
end))
table.insert(Dropdown.Connections, Button.MouseLeave:Connect(function()
local Entry = Row.Entry
if not Entry or Entry.IsDisabled then
return
end
if Row.Selected then
return
end
TweenService:Create(Container, Library.TweenInfo, {
BackgroundTransparency = 1,
}):Play()
TweenService:Create(Button, Library.TweenInfo, {
TextTransparency = 0.5,
}):Play()
if Image then
TweenService:Create(Image, Library.TweenInfo, {
ImageTransparency = 0.5,
}):Play()
end
end))
table.insert(Dropdown.Connections, Button.InputBegan:Connect(function(StartInput)
if not (Info.Multi and Dropdown.DragSelect and not Library.IsMobile) then
return
end
local Entry = Row.Entry
if not Entry or Entry.IsDisabled then
return
end
if not IsMouseInput(StartInput) then
return
end
DragSelecting = true
DragStartIndex = Row.Index
table.clear(DragInitialValues)
for _, FilteredEntry in FilteredEntries do
DragInitialValues[FilteredEntry.Value] = Dropdown.Value[FilteredEntry.Value]
end
UpdateDrag(Row.Index)
if DragInputEndedConn then DragInputEndedConn:Disconnect() end
if DragInputChangedConn then DragInputChangedConn:Disconnect() end
DragInputChangedConn = Library:GiveSignal(UserInputService.InputChanged:Connect(function(ChangeInput)
if not IsMovementInput(ChangeInput) and ChangeInput ~= StartInput then
return
end
local Pos = ChangeInput.Position
for _, OtherRow in Pool do
if OtherRow.Entry and Library:MouseIsOverFrame(OtherRow.Button, Pos) then
UpdateDrag(OtherRow.Index)
break
end
end
end))
DragInputEndedConn = Library:GiveSignal(UserInputService.InputEnded:Connect(function(EndInput)
if EndInput ~= StartInput and not (IsMouseInput(EndInput) and EndInput.UserInputType == StartInput.UserInputType) then
return
end
Dropdown:Display()
Library:UpdateDependencyBoxes()
Dropdown:RunChanged()
StopDragSelect()
end))
table.insert(Dropdown.Connections, DragInputEndedConn)
table.insert(Dropdown.Connections, DragInputChangedConn)
end))
return Row
end
function Dropdown:BuildDropdownList()
StopDragSelect()
RecomputeFilteredEntries()
MenuTable.Menu.CanvasPosition = Vector2.new(0, 0)
Dropdown:RefreshPool()
Dropdown:RecalculateListSize(#FilteredEntries)
end
for _ = 1, PoolSize do
table.insert(Pool, CreatePoolRow())
end
table.insert(Dropdown.Connections, MenuTable.Menu:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
Dropdown:RefreshPool()
end))
local function ValueExists(Val)
if IsSequentialArray(Dropdown.Values) then
for _, Existing in Dropdown.Values do
if Existing == Val then
return true
end
end
return false
end
return Dropdown.Values[Val] ~= nil
end
function Dropdown:SetValue(Value)
if Info.Multi then
if typeof(Value) == "string" then
Value = if Value == "" then {} else { [Value] = true }
end
local Table = {}
for Val, Active in Value or {} do
if typeof(Active) ~= "boolean" then
Table[Active] = true
elseif Active and ValueExists(Val) then
Table[Val] = true
end
end
Dropdown.Value = Table
else
if ValueExists(Value) then
Dropdown.Value = Value
elseif not Value then
Dropdown.Value = nil
end
end
Dropdown:Display()
for _, Row in Pool do
Row:UpdateButton()
end
if not Dropdown.Disabled then
Library:UpdateDependencyBoxes()
end
Dropdown:RunChanged()
end
function Dropdown:SetValues(Values)
Dropdown.Values = Values
local Changed = false
if Info.Multi then
for Val in Dropdown.Value do
if not ValueExists(Val) then
Dropdown.Value[Val] = nil
Changed = true
end
end
elseif Dropdown.Value ~= nil and not ValueExists(Dropdown.Value) then
Dropdown.Value = nil
Changed = true
end
Dropdown:BuildDropdownList()
Dropdown:Display()
if Changed and not Dropdown.Disabled then
Library:UpdateDependencyBoxes()
end
if Changed then
Dropdown:RunChanged()
end
end
function Dropdown:AddValues(Values)
if typeof(Values) ~= "table" and typeof(Values) ~= "string" then
return
end
local IsDictionary = not IsSequentialArray(Dropdown.Values)
if IsDictionary then
if typeof(Values) == "string" then
Dropdown.Values[Values] = Values
elseif IsSequentialArray(Values) then
for _, Val in Values do
Dropdown.Values[Val] = Val
end
else
for Key, Val in Values do
Dropdown.Values[Key] = Val
end
end
else
if typeof(Values) == "table" then
for _, Val in Values do
table.insert(Dropdown.Values, Val)
end
else
table.insert(Dropdown.Values, Values)
end
end
Dropdown:BuildDropdownList()
end
function Dropdown:SetDisabledValues(DisabledValues)
Dropdown.DisabledValues = DisabledValues
Dropdown:BuildDropdownList()
end
function Dropdown:AddDisabledValues(DisabledValues)
if typeof(DisabledValues) == "table" then
for _, val in DisabledValues do
table.insert(Dropdown.DisabledValues, val)
end
elseif typeof(DisabledValues) == "string" then
table.insert(Dropdown.DisabledValues, DisabledValues)
else
return
end
Dropdown:BuildDropdownList()
end
function Dropdown:SetValueImages(ValueImages)
if typeof(ValueImages) ~= "table" then
return
end
Dropdown.ValueImages = ValueImages
Dropdown:BuildDropdownList()
end
function Dropdown:AddValueImages(ValueImages)
if typeof(ValueImages) ~= "table" then
return
end
for key, val in ValueImages do
Dropdown.ValueImages[key] = val
end
Dropdown:BuildDropdownList()
end
function Dropdown:SetDisabled(Disabled: boolean)
Dropdown.Disabled = Disabled
if Dropdown.TooltipTable then
Dropdown.TooltipTable.Disabled = Dropdown.Disabled
end
MenuTable:Close()
DisplayButton.Active = not Dropdown.Disabled
Dropdown:UpdateColors()
Library:UpdateDependencyBoxes()
end
function Dropdown:SetVisible(Visible: boolean)
Dropdown.Visible = Visible
Holder.Visible = Dropdown.Visible
Groupbox:Resize()
end
function Dropdown:SetText(Text: string)
Dropdown.Text = Text
Holder.Size = UDim2.new(1, 0, 0, Text and 39 or 21)
Label.Text = Text and Text or ""
Label.Visible = not not Text
end
function Dropdown:SetDragSelect(Value: boolean)
if not Info.Multi or Library.IsMobile then
Value = false
end
Dropdown.DragSelect = Value == true
Dropdown:BuildDropdownList()
end
local ToggleDropdown = function()
if Dropdown.Disabled then
return
end
MenuTable:Toggle()
end
table.insert(Dropdown.Connections, DisplayContainer.MouseButton1Click:Connect(ToggleDropdown))
table.insert(Dropdown.Connections, DisplayButton.MouseButton1Click:Connect(ToggleDropdown))
if SearchBox then
table.insert(Dropdown.Connections, SearchBox:GetPropertyChangedSignal("Text"):Connect(Dropdown.BuildDropdownList))
end
local Defaults = (function()
local Resolved = {}
local Default = Info.Default
if Default == nil then
return Resolved
end
local IsDictionary = not IsSequentialArray(Dropdown.Values)
local function ResolveOne(Candidate)
if IsDictionary then
return Dropdown.Values[Candidate] ~= nil and Candidate or nil
end
for _, Existing in Dropdown.Values do
if Existing == Candidate then
return Existing
end
end
return nil
end
local DefaultType = typeof(Default)
if DefaultType == "string" then
local Value = ResolveOne(Default)
if Value ~= nil then
table.insert(Resolved, Value)
end
elseif DefaultType == "table" then
for _, Candidate in Default do
local Value = ResolveOne(Candidate)
if Value ~= nil then
table.insert(Resolved, Value)
end
end
elseif Dropdown.Values[Default] ~= nil then
table.insert(Resolved, IsDictionary and Default or Dropdown.Values[Default])
end
return Resolved
end)()
for _, SelectValue in Defaults do
if Info.Multi then
Dropdown.Value[SelectValue] = true
else
Dropdown.Value = SelectValue
break
end
end
if typeof(Dropdown.Tooltip) == "string" or typeof(Dropdown.DisabledTooltip) == "string" then
Dropdown.TooltipTable = Library:AddTooltip(Dropdown.Tooltip, Dropdown.DisabledTooltip, DisplayContainer)
Dropdown.TooltipTable.Disabled = Dropdown.Disabled
end
Dropdown:UpdateColors()
Dropdown:Display()
Dropdown:BuildDropdownList()
Groupbox:Resize()
Dropdown.Holder = Holder
table.insert(Groupbox.Elements, Dropdown)
Dropdown.Default = Defaults
Dropdown.DefaultValues = Dropdown.Values
Options[Idx] = Dropdown
function Dropdown:Destroy()
Dropdown.Destroyed = true
StopDragSelect()
if Dropdown.Connections then
for _, Connection in Dropdown.Connections do
Connection:Disconnect()
end
end
if Dropdown.TooltipTable then
Dropdown.TooltipTable:Destroy()
end
if MenuTable then
MenuTable:Destroy()
end
if Holder then
Holder:Destroy()
end
local ElemIdx = table.find(Groupbox.Elements, Dropdown)
if ElemIdx then
table.remove(Groupbox.Elements, ElemIdx)
end
Groupbox:Resize()
Options[Idx] = nil
end
return Dropdown
end
function Funcs:AddViewport(Idx, Info)
if self.Destroyed then return nil end
Info = Library:Validate(Info, Templates.Viewport)
local Groupbox = self
local Container = Groupbox.Container
local Dragging, Pinching = false, false
local LastMousePos, LastPinchDist = nil, 0
local ViewportObject = Info.Object
if Info.Clone and typeof(Info.Object) == "Instance" then
if Info.Object.Archivable then
ViewportObject = ViewportObject:Clone()
else
Info.Object.Archivable = true
ViewportObject = ViewportObject:Clone()
Info.Object.Archivable = false
end
end
local Viewport = {
Connections = {},
Destroyed = false,
Object = ViewportObject :: PVInstance,
Camera = if not Info.Camera then Instance.new("Camera") else Info.Camera,
Interactive = Info.Interactive,
AutoFocus = Info.AutoFocus,
Visible = Info.Visible,
Type = "Viewport",
}
assert(
typeof(Viewport.Object) == "Instance" and (Viewport.Object:IsA("BasePart") or Viewport.Object:IsA("Model")),
"Instance must be a BasePart or Model."
)
assert(
typeof(Viewport.Camera) == "Instance" and Viewport.Camera:IsA("Camera"),
"Camera must be a valid Camera instance."
)
local function GetModelSize(model)
if model:IsA("BasePart") then
return model.Size
end
return select(2, model:GetBoundingBox())
end
local function FocusCamera()
local ModelSize = GetModelSize(Viewport.Object)
local MaxExtent = math.max(ModelSize.X, ModelSize.Y, ModelSize.Z)
local CameraDistance = MaxExtent * 2
local ModelPosition = (Viewport.Object :: PVInstance):GetPivot().Position
Viewport.Camera.CFrame = CFrame.new(ModelPosition + Vector3.new(0, MaxExtent / 2, CameraDistance), ModelPosition)
end
local Holder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, Info.Height),
Visible = Viewport.Visible,
Parent = Container,
})
local Box = New("Frame", {
AnchorPoint = Vector2.new(0, 1),
BackgroundColor3 = "MainColor",
BorderColor3 = "OutlineColor",
BorderSizePixel = 1,
Position = UDim2.fromScale(0, 1),
Size = UDim2.fromScale(1, 1),
Parent = Holder,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 3),
PaddingLeft = UDim.new(0, 8),
PaddingRight = UDim.new(0, 8),
PaddingTop = UDim.new(0, 4),
Parent = Box,
})
local ViewportFrame = New("ViewportFrame", {
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 1),
Parent = Box,
CurrentCamera = Viewport.Camera,
Active = Viewport.Interactive,
})
table.insert(Viewport.Connections, ViewportFrame.MouseEnter:Connect(function()
if not Viewport.Interactive then
return
end
for _, Side in Groupbox.Tab.Sides do
Side.ScrollingEnabled = false
end
end))
table.insert(Viewport.Connections, ViewportFrame.MouseLeave:Connect(function()
if not Viewport.Interactive then
return
end
for _, Side in Groupbox.Tab.Sides do
Side.ScrollingEnabled = true
end
end))
table.insert(Viewport.Connections, ViewportFrame.InputBegan:Connect(function(input)
if not Viewport.Interactive then
return
end
if input.UserInputType == Enum.UserInputType.MouseButton2 or (input.UserInputType == Enum.UserInputType.Touch and not Pinching) then
Dragging = true
LastMousePos = input.Position
end
end))
table.insert(Viewport.Connections, UserInputService.InputEnded:Connect(function(input)
if Library.Unloaded then
return
end
if not Viewport.Interactive then
return
end
if input.UserInputType == Enum.UserInputType.MouseButton2 or input.UserInputType == Enum.UserInputType.Touch then
Dragging = false
end
end))
table.insert(Viewport.Connections, UserInputService.InputChanged:Connect(function(input)
if Library.Unloaded then
return
end
if not Viewport.Interactive or not Dragging or Pinching then
return
end
if
input.UserInputType == Enum.UserInputType.MouseMovement
or input.UserInputType == Enum.UserInputType.Touch
then
local MouseDelta = input.Position - LastMousePos
LastMousePos = input.Position
local Position = (Viewport.Object :: PVInstance):GetPivot().Position
local Camera = Viewport.Camera
local RotationY = CFrame.fromAxisAngle(Vector3.new(0, 1, 0), -MouseDelta.X * 0.01)
Camera.CFrame = CFrame.new(Position) * RotationY * CFrame.new(-Position) * Camera.CFrame
local RotationX = CFrame.fromAxisAngle(Camera.CFrame.RightVector, -MouseDelta.Y * 0.01)
local PitchedCFrame = CFrame.new(Position) * RotationX * CFrame.new(-Position) * Camera.CFrame
if PitchedCFrame.UpVector.Y > 0.1 then
Camera.CFrame = PitchedCFrame
end
end
end))
table.insert(Viewport.Connections, ViewportFrame.InputChanged:Connect(function(input)
if not Viewport.Interactive then
return
end
if input.UserInputType == Enum.UserInputType.MouseWheel then
local ZoomAmount = input.Position.Z * 2
Viewport.Camera.CFrame += Viewport.Camera.CFrame.LookVector * ZoomAmount
end
end))
table.insert(Viewport.Connections, UserInputService.TouchPinch:Connect(function(touchPositions, _, _, state)
if Library.Unloaded then
return
end
if not Viewport.Interactive or not Library:MouseIsOverFrame(ViewportFrame, touchPositions[1]) then
return
end
if state == Enum.UserInputState.Begin then
Pinching = true
Dragging = false
LastPinchDist = (touchPositions[1] - touchPositions[2]).Magnitude
elseif state == Enum.UserInputState.Change then
local currentDist = (touchPositions[1] - touchPositions[2]).Magnitude
local delta = (currentDist - LastPinchDist) * 0.1
LastPinchDist = currentDist
Viewport.Camera.CFrame += Viewport.Camera.CFrame.LookVector * delta
elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
Pinching = false
end
end))
;(Viewport.Object :: PVInstance).Parent = ViewportFrame
if Viewport.AutoFocus then
FocusCamera()
end
function Viewport:SetObject(Object: Instance, Clone: boolean?)
assert(Object, "Object cannot be nil.")
if Clone then
Object = Object:Clone()
end
if Viewport.Object then
Viewport.Object:Destroy()
end
Viewport.Object = Object
;(Viewport.Object :: PVInstance).Parent = ViewportFrame
Groupbox:Resize()
end
function Viewport:SetHeight(Height: number)
assert(Height > 0, "Height must be greater than 0.")
Holder.Size = UDim2.new(1, 0, 0, Height)
Groupbox:Resize()
end
function Viewport:Focus()
if not Viewport.Object then
return
end
FocusCamera()
end
function Viewport:SetCamera(Camera: Instance)
assert(
Camera and typeof(Camera) == "Instance" and Camera:IsA("Camera"),
"Camera must be a valid Camera instance."
)
Viewport.Camera = Camera
ViewportFrame.CurrentCamera = Camera
end
function Viewport:SetInteractive(Interactive: boolean)
Viewport.Interactive = Interactive
ViewportFrame.Active = Interactive
end
function Viewport:SetVisible(Visible: boolean)
Viewport.Visible = Visible
Holder.Visible = Viewport.Visible
Groupbox:Resize()
end
Groupbox:Resize()
Viewport.Holder = Holder
table.insert(Groupbox.Elements, Viewport)
Options[Idx] = Viewport
function Viewport:Destroy()
Viewport.Destroyed = true
if Viewport.Connections then
for _, Connection in Viewport.Connections do
Connection:Disconnect()
end
end
if Holder then
Holder:Destroy()
end
local ElemIdx = table.find(Groupbox.Elements, Viewport)
if ElemIdx then
table.remove(Groupbox.Elements, ElemIdx)
end
Groupbox:Resize()
Options[Idx] = nil
end
return Viewport
end
function Funcs:AddImage(Idx, Info)
if self.Destroyed then return nil end
Info = Library:Validate(Info, Templates.Image)
local Groupbox = self
local Container = Groupbox.Container
local Image = {
Connections = {},
Destroyed = false,
Image = Info.Image,
Color = Info.Color,
RectOffset = Info.RectOffset,
RectSize = Info.RectSize,
Height = Info.Height,
ScaleType = Info.ScaleType,
Transparency = Info.Transparency,
BackgroundTransparency = Info.BackgroundTransparency,
Visible = Info.Visible,
Type = "Image",
}
local Holder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, Info.Height),
Visible = Image.Visible,
Parent = Container,
})
local Box = New("Frame", {
AnchorPoint = Vector2.new(0, 1),
BackgroundColor3 = "MainColor",
BorderColor3 = "OutlineColor",
BorderSizePixel = 1,
BackgroundTransparency = Image.BackgroundTransparency,
Position = UDim2.fromScale(0, 1),
Size = UDim2.fromScale(1, 1),
Parent = Holder,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 3),
PaddingLeft = UDim.new(0, 8),
PaddingRight = UDim.new(0, 8),
PaddingTop = UDim.new(0, 4),
Parent = Box,
})
local ImageProperties = {
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 1),
ImageTransparency = Image.Transparency,
ImageColor3 = Image.Color,
ScaleType = Image.ScaleType,
Parent = Box,
}
local Icon = Library:GetCustomIcon(Image.Image)
assert(Icon, "Image must be a valid Roblox asset or a valid URL or a valid lucide icon.")
ImageProperties.Image = Icon.Url
ImageProperties.ImageRectOffset = Icon.ImageRectOffset
ImageProperties.ImageRectSize = Icon.ImageRectSize
local ImageLabel = New("ImageLabel", ImageProperties)
function Image:SetHeight(Height: number)
assert(Height > 0, "Height must be greater than 0.")
Image.Height = Height
Holder.Size = UDim2.new(1, 0, 0, Height)
Groupbox:Resize()
end
function Image:SetImage(NewImage: string)
assert(typeof(NewImage) == "string", "Image must be a string.")
local Icon = Library:GetCustomIcon(NewImage)
assert(Icon, "Image must be a valid Roblox asset or a valid URL or a valid lucide icon.")
Image.RectOffset = Icon.ImageRectOffset
Image.RectSize = Icon.ImageRectSize
Library:ApplyLucideIcon(ImageLabel, Icon)
Image.Image = Icon.Url
end
function Image:SetColor(Color: Color3)
assert(typeof(Color) == "Color3", "Color must be a Color3 value.")
ImageLabel.ImageColor3 = Color
Image.Color = Color
end
function Image:SetRectOffset(RectOffset: Vector2)
assert(typeof(RectOffset) == "Vector2", "RectOffset must be a Vector2 value.")
ImageLabel.ImageRectOffset = RectOffset
Image.RectOffset = RectOffset
end
function Image:SetRectSize(RectSize: Vector2)
assert(typeof(RectSize) == "Vector2", "RectSize must be a Vector2 value.")
ImageLabel.ImageRectSize = RectSize
Image.RectSize = RectSize
end
function Image:SetScaleType(ScaleType: Enum.ScaleType)
assert(
typeof(ScaleType) == "EnumItem" and ScaleType:IsA("ScaleType"),
"ScaleType must be a valid Enum.ScaleType."
)
ImageLabel.ScaleType = ScaleType
Image.ScaleType = ScaleType
end
function Image:SetTransparency(Transparency: number)
assert(typeof(Transparency) == "number", "Transparency must be a number between 0 and 1.")
assert(Transparency >= 0 and Transparency <= 1, "Transparency must be between 0 and 1.")
ImageLabel.ImageTransparency = Transparency
Image.Transparency = Transparency
end
function Image:SetVisible(Visible: boolean)
Image.Visible = Visible
Holder.Visible = Image.Visible
Groupbox:Resize()
end
Groupbox:Resize()
Image.Holder = Holder
table.insert(Groupbox.Elements, Image)
Options[Idx] = Image
function Image:Destroy()
Image.Destroyed = true
if Holder then
Holder:Destroy()
end
local ElemIdx = table.find(Groupbox.Elements, Image)
if ElemIdx then
table.remove(Groupbox.Elements, ElemIdx)
end
Groupbox:Resize()
Options[Idx] = nil
end
return Image
end
function Funcs:AddVideo(Idx, Info)
if self.Destroyed then return nil end
Info = Library:Validate(Info, Templates.Video)
local Groupbox = self
local Container = Groupbox.Container
local Video = {
Connections = {},
Destroyed = false,
Video = Info.Video,
Looped = Info.Looped,
Playing = Info.Playing,
Volume = Info.Volume,
Height = Info.Height,
Visible = Info.Visible,
Type = "Video",
}
local Holder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, Info.Height),
Visible = Video.Visible,
Parent = Container,
})
local Box = New("Frame", {
AnchorPoint = Vector2.new(0, 1),
BackgroundColor3 = "MainColor",
BorderColor3 = "OutlineColor",
BorderSizePixel = 1,
Position = UDim2.fromScale(0, 1),
Size = UDim2.fromScale(1, 1),
Parent = Holder,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 3),
PaddingLeft = UDim.new(0, 8),
PaddingRight = UDim.new(0, 8),
PaddingTop = UDim.new(0, 4),
Parent = Box,
})
local VideoFrameInstance = New("VideoFrame", {
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 1),
Video = Video.Video,
Looped = Video.Looped,
Volume = Video.Volume,
Parent = Box,
})
VideoFrameInstance.Playing = Video.Playing
function Video:SetHeight(Height: number)
assert(Height > 0, "Height must be greater than 0.")
Video.Height = Height
Holder.Size = UDim2.new(1, 0, 0, Height)
Groupbox:Resize()
end
function Video:SetVideo(NewVideo: string)
assert(typeof(NewVideo) == "string", "Video must be a string.")
VideoFrameInstance.Video = NewVideo
Video.Video = NewVideo
end
function Video:SetLooped(Looped: boolean)
assert(typeof(Looped) == "boolean", "Looped must be a boolean.")
VideoFrameInstance.Looped = Looped
Video.Looped = Looped
end
function Video:SetVolume(Volume: number)
assert(typeof(Volume) == "number", "Volume must be a number between 0 and 10.")
VideoFrameInstance.Volume = Volume
Video.Volume = Volume
end
function Video:SetPlaying(Playing: boolean)
assert(typeof(Playing) == "boolean", "Playing must be a boolean.")
VideoFrameInstance.Playing = Playing
Video.Playing = Playing
end
function Video:Play()
VideoFrameInstance.Playing = true
Video.Playing = true
end
function Video:Pause()
VideoFrameInstance.Playing = false
Video.Playing = false
end
function Video:SetVisible(Visible: boolean)
Video.Visible = Visible
Holder.Visible = Video.Visible
Groupbox:Resize()
end
Groupbox:Resize()
Video.Holder = Holder
Video.VideoFrame = VideoFrameInstance
table.insert(Groupbox.Elements, Video)
Options[Idx] = Video
function Video:Destroy()
Video.Destroyed = true
if Video.Connections then
for _, Connection in Video.Connections do
Connection:Disconnect()
end
end
if Holder then
Holder:Destroy()
end
local ElemIdx = table.find(Groupbox.Elements, Video)
if ElemIdx then
table.remove(Groupbox.Elements, ElemIdx)
end
Groupbox:Resize()
Options[Idx] = nil
end
return Video
end
function Funcs:AddUIPassthrough(Idx, Info)
if self.Destroyed then return nil end
Info = Library:Validate(Info, Templates.UIPassthrough)
local Groupbox = self
local Container = Groupbox.Container
assert(Info.Instance, "Instance must be provided.")
assert(
typeof(Info.Instance) == "Instance" and Info.Instance:IsA("GuiBase2d"),
"Instance must inherit from GuiBase2d."
)
assert(typeof(Info.Height) == "number" and Info.Height > 0, "Height must be a number greater than 0.")
local Passthrough = {
Connections = {},
Destroyed = false,
Instance = Info.Instance,
Height = Info.Height,
Visible = Info.Visible,
Type = "UIPassthrough",
}
local Holder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, Info.Height),
Visible = Passthrough.Visible,
Parent = Container,
})
Passthrough.Instance.Parent = Holder
Groupbox:Resize()
function Passthrough:SetHeight(Height: number)
assert(typeof(Height) == "number" and Height > 0, "Height must be a number greater than 0.")
Passthrough.Height = Height
Holder.Size = UDim2.new(1, 0, 0, Height)
Groupbox:Resize()
end
function Passthrough:SetInstance(Instance: Instance)
assert(Instance, "Instance must be provided.")
assert(
typeof(Instance) == "Instance" and Instance:IsA("GuiBase2d"),
"Instance must inherit from GuiBase2d."
)
if Passthrough.Instance then
Passthrough.Instance.Parent = nil
end
Passthrough.Instance = Instance
Passthrough.Instance.Parent = Holder
end
function Passthrough:SetVisible(Visible: boolean)
Passthrough.Visible = Visible
Holder.Visible = Passthrough.Visible
Groupbox:Resize()
end
Passthrough.Holder = Holder
table.insert(Groupbox.Elements, Passthrough)
Options[Idx] = Passthrough
function Passthrough:Destroy()
Passthrough.Destroyed = true
if Passthrough.Connections then
for _, Connection in Passthrough.Connections do
Connection:Disconnect()
end
end
if Holder then
Holder:Destroy()
end
local ElemIdx = table.find(Groupbox.Elements, Passthrough)
if ElemIdx then
table.remove(Groupbox.Elements, ElemIdx)
end
Groupbox:Resize()
Options[Idx] = nil
end
return Passthrough
end
function Funcs:AddDependencyBox()
if self.Destroyed then return nil end
local Groupbox = self
local Container = Groupbox.Container
local DepboxContainer
local DepboxList
do
DepboxContainer = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 1),
Visible = false,
Parent = Container,
})
DepboxList = New("UIListLayout", {
Padding = UDim.new(0, 8),
Parent = DepboxContainer,
})
end
local Depbox = {
Connections = {},
Destroyed = false,
Visible = false,
Dependencies = {},
Holder = DepboxContainer,
Container = DepboxContainer,
Elements = {},
DependencyBoxes = {}
}
function Depbox:Resize()
DepboxContainer.Size = UDim2.new(1, 0, 0, DepboxList.AbsoluteContentSize.Y / Library.DPIScale)
Groupbox:Resize()
end
function Depbox:Update(CancelSearch)
for _, Dependency in Depbox.Dependencies do
local Element = Dependency[1]
local Value = Dependency[2]
if Element.Disabled then
DepboxContainer.Visible = false
Depbox.Visible = false
return
end
if Element.Type == "Toggle" and Element.Value ~= Value then
DepboxContainer.Visible = false
Depbox.Visible = false
return
elseif Element.Type == "Dropdown" then
if typeof(Element.Value) == "table" then
if not Element.Value[Value] then
DepboxContainer.Visible = false
Depbox.Visible = false
return
end
else
if Element.Value ~= Value then
DepboxContainer.Visible = false
Depbox.Visible = false
return
end
end
end
end
Depbox.Visible = true
DepboxContainer.Visible = true
if not Library.Searching then
task.defer(function()
Depbox:Resize()
end)
elseif not CancelSearch then
Library:UpdateSearch(Library.SearchText)
end
end
table.insert(Depbox.Connections, DepboxList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
if not Depbox.Visible then
return
end
Depbox:Resize()
end))
function Depbox:SetupDependencies(Dependencies)
for _, Dependency in Dependencies do
assert(typeof(Dependency) == "table", "Dependency should be a table.")
assert(Dependency[1] ~= nil, "Dependency is missing element.")
assert(Dependency[2] ~= nil, "Dependency is missing expected value.")
end
Depbox.Dependencies = Dependencies
Depbox:Update()
end
table.insert(Depbox.Connections, DepboxContainer:GetPropertyChangedSignal("Visible"):Connect(function()
Depbox:Resize()
end))
setmetatable(Depbox, BaseGroupbox)
table.insert(Groupbox.DependencyBoxes, Depbox)
table.insert(Library.DependencyBoxes, Depbox)
function Depbox:Destroy()
Depbox.Destroyed = true
if Depbox.Connections then
for _, Connection in Depbox.Connections do
Connection:Disconnect()
end
end
for _, Element in Depbox.Elements do
if Element.Destroy then
Element:Destroy()
end
end
for _, SubDepbox in Depbox.DependencyBoxes do
if SubDepbox.Destroy then
SubDepbox:Destroy()
end
end
if DepboxContainer then
DepboxContainer:Destroy()
end
local ElemIdx = table.find(Groupbox.DependencyBoxes, Depbox)
if ElemIdx then
table.remove(Groupbox.DependencyBoxes, ElemIdx)
end
local LibIdx = table.find(Library.DependencyBoxes, Depbox)
if LibIdx then
table.remove(Library.DependencyBoxes, LibIdx)
end
end
return Depbox
end
function Funcs:AddDependencyGroupbox()
if self.Destroyed then return nil end
local Groupbox = self
local Tab = Groupbox.Tab
local BoxHolder = Groupbox.BoxHolder
local DepGroupboxContainer
local DepGroupboxList
do
DepGroupboxContainer = New("Frame", {
BackgroundColor3 = "BackgroundColor",
Size = UDim2.fromScale(1, 0),
Visible = false,
Parent = BoxHolder,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius),
Parent = DepGroupboxContainer,
})
)
Library:AddOutline(DepGroupboxContainer)
DepGroupboxList = New("UIListLayout", {
Padding = UDim.new(0, 8),
Parent = DepGroupboxContainer,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 7),
PaddingLeft = UDim.new(0, 7),
PaddingRight = UDim.new(0, 7),
PaddingTop = UDim.new(0, 7),
Parent = DepGroupboxContainer,
})
end
local DepGroupbox = {
Connections = {},
Destroyed = false,
Visible = false,
Dependencies = {},
BoxHolder = BoxHolder,
Holder = DepGroupboxContainer,
Container = DepGroupboxContainer,
Tab = Tab,
Elements = {},
DependencyBoxes = {},
}
function DepGroupbox:Resize()
DepGroupboxContainer.Size = UDim2.new(1, 0, 0, (DepGroupboxList.AbsoluteContentSize.Y / Library.DPIScale) + 18)
end
function DepGroupbox:Update(CancelSearch)
for _, Dependency in DepGroupbox.Dependencies do
local Element = Dependency[1]
local Value = Dependency[2]
if Element.Disabled then
DepGroupboxContainer.Visible = false
DepGroupbox.Visible = false
return
end
if Element.Type == "Toggle" and Element.Value ~= Value then
DepGroupboxContainer.Visible = false
DepGroupbox.Visible = false
return
elseif Element.Type == "Dropdown" then
if typeof(Element.Value) == "table" then
if not Element.Value[Value] then
DepGroupboxContainer.Visible = false
DepGroupbox.Visible = false
return
end
else
if Element.Value ~= Value then
DepGroupboxContainer.Visible = false
DepGroupbox.Visible = false
return
end
end
end
end
DepGroupbox.Visible = true
if not Library.Searching then
DepGroupboxContainer.Visible = true
DepGroupbox:Resize()
elseif not CancelSearch then
Library:UpdateSearch(Library.SearchText)
end
end
function DepGroupbox:SetupDependencies(Dependencies)
for _, Dependency in Dependencies do
assert(typeof(Dependency) == "table", "Dependency should be a table.")
assert(Dependency[1] ~= nil, "Dependency is missing element.")
assert(Dependency[2] ~= nil, "Dependency is missing expected value.")
end
DepGroupbox.Dependencies = Dependencies
DepGroupbox:Update()
end
setmetatable(DepGroupbox, BaseGroupbox)
table.insert(Tab.DependencyGroupboxes, DepGroupbox)
table.insert(Library.DependencyBoxes, DepGroupbox :: any)
function DepGroupbox:Destroy()
DepGroupbox.Destroyed = true
if DepGroupbox.Connections then
for _, Connection in DepGroupbox.Connections do
Connection:Disconnect()
end
end
for _, Element in DepGroupbox.Elements do
if Element.Destroy then
Element:Destroy()
end
end
for _, SubDepbox in DepGroupbox.DependencyBoxes do
if SubDepbox.Destroy then
SubDepbox:Destroy()
end
end
if DepGroupboxContainer then
DepGroupboxContainer:Destroy()
end
local ElemIdx = table.find(Tab.DependencyGroupboxes, DepGroupbox)
if ElemIdx then
table.remove(Tab.DependencyGroupboxes, ElemIdx)
end
local LibIdx = table.find(Library.DependencyBoxes, DepGroupbox)
if LibIdx then
table.remove(Library.DependencyBoxes, LibIdx)
end
end
return DepGroupbox
end
BaseGroupbox.__index = Funcs
BaseGroupbox.__namecall = function(_, Key, ...)
return Funcs[Key](...)
end
end
function Library:SetFont(FontFace)
if typeof(FontFace) == "EnumItem" then
FontFace = Font.fromEnum(FontFace :: any)
end
Library.Scheme.Font = FontFace
Library:UpdateColorsUsingRegistry()
end
function Library:SetBackgroundImage(Image: string | number)
assert(typeof(Image) == "string" or typeof(Image) == "number", "Expected string/number got " .. typeof(Image))
Library.Scheme.BackgroundImage = Image
if Library.Window then
Library.Window:SetBackgroundImage(Image)
end
Library:UpdateColorsUsingRegistry()
end
function Library:UpdateNotificationPositions(Snap: boolean?)
local IsLeft = Library.NotifySide:lower() == "left"
local XScale = IsLeft and 0 or 1
local RunningY = 0
for _, FakeBackground in NotifyOrder do
local Data = Library.Notifications[FakeBackground]
if not (Data and FakeBackground.Parent) then continue end
local Target = UDim2.new(XScale, 0, 0, RunningY)
if Snap or not Data.PositionInitialized then
FakeBackground.Position = Target
Data.PositionInitialized = true
elseif FakeBackground.Position ~= Target then
TweenService:Create(FakeBackground, Library.NotifyTweenInfo, {
Position = Target,
}):Play()
end
RunningY = RunningY + FakeBackground.AbsoluteSize.Y / Library.DPIScale + 8
end
end
function Library:SetNotifySide(Side: string)
Library.NotifySide = Side
local IsLeft = Side:lower() == "left"
if IsLeft then
NotificationArea.AnchorPoint = Vector2.new(0, 0)
NotificationArea.Position = UDim2.fromOffset(6, 6)
else
NotificationArea.AnchorPoint = Vector2.new(1, 0)
NotificationArea.Position = UDim2.new(1, -6, 0, 6)
end
for FakeBackground in Library.Notifications do
if not (FakeBackground and FakeBackground.Parent) then continue end
FakeBackground.AnchorPoint = if IsLeft then Vector2.new(0, 0) else Vector2.new(1, 0)
end
if Library.UpdateNotificationPositions then
Library:UpdateNotificationPositions(true)
end
end
function Library:Notify(...)
local Data = {}
local Info = select(1, ...)
if typeof(Info) == "table" then
Data.Title = tostring(Info.Title)
Data.TitleColor = Info.TitleColor
Data.Description = tostring(Info.Description)
Data.DescriptionColor = Info.DescriptionColor
Data.Time = Info.Time or 5
Data.SoundId = Info.SoundId
Data.Steps = Info.Steps
Data.Persist = Info.Persist
Data.Callback = typeof(Info.Callback) == "function" and Info.Callback or nil
Data.Closable = Info.Closable == true
Data.Icon = Info.Icon
Data.BigIcon = Info.BigIcon
Data.IconColor = Info.IconColor
Data.Volume = tonumber(Info.Volume) or 3
else
Data.Description = tostring(Info)
Data.Time = select(2, ...) or 5
Data.SoundId = select(3, ...)
Data.Volume = select(4, ...) or 3
end
Data.Destroyed = false
local DeletedInstance = false
local DeleteConnection = nil
if typeof(Data.Time) == "Instance" then
DeleteConnection = Data.Time.Destroying:Connect(function()
DeletedInstance = true
DeleteConnection:Disconnect()
DeleteConnection = nil
end)
end
local FakeBackground = New("Frame", {
AnchorPoint = Library.NotifySide:lower() == "left" and Vector2.new(0, 0) or Vector2.new(1, 0),
AutomaticSize = Enum.AutomaticSize.Y,
BackgroundTransparency = 1,
Size = UDim2.fromOffset(0, 0),
Visible = false,
Parent = NotificationArea,
})
local Holder = New("Frame", {
AutomaticSize = Enum.AutomaticSize.Y,
BackgroundColor3 = function()
return Library:GetBetterColor(Library.Scheme.BackgroundColor, 3)
end,
Position = Library.NotifySide:lower() == "left" and UDim2.new(-1, -8, 0, 0) or UDim2.new(1, 8, 0, 0),
Size = UDim2.new(1, 0, 0, 0),
ZIndex = 5,
Parent = FakeBackground,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius),
Parent = Holder,
})
)
Library:AddOutline(Holder)
local AccentEdge = New("Frame", {
BackgroundColor3 = "WhiteColor",
Position = UDim2.fromOffset(0, 8),
Size = UDim2.new(0, 3, 1, -16),
ZIndex = 6,
Parent = Holder,
})
New("UICorner", {
CornerRadius = UDim.new(1, 0),
Parent = AccentEdge,
})
New("UIGradient", {
Color = function()
return Library:GetAccentSequence()
end,
Rotation = 90,
Parent = AccentEdge,
})
local ContentHolder = New("Frame", {
AutomaticSize = Enum.AutomaticSize.Y,
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 0),
Parent = Holder,
})
New("UIListLayout", {
Padding = UDim.new(0, 6),
Parent = ContentHolder,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 10),
PaddingLeft = UDim.new(0, 14),
PaddingRight = UDim.new(0, 10),
PaddingTop = UDim.new(0, 10),
Parent = ContentHolder,
})
local CloseButton
if Data.Closable then
CloseButton = New("ImageButton", {
AnchorPoint = Vector2.new(1, 0),
BackgroundTransparency = 1,
Image = CloseIcon and CloseIcon.Url or "",
ImageColor3 = "FontColor",
ImageRectOffset = CloseIcon and CloseIcon.ImageRectOffset or Vector2.zero,
ImageRectSize = CloseIcon and CloseIcon.ImageRectSize or Vector2.zero,
ImageTransparency = 0.5,
Position = UDim2.new(1, -8, 0, 8),
Size = UDim2.fromOffset(14, 14),
ZIndex = 6,
Parent = Holder,
})
CloseButton.MouseEnter:Connect(function()
TweenService:Create(CloseButton, Library.TweenInfo, {
ImageTransparency = 0,
}):Play()
end)
CloseButton.MouseLeave:Connect(function()
TweenService:Create(CloseButton, Library.TweenInfo, {
ImageTransparency = 0.5,
}):Play()
end)
CloseButton.MouseButton1Click:Connect(function()
Data:Destroy("user")
end)
end
local ContentContainer = New("Frame", {
BackgroundTransparency = 1,
AutomaticSize = Enum.AutomaticSize.XY,
Size = UDim2.fromOffset(0, 0),
Parent = ContentHolder,
})
local BadgeIcon = Library:GetCustomIcon(Data.BigIcon or "bell")
if BadgeIcon then
New("UIListLayout", {
Padding = UDim.new(0, 10),
FillDirection = Enum.FillDirection.Horizontal,
VerticalAlignment = Enum.VerticalAlignment.Center,
Parent = ContentContainer,
})
end
local BigIconLabel
if BadgeIcon then
BigIconLabel = New("Frame", {
BackgroundColor3 = Data.IconColor or "AccentColor",
BackgroundTransparency = 0.85,
Size = UDim2.fromOffset(30, 30),
Parent = ContentContainer,
})
New("UICorner", {
CornerRadius = UDim.new(0, 8),
Parent = BigIconLabel,
})
local BadgeGlyph = New("ImageLabel", {
AnchorPoint = Vector2.new(0.5, 0.5),
ImageColor3 = Data.IconColor or "AccentColor",
Position = UDim2.fromScale(0.5, 0.5),
Size = UDim2.fromOffset(17, 17),
Parent = BigIconLabel,
})
Library:ApplyLucideIcon(BadgeGlyph, BadgeIcon)
end
local TextContainer = New("Frame", {
BackgroundTransparency = 1,
AutomaticSize = Enum.AutomaticSize.XY,
Size = UDim2.fromOffset(0, 0),
Parent = ContentContainer,
})
New("UIListLayout", {
Padding = UDim.new(0, 4),
Parent = TextContainer,
})
local TitleContainer
if Data.Title then
TitleContainer = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.fromOffset(0, 0),
Parent = TextContainer,
})
end
local IconLabel
if Data.Icon and TitleContainer then
local ParsedIcon = Library:GetCustomIcon(Data.Icon)
if ParsedIcon then
IconLabel = New("ImageLabel", {
BackgroundTransparency = 1,
AnchorPoint = Vector2.new(0, 0.5),
Position = UDim2.new(0, 0, 0.5, 1),
Size = UDim2.fromOffset(15, 15),
ImageColor3 = Data.IconColor or "FontColor",
Parent = TitleContainer,
})
Library:ApplyLucideIcon(IconLabel, ParsedIcon)
end
end
local Title
local Desc
local TitleX = 0
local DescX = 0
local TimerFill
if Data.Title then
Title = New("TextLabel", {
AutomaticSize = Enum.AutomaticSize.None,
BackgroundTransparency = 1,
AnchorPoint = Vector2.new(0, 0.5),
Position = UDim2.new(0, (IconLabel and 21 or 0), 0.5, 0),
Size = UDim2.fromScale(0, 0),
FontFace = function()
return Font.new(Library.Scheme.Font.Family, Enum.FontWeight.Bold)
end,
Text = Data.Title,
TextColor3 = Data.TitleColor or "FontColor",
TextSize = 15,
TextXAlignment = Enum.TextXAlignment.Left,
TextYAlignment = Enum.TextYAlignment.Center,
TextWrapped = true,
Parent = TitleContainer,
})
end
if Data.Description then
Desc = New("TextLabel", {
AutomaticSize = Enum.AutomaticSize.None,
BackgroundTransparency = 1,
Size = UDim2.fromScale(0, 0),
Text = Data.Description,
TextColor3 = Data.DescriptionColor or "FontColor",
TextSize = 14,
TextTransparency = 0.25,
TextXAlignment = Enum.TextXAlignment.Left,
TextWrapped = true,
Parent = TextContainer,
})
end
function Data:Resize()
local ExtraWidth = BigIconLabel and 40 or 0
local IconWidth = IconLabel and 21 or 0
local CloseWidth = Data.Closable and 20 or 0
local MaxTextWidth = math.max(
40,
(NotificationArea.AbsoluteSize.X / Library.DPIScale) - 24 - ExtraWidth - CloseWidth
)
if Title then
local X, Y = Library:GetTextBounds(Title.Text, Title.FontFace, Title.TextSize, MaxTextWidth - IconWidth)
Title.Size = UDim2.fromOffset(X, Y)
TitleX = X + IconWidth
TitleContainer.Size = UDim2.fromOffset(TitleX, math.max(Y, IconLabel and 16 or 0))
end
if Desc then
local X, Y = Library:GetTextBounds(Desc.Text, Desc.FontFace, Desc.TextSize, MaxTextWidth)
Desc.Size = UDim2.fromOffset(X, Y)
DescX = X
end
FakeBackground.Size = UDim2.fromOffset(math.max(TitleX, DescX) + 24 + ExtraWidth + CloseWidth, 0)
if Library.Notifications[FakeBackground] then
task.defer(function()
if Data.Destroyed or not FakeBackground.Parent then
return
end
if FakeBackground.AbsoluteSize.Y <= 0 then
task.defer(function()
if Data.Destroyed or not FakeBackground.Parent then
return
end
Library:UpdateNotificationPositions(true)
end)
return
end
Library:UpdateNotificationPositions(true)
end)
end
end
function Data:ChangeTitle(Text)
if Title then
Data.Title = tostring(Text)
Title.Text = Data.Title
Data:Resize()
end
end
function Data:ChangeDescription(Text)
if Desc then
Data.Description = tostring(Text)
Desc.Text = Data.Description
Data:Resize()
end
end
function Data:ChangeStep(NewStep)
if TimerFill and Data.Steps then
NewStep = math.clamp(NewStep or 0, 0, Data.Steps)
TimerFill.Size = UDim2.fromScale(NewStep / Data.Steps, 1)
end
end
function Data:Destroy(Reason)
if Data.Destroyed then
return
end
Reason = Reason or "script"
Data.Destroyed = true
if Data.Callback then
pcall(Data.Callback, Reason)
end
if typeof(Data.Time) == "Instance" then
pcall(Data.Time.Destroy, Data.Time)
end
if DeleteConnection then
DeleteConnection:Disconnect()
end
if FakeBackground then
local Idx = table.find(NotifyOrder, FakeBackground)
if Idx then
table.remove(NotifyOrder, Idx)
end
end
Library:UpdateNotificationPositions()
TweenService
:Create(Holder, Library.NotifyTweenInfo, {
Position = Library.NotifySide:lower() == "left" and UDim2.new(-1, -8, 0, -2) or UDim2.new(1, 8, 0, -2),
})
:Play()
task.delay(Library.NotifyTweenInfo.Time, function()
Library.Notifications[FakeBackground] = nil
FakeBackground:Destroy()
end)
end
local TimerHolder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 4),
Visible = (Data.Persist ~= true and typeof(Data.Time) ~= "Instance") or typeof(Data.Steps) == "number",
Parent = ContentHolder,
})
local TimerBar = New("Frame", {
BackgroundColor3 = "OutlineColor",
Position = UDim2.fromOffset(0, 1),
Size = UDim2.new(1, 0, 0, 3),
Parent = TimerHolder,
})
New("UICorner", {
CornerRadius = UDim.new(1, 0),
Parent = TimerBar,
})
TimerFill = New("Frame", {
BackgroundColor3 = "WhiteColor",
Size = UDim2.fromScale(1, 1),
Parent = TimerBar,
})
New("UICorner", {
CornerRadius = UDim.new(1, 0),
Parent = TimerFill,
})
New("UIGradient", {
Color = function()
return Library:GetAccentSequence()
end,
Parent = TimerFill,
})
if typeof(Data.Time) == "Instance" then
TimerFill.Size = UDim2.fromScale(0, 1)
end
if Data.SoundId then
local SoundId = Data.SoundId
if typeof(SoundId) == "number" then
SoundId = string.format("rbxassetid://%d", SoundId)
end
New("Sound", {
SoundId = SoundId,
Volume = tonumber(Data.Volume) or 3,
PlayOnRemove = true,
Parent = SoundService,
}):Destroy()
end
Data.Holder = Holder
table.insert(NotifyOrder, FakeBackground)
Library.Notifications[FakeBackground] = Data
Data:Resize()
FakeBackground.Visible = true
TweenService:Create(Holder, Library.NotifyTweenInfo, {
Position = UDim2.fromOffset(0, 0),
}):Play()
task.defer(function()
if not Data.Destroyed then
Library:UpdateNotificationPositions(true)
end
end)
task.delay(Library.NotifyTweenInfo.Time, function()
if Data.Persist then
return
elseif typeof(Data.Time) == "Instance" then
repeat
task.wait()
until DeletedInstance or Data.Destroyed
else
TweenService
:Create(TimerFill, TweenInfo.new(Data.Time, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut), {
Size = UDim2.fromScale(0, 1),
})
:Play()
task.wait(Data.Time)
end
Data:Destroy("timer")
end)
return Data
end
function Library:CreateWindow(WindowInfo)
WindowInfo = Library:Validate(WindowInfo, Templates.Window)
local ViewportSize: Vector2 = workspace.CurrentCamera.ViewportSize
if RunService:IsStudio() and ViewportSize.X <= 5 and ViewportSize.Y <= 5 then
repeat
ViewportSize = workspace.CurrentCamera.ViewportSize
task.wait()
until ViewportSize.X > 5 and ViewportSize.Y > 5
end
local MaxX = ViewportSize.X - 64
local MaxY = ViewportSize.Y - 64
Library.OriginalMinSize =
Vector2.new(math.min(Library.OriginalMinSize.X, MaxX), math.min(Library.OriginalMinSize.Y, MaxY))
Library.MinSize = Vector2.new(math.min(WindowInfo.MinContainerWidth, MaxX), Library.OriginalMinSize.Y)
WindowInfo.Size = UDim2.fromOffset(
math.clamp(WindowInfo.Size.X.Offset, Library.MinSize.X, MaxX),
math.clamp(WindowInfo.Size.Y.Offset, Library.MinSize.Y, MaxY)
)
if typeof(WindowInfo.Font) == "EnumItem" then
WindowInfo.Font = Font.fromEnum(WindowInfo.Font :: any)
end
WindowInfo.CornerRadius = math.min(WindowInfo.CornerRadius, 20)
local TabButtonsStyle = WindowInfo.TabButtonsStyle
if WindowInfo.Compact ~= nil then
WindowInfo.SidebarCompacted = WindowInfo.Compact
end
if WindowInfo.SidebarMinWidth ~= nil then
WindowInfo.MinSidebarWidth = WindowInfo.SidebarMinWidth
end
WindowInfo.MinSidebarWidth = math.max(64 + TabButtonsStyle.Padding * 2, WindowInfo.MinSidebarWidth)
WindowInfo.SidebarCompactWidth = math.max(40 + TabButtonsStyle.Padding * 2, WindowInfo.SidebarCompactWidth)
WindowInfo.SidebarCollapseThreshold = math.clamp(WindowInfo.SidebarCollapseThreshold, 0.1, 0.9)
WindowInfo.CompactWidthActivation = math.max(40 + TabButtonsStyle.Padding * 2, WindowInfo.CompactWidthActivation)
WindowInfo.SnapDistance = math.max(0, WindowInfo.SnapDistance)
WindowInfo.SnapMargin = math.max(0, WindowInfo.SnapMargin)
Library.CornerRadius = WindowInfo.CornerRadius
Library:SetNotifySide(WindowInfo.NotifySide)
Library.ShowCustomCursor = WindowInfo.ShowCustomCursor
Library.Scheme.Font = WindowInfo.Font
Library.ToggleKeybind = WindowInfo.ToggleKeybind
Library.GlobalSearch = WindowInfo.GlobalSearch
Library.Animations = WindowInfo.Animations
Library.TabTransitionInfo = TweenInfo.new(
math.max(0, WindowInfo.TabTransitionTime or 0.22),
Enum.EasingStyle.Quad,
Enum.EasingDirection.Out
)
Library.TabSwipeOffset = math.max(1, WindowInfo.TabSwipeOffset or 26)
Library.TabSwipeFrom = WindowInfo.TabSwipeFrom or "right"
local IsDefaultSearchbarSize = WindowInfo.SearchbarSize == UDim2.fromScale(1, 1)
local MainFrame
local DividerLine
local TitleHolder
local WindowTitle
local WindowIcon
local RightWrapper
local SearchBox
local CurrentTabInfo
local CurrentTabLabel
local CurrentTabDescription
local ResizeButton
local Tabs
local Container
local BackgroundImage
local HasBackgroundImage = false
local BottomBackground
local BottomBackgroundCorner
local FooterLabel
local TopBar
local SidebarPanel
local HeaderLine
local BrandLine
local TitleTexts
local NavLabel
local ProfileCard
local ProfileAvatar
local ProfileTexts
local WindowShadow
local MinimizeButton
local CloseWindowButton
local ResizeGrip
local HeaderHeight = 56
local ControlsWidth = 76
local TabsTop = HeaderHeight + 1
local ProfileHeight = WindowInfo.ShowProfile and 68 or 0
local WindowSnapConfig = {
Enabled = WindowInfo.Snapping,
Distance = WindowInfo.SnapDistance,
Margin = WindowInfo.SnapMargin,
AvoidCoreGui = WindowInfo.SnapAvoidCoreGui,
}
local InitialLeftWidth = math.ceil(WindowInfo.Size.X.Offset * 0.3)
local IsCompact = WindowInfo.SidebarCompacted
local LastExpandedWidth = InitialLeftWidth
do
Library.KeybindFrame, Library.KeybindContainer = Library:AddDraggableMenu("Keybinds")
Library.KeybindFrame.AnchorPoint = Vector2.new(0, 0.5)
Library.KeybindFrame.Position = UDim2.new(0, 6, 0.5, 0)
Library.KeybindFrame.Visible = false
MainFrame = New("TextButton", {
BackgroundColor3 = function()
return Library:GetBetterColor(Library.Scheme.BackgroundColor, 1)
end,
Name = "Main",
Text = "",
Position = WindowInfo.Position,
Size = WindowInfo.Size,
Visible = false,
Parent = ScreenGui,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, WindowInfo.CornerRadius),
Parent = MainFrame,
})
)
table.insert(
Library.Scales,
New("UIScale", {
Parent = MainFrame,
})
)
local MainOutline = Library:AddOutline(MainFrame)
Library.Registry[MainOutline].Color = "WhiteColor"
MainOutline.Color = Library.Scheme.WhiteColor
New("UIGradient", {
Color = function()
return ColorSequence.new({
ColorSequenceKeypoint.new(0, Library.Scheme.AccentColor),
ColorSequenceKeypoint.new(0.35, Library.Scheme.OutlineColor),
ColorSequenceKeypoint.new(1, Library.Scheme.OutlineColor),
})
end,
Rotation = 90,
Parent = MainOutline,
})
WindowShadow = New("ImageLabel", {
BackgroundTransparency = 1,
Image = "rbxassetid://6014261993",
ImageColor3 = "DarkColor",
ImageTransparency = 0.4,
ScaleType = Enum.ScaleType.Slice,
SliceCenter = Rect.new(49, 49, 450, 450),
Visible = false,
ZIndex = 0,
Parent = ScreenGui,
})
Library:GiveSignal(RunService.RenderStepped:Connect(function()
local Showing = MainFrame.Visible and not Library.Unloaded
WindowShadow.Visible = Showing
if not Showing then
return
end
local Spread = 30
WindowShadow.Position = UDim2.fromOffset(
MainFrame.AbsolutePosition.X - Spread,
MainFrame.AbsolutePosition.Y - Spread + 8
)
WindowShadow.Size = UDim2.fromOffset(
MainFrame.AbsoluteSize.X + Spread * 2,
MainFrame.AbsoluteSize.Y + Spread * 2
)
WindowShadow.ImageTransparency = 0.4 + 0.6 * MainFrame.BackgroundTransparency
end))
SidebarPanel = New("Frame", {
BackgroundColor3 = function()
return Library:GetBetterColor(Library.Scheme.BackgroundColor, -1)
end,
Size = UDim2.new(0, InitialLeftWidth, 1, 0),
Parent = MainFrame,
})
New("UICorner", {
TopLeftRadius = UDim.new(0, WindowInfo.CornerRadius),
BottomLeftRadius = UDim.new(0, WindowInfo.CornerRadius),
TopRightRadius = UDim.new(0, 0),
BottomRightRadius = UDim.new(0, 0),
Parent = SidebarPanel,
})
HeaderLine = Library:MakeLine(MainFrame, {
Position = UDim2.fromOffset(InitialLeftWidth + 1, HeaderHeight),
Size = UDim2.new(1, -InitialLeftWidth - 1, 0, 1),
})
Library:AddAccentLine(HeaderLine)
BrandLine = Library:MakeLine(MainFrame, {
Position = UDim2.fromOffset(12, HeaderHeight),
Size = UDim2.fromOffset(math.max(0, InitialLeftWidth - 24), 1),
})
DividerLine = New("Frame", {
BackgroundColor3 = "OutlineColor",
Position = UDim2.fromOffset(InitialLeftWidth, 0),
Size = UDim2.new(0, 1, 1, 0),
Parent = MainFrame,
ZIndex = 2
})
local BackgroundIcon = Library:GetCustomIcon(WindowInfo.BackgroundImage)
HasBackgroundImage = BackgroundIcon ~= nil
BackgroundImage = New("ImageLabel", {
Active = false,
Position = UDim2.fromScale(0, 0),
Size = UDim2.fromScale(1, 1),
ScaleType = Enum.ScaleType.Stretch,
ZIndex = Overlay.ZIndex + 1,
BackgroundTransparency = 1,
ImageTransparency = 0.75,
Visible = false,
Parent = ScreenGui,
})
if BackgroundIcon then
Library:ApplyLucideIcon(BackgroundImage, BackgroundIcon)
end
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, WindowInfo.CornerRadius),
Parent = BackgroundImage,
})
)
Library:GiveSignal(RunService.RenderStepped:Connect(function()
if not (BackgroundImage and MainFrame) then
return
end
local ShouldShow = HasBackgroundImage and MainFrame.Visible
BackgroundImage.Visible = ShouldShow
if not ShouldShow then
return
end
BackgroundImage.Position = UDim2.fromOffset(
MainFrame.AbsolutePosition.X,
MainFrame.AbsolutePosition.Y
)
BackgroundImage.Size = UDim2.fromOffset(
MainFrame.AbsoluteSize.X,
MainFrame.AbsoluteSize.Y
)
end))
if WindowInfo.Center then
MainFrame.Position = UDim2.new(0.5, -MainFrame.Size.X.Offset / 2, 0.5, -MainFrame.Size.Y.Offset / 2)
end
TopBar = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, HeaderHeight),
Parent = MainFrame,
})
Library:MakeDraggable(MainFrame, TopBar, false, true, WindowSnapConfig)
TitleHolder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(0, InitialLeftWidth, 1, 0),
Parent = TopBar,
})
New("UIPadding", {
PaddingLeft = UDim.new(0, 12),
PaddingRight = UDim.new(0, 10),
Parent = TitleHolder,
})
New("UIListLayout", {
FillDirection = Enum.FillDirection.Horizontal,
VerticalAlignment = Enum.VerticalAlignment.Center,
Padding = UDim.new(0, 10),
Parent = TitleHolder,
})
local Badge = Library:MakeBadge(TitleHolder, 32, WindowInfo.Icon, WindowInfo.Title)
WindowIcon = Badge.Glyph
TitleTexts = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, -42, 0, 34),
Parent = TitleHolder,
})
New("UIListLayout", {
VerticalAlignment = Enum.VerticalAlignment.Center,
Padding = UDim.new(0, 1),
Parent = TitleTexts,
})
WindowTitle = New("TextLabel", {
BackgroundTransparency = 1,
FontFace = function()
return Font.new(Library.Scheme.Font.Family, Enum.FontWeight.Bold)
end,
Size = UDim2.new(1, 0, 0, 18),
Text = WindowInfo.Title,
TextSize = 17,
TextTruncate = Enum.TextTruncate.AtEnd,
TextXAlignment = Enum.TextXAlignment.Left,
Parent = TitleTexts,
})
FooterLabel = New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 14),
Text = WindowInfo.Footer,
TextSize = 13,
TextTransparency = 0.5,
TextTruncate = Enum.TextTruncate.AtEnd,
TextXAlignment = Enum.TextXAlignment.Left,
Parent = TitleTexts,
})
RightWrapper = New("Frame", {
AnchorPoint = Vector2.new(1, 0.5),
BackgroundTransparency = 1,
Position = UDim2.new(1, -ControlsWidth, 0.5, 0),
Size = UDim2.new(1, -InitialLeftWidth - ControlsWidth - 14, 1, -20),
Parent = TopBar,
})
New("UIListLayout", {
FillDirection = Enum.FillDirection.Horizontal,
HorizontalAlignment = Enum.HorizontalAlignment.Left,
VerticalAlignment = Enum.VerticalAlignment.Center,
Padding = UDim.new(0, 8),
Parent = RightWrapper,
})
CurrentTabInfo = New("Frame", {
Size = UDim2.fromScale(WindowInfo.DisableSearch and 1 or 0.5, 1),
Visible = false,
BackgroundTransparency = 1,
Parent = RightWrapper,
})
New("UIFlexItem", {
FlexMode = Enum.UIFlexMode.Grow,
Parent = CurrentTabInfo,
})
New("UIListLayout", {
FillDirection = Enum.FillDirection.Vertical,
HorizontalAlignment = Enum.HorizontalAlignment.Left,
VerticalAlignment = Enum.VerticalAlignment.Center,
Parent = CurrentTabInfo,
})
New("UIPadding", {
PaddingLeft = UDim.new(0, 12),
PaddingRight = UDim.new(0, 8),
Parent = CurrentTabInfo,
})
CurrentTabLabel = New("TextLabel", {
BackgroundTransparency = 1,
FontFace = function()
return Font.new(Library.Scheme.Font.Family, Enum.FontWeight.Bold)
end,
Size = UDim2.new(1, 0, 0, 20),
Text = "",
TextSize = 19,
TextTruncate = Enum.TextTruncate.AtEnd,
TextXAlignment = Enum.TextXAlignment.Left,
Parent = CurrentTabInfo,
})
CurrentTabDescription = New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 14),
Text = "",
TextSize = 13,
TextTruncate = Enum.TextTruncate.AtEnd,
TextXAlignment = Enum.TextXAlignment.Left,
TextTransparency = 0.5,
Visible = false,
Parent = CurrentTabInfo,
})
SearchBox = New("TextBox", {
BackgroundColor3 = "MainColor",
PlaceholderText = "Search",
Size = WindowInfo.SearchbarSize,
TextScaled = true,
Visible = not (WindowInfo.DisableSearch or false),
Parent = RightWrapper,
})
New("UIFlexItem", {
FlexMode = Enum.UIFlexMode.Shrink,
Parent = SearchBox,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, WindowInfo.CornerRadius),
Parent = SearchBox,
})
)
New("UIPadding", {
PaddingBottom = UDim.new(0, 10),
PaddingLeft = UDim.new(0, 10),
PaddingRight = UDim.new(0, 10),
PaddingTop = UDim.new(0, 10),
Parent = SearchBox,
})
local SearchBoxStroke = New("UIStroke", {
Color = "OutlineColor",
Parent = SearchBox,
})
Library:GiveSignal(SearchBox.Focused:Connect(function()
Library.Registry[SearchBoxStroke].Color = "AccentColor"
TweenService:Create(SearchBoxStroke, Library.TweenInfo, {
Color = Library.Scheme.AccentColor,
}):Play()
end))
Library:GiveSignal(SearchBox.FocusLost:Connect(function()
Library.Registry[SearchBoxStroke].Color = "OutlineColor"
TweenService:Create(SearchBoxStroke, Library.TweenInfo, {
Color = Library.Scheme.OutlineColor,
}):Play()
end))
local SearchIcon = Library:GetIcon("search")
if SearchIcon then
local SearchIconImage = New("ImageLabel", {
ImageColor3 = "FontColor",
ImageTransparency = 0.5,
Size = UDim2.fromScale(1, 1),
SizeConstraint = Enum.SizeConstraint.RelativeYY,
Parent = SearchBox,
})
Library:ApplyLucideIcon(SearchIconImage, SearchIcon)
end
local Controls = New("Frame", {
AnchorPoint = Vector2.new(1, 0.5),
BackgroundTransparency = 1,
Position = UDim2.new(1, -12, 0.5, 0),
Size = UDim2.fromOffset(ControlsWidth - 14, 28),
Parent = TopBar,
})
New("UIListLayout", {
FillDirection = Enum.FillDirection.Horizontal,
HorizontalAlignment = Enum.HorizontalAlignment.Right,
VerticalAlignment = Enum.VerticalAlignment.Center,
Padding = UDim.new(0, 6),
Parent = Controls,
})
local function ControlButton(IconName: string, HoverColor: () -> Color3)
local Button = New("ImageButton", {
BackgroundColor3 = "MainColor",
BackgroundTransparency = 1,
Size = UDim2.fromOffset(28, 28),
Parent = Controls,
})
New("UICorner", {
CornerRadius = UDim.new(0, 8),
Parent = Button,
})
local Glyph = New("ImageLabel", {
AnchorPoint = Vector2.new(0.5, 0.5),
ImageColor3 = "FontColor",
ImageTransparency = 0.45,
Position = UDim2.fromScale(0.5, 0.5),
Size = UDim2.fromOffset(16, 16),
Parent = Button,
})
local Icon = Library:GetIcon(IconName)
if Icon then
Library:ApplyLucideIcon(Glyph, Icon)
end
Button.MouseEnter:Connect(function()
TweenService:Create(Button, Library.TweenInfo, {
BackgroundColor3 = HoverColor(),
BackgroundTransparency = 0,
}):Play()
TweenService:Create(Glyph, Library.TweenInfo, { ImageTransparency = 0 }):Play()
end)
Button.MouseLeave:Connect(function()
TweenService:Create(Button, Library.TweenInfo, { BackgroundTransparency = 1 }):Play()
TweenService:Create(Glyph, Library.TweenInfo, { ImageTransparency = 0.45 }):Play()
end)
return Button
end
MinimizeButton = ControlButton("minus", function()
return Library.Scheme.MainColor
end)
CloseWindowButton = ControlButton("x", function()
return Library.Scheme.DestructiveColor
end)
BottomBackground = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 20 + WindowInfo.CornerRadius),
Visible = false,
Parent = MainFrame
})
local BottomBar = New("Frame", {
AnchorPoint = Vector2.new(1, 1),
BackgroundTransparency = 1,
Position = UDim2.new(1, -2, 1, -2),
Size = UDim2.fromOffset(18, 18),
ZIndex = 4,
Parent = MainFrame,
})
ResizeGrip = BottomBar
if WindowInfo.Resizable then
ResizeButton = New("TextButton", {
AnchorPoint = Vector2.new(1, 0),
BackgroundTransparency = 1,
Position = UDim2.new(1, -WindowInfo.CornerRadius / 4, 0, 0),
Size = UDim2.fromScale(1, 1),
SizeConstraint = Enum.SizeConstraint.RelativeYY,
Text = "",
Parent = BottomBar,
})
Library:MakeResizable(MainFrame, ResizeButton, function()
for _, Tab in Library.Tabs do
Tab:Resize(true)
end
end)
end
local WindowResizeIcon = New("ImageLabel", {
ImageColor3 = "FontColor",
ImageTransparency = 0.7,
Position = UDim2.fromOffset(2, 2),
Size = UDim2.new(1, -4, 1, -4),
Parent = ResizeButton,
})
if ResizeIcon then
Library:ApplyLucideIcon(WindowResizeIcon, ResizeIcon)
end
Tabs = New("ScrollingFrame", {
AutomaticCanvasSize = Enum.AutomaticSize.Y,
BackgroundTransparency = 1,
CanvasSize = UDim2.fromScale(0, 0),
Position = UDim2.fromOffset(0, TabsTop),
ScrollBarImageTransparency = 1,
ScrollBarThickness = 0,
Size = UDim2.new(0, InitialLeftWidth, 1, -TabsTop - ProfileHeight),
Parent = MainFrame,
})
New("UIListLayout", {
Padding = UDim.new(0, TabButtonsStyle.Gap),
Parent = Tabs,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, TabButtonsStyle.Padding),
PaddingLeft = UDim.new(0, TabButtonsStyle.Padding),
PaddingRight = UDim.new(0, TabButtonsStyle.Padding),
PaddingTop = UDim.new(0, TabButtonsStyle.Padding),
Parent = Tabs,
})
NavLabel = New("TextLabel", {
BackgroundTransparency = 1,
FontFace = function()
return Font.new(Library.Scheme.Font.Family, Enum.FontWeight.Bold)
end,
LayoutOrder = -1,
Size = UDim2.new(1, 0, 0, 20),
Text = "NAVIGATION",
TextSize = 11,
TextTransparency = 0.6,
TextXAlignment = Enum.TextXAlignment.Left,
Parent = Tabs,
})
New("UIPadding", {
PaddingLeft = UDim.new(0, 8),
Parent = NavLabel,
})
if WindowInfo.ShowProfile then
ProfileCard = New("Frame", {
AnchorPoint = Vector2.new(0, 1),
BackgroundColor3 = "MainColor",
Position = UDim2.new(0, 8, 1, -8),
Size = UDim2.new(0, math.max(InitialLeftWidth - 16, 32), 0, 52),
Parent = MainFrame,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, WindowInfo.CornerRadius),
Parent = ProfileCard,
})
)
New("UIStroke", {
Color = "OutlineColor",
Parent = ProfileCard,
})
ProfileAvatar = New("ImageLabel", {
AnchorPoint = Vector2.new(0, 0.5),
BackgroundColor3 = "BackgroundColor",
BackgroundTransparency = 0,
Image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", LocalPlayer.UserId),
Position = UDim2.new(0, 8, 0.5, 0),
Size = UDim2.fromOffset(36, 36),
Parent = ProfileCard,
})
New("UICorner", {
CornerRadius = UDim.new(1, 0),
Parent = ProfileAvatar,
})
New("UIStroke", {
Color = "AccentColor",
Thickness = 1.5,
Parent = ProfileAvatar,
})
ProfileTexts = New("Frame", {
BackgroundTransparency = 1,
Position = UDim2.fromOffset(52, 0),
Size = UDim2.new(1, -58, 1, 0),
Parent = ProfileCard,
})
New("UIListLayout", {
VerticalAlignment = Enum.VerticalAlignment.Center,
Padding = UDim.new(0, 1),
Parent = ProfileTexts,
})
New("TextLabel", {
BackgroundTransparency = 1,
FontFace = function()
return Font.new(Library.Scheme.Font.Family, Enum.FontWeight.Bold)
end,
Size = UDim2.new(1, 0, 0, 16),
Text = LocalPlayer.DisplayName,
TextSize = 14,
TextTruncate = Enum.TextTruncate.AtEnd,
TextXAlignment = Enum.TextXAlignment.Left,
Parent = ProfileTexts,
})
New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 14),
Text = "@" .. LocalPlayer.Name,
TextSize = 12,
TextTransparency = 0.5,
TextTruncate = Enum.TextTruncate.AtEnd,
TextXAlignment = Enum.TextXAlignment.Left,
Parent = ProfileTexts,
})
end
Container = New("Frame", {
AnchorPoint = Vector2.new(1, 0),
BackgroundTransparency = 1,
ClipsDescendants = true,
Name = "Container",
Position = UDim2.new(1, 0, 0, TabsTop),
Size = UDim2.new(1, -InitialLeftWidth - 1, 1, -TabsTop),
Parent = MainFrame,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 4),
PaddingLeft = UDim.new(0, 8),
PaddingRight = UDim.new(0, 8),
PaddingTop = UDim.new(0, 4),
Parent = Container,
})
Library.WindowContainer = Container
end
local Window = {}
local Fading = false
local IntroPlaying = false
local UpdateFloatingButton = function() end
local RestoreIdentity = Elevate
local function SetUICorner(UICorner, Corner, HalfValue)
local Current = UICorner[Corner]
if Current.Offset == 0 and Current.Scale == 0 then
return
end
UICorner[Corner] = HalfValue
end
function Window:ChangeTitle(title)
assert(typeof(title) == "string", "Expected string for title got: " .. typeof(title))
WindowTitle.Text = title
WindowInfo.Title = title
end
function Window:SetBackgroundImage(Image: string)
local ValidIcon = false
if typeof(Image) == "string" then
local BackgroundIcon = Library:GetCustomIcon(Image)
if BackgroundIcon then
ValidIcon = true
Library:ApplyLucideIcon(BackgroundImage, BackgroundIcon)
elseif Image:match("http://") or Image:match("https://") then
local RawFileName = Image:match("(.+)%..+$")
local _, Domain = Image:match("^(https?://)([^/]+)");
if RawFileName and Domain then
local Extention = string.sub(Image, #RawFileName + 1, #Image)
local FileNamePos = RawFileName:gsub("\\", "/"):find("/[^/]*$")
local FileName = FileNamePos and Image:sub(FileNamePos + 1) or nil
if FileName then
ValidIcon = true
local AssetName = Domain .. FileName
if #AssetName > 255 then
local NewLength = 255 - #Domain - #Extention
if NewLength < 0 then
AssetName = Domain .. Extention
else
AssetName = Domain .. string.sub(FileName:sub(1, #FileName - #Extention), 1, NewLength) .. Extention
end
end
if CustomImageManagerAssets[FileName] == nil then
CustomImageManager.AddAsset(FileName, 0, Image)
else
CustomImageManager.DownloadAsset(FileName, true)
end
BackgroundImage.Image = CustomImageManager.GetAsset(FileName)
BackgroundImage.ImageRectOffset = Vector2.zero
BackgroundImage.ImageRectSize = Vector2.zero
end
end
end
end
if not ValidIcon then
BackgroundImage.Image = ""
BackgroundImage.ImageRectOffset = Vector2.zero
BackgroundImage.ImageRectSize = Vector2.zero
end
HasBackgroundImage = ValidIcon
WindowInfo.BackgroundImage = Image
end
function Window:SetFooter(Footer: string)
assert(typeof(Footer) == "string", "Expected string for footer got: " .. typeof(Footer))
FooterLabel.Text = Footer
WindowInfo.Footer = Footer
end
function Window:SetAlwaysOnTop(Enabled: boolean)
WindowInfo.AlwaysOnTop = Enabled == true
SetAlwaysOnTop(Library.ScreenGui, WindowInfo.AlwaysOnTop)
end
function Window:SetSnapping(Enabled: boolean, Distance: number?, Margin: number?, AvoidCoreGui: boolean?)
WindowInfo.Snapping = Enabled == true
WindowSnapConfig.Enabled = WindowInfo.Snapping
if Distance then
WindowInfo.SnapDistance = math.max(0, Distance)
WindowSnapConfig.Distance = WindowInfo.SnapDistance
end
if Margin then
WindowInfo.SnapMargin = math.max(0, Margin)
WindowSnapConfig.Margin = WindowInfo.SnapMargin
end
if AvoidCoreGui ~= nil then
WindowInfo.SnapAvoidCoreGui = AvoidCoreGui == true
WindowSnapConfig.AvoidCoreGui = WindowInfo.SnapAvoidCoreGui
end
end
function Window:SetCornerRadius(Radius: number)
assert(typeof(Radius) == "number", "Expected number for Radius got: " .. typeof(Radius))
Radius = math.min(Radius, 20)
local RadiusHalf = UDim.new(0, Radius / 2)
local RadiusUDim = UDim.new(0, Radius)
local HalfCurrent = Library.CornerRadius / 2
for _, UICorner in Library.Corners do
if math.abs(UICorner.CornerRadius.Offset - HalfCurrent) < 0.001 then
UICorner.CornerRadius = RadiusHalf
else
UICorner.CornerRadius = RadiusUDim
end
end
for _, UICorner in Library.SpecificCorners do
SetUICorner(UICorner, "TopRightRadius", RadiusHalf)
SetUICorner(UICorner, "TopLeftRadius", RadiusHalf)
SetUICorner(UICorner, "BottomRightRadius", RadiusHalf)
SetUICorner(UICorner, "BottomLeftRadius", RadiusHalf)
end
Library.CornerRadius = Radius
WindowInfo.CornerRadius = Radius
if ResizeButton then
ResizeButton.Position = UDim2.new(1, -Radius / 4, 0, 0)
end
if BottomBackgroundCorner then
BottomBackgroundCorner.BottomLeftRadius = RadiusUDim
BottomBackgroundCorner.BottomRightRadius = RadiusUDim
end
for _, Menu in Library.ContextMenus do
if Menu.Destroyed then
continue
end
if typeof(Menu.ActiveCallback) ~= "function" then
continue
end
if not Menu.Active then
local HolderActive = false
for _, Other in Library.ContextMenus do
if Other == Menu then
continue
end
if Other.Active and Other.Holder == Menu.Holder then
HolderActive = true
break
end
end
if HolderActive then
continue
end
Menu.ActiveCallback(false)
continue
end
Menu.ActiveCallback(true)
end
for _, Option in Options do
if Option.Type == "Dropdown" and Option.RefreshPool then
Option:RefreshPool()
end
end
for _, Tab in Library.Tabs do
if Tab.IsKeyTab then
continue
end
for _, Tabbox in Tab.Tabboxes do
Tabbox:UpdateCorners()
end
end
end
function Window:SetAnimations(Animations: { [string]: boolean }?, TabTransitionTime: number?, TabSwipeOffset: number?, TabSwipeFrom: ("left" | "right" | "top" | "bottom" | string)?)
if typeof(Animations) == "table" then
WindowInfo.Animations = Animations
Library.Animations = Animations
end
if typeof(TabTransitionTime) == "number" then
local TweenInfo = TweenInfo.new(
math.max(0, TabTransitionTime or 0.22),
Enum.EasingStyle.Quad,
Enum.EasingDirection.Out
)
WindowInfo.TabTransitionInfo = TweenInfo
Library.TabTransitionInfo = TweenInfo
end
if typeof(TabSwipeOffset) == "number" then
TabSwipeOffset = math.max(1, TabSwipeOffset)
WindowInfo.TabSwipeOffset = TabSwipeOffset
Library.TabSwipeOffset = TabSwipeOffset
end
if typeof(TabSwipeFrom) == "string" then
TabSwipeFrom = string.lower(TabSwipeFrom)
WindowInfo.TabSwipeFrom = TabSwipeFrom
Library.TabSwipeFrom = TabSwipeFrom
end
end
local function ApplyCompact()
IsCompact = Window:GetSidebarWidth() == WindowInfo.SidebarCompactWidth
if WindowInfo.DisableCompactingSnap then
IsCompact = Window:GetSidebarWidth() <= WindowInfo.CompactWidthActivation
end
TitleTexts.Visible = not IsCompact
NavLabel.Visible = not IsCompact
if ProfileTexts then
ProfileTexts.Visible = not IsCompact
ProfileCard.BackgroundTransparency = IsCompact and 1 or 0
ProfileAvatar.AnchorPoint = IsCompact and Vector2.new(0.5, 0.5) or Vector2.new(0, 0.5)
ProfileAvatar.Position = IsCompact and UDim2.fromScale(0.5, 0.5) or UDim2.new(0, 8, 0.5, 0)
end
for _, Button in Library.TabButtons do
if not Button.Icon then
continue
end
Button.Label.Visible = not IsCompact
Button.Padding.PaddingBottom = UDim.new(0, IsCompact and 6 or 11)
Button.Padding.PaddingLeft = UDim.new(0, IsCompact and 6 or 12)
Button.Padding.PaddingRight = UDim.new(0, IsCompact and 6 or 12)
Button.Padding.PaddingTop = UDim.new(0, IsCompact and 6 or 11)
Button.Icon.SizeConstraint = IsCompact and Enum.SizeConstraint.RelativeXY or Enum.SizeConstraint.RelativeYY
end
end
function Window:IsSidebarCompacted()
return IsCompact
end
function Window:SetCompact(State)
Window:SetSidebarWidth(State and WindowInfo.SidebarCompactWidth or LastExpandedWidth)
end
function Window:GetSidebarWidth()
return Tabs.Size.X.Offset
end
function Window:SetSidebarWidth(Width)
Width = math.clamp(Width, 48, MainFrame.Size.X.Offset - WindowInfo.MinContainerWidth - 1)
DividerLine.Position = UDim2.fromOffset(Width, 0)
SidebarPanel.Size = UDim2.new(0, Width, 1, 0)
HeaderLine.Position = UDim2.fromOffset(Width + 1, HeaderHeight)
HeaderLine.Size = UDim2.new(1, -Width - 1, 0, 1)
BrandLine.Size = UDim2.fromOffset(math.max(0, Width - 24), 1)
TitleHolder.Size = UDim2.new(0, Width, 1, 0)
RightWrapper.Size = UDim2.new(1, -Width - ControlsWidth - 14, 1, -20)
Tabs.Size = UDim2.new(0, Width, 1, -TabsTop - ProfileHeight)
Container.Size = UDim2.new(1, -Width - 1, 1, -TabsTop)
if ProfileCard then
ProfileCard.Size = UDim2.new(0, math.max(Width - 16, 32), 0, 52)
end
if WindowInfo.EnableCompacting then
ApplyCompact()
end
if not IsCompact then
LastExpandedWidth = Width
end
end
function Window:ShowTabInfo(Name, Description)
CurrentTabLabel.Text = Name
CurrentTabDescription.Text = Description or ""
CurrentTabDescription.Visible = Description ~= nil and Description ~= ""
if IsDefaultSearchbarSize then
SearchBox.Size = UDim2.fromScale(0.42, 1)
end
CurrentTabInfo.Visible = true
end
function Window:HideTabInfo()
CurrentTabInfo.Visible = false
if IsDefaultSearchbarSize then
SearchBox.Size = UDim2.fromScale(1, 1)
end
end
function Window:AddTab(...)
local Name = nil
local Icon = nil
local Description = nil
local Tooltip = nil
local Order = nil
if select("#", ...) == 1 and typeof(...) == "table" then
local Info = select(1, ...)
Name = Info.Name or "Tab"
Icon = Info.Icon
Description = Info.Description
Tooltip = Info.Tooltip
Order = Info.Order
else
Name = select(1, ...)
Icon = select(2, ...)
Description = select(3, ...)
Order = select(4, ...)
end
if not tonumber(Order) then
Order = #Tabs:GetChildren()
end
local TabButton: TextButton
local TabIndicator
local TabLabel
local TabIcon
local TabContainer
local TabLeft
local TabRight
Icon = Library:GetCustomIcon(Icon)
do
TabButton = New("TextButton", {
BackgroundColor3 = "AccentColor",
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 38),
Text = "",
LayoutOrder = Order,
Parent = Tabs,
})
New("UICorner", {
CornerRadius = UDim.new(0, TabButtonsStyle.CornerRadius),
Parent = TabButton,
})
if TabButtonsStyle.Indicator then
TabIndicator = New("Frame", {
AnchorPoint = Vector2.new(1, 0.5),
BackgroundColor3 = "AccentColor",
BackgroundTransparency = 1,
Position = UDim2.new(0, -2, 0.5, 0),
Size = UDim2.fromOffset(TabButtonsStyle.IndicatorWidth, TabButtonsStyle.IndicatorHeight),
Parent = TabButton,
})
New("UICorner", {
CornerRadius = UDim.new(1, 0),
Parent = TabIndicator,
})
end
local ButtonHolder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 1),
Parent = TabButton,
})
local ButtonPadding = New("UIPadding", {
PaddingBottom = UDim.new(0, IsCompact and 6 or 11),
PaddingLeft = UDim.new(0, IsCompact and 6 or 12),
PaddingRight = UDim.new(0, IsCompact and 6 or 12),
PaddingTop = UDim.new(0, IsCompact and 6 or 11),
Parent = ButtonHolder,
})
TabLabel = New("TextLabel", {
BackgroundTransparency = 1,
Position = UDim2.fromOffset(30, 0),
Size = UDim2.new(1, -30, 1, 0),
Text = Name,
TextSize = 16,
TextTransparency = 0.5,
TextXAlignment = Enum.TextXAlignment.Left,
Visible = not IsCompact,
Parent = ButtonHolder,
})
if Icon then
TabIcon = New("ImageLabel", {
ImageColor3 = Icon.Custom and "WhiteColor" or "AccentColor",
ImageTransparency = 0.5,
ScaleType = Enum.ScaleType.Fit,
Size = UDim2.fromScale(1, 1),
SizeConstraint = IsCompact and Enum.SizeConstraint.RelativeXY or Enum.SizeConstraint.RelativeYY,
Parent = ButtonHolder,
})
Library:ApplyLucideIcon(TabIcon, Icon)
end
table.insert(Library.TabButtons, {
Label = TabLabel,
Padding = ButtonPadding,
Icon = TabIcon,
})
TabContainer = New("Frame", {
BackgroundTransparency = 1,
Position = UDim2.fromScale(0, 0),
Size = UDim2.fromScale(1, 1),
Visible = false,
Parent = Container,
})
TabLeft = New("ScrollingFrame", {
AutomaticCanvasSize = Enum.AutomaticSize.Y,
BackgroundTransparency = 1,
CanvasSize = UDim2.fromScale(0, 0),
ScrollBarImageTransparency = 1,
ScrollBarThickness = 0,
Size = UDim2.new(0.5, -3, 1, 0),
Parent = TabContainer,
})
New("UIListLayout", {
Padding = UDim.new(0, 2),
Parent = TabLeft,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 2),
PaddingLeft = UDim.new(0, 2),
PaddingRight = UDim.new(0, 2),
PaddingTop = UDim.new(0, 2),
Parent = TabLeft,
})
do
New("Frame", {
BackgroundTransparency = 1,
LayoutOrder = -1,
Parent = TabLeft,
})
New("Frame", {
BackgroundTransparency = 1,
LayoutOrder = 1,
Parent = TabLeft,
})
end
TabRight = New("ScrollingFrame", {
AnchorPoint = Vector2.new(1, 0),
AutomaticCanvasSize = Enum.AutomaticSize.Y,
BackgroundTransparency = 1,
CanvasSize = UDim2.fromScale(0, 0),
Position = UDim2.fromScale(1, 0),
ScrollBarImageTransparency = 1,
ScrollBarThickness = 0,
Size = UDim2.new(0.5, -3, 1, 0),
Parent = TabContainer,
})
New("UIListLayout", {
Padding = UDim.new(0, 2),
Parent = TabRight,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 2),
PaddingLeft = UDim.new(0, 2),
PaddingRight = UDim.new(0, 2),
PaddingTop = UDim.new(0, 2),
Parent = TabRight,
})
do
New("Frame", {
BackgroundTransparency = 1,
LayoutOrder = -1,
Parent = TabRight,
})
New("Frame", {
BackgroundTransparency = 1,
LayoutOrder = 1,
Parent = TabRight,
})
end
end
local Tab = {
Name = Name,
Description = Description,
Tooltip = Tooltip,
TooltipTable = nil,
Connections = {},
Destroyed = false,
Window = Window,
Button = TabButton,
Container = TabContainer,
Sides = {
TabLeft,
TabRight,
},
WarningBox = {
IsNormal = false,
LockSize = false,
Visible = false,
Title = "WARNING",
Text = "",
},
Groupboxes = {},
Tabboxes = {},
DependencyGroupboxes = {},
}
local WarningBoxHolder = New("Frame", {
AutomaticSize = Enum.AutomaticSize.Y,
BackgroundTransparency = 1,
Position = UDim2.fromOffset(0, 7),
Size = UDim2.fromScale(1, 0),
Visible = false,
Parent = TabContainer,
})
local WarningBox
local WarningBoxOutline
local WarningBoxShadowOutline
local WarningBoxScrollingFrame
local WarningTitle
local WarningStroke
local WarningText
do
WarningBox = New("Frame", {
BackgroundColor3 = Color3.fromRGB(127, 0, 0),
Position = UDim2.fromOffset(2, 0),
Size = UDim2.new(1, -5, 0, 0),
Parent = WarningBoxHolder,
})
Library:AddToRegistry(WarningBox, {
BackgroundColor3 = function()
return Tab.WarningBox.IsNormal == true and Library.Scheme.BackgroundColor or Color3.fromRGB(127, 0, 0)
end
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, WindowInfo.CornerRadius),
Parent = WarningBox,
})
)
WarningBoxOutline, WarningBoxShadowOutline = Library:AddOutline(WarningBox)
Library:AddToRegistry(WarningBoxOutline, {
Color = function()
return Tab.WarningBox.IsNormal == true and Library.Scheme.OutlineColor or Color3.fromRGB(255, 50, 50)
end
})
Library:AddToRegistry(WarningBoxShadowOutline, {
Color = function()
return Tab.WarningBox.IsNormal == true and Library.Scheme.DarkColor or Color3.fromRGB(85, 0, 0)
end
})
WarningBoxScrollingFrame = New("ScrollingFrame", {
BackgroundTransparency = 1,
BorderSizePixel = 0,
Size = UDim2.fromScale(1, 1),
CanvasSize = UDim2.new(0, 0, 0, 0),
ScrollBarThickness = 3,
ScrollingDirection = Enum.ScrollingDirection.Y,
Parent = WarningBox,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 4),
PaddingLeft = UDim.new(0, 6),
PaddingRight = UDim.new(0, 6),
PaddingTop = UDim.new(0, 4),
Parent = WarningBoxScrollingFrame,
})
WarningTitle = New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.new(1, -4, 0, 14),
Text = "",
TextColor3 = Color3.fromRGB(255, 50, 50),
TextSize = 14,
TextXAlignment = Enum.TextXAlignment.Left,
Parent = WarningBoxScrollingFrame,
})
Library:AddToRegistry(WarningTitle, {
TextColor3 = function()
return Tab.WarningBox.IsNormal == true and Library.Scheme.FontColor or Color3.fromRGB(255, 50, 50)
end
})
WarningStroke = New("UIStroke", {
ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
Color = Color3.fromRGB(169, 0, 0),
LineJoinMode = Enum.LineJoinMode.Miter,
Parent = WarningTitle,
})
Library:AddToRegistry(WarningStroke, {
Color = function()
return Tab.WarningBox.IsNormal == true and Library.Scheme.OutlineColor or Color3.fromRGB(169, 0, 0)
end
})
WarningText = New("TextLabel", {
BackgroundTransparency = 1,
Position = UDim2.fromOffset(0, 16),
Size = UDim2.new(1, -4, 0, 0),
Text = "",
TextSize = 14,
TextWrapped = true,
Parent = WarningBoxScrollingFrame,
TextXAlignment = Enum.TextXAlignment.Left,
TextYAlignment = Enum.TextYAlignment.Top,
})
New("UIStroke", {
ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
Color = "DarkColor",
LineJoinMode = Enum.LineJoinMode.Miter,
Parent = WarningText,
})
end
function Tab:UpdateWarningBox(Info)
if typeof(Info.IsNormal) == "boolean" then
Tab.WarningBox.IsNormal = Info.IsNormal
end
if typeof(Info.LockSize) == "boolean" then
Tab.WarningBox.LockSize = Info.LockSize
end
if typeof(Info.Visible) == "boolean" then
Tab.WarningBox.Visible = Info.Visible
end
if typeof(Info.Title) == "string" then
Tab.WarningBox.Title = Info.Title
end
if typeof(Info.Text) == "string" then
Tab.WarningBox.Text = Info.Text
end
WarningBoxHolder.Visible = Tab.WarningBox.Visible
WarningTitle.Text = Tab.WarningBox.Title
WarningText.Text = Tab.WarningBox.Text
Tab:Resize(true)
WarningBox.BackgroundColor3 = Library.Registry[WarningBox].BackgroundColor3()
WarningBoxShadowOutline.Color = Library.Registry[WarningBoxShadowOutline].Color()
WarningBoxOutline.Color = Library.Registry[WarningBoxOutline].Color()
WarningTitle.TextColor3 = Library.Registry[WarningTitle].TextColor3()
WarningStroke.Color = Library.Registry[WarningStroke].Color()
end
function Tab:RefreshSides()
local Offset = WarningBoxHolder.Visible and WarningBox.Size.Y.Offset + 8 or 0
for _, Side in Tab.Sides do
Side.Position = UDim2.new(Side.Position.X.Scale, 0, 0, Offset)
Side.Size = UDim2.new(0.5, -3, 1, -Offset)
end
end
function Tab:Resize(ResizeWarningBox: boolean?)
if ResizeWarningBox then
local MaximumSize = math.floor((TabContainer.AbsoluteSize.Y / Library.DPIScale) / 3.25)
local _, YText = Library:GetTextBounds(
WarningText.Text,
Library.Scheme.Font,
WarningText.TextSize,
WarningText.AbsoluteSize.X / Library.DPIScale
)
local YBox = 24 + YText
if Tab.WarningBox.LockSize == true and YBox >= MaximumSize then
WarningBoxScrollingFrame.CanvasSize = UDim2.fromOffset(0, YBox)
YBox = MaximumSize
else
WarningBoxScrollingFrame.CanvasSize = UDim2.fromOffset(0, 0)
end
WarningText.Size = UDim2.new(1, -4, 0, YText)
WarningBox.Size = UDim2.new(1, -5, 0, YBox + 4)
end
Tab:RefreshSides()
end
local function AddTabbox(self, Info)
Info = Library:Validate(Info, Templates.Tabbox)
local ParentObj = self
local IsNested = ParentObj.Type == "Groupbox" or ParentObj.Type == "SubTab"
if typeof(Info.Side) == "string" then
local lowerSide = string.lower(Info.Side)
if not SideIndex[lowerSide] then
error(string.format("Invalid side: %s", Info.Side))
end
Info.Side = SideIndex[lowerSide]
end
local BoxHolder = New("Frame", {
AutomaticSize = Enum.AutomaticSize.Y,
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 0),
Parent = if IsNested then ParentObj.Container else (Info.Side == 1 and TabLeft or TabRight),
})
New("UIListLayout", {
Padding = UDim.new(0, 6),
Parent = BoxHolder,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 4),
PaddingTop = UDim.new(0, 4),
Parent = BoxHolder,
})
local TabboxHolder
local TabboxButtons
do
TabboxHolder = New("Frame", {
BackgroundColor3 = "BackgroundColor",
Size = UDim2.fromScale(1, 0),
Parent = BoxHolder,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, WindowInfo.CornerRadius),
Parent = TabboxHolder,
})
)
Library:AddOutline(TabboxHolder)
TabboxButtons = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 34),
Parent = TabboxHolder,
})
New("UIListLayout", {
FillDirection = Enum.FillDirection.Horizontal,
HorizontalFlex = Enum.UIFlexAlignment.Fill,
Parent = TabboxButtons,
})
end
local TotalTabs = 0
local FirstTab
local LastTab
local Tabbox: any = {
Type = "Tabbox",
Connections = {},
Destroyed = false,
Visible = true,
ActiveTab = nil,
BoxHolder = BoxHolder,
Holder = TabboxHolder,
Tabs = {},
ParentBox = if IsNested then ParentObj else nil,
}
function Tabbox:UpdateCorners()
for _, Tab in Tabbox.Tabs do
Tab:UpdateCorners()
end
end
function Tabbox:Resize()
if Tabbox.ActiveTab then
Tabbox.ActiveTab:Resize()
end
end
function Tabbox:AddTab(Name, IconName)
TotalTabs = TotalTabs + 1
local TabIndex = TotalTabs
LastTab = TabIndex
if not FirstTab then
FirstTab = TabIndex
end
local IsNameEmpty = Name == nil or Trim(tostring(Name)) == ""
local TabStoringIndex = IsNameEmpty and tostring(TabIndex) or Name
local Button = New("TextButton", {
BackgroundColor3 = "MainColor",
BackgroundTransparency = 0,
Size = UDim2.fromOffset(0, 34),
Text = "",
Parent = TabboxButtons,
})
local ButtonCorner = New("UICorner", {
TopLeftRadius = UDim.new(0, WindowInfo.CornerRadius),
TopRightRadius = UDim.new(0, WindowInfo.CornerRadius),
BottomRightRadius = UDim.new(0, 0),
BottomLeftRadius = UDim.new(0, 0),
Parent = Button,
}); table.insert(Library.SpecificCorners, ButtonCorner)
local ButtonContent = New("Frame", {
AnchorPoint = Vector2.new(0.5, 0.5),
AutomaticSize = Enum.AutomaticSize.X,
BackgroundTransparency = 1,
Position = UDim2.fromScale(0.5, 0.5),
Size = UDim2.fromOffset(0, 16),
Parent = Button,
})
New("UIListLayout", {
FillDirection = Enum.FillDirection.Horizontal,
HorizontalAlignment = Enum.HorizontalAlignment.Center,
VerticalAlignment = Enum.VerticalAlignment.Center,
Padding = UDim.new(0, 8),
Parent = ButtonContent,
})
local ButtonIcon
local BoxIcon = Library:GetCustomIcon(IconName)
if BoxIcon then
ButtonIcon = New("ImageLabel", {
ImageColor3 = BoxIcon.Custom and "WhiteColor" or "AccentColor",
ImageTransparency = 0.5,
Size = IsNameEmpty and UDim2.fromOffset(16, 16) or UDim2.fromOffset(18, 18),
Parent = ButtonContent,
})
Library:ApplyLucideIcon(ButtonIcon, BoxIcon)
end
local ButtonLabel
if not IsNameEmpty then
ButtonLabel = New("TextLabel", {
AutomaticSize = Enum.AutomaticSize.X,
BackgroundTransparency = 1,
Size = UDim2.fromOffset(0, 16),
Text = Name,
TextSize = 15,
TextTransparency = 0.5,
Parent = ButtonContent,
})
end
local Line = Library:MakeLine(Button, {
AnchorPoint = Vector2.new(0, 1),
Position = UDim2.new(0, 0, 1, 1),
Size = UDim2.new(1, 0, 0, 1),
})
local Container = New("ScrollingFrame", {
AutomaticCanvasSize = Enum.AutomaticSize.Y,
BackgroundTransparency = 1,
BorderSizePixel = 0,
CanvasSize = UDim2.fromScale(0, 0),
Position = UDim2.fromOffset(0, 35),
ScrollBarThickness = 0,
Size = UDim2.new(1, 0, 1, -35),
Visible = false,
Parent = TabboxHolder,
})
local List = New("UIListLayout", {
Padding = UDim.new(0, 8),
Parent = Container,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 7),
PaddingLeft = UDim.new(0, 7),
PaddingRight = UDim.new(0, 7),
PaddingTop = UDim.new(0, 7),
Parent = Container,
})
local Tab = {
Type = "SubTab",
Name = Name,
Connections = {},
Destroyed = false,
ButtonHolder = Button,
Container = Container,
ButtonCorner = ButtonCorner,
Tab = Tab,
Tabbox = Tabbox,
Elements = {},
DependencyBoxes = {},
}
function Tab:Show()
if Tabbox.ActiveTab then
Tabbox.ActiveTab:Hide()
end
Button.BackgroundTransparency = 1
if ButtonLabel then
ButtonLabel.TextTransparency = 0
end
if ButtonIcon then
ButtonIcon.ImageTransparency = 0
end
Line.Visible = false
Container.Visible = true
Tabbox.ActiveTab = Tab
Tab:Resize()
Tabbox:RefreshPopOutPlaceholder()
end
function Tab:Hide()
Button.BackgroundTransparency = 0
if ButtonLabel then
ButtonLabel.TextTransparency = 0.5
end
if ButtonIcon then
ButtonIcon.ImageTransparency = 0.5
end
Line.Visible = true
Container.Visible = false
Tabbox.ActiveTab = nil
end
function Tab:Resize()
if Tabbox.ActiveTab ~= Tab then
return
end
local ContentSize = (List.AbsoluteContentSize.Y / Library.DPIScale) + 14
if Tabbox.PoppedOut then
ContentSize = math.min(ContentSize, GetPopOutBodyMaxHeight(Tabbox, 35))
end
TabboxHolder.Size = UDim2.new(1, 0, 0, ContentSize + 35)
if IsNested then
ParentObj:Resize()
end
end
function Tab:UpdateCorners()
local Radius = WindowInfo.CornerRadius
ButtonCorner.TopLeftRadius = UDim.new(0, TabIndex == FirstTab and Radius or 0)
ButtonCorner.TopRightRadius = UDim.new(0, TabIndex == LastTab and Radius or 0)
end
function Tab:Destroy()
Tab.Destroyed = true
if Tab.Connections then
for _, Connection in Tab.Connections do
Connection:Disconnect()
end
end
for _, Element in Tab.Elements do
if Element.Destroy then
Element:Destroy()
end
end
for _, SubDepbox in Tab.DependencyBoxes do
if SubDepbox.Destroy then
SubDepbox:Destroy()
end
end
if Container then
Container:Destroy()
end
if Button then
Button:Destroy()
end
end
if not Tabbox.ActiveTab then
Tab:Show()
end
Button.MouseButton1Click:Connect(Tab.Show)
Tab.AddTabbox = AddTabbox
setmetatable(Tab, BaseGroupbox)
Tabbox.Tabs[TabStoringIndex] = Tab
Tabbox:UpdateCorners()
return Tab, TabStoringIndex
end
Library:MakeBoxPopOut(Tabbox, {
Enabled = Info.PopOut ~= false,
MaxPopOutHeight = Info.MaxPopOutHeight,
PopOutWidth = Info.PopOutWidth,
Header = TabboxButtons,
Children = function()
return { TabboxHolder }
end,
After = function()
if Tabbox.ActiveTab then
Tabbox.ActiveTab:Resize()
end
if IsNested then
ParentObj:Resize()
end
end,
})
function Tabbox:Destroy()
if Tabbox.PoppedOut then
Tabbox:SetPoppedOut(false)
end
Tabbox.Destroyed = true
if Tabbox.Connections then
for _, Connection in Tabbox.Connections do
Connection:Disconnect()
end
end
for _, Tab in Tabbox.Tabs do
if Tab.Destroy then
Tab:Destroy()
end
end
if TabboxHolder then
TabboxHolder:Destroy()
end
if BoxHolder then
BoxHolder:Destroy()
end
end
if Info.Name then
Tab.Tabboxes[Info.Name] = Tabbox
else
table.insert(Tab.Tabboxes, Tabbox)
end
return Tabbox
end
Tab.AddTabbox = AddTabbox
function Tab:AddLeftTabbox(Name)
return Tab:AddTabbox({ Side = 1, Name = Name })
end
function Tab:AddRightTabbox(Name)
return Tab:AddTabbox({ Side = 2, Name = Name })
end
function Tab:AddGroupbox(Info)
Info = Library:Validate(Info, Templates.Groupbox)
if typeof(Info.Side) == "string" then
local lowerSide = string.lower(Info.Side)
if not SideIndex[lowerSide] then
error(string.format("Invalid side: %s", Info.Side))
end
Info.Side = SideIndex[lowerSide]
end
local BoxHolder = New("Frame", {
AutomaticSize = Enum.AutomaticSize.Y,
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 0),
Parent = (Info.Side == 1) and TabLeft or TabRight,
})
New("UIListLayout", {
Padding = UDim.new(0, 6),
Parent = BoxHolder,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 4),
PaddingTop = UDim.new(0, 4),
Parent = BoxHolder,
})
local GroupboxHolder
local GroupboxTop
local GroupboxLabel
local GroupboxDescription
local GroupboxContainer
local GroupboxList
local GroupboxCollapseArrow
local GroupboxLine
do
GroupboxHolder = New("Frame", {
BackgroundColor3 = function()
return Library:GetBetterColor(Library.Scheme.BackgroundColor, 3)
end,
Size = UDim2.fromScale(1, 0),
Parent = BoxHolder,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, WindowInfo.CornerRadius),
Parent = GroupboxHolder,
})
)
New("UIListLayout", {
Parent = GroupboxHolder,
})
Library:AddOutline(GroupboxHolder)
GroupboxTop = New("Frame", {
AutomaticSize = Enum.AutomaticSize.Y,
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 0),
Parent = GroupboxHolder,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 6),
PaddingLeft = UDim.new(0, 6),
PaddingRight = UDim.new(0, 6),
PaddingTop = UDim.new(0, 6),
Parent = GroupboxTop,
})
local BoxIcon = Library:GetCustomIcon(Info.IconName)
if BoxIcon then
local IconBadge = New("Frame", {
AnchorPoint = Vector2.new(0, 0.5),
BackgroundColor3 = "AccentColor",
BackgroundTransparency = 0.85,
Position = UDim2.fromScale(0, 0.5),
Size = UDim2.fromOffset(26, 26),
Parent = GroupboxTop,
})
New("UICorner", {
CornerRadius = UDim.new(0, 7),
Parent = IconBadge,
})
local GroupboxHeaderIcon = New("ImageLabel", {
AnchorPoint = Vector2.new(0.5, 0.5),
ImageColor3 = BoxIcon.Custom and "WhiteColor" or "AccentColor",
Position = UDim2.fromScale(0.5, 0.5),
Size = UDim2.fromOffset(15, 15),
Parent = IconBadge,
})
Library:ApplyLucideIcon(GroupboxHeaderIcon, BoxIcon)
end
local RightInset = if Info.DisableCollapsing ~= true then 22 else 0
local TextsFrame = New("Frame", {
AutomaticSize = Enum.AutomaticSize.Y,
BackgroundTransparency = 1,
Position = UDim2.fromOffset(BoxIcon and 30 or 0, 0),
Size = UDim2.new(1, -RightInset - (BoxIcon and 30 or 0), 0, 0),
Parent = GroupboxTop,
})
New("UIListLayout", {
Parent = TextsFrame,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 3),
PaddingLeft = UDim.new(0, 6),
PaddingRight = UDim.new(0, 6),
PaddingTop = UDim.new(0, 3),
Parent = TextsFrame,
})
GroupboxLabel = New("TextLabel", {
AutomaticSize = Enum.AutomaticSize.Y,
BackgroundTransparency = 1,
FontFace = function()
return Font.new(Library.Scheme.Font.Family, Enum.FontWeight.SemiBold)
end,
Size = UDim2.fromScale(1, 0),
Text = Info.Name,
TextSize = 15,
TextWrapped = true,
TextXAlignment = Enum.TextXAlignment.Left,
Parent = TextsFrame,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 1),
Parent = GroupboxLabel,
})
GroupboxDescription = New("TextLabel", {
AutomaticSize = Enum.AutomaticSize.Y,
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 0),
Text = Info.Description or "",
TextSize = 14,
TextTransparency = 0.5,
TextWrapped = true,
TextXAlignment = Enum.TextXAlignment.Left,
Visible = (Info.Description ~= nil),
Parent = TextsFrame,
})
GroupboxCollapseArrow = New("ImageButton", {
Visible = Info.DisableCollapsing ~= true,
AnchorPoint = Vector2.new(1, 0.5),
BackgroundTransparency = 1,
ImageColor3 = "WhiteColor",
Position = UDim2.fromScale(1, 0.5),
Size = UDim2.fromOffset(22, 22),
Parent = GroupboxTop,
})
if ArrowIcon then
Library:ApplyLucideIcon(GroupboxCollapseArrow, ArrowIcon, 180)
end
GroupboxLine = Library:MakeLine(GroupboxHolder, {
LayoutOrder = 1,
Size = UDim2.new(1, 0, 0, 1),
})
Library:AddAccentLine(GroupboxLine, true)
GroupboxContainer = New("ScrollingFrame", {
AutomaticCanvasSize = Enum.AutomaticSize.Y,
BackgroundTransparency = 1,
BorderSizePixel = 0,
CanvasSize = UDim2.fromScale(0, 0),
LayoutOrder = 2,
ScrollBarThickness = 0,
Size = UDim2.fromScale(1, 0),
Parent = GroupboxHolder,
})
GroupboxList = New("UIListLayout", {
Padding = UDim.new(0, 8),
Parent = GroupboxContainer,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 7),
PaddingLeft = UDim.new(0, 7),
PaddingRight = UDim.new(0, 7),
PaddingTop = UDim.new(0, 7),
Parent = GroupboxContainer,
})
end
local Groupbox: any = {
Type = "Groupbox",
Name = Info.Name,
Description = Info.Description,
Connections = {},
Destroyed = false,
Visible = true,
Collapsed = false,
BoxHolder = BoxHolder,
Holder = GroupboxHolder,
Container = GroupboxContainer,
Tab = Tab,
DependencyBoxes = {},
Elements = {}
}
local ResizeTween
local CollapseArrowTween
function Groupbox:Resize()
if ResizeTween then
StopTween(ResizeTween, true)
ResizeTween = nil
end
local TopSize = (GroupboxTop.AbsoluteSize.Y / Library.DPIScale)
local ContainerSize = (GroupboxList.AbsoluteContentSize.Y / Library.DPIScale) + 14
if Groupbox.PoppedOut then
ContainerSize = math.min(ContainerSize, GetPopOutBodyMaxHeight(Groupbox, TopSize + 1))
end
local TargetSize = UDim2.new(1, 0, 0, if Groupbox.Collapsed then TopSize else (TopSize + 1 + ContainerSize))
GroupboxContainer.Size = UDim2.new(1, 0, 0, ContainerSize)
GroupboxLine.Visible = not Groupbox.Collapsed
if Library.Animations and Library.Animations.Groupbox then
local TweenInfo = Library.GroupboxTweenInfo or TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local Tween = TweenService:Create(GroupboxHolder, TweenInfo, { Size = TargetSize })
ResizeTween = Tween
local Connection; Connection = Library:GiveSignal(Tween.Completed:Once(function()
if Connection then
Connection:Disconnect()
end
if ResizeTween == Tween then
StopTween(ResizeTween, true)
ResizeTween = nil
end
end))
Tween:Play()
else
GroupboxHolder.Size = TargetSize
end
end
table.insert(Groupbox.Connections, GroupboxList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
if Groupbox.Visible == false or Groupbox.Destroyed then
return
end
Groupbox:Resize()
end))
function Groupbox:SetDescription(Description: string | nil)
GroupboxDescription.Text = Description or ""
GroupboxDescription.Visible = (Description ~= nil)
Groupbox:Resize()
end
function Groupbox:SetCollapsed(Collapsed: boolean)
if Info.DisableCollapsing == true then return end
Groupbox.Collapsed = Collapsed
if CollapseArrowTween then
StopTween(CollapseArrowTween, true)
CollapseArrowTween = nil
end
local TargetRotation = if Collapsed then 0 else 180
GroupboxContainer.Visible = not Collapsed
if Library.Animations and Library.Animations.Groupbox then
local TweenInfo = Library.GroupboxTweenInfo or TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local Tween = TweenService:Create(GroupboxCollapseArrow, TweenInfo, { Rotation = TargetRotation })
CollapseArrowTween = Tween
local Connection; Connection = Library:GiveSignal(Tween.Completed:Connect(function()
if Connection then
Connection:Disconnect()
end
if CollapseArrowTween == Tween then
StopTween(CollapseArrowTween, true)
CollapseArrowTween = nil
end
end))
Tween:Play()
else
GroupboxCollapseArrow.Rotation = TargetRotation
end
Groupbox:Resize()
end
function Groupbox:ToggleCollapsed()
if Info.DisableCollapsing == true then return end
Groupbox:SetCollapsed(not Groupbox.Collapsed)
end
Library:MakeBoxPopOut(Groupbox, {
Enabled = Info.PopOut ~= false,
MaxPopOutHeight = Info.MaxPopOutHeight,
PopOutWidth = Info.PopOutWidth,
Header = GroupboxTop,
Children = function()
local Children = {}
for _, Child in BoxHolder:GetChildren() do
if Child:IsA("GuiObject") and Child ~= Groupbox.PopOutPlaceholder then
table.insert(Children, Child)
end
end
return Children
end,
Before = function()
GroupboxCollapseArrow.Visible = false
end,
After = function()
GroupboxCollapseArrow.Visible = Info.DisableCollapsing ~= true
Groupbox:Resize()
end
})
function Groupbox:Destroy()
if Groupbox.PoppedOut then
Groupbox:SetPoppedOut(false)
end
Groupbox.Destroyed = true
if ResizeTween then
StopTween(ResizeTween, true)
ResizeTween = nil
end
if CollapseArrowTween then
StopTween(CollapseArrowTween, true)
CollapseArrowTween = nil
end
if Groupbox.Connections then
for _, Connection in Groupbox.Connections do
Connection:Disconnect()
end
end
for _, Element in Groupbox.Elements do
if Element.Destroy then
Element:Destroy()
end
end
table.clear(Groupbox.Elements)
for _, SubDepbox in Groupbox.DependencyBoxes do
if SubDepbox.Destroy then
SubDepbox:Destroy()
end
end
table.clear(Groupbox.DependencyBoxes)
if GroupboxHolder then
GroupboxHolder:Destroy()
end
if BoxHolder then
BoxHolder:Destroy()
end
end
function Groupbox:SetVisible(Visible: boolean)
Groupbox.Visible = Visible
BoxHolder.Visible = Visible
SyncPopOutVisibility(Groupbox)
if Visible == true and Library.Searching then
Library:UpdateSearch(Library.SearchText)
end
end
function Groupbox:Show()
Groupbox:SetVisible(true)
end
function Groupbox:Hide()
Groupbox:SetVisible(false)
end
if Info.DisableCollapsing ~= true then
GroupboxCollapseArrow.MouseButton1Click:Connect(function()
Groupbox:ToggleCollapsed()
end)
end
Groupbox.AddTabbox = AddTabbox
setmetatable(Groupbox, BaseGroupbox)
Groupbox:Resize()
Tab.Groupboxes[Info.Name] = Groupbox
if Info.Visible == false then
Groupbox:Hide()
end
if Info.DisableCollapsing ~= true and Info.Collapsed == true then
Groupbox:SetCollapsed(true)
end
return Groupbox
end
function Tab:AddLeftGroupbox(Name, IconName, Visible, Collapsed, DisableCollapsing)
return Tab:AddGroupbox({ Side = 1, Name = Name, IconName = IconName, Visible = Visible, Collapsed = Collapsed, DisableCollapsing = DisableCollapsing })
end
function Tab:AddRightGroupbox(Name, IconName, Visible, Collapsed, DisableCollapsing)
return Tab:AddGroupbox({ Side = 2, Name = Name, IconName = IconName, Visible = Visible, Collapsed = Collapsed, DisableCollapsing = DisableCollapsing })
end
function Tab:Hover(Hovering)
if Library.ActiveTab == Tab then
return
end
TweenService:Create(TabButton, Library.TweenInfo, {
BackgroundTransparency = Hovering and 0.95 or 1,
}):Play()
TweenService:Create(TabLabel, Library.TweenInfo, {
TextTransparency = Hovering and 0.25 or 0.5,
}):Play()
if TabIcon then
TweenService:Create(TabIcon, Library.TweenInfo, {
ImageTransparency = Hovering and 0.25 or 0.5,
}):Play()
end
end
function Tab:Show()
if Library.ActiveTab == Tab then
return
end
if Library.ActiveTab then
Library.ActiveTab:Hide()
end
TweenService:Create(TabButton, Library.TweenInfo, {
BackgroundTransparency = 0.86,
}):Play()
if TabIndicator then
TweenService:Create(TabIndicator, Library.TweenInfo, {
BackgroundTransparency = 0,
}):Play()
end
TweenService:Create(TabLabel, Library.TweenInfo, {
TextTransparency = 0,
}):Play()
if TabIcon then
TweenService:Create(TabIcon, Library.TweenInfo, {
ImageTransparency = 0,
}):Play()
end
Window:ShowTabInfo(Name, Description)
Library:PlayTabAnimation(Tab, true)
Tab:RefreshSides()
Library.ActiveTab = Tab
if Library.Searching then
Library:UpdateSearch(Library.SearchText)
end
end
function Tab:Hide()
TweenService:Create(TabButton, Library.TweenInfo, {
BackgroundTransparency = 1,
}):Play()
if TabIndicator then
TweenService:Create(TabIndicator, Library.TweenInfo, {
BackgroundTransparency = 1,
}):Play()
end
TweenService:Create(TabLabel, Library.TweenInfo, {
TextTransparency = 0.5,
}):Play()
if TabIcon then
TweenService:Create(TabIcon, Library.TweenInfo, {
ImageTransparency = 0.5,
}):Play()
end
Library:PlayTabAnimation(Tab, false)
Window:HideTabInfo()
Library.PreviousTab = Tab
Library.ActiveTab = nil
end
function Tab:SetVisible(Visible: boolean)
TabButton.Visible = Visible
if not Visible and Library.ActiveTab == Tab then
Tab:Hide()
end
end
function Tab:SetOrder(NewOrder: number)
Order = NewOrder
TabButton.LayoutOrder = Order
end
function Tab:SetTooltip(Text: string?)
Tab.Tooltip = Text
if Tab.TooltipTable then
Tab.TooltipTable:Destroy()
Tab.TooltipTable = nil
end
if typeof(Text) == "string" then
Tab.TooltipTable = Library:AddTooltip(Text, nil, TabButton)
end
end
function Tab:Destroy()
Tab.Destroyed = true
if Tab.Connections then
for _, Connection in Tab.Connections do
Connection:Disconnect()
end
end
if Tab.TooltipTable then
Tab.TooltipTable:Destroy()
Tab.TooltipTable = nil
end
for _, Groupbox in Tab.Groupboxes do
if Groupbox.Destroy then
Groupbox:Destroy()
end
end
table.clear(Tab.Groupboxes)
for _, Tabbox in Tab.Tabboxes do
if Tabbox.Destroy then
Tabbox:Destroy()
end
end
table.clear(Tab.Tabboxes)
for _, DepGroupbox in Tab.DependencyGroupboxes do
if DepGroupbox.Destroy then
DepGroupbox:Destroy()
end
end
if TabContainer then
TabContainer:Destroy()
end
if TabButton then
for Index, Entry in Library.TabButtons do
if typeof(Entry) == "table" and Entry.Button == TabButton then
table.remove(Library.TabButtons, Index)
break
end
end
TabButton:Destroy()
end
Library.Tabs[Name] = nil
end
if typeof(Tooltip) == "string" then
Tab.TooltipTable = Library:AddTooltip(Tooltip, nil, TabButton)
end
if not Library.ActiveTab then
Tab:Show()
end
TabButton.MouseEnter:Connect(function()
Tab:Hover(true)
end)
TabButton.MouseLeave:Connect(function()
Tab:Hover(false)
end)
TabButton.MouseButton1Click:Connect(Tab.Show)
Library.Tabs[Name] = Tab
return Tab
end
function Window:AddKeyTab(...)
local Name = nil
local Icon = nil
local Description = nil
local Tooltip = nil
local Order = nil
if select("#", ...) == 1 and typeof(...) == "table" then
local Info = select(1, ...)
Name = Info.Name or "Tab"
Icon = Info.Icon
Description = Info.Description
Tooltip = Info.Tooltip
Order = Info.Order
else
Name = select(1, ...) or "Tab"
Icon = select(2, ...)
Description = select(3, ...)
Order = select(4, ...)
end
if not tonumber(Order) then
Order = #Tabs:GetChildren()
end
Icon = Icon or "key"
local TabButton: TextButton
local TabIndicator
local TabLabel
local TabIcon
local TabContainer
Icon = if Icon == "key" then KeyIcon else Library:GetCustomIcon(Icon)
do
TabButton = New("TextButton", {
BackgroundColor3 = "AccentColor",
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 38),
Text = "",
LayoutOrder = Order,
Parent = Tabs,
})
New("UICorner", {
CornerRadius = UDim.new(0, TabButtonsStyle.CornerRadius),
Parent = TabButton,
})
if TabButtonsStyle.Indicator then
TabIndicator = New("Frame", {
AnchorPoint = Vector2.new(1, 0.5),
BackgroundColor3 = "AccentColor",
BackgroundTransparency = 1,
Position = UDim2.new(0, -2, 0.5, 0),
Size = UDim2.fromOffset(TabButtonsStyle.IndicatorWidth, TabButtonsStyle.IndicatorHeight),
Parent = TabButton,
})
New("UICorner", {
CornerRadius = UDim.new(1, 0),
Parent = TabIndicator,
})
end
local ButtonHolder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 1),
Parent = TabButton,
})
local ButtonPadding = New("UIPadding", {
PaddingBottom = UDim.new(0, IsCompact and 6 or 11),
PaddingLeft = UDim.new(0, IsCompact and 6 or 12),
PaddingRight = UDim.new(0, IsCompact and 6 or 12),
PaddingTop = UDim.new(0, IsCompact and 6 or 11),
Parent = ButtonHolder,
})
TabLabel = New("TextLabel", {
BackgroundTransparency = 1,
Position = UDim2.fromOffset(30, 0),
Size = UDim2.new(1, -30, 1, 0),
Text = Name,
TextSize = 16,
TextTransparency = 0.5,
TextXAlignment = Enum.TextXAlignment.Left,
Visible = not IsCompact,
Parent = ButtonHolder,
})
if Icon then
TabIcon = New("ImageLabel", {
ImageColor3 = Icon.Custom and "WhiteColor" or "AccentColor",
ImageTransparency = 0.5,
ScaleType = Enum.ScaleType.Fit,
Size = UDim2.fromScale(1, 1),
SizeConstraint = IsCompact and Enum.SizeConstraint.RelativeXY or Enum.SizeConstraint.RelativeYY,
Parent = ButtonHolder,
})
Library:ApplyLucideIcon(TabIcon, Icon)
end
table.insert(Library.TabButtons, {
Label = TabLabel,
Padding = ButtonPadding,
Icon = TabIcon,
})
TabContainer = New("ScrollingFrame", {
AutomaticCanvasSize = Enum.AutomaticSize.Y,
BackgroundTransparency = 1,
CanvasSize = UDim2.fromScale(0, 0),
ScrollBarThickness = 0,
Position = UDim2.fromScale(0, 0),
Size = UDim2.fromScale(1, 1),
Visible = false,
Parent = Container,
})
New("UIListLayout", {
HorizontalAlignment = Enum.HorizontalAlignment.Center,
Padding = UDim.new(0, 8),
VerticalAlignment = Enum.VerticalAlignment.Center,
Parent = TabContainer,
})
New("UIPadding", {
PaddingLeft = UDim.new(0, 1),
PaddingRight = UDim.new(0, 1),
Parent = TabContainer,
})
end
local Tab = {
Description = Description,
IsKeyTab = true,
Tooltip = Tooltip,
TooltipTable = nil,
Elements = {},
Window = Window,
Button = TabButton,
Container = TabContainer
}
function Tab:AddKeyBox(Callback)
assert(typeof(Callback) == "function", "Callback must be a function")
local Holder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(0.75, 0, 0, 21),
Parent = TabContainer,
})
local Box = New("TextBox", {
BackgroundColor3 = "MainColor",
PlaceholderText = "Key",
Size = UDim2.new(1, -71, 1, 0),
TextSize = 14,
TextXAlignment = Enum.TextXAlignment.Left,
Parent = Holder,
})
New("UIPadding", {
PaddingLeft = UDim.new(0, 8),
PaddingRight = UDim.new(0, 8),
Parent = Box,
})
local BoxStroke = New("UIStroke", {
Color = "OutlineColor",
Parent = Box,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = Box,
})
)
Box.Focused:Connect(function()
Library.Registry[BoxStroke].Color = "AccentColor"
TweenService:Create(BoxStroke, Library.TweenInfo, {
Color = Library.Scheme.AccentColor,
}):Play()
end)
Box.FocusLost:Connect(function()
Library.Registry[BoxStroke].Color = "OutlineColor"
TweenService:Create(BoxStroke, Library.TweenInfo, {
Color = Library.Scheme.OutlineColor,
}):Play()
end)
local Button = New("TextButton", {
AnchorPoint = Vector2.new(1, 0),
BackgroundColor3 = "MainColor",
Position = UDim2.fromScale(1, 0),
Size = UDim2.new(0, 63, 1, 0),
Text = "Execute",
TextSize = 14,
TextTransparency = 0.4,
Parent = Holder,
})
New("UIStroke", {
Color = "OutlineColor",
Parent = Button,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius / 2),
Parent = Button,
})
)
Button.MouseEnter:Connect(function()
TweenService:Create(Button, Library.TweenInfo, {
TextTransparency = 0,
}):Play()
end)
Button.MouseLeave:Connect(function()
TweenService:Create(Button, Library.TweenInfo, {
TextTransparency = 0.4,
}):Play()
end)
Button.InputBegan:Connect(function(Input)
if not IsClickInput(Input) then
return
end
if not Library:MouseIsOverFrame(Button, Input.Position) then
return
end
Callback(Box.Text)
Elevate()
end)
end
function Tab:Destroy()
if TabContainer then
TabContainer:Destroy()
end
if TabButton then
for Index, Entry in Library.TabButtons do
if typeof(Entry) == "table" and Entry.Button == TabButton then
table.remove(Library.TabButtons, Index)
break
end
end
TabButton:Destroy()
end
Library.Tabs[Name] = nil
end
function Tab:SetOrder(NewOrder: number)
Order = NewOrder
TabButton.LayoutOrder = Order
end
function Tab:RefreshSides() end
function Tab:Resize() end
function Tab:UpdateCorners() end
function Tab:Hover(Hovering)
if Library.ActiveTab == Tab then
return
end
TweenService:Create(TabButton, Library.TweenInfo, {
BackgroundTransparency = Hovering and 0.95 or 1,
}):Play()
TweenService:Create(TabLabel, Library.TweenInfo, {
TextTransparency = Hovering and 0.25 or 0.5,
}):Play()
if TabIcon then
TweenService:Create(TabIcon, Library.TweenInfo, {
ImageTransparency = Hovering and 0.25 or 0.5,
}):Play()
end
end
function Tab:Show()
if Library.ActiveTab == Tab then
return
end
if Library.ActiveTab then
Library.ActiveTab:Hide()
end
TweenService:Create(TabButton, Library.TweenInfo, {
BackgroundTransparency = 0.86,
}):Play()
if TabIndicator then
TweenService:Create(TabIndicator, Library.TweenInfo, {
BackgroundTransparency = 0,
}):Play()
end
TweenService:Create(TabLabel, Library.TweenInfo, {
TextTransparency = 0,
}):Play()
if TabIcon then
TweenService:Create(TabIcon, Library.TweenInfo, {
ImageTransparency = 0,
}):Play()
end
Library:PlayTabAnimation(Tab, true)
Window:ShowTabInfo(Name, Description)
Tab:RefreshSides()
Library.ActiveTab = Tab
if Library.Searching then
Library:UpdateSearch(Library.SearchText)
end
end
function Tab:Hide()
TweenService:Create(TabButton, Library.TweenInfo, {
BackgroundTransparency = 1,
}):Play()
if TabIndicator then
TweenService:Create(TabIndicator, Library.TweenInfo, {
BackgroundTransparency = 1,
}):Play()
end
TweenService:Create(TabLabel, Library.TweenInfo, {
TextTransparency = 0.5,
}):Play()
if TabIcon then
TweenService:Create(TabIcon, Library.TweenInfo, {
ImageTransparency = 0.5,
}):Play()
end
Library:PlayTabAnimation(Tab, false)
Window:HideTabInfo()
Library.PreviousTab = Tab
Library.ActiveTab = nil
end
function Tab:SetVisible(Visible: boolean)
TabButton.Visible = Visible
if not Visible and Library.ActiveTab == Tab then
Tab:Hide()
end
end
function Tab:SetTooltip(Text: string?)
Tab.Tooltip = Text
if Tab.TooltipTable then
Tab.TooltipTable:Destroy()
Tab.TooltipTable = nil
end
if typeof(Text) == "string" then
Tab.TooltipTable = Library:AddTooltip(Text, nil, TabButton)
end
end
if typeof(Tooltip) == "string" then
Tab.TooltipTable = Library:AddTooltip(Tooltip, nil, TabButton)
end
if not Library.ActiveTab then
Tab:Show()
end
TabButton.MouseEnter:Connect(function()
Tab:Hover(true)
end)
TabButton.MouseLeave:Connect(function()
Tab:Hover(false)
end)
TabButton.MouseButton1Click:Connect(Tab.Show)
Tab.Container = TabContainer
setmetatable(Tab, BaseGroupbox)
Library.Tabs[Name] = Tab
return Tab
end
function Window:AddDialog(Idx, Info)
Info = Library:Validate(Info, Templates.Dialog)
local DialogFrame
local DialogOverlay
local DialogContainer
local ButtonsHolder
local FooterButtonsList = {}
DialogOverlay = New("TextButton", {
AutoButtonColor = false,
BackgroundColor3 = "DarkColor",
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 1),
Text = "",
Active = false,
ZIndex = 9000,
Visible = true,
Parent = MainFrame,
})
TweenService:Create(DialogOverlay, Library.TweenInfo, {
BackgroundTransparency = 0.5,
}):Play()
DialogFrame = New("TextButton", {
AnchorPoint = Vector2.new(0.5, 0.5),
BackgroundColor3 = "BackgroundColor",
Position = UDim2.fromScale(0.5, 0.5),
Size = UDim2.fromOffset(300, 0),
AutomaticSize = Enum.AutomaticSize.Y,
Text = "",
AutoButtonColor = false,
ZIndex = 1,
Parent = DialogOverlay,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, WindowInfo.CornerRadius),
Parent = DialogFrame,
})
)
Library:AddOutline(DialogFrame)
local InnerContainer = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 0),
AutomaticSize = Enum.AutomaticSize.Y,
ZIndex = 2,
Parent = DialogFrame,
})
local DialogScale = New("UIScale", {
Scale = 0.95,
Parent = DialogFrame,
})
TweenService:Create(DialogScale, Library.TweenInfo, {
Scale = 1
}):Play()
local _InnerPadding = New("UIPadding", {
PaddingBottom = UDim.new(0, 15),
PaddingLeft = UDim.new(0, 15),
PaddingRight = UDim.new(0, 15),
PaddingTop = UDim.new(0, 15),
Parent = InnerContainer,
})
local _InnerLayout = New("UIListLayout", {
Padding = UDim.new(0, 10),
SortOrder = Enum.SortOrder.LayoutOrder,
Parent = InnerContainer,
})
local HeaderContainer = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 0),
AutomaticSize = Enum.AutomaticSize.Y,
LayoutOrder = 1,
ZIndex = 2,
Parent = InnerContainer,
})
New("UIListLayout", {
Padding = UDim.new(0, 6),
SortOrder = Enum.SortOrder.LayoutOrder,
Parent = HeaderContainer,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 5),
Parent = HeaderContainer,
})
local TitleRow = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 20),
AutomaticSize = Enum.AutomaticSize.Y,
LayoutOrder = 1,
ZIndex = 2,
Parent = HeaderContainer,
})
New("UIListLayout", {
Padding = UDim.new(0, 6),
FillDirection = Enum.FillDirection.Horizontal,
VerticalAlignment = Enum.VerticalAlignment.Center,
SortOrder = Enum.SortOrder.LayoutOrder,
Parent = TitleRow,
})
if Info.Icon then
local ParsedIcon = Library:GetCustomIcon(Info.Icon)
if ParsedIcon then
local IconImg = New("ImageLabel", {
BackgroundTransparency = 1,
Size = UDim2.fromOffset(16, 16),
ImageColor3 = Info.TitleColor or "FontColor",
LayoutOrder = 1,
ZIndex = 2,
Parent = TitleRow,
})
Library:ApplyLucideIcon(IconImg, ParsedIcon)
end
end
local TitleLabel = New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 18),
AutomaticSize = Enum.AutomaticSize.Y,
Text = Info.Title,
TextSize = 18,
TextColor3 = Info.TitleColor or "FontColor",
TextXAlignment = Enum.TextXAlignment.Left,
LayoutOrder = 2,
ZIndex = 2,
Parent = TitleRow,
})
local DescriptionLabel = New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 14),
AutomaticSize = Enum.AutomaticSize.Y,
Text = Info.Description,
TextSize = 14,
TextTransparency = Info.DescriptionColor and 0 or 0.2,
TextXAlignment = Enum.TextXAlignment.Left,
TextColor3 = Info.DescriptionColor or "FontColor",
TextWrapped = true,
LayoutOrder = 2,
ZIndex = 2,
Parent = HeaderContainer,
})
DialogContainer = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 0),
AutomaticSize = Enum.AutomaticSize.Y,
LayoutOrder = 4,
ZIndex = 2,
Parent = InnerContainer,
})
local _DialogContainerLayout = New("UIListLayout", {
Padding = UDim.new(0, 8),
SortOrder = Enum.SortOrder.LayoutOrder,
Parent = DialogContainer,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 5),
Parent = DialogContainer,
})
local _Sep2 = New("Frame", {
BackgroundColor3 = "OutlineColor",
BackgroundTransparency = 0,
BorderSizePixel = 0,
Size = UDim2.new(1, 0, 0, 1),
LayoutOrder = 5,
ZIndex = 2,
Parent = InnerContainer,
})
ButtonsHolder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 0),
AutomaticSize = Enum.AutomaticSize.Y,
LayoutOrder = 6,
ZIndex = 2,
Parent = InnerContainer,
})
New("UIListLayout", {
Padding = UDim.new(0, 8),
FillDirection = Enum.FillDirection.Horizontal,
HorizontalAlignment = Enum.HorizontalAlignment.Right,
Wraps = true,
SortOrder = Enum.SortOrder.LayoutOrder,
Parent = ButtonsHolder,
})
New("UIPadding", {
PaddingTop = UDim.new(0, 5),
Parent = ButtonsHolder,
})
local Dialog = {
Destroyed = false,
Elements = {},
Container = DialogContainer,
OutsideClickDismiss = Info.OutsideClickDismiss,
}
function Dialog:Resize()
local MaxWidth = (MainFrame.AbsoluteSize.X / Library.DPIScale) * 0.75
local MinWidth = 400
local TotalButtonWidth = 0
local ButtonCount = 0
local HasButtons = false
for _, BtnWrap in FooterButtonsList do
HasButtons = true
ButtonCount = ButtonCount + 1
TotalButtonWidth = TotalButtonWidth + BtnWrap.Container.Size.X.Offset
end
local TargetWidth = MinWidth
if HasButtons then
local RequiredWidth = TotalButtonWidth + ((ButtonCount - 1) * 8) + 30
TargetWidth = math.max(MinWidth, math.min(RequiredWidth, MaxWidth))
end
DialogFrame.Size = UDim2.fromOffset(TargetWidth, 0)
local _DescX, DescY = Library:GetTextBounds(DescriptionLabel.Text, Library.Scheme.Font, 14, TargetWidth - 30)
DescriptionLabel.Size = UDim2.new(1, 0, 0, DescY)
local HasElements = false
for _, v in DialogContainer:GetChildren() do
if not v:IsA("UIListLayout") and not v:IsA("UIPadding") then
HasElements = true
break
end
end
DialogContainer.Visible = HasElements
ButtonsHolder.Visible = HasButtons
_Sep2.Visible = HasButtons
end
function Dialog:SetTitle(Title)
TitleLabel.Text = Title
Dialog:Resize()
end
function Dialog:SetDescription(Description)
DescriptionLabel.Text = Description
Dialog:Resize()
end
function Dialog:Dismiss()
if Dialog.Destroyed then
return
end
Dialog.Destroyed = true
if Library.ActiveDialog == Dialog then
Library.ActiveDialog = nil
end
for Index = #Dialog.Elements, 1, -1 do
local Element = Dialog.Elements[Index]
if Element and Element.Destroy then
Element:Destroy()
end
end
table.clear(Dialog.Elements)
local CloseTween = TweenService:Create(DialogScale, Library.TweenInfo, { Scale = 0.95 })
TweenService:Create(DialogOverlay, Library.TweenInfo, { BackgroundTransparency = 1 }):Play()
CloseTween:Play()
task.delay(Library.TweenInfo.Time, function()
DialogOverlay:Destroy()
end)
Library.Dialogues[Idx] = nil
end
DialogOverlay.MouseButton1Click:Connect(function()
if Info.OutsideClickDismiss then
Dialog:Dismiss()
end
end)
function Dialog:RemoveFooterButton(ButtonIdx)
if FooterButtonsList[ButtonIdx] then
FooterButtonsList[ButtonIdx].Container:Destroy()
FooterButtonsList[ButtonIdx] = nil
end
end
function Dialog:SetButtonDisabled(ButtonIdx, Disabled)
if FooterButtonsList[ButtonIdx] and type(FooterButtonsList[ButtonIdx].SetDisabled) == "function" then
FooterButtonsList[ButtonIdx]:SetDisabled(Disabled)
end
end
function Dialog:SetButtonOrder(ButtonIdx, Order)
if FooterButtonsList[ButtonIdx] and FooterButtonsList[ButtonIdx].Container then
FooterButtonsList[ButtonIdx].Container.LayoutOrder = Order
end
end
function Dialog:AddFooterButton(ButtonIdx, ButtonInfo)
Dialog:RemoveFooterButton(ButtonIdx)
local WaitTime = ButtonInfo.WaitTime or 0
local ButtonContainer = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.fromOffset(0, 26),
LayoutOrder = ButtonInfo.Order or 0,
ZIndex = 2,
Parent = ButtonsHolder,
})
local BtnColor = "MainColor"
local BtnOutline = "OutlineColor"
local Variant = ButtonInfo.Variant or "Primary"
if Variant == "Primary" then
BtnColor = "FontColor"
BtnOutline = "FontColor"
elseif Variant == "Secondary" then
BtnColor = "MainColor"
BtnOutline = "OutlineColor"
elseif Variant == "Destructive" then
BtnColor = "DestructiveColor"
BtnOutline = "DestructiveColor"
elseif Variant == "Ghost" then
BtnColor = "BackgroundColor"
BtnOutline = "BackgroundColor"
end
local TextBtn = New("TextButton", {
BackgroundColor3 = BtnColor,
BorderColor3 = BtnOutline,
BackgroundTransparency = WaitTime > 0 and 0.5 or 0,
Size = UDim2.fromOffset(0, 26),
Text = "",
AutoButtonColor = false,
ZIndex = 2,
Parent = ButtonContainer,
})
Library:AddOutline(TextBtn)
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius),
Parent = TextBtn
})
)
local _BtnPadding = New("UIPadding", {
PaddingLeft = UDim.new(0, 15),
PaddingRight = UDim.new(0, 15),
Parent = TextBtn,
})
local TextColor = Library.Scheme.FontColor
if Variant == "Primary" then
TextColor = Library.Scheme.BackgroundColor
elseif Variant == "Destructive" then
TextColor = Color3.new(1, 1, 1)
end
local BtnLabel = New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 1),
Text = ButtonInfo.Title or ButtonIdx,
TextColor3 = TextColor,
TextTransparency = WaitTime > 0 and 0.5 or 0,
TextSize = 14,
ZIndex = 2,
Parent = TextBtn,
})
local LabelX, _ = Library:GetTextBounds(BtnLabel.Text, Library.Scheme.Font, 14, 250)
ButtonContainer.Size = UDim2.fromOffset(LabelX + 30, 26)
TextBtn.Size = UDim2.fromOffset(LabelX + 30, 26)
local ProgressBar
if WaitTime > 0 then
ProgressBar = New("Frame", {
BackgroundColor3 = "AccentColor",
BorderSizePixel = 0,
Position = UDim2.new(0, 0, 1, -2),
Size = UDim2.new(0, 0, 0, 2),
ZIndex = 2,
Parent = TextBtn,
})
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius),
Parent = ProgressBar
})
)
end
local IsActive = WaitTime <= 0
local ButtonWrap = {
Container = ButtonContainer,
SetDisabled = function(self, Disabled)
IsActive = not Disabled
if Disabled then
TweenService:Create(TextBtn, Library.TweenInfo, { BackgroundTransparency = 0.5 }):Play()
TweenService:Create(BtnLabel, Library.TweenInfo, { TextTransparency = 0.5 }):Play()
else
TweenService:Create(TextBtn, Library.TweenInfo, { BackgroundTransparency = 0 }):Play()
TweenService:Create(BtnLabel, Library.TweenInfo, { TextTransparency = 0 }):Play()
end
end
}
local ActiveColor = typeof(BtnColor) == "Color3" and BtnColor or Library.Scheme[BtnColor]
local HoverColor = Variant == "Ghost" and Library.Scheme.MainColor or Library:GetBetterColor(ActiveColor, 10)
TextBtn.MouseEnter:Connect(function()
if not IsActive then return end
TweenService:Create(TextBtn, Library.TweenInfo, {
BackgroundColor3 = HoverColor
}):Play()
end)
TextBtn.MouseLeave:Connect(function()
if not IsActive then return end
TweenService:Create(TextBtn, Library.TweenInfo, {
BackgroundColor3 = ActiveColor
}):Play()
end)
TextBtn.MouseButton1Click:Connect(function()
if not IsActive then return end
if ButtonInfo.Callback then
ButtonInfo.Callback(Dialog)
Elevate()
end
if Info.AutoDismiss then
Dialog:Dismiss()
end
end)
if WaitTime > 0 then
TweenService:Create(ProgressBar, TweenInfo.new(WaitTime, Enum.EasingStyle.Linear), {
Size = UDim2.new(1, 0, 0, 2)
}):Play()
task.delay(WaitTime, function()
ButtonWrap:SetDisabled(false)
if ProgressBar then
TweenService:Create(ProgressBar, Library.TweenInfo, {
BackgroundTransparency = 1
}):Play()
end
end)
end
FooterButtonsList[ButtonIdx] = ButtonWrap
end
for BIdx, BInfo in Info.FooterButtons do
if type(BIdx) == "number" and BInfo.Id then BIdx = BInfo.Id end
Dialog:AddFooterButton(BIdx, BInfo)
end
setmetatable(Dialog, BaseGroupbox)
Library.Dialogues[Idx] = Dialog
Dialog:Resize()
Library.ActiveDialog = Dialog
return Dialog
end
local GuiProperties = { "BackgroundTransparency" }
local ImageProperties = { "BackgroundTransparency", "ImageTransparency" }
local TextProperties = { "BackgroundTransparency", "TextTransparency" }
local StrokeProperties = { "Transparency" }
local function FadeInstance(Desc, Properties)
local Cache = TransparencyCache[Desc]
if not Cache then
Cache = {}
TransparencyCache[Desc] = Cache
end
for _, Prop in Properties do
if not Library.Toggled then
Cache[Prop] = Desc[Prop]
end
if Cache[Prop] ~= nil and Cache[Prop] ~= 1 then
TweenService:Create(Desc, Library.WindowAnimationInfo, {
[Prop] = Library.Toggled and Cache[Prop] or 1,
}):Play()
end
end
end
function Window:Toggle(Value: boolean?)
if Fading then
return
end
if Library.ActiveLoading then
if Value == true then
return
end
if not Library.Toggled then
return
end
end
if typeof(Value) == "boolean" and Value == Library.Toggled and (MainFrame.Visible == Value) then
return
end
if typeof(Value) == "boolean" then
Library.Toggled = Value
else
Library.Toggled = not Library.Toggled
end
UpdateFloatingButton()
if Library.Animations and Library.Animations.ToggleWindow == true then
local FadeTime = Library.WindowAnimationInfo.Time
local SlideOrigin = MainFrame.Position
local SlideOffset = UDim2.fromOffset(0, 18)
Fading = true
if Library.Toggled then
MainFrame.Visible = true
MainFrame.Position = SlideOrigin + SlideOffset
TweenService:Create(MainFrame, Library.WindowAnimationInfo, { Position = SlideOrigin }):Play()
else
TweenService:Create(MainFrame, Library.WindowAnimationInfo, { Position = SlideOrigin + SlideOffset }):Play()
task.delay(FadeTime, function()
if not Library.Toggled then
MainFrame.Position = SlideOrigin
end
end)
end
if Library.Toggled then
FadeInstance(MainFrame, { "BackgroundTransparency" })
task.wait(FadeTime / 2)
else
task.delay(FadeTime / 2, FadeInstance, MainFrame, { "BackgroundTransparency" })
end
for _, Instance in MainFrame:GetDescendants() do
if Instance == TopBar then
continue
end
if Instance:IsA("GuiObject") then
local ClassName = Instance.ClassName
if ClassName == "ImageLabel" or ClassName == "ImageButton" then
FadeInstance(Instance, ImageProperties)
elseif ClassName == "TextLabel" or ClassName == "TextBox" or ClassName == "TextButton" then
FadeInstance(Instance, TextProperties)
else
FadeInstance(Instance, GuiProperties)
end
elseif Instance.ClassName == "UIStroke" then
FadeInstance(Instance, StrokeProperties)
end
end
task.delay(FadeTime, function()
MainFrame.Visible = Library.Toggled
Fading = false
end)
else
MainFrame.Visible = Library.Toggled
end
if WindowInfo.UnlockMouseWhileOpen then
ModalElement.Modal = Library.Toggled
end
if Library.Toggled and not Library.IsMobile then
local ShowCursorBinding = Library.ShowCursorBinding
Library.OriginalMouseIconEnabled = UserInputService.MouseIconEnabled
pcall(function() RunService:UnbindFromRenderStep(ShowCursorBinding) end)
RunService:BindToRenderStep(ShowCursorBinding, Enum.RenderPriority.Last.Value, function()
UserInputService.MouseIconEnabled = not Library.ShowCustomCursor
Cursor.Position = UDim2.fromOffset(Mouse.X, Mouse.Y)
Cursor.Visible = Library.ShowCustomCursor
if Library.Unloaded == true or not (Library.Toggled and ScreenGui and ScreenGui.Parent) then
RestoreMouseIcon()
end
end)
elseif not Library.Toggled then
RestoreMouseIcon()
TooltipLabel.Visible = false
for _, Option in Library.Options do
if Option.Type == "ColorPicker" then
Option.ColorMenu:Close()
Option.ContextMenu:Close()
elseif Option.Type == "Dropdown" or Option.Type == "KeyPicker" then
Option.Menu:Close()
end
end
end
end
function Library:Toggle(Value: boolean?)
return Window:Toggle(Value)
end
local Collapsed = false
local ExpandedHeight
function Window:IsCollapsed()
return Collapsed
end
function Window:SetCollapsed(State: boolean)
if State == Collapsed then
return
end
Collapsed = State
local Width = MainFrame.Size.X.Offset
if ProfileCard then
ProfileCard.Visible = not State
end
if State then
ExpandedHeight = MainFrame.Size.Y.Offset
MainFrame.ClipsDescendants = true
ResizeGrip.Visible = false
TweenService:Create(MainFrame, Library.WindowAnimationInfo, {
Size = UDim2.fromOffset(Width, HeaderHeight + 1),
}):Play()
TweenService:Create(SidebarPanel, Library.WindowAnimationInfo, {
Size = UDim2.new(0, Window:GetSidebarWidth(), 0, HeaderHeight + 1),
}):Play()
else
local Grow = TweenService:Create(MainFrame, Library.WindowAnimationInfo, {
Size = UDim2.fromOffset(Width, ExpandedHeight or WindowInfo.Size.Y.Offset),
})
Grow.Completed:Once(function()
if not Collapsed then
MainFrame.ClipsDescendants = false
ResizeGrip.Visible = true
end
end)
Grow:Play()
TweenService:Create(SidebarPanel, Library.WindowAnimationInfo, {
Size = UDim2.new(0, Window:GetSidebarWidth(), 1, 0),
}):Play()
end
end
Library:GiveSignal(MinimizeButton.MouseButton1Click:Connect(function()
Window:SetCollapsed(not Collapsed)
end))
Library:GiveSignal(CloseWindowButton.MouseButton1Click:Connect(function()
Library:Toggle(false)
end))
if WindowInfo.FloatingButton then
local Bubble = Library:MakeBadge(ScreenGui, 48, WindowInfo.Icon, WindowInfo.Title)
local FloatingButton = Bubble.Holder
FloatingButton.AnchorPoint = Vector2.new(0.5, 0.5)
FloatingButton.Position = UDim2.new(0, 48, 0.62, 0)
FloatingButton.Visible = false
FloatingButton.ZIndex = 20
Bubble.Glyph.ZIndex = 21
New("UIStroke", {
Color = "AccentColor",
Thickness = 2,
Transparency = 0.35,
Parent = FloatingButton,
})
local BubbleScale = New("UIScale", {
Parent = FloatingButton,
})
local Hitbox = New("TextButton", {
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 1),
Text = "",
ZIndex = 22,
Parent = FloatingButton,
})
Library:MakeDraggable(FloatingButton, Hitbox, true, false)
local PressedAt
Hitbox.InputBegan:Connect(function(Input: InputObject)
if IsClickInput(Input) then
PressedAt = Input.Position
end
end)
Hitbox.InputEnded:Connect(function(Input: InputObject)
-- IsClickInput only accepts Begin-state inputs, so a release never passed it.
if not IsMouseInput(Input) or not PressedAt then
return
end
local Moved = (Input.Position - PressedAt).Magnitude
PressedAt = nil
if Moved < 6 then
Library:Toggle(true)
end
end)
Hitbox.MouseEnter:Connect(function()
TweenService:Create(BubbleScale, Library.TweenInfo, { Scale = 1.08 }):Play()
end)
Hitbox.MouseLeave:Connect(function()
TweenService:Create(BubbleScale, Library.TweenInfo, { Scale = 1 }):Play()
end)
UpdateFloatingButton = function()
RestoreIdentity()
local Show = not Library.Toggled and not IntroPlaying and not Library.Unloaded
if Show == FloatingButton.Visible then
return
end
FloatingButton.Visible = Show
if Show then
BubbleScale.Scale = 0.5
TweenService:Create(BubbleScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
Scale = 1,
}):Play()
end
end
end
local function PlayIntro()
IntroPlaying = true
local Card = New("CanvasGroup", {
AnchorPoint = Vector2.new(0.5, 0.5),
BackgroundColor3 = function()
return Library:GetBetterColor(Library.Scheme.BackgroundColor, 1)
end,
GroupTransparency = 1,
Position = UDim2.fromScale(0.5, 0.5),
Size = UDim2.fromOffset(300, 150),
ZIndex = 200,
Parent = ScreenGui,
})
New("UICorner", {
CornerRadius = UDim.new(0, 14),
Parent = Card,
})
New("UIStroke", {
Color = "OutlineColor",
Parent = Card,
})
local CardScale = New("UIScale", {
Scale = 0.9,
Parent = Card,
})
New("UIListLayout", {
HorizontalAlignment = Enum.HorizontalAlignment.Center,
VerticalAlignment = Enum.VerticalAlignment.Center,
Padding = UDim.new(0, 8),
SortOrder = Enum.SortOrder.LayoutOrder,
Parent = Card,
})
local Logo = Library:MakeBadge(Card, 46, WindowInfo.Icon, WindowInfo.Title)
Logo.Holder.LayoutOrder = 1
New("TextLabel", {
BackgroundTransparency = 1,
FontFace = function()
return Font.new(Library.Scheme.Font.Family, Enum.FontWeight.Bold)
end,
LayoutOrder = 2,
Size = UDim2.new(1, -40, 0, 20),
Text = WindowInfo.Title,
TextSize = 19,
TextTruncate = Enum.TextTruncate.AtEnd,
Parent = Card,
})
local Status = New("TextLabel", {
BackgroundTransparency = 1,
LayoutOrder = 3,
Size = UDim2.new(1, -40, 0, 14),
Text = "Loading interface...",
TextSize = 13,
TextTransparency = 0.5,
Parent = Card,
})
local Bar = New("Frame", {
BackgroundColor3 = "OutlineColor",
LayoutOrder = 4,
Size = UDim2.fromOffset(200, 4),
Parent = Card,
})
New("UICorner", {
CornerRadius = UDim.new(1, 0),
Parent = Bar,
})
local Fill = New("Frame", {
BackgroundColor3 = "WhiteColor",
Size = UDim2.fromScale(0, 1),
Parent = Bar,
})
New("UICorner", {
CornerRadius = UDim.new(1, 0),
Parent = Fill,
})
New("UIGradient", {
Color = function()
return Library:GetAccentSequence()
end,
Parent = Fill,
})
TweenService:Create(Card, TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
GroupTransparency = 0,
}):Play()
TweenService:Create(CardScale, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
Scale = 1,
}):Play()
task.wait(0.25)
RestoreIdentity()
TweenService:Create(Fill, TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
Size = UDim2.fromScale(1, 1),
}):Play()
task.wait(1)
RestoreIdentity()
Status.Text = "Ready"
task.wait(0.2)
RestoreIdentity()
TweenService:Create(Card, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {
GroupTransparency = 1,
}):Play()
TweenService:Create(CardScale, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {
Scale = 0.94,
}):Play()
task.wait(0.25)
RestoreIdentity()
Card:Destroy()
IntroPlaying = false
end
if WindowInfo.EnableSidebarResize then
local Threshold = (WindowInfo.MinSidebarWidth + WindowInfo.SidebarCompactWidth) * WindowInfo.SidebarCollapseThreshold
local StartPos, StartWidth
local Dragging = false
local Changed
local SidebarGrabber = New("TextButton", {
AnchorPoint = Vector2.new(0.5, 0),
BackgroundTransparency = 1,
Position = UDim2.fromScale(0.5, 0),
Size = UDim2.new(0, 8, 1, 0),
Text = "",
Parent = DividerLine,
})
SidebarGrabber.MouseEnter:Connect(function()
TweenService:Create(DividerLine, Library.TweenInfo, {
BackgroundColor3 = Library:GetLighterColor(Library.Scheme.OutlineColor),
}):Play()
end)
SidebarGrabber.MouseLeave:Connect(function()
if Dragging then
return
end
TweenService:Create(DividerLine, Library.TweenInfo, {
BackgroundColor3 = Library.Scheme.OutlineColor,
}):Play()
end)
SidebarGrabber.InputBegan:Connect(function(Input: InputObject)
if not IsClickInput(Input) then
return
end
Library.CantDragForced = true
StartPos = Input.Position
StartWidth = Window:GetSidebarWidth()
Dragging = true
Changed = Input.Changed:Connect(function()
if Input.UserInputState ~= Enum.UserInputState.End then
return
end
Library.CantDragForced = false
TweenService:Create(DividerLine, Library.TweenInfo, {
BackgroundColor3 = Library.Scheme.OutlineColor,
}):Play()
Dragging = false
if Changed and Changed.Connected then
Changed:Disconnect()
Changed = nil
end
end)
end)
Library:GiveSignal(UserInputService.InputChanged:Connect(function(Input: InputObject)
if not Library.Toggled or not (ScreenGui and ScreenGui.Parent) then
Dragging = false
if Changed and Changed.Connected then
Changed:Disconnect()
Changed = nil
end
return
end
if Dragging and IsHoverInput(Input) then
local Delta = Input.Position - StartPos
local Width = StartWidth + Delta.X
if WindowInfo.DisableCompactingSnap then
Window:SetSidebarWidth(Width)
return
end
if Width > Threshold then
Window:SetSidebarWidth(math.max(Width, WindowInfo.MinSidebarWidth))
else
Window:SetSidebarWidth(WindowInfo.SidebarCompactWidth)
end
end
end))
end
Window:SetAlwaysOnTop(WindowInfo.AlwaysOnTop)
if WindowInfo.EnableCompacting and WindowInfo.SidebarCompacted then
Window:SetSidebarWidth(WindowInfo.SidebarCompactWidth)
end
if WindowInfo.AutoShow and not Library.ActiveLoading then
task.spawn(function()
if WindowInfo.Intro then
local Ok, Error = pcall(PlayIntro)
if not Ok then
warn("Intro splash failed: " .. tostring(Error))
end
IntroPlaying = false
end
RestoreIdentity()
if not Library.Unloaded then
Library:Toggle(true)
end
end)
else
UpdateFloatingButton()
end
if Library.IsMobile then
local ToggleButton = Library:AddDraggableButton("Toggle", function()
Library:Toggle()
end, true, true)
local LockButton = Library:AddDraggableButton("Lock", function(self)
Library.CantDragForced = not Library.CantDragForced
self:SetText(Library.CantDragForced and "Unlock" or "Lock")
end, true, true)
if WindowInfo.MobileButtonsSide == "Right" then
ToggleButton.Button.AnchorPoint = Vector2.new(1, 0)
ToggleButton.Button.Position = UDim2.new(1, -6, 0, 6)
LockButton.Button.AnchorPoint = Vector2.new(1, 0)
LockButton.Button.Position = UDim2.new(1, -(ToggleButton.Button.Size.X.Offset + 12), 0, 6)
else
ToggleButton.Button.AnchorPoint = Vector2.new(0, 0)
ToggleButton.Button.Position = UDim2.fromOffset(6, 6)
LockButton.Button.AnchorPoint = Vector2.new(0, 0)
LockButton.Button.Position = UDim2.fromOffset(ToggleButton.Button.Size.X.Offset + 12, 6)
end
if WindowInfo.ShowMobileButtons == false then
ToggleButton.Button.Visible = false
LockButton.Button.Visible = false
end
end
Library:GiveSignal(SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
Library:UpdateSearch(SearchBox.Text)
end))
Library:GiveSignal(UserInputService.InputBegan:Connect(function(Input: InputObject)
if Library.Unloaded then
return
end
if Input.KeyCode == Enum.KeyCode.Escape then
local FocusedBox = UserInputService:GetFocusedTextBox()
if FocusedBox then
FocusedBox:ReleaseFocus()
return
end
if Library.ActiveDialog and Library.ActiveDialog.OutsideClickDismiss ~= false then
Library.ActiveDialog:Dismiss()
return
end
if CurrentMenu then
CurrentMenu:Close()
return
end
return
end
if UserInputService:GetFocusedTextBox() then
return
end
if Input.KeyCode == Library.ToggleKeybind then
Library:Toggle()
end
end))
Library:GiveSignal(UserInputService.WindowFocused:Connect(function()
Library.IsRobloxFocused = true
end))
Library:GiveSignal(UserInputService.WindowFocusReleased:Connect(function()
Library.IsRobloxFocused = false
end))
Window.MainFrame = MainFrame
Library.Window = Window
return Window
end
function Library:CreateLoading(LoadingInfo)
if Library.ActiveLoading then
warn("Loading GUI already exists, you cannot create multiple Loading GUIs.")
return Library.ActiveLoading
end
LoadingInfo = Library:Validate(LoadingInfo, Templates.Loading)
local Loading = {
CurrentStep = LoadingInfo.CurrentStep,
TotalSteps = LoadingInfo.TotalSteps,
ShowSidebar = LoadingInfo.ShowSidebar,
AutoResizeHeight = LoadingInfo.AutoResizeHeight,
AlwaysOnTop = LoadingInfo.AlwaysOnTop,
IsError = false,
Destroyed = false,
WindowWidth = LoadingInfo.WindowWidth,
WindowHeight = LoadingInfo.WindowHeight,
BaseWindowHeight = LoadingInfo.WindowHeight,
WindowErrorHeight = LoadingInfo.WindowHeight,
ContentWidth = LoadingInfo.ContentWidth,
SidebarWidth = LoadingInfo.SidebarWidth,
}
local ScreenGui = New("ScreenGui", {
Name = "ObsidianLoading",
DisplayOrder = 999,
ResetOnSpawn = false
})
ParentUI(ScreenGui)
Loading.ScreenGui = ScreenGui
SetAlwaysOnTop(ScreenGui, LoadingInfo.AlwaysOnTop)
ScreenGui.DescendantRemoving:Connect(function(Instance)
task.defer(function()
if Instance.Parent and Instance:IsDescendantOf(ScreenGui) then
return
end
Library:RemoveFromRegistry(Instance)
end)
end)
local MainFrame = New("TextButton", {
Name = "Main",
AnchorPoint = Vector2.new(0.5, 0.5),
BackgroundColor3 = function()
return Library:GetBetterColor(Library.Scheme.BackgroundColor, -1)
end,
Position = UDim2.fromScale(0.5, 0.5),
Size = UDim2.fromOffset(Loading.ShowSidebar and (Loading.ContentWidth + Loading.SidebarWidth) or Loading.WindowWidth, Loading.WindowHeight),
ClipsDescendants = true,
Text = "",
AutoButtonColor = false,
Parent = ScreenGui,
})
Library:AddOutline(MainFrame)
table.insert(Library.Corners, New("UICorner", { CornerRadius = UDim.new(0, Library.CornerRadius), Parent = MainFrame }))
local MainScale = New("UIScale", {
Scale = Library.IsMobile and 0.8 or 1,
Parent = MainFrame
})
table.insert(Library.Scales, MainScale)
Library.ScalesOffset[MainScale] = Library.IsMobile and 0.2 or 0
local Container = New("Frame", {
Name = "Content",
BackgroundTransparency = 1,
Position = UDim2.fromOffset(0, 0),
Size = UDim2.new(0, Loading.ContentWidth, 1, 0),
Parent = MainFrame,
})
local SideBar = New("Frame", {
Name = "SideBar",
BackgroundTransparency = 1,
Position = UDim2.fromOffset(Loading.ContentWidth, 0),
Size = UDim2.new(0, Loading.ShowSidebar and Loading.SidebarWidth or 0, 1, 0),
ClipsDescendants = true,
Visible = Loading.ShowSidebar,
Parent = MainFrame,
})
local SidebarCorner = New("UICorner", { CornerRadius = UDim.new(0, Library.CornerRadius), Parent = SideBar })
table.insert(Library.Corners, SidebarCorner)
Library:AddOutline(SideBar)
local SidebarDivider = New("Frame", {
BackgroundColor3 = "OutlineColor",
BorderSizePixel = 0,
Position = UDim2.fromOffset(0, 0),
Size = UDim2.new(0, 1, 1, 0),
Visible = Loading.ShowSidebar,
Parent = SideBar,
})
local TopBar = New("Frame", {
Name = "TopBar",
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 0, 48),
ZIndex = 2,
Parent = Container,
})
Library:MakeDraggable(MainFrame, TopBar, true, true)
local TitleHolder = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.new(1, 0, 1, 0),
Parent = TopBar,
})
New("UIListLayout", {
FillDirection = Enum.FillDirection.Horizontal,
HorizontalAlignment = Enum.HorizontalAlignment.Left,
VerticalAlignment = Enum.VerticalAlignment.Center,
Padding = UDim.new(0, 6),
Parent = TitleHolder,
})
New("UIPadding", {
PaddingLeft = UDim.new(0, 12),
Parent = TitleHolder,
})
if LoadingInfo.Icon then
local Icon = Library:GetCustomIcon(LoadingInfo.Icon)
local _WindowIcon = New("ImageLabel", {
Size = LoadingInfo.IconSize,
Parent = TitleHolder,
})
if Icon then
Library:ApplyLucideIcon(_WindowIcon, Icon)
end
else
local _WindowIcon = New("TextLabel", {
BackgroundTransparency = 1,
Size = LoadingInfo.IconSize,
Text = LoadingInfo.Title:sub(1, 1),
TextScaled = true,
Visible = false,
Parent = TitleHolder,
})
end
local TitleX = Library:GetTextBounds(
LoadingInfo.Title,
Library.Scheme.Font,
20,
(TitleHolder.AbsoluteSize.X / Library.DPIScale) - (LoadingInfo.Icon and (LoadingInfo.IconSize.X.Offset + 6) or 0) - 12
)
local _WindowTitle = New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.new(0, TitleX, 1, 0),
Text = LoadingInfo.Title,
TextSize = 20,
Parent = TitleHolder,
})
Library:MakeLine(Container, {
Position = UDim2.fromOffset(0, 48),
Size = UDim2.new(1, 0, 0, 1),
})
local InnerContent = New("Frame", {
Name = "InnerContent",
BackgroundTransparency = 1,
Position = UDim2.fromOffset(0, 49),
Size = UDim2.new(1, 0, 1, -49),
Parent = Container,
})
New("UIListLayout", {
FillDirection = Enum.FillDirection.Vertical,
HorizontalAlignment = Enum.HorizontalAlignment.Center,
VerticalAlignment = Enum.VerticalAlignment.Center,
Padding = UDim.new(0, 12),
Parent = InnerContent,
})
local IconHolder = New("Frame", {
Name = "IconHolder",
BackgroundTransparency = 1,
Size = UDim2.fromOffset(64, 64),
Parent = InnerContent,
})
local LoaderIcon = Library:GetCustomIcon(LoadingInfo.LoadingIcon)
local LoadingIcon = New("ImageLabel", {
Name = "LoaderIcon",
AnchorPoint = Vector2.new(0.5, 0.5),
BackgroundTransparency = 1,
Position = UDim2.fromScale(0.5, 0.5),
Size = UDim2.fromScale(1, 1),
ImageColor3 = LoadingInfo.LoadingIconColor or ((LoadingInfo.LoadingIcon == Templates.Loading.LoadingIcon) and "AccentColor" or "WhiteColor"),
Parent = IconHolder,
})
if LoaderIcon then
Library:ApplyLucideIcon(LoadingIcon, LoaderIcon)
end
local RotationTween
if LoadingInfo.LoadingIconTweenTime > 0 then
RotationTween = TweenService:Create(
LoadingIcon,
TweenInfo.new(LoadingInfo.LoadingIconTweenTime, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1),
{ Rotation = 360 }
)
RotationTween:Play()
end
local MessageLabel = New("TextLabel", {
BackgroundTransparency = 1,
AutomaticSize = Loading.AutoResizeHeight and Enum.AutomaticSize.Y or Enum.AutomaticSize.XY,
Size = Loading.AutoResizeHeight and UDim2.new(1, -60, 0, 0) or UDim2.fromOffset(0, 0),
Text = "",
TextSize = 18,
TextWrapped = Loading.AutoResizeHeight,
Parent = InnerContent,
})
local DescriptionLabel = New("TextLabel", {
BackgroundTransparency = 1,
AutomaticSize = Loading.AutoResizeHeight and Enum.AutomaticSize.Y or Enum.AutomaticSize.XY,
Size = Loading.AutoResizeHeight and UDim2.new(1, -60, 0, 0) or UDim2.fromOffset(0, 0),
Text = "",
TextSize = 14,
TextTransparency = 0.5,
TextWrapped = Loading.AutoResizeHeight,
Parent = InnerContent,
})
local SliderBar = New("Frame", {
BackgroundColor3 = "MainColor",
Size = UDim2.new(0.7, 0, 0, 15),
Parent = InnerContent,
})
Library:AddOutline(SliderBar)
table.insert(Library.Corners, New("UICorner", { CornerRadius = UDim.new(0, Library.CornerRadius / 2), Parent = SliderBar }))
local SliderFill = New("Frame", {
BackgroundColor3 = "AccentColor",
BorderSizePixel = 0,
Size = UDim2.fromScale(0, 1),
Parent = SliderBar,
})
table.insert(Library.Corners, New("UICorner", { CornerRadius = UDim.new(0, Library.CornerRadius / 2), Parent = SliderFill }))
local ProgressLabel = New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 1),
Text = "",
TextSize = 14,
ZIndex = 2,
Parent = SliderBar,
})
New("UIStroke", {
ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
Color = "DarkColor",
LineJoinMode = Enum.LineJoinMode.Miter,
Parent = ProgressLabel,
})
local SidebarScrolling = New("ScrollingFrame", {
BackgroundTransparency = 1,
BorderSizePixel = 0,
CanvasSize = UDim2.new(0, 0, 0, 0),
Size = UDim2.fromScale(1, 1),
ScrollBarThickness = 2,
ScrollBarImageColor3 = "OutlineColor",
Parent = SideBar,
})
local SidebarList = New("UIListLayout", {
Padding = UDim.new(0, 8),
SortOrder = Enum.SortOrder.LayoutOrder,
Parent = SidebarScrolling,
})
New("UIPadding", {
PaddingBottom = UDim.new(0, 12),
PaddingLeft = UDim.new(0, 12),
PaddingRight = UDim.new(0, 12),
PaddingTop = UDim.new(0, 12),
Parent = SidebarScrolling,
})
local SidebarObject = {
Elements = {},
DependencyBoxes = {},
Tabboxes = {},
BoxHolder = SidebarScrolling,
Container = SidebarScrolling,
Resize = function(self)
SidebarScrolling.CanvasSize = UDim2.fromOffset(0, SidebarList.AbsoluteContentSize.Y + 24)
end,
Tab = {
Elements = {},
DependencyBoxes = {},
DependencyGroupboxes = {},
Tabboxes = {},
},
}
SidebarList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
SidebarObject:Resize()
end)
setmetatable(SidebarObject, BaseGroupbox)
Loading.Sidebar = SidebarObject
local ErrorFrame = New("Frame", {
Name = "Error",
BackgroundTransparency = 1,
Position = UDim2.fromOffset(0, 49),
Size = UDim2.new(1, 0, 1, -49),
ClipsDescendants = true,
Visible = false,
Parent = Container,
})
local _ErrorTitle = New("TextLabel", {
BackgroundTransparency = 1,
Position = UDim2.fromOffset(15, 15),
Size = UDim2.new(1, -30, 0, 18),
Text = "Error",
TextColor3 = "RedColor",
TextSize = 18,
TextXAlignment = Enum.TextXAlignment.Left,
Parent = ErrorFrame,
})
local ErrorLabel = New("TextLabel", {
BackgroundTransparency = 1,
Position = UDim2.fromOffset(15, 39),
Size = UDim2.new(1, -30, 1, -90),
Text = "Error Message",
TextSize = 14,
TextTransparency = 0.2,
TextWrapped = true,
TextXAlignment = Enum.TextXAlignment.Left,
TextYAlignment = Enum.TextYAlignment.Top,
Parent = ErrorFrame,
})
local ErrorButtonsDivider = New("Frame", {
BackgroundColor3 = "OutlineColor",
BackgroundTransparency = 0,
BorderSizePixel = 0,
AnchorPoint = Vector2.new(0.5, 0),
Position = UDim2.new(0.5, 0, 1, -48),
Size = UDim2.new(1, -30, 0, 1),
Visible = false,
Parent = ErrorFrame,
})
local ErrorButtonsHolder = New("Frame", {
AnchorPoint = Vector2.new(0.5, 1),
BackgroundTransparency = 1,
Position = UDim2.new(0.5, 0, 1, 0),
Size = UDim2.new(1, 0, 0, 42),
Visible = false,
Parent = ErrorFrame,
})
New("UIListLayout", {
Padding = UDim.new(0, 8),
FillDirection = Enum.FillDirection.Horizontal,
HorizontalAlignment = Enum.HorizontalAlignment.Right,
VerticalAlignment = Enum.VerticalAlignment.Center,
SortOrder = Enum.SortOrder.LayoutOrder,
Parent = ErrorButtonsHolder,
})
New("UIPadding", {
PaddingTop = UDim.new(0, 5),
PaddingBottom = UDim.new(0, 15),
PaddingRight = UDim.new(0, 15),
Parent = ErrorButtonsHolder,
})
function Loading:UpdateLayout()
if Loading.IsError then
Loading:RecalculateErrorHeight()
end
local ShowSidebar = Loading.ShowSidebar
local FinalWidth = ShowSidebar and (Loading.ContentWidth + Loading.SidebarWidth) or Loading.WindowWidth
local FinalHeight = Loading.IsError and Loading.WindowErrorHeight or Loading.WindowHeight
if ShowSidebar then
SideBar.Visible = true
SidebarDivider.Visible = true
end
TweenService:Create(MainFrame, Library.TweenInfo, { Size = UDim2.fromOffset(FinalWidth, FinalHeight) }):Play()
TweenService:Create(SideBar, Library.TweenInfo, { Position = UDim2.fromOffset(Loading.ContentWidth, 0), Size = UDim2.new(0, ShowSidebar and Loading.SidebarWidth or 0, 1, 0) }):Play()
TweenService:Create(Container, Library.TweenInfo, { Size = UDim2.new(0, ShowSidebar and Loading.ContentWidth or Loading.WindowWidth, 1, 0) }):Play()
if not ShowSidebar then
task.delay(Library.TweenInfo.Time, function()
if not Loading.ShowSidebar then
SideBar.Visible = false
SidebarDivider.Visible = false
end
end)
end
end
function Loading:RecalculateLoadingHeight()
if not Loading.AutoResizeHeight then
return
end
local RequiredHeight =
49 -- TopBar
+ 48 -- Padding
+ InnerContent.UIListLayout.AbsoluteContentSize.Y
Loading.WindowHeight = math.max(Loading.BaseWindowHeight, RequiredHeight)
end
function Loading:SetMessage(Text)
MessageLabel.Text = Text
if Loading.AutoResizeHeight then
Loading:RecalculateLoadingHeight()
Loading:UpdateLayout()
end
end
function Loading:SetDescription(Text)
DescriptionLabel.Text = Text
if Loading.AutoResizeHeight then
Loading:RecalculateLoadingHeight()
Loading:UpdateLayout()
end
end
function Loading:SetLoadingIcon(Icon)
local IconData = Library:GetCustomIcon(Icon)
assert(IconData, "Image must be a valid Roblox asset or a valid URL or a valid lucide icon.")
Library:ApplyLucideIcon(LoadingIcon, IconData)
end
function Loading:SetLoadingIconTweenTime(TweenTime)
if RotationTween then
StopTween(RotationTween, true)
RotationTween = nil
end
if TweenTime > 0 then
RotationTween = TweenService:Create(
LoadingIcon,
TweenInfo.new(TweenTime, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1),
{ Rotation = 360 }
)
RotationTween:Play()
else
LoadingIcon.Rotation = 0
end
end
function Loading:SetLoadingIconColor(Color)
LoadingIcon.ImageColor3 = Color
end
function Loading:SetCurrentStep(Step)
Loading.CurrentStep = math.clamp(Step, 0, Loading.TotalSteps)
local Progress = Loading.CurrentStep / Loading.TotalSteps
TweenService:Create(SliderFill, Library.TweenInfo, { Size = UDim2.fromScale(Progress, 1) }):Play()
ProgressLabel.Text = string.format("%d/%d", Loading.CurrentStep, Loading.TotalSteps)
end
function Loading:SetTotalSteps(Steps)
Loading.TotalSteps = Steps
Loading:SetCurrentStep(Loading.CurrentStep)
end
function Loading:SetWindowHeight(Height)
Loading.WindowHeight = Height
Loading:UpdateLayout()
end
function Loading:SetWindowWidth(Width)
Loading.WindowWidth = Width
Loading:UpdateLayout()
end
function Loading:SetContentWidth(Width)
Loading.ContentWidth = Width
Loading:UpdateLayout()
end
function Loading:SetSidebarWidth(Width)
Loading.SidebarWidth = Width
Loading:UpdateLayout()
end
function Loading:ShowSidebarPage(Bool)
Loading.ShowSidebar = Bool
Loading:UpdateLayout()
end
function Loading:ShowErrorPage(Enabled)
Loading.IsError = Enabled
InnerContent.Visible = not Enabled
ErrorFrame.Visible = Enabled
if Loading.ShowSidebar then
Loading:ShowSidebarPage(not Enabled)
else
Loading:UpdateLayout()
end
end
function Loading:RecalculateErrorHeight()
local TargetWidth = (Loading.ShowSidebar and Loading.ContentWidth or Loading.WindowWidth) - 30
local _, ErrorY = Library:GetTextBounds(ErrorLabel.Text, Library.Scheme.Font, 14, TargetWidth)
ErrorLabel.Size = UDim2.new(1, -30, 0, ErrorY)
local HasButtons = ErrorButtonsHolder.Visible
local RequiredHeight =
49                        -- TopBar
+ 15                        -- Padding Top
+ 18                        -- Title Height
+ 6                         -- Padding between Title and Label
+ ErrorY                    -- Label Height
+ 15                        -- Padding between Label and Buttons
+ (HasButtons and 48 or 0)  -- Buttons Area
Loading.WindowErrorHeight = RequiredHeight -- math.max(Loading.WindowHeight, RequiredHeight)
end
function Loading:SetErrorMessage(Text)
ErrorLabel.Text = Text
Loading:UpdateLayout()
end
function Loading:SetErrorButtons(Buttons)
assert(typeof(Buttons) == "table", "Buttons must be a table")
for _, button in ErrorButtonsHolder:GetChildren() do
if button:IsA("Frame") then
button:Destroy()
end
end
local HasButtons = GetTableSize(Buttons) > 0
ErrorButtonsHolder.Visible = HasButtons
ErrorButtonsDivider.Visible = HasButtons
for Idx, ButtonInfo in Buttons do
local ButtonContainer = New("Frame", {
BackgroundTransparency = 1,
Size = UDim2.fromOffset(0, 26),
Parent = ErrorButtonsHolder,
})
local BtnColor = "MainColor"
local BtnOutline = "OutlineColor"
local Variant = ButtonInfo.Variant or "Primary"
if Variant == "Primary" then
BtnColor = "FontColor"
BtnOutline = "FontColor"
elseif Variant == "Secondary" then
BtnColor = "MainColor"
BtnOutline = "OutlineColor"
elseif Variant == "Destructive" then
BtnColor = "DestructiveColor"
BtnOutline = "DestructiveColor"
elseif Variant == "Ghost" then
BtnColor = "BackgroundColor"
BtnOutline = "BackgroundColor"
end
local TextBtn = New("TextButton", {
BackgroundColor3 = BtnColor,
BorderColor3 = BtnOutline,
Size = UDim2.fromOffset(0, 26),
Text = "",
AutoButtonColor = false,
Parent = ButtonContainer,
})
Library:AddOutline(TextBtn)
table.insert(
Library.Corners,
New("UICorner", {
CornerRadius = UDim.new(0, Library.CornerRadius),
Parent = TextBtn
})
)
New("UIPadding", {
PaddingLeft = UDim.new(0, 15),
PaddingRight = UDim.new(0, 15),
Parent = TextBtn,
})
local TextColor = Library.Scheme.FontColor
if Variant == "Primary" then
TextColor = Library.Scheme.BackgroundColor
elseif Variant == "Destructive" then
TextColor = Color3.new(1, 1, 1)
end
local BtnLabel = New("TextLabel", {
BackgroundTransparency = 1,
Size = UDim2.fromScale(1, 1),
Text = ButtonInfo.Title or Idx,
TextColor3 = TextColor,
TextSize = 14,
Parent = TextBtn,
})
local LabelX, _ = Library:GetTextBounds(BtnLabel.Text, Library.Scheme.Font, 14, 250)
ButtonContainer.Size = UDim2.fromOffset(LabelX + 30, 26)
TextBtn.Size = UDim2.fromOffset(LabelX + 30, 26)
local ActiveColor = typeof(BtnColor) == "Color3" and BtnColor or Library.Scheme[BtnColor]
local HoverColor = Variant == "Ghost" and Library.Scheme.MainColor or Library:GetBetterColor(ActiveColor, 10)
TextBtn.MouseEnter:Connect(function()
TweenService:Create(TextBtn, Library.TweenInfo, {
BackgroundColor3 = HoverColor
}):Play()
end)
TextBtn.MouseLeave:Connect(function()
TweenService:Create(TextBtn, Library.TweenInfo, {
BackgroundColor3 = ActiveColor
}):Play()
end)
TextBtn.MouseButton1Click:Connect(function()
if ButtonInfo.Callback then
ButtonInfo.Callback(Loading)
Elevate()
end
end)
end
Loading:UpdateLayout()
end
function Loading:Destroy()
if RotationTween then
StopTween(RotationTween, true)
RotationTween = nil
end
ScreenGui:Destroy()
Loading.Destroyed = true
Library.ActiveLoading = nil
if Library.Toggle and Library.Toggled == false and Library.Unloaded ~= true then
Library:Toggle(true)
end
end
Loading.Continue = Loading.Destroy;
if Library.Toggle and Library.Toggled and Library.Unloaded ~= true then
Library:Toggle(false)
end
Loading:SetCurrentStep(Loading.CurrentStep)
Library.ActiveLoading = Loading
return Loading
end
local function OnPlayerChange()
if Library.Unloaded then
return
end
local PlayerList, ExcludedPlayerList = GetPlayers(), GetPlayers(true)
for _, Dropdown in Options do
if Dropdown.Type == "Dropdown" and Dropdown.SpecialType == "Player" then
Dropdown:SetValues(Dropdown.ExcludeLocalPlayer and ExcludedPlayerList or PlayerList)
end
end
end
local function OnTeamChange()
if Library.Unloaded then
return
end
local TeamList = GetTeams()
for _, Dropdown in Options do
if Dropdown.Type == "Dropdown" and Dropdown.SpecialType == "Team" then
Dropdown:SetValues(TeamList)
end
end
end
Library:GiveSignal(Players.PlayerAdded:Connect(OnPlayerChange))
Library:GiveSignal(Players.PlayerRemoving:Connect(OnPlayerChange))
Library:GiveSignal(Teams.ChildAdded:Connect(OnTeamChange))
Library:GiveSignal(Teams.ChildRemoved:Connect(OnTeamChange))
function Library:Unload()
if Library.Unloaded then return end
Library.Unloaded = true
for Index = #Library.Signals, 1, -1 do
local Connection = table.remove(Library.Signals, Index)
if Connection and Connection.Connected then
Connection:Disconnect()
end
end
for _ = 1, #Library.UnloadSignals do
local Callback = table.remove(Library.UnloadSignals, 1)
if Callback then
Library:SafeCallback(Callback)
end
end
for Index = #Library.Tabs, 1, -1 do
local Tab = table.remove(Library.Tabs, Index)
if Tab and Tab.Destroy then
Library:SafeCallback(Tab.Destroy, Tab)
end
end
for Index = #Tooltips, 1, -1 do
local Tooltip = table.remove(Tooltips, Index)
if Tooltip and Tooltip.Destroy then
Library:SafeCallback(Tooltip.Destroy, Tooltip)
end
end
if Library.ActiveLoading then
Library.ActiveLoading:Destroy()
end
if ScreenGui then
ScreenGui:Destroy()
end
table.clear(Library.Registry)
table.clear(Options)
table.clear(Toggles)
table.clear(Buttons)
table.clear(Labels)
table.clear(Tooltips)
table.clear(Library.Tabs)
table.clear(Library.TabButtons)
table.clear(Library.Scales)
table.clear(Library.ScalesOffset)
table.clear(Library.Corners)
table.clear(Library.SpecificCorners)
table.clear(Library.ContextMenus)
table.clear(Library.Notifications)
table.clear(Library.Dialogues)
table.clear(Library.DraggableElements)
table.clear(Library.KeybindToggles)
table.clear(Library.DependencyBoxes)
table.clear(TransparencyCache)
table.clear(ActiveTabTweens)
Library.Toggle = function(...) end
Library.ScreenGui = nil
Library.Floats = nil
Library.Overlay = nil
Library.WindowContainer = nil
Library.KeybindFrame = nil
Library.KeybindContainer = nil
if getgenv().Library == Library then getgenv().Library = nil end
end
do
local GuardedFunctions = setmetatable({}, { __mode = "k" })
local GuardedObjects = setmetatable({}, { __mode = "k" })
local Skip = {
Validate = true,
SafeCallback = true,
GiveSignal = true,
AddToRegistry = true,
RemoveFromRegistry = true,
Callback = true,
Changed = true,
}
local GuardObject
local function GuardFunction(Function)
if GuardedFunctions[Function] then
return Function
end
local function Guarded(...)
Elevate()
local Results = table.pack(Function(...))
for Index = 1, Results.n do
if type(Results[Index]) == "table" then
GuardObject(Results[Index])
end
end
return table.unpack(Results, 1, Results.n)
end
GuardedFunctions[Guarded] = true
return Guarded
end
function GuardObject(Object, Rescan: boolean?)
if GuardedObjects[Object] and not Rescan then
return Object
end
GuardedObjects[Object] = true
for Key, Value in Object do
if type(Key) == "string" and type(Value) == "function" and not Skip[Key]
and not string.match(Key, "^Get") and not string.match(Key, "^Is") then
Object[Key] = GuardFunction(Value)
end
end
return Object
end
GuardObject(BaseGroupbox.__index)
GuardObject(BaseAddons.__index)
GuardObject(Library)
for _, Name in { "CreateWindow", "CreateLoading" } do
local Create = Library[Name]
if Create then
local function Rescanning(...)
local Results = table.pack(Create(...))
GuardObject(Library, true)
return table.unpack(Results, 1, Results.n)
end
GuardedFunctions[Rescanning] = true
Library[Name] = Rescanning
end
end
end
getgenv().Library = Library
return Library
end
return use("main")
