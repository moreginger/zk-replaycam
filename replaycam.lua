function widget:GetInfo()
	return {
		name    = "Action Tracking Camera DEV",
		desc    = "Automated camera for spectator mode DEV",
		author  = "fiendicus_prime",
		date    = "2023-11-24",
		license = "GNU GPL v2",
		layer   = 0,
		enabled = false
	}
end

-- PURPOSE AND STRATEGY
--
-- A widget that moves the camera to show the action in a game, in a cinematic and exciting way.
--
-- Strategy:
--
-- 1. Events are generated from different callins (UnitDamaged etc), merging with other events
--    of the same type
-- 2. Maintain a low resolution grid of hotspots of activity, and where we have recently been
--    watching (interestGrid)
-- 3. Scene events anticipate the action: places where one side's value is coming within reach
--    of the other's armed units (scenes)
-- 
-- The most interesting event is selected by comparison to other events of the same type,
-- adjusting by type (e.g. combat is generally more interesting than manufacture), and by the
-- interest grid.

local atan2 = math.atan2
local cos = math.cos
local deg = math.deg
local exp = math.exp
local log10 = math.log10
local floor = math.floor
local huge = math.huge
local max = math.max
local min = math.min
local pi = math.pi
local rad = math.rad
local sin = math.sin
local sqrt = math.sqrt
local tan = math.tan

local GL_FILL = GL.FILL
local GL_FRONT_AND_BACK = GL.FRONT_AND_BACK
local GL_LINE = GL.LINE
local glColor = gl.Color
local glLineWidth = gl.LineWidth
local glPolygonMode = gl.PolygonMode
local glRect = gl.Rect

local spEcho = Spring.Echo
local spGetAIInfo = Spring.GetAIInfo
local spGetAllyTeamList = Spring.GetAllyTeamList
local spGetCameraPosition = Spring.GetCameraPosition
local spGetCameraState = Spring.GetCameraState
local spGetGaiaTeamID = Spring.GetGaiaTeamID
local spGetGameRulesParam = Spring.GetGameRulesParam
local spGetGroundHeight = Spring.GetGroundHeight
local spGetHumanName = Spring.Utilities.GetHumanName
local spGetMouseState = Spring.GetMouseState
local spGetPixelDir = Spring.GetPixelDir
local spGetMovetype = Spring.Utilities.getMovetype
local spGetPlayerInfo = Spring.GetPlayerInfo
local spGetSpectatingState = Spring.GetSpectatingState
local spGetTeamColor = Spring.GetTeamColor
local spGetTeamInfo = Spring.GetTeamInfo
local spGetTeamList = Spring.GetTeamList
local spGetTeamRulesParam = Spring.GetTeamRulesParam
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitHealth = Spring.GetUnitHealth
local spGetUnitNoDraw = Spring.GetUnitNoDraw
local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitRulesParam = Spring.GetUnitRulesParam
local spGetUnitsInCylinder = Spring.GetUnitsInCylinder
local spGetUnitTeam = Spring.GetUnitTeam
local spGetUnitVelocity = Spring.GetUnitVelocity
local spGetVisibleUnits = Spring.GetVisibleUnits
local spGetViewGeometry = Spring.GetViewGeometry
local spIsReplay = Spring.IsReplay
local spSetCameraState = Spring.SetCameraState
local spSetMouseCursor = Spring.SetMouseCursor
local spTraceScreenRay = Spring.TraceScreenRay
local spWorldToScreenCoords = Spring.WorldToScreenCoords

local CMD_ATTACK = CMD.ATTACK
local CMD_ATTACK_MOVE = CMD.FIGHT
local CMD_MOVE = CMD.MOVE
local CMD_RAW_MOVE = VFS.Include("LuaRules/Configs/customcmds.lua").RAW_MOVE

local framesPerSecond = 30
local gameFrame = 0

-- CONFIGURATION

-- Must ship with false
local DEBUG = false
-- Emit machine-readable "rc-*" lines for scripts/generate-stats.py. Must ship with false (or DEBUG).
local STATS = DEBUG
local updateIntervalFrames = framesPerSecond
local defaultFov, defaultRx, defaultRy = 45, -1.0, pi
-- Time until we think the user is watching, not playing
local userInactiveSecondsThreshold = 2

-- GUI COMPONENTS

-- Callout and ground markings for the shot (see OVERLAY)
local overlay = { tally = {}, allyColor = {} }

i18nPrefix = 'actiontrackingcamera_'
options_path = 'Settings/Spectating/Action Tracking Camera'
options_order = {"user_interrupts_tracking", "camera_rotation", "show_commentary", "tracking_reticle"}
options = {
	user_interrupts_tracking = {
		type = 'bool',
		value = true,
	},
	camera_rotation = {
		type = 'bool',
		value = true,
	},
	show_commentary = {
		type = 'bool',
		value = true,
	},
	tracking_reticle = {
		type = 'bool',
		value = false,
	}
}

-- UTILITY FUNCTIONS

-- Initialize a table.
local function initTable(key, value)
	local result = {}
	if key then
		result[key] = value
	end
	return result
end

-- Calculate length of a vector
local function length(x, y, z)
	return sqrt(x * x + y * y + (z and z * z or 0))
end

-- Calculate x, y, z distance between two { x, y, z } points.
local function distance(p1, p2)
	local x, y, z = p1[1], p1[2], p1[3]
	if p2 then
		x, y, z = x - p2[1], y - p2[2], z - p2[3]
	end
	return length(x, y, z)
end

-- Bound a number to be >= min and <= max
local function bound(x, min, max)
	if x < min then
		return min
	end
	if x > max then
		return max
	end
	return x
end

-- Wrap an angle to [-pi, pi)
local function wrapAngle(a)
	return (a + pi) % (2 * pi) - pi
end

-- Critically damped spring (Game Programming Gems 4, 1.10). Gets ~90% of the way in 2x smoothTime
-- whatever the distance, without overshoot. maxSpeed (optional) caps the speed of the approach.
-- Returns the new value and velocity.
local function smoothDamp(current, target, velocity, smoothTime, dt, maxSpeed)
	local omega = 2 / smoothTime
	local x = omega * dt
	local e = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
	local change = current - target
	if maxSpeed then
		local maxChange = maxSpeed * smoothTime
		change = bound(change, -maxChange, maxChange)
	end
	local temp = (velocity + omega * change) * dt
	return current - change + (change + temp) * e, (velocity - omega * temp) * e
end

-- smoothDamp for 3-vectors, capping the speed along the direction of travel. Updates in place.
local function smoothDampVec(current, target, velocity, smoothTime, dt, maxSpeed)
	local omega = 2 / smoothTime
	local x = omega * dt
	local e = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
	local c1, c2, c3 = current[1] - target[1], current[2] - target[2], current[3] - target[3]
	local cl = length(c1, c2, c3)
	local maxChange = maxSpeed * smoothTime
	if cl > maxChange then
		local f = maxChange / cl
		c1, c2, c3 = c1 * f, c2 * f, c3 * f
	end
	local change = { c1, c2, c3 }
	for i = 1, 3 do
		local temp = (velocity[i] + omega * change[i]) * dt
		current[i] = current[i] - change[i] + (change[i] + temp) * e
		velocity[i] = (velocity[i] - omega * temp) * e
	end
end

local function logistic(x)
	return 1 / (1 + exp(-x))
end

local function applyDamping(old, new, rollingFraction, dt)
	dt = dt or 1
	local newFraction = (1 - rollingFraction) * dt
	return (1 - newFraction) * old + newFraction * new
end

local function _apply(fun, vector, arg1, arg2)
	local result = {}
	for k, v in pairs(vector) do
		result[k] = fun(v, arg1, arg2)
	end
	return result
end

local function _apply2(fun, vector1, vector2, arg1, arg2)
	local result = {}
	for k, v in pairs(vector1) do
		result[k] = fun(v, vector2[k], arg1, arg2)
	end
	return result
end

local function _multiply(a, b, c)
	return a * b * (c or 1)
end

local function _extrapolate(current, rate, dt)
	return current + rate * dt
end

-- SPRING UTILS

local function getUnitLocation(unitID)
	local x, y, z = spGetUnitPosition(unitID)
	return x and y and z and { x, y, z }
end

local function getUnitVelocity(unitID)
	local xv, yv, zv = spGetUnitVelocity(unitID)
	return xv and yv and zv and { xv, yv, zv }
end

-- LINKED LIST CLASS

-- capacity of 0 = unlimited
LinkedList = { capacity = 0, size = 0, head = nil, _tail = nil }

function LinkedList:new(o)
	o = o or {}
	setmetatable(o, self)
	self.__index = self

	return o
end

function LinkedList:add(e)
	local tail, head = self._tail, self.head
	if not tail and not head then
		self._tail = e
		self.head = e
		self.size = 1
	else
		head.next = e
		e.prev = head
		self.head = e
		if self.capacity > 0 and self.capacity == self.size then
			tail.next.prev = nil
			self._tail = tail.next
		else
			self.size = self.size + 1
		end
	end
end

function LinkedList:remove(e)
	local prev, next = e.prev, e.next
	if e == self.head then
		self.head = prev
	end
	if e == self._tail then
		self._tail = next
	end
	if prev then
		prev.next = next
	end
	if next then
		next.prev = prev
	end
	e.prev, e.next = nil, nil
	self.size = self.size - 1

	return prev, next
end

function LinkedList:clear()
	-- We do it this way to unlink all elements as well
	local e = self.head
	while e ~= nil do
		e, _ = self:remove(e)
	end
end

-- WORLD GRID CLASS
-- Translates world coordinates into operations on a grid.

WorldGrid = { xSize = 0, ySize = 0, gridSize = 0, teamCount = 0, allyTeams = {}, data = {} }

function WorldGrid:new(o)
	o = o or {} -- create object if user does not provide one
	setmetatable(o, self)
	self.__index = self

    o.teamCount = o.teamCount or 0
	o.allyTeams = o.allyTeams or {}
	o.data = o.data or {}
	for x = 1, o.xSize do
		o.data[x] = {}
		for y = 1, o.ySize do
			o.data[x][y] = { 1, {}, 0, 0 }
		end
	end

	return o
end

function WorldGrid:__toGridCoords(x, y)
	x = 1 + bound(floor(x / self.gridSize), 0, self.xSize - 1)
	y = 1 + bound(floor(y / self.gridSize), 0, self.ySize - 1)
	return x, y
end

-- Return the center of the grid in world coordinates
function WorldGrid:__toWorldCoords(gx, gy)
	local halfGrid = self.gridSize / 2
	return gx * self.gridSize - halfGrid, gy * self.gridSize - halfGrid
end

-- Lazily synchronize grid cell to game frame
function WorldGrid:_syncCell(data)
	local framesPassed = gameFrame - data[4]
	if framesPassed > 0 then
		data[1] = 1 + (data[1] - 1) * (0.95 ^ framesPassed)
		data[3] = max(0, data[3] - framesPassed / framesPerSecond)
		for team, expiry in pairs(data[2]) do
			if gameFrame >= expiry then
				data[2][team] = nil
			end
		end
		data[4] = gameFrame
	end
end

function WorldGrid:_getScoreGridCoords(x, y)
	local data = self.data[x][y]
	self:_syncCell(data)
	local interest, allyTeams, passe = unpack(data)
	local allyTeamCount = 0
	for _, _ in pairs(allyTeams) do
		allyTeamCount = allyTeamCount + 1
	end
	local allyTeamsMult = max(1, allyTeamCount * allyTeamCount)
	-- We want passe to kick in slowly then get strong after 10s or so;
	-- use logistic function
	-- Shift the function to the right given min passe is 0
	local passeMult = 1 - logistic(0.4 * (passe - 8))
	return interest * allyTeamsMult * passeMult
end

function WorldGrid:getScore(x, y)
	x, y = self:__toGridCoords(x, y)
	return self:_getScoreGridCoords(x, y)
end

-- Raw activity at a location: interest and interacting teams, ignoring how recently we watched it
function WorldGrid:getActivity(x, y)
	x, y = self:__toGridCoords(x, y)
	local data = self.data[x][y]
	self:_syncCell(data)
	local allyTeamCount = 0
	for _, _ in pairs(data[2]) do
		allyTeamCount = allyTeamCount + 1
	end
	return data[1] * max(1, allyTeamCount * allyTeamCount)
end

-- Call func on each square under a size-wide square centred on (x, y), with the share of it that
-- falls there. Squares off the map don't count.
function WorldGrid:_addInternal(x, y, size, opts, func)
	local function overlaps(c, count)
		local spans, total, g = {}, 0, 1 + bound(floor(c / self.gridSize), 0, count - 1)
		for i = max(1, g - 1), min(count, g + 1) do
			spans[i] = max(0, min(c + size / 2, i * self.gridSize) - max(c - size / 2, (i - 1) * self.gridSize))
			total = total + spans[i]
		end
		return spans, total
	end
	local xs, xTotal = overlaps(x, self.xSize)
	local ys, yTotal = overlaps(y, self.ySize)
	for ix, ox in pairs(xs) do
		for iy, oy in pairs(ys) do
			if ox * oy > 0 then
				local data = self.data[ix][iy]
				self:_syncCell(data)
				func(data, ox * oy / (xTotal * yTotal), opts)
			end
		end
	end
end

local function _addInterest(data, f, opts)
	data[1] = data[1] + opts.interest * f
	if opts.allyTeam then
		data[2][opts.allyTeam] = gameFrame + framesPerSecond
	end
end

local function _boostInterest(data, f, opts)
	data[1] = data[1] * (1 + (opts.boost - 1) * f)
end

local function _addPasse(data, f, opts)
	data[3] = data[3] + opts.passe * f
end

function WorldGrid:add(x, y, allyTeam, interest)
	return self:_addInternal(x, y, self.gridSize, { allyTeam = allyTeam, interest = interest }, _addInterest)
end

-- Call this exactly once between each reset.
-- When watching an area we apply a fixed boost to make things sticky,
-- but a longer-term negative factor (passe) to encourage moving.
function WorldGrid:setWatching(x, y)
	-- Both are spread over a 2x2 grid, so hopping to the next square doesn't escape passe. Passe
	-- wears off by 1/s in each square, so only more than that tells.
	self:_addInternal(x, y, self.gridSize * 2, { boost = 10 }, _boostInterest)
	self:_addInternal(x, y, self.gridSize * 2, { passe = 10 }, _addPasse)
end

function WorldGrid:setCursor(x, y)
	self:_addInternal(x, y, self.gridSize, { boost = 10 / self.teamCount }, _boostInterest)
end

-- SPATIAL LOOKUP CLASS
-- Manages items in a grid for fast proximity searches, keeping only the N most recent items.
-- Assumes any item added has a `location` property (a table where location[1] is x and location[3] is z)

SpatialLookup = { xSize = 0, ySize = 0, gridSize = 0, capacity = 0, data = {}, _items = nil }

function SpatialLookup:new(o)
	o = o or {}
	setmetatable(o, self)
	self.__index = self

	o.data = o.data or {}
	for x = 1, o.xSize do
		o.data[x] = {}
		for y = 1, o.ySize do
			o.data[x][y] = {}
		end
	end
	o._items = LinkedList:new({ capacity = o.capacity })

	return o
end

function SpatialLookup:__toGridCoords(x, y)
	x = 1 + bound(floor(x / self.gridSize), 0, self.xSize - 1)
	y = 1 + bound(floor(y / self.gridSize), 0, self.ySize - 1)
	return x, y
end

function SpatialLookup:add(item)
	local gx, gy = self:__toGridCoords(item.location[1], item.location[3])
	
	if item.prev or item.next or self._items.head == item then
		self._items:remove(item)
		local oldGx, oldGy = self:__toGridCoords(item.location[1], item.location[3])
		self.data[oldGx][oldGy][item] = nil
	elseif self.capacity > 0 and self._items.size == self.capacity then
		local oldest = self._items._tail
		self._items:remove(oldest)
		local oldGx, oldGy = self:__toGridCoords(oldest.location[1], oldest.location[3])
		self.data[oldGx][oldGy][oldest] = nil
	end

	self.data[gx][gy][item] = true
	self._items:add(item)
end

function SpatialLookup:remove(item)
	local prev, next
	if item.location then
		if item.prev or item.next or self._items.head == item then
			prev, next = self._items:remove(item)
		end
		local gx, gy = self:__toGridCoords(item.location[1], item.location[3])
		self.data[gx][gy][item] = nil
	end
	return prev, next
end

-- If evalFunc is provided, it should return a numerical score for the item, or nil to filter it out.
-- getNearby will return the item with the highest score.
function SpatialLookup:getNearby(x, y, range, evalFunc)
	local minGx, minGy = self:__toGridCoords(x - range, y - range)
	local maxGx, maxGy = self:__toGridCoords(x + range, y + range)
	local rangeSq = range * range
	local bestItem = nil
	local bestScore = -huge
	for gx = minGx, maxGx do
		for gy = minGy, maxGy do
			for item, _ in pairs(self.data[gx][gy]) do
				local dx, dy = item.location[1] - x, item.location[3] - y
				if dx * dx + dy * dy <= rangeSq and evalFunc(item) then
					local score = evalFunc(item)
					if score and score > bestScore then
						bestItem = item
						bestScore = score
					end
				end
			end
		end
	end
	return bestItem
end

-- UNIT INFO CACHE

local unitInfoCacheFrames = framesPerSecond

