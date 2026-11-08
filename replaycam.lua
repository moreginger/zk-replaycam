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
local spGetViewGeometry = Spring.GetViewGeometry
local spIsReplay = Spring.IsReplay
local spSetCameraState = Spring.SetCameraState
local spSetMouseCursor = Spring.SetMouseCursor
local spTraceScreenRay = Spring.TraceScreenRay
local spWorldToScreenCoords = Spring.WorldToScreenCoords

local Chili
local Window
local ScrollPanel
local screen0

local CMD_ATTACK = CMD.ATTACK
local CMD_ATTACK_MOVE = CMD.FIGHT
local CMD_MOVE = CMD.MOVE
local CMD_RAW_MOVE = VFS.Include("LuaRules/Configs/customcmds.lua").RAW_MOVE

local framesPerSecond = 30
local gameFrame = 0

-- CONFIGURATION

-- Must ship with false
local DEBUG = false
local LOG_ERROR, LOG_DEBUG = 1, 2
local logging = DEBUG and LOG_DEBUG or LOG_ERROR
-- Emit machine-readable "rc-*" lines for scripts/generate-stats.py. Must ship with false (or DEBUG).
local STATS = DEBUG
local updateIntervalFrames = framesPerSecond
local defaultFov, defaultRx, defaultRy = 45, -1.0, pi
-- Time until we think the user is watching, not playing
local userInactiveSecondsThreshold = 2

-- GUI COMPONENTS

local window_cpl, panel_cpl, commentary_cpl

local function setupPanels()
	window_cpl = Window:New {
		parent = screen0,
		dockable = true,
		name = "Action Tracking",
		color = { 0, 0, 0, 0 },
		x = 100,
		y = 200,
		width = 500,
		height = 50,
		padding = { 0, 0, 0, 0 };
		draggable = true,
		resizable = true,
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
		padding = { 4, 4, 4, 4 },
		fontSize = 16,
		text = "The quiet before the storm.",
	}
end

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
		OnChange = function(self)
			if self.value and not window_cpl then
				setupPanels()
			elseif not self.value and window_cpl then
				window_cpl:Dispose()
				window_cpl, panel_cpl, commentary_cpl = nil, nil, nil
			end
		end,
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

function WorldGrid:getInterestingScore()
	-- one event of the mean value, or one moving unit (per second) = 1
	-- two interacting teams = *4	
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

	if totalArea == 0 then
		-- This can happen if the location is so far outside the map that it doesn't touch any grids
		return
	end

	-- Divvy out the interest.
	i = 1
	for ix = gx - 1, gx + 1 do
		for iy = gy - 1, gy + 1 do
			if areas[i] then
				local data = self.data[ix][iy]
				self:_syncCell(data)
				func(data, areas[i] / totalArea, opts)
			end
			i = i + 1
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

function WorldGrid:_intersectArea(x1, y1, x2, y2, x3, y3, x4, y4)
	local x5, y5, x6, y6 = max(x1, x3), max(y1, y3), min(x2, x4), min(y2, y4)
	if x5 >= x6 or y5 >= y6 then
		return 0
	end
	return (x6 - x5) * (y6 - y5)
end



-- Call this exactly once between each reset.
-- When watching an area we apply a fixed boost to make things sticky,
-- but a longer-term negative factor (passe) to encourage moving.
function WorldGrid:setWatching(x, y)
	-- Note: boost is spread over a 2x2 grid.
	self:_addInternal(x, y, self.gridSize * 2, { boost = 10 }, _boostInterest)
	-- passe will be decreased by 1 in EACH grid square in reset, therefore we MUST add more than 1 to a square to have any effect.
	x, y =  self:__toWorldCoords(self:__toGridCoords(x, y))
	self:_addInternal(x, y, self.gridSize * 0.5, { passe = 3 }, _addPasse)
end

function WorldGrid:setCursor(x, y)
	self:_addInternal(x, y, self.gridSize, { boost = 10 / self.teamCount }, _boostInterest)
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

	return total, maxValue, centerX + dX, centerY + dY
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
    -- FIXME: Make Newton damage "important"
	local weaponImportance = weaponDamage * aoeBoost * afterburnBoost
	local range = wdcp.truerange or wd.range
	return weaponImportance, range
