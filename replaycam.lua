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
-- 1. What happens (damage, deaths, building, orders) is gathered from the callins into foci:
--    places where things are happening, each keeping what went on there, in metal, by kind and
--    side, over the last few seconds (foci)
-- 2. Scenes anticipate the action: places where one side's value is coming within reach of the
--    other's armed units add to the foci too (scenes), as do armed units closing to weapon range
--    of something they can hit (foci.contact)
-- 3. The camera shows the focus with most going on, less what it has been watching for a while,
--    and the callout says what is going on there from what the focus has kept (overlay)

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
local spGetUnitHeading = Spring.GetUnitHeading
local spGetUnitVelocity = Spring.GetUnitVelocity
local spGetVisibleUnits = Spring.GetVisibleUnits
local spGetViewGeometry = Spring.GetViewGeometry
local spIsReplay = Spring.IsReplay
local spSetCameraState = Spring.SetCameraState
local spSetMouseCursor = Spring.SetMouseCursor
local spTraceScreenRay = Spring.TraceScreenRay
local spWorldToScreenCoords = Spring.WorldToScreenCoords

local CMD_ATTACK = CMD.ATTACK
local CMD_ATTACK_MOVE = CMD.FIGHT
local CMD_MOVE = CMD.MOVE
local CMD_RAW_MOVE = VFS.Include("LuaRules/Configs/customcmds.lua").RAW_MOVE

local framesPerSecond = 30
local gameFrame = 0

-- CONFIGURATION

-- Must ship with false
local DEBUG = false
-- Emit machine-readable "rc-*" lines for scripts/generate-stats.py. Must ship with false (or DEBUG).
local STATS = DEBUG
local updateIntervalFrames = framesPerSecond
local defaultFov, defaultRx, defaultRy = 45, -1.0, pi
-- Time until we think the user is watching, not playing
local userInactiveSecondsThreshold = 2

-- GUI COMPONENTS

-- Callout and ground markings for the shot (see OVERLAY)
local overlay = { tally = {}, allyColor = {} }

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
	},
	tracking_reticle = {
		type = 'bool',
		value = false,
	}
}

-- UTILITY FUNCTIONS

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

-- The camera's ahead, right (level) and up vectors at this pitch and yaw
local function cameraAxes(pitch, yaw)
	local cp, sp, cy, sy = cos(pitch), sin(pitch), cos(yaw), sin(yaw)
	return sy * cp, sp, cy * cp, -cy, sy, -sy * sp, cp, -cy * sp
end

-- SPRING UTILS

local function getUnitLocation(unitID)
	local x, y, z = spGetUnitPosition(unitID)
	return x and y and z and { x, y, z }
end

-- Where a unit is seen. Nil while it is hidden: various units (e.g. puppies) use a noDraw hack
-- combined with location displacement.
local function getSeenLocation(unitID)
	return not spGetUnitNoDraw(unitID) and getUnitLocation(unitID) or nil
end

local function getUnitVelocity(unitID)
	local xv, yv, zv = spGetUnitVelocity(unitID)
	return xv and yv and zv and { xv, yv, zv }
end

-- UNIT INFO CACHE

local unitInfoCacheFrames = framesPerSecond

-- updateListener is called exactly once per unit per unitInfoCacheFrames
UnitInfoCache = { updateListener = nil }

function UnitInfoCache:new(o)
	o = o or {} -- create object if user does not provide one
	setmetatable(o, self)
	self.__index = self

	-- cacheObject {}
    -- 1 - unit importance
	-- 2 - static (not mobile)
	-- 3 - weapon importance
	-- 4 - weapon range
	-- 5 - health
	-- 6 - flies
	-- 7, 8 - weapon hits air, ground
	o._unitStatsCache = {}
	-- cacheObject { name, allyTeam, unitDefID, lastUpdatedFrame, location, velocity }
	o.cache = o.cache or {}
	return o
end

-- Weapon importance, 0 if no weapon found, its range, and whether it hits air and ground
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
	local only = weapon.onlyTargets
	local hitsAir, hitsGround = true, true
	if only and next(only) then
		hitsAir = only.fixedwing or only.gunship or false
		hitsGround = only.land or only.sink or only.turret or only.ship or only.swim or only.float or only.hover or false
	end
	-- Weapon damage is burst damage that can be delivered in 1s.
	local projectileMult = tonumber(wdcp.statsprojectiles) or ((tonumber(wdcp.script_burst) or wd.salvoSize) * wd.projectiles)
	local reloadTime = tonumber(wdcp.script_reload) or wd.reload
	local weaponDamage = tonumber(wdcp.stats_damage) * projectileMult / min(1, reloadTime)
	local aoe = wd.impactOnly and 0 or wd.damageAreaOfEffect
	-- Likho bomb is 192 so this gives a boost of 1 + 2.25. Feels about right.
	local aoeBoost = 1 + (aoe * aoe) / (128 * 128)
	-- FIXME: Afterburn and Newton damage aren't counted
	local weaponImportance = weaponDamage * aoeBoost
	local range = wdcp.truerange or wd.range
	return weaponImportance, range, hitsAir, hitsGround
end

-- Damage no unit can be blamed for counts for this much (see UnitDamaged)
local unattributedDamageFactor = 0.25

function UnitInfoCache:_unitStats(unitDefID)
	local cacheObject = self._unitStatsCache[unitDefID]
	if not cacheObject then
		local unitDef = UnitDefs[unitDefID]
		local isStatic = not spGetMovetype(unitDef)
		local importance = unitDef.metalCost
	    if unitDef.customParams.ismex then
			-- Give mexes a little extra buff since they are cheap but important
			importance = importance * 1.5
		end
		if unitDef.name == 'terraunit' then
			-- terraunit has fixed cost of 100000, actual estimated cost is a unit rules param that we try to read later
			importance = 500
		end
		local wImportance, wRange, hitsAir, hitsGround = self:_weaponStats(unitDef)
		cacheObject = { importance, isStatic, wImportance, wRange, unitDef.health or 1, unitDef.canFly or false,
			hitsAir or false, hitsGround or false }
		self._unitStatsCache[unitDefID] = cacheObject
	end
	return unpack(cacheObject)
end

function UnitInfoCache:_updatePosition(unitID, cacheObject)
	local location = getUnitLocation(unitID)
	local velocity = getUnitVelocity(unitID)
	if not location or not velocity then
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


	return true
end

function UnitInfoCache:watch(unitID, allyTeam, unitDefID)
	if not unitDefID then
		unitDefID = spGetUnitDefID(unitID)
	end
	local unitDef = UnitDefs[unitDefID]
	local name = spGetHumanName(unitDef, unitID)
	local importance, _, _, _ = self:_unitStats(unitDefID)
	-- What it cost, unlike importance, which is how much the camera cares about it
	local metal = unitDef.metalCost
	if unitDef.name == 'terraunit' then
		-- FIXME: This is set in unit_terraform.lua, but not accessible here?
		importance = spGetUnitRulesParam(unitID, 'terraform_estimate') or importance
		metal = importance
	end
	local cacheObject = { unitID = unitID, name = name, allyTeam = allyTeam, unitDefID = unitDefID, importance = importance,
		metal = metal, lastUpdatedFrame = gameFrame }
	if not self:_updatePosition(unitID, cacheObject) then
		return
	end
	self.cache[unitID] = cacheObject
	return self:get(unitID)
end

-- Returns unit info including rough position: where it was up to unitInfoCacheFrames ago
function UnitInfoCache:get(unitID)
	local cacheObject = self.cache[unitID]
	if cacheObject then
		local _, isStatic, weaponImportance, weaponRange = self:_unitStats(cacheObject.unitDefID)
		return cacheObject.location, cacheObject.velocity, cacheObject.importance, cacheObject.name, isStatic, weaponImportance, weaponRange
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
		elseif currentFrame - cacheObject.lastUpdatedFrame >= unitInfoCacheFrames then
			cacheObject.lastUpdatedFrame = currentFrame
			if not self:_updatePosition(unitID, cacheObject) then
				-- Something went wrong, drop from cache.
				self.cache[unitID] = nil
			elseif self.updateListener then
				self.updateListener(cacheObject)
			end
		end
	end
end

-- WORLD INFO

local mapSizeX, mapSizeZ = Game.mapSizeX, Game.mapSizeZ
local worldGridSize = 512
local mapGridX, mapGridZ = mapSizeX / worldGridSize, mapSizeZ / worldGridSize
local teamInfo, unitInfo

-- SHOT SELECTION

-- A challenger has to score this many times what the shot on show scores to replace it, more for
-- one that takes longer to get to (see transitionCost)
local switchBoostNear, switchBoostFar = 1.3, 2
-- While the shot is locked, it scores at least this share of the typical best score
local lockedShare = 0.5
-- transitionCost(location) returns 0 for something already framed, up to 1 for a cut. Defined
-- with the camera.
local transitionCost

-- CAMERA

local camTypeTracking = 'tracking'
-- The tracked units' centre is smoothed while it moves less than this in an update, moving this
-- share of the way there a second
local trackDampRange, trackDampRate = 256, 0.6
local camDiagMin = 1000
-- Share of the screen a shot's box may span, as projected, per axis (see frameBox)
local frameFill = 0.58
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
-- Close shots: a tight focus with nothing else going on near it is framed closer by narrowing the
-- lens, as a documentary or sports camera zooms in, rather than by moving the camera in. Each new
-- shot, cut or panned to, settles its zoom straight away, except that a fight opens at the usual
-- framing to set the scene. After that the zoom only changes once the shot has wanted the change
-- for a while, and not within holdSeconds of the last change, so it doesn't go in and out with
-- every jump or flicker of heat nearby: going in as the action starts after enterSeconds, and
-- staying in after it ends for leaveSeconds; but at once if its units no longer fit. A shot can't
-- open close within restSeconds of the last close-up ending, so close-ups don't follow each other
-- shot after shot; a shot can still go close as its action starts.
local closeUp = {
	-- Zoom (on the field of view) at most this much
	maxZoom = 1.6,
	-- Close when the shot's units would still fit zoomed in enterZoom; once close, until leaveZoom
	enterZoom = 1.4, leaveZoom = 1.15,
	-- Not while another focus hotter than the shot is within range of it, or one with imminentShare
	-- of its heat has something about to arrive (see foci.contact)
	range = worldGridSize * 3, rivalShare = 1, imminentShare = 0.2,
	enterSeconds = 1.5, leaveSeconds = 4, holdSeconds = 3, restSeconds = 15,
	-- Zoom changes take about twice smooth (s), or twice quickSmooth when the units are leaving the
	-- screen: zoomed in more than tooTight times what fits (which leaves a margin; see frameFill)
	smooth = 0.5, quickSmooth = 0.25, tooTight = 1.6,
}
-- Lulls: when a fight dies down, a wide, north-facing shot of the foci with most going on is offered.
-- It is offered once per fight, when recent damage drops well below its recent peak, scoring that
-- peak, so bigger fights ending are more likely to be shown.
-- (A table, as Lua 5.1 allows only 200 locals here.)
local lullConfig = {
	-- Damage (metal value per second) is averaged over a short and a long window. The short
	-- average's peak decays with this half-life.
	damageShortSeconds = 5, damageLongSeconds = 60, peakHalfLifeSeconds = 30,
	-- A fight is a peak of at least minPeak, and at least minPeakRatio times the long average
	minPeak = 10, minPeakRatio = 1.5,
	-- Fire when the short average falls to dropRatio of the peak; rearm once back over rearmRatio
	dropRatio = 0.3, rearmRatio = 0.6,
	-- Frame every focus with at least this share of the hottest's heat
	focusShare = 0.1,
	-- The wide shot scores the peak (metal/s) times this, fading by half after decaySeconds, or
	-- shownDecaySeconds once on show
	scoreScale = 6, decaySeconds = 4, shownDecaySeconds = 3,
	-- Frame at least this diagonal, and fill this share of the screen
	minDiag = 2000, fill = 0.9,
	pitch = -1.2,
}
-- Lull detection, defined with the shot code. damage has this second's damage, its short and
-- long running means and the short mean's decaying peak (metal value per second).
local lull = { damage = { now = 0, short = 0, long = 0, peak = 0 }, armed = false }

-- Scenes: a scene is a place where value is at stake, i.e. one side's metal within reach of the
-- other's armed units, now or in the next few seconds on their current heading. Clashes, raids and
-- bombing runs all score the same way, in metal. Orders are ignored: players change their minds,
-- so only where units are actually going counts, and less the further ahead it is.
local scenes = {
	-- Armed units are projected along their velocity to these times (s), with these weights
	horizon = { 0, 3, 6, 9 }, discount = { 1, 0.6, 0.3, 0.15 },
	-- Metal an armed unit puts at stake, per metal of its own cost
	leverage = 2,
	-- A cell's stake counts by how far it has risen over its average of this many seconds, so a
	-- standoff fades. Ignore rises below minStake.
	baselineSeconds = 30, minStake = 150,
	-- ... or of this many seconds, within watchedRange of where the camera is looking. A scene on
	-- show holds the camera only while its stake keeps growing.
	watchedSeconds = 3, watchedRange = worldGridSize,
	-- Add to foci for at most this many scenes a second, at least this many cells apart
	maxScenes = 2, separation = 3,
	-- A scene's units are those this close to its centre, and the other sides' armed units on their
	-- way, this close
	radius = worldGridSize * 0.75, threatRadius = worldGridSize * 1.5,
	-- Average stake by cell, and ally team names
	baseline = {}, names = {},
	-- This second's value (importance, for scoring), metal (what it cost, for the callout), armed
	-- strength over the horizon and armed strength now, by ally team and cell
	value = {}, metal = {}, power = {}, powerNow = {},
	-- Units by ally team and cell this second, and how much is going on by cell (see activityAt)
	count = {}, activity = {},
}

-- Orbits: once a shot is framed, the camera may slowly fly around the event to a heading that
-- shows more of what's going on nearby, keeps the map on screen and isn't blocked by terrain.
-- An orbit has to improve what's in view; heading preferences (turn, north) only pick between
-- equally good views.
local orbitConfig = {
	candidateStep = pi / 6,
	smoothTime = 3,
	-- Start planning this long after framing, and replan this often
	startFrames = 2 * framesPerSecond, planFrames = framesPerSecond,
	-- Orbit when another heading's view scores this much better, before heading preferences
	margin = 0.4,
	-- On a long hold, drift once to a heading at least driftMin away that scores nearly as well
	driftFrames = 6 * framesPerSecond, driftMin = pi / 9, driftTolerance = 0.2,
	-- activity: mean log10 activity in view; offMap: share of view off the map; occluded: terrain
	-- samples blocking the line of sight; turn: per half turn from the current heading; north: per
	-- quarter turn from north
	headingWeights = { activity = 1, offMap = 3, occluded = 0.5, turn = 0.3, north = 0.3 },
	headingSamples = { -0.9, -0.45, 0, 0.45, 0.9 },
}
-- Shot lock: a new shot holds until it has framed its event, then for minShotFrames more. Only a
-- challenger that beats it with the pick boost multiplied by shotLockBoost can cut in sooner.
-- If framing never happens (e.g. user control), the lock gives up after maxShotLockFrames.
local minShotFrames = 2 * framesPerSecond
local maxShotLockFrames = 3 * framesPerSecond
local shotLockBoost = 2
-- A unit can be counted as stunned again after this long
local stunFrames = 10 * framesPerSecond
local mapEdgeBorder = worldGridSize * 0.5
-- Near the map's edge the camera looks off centre to keep less of the view off the map, as long as
-- what it frames stays within edgeFill of the screen, and the middle of the shot within edgeOffset
-- of the way from the middle of the screen to its edge (see edgeShift)
local edgeFill, edgeOffset = 0.95, 0.3

-- A shot counts as framed once its tracking box is on screen and its centre is in the middle half.
local framedCentre = 0.25

local display, initialCameraState, camera
-- What the camera is showing: a focus, or a wide shot (see lull.wide)
local shown

-- Whether a world location is in view
local function onScreen(location)
	local vsx, vsy = spGetViewGeometry()
	local sx, sy, sz = spWorldToScreenCoords(location[1], location[2], location[3])
	return sx and sz >= 0 and sz <= 1 and sx >= 0 and sx <= vsx and sy >= 0 and sy <= vsy or false
end

