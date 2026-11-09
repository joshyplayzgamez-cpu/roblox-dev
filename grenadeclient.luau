--!nonstrict
-- made by @extendedrealm on discord
-- client side of the grenade tool, click to aim with an arc preview then click again to throw
-- trajectory, network, mobile ui and smartbone modules aren't mine, credit to their authors

-- only the fields this script reads, the rest is shared with guns and melee
type GrenadeSettings = {
	handle: string,
	maxBounce: number,
	speed: number,
	upForce: number, -- extra lift so throws lob instead of going flat
	equipTime: number,
	delay: number, -- gun cooldown reused here for inspect and holster
	simulatePhysicsParts: { string },
	anims: { [string]: any },
	[string]: any,
}

-- { x0, v0, t, hitPosition, hitNormal }
type TrajectorySegment = { any }

-- { hitPosition, hitNormal }
type TrajectoryPoint = { Vector3 }

type TrajectoryCaster = {
	Cast: (self: any, x0: Vector3, v0: Vector3, material: Enum.Material, ignoreList: { Instance }) -> { TrajectorySegment },
	Draw: (self: any, path: { TrajectorySegment }, beamColor: Color3?) -> ({ Instance }, TrajectoryPoint?),
	[string]: any,
}

-- value is a track or a table of tracks
type AnimTable = { [string]: any }

