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
local exp = math.exp
local floor = math.floor
local max = math.max
local min = math.min
local pi = math.pi
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

local debugText = "DEBUG"

local framesPerSecond = 30

-- CONFIGURATION

local updateIntervalFrames = framesPerSecond
local fov = 45

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
local function length(x, y)
	return sqrt(x * x + y * y)
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

function WorldGrid:_getScoreGridCoords(x, y)
	local data = self.data[x][y]
	local allyTeamCount = 0
	for _, _ in pairs(data[2]) do
		allyTeamCount = allyTeamCount + 1
	end
	return data[1] * allyTeamCount * allyTeamCount
end

function WorldGrid:getScore(x, y)
	x, y = self:__toGridCoords(x, y)
	return self:_getScoreGridCoords(x, y)
end

function WorldGrid:getInterestingScore()
	-- 4 is equal to 4 ally units, or 2 x 1 units from different ally teams.
	return 5 * updateIntervalFrames / framesPerSecond
end

function WorldGrid:add(x, y, allyTeam, interest, radius)
	if not radius then
		radius = self.gridSize
	end
	local gx, gy = self:__toGridCoords(x, y)

	-- Work out how to divvy the interest up around nearby grid squares.
	local proportions, i, totalArea = {}, 1, 0
	for ix = gx - 1, gx + 1 do
		for iy = gy - 1, gy + 1 do
			if ix >= 1 and ix <= self.xSize and iy >= 1 and iy <= self.ySize then
				proportions[i] = self:_intersectArea(x - radius / 2, y - radius / 2, x + radius / 2, y + radius / 2,
					(ix - 1) * self.gridSize, (iy - 1) * self.gridSize, ix * self.gridSize, iy * self.gridSize)
				totalArea = totalArea + proportions[i]
			end
			i = i + 1
		end
	end

	-- Divvy out the interest.
	i = 1
	for ix = gx - 1, gx + 1 do
		for iy = gy - 1, gy + 1 do
			if proportions[i] then
				local data = self.data[ix][iy]
				data[1] = data[1] + interest * proportions[i] / totalArea
				if allyTeam then
					data[2][allyTeam] = true
				end
			end
			i = i + 1
		end
	end
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
			self.data[x][y] = { 1, {} }
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
	local mult = tonumber(wdcp.statsprojectiles) or ((tonumber(wdcp.script_burst) or wd.salvoSize) * wd.projectiles)
	local weaponDamage = tonumber(wdcp.stats_damage) * mult
	local range = wdcp.truerange or wd.range
	return weaponDamage, range
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
		-- DEBUG: Why is this happening?
		spEcho("ERROR! UnitInfoCache:_updatePosition failed", unitID, UnitDefs[cacheObject[2]].name)
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

	return o
end

function Event:importanceAtFrame(frame)
  return self.importance * (1 - self.decay * (frame - self.started) / framesPerSecond)
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
local unitMovedEventType = "unitMoved"
local unitTakenEventType = "unitTaken"
local eventTypes = {
	attackEventType,
	hotspotEventType,
	overviewEventType,
	unitBuiltEventType,
	unitDamagedEventType,
	unitDestroyedEventType,
	unitMovedEventType,
	unitTakenEventType
}

local eventMergeRange = 256

local tailEvent = nil
local headEvent = nil

-- Linear decay rate
local decayPerSecond = {
	attack = 1,
	hotspot = 1,
	overview = 1,
	unitBuilt = 0.05,
	unitDamaged = 0.4,
	unitDestroyed = 0.1,
	unitMoved = 0.4,
	unitTaken = 0.1,
}

local eventStatistics = EventStatistics:new({
	-- Adjust mean of events in percentile estimation
	-- > 1: make each event seem more likely (less interesting)
	-- < 1: make each event seem less likely (more interesting)
	eventMeanAdj = {
		attack = 1.0,
		hotspot = 1.1,
		overview = 4.0,
		unitBuilt = 4.0,
		unitDamaged = 0.6,
		unitDestroyed = 0.6,
		unitMoved = 1.6,
		unitTaken = 0.2,
	}
}, eventTypes)

local showingEvent = nil
local display = nil

-- CAMERA TRACKING

local camRangeMax = 1600
local camRangeMin = 1000
local camera = nil

local function removeEvent(event)
	if event == headEvent then
		headEvent = event.previous
	end
	if event == tailEvent then
		tailEvent = event.next
	end
	if event.previous then
		event.previous.next = event.next
	end
	if event.next then
		event.next.previous = event.previous
	end
	event.previous = nil
	event.next = nil
