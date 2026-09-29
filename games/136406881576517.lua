-- Slopix Hub (Slayers 2), built 2026-09-29 18:08 UTC by build.py. Edit the files in src/, not this one.
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
    local ok, result = xpcall(loader, debug.traceback, use)
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
__modules["core/accessories"] = function(use) -- src/games/slayers2/core/accessories.luau
-- Accessories: which pieces to wear in the five stat slots, and putting them on.
--
-- The Accessories page of the inventory menu holds Accessory, Costume and Clothing items (it shows
-- the same Equip Stats / Equip Vanity buttons for all three), and any of them with a Stats table
-- adds it while it sits in a stat slot: { ["Max Health"] = 70, ["Additional Damage Factor"] = 0.05,
-- ["Sun Immunity"] = true }. The slots are slot.Inventory.Accessories.Stats.One .. Five, each
-- holding the Id of the inventory entry worn there (0 = empty). The menu's Equip button sends
-- SignalEvent "AccessoryEquip"(slot name, entry Id, "Stats"): a slot that holds something is
-- replaced, and Id 0 empties it.
--
-- Worn stats add up (PlayerStatResolver's Accessory solver), except the HighestOnlyStats
-- (Illumination), where the best piece counts, and the true/false ones (Sun Immunity), which a
-- second piece adds nothing to. A Series piece (or a Refinable one) is scaled by its entry's Tier
-- (Series.Multiplier) and RefineLevel (Refinement.GetStatMultiplier), so two copies of one piece
-- can differ. A piece with an ExclusiveGroup (the two cold-weather lanterns) is meant to be worn
-- without another piece of its group; no client script reads the key, so the server presumably
-- enforces it, and the best set takes one piece per group.
--
-- "Best" needs one unit: 70 health and 5% damage cannot be added up. Each stat is counted as a
-- share of the most any obtainable piece gives of it (Accessories.scales), so a piece with a
-- quarter of the best health and half of the best damage is worth 0.75 to someone who picks both.

local Env = use("core/env")
local Life = use("shared/life")
local Data = use("core/data")

local Accessories = {}

Accessories.SLOTS = { "One", "Two", "Three", "Four", "Five" }

-- Menum.ItemEquipType names the Accessories page takes.
local WEARABLE = { "Accessory", "Costume", "Clothing" }
local EQUIP_WAIT = 2
-- A change per slot, plus room for pieces the game refuses and the next best ones tried instead.
local MAX_CHANGES = 12
local EPSILON = 1e-9

-- { [item name] = definition } for every wearable item that carries stats.
local function wearables()
    local kinds = {}
    for _, kind in ipairs(WEARABLE) do
        local value = Env.Game.Menum.ItemEquipType[kind]
        if value ~= nil then
            kinds[value] = true
        end
    end
    local found = {}
    for name, definition in pairs(Env.Game.Items) do
        if type(definition) == "table" and kinds[definition.EquipType] and type(definition.Stats) == "table" then
            found[name] = definition
        end
    end
    return found
end

-- The stats some piece carries, in the game's own stat order (StatTypes.StatKeys), for the picker.
function Accessories.statNames()
    local present = {}
    for _, definition in pairs(wearables()) do
        for stat, value in pairs(definition.Stats) do
            if value == true or type(value) == "number" then
                present[stat] = true
            end
        end
    end
    local names = {}
    for _, stat in ipairs(Env.Game.StatTypes.StatKeys or {}) do
        if present[stat] then
            names[#names + 1] = stat
            present[stat] = nil
        end
    end
    local others = {}
    for stat in pairs(present) do
        others[#others + 1] = stat
    end
    table.sort(others)
    for _, stat in ipairs(others) do
        names[#names + 1] = stat
    end
    return names
end

-- { [stat] = the most any obtainable piece gives of it }: the unit each stat is counted in. True
-- and false stats count 1. Unobtainable pieces (the developers' own) would only stretch it.
function Accessories.scales()
    local scales = {}
    for _, definition in pairs(wearables()) do
        if definition.Unobtainable ~= true then
            for stat, value in pairs(definition.Stats) do
                if value == true then
                    scales[stat] = 1
                elseif type(value) == "number" and value > (scales[stat] or 0) then
                    scales[stat] = value
                end
            end
        end
    end
    return scales
end

-- What one inventory entry adds when worn: its definition's stats, scaled by the entry's tier and
-- refinement where the game does.
local function effectiveStats(name, definition, entry)
    local scaled = definition.Series ~= nil or definition.Refinable == true
    local tier, level = 1, nil
    if scaled then
        local ok, multiplier = Env.call(Env.Game.Series.Multiplier, entry)
        if ok and type(multiplier) == "number" then
            tier = multiplier
        end
        local refine = entry:FindFirstChild("RefineLevel")
        level = refine and refine.Value
    end
    local stats = {}
    for stat, value in pairs(definition.Stats) do
        if scaled and type(value) == "number" then
            value *= tier
            if level then
                local ok, refined = Env.call(Env.Game.Refinement.GetStatMultiplier, name, stat, level)
                if ok and type(refined) == "number" then
                    value *= refined
                end
            end
        end
        stats[stat] = value
    end
    return stats
end

-- Every wearable entry in the inventory: { name, id, stats, group }. Two copies of one item are
-- two pieces.
function Accessories.owned()
    local inventory = Data.inventory()
    local definitions = wearables()
    local pool = {}
    for _, entry in ipairs(inventory and inventory:GetChildren() or {}) do
        local definition = definitions[entry.Name]
        local id = definition and entry:FindFirstChild("Id")
        if id and id.Value ~= 0 then
            pool[#pool + 1] = {
                name = entry.Name,
                id = id.Value,
                stats = effectiveStats(entry.Name, definition, entry),
                group = definition.ExclusiveGroup,
            }
        end
    end
    Env.elevate()
    return pool
end

-- What `piece` adds to a set whose stats so far are `totals`, counting only the stats in `wanted`,
-- each as a share of its scale.
local function gain(piece, totals, wanted, scales, highest)
    local sum = 0
    for stat in pairs(wanted) do
        local value, scale = piece.stats[stat], scales[stat]
        if scale and scale > 0 then
            if value == true then
                if not totals[stat] then
                    sum += 1
                end
            elseif type(value) == "number" then
                if highest[stat] then
                    sum += (math.max(value, totals[stat] or 0) - (totals[stat] or 0)) / scale
                else
                    sum += value / scale
                end
            end
        end
    end
    return sum
end

-- Whether `a` (adding gainA) beats `b`. A tie keeps what is already worn, so a second press finds
-- nothing to change, and is otherwise settled by name and Id, so the same pool gives the same set.
local function better(a, gainA, b, gainB)
    if math.abs(gainA - gainB) > EPSILON then
        return gainA > gainB
    end
    if (a.worn == true) ~= (b.worn == true) then
        return a.worn == true
    end
    if a.name ~= b.name then
        return a.name < b.name
    end
    return a.id < b.id
end

-- The best set of up to `count` pieces from `pool` for the stats in `wanted` ({ [stat] = true }).
-- Each pick is the piece that adds the most to the ones already picked, so a second Sun Immunity
-- piece adds nothing and a second Illumination piece only what it has over the first (`highest`
-- is StatTypes.HighestOnlyStats). Pieces that add nothing are left out, so the set can be shorter
-- than `count`. A piece of a group already picked from is skipped. A piece marked worn wins ties.
function Accessories.choose(pool, wanted, scales, highest, count)
    local chosen, taken, groups, totals = {}, {}, {}, {}
    for _ = 1, count do
        local best, bestGain
        for _, piece in ipairs(pool) do
            if not taken[piece] and not (piece.group and groups[piece.group]) then
                local value = gain(piece, totals, wanted, scales, highest)
                if value > EPSILON and (not best or better(piece, value, best, bestGain)) then
                    best, bestGain = piece, value
                end
            end
        end
        if not best then
            break
        end
        chosen[#chosen + 1] = best
        taken[best] = true
        if best.group then
            groups[best.group] = true
        end
        for stat, value in pairs(best.stats) do
            if value == true then
                totals[stat] = true
            elseif type(value) == "number" then
                if highest[stat] then
                    totals[stat] = math.max(totals[stat] or 0, value)
                else
                    totals[stat] = (totals[stat] or 0) + value
                end
            end
        end
    end
    return chosen
end

-- The equips that turn the slots (`slotIds`: { [slot] = worn Id, 0 when empty }) into `chosen`, in
-- the order to send them: { { slot, piece }, ... }. A chosen piece already in a slot stays where it
-- is; the rest go into empty slots first, then over pieces that are not chosen.
function Accessories.plan(chosen, slotIds)
    local wanted = {}
    for _, piece in ipairs(chosen) do
        wanted[piece.id] = true
    end
    local placed, empty, replaceable = {}, {}, {}
    for _, slot in ipairs(Accessories.SLOTS) do
        local id = slotIds[slot]
        if id ~= nil then
            if wanted[id] then
                placed[id] = true
            elseif id == 0 then
                empty[#empty + 1] = slot
            else
                replaceable[#replaceable + 1] = slot
            end
        end
    end
    local moves = {}
    for _, piece in ipairs(chosen) do
        if not placed[piece.id] then
            local slot = table.remove(empty, 1) or table.remove(replaceable, 1)
            if not slot then
                break
            end
            moves[#moves + 1] = { slot = slot, piece = piece }
        end
    end
    return moves
end

-- The folder of stat slots (slot.Inventory.Accessories.Stats), or nil until the save has loaded.
function Accessories.slots()
    local slot = Data.slot()
    local inventory = slot and slot:FindFirstChild("Inventory")
    local accessories = inventory and inventory:FindFirstChild("Accessories")
    return accessories and accessories:FindFirstChild("Stats")
end

local function slotIds(folder)
    local ids = {}
    for _, slot in ipairs(Accessories.SLOTS) do
        local entry = folder:FindFirstChild(slot)
        if entry then
            ids[slot] = type(entry.Value) == "number" and entry.Value or 0
        end
    end
    return ids
end

-- Sends one equip the way the inventory menu does, then waits for the slot to hold the piece. A
-- remote that cannot be called is an error, not the game's refusal.
local function equip(folder, slot, id)
    local sent, err = Env.call(Env.Game.SignalEvent.ToServer, "AccessoryEquip", slot, id, "Stats")
    if not sent then
        error("AccessoryEquip could not be sent: " .. tostring(err), 0)
    end
    local entry = folder:FindFirstChild(slot)
    local deadline = os.clock() + EQUIP_WAIT
    while entry.Value ~= id and os.clock() < deadline do
        if not Life.wait(0.1) then
            break
        end
    end
    Env.elevate()
    return entry.Value == id
end

-- Wears the best pieces for `wanted` ({ [stat] = true }) in the stat slots and leaves the vanity
-- slots alone. One slot at a time: the best set is worked out again after each equip, so a piece
-- the game refuses (the server has rules the client never checks) is dropped and the next best
-- one goes in its place. Returns { set, equipped, refused, incomplete, aborted, error }: `set`
-- is the best set now (what is worn once nothing is `incomplete` or `aborted`), `equipped` the
-- pieces put on and `refused` the ones the game turned down.
function Accessories.equipBest(wanted)
    local folder = Accessories.slots()
    if not folder then
        return { set = {}, equipped = {}, refused = {}, error = "Your accessory slots have not loaded yet." }
    end
    local scales = Accessories.scales()
    local highest = Env.Game.StatTypes.HighestOnlyStats or {}
    local pool = Accessories.owned()
    local result = { set = {}, equipped = {}, refused = {} }
    local refused = {}
    for _ = 1, MAX_CHANGES do
        local ids = slotIds(folder)
        local worn = {}
        for _, id in pairs(ids) do
            worn[id] = true
        end
        local usable = {}
        for _, piece in ipairs(pool) do
            -- A piece the game refused is dropped, unless it is on: a slow server took it after all.
            if worn[piece.id] or not refused[piece.id] then
                piece.worn = worn[piece.id] == true
                usable[#usable + 1] = piece
            end
        end
        result.set = Accessories.choose(usable, wanted, scales, highest, #Accessories.SLOTS)
        local move = Accessories.plan(result.set, ids)[1]
        if not move then
            return result
        end
        local taken = equip(folder, move.slot, move.piece.id)
        if not Life.alive then
            result.aborted = true
            return result
        end
        if taken then
            result.equipped[#result.equipped + 1] = move.piece
        else
            refused[move.piece.id] = true
            result.refused[#result.refused + 1] = move.piece
        end
    end
    result.incomplete = true
    return result
end

return Accessories
end
__modules["core/combat"] = function(use) -- src/games/slayers2/core/combat.luau
-- Finding mobs.
--
-- What the game does (measured live):
--  * Mobs are workspace.Humanoids.Regions.<Region>.ActiveNpcs.<Name>.<Name> (the inner model is
--    the live rig; a folder without it is despawned). Hostile rigs carry IsMob = true.

local Env = use("core/env")
local Data = use("core/data")

local Combat = {}

local RegionRoot = Env.need(Env.need(workspace, "Humanoids"), "Regions")

function Combat.alive(rig)
    if not rig or not rig.Parent then
        return false
    end
    local humanoid = rig:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.Health > 0 and rig:FindFirstChild("HumanoidRootPart") ~= nil
end

-- Every live rig, optionally only those in one region folder ("Temporary" holds event mobs).
function Combat.rigs(regionName)
    local list = {}
    for _, region in ipairs(RegionRoot:GetChildren()) do
        if regionName == nil or region.Name == regionName then
            local active = region:FindFirstChild("ActiveNpcs")
            for _, folder in ipairs(active and active:GetChildren() or {}) do
                local rig = folder:FindFirstChild(folder.Name)
                if Combat.alive(rig) then
                    list[#list + 1] = rig
                end
            end
        end
    end
    return list
end

-- The nearest live rig for which filter(rig) is true.
function Combat.find(filter)
    local root = Data.character()
    if not root then
        return nil
    end
    local best, bestDistance
    for _, rig in ipairs(Combat.rigs()) do
        if filter == nil or filter(rig) then
            local distance = (rig.HumanoidRootPart.Position - root.Position).Magnitude
            if not bestDistance or distance < bestDistance then
                best, bestDistance = rig, distance
            end
        end
    end
    return best
end

return Combat
end
__modules["core/data"] = function(use) -- src/games/slayers2/core/data.luau
-- The player's save slot, inventory, hotbar and character, read the way the game stores them.
--
-- Save data lives at Utility.GetData(player, true) -> slot. Level is not stored: it is
-- slot.Exp.Goal / gameSettings.expPerLevel. Items are folders under slot.Inventory.Inventory
-- (an Amount child when stackable), and the hotbar holds item Ids in slot.Inventory.Toolbar.

local Env = use("core/env")

local Data = {}

Data.TOOLBAR_SLOTS = { "One", "Two", "Three", "Four", "Five" }
local EQUIP_SETTLE = 0.5

function Data.slot()
    local ok, slot = Env.call(Env.Game.Utility.GetData, Env.LocalPlayer, true)
    return ok and slot or nil
end

function Data.inventory()
    local slot = Data.slot()
    local inventory = slot and slot:FindFirstChild("Inventory")
    return inventory and inventory:FindFirstChild("Inventory"), inventory and inventory:FindFirstChild("Toolbar")
end

function Data.itemCount(name)
    local owned = Data.inventory()
    local item = owned and owned:FindFirstChild(name)
    if not item then
        return 0
    end
    local amount = item:FindFirstChild("Amount")
    return amount and amount.Value or 1
end

-- { [itemName] = amount } for everything owned.
function Data.counts()
    local owned = Data.inventory()
    local counts = {}
    for _, item in ipairs(owned and owned:GetChildren() or {}) do
        local amount = item:FindFirstChild("Amount")
        counts[item.Name] = amount and amount.Value or 1
    end
    return counts
end

function Data.value(name)
    local slot = Data.slot()
    local holder = slot and slot:FindFirstChild(name)
    return holder and holder.Value
end

function Data.level()
    local slot = Data.slot()
    local goal = slot and slot:FindFirstChild("Exp") and slot.Exp:FindFirstChild("Goal")
    local perLevel = Env.Game.gameSettings.expPerLevel
    if not goal or not perLevel or perLevel == 0 then
        return 0
    end
    return math.floor(goal.Value / perLevel)
end

function Data.wen()
    return Data.value("Wen") or 0
end

-- Items on the hotbar that pass predicate(name, itemDefinition):
-- returns an ordered name list and { [name] = hotbarIndex }.
function Data.hotbar(predicate)
    local owned, toolbar = Data.inventory()
    if not owned or not toolbar then
        return {}, {}
    end
    local nameById = {}
    for _, item in ipairs(owned:GetChildren()) do
        local id = item:FindFirstChild("Id")
        if id then
            nameById[id.Value] = item.Name
        end
    end
    local names, indexByName = {}, {}
    for index, key in ipairs(Data.TOOLBAR_SLOTS) do
        local entry = toolbar:FindFirstChild(key)
        local name = entry and nameById[entry.Value]
        local definition = name and Env.Game.Items[name]
        if type(definition) == "table" and (predicate == nil or predicate(name, definition)) then
            names[#names + 1] = name
            indexByName[name] = index
        end
    end
    return names, indexByName
end

-- The hotbar index (1-5) holding `name`, or nil.
function Data.hotbarIndex(name)
    local owned, toolbar = Data.inventory()
    local item = owned and owned:FindFirstChild(name)
    local id = item and item:FindFirstChild("Id")
    if not id or not toolbar then
        return nil
    end
    for index, key in ipairs(Data.TOOLBAR_SLOTS) do
        local entry = toolbar:FindFirstChild(key)
        if entry and entry.Value == id.Value then
            return index
        end
    end
    return nil
end

local function emptySlot(toolbar)
    for _, key in ipairs(Data.TOOLBAR_SLOTS) do
        local entry = toolbar:FindFirstChild(key)
        if entry and (entry.Value == 0 or entry.Value == "") then
            return key
        end
    end
    return nil
end

-- Puts `name` on the hotbar the way the inventory menu does (SignalEvent "Toolbar_Equip"): into
-- slotKey when given, else the first empty slot, else (only with replaceLast) the last slot.
-- Returns the index, plus the slot key and the item id it replaced, so a caller can put it back.
function Data.putOnHotbar(name, slotKey, replaceLast)
    local index = Data.hotbarIndex(name)
    if index then
        return index
    end
    local owned, toolbar = Data.inventory()
    local item = owned and owned:FindFirstChild(name)
    local id = item and item:FindFirstChild("Id")
    if not id or not toolbar then
        return nil
    end
    slotKey = slotKey or emptySlot(toolbar) or (replaceLast and Data.TOOLBAR_SLOTS[#Data.TOOLBAR_SLOTS])
    if not slotKey then
        return nil
    end
    local entry = toolbar:FindFirstChild(slotKey)
    local previous = entry and entry.Value
    Env.Game.SignalEvent.ToServer("Toolbar_Equip", slotKey, id.Value)
    local deadline = os.clock() + 2
    while not Data.hotbarIndex(name) and os.clock() < deadline do
        task.wait(0.1)
    end
    Env.elevate()
    return Data.hotbarIndex(name), slotKey, previous
end

function Data.character()
    local char = Env.LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    return root, humanoid, char
end

function Data.equipped()
    local config = Env.LocalPlayer:FindFirstChild("Items_Config")
    return config and config:FindFirstChild("Equipped")
end

-- Equips a hotbar slot (1-5, 0 = nothing). The game reverts a direct slot-to-slot swap, so this
-- goes through 0 first and verifies the value held. Returns true once it is equipped.
function Data.equip(index, attempts)
    local equipped = Data.equipped()
    if not equipped then
        return false
    end
    for _ = 1, attempts or 1 do
        if equipped.Value == index then
            return true
        end
        if equipped.Value ~= 0 then
            equipped.Value = 0
            task.wait(EQUIP_SETTLE)
        end
        equipped.Value = index
        task.wait(EQUIP_SETTLE)
    end
    Env.elevate()
    return equipped.Value == index
end

return Data
end
__modules["core/env"] = function(use) -- src/games/slayers2/core/env.luau
-- Slayers 2: the game's own ModuleScripts and which of its places this server is.
-- Everything else (services, the executor, elevate) comes from shared/env.

local Env = use("shared/env")

Env.checkMissing({
    { "fireproximityprompt", fireproximityprompt },
    { "getconnections", getconnections },
    { "queue_on_teleport", Env.queueOnTeleport },
    { "writefile", writefile },
})

local RS = Env.ReplicatedStorage
local MODULES = {
    Utility = { "CAM", "Global", "Utility" },
    SignalEvent = { "Communication", "ServerAndClient", "Signals", "SignalEvent" },
    SignalFunction = { "Communication", "ServerAndClient", "Signals", "SignalFunction" },
    Clans = { "CAM", "Clans" },
    SpinBalance = { "CAM", "Global", "SpinBalance" },
    Items = { "CAM", "Global", "Collectibles", "Items" },
    Menum = { "CAM", "Global", "Menum" },
    Series = { "CAM", "Global", "Series" },
    Refinement = { "CAM", "Global", "Refinement" },
    StatTypes = { "CAM", "Global", "Types", "StatTypes" },
    Regions = { "Regions" },
    DayAndNightHandler = { "CAM", "Global", "DayAndNightHandler" },
    Multipliers = { "CAM", "Global", "Multipliers" },
    LiveConfig = { "CAM", "Global", "LiveConfig" },
    Quests ={ "CAM", "Global", "Subsets", "Gameplay", "Quests" },
    BossHunts = { "CAM", "Global", "Subsets", "Gameplay", "Quests", "BossHunts" },
    gameSettings = { "CAM", "Global", "gameSettings" },
    Shop = { "CAM", "Global", "Shop" },
    Rarities = { "CAM", "Global", "Rarities" },
    TimedVendor = { "CAM", "Global", "Subsets", "Gameplay", "TimedVendor" },
    RotatingShop = { "CAM", "Global", "Subsets", "Gameplay", "RotatingShop" },
    TimedEvents = { "CAM", "Global", "Subsets", "Gameplay", "TimedEvents" },
    Skill_Controller = { "CAM", "Client", "Controllers", "Skill_Controller" },
    Skills_Provider = { "CAM", "Client", "Controllers", "Skills_Provider" },
    Platform_Handler = { "CAM", "Client", "Controllers", "Platform_Handler" },
    PlayerProfile = { "CAM", "Global", "PlayerProfile" },
    Skill_Info = { "CAM", "Global", "PlayerProfile", "Skill_Info" },
    manage_cd = { "CAM", "Global", "Subsets", "Gameplay", "manage_cd" },
    SkillStats = { "CAM", "Global", "SkillService", "Stats" },
    Caps = { "CAM", "Global", "Caps" },
    MinigameSettings = { "CAM", "Global", "MinigameSettings" },
}

-- Env.Game.Quests, Env.Game.Items, ...: required on first use and cached.
local loadModule
Env.Game, loadModule = Env.modules(RS, MODULES)

-- Loads game modules from a plain call, where waiting on the game is allowed (see Env.modules);
-- Env.Game.<name> is then a cached field.
function Env.preload(...)
    for index = 1, select("#", ...) do
        loadModule((select(index, ...)))
    end
end

-- True once Env.Game.<name> is loaded (reading it then never has to wait).
function Env.loaded(name)
    return rawget(Env.Game, name) ~= nil
end

Env.MODULE_NAMES = {}
for name in pairs(MODULES) do
    Env.MODULE_NAMES[#Env.MODULE_NAMES + 1] = name
end
table.sort(Env.MODULE_NAMES)

-- On the Minigames place the workspace names the minigame this server runs ("Ouwigahara" for the
-- tower dungeon, "FinalSelection", "PvP"). Nil in the open world. A hub queued across a teleport
-- can start before the server sets it, and then took the tower for the open world and hung
-- waiting for BossHunts, so on that place it waits for the key (a freshly started private server
-- can take well over 20s to set it).
Env.MINIGAMES_PLACE = 75556147183481
if game.PlaceId == Env.MINIGAMES_PLACE then
    local deadline = os.clock() + 90
    while workspace:GetAttribute("MinigameKey") == nil and os.clock() < deadline do
        task.wait(0.25)
    end
    Env.elevate()
    Env.minigame = workspace:GetAttribute("MinigameKey") or "an unknown minigame"
else
    Env.minigame = workspace:GetAttribute("MinigameKey")
end
Env.inDungeon = Env.minigame == "Ouwigahara"

-- The main menu place (workspace attribute IsMenu) has your save slot, clan spins and codes, but no
-- world: no workspace.Humanoids.Regions (Combat would wait for it forever), NPCs, quests or shops.
Env.MENU_PLACE = 16205713724
Env.inMenu = game.PlaceId == Env.MENU_PLACE or workspace:GetAttribute("IsMenu") == true

return Env
end
__modules["core/npcdata"] = function(use) -- src/games/slayers2/core/npcdata.luau
-- What the game says a mob is worth.
--
-- LiveConfig "NpcDataTable" is synced from the server and holds, per NpcCode, the mob's Name, Icon
-- and Rewards ({ Exp, Wen, <item> = { Chance, Quantity } }); the game's own boss bar reads the
-- exp from there. A mob's NpcCode is on its folder in workspace.Humanoids.Regions.<Region>
-- .ActiveNpcs (or on the rig, or a folder inside that), so a rig is matched by code first and by
-- name after.

local Env = use("core/env")

local NpcData = {}

local EVERY = 30 -- the table is copied on every read, so it is read this often
local data, byName, readAt = nil, {}, -math.huge

local function table_()
    if os.clock() - readAt >= EVERY then
        readAt = os.clock()
        local ok, result = Env.call(Env.Game.LiveConfig.get, "NpcDataTable")
        if ok and type(result) == "table" then
            data, byName = result, {}
            for _, entry in pairs(result) do
                if type(entry) == "table" and type(entry.Name) == "string" and byName[entry.Name] == nil then
                    byName[entry.Name] = entry
                end
            end
        end
    end
    return data
end

-- The NpcDataTable entry for a rig, or nil (not synced yet, or the mob is not in it).
function NpcData.entryOf(rig)
    local all = table_()
    if not all then
        return nil
    end
    local folder = rig.Parent
    local code = rig:GetAttribute("NpcCode") or (folder and folder:GetAttribute("NpcCode"))
    if not code and folder then
        for _, child in ipairs(folder:GetChildren()) do
            code = child:GetAttribute("NpcCode")
            if code then
                break
            end
        end
    end
    return (code and all[code]) or all[rig.Name] or byName[rig.Name]
end

-- Exp for one kill, before your multiplier (0 when unknown).
function NpcData.exp(rig)
    local entry = NpcData.entryOf(rig)
    local rewards = entry and entry.Rewards
    return type(rewards) == "table" and tonumber(rewards.Exp) or 0
end

return NpcData
end
__modules["core/npcs"] = function(use) -- src/games/slayers2/core/npcs.luau
-- Finding NPCs: their definitions (what they sell) and their models in the world.
--
-- NPC models are made by the server under workspace.Debree.Regions.<Region>.StationaryNpcs.<Name>
-- and only exist on the client while streamed in. Each NPC is defined in a ModuleScript under
-- ReplicatedStorage.Ouwland.Content.<Region>.Npcs, with its Spawns and, for vendors, a Shop.

local Env = use("core/env")

local Npcs = {}

local definitions, sellers = nil, nil

local function load()
    if definitions then
        return
    end
    local content = Env.need(Env.need(Env.ReplicatedStorage, "Ouwland"), "Content")
    definitions, sellers = {}, {}
    for _, region in ipairs(content:GetChildren()) do
        local npcs = region:FindFirstChild("Npcs")
        for _, module in ipairs(npcs and npcs:GetDescendants() or {}) do
            if module:IsA("ModuleScript") then
                local ok, definition = pcall(require, module)
                if ok and type(definition) == "table" and type(definition.Name) == "string" then
                    definitions[definition.Name] = definition
                    if type(definition.Shop) == "table" then
                        for item in pairs(definition.Shop) do
                            sellers[item] = sellers[item] or definition.Name
                        end
                    end
                end
            end
        end
    end
    Env.elevate()
end

function Npcs.definition(name)
    load()
    return definitions[name]
end

-- Every NPC definition by name.
function Npcs.all()
    load()
    return definitions
end

-- Which NPC sells an item from their own Shop table (nil when none does).
function Npcs.sellerOf(item)
    load()
    return sellers[item]
end

function Npcs.model(name)
    local regions = workspace:FindFirstChild("Debree") and workspace.Debree:FindFirstChild("Regions")
    for _, region in ipairs(regions and regions:GetChildren() or {}) do
        local stationary = region:FindFirstChild("StationaryNpcs")
        local model = stationary and stationary:FindFirstChild(name)
        if model and model:IsA("Model") then
            return model
        end
    end
    return nil
end

function Npcs.prompt(model)
    return model and model:FindFirstChildWhichIsA("ProximityPrompt", true)
end

return Npcs
end
__modules["core/ready"] = function(use) -- src/games/slayers2/core/ready.luau
-- Waits until the game has loaded what the hub reads, before any feature is built.
--
-- Executed on join (auto-execute, a freshly started private server), the hub used to start while
-- the character, the save data and the world folders were still on their way. A feature built
-- then failed for the whole session: Env.need gave up after 30s, a feature read nil save data,
-- or a game module was first required inside Env.Game's __index while it waited for the game,
-- which Luau cannot do ("attempt to yield across metamethod/C-call boundary").
--
-- Ready.wait() checks what this place has (open world, dungeon or main menu) every 0.5s, says
-- in a notification what it is still waiting for, then requires the place's game modules here,
-- where waiting is allowed. After MAX_WAIT it loads anyway and names what never showed up.

local Env = use("core/env")

local Ready = {}

local MAX_WAIT = 180
local MODULE_WAIT = 45
local NOTE_EVERY = 15

-- Game modules each place's features read. The open world takes them all; the tower and the menu
-- only what their features use, since requiring a module also runs its setup (Regions, for one,
-- builds the shrines).
local DUNGEON_MODULES = { "Utility", "SignalEvent", "SignalFunction", "Items", "gameSettings", "Rarities", "Clans",
    "Caps", "MinigameSettings", "Skill_Controller", "Skills_Provider", "Platform_Handler", "PlayerProfile", "Skill_Info",
    "manage_cd", "SkillStats" }
local MENU_MODULES = { "Utility", "SignalEvent", "SignalFunction", "Clans", "SpinBalance", "gameSettings", "Items",
    "Rarities", "Shop", "Caps" }

local StarterGui = game:GetService("StarterGui")

local function notify(text, duration)
    pcall(StarterGui.SetCore, StarterGui, "SendNotification", {
        Title = "Slopix Hub",
        Text = text,
        Duration = duration or 5,
    })
    Env.elevate()
end

local function find(root, path)
    local node = root
    for part in string.gmatch(path, "[^%.]+") do
        node = node and node:FindFirstChild(part)
    end
    return node
end

local function characterReady()
    local char = Env.LocalPlayer.Character
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    return char ~= nil and char:FindFirstChild("HumanoidRootPart") ~= nil and humanoid ~= nil and humanoid.Health > 0
end

-- The save slot as the hub reads it (Data.slot), once Utility has loaded.
local function dataReady()
    if not Env.loaded("Utility") then
        return false
    end
    local ok, slot = Env.call(Env.Game.Utility.GetData, Env.LocalPlayer, true)
    return ok and slot ~= nil and find(slot, "Inventory.Inventory") ~= nil and find(slot, "Inventory.Toolbar") ~= nil
end

local function exists(root, path)
    return function()
        return find(root, path) ~= nil
    end
end

-- { label, check } for everything this place needs before the features are built.
local function checklist()
    local list = {
        { "the loading screen", function()
            return Env.LocalPlayer:GetAttribute("LoadingScreen") ~= true
        end },
        { "your save data", dataReady },
    }
    if Env.inMenu then
        return list
    end
    local RS = Env.ReplicatedStorage
    local more = {
        { "your character", characterReady },
        { "your hotbar", exists(Env.LocalPlayer, "Items_Config.Equipped") },
        { "your combat values", function()
            local values = find(RS, "Player_Service.Values")
            return values ~= nil and values:FindFirstChild(Env.LocalPlayer.Name) ~= nil
        end },
        { "the world (Debree)", exists(workspace, "Debree") },
        { "the mobs", exists(workspace, "Humanoids.Regions") },
        { "the game's remotes", exists(RS, "CAM.Global.ServerClientPortal.Event") },
    }
    if not Env.inDungeon then
        more[#more + 1] = { "the boss hunts", exists(RS, "BossHunts") }
        more[#more + 1] = { "the NPCs and quests", exists(RS, "Ouwland.Content") }
    end
    for _, entry in ipairs(more) do
        list[#list + 1] = entry
    end
    return list
end

-- Requires `names` side by side, each in its own thread (one that waits on the game holds up no
-- other), for up to `seconds`. Returns the ones that did not load.
local function preload(names, seconds)
    local pending = {}
    for _, name in ipairs(names) do
        if not Env.loaded(name) then
            pending[name] = true
            task.spawn(function()
                pcall(Env.preload, name)
                pending[name] = nil
            end)
        end
    end
    local deadline = os.clock() + seconds
    while next(pending) ~= nil and os.clock() < deadline do
        task.wait(0.1)
    end
    Env.elevate()
    local left = {}
    for name in pairs(pending) do
        left[#left + 1] = name
    end
    table.sort(left)
    return left
end

-- Blocks until the place is ready (or MAX_WAIT passed). Returns the labels that never became
-- ready and the game modules that did not load (both empty when all is well).
function Ready.wait()
    local started = os.clock()
    -- Save data is read through Utility: start loading it at once, alongside the checks.
    task.spawn(pcall, Env.preload, "Utility")
    local list = checklist()
    local nextNote = started + 3
    local waited = false
    local missing
    while true do
        missing = {}
        for _, entry in ipairs(list) do
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
            notify(string.format("Still no %s after %ds. Loading anyway: what needs it may not work.",
                table.concat(missing, ", "), MAX_WAIT), 10)
            break
        end
        if now >= nextNote then
            waited = true
            notify(string.format("Waiting for the game to load: %s (%ds)", table.concat(missing, ", "), math.floor(now - started)), 5)
            nextNote = now + NOTE_EVERY
        end
        task.wait(0.5)
    end

    local names = Env.inMenu and MENU_MODULES or Env.inDungeon and DUNGEON_MODULES or Env.MODULE_NAMES
    local slow = preload(names, MODULE_WAIT)
    if #slow > 0 then
        warn("[Slopix] game modules still loading: " .. table.concat(slow, ", "))
    end
    if waited then
        notify(string.format("Game loaded after %ds, starting the hub.", math.floor(os.clock() - started)), 4)
    end
    return missing, slow
end

return Ready
end
__modules["core/scheduler"] = function(use) -- src/games/slayers2/core/scheduler.luau
-- Decides what the hub is doing.
--
-- Each feature registers an activity:
--   { name, priority, wants() -> bool, start(), step() -> seconds?, stop() }
-- Every tick the scheduler runs step() of the highest-priority activity whose wants() is true.
-- Any number of toggles can be on at once: an activity only wants to run while it has work
-- (a potion is needed, fishing is on), and the rest wait their turn. Activities that swap the
-- equipped tool (a potion, a rod) must not run together, which is what this is for.
--
-- step() should return quickly (one potion, one cast) and hand back how long to wait, so a more
-- urgent activity never waits long to take over.

local Env = use("core/env")
local Life = use("shared/life")

local Scheduler = {
    current = nil,
    status = "Idle",
}

-- Shared priorities so features agree on the order.
Scheduler.PRIORITY = {
    heal = 90,
    fishing = 10,
}

local activities = {}

function Scheduler.register(activity)
    assert(activity.name and activity.priority and activity.wants and activity.step, "incomplete activity")
    activities[#activities + 1] = activity
    table.sort(activities, function(a, b)
        return a.priority > b.priority
    end)
    return activity
end

local function wants(activity)
    local ok, result = pcall(activity.wants)
    Env.elevate()
    if not ok then
        Life.errors["wants:" .. activity.name] = tostring(result)
    end
    return ok and result == true
end

local function pick()
    for _, activity in ipairs(activities) do
        if wants(activity) then
            return activity
        end
    end
    return nil
end

local function switch(nextActivity)
    local previous = Scheduler.current
    if previous and previous.stop then
        local ok, err = xpcall(previous.stop, debug.traceback)
        Env.elevate()
        if not ok then
            Life.errors["stop:" .. previous.name] = tostring(err)
        end
    end
    Scheduler.current = nextActivity
    if nextActivity and nextActivity.start then
        local ok, err = xpcall(nextActivity.start, debug.traceback)
        Env.elevate()
        if not ok then
            Life.errors["start:" .. nextActivity.name] = tostring(err)
        end
    end
end

-- For long steps (a fishing cast waits up to 30s for a bite): true when a more important
-- activity wants to run, so the step can bail out early. Checked at most once a second.
local yieldCache = {}
function Scheduler.shouldYield(activity)
    local cached = yieldCache[activity]
    if cached and os.clock() - cached.at < 1 then
        return cached.value
    end
    local value = false
    for _, other in ipairs(activities) do
        if other == activity or other.priority <= activity.priority then
            break
        end
        if wants(other) then
            value = true
            break
        end
    end
    yieldCache[activity] = { at = os.clock(), value = value }
    return value
end

task.spawn(function()
    while Life.alive do
        Env.elevate()
        local nextActivity = pick()
        if nextActivity ~= Scheduler.current then
            switch(nextActivity)
        end
        local current = Scheduler.current
        local delay = 0.2
        if current then
            local ok, result = xpcall(current.step, debug.traceback)
            Env.elevate()
            Life.errors["step:" .. current.name] = (not ok) and tostring(result) or nil
            delay = ok and type(result) == "number" and result or 0.2
            Scheduler.status = current.label or current.name
        else
            Scheduler.status = "Idle"
        end
        task.wait(delay)
    end
end)

Life.onCleanup(function()
    if Scheduler.current and Scheduler.current.stop then
        pcall(Scheduler.current.stop)
    end
    Scheduler.current = nil
end)

return Scheduler
end
__modules["core/ui"] = function(use) -- src/games/slayers2/core/ui.luau
-- Slayers 2's window: its tabs, and which of them load in the tower and the main menu.

local Env = use("core/env")
local Ui = use("shared/ui")

-- Inside the tower and in the main menu only some features load (see main), so only their tabs
-- are made.
local DUNGEON_TABS = { Home = true, Farm = true, Settings = true }
local MENU_TABS = { Home = true, Clan = true, Settings = true }

return Ui.create({
    footer = "Slayers 2",
    tabs = {
        { "Home", "house", "Welcome to Slopix Hub" },
        { "Guide", "book-open", "Fastest way to level, worked out for you" },
        { "Timers", "timer", "Day and night clock and boss respawns" },
        { "Locator", "map-pin", "A marker that points to any NPC, mob, shrine or training spot" },
        { "ESP", "eye", "Name tags on mobs, bosses, NPCs, chests, loot and players" },
        { "Farm", "swords", "Auto skills, auto heal, anti drown, anti sun and boss hunt timers" },
        { "Fishing", "fish", "Auto fishing" },
        { "Market", "store", "Black Marketer, shops and timed events" },
        { "Clan", "dices", "Clan spins" },
        { "Settings", "settings", "Menu, themes and configs" },
    },
    only = Env.inDungeon and DUNGEON_TABS or Env.inMenu and MENU_TABS or nil,
})
end
__modules["core/where"] = function(use) -- src/games/slayers2/core/where.luau
-- Where things are from where the character stands: "NE 340 studs, 60 up".
-- North is -Z and east is +X, as on the game's minimap. The map is very tall (towns sit around
-- y 300, 1000 and 1100), so a target far above or below says so.

local Data = use("core/data")

local Where = {}

local HEADINGS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
local NEAR = 15 -- closer than this (and level) is "right here"
local VERTICAL = 40 -- a difference in height this big is worth saying

-- "N", "NE", ... for an offset (target - you).
function Where.compass(offset)
    local angle = math.deg(math.atan2(offset.X, -offset.Z)) -- 0 = north, 90 = east
    return HEADINGS[(math.floor((angle + 22.5) / 45) % 8) + 1]
end

-- Studs along the ground from the character to `position`, or nil.
function Where.flat(position)
    local root = Data.character()
    if not (root and typeof(position) == "Vector3") then
        return nil
    end
    local offset = position - root.Position
    return Vector3.new(offset.X, 0, offset.Z).Magnitude
end

function Where.text(position)
    local root = Data.character()
    if not (root and typeof(position) == "Vector3") then
        return "location unknown"
    end
    local offset = position - root.Position
    local studs = math.floor(Vector3.new(offset.X, 0, offset.Z).Magnitude)
    local height = math.floor(offset.Y)
    local vertical = ""
    if math.abs(height) >= VERTICAL then
        vertical = string.format(", %d %s", math.abs(height), height > 0 and "up" or "down")
    end
    if studs < NEAR and vertical == "" then
        return "right here"
    end
    return string.format("%s %d studs%s", Where.compass(offset), studs, vertical)
end

return Where
end
__modules["features/accessories"] = function(use) -- src/games/slayers2/features/accessories.luau
-- Accessories: one button that wears the best pieces for the stats you pick in the five stat slots
-- (core/accessories has how "best" is worked out and how the pieces are put on). The vanity slots
-- are never touched.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")
local Accessories = use("core/accessories")

local Options = Ui.Options

-- The main fighting stats; speed, stamina, regeneration and the immunities are a click away.
local STAT_DEFAULTS = {
    "Additional Damage",
    "Additional Damage Factor",
    "Max Health",
    "Max Health Factor",
    "Damage Reduction",
    "Damage Reduction Factor",
}

local function pickedStats()
    local picked = {}
    for name, on in pairs(Options.AccessoryStats.Value) do
        if on then
            picked[name] = true
        end
    end
    return picked
end

local function pieceNames(pieces)
    local list = {}
    for _, piece in ipairs(pieces) do
        list[#list + 1] = piece.name
    end
    return table.concat(list, ", ")
end

-- What a run did, in a sentence or two, for the notification and the label.
local function describe(result)
    if result.error then
        return result.error
    end
    local parts = {}
    if #result.equipped > 0 then
        parts[#parts + 1] = "Equipped " .. pieceNames(result.equipped) .. "."
    end
    if #result.refused > 0 then
        parts[#parts + 1] = "The game refused " .. pieceNames(result.refused) .. "."
    end
    if result.incomplete then
        parts[#parts + 1] = "Stopped early: the game kept turning changes down."
    elseif #result.set == 0 then
        parts[#parts + 1] = #result.refused > 0 and "Nothing else could be worn."
            or "None of your accessories carry the stats you picked."
    elseif #result.equipped == 0 and #result.refused == 0 then
        parts[#parts + 1] = "Already wearing the best set: " .. pieceNames(result.set) .. "."
    else
        parts[#parts + 1] = "Wearing " .. pieceNames(result.set) .. "."
    end
    return table.concat(parts, " ")
end

-- UI ----------------------------------------------------------------------------------------------
local statNames = Accessories.statNames()
local defaults = {}
for _, name in ipairs(STAT_DEFAULTS) do
    if table.find(statNames, name) then
        defaults[#defaults + 1] = name
    end
end

local group = Ui.Tabs.Home:AddGroupbox({ Side = "Right", Name = "Accessories", IconName = "gem" })
group:AddDropdown("AccessoryStats", {
    Searchable = true,
    Text = "Stats to favour",
    Values = statNames,
    Default = defaults,
    Multi = true,
    Tooltip = "What the best set is chosen for. Each stat counts as a share of the most any piece gives of it, so health and damage weigh the same. Starts with the main fighting stats.",
})
local statusLabel -- under the button, shown once there is something to say

local running = false
local function run()
    if running then
        return
    end
    if next(pickedStats()) == nil then
        Ui.notify("Accessories", "Pick at least one stat to favour first.", 4)
        return
    end
    running = true
    local ok, result = xpcall(Accessories.equipBest, debug.traceback, pickedStats())
    Env.elevate()
    running = false
    if not Life.alive then
        return
    end
    local text
    if ok then
        Life.errors.accessories = nil
        text = describe(result)
    else
        Life.errors.accessories = tostring(result)
        text = "Could not equip: " .. (string.match(tostring(result), "^[^\n]+") or "unknown error")
    end
    statusLabel:SetText(text)
    statusLabel:SetVisible(true)
    Ui.notify("Accessories", text, 8)
end

group:AddButton({
    Text = "Equip best accessories",
    Tooltip = "Wears the best pieces for the stats above in your five stat slots. Costumes and clothing count too, since the game wears them in the same slots.",
    Func = function()
        task.spawn(run)
    end,
})
statusLabel = group:AddLabel("", true)
statusLabel:SetVisible(false)

return {}
end
__modules["features/antidrown"] = function(use) -- src/games/slayers2/features/antidrown.luau
-- Farm tab: anti drown.
--
-- Drowning is run by the client. The character's Swimming script drains Breath (17s x (1 + the
-- "Breath Duration Factor" stat) once you have been under for 1.5s; some water drowns you at once)
-- and, at zero, reports its own damage: SignalEvent.ToServer("Swim", "DrownDamage", amount) every
-- 0.5 units. Every tick it first asks MinigameSettings.Get("NoDrowning") (true in PvP matches),
-- and when that is true nothing drains, nothing is reported and the breath bar stays full.
-- So anti drown answers true to that one key, and as a backstop drops any DrownDamage report.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local AntiDrown = { blocked = 0 }

local group = Ui.Tabs.Farm:AddGroupbox({ Side = "Right", Name = "Anti drown", IconName = "waves" })
group:AddToggle("AntiDrown", {
    Text = "Anti drown",
    Default = false,
    Tooltip = "Stay under water as long as you like: your breath never runs out and you take no drowning damage.",
})
local statusLabel = group:AddLabel("", true)

local function on()
    return Life.alive and Ui.on("AntiDrown")
end

do
    local Settings = Env.Game.MinigameSettings
    local originalGet = Settings.Get
    local function get(key, ...)
        if key == "NoDrowning" and on() then
            return true
        end
        return originalGet(key, ...)
    end
    Settings.Get = get
    Life.onCleanup(function()
        if Settings.Get == get then
            Settings.Get = originalGet
        end
    end)
end

do
    local Signal = Env.Game.SignalEvent
    local originalToServer = Signal.ToServer
    local function toServer(name, action, ...)
        if name == "Swim" and action == "DrownDamage" and on() then
            AntiDrown.blocked += 1
            return nil
        end
        return originalToServer(name, action, ...)
    end
    Signal.ToServer = toServer
    Life.onCleanup(function()
        if Signal.ToServer == toServer then
            Signal.ToServer = originalToServer
        end
    end)
end

Life.loop("antidrown:panel", 1, function()
    local char = Env.LocalPlayer.Character
    local underwater = char and char:GetAttribute("SwimUnderwater") == true
    statusLabel:SetText(not Ui.on("AntiDrown") and "Off"
        or underwater and "Under water: breath held"
        or "On")
end)

return AntiDrown
end
__modules["features/antisun"] = function(use) -- src/games/slayers2/features/antisun.luau
-- Farm tab: anti sun damage.
--
-- A Demon burns in daylight, and the client decides it. The character's SunDamage script (Ouwland
-- only, Demons only) raycasts from the head to the sun and reports the result to the server with
-- SignalFunction "SunDamage"(inSun); the server burns you while the last report said true. It skips
-- the whole check when MinigameSettings.Get("NoSunDamage") is true (the tower and PvP matches), or
-- when you have the Sun Immunity stat or a ForceField, and then reports false.
-- So anti sun answers true to that one key, and as a backstop turns any "in the sun" report into
-- "not in the sun".

local Env = use("core/env")
local Life = use("shared/life")
local Data = use("core/data")
local Ui = use("core/ui")

local AntiSun = { blocked = 0 }

local group = Ui.Tabs.Farm:AddGroupbox({ Side = "Right", Name = "Anti sun damage", IconName = "sun" })
group:AddToggle("AntiSun", {
    Text = "Anti sun damage",
    Default = false,
    Tooltip = "Stay in the sun as long as you like: the game is told you are never in it, so a Demon takes no sun damage. Sun Immunity accessories do the same the normal way.",
})
local statusLabel = group:AddLabel("", true)

local function on()
    return Life.alive and Ui.on("AntiSun")
end

do
    local Settings = Env.Game.MinigameSettings
    local originalGet = Settings.Get
    local function get(key, ...)
        if key == "NoSunDamage" and on() then
            return true
        end
        return originalGet(key, ...)
    end
    Settings.Get = get
    Life.onCleanup(function()
        if Settings.Get == get then
            Settings.Get = originalGet
        end
    end)
end

do
    local Signal = Env.Game.SignalFunction
    local originalToServer = Signal.ToServer
    local function toServer(name, inSun, ...)
        if name == "SunDamage" and inSun == true and on() then
            AntiSun.blocked += 1
            return originalToServer(name, false, ...)
        end
        return originalToServer(name, inSun, ...)
    end
    Signal.ToServer = toServer
    Life.onCleanup(function()
        if Signal.ToServer == toServer then
            Signal.ToServer = originalToServer
        end
    end)
end

Life.loop("antisun:panel", 1, function()
    local race = Data.value("Race")
    if not Ui.on("AntiSun") then
        statusLabel:SetText("Off")
    elseif race ~= nil and race ~= "Demon" then
        statusLabel:SetText(string.format("On, but only Demons burn in the sun (you are %s)", tostring(race)))
    else
        statusLabel:SetText(AntiSun.blocked > 0 and string.format("On: no sun damage (%d report(s) turned around)", AntiSun.blocked)
            or "On: no sun damage")
    end
end)

return AntiSun
end
__modules["features/boss"] = function(use) -- src/games/slayers2/features/boss.luau
-- Boss hunts: live timers for the hunts on the boards.
--
-- Hunts are Configurations under ReplicatedStorage.BossHunts with attributes Boss (npc name),
-- ExpiresAt (os.time epoch), Quest ("Eliminate <boss>"), Tier and Side. Muzan hunts are for Demons
-- and Hybrids, Crow hunts for Slayers and Hybrids, each within a level band (BossHunts.Eligible),
-- so most live hunts are not yours to take. A hunt only pays whoever claimed it, which adds the
-- "Eliminate <boss>" quest (one at a time).

local Env = use("core/env")
local Life = use("shared/life")
local Data = use("core/data")
local Ui = use("core/ui")

local BossHunts = Env.need(Env.ReplicatedStorage, "BossHunts")
local TIMER_ROWS = 10

local timers = Ui.Tabs.Farm:AddGroupbox({ Side = "Left", Name = "Active hunts", IconName = "timer" })

local function hunts()
    local list = {}
    for _, config in ipairs(BossHunts:GetChildren()) do
        local name, expires = config:GetAttribute("Boss"), config:GetAttribute("ExpiresAt")
        if name and expires then
            list[#list + 1] = {
                id = config.Name,
                name = name,
                quest = config:GetAttribute("Quest"),
                expires = expires,
                tier = config:GetAttribute("Tier") or "?",
                side = config:GetAttribute("Side") or "?",
            }
        end
    end
    table.sort(list, function(a, b)
        return a.expires < b.expires
    end)
    return list
end

-- Whether this character can claim a hunt and be paid for it (side and level band).
local function mine(hunt)
    local ok, eligible = Env.call(function()
        local entry = Env.Game.BossHunts.Entry(hunt.name)
        return entry ~= nil and Env.Game.BossHunts.Eligible(entry, Env.LocalPlayer) == true
    end)
    return ok and eligible == true
end

-- The boss of the hunt we hold, if any (its "Eliminate <boss>" quest is active).
local function claimedBoss()
    local slot = Data.slot()
    local holder = slot and slot:FindFirstChild("Quests") and slot.Quests:FindFirstChild("Holder")
    for _, quest in ipairs(holder and holder:GetChildren() or {}) do
        local key = quest:FindFirstChild("QuestString")
        local definition = key and Env.Game.Quests.Holder[key.Value]
        if definition and definition.Category == "BossHunt" then
            return string.match(key.Value, "^Eliminate (.+)$")
        end
    end
    return nil
end

local function countdown(seconds)
    if seconds <= 0 then
        return "expired"
    end
    seconds = math.ceil(seconds)
    return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local panel = Ui.panel(timers, TIMER_ROWS)

Life.loop("boss:timers", 1, function()
    local list, now, lines = hunts(), os.time(), {}
    for index = 1, math.min(#list, TIMER_ROWS) do
        local hunt = list[index]
        lines[index] = string.format("%s  [%s / %s]  %s%s", hunt.name, hunt.tier, hunt.side,
            countdown(hunt.expires - now), mine(hunt) and "" or "  (not yours)")
    end
    local held = claimedBoss()
    local footer = (held and ("Your hunt: " .. held .. ". ") or "")
        .. (#list == 0 and "No boss hunts on the board." or string.format("%d hunt(s) on the board, soonest first.", #list))
    panel.set(lines, footer)
end)

return {
    hunts = hunts,
    mine = mine,
    claimedBoss = claimedBoss,
}
end
__modules["features/clan"] = function(use) -- src/games/slayers2/features/clan.luau
-- Clan tab: auto spin until a clan of the chosen rarity (or better) is rolled.
--
-- A spin is SignalFunction "ClanSpin" (returns the rolled clan name). The server then waits for
-- "ClanSpinComplete" before the next one; while it waits, LocalPlayer has the PendingClanSpin
-- attribute. Spins left: SpinBalance.Total(slot, true).

local Env = use("core/env")
local Life = use("shared/life")
local Data = use("core/data")
local Ui = use("core/ui")

local Options = Ui.Options
local PENDING = "PendingClanSpin"
local FINALIZE_TIMEOUT = 3
local DEFAULT_RARITY = 6

local Clans = Env.Game.Clans
local rarityByName, rarityNames = {}, {}
for _, tier in ipairs(Clans.Rarities) do
    rarityByName[tier.name] = tier.rarity
    rarityNames[#rarityNames + 1] = tier.name
end

local spins = 0

local function clanName()
    return Data.value("Clan") or "None"
end

local function rarityOf(name)
    local ok, clan = Env.call(Clans.GetClan, name)
    return ok and clan and clan.rarity or 0
end

local function tierOf(name)
    local ok, tier = Env.call(Clans.TierOf, name)
    return ok and tier and tier.name or "?"
end

local function spinsLeft()
    local slot = Data.slot()
    if not slot then
        return 0
    end
    local ok, total = Env.call(Env.Game.SpinBalance.Total, slot, true)
    return ok and total or 0
end

local function finalizePending()
    if Env.LocalPlayer:GetAttribute(PENDING) == nil then
        return true
    end
    Env.Game.SignalEvent.ToServer("ClanSpinComplete")
    local started = os.clock()
    while Life.alive and Env.LocalPlayer:GetAttribute(PENDING) ~= nil do
        if os.clock() - started > FINALIZE_TIMEOUT then
            return false
        end
        task.wait(0.05)
    end
    return true
end

-- One roll. Returns true plus the clan and its rarity, or false plus a reason.
local function spinOnce()
    if not finalizePending() then
        return false, "the previous spin is still pending"
    end
    local ok, rolled = Env.call(Env.Game.SignalFunction.ToServer, "ClanSpin")
    if not ok or type(rolled) ~= "string" then
        return false, "the server rejected the roll"
    end
    spins += 1
    finalizePending()
    return true, rolled, rarityOf(rolled)
end

local group = Ui.Tabs.Clan:AddGroupbox({ Side = "Left", Name = "Clan auto spin", IconName = "refresh-cw" })
group:AddDropdown("StopRarity", {
    Searchable = true,
    Text = "Stop at rarity",
    Values = rarityNames,
    Default = "Mythic",
    Multi = false,
})
group:AddSlider("SpinDelay", {
    Text = "Spin delay",
    Default = 0.4,
    Min = 0.1,
    Max = 3,
    Rounding = 1,
    Suffix = "s",
})
group:AddToggle("AutoSpin", {
    Text = "Auto spin",
    Default = false,
    Tooltip = "Rolls through the clan remote directly. Stops at the chosen rarity or when spins run out.",
})
Ui.automation("AutoSpin", true)
group:AddButton({ Text = "Spin once", Func = function()
    task.spawn(function()
        if spinsLeft() <= 0 then
            Ui.notify("Clan", "No clan spins left", 4)
            return
        end
        local ok, rolled = spinOnce()
        Ui.notify("Clan", ok and string.format("Rolled %s (%s)", rolled, tierOf(rolled)) or tostring(rolled), 4)
    end)
end })
local statusLabel = group:AddLabel("", true)

-- Buying a clan outright: the menu shop lists clans for spins (Shop.itemsforsale, Type "Clan").
local CONFIRM_WINDOW = 5
local clanPrices, clanNames = {}, {}
for name, listing in pairs(Env.Game.Shop.itemsforsale) do
    local price = type(listing) == "table" and listing.Type == "Clan" and type(listing.Price) == "table" and tonumber(listing.Price.Spins)
    if price then
        clanPrices[name] = price
        clanNames[#clanNames + 1] = name
    end
end
Env.elevate()
table.sort(clanNames, function(a, b)
    if clanPrices[a] ~= clanPrices[b] then
        return clanPrices[a] > clanPrices[b]
    end
    return a < b
end)

local function purchaseBalance()
    local slot = Data.slot()
    local ok, total = Env.call(Env.Game.SpinBalance.Total, slot, false)
    return slot and ok and total or 0
end

local buyGroup = Ui.Tabs.Clan:AddGroupbox({ Side = "Right", Name = "Buy a clan", IconName = "shopping-bag" })
buyGroup:AddDropdown("ClanBuyPick", {
    Searchable = true,
    Text = "Clan",
    Values = clanNames,
    Default = clanNames[1],
    Multi = false,
})
local buyLabel = buyGroup:AddLabel("", true)
local confirmUntil, confirmName = 0, nil
buyGroup:AddButton({ Text = "Buy with spins", Func = function()
    local name = Options.ClanBuyPick.Value
    local price = clanPrices[name]
    if not price then
        return
    end
    local ok, allowed, reason = Env.call(Env.Game.Shop.CanBuy, Env.LocalPlayer, name, nil, 1)
    if not (ok and allowed) then
        Ui.notify("Clan", string.format("Cannot buy %s: %s", name, tostring(reason or "not enough spins")), 5)
        return
    end
    -- It replaces your clan, so the first click only arms it.
    if confirmName ~= name or os.clock() > confirmUntil then
        confirmName, confirmUntil = name, os.clock() + CONFIRM_WINDOW
        Ui.notify("Clan", string.format("Click again within %ds to spend %d spins on %s (replaces %s).", CONFIRM_WINDOW, price, name, clanName()), CONFIRM_WINDOW)
        return
    end
    confirmName = nil
    task.spawn(function()
        local called, _, message = Env.call(Env.Game.SignalFunction.ToServer, "PurchaseFromShop", name, 1)
        local deadline = os.clock() + 3
        while clanName() ~= name and os.clock() < deadline do
            task.wait(0.2)
        end
        Env.elevate()
        if clanName() == name then
            Ui.notify("Clan", "You are now " .. name, 6)
        else
            local why = called and type(message) == "string" and (": " .. message) or ""
            Ui.notify("Clan", "The purchase did not go through" .. why, 6)
        end
    end)
end })

Life.loop("clan:buy", 1, function()
    local name = Options.ClanBuyPick.Value
    local price = clanPrices[name]
    buyLabel:SetText(price and string.format("%s (%s): %s spins\nYou have %s spins to spend.", name, tierOf(name), price, purchaseBalance())
        or "No clans are for sale.")
end)

local function stop(message, seconds)
    Ui.set("AutoSpin", false)
    Ui.notify("Clan", message, seconds)
end

Life.loop("clan:spin", function()
    return Ui.on("AutoSpin") and Options.SpinDelay.Value or 0.5
end, function()
    local current = clanName()
    statusLabel:SetText(string.format("Clan: %s (%s)\nSpins left: %d  |  rolled this session: %d", current, tierOf(current), spinsLeft(), spins))
    if not Ui.on("AutoSpin") then
        return
    end
    local target = rarityByName[Options.StopRarity.Value] or DEFAULT_RARITY
    if rarityOf(current) >= target then
        return stop(string.format("Stopped: you already have %s (%s or better)", current, Options.StopRarity.Value), 6)
    end
    if spinsLeft() <= 0 then
        return stop("No clan spins left", 5)
    end
    local ok, rolled, rarity = spinOnce()
    if not ok then
        return stop(spinsLeft() <= 0 and "No clan spins left" or "Roll rejected - open the clan spin screen or rejoin", 6)
    end
    if rarity >= target then
        stop(string.format("Got %s (%s) after %d spins", rolled, tierOf(rolled), spins), 8)
    end
end)

return {}
end
__modules["features/esp"] = function(use) -- src/games/slayers2/features/esp.luau
-- ESP tab: name tags on mobs, bosses, NPCs, chests, loot drops and players, seen through walls.
--
-- Each tag is a BillboardGui adorned to a part that already exists (a rig's root, a chest's
-- RootPart, a drop), kept in a folder of its own in the executor's GUI holder, so nothing is added
-- to the world and the game cannot see it. Only what is streamed in can be tagged.
--  * Mobs and bosses: workspace.Humanoids.Regions.<Region>.ActiveNpcs.<Name>.<Name>. A folder
--    with BossInfo is a boss. Health is the rig's Humanoid; exp per kill is what the game says the
--    mob is worth (core/npcdata), shown before your multiplier.
--  * NPCs: workspace.Debree.Regions.<Region>.StationaryNpcs.<Name> (idle ones too).
--  * Chests: workspace.Chests models, with ChestState and IsOpen; opened ones are left out.
--  * Loot: parts tagged "LootDrop" that are yours to take (same rules as the game's own
--    VisualBinder.isEligible).

local Env = use("core/env")
local Life = use("shared/life")
local Data = use("core/data")
local Ui = use("core/ui")
local Combat = use("core/combat")
local NpcData = use("core/npcdata")

local Options = Ui.Options

local EVERY = 0.25
local CAP = { mobs = 40, bosses = 12, npcs = 30, chests = 30, loot = 30, players = 30 }
local COLORS = {
    mobs = Color3.fromRGB(255, 150, 90),
    bosses = Color3.fromRGB(235, 64, 96),
    npcs = Color3.fromRGB(110, 200, 255),
    chests = Color3.fromRGB(255, 214, 90),
    loot = Color3.fromRGB(150, 255, 150),
    players = Color3.fromRGB(255, 255, 255),
}
local CLOSED = { Opening = true, Opened = true, Despawned = true }
local userId = Env.LocalPlayer.UserId

-- UI --------------------------------------------------------------------------------------------------------

local tab = Ui.Tabs.ESP
local box = tab:AddGroupbox({ Side = "Left", Name = "Name tags", IconName = "eye" })
local TOGGLES = {
    { "EspMobs", "Mobs", "mobs", "Hostile mobs, with their health and the exp a kill is worth." },
    { "EspBosses", "Bosses", "bosses", "Bosses, with their health." },
    { "EspNpcs", "NPCs", "npcs", "Quest givers, shops and trainers that are streamed in." },
    { "EspChests", "Chests", "chests", "Chests that can still be opened (guards up is marked)." },
    { "EspLoot", "Loot drops", "loot", "Drops that are yours to pick up." },
    { "EspPlayers", "Players", "players", "Other players, with their health." },
}
for _, entry in ipairs(TOGGLES) do
    box:AddToggle(entry[1], { Text = entry[2], Default = false, Tooltip = entry[4] })
end
box:AddSlider("EspRange", {
    Text = "Range",
    Default = 700,
    Min = 100,
    Max = 3000,
    Rounding = 0,
    Suffix = " studs",
    Tooltip = "Tags further away than this are hidden. Only what the game has streamed in near you can be tagged anyway.",
})
box:AddLabel("Tags are drawn on your screen only. The nearest ones of each kind are shown.", true)

local function enabled(category)
    for _, entry in ipairs(TOGGLES) do
        if entry[3] == category then
            return Ui.on(entry[1])
        end
    end
    return false
end

-- Tags ------------------------------------------------------------------------------------------------------------

local function guiParent()
    local ok, parent = pcall(function()
        return (gethui and gethui()) or game:GetService("CoreGui")
    end)
    if ok and parent then
        return parent
    end
    return Env.LocalPlayer:WaitForChild("PlayerGui")
end

local holder = Instance.new("Folder")
holder.Name = "SlopixEsp"
holder.Parent = guiParent()
Life.onCleanup(function()
    holder:Destroy()
end)

local tags = {} -- key (the instance the tag belongs to) -> { gui, label, seen }
local pass = 0

local function tag(key, adornee, text, color)
    local entry = tags[key]
    if not entry then
        local gui = Instance.new("BillboardGui")
        gui.AlwaysOnTop = true
        gui.LightInfluence = 0
        gui.ResetOnSpawn = false
        gui.Size = UDim2.fromOffset(190, 56)
        gui.StudsOffset = Vector3.new(0, 3, 0)
        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Size = UDim2.fromScale(1, 1)
        label.Font = Enum.Font.GothamBold
        label.TextSize = 13
        label.TextStrokeTransparency = 0.4
        label.TextWrapped = true
        label.Parent = gui
        entry = { gui = gui, label = label }
        tags[key] = entry
        gui.Parent = holder
    end
    entry.seen = pass
    if entry.gui.Adornee ~= adornee then
        entry.gui.Adornee = adornee
    end
    entry.gui.MaxDistance = Options.EspRange.Value
    entry.label.Text = text
    entry.label.TextColor3 = color
end

local function sweep()
    for key, entry in pairs(tags) do
        if entry.seen ~= pass then
            entry.gui:Destroy()
            tags[key] = nil
        end
    end
end

-- Candidates ------------------------------------------------------------------------------------------------------

local function distanceTo(root, part)
    return (part.Position - root.Position).Magnitude
end

-- The nearest `cap` of candidates ({ key, part, text, distance }), tagged.
local function show(category, candidates)
    table.sort(candidates, function(a, b)
        return a.distance < b.distance
    end)
    for index = 1, math.min(#candidates, CAP[category]) do
        local candidate = candidates[index]
        tag(candidate.key, candidate.part, string.format("%s\n%d studs", candidate.text, math.floor(candidate.distance)), COLORS[category])
    end
end

local function healthText(humanoid)
    return string.format("%d / %d HP", math.floor(humanoid.Health), math.floor(humanoid.MaxHealth))
end

local function scanMobs(root, range)
    local wantMobs, wantBosses = enabled("mobs"), enabled("bosses")
    if not (wantMobs or wantBosses) then
        return
    end
    local mobs, bosses = {}, {}
    for _, rig in ipairs(Combat.rigs()) do
        local part = rig:FindFirstChild("HumanoidRootPart")
        local humanoid = rig:FindFirstChildOfClass("Humanoid")
        if part and humanoid then
            local distance = distanceTo(root, part)
            if distance <= range then
                local folder = rig.Parent
                if folder and folder:FindFirstChild("BossInfo") then
                    if wantBosses then
                        bosses[#bosses + 1] = { key = rig, part = part, distance = distance, text = rig.Name .. "\n" .. healthText(humanoid) }
                    end
                elseif wantMobs and rig:GetAttribute("IsMob") == true then
                    local exp = NpcData.exp(rig)
                    local extra = exp > 0 and string.format("  +%d exp", math.floor(exp)) or ""
                    mobs[#mobs + 1] = { key = rig, part = part, distance = distance, text = rig.Name .. extra .. "\n" .. healthText(humanoid) }
                end
            end
        end
    end
    show("mobs", mobs)
    show("bosses", bosses)
end

local function scanNpcs(root, range)
    if not enabled("npcs") then
        return
    end
    local debree = workspace:FindFirstChild("Debree")
    local regions = debree and debree:FindFirstChild("Regions")
    local list = {}
    for _, region in ipairs(regions and regions:GetChildren() or {}) do
        local stationary = region:FindFirstChild("StationaryNpcs")
        for _, model in ipairs(stationary and stationary:GetChildren() or {}) do
            local part = model:IsA("Model") and model:FindFirstChild("HumanoidRootPart")
            if part then
                local distance = distanceTo(root, part)
                if distance <= range then
                    list[#list + 1] = { key = model, part = part, distance = distance, text = model.Name }
                end
            end
        end
    end
    show("npcs", list)
end

local function scanChests(root, range)
    if not enabled("chests") then
        return
    end
    local folder = workspace:FindFirstChild("Chests")
    local list = {}
    for _, model in ipairs(folder and folder:GetChildren() or {}) do
        local state = model:GetAttribute("ChestState")
        if model:IsA("Model") and model:GetAttribute("ChestGuid") ~= nil and model:GetAttribute("IsOpen") ~= true
            and not CLOSED[state] then
            local part = model:FindFirstChild("RootPart") or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
            if part and part:IsA("BasePart") then
                local distance = distanceTo(root, part)
                if distance <= range then
                    local name = tostring(model:GetAttribute("ChestId") or model.Name)
                    list[#list + 1] = { key = model, part = part, distance = distance, text = name .. (state == "Locked" and "  (guards up)" or "") }
                end
            end
        end
    end
    show("chests", list)
end

-- Mirrors the game's own LootDrop VisualBinder.isEligible.
local function mine(drop)
    local owner = drop:GetAttribute("DropOwnerUserId")
    if typeof(owner) == "number" and owner ~= userId then
        return false
    end
    local reserved = drop:GetAttribute("DropReservedFor")
    if typeof(reserved) == "string" and not string.find(reserved, "," .. userId .. ",", 1, true) then
        return false
    end
    return drop:GetAttribute("DropClaimedBy") == nil
end

local function scanLoot(root, range)
    if not enabled("loot") then
        return
    end
    local list = {}
    for _, drop in ipairs(Env.CollectionService:GetTagged("LootDrop")) do
        if drop:IsA("BasePart") and drop.Parent and mine(drop) then
            local distance = distanceTo(root, drop)
            if distance <= range then
                local name = drop:GetAttribute("ItemName") or drop:GetAttribute("Item") or drop.Name
                list[#list + 1] = { key = drop, part = drop, distance = distance, text = tostring(name) }
            end
        end
    end
    show("loot", list)
end

local function scanPlayers(root, range)
    if not enabled("players") then
        return
    end
    local list = {}
    for _, player in ipairs(Env.Players:GetPlayers()) do
        local char = player ~= Env.LocalPlayer and player.Character
        local part = char and char:FindFirstChild("HumanoidRootPart")
        local humanoid = char and char:FindFirstChildOfClass("Humanoid")
        if part and humanoid then
            local distance = distanceTo(root, part)
            if distance <= range then
                list[#list + 1] = { key = char, part = part, distance = distance, text = player.DisplayName .. "\n" .. healthText(humanoid) }
            end
        end
    end
    show("players", list)
end

Life.loop("esp:tags", EVERY, function()
    pass += 1
    local root = Data.character()
    local any = false
    for _, entry in ipairs(TOGGLES) do
        any = any or Ui.on(entry[1])
    end
    if root and any then
        local range = Options.EspRange.Value
        scanMobs(root, range)
        scanNpcs(root, range)
        scanChests(root, range)
        scanLoot(root, range)
        scanPlayers(root, range)
    end
    sweep()
end)

return {}
end
__modules["features/fishing"] = function(use) -- src/games/slayers2/features/fishing.luau
-- Fishing tab: auto fishing with an instant reel.
--
-- Verified flow: with a rod (ToolScript "Rare Fishing Rod") equipped, SignalEvent "Tool_Mouse"
-- Up at a water position casts. After 4-9s the server fires ServerClientPortal.Event
-- ("FishingRod", "Bite", token); replying Event:FireServer("FishingRod", token, true) records a
-- won reel, but only 4.5s or more after the bite (place 5400; sooner counts as lost). The minigame
-- itself can't be won in under 5s, and its RenderStepped loop outlives the game's BiteCancel (see
-- closeBiteUi). A win still rolls the catch chance ("BiteMissed" on a miss or a loss, and a roll
-- can also come up empty with no message). The bobber (workspace.Debree.FishingLine_<n>)
-- and the catch (FishingCatch_<n>, CatchItem attribute) both hang on a RopeConstraint
-- "FishingLine" whose Attachment0 is the caster's rod tip, which is how ours are told apart. The
-- catch has a 2s "Collect" prompt the server only pays out for a real hold (fireproximityprompt is
-- ignored), and a hold only registers once the prompt is on screen. Casting or unequipping before
-- collecting drops the catch on the ground. The rod can stay equipped between casts.

local Env = use("core/env")
local Life = use("shared/life")
local Data = use("core/data")
local Ui = use("core/ui")
local Scheduler = use("core/scheduler")

local Options = Ui.Options
local BITE_TIMEOUT = 30
-- Seconds after the bite before a won reel is reported. The server rejects one under 4.5s, timed
-- from when it sent the bite, so our clock (started when the bite arrived) already runs behind it.
local REEL_DELAY = 4.6
-- After a verdict the server spends 1.4s reeling in and ignores casts meanwhile.
local UNCAST_TIME = 1.5
local CAST_TRIES = 2
-- Failures in a row that a retry might fix (a lost line, a refused equip) before giving up.
local MAX_STRIKES = 3

local tab = Ui.Tabs.Fishing
local group = tab:AddGroupbox({ Side = "Left", Name = "Auto fishing", IconName = "fish" })
local log = tab:AddGroupbox({ Side = "Right", Name = "Catch log", IconName = "list" })
local statusLabel = log:AddLabel("Idle", true)
local catchLabel = log:AddLabel("Items caught this session: 0", true)

local Fishing = { status = "Idle", caught = 0 }

local function setStatus(text)
    Fishing.status = text
    Env.elevate()
    statusLabel:SetText(text)
end

-- Rods are Fishing items held in the hand (EquipType 2; bait is 6, catches have none): Basic
-- Fishing Rod, Rare Fishing Rod (bought with Golden Fish) and Legendary Fishing Rod (Isao's quest).
-- They all run the same tool script. Only rods with ToolScript "Rare Fishing Rod" used to count,
-- which missed the Rare rod itself: it has no ToolScript field because it is that script.
local BEST_ROD = "Best rod I own"

local function isRod(definition)
    return type(definition) == "table" and definition.Category == "Fishing" and definition.EquipType == 2
end

-- Owned rods, best (rarest) first.
local function rods()
    local list = {}
    for name in pairs(Data.counts()) do
        local definition = Env.Game.Items[name]
        if isRod(definition) then
            list[#list + 1] = { name = name, rarity = tonumber(definition.Rarity) or 0 }
        end
    end
    table.sort(list, function(a, b)
        if a.rarity ~= b.rarity then
            return a.rarity > b.rarity
        end
        return a.name < b.name
    end)
    local names = {}
    for index, rod in ipairs(list) do
        names[index] = rod.name
    end
    return names
end

local function rodChoices()
    local choices = { BEST_ROD }
    for _, name in ipairs(rods()) do
        choices[#choices + 1] = name
    end
    return choices
end

-- The rod to fish with, or nil and why.
local function pickedRod()
    local owned = rods()
    local picked = Options.FishingRod.Value
    if picked == BEST_ROD or picked == nil or picked == "" then
        return owned[1], owned[1] == nil and "You own no fishing rod" or nil
    end
    if table.find(owned, picked) then
        return picked
    end
    return owned[1], owned[1] == nil and "You own no fishing rod" or nil
end

-- Hotbar index of `rod`, putting it on the hotbar first if needed: into the slot of another rod,
-- else an empty slot. Never over one of your other items.
local function rodSlot(rod)
    local index = Data.hotbarIndex(rod)
    if index then
        return index
    end
    local _, toolbar = Data.inventory()
    local slotKey
    for _, other in ipairs(rods()) do
        local otherIndex = other ~= rod and Data.hotbarIndex(other)
        if otherIndex then
            slotKey = Data.TOOLBAR_SLOTS[otherIndex]
            break
        end
    end
    index = toolbar and Data.putOnHotbar(rod, slotKey)
    if not index then
        return nil, string.format("No free hotbar slot for %s. Free one, or put it on the hotbar yourself", rod)
    end
    return index
end

group:AddDropdown("FishingRod", {
    Searchable = true,
    Text = "Rod",
    Values = rodChoices(),
    Default = BEST_ROD,
    Tooltip = "Any rod you own. It goes on the hotbar by itself, in place of another rod or in an empty slot.",
})
group:AddButton({ Text = "Refresh rods", Func = function()
    local choices = rodChoices()
    Options.FishingRod:SetValues(choices)
    if not table.find(choices, Options.FishingRod.Value) then
        Options.FishingRod:SetValue(BEST_ROD)
    end
end })
group:AddToggle("InstantReel", {
    Text = "Instant reel",
    Default = true,
    Tooltip = "Skips the minigame and reports a won reel to the server. The game only accepts one 4.5s after the bite.",
})
group:AddToggle("AutoFish", {
    Text = "Auto fishing",
    Default = false,
    Tooltip = "Casts, reels and collects on repeat where you stand. Auto heal takes over while it drinks a potion and fishing resumes after.",
})
Ui.automation("AutoFish")
group:AddLabel("Walk up to open water yourself first (the dock, a shore): it fishes where you stand. Uses your "
    .. "equipped bait, if any. Catches are collected into your inventory.", true)

-- Game plumbing --------------------------------------------------------------------------------
local PortalEvent = Env.need(Env.ReplicatedStorage.CAM.Global.ServerClientPortal, "Event")
local Debree = Env.need(workspace, "Debree")
local biteToken, biteAt, biteMissed, biteCancelled = nil, nil, nil, nil
-- Our bobber and catch, caught the moment they replicate (see onOurLine).
local myBobber, myCatch = nil, nil
local connections = {}
local closingUi = false

-- True when `model` hangs on a fishing line running from our rod tip. The server builds both the
-- bobber and the catch that way, so this tells ours from other players' as they spawn.
local function onOurLine(model)
    local line = model:FindFirstChild("FishingLine", true)
    local tip = line and line:IsA("RopeConstraint") and line.Attachment0
    local char = Env.LocalPlayer.Character
    return tip ~= nil and char ~= nil and tip:IsDescendantOf(char)
end

-- The reel minigame's per-frame loops: RenderStepped connections made by the game's BarKeepup
-- module. Tearing a minigame down never disconnects its loop, so the game leaks one per bite.
local function minigameLoops()
    local loops = {}
    for _, connection in ipairs(getconnections(Env.RunService.RenderStepped)) do
        local fn = connection.Function
        local ok, source = false, nil
        if fn then
            ok, source = pcall(debug.info, fn, "s")
        end
        if ok and type(source) == "string" and string.find(source, "BarKeepup", 1, true) then
            loops[#loops + 1] = connection
        end
    end
    return loops
end

local function disconnectMinigameLoops()
    for _, connection in ipairs(minigameLoops()) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    return #minigameLoops() == 0
end

-- Stops the reel minigame without a verdict, so it cannot report a loss while we wait to send the
-- win. Its loop goes first: the game's own BiteCancel only tears the UI down, and a loop left
-- running reports a loss once the bar drains (~3.5s). BiteCancel then clears the screen; its
-- handlers are called directly because Real ignores firesignal and Connection:Fire. True once
-- nothing is left that could report; false leaves the minigame running, to be played instead.
local function closeBiteUi()
    if not getconnections or #minigameLoops() == 0 or not disconnectMinigameLoops() then
        Env.elevate()
        return false
    end
    closingUi = true
    for _, connection in ipairs(getconnections(PortalEvent.OnClientEvent)) do
        if connection.Function then
            pcall(connection.Function, "FishingRod", "BiteCancel")
        end
    end
    closingUi = false
    Env.elevate()
    return true
end

local function catchSnapshot()
    local existing = {}
    for _, model in ipairs(Debree:GetChildren()) do
        existing[model] = true
    end
    return existing
end

-- The nearest catch that is not in `existing`: the fallback for when our line cannot be seen.
local function newCatch(root, existing)
    local best, bestDistance
    for _, model in ipairs(Debree:GetChildren()) do
        if not existing[model] and model:GetAttribute("CatchItem") then
            local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
            local part = prompt and prompt.Parent
            if part and part:IsA("BasePart") then
                local distance = (part.Position - root.Position).Magnitude
                if not bestDistance or distance < bestDistance then
                    best, bestDistance = model, distance
                end
            end
        end
    end
    return best
end

local function waterTarget(root, char)
    local water = RaycastParams.new()
    water.FilterType = Enum.RaycastFilterType.Include
    water.BruteForceAllSlow = true
    local parts = {}
    for _, part in ipairs(Env.CollectionService:GetTagged("SwimParts")) do
        parts[#parts + 1] = part.Parent or part
    end
    water.FilterDescendantsInstances = parts
    local ground = RaycastParams.new()
    ground.FilterType = Enum.RaycastFilterType.Exclude
    ground.FilterDescendantsInstances = { char, Debree }
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

-- Activity -------------------------------------------------------------------------------------
local activity = { name = "Auto fishing", priority = Scheduler.PRIORITY.fishing, label = "Fishing", status = "Idle" }
local fishingSlot, strikes = nil, 0
-- The water target found from where you stand, reused until you move.
local lastSpot = nil

local function wanted()
    return Ui.on("AutoFish")
end

local function stillOn()
    return Life.alive and wanted() and not Scheduler.shouldYield(activity)
end

-- Waits until done() holds or `seconds` pass, checking done() every frame and stillOn() every
-- 0.1s. Returns true when done() held, false on timeout, nil when fishing has to stop.
local function waitUntil(done, seconds)
    local deadline = os.clock() + seconds
    local nextCheck = 0
    while not done() do
        local now = os.clock()
        if now >= deadline then
            return false
        end
        if now >= nextCheck then
            if not stillOn() then
                return nil
            end
            nextCheck = now + 0.1
        end
        task.wait()
    end
    return true
end

local function never()
    return false
end

-- Waits `seconds`; false when fishing has to stop first.
local function waitOn(seconds)
    return waitUntil(never, seconds) ~= nil
end

-- Plays the reel minigame (Instant reel off): hold while the bar sits below the fish tracker.
local function reel()
    if not getconnections then
        return false, "Your executor has no getconnections, which playing the reel needs: turn Instant reel on"
    end
    local lastY, lastTime, held, currentGui
    local deadline = os.clock() + 45
    while stillOn() and Env.LocalPlayer:GetAttribute("FishingBite") do
        if os.clock() >= deadline then
            return false, "Reeling timed out"
        end
        local misc = Env.LocalPlayer.PlayerGui:FindFirstChild("Misc")
        local tracker = misc and misc:FindFirstChild("tracker", true)
        local bar = tracker and tracker.Parent:FindFirstChild("Bar")
        if bar then
            local gui = tracker:FindFirstAncestorOfClass("CanvasGroup")
            if currentGui ~= gui then
                lastY, lastTime, held, currentGui = nil, nil, nil, gui
            end
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
                if not invoked then
                    return false, "The fishing input handler is unavailable"
                end
                held = press
            end
            lastY, lastTime = y, now
        end
        task.wait(0.025)
    end
    return true
end

-- Collects our catch. It spawns at the bobber just after the verdict and is pulled to the rod tip;
-- the hold starts the moment its prompt comes on screen and the server pays out when it completes.
-- Returns whether it was collected and the item's name (nil when nothing was caught).
local function collectCatch(root, existing)
    local model = nil
    local found = waitUntil(function()
        model = myCatch
        return model ~= nil or biteMissed
    end, 0.8)
    if found == false then
        found = waitUntil(function()
            model = myCatch or newCatch(root, existing)
            return model ~= nil or biteMissed
        end, 1.2)
    end
    if not model or not model.Parent then
        return nil
    end
    local item = tostring(model:GetAttribute("CatchItem"))
    local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
    if not found or not prompt then
        return false, item
    end
    setStatus(string.format("Pulling in %s...", item))
    -- The prompt can show and hide again while the catch swings in, which drops a hold; each time
    -- it shows again the hold starts over.
    local shown, seen, holding, triggered = false, false, false, false
    local promptConnections = {
        prompt.PromptShown:Connect(function()
            shown, seen = true, true
        end),
        prompt.PromptHidden:Connect(function()
            shown, seen = false, true
        end),
        prompt.PromptButtonHoldEnded:Connect(function()
            holding = false
        end),
        prompt.Triggered:Connect(function()
            triggered = true
        end),
    }
    -- PromptShown can have fired before we connected, so until an event is seen, being in range
    -- for a moment counts too.
    local inRangeSince = nil
    local function ready()
        if shown or not model.Parent then
            return true
        end
        local part = prompt.Parent
        if not seen and part:IsA("BasePart")
            and (part.Position - root.Position).Magnitude <= prompt.MaxActivationDistance - 0.5 then
            inRangeSince = inRangeSince or os.clock()
            return os.clock() - inRangeSince >= 0.15
        end
        inRangeSince = nil
        return false
    end
    local deadline = os.clock() + 8
    while model.Parent and not triggered and os.clock() < deadline do
        if not waitUntil(ready, deadline - os.clock()) or not model.Parent then
            break
        end
        setStatus(string.format("Collecting %s...", item))
        holding = true
        pcall(prompt.InputHoldBegin, prompt)
        local ended = waitUntil(function()
            return model.Parent == nil or triggered or not holding
        end, prompt.HoldDuration + 1)
        pcall(prompt.InputHoldEnd, prompt)
        if ended == nil then
            break
        end
        if ended == false then
            -- The hold ran its time without a payout: whatever showed it was stale.
            shown, seen = false, true
        end
    end
    if triggered then
        waitUntil(function()
            return model.Parent == nil
        end, 1)
    end
    for _, connection in ipairs(promptConnections) do
        connection:Disconnect()
    end
    if model.Parent and stillOn() then
        -- Last resort, for a game version that stops checking the hold.
        Env.firePrompt(prompt)
        waitUntil(function()
            return model.Parent == nil
        end, 1)
    end
    Env.elevate()
    return model.Parent == nil, item
end

-- Checks you are somewhere you can fish: on the ground with open water within 32 studs. The hub
-- does not take you there (the anti-teleport pulls a moved character back). Returns the water
-- target, or nil, why and whether a retry might help.
local function ensureSpot()
    local root, humanoid, char = Data.character()
    if not root or not humanoid or humanoid.Health <= 0 then
        return nil, "Character is not ready", true
    end
    local deadline = os.clock() + 3
    while humanoid.FloorMaterial == Enum.Material.Air or (char:GetAttribute("SwimState") or 0) > 0 do
        if os.clock() >= deadline then
            break
        end
        task.wait(0.2)
    end
    local grounded = humanoid.FloorMaterial ~= Enum.Material.Air and (char:GetAttribute("SwimState") or 0) == 0
    local target = nil
    if grounded then
        if lastSpot and (root.Position - lastSpot.from).Magnitude < 2 then
            target = lastSpot.target
        else
            target = waterTarget(root, char)
            lastSpot = target and { from = root.Position, target = target } or nil
        end
    end
    if target then
        return target
    end
    if grounded then
        return nil, "No open water nearby. Walk up to the water (the dock, a shore) and turn it on again"
    end
    return nil, "Stand on the dock or shore before fishing", true
end

local function rodInHand(rod)
    local _, _, char = Data.character()
    local accessories = char and char:FindFirstChild("Tool_Accessories")
    return accessories ~= nil and accessories:FindFirstChild(rod) ~= nil
end

-- Equips the rod on hotbar slot `index` and waits until it is in hand. True once it is, nil when
-- fishing has to stop.
local function equipRod(index, rod)
    local equipped = Data.equipped()
    local function holding()
        return equipped.Value == index and rodInHand(rod)
    end
    if holding() then
        return true
    end
    for _ = 1, 3 do
        -- The game reverts a direct swap from another slot, and setting the slot it already has
        -- does nothing, so go through 0.
        if equipped.Value ~= 0 then
            equipped.Value = 0
            if not waitOn(0.5) then
                return nil
            end
        end
        equipped.Value = index
        local held = waitUntil(holding, 2)
        if held == nil then
            return nil
        end
        -- The rod model shows up a moment before the server has hooked the rod up.
        if held then
            return waitOn(0.2) or nil
        end
    end
    return false
end

-- Unequips and re-equips the rod, which makes the server drop whatever state it was stuck in: a
-- line still out, a bite waiting on a verdict, a catch left hanging.
local function resetRod(index, rod)
    local equipped = Data.equipped()
    equipped.Value = 0
    local cleared = waitUntil(function()
        return not rodInHand(rod)
    end, 1.5)
    if cleared == nil or not waitOn(0.3) then
        return nil
    end
    return equipRod(index, rod)
end

-- Casts at `target` and waits for our bobber. The server ignores a cast while it is still reeling
-- in, and a cast with a catch still hanging only drops the catch, so one retry. True once the
-- bobber is out, nil when fishing has to stop.
local function castLine(target)
    for _ = 1, CAST_TRIES do
        myBobber = nil
        Env.Game.SignalEvent.ToServer("Tool_Mouse", "Up", target)
        Env.elevate()
        local landed = waitUntil(function()
            return myBobber ~= nil
        end, 1.5)
        if landed ~= false then
            return landed
        end
    end
    return false
end

-- Adds what the last catch put in your inventory to the log, off the fishing loop so the next cast
-- does not wait on the inventory.
local function logCatch(before, collected, item, missed)
    task.spawn(function()
        local total, gains = 0, {}
        local deadline = os.clock() + (collected and 2 or 0)
        repeat
            total, gains = 0, {}
            for name, amount in pairs(Data.counts()) do
                local gain = amount - (before[name] or 0)
                if gain > 0 then
                    total += gain
                    gains[#gains + 1] = string.format("%s x%d", name, gain)
                end
            end
            if total > 0 or os.clock() >= deadline then
                break
            end
            task.wait(0.1)
        until false
        Fishing.caught += total
        local outcome = total > 0 and table.concat(gains, ", ")
            or missed and "The fish got away"
            or item and string.format("Could not collect %s", item)
            or "Nothing on the line"
        Env.elevate()
        catchLabel:SetText(string.format("Items caught this session: %d\nLast attempt: %s", Fishing.caught, outcome))
    end)
end

-- One cast, bite, reel and collect. Returns true when it went through or fishing was stopped;
-- otherwise false, why, and whether a retry might fix it.
local function fishOnce()
    local target, why, retry = ensureSpot()
    if not target then
        return false, why, retry
    end
    local root = Data.character()
    local rod, noRod = pickedRod()
    if not rod then
        return false, noRod
    end
    local index, noSlot = rodSlot(rod)
    if not index then
        return false, noSlot
    end
    fishingSlot = index
    local held = equipRod(index, rod)
    if held == nil then
        return true
    end
    if not held then
        return false, "The game refused to equip " .. rod, true
    end

    local before = Data.counts()
    local instant = Ui.on("InstantReel")
    biteToken, biteAt, biteMissed, biteCancelled, myCatch = nil, nil, nil, nil, nil
    setStatus("Casting with " .. rod .. "...")
    local cast = castLine(target)
    if cast == false then
        setStatus("Resetting the rod...")
        cast = resetRod(index, rod)
        if cast then
            cast = castLine(target)
        end
    end
    if cast == nil then
        return true
    end
    if not cast then
        lastSpot = nil
        return false, "The game did not take the cast", true
    end

    setStatus("Waiting for a bite...")
    local function bitten()
        if instant then
            return biteToken ~= nil
        end
        return Env.LocalPlayer:GetAttribute("FishingBite") == true
    end
    local bobber = myBobber
    local bite = waitUntil(function()
        return bitten() or bobber.Parent == nil
    end, BITE_TIMEOUT)
    if bite == nil then
        return true
    end
    if not bitten() then
        lastSpot = nil
        return false, "No bite. Move closer to open water and retry", true
    end

    local existing = catchSnapshot()
    if instant then
        setStatus("Reeling...")
        if waitUntil(function()
            return Env.LocalPlayer:GetAttribute("FishingBite") == true
        end, 0.5) == nil then
            return true
        end
        if closeBiteUi() then
            setStatus("Reeling (the game makes you wait 4.5s)...")
            local dropped = waitUntil(function()
                return biteCancelled == true
            end, biteAt + REEL_DELAY - os.clock())
            if dropped == nil then
                return true
            end
            if dropped then
                return false, "The game reeled the line in before the fish was landed", true
            end
            -- Our catch only spawns after the verdict; anything from the wait is someone else's.
            myCatch, existing = nil, catchSnapshot()
            PortalEvent:FireServer("FishingRod", biteToken, true)
        elseif not getconnections then
            return false, "Your executor has no getconnections, which skipping the reel minigame needs"
        else
            -- The minigame could not be stopped safely: play it instead.
            instant = false
        end
    end
    if not instant then
        setStatus("Reeling...")
        local reeled, reelWhy = reel()
        -- The finished minigame's loop is leaked by the game and would run every frame from now on.
        if getconnections then
            pcall(disconnectMinigameLoops)
            Env.elevate()
        end
        if not reeled then
            return reelWhy == nil, reelWhy, true
        end
    end
    local verdictAt = os.clock()

    local collected, item = collectCatch(root, existing)
    logCatch(before, collected, item, biteMissed)
    if not collected then
        -- The server ignores a cast until it has reeled this one in.
        waitOn(verdictAt + UNCAST_TIME - os.clock())
    end
    return true
end

function activity.wants()
    return wanted()
end

local function disconnectAll()
    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end
    table.clear(connections)
end

function activity.start()
    strikes = 0
    disconnectAll()
    connections[#connections + 1] = PortalEvent.OnClientEvent:Connect(function(channel, kind, token)
        if channel ~= "FishingRod" then
            return
        end
        if kind == "Bite" then
            biteToken, biteAt = token, os.clock()
        elseif kind == "BiteMissed" then
            biteMissed = true
        elseif kind == "BiteCancel" and not closingUi then
            biteCancelled = true
        end
    end)
    connections[#connections + 1] = Debree.ChildAdded:Connect(function(child)
        if child:GetAttribute("CatchItem") ~= nil then
            if onOurLine(child) then
                myCatch = child
                return
            end
            -- A bigger catch model can replicate a moment before its line; look again briefly
            -- (the line moves off the rod tip 0.3s after the catch spawns).
            task.spawn(function()
                for _ = 1, 15 do
                    task.wait()
                    if not child.Parent then
                        return
                    end
                    if onOurLine(child) then
                        myCatch = child
                        return
                    end
                end
            end)
        elseif string.sub(child.Name, 1, 12) == "FishingLine_" and onOurLine(child) then
            myBobber = child
        end
    end)
end

function activity.step()
    local ok, fine, why, retry = pcall(fishOnce)
    Env.elevate()
    if ok and fine then
        strikes = 0
    else
        local reason = tostring(if ok then why else fine)
        -- A Lua error counts as retryable too: most come from the character dying mid-cast.
        if (retry or not ok) and strikes < MAX_STRIKES then
            strikes += 1
            setStatus(string.format("%s. Retrying (%d/%d)...", reason, strikes, MAX_STRIKES))
            activity.status = Fishing.status
            return 1
        end
        strikes = 0
        Ui.set("AutoFish", false)
        Fishing.lastError = reason
        setStatus(reason)
        Ui.notify("Auto Fishing", reason, 6)
    end
    activity.status = Fishing.status
    return 0.05
end

function activity.stop()
    disconnectAll()
    local equipped = Data.equipped()
    if equipped and fishingSlot and (equipped.Value == fishingSlot or equipped.Value == 0) then
        equipped.Value = 0
    end
    fishingSlot = nil
    setStatus(wanted() and "Paused - something more important is running" or "Stopped")
end

Scheduler.register(activity)

return Fishing
end
__modules["features/guide"] = function(use) -- src/games/slayers2/features/guide.luau
-- Guide tab: the fastest way to level, worked out from the game's own data and your character.
--
-- Nothing here moves you. Every row says what to do and where it is (compass heading and studs
-- from where you stand; north is -Z, as on the game's minimap).
--
-- Where the numbers come from:
--  * Level: slot.Exp.Goal / gameSettings.expPerLevel, and Exp.Current / Exp.Goal is the bar you are
--    on. Rewards are shown as a share of that bar, so no cost formula is needed.
--  * Multipliers.ExpGain(player, source) is (1 + Exp Factor [+ Quest Exp Factor for quests]) plus a
--    2x EXP window when one is running. Quests and boss hunts pay through "Quest", kills through
--    "NpcReward". Exp accessories are the one thing you can change.
--  * Quests: Quests.Holder[key].Rewards.Exp, .Requirements, .OfferNpc, and the task counts in
--    QuestInstance.Tasks.<task>.Max. The game does not say how long a step takes, so quests are
--    ranked by exp per task step.
--  * Boss hunts: BossHunts.Rewards(entry).Exp (tier x expPerLevel x hunt level) for the live hunts
--    on the board (features/boss).
--  * Mobs: a rig's NpcCode -> LiveConfig "NpcDataTable"[code].Rewards.Exp, over the rig's health.

local Env = use("core/env")
local Life = use("shared/life")
local Data = use("core/data")
local Ui = use("core/ui")
local Combat = use("core/combat")
local NpcData = use("core/npcdata")
local Where = use("core/where")
local Accessories = use("core/accessories")
local Boss = use("features/boss")

local QUEST_ROWS = 6
local HUNT_ROWS = 5
local MOB_ROWS = 5
local MIN_HUNT_TIME = 45 -- a hunt about to expire is not worth starting
local SLOW_EVERY = 6 -- seconds between the quest and hunt rankings (the mobs refresh every pass)
local CLAIM_WAIT = 3
local EXP_STATS = { ["Exp Factor"] = true, ["Quest Exp Factor"] = true }

-- Helpers ---------------------------------------------------------------------------------------

local function commas(number)
    local text = tostring(math.floor(number + 0.5))
    repeat
        local changed
        text, changed = text:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    until changed == 0
    return text
end

-- The labels are RichText.
local function escape(text)
    return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function clock(seconds)
    seconds = math.max(0, math.ceil(seconds))
    return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local heading = Where.text

local function spawnOf(name)
    local ok, position = Env.call(Env.Game.Regions.GetNpcSpawn, name)
    return ok and typeof(position) == "Vector3" and position or nil
end

-- Which region an NPC belongs to, from the region definitions (built once).
local npcRegion = nil
local function regionOf(name)
    if not npcRegion then
        npcRegion = {}
        local ok, regions = Env.call(function()
            return Env.Game.Regions.Regions
        end)
        for regionName, region in pairs(ok and type(regions) == "table" and regions or {}) do
            for _, npc in ipairs(type(region) == "table" and type(region.Npcs) == "table" and region.Npcs or {}) do
                if type(npc) == "table" and type(npc.Name) == "string" and npcRegion[npc.Name] == nil then
                    npcRegion[npc.Name] = regionName
                end
            end
        end
    end
    return npcRegion[name]
end

local function whereIs(npcName)
    local region = regionOf(npcName)
    return string.format("%s%s", region and (region .. ", ") or "", heading(spawnOf(npcName)))
end

-- Your bar and multipliers -----------------------------------------------------------------------

local function progress()
    local slot = Data.slot()
    local exp = slot and slot:FindFirstChild("Exp")
    local current, goal = exp and exp:FindFirstChild("Current"), exp and exp:FindFirstChild("Goal")
    if not (current and goal) or goal.Value <= 0 then
        return nil
    end
    return current.Value, goal.Value
end

-- The game's own reader waits for the window's data to exist, so it only runs when it does, on a
-- thread of its own that cannot hold the panels up.
local factors = { quest = 1, kill = 1 }
local reading = false
local function readFactors()
    if reading then
        return
    end
    local slot = Data.slot()
    local windows = slot and slot:FindFirstChild("Multipliers")
    if not (windows and windows:FindFirstChild("Exp2X")) then
        return
    end
    reading = true
    task.spawn(function()
        local questOk, quest = Env.call(Env.Game.Multipliers.ExpGain, Env.LocalPlayer, "Quest")
        local killOk, kill = Env.call(Env.Game.Multipliers.ExpGain, Env.LocalPlayer, "NpcReward")
        if questOk and type(quest) == "number" then
            factors.quest = quest
        end
        if killOk and type(kill) == "number" then
            factors.kill = kill
        end
        reading = false
    end)
end

-- The next boss hunts you do not have yet: their level and which they are.
local function nextHunts(level)
    local ok, text = Env.call(function()
        local race = Data.value("Race")
        local BossHunts = Env.Game.BossHunts
        local soonest, names = math.huge, {}
        for _, entry in ipairs(BossHunts.Hunts) do
            local side = BossHunts.Sides[entry.Side]
            if side and table.find(side.Race, race) and entry.MinLevel > level then
                if entry.MinLevel < soonest then
                    soonest, names = entry.MinLevel, {}
                end
                if entry.MinLevel == soonest then
                    names[#names + 1] = string.format("%s (%s)", BossHunts.Npc(entry), entry.Tier)
                end
            end
        end
        if soonest == math.huge then
            return "Every boss hunt for your race is open to you."
        end
        return string.format("More boss hunts open at Lv %d: %s.", soonest, table.concat(names, ", "))
    end)
    return ok and text or ""
end

-- Quests --------------------------------------------------------------------------------------------

local function steps(definition)
    local total = 0
    local ok = pcall(function()
        for _, child in ipairs(definition.QuestInstance.Tasks:GetChildren()) do
            local max = child:FindFirstChild("Max")
            total += max and tonumber(max.Value) or 1
        end
    end)
    return ok and math.max(total, 1) or 1
end

-- Whether this character can take the quest (another quest of its category in the way counts as
-- yes: it is finished first). CanAddQuest gives nil for unmet requirements, false + 1 for a quest
-- already taken and false + 2 for one done that is only ever done once.
local function takeable(key)
    local ok, allowed, code = Env.call(Env.Game.Quests.CanAddQuest, Env.LocalPlayer, key, true)
    return ok and (allowed == true or (allowed == false and code == false))
end

local function costsSomething(definition)
    local items = definition.ItemCostOnAccept
    return (type(items) == "table" and next(items) ~= nil) or (tonumber(definition.WenCostOnAccept) or 0) > 0
end

-- Quests worth taking now, best exp per task step first. Ones that swap your power, or charge Wen
-- or items to accept, are left out.
local function rankQuests()
    local rows = {}
    for key, definition in pairs(Env.Game.Quests.Holder) do
        local rewards = type(definition) == "table" and definition.Rewards or nil
        local exp = type(rewards) == "table" and tonumber(rewards.Exp) or 0
        if exp > 0 and type(definition.OfferNpc) == "string" and definition.Category ~= "BossHunt"
            and rewards.Power == nil and not costsSomething(definition) and takeable(key) then
            local count = steps(definition)
            local gain = exp * factors.quest
            local ok, name = pcall(function()
                return definition.QuestInstance.Name
            end)
            rows[#rows + 1] = {
                name = ok and name or tostring(key),
                npc = definition.OfferNpc,
                gain = gain,
                steps = count,
                perStep = gain / count,
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.perStep ~= b.perStep then
            return a.perStep > b.perStep
        end
        return a.gain > b.gain
    end)
    return rows
end

-- Boss hunts -----------------------------------------------------------------------------------------

-- Live hunts you can be paid for, biggest exp first.
local function rankHunts()
    local rows, others = {}, 0
    local now = os.time()
    for _, hunt in ipairs(Boss.hunts()) do
        if hunt.expires > now and Boss.mine(hunt) then
            local ok, rewards = Env.call(function()
                return Env.Game.BossHunts.Rewards(Env.Game.BossHunts.Entry(hunt.name))
            end)
            local exp = ok and type(rewards) == "table" and tonumber(rewards.Exp) or 0
            rows[#rows + 1] = { hunt = hunt, gain = exp * factors.quest }
        elseif hunt.expires > now then
            others += 1
        end
    end
    table.sort(rows, function(a, b)
        return a.gain > b.gain
    end)
    return rows, others
end

-- Breathing and style trials ---------------------------------------------------------------------------

-- The trainers' quests: they give a power (a breathing or a style) and their tasks go in order, each
-- one naming the task before it in Need. Learning one replaces the power you have. Where a task is
-- comes from Quests.GetTaskMarker: the quest's own marker (a trainee's spawn), or the training
-- ground (gameSettings.TrainingMarkerPositions) named by the task's Code.
local TRIAL_ROWS = 3

local function powerName(power)
    return type(power) == "table" and power.Name or power
end

local function powerHeld(name)
    if not name then
        return true
    end
    local slot = Data.slot()
    local powers = slot and slot:FindFirstChild("Powers")
    for _, value in ipairs(powers and powers:GetChildren() or {}) do
        if value:IsA("ValueBase") and value.Value == name then
            return true
        end
    end
    return false
end

local function taskOrder(definition)
    local pending = {}
    local ok = pcall(function()
        for _, child in ipairs(definition.QuestInstance.Tasks:GetChildren()) do
            local need = child:FindFirstChild("Need")
            pending[#pending + 1] = { instance = child, name = child.Name, need = (need and need.Value ~= "") and need.Value or nil }
        end
    end)
    local ordered, placed = {}, {}
    if not ok then
        return ordered
    end
    while #ordered < #pending do
        local before = #ordered
        for _, entry in ipairs(pending) do
            if not placed[entry.name] and (entry.need == nil or placed[entry.need]) then
                ordered[#ordered + 1] = entry
                placed[entry.name] = true
            end
        end
        if #ordered == before then -- a Need that names nothing: take the rest as they come
            for _, entry in ipairs(pending) do
                if not placed[entry.name] then
                    ordered[#ordered + 1] = entry
                    placed[entry.name] = true
                end
            end
        end
    end
    return ordered
end

-- The tasks folder of the quest as you are doing it, or nil.
local function activeTasks(definition)
    local slot = Data.slot()
    local holder = slot and slot:FindFirstChild("Quests") and slot.Quests:FindFirstChild("Holder")
    local ok, name = pcall(function()
        return definition.QuestInstance.Name
    end)
    local quest = ok and holder and holder:FindFirstChild(name)
    return quest and quest:FindFirstChild("Tasks")
end

-- Trials you can start (or are in the middle of) for a power you do not have, the lowest level first.
local function rankTrials()
    local rows = {}
    local Quests = Env.Game.Quests
    for key, definition in pairs(Quests.Holder) do
        local rewards = type(definition) == "table" and definition.Rewards or nil
        if type(rewards) == "table" and rewards.Power ~= nil and definition.Category == "Combat"
            and type(definition.OfferNpc) == "string" and not powerHeld(powerName(rewards.Power)) then
            local okState, state = Env.call(Quests.GetPlayerQuestState, Env.LocalPlayer, key)
            local active = okState and state == "Doing"
            if active or takeable(key) then
                local tasks = active and activeTasks(definition) or nil
                local steps = {}
                for index, entry in ipairs(taskOrder(definition)) do
                    local done = false
                    local progress = tasks and tasks:FindFirstChild(entry.name)
                    local value, max = progress and progress:FindFirstChild("Value"), progress and progress:FindFirstChild("Max")
                    if value and max then
                        done = value.Value >= max.Value
                    end
                    local okMarker, marker = Env.call(Quests.GetTaskMarker, definition, entry.instance)
                    steps[#steps + 1] = {
                        index = index,
                        name = entry.name,
                        done = done,
                        position = okMarker and type(marker) == "table" and typeof(marker.Position) == "Vector3" and marker.Position or nil,
                    }
                end
                local costs, missing = {}, {}
                local wen = tonumber(definition.WenCostOnAccept) or 0
                if wen > 0 then
                    costs[#costs + 1] = "$" .. commas(wen)
                    if Data.wen() < wen then
                        missing[#missing + 1] = "$" .. commas(wen - Data.wen())
                    end
                end
                local items = type(definition.ItemCostOnAccept) == "table" and definition.ItemCostOnAccept or {}
                local names = {}
                for item in pairs(items) do
                    names[#names + 1] = item
                end
                table.sort(names)
                for _, item in ipairs(names) do
                    costs[#costs + 1] = string.format("%s %s", tostring(items[item]), item)
                    local short = (tonumber(items[item]) or 0) - Data.itemCount(item)
                    if short > 0 then
                        missing[#missing + 1] = string.format("%d %s", short, item)
                    end
                end
                local ok, name = pcall(function()
                    return definition.QuestInstance.Name
                end)
                rows[#rows + 1] = {
                    name = ok and name or tostring(key),
                    level = type(definition.Requirements) == "table" and tonumber(definition.Requirements.Level) or 0,
                    power = tostring(powerName(rewards.Power)),
                    gain = (tonumber(rewards.Exp) or 0) * factors.quest,
                    trainer = definition.OfferNpc,
                    active = active,
                    steps = steps,
                    costs = costs,
                    missing = missing,
                }
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.active ~= b.active then
            return a.active
        end
        if a.level ~= b.level then
            return a.level < b.level
        end
        return a.name < b.name
    end)
    return rows
end

-- Mobs near you ------------------------------------------------------------------------------------------

-- Loaded mobs by exp per point of health (the fastest kills for the exp), one row per kind.
local function rankMobs()
    local root = Data.character()
    if not root then
        return {}
    end
    local kinds = {}
    for _, rig in ipairs(Combat.rigs()) do
        local humanoid = rig:FindFirstChildOfClass("Humanoid")
        if rig:GetAttribute("IsMob") == true and humanoid and humanoid.MaxHealth > 0 then
            local exp = NpcData.exp(rig)
            if exp > 0 then
                local base = rig:GetAttribute("BaseMaxHealth")
                local health = (type(base) == "number" and base > 0) and math.min(base, humanoid.MaxHealth) or humanoid.MaxHealth
                local position = rig.HumanoidRootPart.Position
                local distance = (position - root.Position).Magnitude
                local row = kinds[rig.Name]
                if not row or distance < row.distance then
                    kinds[rig.Name] = {
                        name = rig.Name,
                        gain = exp * factors.kill,
                        health = health,
                        efficiency = exp / health,
                        distance = distance,
                        position = position,
                    }
                end
            end
        end
    end
    local rows = {}
    for _, row in pairs(kinds) do
        rows[#rows + 1] = row
    end
    table.sort(rows, function(a, b)
        return a.efficiency > b.efficiency
    end)
    return rows
end

-- UI ----------------------------------------------------------------------------------------------------------

local tab = Ui.Tabs.Guide
local levelBox = tab:AddGroupbox({ Side = "Left", Name = "Your level", IconName = "trending-up" })
local huntBox = tab:AddGroupbox({ Side = "Left", Name = "Boss hunts for you", IconName = "skull" })
local trialBox = tab:AddGroupbox({ Side = "Left", Name = "Breathing trials", IconName = "wind" })
local questBox = tab:AddGroupbox({ Side = "Right", Name = "Best quests right now", IconName = "scroll-text" })
local mobBox = tab:AddGroupbox({ Side = "Right", Name = "Best mobs near you", IconName = "crosshair" })

local levelLabel = levelBox:AddLabel("Loading...", true)
local boostLabel = levelBox:AddLabel("", true)
local unlockLabel = levelBox:AddLabel("", true)
local gearLabel = levelBox:AddLabel("", true)
gearLabel:SetVisible(false)

local wearing = false
levelBox:AddButton({
    Text = "Wear EXP accessories",
    Tooltip = "Puts the accessories with the most Exp Factor and Quest Exp Factor in your five stat slots, replacing what is there. Use the Home tab's Equip best accessories to switch back.",
    Func = function()
        if wearing then
            return
        end
        wearing = true
        task.spawn(function()
            local ok, result = xpcall(Accessories.equipBest, debug.traceback, EXP_STATS)
            Env.elevate()
            wearing = false
            if not Life.alive then
                return
            end
            local text
            if not ok then
                text = "Could not equip: " .. (string.match(tostring(result), "^[^\n]+") or "unknown error")
            elseif result.error then
                text = result.error
            elseif #result.set == 0 then
                text = "None of your accessories give EXP."
            elseif #result.equipped == 0 then
                text = "Already wearing your best EXP set."
            else
                local names = {}
                for _, piece in ipairs(result.equipped) do
                    names[#names + 1] = piece.name
                end
                text = "Equipped " .. table.concat(names, ", ") .. "."
            end
            gearLabel:SetText(text)
            gearLabel:SetVisible(true)
            Ui.notify("Guide", text, 6)
        end)
    end,
})
levelBox:AddLabel("Fastest route: wear EXP gear, claim the biggest boss hunt you can and kill it, chain the quests below "
    .. "between hunts, and kill the best exp-per-health mob near you when nothing else is up.", true)

local claimable = nil -- the best hunt as of the last ranking
local claiming = false
huntBox:AddButton({
    Text = "Claim the best hunt",
    Tooltip = "Takes the biggest hunt you can be paid for, without a trip to the board. One hunt at a time; then go and kill the boss.",
    Func = function()
        if claiming then
            return
        end
        local held = Boss.claimedBoss()
        if held then
            Ui.notify("Guide", "You already hold a hunt: " .. held, 4)
            return
        end
        local hunt = claimable
        if not hunt then
            Ui.notify("Guide", "No hunt you can be paid for right now.", 4)
            return
        end
        claiming = true
        task.spawn(function()
            local ok, allowed = Env.call(Env.Game.Quests.CanAddQuest, hunt.quest)
            if ok and allowed then
                Env.Game.SignalEvent.ToServer("BossHuntsRequest", { action = "Claim", id = hunt.id })
                local deadline = os.clock() + CLAIM_WAIT
                repeat
                    task.wait(0.2)
                until Boss.claimedBoss() == hunt.name or os.clock() >= deadline or not Life.alive
                Env.elevate()
            end
            claiming = false
            if not Life.alive then
                return
            end
            if Boss.claimedBoss() == hunt.name then
                Ui.notify("Guide", "Claimed the hunt: " .. hunt.name, 5)
            else
                Ui.notify("Guide", "The game would not hand over " .. hunt.name .. " right now (cooldown or another hunt).", 5)
            end
        end)
    end,
})
local huntPanel = Ui.panel(huntBox, HUNT_ROWS)
local trialPanel = Ui.panel(trialBox, TRIAL_ROWS)
local questPanel = Ui.panel(questBox, QUEST_ROWS)
local mobPanel = Ui.panel(mobBox, MOB_ROWS)

-- Workers ------------------------------------------------------------------------------------------------------

local huntRows, otherHunts, questRows, trialRows = {}, 0, {}, {}
local slowAt = -math.huge

local function share(gain, goal)
    return goal and gain / goal * 100 or 0
end

Life.loop("guide:panels", 2, function()
    readFactors()
    local current, goal = progress()
    local level = Data.level()
    local race = Data.value("Race")

    if os.clock() - slowAt >= SLOW_EVERY then
        slowAt = os.clock()
        huntRows, otherHunts = rankHunts()
        claimable = huntRows[1] and huntRows[1].hunt.expires - os.time() >= MIN_HUNT_TIME and huntRows[1].hunt or nil
        questRows = rankQuests()
        trialRows = rankTrials()
        unlockLabel:SetText(nextHunts(level))
    end

    levelLabel:SetText(current and string.format("Level %d (%s)\nExp %s / %s (%d%%)", level, tostring(race), commas(current),
        commas(goal), math.floor(current / goal * 100)) or "Waiting for your save data...")
    boostLabel:SetText(string.format("Exp multiplier: kills x%.2f, quests and hunts x%.2f", factors.kill, factors.quest))

    local lines = {}
    for index = 1, math.min(#huntRows, HUNT_ROWS) do
        local row = huntRows[index]
        lines[index] = string.format("%s  [%s]  +%s exp (%.1f%% of your level)  %s left\n    %s", escape(row.hunt.name),
            escape(row.hunt.tier), commas(row.gain), share(row.gain, goal), clock(row.hunt.expires - os.time()),
            escape(whereIs(row.hunt.name)))
    end
    huntPanel.set(lines, #huntRows == 0 and "No hunt on the board is one you can be paid for."
        or string.format("Biggest first.%s", otherHunts > 0 and string.format(" %d more are not for your race or level.", otherHunts) or ""))

    lines = {}
    for index = 1, math.min(#trialRows, TRIAL_ROWS) do
        local row = trialRows[index]
        local steps = {}
        for _, step in ipairs(row.steps) do
            steps[#steps + 1] = string.format("%s %d. %s: %s", step.done and "[x]" or "[ ]", step.index, escape(step.name),
                step.done and "done" or escape(heading(step.position)))
        end
        lines[index] = string.format("%s  Lv%d  gives %s  +%s exp%s\n    Trainer: %s (%s)\n    Costs: %s%s\n    %s", escape(row.name), row.level,
            escape(row.power), commas(row.gain), row.active and "  (in progress)" or "", escape(row.trainer), escape(whereIs(row.trainer)),
            #row.costs > 0 and escape(table.concat(row.costs, ", ")) or "nothing",
            #row.missing > 0 and ("  (you lack " .. escape(table.concat(row.missing, ", ")) .. ")") or "",
            table.concat(steps, "\n    "))
    end
    trialPanel.set(lines, #trialRows == 0 and "No breathing trial for a power you do not have is open to you right now."
        or "Do the tasks in order. Learning one replaces the breathing or style you have now.")

    lines = {}
    for index = 1, math.min(#questRows, QUEST_ROWS) do
        local row = questRows[index]
        lines[index] = string.format("%s  +%s exp (%.1f%% of your level)  %d step(s)\n    %s: %s", escape(row.name),
            commas(row.gain), share(row.gain, goal), row.steps, escape(row.npc), escape(whereIs(row.npc)))
    end
    questPanel.set(lines, #questRows == 0 and "No quest you can take right now pays exp."
        or "Best exp per task step first. Quests that cost Wen or items, or swap your power, are left out.")

    local mobs = rankMobs()
    lines = {}
    for index = 1, math.min(#mobs, MOB_ROWS) do
        local row = mobs[index]
        lines[index] = string.format("%s  +%s exp (%.2f%% of your level)  %s health\n    %s", escape(row.name),
            commas(row.gain), share(row.gain, goal), commas(row.health), escape(heading(row.position)))
    end
    local footer = "Loaded mobs only, most exp per health first."
    if mobs[1] and current and mobs[1].gain > 0 then
        footer = string.format("About %s kills of %s to your next level. %s", commas(math.ceil((goal - current) / mobs[1].gain)),
            escape(mobs[1].name), footer)
    end
    mobPanel.set(lines, #mobs == 0 and "No loaded mob has exp data yet. Walk toward some." or footer)
end)

return {}
end
__modules["features/heal"] = function(use) -- src/games/slayers2/features/heal.luau
-- Auto heal: drinks a hotbar potion when health falls under the threshold.
--
-- Verified flow: equip the potion slot (through 0), SignalEvent "Tool_Mouse" Down, wait ~2.1s
-- (the server drinks over ~1.85s and an early Up cancels it), then Up. Health Potion is a flat
-- +25 HP, Health Elixir +60. Success shows as the inventory amount going down.

local Env = use("core/env")
local Data = use("core/data")
local Ui = use("core/ui")
local Scheduler = use("core/scheduler")

local Options = Ui.Options
local DRINK_TIME = 2.1
local FAIL_BACKOFF = 5

local group = Ui.Tabs.Farm:AddGroupbox({ Side = "Right", Name = "Auto heal", IconName = "heart-pulse" })

local function potions()
    return Data.hotbar(function(name, definition)
        return definition.Category == "Potions" and string.find(name, "Health", 1, true) ~= nil
    end)
end

local names = potions()
group:AddToggle("AutoHeal", {
    Text = "Auto heal",
    Default = false,
    Tooltip = "Drinks a potion from your hotbar when health drops below the threshold, pausing whatever else is running.",
})
group:AddSlider("HealThreshold", {
    Text = "Heal below",
    Default = 45,
    Min = 10,
    Max = 95,
    Rounding = 0,
    Suffix = "%",
})
group:AddDropdown("HealPotion", {
    Searchable = true,
    Text = "Potion on hotbar",
    Values = names,
    Default = names[1] or "",
    Multi = false,
})
group:AddButton({ Text = "Refresh potions", Func = function()
    local list = potions()
    Options.HealPotion:SetValues(list)
    if not table.find(list, Options.HealPotion.Value) then
        Options.HealPotion:SetValue(list[1])
    end
    Ui.notify("Auto Heal", string.format("%d health potion(s) on the hotbar", #list), 3)
end })
group:AddLabel("Put a Health Potion or Elixir on your hotbar.", true)
Ui.automation("AutoHeal", true)

local failedUntil = 0

local activity = { name = "Auto heal", priority = Scheduler.PRIORITY.heal, label = "Healing", status = "Idle" }

function activity.wants()
    if not Ui.on("AutoHeal") or os.clock() < failedUntil then
        return false
    end
    local _, humanoid = Data.character()
    if not humanoid or humanoid.Health <= 0 or humanoid.MaxHealth <= 0 then
        return false
    end
    return humanoid.Health / humanoid.MaxHealth * 100 <= Options.HealThreshold.Value
        and Data.itemCount(Options.HealPotion.Value) > 0
end

function activity.step()
    local name = Options.HealPotion.Value
    local _, indexByName = potions()
    local index = indexByName[name]
    local root = Data.character()
    if not index or not root then
        activity.status = string.format("%s is not on your hotbar", tostring(name))
        Ui.notify("Auto Heal", activity.status, 5)
        failedUntil = os.clock() + FAIL_BACKOFF
        return 0.1
    end
    local before = Data.itemCount(name)
    activity.status = "Drinking " .. name
    if Data.equip(index, 2) then
        Env.Game.SignalEvent.ToServer("Tool_Mouse", "Down", root.Position)
        task.wait(DRINK_TIME)
        Env.Game.SignalEvent.ToServer("Tool_Mouse", "Up", root.Position)
        local deadline = os.clock() + 1
        repeat
            task.wait(0.1)
        until Data.itemCount(name) < before or os.clock() >= deadline
    end
    Data.equip(0)
    Env.elevate()
    if Data.itemCount(name) >= before then
        activity.status = "The game refused the potion"
        failedUntil = os.clock() + FAIL_BACKOFF
    end
    return 0.1
end

function activity.stop()
    activity.status = "Idle"
end

Scheduler.register(activity)

return {}
end
__modules["features/home"] = function(use) -- src/games/slayers2/features/home.luau
-- Home tab: the shared welcome box (shared/home), what the hub is doing right now, character
-- stats and codes.

local Env = use("core/env")
local Life = use("shared/life")
local Data = use("core/data")
local Ui = use("core/ui")
local Scheduler = use("core/scheduler")
local Home = use("shared/home")

local REDEEM_INTERVAL = 0.75

local tab = Ui.Tabs.Home

-- First box on the tab, so it is the first thing anyone sees. Labels are RichText.
local notice = tab:AddGroupbox({ Side = "Left", Name = "Important", IconName = "megaphone" })
notice:AddLabel(
    '<font color="#eb4060"><b>Slayers 2 is now a utility script</b></font>\n'
        .. 'Slayers 2 added an <font color="#ffb454"><b>anti-cheat</b></font> that catches teleporting, so the autofarms '
        .. "and teleports are gone. What is left does not move you: guides, timers, fishing and other helpers.\n"
        .. 'Got an idea? <font color="#7f8cff"><b>Join the Discord</b></font> and post it (Copy Discord invite is right below).',
    true
)

local _, statusLabel = Home.build(Env.inMenu and {
    "You are in the main menu: only Home and Clan work here. Join a server for everything else.",
} or nil)
local character = tab:AddGroupbox({ Side = "Right", Name = "Character", IconName = "user" })
local codes = tab:AddGroupbox({ Side = "Right", Name = "Codes", IconName = "gift" })

-- Character stats and the scheduler's current activity.
local stats = character:AddLabel("Loading...", true)
Life.loop("home:stats", 1, function()
    local slot = Data.slot()
    if not slot then
        return
    end
    local clan = slot:FindFirstChild("Clan") and slot.Clan.Value or "None"
    local ok, tier = Env.call(Env.Game.Clans.TierOf, clan)
    local current = Scheduler.current
    local doing = current and string.format("%s - %s", current.label or current.name, tostring(current.status or "")) or "Idle"
    statusLabel:SetText("Doing: " .. doing)
    stats:SetText(string.format("Level %d  |  %s\nClan: %s (%s)\nWen: %s\nReputation: %s\nSkill points: %s",
        Data.level(), tostring(Data.value("Race")), clan, ok and tier and tier.name or "?",
        tostring(Data.wen()), tostring(Data.value("Reputation")), tostring(Data.value("SkillPoints"))))
end)

-- Codes: the game publishes its live code list (SignalFunction "CodeStatus" -> { codes = {
-- [CODE] = { redeemed, requirements = { { label, met, fake } } } } }) and "RedeemCode"(code)
-- claims one. Rewards are decided on the server and described nowhere on the client, and some
-- codes reset progress (SKILLTREERESET, BREATHRESET, ARTRESET, POINTSRESET), so only codes named
-- for spins or rerolls are ever redeemed. Anything else is left to type in by hand.
local function codeKind(code)
    local upper = string.upper(code)
    if string.find(upper, "RESET", 1, true) or string.find(upper, "WIPE", 1, true) then
        return "reset"
    end
    if string.find(upper, "SPIN", 1, true) or string.find(upper, "ROLL", 1, true) then
        return "spins"
    end
    return "other"
end

-- The first requirement the server can check that is not met ("fake" ones, like liking the
-- game, cannot be checked and always pass).
local function unmetRequirement(info)
    for _, requirement in ipairs(type(info.requirements) == "table" and info.requirements or {}) do
        if requirement.met == false and not requirement.fake then
            return requirement.label or "a requirement"
        end
    end
    return nil
end

local codeList = codes:AddLabel("Loading codes...", true)

local function redeemSpinCodes()
    local ok, status = Env.call(Env.Game.SignalFunction.ToServer, "CodeStatus")
    if not ok or type(status) ~= "table" or type(status.codes) ~= "table" then
        codeList:SetText("Could not load the code list.")
        return
    end
    local lines, redeemed = {}, 0
    for code, info in pairs(status.codes) do
        local kind, line = codeKind(code), nil
        if info.redeemed then
            line = "redeemed"
        elseif kind == "reset" then
            line = "skipped - resets progress"
        elseif kind ~= "spins" then
            line = "skipped - not a spin code"
        elseif unmetRequirement(info) then
            line = "needs: " .. unmetRequirement(info)
        else
            local sent, result = Env.call(Env.Game.SignalFunction.ToServer, "RedeemCode", code)
            if sent and result then
                redeemed += 1
                line = "redeemed now"
            else
                line = "refused by the game"
            end
            if not Life.wait(REDEEM_INTERVAL) then
                return
            end
        end
        lines[#lines + 1] = string.format("%s: %s", code, line)
    end
    table.sort(lines)
    Env.elevate()
    codeList:SetText(#lines > 0 and table.concat(lines, "\n") or "No codes right now.")
    if redeemed > 0 then
        Ui.notify("Codes", string.format("Redeemed %d spin code(s)", redeemed), 5)
    end
end

codes:AddButton({ Text = "Redeem spin codes", Func = function()
    task.spawn(redeemSpinCodes)
end })
codes:AddLabel("Spin and reroll codes are redeemed when the hub loads. Reset codes (skill tree, breathing, demon art, points) are never touched.", true)
task.spawn(redeemSpinCodes)

return {}
end
__modules["features/locator"] = function(use) -- src/games/slayers2/features/locator.luau
-- Locator tab: pick an NPC, shop, mob, boss, shrine, town or training spot and a marker on your
-- screen points at it, with its heading and distance, until you get there. Nothing moves you and
-- nothing is put in the world: the marker is a label in its own ScreenGui, placed each frame where
-- the target projects on screen (at the screen edge, pointing the way, when it is off screen or behind
-- you).
--
-- Where things are (read from the game, so they follow updates):
--  * Regions.Regions[region].Npcs: stationary and idle NPCs have Spawns (points, or routes of
--    points); active ones (mobs, bosses) have SendOver.Spawning.Locations / Center, and SendOver.Boss
--    marks a boss. The Black Marketer moves between spots on a timer, so the Market tab has him.
--  * Regions.Regions[region].CrystalAt (a town's spawn crystal), .Shrines ({ Name, At }) and the
--    crystals of its child areas.
--  * gameSettings.TrainingMarkerPositions[PlaceId]: the training grounds, and .UnderwaterRockSpots.
-- An NPC that is streamed in is followed live (idle ones walk); otherwise the nearest known spawn.

local Env = use("core/env")
local Life = use("shared/life")
local Data = use("core/data")
local Ui = use("core/ui")
local Npcs = use("core/npcs")
local Where = use("core/where")

local Options = Ui.Options

local MARGIN = 48 -- pixels kept between the marker and the screen edge
local ARRIVED = 12 -- studs along the ground, and this many up or down
local CATEGORIES = { "NPCs and shops", "Mobs and bosses", "Shrines and towns", "Training spots" }

-- Data ----------------------------------------------------------------------------------------------

-- Every point in a Vector3, a CFrame or a (nested) list of them.
local function flatten(value, into)
    into = into or {}
    if typeof(value) == "CFrame" then
        into[#into + 1] = value.Position
    elseif typeof(value) == "Vector3" then
        into[#into + 1] = value
    elseif type(value) == "table" then
        for _, item in ipairs(value) do
            flatten(item, into)
        end
    end
    return into
end

local function eachRegion(fn)
    local ok, regions = Env.call(function()
        return Env.Game.Regions.Regions
    end)
    if not (ok and type(regions) == "table") then
        return
    end
    for regionName, region in pairs(regions) do
        if type(region) == "table" then
            fn(regionName, region)
        end
    end
end

local function eachNpc(fn)
    eachRegion(function(regionName, region)
        for _, npc in ipairs(type(region.Npcs) == "table" and region.Npcs or {}) do
            if type(npc) == "table" and type(npc.Name) == "string" then
                fn(regionName, npc)
            end
        end
    end)
end

-- label -> { name, positions = { Vector3 }, live = follow the streamed-in model }
local BUILD = {}

BUILD["NPCs and shops"] = function()
    local list = {}
    local kinds = Env.Game.Menum.npcType
    eachNpc(function(regionName, npc)
        if (npc.Type == kinds.Stationary or npc.Type == kinds.Idle) and npc.TimedVendor == nil then
            local positions = flatten(npc.Spawns)
            if #positions > 0 then
                local shop = (npc.Shop ~= nil or npc.RotatingShop ~= nil) and "  [shop]" or ""
                list[string.format("%s (%s)%s", npc.Name, regionName, shop)] = { name = npc.Name, positions = positions, live = true }
            end
        end
    end)
    return list
end

BUILD["Mobs and bosses"] = function()
    local list = {}
    local kinds = Env.Game.Menum.npcType
    eachNpc(function(regionName, npc)
        local spawning = type(npc.SendOver) == "table" and npc.SendOver.Spawning
        if npc.Type == kinds.Active and type(spawning) == "table" then
            local positions = flatten(spawning.Locations)
            if #positions == 0 then
                positions = flatten(spawning.Center)
            end
            if #positions > 0 then
                local boss = npc.SendOver.Boss ~= nil and "  [boss]" or ""
                list[string.format("%s (%s)%s", npc.Name, regionName, boss)] = { name = npc.Name, positions = positions }
            end
        end
    end)
    return list
end

BUILD["Shrines and towns"] = function()
    local list = {}
    local function town(name, crystal, spawns)
        local positions = flatten(crystal)
        if #positions == 0 then
            positions = flatten(spawns and spawns[1])
        end
        if #positions > 0 then
            list["Town: " .. name] = { name = name, positions = positions }
        end
    end
    eachRegion(function(regionName, region)
        if regionName == "Misc" then
            return
        end
        town(regionName, region.CrystalAt, region.Spawns)
        for _, shrine in ipairs(type(region.Shrines) == "table" and region.Shrines or {}) do
            local positions = type(shrine) == "table" and flatten(shrine.At) or {}
            if #positions > 0 then
                local name = tostring(shrine.Name or regionName)
                list["Shrine: " .. name] = { name = name, positions = positions }
            end
        end
        for _, cell in ipairs(type(region.Area) == "table" and type(region.Area.Grid) == "table" and region.Area.Grid or {}) do
            for childName, child in pairs(type(cell) == "table" and type(cell.ChildAreas) == "table" and cell.ChildAreas or {}) do
                if type(child) == "table" and child.CrystalAt ~= nil then
                    town(tostring(childName), child.CrystalAt, nil)
                end
            end
        end
    end)
    return list
end

BUILD["Training spots"] = function()
    local list = {}
    local ok, markers = Env.call(function()
        local all = Env.Game.gameSettings.TrainingMarkerPositions
        return all[game.PlaceId] or all.Default
    end)
    for name, marker in pairs(ok and type(markers) == "table" and markers or {}) do
        if type(marker) == "table" and typeof(marker.Position) == "Vector3" then
            list[tostring(name)] = { name = tostring(name), positions = { marker.Position } }
        end
    end
    local rocksOk, rocks = Env.call(function()
        return Env.Game.gameSettings.UnderwaterRockSpots[game.PlaceId]
    end)
    for index, spot in ipairs(rocksOk and type(rocks) == "table" and rocks or {}) do
        if typeof(spot) == "Vector3" then
            local name = "Underwater rock spot " .. index
            list[name] = { name = name, positions = { spot } }
        end
    end
    return list
end

local entries = {}

local function sortedLabels(list)
    local labels = {}
    for label in pairs(list) do
        labels[#labels + 1] = label
    end
    table.sort(labels)
    return labels
end

-- The marker ------------------------------------------------------------------------------------------

local target = nil -- { label, entry }
local targetPosition = nil

local function escape(text)
    return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function guiParent()
    local ok, parent = pcall(function()
        return (gethui and gethui()) or game:GetService("CoreGui")
    end)
    if ok and parent then
        return parent
    end
    return Env.LocalPlayer:WaitForChild("PlayerGui")
end

local screen = Instance.new("ScreenGui")
screen.Name = "SlopixLocator"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.DisplayOrder = 20
screen.Enabled = false
screen.Parent = guiParent()
Life.onCleanup(function()
    screen:Destroy()
end)

local marker = Instance.new("TextLabel")
marker.AnchorPoint = Vector2.new(0.5, 0.5)
marker.AutomaticSize = Enum.AutomaticSize.XY
marker.Size = UDim2.fromOffset(0, 0)
marker.BackgroundColor3 = Color3.fromRGB(13, 12, 18)
marker.BackgroundTransparency = 0.25
marker.BorderSizePixel = 0
marker.Font = Enum.Font.GothamBold
marker.RichText = true
marker.TextSize = 15
marker.TextColor3 = Color3.fromRGB(240, 238, 246)
marker.Text = ""
marker.Parent = screen
do
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = marker
    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(235, 64, 96)
    stroke.Thickness = 1.5
    stroke.Parent = marker
    local padding = Instance.new("UIPadding")
    padding.PaddingLeft, padding.PaddingRight = UDim.new(0, 8), UDim.new(0, 8)
    padding.PaddingTop, padding.PaddingBottom = UDim.new(0, 4), UDim.new(0, 4)
    padding.Parent = marker
end

local statusLabel

local function stop(message)
    target, targetPosition = nil, nil
    screen.Enabled = false
    if statusLabel then
        statusLabel:SetText(message or "Not tracking anything.")
    end
end

-- Where the target is now: the live model for an NPC that is streamed in, else the nearest known spot.
local function locate()
    if not target then
        return
    end
    local entry = target.entry
    if entry.live then
        local model = Npcs.model(entry.name)
        if model then
            local ok, pivot = pcall(model.GetPivot, model)
            if ok then
                targetPosition = pivot.Position
                return
            end
        end
    end
    local root = Data.character()
    local best, bestDistance = entry.positions[1], math.huge
    if root then
        for _, position in ipairs(entry.positions) do
            local distance = (position - root.Position).Magnitude
            if distance < bestDistance then
                best, bestDistance = position, distance
            end
        end
    end
    targetPosition = best
end

local function place()
    local camera = workspace.CurrentCamera
    if not (target and targetPosition and camera) then
        screen.Enabled = false
        return
    end
    screen.Enabled = true
    marker.Text = string.format('<font color="#eb4060">%s</font>\n%s', escape(target.label), escape(Where.text(targetPosition)))
    local viewport = camera.ViewportSize
    local projected, onScreen = camera:WorldToViewportPoint(targetPosition)
    if onScreen then
        marker.Position = UDim2.fromOffset(projected.X, math.max(projected.Y - 28, MARGIN))
        return
    end
    -- Off screen (or behind the camera, where the projection is mirrored): stick to the edge, in its direction.
    local center = viewport / 2
    local offset = Vector2.new(projected.X, projected.Y) - center
    if projected.Z < 0 then
        offset = -offset
    end
    if offset.Magnitude < 1 then
        offset = Vector2.new(0, -1)
    end
    local scale = math.min((center.X - MARGIN) / math.max(math.abs(offset.X), 1e-3), (center.Y - MARGIN) / math.max(math.abs(offset.Y), 1e-3))
    local at = center + offset * scale
    marker.Position = UDim2.fromOffset(at.X, at.Y)
end

Life.connect(Env.RunService.RenderStepped, place)

Life.loop("locator:follow", 0.5, function()
    if not target then
        return
    end
    locate()
    local root = Data.character()
    if root and targetPosition then
        local flat = Where.flat(targetPosition)
        if flat and flat <= ARRIVED and math.abs(targetPosition.Y - root.Position.Y) <= ARRIVED + 8 then
            local name = target.label
            stop("You are at " .. name .. ".")
            Ui.notify("Locator", "You are at " .. name, 4)
        end
    end
end)

-- UI ----------------------------------------------------------------------------------------------------------

local tab = Ui.Tabs.Locator
local box = tab:AddGroupbox({ Side = "Left", Name = "Find something", IconName = "map-pin" })

local function refreshTargets()
    local builder = BUILD[Options.LocatorCategory.Value]
    local ok, list = pcall(builder or function()
        return {}
    end)
    Env.elevate()
    entries = ok and list or {}
    local labels = sortedLabels(entries)
    Options.LocatorTarget:SetValues(labels)
    if labels[1] then
        Options.LocatorTarget:SetValue(labels[1])
    end
end

box:AddDropdown("LocatorCategory", {
    Text = "Category",
    Values = CATEGORIES,
    Default = CATEGORIES[1],
    Multi = false,
    Callback = function()
        if Options.LocatorTarget then
            refreshTargets()
        end
    end,
})
box:AddDropdown("LocatorTarget", {
    Searchable = true,
    Text = "Target",
    Values = {},
    Default = "",
    Multi = false,
    Tooltip = "Shops are marked [shop] and bosses [boss]. A mob shows the nearest place it spawns.",
})
box:AddButton({ Text = "Track it", Func = function()
    local label = Options.LocatorTarget.Value
    local entry = entries[label]
    if not entry then
        Ui.notify("Locator", "Pick something to find first.", 3)
        return
    end
    target = { label = label, entry = entry }
    locate()
    statusLabel:SetText("Tracking " .. label)
    place()
end })
box:AddButton({ Text = "Stop tracking", Func = function()
    stop()
end })
box:AddButton({ Text = "Refresh the list", Func = refreshTargets })
statusLabel = box:AddLabel("Not tracking anything.", true)
box:AddLabel("A marker on your screen points at it with the heading and distance (north is -Z, as on the map). "
    .. "It goes away when you get there.", true)

refreshTargets()

return {}
end
__modules["features/market"] = function(use) -- src/games/slayers2/features/market.luau
-- Market tab: the Black Marketer and rotating shops are seeded from server time, so the client
-- can compute where he is, what he sells now, and what he will sell on any future visit.
--
-- Black Marketer: Ouwland.Content.Misc.Npcs["Black Marketer"].TimedVendor (every 2h, in town
-- 30 min, 11 spots). TimedVendor.GetState -> { Cycle, Active, NextEdgeIn }, GetStock(cfg, cycle),
-- GetSpotIndex(cfg, cycle, #Spawns). The shop data and the wishlist picker are features/shops;
-- this tab shows where he is, his stock, and when he next brings the items picked there.

local Env = use("core/env")
local Life = use("shared/life")
local Data = use("core/data")
local Ui = use("core/ui")
local Shops = use("features/shops")

local FORECAST_VISITS = 3
local FORECAST_CYCLES = 84 -- one week of visits

local Content = Env.ReplicatedStorage.Ouwland.Content
local Vendor = Shops.Marketer.TimedVendor
local ROTATING_SHOPS = {
    { label = "Elara (Mistfall Harbor)", path = { "Mistfall Harbor", "Npcs", "Elara" } },
    { label = "Lynx (Iceveil winter store)", path = { "Iceveil Valley", "Npcs", "Iceveil Settlement", "Winter Store Rep Lynx" } },
}
for _, shop in ipairs(ROTATING_SHOPS) do
    local node = Content
    for _, part in ipairs(shop.path) do
        node = node and node:FindFirstChild(part)
    end
    local ok, definition = pcall(require, node)
    shop.config = ok and type(definition) == "table" and definition.RotatingShop or nil
end
Env.elevate()

local entryName = Shops.entryName
local vendorState, stock, spotOf = Shops.vendorState, Shops.vendorStock, Shops.vendorSpot

local function duration(seconds)
    seconds = math.max(0, math.floor(seconds))
    local hours, minutes = seconds // 3600, (seconds % 3600) // 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, seconds % 60)
    end
    return string.format("%d:%02d", minutes, seconds % 60)
end

local function priceText(entry)
    return Shops.priceText(entryName(entry), type(entry) == "table" and entry.Price or nil)
end

local function rarityOf(name)
    local definition = Env.Game.Items[name]
    return definition and Env.Game.Rarities.Order[definition.Rarity] or "?"
end

local function describe(entry)
    local name = entryName(entry)
    return string.format("%s  [%s]  %s%s", name, rarityOf(name), priceText(entry), Shops.owned(name) > 0 and "  (owned)" or "")
end

local always = {}
for _, entry in ipairs(Vendor.Always or {}) do
    always[entryName(entry)] = true
end

-- Picks from the wishlist that the Black Marketer sells.
local function wishlist()
    local wanted, count = {}, 0
    for _, name in ipairs(Shops.picked()) do
        local entry = Shops.catalog[name]
        if entry and entry.kind == "vendor" then
            wanted[name] = true
            count += 1
        end
    end
    return wanted, count
end

-- UI -------------------------------------------------------------------------------------------
local tab = Ui.Tabs.Market
local marketer = tab:AddGroupbox({ Side = "Left", Name = "Black Marketer", IconName = "venetian-mask" })
local forecast = tab:AddGroupbox({ Side = "Right", Name = "Upcoming visits", IconName = "calendar-clock" })
local rotating = tab:AddGroupbox({ Side = "Right", Name = "Rotating shops", IconName = "refresh-ccw" })
local events = tab:AddGroupbox({ Side = "Right", Name = "Timed events", IconName = "timer" })

local statusLabel = marketer:AddLabel("", true)
local stockLabel = marketer:AddLabel("", true)
marketer:AddToggle("MarketNotify", { Text = "Notify when he arrives", Default = true })
local forecastLabel = forecast:AddLabel("", true)
forecast:AddDivider()
local wishLabel = forecast:AddLabel("", true)
local rotatingLabel = rotating:AddLabel("", true)
local eventsLabel = events:AddLabel("", true)

-- Panels ---------------------------------------------------------------------------------------
local announced = nil
Life.loop("market:panels", 2, function()
    local current = vendorState()
    local ok, every = Env.call(Env.Game.TimedVendor.GetEvery, Vendor)
    every = ok and every or 7200
    local now = workspace:GetServerTimeNow()
    local texts = {}

    if current.Active then
        local spot = spotOf(current.Cycle)
        local root = Data.character()
        local distance = spot and root and (spot - root.Position).Magnitude or 0
        texts.status = string.format("In town now - leaves in %s\n%d studs away", duration(current.NextEdgeIn), math.floor(distance))
    else
        texts.status = string.format("Away - arrives in %s", duration(current.NextEdgeIn))
    end

    local shown = current.Active and current.Cycle or current.Cycle + 1
    local lines = {}
    for _, entry in ipairs(stock(shown)) do
        if not always[entryName(entry)] then
            lines[#lines + 1] = describe(entry)
        end
    end
    texts.stock = (current.Active and "Selling now:\n" or "Next visit brings:\n") .. table.concat(lines, "\n")
        .. "\n+ Frozen Heart ($10,000) and Robux items every visit"

    local visits = {}
    for offset = 1, FORECAST_VISITS do
        local cycle = current.Cycle + offset
        local names = {}
        for _, entry in ipairs(stock(cycle)) do
            if not always[entryName(entry)] then
                names[#names + 1] = entryName(entry)
            end
        end
        visits[#visits + 1] = string.format("In %s: %s", duration(cycle * every - now), table.concat(names, ", "))
    end
    texts.forecast = table.concat(visits, "\n\n")

    local wanted, wantedCount = wishlist()
    if wantedCount == 0 then
        texts.wish = "Pick Black Marketer items in the Wishlist to see when he next brings them."
    else
        local found, rows = {}, {}
        for offset = current.Active and 0 or 1, FORECAST_CYCLES do
            local cycle = current.Cycle + offset
            for _, entry in ipairs(stock(cycle)) do
                local name = entryName(entry)
                if wanted[name] and not found[name] then
                    found[name] = cycle
                end
            end
        end
        for name in pairs(wanted) do
            local cycle = found[name]
            rows[#rows + 1] = not cycle and string.format("%s: not within a week", name)
                or (cycle == current.Cycle and current.Active) and string.format("%s: IN STOCK NOW", name)
                or string.format("%s: in %s", name, duration(cycle * every - now))
        end
        table.sort(rows)
        texts.wish = table.concat(rows, "\n")
    end

    local shops = {}
    for _, shop in ipairs(ROTATING_SHOPS) do
        if shop.config then
            local _, shopEvery = Env.call(Env.Game.RotatingShop.GetEvery, shop.config)
            local _, cycle = Env.call(Env.Game.RotatingShop.GetCycleIndex, shop.config)
            local _, nowItems = Env.call(Env.Game.RotatingShop.GetRotation, shop.config, cycle)
            local _, nextItems = Env.call(Env.Game.RotatingShop.GetRotation, shop.config, (cycle or 0) + 1)
            local nowText, nextText = {}, {}
            for _, entry in ipairs(nowItems or {}) do
                nowText[#nowText + 1] = string.format("%s %s", entryName(entry), priceText(entry))
            end
            for _, entry in ipairs(nextItems or {}) do
                nextText[#nextText + 1] = entryName(entry)
            end
            shops[#shops + 1] = string.format("%s - restock in %s\nNow: %s\nNext: %s", shop.label,
                duration((shopEvery or 3600) - now % (shopEvery or 3600)), table.concat(nowText, ", "), table.concat(nextText, ", "))
        end
    end
    texts.rotating = #shops > 0 and table.concat(shops, "\n\n") or "No rotating shops found."

    local timed = Env.Game.TimedEvents
    local finalSelection = timed.FinalSelection
    local requirement = finalSelection.Requirements or {}
    local qualifies = Data.value("Race") == requirement.Race and Data.level() >= (requirement.Level or 0)
    texts.events = string.format("Final Selection in %s (%s)\nBoss hunt rotation in %s",
        duration(finalSelection.Every - now % finalSelection.Every),
        qualifies and "you qualify" or string.format("needs %s, Lv %d", tostring(requirement.Race), requirement.Level or 0),
        duration(timed.BossHunt.Every - now % timed.BossHunt.Every))

    -- Arrival notice, once per visit.
    if current.Active and announced ~= current.Cycle then
        announced = current.Cycle
        if Ui.on("MarketNotify") then
            local hits = {}
            for _, entry in ipairs(stock(current.Cycle)) do
                if wanted[entryName(entry)] then
                    hits[#hits + 1] = entryName(entry)
                end
            end
            Ui.notify("Black Market", string.format("The Black Marketer is in town for %s.%s", duration(current.NextEdgeIn),
                #hits > 0 and ("\nWishlist in stock: " .. table.concat(hits, ", ")) or ""), 8)
        end
    end

    Env.elevate()
    statusLabel:SetText(texts.status)
    stockLabel:SetText(texts.stock)
    forecastLabel:SetText(texts.forecast)
    wishLabel:SetText(texts.wish)
    rotatingLabel:SetText(texts.rotating)
    eventsLabel:SetText(texts.events)
end)

return {}
end
__modules["features/settings"] = function(use) -- src/games/slayers2/features/settings.luau
-- Settings tab (see shared/settings): Slayers 2 configs, and what each missing function changes.

use("core/ui")
local Settings = use("shared/settings")

return Settings.build({
    folder = "Slayers2",
    effects = {
        fireproximityprompt = "prompts are pressed like a player would (in range only)",
        getconnections = "fishing needs Instant reel on",
        queue_on_teleport = "the hub does not come back after a teleport: run the loader again",
        writefile = "configs, themes and the offline cache cannot be saved",
    },
})
end
__modules["features/shops"] = function(use) -- src/games/slayers2/features/shops.luau
-- Shop data for the Market tab: what the Black Marketer sells and at what price, and the wishlist
-- of his items to watch for (the Market tab shows when he next brings them).
--
-- Everything for sale is registered in one table, Shop.itemsforsale, under four kinds of seller:
--  * NPC shops: an NPC definition's Shop table (Kuro, Rika, Meku, Ginzo, Raze, Ren, Fisherman
--    Jeso, Baitmonger Nori, Lynx).
--  * The Black Marketer (TimedVendor): only while he is in town, only his stock for that visit.
--  * Rotating stalls (Elara, Lynx's winter store): the pool rotates on a server-time seed, and
--    only the current rotation is listed.
--  * The menu shop: listings with no seller (Evil Art orbs for spins).
-- Robux prices are never listed.

local Env = use("core/env")
local Data = use("core/data")
local Ui = use("core/ui")
local Npcs = use("core/npcs")

local Options = Ui.Options

local Shops = {}

local Content = Env.ReplicatedStorage.Ouwland.Content
Shops.Marketer = require(Content.Misc.Npcs["Black Marketer"])
local Vendor = Shops.Marketer.TimedVendor
Env.elevate()

function Shops.entryName(entry)
    return type(entry) == "table" and entry.Name or tostring(entry)
end
local entryName = Shops.entryName

-- Black Marketer --------------------------------------------------------------------------------
function Shops.vendorState()
    local ok, result = Env.call(Env.Game.TimedVendor.GetState, Vendor)
    return ok and result or { Cycle = 0, Active = false, NextEdgeIn = 0 }
end

function Shops.vendorStock(cycle)
    local ok, result = Env.call(Env.Game.TimedVendor.GetStock, Vendor, cycle)
    return ok and result or {}
end

function Shops.vendorSpot(cycle)
    local ok, index = Env.call(Env.Game.TimedVendor.GetSpotIndex, Vendor, cycle, #Shops.Marketer.Spawns)
    local spot = ok and Shops.Marketer.Spawns[index]
    return spot and (typeof(spot) == "CFrame" and spot.Position or spot) or nil
end

-- Prices ------------------------------------------------------------------------------------------
local catalog = {} -- name -> { name, kind, sellers = { npc }, price, rotation }

-- The price table for an item: the live listing's, the shop entry's, or the item's own.
function Shops.priceOf(name, fallback)
    local listing = Env.Game.Shop.itemsforsale[name]
    local price = listing and listing.Price
    if typeof(price) ~= "table" then
        price = fallback or (catalog[name] and catalog[name].price)
    end
    if typeof(price) ~= "table" then
        local definition = Env.Game.Items[name]
        price = definition and definition.Price
    end
    return typeof(price) == "table" and price or nil
end

local function isRobux(price)
    return price ~= nil and (price.Product ~= nil or price.Gamepass ~= nil)
end

local function commas(number)
    local text = tostring(math.floor(number))
    repeat
        local changed
        text, changed = text:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    until changed == 0
    return text
end
Shops.commas = commas

-- "$600", "$350 + 2 Demon Horns", "54 Spins", "Robux" or "?".
function Shops.priceText(name, fallback)
    local price = Shops.priceOf(name, fallback)
    if not price then
        return "?"
    end
    if isRobux(price) then
        return "Robux"
    end
    local parts = {}
    if type(price.Wen) == "number" then
        parts[1] = "$" .. commas(price.Wen)
    end
    for currency, amount in pairs(price) do
        if currency ~= "Wen" then
            parts[#parts + 1] = string.format("%s %s", commas(tonumber(amount) or 0), currency)
        end
    end
    return table.concat(parts, " + ")
end

-- Catalog -----------------------------------------------------------------------------------------
local function add(name, kind, seller, price, rotation)
    if isRobux(price) then
        return
    end
    local entry = catalog[name]
    if not entry then
        entry = { name = name, kind = kind, sellers = {}, price = price, rotation = rotation }
        catalog[name] = entry
    end
    if seller and not table.find(entry.sellers, seller) then
        entry.sellers[#entry.sellers + 1] = seller
    end
    entry.price = entry.price or price
end

for npcName, definition in pairs(Npcs.all()) do
    if type(definition.Shop) == "table" then
        for item, listing in pairs(definition.Shop) do
            add(item, "npc", npcName, type(listing) == "table" and listing.Price or nil)
        end
    end
    if type(definition.TimedVendor) == "table" then
        for _, source in ipairs({ definition.TimedVendor.Always or {}, definition.TimedVendor.Stock or {} }) do
            for _, entry in ipairs(source) do
                add(entryName(entry), "vendor", npcName, type(entry) == "table" and entry.Price or nil)
            end
        end
    end
    if type(definition.RotatingShop) == "table" then
        for _, source in ipairs({ definition.RotatingShop.Always or {}, definition.RotatingShop.Pool or {} }) do
            for _, entry in ipairs(source) do
                add(entryName(entry), "rotating", npcName, type(entry) == "table" and entry.Price or nil, definition.RotatingShop)
            end
        end
    end
end
for name, listing in pairs(Env.Game.Shop.itemsforsale) do
    if listing.Type == "Item" and not catalog[name] then
        add(name, "menu", nil, listing.Price)
    end
end
Env.elevate()

-- Drop entries with no price anywhere, or a Robux one. The wishlist lists the Black Marketer's.
local names = {}
for name, entry in pairs(catalog) do
    local price = Shops.priceOf(name, entry.price)
    if price and not isRobux(price) then
        if entry.kind == "vendor" then
            names[#names + 1] = name
        end
    else
        catalog[name] = nil
    end
end
table.sort(names)
Shops.catalog = catalog

-- What you own of an item (non-stacking items are one entry per copy).
local function owned(name)
    local inventory = Data.inventory()
    local total = 0
    for _, item in ipairs(inventory and inventory:GetChildren() or {}) do
        if item.Name == name then
            local amount = item:FindFirstChild("Amount")
            total += amount and amount.Value or 1
        end
    end
    return total
end
Shops.owned = owned

-- The Black Marketer items picked in the wishlist.
function Shops.picked()
    local list = {}
    for name, on in pairs(Options.ShopBuyList.Value) do
        if on then
            list[#list + 1] = name
        end
    end
    table.sort(list)
    return list
end

-- UI ----------------------------------------------------------------------------------------------
-- The option keeps its old id (ShopBuyList) so picks saved in a config still load.
local group = Ui.Tabs.Market:AddGroupbox({ Side = "Left", Name = "Wishlist", IconName = "star" })
group:AddDropdown("ShopBuyList", {
    Searchable = true,
    Text = "Black Marketer items to watch",
    Values = names,
    Default = {},
    Multi = true,
    Tooltip = "Everything the Black Marketer sells for Wen, materials or spins (Robux items are left out). Upcoming visits shows when he next brings the ones you pick, and his arrival notice lists any that are in stock.",
})

return Shops
end
__modules["features/skills"] = function(use) -- src/games/slayers2/features/skills.luau
-- Farm tab: auto use skills, pressed the way the skill keys press them, alongside any fight.
--
-- How the game casts (read from the HUD's Skills handler and Skill_Controller):
--  * Skills_Provider.get_current_keys() is the skill bar: up to 10 { Name, Max_Hold, ... } from
--    the equipped weapon (Items[weapon].Skills) and its breathing / demon art, fighting style,
--    clan and innate skills. Keys_Changed fires when it changes (a weapon swap).
--  * A key press is Skill_Controller.Attempt_Hold(name, key); when it returns true the HUD sets
--    CurrentMax = Max_Hold and HeldSkill = name. Letting go of the key sets UnHoldBoolean and the
--    controller's own loop calls StopHold (it also lets go by itself after Max_Hold). Pressing a
--    skill that has a follow-up waiting (a "Switch" child on the player) goes through the same
--    Attempt_Hold. So every kind of skill (taps, charges, buffs, follow-ups) is a press and a
--    release.
--  * Aim is Platform_Handler.mousepos, read on press and on release: while a cast is in flight it
--    points at the fight's target, or ahead of the character.
--  * Pressing a skill the current loadout does not provide is reported by the server as a
--    ban-tier action ("Casted a skill their loadout does not provide"), so only skills on the bar
--    right now are pressed. Cooldowns (an SHC child named after the skill: Started + Value
--    seconds), locks (SkillService.Stats.GetRequirements), stamina and auras are checked first, as
--    Skills_Module.Can_Skill does, so a press never pops the game's warnings.

local Env = use("core/env")
local Life = use("shared/life")
local Data = use("core/data")
local Ui = use("core/ui")
local Combat = use("core/combat")

local Options = Ui.Options

-- The game's skill modules, set by connect() once the game is ready for them: the hub can start
-- before the character exists (from the main menu, after a teleport), and these controllers wait
-- on it while they load.
local Controller, Provider, Platform = nil, nil, nil
local SKILL_MODULES = { "Skill_Controller", "Skills_Provider", "Platform_Handler", "PlayerProfile", "Skill_Info",
    "manage_cd", "SkillStats" }

local Skills = {
    status = "Off",
    casts = 0,
    last = nil,
    connected = false, -- hooked into the game's skill system (see connect)
    bar = {}, -- the skill bar right now: { { name, maxHold } } in key order
    known = {}, -- name -> where it comes from, for the picker
}

local RANGE = 40 -- "while fighting": the fight's target must be this close
local GAP = 0.25 -- between two casts
local BLOCKING = "Blocking" -- a guard, not an attack: only used when picked by name

-- The bar ---------------------------------------------------------------------------------------

local function setBar(keys)
    local bar = {}
    for index = 1, 10 do
        local entry = type(keys) == "table" and keys[index]
        if type(entry) == "table" and type(entry.Name) == "string" and entry.Name ~= "" then
            bar[#bar + 1] = { name = entry.Name, maxHold = tonumber(entry.Max_Hold) }
            if not Skills.known[entry.Name] then
                Skills.known[entry.Name] = "your skill bar"
                Skills.pickerStale = true
            end
        end
    end
    Skills.bar = bar
end

function Skills.readBar()
    if not Provider then
        return
    end
    local ok, keys = Env.call(Provider.get_current_keys)
    if ok then
        setBar(keys)
    end
end

-- Every hotbar weapon's own skills, so they can be picked before that weapon is out.
function Skills.learnHotbar()
    Data.hotbar(function(name, definition)
        for _, skill in ipairs(type(definition.Skills) == "table" and definition.Skills or {}) do
            if type(skill) == "table" and type(skill.Name) == "string" and not Skills.known[skill.Name] then
                Skills.known[skill.Name] = name
                Skills.pickerStale = true
            end
        end
        return false
    end)
end

-- Ready to press ----------------------------------------------------------------------------------

local function holder()
    local char = Env.LocalPlayer.Character
    return char and (char:FindFirstChild("SHC") or char:FindFirstChild("SHCS"))
end

local function info(name)
    local ok, table_ = pcall(function()
        return Env.Game.Skill_Info[name]
    end)
    return ok and type(table_) == "table" and table_ or nil
end

-- True when `name` would be accepted right now, or false and why.
function Skills.ready(name)
    local shc = holder()
    if shc then
        local named, cdName = Env.call(Env.Game.manage_cd.filter_cd_name, Env.LocalPlayer, name)
        local cooldown = shc:FindFirstChild(named and cdName or name)
        local started = cooldown and cooldown:GetAttribute("Started")
        if cooldown and typeof(cooldown.Value) == "number" and typeof(started) == "number"
            and os.clock() - started < cooldown.Value then
            return false, "cooling down"
        end
    end
    local checked, _, unlocked = Env.call(Env.Game.SkillStats.GetRequirements, Env.LocalPlayer, name)
    if checked and not unlocked then
        return false, "locked"
    end
    local details = info(name)
    local values = Env.ReplicatedStorage:FindFirstChild("Player_Service")
        and Env.ReplicatedStorage.Player_Service.Values:FindFirstChild(Env.LocalPlayer.Name)
    if details and values then
        if details.RequiresAura and not values:FindFirstChild(details.RequiresAura) then
            return false, details.RequiresAura .. " is not active"
        end
        local stamina = values:FindFirstChild("Stamina")
        if type(details.Stamina) == "number" and stamina and stamina.Value < details.Stamina then
            return false, "low stamina"
        end
    end
    return true
end

-- Aim ---------------------------------------------------------------------------------------------

local aimAt = nil -- () -> Vector3 while one of our casts is in flight

local function hookAim()
    local originalMousepos = Platform.mousepos
    local function aimedMousepos(...)
        local get = aimAt
        if get then
            local ok, position = pcall(get)
            if ok and typeof(position) == "Vector3" then
                return position
            end
        end
        return originalMousepos(...)
    end
    Platform.mousepos = aimedMousepos
    Life.onCleanup(function()
        if Platform.mousepos == aimedMousepos then
            Platform.mousepos = originalMousepos
        end
    end)
end

-- Casting -------------------------------------------------------------------------------------------

-- Presses `skill`, holds it (charge skills, up to the "Hold for" setting) and lets go, aimed at rig.
function Skills.cast(skill, rig)
    aimAt = function()
        local targetRoot = rig and rig.Parent and rig:FindFirstChild("HumanoidRootPart")
        if targetRoot then
            return targetRoot.Position
        end
        local root = Data.character()
        return root and root.Position + root.CFrame.LookVector * 20 or nil
    end
    local ok, pressed = Env.call(Controller.Attempt_Hold, skill.name, nil)
    if not ok or pressed ~= true then
        aimAt = nil
        return false
    end
    Controller.CurrentMax = skill.maxHold
    Controller.HeldSkill = skill.name
    Skills.casts += 1
    Skills.last = skill.name
    local shc = holder()
    local hold = math.min(Options.AutoSkillHold.Value, skill.maxHold or 0)
    local deadline = os.clock() + hold
    while Life.alive and shc and shc.Value == skill.name and os.clock() < deadline do
        task.wait(0.05)
    end
    if shc and shc.Value == skill.name then
        -- The key-up: the controller's loop lets go, reading the aim once more.
        Controller.UnHoldBoolean = true
        local released = os.clock() + 1
        while Life.alive and shc.Value == skill.name and os.clock() < released do
            task.wait(0.05)
        end
    end
    aimAt = nil
    Env.elevate()
    return true
end

local function picked()
    local set, count = {}, 0
    for name, on in pairs(Options.AutoSkillList.Value) do
        if on then
            set[name] = true
            count += 1
        end
    end
    return set, count
end

-- What to aim at: the nearest mob in range.
local function target()
    local root = Data.character()
    if not root then
        return nil
    end
    local function near(rig)
        return (rig.HumanoidRootPart.Position - root.Position).Magnitude <= RANGE
    end
    return Combat.find(function(candidate)
        return candidate:GetAttribute("IsMob") == true and near(candidate)
    end)
end

function Skills.step()
    if not Ui.on("AutoSkills") then
        Skills.status = "Off"
        return
    end
    if not Skills.connected then
        Skills.status = "Waiting for the game to load your skills"
        return
    end
    local root, humanoid = Data.character()
    if not root or not humanoid or humanoid.Health <= 0 then
        Skills.status = "Waiting to respawn"
        return
    end
    local shc = holder()
    if shc and (shc.Value ~= "" or shc:GetAttribute("en") == true) then
        return -- a skill is out (ours, or one you pressed)
    end
    local rig = target()
    if Options.AutoSkillWhen.Value == "While fighting" and not rig then
        Skills.status = "Waiting for a fight"
        return
    end
    local set, count = picked()
    local waiting = {}
    for _, skill in ipairs(Skills.bar) do
        local wanted = count > 0 and set[skill.name] or (count == 0 and skill.name ~= BLOCKING)
        if wanted then
            local ok, why = Skills.ready(skill.name)
            if ok then
                Skills.status = "Using " .. skill.name
                if Skills.cast(skill, rig) then
                    Skills.status = "Used " .. skill.name
                    return
                end
                waiting[#waiting + 1] = skill.name .. " (the game refused it)"
            else
                waiting[#waiting + 1] = string.format("%s (%s)", skill.name, why)
            end
        end
    end
    if count > 0 then
        for name in pairs(set) do
            local onBar = false
            for _, skill in ipairs(Skills.bar) do
                onBar = onBar or skill.name == name
            end
            if not onBar then
                waiting[#waiting + 1] = name .. " (not on your bar with this weapon)"
            end
        end
    end
    Skills.status = #waiting > 0 and ("Waiting: " .. table.concat(waiting, ", ")) or "No skills to use"
end

-- UI ------------------------------------------------------------------------------------------------
local group = Ui.Tabs.Farm:AddGroupbox({ Side = "Right", Name = "Auto skills", IconName = "sparkles" })

group:AddToggle("AutoSkills", {
    Text = "Auto use skills",
    Default = false,
    Tooltip = "Presses your skills like the skill keys do: attacks, charges, buffs and follow-ups. Only skills on your bar right now are used, each when it is off cooldown and you have the stamina.",
})
Ui.automation("AutoSkills", true)
group:AddDropdown("AutoSkillList", {
    Searchable = true,
    Text = "Skills to use",
    Values = {},
    Default = {},
    Multi = true,
    Tooltip = "Pick nothing to use every skill on your bar except Blocking. Skills of every weapon on your hotbar are listed; each is used while that weapon is out.",
})
group:AddDropdown("AutoSkillWhen", {
    Text = "Use them",
    Values = { "While fighting", "Always" },
    Default = "While fighting",
    Multi = false,
    Tooltip = "While fighting: aimed at the nearest mob in range. Always: also with no fight (buffs), aimed ahead of you.",
})
group:AddSlider("AutoSkillHold", {
    Text = "Hold charge skills for",
    Default = 0.4,
    Min = 0,
    Max = 5,
    Rounding = 1,
    Suffix = "s",
    Tooltip = "How long to hold a skill that can be charged before letting go (never longer than the skill allows). 0 = tap.",
})
local statusLabel = group:AddLabel("", true)

-- Workers -------------------------------------------------------------------------------------------

-- Hooks into the game's skill system once the character is in (the controllers wait for it while
-- they load, and the game's own HUD requires them then too). Retried until it works.
local function connect()
    if Skills.connected or not Env.LocalPlayer.Character then
        return
    end
    Env.preload(table.unpack(SKILL_MODULES))
    Controller, Provider, Platform = Env.Game.Skill_Controller, Env.Game.Skills_Provider, Env.Game.Platform_Handler
    hookAim()
    local ok, connection = pcall(function()
        return Provider.Keys_Changed:Connect(setBar)
    end)
    Env.elevate()
    if ok and connection then
        Life.onCleanup(function()
            pcall(function()
                connection:Disconnect()
            end)
        end)
    end
    Skills.connected = true
    Skills.readBar()
end

Skills.learnHotbar()
Life.loop("skills:connect", 1, connect)
Life.loop("skills:cast", GAP, Skills.step)

local function refreshPicker()
    if not Skills.pickerStale then
        return
    end
    Skills.pickerStale = false
    local names = {}
    for name in pairs(Skills.known) do
        names[#names + 1] = name
    end
    table.sort(names)
    Options.AutoSkillList:SetValues(names)
end
refreshPicker()

Life.loop("skills:panel", 1, function()
    Skills.readBar() -- Keys_Changed misses nothing, but a missed connection must not freeze the list
    Skills.learnHotbar()
    refreshPicker()
    local bar = {}
    for _, skill in ipairs(Skills.bar) do
        bar[#bar + 1] = skill.name
    end
    statusLabel:SetText(string.format("%s\nOn your bar: %s. Used %d time(s)%s.",
        Ui.on("AutoSkills") and Skills.status or "Off",
        #bar > 0 and table.concat(bar, ", ") or "nothing",
        Skills.casts, Skills.last and (", last " .. Skills.last) or ""))
end)

return Skills
end
__modules["features/skilltree"] = function(use) -- src/games/slayers2/features/skilltree.luau
-- Skill points: spends them in the skill tree the way its own Unlock button does, through
-- SignalFunction "UnlockSkillTreeNode"(name).
--
-- The tree is SkillService.SkillTreeholder.GetBranches(): a Character branch (Innate Skills:
-- Double Jump, Wall Climb; Stats: one levelled progression per stat) plus a branch per breathing
-- or demon art, weapon and clan, holding its skills. A stat's level is
-- slot.SkillTreeUnlockedList[stat].Value, capped by Stats.GetMaxIndexForCategory; a skill is
-- unlocked when Stats.IsSkillUnlocked says so. What the next step costs is
-- Stats.GetRequirementsAt(player, name, index) (stats) or Stats.GetRequirements(player, name)
-- (skills): { SkillPoints = n, Mastery = n, Boss = name }, each checked by
-- SkillTreeholder.RequirementsSolver[kind].CanBuy(player, name, value).

local Env = use("core/env")
local Life = use("shared/life")
local Data = use("core/data")
local Ui = use("core/ui")

local Options = Ui.Options
local SkillService = Env.ReplicatedStorage.CAM.Global.SkillService
local Holder = require(SkillService.SkillTreeholder)
local Stats = require(SkillService.Stats)
Env.elevate()

local STAT_DEFAULTS = { "Additional Damage", "Max Health" }
local UNLOCK_WAIT = 2
local MAX_PER_PASS = 20

local player = Env.LocalPlayer

-- Stat names and skill names, read from the tree as the menu would draw it.
local function tree()
    local stats, skills = {}, {}
    local ok, branches = Env.call(Holder.GetBranches)
    local function walk(node, underStats)
        for _, child in ipairs(node) do
            if type(child) == "table" and type(child.Name) == "string" then
                if underStats then
                    if not table.find(stats, child.Name) then
                        stats[#stats + 1] = child.Name
                    end
                elseif child.IsBranch then
                    walk(child, child.Name == "Stats")
                elseif not table.find(skills, child.Name) then
                    skills[#skills + 1] = child.Name
                end
            end
        end
    end
    walk(ok and branches or {}, false)
    return stats, skills
end

local function statLevel(name)
    local slot = Data.slot()
    local list = slot and slot:FindFirstChild("SkillTreeUnlockedList")
    local entry = list and list:FindFirstChild(name)
    return entry and entry.Value or 0
end

local function describeMissing(kind, value)
    if kind == "SkillPoints" then
        return string.format("%s SP", tostring(value))
    elseif kind == "Mastery" then
        return string.format("mastery %s", tostring(value))
    elseif kind == "Boss" then
        return "defeat " .. tostring(value)
    end
    return string.format("%s %s", tostring(kind), tostring(value))
end

-- The next thing `name` can be unlocked to: { name, index, cost, ready, missing } or nil when
-- it is maxed or already unlocked.
local function nextStep(name, isStat)
    local index, requirements
    if isStat then
        local level = statLevel(name)
        local ok, maxIndex = Env.call(Stats.GetMaxIndexForCategory, name)
        if ok and type(maxIndex) == "number" and level >= maxIndex then
            return nil
        end
        index = level + 1
        local got, result = Env.call(Stats.GetRequirementsAt, player, name, index)
        requirements = got and result or nil
    else
        local ok, unlocked = Env.call(Stats.IsSkillUnlocked, player, name)
        if ok and unlocked then
            return nil
        end
        local got, result = Env.call(Stats.GetRequirements, player, name)
        requirements = got and result or nil
    end
    if type(requirements) ~= "table" then
        return nil
    end
    local missing = {}
    for kind, value in pairs(requirements) do
        local solver = Holder.RequirementsSolver[kind]
        local ok, met = true, true
        if solver then
            ok, met = Env.call(solver.CanBuy, player, name, value)
        end
        if not (ok and met) then
            missing[#missing + 1] = describeMissing(kind, value)
        end
    end
    return {
        name = name,
        index = index,
        cost = tonumber(requirements.SkillPoints) or 0,
        ready = #missing == 0,
        missing = missing,
    }
end

local function label(step)
    return step.index and string.format("%s Lv%d (%d SP)", step.name, step.index, step.cost)
        or string.format("%s (%d SP)", step.name, step.cost)
end

local function pickedStats()
    local list = {}
    for name, on in pairs(Options.SkillStats.Value) do
        if on then
            list[#list + 1] = name
        end
    end
    return list
end

-- Everything affordable right now, skills first, then the cheapest picked stat.
local function candidates()
    local stats, skills = tree()
    local ready = {}
    if Ui.on("SkillUnlockSkills") then
        for _, name in ipairs(skills) do
            local step = nextStep(name, false)
            if step and step.ready then
                ready[#ready + 1] = step
            end
        end
        table.sort(ready, function(a, b)
            return a.cost < b.cost
        end)
    end
    local cheapest
    for _, name in ipairs(pickedStats()) do
        if table.find(stats, name) then
            local step = nextStep(name, true)
            if step and step.ready and (not cheapest or step.cost < cheapest.cost) then
                cheapest = step
            end
        end
    end
    ready[#ready + 1] = cheapest
    return ready
end

local function unlock(step)
    local before = step.index and statLevel(step.name) or nil
    local ok, result = Env.call(Env.Game.SignalFunction.ToServer, "UnlockSkillTreeNode", step.name)
    if not ok or result == false then
        return false
    end
    local deadline = os.clock() + UNLOCK_WAIT
    repeat
        task.wait(0.1)
        local done
        if before then
            done = statLevel(step.name) > before
        else
            local got, unlocked = Env.call(Stats.IsSkillUnlocked, player, step.name)
            done = got and unlocked
        end
        if done then
            return true
        end
    until os.clock() >= deadline
    return false
end

local spending = false
local function spend(announce)
    if spending then
        return
    end
    spending = true
    local bought, failed = {}, nil
    for _ = 1, MAX_PER_PASS do
        local step = candidates()[1]
        if not step or not Life.alive then
            break
        end
        if not unlock(step) then
            failed = step
            break
        end
        bought[#bought + 1] = label(step)
    end
    Env.elevate()
    spending = false
    if #bought > 0 then
        Ui.notify("Skill points", "Unlocked " .. table.concat(bought, ", "), 8)
    elseif failed then
        Ui.notify("Skill points", "The game refused " .. label(failed), 5)
    elseif announce then
        Ui.notify("Skill points", "Nothing affordable with your picks right now.", 4)
    end
end

-- UI ----------------------------------------------------------------------------------------------
local statNames = tree()
local group = Ui.Tabs.Home:AddGroupbox({ Side = "Left", Name = "Skill points", IconName = "sparkle" })
local statusLabel = group:AddLabel("", true)
group:AddDropdown("SkillStats", {
    Searchable = true,
    Text = "Stats to raise",
    Values = statNames,
    Default = STAT_DEFAULTS,
    Multi = true,
    Tooltip = "Points go to the cheapest next level among these, so they rise together.",
})
group:AddToggle("SkillUnlockSkills", {
    Text = "Unlock skills first",
    Default = true,
    Tooltip = "Double Jump, Wall Climb and your breathing, weapon and clan skills, as soon as their mastery and boss requirements are met.",
})
group:AddToggle("AutoSkillPoints", {
    Text = "Auto spend points",
    Default = false,
    Tooltip = "Spends skill points whenever something you picked becomes affordable.",
})
Ui.automation("AutoSkillPoints", true)
group:AddButton({ Text = "Spend now", Func = function()
    task.spawn(spend, true)
end })

Life.loop("skilltree", 5, function()
    local stats, skills = tree()
    local statLines, skillReady, skillLocked = {}, {}, {}
    for _, name in ipairs(pickedStats()) do
        if table.find(stats, name) then
            local step = nextStep(name, true)
            statLines[#statLines + 1] = step and (label(step) .. (step.ready and "" or (" - needs " .. table.concat(step.missing, ", "))))
                or (name .. " maxed")
        end
    end
    for _, name in ipairs(skills) do
        local step = nextStep(name, false)
        if step and step.ready then
            skillReady[#skillReady + 1] = label(step)
        elseif step then
            skillLocked[#skillLocked + 1] = string.format("%s (%s)", step.name, table.concat(step.missing, ", "))
        end
    end
    statusLabel:SetText(string.format("Skill points: %s\nNext stats: %s\nSkills ready: %s\nSkills locked: %s",
        tostring(Data.value("SkillPoints") or 0),
        #statLines > 0 and table.concat(statLines, "; ") or "none picked",
        #skillReady > 0 and table.concat(skillReady, ", ") or "none",
        #skillLocked > 0 and table.concat(skillLocked, ", ") or "none"))
    if Ui.on("AutoSkillPoints") and candidates()[1] then
        spend(false)
    end
end)

return {}
end
__modules["features/timers"] = function(use) -- src/games/slayers2/features/timers.luau
-- Timers tab: the day and night clock (the sun burns Demons) and when each boss is back.
--
-- Day and night: DayAndNightHandler runs one cycle of DayTime + NighTime seconds (gameSettings.Day:
-- 12 minutes of day, 24 of night) off the server clock, so every client agrees. It gives the phase,
-- the clock and SecondsUntilPhaseChange (to the next sunrise or sunset). Only Demons burn: see Anti
-- sun damage on the Farm tab.
--
-- Bosses: a boss's folder in workspace.Humanoids.Regions.<Region>.ActiveNpcs stays for the whole
-- server while its rig comes and goes. It holds BossInfo (attribute SpawnTime, the respawn in
-- seconds) and gets DespawnedAt (server time) when the boss goes down: the game's own boss bar
-- counts down from those two. A boss without BossInfo falls back on the SpawnTime in its Regions
-- definition, and one that went down before we saw it and has no DespawnedAt is timed from when we
-- noticed.

local Env = use("core/env")
local Life = use("shared/life")
local Data = use("core/data")
local Ui = use("core/ui")
local Where = use("core/where")

local ROWS = 10
local ALERT_AT = 60 -- seconds before sunrise

local RegionRoot = Env.need(Env.need(workspace, "Humanoids"), "Regions")

local tab = Ui.Tabs.Timers
local clockBox = tab:AddGroupbox({ Side = "Left", Name = "Day and night", IconName = "sun-moon" })
local bossBox = tab:AddGroupbox({ Side = "Right", Name = "Boss respawns", IconName = "skull" })

local function countdown(seconds)
    seconds = math.max(0, math.ceil(seconds))
    return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function clockText(hours)
    local whole = math.floor(hours) % 24
    return string.format("%02d:%02d", whole, math.floor((hours - math.floor(hours)) * 60))
end

-- Day and night -----------------------------------------------------------------------------------

local clockLabel = clockBox:AddLabel("Loading...", true)
clockBox:AddToggle("SunAlert", {
    Text = "Sunrise alert",
    Default = true,
    Tooltip = "Tells you a minute before the sun comes up, as a Demon. Nobody else burns in it.",
})
local cycleNote = ""
do
    local ok, text = pcall(function()
        local day = Env.Game.gameSettings.Day
        return string.format("One cycle is %d minutes of day and %d of night.", day.DayTime.Game // 60, day.NighTime.Game // 60)
    end)
    cycleNote = ok and text or ""
end
if cycleNote ~= "" then
    clockBox:AddLabel(cycleNote, true)
end

local alerted = false
local function updateClock()
    local handler = Env.Game.DayAndNightHandler
    local okEnabled, enabled = Env.call(handler.IsEnabled)
    if okEnabled and enabled == false then
        clockLabel:SetText("This place has no day and night cycle.")
        return
    end
    local okNight, night = Env.call(handler.IsNight)
    local okLeft, left = Env.call(handler.SecondsUntilPhaseChange)
    local okHours, hours = Env.call(handler.GetClockTime)
    if not (okNight and okLeft and type(left) == "number") then
        clockLabel:SetText("The day cycle is not available right now.")
        return
    end
    local race = Data.value("Race")
    local lines = {}
    if night then
        lines[1] = string.format("Night: sunrise in %s", countdown(left))
    else
        lines[1] = string.format("Day: the sun is up, sunset in %s", countdown(left))
        if race == "Demon" then
            lines[2] = Ui.on("AntiSun") and "Anti sun damage is on." or "The sun burns you: stay in shade, or turn on Anti sun damage (Farm tab)."
        end
    end
    if okHours and type(hours) == "number" then
        lines[#lines + 1] = "Clock " .. clockText(hours)
    end
    clockLabel:SetText(table.concat(lines, "\n"))

    if night and left <= ALERT_AT and not alerted then
        alerted = true
        if race == "Demon" and Ui.on("SunAlert") then
            Ui.notify("Sunrise", string.format("The sun comes up in %s. Find shade or turn on Anti sun damage.", countdown(left)), 8)
        end
    elseif not night or left > ALERT_AT + 5 then
        alerted = false
    end
end

-- Boss respawns -----------------------------------------------------------------------------------

local bossPanel
bossBox:AddToggle("BossAlert", {
    Text = "Alert when a boss spawns",
    Default = false,
    Tooltip = "A notification the moment a boss you saw down is back up, with where it is.",
})
bossPanel = Ui.panel(bossBox, ROWS)

local definedRespawn = nil
local function respawnOf(folder)
    local info = folder:FindFirstChild("BossInfo")
    local seconds = info and info:GetAttribute("SpawnTime")
    if type(seconds) == "number" then
        return seconds
    end
    if not definedRespawn then
        definedRespawn = {}
        local ok, regions = Env.call(function()
            return Env.Game.Regions.Regions
        end)
        for _, region in pairs(ok and type(regions) == "table" and regions or {}) do
            for _, npc in ipairs(type(region) == "table" and type(region.Npcs) == "table" and region.Npcs or {}) do
                local spawning = type(npc) == "table" and type(npc.SendOver) == "table" and npc.SendOver.Spawning
                if type(spawning) == "table" and type(spawning.SpawnTime) == "number" and type(npc.Name) == "string" then
                    definedRespawn[npc.Name] = spawning.SpawnTime
                end
            end
        end
    end
    return definedRespawn[folder.Name]
end

local function spawnOf(name)
    local ok, position = Env.call(Env.Game.Regions.GetNpcSpawn, name)
    return ok and typeof(position) == "Vector3" and position or nil
end

local wasUp = setmetatable({}, { __mode = "k" }) -- folder -> whether it was up last pass
local wentDown = setmetatable({}, { __mode = "k" }) -- folder -> os.clock() when we saw it fall

local function bosses()
    local rows = {}
    local now = workspace:GetServerTimeNow()
    for _, region in ipairs(RegionRoot:GetChildren()) do
        local active = region:FindFirstChild("ActiveNpcs")
        for _, folder in ipairs(active and active:GetChildren() or {}) do
            if folder:FindFirstChild("BossInfo") then
                local rig = folder:FindFirstChild(folder.Name)
                local humanoid = rig and rig:FindFirstChildOfClass("Humanoid")
                local up = humanoid ~= nil and humanoid.Health > 0
                local root = rig and rig:FindFirstChild("HumanoidRootPart")
                local previous = wasUp[folder]
                if up and previous == false and Ui.on("BossAlert") then
                    Ui.notify("Boss", string.format("%s is up: %s", folder.Name, Where.text(root and root.Position or spawnOf(folder.Name))), 8)
                end
                if not up and previous ~= false then
                    wentDown[folder] = os.clock()
                end
                wasUp[folder] = up

                local left = nil
                if not up then
                    local seconds = respawnOf(folder)
                    local despawned = folder:GetAttribute("DespawnedAt")
                    if seconds and type(despawned) == "number" then
                        left = seconds - (now - despawned)
                    elseif seconds and wentDown[folder] then
                        left = seconds - (os.clock() - wentDown[folder])
                    end
                end
                rows[#rows + 1] = {
                    name = folder.Name,
                    up = up,
                    left = left and math.max(0, left),
                    position = root and root.Position or spawnOf(folder.Name),
                }
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.up ~= b.up then
            return a.up
        end
        if (a.left ~= nil) ~= (b.left ~= nil) then
            return a.left ~= nil
        end
        if a.left ~= b.left then
            return a.left < b.left
        end
        return a.name < b.name
    end)
    return rows
end

local function updateBosses()
    local rows = bosses()
    local lines, upCount = {}, 0
    for index, row in ipairs(rows) do
        if row.up then
            upCount += 1
        end
        if index <= ROWS then
            local state = row.up and "UP now" or (row.left and ("back in " .. countdown(row.left)) or "down, respawn unknown")
            lines[index] = string.format("%s  %s\n    %s", row.name, state, Where.text(row.position))
        end
    end
    bossPanel.set(lines, #rows == 0 and "No boss is known to this server yet."
        or string.format("%d of %d boss(es) up. Up first, then the soonest back.%s", upCount, #rows,
            #rows > ROWS and string.format(" Showing %d.", ROWS) or ""))
end

Life.loop("timers:panels", 1, function()
    updateClock()
    updateBosses()
end)

return {}
end
__modules["main"] = function(use) -- src/games/slayers2/main.luau
-- Entry point. Core systems first, then features in tab order, then settings (autoload last).

-- The loader waits for this too, but the bundle can also be run on its own (a local build, an
-- auto-execute folder) before the game has finished loading.
if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Env = use("core/env")

-- The Minigames place also hosts Final Selection and PvP servers, which the hub does not play.
if Env.minigame and not Env.inDungeon then
    pcall(game:GetService("StarterGui").SetCore, game:GetService("StarterGui"), "SendNotification", {
        Title = "Slopix Hub",
        Text = "Nothing to automate in " .. tostring(Env.minigame) .. ".",
        Duration = 6,
    })
    return "Slopix Hub: not loaded in " .. tostring(Env.minigame)
end

-- Nothing is built until the game has loaded what the hub reads (see core/ready): executed on
-- join, in a freshly started private server above all, features used to start too early and fail.
use("core/ready").wait()

-- Everything reads the game's own ModuleScripts. An executor that cannot require them cannot run
-- the hub, so that is said once here instead of by every feature failing on its own. Loaded with
-- Env.preload, where the module may wait on the game (Env.Game.Utility, inside __index, may not).
local canRequire, requireError = pcall(Env.preload, "Utility")
Env.elevate()
if not canRequire then
    error("your executor could not load the game's modules (require): " .. tostring(requireError), 0)
end

-- A copy already running (the bundle executed twice, or a local build after the loader's) is
-- closed first: two hubs fight over the character, and only the loader used to close the old one.
local previous = Env.genv.__SlopixHub
if type(previous) == "table" and type(previous.Ui) == "table" and previous.Ui.Library then
    pcall(previous.Ui.Library.Unload, previous.Ui.Library)
    Env.genv.__SlopixHub = nil
    Env.elevate()
end

local Life = use("shared/life")
local Ui = use("core/ui")

use("core/scheduler")
-- The menu has no mobs, and Combat waits for the mob folders at load.
local Combat = not Env.inMenu and use("core/combat") or nil

local FEATURES = {
    "features/home",
    "features/skilltree",
    "features/accessories",
    "features/skills",
    "features/boss",
    "features/guide",
    "features/timers",
    "features/locator",
    "features/esp",
    "features/heal",
    "features/antidrown",
    "features/antisun",
    "features/fishing",
    "features/shops",
    "features/market",
    "features/clan",
}
-- Inside the tower there are no NPC regions, quests or shops of the open world: only the fight.
local DUNGEON_FEATURES = {
    "features/home",
    "features/skills",
    "features/heal",
}
-- The main menu only has your save slot: clan spins and codes work there, nothing else does.
local MENU_FEATURES = {
    "features/home",
    "features/clan",
}
-- One feature failing (a missing folder, a game update) is reported and the rest carry on.
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

local features = Env.inDungeon and DUNGEON_FEATURES or Env.inMenu and MENU_FEATURES or FEATURES
local loaded = {}
for _, name in ipairs(features) do
    loaded[name] = load(name)
end

local Settings = load("features/settings")
if Settings then
    Settings.finish()
end

-- Handle for debugging from Real (and for the next version to unload this one).
Env.genv.__SlopixHub = {
    Ui = Ui,
    Life = Life,
    Data = use("core/data"),
    Scheduler = use("core/scheduler"),
    Combat = Combat,
    Features = loaded, -- what each feature module returned, by name (nil if it failed to load)
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

local setIdentity = setthreadidentity or set_thread_identity or setidentity or setthreadcontext

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
-- The hub targets sUNC (which Real and Volt pass in full) but must not break where a function is
-- missing or goes by another name: everything executor-specific is looked up here once, and a
-- feature that cannot work without one says so instead of silently doing nothing.

local executorEnv = getfenv()
local syn, fluxus = executorEnv.syn, executorEnv.fluxus
local function first(...)
    for index = 1, select("#", ...) do
        local fn = select(index, ...)
        if type(fn) == "function" then
            return fn
        end
    end
    return nil
end

Env.genv = getgenv and getgenv() or _G
Env.request = first(request, http_request, http and http.request, syn and syn.request, fluxus and fluxus.request)
Env.queueOnTeleport = first(queue_on_teleport, queueonteleport, syn and syn.queue_on_teleport, fluxus and fluxus.queue_on_teleport)
Env.setClipboard = first(setclipboard, toclipboard, set_clipboard, Clipboard and Clipboard.set)
local executorOk, executorName = pcall(function()
    return identifyexecutor()
end)
Env.executor = executorOk and type(executorName) == "string" and executorName or "Unknown"

-- Missing functions that switch a feature off or change how it works, for the Settings tab.
-- A list, not a map: a map literal drops the missing (nil) ones before they can be counted.
-- Each game names the functions it cares about (Env.checkMissing), since what one needs another
-- never calls.
Env.missing = {}
function Env.checkMissing(entries)
    for _, entry in ipairs(entries) do
        if type(entry[2]) ~= "function" then
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
    local cache = {}
    local function load(name)
        local loaded = rawget(cache, name)
        if loaded ~= nil then
            return loaded
        end
        local path = paths[name]
        assert(path, "Slopix: unknown game module " .. tostring(name))
        local node = root
        for _, part in ipairs(path) do
            node = node:WaitForChild(part, 10)
            assert(node, string.format("Slopix: game module %s is missing (%s)", name, part))
        end
        local module = require(node)
        Env.elevate()
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
    Life.connect(Env.LocalPlayer.Idled, nudge)

    -- Belt and braces: the idle kick itself listens on Idled too. Where the executor has
    -- getconnections (Real, Volt), those listeners are switched off while Anti AFK is on and
    -- switched back on when it goes off or the hub unloads.
    local silenced = {}
    local function silenceIdle(off)
        if off and getconnections then
            local ok, connections = pcall(getconnections, Env.LocalPlayer.Idled)
            for _, connection in ipairs(ok and connections or {}) do
                if connection.Function ~= nudge and connection.Enabled ~= false and pcall(connection.Disable, connection) then
                    silenced[#silenced + 1] = connection
                end
            end
        elseif not off then
            for _, connection in ipairs(silenced) do
                pcall(connection.Enable, connection)
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

local fs = writefile and readfile and isfile and isfolder and makefolder

-- The body at url, or nil and the reason. Tries the executor's request first (it reports the
-- status code), then game:HttpGet.
local function get(url)
    if Env.request then
        local ok, res = pcall(Env.request, { Url = url, Method = "GET" })
        if ok and type(res) == "table" and res.StatusCode ~= nil then
            if tonumber(res.StatusCode) == 200 and type(res.Body) == "string" and res.Body ~= "" then
                return res.Body
            end
            return nil, "HTTP " .. tostring(res.StatusCode)
        end
    end
    local ok, body = pcall(game.HttpGet, game, url)
    if not ok then
        return nil, tostring(body)
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

local function save(path, body)
    local dir = ""
    for part in CACHE:gmatch("[^/]+") do
        dir = dir == "" and part or dir .. "/" .. part
        if not isfolder(dir) then
            makefolder(dir)
        end
    end
    writefile(path, body)
end

-- Downloads url and compiles it (chunk name `name`). Falls back to the cached copy saved under
-- `name` by an earlier load. Returns the compiled chunk; errors with the reason when neither works.
function Http.load(url, name)
    local path = CACHE .. "/" .. name
    local reason
    for attempt = 1, TRIES do
        local body, err = get(url)
        Env.elevate()
        if body then
            local chunk, compileError = loadstring(body, "@" .. name)
            if chunk then
                if fs then
                    pcall(save, path, body)
                end
                return chunk
            end
            err = compileError -- a cut-off download
        end
        reason = err
        if attempt < TRIES then
            task.wait(attempt)
        end
    end
    local ok, cached = pcall(function()
        return fs and isfile(path) and readfile(path)
    end)
    local chunk = ok and type(cached) == "string" and cached ~= "" and loadstring(cached, "@" .. name)
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

function Life.onCleanup(fn)
    cleanups[#cleanups + 1] = fn
end

function Life.connect(signal, fn)
    local connection = signal:Connect(fn)
    Life.onCleanup(function()
        connection:Disconnect()
    end)
    return connection
end

-- Runs fn every `interval` seconds (a number, or a function returning one) until unload.
function Life.loop(name, interval, fn)
    task.spawn(function()
        while Life.alive do
            Env.elevate()
            local ok, err = xpcall(fn, debug.traceback)
            Env.elevate()
            Life.errors[name] = (not ok) and tostring(err) or nil
            if not Life.alive then
                break
            end
            task.wait(type(interval) == "function" and interval() or interval)
        end
    end)
end

-- Waits up to `seconds`, returning early (false) once the hub is unloading.
function Life.wait(seconds)
    local deadline = os.clock() + seconds
    repeat
        task.wait(math.min(0.1, seconds))
    until not Life.alive or os.clock() >= deadline
    Env.elevate()
    return Life.alive
end

function Life.shutdown()
    if not Life.alive then
        return
    end
    Life.alive = false
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
        lines[#lines + 1] = "Everything the hub uses is available."
    end
    compat:AddLabel(table.concat(lines, "\n"), true)

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
function Ui.create(options)
    local Library = Http.load(LIBRARY_URL, "Library.lua")()
    Env.elevate()
    Ui.Library = Library
    Ui.Options = Library.Options
    Ui.Toggles = Library.Toggles

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

    Library:OnUnload(function()
        Env.elevate()
        Life.shutdown()
    end)
    return Ui
end

function Ui.notify(title, text, seconds)
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
return use("main")
