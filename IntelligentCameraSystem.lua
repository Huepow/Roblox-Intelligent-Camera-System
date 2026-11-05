--[[
	==========================================================================
	  ICS2K  //  INTELLIGENT CAMERA SYSTEM 2000  //  V10 "CHROME"
	==========================================================================
	  LocalScript  ->  StarterPlayer > StarterPlayerScripts > IntelligentCameraSystem

	  MODES (press C to cycle, X to exit to the standard Roblox camera)
	    STANDARD   the default Roblox camera, untouched
	    FREE       smooth drone flight, 120x exponential zoom, bookmarks + dolly rail
	    CINEMATIC  an AI shot director with 11 shot types + film look
	    PAPARAZZI  pull out an iPhone, front camera, selfies, flash, gallery
	    BODYCAM    first person body camera with head bob + timestamp overlay
	    DRONE      an autonomous follow drone with lead prediction + banking
	    TACTICAL   top down RTS style camera with x-ray roofs and deadzone follow
	    CCTV       security cameras placed by you, PTZ tracking, smart switching

	  UI: press I for the ICS2K window (modes, settings, filter, gallery, keys)
	  PC only. Mobile / VR fall back to the standard camera.

	  Written in the Lua 5.1 compatible subset of Luau on purpose: the whole file
	  is parse-checked and executed in a headless harness before release.
	==========================================================================
]]

----------------------------------------------------------------------------
-- 1. SERVICES / BOOTSTRAP
----------------------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local Lighting = game:GetService("Lighting")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera
local playerGui = player:WaitForChild("PlayerGui")

-- Platform guard: this system is keyboard + mouse. Touch / VR keep the stock camera.
do
	local isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
	local isVR = UserInputService.VREnabled
	if isMobile or isVR then
		return
	end
end

local char = player.Character or player.CharacterAdded:Wait()
local humanoid = char:WaitForChild("Humanoid")
local root = char:WaitForChild("HumanoidRootPart")

----------------------------------------------------------------------------
-- 2. CONFIG (engineering constants) + SETTINGS (what the UI exposes)
----------------------------------------------------------------------------
local CFG = {
	version = "10.0 CHROME",
	baseFov = 70,
	minFov = 1,
	maxFov = 120,
	transitionTime = 0.65,
	afkTimeout = 180,
	hudRate = 20, -- Hz
	uiAnimRate = 30, -- Hz
	pointerProbeRate = 12, -- Hz, how often we ask "is the mouse over some UI?"
	collisionIgnoreNames = {
		"coin", "pickup", "collectible", "powerup", "token", "mannequin", "maniquien",
		"displaymodel", "clothingstand", "wearabledisplay", "tryon", "outfitdisplay",
		"gem", "crystal", "orb", "star", "heart", "diamond", "treasure", "reward",
		"prize", "bonus", "item",
	},
	collisionIgnoreTags = { "IgnoreCameraCollision", "Collectible" },
	shopGuiWords = { "shop", "store", "purchase", "buy", "inventory", "catalog", "market", "wardrobe" },
	sounds = {
		-- Legacy built-in client sounds. Replace with rbxassetid:// ids if you have nicer ones.
		click = "rbxasset://sounds/clickfast.mp3",
		ping = "rbxasset://sounds/electronicpingshort.mp3",
		shutter = "rbxasset://sounds/flashbulb.mp3",
		swoosh = "rbxasset://sounds/swoosh.mp3",
	},
	grainTextureFallback = "rbxasset://textures/particles/smoke_main.dds",
	runwayWalkSpeed = 6.5,
}

-- Everything in S is a live setting. DEFAULTS is the factory copy for "reset".
local S = {
	general = {
		transitions = true,
		afk = true,
		afkTimeout = 180,
		hud = true,
		toasts = true,
		sounds = true,
		screensaver = true,
		paparazziFlashes = false,
		uiScale = 1.0,
	},
	carousel = {
		FREE = true, CINEMATIC = true, PAPARAZZI = true, TIKTOK = true, BODYCAM = true,
		DRONE = true, TACTICAL = true, CCTV = true,
	},
	free = {
		sensitivity = 1.0,
		flySpeed = 32,
		accel = 9,
		smoothing = 0.35,
		zoomSpeed = 1.0,
		maxZoom = 120,
		rollSpeed = 110,
		autoLevel = false,
		collision = true,
		speedFov = true,
		autofocus = true,
		showRail = true,
		railSegmentTime = 2.5,
		railLoop = false,
	},
	cinematic = {
		energy = 0.45,
		shotLength = 1.0,
		handheld = 0.5,
		zoom = 1.0,
		autoFocus = true,
		preset = "KODAK",
	},
	paparazzi = {
		armLength = 1.0,
		fov = 68,
		sensitivity = 1.0,
		torch = 2.0,
		shake = 0.5,
		preset = "PORTRAIT",
	},
	tiktok = {
		fov = 62,
		markDistance = 7,
		light = 2,
		temp = "NEUTRAL",
		centerStage = true,
		autoZoom = false,
		autoZoomStrength = 1.0,
		clipFrames = 15,
		hearts = true,
		preset = "PORTRAIT",
	},
	bodycam = {
		fov = 100,
		headBob = 1.0,
		sensitivity = 1.0,
		sprint = 1.6,
		overlay = true,
		preset = "BODYCAM",
	},
	drone = {
		distance = 12,
		height = 5,
		stiffness = 0.65,
		damping = 0.8,
		lead = 0.35,
		autoOrbit = true,
		orbitSpeed = 10,
		sensitivity = 1.0,
		hud = true,
	},
	tactical = {
		height = 40,
		pitch = 65,
		deadzone = 4,
		xray = true,
		smoothing = 0.5,
		fov = 45,
	},
	cctv = {
		cycleSeconds = 8,
		autoCycle = true,
		tracking = true,
		smartSwitch = true,
		glitches = true,
		fov = 80,
		preset = "CCTV",
	},
	filter = {
		preset = "OFF",
		lock = false,
		grain = 0, vignette = 0, letterbox = 0, scanlines = 0,
		bloom = 0, bloomSize = 24, contrast = 0, saturation = 0, brightness = 0,
		blur = 0, dof = 0, dofRadius = 6, tint = "NONE",
		userPreset = "OFF",
	},
}

local function deepCopy(t)
	local out = {}
	for k, v in pairs(t) do
		if type(v) == "table" then out[k] = deepCopy(v) else out[k] = v end
	end
	return out
end
local DEFAULTS = deepCopy(S)

----------------------------------------------------------------------------
-- 3. UTIL
----------------------------------------------------------------------------
local Util = {}
local clamp = math.clamp
local rad, deg = math.rad, math.deg
local rng = Random.new()

function Util.expAlpha(rate, dt) return 1 - math.exp(-rate * dt) end
function Util.smooth(cur, target, rate, dt) return cur + (target - cur) * Util.expAlpha(rate, dt) end
function Util.smoothVec(cur, target, rate, dt) return cur:Lerp(target, Util.expAlpha(rate, dt)) end
function Util.angleDelta(a, b) return (b - a + 180) % 360 - 180 end
function Util.smoothAngle(cur, target, rate, dt) return cur + Util.angleDelta(cur, target) * Util.expAlpha(rate, dt) end
function Util.wrapAngle(a) return (a + 180) % 360 - 180 end
function Util.smoothstep(t) t = clamp(t, 0, 1) return t * t * (3 - 2 * t) end
function Util.easeOutCubic(t) t = clamp(t, 0, 1) return 1 - (1 - t) * (1 - t) * (1 - t) end
function Util.easeInOutCubic(t)
	t = clamp(t, 0, 1)
	if t < 0.5 then return 4 * t * t * t end
	local u = -2 * t + 2
	return 1 - u * u * u / 2
end
function Util.easeOutBack(t)
	t = clamp(t, 0, 1)
	local c1, c3 = 1.70158, 2.70158
	return 1 + c3 * (t - 1) * (t - 1) * (t - 1) + c1 * (t - 1) * (t - 1)
end
function Util.lerp(a, b, t) return a + (b - a) * t end
function Util.round(n, step) step = step or 1 return math.floor(n / step + 0.5) * step end
function Util.sign(n) if n > 0 then return 1 elseif n < 0 then return -1 end return 0 end

-- Critically-damped-ish spring; works for numbers and Vector3 alike. Substeps keep it stable.
function Util.spring(pos, vel, target, stiffness, damping, dt)
	local steps = math.max(1, math.ceil(dt / (1 / 120)))
	local h = dt / steps
	for _ = 1, steps do
		local accel = (target - pos) * stiffness - vel * damping
		vel = vel + accel * h
		pos = pos + vel * h
	end
	return pos, vel
end

function Util.flatten(v) return Vector3.new(v.X, 0, v.Z) end
function Util.safeUnit(v, fallback)
	if v.Magnitude < 1e-4 then return fallback or Vector3.new(0, 0, -1) end
	return v.Unit
end
function Util.yawOf(cf) local _, y = cf:ToEulerAnglesYXZ() return y end
function Util.catmullRom(p0, p1, p2, p3, t)
	local t2, t3 = t * t, t * t * t
	return (p1 * 2 + (p2 - p0) * t + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2 + (p1 * 3 - p0 - p2 * 3 + p3) * t3) * 0.5
end
function Util.noise3(t, seed)
	return Vector3.new(
		math.noise(t, seed, 0.5),
		math.noise(t + 31.7, seed + 7.1, 0.5),
		math.noise(t + 77.3, seed + 13.9, 0.5))
end
function Util.fmtTime(sec)
	sec = math.max(0, math.floor(sec))
	return string.format("%02d:%02d", math.floor(sec / 60), sec % 60)
end
function Util.clock24() return os.date("%H:%M") end
function Util.stamp() return os.date("%Y-%m-%d %H:%M:%S") end
function Util.dateLong() return os.date("%A, %B %d") end

-- Maid: collect connections / instances / functions and clean them in one call.
local Maid = {}
Maid.__index = Maid
function Maid.new() return setmetatable({ _items = {} }, Maid) end
function Maid:give(item) table.insert(self._items, item) return item end
function Maid:clean()
	for i = #self._items, 1, -1 do
		local item = self._items[i]
		local ty = typeof(item)
		if ty == "RBXScriptConnection" then
			item:Disconnect()
		elseif ty == "Instance" then
			item:Destroy()
		elseif ty == "function" then
			pcall(item)
		elseif ty == "table" and item.clean then
			item:clean()
		end
		self._items[i] = nil
	end
end

-- Instance builder: new("Frame", {props}, {children})
local function new(class, props, children)
	local inst = Instance.new(class)
	local parent
	if props then
		for k, v in pairs(props) do
			if k == "Parent" then parent = v else inst[k] = v end
		end
	end
	if children then
		for _, c in ipairs(children) do c.Parent = inst end
	end
	if parent then inst.Parent = parent end
	return inst
end
Util.new = new

local function tween(inst, props, time, style, dir)
	local info = TweenInfo.new(time or 0.2, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out)
	local tw = TweenService:Create(inst, info, props)
	tw:Play()
	return tw
end
Util.tween = tween

-- Sound: fire-and-forget, never errors.
local Sound = {}
function Sound.play(name, volume)
	if not S.general.sounds then return end
	local id = CFG.sounds[name]
	if not id or id == "" then return end
	pcall(function()
		local s = Instance.new("Sound")
		s.SoundId = id
		s.Volume = volume or 0.35
		s.Parent = playerGui
		s:Play()
		task.delay(3, function() s:Destroy() end)
	end)
end

----------------------------------------------------------------------------
-- 4. CHARACTER REFERENCES + RAYCAST CACHE
----------------------------------------------------------------------------
local Rig = { char = char, humanoid = humanoid, root = root, head = char:FindFirstChild("Head") }

local Ray = { params = RaycastParams.new(), dirty = true }
Ray.params.FilterType = Enum.RaycastFilterType.Exclude
Ray.params.IgnoreWater = true

function Ray.refresh()
	local filter = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then table.insert(filter, p.Character) end
	end
	local markers = Workspace:FindFirstChild("ICS2K_Local")
	if markers then table.insert(filter, markers) end
	Ray.params.FilterDescendantsInstances = filter
	Ray.dirty = false
end

function Ray.shouldIgnore(instance)
	if not instance then return false end
	local lname = instance.Name:lower()
	for _, word in ipairs(CFG.collisionIgnoreNames) do
		if lname:find(word, 1, true) then return true end
	end
	for _, tag in ipairs(CFG.collisionIgnoreTags) do
		if CollectionService:HasTag(instance, tag) then return true end
	end
	local model = instance:FindFirstAncestorOfClass("Model")
	if model and Players:GetPlayerFromCharacter(model) then return true end
	return false
end

-- Raycast that skips "ignorable" hits by re-casting past them (max 3 hops).
function Ray.cast(origin, direction)
	if Ray.dirty then Ray.refresh() end
	local from, dir = origin, direction
	for _ = 1, 3 do
		local result = Workspace:Raycast(from, dir, Ray.params)
		if not result then return nil end
		if not Ray.shouldIgnore(result.Instance) then return result end
		local travelled = result.Position - from
		local remaining = dir - travelled
		from = result.Position + dir.Unit * 0.05
		dir = remaining
		if dir.Magnitude < 0.1 then return nil end
	end
	return nil
end

function Ray.sphere(origin, radius, direction)
	if Ray.dirty then Ray.refresh() end
	if direction.Magnitude < 1e-5 then return nil end
	local ok, result = pcall(function() return Workspace:Spherecast(origin, radius, direction, Ray.params) end)
	if not ok then return nil end
	if result and Ray.shouldIgnore(result.Instance) then return nil end
	return result
end

-- Pull a camera position toward a look target until the line of sight is clear.
function Ray.pullIn(camPos, lookAt, buffer)
	buffer = buffer or 0.8
	local dir = camPos - lookAt
	local dist = dir.Magnitude
	if dist < 0.1 then return camPos end
	local hit = Ray.cast(lookAt, dir)
	if hit then
		local d = math.max(0.5, (hit.Position - lookAt).Magnitude - buffer)
		return lookAt + dir.Unit * d
	end
	return camPos
end

-- Move a point with sphere collision + sliding (two passes).
function Ray.slide(pos, move, radius)
	if move.Magnitude < 1e-5 then return pos end
	local hit = Ray.sphere(pos, radius, move)
	if not hit then return pos + move end
	local n = hit.Normal
	local slideMove = move - n * move:Dot(n)
	local hit2 = Ray.sphere(pos, radius, slideMove)
	if hit2 then
		local n2 = hit2.Normal
		slideMove = slideMove - n2 * slideMove:Dot(n2)
		if Ray.sphere(pos, radius, slideMove) then return pos end
	end
	return pos + slideMove
end

function Ray.isIndoors(pos)
	local hit = Ray.cast(pos, Vector3.new(0, 40, 0))
	return hit ~= nil
end

function Ray.groundY(pos, maxDrop)
	local hit = Ray.cast(pos, Vector3.new(0, -(maxDrop or 50), 0))
	if hit then return hit.Position.Y end
	return nil
end

----------------------------------------------------------------------------
-- 5. SHARED CAMERA STATE + FORWARD DECLARATIONS
----------------------------------------------------------------------------
local Cam = {
	cf = camera.CFrame,
	fov = CFG.baseFov,
	focus = nil, -- distance in studs for depth of field, or nil
	blendFrom = nil, blendFromFov = 70, blendT = 1, blendDur = 0.65,
	scriptable = false,
	override = nil, -- a function(dt) that fully owns the camera (rail playback / intros)
}

local STATE = {
	modeId = "STANDARD",
	previousModeId = "FREE",
	uiHidden = false,
	windowOpen = false,
	pointerOverUI = false,
	shopUIOpen = false,
	rmb = false,
	lmb = false,
	keys = {},
	runway = false,
	lastActivity = os.clock(),
	afk = false,
	mouseLocked = false,
	textFocused = false,
	startedAt = os.clock(),
}

-- Forward declared so UI code can call into the mode system defined later.
local Modes, setMode, cycleMode, Filter, HUD, Gallery, Phone, Bookmarks, Rail, Body, Toast, Window, Chip

----------------------------------------------------------------------------
-- 6. Y2K THEME + UI KIT
----------------------------------------------------------------------------
local T = {
	bg = Color3.fromRGB(12, 11, 22),
	panel = Color3.fromRGB(20, 18, 36),
	panel2 = Color3.fromRGB(30, 28, 52),
	panel3 = Color3.fromRGB(42, 40, 70),
	chromeA = Color3.fromRGB(248, 248, 255),
	chromeB = Color3.fromRGB(201, 203, 221),
	chromeC = Color3.fromRGB(242, 242, 250),
	chromeD = Color3.fromRGB(174, 177, 198),
	chromeE = Color3.fromRGB(127, 130, 153),
	cyan = Color3.fromRGB(0, 229, 255),
	magenta = Color3.fromRGB(255, 62, 201),
	lime = Color3.fromRGB(180, 255, 58),
	lavender = Color3.fromRGB(200, 182, 255),
	gold = Color3.fromRGB(255, 214, 90),
	text = Color3.fromRGB(236, 236, 248),
	textDark = Color3.fromRGB(18, 16, 30),
	muted = Color3.fromRGB(150, 150, 184),
	danger = Color3.fromRGB(255, 80, 110),
	black = Color3.fromRGB(0, 0, 0),
	white = Color3.fromRGB(255, 255, 255),
	font = {
		head = Enum.Font.Michroma,
		body = Enum.Font.Jura,
		mono = Enum.Font.Code,
		big = Enum.Font.Sarpanch,
		ui = Enum.Font.GothamMedium,
		uiBold = Enum.Font.GothamBold,
	},
}

T.iridescent = ColorSequence.new({
	ColorSequenceKeypoint.new(0.00, T.cyan),
	ColorSequenceKeypoint.new(0.30, T.lavender),
	ColorSequenceKeypoint.new(0.55, T.magenta),
	ColorSequenceKeypoint.new(0.80, T.lime),
	ColorSequenceKeypoint.new(1.00, T.cyan),
})
T.chrome = ColorSequence.new({
	ColorSequenceKeypoint.new(0.00, T.chromeA),
	ColorSequenceKeypoint.new(0.38, T.chromeB),
	ColorSequenceKeypoint.new(0.50, T.chromeC),
	ColorSequenceKeypoint.new(0.62, T.chromeD),
	ColorSequenceKeypoint.new(1.00, T.chromeE),
})
T.glass = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(34, 32, 60)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(14, 13, 26)),
})

local UI = { anims = {}, dragging = nil, scale = 1 }

-- Animation registry: tiny functions stepped at CFG.uiAnimRate from the main loop.
function UI.animate(fn)
	local handle = { fn = fn, alive = true }
	table.insert(UI.anims, handle)
	return handle
end
function UI.tickAnims(t, dt)
	for i = #UI.anims, 1, -1 do
		local h = UI.anims[i]
		if not h.alive then
			table.remove(UI.anims, i)
		else
			local ok = pcall(h.fn, t, dt)
			if not ok then h.alive = false end
		end
	end
end

function UI.corner(parent, radius)
	return new("UICorner", { CornerRadius = UDim.new(0, radius or 10), Parent = parent })
end
function UI.pill(parent)
	return new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = parent })
end
function UI.stroke(parent, thickness, color, transparency)
	return new("UIStroke", {
		Thickness = thickness or 1,
		Color = color or T.chromeD,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end
function UI.gradient(parent, colors, rotation, transparency)
	local g = new("UIGradient", { Color = colors, Rotation = rotation or 90, Parent = parent })
	if transparency then g.Transparency = transparency end
	return g
end
function UI.padding(parent, all, left, right, top, bottom)
	return new("UIPadding", {
		PaddingLeft = UDim.new(0, left or all or 0),
		PaddingRight = UDim.new(0, right or all or 0),
		PaddingTop = UDim.new(0, top or all or 0),
		PaddingBottom = UDim.new(0, bottom or all or 0),
		Parent = parent,
	})
end
function UI.list(parent, gap, horizontal, align)
	return new("UIListLayout", {
		Padding = UDim.new(0, gap or 6),
		FillDirection = horizontal and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = align or Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Parent = parent,
	})
end

-- Rotating holographic gradient on any Frame / UIStroke
function UI.iridescent(target, speed, rotation)
	local g = UI.gradient(target, T.iridescent, rotation or 0)
	local phase = rng:NextNumber(0, 360)
	UI.animate(function(t)
		if not g.Parent then return error("dead") end
		g.Rotation = (phase + t * (speed or 40)) % 360
	end)
	return g
end

function UI.chromeFill(frame, rotation)
	frame.BackgroundColor3 = T.white
	return UI.gradient(frame, T.chrome, rotation or 90)
end

-- Glossy highlight on the top half of a frame (Y2K bubble sheen)
function UI.gloss(frame, radius)
	local g = new("Frame", {
		Name = "Gloss",
		Size = UDim2.new(1, -4, 0.48, 0),
		Position = UDim2.new(0, 2, 0, 2),
		BackgroundColor3 = T.white,
		BackgroundTransparency = 0.72,
		BorderSizePixel = 0,
		ZIndex = frame.ZIndex + 1,
		Parent = frame,
	})
	UI.gradient(g, ColorSequence.new(T.white, T.white), 90,
		NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) }))
	new("UICorner", { CornerRadius = radius or UDim.new(1, 0), Parent = g })
	return g
end

function UI.text(parent, str, o)
	o = o or {}
	local lbl = new("TextLabel", {
		Name = o.name or "Text",
		Text = str or "",
		Font = o.font or T.font.body,
		TextSize = clamp(o.size or 14, 1, 100),
		TextColor3 = o.color or T.text,
		BackgroundTransparency = 1,
		Size = o.frameSize or UDim2.new(1, 0, 0, o.height or 18),
		Position = o.pos or UDim2.new(0, 0, 0, 0),
		TextXAlignment = o.xalign or Enum.TextXAlignment.Left,
		TextYAlignment = o.yalign or Enum.TextYAlignment.Center,
		TextWrapped = o.wrap or false,
		TextTruncate = o.truncate and Enum.TextTruncate.AtEnd or Enum.TextTruncate.None,
		RichText = o.rich or false,
		ZIndex = o.z or (parent and parent:IsA("GuiObject") and parent.ZIndex + 1 or 1),
		LayoutOrder = o.order or 0,
		AnchorPoint = o.anchor or Vector2.new(0, 0),
		TextTransparency = o.transparency or 0,
		Parent = parent,
	})
	if o.stroke then UI.stroke(lbl, o.stroke, o.strokeColor or T.black, o.strokeTransparency or 0.6) end
	return lbl
end

-- Buttons. kind: "chrome" | "primary" | "ghost" | "danger" | "dark"
function UI.button(parent, o)
	o = o or {}
	local kind = o.kind or "chrome"
	local btn = new("TextButton", {
		Name = o.name or "Button",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = T.panel2,
		BorderSizePixel = 0,
		Size = o.size or UDim2.new(0, 120, 0, 32),
		Position = o.pos or UDim2.new(0, 0, 0, 0),
		AnchorPoint = o.anchor or Vector2.new(0, 0),
		ZIndex = o.z or (parent and parent:IsA("GuiObject") and parent.ZIndex + 1 or 2),
		LayoutOrder = o.order or 0,
		Parent = parent,
	})
	local corner = new("UICorner", { CornerRadius = o.radius or UDim.new(1, 0), Parent = btn })
	local label = UI.text(btn, o.text or "", {
		font = o.font or T.font.head,
		size = o.textSize or 11,
		color = T.text,
		xalign = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, -8, 1, 0),
		pos = UDim2.new(0, 4, 0, 0),
		z = btn.ZIndex + 2,
	})
	local stroke = UI.stroke(btn, 1, T.chromeE, 0.2)
	local scale = new("UIScale", { Scale = 1, Parent = btn })

	local function style(hover)
		if kind == "chrome" then
			btn.BackgroundColor3 = T.white
			label.TextColor3 = T.textDark
		elseif kind == "primary" then
			btn.BackgroundColor3 = T.white
			label.TextColor3 = T.textDark
		elseif kind == "danger" then
			btn.BackgroundColor3 = hover and Color3.fromRGB(255, 110, 135) or T.danger
			label.TextColor3 = T.textDark
		elseif kind == "dark" then
			btn.BackgroundColor3 = hover and T.panel3 or T.panel2
			label.TextColor3 = T.text
		else -- ghost
			btn.BackgroundColor3 = T.panel2
			btn.BackgroundTransparency = hover and 0.4 or 0.75
			label.TextColor3 = hover and T.text or T.muted
		end
		stroke.Transparency = hover and 0 or 0.35
	end
	if kind == "chrome" then
		UI.gradient(btn, T.chrome, 90)
		UI.gloss(btn, corner.CornerRadius)
	elseif kind == "primary" then
		UI.iridescent(btn, 60, 0)
		UI.gloss(btn, corner.CornerRadius)
		stroke.Color = T.white
	end
	style(false)

	btn.MouseEnter:Connect(function() style(true) tween(scale, { Scale = 1.03 }, 0.12) end)
	btn.MouseLeave:Connect(function() style(false) tween(scale, { Scale = 1 }, 0.12) end)
	btn.MouseButton1Down:Connect(function() tween(scale, { Scale = 0.96 }, 0.08) end)
	btn.MouseButton1Up:Connect(function() tween(scale, { Scale = 1.03 }, 0.08) end)
	btn.MouseButton1Click:Connect(function()
		Sound.play("click", 0.25)
		if o.onClick then o.onClick(btn) end
	end)
	local api = { button = btn, label = label, stroke = stroke }
	function api.setText(t) label.Text = t end
	function api.setKind(k) kind = k style(false) end
	return api
end

-- Section header + content container for scrolling settings lists
function UI.section(parent, title, o)
	o = o or {}
	local holder = new("Frame", {
		Name = "Section_" .. title,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = o.order or 0,
		Parent = parent,
	})
	UI.list(holder, 4)
	local header = new("TextButton", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundColor3 = T.panel2,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = 0,
		Parent = holder,
	})
	UI.corner(header, 8)
	local bar = new("Frame", {
		Size = UDim2.new(0, 3, 1, -8), Position = UDim2.new(0, 6, 0, 4),
		BackgroundColor3 = T.cyan, BorderSizePixel = 0, Parent = header,
	})
	UI.pill(bar)
	UI.iridescent(bar, 80, 90)
	UI.text(header, title:upper(), {
		font = T.font.head, size = 10, color = T.lavender,
		frameSize = UDim2.new(1, -40, 1, 0), pos = UDim2.new(0, 16, 0, 0),
	})
	local arrow = UI.text(header, o.collapsed and "+" or "–", {
		font = T.font.mono, size = 14, color = T.muted,
		frameSize = UDim2.new(0, 20, 1, 0), pos = UDim2.new(1, -24, 0, 0),
		xalign = Enum.TextXAlignment.Center,
	})
	local content = new("Frame", {
		Name = "Content",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Visible = not o.collapsed,
		LayoutOrder = 1,
		Parent = holder,
	})
	UI.list(content, 4)
	UI.padding(content, 0, 8, 4, 2, 6)
	local api = { holder = holder, content = content, header = header }
	function api.setOpen(open)
		content.Visible = open
		arrow.Text = open and "–" or "+"
	end
	header.MouseButton1Click:Connect(function() api.setOpen(not content.Visible) end)
	return api
end

-- Horizontal key + description row (for the KEYS tab)
function UI.keyRow(parent, key, desc, order)
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, LayoutOrder = order or 0, Parent = parent,
	})
	local pillF = new("Frame", {
		Size = UDim2.new(0, 92, 0, 22), Position = UDim2.new(0, 0, 0.5, -11),
		BackgroundColor3 = T.white, BorderSizePixel = 0, Parent = row,
	})
	UI.corner(pillF, 6)
	UI.gradient(pillF, T.chrome, 90)
	UI.stroke(pillF, 1, T.chromeE, 0.3)
	UI.text(pillF, key, {
		font = T.font.mono, size = 12, color = T.textDark, xalign = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, 0, 1, 0),
	})
	UI.text(row, desc, {
		font = T.font.body, size = 13, color = T.text, frameSize = UDim2.new(1, -100, 1, 0),
		pos = UDim2.new(0, 100, 0, 0), truncate = true,
	})
	return row
end

