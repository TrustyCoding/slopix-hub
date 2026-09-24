local REPO, BRANCH, SELF = "TrustyCoding/slopix-hub", "main", "loader.luau"
local INVITE, INVITE_COOLDOWN = "https://discord.gg/s5UNS2fdPh", 86400

local PLACES = {
    [16205713724] = "136406881576517",
    [136406881576517] = "136406881576517",
}

local genv = getgenv and getgenv() or _G
local queued = genv.SlopixAutoload == true
genv.SlopixAutoload = nil

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")

local function notify(text, duration)
    pcall(StarterGui.SetCore, StarterGui, "SendNotification", { Title = "Slopix Hub", Text = text, Duration = duration or 6 })
end

local id = PLACES[game.PlaceId]
if not id then
    if not queued then
        notify("Unsupported game.", 6)
    end
    return
end
if genv.SlopixLoading then
    return
end

local syn = getfenv().syn
local req = request or http_request or (http and http.request) or (syn and syn.request)
local queue = queueonteleport or queue_on_teleport or (syn and syn.queue_on_teleport)
local fs = writefile and readfile and isfile and isfolder and makefolder

local function raw(path)
    return ("https://raw.githubusercontent.com/%s/%s/%s"):format(REPO, BRANCH, path)
end

local function get(url)
    if req then
        local ok, res = pcall(req, { Url = url, Method = "GET" })
        if ok and type(res) == "table" then
            if res.StatusCode == 200 and type(res.Body) == "string" and res.Body ~= "" then
                return res.Body
            end
            return nil, "HTTP " .. tostring(res.StatusCode), res.StatusCode
        end
    end
    local ok, body = pcall(game.HttpGet, game, url)
    local code = ok and type(body) == "string" and tonumber(body:match("^(%d%d%d): "))
    if not ok or code or type(body) ~= "string" or body == "" then
        return nil, ok and ("HTTP " .. tostring(code)) or tostring(body), code
    end
    return body
end

local function fetch(path)
    local url, err = raw(path) .. "?t=" .. os.time() // 60, nil
    for i = 1, 3 do
        local body, reason, code = get(url)
        if body then
            return body
        end
        err = reason
        if code == 404 then
            break
        end
        task.wait(i)
    end
    return nil, err
end

local function mkdir(path)
    local cur = ""
    for part in path:gmatch("[^/]+") do
        cur = cur == "" and part or cur .. "/" .. part
        if not isfolder(cur) then
            makefolder(cur)
        end
    end
end

local function invite()
    if INVITE == "" or queued or genv.SlopixInvited then
        return
    end
    genv.SlopixInvited = true
    if fs then
        local ok, last = pcall(function()
            return isfile("SlopixHub/invite") and tonumber(readfile("SlopixHub/invite"))
        end)
        if ok and last and os.time() - last < INVITE_COOLDOWN then
            return
        end
        pcall(function()
            mkdir("SlopixHub")
            writefile("SlopixHub/invite", tostring(os.time()))
        end)
    end
    if req then
        local body = HttpService:JSONEncode({ cmd = "INVITE_BROWSER", nonce = HttpService:GenerateGUID(false), args = { code = INVITE } })
        for port = 6463, 6472 do
            local ok, res = pcall(req, {
                Url = ("http://127.0.0.1:%d/rpc?v=1"):format(port),
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json", Origin = "https://discord.com" },
                Body = body,
            })
            if ok and type(res) == "table" and res.StatusCode == 200 then
                break
            end
        end
    end
    local copy = setclipboard or toclipboard
    if copy then
        pcall(copy, "https://discord.gg/" .. INVITE)
    end
    notify("discord.gg/" .. INVITE .. " copied to clipboard.", 8)
end

local function boot()
    local path, cache = "games/" .. id .. ".lua", "SlopixHub/cache/" .. id .. ".lua"
    local src, err = fetch(path)
    if src and fs then
        pcall(function()
            mkdir("SlopixHub/cache")
            writefile(cache, src)
        end)
    elseif not src then
        local ok, cached = pcall(function()
            return fs and isfile(cache) and readfile(cache)
        end)
        if not ok or type(cached) ~= "string" or cached == "" then
            error(("%s: %s"):format(path, tostring(err)), 0)
        end
        src = cached
        notify("Offline, using cached build.", 6)
    end

    local fn, cerr = loadstring(src, "@slopix-hub/" .. path)
    if not fn then
        error(cerr, 0)
    end

    local old = genv.__SlopixHub
    if old and old.Ui and old.Ui.Library then
        pcall(old.Ui.Library.Unload, old.Ui.Library)
    end

    if queue and not genv.SlopixQueued then
        genv.SlopixQueued = true
        pcall(queue, ("getgenv().SlopixAutoload=true loadstring(game:HttpGet(%q))()"):format(raw(SELF)))
    end
    task.spawn(invite)
    return fn()
end

genv.SlopixLoading = true
local ok, res = xpcall(boot, debug.traceback)
genv.SlopixLoading = nil

if not ok then
    local exec = identifyexecutor and table.concat({ pcall(identifyexecutor) }, " ", 2) or "?"
    notify("Failed to load: " .. (tostring(res):match("^[^\n]+") or "?"), 10)
    error(("[Slopix] %s | %d | %s"):format(exec, game.PlaceId, tostring(res)), 0)
end
return res
