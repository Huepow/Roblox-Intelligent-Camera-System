--[[
	ICS2K_Server  ->  ServerScriptService (Script)

	Optional. Makes the TIKTOK ring light rig and the PAPARAZZI phone pose visible to
	everyone in the server. Without it the camera system still works: the rig is
	simply built locally and only its owner sees it.

	What it owns:
	  ReplicatedStorage.ICS2K.Rig   RemoteEvent  spawn / attr / despawn the tripod
	  ReplicatedStorage.ICS2K.Pose  RemoteEvent  20 Hz phone pose relay for PAPARAZZI
	  workspace.ICS2K_Rigs          Folder       one tripod model per player

	Everything a client sends is validated and rate limited here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local folder = ReplicatedStorage:FindFirstChild("ICS2K")
if not folder then
	folder = Instance.new("Folder")
	folder.Name = "ICS2K"
	folder.Parent = ReplicatedStorage
end
local function remote(name)
	local r = folder:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = folder
	end
	return r
end
local rigEvent = remote("Rig")
local poseEvent = remote("Pose")

local rigs = Workspace:FindFirstChild("ICS2K_Rigs")
if not rigs then
	rigs = Instance.new("Folder")
	rigs.Name = "ICS2K_Rigs"
	rigs.Parent = Workspace
end

local PHONE_OFFSET = CFrame.new(0, 4.45, 0.15)
local MARK_OFFSET = Vector3.new(0, 0, -3.6)

-- Geometry mirrored from Tripod.buildModel in IntelligentCameraSystem.lua (keep both in sync).
local function buildRig(rootCF, ownerId)
	local m = Instance.new("Model")
	m.Name = "ICS2K_Rig"
	local function part(name, size, cf, color, material, shape)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = rootCF * cf
		p.Color = color
		p.Material = material or Enum.Material.Metal
		p.Shape = shape or Enum.PartType.Block
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = true
		p.Parent = m
		return p
	end
	local dark = Color3.fromRGB(28, 28, 32)
	local titanium = Color3.fromRGB(168, 166, 158)
	local hub = part("Hub", Vector3.new(0.3, 0.5, 0.5), CFrame.new(0, 0.9, 0) * CFrame.Angles(0, 0, math.rad(90)), dark, nil, Enum.PartType.Cylinder)
	for i = 1, 3 do
		local a = math.rad(90 + (i - 1) * 120)
		local foot = Vector3.new(math.cos(a) * 1.15, 0.06, math.sin(a) * 1.15)
		local top = Vector3.new(0, 0.85, 0)
		part("Leg" .. i, Vector3.new(0.1, 0.1, (foot - top).Magnitude), CFrame.lookAt((foot + top) / 2, foot), dark)
		part("Foot" .. i, Vector3.new(0.18, 0.1, 0.18), CFrame.new(foot), Color3.fromRGB(60, 60, 66), Enum.Material.Rubber)
	end
	part("Column", Vector3.new(0.12, 3.5, 0.12), CFrame.new(0, 2.6, 0), dark)
	part("Mount", Vector3.new(0.34, 0.3, 0.3), CFrame.new(0, 4.3, 0.06), dark)
	local phoneCF = PHONE_OFFSET
	part("JawTop", Vector3.new(0.95, 0.12, 0.22), phoneCF * CFrame.new(0, 0.92, 0.02), dark)
	part("JawBottom", Vector3.new(0.95, 0.12, 0.22), phoneCF * CFrame.new(0, -0.92, 0.02), dark)
	part("Phone", Vector3.new(0.82, 1.72, 0.075), phoneCF, titanium)
	part("Screen", Vector3.new(0.76, 1.64, 0.012), phoneCF * CFrame.new(0, 0, -0.042), Color3.fromRGB(4, 4, 7), Enum.Material.SmoothPlastic)
	part("Plateau", Vector3.new(0.36, 0.36, 0.03), phoneCF * CFrame.new(-0.2, 0.64, 0.05), Color3.fromRGB(150, 148, 140))
	for i, off in ipairs({ Vector3.new(-0.29, 0.73, 0.065), Vector3.new(-0.29, 0.55, 0.065), Vector3.new(-0.11, 0.64, 0.065) }) do
		part("Lens" .. i, Vector3.new(0.035, 0.14, 0.14), phoneCF * CFrame.new(off) * CFrame.Angles(0, math.rad(90), 0), Color3.fromRGB(10, 10, 14), Enum.Material.Glass, Enum.PartType.Cylinder)
	end
	part("RingArm", Vector3.new(0.08, 1.0, 0.08), CFrame.new(0, 5.35, 0.1), dark)
	local ringCF = CFrame.new(0, 5.85, 0.1) * CFrame.Angles(math.rad(-12), 0, 0)
	part("RingBack", Vector3.new(0.08, 2.3, 2.3), ringCF * CFrame.new(0, 0, 0.06) * CFrame.Angles(0, math.rad(90), 0), dark, nil, Enum.PartType.Cylinder)
	part("RingLight", Vector3.new(0.05, 2.2, 2.2), ringCF * CFrame.Angles(0, math.rad(90), 0), Color3.fromRGB(255, 244, 228), Enum.Material.Neon, Enum.PartType.Cylinder)
	part("RingCenter", Vector3.new(0.07, 1.3, 1.3), ringCF * CFrame.new(0, 0, -0.012) * CFrame.Angles(0, math.rad(90), 0), dark, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	for i = 1, 16 do
		local a = math.rad((i - 1) * 22.5)
		local p = MARK_OFFSET + Vector3.new(math.cos(a) * 1.25, 0.03, math.sin(a) * 1.25)
		part("Mark" .. i, Vector3.new(0.5, 0.04, 0.2), CFrame.new(p) * CFrame.Angles(0, -(a + math.pi / 2), 0), Color3.fromRGB(0, 229, 255), Enum.Material.Neon)
	end
	m.PrimaryPart = hub
	m:SetAttribute("Owner", ownerId)
	m:SetAttribute("Light", 2)
	m:SetAttribute("Temp", "NEUTRAL")
	m:SetAttribute("Rec", false)
	return m
end

local owned = {}
local lastSpawn = {}
local lastPose = {}
local TEMPS = { WARM = true, NEUTRAL = true, COOL = true }

local function removeRig(player)
	local m = owned[player]
	if m then
		owned[player] = nil
		m:Destroy()
	end
end

rigEvent.OnServerEvent:Connect(function(player, action, data)
	if action == "spawn" then
		if typeof(data) ~= "table" or typeof(data.cf) ~= "CFrame" then return end
		local now = os.clock()
		if lastSpawn[player] and now - lastSpawn[player] < 1 then return end
		lastSpawn[player] = now
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not root or (root.Position - data.cf.Position).Magnitude > 30 then return end
		removeRig(player)
		local m = buildRig(data.cf, player.UserId)
		m:SetAttribute("Light", math.clamp(math.floor((tonumber(data.light) or 2) + 0.5), 0, 4))
		local temp = tostring(data.temp or "NEUTRAL")
		m:SetAttribute("Temp", TEMPS[temp] and temp or "NEUTRAL")
		m.Parent = rigs
		owned[player] = m
	elseif action == "attr" then
		local m = owned[player]
		if not m or typeof(data) ~= "table" then return end
		if data.key == "Light" then
			m:SetAttribute("Light", math.clamp(math.floor((tonumber(data.value) or 2) + 0.5), 0, 4))
		elseif data.key == "Temp" then
			local v = tostring(data.value)
			if TEMPS[v] then m:SetAttribute("Temp", v) end
		elseif data.key == "Rec" then
			m:SetAttribute("Rec", data.value == true)
		end
	elseif action == "despawn" then
		removeRig(player)
	end
end)

poseEvent.OnServerEvent:Connect(function(player, rel, weight, torch)
	if typeof(rel) ~= "CFrame" or type(weight) ~= "number" then return end
	local now = os.clock()
	if lastPose[player] and now - lastPose[player] < 1 / 25 then return end
	lastPose[player] = now
	poseEvent:FireAllClients(player, rel, math.clamp(weight, 0, 1), torch == true)
end)

Players.PlayerRemoving:Connect(function(player)
	removeRig(player)
	lastSpawn[player] = nil
	lastPose[player] = nil
end)
