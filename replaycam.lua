function widget:GetInfo()
	return {
		name    = "ReplayCam",
		desc    = "Pan to and comment on interesting events",
		author  = "moreginger",
		date    = "2023-01-23",
		license = "GNU GPL v2",
		--layer        = 0,
		enabled = true
	}
end

local abs = math.abs
local atan2 = math.atan2
local cos = math.cos
local deg = math.deg
local exp = math.exp
local floor = math.floor
local huge = math.huge
local max = math.max
local min = math.min
local pi = math.pi
local rad = math.rad
local sin = math.sin
local sqrt = math.sqrt
local tan = math.tan

local spEcho = Spring.Echo
local spGetAllyTeamList = Spring.GetAllyTeamList
local spGetCameraPosition = Spring.GetCameraPosition
local spGetCameraState = Spring.GetCameraState
local spGetGameRulesParam = Spring.GetGameRulesParam
local spGetGroundHeight = Spring.GetGroundHeight
local spGetHumanName = Spring.Utilities.GetHumanName
local spGetMouseState = Spring.GetMouseState
local spGetMovetype = Spring.Utilities.getMovetype
local spGetPlayerInfo = Spring.GetPlayerInfo
local spGetSpectatingState = Spring.GetSpectatingState
local spGetTeamColor = Spring.GetTeamColor
local spGetTeamInfo = Spring.GetTeamInfo
local spGetTeamList = Spring.GetTeamList
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitHealth = Spring.GetUnitHealth
local spGetUnitNoDraw = Spring.GetUnitNoDraw
local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitRulesParam = Spring.GetUnitRulesParam
local spGetUnitsInRectangle = Spring.GetUnitsInRectangle
local spGetUnitTeam = Spring.GetUnitTeam
local spGetUnitVelocity = Spring.GetUnitVelocity
local spGetViewGeometry = Spring.GetViewGeometry
local spIsReplay = Spring.IsReplay
local spSetCameraState = Spring.SetCameraState
local spTableEcho = Spring.Utilities.TableEcho

local Chili
local Window
local ScrollPanel
local screen0

local CMD_ATTACK = CMD.ATTACK
local CMD_ATTACK_MOVE = CMD.FIGHT
local CMD_MOVE = CMD.MOVE

local framesPerSecond = 30
local gameFrame = 0

-- CONFIGURATION

local LOG_ERROR, LOG_DEBUG = 1, 2
local logging = LOG_ERROR
local updateIntervalFrames = framesPerSecond
local defaultFov, defaultRx, defaultRy, maxCamRPerSecond = 45, -1.0, pi, pi / 16

-- UTILITY FUNCTIONS

-- Initialize a table.
local function initTable(key, value)
	local result = {}
	if (key) then
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
	if (x < min) then
		return min
	end
	if (x > max) then
		return max
	end
	return x
end

local function symmetricBound(x, center, diff)
	return bound(x, center - diff, center + diff)
end

local function signum(x)
    return x > 0 and 1 or (x == 0 and 0 or -1)
end

local function applyDamping(old, new, rollingFraction, dt)
	dt = dt or 1
	local newFraction = (1 - rollingFraction) * dt
	return (1 - newFraction) * old + newFraction * new
end

local function _apply(fun, vector, arg1, arg2)
	local result = {}
	for i = 1, #vector do
		result[i] = fun(vector[i], arg1, arg2)
	end
	return result
end

local function _apply2(fun, vector1, vector2, arg1, arg2)
	local result = {}
	for i = 1, #vector1 do
		result[i] = fun(vector1[i], vector2[i], arg1, arg2)
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

-- WORLD GRID CLASS
-- Translates world coordinates into operations on a grid.

WorldGrid = { xSize = 0, ySize = 0, gridSize = 0, allyTeams = {}, data = {} }

function WorldGrid:new(o)
	o = o or {} -- create object if user does not provide one
	setmetatable(o, self)
	self.__index = self

	o.allyTeams = o.allyTeams or {}
	o.data = o.data or {}
	for x = 1, o.xSize do
		o.data[x] = {}
		for y = 1, o.ySize do
			o.data[x][y] = {}
		end
	end
	o:reset()

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

function WorldGrid:_getScoreGridCoords(x, y)
	local interest, allyTeams, passe = unpack(self.data[x][y])
	local allyTeamCount = 0
	for _, _ in pairs(allyTeams) do
		allyTeamCount = allyTeamCount + 1
	end
	local allyTeamsMult = max(1, allyTeamCount * allyTeamCount)
	-- We want passe to kick in slowly then get strong after 10s or so;
	-- use logistic function
	-- Shift the function to the right given min passe is 0
	passe = passe - 8
	local passeMult = 1 - (1 / (1 + exp(-0.4 * passe)))
	return interest * allyTeamsMult * passeMult
end

function WorldGrid:getScore(x, y)
	x, y = self:__toGridCoords(x, y)
	return self:_getScoreGridCoords(x, y)
end

function WorldGrid:getInterestingScore()
	-- 4 is equal to 4 ally units, or 2 x 1 units from different ally teams.
	return 5 * updateIntervalFrames / framesPerSecond