end

-- deferFunc - Optional function taking the event as a parameter.
--             Useful for command events that may become interesting e.g. when units close range.
local function addEvent(actor, importance, location, meta, type, unit, unitDef, deferFunc)
	local frame = spGetGameFrame()
	local object = {}
	if unit then
		object = spGetHumanName(UnitDefs[unitDef], unit)
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
			removeEvent(event)
		elseif event.type == type and event.object == object and distance(event.location, location) < eventMergeRange then
			-- Merge new event into old.
			event.importance = importanceAtFrame + importance
			event.decay = decay
			event.location = location
			event.started = frame
			if (actor and not event.actors[actor]) then
				event.actorCount = event.actorCount + 1
				event.actors[actor] = actor
			end
			if (unit and not event.units[unit]) then
				event.unitCount = event.unitCount + 1
				event.units[unit] = location
			end

			-- Remove it and attach at head later.
			removeEvent(event)

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
			object = object,
			started = frame,
			type = type,
			unitCount = 1,
			units = initTable(unit, location)
		})
	end

	eventStatistics:logEvent(type, importance)

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
		if event.units[unitID] and event.type ~= unitDestroyedEventType then
			event.units[unitID] = nil
			event.unitCount = event.unitCount - 1
			if event.unitCount == 0 then
				event.importance = 0
				removeEvent(event)
			end
		end
		event = nextEvent
	end
end

local function _processEvent(currentFrame, event)
	if event.deferFunc then
	  event.deferredFrom = event.deferredFrom or event.started
		-- TODO: Check if event in command queue, if not then remove it.
		local defer, abort = event.deferFunc(event)
		if abort or event.deferredFrom - currentFrame > framesPerSecond * 8 then
			removeEvent(event)
			return
		elseif defer then
			-- Try it again later.
			event.started = currentFrame
			return
		end
	end
	local importance = event:importanceAtFrame(currentFrame)
	if importance <= 0 then
		removeEvent(event)
		return
	end
	local x, _, z = unpack(event.location)
	local interestModifier = 1 + interestGrid:getScore(x, z)
	return eventStatistics:getPercentile(event.type, importance * interestModifier)
end

local function selectNextEventToShow()
	local currentFrame = spGetGameFrame()
	local mostImportantEvent, mostPercentile, event = nil, 0, tailEvent
	while event ~= nil do
		-- Get next event before we process the current one, as this may nil out .next.
		local nextEvent = event.next
		local eventPercentile = _processEvent(currentFrame, event)
		if eventPercentile and eventPercentile > mostPercentile then
			mostImportantEvent, mostPercentile = event, eventPercentile
		end
		event = nextEvent
	end
	return mostImportantEvent
end

local function toDisplayInfo(event, frame)
	local camAngle, camRange, commentary = -1.2, camRangeMin, nil
	local actorID = pairs(event.actors)(event.actors)

	local actorName = "unknown"
	if (actorID) then
		actorName = teamInfo[actorID].name .. " (" .. teamInfo[actorID].allyTeamName .. ")"
	end

	if event.type == attackEventType then
		commentary = event.object .. " is attacking"
  elseif event.type == hotspotEventType then
		commentary = "Something's going down here"
	elseif event.type == overviewEventType then
		camAngle = - pi / 2
		camRange = 1.2 * max(mapSizeX, mapSizeZ) / tan(pi * fov / 180)
		commentary = "Let's get an overview of the battlefield"
	elseif event.type == unitBuiltEventType then
		commentary = event.object .. " built by " .. actorName
	elseif event.type == unitDamagedEventType then
		commentary = event.object .. " under attack"
	elseif event.type == unitDestroyedEventType then
		commentary = event.object .. " destroyed by " .. actorName
	elseif event.type == unitMovedEventType then
		local quantityPrefix = " "
		if (event.unitCount > 5) then
			quantityPrefix = " batallion "
		elseif (event.unitCount > 2) then
			quantityPrefix = " team "
		end
		commentary = event.object .. quantityPrefix .. "moving"
	elseif event.type == unitTakenEventType then
		commentary = event.object .. " captured by " .. actorName
	end

	return { camAngle = camAngle, camRange = camRange, commentary = commentary, location = event.location, shownAt = frame, tracking = event.units }
end

