--[[
    Battle Engine State Manager
    Written by andarm to handle states with stacking instead of simple set/unset methods
    Optimized for combat, with priorities included
]]

local be = {}

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")

--// Remotes
local engineRemote = ReplicatedStorage:WaitForChild("RemoteEvent")
local unreliableRemote = ReplicatedStorage:WaitForChild("UnreliableRemoteEvent")

--// External Modules
local ragdollLib = require(script.Parent:WaitForChild("Ragdoll"))

---------------------------------------------------------------------
-- INTERNAL STATE TABLES
---------------------------------------------------------------------

local State = {
	Speeds = {},
	Jumps = {},
	Stuns = {},
	UsingMoves = {},
	Attacks = {},
	Rotations = {},
	Ragdolls = {},
	Damage = {}
}

---------------------------------------------------------------------
-- UTILITY
---------------------------------------------------------------------

local function getPlayer(char)
	return Players:GetPlayerFromCharacter(char)
end

local function resolvePriorityLowest(tbl, keyName)
	local highestPriority = -math.huge
	local t = {}

	for _, data in pairs(tbl) do
		if data.Priority > highestPriority then
			highestPriority = data.Priority
			t = { data }
		elseif data.Priority == highestPriority then
			table.insert(t, data)
		end
	end

	local lowest
	for _, data in ipairs(t) do
		if not lowest or data[keyName] < lowest[keyName] then
			lowest = data
		end
	end

	return lowest and lowest[keyName]
end

local function ensureState(id)
	State.Speeds[id] = State.Speeds[id] or {}
	State.Jumps[id] = State.Jumps[id] or {}
	State.Stuns[id] = State.Stuns[id] or {}
	State.UsingMoves[id] = State.UsingMoves[id] or {}
	State.Attacks[id] = State.Attacks[id] or {}
	State.Rotations[id] = State.Rotations[id] or {}
	State.Ragdolls[id] = State.Ragdolls[id] or {}
	State.Damage[id] = State.Damage[id] or {}
end

---------------------------------------------------------------------
-- SETUP / CLEAN
---------------------------------------------------------------------

function be:Setup(id)
	ensureState(id)
end

function be:Clean(id, char)
	for _, group in pairs(State) do
		group[id] = nil
	end

	if char then
		for _, tag in ipairs(CollectionService:GetTags(char)) do
			CollectionService:RemoveTag(char, tag)
		end
	end
end

---------------------------------------------------------------------
-- DAMAGE TRACKING
---------------------------------------------------------------------

function be:AddDamage(data)
	local char = data.char
	local enemy = data.enemy
	local dmg = data.damage
	local id = char.UserId.Value

	ensureState(id)

	if not enemy then return end

	local enemyId = enemy:IsA("Player") and enemy.UserId or enemy.UserId.Value
	if not enemyId then return end

	local existing = State.Damage[id][enemyId]
	if existing then
		existing.damage += dmg
	else
		State.Damage[id][enemyId] = { id = enemyId, damage = dmg }
	end
end

function be:GetKillerId(data)
	local char = data.char
	local id = char.UserId.Value
	local dmgTable = State.Damage[id]
	if not dmgTable then return id end

	local max = 0
	local killer = id

	for _, info in pairs(dmgTable) do
		if info.damage > max then
			max = info.damage
			killer = info.id
		end
	end

	return killer
end
---------------------------------------------------------------------
-- STATE CHECKING
---------------------------------------------------------------------

function be:CheckState(stateName, id)
	local group = State[stateName]
	if not group then return false end

	local stateTable = group[id]
	if not stateTable then return false end

	return next(stateTable) ~= nil
end

---------------------------------------------------------------------
-- SPEED
---------------------------------------------------------------------

function be:AddSpeed(data)
	local char = data.char
	local hum = char.Humanoid
	local id = char.UserId.Value
	ensureState(id)

	State.Speeds[id][data.Name] = {
		Speed = data.WalkSpeed,
		Priority = data.Priority or 0
	}

	local final = resolvePriorityLowest(State.Speeds[id], "Speed") or data.WalkSpeed
	local player = getPlayer(char)
	
	
	if player then
		engineRemote:FireClient(player, 1, final)
	else
		hum.WalkSpeed = final
	end

	if data.Dura and data.Dura ~= math.huge then
		task.delay(data.Dura, function()
			be:RemoveSpeed(data)
		end)
	end
end

function be:RemoveSpeed(data)
	local char = data.char
	local hum = char.Humanoid
	local id = char.UserId.Value

	if not State.Speeds[id] then return end
	State.Speeds[id][data.Name] = nil

	local final = resolvePriorityLowest(State.Speeds[id], "Speed") or hum.WalkSpeed
	local player = getPlayer(char)

	if player then
		engineRemote:FireClient(player, 1, final)
	else
		hum.WalkSpeed = final
	end
end

---------------------------------------------------------------------
-- JUMP
---------------------------------------------------------------------