-- locationListener is called whenever a position is read, updateListener exactly once per unit
-- per unitInfoCacheFrames
UnitInfoCache = { locationListener = nil, updateListener = nil }

function UnitInfoCache:new(o)
	o = o or {} -- create object if user does not provide one
	setmetatable(o, self)
	self.__index = self

	-- cacheObject {}
    -- 1 - unit importance
	-- 2 - static (not mobile)
	-- 3 - weapon importance
	-- 4 - weapon range
	o._unitStatsCache = {}
	-- cacheObject { name, allyTeam, unitDefID, lastUpdatedFrame, location, velocity }
	o.cache = o.cache or {}
	o.locationListener = o.locationListener or nil
	return o
end

-- Weapon importance, 0 if no weapon found.
function UnitInfoCache:_weaponStats(unitDef)
	-- Get weapon damage from first weapon. Hacked together from gui_contextmenu.lua.
	local weapon = unitDef.weapons[1]
	if not weapon then
		return 0, 0
	end
	local wd = WeaponDefs[weapon.weaponDef]
  local wdcp = wd.customParams
	if not wdcp or wdcp.fake_weapon then
		return 0, 0
	end
	-- Weapon damage is burst damage that can be delivered in 1s.
	local projectileMult = tonumber(wdcp.statsprojectiles) or ((tonumber(wdcp.script_burst) or wd.salvoSize) * wd.projectiles)
	local reloadTime = tonumber(wdcp.script_reload) or wd.reload
	local weaponDamage = tonumber(wdcp.stats_damage) * projectileMult / min(1, reloadTime)
	local aoe = wd.impactOnly and 0 or wd.damageAreaOfEffect
	-- Likho bomb is 192 so this gives a boost of 1 + 2.25. Feels about right.
	local aoeBoost = 1 + (aoe * aoe) / (128 * 128)
	-- Afterburn is difficult to quantify; dps is 15 but it also decloaks, burntime varies but
	-- ground flames may persist, denying area and causing more damage. Shrug.
	local afterburnBoost = 1 or ((wdcp.burntime or wd.fireStarter) and 1.5)
    -- FIXME: Make Newton damage "important"
	local weaponImportance = weaponDamage * aoeBoost * afterburnBoost
	local range = wdcp.truerange or wd.range
	return weaponImportance, range
end

-- Static units are less interesting just for being built, but they matter when they are fought over
local staticAttackedBoost = 1.5
-- Damage no unit can be blamed for, such as fire burning on after whoever lit it has died, lava or
-- a shell landing after its gun is gone, is mostly not the fight itself
local unattributedDamageFactor = 0.25

function UnitInfoCache:_unitStats(unitDefID)
	local cacheObject = self._unitStatsCache[unitDefID]
	if not cacheObject then
		local unitDef = UnitDefs[unitDefID]
		local isStatic = not spGetMovetype(unitDef)
		local importance = unitDef.metalCost
	    if unitDef.customParams.ismex then
			-- Give mexes a little extra buff since they are cheap but important
			importance = importance * 1.5
		end
		if unitDef.name == 'terraunit' then
			-- terraunit has fixed cost of 100000, actual estimated cost is a unit rules param that we try to read later
			importance = 500
		end
		local wImportance, wRange = self:_weaponStats(unitDef)
		cacheObject = { importance, isStatic, wImportance, wRange }
		self._unitStatsCache[unitDefID] = cacheObject
	end
	return unpack(cacheObject)
end

function UnitInfoCache:_updatePosition(unitID, cacheObject)
	local location = getUnitLocation(unitID)
	local velocity = getUnitVelocity(unitID)
	if not location or not velocity then
		return false
	end

	local noDraw = spGetUnitNoDraw(unitID)
	if noDraw then
		-- Various units (e.g. puppies) use a noDraw hack combined with location displacement
		-- Don't update or ping in this state. Return true unless we have nothing cached
		return cacheObject.location and cacheObject.velocity
	end

	cacheObject.location = location
	cacheObject.velocity = velocity

	if self.locationListener then
		local isMoving = distance(velocity) > 0.1
		self.locationListener(location, cacheObject.allyTeam, isMoving)
	end

	return true
end

function UnitInfoCache:watch(unitID, allyTeam, unitDefID)
	if not unitDefID then
		unitDefID = spGetUnitDefID(unitID)
	end
	local unitDef = UnitDefs[unitDefID]
	local name = spGetHumanName(unitDef, unitID)
	local importance, _, _, _ = self:_unitStats(unitDefID)
	-- What it cost, unlike importance, which is how much the camera cares about it
	local metal = unitDef.metalCost
	if unitDef.name == 'terraunit' then
		-- FIXME: This is set in unit_terraform.lua, but not accessible here?
		importance = spGetUnitRulesParam(unitID, 'terraform_estimate') or importance
		metal = importance
		spEcho('terraform_estimate', importance)
	end
	local cacheObject = { name = name, allyTeam = allyTeam, unitDefID = unitDefID, importance = importance, metal = metal,
		lastUpdatedFrame = gameFrame }
	if not self:_updatePosition(unitID, cacheObject) then
		return
	end
	self.cache[unitID] = cacheObject
	return self:get(unitID)
end

-- Returns unit info including rough position.
function UnitInfoCache:get(unitID)
	local cacheObject = self.cache[unitID]
	if cacheObject then
		local _, isStatic, weaponImportance, weaponRange = self:_unitStats(cacheObject.unitDefID)
		local dt = (gameFrame - cacheObject.lastUpdatedFrame) / framesPerSecond
		local location = _apply2(_extrapolate, cacheObject.location, cacheObject.velocity, dt)
		return location, cacheObject.velocity, cacheObject.importance, cacheObject.name, isStatic, weaponImportance, weaponRange
	end
	local unitTeamID = spGetUnitTeam(unitID)
	if not unitTeamID then
		spEcho("ERROR! UnitInfoCache:get failed", unitID)
		return
	end
	local _, _, _, _, _, allyTeam = spGetTeamInfo(unitTeamID)
	return self:watch(unitID, allyTeam)
end

function UnitInfoCache:forget(unitID)
	if self.cache[unitID] then
		-- Don't remove immediately as we may need to get information for event display
		self.cache[unitID].removeAfterFrame = gameFrame + framesPerSecond * 30
	end
end

function UnitInfoCache:update(currentFrame)
	for unitID, cacheObject in pairs(self.cache) do
		if cacheObject.removeAfterFrame then
			if currentFrame > cacheObject.removeAfterFrame then
				self.cache[unitID] = nil
			end
		elseif currentFrame - cacheObject.lastUpdatedFrame >= unitInfoCacheFrames then
			cacheObject.lastUpdatedFrame = currentFrame
			if not self:_updatePosition(unitID, cacheObject) then
				-- Something went wrong, drop from cache.
				self.cache[unitID] = nil
			elseif self.updateListener then
				self.updateListener(cacheObject)
			end
		end
	end
end

-- EVENT

local eventMergeRange = 256

-- This value gives a decay of 0.018 at time zero
local eventDecayBase = 4

Event = {}

function Event:new(o)
	o = o or {} -- create object if user does not provide one
	setmetatable(o, self)
	self.__index = self

	o._excludes = {}
    o._objUnits = {}
	o._sbjUnits = {}
	return o
end

-- This event, if shown, excludes the other from being shown
function Event:addExcludes(other)
	self._excludes[other.id] = true
end

-- Add an object unit i.e. the unit being done to
function Event:addObject(unitID, location)
	self._objUnits[unitID] = location
end

-- Add a subject unit i.e. the unit doing the thing
function Event:addSubject(unitID, location)
	self._sbjUnits[unitID] = location
	-- The costliest subject, noted while it is still there to ask
	local unitDefID = spGetUnitDefID(unitID)
	if unitDefID then
		self.metal = max(self.metal or 0, UnitDefs[unitDefID].metalCost)
	end
end

function Event:excludes(other)
	return self._excludes[other.id]
end

function Event:valueAtFrame(value, frame)
  return value * (1 - logistic(eventDecayBase / self.decay * (frame - self.started - self.decay)))
end

-- return - true if there are no more subjects
function Event:removeSubject(unitID)
	self._sbjUnits[unitID] = nil
	for _, _ in pairs(self._sbjUnits) do
		return false
	end
	return true
end

function Event:subjectCount()
	local count = 0
	for _, _ in pairs(self._sbjUnits) do
		count = count + 1
	end
	return count
end

-- EVENT STATISTICS

EventStatistics = { eventMeanAdj = {} }

function EventStatistics:new(o, types)
	o = o or {} -- create object if user does not provide one
	setmetatable(o, self)
	self.__index = self

	for type, _ in pairs(types) do
		o[type] = { 0, 0 }
	end

	return o
end

function EventStatistics:logEvent(type, importance)
	local oldCount, meanImportance = unpack(self[type])
	-- Switch to a weighted mean after a certain number of events, for faster adaptation.
	local newCount = (oldCount == 32 and oldCount) or oldCount + 1

	meanImportance = meanImportance * (newCount - 1) / newCount + importance / newCount
	self[type][1] = newCount
	self[type][2] = meanImportance
end

-- Return percentile in unit range
function EventStatistics:getPercentile(type, importance)
	local meanImportance = self[type][2]

	-- Assume exponential distribution
	local m = 1 / (meanImportance * self.eventMeanAdj[type])
	return 1 - exp(-m * importance)
end


-- WORLD INFO

local mapSizeX, mapSizeZ = Game.mapSizeX, Game.mapSizeZ
local worldGridSize = 512
local mapGridX, mapGridZ = mapSizeX / worldGridSize, mapSizeZ / worldGridSize
local teamInfo, interestGrid, unitInfo

-- EVENT TRACKING

local attackEventType = "attack"
local buildingEventType = "building"
local lullEventType = "lull"
local moveEventType = "move"
local sceneEventType = "scene"
local unitBuiltEventType = "unitBuilt"
local unitDamagedEventType = "unitDamaged"
local unitDestroyedEventType = "unitDestroyed"
local unitDestroyerEventType = "unitDestroyer"
local unitTakenEventType = "unitTaken"
local eventTypes = {
	attack = true,
	building = true,
	lull = true,
	move = true,
	scene = true,
	unitBuilt = true,
	unitDamaged = true,
	unitDestroyed = true,
	unitDestroyer = true,
	unitTaken = true
}
local eventTypesCount = 0
for _, enabled in pairs(eventTypes) do
	eventTypesCount = eventTypesCount + (enabled and 1 or 0)
end

-- Logistic decay, time in frames to reach 1/2 of original value
local eventDecayFactors = _apply(_multiply, {
	attack = 1,
	building = 5,
	lull = 4,
	move = 2,
	scene = 2,
	unitBuilt = 5,
	unitDamaged = 2,
	unitDestroyed = 3,
	unitDestroyer = 3,
	unitTaken = 3
}, framesPerSecond)

local eventStatistics = EventStatistics:new({
	-- Adjust mean of events in percentile estimation
	-- > 1: make each event seem more likely (less interesting)
	-- < 1: make each event seem less likely (more interesting)
	eventMeanAdj = {
		attack = 1.0,
		building = 2.4,
		lull = 1.0,
		move = 5.0,
		scene = 1.0,
		unitBuilt = 1.9,
		unitDamaged = 0.8,
		unitDestroyed = 0.5,
		unitDestroyer = 0.7,
		unitTaken = 0.2
	}
}, eventTypes)

local lastEventId = 0
local events = SpatialLookup:new({ xSize = mapGridX, ySize = mapGridZ, gridSize = worldGridSize, capacity = 128 })
local mie, pendingMie

local function _getInterestModifier(event)
	if event.type == lullEventType or event.type == sceneEventType then
		-- Lulls have a pseudo-location in the middle of a wide area, and should ignore what is happening
		-- there. Scenes do their own accounting of what's new (see scenes).
		return 1
	end
	local x, _, z = unpack(event.location)
	return interestGrid:getScore(x, z)
end

local function _getEventPercentile(currentFrame, event)
	local importance = event:valueAtFrame(event.importance, currentFrame)
	return eventStatistics:getPercentile(event.type, importance * _getInterestModifier(event))
end

-- Against a challenger the pick's importance counts this many times over, more for ones that
-- take longer to get to (see transitionCost).
local switchBoostNear, switchBoostFar = 2, 3.3
local lockedRarity = 0.5
-- transitionCost(location) returns 0 for something already framed, up to 1 for a cut. Defined
-- with the camera.
local transitionCost

local function _getRarity(event)
	return 1 - _getEventPercentile(gameFrame, event)
end

-- Boosting importance by b raises rarity to the power b, so a decayed pick still gives way.
-- boostScale multiplies the boost, e.g. while the shot is locked.
local function _beatsPick(event, rarity, boostScale)
	if not mie then
		return true
	end
	local boost = switchBoostNear
	-- A wide lull shot shows the other event anyway, so moving between them costs little
	if mie.type ~= lullEventType and event.type ~= lullEventType then
		boost = switchBoostNear + (switchBoostFar - switchBoostNear) * transitionCost(event.location)
	end
	local pickRarity = _getRarity(mie)
	if boostScale then
		-- A locked shot holds like a fair pick, however weak it was
		pickRarity = min(pickRarity, lockedRarity)
		boost = boost * boostScale
	end
	return rarity < pickRarity ^ boost
end

local ADD_EVENT_OPTS_NO_GRID_NO_MERGE = { noGrid = true, noMerge = true }

-- updateFunc - Optional function taking the event as a parameter.
-- returns event {}
-- - units Contains unit IDs and their current locations. May contain negative unit IDs e.g. for dead units.
local function addEvent(actor, importance, location, meta, sbjName, type, unitID, updateFunc, opts)
	if not importance or not location or not sbjName or not type then
		spEcho("ERROR! addEvent failed", importance, location, sbjName, type)
		return Event:new({ id = -1, importance = 0, type = type or "nil", location = location or {0, 0, 0}, started = 0 })
	end
	if importance > 10000000 then
	    -- Safety net, should not happen
		spEcho('ERROR! addEvent with extreme importance', importance, type)
		if not DEBUG then
			return Event:new({ id = -1, importance = 0, type = type, location = location, started = 0 })
		end
	end
	opts = opts or {}

	local decay = eventDecayFactors[type]
	local actorAllyTeam = actor and teamInfo[actor].allyTeam

	if not opts.noGrid then
		interestGrid:add(location[1], location[3], actorAllyTeam, importance)
	end

	-- Try to merge into recent events.
	local considerForMergeAfterFrame = gameFrame - framesPerSecond
	local event = nil
	if not opts.noMerge then
		event = events:getNearby(location[1], location[3], opts.mergeRange or eventMergeRange, function(e)
			-- The current pick keeps merging for as long as it lasts.
			return (e.started >= considerForMergeAfterFrame or e == mie)
		        and e.type == type
				and e.sbjName == sbjName
				and e.actorAllyTeam == actorAllyTeam
				and e.started
				or nil
		end)
	end

	if event then
		if STATS and event == mie then
			spEcho(string.format('rc-extend,%d,%s', event.id, type))
		end

		-- Remove it and attach at head later. Must do this before mutating event.location
		events:remove(event)

		-- Merge new event into old.
		event.importance = event:valueAtFrame(event.importance, gameFrame) + importance
		event.decay = decay
		event.location = location
		event.started = gameFrame
		if actor and not event.actors[actor] then
			event.actorCount = event.actorCount + 1
			event.actors[actor] = actor
		end
		if unitID then
			event:addSubject(unitID, location)
		end
	else
		lastEventId = lastEventId + 1
		event = Event:new({
			actorCount = 1,
			actors = initTable(actor, true),
			actorAllyTeam = actorAllyTeam,
			decay = decay,
			updateFunc = updateFunc,
			id = lastEventId,
			importance = importance,
			location = location,
			meta = meta,
			sbjName = sbjName,
			started = gameFrame,
			type = type
		})
		if unitID then
		  event:addSubject(unitID, location)
		end
	end

	events:add(event)

	if event.updateFunc then
		event.updateFunc(event)
	end

	eventStatistics:logEvent(event.type, event.importance * _getInterestModifier(event))

	if eventTypes[event.type] then
		local rarity = _getRarity(event)
		if event == mie then
			-- A strengthened pick can win back a pending cut.
			if pendingMie and pendingMie ~= mie and not _beatsPick(pendingMie, _getRarity(pendingMie)) then
				pendingMie = mie
			end
		elseif rarity < (pendingMie and pendingMie ~= mie and _getRarity(pendingMie) or 1)
		    and _beatsPick(event, rarity) then
			pendingMie = event
		end
	end

	return event
end

-- eventProcessor - perform processing and return truthy to remove the event
local function purgeEvents(eventProcessor, opts)
	local event = events._items.head
	while event ~= nil do
		if eventProcessor(event, opts) then
			if event == pendingMie then
				-- Its subjects are gone, don't show it.
				pendingMie = nil
			end
			event, _ = events:remove(event)
		else
			event = event.prev
		end
	end
end

local function __purgeExcludes(event, opts)
	return opts.excluder:excludes(event)
end

local function __purgeSubject(event, opts)
  return event:removeSubject(opts.unitID)
end

local function __purgeCommands(event, opts)
	if event.type ~= attackEventType and event.type ~= moveEventType then
		return false
	end
	return event:removeSubject(opts.unitID)
end




-- EVENT DISPLAY