-- Slider: {label, min, max, step, value, format, onChange, order}
function UI.slider(parent, o)
	local row = new("Frame", {
		Name = "Slider_" .. (o.label or ""),
		Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1, LayoutOrder = o.order or 0, Parent = parent,
	})
	UI.text(row, o.label or "", { font = T.font.body, size = 13, frameSize = UDim2.new(0.65, 0, 0, 18) })
	local readout = UI.text(row, "", {
		font = T.font.mono, size = 12, color = T.lavender, xalign = Enum.TextXAlignment.Right,
		frameSize = UDim2.new(0.35, 0, 0, 18), pos = UDim2.new(0.65, 0, 0, 0),
	})
	local track = new("Frame", {
		Name = "Track", Size = UDim2.new(1, -16, 0, 6), Position = UDim2.new(0, 8, 0, 30),
		BackgroundColor3 = T.panel3, BorderSizePixel = 0, Parent = row,
	})
	UI.pill(track)
	local fill = new("Frame", {
		Name = "Fill", Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = T.cyan, BorderSizePixel = 0, Parent = track,
	})
	UI.pill(fill)
	UI.iridescent(fill, 50, 0)
	local knob = new("Frame", {
		Name = "Knob", Size = UDim2.new(0, 16, 0, 16), AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0), BackgroundColor3 = T.white, BorderSizePixel = 0,
		ZIndex = track.ZIndex + 2, Parent = track,
	})
	UI.pill(knob)
	UI.gradient(knob, T.chrome, 90)
	UI.stroke(knob, 1, T.chromeE, 0.1)
	UI.gloss(knob)
	local hit = new("TextButton", {
		Name = "Hit", Size = UDim2.new(1, 0, 0, 24), Position = UDim2.new(0, 0, 0, 21),
		BackgroundTransparency = 1, Text = "", ZIndex = track.ZIndex + 3, Parent = row,
	})

	local min, max, step = o.min or 0, o.max or 1, o.step or 0.01
	local value = o.value or min
	local api = {}
	local function render()
		local a = (max > min) and clamp((value - min) / (max - min), 0, 1) or 0
		fill.Size = UDim2.new(a, 0, 1, 0)
		knob.Position = UDim2.new(a, 0, 0.5, 0)
		if o.format then readout.Text = o.format(value) else readout.Text = string.format("%.2f", value) end
	end
	function api.set(v, fire)
		v = clamp(Util.round(v, step), min, max)
		value = v
		render()
		if fire and o.onChange then o.onChange(v) end
	end
	function api.get() return value end
	local function fromX(x)
		local a = clamp((x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
		api.set(min + a * (max - min), true)
	end
	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			UI.dragging = { update = fromX }
			fromX(UserInputService:GetMouseLocation().X)
		end
	end)
	hit.MouseEnter:Connect(function() tween(knob, { Size = UDim2.new(0, 20, 0, 20) }, 0.1) end)
	hit.MouseLeave:Connect(function() tween(knob, { Size = UDim2.new(0, 16, 0, 16) }, 0.1) end)
	render()
	return api
end

-- Toggle switch: {label, value, onChange, order}
function UI.toggle(parent, o)
	local row = new("Frame", {
		Name = "Toggle_" .. (o.label or ""),
		Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, LayoutOrder = o.order or 0, Parent = parent,
	})
	UI.text(row, o.label or "", { font = T.font.body, size = 13, frameSize = UDim2.new(1, -60, 1, 0) })
	local sw = new("TextButton", {
		Name = "Switch", Size = UDim2.new(0, 42, 0, 22), Position = UDim2.new(1, -42, 0.5, -11),
		BackgroundColor3 = T.panel3, BorderSizePixel = 0, Text = "", AutoButtonColor = false, Parent = row,
	})
	UI.pill(sw)
	local swStroke = UI.stroke(sw, 1, T.chromeE, 0.3)
	local onFill = new("Frame", {
		Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = T.lime, BorderSizePixel = 0,
		BackgroundTransparency = 1, Parent = sw,
	})
	UI.pill(onFill)
	UI.iridescent(onFill, 70, 0)
	local knob = new("Frame", {
		Size = UDim2.new(0, 18, 0, 18), Position = UDim2.new(0, 2, 0.5, -9),
		BackgroundColor3 = T.white, BorderSizePixel = 0, ZIndex = sw.ZIndex + 2, Parent = sw,
	})
	UI.pill(knob)
	UI.gradient(knob, T.chrome, 90)
	UI.gloss(knob)
	local value = o.value and true or false
	local api = {}
	local function render(animate)
		local pos = value and UDim2.new(1, -20, 0.5, -9) or UDim2.new(0, 2, 0.5, -9)
		if animate then tween(knob, { Position = pos }, 0.15, Enum.EasingStyle.Back)
		else knob.Position = pos end
		if animate then tween(onFill, { BackgroundTransparency = value and 0 or 1 }, 0.15)
		else onFill.BackgroundTransparency = value and 0 or 1 end
		swStroke.Color = value and T.white or T.chromeE
	end
	function api.set(v, fire)
		value = v and true or false
		render(true)
		if fire and o.onChange then o.onChange(value) end
	end
	function api.get() return value end
	sw.MouseButton1Click:Connect(function()
		Sound.play("click", 0.2)
		api.set(not value, true)
	end)
	render(false)
	return api
end

-- Segmented control: {label, options = {{id, label}}, value, onChange, order}
function UI.segmented(parent, o)
	local row = new("Frame", {
		Name = "Seg_" .. (o.label or ""),
		Size = UDim2.new(1, 0, 0, o.label and 50 or 30), BackgroundTransparency = 1,
		LayoutOrder = o.order or 0, Parent = parent,
	})
	if o.label then
		UI.text(row, o.label, { font = T.font.body, size = 13, frameSize = UDim2.new(1, 0, 0, 18) })
	end
	local bar = new("Frame", {
		Size = UDim2.new(1, 0, 0, 28), Position = UDim2.new(0, 0, 0, o.label and 22 or 0),
		BackgroundColor3 = T.panel3, BorderSizePixel = 0, Parent = row,
	})
	UI.pill(bar)
	UI.stroke(bar, 1, T.chromeE, 0.4)
	UI.padding(bar, 3)
	UI.list(bar, 3, true)
	local buttons = {}
	local value = o.value
	local api = {}
	local function render()
		for id, b in pairs(buttons) do
			local active = (id == value)
			b.btn.BackgroundTransparency = active and 0 or 1
			b.label.TextColor3 = active and T.textDark or T.muted
			b.grad.Enabled = active
		end
	end
	for i, opt in ipairs(o.options) do
		local btn = new("TextButton", {
			Size = UDim2.new(1 / #o.options, -3, 1, 0), BackgroundColor3 = T.white, BorderSizePixel = 0,
			Text = "", AutoButtonColor = false, LayoutOrder = i, Parent = bar,
		})
		UI.pill(btn)
		local grad = UI.gradient(btn, T.chrome, 90)
		local lbl = UI.text(btn, opt[2] or opt[1], {
			font = T.font.head, size = 9, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 1, 0),
		})
		buttons[opt[1]] = { btn = btn, label = lbl, grad = grad }
		btn.MouseButton1Click:Connect(function()
			Sound.play("click", 0.2)
			value = opt[1]
			render()
			if o.onChange then o.onChange(value) end
		end)
	end
	function api.set(v, fire)
		value = v
		render()
		if fire and o.onChange then o.onChange(v) end
	end
	function api.get() return value end
	render()
	return api
end

function UI.divider(parent, order)
	local d = new("Frame", {
		Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = T.chromeE, BackgroundTransparency = 0.6,
		BorderSizePixel = 0, LayoutOrder = order or 0, Parent = parent,
	})
	return d
end

function UI.scroller(parent, o)
	o = o or {}
	local sf = new("ScrollingFrame", {
		Name = o.name or "Scroller",
		Size = o.size or UDim2.new(1, 0, 1, 0),
		Position = o.pos or UDim2.new(0, 0, 0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = T.lavender,
		ScrollBarImageTransparency = 0.3,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ElasticBehavior = Enum.ElasticBehavior.Never,
		Visible = o.visible ~= false,
		Parent = parent,
	})
	UI.list(sf, o.gap or 6)
	UI.padding(sf, 0, 10, 12, 8, 12)
	return sf
end

-- Sparkle decorations (✦) that twinkle
function UI.sparkles(parent, count, color)
	for i = 1, count or 3 do
		local s = UI.text(parent, "✦", {
			font = T.font.body, size = rng:NextInteger(9, 15), color = color or T.lavender,
			frameSize = UDim2.new(0, 16, 0, 16),
			pos = UDim2.new(rng:NextNumber(0.05, 0.95), -8, rng:NextNumber(0.05, 0.95), -8),
			xalign = Enum.TextXAlignment.Center, z = parent.ZIndex + 5,
		})
		local phase = rng:NextNumber(0, 6.28)
		local speed = rng:NextNumber(1.2, 2.6)
		UI.animate(function(t)
			if not s.Parent then return error("dead") end
			s.TextTransparency = 0.25 + 0.75 * math.abs(math.sin(t * speed + phase))
			s.Rotation = (t * 20 + phase * 40) % 360
		end)
	end
end

-- Global drag manager (sliders + window drag): one pair of connections for everything.
UserInputService.InputChanged:Connect(function(input)
	if UI.dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
		local m = UserInputService:GetMouseLocation()
		UI.dragging.update(m.X, m.Y)
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if UI.dragging and UI.dragging.finish then UI.dragging.finish() end
		UI.dragging = nil
	end
end)

----------------------------------------------------------------------------
-- 7. TOASTS
----------------------------------------------------------------------------
Toast = { gui = nil, holder = nil, items = {} }

function Toast.init()
	Toast.gui = new("ScreenGui", {
		Name = "ICS2K_Toast", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 400, Parent = playerGui,
	})
	Toast.holder = new("Frame", {
		Size = UDim2.new(0, 420, 0, 200), Position = UDim2.new(0.5, -210, 0, 14),
		BackgroundTransparency = 1, Parent = Toast.gui,
	})
	UI.list(Toast.holder, 6, false, Enum.HorizontalAlignment.Center)
	Toast.holder.UIListLayout.VerticalAlignment = Enum.VerticalAlignment.Top
end

function Toast.show(msg, kind, duration)
	if not Toast.holder then return end
	if not S.general.toasts and kind ~= "error" then return end
	duration = duration or 2.4
	local color = T.cyan
	if kind == "ok" then color = T.lime elseif kind == "error" then color = T.danger elseif kind == "mode" then color = T.magenta end
	local pillF = new("Frame", {
		Size = UDim2.new(0, 0, 0, 34), AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = T.panel, BackgroundTransparency = 0.12, BorderSizePixel = 0,
		LayoutOrder = math.floor(os.clock() * 1000), Parent = Toast.holder,
	})
	UI.pill(pillF)
	local st = UI.stroke(pillF, 1.5, color, 0)
	UI.padding(pillF, 0, 14, 14, 0, 0)
	local dot = new("Frame", {
		Size = UDim2.new(0, 8, 0, 8), Position = UDim2.new(0, 0, 0.5, -4),
		BackgroundColor3 = color, BorderSizePixel = 0, Parent = pillF,
	})
	UI.pill(dot)
	local lbl = UI.text(pillF, msg, {
		font = T.font.body, size = 14, color = T.text, frameSize = UDim2.new(0, 0, 1, 0),
		pos = UDim2.new(0, 16, 0, 0), xalign = Enum.TextXAlignment.Left,
	})
	lbl.AutomaticSize = Enum.AutomaticSize.X
	local scale = new("UIScale", { Scale = 0.7, Parent = pillF })
	tween(scale, { Scale = 1 }, 0.25, Enum.EasingStyle.Back)
	Sound.play("ping", 0.12)
	task.delay(duration, function()
		if pillF.Parent then
			tween(scale, { Scale = 0.6 }, 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			tween(pillF, { BackgroundTransparency = 1 }, 0.18)
			tween(st, { Transparency = 1 }, 0.18)
			tween(lbl, { TextTransparency = 1 }, 0.18)
			tween(dot, { BackgroundTransparency = 1 }, 0.18)
			task.delay(0.2, function() pillF:Destroy() end)
		end
	end)
	-- keep max 4 on screen
	local kids = Toast.holder:GetChildren()
	local frames = {}
	for _, k in ipairs(kids) do if k:IsA("Frame") then table.insert(frames, k) end end
	if #frames > 4 then
		table.sort(frames, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
		frames[1]:Destroy()
	end
end

----------------------------------------------------------------------------
-- 8. FILTER STACK  (color grade, bloom, DOF autofocus, grain, letterbox,
--    vignette, scanlines, glitches, screen flashes, paparazzi flash FX)
----------------------------------------------------------------------------
Filter = {
	gui = nil, cur = {}, focus = 12, focusTarget = 12, glitchT = 0, grainClock = 0,
	flashPool = {}, flashClock = 0, listeners = {}, tints = {
		NONE = Color3.fromRGB(255, 255, 255),
		WARM = Color3.fromRGB(255, 236, 214),
		COOL = Color3.fromRGB(214, 232, 255),
		ROSE = Color3.fromRGB(255, 224, 236),
		MINT = Color3.fromRGB(220, 255, 238),
		TEAL = Color3.fromRGB(205, 238, 240),
	},
	presets = {
		OFF = { grain = 0, vignette = 0, letterbox = 0, scanlines = 0, bloom = 0, bloomSize = 24, contrast = 0, saturation = 0, brightness = 0, blur = 0, dof = 0, dofRadius = 6, tint = "NONE" },
		KODAK = { grain = 0.35, vignette = 0.4, letterbox = 0.7, scanlines = 0, bloom = 0.2, bloomSize = 28, contrast = 0.12, saturation = -0.08, brightness = 0, blur = 0, dof = 0.4, dofRadius = 8, tint = "WARM" },
		TEAL = { grain = 0.25, vignette = 0.35, letterbox = 0.7, scanlines = 0, bloom = 0.25, bloomSize = 30, contrast = 0.18, saturation = -0.05, brightness = 0, blur = 0, dof = 0.3, dofRadius = 8, tint = "TEAL" },
		NOIR = { grain = 0.5, vignette = 0.7, letterbox = 0.7, scanlines = 0, bloom = 0.1, bloomSize = 24, contrast = 0.3, saturation = -1, brightness = -0.04, blur = 0, dof = 0.35, dofRadius = 6, tint = "NONE" },
		VHS = { grain = 0.6, vignette = 0.45, letterbox = 0, scanlines = 0.4, bloom = 0.15, bloomSize = 20, contrast = -0.05, saturation = -0.25, brightness = 0.02, blur = 0.25, dof = 0, dofRadius = 6, tint = "ROSE" },
		DREAM = { grain = 0.15, vignette = 0.3, letterbox = 0, scanlines = 0, bloom = 0.9, bloomSize = 56, contrast = -0.02, saturation = 0.1, brightness = 0.03, blur = 0.12, dof = 0.5, dofRadius = 10, tint = "ROSE" },
		Y2K = { grain = 0.2, vignette = 0.2, letterbox = 0, scanlines = 0.15, bloom = 0.5, bloomSize = 24, contrast = 0.2, saturation = 0.25, brightness = 0, blur = 0, dof = 0.2, dofRadius = 8, tint = "COOL" },
		CCTV = { grain = 0.7, vignette = 0.5, letterbox = 0, scanlines = 0.5, bloom = 0, bloomSize = 24, contrast = 0.1, saturation = -0.6, brightness = -0.02, blur = 0.08, dof = 0, dofRadius = 6, tint = "MINT" },
		BODYCAM = { grain = 0.45, vignette = 0.35, letterbox = 0, scanlines = 0, bloom = 0.1, bloomSize = 24, contrast = 0.1, saturation = -0.35, brightness = 0, blur = 0, dof = 0, dofRadius = 6, tint = "COOL" },
		PORTRAIT = { grain = 0.08, vignette = 0.15, letterbox = 0, scanlines = 0, bloom = 0.15, bloomSize = 24, contrast = 0.06, saturation = 0.08, brightness = 0.02, blur = 0, dof = 0.8, dofRadius = 3, tint = "WARM" },
	},
	presetOrder = { "OFF", "KODAK", "TEAL", "NOIR", "VHS", "DREAM", "Y2K", "CCTV", "BODYCAM", "PORTRAIT" },
}

-- Try to synthesize a real white-noise grain texture at runtime. Falls back to a built-in texture.
local function makeNoiseContent(size, mode)
	local ok, result = pcall(function()
		local AssetService = game:GetService("AssetService")
		local img = AssetService:CreateEditableImage({ Size = Vector2.new(size, size) })
		local buf = buffer.create(size * size * 4)
		for i = 0, size * size - 1 do
			local v, a = 0, 0
			if mode == "scan" then
				local y = math.floor(i / size)
				if y % 4 < 2 then v, a = 0, 150 end
			else
				local r = rng:NextNumber()
				if r < 0.10 then v, a = 255, rng:NextInteger(70, 170)
				elseif r < 0.20 then v, a = 0, rng:NextInteger(70, 160) end
			end
			local o = i * 4
			buffer.writeu8(buf, o, v)
			buffer.writeu8(buf, o + 1, v)
			buffer.writeu8(buf, o + 2, v)
			buffer.writeu8(buf, o + 3, a)
		end
		img:WritePixelsBuffer(Vector2.zero, Vector2.new(size, size), buf)
		return Content.fromObject(img)
	end)
	if ok then return result end
	return nil
end

function Filter.init()
	Filter.gui = new("ScreenGui", {
		Name = "ICS2K_Filter", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 300, Parent = playerGui,
	})
	local g = Filter.gui

	-- grain: two oversized tiled layers, jittered independently
	Filter.grain = {}
	local noise = makeNoiseContent(256, "grain")
	for i = 1, 2 do
		local lbl = new("ImageLabel", {
			Name = "Grain" .. i,
			Size = UDim2.new(2.2, 0, 2.2, 0), Position = UDim2.new(0.5, 0, 0.5, 0), AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundTransparency = 1, ImageTransparency = 1, ScaleType = Enum.ScaleType.Tile,
			TileSize = UDim2.new(0, i == 1 and 256 or 192, 0, i == 1 and 256 or 192),
			ZIndex = 5, Parent = g,
		})
		if noise then
			lbl.ImageContent = noise
			Filter.realNoise = true
		else
			lbl.Image = CFG.grainTextureFallback
			lbl.ImageColor3 = i == 1 and T.white or T.black
			lbl.TileSize = UDim2.new(0, i == 1 and 140 or 90, 0, i == 1 and 140 or 90)
		end
		Filter.grain[i] = lbl
	end

	-- scanlines
	Filter.scan = new("ImageLabel", {
		Name = "Scanlines", Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, ImageTransparency = 1,
		ScaleType = Enum.ScaleType.Tile, TileSize = UDim2.new(0, 4, 0, 4), ZIndex = 6, Parent = g,
	})
	local scan = makeNoiseContent(4, "scan")
	if scan then
		Filter.scan.ImageContent = scan
	else
		Filter.scan.Visible = false
		Filter.scanFallback = new("Frame", {
			Name = "ScanFallback", Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, ZIndex = 6, Parent = g,
		})
		Filter.scanLines = {}
	end

	-- vignette: four gradient edges
	Filter.vig = {}
	local edges = {
		{ UDim2.new(1, 0, 0.32, 0), UDim2.new(0, 0, 0, 0), 90 },
		{ UDim2.new(1, 0, 0.32, 0), UDim2.new(0, 0, 0.68, 0), 270 },
		{ UDim2.new(0.24, 0, 1, 0), UDim2.new(0, 0, 0, 0), 0 },
		{ UDim2.new(0.24, 0, 1, 0), UDim2.new(0.76, 0, 0, 0), 180 },
	}
	for i, e in ipairs(edges) do
		local f = new("Frame", {
			Name = "Vignette" .. i, Size = e[1], Position = e[2], BackgroundColor3 = T.black,
			BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 4, Parent = g,
		})
		UI.gradient(f, ColorSequence.new(T.black, T.black), e[3],
			NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.55, 0.75), NumberSequenceKeypoint.new(1, 1) }))
		Filter.vig[i] = f
	end

	-- letterbox bars
	Filter.barTop = new("Frame", { Name = "BarTop", Size = UDim2.new(1, 0, 0, 0), BackgroundColor3 = T.black, BorderSizePixel = 0, ZIndex = 8, Parent = g })
	Filter.barBottom = new("Frame", { Name = "BarBottom", Size = UDim2.new(1, 0, 0, 0), Position = UDim2.new(0, 0, 1, 0), AnchorPoint = Vector2.new(0, 1), BackgroundColor3 = T.black, BorderSizePixel = 0, ZIndex = 8, Parent = g })

	-- full screen flash + black blink + glitch band
	Filter.flash = new("Frame", { Name = "Flash", Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = T.white, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 9, Parent = g })
	Filter.black = new("Frame", { Name = "Black", Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = T.black, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 9, Parent = g })
	Filter.band = new("Frame", { Name = "GlitchBand", Size = UDim2.new(1, 0, 0, 18), BackgroundColor3 = Color3.fromRGB(200, 220, 230), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 7, Parent = g })
	UI.gradient(Filter.band, ColorSequence.new(T.white, Color3.fromRGB(120, 140, 160)), 0)

	-- post effects live in Lighting with unique names (local instances, local effect)
	for _, old in ipairs(Lighting:GetChildren()) do
		if old.Name:sub(1, 6) == "ICS2K_" then old:Destroy() end
	end
	Filter.cc = new("ColorCorrectionEffect", { Name = "ICS2K_Color", Enabled = true, Parent = Lighting })
	Filter.bloom = new("BloomEffect", { Name = "ICS2K_Bloom", Intensity = 0, Size = 24, Threshold = 0.85, Enabled = true, Parent = Lighting })
	Filter.dof = new("DepthOfFieldEffect", { Name = "ICS2K_DOF", FarIntensity = 0, NearIntensity = 0, FocusDistance = 12, InFocusRadius = 6, Enabled = true, Parent = Lighting })
	Filter.blur = new("BlurEffect", { Name = "ICS2K_Blur", Size = 0, Enabled = true, Parent = Lighting })

	for k, v in pairs(Filter.presets.OFF) do
		if type(v) == "number" then Filter.cur[k] = v end
	end
	Filter.cur.tint = T.white

	-- local folder for flash lights / markers
	Filter.folder = Workspace:FindFirstChild("ICS2K_Local") or new("Folder", { Name = "ICS2K_Local", Parent = Workspace })
	Ray.dirty = true
end

local FILTER_KEYS = { "grain", "vignette", "letterbox", "scanlines", "bloom", "bloomSize", "contrast", "saturation", "brightness", "blur", "dof", "dofRadius", "tint" }

function Filter.applyPreset(name, silent)
	local p = Filter.presets[name]
	if name == "CUSTOM" then p = Filter.custom end
	if not p then return end
	for _, k in ipairs(FILTER_KEYS) do if p[k] ~= nil then S.filter[k] = p[k] end end
	S.filter.preset = name
	for _, fn in ipairs(Filter.listeners) do pcall(fn) end
	if not silent then Toast.show("filter ✦ " .. name, "info", 1.6) end
end

-- The user picked a look in the FILTER tab: remember it so modes without an opinion return to it.
function Filter.userPick(name)
	S.filter.userPreset = name
	Filter.applyPreset(name)
end

-- The user dragged a filter slider: the look is now CUSTOM; keep a snapshot so it survives mode changes.
function Filter.snapshotCustom()
	Filter.custom = Filter.custom or {}
	for _, k in ipairs(FILTER_KEYS) do Filter.custom[k] = S.filter[k] end
	S.filter.preset = "CUSTOM"
	S.filter.userPreset = "CUSTOM"
end

-- Modes ask for their look (nil = no opinion, falls back to the user's pick). Lock ignores all of it.
function Filter.requestPreset(name)
	if S.filter.lock then return end
	if type(name) == "function" then name = name() end
	name = name or S.filter.userPreset or "OFF"
	if name ~= S.filter.preset then Filter.applyPreset(name, true) end
end

function Filter.setFocus(distance) if distance then Filter.focusTarget = clamp(distance, 0.5, 500) end end
function Filter.glitch(duration) Filter.glitchT = math.max(Filter.glitchT, duration or 0.2) end
function Filter.screenFlash(strength, duration)
	Filter.flash.BackgroundTransparency = 1 - (strength or 0.9)
	tween(Filter.flash, { BackgroundTransparency = 1 }, duration or 0.35)
end
function Filter.blackBlink(duration)
	Filter.black.BackgroundTransparency = 0
	task.delay(duration or 0.08, function() Filter.black.BackgroundTransparency = 1 end)
end

local function ensureScanFallback(count)
	if not Filter.scanLines then return end
	while #Filter.scanLines < count do
		local i = #Filter.scanLines + 1
		Filter.scanLines[i] = new("Frame", {
			Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 0, (i - 1) * 5), BackgroundColor3 = T.black,
			BorderSizePixel = 0, BackgroundTransparency = 1, Parent = Filter.scanFallback,
		})
	end
end

-- Paparazzi flashbulbs: a ring of camera flashes popping around the subject.
function Filter.flashbulbs(dt, subjectPos)
	if not S.general.paparazziFlashes or not subjectPos then return end
	Filter.flashClock = Filter.flashClock - dt
	if Filter.flashClock > 0 then return end
	Filter.flashClock = rng:NextNumber(0.12, 0.55)
	local ang = rng:NextNumber(0, math.pi * 2)
	local r = rng:NextNumber(7, 16)
	local pos = subjectPos + Vector3.new(math.cos(ang) * r, rng:NextNumber(0.5, 6), math.sin(ang) * r)
	local bulb = new("Part", {
		Name = "Flashbulb", Shape = Enum.PartType.Ball, Size = Vector3.new(0.35, 0.35, 0.35), Material = Enum.Material.Neon,
		Color = T.white, Anchored = true, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false,
		CFrame = CFrame.new(pos), Parent = Filter.folder,
	})
	new("PointLight", { Brightness = 8, Range = 28, Color = Color3.fromRGB(235, 240, 255), Shadows = false, Parent = bulb })
	task.delay(rng:NextNumber(0.05, 0.1), function() bulb:Destroy() end)
end

function Filter.tick(dt, t)
	local f = S.filter
	local cur = Filter.cur
	local k = Util.expAlpha(7, dt)
	for _, key in ipairs({ "grain", "vignette", "letterbox", "scanlines", "bloom", "bloomSize", "contrast", "saturation", "brightness", "blur", "dof", "dofRadius" }) do
		cur[key] = cur[key] + ((f[key] or 0) - cur[key]) * k
	end
	cur.tint = cur.tint:Lerp(Filter.tints[f.tint] or T.white, k)

	-- glitch envelope (CCTV / VHS flavour)
	local glitch = 0
	if Filter.glitchT > 0 then
		Filter.glitchT = Filter.glitchT - dt
		glitch = 1
		Filter.band.BackgroundTransparency = 0.6
		Filter.band.Position = UDim2.new(0, 0, rng:NextNumber(0, 0.95), 0)
	else
		Filter.band.BackgroundTransparency = 1
	end

	-- post effects
	Filter.cc.Contrast = cur.contrast
	Filter.cc.Saturation = cur.saturation - glitch * 0.3
	Filter.cc.Brightness = cur.brightness - glitch * 0.2
	Filter.cc.TintColor = cur.tint
	Filter.bloom.Intensity = cur.bloom
	Filter.bloom.Size = cur.bloomSize
	Filter.blur.Size = cur.blur * 12 + glitch * 3
	Filter.blur.Enabled = Filter.blur.Size > 0.05
	Filter.focus = Util.smooth(Filter.focus, Filter.focusTarget, 6, dt)
	Filter.dof.FocusDistance = Filter.focus
	Filter.dof.InFocusRadius = cur.dofRadius
	Filter.dof.FarIntensity = cur.dof
	Filter.dof.NearIntensity = cur.dof * 0.6
	Filter.dof.Enabled = cur.dof > 0.01

	-- grain: 24 Hz jitter so it flickers like real stock
	local grainAmount = clamp(cur.grain + glitch * 0.5, 0, 1)
	Filter.grainClock = Filter.grainClock + dt
	if Filter.grainClock >= 1 / 24 then
		Filter.grainClock = 0
		for i, lbl in ipairs(Filter.grain) do
			lbl.ImageTransparency = 1 - grainAmount * (Filter.realNoise and 0.95 or 0.22) * (i == 1 and 1 or 0.7)
			if grainAmount > 0.01 then
				lbl.Position = UDim2.new(0.5, rng:NextInteger(-128, 128), 0.5, rng:NextInteger(-128, 128))
				lbl.Rotation = rng:NextInteger(0, 3) * 90
			end
		end
	end

	-- scanlines
	local scanAmount = clamp(cur.scanlines + glitch * 0.3, 0, 1)
	if Filter.scanLines then
		local count = scanAmount > 0.01 and math.floor(camera.ViewportSize.Y / 5) or 0
		ensureScanFallback(math.min(count, 260))
		for i, line in ipairs(Filter.scanLines) do
			line.BackgroundTransparency = (i <= count) and (1 - scanAmount * 0.5) or 1
		end
	else
		Filter.scan.ImageTransparency = 1 - scanAmount * 0.9
	end

	-- vignette
	for _, v in ipairs(Filter.vig) do v.BackgroundTransparency = 1 - cur.vignette * 0.95 end

	-- letterbox: aim for 2.39:1 inside whatever the viewport is
	local vp = camera.ViewportSize
	local aspect = vp.X / math.max(1, vp.Y)
	local frac = math.max(0, (1 - aspect / 2.39) / 2) * cur.letterbox
	if cur.letterbox < 0.01 then frac = 0 end
	Filter.barTop.Size = UDim2.new(1, 0, frac, 0)
	Filter.barBottom.Size = UDim2.new(1, 0, frac, 0)
end

----------------------------------------------------------------------------
-- 9. BODY  (controls, walk speed, head hiding) + ARM IK (phone hand)
----------------------------------------------------------------------------
Body = { baseWalkSpeed = 16, override = nil, controlsOn = true, controls = nil, hiddenParts = {}, autoRotateSaved = true }

do
	local ok, controls = pcall(function()
		local scripts = player:WaitForChild("PlayerScripts", 5)
		local module = scripts and scripts:WaitForChild("PlayerModule", 5)
		return require(module):GetControls()
	end)
	if ok and controls then Body.controls = controls end
end

function Body.rebind(newChar)
	Rig.char = newChar
	Rig.humanoid = newChar:WaitForChild("Humanoid")
	Rig.root = newChar:WaitForChild("HumanoidRootPart")
	Rig.head = newChar:FindFirstChild("Head") or newChar:WaitForChild("Head", 5)
	Body.hiddenParts = {}
	Body.baseWalkSpeed = Rig.humanoid.WalkSpeed > 0 and Rig.humanoid.WalkSpeed or 16
	Body.override = nil
	Body.autoRotateOverridden = false
	Body.controlsOn = true
	Ray.dirty = true
end

function Body.desiredWalkSpeed()
	local o = Body.override
	if o == nil then return nil end
	if o == "freeze" then return 0 end
	if o == "runway" then return CFG.runwayWalkSpeed end
	if type(o) == "number" then return Body.baseWalkSpeed * o end
	return nil
end

function Body.setWalk(mode)
	Body.override = mode
	local want = Body.desiredWalkSpeed()
	if want then Rig.humanoid.WalkSpeed = want
	else Rig.humanoid.WalkSpeed = Body.baseWalkSpeed end
end

function Body.setControls(enabled)
	if Body.controlsOn == enabled then return end
	Body.controlsOn = enabled
	if Body.controls then
		pcall(function()
			if enabled then Body.controls:Enable() else Body.controls:Disable() end
		end)
	end
end

function Body.setAutoRotate(enabled)
	local hum = Rig.humanoid
	if not Body.autoRotateOverridden then
		Body.autoRotateSaved = hum.AutoRotate
		Body.autoRotateOverridden = true
	end
	hum.AutoRotate = enabled
end

function Body.restoreAutoRotate()
	if Body.autoRotateOverridden then
		Rig.humanoid.AutoRotate = Body.autoRotateSaved
		Body.autoRotateOverridden = false
	end
end

function Body.tick()
	local hum = Rig.humanoid
	if not hum or not hum.Parent then return end
	local want = Body.desiredWalkSpeed()
	if want then
		if math.abs(hum.WalkSpeed - want) > 0.01 then
			-- an external script changed the speed while we own it: adopt it as the new base, re-apply
			if hum.WalkSpeed > 0 and hum.WalkSpeed ~= CFG.runwayWalkSpeed then Body.baseWalkSpeed = hum.WalkSpeed end
			hum.WalkSpeed = want
		end
	else
		if hum.WalkSpeed > 0 then Body.baseWalkSpeed = hum.WalkSpeed end
	end
end

function Body.release()
	Body.setWalk(nil)
	Body.setControls(true)
	Body.restoreAutoRotate()
	Body.hideHead(false)
end

function Body.hideHead(hide)
	local head = Rig.head
	if hide then
		if #Body.hiddenParts > 0 then return end
		local function hidePart(p)
			if p and p:IsA("BasePart") then
				p.LocalTransparencyModifier = 1
				table.insert(Body.hiddenParts, p)
			end
		end
		hidePart(head)
		local headAttachments = {}
		if head then
			for _, a in ipairs(head:GetChildren()) do
				if a:IsA("Attachment") then headAttachments[a.Name] = true end
			end
		end
		for _, acc in ipairs(Rig.char:GetChildren()) do
			if acc:IsA("Accessory") then
				local handle = acc:FindFirstChild("Handle")
				local weld = handle and handle:FindFirstChildWhichIsA("Weld")
				local onHead = weld and (weld.Part0 == head or weld.Part1 == head)
				if not onHead and handle then
					for _, a in ipairs(handle:GetChildren()) do
						if a:IsA("Attachment") and headAttachments[a.Name] then onHead = true end
					end
				end
				if onHead then hidePart(handle) end
			end
		end
	else
		for _, p in ipairs(Body.hiddenParts) do
			if p and p.Parent then p.LocalTransparencyModifier = 0 end
		end
		Body.hiddenParts = {}
	end
end

-- Two-bone arm IK driven through joint Transform (stepped after the animator, before physics).
-- Works with classic Motor6D rigs and with AnimationConstraint rigs (AvatarJointUpgrade):
-- both satisfy Part1.CFrame = Part0.CFrame * C0 * Transform * C1:Inverse().
local ArmIK = {}
ArmIK.__index = ArmIK

function ArmIK.new()
	return setmetatable({ weight = 0, targetWeight = 0, rig = nil, handCF = nil, elbowRoll = rad(-35), wasActive = false }, ArmIK)
end

local function findJoint(model, name)
	for _, d in ipairs(model:GetDescendants()) do
		if d.Name == name and (d:IsA("Motor6D") or d:IsA("AnimationConstraint")) then return d end
	end
	return nil
end

-- part0, part1, C0, C1 for either joint type
local function jointFrames(j)
	if j:IsA("Motor6D") then return j.Part0, j.Part1, j.C0, j.C1 end
	local a0, a1 = j.Attachment0, j.Attachment1
	if a0 and a1 then return a0.Parent, a1.Parent, a0.CFrame, a1.CFrame end
	return nil
end

local function solveTwoBone(originCF, targetPos, l1, l2)
	local localized = originCF:PointToObjectSpace(targetPos)
	local l3 = localized.Magnitude
	if l3 < 1e-4 then return originCF, -math.pi / 2, math.pi end
	local unit = localized / l3
	local axis = Vector3.new(0, 0, -1):Cross(unit)
	local planeCF
	if axis.Magnitude < 1e-5 then
		planeCF = unit.Z < 0 and originCF or originCF * CFrame.Angles(0, math.pi, 0)
	else
		planeCF = originCF * CFrame.fromAxisAngle(axis.Unit, math.acos(clamp(-unit.Z, -1, 1)))
	end
	if l3 < math.abs(l1 - l2) then
		return planeCF, -math.pi / 2, math.pi
	elseif l3 > l1 + l2 then
		return planeCF, math.pi / 2, 0
	end
	local a1 = -math.acos(clamp((-(l2 * l2) + l1 * l1 + l3 * l3) / (2 * l1 * l3), -1, 1))
	local a2 = math.acos(clamp((l2 * l2 - l1 * l1 + l3 * l3) / (2 * l2 * l3), -1, 1))
	return planeCF, a1 + math.pi / 2, a2 - a1
end

function ArmIK:bindTo(c, hum)
	self.rig = nil
	hum = hum or (c and c:FindFirstChildOfClass("Humanoid"))
	if not c or not hum then return false end
	if hum.RigType == Enum.HumanoidRigType.R15 then
		local torso = c:FindFirstChild("UpperTorso")
		local hand = c:FindFirstChild("RightHand")
		local shoulder = findJoint(c, "RightShoulder")
		local elbow = findJoint(c, "RightElbow")
		local wrist = findJoint(c, "RightWrist")
		if torso and hand and shoulder and elbow and wrist then
			local _, _, sC0, sC1 = jointFrames(shoulder)
			local _, _, eC0, eC1 = jointFrames(elbow)
			local _, _, wC0 = jointFrames(wrist)
			if sC0 and eC0 and wC0 then
				self.rig = "R15"
				self.torso, self.shoulder, self.elbow, self.wrist, self.hand = torso, shoulder, elbow, wrist, hand
				self.l1 = (eC0.Position - sC1.Position).Magnitude
				self.l2 = (wC0.Position - eC1.Position).Magnitude
				self.reach = self.l1 + self.l2
			end
		end
	else
		local torso = c:FindFirstChild("Torso")
		local arm = c:FindFirstChild("Right Arm")
		local shoulder = findJoint(c, "Right Shoulder")
		if torso and arm and shoulder and jointFrames(shoulder) then
			self.rig = "R6"
			self.torso, self.shoulder, self.hand = torso, shoulder, arm
			self.reach = 2.0
		end
	end
	return self.rig ~= nil
end

function ArmIK:shoulderPosition(fallback)
	if not self.rig then return fallback end
	local _, _, c0 = jointFrames(self.shoulder)
	return (self.torso.CFrame * c0).Position
end

-- Leave the joints to the animator again (rigs without playing animations would otherwise keep our pose).
function ArmIK:releaseJoints()
	if not self.rig then return end
	for _, j in ipairs({ self.shoulder, self.elbow, self.wrist }) do
		if j and j.Parent then j.Transform = CFrame.identity end
	end
end

-- handCF: desired world CFrame for the hand (R15) / arm end (R6).
function ArmIK:stepJoints()
	if not self.rig or not self.handCF then return end
	local w = self.weight
	if w <= 0.001 then return end
	if not self.torso.Parent then return end
	local torsoCF = self.torso.CFrame
	if self.rig == "R15" then
		local shoulder, elbow, wrist = self.shoulder, self.elbow, self.wrist
		local _, _, sC0, sC1 = jointFrames(shoulder)
		local _, _, eC0, eC1 = jointFrames(elbow)
		local _, _, wC0, wC1 = jointFrames(wrist)
		if not (sC0 and eC0 and wC0) then return end
		local wristTarget = self.handCF:PointToWorldSpace(wC1.Position)
		local originCF = torsoCF * sC0
		local planeCF, a1, a2 = solveTwoBone(originCF, wristTarget, self.l1, self.l2)
		planeCF = planeCF * CFrame.Angles(0, 0, self.elbowRoll)
		local desiredC0 = torsoCF:ToObjectSpace(planeCF) * CFrame.Angles(a1, 0, 0)
		local shoulderT = sC0:Inverse() * desiredC0
		local elbowT = CFrame.Angles(a2, 0, 0)
		shoulder.Transform = shoulder.Transform:Lerp(shoulderT, w)
		elbow.Transform = elbow.Transform:Lerp(elbowT, w)
		local upperCF = torsoCF * sC0 * shoulder.Transform * sC1:Inverse()
		local lowerCF = upperCF * eC0 * elbow.Transform * eC1:Inverse()
		local wristT = (lowerCF * wC0):Inverse() * self.handCF * wC1
		wrist.Transform = wrist.Transform:Lerp(wristT, w)
	else
		local shoulder = self.shoulder
		local _, _, sC0, sC1 = jointFrames(shoulder)
		if not sC0 then return end
		local jointCF = torsoCF * sC0
		local jointPos = jointCF.Position
		local toTarget = self.handCF.Position - jointPos
		if toTarget.Magnitude < 0.05 then return end
		local aim = CFrame.lookAt(jointPos, self.handCF.Position)
		local aimRot = (aim * CFrame.Angles(math.pi / 2, 0, 0)).Rotation
		-- roll about the arm axis so the arm's front matches the hand's front as well as it can
		local wantFront = self.handCF.LookVector
		local localFront = aimRot:VectorToObjectSpace(wantFront)
		local roll = math.atan2(-localFront.X, -localFront.Z)
		local armRot = aimRot * CFrame.Angles(0, roll, 0)
		local J = CFrame.new(jointPos) * armRot * sC1.Rotation
		local shoulderT = jointCF:Inverse() * J
		shoulder.Transform = shoulder.Transform:Lerp(shoulderT, w)
	end
end

function ArmIK:tickWeight(dt)
	self.weight = Util.smooth(self.weight, self.targetWeight, 6, dt)
	if self.weight < 0.002 then
		self.weight = 0
		if self.wasActive then
			self.wasActive = false
			pcall(self.releaseJoints, self)
		end
	else
		self.wasActive = true
	end
end

-- The local player's arm. Dot-style wrappers keep the call sites short.
local IK = ArmIK.new()
function IK.bind() return IK:bindTo(Rig.char, Rig.humanoid) end
function IK.step() IK:stepJoints() end
function IK.tick(dt) IK:tickWeight(dt) end
function IK.release() IK:releaseJoints() end
function IK.shoulderPos() return IK:shoulderPosition(Rig.root.Position) end

----------------------------------------------------------------------------
-- 10. CAPTURE + GALLERY
----------------------------------------------------------------------------
Gallery = { items = {}, listeners = {}, modal = nil, busy = false }

local CaptureService = nil
pcall(function() CaptureService = game:GetService("CaptureService") end)

function Gallery.notify()
	for _, fn in ipairs(Gallery.listeners) do pcall(fn) end
end

function Gallery.add(contentId, label)
	local item = { id = contentId, frames = { contentId }, label = label or "CAPTURE", time = os.time(), clock = Util.clock24() }
	table.insert(Gallery.items, 1, item)
	Gallery.notify()
	return item
end

-- A clip is a burst of frames saved together (one save prompt for all of them).
function Gallery.addClip(ids, label)
	local item = { id = ids[1], frames = ids, clip = true, label = label or "CLIP", time = os.time(), clock = Util.clock24() }
	table.insert(Gallery.items, 1, item)
	Gallery.notify()
	return item
end

-- Hide the given ScreenGuis for the capture frame, grab the screen, restore.
function Gallery.capture(opts)
	opts = opts or {}
	if Gallery.busy then return end
	if not CaptureService then
		Toast.show("capture service unavailable here", "error")
		if opts.onDone then opts.onDone(nil) end
		return
	end
	Gallery.busy = true
	task.spawn(function()
		local restore = {}
		for _, gui in ipairs(opts.hide or {}) do
			if gui and gui.Enabled then
				gui.Enabled = false
				table.insert(restore, gui)
			end
		end
		RunService.RenderStepped:Wait()
		RunService.RenderStepped:Wait()
		local ok, err = pcall(function()
			CaptureService:CaptureScreenshot(function(contentId)
				if opts.raw then
					if opts.onDone then opts.onDone(contentId) end
					return
				end
				local item = Gallery.add(contentId, opts.label)
				if opts.onDone then opts.onDone(item) end
			end)
		end)
		RunService.RenderStepped:Wait()
		RunService.RenderStepped:Wait()
		for _, gui in ipairs(restore) do gui.Enabled = true end
		Gallery.busy = false
		if not ok then
			Toast.show("capture failed: " .. tostring(err), "error", 3)
			if opts.onDone then opts.onDone(nil) end
		end
	end)
end

function Gallery.remove(item)
	for i, it in ipairs(Gallery.items) do
		if it == item then table.remove(Gallery.items, i) break end
	end
	pcall(function()
		if CaptureService then
			for _, id in ipairs(item.frames or { item.id }) do CaptureService:DeleteCapture(id) end
		end
	end)
	Gallery.notify()
end

function Gallery.save(items)
	if not CaptureService then Toast.show("saving needs the live Roblox client", "error") return end
	local ids = {}
	for _, it in ipairs(items) do
		for _, id in ipairs(it.frames or { it.id }) do table.insert(ids, id) end
	end
	if #ids == 0 then return end
	local ok, err = pcall(function()
		CaptureService:PromptSaveCapturesToGallery(ids, function(results)
			local n = 0
			if type(results) == "table" then
				for _, saved in pairs(results) do if saved then n = n + 1 end end
			end
			Toast.show(n > 0 and ("saved " .. n .. " photo" .. (n > 1 and "s" or "") .. " to your device ✦") or "save cancelled", n > 0 and "ok" or "info")
		end)
	end)
	if not ok then Toast.show("save failed: " .. tostring(err), "error", 3) end
end

function Gallery.share(item)
	if not CaptureService then Toast.show("sharing needs the live Roblox client", "error") return end
	-- newer clients type the first argument as Content; older ones take the id string
	local arg = item.id
	pcall(function() arg = Content.fromUri(item.id) end)
	local ok = pcall(function()
		CaptureService:PromptShareCapture(arg, "ICS2K", function() Toast.show("shared ✦", "ok") end, function() end)
	end)
	if not ok and arg ~= item.id then
		pcall(function()
			CaptureService:PromptShareCapture(item.id, "ICS2K", function() Toast.show("shared ✦", "ok") end, function() end)
		end)
	end
end

function Gallery.init()
	local gui = new("ScreenGui", {
		Name = "ICS2K_Modal", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 500, Enabled = false, Parent = playerGui,
	})
	Gallery.modalGui = gui
	local backdrop = new("TextButton", {
		Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = T.black, BackgroundTransparency = 0.35, Text = "",
		AutoButtonColor = false, BorderSizePixel = 0, Parent = gui,
	})
	local card = new("Frame", {
		Size = UDim2.new(0, 640, 0, 520), Position = UDim2.new(0.5, 0, 0.5, 0), AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = T.panel, BorderSizePixel = 0, Parent = gui,
	})
	UI.corner(card, 18)
	UI.gradient(card, T.glass, 90)
	UI.iridescent(UI.stroke(card, 2, T.white, 0), 35, 0)
	local img = new("ImageLabel", {
		Size = UDim2.new(1, -24, 1, -92), Position = UDim2.new(0, 12, 0, 12), BackgroundColor3 = T.black,
		BackgroundTransparency = 0.3, BorderSizePixel = 0, ScaleType = Enum.ScaleType.Fit, Parent = card,
	})
	UI.corner(img, 12)
	local caption = UI.text(card, "", {
		font = T.font.head, size = 10, color = T.lavender, frameSize = UDim2.new(0.5, -12, 0, 20),
		pos = UDim2.new(0, 14, 1, -72),
	})
	local row = new("Frame", { Size = UDim2.new(1, -24, 0, 36), Position = UDim2.new(0, 12, 1, -48), BackgroundTransparency = 1, Parent = card })
	UI.list(row, 8, true, Enum.HorizontalAlignment.Right)
	local current
	local frameIdx = 1
	local function close() gui.Enabled = false end
	-- clip navigation
	local nav = new("Frame", { Size = UDim2.new(0, 170, 0, 26), Position = UDim2.new(0.5, -85, 1, -78), BackgroundTransparency = 1, Visible = false, Parent = card })
	UI.list(nav, 6, true, Enum.HorizontalAlignment.Center)
	local frameLbl
	local function showFrame()
		if not current then return end
		local frames = current.frames or { current.id }
		frameIdx = ((frameIdx - 1) % #frames) + 1
		img.Image = frames[frameIdx]
		nav.Visible = #frames > 1
		if frameLbl then frameLbl.Text = string.format("%d / %d", frameIdx, #frames) end
	end
	UI.button(nav, { text = "‹", kind = "dark", size = UDim2.new(0, 34, 0, 26), order = 1, textSize = 14, onClick = function() frameIdx = frameIdx - 1 showFrame() end })
	frameLbl = UI.text(nav, "", { font = T.font.mono, size = 12, color = T.text, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(0, 70, 0, 26), order = 2 })
	UI.button(nav, { text = "›", kind = "dark", size = UDim2.new(0, 34, 0, 26), order = 3, textSize = 14, onClick = function() frameIdx = frameIdx + 1 showFrame() end })
	UI.button(row, { text = "CLOSE", kind = "ghost", size = UDim2.new(0, 90, 0, 32), order = 4, onClick = close })
	UI.button(row, { text = "DELETE", kind = "danger", size = UDim2.new(0, 96, 0, 32), order = 3, onClick = function()
		if current then Gallery.remove(current) Toast.show("photo deleted", "info") end
		close()
	end })
	UI.button(row, { text = "SHARE", kind = "chrome", size = UDim2.new(0, 90, 0, 32), order = 2, onClick = function()
		if current then Gallery.share(current) end
	end })
	UI.button(row, { text = "SAVE TO DEVICE", kind = "primary", size = UDim2.new(0, 150, 0, 32), order = 1, onClick = function()
		if current then Gallery.save({ current }) end
	end })
	backdrop.MouseButton1Click:Connect(close)
	function Gallery.open(item)
		current = item
		frameIdx = 1
		local n = item.frames and #item.frames or 1
		caption.Text = item.label .. "  ✦  " .. item.clock .. (n > 1 and ("  ✦  " .. n .. " FRAMES") or "")
		showFrame()
		gui.Enabled = true
	end
	function Gallery.isOpen() return gui.Enabled end
	function Gallery.close() close() end
end

----------------------------------------------------------------------------
-- 10b. NET  (optional replication through ICS2K_Server.lua; silently off without it)
----------------------------------------------------------------------------
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = { folder = nil, rig = nil, pose = nil, available = false, lastPose = 0, onPose = nil }

function Net.init()
	task.spawn(function()
		local folder = ReplicatedStorage:FindFirstChild("ICS2K") or ReplicatedStorage:WaitForChild("ICS2K", 6)
		if not folder then return end
		Net.folder = folder
		Net.rig = folder:FindFirstChild("Rig")
		Net.pose = folder:FindFirstChild("Pose")
		Net.available = Net.rig ~= nil and Net.pose ~= nil
		if Net.pose then
			Net.pose.OnClientEvent:Connect(function(...)
				if Net.onPose then pcall(Net.onPose, ...) end
			end)
		end
	end)
end

function Net.sendRig(action, data)
	if not Net.rig then return end
	pcall(function() Net.rig:FireServer(action, data) end)
end

-- 20 Hz phone pose stream for PAPARAZZI (so others see the raised phone). force = send now.
function Net.sendPose(rel, weight, torch, now, force)
	if not Net.pose then return end
	if not force and now - Net.lastPose < 1 / 20 then return end
	Net.lastPose = now
	pcall(function() Net.pose:FireServer(rel, weight, torch) end)
end

----------------------------------------------------------------------------
-- 11. MODE FRAMEWORK
----------------------------------------------------------------------------
Modes = { byId = {}, order = {} }

local function defineMode(def)
	Modes.byId[def.id] = def
	table.insert(Modes.order, def.id)
	return def
end

local function currentMode() return Modes.byId[STATE.modeId] end

-- Markers folder in workspace (local only) for bookmarks / rail / flashbulbs
local function localFolder()
	local f = Workspace:FindFirstChild("ICS2K_Local")
	if not f then
		f = new("Folder", { Name = "ICS2K_Local", Parent = Workspace })
		Ray.dirty = true
	end
	return f
end

local function makeMarker(pos, color, label)
	local part = new("Part", {
		Name = "Marker", Shape = Enum.PartType.Ball, Size = Vector3.new(0.3, 0.3, 0.3), Material = Enum.Material.Neon,
		Color = color, Anchored = true, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false,
		CFrame = CFrame.new(pos), Parent = localFolder(),
	})
	new("Attachment", { Name = "A", Parent = part })
	if label then
		local bb = new("BillboardGui", {
			Size = UDim2.new(0, 70, 0, 18), StudsOffset = Vector3.new(0, 0.5, 0), AlwaysOnTop = true, MaxDistance = 120, Parent = part,
		})
		UI.text(bb, label, { font = T.font.mono, size = 12, color = color, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 1, 0), stroke = 1 })
	end
	return part
end

-- Pose helpers shared by FREE / bookmarks / rail
local function poseFromCFrame(cf)
	local p, y, r = cf:ToEulerAnglesYXZ()
	return deg(y), deg(p), deg(r)
end

----------------------------------------------------------------------------
-- 12. BOOKMARKS + RAIL
----------------------------------------------------------------------------
Bookmarks = { list = {}, markers = {}, idx = 0, visible = false }

function Bookmarks.add(cf, fov, name)
	local entry = { cf = cf, fov = fov or CFG.baseFov, name = name or ("CAM " .. string.format("%02d", #Bookmarks.list + 1)) }
	table.insert(Bookmarks.list, entry)
	Bookmarks.rebuild()
	Bookmarks.notify()
	return entry
end
function Bookmarks.remove(i)
	table.remove(Bookmarks.list, i)
	for k, e in ipairs(Bookmarks.list) do e.name = "CAM " .. string.format("%02d", k) end
	Bookmarks.rebuild()
	Bookmarks.notify()
end
function Bookmarks.clear()
	Bookmarks.list = {}
	Bookmarks.rebuild()
	Bookmarks.notify()
end
Bookmarks.listeners = {}
function Bookmarks.notify() for _, fn in ipairs(Bookmarks.listeners) do pcall(fn) end end
function Bookmarks.rebuild()
	for _, m in ipairs(Bookmarks.markers) do m:Destroy() end
	Bookmarks.markers = {}
	if not Bookmarks.visible then return end
	for _, e in ipairs(Bookmarks.list) do
		local m = makeMarker(e.cf.Position, T.cyan, e.name)
		-- a little "lens" line showing where the cam looks
		local a0 = m:FindFirstChild("A")
		local tip = new("Attachment", { Position = Vector3.new(0, 0, -1.5), Parent = m })
		m.CFrame = e.cf
		new("Beam", { Attachment0 = a0, Attachment1 = tip, Width0 = 0.06, Width1 = 0.01, Color = ColorSequence.new(T.cyan), LightEmission = 1, FaceCamera = true, Parent = m })
		table.insert(Bookmarks.markers, m)
	end
end
function Bookmarks.show(v)
	Bookmarks.visible = v
	Bookmarks.rebuild()
end

Rail = { keys = {}, markers = {}, playing = false, t = 0, listeners = {} }

function Rail.notify() for _, fn in ipairs(Rail.listeners) do pcall(fn) end end
function Rail.add(cf, fov)
	table.insert(Rail.keys, { cf = cf, fov = fov or CFG.baseFov })
	Rail.rebuild()
	Rail.notify()
end
function Rail.clear()
	Rail.keys = {}
	Rail.stop()
	Rail.rebuild()
	Rail.notify()
end
function Rail.rebuild()
	for _, m in ipairs(Rail.markers) do m:Destroy() end
	Rail.markers = {}
	if not S.free.showRail or not Bookmarks.visible then return end
	local prev
	for i, k in ipairs(Rail.keys) do
		local m = makeMarker(k.cf.Position, T.lavender, "K" .. i)
		m.Size = Vector3.new(0.22, 0.22, 0.22)
		if prev then
			new("Beam", {
				Attachment0 = prev:FindFirstChild("A"), Attachment1 = m:FindFirstChild("A"),
				Width0 = 0.05, Width1 = 0.05, Color = ColorSequence.new(T.lavender, T.magenta), LightEmission = 1,
				FaceCamera = true, Transparency = NumberSequence.new(0.2), Parent = m,
			})
		end
		prev = m
		table.insert(Rail.markers, m)
	end
end

-- u in [0, n-1]; returns CFrame, fov
function Rail.sample(u)
	local keys = Rail.keys
	local n = #keys
	if n == 0 then return camera.CFrame, CFG.baseFov end
	if n == 1 then return keys[1].cf, keys[1].fov end
	local loop = S.free.railLoop
	local segCount = loop and n or (n - 1)
	u = clamp(u, 0, segCount)
	local i = math.min(math.floor(u), segCount - 1)
	local f = u - i
	local function K(idx)
		if loop then idx = ((idx - 1) % n) + 1 else idx = clamp(idx, 1, n) end
		return keys[idx]
	end
	local k0, k1, k2, k3 = K(i), K(i + 1), K(i + 2), K(i + 3)
	local pos = Util.catmullRom(k0.cf.Position, k1.cf.Position, k2.cf.Position, k3.cf.Position, f)
	local rot = k1.cf.Rotation:Lerp(k2.cf.Rotation, Util.smoothstep(f))
	local fov = Util.lerp(k1.fov, k2.fov, Util.smoothstep(f))
	return CFrame.new(pos) * rot, fov
end

function Rail.play()
	if #Rail.keys < 2 then Toast.show("rail needs 2+ keyframes (K)", "error") return end
	Rail.playing = true
	Rail.t = 0
	local loop = S.free.railLoop
	local segCount = loop and #Rail.keys or (#Rail.keys - 1)
	local total = segCount * math.max(0.3, S.free.railSegmentTime)
	Cam.override = function(dt)
		Rail.t = Rail.t + dt
		local p = Rail.t / total
		if loop then
			p = p % 1
		elseif p >= 1 then
			local cf, fov = Rail.sample(segCount)
			Cam.cf, Cam.fov = cf, fov
			Rail.stop()
			return
		else
			p = Util.easeInOutCubic(p)
		end
		local cf, fov = Rail.sample(p * segCount)
		Cam.cf, Cam.fov = cf, fov
	end
	Toast.show("rail ▶ " .. #Rail.keys .. " keys · " .. string.format("%.1fs", total), "ok")
end

function Rail.stop()
	if Rail.playing then
		Rail.playing = false
		Cam.override = nil
		local m = currentMode()
		if m and m.syncFromCamera then m.syncFromCamera() end
	end
end

----------------------------------------------------------------------------
-- 13. MODE: STANDARD
----------------------------------------------------------------------------
defineMode({
	id = "STANDARD", name = "STANDARD", icon = "◎", blurb = "the default roblox camera, untouched",
	scriptable = false, preset = nil, wantsMouseLock = "never",
	keys = { { "C", "next camera mode" }, { "I", "open the ICS2K window" } },
	enter = function() end,
	exit = function() end,
	update = function() end,
})

----------------------------------------------------------------------------
-- 14. MODE: FREE  (drone flight, 120x zoom, bookmarks, dolly rail)
----------------------------------------------------------------------------
local Free = {
	pos = Vector3.new(), vel = Vector3.new(), yaw = 0, pitch = 0, roll = 0, rollVel = 0,
	yawS = 0, pitchS = 0, rollS = 0, zoomLog = 0, zoomLogT = 0, zoomVel = 0, body = nil,
	focusClock = 0, glide = nil, speedBoost = 0, hudEls = nil,
}

function Free.fov()
	local zoom = math.pow(2, Free.zoomLog)
	return clamp(CFG.baseFov / zoom, CFG.minFov, CFG.maxFov)
end

function Free.syncFromCamera()
	local cf = Cam.cf
	Free.pos = cf.Position
	Free.vel = Vector3.new()
	Free.yaw, Free.pitch, Free.roll = poseFromCFrame(cf)
	Free.pitch = clamp(Free.pitch, -89, 89)
	Free.yawS, Free.pitchS, Free.rollS = Free.yaw, Free.pitch, Free.roll
	Free.rollVel = 0
	local fov = clamp(Cam.fov, CFG.minFov, CFG.maxFov)
	Free.zoomLog = math.log(CFG.baseFov / fov) / math.log(2)
	Free.zoomLogT = Free.zoomLog
	Free.zoomVel = 0
end

function Free.setBody(mode)
	if Free.body == mode then return end
	Free.body = mode
	if mode == nil then
		Body.setControls(false)
		if Body.controls then Body.setWalk(nil) else Body.setWalk("freeze") end
	elseif mode == "run" then
		Body.setWalk(nil)
		Body.setControls(true)
	elseif mode == "runway" then
		Body.setWalk("runway")
		Body.setControls(true)
	end
end

function Free.gotoPose(cf, fov, dur)
	local from, fromFov = Cam.cf, Cam.fov
	local t = 0
	Cam.override = function(dt)
		t = t + dt
		local a = Util.easeInOutCubic(t / dur)
		Cam.cf = from:Lerp(cf, a)
		Cam.fov = Util.lerp(fromFov, fov, a)
		if t >= dur then
			Cam.cf, Cam.fov = cf, fov
			Cam.override = nil
			Free.syncFromCamera()
		end
	end
end

defineMode({
	id = "FREE", name = "FREE CAMERA", icon = "✦", blurb = "fly anywhere · 120x zoom · bookmarks · dolly rail",
	scriptable = true, preset = nil, wantsMouseLock = "rmb",
	keys = {
		{ "W A S D", "fly" }, { "R / F", "up / down (Space = up)" }, { "Q / E", "roll left / right" }, { "Z", "level roll" },
		{ "Wheel", "zoom in / out (1° to 120°)" }, { "Ctrl+Wheel", "fly speed" }, { "RMB drag", "look" }, { "M", "toggle mouse lock" },
		{ "hold T", "run: body follows camera" }, { "hold Shift", "runway walk" },
		{ "B", "bookmark this view" }, { "G", "glide to next bookmark" }, { "N", "clear bookmarks" },
		{ "K", "add rail keyframe" }, { "L", "play / stop rail" }, { "J", "clear rail" },
	},
	enter = function()
		Cam.cf = camera.CFrame
		Cam.fov = camera.FieldOfView
		Free.syncFromCamera()
		Free.body = "init"
		Free.setBody(nil)
		Bookmarks.show(true)
		Rail.rebuild()
	end,
	exit = function()
		Rail.stop()
		Cam.override = nil
		Free.glide = nil
		Bookmarks.show(false)
		Rail.rebuild()
		STATE.mouseLocked = false
	end,
	syncFromCamera = Free.syncFromCamera,
	update = function(dt, t)
		local keys = STATE.keys
		local sf = S.free

		-- body coupling
		if STATE.runway then Free.setBody("runway")
		elseif keys.T then Free.setBody("run")
		else Free.setBody(nil) end

		-- zoom spring (exponential: every notch is the same *ratio*)
		Free.zoomLog, Free.zoomVel = Util.spring(Free.zoomLog, Free.zoomVel, Free.zoomLogT, 140, 24, dt)
		local fov = Free.fov()
		local fovScale = clamp(fov / CFG.baseFov, 0.012, 1.5)

		-- roll
		local rollAccel = sf.rollSpeed * 3
		if keys.Q then Free.rollVel = Free.rollVel - rollAccel * dt
		elseif keys.E then Free.rollVel = Free.rollVel + rollAccel * dt
		else Free.rollVel = Free.rollVel * math.exp(-9 * dt) end
		Free.rollVel = clamp(Free.rollVel, -sf.rollSpeed * 2, sf.rollSpeed * 2)
		Free.roll = Util.wrapAngle(Free.roll + Free.rollVel * dt)
		if sf.autoLevel and not keys.Q and not keys.E then
			Free.roll = Util.smoothAngle(Free.roll, 0, 3, dt)
		end

		-- movement
		local fwd = (keys.W and 1 or 0) - (keys.S and 1 or 0)
		local right = (keys.D and 1 or 0) - (keys.A and 1 or 0)
		local up = ((keys.R or keys.Space) and 1 or 0) - (keys.F and 1 or 0)
		local wish = Vector3.new(right, up, -fwd)
		local rot = CFrame.fromEulerAnglesYXZ(rad(Free.pitch), rad(Free.yaw), rad(Free.roll))
		local speed
		if Free.body == "run" then speed = Rig.humanoid.WalkSpeed
		elseif Free.body == "runway" then speed = CFG.runwayWalkSpeed
		else speed = sf.flySpeed * math.pow(fovScale, 0.75) end
		local targetVel = Vector3.new()
		if wish.Magnitude > 0 then
			local dir
			if Free.body then
				-- body modes: keep the camera level with the walking character
				local flat = CFrame.fromEulerAnglesYXZ(0, rad(Free.yaw), 0)
				dir = flat:VectorToWorldSpace(Vector3.new(wish.X, 0, wish.Z))
				if dir.Magnitude > 0 then dir = dir.Unit end
				dir = dir + Vector3.new(0, wish.Y, 0)
			else
				dir = rot:VectorToWorldSpace(wish.Unit)
			end
			targetVel = dir * speed
		end
		Free.vel = Util.smoothVec(Free.vel, targetVel, sf.accel, dt)
		local move = Free.vel * dt
		local before = Free.pos
		if sf.collision then Free.pos = Ray.slide(Free.pos, move, 1.1)
		else Free.pos = Free.pos + move end
		if dt > 0 then
			local actual = (Free.pos - before) / dt
			if (actual - Free.vel).Magnitude > 0.5 then Free.vel = actual end
		end

		-- smoothing of orientation (0 = razor, 1 = floaty)
		local rate = Util.lerp(70, 7, clamp(sf.smoothing, 0, 1))
		Free.yawS = Util.smoothAngle(Free.yawS, Free.yaw, rate, dt)
		Free.pitchS = Util.smooth(Free.pitchS, Free.pitch, rate, dt)
		Free.rollS = Util.smoothAngle(Free.rollS, Free.roll, rate, dt)

		-- speed FOV widening (only noticeable at low zoom)
		local boostTarget = 0
		if sf.speedFov then boostTarget = clamp(Free.vel.Magnitude / 160, 0, 1) * 10 * fovScale end
		Free.speedBoost = Util.smooth(Free.speedBoost, boostTarget, 5, dt)

		if not Cam.override then
			Cam.cf = CFrame.new(Free.pos) * CFrame.fromEulerAnglesYXZ(rad(Free.pitchS), rad(Free.yawS), rad(Free.rollS))
			Cam.fov = clamp(fov + Free.speedBoost, CFG.minFov, CFG.maxFov)
		end

		-- autofocus: whatever the crosshair hits
		Free.focusClock = Free.focusClock + dt
		if sf.autofocus and Free.focusClock > 1 / 15 then
			Free.focusClock = 0
			local hit = Ray.cast(Cam.cf.Position, Cam.cf.LookVector * 600)
			Filter.setFocus(hit and (hit.Position - Cam.cf.Position).Magnitude or 400)
		end
	end,
	mouse = function(delta)
		local fov = Free.fov()
		local sens = 0.18 * S.free.sensitivity * clamp(fov / CFG.baseFov, 0.012, 1.5)
		Free.yaw = Util.wrapAngle(Free.yaw - delta.X * sens)
		Free.pitch = clamp(Free.pitch - delta.Y * sens, -89, 89)
	end,
	wheel = function(delta)
		if STATE.keys.LeftControl or STATE.keys.RightControl then
			S.free.flySpeed = clamp(S.free.flySpeed * math.pow(2, delta * 0.2), 1, 400)
			if Window and Window.refreshSliders then Window.refreshSliders() end
			return
		end
		local maxLog = math.log(math.max(2, S.free.maxZoom)) / math.log(2)
		local minLog = math.log(CFG.baseFov / CFG.maxFov) / math.log(2)
		Free.zoomLogT = clamp(Free.zoomLogT + delta * 0.22 * S.free.zoomSpeed, minLog, maxLog)
	end,
	key = function(code, began)
		if not began then return end
		if code == Enum.KeyCode.Z then
			Free.roll = 0 Free.rollVel = 0
		elseif code == Enum.KeyCode.M then
			STATE.mouseLocked = not STATE.mouseLocked
			Toast.show(STATE.mouseLocked and "mouse locked · M to release" or "mouse released", "info", 1.4)
		elseif code == Enum.KeyCode.B then
			local e = Bookmarks.add(Cam.cf, Cam.fov)
			Toast.show("📍 " .. e.name .. " bookmarked", "ok")
		elseif code == Enum.KeyCode.G then
			if #Bookmarks.list == 0 then Toast.show("no bookmarks yet · press B", "error") return end
			Bookmarks.idx = (Bookmarks.idx % #Bookmarks.list) + 1
			local e = Bookmarks.list[Bookmarks.idx]
			Rail.stop()
			Free.gotoPose(e.cf, e.fov, 1.2)
			Toast.show("gliding to " .. e.name, "info", 1.2)
		elseif code == Enum.KeyCode.N then
			Bookmarks.clear()
			Toast.show("bookmarks cleared", "info")
		elseif code == Enum.KeyCode.K then
			Rail.add(Cam.cf, Cam.fov)
			Toast.show("rail key " .. #Rail.keys .. " added", "ok", 1.2)
		elseif code == Enum.KeyCode.L then
			if Rail.playing then Rail.stop() Toast.show("rail stopped", "info", 1.2) else Rail.play() end
		elseif code == Enum.KeyCode.J then
			Rail.clear()
			Toast.show("rail cleared", "info")
		end
	end,
	buildHud = function(parent)
		local els = {}
		els.block = new("Frame", { Size = UDim2.new(0, 300, 0, 64), Position = UDim2.new(0, 16, 1, -80), BackgroundTransparency = 1, Parent = parent })
		els.l1 = UI.text(els.block, "", { font = T.font.mono, size = 14, color = T.cyan, frameSize = UDim2.new(1, 0, 0, 18), stroke = 1 })
		els.l2 = UI.text(els.block, "", { font = T.font.mono, size = 14, color = T.text, frameSize = UDim2.new(1, 0, 0, 18), pos = UDim2.new(0, 0, 0, 20), stroke = 1 })
		els.l3 = UI.text(els.block, "", { font = T.font.head, size = 9, color = T.lavender, frameSize = UDim2.new(1, 0, 0, 18), pos = UDim2.new(0, 0, 0, 42), stroke = 1 })
		els.cross = new("Frame", { Size = UDim2.new(0, 4, 0, 4), Position = UDim2.new(0.5, -2, 0.5, -2), BackgroundColor3 = T.white, BorderSizePixel = 0, Visible = false, Parent = parent })
		UI.pill(els.cross)
		local ring = new("Frame", { Size = UDim2.new(0, 18, 0, 18), Position = UDim2.new(0.5, -9, 0.5, -9), BackgroundTransparency = 1, Visible = false, Parent = parent })
		UI.pill(ring)
		UI.stroke(ring, 1, T.white, 0.5)
		els.ring = ring
		return els
	end,
	tickHud = function(els)
		local fov = Cam.fov
		local zoom = CFG.baseFov / math.max(0.01, fov)
		els.l1.Text = string.format("ZOOM %5.1fx   FOV %5.1f°", zoom, fov)
		els.l2.Text = string.format("SPD %4.0f   ALT %6.1f   ROLL %4.0f°", Free.vel.Magnitude, Free.pos.Y, Free.rollS)
		local tags = {}
		if Free.body == "run" then table.insert(tags, "RUN") end
		if Free.body == "runway" then table.insert(tags, "RUNWAY") end
		if Rail.playing then table.insert(tags, string.format("RAIL ▶ %d KEYS", #Rail.keys)) elseif #Rail.keys > 0 then table.insert(tags, "RAIL " .. #Rail.keys) end
		if #Bookmarks.list > 0 then table.insert(tags, "BOOKMARKS " .. #Bookmarks.list) end
		if not S.free.collision then table.insert(tags, "NOCLIP") end
		if STATE.mouseLocked then table.insert(tags, "LOCKED") end
		els.l3.Text = table.concat(tags, "  ·  ")
		els.cross.Visible = STATE.mouseLocked or STATE.rmb
		els.ring.Visible = els.cross.Visible
	end,
})

----------------------------------------------------------------------------
-- 15. MODE: CINEMATIC  (an AI shot director)
----------------------------------------------------------------------------
local Director = {
	shot = nil, params = nil, shotT = 0, shotDur = 8, history = {}, blend = nil, hold = false,
	subject = nil, cfS = nil, fovS = CFG.baseFov, recT = 0, ctx = nil, indoorClock = 0, indoors = false,
	seed = rng:NextNumber(0, 1000), handheldT = 0,
}

-- relative placement: angle 0 = in front of the subject's face, 90 = subject's right
local function around(ctx, angleDeg, dist, height, useMove)
	local F = useMove and ctx.moveDir or ctx.facing
	local R = Vector3.new(-F.Z, 0, F.X)
	local a = rad(angleDeg)
	return ctx.pos + F * (math.cos(a) * dist) + R * (math.sin(a) * dist) + Vector3.new(0, height, 0)
end

local SHOTS = {
	{ name = "ORBIT", dur = { 7, 11 }, indoorsOK = true,
		build = function(ctx) return { a0 = rng:NextNumber(0, 360), dir = rng:NextInteger(0, 1) * 2 - 1, r = ctx.indoors and rng:NextNumber(5, 7) or rng:NextNumber(8, 14), h = rng:NextNumber(1.2, 3.5), w = rng:NextNumber(10, 18), fov = rng:NextNumber(46, 58) } end,
		eval = function(p, ctx, u, t)
			local a = p.a0 + p.dir * p.w * t
			return around(ctx, a, p.r, p.h), ctx.pos + Vector3.new(0, 0.3, 0), p.fov
		end },
	{ name = "DOLLY IN", dur = { 6, 8 }, idle = true, indoorsOK = true,
		build = function(ctx) return { a = rng:NextNumber(-55, 55), d0 = ctx.indoors and 10 or rng:NextNumber(18, 26), d1 = rng:NextNumber(4.2, 5.5), h0 = rng:NextNumber(3, 5), h1 = rng:NextNumber(1, 1.6) } end,
		eval = function(p, ctx, u)
			local e = Util.easeInOutCubic(u)
			return around(ctx, p.a, Util.lerp(p.d0, p.d1, e), Util.lerp(p.h0, p.h1, e)), ctx.pos + Vector3.new(0, 0.4, 0), Util.lerp(56, 38, e)
		end },
	{ name = "CRANE", dur = { 7, 9 }, indoorsOK = false,
		build = function(ctx) return { a = rng:NextNumber(15, 70) * (rng:NextInteger(0, 1) * 2 - 1), r0 = 5, r1 = rng:NextNumber(16, 22), h0 = 0.6, h1 = rng:NextNumber(11, 16) } end,
		eval = function(p, ctx, u)
			local e = Util.easeInOutCubic(u)
			return around(ctx, p.a + e * 25, Util.lerp(p.r0, p.r1, e), Util.lerp(p.h0, p.h1, e)), ctx.pos, 60
		end },
	{ name = "HERO LOW", dur = { 5, 7 }, idle = true, indoorsOK = true,
		build = function(ctx) return { a = rng:NextNumber(-35, 35), r = rng:NextNumber(3.6, 5), drift = rng:NextNumber(-18, 18) } end,
		eval = function(p, ctx, u)
			local pos = around(ctx, p.a + p.drift * u, p.r, -1.0)
			if ctx.groundY then pos = Vector3.new(pos.X, math.max(pos.Y, ctx.groundY + 0.5), pos.Z) end
			return pos, ctx.head + Vector3.new(0, 0.35, 0), 42
		end },
	{ name = "TRACK SIDE", dur = { 5, 8 }, moving = true, indoorsOK = true,
		build = function() return { side = rng:NextInteger(0, 1) * 2 - 1, d = rng:NextNumber(5.5, 8), h = rng:NextNumber(1.2, 2) } end,
		eval = function(p, ctx)
			local F = ctx.moveDir
			local R = Vector3.new(-F.Z, 0, F.X)
			return ctx.pos + R * (p.side * p.d) - F * 0.6 + Vector3.new(0, p.h, 0), ctx.pos + F * 1.5, 50
		end },
	{ name = "OVER SHOULDER", dur = { 5, 8 }, moving = true, indoorsOK = true,
		build = function() return { side = rng:NextInteger(0, 1) * 2 - 1 } end,
		eval = function(p, ctx)
			local F = ctx.moveDir
			local R = Vector3.new(-F.Z, 0, F.X)
			return ctx.pos - F * 4.5 + R * (1.6 * p.side) + Vector3.new(0, 2.4, 0), ctx.pos + F * 9 + Vector3.new(0, 0.6, 0), 60
		end },
	{ name = "VERTIGO", dur = { 6, 7 }, idle = true, indoorsOK = false,
		build = function() local fov0 = 65 local d0 = 6 return { a = rng:NextNumber(-40, 40), d0 = d0, d1 = rng:NextNumber(20, 26), k = math.tan(rad(fov0 / 2)) * d0, flip = rng:NextInteger(0, 1) == 1 } end,
		eval = function(p, ctx, u)
			local e = Util.easeInOutCubic(p.flip and (1 - u) or u)
			local d = Util.lerp(p.d0, p.d1, e)
			local fov = deg(2 * math.atan(p.k / d))
			return around(ctx, p.a, d, 1.2), ctx.pos, fov
		end },
	{ name = "HANDHELD", dur = { 4, 6 }, indoorsOK = true, handheld = 2.5,
		build = function() return { a = rng:NextNumber(-45, 45), r = rng:NextNumber(2.8, 3.8), h = rng:NextNumber(0.3, 0.8) } end,
		eval = function(p, ctx) return around(ctx, p.a, p.r, p.h), ctx.head, 40 end },
	{ name = "TOP SPIRAL", dur = { 8, 10 }, indoorsOK = false,
		build = function() return { a0 = rng:NextNumber(0, 360), w = rng:NextNumber(25, 40) * (rng:NextInteger(0, 1) * 2 - 1) } end,
		eval = function(p, ctx, u, t)
			local r = Util.lerp(5, 13, u)
			local h = Util.lerp(12, 22, u)
			local a = rad(p.a0 + p.w * t)
			return ctx.pos + Vector3.new(math.cos(a) * r, h, math.sin(a) * r), ctx.pos, 65
		end },
	{ name = "WIDE", dur = { 6, 9 }, idle = true, indoorsOK = false,
		build = function() return { a = rng:NextNumber(0, 360), w = rng:NextNumber(-4, 4) } end,
		eval = function(p, ctx, u, t) return around(ctx, p.a + p.w * t, 28, 6), ctx.pos + Vector3.new(0, 1, 0), 68 end },
	{ name = "GROUP", dur = { 7, 10 }, group = true, indoorsOK = true,
		build = function(ctx) return { a0 = rng:NextNumber(0, 360), w = rng:NextNumber(6, 12) * (rng:NextInteger(0, 1) * 2 - 1), r = 9 + ctx.nearby * 2.5 } end,
		eval = function(p, ctx, u, t)
			local a = rad(p.a0 + p.w * t)
			local c = ctx.groupCenter
			return c + Vector3.new(math.cos(a) * p.r, 3, math.sin(a) * p.r), c + Vector3.new(0, 0.5, 0), 62
		end },
}

local function sortedPlayers()
	local list = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character and p.Character:FindFirstChild("HumanoidRootPart") then table.insert(list, p) end
	end
	table.sort(list, function(a, b) return a.Name < b.Name end)
	return list
end

function Director.subjectChar()
	local s = Director.subject
	if s and s.Parent and s.Character and s.Character:FindFirstChild("HumanoidRootPart") then return s.Character end
	Director.subject = player
	return Rig.char
end

function Director.buildContext(dt)
	local c = Director.subjectChar()
	local rootP = c:FindFirstChild("HumanoidRootPart")
	local headP = c:FindFirstChild("Head")
	if not rootP then return nil end
	local headPos = headP and headP.Position or (rootP.Position + Vector3.new(0, 1.5, 0))
	local vel = Util.flatten(rootP.AssemblyLinearVelocity)
	local speed = vel.Magnitude
	local facing = Util.safeUnit(Util.flatten(rootP.CFrame.LookVector))
	local ctx = Director.ctx or {}
	ctx.pos = headPos - Vector3.new(0, 0.35, 0)
	ctx.head = headPos
	ctx.facing = facing
	ctx.speed = speed
	ctx.isMoving = speed > 2.5
	ctx.moveDir = ctx.isMoving and vel.Unit or facing
	Director.indoorClock = Director.indoorClock - dt
	if Director.indoorClock <= 0 then
		Director.indoorClock = 0.6
		Director.indoors = Ray.isIndoors(headPos + Vector3.new(0, 0.5, 0))
		ctx.groundY = Ray.groundY(rootP.Position, 60)
		local n, sum = 0, Vector3.new()
		for _, p in ipairs(Players:GetPlayers()) do
			local ch = p.Character
			local r = ch and ch ~= c and ch:FindFirstChild("HumanoidRootPart")
			if r and (r.Position - rootP.Position).Magnitude < 18 then n = n + 1 sum = sum + r.Position end
		end
		ctx.nearby = n
		ctx.groupCenter = n > 0 and ((sum + rootP.Position) / (n + 1)) or rootP.Position
	end
	ctx.indoors = Director.indoors
	ctx.nearby = ctx.nearby or 0
	ctx.groupCenter = ctx.groupCenter or rootP.Position
	Director.ctx = ctx
	return ctx
end

function Director.pickShot(ctx)
	local candidates = {}
	for _, shot in ipairs(SHOTS) do
		local score = 1
		if ctx.isMoving then
			if shot.moving then score = score * 2.6 end
			if shot.idle then score = score * 0.35 end
		else
			if shot.moving then score = score * 0.12 end
		end
		if ctx.indoors and not shot.indoorsOK then score = score * 0.08 end
		if shot.group then score = ctx.nearby > 0 and score * 3 or 0 end
		for i, h in ipairs(Director.history) do
			if h == shot.name then score = score * (i == 1 and 0.1 or 0.4) end
		end
		score = score * rng:NextNumber(0.6, 1.4)
		if score > 0 then table.insert(candidates, { shot = shot, score = score }) end
	end
	table.sort(candidates, function(a, b) return a.score > b.score end)
	-- line of sight check on the top candidates
	for i = 1, math.min(4, #candidates) do
		local shot = candidates[i].shot
		local p = shot.build(ctx)
		local blocked = 0
		for _, u in ipairs({ 0, 0.5, 1 }) do
			local pos, look = shot.eval(p, ctx, u, u * 6)
			local zoomed = look + (pos - look) * S.cinematic.zoom
			if Ray.cast(look, zoomed - look) then blocked = blocked + 1 end
		end
		if blocked < 2 then return shot, p end
	end
	local fallback = SHOTS[1]
	return fallback, { a0 = rng:NextNumber(0, 360), dir = 1, r = 5, h = 1.5, w = 14, fov = 55 }
end

function Director.nextShot(ctx, forceGlide)
	local shot, p = Director.pickShot(ctx)
	local cut = (not forceGlide) and Director.shot ~= nil and rng:NextNumber() < S.cinematic.energy * 0.85
	if Director.shot and not cut then
		Director.blend = { from = Director.cfS or Cam.cf, fromFov = Director.fovS, t = 0, dur = Util.lerp(2.3, 0.7, S.cinematic.energy) }
	else
		Director.blend = nil
	end
	Director.shot = shot
	Director.params = p
	Director.shotT = 0
	Director.shotDur = rng:NextNumber(shot.dur[1], shot.dur[2]) * clamp(S.cinematic.shotLength, 0.3, 3)
	table.insert(Director.history, 1, shot.name)
	if #Director.history > 3 then table.remove(Director.history) end
	if cut then Director.cfS = nil end
end

function Director.switchSubject(step)
	local list = sortedPlayers()
	if #list <= 1 then Toast.show("nobody else to film", "error") return end
	local idx = 1
	for i, p in ipairs(list) do if p == Director.subject then idx = i break end end
	idx = ((idx - 1 + step) % #list) + 1
	Director.subject = list[idx]
	Director.ctx = nil
	Director.indoorClock = 0
	local ctx = Director.buildContext(0)
	if ctx then Director.nextShot(ctx, true) end
	Toast.show("filming " .. Director.subject.DisplayName, "mode")
end

defineMode({
	id = "CINEMATIC", name = "CINEMATIC", icon = "▶", blurb = "an AI shot director · 11 shot types · film look",
	scriptable = true, preset = function() return S.cinematic.preset end, wantsMouseLock = "never",
	keys = {
		{ "O", "next shot" }, { "P", "film the next player" }, { "H", "hold / release the director" },
		{ "Wheel", "shot scale" }, { "hold Shift", "runway walk" }, { "W A S D", "walk (you stay the subject)" },
	},
	enter = function()
		Director.subject = player
		Director.shot = nil
		Director.history = {}
		Director.blend = nil
		Director.hold = false
		Director.recT = 0
		Director.ctx = nil
		Director.indoorClock = 0
		Director.cfS = nil
		Director.fovS = camera.FieldOfView
		local ctx = Director.buildContext(0)
		if ctx then Director.nextShot(ctx, true) end
	end,
	exit = function() Director.blend = nil end,
	update = function(dt, t)
		local ctx = Director.buildContext(dt)
		if not ctx or not Director.shot then return end
		Director.recT = Director.recT + dt
		if STATE.runway then Body.setWalk("runway") elseif Body.override == "runway" then Body.setWalk(nil) end

		if not Director.hold then
			Director.shotT = Director.shotT + dt
			if Director.shotT >= Director.shotDur then Director.nextShot(ctx) end
		end
		local u = clamp(Director.shotT / Director.shotDur, 0, 1)
		local pos, look, fov = Director.shot.eval(Director.params, ctx, u, Director.shotT)
		pos = look + (pos - look) * clamp(S.cinematic.zoom, 0.3, 3)

		-- handheld micro-motion
		local hh = S.cinematic.handheld * (Director.shot.handheld or 1)
		if hh > 0 then
			Director.handheldT = Director.handheldT + dt
			local n = Util.noise3(Director.handheldT * 0.9, Director.seed)
			pos = pos + n * (0.12 * hh)
			look = look + Util.noise3(Director.handheldT * 1.3, Director.seed + 50) * (0.08 * hh)
		end

		pos = Ray.pullIn(pos, look, 0.8)
		local target = CFrame.lookAt(pos, look)

		if Director.blend then
			local b = Director.blend
			b.t = b.t + dt
			local a = Util.smoothstep(b.t / b.dur)
			target = b.from:Lerp(target, a)
			fov = Util.lerp(b.fromFov, fov, a)
			if b.t >= b.dur then Director.blend = nil end
		end

		if Director.cfS then
			Director.cfS = Director.cfS:Lerp(target, Util.expAlpha(14, dt))
			Director.fovS = Util.smooth(Director.fovS, fov, 8, dt)
		else
			Director.cfS = target
			Director.fovS = fov
		end
		Cam.cf = Director.cfS
		Cam.fov = Director.fovS
		if S.cinematic.autoFocus then Filter.setFocus((look - pos).Magnitude) end
		Filter.flashbulbs(dt, ctx.pos)
	end,
	wheel = function(delta)
		S.cinematic.zoom = clamp(S.cinematic.zoom * math.pow(2, -delta * 0.12), 0.3, 3)
	end,
	key = function(code, began)
		if not began then return end
		if code == Enum.KeyCode.O then
			local ctx = Director.buildContext(0)
			if ctx then Director.nextShot(ctx) end
		elseif code == Enum.KeyCode.P then
			Director.switchSubject(1)
		elseif code == Enum.KeyCode.H then
			Director.hold = not Director.hold
			Toast.show(Director.hold and "director on hold" or "director rolling", "info", 1.4)
		end
	end,
	buildHud = function(parent)
		local els = {}
		els.rec = UI.text(parent, "", { font = T.font.mono, size = 14, color = T.danger, frameSize = UDim2.new(0, 220, 0, 20), pos = UDim2.new(0, 18, 0, 18), stroke = 1 })
		els.shot = UI.text(parent, "", { font = T.font.head, size = 10, color = T.lavender, frameSize = UDim2.new(0, 300, 0, 20), pos = UDim2.new(0, 18, 0, 40), stroke = 1 })
		els.subject = UI.text(parent, "", { font = T.font.head, size = 10, color = T.text, frameSize = UDim2.new(0, 300, 0, 20), pos = UDim2.new(1, -318, 0, 18), xalign = Enum.TextXAlignment.Right, stroke = 1 })
		return els
	end,
	tickHud = function(els)
		local blink = math.floor(os.clock() * 2) % 2 == 0
		els.rec.Text = (blink and "● " or "   ") .. "REC " .. Util.fmtTime(Director.recT)
		local shotName = Director.shot and Director.shot.name or "-"
		els.shot.Text = shotName .. (Director.hold and "  ·  HOLD" or "") .. (Director.indoors and "  ·  INT" or "  ·  EXT")
		els.subject.Text = Director.subject and ("SUBJECT  " .. Director.subject.DisplayName) or ""
	end,
})

----------------------------------------------------------------------------
-- 16. PHONE  (a procedurally built iPhone that lives in the right hand)
----------------------------------------------------------------------------
Phone = { model = nil, parts = {}, torch = false }

-- Where the phone sits in the hand. Tuned for Rthro-style hands (fingers -Y, palm -X).
CFG.phoneGrip = CFrame.fromMatrix(Vector3.new(-0.2, -0.05, 0.02), Vector3.new(0, 0, -1), Vector3.new(0, -1, 0), Vector3.new(-1, 0, 0))

-- Lockscreen builder used both on the 3D phone (SurfaceGui) and the full screen overlay.
-- w/h are pixel sizes of the phone face. Returns a table with the live labels.
local function buildLockscreen(parent, w, h, zBase, userId)
	zBase = zBase or 1
	userId = userId or player.UserId
	local bg = new("Frame", {
		Name = "Lockscreen", Size = UDim2.new(0, w, 0, h), BackgroundColor3 = Color3.fromRGB(190, 176, 198),
		BorderSizePixel = 0, ClipsDescendants = true, ZIndex = zBase, Parent = parent,
	})
	-- low saturation gradient: dusty lavender -> dusty rose -> slate
	local grad = UI.gradient(bg, ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(186, 178, 204)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(204, 186, 188)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(142, 154, 170)),
	}), 90)
	UI.animate(function(t)
		if not grad.Parent then return error("dead") end
		grad.Rotation = 90 + math.sin(t * 0.25) * 9
	end)
	-- avatar: full body thumbnail cropped to head -> waist
	local avatarHolder = new("Frame", {
		Name = "Avatar", Size = UDim2.new(1, 0, 0.66, 0), Position = UDim2.new(0, 0, 0.34, 0),
		BackgroundTransparency = 1, ClipsDescendants = true, ZIndex = zBase + 1, Parent = bg,
	})
	local imgSize = (h * 0.66) / 0.55
	local avatar = new("ImageLabel", {
		Name = "Body", Size = UDim2.new(0, imgSize, 0, imgSize), Position = UDim2.new(0.5, -imgSize / 2, 0, -imgSize * 0.04),
		BackgroundTransparency = 1, Image = "rbxthumb://type=Avatar&id=" .. userId .. "&w=720&h=720",
		ScaleType = Enum.ScaleType.Fit, ZIndex = zBase + 2, Parent = avatarHolder,
	})
	-- soft floor fade under the avatar
	local fade = new("Frame", {
		Size = UDim2.new(1, 0, 0.3, 0), Position = UDim2.new(0, 0, 0.7, 0), BackgroundColor3 = Color3.fromRGB(142, 154, 170),
		BorderSizePixel = 0, ZIndex = zBase + 3, Parent = bg,
	})
	UI.gradient(fade, ColorSequence.new(T.white, T.white), 90, NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.15) }))
	-- status bar
	local sb = h * 0.05
	local status = UI.text(bg, "", { font = T.font.ui, size = math.max(8, h * 0.028), color = T.white, frameSize = UDim2.new(0.3, 0, 0, sb), pos = UDim2.new(0.08, 0, 0, sb * 0.3), z = zBase + 4 })
	UI.text(bg, "▮▮▮  5G  ▭", { font = T.font.ui, size = math.max(8, h * 0.024), color = T.white, frameSize = UDim2.new(0.32, 0, 0, sb), pos = UDim2.new(0.6, 0, 0, sb * 0.3), xalign = Enum.TextXAlignment.Right, z = zBase + 4 })
	-- dynamic island
	local island = new("Frame", { Size = UDim2.new(0.3, 0, 0, h * 0.032), Position = UDim2.new(0.35, 0, 0, h * 0.018), BackgroundColor3 = T.black, BorderSizePixel = 0, ZIndex = zBase + 4, Parent = bg })
	UI.pill(island)
	-- lock glyph + clock + date
	UI.text(bg, "🔒", { font = T.font.ui, size = math.max(10, h * 0.03), color = T.white, frameSize = UDim2.new(1, 0, 0, h * 0.04), pos = UDim2.new(0, 0, 0, h * 0.075), xalign = Enum.TextXAlignment.Center, z = zBase + 4 })
	local date = UI.text(bg, "", { font = T.font.body, size = math.max(9, h * 0.034), color = T.white, frameSize = UDim2.new(1, 0, 0, h * 0.05), pos = UDim2.new(0, 0, 0, h * 0.12), xalign = Enum.TextXAlignment.Center, z = zBase + 4 })
	local clock = UI.text(bg, "", { font = T.font.big, size = math.max(16, h * 0.14), color = T.white, frameSize = UDim2.new(1, 0, 0, h * 0.16), pos = UDim2.new(0, 0, 0, h * 0.16), xalign = Enum.TextXAlignment.Center, z = zBase + 4 })
	-- bottom: hint + home bar
	local hint = UI.text(bg, "swipe up to open camera", { font = T.font.body, size = math.max(8, h * 0.026), color = T.white, frameSize = UDim2.new(1, 0, 0, h * 0.04), pos = UDim2.new(0, 0, 0.91, 0), xalign = Enum.TextXAlignment.Center, z = zBase + 5, transparency = 0.25 })
	local home = new("Frame", { Size = UDim2.new(0.36, 0, 0, math.max(2, h * 0.007)), Position = UDim2.new(0.32, 0, 0.975, 0), BackgroundColor3 = T.white, BorderSizePixel = 0, ZIndex = zBase + 5, Parent = bg })
	UI.pill(home)
	-- quick action bubbles (flashlight / camera) like iOS
	for i, glyph in ipairs({ "🔦", "📷" }) do
		local b = new("Frame", { Size = UDim2.new(0, h * 0.075, 0, h * 0.075), Position = UDim2.new(i == 1 and 0.1 or 0.9, i == 1 and 0 or -h * 0.075, 0.885, 0), BackgroundColor3 = Color3.fromRGB(40, 36, 52), BackgroundTransparency = 0.35, BorderSizePixel = 0, ZIndex = zBase + 5, Parent = bg })
		UI.pill(b)
		UI.text(b, glyph, { font = T.font.ui, size = math.max(10, h * 0.035), xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 1, 0), z = zBase + 6 })
	end
	local api = { frame = bg, clock = clock, date = date, status = status, hint = hint, avatar = avatar }
	function api.tick()
		clock.Text = Util.clock24()
		date.Text = Util.dateLong()
		status.Text = Util.clock24()
	end
	api.tick()
	return api
end

-- Build a phone for any character's hand (nil hand = anchored, positioned by the caller).
-- Returns a handle { model, parts, spot, point, lockGui, lock, weld, setTorch, setVisible, flashBurst, destroy }.
function Phone.create(handPart, rigType, userId, parent)
	local h = { torch = false, parts = {} }
	local body = new("Part", {
		Name = "ICS2K_Phone", Size = Vector3.new(0.74, 1.52, 0.07), Color = Color3.fromRGB(26, 26, 32),
		Material = Enum.Material.SmoothPlastic, Anchored = false, CanCollide = false, CanQuery = false, CanTouch = false,
		Massless = true, CastShadow = false, Parent = parent or localFolder(),
	})
	local screen = new("Part", {
		Name = "Screen", Size = Vector3.new(0.68, 1.44, 0.012), Color = T.black, Material = Enum.Material.SmoothPlastic,
		Anchored = false, CanCollide = false, CanQuery = false, CanTouch = false, Massless = true, CastShadow = false, Parent = body,
	})
	new("Weld", { Part0 = body, Part1 = screen, C0 = CFrame.new(0, 0, -0.04), Parent = screen })
	local lens = new("Part", {
		Name = "FrontLens", Shape = Enum.PartType.Ball, Size = Vector3.new(0.06, 0.06, 0.06), Color = Color3.fromRGB(10, 10, 14),
		Material = Enum.Material.Glass, Anchored = false, CanCollide = false, CanQuery = false, CanTouch = false, Massless = true, CastShadow = false, Parent = body,
	})
	new("Weld", { Part0 = body, Part1 = lens, C0 = CFrame.new(0, 0.6, -0.045), Parent = lens })
	for i, off in ipairs({ Vector3.new(-0.18, 0.5, 0.05), Vector3.new(-0.18, 0.28, 0.05), Vector3.new(0.02, 0.39, 0.05) }) do
		local cam = new("Part", {
			Name = "Lens" .. i, Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.03, 0.17, 0.17), Color = Color3.fromRGB(12, 12, 16),
			Material = Enum.Material.Glass, Anchored = false, CanCollide = false, CanQuery = false, CanTouch = false, Massless = true, CastShadow = false, Parent = body,
		})
		new("Weld", { Part0 = body, Part1 = cam, C0 = CFrame.new(off) * CFrame.Angles(0, rad(90), 0), Parent = cam })
	end
	local gui = new("SurfaceGui", {
		Name = "LockGui", Face = Enum.NormalId.Front, LightInfluence = 0, Brightness = 1.6, PixelsPerStud = 400,
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud, AlwaysOnTop = false, Parent = screen,
	})
	h.lockGui = gui
	h.lock = buildLockscreen(gui, 272, 576, 1, userId)
	h.spot = new("SpotLight", { Face = Enum.NormalId.Front, Angle = 75, Range = 9, Brightness = 0, Color = Color3.fromRGB(255, 244, 228), Shadows = false, Parent = screen })
	h.point = new("PointLight", { Range = 7, Brightness = 0, Color = Color3.fromRGB(255, 248, 235), Shadows = false, Parent = body })
	h.model = body
	h.parts = { body, screen, lens }
	for _, c in ipairs(body:GetChildren()) do if c:IsA("BasePart") then table.insert(h.parts, c) end end
	if handPart then
		h.weld = new("Weld", { Part0 = handPart, Part1 = body, C0 = CFG.phoneGrip, Parent = body })
		if rigType == "R6" then h.weld.C0 = CFrame.new(0, -1.05, 0) * CFrame.Angles(rad(-90), 0, 0) * CFrame.Angles(0, rad(180), 0) end
	else
		body.Anchored = true
	end
	function h.setTorch(on, brightness)
		h.torch = on and true or false
		if h.spot then h.spot.Brightness = h.torch and (brightness or 2) or 0 end
	end
	function h.setVisible(v)
		for _, p in ipairs(h.parts) do p.LocalTransparencyModifier = v and 0 or 1 end
		if h.lockGui then h.lockGui.Enabled = v and true or false end
	end
	function h.flashBurst()
		if not h.point then return end
		h.point.Brightness = 12
		if h.spot then h.spot.Brightness = 10 end
		task.delay(0.22, function()
			if h.point then h.point.Brightness = 0 end
			h.setTorch(h.torch, S.paparazzi.torch)
		end)
	end
	function h.destroy()
		if h.model then h.model:Destroy() end
		h.model = nil
		h.parts = {}
	end
	return h
end

-- The local player's phone (PAPARAZZI mode)
function Phone.build()
	Phone.destroy()
	local h = Phone.create(IK.rig and IK.hand or nil, IK.rig, player.UserId, localFolder())
	Phone.handle = h
	Phone.model, Phone.parts, Phone.weld = h.model, h.parts, h.weld
	Phone.lock, Phone.lockGui, Phone.spot, Phone.point = h.lock, h.lockGui, h.spot, h.point
	Phone.setTorch(Phone.torch)
	return h.model
end

function Phone.destroy()
	if Phone.handle then Phone.handle.destroy() end
	Phone.handle = nil
	Phone.model = nil
	Phone.parts = {}
	Phone.weld = nil
	Phone.lock = nil
	Phone.lockGui = nil
	Phone.spot = nil
	Phone.point = nil
end

function Phone.setVisible(v)
	if Phone.handle then Phone.handle.setVisible(v) end
end

function Phone.setTorch(on)
	Phone.torch = on and true or false
	if Phone.handle then Phone.handle.setTorch(Phone.torch, S.paparazzi.torch) end
end

function Phone.flashBurst()
	if Phone.handle then Phone.handle.flashBurst() end
end

----------------------------------------------------------------------------
-- 17. MODE: PAPARAZZI  (iPhone selfie mode)
----------------------------------------------------------------------------
local Pap = {
	phase = "off", phaseT = 0, armYaw = -18, armPitch = 12, armYawS = -18, armPitchS = 12,
	rootYawS = 0, front = true, zoomLevels = { 0.5, 1, 2, 3 }, zoomT = 1, zoomS = 1, zoomVel = 0,
	lookS = nil, camS = nil, shakeT = 0, seed = rng:NextNumber(0, 500), lastThumb = nil,
	focusFade = 0, introFrom = nil, introFromFov = 70, region = nil,
}

function Pap.desiredPhoneCF(dt)
	local head = Rig.head
	local headPos = head and head.Position or (Rig.root.Position + Vector3.new(0, 1.5, 0))
	local rootYaw = Util.yawOf(Rig.root.CFrame)
	if dt then Pap.rootYawS = Pap.rootYawS + Util.angleDelta(Pap.rootYawS, deg(rootYaw)) * Util.expAlpha(9, dt) end
	local base = CFrame.new(headPos) * CFrame.Angles(0, rad(Pap.rootYawS), 0)
	local reach = (IK.reach or 2.2) * S.paparazzi.armLength
	local dist = clamp(reach * 0.8, 1.1, 3.4)
	local off = CFrame.Angles(0, rad(Pap.armYawS), 0) * CFrame.Angles(rad(Pap.armPitchS), 0, 0) * CFrame.new(0, 0, -dist)
	local phonePos = (base * off).Position
	local facePos = headPos + Vector3.new(0, 0.05, 0)
	local cf = CFrame.lookAt(phonePos, facePos) * CFrame.Angles(rad(-6), 0, 0)
	return cf, facePos, headPos
end

function Pap.fov()
	local z = clamp(Pap.zoomS, 0.5, 6)
	return clamp(S.paparazzi.fov / z, 18, 112)
end

-- Layout of the full screen phone UI (mask, bezel, viewfinder, chrome). Rebuilt on resize.
function Pap.layout()
	local vp = camera.ViewportSize
	local phoneH = vp.Y * 0.965
	local phoneW = phoneH * (9 / 19.5)
	if phoneW > vp.X * 0.92 then
		phoneW = vp.X * 0.92
		phoneH = phoneW * (19.5 / 9)
	end
	local x0 = (vp.X - phoneW) / 2
	local y0 = (vp.Y - phoneH) / 2
	local vfW = phoneW
	local vfH = phoneW * 4 / 3
	local vfY = y0 + phoneH * 0.165
	local r = { x0 = x0, y0 = y0, w = phoneW, h = phoneH, vfX = x0, vfY = vfY, vfW = vfW, vfH = vfH, vp = vp }
	Pap.region = r
	local e = Pap.els
	if not e then return end
	e.maskL.Size = UDim2.new(0, x0, 1, 0)
	e.maskR.Size = UDim2.new(0, vp.X - (x0 + phoneW), 1, 0)
	e.maskR.Position = UDim2.new(0, x0 + phoneW, 0, 0)
	e.maskT.Size = UDim2.new(0, phoneW, 0, vfY)
	e.maskT.Position = UDim2.new(0, x0, 0, 0)
	e.maskB.Size = UDim2.new(0, phoneW, 0, vp.Y - (vfY + vfH))
	e.maskB.Position = UDim2.new(0, x0, 0, vfY + vfH)
	e.bezel.Size = UDim2.new(0, phoneW, 0, phoneH)
	e.bezel.Position = UDim2.new(0, x0, 0, y0)
	e.phoneFrame.Size = UDim2.new(0, phoneW, 0, phoneH)
	e.phoneFrame.Position = UDim2.new(0, x0, 0, y0)
	e.vfFrame.Size = UDim2.new(0, vfW, 0, vfH)
	e.vfFrame.Position = UDim2.new(0, x0, 0, vfY)
	e.hints.Position = UDim2.new(0, 18, 1, -110)
	e.hints.Visible = x0 > 200
	e.brand.Position = UDim2.new(1, -18, 1, -40)
	e.brand.Visible = x0 > 160
	if e.lock then
		e.lock.frame.Size = UDim2.new(1, 0, 1, 0)
	end
end

function Pap.buildUI()
	-- mask layer (kept during capture so photos come out portrait)
	Pap.maskGui = new("ScreenGui", { Name = "ICS2K_PhoneMask", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 250, Enabled = false, Parent = playerGui })
	-- chrome layer (hidden for the capture frame)
	Pap.chromeGui = new("ScreenGui", { Name = "ICS2K_PhoneChrome", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 260, Enabled = false, Parent = playerGui })
	local e = {}
	Pap.els = e
	local dark = Color3.fromRGB(5, 5, 8)
	local function mask(name) return new("Frame", { Name = name, BackgroundColor3 = dark, BorderSizePixel = 0, ZIndex = 1, Parent = Pap.maskGui }) end
	e.maskL, e.maskR, e.maskT, e.maskB = mask("L"), mask("R"), mask("T"), mask("B")
	for _, m in ipairs({ e.maskL, e.maskR }) do
		UI.gradient(m, ColorSequence.new(Color3.fromRGB(10, 9, 16), dark), 90)
	end
	e.bezel = new("Frame", { Name = "Bezel", BackgroundTransparency = 1, ZIndex = 3, Parent = Pap.maskGui })
	UI.corner(e.bezel, 46)
	UI.gradient(UI.stroke(e.bezel, 4, T.white, 0.05), T.chrome, 90)
	-- outside the phone: hints + brand
	e.hints = UI.text(Pap.chromeGui, "ENTER  shutter\nF  flash   V  flip   G  gallery\nRMB drag  aim   wheel  zoom\nW A S D  walk   SPACE  jump\nX  exit", {
		font = T.font.mono, size = 13, color = T.muted, frameSize = UDim2.new(0, 260, 0, 100), yalign = Enum.TextYAlignment.Bottom, z = 5,
	})
	e.brand = UI.text(Pap.chromeGui, "ICS2K ✦ PAPARAZZI", { font = T.font.head, size = 10, color = T.lavender, frameSize = UDim2.new(0, 220, 0, 20), anchor = Vector2.new(1, 0), xalign = Enum.TextXAlignment.Right, z = 5 })

	-- phone frame (chrome layer) holds the camera app and the lockscreen
	e.phoneFrame = new("Frame", { Name = "Phone", BackgroundTransparency = 1, ClipsDescendants = true, ZIndex = 10, Parent = Pap.chromeGui })
	UI.corner(e.phoneFrame, 46)
	-- status bar
	e.status = UI.text(e.phoneFrame, "", { font = T.font.ui, size = 14, color = T.white, frameSize = UDim2.new(0.3, 0, 0, 24), pos = UDim2.new(0.07, 0, 0, 10), z = 12 })
	UI.text(e.phoneFrame, "▮▮▮  5G  ▭", { font = T.font.ui, size = 12, color = T.white, frameSize = UDim2.new(0.32, 0, 0, 24), pos = UDim2.new(0.61, 0, 0, 10), xalign = Enum.TextXAlignment.Right, z = 12 })
	local island = new("Frame", { Size = UDim2.new(0.3, 0, 0, 24), Position = UDim2.new(0.35, 0, 0, 12), BackgroundColor3 = T.black, BorderSizePixel = 0, ZIndex = 12, Parent = e.phoneFrame })
	UI.pill(island)
	UI.stroke(island, 1, Color3.fromRGB(40, 40, 48), 0)
	-- top camera controls
	e.flashBtn = UI.button(e.phoneFrame, { text = "⚡", kind = "dark", size = UDim2.new(0, 38, 0, 38), pos = UDim2.new(0.06, 0, 0, 52), textSize = 18, font = T.font.ui, onClick = function() Pap.toggleTorch() end })
	e.liveLbl = UI.text(e.phoneFrame, "SELFIE", { font = T.font.head, size = 9, color = T.gold, frameSize = UDim2.new(0.4, 0, 0, 38), pos = UDim2.new(0.3, 0, 0, 52), xalign = Enum.TextXAlignment.Center, z = 12 })
	e.timerLbl = UI.text(e.phoneFrame, "◴", { font = T.font.ui, size = 18, color = T.white, frameSize = UDim2.new(0, 38, 0, 38), pos = UDim2.new(0.94, -38, 0, 52), xalign = Enum.TextXAlignment.Center, z = 12 })

	-- viewfinder overlay (sits exactly over the visible world rect)
	e.vfFrame = new("Frame", { Name = "Viewfinder", BackgroundTransparency = 1, ZIndex = 11, Parent = Pap.chromeGui })
	e.vfTap = new("TextButton", { Name = "PassiveTap", Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "", ZIndex = 11, Parent = e.vfFrame })
	e.vfTap.MouseButton1Click:Connect(function() Pap.tapFocus() end)
	e.focusBox = new("Frame", { Size = UDim2.new(0, 74, 0, 74), BackgroundTransparency = 1, ZIndex = 13, Visible = false, Parent = e.vfFrame })
	UI.stroke(e.focusBox, 1.5, T.gold, 0)
	UI.corner(e.focusBox, 4)
	e.zoomBar = new("Frame", { Size = UDim2.new(0, 190, 0, 30), Position = UDim2.new(0.5, -95, 1, -42), BackgroundColor3 = T.black, BackgroundTransparency = 0.45, BorderSizePixel = 0, ZIndex = 12, Parent = e.vfFrame })
	UI.pill(e.zoomBar)
	UI.list(e.zoomBar, 4, true, Enum.HorizontalAlignment.Center)
	e.zoomChips = {}
	for i, z in ipairs(Pap.zoomLevels) do
		local chip = new("TextButton", { Size = UDim2.new(0, 40, 0, 24), BackgroundColor3 = T.black, BackgroundTransparency = 0.3, Text = "", AutoButtonColor = false, LayoutOrder = i, ZIndex = 13, Parent = e.zoomBar })
		UI.pill(chip)
		local lbl = UI.text(chip, (z < 1 and ".5" or tostring(z)) .. (z == 1 and "x" or ""), { font = T.font.uiBold, size = 12, color = T.white, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 1, 0), z = 14 })
		chip.MouseButton1Click:Connect(function() Pap.zoomT = z Sound.play("click", 0.15) end)
		e.zoomChips[i] = { chip = chip, label = lbl, z = z }
	end
	e.camLbl = UI.text(e.vfFrame, "FRONT", { font = T.font.mono, size = 11, color = T.white, frameSize = UDim2.new(0, 80, 0, 18), pos = UDim2.new(0, 10, 0, 8), stroke = 1, z = 12 })
	e.levelLbl = UI.text(e.vfFrame, "", { font = T.font.mono, size = 11, color = T.gold, frameSize = UDim2.new(0, 120, 0, 18), pos = UDim2.new(1, -130, 0, 8), xalign = Enum.TextXAlignment.Right, stroke = 1, z = 12 })

	-- bottom controls
	e.modeStrip = UI.text(e.phoneFrame, "PORTRAIT     <font color=\"#FFD65A\">PHOTO</font>     VIDEO", { font = T.font.uiBold, size = 12, color = T.white, rich = true, frameSize = UDim2.new(1, 0, 0, 22), pos = UDim2.new(0, 0, 0.805, 0), xalign = Enum.TextXAlignment.Center, z = 12 })
	e.shutterRing = new("Frame", { Size = UDim2.new(0, 78, 0, 78), Position = UDim2.new(0.5, -39, 0.86, 0), BackgroundTransparency = 1, ZIndex = 12, Parent = e.phoneFrame })
	UI.pill(e.shutterRing)
	UI.stroke(e.shutterRing, 3, T.white, 0)
	e.shutter = new("TextButton", { Size = UDim2.new(0, 64, 0, 64), Position = UDim2.new(0.5, -32, 0.5, -32), BackgroundColor3 = T.white, Text = "", AutoButtonColor = false, BorderSizePixel = 0, ZIndex = 13, Parent = e.shutterRing })
	UI.pill(e.shutter)
	e.shutter.MouseButton1Click:Connect(function() Pap.shoot() end)
	e.shutter.MouseButton1Down:Connect(function() tween(e.shutter, { Size = UDim2.new(0, 54, 0, 54), Position = UDim2.new(0.5, -27, 0.5, -27) }, 0.08) end)
	e.shutter.MouseButton1Up:Connect(function() tween(e.shutter, { Size = UDim2.new(0, 64, 0, 64), Position = UDim2.new(0.5, -32, 0.5, -32) }, 0.12) end)
	e.thumb = new("ImageButton", { Size = UDim2.new(0, 52, 0, 52), Position = UDim2.new(0.1, 0, 0.86, 13), BackgroundColor3 = Color3.fromRGB(30, 30, 36), BorderSizePixel = 0, ScaleType = Enum.ScaleType.Crop, ZIndex = 12, Parent = e.phoneFrame })
	UI.corner(e.thumb, 10)
	UI.stroke(e.thumb, 1, T.white, 0.5)
	e.thumb.MouseButton1Click:Connect(function() if Pap.lastThumb then Gallery.open(Pap.lastThumb) end end)
	e.flip = new("TextButton", { Size = UDim2.new(0, 48, 0, 48), Position = UDim2.new(0.9, -48, 0.86, 15), BackgroundColor3 = Color3.fromRGB(40, 40, 48), BackgroundTransparency = 0.2, Text = "", AutoButtonColor = false, BorderSizePixel = 0, ZIndex = 12, Parent = e.phoneFrame })
	UI.pill(e.flip)
	UI.text(e.flip, "⟲", { font = T.font.ui, size = 22, color = T.white, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 1, 0), z = 13 })
	e.flip.MouseButton1Click:Connect(function() Pap.flip() end)

	-- lockscreen overlay inside the phone frame
	e.lock = buildLockscreen(e.phoneFrame, 100, 100, 20)
	e.lock.frame.Size = UDim2.new(1, 0, 1, 0)
	e.lock.frame.Visible = false
	e.lockTap = new("TextButton", { Name = "PassiveLock", Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "", ZIndex = 30, Parent = e.lock.frame })
	e.lockTap.MouseButton1Click:Connect(function() Pap.unlock() end)
	-- black "shutter" blink inside the viewfinder
	e.blink = new("Frame", { Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = T.black, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 15, Parent = e.vfFrame })
	Pap.layout()
end

function Pap.rebuildLockscreen()
	local e = Pap.els
	if not e then return end
	-- the lockscreen scales with the phone frame; relayout the avatar crop for the real size
	local r = Pap.region
	if e.lock and e.lock.frame then e.lock.frame:Destroy() end
	e.lock = buildLockscreen(e.phoneFrame, r.w, r.h, 20)
	e.lock.frame.Size = UDim2.new(1, 0, 1, 0)
	e.lockTap = new("TextButton", { Name = "PassiveLock", Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "", ZIndex = 30, Parent = e.lock.frame })
	e.lockTap.MouseButton1Click:Connect(function() Pap.unlock() end)
end

function Pap.setThumb(item)
	Pap.lastThumb = item
	if Pap.els then
		Pap.els.thumb.Image = item and item.id or ""
		local s = new("UIScale", { Scale = 1.4, Parent = Pap.els.thumb })
		tween(s, { Scale = 1 }, 0.35, Enum.EasingStyle.Back)
		task.delay(0.5, function() s:Destroy() end)
	end
end

function Pap.toggleTorch()
	Phone.setTorch(not Phone.torch)
	if Pap.els then Pap.els.flashBtn.label.TextColor3 = Phone.torch and T.gold or T.text end
	Toast.show(Phone.torch and "flash on ⚡" or "flash off", "info", 1)
end

function Pap.flip()
	Pap.front = not Pap.front
	Pap.camS = nil
	if Pap.els then
		Pap.els.camLbl.Text = Pap.front and "FRONT" or "BACK"
		Pap.els.liveLbl.Text = Pap.front and "SELFIE" or "PHOTO"
	end
	Filter.blackBlink(0.1)
	Sound.play("click", 0.3)
end

function Pap.tapFocus()
	local m = UserInputService:GetMouseLocation()
	local e = Pap.els
	if not e then return end
	-- GetMouseLocation and ViewportPointToRay share viewport space; AbsolutePosition lives in inset space
	local inset = GuiService:GetGuiInset()
	local ray = camera:ViewportPointToRay(m.X, m.Y)
	local hit = Ray.cast(ray.Origin, ray.Direction * 300)
	Filter.setFocus(hit and (hit.Position - ray.Origin).Magnitude or 60)
	local local2 = (m - inset) - e.vfFrame.AbsolutePosition
	e.focusBox.Position = UDim2.new(0, local2.X - 37, 0, local2.Y - 37)
	e.focusBox.Visible = true
	Pap.focusFade = 1.2
	local s = new("UIScale", { Scale = 1.5, Parent = e.focusBox })
	tween(s, { Scale = 1 }, 0.2)
	task.delay(0.3, function() s:Destroy() end)
end

function Pap.shoot()
	if Pap.phase ~= "cam" then return end
	if Gallery.busy then return end
	Sound.play("shutter", 0.6)
	Phone.flashBurst()
	Gallery.capture({
		hide = { Pap.chromeGui, HUD and HUD.gui or nil, Window and Window.gui or nil, Toast.gui },
		label = Pap.front and "SELFIE" or "PHOTO",
		onDone = function(item)
			if Pap.els then
				Pap.els.blink.BackgroundTransparency = 0
				tween(Pap.els.blink, { BackgroundTransparency = 1 }, 0.18)
			end
			if item then
				Pap.setThumb(item)
				Filter.screenFlash(0.6, 0.3)
				Toast.show("📸 saved to gallery · G to view", "ok", 1.8)
			end
		end,
	})
end

function Pap.unlock()
	if Pap.phase ~= "lock" then return end
	Pap.phase = "cam"
	Pap.phaseT = 0
	local e = Pap.els
	Sound.play("swoosh", 0.3)
	tween(e.lock.frame, { Position = UDim2.new(0, 0, -1, 0) }, 0.42, Enum.EasingStyle.Quint)
	task.delay(0.45, function() if e.lock then e.lock.frame.Visible = false end end)
end

function Pap.thirdPersonPose()
	local phoneCF, facePos, headPos = Pap.desiredPhoneCF()
	local base = CFrame.new(headPos) * CFrame.Angles(0, rad(Pap.rootYawS), 0)
	local pos = base:PointToWorldSpace(Vector3.new(2.4, 0.35, -3.4))
	local look = (facePos + phoneCF.Position) / 2
	return CFrame.lookAt(Ray.pullIn(pos, look, 0.5), look), 58
end

defineMode({
	id = "PAPARAZZI", name = "PAPARAZZI", icon = "📱", blurb = "pull out your phone · front camera · selfies · flash · gallery",
	scriptable = true, preset = function() return S.paparazzi.preset end, wantsMouseLock = "rmb",
	keys = {
		{ "Enter", "take the picture" }, { "F", "flash / torch" }, { "V", "flip front / back camera" }, { "G", "open the gallery" },
		{ "RMB drag", "move the arm around your face" }, { "Wheel", "zoom .5x to 5x" }, { "click viewfinder", "tap to focus" },
		{ "W / S", "walk forward / back" }, { "A / D", "turn" }, { "Space", "jump" }, { "X", "put the phone away" },
	},
	enter = function()
		if not Pap.els then Pap.buildUI() end
		Pap.layout()
		Pap.rebuildLockscreen()
		IK.bind()
		Pap.rootYawS = deg(Util.yawOf(Rig.root.CFrame))
		Pap.armYaw, Pap.armPitch = -18, 12
		Pap.armYawS, Pap.armPitchS = -18, 12
		Pap.front = true
		Pap.zoomT, Pap.zoomS, Pap.zoomVel = 1, 1, 0
		Pap.camS = nil
		Pap.lookS = nil
		Pap.phase = "intro3p"
		Pap.phaseT = 0
		Pap.introFrom = camera.CFrame
		Pap.introFromFov = camera.FieldOfView
		Cam.blendT = 1 -- the mode runs its own intro
		Phone.build()
		Phone.setVisible(true)
		IK.handCF = Pap.desiredPhoneCF() * CFG.phoneGrip:Inverse()
		IK.targetWeight = 1
		Body.setControls(false)
		Body.setAutoRotate(true)
		Body.setWalk(nil)
		local e = Pap.els
		e.lock.frame.Position = UDim2.new(0, 0, 0, 0)
		e.lock.frame.Visible = false
		e.camLbl.Text = "FRONT"
		e.liveLbl.Text = "SELFIE"
		e.flashBtn.label.TextColor3 = Phone.torch and T.gold or T.text
		Pap.setThumb(Gallery.items[1])
		Pap.maskGui.Enabled = false
		Pap.chromeGui.Enabled = false
	end,
	exit = function()
		IK.targetWeight = 0
		Pap.phase = "off"
		if Pap.maskGui then Pap.maskGui.Enabled = false end
		if Pap.chromeGui then Pap.chromeGui.Enabled = false end
		Net.sendPose(CFrame.identity, 0, false, 0, true)
		task.delay(0.7, function() if Pap.phase == "off" then Phone.destroy() end end)
	end,
	update = function(dt, t)
		local e = Pap.els
		Pap.phaseT = Pap.phaseT + dt
		-- arm smoothing + phone pose (also drives the IK hand target every frame)
		Pap.armYawS = Util.smooth(Pap.armYawS, Pap.armYaw, 14, dt)
		Pap.armPitchS = Util.smooth(Pap.armPitchS, Pap.armPitch, 14, dt)
		local phoneCF, facePos = Pap.desiredPhoneCF(dt)
		IK.handCF = phoneCF * CFG.phoneGrip:Inverse()
		if Phone.model and Phone.model.Anchored then Phone.model.CFrame = phoneCF end
		Net.sendPose(Rig.root.CFrame:ToObjectSpace(phoneCF), IK.weight, Phone.torch, t)
		if Phone.lock and math.floor(t) ~= math.floor(t - dt) then Phone.lock.tick() end

		-- zoom spring
		Pap.zoomS, Pap.zoomVel = Util.spring(Pap.zoomS, Pap.zoomVel, Pap.zoomT, 120, 22, dt)
		local fov = Pap.fov()

		if Pap.phase == "intro3p" then
			local target, tfov = Pap.thirdPersonPose()
			local a = Util.easeOutCubic(Pap.phaseT / 0.9)
			Cam.cf = Pap.introFrom:Lerp(target, a)
			Cam.fov = Util.lerp(Pap.introFromFov, tfov, a)
			Filter.setFocus((phoneCF.Position - Cam.cf.Position).Magnitude)
			if Pap.phaseT >= 0.9 then
				Pap.phase = "flyin"
				Pap.phaseT = 0
				Pap.introFrom = Cam.cf
				Pap.introFromFov = Cam.fov
			end
			return
		elseif Pap.phase == "flyin" then
			local screenCF = phoneCF * CFrame.new(0, 0, -0.85)
			local target = CFrame.lookAt(screenCF.Position, phoneCF.Position)
			local a = Util.easeInOutCubic(Pap.phaseT / 0.62)
			Cam.cf = Pap.introFrom:Lerp(target, a)
			Cam.fov = Util.lerp(Pap.introFromFov, 34, a)
			Filter.setFocus(0.9)
			if Pap.phaseT >= 0.45 and not Pap.maskGui.Enabled then
				-- lockscreen slides over the 3D phone right before the cut
				Pap.maskGui.Enabled = true
				Pap.chromeGui.Enabled = true
				e.lock.frame.Visible = true
				e.lock.frame.Position = UDim2.new(0, 0, 0.06, 0)
				e.lock.frame.BackgroundTransparency = 0
				tween(e.lock.frame, { Position = UDim2.new(0, 0, 0, 0) }, 0.2)
			end
			if Pap.phaseT >= 0.62 then
				Pap.phase = "lock"
				Pap.phaseT = 0
				Phone.setVisible(false)
				Pap.camS = nil
			end
			return
		end

		-- lock + cam phases: the camera is the phone's camera
		if Pap.phase == "lock" then
			e.lock.tick()
			if Pap.phaseT > 2.4 then Pap.unlock() end
		end
		local lens, target
		if Pap.front then
			lens = phoneCF:PointToWorldSpace(Vector3.new(0, 0.58, -0.06))
			local look = facePos
			Pap.lookS = Pap.lookS and Util.smoothVec(Pap.lookS, look, 18, dt) or look
			target = CFrame.lookAt(lens, Pap.lookS)
		else
			lens = phoneCF:PointToWorldSpace(Vector3.new(-0.15, 0.42, 0.08))
			local outward = Util.safeUnit(phoneCF.Position - facePos)
			target = CFrame.lookAt(lens, lens + outward)
		end
		-- handheld shake
		Pap.shakeT = Pap.shakeT + dt
		local sh = S.paparazzi.shake
		if sh > 0 then
			local n = Util.noise3(Pap.shakeT * 1.4, Pap.seed)
			target = target * CFrame.Angles(rad(n.X * 0.9 * sh), rad(n.Y * 0.9 * sh), rad(n.Z * 0.5 * sh))
		end
		Pap.camS = Pap.camS and Pap.camS:Lerp(target, Util.expAlpha(22, dt)) or target
		Cam.cf = Pap.camS
		Cam.fov = fov
		if Pap.front then Filter.setFocus((facePos - lens).Magnitude) end

		-- walking with the phone out: body-relative controls
		if Pap.phase == "cam" then
			local keys = STATE.keys
			local hum = Rig.humanoid
			local fwd = (keys.W and 1 or 0) - (keys.S and 1 or 0)
			local side = (keys.D and 1 or 0) - (keys.A and 1 or 0)
			local look = Util.safeUnit(Util.flatten(Rig.root.CFrame.LookVector))
			local right = Vector3.new(-look.Z, 0, look.X)
			local move = look * fwd + right * side
			if STATE.runway then Body.setWalk("runway") elseif Body.override == "runway" then Body.setWalk(nil) end
			pcall(function() hum:Move(move.Magnitude > 0 and move.Unit or Vector3.new(), false) end)
			if keys.Space and hum.FloorMaterial ~= Enum.Material.Air then hum.Jump = true end
		end

		-- UI housekeeping
		if Pap.focusFade > 0 then
			Pap.focusFade = Pap.focusFade - dt
			if Pap.focusFade <= 0 then e.focusBox.Visible = false end
		end
		Filter.flashbulbs(dt, facePos)
	end,
	mouse = function(delta)
		if Pap.phase ~= "cam" then return end
		local sens = 0.12 * S.paparazzi.sensitivity
		Pap.armYaw = clamp(Pap.armYaw - delta.X * sens, -70, 55)
		Pap.armPitch = clamp(Pap.armPitch - delta.Y * sens, -35, 60)
	end,
	wheel = function(delta)
		if Pap.phase ~= "cam" then return end
		Pap.zoomT = clamp(Pap.zoomT * math.pow(2, delta * 0.18), 0.5, 5)
	end,
	key = function(code, began)
		if not began then return end
		if Pap.phase == "lock" and code ~= Enum.KeyCode.X then Pap.unlock() return end
		if code == Enum.KeyCode.Return or code == Enum.KeyCode.KeypadEnter then Pap.shoot()
		elseif code == Enum.KeyCode.F then Pap.toggleTorch()
		elseif code == Enum.KeyCode.V then Pap.flip()
		elseif code == Enum.KeyCode.G then if Window then Window.open("GALLERY") end
		end
	end,
	buildHud = function() return {} end,
	tickHud = function()
		local e = Pap.els
		if not e or Pap.phase == "off" then return end
		local vp = camera.ViewportSize
		if Pap.region and (Pap.region.vp.X ~= vp.X or Pap.region.vp.Y ~= vp.Y) then Pap.layout() Pap.rebuildLockscreen() end
		e.status.Text = Util.clock24()
		-- zoom chips
		local best, bestD = 1, 1e9
		for i, c in ipairs(e.zoomChips) do
			local d = math.abs(math.log(c.z) - math.log(Pap.zoomT))
			if d < bestD then best, bestD = i, d end
		end
		for i, c in ipairs(e.zoomChips) do
			local active = i == best
			c.label.TextColor3 = active and T.gold or T.white
			c.chip.BackgroundTransparency = active and 0.1 or 0.6
			if active then c.label.Text = string.format("%.1fx", Pap.zoomT):gsub("%.0x", "x") else c.label.Text = (c.z < 1 and ".5" or tostring(c.z)) end
		end
		e.levelLbl.Text = string.format("%s  %.0f°", Pap.front and "f/1.9" or "f/1.6", Pap.fov())
	end,
})

----------------------------------------------------------------------------
-- 17b. TRIPOD + SPECTATE  (the ring light rig everybody can see, remote phones)
----------------------------------------------------------------------------
local Tripod = {
	lightLevels = { [0] = 0, 1.2, 2.6, 4.5, 7.5 },
	temps = { WARM = Color3.fromRGB(255, 214, 170), NEUTRAL = Color3.fromRGB(255, 244, 228), COOL = Color3.fromRGB(214, 232, 255) },
	phoneOffset = CFrame.new(0, 4.45, 0.15),
	markOffset = Vector3.new(0, 0, -3.6),
}

-- Geometry. Mirrored in ICS2K_Server.lua (keep both in sync). rootCF sits on the floor looking at the performer.
function Tripod.buildModel(rootCF, parent, ownerId)
	local m = new("Model", { Name = "ICS2K_Rig" })
	local function part(name, size, cf, color, material, shape)
		return new("Part", {
			Name = name, Size = size, CFrame = rootCF * cf, Color = color, Material = material or Enum.Material.Metal,
			Shape = shape or Enum.PartType.Block, Anchored = true, CanCollide = false, CanQuery = false, CanTouch = false,
			CastShadow = true, Parent = m,
		})
	end
	local dark = Color3.fromRGB(28, 28, 32)
	local titanium = Color3.fromRGB(168, 166, 158)
	local hub = part("Hub", Vector3.new(0.3, 0.5, 0.5), CFrame.new(0, 0.9, 0) * CFrame.Angles(0, 0, rad(90)), dark, nil, Enum.PartType.Cylinder)
	for i = 1, 3 do
		local a = rad(90 + (i - 1) * 120)
		local foot = Vector3.new(math.cos(a) * 1.15, 0.06, math.sin(a) * 1.15)
		local top = Vector3.new(0, 0.85, 0)
		part("Leg" .. i, Vector3.new(0.1, 0.1, (foot - top).Magnitude), CFrame.lookAt((foot + top) / 2, foot), dark)
		part("Foot" .. i, Vector3.new(0.18, 0.1, 0.18), CFrame.new(foot), Color3.fromRGB(60, 60, 66), Enum.Material.Rubber)
	end
	part("Column", Vector3.new(0.12, 3.5, 0.12), CFrame.new(0, 2.6, 0), dark)
	part("Mount", Vector3.new(0.34, 0.3, 0.3), CFrame.new(0, 4.3, 0.06), dark)
	local phoneCF = Tripod.phoneOffset
	part("JawTop", Vector3.new(0.95, 0.12, 0.22), phoneCF * CFrame.new(0, 0.92, 0.02), dark)
	part("JawBottom", Vector3.new(0.95, 0.12, 0.22), phoneCF * CFrame.new(0, -0.92, 0.02), dark)
	part("Phone", Vector3.new(0.82, 1.72, 0.075), phoneCF, titanium)
	part("Screen", Vector3.new(0.76, 1.64, 0.012), phoneCF * CFrame.new(0, 0, -0.042), Color3.fromRGB(4, 4, 7), Enum.Material.SmoothPlastic)
	part("Plateau", Vector3.new(0.36, 0.36, 0.03), phoneCF * CFrame.new(-0.2, 0.64, 0.05), Color3.fromRGB(150, 148, 140))
	for i, off in ipairs({ Vector3.new(-0.29, 0.73, 0.065), Vector3.new(-0.29, 0.55, 0.065), Vector3.new(-0.11, 0.64, 0.065) }) do
		part("Lens" .. i, Vector3.new(0.035, 0.14, 0.14), phoneCF * CFrame.new(off) * CFrame.Angles(0, rad(90), 0), Color3.fromRGB(10, 10, 14), Enum.Material.Glass, Enum.PartType.Cylinder)
	end
	part("RingArm", Vector3.new(0.08, 1.0, 0.08), CFrame.new(0, 5.35, 0.1), dark)
	local ringCF = CFrame.new(0, 5.85, 0.1) * CFrame.Angles(rad(-12), 0, 0)
	part("RingBack", Vector3.new(0.08, 2.3, 2.3), ringCF * CFrame.new(0, 0, 0.06) * CFrame.Angles(0, rad(90), 0), dark, nil, Enum.PartType.Cylinder)
	part("RingLight", Vector3.new(0.05, 2.2, 2.2), ringCF * CFrame.Angles(0, rad(90), 0), Tripod.temps.NEUTRAL, Enum.Material.Neon, Enum.PartType.Cylinder)
	part("RingCenter", Vector3.new(0.07, 1.3, 1.3), ringCF * CFrame.new(0, 0, -0.012) * CFrame.Angles(0, rad(90), 0), dark, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	for i = 1, 16 do
		local a = rad((i - 1) * 22.5)
		local p = Tripod.markOffset + Vector3.new(math.cos(a) * 1.25, 0.03, math.sin(a) * 1.25)
		part("Mark" .. i, Vector3.new(0.5, 0.04, 0.2), CFrame.new(p) * CFrame.Angles(0, -(a + math.pi / 2), 0), Color3.fromRGB(0, 229, 255), Enum.Material.Neon)
	end
	m.PrimaryPart = hub
	m:SetAttribute("Owner", ownerId)
	m:SetAttribute("Light", 2)
	m:SetAttribute("Temp", "NEUTRAL")
	m:SetAttribute("Rec", false)
	m.Parent = parent
	return m
end

-- The phone screen bystanders see: LIVE badge, viewers, hearts, REC timer.
function Tripod.liveScreen(gui, h)
	local w, hgt = 274, 590
	local bg = new("Frame", { Size = UDim2.new(0, w, 0, hgt), BackgroundColor3 = Color3.fromRGB(8, 8, 12), BorderSizePixel = 0, ClipsDescendants = true, Parent = gui })
	UI.gradient(bg, ColorSequence.new(Color3.fromRGB(22, 16, 36), Color3.fromRGB(6, 6, 10)), 90)
	local owner = h.owner and Players:GetPlayerByUserId(h.owner)
	UI.text(bg, owner and ("@" .. owner.Name) or "@live", { font = T.font.uiBold, size = 16, color = T.white, frameSize = UDim2.new(1, -20, 0, 24), pos = UDim2.new(0, 12, 0, 40), z = 2 })
	local live = new("Frame", { Size = UDim2.new(0, 52, 0, 20), Position = UDim2.new(1, -64, 0, 42), BackgroundColor3 = Color3.fromRGB(254, 44, 85), BorderSizePixel = 0, ZIndex = 2, Parent = bg })
	UI.corner(live, 5)
	UI.text(live, "LIVE", { font = T.font.uiBold, size = 12, color = T.white, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 1, 0), z = 3 })
	local viewers = UI.text(bg, "", { font = T.font.ui, size = 13, color = T.white, frameSize = UDim2.new(1, -20, 0, 20), pos = UDim2.new(0, 12, 0, 66), z = 2 })
	local rec = UI.text(bg, "", { font = T.font.mono, size = 15, color = Color3.fromRGB(254, 44, 85), frameSize = UDim2.new(1, -20, 0, 22), pos = UDim2.new(0, 12, 0, 92), z = 2 })
	UI.text(bg, "♪ ICS2K · original sound", { font = T.font.ui, size = 12, color = T.white, frameSize = UDim2.new(1, -20, 0, 18), pos = UDim2.new(0, 12, 1, -40), transparency = 0.2, z = 2 })
	local count = rng:NextInteger(40, 320)
	local heartClock = 0
	h.anim = UI.animate(function(t, dt)
		if not bg.Parent then return error("dead") end
		if rng:NextNumber() < 0.08 then count = math.max(1, count + rng:NextInteger(-2, 5)) end
		viewers.Text = "👁 " .. count
		if h.recStart then
			local blink = math.floor(t * 2) % 2 == 0
			rec.Text = (blink and "● " or "   ") .. "REC " .. Util.fmtTime(os.clock() - h.recStart)
		else
			rec.Text = ""
		end
		heartClock = heartClock - dt
		if heartClock <= 0 and S.tiktok.hearts then
			heartClock = rng:NextNumber(0.5, 1.4)
			local colors = { T.magenta, T.danger, T.lavender, T.white }
			local heart = UI.text(bg, "❤", { font = T.font.ui, size = rng:NextInteger(16, 26), color = colors[rng:NextInteger(1, 4)], frameSize = UDim2.new(0, 30, 0, 30), pos = UDim2.new(0.78 + rng:NextNumber(-0.08, 0.08), 0, 0.86, 0), xalign = Enum.TextXAlignment.Center, z = 3 })
			tween(heart, { Position = UDim2.new(0.78 + rng:NextNumber(-0.15, 0.15), 0, 0.35, 0), TextTransparency = 1 }, rng:NextNumber(1.6, 2.6))
			task.delay(2.7, function() heart:Destroy() end)
		end
	end)
	return { frame = bg }
end

-- Lights, screen UI and attribute listeners for any rig model (server-owned or local).
function Tripod.decorate(model)
	local maid = Maid.new()
	local h = { model = model, maid = maid, owner = model:GetAttribute("Owner"), recStart = nil }
	local ring = model:FindFirstChild("RingLight")
	local screen = model:FindFirstChild("Screen")
	if ring then
		h.spot = maid:give(new("SpotLight", { Face = Enum.NormalId.Right, Angle = 95, Range = 18, Brightness = 2.6, Color = Tripod.temps.NEUTRAL, Shadows = true, Parent = ring }))
		h.point = maid:give(new("PointLight", { Range = 9, Brightness = 0.8, Color = Tripod.temps.NEUTRAL, Shadows = false, Parent = ring }))
	end
	if screen then
		local gui = maid:give(new("SurfaceGui", { Name = "LiveGui", Face = Enum.NormalId.Front, LightInfluence = 0, Brightness = 1.4, PixelsPerStud = 360, SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud, Parent = screen }))
		h.live = Tripod.liveScreen(gui, h)
	end
	local function applyLight()
		local level = clamp(math.floor((tonumber(model:GetAttribute("Light")) or 2) + 0.5), 0, 4)
		local temp = Tripod.temps[model:GetAttribute("Temp")] or Tripod.temps.NEUTRAL
		local b = Tripod.lightLevels[level] or 0
		if h.spot then
			h.spot.Brightness = b
			h.spot.Color = temp
			h.point.Brightness = b * 0.3
			h.point.Color = temp
		end
		if ring then
			ring.Color = temp
			ring.Material = level > 0 and Enum.Material.Neon or Enum.Material.SmoothPlastic
		end
		h.level = level
	end
	local function applyRec()
		h.recStart = model:GetAttribute("Rec") and os.clock() or nil
	end
	maid:give(model:GetAttributeChangedSignal("Light"):Connect(applyLight))
	maid:give(model:GetAttributeChangedSignal("Temp"):Connect(applyLight))
	maid:give(model:GetAttributeChangedSignal("Rec"):Connect(applyRec))
	applyLight()
	applyRec()
	return h
end

-- Assembly: everything rises out of the hub with a bounce, then the ring flickers on.
function Tripod.animateIn(model)
	local parts = {}
	for _, p in ipairs(model:GetChildren()) do if p:IsA("BasePart") then table.insert(parts, p) end end
	local hub = model.PrimaryPart or parts[1]
	if not hub then return end
	local base = hub.CFrame
	for _, p in ipairs(parts) do
		local final = p.CFrame
		local finalT = p.Transparency
		p.Transparency = 1
		p.CFrame = CFrame.new(base.Position + Vector3.new(0, -0.6, 0)) * final.Rotation
		local wait = 0.05 + math.max(0, final.Position.Y - base.Position.Y) * 0.09 + rng:NextNumber(0, 0.06)
		task.delay(wait, function()
			if not p.Parent then return end
			tween(p, { CFrame = final, Transparency = finalT }, 0.55, Enum.EasingStyle.Back)
		end)
	end
	task.delay(0.95, function()
		local ring = model:FindFirstChild("RingLight")
		local spot = ring and ring:FindFirstChildOfClass("SpotLight")
		if not spot then return end
		local target = spot.Brightness
		for i = 1, 4 do
			spot.Brightness = (i % 2 == 0) and target or 0
			task.wait(0.07)
		end
		spot.Brightness = target
	end)
end

function Tripod.animateOut(model, onDone)
	for _, p in ipairs(model:GetChildren()) do
		if p:IsA("BasePart") then tween(p, { Transparency = 1 }, 0.3) end
	end
	task.delay(0.32, function() if onDone then onDone() end end)
end

local Spectate = { rigs = {}, phones = {}, folder = nil }

function Spectate.onRig(model)
	if Spectate.rigs[model] then return end
	Spectate.rigs[model] = { pending = true, maid = Maid.new() }
	task.spawn(function()
		-- a replicated model can arrive before all of its parts have; wait for the ones we decorate
		model:WaitForChild("RingLight", 3)
		model:WaitForChild("Screen", 3)
		model:WaitForChild("Phone", 3)
		if not model.Parent or not Spectate.rigs[model] then return end
		local ok, h = pcall(Tripod.decorate, model)
		if not ok then
			warn("[ICS2K] rig decorate: " .. tostring(h))
			Spectate.rigs[model] = nil
			return
		end
		Spectate.rigs[model] = h
		pcall(Tripod.animateIn, model)
		Ray.dirty = true
	end)
end

function Spectate.offRig(model)
	local h = Spectate.rigs[model]
	if not h then return end
	if h.maid then h.maid:clean() end
	if h.anim then h.anim.alive = false end
	Spectate.rigs[model] = nil
end

function Spectate.watch(folder)
	Spectate.folder = folder
	for _, m in ipairs(folder:GetChildren()) do if m:IsA("Model") then Spectate.onRig(m) end end
	folder.ChildAdded:Connect(function(m)
		if m:IsA("Model") then task.defer(function() Spectate.onRig(m) end) end
	end)
	folder.ChildRemoved:Connect(function(m) Spectate.offRig(m) end)
end

function Spectate.findOwnRig()
	if not Spectate.folder then return nil end
	for _, m in ipairs(Spectate.folder:GetChildren()) do
		if m:GetAttribute("Owner") == player.UserId then return m end
	end
	return nil
end

function Spectate.dropPhone(p)
	local e = Spectate.phones[p]
	if not e then return end
	pcall(function() e.ik:releaseJoints() end)
	e.phone.destroy()
	Spectate.phones[p] = nil
end

function Spectate.init()
	local f = Workspace:FindFirstChild("ICS2K_Rigs")
	if f then
		Spectate.watch(f)
	else
		Workspace.ChildAdded:Connect(function(c)
			if c.Name == "ICS2K_Rigs" and not Spectate.folder then Spectate.watch(c) end
		end)
	end
	-- somebody else pulled out their phone: pose their arm and give them a phone, locally
	Net.onPose = function(p, rel, w, torch)
		if p == player or typeof(rel) ~= "CFrame" then return end
		local c = p.Character
		if not c then return end
		local entry = Spectate.phones[p]
		if not entry or entry.char ~= c then
			if entry then Spectate.dropPhone(p) end
			local ik = ArmIK.new()
			ik:bindTo(c, c:FindFirstChildOfClass("Humanoid"))
			local phone = Phone.create(ik.rig and ik.hand or nil, ik.rig, p.UserId, localFolder())
			entry = { char = c, ik = ik, phone = phone, rel = rel, lastSeen = os.clock(), created = os.clock() }
			Spectate.phones[p] = entry
		end
		entry.rel = rel
		entry.ik.targetWeight = clamp(tonumber(w) or 0, 0, 1)
		entry.lastSeen = os.clock()
		entry.phone.setTorch(torch and true or false, 2)
	end
	Players.PlayerRemoving:Connect(function(p) Spectate.dropPhone(p) end)
end

function Spectate.tick(dt)
	local now = os.clock()
	for p, e in pairs(Spectate.phones) do
		local root = e.char and e.char:FindFirstChild("HumanoidRootPart")
		local stale = now - e.lastSeen > 3
		local lowered = e.ik.targetWeight <= 0 and e.ik.weight <= 0.01 and now - e.created > 1
		if not root or not e.char.Parent or stale or lowered then
			Spectate.dropPhone(p)
		else
			e.ik.handCF = root.CFrame * e.rel * CFG.phoneGrip:Inverse()
			e.ik:tickWeight(dt)
			if e.phone.model and e.phone.model.Anchored then e.phone.model.CFrame = root.CFrame * e.rel end
		end
	end
end

function Spectate.step()
	for _, e in pairs(Spectate.phones) do
		if e.ik.weight > 0 then pcall(function() e.ik:stepJoints() end) end
	end
end

----------------------------------------------------------------------------
-- 17c. MODE: TIKTOK  (ring light tripod, auto walk to the mark, phone POV, emotes, clips)
----------------------------------------------------------------------------
local Tik = {
	phase = "off", phaseT = 0, rig = nil, rigLocal = false, rigCF = nil, mark = nil, phoneCF = nil, spawnT = 0,
	zoomT = 1, zoomS = 1, zoomVel = 0, wide = false, autoT = 0, autoTarget = 1, autoS = 1, punch = 0, stageS = 1,
	lookS = nil, camS = nil, btsT = 0, rec = false, recT = 0, recDur = 15, recIds = {}, recNext = 0,
	timer = 0, timerT = 0, emotesOpen = false, els = nil, light = 2, temp = "NEUTRAL", fovS = 62, filterIdx = 1,
	walkDone = false, walkConn = nil, hintShown = false, lastClip = nil, shell = nil,
}
local TIK_EMOTES = { { "wave", "👋" }, { "point", "👉" }, { "dance", "💃" }, { "dance2", "🕺" }, { "dance3", "✨" }, { "cheer", "🙌" }, { "laugh", "😂" } }
local TIK_TEMPS = { "WARM", "NEUTRAL", "COOL" }
local TIK_FILTERS = { { "PORTRAIT", "natural" }, { "DREAM", "dream" }, { "Y2K", "y2k" }, { "KODAK", "film" }, { "NOIR", "noir" } }

-- Full screen phone shell (dark mask around a portrait phone with a viewfinder cut-out).
local function buildPhoneShell(prefix, order, vfAspect, topFrac)
	local shell = { els = {} }
	shell.maskGui = new("ScreenGui", { Name = prefix .. "Mask", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = order, Enabled = false, Parent = playerGui })
	shell.chromeGui = new("ScreenGui", { Name = prefix .. "Chrome", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = order + 10, Enabled = false, Parent = playerGui })
	local e = shell.els
	local dark = Color3.fromRGB(5, 5, 8)
	local function mask(name) return new("Frame", { Name = name, BackgroundColor3 = dark, BorderSizePixel = 0, ZIndex = 1, Parent = shell.maskGui }) end
	e.maskL, e.maskR, e.maskT, e.maskB = mask("L"), mask("R"), mask("T"), mask("B")
	for _, m in ipairs({ e.maskL, e.maskR }) do UI.gradient(m, ColorSequence.new(Color3.fromRGB(10, 9, 16), dark), 90) end
	e.bezel = new("Frame", { Name = "Bezel", BackgroundTransparency = 1, ZIndex = 3, Parent = shell.maskGui })
	UI.corner(e.bezel, 46)
	UI.gradient(UI.stroke(e.bezel, 4, T.white, 0.05), T.chrome, 90)
	e.phoneFrame = new("Frame", { Name = "Phone", BackgroundTransparency = 1, ClipsDescendants = true, ZIndex = 10, Parent = shell.chromeGui })
	UI.corner(e.phoneFrame, 46)
	e.vfFrame = new("Frame", { Name = "Viewfinder", BackgroundTransparency = 1, ZIndex = 11, Parent = shell.chromeGui })
	function shell.layout()
		local vp = camera.ViewportSize
		local phoneH = vp.Y * 0.965
		local phoneW = phoneH * (9 / 19.5)
		if phoneW > vp.X * 0.92 then
			phoneW = vp.X * 0.92
			phoneH = phoneW * (19.5 / 9)
		end
		local x0 = (vp.X - phoneW) / 2
		local y0 = (vp.Y - phoneH) / 2
		local vfW = phoneW
		local vfH = math.min(phoneW * vfAspect, phoneH * 0.86)
		local vfY = y0 + phoneH * topFrac
		shell.region = { x0 = x0, y0 = y0, w = phoneW, h = phoneH, vfX = x0, vfY = vfY, vfW = vfW, vfH = vfH, vp = vp }
		e.maskL.Size = UDim2.new(0, x0, 1, 0)
		e.maskR.Size = UDim2.new(0, vp.X - (x0 + phoneW), 1, 0)
		e.maskR.Position = UDim2.new(0, x0 + phoneW, 0, 0)
		e.maskT.Size = UDim2.new(0, phoneW, 0, vfY)
		e.maskT.Position = UDim2.new(0, x0, 0, 0)
		e.maskB.Size = UDim2.new(0, phoneW, 0, vp.Y - (vfY + vfH))
		e.maskB.Position = UDim2.new(0, x0, 0, vfY + vfH)
		e.bezel.Size = UDim2.new(0, phoneW, 0, phoneH)
		e.bezel.Position = UDim2.new(0, x0, 0, y0)
		e.phoneFrame.Size = UDim2.new(0, phoneW, 0, phoneH)
		e.phoneFrame.Position = UDim2.new(0, x0, 0, y0)
		e.vfFrame.Size = UDim2.new(0, vfW, 0, vfH)
		e.vfFrame.Position = UDim2.new(0, x0, 0, vfY)
		if shell.onLayout then shell.onLayout(shell.region) end
	end
	function shell.setEnabled(v)
		shell.maskGui.Enabled = v
		shell.chromeGui.Enabled = v
	end
	shell.layout()
	return shell
end

function Tik.buildUI()
	local shell = buildPhoneShell("ICS2K_Tik", 250, 16 / 9, 0.06)
	Tik.shell = shell
	local e = shell.els
	Tik.els = e
	local pf, vf = e.phoneFrame, e.vfFrame
	local glass = Color3.fromRGB(20, 20, 26)
	local tikRed = Color3.fromRGB(254, 44, 85)
	local function roundBtn(parent, glyph, pos, size, onClick, name)
		local b = new("TextButton", { Name = name or "Btn", Size = UDim2.new(0, size, 0, size), Position = pos, BackgroundColor3 = glass, BackgroundTransparency = 0.35, Text = "", AutoButtonColor = false, BorderSizePixel = 0, ZIndex = 13, Parent = parent })
		UI.pill(b)
		UI.stroke(b, 1, T.white, 0.75)
		local l = UI.text(b, glyph, { font = T.font.ui, size = math.floor(size * 0.42), color = T.white, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 1, 0), z = 14 })
		b.MouseButton1Click:Connect(function() Sound.play("click", 0.2) onClick() end)
		return { btn = b, label = l }
	end
	e.hints = UI.text(shell.chromeGui, "ENTER  record   SPACE  jump   .  emote menu\nW S  walk   A D  turn   wheel / − +  zoom\nL  light   T  colour   V  wide   Z  auto zoom\nN  center stage   F  filter   X  pack up", {
		font = T.font.mono, size = 13, color = T.muted, frameSize = UDim2.new(0, 310, 0, 100), pos = UDim2.new(0, 18, 1, -110), yalign = Enum.TextYAlignment.Bottom, z = 5,
	})
	e.brand = UI.text(shell.chromeGui, "ICS2K ✦ TIKTOK STUDIO", { font = T.font.head, size = 10, color = T.lavender, frameSize = UDim2.new(0, 240, 0, 20), pos = UDim2.new(1, -18, 1, -40), anchor = Vector2.new(1, 0), xalign = Enum.TextXAlignment.Right, z = 5 })
	-- status bar + island
	e.status = UI.text(pf, "", { font = T.font.ui, size = 14, color = T.white, frameSize = UDim2.new(0.3, 0, 0, 24), pos = UDim2.new(0.07, 0, 0, 10), z = 12 })
	UI.text(pf, "▮▮▮  5G  ▭", { font = T.font.ui, size = 12, color = T.white, frameSize = UDim2.new(0.32, 0, 0, 24), pos = UDim2.new(0.61, 0, 0, 10), xalign = Enum.TextXAlignment.Right, z = 12 })
	local island = new("Frame", { Size = UDim2.new(0.3, 0, 0, 24), Position = UDim2.new(0.35, 0, 0, 12), BackgroundColor3 = T.black, BorderSizePixel = 0, ZIndex = 12, Parent = pf })
	UI.pill(island)
	UI.stroke(island, 1, Color3.fromRGB(40, 40, 48), 0)
	-- viewfinder top: progress, close, sound pill, rec label
	e.progress = new("Frame", { Size = UDim2.new(0, 0, 0, 4), BackgroundColor3 = tikRed, BorderSizePixel = 0, Visible = false, ZIndex = 14, Parent = vf })
	e.closeBtn = roundBtn(vf, "✕", UDim2.new(0, 10, 0, 14), 36, function() setMode("STANDARD") end, "CloseBtn")
	e.sound = new("Frame", { Size = UDim2.new(0, 190, 0, 30), Position = UDim2.new(0.5, -95, 0, 17), BackgroundColor3 = glass, BackgroundTransparency = 0.35, BorderSizePixel = 0, ZIndex = 13, Parent = vf })
	UI.pill(e.sound)
	UI.text(e.sound, "♪  ICS2K · original sound", { font = T.font.ui, size = 12, color = T.white, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 1, 0), z = 14 })
	e.recLbl = UI.text(vf, "", { font = T.font.mono, size = 15, color = tikRed, frameSize = UDim2.new(0, 160, 0, 20), pos = UDim2.new(0, 14, 0, 58), stroke = 1, z = 14 })
	-- right column: smart features
	local col = {
		{ "💡", "LIGHT", function() Tik.cycleLight() end },
		{ "☀", "TEMP", function() Tik.cycleTemp() end },
		{ ".5", "WIDE", function() Tik.toggleWide() end },
		{ "↕", "AUTO", function() Tik.toggleAuto() end },
		{ "◎", "STAGE", function() Tik.toggleStage() end },
		{ "✦", "FILTER", function() Tik.cycleFilter() end },
		{ "◴", "TIMER", function() Tik.cycleTimer() end },
	}
	e.colBtns = {}
	for i, c in ipairs(col) do
		local y = 64 + (i - 1) * 56
		local b = roundBtn(vf, c[1], UDim2.new(1, -52, 0, y), 40, c[3], c[2] .. "Btn")
		UI.text(vf, c[2], { font = T.font.head, size = 7, color = T.white, frameSize = UDim2.new(0, 60, 0, 12), pos = UDim2.new(1, -62, 0, y + 41), xalign = Enum.TextXAlignment.Center, stroke = 1, z = 13 })
		e.colBtns[c[2]] = b
	end
	e.lightDots = UI.text(vf, "", { font = T.font.mono, size = 9, color = T.gold, frameSize = UDim2.new(0, 60, 0, 12), pos = UDim2.new(1, -62, 0, 64 + 51), xalign = Enum.TextXAlignment.Center, z = 14 })
	-- zoom row + duration chips at the bottom of the viewfinder
	e.zoomRow = new("Frame", { Size = UDim2.new(0, 260, 0, 32), Position = UDim2.new(0.5, -130, 1, -92), BackgroundTransparency = 1, ZIndex = 12, Parent = vf })
	UI.list(e.zoomRow, 6, true, Enum.HorizontalAlignment.Center)
	e.zoomChips = {}
	local function chip(text, order, onClick, name)
		local c = new("TextButton", { Name = name or "Chip", Size = UDim2.new(0, 42, 0, 26), BackgroundColor3 = T.black, BackgroundTransparency = 0.45, Text = "", AutoButtonColor = false, BorderSizePixel = 0, LayoutOrder = order, ZIndex = 13, Parent = e.zoomRow })
		UI.pill(c)
		local l = UI.text(c, text, { font = T.font.uiBold, size = 12, color = T.white, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 1, 0), z = 14 })
		c.MouseButton1Click:Connect(function() Sound.play("click", 0.15) onClick() end)
		return { chip = c, label = l }
	end
	e.zoomOut = chip("−", 1, function() Tik.zoomBy(-1) end, "ZoomOutBtn")
	for i, z in ipairs({ 0.5, 1, 2 }) do
		local c = chip(z < 1 and ".5x" or (z .. "x"), 1 + i, function() Tik.zoomT = z end)
		c.z = z
		table.insert(e.zoomChips, c)
	end
	e.zoomIn = chip("+", 5, function() Tik.zoomBy(1) end, "ZoomInBtn")
	e.durRow = new("Frame", { Size = UDim2.new(0, 200, 0, 22), Position = UDim2.new(0.5, -100, 1, -52), BackgroundTransparency = 1, ZIndex = 12, Parent = vf })
	UI.list(e.durRow, 10, true, Enum.HorizontalAlignment.Center)
	e.durBtns = {}
	for i, d in ipairs({ { 15, "15s" }, { 60, "60s" }, { 180, "3m" } }) do
		local b = new("TextButton", { Size = UDim2.new(0, 44, 0, 22), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, LayoutOrder = i, ZIndex = 13, Parent = e.durRow })
		local l = UI.text(b, d[2], { font = T.font.uiBold, size = 13, color = T.white, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 1, 0), stroke = 1, z = 14 })
		b.MouseButton1Click:Connect(function() Tik.recDur = d[1] Tik.refreshUI() end)
		e.durBtns[d[1]] = l
	end
	-- bottom band: emotes, record, gallery
	e.emoteBtn = roundBtn(pf, "😀", UDim2.new(0.12, 0, 0.885, 0), 48, function() Tik.toggleEmotes() end, "EmoteBtn")
	UI.text(pf, "Emotes", { font = T.font.ui, size = 10, color = T.white, frameSize = UDim2.new(0, 60, 0, 14), pos = UDim2.new(0.12, -6, 0.885, 50), xalign = Enum.TextXAlignment.Center, z = 12 })
	e.recRing = new("Frame", { Size = UDim2.new(0, 82, 0, 82), Position = UDim2.new(0.5, -41, 0.873, 0), BackgroundTransparency = 1, ZIndex = 12, Parent = pf })
	UI.pill(e.recRing)
	UI.stroke(e.recRing, 4, T.white, 0.15)
	e.recBtn = new("TextButton", { Name = "RecBtn", Size = UDim2.new(0, 64, 0, 64), Position = UDim2.new(0.5, -32, 0.5, -32), BackgroundColor3 = tikRed, Text = "", AutoButtonColor = false, BorderSizePixel = 0, ZIndex = 13, Parent = e.recRing })
	e.recCorner = UI.pill(e.recBtn)
	e.recBtn.MouseButton1Click:Connect(function() Tik.toggleRec() end)
	e.thumb = new("ImageButton", { Name = "Thumb", Size = UDim2.new(0, 48, 0, 48), Position = UDim2.new(0.88, -48, 0.885, 0), BackgroundColor3 = Color3.fromRGB(30, 30, 36), BorderSizePixel = 0, ScaleType = Enum.ScaleType.Crop, ZIndex = 12, Parent = pf })
	UI.corner(e.thumb, 10)
	UI.stroke(e.thumb, 1, T.white, 0.5)
	e.thumb.MouseButton1Click:Connect(function() Window.open("GALLERY") end)
	UI.text(pf, "Upload", { font = T.font.ui, size = 10, color = T.white, frameSize = UDim2.new(0, 60, 0, 14), pos = UDim2.new(0.88, -54, 0.885, 50), xalign = Enum.TextXAlignment.Center, z = 12 })
	-- emote strip
	e.emoteStrip = new("Frame", { Size = UDim2.new(1, -20, 0, 48), Position = UDim2.new(0, 10, 1, -148), BackgroundColor3 = glass, BackgroundTransparency = 0.3, BorderSizePixel = 0, Visible = false, ZIndex = 15, Parent = vf })
	UI.pill(e.emoteStrip)
	UI.list(e.emoteStrip, 4, true, Enum.HorizontalAlignment.Center)
	for i, em in ipairs(TIK_EMOTES) do
		local b = new("TextButton", { Name = "Emote_" .. em[1], Size = UDim2.new(0, 42, 0, 40), BackgroundColor3 = T.black, BackgroundTransparency = 0.5, Text = "", AutoButtonColor = false, BorderSizePixel = 0, LayoutOrder = i, ZIndex = 16, Parent = e.emoteStrip })
		UI.pill(b)
		UI.text(b, em[2], { font = T.font.ui, size = 18, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 0, 26), z = 17 })
		UI.text(b, em[1], { font = T.font.ui, size = 8, color = T.white, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 0, 10), pos = UDim2.new(0, 0, 0, 27), z = 17 })
		b.MouseButton1Click:Connect(function() Tik.emote(em[1]) end)
	end
	-- countdown, splash, blink, passive tap
	e.countdown = UI.text(vf, "", { font = T.font.big, size = 120, color = T.white, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 1, 0), stroke = 2, z = 18 })
	e.splash = new("Frame", { Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = T.black, BorderSizePixel = 0, Visible = false, ZIndex = 25, Parent = pf })
	UI.text(e.splash, "♪", { font = T.font.big, size = 90, color = T.white, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 0, 120), pos = UDim2.new(0, 0, 0.36, 0), z = 26 })
	UI.text(e.splash, "ICS2K  LIVE  STUDIO", { font = T.font.head, size = 12, color = T.lavender, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 0, 20), pos = UDim2.new(0, 0, 0.56, 0), z = 26 })
	e.blink = new("Frame", { Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = T.black, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 15, Parent = vf })
	e.tap = new("TextButton", { Name = "PassiveTap", Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "", ZIndex = 11, Parent = vf })
	shell.onLayout = function(r)
		e.hints.Visible = r.x0 > 200
		e.brand.Visible = r.x0 > 160
	end
	shell.onLayout(shell.region)
	Tik.refreshUI()
