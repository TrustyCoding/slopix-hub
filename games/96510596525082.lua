-- Slopix Hub (Ball VS Ball), built 2026-10-09 14:54 UTC by build.py. Edit the files in src/, not this one.
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
__modules["core/env"] = function(use) -- src/games/ballvsball/core/env.luau
-- Ball VS Ball: the game's own ModuleScripts and remotes. Everything else (services, the executor,
-- elevate) comes from shared/env.
--
-- Remotes use sleitnick Net names. Resolve their instances under Packages without invoking
-- the module loader while resolving a replicated event or function.

local Env = use("shared/env")

Env.checkMissing({
    { "queue_on_teleport", Env.queueOnTeleport },
    { "setclipboard", Env.setClipboard },
})
for name, _ in pairs({ readfile = true, writefile = true, isfile = true, isfolder = true,
    makefolder = true, listfiles = true, delfile = true }) do
    Env.checkMissing({ { name, Env.files[name] } })
end
table.sort(Env.missing)

local RS = Env.ReplicatedStorage
local SERVICE = { "Engine", "Service" }
local function service(name)
    return { SERVICE[1], SERVICE[2], name }
end

-- Env.loadModule("Config"), Env.loadModule("PlayerData"), ...: required on first use and cached.
Env.Game, Env.loadModule = Env.modules(RS, {
    Net = { "Packages", "Net" },
    Config = service("Config"), -- the game's CloudConfig: balls, codes, quests, crates, limits
    PlayerData = service("PlayerData"),
    ExperienceService = service("ExperienceService"),
    TimeService = service("TimeService"),
    GameModeRegistry = service("GameModeRegistry"),
    CheckInService = service("CheckInService"),
    OnlineRewardConfig = service("OnlineRewardConfig"),
    StatsCore = { "Engine", "Service", "BallBattleStatsService", "Core" },
    BattleConfig = { "BattleDemo", "BattleConfig" },
    BattleSimulation = { "BattleDemo", "BattleSimulation" },
    ArenaOverride = { "BattleDemo", "ArenaOverride" },
})

local remotes = {}
local CONSTRUCTORS = { event = "RemoteEvent", unreliable = "UnreliableRemoteEvent", fn = "RemoteFunction" }
local PREFIX = { event = "RE/", unreliable = "URE/", fn = "RF/" }
local function remote(kind, name)
    Env.elevate()
    local key = kind .. name
    if not remotes[key] or not remotes[key].Parent then
        -- Locate the replicated instance without requiring Net in a lazy-table lookup;
        -- matching the class avoids an event/function mixup.
        local packages = Env.need(RS, "Packages", 10)
        local found = packages:FindFirstChild(PREFIX[kind] .. name, true)
        local deadline = os.clock() + 5
        while not found and os.clock() < deadline do
            task.wait(0.1)
            found = packages:FindFirstChild(PREFIX[kind] .. name, true)
        end
        Env.elevate()
        if not found then
            error("Slopix: remote " .. name .. " is not available yet", 2)
        end
        assert(found:IsA(CONSTRUCTORS[kind]), "Slopix: remote " .. name .. " has an unexpected class")
        remotes[key] = found
    end
    return remotes[key]
end

-- The RemoteEvent the game calls `name` ("DuelTableState").
function Env.event(name)
    return remote("event", name)
end

-- The UnreliableRemoteEvent the game calls `name` ("DuelTableAimPreview").
function Env.unreliable(name)
    return remote("unreliable", name)
end

local pending, retryAt = {}, {}
Env.requestIssues = {}

-- A timeout cannot undo a server action. Keep that remote occupied until its original call
-- finishes, then allow replication time before another request. Never retry inside this helper.
function Env.invoke(name, ...)
    if Env.stopped then return false, "hub unloaded" end
    if pending[name] or os.clock() < (retryAt[name] or 0) then
        return false, "waiting for the previous " .. name .. " request"
    end
    local work, args = {}, table.pack(...)
    pending[name] = work
    task.spawn(function()
        work.result = table.pack(Env.call(function()
            local fn = remote("fn", name)
            return fn:InvokeServer(table.unpack(args, 1, args.n))
        end))
        work.done = true
        if work.timedOut then
            retryAt[name] = os.clock() + 30
            Env.requestIssues[name] = "Late reply received; waiting for inventory/balance updates."
            local untilAt = retryAt[name]
            task.delay(30, function()
                if retryAt[name] == untilAt then Env.requestIssues[name] = nil end
            end)
        end
        if pending[name] == work then pending[name] = nil end
    end)
    local deadline = os.clock() + 15
    while not work.done and not Env.stopped and os.clock() < deadline do task.wait(0.05) end
    Env.elevate()
    if Env.stopped then return false, "hub unloaded" end
    if not work.done then
        work.timedOut = true
        Env.requestIssues[name] = "No reply yet; duplicate requests are paused."
        return false, "request timed out; its result is not yet known"
    end
    Env.requestIssues[name] = nil
    return table.unpack(work.result, 1, work.result.n)
end

-- The local player's saved data as the game's client sees it: Env.data("coins") -> 490.
-- Nil when the value is not there (yet).
function Env.data(key)
    local ok, value = Env.call(function()
        return Env.loadModule("PlayerData").client[key]()
    end)
    if ok then return value end
    return nil
end

-- A ball's English name (roleIds are the game's Chinese ids, e.g. "刀片球" -> "Blade Ball").
function Env.ballName(roleId)
    local ok, ball = pcall(function()
        return Env.loadModule("Config").ball.byCnId[roleId]
    end)
    return ok and ball and ball.displayName or tostring(roleId)
end

return Env
end
__modules["core/fusion"] = function(use) -- src/games/ballvsball/core/fusion.luau
-- October 2026: rarity fusion takes ten Classic balls; form fusion takes six matching copies.
-- Keep tradeability groups separate so automatic fusion cannot bind a tradable copy's result.
local Env = use("core/env")
local Fusion = {}

function Fusion.requiredCount(mode)
    if mode == nil or mode == "Higher rarity" then
        return 10
    elseif mode == "Shiny" or mode == "Rainbow" then
        return 6
    end
end

function Fusion.kind(item)
    if item.serial ~= nil then
        return "Rainbow"
    end
    local kills
    if type(item.metadata) == "table" then
        kills = item.metadata.killCount
    end
    if kills == nil then
        kills = item.killCount
    end
    if kills == nil then
        return "Classic"
    end
    if type(kills) == "number" and kills >= 0 and kills < math.huge and kills % 1 == 0 then
        return "Shiny"
    end
    return nil -- malformed kill metadata must not turn a special copy into a Classic material
end

