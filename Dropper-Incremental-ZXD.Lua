-- Reel Helper v4: auto-hold to keep the zone on the fish (Rayfield)
-- GUI path: PlayerGui > Front > MainFrame > ReelBar > Track > Lane > (Zone, Fish)
-- Remote (spy only): ReplicatedStorage > Remotes > Fishing

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

local okVIM, VIM = pcall(function()
	return game:GetService("VirtualInputManager")
end)
if not okVIM then
	VIM = nil
end

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

pcall(function()
	RunService:UnbindFromRenderStep("ZoneFollowFish") -- leftover from older versions
end)

-- state
local autoOn = false
local debugOn = false
local spyOn = false
local invert = false -- turn on if holding moves the zone LEFT
local inputMethod = "Mouse"
local deadband = 12 -- px
local ctrlConn = nil
local holding = false
local inputBroken = false
local hookInstalled = false
local lane, zone, fish = nil, nil, nil
local fishingRemote = nil
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

local function getFishingRemote()
	if fishingRemote and fishingRemote.Parent then
		return fishingRemote
	end
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local r = remotes and remotes:FindFirstChild("Fishing")
	if r and r:IsA("RemoteEvent") then
		fishingRemote = r
		return r
	end
	fishingRemote = nil
	return nil
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

local function guiInZone()
	if not resolve() then
		return nil
	end
	local fishCenter = fish.AbsolutePosition.X + fish.AbsoluteSize.X / 2
	local zl = zone.AbsolutePosition.X
	return fishCenter >= zl and fishCenter <= zl + zone.AbsoluteSize.X
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
	if invert then
		err = -err
	end

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

-- ===== fishing remote spy (finder) =====

local function fmtArgs(...)
	local packed = table.pack(...)
	local out = {}
	for i = 1, math.min(packed.n, 6) do
		local v = packed[i]
		local ok, s = pcall(tostring, v)
		out[#out + 1] = typeof(v) .. ":" .. (ok and s or "?")
	end
	return table.concat(out, ", ")
end

local function installSpyHook()
	if hookInstalled then
		return true
	end
	if not (hookmetamethod and getnamecallmethod) then
		warn("[ReelHelper] your executor has no hookmetamethod/getnamecallmethod, spy not available")
		return false
	end

	local wrap = newcclosure or function(f)
		return f
	end

	local ok, err = pcall(function()
		local old
		old = hookmetamethod(game, "__namecall", wrap(function(self, ...)
			local method = getnamecallmethod()
			if spyOn and method == "FireServer" and self == fishingRemote then
				local args = fmtArgs(...)
				local inZone = nil
				pcall(function()
					inZone = guiInZone()
				end)
				print("[Spy] Fishing:", args, "| GUI says fish in zone:", tostring(inZone))
			end
			return old(self, ...)
		end))
	end)

	if not ok then
		warn("[ReelHelper] hook failed:", err)
		return false
	end

	hookInstalled = true
	return true
end

-- ===== UI =====

local Window = Rayfield:CreateWindow({
	Name = "Reel Helper",
	LoadingTitle = "Reel Helper",
	LoadingSubtitle = "auto-hold follows fish",
	ConfigurationSaving = { Enabled = false },
	KeySystem = false,
})

local Tab = Window:CreateTab("Reel", 4483362458)

Tab:CreateToggle({
	Name = "Auto-hold (keeps zone on fish)",
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

Tab:CreateToggle({
	Name = "Invert (holding moves zone LEFT)",
	CurrentValue = false,
	Flag = "InvertHold",
	Callback = function(value)
		invert = value
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

local FinderTab = Window:CreateTab("Finder", 4483362458)

FinderTab:CreateToggle({
	Name = "Fishing remote spy",
	CurrentValue = false,
	Flag = "ReelSpy",
	Callback = function(value)
		if value then
			if not getFishingRemote() then
				warn("[ReelHelper] couldn't find ReplicatedStorage.Remotes.Fishing")
			end
			if installSpyHook() then
				spyOn = true
				print("[ReelHelper] spy ON, go reel a fish")
			else
				spyOn = false
			end
		else
			spyOn = false
			print("[ReelHelper] spy OFF")
		end
	end,
})

FinderTab:CreateButton({
	Name = "Print status",
	Callback = function()
		local found = resolve()
		print("[ReelHelper] auto:", autoOn, "| invert:", invert, "| input:", inputMethod, "| broken:", inputBroken, "| gui found:", found)
		if found then
			print("Zone:", zone.ClassName, zone.Position, zone.AbsoluteSize)
			print("Fish:", fish.ClassName, fish.Position, fish.AbsoluteSize)
			print("GUI says fish in zone:", tostring(guiInZone()))
		end
	end,
})

FinderTab:CreateButton({
	Name = "Unload script",
	Callback = function()
		autoOn = false
		spyOn = false -- hook can't be removed, but it just passes calls through when off
		stopCtrl()
		Rayfield:Destroy()
	end,
})
