-- Made by ZXD --

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
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

-- auto pulls debris (Auto Click tab): holds the input, and every "delay" seconds does a quick click
local autoHoldOn = false
local autoHoldInput = "Touch" -- "Touch" or "Click"
local autoHoldDelay = 60 -- seconds between quick clicks
local autoHoldRunId = 0
local autoHoldHolding = false
local autoHoldBroken = false
local AUTOHOLD_TOUCH_ID = 2 -- different id than Auto Fish so they don't collide

-- auto kite (Auto Click tab): holds the kite button through the Kite remote
local kiteOn = false
local kiteWarned = false

-- auto golden circle (kite minigame): clicks when the Ring shrinks to the gold size
local goldenOn = false
local goldenInput = "Touch" -- "Touch" or "Click"
local goldenSize = 60 -- Ring AbsoluteSize where it turns gold
local goldenEarly = 3 -- click this many px before the gold size (covers input delay)
local ringRef = nil
local lastRingSearch = 0
local goldenArmed = true
local goldenClicking = false
local goldenWarned = false
local lastGoldenDbg = 0
local GOLDEN_TOUCH_ID = 3

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

-- remote spam loops (Auto Click tab + Misc tab)
-- a loop with its own "interval" uses that, otherwise it uses the shared clickInterval
-- a loop with "args" sends those arguments with FireServer (otherwise it sends none)
local clickInterval = 0.1
local clickLoops = {
	DropperClick = { on = false, id = 0, warned = false },
	BronzeDropperClick = { on = false, id = 0, warned = false },
	Windmill = { on = false, id = 0, warned = false, args = { "Push" } },
	MobAttackMlt = { on = false, id = 0, warned = false },
	TreeHit = { on = false, id = 0, warned = false },
	Ascend = { on = false, id = 0, warned = false, interval = 0.1 },
}