function Fusion.nextBatch(items, equipment, maxRating, reserved, allowedBall, mode)
    mode = mode or "Higher rarity"
    local required = Fusion.requiredCount(mode)
    if not required then
        return nil
    end
    reserved = reserved or {}
    local materialKind = mode == "Rainbow" and "Shiny" or "Classic"
    local equipped = {}
    for _, value in pairs(type(equipment) == "table" and equipment or {}) do
        local id = type(value) == "table" and (value.id or value.instanceId) or value
        if type(id) == "string" then
            equipped[id] = true
        end
    end
    local groups = {}
    for id, item in pairs(type(items) == "table" and items or {}) do
        if type(id) == "string" and type(item) == "table" and item.itemType == "Ball"
            and type(item.itemId) == "string" and item.ownerUserId == Env.LocalPlayer.UserId
            and Fusion.kind(item) == materialKind and (mode ~= "Higher rarity" or item.canFusion == true)
            and not equipped[id] and not reserved[id]
            and (item.locks == nil or (type(item.locks) == "table" and next(item.locks) == nil)) then
            local ball = Env.loadModule("Config").ball.byCnId[item.itemId]
            if ball and type(ball.rating) == "number" and ball.rating <= maxRating
                and (not allowedBall or allowedBall(item.itemId)) then
                local key = item.itemId .. (item.tradable == true and ":tradable" or ":bound")
                local group = groups[key]
                if not group then
                    group = { ballId = item.itemId, rating = ball.rating, key = key, ids = {} }
                    groups[key] = group
                end
                group.ids[#group.ids + 1] = id
            end
        end
    end
    local candidates = {}
    for _, group in pairs(groups) do
        if #group.ids > required then -- retain one copy of each ball/tradability group
            candidates[#candidates + 1] = group
        end
    end
    table.sort(candidates, function(a, b)
        return a.rating < b.rating or (a.rating == b.rating and a.key < b.key)
    end)
    local group = candidates[1]
    if not group then
        return nil
    end
    table.sort(group.ids)
    return table.move(group.ids, 2, required + 1, 1, {}), group.ballId
end

return Fusion
end
__modules["core/limits"] = function(use) -- src/games/ballvsball/core/limits.luau
-- How many duel coins are left today and this week. Duels pay nothing once either cap is reached
-- (the game's config: misc.coinsLimit, 6,000 a day and 30,000 a week at the time of writing).
-- The saved counters only count for the day/week key they were written under, the same way the
-- game's DuelCoinLimitService reads them.

local Env = use("core/env")

local Limits = {}

local function limitsConfig()
    local ok, limits = pcall(function()
        return Env.loadModule("Config").misc.coinsLimit
    end)
    return ok and type(limits) == "table" and limits or {}
end

-- { day, dayMax, week, weekMax, capped } (a max is nil when the game has no such cap).
-- The whole lookup is optional: a place without TimeService reports no progress rather than
-- throwing out of the panels and the duel loop that call this every half second.
function Limits.coins()
    local config = limitsConfig()
    local saved = Env.data("duelCoinLimit") or {}
    local dayMax, weekMax = config["每日金币上限"], config["每周金币上限"]
    local okDay, dayKey = Env.call(function()
        return Env.loadModule("TimeService").getDayKey(0, config["每日重置时间"])
    end)
    local okWeek, weekKey = Env.call(function()
        return Env.loadModule("TimeService").getWeekKey(0, config["每周重置时间"], config["每周重置日期"])
    end)
    local day = okDay and saved.dailyKey == dayKey and saved.dailyEarned or 0
    local week = okWeek and saved.weeklyKey == weekKey and saved.weeklyEarned or 0
    local capped = (type(dayMax) == "number" and day >= dayMax) or (type(weekMax) == "number" and week >= weekMax)
    return { day = day, dayMax = dayMax, week = week, weekMax = weekMax, capped = capped == true }
end

return Limits
end
__modules["core/match"] = function(use) -- src/games/ballvsball/core/match.luau
-- What the server tells us about our table: its state, the ball and upgrade offers, and the
-- replays of this match.
--
-- A match is rounds of Picking (30s to choose one of 3 offered balls), Aiming (30s to set the
-- launch direction) and Playing (the server simulates the battle and streams a replay). Each
-- player has 3 hp and a lost round costs 1. Battles are deterministic: the replay's seed, balls and
-- directions reproduce the result exactly (see core/sim), and round r's seed is round 1's seed
-- plus (r - 1) * 1009. So once round 1 has been replayed, every later round's seed is known while
-- we still choose.

local Env = use("core/env")
local Life = use("shared/life")

local SEED_STEP = 1009

local Match = {
    tableModel = nil,
    tableId = nil,
    state = nil, -- the latest DuelTableState of our table
    slot = nil, -- our key in state.players ("Blue", "Yellow", "Blue1"...)
    left = false, -- a state showed our table, or every table, without us
    offer = nil, -- the latest ball offer: { offer = {roleIds}, selectPrice, rerollPrice, at }
    selectList = nil, -- the free pick's list: { roleIds, at }
    weeklyFreeRoleIds = {}, -- server-provided weekly choices for this match; never infer owned items
    upgradeOffer = nil, -- { offer = { { kind, id } }, at }
    ballLocked = nil, -- { roleId, at }
    aimToken = nil, -- a new table each time Aiming starts
    aimStartedAt = 0, -- os.clock() when it did
    aimLocked = nil, -- { direction, at }
    teammateAim = nil, -- 2v2: { userId, direction, at } as the teammate drags their aim
    replays = {}, -- this match's replays by round
    lastReplay = nil,
    capped = false, -- the server said today's duel coins are used up
    status = nil, -- what auto duel is doing (set by features/duel, shown on Home)
    prediction = nil, -- the solver's reasoning for the round in play (set by features/duel)
    history = nil, -- recent rounds and whether their predictions held (set by features/duel)
    session = nil, -- this session's match, round and coin tally (set by features/duel)
}

local listeners = {}

function Match.phase()
    return Match.state and Match.state.state or nil
end

-- Bind independently so one missing optional event cannot prevent all match tracking. The
-- connector retries after replication and disconnects a replaced remote before rebinding.
--
-- Exported because binding a remote at module load means a renamed or absent one errors out of
-- the whole feature on the way up: a hub that loses the coin tally should not also lose auto duel.
function Match.listen(name, fn, unreliable)
    local current, connection
    Life.loop("remote:" .. name, 5, function()
        if connection and connection.Connected and current and current.Parent then return end
        if connection then connection:Disconnect() end
        current = unreliable and Env.unreliable(name) or Env.event(name)
        connection = Life.connect(current.OnClientEvent, fn, "match:" .. name)
    end)
end
local listen = Match.listen

-- fn(replay, won) after each replay of our table. `won` is true, false, or nil for a draw.
function Match.onRound(fn)
    listeners[#listeners + 1] = fn
end

local function hasMe(state)
    local players = type(state) == "table" and state.players
    if type(players) ~= "table" then
        return nil
    end
    for slot, player in pairs(players) do
        if type(player) == "table" and player.userId == Env.LocalPlayer.UserId then
            return slot
        end
    end
    return nil
end

local function newMatch()
    table.clear(Match.replays)
    table.clear(Match.weeklyFreeRoleIds)
    Match.lastReplay = nil
    Match.offer, Match.selectList, Match.upgradeOffer = nil, nil, nil
    Match.ballLocked, Match.aimLocked = nil, nil
    Match.aimToken, Match.teammateAim = nil, nil
end

local function applyState(state)
    local slot = hasMe(state)
    if not slot then
        return false
    end
    if state.tableId ~= Match.tableId or (state.state == "Countdown" and Match.phase() ~= "Countdown") then
        newMatch()
    end
    -- A fresh token each time the table enters Aiming, so each round is aimed once.
    if state.state == "Aiming" and (Match.phase() ~= "Aiming" or Match.aimToken == nil) then
        Match.aimToken, Match.aimLocked, Match.teammateAim = {}, nil, nil
        Match.aimStartedAt = os.clock()
    end
    Match.tableId = state.tableId
    if typeof(state.table) == "Instance" then
        Match.tableModel = state.table
    end
    Match.state, Match.slot, Match.left = state, slot, false
    return true
end

-- The server only sends states when a table changes, so there can be long quiet stretches (a
-- whole battle): being seated is decided by what the states say, never by how long ago one came.
listen("DuelTableState", function(payload)
    if type(payload) ~= "table" then
        return
    end
    if payload.table then
        if not applyState(payload) and payload.tableId == Match.tableId then
            Match.left = true
        end
        return
    end
    if type(payload.tables) ~= "table" then
        return
    end
    local found = false
    for _, state in pairs(payload.tables) do
        found = applyState(state) or found
    end
    -- A full snapshot (every table) without us: we are not at any table.
    if not found and Match.state then
        Match.left = true
    end
end)

-- Offers and locks are only sent to the players at the table, so they are ours.
local function stamp(payload)
    local copy = table.clone(type(payload) == "table" and payload or {})
    copy.at = os.clock()
    copy.revision = 0
    return copy
end

local function updateWeeklyFree(payload)
    if type(payload) ~= "table" or type(payload.weeklyFreeRoleIds) ~= "table" then
        return
    end
    table.clear(Match.weeklyFreeRoleIds)
    for _, id in ipairs(payload.weeklyFreeRoleIds) do
        if type(id) == "string" then
            Match.weeklyFreeRoleIds[id] = true
        end
    end
end

function Match.isWeeklyFree(roleId)
    return Match.weeklyFreeRoleIds[roleId] == true
end

listen("DuelTableBallOffer", function(model, payload)
    if typeof(model) ~= "Instance" or type(payload) ~= "table" then return end
    -- The first offer of a match is not a reselect: whatever we saw before belongs to another match
    -- (even at the same table), and its seed must not be used.
    if type(payload) == "table" and not payload.isReselect then
        newMatch()
    end
    Match.tableModel = model
    Match.offer, Match.selectList, Match.ballLocked = stamp(payload), nil, nil
    updateWeeklyFree(payload)
end)
-- Keep the offer's identity and original deadline. A reroll is a revision of that offer,
-- not another picking window. Failed replies also release the response wait.
local function rerolled(model, payload, offer)
    if not Life.alive or model ~= Match.tableModel or type(payload) ~= "table" or not offer then
        return
    end
    offer.rerollReplyAt = os.clock()
    offer.rerollPending = false
    offer.rerollError = payload.reason
    if payload.ok ~= false and type(payload.offer) == "table" then
        offer.offer = payload.offer
        offer.revision += 1
        updateWeeklyFree(payload)
    end
    for _, key in ipairs({ "rerollPrice", "rerollCurrency", "canReroll", "rerollsRemaining", "freeRerolls" }) do
        if payload[key] ~= nil then
            offer[key] = payload[key]
        end
    end
end
listen("DuelTableBallRerollResult", function(model, payload)
    if Match.phase() == "Picking" and not Match.ballLocked then
        rerolled(model, payload, Match.offer)
    end
end)
listen("DuelTableUpgradeRerollResult", function(model, payload)
    if Match.phase() == "Upgrading" then
        rerolled(model, payload, Match.upgradeOffer)
    end
end)
listen("DuelTableRerollDenied", function(model, reason)
    local offer = Match.phase() == "Picking" and Match.offer or Match.upgradeOffer
    rerolled(model, { ok = false, reason = reason }, offer)
end)
listen("DuelTableBallSelectPurchaseResult", function(model, payload)
    if model == Match.tableModel and type(payload) == "table" and payload.ok ~= false
        and type(payload.roleIds) == "table" and Match.phase() == "Picking" and not Match.ballLocked then
        Match.selectList = stamp(payload)
        if Match.offer then
            Match.offer.selectPending = false
            Match.offer.selectError = nil
        end
        updateWeeklyFree(payload)
    end
end)
listen("DuelTableBallSelectDenied", function(model, reason)
    if model == Match.tableModel and Match.offer then
        Match.offer.selectPending = false
        Match.offer.selectError = reason or "unavailable"
    end
end)
listen("DuelTableBallSelectConfirmDenied", function(model, reason, price)
    if model == Match.tableModel and Match.offer then
        Match.offer.selectConfirmError = reason or "refused"
        if type(price) == "number" then
            Match.offer.selectPrice = price
        end
    end
end)
listen("DuelTableBallLocked", function(model, payload)
    if model == Match.tableModel then
        Match.ballLocked = stamp(payload)
    end
end)
listen("DuelTableBallSelectConfirmed", function(model, payload)
    if model == Match.tableModel then
        Match.ballLocked = stamp(payload)
    end
end)
listen("DuelTableUpgradeOffer", function(model, payload)
    Match.tableModel = model
    Match.upgradeOffer = stamp(payload)
end)
listen("DuelTableUpgradeLocked", function(model)
    if model == Match.tableModel then
        Match.upgradeOffer = nil
    end
end)
listen("DuelTableLaunchLocked", function(model, payload)
    if model == Match.tableModel then Match.aimLocked = stamp(payload) end
end)
-- In 2v2 the server relays the teammate's aim while they drag it: (table, their userId, direction).
listen("DuelTableAimPreview", function(model, userId, direction)
    if model == Match.tableModel and typeof(direction) == "Vector2" then
        Match.teammateAim = { userId = userId, direction = direction, at = os.clock() }
    end
end, true)
listen("DuelCoinLimitReached", function()
    Match.capped = true
end)

listen("DuelTableReplayStream", function(replay)
    if type(replay) ~= "table" or replay.tableId ~= Match.tableId or type(replay.round) ~= "number" then
        return
    end
    Match.replays[replay.round] = replay
    Match.lastReplay = replay
    local me = Env.LocalPlayer.UserId
    local won = nil
    if replay.isDraw ~= true then
        won = table.find(type(replay.winnerUserIds) == "table" and replay.winnerUserIds or {}, me) ~= nil
            or replay.winnerUserId == me
    end
    for index, fn in ipairs(listeners) do
        Life.spawn("match:round:" .. index, fn, replay, won)
    end
end)

local function canReroll(offer, allowDiamonds)
    if not offer or offer.rerollTried or offer.rerollPending or offer.canReroll == false
        or (type(offer.rerollsRemaining) == "number" and offer.rerollsRemaining <= 0) then
        return false
    end
    if type(offer.freeRerolls) == "number" and offer.freeRerolls > 0 then
        return true
    end
    -- The shipped client hides a zero-price reroll; only explicit metadata enables a free one.
    local price = offer.rerollPrice
    if price == 0 then
        return offer.canReroll == true
    end
    -- DuelChoice handles an insufficient reroll by opening DiamondTopUpService. Rerolls
    -- without currency metadata are priced in diamonds, so coins cannot fund them.
    local currency = offer.rerollCurrency or "diamonds"
    if currency == "diamonds" and not allowDiamonds then
        return false
    end
    return (currency == "coins" or currency == "diamonds") and type(price) == "number" and price > 0
        and (tonumber(Env.data(currency)) or 0) >= price
end

function Match.canRerollBall(allowDiamonds)
    return Match.seated() and Match.phase() == "Picking" and not Match.ballLocked and canReroll(Match.offer, allowDiamonds)
end

function Match.canRerollUpgrade(allowDiamonds)
    return Match.seated() and Match.phase() == "Upgrading" and canReroll(Match.upgradeOffer, allowDiamonds)
end

-- True while we sit at a table whose match is not over.
function Match.seated()
    return Match.state ~= nil and not Match.left and Match.phase() ~= "Finished"
end

function Match.teamSize()
    return Match.state and Match.state.teamSize or 1
end

-- Everyone at our table: { { userId, team, index, roleId, me, teammate } }, from the latest state.
-- roleId is only there once balls are locked (Aiming on). `index` is the seat within the team
-- (always 1 in a 1v1).
function Match.players()
    local out = {}
    local players = Match.state and Match.state.players
    local mine = players and players[Match.slot]
    for slot, player in pairs(type(players) == "table" and players or {}) do
        if type(player) == "table" then
            local team = player.team or slot
            out[#out + 1] = {
                userId = player.userId,
                team = team,
                index = player.teamIndex or 1,
                roleId = player.roleId,
                me = slot == Match.slot,
                teammate = slot ~= Match.slot and mine ~= nil and team == (mine.team or Match.slot),
            }
        end
    end
    return out
end

-- Our team's name ("Blue" or "Yellow"): what the simulation reports as the winner.
function Match.team()
    local players = Match.state and Match.state.players
    local mine = players and players[Match.slot]
    return mine and mine.team or Match.slot
end

function Match.hp(player)
    local state = Match.state
    if not (state and type(state.hp) == "table" and player) then
        return nil
    end
    return state.hp[player.userId] or state.hp[tostring(player.userId)]
end

-- The round being chosen or aimed right now (1 before this match's first replay).
function Match.round()
    local replay = Match.lastReplay
    if not replay or type(replay.round) ~= "number" then
        return 1
    end
    local phase = Match.phase()
    local playing = phase == "Playing" or phase == "Finished"
    return replay.round + (playing and 0 or 1)
end

-- Our hp and the lowest hp on the other team, which is what decides whether a round is worth a
-- risk: a loss at 1 hp ends the match, and so does a win against someone on their last one.
function Match.stakes()
    local ours, theirs
    for _, player in ipairs(Match.players()) do
        local hp = tonumber(Match.hp(player))
        if hp then
            if player.me then
                ours = hp
            elseif not player.teammate then
                theirs = math.min(theirs or math.huge, hp)
            end
        end
    end
    return ours, theirs
end

-- The seed of the round being chosen now, or nil before this match's first replay.
function Match.nextSeed()
    local replay = Match.lastReplay
    if not replay or type(replay.seed) ~= "number" then
        return nil
    end
    return replay.seed + SEED_STEP
end

-- A replay keeps balls and directions by team: one value in a 1v1, a list by seat in team modes.
function Match.forPlayer(byTeam, team, index)
    local value = type(byTeam) == "table" and byTeam[team]
    if type(value) == "table" then
        return value[index]
    end
    return value
end

-- The ball and direction `player` (from Match.players) used last round, or nil.
function Match.lastPlay(player)
    local options = Match.lastReplay and Match.lastReplay.replayOptions
    if not options then
        return nil, nil
    end
    return Match.forPlayer(options.selectedRoles, player.team, player.index),
        Match.forPlayer(options.initialDirections, player.team, player.index)
end

-- Whether `player` launched in the same direction in this match's last two rounds: true or false,
-- or nil with fewer than two rounds played. Someone who re-aims is not worth predicting.
function Match.keepsAim(player)
    local last = Match.lastReplay
    local before = last and Match.replays[last.round - 1]
    if not before then
        return nil
    end
    local a = Match.forPlayer((last.replayOptions or {}).initialDirections, player.team, player.index)
    local b = Match.forPlayer((before.replayOptions or {}).initialDirections, player.team, player.index)
    return typeof(a) == "Vector2" and typeof(b) == "Vector2" and (a - b).Magnitude < 1e-3
end

-- The arena the round is fought in: nil for the 1v1 board, the 2v2 board's layout otherwise.
function Match.arena()
    local options = Match.lastReplay and Match.lastReplay.replayOptions
    if options then
        return options.arena
    end
    if Match.teamSize() > 1 and Match.tableModel then
        local ok, arena = Env.call(function()
            return Env.loadModule("ArenaOverride").buildArenaData(Env.loadModule("GameModeRegistry").getForTable(Match.tableModel))
        end)
        return ok and arena or nil
    end
    return nil
end

Life.onCleanup(function()
    newMatch()
    table.clear(listeners)
    Match.tableModel, Match.tableId, Match.state, Match.slot = nil, nil, nil, nil
    Match.left, Match.status = true, "Off"
    Match.prediction, Match.history, Match.session = nil, nil, nil
end)

return Match
end
__modules["core/profile"] = function(use) -- src/games/ballvsball/core/profile.luau
-- What we have learned about the people we duel, kept between sessions.
--
-- The aim solver needs one number from the opponent: how likely they are to launch where they
-- launched last round. The hub used to assume 0.6, or 0.8 after two matching rounds, for everyone.
-- That is a reasonable guess and it is wrong for most individual players: an afk account is re-sent
-- its old aim by the server every round and never deviates, while someone actually playing re-aims
-- constantly. Measuring it per player and remembering it turns a constant into evidence.
--
-- Ball choices are recorded for the same reason. The pick phase simulates our offered balls against
-- what the opponent played last round, which is only a good assumption for someone who keeps
-- playing the same ball -- and now we know who does.
--
-- Nothing here is required. Without file access it is a memory-only model that starts fresh each
-- session, which is still better than a constant.

local Env = use("core/env")
local Life = use("shared/life")

local Profile = {}

local FOLDER = "SlopixHub/BallVsBall"
local FILE = FOLDER .. "/opponents.json"
local SAVE_INTERVAL = 45
local MAX_ENTRIES = 400

-- The prior, as a count of imaginary rounds: a player seen once does not get a 0% or 100% model.
-- 3 of 5 kept starts everyone at the 0.6 the hub used to assume for all players.
local PRIOR_KEPT, PRIOR_SEEN = 3, 5

local players = {}
local dirty, savedAt = false, os.clock()

local function entry(userId)
    local key = tostring(userId)
    local found = players[key]
    if not found then
        found = { kept = 0, seen = 0, rounds = 0, won = 0, lost = 0, balls = {}, at = os.time() }
        players[key] = found
    end
    return found
end

-- Load ---------------------------------------------------------------------------------------

local function decode(body)
    if type(body) ~= "string" or body == "" then
        return nil
    end
    local ok, decoded = pcall(function()
        return Env.HttpService:JSONDecode(body)
    end)
    Env.elevate()
    return ok and type(decoded) == "table" and decoded or nil
end

-- A saved file is data we wrote, but it is still a file on disk that anything could have edited,
-- so every field is checked before it reaches the solver's weights.
local function sanitise(raw)
    local out = {}
    for key, value in pairs(type(raw) == "table" and raw or {}) do
        if type(key) == "string" and type(value) == "table" then
            local seen = tonumber(value.seen) or 0
            local kept = tonumber(value.kept) or 0
            if seen >= 0 and seen < math.huge and kept >= 0 and kept <= seen then
                local balls = {}
                for ball, count in pairs(type(value.balls) == "table" and value.balls or {}) do
                    local number = tonumber(count)
                    if type(ball) == "string" and number and number > 0 and number < math.huge then
                        balls[ball] = math.floor(number)
                    end
                end
                out[key] = {
                    kept = math.floor(kept),
                    seen = math.floor(seen),
                    rounds = math.max(0, math.floor(tonumber(value.rounds) or 0)),
                    won = math.max(0, math.floor(tonumber(value.won) or 0)),
                    lost = math.max(0, math.floor(tonumber(value.lost) or 0)),
                    balls = balls,
                    at = math.max(0, math.floor(tonumber(value.at) or 0)),
                }
            end
        end
    end
    return out
end

local files = Env.files
local canSave = files.writefile ~= nil and files.isfolder ~= nil and files.makefolder ~= nil

do
    local ok, body = pcall(function()
        return Env.canCache and files.isfile(FILE) and files.readfile(FILE)
    end)
    Env.elevate()
    players = ok and sanitise(decode(body)) or {}
end

-- Save ---------------------------------------------------------------------------------------

-- Oldest first, so a long-lived file keeps the people still being played against.
local function trim()
    local keys = {}
    for key in pairs(players) do
        keys[#keys + 1] = key
    end
    if #keys <= MAX_ENTRIES then
        return
    end
    table.sort(keys, function(a, b)
        return (players[a].at or 0) > (players[b].at or 0)
    end)
    for index = MAX_ENTRIES + 1, #keys do
        players[keys[index]] = nil
    end
end

local function write()
    if not canSave or not dirty then
        return
    end
    dirty, savedAt = false, os.clock()
    trim()
    local ok = pcall(function()
        local path = ""
        for part in FOLDER:gmatch("[^/]+") do
            path = path == "" and part or path .. "/" .. part
            if not files.isfolder(path) then
                files.makefolder(path)
            end
        end
        files.writefile(FILE, Env.HttpService:JSONEncode(players))
    end)
    Env.elevate()
    if not ok then
        canSave = false -- a filesystem that refuses once is not asked again every 45 seconds
    end
end

Life.loop("duel:profile-save", SAVE_INTERVAL, function()
    if dirty and os.clock() - savedAt >= SAVE_INTERVAL then
        write()
    end
end)

-- Record -------------------------------------------------------------------------------------

-- One round of one opponent. `kept` is whether they launched where we assumed (nil when there was
-- no previous round to compare against, which teaches us nothing either way).
function Profile.observe(userId, kept, roleId, won)
    if type(userId) ~= "number" then
        return
    end
    local found = entry(userId)
    found.rounds += 1
    found.at = os.time()
    if kept ~= nil then
        found.seen += 1
        found.kept += kept and 1 or 0
    end
    if type(roleId) == "string" then
        found.balls[roleId] = (found.balls[roleId] or 0) + 1
    end
    if won == true then
        found.lost += 1 -- we won, so they lost
    elseif won == false then
        found.won += 1
    end
    dirty = true
end

-- Read ---------------------------------------------------------------------------------------

-- How likely `userId` is to launch where they launched last round, as a probability the solver can
-- weight its first column by. Everyone starts at the old 0.6 assumption and moves from there.
function Profile.keepRate(userId)
    local found = players[tostring(userId)]
    local kept = (found and found.kept or 0) + PRIOR_KEPT
    local seen = (found and found.seen or 0) + PRIOR_SEEN
    return kept / seen
end

-- The whole table's keep rate, which is what a scenario weight actually needs: one opponent who
-- re-aims is enough to make the "everyone kept their aim" column unlikely.
function Profile.tableKeepRate(opponents)
    local rate = 1
    local counted = 0
    for _, player in ipairs(opponents) do
        if not player.me and not player.teammate then
            rate *= Profile.keepRate(player.userId)
            counted += 1
        end
    end
    return counted > 0 and rate or PRIOR_KEPT / PRIOR_SEEN
end

-- The ball `userId` plays most often, and how often, or nil when we have not seen them pick.
function Profile.likelyBall(userId)
    local found = players[tostring(userId)]
    if not found then
        return nil
    end
    local best, bestCount, total = nil, 0, 0
    for ball, count in pairs(found.balls) do
        total += count
        if count > bestCount then
            best, bestCount = ball, count
        end
    end
    if not best or total == 0 then
        return nil
    end
    return best, bestCount / total
end

-- A line per opponent for the Intel tab. `name` is what to call them (their user id otherwise).
function Profile.describe(player, name)
    local found = players[tostring(player.userId)]
    local keep = math.floor(Profile.keepRate(player.userId) * 100 + 0.5)
    name = name or tostring(player.userId)
    if not found or found.rounds == 0 then
        return string.format("%s: new opponent, assuming %d%% aim repeat", name, keep)
    end
    local ball, share = Profile.likelyBall(player.userId)
    local favourite = ball and string.format(", favours %s (%d%%)", Env.ballName(ball),
        math.floor(share * 100 + 0.5)) or ""
    return string.format("%s: %d rounds, repeats aim %d%% (%d/%d), %d-%d against you%s",
        name, found.rounds, keep, found.kept, found.seen, found.won, found.lost, favourite)
end

function Profile.count()
    local total = 0
    for _ in pairs(players) do
        total += 1
    end
    return total
end

function Profile.forget()
    table.clear(players)
    dirty = true
    write()
end

Life.onCleanup(write)

return Profile
end
__modules["core/sim"] = function(use) -- src/games/ballvsball/core/sim.luau
-- Runs the game's own battle simulation (BattleDemo.BattleSimulation) to see how a round would
-- end. It uses the game's deterministic inputs and yields between groups of simulation steps
-- so a slower client can still draw frames, handle events, and stop an obsolete search.
--
-- Balls and directions are keyed by team, as in the server's replays: { Blue = "刀片球" } in a 1v1,
-- { Blue = { "刀片球", "蛇球" } } (by seat) in a 2v2, which also needs the 2v2 arena.

local Env = use("core/env")
local Life = use("shared/life")

local Sim = {}

-- Only these two decide a battle. ArenaOverride and GameModeRegistry shape the 2v2 board, and
-- both callers already fall back to the 1v1 config when they are missing, so a place that does
-- not ship them must not hold Smart aim off for the whole session.
local REQUIRED = { "BattleConfig", "BattleSimulation" }
local OPTIONAL = { "ArenaOverride", "GameModeRegistry" }

-- Reads the module cache rather than a flag this file sets, so readiness follows what is actually
-- loaded instead of whether the loader loop below has had its turn yet.
function Sim.ready()
    for _, name in ipairs(REQUIRED) do
        if rawget(Env.Game, name) == nil then
            return false
        end
    end
    return true
end

local optionalTries = {}
Life.loop("duel:simulation-modules", 5, function()
    if not Sim.ready() then
        for _, name in ipairs(REQUIRED) do
            Env.loadModule(name)
        end
        return
    end
    -- The arena modules only matter in 2v2. A few attempts, then they are left alone: each miss
    -- costs this thread a 30-second wait, and the 1v1 board works without them.
    for _, name in ipairs(OPTIONAL) do
        if rawget(Env.Game, name) == nil and (optionalTries[name] or 0) < 3 then
            optionalTries[name] = (optionalTries[name] or 0) + 1
            pcall(Env.loadModule, name)
        end
    end
end)

local SCORE = { win = 1, draw = 0.5, loss = 0 }
local FAST_WIN_BONUS = 0.01 -- tie-break: a quicker win is a safer one

-- Giving a frame back costs ~16ms of a think budget measured in seconds, so yielding once per
-- simulation spent more time waiting for the next frame than simulating. Every search yields off
-- one shared slice clock instead.
local SLICE = 0.008
local sliceStart = os.clock()

function Sim.breathe()
    if os.clock() - sliceStart >= SLICE then
        task.wait()
        Env.elevate()
        sliceStart = os.clock()
    end
    return Life.alive
end

-- The shipped step() has no scratch-buffer argument. Keep its dispatch order, but reuse the
-- event container for this simulation only. Helpers still emit their event records; suppressing
-- those would require replacing combat code and could change deterministic results. No shared
-- module, table.insert, or live replay is patched.
local function headlessStep(self, dt)
    local events, state = self._headlessEvents, self.state
    table.clear(events)
    if state.finished then
        return state
    end
    state.elapsed += dt
    if self.multiEntityMode then
        self:_stepMultiEntity(dt, events)
    else
        local blue, yellow = state.balls.Blue, state.balls.Yellow
        self:_updateBallSkill(blue, yellow, dt, events)
        self:_updateBallSkill(yellow, blue, dt, events)
        if blue.vampireStateRemaining > 0 and type(blue.vampireAttachedTargetId) == "string"
            and blue.vampireAttachedTargetId == yellow.id then
            self:_moveAttachedPair(blue, yellow, dt, events)
            self:_handlePoisonSpikeCollisions(blue, events)
            self:_handlePoisonSpikeCollisions(yellow, events)
        elseif yellow.vampireStateRemaining > 0 and type(yellow.vampireAttachedTargetId) == "string"
            and yellow.vampireAttachedTargetId == blue.id then
            self:_moveAttachedPair(yellow, blue, dt, events)
            self:_handlePoisonSpikeCollisions(blue, events)
            self:_handlePoisonSpikeCollisions(yellow, events)
        else
            self:_moveBall(blue, dt, events)
            if not ((blue.traits.ChessPath and blue.traits.ChessPath.isActive)
                or (blue.traits.OnePunch and blue.traits.OnePunch.phase == "Dash")) then
                self:_handleWallBounce(blue, events)
                self:_handlePoisonSpikeCollisions(blue, events)
            end
            self:_moveBall(yellow, dt, events)
            if not ((yellow.traits.ChessPath and yellow.traits.ChessPath.isActive)
                or (yellow.traits.OnePunch and yellow.traits.OnePunch.phase == "Dash")) then
                self:_handleWallBounce(yellow, events)
                self:_handlePoisonSpikeCollisions(yellow, events)
            end
        end
        self:_updateThomas(blue, dt, events)
        self:_updateThomas(yellow, dt, events)
        self:_handleBallCollision(events)
        self:_handleDiceCollisions(events)
    end
    self:_refreshAllBuffIndicators()
    self:_updateWinner(events)
    return state
end

-- The battle config for an arena (nil: the 1v1 board), resolved once per board.
local configs = {}
local function battleConfig(arena)
    local key = arena and arena.boardAssetName or "default"
    if not configs[key] then
        local ok, resolved = Env.call(Env.loadModule("ArenaOverride").resolveConfig, Env.loadModule("BattleConfig"), arena)
        configs[key] = ok and resolved or Env.loadModule("BattleConfig")
    end
    return configs[key]
end

-- The longest a battle can run on this board, for scoring a fast win.
function Sim.maxDuration(arena)
    local ok, duration = pcall(function()
        return battleConfig(arena).replay.maxDuration
    end)
    return ok and type(duration) == "number" and duration > 0 and duration or 1
end

-- A battle is a pure function of (seed, balls, directions, stats, traits, board), and the same
-- combination comes up again and again: the coarse and refine passes share scenarios, the ball
-- search re-tests the same opponents, and the matrix solver re-reads rows it has already filled.
local CACHE_LIMIT = 4096
local cache, cacheCount = {}, 0

local function keyOf(value, out)
    local kind = typeof(value)
    if kind == "Vector2" then
        -- Rounded to the tolerance directions are compared by everywhere else (1e-3).
        out[#out + 1] = string.format("v%.4f,%.4f", value.X, value.Y)
    elseif kind == "table" then
        local keys = {}
        for key in pairs(value) do
            keys[#keys + 1] = key
        end
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)
        out[#out + 1] = "{"
        for _, key in ipairs(keys) do
            out[#out + 1] = tostring(key)
            out[#out + 1] = "="
            keyOf(value[key], out)
            out[#out + 1] = ";"
        end
        out[#out + 1] = "}"
    else
        out[#out + 1] = tostring(value)
    end
    return out
end

-- The board goes in by name: resolveConfig already keys its own cache that way, and serialising a
-- whole arena layout per simulation would cost more than the lookup saves.
local function cacheKey(seed, roles, directions, statLevels, traits, arena)
    local out = { tostring(seed), "|", arena and tostring(arena.boardAssetName) or "default", "|" }
    keyOf(roles, out)
    out[#out + 1] = "|"
    keyOf(directions, out)
    out[#out + 1] = "|"
    keyOf(statLevels, out)
    out[#out + 1] = "|"
    keyOf(traits, out)
    return table.concat(out)
end

function Sim.clearCache()
    table.clear(cache)
    cacheCount = 0
end

-- Plays one battle out. Returns the winning team ("Blue", "Yellow" or "Draw") and its length in
-- seconds, or nil and the error.
function Sim.run(seed, roles, directions, statLevels, traits, arena, deadline, valid)
    if not Sim.ready() then return nil, "simulation modules are still loading" end
    local key = cacheKey(seed, roles, directions, statLevels, traits, arena)
    local hit = cache[key]
    if hit then
        return hit[1], hit[2]
    end
    local cfg = battleConfig(arena)
    local ok, winner, elapsed = Env.call(function()
        local sim = Env.loadModule("BattleSimulation").new(cfg, seed, roles, traits, statLevels, directions)
        sim._headlessEvents = {}
        sim.step = headlessStep
        local dt = cfg.replay.fixedDt
        assert(type(dt) == "number" and dt > 0 and dt < math.huge, "invalid simulation time step")
        local duration = cfg.replay.maxDuration
        assert(type(duration) == "number" and duration > 0 and duration < math.huge, "invalid simulation duration")
        for step = 1, math.ceil(duration / dt) do
            if sim:step(dt).finished then
                break
            end
            if step % 32 == 0 and os.clock() - sliceStart >= SLICE then
                task.wait()
                Env.elevate()
                sliceStart = os.clock()
                if not Life.alive or (deadline and os.clock() >= deadline) or (valid and not valid()) then
                    return nil, "simulation cancelled"
                end
            end
        end
        local state = sim:getState()
        table.clear(sim._headlessEvents)
        return state.finished and state.winner or "Draw", state.elapsed
    end)
    if not ok then
        return nil, winner
    end
    -- A cancelled run reports no winner; only a finished battle is a fact worth keeping.
    if winner == nil then
        return nil, elapsed
    end
    if cacheCount >= CACHE_LIMIT then
        Sim.clearCache()
    end
    cache[key] = { winner, elapsed }
    cacheCount += 1
    return winner, elapsed
end

-- `count` launch directions spread evenly around the circle.
function Sim.directions(count)
    local out = {}
    for index = 0, count - 1 do
        local angle = index / count * math.pi * 2
        out[#out + 1] = Vector2.new(math.cos(angle), math.sin(angle))
    end
    return out
end

local random = Random.new()

function Sim.randomDirection()
    local angle = random:NextNumber(0, math.pi * 2)
    return Vector2.new(math.cos(angle), math.sin(angle))
end

function Sim.randomSeed()
    return math.floor(workspace:GetServerTimeNow() * 1000) + random:NextInteger(-600000, 600000)
end

-- The plain result for `team`: 1 win, 0.5 draw, 0 loss. A draw costs no hp, so it really is worth
-- half a win and must never be lumped in with a loss.
function Sim.outcome(winner, team)
    if winner == team then
        return SCORE.win
    end
    return winner == "Draw" and SCORE.draw or SCORE.loss
end

-- How good one outcome is for `team`, plus a little for winning fast.
function Sim.score(winner, elapsed, team, maxDuration)
    local base = Sim.outcome(winner, team)
    if base ~= SCORE.win then
        return base
    end
    return base + FAST_WIN_BONUS * (1 - math.clamp((elapsed or 0) / maxDuration, 0, 1))
end

local score = Sim.score

-- The coarse pass gets this share of the think time; the rest refines around its best directions,
-- since a winning window can be narrower than the gap between two coarse directions.
local COARSE_SHARE = 0.65
local REFINE_TOP = 3
local REFINE_STEPS = { -1 / 3, -1 / 6, 1 / 6, 1 / 3 } -- of the gap between coarse directions

local function rotate(direction, angle)
    local c, s = math.cos(angle), math.sin(angle)
    return Vector2.new(direction.X * c - direction.Y * s, direction.X * s + direction.Y * c)
end

-- Tries every direction against each scenario in turn until the deadline (scenario 1 may run on to
-- `firstDeadline`). A scenario only counts once every direction has been tried against it, so the
-- directions stay comparable. Returns the weighted total per direction, how many scenarios
-- completed, and who wins scenario 1 with each.
local function evaluate(spec, directions, scenarios, deadline, firstDeadline)
    local maxDuration = Sim.maxDuration(spec.arena)
    local totals, rates, completed, firstWinners = {}, {}, 0, {}
    for scenarioIndex, scenario in ipairs(scenarios) do
        local results, outcomes = {}, {}
        local stopAt = scenarioIndex == 1 and (firstDeadline or deadline) or deadline
        for index, direction in ipairs(directions) do
            if not Life.alive or (spec.valid and not spec.valid()) or os.clock() > stopAt then
                break
            end
            local winner, elapsed = Sim.run(scenario.seed, spec.roles, spec.place(direction, scenario),
                spec.statLevels, spec.traits, spec.arena, stopAt, spec.valid)
            results[index] = winner and score(winner, elapsed, spec.team, maxDuration) or 0
            if not winner then
                return totals, completed, firstWinners, rates -- errors are not predicted losses
            end
            outcomes[index] = Sim.outcome(winner, spec.team)
            if scenarioIndex == 1 then
                firstWinners[index] = winner
            end
            Sim.breathe()
        end
        if #results < #directions then
            break -- out of time: this scenario is incomplete, so it is left out
        end
        for index, value in ipairs(results) do
            totals[index] = (totals[index] or 0) + value * scenario.weight
            rates[index] = (rates[index] or 0) + outcomes[index] * scenario.weight
        end
        completed = scenarioIndex
    end
    return totals, completed, firstWinners, rates
end

-- Finds our best launch direction.
-- spec = {
--   team            -- our team ("Blue" or "Yellow"): the winner we want
--   roles           -- every ball, keyed by team as in a replay
--   place           -- function(ourDirection, scenario) -> every direction, keyed by team
--   directions      -- our coarse candidate directions, evenly spaced (Sim.directions)
--   scenarios       -- { { seed, weight, ... } }, most likely first; `place` reads the rest
--   statLevels, traits, arena -- from the match's last replay (nil in round 1, arena nil in a 1v1)
--   deadline        -- os.clock() by which to answer
-- }
-- A coarse pass over `directions`, then a finer one around its best few, against the scenarios the
-- coarse pass completed. Returns the best direction, its expected score (0..1), how many coarse
-- directions win the first scenario, and who wins the first scenario with the best direction.
function Sim.bestDirection(spec)
    if not ready or not Life.alive then return nil, 0, 0, nil end
    local started = os.clock()
    local coarseDeadline = started + (spec.deadline - started) * COARSE_SHARE
    -- Scenario 1 (the likely one) may use the whole think time; more only fit in the coarse share.
    local totals, completed, winners, rates = evaluate(spec, spec.directions, spec.scenarios, coarseDeadline, spec.deadline)
    if completed == 0 then
        return nil, 0, 0, nil
    end
    local weights = 0
    for index = 1, completed do
        weights += spec.scenarios[index].weight
    end
    local firstWins = 0
    for _, winner in pairs(winners) do
        firstWins += winner == spec.team and 1 or 0
    end

    local best, bestTotal, bestWinner, bestRate = nil, -1, nil, 0
    local order = {}
    for index, total in ipairs(totals) do
        order[#order + 1] = index
        if total > bestTotal then
            best, bestTotal, bestWinner = spec.directions[index], total, winners[index]
            bestRate = rates[index]
        end
    end

    -- Refine: directions between the best coarse ones and their neighbours, scored on the same
    -- scenarios. Kept only if every one of them finishes, so the comparison stays fair.
    table.sort(order, function(a, b)
        return totals[a] > totals[b]
    end)
    local gap = math.pi * 2 / #spec.directions
    local finer = {}
    for rank = 1, math.min(REFINE_TOP, #order) do
        for _, step in ipairs(REFINE_STEPS) do
            finer[#finer + 1] = rotate(spec.directions[order[rank]], step * gap)
        end
    end
    local scenarios = table.move(spec.scenarios, 1, completed, 1, {})
    local fineTotals, fineCompleted, fineWinners, fineRates = evaluate(spec, finer, scenarios, spec.deadline)
    if fineCompleted == completed then
        for index, total in ipairs(fineTotals) do
            if total > bestTotal then
                best, bestTotal, bestWinner = finer[index], total, fineWinners[index]
                bestRate = fineRates[index]
            end
        end
    end
    return best, math.clamp(bestRate / weights, 0, 1), firstWins, bestWinner
end

Life.onCleanup(function()
    table.clear(configs)
    table.clear(optionalTries)
    Sim.clearCache()
end)

return Sim
end
__modules["core/solver"] = function(use) -- src/games/ballvsball/core/solver.luau
-- Solves the aim phase as the game it actually is.
--
-- From round 2 the seed is known exactly (core/match), every ball is locked before aiming starts,
-- and the battle is deterministic. The only thing left unknown is where the others launch. That
-- makes one round a finite two-player zero-sum simultaneous game whose payoff function we can
-- evaluate directly, so instead of guessing one opponent aim and answering it, this builds the
-- payoff matrix: our candidate directions down the rows, the opponent's down the columns.
--
-- Three numbers come out of a row, and they answer different questions:
--   expected  how the row does against the opponent we actually expect (core/profile weights it)
--   worst     the worst any opponent direction can do to it: a floor that holds whatever they pick
--   wins      how many opponent directions it beats outright, i.e. how forgiving the aim is
--
-- Ranking by `expected` alone exploits a predictable opponent but can be punished badly by a
-- surprise. Ranking by `worst` alone is the maximin play: it gives up some wins to never be
-- blown out. `lambda` slides between them, and hp moves it on its own, because the value of a
-- round is not symmetric when someone is one loss from going out.

local Life = use("shared/life")
local Sim = use("core/sim")

local Solver = {}

-- A row has to cover every column in the current comparison set before it can be ranked against
-- another row: a partly filled row has a flattering minimum and a meaningless average.
local function rank(a, b)
    if a.score ~= b.score then
        return a.score > b.score
    end
    if a.worst ~= b.worst then
        return a.worst > b.worst
    end
    return a.wins > b.wins
end

-- Fills columns `from`..`to` of one row. False when the search was cancelled or ran out of time,
-- in which case the row keeps whatever it had and must not be ranked at the new column count.
local function fill(spec, row, from, to)
    for column = from, to do
        if not Life.alive or (spec.valid and not spec.valid()) or os.clock() >= spec.deadline then
            return false
        end
        local scenario = spec.opponents[column]
        local winner, elapsed = Sim.run(spec.seed, spec.roles, spec.place(row.direction, scenario),
            spec.statLevels, spec.traits, spec.arena, spec.deadline, spec.valid)
        if not winner then
            return false -- an error or a cancellation is not a predicted loss
        end
        row.scores[column] = Sim.score(winner, elapsed, spec.team, spec.maxDuration)
        row.outcomes[column] = Sim.outcome(winner, spec.team)
        if column == 1 then
            row.winner = winner
        end
        Sim.breathe()
    end
    return true
end

-- Collapses a row's filled columns into the three numbers, under `lambda`.
local function summarise(row, spec, columns)
    local weighted, weights, worst, wins = 0, 0, math.huge, 0
    for column = 1, columns do
        local weight = spec.opponents[column].weight or 1
        weighted += row.scores[column] * weight
        weights += weight
        worst = math.min(worst, row.outcomes[column])
        wins += row.outcomes[column] >= 1 and 1 or 0
    end
    row.expected = weights > 0 and weighted / weights or 0
    row.worst = worst == math.huge and 0 or worst
    row.wins = wins
    row.columns = columns
    row.score = (1 - spec.lambda) * row.expected + spec.lambda * row.worst
end

local function newRow(direction)
    return { direction = direction, scores = {}, outcomes = {}, expected = 0, worst = 0, wins = 0, score = -1 }
end

-- Evaluates every candidate against columns 1..`columns` and returns the ones that covered them
-- all, best first. `done` is false when the stage was cut short, so the caller keeps the previous
-- stage's answer rather than comparing rows judged on different opponents.
local function stage(spec, candidates, columns)
    local complete, done = {}, true
    for _, row in ipairs(candidates) do
        local from = (row.columns or 0) + 1
        if from > columns then
            summarise(row, spec, columns)
            complete[#complete + 1] = row
        elseif fill(spec, row, from, columns) then
            summarise(row, spec, columns)
            complete[#complete + 1] = row
        else
            done = false
            break
        end
    end
    table.sort(complete, rank)
    return complete, done
end

local function rotate(direction, angle)
    local c, s = math.cos(angle), math.sin(angle)
    return Vector2.new(direction.X * c - direction.Y * s, direction.X * s + direction.Y * c)
end

-- How much weight the floor gets. A round is not worth the same to both sides once someone is one
-- loss from out: at 1 hp a loss ends the match, so the floor matters more than the average; when
-- the opponent is at 1 hp a win ends it, so it is worth reaching for.
local STYLE = { Exploit = 0, Balanced = 0.5, Safe = 1 }

function Solver.lambda(style, ourHp, theirHp)
    local lambda = STYLE[style] or STYLE.Balanced
    if ourHp == 1 then
        lambda += 0.25
    end
    if theirHp == 1 then
        lambda -= 0.2
    end
    return math.clamp(lambda, 0, 1)
end

-- The opponent's candidate directions, as scenarios the caller's `place` can read.
--
-- Column 1 is who we think they are: the aim core/profile expects them to keep. The rest cover
-- what else they could do. With one unknown opponent that space is just the circle, so it is
-- covered evenly and the row minimum becomes a real maximin over that discretisation. With two
-- (a 2v2) the joint space is square and sampling it is the only thing that fits the budget.
function Solver.columns(players, likely, modelled, count)
    local unknown = {}
    for _, player in ipairs(players) do
        if not player.me and not player.teammate then
            unknown[#unknown + 1] = player
        end
    end
    -- An opponent who changed their aim last round has no direction to expect. Their slot in
    -- column 1 is then as random as any other column, and giving it the model's weight would let
    -- a coin flip dominate the expected value -- so without a full prediction every column counts
    -- the same and the row's average is a plain average over the sweep.
    local predicted = true
    for _, player in ipairs(unknown) do
        predicted = predicted and likely[player.userId] ~= nil
    end
    local weight = predicted and math.clamp(modelled or 0.6, 0.05, 0.95) or 1 / math.max(1, count)
    local first = { others = {}, weight = weight, modelled = predicted }
    for _, player in ipairs(players) do
        if not player.me then
            first.others[player.userId] = likely[player.userId] or Sim.randomDirection()
        end
    end
    local columns = { first }
    local spread = (1 - first.weight) / math.max(1, count - 1)
    if #unknown == 1 then
        local opponent = unknown[1]
        local sweep = Sim.directions(count - 1)
        for _, direction in ipairs(sweep) do
            local others = {}
            for userId, value in pairs(first.others) do
                others[userId] = value -- the teammate's aim is known and stays put
            end
            others[opponent.userId] = direction
            columns[#columns + 1] = { others = others, weight = spread }
        end
        return columns
    end
    for _ = 2, count do
        local others = {}
        for userId, value in pairs(first.others) do
            others[userId] = value
        end
        for _, player in ipairs(unknown) do
            others[player.userId] = Sim.randomDirection()
        end
        columns[#columns + 1] = { others = others, weight = spread }
    end
    return columns
end

-- spec = {
--   team, seed, roles, statLevels, traits, arena -- the round, exactly as the server will run it
--   ours        -- our candidate directions, evenly spaced (Sim.directions)
--   opponents   -- Solver.columns(...): index 1 is the opponent we expect
--   place       -- function(ourDirection, scenario) -> directions keyed by team, as in a replay
--   lambda      -- Solver.lambda(...): 0 answers the expected opponent, 1 plays the floor
--   deadline, valid
-- }
--
-- Widens in stages so there is always an answer to give back: the whole grid against a few
-- opponent directions first, then the leaders against all of them, then finer directions around
-- the leaders. Every stage compares rows that saw the same opponents.
--
-- Returns the winning row { direction, score, expected, worst, wins, winner, columns } and how
-- many opponent directions it was judged against, or nil when nothing finished in time.
local NARROW = 4 -- opponent columns every one of our directions is tried against
local SURVIVORS = 4
local REFINE_STEPS = { -1 / 3, -1 / 6, 1 / 6, 1 / 3 } -- of the gap between our coarse directions
local PHI = (math.sqrt(5) - 1) / 2

-- Our directions in golden-ratio order rather than round the circle. If the clock runs out
-- partway through the first pass, the rows that did finish are still spread over every side of
-- the board, instead of all sitting in the one arc that happened to come first.
local function spread(directions)
    local order = {}
    for index = 1, #directions do
        order[index] = index
    end
    table.sort(order, function(a, b)
        return ((a - 1) * PHI) % 1 < ((b - 1) * PHI) % 1
    end)
    local out = {}
    for _, index in ipairs(order) do
        out[#out + 1] = directions[index]
    end
    return out
end

function Solver.solve(spec)
    if not Sim.ready() or not Life.alive or not spec.seed or #spec.ours == 0 or #spec.opponents == 0 then
        return nil
    end
    spec.lambda = math.clamp(spec.lambda or 0.5, 0, 1)
    spec.maxDuration = Sim.maxDuration(spec.arena)
    local narrow = math.min(NARROW, #spec.opponents)
    local full = #spec.opponents

    -- Every list `stage` returns holds only rows that covered all of its columns, so a stage cut
    -- short still ranks fairly; it just ranks fewer rows.
    local rows = {}
    for _, direction in ipairs(spread(spec.ours)) do
        rows[#rows + 1] = newRow(direction)
    end
    local best = stage(spec, rows, narrow)
    if #best == 0 then
        return nil
    end

    -- The leaders face every opponent column. The narrow pass is already cached, so this only
    -- pays for the columns it adds. Leaders run best first, so a cut-off loses the weakest.
    local leaders = table.move(best, 1, math.min(SURVIVORS, #best), 1, {})
    local widened, done = stage(spec, leaders, full)
    if #widened == 0 then
        return best[1], narrow
    end
    if not done then
        return widened[1], full
    end

    -- A winning window can be narrower than the gap between two coarse directions.
    local gap = math.pi * 2 / #spec.ours
    local finer = table.move(widened, 1, #widened, 1, {})
    for place = 1, math.min(2, #widened) do
        for _, step in ipairs(REFINE_STEPS) do
            finer[#finer + 1] = newRow(rotate(widened[place].direction, step * gap))
        end
    end
    -- The widened rows lead the list and are already complete, so this is never empty.
    local refined = stage(spec, finer, full)
    return refined[1], full
end

return Solver
end
__modules["core/stats"] = function(use) -- src/games/ballvsball/core/stats.luau
-- Every ball's win rate across all players, from the game's own BallBattleStats (the numbers its
-- Ball Index shows): overall, and head to head against each other ball.

local Env = use("core/env")
local Life = use("shared/life")

local Stats = {}

local REFRESH = 600 -- seconds; the server rate-limits the call
local MIN_MATCHUP_GAMES = 500 -- fewer head-to-head games than this and the overall rate is used

local raw, fetchedAt = nil, -math.huge
local fetching = false

local function all()
    if not fetching and os.clock() - fetchedAt > REFRESH then
        fetching, fetchedAt = true, os.clock()
        Life.spawn("duel:statistics", function()
            local moduleOk = Env.call(Env.loadModule, "StatsCore")
            local ok, result = Env.invoke("BallBattleStats/GetAll")
            if Life.alive and moduleOk and ok and type(result) == "table" then
                raw = type(result.data) == "table" and result.data or result
            else
                fetchedAt = os.clock() - REFRESH + 30
            end
            fetching = false
        end)
    end
    return raw
end

-- Refresh off the picking path: a slow statistics service must not use the pick timer.
all()

-- A ball's overall win rate (0..1), or nil when the game has no numbers for it.
function Stats.winRate(ball)
    local entry = (all() or {})[ball]
    if type(entry) ~= "table" then
        return nil
    end
    local core = rawget(Env.Game, "StatsCore")
    if not core then return nil end
    local ok, summary = Env.call(core.summarize, entry)
    return ok and summary and summary.winRate or nil
end

-- How often `ball` beats `versus`, falling back to its overall rate on too few games.
function Stats.against(ball, versus)
    local entry = (all() or {})[ball]
    local record = versus and type(entry) == "table" and type(entry.opponents) == "table" and entry.opponents[versus]
    if type(record) == "table" then
        local games = (record.wins or 0) + (record.losses or 0) + (record.draws or 0)
        if games >= MIN_MATCHUP_GAMES then
            return (record.wins + 0.5 * (record.draws or 0)) / games
        end
    end
    return Stats.winRate(ball)
end

return Stats
end
__modules["core/trajectory"] = function(use) -- src/games/ballvsball/core/trajectory.luau
-- Aim uses the same arena anchor and XY plane as DuelLaunchAimClient (local -Z is up).
local Env = use("core/env")
local Life = use("shared/life")
local Match = use("core/match")
local Trajectory = {}
local root, shownModel, shownToken

function Trajectory.clear()
    Env.elevate()
    if root then
        root:Destroy()
    end
    root, shownModel, shownToken = nil, nil, nil
end

-- `detail` is an optional second line: what the solver guarantees, next to what it expects.
function Trajectory.show(player, direction, expected, detail)
    Trajectory.clear()
    local model = Match.tableModel
    if not Life.alive or not Match.seated() or Match.phase() ~= "Aiming" or not model then
        return false
    end
    local anchor = model:FindFirstChild("棋盘锚点") or model:FindFirstChild("ArenaAnchor")
    if not anchor or not anchor:IsA("BasePart") or direction.Magnitude < 1e-6 then
        return false
    end
    local ok, cfg = Env.call(Env.loadModule("ArenaOverride").resolveConfig, Env.loadModule("BattleConfig"), Match.arena())
    if not ok or not Life.alive or model ~= Match.tableModel or Match.phase() ~= "Aiming" then
        return false
    end
    local slot = cfg.slots[player.team]
    local spawn = slot and ((slot.spawnPositionCorners or {})[player.index] or slot.spawnPosition)
    if typeof(spawn) ~= "Vector2" then
        return false
    end
    Env.elevate()
    root = Instance.new("Folder")
    root.Name = "SlopixAimTrajectory"
    root.Parent = model
    shownModel, shownToken = model, Match.aimToken
    local color = expected > 0.60 and Color3.fromRGB(70, 235, 115)
        or expected >= 0.45 and Color3.fromRGB(255, 215, 65) or Color3.fromRGB(255, 85, 85)
    direction = direction.Unit
    local length = math.min(cfg.arena.size.X, cfg.arena.size.Y) * 0.3
    -- Clip the launch segment to the board's edge, including corner spawns in team modes.
    for _, axis in ipairs({ "X", "Y" }) do
        local component = direction[axis]
        if math.abs(component) > 1e-6 then
            local edge = math.sign(component) * (cfg.arena.size[axis] / 2 - 0.2)
            length = math.min(length, math.max(0.2, (edge - spawn[axis]) / component))
        end
    end
    local tip = spawn + direction * length
    local wing = Vector2.new(-direction.Y, direction.X)
    local head = math.min(1.1, length * 0.3)
    local function point(position)
        local attachment = Instance.new("Attachment")
        attachment.Position = Vector3.new(position.X, position.Y, -0.3)
        attachment.Parent = anchor
        return attachment
    end
    -- Attachments are on a transparent anchor part owned by the visual, so one Destroy clears all.
    local holder = Instance.new("Part")
    holder.Name = "ArenaPlane"
    holder.Size = Vector3.new(0.1, 0.1, 0.1)
    holder.Transparency, holder.Anchored = 1, true
    holder.CanCollide, holder.CanTouch, holder.CanQuery = false, false, false
    holder.CFrame = anchor.CFrame
    holder.Parent = root
    anchor = holder
    local start, finish = point(spawn), point(tip)
    local function beam(a, b, width)
        local line = Instance.new("Beam")
        line.Attachment0, line.Attachment1 = a, b
        line.Width0, line.Width1 = width, width
        line.Color, line.Transparency = ColorSequence.new(color), NumberSequence.new(0)
        line.FaceCamera, line.LightEmission, line.Segments = true, 1, 1
        line.Parent = root
    end
    beam(start, finish, 0.16)
    beam(finish, point(tip - direction * head + wing * head * 0.5), 0.16)
    beam(finish, point(tip - direction * head - wing * head * 0.5), 0.16)
    local label = Instance.new("BillboardGui")
    label.Name, label.Adornee = "Prediction", holder
    label.Size = UDim2.fromOffset(260, detail and 58 or 44)
    label.StudsOffsetWorldSpace = holder.CFrame.LookVector * 3
    label.AlwaysOnTop, label.MaxDistance = true, 150
    label.Parent = root
    local text = Instance.new("TextLabel")
    text.Size, text.BackgroundTransparency = UDim2.fromScale(1, 1), 1
    text.TextColor3, text.TextStrokeTransparency = color, 0.25
    text.Font, text.TextSize = Enum.Font.GothamBold, 18
    local outcome = expected > 0.60 and "Win" or expected >= 0.45 and "Even" or "Loss"
    text.Text = string.format("Predicted: %s (%d%%)", outcome, math.floor(expected * 100 + 0.5))
        .. (detail and "\n" .. detail or "")
    text.Parent = label
    return true
end

local function refresh()
    if root and (not Life.alive or not Match.seated() or Match.phase() ~= "Aiming"
        or Match.tableModel ~= shownModel or Match.aimToken ~= shownToken or not root.Parent) then
        Trajectory.clear()
    end
end
-- Through Match, so an absent or renamed state remote costs the overlay its prompt refresh
-- rather than erroring out of this module while the hub is still loading.
Match.listen("DuelTableState", refresh)
Life.loop("duel:trajectory", 0.1, refresh)
Life.onCleanup(Trajectory.clear)

return Trajectory
end
__modules["core/ui"] = function(use) -- src/games/ballvsball/core/ui.luau
-- Ball VS Ball's window and tabs.

local Ui = use("shared/ui")

return Ui.create({
    library = function() return use("vendor/ui") end,
    icons = use("vendor/icons"),
    footer = "Ball VS Ball",
    tabs = {
        { "Home", "house", "Welcome to Slopix Hub" },
        { "Duel", "swords", "Auto duel, ball picks and aim" },
        { "Intel", "radar", "Opponents, the aim solver and prediction accuracy" },
        { "Rewards", "gift", "Daily quests, online rewards, check-in, mail and crates" },
        { "Settings", "settings", "Menu, themes and configs" },
    },
})
end
__modules["core/upgrades"] = function(use) -- src/games/ballvsball/core/upgrades.luau
-- Card ids are engine keys; upgradeChoice is indexed by the corresponding Chinese config id.
--
-- Two ways to judge a card. Upgrades.score reads its star rating out of the cloud config and adds
-- a bonus where its text lines up with the ball's traits: cheap, always available, and a guess.
-- Upgrades.bestBySimulation is the real answer, because a card is not a description -- it is an
-- entry in the statLevels and secondary-trait tables the server hands to the battle simulation.
-- Project the card into those tables, replay the next round with the game's own code, and the
-- question "which of these three wins" stops being a keyword match. The heuristic stays as the
-- tie-break and as the fallback for round 1, where there is no seed to replay against.
local Env = use("core/env")
local Sim = use("core/sim")
local Upgrades = {}

local function textOf(value)
    if type(value) ~= "table" then
        return tostring(value or "")
    end
    return table.concat({ tostring(value.behaviorKey or ""), tostring(value.displayName or ""),
        tostring(value.cnId or ""), tostring(value.trigger or "") }, " ")
end

local function contains(text, words)
    for _, word in ipairs(words) do
        if string.find(text, word, 1, true) then
            return true
        end
    end
    return false
end

function Upgrades.definition(candidate)
    if type(candidate) ~= "table" or type(candidate.id) ~= "string" then
        return nil
    end
    local battle = rawget(Env.Game, "BattleConfig")
    if not battle then return nil end
    local stats = type(battle.tournament_upgrade) == "table" and battle.tournament_upgrade.basicStats or nil
    local defs = candidate.kind == "effect" and battle.traits
        or candidate.kind == "basicStat" and stats
    local effect = type(defs) == "table" and defs[candidate.id] or nil
    local choice = Env.loadModule("Config").upgradeChoice
    local choices = type(choice) == "table" and choice.byTargetCnId or nil
    if type(choices) ~= "table" then
        return nil, effect
    end
    return choices[effect and effect.cnId or candidate.id], effect
end

function Upgrades.score(candidate, roleId, secondary)
    local choice, effect = Upgrades.definition(candidate)
    local star = choice and tonumber(choice.star) or 0
    if not choice then
        return -math.huge, nil -- unknown metadata must not be mistaken for a one-star card
    end
    local config, battle = Env.loadModule("Config"), Env.loadModule("BattleConfig")
    local ball = config.ball.byCnId[roleId]
    local role = battle.roles and battle.roles[roleId]
    local traitsByKey = type(battle.traits) == "table" and battle.traits or {}
    local active = { textOf(ball), textOf(role and role.skill) }
    -- Cloud ball.skills contains Chinese skill ids; resolve them to engine behavior keys.
    for _, id in ipairs(ball and ball.skills or {}) do
        active[#active + 1] = textOf(id)
        for key, trait in pairs(traitsByKey) do
            if type(trait) == "table" and trait.cnId == id then
                active[#active + 1] = key .. " " .. textOf(trait)
            end
        end
    end
    for _, id in ipairs(type(secondary) == "table" and secondary or {}) do
        active[#active + 1] = textOf(id) .. " " .. textOf(traitsByKey[id])
    end
    local traits = string.lower(table.concat(active, " "))
    local target = string.lower(candidate.id .. " " .. textOf(effect) .. " " .. textOf(choice))
    local bonus = 0
    if contains(traits, { "blade", "axe", "burst" })
        and contains(target, { "attackspeed", "attack speed", "bounceaccel", "bounce accel", "ballhitaccel" }) then
        bonus = 15
    elseif contains(traits, { "poison", "acid", "snake", "venom", "virus" })
        and contains(target, { "poisonduration", "poison duration", "poisonampl", "poison ampl", "lastingpoison", "damageamplification", "venom" }) then
        bonus = 15
    elseif contains(traits, { "electric", "electro", "voltaic" })
        and contains(target, { "stun", "paraly", "paralysis", "shockduration", "shock duration" }) then
        bonus = 15
    elseif candidate.id == "hp" or candidate.id == "LowHpArmor"
        or contains(target, { "defense", "shield", "health", "maxhp", "thick skin" }) then
        bonus = 3
    end
    return star * 10 + bonus, star
end

local function usable(candidate)
    return type(candidate) == "table" and type(candidate.id) == "string"
        and (candidate.kind == "effect" or candidate.kind == "basicStat")
end

function Upgrades.best(candidates, roleId, secondary)
    local best, bestScore, maxStar, known = nil, -math.huge, 0, true
    for _, candidate in ipairs(candidates) do
        local score, star = Upgrades.score(candidate, roleId, secondary)
        known = known and star ~= nil
        maxStar = math.max(maxStar, star or 0)
        if usable(candidate) and (not best or score > bestScore) then
            best, bestScore = candidate, score
        end
    end
    return best, maxStar, known
end

-- Projection -----------------------------------------------------------------------------------

-- Replaces one level of a container so the original (the live replay options) is never touched.
local function branch(container, key)
    local copy = table.clone(container)
    copy[key] = type(container[key]) == "table" and table.clone(container[key]) or nil
    return copy
end

-- Where our entry lives in a replay's per-team tables: one value per team in a 1v1, a list by seat
-- in a 2v2. `teamMode` says which, and the stored shape has to agree before anything is projected:
-- a mismatch means the game changed how it keys these, and simulating a guessed layout would be
-- worse than the heuristic it is meant to replace.
local function seat(container, team, index, teamMode)
    local value = type(container) == "table" and container[team]
    if type(value) ~= "table" then
        return nil
    end
    local perSeat = type(value[1]) == "table"
    if perSeat ~= (teamMode == true) then
        return nil
    end
    if not perSeat then
        return value
    end
    return type(value[index]) == "table" and value[index] or nil
end

-- The round's simulation inputs with `candidate` applied, or nil when the layout is unfamiliar.
-- A basic stat raises its level by one; an effect is appended to our secondary traits, which is
-- how the server records a chosen trait card.
function Upgrades.project(candidate, statLevels, traits, team, index, teamMode)
    if not usable(candidate) then
        return nil
    end
    if candidate.kind == "basicStat" then
        local current = seat(statLevels, team, index, teamMode)
        if not current or type(current[candidate.id]) ~= "number" then
            return nil
        end
        local projected = branch(statLevels, team)
        local target = projected[team]
        if teamMode then
            target[index] = table.clone(target[index])
            target = target[index]
        end
        target[candidate.id] += 1
        return projected, traits
    end
    local current = seat(traits, team, index, teamMode)
    if not current then
        return nil
    end
    for _, held in ipairs(current) do
        if held == candidate.id then
            return nil -- already carried; the card would change nothing to simulate
        end
    end
    local projected = branch(traits, team)
    local target = projected[team]
    if teamMode then
        target[index] = table.clone(target[index])
        target = target[index]
    end
    target[#target + 1] = candidate.id
    return statLevels, projected
end

-- Simulated selection -------------------------------------------------------------------------

-- Picks the card that actually wins the next round.
--
-- context = {
--   seed                      -- next round's seed (Match.nextSeed); nil means no simulation
--   team, index, teamMode     -- which entry in the per-team tables is ours
--   roles, directions         -- every ball and launch direction, keyed by team as in a replay
--   statLevels, traits, arena -- the round's inputs, from the last replay
--   roleId, secondary         -- for the heuristic tie-break
--   deadline, valid
-- }
--
-- Returns the card, a line explaining it, and the simulated outcome (1 win, 0.5 draw, 0 loss), or
-- nil when nothing could be simulated in time and the caller should fall back to Upgrades.best.
function Upgrades.bestBySimulation(candidates, context)
    if not context.seed or not Sim.ready() or type(context.roles) ~= "table"
        or type(context.directions) ~= "table" then
        return nil
    end
    local maxDuration = Sim.maxDuration(context.arena)
    local function play(statLevels, traits)
        local winner, elapsed = Sim.run(context.seed, context.roles, context.directions, statLevels, traits,
            context.arena, context.deadline, context.valid)
        if not winner then
            return nil
        end
        return Sim.outcome(winner, context.team), Sim.score(winner, elapsed, context.team, maxDuration)
    end

    -- The same round without any card, so the report can say what the choice is worth.
    local baseline = play(context.statLevels, context.traits)
    local best, bestOutcome, bestScore, bestHeuristic, tried = nil, -1, -1, -math.huge, 0
    for _, candidate in ipairs(candidates) do
        if os.clock() >= context.deadline or (context.valid and not context.valid()) then
            break
        end
        local statLevels, traits = Upgrades.project(candidate, context.statLevels, context.traits,
            context.team, context.index, context.teamMode)
        if statLevels then
            local outcome, score = play(statLevels, traits)
            if outcome then
                tried += 1
                local heuristic = Upgrades.score(candidate, context.roleId, context.secondary)
                -- Outcome first, then how fast, then the star/synergy guess for a genuine tie.
                if outcome > bestOutcome
                    or (outcome == bestOutcome and score > bestScore)
                    or (outcome == bestOutcome and score == bestScore and heuristic > bestHeuristic) then
                    best, bestOutcome, bestScore, bestHeuristic = candidate, outcome, score, heuristic
                end
            end
        end
        Sim.breathe()
    end
    if not best or tried < 2 then
        return nil -- one simulated card is not a comparison
    end
    local result = bestOutcome >= 1 and "wins" or bestOutcome >= 0.5 and "draws" or "loses"
    local change = baseline and bestOutcome > baseline and " (turns the round around)"
        or baseline and bestOutcome < baseline and " (best of a losing round)" or ""
    return best, string.format("%s: simulated, %s next round%s", best.id, result, change), bestOutcome
end

return Upgrades
end
__modules["features/duel"] = function(use) -- src/games/ballvsball/features/duel.luau
-- Duel tab: queue with Quick Play, pick the ball, aim, and queue again.
--
-- Picks: inventory choices use the free pick, then a pick voucher or diamonds when enabled.
-- DuelTableBallSelectPurchase lists eligible choices; DuelTableBallSelfSelect confirms one. "Smart"
-- simulates each offered ball against what everyone else played last round once the round's seed is
-- known (round 2 on, see core/match); otherwise, and in round 1, balls go by their win rate across
-- all players.
--
-- Aim: the launch direction decides the battle. Smart aim runs the game's own simulation for each
-- direction and locks the one that wins most. From round 2 the seed is exact and most players keep
-- the same direction every round, so the prediction is usually right; in round 1 it can only pick
-- the direction that wins most often over random seeds. 2v2 works the same way with four balls: the
-- replays key balls and directions by team and seat, the 2v2 board has its own arena, and the
-- server relays the teammate's aim while they drag it.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")
local Match = use("core/match")
local Sim = use("core/sim")
local Solver = use("core/solver")
local Profile = use("core/profile")
local Stats = use("core/stats")
local Limits = use("core/limits")
local Upgrades = use("core/upgrades")
local Trajectory = use("core/trajectory")

local Options = Ui.Options

local QUEUE_INTERVAL = 6 -- seconds between Quick Play requests while unseated
local PICK_WINDOW = 30 -- seconds the game gives to pick (and to aim)
local PICK_MARGIN = 4 -- answer this long before the game picks for us
local FREE_LIST_WAIT = 4
local LOCK_WAIT = 3
local PICK_DIRECTIONS = 12 -- directions tried per ball when picking by simulation
local AIM_DIRECTIONS = 36
local OPPONENT_SWEEP = 10 -- opponent launch directions the guaranteed floor is measured over
local REROLL_WAIT, REROLL_COOLDOWN = 3, 5
-- Round 1 has no seed, so there is no grid to solve: every scenario is a guessed seed and the
-- opponent's aim can only be averaged over. More think time buys more guesses.
local ROUND_ONE_SAMPLES, ROUND_ONE_MAX = 6, 14
-- 2v2: think once the teammate's aim has stopped moving this long (or when time runs short).
local TEAMMATE_SETTLE = 2
-- 2v2 Smart picks wait up to this long into the pick timer for the teammate to lock their ball,
-- leaving at least PICK_THINK_RESERVE seconds to simulate.
local TEAMMATE_PICK_WAIT, PICK_THINK_RESERVE = 12, 8

local MODES = { "1v1 (3 HP)", "2v2" }
local QUEUE_REMOTE = { ["1v1 (3 HP)"] = "DuelQuickPlayRequest", ["2v2"] = "Duel2v2QuickPlayRequest" }
local STRATEGIES = { "Smart", "Best win rate", "First offered", "Selected inventory ball" }

-- Ball names for the "Never pick" list.
local ballNames = {}
for _, ball in ipairs(Env.loadModule("Config").ball.list) do
    if ball.canPlayerUse then
        ballNames[#ballNames + 1] = ball.displayName
    end
end
table.sort(ballNames)

local tab = Ui.Tabs.Duel
local auto = tab:AddGroupbox({ Side = "Left", Name = "Auto duel", IconName = "swords" })
auto:AddToggle("AutoDuel", {
    Text = "Auto duel",
    Default = false,
    Tooltip = "Queues with Quick Play, picks your ball, aims, and queues again after each match.",
})
Ui.automation("AutoDuel")
auto:AddDropdown("DuelMode", { Text = "Mode", Values = MODES, Default = MODES[1] })
auto:AddToggle("StopAtCoinCap", {
    Text = "Stop at the coin cap",
    Default = true,
    Tooltip = "Duels pay nothing past the daily (and weekly) coin cap. Stops after the match in progress.",
})
auto:AddButton({
    Text = "Leave the table",
    Func = function()
        Env.event("DuelTableLeaveRequest"):FireServer()
    end,
    Tooltip = "Mid-match this forfeits.",
})

local picks = tab:AddGroupbox({ Side = "Left", Name = "Ball picks", IconName = "circle-dot" })
picks:AddDropdown("PickStrategy", {
    Text = "Pick by",
    Values = STRATEGIES,
    Default = STRATEGIES[1],
    Tooltip = "Smart simulates each offered ball against the opponent's last ball once the seed is known, and uses win rates before that.",
})
picks:AddToggle("FreePick", {
    Text = "Use the free pick",
    Default = true,
    Tooltip = "Takes the best server-approved free choice, including owned balls and weekly free balls you have unlocked.",
})
local NO_INVENTORY_BALL = "Choose an inventory ball"
local inventoryByLabel, inventorySignature = {}, nil
local function inventoryChoices()
    local items = Env.data("items")
    if type(items) ~= "table" then
        return nil
    end
    local labels, ids, seen = { NO_INVENTORY_BALL }, {}, {}
    for _, item in pairs(items) do
        if type(item) == "table" and item.itemType == "Ball" and type(item.itemId) == "string"
            and (item.ownerUserId == nil or item.ownerUserId == Env.LocalPlayer.UserId) and not seen[item.itemId] then
            local definition = Env.loadModule("Config").ball.byCnId[item.itemId]
            if definition and definition.canPlayerUse ~= false then
                seen[item.itemId] = true
                local label = Env.ballName(item.itemId) .. " [" .. item.itemId .. "]"
                ids[label] = item.itemId
                labels[#labels + 1] = label
            end
        end
    end
    table.sort(labels, function(a, b)
        if a == NO_INVENTORY_BALL then return b ~= NO_INVENTORY_BALL end
        if b == NO_INVENTORY_BALL then return false end
        return a < b
    end)
    return labels, ids
end
local initialInventory, initialIds = inventoryChoices()
inventoryByLabel = initialIds or {}
picks:AddDropdown("InventoryBall", {
    Text = "Inventory ball", Values = initialInventory or { NO_INVENTORY_BALL },
    Default = NO_INVENTORY_BALL, Searchable = true,
    Tooltip = "Set Pick by to Selected inventory ball to use this ball whenever the game allows it. The list follows your inventory.",
})
picks:AddToggle("PaidInventoryPick", {
    Text = "Allow paid inventory picks", Default = false,
    Tooltip = "After the free pick, allows the game's normal cost: a pick voucher first, otherwise your existing diamonds. Applies to every picking round while Auto duel is on.",
})
local inventoryCostLabel = picks:AddLabel("Inventory picks: waiting for a ball offer.", true)
local function selectedInventoryBall()
    if Options.PickStrategy.Value == "Selected inventory ball" then
        return inventoryByLabel[Options.InventoryBall.Value]
    end
end
local function inventoryPickAvailable(offer)
    local price = offer and offer.selectPrice
    if type(price) ~= "number" or price < 0 or price ~= price or price == math.huge then
        return false, "Inventory selection is unavailable."
    end
    if price == 0 then
        return true, "Inventory pick: free."
    end
    local vouchers = Env.data("vouchers")
    local count = type(vouchers) == "table" and tonumber(vouchers["指定卡"]) or 0
    if (count or 0) >= 1 then
        return Ui.on("PaidInventoryPick"), "Inventory pick: 1 pick voucher" .. (Ui.on("PaidInventoryPick") and "." or " (paid picks off).")
    end
    local enough = (tonumber(Env.data("diamonds")) or 0) >= price
    local suffix = not Ui.on("PaidInventoryPick") and " (paid picks off)." or not enough and " (not enough diamonds)." or "."
    return Ui.on("PaidInventoryPick") and enough, string.format("Inventory pick: %s diamonds%s", tostring(price), suffix)
end
Life.loop("duel:inventory", 3, function()
    local labels, ids = inventoryChoices()
    if labels then
        local signature = table.concat(labels, "\0")
        inventoryByLabel = ids
        if signature ~= inventorySignature then
            inventorySignature = signature
            Env.elevate()
            Options.InventoryBall:SetValues(labels)
        end
    end
    if not Life.alive then return end
    Env.elevate()
    if Match.seated() and Match.phase() == "Picking" and not Match.ballLocked then
        local _, text = inventoryPickAvailable(Match.offer)
        Env.elevate()
        inventoryCostLabel:SetText(text)
    else
        inventoryCostLabel:SetText("Inventory picks: available while choosing a ball.")
    end
end)
picks:AddDropdown("NeverPick", {
    Text = "Never pick",
    Values = ballNames,
    Multi = true,
    Searchable = true,
    Default = {},
})
picks:AddToggle("RerollBadOffers", {
    Text = "Reroll bad offers", Default = true,
    Tooltip = "Rerolls once when every offered ball is excluded or below the threshold. Diamond rerolls require the separate option below.",
})
picks:AddToggle("UseOwnedDiamondsForRerolls", {
    Text = "Use owned diamonds for rerolls", Default = false,
    Tooltip = "Allows ball and upgrade rerolls only when your existing diamonds cover the price. Off by default to avoid the game's Robux top-up prompt.",
})
picks:AddSlider("RerollThreshold", {
    Text = "Reroll below", Default = 50, Min = 30, Max = 70, Rounding = 0, Suffix = "%",
    Tooltip = "Rerolls when every offered ball's win rate across all players is below this. Higher holds out for strong balls but spends more rerolls.",
})
picks:AddSlider("PickDelay", {
    Text = "Pick after",
    Default = 2,
    Min = 0,
    Max = 20,
    Rounding = 0,
    Suffix = "s",
    Tooltip = "Waits this long before picking. The pick always goes in before the game's timer ends.",
})

local aimBox = tab:AddGroupbox({ Side = "Right", Name = "Aim", IconName = "crosshair" })
aimBox:AddToggle("SmartAim", {
    Text = "Smart aim",
    Default = true,
    Tooltip = "Simulates the round for each launch direction with the game's own battle code and locks the best. Also aims for you when you play yourself.",
})
aimBox:AddToggle("AimTrajectory", {
    Text = "Show aim prediction", Default = true,
    Callback = function(value)
        if not value then
            Trajectory.clear()
        end
    end,
})
aimBox:AddDropdown("AimStyle", {
    Text = "Play style",
    Values = { "Balanced", "Exploit", "Safe" },
    Default = "Balanced",
    Tooltip = "Exploit answers the aim this opponent is expected to use. Safe takes the direction with the best worst case, so a surprise aim cannot blow the round out. Balanced weighs both, and all three lean safer at 1 hp and bolder when the opponent is on their last.",
})
aimBox:AddSlider("AimThinkTime", {
    Text = "Think time",
    Default = 10,
    Min = 3,
    Max = 22,
    Rounding = 0,
    Suffix = "s",
    Tooltip = "Longer tries more of the opponent's possible aims. Each simulation stalls the game for a moment.",
})
aimBox:AddLabel("From round 2 the seed is exact and every ball is locked, so the round is solved as a grid: your directions against theirs. You get the aim that beats the opponent you expect and the one that cannot be punished, and the Intel tab shows which is which.", true)

local matchBox = tab:AddGroupbox({ Side = "Right", Name = "Match", IconName = "activity" })
local panel = Ui.panel(matchBox, 6)
local upgrades = tab:AddGroupbox({ Side = "Left", Name = "Upgrades", IconName = "sparkles" })
upgrades:AddToggle("RerollLowUpgrades", {
    Text = "Reroll one-star offers", Default = true,
    Tooltip = "Rerolls once if every card is one star. Diamond rerolls also require Use owned diamonds for rerolls under Ball picks.",
})
upgrades:AddToggle("SimulateUpgrades", {
    Text = "Simulate upgrade cards", Default = true,
    Tooltip = "A card is an entry in the stat and trait tables the battle simulation reads, so each one can be played out instead of guessed at. Needs a known seed; before that, and whenever the card tables are not in a shape it recognises, the star rating decides.",
})
local upgradeLabel = upgrades:AddLabel("Cards score 10 per star, +15 for a matching ball trait, or +3 for defense, shield and health.", true)

-- Session tally --------------------------------------------------------------------------------

local session = { rounds = { won = 0, lost = 0, draw = 0 }, matches = { won = 0, lost = 0 }, coins = 0 }
Match.status = "Off"
local prediction = nil -- { text, ... } for the round being played
-- The last rounds, newest last, for checking predictions: what was assumed and what happened.
local history = {}
local HISTORY_SIZE = 30
-- Published on Match, the way `status` already is, so features/intel can report on the solver
-- without a feature having to use() another feature (and rebuild its tab if that one failed).
Match.history, Match.session = history, session

local function directionsMatch(a, b)
    return typeof(a) == "Vector2" and typeof(b) == "Vector2" and (a - b).Magnitude < 1e-3
end

local function otherTeam(team)
    return team == "Blue" and "Yellow" or "Blue"
end

-- Balls or directions for everyone at the table, keyed by team the way the simulation and the
-- replays have them: one value per team in a 1v1, a list by seat in a 2v2.
local function byTeam(players, valueOf)
    local out = {}
    local teamMode = Match.teamSize() > 1
    for _, player in ipairs(players) do
        if teamMode then
            out[player.team] = out[player.team] or {}
            out[player.team][player.index] = valueOf(player)
        else
            out[player.team] = valueOf(player)
        end
    end
    return out
end

-- "Ray Ball + Spider Ball" for a team's entry in a replay's selectedRoles.
local function teamBalls(roles, team)
    local value = type(roles) == "table" and roles[team]
    if type(value) ~= "table" then
        return Env.ballName(value)
    end
    local names = {}
    for _, role in ipairs(value) do
        names[#names + 1] = Env.ballName(role)
    end
    return table.concat(names, " + ")
end

Match.onRound(function(replay, won)
    local rounds = session.rounds
    if won == nil then
        rounds.draw += 1
    elseif won then
        rounds.won += 1
    else
        rounds.lost += 1
    end
    if prediction then
        prediction.result = won
    end
    local options = replay.replayOptions or {}
    local team = Match.team()
    local entry = {
        round = replay.round,
        won = won,
        balls = string.format("%s vs %s", teamBalls(options.selectedRoles, team), teamBalls(options.selectedRoles, otherTeam(team))),
    }
    if prediction and prediction.seed then
        -- Was the seed right, and did everyone else aim where we assumed?
        entry.seedRight = prediction.seed == replay.seed
        local kept, opponents, opponentsKept = true, 0, 0
        for _, player in ipairs(Match.players()) do
            local assumed = prediction.assumed[player.userId]
            local same = assumed ~= nil
                and directionsMatch(assumed, Match.forPlayer(options.initialDirections, player.team, player.index))
            if assumed and not same then
                kept = false
            end
            if player.teammate then
                entry.teammateKeptAim = same
            elseif not player.me then
                opponents += 1
                opponentsKept += same and 1 or 0
            end
        end
        entry.othersKeptAim = kept
        entry.opponentsKeptAim = string.format("%d/%d", opponentsKept, opponents)
        entry.opponentsKept, entry.opponents = opponentsKept, opponents
        entry.predicted = prediction.predicted
        entry.expected, entry.worst = prediction.expected, prediction.worst
    end
    -- Learn from the round regardless of whether we predicted it. keepsAim compares the replay
    -- that just landed against the one before it, which is exactly "did they launch there again",
    -- and is nil in round 1 where there is nothing to compare and nothing to learn.
    for _, player in ipairs(Match.players()) do
        if not player.me then
            Profile.observe(player.userId, Match.keepsAim(player),
                Match.forPlayer(options.selectedRoles, player.team, player.index),
                not player.teammate and won or nil)
        end
    end
    history[#history + 1] = entry
    if #history > HISTORY_SIZE then
        table.remove(history, 1)
    end
    if replay.matchFinished then
        local matches = session.matches
        if won then
            matches.won += 1
        else
            matches.lost += 1
        end
    end
end)

-- Through Match, so a renamed currency event costs the session tally and nothing else. Bound
-- directly, it errored on the way up and took auto duel, picks and aim with it.
Match.listen("CurrencyChanged", function(currency, delta, _, source)
    if currency == "coins" and type(delta) == "number" and type(source) == "table" and source.type == "duelReward" then
        session.coins += delta
    end
end)

-- Choosing a ball --------------------------------------------------------------------------------

local function never(ball)
    local chosen = Options.NeverPick and Options.NeverPick.Value or {}
    return chosen[Env.ballName(ball)] == true
end

local function allowed(candidates)
    local out = {}
    for _, ball in ipairs(candidates) do
        if not never(ball) then
            out[#out + 1] = ball
        end
    end
    -- The server requires a pick even when every candidate is excluded; reroll is attempted first.
    return #out > 0 and out or candidates
end

-- The one opponent of a 1v1 (from Match.players), or nil in a 2v2.
local function soleOpponent(players)
    if Match.teamSize() ~= 1 then
        return nil
    end
    for _, player in ipairs(players) do
        if not player.me then
            return player
        end
    end
    return nil
end

-- Best by win rate, head to head against `versus` when the game has enough games of it.
local function byWinRate(candidates, versus)
    if #candidates == 0 then return nil, "no eligible balls" end
    local best, bestRate = candidates[1], -1
    local hasStatistics = false
    for _, ball in ipairs(candidates) do
        local rate = Stats.against(ball, versus)
        hasStatistics = hasStatistics or rate ~= nil
        rate = rate or 0
        if rate > bestRate then
            best, bestRate = ball, rate
        end
    end
    if not hasStatistics then return best, Env.ballName(best) .. ": statistics unavailable" end
    return best, string.format("%s: %d%% win rate%s", Env.ballName(best), math.floor(bestRate * 100 + 0.5),
        versus and " vs " .. Env.ballName(versus) or "")
end

-- Simulates each candidate with the known seed against everyone else's ball and aim from last
-- round (teammate included in a 2v2). Nil when the seed or last round is not known yet.
local function bySimulation(candidates, deadline, valid)
    local seed = Match.nextSeed()
    if not seed or not Sim.ready() then
        return nil
    end
    local players = Match.players()
    local lastRole, lastDirection = {}, {}
    for _, player in ipairs(players) do
        if not player.me then
            local role, direction = Match.lastPlay(player)
            -- A teammate who has already locked this round shows their ball (the pick screen does
            -- too). Failing both, the ball this player is known to favour beats giving up on the
            -- simulation entirely.
            role = player.teammate and player.roleId or role or Profile.likelyBall(player.userId)
            if not (role and direction) then
                return nil
            end
            lastRole[player.userId], lastDirection[player.userId] = role, direction
        end
    end
    local options = Match.lastReplay.replayOptions or {}
    local arena = Match.arena()
    local best, bestScore, bestWins = nil, -1, 0
    local perBall = math.max(1, (deadline - os.clock()) / #candidates)
    for _, ball in ipairs(candidates) do
        local direction, expected, wins = Sim.bestDirection({
            team = Match.team(),
            roles = byTeam(players, function(player)
                return player.me and ball or lastRole[player.userId]
            end),
            place = function(direction)
                return byTeam(players, function(player)
                    return player.me and direction or lastDirection[player.userId]
                end)
            end,
            directions = Sim.directions(PICK_DIRECTIONS),
            scenarios = { { seed = seed, weight = 1 } },
            statLevels = options.statLevels,
            traits = options.selectedSecondaryTraits,
            arena = arena,
            deadline = math.min(deadline, os.clock() + perBall),
            valid = valid,
        })
        if not direction then return nil end
        -- Can it win at all, how forgiving is the aim, and how good is the ball in general.
        local score = (expected >= 1 and 0.6 or 0) + 0.25 * wins / PICK_DIRECTIONS + 0.15 * (Stats.winRate(ball) or 0.5)
        if score > bestScore then
            best, bestScore, bestWins = ball, score, wins
        end
    end
    return best, string.format("%s: wins with %d/%d aims against last round's balls (simulated)", Env.ballName(best),
        bestWins, PICK_DIRECTIONS)
end

local function choose(candidates, deadline, valid)
    local strategy = Options.PickStrategy.Value
    local selected = selectedInventoryBall()
    if selected and table.find(candidates, selected) then
        return selected, Env.ballName(selected) .. ": selected inventory ball"
    end
    if strategy == "First offered" then
        return candidates[1], Env.ballName(candidates[1]) .. ": first offered"
    end
    if strategy == "Smart" then
        local ball, why = bySimulation(candidates, deadline, valid)
        if ball then
            return ball, why
        end
    end
    local opponent = soleOpponent(Match.players())
    return byWinRate(candidates, opponent and (Match.lastPlay(opponent)))
end

local function waitFor(predicate, seconds)
    local deadline = os.clock() + seconds
    while Life.alive and not predicate() and os.clock() < deadline do
        Life.wait(0.1)
    end
    Env.elevate()
    return Life.alive and predicate()
end

local triedAt = {}
local function mayTry(key, cooldown)
    local now = os.clock()
    if not Life.alive or now - (triedAt[key] or -math.huge) < cooldown then
        return false
    end
    triedAt[key] = now -- acquire before sending, including failed/timed-out calls
    return true
end

local function reroll(kind, offer, deadline, valid)
    local function affordable()
        local allowDiamonds = Ui.on("UseOwnedDiamondsForRerolls")
        if kind == "ball" then
            return Match.canRerollBall(allowDiamonds)
        end
        return Match.canRerollUpgrade(allowDiamonds)
    end
    if offer.rerollTried or deadline - os.clock() < REROLL_WAIT + 1
        or not affordable()
        or not mayTry("reroll:" .. kind, REROLL_COOLDOWN) then
        return
    end
    local remote = Env.event(kind == "ball" and "DuelTableBallReroll" or "DuelTableUpgradeReroll")
    if not valid() or not affordable() then
        return
    end
    offer.rerollTried, offer.rerollPending = true, true
    Match.status = kind == "ball" and "Rerolling bad balls" or "Rerolling one-star upgrades"
    Env.elevate()
    remote:FireServer(Match.tableModel)
    waitFor(function()
        return not valid() or not offer.rerollPending
    end, math.min(REROLL_WAIT, deadline - os.clock()))
    -- If no reply arrives, leave the request pending until near the deadline. A later loop
    -- reads the latest offer rather than choosing from the pre-reroll candidates.
end

local function badBalls(candidates)
    if #candidates == 0 then
        return false
    end
    for _, ball in ipairs(candidates) do
        local rate = Stats.winRate(ball)
        if not never(ball) and (rate == nil or rate * 100 >= Options.RerollThreshold.Value) then
            return false -- unknown stats do not justify spending a reroll
        end
    end
    return true
end

local function pick(offer)
    local model = Match.tableModel
    local deadline = offer.at + (offer.duration or PICK_WINDOW) - PICK_MARGIN
    local function valid()
        return Life.alive and Ui.on("AutoDuel") and Match.seated() and Match.phase() == "Picking"
            and Match.tableModel == model and Match.offer == offer and not Match.ballLocked
    end
    if not valid() then
        return true
    end
    local candidates, inventoryPick = offer.offer or {}, false
    local selected = selectedInventoryBall()
    local alreadyOffered = selected and table.find(candidates, selected) ~= nil
    local wantsInventory = not alreadyOffered and (selected ~= nil
        or (Options.PickStrategy.Value ~= "Selected inventory ball" and (Ui.on("FreePick") or Ui.on("PaidInventoryPick"))))
    local available = wantsInventory and inventoryPickAvailable(offer)
    local useInventory = available and (offer.selectPrice > 0 or Ui.on("FreePick") or selected ~= nil)
    if useInventory and not offer.selectAsked and mayTry("inventoryPick", 5) then
        offer.selectAsked, offer.selectPending, offer.selectError = true, true, nil
        offer.selectAskedAt = os.clock()
        Match.selectList = nil
        Env.elevate()
        Env.event("DuelTableBallSelectPurchase"):FireServer(model)
        waitFor(function()
            return not valid() or not offer.selectPending
        end, math.max(0, math.min(FREE_LIST_WAIT, deadline - os.clock())))
    end
    if not valid() then
        return true
    end
    if useInventory and offer.selectPending and os.clock() < deadline - 1 then
        Match.status = "Waiting for inventory choices"
        return false
    end
    if useInventory and Match.selectList and not offer.selectError and type(Match.selectList.roleIds) == "table"
        and #Match.selectList.roleIds > 0 and (not selected or table.find(Match.selectList.roleIds, selected)) then
        candidates, inventoryPick = Match.selectList.roleIds, true
    end
    if not inventoryPick and not alreadyOffered and Ui.on("RerollBadOffers") and badBalls(candidates)
        and Match.canRerollBall(Ui.on("UseOwnedDiamondsForRerolls")) then
        reroll("ball", offer, deadline, valid)
    end
    if not valid() then
        return true
    end
    if offer.rerollPending and os.clock() < deadline - 1 then
        Match.status = "Waiting for ball reroll"
        return false
    end
    candidates = inventoryPick and candidates or offer.offer or {}
    if #candidates == 0 then
        return false
    end
    -- 2v2: simulating is worth more with the teammate's real ball, so give them time to lock it,
    -- keeping enough of the timer to simulate afterwards.
    local waitUntil = math.min(offer.at + TEAMMATE_PICK_WAIT, deadline - PICK_THINK_RESERVE)
    if Match.teamSize() > 1 and Options.PickStrategy.Value == "Smart" and Match.nextSeed() then
        Match.status = "Picking a ball (waiting for your teammate's pick)"
        waitFor(function()
            if os.clock() >= waitUntil or not valid() then
                return true
            end
            for _, player in ipairs(Match.players()) do
                if player.teammate and player.roleId then
                    return true
                end
            end
            return false
        end, TEAMMATE_PICK_WAIT)
    end
    if not valid() then
        return true
    end
    Match.status = "Picking a ball"
    -- A reply can arrive during the teammate wait too.
    candidates = inventoryPick and candidates or offer.offer or {}
    local revision = offer.revision
    local preferred = selectedInventoryBall()
    local choices = preferred and table.find(candidates, preferred) and { preferred } or allowed(candidates)
    local ball, why = choose(choices, deadline - 1, valid)
    local pickAt = math.min(offer.at + Options.PickDelay.Value, deadline)
    waitFor(function()
        return not valid() or os.clock() >= pickAt
    end, math.max(0, pickAt - os.clock()))
    if not valid() then
        return true
    end
    if not ball or offer.revision ~= revision then
        return false
    end
    if inventoryPick then
        local selectedNow = selectedInventoryBall()
        if selectedNow and selectedNow ~= ball then return false end
        local affordable, text = inventoryPickAvailable(offer)
        if not affordable then
            Env.elevate()
            inventoryCostLabel:SetText(text)
            return false -- re-read the current balance/settings before confirming a paid choice
        end
    end
    if not valid() then return true end
    offer.selectConfirmError = nil
    -- A callback error or a delayed confirmation must never submit another paid pick.
    if inventoryPick and offer.inventorySubmitted then return true end
    local pickRemote = Env.event(inventoryPick and "DuelTableBallSelfSelect" or "DuelTableBallSelect")
    if inventoryPick then
        local selectedNow = selectedInventoryBall()
        if (selectedNow and selectedNow ~= ball) or not inventoryPickAvailable(offer) then return false end
    end
    if not valid() then return true end
    if inventoryPick then offer.inventorySubmitted = true end
    Env.elevate()
    pickRemote:FireServer(model, ball)
    local weekly = Match.isWeeklyFree(ball) and " (weekly free)" or ""
    prediction = { text = "Picked " .. why .. weekly }
    Match.status = "Ball selected: " .. Env.ballName(ball) .. weekly
    if inventoryPick then
        waitFor(function()
            return not valid() or offer.selectConfirmError ~= nil
        end, LOCK_WAIT)
    end
    if inventoryPick and valid() then
        -- An unavailable/denied inventory choice falls back to the ordinary offer.
        local fallback, fallbackWhy = byWinRate(allowed(offer.offer or {}))
        if fallback then
            Env.elevate()
            Env.event("DuelTableBallSelect"):FireServer(model, fallback)
            prediction = { text = "Picked " .. fallbackWhy }
            Match.status = "Inventory choice unavailable; selected " .. Env.ballName(fallback)
        end
    end
    return true
end

-- Aiming -----------------------------------------------------------------------------------------

local function aim()
    if not Sim.ready() then
        Match.status = "Waiting for simulation modules"
        return
    end
    local token, model = Match.aimToken, Match.tableModel
    local function valid()
        return Life.alive and Ui.on("SmartAim") and Match.seated() and Match.phase() == "Aiming"
            and Match.aimToken == token and Match.tableModel == model and not Match.aimLocked
    end
    local players = Match.players()
    local me
    for _, player in ipairs(players) do
        if player.me then
            me = player
        end
        if not player.roleId then
            return -- balls are not all locked yet
        end
    end
    if not (Ui.on("SmartAim") and me) then
        return -- the game locks the current aim when its timer runs out
    end
    Match.status = "Aiming"
    -- 2v2: the teammate's aim is known as they drag it, so wait for it to settle first.
    local thinkTime = math.min(Options.AimThinkTime.Value, PICK_WINDOW - PICK_MARGIN)
    local latest = Match.aimStartedAt + PICK_WINDOW - PICK_MARGIN - thinkTime
    local hasTeammate = false
    for _, player in ipairs(players) do
        hasTeammate = hasTeammate or player.teammate
    end
    while hasTeammate and valid() and os.clock() < latest do
        local live = Match.teammateAim
        if live and os.clock() - live.at >= TEAMMATE_SETTLE then
            break
        end
        Match.status = "Aiming (waiting for your teammate's aim)"
        Life.wait(0.2)
    end
    if not valid() then
        return
    end
    Match.status = "Aiming (solving launch directions)"
    local seed = Match.nextSeed()
    -- Where everyone else will likely aim: a teammate's live aim while they drag it, otherwise
    -- last round's aim (nil in round 1, and nil for anyone the model says re-aims: they are
    -- swept or sampled instead).
    local likely = {}
    for _, player in ipairs(players) do
        if not player.me then
            local _, lastDirection = Match.lastPlay(player)
            local live = player.teammate and Match.teammateAim and Match.teammateAim.userId == player.userId
                and Match.teammateAim.direction
            likely[player.userId] = live or (Match.keepsAim(player) ~= false and lastDirection) or nil
        end
    end
    local options = Match.lastReplay and Match.lastReplay.replayOptions or {}
    local team = Match.team()
    local roles = byTeam(players, function(player)
        return player.roleId
    end)
    local function place(ours, scenario)
        return byTeam(players, function(player)
            return player.me and ours or scenario.others[player.userId]
        end)
    end
    local directionCount = math.clamp(math.floor(thinkTime / 10 * AIM_DIRECTIONS / 6) * 6, 12, AIM_DIRECTIONS)
    local deadline = math.min(os.clock() + thinkTime, Match.aimStartedAt + PICK_WINDOW - PICK_MARGIN)
    local arena = Match.arena()
    -- `call` becomes the round's prediction only once the aim is actually sent, so the accuracy
    -- figures never judge a call the hub abandoned at the last moment.
    local direction, expected, detail, call

    if seed then
        -- The round is fully determined except for where the others launch, so solve it as a grid
        -- instead of answering one guess. The first opponent column is who the model expects, and
        -- its weight is how often these specific players have actually repeated an aim.
        local modelled = Profile.tableKeepRate(players)
        local sweep = math.clamp(math.floor(thinkTime / 2), 4, OPPONENT_SWEEP)
        local ourHp, theirHp = Match.stakes()
        local lambda = Solver.lambda(Options.AimStyle.Value, ourHp, theirHp)
        local row, columns = Solver.solve({
            team = team,
            seed = seed,
            roles = roles,
            ours = Sim.directions(directionCount),
            opponents = Solver.columns(players, likely, modelled, sweep),
            place = place,
            statLevels = options.statLevels,
            traits = options.selectedSecondaryTraits,
            arena = arena,
            lambda = lambda,
            deadline = deadline,
            valid = valid,
        })
        if not row or not valid() then
            return
        end
        direction, expected = row.direction, row.expected
        local floor = row.worst >= 1 and "a win" or row.worst >= 0.5 and "a draw" or "a loss"
        detail = string.format("floor %s | beats %d/%d aims", floor, row.wins, columns)
        local versus = string.format("%s vs %s", teamBalls(roles, team), teamBalls(roles, otherTeam(team)))
        call = {
            text = string.format("%s: %s (%s, %d%% expected, %s style at lambda %.2f)", versus,
                row.winner == team and "expect a win" or row.winner == "Draw" and "expect a draw" or "likely a loss",
                detail, math.floor(row.expected * 100 + 0.5), Options.AimStyle.Value, lambda),
            seed = seed,
            assumed = likely,
            predicted = row.winner == team,
            expected = row.expected,
            worst = row.worst,
            wins = row.wins,
            columns = columns,
            lambda = lambda,
            modelled = modelled,
        }
    else
        -- Round 1: the seed is unknown, so there is no grid. Every scenario is a guessed seed and
        -- the best that can be said is which direction wins over the most of them.
        -- Nobody has a last aim yet, so opponents are random in every scenario; only a teammate
        -- dragging their arrow is known.
        local scenarios = {}
        local samples = math.clamp(math.floor(thinkTime / 10 * ROUND_ONE_SAMPLES), ROUND_ONE_SAMPLES, ROUND_ONE_MAX)
        for _ = 1, samples do
            local others = {}
            for _, player in ipairs(players) do
                if not player.me then
                    others[player.userId] = likely[player.userId] or Sim.randomDirection()
                end
            end
            scenarios[#scenarios + 1] = { seed = Sim.randomSeed(), others = others, weight = 1 }
        end
        local firstWins
        direction, expected, firstWins = Sim.bestDirection({
            team = team,
            roles = roles,
            place = place,
            directions = Sim.directions(directionCount),
            scenarios = scenarios,
            arena = arena,
            deadline = deadline,
            valid = valid,
        })
        if not direction or not valid() then
            return
        end
        detail = string.format("round 1 | %d seeds sampled", samples)
        local versus = string.format("%s vs %s", teamBalls(roles, team), teamBalls(roles, otherTeam(team)))
        call = {
            text = string.format("%s: round 1, best aim wins %d%% of %d sampled seeds (%d/%d directions win the first)",
                versus, math.floor(expected * 100 + 0.5), samples, firstWins or 0, directionCount),
            expected = expected,
        }
    end

    Env.elevate()
    if Ui.on("AimTrajectory") then
        local ok, err = pcall(Trajectory.show, me, direction, expected, detail)
        Life.errors["duel:trajectory"] = not ok and tostring(err) or nil
        if not ok then
            Trajectory.clear()
        end
    end
    if not valid() then
        Trajectory.clear()
        return
    end
    Env.elevate()
    if Match.teamSize() > 1 then
        -- Shows our arrow on the teammate's screen, as the game does while we drag.
        Env.unreliable("DuelTableAimPreview"):FireServer(Match.tableModel, direction)
    end
    Env.event("DuelTableLaunchDirection"):FireServer(Match.tableModel, direction)
    prediction = call
    Match.status = string.format("Aim selected (%d%% expected, %s)", math.floor(expected * 100 + 0.5), detail)
    return true
end

-- Resolve cloud star ratings and add bonuses for the current ball's traits.
local function upgrade(offer)
    local model, phase = Match.tableModel, Match.phase()
    local function valid()
        return Life.alive and Ui.on("AutoDuel") and Match.seated() and Match.tableModel == model
            and Match.phase() == phase and Match.upgradeOffer == offer
    end
    local players = Match.players()
    local me, roleId, secondary
    for _, player in ipairs(players) do
        if player.me then
            me = player
            roleId = player.roleId or (Match.ballLocked and Match.ballLocked.roleId) or Match.lastPlay(player)
            local options = Match.lastReplay and Match.lastReplay.replayOptions
            local traits = options and options.selectedSecondaryTraits
            secondary = traits and traits[player.team]
            if Match.teamSize() > 1 and type(secondary) == "table" then
                secondary = secondary[player.index]
            end
            break
        end
    end
    local deadline = offer.at + (offer.duration or 20) - 2
    local best, maxStar, known = Upgrades.best(offer.offer or {}, roleId, secondary)
    if valid() and Ui.on("RerollLowUpgrades") and known and maxStar == 1
        and Match.canRerollUpgrade(Ui.on("UseOwnedDiamondsForRerolls")) then
        reroll("upgrade", offer, deadline, valid)
    end
    if not valid() then
        return true
    end
    if offer.rerollPending and os.clock() < deadline - 1 then
        Match.status = "Waiting for upgrade reroll"
        return false
    end
    local candidates = offer.offer or {}
    local why
    best = nil
    -- The next round's balls are not chosen yet, so the card is judged on the round we just
    -- played: same balls, same aims, next round's seed. That is a proxy, not the certainty the
    -- aim solver gets -- but a card that wins a replay of the last round beats one that merely
    -- reads as if it should.
    if Ui.on("SimulateUpgrades") and me then
        local options = Match.lastReplay and Match.lastReplay.replayOptions or {}
        local lastRoles, lastDirections, complete = {}, {}, true
        for _, player in ipairs(players) do
            local role, direction = Match.lastPlay(player)
            if not (role and direction) then
                complete = false
                break
            end
            lastRoles[player.userId], lastDirections[player.userId] = role, direction
        end
        if complete then
            best, why = Upgrades.bestBySimulation(candidates, {
                seed = Match.nextSeed(),
                team = me.team,
                index = me.index,
                teamMode = Match.teamSize() > 1,
                roles = byTeam(players, function(player)
                    return lastRoles[player.userId]
                end),
                directions = byTeam(players, function(player)
                    return lastDirections[player.userId]
                end),
                statLevels = options.statLevels,
                traits = options.selectedSecondaryTraits,
                arena = Match.arena(),
                roleId = roleId,
                secondary = secondary,
                deadline = deadline,
                valid = valid,
            })
        end
    end
    if not best then
        best = Upgrades.best(candidates, roleId, secondary)
        why = best and (best.id .. ": best star rating and trait match") or nil
    end
    if not best then
        return false
    end
    if not valid() then
        return true
    end
    Match.status = "Selecting upgrade: " .. best.id
    Env.elevate()
    upgradeLabel:SetText("Last card: " .. tostring(why))
    Env.event("DuelTableUpgradeSelect"):FireServer(model, { kind = best.kind, id = best.id })
    return true
end

-- The loop ------------------------------------------------------------------------------------------

local lastQueue = -math.huge
local handledOffer, handledAim, handledUpgrade, seenOffer

-- Aims once per Aiming token. Past the point where a search could still finish before the game
-- locks the current aim, the token is given up on: otherwise a solve that cannot complete was
-- restarted every quarter second until the phase changed, stalling frames for nothing.
local function tryAim()
    if not (Ui.on("SmartAim") and Match.seated() and Match.phase() == "Aiming" and Match.aimToken
        and handledAim ~= Match.aimToken and not Match.aimLocked) then
        return
    end
    local token = Match.aimToken
    if os.clock() >= Match.aimStartedAt + PICK_WINDOW - PICK_MARGIN then
        handledAim = token
        Match.status = "Aim window closed; the game keeps the current aim"
        return
    end
    if aim() then
        handledAim = token
    end
end

local function step()
    if not Ui.on("AutoDuel") then
        Match.status = Ui.on("SmartAim") and "Auto duel off (smart aim still aims your rounds)" or "Off"
        -- Smart aim also helps in matches you play yourself.
        tryAim()
        return
    end
    if not Match.seated() then
        if Ui.on("StopAtCoinCap") and (Match.capped or Limits.coins().capped) then
            Match.status = "Stopped at the coin cap"
            Ui.set("AutoDuel", false)
            Ui.notify("Auto duel", "Coin cap reached: duels pay nothing more until the reset.", 8)
            return
        end
        Match.status = "Queueing (" .. Options.DuelMode.Value .. ")"
        if os.clock() - lastQueue > QUEUE_INTERVAL then
            lastQueue = os.clock()
            Env.event(QUEUE_REMOTE[Options.DuelMode.Value] or QUEUE_REMOTE[MODES[1]]):FireServer()
        end
        return
    end
    local phase = Match.phase()
    Match.status = phase == "Aiming" and (Match.aimLocked or handledAim == Match.aimToken)
        and "Aim selected (waiting for other players)" or "In a match: " .. tostring(phase)
    if phase == "Upgrading" and Match.upgradeOffer and handledUpgrade ~= Match.upgradeOffer then
        local offer = Match.upgradeOffer
        if upgrade(offer) then
            handledUpgrade = offer
        end
        return
    end
    if phase == "Picking" and Match.offer and handledOffer ~= Match.offer and not Match.ballLocked then
        local offer = Match.offer
        -- Cleared once per offer, not on every pass that is still waiting on a reroll or the
        -- teammate: last round's result line used to blink out of the panel four times a second.
        if seenOffer ~= offer then
            seenOffer, prediction = offer, nil
        end
        if pick(offer) then
            handledOffer = offer
        end
    elseif phase == "Aiming" then
        tryAim()
    end
end

Life.loop("duel:auto", 0.25, step)

Life.loop("duel:panel", 0.5, function()
    Match.prediction = prediction
    local lines = { "Status: " .. Match.status }
    if Match.seated() then
        local mine, theirs
        for _, player in ipairs(Match.players()) do
            if player.me then
                mine = Match.hp(player)
            elseif not player.teammate and not theirs then
                theirs = Match.hp(player)
            end
        end
        lines[#lines + 1] = string.format("%s, round %d: you %s hp, them %s hp", tostring(Match.tableId), Match.round(),
            tostring(mine or "?"), tostring(theirs or "?"))
        lines[#lines + 1] = Match.nextSeed() and "Seed: known (exact simulation)" or "Seed: unknown until round 1 is played"
    end
    if prediction then
        local result = prediction.result == true and " - won" or prediction.result == false and " - lost" or ""
        lines[#lines + 1] = prediction.text .. result
    end
    local rounds, matches = session.rounds, session.matches
    lines[#lines + 1] = string.format("Session: matches %d-%d, rounds %d-%d%s, +%d coins", matches.won, matches.lost,
        rounds.won, rounds.lost, rounds.draw > 0 and string.format(" (%d drawn)", rounds.draw) or "", session.coins)
    local coins = Limits.coins()
    local footer = coins.dayMax and string.format("Duel coins today: %d / %d, this week: %d / %d", coins.day, coins.dayMax,
        coins.week, coins.weekMax or 0) or ""
    panel.set(lines, footer)
end)

Life.onCleanup(function()
    table.clear(triedAt)
    table.clear(history)
    prediction, handledOffer, handledAim, handledUpgrade, seenOffer = nil, nil, nil, nil, nil
    Match.prediction = nil
    Trajectory.clear()
end)

return { history = history, session = session }
end
__modules["features/home"] = function(use) -- src/games/ballvsball/features/home.luau
-- Home tab: the shared welcome box (shared/home), your stats, and codes.
--
-- Codes come from the game's own config (Config.codes.list, which its redeem screen checks
-- against), so new ones are picked up without a hub update. "grantOnly" codes are handed out by
-- the developers and cannot be typed in. The server allows one redeem every 2 seconds and answers
-- SUCCESS, CLAIMED, EXPIRED or INVALID.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")
local Home = use("shared/home")
local Match = use("core/match")
local Limits = use("core/limits")

local REDEEM_INTERVAL = 2.5
local RESULTS = {
    SUCCESS = "redeemed now",
    CLAIMED = "already redeemed",
    EXPIRED = "expired",
    INVALID = "not valid",
    INVALID_CODE = "not valid",
}

local tab = Ui.Tabs.Home
local _, statusLabel = Home.build()
local statsBox = tab:AddGroupbox({ Side = "Right", Name = "You", IconName = "user" })
local codesBox = tab:AddGroupbox({ Side = "Right", Name = "Codes", IconName = "ticket" })

local stats = statsBox:AddLabel("Loading...", true)
Life.loop("home:stats", 1, function()
    statusLabel:SetText("Doing: " .. tostring(Match.status or "Idle"))
    local exp = Env.data("exp") or {}
    local ok, level = Env.call(Env.loadModule("ExperienceService").getLevelInfo, exp.total or 0)
    local matches, wins = 0, 0
    for _, mode in pairs(Env.data("matchStats") or {}) do
        matches += mode.matches or 0
        wins += mode.wins or 0
    end
    local coins = Limits.coins()
    stats:SetText(string.format(
        "Level %s\nCoins: %s  |  Diamonds: %s\nMatches: %d, won %d (%d%%)\nWin streak: %s (best %s)\nDuel coins today: %d / %s",
        ok and level and tostring(level.level) or "?",
        tostring(Env.data("coins") or "?"),
        tostring(Env.data("diamonds") or "?"),
        matches, wins, matches > 0 and math.floor(wins / matches * 100 + 0.5) or 0,
        tostring(Env.data("winStreak") or 0), tostring(Env.data("maxWinStreak") or 0),
        coins.day, tostring(coins.dayMax or "no cap")))
end)

local codeList = codesBox:AddLabel("Loading codes...", true)
local redeeming = false

local function redeemCodes()
    local lines = {}
    for _, entry in ipairs(Env.loadModule("Config").codes.list) do
        if not entry.grantOnly then
            if not Life.alive then return end
            local ok, result = Env.invoke("RedeemCodeRedeem", entry.code)
            if not Life.alive then return end
            local text = ok and (RESULTS[result] or tostring(result)) or "the game did not answer"
            lines[#lines + 1] = string.format("%s: %s", entry.code, text)
            Env.elevate()
            codeList:SetText(table.concat(lines, "\n"))
            if result == "SUCCESS" then
                Ui.notify("Codes", "Redeemed " .. entry.code, 5)
            end
            if not Life.wait(REDEEM_INTERVAL) then
                return
            end
        end
    end
    Env.elevate()
    codeList:SetText(#lines > 0 and table.concat(lines, "\n") or "No codes right now.")
end

local function startRedeeming()
    if redeeming or not Life.alive then return end
    redeeming = true
    Life.spawn("home:codes", function()
        Life.call("home:redeem", redeemCodes)
        redeeming = false
    end)
end

codesBox:AddToggle("RedeemOnLoad", {
    Text = "Redeem codes on load",
    Default = true,
    Tooltip = "Tries every code in the game's list once each time the hub loads.",
})
codesBox:AddButton({ Text = "Redeem codes", Func = function()
    startRedeeming()
end })

-- After the autoload, so a saved "off" is respected (main calls Home.afterLoad).
return {
    afterLoad = function()
        if Ui.on("RedeemOnLoad") then
            startRedeeming()
        else
            codeList:SetText("Press Redeem codes to try the game's codes.")
        end
    end,
}
end
__modules["features/intel"] = function(use) -- src/games/ballvsball/features/intel.luau
-- Intel tab: who you are playing, what the solver decided, and whether its predictions hold up.
--
-- Everything here is read-only. It reports on what features/duel publishes on Match (prediction,
-- history, session) and on core/profile's opponent model, so a broken panel can never change how
-- a round is played -- and checking the predictions against what actually happened is the only
-- honest way to know whether the solver is worth its think time.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")
local Match = use("core/match")
local Profile = use("core/profile")

local tab = Ui.Tabs.Intel

-- Opponents ----------------------------------------------------------------------------------

local opponentsBox = tab:AddGroupbox({ Side = "Left", Name = "Opponents", IconName = "users" })
local opponentsPanel = Ui.panel(opponentsBox, 6)
opponentsBox:AddButton({
    Text = "Forget opponents",
    Func = function()
        Profile.forget()
        Ui.notify("Intel", "Opponent history cleared. Everyone starts at the default aim-repeat guess again.", 5)
    end,
    Tooltip = "Clears every opponent's aim and ball history, here and in the saved file.",
})

local names = {}
local function nameOf(userId)
    if names[userId] == nil then
        local player = Env.Players:GetPlayerByUserId(userId)
        names[userId] = player and player.DisplayName ~= "" and player.DisplayName or false
    end
    return names[userId] or nil
end

Life.loop("intel:opponents", 1, function()
    local lines = {}
    if Match.seated() then
        local players = Match.players()
        for _, player in ipairs(players) do
            if not player.me then
                local tag = player.teammate and " (teammate)" or ""
                lines[#lines + 1] = Profile.describe(player, nameOf(player.userId)) .. tag
            end
        end
        lines[#lines + 1] = string.format("Chance the table repeats every aim: %d%%",
            math.floor(Profile.tableKeepRate(players) * 100 + 0.5))
    else
        lines[#lines + 1] = "Not at a table. Opponents show here once you sit down."
    end
    opponentsPanel.set(lines, string.format("%d opponents remembered", Profile.count()))
end)

-- Solver -------------------------------------------------------------------------------------

local solverBox = tab:AddGroupbox({ Side = "Right", Name = "Solver", IconName = "brain" })
local solverPanel = Ui.panel(solverBox, 6)

local function percent(value)
    return value and string.format("%d%%", math.floor(value * 100 + 0.5)) or "?"
end

local function outcomeName(value)
    if value == nil then
        return "?"
    end
    return value >= 1 and "win" or value >= 0.5 and "draw" or "loss"
end

Life.loop("intel:solver", 0.5, function()
    local prediction = Match.prediction
    local lines = {}
    local ours, theirs = Match.stakes()
    if Match.seated() then
        lines[#lines + 1] = string.format("Round %d | seed %s | hp %s vs %s", Match.round(),
            Match.nextSeed() and "known" or "unknown", tostring(ours or "?"), tostring(theirs or "?"))
    end
    if prediction and prediction.columns then
        lines[#lines + 1] = string.format("Expected result: %s", percent(prediction.expected))
        lines[#lines + 1] = string.format("Guaranteed floor: %s, whatever they aim", outcomeName(prediction.worst))
        lines[#lines + 1] = string.format("Beats %d of %d opponent aims", prediction.wins or 0, prediction.columns)
        lines[#lines + 1] = string.format("Risk weight %.2f (0 exploits, 1 plays safe), aim repeat %s",
            prediction.lambda or 0, percent(prediction.modelled))
    elseif prediction then
        lines[#lines + 1] = prediction.text
    else
        lines[#lines + 1] = "No round solved yet."
    end
    solverPanel.set(lines, "From round 2 every round is solved as a grid of your aims against theirs.")
end)

-- Accuracy -----------------------------------------------------------------------------------

local accuracyBox = tab:AddGroupbox({ Side = "Right", Name = "Prediction accuracy", IconName = "target" })
local accuracyPanel = Ui.panel(accuracyBox, 9)

Life.loop("intel:accuracy", 1, function()
    local history = Match.history or {}
    local judged, correct, seeds, seedsRight, kept, opponents = 0, 0, 0, 0, 0, 0
    for _, entry in ipairs(history) do
        if entry.predicted ~= nil and entry.won ~= nil then
            judged += 1
            correct += entry.predicted == entry.won and 1 or 0
        end
        if entry.seedRight ~= nil then
            seeds += 1
            seedsRight += entry.seedRight and 1 or 0
        end
        if entry.opponents then
            kept += entry.opponentsKept or 0
            opponents += entry.opponents
        end
    end
    local lines = {}
    lines[#lines + 1] = judged > 0 and string.format("Win/loss calls right: %d of %d (%d%%)", correct, judged,
        math.floor(correct / judged * 100 + 0.5)) or "Win/loss calls right: none judged yet"
    lines[#lines + 1] = seeds > 0 and string.format("Seed predicted exactly: %d of %d", seedsRight, seeds)
        or "Seed predicted exactly: from round 2"
    lines[#lines + 1] = opponents > 0 and string.format("Opponents repeated their aim: %d of %d", kept, opponents)
        or "Opponents repeated their aim: from round 2"
    -- The newest rounds, newest first.
    for index = #history, math.max(1, #history - 5), -1 do
        local entry = history[index]
        local result = entry.won == true and "won" or entry.won == false and "lost" or "drew"
        local call = entry.predicted == nil and "" or entry.predicted and ", called a win" or ", called a loss"
        lines[#lines + 1] = string.format("R%s %s: %s%s", tostring(entry.round), entry.balls or "?", result, call)
    end
    local session = Match.session
    local footer = session and string.format("Session: matches %d-%d, rounds %d-%d", session.matches.won,
        session.matches.lost, session.rounds.won, session.rounds.lost) or ""
    accuracyPanel.set(lines, footer)
end)

Life.onCleanup(function()
    table.clear(names)
end)

return {}
end
__modules["features/rewards"] = function(use) -- src/games/ballvsball/features/rewards.luau
-- Rewards tab: claims what the game hands out for free, and buys crates with coins.
--
-- Claims use the same remotes as the game's own UI, and the server
-- checks each one (progress, time online, day, already claimed), so a claim it refuses costs
-- nothing. What is claimable is read from the player's data as the client sees it:
--   daily quests   dailyQuest.progress/claimed vs Config.dailyQuest.list -> DailyQuestClaim(id)
--   online time    granted automatically by the updated server; display replicated progress only
--   check-in       CheckInService.client.getState() "claimable" days -> CheckInService.client.claim(day)
--   mail           mailbox.mails[id].claimedAt == 0 -> MailService/Claim(id)
-- Crates: GachaRoll(crateId, "coins"), rolled and granted by the server.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")
local Fusion = use("core/fusion")

local Options = Ui.Options
local Config = Env.loadModule("Config")

local CLAIM_INTERVAL = 15
local RETRY_AFTER = 120 -- seconds before a refused claim is tried again
local BUY_INTERVAL = 3

local tab = Ui.Tabs.Rewards
local claims = tab:AddGroupbox({ Side = "Left", Name = "Auto claim", IconName = "gift" })
claims:AddToggle("AutoClaim", {
    Text = "Auto claim rewards",
    Default = true,
    Tooltip = "Claims the ticked rewards as soon as the game says they are ready.",
})
Ui.automation("AutoClaim", true)
claims:AddToggle("ClaimQuests", { Text = "Daily quests", Default = true })
claims:AddToggle("ClaimOnline", {
    Text = "Show online reward progress", Default = true,
    Tooltip = "The game now claims online rewards automatically. This only controls their progress display.",
})
claims:AddToggle("ClaimCheckIn", { Text = "Daily check-in", Default = true })
claims:AddToggle("ClaimMail", { Text = "Mail", Default = true })
claims:AddToggle("ClaimLevelRewards", { Text = "Level milestone rewards", Default = true })
claims:AddToggle("ClaimFreeChests", { Text = "Free starter / first-race chests", Default = true })
claims:AddButton({
    Text = "Claim group reward",
    Func = function()
        Life.spawn("rewards:group", function()
            local ok, result = Env.invoke("GroupJoinRewardRequest")
            local text = ok and type(result) == "table" and (result.ok and "Claimed." or tostring(result.reason))
                or "The game did not answer."
            Ui.notify("Group reward", text, 5)
        end)
    end,
    Tooltip = "Only pays if you are in the game's group.",
})
local claimPanel = Ui.panel(claims, #Config.dailyQuest.list + 9)

-- Lock every attempt before sending, including successful claims awaiting data replication.
local attemptedAt = {}
local function mayTry(key)
    local now = os.clock()
    if not Life.alive or now - (attemptedAt[key] or -math.huge) < RETRY_AFTER then
        return false
    end
    attemptedAt[key] = now
    return true
end

local function claimed(ok, result, key)
    if not Life.alive then
        return false
    end
    local success = Life.alive and ok and type(result) == "table" and result.ok == true
    if not success then
        attemptedAt[key] = os.clock()
    end
    return success
end

-- These rewards are granted by the server. Ready releases queued results; it does not accept
-- a level or chest id. In particular FirstRaceFreeChestResult is receive-only.
local rewardLog, seenRewards, seenChests = {}, {}, {}
local levelMilestones, lastExp, levelReadySent = 0, nil, false
local function logReward(key, text, toggle)
    if not Life.alive or seenRewards[key] then
        return
    end
    seenRewards[key] = true
    rewardLog[#rewardLog + 1] = text
    if #rewardLog > 3 then
        table.remove(rewardLog, 1)
    end
    if Ui.on("AutoClaim") and Ui.on(toggle) then
        Env.elevate()
        Ui.notify("Free reward", text, 5)
    end
end

Life.connect(Env.event("LevelRewardResult").OnClientEvent, function(payload)
    if not Life.alive or type(payload) ~= "table" or payload.ok == false then
        return
    end
    for _, entry in ipairs(payload) do
        if type(entry) == "table" and type(entry.level) == "number" then
            local key = "level:" .. entry.level .. ":" .. tostring(entry.rewardId or entry.cnId)
            if not seenRewards[key] then
                levelMilestones += 1
            end
            logReward(key, string.format("Level %d reward claimed", entry.level), "ClaimLevelRewards")
        end
    end
end)

local function chestResult(kind, payload)
    if not Life.alive or type(payload) ~= "table" or payload.ok == false then
        return
    end
    local results = type(payload.results) == "table" and payload.results or payload
    if #results == 0 then
        return
    end
    seenChests[kind] = true
    logReward("chest:" .. kind, string.format("%s chest claimed (%d items)", kind, #results), "ClaimFreeChests")
end
Life.connect(Env.event("NewbieFreeChestResult").OnClientEvent, function(payload)
    chestResult("Starter", payload)
end)
Life.connect(Env.event("FirstRaceFreeChestResult").OnClientEvent, function(payload)
    chestResult("First race", payload)
end)

local function claimLevels(lines, allowed)
    local exp = Env.data("exp")
    local total = type(exp) == "table" and tonumber(exp.total)
    if allowed("ClaimLevelRewards") and (not levelReadySent or (total and total > (lastExp or -1)))
        and mayTry("level:ready") then
        Env.elevate()
        Env.event("LevelRewardReady"):FireServer()
        levelReadySent, lastExp = true, total
    end
    local state = Env.data("levelRewards") or {}
    local granted = {}
    for _, field in ipairs({ "grantedRewards", "grantedRandom" }) do
        for level in pairs(type(state[field]) == "table" and state[field] or {}) do
            granted[tostring(level)] = true
        end
    end
    local count = 0
    for _ in pairs(granted) do
        count += 1
    end
    lines[#lines + 1] = string.format("Level rewards: %d saved milestones, %d received this session", count, levelMilestones)
end

local newbieReadySent = false
local function claimFreeChests(lines, allowed)
    local starter = Env.data("hasClaimedNewbieFreeChestV2")
    local firstRace = Env.data("hasClaimedFirstRaceFreeChest")
    -- One initial handshake also flushes rewards granted before the hub loaded. Retry only
    -- while PlayerData says a starter reward is pending, at the normal refusal cooldown.
    if allowed("ClaimFreeChests") and not seenChests.Starter and starter ~= nil
        and (not newbieReadySent or starter == false) and mayTry("chest:ready") then
        Env.elevate()
        Env.event("NewbieFreeChestReady"):FireServer()
        newbieReadySent = true
    end
    lines[#lines + 1] = "Starter chest: " .. ((starter == true or seenChests.Starter) and "claimed" or "pending")
    lines[#lines + 1] = "First race chest: " .. ((firstRace == true or seenChests["First race"]) and "claimed" or "awaiting first race")
end

local function claimQuests(lines, allowed)
    local data = Env.data("dailyQuest") or {}
    local progress, done = data.progress or {}, data.claimed or {}
    for _, quest in ipairs(Config.dailyQuest.list) do
        local count = progress[quest.cnId] or 0
        local state = done[quest.cnId] and "claimed" or string.format("%d/%d", math.min(count, quest.requireCount), quest.requireCount)
        if not done[quest.cnId] and count >= quest.requireCount and allowed("ClaimQuests") and mayTry("quest:" .. quest.cnId) then
            local ok, result = Env.invoke("DailyQuestClaim", quest.cnId)
            if claimed(ok, result, "quest:" .. quest.cnId) then
                state = "claimed now"
                Ui.notify("Daily quest", string.format("%s: +%s coins", quest.desc, tostring(result.rewardCoins or quest.rewardCoins)), 5)
            end
        end
        lines[#lines + 1] = string.format("%s: %s (%d coins)", quest.desc, state, quest.rewardCoins)
    end
end

local function claimOnline(lines)
    if not Ui.on("ClaimOnline") then
        return
    end
    local data = Env.data("onlineReward") or {}
    local seconds, done = data.onlineSeconds or 0, data.claimed or {}
    local ok, tiers = Env.call(Env.loadModule("OnlineRewardConfig").getTiers)
    if not ok or type(tiers) ~= "table" or #tiers == 0 then
        lines[#lines + 1] = "Online rewards: waiting for reward tiers."
        return
    end
    local nextTier, pending = nil, 0
    for _, tier in ipairs(tiers) do
        local isDone = done[tostring(tier.index)] or done[tier.index]
        if not isDone and seconds >= tier.seconds then
            pending += 1
        end
        if not isDone and seconds < tier.seconds and (not nextTier or tier.seconds < nextTier.seconds) then
            nextTier = tier
        end
    end
    -- Do not poll OnlineRewardNotifications: that drains the game's own notification queue.
    local status = pending > 0 and string.format("%d rewards awaiting the game's auto claim", pending)
        or nextTier and string.format("next reward at %d min", nextTier.minutes) or "every reward claimed"
    lines[#lines + 1] = string.format("Online %d min today: %s", seconds // 60, status)
end

local function claimCheckIn(lines, allowed)
    local service = Env.loadModule("CheckInService").client
    local ok, days = Env.call(service.getState)
    if not ok or type(days) ~= "table" then
        return
    end
    local claimedDays = 0
    for _, day in ipairs(days) do
        if day.status == "claimable" and allowed("ClaimCheckIn") and mayTry("checkin:" .. day.dayIndex) then
            local sent, result = Env.call(service.claim, day.dayIndex)
            if claimed(sent, result, "checkin:" .. day.dayIndex) then
                day.status = "claimed"
                Ui.notify("Check-in", string.format("Claimed day %d", day.dayIndex), 5)
            end
        end
        if day.status == "claimed" then
            claimedDays += 1
        end
    end
    lines[#lines + 1] = string.format("Check-in: %d/%d days claimed", claimedDays, #days)
end

local function claimMail(lines, allowed)
    local mailbox = Env.data("mailbox") or {}
    local waiting = 0
    for id, mail in pairs(type(mailbox.mails) == "table" and mailbox.mails or {}) do
        if type(mail) == "table" and (mail.claimedAt or 0) <= 0 then
            if allowed("ClaimMail") and mayTry("mail:" .. id) then
                local ok, result = Env.invoke("MailService/Claim", id)
                if claimed(ok, result, "mail:" .. id) then
                    Ui.notify("Mail", "Claimed a mail reward", 5)
                else
                    waiting += 1
                end
            else
                waiting += 1
            end
        end
    end
    lines[#lines + 1] = waiting > 0 and string.format("Mail: %d unclaimed", waiting) or "Mail: nothing to claim"
end

Life.loop("rewards:claim", CLAIM_INTERVAL, function()
    local lines = {}
    -- With Auto claim off the panel still shows progress; nothing is claimed.
    local function allowed(toggle)
        return Life.alive and Ui.on("AutoClaim") and Ui.on(toggle)
    end
    for _, step in ipairs({ claimQuests, claimOnline, claimCheckIn, claimMail, claimLevels, claimFreeChests }) do
        step(lines, allowed)
        if not Life.alive then
            return
        end
    end
    for _, entry in ipairs(rewardLog) do
        lines[#lines + 1] = entry
    end
    claimPanel.set(lines, Ui.on("AutoClaim") and "Claiming automatically." or "Auto claim is off.")
end)

-- Fusion --------------------------------------------------------------------------------------------
local fusionBox = tab:AddGroupbox({ Side = "Right", Name = "Ball Fusion", IconName = "combine" })
fusionBox:AddToggle("AutoFuseDuplicates", {
    Text = "Auto fuse duplicates", Default = false,
    Tooltip = "Fuses duplicates toward the selected goal. Keeps one eligible copy per ball, form and trade status; equipped or locked copies are skipped.",
})
Ui.automation("AutoFuseDuplicates", true)
fusionBox:AddDropdown("FuseMode", {
    Text = "Fusion goal", Values = { "Higher rarity", "Shiny", "Rainbow" }, Default = "Higher rarity",
    Tooltip = "Higher rarity consumes ten Classic copies. Shiny consumes six Classic copies; Rainbow consumes six Shiny copies. One additional copy is kept.",
})
local rarityLabels, rarityByLabel, ratings = {}, {}, {}
for _, rating in ipairs(Config.rating.list) do
    if type(rating.lvl) == "number" then
        ratings[#ratings + 1] = rating
    end
end
table.sort(ratings, function(a, b) return a.lvl < b.lvl end)
for index = 1, #ratings do
    local rating = ratings[index]
    local label = rating.displayName or rating.name or (index == 1 and "Common" or "Uncommon")
    label = tostring(label) .. " (" .. rating.lvl .. ")"
    rarityLabels[#rarityLabels + 1], rarityByLabel[label] = label, rating.lvl
end
if #rarityLabels == 0 then
    rarityLabels, rarityByLabel = { "Common", "Uncommon" }, { Common = 1, Uncommon = 2 }
end
fusionBox:AddDropdown("FuseMaxRarity", {
    Text = "Maximum material rarity", Values = rarityLabels, Default = rarityLabels[math.min(2, #rarityLabels)],
})
local fusionLabel = fusionBox:AddLabel("Fusion is off.", true)
local reserved, fusedBatches = {}, 0
Life.loop("rewards:fusion", 1.5, function()
    if not Ui.on("AutoFuseDuplicates") then
        fusionLabel:SetText("Fusion is off.")
        return
    end
    local items = Env.data("items")
    if type(items) ~= "table" then
        fusionLabel:SetText("Waiting for inventory.")
        return
    end
    local mode = Options.FuseMode.Value
    local required = Fusion.requiredCount(mode)
    if not required then
        fusionLabel:SetText("Choose a fusion goal.")
        return
    end
    local function attemptKey(id)
        return "fusion:" .. mode .. ":" .. id
    end
    for id, untilAt in pairs(reserved) do
        if items[id] == nil or os.clock() >= untilAt then
            reserved[id] = nil
        end
    end
    local batch, ballId = Fusion.nextBatch(items, Env.data("equipment"),
        rarityByLabel[Options.FuseMaxRarity.Value] or -math.huge, reserved, function(id)
            return os.clock() - (attemptedAt[attemptKey(id)] or -math.huge) >= RETRY_AFTER
        end, mode)
    if not batch then
        fusionLabel:SetText(string.format("%d batches fused. %s needs %d matching copies plus one kept.", fusedBatches, mode, required))
        return
    end
    if not Ui.on("AutoFuseDuplicates") or not mayTry(attemptKey(ballId)) then
        return
    end
    -- Reserve before the yielding invoke so delayed PlayerData cannot resubmit consumed ids.
    for _, id in ipairs(batch) do
        reserved[id] = os.clock() + RETRY_AFTER
    end
    Env.elevate()
    fusionLabel:SetText("Fusing " .. Env.ballName(ballId) .. "...")
    local ok, result
    if mode == "Higher rarity" then
        ok, result = Env.invoke("FusionRequest", batch)
    else
        -- The form-upgrade remote takes one main id and five additional ids, not six materials.
        ok, result = Env.invoke("BallUpgradeRequest", batch[1], table.move(batch, 2, #batch, 1, {}))
    end
    if not Life.alive then
        return
    end
    if ok and type(result) == "table" and result.ok == true then
        for _, id in ipairs(batch) do
            reserved[id] = math.huge -- release only after replication removes the consumed item
        end
        attemptedAt[attemptKey(ballId)] = nil -- another disjoint batch may run in 1.5s
        fusedBatches += 1
        Env.elevate()
        local target = mode == "Higher rarity" and Env.ballName(result.cnId) or (mode .. " " .. Env.ballName(ballId))
        fusionLabel:SetText("Fused " .. Env.ballName(ballId) .. " into " .. target)
    else
        Env.elevate()
        if not ok then
            -- Transport failure does not prove the server rejected the materials.
            for _, id in ipairs(batch) do reserved[id] = math.huge end
        end
        fusionLabel:SetText("Fusion not confirmed: " .. tostring(type(result) == "table" and result.reason or result or "no response"))
    end
end)

-- Crates ---------------------------------------------------------------------------------------------

local crates = tab:AddGroupbox({ Side = "Right", Name = "Crates", IconName = "package" })
local crateByLabel, crateLabels = {}, {}
for _, crate in ipairs(Config.crate.list) do
    if crate.isForSale and type(crate.coinsPrice) == "number" and crate.coinsPrice > 0 then
        local label = string.format("%s x%d (%d coins)", crate.name, crate.drawCount or 1, crate.coinsPrice)
        crateByLabel[label] = crate
        crateLabels[#crateLabels + 1] = label
    end
end
crates:AddDropdown("CrateChoice", {
    Text = "Crate",
    Values = crateLabels,
    Default = crateLabels[1],
})
crates:AddSlider("CrateReserve", {
    Text = "Keep at least",
    Default = 0,
    Min = 0,
    Max = 20000,
    Rounding = 0,
    Suffix = " coins",
    Tooltip = "Auto buy never spends below this.",
})
crates:AddToggle("AutoBuyCrate", {
    Text = "Auto buy",
    Default = false,
    Tooltip = "Buys the crate with coins whenever you have its price plus the amount to keep.",
})
Ui.automation("AutoBuyCrate", true)
local crateLabel = crates:AddLabel("", true)

local function itemName(result)
    if type(result) ~= "table" then
        return "?"
    end
    local id = result.itemId or result.targetId or result.cnId
    local ball = id and Config.ball.byCnId[id]
    return ball and ball.displayName or tostring(id or result.itemType or "?")
end

local function buyCrate()
    local crate = crateByLabel[Options.CrateChoice.Value]
    if not crate then
        return false, "no crate chosen"
    end
    local ok, result = Env.invoke("GachaRoll", crate.cnId, "coins")
    if not ok or type(result) ~= "table" then
        return false, not ok and tostring(result) or "the game did not answer"
    end
    if not result.ok then
        return false, tostring(result.reason or "refused")
    end
    local names = {}
    for _, item in ipairs(type(result.results) == "table" and result.results or { result }) do
        names[#names + 1] = itemName(item)
    end
    return true, table.concat(names, ", ")
end

local function reportBuy(ok, text)
    if not Life.alive then return end
    Env.elevate()
    crateLabel:SetText(ok and "Last crate: " .. text or "Could not buy: " .. text)
end

crates:AddButton({
    Text = "Buy once",
    Func = function()
        Life.spawn("rewards:buy-once", function()
            reportBuy(buyCrate())
        end)
    end,
})

Life.loop("rewards:crates", BUY_INTERVAL, function()
    if not Ui.on("AutoBuyCrate") then
        return
    end
    local crate = crateByLabel[Options.CrateChoice.Value]
    local coins = Env.data("coins") or 0
    if crate and coins >= crate.coinsPrice + Options.CrateReserve.Value and mayTry("crate:" .. crate.cnId) then
        local ok, text = buyCrate()
        if not Life.alive then
            return
        end
        if ok then
            attemptedAt["crate:" .. crate.cnId] = nil
        end
        reportBuy(ok, text)
    end
end)

Life.onCleanup(function()
    table.clear(attemptedAt)
    table.clear(reserved)
    table.clear(rewardLog)
    table.clear(seenRewards)
    table.clear(seenChests)
end)

return {}
end
__modules["features/settings"] = function(use) -- src/games/ballvsball/features/settings.luau
-- Settings tab (see shared/settings): Ball VS Ball configs, and what each missing function changes.

use("core/ui")
local Settings = use("shared/settings")

return Settings.build({
    folder = "BallVsBall",
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
__modules["main"] = function(use) -- src/games/ballvsball/main.luau
-- Entry point. Core systems first, then features in tab order, then settings (autoload last).

-- The loader waits for this too, but the bundle can also be run on its own (a local build, an
-- auto-execute folder) before the game has finished loading.
if not game:IsLoaded() then
    local deadline = os.clock() + 90
    repeat task.wait(0.1) until game:IsLoaded() or os.clock() >= deadline
    assert(game:IsLoaded(), "Slopix: the game has not finished loading; run the script again once it loads")
end

local Env = use("core/env")
local Life = use("shared/life")
local activeBoot = Env.genv.__SlopixBallBoot
if type(activeBoot) == "table" and type(activeBoot.at) == "number" and os.clock() - activeBoot.at < 120 then
    return "Slopix Hub is already loading"
end
local bootToken = { at = os.clock() }
Env.genv.__SlopixBallBoot = bootToken
local Ui
local function boot()

-- Everything reads the game's own ModuleScripts. An executor that cannot require them cannot run
-- the hub, so that is said once here instead of by every feature failing on its own.
local canRequire, requireError = pcall(function()
    return Env.loadModule("Config")
end)
Env.elevate()
if not canRequire then
    error("your executor could not load the game's modules (require): " .. tostring(requireError), 0)
end

-- A copy already running (the bundle executed twice, or a local build after the loader's) is
-- closed first: two hubs fight over the game, and only the loader used to close the old one.
local previous = Env.genv.__SlopixHub
if type(previous) == "table" and type(previous.Ui) == "table" and previous.Ui.Library then
    if type(previous.Life) == "table" and type(previous.Life.shutdown) == "function" then
        pcall(previous.Life.shutdown)
    end
    pcall(previous.Ui.Library.Unload, previous.Ui.Library)
    Env.genv.__SlopixHub = nil
    Env.elevate()
end

Ui = use("core/ui")
local handle = { Ui = Ui, Life = Life, Features = {} }
Env.genv.__SlopixHub = handle
Life.onCleanup(function()
    Env.stopped = true
    if Env.genv.__SlopixHub == handle then Env.genv.__SlopixHub = nil end
end)

local FEATURES = {
    "features/home",
    "features/duel",
    "features/intel",
    "features/rewards",
}
-- One feature failing (a missing remote, a game update) is reported and the rest carry on.
local function load(name)
    if not Life.alive then return nil end
    local ok, result = xpcall(use, Env.traceback, name)
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
    Life.call("settings:autoload", Settings.finish)
end
-- After the autoload, so a saved "Redeem codes on load: off" is respected.
local Home = loaded["features/home"]
if Home then
    Life.call("home:after-load", Home.afterLoad)
end

-- Handle for debugging from Real (and for the next version to unload this one).
handle.Features = loaded
-- Match may be unavailable after a game update; that must not undo the working Settings tab.
local matchOk, match = pcall(use, "core/match")
handle.Match = matchOk and match or nil

if Life.alive and type(Env.RuntimeState) == "table" and type(Env.RuntimeState.onCleanup) == "function" then
    Env.RuntimeState.onCleanup(function()
        Env.elevate()
        pcall(function()
            Ui.Library:Unload()
        end)
    end)
end

return "Slopix Hub loaded"
end

local ok, result = xpcall(boot, Env.traceback)
if Env.genv.__SlopixBallBoot == bootToken then Env.genv.__SlopixBallBoot = nil end
if not ok then
    Life.shutdown()
    -- shared/ui stores the library before CreateWindow, allowing partial startup to be cleaned.
    local sharedUi = use("shared/ui")
    if sharedUi.Library then pcall(sharedUi.Library.Unload, sharedUi.Library) end
    error("[Slopix] " .. Env.executor .. ": " .. tostring(result), 0)
end
return result
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
