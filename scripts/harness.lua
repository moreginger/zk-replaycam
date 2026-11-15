-- Offline harness for replaycam.lua (run with scripts/run-harness.py).
-- Stubs the Spring API and drives the widget through a scripted scenario: one side sends raiders
-- or bombers across the map at the other's undefended base. It checks that the widget loads and
-- runs without errors, and reports when scenes fire, what is shown and the cost per game frame.
-- It runs under Lua 5.4 rather than the engine's 5.1, and can't judge how the camera looks.
local WIDGET, SCENARIO = os.getenv('WIDGET'), os.getenv('SCENARIO') or 'raid'
unpack = table.unpack
math.atan2 = function(y, x) return math.atan(y, x) end
math.log10 = function(x) return math.log(x, 10) end
local realFormat = string.format
string.format = function(f, ...)  -- 5.4 is strict about %d with floats
	local a = { ... }
	for i, v in ipairs(a) do if math.type(v) == 'float' and v == math.floor(v) then a[i] = math.tointeger(v) end end
	return realFormat(f, unpack(a))
end

local frame, units, echoes, failed, texts = 0, {}, {}, false, {}
cam = { px = 4096, py = 2000, pz = 4096 }
local teams = { [0] = 0, [1] = 1 }
UnitDefs = {
	{ name = 'raider', speed = 90, metalCost = 65, weapons = { { weaponDef = 1 } }, customParams = {}, mobile = true },
	{ name = 'mex', speed = 0, metalCost = 75, weapons = {}, customParams = { ismex = 1 } },
	{ name = 'factory', speed = 0, metalCost = 800, weapons = {}, customParams = {} },
	{ name = 'bomber', speed = 90, metalCost = 300, weapons = { { weaponDef = 1 } }, customParams = {}, mobile = true },
	{ name = 'turret', speed = 0, metalCost = 120, weapons = { { weaponDef = 1 } }, customParams = {} },
}
WeaponDefs = { { customParams = { stats_damage = '100' }, salvoSize = 1, projectiles = 1, reload = 1, impactOnly = true, damageAreaOfEffect = 0, range = 300 } }
Game = { mapSizeX = 8192, mapSizeZ = 8192, mapName = 'Test' }
GL = { FILL = 1, FRONT_AND_BACK = 2, LINE = 3 }
gl = setmetatable({
	BeginEnd = function(_, draw) draw() end,
	GetTextWidth = function(text) return #text * 0.5 end,
	-- Catch what the engine would reject
	Text = function(text, x, y, size)
		assert(type(text) == "string" and x + y + size)
		texts[text:gsub("\255...", "<"):gsub("\008", ">")] = true
	end,
	Rect = function(a, b, c, d) assert(a + b + c + d) end,
	Vertex = function(x, y, z) assert(x + y + (z or 0)) end,
	Color = function(r, g, b, a) assert(r + g + b + (a or 1)) end,
}, { __index = function() return function() end end })
CMD = { ATTACK = 20, FIGHT = 16, MOVE = 10 }
VFS = { Include = function() return { RAW_MOVE = 31109 } end }
-- Windows for callouts to keep off: a bar along the top, a panel, and a full screen holder to ignore
WG = { Chili = { Screen0 = { children = {
	{ x = 0, y = 0, width = 1920, height = 60 }, { x = 1500, y = 700, width = 400, height = 300 },
	{ x = 0, y = 0, width = 1920, height = 1080 },
} } } }
widgetHandler = { RemoveWidget = function() error('widget removed') end }
widget = {}
Spring = setmetatable({
	Echo = function(...)
		local t = {} for i = 1, select('#', ...) do t[i] = tostring((select(i, ...))) end
		local line = table.concat(t, ', ')
		echoes[#echoes + 1] = { frame, line }
		if line:find('ERROR') or os.getenv('VERBOSE') then print(frame, line) end
		if line:find('ERROR') then failed = true end
	end,
	Utilities = { GetHumanName = function(ud) return ud.name end, getMovetype = function(ud) return ud.mobile and 2 or nil end },
	GetUnitPosition = function(id) local u = units[id] if u then return u.x, 0, u.z end end,
	GetUnitVelocity = function(id) local u = units[id] if u then return u.vx, 0, u.vz end end,
	GetUnitHealth = function(id) if units[id] then return units[id].health or 100, 100, 0, 0, 1 end end,
	GetUnitNoDraw = function() return false end,
	GetUnitDefID = function(id) return units[id] and units[id].def end,
	GetUnitTeam = function(id) return units[id] and units[id].team end,
	GetUnitRulesParam = function() end,
	GetAllUnits = function() local t = {} for id in pairs(units) do t[#t + 1] = id end return t end,
	GetUnitsInCylinder = function(x, z, r)
		local t = {}
		for id, u in pairs(units) do if (u.x - x) ^ 2 + (u.z - z) ^ 2 <= r * r then t[#t + 1] = id end end
		return t
	end,
	GetGroundHeight = function() return 0 end,
	GetViewGeometry = function() return 1920, 1080 end,
	-- Flat, north up, around where the camera is
	WorldToScreenCoords = function(x, y, z) return 960 + (x - cam.px) * 0.5, 540 - (z - cam.pz) * 0.5, 0.5 end,
	GetCameraState = function() return {} end,
	GetCameraPosition = function() return cam.px, cam.py, cam.pz end,
	SetCameraState = function(st) cam = st end,
	IsReplay = function() return true end,
	GetSpectatingState = function() return true end,
	GetGameFrame = function() return frame end,
	GetGaiaTeamID = function() return 99 end,
	GetAllyTeamList = function() return { 0, 1 } end,
	GetTeamList = function(a) return { a } end,
	GetTeamInfo = function(t) return t, t, false, false, 'x', teams[t] end,
	GetPlayerInfo = function(p) return 'Player' .. p end,
	GetTeamColor = function() return 1, 1, 1, 1 end,
	GetGameRulesParam = function(k) return k:find('long') and ('Team ' .. k:sub(-1)) or 'T' end,
	GetTeamRulesParam = function() end,
	GetMouseState = function() return 0, 0 end,
	SetMouseCursor = function() end,
	-- Rough footprint for a north-facing camera pitched at 1 rad
	TraceScreenRay = function(sx, sy)
		return 'ground', { cam.px + (sx / 1920 - 0.5) * cam.py * 1.3, 0, cam.pz - 0.64 * cam.py + (0.5 - sy / 1080) * cam.py * 0.9 }
	end,
	GetPixelDir = function() return 0, -1, 0 end,
}, { __index = function(_, k) return function() error('unstubbed Spring.' .. k, 2) end end })

assert(loadfile(WIDGET))()

local nextId = 1
local function spawn(def, team, x, z, vx, vz)
	local id = nextId
	nextId = nextId + 1
	units[id] = { def = def, team = team, x = x, z = z, vx = vx or 0, vz = vz or 0 }
	widget:UnitCreated(id, def, team)
	widget:UnitFinished(id, def, team)
	return id
end

widget:Initialize()
-- Team 1 base in the south east
for i = 1, 6 do spawn(2, 1, 5900 + i * 60, 6100) end
spawn(3, 1, 6000, 6000)
-- Team 0 base in the north west, with its own turret
for i = 1, 6 do spawn(2, 0, 1900 + i * 60, 1900) end
spawn(5, 0, 2000, 2100)
local attackers = {}
local n, def, speed = 5, 1, 3
if SCENARIO == 'bombers' then n, def, speed = 3, 4, 9 end
local d = speed / math.sqrt(2)
for i = 1, n do attackers[i] = spawn(def, 0, 2000 + i * 30, 2000, d, d) end

-- Extra units milling about, to measure cost
local crowd = tonumber(os.getenv('CROWD') or 0)
local firstScene, arrived, slowest, total, ticks = nil, nil, 0, 0, 0
for f = 1, 90 * 30 do
	frame = f
	for _, id in ipairs(attackers) do
		local u = units[id]
		-- Orders for the overlay's arrow: out, then (recall) back again, which redirects it
		if f == 60 then widget:UnitCommand(id, u.def, u.team, CMD.MOVE, { 6000, 0, 6000 }, {}) end
		if SCENARIO == 'recall' and f == 25 * 30 then
			u.vx, u.vz = -u.vx, -u.vz
			widget:UnitCommand(id, u.def, u.team, CMD.MOVE, { 2000, 0, 2000 }, {})
		end
		if math.abs(u.x - 6000) < 20 and u.vx > 0 then u.vx, u.vz = 0, 0 end
		if u.x < 2000 and u.vx < 0 then u.vx, u.vz = 0, 0 end
		u.x, u.z = u.x + u.vx, u.z + u.vz
	end
	-- Stagger the crowd's arrival, as in a real game
	for i = 1, crowd do
		if i % 30 == f then
			spawn(1, i % 2, 500 + (i * 37) % 7000, 500 + (i * 91) % 7000, ((i % 7) - 3) * 0.5, ((i % 5) - 2) * 0.5)
		end
	end
	local lead = units[attackers[1]]
	if lead.vx == 0 and SCENARIO ~= 'recall' then
		arrived = arrived or f
		-- Kill a building a second, from 2s after arriving
		local victim = (f - arrived) / 30 - 1
		if victim == math.floor(victim) and units[victim] and victim >= 1 and victim <= 7 then
			widget:UnitDamaged(victim, units[victim].def, 1, 100, false, nil, nil, attackers[1], 1, 0)
			units[victim].health = 0
			-- Some burn to death: with only the attacker's team known, or with nothing known
			local attacker = victim % 3 == 0 and attackers[1] or nil
			widget:UnitDestroyed(victim, units[victim].def, 1, attacker, attacker and 1, victim % 3 ~= 1 and 0 or nil)
			units[victim] = nil
		end
	end
	local before = #echoes
	local t0 = os.clock()
	widget:GameFrame(f)
	do
		local t = os.clock() - t0
		slowest, total, ticks = math.max(slowest, t), total + t, ticks + 1
	end
	widget:Update(1 / 30)
	widget:DrawWorldPreUnit()
	widget:DrawScreen()
	for i = before + 1, #echoes do
		local line = echoes[i][2]
		if line:find('^rc%-scene') then
			local u = units[attackers[1]]
			local dist = math.sqrt((u.x - 6000) ^ 2 + (u.z - 6000) ^ 2)
			if not firstScene then
				firstScene = f
				print(string.format('first scene at %.0fs, attackers %.0f elmos (%.1fs) out: %s', f / 30, dist, dist / speed / 30, line))
			end
		elseif line:find('^rc%-shown') then
			print(string.format('%5.1fs %s', f / 30, line))
		end
	end
end
local count = 0
for _, e in ipairs(echoes) do if e[2]:find('^rc%-scene') then count = count + 1 end end
print('scene events: ' .. count)
local drawn = {}
for text in pairs(texts) do drawn[#drawn + 1] = text end
table.sort(drawn)
print('callout texts: ' .. #drawn)
if os.getenv('VERBOSE') then print(table.concat(drawn, '\n')) end
print(string.format('per game frame: mean %.2f ms, worst %.2f ms, %d units', total / ticks * 1000, slowest * 1000, nextId - 1))
if os.getenv('LOG') then
	local out = io.open(os.getenv('LOG'), 'w')
	for _, e in ipairs(echoes) do out:write(string.format('[t=00:00:00.000000][f=%07d] %s\n', e[1], e[2])) end
	out:close()
end
if failed then error('the widget logged errors') end