-- merchant (all 3 slots selected by default)
local merchantOn = false
local merchantRunId = 0
local merchantInterval = 0.25 -- wait after a full pass over the slots
local merchantSlotGap = 0.4 -- wait between each slot buy (so the server doesn't drop them)
local merchantSlots = { "Slot1", "Slot2", "Slot3" }
local merchantWarned = false

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
		if (cur:IsA("BillboardGui") or cur:IsA("SurfaceGui")) and not cur.Enabled then
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

-- ===== auto pulls debris (Auto Click tab) =====

-- sends one press (down = true) or release (down = false), returns true if it worked
local function autoHoldSend(down)
	if autoHoldBroken then
		return false
	end
	if not VIM then
		autoHoldBroken = true
		warn("[ReelHelper] VirtualInputManager not available in your executor")
		return false
	end

	local x, y = tapPos()
	local ok, err = pcall(function()
		if autoHoldInput == "Touch" then
			VIM:SendTouchEvent(AUTOHOLD_TOUCH_ID, down and 0 or 2, x, y)
		else
			VIM:SendMouseButtonEvent(x, y, 0, down, game, 0)
		end
	end)

	if not ok then
		autoHoldBroken = true
		warn("[ReelHelper] auto pulls debris input failed (" .. autoHoldInput .. "):", err)
		warn("[ReelHelper] try the other input in the dropdown")
		return false
	end
	return true
end

local function autoHoldSet(state)
	if autoHoldHolding == state then
		return
	end
	if autoHoldSend(state) then
		autoHoldHolding = state
		dbg("auto pulls debris:", state and "HOLD" or "RELEASE")
	end
end

local function startAutoHold()
	autoHoldRunId += 1
	local myId = autoHoldRunId
	autoHoldBroken = false

	task.spawn(function()
		local lastClick = os.clock()

		while alive and autoHoldOn and autoHoldRunId == myId do
			if reelBusy then
				-- let the reel bar have the input while you're reeling
				autoHoldSet(false)
				lastClick = os.clock()
			else
				if os.clock() - lastClick >= autoHoldDelay then
					-- quick click: let go, click, then hold again
					autoHoldSet(false)
					task.wait(0.05)
					autoHoldSend(true)
					task.wait(0.05)
					autoHoldSend(false)
					task.wait(0.05)
					lastClick = os.clock()
					dbg("auto pulls debris: quick click")
				end
				autoHoldSet(true)
			end

			task.wait(0.1)
		end
	end)

	dbg("auto pulls debris started")
end

local function stopAutoHold()
	autoHoldRunId += 1 -- ends any running loop
	autoHoldSet(false) -- let go right away
	dbg("auto pulls debris stopped")
end

-- ===== remote spam loops =====

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
	if st.on then
		return -- already running (the toggle callback and the default-on start can both call this)
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
					ev:FireServer(table.unpack(st.args or {}))
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

			task.wait(st.interval or clickInterval)
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

-- ===== auto kite (hold forever) =====

-- sends Kite("Hold", true/false), returns true if it was sent
local function sendKite(state)
	local ev = getRemote("Kite")
	if not ev then
		if not kiteWarned then
			kiteWarned = true
			warn("[ReelHelper] couldn't find ReplicatedStorage.Remotes.Kite")
		end
		return false
	end

	local ok, err = pcall(function()
		ev:FireServer("Hold", state)
	end)

	if ok then
		kiteWarned = false
		dbg("kite hold:", state)
	elseif not kiteWarned then
		kiteWarned = true
		warn("[ReelHelper] kite hold failed:", err)
	end
	return ok
end

local function startKite()
	kiteOn = true
	sendKite(true) -- sent once, the game keeps the hold until we release
end

local function stopKite()
	local wasOn = kiteOn
	kiteOn = false
	if wasOn then
		sendKite(false) -- always let go so you're never stuck holding
	end
end

-- ===== auto golden circle (kite minigame) =====

-- finds Worlds > (any world) > KiteClient > Kite_<number> > Ring
local function findKiteRing()
	if ringRef and ringRef.Parent then
		return ringRef
	end
	ringRef = nil

	-- don't search every frame
	local now = os.clock()
	if now - lastRingSearch < 0.25 then
		return nil
	end
	lastRingSearch = now

	local kiteClient = nil
	for _, root in ipairs({ workspace, ReplicatedStorage }) do
		local worlds = root:FindFirstChild("Worlds")
		if worlds then
			for _, world in ipairs(worlds:GetChildren()) do
				local kc = world:FindFirstChild("KiteClient")
				if kc then
					kiteClient = kc
					break
				end
			end
		end
		if kiteClient then
			break
		end
	end

	if not kiteClient then
		return nil
	end

	for _, k in ipairs(kiteClient:GetChildren()) do
		if k.Name:match("^Kite_%d+$") then
			local r = k:FindFirstChild("Ring", true)
			if r then
				ringRef = r
				dbg("found kite ring:", r:GetFullName(), r.ClassName)
				return r
			end
		end
	end

	return nil
end

local function goldenReadSize(ring)
	local ok, size = pcall(function()
		return ring.AbsoluteSize
	end)
	if ok and typeof(size) == "Vector2" then
		return size.X
	end
	return nil
end

-- taps the ring's center if it's normal on-screen UI, otherwise the screen center
local function goldenTapPos(ring)
	local ok, x, y = pcall(function()
		local gui = ring:FindFirstAncestorOfClass("ScreenGui")
		if gui and ring:IsA("GuiObject") then
			local pos = ring.AbsolutePosition
			local size = ring.AbsoluteSize
			local inset = gui.IgnoreGuiInset and Vector2.zero or GuiService:GetGuiInset()
			return pos.X + size.X / 2 + inset.X, pos.Y + size.Y / 2 + inset.Y
		end
		return nil, nil
	end)

	if ok and x and y then
		return x, y
	end
	return tapPos()
end

-- one quick tap (press, short wait, release) without blocking the main loop
local function goldenClick(x, y)
	if goldenClicking then
		return
	end
	if not VIM then
		if not goldenWarned then
			goldenWarned = true
			warn("[ReelHelper] VirtualInputManager not available in your executor")
		end
		return
	end

	goldenClicking = true
	task.spawn(function()
		local ok, err = pcall(function()
			if goldenInput == "Touch" then
				VIM:SendTouchEvent(GOLDEN_TOUCH_ID, 0, x, y)
			else
				VIM:SendMouseButtonEvent(x, y, 0, true, game, 0)
			end
		end)
		if not ok and not goldenWarned then
			goldenWarned = true
			warn("[ReelHelper] golden circle click failed (" .. goldenInput .. "):", err)
			warn("[ReelHelper] try the other input in the dropdown")
		end

		task.wait(0.04)

		pcall(function()
			if goldenInput == "Touch" then
				VIM:SendTouchEvent(GOLDEN_TOUCH_ID, 2, x, y)
			else
				VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
			end
		end)

		goldenClicking = false
	end)
end

local function goldenStep(now)
	local ring = findKiteRing()
	if not ring or not isShown(ring) then
		goldenArmed = true
		return
	end

	local size = goldenReadSize(ring)
	if not size then
		if not goldenWarned then
			goldenWarned = true
			warn("[ReelHelper] kite Ring has no AbsoluteSize, can't read it")
		end
		return
	end

	if size <= 1 then
		goldenArmed = true
		return
	end

	if debugOn and now - lastGoldenDbg > 0.1 then
		lastGoldenDbg = now
		local colorText = "?"
		pcall(function()
			if ring:IsA("ImageLabel") or ring:IsA("ImageButton") then
				colorText = tostring(ring.ImageColor3)
			else
				colorText = tostring(ring.BackgroundColor3)
			end
		end)
		print(string.format("[ReelHelper] ring size %.1f | color %s | armed %s", size, colorText, tostring(goldenArmed)))
	end

	local trigger = goldenSize + goldenEarly

	-- a big ring means a new circle started, so get ready to click again
	if size > trigger + 20 then
		goldenArmed = true
	end

	-- click once when the ring shrinks into the gold size (never before)
	if goldenArmed and size <= trigger and size >= goldenSize - 25 then
		goldenArmed = false
		local x, y = goldenTapPos(ring)
		dbg(string.format("golden circle: clicking at ring size %.1f", size))
		goldenClick(x, y)
	end
end

local function startGolden()
	goldenOn = true
	goldenArmed = true
	dbg("auto golden circle started")
end

local function stopGolden()
	goldenOn = false
	dbg("auto golden circle stopped")
end

-- ===== merchant =====

local function startMerchantLoop()
	if merchantOn then
		return -- already running
	end

	merchantOn = true
	merchantRunId += 1
	local myId = merchantRunId

	task.spawn(function()
		local ev = nil

		while alive and merchantOn and merchantRunId == myId do
			if not ev or not ev.Parent then
				ev = getRemote("Merchant")
			end

			if ev then
				-- copy the list so changing the dropdown mid-loop can't break the pass
				local slots = table.clone(merchantSlots)
				for _, slot in ipairs(slots) do
					if not (alive and merchantOn and merchantRunId == myId) then
						break
					end

					local ok, err = pcall(function()
						ev:FireServer("Buy", slot)
					end)
					dbg("merchant buy", slot, ok and "sent" or "failed")

					if ok then
						merchantWarned = false
					elseif not merchantWarned then
						merchantWarned = true
						warn("[ReelHelper] merchant buy failed:", err)
					end

					-- wait between slots so the server doesn't drop Slot 2 / Slot 3
					task.wait(merchantSlotGap)
				end
			elseif not merchantWarned then
				merchantWarned = true
				warn("[ReelHelper] couldn't find ReplicatedStorage.Remotes.Merchant")
			end

			task.wait(merchantInterval)
		end
	end)

	dbg("auto buy merchant started")
end

local function stopMerchantLoop()
	merchantOn = false
	merchantRunId += 1 -- ends any running merchant loop
	dbg("auto buy merchant stopped")
end

-- fires Slot1, Slot2, Slot3 once each (1 second apart) and prints what happened
local function testBuySlots()
	task.spawn(function()
		local ev = getRemote("Merchant")
		if not ev then
			warn("[ReelHelper] couldn't find ReplicatedStorage.Remotes.Merchant")
			return
		end

		for _, slot in ipairs({ "Slot1", "Slot2", "Slot3" }) do
			if not alive then
				return
			end
			local ok, err = pcall(function()
				ev:FireServer("Buy", slot)
			end)
			print("[ReelHelper] test buy", slot, ok and "sent" or ("failed: " .. tostring(err)))
			task.wait(1)
		end
	end)
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

	if goldenOn then
		goldenStep(now)
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
	autoHoldOn = false
	goldenOn = false
	collectOn = false
	challengeOn = false
	stopAutoHold()
	stopKite() -- sends the release if the kite was being held
	stopCollect()
	stopChallengeLoop()
	stopMerchantLoop()
	for name in pairs(clickLoops) do
		stopClickLoop(name)
	end
	if conn then
		conn:Disconnect()
		conn = nil
	end
	restoreRegionSize()
	setHold(false)
end

-- ===== UI =====

local Window = Rayfield:CreateWindow({
	Name = "Dropper Incremental",
	LoadingTitle = "Dropper Incremental",
	LoadingSubtitle = "Readying up your Clickers...",
	ConfigurationSaving = { Enabled = false },
	KeySystem = false,
})

-- Tab 1: Auto Click
local ClickTab = Window:CreateTab("Auto Click", 4483362458)

ClickTab:CreateSection("Holders")

ClickTab:CreateToggle({
	Name = "Auto Pulls Debris",
	CurrentValue = false,
	Flag = "AutoPullsDebris",
	Callback = function(value)
		autoHoldOn = value
		if value then
			startAutoHold()
		else
			stopAutoHold()
		end
	end,
})

ClickTab:CreateDropdown({
	Name = "Input",
	Options = { "Touch", "Click" },
	CurrentOption = { "Touch" }, -- default is Touch (mobile)
	MultipleOptions = false,
	Flag = "AutoHoldInput",
	Callback = function(option)
		local v = type(option) == "table" and option[1] or option
		if v == "Touch" or v == "Click" then
			autoHoldSet(false) -- let go with the old input first
			autoHoldInput = v
			autoHoldBroken = false
			dbg("auto pulls debris input:", v)
		end
	end,
})

ClickTab:CreateSlider({
	Name = "Delay (sec)",
	Range = { 1, 300 },
	Increment = 1,
	Suffix = "sec",
	CurrentValue = 60,
	Flag = "AutoHoldDelay",
	Callback = function(value)
		autoHoldDelay = value
	end,
})

ClickTab:CreateToggle({
	Name = "Auto Kite",
	CurrentValue = false,
	Flag = "AutoKite",
	Callback = function(value)
		if value then
			startKite()
		else
			stopKite()
		end
	end,
})

ClickTab:CreateToggle({
	Name = "Auto Golden Circle",
	CurrentValue = true, -- ON by default
	Flag = "AutoGoldenCircle",
	Callback = function(value)
		if value then
			startGolden()
		else
			stopGolden()
		end
	end,
})

ClickTab:CreateDropdown({
	Name = "Circle input",
	Options = { "Touch", "Click" },
	CurrentOption = { "Touch" }, -- default is Touch (mobile)
	MultipleOptions = false,
	Flag = "GoldenInput",
	Callback = function(option)
		local v = type(option) == "table" and option[1] or option
		if v == "Touch" or v == "Click" then
			goldenInput = v
			goldenWarned = false
			dbg("golden circle input:", v)
		end
	end,
})

ClickTab:CreateSlider({
	Name = "Golden size (px)",
	Range = { 20, 200 },
	Increment = 1,
	Suffix = "px",
	CurrentValue = 60,
	Flag = "GoldenSize",
	Callback = function(value)
		goldenSize = value
	end,
})

ClickTab:CreateSlider({
	Name = "Click early by (px)",
	Range = { 0, 20 },
	Increment = 1,
	Suffix = "px",
	CurrentValue = 3,
	Flag = "GoldenEarly",
	Callback = function(value)
		goldenEarly = value
	end,
})

ClickTab:CreateSection("Clickers")

ClickTab:CreateToggle({
	Name = "Auto Dropper",
	CurrentValue = true, -- ON by default
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
	CurrentValue = true, -- ON by default
	Flag = "AutoBronzeDropper",
	Callback = function(value)
		if value then
			startClickLoop("BronzeDropperClick")
		else
			stopClickLoop("BronzeDropperClick")
		end
	end,
})

ClickTab:CreateToggle({
	Name = "Auto Windmill",
	CurrentValue = false,
	Flag = "AutoWindmill",
	Callback = function(value)
		if value then
			startClickLoop("Windmill")
		else
			stopClickLoop("Windmill")
		end
	end,
})

ClickTab:CreateToggle({
	Name = "Auto Fighting",
	CurrentValue = false,
	Flag = "AutoFighting",
	Callback = function(value)
		if value then
			startClickLoop("MobAttackMlt")
		else
			stopClickLoop("MobAttackMlt")
		end
	end,
})

ClickTab:CreateToggle({
	Name = "Auto Logging",
	CurrentValue = false,
	Flag = "AutoLogging",
	Callback = function(value)
		if value then
			startClickLoop("TreeHit")
		else
			stopClickLoop("TreeHit")
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

-- Tab 3: Fishing
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

-- Tab 4: Misc (above Settings)
local MiscTab = Window:CreateTab("Misc", 4483362458)

MiscTab:CreateSection("Speedrun")

MiscTab:CreateToggle({
	Name = "Auto Ascend",
	CurrentValue = false,
	Flag = "AutoAscend",
	Callback = function(value)
		if value then
			startClickLoop("Ascend")
		else
			stopClickLoop("Ascend")
		end
	end,
})

MiscTab:CreateSlider({
	Name = "Ascend delay (s)",
	Range = { 0.03, 1 },
	Increment = 0.01,
	Suffix = "s",
	CurrentValue = 0.1,
	Flag = "AscendDelay",
	Callback = function(value)
		clickLoops.Ascend.interval = value
	end,
})

MiscTab:CreateSection("Merchant")

MiscTab:CreateToggle({
	Name = "Auto Buy Merchant",
	CurrentValue = true, -- ON by default
	Flag = "AutoBuyMerchant",
	Callback = function(value)
		if value then
			startMerchantLoop()
		else
			stopMerchantLoop()
		end
	end,
})

MiscTab:CreateDropdown({
	Name = "Merchant slots",
	Options = { "Slot 1", "Slot 2", "Slot 3" },
	CurrentOption = { "Slot 1", "Slot 2", "Slot 3" }, -- all selected by default
	MultipleOptions = true,
	Flag = "MerchantSlots",
	Callback = function(options)
		local list = {}
		if type(options) == "table" then
			for _, v in ipairs(options) do
				if type(v) == "string" then
					local n = v:match("Slot%s*(%d+)")
					if n then
						list[#list + 1] = "Slot" .. n
					end
				end
			end
		elseif type(options) == "string" then
			local n = options:match("Slot%s*(%d+)")
			if n then
				list[1] = "Slot" .. n
			end
		end
		merchantSlots = list
		dbg("merchant slots:", table.concat(list, ", "))
	end,
})

MiscTab:CreateSlider({
	Name = "Merchant slot gap (s)",
	Range = { 0.05, 3 },
	Increment = 0.05,
	Suffix = "s",
	CurrentValue = 0.4,
	Flag = "MerchantSlotGap",
	Callback = function(value)
		merchantSlotGap = value
	end,
})

MiscTab:CreateSlider({
	Name = "Merchant delay (s)",
	Range = { 0.05, 5 },
	Increment = 0.05,
	Suffix = "s",
	CurrentValue = 0.25,
	Flag = "MerchantDelay",
	Callback = function(value)
		merchantInterval = value
	end,
})

MiscTab:CreateButton({
	Name = "Test buy slots (1, 2, 3)",
	Callback = testBuySlots,
})

-- Tab 5: Settings (last)
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

-- Things that are ON by default get started right now
-- (each start function does nothing if the toggle callback already started it)
startClickLoop("DropperClick")
startClickLoop("BronzeDropperClick")
startGolden()
startMerchantLoop()

-- start the main loop (reel detection, auto fish, golden circle, region size, coin pulling)
conn = RunService.Heartbeat:Connect(onHeartbeat)
