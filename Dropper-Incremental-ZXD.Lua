-- Reel Helper (Rayfield): Auto hold + Coins (pull to me)
-- Reel GUI: PlayerGui > Front > MainFrame > ReelBar > Track > Lane > (Zone, Fish)
-- Coins:    workspace > MapEssentials > Spawned > Number (MeshPart, positioned with CFrame)
-- Game behavior while reeling: hold = zone moves RIGHT, release = zone moves LEFT

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

-- ===== shared state =====
local alive = true
local debugOn = false
local conn = nil
local errWarned = false

-- auto hold
local autoOn = false
local inputMethod = "Mouse"
local deadband = 12 -- px
local holding = false
local inputBroken = false
local lane, zone, fish = nil, nil, nil
local wasFound = false
local lastFishX, lastMove, lastDbg = nil, 0, 0
local reelBusy = false -- true while the reel minigame is running
local TOUCH_ID = 1

-- coins
local collectOn = false
local returnOn = true
local coinMethod = "Pull" -- "Pull", "Teleport" or "Touch"
local delaySec = 0.15
local pullInterval = 0.1
local maxDist = 0 -- 0 = no limit
local runId = 0
local originCF = nil
local lastPull, lastPullDbg = 0, 0
local touchWarned = false
local missingWarned = false
local attempts = setmetatable({}, { __mode = "k" })
local blacklist = setmetatable({}, { __mode = "k" })

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

local function getHRP()
	local char = LocalPlayer.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- ===== reel GUI =====

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

-- reel bar showing AND the fish is actually moving
local function reelActive(now)
	if not resolve() or not isShown(lane) or lane.AbsoluteSize.X <= 0 then
		lastFishX = nil
		return false
	end
	local fishX = fish.AbsolutePosition.X
	if lastFishX == nil or math.abs(fishX - lastFishX) > 0.5 then
		lastMove = now
	end
	lastFishX = fishX
	return (now - lastMove) <= 0.75
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

-- ===== auto hold logic =====

local function holdLogic(now)
	local fishC = fish.AbsolutePosition.X + fish.AbsoluteSize.X / 2
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

-- ===== coins =====

local function getSpawned()
	local me = workspace:FindFirstChild("MapEssentials")
	return me and me:FindFirstChild("Spawned")
end

-- PULL mode: moves every coin to your character
local function pullCoins(now)
	if now - lastPull < pullInterval then
		return
	end
	lastPull = now

	local hrp = getHRP()
	if not hrp then
		return
	end

	local folder = getSpawned()
	if not folder then
		if not missingWarned then
			missingWarned = true
			warn("[ReelHelper] couldn't find workspace.MapEssentials.Spawned")
		end
		return
	end
	missingWarned = false

	local target = hrp.CFrame
	local count = 0
	for _, c in ipairs(folder:GetChildren()) do
		if c:IsA("BasePart") then
			if maxDist <= 0 or (c.Position - hrp.Position).Magnitude <= maxDist then
				pcall(function()
					c.CanCollide = false -- so coins don't shove you around
					c.CFrame = target
				end)
				count += 1
			end
		end
	end

	if debugOn and count > 0 and now - lastPullDbg > 1 then
		lastPullDbg = now
		print("[ReelHelper] pulled", count, "coins to you")
	end
end

-- TELEPORT / TOUCH modes: goes to the nearest coin, returns true if it tried to collect one
local function collectOne()
	local hrp = getHRP()
	if not hrp then
		return false
	end

	local folder = getSpawned()
	if not folder then
		if not missingWarned then
			missingWarned = true
			warn("[ReelHelper] couldn't find workspace.MapEssentials.Spawned")
		end
		return false
	end
	missingWarned = false

	local now = os.clock()
	local best, bestDist = nil, math.huge
	for _, c in ipairs(folder:GetChildren()) do
		if c:IsA("BasePart") and (not blacklist[c] or blacklist[c] < now) then
			local d = (c.Position - hrp.Position).Magnitude
			if (maxDist <= 0 or d <= maxDist) and d < bestDist then
				best, bestDist = c, d
			end
		end
	end

	if not best then
		return false
	end

	if not originCF then
		originCF = hrp.CFrame
	end

	-- if a coin won't collect after a few tries, skip it for a bit
	attempts[best] = (attempts[best] or 0) + 1
	if attempts[best] > 4 then
		blacklist[best] = now + 3
		attempts[best] = nil
		dbg("skipping stubborn coin:", best.Name)
		return true
	end

	dbg("collecting", best.Name, string.format("(%.0f studs)", bestDist), "via", coinMethod)

	if coinMethod == "Touch" and firetouchinterest then
		firetouchinterest(hrp, best, 0)
		task.wait()
		firetouchinterest(hrp, best, 1)
	else
		if coinMethod == "Touch" and not touchWarned then
			touchWarned = true
			warn("[ReelHelper] your executor has no firetouchinterest, using Teleport instead")
		end
		hrp.CFrame = best.CFrame
		hrp.AssemblyLinearVelocity = Vector3.zero
	end

	return true
end

