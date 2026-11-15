function widget:GetInfo()
	return { name = "RC Autorun", desc = "Fast-forwards replay pregame and quits at the end", layer = 0, enabled = true }
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

function widget:GameFrame(f)
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
