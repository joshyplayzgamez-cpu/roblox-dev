--!nonstrict
-- made by @extendedrealm on discord
-- store robbery mission built around the general store cashier's own robbery stuff
-- hold up, hand over, grab the bag, escape, then payout and the store reopens later

type Phase = "holdup" | "handover" | "grab" | "escape"

type Mission = {
	player: Player,
	step: number,
	phase: Phase,
	objective: string,
	hint: string,
	progress: number,
	deadline: number?,
	store: Vector3,
	worker: Model,
	bag: BasePart?,
	handStart: number?,
}

type Config = {
	holdUpRange: number,
	holdUpTimeout: number,
	holdUpNeed: number,
	handOverTimeout: number,
	grabTimeout: number,
	escapeDistance: number,
	escapeTime: number,
	bonusCash: number,
	bonusXp: number,
	storeCooldown: number,
	playerCooldown: number,
	retryCooldown: number,
}

type StatePayload = { [string]: any }

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NAME = "General Store Worker"
local npcFolder = workspace:WaitForChild("Characters"):WaitForChild("NPCs")
local prefab = ServerStorage:WaitForChild("Characters"):WaitForChild("NPCs"):WaitForChild(NAME)
local StateEvent = ReplicatedStorage:WaitForChild("StoreRobbery"):WaitForChild("State") -- server to client only, client never sends anything back

local CFG: Config = {
	holdUpRange     = 25,   -- studs, further than this and he stops being scared
	holdUpTimeout   = 15,
	holdUpNeed      = 4.5,  -- the ai needs about 2.5 aware + 1.5 aim, plus some slack
	handOverTimeout = 12,
	grabTimeout     = 25,
	escapeDistance  = 110,
	escapeTime      = 45,
	bonusCash       = 400,
	bonusXp         = 150,
	storeCooldown   = 60,
	playerCooldown  = 120,
	retryCooldown   = 15,   -- after a hold up that fizzled before the hand over
}

local mission: Mission? = nil -- only one robbery at a time
local storeClosedUntil: number = 0
local lastRobbed: { [Player]: number } = {}

-- more than one store and the menu parks a display cashier off map, so always check the exact one
local function usable(w: Model?): boolean
	return w ~= nil and w.Parent == npcFolder and w.Name == NAME
		and w:GetAttribute("MenuStageVendor") ~= true
		and w:FindFirstChild("Humanoid") ~= nil and w.Humanoid.Health > 0
		and w:FindFirstChild("HumanoidRootPart") ~= nil
end

-- nil if dead so a dead robber never passes a distance check
local function rootOf(player: Player): BasePart?
	local c = player.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	if not h or h.Health <= 0 then return nil end
	return c:FindFirstChild("HumanoidRootPart")
end

local function push(player: Player?, data: StatePayload): ()
	if player and player.Parent then
		StateEvent:FireClient(player, data)
	end
end

-- extra is for one off flags like beat = true for the phase change sting
local function status(extra: StatePayload?): ()
	if not mission then return end
	local data: StatePayload = {
		phase = "objective",
		step = mission.step,
		objective = mission.objective,
		hint = mission.hint,
		progress = mission.progress or 0,
		timeLeft = mission.deadline and math.max(0, mission.deadline - os.clock()) or nil,
		steps = 4,
	}
	for k, v in pairs(extra or {}) do data[k] = v end
	push(mission.player, data)
end

-- the ai keeps surrender set forever after a robbery so reopening means a fresh clone
local function reopenStore(old: Model?): ()
	if not old or old.Parent ~= npcFolder then return end
	local cf = old:GetPivot()
	local fresh = prefab:Clone()
	fresh.Name = NAME
	fresh:PivotTo(cf) -- before parenting so he doesn't pop in at the origin
	if old then old:Destroy() end
	fresh.Parent = npcFolder -- GeneralStoreService re-anchors him
end

local function finish(won: boolean, reason: string?): ()
	local m = mission
	if not m then return end
	mission = nil
	-- a hold up that never got to the hand over leaves the cashier fine, just a short retry wait
	local spent = won or m.phase ~= "holdup"
	if spent then
		lastRobbed[m.player] = os.clock()
	else
		lastRobbed[m.player] = os.clock() - (CFG.playerCooldown - CFG.retryCooldown) -- backdated so only retryCooldown is left
	end
	if won then
		-- _G hooks belong to other scripts and might not exist, pcall so they can't break this
		if _G.__menuAddCash then pcall(_G.__menuAddCash, m.player, CFG.bonusCash) end
		if _G.__menuAddXp then pcall(_G.__menuAddXp, m.player, CFG.bonusXp) end
		if _G.__storyEvent then pcall(_G.__storyEvent, m.player, "storeRobbery") end
		push(m.player, {phase = "victory", cash = CFG.bonusCash, xp = CFG.bonusXp})
	else
		push(m.player, {phase = "defeat", reason = reason or ""})
	end
	if spent then
		storeClosedUntil = os.clock() + CFG.storeCooldown
		task.delay(CFG.storeCooldown, function(): ()
			reopenStore(m.worker)
		end)
	end
