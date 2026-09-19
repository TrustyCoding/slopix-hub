local REPOSITORY = "TrustyCoding/slopix-hub"
local BRANCH = "main"
local placeId = tostring(game.PlaceId)
local url = ("https://raw.githubusercontent.com/%s/%s/games/%s.lua"):format(REPOSITORY, BRANCH, placeId)

local ok, source = pcall(function()
    return game:HttpGet(url)
end)
if not ok then
    error(("Slopix Hub: could not load place %s. It may be unsupported, or GitHub may be unavailable. Details: %s"):format(placeId, tostring(source)), 0)
end
if type(source) ~= "string" or source == "" or source:match("^404:") then
    error("Slopix Hub: no script is available for place " .. placeId, 0)
end
local chunk, compileError = loadstring(source, "@slopix-hub/games/" .. placeId .. ".lua")
if not chunk then
    error("Slopix Hub: script compilation failed: " .. tostring(compileError), 0)
end
return chunk()
