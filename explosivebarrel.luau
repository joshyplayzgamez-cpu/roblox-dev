--!nonstrict
-- made by @extendedrealm on discord
-- explosive barrel, blows up when shot, burned down or slammed into stuff, then respawns
-- combattag, network and worldtogui aren't mine, credit to their authors

type Connections = { RBXScriptConnection }
type GuiConfig = { [string]: any }
type PositionLike = Instance | Vector3
type TagData = { damage: number, weapon: string }

return function(script: Script): ()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Players = game:GetService("Players")
	local ServerStorage = game:GetService("ServerStorage")
	local Debris = game:GetService("Debris")
	local RunService = game:GetService("RunService")

	local ClientStorage = ReplicatedStorage:WaitForChild("Storage")
	local Storage = ServerStorage:WaitForChild("Storage")

	local CombatTag = require(ClientStorage.Modules.CombatTag)
	local Network = require(ClientStorage.Modules.Network)
	local WorldToGui = require(ClientStorage.Modules.WorldToGui)

	local character = script.Parent :: Model
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

	-- clone before renaming so the respawn is a clean copy
	local clone = character:Clone()
	-- unique name so it never gets mixed up with its respawned twin
	character.Name = game:GetService("HttpService"):GenerateGUID(false)

	local connections: Connections? = {}

	local function getRandomChild(parent: Instance): Instance
		return parent:GetChildren()[math.random(#parent:GetChildren())]
	end

	-- climbs up until it finds a model with a humanoid, false if it's just map
	local function isHumanoid(part: Instance): Instance | false
		if part.Parent:FindFirstChild("Humanoid") then
			return part.Parent
		elseif part.Parent ~= workspace then
			return isHumanoid(part.Parent)
		end

		return false
	end

	local function toPosition(value: PositionLike): Vector3
		return (typeof(value) == "Instance" and (value :: BasePart).Position or value) :: Vector3
	end

	local function getDistance(p1: PositionLike, p2: PositionLike): number
		return (toPosition(p1) - toPosition(p2)).magnitude
	end

	local function emitParticle(name: string, multiplier: number?, v: Vector3 | Instance, dur: number?): Attachment
		local n = ClientStorage.Particles[name].Attachment:Clone()
		if typeof(v) == "Vector3" then
			n.Parent = workspace.Terrain
			n.WorldPosition = v
		else
			n.Parent = v
		end
		for _, p in pairs(n:GetChildren()) do
			p:Emit(p:GetAttribute("EmitCount") * (multiplier or 1))
		end
		-- the 3 does nothing, nil dur just means debris uses its 10s default
		Debris:AddItem(n, dur, 3)

		return n
	end

	-- scorch mark, surfacegui instead of a decal so it sits right on the hit point
	local function createGuiSurface(texture: string, part: BasePart, pos: Vector3, scale: number, size: Vector2, config: GuiConfig): SurfaceGui
		local surfaceFace, width, height, relativeX, relativeY = WorldToGui:WorldPositionToGuiPosition(part, pos)

		local surfaceGui = Instance.new("SurfaceGui")
		-- canvas is scale pixels per stud
		surfaceGui.CanvasSize = Vector2.new(scale * width, scale * height)
		surfaceGui.LightInfluence = 1
		surfaceGui.Face = surfaceFace

		local surfaceFrame = Instance.new("Frame")
		surfaceFrame.Size = UDim2.new(1, 0, 1, 0)
		surfaceFrame.BackgroundTransparency = 1
		surfaceFrame.ClipsDescendants = true
		surfaceFrame.BorderSizePixel = 0
		surfaceFrame.Parent = surfaceGui

		local decal = Instance.new("ImageLabel")
		decal.Image = texture
		decal.BorderSizePixel = 0
		decal.BackgroundTransparency = 1
		decal.Size = UDim2.new(0, scale * size.x, 0, scale * size.y)
		decal.AnchorPoint = Vector2.new(0.5, 0.5)
		decal.Position = UDim2.new(relativeX, 0, relativeY, 0)
		for prop, data in pairs(config) do
			decal[prop] = data
		end
		decal.Parent = surfaceFrame

		surfaceGui.Parent = part
		Debris:AddItem(surfaceGui, 10)

		return surfaceGui
	end

	-- fire
	local burning = false
	table.insert(connections, humanoid.HealthChanged:Connect(function(current: number): ()
		-- checks against 50 not 0.5 so pretty much any hit can light it, burning never gets set either, left as is
		if (current / humanoid.MaxHealth) <= 50 and not burning and humanoid.Health > 0 and math.random(3) == 1 then
			for _, v in pairs(humanoid.RootPart.Attachment:GetChildren()) do
				if v:IsA("Sound") then
					v:Play()
				elseif v:IsA("ParticleEmitter") or v:IsA("Light") then
					v.Enabled = true
				end
			end

			-- burn down slowly, random delay so barrels don't all tick in sync
			for _ = 1, humanoid.MaxHealth do
				humanoid:TakeDamage(0.5)
				task.wait(0.5 + (math.random() * 0.5))
			end
		end
	end))

	-- impact
	local start = tick()
	local lastVelocity = humanoid.RootPart.AssemblyLinearVelocity
	table.insert(connections, RunService.Heartbeat:Connect(function(_deltaTime: number): ()
		-- skip the first 5s so landing on spawn doesn't blow it up
		if humanoid.RootPart and tick() - start >= 5 then
			-- lost over 10 studs/s in one frame so it hit something hard
			local currentVelocity = humanoid.RootPart.AssemblyLinearVelocity
			if lastVelocity.magnitude - currentVelocity.magnitude > 10 then
				humanoid:TakeDamage(humanoid.MaxHealth)
			end

			lastVelocity = humanoid.RootPart.AssemblyLinearVelocity
		end
	end))

	-- explosion
	table.insert(connections, humanoid.Died:Connect(function(): ()
		for index, event in pairs(connections) do
			event:Disconnect()
			connections[index] = nil
		end
		connections = nil

		if humanoid.RootPart then
			-- hide the barrel for now, the clone swap happens later
			for _, v in pairs(character:GetDescendants()) do
				if v:IsA("BasePart") then
					v.Transparency = 1
					v.CanCollide = false
					v.CollisionGroup = "Debris"
				elseif v:IsA("ParticleEmitter") or v:IsA("Light") then
					v.Enabled = false
				elseif v:IsA("Sound") then
					v:Stop()
				end
			end

			humanoid.RootPart.Size = Vector3.new()

			-- scorch mark, only raycast against buildings so it lands on the floor
			local params = RaycastParams.new()
			params.FilterDescendantsInstances = { workspace.Buildings }
			params.FilterType = Enum.RaycastFilterType.Include
			local crater = workspace:Raycast(humanoid.RootPart.Position, Vector3.new(0, -10, 0), params)
			if crater then
				local size = math.random(1200, 1500) / 100
				createGuiSurface(
					"rbxassetid://2828069358",
					crater.Instance,
					crater.Position,
					128,
					Vector2.new(size, size),
					{
						["ImageTransparency"] = math.random(150, 250) / 1000,
						["Rotation"] = 0,
						["ResampleMode"] = Enum.ResamplerMode.Pixelated,
					}
				)
			end

			local explosionSound = getRandomChild(ClientStorage.Sounds.explosions)
			Network:FireAllClients("client", "createSound", explosionSound, humanoid.RootPart)

			-- no blast pressure or joint breaking, damage and knockback are done by hand below
			local hitted: { [Instance]: boolean } = {}
			local explosion = Instance.new("Explosion")
			explosion.BlastPressure = 0
			explosion.BlastRadius = 18
			explosion.DestroyJointRadiusPercent = 0
			explosion.ExplosionType = Enum.ExplosionType.NoCraters
			explosion.Position = humanoid.RootPart.Position
			explosion.Parent = workspace.Terrain
			-- hit fires once per part, hitted stops one character getting hit 15 times
			explosion.Hit:Connect(function(part: BasePart): ()
				local target = isHumanoid(part)
				local player = target and game:GetService("Players"):GetPlayerFromCharacter(target)
				-- npcs always count, players only if they have pvp on
				local pvp = player and ReplicatedStorage.__profiles[player.Name].pvp.Value or not player
				if
					target
					and target:IsDescendantOf(workspace.Characters)
					and not hitted[target]
					and part.Parent == target
					and part:GetAttribute("Enabled") -- skip limbs that already got gibbed
					and not target:FindFirstChildWhichIsA("ForceField")
					and pvp
				then
					hitted[target] = true

					task.defer(function(): ()
						local lastHealth = target.Humanoid.Health
						local dead = false

						-- less damage the further away you are
						local ragdoll = false
						local dist = getDistance(target.Humanoid.RootPart, explosion.Position)
						local baseDamage = 30
						local damage = explosion.BlastRadius / (dist / 2) * baseDamage

						if damage > 30 then
							ragdoll = true
						end

						-- tag the shooter so the kill goes to them, pvp off means they can't hurt other players
						local killer = CombatTag:getKiller(character)
						if killer and Players:FindFirstChild(killer) then
							if ReplicatedStorage.__profiles[killer].pvp.Value == false and target.Name ~= killer and Players:GetPlayerFromCharacter(target) then
								return
							end

							local tagData: TagData = { damage = damage, weapon = "Explosive Barrel" }
							CombatTag:addTag(target, Players[killer].Character, tagData)
						end
						target.Humanoid:TakeDamage(damage)

						if target.Humanoid.Health <= 0 and lastHealth > 0 then
							dead = true
						end

						-- gore, raycast through each limb to get a real hit point for the client
						local parts: { BasePart } = {}
						if dead then
							for _, bodyPart in pairs(target:GetChildren()) do
								if bodyPart:IsA("BasePart") then
									local goreParams = RaycastParams.new()
									goreParams.FilterDescendantsInstances = { target }
									goreParams.CollisionGroup = "Raycast"
									goreParams.FilterType = Enum.RaycastFilterType.Whitelist -- old name for include

									local origin = bodyPart.Position + (bodyPart.CFrame.LookVector * -1)
									local dir = bodyPart.CFrame.LookVector * 2
									local cast = workspace:Raycast(origin, dir, goreParams)
									if cast then
										local gib, _ = _G.getGibFromPosition(cast.Instance, cast.Position)
										local awayFromBlast = (target.Humanoid.RootPart.Position - humanoid.RootPart.Position).unit * 2
										local headLook = target.Head.CFrame.LookVector
										Network:FireAllClients("client", "gore", target, cast.Instance, damage, gib, awayFromBlast, cast.Position, headLook, cast.Normal, false)
									end

									-- 1 in 5 limbs gets blown off
									if math.random(5) == 1 then
										parts[#parts + 1] = bodyPart
									end
								end
							end
						end

						-- ragdoll and shove them away from the barrel
						if ragdoll then
							target.Humanoid:SetAttribute("RagdollDur", 3.5) -- set before ragdoll so it gets read
							target.Humanoid:SetAttribute("Ragdoll", true)

							-- short bodyvelocity works like an impulse
							local force = Instance.new("BodyVelocity")
							force.MaxForce = Vector3.new(1e11, 1e11, 1e11)
							local awayDirection = (target.Humanoid.RootPart.Position - humanoid.RootPart.Position).unit
							local knockbackSpeed = math.max(damage / 4, 15)
							local upwardKick = Vector3.new(0, math.random(8, 12), 0)
							force.Velocity = awayDirection * knockbackSpeed + upwardKick
							force.Parent = part
							Debris:AddItem(force, 0.1)
							if part:GetAttribute("Enabled") then
								target.Humanoid.RootPart.Velocity = part.Velocity / 2
							end
						end
						emitParticle("BloodHitEffect", nil, target.Humanoid.RootPart.Position)

						-- dismemberment, deferred so the gore goes out first
						if dead then
							task.defer(function(): ()
								for _, limb in pairs(parts) do
									if limb:GetAttribute("Limbs") then
										limb:SetAttribute("Enabled", false)
										_G.createSound(getRandomChild(ClientStorage.Sounds.fleshHits), limb):Play()
										emitParticle("BloodHitEffect", nil, limb.Position)
									end
								end
							end)
						end
					end)
				elseif target and target:IsDescendantOf(workspace.Buildings.Objects) then
					-- chain reaction, small delay so it ripples outward
					task.wait(1 / 15)
					-- whoever started the chain gets credit for every barrel in it
					local killer = CombatTag:getKiller(character)
					if killer and Players:FindFirstChild(killer) then
						local tagData: TagData = { damage = 1000, weapon = "Explosive Barrel" }
						CombatTag:addTag(target, Players[killer].Character, tagData)
					end
					target.Humanoid:TakeDamage(1000)
				elseif not target and part:IsDescendantOf(workspace.Buildings.Glass) then
					-- glass, shards fly away from the barrel
					local shardVelocity = (part.Position - humanoid.RootPart.Position).unit * 30 + Vector3.new(0, math.random(8, 12), 0)
					ClientStorage.Events.glass:Fire(part, part.Position, shardVelocity)
				end
			end)

			-- clear hitted once the explosion is gone
			local connection: RBXScriptConnection
			connection = explosion.AncestryChanged:Connect(function(_: Instance, parent: Instance?): ()
				if parent == nil then
					connection:Disconnect()
					table.clear(hitted)
				end
			end)

			-- camera shake, stronger the closer you are
			for _, player in pairs(Players:GetPlayers()) do
				local pChar = player.Character
				local pHum = pChar:FindFirstChild("Humanoid")
				if pHum.Health > 0 and pHum.RootPart and getDistance(pHum.RootPart, humanoid.RootPart) <= 150 then
					local dist = getDistance(pHum.RootPart, humanoid.RootPart)
					local intensity = math.clamp(80 - dist, 5, 60)
					ClientStorage.Events.shake:FireClient(player, { Damping = 1.2 }, intensity, 0.8, true)
				end
			end
		end

		-- respawn the clean clone after 8s
		task.wait(8)
		clone.Parent = character.Parent
		character:Destroy()
	end))

	-- stops it trying to stand up so it acts like a normal prop
	humanoid.PlatformStand = true
end