end

-- aiming and the prompt both end up here so all the entry checks live in one place
local function startMission(player: Player, viaPrompt: boolean, w: Model): ()
	if mission then
		if mission.player ~= player then
			push(player, {phase = "toast", text = "Someone is already robbing the store."})
		end
		return
	end
	if os.clock() < storeClosedUntil then
		push(player, {phase = "toast", text = ("The store is closed for %ds."):format(math.ceil(storeClosedUntil - os.clock()))})
		return
	end
	if lastRobbed[player] and os.clock() - lastRobbed[player] < CFG.playerCooldown then
		push(player, {phase = "toast", text = ("Lay low for %ds before the next job."):format(math.ceil(CFG.playerCooldown - (os.clock() - lastRobbed[player]))) })
		return
	end
	if _G.__menuIsInMenu and _G.__menuIsInMenu(player) then return end
	if not usable(w) or not rootOf(player) then return end

	mission = {
		player = player,
		step = 1,
		phase = "holdup",
		objective = "HOLD UP THE CASHIER",
		hint = viaPrompt and "Draw a gun and keep it aimed at him" or "Keep your gun on him until he gives in",
		progress = 0,
		deadline = os.clock() + CFG.holdUpTimeout,
		store = w.HumanoidRootPart.Position,
		worker = w,
	}
	push(player, {phase = "start"})
	status()
end

