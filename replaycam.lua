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
local spGetPlayerInfo = Spring.GetPlayerInfo
local spGetSpectatingState = Spring.GetSpectatingState
local spGetTeamColor = Spring.GetTeamColor
local spGetTeamInfo = Spring.GetTeamInfo
local spGetTeamList = Spring.GetTeamList
local spGetUnitPosition = Spring.GetUnitPosition
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

WorldGrid = { xSize = 0, ySize = 0, gridSize = 0, data = nil }

function WorldGrid:new(o, value)
	o = o or {} -- create object if user does not provide one
	setmetatable(o, self)
	self.__index = self

	o.data = o.data or {}
	for x = 1, o.xSize do
		o.data[x] = {}
		for y = 1, o.ySize do
			o.data[x][y] = value
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

function WorldGrid:multiply(x, y, f)
	x, y = self:__toGridCoordinates(x, y)
	self.data[x][y] = self.data[x][y] * f
end

-- Fade, blur and normalize over the grid.
function WorldGrid:fade()
	local fadeRatio = 0.2
	local total = 0
	for x = 1, self.xSize do
		for y = 1, self.ySize do
			total = total + self.data[x][y]
		end
	end

	local fade = fadeRatio / (self.xSize * self.ySize)
	local scaleFactor = (1 - fadeRatio) / total

	for x = 1, self.xSize do
		for y = 1, self.ySize do
			self.data[x][y] = (self.data[x][y] * scaleFactor) + fade
		end
	end
end

-- CONFIGURATION

local framesPerSecond = 30
local updateIntervalFrames = framesPerSecond * 2
local eventFrameHorizon = framesPerSecond * 8

-- WORLD INFO

local mapSizeX, mapSizeZ = Game.mapSizeX, Game.mapSizeZ
local worldGridSize = 512
local mapGridX, mapGridZ = mapSizeX / worldGridSize, mapSizeZ / worldGridSize
local teamInfo = {}

-- GUI COMPONENTS

local window_cpl, panel_cpl, commentary_cpl

-- EVENT TRACKING

local unitBuiltEventType = "unitBuilt"
local unitDamagedEventType = "unitDamaged"
local unitDestroyedEventType = "unitDestroyed"
local unitMovedEventType = "unitMoved"

local eventTargetRatios = normalizeTable({
	unitBuilt = 1,
	unitDamaged = 5,
	unitDestroyed = 3,
	unitMoved = 1,
})

-- These values are dynamically adjusted as we process events.
-- Note that importance is a different quantity for different events, which is also accounted for here.
local eventImportanceAdj = normalizeTable({
	unitBuilt = 0.05, -- Initially high as many build actions at start.
	unitDamaged = 0.2,
	unitDestroyed = 0.8,
	unitMoved = 0.001,
})
local shownEventTypes = {}
local events = {}
local currentEvent = {
	importance = 0
}

local interestGrid = WorldGrid:new({ xSize = mapGridX, ySize = mapGridZ, gridSize = worldGridSize }, 1)

-- CAMERA TRACKING

local camHeightMax = 1600
local camHeightMin = 1000
local camera = {
	x = 0,
	z = 0,
	h = camHeightMax,
	xv = 0,
	zv = 0
}

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