function be:AddJump(data)
	local char = data.char
	local hum = char.Humanoid
	local id = char.UserId.Value
	ensureState(id)

	State.Jumps[id][data.Name] = {
		JumpPower = data.JumpPower,
		Priority = data.Priority or 0
	}

	local final = resolvePriorityLowest(State.Jumps[id], "JumpPower") or data.JumpPower
	local player = getPlayer(char)

	if player then
		engineRemote:FireClient(player, 2, final)
	else
		hum.JumpPower = final
	end

	if data.Dura and data.Dura ~= math.huge then
		task.delay(data.Dura, function()
			be:RemoveJump(data)
		end)
	end
end

function be:RemoveJump(data)
	local char = data.char
	local hum = char.Humanoid
	local id = char.UserId.Value

	if not State.Jumps[id] then return end
	State.Jumps[id][data.Name] = nil

	local final = resolvePriorityLowest(State.Jumps[id], "JumpPower") or hum.JumpPower
	local player = getPlayer(char)

	if player then
		engineRemote:FireClient(player, 2, final)
	else
		hum.JumpPower = final
	end
end

---------------------------------------------------------------------
-- STUN
---------------------------------------------------------------------
function be:AddStun(data)
	local char = data.char
	local id = char.UserId.Value
	ensureState(id)

	State.Stuns[id][data.Name] = true

	local effectMap = {
		WalkSpeed = self.AddSpeed,
		JumpPower = self.AddJump,
		Ragdoll = self.AddRagdoll,
		AutoRotate = self.AddAutoRotate,
	}

	for key, func in pairs(effectMap) do
		if data[key] then
			func(self, {
				char = char,
				Name = data.Name .. "_Stun",
				[key] = data[key],
				Priority = 10,
				Dura = data.Dura
			})
		end
	end


	if data.Dura and data.Dura ~= math.huge then
		task.delay(data.Dura, function()
			State.Stuns[id][data.Name] = nil
		end)
	end
end

function be:RemoveStun(data)
	local char = data.char
	local id = char.UserId.Value

	if not State.Stuns[id] then return end

	local revertTables = {
		{table = State.Speeds, func = be.RemoveSpeed},
		{table = State.Jumps, func = be.RemoveJump},
		{table = State.Ragdolls, func = be.RemoveRagdoll},
		{table = State.Rotations, func = be.RemoveAutoRotate},
	}

	for _, info in ipairs(revertTables) do
		local tbl = info.table
		local remover = info.func
		if tbl[id] and tbl[id][data.Name.."Stun"] then
			remover({char = char, Name = data.Name.."Stun"})
		end
	end

	State.Stuns[id][data.Name] = nil

	if next(State.Stuns[id]) == nil then
		State.Stuns[id] = nil
	end
end


---------------------------------------------------------------------
-- RAGDOLL
---------------------------------------------------------------------

function be:AddRagdoll(data)
	local char = data.char
	local id = char.UserId.Value
	ensureState(id)

	if State.Ragdolls[id][data.Name] then return end

	State.Ragdolls[id][data.Name] = true
	
	--Custom ragdoll library
	ragdollLib:ragdollModel(char, math.huge, true, data.Dura)

	if data.Dura and data.Dura ~= math.huge then
		task.delay(data.Dura, function()
			be:RemoveRagdoll(data)
		end)
	end
end

function be:RemoveRagdoll(data)
	local char = data.char
	local id = char.UserId.Value

	if not State.Ragdolls[id] then return end
	State.Ragdolls[id][data.Name] = nil

	if next(State.Ragdolls[id]) == nil then
		ragdollLib:reverseRagdoll(char)
	end
end

---------------------------------------------------------------------
-- USING MOVE
---------------------------------------------------------------------

function be:AddUsingMove(data)
	local id = data.char.UserId.Value
	ensureState(id)

	State.UsingMoves[id][data.Name] = true

	if data.Dura and data.Dura ~= math.huge then
		task.delay(data.Dura, function()
			State.UsingMoves[id][data.Name] = nil
		end)
	end
end

function be:IsUsingMove(id)
	return State.UsingMoves[id] and next(State.UsingMoves[id]) ~= nil
end

---------------------------------------------------------------------
-- BLOCKING
---------------------------------------------------------------------

function be:StartBlocking(data)
	local char = data.char

	self:AddSpeed({
		char = char,
		Name = "Block",
		WalkSpeed = 6,
		Priority = 9,
		Dura = math.huge
	})

	local block = Instance.new("NumberValue")
	block.Name = "Block"
	block.Value = 50
	block.Parent = char
end

function be:StopBlocking(data)
	local char = data.char
	self:RemoveSpeed({char = char, Name = "Block"})

	if char:FindFirstChild("Block") then
		char.Block:Destroy()
	end
end

---------------------------------------------------------------------
-- RETURN
---------------------------------------------------------------------

return be
