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
local floor = math.floor
local max = math.max
local min = math.min
local pow = math.pow
local sqrt = math.sqrt

local spEcho = Spring.Echo
local spGetAllyTeamList = Spring.GetAllyTeamList
local spGetCameraPosition = Spring.GetCameraPosition
local spGetCameraState = Spring.GetCameraState
local spGetGameFrame = Spring.GetGameFrame
local spGetGameRulesParam = Spring.GetGameRulesParam
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
local spSetCameraTarget = Spring.SetCameraTarget

local Chili
local Window
local ScrollPanel
local screen0

local CMD_MOVE = CMD.MOVE
local CMD_ATTACK_MOVE = CMD.FIGHT

local debugText = "DEBUG"

local framesPerSecond = 30

-- CONFIGURATION

local updateIntervalFrames = framesPerSecond
local eventFrameHorizon = framesPerSecond * 8

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
	x = 1 + min(floor(x / self.gridSize), self.xSize - 1)
	y = 1 + min(floor(y / self.gridSize), self.ySize - 1)
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
	-- TODO: 4 is equal to 4 ally units, or 2 x 1 units from different ally teams.
	return 5 * updateIntervalFrames / framesPerSecond
end

-- @param f Units of interest to add.
function WorldGrid:add(x, y, allyTeam, f)
	x, y = self:__toGridCoords(x, y)
	local data = self.data[x][y]
	data[1] = data[1] + f
	if allyTeam then
		data[2][allyTeam] = true
	end
end

function WorldGrid:reset()
	for x = 1, self.xSize do
		for y = 1, self.ySize do
			self.data[x][y] = { 0, {} }
		end
	end
end

function WorldGrid:maxScore()
	local maxValue, maxX, maxY = -1, nil, nil
	for x = 1, self.xSize do
		for y = 1, self.ySize do
			local value = self:_getScoreGridCoords(x, y)
			if maxValue < value then
				maxValue = value
				maxX = x
				maxY = y
			end
		end
	end
	return maxValue, (maxX - 0.5) * self.gridSize, (maxY - 0.5) * self.gridSize
end

-- UNIT INFO CACHE

local unitInfoCacheFrames = framesPerSecond

-- cacheObject {}
-- 1 - allyTeam
-- 2 - unitDefID
-- 3 - lastUpdatedFrame
-- 4 - last known x
-- 5 - last known y
-- 6 - last known z
-- 7 - importance
-- 8 - static (not mobile)
UnitInfoCache = { cache = nil, locationListener = nil }

function UnitInfoCache:new(o)
	o = o or {} -- create object if user does not provide one
	setmetatable(o, self)
	self.__index = self

	o.cache = o.cache or {}
	o.locationListener = o.locationListener or nil
	return o
end

function UnitInfoCache:_updatePosition(unitID, cacheObject)
	local x, y, z = spGetUnitPosition(unitID)
	if not x or not y or not z then
		-- DEBUG: Why is this happening?
		spEcho("ERROR! _updatePosition failed", unitID, UnitDefs[cacheObject[2]].name)
		return false
	end
	cacheObject[4] = x
	cacheObject[5] = y
	cacheObject[6] = z
	if self.locationListener then
		-- TODO: Track velocity?
		local isMoving = not cacheObject[8]
		self.locationListener(x, y, z, cacheObject[1], isMoving)
	end
	return true
end

function UnitInfoCache:watch(unitID, allyTeam, unitDefID)
	local currentFrame = spGetGameFrame()
	if not unitDefID then
		unitDefID = spGetUnitDefID(unitID)
	end
	local unitDef = UnitDefs[unitDefID]
	local importance = unitDef.cost
	if unitDef.customParams.iscommander then
		-- Commanders are extra important.
		-- TODO: Make upgrades less important as they tend to be boring stay at home units.
		importance = importance * 1.5
	end
	local isStatic = not spGetMovetype(unitDef)
	local cacheObject = { allyTeam, unitDefID, currentFrame, 0, 0, 0, importance, isStatic }
	self:_updatePosition(unitID, cacheObject)
	self.cache[unitID] = cacheObject
	return self:get(unitID)
end

-- Returns unit info including rough position.
-- TODO: Override indexer?
function UnitInfoCache:get(unitID)
	local cacheObject = self.cache[unitID]
	if cacheObject then
		local _, _, _, x, y, z, importance, isStatic = unpack(cacheObject)
		return x, y, z, importance, isStatic
	end
	local unitTeamID = spGetUnitTeam(unitID)
	local _, _, _, _, _, allyTeam = spGetTeamInfo(unitTeamID)
	return self:watch(unitID, allyTeam)
end