local function updateCamera(displayInfo, dt)
	local cameraAccel = worldGridSize * 2
	local maxPanDistance = worldGridSize * 3
	local mapEdgeBorder = worldGridSize * 0.5

	if (not displayInfo) then
		return
	end

	local tracking = displayInfo.tracking
	local xSum, ySum, zSum, xvSum, zvSum, trackedLocationCount = 0, 0, 0, 0, 0, 0
	local xMin, xMax, zMin, zMax = mapSizeX, 0, mapSizeZ, 0
	for unit, location in pairs(tracking) do
		local x, y, z = spGetUnitPosition(unit)
		local xv, _, zv = spGetUnitVelocity(unit)
		if x and y and z and xv and zv then
			location = { x, y, z }
			tracking[unit] = { x, y, z }
			xvSum, zvSum = xvSum + xv, zvSum + zv
		else
			x, y, z = unpack(location)
		end
		xMin, xMax, zMin, zMax = min(xMin, x), max(xMax, x), min(zMin, z), max(zMax, z)
		xSum, ySum, zSum = xSum + x, ySum + y, zSum + z
		trackedLocationCount = trackedLocationCount + 1
	end

	if trackedLocationCount > 0 then
		displayInfo.location = {
			xSum / trackedLocationCount + (xvSum / trackedLocationCount * framesPerSecond),
			ySum / trackedLocationCount,
			zSum / trackedLocationCount + (zvSum / trackedLocationCount * framesPerSecond),
		}
	end

	-- Smoothly move to the location of the event.
	-- Camera position and vector
	local cx, cy, cz, cxv, czv = camera.x, camera.y, camera.z, camera.xv, camera.zv
	-- Event location
	local ex, ey, ez = unpack(displayInfo.location)
	ex, ez = bound(ex, mapEdgeBorder, mapSizeX - mapEdgeBorder), bound(ez, mapEdgeBorder, mapSizeZ - mapEdgeBorder)
	-- Calculate height we want the camera at.
	local boundingDiagLength = distance({ xMin, nil, zMin }, { xMax, nil, zMax })
	local targetRange = ey + displayInfo.camRange + bound(boundingDiagLength + length(ex - cx, ez - cz), 0, camRangeMax - camRangeMin)
	local heightChange = (targetRange - cy) * dt
	cy = cy + heightChange

	if (length(ex - cx, ez - cz) > maxPanDistance) then
		cx = ex
		cy = ey + displayInfo.camRange
		cz = ez
		cxv = 0
		czv = 0
	else
		-- Project out current vector
		local cv = length(cxv, czv)
		local px, pz = cx, cz
		if (cv > 0) then
			local time = cv / cameraAccel
			px = px + cxv * time / 2
			pz = pz + czv * time / 2
		end
		-- Offset vector
		local ox, oz = ex - px, ez - pz
		local od     = length(ox, oz)
		-- Correction vector
		local dx, dz = -cxv, -czv
		if (od > 0) then
			-- Not 2 x d as we want to accelerate until half way then decelerate.
			local ov = sqrt(od * cameraAccel)
			dx = dx + ov * ox / od
			dz = dz + ov * oz / od
		end
		local dv = length(dx, dz)
		if (dv > 0) then
			cxv = cxv + dt * cameraAccel * dx / dv
			czv = czv + dt * cameraAccel * dz / dv
		end
		cx = cx + dt * cxv
		cz = cz + dt * czv
	end

	camera = {
		x = cx,
		y = cy,
		z = cz,
		xv = cxv,
		zv = czv
	}

	local cameraState = spGetCameraState()
	cameraState.mode = 4
	cameraState.px = cx
	cameraState.py = cy
	cameraState.pz = cz - cy / math.tan(displayInfo.camAngle)
	cameraState.rx = displayInfo.camAngle
	cameraState.ry = math.pi
	cameraState.rz = 0
	cameraState.fov = fov

	spSetCameraState(cameraState)
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

function widget:Initialize()
	local loadText = "LOADED "
	if (WG.Chili and (spIsReplay() or spGetSpectatingState())) then
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
				interest = 0.2
			end
			interestGrid:add(x, z, allyTeam, interest)
		end})

		setupPanels()
	else
		spEcho(loadText .. "AND REMOVED " .. widget:GetInfo().name)
		widgetHandler:RemoveWidget()
	end

	local cx, cy, cz = spGetCameraPosition()
	camera = {
		x = cx,
		y = cy,
		z = cz,
		xv = 0,
		zv = 0
	}
end