-- FOCI
-- A focus is a place where things are happening. Damage, deaths, captures, building, units given
-- orders and value coming under threat (see scenes) each add their metal to the nearest focus, or
-- start one. A focus keeps that metal by kind and by side in one-second bins over the last few
-- seconds, which give its heat, and in totals since it formed, for the callout. The camera shows
-- the focus that scores best, and the callout talks about it.
-- (A table, as Lua 5.1 allows only 200 locals here.)
local foci = {
	-- Input joins the nearest focus whose centre is this close, and foci this close merge
	joinRange = 512, mergeRange = 384,
	-- An attacker this far from what it hit isn't framed with it, and one further than coreRange
	-- is only at the focus's edge (see foci.enlist)
	attackerRange = 768, coreRange = 384,
	-- The camera frames a focus's other units this far from its middle (see foci.frame)
	frameReach = 384,
	-- A close shot keeps the focus's units within contextReach on screen, if not framed (see closeUp)
	contextReach = 768,
	-- A shot about particular units (see foci.frame) leaves room ahead of them for where they will be
	-- in leadSeconds, up to leadMax away
	leadSeconds = 2, leadMax = 400,
	-- At most this many foci. When full, the weakest goes for new input, unless that is weaker still.
	cap = 32,
	-- One-second bins, each worth binDecay times the next newer one in heat
	bins = 16, binDecay = 0.8,
	-- Heat is metal times these. A kill counts as damage and again as a death, so kills count
	-- double. Also kept, for the callout only: kills by the killer's side and dealt (damage) by
	-- the attacker's side; the rest are by the side that lost or did it.
	weights = { damage = 1, destroyed = 1, captured = 1.5, building = 0.25, built = 0.5, stake = 0.35, contact = 1, orders = 0.1 },
	-- Contact: an armed unit closing on something of the enemy's it can hit, due in range within
	-- contactSeconds, adds the metal it could destroy there in a second, less the further off
	contactSeconds = 6,
	-- A unit due in range within imminentSeconds holds its focus on show: a challenger needs
	-- imminentBoost times more to cut away just before the action
	imminentSeconds = 3, imminentBoost = 1.5,
	-- A unit is framed with its focus for this long after it was last involved, or once dead, deadSeconds
	unitSeconds = 8, deadSeconds = 2,
	-- A unit's orders count once in this long
	orderSeconds = 8,
	-- Passe: seconds watched, rising by 1/s while the camera is within passeRange and falling by
	-- 1/s otherwise. It halves the score at passeMid, sparing heat from the last freshSeconds so a
	-- fight still going on holds the camera.
	passeRange = 512, passeMid = 10, passeSlope = 0.4, freshSeconds = 2,
	-- An allied cursor this close multiplies the score by this
	cursorRange = 512, cursorBoost = 1.5,
	-- A focus this hot and this close to the shot is taken into frame for a few seconds
	asideHeat = 1000, asideRange = worldGridSize * 2.5, asideFrames = 3 * framesPerSecond,
	-- Moments that are news in themselves: losing a commander or something costing highlightMetal,
	-- a capture costing captureHighlightMetal, or finishing something costing builtHighlightMetal.
	-- One adds its metal to the score, halving every highlightHalfLife seconds and ignoring passe.
	highlightMetal = 750, captureHighlightMetal = 300, builtHighlightMetal = 1500, highlightHalfLife = 3,
	-- A unit morphed (or a commander upgraded) from another counts as this share of its cost: the
	-- player paid only the difference, but it can change a lot. Units being morphed into are kept.
	morphShare = 0.5, morphed = {},
	-- Running mean of the best score, over about this many seconds
	typicalSeconds = 30, typical = 0,
	-- Heat by cell, for choosing headings (see scenes.activityAt), counts this much less than a unit
	cellHeatScale = 10, cells = {},
	list = {}, slot = 1, lastId = 0,
}

