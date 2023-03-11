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
local spGetGameFrame = Spring.GetGameFrame
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
local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitRulesParam = Spring.GetUnitRulesParam
local spGetUnitsInRectangle = Spring.GetUnitsInRectangle
local spGetUnitTeam = Spring.GetUnitTeam
local spGetUnitVelocity = Spring.GetUnitVelocity
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

-- CONFIGURATION

local debug = true
local updateIntervalFrames = framesPerSecond
local defaultFov, defaultRx, defaultRy = 45, -1.2, pi

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

-- Calculate x, z distance between two { x, y, z } points.
local function distance(p1, p2)
	local p1x, _, p1z = unpack(p1)
	local p2x, _, p2z = unpack(p2)
	return length(p1x - p2x, p1z - p2z)
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
			o.data[x][y] = { nil, nil, 0 }
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

function WorldGrid:_getScoreGridCoords(x, y)
	local interest, allyTeams, passe = unpack(self.data[x][y])
	local allyTeamCount = 0
	for _, _ in pairs(allyTeams) do
		allyTeamCount = allyTeamCount + 1
	end
	return interest * max(1, allyTeamCount * allyTeamCount) * (1 - passe)
end

function WorldGrid:getScore(x, y)
	x, y = self:__toGridCoords(x, y)
	return self:_getScoreGridCoords(x, y)
end

function WorldGrid:getInterestingScore()
	-- 4 is equal to 4 ally units, or 2 x 1 units from different ally teams.
	return 5 * updateIntervalFrames / framesPerSecond
end