end

function UnitInfoCache:_unitStats(unitDefID)
	local cacheObject = self._unitStatsCache[unitDefID]
	if not cacheObject then
		local unitDef = UnitDefs[unitDefID]
		local isStatic = not spGetMovetype(unitDef)
		local importance = unitDef.metalCost
		if isStatic then
			-- This helps us pick static builds to show. Mobile units are going to show up anyway
			importance = importance * 1.5
		end
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
	if unitDef.name == 'terraunit' then
		-- FIXME: This is set in unit_terraform.lua, but not accessible here?
		importance = spGetUnitRulesParam(unitID, 'terraform_estimate') or importance
		spEcho('terraform_estimate', importance)
	end
	local cacheObject = { name = name, allyTeam = allyTeam, unitDefID = unitDefID, importance = importance, lastUpdatedFrame = gameFrame }
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

	o._types = types
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

function EventStatistics:summary()
	local summary = {}
	for type, _ in pairs(self._types) do
		summary[#summary+1] = type .. ': ' .. (self:getMean(type) or 'nil')
	end
	return table.concat(summary, ', ')
end

-- WORLD INFO

local mapSizeX, mapSizeZ = Game.mapSizeX, Game.mapSizeZ
local worldGridSize = 512
local mapGridX, mapGridZ = mapSizeX / worldGridSize, mapSizeZ / worldGridSize
local teamInfo, interestGrid, unitInfo

-- EVENT TRACKING

local attackEventType = "attack"
local buildingEventType = "building"
local hotspotEventType = "hotspot"
local moveEventType = "move"
local overviewEventType = "overview"
local unitBuiltEventType = "unitBuilt"
local unitDamagedEventType = "unitDamaged"
local unitDestroyedEventType = "unitDestroyed"
local unitDestroyerEventType = "unitDestroyer"
local unitTakenEventType = "unitTaken"
local eventTypes = {
	attack = true,
	building = true,
	hotspot = true,
	move = true,
	overview = true,
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
	hotspot = 1,
	move = 2,
	overview = 1,
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
		hotspot = 0.7,
		move = 5.0,
		-- High as overview competes every second, mostly against a weak field.
		overview = 20.0,
		unitBuilt = 1.7,
		unitDamaged = 0.8,
		unitDestroyed = 0.5,
		unitDestroyer = 0.7,
		unitTaken = 0.2
	}
}, eventTypes)

local lastEventId = 0
local events = SpatialLookup:new({ xSize = mapGridX, ySize = mapGridZ, gridSize = worldGridSize, capacity = 128 })
local mie, pendingMie
-- Overview scores quietness against this game's recent log10(igMax), so grid scale doesn't matter.
local overviewBaselineUpdates = 120
-- Overview scores zero this many decades above the baseline.
local overviewBusyDecades = 1.0
local overviewBaseline