function widget:GameFrame(frame)
	unitInfo:update(frame)

	if (frame % updateIntervalFrames ~= 0) then
		return
	end

	local _, igMax, igX, igZ = interestGrid:statistics()
	interestGrid:reset()
	if igMax >= interestGrid:getInterestingScore() then
		local units = spGetUnitsInRectangle (igX - worldGridSize / 2, igZ - worldGridSize / 2, igX + worldGridSize / 2, igZ + worldGridSize / 2)
		if #units > 0 then
			local event = addEvent(nil, 10 * igMax, { igX, 0, igZ }, nil, hotspotEventType, nil, nil)
			for _, unit in pairs(units) do
				event.units[unit] = { igX, _, igZ }
			end
		end
	end
	addEvent(nil, 100 / igMax, { mapSizeX / 2, spGetGroundHeight(mapSizeX / 2, mapSizeZ / 2), mapSizeZ / 2 }, nil, overviewEventType, nil, nil)

	local newEvent = selectNextEventToShow()
	if newEvent and newEvent ~= showingEvent then
		-- Avoid coming back to the previous event
		if showingEvent then
			removeEvent(showingEvent)
		end

		-- We want the selected event to be a little sticky to avoid too much jumping,
		-- but we also want to make sure it goes away reasonably soon.
		newEvent.importance = newEvent.importance * 2.5
		newEvent.decay = 0.20
		newEvent.started = frame

		display = toDisplayInfo(newEvent, frame)

		-- Sticky locations.
		local x, _, z = unpack(display.location)
		interestGrid:add(x, z, nil, 2, worldGridSize * 2)

		commentary_cpl:SetText(display.commentary)
		
		showingEvent = newEvent
	end
end

local function _deferAttackEvent(event)
	-- TODO: Incorporate unit velocity.
	local attackerID = event.meta.attackerID
	local ux, uy, uz, uv, _, _, _, weaponRange = unitInfo:get(attackerID)
	if not ux or not uy or not uz or not uv then
		return false, true
	end
	local defer = distance(event.location, { ux, uy, uz }) > weaponRange + uv * 2.5
	if not defer then
		local x, _, z = unpack(event.location)
		interestGrid:add(x, z, event.meta.attackerAllyTeam, 1)
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
		local unitLocation = { x, y, z }

		local moveDistance = distance(cmdParams, unitLocation)
		if (moveDistance < 256) then
			-- Ignore smaller moves to keep event numbers down and help ignore unitAI
			return
		end
		addEvent(unitTeam, sqrt(moveDistance) * importance, unitLocation, nil, unitMovedEventType, unitID, unitDefID)
	elseif cmdID == CMD_ATTACK then
		-- Process attack event
		local ax, ay, az, attackedUnitID
		-- Find the location / unit being attacked.
		if #cmdParams == 1 then
			attackedUnitID = cmdParams[1]
			ax, ay, az = unitInfo:get(attackedUnitID)
		else
			ax, ay, az = unpack(cmdParams)
		end
		if ax and ay and az then
			local x, y, z, _, _, _, weaponImportance = unitInfo:get(unitID)
			local attackerAllyTeam = teamInfo[unitTeam].allyTeam
			local event = addEvent(unitTeam, weaponImportance, { x, y, z }, { attackerAllyTeam = attackerAllyTeam, attackerID = unitID }, attackEventType, unitID, unitDefID, _deferAttackEvent)
			-- Hack: we want the primary unit to be the attacker but the event location to be the target.
			event.location = { ax, ay, az }
			if attackedUnitID then
				event.units[attackedUnitID] = { ax, ay, az }
			end
			interestGrid:add(ax, az, attackerAllyTeam, 1)
		end
	end
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer, weaponDefID, projectileID, attackerID, attackerDefID, attackerTeam)
	if paralyzer then
		-- Paralyzer weapons deal very high "damage", but it's not as important as real damage
		damage = damage / 2
	end
	local x, y, z, _, unitImportance = unitInfo:get(unitID)
	local currentHealth, _, _, _, buildProgress = spGetUnitHealth(unitID)
	-- Percentage of current health being dealt in damage, up to 100
	local importance = 100 * min(currentHealth, damage) / currentHealth
	-- Multiply by unit importance factor
	importance = importance * sqrt(unitImportance * buildProgress)

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
	event.units[attackerID] = { x, y, z }
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
	event.units[captureController] = { x, y, z }
end

function widget:Update(dt)
	updateCamera(display, dt)
end