local function startCollect()
	runId += 1
	local myId = runId
	originCF = nil

	-- Pull mode runs inside the main Heartbeat loop, no extra loop needed
	if coinMethod == "Pull" then
		dbg("coin collector started (pull mode)")
		return
	end

	task.spawn(function()
		local hadCoins = false
		local coinErrWarned = false

		while alive and collectOn and runId == myId do
			if reelBusy then
				-- don't teleport away while reeling a fish
				task.wait(0.25)
			else
				local ok, result = pcall(collectOne)

				if ok and result then
					hadCoins = true
					task.wait(delaySec)
				else
					if not ok and not coinErrWarned then
						coinErrWarned = true
						warn("[ReelHelper] coin error:", result)
					end

					-- no coins left: go back to where we started
					if hadCoins and returnOn and originCF then
						pcall(function()
							local hrp = getHRP()
							if hrp then
								hrp.CFrame = originCF
								dbg("returned to start spot")
							end
						end)
					end
					if hadCoins then
						originCF = nil
					end
					hadCoins = false
					task.wait(0.5)
				end
			end
		end
	end)
end

local function stopCollect()
	runId += 1 -- ends any running coin loop
	dbg("coin collector stopped")
end

-- ===== main loop =====

local function step()
	local now = os.clock()
	local active = reelActive(now)
	reelBusy = active

	if autoOn and active then
		holdLogic(now)
	else
		setHold(false)
	end

	if collectOn and coinMethod == "Pull" then
		pullCoins(now)
	end
end

local function onHeartbeat()
	local ok, err = pcall(step)
	if not ok and not errWarned then
		errWarned = true
		warn("[ReelHelper] error:", err)
	end
end

-- ===== cleanup =====

local function cleanup()
	alive = false
	autoOn = false
	collectOn = false
	stopCollect()
	if conn then
		conn:Disconnect()
		conn = nil
	end
	setHold(false)
end

-- ===== UI =====

local Window = Rayfield:CreateWindow({
	Name = "Reel Helper",
	LoadingTitle = "Reel Helper",
	LoadingSubtitle = "auto hold + coins",
	ConfigurationSaving = { Enabled = false },
	KeySystem = false,
})

local FishTab = Window:CreateTab("Fishing", 4483362458)

FishTab:CreateButton({
	Name = "Unload script",
	Callback = function()
		cleanup()
		Rayfield:Destroy()
	end,
})

FishTab:CreateToggle({
	Name = "Auto hold",
	CurrentValue = false,
	Flag = "AutoHold",
	Callback = function(value)
		autoOn = value
		if not value then
			setHold(false)
		end
		dbg("auto hold:", value)
	end,
})

FishTab:CreateDropdown({
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

FishTab:CreateSlider({
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

FishTab:CreateToggle({
	Name = "Debug messages (everything)",
	CurrentValue = false,
	Flag = "ReelDebug",
	Callback = function(value)
		debugOn = value
	end,
})

local CoinTab = Window:CreateTab("Coins", 4483362458)

CoinTab:CreateToggle({
	Name = "Auto collect coins",
	CurrentValue = false,
	Flag = "AutoCollectCoins",
	Callback = function(value)
		collectOn = value
		if value then
			startCollect()
		else
			stopCollect()
		end
	end,
})

CoinTab:CreateDropdown({
	Name = "Method",
	Options = { "Pull to me", "Teleport to coin", "Touch" },
	CurrentOption = { "Pull to me" },
	MultipleOptions = false,
	Flag = "CollectMethod",
	Callback = function(option)
		local v = type(option) == "table" and option[1] or option
		local newMethod = nil
		if v == "Pull to me" then
			newMethod = "Pull"
		elseif v == "Teleport to coin" then
			newMethod = "Teleport"
		elseif v == "Touch" then
			newMethod = "Touch"
		end
		if newMethod then
			coinMethod = newMethod
			dbg("coin method:", newMethod)
			if collectOn then
				stopCollect()
				startCollect() -- restart so the right mode runs
			end
		end
	end,
})

CoinTab:CreateSlider({
	Name = "Pull speed (s between pulls)",
	Range = { 0.03, 0.5 },
	Increment = 0.01,
	Suffix = "s",
	CurrentValue = 0.1,
	Flag = "PullInterval",
	Callback = function(value)
		pullInterval = value
	end,
})

CoinTab:CreateSlider({
	Name = "Delay per coin (Teleport/Touch)",
	Range = { 0.05, 1 },
	Increment = 0.05,
	Suffix = "s",
	CurrentValue = 0.15,
	Flag = "CoinDelay",
	Callback = function(value)
		delaySec = value
	end,
})

CoinTab:CreateSlider({
	Name = "Max distance (0 = no limit)",
	Range = { 0, 2000 },
	Increment = 10,
	Suffix = "studs",
	CurrentValue = 0,
	Flag = "CoinMaxDist",
	Callback = function(value)
		maxDist = value
	end,
})

CoinTab:CreateToggle({
	Name = "Go back to start (Teleport/Touch)",
	CurrentValue = true,
	Flag = "CoinReturn",
	Callback = function(value)
		returnOn = value
	end,
})

CoinTab:CreateButton({
	Name = "Print coin count",
	Callback = function()
		local folder = getSpawned()
		if not folder then
			print("[ReelHelper] Spawned folder not found")
			return
		end
		local kids = folder:GetChildren()
		print("[ReelHelper] children in Spawned:", #kids)
		for i = 1, math.min(#kids, 5) do
			local c = kids[i]
			print("  ", c.ClassName, c.Name, c:IsA("BasePart") and tostring(c.Position) or "")
		end
	end,
})

-- start the main loop (reel detection, auto hold, coin pulling)
conn = RunService.Heartbeat:Connect(onHeartbeat)
