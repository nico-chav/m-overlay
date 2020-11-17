local bit = require("bit")
local ffi = require("ffi")
local log = require("log")
local process = require("memory." .. jit.os:lower())
local clones = require("games.clones")
local notification = require("notification")
local filesystem = love.filesystem

require("extensions.string")

local NULL = 0x00000000

local GAME_ID_ADDR  = 0x80000000
local GAME_VER_ADDR = 0x80000007
local GAME_ID_LEN   = 0x06
local GAME_NONE     = "\0\0\0\0\0\0"

local VC_ID_ADDR    = 0x80003180
local VC_ID_LEN     = 0x04
local VC_NONE       = "\0\0\0\0"

local memory = {
	gameid = GAME_NONE,
	vcid = VC_NONE,
	process = process,
	permissions = process:hasPermissions(),

	hooked = false,
	initialized = false,

	map = {},
	values = {},

	hooks = {},
	wildcard_hooks = {},

	hook_queue = {},
}

setmetatable(memory, {__index = memory.values})

local bswap = bit.bswap
local function bswap16(n)
	return bit.bor(bit.rshift(n, 8), bit.lshift(bit.band(n, 0xFF), 8))
end

function memory.readGameID()
	return memory.read(GAME_ID_ADDR, GAME_ID_LEN)
end

function memory.readGameVersion()
	return memory.readUByte(GAME_VER_ADDR)
end

function memory.read(addr, len)
	local output = ffi.new("char[?]", len)
	local size = ffi.sizeof(output)
	process:read(addr, output, size)
	return ffi.string(output, size)
end

function memory.readByte(addr)
	if not process:hasProcess() then return 0 end
	local output = ffi.new("int8_t[1]")
	process:read(addr, output, ffi.sizeof(output))
	return output[0]
end

function memory.writeByte(addr, value)
	if not process:hasProcess() then return end
	local input = ffi.new("int8_t[1]", value)
	return process:write(addr, input, ffi.sizeof(input))
end

function memory.readBool(addr)
	if not process:hasProcess() then return false end
	return memory.readByte(addr) == 1
end

function memory.writeBool(addr, value)
	if not self:hasProcess() then return end
	self:writeByte(addr, value == true and 1 or 0)
end

function memory.readUByte(addr)
	if not process:hasProcess() then return 0 end
	local output = ffi.new("uint8_t[1]")
	process:read(addr, output, ffi.sizeof(output))
	return output[0]
end

function memory.writeUByte(addr, value)
	if not process:hasProcess() then return end
	local input = ffi.new("uint8_t[1]", value)
	return process:write(addr, input, ffi.sizeof(input))
end

function memory.readShort(addr)
	if not process:hasProcess() then return 0 end
	local output = ffi.new("int16_t[1]")
	process:read(addr, output, ffi.sizeof(output))
	return bswap16(output[0])
end

function memory.writeShort(addr, value)
	if not process:hasProcess() then return end
	local input = ffi.new("int16_t[1]", value)
	return process:write(addr, input, ffi.sizeof(input))
end

function memory.readUShort(addr)
	if not process:hasProcess() then return 0 end
	local output = ffi.new("uint16_t[1]")
	process:read(addr, output, ffi.sizeof(output))
	return bswap16(output[0])
end

function memory.writeUShort(addr, value)
	if not process:hasProcess() then return end
	local input = ffi.new("uint16_t[1]", value)
	return process:write(addr, input, ffi.sizeof(input))
end

do
	local floatconversion = ffi.new("union { uint32_t i; float f; }")

	function memory.readFloat(addr)
		if not process:hasProcess() then return 0 end
		local output = ffi.new("uint32_t[1]")
		process:read(addr, output, ffi.sizeof(output))
		floatconversion.i = bswap(output[0])
		return floatconversion.f, floatconversion.i
	end
end

