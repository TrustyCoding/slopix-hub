local REPOSITORY = "TrustyCoding/slopix-hub"
local BRANCH = "main"

-- IDs from ReplicatedStorage.CAM.Worlds in Scripts.rbxlx.
-- Upload the obfuscated MCP/slayers-2-obsidian.luau as games/136406881576517.lua.
-- Both Slayers 2 places use that one file.
local SCRIPT_BY_PLACE = {
    ["16205713724"] = "136406881576517", -- Main Menu
    ["136406881576517"] = "136406881576517", -- Ouwland (normal world)
}

local placeId = tostring(game.PlaceId)
local scriptId = SCRIPT_BY_PLACE[placeId] or placeId
local scriptPath = "games/" .. scriptId .. ".lua"
local url = ("https://raw.githubusercontent.com/%s/%s/%s"):format(REPOSITORY, BRANCH, scriptPath)

local ok, source = pcall(function()
    return game:HttpGet(url)
end)
if not ok then
    error(("Slopix Hub: could not load %s for place %s. The script may not be uploaded yet, or GitHub may be unavailable. Details: %s"):format(scriptPath, placeId, tostring(source)), 0)
end
if type(source) ~= "string" or source == "" or source:match("^404:") then
    error(("Slopix Hub: no script is available at %s for place %s"):format(scriptPath, placeId), 0)
end
local chunk, compileError = loadstring(source, "@slopix-hub/" .. scriptPath)
if not chunk then
    error("Slopix Hub: script compilation failed: " .. tostring(compileError), 0)
end
return chunk()