end

function WorldGrid:_addInternal(x, y, area, opts, func)
	if not area then
		area = self.gridSize
	end
	local gx, gy = self:__toGridCoords(x, y)

	-- Work out how to divvy the interest up around nearby grid squares.
	local areas, i, totalArea = {}, 1, 0
	for ix = gx - 1, gx + 1 do
		for iy = gy - 1, gy + 1 do
			if ix >= 1 and ix <= self.xSize and iy >= 1 and iy <= self.ySize then
				areas[i] = self:_intersectArea(x - area / 2, y - area / 2, x + area / 2, y + area / 2,
					(ix - 1) * self.gridSize, (iy - 1) * self.gridSize, ix * self.gridSize, iy * self.gridSize)
				totalArea = totalArea + areas[i]
			end
			i = i + 1
		end
	end

	-- Divvy out the interest.
	i = 1
	for ix = gx - 1, gx + 1 do
		for iy = gy - 1, gy + 1 do
			if areas[i] then
				local data = self.data[ix][iy]
				func(data, areas[i] / totalArea, opts)
			end
			i = i + 1
		end
	end
end

local function _addInterest(data, f, opts)
	data[1] = data[1] + opts.interest * f
	if opts.allyTeam then
		data[2][opts.allyTeam] = true
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

function WorldGrid:_intersectArea(x1, y1, x2, y2, x3, y3, x4, y4)
	local x5, y5, x6, y6 = max(x1, x3), max(y1, y3), min(x2, x4), min(y2, y4)
	if x5 >= x6 or y5 >= y6 then
		return 0
	end
	return (x6 - x5) * (y6 - y5)
end

function WorldGrid:reset()
	for x = 1, self.xSize do
		for y = 1, self.ySize do
			local data = self.data[x][y]
			data[1] = 1
			data[2] = {}
			-- Reduce passe to min of 0
			data[3] = max(0, (data[3] or 0) - 1)
		end
	end
end

-- Call this exactly once between each reset.
-- When watching an area we apply a fixed boost to make things sticky,
-- but a longer-term negative factor (passe) to encourage moving.
function WorldGrid:setWatching(x, y)
	-- Note: boost is spread over a 2x2 grid.
	self:_addInternal(x, y, self.gridSize * 2, { boost = 10 }, _boostInterest)
	-- passe will be decreased by 1 in each grid square in reset, therefore:
	-- 1. Make sure it all goes into one grid square instead of being shared
	-- 2. Increase by 2 in anticipation of decreasing by 1 later
	x, y =  self:__toWorldCoords(self:__toGridCoords(x, y))
	self:_addInternal(x, y, self.gridSize * 0.5, { passe = 2 }, _addPasse)
end

