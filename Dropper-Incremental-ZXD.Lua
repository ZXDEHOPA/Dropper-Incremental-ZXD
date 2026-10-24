-- Reel Helper v6 (Rayfield): Auto hold + Auto cast + Auto hook
-- Reel GUI: PlayerGui > Front > MainFrame > ReelBar > Track > Lane > (Zone, Fish)
-- Flow: cast (tap) -> wait for "!" -> hook (tap) -> reel bar -> auto hold
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

-- settings / toggles
local holdOn = false
local castOn = false
local hookOn = false
local debugOn = false
local discoveryOn = false
local inputMethod = "Mouse"
local deadband = 12 -- px
local castDelay = 2 -- seconds to wait after a catch before casting again
local castHoldMs = 100 -- how long the cast tap is held
local hookDelayMs = 150 -- reaction delay before hooking
local biteTimeout = 25 -- seconds to wait for a bite before recasting
local HOOK_TIMEOUT = 6 -- seconds to wait for the reel bar after hooking

-- state
local alive = true
local conn = nil
local listeners = {}
local holding = false
local pulsing = false
local inputBroken = false
local lane, zone, fish = nil, nil, nil
local wasFound = false
local errWarned = false
local lastFishX, lastMove, lastDbg = nil, 0, 0
local state = "IDLE" -- IDLE, WAIT_BITE, HOOKED, REELING
local stateTime = os.clock()
local lastReelEnd = os.clock()
local lastHook = 0
local biteFlag = false
local discoveryCount = 0
local TOUCH_ID = 1

local function dbg(...)
	if debugOn then
		print("[ReelHelper]", ...)
	end
end

local function setState(s)
	if state ~= s then
		dbg("state:", state, "->", s)
	end
	state = s
	stateTime = os.clock()
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

-- ===== input (hold / release / tap) =====

local function tapPos()
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(800, 400)
	return vp.X * 0.5, vp.Y * 0.4
end

local function setHold(s)
	if holding == s then
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
			VIM:SendTouchEvent(TOUCH_ID, s and 0 or 2, x, y)
		else
			VIM:SendMouseButtonEvent(x, y, 0, s, game, 0)
		end
	end)

	if ok then
		holding = s
		dbg(s and "HOLD" or "RELEASE")
	else
		inputBroken = true
		warn("[ReelHelper] input failed (" .. inputMethod .. "):", err)
		warn("[ReelHelper] try the other input method in the dropdown")
	end
end

local function releaseHold()
	if not pulsing then
		setHold(false)
	end
end

-- one tap (press, wait, release) without blocking the main loop
local function pulse(ms)
	if pulsing or not alive then
		return
	end
	pulsing = true
	task.spawn(function()
		setHold(true)
		task.wait(ms / 1000)
		setHold(false)
		pulsing = false
	end)
end

-- ===== reel detection + auto hold =====

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

local function holdLogic(now)
	if pulsing then
		return
	end

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

-- ===== bite ("!") detection =====

local function looksLikeBite(inst)
	local ok, res = pcall(function()
		local n = string.lower(inst.Name)
		if n == "!" or n:find("exclam", 1, true) or n:find("bite", 1, true) or n:find("alert", 1, true)
			or n:find("nibble", 1, true) or n:find("strike", 1, true) then
			return true
		end
		if inst:IsA("TextLabel") or inst:IsA("TextButton") then
			local t = string.gsub(inst.Text, "%s", "")
			if t == "!" then
				return true
			end
		end
		return false
	end)
	return ok and res == true
end

local function onAdded(inst)
	if not alive then
		return
	end

	if discoveryOn and state ~= "REELING" and discoveryCount < 80 then
		discoveryCount += 1
		local txt = ""
		pcall(function()
			if inst:IsA("TextLabel") or inst:IsA("TextButton") then
				txt = inst.Text
			end
		end)
		print("[Discovery]", state, inst.ClassName, inst:GetFullName(), txt)
	end

	if looksLikeBite(inst) then
		biteFlag = true
		dbg("bite signal:", inst:GetFullName())
	end
end

local function scanBite()
	print("[ReelHelper] ---- bite scan (do this while the ! is on screen) ----")
	local found = 0
	local function check(root)
		if not root then
			return
		end
		for _, d in ipairs(root:GetDescendants()) do
			if found >= 40 then
				return
			end
			local hit = false
			if looksLikeBite(d) then
				hit = true
			elseif d:IsA("BillboardGui") and d.Enabled then
				hit = true
			end
			if hit then
				found += 1
				local extra = ""
				if d:IsA("GuiObject") then
					extra = "Visible=" .. tostring(d.Visible)
				elseif d:IsA("BillboardGui") then
					extra = "Enabled=" .. tostring(d.Enabled)
				end
				print(d.ClassName, d:GetFullName(), extra)
			end
		end
	end
	check(LocalPlayer:FindFirstChild("PlayerGui"))
	check(workspace)
	print("[ReelHelper] scan done, hits:", found)
end