function UnitInfoCache:forget(unitID)
	local x, y, z, importance, isStatic = self:get(unitID)
	self.cache[unitID] = nil
	return x, y, z, importance, isStatic
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

-- Log event and return percentile in unit range (not sure what to call it).
function EventStatistics:logEvent(type, importance)
	local count, meanImportance = unpack(self[type])
	local newCount = count + 1

	-- Switch to a weighted mean after a certain number of events, for faster adaptation.
	-- NOTE: This is called each update, so events get logged multiple times as their importance decreases.
	local switchCount = 8 * eventFrameHorizon / updateIntervalFrames
	if newCount > switchCount then
		count = switchCount - 1
		newCount = switchCount
	end

	meanImportance = meanImportance * count / newCount + importance / newCount
	self[type][1] = newCount
	self[type][2] = meanImportance

	-- Assume exponential distribution.
	local m = 1 / (meanImportance * self.eventMeanAdj[type])
	return 1 - math.exp(-m * importance)
end

-- WORLD INFO

local mapSizeX, mapSizeZ = Game.mapSizeX, Game.mapSizeZ
local worldGridSize = 512
local mapGridX, mapGridZ = mapSizeX / worldGridSize, mapSizeZ / worldGridSize
local teamInfo, interestGrid, unitInfo

-- GUI COMPONENTS

local window_cpl, panel_cpl, commentary_cpl

-- EVENT TRACKING

local hotspotEventType = "hotspot"
local unitBuiltEventType = "unitBuilt"
local unitDamagedEventType = "unitDamaged"
local unitDestroyedEventType = "unitDestroyed"
local unitMovedEventType = "unitMoved"
local unitTakenEventType = "unitTaken"
local eventTypes = {
	hotspotEventType,
	unitBuiltEventType,
	unitDamagedEventType,
	unitDestroyedEventType,
	unitMovedEventType,
	unitTakenEventType
}

local eventMergeRange = 256

-- Importance decay factor per second.
local importanceDecayFactor = 0.9

local tailEvent = nil
local headEvent = nil
local eventStatistics = EventStatistics:new({
	-- Adjust mean of events in percentile estimation
	-- > 1: make each event seem more likely (less interesting)
	-- < 1: make each event seem less likely (more interesting)
	eventMeanAdj = {
		hotspot = 1.0,
		unitBuilt = 2.5,
		unitDamaged = 0.6,
		unitDestroyed = 0.6,
		unitMoved = 1.2,
		unitTaken = 0.2,
	}
}, eventTypes)

local shownEventTypes = {}
local showingEvent = {}
local display = nil

-- CAMERA TRACKING

local camHeightMax = 1600
local camHeightMin = 1000
local camera = nil

local function decayImportance(importance, frames)
	return importance * pow(importanceDecayFactor, frames / framesPerSecond)
end

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

local function addEvent(actor, expireIn, importance, location, type, unit, unitDef)
	local frame = spGetGameFrame()
	local object = {}
	if unit then
		object = spGetHumanName(UnitDefs[unitDef], unit)
	end
	local expiry = frame + expireIn

	-- Try to merge into recent events.
	local considerForMergeAfterFrame = frame - framesPerSecond
	local event = headEvent
	while (event ~= nil) do
		if (event.started < considerForMergeAfterFrame) then
			-- Don't want to check further back, so break.
			event = nil
			break
		end
		if (event.type == type and event.object == object and
				distance(event.location, location) < eventMergeRange) then

			-- Merge new event into old
			event.importance = event.importance + importance
			event.expiry = expiry
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

			-- We put it back in later.
			removeEvent(event)

			-- We merged, so break.
			break
		end

		-- Keep looking.
		event = event.previous
	end

	if (not event) then
		event = {
			actorCount = 1,
			actors = initTable(actor, true),
			expiry = expiry,
			importance = importance,
			location = location,
			object = object,
			started = frame,
			type = type,
			unitCount = 1,
			units = initTable(unit, location)
		}
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

local function purgeEventsOfUnit(unitID)
	local event = tailEvent
	while event ~= nil do
		-- Keep unit if it was destroyed as we'll track its destroyed location.
		if event.units[unitID] and event.type ~= unitDestroyedEventType then
			event.units[unitID] = nil
			event.unitCount = event.unitCount - 1
			if event.unitCount == 0 then
				event.importance = 0
				removeEvent(event)
			end
		end
		event = event.next
	end
end

-- This is slow, don't use it in anger.
local function debugGetEventCount()
	local event, count = tailEvent, 0
	while (event ~= nil) do
		count = count + 1
		event = event.next
	end
	return count
end

