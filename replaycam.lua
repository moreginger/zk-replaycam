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

local spEcho = Spring.Echo
local spGetCameraState = Spring.GetCameraState
local spGetGameFrame = Spring.GetGameFrame
local spGetHumanName = Spring.Utilities.GetHumanName
local spGetSpectatingState = Spring.GetSpectatingState
local spGetUnitIsDead = Spring.GetUnitIsDead
local spGetUnitPosition = Spring.GetUnitPosition
local spIsReplay = Spring.IsReplay
local spSetCameraState = Spring.SetCameraState
local spSetCameraTarget = Spring.SetCameraTarget

local Chili
local Window
local ScrollPanel
local Label
local screen0

local framesPerSecond = 30
local updateIntervalFrames = framesPerSecond * 5
local eventFrameHorizon = framesPerSecond * 30

-- GUI components
local window_cpl, scroll_cpl, comment_label

local unitFinishedEventType = "unitFinished"
local unitDestroyedEventType = "unitDestroyed"

local events = {}
local currentEvent = {
}
local timeSinceUpdate = 0

local function computeImportance(metal)
	return metal
end

local function addEvent(importance, location, type, unitDefs, units)
	local importanceDecayFactor = 0.1
	if (type == unitDestroyedEventType) then
		importanceDecayFactor = importanceDecayFactor * 2
	end
	local event = { importance = importance, importanceDecayFactor = importanceDecayFactor, location = location, started = spGetGameFrame(), type = type, unitDefs = unitDefs, units = units }
	events[#events + 1] = event
end

local function selectNextEventToShow()
	local currentFrame = spGetGameFrame()
	local newEvents = {}
	for _, event in pairs(events) do
		if (currentFrame - event.started < eventFrameHorizon) then
			newEvents[#newEvents + 1] = event
		end
	end
	events = newEvents

	local mostImportantEvent = nil
	local mostImportance = 0
	for _, event in pairs(events) do
		local eventDecay = math.pow(2, event.importanceDecayFactor * (currentFrame - event.started) / framesPerSecond)
		local adjImportance = event.importance / eventDecay
		if (adjImportance > mostImportance) then
			mostImportantEvent = event
			mostImportance = adjImportance
		end
	end
	return mostImportantEvent
end

local function getHumanName(unitDef, unit)
	return spGetHumanName(UnitDefs[unitDef], unit)
end

local function toDisplayInfo(event, frame)
	local commentary = nil
	local tracking = nil
	if (event.type == unitFinishedEventType) then
		commentary = getHumanName(event.unitDefs[1], event.units[1]) .. " built"
		tracking = event.units[1]
	elseif (event.type == unitDestroyedEventType) then
		commentary = getHumanName(event.unitDefs[1], event.units[1]) .. " destroyed"
	end
	return { commentary = commentary, height = 1600, heightMin = 1200, heightChange = -20, location = event.location, tracking = tracking }
end

local function updateCamera(displayInfo, dt)
	if (displayInfo ~= nil) then
		if (displayInfo.tracking ~= nil) then
			local x, y, z = spGetUnitPosition(displayInfo.tracking)
			if (x ~= nil and y ~= nil and z ~= nil) then
				displayInfo.location = { x, y, z }
			else
				displayInfo.tracking = nil
				-- TODO: Adjust importance decay factor of event?
			end
		end
		local x, y, z = unpack(displayInfo.location)
		spSetCameraTarget(x, y, z, 1)
		local height = displayInfo.height + dt * displayInfo.heightChange
		height = math.max(height, displayInfo.heightMin)
		displayInfo.height = height
		local cameraState = spGetCameraState()
		cameraState.height = height
		spSetCameraState(cameraState)
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
		width = 300,
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
		fontSize = 12,
		caption = "The quiet before the storm.",
	}
end

function widget:Initialize()
	-- TODO: Force overhead camera
	local loadText = "LOADED "
	if (WG.Chili and (spIsReplay() or spGetSpectatingState())) then
		spEcho(loadText .. widget:GetInfo().name)

		Chili = WG.Chili
		Window = Chili.Window
		ScrollPanel = Chili.ScrollPanel
		Label = Chili.Label
		screen0 = Chili.Screen0

		setupPanels()
	else
		spEcho(loadText .. "AND REMOVED " .. widget:GetInfo().name)
		widgetHandler:RemoveWidget()
	end

	-- TODO: Team / player names
end

function widget:GameFrame(frame)
	local doIt = frame % updateIntervalFrames == 0
	if (doIt) then
		local newEvent = selectNextEventToShow()
		if (newEvent ~= nil and newEvent ~= currentEvent) then
			currentEvent = newEvent
			local display = toDisplayInfo(currentEvent, frame)
			currentEvent.display = display
			comment_label:SetCaption(display.commentary)
		end
	end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
	-- TODO: Exclude cancelled units.
	-- TODO: Exclude commander upgrades.
	local unitDef = UnitDefs[unitDefID]
	-- dontcount e.g. terraunit
	if (not unitDef.customParams.dontcount) then
		local x, y, z = spGetUnitPosition(unitID)
		addEvent(computeImportance(UnitDefs[unitDefID].cost * 1.5), { x, y, z }, unitDestroyedEventType, { unitDefID },
			{ unitID })
	end
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	local x, y, z = spGetUnitPosition(unitID)
	addEvent(computeImportance(UnitDefs[unitDefID].cost), { x, y, z }, unitFinishedEventType, { unitDefID }, { unitID })
end

function widget:Update(dt)
	updateCamera(currentEvent.display, dt)
end
