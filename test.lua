--[[
    PalantirX Auth Gate — Luarmor wrapper script.

    Role: hold the piracy-screen UI. The actual auth check + fingerprinting
    live in the PalantirX bundle's BlacklistCheck. This wrapper just exposes
    a function via getgenv() and hands off to the bundle.

    USAGE
        1. Paste this whole file into Luarmor as a NEW script in your
           PalantirX project (e.g. "PalantirX Gate").
        2. Luarmor wraps + Luraph-obfuscates it; you get a loader URL:
               https://api.luarmor.net/files/v4/loaders/<NEW_HASH>.lua
        3. Buyer template becomes:

               script_key = "..."
               getgenv().PalantirX_UserKey = script_key
               loadstring(game:HttpGet(
                   "https://api.luarmor.net/files/v4/loaders/<NEW_HASH>.lua"
               ))()

        4. PALANTIRX_BUNDLE_URL below stays pointed at the existing PalantirX
           bundle hash — we hand off to it at the bottom.

    FLOW
        - Build piracy-screen functions (regular + chase).
        - Expose them via getgenv().PalantirX_ShowPiracyScreen(screen, reason).
        - loadstring the PalantirX bundle.
        - When the bundle's BlacklistCheck gets a 403, it calls our exposed
          function — which renders the screen, waits, then kicks.
]]

local PALANTIRX_BUNDLE_URL   = "https://api.luarmor.net/files/v4/loaders/53b23657687b6fde91ec5a12589d6a4c.lua"
local PIRACY_SCREEN_DURATION = 8

-- Audio toggle. Set false to skip the download+play path entirely while
-- diagnosing crashes — if the screen renders without audio, the song is
-- the culprit (likely a getcustomasset size/format issue on the executor).
local ENABLE_SOUND      = false
local REGULAR_SOUND_URL = "https://files.catbox.moe/3e9ckp.mp3"
local SOUND_CACHE_FILE  = "PalantirX_Sounds/blacklist_regular.mp3"

-- ============================================================================
-- Services
-- ============================================================================

local Players              = game:GetService("Players")
local UserInputService     = game:GetService("UserInputService")
local CoreGui              = game:GetService("CoreGui")
local ContextActionService = game:GetService("ContextActionService")
local TweenService         = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer

-- ============================================================================
-- Halt — kick + finite wait + error so Roblox doesn't fire the long-yield
-- watchdog (which makes the screen look like a crash).
-- ============================================================================

local function halt(message)
    pcall(function()
        if LocalPlayer then
            LocalPlayer:Kick("\n" .. tostring(message) .. "\n")
        end
    end)
    task.wait(5)
    error("PalantirX: halted", 0)
end

-- ============================================================================
-- GUI helpers
-- ============================================================================

local SCREEN_NAMES = {
    chase   = "PalantirX_ChaseBan",
    regular = "PalantirX_Pirate",
}

local function getHostGui()
    if gethui then
        local ok, hui = pcall(gethui)
        if ok and hui then return hui end
    end
    local ok = pcall(function() return CoreGui:GetChildren() end)
    if ok then return CoreGui end
    return LocalPlayer:FindFirstChild("PlayerGui")
end

local function clearPriorScreens()
    for _, name in pairs(SCREEN_NAMES) do
        for _, parent in ipairs({ getHostGui(), CoreGui, LocalPlayer:FindFirstChild("PlayerGui") }) do
            if parent then
                local existing = parent:FindFirstChild(name)
                if existing then pcall(function() existing:Destroy() end) end
            end
        end
    end
end

-- ============================================================================
-- External sound: download via executor request -> writefile -> getcustomasset.
-- ============================================================================

local function loadExternalSound(url, cachePath)
    local req = (syn and syn.request) or http_request or request or (http and http.request)
    if not (req and writefile and isfile and getcustomasset) then return nil end
    if isfile(cachePath) then
        local ok, asset = pcall(getcustomasset, cachePath)
        if ok and asset then return asset end
    end
    if makefolder and isfolder then
        local folder = cachePath:match("^(.*)/[^/]*$")
        if folder and not isfolder(folder) then pcall(makefolder, folder) end
    end
    local ok, res = pcall(req, { Url = url, Method = "GET" })
    if not ok or type(res) ~= "table" then return nil end
    if res.StatusCode and res.StatusCode >= 400 then return nil end
    local body = res.Body
    if type(body) ~= "string" or #body == 0 then return nil end
    if not pcall(writefile, cachePath, body) then return nil end
    local got, asset = pcall(getcustomasset, cachePath)
    if got then return asset end
    return nil