-- start: real hold up (aiming fires the game's "robbing" remote) or the prompt
-- weak keys so destroyed cashiers get cleaned up
local hooked: { [Model]: boolean } = setmetatable({}, {__mode = "k"})

local function hookWorker(w: Model): ()
	if hooked[w] then return end
	if w:GetAttribute("MenuStageVendor") == true then return end
	hooked[w] = true -- set before the yields below so a second call can't slip in
	local listeners = w:WaitForChild("listeners", 10)
	local aimed = listeners and listeners:WaitForChild("beingAimAt", 10)
	if aimed then
		aimed.Changed:Connect(function(): ()
			if aimed.Value ~= true then return end
			local robber = aimed:FindFirstChild("robber") and aimed.robber.Value
			if typeof(robber) == "Instance" and robber:IsA("Player") then
				startMission(robber, false, w)
			end
		end)
	end

	local root = w:WaitForChild("HumanoidRootPart", 10)
	if root and not root:FindFirstChild("RobPrompt") then
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "RobPrompt"
		prompt.ActionText = "Rob Store"
		prompt.ObjectText = "General Store"
		prompt.KeyboardKeyCode = Enum.KeyCode.G -- G and ButtonY so it doesn't clash with the shop prompt
		prompt.GamepadKeyCode = Enum.KeyCode.ButtonY
		prompt.HoldDuration = 0.4
		prompt.MaxActivationDistance = 12
		prompt.RequiresLineOfSight = false -- the counter blocks it otherwise
		prompt.UIOffset = Vector2.new(0, 60)
		prompt.Parent = root
		prompt.Triggered:Connect(function(player: Player): ()
			startMission(player, true, w)
		end)
	end
end

for _, c in ipairs(npcFolder:GetChildren()) do
	if c.Name == NAME then task.spawn(hookWorker, c) end
end
npcFolder.ChildAdded:Connect(function(c: Instance): ()
	if c.Name == NAME then task.defer(hookWorker, c) end -- reopened stores, defer lets the clone finish parenting
end)

-- the bag: ai throws a duffel bag into Objects.Money when the hand over anim ends
-- this place was missing Objects.Money so his bag drop errored, make sure it exists
local objects = workspace:WaitForChild("Objects")
local moneyFolder = objects:FindFirstChild("Money")
if not moneyFolder then
	moneyFolder = Instance.new("Folder")
	moneyFolder.Name = "Money"
	moneyFolder.Parent = objects
end

-- reads the cash off the bag's billboard, clamped so a bad label can't pay out a fortune
local function bagAmount(bag: BasePart): number
	local ok, text = pcall(function(): string return (bag :: any).moneyDisplay.ui.amount.Text end)
	local n = ok and tonumber((tostring(text):gsub("[^%d]", ""))) or nil
	return math.clamp(n or 100, 0, 1000)
end

local function startEscape(m: Mission): ()
	m.phase = "escape"
	m.step = 4
	m.objective = "ESCAPE"
	m.hint = "The alarm is ringing. Get clear of the store!"
	m.progress = 0
	m.deadline = os.clock() + CFG.escapeTime
	push(m.player, {phase = "alarm"})
	status({beat = true})
end

-- grab phase, nothing in the game picks these bags up so it gets its own prompt
local function armBag(bag: BasePart, m: Mission): ()
	m.bag = bag
	m.phase = "grab"
	m.step = 3
	m.objective = "GRAB THE CASH"
	m.hint = "Pick up the duffel bag he threw"
	m.progress = 0
	m.deadline = os.clock() + CFG.grabTimeout
	status({beat = true})

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "GrabPrompt"
	prompt.ActionText = "Grab Cash"
	prompt.ObjectText = "Duffel Bag"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = bag
	prompt.Triggered:Connect(function(player: Player): ()
		if mission ~= m or m.phase ~= "grab" or player ~= m.player then return end
		local root = rootOf(player)
		if not root or (root.Position - bag.Position).Magnitude > 14 then return end -- server distance check, bit of slack over the prompt's 10
		local amount = bagAmount(bag)
		-- switch phase before destroying or the bag gone handler fails the job
		startEscape(m)
		bag:Destroy()
		if _G.__menuAddCash and amount > 0 then pcall(_G.__menuAddCash, player, amount) end
		push(player, {phase = "toast", text = ("+$%d in the bag"):format(amount)})
	end)
	bag.AncestryChanged:Connect(function(_: Instance, parent: Instance?): ()
		if parent == nil and mission == m and m.phase == "grab" then -- bag vanished before the grab, fail instead of getting stuck
			finish(false, "The cash is gone.")
		end
	end)
end

moneyFolder.ChildAdded:Connect(function(bag: Instance): ()
	-- the ai renames it to Duffel Bag only after parenting it
	task.defer(function(): ()
		local m = mission
		if not m or (m.phase ~= "handover" and m.phase ~= "holdup") then return end
		if not bag:IsA("BasePart") or (bag.Name ~= "Duffel Bag" and bag.Name ~= "duffel_bag") then return end
		if (bag.Position - m.store).Magnitude > 20 then return end
		armBag(bag, m)
	end)
end)

-- mission tick
-- seconds of steady aim, drains at half speed when the aim slips
local aimTime: number = 0

-- one server loop runs every timer and distance check so the client can't speed anything up
task.spawn(function(): ()
	local last = os.clock()
	while true do
		task.wait(0.2)
		local now = os.clock()
		local dt = now - last
		last = now
		local m = mission -- snapshot since finish() can clear it mid tick
		if m then
			local root = rootOf(m.player)
			if not m.player.Parent then
				mission = nil
			elseif not root then
				finish(false, "You went down.")
			elseif m.deadline and now > m.deadline then
				local why = ({
					holdup = "The cashier hit the silent alarm.",
					handover = "The cashier stalled until the cops came.",
					grab = "You left the cash behind.",
					escape = "The cops boxed you in.",
				})[m.phase]
				finish(false, why)
			elseif m.phase == "holdup" then
				local w = m.worker
				local aimed = w and w:FindFirstChild("listeners") and w.listeners:FindFirstChild("beingAimAt")
				local fresh = aimed and aimed.Value and aimed.robber.Value == m.player and (tick() - aimed.update.Value) <= 0.6 -- aimed by this robber and recent, the ai stamps it with tick()
				if (root.Position - m.store).Magnitude > CFG.holdUpRange then
					finish(false, "You walked away from the job.")
				else
					if fresh then aimTime += dt else aimTime = math.max(0, aimTime - dt * 0.5) end
					m.progress = math.clamp(aimTime / CFG.holdUpNeed, 0, 1)
					if m.progress >= 1 then -- he gave in, hand over phase
						aimTime = 0
						m.phase = "handover"
						m.step = 2
						m.objective = "HE'S FILLING THE BAG"
						m.hint = "Stay close. Don't let him off the hook"
						m.progress = 0
						m.handStart = now
						m.deadline = now + CFG.handOverTimeout
						status({beat = true})
					else
						status()
					end
				end
			elseif m.phase == "handover" then
				m.progress = math.clamp((now - m.handStart) / 4, 0, 0.95) -- his anim is about 4s, holds at 95% till the bag lands
				status()
			elseif m.phase == "grab" then
				if m.bag and m.bag.Parent then
					local d = (root.Position - m.bag.Position).Magnitude
					m.progress = math.clamp(1 - d / 30, 0, 1)
				end
				status()
			elseif m.phase == "escape" then
				local d = (root.Position - m.store).Magnitude
				m.progress = math.clamp(d / CFG.escapeDistance, 0, 1)
				if d >= CFG.escapeDistance then
					finish(true)
				else
					status()
				end
			end
		end
	end
end)

-- leaving mid robbery ends it with no payout
Players.PlayerRemoving:Connect(function(p: Player): ()
	lastRobbed[p] = nil
	if mission and mission.player == p then
		if mission.phase ~= "holdup" then -- he already handed over so he's used up
			local spentWorker = mission.worker
			storeClosedUntil = os.clock() + CFG.storeCooldown
			task.delay(CFG.storeCooldown, function(): () reopenStore(spentWorker) end)
		end
		mission = nil
	end
end)