-- Return mean, max, maxX, maxY
function WorldGrid:statistics()
	local maxValue, maxX, maxY, total = -1, nil, nil, 0
	for gx = 1, self.xSize do
		for gy = 1, self.ySize do
			local value = self:_getScoreGridCoords(gx, gy)
			total = total + value
			if maxValue < value then
				maxValue = value
				maxX = gx
				maxY = gy
			end
		end
	end

	-- Displace the coordinates according to the scores of neighbouring squares,
	-- this avoids the problem of a hard stop at the edge of a square.
	local centerX, centerY = self:__toWorldCoords(maxX, maxY)
	local gridsToAverage = {}
	local totalScore = 0
	for gx = max(1, maxX - 1), min(self.xSize, maxX + 1) do
		for gy = max(1, maxY - 1), min(self.ySize, maxY + 1) do
			if gx ~= maxX or gy ~= maxY then
				local wX, wY = self:__toWorldCoords(gx, gy)
				-- Displace according to the inverse of the distance
				local distanceFactor = 1 / length(maxX - gx, maxY - gy)
				local dX, dY = (wX - centerX) * distanceFactor, (wY - centerY) * distanceFactor
				local score = self:_getScoreGridCoords(gx, gy)
				gridsToAverage[#gridsToAverage + 1] = { dX = dX, dY = dY, score = score }
				totalScore = totalScore + score
			end
		end
	end

	local dX, dY = 0, 0
	for _, grid in pairs(gridsToAverage) do
		dX, dY = dX + (grid.dX * grid.score / totalScore), dY + (grid.dY * grid.score / totalScore)
	end

	return maxValue, centerX + dX, centerY + dY
end

-- UNIT INFO CACHE

local unitInfoCacheFrames = framesPerSecond

UnitInfoCache = { locationListener = nil }

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
	local weaponImportance = weaponDamage * aoeBoost * afterburnBoost
	local range = wdcp.truerange or wd.range
	return weaponImportance, range
end

function UnitInfoCache:_unitStats(unitDefID)
	local cacheObject = self._unitStatsCache[unitDefID]
	if not cacheObject then
		local unitDef = UnitDefs[unitDefID]
		local importance = unitDef.metalCost
		if unitDef.customParams.ismex then
			-- Give mexes a little buff since they are cheap but important
			importance = importance * 2
		end
		local isStatic = not spGetMovetype(unitDef)
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
		if logging >= LOG_DEBUG then
			spEcho("ERROR! UnitInfoCache:_updatePosition failed", unitID, cacheObject.name)
		end
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
		local x, y, z = unpack(location)
		self.locationListener(x, y, z, cacheObject.allyTeam, isMoving)
	end

	return true
end

function UnitInfoCache:watch(unitID, allyTeam, unitDefID)
	if not unitDefID then
		unitDefID = spGetUnitDefID(unitID)
	end
	local unitDef = UnitDefs[unitDefID]
	local name = spGetHumanName(unitDef, unitID)
	local cacheObject = { name = name, allyTeam = allyTeam, unitDefID = unitDefID, lastUpdatedFrame = gameFrame }
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
		local importance, isStatic, weaponImportance, weaponRange = self:_unitStats(cacheObject.unitDefID)
		local dt = (gameFrame - cacheObject.lastUpdatedFrame) / framesPerSecond
		local location = _apply2(_extrapolate, cacheObject.location, cacheObject.velocity, dt)
		return location, cacheObject.velocity, importance, cacheObject.name, isStatic, weaponImportance, weaponRange
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
		elseif currentFrame - cacheObject.lastUpdatedFrame > unitInfoCacheFrames then
			cacheObject.lastUpdatedFrame = currentFrame
			if not self:_updatePosition(unitID, cacheObject) then
				-- Something went wrong, drop from cache.
				self.cache[unitID] = nil
			end
		end
	end
end

-- EVENT

local eventMergeRange = 256

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
end

function Event:excludes(other)
	return self._excludes[other.id]
end

function Event:importanceAtFrame(frame)
  return self.importance * (1 - self.decay * (frame - self.started) / framesPerSecond)
end

-- return - true if there are no more subjects
function Event:removeSubject(unitID)
	self._sbjUnits[unitID] = nil
	for _, _ in pairs(self._sbjUnits) do
		return false
	end
	return true
end

function Event:shouldMerge(type, sbjName, location, actorAllyTeam)
	return self.type == type and self.sbjName == sbjName and self.actorAllyTeam == actorAllyTeam and distance(self.location, location) < eventMergeRange
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

	for _, type in pairs(types) do
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

-- Return mean importance
function EventStatistics:getMean(type)
	local mean = self[type][2]
	return (mean > 0) and mean or nil
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

-- GUI COMPONENTS

local window_cpl, panel_cpl, commentary_cpl

-- EVENT TRACKING

local attackEventType = "attack"
local hotspotEventType = "hotspot"
local overviewEventType = "overview"
local unitBuiltEventType = "unitBuilt"
local unitDamagedEventType = "unitDamaged"
local unitDestroyedEventType = "unitDestroyed"
local unitDestroyerEventType = "unitDestroyer"
local unitMovingEventType = "unitMoving"
local unitTakenEventType = "unitTaken"
local eventTypes = {
	attackEventType,
	hotspotEventType,
	overviewEventType,
	unitBuiltEventType,
	unitDamagedEventType,
	unitDestroyedEventType,
	unitDestroyerEventType,
	unitMovingEventType,
	unitTakenEventType
}

-- Linear decay rate
local decayPerSecond = {
	attack = 1,
	hotspot = 1,
	overview = 1,
	unitBuilt = 0.05,
	unitDamaged = 0.4,
	unitDestroyed = 0.1,
	unitDestroyer = 0.1,
	unitMoving = 0.4,
	unitTaken = 0.1,
}

local eventStatistics = EventStatistics:new({
	-- Adjust mean of events in percentile estimation
	-- > 1: make each event seem more likely (less interesting)
	-- < 1: make each event seem less likely (more interesting)
	eventMeanAdj = {
		attack = 1.3,
		hotspot = 0.7,
		overview = 4.4,
		unitBuilt = 3.2,
		unitDamaged = 0.7,
		unitDestroyed = 0.5,
		unitDestroyer = 0.8,
		unitMoving = 2.0,
		unitTaken = 0.2,
	}
}, eventTypes)

local lastEventId = 0
local tailEvent, headEvent, showingEvent

-- Removes element from linked list and returns new head/tail.
local function removeElement(element, head, tail)
	if element == head then
		head = element.previous
	end
	if element == tail then
		tail = element.next
	end
	if element.previous then
		element.previous.next = element.next
	end
	if element.next then
		element.next.previous = element.previous
	end
	element.previous = nil
	element.next = nil
	return head, tail
end

-- deferFunc - Optional function taking the event as a parameter.
--             Useful for command events that may become interesting e.g. when units close range.
-- returns event {}
-- - units Contains unit IDs and their current locations. May contain negative unit IDs e.g. for dead units.
local function addEvent(actor, importance, location, meta, sbjName, type, unitID, deferFunc, opts)
	opts = opts or {}

	local decay = decayPerSecond[type]
	local actorAllyTeam = actor and teamInfo[actor].allyTeam

	-- Try to merge into recent events.
	local considerForMergeAfterFrame = gameFrame - framesPerSecond
	local event = (not opts.noMerge and headEvent) or nil
	while event ~= nil do
		local nextEvent = event.previous
		if event.started < considerForMergeAfterFrame then
			-- Don't want to check further back, so break.
			event = nil
			break
		end
		local importanceAtFrame = event:importanceAtFrame(gameFrame)
		if importanceAtFrame <= 0 then
			-- Just remove the event forever.
			headEvent, tailEvent = removeElement(event, headEvent, tailEvent)
		elseif event:shouldMerge(type, sbjName, location, actorAllyTeam) then
			if logging >= LOG_DEBUG then
				spEcho('merging events', type)
			end
			-- Merge new event into old.
			event.importance = importanceAtFrame + importance
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

			-- Remove it and attach at head later.
			headEvent, tailEvent = removeElement(event, headEvent, tailEvent)

			-- We merged, so break.
			break
		end
		event = nextEvent
	end

	if not event then
		if logging == LOG_DEBUG then
			spEcho('event', type, sbjName, importance, location)
		end
		lastEventId = lastEventId + 1
		event = Event:new({
			actorCount = 1,
			actors = initTable(actor, true),
			actorAllyTeam = actorAllyTeam,
			decay = decay,
			deferFunc = deferFunc,
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

	if (headEvent == nil) then
		tailEvent = event
		headEvent = event
	elseif (event ~= headEvent) then
		headEvent.next = event
		event.previous = headEvent
		headEvent = event
	end

	return event
end

local function addOverviewEvent(importance)
	local x, z = mapSizeX / 2, mapSizeZ / 2
	local overviewY = spGetGroundHeight(x, z)
	local overviewEvent = addEvent(nil, importance, { x, overviewY, z }, nil, overviewEventType, overviewEventType, -1, nil, { noMerge = true })

	-- Add two fake units to get the right zoom level
	local sx, sy = spGetViewGeometry()
	local sratio = sx / sy
	local mratio = mapSizeX / mapSizeZ
	local zfit = 0.8
	if sratio < mratio then
		zfit = zfit * sratio / mratio
	end
	local zoffset = mapSizeZ * (1 - zfit) / 2
	overviewEvent:addSubject(-2, { x, overviewY, -zoffset })
	overviewEvent:addSubject(-3, { x, overviewY, mapSizeZ + zoffset })

	return overviewEvent
end
-- eventProcessor - perform processing and return truthy to remove the event
local function purgeEvents(eventProcessor, opts)
	local event = tailEvent
	while event ~= nil do
		local nextEvent = event.next
		if eventProcessor(event, opts) then
			headEvent, tailEvent = removeElement(event, headEvent, tailEvent)
		end
		event = nextEvent
	end
end

local function __purgeExcludes(event, opts)
	return opts.excluder:excludes(event)
end

local function __purgeSubject(event, opts)
  return event:removeSubject(opts.unitID)
end

local function __purgeCommands(event, opts)
	if event.type ~= attackEventType and event.type ~= unitMovingEventType then
		return false
	end
	return event:removeSubject(opts.unitID)
end


local function _getEventPercentile(currentFrame, event)
	local importance = event:importanceAtFrame(currentFrame)
	if importance <= 0 then
		return 0
	end
	local x, _, z = unpack(event.location)
	local interestModifier = interestGrid:getScore(x, z)
	return eventStatistics:getPercentile(event.type, importance * interestModifier)
end

-- Process the event, possibly removing it from the list
-- Return true if the event is still in the list
local function _processEvent(currentFrame, event)
	if event.deferFunc then
	  event.deferredFrom = event.deferredFrom or event.started
		event.started = currentFrame
		local defer, abort = event.deferFunc(event)
		if abort or event.deferredFrom - currentFrame > framesPerSecond * 16 then
			headEvent, tailEvent = removeElement(event, headEvent, tailEvent)
			return
		end
		if not defer then
			-- Stop deferring.
			event.deferFunc = nil
		end
	end

	if event:importanceAtFrame(currentFrame) <= 0 then
		headEvent, tailEvent = removeElement(event, headEvent, tailEvent)
		return
	end

	return true
end

local function selectMostInterestingEvent(currentFrame)
	-- Process events and update interest grid
	local event = tailEvent
	while event ~= nil do
		local nextEvent = event.next
		if _processEvent(currentFrame, event) and event.actorAllyTeam then
			local meanImportance = eventStatistics:getMean(event.type)
			local importanceAtFrame = event:importanceAtFrame(currentFrame)
			local interest = meanImportance and (importanceAtFrame / meanImportance) or 1
				-- FIXME: Could use allyteams of all involved parties?
			local x, _, z = unpack(event.location)
			interestGrid:add(x, z, event.actorAllyTeam, interest)
		end
		event = nextEvent
	end

	-- Update event statistics
	event = tailEvent
	while event ~= nil do
		local x, _, z = unpack(event.location)
		eventStatistics:logEvent(event.type, event.importance * interestGrid:getScore(x, z))
		event = event.next
	end

	-- Make sure we always include current event even if it's not in the list
	local mie, mostPercentile = showingEvent, showingEvent and _getEventPercentile(currentFrame, showingEvent) or 0
	event = tailEvent
	while event ~= nil do
		local eventPercentile = _getEventPercentile(currentFrame, event)
		if eventPercentile > mostPercentile and not event.deferFunc then
			mie, mostPercentile = event, eventPercentile
		end
		event = event.next
	end
	if logging >= LOG_DEBUG and mie then
		spEcho('mie', mie.type, mie.sbj, mostPercentile, mie.started)
	end
	return mie
end

-- EVENT DISPLAY

local camTypeTracking = 'tracking'
local camTypeOverview = 'overview'
local camDiagMin = 1000
local cameraAccel = worldGridSize * 1.2
local maxPanDistance = worldGridSize * 3
local mapEdgeBorder = worldGridSize * 0.5
local keepTrackingRange = worldGridSize * 1.5

local display, initialCameraState, camera
local userCameraOverrideFrame, lastMouseLocation = -1000, { -1, 0, -1 }

local function initCamera(cx, cy, cz, rx, ry, type)
	return { x = cx, y = cy, z = cz, xv = 0, yv = 0, zv = 0, rx = rx, ry = ry, fov = defaultFov, type = type }
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

local function updateDisplay(event)
	if display.noUpdateBeforeFrame > gameFrame then
		return false
	end

	local camAngle, camType, commentary = defaultRx, camTypeTracking, nil

	local actorName
	for actorID, _ in pairs(event.actors) do
		actorName = (actorName and "multiple") or teamInfo[actorID].name .. " (" .. teamInfo[actorID].allyTeamName .. ")"
	end
	actorName = actorName or "unknown"

	local sbjUnitCount = 0
	for _, _ in pairs(event._sbjUnits) do
		sbjUnitCount = sbjUnitCount + 1
	end
  local sbjString = __pluralize(event.sbjName, sbjUnitCount)

	if event.type == attackEventType then
		commentary = sbjString .. " is attacking"
  elseif event.type == hotspotEventType then
		commentary = "Something's going down here"
	elseif event.type == overviewEventType then
		camAngle = - pi / 2
		camType = camTypeOverview
		commentary = "Let's get an overview of the battlefield"
	elseif event.type == unitBuiltEventType then
		commentary = sbjString .. " built by " .. actorName
	elseif event.type == unitDamagedEventType then
		commentary = sbjString .. " under attack by " .. actorName
	elseif event.type == unitDestroyedEventType then
		local destroyer = __getUnitsNameString(event._objUnits)
		commentary = sbjString .. " destroyed by " .. destroyer .. " of " .. actorName
	elseif event.type == unitDestroyerEventType then
		commentary = sbjString .. " on a rampage"
	elseif event.type == unitMovingEventType then
		commentary = sbjString .. " moving"
	elseif event.type == unitTakenEventType then
		commentary = sbjString .. " captured by " .. actorName
	end

	display.camAngle = camAngle
	if display.camType ~= camType then
		-- It looks especially naff if we flip between camera types every second
		display.noUpdateBeforeFrame = gameFrame + framesPerSecond * 4
	end
	display.camType = camType

	-- We use keepPrevious to keep runs of track infos from the same event
	local keepPrevious = false
	for k, v in pairs(event._sbjUnits) do
		display.tracking = { unitID = k, location = v, previous = display.tracking, keepPrevious = keepPrevious }
		keepPrevious = true
	end
	for k, v in pairs(event._objUnits) do
		display.tracking = { unitID = k, location = v, previous = display.tracking, keepPrevious = keepPrevious }
		keepPrevious = true
	end

	-- Remove duplicates from tracking
	local tracked, trackInfo = {}, display.tracking
	while trackInfo do
		if tracked[trackInfo.unitID] then
			_, display.tracking = removeElement(trackInfo, nil, display.tracking)
		else
			tracked[trackInfo.unitID] = true
		end
		trackInfo = trackInfo.previous
	end

	commentary_cpl:SetText(commentary)

	return true
end

local function setupPanels()
	window_cpl = Window:New {
		parent = screen0,
		dockable = true,
		name = "replaycam",
		color = { 0, 0, 0, 0 },
		x = 100,
		y = 200,
		width = 500,
		height = 100,
		padding = { 0, 0, 0, 0 };
		draggable = false,
		resizable = false,
		tweakDraggable = true,
		tweakResizable = true,
		minimizable = false,
	}
	panel_cpl = ScrollPanel:New {
		parent = window_cpl,
		width = "100%",
		height = "100%",
		padding = { 4, 4, 4, 4 },
		scrollbarSize = 6,
		horizontalScrollbar = false,
	}
	commentary_cpl = Chili.TextBox:New {
		parent = panel_cpl,
		width = "100%",
		x = 0,
		y = 0,
		fontSize = 16,
		text = "The quiet before the storm.",
	}
end

function widget:Shutdown()
  spSetCameraState(initialCameraState, 0)
end

function widget:Initialize()
	if not WG.Chili or not (spIsReplay() or spGetSpectatingState()) then
		spEcho("DEACTIVATING " .. widget:GetInfo().name .. " as not spec")
		widgetHandler:RemoveWidget()
		return
	end

	Chili = WG.Chili
	Window = Chili.Window
	ScrollPanel = Chili.ScrollPanel
	screen0 = Chili.Screen0

	-- Init teams.
	teamInfo = {}
	local allyTeams = spGetAllyTeamList()
	for _, allyTeam in pairs(allyTeams) do
		local teamList = spGetTeamList(allyTeam)

		local allyTeamName = spGetGameRulesParam("allyteam_long_name_" .. allyTeam)
		if string.len(allyTeamName) > 10 then
			allyTeamName = spGetGameRulesParam("allyteam_short_name_" .. allyTeam)
		end

		for _, teamID in pairs(teamList) do
			local teamLeader = nil
			_, teamLeader = spGetTeamInfo(teamID)
			local teamName = "unknown"
			if (teamLeader) then
				teamName = spGetPlayerInfo(teamLeader)
			end
			teamInfo[teamID] = {
				allyTeam = allyTeam,
				allyTeamName = allyTeamName,
				color = { spGetTeamColor(teamID) } or { 1, 1, 1, 1 },
				name = teamName
			}
		end
	end

	interestGrid = WorldGrid:new({ xSize = mapGridX, ySize = mapGridZ, gridSize = worldGridSize, allyTeams = allyTeams })
	unitInfo = UnitInfoCache:new({ locationListener = function(x, _, z, allyTeam, isMoving)
		local interest = 1
		if not isMoving then
			-- Static things aren't themselves very interesting but count for #teams
			interest = 0.16
		end
		interestGrid:add(x, z, allyTeam, interest)
	end})

	setupPanels()

	initialCameraState = spGetCameraState()

	local cx, cy, cz = spGetCameraPosition()
	display = {
	  camAngle = defaultRx,
		diag = 0,
		location = { mapSizeX / 2, -1000, mapSizeZ / 2 },
		noUpdateBeforeFrame = 0,
		velocity = { 0, 0, 0 }
	}
	updateDisplay(addOverviewEvent(1))
	camera = initCamera(cx, cy, cz, defaultRx, defaultRy, camTypeTracking)
end

function widget:GameFrame(frame)
	gameFrame = frame
	unitInfo:update(frame)

	if (frame % updateIntervalFrames ~= 0) then
		return
	end

	local x, _, z = unpack(display.location)
	interestGrid:setWatching(x, z)

	local igMax, igX, igZ = interestGrid:statistics()
	if igMax >= interestGrid:getInterestingScore() then
		local units = spGetUnitsInRectangle (igX - worldGridSize / 2, igZ - worldGridSize / 2, igX + worldGridSize / 2, igZ + worldGridSize / 2)
		local hotspotEvent
		for _, unitID in pairs(units) do
			local location, _, _, _, isStatic = unitInfo:get(unitID)
			if not isStatic then
				hotspotEvent = hotspotEvent or addEvent(nil, 10 * igMax, { igX, spGetGroundHeight(igX, igZ), igZ }, nil, hotspotEventType, hotspotEventType, -1, nil, { noMerge = true })
				hotspotEvent:addSubject(unitID, location)
			end
		end
	end

	addOverviewEvent(100 / igMax)

	local mie = selectMostInterestingEvent(frame)
	if mie and mie ~= showingEvent and updateDisplay(mie) then
		if showingEvent then
			-- Avoid showing it again
			headEvent, tailEvent = removeElement(showingEvent, headEvent, tailEvent)
		end
		purgeEvents(__purgeExcludes, { excluder = mie })
		-- Set a standard decay so that we don't show the event for too long.
		mie.decay, mie.started = 0.20, frame
		showingEvent = mie
	end

	interestGrid:reset()
end

local function userAction()
	-- Override camera movements for a short time.
  userCameraOverrideFrame = gameFrame + framesPerSecond
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

local function _deferCommandEvent(event)
	local meta = event.meta
	local sbjLocation, sbjv = unitInfo:get(meta.sbjUnitID)
	if not sbjLocation or not sbjv then
		return false, true
	end
	local defer = distance(event.location, sbjLocation) > meta.deferRange + distance(sbjv) * framesPerSecond * 2.5
	if not defer then
		local trgx, _, trgz = unpack(event.location)
		interestGrid:add(trgx, trgz, meta.sbjAllyTeam, 1)
	end
	return defer, false
end

function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOpts, cmdTag)
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

	if cmdID == CMD_MOVE or cmdID == CMD_ATTACK_MOVE then
		-- Process move event.

		local sbjLocation, _, importance, sbjName, isStatic = unitInfo:get(unitID)
		if isStatic then
			-- Not interested in move commands given to static buildings e.g. factories
			return
		end

		local trgx, trgy, trgz = unpack(cmdParams)
		local trgLocation = { trgx, trgy, trgz }

		local moveDistance = distance(trgLocation, sbjLocation)
		if (moveDistance < 512) then
			-- Ignore smaller moves to keep event numbers down and help ignore unitAI
			return
		end

		-- Shouldn't display a superseded command
		purgeEvents(__purgeCommands, { unitID = unitID })

		local meta = { sbjAllyTeam = teamInfo[unitTeam].allyTeam, sbjUnitID = unitID, deferRange = worldGridSize / 2 }
		local event = addEvent(unitTeam, importance, sbjLocation, meta, sbjName, unitMovingEventType, unitID, _deferCommandEvent)
		-- HACK: Event location should be the target location, not the subject location
		event.location = trgLocation
		event:addObject(-unitID, trgLocation)
	elseif cmdID == CMD_ATTACK then
		-- Process attack event
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

		-- Shouldn't display a superseded command
		purgeEvents(__purgeCommands, { unitID = unitID })

		local sbjLocation, _, _, sbjName, _, weaponImportance, weaponRange = unitInfo:get(unitID)
		local sbjAllyTeam = teamInfo[unitTeam].allyTeam
		-- HACK: Silo is weird.
		unitID = spGetUnitRulesParam(unitID, 'missile_parentSilo') or unitID
		local meta = { sbjAllyTeam = sbjAllyTeam, sbjUnitID = unitID, deferRange = weaponRange }
		local event = addEvent(unitTeam, weaponImportance, sbjLocation, meta, sbjName, attackEventType, unitID, _deferCommandEvent)
		-- HACK: Event location should be the target location, not the subject location
		event.location = trgLocation
		event:addObject(attackedUnitID or -unitID, trgLocation)
	end
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer, weaponDefID, projectileID, attackerID, attackerDefID, attackerTeam)
	if paralyzer then
		-- Paralyzer weapons deal very high "damage", but it's not as important as real damage
		damage = damage / 2
	end
	local sbjLocation, _, unitImportance, sbjName = unitInfo:get(unitID)
	local currentHealth, maxHealth, _, _, buildProgress = spGetUnitHealth(unitID)
	-- currentHealth can be 0, also avoid skewing the score overly much
	currentHealth = max(currentHealth, maxHealth / 16)
	-- Percentage of current health being dealt in damage, up to 100
	local importance = 100 * min(currentHealth, damage) / currentHealth
	-- Multiply by unit importance factor
	importance = importance * unitImportance * buildProgress

	addEvent(attackerTeam, importance, sbjLocation, nil, sbjName, unitDamagedEventType, unitID)
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
	local destroyedLocation, _, importance, destroyedName = unitInfo:get(unitID)
	unitInfo:forget(unitID)
	purgeEvents(__purgeSubject, { unitID = unitID })

	if not destroyedLocation or not importance or not destroyedName then
		-- Might happen if an uncached unit is destroyed and fails to retrieve current location
		return
	end

	if not attackerTeam then
		-- Attempt to ignore cancelled builds and other similar things like comm upgrade
		return
	end

	local unitDef = UnitDefs[unitDefID]
	if unitDef.customParams.dontcount then
		-- Ignore dontcount units e.g. terraunit
		return
	end

	local destroyerLocation, _, _, destroyerName = unitInfo:get(attackerID)
	local destroyedEvent = addEvent(attackerTeam, importance, destroyedLocation, nil, destroyedName, unitDestroyedEventType, unitID)
	destroyedEvent:addObject(attackerID, destroyerLocation)
	local destroyerEvent = addEvent(unitTeam, importance, destroyerLocation, nil, destroyerName, unitDestroyerEventType, attackerID)
	destroyerEvent:addObject(unitID, destroyedLocation)
	-- It would be naff to show both
	destroyedEvent:addExcludes(destroyerEvent)
  destroyerEvent:addExcludes(destroyedEvent)
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	local allyTeam = teamInfo[unitTeam].allyTeam
	local sbjLocation, _, importance, sbjName = unitInfo:watch(unitID, allyTeam, unitDefID)
	addEvent(unitTeam, importance, sbjLocation, nil, sbjName, unitBuiltEventType, unitID)
end

function widget:UnitTaken(unitID, unitDefID, oldTeam, newTeam)
	-- Note that UnitTaken (and UnitGiven) are both called for both capture and release.
	local captureController = spGetUnitRulesParam(unitID, "capture_controller");
	if not captureController or captureController == -1 then
		return
	end

	local sbjLocation, _, importance, sbjName = unitInfo:get(unitID)
	local event = addEvent(newTeam, importance, sbjLocation, nil, sbjName, unitTakenEventType, unitID)
	local capturerLocation =  unitInfo:get(captureController)
	event:addObject(captureController, capturerLocation)
end

local function calcCamRange(diag, fov)
	return diag / 2 / tan(rad(fov / 2))
end

local function updateCamera(dt)
	if logging >= LOG_DEBUG and dt > 0.05 then
		spEcho('slow camera update', dt)
	end

	local xSum, ySum, zSum, xvSum, yvSum, zvSum, trackedLocationCount = 0, 0, 0, 0, 0, 0, 0
	local xMin, xMax, zMin, zMax = huge, -huge, huge, -huge
	local trackInfo, nextTrackInfo = display.tracking, nil
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
		if (nextTrackInfo and nextTrackInfo.keepPrevious) or length(nxMax - nxMin, nzMax - nzMin) <= keepTrackingRange then
			xMin, xMax, zMin, zMax = nxMin, nxMax, nzMin, nzMax
			xSum, ySum, zSum = xSum + x, ySum + y, zSum + z
			trackedLocationCount = trackedLocationCount + 1
			nextTrackInfo = trackInfo
			trackInfo = trackInfo.previous
		else
			if nextTrackInfo then
				nextTrackInfo.previous = nil
			end
			trackInfo = nil
		end
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
		local damping = 0.8
		display.diag = applyDamping(display.diag, tdiag, damping, dt)
		display.location = _apply2(applyDamping, display.location, tlocation, damping, dt)
		display.velocity = _apply2(applyDamping, display.velocity, tvelocity, damping, dt)
	else
		display.diag = tdiag
		display.location = tlocation
		display.velocity = tvelocity
	end

	-- Smoothly move to the location of the event.
	-- Camera position and vector
	local cx, cy, cz, cxv, cyv, czv = camera.x, camera.y, camera.z, camera.xv, camera.yv, camera.zv
	local crx, cry, cfov = camera.rx, camera.ry, camera.fov
	-- Event location
	local ex, ey, ez = unpack(display.location)
	local exv, eyv, ezv = unpack(display.velocity)
	ex, ey, ez = ex + exv, ey + eyv, ez + ezv
	ex, ez = bound(ex, mapEdgeBorder, mapSizeX - mapEdgeBorder), bound(ez, mapEdgeBorder, mapSizeZ - mapEdgeBorder)
	-- Where do we *want* the camera to be ie: (t)arget
	local tcDist = calcCamRange(display.diag, defaultFov)
	local try = atan2(cx - ex, cz - ez) + pi
	-- HACK: It appears that translation occurs 1 render frame later than rotation,
	-- this is used to defer rotation by a frame when reorienting
	local deferRotationRenderFrames = camera.deferRotationRenderFrames and camera.deferRotationRenderFrames - 1
	cry = (deferRotationRenderFrames == 0 and try) or symmetricBound(try, cry, maxCamRPerSecond * dt)
	-- Calculate target position
	local tcDist2d = tcDist * cos(-display.camAngle)
	local tcx, tcy, tcz = ex + tcDist2d * sin(cry - pi), ey + tcDist * sin(-display.camAngle), ez + tcDist2d * cos(cry - pi)

	local doInstantTransition = length(tcx - cx, tcy - cy, tcz - cz) > maxPanDistance
	if doInstantTransition or display.camType == camTypeOverview then
		cx, cy, cz = ex + tcDist2d * sin(defaultRy - pi), tcy, ez + tcDist2d * cos(defaultRy - pi)
		cxv, cyv, czv = 0, 0, 0
		if doInstantTransition then
			-- HACK: Need to defer rotation by 1 frame, see earlier
			deferRotationRenderFrames = 1
		else
			-- FIXME: Simplify this else case (for overview) somehow
			crx, cry, cfov = display.camAngle, defaultRy, defaultFov
		end
	else
		-- Project out current vector
		local cv = length(cxv, cyv, czv)
		local px, py, pz = cx, cy, cz
		if (cv > 0) then
			local time = cv / cameraAccel
			px = px + cxv * time / 2
			py = py + cyv * time / 2
			pz = pz + czv * time / 2
		end
		-- Offset vector
		local ox, oy, oz = tcx - px, tcy - py, tcz - pz
		local od     = length(ox, oy, oz)
		-- Correction vector
		local dx, dy, dz = -cxv, -cyv, -czv
		if (od > 0) then
			-- Not 2 x d as we want to accelerate until half way then decelerate.
			local ov = sqrt(od * cameraAccel)
			dx = dx + ov * ox / od
			dy = dy + ov * oy / od
			dz = dz + ov * oz / od
		end
		local dv = length(dx, dy, dz)
		if (dv > 0) then
			cxv = cxv + dt * cameraAccel * dx / dv
			cyv = cyv + dt * cameraAccel * dy / dv
			czv = czv + dt * cameraAccel * dz / dv
		end
		cx = cx + dt * cxv
		cy = cy + dt * cyv
		cz = cz + dt * czv

		-- Rotate and zoom camera
		local trx = -atan2(cy - ey, length(cx - ex, cz - ez))
		crx = (deferRotationRenderFrames == 0 and display.camAngle) or symmetricBound(trx, crx, maxCamRPerSecond * dt)
		cfov = applyDamping(cfov, deg(2 * atan2(display.diag / 2, length(ex - cx, ey - cy, ez - cz))), 0.5, dt)
	end

	camera = { x = cx, y = cy, z = cz, xv = cxv, yv = cyv, zv = czv, rx = crx, ry = cry, fov = cfov, deferRotationRenderFrames = deferRotationRenderFrames }

	if userCameraOverrideFrame >= gameFrame then
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
end

function widget:Update(dt)
	local mx, my = spGetMouseState()
	local newMouseLocation = { mx, 0, my }
  if distance(newMouseLocation, lastMouseLocation) ~= 0 then
		lastMouseLocation = newMouseLocation
		userAction()
	end
	updateCamera(dt)
end