return function(script: LocalScript): ()
	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local RunService = game:GetService("RunService")
	local UserInputService = game:GetService("UserInputService")
	local TweenService = game:GetService("TweenService")
	local CollectionService = game:GetService("CollectionService")

	local Storage = ReplicatedStorage:WaitForChild("Storage")

	local Network = require(Storage.Modules.Network)

	local player = Players.LocalPlayer
	local mouse = player:GetMouse()
	local camera = workspace.CurrentCamera

	-- tools can run this before the respawned character is parented, so wait till it's actually in workspace
	local character = player.Character
	if not character then
		character = player.CharacterAdded:Wait()
	else
		while not player.Character or not player.Character:IsDescendantOf(workspace) do
			task.wait()
		end

		task.wait(1 / 30) -- small extra wait so humanoid and animator have replicated
	end
	character = player.Character

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local animator = humanoid:WaitForChild("Animator") :: Animator

	local tool = script.Parent :: Tool
	local settings: GrenadeSettings = require(Storage.Modules.Weapons:WaitForChild(tool.Name))
	local handle = tool:WaitForChild("_mod"):WaitForChild(settings.handle)

	-- real workspace gravity so the preview bends the same as the server projectile
	local Trajectory: TrajectoryCaster = require(Storage.Modules.Trajectory).new(Vector3.new(0, -game.Workspace.Gravity, 0), {MaxBounce = settings.maxBounce})

	-- hud is shared with the guns and chainsaw so it gets reset on equip
	local UI = player.PlayerGui:WaitForChild("UI")
	local gunInfo = UI:WaitForChild("HUD_GAMEPLAY"):WaitForChild("gunInfo"):WaitForChild("main")
	local chainsawInfo = UI:WaitForChild("HUD_GAMEPLAY"):WaitForChild("chainsawInfo"):WaitForChild("main")

	local function loadAnim(id: number | string): AnimationTrack
		local animTrack = Instance.new("Animation")
		animTrack.AnimationId = "rbxassetid://" .. id
		return animator:LoadAnimation(animTrack),
			animTrack:Destroy() -- track still works after the animation instance is gone
	end

	local data: { [string]: any } = {}
	for _, var in pairs(tool._data:GetChildren()) do
		data[var.Name] = (var :: any).Value
	end

	-- anims can be a single id or a nested table of ids, tracks mirror that shape
	local anims: AnimTable = {}
	for animName, id in pairs(settings.anims) do
		if typeof(settings.anims[animName]) == "table" then
			anims[animName] = {}
			for animName2, id2 in pairs(settings.anims[animName]) do
				anims[animName][animName2] = loadAnim(id2)
			end
		else
			anims[animName] = loadAnim(id)
		end
	end

	-- active = pin pulled and aiming, used = already thrown, never resets
	local active = false
	local used = false

	local function clampDistanceBetweenVectors(V1: Vector3, V2: Vector3, Max: number): Vector3 -- v1 is the origin
		return V1 + ((V2 - V1).Unit * math.min((V2 - V1).Magnitude, Max))
	end

	local equipTick = 0
	local rateTick = 0
	local equipTime = 0

	local function isEquipped(): boolean
		return tick() - equipTick >= settings.equipTime
	end

	local hints = {
		["H"] = anims.inspect and {info = "Inspect"} or nil,
	}

	local trajectoryConnection: RBXScriptConnection?
	local components: { Instance }?

	-- one landing marker cloned once and reused, tagged so raycasts ignore it
	local trajectorHitPoint = Storage.Models.trajectoryPoint:Clone()
	CollectionService:AddTag(trajectorHitPoint, "_Trajectory")

	-- clears this frame's beams, disconnect also stops the preview loop and hides the marker
	local function clearTrajectory(disconnect: boolean?): ()
		if components then
			for _, v in pairs(components) do
				v:Destroy()
			end
			table.clear(components)
			components = nil
		end

		if disconnect and trajectoryConnection then
			trajectorHitPoint.Parent = nil
			trajectoryConnection:Disconnect()
			trajectoryConnection = nil
		end
	end

	-- attributes set by the server ragdoll and combat stuff
	local function isHealthy(): boolean
		local isRagdolled = humanoid:GetAttribute("Ragdoll")
		local isDowned = humanoid:GetAttribute("Downed")
		local isCarried = humanoid:GetAttribute("Carried")
		return not isRagdolled and not isDowned and not isCarried and humanoid.Health > 0
	end

	-- shared by the H key and the mobile button so they can't disagree
	local function canInspect(): boolean
		return not active
			and tick() - rateTick >= settings.delay
			and humanoid.Health > 0
			and isEquipped()
			and anims.inspect ~= nil
			and not anims.inspect.IsPlaying
			and not anims.use.IsPlaying
	end

	-- indexed live instead of using the cached handle
	local function getHandlePosition(): Vector3
		return tool._mod[settings.handle].Position
	end

	local function getAimDirection(): Vector3
		return (mouse.Hit.p - getHandlePosition()).unit
	end

	-- arc preview, waits for the pin pull to finish then redraws every frame
	local function stepTrajectoryPreview(dt: number): ()
		_G.aim = true
		if not anims.use.IsPlaying and isHealthy() then
			active = true
			clearTrajectory()

			if not trajectorHitPoint:IsDescendantOf(workspace) then
				trajectorHitPoint.Parent = workspace.Ignored -- ignored folder so the marker can't block its own arc
			end

			local dir = getAimDirection()
			-- start the arc 2 studs out so it doesn't hit the hand
			local x0 = getHandlePosition() + dir * 2
			-- same numbers the server uses for the real throw
			local v0 = dir * settings.speed + Vector3.new(0, settings.upForce, 0)

			local path = Trajectory:Cast(x0, v0, Enum.Material.Plastic, {workspace.Ignored, camera})
			local point: TrajectoryPoint?
			components, point = Trajectory:Draw(path)
			-- lay the marker flat on the hit surface, park it far away when there's no hit
			trajectorHitPoint.CFrame = point and CFrame.new(point[1], point[1] + point[2]) * CFrame.Angles(math.rad(-90), 0, 0) or CFrame.new(10e5, 10e5, 10e5)
		end
	end

	-- first click, pull the pin and start the preview
	local function beginAiming(): ()
		Storage.Events.client:Fire("cMeleeFire", tool, settings)
		anims.throw_idle:Play()
		anims.use.Priority = Enum.AnimationPriority.Action4
		anims.use:Play(0.0000001) -- basically no fade so the pin pull snaps in
		_G.grenadeUse = true
		_G.grenadeEquipped = true

		trajectoryConnection = RunService.Heartbeat:Connect(stepTrajectoryPreview)
	end

	-- second click, server spawns the grenade, client only sends origin and direction
	local function releaseThrow(): ()
		anims.use:Stop()
		anims.throw_idle:Stop()
		clearTrajectory(true)
		_G.aim = false
		_G.grenadeUse = false
		_G.grenadeEquipped = false

		if isHealthy() then -- got knocked between clicks = no throw
			active = false
			used = true
			anims.idle:Stop()
			anims.throw:Play()
			Storage.Events.client:Fire("cMeleeFire", tool, settings)

			local dir = getAimDirection()
			Network:FireServer("grenade", tool, getHandlePosition(), dir)
		end

		anims.cancel:Play()
	end

	-- pc and mobile both go through this so there's only one throw path
	local function grenadeActivate(): ()
		if not isHealthy() then return end
		if anims.inspect and anims.inspect.IsPlaying then
			anims.inspect:Stop() -- click during inspect just cancels it
			return
		end

		if isEquipped() and not used then
			if not active then
				if anims.use.IsPlaying then
					return -- ignore spam while the pin is still coming out
				end

				beginAiming()
			elseif active and not used then
				releaseThrow()
			end
		end
	end

	local keyHints: { GuiObject } = {}
	local connections: { RBXScriptConnection } = {}

	local function onInputBegan(inputObject: InputObject, process: boolean): ()
		if not process then
			if inputObject.KeyCode == Enum.KeyCode.H and canInspect() then
				anims.inspect:Play()
			elseif inputObject.UserInputType == Enum.UserInputType.MouseButton1 and isHealthy() then
				grenadeActivate()
			end
		end
	end

	-- mobile buttons, runs in a pcall so a broken ui doesn't kill the grenade
	local function buildMobileControls(): ()
		local MobileWeaponUI = require(Storage.Modules:WaitForChild("MobileWeaponUI"))

		local mobileGui = tool:WaitForChild("MobileUI"):Clone()
		mobileGui.Name = "MobileUI"
		mobileGui.Enabled = true
		mobileGui.ResetOnSpawn = false
		mobileGui.DisplayOrder = 6
		mobileGui.Parent = player.PlayerGui

		-- passes the shared connections table so unequip cleans these up too
		local mc = MobileWeaponUI.new(mobileGui, connections)

		local fireFrame = mobileGui:FindFirstChild("fire")
		local inspectFrame = mobileGui:FindFirstChild("inspect")
		local scopeFrame = mobileGui:FindFirstChild("scopeToggle")

		mc:button("fire", {
			frame = fireFrame,
			label = "THROW",
			mode = "tap",
			tap = function(): ()
				grenadeActivate()
			end,
		})

		mc:button("inspect", {
			frame = inspectFrame,
			label = "INSPECT",
			mode = "tap",
			show = anims.inspect ~= nil,
			tap = function(): ()
				if anims.inspect and canInspect() then
					anims.inspect:Play()
				end
			end,
		})

		-- no aim button, grenades aim on their own
		mc:button("aim", { frame = scopeFrame, show = false })

		local destroyConn: RBXScriptConnection?
		destroyConn = tool.Unequipped:Connect(function(): ()
			if destroyConn then
				destroyConn:Disconnect()
				destroyConn = nil
			end
			mc:destroy()
		end)
	end

	-- lowers the grenade while sprinting and keeps idle in sync
	local function stepHolster(): ()
		if tick() - rateTick >= settings.delay and anims.holster and _G.run then
			anims.holster.Priority = Enum.AnimationPriority.Action
			if not anims.holster.IsPlaying then
				anims.holster:Play(0.1)
			end
		elseif anims.holster and anims.holster.IsPlaying then
			anims.holster:Stop(0.25)
		end

		if anims.holster and anims.holster.IsPlaying then
			anims.idle:Stop(0.25)
		elseif not anims.idle.IsPlaying then
			anims.idle:Play(0.25)
		end

		if anims.inspect then
			_G.inspect = anims.inspect.IsPlaying
		end
	end

	local function onEquipped(): ()
		if used then
			humanoid:UnequipTools() -- thrown grenade can't be held again
			return
		end

		_G.grenadeEquipped = true
		anims.cancel:Play()
		for _, partName in pairs(settings.simulatePhysicsParts) do
			CollectionService:AddTag(tool._mod[partName], "SmartBone")
		end
		UI.circularBar.Visible = false
		equipTick = tick()
		-- tiny tween instead of setting it so it overrides whatever tween the last weapon left running
		TweenService:Create(gunInfo.reloadProgress, TweenInfo.new(16e-5, Enum.EasingStyle.Sine), {Size = UDim2.new(0, 0, 1, 0), Transparency = 0.5, BackgroundColor3 = Color3.fromRGB(255, 255, 255)}):Play()
		equipTime = 0

		for key, hintData in pairs(hints) do
			local frame = _G.setKeyHint(key, hintData.info, 5)
			keyHints[#keyHints + 1] = frame
		end

		anims.idle.Priority = Enum.AnimationPriority.Action
		anims.equip.Priority = Enum.AnimationPriority.Action2
		anims.equip:Play()
		anims.idle:Play()

		table.insert(connections, UserInputService.InputBegan:Connect(onInputBegan))

		if UserInputService.TouchEnabled then
			local _mobileOk, _mobileErr = pcall(buildMobileControls)
			if not _mobileOk then warn("[MobileWeaponUI] grenade:", _mobileErr) end
		end

		if anims.holster then
			table.insert(connections, RunService.Heartbeat:Connect(stepHolster))
		end
	end

	local function stopAllAnimations(): ()
		for index, v in pairs(anims) do
			if typeof(anims[index]) == "table" then
				for _, k in pairs(anims[index]) do
					k:AdjustWeight(0)
					k:Stop()
				end
			else
				v:AdjustWeight(0)
				v:Stop()
			end
		end
	end

	local function onUnequipped(): ()
		if active or anims.use.IsPlaying then
			-- pin's already out so drop it instead of cancelling, server expects this exact dir from here
			local dir = (getHandlePosition() + Vector3.new(0, -100, 0)).unit
			Network:FireServer("grenade", tool, getHandlePosition(), dir)
		end
		active = false

		-- reset flags so camera, sprint and hud don't get stuck in grenade mode
		_G.grenadeEquipped = false
		_G.aim = false
		_G.grenadeUse = false
		_G.inspect = false
		UI.circularBar.Visible = false
		UI.HUD_GAMEPLAY.chainsawInfo.Visible = false
		clearTrajectory(true)

		for i, v in pairs(connections) do
			v:Disconnect()
			connections[i] = nil -- cleared in place since MobileWeaponUI holds the same table
		end

		for index, frame in pairs(keyHints) do
			if frame:IsDescendantOf(game) then
				_G.clearKeyHint(frame)
			end

			keyHints[index] = nil
		end
		keyHints = {}

		TweenService:Create(camera, TweenInfo.new(16e-5, Enum.EasingStyle.Sine), {FieldOfView = 70}):Play()

		stopAllAnimations()
	end

	-- respawned already holding it, equipped already fired
	if tool:IsDescendantOf(character) then
		onEquipped()
	end

	tool.Equipped:Connect(onEquipped)
	tool.Unequipped:Connect(onUnequipped)

	-- stop anims when the tool gets destroyed
	local connection: RBXScriptConnection
	connection = tool.AncestryChanged:Connect(function(_: Instance, parent: Instance?): ()
		if parent == nil then
			connection:Disconnect()

			stopAllAnimations()
		end
	end)
end