local function connectListeners()
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	if pg then
		listeners[#listeners + 1] = pg.DescendantAdded:Connect(onAdded)
	end
	listeners[#listeners + 1] = workspace.DescendantAdded:Connect(onAdded)
end

-- ===== main loop (state machine) =====

local function step()
	local now = os.clock()
	local active = reelActive(now)

	-- auto hold
	if holdOn and active then
		holdLogic(now)
	else
		releaseHold()
	end

	-- reeling: nothing else to do
	if active then
		if state ~= "REELING" then
			setState("REELING")
			biteFlag = false
			discoveryCount = 0
		end
		return
	end

	-- reel just ended
	if state == "REELING" then
		lastReelEnd = now
		setState("IDLE")
		return
	end

	-- bite signal -> hook
	if biteFlag then
		biteFlag = false
		local accept = hookOn
			and (state == "WAIT_BITE" or (state == "IDLE" and not castOn))
			and (now - lastHook > 2)
		if accept then
			lastHook = now
			dbg("hooking in", hookDelayMs, "ms")
			task.delay(hookDelayMs / 1000, function()
				if alive then
					pulse(80)
				end
			end)
			setState("HOOKED")
		end
	end

	if state == "IDLE" then
		if castOn and not pulsing and now - lastReelEnd >= castDelay then
			dbg("casting")
			pulse(castHoldMs)
			setState("WAIT_BITE")
			biteFlag = false
			discoveryCount = 0
		end
	elseif state == "WAIT_BITE" then
		if now - stateTime > biteTimeout then
			dbg("no bite in time, resetting")
			lastReelEnd = now
			setState("IDLE")
		end
	elseif state == "HOOKED" then
		if now - stateTime > HOOK_TIMEOUT then
			dbg("reel bar never showed, resetting")
			lastReelEnd = now
			setState("IDLE")
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

local function startLoop()
	if conn then
		return
	end
	conn = RunService.Heartbeat:Connect(onHeartbeat)
end

local function cleanup()
	alive = false
	holdOn, castOn, hookOn = false, false, false
	if conn then
		conn:Disconnect()
		conn = nil
	end
	for _, c in ipairs(listeners) do
		c:Disconnect()
	end
	listeners = {}
	setHold(false)
end

-- ===== UI =====

local Window = Rayfield:CreateWindow({
	Name = "Reel Helper",
	LoadingTitle = "Reel Helper",
	LoadingSubtitle = "auto cast / hook / hold",
	ConfigurationSaving = { Enabled = false },
	KeySystem = false,
})

local Tab = Window:CreateTab("Fishing", 4483362458)

Tab:CreateToggle({
	Name = "Auto hold",
	CurrentValue = false,
	Flag = "AutoHold",
	Callback = function(value)
		holdOn = value
		if not value then
			releaseHold()
		end
	end,
})

Tab:CreateToggle({
	Name = "Auto cast",
	CurrentValue = false,
	Flag = "AutoCast",
	Callback = function(value)
		castOn = value
		if value then
			lastReelEnd = os.clock()
			setState("IDLE")
		end
	end,
})

Tab:CreateToggle({
	Name = "Auto hook (tap when ! shows)",
	CurrentValue = false,
	Flag = "AutoHook",
	Callback = function(value)
		hookOn = value
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

local TimingTab = Window:CreateTab("Timing", 4483362458)

TimingTab:CreateSlider({
	Name = "Cast delay after catch (s)",
	Range = { 0.5, 10 },
	Increment = 0.5,
	Suffix = "s",
	CurrentValue = 2,
	Flag = "CastDelay",
	Callback = function(value)
		castDelay = value
	end,
})

TimingTab:CreateSlider({
	Name = "Cast tap length (ms)",
	Range = { 20, 1500 },
	Increment = 10,
	Suffix = "ms",
	CurrentValue = 100,
	Flag = "CastHoldMs",
	Callback = function(value)
		castHoldMs = value
	end,
})

TimingTab:CreateSlider({
	Name = "Hook reaction delay (ms)",
	Range = { 0, 1000 },
	Increment = 10,
	Suffix = "ms",
	CurrentValue = 150,
	Flag = "HookDelayMs",
	Callback = function(value)
		hookDelayMs = value
	end,
})

TimingTab:CreateSlider({
	Name = "Bite timeout (s)",
	Range = { 5, 60 },
	Increment = 1,
	Suffix = "s",
	CurrentValue = 25,
	Flag = "BiteTimeout",
	Callback = function(value)
		biteTimeout = value
	end,
})

local FinderTab = Window:CreateTab("Finder", 4483362458)

FinderTab:CreateToggle({
	Name = "Debug messages",
	CurrentValue = false,
	Flag = "ReelDebug",
	Callback = function(value)
		debugOn = value
	end,
})

FinderTab:CreateToggle({
	Name = "Discovery log (prints new objects while waiting)",
	CurrentValue = false,
	Flag = "ReelDiscovery",
	Callback = function(value)
		discoveryOn = value
		discoveryCount = 0
	end,
})

FinderTab:CreateButton({
	Name = "Scan for ! icon (press while it's showing)",
	Callback = scanBite,
})

FinderTab:CreateButton({
	Name = "Unload script",
	Callback = function()
		cleanup()
		Rayfield:Destroy()
	end,
})

connectListeners()
startLoop()