local camTypeTracking = 'tracking'
local camDiagMin = 1000
-- Share of the screen a shot's box may span, as projected, per axis (see frameBox)
local frameFill = 0.58
-- The camera is a drone orbiting a look-at point at some distance, pitch and yaw, and always points
-- at it. Each of these follows its target on a critically damped spring (see smoothDamp), so the
-- event can't be pulled out of frame by rotation and zoom lagging behind translation.
local lookSmoothTime = 0.45
-- Caps pan speed (elmos/s) so long pans glide rather than whip
local lookMaxSpeed = worldGridSize * 5
local distSmoothTime = 0.7
local pitchSmoothTime = 0.6
local yawSmoothTime = 1.2
-- While panning, pull out by this share of the remaining pan, up to this share of the shot
-- distance, so the camera arcs up and over rather than skimming the ground.
local panArcRise, panArcMax = 0.4, 0.75
-- A new shot turns to face its event by at most this much
local maxShotYawChange = pi / 3
-- Cut rather than pan when the pan would take longer than this
local maxPanSeconds = 1.8
-- Lull events: when a fight dies down, a lull event frames the spread of activity across the map in
-- a wide, north-facing shot. It fires once per fight, when recent damage drops well below its recent
-- peak, with that peak as its importance, so bigger fights ending are more likely to be shown.
-- (A table, as Lua 5.1 allows only 200 locals here.)
local lullConfig = {
	-- Damage (metal value per second) is averaged over a short and a long window. The short
	-- average's peak decays with this half-life.
	damageShortSeconds = 5, damageLongSeconds = 60, peakHalfLifeSeconds = 30,
	-- A fight is a peak of at least minPeak, and at least minPeakRatio times the long average
	minPeak = 10, minPeakRatio = 1.5,
	-- Fire when the short average falls to dropRatio of the peak; rearm once back over rearmRatio
	dropRatio = 0.3, rearmRatio = 0.6,
	-- Frame every grid cell with at least this much activity (idle is 1; a moving unit adds about 1)
	cellMin = 1.5,
	-- Frame at least this diagonal, and fill this share of the screen
	minDiag = 2000, fill = 0.9,
	pitch = -1.2,
}
-- Lull detection, defined with the display code. damage has this second's damage, its short and
-- long running means and the short mean's decaying peak (metal value per second).
local lull = { damage = { now = 0, short = 0, long = 0, peak = 0 }, armed = false }

-- Scenes: a scene is a place where value is at stake, i.e. one side's metal within reach of the
-- other's armed units, now or in the next few seconds on their current heading. Clashes, raids and
-- bombing runs all score the same way, in metal. Orders are ignored: players change their minds,
-- so only where units are actually going counts, and less the further ahead it is.
local scenes = {
	-- Armed units are projected along their velocity to these times (s), with these weights
	horizon = { 0, 3, 6, 9 }, discount = { 1, 0.6, 0.3, 0.15 },
	-- Metal an armed unit puts at stake, per metal of its own cost
	leverage = 2,
	-- A cell's stake counts by how far it has risen over its average of this many seconds, so a
	-- standoff fades. Ignore rises below minStake.
	baselineSeconds = 30, minStake = 150,
	-- ... or of this many seconds, within watchedRange of where the camera is looking. A scene on
	-- show holds the camera only while its stake keeps growing.
	watchedSeconds = 3, watchedRange = worldGridSize,
	-- Add events for at most this many scenes a second, at least this many cells apart
	maxScenes = 2, separation = 3,
	-- Frame the units this close to the cell centre
	radius = worldGridSize * 0.75,
	-- The stake on show is steadied over about this many seconds
	shownStakeSeconds = 3,
	-- A scene already under way only moves as far as the rise moves beyond this
	deadZone = 128,
	-- A scene this big and this close to the shot is taken into frame for a few seconds
	asideStake = 600, asideRange = worldGridSize * 2.5, asideFrames = 3 * framesPerSecond,
	eventOpts = { noGrid = true, mergeRange = worldGridSize * 1.5 },
	-- Average stake by cell, and ally team names
	baseline = {}, names = {},
	-- This second's value (importance, for scoring), metal (what it cost, for the callout), armed
	-- strength over the horizon and armed strength now, by ally team and cell
	value = {}, metal = {}, power = {}, powerNow = {},
}

-- Orbits: once a shot is framed, the camera may slowly fly around the event to a heading that
-- shows more of what's going on nearby, keeps the map on screen and isn't blocked by terrain.
-- An orbit has to improve what's in view; heading preferences (turn, north) only pick between
-- equally good views.
local orbitConfig = {
	candidateStep = pi / 6,
	smoothTime = 3,
	-- Start planning this long after framing, and replan this often
	startFrames = 2 * framesPerSecond, planFrames = framesPerSecond,
	-- Orbit when another heading's view scores this much better, before heading preferences
	margin = 0.4,
	-- On a long hold, drift once to a heading at least driftMin away that scores nearly as well
	driftFrames = 6 * framesPerSecond, driftMin = pi / 9, driftTolerance = 0.2,
	-- activity: mean log10 activity in view; offMap: share of view off the map; occluded: terrain
	-- samples blocking the line of sight; turn: per half turn from the current heading; north: per
	-- quarter turn from north
	headingWeights = { activity = 1, offMap = 3, occluded = 0.5, turn = 0.3, north = 0.3 },
	headingSamples = { -0.9, -0.45, 0, 0.45, 0.9 },
}
-- Shot lock: a new shot holds until it has framed its event, then for minShotFrames more. Only a
-- challenger that beats it with the pick boost multiplied by shotLockBoost can cut in sooner.
-- If framing never happens (e.g. user control), the lock gives up after maxShotLockFrames.
local minShotFrames = 2 * framesPerSecond
local maxShotLockFrames = 3 * framesPerSecond
local shotLockBoost = 2
-- A unit can be counted as stunned again after this long
local stunFrames = 10 * framesPerSecond
local mapEdgeBorder = worldGridSize * 0.5
local keepTrackingRange = worldGridSize * 2

-- A shot counts as framed once its tracking box is on screen and its centre is in the middle half.
local framedCentre = 0.25

local display, initialCameraState, camera
-- Event the camera is actually showing (updateDisplay may refuse to switch)
local shownEvent

-- Whether a world location is in view
local function onScreen(location)
	local vsx, vsy = spGetViewGeometry()
	local sx, sy, sz = spWorldToScreenCoords(location[1], location[2], location[3])
	return sx and sz >= 0 and sz <= 1 and sx >= 0 and sx <= vsx and sy >= 0 and sy <= vsy or false
end

-- OVERLAY
-- A callout pointing at the shot, with what each side has killed on screen since the last cut, and
-- markings on the ground: a ring for a scene, an arrow for a move.
-- A wide shot gets a board instead, with what each side's units are worth.

-- A unit dying with no attacker is credited to whoever hit it this recently
overlay.creditFrames = 20 * framesPerSecond
-- Text size and arrow width, the first for a 1080 high view
overlay.textSize, overlay.arrowWidth = 16, 36
-- How opaque the pointer and a scene's ring are
overlay.lineAlpha = 0.8
-- The callout follows a fight rather than each pick in it: a pick close to where the camera is,
-- within fightWindow of the callout going up, joins it instead of replacing it, unless one of its
-- units costs fightBreakMetal or more (see overlay.show)
overlay.fightWindow, overlay.fightBreakMetal = 8 * framesPerSecond, 750

-- A player and their side, in the player's colour
function overlay.player(teamID)
	local info = teamInfo[teamID]
	return overlay.coloured(info.name .. " (" .. info.allyTeamName .. ")", info.color)
end

-- Text in a team's colour (colour code bytes can't be 0)
function overlay.coloured(text, color)
	return string.char(255, max(1, color[1] * 255), max(1, color[2] * 255), max(1, color[3] * 255)) .. text .. "\008"
end

function overlay.metal(amount)
	amount = floor(amount / 10 + 0.5) * 10
	return amount < 1000 and tostring(amount) or string.format("%d,%03d", floor(amount / 1000), amount % 1000)
end

-- The tally counts what the viewer could have seen die: on screen, in a close shot. A cut or a wide
-- shot starts it again, as the viewer sees those as a new scene; a pan carries on.
function overlay.addDeath(allyTeam, location, metal)
	if not display.isWide and onScreen(location) then
		overlay.tally[allyTeam] = (overlay.tally[allyTeam] or 0) + metal
	end
end

-- Put the callout up for a pick: its own headline, units and colour
function overlay.start(event)
	local side, actor = event.meta and event.meta.side, next(event.actors)
	overlay.event, overlay.fight, overlay.since, overlay.anchor = event, nil, gameFrame, { event.location[1], event.location[3] }
	-- The event drops units that are given new orders, the overlay keeps pointing at them
	overlay.headline, overlay.subjects = event.commentary, {}
	for unitID, location in pairs(event._sbjUnits) do
		overlay.subjects[unitID] = { unpack(location) }
	end
	overlay.total, overlay.killed = event:subjectCount(), 0
	overlay.left, overlay.closing = nil, nil
	local isOrder = event.type == moveEventType or event.type == attackEventType
	overlay.arrowFrom = isOrder and event.meta.origin
	overlay.arrowTo = isOrder and { event.location[1], event.location[3] }
	overlay.color = side and overlay.allyColor[side] or actor and teamInfo[actor].color or { 1, 1, 1 }
	overlay.update()
	if DEBUG then
		spEcho(string.format('rc-callout,start,%d,%s,%s', event.id, event.type, overlay.headline or ''))
	end
end

-- Add the sides an event involves to the set sides: who did it and whose units it is about
function overlay.sidesOf(event, sides)
	for actor in pairs(event.actors) do
		if teamInfo[actor] then
			sides[teamInfo[actor].allyTeam] = true
		end
	end
	for unitID in pairs(event._sbjUnits) do
		local team = spGetUnitTeam(unitID)
		if team and teamInfo[team] then
			sides[teamInfo[team].allyTeam] = true
		end
	end
end

