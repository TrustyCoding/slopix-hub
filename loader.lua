local REPO, BRANCH, SELF = "TrustyCoding/slopix-hub", "main", "loader.lua" -- the name it has on GitHub
local INVITE, INVITE_COOLDOWN = "s5UNS2fdPh", 86400 -- the invite code alone: discord.gg/<code>
-- The key site (docs/ on GitHub Pages). KEY_SECRET and KEY_HOURS must match CONFIG in its index.html.
local KEY_SITE = "https://trustycoding.github.io/slopix-hub/"
local KEY_SECRET, KEY_HOURS = "7WCEwbcXxO9H6UnSEjxWydpFCgyZ8w8W", 24

-- PlaceId -> the bundle it runs (games/<id>.lua in the repo). Every place of a game shares one.
local PLACES = {
    -- Slayers 2
    [16205713724] = "136406881576517", -- main menu
    [136406881576517] = "136406881576517",
    [75556147183481] = "136406881576517", -- Minigames place (Ouwigahara dungeon)
    -- Ball VS Ball
    [96510596525082] = "96510596525082",
}

local genv = getgenv and getgenv() or _G
local queued = genv.SlopixAutoload == true
genv.SlopixAutoload = nil

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")

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
-- A copy already loading (two queued reloads, a double execute) wins. The lock is a timestamp so
-- a copy that died mid-load cannot block every later one.
if type(genv.SlopixLoading) == "number" and os.clock() - genv.SlopixLoading < 90 then
    return
end

local syn, fluxus = getfenv().syn, getfenv().fluxus
local req = request or http_request or (http and http.request) or (syn and syn.request) or (fluxus and fluxus.request)
local queue = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)
local fs = writefile and readfile and isfile and isfolder and makefolder

local function raw(path)
    return ("https://raw.githubusercontent.com/%s/%s/%s"):format(REPO, BRANCH, path)
end

local function get(url)
    if req then
        local ok, res = pcall(req, { Url = url, Method = "GET" })
        if ok and type(res) == "table" and res.StatusCode ~= nil then
            local code = tonumber(res.StatusCode)
            if code == 200 and type(res.Body) == "string" and res.Body ~= "" then
                return res.Body
            end
            return nil, "HTTP " .. tostring(res.StatusCode), code
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
    local url, err = raw(path) .. "?t=" .. math.floor(os.time() / 60), nil
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

-- Key system -----------------------------------------------------------------------------------
-- The key site hands out SLOPIX-<expiry>-<signature> after two LootLabs steps: the expiry in unix
-- seconds (hex), the signature a hash of KEY_SECRET, the Roblox UserId and that expiry. So a key
-- works on the account it was made for, until it expires. The site signs with a JavaScript copy of
-- hash32, which has to stay identical to this one. Both files are public, so this stops key
-- sharing and skipped ads for everyone who does not read the source, not for those who do.

local KEY_FILE = "SlopixHub/key"
local setIdentity = setthreadidentity or set_thread_identity or setidentity or setthreadcontext

-- Real can drop the capability UI writes need after a yield (see Env.elevate in the hub).
local function elevate()
    if setIdentity then
        pcall(setIdentity, 8)
    end
end

