-- engine.lua — seasonal theme + watermark renderer, runs inside mpv (--script=themes/engine.lua)
--
-- Driven by kioskplayer (themes.py) through script-messages:
--   theme-load <manifest.json>   load sprites/elements/jokes + intensity (0..1, 1 = prime day)
--   theme-off                    remove theme
--   theme-mode idle|video|hidden where we are: idle screen, playing video (subtle), or nothing
--   watermark <json>|""          watermark sprite meta (+position, margin) or "" to remove
--
-- Sprites are premultiplied BGRA atlases (see themes.py): frames, then mirrored frames,
-- drawn with overlay-add. mpv draws overlays in id order, so decor gets the high ids and
-- moving actors the low ones: creatures can rise from *behind* pumpkins and stones.

local utils = require "mp.utils"
local msg = require "mp.msg"

local FPS = 30
local WM_ID = 63
local DECOR_IDS = { first = 40, last = 62 }
local ACTOR_IDS = { first = 0, last = 39 }

local M = nil            -- manifest
local mode = "hidden"
local W, H = 0, 0
local decor = {}         -- static/bobbing actors
local actors = {}        -- transient actors (walkers, flyers, peekers, particles, droppers)
local elements = {}      -- element state (next spawn time, active count)
local shown = {}         -- id -> last draw key (skip redundant overlay-add)
local free_ids = {}
local wm = nil
local timer = nil
local ass = mp.create_osd_overlay("ass-events")
local decks = {}         -- shuffled decks per text list ("jokes", "shouts")
local t0 = mp.get_time()

math.randomseed(os.time())

local function rnd(a, b) return a + math.random() * (b - a) end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function range(v, default)
    if type(v) == "table" then return v[1], v[2] end
    if v == nil then return default, default end
    return v, v
end

-- ── overlay plumbing ────────────────────────────────────────────────────────

-- variant: false/true (mirror) for normal sprites, or an index into spr.variants
-- ("right", "left", "up", "down") for sprites baked with directions.
local function draw(id, spr, frame, variant, x, y)
    local n = spr.frames
    local v = (variant == true) and 1 or (tonumber(variant) or 0)
    local idx = (frame % n) + v * n
    local xi, yi = math.floor(x + 0.5), math.floor(y + 0.5)
    local key = xi .. ":" .. yi .. ":" .. idx
    if shown[id] == key then return end
    shown[id] = key
    mp.command_native({ "overlay-add", id, xi, yi, spr.file, idx * spr.w * spr.h * 4, "bgra", spr.w, spr.h, spr.w * 4 })
end

local function hide(id)
    if shown[id] then
        shown[id] = nil
        mp.command_native({ "overlay-remove", id })
    end
end

