-- kiosksim: the prowler cat in a row of fixed poses, for checking its drawing.
-- Load over IPC: load-script tools/kiosksim/catsheet.lua (drive.py catsheet)
local dir = (debug.getinfo(1, "S").source or ""):match("^@(.*)/[^/]*$") or "."
local P = dofile(dir .. "/../../themes/prowler.lua")
local W = mp.get_property_number("osd-width", 1920)
local H = mp.get_property_number("osd-height", 1080)
local ov = mp.create_osd_overlay("ass-events")
ov.res_x, ov.res_y, ov.z = W, H, 10

local function set(c, t) for k, v in pairs(t or {}) do c.p[k] = v end end
local sheet = {
    { "stand" },
    { "walk 0", walk = 0.0 }, { "walk .25", walk = 0.25 }, { "walk .5", walk = 0.5 },
    { "tail low", walk = 0.6, tail = 2 },
    { "sit", pose = "SIT", feet = { nhx = 1.4, fhx = 1.0 } },
    { "sit front", pose = "SIT", feet = { nhx = 1.4, fhx = 1.0 }, set = { face = 0 } },
    { "lick", pose = "SIT", feet = { nhx = 1.4, fhx = 1.0 }, lick = true },
    { "scratch", pose = "SCRATCH", scratch = true },
    { "look back", set = { face = -1 } },
}
local out = {}
for i, s in ipairs(sheet) do
    local c = P.new({ W = W, H = H })
    c.dir = 1
    c.ground = H * (i <= 5 and 0.45 or 0.9)
    c.p.x = W * (((i - 1) % 5) * 0.19 + 0.05)
    set(c, P.poses.TAILS[s.tail or 1])
    if s.pose then set(c, P.poses[s.pose]) end
    c:neutral_feet(c.p)
    set(c, s.feet)
    if s.walk then c.phase = s.walk; c:gait() end
    set(c, s.set)
    if c.p.face == -1 then c.back = 1 end
    if s.lick then
        local hx, hy = c:head_at()
        set(c, { nfx = hx + 1.7, nfy = hy + 2.6, hp = 0.5, eye = 0.3, tongue = 1 })
    end
    if s.scratch then
        local sx = P.poses.SCRATCH.bl * math.cos(P.poses.SCRATCH.ba) + 3.9
        set(c, { nfx = sx, nfy = -10.4, ffx = sx - 0.3, ffy = -8.6 })
    end
    for _, e in ipairs(c:frame()) do out[#out + 1] = e end
    out[#out + 1] = string.format("{\\an8\\pos(%d,%d)\\fs%d\\bord2\\1c&HFFFFFF&\\3c&H000000&}%s",
        c.p.x + 4 * c.u, c.ground + 6, H * 0.022, s[1])
end
ov.data = table.concat(out, "\n")
ov:update()
mp.add_timeout(60, function() ov:remove() end)