end

-- ============================================================================
-- Input lock — modal pointer block + mouse pin + key/action sink.
-- Yield-prone ops live in task.spawn so this function returns instantly.
-- ============================================================================

local function lockInput(sg)
    local blocker = Instance.new("TextButton")
    blocker.Name = "InputBlocker"
    blocker.Modal = true
    blocker.Active = true
    blocker.AutoButtonColor = false
    blocker.BackgroundTransparency = 1
    blocker.Text = ""
    blocker.Size = UDim2.fromScale(1, 1)
    blocker.ZIndex = 100000
    blocker.Parent = sg

    task.spawn(function()
        while sg.Parent do
            if UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
                UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
            end
            if UserInputService.MouseIconEnabled then
                UserInputService.MouseIconEnabled = false
            end
            task.wait(0.05)
        end
    end)

    task.spawn(function()
        pcall(function()
            ContextActionService:BindAction(
                "PalantirX_LockKeys",
                function() return Enum.ContextActionResult.Sink end,
                false,
                Enum.KeyCode.Escape, Enum.KeyCode.Tab,
                Enum.KeyCode.LeftAlt, Enum.KeyCode.RightAlt,
                Enum.KeyCode.M, Enum.KeyCode.Slash,
                Enum.KeyCode.Quote, Enum.KeyCode.Backquote,
                Enum.KeyCode.F9, Enum.KeyCode.F10
            )
        end)
        pcall(function()
            for _, action in ipairs(Enum.PlayerActions:GetEnumItems()) do
                pcall(function()
                    ContextActionService:BindCoreAction(
                        "PalantirX_LockAction_" .. tostring(action.Name),
                        function() return Enum.ContextActionResult.Sink end,
                        false, action
                    )
                end)
            end
        end)
        pcall(function()
            local StarterGui = game:GetService("StarterGui")
            for _, ct in ipairs(Enum.CoreGuiType:GetEnumItems()) do
                pcall(function() StarterGui:SetCoreGuiEnabled(ct, false) end)
            end
            for _ = 1, 5 do
                local ok = pcall(function()
                    StarterGui:SetCore("ResetButtonCallback", false)
                end)
                if ok then break end
                task.wait(0.2)
            end
        end)
    end)
end

-- ============================================================================
-- CRT effect builders
-- ============================================================================

local function buildVignette(bg)
    local f = Instance.new("Frame")
    f.Size = UDim2.fromScale(1, 1)
    f.BackgroundColor3 = Color3.new(0, 0, 0)
    f.BackgroundTransparency = 1
    f.BorderSizePixel = 0
    f.ZIndex = 9
    f.Parent = bg
    local g = Instance.new("UIGradient")
    g.Rotation = 90
    g.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.3),
        NumberSequenceKeypoint.new(0.5, 1.0),
        NumberSequenceKeypoint.new(1, 0.3),
    })
    g.Parent = f
end

local function buildScanlines(bg)
    local stripes = Instance.new("Frame")
    stripes.Name = "Scanlines"
    stripes.Size = UDim2.fromScale(1, 1)
    stripes.BackgroundColor3 = Color3.new(0, 0, 0)
    stripes.BackgroundTransparency = 0
    stripes.BorderSizePixel = 0
    stripes.ZIndex = 10
    stripes.Parent = bg
    local stops = {}
    for i = 0, 19 do
        local t = i / 19
        local alpha = (i % 2 == 0) and 0.55 or 1.0
        stops[#stops + 1] = NumberSequenceKeypoint.new(t, alpha)
    end
    local g = Instance.new("UIGradient")
    g.Rotation = 90
    g.Transparency = NumberSequence.new(stops)
    g.Parent = stripes
end

local function buildRollingBar(bg)
    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(1, 0, 0, 120)
    bar.Position = UDim2.new(0, 0, 0, -120)
    bar.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    bar.BackgroundTransparency = 0.85
    bar.BorderSizePixel = 0
    bar.ZIndex = 12
    bar.Parent = bg
    local gradient = Instance.new("UIGradient")
    gradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1),
        NumberSequenceKeypoint.new(0.5, 0),
        NumberSequenceKeypoint.new(1, 1),
    })
    gradient.Rotation = 90
    gradient.Parent = bar
    task.spawn(function()
        while bar.Parent do
            bar.Position = UDim2.new(0, 0, 0, -120)
            local t = TweenService:Create(bar,
                TweenInfo.new(3.2, Enum.EasingStyle.Linear),
                { Position = UDim2.new(0, 0, 1, 120) }
            )
            t:Play()
            t.Completed:Wait()
            task.wait(math.random() * 1.4 + 0.6)
        end
    end)