end

function Tik.setRigAttr(key, value)
	if Tik.rigLocal then
		if Tik.rig then Tik.rig:SetAttribute(key, value) end
	else
		Net.sendRig("attr", { key = key, value = value })
	end
end

function Tik.cycleLight()
	Tik.light = (Tik.light + 1) % 5
	S.tiktok.light = Tik.light
	Tik.setRigAttr("Light", Tik.light)
	Tik.refreshUI()
	Toast.show("ring light " .. Tik.light .. " / 4", "info", 1)
end

function Tik.cycleTemp()
	local i = 1
	for k, v in ipairs(TIK_TEMPS) do if v == Tik.temp then i = k end end
	Tik.temp = TIK_TEMPS[(i % #TIK_TEMPS) + 1]
	S.tiktok.temp = Tik.temp
	Tik.setRigAttr("Temp", Tik.temp)
	Tik.refreshUI()
end

function Tik.toggleWide() Tik.wide = not Tik.wide Tik.refreshUI() end
function Tik.toggleAuto()
	S.tiktok.autoZoom = not S.tiktok.autoZoom
	Tik.refreshUI()
	Toast.show(S.tiktok.autoZoom and "auto zoom on" or "auto zoom off", "info", 1)
end
function Tik.toggleStage()
	S.tiktok.centerStage = not S.tiktok.centerStage
	Tik.refreshUI()
	Toast.show(S.tiktok.centerStage and "center stage on" or "center stage off", "info", 1)
end
function Tik.cycleFilter()
	Tik.filterIdx = (Tik.filterIdx % #TIK_FILTERS) + 1
	local f = TIK_FILTERS[Tik.filterIdx]
	S.tiktok.preset = f[1]
	if S.filter.lock then Toast.show("filter is locked in the window", "error", 1.5) return end
	Filter.requestPreset(f[1])
	Toast.show("filter ✦ " .. f[2], "info", 1)
end
function Tik.cycleTimer()
	Tik.timer = ({ [0] = 3, [3] = 10, [10] = 0 })[Tik.timer] or 0
	Tik.refreshUI()
end
function Tik.zoomBy(dir) Tik.zoomT = clamp(Tik.zoomT * math.pow(2, dir * 0.25), 0.5, 4) end
function Tik.toggleEmotes()
	Tik.emotesOpen = not Tik.emotesOpen
	if Tik.els then Tik.els.emoteStrip.Visible = Tik.emotesOpen end
end
function Tik.emote(name)
	local ok, played = pcall(function() return Rig.humanoid:PlayEmote(name) end)
	if not (ok and played) then Toast.show("emote '" .. name .. "' is not available here · try the . menu", "error", 2) end
end

function Tik.toggleRec()
	if Tik.phase ~= "live" then return end
	if Tik.rec then Tik.stopRec(false) return end
	if Tik.timerT > 0 then Tik.timerT = 0 if Tik.els then Tik.els.countdown.Text = "" end return end
	if Tik.timer > 0 then Tik.timerT = Tik.timer return end
	Tik.startRec()
end

function Tik.startRec()
	Tik.rec = true
	Tik.recT = 0
	Tik.recIds = {}
	Tik.recNext = 0.2
	Tik.setRigAttr("Rec", true)
	Sound.play("ping", 0.3)
	Tik.refreshUI()
end

function Tik.stopRec(auto)
	if not Tik.rec then return end
	Tik.rec = false
	Tik.setRigAttr("Rec", false)
	local ids = Tik.recIds
	Tik.recIds = {}
	if #ids >= 1 then
		local item = Gallery.addClip(ids, "TIKTOK")
		Tik.lastClip = item
		Toast.show(string.format("clip saved · %d frames · gallery → SAVE TO DEVICE", #ids), "ok", 3)
		if not Tik.hintShown then
			Tik.hintShown = true
			Toast.show("for a real video file use the Roblox menu: Esc → Record Video (Windows)", "info", 5)
		end
	else
		Toast.show(auto and "clip ended" or "recording stopped", "info", 1.5)
	end
	Tik.refreshUI()
end

function Tik.refreshUI()
	local e = Tik.els
	if not e then return end
	e.lightDots.Text = string.rep("●", Tik.light) .. string.rep("○", 4 - Tik.light)
	e.colBtns.TEMP.label.Text = ({ WARM = "3200K", NEUTRAL = "4500K", COOL = "5600K" })[Tik.temp] or "☀"
	e.colBtns.TEMP.label.TextSize = 10
	e.colBtns.WIDE.label.TextColor3 = Tik.wide and T.gold or T.white
	e.colBtns.AUTO.label.TextColor3 = S.tiktok.autoZoom and T.gold or T.white
	e.colBtns.STAGE.label.TextColor3 = S.tiktok.centerStage and T.gold or T.white
	e.colBtns.TIMER.label.Text = Tik.timer > 0 and (Tik.timer .. "s") or "◴"
	e.colBtns.TIMER.label.TextSize = Tik.timer > 0 and 12 or 17
	for d, l in pairs(e.durBtns) do l.TextColor3 = (d == Tik.recDur) and T.gold or T.white end
	if Tik.rec then
		e.recBtn.Size = UDim2.new(0, 36, 0, 36)
		e.recBtn.Position = UDim2.new(0.5, -18, 0.5, -18)
		e.recCorner.CornerRadius = UDim.new(0, 8)
	else
		e.recBtn.Size = UDim2.new(0, 64, 0, 64)
		e.recBtn.Position = UDim2.new(0.5, -32, 0.5, -32)
		e.recCorner.CornerRadius = UDim.new(1, 0)
	end
	e.progress.Visible = Tik.rec
	local latest = Tik.lastClip or Gallery.items[1]
	e.thumb.Image = latest and latest.id or ""
end

-- Where the tripod and the mark go: in front of you, never through a wall, on the floor.
function Tik.placeRig()
	local rootPos = Rig.root.Position
	local F = Util.safeUnit(Util.flatten(Rig.root.CFrame.LookVector))
	local dist = clamp(S.tiktok.markDistance, 5, 12)
	local hit = Ray.cast(rootPos + Vector3.new(0, 1, 0), F * (dist + 1))
	if hit then dist = math.max(4.5, (hit.Position - rootPos).Magnitude - 1.5) end
	local tripodPos = rootPos + F * dist
	local floorY = Ray.groundY(tripodPos + Vector3.new(0, 2, 0), 14) or (rootPos.Y - 3)
	tripodPos = Vector3.new(tripodPos.X, floorY, tripodPos.Z)
	local markPos = rootPos + F * math.max(1.2, dist - 3.6)
	local markY = Ray.groundY(markPos + Vector3.new(0, 2, 0), 14) or floorY
	Tik.rigCF = CFrame.lookAt(tripodPos, Vector3.new(markPos.X, floorY, markPos.Z))
	Tik.mark = Vector3.new(markPos.X, markY, markPos.Z)
	Tik.phoneCF = Tik.rigCF * Tripod.phoneOffset
end

-- Behind-the-scenes shot while the rig assembles and you walk to the mark.
function Tik.btsCamera(dt, dollyIn)
	Tik.btsT = Tik.btsT + dt
	local phonePos = Tik.phoneCF.Position
	local side = Tik.rigCF:PointToWorldSpace(Vector3.new(4.6 + math.sin(Tik.btsT * 0.35) * 0.6, 3.1, -1.4))
	local closeUp = Tik.phoneCF:PointToWorldSpace(Vector3.new(1.2, 0.3, -2.2))
	local pos = side:Lerp(closeUp, dollyIn)
	local look = (phonePos + Tik.mark + Vector3.new(0, 2.2, 0)) / 2
	look = look:Lerp(phonePos, dollyIn * 0.6)
	pos = Ray.pullIn(pos, look, 0.6)
	local target = CFrame.lookAt(pos, look)
	Tik.camS = Tik.camS and Tik.camS:Lerp(target, Util.expAlpha(6, dt)) or target
	Cam.cf = Tik.camS
	Cam.fov = Util.lerp(58, 46, dollyIn)
	Filter.setFocus((look - pos).Magnitude)
end

local function tikLocalRig()
	Tik.rigLocal = true
	Tik.rig = Tripod.buildModel(Tik.rigCF, localFolder(), player.UserId)
	Tik.rig:SetAttribute("Light", Tik.light)
	Tik.rig:SetAttribute("Temp", Tik.temp)
	Spectate.onRig(Tik.rig)
end

defineMode({
	id = "TIKTOK", name = "TIKTOK STUDIO", icon = "🎵", blurb = "ring light tripod · auto walk to the mark · phone POV · emotes · clips",
	scriptable = true, preset = function() return S.tiktok.preset end, wantsMouseLock = "never",
	keys = {
		{ "Enter / ●", "start or stop recording a clip" }, { "W / S", "walk" }, { "A / D", "turn" }, { "Space", "jump" },
		{ ".", "roblox emote menu" }, { "Wheel / − +", "zoom" }, { "L", "ring light level" }, { "T", "light colour" },
		{ "V", "wide angle" }, { "Z", "auto zoom pulses" }, { "N", "center stage" }, { "F", "filter" }, { "X", "pack up" },
	},
	enter = function()
		if not Tik.els then Tik.buildUI() end
		Tik.shell.layout()
		Tik.placeRig()
		Tik.light = clamp(math.floor(S.tiktok.light + 0.5), 0, 4)
		Tik.temp = S.tiktok.temp
		if not Tripod.temps[Tik.temp] then Tik.temp = "NEUTRAL" end
		Tik.zoomT, Tik.zoomS, Tik.zoomVel = 1, 1, 0
		Tik.wide, Tik.autoS, Tik.autoTarget, Tik.autoT, Tik.punch, Tik.stageS = false, 1, 1, 2, 0, 1
		Tik.lookS, Tik.camS, Tik.btsT = nil, nil, 0
		Tik.rec, Tik.recIds, Tik.timerT, Tik.emotesOpen, Tik.walkDone = false, {}, 0, false, false
		Tik.fovS = S.tiktok.fov
		Tik.phase, Tik.phaseT, Tik.spawnT = "spawn", 0, os.clock()
		Tik.rig = nil
		Tik.rigLocal = false
		if Net.available then
			Net.sendRig("spawn", { cf = Tik.rigCF, light = Tik.light, temp = Tik.temp })
		else
			tikLocalRig()
		end
		Body.setControls(false)
		Body.setAutoRotate(true)
		Body.setWalk(nil)
		Tik.shell.setEnabled(false)
		Tik.els.emoteStrip.Visible = false
		Tik.els.splash.Visible = false
		Tik.els.countdown.Text = ""
		Tik.refreshUI()
		Toast.show(Net.available and "setting up the ring light · everyone can see this" or "setting up the ring light (install ICS2K_Server.lua so others see it)", "info", 3)
	end,
	exit = function()
		if Tik.rec then Tik.stopRec(true) end
		if Tik.walkConn then Tik.walkConn:Disconnect() Tik.walkConn = nil end
		if Tik.shell then Tik.shell.setEnabled(false) end
		local rig = Tik.rig
		Tik.rig = nil
		Tik.phase = "off"
		if Tik.rigLocal and rig then
			Tripod.animateOut(rig, function() Spectate.offRig(rig) rig:Destroy() end)
		end
		if Net.available then Net.sendRig("despawn") end
		pcall(function()
			-- cancel a walk that is still in progress and stop any Move we issued
			Rig.humanoid:MoveTo(Rig.root.Position)
			Rig.humanoid:Move(Vector3.new(), false)
		end)
	end,
	update = function(dt, t)
		local e = Tik.els
		Tik.phaseT = Tik.phaseT + dt
		-- a replicated rig arrives a moment after we asked for it; fall back to a local one if the server is silent
		if not Tik.rig and not Tik.rigLocal then
			local m = Spectate.findOwnRig()
			if m then
				Tik.rig = m
				local ph = m:FindFirstChild("Phone")
				if ph then Tik.phoneCF = ph.CFrame end
			elseif os.clock() - Tik.spawnT > 2 then
				tikLocalRig()
				Toast.show("no reply from ICS2K_Server · using a local rig", "error", 2.5)
			end
		end
		local phoneCF = Tik.phoneCF
		local head = Rig.head and Rig.head.Position or (Rig.root.Position + Vector3.new(0, 1.5, 0))
		local phase = Tik.phase
		if phase == "spawn" then
			Tik.btsCamera(dt, 0)
			if Tik.phaseT > 0.9 and Tik.rig then
				Tik.phase, Tik.phaseT = "walk", 0
				Tik.walkDone = false
				pcall(function()
					Tik.walkConn = Rig.humanoid.MoveToFinished:Connect(function() Tik.walkDone = true end)
					Rig.humanoid:MoveTo(Tik.mark)
				end)
			end
			return
		elseif phase == "walk" then
			Tik.btsCamera(dt, 0)
			local flat = Util.flatten(Rig.root.Position - Tik.mark)
			if Tik.walkDone or flat.Magnitude < 1.2 or Tik.phaseT > 6 then
				if Tik.walkConn then Tik.walkConn:Disconnect() Tik.walkConn = nil end
				Tik.phase, Tik.phaseT = "hold", 0
				local r = Rig.root
				r.CFrame = CFrame.lookAt(r.Position, Vector3.new(phoneCF.Position.X, r.Position.Y, phoneCF.Position.Z))
			end
			return
		elseif phase == "hold" then
			Tik.btsCamera(dt, Util.smoothstep(Tik.phaseT / 1.6))
			if Tik.phaseT > 1.6 then
				Tik.phase, Tik.phaseT = "flyin", 0
				Tik.introFrom, Tik.introFromFov = Cam.cf, Cam.fov
			end
			return
		elseif phase == "flyin" then
			local screenCF = phoneCF * CFrame.new(0, 0, -0.95)
			local target = CFrame.lookAt(screenCF.Position, phoneCF.Position)
			local a = Util.easeInOutCubic(Tik.phaseT / 0.65)
			Cam.cf = Tik.introFrom:Lerp(target, a)
			Cam.fov = Util.lerp(Tik.introFromFov, 34, a)
			Filter.setFocus(1)
			if Tik.phaseT >= 0.5 and not Tik.shell.maskGui.Enabled then
				Tik.shell.setEnabled(true)
				e.splash.Visible = true
				e.splash.BackgroundTransparency = 0
			end
			if Tik.phaseT >= 0.65 then
				Tik.phase, Tik.phaseT, Tik.camS = "live", 0, nil
				tween(e.splash, { BackgroundTransparency = 1 }, 0.35)
				task.delay(0.4, function() e.splash.Visible = false end)
				Sound.play("swoosh", 0.3)
			end
			return
		end
		if phase ~= "live" then return end

		-- the phone's front camera, fixed on the tripod
		Tik.zoomS, Tik.zoomVel = Util.spring(Tik.zoomS, Tik.zoomVel, Tik.zoomT, 120, 22, dt)
		if S.tiktok.autoZoom then
			Tik.autoT = Tik.autoT - dt
			if Tik.autoT <= 0 then
				Tik.autoT = rng:NextNumber(3, 7)
				if rng:NextNumber() < 0.25 then
					Tik.punch = 1
					Tik.autoTarget = 1
				else
					Tik.autoTarget = ({ 1, 1, 1.12, 1.22, 1.35 })[rng:NextInteger(1, 5)]
				end
			end
		else
			Tik.autoTarget, Tik.punch = 1, 0
		end
		Tik.punch = math.max(0, Tik.punch - dt / 1.1)
		local strength = clamp(S.tiktok.autoZoomStrength, 0, 2)
		local autoGoal = 1 + (Tik.autoTarget - 1) * strength + Tik.punch * 0.28 * strength
		Tik.autoS = Util.smooth(Tik.autoS, autoGoal, Tik.punch > 0 and 14 or 1.4, dt)
		-- center stage: digital pan + crop inside the wide field so you stay framed
		local lens = phoneCF:PointToWorldSpace(Vector3.new(0, 0.66, -0.06))
		local forward = phoneCF.LookVector
		local markHead = Tik.mark + Vector3.new(0, 2.4, 0)
		local look, stageZoom = markHead, 1
		if S.tiktok.centerStage then
			local toHead = head - lens
			local dist = math.max(0.5, toHead.Magnitude)
			local ang = math.acos(clamp(forward:Dot(toHead / dist), -1, 1))
			local maxAng = rad(26)
			if ang > maxAng then
				local k = maxAng / ang
				look = lens + toHead * k + (markHead - lens) * (1 - k)
			else
				look = head
			end
			stageZoom = clamp(3.8 / dist, 0.85, 1.4)
		end
		Tik.lookS = Tik.lookS and Util.smoothVec(Tik.lookS, look, 5, dt) or look
		Tik.stageS = Util.smooth(Tik.stageS, stageZoom, 2.5, dt)
		local target = CFrame.lookAt(lens, Tik.lookS)
		Tik.camS = Tik.camS and Tik.camS:Lerp(target, Util.expAlpha(18, dt)) or target
		Cam.cf = Tik.camS
		local fov = S.tiktok.fov / Tik.zoomS / Tik.autoS / Tik.stageS * (Tik.wide and 1.55 or 1)
		Tik.fovS = Util.smooth(Tik.fovS, clamp(fov, 18, 112), 10, dt)
		Cam.fov = Tik.fovS
		Filter.setFocus((head - lens).Magnitude)

		-- body-relative movement so you can dance around the mark
		local keys = STATE.keys
		local hum = Rig.humanoid
		local fwd = (keys.W and 1 or 0) - (keys.S and 1 or 0)
		local side = (keys.D and 1 or 0) - (keys.A and 1 or 0)
		local lookF = Util.safeUnit(Util.flatten(Rig.root.CFrame.LookVector))
		local right = Vector3.new(-lookF.Z, 0, lookF.X)
		local move = lookF * fwd + right * side
		pcall(function() hum:Move(move.Magnitude > 0 and move.Unit or Vector3.new(), false) end)
		if keys.Space and hum.FloorMaterial ~= Enum.Material.Air then hum.Jump = true end

		-- countdown
		if Tik.timerT > 0 then
			Tik.timerT = Tik.timerT - dt
			e.countdown.Text = tostring(math.ceil(Tik.timerT))
			if Tik.timerT <= 0 then
				e.countdown.Text = ""
				Tik.startRec()
			end
		end
		-- recording: progress bar + burst frames into a clip
		if Tik.rec then
			Tik.recT = Tik.recT + dt
			e.progress.Size = UDim2.new(clamp(Tik.recT / Tik.recDur, 0, 1), 0, 0, 4)
			e.recLbl.Text = "● " .. Util.fmtTime(Tik.recT)
			Tik.recNext = Tik.recNext - dt
			if Tik.recNext <= 0 and not Gallery.busy then
				local frames = clamp(math.floor(S.tiktok.clipFrames + 0.5), 4, 40)
				Tik.recNext = Tik.recDur / frames
				Gallery.capture({
					raw = true, hide = { Tik.shell.chromeGui, HUD.gui, Window.gui, Toast.gui },
					onDone = function(id) if id and Tik.rec then table.insert(Tik.recIds, id) end end,
				})
			end
			if Tik.recT >= Tik.recDur then Tik.stopRec(true) end
		else
			e.recLbl.Text = ""
		end
		Filter.flashbulbs(dt, head)
	end,
	wheel = function(delta)
		if Tik.phase ~= "live" then return end
		Tik.zoomT = clamp(Tik.zoomT * math.pow(2, delta * 0.18), 0.5, 4)
	end,
	key = function(code, began)
		if not began or Tik.phase ~= "live" then return end
		if code == Enum.KeyCode.Return or code == Enum.KeyCode.KeypadEnter then Tik.toggleRec()
		elseif code == Enum.KeyCode.L then Tik.cycleLight()
		elseif code == Enum.KeyCode.T then Tik.cycleTemp()
		elseif code == Enum.KeyCode.V then Tik.toggleWide()
		elseif code == Enum.KeyCode.Z then Tik.toggleAuto()
		elseif code == Enum.KeyCode.N then Tik.toggleStage()
		elseif code == Enum.KeyCode.F then Tik.cycleFilter()
		elseif code == Enum.KeyCode.G then Window.open("GALLERY")
		end
	end,
	buildHud = function() return {} end,
	tickHud = function()
		local e = Tik.els
		if not e or Tik.phase == "off" then return end
		local vp = camera.ViewportSize
		local r = Tik.shell.region
		if r and (r.vp.X ~= vp.X or r.vp.Y ~= vp.Y) then Tik.shell.layout() end
		e.status.Text = Util.clock24()
		local best, bestD = 1, 1e9
		for i, c in ipairs(e.zoomChips) do
			local d = math.abs(math.log(c.z) - math.log(Tik.zoomT))
			if d < bestD then best, bestD = i, d end
		end
		for i, c in ipairs(e.zoomChips) do
			local active = i == best
			c.label.TextColor3 = active and T.gold or T.white
			c.chip.BackgroundTransparency = active and 0.1 or 0.6
			if active then c.label.Text = string.format("%.1fx", Tik.zoomT):gsub("%.0x", "x") else c.label.Text = (c.z < 1 and ".5x" or (c.z .. "x")) end
		end
	end,
})

----------------------------------------------------------------------------
-- 18. MODE: BODYCAM  (first person body camera)
----------------------------------------------------------------------------
local Bodycam = { yaw = 0, pitch = 0, bobT = 0, land = 0, rollS = 0, fovS = 100, headS = nil, battery = 100, stateConn = nil }

defineMode({
	id = "BODYCAM", name = "BODYCAM", icon = "👁", blurb = "first person body camera · head bob · timestamp overlay",
	scriptable = true, preset = function() return S.bodycam.preset end, wantsMouseLock = "always",
	keys = {
		{ "Mouse", "look (body turns with you)" }, { "W A S D", "move" }, { "hold Shift", "sprint" }, { "Space", "jump" },
		{ "Wheel", "field of view" }, { "I", "open the window (frees the mouse)" },
	},
	enter = function()
		Bodycam.yaw = deg(Util.yawOf(Rig.root.CFrame))
		Bodycam.pitch = 0
		Bodycam.bobT = 0
		Bodycam.land = 0
		Bodycam.headS = nil
		Bodycam.fovS = S.bodycam.fov
		Body.setControls(true)
		Body.setAutoRotate(false)
		Body.hideHead(true)
		Bodycam.stateConn = Rig.humanoid.StateChanged:Connect(function(_, newState)
			if newState == Enum.HumanoidStateType.Landed then Bodycam.land = 0.16 end
		end)
	end,
	exit = function()
		if Bodycam.stateConn then Bodycam.stateConn:Disconnect() Bodycam.stateConn = nil end
		Body.hideHead(false)
		Body.restoreAutoRotate()
	end,
	stepped = function()
		local r = Rig.root
		if r and r.Parent then
			r.CFrame = CFrame.new(r.Position) * CFrame.Angles(0, rad(Bodycam.yaw), 0)
		end
	end,
	update = function(dt)
		local hum = Rig.humanoid
		local head = Rig.head
		local headPos = head and head.Position or (Rig.root.Position + Vector3.new(0, 1.5, 0))
		Bodycam.headS = Bodycam.headS and Util.smoothVec(Bodycam.headS, headPos, 40, dt) or headPos
		local vel = Util.flatten(Rig.root.AssemblyLinearVelocity)
		local speed = vel.Magnitude
		local grounded = hum.FloorMaterial ~= Enum.Material.Air
		local moving = speed > 1 and grounded
		local sprinting = STATE.runway and moving
		Body.setWalk(STATE.runway and S.bodycam.sprint or nil)
		if moving then Bodycam.bobT = Bodycam.bobT + dt * (5.5 + speed * 0.22) end
		local amp = S.bodycam.headBob * clamp(speed / 16, 0, 1.6)
		local bobY = math.sin(Bodycam.bobT * 2) * 0.05 * amp
		local bobX = math.sin(Bodycam.bobT) * 0.035 * amp
		local rollT = math.sin(Bodycam.bobT) * 0.6 * amp
		Bodycam.rollS = Util.smooth(Bodycam.rollS, rollT, 12, dt)
		if Bodycam.land > 0 then
			bobY = bobY - math.sin(math.min(1, Bodycam.land / 0.16) * math.pi) * 0.22
			Bodycam.land = Bodycam.land - dt
		end
		local rot = CFrame.fromEulerAnglesYXZ(rad(Bodycam.pitch), rad(Bodycam.yaw), rad(Bodycam.rollS))
		Cam.cf = CFrame.new(Bodycam.headS) * rot * CFrame.new(bobX, bobY + 0.08, -0.28)
		local fovTarget = S.bodycam.fov + (sprinting and 7 or 0)
		Bodycam.fovS = Util.smooth(Bodycam.fovS, fovTarget, 6, dt)
		Cam.fov = Bodycam.fovS
		Bodycam.battery = math.max(4, Bodycam.battery - dt * 0.05)
	end,
	mouse = function(delta)
		local sens = 0.14 * S.bodycam.sensitivity
		Bodycam.yaw = Util.wrapAngle(Bodycam.yaw - delta.X * sens)
		Bodycam.pitch = clamp(Bodycam.pitch - delta.Y * sens, -80, 80)
	end,
	wheel = function(delta)
		S.bodycam.fov = clamp(S.bodycam.fov - delta * 4, 60, 118)
		if Window and Window.refreshSliders then Window.refreshSliders() end
	end,
	buildHud = function(parent)
		local els = {}
		els.title = UI.text(parent, "ICS2K  BODY 3", { font = T.font.mono, size = 16, color = T.white, frameSize = UDim2.new(0, 300, 0, 22), pos = UDim2.new(0, 22, 0, 20), stroke = 1 })
		els.id = UI.text(parent, "", { font = T.font.mono, size = 13, color = Color3.fromRGB(200, 210, 220), frameSize = UDim2.new(0, 300, 0, 18), pos = UDim2.new(0, 22, 0, 44), stroke = 1 })
		els.stamp = UI.text(parent, "", { font = T.font.mono, size = 16, color = T.white, frameSize = UDim2.new(0, 320, 0, 22), pos = UDim2.new(1, -342, 0, 20), xalign = Enum.TextXAlignment.Right, stroke = 1 })
		els.rec = UI.text(parent, "", { font = T.font.mono, size = 15, color = T.danger, frameSize = UDim2.new(0, 200, 0, 20), pos = UDim2.new(0, 22, 1, -46), stroke = 1 })
		els.bat = UI.text(parent, "", { font = T.font.mono, size = 14, color = T.white, frameSize = UDim2.new(0, 300, 0, 20), pos = UDim2.new(1, -322, 1, -46), xalign = Enum.TextXAlignment.Right, stroke = 1 })
		return els
	end,
	tickHud = function(els)
		els.title.Visible = S.bodycam.overlay
		els.id.Visible = S.bodycam.overlay
		els.stamp.Visible = S.bodycam.overlay
		els.rec.Visible = S.bodycam.overlay
		els.bat.Visible = S.bodycam.overlay
		els.id.Text = "UNIT " .. string.format("%06d", player.UserId % 1000000) .. "  " .. player.Name:upper()
		els.stamp.Text = Util.stamp()
		local blink = math.floor(os.clock() * 2) % 2 == 0
		els.rec.Text = (blink and "● " or "   ") .. "REC"
		local b = Bodycam.battery
		local bars = string.rep("▮", math.ceil(b / 25)) .. string.rep("▯", 4 - math.ceil(b / 25))
		els.bat.Text = string.format("%s %3.0f%%   %s", bars, b, (Rig.root.AssemblyLinearVelocity.Magnitude > 1) and "MOVING" or "STATIONARY")
	end,
})

----------------------------------------------------------------------------
-- 19. MODE: DRONE  (an autonomous follow drone)
----------------------------------------------------------------------------
local Drone = {
	pos = Vector3.new(), vel = Vector3.new(), userYaw = 180, orbitPhase = 0, heightOff = 0, idleT = 0, lookS = nil,
	leadS = nil, rollS = 0, fovS = 72, battery = 100, bobT = 0, seed = rng:NextNumber(0, 300), lastAccel = Vector3.new(),
}

function Drone.subjectFrame()
	local r = Rig.root
	local vel = Util.flatten(r.AssemblyLinearVelocity)
	local facing = Util.safeUnit(Util.flatten(r.CFrame.LookVector))
	local moving = vel.Magnitude > 2
	return r.Position, vel, facing, moving
end

defineMode({
	id = "DRONE", name = "DRONE", icon = "🚁", blurb = "an autonomous follow drone · lead prediction · banking · auto orbit",
	scriptable = true, preset = nil, wantsMouseLock = "rmb",
	keys = {
		{ "RMB drag", "orbit angle / height" }, { "Wheel", "follow distance" }, { "O", "toggle auto orbit when idle" },
		{ "W A S D", "walk (the drone follows)" }, { "hold Shift", "runway walk" },
	},
	enter = function()
		local pos, _, facing = Drone.subjectFrame()
		Drone.userYaw = 180
		Drone.orbitPhase = 0
		Drone.heightOff = 0
		Drone.idleT = 0
		Drone.pos = pos - facing * S.drone.distance + Vector3.new(0, S.drone.height, 0)
		Drone.vel = Vector3.new()
		Drone.lookS = nil
		Drone.leadS = facing
		Drone.rollS = 0
		Drone.fovS = 72
		Body.setControls(true)
		Body.setAutoRotate(true)
	end,
	exit = function() end,
	update = function(dt)
		local sd = S.drone
		local rootPos, vel, facing, moving = Drone.subjectFrame()
		local head = Rig.head and Rig.head.Position or (rootPos + Vector3.new(0, 1.5, 0))
		if STATE.runway then Body.setWalk("runway") elseif Body.override == "runway" then Body.setWalk(nil) end

		-- lead direction: where the subject is going
		local leadDir = moving and vel.Unit or facing
		Drone.leadS = Drone.leadS and Util.smoothVec(Drone.leadS, leadDir, 2.5, dt) or leadDir
		local F = Util.safeUnit(Drone.leadS, facing)

		-- auto orbit when idle
		if moving then
			Drone.idleT = 0
			Drone.orbitPhase = Util.smoothAngle(Drone.orbitPhase, 0, 1.2, dt)
		else
			Drone.idleT = Drone.idleT + dt
			if sd.autoOrbit and Drone.idleT > 3 then Drone.orbitPhase = Drone.orbitPhase + sd.orbitSpeed * dt end
		end
		local yaw = rad(Drone.userYaw + Drone.orbitPhase)
		local dirFromSubject = CFrame.fromEulerAnglesYXZ(0, yaw, 0):VectorToWorldSpace(F)
		local desired = rootPos + dirFromSubject * sd.distance + Vector3.new(0, sd.height + Drone.heightOff, 0)
		desired = Ray.pullIn(desired, head, 1.2)

		-- spring physics
		local k = Util.lerp(3, 16, clamp(sd.stiffness, 0, 1))
		local c = 2 * math.sqrt(k) * Util.lerp(0.4, 1.3, clamp(sd.damping, 0, 1))
		local accel = (desired - Drone.pos) * k - Drone.vel * c
		Drone.lastAccel = accel
		Drone.vel = Drone.vel + accel * dt
		local before = Drone.pos
		Drone.pos = Ray.slide(Drone.pos, Drone.vel * dt, 0.8)
		if dt > 0 then
			local actual = (Drone.pos - before) / dt
			if (actual - Drone.vel).Magnitude > 0.5 then Drone.vel = actual end
		end

		-- hover + bank
		Drone.bobT = Drone.bobT + dt
		local hover = Util.noise3(Drone.bobT * 0.7, Drone.seed) * 0.12
		local look = head + vel * sd.lead
		Drone.lookS = Drone.lookS and Util.smoothVec(Drone.lookS, look, 9, dt) or look
		local camPos = Drone.pos + hover
		local base = CFrame.lookAt(camPos, Drone.lookS)
		local lateral = accel:Dot(base.RightVector)
		Drone.rollS = Util.smooth(Drone.rollS, clamp(-lateral * 0.5, -16, 16), 5, dt)
		Cam.cf = base * CFrame.Angles(0, 0, rad(Drone.rollS))
		Drone.fovS = Util.smooth(Drone.fovS, 72 + clamp(Drone.vel.Magnitude * 0.22, 0, 14), 4, dt)
		Cam.fov = Drone.fovS
		Filter.setFocus((Drone.lookS - camPos).Magnitude)
		Drone.battery = math.max(5, Drone.battery - dt * 0.06)
		Filter.flashbulbs(dt, head)
	end,
	mouse = function(delta)
		local s = S.drone.sensitivity
		Drone.userYaw = Util.wrapAngle(Drone.userYaw - delta.X * 0.3 * s)
		Drone.heightOff = clamp(Drone.heightOff - delta.Y * 0.05 * s, -S.drone.height + 1.5, 30)
	end,
	wheel = function(delta)
		S.drone.distance = clamp(S.drone.distance * math.pow(2, -delta * 0.12), 3, 60)
		if Window and Window.refreshSliders then Window.refreshSliders() end
	end,
	key = function(code, began)
		if not began then return end
		if code == Enum.KeyCode.O then
			S.drone.autoOrbit = not S.drone.autoOrbit
			Toast.show(S.drone.autoOrbit and "auto orbit on" or "auto orbit off", "info", 1.2)
			if Window and Window.refreshSliders then Window.refreshSliders() end
		end
	end,
	buildHud = function(parent)
		local els = {}
		els.col = new("Frame", { Size = UDim2.new(0, 220, 0, 100), Position = UDim2.new(0, 20, 0.5, -50), BackgroundTransparency = 1, Parent = parent })
		els.lines = {}
		for i = 1, 4 do
			els.lines[i] = UI.text(els.col, "", { font = T.font.mono, size = 14, color = T.cyan, frameSize = UDim2.new(1, 0, 0, 22), pos = UDim2.new(0, 0, 0, (i - 1) * 24), stroke = 1 })
		end
		els.horizon = new("Frame", { Size = UDim2.new(0, 180, 0, 2), Position = UDim2.new(0.5, -90, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), BackgroundColor3 = T.cyan, BackgroundTransparency = 0.35, BorderSizePixel = 0, Parent = parent })
		els.hCenter = new("Frame", { Size = UDim2.new(0, 6, 0, 6), Position = UDim2.new(0.5, -3, 0.5, -3), BackgroundColor3 = T.white, BorderSizePixel = 0, Parent = parent })
		UI.pill(els.hCenter)
		els.tag = UI.text(parent, "", { font = T.font.head, size = 10, color = T.lavender, frameSize = UDim2.new(0, 320, 0, 20), pos = UDim2.new(1, -340, 1, -46), xalign = Enum.TextXAlignment.Right, stroke = 1 })
		els.brand = UI.text(parent, "ICS2K  DRONE  ·  GPS ▮▮▮  ·  LINK OK", { font = T.font.mono, size = 13, color = T.text, frameSize = UDim2.new(0, 420, 0, 20), pos = UDim2.new(1, -440, 0, 20), xalign = Enum.TextXAlignment.Right, stroke = 1 })
		return els
	end,
	tickHud = function(els)
		local vis = S.drone.hud
		els.col.Visible, els.horizon.Visible, els.hCenter.Visible, els.tag.Visible, els.brand.Visible = vis, vis, vis, vis, vis
		if not vis then return end
		local rootPos = Rig.root.Position
		els.lines[1].Text = string.format("ALT  %6.1f", Drone.pos.Y - rootPos.Y)
		els.lines[2].Text = string.format("SPD  %6.1f", Drone.vel.Magnitude)
		els.lines[3].Text = string.format("DST  %6.1f", (Drone.pos - rootPos).Magnitude)
		els.lines[4].Text = string.format("BAT  %5.0f%%", Drone.battery)
		els.horizon.Rotation = -Drone.rollS
		local tags = {}
		if Drone.idleT > 3 and S.drone.autoOrbit then table.insert(tags, "AUTO ORBIT") end
		table.insert(tags, string.format("FOLLOW %.0f", S.drone.distance))
		els.tag.Text = table.concat(tags, "  ·  ")
	end,
})

----------------------------------------------------------------------------
-- 20. MODE: TACTICAL  (top down RTS camera with x-ray roofs)
----------------------------------------------------------------------------
local Tactical = { focus = Vector3.new(), focusS = nil, yaw = 0, yawS = 0, el = 65, elS = 65, dist = 40, distS = 40, xray = {}, xrayClock = 0 }

-- Raycast through up to `max` surfaces (used for x-raying everything between camera and subject)
function Ray.castAll(origin, direction, max)
	local hits = {}
	local from, dir = origin, direction
	for _ = 1, max or 4 do
		if Ray.dirty then Ray.refresh() end
		local result = Workspace:Raycast(from, dir, Ray.params)
		if not result then break end
		if not Ray.shouldIgnore(result.Instance) then table.insert(hits, result) end
		local travelled = result.Position - from
		dir = dir - travelled - dir.Unit * 0.15
		from = result.Position + dir.Unit * 0.15
		if dir.Magnitude < 0.2 then break end
	end
	return hits
end

function Tactical.clearXray()
	for part in pairs(Tactical.xray) do
		if part and part.Parent then part.LocalTransparencyModifier = 0 end
	end
	Tactical.xray = {}
end

defineMode({
	id = "TACTICAL", name = "TACTICAL", icon = "🛰", blurb = "top down command view · deadzone follow · x-ray roofs",
	scriptable = true, preset = nil, wantsMouseLock = "rmb",
	keys = {
		{ "RMB drag", "rotate / tilt" }, { "Q / E", "rotate 45°" }, { "Wheel", "zoom" }, { "W A S D", "move" }, { "hold Shift", "runway walk" },
	},
	enter = function()
		Tactical.focus = Rig.root.Position
		Tactical.focusS = Tactical.focus
		Tactical.yaw = deg(Util.yawOf(Rig.root.CFrame))
		Tactical.yawS = Tactical.yaw
		Tactical.el = S.tactical.pitch
		Tactical.elS = Tactical.el
		Tactical.dist = S.tactical.height
		Tactical.distS = Tactical.dist
		Body.setControls(true)
		Body.setAutoRotate(true)
	end,
	exit = function() Tactical.clearXray() end,
	update = function(dt)
		local st = S.tactical
		local rootPos = Rig.root.Position
		if STATE.runway then Body.setWalk("runway") elseif Body.override == "runway" then Body.setWalk(nil) end
		-- deadzone follow in the camera's own frame
		local dz = st.deadzone
		local f = Tactical.focus
		local rel = CFrame.fromEulerAnglesYXZ(0, rad(Tactical.yawS), 0):VectorToObjectSpace(rootPos - f)
		local dx = 0
		if rel.X > dz then dx = rel.X - dz elseif rel.X < -dz then dx = rel.X + dz end
		local dzz = 0
		if rel.Z > dz then dzz = rel.Z - dz elseif rel.Z < -dz then dzz = rel.Z + dz end
		local shift = CFrame.fromEulerAnglesYXZ(0, rad(Tactical.yawS), 0):VectorToWorldSpace(Vector3.new(dx, 0, dzz))
		Tactical.focus = Vector3.new(f.X + shift.X, rootPos.Y, f.Z + shift.Z)
		local rate = Util.lerp(16, 3, clamp(st.smoothing, 0, 1))
		Tactical.focusS = Util.smoothVec(Tactical.focusS, Tactical.focus, rate, dt)
		Tactical.yawS = Util.smoothAngle(Tactical.yawS, Tactical.yaw, 8, dt)
		Tactical.elS = Util.smooth(Tactical.elS, Tactical.el, 8, dt)
		Tactical.distS = Util.smooth(Tactical.distS, Tactical.dist, 8, dt)
		local el = rad(Tactical.elS)
		local offset = CFrame.fromEulerAnglesYXZ(0, rad(Tactical.yawS), 0):VectorToWorldSpace(Vector3.new(0, math.sin(el) * Tactical.distS, math.cos(el) * Tactical.distS))
		local look = Tactical.focusS + Vector3.new(0, 1.5, 0)
		local pos = look + offset
		if st.xray then
			Tactical.xrayClock = Tactical.xrayClock + dt
			if Tactical.xrayClock > 1 / 20 then
				Tactical.xrayClock = 0
				local now = os.clock()
				local subjectHead = rootPos + Vector3.new(0, 1.5, 0)
				local right = CFrame.lookAt(pos, subjectHead).RightVector
				for _, o in ipairs({ Vector3.new(), right * 1.5, -right * 1.5, Vector3.new(0, 1.5, 0), Vector3.new(0, -1.5, 0) }) do
					for _, hit in ipairs(Ray.castAll(subjectHead + o, pos - subjectHead - o, 5)) do
						local p = hit.Instance
						if p and p:IsA("BasePart") then
							p.LocalTransparencyModifier = 0.85
							Tactical.xray[p] = now
						end
					end
				end
				for part, seen in pairs(Tactical.xray) do
					if now - seen > 0.2 then
						if part.Parent then part.LocalTransparencyModifier = 0 end
						Tactical.xray[part] = nil
					end
				end
			end
		else
			if next(Tactical.xray) then Tactical.clearXray() end
			pos = Ray.pullIn(pos, look, 1)
		end
		Cam.cf = CFrame.lookAt(pos, look)
		Cam.fov = st.fov
		Filter.setFocus((pos - look).Magnitude)
	end,
	mouse = function(delta)
		Tactical.yaw = Util.wrapAngle(Tactical.yaw - delta.X * 0.3)
		Tactical.el = clamp(Tactical.el + delta.Y * 0.2, 30, 89)
	end,
	wheel = function(delta)
		Tactical.dist = clamp(Tactical.dist * math.pow(2, -delta * 0.12), 8, 180)
	end,
	key = function(code, began)
		if not began then return end
		if code == Enum.KeyCode.Q then Tactical.yaw = Util.wrapAngle(Tactical.yaw + 45)
		elseif code == Enum.KeyCode.E then Tactical.yaw = Util.wrapAngle(Tactical.yaw - 45) end
	end,
	buildHud = function(parent)
		local els = {}
		els.ring = new("Frame", { Size = UDim2.new(0, 92, 0, 92), Position = UDim2.new(1, -116, 0, 24), BackgroundColor3 = T.panel, BackgroundTransparency = 0.5, BorderSizePixel = 0, Parent = parent })
		UI.pill(els.ring)
		UI.iridescent(UI.stroke(els.ring, 1.5, T.white, 0.2), 30, 0)
		els.dirs = {}
		for i, d in ipairs({ "N", "E", "S", "W" }) do
			els.dirs[i] = UI.text(els.ring, d, { font = T.font.head, size = i == 1 and 12 or 10, color = i == 1 and T.magenta or T.text, frameSize = UDim2.new(0, 16, 0, 16), xalign = Enum.TextXAlignment.Center, anchor = Vector2.new(0.5, 0.5) })
		end
		els.needle = new("Frame", { Size = UDim2.new(0, 2, 0, 20), Position = UDim2.new(0.5, -1, 0.5, -10), BackgroundColor3 = T.lime, BorderSizePixel = 0, Parent = els.ring })
		els.coords = UI.text(parent, "", { font = T.font.mono, size = 14, color = T.cyan, frameSize = UDim2.new(0, 360, 0, 20), pos = UDim2.new(0, 20, 1, -46), stroke = 1 })
		return els
	end,
	tickHud = function(els)
		local yaw = rad(Tactical.yawS)
		for i, lbl in ipairs(els.dirs) do
			local a = yaw + (i - 1) * math.pi / 2
			lbl.Position = UDim2.new(0.5 + math.sin(a) * 0.36, 0, 0.5 - math.cos(a) * 0.36, 0)
		end
		local p = Rig.root.Position
		els.coords.Text = string.format("X %7.1f   Z %7.1f   ALT %6.1f   ZOOM %3.0f", p.X, p.Z, p.Y, Tactical.distS)
	end,
})

----------------------------------------------------------------------------
-- 21. MODE: CCTV  (security cameras you placed, PTZ tracking, smart switching)
----------------------------------------------------------------------------
local CCTV = { cams = {}, idx = 1, camT = 0, losLost = 0, losClock = 0, visible = true, glitchClock = 6, yawS = 0, pitchS = 0, auto = false }

function CCTV.autoCams()
	local list = {}
	local center = Rig.root.Position
	for i, ang in ipairs({ 45, 135, 225, 315 }) do
		local a = rad(ang)
		local pos = center + Vector3.new(math.cos(a) * 22, 9, math.sin(a) * 22)
		pos = Ray.pullIn(pos, center + Vector3.new(0, 1.5, 0), 1)
		table.insert(list, { cf = CFrame.lookAt(pos, center), fov = S.cctv.fov, name = "CAM " .. string.format("%02d", i) })
	end
	return list
end

function CCTV.bestCam(exclude)
	local head = Rig.head and Rig.head.Position or Rig.root.Position
	local best, bestScore
	for i, cam in ipairs(CCTV.cams) do
		if i ~= exclude or #CCTV.cams == 1 then
			local d = (cam.cf.Position - head).Magnitude
			local blocked = Ray.cast(cam.cf.Position, head - cam.cf.Position) ~= nil
			local score = d + (blocked and 1000 or 0)
			if not bestScore or score < bestScore then best, bestScore = i, score end
		end
	end
	return best or 1
end

function CCTV.switchTo(i, silent)
	if #CCTV.cams == 0 then return end
	CCTV.idx = ((i - 1) % #CCTV.cams) + 1
	CCTV.camT = 0
	CCTV.losLost = 0
	local cam = CCTV.cams[CCTV.idx]
	local y, p = poseFromCFrame(cam.cf)
	CCTV.yawS, CCTV.pitchS = y, p
	Filter.glitch(0.12)
	Filter.blackBlink(0.06)
	if not silent then Toast.show(cam.name, "info", 1) end
end

defineMode({
	id = "CCTV", name = "CCTV", icon = "📹", blurb = "security cams you placed in FREE mode (B) · PTZ tracking · smart switching",
	scriptable = true, preset = function() return S.cctv.preset end, wantsMouseLock = "never",
	keys = {
		{ "N / P", "next / previous camera" }, { "T", "toggle PTZ tracking" }, { "Y", "toggle auto cycle" },
		{ "W A S D", "walk (camera relative)" }, { "hold Shift", "runway walk" }, { "FREE + B", "place a new camera" },
	},
	enter = function()
		CCTV.auto = #Bookmarks.list == 0
		CCTV.cams = CCTV.auto and CCTV.autoCams() or Bookmarks.list
		CCTV.glitchClock = rng:NextNumber(4, 10)
		CCTV.switchTo(CCTV.bestCam(nil), true)
		Body.setControls(true)
		Body.setAutoRotate(true)
		if CCTV.auto then Toast.show("no bookmarks: 4 auto cams placed · add your own in FREE (B)", "info", 3) end
	end,
	exit = function() end,
	update = function(dt)
		local sc = S.cctv
		if #CCTV.cams == 0 then return end
		if STATE.runway then Body.setWalk("runway") elseif Body.override == "runway" then Body.setWalk(nil) end
		-- bookmarks can be deleted from the window while we are on one of them
		if CCTV.idx > #CCTV.cams then CCTV.switchTo(1, true) end
		local cam = CCTV.cams[CCTV.idx]
		local head = Rig.head and Rig.head.Position or Rig.root.Position
		-- line of sight probe
		CCTV.losClock = CCTV.losClock + dt
		if CCTV.losClock > 0.25 then
			CCTV.losClock = 0
			CCTV.visible = Ray.cast(cam.cf.Position, head - cam.cf.Position) == nil
		end
		if CCTV.visible then CCTV.losLost = 0 else CCTV.losLost = CCTV.losLost + dt end
		CCTV.camT = CCTV.camT + dt
		if sc.smartSwitch and CCTV.losLost > 1.5 and #CCTV.cams > 1 then
			CCTV.switchTo(CCTV.bestCam(CCTV.idx))
			cam = CCTV.cams[CCTV.idx]
		elseif sc.autoCycle and CCTV.camT > sc.cycleSeconds and #CCTV.cams > 1 then
			local nextIdx = (CCTV.idx % #CCTV.cams) + 1
			if sc.smartSwitch then nextIdx = CCTV.bestCam(CCTV.idx) end
			CCTV.switchTo(nextIdx)
			cam = CCTV.cams[CCTV.idx]
		end
		-- PTZ: slew toward the subject with a motor-like rate limit
		local yawT, pitchT = poseFromCFrame(cam.cf)
		if sc.tracking then
			local aim = CFrame.lookAt(cam.cf.Position, head)
			yawT, pitchT = poseFromCFrame(aim)
		end
		local maxStep = 55 * dt
		CCTV.yawS = CCTV.yawS + clamp(Util.angleDelta(CCTV.yawS, yawT) * Util.expAlpha(4, dt), -maxStep, maxStep)
		CCTV.pitchS = CCTV.pitchS + clamp((pitchT - CCTV.pitchS) * Util.expAlpha(4, dt), -maxStep, maxStep)
		Cam.cf = CFrame.new(cam.cf.Position) * CFrame.fromEulerAnglesYXZ(rad(CCTV.pitchS), rad(CCTV.yawS), 0)
		Cam.fov = sc.fov
		Filter.setFocus((cam.cf.Position - head).Magnitude)
		if sc.glitches then
			CCTV.glitchClock = CCTV.glitchClock - dt
			if CCTV.glitchClock <= 0 then
				Filter.glitch(rng:NextNumber(0.08, 0.25))
				CCTV.glitchClock = rng:NextNumber(5, 14)
			end
		end
	end,
	key = function(code, began)
		if not began then return end
		if code == Enum.KeyCode.N then CCTV.switchTo(CCTV.idx + 1)
		elseif code == Enum.KeyCode.P then CCTV.switchTo(CCTV.idx - 1)
		elseif code == Enum.KeyCode.T then
			S.cctv.tracking = not S.cctv.tracking
			Toast.show(S.cctv.tracking and "PTZ tracking on" or "PTZ tracking off", "info", 1.2)
			if Window and Window.refreshSliders then Window.refreshSliders() end
		elseif code == Enum.KeyCode.Y then
			S.cctv.autoCycle = not S.cctv.autoCycle
			Toast.show(S.cctv.autoCycle and "auto cycle on" or "auto cycle off", "info", 1.2)
			if Window and Window.refreshSliders then Window.refreshSliders() end
		end
	end,
	buildHud = function(parent)
		local els = {}
		els.name = UI.text(parent, "", { font = T.font.mono, size = 18, color = T.white, frameSize = UDim2.new(0, 360, 0, 24), pos = UDim2.new(0, 26, 0, 22), stroke = 1 })
		els.sub = UI.text(parent, "", { font = T.font.mono, size = 13, color = Color3.fromRGB(190, 220, 205), frameSize = UDim2.new(0, 360, 0, 18), pos = UDim2.new(0, 26, 0, 48), stroke = 1 })
		els.stamp = UI.text(parent, "", { font = T.font.mono, size = 16, color = T.white, frameSize = UDim2.new(0, 320, 0, 22), pos = UDim2.new(1, -346, 0, 22), xalign = Enum.TextXAlignment.Right, stroke = 1 })
		els.rec = UI.text(parent, "", { font = T.font.mono, size = 15, color = T.danger, frameSize = UDim2.new(0, 200, 0, 20), pos = UDim2.new(0, 26, 1, -48), stroke = 1 })
		els.brand = UI.text(parent, "ICS2K SECURITY  ·  CH 1", { font = T.font.mono, size = 13, color = T.text, frameSize = UDim2.new(0, 320, 0, 20), pos = UDim2.new(1, -346, 1, -48), xalign = Enum.TextXAlignment.Right, stroke = 1 })
		-- corner brackets
		for i = 1, 4 do
			local bx = (i == 2 or i == 4) and 1 or 0
			local by = (i >= 3) and 1 or 0
			local h = new("Frame", { Size = UDim2.new(0, 28, 0, 2), Position = UDim2.new(bx, bx == 1 and -42 or 14, by, by == 1 and -16 or 14), BackgroundColor3 = T.white, BackgroundTransparency = 0.3, BorderSizePixel = 0, Parent = parent })
			local v = new("Frame", { Size = UDim2.new(0, 2, 0, 28), Position = UDim2.new(bx, bx == 1 and -16 or 14, by, by == 1 and -42 or 14), BackgroundColor3 = T.white, BackgroundTransparency = 0.3, BorderSizePixel = 0, Parent = parent })
			h.Name, v.Name = "BracketH" .. i, "BracketV" .. i
		end
		return els
	end,
	tickHud = function(els)
		local cam = CCTV.cams[CCTV.idx]
		els.name.Text = cam and (cam.name .. (CCTV.auto and "  AUTO" or "")) or "NO SIGNAL"
		local tags = {}
		table.insert(tags, S.cctv.tracking and "PTZ TRACK" or "FIXED")
		table.insert(tags, CCTV.visible and "TARGET OK" or "TARGET LOST")
		if S.cctv.autoCycle then table.insert(tags, string.format("CYCLE %2.0fs", math.max(0, S.cctv.cycleSeconds - CCTV.camT))) end
		els.sub.Text = table.concat(tags, "  ·  ")
		els.stamp.Text = os.date("%d/%m/%Y  %H:%M:%S")
		local blink = math.floor(os.clock() * 2) % 2 == 0
		els.rec.Text = (blink and "● " or "   ") .. "REC"
	end,
})

----------------------------------------------------------------------------
-- 22. HUD  (per mode overlays + the AFK screensaver)
----------------------------------------------------------------------------
HUD = { gui = nil, frames = {}, els = {}, clock = 0, saver = nil, saverVel = Vector2.new(1, 1), saverPos = Vector2.new(100, 100) }

function HUD.init()
	HUD.gui = new("ScreenGui", { Name = "ICS2K_HUD", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 150, Parent = playerGui })
	for _, id in ipairs(Modes.order) do
		local m = Modes.byId[id]
		if m.buildHud then
			local frame = new("Frame", { Name = "HUD_" .. id, Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Visible = false, Parent = HUD.gui })
			HUD.frames[id] = frame
			HUD.els[id] = m.buildHud(frame)
		end
	end
	-- DVD style screensaver logo
	local saver = new("Frame", { Name = "Screensaver", Size = UDim2.new(0, 180, 0, 64), Position = UDim2.new(0, 100, 0, 100), BackgroundColor3 = T.white, BorderSizePixel = 0, Visible = false, ZIndex = 50, Parent = HUD.gui })
	UI.corner(saver, 16)
	HUD.saverGrad = UI.gradient(saver, T.chrome, 90)
	UI.gloss(saver, UDim.new(0, 16))
	UI.text(saver, "ICS2K", { font = T.font.head, size = 20, color = T.textDark, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 0, 36), pos = UDim2.new(0, 0, 0, 8), z = 52 })
	UI.text(saver, "away · move to wake", { font = T.font.body, size = 11, color = T.textDark, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 0, 16), pos = UDim2.new(0, 0, 0, 42), z = 52 })
	HUD.saver = saver
end

function HUD.setMode(id)
	for fid, frame in pairs(HUD.frames) do frame.Visible = (fid == id) end
end

function HUD.tick(dt)
	HUD.gui.Enabled = S.general.hud and not STATE.uiHidden
	-- screensaver bounce
	local saver = HUD.saver
	local showSaver = STATE.afk and S.general.screensaver and not STATE.uiHidden
	if saver.Visible ~= showSaver then saver.Visible = showSaver end
	if showSaver then
		local vp = camera.ViewportSize
		local size = saver.AbsoluteSize
		local p = HUD.saverPos + HUD.saverVel * (dt * 120)
		local bounced = false
		if p.X < 0 then p = Vector2.new(0, p.Y) HUD.saverVel = Vector2.new(math.abs(HUD.saverVel.X), HUD.saverVel.Y) bounced = true end
		if p.Y < 0 then p = Vector2.new(p.X, 0) HUD.saverVel = Vector2.new(HUD.saverVel.X, math.abs(HUD.saverVel.Y)) bounced = true end
		if p.X + size.X > vp.X then p = Vector2.new(vp.X - size.X, p.Y) HUD.saverVel = Vector2.new(-math.abs(HUD.saverVel.X), HUD.saverVel.Y) bounced = true end
		if p.Y + size.Y > vp.Y then p = Vector2.new(p.X, vp.Y - size.Y) HUD.saverVel = Vector2.new(HUD.saverVel.X, -math.abs(HUD.saverVel.Y)) bounced = true end
		if bounced then
			local hues = { T.cyan, T.magenta, T.lime, T.lavender, T.gold }
			local c = hues[rng:NextInteger(1, #hues)]
			HUD.saverGrad.Color = ColorSequence.new(T.white, c)
		end
		HUD.saverPos = p
		saver.Position = UDim2.new(0, p.X, 0, p.Y)
	end
	HUD.clock = HUD.clock + dt
	if HUD.clock < 1 / CFG.hudRate then return end
	HUD.clock = 0
	local m = currentMode()
	local els = HUD.els[m.id]
	if m.tickHud and els then
		local ok, err = pcall(m.tickHud, els)
		if not ok then warn("[ICS2K] hud " .. m.id .. ": " .. tostring(err)) end
	end
end

----------------------------------------------------------------------------
-- 23. WINDOW  (the Y2K control panel)
----------------------------------------------------------------------------
Window = { gui = nil, root = nil, pages = {}, tab = "MODES", binds = {}, filterBinds = {}, modeCards = {} }

local SETTINGS_SCHEMA = {
	{ group = "general", title = "general", items = {
		{ k = "transitions", t = "toggle", label = "glide between modes" },
		{ k = "hud", t = "toggle", label = "mode HUD overlays" },
		{ k = "toasts", t = "toggle", label = "toast messages" },
		{ k = "sounds", t = "toggle", label = "ui sounds" },
		{ k = "afk", t = "toggle", label = "AFK → cinematic" },
		{ k = "afkTimeout", t = "slider", label = "AFK timeout", min = 30, max = 600, step = 10, fmt = "%ds" },
		{ k = "screensaver", t = "toggle", label = "AFK bouncing logo" },
		{ k = "paparazziFlashes", t = "toggle", label = "paparazzi flashbulbs FX" },
	} },
	{ group = "free", title = "free camera", items = {
		{ k = "sensitivity", t = "slider", label = "mouse sensitivity", min = 0.1, max = 3, step = 0.05, fmt = "%.2fx" },
		{ k = "flySpeed", t = "slider", label = "fly speed", min = 1, max = 300, step = 1, fmt = "%d" },
		{ k = "accel", t = "slider", label = "acceleration", min = 1, max = 30, step = 0.5, fmt = "%.1f" },
		{ k = "smoothing", t = "slider", label = "look smoothing", min = 0, max = 1, step = 0.05, fmt = "%.2f" },
		{ k = "zoomSpeed", t = "slider", label = "zoom step", min = 0.2, max = 3, step = 0.1, fmt = "%.1fx" },
		{ k = "maxZoom", t = "slider", label = "max zoom", min = 2, max = 120, step = 1, fmt = "%dx" },
		{ k = "rollSpeed", t = "slider", label = "roll speed", min = 10, max = 360, step = 5, fmt = "%d°/s" },
		{ k = "autoLevel", t = "toggle", label = "auto level roll" },
		{ k = "collision", t = "toggle", label = "collision (off = noclip)" },
		{ k = "speedFov", t = "toggle", label = "speed widens FOV" },
		{ k = "autofocus", t = "toggle", label = "autofocus (depth of field)" },
		{ k = "showRail", t = "toggle", label = "show rail markers" },
		{ k = "railSegmentTime", t = "slider", label = "rail seconds per key", min = 0.3, max = 10, step = 0.1, fmt = "%.1fs" },
		{ k = "railLoop", t = "toggle", label = "rail loops" },
	} },
	{ group = "cinematic", title = "cinematic director", items = {
		{ k = "energy", t = "slider", label = "energy (cuts vs glides)", min = 0, max = 1, step = 0.05, fmt = "%.2f" },
		{ k = "shotLength", t = "slider", label = "shot length", min = 0.3, max = 3, step = 0.1, fmt = "%.1fx" },
		{ k = "handheld", t = "slider", label = "handheld motion", min = 0, max = 2, step = 0.05, fmt = "%.2f" },
		{ k = "autoFocus", t = "toggle", label = "autofocus on subject" },
		{ k = "preset", t = "seg", label = "look", options = { { "KODAK", "KODAK" }, { "TEAL", "TEAL" }, { "NOIR", "NOIR" }, { "DREAM", "DREAM" }, { "Y2K", "Y2K" } } },
	} },
	{ group = "paparazzi", title = "paparazzi phone", items = {
		{ k = "armLength", t = "slider", label = "arm length", min = 0.6, max = 1.4, step = 0.02, fmt = "%.2fx" },
		{ k = "fov", t = "slider", label = "1x field of view", min = 40, max = 100, step = 1, fmt = "%d°" },
		{ k = "sensitivity", t = "slider", label = "arm sensitivity", min = 0.2, max = 3, step = 0.05, fmt = "%.2fx" },
		{ k = "torch", t = "slider", label = "flash brightness", min = 0.5, max = 6, step = 0.1, fmt = "%.1f" },
		{ k = "shake", t = "slider", label = "handheld shake", min = 0, max = 2, step = 0.05, fmt = "%.2f" },
		{ k = "preset", t = "seg", label = "look", options = { { "PORTRAIT", "PORTRAIT" }, { "OFF", "CLEAN" }, { "DREAM", "DREAM" }, { "Y2K", "Y2K" } } },
	} },
	{ group = "tiktok", title = "tiktok studio", items = {
		{ k = "fov", t = "slider", label = "1x field of view", min = 40, max = 100, step = 1, fmt = "%d°" },
		{ k = "markDistance", t = "slider", label = "tripod distance", min = 5, max = 12, step = 0.5, fmt = "%.1f" },
		{ k = "light", t = "slider", label = "ring light level", min = 0, max = 4, step = 1, fmt = "%d" },
		{ k = "temp", t = "seg", label = "light colour", options = { { "WARM", "3200K" }, { "NEUTRAL", "4500K" }, { "COOL", "5600K" } } },
		{ k = "centerStage", t = "toggle", label = "center stage (auto framing)" },
		{ k = "autoZoom", t = "toggle", label = "auto zoom pulses" },
		{ k = "autoZoomStrength", t = "slider", label = "auto zoom strength", min = 0.2, max = 2, step = 0.05, fmt = "%.2f" },
		{ k = "clipFrames", t = "slider", label = "frames per clip", min = 4, max = 40, step = 1, fmt = "%d" },
		{ k = "hearts", t = "toggle", label = "hearts on the phone screen" },
		{ k = "preset", t = "seg", label = "look", options = { { "PORTRAIT", "NATURAL" }, { "DREAM", "DREAM" }, { "Y2K", "Y2K" }, { "KODAK", "FILM" } } },
	} },
	{ group = "bodycam", title = "bodycam", items = {
		{ k = "fov", t = "slider", label = "field of view", min = 60, max = 118, step = 1, fmt = "%d°" },
		{ k = "headBob", t = "slider", label = "head bob", min = 0, max = 2, step = 0.05, fmt = "%.2f" },
		{ k = "sensitivity", t = "slider", label = "mouse sensitivity", min = 0.1, max = 3, step = 0.05, fmt = "%.2fx" },
		{ k = "sprint", t = "slider", label = "sprint multiplier", min = 1, max = 3, step = 0.1, fmt = "%.1fx" },
		{ k = "overlay", t = "toggle", label = "bodycam overlay" },
	} },
	{ group = "drone", title = "drone", items = {
		{ k = "distance", t = "slider", label = "follow distance", min = 3, max = 60, step = 0.5, fmt = "%.1f" },
		{ k = "height", t = "slider", label = "height", min = 0.5, max = 30, step = 0.5, fmt = "%.1f" },
		{ k = "stiffness", t = "slider", label = "responsiveness", min = 0, max = 1, step = 0.05, fmt = "%.2f" },
		{ k = "damping", t = "slider", label = "damping", min = 0, max = 1, step = 0.05, fmt = "%.2f" },
		{ k = "lead", t = "slider", label = "look ahead", min = 0, max = 1, step = 0.05, fmt = "%.2fs" },
		{ k = "autoOrbit", t = "toggle", label = "auto orbit when idle" },
		{ k = "orbitSpeed", t = "slider", label = "orbit speed", min = 2, max = 40, step = 1, fmt = "%d°/s" },
		{ k = "sensitivity", t = "slider", label = "mouse sensitivity", min = 0.1, max = 3, step = 0.05, fmt = "%.2fx" },
		{ k = "hud", t = "toggle", label = "drone HUD" },
	} },
	{ group = "tactical", title = "tactical", items = {
		{ k = "height", t = "slider", label = "zoom distance", min = 8, max = 180, step = 1, fmt = "%d" },
		{ k = "pitch", t = "slider", label = "tilt", min = 30, max = 89, step = 1, fmt = "%d°" },
		{ k = "deadzone", t = "slider", label = "deadzone", min = 0, max = 15, step = 0.5, fmt = "%.1f" },
		{ k = "smoothing", t = "slider", label = "follow smoothing", min = 0, max = 1, step = 0.05, fmt = "%.2f" },
		{ k = "fov", t = "slider", label = "field of view", min = 20, max = 80, step = 1, fmt = "%d°" },
		{ k = "xray", t = "toggle", label = "x-ray roofs and walls" },
	} },
	{ group = "cctv", title = "cctv", items = {
		{ k = "cycleSeconds", t = "slider", label = "cycle seconds", min = 2, max = 60, step = 1, fmt = "%ds" },
		{ k = "autoCycle", t = "toggle", label = "auto cycle" },
		{ k = "tracking", t = "toggle", label = "PTZ tracking" },
		{ k = "smartSwitch", t = "toggle", label = "smart switch when target lost" },
		{ k = "glitches", t = "toggle", label = "signal glitches" },
		{ k = "fov", t = "slider", label = "field of view", min = 40, max = 110, step = 1, fmt = "%d°" },
	} },
}

local FILTER_SCHEMA = {
	{ k = "grain", label = "film grain", min = 0, max = 1 },
	{ k = "vignette", label = "vignette", min = 0, max = 1 },
	{ k = "letterbox", label = "letterbox 2.39:1", min = 0, max = 1 },
	{ k = "scanlines", label = "scanlines", min = 0, max = 1 },
	{ k = "bloom", label = "bloom", min = 0, max = 1.5 },
	{ k = "bloomSize", label = "bloom size", min = 4, max = 64, step = 1, fmt = "%d" },
	{ k = "contrast", label = "contrast", min = -0.5, max = 0.6 },
	{ k = "saturation", label = "saturation", min = -1, max = 1 },
	{ k = "brightness", label = "brightness", min = -0.3, max = 0.3 },
	{ k = "blur", label = "soft blur", min = 0, max = 1 },
	{ k = "dof", label = "depth of field", min = 0, max = 1 },
	{ k = "dofRadius", label = "focus range", min = 1, max = 30, step = 0.5, fmt = "%.1f" },
}

function Window.init()
	Window.gui = new("ScreenGui", { Name = "ICS2K_Window", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 350, Enabled = false, Parent = playerGui })
	local root = new("Frame", {
		Name = "Root", Size = UDim2.new(0, 380, 0, 560), Position = UDim2.new(1, -16, 1, -16), AnchorPoint = Vector2.new(1, 1),
		BackgroundColor3 = T.panel, BackgroundTransparency = 0.06, BorderSizePixel = 0, ClipsDescendants = false, Parent = Window.gui,
	})
	Window.root = root
	UI.corner(root, 18)
	UI.gradient(root, T.glass, 90)
	UI.iridescent(UI.stroke(root, 2, T.white, 0), 30, 0)
	new("UIScale", { Scale = S.general.uiScale, Parent = root })
	UI.sparkles(root, 3)

	-- title bar (drag handle)
	local title = new("TextButton", { Name = "Title", Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = T.white, BorderSizePixel = 0, Text = "", AutoButtonColor = false, ZIndex = 2, Parent = root })
	UI.corner(title, 18)
	UI.gradient(title, T.chrome, 90)
	UI.gloss(title, UDim.new(0, 18))
	new("Frame", { Size = UDim2.new(1, 0, 0, 18), Position = UDim2.new(0, 0, 1, -18), BackgroundColor3 = T.chromeD, BorderSizePixel = 0, ZIndex = 2, Parent = title })
	UI.text(title, "ICS2K", { font = T.font.head, size = 14, color = T.textDark, frameSize = UDim2.new(0, 90, 1, 0), pos = UDim2.new(0, 16, 0, 0), z = 5 })
	UI.text(title, "intelligent camera system  ✦  v" .. CFG.version:lower(), { font = T.font.body, size = 12, color = Color3.fromRGB(60, 60, 80), frameSize = UDim2.new(0, 230, 1, 0), pos = UDim2.new(0, 92, 0, 0), z = 5 })
	local closeBtn = new("TextButton", { Size = UDim2.new(0, 24, 0, 24), Position = UDim2.new(1, -32, 0.5, -12), BackgroundColor3 = T.magenta, Text = "", AutoButtonColor = false, BorderSizePixel = 0, ZIndex = 5, Parent = title })
	UI.pill(closeBtn)
	UI.gloss(closeBtn)
	UI.text(closeBtn, "×", { font = T.font.uiBold, size = 16, color = T.textDark, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 1, 0), z = 7 })
	closeBtn.MouseButton1Click:Connect(function() Window.close() end)
	title.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			local m = UserInputService:GetMouseLocation()
			-- AbsolutePosition is in gui-inset space; Position inside an IgnoreGuiInset gui is viewport space
			local abs = root.AbsolutePosition - Window.gui.AbsolutePosition
			root.AnchorPoint = Vector2.new(0, 0)
			root.Position = UDim2.new(0, abs.X, 0, abs.Y)
			local offX, offY = m.X - abs.X, m.Y - abs.Y
			UI.dragging = { update = function(x, y) root.Position = UDim2.new(0, x - offX, 0, y - offY) end }
		end
	end)

	-- tabs
	local tabs = { "MODES", "SETTINGS", "FILTER", "GALLERY", "KEYS" }
	local opts = {}
	for _, tname in ipairs(tabs) do table.insert(opts, { tname, tname:lower() }) end
	local tabHolder = new("Frame", { Size = UDim2.new(1, -20, 0, 30), Position = UDim2.new(0, 10, 0, 46), BackgroundTransparency = 1, Parent = root })
	Window.tabCtl = UI.segmented(tabHolder, { options = opts, value = Window.tab, onChange = function(v) Window.setTab(v) end })

	-- pages
	local pageHolder = new("Frame", { Name = "Pages", Size = UDim2.new(1, 0, 1, -112), Position = UDim2.new(0, 0, 0, 84), BackgroundTransparency = 1, Parent = root })
	for _, tname in ipairs(tabs) do
		Window.pages[tname] = UI.scroller(pageHolder, { name = tname, visible = tname == Window.tab, gap = 6 })
	end
	-- footer
	UI.text(root, "C next mode  ·  X standard  ·  I window  ·  U hide ui  ·  ENTER snapshot", { font = T.font.mono, size = 11, color = T.muted, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 0, 22), pos = UDim2.new(0, 0, 1, -24) })

	Window.buildModes()
	Window.buildSettings()
	Window.buildFilter()
	Window.buildGallery()
	Window.buildKeys()
	table.insert(Gallery.listeners, function() Window.buildGallery() end)
	table.insert(Filter.listeners, function() Window.refreshFilter() end)
	table.insert(Bookmarks.listeners, function() Window.refreshBookmarks() end)
end

function Window.setTab(name)
	Window.tab = name
	for tname, page in pairs(Window.pages) do page.Visible = (tname == name) end
	if Window.tabCtl then Window.tabCtl.set(name, false) end
end

function Window.open(tab)
	STATE.windowOpen = true
	Window.gui.Enabled = true
	if tab then Window.setTab(tab) end
	Window.refresh()
	local s = Window.root:FindFirstChildOfClass("UIScale")
	if s then s.Scale = S.general.uiScale * 0.92 tween(s, { Scale = S.general.uiScale }, 0.22, Enum.EasingStyle.Back) end
	Sound.play("swoosh", 0.15)
	Chip.refresh()
end
function Window.close()
	STATE.windowOpen = false
	Window.gui.Enabled = false
	Chip.refresh()
end
function Window.toggle() if STATE.windowOpen then Window.close() else Window.open() end end

function Window.buildModes()
	local page = Window.pages.MODES
	UI.text(page, "pick a camera. C cycles through the ones marked in the cycle.", { font = T.font.body, size = 12, color = T.muted, frameSize = UDim2.new(1, 0, 0, 30), wrap = true, order = 0 })
	for i, id in ipairs(Modes.order) do
		local m = Modes.byId[id]
		local card = new("TextButton", { Name = "Card_" .. id, Size = UDim2.new(1, 0, 0, 62), BackgroundColor3 = T.panel2, BackgroundTransparency = 0.15, BorderSizePixel = 0, Text = "", AutoButtonColor = false, LayoutOrder = i, Parent = page })
		UI.corner(card, 14)
		local stroke = UI.stroke(card, 1.5, T.chromeE, 0.5)
		local icon = new("Frame", { Size = UDim2.new(0, 40, 0, 40), Position = UDim2.new(0, 10, 0.5, -20), BackgroundColor3 = T.white, BorderSizePixel = 0, Parent = card })
		UI.pill(icon)
		UI.gradient(icon, T.chrome, 90)
		UI.gloss(icon)
		UI.text(icon, m.icon, { font = T.font.ui, size = 20, color = T.textDark, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 1, 0), z = 4 })
		local name = UI.text(card, m.name, { font = T.font.head, size = 11, color = T.text, frameSize = UDim2.new(1, -140, 0, 18), pos = UDim2.new(0, 60, 0, 10) })
		UI.text(card, m.blurb, { font = T.font.body, size = 12, color = T.muted, frameSize = UDim2.new(1, -130, 0, 30), pos = UDim2.new(0, 60, 0, 28), wrap = true, yalign = Enum.TextYAlignment.Top })
		local active = UI.text(card, "ACTIVE", { font = T.font.head, size = 8, color = T.lime, frameSize = UDim2.new(0, 60, 0, 14), pos = UDim2.new(1, -118, 0, 8), xalign = Enum.TextXAlignment.Right })
		local cyc
		if id ~= "STANDARD" then
			local holder = new("Frame", { Size = UDim2.new(0, 60, 0, 28), Position = UDim2.new(1, -66, 0.5, -14), BackgroundTransparency = 1, Parent = card })
			UI.text(holder, "C", { font = T.font.mono, size = 11, color = T.muted, frameSize = UDim2.new(0, 14, 1, 0) })
			cyc = UI.toggle(holder, { label = "", value = S.carousel[id], onChange = function(v) S.carousel[id] = v end })
			holder.Toggle_.Size = UDim2.new(0, 46, 1, 0)
			holder.Toggle_.Position = UDim2.new(0, 14, 0, 0)
		end
		card.MouseButton1Click:Connect(function() setMode(id) end)
		card.MouseEnter:Connect(function() stroke.Transparency = 0 end)
		card.MouseLeave:Connect(function() stroke.Transparency = STATE.modeId == id and 0 or 0.5 end)
		Window.modeCards[id] = { card = card, stroke = stroke, active = active, name = name, cyc = cyc }
	end
end

function Window.refresh()
	for id, c in pairs(Window.modeCards) do
		local isActive = STATE.modeId == id
		c.active.Visible = isActive
		c.stroke.Transparency = isActive and 0 or 0.5
		c.stroke.Color = isActive and T.lime or T.chromeE
		c.name.TextColor3 = isActive and T.lime or T.text
		if c.cyc then c.cyc.set(S.carousel[id], false) end
	end
	Window.buildKeys()
	Window.refreshSliders()
end

function Window.buildSettings()
	local page = Window.pages.SETTINGS
	for gi, group in ipairs(SETTINGS_SCHEMA) do
		local sec = UI.section(page, group.title, { order = gi, collapsed = gi > 2 })
		Window.binds[group.group] = Window.binds[group.group] or {}
		for ii, item in ipairs(group.items) do
			local store = S[group.group]
			local ctl
			if item.t == "slider" then
				ctl = UI.slider(sec.content, {
					label = item.label, min = item.min, max = item.max, step = item.step or 0.01, value = store[item.k], order = ii,
					format = function(v) return string.format(item.fmt or "%.2f", v) end,
					onChange = function(v) store[item.k] = v end,
				})
			elseif item.t == "toggle" then
				ctl = UI.toggle(sec.content, { label = item.label, value = store[item.k], order = ii, onChange = function(v) store[item.k] = v end })
			elseif item.t == "seg" then
				ctl = UI.segmented(sec.content, { label = item.label, options = item.options, value = store[item.k], order = ii, onChange = function(v)
					store[item.k] = v
					if STATE.modeId == group.group:upper() then Filter.requestPreset(v) end
				end })
			end
			table.insert(Window.binds[group.group], { ctl = ctl, item = item, store = store })
		end
		Window.sections = Window.sections or {}
		Window.sections[group.group] = sec
	end
	-- bookmarks manager
	local sec = UI.section(page, "bookmarks / cctv cams", { order = 50, collapsed = true })
	Window.bookmarkList = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = sec.content })
	UI.list(Window.bookmarkList, 4)
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 32), BackgroundTransparency = 1, LayoutOrder = 99, Parent = sec.content })
	UI.list(row, 6, true)
	UI.button(row, { text = "CLEAR ALL", kind = "danger", size = UDim2.new(0, 110, 0, 28), onClick = function() Bookmarks.clear() end })
	UI.button(row, { text = "CLEAR RAIL", kind = "dark", size = UDim2.new(0, 110, 0, 28), onClick = function() Rail.clear() end })
	Window.refreshBookmarks()
	-- reset
	UI.button(page, { text = "RESET ALL SETTINGS", kind = "chrome", size = UDim2.new(1, 0, 0, 34), order = 60, onClick = function()
		for g, vals in pairs(DEFAULTS) do
			for k, v in pairs(vals) do S[g][k] = v end
		end
		Window.refreshSliders()
		Window.refreshFilter()
		Window.refresh()
		Toast.show("settings reset ✦", "ok")
	end })