function memory.writeFloat(addr, value)
	if not process:hasProcess() then return end
	local input = ffi.new("float[1]", value)
	return process:write(addr, input, ffi.sizeof(input))
end

function memory.readInt(addr)
	if not process:hasProcess() then return 0 end
	local output = ffi.new("int32_t[1]")
	process:read(addr, output, ffi.sizeof(output))
	return bswap(output[0])
end

function memory.writeInt(addr, value)
	if not process:hasProcess() then return end
	local input = ffi.new("int32_t[1]", value)
	return process:write(addr, input, ffi.sizeof(input))
end

function memory.readUInt(addr)
	if not process:hasProcess() then return 0 end
	local output = ffi.new("uint32_t[1]")
	process:read(addr, output, ffi.sizeof(output))
	return bswap(output[0])
end

function memory.writeUInt(addr, value)
	if not process:hasProcess() then return end
	local input = ffi.new("uint32_t[1]", value)
	return process:write(addr, input, ffi.sizeof(input))
end

local TYPES_READ = {
	["bool"] = memory.readBool,

	["sbyte"] = memory.readByte,
	["byte"] = memory.readUByte,
	["short"] = memory.readShort,

	["u8"] = memory.readUByte,
	["s8"] = memory.readByte,
	["u16"] = memory.readUShort,
	["s16"] = memory.readShort,
	["u32"] = memory.readUInt,
	["s32"] = memory.readInt,

	["float"] = memory.readFloat,

	["data"] = memory.read,
}