-- a * b mod 2^32, split so no bits are lost to doubles (Math.imul in the site's copy).
local function mul32(a, b)
    return (bit32.band(a, 0xFFFF) * b + bit32.rshift(a, 16) * b % 0x10000 * 0x10000) % 0x100000000
end

-- FNV-1a from `seed` over the bytes of text, then murmur3's finaliser.
local function hash32(text, seed)
    local h = seed
    for index = 1, #text do
        h = mul32(bit32.bxor(h, text:byte(index)), 16777619)
    end
    h = mul32(bit32.bxor(h, bit32.rshift(h, 16)), 0x85EBCA6B)
    h = mul32(bit32.bxor(h, bit32.rshift(h, 13)), 0xC2B2AE35)
    return bit32.bxor(h, bit32.rshift(h, 16))
end

local function keySignature(userId, expiryHex)
    local text = KEY_SECRET .. "|" .. userId .. "|" .. expiryHex
    return ("%08X%08X"):format(hash32(text, 0x811C9DC5), hash32(text, 0x2F6B7C3D))
end

-- Why `key` (already cleaned) does not work for this account right now, or nil when it does.
local function keyProblem(key)
    local expiryHex, signature = key:match("^SLOPIX%-(%x+)%-(%x+)$")
    local expiry = expiryHex and tonumber(expiryHex, 16)
    if not expiry then
        return "That is not a Slopix key."
    end
    local left = expiry - os.time()
    if left <= 0 then
        return "That key has expired, get a new one."
    end
    -- More than a whole key's life left means it was made on a clock set far ahead.
    if left > (KEY_HOURS + 1) * 3600 or signature ~= keySignature(tostring(Players.LocalPlayer.UserId), expiryHex) then
        return "That key is for another account."
    end
    return nil
end

local function cleanKey(key)
    return type(key) == "string" and key:gsub("%s+", ""):upper() or ""
end

-- A key that still works: the one the last load passed on (getgenv().SlopixKey, which is also
-- how a key can be given up front), else the one saved on disk.
local function savedKey()
    local ok, saved = pcall(function()
        return fs and isfile(KEY_FILE) and readfile(KEY_FILE)
    end)
    for _, key in ipairs({ cleanKey(genv.SlopixKey), cleanKey(ok and saved) }) do
        if key ~= "" and not keyProblem(key) then
            return key
        end
    end
    return nil
end

local function make(class, props, parent)
    local instance = Instance.new(class)
    for name, value in pairs(props) do
        instance[name] = value
    end
    instance.Parent = parent
    return instance
end

-- Opens the key window and waits. Returns the key once one checks out, or nil if it is closed.
local function askKey()
    elevate()
    local link = KEY_SITE .. "?id=" .. Players.LocalPlayer.UserId
    local font = "rbxasset://fonts/families/BuilderSans.json"
    local colors = {
        back = Color3.fromHex("0d0c12"),
        main = Color3.fromHex("1e1b28"),
        accent = Color3.fromHex("eb4060"),
        outline = Color3.fromHex("302b3e"),
        text = Color3.fromHex("f0eef6"),
        muted = Color3.fromHex("a39fb3"),
        good = Color3.fromHex("5fd38d"),
    }

    local gui = make("ScreenGui", { Name = "SlopixKey", ResetOnSpawn = false, DisplayOrder = 1000, IgnoreGuiInset = true })
    local placed = pcall(function()
        gui.Parent = gethui and gethui() or game:GetService("CoreGui")
    end)
    if not placed then
        gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
    end
    genv.SlopixKeyWindow = gui

    local window = make("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(340, 200),
        BackgroundColor3 = colors.back,
    }, gui)
    make("UICorner", { CornerRadius = UDim.new(0, 8) }, window)
    make("UIStroke", { Color = colors.outline }, window)

    local function label(text, y, height, size, weight, color)
        return make("TextLabel", {
            Position = UDim2.fromOffset(16, y),
            Size = UDim2.new(1, -32, 0, height),
            BackgroundTransparency = 1,
            Text = text,
            TextSize = size,
            FontFace = Font.new(font, weight),
            TextColor3 = color,
            TextWrapped = true,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, window)
    end
    label("Slopix Hub", 12, 24, 20, Enum.FontWeight.Bold, colors.text)
    label("Copy the link, get your key in your browser, then paste it here.", 38, 34, 15, Enum.FontWeight.Regular, colors.muted)
    local status = label("", 170, 20, 14, Enum.FontWeight.Medium, colors.muted)

    local box = make("TextBox", {
        Position = UDim2.fromOffset(16, 80),
        Size = UDim2.new(1, -32, 0, 36),
        BackgroundColor3 = colors.main,
        ClearTextOnFocus = false,
        PlaceholderText = "Paste your key here",
        PlaceholderColor3 = colors.muted,
        Text = "",
        TextSize = 15,
        FontFace = Font.new(font, Enum.FontWeight.Medium),
        TextColor3 = colors.text,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, window)
    make("UICorner", { CornerRadius = UDim.new(0, 6) }, box)
    make("UIStroke", { Color = colors.outline, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, box)

    local function button(text, x, color, onClick)
        local instance = make("TextButton", {
            Position = UDim2.new(x, x == 0 and 16 or 6, 0, 126),
            Size = UDim2.new(0.5, -22, 0, 34),
            BackgroundColor3 = color,
            AutoButtonColor = true,
            Text = text,
            TextSize = 15,
            FontFace = Font.new(font, Enum.FontWeight.Bold),
            TextColor3 = colors.text,
        }, window)
        make("UICorner", { CornerRadius = UDim.new(0, 6) }, instance)
        instance.MouseButton1Click:Connect(function()
            elevate()
            onClick()
        end)
        return instance
    end

    local function say(text, color)
        status.Text = text
        status.TextColor3 = color or colors.muted
    end

    local accepted
    button("Copy link", 0, colors.main, function()
        local copy = setclipboard or toclipboard
        if copy and pcall(copy, link) then
            say("Link copied. Open it in your browser.")
        else
            say("Open the link in the notification.")
            notify(link, 20)
        end
    end)
    local function check()
        local key = cleanKey(box.Text)
        local problem = key == "" and "Paste your key first." or keyProblem(key)
        if problem then
            say(problem, colors.accent)
            return
        end
        accepted = key
        say("Key accepted.", colors.good)
        task.delay(0.4, function()
            gui:Destroy()
        end)
    end
    button("Check key", 0.5, colors.accent, check)
    box.FocusLost:Connect(function(enter)
        elevate()
        if enter then
            check()
        end
    end)
    local close = make("TextButton", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -10, 0, 10),
        Size = UDim2.fromOffset(26, 26),
        BackgroundTransparency = 1,
        Text = "X",
        TextSize = 16,
        FontFace = Font.new(font, Enum.FontWeight.Bold),
        TextColor3 = colors.muted,
    }, window)
    close.MouseButton1Click:Connect(function()
        gui:Destroy()
    end)

    -- A saved key that ran out is why the window is back: say so.
    local ok, saved = pcall(function()
        return fs and isfile(KEY_FILE) and readfile(KEY_FILE)
    end)
    if ok and cleanKey(saved) ~= "" then
        say(keyProblem(cleanKey(saved)) or "")
    end

    while gui.Parent and not accepted do
        task.wait(0.2)
    end
    elevate()
    if accepted then
        pcall(function()
            mkdir("SlopixHub")
            writefile(KEY_FILE, accepted)
        end)
    end
    return accepted
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

    -- Real's HttpGet returns "429: ..." as the body instead of throwing, so the queued snippet
    -- checks what it got and retries rather than calling a nil loadstring after the teleport.
    -- It carries the key along for executors without file functions to have saved it.
    if queue and not genv.SlopixQueued then
        genv.SlopixQueued = true
        pcall(queue, ("local g=getgenv and getgenv() or _G g.SlopixAutoload=true g.SlopixKey=%q "
            .. "for i=1,3 do local ok,s=pcall(game.HttpGet,game,%q) "
            .. "local f=ok and type(s)=='string' and not s:find('^%%d%%d%%d: ') and loadstring(s) "
            .. "if f then return f() end task.wait(i*2) end "
            .. "warn('[Slopix] could not download the loader after the teleport')"):format(genv.SlopixKey, raw(SELF)))
    end
    task.spawn(invite)
    return fn()
end

-- Asked before the load lock is taken: getting a key takes minutes, the lock only 90 seconds.
-- An execute while the window is up leaves the window to it.
local key = savedKey()
if not key then
    local open = genv.SlopixKeyWindow
    if typeof(open) == "Instance" and open.Parent then
        notify("Enter your key in the Slopix Hub window.", 5)
        return
    end
    key = askKey()
    if not key then
        notify("No key entered, the hub was not loaded.", 5)
        return
    end
    local left = (tonumber(key:match("^SLOPIX%-(%x+)"), 16) or 0) - os.time()
    notify(("Key accepted, %dh %dm left on it."):format(left // 3600, left % 3600 // 60), 6)
end
genv.SlopixKey = key

genv.SlopixLoading = os.clock()
local ok, res = xpcall(boot, debug.traceback)
genv.SlopixLoading = nil

if not ok then
    local exec = identifyexecutor and table.concat({ pcall(identifyexecutor) }, " ", 2) or "?"
    notify("Failed to load: " .. (tostring(res):match("^[^\n]+") or "?"), 10)
    error(("[Slopix] %s | %d | %s"):format(exec, game.PlaceId, tostring(res)), 0)
end
return res