end

function Window.refreshBookmarks()
	if not Window.bookmarkList then return end
	for _, c in ipairs(Window.bookmarkList:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
	if #Bookmarks.list == 0 then
		local r = new("Frame", { Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, Parent = Window.bookmarkList })
		UI.text(r, "none yet · press B in FREE mode", { font = T.font.body, size = 12, color = T.muted, frameSize = UDim2.new(1, 0, 1, 0) })
		return
	end
	for i, e in ipairs(Bookmarks.list) do
		local r = new("Frame", { Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, LayoutOrder = i, Parent = Window.bookmarkList })
		UI.text(r, string.format("%s   (%.0f, %.0f, %.0f)", e.name, e.cf.Position.X, e.cf.Position.Y, e.cf.Position.Z), { font = T.font.mono, size = 12, color = T.text, frameSize = UDim2.new(1, -140, 1, 0) })
		UI.button(r, { text = "GO", kind = "dark", size = UDim2.new(0, 44, 0, 22), pos = UDim2.new(1, -112, 0, 2), textSize = 9, onClick = function()
			if STATE.modeId ~= "FREE" then setMode("FREE") end
			Free.gotoPose(e.cf, e.fov, 1.2)
		end })
		UI.button(r, { text = "DEL", kind = "danger", size = UDim2.new(0, 56, 0, 22), pos = UDim2.new(1, -60, 0, 2), textSize = 9, onClick = function() Bookmarks.remove(i) end })
	end
end

function Window.refreshSliders()
	for _, list in pairs(Window.binds) do
		for _, b in ipairs(list) do
			if b.ctl and b.ctl.set then b.ctl.set(b.store[b.item.k], false) end
		end
	end
end

function Window.buildFilter()
	local page = Window.pages.FILTER
	UI.text(page, "presets", { font = T.font.head, size = 10, color = T.lavender, frameSize = UDim2.new(1, 0, 0, 18), order = 0 })
	local grid = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 1, Parent = page })
	new("UIGridLayout", { CellSize = UDim2.new(0, 108, 0, 30), CellPadding = UDim2.new(0, 6, 0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })
	Window.presetButtons = {}
	for i, name in ipairs(Filter.presetOrder) do
		local b = UI.button(grid, { text = name, kind = "dark", size = UDim2.new(0, 108, 0, 30), order = i, textSize = 10, onClick = function() Filter.userPick(name) end })
		Window.presetButtons[name] = b
	end
	Window.filterLock = UI.toggle(page, { label = "lock look (modes won't change it)", value = S.filter.lock, order = 2, onChange = function(v) S.filter.lock = v end })
	Window.tintCtl = UI.segmented(page, { label = "tint", order = 3, value = S.filter.tint, options = { { "NONE", "none" }, { "WARM", "warm" }, { "COOL", "cool" }, { "ROSE", "rose" }, { "MINT", "mint" }, { "TEAL", "teal" } }, onChange = function(v) S.filter.tint = v Filter.snapshotCustom() Window.refreshFilter() end })
	for i, item in ipairs(FILTER_SCHEMA) do
		local ctl = UI.slider(page, {
			label = item.label, min = item.min, max = item.max, step = item.step or 0.01, value = S.filter[item.k], order = 10 + i,
			format = function(v) return string.format(item.fmt or "%.2f", v) end,
			onChange = function(v) S.filter[item.k] = v Filter.snapshotCustom() Window.refreshPresetButtons() end,
		})
		Window.filterBinds[item.k] = ctl
	end
	Window.refreshFilter()
end

function Window.refreshPresetButtons()
	for name, b in pairs(Window.presetButtons or {}) do
		b.setKind(S.filter.preset == name and "primary" or "dark")
	end
end

function Window.refreshFilter()
	for k, ctl in pairs(Window.filterBinds) do ctl.set(S.filter[k], false) end
	if Window.tintCtl then Window.tintCtl.set(S.filter.tint, false) end
	if Window.filterLock then Window.filterLock.set(S.filter.lock, false) end
	Window.refreshPresetButtons()
end

function Window.buildGallery()
	local page = Window.pages.GALLERY
	if not page then return end
	for _, c in ipairs(page:GetChildren()) do
		if c:IsA("GuiObject") then c:Destroy() end
	end
	local header = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, LayoutOrder = 0, Parent = page })
	UI.text(header, string.format("%d photo%s", #Gallery.items, #Gallery.items == 1 and "" or "s"), { font = T.font.head, size = 10, color = T.lavender, frameSize = UDim2.new(0.4, 0, 1, 0) })
	local btns = new("Frame", { Size = UDim2.new(0.6, 0, 1, 0), Position = UDim2.new(0.4, 0, 0, 0), BackgroundTransparency = 1, Parent = header })
	UI.list(btns, 6, true, Enum.HorizontalAlignment.Right)
	UI.button(btns, { text = "SNAP", kind = "primary", size = UDim2.new(0, 64, 0, 28), order = 1, textSize = 10, onClick = function() Window.snapshot() end })
	UI.button(btns, { text = "SAVE ALL", kind = "chrome", size = UDim2.new(0, 84, 0, 28), order = 2, textSize = 10, onClick = function() Gallery.save(Gallery.items) end })
	if #Gallery.items == 0 then
		UI.text(page, "no photos yet ✦\nENTER snaps in any mode · PAPARAZZI mode for selfies", { font = T.font.body, size = 13, color = T.muted, frameSize = UDim2.new(1, 0, 0, 60), wrap = true, xalign = Enum.TextXAlignment.Center, order = 1 })
		return
	end
	local grid = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 1, Parent = page })
	new("UIGridLayout", { CellSize = UDim2.new(0, 108, 0, 108), CellPadding = UDim2.new(0, 8, 0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })
	for i, item in ipairs(Gallery.items) do
		local cell = new("ImageButton", { Image = item.id, BackgroundColor3 = T.panel3, BorderSizePixel = 0, ScaleType = Enum.ScaleType.Crop, LayoutOrder = i, Parent = grid })
		UI.corner(cell, 12)
		UI.stroke(cell, 1, T.chromeE, 0.4)
		local n = item.frames and #item.frames or 1
		local cap = UI.text(cell, (n > 1 and ("CLIP " .. n .. " · ") or (item.label .. " ")) .. item.clock, { font = T.font.mono, size = 10, color = T.white, frameSize = UDim2.new(1, -8, 0, 16), pos = UDim2.new(0, 4, 1, -18), stroke = 1 })
		cell.MouseButton1Click:Connect(function() Gallery.open(item) end)
	end
end

function Window.snapshot()
	Gallery.capture({
		hide = { Window.gui, HUD.gui, Toast.gui, Pap.chromeGui },
		label = STATE.modeId,
		onDone = function(item)
			if item then
				Filter.screenFlash(0.5, 0.25)
				Sound.play("shutter", 0.5)
				Toast.show("📸 snapshot saved to gallery", "ok", 1.8)
			end
		end,
	})
end

function Window.buildKeys()
	local page = Window.pages.KEYS
	if not page then return end
	for _, c in ipairs(page:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
	local m = currentMode()
	UI.text(page, m.name, { font = T.font.head, size = 11, color = T.lime, frameSize = UDim2.new(1, 0, 0, 20), order = 0 })
	local n = 1
	for _, k in ipairs(m.keys or {}) do UI.keyRow(page, k[1], k[2], n) n = n + 1 end
	UI.divider(page, n) n = n + 1
	UI.text(page, "GLOBAL", { font = T.font.head, size = 11, color = T.lavender, frameSize = UDim2.new(1, 0, 0, 20), order = n }) n = n + 1
	for _, k in ipairs({ { "C", "next camera mode" }, { "X", "back to the standard camera" }, { "I", "toggle this window" }, { "U", "hide every ui (Esc or U restores)" }, { "Enter", "snapshot to the gallery" }, { "hold Shift", "runway walk (6.5 speed)" } }) do
		UI.keyRow(page, k[1], k[2], n) n = n + 1
	end
end

----------------------------------------------------------------------------
-- 24. CHIP  (the little mode pill when the window is closed)
----------------------------------------------------------------------------
Chip = { gui = nil, label = nil }

function Chip.init()
	Chip.gui = new("ScreenGui", { Name = "ICS2K_Chip", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 340, Parent = playerGui })
	local pillF = new("TextButton", { Size = UDim2.new(0, 0, 0, 38), AutomaticSize = Enum.AutomaticSize.X, Position = UDim2.new(1, -16, 1, -16), AnchorPoint = Vector2.new(1, 1), BackgroundColor3 = T.panel, BackgroundTransparency = 0.1, BorderSizePixel = 0, Text = "", AutoButtonColor = false, Parent = Chip.gui })
	UI.pill(pillF)
	UI.iridescent(UI.stroke(pillF, 1.5, T.white, 0), 50, 0)
	UI.padding(pillF, 0, 12, 14, 0, 0)
	local key = new("Frame", { Size = UDim2.new(0, 26, 0, 22), Position = UDim2.new(0, 0, 0.5, -11), BackgroundColor3 = T.white, BorderSizePixel = 0, Parent = pillF })
	UI.corner(key, 6)
	UI.gradient(key, T.chrome, 90)
	UI.text(key, "C", { font = T.font.mono, size = 13, color = T.textDark, xalign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 1, 0) })
	Chip.label = UI.text(pillF, "", { font = T.font.head, size = 10, color = T.text, frameSize = UDim2.new(0, 0, 1, 0), pos = UDim2.new(0, 34, 0, 0) })
	Chip.label.AutomaticSize = Enum.AutomaticSize.X
	pillF.MouseButton1Click:Connect(function() Window.open() end)
	Chip.pill = pillF
	Chip.refresh()
end

function Chip.refresh()
	local m = currentMode()
	Chip.label.Text = "▸  " .. m.name .. "   ·   I"
	Chip.gui.Enabled = (not STATE.windowOpen) and (not STATE.uiHidden) and STATE.modeId ~= "PAPARAZZI"
end

----------------------------------------------------------------------------
-- 25. MODE SWITCHING, UI HIDING, AFK
----------------------------------------------------------------------------
local hiddenGuis = {}
local savedCoreGui = {}
local CORE_GUI_NAMES = { "PlayerList", "Health", "Backpack", "Chat", "EmotesMenu", "SelfView", "Captures" }

local function setUIHidden(hidden)
	if STATE.uiHidden == hidden then return end
	STATE.uiHidden = hidden
	-- remember which core guis the game had on, so un-hiding restores *that*, not "everything"
	if hidden then
		savedCoreGui = {}
		for _, name in ipairs(CORE_GUI_NAMES) do
			pcall(function()
				local t = Enum.CoreGuiType[name]
				savedCoreGui[name] = StarterGui:GetCoreGuiEnabled(t)
				StarterGui:SetCoreGuiEnabled(t, false)
			end)
		end
		pcall(function() StarterGui:SetCore("TopbarEnabled", false) end)
	else
		for _, name in ipairs(CORE_GUI_NAMES) do
			pcall(function()
				if savedCoreGui[name] ~= nil then StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType[name], savedCoreGui[name]) end
			end)
		end
		pcall(function() StarterGui:SetCore("TopbarEnabled", true) end)
	end
	local keep = { ICS2K_Filter = true, ICS2K_PhoneMask = true, ICS2K_PhoneChrome = true, ICS2K_Toast = true, ICS2K_Modal = true }
	if hidden then
		hiddenGuis = {}
		for _, gui in ipairs(playerGui:GetChildren()) do
			if gui:IsA("ScreenGui") and gui.Enabled and not keep[gui.Name] then
				gui.Enabled = false
				table.insert(hiddenGuis, gui)
			end
		end
		Toast.show("ui hidden · U or Esc brings it back", "info", 2)
	else
		for _, gui in ipairs(hiddenGuis) do
			if gui.Parent then gui.Enabled = true end
		end
		hiddenGuis = {}
	end
	if Window.gui then Window.gui.Enabled = STATE.windowOpen and not hidden end
	Chip.refresh()