-- Creates or updates a tree of values for easy indexing
-- Example a path of "player.name" will become memory.players = { name = value }
function memory.cacheValue(table, path, value)
	local last = table
	local last_key = nil

	local keys = {}
	for key in string.gmatch(path, "[^%.]+") do
		keys[#keys + 1] = tonumber(key) or key
	end

	for i, key in ipairs(keys) do
		if i < #keys then
			last[key] = last[key] or {}
			last = last[key]
		else
			if type(last) ~= "table" then
				return error(("Failed to index a %s value (%q)"):format(type(last), keys[i-1]))
			end
			last[key] = value
			last_key = key
		end
	end

	-- Return the table that the value is being stored in, and the key name
	return last, last_key
end

local ADDRESS = {}
ADDRESS.__index = ADDRESS

function memory.newvalue(addr, offset, struct)
	assert(type(addr) == "number", "argument #1 'address' must be a number")
	assert(TYPES_READ[struct.type] ~= nil, "unhandled type: " .. struct.type)

	-- create/get a new value cache based off of the value name
	local tbl, key = memory.cacheValue(memory.values, struct.name, struct.init or NULL)

	return setmetatable({
		name = struct.name,

		address = addr, -- Where in memory this value is located
		offset = offset, -- How far past the address value we should get the value from

		read = TYPES_READ[struct.type],

		cache = tbl,
		cache_key = key,

		debug = struct.debug,
	}, ADDRESS)
end

function ADDRESS:update()
	if self.address == NULL then return end

	-- value = byteswapped value
	-- orig = Non-byteswapped value (Only available for floats)
	local value, orig = self.read(self.address + self.offset)

	-- Check if there has been a value change
	if self.cache[self.cache_key] ~= value then
		self.cache[self.cache_key] = value

		if self.debug then
			local numValue = tonumber(orig) or tonumber(value) or (value and 1 or 0)
			log.debug("[MEMORY] [0x%08X  = 0x%08X] %s = %s", self.address, numValue, self.name, value)
		end

		-- Queue up a hook event
		table.insert(memory.hook_queue, {name = self.name, value = value, debug = self.debug})
	end
end

local POINTER = {}
POINTER.__index = POINTER

function memory.newpointer(addr, offset, pointer)
	local struct = {}

	for poffset, pstruct in pairs(pointer.struct) do
		if pointer.name then
			pstruct.name = pointer.name .. "." .. pstruct.name
		end
		if pstruct.type == "pointer" then
			struct[poffset] = memory.newpointer(NULL, poffset, pstruct)
		else
			struct[poffset] = memory.newvalue(NULL, poffset, pstruct)
		end
	end

	return setmetatable({
		name = pointer.name,
		address = addr,
		offset = offset,
		location = NULL,
		struct = struct,
	}, POINTER)
end

function POINTER:update()
	local ploc = memory.readUInt(self.address + self.offset)

	if self.location ~= ploc then
		self.location = ploc

		if ploc == NULL then
			log.debug("[MEMORY] [0x%08X -> 0x0 (NULL)] %s = 0x%08X", self.address, self.name, self.address)
		else
			log.debug("[MEMORY] [0x%08X -> 0x%08X] %s = 0x%08X", self.address, ploc, self.name, ploc)
		end
	end

	for offset, struct in pairs(self.struct) do
		-- Set the address space to be where the containing pointer is pointing to
		struct.address = ploc
		-- Update the value/pointer recursively
		struct:update()
	end
end

function memory.loadmap(map)
	for address, struct in pairs(map) do
		if struct.type == "pointer" then
			memory.map[address] = memory.newpointer(address, NULL, struct)
		else
			memory.map[address] = memory.newvalue(address, NULL, struct)
		end
	end
end

function memory.hasPermissions()
	return memory.permissions
end

function memory.isInGame()
	local gid = memory.gameid
	return gid ~= GAME_NONE
end

function memory.isMelee()
	local gid = memory.gameid

	-- Force the GAMEID and VERSION to be Melee 1.02, since Fizzi seems to be using the gameid address space for something..
	if gid ~= GAME_NONE and PANEL_SETTINGS:IsSlippiNetplay() then
		gid = "GALE01"
		version = 0x02
	end

	local clone = clones[gid]
	if clone then gid = clone.id end

	return gid == "GALE01"
end

local timer = love.timer.getTime()

function memory.findGame()
	local gid = memory.readGameID()
	local version = memory.readGameVersion()

	-- Force the GAMEID and VERSION to be Melee 1.02, since Fizzi seems to be using the gameid address space for something..
	if gid ~= GAME_NONE and PANEL_SETTINGS:IsSlippiNetplay() then
		gid = "GALE01"
		version = 0x02
	end

	local meleeMode = (memory.isMelee() and memory.gameid ~= gid)

	if (not memory.ingame or meleeMode) and gid ~= GAME_NONE then
		memory.reset()
		memory.ingame = true
		memory.gameid = gid
		memory.version = version

		log.debug("[DOLPHIN] GAMEID: %q (Version %d)", gid, version)
		love.updateTitle(("M'Overlay - Dolphin hooked (%s-%d)"):format(gid, version))
		memory.runhook("OnGameOpen", gid, version)

		-- See if this GameID is a clone of another
		local clone = clones[gid]

		if clone then
			version = clone.version
			gid = clone.id
		end

		-- Try to load the game table
		local status, game = xpcall(require, debug.traceback, string.format("games.%s-%d", gid, version))

		if status then
			memory.game = game
			log.info("[DOLPHIN] Loaded game config: %s-%d", gid, version)
			memory.init(game.memorymap)
		else
			notification.error(("Unsupported game %s-%d"):format(gid, version))
			notification.error(("Playing slippi netplay? Press 'escape' and enable Rollback/Netplay mode"):format(gid, version))
			log.error("[DOLPHIN] %s", game)
		end
	elseif (memory.ingame or meleeMode) and gid == GAME_NONE then
		memory.reset()
		memory.ingame = false
		memory.gameid = gid
		memory.version = version

		love.updateTitle("M'Overlay - Dolphin hooked")
		memory.runhook("OnGameClosed", gid, version)
		memory.process:clearGamecubeRAMOffset() -- Clear the memory address space location (When a new game is opened, we recheck this)
		log.info("[DOLPHIN] Game closed..")
	end
end

function memory.update()
	if not memory.hasPermissions() then return end

	if not process:isProcessActive() and process:hasProcess() then
		process:close()
		love.updateTitle("M'Overlay - Waiting for Dolphin..")
		log.info("[DOLPHIN] Unhooked")
		memory.hooked = false
	end

	local t = love.timer.getTime()

	-- Only check for the dolphin process once per second to reduce CPU load
	if not process:hasProcess() or not process:hasGamecubeRAMOffset() then
		if timer <= t then
			timer = t + 0.5
			if process:findprocess() then
				log.info("[DOLPHIN] Hooked")
				love.updateTitle("M'Overlay - Dolphin hooked")
				memory.hooked = true
			elseif not process:hasGamecubeRAMOffset() and process:findGamecubeRAMOffset() then
				log.info("[DOLPHIN] Watching ram: %X [%X]", process:getGamecubeRAMOffset(), process:getGamecubeRAMSize())
			end
		end
	else
		memory.updatememory()

		local frame = memory.frame or 0
		if frame == 0 or memory.game_frame ~= frame then
			memory.game_frame = frame
			memory.runhooks()
		end
	end
end

function memory.init(map)
	log.info("[MEMORY] Mapping game memory..")
	memory.initialized = true
	memory.loadmap(map)
end

function memory.reset()
	memory.initialized = false
	memory.map = {}
	memory.values = {}
	memory.gameid = GAME_NONE
	memory.version = 0
	memory.game = nil
	setmetatable(memory, {__index = memory.values})
end

function memory.updatememory()
	memory.findGame()

	for addr, value in pairs(memory.map) do
		value:update()
	end
end

local function hookPattern(name)
	-- Convert '*' into capture patterns
	if string.find(name, "*", 1, true) then
		return true, '^' .. name:escape():gsub("%%%*", "([^.]-)") .. '$'
	end
	return false, name
end

function memory.hook(name, desc, callback)
	local wildcard, name = hookPattern(name)
	if wildcard then
		memory.wildcard_hooks[name] = memory.wildcard_hooks[name] or {}
		memory.wildcard_hooks[name][desc] = callback
	else
		memory.hooks[name] = memory.hooks[name] or {}
		memory.hooks[name][desc] = callback
	end
end

function memory.unhook(name, desc)
	memory.hook(name, desc, nil)
end

function memory.runhooks()
	local pop
	while true do
		pop = table.remove(memory.hook_queue, #memory.hook_queue)
		if not pop then break end
		memory.runhook(pop.name, pop.value)
	end
end

do
	local args = {}
	local matches = {}

	function memory.runhook(name, ...)
		-- Normal hooks
		if memory.hooks[name] then
			for desc, callback in pairs(memory.hooks[name]) do
				local succ, err
				if type(desc) == "table" then
					-- Assume a table is an object, so call it as so
					succ, err = xpcall(callback, debug.traceback, desc, ...)
				else
					succ, err = xpcall(callback, debug.traceback, ...)
				end
				if not succ then
					log.error("[MEMORY] hook error: %s (%s)", desc, err)
				end
			end
		end

		local varargs = {...}

		-- Allow for wildcard hooks
		for pattern, hooks in pairs(memory.wildcard_hooks) do
			if string.find(name, pattern) then
				args = {}
				matches = {name:match(pattern)}

				for k, match in ipairs(matches) do
					table.insert(args, tonumber(match) or match)
				end
				for k, arg in ipairs(varargs) do
					table.insert(args, arg)
				end

				for desc, callback in pairs(hooks) do
					local succ, err
					if type(desc) == "table" then
						-- Assume a table is an object, so call it as so
						succ, err = xpcall(callback, debug.traceback, desc, unpack(args))
					else
						succ, err = xpcall(callback, debug.traceback, unpack(args))
					end
					if not succ then
						log.error("[MEMORY] wildcard hook error: %s (%s)", desc, err)
					end
				end
			end
		end
	end
end

return memory