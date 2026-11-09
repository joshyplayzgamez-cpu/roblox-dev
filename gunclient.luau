--!nonstrict
-- super sorry to the hd team, its my first time doing this and using github like this, super sorry if i did something dumb.
-- made by @extendedrealm on discord
-- client side of my gun framework, one copy runs inside each gun tool, works for players and npcs (AI is the npc character)
-- network is EasyNetwork from the devforum, not mine, credit to its author
-- weapon settings are different per gun so these stay loose
type WeaponSettings = { [string]: any }

type AnimTable = { [string]: any }

type InputKey = Enum.KeyCode | Enum.UserInputType

return function(script: Instance, AI: Model?): ()
	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local RunService = game:GetService("RunService")
	local UserInputService = game:GetService("UserInputService")
	local TweenService = game:GetService("TweenService")
	local Debris = game:GetService("Debris")

	local Storage = ReplicatedStorage:WaitForChild("Storage")

	local Network = require(Storage.Modules.Network)

	local player = not AI and Players.LocalPlayer
	local mouse = not AI and player:GetMouse()
	local camera = workspace.CurrentCamera

	local character = AI or player.Character
	if not AI then
		if not character then
			character = player.CharacterAdded:Wait()
		else
			-- on respawn the character can exist before it's in workspace so wait for it
			while not player.Character or not player.Character:IsDescendantOf(workspace) do
				task.wait()
			end

			task.wait(1 / 30)
		end
		character = player.Character
	end

	local humanoid = character:WaitForChild("Humanoid")
	local animator = humanoid:WaitForChild("Animator")

	local tool = script.Parent
	local handle = tool:WaitForChild("_mod"):WaitForChild("Handle")

	-- npcs can't press keys so the npc brain fires this with key and "began" or "ended"
	local activateEvent
	if AI then
		activateEvent = Instance.new("BindableEvent")
		activateEvent.Name = "activateEvent"
		activateEvent.Parent = tool
	end

	local settings: WeaponSettings = require(Storage.Modules.Weapons:WaitForChild(tool.Name))
	local UI = player and player.PlayerGui:WaitForChild("UI")
	local gunInfo = UI and UI:WaitForChild("HUD_GAMEPLAY"):WaitForChild("gunInfo"):WaitForChild("main")

	-- load a track then destroy the animation object, the track still works
	local function loadAnim(id: number | string): AnimationTrack
		local animTrack = Instance.new("Animation")
		animTrack.AnimationId = "rbxassetid://" .. id
		return animator:LoadAnimation(animTrack),
			animTrack:Destroy()
	end

	-- local copy of the server ammo so the hud can predict without waiting
	local data = {}
	for _, var in pairs(tool._data:GetChildren()) do
		data[var.Name] = var.Value
	end

	local anims: AnimTable = {}
	for animName, id in pairs(settings.anims) do -- preload everything so the first shot doesn't hitch
		anims[animName] = loadAnim(id)
	end

	-- players share flags through _G, npcs use attributes so they don't overwrite each other
	local function getGlobal(name: string): any
		return AI and character:GetAttribute(name) or _G[name]
	end

	local function setGlobal(name: string, value: any): ()
		if AI then
			character:SetAttribute(name, value)
		else
			_G[name] = value
		end
	end

	local reloading = false
	local active = false
	local fireProcess = false
	local isActuallyAiming = false
	setGlobal("reload", false) -- reset in case the last gun got dropped mid reload

	local function getDistance(p1: Vector3 | Instance, p2: Vector3 | Instance): number
		return ((typeof(p1) == "Instance" and p1.Position or p1) - (typeof(p2) == "Instance" and p2.Position or p2)).magnitude
	end

	local function getRandomChild(parent: Instance): Instance
		return parent:GetChildren()[math.random(#parent:GetChildren())]
	end

	local equipTick = 0
	local rateTick = 0
	local reloadFinishTime -- tac reload end time, set from an anim marker
	local walkSpeed = 0

	local fireMode = settings.mode -- 1 single 2 burst 3 auto
	local currentFireMode = 1
	local fireModeDelay = 0

	local function isEquipped(): boolean
		return tick() - equipTick >= settings.equipTime
	end

	-- walk up from the hit part until something has a humanoid
	local function isHumanoid(part: Instance): Instance | false
		if part.Parent:FindFirstChild("Humanoid") then
			return part.Parent
		elseif part.Parent ~= workspace then
			return isHumanoid(part.Parent)
		end

		return false
	end

	-- ignores vfx, the camera and the shooter, Raycast group so invisible walls don't eat bullets
	local gunParams = RaycastParams.new()
	gunParams.FilterDescendantsInstances = {workspace.Ignored, camera, character}
	gunParams.FilterType = Enum.RaycastFilterType.Exclude
	gunParams.CollisionGroup = "Raycast"

	-- cast from the camera so the bullet goes where the crosshair is, then aim from the head
	local function getHitPos(muzzle: Attachment): (Vector3, Vector3)
		local head = character:FindFirstChild("Head")
		-- on mobile mouse.UnitRay points at the last touch which is the fire button so use the camera
		local aimDir = (not AI and UserInputService.TouchEnabled) and camera.CFrame.LookVector or mouse.UnitRay.Direction
		local cast = workspace:Raycast(camera.CFrame.Position, aimDir.unit * 10000, gunParams)
		local origin = head and head.Position or muzzle.WorldPosition
		if cast then
			return origin, (cast.Position - origin).unit
		end

		return origin, aimDir
	end

	-- same idea but checks if a wall is between the head and what the crosshair is on
	local function sightBlocked(muzzle: Attachment): (boolean, Vector3?)
		local head = character:FindFirstChild("Head")
		local aimDir = (not AI and UserInputService.TouchEnabled) and camera.CFrame.LookVector or mouse.UnitRay.Direction
		local cast = workspace:Raycast(camera.CFrame.Position, aimDir.unit * 10000, gunParams)
		local origin = head and head.Position or muzzle.WorldPosition
		if cast then
			-- push the target out by the normal so the surface itself doesn't count
			local cast2 = workspace:Raycast(origin, (cast.Position + cast.Normal) - origin, gunParams)
			if cast2 and getDistance(origin, cast2.Position) < 50 and not isHumanoid(cast2.Instance) then
				return true, cast2.Position
			end
		end

		return false
	end

	-- holster anim doubles as the run cycle, speed follows running speed, frozen otherwise
	humanoid.Running:Connect(function(speed: number): ()
		if anims.holster then
			if getGlobal("run") then
				anims.holster:AdjustSpeed(speed / 10)
			else
				anims.holster:AdjustSpeed(0)
			end
		end

		walkSpeed = speed
	end)

	-- key hints on equip, only for stuff this gun can do
	local hints = {
		["T"] = anims.shove and {info = "Shove"} or nil,
		["H"] = anims.inspect and {info = "Inspect"} or nil,
		["B"] = settings.mode_switch and {info = "Switch Mode"} or nil,
	}

	local keyHints = {}
	-- every press goes through here, keyboard, mouse, mobile buttons and the npc brain
	local function gunFunctionBegan(key: InputKey): ()
		-- reload
		if key == Enum.KeyCode.R and not settings.noReload and not reloading and data.magCurrent < data.magSize and data.ammo > 0 and isEquipped() then
			reloading = true
			setGlobal("reload", true)
			-- Length is 0 until the anim streams in and the timing divides by it
			while (settings.shotgun and anims.load.Length <= 0 or not settings.shotgun and anims.reload.Length <= 0) and tool:IsDescendantOf(character) do
				task.wait()
			end

			if tool:IsDescendantOf(character) then
				-- reset any leftover recoil pose so it doesn't fight the reload
				anims.fire.Priority = Enum.AnimationPriority.Core
				anims.fire:Play()
				if not getGlobal("aim") then
					anims.fire:AdjustWeight(1)
				end
				anims.fire:Stop()
				-- reloading cancels inspect and fan fire
				if anims.inspect then
					anims.inspect:Stop(0.00000001)
				end
				if anims.inspect_empty then
					anims.inspect_empty:Stop(0.00000001)
				end
				if anims.fanfire then
					anims.fanfire:Stop()
				end

				if not AI then
					gunInfo.reloadProgress.Size = UDim2.new(0, 0, 1, 0)
					gunInfo.reloadProgress.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
					gunInfo.reloadProgress.Transparency = 0.5

					UI.circularBar.Visible = true
					-- the ring is two halves, each one fills by rotating its gradient
					UI.circularBar.right.image.UIGradient.Rotation = 0
					UI.circularBar.left.image.UIGradient.Rotation = 180

					-- pulse the ring while reloading
					task.spawn(function(): ()
						while reloading do
							local alpha = 0.5 + (math.abs(math.sin(tick() * 3.5) * 0.5))
							UI.circularBar.right.image.ImageColor3 = Color3.fromRGB(60, 60, 60):Lerp(Color3.fromRGB(255, 255, 255), alpha)
							UI.circularBar.left.image.ImageColor3 = Color3.fromRGB(60, 60, 60):Lerp(Color3.fromRGB(255, 255, 255), alpha)
							task.wait()
						end

						-- pcall cause the ui might be gone if the player died mid reload
						pcall(function(): ()
							UI.circularBar.right.image.ImageColor3 = Color3.fromRGB(255, 255, 255)
							UI.circularBar.left.image.ImageColor3 = Color3.fromRGB(255, 255, 255)
						end)
					end)
				end

				if settings.shotgun then
					-- shotguns load one shell at a time
					if not AI then
						Network:FireServer("vars", "reload", {tool = tool, state = true})
					end

					if data.magCurrent <= 0 then
						-- preload_empty chambers a shell itself so credit it halfway through
						anims.preload_empty.Priority = Enum.AnimationPriority.Action3
						anims.preload_empty:Play()
						task.wait(anims.preload_empty.Length / 2)
						if tool:IsDescendantOf(character) and reloading then
							if not AI then
								Network:FireServer("vars", "reload", {tool = tool, add = true})
							end
							data.magCurrent += 1
							data.ammo = math.max(data.ammo - 1, 0)
							if AI then
								-- npcs run on the server so they can write the real values
								tool._data.magCurrent.Value = data.magCurrent
								tool._data.ammo.Value = data.ammo
							end
						end
						task.wait((anims.preload_empty.Length / 2) - 0.1) -- 0.1s early so load blends in
					else
						anims.preload.Priority = Enum.AnimationPriority.Action3
						anims.preload:Play()
						task.wait(anims.preload.Length - 0.1)
					end

					if tool:IsDescendantOf(character) and reloading and not humanoid:GetAttribute("Ragdoll") and humanoid.Health > 0 and data.magCurrent < data.magSize and data.ammo > 0 then
						anims.load.Priority = Enum.AnimationPriority.Action3
						if not AI then
							-- ring follows progress through the current shell
							task.spawn(function(): ()
								while reloading and tool:IsDescendantOf(character) do
									local progress = (anims.load.TimePosition / anims.load.Length) * 100
									if progress > 50 then
										UI.circularBar.right.image.UIGradient.Rotation = 180
										TweenService:Create(UI.circularBar.left.image.UIGradient, TweenInfo.new(1 / 15), {Rotation = (progress / 100) * 360}):Play()
									else
										UI.circularBar.left.image.UIGradient.Rotation = 180
										TweenService:Create(UI.circularBar.right.image.UIGradient, TweenInfo.new(1 / 15), {Rotation = (progress / 50) * 180}):Play()
									end

									task.wait(1 / 15)
								end
							end)
						end

						local isReloaded = false
						-- one loop per shell, holding fire stops loading so you can shoot what's in the tube
						while tool:IsDescendantOf(character) and reloading and not humanoid:GetAttribute("Ragdoll") and humanoid.Health > 0 and (AI or not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)) and data.magCurrent < data.magSize and data.ammo > 0 do
							anims.load:Play()
							-- wait for the shell anim to finish or get stopped
							while true do
								if anims.load.TimePosition >= anims.load.Length then
									isReloaded = true
									break
								end

								if not anims.load.IsPlaying then
									break
								end

								task.wait()
							end

							if tool:IsDescendantOf(character) and reloading and isReloaded then
								if not AI then
									Network:FireServer("vars", "reload", {tool = tool, add = true})
								end
								data.magCurrent += 1
								data.ammo = math.max(data.ammo - 1, 0)
								if AI then
									tool._data.magCurrent.Value = data.magCurrent
									tool._data.ammo.Value = data.ammo
								end
							end

							if data.magCurrent >= data.magSize then
								break
							end
						end

						-- don't hide the ring if another gun is using it now
						if tool:IsDescendantOf(character) or not character:FindFirstChildWhichIsA("Tool") then
							UI.circularBar.Visible = false
						end
					end

					if tool:IsDescendantOf(character) then
						if not AI then
							Network:FireServer("vars", "reload", {tool = tool, client = true})
						end
						anims.afterload.Priority = Enum.AnimationPriority.Action3
						anims.afterload:Play() -- pump, firing waits for this
					end
				else
					-- magazine guns
					anims.reload.Priority = Enum.AnimationPriority.Action3
					anims.reload:Play()
					-- tac reload can finish early at the tacReload or clipIn marker
					local getTime
					getTime = anims.reload:GetMarkerReachedSignal(settings.tacReloadMarker and "tacReload" or "clipIn"):Connect(function(): ()
						if not reloadFinishTime and not settings.noTacReload then
							reloadFinishTime = anims.reload.TimePosition + settings.tacReloadAdditional
						end

						if anims.noammo then
							anims.noammo:Stop()
						end
					end)
					if not AI then
						Network:FireServer("vars", "reload", {tool = tool, state = true})
					end

					local isReloaded = false
					while tool:IsDescendantOf(character) and reloading and not humanoid:GetAttribute("Ragdoll") and humanoid.Health > 0 do
						local maxTime = data.magCurrent > 0 and reloadFinishTime or anims.reload.Length
						-- done at the end of the track, or early on a tac reload
						if anims.reload.TimePosition >= anims.reload.Length or (reloadFinishTime and anims.reload.TimePosition >= reloadFinishTime and data.magCurrent > 0) then
							isReloaded = true
							data.magCurrent = data.magSize
							data.ammo = math.max(data.ammo - 1, 0) -- reserve counts mags not rounds
							if AI then
								tool._data.magCurrent.Value = data.magCurrent
								tool._data.ammo.Value = data.ammo
							end
							if not AI then
								Network:FireServer("vars", "reload", {tool = tool, client = true})
							end
							anims.reload:Stop(0.25)

							break
						end

						if not AI then
							local progress = (anims.reload.TimePosition / maxTime) * 100
							if progress > 50 then
								UI.circularBar.right.image.UIGradient.Rotation = 180
								TweenService:Create(UI.circularBar.left.image.UIGradient, TweenInfo.new(1 / 15), {Rotation = (progress / 100) * 360}):Play()
							else
								UI.circularBar.left.image.UIGradient.Rotation = 180
								TweenService:Create(UI.circularBar.right.image.UIGradient, TweenInfo.new(1 / 15), {Rotation = (progress / 50) * 180}):Play()
							end
						end

						task.wait(1 / 15) -- 15hz is plenty for reload timing
					end

					if (tool:IsDescendantOf(character) or not character:FindFirstChildWhichIsA("Tool")) and not AI then
						UI.circularBar.Visible = false
					end

					if getTime then
						getTime:Disconnect()
					end

					-- some reloads have no markers like the deagle and glock so decide the empty pose from ammo
					if anims.noammo then
						if data.magCurrent > 0 then
							anims.noammo:Stop()
						elseif not isReloaded then
							anims.noammo:Play() -- reload got cancelled on an empty gun
						end
					end

					anims.reload:Stop()
				end
			end

			reloading = false
			setGlobal("reload", false)
		-- inspect, only when idle
		elseif key == Enum.KeyCode.H and not active and not fireProcess and tick() - rateTick >= settings.rate and humanoid.Health > 0 and not reloading and isEquipped() and anims.inspect and not anims.inspect.IsPlaying and (anims.inspect_empty and not anims.inspect_empty.IsPlaying or not anims.inspect_empty) then
			anims.fire.Priority = Enum.AnimationPriority.Core
			if data.magCurrent > 0 or not anims.inspect_empty then
				anims.inspect:Play()
			else
				-- empty inspect has its own anim, stop the empty pose while it plays and bring it back after
				anims.inspect_empty:Play()
				if anims.noammo then
					anims.noammo:Stop()

					local connection
					connection = anims.inspect_empty.Stopped:Connect(function(): ()
						anims.noammo:Play(0.0000001)
					end)
				end
			end
		-- switch fire mode, 0.5s debounce
		elseif key == Enum.KeyCode.B and not active and not fireProcess and tick() - rateTick >= settings.rate and humanoid.Health > 0 and not reloading and isEquipped() and settings.mode_switch and tick() - fireModeDelay >= 0.5 then
			fireModeDelay = tick()
			currentFireMode += 1
			if currentFireMode > #settings.mode_switch then
				currentFireMode = 1
			end
			fireMode = settings.mode_switch[currentFireMode]
			_G.changeFireMode()
			_G.createSound(player.PlayerGui.SOUNDS.fireSwitch, player.PlayerGui):Play()
		-- shove
		elseif key == Enum.KeyCode.T and not active and not fireProcess and humanoid.Health > 0 and not reloading and isEquipped() and anims.shove and tick() - rateTick >= settings.rate_shove then
			rateTick = tick() -- shares the shot cooldown
			setGlobal("fireActive", tick())
			anims.shove:Play()
		-- aim, the camera script reads the flag
		elseif key == Enum.UserInputType.MouseButton2 then
			if not reloading and humanoid.Health > 0 and isEquipped() then
				setGlobal("aim", true)
			end
		-- fire
		elseif key == Enum.UserInputType.MouseButton1 and not active and not fireProcess and tick() - rateTick >= settings.rate and humanoid.Health > 0 and isEquipped() and not _G.unableToShoot and not ReplicatedStorage.__tempSTORAGE["self-revive"]:FindFirstChild(AI and character.Name or player.Name) then
			-- clicking during inspect just cancels it
			if anims.inspect and anims.inspect.IsPlaying then
				anims.inspect:Stop()
				if settings.gunType == "diy_ft" then
					anims.light:Play() -- diy flamethrower relights its pilot flame
				end

				return
			end

			if anims.inspect_empty and anims.inspect_empty.IsPlaying then
				anims.inspect_empty:Stop()
				return
			end

			if not reloading then
				active = true
				local fanfire = false
				-- guns with a prefire like a hammer need the trigger held for prefireDelay first
				if settings.prefireDelay then
					anims.prefire:Play()
					local downed = tick()
					local prefired = false
					while active and tool:IsDescendantOf(character) do
						if tick() - downed >= settings.prefireDelay then
							prefired = true
							break
						end

						task.wait()
					end

					if not tool:IsDescendantOf(character) then
						anims.prefire:Stop()
						return
					elseif not prefired and anims.fanfire and (not getGlobal("aim") or not AI and not _G.isFPS()) then
						-- let go early while hip firing means fan fire, keeps shooting without the trigger held
						fanfire = true
						anims.prefire:Stop()
						anims.fanfire:Play()
					elseif not prefired then
						anims.prefire:Stop()
						return
					end
				end

				fireProcess = true -- blocks inspect, shove and mode switch till this is done
				-- needs ammo and no pump or reload anim playing
				if data.magCurrent > 0 and (settings.shotgun and not anims.afterload.IsPlaying or not settings.shotgun and (not anims.reload or not anims.reload.IsPlaying)) then
					local rate = 0
					local count = 0
					local wasFired = false
					local lastAmmoAmount = data.magCurrent
					local diyFTfire = false
					if settings.gunType == "diy_ft" then
						anims.after:Stop()
						anims.shake:Play() -- flamethrower sputters before it lights
					end
					-- main fire loop, runs every frame and the rate check decides when a shot goes out
					while tool:IsDescendantOf(character) and (active or fanfire) and not reloading and humanoid.Health > 0 and not humanoid:GetAttribute("Ragdoll") and not getGlobal("unableToShoot") and not ReplicatedStorage.__tempSTORAGE["self-revive"]:FindFirstChild(AI and character.Name or player.Name) do
						if data.magCurrent > 0 and settings.gunType == "diy_ft" and not anims.shake.IsPlaying and not diyFTfire then
							anims.fire_start:Play()
							diyFTfire = true
						end

						if tick() - rate >= settings.rate and (settings.gunType ~= "diy_ft" or diyFTfire) then
							rate = tick()
							-- server still thinks it's reloading, clear it so it accepts the shot
							if tool._data.reload.Value == true then
								reloading = false
								Network:FireServer("vars", "reload", {tool = tool, state = false})
							end

							-- fires one round, false means the gun is empty so stop the loop
							local function fire(): boolean
								if data.magCurrent > 0 then
									if tool._mod.Handle.MuzzleFX:FindFirstChild("SmokeHeat") then
										tool._mod.Handle.MuzzleFX.SmokeHeat.Enabled = false
									end
									wasFired = true
									rateTick = tick()
									data.magCurrent = math.max(data.magCurrent - 1, 0) -- predicted, server has the real count
									-- fan fire has its own body anim so recoil goes lower
									anims.fire.Priority = not fanfire and Enum.AnimationPriority.Action4 or Enum.AnimationPriority.Action
									if settings.gunType ~= "diy_ft" or not anims.fire.IsPlaying then
										anims.fire:Play() -- flamethrower fire is a loop, don't restart it
									end
									if not getGlobal("aim") and not AI then
										anims.fire:AdjustWeight(1)
									end
									setGlobal("fireActive", tick())
									if not AI then
										Storage.Events.client:Fire("cGunFire", tool, settings)

										-- quick depth of field punch on each shot
										local blur = Instance.new("DepthOfFieldEffect")
										blur.FarIntensity = 0
										blur.InFocusRadius = _G.isFPS() and _G.aim and 48.9 or 45
										blur.Parent = camera
										Debris:AddItem(blur, 0.15)
										TweenService:Create(blur, TweenInfo.new(0.5), {InFocusRadius = 50}):Play()

										local origin, dir = getHitPos(handle.MuzzleFX)
										Storage.Events.client:Fire("fire", tool.Name, origin, dir, character, handle)
										Network:FireServer("fire", tool, dir) -- server recasts and does the damage
									else
										-- npcs are already on the server so fire the pipeline straight away with AimDir
										Storage.Events.server:Fire("fire", character, tool, false, tool:GetAttribute("AimDir"))

										local params = RaycastParams.new()
										params.FilterDescendantsInstances = {workspace.Ignored, camera, character}
										params.FilterType = Enum.RaycastFilterType.Exclude
										params.IgnoreWater = true
										params.CollisionGroup = "Raycast"
										-- AimDir already has the range in its length
										local cast = workspace:Raycast(character.Head.Position, tool:GetAttribute("AimDir"), params)
										if cast then
											local target = isHumanoid(cast.Instance)
											if target then
												-- same arg layout as the player path
												Storage.Events.server:Fire("damage", character, target, tool, cast.Instance, tool:GetAttribute("AimDir"), {
													Instance = cast.Instance,
													Position = cast.Position,
													Normal = cast.Normal
												}, tool:GetAttribute("AimDir"), tool:GetAttribute("AimDir"))
											end
										end
									end
									count += 1

									if anims.noammo and data.magCurrent <= 0 then
										-- last round, go to the empty pose
										anims.fire.Priority = Enum.AnimationPriority.Action2
										anims.noammo:Play()
										return false
									end
								else
									-- dry fire, show the reload hint
									if not AI then
										if (not keyHints.reload or not keyHints.reload:IsDescendantOf(game)) and data.ammo > 0 and not settings.noReloadHint then
											local frame = _G.setKeyHint("R", "Reload", 5)
											keyHints.reload = frame
										end
									end
									if anims.noammo then
										anims.noammo:Play()
									end
									if handle.MuzzleFX:FindFirstChild("Empty") then
										handle.MuzzleFX.Empty:Play()
									end

									return false
								end

								return true
							end

							if fireMode == 2 then
								-- burst, a bit faster than the normal rate, one burst per click
								for k = 1, settings.burstAmount do
									local fired = fire()
									if not fired then
										break
									end

									task.wait(settings.rate * 0.9)
								end

								task.wait(settings.rate * 0.8)
								break
							else
								local fired = fire()
								if not fired then
									break
								end
							end

							if fireMode == 1 then
								break -- single fires once, auto keeps looping
							end
						end

						task.wait()
					end
					-- barrel smoke after shooting, longer the more you fired, max 5s
					if wasFired and tool._mod.Handle.MuzzleFX:FindFirstChild("SmokeHeat") then
						tool._mod.Handle.MuzzleFX.SmokeHeat.Enabled = true
						local t = tick()
						task.spawn(function(): ()
							while tool:IsDescendantOf(character) and tool._mod.Handle.MuzzleFX.SmokeHeat.Enabled do
								if tick() - t >= math.min((lastAmmoAmount - data.magCurrent) / 1.5, 5) then
									tool._mod.Handle.MuzzleFX.SmokeHeat.Enabled = false
									break
								end
								task.wait()
							end
						end)
					end
					if settings.gunType == "diy_ft" then
						-- flamethrower released, stop the flame
						anims.shake:Stop()
						anims.fire_start:Stop()
						anims.fire:Stop()
						anims.cancel:Play()
						anims.after:Play()
					end
				else
					-- empty mag or mid pump, show the hint and out of ammo msg
					if not AI then
						if (not keyHints.reload or not keyHints.reload:IsDescendantOf(game)) and data.ammo > 0 and not settings.noReloadHint then
							local frame = _G.setKeyHint("R", "Reload", 5)
							keyHints.reload = frame
						end

						_G.messageLog({
							Text = "OUT OF AMMO [" .. tool.Name .. "]",
							TextColor3 = Color3.fromRGB(255, 94, 97),
						}, false, 2)
					end

					anims.fire.Priority = Enum.AnimationPriority.Core
					if anims.noammo then
						anims.noammo:Play()
					end
					handle.MuzzleFX.Empty:Play()
					if anims.fire.WeightCurrent < 0.1 then
						anims.fire:Play()
					end
					if not AI then
						anims.fire:AdjustWeight(0.01) -- tiny twitch instead of full recoil
					end
					if settings.prefireDelay then
						anims.prefire:Stop()
					end
				end

				fireProcess = false
			else
				-- clicking while reloading cancels the reload so you can shoot what's left
				if not AI then
					TweenService:Create(gunInfo.reloadProgress, TweenInfo.new(0.5, Enum.EasingStyle.Sine), {BackgroundColor3 = Color3.fromRGB(255, 0, 0), Transparency = 1, Size = gunInfo.reloadProgress.Size}):Play()
				end
				if not settings.shotgun then
					anims.reload:Stop(0.25)
				else
					anims.load:Stop(0.25) -- shell loop sees it stopped and doesn't credit the shell
				end
				reloading = false
				setGlobal("reload", false)
				if not AI then
					Network:FireServer("vars", "reload", {tool = tool, state = false})
				end
			end
		end
	end

	-- releases
	local function gunFunctionEnded(key: InputKey): ()
		if key == Enum.UserInputType.MouseButton1 then
			active = false
		elseif key == Enum.UserInputType.MouseButton2 and data.magCurrent > 0 then
			-- letting go of aim cancels inspect and puts recoil weight back
			if anims.inspect then
				anims.inspect:Stop()
				if settings.gunType == "diy_ft" then
					anims.light:Play()
				end
			end

			if anims.inspect_empty then
				anims.inspect_empty:Stop()
			end
			anims.fire:AdjustWeight(1)
		end
	end
	-- equip
	local aimCrosshair = _G.aim -- last aim state sent to the crosshair
	local connections = {} -- all of these get disconnected on unequip

	local function onEquipped(): ()
		if not AI then
			UI.circularBar.Visible = false
		end
		setGlobal("gunEquipped", true)
		equipTick = tick()

		if not AI then
			for key, data in pairs(hints) do
				local frame = _G.setKeyHint(key, data.info, 5)
				keyHints[#keyHints + 1] = frame
			end
			TweenService:Create(gunInfo.reloadProgress, TweenInfo.new(16e-5, Enum.EasingStyle.Sine), {Size = UDim2.new(0, 0, 1, 0), Transparency = 0.5, BackgroundColor3 = Color3.fromRGB(255, 255, 255)}):Play()
		end

		-- idle is optional, guns without one keep the default tool hold cause their grip doesn't match the shared poses
		if anims.idle then
			anims.idle.Priority = Enum.AnimationPriority.Action
		end
		anims.equip.Priority = Enum.AnimationPriority.Action2
		anims.fire.Priority = Enum.AnimationPriority.Movement
		-- run pose plays in first and third person while sprinting, unlike holster
		if anims.run then
			anims.run.Priority = Enum.AnimationPriority.Action2
		end
		if anims.inspect then
			anims.inspect.Priority = Enum.AnimationPriority.Action3
		end
		if anims.equip_empty then
			anims.equip_empty.Priority = Enum.AnimationPriority.Action2
		end

		if anims.inspect_empty then
			anims.inspect_empty.Priority = Enum.AnimationPriority.Action3
		end

		-- empty equip if the mag is empty
		if data.magCurrent > 0 or not anims.equip_empty then
			anims.equip:Play()
		else
			anims.equip_empty:Play()
		end
		if anims.idle then
			anims.idle:Play()
		end
		if anims.noammo and data.magCurrent <= 0 then
			anims.noammo:Play()
		end

		if not AI then
			-- process is true when ui ate the input like chat
			table.insert(connections, UserInputService.InputBegan:Connect(function(inputObject: InputObject, process: boolean): ()
				if not process then
					gunFunctionBegan(inputObject.UserInputType == Enum.UserInputType.Keyboard and inputObject.KeyCode or inputObject.UserInputType)
				end
			end))

			-- releases always go through so the trigger can't get stuck
			table.insert(connections, UserInputService.InputEnded:Connect(function(inputObject: InputObject): ()
				gunFunctionEnded(inputObject.UserInputType == Enum.UserInputType.Keyboard and inputObject.KeyCode or inputObject.UserInputType)
			end))
		else
			-- npc input
			activateEvent.Event:Connect(function(key: InputKey, mode: string): ()
				if mode == "began" then
					gunFunctionBegan(key)
				elseif mode == "ended" then
					gunFunctionEnded(key)
				end
			end)
		end

		-- mobile buttons, pcall so a broken mobile ui can't break the gun
		if UserInputService.TouchEnabled and not AI then
			local _mobileOk, _mobileErr = pcall(function(): ()
				local MobileWeaponUI = require(Storage.Modules:WaitForChild("MobileWeaponUI"))

				-- each gun ships its own MobileUI, clone it in on equip
				local mobileGui = tool:WaitForChild("MobileUI"):Clone()
				mobileGui.Name = "MobileUI"
				mobileGui.Enabled = true
				mobileGui.ResetOnSpawn = false
				mobileGui.DisplayOrder = 6
				mobileGui.Parent = player.PlayerGui

				local mc = MobileWeaponUI.new(mobileGui, connections) -- shares connections so unequip cleans it up too

				local fireFrame = mobileGui:FindFirstChild("fire")
				local reloadFrame = mobileGui:FindFirstChild("reload")
				local scopeFrame = mobileGui:FindFirstChild("scopeToggle")
				local fireModeFrame = mobileGui:FindFirstChild("fireModeToggle")
				local inspectFrame = mobileGui:FindFirstChild("inspect")

				-- hold to fire, the fire loop already handles the fire mode
				mc:button("fire", {
					frame = fireFrame, label = "FIRE", mode = "hold",
					begin = function(): () gunFunctionBegan(Enum.UserInputType.MouseButton1) end,
					ended = function(): () gunFunctionEnded(Enum.UserInputType.MouseButton1) end,
				})

				-- aim is a toggle on mobile, clear _G.aim on toggle off since touch never sends a mb2 release
				local aimOn = false
				mc:button("aim", {
					frame = scopeFrame, label = settings.sniper and "SCOPE" or "AIM", mode = "tap",
					tap = function(): ()
						aimOn = not aimOn
						if aimOn then
							gunFunctionBegan(Enum.UserInputType.MouseButton2)
						else
							gunFunctionEnded(Enum.UserInputType.MouseButton2)
							_G.aim = false
							_G.aimTick = tick()
						end
					end,
				})

				mc:button("reload", {
					frame = reloadFrame, label = "RELOAD", mode = "tap",
					show = not settings.noReload,
					tap = function(): () gunFunctionBegan(Enum.KeyCode.R) end,
				})

				mc:button("firemode", {
					frame = fireModeFrame, label = "MODE", mode = "tap",
					show = settings.mode_switch ~= nil,
					tap = function(): () gunFunctionBegan(Enum.KeyCode.B) end,
				})

				mc:button("inspect", {
					frame = inspectFrame, label = "INSPECT", mode = "tap",
					show = anims.inspect ~= nil,
					tap = function(): () gunFunctionBegan(Enum.KeyCode.H) end,
				})

				-- MobileUI has no shove button so clone the fire one
				if anims.shove and fireFrame then
					local shoveFrame = fireFrame:Clone()
					shoveFrame.Name = "shove"
					shoveFrame.Parent = mobileGui
					mc:button("shove", {
						frame = shoveFrame, label = "SHOVE", mode = "tap",
						tap = function(): () gunFunctionBegan(Enum.KeyCode.T) end,
					})
				end

				-- keep reload and aim buttons in sync, about 12hz
				local syncTick = 0
				table.insert(connections, RunService.Heartbeat:Connect(function(): ()
					if tick() - syncTick < 0.08 then return end
					syncTick = tick()
					mc:setEnabled("reload", (not settings.noReload) and data.ammo > 0 and data.magCurrent < data.magSize)
					mc:setActive("reload", reloading)
					if not _G.aim then aimOn = false end -- something else dropped aim, keep the toggle in sync
					mc:setActive("aim", _G.aim == true)
				end))

				local destroyConn
				-- teardown on unequip no matter the connection order
				destroyConn = tool.Unequipped:Connect(function(): ()
					if destroyConn then destroyConn:Disconnect() destroyConn = nil end
					mc:destroy()
				end)
			end)
			if not _mobileOk then warn("[MobileWeaponUI] guns:", _mobileErr) end
		end

		-- per frame poses and hud
		-- this rateTick shadows the shot cooldown on purpose, only npcs throttle to 10hz
		local rateTick = 0
		local stepped = AI and RunService.Heartbeat or RunService.RenderStepped -- RenderStepped is client only
		table.insert(connections, stepped:Connect(function(): ()
			if not tool:IsDescendantOf(character) or not humanoid.RootPart then
				return
			end

			if tick() - rateTick >= 1 / 10 then
				if AI then
					rateTick = tick()
				end

				-- run pose only while sprinting and doing nothing else with the gun
				local wantRun = anims.run
					and getGlobal("run")
					and not getGlobal("aim")
					and not getGlobal("reload")
					and not getGlobal("inspect")
					and not getGlobal("isProne")
					and not getGlobal("isCrouch")
					and not anims.fire.IsPlaying
					and not anims.equip.IsPlaying
					and (not anims.equip_empty or not anims.equip_empty.IsPlaying)
					and true or false -- turn it into a real boolean

				if anims.run then
					anims.run.Priority = Enum.AnimationPriority.Action2
					if wantRun then
						if not anims.run.IsPlaying then
							anims.run:Play(0.2)
						end
					elseif anims.run.IsPlaying then
						anims.run:Stop(0.25)
					end
				end

				-- holster pose
				if anims.holster and wantRun then
					-- run pose owns the body while sprinting
					if anims.holster.IsPlaying then
						anims.holster:Stop(0.2)
					end
					if anims.holsterIdle and anims.holsterIdle.IsPlaying then
						anims.holsterIdle:Stop(0.2)
					end
				elseif anims.holster then
					-- third person, not aiming, no shot for 0.5s, lower the gun
					if not getGlobal("aim") and tick() - getGlobal("fireActive") >= 0.5 and (AI or not _G.isFPS()) and not anims.equip.IsPlaying and not anims.fire.IsPlaying and not getGlobal("isProne") and not getGlobal("isCrouch") then
						if anims.holsterIdle then
							anims.holsterIdle.Priority = Enum.AnimationPriority.Action2
							if not anims.holsterIdle.IsPlaying then
								anims.holsterIdle:Play(0.2)
							end
						end

						anims.holster.Priority = Enum.AnimationPriority.Action
						if not anims.holster.IsPlaying then
							anims.holster:Play(0.1)
							anims.holster:AdjustSpeed(0) -- frozen, humanoid.Running speeds it up when sprinting
						end
					-- first person or npc sprinting with no run pose, holster is the run cycle
					elseif (AI or _G.isFPS()) and getGlobal("run") and not anims.fire.IsPlaying and not anims.equip.IsPlaying and not getGlobal("isProne") and not getGlobal("isCrouch") then
						if anims.holsterIdle then
							anims.holsterIdle:Stop()
						end
						anims.holster.Priority = Enum.AnimationPriority.Action
						if not anims.holster.IsPlaying then
							anims.fire.Priority = Enum.AnimationPriority.Core
							anims.holster:Play(0.15)
						end
					else
						-- aiming in first person, snap out of holster instantly so the sights line up
						if getGlobal("aim") and (AI or _G.isFPS()) then
							if not anims.holster.IsPlaying then
								anims.holster:Play()
							end
							anims.holster:Stop(0.000000001)
						else
							anims.holster:Stop(0.25)
						end

						if anims.holsterIdle then
							anims.holsterIdle:Stop(0.2)
						end
					end
				end

				if not AI then
					setGlobal("gunEquip", anims.equip.IsPlaying)
				end

				-- kill idle instantly in first person ads so it doesn't offset the sights
				if anims.idle and getGlobal("aim") and (AI or _G.isFPS()) and anims.idle.IsPlaying then
					anims.idle:Stop(0.000000001)
				end

				-- inspecting kicks you out of aim
				if anims.inspect then
					if anims.inspect.IsPlaying then
						setGlobal("aim", false)
					end
				end

				if anims.inspect_empty then
					if anims.inspect_empty.IsPlaying then
						setGlobal("aim", false)
					end
				end

				if not AI then
					setGlobal("inspect", anims.inspect and anims.inspect.IsPlaying or anims.inspect_empty and anims.inspect_empty.IsPlaying)
				end

				-- idle plays when holster or run aren't playing
				if anims.idle then
					if (anims.holster and anims.holster.IsPlaying) or (anims.run and anims.run.IsPlaying) then
						anims.idle:Stop(0.25)
					elseif not anims.idle.IsPlaying then
						anims.idle:Play(getGlobal("aim") and (AI or _G.isFPS()) and 0.000000001 or nil)
					end
				end

				-- holsterIdle is a static pose, removed while running or reloading
				if anims.holsterIdle and not getGlobal("run") and not getGlobal("reload") then
					anims.holsterIdle:AdjustSpeed(0)
				elseif getGlobal("run") or getGlobal("reload") then
					if anims.holsterIdle then
						anims.holsterIdle:Stop(0.25)
					end
				end

				-- player hud
				if not AI and handle:FindFirstChild("MuzzleFX") then
					-- can't shoot marker where a wall blocks the shot
					local blocked, blockedPos = sightBlocked(handle.MuzzleFX)
					if blocked and humanoid.Health > 0 and not humanoid:GetAttribute("Downed") then
						UI.cantShoot.Visible = true
						local pos, _ = camera:WorldToScreenPoint(blockedPos)
						UI.cantShoot.Position = UDim2.new(0, pos.x, 0, pos.y + 36) -- 36px so it sits just under the point
					else
						UI.cantShoot.Visible = false
					end

					-- first person hides the crosshair while aiming, third person shrinks it to half
					if _G.isFPS() then
						Storage.Events.client:Fire("crosshair", not _G.aim, settings.crosshairRadius)
					else
						Storage.Events.client:Fire("crosshair", true, settings.crosshairRadius * (_G.aim and 0.5 or 1))
						if aimCrosshair and not _G.aim then
							aimCrosshair = false
							Storage.Events.client:Fire("setCrosshair", settings.crosshairRadius, true, nil, nil, 0.25)
						elseif not aimCrosshair and _G.aim then
							aimCrosshair = true
							Storage.Events.client:Fire("setCrosshair", settings.crosshairRadius * 0.5, true, nil, nil, 0.25)
						end
					end

					-- ammo panel
					gunInfo.gunName.Text = tostring(tool.Name) .. " []"
					if isEquipped() and data then
						gunInfo.currentAmmo.Text = data.magCurrent
						gunInfo.magSize.Text = data.ammo
						gunInfo.fireMode.Text = (fireMode == 1 and "[SINGLE]") or (fireMode == 2 and "[BURST]") or (fireMode == 3 and "[AUTO]")
						gunInfo.currentAmmo.TextColor3 = Color3.fromRGB(170, 0, 0):Lerp(Color3.fromRGB(255, 255, 255), (data.magCurrent / data.magSize) * 1) -- goes red as the mag empties
						gunInfo.magSize.TextColor3 = data.ammo > 0 and Color3.fromRGB(229, 229, 229) or Color3.fromRGB(79, 0, 0)
					else
						gunInfo.currentAmmo.Text = "-"
						gunInfo.magSize.Text = "-"
					end

					-- only zoom once the sight is actually at the camera so it doesn't zoom early
					if tool._mod.Handle:FindFirstChild("aimPos") then
						local dist = getDistance(tool._mod.Handle.aimPos.WorldPosition, camera.CFrame.Position)
						if _G.aim and _G.isFPS() then
							if dist < 0.35 then
								if not isActuallyAiming and settings.sniper and not AI then
									_G.createSound(player.PlayerGui.SOUNDS.zoom, player.PlayerGui):Play() -- scope in sound once per ads
								end
								isActuallyAiming = true
							end
							if isActuallyAiming then
								if data.magCurrent > 0 then
									anims.fire:AdjustWeight(settings.aimWeight)
								end
								TweenService:Create(camera, settings.ads_config.tweenInfoIn, {FieldOfView = settings.ads_config.fovIn}):Play()
							end
						elseif not _G.aim or not _G.isFPS() then
							isActuallyAiming = false
							TweenService:Create(camera, settings.ads_config.tweenInfoOut, {FieldOfView = settings.ads_config.fovOut}):Play()
							_G.aimTickTimer = settings.ads_config.aimOutTime and settings.ads_config.aimOutTime + 0.1 or 0.35 -- how long the camera waits before leaving ads
						end
					end
				end
			end
		end))
	end
	if tool:IsDescendantOf(character) then
		onEquipped() -- gun can already be in hand when this runs
	end

	-- unequip and cleanup
	tool.Equipped:Connect(onEquipped)
	tool.Unequipped:Connect(function(): ()
		if not AI then
			UI.cantShoot.Visible = false
		end
		active = false
		reloading = false

		_G.gunEquipped = false
		_G.inspect = false

		for i, v in pairs(connections) do
			v:Disconnect()
			connections[i] = nil
		end

		if not AI then
			for index, frame in pairs(keyHints) do
				if frame:IsDescendantOf(game) then
					_G.clearKeyHint(frame)
				end

				keyHints[index] = nil
			end
			keyHints = {}

			TweenService:Create(camera, TweenInfo.new(16e-5, Enum.EasingStyle.Sine), {FieldOfView = 70}):Play() -- snap fov back
		end

		-- zero the weight first so nothing lingers while fading out
		for _, v in pairs(anims) do
			v:AdjustWeight(0)
			v:Stop()
		end
	end)

	-- tool got destroyed, stop every track so nothing keeps playing
	local connection
	connection = tool.AncestryChanged:Connect(function(_: Instance, parent: Instance?): ()
		if parent == nil then
			connection:Disconnect()

			for index, v in pairs(anims) do
				if typeof(anims[index]) == "table" then
					-- in case a name holds a group of tracks
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
	end)
end