local function _getInterestModifier(event)
	if event.type == overviewEventType then
		-- Overview has a pseudo-location in the centre of the map, but should ignore what is happening there.
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
	if mie.type ~= overviewEventType and event.type ~= overviewEventType then
		boost = switchBoostNear + (switchBoostFar - switchBoostNear) * transitionCost(event.location)
	end
	return rarity < _getRarity(mie) ^ (boost * (boostScale or 1))
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
		event = events:getNearby(location[1], location[3], eventMergeRange, function(e)
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
		if logging >= LOG_DEBUG then
			spEcho('merging events', type)
		end
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
		if logging == LOG_DEBUG then
			spEcho('event', type, sbjName, importance, location[1], location[3])
		end
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

local function addOverviewEvent(importance)
	local x, z = mapSizeX / 2, mapSizeZ / 2
	local overviewY = spGetGroundHeight(x, z)
	-- Not added to the interest grid: it would inflate the centre and so damp its own importance.
	local event = addEvent(nil, importance, { x, overviewY, z }, nil, overviewEventType, overviewEventType, -1, nil, ADD_EVENT_OPTS_NO_GRID_NO_MERGE)

	-- Add two fake units to get the right zoom level
	local sx, sy = spGetViewGeometry()
	local sratio = sx / sy
	local mratio = mapSizeX / mapSizeZ
	local zfit = 0.8
	if sratio < mratio then
		zfit = zfit * sratio / mratio
	end
	local zoffset = mapSizeZ * (1 - zfit) / 2
	event:addSubject(-2, { x, overviewY, -zoffset })
	event:addSubject(-3, { x, overviewY, mapSizeZ + zoffset })

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
local camTypeOverview = 'overview'
local camDiagMin = 1000
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
-- Shot lock: a new shot holds until it has framed its event, then for minShotFrames more. Only a
-- challenger that beats it with the pick boost multiplied by shotLockBoost can cut in sooner.
-- If framing never happens (e.g. user control), the lock gives up after maxShotLockFrames.
local minShotFrames = 2 * framesPerSecond
local maxShotLockFrames = 3 * framesPerSecond
local shotLockBoost = 2
local mapEdgeBorder = worldGridSize * 0.5
local keepTrackingRange = worldGridSize * 2

-- A shot counts as framed once its tracking box is on screen and its centre is in the middle half.
local framedCentre = 0.25

local display, initialCameraState, camera
-- Event the camera is actually showing (updateDisplay may refuse to switch)
local shownEvent

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
local function statsAddDamage(unitID, unitDefID, damage, paralyzer)
	local value, maxHealth = statsUnitValue(unitID, unitDefID)
	local x, _, z = spGetUnitPosition(unitID)
	if not value or not maxHealth or maxHealth <= 0 or not x then
		return
	end
	-- Metal-equivalent of the damage dealt. Paralysis counts for half, as in event scoring.
	value = value * min(damage, maxHealth) / maxHealth * (paralyzer and 0.5 or 1)
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
	-- Overview's box deliberately reaches past the map edges, so only its centre counts.
	if display.camType ~= camTypeOverview then
		for _, c in ipairs({ { xMin, zMin }, { xMin, zMax }, { xMax, zMin }, { xMax, zMax } }) do
			local px, py, pz = spWorldToScreenCoords(c[1], gy, c[2])
			if not px or pz < 0 or pz > 1 or px < 0 or px > vsx or py < 0 or py > vsy then
				return
			end
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
	local vsx, vsy = spGetViewGeometry()
	local sx, sy, sz = spWorldToScreenCoords(location[1], location[2], location[3])
	if sx and sz >= 0 and sz <= 1 and sx >= 0 and sx <= vsx and sy >= 0 and sy <= vsy then
		pan = pan / 2
	end
	-- Even a tiny pan takes about the look-at smooth time, so measure from there
	return bound((pan - lookSmoothTime) / (maxPanSeconds - lookSmoothTime), 0, 1)
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
		commentary = sbjString .. " attacking"
	elseif event.type == buildingEventType then
		commentary = actorName .. " making " .. sbjString
	elseif event.type == hotspotEventType then
		commentary = "Something's going down here"
	elseif event.type == overviewEventType then
		-- Don't quite go to straight down, as Spring gets janky
		camAngle = 0.01 - pi / 2
		camType = camTypeOverview
		commentary = "Let's get an overview of the battlefield"
	elseif event.type == unitBuiltEventType then
		commentary = sbjString .. " built by " .. actorName
	elseif event.type == unitDamagedEventType then
		local attacker = __getUnitsNameString(event._objUnits)
		commentary = sbjString .. " under attack by " .. attacker .. " of " .. actorName
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

	display.camAngle = camAngle
	if display.camType ~= camType then
		-- It looks especially naff if we flip between camera types every second
		display.noUpdateBeforeFrame = gameFrame + framesPerSecond * 4
		display.tracking:clear()
	end
	display.camType = camType

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

	if options.show_commentary.value then
		commentary_cpl:SetText(commentary)
	end

	shownEvent = event
	display.shotFrame = gameFrame
	if STATS then
		local x, _, z = unpack(event.location)
		spEcho(string.format('rc-shown,%d,%s,%.0f,%.0f,%s', event.id, event.type, x, z, camType))
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
	end})

	if options.show_commentary then
		setupPanels()
	end

	initialCameraState = spGetCameraState()

	local cx, cy, cz = spGetCameraPosition()
	display = {
		camAngle = defaultRx,
		diag = 0,
		location = { mapSizeX / 2, -1000, mapSizeZ / 2 },
		noUpdateBeforeFrame = 0,
		shotFrame = 0,
		tracking = LinkedList:new(),
		velocity = { 0, 0, 0 }
	}
	if STATS then
		statsLogGame()
	end
	updateDisplay(addOverviewEvent(1))
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

	if display.camType ~= camTypeOverview then
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

	local _, igMax, igX, igZ = interestGrid:statistics()
	if igMax >= interestGrid:getInterestingScore() then
		local units = spGetUnitsInCylinder(igX, igZ, length(worldGridSize / 2, worldGridSize / 2))
		local hotspotEvent
		for _, unitID in pairs(units) do
			local location, _, _, _, isStatic = unitInfo:get(unitID)
			if not isStatic then
				hotspotEvent = hotspotEvent or addEvent(nil, igMax, { igX, spGetGroundHeight(igX, igZ), igZ }, nil, hotspotEventType, hotspotEventType, nil, nil, ADD_EVENT_OPTS_NO_GRID_NO_MERGE)
				hotspotEvent:addSubject(unitID, location)
			end
		end
	end

	-- Log scale, as igMax spans orders of magnitude. Kept above 0 for the running mean.
	local igMaxLog = log10(max(igMax, 1e-6))
	overviewBaseline = overviewBaseline and overviewBaseline + (igMaxLog - overviewBaseline) / overviewBaselineUpdates or igMaxLog
	addOverviewEvent(max(0.001, overviewBaseline + overviewBusyDecades - igMaxLog))


	local cut = false
	if pendingMie and pendingMie ~= mie then
		-- While the shot is locked a cut needs a bigger margin. A cut may also have decayed while
		-- it waited out the lock, so check it still beats the pick.
		local locked = shotLocked()
		cut = _beatsPick(pendingMie, _getRarity(pendingMie), locked and shotLockBoost or 1)
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
		if logging >= LOG_DEBUG then
			spEcho('mie', mie.type, mie.sbjName, mie.importance, mie.started, _getEventPercentile(gameFrame, mie))
		end
		updateDisplay(mie);
		purgeEvents(__purgeExcludes, { excluder = mie })
		-- Picked event should stop changing itself
		mie.updateFunc = nil
		-- Set a standard decay so that we don't show the event for too long.
		mie.decay, mie.started = 3 * framesPerSecond, frame
	end
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