local function addEvent(actor, importance, location, type, unit, unitDef)
	local event = {
		actorCount = 1,
		actors = initTable(actor, true),
		importance = importance,
		location = location,
		object = spGetHumanName(UnitDefs[unitDef], unit),
		started = spGetGameFrame(),
		type = type,
		unitCount = 1,
		units = initTable(unit, location)
	}
	events[#events + 1] = event
	return event
end

local function mergeIntoOld(old, new)
	old.importance = old.importance + new.importance
	old.started = new.started
	for actor, v in pairs(new.actors) do
		if (not old.actors[actor]) then
			old.actorCount = old.actorCount + 1
			old.actors[actor] = v
		end
	end
	for unit, v in pairs(new.units) do
		if (not old.units[unit]) then
			old.unitCount = old.unitCount + 1
			old.units[unit] = v
		end
	end
end

local function selectNextEventToShow()
	local eventMergeRange = 256

	-- Purge old events and merge similar events.
	local currentFrame = spGetGameFrame()
	local newEvents, lastEvent = {}, nil
	for _, event in pairs(events) do
		if (currentFrame - event.started < eventFrameHorizon) then
			local eventDecay = pow(0.9, (currentFrame - (event.lastChecked or event.started)) / framesPerSecond)
			event.importance = event.importance * eventDecay
			event.lastChecked = currentFrame
			if (
					lastEvent and event.type == lastEvent.type and event.object == lastEvent.object and
							distance(event.location, lastEvent.location) < eventMergeRange) then
				mergeIntoOld(lastEvent, event)
			else
				newEvents[#newEvents + 1] = event
				lastEvent = event
			end
		end
	end
	events = newEvents

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
	interestGrid:fade()
	local mostImportantEvent = nil
	local mostImportance = 0
	debugText = "" .. #events .. " events\n"
	for _, event in pairs(events) do
		local x, _, z = unpack(event.location)
		local interestModifier = 1 + interestGrid:get(x, z)
		local adjImportance = event.importance * interestModifier * eventImportanceAdj[event.type]
		if (adjImportance > mostImportance) then
			mostImportantEvent = event
			mostImportance = adjImportance
			debugText = debugText ..
					mostImportantEvent.type .. " " .. adjImportance .. ", "
		end
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
	local currentEventImportanceDecayPerSecond = 0.98
	if (mostImportantEvent == currentEvent) then
		mostImportantEvent.importance = mostImportantEvent.importance *
				pow(currentEventImportanceDecayPerSecond, updateIntervalFrames / framesPerSecond)
	else
		mostImportantEvent.importance = mostImportantEvent.importance / pow(currentEventImportanceDecayPerSecond, 2)
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

	if (event.type == unitBuiltEventType) then
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
	end

	return { commentary = commentary, location = event.location, tracking = event.units }
end

local function updateCamera(displayInfo, dt)
	local cameraAccel = 1024
	local maxPanDistance = 1024
	local mapEdgeBorder = 256

	if (not displayInfo) then
		return
	end

	local tracking = displayInfo.tracking
	-- TODO: What if units are a long way apart e.g. Bertha kill?
	local xSum, ySum, zSum, count = 0, 0, 0, 0
	for unit, location in pairs(tracking) do
		local x, y, z = spGetUnitPosition(unit)
		if (x and y and z) then
			location = { x, y, z }
			tracking[unit] = { x, y, z }
		else
			x, y, z = unpack(location)
		end
		xSum, ySum, zSum = xSum + x, ySum + y, zSum + z
		count = count + 1
	end
	displayInfo.location = {
		xSum / count,
		ySum / count,
		zSum / count,
	}

	-- Event location
	local ex, _, ez = unpack(displayInfo.location)
	ex, ez = bound(ex, mapEdgeBorder, mapSizeX - mapEdgeBorder), bound(ez, mapEdgeBorder, mapSizeZ - mapEdgeBorder)
	-- Camera position and vector
	local cx, cz, ch, cxv, czv = camera.x, camera.z, camera.h, camera.xv, camera.zv
	if (length(ex - cx, ez - cz) > maxPanDistance) then
		cx = ex
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
		z = cz,
		h = ch,
		xv = cxv,
		zv = czv
	}

	spSetCameraTarget(camera.x, 0, camera.z, 1)

	-- TODO: Dynamic height adjustment.
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

	-- TODO: Improve on this, doesn't seem to work well.
	local cx, _, cz = spGetCameraPosition()
	camera = {
		x = cx,
		z = cz,
		h = camHeightMax,
		xv = 0,
		zv = 0
	}
end

function widget:GameFrame(frame)
	if (frame % updateIntervalFrames ~= 0) then
		return
	end

	local newEvent = selectNextEventToShow()
	if (newEvent and newEvent ~= currentEvent) then
		local display = toDisplayInfo(newEvent, frame)

		-- Sticky locations.
		local x, _, z = unpack(display.location)
		interestGrid:multiply(x, z, 1.5)

		newEvent.display = display
		commentary_cpl:SetText(display.commentary .. "\n" .. debugText)

		-- Don't bounce between events e.g. comm spawn.
		currentEvent.importance = 0
		currentEvent = newEvent
	end
end

function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOpts, cmdTag)
	if (cmdID ~= CMD_MOVE and cmdID ~= CMD_ATTACK_MOVE) then
		return
	end

	local unitDef = UnitDefs[unitDefID]
	if (unitDef.customParams.dontcount or unitDef.customParams.is_drone) then
		-- Drones get move commands too :shrug:
		return
	end

	local x, y, z = spGetUnitPosition(unitID)
	local unitLocation = { x, y, z }
	addEvent(unitTeam, sqrt(distance(cmdParams, unitLocation)), unitLocation, unitMovedEventType, unitID, unitDefID)
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
	local x, y, z = spGetUnitPosition(unitID)
	addEvent(attackerTeam, importance, { x, y, z }, unitDamagedEventType, unitID, unitDefID)
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
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
	local event = addEvent(attackerTeam, UnitDefs[unitDefID].cost, { x, y, z }, unitDestroyedEventType, unitID, unitDefID)
	interestGrid:multiply(x, z, 2)
	x, y, z = spGetUnitPosition(attackerID)
	event.units[attackerID] = { x, y, z }
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	local x, y, z = spGetUnitPosition(unitID)
	addEvent(unitTeam, UnitDefs[unitDefID].cost, { x, y, z }, unitBuiltEventType, unitID, unitDefID)
end

function widget:Update(dt)
	updateCamera(currentEvent.display, dt)
end