function WorldGrid:_addInternal(x, y, radius, opts, func)
	if not radius then
		radius = self.gridSize
	end
	local gx, gy = self:__toGridCoords(x, y)

	-- Work out how to divvy the interest up around nearby grid squares.
	local areas, i, totalArea = {}, 1, 0
	for ix = gx - 1, gx + 1 do
		for iy = gy - 1, gy + 1 do
			if ix >= 1 and ix <= self.xSize and iy >= 1 and iy <= self.ySize then
				areas[i] = self:_intersectArea(x - radius / 2, y - radius / 2, x + radius / 2, y + radius / 2,
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

function WorldGrid:add(x, y, allyTeam, interest, radius)
	return self:_addInternal(x, y, radius, { allyTeam = allyTeam, interest = interest }, _addInterest)
end

-- Call this exactly once between each reset.
-- When watching an area we apply a fixed boost to make things sticky,
-- but a longer-term negative factor (passe) to encourage moving.
function WorldGrid:setWatching(x, y)
	-- Note: boost is spread over a 2x2 grid.
	self:_addInternal(x, y, self.gridSize * 2, { boost = 10 }, _boostInterest)
	self:_addInternal(x, y, self.gridSize, { passe = 0.1 }, _addPasse)
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
			data[3] = data[3] * 0.9
		end
	end
end

-- Return mean, max, maxX, maxY
function WorldGrid:statistics()
	local maxValue, maxX, maxY, total = -1, nil, nil, 0
	for x = 1, self.xSize do
		for y = 1, self.ySize do
			local value = self:_getScoreGridCoords(x, y)
			total = total + value
			if maxValue < value then
				maxValue = value
				maxX = x
				maxY = y
			end
		end
	end
	return total / (self.xSize * self.ySize), maxValue, (maxX - 0.5) * self.gridSize, (maxY - 0.5) * self.gridSize
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
	-- cacheObject {}
	-- 1 - allyTeam
	-- 2 - unitDefID
	-- 3 - lastUpdatedFrame
	-- 4 - last known x
	-- 5 - last known y
	-- 6 - last known z
	-- 7 - last known velocity
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
		local isStatic = not spGetMovetype(unitDef)
		local wImportance, wRange = self:_weaponStats(unitDef)
		cacheObject = { importance, isStatic, wImportance, wRange }
		self._unitStatsCache[unitDefID] = cacheObject
	end
	return unpack(cacheObject)
end

function UnitInfoCache:_updatePosition(unitID, cacheObject)
	local x, y, z = spGetUnitPosition(unitID)
	local xv, _, zv = spGetUnitVelocity(unitID)
	if not x or not y or not z or not xv or not zv then
		if debug then
			spEcho("ERROR! UnitInfoCache:_updatePosition failed", unitID, UnitDefs[cacheObject[2]].name)
		end
		return false
	end
	local v = length(xv, zv)
	cacheObject[4] = x
	cacheObject[5] = y
	cacheObject[6] = z
	cacheObject[7] = v
	if self.locationListener then
		local isMoving = v > 0.1
		self.locationListener(x, y, z, cacheObject[1], isMoving)
	end
	return true
end

function UnitInfoCache:watch(unitID, allyTeam, unitDefID)
	local currentFrame = spGetGameFrame()
	if not unitDefID then
		unitDefID = spGetUnitDefID(unitID)
	end
	local cacheObject = { allyTeam, unitDefID, currentFrame, 0, 0, 0, 0 }
	self:_updatePosition(unitID, cacheObject)
	self.cache[unitID] = cacheObject
	return self:get(unitID)
end

-- Returns unit info including rough position.
function UnitInfoCache:get(unitID)
	local cacheObject = self.cache[unitID]
	if cacheObject then
		local _, unitDefID, _, x, y, z, v = unpack(cacheObject)
		local importance, isStatic, weaponImportance, weaponRange = self:_unitStats(unitDefID)
		return x, y, z, v, importance, isStatic, weaponImportance, weaponRange
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
	local x, y, z, v, importance, isStatic = self:get(unitID)
	self.cache[unitID] = nil
	return x, y, z, v, importance, isStatic
end

function UnitInfoCache:update(currentFrame)
	for unitID, cacheObject in pairs(self.cache) do
		local lastUpdated = cacheObject[3]
		if (currentFrame - lastUpdated) > unitInfoCacheFrames then
			cacheObject[3] = currentFrame
			if not self:_updatePosition(unitID, cacheObject) then
				-- Something went wrong, drop from cache.
				self.cache[unitID] = nil
			end
		end
	end
end

-- EVENT

Event = {}

function Event:new(o)
	o = o or {} -- create object if user does not provide one
	setmetatable(o, self)
	self.__index = self

	o._unitCount = 0
  o._units = {}
	return o
end

function Event:importanceAtFrame(frame)
  return self.importance * (1 - self.decay * (frame - self.started) / framesPerSecond)
end

function Event:addUnit(unitID, location)
	if not self._units[unitID] then
		if unitID > 0 then
			self._unitCount = self._unitCount + 1
		end
		self._units[unitID] = location
	end
end

function Event:removeUnit(unitID)
	if self._units[unitID] then
		self._unitCount = self._unitCount - 1
		self._units[unitID] = nil
	end
end

function Event:unitCount()
	return self._unitCount
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
	local count, meanImportance = unpack(self[type])
	local newCount = count + 1

	-- Switch to a weighted mean after a certain number of events, for faster adaptation.
	local switchCount = 32
	if newCount > switchCount then
		count = switchCount - 1
		newCount = switchCount
	end

	meanImportance = meanImportance * count / newCount + importance / newCount
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

-- GUI COMPONENTS

local window_cpl, panel_cpl, commentary_cpl

-- EVENT TRACKING

local attackEventType = "attack"
local hotspotEventType = "hotspot"
local overviewEventType = "overview"
local unitBuiltEventType = "unitBuilt"
local unitDamagedEventType = "unitDamaged"
local unitDestroyedEventType = "unitDestroyed"
local unitMovingEventType = "unitMoving"
local unitTakenEventType = "unitTaken"
local eventTypes = {
	attackEventType,
	hotspotEventType,
	overviewEventType,
	unitBuiltEventType,
	unitDamagedEventType,
	unitDestroyedEventType,
	unitMovingEventType,
	unitTakenEventType
}

local eventMergeRange = 256

-- Linear decay rate
local decayPerSecond = {
	attack = 1,
	hotspot = 1,
	overview = 1,
	unitBuilt = 0.05,
	unitDamaged = 0.4,
	unitDestroyed = 0.1,
	unitMoving = 0.4,
	unitTaken = 0.1,
}

local eventStatistics = EventStatistics:new({
	-- Adjust mean of events in percentile estimation
	-- > 1: make each event seem more likely (less interesting)
	-- < 1: make each event seem less likely (more interesting)
	eventMeanAdj = {
		attack = 1.3,
		hotspot = 0.5,
		overview = 4.4,
		unitBuilt = 4.2,
		unitDamaged = 0.7,
		unitDestroyed = 0.6,
		unitMoving = 2.0,
		unitTaken = 0.2,
	}
}, eventTypes)

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
local function addEvent(actor, importance, location, meta, type, unit, unitDef, deferFunc)
	local frame = spGetGameFrame()
	local sbj = {}
	if unit then
		sbj = spGetHumanName(UnitDefs[unitDef], unit)
	end
	local decay = decayPerSecond[type]

	-- Try to merge into recent events.
	local considerForMergeAfterFrame = frame - framesPerSecond
	local event = headEvent
	while event ~= nil do
		local nextEvent = event.previous
		if event.started < considerForMergeAfterFrame then
			-- Don't want to check further back, so break.
			event = nil
			break
		end
		local importanceAtFrame = event:importanceAtFrame(frame)
		if importanceAtFrame <= 0 then
			-- Just remove the event forever.
			headEvent, tailEvent = removeElement(event, headEvent, tailEvent)
		elseif event.type == type and event.sbj == sbj and distance(event.location, location) < eventMergeRange then
			-- Merge new event into old.
			event.importance = importanceAtFrame + importance
			event.decay = decay
			event.location = location
			event.started = frame
			if actor and not event.actors[actor] then
				event.actorCount = event.actorCount + 1
				event.actors[actor] = actor
			end
			if unit then
				event:addUnit(unit, location)
			end

			-- Remove it and attach at head later.
			headEvent, tailEvent = removeElement(event, headEvent, tailEvent)

			-- We merged, so break.
			break
		end
		event = nextEvent
	end

	if not event then
		event = Event:new({
			actorCount = 1,
			actors = initTable(actor, true),
			deferFunc = deferFunc,
			importance = importance,
			decay = decay,
			location = location,
			meta = meta,
			sbj = sbj,
			started = frame,
			type = type
		})
		if unit then
		  event:addUnit(unit, location)
		end
	end

	eventStatistics:logEvent(type, importance * interestGrid:getScore(location[1], location[3]))

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

local function purgeEventsOfUnit(unitID)
	local event = tailEvent
	while event ~= nil do
		local nextEvent = event.next
		-- Keep unit if it was destroyed as we'll track its destroyed location.
		if event.type ~= unitDestroyedEventType then
			event:removeUnit(unitID)
			if event:unitCount() == 0 then
				headEvent, tailEvent = removeElement(event, headEvent, tailEvent)
			end
		end
		event = nextEvent
	end
end

local function _getEventPercentile(currentFrame, event)
	local importance = event:importanceAtFrame(currentFrame)
	if importance <= 0 then
		return
	end
	local x, _, z = unpack(event.location)
	local interestModifier = interestGrid:getScore(x, z)
	return eventStatistics:getPercentile(event.type, importance * interestModifier)
end

local function _processEvent(currentFrame, event)
	if event.deferFunc then
	  event.deferredFrom = event.deferredFrom or event.started
		event.started = currentFrame
		-- TODO: Check if event in command queue, if not then remove it.
		local defer, abort = event.deferFunc(event)
		if abort or event.deferredFrom - currentFrame > framesPerSecond * 8 then
			headEvent, tailEvent = removeElement(event, headEvent, tailEvent)
			return
		elseif defer then
			-- Try it again later.
			return
		end
		-- Stop deferring.
		event.deferFunc = nil
	end
	local percentile = _getEventPercentile(currentFrame, event)
	if not percentile then
		headEvent, tailEvent = removeElement(event, headEvent, tailEvent)
	end
	return percentile
end

local function selectMostImportantEvent()
	local currentFrame = spGetGameFrame()
	-- Make sure we always include current event even if it's not in the list.
	local mie, mostPercentile, event = showingEvent, showingEvent and _getEventPercentile(currentFrame, showingEvent) or 0, tailEvent
	while event ~= nil do
		-- Get next event before we process the current one, as this may nil out .next.
		local nextEvent = event.next
		local eventPercentile = _processEvent(currentFrame, event)
		if eventPercentile and eventPercentile > mostPercentile then
			mie, mostPercentile = event, eventPercentile
		end
		event = nextEvent
	end
	if debug and mie then
		spEcho('mie:', mie.type, mie.sbj, mostPercentile)
	end
	return mie
end

-- EVENT DISPLAY

local camDiagMin = 1000
local cameraAccel = worldGridSize * 1.2
local maxPanDistance = worldGridSize * 3
local mapEdgeBorder = worldGridSize * 0.5
local keepTrackingRange = worldGridSize * 1.5

local display = { camAngle = defaultRx, commentary = "The quiet before the storm", location = nil, tracking = nil }
local initialCameraState, camera
local userCameraOverrideFrame, lastMouseLocation = -1000, { -1, 0, -1 }

local function initCamera(cx, cy, cz, rx, ry)
	return { x = cx, y = cy, z = cz, xv = 0, yv = 0, zv = 0, rx = rx, ry = ry, fov = defaultFov }
end

local function updateDisplay(event)
	local camAngle, commentary = defaultRx, nil
	local actorID = pairs(event.actors)(event.actors)

	local actorName = "unknown"
	if (actorID) then
		actorName = teamInfo[actorID].name .. " (" .. teamInfo[actorID].allyTeamName .. ")"
	end

	if event.type == attackEventType then
		commentary = event.sbj .. " is attacking"
  elseif event.type == hotspotEventType then
		commentary = "Something's going down here"
	elseif event.type == overviewEventType then
		camAngle = - pi / 2
		commentary = "Let's get an overview of the battlefield"
	elseif event.type == unitBuiltEventType then
		commentary = event.sbj .. " built by " .. actorName
	elseif event.type == unitDamagedEventType then
		commentary = event.sbj .. " under attack"
	elseif event.type == unitDestroyedEventType then
		commentary = event.sbj .. " destroyed by " .. actorName
	elseif event.type == unitMovingEventType then
		local quantityPrefix, unitCount = " ", event:unitCount()
		if unitCount > 5 then
			quantityPrefix = " batallion "
		elseif unitCount > 2 then
			quantityPrefix = " team "
		end
		commentary = event.sbj .. quantityPrefix .. "moving"
	elseif event.type == unitTakenEventType then
		commentary = event.sbj .. " captured by " .. actorName
	end

	display.camAngle = camAngle
	display.commentary = commentary
	display.location = event.location

	-- We use keepPrevious to keep runs of track infos from the same event
	local keepPrevious = false
	for k, v in pairs(event._units) do
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
	if not WG.Chili or not (spIsReplay() and spGetSpectatingState()) then
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
	camera = initCamera(cx, cy, cz, defaultRx, defaultRy)
end

function widget:GameFrame(frame)
	unitInfo:update(frame)

	if (frame % updateIntervalFrames ~= 0) then
		return
	end

	if display.location then
		local x, _, z = unpack(display.location)
		interestGrid:setWatching(x, z)
	end

	local _, igMax, igX, igZ = interestGrid:statistics()
	if igMax >= interestGrid:getInterestingScore() then
		local units = spGetUnitsInRectangle (igX - worldGridSize / 2, igZ - worldGridSize / 2, igX + worldGridSize / 2, igZ + worldGridSize / 2)
		if #units > 0 then
			local event = addEvent(nil, 10 * igMax, { igX, spGetGroundHeight(igX, igZ), igZ }, nil, hotspotEventType, nil, nil)
			for _, unitID in pairs(units) do
				local x, y, z = unitInfo:get(unitID)
				event:addUnit(unitID, { x, y, z })
			end
		end
	end
	local overviewY = spGetGroundHeight(mapSizeX / 2, mapSizeZ / 2)
	local overviewEvent = addEvent(nil, 100 / igMax, { mapSizeX / 2, overviewY, mapSizeZ / 2 }, nil, overviewEventType, nil, nil)
	-- Set two "units" at the corners so that we calculate the correct camera range
	overviewEvent:addUnit(-1, { 0, overviewY, 0})
	overviewEvent:addUnit(-2, { mapSizeX, overviewY, mapSizeZ})

	local newEvent = selectMostImportantEvent()
	if newEvent and newEvent ~= showingEvent then
		-- Avoid coming back to the previous event
		if showingEvent then
			headEvent, tailEvent = removeElement(showingEvent, headEvent, tailEvent)
		end

		updateDisplay(newEvent, frame)
		commentary_cpl:SetText(display.commentary)
		-- Set a standard decay so that we don't show the event for too long.
		newEvent.decay, newEvent.started = 0.20, frame

		showingEvent = newEvent
	end

	interestGrid:reset()
end

local function userAction()
	-- Override camera movements for a short time.
  userCameraOverrideFrame = spGetGameFrame() + framesPerSecond
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
	local sbjUnitID = meta.sbjUnitID
	local sbjx, sbjy, sbjz, sbjv = unitInfo:get(sbjUnitID)
	if not sbjx or not sbjy or not sbjz or not sbjv then
		return false, true
	end
	local defer = distance(event.location, { sbjx, sbjy, sbjz }) > meta.deferRange + sbjv * framesPerSecond * 2.5
	if not defer then
		local vctx, _, vctz = unpack(event.location)
		interestGrid:add(vctx, vctz, meta.sbjAllyTeam, 1)
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

		local x, y, z, _, importance, isStatic = unitInfo:get(unitID)
		if isStatic then
			-- Not interested in move commands given to static buildings e.g. factories
			return
		end

		local sbjLocation = { x, y, z }
		local trgx, trgy, trgz = unpack(cmdParams)
		local trgLocation = { trgx, trgy, trgz }

		local moveDistance = distance(trgLocation, sbjLocation)
		if (moveDistance < 512) then
			-- Ignore smaller moves to keep event numbers down and help ignore unitAI
			return
		end
		local meta = { sbjAllyTeam = teamInfo[unitTeam].allyTeam, sbjUnitID = unitID, deferRange = worldGridSize / 2 }
		local event = addEvent(unitTeam, importance, sbjLocation, meta, unitMovingEventType, unitID, unitDefID, _deferCommandEvent)
		-- Hack: we want the subject to be the "actor" but the event location to be the target.
		event.location = trgLocation
		event:addUnit(-unitID, trgLocation)
	elseif cmdID == CMD_ATTACK then
		-- Process attack event
		local trgx, trgy, trgz, attackedUnitID
		-- Find the location / unit being attacked.
		if #cmdParams == 1 then
			attackedUnitID = cmdParams[1]
			trgx, trgy, trgz = unitInfo:get(attackedUnitID)
		else
			trgx, trgy, trgz = unpack(cmdParams)
		end
		if not trgx or not trgy or not trgz then
			return
		end
		local trgLocation = { trgx, trgy, trgz }
		local x, y, z, _, _, _, weaponImportance, weaponRange = unitInfo:get(unitID)
		local sbjAllyTeam = teamInfo[unitTeam].allyTeam
		-- HACK: Silo is weird.
		unitID = spGetUnitRulesParam(unitID, 'missile_parentSilo') or unitID
		local meta = { sbjAllyTeam = sbjAllyTeam, sbjUnitID = unitID, deferRange = weaponRange }
		local event = addEvent(unitTeam, weaponImportance, { x, y, z }, meta, attackEventType, unitID, unitDefID, _deferCommandEvent)
		-- Hack: we want the subject to be the "actor" but the event location to be the target.
		event.location = trgLocation
		event:addUnit(attackedUnitID or -unitID, trgLocation)
	end
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer, weaponDefID, projectileID, attackerID, attackerDefID, attackerTeam)
	if paralyzer then
		-- Paralyzer weapons deal very high "damage", but it's not as important as real damage
		damage = damage / 2
	end
	local x, y, z, _, unitImportance = unitInfo:get(unitID)
	local currentHealth, maxHealth, _, _, buildProgress = spGetUnitHealth(unitID)
	-- currentHealth can be 0, also avoid skewing the score overly much
	currentHealth = max(currentHealth, maxHealth / 16)
	-- Percentage of current health being dealt in damage, up to 100
	local importance = 100 * min(currentHealth, damage) / currentHealth
	-- Multiply by unit importance factor
	importance = importance * unitImportance * buildProgress

	addEvent(attackerTeam, importance, { x, y, z }, nil, unitDamagedEventType, unitID, unitDefID)
	interestGrid:add(x, z, teamInfo[unitTeam].allyTeam, 0.2)
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
	local x, y, z, importance = unitInfo:forget(unitID)
	purgeEventsOfUnit(unitID)

	if (not attackerTeam) then
		-- Attempt to ignore cancelled builds and other similar things like comm upgrade
		return
	end

	local unitDef = UnitDefs[unitDefID]
	if (unitDef.customParams.dontcount) then
		-- Ignore dontcount units e.g. terraunit
		return
	end

	local event = addEvent(attackerTeam, importance or unitDef.metalCost, { x, y, z }, nil, unitDestroyedEventType, unitID, unitDefID)
	x, y, z = spGetUnitPosition(attackerID)
	event:addUnit(attackerID, { x, y, z })
	-- Areas where units are being destroyed are particularly interesting, and
	-- also the destroyed unit will no longer count, so add some extra interest
	-- here.
	interestGrid:add(x, z, teamInfo[unitTeam].allyTeam, 1)
	interestGrid:add(x, z, teamInfo[attackerTeam].allyTeam, 1)
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	local allyTeam = teamInfo[unitTeam].allyTeam
	local x, y, z, _, importance = unitInfo:watch(unitID, allyTeam, unitDefID)
	addEvent(unitTeam, importance, { x, y, z }, nil, unitBuiltEventType, unitID, unitDefID)