function foci.new(x, z)
	foci.lastId = foci.lastId + 1
	local f = { id = foci.lastId, x = x, z = z, mass = 0, heat = 0, pending = 0, score = 0, watched = 0,
		bins = {}, totals = {}, units = {}, core = {}, staked = {}, players = {}, born = gameFrame }
	foci.list[#foci.list + 1] = f
	return f
end

-- The nearest focus to (x, z) within range
function foci.near(x, z, range)
	local best, bestD = nil, range * range
	for _, f in ipairs(foci.list) do
		local dx, dz = f.x - x, f.z - z
		local d = dx * dx + dz * dz
		if d <= bestD then
			best, bestD = f, d
		end
	end
	return best
end

-- Add metal of a kind to a focus's bins and totals, for a side
function foci.record(f, metric, allyTeam, metal)
	local bin = f.bins[foci.slot]
	if not bin then
		bin = {}
		f.bins[foci.slot] = bin
	end
	local m = bin[metric]
	if not m then
		m = {}
		bin[metric] = m
	end
	m[allyTeam] = (m[allyTeam] or 0) + metal
	local t = f.totals[metric]
	if not t then
		t = {}
		f.totals[metric] = t
	end
	t[allyTeam] = (t[allyTeam] or 0) + metal
end

-- Add metal of a kind for a side at (x, z), involving unitID, and otherID too if it is close. Returns
-- the focus, or nil if the input was too slight to start one.
function foci.add(metric, allyTeam, metal, x, z, unitID, otherID)
	if not metal or metal <= 0 or not x or not z or not allyTeam then
		return
	end
	local weighted = metal * (foci.weights[metric] or 0)
	local f = foci.near(x, z, foci.joinRange)
	if not f then
		if #foci.list >= foci.cap then
			local weakest, weakestHeat = nil, huge
			for i, other in ipairs(foci.list) do
				local heat = other.heat + other.pending
				if other ~= shown and heat < weakestHeat then
					weakest, weakestHeat = i, heat
				end
			end
			if not weakest or weighted <= weakestHeat then
				return
			end
			table.remove(foci.list, weakest)
		end
		f = foci.new(x, z)
	end
	foci.record(f, metric, allyTeam, metal)
	if weighted > 0 then
		-- The centre follows the input, by its share of what has come in lately
		f.mass, f.pending = f.mass + weighted, f.pending + weighted
		f.x, f.z = f.x + (x - f.x) * weighted / f.mass, f.z + (z - f.z) * weighted / f.mass
	end
	-- Who is in on it, by player: the unit's, and the other's if close
	local function involve(id)
		local team = spGetUnitTeam(id)
		if team then
			f.players[team] = (f.players[team] or 0) + metal
		end
	end
	if unitID then
		foci.enlist(f, unitID, 'core')
		involve(unitID)
	end
	if otherID then
		local location = unitInfo:get(otherID)
		local d = location and length(location[1] - x, location[3] - z)
		if d and d <= foci.attackerRange then
			foci.enlist(f, otherID, d <= foci.coreRange and 'core' or 'edge')
			involve(otherID)
		end
	end
	return f
end

-- A unit is in on a focus, and framed with it (see foci.frame), as of now. How: 'core' when it was in
-- what happened there, or close by; 'staked' when it is what a stake there is about; 'edge' when it
-- is on its way or shooting in from afar. The focus goes where its core units are, failing those its
-- staked ones (see foci.around).
function foci.enlist(f, unitID, how)
	f.units[unitID] = gameFrame
	if how ~= 'edge' then
		f[how][unitID] = gameFrame
	end
end

-- A moment that is news in itself (see highlightMetal): { kind, metal, location, ... }. It replaces
-- one that is worth less by now.
function foci.highlight(f, h)
	if not f then
		return
	end
	h.frame = gameFrame
	if foci.highlightBonus(f) <= h.metal then
		f.highlight = h
	end
end

function foci.highlightBonus(f)
	local h = f.highlight
	return h and h.metal * 0.5 ^ ((gameFrame - h.frame) / framesPerSecond / foci.highlightHalfLife) or 0
end

-- The metal of a kind in the last seconds bins: in all, and by side
function foci.recent(f, metric, seconds)
	local total, bySide = 0, {}
	for age = 0, min(seconds, foci.bins) - 1 do
		local bin = f.bins[(foci.slot - 1 - age) % foci.bins + 1]
		local m = bin and bin[metric]
		if m then
			for side, v in pairs(m) do
				bySide[side], total = (bySide[side] or 0) + v, total + v
			end
		end
	end
	return total, bySide
end

-- Weighted metal over the bins, newest (the one filling) first, older ones worth less. Also returns
-- the part from the last freshSeconds.
function foci.heatOf(f)
	local heat, fresh, w = 0, 0, 1
	for age = 0, foci.bins - 1 do
		if age == foci.freshSeconds then
			fresh = heat
		end
		local bin = f.bins[(foci.slot - 1 - age) % foci.bins + 1]
		if bin then
			for metric, m in pairs(bin) do
				local weight = foci.weights[metric]
				if weight then
					for _, v in pairs(m) do
						heat = heat + v * weight * w
					end
				end
			end
		end
		w = w * foci.binDecay
	end
	return heat, fresh
end

-- The kind of thing mostly going on lately, by weighted metal
function foci.kind(f, seconds)
	local best, bestValue = nil, 0
	for metric, weight in pairs(foci.weights) do
		local value = foci.recent(f, metric, seconds) * weight
		if value > bestValue then
			best, bestValue = metric, value
		end
	end
	return best
end

-- Add each side's amounts per metric into another such table
local function addSides(into, from)
	for metric, m in pairs(from) do
		local km = into[metric] or {}
		into[metric] = km
		for side, v in pairs(m) do
			km[side] = (km[side] or 0) + v
		end
	end
end

-- Fold gone into keep
function foci.absorb(keep, gone)
	local mass = keep.mass + gone.mass
	if mass > 0 then
		keep.x = (keep.x * keep.mass + gone.x * gone.mass) / mass
		keep.z = (keep.z * keep.mass + gone.z * gone.mass) / mass
	end
	keep.mass, keep.pending, keep.heat = mass, keep.pending + gone.pending, keep.heat + gone.heat
	for slot, bin in pairs(gone.bins) do
		keep.bins[slot] = keep.bins[slot] or {}
		addSides(keep.bins[slot], bin)
	end
	addSides(keep.totals, gone.totals)
	for _, how in ipairs({ 'units', 'core', 'staked' }) do
		for unitID, frame in pairs(gone[how]) do
			keep[how][unitID] = max(keep[how][unitID] or 0, frame)
		end
	end
	for team, v in pairs(gone.players) do
		keep.players[team] = (keep.players[team] or 0) + v
	end
	keep.watched, keep.born = max(keep.watched, gone.watched), min(keep.born, gone.born)
	keep.imminent = max(keep.imminent or 0, gone.imminent or 0)
	if gone.highlight and foci.highlightBonus(gone) > foci.highlightBonus(keep) then
		keep.highlight = gone.highlight
	end
	if gone.order and (not keep.order or gone.order.frame > keep.order.frame) then
		keep.order = gone.order
	end
	local b = gone.lastBuilt
	if b and (not keep.lastBuilt or b.metal > keep.lastBuilt.metal) then
		keep.lastBuilt = b
	end
end

-- Foci that have come close merge. The one on show keeps its identity, otherwise the heavier.
function foci.merge()
	local list = foci.list
	for i = #list, 2, -1 do
		local a = list[i]
		for j = 1, i - 1 do
			local b = list[j]
			if a and length(a.x - b.x, a.z - b.z) <= foci.mergeRange then
				local keepA = a == shown or b ~= shown and a.mass > b.mass
				if keepA then
					foci.absorb(a, b)
					table.remove(list, j)
				else
					foci.absorb(b, a)
					table.remove(list, i)
				end
				break
			end
		end
	end
end

-- The middle of a focus's core units (see foci.enlist), each counting less the longer since it was
-- in on it that way, and how far out from there most of them (three quarters by that count) are.
-- Failing core units, its staked ones, and failing those, any. When they are in more than one
-- group (units within coreRange of one of them), the middle of the heaviest, rather than the empty
-- ground between them. A dead unit counts where it was last seen, for deadSeconds: the action has
-- moved on. Also their height, and the middle of all of them, which is where the focus itself
-- sits. Nil when none of its units are left.
function foci.around(f)
	local units, total, x, y, z = {}, 0, 0, 0, 0
	for _, how in ipairs({ 'core', 'staked', 'units' }) do
		for unitID, frame in pairs(f[how]) do
			local info = unitInfo.cache[unitID]
			local live = getSeenLocation(unitID)
			local location = live or info and info.location
			local seconds = (live or not info or not info.removeAfterFrame) and foci.unitSeconds or foci.deadSeconds
			local weight = max(0, 1 - (gameFrame - frame) / (seconds * framesPerSecond))
			if location and weight > 0 then
				units[#units + 1] = { location, weight }
				total, x, y, z = total + weight, x + weight * location[1], y + weight * location[2], z + weight * location[3]
			end
		end
		if total > 0 then
			break
		end
	end
	if total == 0 then
		return nil
	end
	local mx, mz = x / total, z / total
	local best, most = nil, 0
	for _, a in ipairs(units) do
		local weight = 0
		for _, b in ipairs(units) do
			if length(a[1][1] - b[1][1], a[1][3] - b[1][3]) <= foci.coreRange then
				weight = weight + b[2]
			end
		end
		if weight > most then
			best, most = a, weight
		end
	end
	total, x, y, z = 0, 0, 0, 0
	for _, unit in ipairs(units) do
		local location, weight = unit[1], unit[2]
		if length(location[1] - best[1][1], location[3] - best[1][3]) <= foci.coreRange then
			total, x, y, z = total + weight, x + weight * location[1], y + weight * location[2], z + weight * location[3]
		end
	end
	x, y, z = x / total, y / total, z / total
	-- How far out from there most of its units are, leaving out another group's
	local near = {}
	total = 0
	for _, unit in ipairs(units) do
		unit[3] = length(unit[1][1] - x, unit[1][3] - z)
		if unit[3] <= 2 * foci.coreRange then
			near[#near + 1], total = unit, total + unit[2]
		end
	end
	units = near
	table.sort(units, function(a, b) return a[3] < b[3] end)
	local far, sum = 0, 0
	for _, unit in ipairs(units) do
		far, sum = unit[3], sum + unit[2]
		if sum >= 0.75 * total then
			break
		end
	end
	return x, z, far, y, mx, mz
end

-- What the camera frames for a focus, from where its units are now: where to look, how that is
-- moving (per frame), the points that must be in shot, and the further units a close shot should
-- still keep on screen (contextReach). When the callout names units (subjects: unitID -> last
-- location), the shot is about them: it looks ahead of them by where they are going, so they sit
-- back from the middle with room in front. Otherwise it looks at the focus's middle (see
-- foci.around), keeping round most of the units it is about (inside its ring, which has a
-- margin) and a fresh highlight's spot. Either way, with the rest of its units within frameReach
-- (the trouble on its way, a shooter further off). A wide shot frames its corners.
function foci.frame(f, subjects)
	if f.wide then
		local look, points = { 0, 0, 0 }, {}
		for i, c in ipairs(f.corners) do
			look = { look[1] + c[1] / #f.corners, look[2] + c[2] / #f.corners, look[3] + c[3] / #f.corners }
			points[i] = { c[1], c[3] }
		end
		return look, { 0, 0, 0 }, points, {}
	end
	local points, n, x, y, z, vx, vz = {}, 0, 0, 0, 0, 0, 0
	for unitID, last in pairs(subjects or {}) do
		local location = getSeenLocation(unitID) or last
		local uvx, _, uvz = spGetUnitVelocity(unitID)
		points[#points + 1] = { location[1], location[3] }
		n, x, y, z = n + 1, x + location[1], y + location[2], z + location[3]
		vx, vz = vx + (uvx or 0), vz + (uvz or 0)
	end
	if n > 0 then
		x, y, z, vx, vz = x / n, y / n, z / n, vx / n, vz / n
		local lx, lz = vx * foci.leadSeconds * framesPerSecond, vz * foci.leadSeconds * framesPerSecond
		local lead = length(lx, lz)
		if lead > foci.leadMax then
			lx, lz = lx * foci.leadMax / lead, lz * foci.leadMax / lead
		end
		points[#points + 1] = { x + 2 * lx, z + 2 * lz }
		x, z = x + lx, z + lz
	else
		local far
		x, z, far, y = foci.around(f)
		if not x then
			x, z, far = f.x, f.z, 0
			y = spGetGroundHeight(x, z)
		end
		for i = 1, 8 do
			local angle = i * pi / 4
			points[i] = { x + far * sin(angle), z + far * cos(angle) }
		end
		local h = f.highlight
		if h and gameFrame - h.frame < overlay.highlightSeconds * framesPerSecond then
			points[#points + 1] = { h.x, h.z }
		end
	end
	local context = {}
	for unitID in pairs(f.units) do
		local info = unitInfo.cache[unitID]
		local location = getSeenLocation(unitID) or info and info.location
		local d = location and length(location[1] - x, location[3] - z)
		if d and d <= foci.frameReach then
			points[#points + 1] = { location[1], location[3] }
		elseif d and d <= foci.contextReach then
			context[#context + 1] = { location[1], location[3] }
		end
	end
	return { x, y, z }, { vx, 0, vz }, points, context
end

-- Once a second: move onto its units, merge, score, then start a new bin and let foci with nothing
-- left go. Events pull a focus towards where they happen as they come in; here it settles on the
-- middle of the units in them (the camera and the ring keep to the heaviest group of those).
function foci.update()
	local unitFrames = foci.unitSeconds * framesPerSecond
	for _, f in ipairs(foci.list) do
		local _, _, _, _, x, z = foci.around(f)
		if x then
			f.x, f.z = bound(x, 0, mapSizeX), bound(z, 0, mapSizeZ)
		end
	end
	foci.merge()
	local wx, _, wz = unpack(display.location)
	local cursors = {}
	for _, acp in pairs(WG.alliedCursorsPos or {}) do
		if acp[1] and acp[2] then
			cursors[#cursors + 1] = acp
		end
	end
	local best = 0
	for _, f in ipairs(foci.list) do
		local fresh
		f.heat, fresh = foci.heatOf(f)
		f.pending, f.mass = 0, f.mass * foci.binDecay
		for team, v in pairs(f.players) do
			f.players[team] = v >= 1 and v * foci.binDecay or nil
		end
		local watched = not display.isWide and length(f.x - wx, f.z - wz) <= foci.passeRange
		f.watched = watched and f.watched + 1 or max(0, f.watched - 1)
		local score = fresh + (f.heat - fresh) * (1 - logistic(foci.passeSlope * (f.watched - foci.passeMid)))
		for _, c in ipairs(cursors) do
			if length(c[1] - f.x, c[2] - f.z) <= foci.cursorRange then
				score = score * foci.cursorBoost
				break
			end
		end
		f.score = score + foci.highlightBonus(f)
		best = max(best, f.score)
		for unitID, frame in pairs(f.units) do
			if gameFrame - frame > unitFrames then
				f.units[unitID] = nil
			end
		end
		for _, how in ipairs({ 'core', 'staked' }) do
			for unitID, frame in pairs(f[how]) do
				if gameFrame - frame > unitFrames then
					f[how][unitID] = nil
				end
			end
		end
	end
	foci.typical = foci.typical + (best - foci.typical) / foci.typicalSeconds
	foci.cells = {}
	for _, f in ipairs(foci.list) do
		scenes.spread(foci.cells, f.x, f.z, f.heat)
	end

	if STATS then
		local sorted = {}
		for i, f in ipairs(foci.list) do
			sorted[i] = f
		end
		table.sort(sorted, function(a, b) return a.score > b.score end)
		for i = 1, min(4, #sorted) do
			local f = sorted[i]
			spEcho(string.format('rc-focus,%d,%.0f,%.0f,%.0f,%.0f,%d,%s,%d', f.id, f.x, f.z, f.heat, f.score, f.watched,
				foci.kind(f, 6) or 'none', #foci.list))
		end
	end

	foci.slot = foci.slot % foci.bins + 1
	for i = #foci.list, 1, -1 do
		local f = foci.list[i]
		f.bins[foci.slot] = nil
		if not next(f.bins) and f ~= shown then
			table.remove(foci.list, i)
		end
	end
end

-- Metal a unit has lost to damage: its cost (as far as it is built) by the share of its health
-- taken, not counting overkill. Damage is reported once taken off, so health can be below 0.
function foci.damageValue(unitID, unitDefID, damage, paralyzer)
	local unitDef = UnitDefs[unitDefID]
	local health, maxHealth, _, _, buildProgress = spGetUnitHealth(unitID)
	if not unitDef or unitDef.customParams.dontcount or not maxHealth or maxHealth <= 0 then
		return 0
	end
	if not paralyzer and health and health < 0 then
		damage = max(0, damage + health)
	end
	return unitDef.metalCost * (buildProgress or 1) * min(damage, maxHealth) / maxHealth
end

-- Once a second per unit (see UnitInfoCache): count what has gone into building it
function foci.observe(info)
	if not info.unfinished or not info.unitID then
		return
	end
	local _, _, _, _, buildProgress = spGetUnitHealth(info.unitID)
	if not buildProgress then
		return
	end
	local delta = buildProgress - (info.progress or 0)
	info.progress = buildProgress
	if delta > 0 then
		local x, _, z = unpack(info.location)
		foci.add('building', info.allyTeam, delta * info.metal, x, z, info.unitID, info.builderID)
	end
end

-- Once a second per unit (see UnitInfoCache): if it is closing on the enemy, add contact where it
-- will hit, for the target it can do most to soonest. Units stood still in range leave it to damage.
function foci.contact(info)
	local _, _, dps, range, _, _, hitsAir, hitsGround = unitInfo:_unitStats(info.unitDefID)
	if dps <= 0 or info.unfinished then
		return
	end
	local x, _, z = unpack(info.location)
	local vx, _, vz = unpack(info.velocity)
	-- Velocities are per frame
	local horizon = foci.contactSeconds * framesPerSecond
	local best, target, soon = 0, nil, false
	for _, id in ipairs(spGetUnitsInCylinder(x, z, range + length(vx, vz) * horizon + worldGridSize / 2)) do
		local other = unitInfo.cache[id]
		if other and other.allyTeam ~= info.allyTeam and not other.removeAfterFrame then
			local _, _, _, _, health, flies = unitInfo:_unitStats(other.unitDefID)
			local dx, dz = other.location[1] - x, other.location[3] - z
			local d = length(dx, dz)
			local closing = d > 0 and ((vx - other.velocity[1]) * dx + (vz - other.velocity[3]) * dz) / d or 0
			if closing > 0 and (flies and hitsAir or not flies and hitsGround) then
				local t = max(0, d - range) / closing
				local metal = t < horizon and other.metal * min(1, dps / health) * (1 - t / horizon) or 0
				if metal > best then
					best, target = metal, other
					soon = d > range and t <= foci.imminentSeconds * framesPerSecond
				end
			end
		end
	end
	if target then
		local tx, _, tz = unpack(target.location)
		local f = foci.add('contact', target.allyTeam, best, tx, tz, target.unitID, info.unitID)
		if f then
			foci.record(f, 'threat', info.allyTeam, best)
			if soon then
				f.imminent = gameFrame
			end
		end
	end
end

function foci.isCommander(unitID, unitDef)
	return unitDef.customParams.commtype or spGetUnitRulesParam(unitID, "comm_level") ~= nil
end

-- Units given orders together are one move, for the callout
function foci.order(f, unitID, team, name, from, to)
	local o = f.order
	if not o or o.team ~= team or gameFrame - o.frame > 3 * framesPerSecond then
		o = { team = team, units = {}, names = {} }
		f.order = o
	end
	-- The arrow stays with the unit it is from while the squad gets its orders
	o.frame = gameFrame
	if not o.unitID or o.unitID == unitID then
		o.from, o.to, o.unitID = { from[1], from[3] }, { to[1], to[3] }, unitID
	end
	if not o.units[unitID] then
		o.units[unitID], o.names[name] = true, (o.names[name] or 0) + 1
	end
end

-- Once a second: a hot focus close to the shot is taken into frame for a few seconds (see
-- updateCamera)
function foci.aside()
	if not shown or display.isWide then
		return
	end
	local wx, _, wz = unpack(display.location)
	local best
	for _, f in ipairs(foci.list) do
		if f ~= shown and f.heat >= foci.asideHeat and length(f.x - wx, f.z - wz) <= foci.asideRange
		    and (not best or f.heat > best.heat) then
			best = f
		end
	end
	if best then
		display.aside = { best.x, best.z, gameFrame }
	end
end


-- OVERLAY
-- A callout pointing at the focus on show, saying what is going on there, with what each side has
-- killed there; and markings on the ground: a ring round the focus, or an arrow for a move.
-- A wide shot gets a board instead, with what each side's units are worth.

-- A unit dying with no attacker is credited to whoever hit it this recently
overlay.creditFrames = 20 * framesPerSecond
-- Text size and arrow width, the first for a 1080 high view
overlay.textSize, overlay.arrowWidth = 16, 36
-- How opaque the pointer and the ring are
overlay.lineAlpha = 0.8
-- The callout speaks of the last recentSeconds. Something new to say replaces what it says once it
-- has held for holdSeconds, whether about something else or naming other units, but a highlight
-- leads at once, for highlightSeconds, and a fight's sides change at once.
overlay.recentSeconds, overlay.holdSeconds, overlay.highlightSeconds = 6, 3, 6
-- Fighting is what the callout is about once this much metal has been lost lately. A side is in
-- the fight if it has lost at least fightShare of what the side losing most has.
overlay.minCombat, overlay.fightShare = 30, 0.15
-- The ring takes in most of the focus's units, within these radii, and follows the focus over
-- about ringSeconds
overlay.ringMin, overlay.ringMax, overlay.ringSeconds = 256, 640, 0.5
-- A fight's colour, as it is no one side's
overlay.neutral = { 0.6, 0.6, 0.6 }
overlay.radius = overlay.ringMin

-- A player and their side, in the player's colour
function overlay.player(teamID)
	local info = teamInfo[teamID]
	-- A team of one is named after its player
	local team = info.allyTeamName ~= info.name and " (" .. info.allyTeamName .. ")" or ""
	return overlay.coloured(info.name .. team, info.color)
end

-- Text in a team's colour (colour code bytes can't be 0)
function overlay.coloured(text, color)
	return string.char(255, max(1, color[1] * 255), max(1, color[2] * 255), max(1, color[3] * 255)) .. text .. "\008"
end

-- A side at a focus, by who on it is in on what is happening there lately: the player most
-- involved, in their colour, or if others are close behind (alsoShare of the first), the team's
-- name in its colour with how many. With nobody, the team's name. Also returns the colour.
overlay.alsoShare = 0.5
function overlay.side(allyTeam, f)
	local list = {}
	for team, v in pairs(f and f.players or {}) do
		local info = teamInfo[team]
		if info and info.allyTeam == allyTeam then
			list[#list + 1] = { team = team, v = v }
		end
	end
	if not list[1] then
		local color = overlay.allyColor[allyTeam] or { 1, 1, 1 }
		return overlay.coloured(scenes.names[allyTeam] or "?", color), color
	end
	table.sort(list, function(a, b) return a.v > b.v end)
	local more = 0
	for i = 2, #list do
		if list[i].v >= overlay.alsoShare * list[1].v then
			more = more + 1
		end
	end
	if more > 0 then
		local color = overlay.allyColor[allyTeam] or { 1, 1, 1 }
		return overlay.coloured((scenes.names[allyTeam] or "?") .. " (" .. (more + 1) .. ")", color), color
	end
	local first = teamInfo[list[1].team]
	return overlay.coloured(first.name, first.color), first.color
end

function overlay.metal(amount)
	amount = floor(amount / 10 + 0.5) * 10
	return amount < 1000 and tostring(amount) or string.format("%d,%03d", floor(amount / 1000), amount % 1000)
end

-- Sides keep one order everywhere, as they started out on the map: west to east, or north to south
-- if they started further apart that way. Set once start positions are known.
function overlay.orderSides()
	local starts, xMin, xMax, zMin, zMax = {}, huge, -huge, huge, -huge
	for teamID, info in pairs(teamInfo) do
		local x, _, z = Spring.GetTeamStartPosition(teamID)
		if x and x >= 0 and overlay.allyColor[info.allyTeam] then
			local s = starts[info.allyTeam] or { 0, 0, 0 }
			starts[info.allyTeam] = { s[1] + x, s[2] + z, s[3] + 1 }
		end
	end
	for _, s in pairs(starts) do
		s[1], s[2] = s[1] / s[3], s[2] / s[3]
		xMin, xMax, zMin, zMax = min(xMin, s[1]), max(xMax, s[1]), min(zMin, s[2]), max(zMax, s[2])
	end
	if next(starts) then
		overlay.order = {}
		for allyTeam, s in pairs(starts) do
			overlay.order[allyTeam] = xMax - xMin >= zMax - zMin and s[1] or s[2]
		end
	end
end

-- Puts a list of ally teams in that order, and returns it
function overlay.sortSides(list)
	local order = overlay.order or {}
	table.sort(list, function(a, b)
		local oa, ob = order[a] or a, order[b] or b
		if oa ~= ob then
			return oa < ob
		end
		return a < b
	end)
	return list
end

-- A headline for a fight between sides, as each side's name in its colour, and the colour for it:
-- grey for a fight, as it is neither side's
function overlay.fightHeadline(sides, f)
	local list, names = {}, {}
	for allyTeam in pairs(sides) do
		if overlay.allyColor[allyTeam] and scenes.names[allyTeam] then
			list[#list + 1] = allyTeam
		end
	end
	local color
	for i, allyTeam in ipairs(overlay.sortSides(list)) do
		names[i], color = overlay.side(allyTeam, f)
	end
	if #names >= 2 then
		return table.concat(names, " vs "), overlay.neutral
	end
	return names[1] and names[1] .. " under fire" or "Fighting", color or overlay.neutral
end

-- How far out the ring goes round its focus: past most of its units (see foci.around)
function overlay.ringRadius(f)
	local _, _, far = foci.around(f)
	return overlay.ringFor(far)
end

-- The ring's radius when most of the focus's units are within far of its middle
function overlay.ringFor(far)
	return bound((far or 0) + 64, overlay.ringMin, overlay.ringMax)
end

-- The camera has a new shot: the callout is about its focus from now on
function overlay.show(f)
	overlay.focus, overlay.kind, overlay.pending, overlay.headline, overlay.detail = f, nil, nil, nil, nil
	overlay.said, overlay.saidFrame = nil, nil
	overlay.subjects, overlay.tally, overlay.ringed = {}, {}, false
	overlay.arrowFrom, overlay.arrowTo, overlay.left, overlay.closing = nil, nil, nil, nil
	if not f.wide then
		overlay.ringX, overlay.ringZ, overlay.radius = f.x, f.z, overlay.ringRadius(f)
		overlay.ringTarget = overlay.radius
	end
	overlay.update()
end

-- What the focus is about lately: a highlight, a fight (trouble incoming counts as one), building,
-- something built or units on the move. Lately is the last recentSeconds or, if nothing
-- happened then, all the bins. Also returns what each side has lost then, for the sides that count.
function overlay.about(f)
	local h = f.highlight
	if h and gameFrame - h.frame < overlay.highlightSeconds * framesPerSecond then
		return 'highlight', {}
	end
	for _, window in ipairs({ overlay.recentSeconds, foci.bins }) do
		local lost, total, most = {}, 0, 0
		for _, metric in ipairs({ 'damage', 'destroyed', 'captured' }) do
			local _, bySide = foci.recent(f, metric, window)
			for side, v in pairs(bySide) do
				lost[side], total = (lost[side] or 0) + v, total + v
				most = max(most, lost[side])
			end
		end
		for side, v in pairs(lost) do
			if v < overlay.fightShare * most then
				lost[side] = nil
			end
		end
		if total >= overlay.minCombat then
			return 'fight', lost
		end
		-- Otherwise whatever there is most of, weighted as for heat
		local best, bestValue = nil, 0
		for _, metric in ipairs({ 'stake', 'contact', 'building', 'built', 'orders' }) do
			local value = foci.recent(f, metric, window) * foci.weights[metric]
			if value > bestValue then
				best, bestValue = metric, value
			end
		end
		if best then
			return (best == 'stake' or best == 'contact') and 'fight' or best, lost
		elseif total > 0 then
			return 'fight', lost
		end
	end
	return nil, {}
end

-- The words for what the focus is about: headline, detail, colour, the units the headline names (or
-- the spot), and whether the pointer goes to the ring. Returns nothing if there is nothing to say.
function overlay.word(f, kind, lost, fresh)
	local grey, subjects = { 0.85, 0.85, 0.85 }, {}
	local function at(x, z)
		return { x, spGetGroundHeight(x, z), z }
	end
	local function stake(minimum)
		local metal = scenes.metalStake and scenes.around(scenes.metalStake, f.x, f.z)
		return metal and metal >= minimum and overlay.metal(metal) .. " metal at stake" or nil
	end
	if kind == 'highlight' then
		local h = f.highlight
		local player = h.team and teamInfo[h.team] and overlay.player(h.team)
		local headline
		if h.kind == 'destroyed' then
			headline = h.name .. overlay.blame(h.burning, h.by, player)
		else
			headline = h.name .. (h.kind == 'built' and h.verb or " captured") .. (player and " by " .. player or "")
		end
		subjects[h.unitID or -1] = at(h.x, h.z)
		return headline, nil, player and teamInfo[h.team].color or grey, subjects, false
	elseif kind == 'fight' then
		-- Everyone who has lost or dealt much here, or has much at stake or is the threat to it, so
		-- the sides don't come and go. With one side, it is under fire from no one known.
		local sides = {}
		for _, metrics in ipairs({ { 'damage', 'destroyed' }, { 'dealt' }, { 'stake', 'contact' }, { 'threat' } }) do
			local most = 0
			for _, metric in ipairs(metrics) do
				for _, v in pairs(f.totals[metric] or {}) do
					most = max(most, v)
				end
			end
			for _, metric in ipairs(metrics) do
				for side, v in pairs(f.totals[metric] or {}) do
					if v >= overlay.fightShare * most then
						sides[side] = true
					end
				end
			end
		end
		for side in pairs(lost) do
			sides[side] = true
		end
		local headline, color = overlay.fightHeadline(sides, f)
		return headline, stake(100), color, subjects, true
	elseif kind == 'building' then
		-- The costliest thing being built
		local unitID, metal = nil, 0
		for id in pairs(f.units) do
			local info = unitInfo.cache[id]
			if info and info.unfinished and not info.removeAfterFrame and info.metal > metal then
				unitID, metal = id, info.metal
			end
		end
		local team = unitID and spGetUnitTeam(unitID)
		if not team or not teamInfo[team] then
			return
		end
		local info = unitInfo.cache[unitID]
		local _, _, _, _, buildProgress = spGetUnitHealth(unitID)
		subjects[unitID] = { unpack(info.location) }
		return overlay.player(team) .. " making " .. info.name,
			string.format("%d%% of %s metal", floor((buildProgress or 0) * 100), overlay.metal(info.metal)),
			teamInfo[team].color, subjects, false
	elseif kind == 'built' then
		local b = f.lastBuilt
		if not b or not teamInfo[b.team] then
			return
		end
		subjects[b.unitID] = at(b.x, b.z)
		-- With others lately, what it all came to
		local n, metal = foci.recent(f, 'units', foci.bins), foci.recent(f, 'built', foci.bins)
		local detail = n > 1 and string.format("%d built here lately, %s metal", n, overlay.metal(metal)) or nil
		return b.name .. b.verb .. " by " .. overlay.player(b.team), detail, teamInfo[b.team].color, subjects, false
	elseif kind == 'orders' then
		local o = f.order
		if not o or not teamInfo[o.team] then
			return
		end
		local name, n = next(o.names)
		local label = next(o.names, name) and overlay.player(o.team) .. " squad" or n > 1 and n .. " " .. name .. "s" or name
		-- The unit the arrow is from: a squad can be spread out, at different speeds
		local info = unitInfo.cache[o.unitID]
		subjects[o.unitID] = info and { unpack(info.location) } or nil
		if fresh then
			overlay.arrowFrom, overlay.arrowTo = o.from, o.to
			overlay.left, overlay.closing = nil, nil
		end
		return label .. " moving", nil, teamInfo[o.team].color, subjects, false
	end
end

-- Once a second: what the callout says, and on a wide shot, what each side's units are worth
function overlay.update()
	if not overlay.order and gameFrame > 0 then
		overlay.orderSides()
	end
	-- What each side's units are worth, part-built ones as far as they have got, for the wide shot.
	-- Zero-K's end game graphs keep these per team.
	local worth = {}
	for teamID, info in pairs(teamInfo) do
		local value = spGetTeamRulesParam(teamID, "stats_history_unit_value_current")
		if value and overlay.allyColor[info.allyTeam] then
			value = value + (spGetTeamRulesParam(teamID, "stats_history_nano_partial_current") or 0)
			worth[info.allyTeam] = (worth[info.allyTeam] or 0) + value
		end
	end
	overlay.worth = worth

	local f = overlay.focus
	if not f or f.wide then
		return
	end
	overlay.ringTarget = overlay.ringRadius(f)

	-- Something new to say has to hold a while first, unless it is a highlight, or one ends, or a fight
	-- breaks out: the trouble has arrived
	local kind, lost = overlay.about(f)
	local fresh = false
	if kind and kind ~= overlay.kind then
		if not overlay.kind or kind == 'highlight' or overlay.kind == 'highlight' or kind == 'fight'
		    or kind == overlay.pending and gameFrame - overlay.pendingFrame >= overlay.holdSeconds * framesPerSecond
		    and gameFrame - (overlay.saidFrame or 0) >= overlay.holdSeconds * framesPerSecond then
			overlay.kind, overlay.pending, fresh = kind, nil, true
		elseif kind ~= overlay.pending then
			overlay.pending, overlay.pendingFrame = kind, gameFrame
		end
	elseif kind then
		overlay.pending = nil
	end
	local headline, detail, color, subjects, ringed = overlay.word(f, overlay.kind, lost, fresh)
	local said = headline and headline .. ':' .. tostring(next(subjects) or '')
	if said and said ~= overlay.said then
		if not fresh and overlay.said and overlay.kind ~= 'fight' and overlay.kind ~= 'highlight'
		    and gameFrame - overlay.saidFrame < overlay.holdSeconds * framesPerSecond then
			headline = nil
		else
			overlay.said, overlay.saidFrame = said, gameFrame
		end
	end
	if headline then
		if DEBUG and headline ~= overlay.headline then
			spEcho(string.format('rc-callout,%s,%d,%s', overlay.kind, f.id, headline))
		end
		overlay.headline, overlay.detail, overlay.color, overlay.subjects, overlay.ringed = headline, detail, color, subjects, ringed
		if overlay.kind ~= 'orders' then
			overlay.arrowFrom, overlay.arrowTo = nil, nil
		end
	end
	local fighting = overlay.kind == 'fight' or overlay.kind == 'highlight'
	overlay.tally = fighting and f.totals.kills or {}

	-- How fast a move is closing on its target, for the time to arrive
	local x, _, z = overlay.centre()
	local left = overlay.arrowTo and x and overlay.kind == 'orders' and length(overlay.arrowTo[1] - x, overlay.arrowTo[2] - z)
	if left and overlay.left then
		overlay.closing = ((overlay.closing or overlay.left - left) + overlay.left - left) / 2
	end
	overlay.left = left
end

-- Each frame: the ring follows its focus
function overlay.follow(dt)
	local f = overlay.focus
	if not f or f.wide or not overlay.ringX then
		return
	end
	-- Where its units are now, as the camera frames them (see foci.frame)
	local x, z, far = foci.around(f)
	if x then
		overlay.ringTarget = overlay.ringFor(far)
	end
	local k = min(1, dt / overlay.ringSeconds)
	x, z = x or f.x, z or f.z
	overlay.ringX, overlay.ringZ = overlay.ringX + (x - overlay.ringX) * k, overlay.ringZ + (z - overlay.ringZ) * k
	overlay.radius = overlay.radius + ((overlay.ringTarget or overlay.radius) - overlay.radius) * k
end

-- The middle of the units the headline names, and the top speed (elmos/s) of the slowest. A dead
-- unit stays where it was last seen.
function overlay.centre()
	local xSum, ySum, zSum, n, speed = 0, 0, 0, 0, huge
	for unitID, location in pairs(overlay.subjects) do
		local x, y, z = spGetUnitPosition(unitID)
		if x then
			location[1], location[2], location[3] = x, y, z
			speed = min(speed, UnitDefs[spGetUnitDefID(unitID)].speed)
		end
		xSum, ySum, zSum, n = xSum + location[1], ySum + location[2], zSum + location[3], n + 1
	end
	if n > 0 then
		return xSum / n, ySum / n, zSum / n, speed
	end
end

-- The selection shape Zero-K draws round a unit (see its gui_selectedunits_gl4.lua) on screen: a
-- square of its footprint for a building, turned with it, otherwise a circle across the footprint's
-- diagonal, at the unit's height (y) so one in the air, jumping or flying, still has it round it
function overlay.outline(unitID, x, y, z)
	local ud = UnitDefs[spGetUnitDefID(unitID)]
	local xs, zs = ud.xsize or 2, ud.zsize or 2
	local scale = tonumber(ud.customParams and ud.customParams.selection_scale) or 1
	local points = {}
	if ud.isImmobile then
		y = spGetGroundHeight(x, z)
		local a = (spGetUnitHeading(unitID) or 0) * 2 * pi / 65536
		local c, s = cos(a), sin(a)
		local hx, hz = 4 * xs * scale, 4 * zs * scale
		for _, k in ipairs({ { -1, 1 }, { 1, 1 }, { 1, -1 }, { -1, -1 } }) do
			local px, pz = k[1] * hx, k[2] * hz
			points[#points + 1] = { spWorldToScreenCoords(x + px * c + pz * s, y, z - px * s + pz * c) }
		end
		return points
	end
	return overlay.ring(x, z, 4 * sqrt(xs * xs + zs * zs) * scale, 16, nil, y)
end

-- How far along from (x1, y1) to (x2, y2) it first crosses the outline through points, or 0
function overlay.crossing(points, x1, y1, x2, y2)
	local dx, dy, first = x2 - x1, y2 - y1, 0
	for i, p in ipairs(points) do
		local q = points[i % #points + 1]
		local qx, qy = q[1] - p[1], q[2] - p[2]
		local denom = dx * qy - dy * qx
		if denom ~= 0 then
			local along = ((p[1] - x1) * qy - (p[2] - y1) * qx) / denom
			local on = ((p[1] - x1) * dy - (p[2] - y1) * dx) / denom
			if along >= 0 and along <= 1 and on >= 0 and on <= 1 and (first == 0 or along < first) then
				first = along
			end
		end
	end
	return first
end

-- Where n points round a ring on the ground are on screen, or as project (see overlay.projector)
-- puts them. Like the drawn ring, each follows the ground under it.
function overlay.ring(x, z, radius, n, project, y)
	project = project or spWorldToScreenCoords
	local points = {}
	for i = 1, n do
		local angle = i * 2 * pi / n
		local px, pz = x + radius * sin(angle), z + radius * cos(angle)
		points[i] = { project(px, y or spGetGroundHeight(px, pz), pz) }
	end
	return points
end

-- A function giving where a world point is on screen for a camera pose { look, dist, pitch, yaw, fov }
-- of the rig in updateCamera, like spWorldToScreenCoords does for the camera as it is
function overlay.projector(pose, vsx, vsy)
	local fx, fy, fz, rx, rz, ux, uy, uz = cameraAxes(pose.pitch, pose.yaw)
	local look, dist = pose.look, pose.dist
	local px, py, pz = look[1] - dist * fx, look[2] - dist * fy, look[3] - dist * fz
	local focal = vsy / 2 / tan(rad(pose.fov or defaultFov) / 2)
	return function(x, y, z)
		local dx, dy, dz = x - px, y - py, z - pz
		local depth = max(1, dx * fx + dy * fy + dz * fz)
		return vsx / 2 + focal * (dx * rx + dz * rz) / depth, vsy / 2 + focal * (dx * ux + dy * uy + dz * uz) / depth
	end
end

-- A flat arrow on the ground from one point to another
function overlay.arrow(x1, z1, x2, z2, color)
	local dx, dz = x2 - x1, z2 - z1
	local len, width = length(dx, dz), overlay.arrowWidth
	local head = min(width * 3, len * 0.4)
	if len < width then
		return
	end
	dx, dz = dx / len, dz / len
	local function vertex(along, across)
		local x, z = x1 + dx * along - dz * across, z1 + dz * along + dx * across
		gl.Vertex(x, max(0, spGetGroundHeight(x, z)) + 4, z)
	end
	-- One strip, so nothing overlaps: the stem, then out to the barbs and in to the tip
	gl.Color(color[1], color[2], color[3], 0.6)
	gl.BeginEnd(GL.TRIANGLE_STRIP, function()
		local steps = math.ceil((len - head) / 48)
		for i = 0, steps do
			vertex((len - head) * i / steps, width / 2)
			vertex((len - head) * i / steps, -width / 2)
		end
		local barb = min(width * 1.4, head * 0.5)
		vertex(len - head, barb)
		vertex(len - head, -barb)
		vertex(len, 0)
	end)
end

-- The shown units were given a new order: the arrow follows at once, the camera stays with the shot
function overlay.redirect(unitID, params)
	local target = #params == 1 and unitInfo:get(params[1]) or #params >= 3 and params
	local x, _, z = spGetUnitPosition(unitID)
	-- Small moves are mostly unit AI
	if target and x and length(target[1] - x, target[3] - z) >= 256 then
		overlay.arrowFrom, overlay.arrowTo = { x, z }, { target[1], target[3] }
		overlay.left, overlay.closing = nil, nil
	end
end

-- How a unit died, from what is known: "destroyed by Rogue of Player", or with no one to blame, by
-- fire or on its own
function overlay.blame(burning, unitName, player)
	local by = unitName and player and unitName .. " of " .. player or unitName or player
	return by and " destroyed by " .. by or burning and " destroyed by fire" or " destroyed"
end

function overlay.drawWorld()
	local f = overlay.focus
	if not f or f.wide or not overlay.headline or not options.show_commentary.value then
		return
	end
	local color = overlay.color
	gl.DepthTest(true)
	gl.LineWidth(3)
	local from, to = overlay.arrowFrom, overlay.arrowTo
	if from then
		overlay.arrow(from[1], from[2], to[1], to[2], color)
	elseif overlay.ringed then
		local x, z = overlay.ringX, overlay.ringZ
		gl.Color(color[1], color[2], color[3], overlay.lineAlpha)
		gl.DrawGroundCircle(x, spGetGroundHeight(x, z), z, overlay.radius, 48)
	end
	gl.DepthTest(false)
	gl.LineWidth(1)
	gl.Color(1, 1, 1, 1)
end

-- The game's own windows on screen, as { left, bottom, right, top }, so callouts can keep off them
function overlay.scanUI(vsx, vsy)
	local windows = {}
	-- Other widgets' windows can go away under us
	pcall(function()
		for _, window in ipairs(WG.Chili.Screen0.children) do
			local x, y, w, h = window.x, window.y, window.width, window.height
			-- Not the invisible full screen holders
			if w > 20 and h > 20 and w * h < vsx * vsy * 0.4 then
				windows[#windows + 1] = { x, vsy - y - h, x + w, vsy - y }
			end
		end
	end)
	return windows
end

-- How far the subject at (ax, ay) is out from the corner of a w by h callout at (bx, by) that the
-- pointer leaves from (see overlay.draw), across and up or down. Either is negative when the
-- pointer goes back across the callout.
function overlay.pointerOut(bx, by, w, h, ax, ay)
	local onLeft, below = bx + w / 2 < ax, by + h / 2 < ay
	return onLeft and ax - bx - w or bx - ax, below and ay - by - h or by - ay
end

-- Where to put a w by h callout for a subject at world point world, now at (ax, ay) on screen,
-- clear of a scene's ring round it if ringed. It is looked at again for each shot and once a second
-- after that, and only moves when it is in the way or for a clear gain: a new shot keeps it where
-- it is on screen if that will do.
function overlay.place(world, ax, ay, w, h, vsx, vsy, ringed)
	-- Off the subject by at least reach, more when zoomed in as the units are bigger on screen
	local reach, margin = vsy * 0.08 * (camera.settled and camera.settled.zoom or 1), vsy * 0.02
	local xMax, yMax = max(10, vsx - w - 10), max(10, vsy - h - 10)
	local fresh = overlay.placedFor ~= overlay.focus
	local box, offset = overlay.box, overlay.offset
	fresh = fresh or not box
	-- A place off units is kept as which side of them the callout's nearest corner is on, each way,
	-- and how far out that corner is: { sx, dx, sy, dy }, so that the callout grows away from them.
	-- A scene's ring grows and shrinks on screen as the camera follows its units, so for a scene
	-- that corner is kept as a share of how far the ring reaches across and up from its middle,
	-- { sx, fx, sy, fy, ring = true }, and the callout keeps its place round the ring. These turn
	-- either into the offset of the callout's lower left from a subject at (ax, ay), and back.
	local function toOffset(place, across, up)
		if place.ring then
			local cx, cy = place[2] * across, place[4] * up
			return place[1] > 0 and cx or cx - w, place[3] > 0 and cy or cy - h
		end
		return place[1] > 0 and place[2] or -place[2] - w, place[3] > 0 and place[4] or -place[4] - h
	end
	local function fromOffset(ox, oy, across, up)
		local sx, sy = ox + w / 2 < 0 and -1 or 1, oy + h / 2 < 0 and -1 or 1
		if ringed then
			return { sx, (sx > 0 and ox or ox + w) / across, sy, (sy > 0 and oy or oy + h) / up, ring = true }
		end
		return { sx, sx > 0 and ox or -ox - w, sy, sy > 0 and oy or -oy - h }
	end
	-- How far a ring reaches across and up from its middle at (ax, ay)
	local function extent(points, ax, ay)
		local across, up = 1, 1
		for _, point in ipairs(points) do
			across, up = max(across, math.abs(point[1] - ax)), max(up, math.abs(point[2] - ay))
		end
		return across, up
	end
	local nowAcross, nowUp = 0, 0
	if ringed then
		nowAcross, nowUp = extent(ringed, ax, ay)
	end
	-- Where the callout is drawn grows the same way
	if box and (box.w ~= w or box.h ~= h) then
		local left, below = box[1] + box.w / 2 < ax, box[2] + box.h / 2 < ay
		box[1], box[2] = box[1] - (left and w - box.w or 0), box[2] - (below and h - box.h or 0)
		box.w, box.h = w, h
	end
	-- Judge it all from where things will be on screen once the camera has settled on its shot,
	-- so that a pan or turn under way doesn't decide it. Meanwhile it keeps its place off the
	-- subject.
	local project = camera.settled and overlay.projector(camera.settled, vsx, vsy) or spWorldToScreenCoords
	local sax, say = project(world[1], world[2], world[3])
	-- That is a guess, and a scene's shot changes as its units move, so it is looked at again,
	-- as readily as for a new shot, once the camera gets there
	if fresh then
		overlay.arrivedFor = nil
	end
	local arriving = false
	if overlay.arrivedFor ~= overlay.focus and length(sax - ax, say - ay) < vsy * 0.03 then
		overlay.arrivedFor, arriving = overlay.focus, not fresh
	end
	if fresh or arriving or gameFrame - overlay.placedFrame >= framesPerSecond then
		overlay.placedFor, overlay.placedFrame = overlay.focus, gameFrame
		if not overlay.uiFrame or gameFrame - overlay.uiFrame >= 3 * framesPerSecond then
			overlay.ui, overlay.uiFrame = overlay.scanUI(vsx, vsy), gameFrame
		end

		-- Where it is off the subject; for a new shot, off the new subject from where it is on screen
		local current = fresh and box and fromOffset(box[1] - ax, box[2] - ay, nowAcross, nowUp) or offset
		local ax, ay = sax, say
		-- Things worth not covering: the units in shot, the move arrow and a scene's ring
		local points, across, up = {}, 0, 0
		if ringed then
			points = overlay.ring(world[1], world[3], overlay.radius, 16, project)
			across, up = extent(points, ax, ay)
		end
		local function avoid(x, z)
			points[#points + 1] = { project(x, spGetGroundHeight(x, z), z) }
		end
		for unitID in pairs(overlay.focus.units) do
			local info = unitInfo.cache[unitID]
			local location = getSeenLocation(unitID) or info and info.location
			if location then
				avoid(location[1], location[3])
			end
		end
		local from, to = overlay.arrowFrom, overlay.arrowTo
		for i = 0, from and 6 or -1 do
			avoid(from[1] + (to[1] - from[1]) * i / 6, from[2] + (to[2] - from[2]) * i / 6)
		end
		-- Everything else on screen counts for less, by how much of it is covered. What moves counts
		-- for less than buildings, as it moves on; and something big on screen, like a factory, for
		-- more again. What will be on screen, that is: mid-pan, what is there now is mostly not.
		local others, unit = {}, vsy * 0.02
		local pose, around = camera.settled, nil
		if pose then
			around = spGetUnitsInCylinder(pose.look[1], pose.look[3], pose.dist * 2)
		end
		for _, unitID in ipairs(around or spGetVisibleUnits() or {}) do
			local x, y, z = spGetUnitPosition(unitID)
			local unitDefID = spGetUnitDefID(unitID)
			if x and unitDefID then
				local _, isStatic, weaponImportance = unitInfo:_unitStats(unitDefID)
				local px, py = project(x, y, z)
				local unitDef = UnitDefs[unitDefID]
				-- A building's footprint can be wider than its radius
				local rx, ry = project(x + max(unitDef.radius or 20, (unitDef.xsize or 0) * 4), y, z)
				local r = max(4, length(rx - px, ry - py))
				if px > -r and px < vsx + r and py > -r and py < vsy + r then
					local weight = (not isStatic or (weaponImportance or 0) > 0) and 0.5 or 0.6
					others[#others + 1] = { px, py, r, weight * bound((r / unit) ^ 2, 1, 4) }
				end
			end
		end
		-- Which way the rest of the action lies from the subject
		local tx, ty = 0, 0
		for _, point in ipairs(points) do
			tx, ty = tx + point[1] - ax, ty + point[2] - ay
		end
		local toward = max(1, length(tx, ty))

		-- What putting the callout's corner at (ox, oy) from the subject costs, once kept on screen.
		-- Worst is landing on the subject or in its ring, then on the game's own windows, then
		-- covering things, a pointer that reads badly, a long pointer and being on the side the action
		-- is. Also returns whether it is one of the first two.
		local function cost(ox, oy)
			local bx, by = bound(ax + ox, 10, xMax), bound(ay + oy, 10, yMax)
			local nx, ny = bound(ax, bx, bx + w) - ax, bound(ay, by, by + h) - ay
			-- Being in the way is judged with some room to spare, so that a spot chosen isn't then in the
			-- way a second later: in the room costs a little, and it only counts as in the way once it
			-- is well inside the ring or over the window itself.
			local onSubject, near = nx == 0 and ny == 0, false
			if across > 0 then
				local function inRing(room)
					return (nx / (across + room)) ^ 2 + (ny / (up + room)) ^ 2 < 1
				end
				-- A ring grows, shrinks and moves as the camera follows its scene, so the room grows with
				-- it. A callout just inside the line is in the way: it reads as part of the scene.
				onSubject, near = inRing(-0.25 * reach), inRing(reach + 0.15 * max(across, up))
			end
			-- The pointer leaves the corner nearest the subject (see overlay.draw). It reads best going
			-- out from there on a diagonal; along an edge, or back across the callout, it looks wrong.
			local ux, uy = overlay.pointerOut(bx, by, w, h, ax, ay)
			-- Short pointers are cheap; past about a fifth of the screen, much less so. A ring's
			-- pointer aims at its middle and stops at the ring, so only the part outside counts.
			local seen = length(nx, ny)
			if across > 0 then
				local d = length(ux, uy)
				local e = length(ux / across, uy / max(1, up))
				seen = e > 1 and d * (1 - 1 / e) or 0
			end
			local long = seen / vsy
			local total, blocked = (onSubject and 50 or near and 3 or 0) + 3 * long + 10 * max(0, long - 0.2), onSubject
			if ux <= 0 or uy <= 0 then
				total = total + 2
			else
				total = total + 1.5 * max(0, math.abs(atan2(uy, ux) - pi / 4) - pi / 12) / (pi / 6)
			end
			-- A scene's middle wanders on screen as the camera follows its units, so keep well clear
			local room = reach * 1.5
			for _, window in ipairs(overlay.ui) do
				if bx < window[3] and bx + w > window[1] and by < window[4] and by + h > window[2] then
					total, blocked = total + 20, true
				elseif bx < window[3] + room and bx + w > window[1] - room and by < window[4] + room and by + h > window[2] - room then
					total = total + 3
				end
			end
			local covered = 0
			for _, other in ipairs(others) do
				local x, y, r = other[1], other[2], other[3]
				local cw = min(x + r, bx + w + margin) - max(x - r, bx - margin)
				local ch = min(y + r, by + h + margin) - max(y - r, by - margin)
				if cw > 0 and ch > 0 then
					covered = covered + other[4] * min(1, cw * ch / (4 * r * r))
				end
			end
			-- A crowd is still better covered than a window
			total = total + min(covered, 10)
			for _, point in ipairs(points) do
				if point[1] > bx - margin and point[1] < bx + w + margin and point[2] > by - margin and point[2] < by + h + margin then
					total = total + 1
				end
			end
			local cx, cy = bx + w / 2 - ax, by + h / 2 - ay
			return total + 0.8 * (cx * tx + cy * ty) / toward / max(1, length(cx, cy)), blocked
		end

		local best, bestCost, curX, curY = nil, nil, nil, nil
		if current then
			curX, curY = toOffset(current, across, up)
		end
		local function try(ox, oy)
			-- Other things being nearly equal, the side it is already on
			local sameSide = curX and (ox + w / 2 < 0) == (curX + w / 2 < 0) and (oy + h / 2 < 0) == (curY + h / 2 < 0)
			local total = cost(ox, oy) - (sameSide and 0.5 or 0)
			if not best or total < bestCost then
				best, bestCost = fromOffset(ox, oy, across, up), total
			end
		end
		-- Out on each diagonal: close by first, then further for when the fight is all around the
		-- subject, and flatter or steeper to fit the space
		for _, far in ipairs({ 1, 2, 3, 4.5 }) do
			local out = (across > 0 and reach * 1.6 or reach) * far
			for sx = 1, -1, -2 do
				for sy = 1, -1, -2 do
					for _, k in ipairs({ 1, 1.6, 1 / 1.6 }) do
						-- 3/4 of the way out each way clears a ring
						local dx, dy = out * k + across * 0.75, out / k + up * 0.75
						try(sx > 0 and dx or -dx - w, sy > 0 and dy or -dy - h)
					end
					if across > 0 and far == 1 then
						-- Round the ring, with the corner nearest its middle just outside it
						for i = 0, 15 do
							local c, s = cos(i * pi / 8), sin(i * pi / 8)
							if (c >= 0) == (sx > 0) and (s >= 0) == (sy > 0) then
								for _, f in ipairs({ 1.5, 3 }) do
									local px, py = (across + reach * f) * c, (up + reach * f) * s
									try(sx > 0 and px or px - w, sy > 0 and py or py - h)
								end
							end
						end
						-- When a ring leaves no room around it: in from a corner of the screen, as far
						-- as stays clear
						local cx, cy, t = (sx > 0 and xMax or 10) - ax, (sy > 0 and yMax or 10) - ay, 0
						while t < 0.9 and not select(2, cost(cx - (cx + w / 2) * (t + 0.1), cy - (cy + h / 2) * (t + 0.1))) do
							t = t + 0.1
						end
						try(cx - (cx + w / 2) * t, cy - (cy + h / 2) * t)
					end
				end
			end
		end
		-- Stay unless in the way or somewhere else is clearly better. A move glides there.
		local currentCost, blocked = huge, true
		if current then
			currentCost, blocked = cost(curX, curY)
		end
		if blocked or currentCost >= bestCost + ((fresh or arriving) and 2 or 4) then
			overlay.offset, overlay.settling = best, true
			if DEBUG then
				local pose = camera.settled or {}
				local bx, by = toOffset(best, across, up)
				spEcho(string.format('rc-place,%s,%.0f,%.0f,%.1f,%.1f,%s,%.0f,%.0f,%.0f,%.0f,%.0f,%.2f', fresh and 'fresh' or arriving and 'arrived' or 'better',
					bx, by, min(currentCost, 999), bestCost, blocked and 'blocked' or '', ax, ay,
					across, up, pose.dist or 0, pose.yaw or 0))
			end
		elseif fresh then
			overlay.offset = current
		end
	end

	-- The callout floats: it stays where it is on screen while within some slack of its place off
	-- the subject, so the pointer swings and stretches as units and the camera move, and is drawn
	-- back in beyond that. After a move it settles all the way, and it is never left on the subject,
	-- on its ring or with its pointer going back across it. Its place is off where the subject will
	-- be once the camera gets there, so that a pan doesn't drag it along behind and past.
	local settledAcross, settledUp = nowAcross, nowUp
	if ringed then
		settledAcross, settledUp = extent(overlay.ring(world[1], world[3], overlay.radius, 16, project), sax, say)
	end
	local ox, oy = toOffset(overlay.offset, settledAcross, settledUp)
	local tx, ty = bound(sax + ox, 10, xMax), bound(say + oy, 10, yMax)
	if not box then
		box = { tx, ty, 0, w = w, h = h, v = { 0, 0, 0 } }
		overlay.settling = false
	else
		local slack = overlay.settling and 0 or vsy * 0.1
		local ux, uy = overlay.pointerOut(box[1], box[2], w, h, ax, ay)
		if ux < margin or uy < margin then
			slack = 0
		end
		if ringed then
			local nx, ny = bound(ax, box[1], box[1] + w) - ax, bound(ay, box[2], box[2] + h) - ay
			if (nx / nowAcross) ^ 2 + (ny / nowUp) ^ 2 < 1 then
				slack = 0
			end
		end
		local dx, dy = tx - box[1], ty - box[2]
		local d = length(dx, dy)
		local f = d > slack and 1 - slack / d or 0
		smoothDampVec(box, { box[1] + dx * f, box[2] + dy * f, 0 }, box.v, 0.3, overlay.dt or 1 / 30, vsy * 3)
		overlay.settling = overlay.settling and d > 2
	end
	box[1], box[2] = bound(box[1], 10, xMax), bound(box[2], 10, yMax)
	overlay.box = box
	return box[1], box[2]
end

-- On a wide shot, a board at the top of the screen with what each side's units are worth in metal.
-- Two sides face each other across it with a bar split the same way, like the tally; more are
-- listed a row each.
-- A bar under a row of text from x1 to x2, split between two sides' amounts in their colours
function overlay.splitBar(x1, x2, ty, pad, a, b, ca, cb)
	local split = x1 + (x2 - x1) * (a + b > 0 and a / (a + b) or 0.5)
	gl.Color(ca[1], ca[2], ca[3], 0.9)
	gl.Rect(x1, ty - pad, split, ty - pad * 0.4)
	gl.Color(cb[1], cb[2], cb[3], 0.9)
	gl.Rect(split, ty - pad, x2, ty - pad * 0.4)
end

function overlay.drawWorth(vsx, vsy, size)
	local worth, sides = overlay.worth or {}, {}
	for allyTeam in pairs(worth) do
		sides[#sides + 1] = allyTeam
	end
	if #sides == 0 then
		return
	end
	overlay.sortSides(sides)
	local pad, row, small = size * 0.6, size * 1.5, size * 0.85
	local title, paired = "Metal value", #sides == 2
	local w, nameW, valueW = gl.GetTextWidth(title) * size, 0, 0
	for _, allyTeam in ipairs(sides) do
		nameW = max(nameW, gl.GetTextWidth(scenes.names[allyTeam]) * small)
		valueW = max(valueW, gl.GetTextWidth(overlay.metal(worth[allyTeam])) * small)
	end
	if paired then
		-- Each side's name and value, either side of the middle
		w = max(w, (nameW + valueW + size) * 2)
	else
		w = max(w, nameW + valueW + size * 2)
	end
	w = w + pad * 2
	local h = row * (1 + (paired and 1 or #sides)) + pad + (paired and pad or 0)

	-- Top centre, below any of the game's windows in the way
	if not overlay.uiFrame or gameFrame - overlay.uiFrame >= 3 * framesPerSecond then
		overlay.ui, overlay.uiFrame = overlay.scanUI(vsx, vsy), gameFrame
	end
	local bx, by = (vsx - w) / 2, vsy - h - 10
	local moved = true
	while moved and by > 10 do
		moved = false
		for _, window in ipairs(overlay.ui) do
			if bx < window[3] and bx + w > window[1] and by < window[4] and by + h > window[2] then
				by, moved = window[2] - h - 10, true
			end
		end
	end

	gl.Color(0, 0, 0, 0.55)
	gl.Rect(bx, by, bx + w, by + h)
	gl.Color(1, 1, 1, 1)
	local ty = by + h - pad * 0.5 - size
	gl.Text(title, bx + w / 2, ty, size, "oc")
	if paired then
		local a, b = sides[1], sides[2]
		ty = ty - row
		gl.Text(overlay.coloured(scenes.names[a] .. " " .. overlay.metal(worth[a]), overlay.allyColor[a]), bx + pad, ty, small, "o")
		gl.Text(overlay.coloured(overlay.metal(worth[b]) .. " " .. scenes.names[b], overlay.allyColor[b]), bx + w - pad, ty, small, "or")
		overlay.splitBar(bx + pad, bx + w - pad, ty, pad, worth[a], worth[b], overlay.allyColor[a], overlay.allyColor[b])
	else
		for _, allyTeam in ipairs(sides) do
			ty = ty - row
			local color = overlay.allyColor[allyTeam]
			gl.Text(overlay.coloured(scenes.names[allyTeam], color), bx + pad, ty, small, "o")
			gl.Text(overlay.coloured(overlay.metal(worth[allyTeam]), color), bx + w - pad, ty, small, "or")
		end
	end
	gl.Color(1, 1, 1, 1)
end

function overlay.draw()
	-- With no callout, the next one starts where it best fits
	local headline = overlay.headline
	if not overlay.focus or not options.show_commentary.value or display.isWide or not headline then
		overlay.box = nil
	end
	if not overlay.focus or not options.show_commentary.value then
		return
	end
	local vsx, vsy = spGetViewGeometry()
	local size = overlay.textSize * vsy / 1080
	if display.isWide then
		overlay.drawWorth(vsx, vsy, size)
		return
	end
	if not headline then
		return
	end
	local pad, row, color = size * 0.6, size * 1.5, overlay.color
	local detail, small = overlay.detail, size * 0.85
	-- The subject on screen: the units or spot the headline names, or the focus and its ring
	local ring
	local sx, sy, sz, speed = overlay.centre()
	if overlay.ringed or not sx then
		sx, sz = overlay.ringX or display.location[1], overlay.ringZ or display.location[3]
		sy = spGetGroundHeight(sx, sz)
		ring = overlay.ringed and overlay.ring(sx, sz, overlay.radius, 24)
	end
	local ax, ay = spWorldToScreenCoords(sx, sy, sz)
	-- Not while the camera is still bringing the subject on screen: a pointer off the edge says
	-- nothing yet
	if (ax < 0 or ax > vsx or ay < 0 or ay > vsy) and camera.settled then
		local sax, say = overlay.projector(camera.settled, vsx, vsy)(sx, sy, sz)
		if length(sax - ax, say - ay) > vsy * 0.1 then
			overlay.box = nil
			return
		end
	end
	if overlay.left and overlay.left > 50 and speed and speed < huge then
		-- At the speed they have been closing, or flat out until that is known
		speed = overlay.closing and overlay.closing > speed * 0.2 and overlay.closing or speed
		detail = string.format("arrives in %ds", math.ceil(length(overlay.arrowTo[1] - sx, overlay.arrowTo[2] - sz) / max(1, speed)))
	end

	-- The tally: what each side has killed, and a bar split the same way
	local tally, a, b, tallyRows = overlay.tally, nil, nil, 0
	if next(tally) then
		local sides = {}
		for allyTeam in pairs(overlay.allyColor) do
			sides[#sides + 1] = allyTeam
		end
		overlay.sortSides(sides)
		a, b, tallyRows = sides[1], sides[2], #sides == 2 and 1 or 0
		if tallyRows == 0 then
			-- More than two sides: list them
			local parts = {}
			for _, allyTeam in ipairs(sides) do
				if tally[allyTeam] then
					parts[#parts + 1] = overlay.side(allyTeam, overlay.focus) .. " " .. overlay.metal(tally[allyTeam])
				end
			end
			detail = (detail and detail .. "  |  " or "") .. "killed: " .. table.concat(parts, "  ")
		end
	end
	local left, right, ca, cb
	if tallyRows == 1 then
		local an, bn
		an, ca = overlay.side(a, overlay.focus)
		bn, cb = overlay.side(b, overlay.focus)
		left = an .. " " .. overlay.coloured(overlay.metal(tally[a] or 0), ca)
		right = overlay.coloured(overlay.metal(tally[b] or 0), cb) .. " " .. bn
	end

	local w = gl.GetTextWidth(headline) * size
	if detail then
		w = max(w, gl.GetTextWidth(detail) * small)
	end
	if left then
		-- "killed" sits in the middle, between each side's count
		w = max(w, (max(gl.GetTextWidth(left), gl.GetTextWidth(right)) * 2 + gl.GetTextWidth("killed")) * small + size * 2)
	end
	w = w + pad * 2
	local h = row * (1 + (detail and 1 or 0) + tallyRows) + pad + tallyRows * pad

	local bx, by = overlay.place({ sx, sy, sz }, ax, ay, w, h, vsx, vsy, ring)

	gl.Color(0, 0, 0, 0.55)
	gl.Rect(bx, by, bx + w, by + h)
	-- The edge facing the subject is coloured, and the pointer runs out of the middle of its end to
	-- stop short of the units, or on the nearest part of the ring
	local t = max(2, size * 0.2)
	local onLeft, below = bx + w / 2 < ax, by + h / 2 < ay
	local ex, cy = onLeft and bx + w - t or bx, below and by + h or by
	local cx, my = ex + t / 2, below and cy - t / 2 or cy + t / 2
	-- Gaps short of the units grow with the lens's zoom, as the units do on screen
	local zoom = camera and camera.zoom or 1
	local px, py, gap = ax, ay, size * 1.8 * zoom
	-- Towards the middle of the ring, or of the one unit named, stopping where it first crosses the
	-- ring or the unit's selection shape (a little outside that). If it doesn't cross, the callout is
	-- on it already: no pointer, rather than one into the middle.
	local only = next(overlay.subjects)
	local outline = ring
	if not ring and only and not next(overlay.subjects, only) and spGetUnitDefID(only) then
		outline = overlay.outline(only, sx, sy, sz)
	end
	if outline then
		local first = overlay.crossing(outline, cx, my, ax, ay)
		px, py, gap = cx + (ax - cx) * first, my + (ay - my) * first, ring and 0 or size * 0.6 * zoom
	end
	local reach = length(px - cx, py - my)
	-- A little see-through, like the ring
	gl.Color(color[1], color[2], color[3], overlay.lineAlpha)
	gl.Rect(ex, by, ex + t, by + h)
	if reach > max(1, gap * 1.5) then
		-- Half the thickness, across the pointer
		local nx, ny = -(py - my) / reach * t / 2, (px - cx) / reach * t / 2
		px, py = px + (cx - px) * gap / reach, py + (my - py) * gap / reach
		gl.BeginEnd(GL.QUADS, function()
			gl.Vertex(cx + nx, my + ny)
			gl.Vertex(cx - nx, my - ny)
			gl.Vertex(px - nx, py - ny)
			gl.Vertex(px + nx, py + ny)
		end)
	end
	gl.Color(1, 1, 1, 1)

	local ty = by + h - pad * 0.5 - size
	gl.Text(headline, bx + pad, ty, size, "o")
	if detail then
		ty = ty - row
		gl.Text(detail, bx + pad, ty, small, "o")
	end
	if left then
		ty = ty - row
		gl.Text(left, bx + pad, ty, small, "o")
		gl.Text(right, bx + w - pad, ty, small, "or")
		gl.Color(0.75, 0.75, 0.75, 1)
		gl.Text("killed", bx + w / 2, ty, small, "oc")
		-- Each side's share of the bar is what it has killed
		overlay.splitBar(bx + pad, bx + w - pad, ty, pad, tally[a] or 0, tally[b] or 0, ca, cb)
	end
	gl.LineWidth(1)
	gl.Color(1, 1, 1, 1)
end

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
local function statsAddDamage(unitID, unitDefID, damage)
	local value, maxHealth = statsUnitValue(unitID, unitDefID)
	local x, _, z = spGetUnitPosition(unitID)
	if not value or not maxHealth or maxHealth <= 0 or not x then
		return
	end
	-- Metal-equivalent of the damage dealt
	value = value * min(damage, maxHealth) / maxHealth
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
		shown and shown.id or -1, shown and shown.shownType or 'nil',
		userOverride and 1 or 0, table.concat(corners, ','),
		camera and camera.ry or 0, deg(statsMaxYawRate)))
	statsMaxYawRate = 0
	-- The shot took in a nearby scene in the last second
	local aside = display.aside
	if display.asideFrame and gameFrame - display.asideFrame < updateIntervalFrames then
		spEcho(string.format('rc-aside,%.0f,%.0f', aside[1], aside[2]))
	end
	-- Where the ring is, for stats to check against the view: a ring off the shot means the overlay
	-- thinks the action is somewhere the camera isn't showing
	if overlay.ringed and overlay.ringX then
		spEcho(string.format('rc-ring,%.0f,%.0f,%.0f', overlay.ringX, overlay.ringZ, overlay.radius))
	end
	-- The lens zoomed in for a close shot (see closeUp)
	if camera and camera.zoom > 1.05 then
		spEcho(string.format('rc-zoom,%.2f', camera.zoom))
	end
end

local function statsTrackYaw(dt, oldRy, newRy, isCut)
	if isCut or dt <= 0 then
		return
	end
	statsMaxYawRate = max(statsMaxYawRate, math.abs(wrapAngle(newRy - oldRy)) / dt)
end

-- Marks the shot framed once its tracking box first sits in frame (and logs rc-framed).
local function checkFramed(xMin, zMin, xMax, zMax)
	if not shown or display.framedId == shown.id then
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
	for _, c in ipairs({ { xMin, zMin }, { xMin, zMax }, { xMax, zMin }, { xMax, zMax } }) do
		local px, py, pz = spWorldToScreenCoords(c[1], gy, c[2])
		if not px or pz < 0 or pz > 1 or px < 0 or px > vsx or py < 0 or py > vsy then
			return
		end
	end
	display.framedId, display.framedFrame = shown.id, gameFrame
	if shown.wide then
		-- Restart a wide shot's fade, so that travel doesn't eat into its screen time
		shown.frame = gameFrame
	end
	if STATS then
		spEcho(string.format('rc-framed,%d,%s', shown.id, shown.shownType))
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
	if onScreen(location) then
		pan = pan / 2
	end
	-- Even a tiny pan takes about the look-at smooth time, so measure from there
	return bound((pan - lookSmoothTime) / (maxPanSeconds - lookSmoothTime), 0, 1)
end

-- Look-at point and distance that fit ground points { x, z } (at height y) in view at this yaw and
-- pitch, with their projection spanning at most fill of the screen and centred on it. Perspective
-- makes the far side look smaller, so aiming at their middle would leave more space above than below.
local function frameBox(corners, y, yaw, pitch, fill)
	local fx, fy, fz, rx, rz, ux, uy, uz = cameraAxes(pitch, yaw)
	local sp, cy, sy = fy, -rx, rz
	local vsx, vsy = spGetViewGeometry()
	local tanV = tan(rad(defaultFov / 2))
	local tanH = tanV * vsx / vsy

	-- Projected extents of the box from distance d back from look-at point (lx, lz)
	local function extents(lx, lz, d)
		local px, py, pz = lx - d * fx, y - d * fy, lz - d * fz
		local uMin, uMax, vMin, vMax = huge, -huge, huge, -huge
		for _, corner in ipairs(corners) do
			local dx, dy, dz = corner[1] - px, y - py, corner[2] - pz
			local depth = dx * fx + dy * fy + dz * fz
			if depth <= 1 then
				return nil
			end
			local u = (dx * rx + dz * rz) / (depth * tanH)
			local v = (dx * ux + dy * uy + dz * uz) / (depth * tanV)
			uMin, uMax, vMin, vMax = min(uMin, u), max(uMax, u), min(vMin, v), max(vMax, v)
		end
		return uMin, uMax, vMin, vMax
	end

	local lx, lz, d = 0, 0, 0
	for _, corner in ipairs(corners) do
		lx, lz = lx + corner[1] / #corners, lz + corner[2] / #corners
	end
	for _ = 1, 3 do
		-- Closest distance that fits (the projection shrinks with distance)
		local lo, hi = 1, length(mapSizeX, mapSizeZ) * 4
		for _ = 1, 24 do
			d = (lo + hi) / 2
			local uMin, uMax, vMin, vMax = extents(lx, lz, d)
			if uMin and uMax - uMin <= 2 * fill and vMax - vMin <= 2 * fill then
				hi = d
			else
				lo = d
			end
		end
		d = hi
		-- Shift the look-at point to centre the projection: sideways along the camera's right, and
		-- along the ground in the direction it faces
		local uMin, uMax, vMin, vMax = extents(lx, lz, d)
		local du, dv = (uMin + uMax) / 2, (vMin + vMax) / 2
		local side, ahead = du * d * tanH, dv * d * tanV / max(0.1, -sp)
		lx, lz = lx + side * rx + ahead * sy, lz + side * rz + ahead * cy
	end
	return lx, lz, d
end

-- How far to move the look-at point (x, z) from look so that less of the view is off the map,
-- keeping the ground points corners on screen (unzoomed; a zoom of z moves it by this over z,
-- which keeps look where it was on screen). From the view's corners within edgeFill of the screen:
-- how far each is off the map, along the screen's sides and towards its top, as it looks on
-- screen. Far ground looks smaller, so a corner far off the map near the horizon is only a sliver
-- of the screen, and moving the shot to show it all would push its middle up to the top. At most
-- edgeOffset of the way from the middle of the screen to its edge, and as far as corners still fit.
local function edgeShift(look, dist, pitch, yaw, corners)
	local fx, fy, fz, rx, rz, ux, uy, uz = cameraAxes(pitch, yaw)
	local ax, az = sin(yaw), cos(yaw)
	local vsx, vsy = spGetViewGeometry()
	local tanV = tan(rad(defaultFov / 2)) * edgeFill
	local tanH = tanV * vsx / vsy
	local lx, ly, lz = look[1], look[2], look[3]
	local px, py, pz = lx - dist * fx, ly - dist * fy, lz - dist * fz
	-- How far the ground moves on screen at a corner, against at the look-at point: across, it
	-- shrinks with depth; ahead, also as the ground there is seen more side on
	local down = max(0.1, -fy)
	-- The view on the ground about look, across (a) and ahead (b), and moves to bring its corners
	-- onto the map, either way
	local aMin, aMax, bMin, bMax = -huge, huge, -huge, huge
	local aLow, aHigh, bLow, bHigh = 0, 0, 0, 0
	for _, su in ipairs({ -1, 1 }) do
		for _, sv in ipairs({ -1, 1 }) do
			local dx = fx + rx * su * tanH + ux * sv * tanV
			local dy = fy + uy * sv * tanV
			local dz = fz + rz * su * tanH + uz * sv * tanV
			-- Towards the horizon, as far as a few times the distance. (The ray is 1 forward, so t
			-- is also the corner's depth.)
			local t = dy < -1e-3 and min((ly - py) / dy, 4 * dist) or 4 * dist
			local x, z = px + dx * t, pz + dz * t
			local a, b = (x - lx) * rx + (z - lz) * rz, (x - lx) * ax + (z - lz) * az
			if su < 0 then aMin = max(aMin, a) else aMax = min(aMax, a) end
			if sv < 0 then bMin = max(bMin, b) else bMax = min(bMax, b) end
			local ox = max(0, -x) - max(0, x - mapSizeX)
			local oz = max(0, -z) - max(0, z - mapSizeZ)
			local oa = (ox * rx + oz * rz) * dist / t
			local ob = (ox * ax + oz * az) * dist / t * max(0, 1 + sv * tanV * cos(pitch) / fy)
			aLow, aHigh, bLow, bHigh = min(aLow, oa), max(aHigh, oa), min(bLow, ob), max(bHigh, ob)
		end
	end
	-- Off both sides: split the difference
	local function either(low, high)
		return (low < 0 and high > 0) and (low + high) / 2 or low + high
	end
	local sa, sb = either(aLow, aHigh), either(bLow, bHigh)
	local wa, wb = edgeOffset * dist * tanH / edgeFill, edgeOffset * dist * tanV / edgeFill / down
	sa, sb = bound(sa, -wa, wa), bound(sb, -wb, wb)
	-- As far as the corners still fit
	local cMin, cMax, dMin, dMax = huge, -huge, huge, -huge
	for _, corner in ipairs(corners) do
		local x, z = corner[1] - lx, corner[2] - lz
		local a, b = x * rx + z * rz, x * ax + z * az
		cMin, cMax, dMin, dMax = min(cMin, a), max(cMax, a), min(dMin, b), max(dMax, b)
	end
	sa = cMax - aMax <= cMin - aMin and bound(sa, cMax - aMax, cMin - aMin) or 0
	sb = dMax - bMax <= dMin - bMin and bound(sb, dMax - bMax, dMin - bMin) or 0
	return sa * rx + sb * ax, sa * rz + sb * az
end

-- Score the view the rig would have at this yaw (see orbitConfig.headingWeights). Returns the
-- total, and the score of the view alone without heading preferences.
local function scoreHeading(c, yaw)
	local lx, ly, lz = unpack(c.look)
	local fx, fy, fz, rx, rz, ux, uy, uz = cameraAxes(c.pitch, yaw)
	local px, py, pz = lx - c.dist * fx, ly - c.dist * fy, lz - c.dist * fz
	local vsx, vsy = spGetViewGeometry()
	-- As seen without the zoom: a heading is judged by what is around the shot
	local tanV = tan(rad(defaultFov / 2))
	local tanH = tanV * vsx / vsy

	-- Cast a grid of rays onto the plane of the look-at point
	local activity, offMap, n = 0, 0, 0
	for _, su in ipairs(orbitConfig.headingSamples) do
		for _, sv in ipairs(orbitConfig.headingSamples) do
			local dx = fx + rx * su * tanH + ux * sv * tanV
			local dy = fy + uy * sv * tanV
			local dz = fz + rz * su * tanH + uz * sv * tanV
			n = n + 1
			if dy >= -1e-3 then
				offMap = offMap + 1
			else
				local t = (ly - py) / dy
				local x, z = px + dx * t, pz + dz * t
				if x < 0 or x > mapSizeX or z < 0 or z > mapSizeZ then
					offMap = offMap + 1
				else
					activity = activity + log10(scenes.activityAt(x, z))
				end
			end
		end
	end

	local occluded = 0
	for i = 1, 4 do
		local t = i / 5
		if spGetGroundHeight(px + (lx - px) * t, pz + (lz - pz) * t) > py + (ly - py) * t then
			occluded = occluded + 1
		end
	end

	local w = orbitConfig.headingWeights
	local view = w.activity * activity / n - w.offMap * offMap / n - w.occluded * occluded
	return view - w.turn * math.abs(wrapAngle(yaw - c.yaw)) / pi
		- w.north * math.abs(wrapAngle(yaw - defaultRy)) / (pi / 2), view
end

-- Once the shot is framed, maybe orbit to a better heading, or drift once on a long hold
local function planHeading(c)
	if not shown or display.framedId ~= shown.id
	    or gameFrame < display.framedFrame + orbitConfig.startFrames
	    or gameFrame < (c.planFrame or 0) + orbitConfig.planFrames
	    -- Let an orbit finish before replanning
	    or math.abs(wrapAngle(c.tyaw - c.yaw)) > 0.1 then
		return
	end
	c.planFrame = gameFrame

	local current, currentView = scoreHeading(c, c.tyaw)
	local best, bestScore, bestView, drift, driftScore, driftView = nil, -huge, nil, nil, -huge, nil
	for k = 0, floor(2 * pi / orbitConfig.candidateStep + 0.5) - 1 do
		local yaw = wrapAngle(defaultRy + k * orbitConfig.candidateStep)
		local score, view = scoreHeading(c, yaw)
		if score > bestScore then
			best, bestScore, bestView = yaw, score, view
		end
		if math.abs(wrapAngle(yaw - c.tyaw)) >= orbitConfig.driftMin and score > driftScore then
			drift, driftScore, driftView = yaw, score, view
		end
	end

	local target, reason, view
	if bestScore > current and bestView > currentView + orbitConfig.margin then
		target, reason, view = best, 'better', bestView
	elseif not c.orbited and gameFrame >= display.framedFrame + orbitConfig.driftFrames
	    and drift and driftScore >= current - orbitConfig.driftTolerance then
		target, reason, view = drift, 'drift', driftView
	end
	if target then
		c.tyaw = c.yaw + wrapAngle(target - c.yaw)
		c.yawSmooth, c.orbited = orbitConfig.smoothTime, true
		if STATS then
			-- Gain is the view score improvement (see orbitConfig.headingWeights), before heading preferences
			spEcho(string.format('rc-orbit,%d,%.0f,%.0f,%s,%.2f', shown.id, deg(c.yaw), deg(target), reason, view - currentView))
		end
	end
end

local function initCamera(cx, cy, cz)
	local lx, lz = mapSizeX / 2, mapSizeZ / 2
	return {
		-- Rig state
		look = { lx, spGetGroundHeight(lx, lz), lz }, lookv = { 0, 0, 0 }, shift = { 0, 0 }, shiftv = { 0, 0 },
		dist = calcCamRange(camDiagMin, defaultFov), distv = 0,
		zoom = 1, zoomv = 0, tzoom = 1, zoomFrame = 0, closeEnd = -huge,
		pitch = defaultRx, pitchv = 0,
		yaw = defaultRy, yawv = 0, tyaw = defaultRy,
		-- Pose last sent to the engine
		x = cx, y = cy, z = cz, rx = defaultRx, ry = defaultRy, fov = defaultFov,
		cutNext = true,
	}
end

local function showFocus(f)
	local wide = f.wide or false
	display.camAngle, display.isWide, display.fill = wide and lullConfig.pitch or defaultRx, wide, wide and lullConfig.fill or frameFill
	if wide then
		-- Once on show, a wide shot fades sooner
		f.frame, f.decay = gameFrame, lullConfig.shownDecaySeconds
	end
	shown = f
	overlay.show(f)
	f.shownType = wide and 'lull' or overlay.kind or 'focus'
	display.shotFrame = gameFrame
	if STATS then
		spEcho(string.format('rc-shown,%d,%s,%.0f,%.0f,%s', f.id, f.shownType, f.x, f.z, display.camType))
	end
end

-- Whether the shot is still settling in or within its minimum hold (see minShotFrames)
local function shotLocked()
	if not shown then
		return false
	end
	if display.framedId == shown.id then
		return gameFrame < display.framedFrame + minShotFrames
	end
	return gameFrame < display.shotFrame + maxShotLockFrames
end

-- Whether f should replace the shot on show. Going to or from a wide shot shows the other anyway,
-- so costs little.
local function beats(f)
	if not shown then
		return true
	end
	local boost = switchBoostNear
	if not shown.wide and not f.wide then
		boost = switchBoostNear + (switchBoostFar - switchBoostNear) * transitionCost({ f.x, spGetGroundHeight(f.x, f.z), f.z })
	end
	-- Contacts are refreshed once a second per unit
	if shown.imminent and gameFrame - shown.imminent <= 1.5 * framesPerSecond then
		boost = boost * foci.imminentBoost
	end
	local score = shown.score
	if shotLocked() then
		-- A locked shot holds like a fair one, however weak it was
		score, boost = max(score, lockedShare * foci.typical), boost * shotLockBoost
	end
	return f.score > score * boost
end

function lull.addDamage(unitID, unitDefID, damage)
	local value, maxHealth = statsUnitValue(unitID, unitDefID)
	if value and maxHealth and maxHealth > 0 then
		lull.damage.now = lull.damage.now + value * min(damage, maxHealth) / maxHealth
	end
end

-- A wide shot framing the foci with most going on, or the whole map if nothing is (e.g. at the
-- start of the game). It scores score, fading over decaySeconds.
function lull.wide(score)
	local cfg = lullConfig
	local hottest, pad = 0, foci.joinRange / 2
	for _, f in ipairs(foci.list) do
		hottest = max(hottest, f.heat)
	end
	local xMin, zMin, xMax, zMax = huge, huge, -huge, -huge
	for _, f in ipairs(foci.list) do
		if hottest > 0 and f.heat >= cfg.focusShare * hottest then
			xMin, zMin = min(xMin, f.x - pad), min(zMin, f.z - pad)
			xMax, zMax = max(xMax, f.x + pad), max(zMax, f.z + pad)
		end
	end
	if xMin == huge then
		xMin, zMin, xMax, zMax = 0, 0, mapSizeX, mapSizeZ
	end
	local x, z = (xMin + xMax) / 2, (zMin + zMax) / 2
	local half = cfg.minDiag / 2 / sqrt(2)
	xMin, xMax = max(0, min(xMin, x - half)), min(mapSizeX, max(xMax, x + half))
	zMin, zMax = max(0, min(zMin, z - half)), min(mapSizeZ, max(zMax, z + half))
	x, z = (xMin + xMax) / 2, (zMin + zMax) / 2

	local y = spGetGroundHeight(x, z)
	foci.lastId = foci.lastId + 1
	return { id = foci.lastId, wide = true, x = x, z = z, peak = score, score = score, frame = gameFrame,
		decay = cfg.decaySeconds, corners = { { xMin, y, zMin }, { xMax, y, zMax } } }
end

-- Once a second: track damage, and offer a wide shot when a fight dies down
function lull.update()
	local d, cfg = lull.damage, lullConfig
	d.short = d.short + (d.now - d.short) / cfg.damageShortSeconds
	d.long = d.long + (d.now - d.long) / cfg.damageLongSeconds
	d.now = 0
	d.peak = max(d.short, d.peak * 0.5 ^ (1 / cfg.peakHalfLifeSeconds))
	local isFight = d.peak >= cfg.minPeak and d.peak >= cfg.minPeakRatio * d.long
	local fired = false
	if not lull.armed then
		lull.armed = isFight and d.short >= cfg.rearmRatio * d.peak
	elseif d.short <= cfg.dropRatio * d.peak then
		lull.armed = false
		if isFight then
			lull.candidate = lull.wide(d.peak * cfg.scoreScale)
			fired = true
		end
	end

	-- Wide shots fade: by half after decay seconds, to nothing at twice that
	local function fade(w)
		if w and w.wide then
			local t = (gameFrame - w.frame) / framesPerSecond
			w.score = w.peak * (1 - logistic(4 / w.decay * (t - w.decay)))
		end
	end
	fade(lull.candidate)
	if shown ~= lull.candidate then
		fade(shown)
	end
	if lull.candidate and lull.candidate ~= shown and lull.candidate.score < 1 then
		lull.candidate = nil
	end

	if STATS then
		spEcho(string.format('rc-lull,%d,%d,%.1f,%.1f,%.1f', lull.armed and 1 or 0, fired and 1 or 0, d.short, d.long, d.peak))
	end
end

-- Spread amount over the four cells nearest (x, z), by closeness to their centres, so that scores
-- don't jump as units cross cell edges. With best, keep the largest amount per cell instead of adding.
function scenes.spread(cells, x, z, amount, best)
	local fx, fz = x / worldGridSize - 0.5, z / worldGridSize - 0.5
	local gx, gz = floor(fx), floor(fz)
	for ix = 0, 1 do
		for iz = 0, 1 do
			local weight = (1 - math.abs(fx - gx - ix)) * (1 - math.abs(fz - gz - iz))
			local cell = 1 + bound(gx + ix, 0, mapGridX - 1) + bound(gz + iz, 0, mapGridZ - 1) * mapGridX
			if best then
				cells[cell] = max(cells[cell] or 0, amount * weight)
			else
				cells[cell] = (cells[cell] or 0) + amount * weight
			end
		end
	end
end

-- How much is going on at (x, z), for choosing headings (see scoreHeading): 1, plus units there
-- (see scenes.observe) and the heat of foci there
function scenes.activityAt(x, z)
	local cell = 1 + bound(floor(x / worldGridSize), 0, mapGridX - 1) + bound(floor(z / worldGridSize), 0, mapGridZ - 1) * mapGridX
	return 1 + (scenes.activity[cell] or 0) + (foci.cells[cell] or 0) / foci.cellHeatScale
end

-- Add a unit to this second's value and strength grids. Called as each unit's position is
-- refreshed, which spreads the work over the second.
function scenes.observe(info)
	local cfg, allyTeam = scenes, info.allyTeam
	if not cfg.value[allyTeam] then
		cfg.value[allyTeam], cfg.metal[allyTeam], cfg.power[allyTeam], cfg.powerNow[allyTeam], cfg.count[allyTeam] = {}, {}, {}, {}, {}
	end
	local x, _, z = unpack(info.location)
	-- Something moving counts for more than a building
	scenes.spread(cfg.count[allyTeam], x, z, distance(info.velocity) > 0.1 and 1 or 0.16)
	scenes.spread(cfg.value[allyTeam], x, z, info.importance)
	scenes.spread(cfg.metal[allyTeam], x, z, info.metal)
	local _, _, weaponImportance = unitInfo:_unitStats(info.unitDefID)
	if weaponImportance <= 0 or info.unfinished then
		return
	end
	scenes.spread(cfg.powerNow[allyTeam], x, z, info.metal)
	-- Strength along the unit's path: in each cell, the most it will bring to bear
	-- (velocity is per frame)
	local vx, _, vz = unpack(info.velocity)
	local power, path = cfg.power[allyTeam], {}
	for i, seconds in ipairs(cfg.horizon) do
		local frames = seconds * framesPerSecond
		scenes.spread(path, x + vx * frames, z + vz * frames, info.metal * cfg.discount[i], true)
		if vx == 0 and vz == 0 then
			break
		end
	end
	for cell, amount in pairs(path) do
		power[cell] = (power[cell] or 0) + amount
	end
end

-- Returns, by cell: value at stake, the same counting only where armed units are now, the ally team
-- with most at stake, the metal at stake (the same, at what the units cost), and the ally team
-- that most threatens the one with most at stake
function scenes.survey()
	local cfg, value, metal, power, powerNow = scenes, scenes.value, scenes.metal, scenes.power, scenes.powerNow
	cfg.value, cfg.metal, cfg.power, cfg.powerNow = {}, {}, {}, {}

	-- Units by cell, counting for more where sides meet
	local count, sides, activity = cfg.count, {}, {}
	cfg.count = {}
	for _, cells in pairs(count) do
		for cell, n in pairs(cells) do
			activity[cell] = (activity[cell] or 0) + n
			sides[cell] = (sides[cell] or 0) + (n >= 0.25 and 1 or 0)
		end
	end
	for cell, n in pairs(sides) do
		activity[cell] = activity[cell] * max(1, n * n)
	end
	cfg.activity = activity

	local stake, stakeNow, owner, ownerStake, metalStake, threatBy = {}, {}, {}, {}, {}, {}
	for allyTeam, cells in pairs(value) do
		for cell, v in pairs(cells) do
			local threat, threatNow, top, topPower = 0, 0, nil, 0
			for enemy, enemyPower in pairs(power) do
				if enemy ~= allyTeam then
					threat = threat + (enemyPower[cell] or 0)
					threatNow = threatNow + (powerNow[enemy][cell] or 0)
					if (enemyPower[cell] or 0) > topPower then
						top, topPower = enemy, enemyPower[cell]
					end
				end
			end
			local atStake = min(v, cfg.leverage * threat)
			if atStake > 0 then
				stake[cell] = (stake[cell] or 0) + atStake
				stakeNow[cell] = (stakeNow[cell] or 0) + min(v, cfg.leverage * threatNow)
				metalStake[cell] = (metalStake[cell] or 0) + min(metal[allyTeam][cell], cfg.leverage * threat)
				if atStake > (ownerStake[cell] or 0) then
					owner[cell], ownerStake[cell], threatBy[cell] = allyTeam, atStake, top
				end
			end
		end
	end
	cfg.metalStake = metalStake
	return stake, stakeNow, owner, metalStake, threatBy
end

-- The stake around a ring at (x, z): the cells under a square that takes in the ring and the cell
-- each unit's value is spread over, by how much of each it covers
function scenes.around(stake, x, z)
	local half, total = scenes.radius + worldGridSize / 2, 0
	local function spans(c, count)
		local shares = {}
		for i = max(1, floor((c - half) / worldGridSize) + 1), min(count, floor((c + half) / worldGridSize) + 1) do
			shares[i] = max(0, min(c + half, i * worldGridSize) - max(c - half, (i - 1) * worldGridSize)) / worldGridSize
		end
		return shares
	end
	for ix, sx in pairs(spans(x, mapGridX)) do
		for iz, sz in pairs(spans(z, mapGridZ)) do
			total = total + (stake[ix + (iz - 1) * mapGridX] or 0) * sx * sz
		end
	end
	return total
end

-- The mobile units near (x, z), or failing that the buildings, and the armed units of sides other
-- than side further out: the trouble coming, also returned on their own. Nil if none.
function scenes.subjects(x, z, side)
	local mobiles, statics, threats = {}, {}, {}
	for _, unitID in ipairs(spGetUnitsInCylinder(x, z, scenes.threatRadius)) do
		local location, _, _, _, isStatic, weaponImportance = unitInfo:get(unitID)
		local info = unitInfo.cache[unitID]
		if location and length(location[1] - x, location[3] - z) <= scenes.radius then
			(isStatic and statics or mobiles)[unitID] = location
		elseif location and not isStatic and (weaponImportance or 0) > 0 and info.allyTeam ~= side then
			threats[unitID] = location
		end
	end
	local subjects = next(mobiles) and mobiles or next(statics) and statics
	if subjects then
		for unitID, location in pairs(threats) do
			subjects[unitID] = location
		end
	end
	return subjects, threats
end

-- Once a second: add to foci where the stake has risen most
function scenes.update()
	local cfg = scenes
	local stake, stakeNow, owner, metalStake, threatBy = scenes.survey()
	for cell in pairs(cfg.baseline) do
		stake[cell] = stake[cell] or 0
	end
	local rise = {}
	local wx, _, wz = unpack(display.location)
	for cell, s in pairs(stake) do
		local base = cfg.baseline[cell] or 0
		rise[cell] = s > base and s - base or nil
		-- What the camera is on stops being news much sooner
		local x, z = ((cell - 1) % mapGridX + 0.5) * worldGridSize, (floor((cell - 1) / mapGridX) + 0.5) * worldGridSize
		local watched = not display.isWide and max(math.abs(x - wx), math.abs(z - wz)) <= cfg.watchedRange
		base = base + (s - base) / (watched and cfg.watchedSeconds or cfg.baselineSeconds)
		cfg.baseline[cell] = base >= 1 and base or nil
	end

	-- A scene is a cell and its neighbours, centred on where the rise is
	local risen = {}
	for cell in pairs(rise) do
		local gx, gz = (cell - 1) % mapGridX + 1, floor((cell - 1) / mapGridX) + 1
		local total, xSum, zSum = 0, 0, 0
		for ix = max(1, gx - 1), min(mapGridX, gx + 1) do
			for iz = max(1, gz - 1), min(mapGridZ, gz + 1) do
				local r = rise[ix + (iz - 1) * mapGridX] or 0
				total, xSum, zSum = total + r, xSum + r * (ix - 0.5), zSum + r * (iz - 0.5)
			end
		end
		if total >= cfg.minStake then
			risen[#risen + 1] = { cell = cell, gx = gx, gz = gz, rise = total,
				x = xSum / total * worldGridSize, z = zSum / total * worldGridSize }
		end
	end
	table.sort(risen, function(a, b) return a.rise > b.rise end)

	local added = {}
	for _, scene in ipairs(risen) do
		local apart = #added < cfg.maxScenes
		for _, other in ipairs(added) do
			apart = apart and max(math.abs(scene.gx - other.gx), math.abs(scene.gz - other.gz)) >= cfg.separation
		end

		local x, z, cell = scene.x, scene.z, scene.cell
		local side = owner[cell]
		local subjects, threats
		if apart and side then
			subjects, threats = scenes.subjects(x, z, side)
		end
		if subjects and side then
			added[#added + 1] = scene
			local f = foci.add('stake', side, scene.rise, x, z)
			if f then
				-- Who the trouble is from, for the headline; it adds no heat
				if threatBy[cell] then
					foci.record(f, 'threat', threatBy[cell], scene.rise)
				end
				for unitID in pairs(subjects) do
					foci.enlist(f, unitID, threats[unitID] and 'edge' or 'staked')
				end
			end
			if STATS then
				-- Share of the stake that is still on its way
				local soon = 1 - stakeNow[cell] / stake[cell]
				spEcho(string.format('rc-scene,%.0f,%.0f,%.0f,%.2f', x, z, scene.rise, soon))
			end
		end
	end
end

function widget:Shutdown()
  spSetCameraState(initialCameraState, 0)
end

function widget:Initialize()
	if not (spIsReplay() or spGetSpectatingState()) then
		spEcho("DEACTIVATING " .. widget:GetInfo().name .. " as not spec")
		widgetHandler:RemoveWidget()
		return
	end

	-- Init teams.
    local gaiaTeamID = spGetGaiaTeamID()
	teamInfo = {}
	local allyTeams = spGetAllyTeamList()
	for _, allyTeam in pairs(allyTeams) do
		local teamList = spGetTeamList(allyTeam)

		-- Zero-K names a team after its start box, or else its best rated player: "Team <name>" in
		-- full, which says it is a team, and "<name>" short, enough after a player's name
		local shortName = spGetGameRulesParam("allyteam_short_name_" .. allyTeam)
		local allyTeamName = spGetGameRulesParam("allyteam_long_name_" .. allyTeam)
		if string.len(allyTeamName) > 20 then
			allyTeamName = shortName
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
			scenes.names[allyTeam] = allyTeamName
			if teamID ~= gaiaTeamID then
				overlay.allyColor[allyTeam] = overlay.allyColor[allyTeam] or { spGetTeamColor(teamID) }
			end
			teamInfo[teamID] = {
				allyTeam = allyTeam,
				allyTeamName = shortName,
				color = { spGetTeamColor(teamID) } or { 1, 1, 1, 1 },
				name = teamName or ("Team " .. teamID)
			}
		end
	end
	-- A team named after one of its players ("Team <name>") is in that player's colour
	for _, info in pairs(teamInfo) do
		local named = scenes.names[info.allyTeam]
		if named == info.name or named == "Team " .. info.name then
			overlay.allyColor[info.allyTeam] = info.color
		end
	end

	unitInfo = UnitInfoCache:new({ updateListener = function(info)
		scenes.observe(info)
		foci.observe(info)
		foci.contact(info)
	end })

	-- Catch up on units made before the widget started, staggering their position updates
	gameFrame = Spring.GetGameFrame()
	for _, unitID in ipairs(Spring.GetAllUnits()) do
		unitInfo:get(unitID)
		if unitInfo.cache[unitID] then
			unitInfo.cache[unitID].lastUpdatedFrame = gameFrame - unitID % unitInfoCacheFrames
		end
	end


	initialCameraState = spGetCameraState()

	local cx, cy, cz = spGetCameraPosition()
	display = {
		camAngle = defaultRx,
		diag = 0,
		location = { mapSizeX / 2, -1000, mapSizeZ / 2 },
		camType = camTypeTracking,
		fill = frameFill,
		shotFrame = 0,
		velocity = { 0, 0, 0 }
	}
	if STATS then
		statsLogGame()
	end
	-- Open on a wide shot of the map
	showFocus(lull.wide(lullConfig.minPeak * lullConfig.scoreScale))
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

	scenes.update()
	foci.update()
	lull.update()

	-- Cut to whatever beats the shot on show by enough
	local best = lull.candidate ~= shown and lull.candidate or nil
	for _, f in ipairs(foci.list) do
		if f ~= shown and (not best or f.score > best.score) then
			best = f
		end
	end
	if best and best.score > 0 and beats(best) then
		showFocus(best)
	end
	foci.aside()
	overlay.update()
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

local moveCommands = {
	[CMD_ATTACK_MOVE] = true,
	[CMD_MOVE] = true,
	[CMD_RAW_MOVE] = true,
}

function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOpts, _)
    if not unitID or not unitDefID or not unitTeam or not cmdID or not cmdParams then
		return
	end

	if not moveCommands[cmdID] and cmdID ~= CMD_ATTACK then
		return
	end

	if overlay.arrowFrom and overlay.subjects[unitID] and not (cmdOpts and cmdOpts.shift) then
		overlay.redirect(unitID, cmdParams)
	end

	local unitDef = UnitDefs[unitDefID]
	if unitDef.customParams.dontcount or unitDef.customParams.is_drone then
		-- Drones get move commands too :shrug:
		return
	end

	local _, _, _, _, buildProgress = spGetUnitHealth(unitID)
	if not buildProgress or buildProgress < 1.0 then
		-- Don't watch units that aren't finished.
		return
	end

	-- A unit sent somewhere far counts once in a while, where it is: players reissue orders all the
	-- time. Orders to buildings, e.g. factories, don't count.
	local location, _, _, name, isStatic = unitInfo:get(unitID)
	local info = unitInfo.cache[unitID]
	if not location or not info or isStatic or gameFrame - (info.orderFrame or -huge) < foci.orderSeconds * framesPerSecond then
		return
	end
	local target = #cmdParams == 1 and unitInfo:get(cmdParams[1]) or #cmdParams >= 3 and cmdParams
	-- Smaller moves are mostly unit AI
	if not target or length(target[1] - location[1], target[3] - location[3]) < 256 then
		return
	end
	info.orderFrame = gameFrame
	local f = foci.add('orders', info.allyTeam, unitDef.metalCost, location[1], location[3], unitID)
	if f then
		foci.order(f, unitID, unitTeam, name, location, target)
	end
end

function widget:UnitCreated(unitID, unitDefID, unitTeam, builderID)
	if not unitID or not unitDefID or not unitTeam then
		return
	end

	local allyTeam = teamInfo[unitTeam].allyTeam
	unitInfo:watch(unitID, allyTeam, unitDefID)
	-- Zero-K's morph flags the unit it makes while making it
	if spGetGameRulesParam("morphUnitCreating") == 1 then
		foci.morphed[unitID] = true
	end
	if unitInfo.cache[unitID] then
		-- Not a threat until finished (see scenes), and what goes into it counts (see foci.observe)
		unitInfo.cache[unitID].unfinished, unitInfo.cache[unitID].builderID = true, builderID
	end
end

function widget:UnitDamaged(unitID, unitDefID, _, damage, paralyzer, _, _, attackerID, _, attackerTeam)
	-- attackerID and attackerTeam may be nil and are tolerated
	if not unitID or not unitDefID or not damage then
		return
	end

	local location = unitInfo:get(unitID)
	local info = unitInfo.cache[unitID]
	if info and attackerTeam then
		info.hitBy, info.hitFrame = attackerTeam, gameFrame
	end
	if paralyzer then
		-- A hit that stuns reports next to no damage, so count each stun once as the whole unit.
		local health, maxHealth, paralysis = spGetUnitHealth(unitID)
		if info and health and paralysis >= health and gameFrame - (info.stunFrame or -stunFrames) >= stunFrames then
			info.stunFrame, damage = gameFrame, max(damage, maxHealth)
		end
		-- Paralysis is not as important as real damage
		damage = damage / 2
	end

	if STATS then
		statsAddDamage(unitID, unitDefID, damage)
	end
	lull.addDamage(unitID, unitDefID, damage)
	if not location or not info then
		return
	end
	-- Damage nobody can be blamed for, such as fire burning on after whoever lit it has died, lava or
	-- a shell landing after its gun is gone, is mostly not the fight itself
	local value = foci.damageValue(unitID, unitDefID, damage, paralyzer) * (attackerID and 1 or unattributedDamageFactor)
	local f = foci.add('damage', info.allyTeam, value, location[1], location[3], unitID, attackerID)
	if f and attackerTeam and teamInfo[attackerTeam] then
		foci.record(f, 'dealt', teamInfo[attackerTeam].allyTeam, value)
	end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, _, attackerTeam)
	if not unitID then
		return
	end

	if STATS and unitDefID and unitTeam then
		statsLogDeath(unitID, unitDefID, unitTeam)
	end

	local destroyedLocation, _, _, destroyedName = unitInfo:get(unitID)
	-- Who gets the credit. Fire can kill after whoever lit it has died, so with no attacker a unit
	-- that died of damage goes to the side that last hit it.
	local info, unitDef = unitInfo.cache[unitID], unitDefID and UnitDefs[unitDefID]
	local health, _, _, _, buildProgress = spGetUnitHealth(unitID)
	local killerTeam = attackerTeam or info and info.hitBy and (health or 0) <= 0
		and gameFrame - info.hitFrame < overlay.creditFrames and info.hitBy
	local destroyerName
	if attackerID then
		_, _, _, destroyerName = unitInfo:get(attackerID)
	end
	-- What was lost goes to its focus, and the kill to the killer's side. A costly unit or a
	-- commander lost is news. Cancelled builds, commanders morphing and the like don't count.
	local lostSide = unitTeam and teamInfo[unitTeam] and teamInfo[unitTeam].allyTeam
	if destroyedLocation and unitDef and lostSide and not unitDef.customParams.dontcount and (attackerID or (health or 0) <= 0) then
		local value, x, z = unitDef.metalCost * (buildProgress or 1), destroyedLocation[1], destroyedLocation[3]
		local f = foci.add('destroyed', lostSide, value, x, z, unitID, attackerID)
		local killerSide = killerTeam and teamInfo[killerTeam] and teamInfo[killerTeam].allyTeam
		if f and killerSide and killerSide ~= lostSide then
			foci.record(f, 'kills', killerSide, value)
		end
		local commander = foci.isCommander(unitID, unitDef)
		if commander or value >= foci.highlightMetal then
			foci.highlight(f, { kind = 'destroyed', metal = max(value, commander and foci.highlightMetal or 0), name = destroyedName,
				by = destroyerName, team = killerTeam, x = x, z = z, burning = spGetUnitRulesParam(unitID, "on_fire") == 1 })
		end
	end
	unitInfo:forget(unitID)
	foci.morphed[unitID] = nil
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	if not unitID or not unitDefID or not unitTeam then
		return
	end

	local allyTeam = teamInfo[unitTeam].allyTeam
	local location, _, _, name = unitInfo:watch(unitID, allyTeam, unitDefID)
	local unitDef = UnitDefs[unitDefID]
	if not location or unitDef.customParams.dontcount then
		return
	end
	local x, z = location[1], location[3]
	local morphed = foci.morphed[unitID]
	foci.morphed[unitID] = nil
	local metal = unitDef.metalCost * (morphed and foci.morphShare or 1)
	local verb = morphed and (foci.isCommander(unitID, unitDef) and " upgraded" or " morphed") or " built"
	local f = foci.add('built', allyTeam, metal, x, z, unitID)
	if f then
		-- Also counted, for the callout. It names the costliest thing finished, each fading as heat
		-- does, so a cheaper unit finished since takes over after a few seconds. As all fade alike,
		-- the one named only changes when something new is finished.
		foci.record(f, 'units', allyTeam, 1)
		local b = f.lastBuilt
		if not b or metal >= b.metal * foci.binDecay ^ ((gameFrame - b.frame) / framesPerSecond) then
			f.lastBuilt = { unitID = unitID, name = name, team = unitTeam, x = x, z = z, metal = metal, frame = gameFrame, verb = verb }
		end
	end
	if metal >= foci.builtHighlightMetal then
		foci.highlight(f, { kind = 'built', metal = metal, name = name, team = unitTeam, unitID = unitID, x = x, z = z, verb = verb })
	end
end

function widget:UnitTaken(unitID, unitDefID, oldTeam, newTeam)
	if not unitID or not newTeam then
		return
	end

	-- Note that UnitTaken (and UnitGiven) are both called for both capture and release.
	local captureController = spGetUnitRulesParam(unitID, "capture_controller");
	if not captureController or captureController == -1 then
		return
	end

	local location, _, _, name = unitInfo:get(unitID)
	local lostSide = oldTeam and teamInfo[oldTeam] and teamInfo[oldTeam].allyTeam
	local unitDef = unitDefID and UnitDefs[unitDefID]
	if location and lostSide and unitDef then
		local f = foci.add('captured', lostSide, unitDef.metalCost, location[1], location[3], unitID, captureController)
		if unitDef.metalCost >= foci.captureHighlightMetal then
			foci.highlight(f, { kind = 'captured', metal = unitDef.metalCost, name = name, team = newTeam, unitID = unitID,
				x = location[1], z = location[3] })
		end
	end
end

-- The zoom the shot on show wants, when its units would fit zoomed in fit times; opening when it
-- is a new shot, close when the camera is close now (see closeUp). Something hotter nearby stops it
-- going close, but doesn't bring it out: the camera will likely go there anyway. Something about to
-- happen nearby does, to show it coming. Also why it wants no zoom.
function closeUp.wanted(c, fit, opening, close)
	local f = shown
	if f.wide or not f.heat or f.heat <= 0 then
		return 1, 'none'
	elseif fit < (close and closeUp.leaveZoom or closeUp.enterZoom) then
		-- Including what is arriving, and a scene being taken into frame
		return 1, 'fit'
	end
	local why = not close and opening and (overlay.kind == 'fight' and 'opening'
		or gameFrame < c.closeEnd + closeUp.restSeconds * framesPerSecond and 'rest')
	for _, other in ipairs(foci.list) do
		if other ~= f and other.heat and length(other.x - f.x, other.z - f.z) <= closeUp.range then
			if other.imminent and gameFrame - other.imminent <= 1.5 * framesPerSecond
			    and other.heat >= closeUp.imminentShare * f.heat then
				return 1, 'nearby'
			end
			why = why or not close and other.heat >= closeUp.rivalShare * f.heat and 'hotter'
		end
	end
	if why then
		return 1, why
	end
	return min(fit, closeUp.maxZoom)
end

local function updateCamera(dt, userCameraOverride)
	if not shown then
		return
	end
	local tlocation, tvelocity, points, context = foci.frame(shown, overlay.focus == shown and overlay.subjects)
	local xMin, xMax, zMin, zMax = huge, -huge, huge, -huge
	for _, p in ipairs(points) do
		xMin, xMax, zMin, zMax = min(xMin, p[1]), max(xMax, p[1]), min(zMin, p[2]), max(zMax, p[2])
	end
	local tdiag = distance({ xMin, 0, zMin }, { xMax, 0, zMax })
	-- Smoothly grade from camDiagMin to the target diag when the latter is 2x the former
	tdiag = tdiag + max(0, camDiagMin - tdiag * 0.5)
	tdiag = max(camDiagMin, tdiag)

	-- Apply damping to location if relatively close, to avoid overly twitchy camera
	if distance(display.location, tlocation) < trackDampRange then
		local new = trackDampRate * dt
		local function damp(old, target)
			return (1 - new) * old + new * target
		end
		local l, v = display.location, display.velocity
		display.diag = damp(display.diag, tdiag)
		display.location = { damp(l[1], tlocation[1]), damp(l[2], tlocation[2]), damp(l[3], tlocation[3]) }
		display.velocity = { damp(v[1], tvelocity[1]), damp(v[2], tvelocity[2]), damp(v[3], tvelocity[3]) }
	else
		display.diag = tdiag
		display.location = tlocation
		display.velocity = tvelocity
	end

	local c = camera
	local rotate = options.camera_rotation.value

	-- Where the camera should look: the event, ahead along its velocity by as much as the smoothing
	-- leaves it behind (velocity / trackDampRate when moving steadily), kept off the map edge
	local ex, ey, ez = unpack(display.location)
	local exv, _, ezv = unpack(display.velocity)
	ex, ez = ex + exv * framesPerSecond / trackDampRate, ez + ezv * framesPerSecond / trackDampRate
	ex, ez = bound(ex, mapEdgeBorder, mapSizeX - mapEdgeBorder), bound(ez, mapEdgeBorder, mapSizeZ - mapEdgeBorder)
	-- Frame the tracked box, at least display.diag across, by distance rather than zoom so the FOV
	-- stays constant. frameBox centres it as projected.
	local tpitch = display.camAngle
	-- Measure the units across and along the view rather than along the map axes, so the zoom doesn't
	-- depend on the heading. (Camera right is (-cos, sin) and ahead is (sin, cos) of the yaw.)
	local cy, sy = cos(c.yaw), sin(c.yaw)
	local half = display.diag / (2 * sqrt(2))
	local aMin, aMax, bMin, bMax = -half, half, -half, half
	local aside = display.aside
	if aside and not display.isWide and gameFrame - aside[3] < foci.asideFrames
	    and length(aside[1] - ex, aside[2] - ez) <= foci.asideRange then
		points[#points + 1] = aside
		display.asideFrame = gameFrame
	end
	for _, point in ipairs(points) do
		local dx, dz = point[1] - ex, point[2] - ez
		local a, b = dz * sy - dx * cy, dx * sy + dz * cy
		aMin, aMax, bMin, bMax = min(aMin, a), max(aMax, a), min(bMin, b), max(bMax, b)
	end
	local corners = {}
	for _, a in ipairs({ aMin, aMax }) do
		for _, b in ipairs({ bMin, bMax }) do
			corners[#corners + 1] = { ex - a * cy + b * sy, ez + a * sy + b * cy }
		end
	end
	local lx, lz, tdist = frameBox(corners, ey, c.yaw, tpitch, display.fill)
	local tlook = { bound(lx, mapEdgeBorder, mapSizeX - mapEdgeBorder), ey, bound(lz, mapEdgeBorder, mapSizeZ - mapEdgeBorder) }
	local tshift = { 0, 0 }
	if not display.isWide then
		tshift[1], tshift[2] = edgeShift(tlook, tdist, tpitch, c.yaw, corners)
	end

	-- Cut when a pan would take too long. A critically damped spring at capped speed takes roughly
	-- 2x its smooth time plus the distance at full speed.
	local remaining = distance(c.look, tlook)
	local isCut = c.cutNext or panSeconds(remaining) > maxPanSeconds

	if shown ~= c.shot then
		c.shot, c.orbited, c.yawSmooth = shown, false, yawSmoothTime
		if rotate and not isCut and not display.isWide then
			-- Turn towards the new event, as a drone pilot would, within limits
			local hx, hz = ex - c.x, ez - c.z
			if length(hx, hz) > 1 then
				c.tyaw = c.yaw + bound(wrapAngle(atan2(hx, hz) - c.yaw), -maxShotYawChange, maxShotYawChange)
			end
		end
	end

	if isCut then
		-- A cut is a new scene to the viewer: the callout starts where it best fits there
		overlay.box = nil
		c.look, c.lookv = tlook, { 0, 0, 0 }
		c.shift, c.shiftv = tshift, { 0, 0 }
		c.dist, c.distv = tdist, 0
		c.pitch, c.pitchv = tpitch, 0
		-- Face north again after a cut, so the viewer doesn't lose their bearings
		c.yaw, c.yawv, c.tyaw, c.yawSmooth = defaultRy, 0, defaultRy, yawSmoothTime
	else
		smoothDampVec(c.look, tlook, c.lookv, lookSmoothTime, dt, lookMaxSpeed)
		for i = 1, 2 do
			c.shift[i], c.shiftv[i] = smoothDamp(c.shift[i], tshift[i], c.shiftv[i], lookSmoothTime, dt)
		end
		local arc = min(tdist * panArcMax, remaining * panArcRise)
		c.dist, c.distv = smoothDamp(c.dist, tdist + arc, c.distv, distSmoothTime, dt)
		c.pitch, c.pitchv = smoothDamp(c.pitch, tpitch, c.pitchv, pitchSmoothTime, dt)
		if display.isWide then
			c.tyaw = defaultRy
		elseif rotate then
			planHeading(c)
		end
		local tyaw = rotate and c.tyaw or defaultRy
		c.yaw, c.yawv = smoothDamp(c.yaw, c.yaw + wrapAngle(tyaw - c.yaw), c.yawv, c.yawSmooth or yawSmoothTime, dt)
		c.yaw = wrapAngle(c.yaw)
		c.tyaw = c.yaw + wrapAngle(c.tyaw - c.yaw)
	end
	c.cutNext = false

	-- Zoom in on a close shot (see closeUp), judged from where the shot is headed: how far it could
	-- zoom with the units it frames filling the same share of the screen, and the rest of its units
	-- nearby still on it, a little in from the edge. Off centre by the edge shift, which keeps its
	-- place on screen as it zooms, so there is less room on that side.
	local fit, tx, tz, thalf = huge, tlocation[1], tlocation[3], tdiag / (2 * sqrt(2))
	local sa, sb = tshift[2] * sy - tshift[1] * cy, tshift[1] * sy + tshift[2] * cy
	local function room(dx, dz, limit)
		local a, b = dz * sy - dx * cy, dx * sy + dz * cy
		local function along(p, s)
			return math.abs(p) < 1 and huge or (limit + (p > 0 and s or -s)) / math.abs(p)
		end
		return min(along(a, sa), along(b, sb))
	end
	for _, point in ipairs(points) do
		fit = min(fit, room(point[1] - tx, point[2] - tz, thalf))
	end
	for _, point in ipairs(context or {}) do
		fit = min(fit, room(point[1] - tx, point[2] - tz, 0.9 * thalf / display.fill))
	end
	local opening = shown ~= c.zoomShot
	-- A cut ends a close-up: the next shot is a new scene
	if isCut and c.tzoom > 1 then
		c.tzoom, c.closeEnd = 1, gameFrame
	end
	local want, why = closeUp.wanted(c, fit, opening, c.tzoom > 1)
	if DEBUG and gameFrame % framesPerSecond == 0 and c.wantLogged ~= gameFrame then
		c.wantLogged = gameFrame
		spEcho(string.format('rc-want,%d,%.2f,%.2f,%s,%.0f,%.0f', shown.id, min(fit, 99), want, why or '', tshift[1], tshift[2]))
	end
	local quick, was = false, c.tzoom
	if opening or isCut then
		c.zoomShot, c.tzoom, c.zoomFrame, c.wantFrame = shown, want, gameFrame, nil
	elseif c.tzoom > 1 and c.tzoom > fit * closeUp.tooTight then
		c.tzoom, c.zoomFrame, c.wantFrame, quick = max(1, min(want, fit)), gameFrame, nil, true
	elseif math.abs(want - c.tzoom) > 0.1 then
		c.wantFrame = c.wantFrame or gameFrame
		if gameFrame - c.wantFrame >= (want > c.tzoom and closeUp.enterSeconds or closeUp.leaveSeconds) * framesPerSecond
		    and gameFrame - c.zoomFrame >= closeUp.holdSeconds * framesPerSecond then
			c.tzoom, c.zoomFrame, c.wantFrame = want, gameFrame, nil
		end
	else
		c.wantFrame = nil
	end
	local tzoom = c.tzoom
	if was > 1 and tzoom == 1 then
		c.closeEnd = gameFrame
	end
	if DEBUG and c.zoomFrame == gameFrame and c.loggedZoom ~= gameFrame then
		c.loggedZoom = gameFrame
		spEcho(string.format('rc-zoomto,%d,%s,%.2f,%s,%.2f', shown.id, overlay.kind or 'nil', tzoom,
			opening and (isCut and 'cut' or 'pan') or quick and 'tight' or 'decided', min(fit, 99)))
	end
	if isCut then
		c.zoom, c.zoomv = tzoom, 0
	else
		c.zoomQuick = quick or c.zoomQuick and c.zoom > tzoom + 0.01
		c.zoom, c.zoomv = smoothDamp(c.zoom, tzoom, c.zoomv, c.zoomQuick and closeUp.quickSmooth or closeUp.smooth, dt)
	end
	local function zoomFov(zoom)
		return 2 * deg(math.atan(tan(rad(defaultFov / 2)) / zoom))
	end

	-- Where the camera is headed, for placing the callout. An orbit takes many seconds, so for
	-- that it is the heading now.
	local orbiting = c.yawSmooth == orbitConfig.smoothTime
	c.settled = { look = { tlook[1] + tshift[1] / tzoom, tlook[2], tlook[3] + tshift[2] / tzoom }, dist = tdist, pitch = tpitch, yaw = (not rotate or display.isWide) and defaultRy or orbiting and c.yaw or c.tyaw,
		fov = zoomFov(tzoom), zoom = tzoom }

	-- Camera pose from the rig: behind the look-at point along the yaw, raised by the pitch. Off the
	-- look-at point by the edge shift, less as it zooms, so the look-at point keeps its place on screen.
	local lx, ly, lz = c.look[1] + c.shift[1] / c.zoom, c.look[2], c.look[3] + c.shift[2] / c.zoom
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
	c.rx, c.ry, c.fov = rx, ry, zoomFov(c.zoom)
	c.reticle = { xMin, zMin, xMax, zMax }

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
	-- For the callout's glide, which is drawn after this
	overlay.dt = dt
	overlay.follow(dt)
	if userInactiveSeconds > userInactiveSecondsThreshold then
		spSetMouseCursor('none')
	end
	updateCamera(dt, options.user_interrupts_tracking.value and userInactiveSeconds < userInactiveSecondsThreshold)
end

function widget:DrawWorldPreUnit()
	overlay.drawWorld()
end

function widget:DrawScreen()
	overlay.draw()
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
