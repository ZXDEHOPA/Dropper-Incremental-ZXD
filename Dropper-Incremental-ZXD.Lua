-- Reel Helper v3 (Rayfield)
-- GUI path: PlayerGui > Front > MainFrame > ReelBar > Track > Lane > (Zone, Fish)
-- Remote:   ReplicatedStorage > Remotes > Fishing  (args seen: "Cast", "Catch", "Zone", bool)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local BIND_NAME = "ZoneFollowFish"
pcall(function()
	RunService:UnbindFromRenderStep(BIND_NAME) -- clean up if script was run before
end)

-- state
local following = false
local bound = false
local debugOn = false
local spyOn = false
local forceOn = false
local hookInstalled = false
local forceConn = nil
local lastForce = 0
local lane, zone, fish = nil, nil, nil
local fishingRemote = nil
local wasFound = false
local errWarned = false

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

-- true only if Lane and everything above it is actually visible
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

-- what the GUI says: is the fish center inside the zone?
local function guiInZone()
	if not resolve() then
		return nil
	end
	local fishCenter = fish.AbsolutePosition.X + fish.AbsoluteSize.X / 2
	local zl = zone.AbsolutePosition.X
	return fishCenter >= zl and fishCenter <= zl + zone.AbsoluteSize.X
end

-- ===== zone follows fish (visual) =====

local function step()
	if not resolve() then
		return
	end

	local laneW = lane.AbsoluteSize.X
	if laneW <= 0 then
		return
	end

	local zoneW = zone.AbsoluteSize.X
	local fishCenter = fish.AbsolutePosition.X + fish.AbsoluteSize.X / 2

	local left = fishCenter - zoneW / 2
	local minLeft = lane.AbsolutePosition.X
	local maxLeft = math.max(minLeft, minLeft + laneW - zoneW)
	left = math.clamp(left, minLeft, maxLeft)

	local scaleX = (left + zone.AnchorPoint.X * zoneW - lane.AbsolutePosition.X) / laneW

	zone.Position = UDim2.new(scaleX, 0, zone.Position.Y.Scale, zone.Position.Y.Offset)
end

local function onRender()
	local ok, err = pcall(step)
	if not ok and not errWarned then
		errWarned = true
		warn("[ReelHelper] error:", err)
	end
end

local function startFollow()
	if bound then
		return
	end
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Last.Value + 1, onRender)
	bound = true
	dbg("follow started")
end

local function stopFollow()
	if not bound then
		return
	end
	pcall(function()
		RunService:UnbindFromRenderStep(BIND_NAME)
	end)
	bound = false
	dbg("follow stopped")
end

-- ===== force "in zone" to the server =====

local function forceStep()
	local now = os.clock()
	if now - lastForce < 0.1 then
		return
	end
	lastForce = now

	local remote = getFishingRemote()
	if not remote or not resolve() or not isShown(lane) then
		return
	end

	local ok, err = pcall(function()
		remote:FireServer("Zone", true)
	end)
	if not ok then
		warn("[ReelHelper] FireServer failed:", err)
	end
end

local function startForce()
	if forceConn then
		return
	end
	if not getFishingRemote() then
		warn("[ReelHelper] couldn't find ReplicatedStorage.Remotes.Fishing")
	end
	forceConn = RunService.Heartbeat:Connect(forceStep)
	dbg("force in-zone started")
end

local function stopForce()
	if forceConn then
		forceConn:Disconnect()
		forceConn = nil
		dbg("force in-zone stopped")
	end
end

-- ===== fishing remote spy =====

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

local function scanScripts()
	print("[ReelHelper] ---- scripts scan ----")
	local roots = {
		LocalPlayer:FindFirstChild("PlayerGui"),
		LocalPlayer:FindFirstChild("PlayerScripts"),
		LocalPlayer:FindFirstChild("Backpack"),
		LocalPlayer.Character,
	}
	local count = 0
	for _, root in ipairs(roots) do
		if root then
			for _, d in ipairs(root:GetDescendants()) do
				if d:IsA("LocalScript") or d:IsA("ModuleScript") then
					count += 1
					print(d.ClassName, d:GetFullName())
				end
			end
		end
	end
	print("[ReelHelper] total:", count)
end

-- ===== UI =====

local Window = Rayfield:CreateWindow({
	Name = "Reel Helper",
	LoadingTitle = "Reel Helper",
	LoadingSubtitle = "zone follows fish",
	ConfigurationSaving = { Enabled = false },
	KeySystem = false,
})

local Tab = Window:CreateTab("Reel", 4483362458)

Tab:CreateToggle({
	Name = "Zone follows fish (visual only)",
	CurrentValue = false,
	Flag = "ZoneFollowFish",
	Callback = function(value)
		following = value
		if value then
			startFollow()
		else
			stopFollow()
		end
	end,
})

Tab:CreateToggle({
	Name = "Force in-zone (sends Zone=true)",
	CurrentValue = false,
	Flag = "ForceInZone",
	Callback = function(value)
		forceOn = value
		if value then
			startForce()
		else
			stopForce()
		end
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
	Name = "Scan scripts",
	Callback = scanScripts,
})

FinderTab:CreateButton({
	Name = "Print status",
	Callback = function()
		local found = resolve()
		print("[ReelHelper] follow:", following, "| force:", forceOn, "| gui found:", found, "| remote:", getFishingRemote() ~= nil)
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
		following = false
		forceOn = false
		spyOn = false -- hook can't be removed, but it just passes calls through when off
		stopFollow()
		stopForce()
		Rayfield:Destroy()
	end,
})