local function reset_ids()
    free_ids = {}
    for id = ACTOR_IDS.first, ACTOR_IDS.last do free_ids[#free_ids + 1] = id end
end

local function take_id()
    return table.remove(free_ids)
end

local function give_id(id)
    hide(id)
    free_ids[#free_ids + 1] = id
end

-- ── helpers ─────────────────────────────────────────────────────────────────

local function intensity() return M and M.intensity or 0 end

-- Is this element allowed right now (intensity + idle/video mode)?
local function element_on(el)
    local i = intensity()
    if i < (el.min or 0) then return false end
    if el.max and i > el.max then return false end
    if mode == "video" and i < (el.video_min or 2) then return false end
    return true
end

-- count / interval scale with intensity between the element's min and 1.0
local function scaled(el, v, default)
    local lo, hi = range(v, default)
    local m = el.min or 0
    local p = (m >= 1) and 1 or clamp((intensity() - m) / (1 - m), 0, 1)
    return lo + (hi - lo) * p
end

local function sprite_of(el)
    local names = el.sprites or { el.sprite }
    local name = names[math.random(#names)]
    return M.sprites[name], name
end

-- Draw texts from a shuffled deck so they alternate without quick repeats.
local function next_text(list)
    local texts = M and M[list] or {}
    if #texts == 0 then return nil end
    local d = decks[list]
    if not d or d.pos >= #d.order or #d.order ~= #texts then
        d = { order = {}, pos = 0 }
        for k = 1, #texts do d.order[k] = k end
        for k = #d.order, 2, -1 do
            local j = math.random(k)
            d.order[k], d.order[j] = d.order[j], d.order[k]
        end
        decks[list] = d
    end
    d.pos = d.pos + 1
    return texts[d.order[d.pos]]
end

local function ass_escape(s)
    return (s:gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}"):gsub("\n", "\\N"))
end

-- In video mode (below prime) keep x inside the left/right border bands.
local function band_x(el, w)
    if mode == "video" and intensity() < 1 then
        local band = (el.video_band or 0.12) * W
        if math.random() < 0.5 then return rnd(0, math.max(1, band - w)) end
        return rnd(W - band, W - w)
    end
    return rnd(0, W - w)
end

-- ── decor (static, optionally bobbing / animated) ───────────────────────────

local ANCHORS = {
    ["bottom-left"]  = function(spr, dx, dy) return dx * W, H - spr.h - dy * H end,
    ["bottom-right"] = function(spr, dx, dy) return W - spr.w - dx * W, H - spr.h - dy * H end,
    ["top-left"]     = function(spr, dx, dy) return dx * W, dy * H end,
    ["top-right"]    = function(spr, dx, dy) return W - spr.w - dx * W, dy * H end,
    ["bottom"]       = function(spr, dx, dy) return dx * W, H - spr.h - dy * H end,
}

local function build_decor()
    for _, d in ipairs(decor) do hide(d.id) end
    decor = {}
    if not M or mode == "hidden" then return end
    local id = DECOR_IDS.last
    for _, el in ipairs(M.elements) do
        if el.type == "decor" and element_on(el) then
            local n = math.floor(scaled(el, el.count, 1) + 0.5)
            local places = el.places or { { el.x or 0.02, el.y or 0 } }
            for k = 1, math.min(n, #places) do
                local spr = sprite_of(el)
                if spr and id >= DECOR_IDS.first then
                    local fx = ANCHORS[el.anchor or "bottom-left"] or ANCHORS["bottom-left"]
                    local x, y = fx(spr, places[k][1], places[k][2])
                    decor[#decor + 1] = {
                        id = id, spr = spr, x = x, y = y, el = el,
                        mirror = places[k][3] == true, phase = rnd(0, 6.28),
                    }
                    id = id - 1
                end
            end
        end
    end
end

local function tick_decor(t)
    for _, d in ipairs(decor) do
        local frame = 0
        if d.spr.fps > 0 then frame = math.floor((t + d.phase) * d.spr.fps) end
        local by = 0
        if d.el.bob then by = math.sin(t * (d.el.bob_speed or 2) + d.phase) * d.el.bob * H end
        draw(d.id, d.spr, frame, d.mirror, d.x, d.y + by)
    end
end

-- ── transient actors ───────────────────────────────────────────────────────

local spawn = {}

-- particles: fall from top, sway sideways, optional spin frames; respawn while element is on
function spawn.particles(el, spr)
    local a = { el = el, spr = spr }
    a.x = band_x(el, spr.w)
    a.y = rnd(-H, -spr.h)
    a.vy = rnd(range(el.speed, 0.08)) * H
    a.sway = (el.sway or 0.02) * W
    a.phase = rnd(0, 6.28)
    a.spin = math.random(0, math.max(0, spr.frames - 1))
    function a.update(dt, t)
        a.y = a.y + a.vy * dt
        if a.y > H then return false end
        local frame = spr.spin > 1 and math.floor(a.spin + t * (el.spin_speed or 6)) or math.floor(t * spr.fps)
        return true, a.x + math.sin(t * 0.9 + a.phase) * a.sway, a.y, frame, false
    end
    return a
end

-- walker: walks along the bottom (or top) edge across the screen
function spawn.walker(el, spr)
    local a = { el = el, spr = spr }
    local ltr = math.random() < 0.5
    a.dir = ltr and 1 or -1
    a.x = ltr and -spr.w or W
    local edge = el.edge or "bottom"
    a.y = (edge == "top") and 0 or (H - spr.h * (el.reveal or 1.0))
    a.v = rnd(range(el.speed, 0.08)) * W
    -- art faces right by default; "faces": "left" flips the rule
    a.mirror = (a.dir < 0) ~= (el.faces == "left")
    function a.update(dt, t)
        a.x = a.x + a.dir * a.v * dt
        if a.x < -spr.w - 2 or a.x > W + 2 then return false end
        local frame = math.floor(t * math.max(spr.fps, 1))
        local wob = el.wobble and math.abs(math.sin(t * 8)) * el.wobble * H or 0
        return true, a.x, a.y - wob, frame, a.mirror
    end
    return a
end

-- flyer: crosses the screen on a wavy path in the upper part (bats, witches, ghosts)
function spawn.flyer(el, spr)
    local a = { el = el, spr = spr }
    local ltr = math.random() < 0.5
    a.dir = ltr and 1 or -1
    a.x = ltr and -spr.w or W
    local ylo, yhi = range(el.y, 0.15)
    if mode == "video" and intensity() < 1 then ylo, yhi = 0.0, 0.08 end
    a.y0 = rnd(ylo, yhi) * H
    a.v = rnd(range(el.speed, 0.15)) * W
    a.amp = (el.amp or 0.04) * H
    a.freq = rnd(1.5, 3.0)
    a.mirror = (a.dir < 0) ~= (el.faces == "left")
    function a.update(dt, t)
        a.x = a.x + a.dir * a.v * dt
        if a.x < -spr.w - 2 or a.x > W + 2 then return false end
        return true, a.x, a.y0 + math.sin(t * a.freq) * a.amp, math.floor(t * math.max(spr.fps, 1)), a.mirror
    end
    return a
end

-- dropper: spider lowering on a thread from the top, pausing, climbing back up
function spawn.dropper(el, spr)
    local a = { el = el, spr = spr, thread = true }
    a.x = band_x(el, spr.w)
    local dlo, dhi = range(el.depth, 0.3)
    if mode == "video" and intensity() < 1 then dlo, dhi = 0.08, 0.18 end
    a.depth = rnd(dlo, dhi) * H
    a.y = -spr.h
    a.v = (el.speed or 0.12) * H
    a.state, a.wait = "down", el.hold or 3
    function a.update(dt, t)
        if a.state == "down" then
            a.y = a.y + a.v * dt
            if a.y >= a.depth then a.y, a.state = a.depth, "hold" end
        elseif a.state == "hold" then
            a.wait = a.wait - dt
            if a.wait <= 0 then a.state = "up" end
        else
            a.y = a.y - a.v * 0.7 * dt
            if a.y < -spr.h then return false end
        end
        local sway = math.sin(t * 1.3) * 0.004 * W
        a.tx, a.ty = a.x + spr.w / 2 + sway, a.y
        return true, a.x + sway, a.y, math.floor(t * math.max(spr.fps, 1)), false
    end
    return a
end

-- crawler: a baked animated creature (clips walk / idle / wave) that walks across the screen
-- in one of four directions, matching speed to its walk cycle, and now and then stops to
-- look around or wave before walking on.
local DIR_INDEX = { right = 0, left = 1, up = 2, down = 3 }
local DIR_VEC = { right = { 1, 0 }, left = { -1, 0 }, up = { 0, -1 }, down = { 0, 1 } }

function spawn.crawler(el, spr)
    local walk = spr.clips and spr.clips.walk
    if not walk then return nil end
    local a = { el = el, spr = spr }
    local dirs = el.directions or { "right", "left" }
    if not spr.variants or #spr.variants < 4 then dirs = { "right", "left" } end
    a.dir = dirs[math.random(#dirs)]
    local dx, dy = DIR_VEC[a.dir][1], DIR_VEC[a.dir][2]
    a.variant = (#(spr.variants or {}) >= 4) and DIR_INDEX[a.dir] or (a.dir == "left")

    if dx ~= 0 then
        local ylo, yhi = range(el.y, 0.5)
        if mode == "video" and intensity() < 1 then ylo, yhi = 0.86, 0.92 end
        a.x = (dx > 0) and -spr.w or W
        a.y = rnd(ylo, yhi) * H - spr.h / 2
    else
        a.x = band_x(el, spr.w)
        a.y = (dy > 0) and -spr.h or H
    end
    a.dx, a.dy = dx, dy
    a.v = walk.stride_px * walk.fps / walk.count * (el.speed or 1.0)
    a.clip, a.tc = "walk", 0
    a.walk_left = rnd(range(el.walk, 3))

    local function onscreen()
        return a.x > 0 and a.y > 0 and a.x + spr.w < W and a.y + spr.h < H
    end

    local function start(clip, dur)
        a.clip, a.tc = clip, 0
        a.dur = dur
    end

    function a.update(dt, t)
        a.tc = a.tc + dt
        local c = spr.clips[a.clip]
        if a.clip == "walk" then
            a.x = a.x + a.dx * a.v * dt
            a.y = a.y + a.dy * a.v * dt
            a.walk_left = a.walk_left - dt
            if a.walk_left <= 0 and onscreen() then
                if spr.clips.wave and math.random() < (el.wave_chance or 0.4) then
                    start("wave", spr.clips.wave.count / spr.clips.wave.fps)
                elseif spr.clips.idle then
                    start("idle", rnd(range(el.pause, 1.5)))
                end
                a.walk_left = rnd(range(el.walk, 3))
            end
            if a.x < -spr.w - 2 or a.x > W + 2 or a.y < -spr.h - 2 or a.y > H + 2 then return false end
        elseif a.tc >= a.dur then
            start("walk")
            c = spr.clips.walk
        end
        local k = math.floor(a.tc * c.fps)
        if c.loop then k = k % c.count else k = math.min(k, c.count - 1) end
        return true, a.x, a.y, c.start + k, a.variant
    end
    return a
end

-- peeker: rises from an edge (or from behind a decor piece), lingers (waves/dances/talks), sinks back
function spawn.peeker(el, spr)
    local a = { el = el, spr = spr }
    local edge = el.edge or "bottom"
    local reveal = rnd(range(el.reveal, 0.8))
    local behind = nil
    if el.from == "decor" and #decor > 0 then behind = decor[math.random(#decor)] end

    if behind then
        edge = "bottom"
        a.x = behind.x + (behind.spr.w - spr.w) / 2 + rnd(-0.3, 0.3) * behind.spr.w
        a.hidden_y = behind.y + behind.spr.h * 0.6
        a.shown_y = a.hidden_y - spr.h * reveal
    elseif edge == "left" or edge == "right" then
        a.y = rnd(0.25, 0.75) * H - spr.h / 2
        if edge == "left" then
            a.hidden_x, a.shown_x = -spr.w, -spr.w + spr.w * reveal
        else
            a.hidden_x, a.shown_x = W, W - spr.w * reveal
        end
    else
        a.x = band_x(el, spr.w)
        a.hidden_y, a.shown_y = H, H - spr.h * reveal
    end
    a.edge = edge
    if edge == "bottom" then
        a.mirror = math.random() < 0.5
    else
        -- face into the screen: art faces right by default
        a.mirror = (edge == "right") ~= (el.faces == "left")
    end
    a.t, a.tin, a.thold, a.tout = 0, el["in"] or 1.2, el.hold or 4, el.out or 0.8
    if el.say then a.joke = next_text("shouts") end

    local function ease(p) return p * p * (3 - 2 * p) end
    function a.update(dt, t)
        a.t = a.t + dt
        local p
        if a.t < a.tin then p = ease(a.t / a.tin)
        elseif a.t < a.tin + a.thold then p = 1
        elseif a.t < a.tin + a.thold + a.tout then p = 1 - ease((a.t - a.tin - a.thold) / a.tout)
        else return false end
        a.talking = a.joke and p == 1
        local mirror = a.mirror
        local by = 0
        if el.dance and p == 1 then
            mirror = (math.floor(t * 2.5) % 2) == 1
            by = math.abs(math.sin(t * 5)) * 0.02 * H
        end
        local x, y
        if a.edge == "left" or a.edge == "right" then
            x, y = a.hidden_x + (a.shown_x - a.hidden_x) * p, a.y
        else
            x, y = a.x, a.hidden_y + (a.shown_y - a.hidden_y) * p - by
        end
        a.bx, a.by = x, y
        return true, x, y, math.floor(t * math.max(spr.fps, 1)), mirror
    end
    return a
end

local function try_spawn(el, now)
    local st = elements[el]
    if not st then
        -- first spawn soon after load, slightly staggered
        st = { next = now + rnd(1, 4), active = 0 }
        elements[el] = st
    end
    if el.type == "particles" then
        local want = math.floor(scaled(el, el.count, 5) + 0.5)
        if mode == "video" and intensity() < 1 then want = math.ceil(want * (el.video_share or 0.4)) end
        while st.active < want and #free_ids > 0 do
            local spr = sprite_of(el)
            if not spr then return end
            local a = spawn.particles(el, spr)
            a.id = take_id(); st.active = st.active + 1
            actors[#actors + 1] = a
        end
        return
    end
    if now < st.next then return end
    local max_active = math.floor(scaled(el, el.max_active, 1) + 0.5)
    if st.active >= max_active or #free_ids == 0 then
        st.next = now + 1
        return
    end
    local spr = sprite_of(el)
    if not spr or not spawn[el.type] then return end
    local a = spawn[el.type](el, spr)
    if not a then st.next = now + 5 return end
    a.id = take_id(); st.active = st.active + 1
    actors[#actors + 1] = a
    local lo, hi = range(el.every, 30)
    -- higher intensity → shorter pauses (down to a third at prime)
    local f = 1 - 0.66 * clamp((intensity() - (el.min or 0)) / math.max(0.01, 1 - (el.min or 0)), 0, 1)
    st.next = now + rnd(lo, hi) * f
end

-- ── ASS layer: spider threads, speech bubbles, banner jokes ─────────────────

local banner = nil  -- { text, until_t }

local function render_ass(now)
    local out = {}
    for _, a in ipairs(actors) do
        if a.thread and a.ty then
            out[#out + 1] = string.format(
                "{\\an7\\pos(0,0)\\bord0\\shad0\\1c&HDDDDDD&\\1a&H60&\\p1}m %d 0 l %d 0 l %d %d l %d %d{\\p0}",
                a.tx - 1, a.tx + 1, a.tx + 1, a.ty + 4, a.tx - 1, a.ty + 4)
        end
        if a.talking and a.joke and a.bx then
            local fs = math.floor(H * 0.035)
            local cx = clamp(a.bx + a.spr.w * 0.5, W * 0.15, W * 0.85)
            local cy = math.max(fs * 2, a.by - fs * 0.6)
            out[#out + 1] = string.format(
                "{\\an2\\pos(%d,%d)\\fs%d\\b1\\1c&H101010&\\3c&HFFFFFF&\\bord%d\\shad0\\4a&HFF&\\fnDejaVu Sans}%s",
                cx, cy, fs, math.floor(fs * 0.45), ass_escape(a.joke))
        end
    end
    if banner and now < banner.until_t then
        -- "Question? Answer!" jokes: question first, punchline a few seconds later on the next line
        local fs = math.floor(H * 0.042)
        local text = banner.text
        local q, a = text:match("^(.-%?)%s+(.+)$")
        if q then
            text = ass_escape(q)
            if now >= banner.punch_t then text = text .. "\\N" .. ass_escape(a) end
        else
            text = ass_escape(text)
        end
        out[#out + 1] = string.format(
            "{\\an8\\pos(%d,%d)\\q0\\fs%d\\b1\\1c&H00A5FF&\\3c&H000000&\\bord%d\\shad2\\fnDejaVu Sans}%s",
            W / 2, H * 0.12, fs, math.max(2, math.floor(fs * 0.08)), text)
    end
    ass.res_x, ass.res_y, ass.z = W, H, 5
    ass.data = table.concat(out, "\n")
    ass:update()
end

local function tick_banner(now)
    if not M or mode == "hidden" then banner = nil return end
    for _, el in ipairs(M.elements) do
        if el.type == "joke" and element_on(el) then
            local st = elements[el]
            if not st then st = { next = now + rnd(5, 15), active = 0 }; elements[el] = st end
            if now >= st.next and (not banner or now > banner.until_t) then
                local j = next_text("jokes")
                if j then
                    banner = { text = j, punch_t = now + (el.punchline or 3.5), until_t = now + (el.show or 8) }
                end
                local lo, hi = range(el.every, 60)
                st.next = now + rnd(lo, hi)
            end
        end
    end
end

-- ── main loop ───────────────────────────────────────────────────────────────

local last = mp.get_time()

local function tick()
    local now = mp.get_time()
    local dt = math.min(0.2, now - last)
    last = now
    local t = now - t0
    if not M or mode == "hidden" then return end

    tick_decor(t)

    for _, el in ipairs(M.elements) do
        if el.type ~= "decor" and el.type ~= "joke" and element_on(el) then try_spawn(el, now) end
    end

    local keep = {}
    for _, a in ipairs(actors) do
        local alive, x, y, frame, mirror = a.update(dt, t)
        if alive and element_on(a.el) then
            draw(a.id, a.spr, frame, mirror, x, y)
            keep[#keep + 1] = a
        else
            give_id(a.id)
            local st = elements[a.el]
            if st then st.active = st.active - 1 end
        end
    end
    actors = keep

    tick_banner(now)
    render_ass(now)
end

local function clear_actors()
    for _, a in ipairs(actors) do hide(a.id) end
    actors = {}
    elements = {}
    banner = nil
    reset_ids()
    ass.data = ""
    ass:update()
end

local function draw_watermark()
    if not wm or mode == "hidden" or W == 0 then
        hide(WM_ID)
        return
    end
    local m = wm.margin * H
    local pos = wm.position
    local x = pos:find("left") and m or (W - wm.w - m)
    local y = pos:find("bottom") and (H - wm.h - m) or m
    shown[WM_ID] = nil
    draw(WM_ID, wm, 0, false, x, y)
end

local function update_dims()
    local w = mp.get_property_number("osd-width", 0)
    local h = mp.get_property_number("osd-height", 0)
    if w > 0 and h > 0 then W, H = w, h end
end

local function refresh()
    update_dims()
    clear_actors()
    build_decor()
    draw_watermark()
    local run = (M ~= nil) and mode ~= "hidden"
    if run and not timer then
        last = mp.get_time()
        timer = mp.add_periodic_timer(1 / FPS, tick)
    elseif not run and timer then
        timer:kill()
        timer = nil
    end
end

mp.register_script_message("theme-load", function(path)
    local f = io.open(path, "r")
    if not f then msg.error("theme-load: cannot open " .. tostring(path)) return end
    local data = utils.parse_json(f:read("*a"))
    f:close()
    if not data then msg.error("theme-load: bad json " .. path) return end
    for name, s in pairs(data.sprites or {}) do
        s.fps = s.fps or 0
        s.spin = s.spin or 0
    end
    M = data
    msg.info(string.format("theme %s intensity %.2f, %d elements", M.theme, M.intensity, #(M.elements or {})))
    refresh()
end)

mp.register_script_message("theme-off", function()
    M = nil
    refresh()
end)

mp.register_script_message("theme-mode", function(m)
    if m == mode then return end
    mode = m
    refresh()
end)

mp.register_script_message("watermark", function(js)
    hide(WM_ID)
    wm = (js and js ~= "") and utils.parse_json(js) or nil
    draw_watermark()
end)

mp.observe_property("osd-dimensions", "native", function()
    local ow, oh = W, H
    update_dims()
    if W ~= ow or H ~= oh then refresh() end
end)

reset_ids()
