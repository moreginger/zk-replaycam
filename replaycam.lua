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

-- UTILITY FUNCTIONS

-- Initialize a table.
local function initTable(key, value)
	local map = {}
	if (key) then
		map[key] = value
	end
	return map
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
	return math.sqrt(x * x + y * y)
end

-- Calculate x, z distance between two { x, y, z } points.
local function distance(p1, p2)
	local p1x, _, p1z = unpack(p1)
	local p2x, _, p2z = unpack(p2)
	return length(p1x - p2x, p1z - p2z)
end

-- Bound a number to be >= min and <= max
local function bound(x, min, max)
	return math.min(math.max(x, min), max)
end

-- END UTILITY FUNCTIONS

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

local mapSizeX = Game.mapSizeX
local mapSizeZ = Game.mapSizeZ

local Chili
local Window
local ScrollPanel
local Label
local screen0

local framesPerSecond = 30
local updateIntervalFrames = framesPerSecond * 5
local eventFrameHorizon = framesPerSecond * 15

local teamInfo = {}

-- GUI components
local window_cpl, scroll_cpl, comment_label

local unitDamagedEventType = "unitDamaged"
local unitDestroyedEventType = "unitDestroyed"
local unitBuiltEventType = "unitBuilt"

local eventTargetRatios = normalizeTable({
	unitBuilt = 1,
	unitDamaged = 3,
	unitDestroyed = 2
})

-- These values are dynamically adjusted as we process events.
-- Note that importance is a different quantity for different events, which is also accounted for here.
local eventImportanceAdj = normalizeTable({
	unitBuilt = 4,
	unitDamaged = 1,
	unitDestroyed = 8
})

local shownEventTypes = {}

local events = {}
local currentEvent = {
	importance = 0
}

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
		actors = initTable(actor, true),
		importance = importance,
		location = location,
		object = spGetHumanName(UnitDefs[unitDef], unit),
		started = spGetGameFrame(),
		type = type,
		units = initTable(unit, location)
	}
	events[#events + 1] = event
	return event
end

local function selectNextEventToShow()
	local eventMergeRange = 256

	local currentFrame = spGetGameFrame()

	-- Purge old events.
	-- TODO: Use linked list.
	local newEvents, lastEvent = {}, nil
	for _, event in pairs(events) do
		if (currentFrame - event.started < eventFrameHorizon) then
			if (
					lastEvent and event.type == lastEvent.type and event.object == lastEvent.object and
							distance(event.location, lastEvent.location) < eventMergeRange) then
				lastEvent.importance = lastEvent.importance + event.importance
				lastEvent.started = event.started
				for actor, v in pairs(event.actors) do
					lastEvent.actors[actor] = v
				end
				for unit, v in pairs(event.units) do
					lastEvent.units[unit] = v
				end
			else
				newEvents[#newEvents + 1] = event
				lastEvent = event
			end
		end
	end
	events = newEvents

	-- Work out modifiers to show more events.
	local eventCounts = {
		unitBuilt = 0,
		unitDamaged = 0,
		unitDestroyed = 0
	}
	for _, v in pairs(shownEventTypes) do
		eventCounts[v] = eventCounts[v] + 1
	end
	eventCounts = normalizeTable(eventCounts)

	local eventRatios = normalizeTable(eventCounts)
	for k, v in pairs(eventRatios) do
		local deviation = eventTargetRatios[k] - v
		eventImportanceAdj[k] = math.max(0.001, eventImportanceAdj[k] + deviation * 0.1)
	end
	eventImportanceAdj = normalizeTable(eventImportanceAdj)

	-- TODO: Write decayed importance.
	-- Find next event to show
	local mostImportantEvent = nil
	local mostImportance = 0
	for _, event in pairs(events) do
		local eventDecay = math.pow(2, (currentFrame - event.started) / framesPerSecond)
		local adjImportance = event.importance * eventImportanceAdj[event.type] / eventDecay
		if (adjImportance > mostImportance) then
			mostImportantEvent = event
			mostImportance = adjImportance
		end
	end

	if (mostImportantEvent) then
		-- TODO: Use linked list
		shownEventTypes[#shownEventTypes + 1] = mostImportantEvent.type
		if (#shownEventTypes == 17) then
			table.remove(shownEventTypes, 1)
		end

		mostImportantEvent.importance = mostImportantEvent.importance * 0.8
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

	if (event.type == unitDamagedEventType) then
		-- TODO: Add actor when Spring allows it: https://github.com/beyond-all-reason/spring/issues/391
		commentary = event.object .. " under attack"
	elseif (event.type == unitDestroyedEventType) then
		commentary = event.object .. " destroyed by " .. actorName
	elseif (event.type == unitBuiltEventType) then
		commentary = event.object .. " built by " .. actorName
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
	-- TODO: Use last location in lieu of positioning info?
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
			local ov = math.sqrt(od * cameraAccel)
			dx = dx + ov * ox / od
			dz = dz + ov * oz / od
		end
		local dv = length(dx, dz)
		if (dv > 0) then
			cxv = cxv + dt * cameraAccel * dx / dv
			czv = czv + dt * cameraAccel * dz / dv
		end
		-- TODO: Bound camera velocity.
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
	scroll_cpl = ScrollPanel:New {
		parent = window_cpl,
		width = "100%",
		height = "100%",
		padding = { 4, 4, 4, 4 },
		scrollbarSize = 6,
		horizontalScrollbar = false,
	}
	comment_label = Label:New {
		parent = scroll_cpl,
		width = "100%",
		x = 0,
		y = 0,
		fontSize = 16,
		caption = "The quiet before the storm.",
	}
end

function widget:Initialize()
	-- TODO: Force overhead camera
	local loadText = "LOADED "
	if (WG.Chili and (spIsReplay() or spGetSpectatingState())) then
		Chili = WG.Chili
		Window = Chili.Window
		ScrollPanel = Chili.ScrollPanel
		Label = Chili.Label
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
	local doIt = frame % updateIntervalFrames == 0
	if (doIt) then
		local newEvent = selectNextEventToShow()
		if (newEvent and newEvent ~= currentEvent) then
			local display = toDisplayInfo(newEvent, frame)

			newEvent.display = display
			comment_label:SetCaption(display.commentary)

			-- Don't bounce between events e.g. comm spawn.
			currentEvent.importance = 0
			currentEvent = newEvent
		end
	end
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer, weaponDefID, projectileID, attackerID,
                            attackerDefID, attackerTeam)
	local x, y, z = spGetUnitPosition(unitID)
	addEvent(attackerTeam, damage, { x, y, z }, unitDamagedEventType, unitID, unitDefID)
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
	local unitDef = UnitDefs[unitDefID]
	-- Attempt to ignore cancelled builds and other similar things like comm upgrade
	local skipEvent = attackerTeam == nil
	-- Ignore dontcount units e.g. terraunit
	skipEvent = skipEvent or unitDef.customParams.dontcount
	if (not skipEvent) then
		local x, y, z = spGetUnitPosition(unitID)
		local event = addEvent(attackerTeam, UnitDefs[unitDefID].cost, { x, y, z }, unitDestroyedEventType, unitID, unitDefID)
		x, y, z = spGetUnitPosition(attackerID)
		event.units[attackerID] = { x, y, z }
	end
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	local x, y, z = spGetUnitPosition(unitID)
	addEvent(unitTeam, UnitDefs[unitDefID].cost, { x, y, z }, unitBuiltEventType, unitID, unitDefID)
end

function widget:Update(dt)
	updateCamera(currentEvent.display, dt)
end
