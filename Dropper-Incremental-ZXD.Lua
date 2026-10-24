-- Reel Helper (Rayfield): Auto Click + Coins + Auto Fish
-- Tabs: Auto Click, Coins, Fishing, Settings
-- Reel GUI: PlayerGui > Front > MainFrame > ReelBar > Track > Lane > (Zone, Fish)
-- Coins:    workspace > MapEssentials > Spawned > Number (MeshPart, positioned with CFrame)
-- Region:   workspace > MapEssentials > Collection > SpawnableRegion (set to 100, 20, 100 while Auto collect is on)
-- Challenge: ReplicatedStorage > Remotes > Challenge:FireServer("CoinCollector", "Start") (spammed every 100ms)
-- Droppers: ReplicatedStorage > Remotes > DropperClick / BronzeDropperClick :FireServer()
-- Game behavior while reeling: hold = zone moves RIGHT, release = zone moves LEFT

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

-- size the spawn region gets while Auto collect coins is ON (change it here if you want)
local REGION_SIZE = Vector3.new(100, 20, 100)

-- how often the challenge Start call is sent (seconds)
local CHALLENGE_INTERVAL = 0.1

-- ===== shared state =====
local alive = true
local debugOn = false
local conn = nil
local errWarned = false

-- auto fish
local autoOn = false
local inputMethod = "Touch"
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

-- challenge spam
local challengeOn = false
local challengeRunId = 0
local challengeWarned = false

-- spawn region
local regionRef = nil
local regionOrigSize = nil
local regionWarned = false

-- auto click (droppers)
local clickInterval = 0.1
local clickLoops = {
	DropperClick = { on = false, id = 0, warned = false },
	BronzeDropperClick = { on = false, id = 0, warned = false },
}

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

-- ===== auto fish logic =====

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

-- ===== auto click (droppers) =====

local function getRemote(name)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local ev = remotes and remotes:FindFirstChild(name)
	if ev and ev:IsA("RemoteEvent") then
		return ev
	end
	return nil
end

local function startClickLoop(name)
	local st = clickLoops[name]
	if not st then
		return
	end

	st.on = true
	st.id += 1
	local myId = st.id

	task.spawn(function()
		local ev = nil

		while alive and st.on and st.id == myId do
			if not ev or not ev.Parent then
				ev = getRemote(name)
			end

			if ev then
				local ok, err = pcall(function()
					ev:FireServer()
				end)
				if ok then
					st.warned = false
				elseif not st.warned then
					st.warned = true
					warn("[ReelHelper] " .. name .. " failed:", err)
				end
			elseif not st.warned then
				st.warned = true
				warn("[ReelHelper] couldn't find ReplicatedStorage.Remotes." .. name)
			end

			task.wait(clickInterval)
		end
	end)

	dbg(name, "loop started")
end

local function stopClickLoop(name)
	local st = clickLoops[name]
	if not st then
		return
	end
	st.on = false
	st.id += 1 -- ends any running loop for this remote
	dbg(name, "loop stopped")
end

-- ===== challenge spam =====

local function getChallengeRemote()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local ev = remotes and remotes:FindFirstChild("Challenge")
	if ev and ev:IsA("RemoteEvent") then
		return ev
	end
	return nil
end

local function startChallengeLoop()
	challengeRunId += 1
	local myId = challengeRunId

	task.spawn(function()
		local ev = nil

		while alive and challengeOn and challengeRunId == myId do
			if not ev or not ev.Parent then
				ev = getChallengeRemote()
			end

			if ev then
				local ok, err = pcall(function()
					ev:FireServer("CoinCollector", "Start")
				end)
				if ok then
					challengeWarned = false
				elseif not challengeWarned then
					challengeWarned = true
					warn("[ReelHelper] challenge start failed:", err)
				end
			elseif not challengeWarned then
				challengeWarned = true
				warn("[ReelHelper] couldn't find ReplicatedStorage.Remotes.Challenge")
			end

			task.wait(CHALLENGE_INTERVAL)
		end
	end)

	dbg("auto challenge started")
end

local function stopChallengeLoop()
	challengeRunId += 1 -- ends any running challenge loop
	dbg("auto challenge stopped")
end

-- ===== spawn region size =====

local function getRegion()
	if regionRef and regionRef.Parent then
		return regionRef
	end
	local r = getPath(workspace, "MapEssentials", "Collection", "SpawnableRegion")
	if r and r:IsA("BasePart") then
		return r
	end
	return nil
end

-- sets the region to REGION_SIZE (and keeps it there if the game changes it back)
local function applyRegionSize()
	local r = getRegion()
	if not r then
		if not regionWarned then
			regionWarned = true
			warn("[ReelHelper] couldn't find workspace.MapEssentials.Collection.SpawnableRegion")
		end
		return
	end
	regionWarned = false

	if regionRef ~= r then
		regionRef = r
		regionOrigSize = r.Size
		print("[ReelHelper] SpawnableRegion size was", tostring(regionOrigSize), "-> setting to", tostring(REGION_SIZE))
	end

	if r.Size ~= REGION_SIZE then
		r.Size = REGION_SIZE
	end
