function widget:GetInfo()
	return { name = "RC Screenshots", desc = "Takes a screenshot every few game seconds, for headed replay runs", layer = 0, enabled = true }
end

-- Game seconds between screenshots
local every = 3

function widget:GameFrame(f)
	if f > 0 and f % (every * 30) == 0 then
		Spring.SendCommands("screenshot jpg")
		Spring.Echo(string.format("rc-screenshot,%d", f))
	end
end