end

local function buildFlicker(bg)
    local flash = Instance.new("Frame")
    flash.Size = UDim2.fromScale(1, 1)
    flash.BackgroundColor3 = Color3.new(1, 1, 1)
    flash.BackgroundTransparency = 1
    flash.BorderSizePixel = 0
    flash.ZIndex = 50
    flash.Parent = bg
    task.spawn(function()
        while flash.Parent do
            task.wait(math.random() * 1.8 + 0.6)
            if math.random() < 0.5 then
                flash.BackgroundTransparency = 0.9
                task.wait(0.04)
                flash.BackgroundTransparency = 1
            end
        end
    end)
end

-- ============================================================================
-- Screen builders
-- ============================================================================

local function showRegular(reason)
    clearPriorScreens()
    local sg = Instance.new("ScreenGui")
    sg.Name           = SCREEN_NAMES.regular
    sg.IgnoreGuiInset = true
    sg.ResetOnSpawn   = false
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.DisplayOrder   = 2147483647

    local bg = Instance.new("Frame")
    bg.Size = UDim2.fromScale(1, 1)
    bg.BackgroundColor3 = Color3.new(0, 0, 0)
    bg.BorderSizePixel = 0
    bg.ZIndex = 1
    bg.Parent = sg

    buildVignette(bg)
    buildScanlines(bg)
    buildRollingBar(bg)
    buildFlicker(bg)

    local header = Instance.new("TextLabel")
    header.AnchorPoint = Vector2.new(0.5, 0.5)
    header.Position    = UDim2.fromScale(0.5, 0.26)
    header.Size        = UDim2.fromScale(0.9, 0.18)
    header.BackgroundTransparency = 1
    header.RichText    = true
    header.Text        = "We've detected that you were "
                      .. "<font color=\"rgb(255,30,30)\"><b>blacklisted</b></font>"
    header.TextColor3  = Color3.fromRGB(235, 235, 235)
    header.TextScaled  = true
    header.TextWrapped = true
    header.Font        = Enum.Font.GothamBold
    header.TextStrokeTransparency = 0.4
    header.TextStrokeColor3       = Color3.new(0, 0, 0)
    header.ZIndex      = 20
    header.Parent      = bg

    local body1 = Instance.new("TextLabel")
    body1.AnchorPoint = Vector2.new(0.5, 0.5)
    body1.Position    = UDim2.fromScale(0.5, 0.50)
    body1.Size        = UDim2.fromScale(0.78, 0.18)
    body1.BackgroundTransparency = 1
    body1.Text        = "If you're keysharing, actively trying to reverse the script, "
                     .. "or not following TOS, please go on with your day and leave Palantir behind."
    body1.TextColor3  = Color3.fromRGB(215, 215, 215)
    body1.TextScaled  = true
    body1.TextWrapped = true
    body1.Font        = Enum.Font.Gotham
    body1.ZIndex      = 20
    body1.Parent      = bg

    local body2 = Instance.new("TextLabel")
    body2.AnchorPoint = Vector2.new(0.5, 0.5)
    body2.Position    = UDim2.fromScale(0.5, 0.73)
    body2.Size        = UDim2.fromScale(0.78, 0.12)
    body2.BackgroundTransparency = 1
    body2.Text        = "If you think this was a mistake, open a ticket in the official Palantir Discord server."
    body2.TextColor3  = Color3.fromRGB(215, 215, 215)
    body2.TextScaled  = true
    body2.TextWrapped = true
    body2.Font        = Enum.Font.Gotham
    body2.ZIndex      = 20
    body2.Parent      = bg

    local reasonLbl = Instance.new("TextLabel")
    reasonLbl.AnchorPoint = Vector2.new(0.5, 1)
    reasonLbl.Position    = UDim2.fromScale(0.5, 0.96)
    reasonLbl.Size        = UDim2.fromScale(0.7, 0.035)
    reasonLbl.BackgroundTransparency = 1
    reasonLbl.Text        = string.format("[ reason: %s ]", tostring(reason or "unknown"))
    reasonLbl.TextColor3  = Color3.fromRGB(160, 160, 160)
    reasonLbl.TextScaled  = true
    reasonLbl.Font        = Enum.Font.Code
    reasonLbl.TextTransparency = 0.25
    reasonLbl.ZIndex      = 20
    reasonLbl.Parent      = bg

    local host = getHostGui() or LocalPlayer:FindFirstChild("PlayerGui")
    pcall(function() sg.Parent = host end)

    lockInput(sg)

    if ENABLE_SOUND then
        task.spawn(function()
            local assetUrl = loadExternalSound(REGULAR_SOUND_URL, SOUND_CACHE_FILE)
            if not assetUrl then return end
            local sound = Instance.new("Sound")
            sound.Name    = "PiracySong"
            sound.SoundId = assetUrl
            sound.Volume  = 1
            sound.Looped  = true
            sound.Parent  = sg
            pcall(function() sound:Play() end)
        end)
    end