end

function widget:UnitTaken(unitID, unitDefID, oldTeam, newTeam)
	-- Note that UnitTaken (and UnitGiven) are both called for both capture and release.
	local captureController = spGetUnitRulesParam(unitID, "capture_controller");
	if not captureController or captureController == -1 then
		return
	end

	local x, y, z, _, importance = unitInfo:get(unitID)
	local event = addEvent(newTeam, importance, { x, y, z}, nil, unitTakenEventType, unitID, unitDefID)
	x, y, z =  unitInfo:get(captureController)
	event:addUnit(captureController, { x, y, z })
end

local function calcCamRange(diag, fov)
	return diag / 2 / tan(rad(fov / 2))
end

local function updateCamera(dt)
	if not display then
		return
	end

	local xSum, ySum, zSum, xvSum, yvSum, zvSum, trackedLocationCount = 0, 0, 0, 0, 0, 0, 0
	local xMin, xMax, zMin, zMax = mapSizeX, 0, mapSizeZ, 0
	local trackInfo, nextTrackInfo = display.tracking, nil
	while trackInfo do
		local x, y, z
		if not trackInfo.isDead then
			x, y, z = spGetUnitPosition(trackInfo.unitID)
			local xv, yv, zv = spGetUnitVelocity(trackInfo.unitID)
			if x and y and z and xv and yv and zv then
				xvSum, yvSum, zvSum = xvSum + xv, yvSum + yv, zvSum + zv
				trackInfo.location = { x, y, z }
			else
				trackInfo.isDead = true
				x, y, z = unpack(trackInfo.location)
			end
		else
			x, y, z = unpack(trackInfo.location)
		end

		-- Accumulate tracking info if not too distant
		local nxMin, nxMax, nzMin, nzMax = min(xMin, x), max(xMax, x), min(zMin, z), max(zMax, z)
		if nextTrackInfo and nextTrackInfo.keepPrevious or distance({ nxMin, nil, nzMin }, { nxMax, nil, nzMax }) <= keepTrackingRange then
			xMin, xMax, zMin, zMax = nxMin, nxMax, nzMin, nzMax
			xSum, ySum, zSum = xSum + x, ySum + y, zSum + z
			trackedLocationCount = trackedLocationCount + 1
			nextTrackInfo = trackInfo
			trackInfo = trackInfo.previous
		else
			nextTrackInfo.previous = nil
			trackInfo = nil
		end
	end

	local boundingDiagLength = camDiagMin
	if trackedLocationCount > 0 then
		local ox, oy, oz = unpack(display.location)
		local nx = xSum / trackedLocationCount + xvSum / trackedLocationCount * framesPerSecond
		local ny = ySum / trackedLocationCount + yvSum / trackedLocationCount * framesPerSecond
		local nz = zSum / trackedLocationCount + zvSum / trackedLocationCount * framesPerSecond
		display.location = { applyDamping(ox, nx, 0.5, dt), applyDamping(oy, ny, 0.5, dt), applyDamping(oz, nz, 0.5, dt) }
		boundingDiagLength = distance({ xMin, nil, zMin }, { xMax, nil, zMax })
		-- Smoothly grade from camDiagMin to the boundingDiagLength when the latter is 2x the former
		boundingDiagLength = boundingDiagLength + max(0, camDiagMin - boundingDiagLength * 0.5)
		boundingDiagLength = max(camDiagMin, boundingDiagLength)
	end

	if userCameraOverrideFrame >= spGetGameFrame() then
		return
	end

	-- Smoothly move to the location of the event.
	-- Camera position and vector
	local cx, cy, cz, cxv, cyv, czv = camera.x, camera.y, camera.z, camera.xv, camera.yv, camera.zv
	local crx, cry, cfov = camera.rx, camera.ry, camera.fov
	-- Event location
	local ex, ey, ez = unpack(display.location)
	ex, ez = bound(ex, mapEdgeBorder, mapSizeX - mapEdgeBorder), bound(ez, mapEdgeBorder, mapSizeZ - mapEdgeBorder)
	-- Where do we *want* the camera to be ie: (t)arget
	local tcDist = calcCamRange(boundingDiagLength, defaultFov)
	local try = atan2(cx - ex, cz - ez) + pi
	-- Limit how much we rotate based on how far we are from the event
	try = cry + (try - cry) * min(1, 0.25 * length(ex - cx, ey - cy, ez - cz) / tcDist)
	-- Calculate target position
	local tcDist2d = tcDist * cos(-display.camAngle)
	local tcx, tcy, tcz = ex + tcDist2d * cos(try - pi / 2), ey + tcDist * sin(-display.camAngle), ez + tcDist2d * sin(try - pi / 2)

	if (length(tcx - cx, tcy - cy, tcz - cz) > maxPanDistance) then
		tcx, tcy, tcz = ex + tcDist2d * cos(defaultRy - pi / 2), tcy, ez + tcDist2d * sin(defaultRy - pi / 2)
		camera = initCamera(tcx, tcy, tcz, display.camAngle, defaultRy)
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
		local maxRyPerSecond = pi / 18
		crx = applyDamping(crx, -atan2(cy - ey, cz - ez), 0.5, dt)
		cry = symmetricBound(applyDamping(cry, try, 0.6, dt), cry, maxRyPerSecond * dt)
		cfov = applyDamping(cfov, deg(2 * atan2(boundingDiagLength / 2, length(ex - cx, ey - cy, ez - cz))), 0.5, dt)

		camera = { x = cx, y = cy, z = cz, xv = cxv, yv = cyv, zv = czv, rx = crx, ry = cry, fov = cfov }
	end

	local cameraState = spGetCameraState()
	cameraState.mode = 4
	cameraState.px = camera.x
	cameraState.py = camera.y
	cameraState.pz = camera.z
	cameraState.rx = camera.rx
	cameraState.ry = camera.ry
	cameraState.rz = 0
	cameraState.fov = camera.fov

	spSetCameraState(cameraState)
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
