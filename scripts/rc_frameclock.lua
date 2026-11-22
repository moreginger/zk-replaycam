function widget:GetInfo()
	return {
		name = "RC Frame Clock",
		desc = "Draws the game frame as a strip of squares in the bottom left corner, for headed runs, so their videos can be synced by game time (see stack-videos.py)",
		-- Drawn last, on top of the game's own windows
		layer = -1000000,
		enabled = true,
	}
end

-- Cells are cell pixels square, along the bottom from the left: white, black (so a strip can be
-- told from whatever else is there), then bits cells of the frame number, lowest bit first,
-- white for 1
local cell, bits = 8, 16

local function square(i, on)
	local c = on and 1 or 0
	gl.Color(c, c, c, 1)
	gl.Rect(i * cell, 0, (i + 1) * cell, cell)
end

function widget:DrawScreen()
	local f = Spring.GetGameFrame()
	if f < 1 then
		return
	end
	square(0, true)
	square(1, false)
	for i = 0, bits - 1 do
		square(i + 2, math.floor(f / 2 ^ i) % 2 == 1)
	end
	gl.Color(1, 1, 1, 1)
end