local function selectNextEventToShow()
	-- Purge old events and merge similar events.
	local currentFrame = spGetGameFrame()

	-- Remove expired events
	local event = tailEvent
	while event ~= nil do
		local nextEvent = event.next
		if event.expiry < currentFrame then
			removeEvent(event)
		end
		event = nextEvent
	end

	-- Decay events that were added before the last check.
	local addedBeforeLastCheckFrame = currentFrame - updateIntervalFrames
	local updateIntervalDecayFactor = decayImportance(1, updateIntervalFrames)
	event = tailEvent
	while event ~= nil and event.started < addedBeforeLastCheckFrame do
		event.importance = event.importance * updateIntervalDecayFactor
		event = event.next
	end

	-- Decay events that were added after the last check.
	while event ~= nil do
		event.importance = decayImportance(event.importance, event.started - currentFrame)
		event = event.next
	end

	-- Find next event to show
	local mostImportantEvent = nil
	local mostPercentile = 0

	debugText = "" .. debugGetEventCount() .. " events\n"
	event = tailEvent
	while (event ~= nil) do
		local x, _, z = unpack(event.location)
		local interestModifier = 1 + interestGrid:getScore(x, z)
		local adjImportance = event.importance * interestModifier
		local eventPercentile = eventStatistics:logEvent(event.type, adjImportance)
		if (eventPercentile > mostPercentile) then
			mostImportantEvent = event
			mostPercentile = eventPercentile
			debugText = debugText ..
					mostImportantEvent.type .. " " .. eventPercentile .. ", "
		end
		event = event.next
	end

	if (not mostImportantEvent) then
		return
	end

	shownEventTypes[#shownEventTypes + 1] = mostImportantEvent.type
	if (#shownEventTypes == 17) then
		table.remove(shownEventTypes, 1)
	end

	-- Decay importance of showing event to encourage events of similar importance to show.
	-- If not yet showing then add importance to make it slightly sticky.
	local showingEventImportanceDecayPerSecond = 0.98
	if (mostImportantEvent == showingEvent) then
		-- Give it a fighting chance of staying there for 2s.
		mostImportantEvent.importance = mostImportantEvent.importance * pow(showingEventImportanceDecayPerSecond, 2)
	else
		mostImportantEvent.importance = mostImportantEvent.importance / pow(showingEventImportanceDecayPerSecond, updateIntervalFrames / framesPerSecond)
	end

	return mostImportantEvent
end

local function toDisplayInfo(event, frame)
	local commentary = nil
	local actorID = pairs(event.actors)(event.actors)

	-- TODO: Tailor message if multiple actors
	local actorName = "unknown"
	if (actorID) then
		actorName = teamInfo[actorID].name .. " (" .. teamInfo[actorID].allyTeamName .. ")"
	end

	if (event.type == hotspotEventType) then
		commentary = "Something's going down here"
	elseif (event.type == unitBuiltEventType) then
		commentary = event.object .. " built by " .. actorName
	elseif (event.type == unitDamagedEventType) then
		-- TODO: Add actor when Spring allows it: https://github.com/beyond-all-reason/spring/issues/391
		commentary = event.object .. " under attack"
	elseif (event.type == unitDestroyedEventType) then
		commentary = event.object .. " destroyed by " .. actorName
	elseif (event.type == unitMovedEventType) then
		local quantityPrefix = " "
		if (event.unitCount > 5) then
			quantityPrefix = " batallion "
		elseif (event.unitCount > 2) then
			quantityPrefix = " team "
		end
		commentary = event.object .. quantityPrefix .. "moving"
	elseif (event.type == unitTakenEventType) then
		commentary = event.object .. " captured by " .. actorName
	end

	return { commentary = commentary, location = event.location, shownAt = frame, tracking = event.units }
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

	-- Event location
	local ex, _, ez = unpack(displayInfo.location)
	ex, ez = bound(ex, mapEdgeBorder, mapSizeX - mapEdgeBorder), bound(ez, mapEdgeBorder, mapSizeZ - mapEdgeBorder)
	-- Camera position and vector
	local cx, cz, ch, cxv, czv = camera.x, camera.z, camera.h, camera.xv, camera.zv
	if (length(ex - cx, ez - cz) > maxPanDistance) then
		cx = ex
		cz = ez
		ch = math.random(camHeightMin, camHeightMax)
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

	-- Change height based on unit distribution.
	local boundingDiagLength = distance({ xMin, nil, zMin }, { xMax, nil, zMax })
	local targetHeight = bound(camHeightMin + boundingDiagLength + length(ex - cx, ez - cz), camHeightMin, camHeightMax)
	local heightChange = 128 * dt
	if (abs(targetHeight - ch) <= heightChange) then
		ch = targetHeight
	elseif (targetHeight > ch) then
		ch = ch + heightChange
	elseif (targetHeight < ch) then
		ch = ch - heightChange
	end

	camera = {
		x = cx,
		z = cz,
		h = ch,
		xv = cxv,
		zv = czv
	}

	spSetCameraTarget(camera.x, 0, camera.z, 1)

	local cameraState = spGetCameraState()
	cameraState.height = camera.h
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
	-- TODO: Force overhead camera
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
					allyTeamName = allyTeamName, -- TODO: Is there any need for separate ally team name or can just concat here?
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

	local cx, _, cz = spGetCameraPosition()
	local height = spGetCameraState().height

	camera = {
		x = cx,
		z = cz,
		h = height,
		xv = 0,
		zv = 0
	}
end

function widget:GameFrame(frame)
	unitInfo:update(frame)

	if (frame % updateIntervalFrames ~= 0) then
		return
	end

	local igMax, igX, igZ = interestGrid:maxScore()
	interestGrid:reset()
	if igMax >= interestGrid:getInterestingScore() then
		local units = spGetUnitsInRectangle (igX - worldGridSize / 2, igZ - worldGridSize / 2, igX + worldGridSize / 2, igZ + worldGridSize / 2)
		if #units > 0 then
			local event = addEvent(nil, 1, 10 * igMax, { igX, 0, igZ }, hotspotEventType, nil, nil)
			for _, unit in pairs(units) do
				event.units[unit] = { igX, _, igZ }
			end
		end
	end

	local newEvent = selectNextEventToShow()
	if newEvent and newEvent ~= showingEvent then
		display = toDisplayInfo(newEvent, frame)

		-- Sticky locations.
		-- TODO: Apply to whole screen?
		local x, _, z = unpack(display.location)
		interestGrid:add(x, z, nil, 1)

		-- Don't bounce between events e.g. comm spawn.
		showingEvent.importance = 0
		showingEvent = newEvent

		commentary_cpl:SetText(display.commentary .. "\n" .. debugText)
	end
end

function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOpts, cmdTag)
	if cmdID ~= CMD_MOVE and cmdID ~= CMD_ATTACK_MOVE then
		return
	end

	local unitDef = UnitDefs[unitDefID]
	if unitDef.customParams.dontcount or unitDef.customParams.is_drone then
		-- Drones get move commands too :shrug:
		return
	end

	local x, y, z, importance, isStatic = unitInfo:get(unitID)
	if isStatic then
		-- Not interested in commands given to factories
		return
	end

	local _, _, _, _, buildProgress = spGetUnitHealth(unitID)
	if buildProgress < 0.9 then
		-- Don't watch units that probably won't move any time soon
		return
	end

	local unitLocation = { x, y, z }
	local moveDistance = distance(cmdParams, unitLocation)
	if (moveDistance < 256) then
		-- Ignore smaller moves to keep event numbers down and help ignore unitAI
		return
	end
	addEvent(unitTeam, updateIntervalFrames, sqrt(moveDistance) * importance, unitLocation, unitMovedEventType, unitID, unitDefID)
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer, weaponDefID, projectileID, attackerID, attackerDefID, attackerTeam)
	if paralyzer then
		-- Paralyzer weapons deal very high "damage", but it's not as important as real damage
		damage = damage / 2
	end
	local x, y, z, unitImportance = unitInfo:get(unitID)
	local currentHealth = spGetUnitHealth(unitID)
	-- Percentage of current health being dealt in damage, up to 100
	local importance = 100 * min(currentHealth, damage) / currentHealth
	-- Multiply by unit importance factor
	importance = importance * sqrt(unitImportance)

	addEvent(attackerTeam, updateIntervalFrames, importance, { x, y, z }, unitDamagedEventType, unitID, unitDefID)
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

	local event = addEvent(attackerTeam, eventFrameHorizon, importance or unitDef.cost, { x, y, z }, unitDestroyedEventType, unitID, unitDefID)
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
	local x, y, z, importance = unitInfo:watch(unitID, allyTeam, unitDefID)
	addEvent(unitTeam, eventFrameHorizon, importance, { x, y, z }, unitBuiltEventType, unitID, unitDefID)
end

function widget:UnitTaken(unitID, unitDefID, oldTeam, newTeam)
	-- Note that UnitTaken (and UnitGiven) are both called for both capture and release.
	local captureController = spGetUnitRulesParam(unitID, "capture_controller");
	if not captureController or captureController == -1 then
		return
	end

	local x, y, z, importance = unitInfo:get(unitID)
	local event = addEvent(newTeam, eventFrameHorizon, importance, { x, y, z}, unitTakenEventType, unitID, unitDefID)
	x, y, z =  unitInfo:get(captureController)
	event.units[captureController] = { x, y, z }
end

function widget:Update(dt)
	updateCamera(display, dt)
end