-- A headline for a fight between sides, as each side's name in its colour
function overlay.fightHeadline(sides)
	local list, names = {}, {}
	for allyTeam in pairs(sides) do
		if overlay.allyColor[allyTeam] and scenes.names[allyTeam] then
			list[#list + 1] = allyTeam
		end
	end
	table.sort(list)
	for i, allyTeam in ipairs(list) do
		names[i] = overlay.coloured(scenes.names[allyTeam], overlay.allyColor[allyTeam])
	end
	if #names >= 2 then
		return "Fight: " .. table.concat(names, " vs ")
	end
	return names[1] and names[1] .. " under fire" or "Fighting"
end

-- The camera has a new pick. A minor one where the callout already is joins it rather than
-- replacing it: reading "Thug damaged", "Picket damaged", "Picket destroyed" over a few seconds is
-- noise. Near a scene, the scene's callout, which is about the fight already, stays for a while.
-- Otherwise, close to where the callout went up and soon after, the callout speaks of the fight
-- instead. Anything else puts the callout up afresh.
function overlay.show(event)
	local current = overlay.event
	-- A scene is about the fight too, so one where a fight or scene is already up adds nothing new
	local fightUp = current and (overlay.fight or current.type == sceneEventType)
	local minor = current and overlay.headline and not display.isWide
		and event.type ~= lullEventType and (event.type ~= sceneEventType or fightUp)
		and event.type ~= unitDestroyerEventType and event.type ~= unitTakenEventType
		-- A costly unit lost is news; one hit, such as a commander, is part of the fight
		and (event.type ~= unitDestroyedEventType or (event.metal or 0) < overlay.fightBreakMetal)
	if not minor then
		overlay.start(event)
		return
	end
	local x, z, age = event.location[1], event.location[3], gameFrame - overlay.since
	local inScene = current.type == sceneEventType and not overlay.fight and age < 2 * overlay.fightWindow
		and length(x - current.location[1], z - current.location[3]) <= keepTrackingRange
	-- A scene has said there is a fight here, so that holds for longer
	local window = current.type == sceneEventType and 2 * overlay.fightWindow or overlay.fightWindow
	local inFight = (overlay.fight or age < window)
		and length(x - overlay.anchor[1], z - overlay.anchor[2]) <= keepTrackingRange
	if not inScene and not inFight then
		overlay.start(event)
		return
	end
	for unitID, location in pairs(event._sbjUnits) do
		overlay.subjects[unitID] = overlay.subjects[unitID] or { unpack(location) }
	end
	if inScene then
		if DEBUG then
			spEcho(string.format('rc-callout,scene,%d,%s,%s', event.id, event.type, overlay.headline))
		end
		return
	end
	if not overlay.fight then
		overlay.fight = {}
		overlay.sidesOf(current, overlay.fight)
		overlay.arrowFrom, overlay.arrowTo = nil, nil
		overlay.color = { 0.85, 0.85, 0.85 }
	end
	overlay.sidesOf(event, overlay.fight)
	overlay.headline = overlay.fightHeadline(overlay.fight)
	overlay.update()
	if DEBUG then
		spEcho(string.format('rc-callout,fight,%d,%s,%s', event.id, event.type, overlay.headline))
	end
end

-- Once a second: word the detail line
function overlay.update()

	local event, detail = overlay.event, nil
	if overlay.fight then
		local x, _, z = unpack(display.location)
		local stake = scenes.metalStake and scenes.around(scenes.metalStake, x, z)
		-- Next to nothing at stake reads oddly for a fight
		detail = stake and stake >= 100 and overlay.metal(stake) .. " metal at stake"
	elseif event and event.type == sceneEventType then
		detail = event.shownStake and overlay.metal(event.shownStake) .. " metal at stake"
	elseif event and event.type == buildingEventType then
		local unitID = next(event._sbjUnits)
		local unitDefID = unitID and spGetUnitDefID(unitID)
		if unitDefID then
			local _, _, _, _, buildProgress = spGetUnitHealth(unitID)
			detail = string.format("%d%% of %s metal", floor((buildProgress or 0) * 100), overlay.metal(UnitDefs[unitDefID].metalCost))
		end
	end
	overlay.detail = detail

	-- What each side's units are worth, part-built ones as far as they have got, for the wide shot.
	-- Zero-K's end game graphs keep these per team.
	local worth = {}
	for teamID, info in pairs(teamInfo) do
		local value = spGetTeamRulesParam(teamID, "stats_history_unit_value_current")
		if value and overlay.allyColor[info.allyTeam] then
			value = value + (spGetTeamRulesParam(teamID, "stats_history_nano_partial_current") or 0)
			worth[info.allyTeam] = (worth[info.allyTeam] or 0) + value
		end
	end
	overlay.worth = worth

	-- How fast a move is closing on its target, for the time to arrive
	local x, _, z = overlay.centre()
	local left = overlay.arrowTo and x and event.type == moveEventType and length(overlay.arrowTo[1] - x, overlay.arrowTo[2] - z)
	if left and overlay.left then
		overlay.closing = ((overlay.closing or overlay.left - left) + overlay.left - left) / 2
	end
	overlay.left = left
end

-- The middle of the units the headline names, and the top speed (elmos/s) of the slowest. A dead
-- unit stays where it was last seen.
function overlay.centre()
	local xSum, ySum, zSum, n, speed = 0, 0, 0, 0, huge
	for unitID, location in pairs(overlay.subjects) do
		local x, y, z = spGetUnitPosition(unitID)
		if x then
			location[1], location[2], location[3] = x, y, z
			speed = min(speed, UnitDefs[spGetUnitDefID(unitID)].speed)
		end
		xSum, ySum, zSum, n = xSum + location[1], ySum + location[2], zSum + location[3], n + 1
	end
	if n > 0 then
		return xSum / n, ySum / n, zSum / n, speed
	end
end

-- Where n points round a ring on the ground are on screen, or as project (see overlay.projector)
-- puts them. Like the drawn ring, each follows the ground under it.
function overlay.ring(x, z, radius, n, project)
	project = project or spWorldToScreenCoords
	local points = {}
	for i = 1, n do
		local angle = i * 2 * pi / n
		local px, pz = x + radius * sin(angle), z + radius * cos(angle)
		points[i] = { project(px, spGetGroundHeight(px, pz), pz) }
	end
	return points
end

-- A function giving where a world point is on screen for a camera pose { look, dist, pitch, yaw }
-- of the rig in updateCamera, like spWorldToScreenCoords does for the camera as it is
function overlay.projector(pose, vsx, vsy)
	local cp, sp, cy, sy = cos(pose.pitch), sin(pose.pitch), cos(pose.yaw), sin(pose.yaw)
	-- Ahead, right (level) and up for the camera
	local fx, fy, fz = cp * sy, sp, cp * cy
	local rx, rz = -cy, sy
	local ux, uy, uz = -rz * fy, rz * fx - rx * fz, rx * fy
	local look, dist = pose.look, pose.dist
	local px, py, pz = look[1] - dist * fx, look[2] - dist * fy, look[3] - dist * fz
	local focal = vsy / 2 / tan(rad(defaultFov) / 2)
	return function(x, y, z)
		local dx, dy, dz = x - px, y - py, z - pz
		local depth = max(1, dx * fx + dy * fy + dz * fz)
		return vsx / 2 + focal * (dx * rx + dz * rz) / depth, vsy / 2 + focal * (dx * ux + dy * uy + dz * uz) / depth
	end
end

-- A flat arrow on the ground from one point to another
function overlay.arrow(x1, z1, x2, z2, color)
	local dx, dz = x2 - x1, z2 - z1
	local len, width = length(dx, dz), overlay.arrowWidth
	local head = min(width * 3, len * 0.4)
	if len < width then
		return
	end
	dx, dz = dx / len, dz / len
	local function vertex(along, across)
		local x, z = x1 + dx * along - dz * across, z1 + dz * along + dx * across
		gl.Vertex(x, max(0, spGetGroundHeight(x, z)) + 4, z)
	end
	-- One strip, so nothing overlaps: the stem, then out to the barbs and in to the tip
	gl.Color(color[1], color[2], color[3], 0.6)
	gl.BeginEnd(GL.TRIANGLE_STRIP, function()
		local steps = math.ceil((len - head) / 48)
		for i = 0, steps do
			vertex((len - head) * i / steps, width / 2)
			vertex((len - head) * i / steps, -width / 2)
		end
		local barb = min(width * 1.4, head * 0.5)
		vertex(len - head, barb)
		vertex(len - head, -barb)
		vertex(len, 0)
	end)
end

-- The shown units were given a new order: the arrow follows at once, the camera stays with the shot
function overlay.redirect(unitID, params)
	local target = #params == 1 and unitInfo:get(params[1]) or #params >= 3 and params
	local x, _, z = spGetUnitPosition(unitID)
	-- Small moves are mostly unit AI
	if target and x and length(target[1] - x, target[3] - z) >= 256 then
		overlay.arrowFrom, overlay.arrowTo = { x, z }, { target[1], target[3] }
		overlay.left, overlay.closing = nil, nil
	end
end

-- How a unit is being hurt, from what is known: "under attack by Rogue of Player", or with no one
-- to blame, "burning" or on its own
function overlay.blame(destroyed, burning, unitName, player)
	local by = unitName and player and unitName .. " of " .. player or unitName or player
	if by then
		return (destroyed and " destroyed by " or " under attack by ") .. by
	end
	return burning and (destroyed and " destroyed by fire" or " burning") or (destroyed and " destroyed" or " under attack")
end

-- A unit the headline says is under attack has died: say so
function overlay.kill(unitID, name, destroyerName, attackerTeam, burning)
	local event = overlay.event
	if overlay.fight or not event or event.type ~= unitDamagedEventType or not overlay.subjects[unitID] then
		return
	end
	overlay.killed = overlay.killed + 1
	local killed, total = overlay.killed, overlay.total
	local subject = killed < total and killed .. " of " .. total .. " " .. name .. "s" or total > 1 and total .. " " .. name .. "s" or name
	overlay.headline = subject .. overlay.blame(true, burning, destroyerName, attackerTeam and overlay.player(attackerTeam))
end

function overlay.drawWorld()
	local event = overlay.event
	if not event or not options.show_commentary.value then
		return
	end
	local color = overlay.color
	gl.DepthTest(true)
	gl.LineWidth(3)
	local from, to = overlay.arrowFrom, overlay.arrowTo
	if from then
		overlay.arrow(from[1], from[2], to[1], to[2], color)
	elseif event.type == sceneEventType and not overlay.fight then
		local x, y, z = unpack(event.location)
		gl.Color(color[1], color[2], color[3], overlay.lineAlpha)
		gl.DrawGroundCircle(x, y, z, scenes.radius, 48)
	end
	gl.DepthTest(false)
	gl.LineWidth(1)
	gl.Color(1, 1, 1, 1)
end

-- The game's own windows on screen, as { left, bottom, right, top }, so callouts can keep off them
function overlay.scanUI(vsx, vsy)
	local windows = {}
	-- Other widgets' windows can go away under us
	pcall(function()
		for _, window in ipairs(WG.Chili.Screen0.children) do
			local x, y, w, h = window.x, window.y, window.width, window.height
			-- Not the invisible full screen holders
			if w > 20 and h > 20 and w * h < vsx * vsy * 0.4 then
				windows[#windows + 1] = { x, vsy - y - h, x + w, vsy - y }
			end
		end
	end)
	return windows
end

-- How far the subject at (ax, ay) is out from the corner of a w by h callout at (bx, by) that the
-- pointer leaves from (see overlay.draw), across and up or down. Either is negative when the
-- pointer goes back across the callout.
function overlay.pointerOut(bx, by, w, h, ax, ay)
	local onLeft, below = bx + w / 2 < ax, by + h / 2 < ay
	return onLeft and ax - bx - w or bx - ax, below and ay - by - h or by - ay
end

-- Where to put a w by h callout for a subject at world point world, now at (ax, ay) on screen,
-- clear of a scene's ring round it if ringed. It is looked at again for each shot and once a second
-- after that, and only moves when it is in the way or for a clear gain: a new shot keeps it where
-- it is on screen if that will do.
function overlay.place(world, ax, ay, w, h, vsx, vsy, ringed)
	local reach, margin = vsy * 0.06, vsy * 0.02
	local xMax, yMax = max(10, vsx - w - 10), max(10, vsy - h - 10)
	local fresh = overlay.placedFor ~= overlay.event
	local box, offset = overlay.box, overlay.offset
	fresh = fresh or not box
	-- A place off units is kept as which side of them the callout's nearest corner is on, each way,
	-- and how far out that corner is: { sx, dx, sy, dy }, so that the callout grows away from them.
	-- A scene's ring grows and shrinks on screen as the camera follows its units, so for a scene
	-- that corner is kept as a share of how far the ring reaches across and up from its middle,
	-- { sx, fx, sy, fy, ring = true }, and the callout keeps its place round the ring. These turn
	-- either into the offset of the callout's lower left from a subject at (ax, ay), and back.
	local function toOffset(place, across, up)
		if place.ring then
			local cx, cy = place[2] * across, place[4] * up
			return place[1] > 0 and cx or cx - w, place[3] > 0 and cy or cy - h
		end
		return place[1] > 0 and place[2] or -place[2] - w, place[3] > 0 and place[4] or -place[4] - h
	end
	local function fromOffset(ox, oy, across, up)
		local sx, sy = ox + w / 2 < 0 and -1 or 1, oy + h / 2 < 0 and -1 or 1
		if ringed then
			return { sx, (sx > 0 and ox or ox + w) / across, sy, (sy > 0 and oy or oy + h) / up, ring = true }
		end
		return { sx, sx > 0 and ox or -ox - w, sy, sy > 0 and oy or -oy - h }
	end
	-- How far a ring reaches across and up from its middle at (ax, ay)
	local function extent(points, ax, ay)
		local across, up = 1, 1
		for _, point in ipairs(points) do
			across, up = max(across, math.abs(point[1] - ax)), max(up, math.abs(point[2] - ay))
		end
		return across, up
	end
	local nowAcross, nowUp = 0, 0
	if ringed then
		nowAcross, nowUp = extent(ringed, ax, ay)
	end
	-- Where the callout is drawn grows the same way
	if box and (box.w ~= w or box.h ~= h) then
		local left, below = box[1] + box.w / 2 < ax, box[2] + box.h / 2 < ay
		box[1], box[2] = box[1] - (left and w - box.w or 0), box[2] - (below and h - box.h or 0)
		box.w, box.h = w, h
	end
	-- Judge it all from where things will be on screen once the camera has settled on its shot,
	-- so that a pan or turn under way doesn't decide it. Meanwhile it keeps its place off the
	-- subject.
	local project = camera.settled and overlay.projector(camera.settled, vsx, vsy) or spWorldToScreenCoords
	local sax, say = project(world[1], world[2], world[3])
	-- That is a guess, and a scene's shot changes as its units move, so it is looked at again,
	-- as readily as for a new shot, once the camera gets there
	if fresh then
		overlay.arrivedFor = nil
	end
	local arriving = false
	if overlay.arrivedFor ~= overlay.event and length(sax - ax, say - ay) < vsy * 0.03 then
		overlay.arrivedFor, arriving = overlay.event, not fresh
	end
	if fresh or arriving or gameFrame - overlay.placedFrame >= framesPerSecond then
		overlay.placedFor, overlay.placedFrame = overlay.event, gameFrame
		if not overlay.uiFrame or gameFrame - overlay.uiFrame >= 3 * framesPerSecond then
			overlay.ui, overlay.uiFrame = overlay.scanUI(vsx, vsy), gameFrame
		end

		-- Where it is off the subject; for a new shot, off the new subject from where it is on screen
		local current = fresh and box and fromOffset(box[1] - ax, box[2] - ay, nowAcross, nowUp) or offset
		local ax, ay = sax, say
		-- Things worth not covering: the units in shot, the move arrow and a scene's ring
		local points, across, up = {}, 0, 0
		if ringed then
			points = overlay.ring(world[1], world[3], scenes.radius, 8, project)
			across, up = extent(points, ax, ay)
		end
		local function avoid(x, z)
			points[#points + 1] = { project(x, spGetGroundHeight(x, z), z) }
		end
		local trackInfo = display.tracking.head
		while trackInfo do
			avoid(trackInfo.location[1], trackInfo.location[3])
			trackInfo = trackInfo.prev
		end
		local from, to = overlay.arrowFrom, overlay.arrowTo
		for i = 0, from and 6 or -1 do
			avoid(from[1] + (to[1] - from[1]) * i / 6, from[2] + (to[2] - from[2]) * i / 6)
		end
		-- Everything else on screen counts for less, by how much of it is covered. What moves counts
		-- for less than buildings, as it moves on; and something big on screen, like a factory, for
		-- more again. What will be on screen, that is: mid-pan, what is there now is mostly not.
		local others, unit = {}, vsy * 0.02
		local pose, around = camera.settled, nil
		if pose then
			around = spGetUnitsInCylinder(pose.look[1], pose.look[3], pose.dist * 2)
		end
		for _, unitID in ipairs(around or spGetVisibleUnits() or {}) do
			local x, y, z = spGetUnitPosition(unitID)
			local unitDefID = spGetUnitDefID(unitID)
			if x and unitDefID then
				local _, isStatic, weaponImportance = unitInfo:_unitStats(unitDefID)
				local px, py = project(x, y, z)
				local unitDef = UnitDefs[unitDefID]
				-- A building's footprint can be wider than its radius
				local rx, ry = project(x + max(unitDef.radius or 20, (unitDef.xsize or 0) * 4), y, z)
				local r = max(4, length(rx - px, ry - py))
				if px > -r and px < vsx + r and py > -r and py < vsy + r then
					local weight = (not isStatic or (weaponImportance or 0) > 0) and 0.5 or 0.6
					others[#others + 1] = { px, py, r, weight * bound((r / unit) ^ 2, 1, 4) }
				end
			end
		end
		-- Which way the rest of the action lies from the subject
		local tx, ty = 0, 0
		for _, point in ipairs(points) do
			tx, ty = tx + point[1] - ax, ty + point[2] - ay
		end
		local toward = max(1, length(tx, ty))

		-- What putting the callout's corner at (ox, oy) from the subject costs, once kept on screen.
		-- Worst is landing on the subject or in its ring, then on the game's own windows, then
		-- covering things, a pointer that reads badly, a long pointer and being on the side the action
		-- is. Also returns whether it is one of the first two.
		local function cost(ox, oy)
			local bx, by = bound(ax + ox, 10, xMax), bound(ay + oy, 10, yMax)
			local nx, ny = bound(ax, bx, bx + w) - ax, bound(ay, by, by + h) - ay
			-- Being in the way is judged with some room to spare, so that a spot chosen isn't then in the
			-- way a second later: in the room costs a little, and it only counts as in the way once it
			-- is well inside the ring or over the window itself.
			local onSubject, near = nx == 0 and ny == 0, false
			if across > 0 then
				local function inRing(room)
					return (nx / (across + room)) ^ 2 + (ny / (up + room)) ^ 2 < 1
				end
				-- A ring grows, shrinks and moves as the camera follows its scene, so the room grows with
				-- it. A ring is only a line, so a callout is only in the way well inside it.
				onSubject, near = inRing(-reach), inRing(reach + 0.15 * max(across, up))
			end
			-- The pointer leaves the corner nearest the subject (see overlay.draw). It reads best going
			-- out from there on a diagonal; along an edge, or back across the callout, it looks wrong.
			local ux, uy = overlay.pointerOut(bx, by, w, h, ax, ay)
			-- Short pointers are cheap; past about a fifth of the screen, much less so. A ring's
			-- pointer aims at its middle and stops at the ring, so only the part outside counts.
			local seen = length(nx, ny)
			if across > 0 then
				local d = length(ux, uy)
				local e = length(ux / across, uy / max(1, up))
				seen = e > 1 and d * (1 - 1 / e) or 0
			end
			local long = seen / vsy
			local total, blocked = (onSubject and 50 or near and 3 or 0) + 3 * long + 10 * max(0, long - 0.2), onSubject
			if ux <= 0 or uy <= 0 then
				total = total + 2
			else
				total = total + 1.5 * max(0, math.abs(atan2(uy, ux) - pi / 4) - pi / 12) / (pi / 6)
			end
			-- A scene's middle wanders on screen as the camera follows its units, so keep well clear
			local room = reach * 1.5
			for _, window in ipairs(overlay.ui) do
				if bx < window[3] and bx + w > window[1] and by < window[4] and by + h > window[2] then
					total, blocked = total + 20, true
				elseif bx < window[3] + room and bx + w > window[1] - room and by < window[4] + room and by + h > window[2] - room then
					total = total + 3
				end
			end
			local covered = 0
			for _, other in ipairs(others) do
				local x, y, r = other[1], other[2], other[3]
				local cw = min(x + r, bx + w + margin) - max(x - r, bx - margin)
				local ch = min(y + r, by + h + margin) - max(y - r, by - margin)
				if cw > 0 and ch > 0 then
					covered = covered + other[4] * min(1, cw * ch / (4 * r * r))
				end
			end
			-- A crowd is still better covered than a window
			total = total + min(covered, 10)
			for _, point in ipairs(points) do
				if point[1] > bx - margin and point[1] < bx + w + margin and point[2] > by - margin and point[2] < by + h + margin then
					total = total + 1
				end
			end
			local cx, cy = bx + w / 2 - ax, by + h / 2 - ay
			return total + 0.8 * (cx * tx + cy * ty) / toward / max(1, length(cx, cy)), blocked
		end

		local best, bestCost, curX, curY = nil, nil, nil, nil
		if current then
			curX, curY = toOffset(current, across, up)
		end
		local function try(ox, oy)
			-- Other things being nearly equal, the side it is already on
			local sameSide = curX and (ox + w / 2 < 0) == (curX + w / 2 < 0) and (oy + h / 2 < 0) == (curY + h / 2 < 0)
			local total = cost(ox, oy) - (sameSide and 0.5 or 0)
			if not best or total < bestCost then
				best, bestCost = fromOffset(ox, oy, across, up), total
			end
		end
		-- Out on each diagonal: close by first, then further for when the fight is all around the
		-- subject, and flatter or steeper to fit the space
		for _, far in ipairs({ 1, 2, 3, 4.5 }) do
			local out = (across > 0 and reach * 1.6 or reach) * far
			for sx = 1, -1, -2 do
				for sy = 1, -1, -2 do
					for _, k in ipairs({ 1, 1.6, 1 / 1.6 }) do
						-- 3/4 of the way out each way clears a ring
						local dx, dy = out * k + across * 0.75, out / k + up * 0.75
						try(sx > 0 and dx or -dx - w, sy > 0 and dy or -dy - h)
					end
					if across > 0 and far == 1 then
						-- Round the ring, with the corner nearest its middle just outside it
						for i = 0, 15 do
							local c, s = cos(i * pi / 8), sin(i * pi / 8)
							if (c >= 0) == (sx > 0) and (s >= 0) == (sy > 0) then
								for _, f in ipairs({ 1.5, 3 }) do
									local px, py = (across + reach * f) * c, (up + reach * f) * s
									try(sx > 0 and px or px - w, sy > 0 and py or py - h)
								end
							end
						end
						-- When a ring leaves no room around it: in from a corner of the screen, as far
						-- as stays clear
						local cx, cy, t = (sx > 0 and xMax or 10) - ax, (sy > 0 and yMax or 10) - ay, 0
						while t < 0.9 and not select(2, cost(cx - (cx + w / 2) * (t + 0.1), cy - (cy + h / 2) * (t + 0.1))) do
							t = t + 0.1
						end
						try(cx - (cx + w / 2) * t, cy - (cy + h / 2) * t)
					end
				end
			end
		end
		-- Stay unless in the way or somewhere else is clearly better. A move glides there.
		local currentCost, blocked = huge, true
		if current then
			currentCost, blocked = cost(curX, curY)
		end
		if blocked or currentCost >= bestCost + ((fresh or arriving) and 2 or 4) then
			overlay.offset, overlay.settling = best, true
			if DEBUG then
				local pose = camera.settled or {}
				local bx, by = toOffset(best, across, up)
				spEcho(string.format('rc-place,%s,%.0f,%.0f,%.1f,%.1f,%s,%.0f,%.0f,%.0f,%.0f,%.0f,%.2f', fresh and 'fresh' or arriving and 'arrived' or 'better',
					bx, by, min(currentCost, 999), bestCost, blocked and 'blocked' or '', ax, ay,
					across, up, pose.dist or 0, pose.yaw or 0))
			end
		elseif fresh then
			overlay.offset = current
		end
	end

	-- The callout floats: it stays where it is on screen while within some slack of its place off
	-- the subject, so the pointer swings and stretches as units and the camera move, and is drawn
	-- back in beyond that. After a move it settles all the way, and it is never left on the subject
	-- or with its pointer going back across it.
	local ox, oy = toOffset(overlay.offset, nowAcross, nowUp)
	local tx, ty = bound(ax + ox, 10, xMax), bound(ay + oy, 10, yMax)
	if not box then
		box = { tx, ty, 0, w = w, h = h, v = { 0, 0, 0 } }
		overlay.settling = false
	else
		local slack = overlay.settling and 0 or vsy * 0.1
		local ux, uy = overlay.pointerOut(box[1], box[2], w, h, ax, ay)
		if ux < margin or uy < margin then
			slack = 0
		end
		local dx, dy = tx - box[1], ty - box[2]
		local d = length(dx, dy)
		local f = d > slack and 1 - slack / d or 0
		smoothDampVec(box, { box[1] + dx * f, box[2] + dy * f, 0 }, box.v, 0.3, overlay.dt or 1 / 30, vsy * 3)
		overlay.settling = overlay.settling and d > 2
	end
	box[1], box[2] = bound(box[1], 10, xMax), bound(box[2], 10, yMax)
	overlay.box = box
	return box[1], box[2]
end

-- On a wide shot, a board at the top of the screen with what each side's units are worth in metal.
-- Two sides face each other across it with a bar split the same way, like the tally; more are
-- listed a row each.
function overlay.drawWorth(vsx, vsy, size)
	local worth, sides = overlay.worth or {}, {}
	for allyTeam in pairs(worth) do
		sides[#sides + 1] = allyTeam
	end
	if #sides == 0 then
		return
	end
	table.sort(sides)
	local pad, row, small = size * 0.6, size * 1.5, size * 0.85
	local title, paired = "Metal value", #sides == 2
	local w, nameW, valueW = gl.GetTextWidth(title) * size, 0, 0
	for _, allyTeam in ipairs(sides) do
		nameW = max(nameW, gl.GetTextWidth(scenes.names[allyTeam]) * small)
		valueW = max(valueW, gl.GetTextWidth(overlay.metal(worth[allyTeam])) * small)
	end
	if paired then
		-- Each side's name and value, either side of the middle
		w = max(w, (nameW + valueW + size) * 2)
	else
		w = max(w, nameW + valueW + size * 2)
	end
	w = w + pad * 2
	local h = row * (1 + (paired and 1 or #sides)) + pad + (paired and pad or 0)

	-- Top centre, below any of the game's windows in the way
	if not overlay.uiFrame or gameFrame - overlay.uiFrame >= 3 * framesPerSecond then
		overlay.ui, overlay.uiFrame = overlay.scanUI(vsx, vsy), gameFrame
	end
	local bx, by = (vsx - w) / 2, vsy - h - 10
	local moved = true
	while moved and by > 10 do
		moved = false
		for _, window in ipairs(overlay.ui) do
			if bx < window[3] and bx + w > window[1] and by < window[4] and by + h > window[2] then
				by, moved = window[2] - h - 10, true
			end
		end
	end

	gl.Color(0, 0, 0, 0.55)
	gl.Rect(bx, by, bx + w, by + h)
	gl.Color(1, 1, 1, 1)
	local ty = by + h - pad * 0.5 - size
	gl.Text(title, bx + w / 2, ty, size, "oc")
	if paired then
		local a, b = sides[1], sides[2]
		ty = ty - row
		gl.Text(overlay.coloured(scenes.names[a] .. " " .. overlay.metal(worth[a]), overlay.allyColor[a]), bx + pad, ty, small, "o")
		gl.Text(overlay.coloured(overlay.metal(worth[b]) .. " " .. scenes.names[b], overlay.allyColor[b]), bx + w - pad, ty, small, "or")
		local total = worth[a] + worth[b]
		local split = bx + pad + (w - pad * 2) * (total > 0 and worth[a] / total or 0.5)
		local ca, cb = overlay.allyColor[a], overlay.allyColor[b]
		gl.Color(ca[1], ca[2], ca[3], 0.9)
		gl.Rect(bx + pad, ty - pad, split, ty - pad * 0.4)
		gl.Color(cb[1], cb[2], cb[3], 0.9)
		gl.Rect(split, ty - pad, bx + w - pad, ty - pad * 0.4)
	else
		for _, allyTeam in ipairs(sides) do
			ty = ty - row
			local color = overlay.allyColor[allyTeam]
			gl.Text(overlay.coloured(scenes.names[allyTeam], color), bx + pad, ty, small, "o")
			gl.Text(overlay.coloured(overlay.metal(worth[allyTeam]), color), bx + w - pad, ty, small, "or")
		end
	end
	gl.Color(1, 1, 1, 1)
end

function overlay.draw()
	-- With no callout, the next one starts where it best fits
	local headline = overlay.headline
	if not overlay.event or not options.show_commentary.value or display.isWide or not headline then
		overlay.box = nil
	end
	if not overlay.event or not options.show_commentary.value then
		return
	end
	local vsx, vsy = spGetViewGeometry()
	local size = overlay.textSize * vsy / 1080
	if display.isWide then
		overlay.drawWorth(vsx, vsy, size)
		return
	end
	if not headline then
		return
	end
	local pad, row, color = size * 0.6, size * 1.5, overlay.color
	local detail, small = overlay.detail, size * 0.85
	-- The subject on screen: the units the headline names, or a scene and its ring
	-- or a fight, which is what the camera is framing
	local event, ring = overlay.event, nil
	local scene = event.type == sceneEventType and not overlay.fight
	local sx, sy, sz, speed = overlay.centre()
	if scene or overlay.fight or not sx then
		sx, sy, sz = unpack(scene and event.location or display.location)
		ring = scene and overlay.ring(sx, sz, scenes.radius, 24)
	end
	local ax, ay = spWorldToScreenCoords(sx, sy, sz)
	local across, up = 0, 0
	for _, point in ipairs(ring or {}) do
		across, up = max(across, math.abs(point[1] - ax)), max(up, math.abs(point[2] - ay))
	end
	if overlay.left and overlay.left > 50 and speed and speed < huge then
		-- At the speed they have been closing, or flat out until that is known
		speed = overlay.closing and overlay.closing > speed * 0.2 and overlay.closing or speed
		detail = string.format("arrives in %ds", math.ceil(length(overlay.arrowTo[1] - sx, overlay.arrowTo[2] - sz) / max(1, speed)))
	end

	-- The tally: what each side has killed, and a bar split the same way
	local tally, a, b, tallyRows = overlay.tally, nil, nil, 0
	if next(tally) then
		for allyTeam in pairs(overlay.allyColor) do
			a, b = a or allyTeam, a and allyTeam
			tallyRows = tallyRows + 1
		end
		tallyRows = tallyRows == 2 and 1 or 0
		if tallyRows == 1 and a > b then
			a, b = b, a
		end
		if tallyRows == 0 then
			-- More than two sides: list them
			local parts = {}
			for allyTeam, destroyed in pairs(tally) do
				parts[#parts + 1] = overlay.coloured(scenes.names[allyTeam] .. " " .. overlay.metal(destroyed), overlay.allyColor[allyTeam])
			end
			detail = (detail and detail .. "  |  " or "") .. "killed: " .. table.concat(parts, "  ")
		end
	end
	local left = tallyRows == 1 and overlay.coloured(scenes.names[a] .. " " .. overlay.metal(tally[a] or 0), overlay.allyColor[a])
	local right = tallyRows == 1 and overlay.coloured(overlay.metal(tally[b] or 0) .. " " .. scenes.names[b], overlay.allyColor[b])

	local w = gl.GetTextWidth(headline) * size
	if detail then
		w = max(w, gl.GetTextWidth(detail) * small)
	end
	if left then
		-- "killed" sits in the middle, between each side's count
		w = max(w, (max(gl.GetTextWidth(left), gl.GetTextWidth(right)) * 2 + gl.GetTextWidth("killed")) * small + size * 2)
	end
	w = w + pad * 2
	local h = row * (1 + (detail and 1 or 0) + tallyRows) + pad + tallyRows * pad

	local bx, by = overlay.place({ sx, sy, sz }, ax, ay, w, h, vsx, vsy, ring)

	gl.Color(0, 0, 0, 0.55)
	gl.Rect(bx, by, bx + w, by + h)
	-- The edge facing the subject is coloured, and the pointer runs out of the middle of its end to
	-- stop short of the units, or on the nearest part of the ring
	local t = max(2, size * 0.2)
	local onLeft, below = bx + w / 2 < ax, by + h / 2 < ay
	local ex, cy = onLeft and bx + w - t or bx, below and by + h or by
	local cx, my = ex + t / 2, below and cy - t / 2 or cy + t / 2
	local px, py, gap = ax, ay, size * 1.8
	if ring then
		-- Towards the middle of the ring, stopping where it first crosses it
		local dx, dy, first = ax - cx, ay - my, 1
		for i, p in ipairs(ring) do
			local q = ring[i % #ring + 1]
			local qx, qy = q[1] - p[1], q[2] - p[2]
			local denom = dx * qy - dy * qx
			if denom ~= 0 then
				local along = ((p[1] - cx) * qy - (p[2] - my) * qx) / denom
				local on = ((p[1] - cx) * dy - (p[2] - my) * dx) / denom
				if along >= 0 and on >= 0 and on <= 1 then
					first = min(first, along)
				end
			end
		end
		px, py, gap = cx + dx * first, my + dy * first, 0
	end
	local reach = length(px - cx, py - my)
	-- A little see-through, like the ring
	gl.Color(color[1], color[2], color[3], overlay.lineAlpha)
	gl.Rect(ex, by, ex + t, by + h)
	if reach > max(1, gap * 1.5) then
		-- Half the thickness, across the pointer
		local nx, ny = -(py - my) / reach * t / 2, (px - cx) / reach * t / 2
		px, py = px + (cx - px) * gap / reach, py + (my - py) * gap / reach
		gl.BeginEnd(GL.QUADS, function()
			gl.Vertex(cx + nx, my + ny)
			gl.Vertex(cx - nx, my - ny)
			gl.Vertex(px - nx, py - ny)
			gl.Vertex(px + nx, py + ny)
		end)
	end
	gl.Color(1, 1, 1, 1)

	local ty = by + h - pad * 0.5 - size
	gl.Text(headline, bx + pad, ty, size, "o")
	if detail then
		ty = ty - row
		gl.Text(detail, bx + pad, ty, small, "o")
	end
	if left then
		ty = ty - row
		gl.Text(left, bx + pad, ty, small, "o")
		gl.Text(right, bx + w - pad, ty, small, "or")
		gl.Color(0.75, 0.75, 0.75, 1)
		gl.Text("killed", bx + w / 2, ty, small, "oc")
		-- Each side's share of the bar is what it has killed
		local split = bx + pad + (w - pad * 2) * (tally[a] or 0) / ((tally[a] or 0) + (tally[b] or 0))
		local ca, cb = overlay.allyColor[a], overlay.allyColor[b]
		gl.Color(ca[1], ca[2], ca[3], 0.9)
		gl.Rect(bx + pad, ty - pad, split, ty - pad * 0.4)
		gl.Color(cb[1], cb[2], cb[3], 0.9)
		gl.Rect(split, ty - pad, bx + w - pad, ty - pad * 0.4)
	end
	gl.LineWidth(1)
	gl.Color(1, 1, 1, 1)
end

-- STATS LOGGING (see scripts/generate-stats.py)
-- Ground-truth lines are logged straight from callins, independently of event scoring,
-- so that different camera algorithms can be compared on the same replay.

local statsCellSize = 256
local statsDamage = {}
-- Fastest yaw seen since the last flush (rad/s), ignoring cuts
local statsMaxYawRate = 0

local function statsLogGame()
	local vsx, vsy = spGetViewGeometry()
	spEcho(string.format('rc-game,%s,%d,%d,%d,%d', Game.mapName, mapSizeX, mapSizeZ, vsx, vsy))
end

local function statsUnitValue(unitID, unitDefID)
	local unitDef = UnitDefs[unitDefID]
	if not unitDef or unitDef.customParams.dontcount then
		return
	end
	local _, maxHealth, _, _, buildProgress = spGetUnitHealth(unitID)
	return unitDef.metalCost * (buildProgress or 1), maxHealth, unitDef
end

local function statsLogDeath(unitID, unitDefID, unitTeam)
	local value, _, unitDef = statsUnitValue(unitID, unitDefID)
	local x, y, z = spGetUnitPosition(unitID)
	if not value or value <= 0 or not x then
		return
	end
	local allyTeam = teamInfo[unitTeam] and teamInfo[unitTeam].allyTeam or -1
	spEcho(string.format('rc-death,%s,%.0f,%.0f,%.0f,%.1f,%d', unitDef.name, x, y, z, value, allyTeam))
end

-- Damage is aggregated per cell and flushed once per update interval to keep the log small.
local function statsAddDamage(unitID, unitDefID, damage)
	local value, maxHealth = statsUnitValue(unitID, unitDefID)
	local x, _, z = spGetUnitPosition(unitID)
	if not value or not maxHealth or maxHealth <= 0 or not x then
		return
	end
	-- Metal-equivalent of the damage dealt
	value = value * min(damage, maxHealth) / maxHealth
	if value <= 0 then
		return
	end
	local key = floor(x / statsCellSize) * 4096 + floor(z / statsCellSize)
	local cell = statsDamage[key]
	if not cell then
		cell = { 0, 0, 0 }
		statsDamage[key] = cell
	end
	cell[1], cell[2], cell[3] = cell[1] + value, cell[2] + x * value, cell[3] + z * value
end

local function statsFlush(userOverride)
	for _, cell in pairs(statsDamage) do
		local value, wx, wz = unpack(cell)
		spEcho(string.format('rc-dmg,%.0f,%.0f,%.1f', wx / value, wz / value, value))
	end
	statsDamage = {}

	-- Ground footprint of the view from the four screen corners. TraceScreenRay only gives
	-- useful coordinates for ground hits, so otherwise intersect the pixel's ray with a plane
	-- at the ground height in the middle of the view, capped at the map diagonal.
	local vsx, vsy = spGetViewGeometry()
	local cx, cy, cz = spGetCameraPosition()
	local _, mid = spTraceScreenRay(floor(vsx / 2), floor(vsy / 2), true, false, false)
	local planeY = mid and mid[2] or spGetGroundHeight(cx, cz)
	local maxDist = length(mapSizeX, mapSizeZ)
	local corners = {}
	for _, c in ipairs({ { 0, 0 }, { vsx - 1, 0 }, { vsx - 1, vsy - 1 }, { 0, vsy - 1 } }) do
		local hitType, pos = spTraceScreenRay(c[1], c[2], true, false, false)
		local x, z
		if hitType == 'ground' and pos then
			x, z = pos[1], pos[3]
		else
			-- GetPixelDir takes y from the top of the screen
			local dx, dy, dz = spGetPixelDir(c[1], vsy - 1 - c[2])
			local t = (dy < -1e-3) and (planeY - cy) / dy or huge
			local hd = length(dx, 0, dz)
			if t * hd > maxDist then
				t = hd > 0 and maxDist / hd or 0
			end
			x, z = cx + dx * t, cz + dz * t
		end
		corners[#corners + 1] = string.format('%.0f,%.0f', x, z)
	end
	spEcho(string.format('rc-cam,%.0f,%.0f,%.0f,%s,%d,%s,%d,%s,%.3f,%.1f',
		cx, cy, cz, display.camType or 'nil',
		shownEvent and shownEvent.id or -1, shownEvent and shownEvent.type or 'nil',
		userOverride and 1 or 0, table.concat(corners, ','),
		camera and camera.ry or 0, deg(statsMaxYawRate)))
	statsMaxYawRate = 0
	-- The shot took in a nearby scene in the last second
	local aside = display.aside
	if display.asideFrame and gameFrame - display.asideFrame < updateIntervalFrames then
		spEcho(string.format('rc-aside,%.0f,%.0f', aside[1], aside[2]))
	end
end

local function statsTrackYaw(dt, oldRy, newRy, isCut)
	if isCut or dt <= 0 then
		return
	end
	local d = (newRy - oldRy + pi) % (2 * pi) - pi
	statsMaxYawRate = max(statsMaxYawRate, math.abs(d) / dt)
end

-- Marks the shot framed once its tracking box first sits in frame (and logs rc-framed).
local function checkFramed(xMin, zMin, xMax, zMax)
	if not shownEvent or display.framedId == shownEvent.id then
		return
	end
	local vsx, vsy = spGetViewGeometry()
	local cxw, czw = (xMin + xMax) / 2, (zMin + zMax) / 2
	local gy = spGetGroundHeight(cxw, czw)
	local sx, sy, sz = spWorldToScreenCoords(cxw, gy, czw)
	if not sx or sz < 0 or sz > 1
	    or math.abs(sx / vsx - 0.5) > framedCentre or math.abs(sy / vsy - 0.5) > framedCentre then
		return
	end
	for _, c in ipairs({ { xMin, zMin }, { xMin, zMax }, { xMax, zMin }, { xMax, zMax } }) do
		local px, py, pz = spWorldToScreenCoords(c[1], gy, c[2])
		if not px or pz < 0 or pz > 1 or px < 0 or px > vsx or py < 0 or py > vsy then
			return
		end
	end
	display.framedId, display.framedFrame = shownEvent.id, gameFrame
	if shownEvent == mie then
		-- Restart the pick's decay, so that travel doesn't eat into its screen time
		mie.started = gameFrame
	end
	if STATS then
		spEcho(string.format('rc-framed,%d,%s', shownEvent.id, shownEvent.type))
	end
end
local userInactiveSeconds, lastMouseLocation = 0, { -1, 0, -1 }

local function calcCamRange(diag, fov)
	return diag / 2 / tan(rad(fov / 2))
end

-- Seconds for the rig to pan its look-at point by distance d (see smoothDamp)
local function panSeconds(d)
	return 2 * lookSmoothTime + d / lookMaxSpeed
end

-- How costly it is to show a location, from where the camera is looking now rather than where it
-- is: 0 if no pan is needed, rising with the pan time, and 1 for a cut. Something already on screen
-- costs half as much, as it stays in view throughout the pan.
transitionCost = function(location)
	if not camera then
		return 1
	end
	local pan = panSeconds(distance(camera.look, location))
	if pan > maxPanSeconds then
		return 1
	end
	if onScreen(location) then
		pan = pan / 2
	end
	-- Even a tiny pan takes about the look-at smooth time, so measure from there
	return bound((pan - lookSmoothTime) / (maxPanSeconds - lookSmoothTime), 0, 1)
end

-- Look-at point and distance that fit ground points { x, z } (at height y) in view at this yaw and
-- pitch, with their projection spanning at most fill of the screen and centred on it. Perspective
-- makes the far side look smaller, so aiming at their middle would leave more space above than below.
local function frameBox(corners, y, yaw, pitch, fill)
	local cp, sp, cy, sy = cos(pitch), sin(pitch), cos(yaw), sin(yaw)
	local fx, fy, fz = sy * cp, sp, cy * cp
	local rx, rz = -cy, sy
	local ux, uy, uz = -sy * sp, cp, -cy * sp
	local vsx, vsy = spGetViewGeometry()
	local tanV = tan(rad(defaultFov / 2))
	local tanH = tanV * vsx / vsy

	-- Projected extents of the box from distance d back from look-at point (lx, lz)
	local function extents(lx, lz, d)
		local px, py, pz = lx - d * fx, y - d * fy, lz - d * fz
		local uMin, uMax, vMin, vMax = huge, -huge, huge, -huge
		for _, corner in ipairs(corners) do
			local dx, dy, dz = corner[1] - px, y - py, corner[2] - pz
			local depth = dx * fx + dy * fy + dz * fz
			if depth <= 1 then
				return nil
			end
			local u = (dx * rx + dz * rz) / (depth * tanH)
			local v = (dx * ux + dy * uy + dz * uz) / (depth * tanV)
			uMin, uMax, vMin, vMax = min(uMin, u), max(uMax, u), min(vMin, v), max(vMax, v)
		end
		return uMin, uMax, vMin, vMax
	end

	local lx, lz, d = 0, 0, 0
	for _, corner in ipairs(corners) do
		lx, lz = lx + corner[1] / #corners, lz + corner[2] / #corners
	end
	for _ = 1, 3 do
		-- Closest distance that fits (the projection shrinks with distance)
		local lo, hi = 1, length(mapSizeX, mapSizeZ) * 4
		for _ = 1, 24 do
			d = (lo + hi) / 2
			local uMin, uMax, vMin, vMax = extents(lx, lz, d)
			if uMin and uMax - uMin <= 2 * fill and vMax - vMin <= 2 * fill then
				hi = d
			else
				lo = d
			end
		end
		d = hi
		-- Shift the look-at point to centre the projection: sideways along the camera's right, and
		-- along the ground in the direction it faces
		local uMin, uMax, vMin, vMax = extents(lx, lz, d)
		local du, dv = (uMin + uMax) / 2, (vMin + vMax) / 2
		local side, ahead = du * d * tanH, dv * d * tanV / max(0.1, -sp)
		lx, lz = lx + side * rx + ahead * sy, lz + side * rz + ahead * cy
	end
	return lx, lz, d
end

-- Score the view the rig would have at this yaw (see orbitConfig.headingWeights). Returns the
-- total, and the score of the view alone without heading preferences.
local function scoreHeading(c, yaw)
	local lx, ly, lz = unpack(c.look)
	local cp, sp, cy, sy = cos(c.pitch), sin(c.pitch), cos(yaw), sin(yaw)
	-- Camera forward, right and up
	local fx, fy, fz = sy * cp, sp, cy * cp
	local rx, rz = -cy, sy
	local ux, uy, uz = -sy * sp, cp, -cy * sp
	local px, py, pz = lx - c.dist * fx, ly - c.dist * fy, lz - c.dist * fz
	local vsx, vsy = spGetViewGeometry()
	local tanV = tan(rad(c.fov / 2))
	local tanH = tanV * vsx / vsy

	-- Cast a grid of rays onto the plane of the look-at point
	local activity, offMap, n = 0, 0, 0
	for _, su in ipairs(orbitConfig.headingSamples) do
		for _, sv in ipairs(orbitConfig.headingSamples) do
			local dx = fx + rx * su * tanH + ux * sv * tanV
			local dy = fy + uy * sv * tanV
			local dz = fz + rz * su * tanH + uz * sv * tanV
			n = n + 1
			if dy >= -1e-3 then
				offMap = offMap + 1
			else
				local t = (ly - py) / dy
				local x, z = px + dx * t, pz + dz * t
				if x < 0 or x > mapSizeX or z < 0 or z > mapSizeZ then
					offMap = offMap + 1
				else
					activity = activity + log10(max(1, interestGrid:getActivity(x, z)))
				end
			end
		end
	end

	local occluded = 0
	for i = 1, 4 do
		local t = i / 5
		if spGetGroundHeight(px + (lx - px) * t, pz + (lz - pz) * t) > py + (ly - py) * t then
			occluded = occluded + 1
		end
	end

	local w = orbitConfig.headingWeights
	local view = w.activity * activity / n - w.offMap * offMap / n - w.occluded * occluded
	return view - w.turn * math.abs(wrapAngle(yaw - c.yaw)) / pi
		- w.north * math.abs(wrapAngle(yaw - defaultRy)) / (pi / 2), view
end

-- Once the shot is framed, maybe orbit to a better heading, or drift once on a long hold
local function planHeading(c)
	if not shownEvent or display.framedId ~= shownEvent.id
	    or gameFrame < display.framedFrame + orbitConfig.startFrames
	    or gameFrame < (c.planFrame or 0) + orbitConfig.planFrames
	    -- Let an orbit finish before replanning
	    or math.abs(wrapAngle(c.tyaw - c.yaw)) > 0.1 then
		return
	end
	c.planFrame = gameFrame

	local current, currentView = scoreHeading(c, c.tyaw)
	local best, bestScore, bestView, drift, driftScore, driftView = nil, -huge, nil, nil, -huge, nil
	for k = 0, floor(2 * pi / orbitConfig.candidateStep + 0.5) - 1 do
		local yaw = wrapAngle(defaultRy + k * orbitConfig.candidateStep)
		local score, view = scoreHeading(c, yaw)
		if score > bestScore then
			best, bestScore, bestView = yaw, score, view
		end
		if math.abs(wrapAngle(yaw - c.tyaw)) >= orbitConfig.driftMin and score > driftScore then
			drift, driftScore, driftView = yaw, score, view
		end
	end

	local target, reason, view
	if bestScore > current and bestView > currentView + orbitConfig.margin then
		target, reason, view = best, 'better', bestView
	elseif not c.orbited and gameFrame >= display.framedFrame + orbitConfig.driftFrames
	    and drift and driftScore >= current - orbitConfig.driftTolerance then
		target, reason, view = drift, 'drift', driftView
	end
	if target then
		c.tyaw = c.yaw + wrapAngle(target - c.yaw)
		c.yawSmooth, c.orbited = orbitConfig.smoothTime, true
		if STATS then
			-- Gain is the view score improvement (see orbitConfig.headingWeights), before heading preferences
			spEcho(string.format('rc-orbit,%d,%.0f,%.0f,%s,%.2f', shownEvent.id, deg(c.yaw), deg(target), reason, view - currentView))
		end
	end
end

local function initCamera(cx, cy, cz)
	local lx, lz = mapSizeX / 2, mapSizeZ / 2
	return {
		-- Rig state
		look = { lx, spGetGroundHeight(lx, lz), lz }, lookv = { 0, 0, 0 },
		dist = calcCamRange(camDiagMin, defaultFov), distv = 0,
		pitch = defaultRx, pitchv = 0,
		yaw = defaultRy, yawv = 0, tyaw = defaultRy,
		-- Pose last sent to the engine
		x = cx, y = cy, z = cz, rx = defaultRx, ry = defaultRy, fov = defaultFov,
		cutNext = true,
	}
end

local function __pluralize(noun, count)
	-- FIXME: Better logic!
	return (count > 1 and count .. ' ' .. noun .. "s") or noun
end

local function __getUnitsNameString(units)
	local unitNames = {}
	for unitID, _ in pairs(units) do
		if unitID >= 0 then
			local _, _, _, name = unitInfo:get(unitID)
			-- Sometimes it's too late to get a (dead) unit in the cache
			name = name or "unknown"
			unitNames[name] = (unitNames[name] and unitNames[name] + 1) or 1
		end
	end
	local result
	for unitName, count in pairs(unitNames) do
		result = (result and "squad") or __pluralize(unitName, count)
	end
	return result or "unknown"
end

-- Track the event's units, ahead of those already tracked or (fresh) in their place
local function trackEvent(event, fresh)
	if fresh then
		display.tracking:clear()
	end
	-- We use keepPrevious to keep runs of track infos from the same event
	local keepPrevious = false
	for k, v in pairs(event._sbjUnits) do
		display.tracking:add({ unitID = k, location = v, keepPrevious = keepPrevious })
		keepPrevious = true
	end
	for k, v in pairs(event._objUnits) do
		display.tracking:add({ unitID = k, location = v, keepPrevious = keepPrevious })
		keepPrevious = true
	end

	-- Remove duplicates from tracking
	local tracked, trackInfo = {}, display.tracking.head
	while trackInfo do
		if tracked[trackInfo.unitID] then
			trackInfo, _ = display.tracking:remove(trackInfo)
		else
			tracked[trackInfo.unitID] = true
			trackInfo = trackInfo.prev
		end
	end
end

local function updateDisplay(event)
	local camAngle, commentary, isWide, fill = defaultRx, nil, false, frameFill

	local actorName
	for actorID, _ in pairs(event.actors) do
		actorName = (actorName and "multiple") or overlay.player(actorID)
	end
	actorName = actorName or "unknown"

	local sbjUnitCount = event:subjectCount()
	local sbjString = __pluralize(event.sbjName, sbjUnitCount)

	if event.type == attackEventType then
		commentary = sbjString .. " attacking"
	elseif event.type == buildingEventType then
		commentary = actorName .. " making " .. sbjString
	elseif event.type == sceneEventType then
		commentary = event.meta.commentary
	elseif event.type == lullEventType then
		camAngle = lullConfig.pitch
		isWide, fill = true, lullConfig.fill
	elseif event.type == unitBuiltEventType then
		commentary = sbjString .. " built by " .. actorName
	elseif event.type == unitDamagedEventType then
		local attacker = next(event._objUnits) and __getUnitsNameString(event._objUnits)
		commentary = sbjString .. overlay.blame(false, not attacker and event.burning, attacker, next(event.actors) and actorName)
	elseif event.type == unitDestroyedEventType then
		local destroyer = __getUnitsNameString(event._objUnits)
		commentary = sbjString .. " destroyed by " .. destroyer .. " of " .. actorName
	elseif event.type == unitDestroyerEventType then
		commentary = sbjString .. " on a rampage"
	elseif event.type == moveEventType then
		commentary = sbjString .. " moving"
	elseif event.type == unitTakenEventType then
		commentary = sbjString .. " captured by " .. actorName
	end

	-- A wide shot's framing (placeholders at its corners) is no place to start from, or keep
	trackEvent(event, isWide or display.isWide)
	if isWide then
		overlay.tally = {}
	end
	-- Wide shots read like a map, so they keep north up and don't count as watching their centre
	display.camAngle, display.isWide, display.fill = camAngle, isWide, fill

	shownEvent = event
	event.commentary = commentary
	overlay.show(event)
	display.shotFrame = gameFrame
	if STATS then
		local x, _, z = unpack(event.location)
		spEcho(string.format('rc-shown,%d,%s,%.0f,%.0f,%s', event.id, event.type, x, z, display.camType))
	end

	return true
end

-- Whether the shown pick is still settling in or within its minimum hold (see minShotFrames)
local function shotLocked()
	if not shownEvent or shownEvent ~= mie then
		return false
	end
	if display.framedId == shownEvent.id then
		return gameFrame < display.framedFrame + minShotFrames
	end
	return gameFrame < display.shotFrame + maxShotLockFrames
end

function lull.addDamage(unitID, unitDefID, damage)
	local value, maxHealth = statsUnitValue(unitID, unitDefID)
	if value and maxHealth and maxHealth > 0 then
		lull.damage.now = lull.damage.now + value * min(damage, maxHealth) / maxHealth
	end
end

-- Add a lull event framing grid cells with notable activity, or the whole map if there are none
-- (e.g. at the start of the game)
function lull.addEvent(importance)
	local cfg = lullConfig
	local xMin, zMin, xMax, zMax = huge, huge, -huge, -huge
	for gx = 1, mapGridX do
		for gz = 1, mapGridZ do
			if interestGrid:getActivity((gx - 0.5) * worldGridSize, (gz - 0.5) * worldGridSize) >= cfg.cellMin then
				xMin, zMin = min(xMin, (gx - 1) * worldGridSize), min(zMin, (gz - 1) * worldGridSize)
				xMax, zMax = max(xMax, gx * worldGridSize), max(zMax, gz * worldGridSize)
			end
		end
	end
	if xMin == huge then
		xMin, zMin, xMax, zMax = 0, 0, mapSizeX, mapSizeZ
	end
	local x, z = (xMin + xMax) / 2, (zMin + zMax) / 2
	local half = cfg.minDiag / 2 / sqrt(2)
	xMin, xMax = max(0, min(xMin, x - half)), min(mapSizeX, max(xMax, x + half))
	zMin, zMax = max(0, min(zMin, z - half)), min(mapSizeZ, max(zMax, z + half))
	x, z = (xMin + xMax) / 2, (zMin + zMax) / 2

	local y = spGetGroundHeight(x, z)
	local event = addEvent(nil, importance, { x, y, z }, nil, lullEventType, lullEventType, nil, nil, ADD_EVENT_OPTS_NO_GRID_NO_MERGE)
	-- Placeholder units at opposite corners give the framing
	event:addSubject(-1000 - 2 * event.id, { xMin, y, zMin })
	event:addSubject(-1001 - 2 * event.id, { xMax, y, zMax })
	return event
end

-- Once a second: track damage, and add a lull event when a fight dies down
function lull.update()
	local d, cfg = lull.damage, lullConfig
	d.short = d.short + (d.now - d.short) / cfg.damageShortSeconds
	d.long = d.long + (d.now - d.long) / cfg.damageLongSeconds
	d.now = 0
	d.peak = max(d.short, d.peak * 0.5 ^ (1 / cfg.peakHalfLifeSeconds))
	local isFight = d.peak >= cfg.minPeak and d.peak >= cfg.minPeakRatio * d.long
	local fired = false
	if not lull.armed then
		lull.armed = isFight and d.short >= cfg.rearmRatio * d.peak
	elseif d.short <= cfg.dropRatio * d.peak then
		lull.armed = false
		if isFight then
			lull.addEvent(d.peak)
			fired = true
		end
	end

	if STATS then
		spEcho(string.format('rc-lull,%d,%d,%.1f,%.1f,%.1f', lull.armed and 1 or 0, fired and 1 or 0, d.short, d.long, d.peak))
	end
end

-- Spread amount over the four cells nearest (x, z), by closeness to their centres, so that scores
-- don't jump as units cross cell edges. With best, keep the largest amount per cell instead of adding.
function scenes.spread(cells, x, z, amount, best)
	local fx, fz = x / worldGridSize - 0.5, z / worldGridSize - 0.5
	local gx, gz = floor(fx), floor(fz)
	for ix = 0, 1 do
		for iz = 0, 1 do
			local weight = (1 - math.abs(fx - gx - ix)) * (1 - math.abs(fz - gz - iz))
			local cell = 1 + bound(gx + ix, 0, mapGridX - 1) + bound(gz + iz, 0, mapGridZ - 1) * mapGridX
			if best then
				cells[cell] = max(cells[cell] or 0, amount * weight)
			else
				cells[cell] = (cells[cell] or 0) + amount * weight
			end
		end
	end
end

-- Add a unit to this second's value and strength grids. Called as each unit's position is
-- refreshed, which spreads the work over the second.
function scenes.observe(info)
	local cfg, allyTeam = scenes, info.allyTeam
	if not cfg.value[allyTeam] then
		cfg.value[allyTeam], cfg.metal[allyTeam], cfg.power[allyTeam], cfg.powerNow[allyTeam] = {}, {}, {}, {}
	end
	local x, _, z = unpack(info.location)
	scenes.spread(cfg.value[allyTeam], x, z, info.importance)
	scenes.spread(cfg.metal[allyTeam], x, z, info.metal)
	local _, _, weaponImportance = unitInfo:_unitStats(info.unitDefID)
	if weaponImportance <= 0 or info.unfinished then
		return
	end
	scenes.spread(cfg.powerNow[allyTeam], x, z, info.metal)
	-- Strength along the unit's path: in each cell, the most it will bring to bear
	-- (velocity is per frame)
	local vx, _, vz = unpack(info.velocity)
	local power, path = cfg.power[allyTeam], {}
	for i, seconds in ipairs(cfg.horizon) do
		local frames = seconds * framesPerSecond
		scenes.spread(path, x + vx * frames, z + vz * frames, info.metal * cfg.discount[i], true)
		if vx == 0 and vz == 0 then
			break
		end
	end
	for cell, amount in pairs(path) do
		power[cell] = (power[cell] or 0) + amount
	end
end

-- Returns, by cell: value at stake, the same counting only where armed units are now, the ally team
-- with most at stake, and the metal at stake (the same, at what the units cost)
function scenes.survey()
	local cfg, value, metal, power, powerNow = scenes, scenes.value, scenes.metal, scenes.power, scenes.powerNow
	cfg.value, cfg.metal, cfg.power, cfg.powerNow = {}, {}, {}, {}

	local stake, stakeNow, owner, ownerStake, metalStake = {}, {}, {}, {}, {}
	for allyTeam, cells in pairs(value) do
		for cell, v in pairs(cells) do
			local threat, threatNow = 0, 0
			for enemy, enemyPower in pairs(power) do
				if enemy ~= allyTeam then
					threat = threat + (enemyPower[cell] or 0)
					threatNow = threatNow + (powerNow[enemy][cell] or 0)
				end
			end
			local atStake = min(v, cfg.leverage * threat)
			if atStake > 0 then
				stake[cell] = (stake[cell] or 0) + atStake
				stakeNow[cell] = (stakeNow[cell] or 0) + min(v, cfg.leverage * threatNow)
				metalStake[cell] = (metalStake[cell] or 0) + min(metal[allyTeam][cell], cfg.leverage * threat)
				if atStake > (ownerStake[cell] or 0) then
					owner[cell], ownerStake[cell] = allyTeam, atStake
				end
			end
		end
	end
	cfg.metalStake = metalStake
	return stake, stakeNow, owner, metalStake
end

-- The stake around a ring at (x, z): the cells under a square that takes in the ring and the cell
-- each unit's value is spread over, by how much of each it covers
function scenes.around(stake, x, z)
	local half, total = scenes.radius + worldGridSize / 2, 0
	local function spans(c, count)
		local shares = {}
		for i = max(1, floor((c - half) / worldGridSize) + 1), min(count, floor((c + half) / worldGridSize) + 1) do
			shares[i] = max(0, min(c + half, i * worldGridSize) - max(c - half, (i - 1) * worldGridSize)) / worldGridSize
		end
		return shares
	end
	for ix, sx in pairs(spans(x, mapGridX)) do
		for iz, sz in pairs(spans(z, mapGridZ)) do
			total = total + (stake[ix + (iz - 1) * mapGridX] or 0) * sx * sz
		end
	end
	return total
end

-- The mobile units near (x, z), or failing that the buildings, or nil
function scenes.subjects(x, z)
	local mobiles, statics = {}, {}
	for _, unitID in ipairs(spGetUnitsInCylinder(x, z, scenes.radius)) do
		local location, _, _, _, isStatic = unitInfo:get(unitID)
		if location then
			(isStatic and statics or mobiles)[unitID] = location
		end
	end
	return next(mobiles) and mobiles or next(statics) and statics or nil
end

-- Once a second: add events where the stake has risen most
function scenes.update()
	local cfg = scenes
	local stake, stakeNow, owner, metalStake = scenes.survey()
	for cell in pairs(cfg.baseline) do
		stake[cell] = stake[cell] or 0
	end
	local rise = {}
	local wx, _, wz = unpack(display.location)
	for cell, s in pairs(stake) do
		local base = cfg.baseline[cell] or 0
		rise[cell] = s > base and s - base or nil
		-- What the camera is on stops being news much sooner
		local x, z = ((cell - 1) % mapGridX + 0.5) * worldGridSize, (floor((cell - 1) / mapGridX) + 0.5) * worldGridSize
		local watched = not display.isWide and max(math.abs(x - wx), math.abs(z - wz)) <= cfg.watchedRange
		base = base + (s - base) / (watched and cfg.watchedSeconds or cfg.baselineSeconds)
		cfg.baseline[cell] = base >= 1 and base or nil
	end

	-- A scene is a cell and its neighbours, centred on where the rise is
	local risen = {}
	for cell in pairs(rise) do
		local gx, gz = (cell - 1) % mapGridX + 1, floor((cell - 1) / mapGridX) + 1
		local total, xSum, zSum = 0, 0, 0
		for ix = max(1, gx - 1), min(mapGridX, gx + 1) do
			for iz = max(1, gz - 1), min(mapGridZ, gz + 1) do
				local r = rise[ix + (iz - 1) * mapGridX] or 0
				total, xSum, zSum = total + r, xSum + r * (ix - 0.5), zSum + r * (iz - 0.5)
			end
		end
		if total >= cfg.minStake then
			risen[#risen + 1] = { cell = cell, gx = gx, gz = gz, rise = total,
				x = xSum / total * worldGridSize, z = zSum / total * worldGridSize }
		end
	end
	table.sort(risen, function(a, b) return a.rise > b.rise end)

	local added = {}
	for _, scene in ipairs(risen) do
		local apart = #added < cfg.maxScenes
		for _, other in ipairs(added) do
			apart = apart and max(math.abs(scene.gx - other.gx), math.abs(scene.gz - other.gz)) >= cfg.separation
		end

		local x, z, cell = scene.x, scene.z, scene.cell
		local subjects = apart and scenes.subjects(x, z)
		if subjects then
			added[#added + 1] = scene
			-- Share of the stake that is still on its way
			local soon = 1 - stakeNow[cell] / stake[cell]
			local side = owner[cell]
			local commentary = (side and overlay.coloured(cfg.names[side], overlay.allyColor[side]) or "Someone")
				.. (soon > 0.5 and " has trouble incoming" or " under pressure")
			local event = addEvent(nil, scene.rise, { x, spGetGroundHeight(x, z), z }, nil, sceneEventType, sceneEventType, nil, nil, cfg.eventOpts)
			-- The rise wanders from cell to cell (and away from where the camera looks, as that
			-- stops being news), so a scene under way ignores small moves
			local last = event.meta
			if last then
				local follow = max(0, 1 - cfg.deadZone / max(1, length(x - last.x, z - last.z)))
				x, z = last.x + (x - last.x) * follow, last.z + (z - last.z) * follow
				event.location = { x, spGetGroundHeight(x, z), z }
				subjects = scenes.subjects(x, z) or subjects
			end
			event.meta, event._sbjUnits = { commentary = commentary, side = side, x = x, z = z }, subjects
			event.shownStake = event.shownStake or scenes.around(metalStake, x, z)
			if event == shownEvent then
				trackEvent(event, true)
			elseif scene.rise >= cfg.asideStake and not display.isWide and length(x - wx, z - wz) <= cfg.asideRange
			    and (not display.aside or display.aside[3] < gameFrame) then
				-- Scenes come biggest first, so this is the best one this second
				display.aside = { x, z, gameFrame }
			end
			if STATS then
				spEcho(string.format('rc-scene,%.0f,%.0f,%.0f,%.2f', x, z, scene.rise, soon))
			end
		end
	end

	-- The scene on show keeps its number up to date, whether or not it rose this second
	local shown = overlay.event
	if shown and shown.type == sceneEventType and shown.shownStake then
		local now = scenes.around(metalStake, shown.location[1], shown.location[3])
		shown.shownStake = shown.shownStake + (now - shown.shownStake) / cfg.shownStakeSeconds
	end
end

function widget:Shutdown()
  spSetCameraState(initialCameraState, 0)
end

function widget:Initialize()
	if not (spIsReplay() or spGetSpectatingState()) then
		spEcho("DEACTIVATING " .. widget:GetInfo().name .. " as not spec")
		widgetHandler:RemoveWidget()
		return
	end

	-- Init teams.
    local gaiaTeamID = spGetGaiaTeamID()
	teamInfo = {}
	local teamCount = 0
	local allyTeams = spGetAllyTeamList()
	for _, allyTeam in pairs(allyTeams) do
		local teamList = spGetTeamList(allyTeam)

		local allyTeamName = spGetGameRulesParam("allyteam_long_name_" .. allyTeam)
		if string.len(allyTeamName) > 10 then
			allyTeamName = spGetGameRulesParam("allyteam_short_name_" .. allyTeam)
		end

		for _, teamID in pairs(teamList) do
			local teamName
            if teamID == gaiaTeamID then
                teamName = "Gaia"
            else
                local _, teamLeader, _, isAI = spGetTeamInfo(teamID)
				if teamLeader < 0 then
					teamLeader = spGetTeamRulesParam(teamID, "initLeaderID") or teamLeader
				end
                if isAI then
                    local _, name = spGetAIInfo(teamID)
                    teamName = name
                else
				    teamName = spGetPlayerInfo(teamLeader)
                end
			end
			scenes.names[allyTeam] = allyTeamName
			if teamID ~= gaiaTeamID then
				overlay.allyColor[allyTeam] = overlay.allyColor[allyTeam] or { spGetTeamColor(teamID) }
			end
			teamInfo[teamID] = {
				allyTeam = allyTeam,
				allyTeamName = allyTeamName,
				color = { spGetTeamColor(teamID) } or { 1, 1, 1, 1 },
				name = teamName or ("Team " .. teamID)
			}
			teamCount = teamCount + 1
		end
	end

	interestGrid = WorldGrid:new({ xSize = mapGridX, ySize = mapGridZ, gridSize = worldGridSize, teamCount = teamCount, allyTeams = allyTeams })
	unitInfo = UnitInfoCache:new({ locationListener = function(location, allyTeam, isMoving)
		-- Static things are less interesting, but with allyTeams multiplier can still be relevant
		local interest = isMoving and 1 or 0.16
		interestGrid:add(location[1], location[3], allyTeam, interest)
	end, updateListener = scenes.observe })

	-- Catch up on units made before the widget started, staggering their position updates
	gameFrame = Spring.GetGameFrame()
	for _, unitID in ipairs(Spring.GetAllUnits()) do
		unitInfo:get(unitID)
		if unitInfo.cache[unitID] then
			unitInfo.cache[unitID].lastUpdatedFrame = gameFrame - unitID % unitInfoCacheFrames
		end
	end


	initialCameraState = spGetCameraState()

	local cx, cy, cz = spGetCameraPosition()
	display = {
		camAngle = defaultRx,
		diag = 0,
		location = { mapSizeX / 2, -1000, mapSizeZ / 2 },
		camType = camTypeTracking,
		fill = frameFill,
		shotFrame = 0,
		tracking = LinkedList:new(),
		velocity = { 0, 0, 0 }
	}
	if STATS then
		statsLogGame()
	end
	-- Open on a wide shot of the map
	updateDisplay(lull.addEvent(lullConfig.minPeak))
	camera = initCamera(cx, cy, cz)
end

function widget:GameFrame(frame)
	gameFrame = frame
	unitInfo:update(frame)

	if frame % updateIntervalFrames ~= 0 then
		return
	end

	if STATS then
		statsFlush(options.user_interrupts_tracking.value and userInactiveSeconds < userInactiveSecondsThreshold)
	end

	if not display.isWide then
		local x, _, z = unpack(display.location)
		interestGrid:setWatching(x, z)
	end

	if WG.alliedCursorsPos then
		for _, acp in pairs(WG.alliedCursorsPos) do
		    local curx, curz = unpack(acp)
			if curx and curz then
				interestGrid:setCursor(curx, curz)
			end
		end
    end

	scenes.update()

	local cut = false
	if pendingMie and pendingMie ~= mie then
		-- While the shot is locked a cut needs a bigger margin. A cut may also have decayed while
		-- it waited out the lock, so check it still beats the pick.
		local locked = shotLocked()
		cut = _beatsPick(pendingMie, _getRarity(pendingMie), locked and shotLockBoost)
		if not cut and not locked then
			pendingMie = mie
		end
	end
	if cut then
		if mie then
			-- Avoid showing current event again
			events:remove(mie)
		end

		mie = pendingMie
		updateDisplay(mie);
		purgeEvents(__purgeExcludes, { excluder = mie })
		-- Picked event should stop changing itself
		mie.updateFunc = nil
		-- Set a standard decay so that we don't show the event for too long.
		mie.decay, mie.started = 3 * framesPerSecond, frame
	end

	lull.update()
	overlay.update()
end

local function userAction()
	userInactiveSeconds = 0
end

function widget:MousePress(x, y, button)
	userAction()
end

function widget:MouseMove(x, y, dx, dy, button)
	userAction()
end

function widget:MouseRelease(x, y, button)
	userAction()
end

function widget:MouseWheel(up, value)
	userAction()
end

local function _updateCommandEvent(event)
	local meta = event.meta

	if meta.updateUntilFrame < gameFrame then
		event.importance, event.updateFunc = 0, nil
		return
	end

	event.started = gameFrame

	-- For simplicity we'll just take the location of one subject
	local sbjUnitID, sbjCount = nil, 0
	for k, _ in pairs(event._sbjUnits) do
		sbjUnitID = sbjUnitID or k
		sbjCount = sbjCount + 1
	end
	local sbjLocation, sbjv = unitInfo:get(sbjUnitID)
	if not sbjLocation or not sbjv then
		event.importance, event.updateFunc = 0, nil
		return
	end

	-- Predicted distance in 1s
	local distanceFromCommand = distance(event.location, sbjLocation) - distance(sbjv) * framesPerSecond
	local rangeFraction = meta.commandRange / max(meta.commandRange, distanceFromCommand)
	event.importance = meta.importance * rangeFraction
	-- A moving unit is worth 1, let's make the commands worth a little less per unit
	event.interest = 0.5 * sbjCount * rangeFraction
end

local moveCommands = {
	[CMD_ATTACK_MOVE] = true,
	[CMD_MOVE] = true,
	[CMD_RAW_MOVE] = true,
}

function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOpts, _)
    if not unitID or not unitDefID or not unitTeam or not cmdID or not cmdParams then
		return
	end

	if not moveCommands[cmdID] and cmdID ~= CMD_ATTACK then
		return
	end

	if overlay.arrowFrom and overlay.subjects[unitID] and not (cmdOpts and cmdOpts.shift) then
		overlay.redirect(unitID, cmdParams)
	end

	local unitDef = UnitDefs[unitDefID]
	if unitDef.customParams.dontcount or unitDef.customParams.is_drone then
		-- Drones get move commands too :shrug:
		return
	end

	local _, _, _, _, buildProgress = spGetUnitHealth(unitID)
	if buildProgress < 1.0 then
		-- Don't watch units that aren't finished.
		return
	end

	-- Shouldn't display a superseded command
	purgeEvents(__purgeCommands, { unitID = unitID })

	if moveCommands[cmdID] then
		local sbjLocation, _, importance, sbjName, isStatic = unitInfo:get(unitID)
		if isStatic then
			-- Not interested in move commands given to static buildings e.g. factories
			return
		end

		local trgx, trgy, trgz = unpack(cmdParams)
		local trgLocation = { trgx, trgy, trgz }

		local moveDistance = distance(trgLocation, sbjLocation)
		if moveDistance < 256 then
			-- Ignore smaller moves to keep event numbers down and help ignore unitAI
			return
		end

		local meta = { commandRange = worldGridSize / 2, importance = importance, updateUntilFrame = gameFrame + framesPerSecond * 8,
			origin = { sbjLocation[1], sbjLocation[3] } }
		local event = addEvent(unitTeam, 0, sbjLocation, meta, sbjName, moveEventType, unitID, _updateCommandEvent)
		-- HACK: Event location should be the target location, not the subject location
		event.location = trgLocation
		event:addObject(-unitID, trgLocation)
	elseif cmdID == CMD_ATTACK then
		local trgLocation, attackedUnitID
		-- Find the location / unit being attacked.
		if #cmdParams == 1 then
			attackedUnitID = cmdParams[1]
			trgLocation = unitInfo:get(attackedUnitID)
		else
			trgLocation = cmdParams
		end
		if not trgLocation then
			return
		end

		local sbjLocation, _, _, sbjName, _, weaponImportance, weaponRange = unitInfo:get(unitID)
		-- HACK: Silo is weird.
		unitID = spGetUnitRulesParam(unitID, 'missile_parentSilo') or unitID
		local meta = { commandRange = weaponRange, importance = weaponImportance, updateUntilFrame = gameFrame + framesPerSecond * 8,
			origin = { sbjLocation[1], sbjLocation[3] } }
		local event = addEvent(unitTeam, 0, sbjLocation, meta, sbjName, attackEventType, unitID, _updateCommandEvent)
		-- HACK: Event location should be the target location, not the subject location
		event.location = trgLocation
		event:addObject(attackedUnitID or -unitID, trgLocation)
	end
end

local function _updateBuildingEvent(event)
	event.started = gameFrame

	local meta = event.meta
	local _, _, _, _, buildProgress = spGetUnitHealth(meta.sbjUnitID)
	if not buildProgress or buildProgress > 0.5 then
		-- Either the unit is no longer being built or let's wait for it to finish
		event.importance, event.updateFunc = 0, nil
	end
end

function widget:UnitCreated(unitID, unitDefID, unitTeam, _)
	if not unitID or not unitDefID or not unitTeam then
		return
	end
	
	local allyTeam = teamInfo[unitTeam].allyTeam
	local sbjLocation, _, importance, sbjName = unitInfo:watch(unitID, allyTeam, unitDefID)
	if unitInfo.cache[unitID] then
		-- Not a threat until finished (see scenes)
		unitInfo.cache[unitID].unfinished = true
	end
	local meta = { sbjUnitID = unitID }
	addEvent(unitTeam, importance, sbjLocation, meta, sbjName, buildingEventType, unitID, _updateBuildingEvent)
end

function widget:UnitDamaged(unitID, unitDefID, _, damage, paralyzer, _, _, attackerID, _, attackerTeam)
	-- attackerID and attackerTeam may be nil and are tolerated
	if not unitID or not unitDefID or not damage then
		return
	end

	local info = unitInfo.cache[unitID]
	if info and attackerTeam then
		info.hitBy, info.hitFrame = attackerTeam, gameFrame
	end
	if paralyzer then
		-- A hit that stuns reports next to no damage, so count each stun once as the whole unit.
		local health, maxHealth, paralysis = spGetUnitHealth(unitID)
		if info and health and paralysis >= health and gameFrame - (info.stunFrame or -stunFrames) >= stunFrames then
			info.stunFrame, damage = gameFrame, max(damage, maxHealth)
		end
		-- Paralysis is not as important as real damage
		damage = damage / 2
	end

	if STATS then
		statsAddDamage(unitID, unitDefID, damage)
	end
	lull.addDamage(unitID, unitDefID, damage)
	local sbjLocation, _, unitImportance, sbjName, isStatic = unitInfo:get(unitID)
	if isStatic then
		unitImportance = unitImportance * staticAttackedBoost
	end
	local currentHealth, maxHealth, _, _, buildProgress = spGetUnitHealth(unitID)
	-- currentHealth can be 0, also avoid skewing the score overly much
	currentHealth = max(currentHealth, maxHealth / 16)
	-- Percentage of current health being dealt in damage, up to 100
	local importance = 100 * min(currentHealth, damage) / currentHealth
	-- Multiply by unit importance factor
	importance = importance * unitImportance * buildProgress
	if not attackerID then
		importance = importance * unattributedDamageFactor
	end
	
	local event = addEvent(attackerTeam, importance, sbjLocation, nil, sbjName, unitDamagedEventType, unitID)
	if attackerID then
		local attackerLocation = unitInfo:get(attackerID)
		event:addObject(attackerID, attackerLocation)
	else
		-- Fire burns on after whoever lit it has gone
		event.burning = spGetUnitRulesParam(unitID, "on_fire") == 1
	end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, _, attackerTeam)
	-- First do some cleanup, if we can
	if not unitID then
		return
	end

	if STATS and unitDefID and unitTeam then
		statsLogDeath(unitID, unitDefID, unitTeam)
	end

	local destroyedLocation, _, importance, destroyedName, isStatic = unitInfo:get(unitID)
	-- Who gets the credit in the overlay. Fire can kill after whoever lit it has died, so with no
	-- attacker a unit that died of damage goes to the side that last hit it.
	local info, unitDef = unitInfo.cache[unitID], unitDefID and UnitDefs[unitDefID]
	local health, _, _, _, buildProgress = spGetUnitHealth(unitID)
	local killerTeam = attackerTeam or info and info.hitBy and (health or 0) <= 0
		and gameFrame - info.hitFrame < overlay.creditFrames and info.hitBy
	if killerTeam and unitTeam and destroyedLocation and unitDef and not unitDef.customParams.dontcount
	    and teamInfo[killerTeam].allyTeam ~= teamInfo[unitTeam].allyTeam then
		-- A unit still being built is worth what had gone into it
		overlay.addDeath(teamInfo[killerTeam].allyTeam, destroyedLocation, unitDef.metalCost * (buildProgress or 1))
	end
	local destroyerLocation, _, _, destroyerName
	if attackerID then
		destroyerLocation, _, _, destroyerName = unitInfo:get(attackerID)
	end
	if destroyedName and (attackerID or (health or 0) <= 0) then
		overlay.kill(unitID, destroyedName, destroyerName, killerTeam, spGetUnitRulesParam(unitID, "on_fire") == 1)
	end
	unitInfo:forget(unitID)
	purgeEvents(__purgeSubject, { unitID = unitID })

	if not unitDefID or not unitTeam or not attackerID or not attackerTeam or not destroyedLocation or not importance or not destroyedName then
		-- Ignore cancelled builds and other similar things like comm upgrade and other calls we don't understand
		return
	end

	if unitDef.customParams.dontcount then
		-- Ignore dontcount units e.g. terraunit
		return
	end

	if isStatic then
		importance = importance * staticAttackedBoost
	end
	local destroyedEvent = addEvent(attackerTeam, importance, destroyedLocation, nil, destroyedName, unitDestroyedEventType, unitID)
	destroyedEvent:addObject(attackerID, destroyerLocation)
	local destroyerEvent = addEvent(unitTeam, importance, destroyerLocation, nil, destroyerName, unitDestroyerEventType, attackerID)
	destroyerEvent:addObject(unitID, destroyedLocation)
	-- It would be naff to show both
	destroyedEvent:addExcludes(destroyerEvent)
    destroyerEvent:addExcludes(destroyedEvent)
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	if not unitID or not unitDefID or not unitTeam then
		return
	end

	local allyTeam = teamInfo[unitTeam].allyTeam
	local sbjLocation, _, importance, sbjName = unitInfo:watch(unitID, allyTeam, unitDefID)
	addEvent(unitTeam, importance, sbjLocation, nil, sbjName, unitBuiltEventType, unitID)
end

function widget:UnitTaken(unitID, _, _, newTeam)
	if not unitID or not newTeam then
		return
	end

	-- Note that UnitTaken (and UnitGiven) are both called for both capture and release.
	local captureController = spGetUnitRulesParam(unitID, "capture_controller");
	if not captureController or captureController == -1 then
		return
	end

	local sbjLocation, _, importance, sbjName, isStatic = unitInfo:get(unitID)
	if isStatic then
		importance = importance * staticAttackedBoost
	end
	local event = addEvent(newTeam, importance, sbjLocation, nil, sbjName, unitTakenEventType, unitID)
	local capturerLocation =  unitInfo:get(captureController)
	event:addObject(captureController, capturerLocation)
end

local function updateCamera(dt, userCameraOverride)
	local xSum, ySum, zSum, xvSum, yvSum, zvSum, trackedLocationCount = 0, 0, 0, 0, 0, 0, 0
	local points = {}
	local xMin, xMax, zMin, zMax = huge, -huge, huge, -huge
	local trackInfo, keepPrevious = display.tracking.head, false
	while trackInfo do
		if not trackInfo.isDead then
			-- Various units (e.g. puppies) use a noDraw hack combined with location displacement
			local noDraw = spGetUnitNoDraw(trackInfo.unitID)
			local location = getUnitLocation(trackInfo.unitID)
			local xv, yv, zv = spGetUnitVelocity(trackInfo.unitID)
			if not location or not xv or not yv or not zv then
				trackInfo.isDead = true
			elseif not noDraw then
				xvSum, yvSum, zvSum = xvSum + xv, yvSum + yv, zvSum + zv
				trackInfo.location = location
			end
		end

		local x, y, z = unpack(trackInfo.location)
		
		-- Accumulate tracking info if not too distant
		local nxMin, nxMax, nzMin, nzMax = min(xMin, x), max(xMax, x), min(zMin, z), max(zMax, z)
		if keepPrevious or length(nxMax - nxMin, nzMax - nzMin) <= keepTrackingRange then
			xMin, xMax, zMin, zMax = nxMin, nxMax, nzMin, nzMax
			xSum, ySum, zSum = xSum + x, ySum + y, zSum + z
			trackedLocationCount = trackedLocationCount + 1
			points[trackedLocationCount] = { x, z }
			keepPrevious = trackInfo.keepPrevious
			trackInfo = trackInfo.prev
		else
			-- Chop off the rest of the tracking infos
			while trackInfo do
				trackInfo, _ = display.tracking:remove(trackInfo)
			end
		end
	end

	if trackedLocationCount == 0 then
		-- Shouldn't happen, but avoid dividing by zero.
		return
	end

	-- Update the location being displayed
	local tlocation = _apply(_multiply, { xSum, ySum, zSum }, 1 / trackedLocationCount)
	local tvelocity = _apply(_multiply, { xvSum, yvSum, zvSum }, 1 / trackedLocationCount)
	local tdiag = distance({ xMin, 0, zMin }, { xMax, 0, zMax })
	-- Smoothly grade from camDiagMin to the target diag when the latter is 2x the former
	tdiag = tdiag + max(0, camDiagMin - tdiag * 0.5)
	tdiag = max(camDiagMin, tdiag)

	-- Apply damping to location if relatively close, to avoid overly twitchy camera
	if distance(display.location, tlocation) < eventMergeRange then
		local damping = 0.4
		display.diag = applyDamping(display.diag, tdiag, damping, dt)
		display.location = _apply2(applyDamping, display.location, tlocation, damping, dt)
		display.velocity = _apply2(applyDamping, display.velocity, tvelocity, damping, dt)
	else
		display.diag = tdiag
		display.location = tlocation
		display.velocity = tvelocity
	end

	local c = camera
	local rotate = options.camera_rotation.value

	-- Where the camera should look: the event, nudged by its velocity and kept off the map edge
	local ex, ey, ez = unpack(display.location)
	local exv, eyv, ezv = unpack(display.velocity)
	ex, ey, ez = ex + exv, ey + eyv, ez + ezv
	ex, ez = bound(ex, mapEdgeBorder, mapSizeX - mapEdgeBorder), bound(ez, mapEdgeBorder, mapSizeZ - mapEdgeBorder)
	-- Frame the tracked box, at least display.diag across, by distance rather than zoom so the FOV
	-- stays constant. frameBox centres it as projected.
	local tpitch = display.camAngle
	-- Measure the units across and along the view rather than along the map axes, so the zoom doesn't
	-- depend on the heading. (Camera right is (-cos, sin) and ahead is (sin, cos) of the yaw.)
	local cy, sy = cos(c.yaw), sin(c.yaw)
	local half = display.diag / (2 * sqrt(2))
	local aMin, aMax, bMin, bMax = -half, half, -half, half
	local aside = display.aside
	if aside and not display.isWide and gameFrame - aside[3] < scenes.asideFrames
	    and length(aside[1] - ex, aside[2] - ez) <= scenes.asideRange then
		points[#points + 1] = aside
		display.asideFrame = gameFrame
	end
	for _, point in ipairs(points) do
		local dx, dz = point[1] - ex, point[2] - ez
		local a, b = dz * sy - dx * cy, dx * sy + dz * cy
		aMin, aMax, bMin, bMax = min(aMin, a), max(aMax, a), min(bMin, b), max(bMax, b)
	end
	local corners = {}
	for _, a in ipairs({ aMin, aMax }) do
		for _, b in ipairs({ bMin, bMax }) do
			corners[#corners + 1] = { ex - a * cy + b * sy, ez + a * sy + b * cy }
		end
	end
	local lx, lz, tdist = frameBox(corners, ey, c.yaw, tpitch, display.fill)
	local tlook = { bound(lx, mapEdgeBorder, mapSizeX - mapEdgeBorder), ey, bound(lz, mapEdgeBorder, mapSizeZ - mapEdgeBorder) }

	-- Cut when a pan would take too long. A critically damped spring at capped speed takes roughly
	-- 2x its smooth time plus the distance at full speed.
	local remaining = distance(c.look, tlook)
	local isCut = c.cutNext or panSeconds(remaining) > maxPanSeconds

	if shownEvent ~= c.shot then
		c.shot, c.orbited, c.yawSmooth = shownEvent, false, yawSmoothTime
		if rotate and not isCut and not display.isWide then
			-- Turn towards the new event, as a drone pilot would, within limits
			local hx, hz = ex - c.x, ez - c.z
			if length(hx, hz) > 1 then
				c.tyaw = c.yaw + bound(wrapAngle(atan2(hx, hz) - c.yaw), -maxShotYawChange, maxShotYawChange)
			end
		end
	end

	if isCut then
		-- A cut is a new scene to the viewer: the callout starts where it best fits there
		overlay.tally, overlay.box = {}, nil
		if shownEvent and overlay.event ~= shownEvent then
			overlay.start(shownEvent)
		end
		c.look, c.lookv = tlook, { 0, 0, 0 }
		c.dist, c.distv = tdist, 0
		c.pitch, c.pitchv = tpitch, 0
		-- Face north again after a cut, so the viewer doesn't lose their bearings
		c.yaw, c.yawv, c.tyaw, c.yawSmooth = defaultRy, 0, defaultRy, yawSmoothTime
	else
		smoothDampVec(c.look, tlook, c.lookv, lookSmoothTime, dt, lookMaxSpeed)
		local arc = min(tdist * panArcMax, remaining * panArcRise)
		c.dist, c.distv = smoothDamp(c.dist, tdist + arc, c.distv, distSmoothTime, dt)
		c.pitch, c.pitchv = smoothDamp(c.pitch, tpitch, c.pitchv, pitchSmoothTime, dt)
		if display.isWide then
			c.tyaw = defaultRy
		elseif rotate then
			planHeading(c)
		end
		local tyaw = rotate and c.tyaw or defaultRy
		c.yaw, c.yawv = smoothDamp(c.yaw, c.yaw + wrapAngle(tyaw - c.yaw), c.yawv, c.yawSmooth or yawSmoothTime, dt)
		c.yaw = wrapAngle(c.yaw)
		c.tyaw = c.yaw + wrapAngle(c.tyaw - c.yaw)
	end
	c.cutNext = false

	-- Where the camera is headed, for placing the callout. An orbit takes many seconds, so for
	-- that it is the heading now.
	local orbiting = c.yawSmooth == orbitConfig.smoothTime
	c.settled = { look = tlook, dist = tdist, pitch = tpitch, yaw = (not rotate or display.isWide) and defaultRy or orbiting and c.yaw or c.tyaw }

	-- Camera pose from the rig: behind the look-at point along the yaw, raised by the pitch
	local lx, ly, lz = unpack(c.look)
	local d2 = c.dist * cos(c.pitch)
	local rx, ry = c.pitch, c.yaw
	-- HACK: Translation seems to apply 1 render frame later than rotation, so on a cut send the new
	-- position with the old rotation, and the new rotation next frame.
	if isCut then
		rx, ry = c.rx, c.ry
	end

	if STATS then
		statsTrackYaw(dt, c.ry, ry, isCut or c.wasCut)
	end
	c.wasCut = isCut

	c.x, c.y, c.z = lx - d2 * sin(c.yaw), ly - c.dist * sin(c.pitch), lz - d2 * cos(c.yaw)
	c.rx, c.ry, c.fov = rx, ry, defaultFov
	c.reticle = { xMin, zMin, xMax, zMax }

	if userCameraOverride then
		return
	end

	spSetCameraState({
		mode = 4,
		px = camera.x,
		py = camera.y,
		pz = camera.z,
		rx = camera.rx,
		ry = camera.ry,
		rz = 0,
		fov = camera.fov
  }, 0)

	checkFramed(xMin, zMin, xMax, zMax)
end

function widget:Update(dt)
	local mx, my = spGetMouseState()
	local newMouseLocation = { mx, 0, my }
    if distance(newMouseLocation, lastMouseLocation) ~= 0 then
		lastMouseLocation = newMouseLocation
		userAction()
	end
	userInactiveSeconds = userInactiveSeconds + dt
	-- For the callout's glide, which is drawn after this
	overlay.dt = dt
	if userInactiveSeconds > userInactiveSecondsThreshold then
		spSetMouseCursor('none')
	end
	updateCamera(dt, options.user_interrupts_tracking.value and userInactiveSeconds < userInactiveSecondsThreshold)
end

function widget:DrawWorldPreUnit()
	overlay.drawWorld()
end

function widget:DrawScreen()
	overlay.draw()
	if not options.tracking_reticle.value or not camera.reticle then
		return
	end

	local xMin, zMin, xMax, zMax = unpack(camera.reticle)
	local centerGroundHeight = spGetGroundHeight((xMin + xMax) / 2, (zMin + zMax) / 2)
	local screenCoordinates = {}
	screenCoordinates[#screenCoordinates+1] = { spWorldToScreenCoords(xMin, centerGroundHeight, zMin) }
	screenCoordinates[#screenCoordinates+1] = { spWorldToScreenCoords(xMin, centerGroundHeight, zMax) }
	screenCoordinates[#screenCoordinates+1] = { spWorldToScreenCoords(xMax, centerGroundHeight, zMin) }
	screenCoordinates[#screenCoordinates+1] = { spWorldToScreenCoords(xMax, centerGroundHeight, zMax) }

	local xMinScreen, yMinScreen, xMaxScreen, yMaxScreen = huge, huge, -huge, -huge
	for _, coord in pairs(screenCoordinates) do
		local x, y = unpack(coord)
		xMinScreen, yMinScreen, xMaxScreen, yMaxScreen = min(xMinScreen, x), min(yMinScreen, y), max(xMaxScreen, x), max(yMaxScreen, y)
	end

	glPolygonMode(GL_FRONT_AND_BACK, GL_LINE)
	glLineWidth(2)
	glColor(0, 1, 0, 0.5)

	glRect(xMinScreen - 32, yMinScreen - 32, xMaxScreen + 32, yMaxScreen + 32)

	-- Reset GL state
	glPolygonMode(GL_FRONT_AND_BACK, GL_FILL)
	glLineWidth(1.0)
	glColor(1, 1, 1, 1)
end