function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, _, _)
    if not unitID or not unitDefID or not unitTeam or not cmdID or not cmdParams then
		return
	end

	if not moveCommands[cmdID] and cmdID ~= CMD_ATTACK then
		return
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

		local meta = { commandRange = worldGridSize / 2, importance = importance, updateUntilFrame = gameFrame + framesPerSecond * 8 }
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
		local meta = { commandRange = weaponRange, importance = weaponImportance, updateUntilFrame = gameFrame + framesPerSecond * 8 }
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
	local meta = { sbjUnitID = unitID }
	addEvent(unitTeam, importance, sbjLocation, meta, sbjName, buildingEventType, unitID, _updateBuildingEvent)
end

function widget:UnitDamaged(unitID, unitDefID, _, damage, paralyzer, _, _, attackerID, _, attackerTeam)
	-- attackerID and attackerTeam may be nil and are tolerated
	if not unitID or not unitDefID or not damage then
		return
	end

	if STATS then
		statsAddDamage(unitID, unitDefID, damage, paralyzer)
	end

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
	
	local event = addEvent(attackerTeam, importance, sbjLocation, nil, sbjName, unitDamagedEventType, unitID)
	if attackerID then
		local attackerLocation = unitInfo:get(attackerID)
		event:addObject(attackerID, attackerLocation)
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

	local destroyedLocation, _, importance, destroyedName = unitInfo:get(unitID)
	unitInfo:forget(unitID)
	purgeEvents(__purgeSubject, { unitID = unitID })

	if not unitDefID or not unitTeam or not attackerID or not attackerTeam or not destroyedLocation or not importance or not destroyedName then
		-- Ignore cancelled builds and other similar things like comm upgrade and other calls we don't understand
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

	local sbjLocation, _, importance, sbjName = unitInfo:get(unitID)
	local event = addEvent(newTeam, importance, sbjLocation, nil, sbjName, unitTakenEventType, unitID)
	local capturerLocation =  unitInfo:get(captureController)
	event:addObject(captureController, capturerLocation)
