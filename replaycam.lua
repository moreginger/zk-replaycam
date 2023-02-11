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
local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitRulesParam = Spring.GetUnitRulesParam
local spGetUnitsInRectangle = Spring.GetUnitsInRectangle
local spIsReplay = Spring.IsReplay
local spSetCameraState = Spring.SetCameraState
local spSetCameraTarget = Spring.SetCameraTarget

local Chili
local Window
local ScrollPanel
local screen0

local CMD_MOVE = CMD.MOVE
local CMD_ATTACK_MOVE = CMD.FIGHT

local framesPerSecond = 30

local debugText = "DEBUG"

-- UTILITY FUNCTIONS

-- Initialize a table.
local function initTable(key, value)
	local result = {}
	if (key) then
		result[key] = value
	end
	return result
end

-- Normalize a table of numeric values to total 1.
local function normalizeTable(t)
	local total = 0
	for _, v in pairs(t) do
		total = total + v
	end
	local result = {}
	for k, v in pairs(t) do
		result[k] = v / total
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

WorldGrid = { xSize = 0, ySize = 0, gridSize = 0, baseValue = 0, data = nil }

function WorldGrid:new(o)
	o = o or {} -- create object if user does not provide one
	setmetatable(o, self)
	self.__index = self

	o.baseValue = o.baseValue or 0
	o.data = o.data or {}
	for x = 1, o.xSize do
		o.data[x] = {}
		for y = 1, o.ySize do
			o.data[x][y] = o.baseValue
		end
	end

	return o
end

function WorldGrid:__toGridCoordinates(x, y)
	x = 1 + min(floor(x / self.gridSize), self.xSize - 1)
	y = 1 + min(floor(y / self.gridSize), self.ySize - 1)
	return x, y
end

function WorldGrid:get(x, y)
	x, y = self:__toGridCoordinates(x, y)
	return self.data[x][y]
end

-- @param f Factor of basevalue to add to this location.
function WorldGrid:add(x, y, f)
	x, y = self:__toGridCoordinates(x, y)
	self.data[x][y] = self.data[x][y] + self.baseValue * f
end

-- 
function WorldGrid:fade()
	local fadeExp = 0.5
	for x = 1, self.xSize do
		for y = 1, self.ySize do
			self.data[x][y] = pow(self.data[x][y] + self.baseValue, fadeExp)
		end
	end
end

function WorldGrid:max()
	local maxValue, maxX, maxY = 0, nil, nil
	for x = 1, self.xSize do
		for y = 1, self.ySize do
			local value = self.data[x][y]
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

UnitInfoCache = { cache = nil, locationListener = nil }

function UnitInfoCache:new(o, value)
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
		spEcho("ERROR! _updatePosition failed", unitID, UnitDefs[cacheObject[1]].name)
		return false
	end
	cacheObject[3] = x
	cacheObject[4] = y
	cacheObject[5] = z
	if self.locationListener then
		self.locationListener(x, y, z)
	end
	return true
end

function UnitInfoCache:watch(unitID, unitDefID)
	local currentFrame = spGetGameFrame()
	if not unitDefID then
		unitDefID = spGetUnitDefID(unitID)
	end
	local unitDef = UnitDefs[unitDefID]
	local importance = unitDef.cost
	local isStatic = not spGetMovetype(unitDef)
	local cacheObject = { unitDefID, currentFrame, 0, 0, 0, importance, isStatic }
	self:_updatePosition(unitID, cacheObject)
	self.cache[unitID] = cacheObject
	return self:get(unitID)
end

-- Returns unit info including rough position.
-- TODO: Override indexer?
function UnitInfoCache:get(unitID)
	local cacheObject = self.cache[unitID]
	if cacheObject then
		local _, _, x, y, z, importance, isStatic = unpack(cacheObject)
		return x, y, z, importance, isStatic
	end
	return self:watch(unitID)
end

function UnitInfoCache:forget(unitID)
	local x, y, z, importance, isStatic = self:get(unitID)
  self.cache[unitID] = nil
	return x, y, z, importance, isStatic
end

function UnitInfoCache:update(currentFrame)
	for unitID, cacheObject in pairs(self.cache) do
		local lastUpdated, isStatic = cacheObject[2], cacheObject[7]
		if not isStatic and (currentFrame - lastUpdated) > unitInfoCacheFrames then
			cacheObject[2] = currentFrame
			if not self:_updatePosition(unitID, cacheObject) then
				-- Something went wrong, drop from cache.
				self.cache[unitID] = nil
			end
		end
	end
end

-- CONFIGURATION

local updateIntervalFrames = framesPerSecond * 2
local eventFrameHorizon = framesPerSecond * 8

-- WORLD INFO

local mapSizeX, mapSizeZ = Game.mapSizeX, Game.mapSizeZ
local worldGridSize = 512
local mapGridX, mapGridZ = mapSizeX / worldGridSize, mapSizeZ / worldGridSize
local teamInfo = {}
local interestGrid = WorldGrid:new({ xSize = mapGridX, ySize = mapGridZ, gridSize = worldGridSize, baseValue = 1 })
local unitInfo = UnitInfoCache:new({ locationListener = function(x, y, z)
	interestGrid:add(x, z, 1)
end})