end

function setMode(id, opts)
	opts = opts or {}
	local newMode = Modes.byId[id]
	if not newMode then return end
	local prev = currentMode()
	if prev == newMode and not opts.force then return end
	if prev.exit then
		local ok, err = pcall(prev.exit, id)
		if not ok then warn("[ICS2K] exit " .. prev.id .. ": " .. tostring(err)) end
	end
	-- common reset between modes
	Rail.stop()
	Cam.override = nil
	STATE.rmb = false
	STATE.lmb = false
	STATE.runway = false
	STATE.mouseLocked = false
	pcall(Body.release)
	STATE.previousModeId = prev.id
	STATE.modeId = id
	if newMode.scriptable then
		if S.general.transitions and not opts.noBlend then
			Cam.blendFrom = camera.CFrame
			Cam.blendFromFov = camera.FieldOfView
			Cam.blendT = 0
			Cam.blendDur = CFG.transitionTime
		else
			Cam.blendT = 1
		end
		Cam.cf = camera.CFrame
		Cam.fov = camera.FieldOfView
		camera.CameraType = Enum.CameraType.Scriptable
		Cam.scriptable = true
	else
		camera.CameraType = Enum.CameraType.Custom
		camera.FieldOfView = CFG.baseFov
		Cam.scriptable = false
		Cam.blendT = 1
		-- hand the mouse back exactly once; the stock camera scripts do not repair a hidden cursor
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = not STATE.uiHidden
	end
	local ok, err = pcall(newMode.enter, prev.id)
	if not ok then warn("[ICS2K] enter " .. id .. ": " .. tostring(err)) end
	Filter.requestPreset(newMode.preset)
	if newMode.id == "STANDARD" then Filter.setFocus(12) end
	HUD.setMode(id)
	Chip.refresh()
	Window.refresh()
	if not opts.silent then
		Toast.show(newMode.icon .. "  " .. newMode.name, "mode", 1.6)
		Sound.play("click", 0.3)
	end