end

local function restoreRegionSize()
	if regionRef and regionRef.Parent and regionOrigSize then
		pcall(function()
			regionRef.Size = regionOrigSize
		end)
		dbg("spawn region size restored to", tostring(regionOrigSize))
	end
	regionRef = nil
	regionOrigSize = nil
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

	if collectOn then
		applyRegionSize() -- keeps the region at REGION_SIZE while Auto collect is on
		if coinMethod == "Pull" then
			pullCoins(now)
		end
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
	challengeOn = false
	stopCollect()
	stopChallengeLoop()
	stopClickLoop("DropperClick")
	stopClickLoop("BronzeDropperClick")
	if conn then
		conn:Disconnect()
		conn = nil
	end
	restoreRegionSize()
	setHold(false)
end

-- ===== UI =====

local Window = Rayfield:CreateWindow({
	Name = "Reel Helper",
	LoadingTitle = "Reel Helper",
	LoadingSubtitle = "auto click + coins + auto fish",
	ConfigurationSaving = { Enabled = false },
	KeySystem = false,
})

-- Tab 1: Auto Click
local ClickTab = Window:CreateTab("Auto Click", 4483362458)

ClickTab:CreateToggle({
	Name = "Auto Dropper",
	CurrentValue = false,
	Flag = "AutoDropper",
	Callback = function(value)
		if value then
			startClickLoop("DropperClick")
		else
			stopClickLoop("DropperClick")
		end
	end,
})

ClickTab:CreateToggle({
	Name = "Auto Bronze Dropper",
	CurrentValue = false,
	Flag = "AutoBronzeDropper",
	Callback = function(value)
		if value then
			startClickLoop("BronzeDropperClick")
		else
			stopClickLoop("BronzeDropperClick")
		end
	end,
})

ClickTab:CreateSlider({
	Name = "Click delay (s)",
	Range = { 0.03, 1 },
	Increment = 0.01,
	Suffix = "s",
	CurrentValue = 0.1,
	Flag = "ClickDelay",
	Callback = function(value)
		clickInterval = value
	end,
})

-- Tab 2: Coins
local CoinTab = Window:CreateTab("Coins", 4483362458)

CoinTab:CreateToggle({
	Name = "Auto collect coins",
	CurrentValue = false,
	Flag = "AutoCollectCoins",
	Callback = function(value)
		collectOn = value
		if value then
			pcall(applyRegionSize) -- resize the spawn region right away
			startCollect()
		else
			stopCollect()
			restoreRegionSize()
		end
	end,
})

CoinTab:CreateToggle({
	Name = "Auto Challenge Coin",
	CurrentValue = false,
	Flag = "AutoChallengeCoin",
	Callback = function(value)
		challengeOn = value
		if value then
			startChallengeLoop()
		else
			stopChallengeLoop()
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

CoinTab:CreateButton({
	Name = "Print Collection info",
	Callback = function()
		local me = workspace:FindFirstChild("MapEssentials")
		if not me then
			print("[ReelHelper] MapEssentials not found")
			return
		end
		print("[ReelHelper] ---- MapEssentials ----")
		for _, c in ipairs(me:GetChildren()) do
			print("  ", c.ClassName, c.Name, "children:", #c:GetChildren())
		end
		local col = me:FindFirstChild("Collection")
		if col then
			print("[ReelHelper] ---- Collection ----")
			for i, c in ipairs(col:GetChildren()) do
				if i > 20 then
					break
				end
				local extra = ""
				if c:IsA("BasePart") then
					extra = "size " .. tostring(c.Size) .. " pos " .. tostring(c.Position)
				end
				print("  ", c.ClassName, c.Name, extra)
			end
		else
			print("[ReelHelper] Collection not found")
		end
	end,
})

-- Tab 3: Fishing (second to last)
local FishTab = Window:CreateTab("Fishing", 4483362458)

FishTab:CreateToggle({
	Name = "Auto Fish",
	CurrentValue = false,
	Flag = "AutoFish",
	Callback = function(value)
		autoOn = value
		if not value then
			setHold(false)
		end
		dbg("auto fish:", value)
	end,
})

FishTab:CreateDropdown({
	Name = "Input method",
	Options = { "Touch", "Mouse" },
	CurrentOption = { "Touch" },
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

-- Tab 4: Settings (last)
local SettingsTab = Window:CreateTab("Settings", 4483362458)

SettingsTab:CreateToggle({
	Name = "Debug messages (everything)",
	CurrentValue = false,
	Flag = "ReelDebug",
	Callback = function(value)
		debugOn = value
	end,
})

SettingsTab:CreateButton({
	Name = "Unload script",
	Callback = function()
		cleanup()
		Rayfield:Destroy()
	end,
})

-- start the main loop (reel detection, auto fish, region size, coin pulling)
conn = RunService.Heartbeat:Connect(onHeartbeat)