-- GUI COMPONENTS

local window_cpl, panel_cpl, commentary_cpl

-- EVENT TRACKING

local hotspotEventType = "hotspot"
local unitBuiltEventType = "unitBuilt"
local unitDamagedEventType = "unitDamaged"
local unitDestroyedEventType = "unitDestroyed"
local unitMovedEventType = "unitMoved"
local unitTakenEventType = "unitTaken"

local eventMergeRange = 256

-- Importance decay factor per second.
local importanceDecayFactor = 0.9

local eventTargetRatios = normalizeTable({
	hotspot = 3,
	unitBuilt = 1,
	unitDamaged = 5,
	unitDestroyed = 3,
	unitMoved = 1,
	unitTaken = 2,
})

-- These values are dynamically adjusted as we process events.
-- Note that importance is a different quantity for different events, which is also accounted for here.
local eventImportanceAdj = normalizeTable({
	hotspot = 0.001,
	unitBuilt = 0.05, -- Initially high as many build actions at start.
	unitDamaged = 0.15,
	unitDestroyed = 0.8,
	unitMoved = 0.001,
	unitTaken = 0.05,
})
local tailEvent = nil
local headEvent = nil
local shownEventTypes = {}
local showingEvent = {}
local minimumDisplayFrames = framesPerSecond * 3
local display = nil

-- CAMERA TRACKING

local camHeightMax = 1600
local camHeightMin = 1000
local camera = nil

local function initTeams()
	local allyTeamList = spGetAllyTeamList()
	for _, allyTeamID in pairs(allyTeamList) do
		local teamList = spGetTeamList(allyTeamID)

		local allyTeam = spGetGameRulesParam("allyteam_long_name_" .. allyTeamID)
		if string.len(allyTeam) > 10 then
			allyTeam = spGetGameRulesParam("allyteam_short_name_" .. allyTeamID)
		end

		for _, teamID in pairs(teamList) do
			local teamLeader = nil
			_, teamLeader = spGetTeamInfo(teamID)
			local teamName = "unknown"
			if (teamLeader) then
				teamName = spGetPlayerInfo(teamLeader)
			end
			teamInfo[teamID] = {
				allyTeam = allyTeam, -- TODO: Is there any need for separate ally team name or can just concat here?
				color = { spGetTeamColor(teamID) } or { 1, 1, 1, 1 },
				name = teamName
			}
		end
	end
end

local function decayImportance(importance, frames)
	return importance * pow(importanceDecayFactor, frames / framesPerSecond)
end

