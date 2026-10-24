-- Reel Helper (Rayfield): Auto-hold keeps the zone on the fish
-- GUI path: PlayerGui > Front > MainFrame > ReelBar > Track > Lane > (Zone, Fish)
-- Game behavior: hold = zone moves RIGHT, release = zone moves LEFT

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local okVIM, VIM = pcall(function()
	return game:GetService("VirtualInputManager")
end)
if not okVIM then
	VIM = nil
end

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

-- state
local autoOn = false
local debugOn = false
local inputMethod = "Mouse"
local deadband = 12 -- px
local ctrlConn = nil
local holding = false
local inputBroken = false
local lane, zone, fish = nil, nil, nil
local wasFound = false
local errWarned = false
local lastFishX, lastMove, lastDbg = nil, 0, 0
local TOUCH_ID = 1

local function dbg(...)
	if debugOn then
		print("[ReelHelper]", ...)
	end
end

local function getPath(root, ...)
	local cur = root
	for _, name in ipairs({ ... }) do
		if not cur then
			return nil
		end
		cur = cur:FindFirstChild(name)
	end
	return cur
end

local function resolve()
	if lane and lane.Parent and zone and zone.Parent == lane and fish and fish.Parent == lane then
		return true
	end

	lane, zone, fish = nil, nil, nil
	lastFishX = nil

	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	local l = pg and getPath(pg, "Front", "MainFrame", "ReelBar", "Track", "Lane")
	local z = l and l:FindFirstChild("Zone")
	local f = l and l:FindFirstChild("Fish")

	if l and z and f and l:IsA("GuiObject") and z:IsA("GuiObject") and f:IsA("GuiObject") then
		lane, zone, fish = l, z, f
		if not wasFound then
			dbg("found Lane/Zone/Fish:", z.ClassName, f.ClassName)
		end
		wasFound = true
		return true
	end

	if wasFound then
		dbg("lost the reel bar (not fishing right now?)")
	end
	wasFound = false
	return false
end

-- true only if the gui and everything above it is actually visible
local function isShown(gui)
	local cur = gui
	while cur do
		if cur:IsA("GuiObject") and not cur.Visible then
			return false
		end
		if cur:IsA("ScreenGui") and not cur.Enabled then
			return false
		end
		cur = cur.Parent
	end
	return true
end

-- ===== input (hold / release) =====

local function tapPos()
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(800, 400)
	return vp.X * 0.5, vp.Y * 0.4
end

local function setHold(state)
	if holding == state then
		return
	end
	if inputBroken then
		return
	end
	if not VIM then
		inputBroken = true
		warn("[ReelHelper] VirtualInputManager not available in your executor")
		return
	end

	local x, y = tapPos()
	local ok, err = pcall(function()
		if inputMethod == "Touch" then
			VIM:SendTouchEvent(TOUCH_ID, state and 0 or 2, x, y)
		else
			VIM:SendMouseButtonEvent(x, y, 0, state, game, 0)
		end
	end)

	if ok then
		holding = state
		dbg(state and "HOLD" or "RELEASE")
	else
		inputBroken = true
		warn("[ReelHelper] input failed (" .. inputMethod .. "):", err)
		warn("[ReelHelper] try the other input method in the dropdown")
	end
end

-- ===== controller =====

local function ctrlStep()
	if not resolve() or not isShown(lane) or lane.AbsoluteSize.X <= 0 then
		setHold(false)
		return
	end

	local now = os.clock()

	-- only act while the fish is actually moving (so we don't click while idle)
	local fishX = fish.AbsolutePosition.X
	if lastFishX == nil or math.abs(fishX - lastFishX) > 0.5 then
		lastMove = now
	end
	lastFishX = fishX
	if now - lastMove > 0.75 then
		setHold(false)
		return
	end

	local fishC = fishX + fish.AbsoluteSize.X / 2
	local zoneC = zone.AbsolutePosition.X + zone.AbsoluteSize.X / 2
	local err = fishC - zoneC

	if err > deadband then
		setHold(true)
	elseif err < -deadband then
		setHold(false)
	end

	if debugOn and now - lastDbg > 0.5 then
		lastDbg = now
		print(string.format("[ReelHelper] fish %.0f | zone %.0f | err %.0f | holding %s", fishC, zoneC, err, tostring(holding)))
	end
end

local function onHeartbeat()
	local ok, err = pcall(ctrlStep)
	if not ok and not errWarned then
		errWarned = true
		warn("[ReelHelper] error:", err)
	end
end

local function startCtrl()
	if ctrlConn then
		return
	end
	inputBroken = false
	ctrlConn = RunService.Heartbeat:Connect(onHeartbeat)
	dbg("auto-hold started")
end

local function stopCtrl()
	if ctrlConn then
		ctrlConn:Disconnect()
		ctrlConn = nil
	end
	setHold(false)
	dbg("auto-hold stopped")
end

-- ===== UI =====

local Window = Rayfield:CreateWindow({
	Name = "Reel Helper",
	LoadingTitle = "Reel Helper",
	LoadingSubtitle = "auto-hold",
	ConfigurationSaving = { Enabled = false },
	KeySystem = false,
})

local Tab = Window:CreateTab("Reel", 4483362458)

Tab:CreateToggle({
	Name = "Auto hold",
	CurrentValue = false,
	Flag = "AutoHold",
	Callback = function(value)
		autoOn = value
		if value then
			startCtrl()
		else
			stopCtrl()
		end
	end,
})

Tab:CreateDropdown({
	Name = "Input method",
	Options = { "Mouse", "Touch" },
	CurrentOption = { "Mouse" },
	MultipleOptions = false,
	Flag = "InputMethod",
	Callback = function(option)
		local v = type(option) == "table" and option[1] or option
		if v == "Mouse" or v == "Touch" then
			setHold(false)
			inputMethod = v
			inputBroken = false
			dbg("input method:", v)
		end
	end,
})

Tab:CreateSlider({
	Name = "Deadband (px)",
	Range = { 0, 60 },
	Increment = 1,
	Suffix = "px",
	CurrentValue = 12,
	Flag = "Deadband",
	Callback = function(value)
		deadband = value
	end,
})

Tab:CreateToggle({
	Name = "Debug messages",
	CurrentValue = false,
	Flag = "ReelDebug",
	Callback = function(value)
		debugOn = value
	end,
})

Tab:CreateButton({
	Name = "Unload script",
	Callback = function()
		autoOn = false
		stopCtrl()
		Rayfield:Destroy()
	end,
})
