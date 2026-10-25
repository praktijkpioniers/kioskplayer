-- kiosksim: SPACE plays the video (theme in video mode, test subtitles), SPACE again or the end
-- of the video goes back to the idle logo (theme in idle mode); loop=yes: the video plays on and
-- on. script-message kiosk-play: start playing (multi.py --play).
local opts = { video = "", subs = "", logo = "", loop = "no" }
require("mp.options").read_options(opts, "kiosk")

local playing = false

local function to_idle()
    playing = false
    mp.set_property("loop-file", "inf")
    mp.commandv("loadfile", opts.logo, "replace")
    mp.commandv("script-message", "theme-mode", "idle")
end

local function play()
    playing = true
    mp.set_property("loop-file", "no")
    if opts.subs ~= "" then
        mp.commandv("loadfile", opts.video, "replace", "sub-files=" .. opts.subs)
    else
        mp.commandv("loadfile", opts.video, "replace")
    end
    mp.commandv("script-message", "theme-mode", "video")
    mp.osd_message("▶ video (SPACE = stop)", 2)
end

mp.add_forced_key_binding("SPACE", "kiosk-play", function()
    if playing then to_idle() else play() end
end)
mp.register_script_message("kiosk-play", function() if not playing then play() end end)

mp.register_event("end-file", function(e)
    if playing and e.reason == "eof" then
        if opts.loop == "yes" then play() else to_idle() end
    end
end)
