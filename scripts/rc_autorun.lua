function widget:GetInfo()
	return { name = "RC Autorun", desc = "Fast-forwards replay pregame, hides the command panel and quits at the end", layer = 0, enabled = true }
end

local pregameSpeed = 20
local fast = false

function widget:AddConsoleMessage(msg)
	if msg.text == "Beginning demo playback" and Spring.GetGameFrame() < 1 then
		-- The engine's own skip hangs when headless, so run the pregame fast instead
		Spring.SendCommands("setminspeed " .. pregameSpeed, "setminspeed 0.1")
		fast = true
	end
end

-- The command panel has nothing to show in a replay, and Zero-K's own option to hide it while
-- spectating doesn't take effect in replays, nor does turning it off (a HUD preset turns it back on)
local function hideCommandPanel()
	local screen = WG.Chili and WG.Chili.Screen0
	for _, child in ipairs(screen and screen.children or {}) do
		if child.name == 'integralwindow' and child.visible then
			child:Hide()
			Spring.Echo("rc-autorun command panel hidden")
		end
	end
end

function widget:GameFrame(f)
	if f % 30 == 0 then
		hideCommandPanel()
	end
	if fast then
		Spring.SendCommands("setmaxspeed 1", "setmaxspeed " .. pregameSpeed)
		fast = false
		Spring.Echo("rc-autorun game started")
	end
end

function widget:GameOver()
	Spring.Echo("rc-autorun game over")
	Spring.SendCommands("quitforce")
end