end

local function updateCamera(dt, userCameraOverride)
	if logging >= LOG_DEBUG and dt > 0.05 then
		spEcho('slow camera update', dt)
	end

	local xSum, ySum, zSum, xvSum, yvSum, zvSum, trackedLocationCount = 0, 0, 0, 0, 0, 0, 0
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
	local isOverview = display.camType == camTypeOverview
	local rotate = options.camera_rotation.value and not isOverview

	-- Where the camera should look: the event, nudged by its velocity and kept off the map edge
	local ex, ey, ez = unpack(display.location)
	local exv, eyv, ezv = unpack(display.velocity)
	ex, ey, ez = ex + exv, ey + eyv, ez + ezv
	ex, ez = bound(ex, mapEdgeBorder, mapSizeX - mapEdgeBorder), bound(ez, mapEdgeBorder, mapSizeZ - mapEdgeBorder)
	local tlook = { ex, ey, ez }
	-- Frame the event by distance rather than zoom, so the FOV stays constant
	local tdist = calcCamRange(display.diag, defaultFov)
	local tpitch = display.camAngle

	-- Cut when a pan would take too long. A critically damped spring at capped speed takes roughly
	-- 2x its smooth time plus the distance at full speed.
	local remaining = distance(c.look, tlook)
	local isCut = c.cutNext or panSeconds(remaining) > maxPanSeconds

	if shownEvent ~= c.shot then
		c.shot = shownEvent
		if rotate and not isCut then
			-- Turn towards the new event, as a drone pilot would, within limits
			local hx, hz = ex - c.x, ez - c.z
			if length(hx, hz) > 1 then
				c.tyaw = c.yaw + bound(wrapAngle(atan2(hx, hz) - c.yaw), -maxShotYawChange, maxShotYawChange)
			end
		end
	end

	if isCut then
		c.look, c.lookv = tlook, { 0, 0, 0 }
		c.dist, c.distv = tdist, 0
		c.pitch, c.pitchv = tpitch, 0
		-- Face north again after a cut, so the viewer doesn't lose their bearings
		c.yaw, c.yawv, c.tyaw = defaultRy, 0, defaultRy
	else
		smoothDampVec(c.look, tlook, c.lookv, lookSmoothTime, dt, lookMaxSpeed)
		local arc = min(tdist * panArcMax, remaining * panArcRise)
		c.dist, c.distv = smoothDamp(c.dist, tdist + arc, c.distv, distSmoothTime, dt)
		c.pitch, c.pitchv = smoothDamp(c.pitch, tpitch, c.pitchv, pitchSmoothTime, dt)
		local tyaw = rotate and c.tyaw or defaultRy
		c.yaw, c.yawv = smoothDamp(c.yaw, c.yaw + wrapAngle(tyaw - c.yaw), c.yawv, yawSmoothTime, dt)
		c.yaw = wrapAngle(c.yaw)
		c.tyaw = c.yaw + wrapAngle(c.tyaw - c.yaw)
	end
	c.cutNext = false

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
	c.reticle = display.camType == camTypeTracking and { xMin, zMin, xMax, zMax }

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
	if userInactiveSeconds > userInactiveSecondsThreshold then
		spSetMouseCursor('none')
	end
	updateCamera(dt, options.user_interrupts_tracking.value and userInactiveSeconds < userInactiveSecondsThreshold)
end

function widget:DrawScreen()
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