end

function cycleMode(step)
	local list = { "STANDARD" }
	for _, id in ipairs(Modes.order) do
		if id ~= "STANDARD" and S.carousel[id] then table.insert(list, id) end
	end
	local idx = 1
	for i, id in ipairs(list) do if id == STATE.modeId then idx = i break end end
	idx = ((idx - 1 + step) % #list) + 1
	setMode(list[idx])
end

local Input = { probeClock = 0 }

function Input.wake()
	if not STATE.afk then return end
	STATE.afk = false
	local back = STATE.afkReturn or "STANDARD"
	STATE.afkReturn = nil
	setMode(back)
	Toast.show("welcome back ✦", "ok", 1.5)
end

function Input.activity()
	STATE.lastActivity = os.clock()
	if STATE.afk then Input.wake() return true end
	return false
end

function Input.tick(dt, now)
	-- pointer over ui probe
	Input.probeClock = Input.probeClock + dt
	if Input.probeClock > 1 / CFG.pointerProbeRate then
		Input.probeClock = 0
		-- GetGuiObjectsAtPosition compares against AbsolutePosition (inset space)
		local m = UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
		local over = false
		local shop = false
		local ok, objs = pcall(function() return playerGui:GetGuiObjectsAtPosition(m.X, m.Y) end)
		if ok and objs then
			for _, o in ipairs(objs) do
				local passive = o.Name:sub(1, 7) == "Passive"
				if not passive and (o:IsA("GuiButton") or o:IsA("TextBox") or o:IsA("ScrollingFrame")) then over = true end
				local sg = o:FindFirstAncestorWhichIsA("ScreenGui")
				if sg then
					if sg.Name == "ICS2K_Window" or sg.Name == "ICS2K_Modal" then over = true end
					local lname = sg.Name:lower()
					for _, w in ipairs(CFG.shopGuiWords) do
						if lname:find(w, 1, true) then shop = true over = true end
					end
				end
				if over then break end
			end
		end
		STATE.pointerOverUI = over or UI.dragging ~= nil
		STATE.shopUIOpen = shop
	end
	-- AFK
	if S.general.afk and not STATE.afk and STATE.modeId ~= "CINEMATIC" and STATE.modeId ~= "PAPARAZZI" and STATE.modeId ~= "TIKTOK" then
		if now - STATE.lastActivity > math.max(20, S.general.afkTimeout) then
			STATE.afk = true
			STATE.afkReturn = STATE.modeId
			setMode("CINEMATIC", { silent = true })
			Toast.show("you drifted off · cinematic mode", "mode", 2.5)
		end
	end
end

function Input.applyMouse()
	local m = currentMode()
	if not m.scriptable then return end
	local lock = false
	local center = false
	if m.wantsMouseLock == "always" then
		lock = not STATE.windowOpen and not Gallery.isOpen()
		center = true
	elseif m.wantsMouseLock == "rmb" then
		lock = STATE.rmb or (STATE.mouseLocked and not STATE.windowOpen and not Gallery.isOpen())
		center = STATE.mouseLocked and not STATE.rmb
	end
	if lock then
		UserInputService.MouseBehavior = center and Enum.MouseBehavior.LockCenter or Enum.MouseBehavior.LockCurrentPosition
		UserInputService.MouseIconEnabled = false
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = not STATE.uiHidden
	end
end

function Input.clearTransient()
	STATE.keys = {}
	STATE.rmb = false
	STATE.lmb = false
	STATE.runway = false
end

function Input.began(input, gp)
	local t = input.UserInputType
	if t == Enum.UserInputType.Keyboard then
		STATE.lastActivity = os.clock()
		if gp then return end
		if Input.activity() then return end
		local code = input.KeyCode
		STATE.keys[code.Name] = true
		if code == Enum.KeyCode.C then cycleMode(1) return end
		if code == Enum.KeyCode.X then setMode("STANDARD") return end
		if code == Enum.KeyCode.U then setUIHidden(not STATE.uiHidden) return end
		if code == Enum.KeyCode.I then Window.toggle() return end
		if code == Enum.KeyCode.Escape then if STATE.uiHidden then setUIHidden(false) end return end
		if code == Enum.KeyCode.LeftShift or code == Enum.KeyCode.RightShift then STATE.runway = true end
		if (code == Enum.KeyCode.Return or code == Enum.KeyCode.KeypadEnter) and STATE.modeId ~= "PAPARAZZI" and STATE.modeId ~= "TIKTOK" and STATE.modeId ~= "STANDARD" then
			Window.snapshot()
			return
		end
		local m = currentMode()
		if m.key then
			local ok, err = pcall(m.key, code, true)
			if not ok then warn("[ICS2K] key " .. m.id .. ": " .. tostring(err)) end
		end
	elseif t == Enum.UserInputType.MouseButton2 then
		if Input.activity() then return end
		if not STATE.pointerOverUI and not gp then STATE.rmb = true end
	elseif t == Enum.UserInputType.MouseButton1 then
		Input.activity()
		STATE.lmb = true
	end
end

function Input.ended(input)
	local t = input.UserInputType
	if t == Enum.UserInputType.Keyboard then
		local code = input.KeyCode
		STATE.keys[code.Name] = nil
		if code == Enum.KeyCode.LeftShift or code == Enum.KeyCode.RightShift then STATE.runway = false end
		local m = currentMode()
		if m.key then pcall(m.key, code, false) end
	elseif t == Enum.UserInputType.MouseButton2 then
		STATE.rmb = false
	elseif t == Enum.UserInputType.MouseButton1 then
		STATE.lmb = false
	end
end

function Input.changed(input)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseMovement then
		if (input.Delta.X ~= 0 or input.Delta.Y ~= 0) and Input.activity() then return end
		local m = currentMode()
		if not m.mouse then return end
		local looking = false
		if m.wantsMouseLock == "always" then looking = not STATE.windowOpen and not Gallery.isOpen()
		elseif m.wantsMouseLock == "rmb" then looking = STATE.rmb or (STATE.mouseLocked and not STATE.windowOpen and not Gallery.isOpen()) end
		if looking then m.mouse(input.Delta) end
	elseif t == Enum.UserInputType.MouseWheel then
		if Input.activity() then return end
		if STATE.pointerOverUI then return end
		local m = currentMode()
		if m.wheel then m.wheel(input.Position.Z) end
	end
end

----------------------------------------------------------------------------
-- 26. MAIN LOOPS + LIFECYCLE
----------------------------------------------------------------------------
local lastWarn = 0
local function safeUpdate(m, dt, t)
	local ok, err = pcall(m.update, dt, t)
	if not ok and os.clock() - lastWarn > 2 then
		lastWarn = os.clock()
		warn("[ICS2K] " .. m.id .. ": " .. tostring(err))
	end
end

local uiClock = 0
local function onRender(dt)
	dt = math.min(dt, 1 / 15)
	local now = os.clock()
	local t = now - STATE.startedAt
	local cc = Workspace.CurrentCamera
	if cc and cc ~= camera then camera = cc end
	Input.tick(dt, now)
	Body.tick()
	IK.tick(dt)
	local m = currentMode()
	if m.scriptable then
		if camera.CameraType ~= Enum.CameraType.Scriptable then camera.CameraType = Enum.CameraType.Scriptable end
		safeUpdate(m, dt, t)
		if Cam.override then pcall(Cam.override, dt) end
		if Cam.blendT < 1 then
			Cam.blendT = Cam.blendT + dt / Cam.blendDur
			local a = Util.smoothstep(Cam.blendT)
			camera.CFrame = Cam.blendFrom:Lerp(Cam.cf, a)
			camera.FieldOfView = Util.lerp(Cam.blendFromFov, Cam.fov, a)
		else
			camera.CFrame = Cam.cf
			camera.FieldOfView = Cam.fov
		end
		-- a Scriptable camera stops maintaining Focus itself; shadows, lighting detail and audio follow it
		camera.Focus = camera.CFrame * CFrame.new(0, 0, -clamp(Filter.focus or 12, 1, 200))
	else
		Cam.cf = camera.CFrame
		Cam.fov = camera.FieldOfView
	end
	Input.applyMouse()
	Spectate.tick(dt)
	Filter.tick(dt, t)
	HUD.tick(dt)
	uiClock = uiClock + dt
	if uiClock >= 1 / CFG.uiAnimRate then
		UI.tickAnims(t, uiClock)
		uiClock = 0
	end
end

local function onStepped(_, dt)
	if IK.weight > 0 then pcall(IK.step) end
	Spectate.step()
	local m = currentMode()
	if m.stepped then pcall(m.stepped, dt) end
end

local function onCharacterAdded(newChar)
	if STATE.modeId ~= "STANDARD" then setMode("STANDARD", { silent = true, noBlend = true }) end
	Body.rebind(newChar)
	IK.bind()
	Phone.destroy()
	Director.subject = player
	local hum = Rig.humanoid
	hum.Died:Connect(function()
		if STATE.modeId ~= "STANDARD" then setMode("STANDARD", { silent = true, noBlend = true }) end
	end)
	Toast.show("respawned · C for cameras", "info", 2)
end

local function start()
	Toast.init()
	Filter.init()
	Gallery.init()
	HUD.init()
	Window.init()
	Chip.init()
	Body.rebind(char)
	IK.bind()
	Net.init()
	Spectate.init()
	Rig.humanoid.Died:Connect(function()
		if STATE.modeId ~= "STANDARD" then setMode("STANDARD", { silent = true, noBlend = true }) end
	end)

	UserInputService.InputBegan:Connect(Input.began)
	UserInputService.InputEnded:Connect(Input.ended)
	UserInputService.InputChanged:Connect(Input.changed)
	UserInputService.WindowFocusReleased:Connect(Input.clearTransient)
	UserInputService.TextBoxFocused:Connect(Input.clearTransient)
	GuiService.MenuOpened:Connect(Input.clearTransient)
	Players.PlayerAdded:Connect(function() Ray.dirty = true end)
	Players.PlayerRemoving:Connect(function(p) Ray.dirty = true if Director.subject == p then Director.subject = player end end)
	player.CharacterAdded:Connect(onCharacterAdded)

	RunService.RenderStepped:Connect(onRender)
	RunService.Stepped:Connect(onStepped)

	setMode("STANDARD", { silent = true, force = true })
	print("[ICS2K] intelligent camera system v" .. CFG.version .. " online · " .. #Modes.order .. " modes · C to cycle · I for the window")
	Toast.show("ICS2K online ✦ press C for cameras · I for the window", "mode", 3.5)
end

start()