local function addEvent(actor, importance, location, type, unit, unitDef)
	local frame = spGetGameFrame()
	local object = {}
	if unit then
		object = spGetHumanName(UnitDefs[unitDef], unit)
	end

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

			-- Unwire event if not at the head.
			if (event ~= headEvent) then
				if (event.previous) then
					event.previous.next = event.next
				end
				event.next.previous = event.previous
				event.previous = nil
				event.next = nil
			end

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

	-- Discard old events
	local purgeBeforeFrame = currentFrame - eventFrameHorizon
	if tailEvent then
		while tailEvent.started < purgeBeforeFrame do
			tailEvent = tailEvent.next
			if not tailEvent then
				headEvent = nil
				break
			end
			tailEvent.previous.next = nil
			tailEvent.previous = nil
		end
	end

	-- Decay events that were added before the last check.
	local addedBeforeLastCheckFrame = currentFrame - updateIntervalFrames
	local updateIntervalDecayFactor = decayImportance(1, updateIntervalFrames)
	local event = tailEvent
	while (event ~= nil and event.started < addedBeforeLastCheckFrame) do
		event.importance = event.importance * updateIntervalDecayFactor
		event = event.next
	end

	-- Decay events that were added after the last check.
	while (event ~= nil) do
		event.importance = decayImportance(event.importance, event.started - currentFrame)
		event = event.next
	end

	-- Work out modifiers to show more events.
	if (#shownEventTypes > 0) then
		local eventCounts = {}
		for k, _ in pairs(eventTargetRatios) do
			eventCounts[k] = 0
		end
		for _, v in pairs(shownEventTypes) do
			eventCounts[v] = eventCounts[v] + 1
		end

		local eventRatios = normalizeTable(eventCounts)
		for k, v in pairs(eventRatios) do
			local deviation = eventTargetRatios[k] - v
			eventImportanceAdj[k] = math.max(0.001, eventImportanceAdj[k] + deviation * 0.1)
		end
		eventImportanceAdj = normalizeTable(eventImportanceAdj)
	end

	-- Find next event to show
	local mostImportantEvent = nil
	local mostImportance = 0

	debugText = "" .. debugGetEventCount() .. " events\n"
	event = tailEvent
	while (event ~= nil) do
		local x, _, z = unpack(event.location)
		local interestModifier = 1 + interestGrid:get(x, z)
		local adjImportance = event.importance * interestModifier * eventImportanceAdj[event.type]
		if (adjImportance > mostImportance) then
			mostImportantEvent = event
			mostImportance = adjImportance
			debugText = debugText ..
					mostImportantEvent.type .. " " .. adjImportance .. ", "
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
		mostImportantEvent.importance = mostImportantEvent.importance *
				pow(showingEventImportanceDecayPerSecond, updateIntervalFrames / framesPerSecond)
	else
		mostImportantEvent.importance = mostImportantEvent.importance / pow(showingEventImportanceDecayPerSecond, 2)
	end

	return mostImportantEvent
end

local function toDisplayInfo(event, frame)
	local commentary = nil
	local actorID = pairs(event.actors)(event.actors)

	-- TODO: Tailor message if multiple actors
	local actorName = "unknown"
	if (actorID) then
		actorName = teamInfo[actorID].name .. " (" .. teamInfo[actorID].allyTeam .. ")"
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
	local xSum, ySum, zSum, trackedLocationCount = 0, 0, 0, 0
	local xMin, xMax, zMin, zMax = mapSizeX, 0, mapSizeZ, 0
	for unit, location in pairs(tracking) do
		local x, y, z = spGetUnitPosition(unit)
		if (x and y and z) then
			location = { x, y, z }
			tracking[unit] = { x, y, z }
		else
			x, y, z = unpack(location)
		end
		xMin, xMax, zMin, zMax = min(xMin, x), max(xMax, x), min(zMin, z), max(zMax, z)
		xSum, ySum, zSum = xSum + x, ySum + y, zSum + z
		trackedLocationCount = trackedLocationCount + 1
	end
	if trackedLocationCount > 0 then
		displayInfo.location = {
			xSum / trackedLocationCount,
			ySum / trackedLocationCount,
			zSum / trackedLocationCount,
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

		initTeams()
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

	interestGrid:fade()
	local igMax, igX, igZ = interestGrid:max()
	if igMax > 2 then
		local event = addEvent(nil, 10 * igMax, { igX, 0, igZ }, hotspotEventType, nil, nil)
		local units = spGetUnitsInRectangle (igX - worldGridSize / 2, igZ - worldGridSize / 2, igX + worldGridSize / 2, igX + worldGridSize / 2)
		for _, unit in pairs(units) do
			event.units[unit] = { igX, _, igZ }
		end
	end

	local newEvent = selectNextEventToShow()
	if newEvent and newEvent ~= showingEvent and (not display or frame - display.shownAt >= minimumDisplayFrames) then
		display = toDisplayInfo(newEvent, frame)

		-- Sticky locations.
		-- TODO: Apply to whole screen?
		local x, _, z = unpack(display.location)
		interestGrid:add(x, z, 1)

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

	local x, y, z, _, isStatic = unitInfo:get(unitID)
	if isStatic then
		return
	end

	local unitLocation = { x, y, z }
	local moveDistance = distance(cmdParams, unitLocation)
	if (moveDistance < 256) then
		-- Ignore smaller moves to keep event numbers down.
		return
	end
	addEvent(unitTeam, sqrt(moveDistance), unitLocation, unitMovedEventType, unitID, unitDefID)
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer, weaponDefID, projectileID, attackerID,
                            attackerDefID, attackerTeam)
	local unitDef = UnitDefs[unitDefID]
	-- Clamp damage to unit health.
	local importance = min(unitDef.health, damage)
	if (paralyzer) then
		-- Paralyzer weapons deal very high "damage", but it's not as important as real damage.
		importance = importance / 2
	end
	local x, y, z = unitInfo:get(unitID)
	addEvent(attackerTeam, importance, { x, y, z }, unitDamagedEventType, unitID, unitDefID)
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
	local _, _, _, importance = unitInfo:forget(unitID)

	if (not attackerTeam) then
		-- Attempt to ignore cancelled builds and other similar things like comm upgrade
		return
	end

	local unitDef = UnitDefs[unitDefID]
	if (unitDef.customParams.dontcount) then
		-- Ignore dontcount units e.g. terraunit
		return
	end

	local x, y, z = spGetUnitPosition(unitID)
	local event = addEvent(attackerTeam, importance or unitDef.cost, { x, y, z }, unitDestroyedEventType, unitID, unitDefID)
	interestGrid:add(x, z, 4)
	x, y, z = spGetUnitPosition(attackerID)
	event.units[attackerID] = { x, y, z }
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	local x, y, z, importance = unitInfo:watch(unitID, unitDefID)
	addEvent(unitTeam, importance, { x, y, z }, unitBuiltEventType, unitID, unitDefID)
end

function widget:UnitTaken(unitID, unitDefID, oldTeam, newTeam)
	-- Note that UnitTaken (and UnitGiven) are both called for both capture and release.
	local captureController = spGetUnitRulesParam(unitID, "capture_controller");
	if not captureController or captureController == -1 then
		return
	end

	local x, y, z, importance = unitInfo:get(unitID)
	local event = addEvent(newTeam, importance, { x, y, z}, unitTakenEventType, unitID, unitDefID)
	x, y, z =  unitInfo:get(captureController)
	event.units[captureController] = { x, y, z }
end

function widget:Update(dt)
	updateCamera(display, dt)
end
