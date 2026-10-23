-- Zone follows Fish (Rayfield)
-- Path: PlayerGui > Front > MainFrame > ReelBar > Track > Lane > (Zone, Fish)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
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
local lane, zone, fish = nil, nil, nil
local wasFound = false
local errWarned = false

local function dbg(...)
	if debugOn then
		print("[ZoneFollow]", ...)
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

-- finds Lane/Zone/Fish, only re-searches if the cached ones are gone
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

	-- where the zone's left edge should be (in screen pixels)
	local left = fishCenter - zoneW / 2
	local minLeft = lane.AbsolutePosition.X
	local maxLeft = math.max(minLeft, minLeft + laneW - zoneW)
	left = math.clamp(left, minLeft, maxLeft)

	-- convert to Lane-space scale (accounts for the zone's AnchorPoint)
	local scaleX = (left + zone.AnchorPoint.X * zoneW - lane.AbsolutePosition.X) / laneW

	zone.Position = UDim2.new(scaleX, 0, zone.Position.Y.Scale, zone.Position.Y.Offset)
end

local function onRender()
	local ok, err = pcall(step)
	if not ok and not errWarned then
		errWarned = true
		warn("[ZoneFollow] error:", err)
	end
end

local function start()
	if bound then
		return
	end
	-- runs after the game's own updates so it wins
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Last.Value + 1, onRender)
	bound = true
	dbg("started")
end

local function stop()
	if not bound then
		return
	end
	pcall(function()
		RunService:UnbindFromRenderStep(BIND_NAME)
	end)
	bound = false
	dbg("stopped")
end

-- UI
local Window = Rayfield:CreateWindow({
	Name = "Reel Helper",
	LoadingTitle = "Reel Helper",
	LoadingSubtitle = "zone follows fish",
	ConfigurationSaving = { Enabled = false },
	KeySystem = false,
})

local Tab = Window:CreateTab("Reel", 4483362458)

Tab:CreateToggle({
	Name = "Zone follows fish",
	CurrentValue = false,
	Flag = "ZoneFollowFish",
	Callback = function(value)
		following = value
		if value then
			start()
		else
			stop()
		end
	end,
})

Tab:CreateToggle({
	Name = "Debug messages",
	CurrentValue = false,
	Flag = "ZoneFollowDebug",
	Callback = function(value)
		debugOn = value
	end,
})

Tab:CreateButton({
	Name = "Print status",
	Callback = function()
		local found = resolve()
		print("[ZoneFollow] following:", following, "| found:", found)
		if found then
			print("Zone:", zone.ClassName, zone.Position, zone.AbsoluteSize)
			print("Fish:", fish.ClassName, fish.Position, fish.AbsoluteSize)
		end
	end,
})

Tab:CreateButton({
	Name = "Unload script",
	Callback = function()
		following = false
		stop()
		Rayfield:Destroy()
	end,
})