end

local function showChase(reason)
    clearPriorScreens()
    local sg = Instance.new("ScreenGui")
    sg.Name           = SCREEN_NAMES.chase
    sg.IgnoreGuiInset = true
    sg.ResetOnSpawn   = false
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.DisplayOrder   = 2147483647

    local bg = Instance.new("Frame")
    bg.Size = UDim2.fromScale(1, 1)
    bg.BackgroundColor3 = Color3.fromRGB(15, 0, 0)
    bg.BorderSizePixel = 0
    bg.Parent = sg

    local header = Instance.new("TextLabel")
    header.AnchorPoint = Vector2.new(0.5, 0.5)
    header.Position    = UDim2.fromScale(0.5, 0.4)
    header.Size        = UDim2.fromScale(0.85, 0.2)
    header.BackgroundTransparency = 1
    header.Text        = "CHASE BAN"
    header.TextColor3  = Color3.fromRGB(255, 35, 35)
    header.TextScaled  = true
    header.Font        = Enum.Font.GothamBlack
    header.Parent      = bg

    local reasonLbl = Instance.new("TextLabel")
    reasonLbl.AnchorPoint = Vector2.new(0.5, 0.5)
    reasonLbl.Position    = UDim2.fromScale(0.5, 0.6)
    reasonLbl.Size        = UDim2.fromScale(0.7, 0.06)
    reasonLbl.BackgroundTransparency = 1
    reasonLbl.Text        = tostring(reason or "")
    reasonLbl.TextColor3  = Color3.fromRGB(255, 255, 255)
    reasonLbl.TextScaled  = true
    reasonLbl.Font        = Enum.Font.Gotham
    reasonLbl.Parent      = bg

    local host = getHostGui() or LocalPlayer:FindFirstChild("PlayerGui")
    pcall(function() sg.Parent = host end)

    lockInput(sg)
end

-- ============================================================================
-- Expose a single entry point to the bundle and hand off.
-- The bundle's BlacklistCheck calls this on 403; it shows the screen, waits,
-- and never returns (Kick + error inside halt).
-- ============================================================================

if getgenv then
    getgenv().PalantirX_ShowPiracyScreen = function(screen, reason)
        if screen == "chase" then
            pcall(showChase, reason)
        else
            pcall(showRegular, reason)
        end
        task.wait(PIRACY_SCREEN_DURATION)
        halt(screen == "chase"
            and "Chase ban active. Do not return."
            or  "This license has been revoked.")
    end
end

-- Hand off to the actual PalantirX bundle. The bundle's BlacklistCheck runs
-- the auth check + fingerprinting and calls our exposed function on deny.
loadstring(game:HttpGet(PALANTIRX_BUNDLE_URL))()
