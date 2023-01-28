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
-- Fraction of importance lost per frame.
local importanceDecayFactor = 0.001

-- GUI components
local window_cpl, scroll_cpl, comment_label

local unitFinishedEventType = "unitFinished"
local unitDestroyedEventType = "unitDestroyed"

local events = {}
local currentEvent = {
	display = {
		shownAt = -100
	}
}
local timeSinceUpdate = 0

local function computeImportance(metal)
	return metal
end

local function addEvent(importance, location, type, unitDefs, units)
	local event = { importance = importance, location = location, started = spGetGameFrame(), type = type,
		unitDefs = unitDefs, units = units }
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
		local adjImportance = event.importance - (currentFrame - event.started) * event.importance * importanceDecayFactor
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
	spEcho(event.type == unitFinishedEventType)
	if (event.type == unitFinishedEventType) then
		commentary = getHumanName(event.unitDefs[1], event.units[1]) .. " built"
	elseif (event.type == unitDestroyedEventType) then
		commentary = getHumanName(event.unitDefs[1], event.units[1]) .. " destroyed"
	end
	return { commentary = commentary, location = event.location, shownAt = frame }
end

local function updateCamera(displayInfo, frame)
	local x, y, z = unpack(displayInfo.location)
	spSetCameraTarget(x, y, z)
	local cameraState = spGetCameraState()
	cameraState.height = 2000
	spSetCameraState(cameraState)
	currentEvent.shownAtFrame = frame
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
		padding = { 0, 0, 0, 0 },
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
	-- TODO: More dynamic consideration of shown vs importance
	local showForFrames = 30 * 5
	local doIt = frame % updateIntervalFrames == 0
	if (doIt and (frame - currentEvent.display.shownAt > showForFrames)) then
		local newEvent = selectNextEventToShow()
		if (newEvent ~= nil) then
			currentEvent = newEvent
			local display = toDisplayInfo(currentEvent, frame)
			currentEvent.display = display
			comment_label:SetCaption(display.commentary)
			updateCamera(display, frame)
		end
	end
end

function widget:PlayerChanged(playerID)
end

function widget:TeamChanged(teamID)
end

function widget:UnitCloaked(unitID, unitDefID, unitTeam)
end

function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOptions)
end

function widget:UnitCreated(unitID, unitDefID, unitTeam, builderID)
end

function widget:UnitDecloaked(unitID, unitDefID, unitTeam)
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
	local unitDef = UnitDefs[unitDefID]
	-- dontcount e.g. terraunit
	if (not unitDef.customParams.dontcount) then
		local x, y, z = spGetUnitPosition(unitID)
		addEvent(computeImportance(UnitDefs[unitDefID].cost * 1.5), { x, y, z }, unitDestroyedEventType, { unitDefID }, { unitID })
	end
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	local x, y, z = spGetUnitPosition(unitID)
	addEvent(computeImportance(UnitDefs[unitDefID].cost), { x, y, z }, unitFinishedEventType, { unitDefID }, { unitID })
end

function widget:UnitGiven(unitID, unitDefID, newTeam, oldTeam)
end

function widget:UnitIdle(unitID, unitDefID, unitTeam)
end

function widget:UnitReverseBuilt(unitID, unitDefID, unitTeam)
end

-- function widget:Update(dt)
-- 	timeSinceUpdate = timeSinceUpdate + dt
-- 	if timeSinceUpdate > (updateIntervalFrames / 30) then
-- 		timeSinceUpdate = 0
-- 		-- TODO: Draw something
-- 	end
-- end
