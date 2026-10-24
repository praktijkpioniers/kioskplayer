-- engine.lua — seasonal theme + watermark renderer, runs inside mpv (--script=themes/engine.lua)
--
-- Driven by kioskplayer (themes.py) through script-messages:
--   theme-load <manifest.json>   load sprites/elements/jokes + level (0..9, 8 = prime day, 9 = demo)
--   theme-off                    remove theme
--   theme-mode idle|video|hidden where we are: idle screen, playing video (subtle), or nothing
--   watermark <json>|""          watermark sprite meta (+position, margin) or "" to remove
--   theme-overscan <json>        TV overscan: fraction hidden per side (n or [l, t, r, b])
--
-- Sprites are premultiplied BGRA atlases (see themes.py): frames, then mirrored frames,
-- drawn with overlay-add. mpv draws overlays in id order, so decor gets the high ids and
-- moving actors the low ones: creatures can rise from *behind* pumpkins and stones.

local utils = require "mp.utils"
local msg = require "mp.msg"

local FPS = 30
local DRAW_HZ = 15      -- default redraw rate of moving actors (each overlay-add costs a full OSD redraw)
local WM_ID = 0          -- below everything: creatures may hang over the logo
local DECOR_IDS = { first = 41, last = 63 }
local ACTOR_IDS = { first = 1, last = 40 }

local M = nil            -- manifest
local mode = "hidden"
local W, H = 0, 0         -- the visible area (screen minus overscan), everything is laid out in it
local FW, FH = 0, 0       -- the whole screen
local OX, OY = 0, 0       -- where the visible area starts
local overscan = { 0, 0, 0, 0 }  -- left, top, right, bottom: fractions a TV hides (theme-overscan)
local decor = {}         -- static/bobbing actors
local actors = {}        -- transient actors (walkers, flyers, peekers, particles, droppers)
local webs = {}          -- orb weavers (weaver.lua): not cleared by refresh, a video starting must not wipe a half-built web
local elements = {}      -- element state (next spawn time, active count)
local shown = {}         -- id -> last draw key (skip redundant overlay-add)
local free_ids = {}
local wm = nil
local timer = nil
local ass = mp.create_osd_overlay("ass-events")
local decks = {}         -- shuffled decks per text list ("jokes", "shouts")
local t0 = mp.get_time()

-- not just the time: screens started in the same second (a room after a power cut, or the
-- side-by-side test) would otherwise play exactly the same animations
do
    local seed = os.time() + (utils.getpid and utils.getpid() or 0) * 7919
    local f = io.open("/etc/hostname", "r")
    local host = f and f:read("*l") or ""
    if f then f:close() end
    for i = 1, #host do seed = (seed * 31 + host:byte(i)) % 2147483647 end
    math.randomseed(seed)
    for _ = 1, 5 do math.random() end
end

local function rnd(a, b) return a + math.random() * (b - a) end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function ease(p) return p * p * (3 - 2 * p) end
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
    -- past the end of the atlas mpv reads beyond the file and dies: never ask for that
    if v < 0 or v >= math.max(#(spr.variants or {}), 1) then return end
    local idx = (frame % n) + v * n
    local xi, yi = math.floor(x + OX + 0.5), math.floor(y + OY + 0.5)
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

local next_text
local demo
-- Preview overrides from the keyboard (test setups only: the kiosk runs mpv without keyboard input).
local preview = { level = nil, text = nil, mode = nil, fast = false }
local real_mode = "hidden"

-- Levels: 0 off, 1 = now and then one decoration … 8 = full blown (the day itself), 9 = demo grid.
local PRIME, DEMO = 8, 9
local function level() return preview.level or (M and M.level) or 0 end
local function text_on()
    if preview.text ~= nil then return preview.text end
    return M and M.text or false
end

-- What a talking character says: a shout, or (sometimes) a "question? punchline!" joke.
local function pick_line(el)
    if not (el.say and text_on()) then return nil end
    local j = (math.random() < (el.joke_chance or 0.3)) and next_text("jokes") or nil
    if j then
        local q, a = j:match("^(.-%?)%s+(.+)$")
        if q then return { text = q, punch = a } end
        return { text = j }
    end
    local sh = next_text("shouts")
    return sh and { text = sh } or nil
end

-- Is this element allowed right now (level + idle/video mode)?
local function element_on(el)
    local lv = level()
    if lv >= DEMO then return false end
    if lv < (el.min or 1) then return false end
    if el.max and lv > el.max then return false end
    if mode == "video" and lv < (el.video_min or 99) then return false end
    return true
end

-- How far the element has grown: 0 at its min level, 1 at its "full" level (default PRIME).
local function growth(el)
    local m, f = el.min or 1, el.full or PRIME
    if f <= m then return 1 end
    return clamp((level() - m) / (f - m), 0, 1)
end

-- count / interval scale with the level between the element's min and full level
local function scaled(el, v, default)
    local lo, hi = range(v, default)
    return lo + (hi - lo) * growth(el)
end

local function sprite_of(el)
    local names = el.sprites or { el.sprite }
    local name = names[math.random(#names)]
    return M.sprites[name], name
end

-- Draw texts from a shuffled deck so they alternate without quick repeats.
function next_text(list)
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

-- In video mode (below prime), or for elements with "band": true, keep x inside the
-- left/right border bands.
local function band_x(el, w)
    if (el.band or mode == "video") and level() < PRIME then
        local band = (el.video_band or 0.12) * W
        if math.random() < 0.5 then return rnd(0, math.max(1, band - w)) end
        return rnd(W - band, W - w)
    end
    return rnd(0, W - w)
end

-- ── the room: the other screens (theme-room / theme-room-claims from the player) ──
-- Neighbours: an actor crossing the edge towards one is handed over (theme-room-out → the player
-- → the room bus → the neighbour's theme-room-in) and goes on there, gap_px further.
-- Claims: what each screen shows (decor and unique actors, by sprite) is announced, so no two
-- screens in the room show the same thing. At start a screen first listens (room.ready) before it
-- puts anything up; if two screens took the same thing at once, the player tells the later one
-- to give it up (taken).
local room = { active = false, left = false, right = false, gap = 0, ready = true, taken = {} }
local handed_in = {}       -- handed-over actors, spawned on the next tick
local mine_sent = nil      -- the claims last told to the player
local NOT_UNIQUE = { flyer = true, particles = true }   -- travel from screen to screen / just leaves

local function claim_key(spr) return "spr:" .. tostring(spr and spr.name) end
local function taken(spr) return room.taken[claim_key(spr)] == true end
local function holding() return room.active and not room.ready end

-- a sprite of the element that no other screen shows (nil when all are)
local function free_sprite_of(el)
    for _ = 1, 8 do
        local spr = sprite_of(el)
        if not spr or not taken(spr) then return spr end
    end
end

local function room_send(name, t)
    local js, err = utils.format_json(t)
    if not js then
        local parts = {}
        for k, v in pairs(t) do parts[#parts + 1] = k .. "=" .. tostring(v) .. "(" .. type(v) .. ")" end
        msg.error(name .. ": " .. tostring(err) .. " " .. table.concat(parts, " "))
        return false
    end
    mp.commandv("script-message", name, js)
    return true
end

local function hand_over(side, h)
    if not room[side] then return false end
    h.side = side
    return room_send("theme-room-out", h)
end

-- ── decor (static, optionally bobbing / animated) ───────────────────────────

local ANCHORS = {
    ["bottom-left"]  = function(spr, dx, dy) return dx * W, H - spr.h - dy * H end,
    ["bottom-right"] = function(spr, dx, dy) return W - spr.w - dx * W, H - spr.h - dy * H end,
    ["top-left"]     = function(spr, dx, dy) return dx * W, dy * H end,
    ["top-right"]    = function(spr, dx, dy) return W - spr.w - dx * W, dy * H end,
    ["bottom"]       = function(spr, dx, dy) return dx * W, H - spr.h - dy * H end,
}

-- Decor comes up out of the ground (or down from the top edge, for things up there) and goes
-- back the same way, instead of popping in and out.
local DECOR_MOVE_S = 1.4

-- the offset that puts a thing just off the screen: below the bottom edge for things in the
-- lower half, above the top for the upper half
local function off_screen_dy(y, h)
    if y + h / 2 > H / 2 then return H - y + 2 end
    return -(y + h) - 2
end

local function decor_move(d, to)
    d.anim = { from = d.dy or 0, to = to, p = 0 }
end

-- decor that stands (not on its way out)
local function standing_decor()
    local list = {}
    for _, d in ipairs(decor) do if not d.leaving then list[#list + 1] = d end end
    return list
end

-- soft: keep what may stay, let the rest sink and new pieces rise (mode change, room); else start
-- over (theme loaded, screen resized)
local function build_decor(soft)
    if not soft or not M or mode == "hidden" then
        for _, d in ipairs(decor) do hide(d.id) end
        decor = {}
    end
    if not M or mode == "hidden" or holding() then return end
    local items = {}
    for _, d in ipairs(decor) do
        if not d.leaving then
            items[d.el] = items[d.el] or {}
            table.insert(items[d.el], d)
        end
    end
    local function want_n(el)
        return math.min(math.floor(scaled(el, el.count, 1) + 0.5), #(el.places or { 0 }))
    end
    local function keeps(el)
        local list = items[el]
        if not list or not element_on(el) or #list ~= want_n(el) then return false end
        for _, d in ipairs(list) do if taken(d.spr) then return false end end
        return true
    end
    -- decor with a "group" (e.g. "pumpkins"): one element of the group per screen; the one that
    -- is there stays, else one picked at random among those this screen may show
    local pick, seen = {}, {}
    for _, el in ipairs(M.elements) do
        if el.type == "decor" and el.group and keeps(el) then pick[el.group] = el end
    end
    for _, el in ipairs(M.elements) do
        local g = el.group
        if el.type == "decor" and g and not (pick[g] and keeps(pick[g])) and element_on(el) and free_sprite_of(el) then
            seen[g] = (seen[g] or 0) + 1
            if math.random(seen[g]) == 1 then pick[g] = el end
        end
    end
    local used, make = {}, {}
    for _, d in ipairs(decor) do if d.leaving then used[d.id] = true end end
    for _, el in ipairs(M.elements) do
        if el.type == "decor" then
            local wanted = element_on(el) and (not el.group or pick[el.group] == el)
            if wanted and keeps(el) then
                for _, d in ipairs(items[el]) do used[d.id] = true end
            else
                for _, d in ipairs(items[el] or {}) do
                    d.leaving = true
                    decor_move(d, off_screen_dy(d.y, d.spr.h))
                    used[d.id] = true
                end
                if wanted then make[#make + 1] = el end
            end
        end
    end
    local id = DECOR_IDS.last
    local function next_id()
        while id >= DECOR_IDS.first and used[id] do id = id - 1 end
        if id < DECOR_IDS.first then return nil end
        used[id] = true
        return id
    end
    for _, el in ipairs(make) do
        local places = el.places or { { el.x or 0.02, el.y or 0 } }
        for k = 1, want_n(el) do
            local spr = free_sprite_of(el)
            local did = spr and next_id()
            if did then
                local fx = ANCHORS[el.anchor or "bottom-left"] or ANCHORS["bottom-left"]
                local x, y = fx(spr, places[k][1], places[k][2])
                local d = {
                    id = did, spr = spr, x = x, y = y, el = el,
                    mirror = places[k][3] == true, phase = rnd(0, 6.28),
                }
                d.dy = off_screen_dy(y, spr.h)
                decor_move(d, 0)
                d.anim.p = -rnd(0, 0.4)          -- not all at once
                decor[#decor + 1] = d
            end
        end
    end
    room.claim_t = 0
end

local function tick_decor(t, dt)
    local keep = {}
    for _, d in ipairs(decor) do
        local gone = false
        if d.anim then
            local A = d.anim
            A.p = A.p + dt / DECOR_MOVE_S
            local p = clamp(A.p, 0, 1)
            -- sinking speeds up, rising slows down at the end
            local e = d.leaving and p * p or (1 - (1 - p) * (1 - p))
            d.dy = A.from + (A.to - A.from) * e
            if A.p >= 1 then
                d.anim = nil
                gone = d.leaving
            end
        end
        if gone then
            hide(d.id)
        else
            local frame = 0
            if d.spr.fps > 0 then frame = math.floor((t + d.phase) * d.spr.fps) end
            local by = 0
            if d.el.bob then by = math.sin(t * (d.el.bob_speed or 2) + d.phase) * d.el.bob * H end
            draw(d.id, d.spr, frame, d.mirror, d.x, d.y + by + (d.dy or 0))
            keep[#keep + 1] = d
        end
    end
    decor = keep
end

-- Exclusive groups ("group": "spider" or a list, on an element or on a visitor's cast entry):
-- nothing starts while something of the same group is on screen. One spider, one bat...
local function groups_of(x)
    local g = x and x.group
    if type(g) == "string" then return { g } end
    local copy = {}
    for _, v in ipairs(g or {}) do copy[#copy + 1] = v end
    return copy
end

local function group_busy(groups)
    if #groups == 0 then return false end
    local busy = {}
    for _, a in ipairs(actors) do busy[#busy + 1] = a end
    for _, w in ipairs(webs) do      -- a web counts while its spider is in it
        if not w.sp.gone then busy[#busy + 1] = w end
    end
    for _, a in ipairs(busy) do
        for _, g in ipairs(a.groups or {}) do
            for _, want in ipairs(groups) do if g == want then return true end end
        end
    end
    return false
end

-- ── transient actors ───────────────────────────────────────────────────────

local spawn = {}

-- particles: fall from top, sway sideways, optional spin frames; respawn while element is on.
-- "rest": [lo, hi] → land on the bottom and lie there that many seconds, then fade out (sprite
-- "fade" steps) over "fade_time"; at most "rest_max" lying at once (the others fall through).
-- Lying ones no longer count, so new ones keep falling.
function spawn.particles(el, spr)
    local a = { el = el, spr = spr }
    a.x = band_x(el, spr.w)
    a.y = rnd(-H, -spr.h)
    a.vy = rnd(range(el.speed, 0.08)) * H
    a.sway = (el.sway or 0.02) * W
    a.phase = rnd(0, 6.28)
    a.spin = math.random(0, math.max(0, spr.frames - 1))
    local land = H - spr.h * rnd(0.55, 0.95)
    local st = elements[el]
    a.leave = function() end            -- falls / lies on as it would, and is done
    local frame, x = 0, a.x
    function a.update(dt, t)
        if a.left then      -- lying on the ground
            a.left = a.left - dt
            if a.left <= 0 then return false end
            local fade_time = el.fade_time or 4
            local v = false
            if a.left < fade_time and spr.fades > 0 then
                v = 1 + math.min(spr.fades, math.ceil((1 - a.left / fade_time) * (spr.fades + 1)))
                if v > spr.fades + 1 then return false end
            end
            return true, x, land, frame, v
        end
        a.y = a.y + a.vy * dt
        frame = spr.spin > 1 and math.floor(a.spin + t * (el.spin_speed or 6)) or math.floor(t * spr.fps)
        x = a.x + math.sin(t * 0.9 + a.phase) * a.sway
        if el.rest and a.y >= land and st and (st.lying or 0) < scaled(el, el.rest_max, 6) then
            a.left = rnd(range(el.rest, 60))
            st.lying = (st.lying or 0) + 1
            st.active = st.active - 1
            a.uncounted = true
            a.release = function() st.lying = st.lying - 1 end
            return true, x, land, frame, false
        end
        if a.y > H then return false end
        return true, x, a.y, frame, false
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

-- flyer: crosses the screen high up (bats, witches, ghosts). el.y is the height in the middle;
-- el.bend lets the path sag towards the sides (an arc over the middle, which stays clear).
-- A sprite with "sizes" (or "depth") drifts nearer and farther: smaller is farther away, slower,
-- with less bob.
-- h: handed over by a neighbour (same flight, coming in from its side).
function spawn.flyer(el, spr, h)
    local a = { el = el, spr = spr }
    local ltr = math.random() < 0.5
    if h then ltr = h.dir == 1 end
    a.dir = ltr and 1 or -1
    a.x = ltr and -spr.w or W
    local ylo, yhi = range(el.y, 0.1)
    if mode == "video" and level() < PRIME then ylo, yhi = 0.0, 0.06 end
    a.y0 = (h and h.y0 or rnd(ylo, yhi)) * H
    a.bend = (h and h.bend or rnd(range(el.bend, 0))) * H
    -- depth: 1 near (full size) .. the smallest size far away; it drifts slowly while flying
    local sizes = spr.sizes or {}
    local far = sizes[#sizes] or 1
    local size0 = (spr.faint_at or #(spr.variants or {})) - 2 * #sizes   -- variant of sizes[1]
    a.rate = h and h.rate or rnd(0.25, 0.6)
    a.dph = h and h.dph or rnd(0, 2 * math.pi)
    local function depth(t) return far + (1 - far) * (0.5 + 0.5 * math.sin(t * a.rate + a.dph)) end
    a.v = (h and h.v or rnd(range(el.speed, 0.15))) * W   -- near; slower farther away
    a.amp = (el.amp or 0.04) * H
    a.freq = h and h.freq or rnd(1.5, 3.0)
    a.ph = 0
    local mirror = (a.dir < 0) ~= (el.faces == "left")
    local function variant(d)
        local best, bd = -1, 1 - d                        -- -1: full size
        for k, f in ipairs(sizes) do
            if math.abs(f - d) < bd then best, bd = k, math.abs(f - d) end
        end
        local v = (best < 0 and 0 or size0 + 2 * (best - 1)) + (mirror and 1 or 0)
        -- while a video plays: the faint copy ("video_opacity"), which has no fade variants
        if mode == "video" and spr.faint_at then
            v = spr.faint_at + (v < 2 and v or v - (spr.fades or 0))
        end
        return v
    end
    if h then
        -- it went over the neighbour's edge h.lead (× H) ago, plus the time on the way (h.late):
        -- the front comes in that far past our edge, gap_px later; bob and depth go on
        local late = clamp(tonumber(h.late) or 0, 0, 1)
        local now = mp.get_time() - t0
        a.ph = (h.ph or 0) + a.freq * late - a.freq * now
        a.dph = (h.dph or 0) + a.rate * late - a.rate * now
        local front = (h.lead or 0) * H + a.v * depth(now) * late - room.gap
        a.x = ltr and (front - spr.w) or (W - front)
    end
    a.leave = function() a.exit = 0 end      -- up and away, getting smaller
    function a.update(dt, t)
        local d = depth(t)
        if a.exit then
            a.exit = a.exit + dt
            d = d + (far - d) * math.min(1, a.exit / 1.5)
            a.y0 = a.y0 - H * (0.04 + 0.3 * a.exit) * dt
            a.bend = a.bend * (1 - math.min(1, dt * 2))
        end
        a.x = a.x + a.dir * a.v * d * dt
        -- the front reaches the edge it flies to: the neighbour takes over from here (for a
        -- moment both show a part)
        local lead = (a.dir > 0) and (a.x + spr.w - W) or (-a.x)
        if lead >= 0 and not a.handed_on and not a.exit then
            a.handed_on = true
            hand_over(a.dir > 0 and "right" or "left", {
                kind = "flyer", el = el.index, sprite = spr.name, dir = a.dir, lead = lead / H,
                y0 = a.y0 / H, bend = a.bend / H, v = a.v / W, freq = a.freq, ph = t * a.freq + a.ph,
                rate = a.rate, dph = t * a.rate + a.dph })
        end
        if a.x < -spr.w - 2 or a.x > W + 2 then return false end
        local side = 2 * math.abs((a.x + spr.w / 2) / W - 0.5)   -- 0 in the middle, 1 at the edges
        local y = a.y0 + a.bend * side * side + math.sin(t * a.freq + a.ph) * a.amp * d
        if y < -spr.h - 2 then return false end
        return true, a.x, y, math.floor(t * math.max(spr.fps, 1)), variant(d)
    end
    return a
end

-- dropper: spider lowering on a thread from the top, pausing, climbing back up
function spawn.dropper(el, spr)
    local a = { el = el, spr = spr, thread = true }
    a.x = band_x(el, spr.w)
    local dlo, dhi = range(el.depth, 0.3)
    if mode == "video" and level() < PRIME then dlo, dhi = 0.08, 0.18 end
    a.depth = rnd(dlo, dhi) * H
    a.y = -spr.h
    a.v = (el.speed or 0.12) * H
    a.state, a.wait = "down", el.hold or 3
    a.leave = function() a.state, a.v = "up", a.v * 1.8 end
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
        return true, a.x + sway, a.y, math.floor(t * math.max(spr.fps, 1)), false
    end
    return a
end

-- crawler: a baked animated creature (clips walk / idle / wave) that walks across the screen
-- in one of four directions, matching speed to its walk cycle, and now and then stops to
-- look around or wave before walking on.
local DIR_INDEX = { right = 0, left = 1, up = 2, down = 3 }
local DIR_VEC = { right = { 1, 0 }, left = { -1, 0 }, up = { 0, -1 }, down = { 0, 1 } }
local OPPOSITE = { right = "left", left = "right", up = "down", down = "up" }

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
        if mode == "video" and level() < PRIME then ylo, yhi = 0.86, 0.92 end
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

    -- "wander": [8, 16] → an erratic path: a new direction every el.turn seconds, turning back
    -- in at the sides; after the wander time it heads for the nearer of top and bottom, and once
    -- out there it is done
    local wander = el.wander and not (mode == "video" and level() < PRIME)
    local wander_s = wander and rnd(range(el.wander, 12)) or 0
    local age, seg, entered = 0, 0, false
    local function set_dir(d)
        a.dir = d
        a.dx, a.dy = DIR_VEC[d][1], DIR_VEC[d][2]
        a.variant = (#(spr.variants or {}) >= 4) and DIR_INDEX[d] or (d == "left")
    end
    local function steer(dt)
        age, seg = age + dt, seg - dt
        if not entered then
            entered = a.x > 0 and a.y > 0 and a.x + spr.w < W and a.y + spr.h < H
            if not entered then return end
            seg = rnd(range(el.turn, 0.8))
        end
        local going = age > wander_s
        if going and seg > 1e8 then return end
        -- about to cross an edge it may not leave by: turn now
        local m = 0.02 * H
        local at_edge = (a.dx < 0 and a.x < m) or (a.dx > 0 and a.x + spr.w > W - m)
            or (not going and ((a.dy < 0 and a.y < m) or (a.dy > 0 and a.y + spr.h > H - m)))
        if seg > 0 and not at_edge then return end
        if going then
            set_dir((a.y + spr.h / 2 < H / 2) and "up" or "down")
            seg = 1e9
            return
        end
        local choices = {}
        for _, d in ipairs({ "right", "left", "up", "down" }) do
            local ok = d ~= OPPOSITE[a.dir] or math.random() < 0.25
            if d == "left" and a.x < W * 0.12 then ok = false end
            if d == "right" and a.x + spr.w > W * 0.88 then ok = false end
            if d == "up" and a.y < H * 0.12 then ok = false end
            if d == "down" and a.y + spr.h > H * 0.88 then ok = false end
            if ok then choices[#choices + 1] = d end
        end
        if #choices > 0 then set_dir(choices[math.random(#choices)]) end
        seg = rnd(range(el.turn, 0.8))
    end

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
            if wander then steer(dt) end
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

-- performer: a baked character acting out a little scene from its clips.
--   enter: "rise" (out of the ground at the bottom edge, or from behind a decor piece — decor is
--          drawn on top, so it hides the legs) or "walk" (in from a side, then "turn_front")
--   acts:  1..n clips from el.acts facing the viewer ("idle" loops for a while), saying a shout
--   exit:  "sink" (rise played backwards) or "walk" ("turn_side", then off-screen)
-- Clips are baked facing right; the mirror variant makes the whole scene face left.
function spawn.performer(el, spr)
    local C = spr.clips
    if not (C and C.rise or C and C.walk) then return nil end
    local a = { el = el, spr = spr }
    local function pick(list, default)
        local ok = {}
        for _, n in ipairs(list or default) do
            local clip = (n == "sink") and "rise" or n
            if C[clip] then ok[#ok + 1] = n end
        end
        return ok[math.random(math.max(1, #ok))]
    end
    local enter = pick(el.enter, { "rise", "walk" })
    local exit = pick(el.exit, { "sink", "walk" })
    if not enter or not exit then return nil end

    local standing = standing_decor()
    local behind = (enter == "rise" and el.from_decor ~= false and #standing > 0 and math.random() < (el.from_decor or 0.5))
        and standing[math.random(#standing)] or nil
    local ground = H + spr.h * (el.sink or 0.0)  -- feet line (sprite bottom)
    a.mirror = math.random() < 0.5
    if behind then
        ground = behind.y + behind.spr.h * 0.92
        a.x = behind.x + (behind.spr.w - spr.w) / 2
    elseif enter == "walk" then
        a.x = a.mirror and W or -spr.w
        a.target = band_x(el, spr.w)
    else
        a.x = band_x(el, spr.w)
    end
    a.y = ground - spr.h

    -- the scene as a list of steps
    local steps = {}
    if enter == "rise" then steps[#steps + 1] = { clip = "rise" }
    else
        steps[#steps + 1] = { clip = "walk", to = a.target }
        if C.turn_front then steps[#steps + 1] = { clip = "turn_front" } end
    end
    local acts = el.acts or { "cheer", "taunt", "idle" }
    for k = 1, math.floor(rnd(range(el.n_acts, 2)) + 0.5) do
        local n = acts[math.random(#acts)]
        if C[n] then
            steps[#steps + 1] = { clip = n, act = true, dur = C[n].loop and rnd(range(el.idle, 2)) or nil }
        end
    end
    if exit == "sink" and not (enter == "walk") then steps[#steps + 1] = { clip = "rise", reverse = true }
    else
        if C.turn_side then steps[#steps + 1] = { clip = "turn_side" } end
        steps[#steps + 1] = { clip = "walk", off = true }
    end
    a.line = pick_line(el)
    if a.line and a.line.punch and C.idle then
        -- a joke needs time for the punchline: stand still after the first act
        table.insert(steps, math.min(#steps + 1, (enter == "rise") and 3 or 4), { clip = "idle", act = true, dur = 7 })
    end

    local walk = C.walk
    local v = walk and walk.stride_px * walk.fps / walk.count * (el.speed or 1.0) or 0
    local dir = a.mirror and -1 or 1
    local si, tc = 1, 0

    function a.update(dt, t)
        local s = steps[si]
        if not s then return false end
        tc = tc + dt
        local c = C[s.clip]
        local done
        if s.clip == "walk" then
            a.x = a.x + dir * v * dt
            if s.off then
                if a.x < -spr.w - 2 or a.x > W + 2 then return false end
            elseif (dir > 0 and a.x >= s.to) or (dir < 0 and a.x <= s.to) then
                done = true
            end
        else
            done = tc >= (s.dur or c.count / c.fps)
        end
        local k = math.floor(tc * c.fps)
        if c.loop then k = k % c.count else k = math.min(k, c.count - 1) end
        if s.reverse then k = c.count - 1 - k end
        a.talking = a.line and s.act
        if a.talking and not a.say_t then a.say_t = t end
        local frame = c.start + k
        if done then si, tc = si + 1, 0 end
        return true, a.x, a.y, frame, a.mirror
    end
    return a
end

-- vampire: a baked character with his coffin (tools/bake/coffin.py): three sprites on three
-- overlay ids — lid (behind him), vampire, box (in front: in it, he is hidden). Sprites with
-- "unit" share one scale and carry "origin" (baked x = 0 on the ground) to line them up.
--   in:  comes in (walking or sneaking) and across, looks around, reaches off-screen and pulls
--        the coffin in walking backwards; wanders about, now sneaking, now dashing; raises a hand
--        and the lid creaks open; jumps in, lies down, the lid closes. A while inside (the lid
--        lifts a crack now and then); hidden, he doesn't count as a walker.
--   out: (once no other walker is about) the lid opens, he gets up, jumps out, the lid shuts,
--        he pushes the coffin off the side it came from and goes off the other side.
-- The scene is planned in its own space (coming in from the left) and mirrored half the time.
function spawn.vampire(el, spr)
    local S = M.sprites
    local lie, box, lid = S[el.lie or ""], S[el.box or ""], S[el.lid or ""]
    local C, L = spr.clips, lie and lie.clips
    if not (C and C.walk and C.pull and C.push and C.reach and L and L.lie_down and L.stand_up
            and box and lid and spr.origin and lie.origin and box.origin and lid.origin and spr.unit) then
        return nil
    end
    local u = spr.unit * H
    local half = box.w / 2              -- coffin half length (its origin is the middle)
    local hands = 0.5 * u               -- his origin → his hands, reaching
    local rest = 0.42 * u               -- coffin middle → his origin, lying (head to the left)
    local sink = (el.sink or 0.45) * u  -- in the coffin he stands/lies this much lower (hidden by the box)
    local hop = 1.3 * u                 -- jump height (clears the box)
    if W < 2 * box.w + 6 * u then return nil end
    local a = { el = el, spr = spr, layers = 3 }
    local d = math.random() < 0.5 and 1 or -1
    local open = lid.frames - 1

    -- the plan: steps that walk (to, at a gait), jump, play a clip (once, or for dur), carry the
    -- coffin along, animate the lid (lid = {from, to}), show him lying (lie) or not at all (hide)
    local steps, X, Y, face = {}, -1.2 * u, 0, 1   -- Y: how deep in the coffin; face: 1 right, -1 left, 0 the viewer
    local function add(s) s.sink = s.sink or Y; steps[#steps + 1] = s; return s end
    local function turn(f)
        if f == face then return end
        if face ~= 0 and C.turn_front then add { clip = "turn_front", m = face < 0 } end
        if f ~= 0 and C.turn_side then add { clip = "turn_side", m = f < 0 } end
        face = f
    end
    local function gait()
        local r = math.random()
        if C.run and r < 0.25 then return "run", rnd(1.3, 1.7) end   -- vampires can be quick
        if C.sneak and r < 0.6 then return "sneak", 1 end
        return "walk", 1
    end
    local function go(to, clip, rate)
        turn(to > X and 1 or -1)
        add { clip = clip or "walk", to = to, m = face < 0, rate = rate }
        X = to
    end
    local function jump(to, y)
        turn(to > X and 1 or -1)
        add { clip = C.jump and "jump" or "walk", jump = { X, to, Y, y }, m = face < 0, dur = C.jump and nil or 1.0 }
        X, Y = to, y
    end
    local function stop(clip, dur)
        turn(0)
        add { clip = clip, dur = dur, act = true }
    end

    local cx = rnd(math.max(W * 0.3, half + 2 * u), math.min(W * 0.7, W - half - 2 * u))
    -- in and across, a look around, the coffin pulled in from the far side
    go(W - 0.7 * u, math.random() < 0.5 and C.sneak and "sneak" or "walk")
    stop("idle", rnd(1.5, 3))
    turn(1)
    add { clip = "reach" }
    X = cx - half - hands
    add { clip = "pull", to = X, carry = true }
    stop("idle", rnd(1, 2.5))
    -- wander
    for _ = 1, math.random(1, 3) do
        local to
        repeat to = rnd(u, W - u) until math.abs(to - X) > 3 * u
        go(to, gait())
        local r = math.random()
        if C.raise and r < 0.3 then stop("raise")
        elseif r < 0.55 then stop("idle", rnd(0.6, 1.2))   -- a short freeze
        else stop("idle", rnd(1.5, 3.5)) end
    end
    -- to the coffin's end; a raised hand opens the lid; a jump in, lie down, the lid closes
    go(X < cx and (cx - half - 0.35 * u) or (cx + half + 0.35 * u))
    turn(0)
    add { clip = C.raise and "raise" or "idle", dur = (not C.raise) and 1.5 or nil, lid = { 0, open } }
    jump(cx + rest, sink)
    turn(1)
    add { clip = "lie_down", lie = true }
    add { hide = true, dur = 1.0, lid = { open, 0 } }
    local stay = rnd(range(el.stay, 40))
    local crack = math.min(3, open)
    while stay > 0 do
        local wait = math.min(stay, rnd(8, 20))
        add { hide = true, dur = wait }
        stay = stay - wait
        if stay > 6 and math.random() < 0.5 then
            add { hide = true, dur = 0.5, lid = { 0, crack } }
            add { hide = true, dur = rnd(1, 2.5) }
            add { hide = true, dur = 0.3, lid = { crack, 0 } }
        end
    end
    -- up and out; the lid shuts while he turns; the coffin pushed off, he goes off the other way
    add { hide = true, dur = 1.2, lid = { 0, open }, wake = true }
    add { clip = "stand_up", lie = true }
    face = 1
    jump(cx - half - hands, 0)
    local n = #steps
    turn(1)
    steps[n + 1].lid, steps[n + 1].dur = { open, 0 }, 1.0
    add { clip = "push", push = true }
    X = W + half
    stop("idle", rnd(1, 2))
    go(-1.5 * u, gait())

    -- play
    local si, tc = 1, 0
    local vx = -1.2 * u                -- his origin (scene space)
    local coffin                       -- coffin middle (scene space), nil until pulled in
    local lf = 0                       -- lid frame
    a.line = pick_line(el)
    local function place(sp, x, frame, mirror, dy)
        local m = (mirror and true or false) ~= (d < 0)
        local ox = m and (sp.w - sp.origin[1]) or sp.origin[1]
        return { spr = sp, frame = frame, variant = m, x = ((d > 0) and x or (W - x)) - ox, y = H - sp.origin[2] + dy }
    end

    function a.update(dt, t)
        local s = steps[si]
        if not s then return false end
        if s.hide and not a.hiding then   -- hidden in the coffin: walkers may come by meanwhile
            a.hiding, a.groups = a.groups, {}
            for _, g in ipairs(a.hiding) do if g ~= "walker" then a.groups[#a.groups + 1] = g end end
        end
        if si ~= a.logged then a.logged = si msg.verbose("vampire step " .. tostring(s.clip or "hidden")) end
        if s.wake and a.hiding then
            if group_busy(a.hiding) then tc = 0 dt = 0   -- someone else walks about: stay in
            else a.groups, a.hiding = a.hiding, nil end
        end
        tc = tc + dt
        local c = s.clip and (s.lie and L[s.clip] or C[s.clip])
        local rate = s.rate or 1
        local done
        local dy = s.sink or 0
        if s.jump then
            local x0, x1, y0, y1 = s.jump[1], s.jump[2], s.jump[3], s.jump[4]
            local dur = s.dur or c.count / c.fps
            local q = clamp((tc / dur - 0.2) / 0.6, 0, 1)   -- airborne in the middle of the clip
            vx = x0 + (x1 - x0) * ease(q)
            dy = y0 + (y1 - y0) * q - hop * math.sin(math.pi * q)
            done = tc >= dur
        elseif s.to or s.push then
            local v = c.stride_px * c.fps / c.count * rate * (el.speed or 1.0)
            local dir = s.push and 1 or (s.to > vx and 1 or -1)
            vx = vx + dir * v * dt
            if s.push then
                done = vx + hands > W + 2
            elseif (dir > 0 and vx >= s.to) or (dir < 0 and vx <= s.to) then
                vx, done = s.to, true
            end
            if s.carry or s.push then coffin = vx + hands + half end
        else
            done = tc >= (s.dur or c.count / c.fps)
        end
        if s.lid then
            local p = clamp(tc / (s.dur or c.count / c.fps), 0, 1)
            lf = math.floor(s.lid[1] + (s.lid[2] - s.lid[1]) * p + 0.5)
        end

        local layers = {}
        if coffin then
            layers[1] = place(lid, coffin, lf, false, 0)
            layers[3] = place(box, coffin, 0, false, 0)
        end
        -- the cat may climb onto the coffin, while it lies still with the lid shut (the cat is drawn
        -- below all sprites: an open lid or the vampire would cover it)
        local near = coffin and not s.hide and math.abs(vx - coffin) < half + 1.5 * u
        local still = s.hide and lf <= crack or (lf == 0 and not near and not s.carry and not s.push)
        a.solid = still and layers[3] or nil
        if c and not s.hide then
            local k = math.floor(tc * c.fps * rate)
            if c.loop then k = k % c.count else k = math.min(k, c.count - 1) end
            local l = place(s.lie and lie or spr, vx, c.start + k, s.m, dy)
            layers[2] = l
            a.sx, a.sy = l.x, l.y
        end
        a.talking = a.line and s.act and true or false
        if a.talking and not a.say_t then a.say_t = t end
        if done then si, tc = si + 1, 0 end
        if s.push and done then coffin = nil end
        return true, layers
    end
    return a
end

-- visitor: a decoration that comes and goes (low levels: "now and then a pumpkin").
-- el.cast = list of { sprite, anchor, places } like decor; one entry is picked per visit.
-- It slides in from its corner/edge, stays el.stay seconds, slides out again. Two visitors
-- never take the same place.
local busy_places = {}  -- "anchor:k" -> true while taken

function spawn.visitor(el, _)
    local options = {}
    for _, c in ipairs(el.cast or {}) do
        local names = c.sprites or { c.sprite }
        if M.sprites[names[1]] and not group_busy(groups_of(c)) then
            if c.near_logo then   -- one place: somewhere around the logo (see below)
                if not busy_places.logo then options[#options + 1] = { c = c, names = names, pl = {}, key = "logo" } end
            end
            for _, pl in ipairs(c.near_logo and {} or c.places or { { 0.02, 0 } }) do
                local key = string.format("%s:%.3f:%.3f", c.anchor or "bottom-right", pl[1], pl[2])
                if not busy_places[key] then options[#options + 1] = { c = c, names = names, pl = pl, key = key } end
            end
        end
    end
    if #options == 0 then return nil end
    local o = options[math.random(#options)]
    local spr = M.sprites[o.names[math.random(#o.names)]] or M.sprites[o.names[1]]
    local anchor = o.c.anchor or "bottom-right"
    local fx = ANCHORS[anchor] or ANCHORS["bottom-right"]
    local x, y
    if o.c.near_logo then
        -- hang from the top edge around/over the logo (top corner), or in that quarter without one
        local pos = wm and wm.position or o.c.anchor or "top-right"
        if wm and pos:find("top") then
            local m = wm.margin * H
            local lx = pos:find("left") and m or (W - wm.w - m)
            x = lx + wm.w / 2 + rnd(-1, 1) * (wm.w / 2 + spr.w) - spr.w / 2
        else
            x = pos:find("left") and rnd(0, W * 0.25) or rnd(W * 0.75 - spr.w, W - spr.w)
        end
        x, y = clamp(x, 0, W - spr.w), 0
    else
        x, y = fx(spr, o.pl[1], o.pl[2])
    end
    local hx, hy = x, y
    if anchor:find("bottom") then hy = H + 2
    elseif o.c.from == "top" then hy = -spr.h - 2      -- lowered from above (hanging things)
    else
        hy = -spr.h - 2
        hx = anchor:find("left") and (-spr.w - 2) or (W + 2)
    end
    busy_places[o.key] = true
    local a = { el = el, spr = spr, key = o.key, mirror = o.pl[3] == true, phase = rnd(0, 6.28) }
    a.groups = groups_of(o.c)
    for _, g in ipairs(groups_of(el)) do a.groups[#a.groups + 1] = g end
    local tin, tout = el["in"] or 1.5, el.out or 1.5
    local stay = rnd(range(el.stay, 60))
    local tt = 0
    local function ease(p) return p * p * (3 - 2 * p) end
    function a.update(dt, t)
        tt = tt + dt
        local p
        if tt < tin then p = ease(tt / tin)
        elseif tt < tin + stay then p = 1
        elseif tt < tin + stay + tout then p = 1 - ease((tt - tin - stay) / tout)
        else busy_places[a.key] = nil return false end
        local frame = spr.fps > 0 and math.floor((t + a.phase) * spr.fps) or 0
        return true, hx + (x - hx) * p, hy + (y - hy) * p, frame, a.mirror
    end
    a.release = function() busy_places[a.key] = nil end
    a.leave = function()                 -- go back now (from where it is)
        if tt < tin then stay, tt = 0, tin + (1 - tt / tin) * tout
        elseif tt < tin + stay then stay = tt - tin end
    end
    return a
end

-- peeker: rises from an edge (or from behind a decor piece), lingers (waves/dances/talks), sinks back
function spawn.peeker(el, spr)
    local a = { el = el, spr = spr }
    local edge = el.edge or "bottom"
    local reveal = rnd(range(el.reveal, 0.8))
    local behind = nil
    local standing = standing_decor()
    if el.from == "decor" and #standing > 0 then behind = standing[math.random(#standing)] end

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
    a.line = pick_line(el)
    a.leave = function()                 -- back behind its edge now
        if a.t < a.tin then a.thold, a.t = 0, a.tin + (1 - a.t / a.tin) * a.tout
        elseif a.t < a.tin + a.thold then a.thold = a.t - a.tin end
    end

    local function ease(p) return p * p * (3 - 2 * p) end
    function a.update(dt, t)
        a.t = a.t + dt
        local p
        if a.t < a.tin then p = ease(a.t / a.tin)
        elseif a.t < a.tin + a.thold then p = 1
        elseif a.t < a.tin + a.thold + a.tout then p = 1 - ease((a.t - a.tin - a.thold) / a.tout)
        else return false end
        a.talking = a.line and p == 1
        if a.talking and not a.say_t then a.say_t = t end
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
        return true, x, y, math.floor(t * math.max(spr.fps, 1)), mirror
    end
    return a
end

-- ── leaving ───────────────────────────────────────────────────────────────────
-- An actor that has to go (its element is off now, another screen shows it, a grave) leaves the
-- way it fits instead of vanishing: its own a.leave (flyers climb away, a spider climbs its
-- thread, visitors and peekers go back) or else it stands still and sinks into the ground (in
-- the lower half of the screen) or rises out of sight (upper half).
local function leave(a, how)
    if a.leaving then return end
    a.leaving = { t = 0, dir = how == "grave" and 1 or nil }
    if a.leave and how ~= "grave" then a.leave() else a.leaving.generic = true end
end

-- the generic way out, applied to what a.update returned (one sprite, or layers)
local function leaving_step(a, dt, x, y)
    local L = a.leaving
    L.t = L.t + dt
    local x0, top, bot
    if a.ids then
        for k = 1, #a.ids do
            local l = x[k]
            if l then
                x0 = x0 or l.x
                top = math.min(top or l.y, l.y)
                bot = math.max(bot or (l.y + l.spr.h), l.y + l.spr.h)
            end
        end
    else
        x0, top, bot = x, y, y + a.spr.h
    end
    if not x0 then return false end
    if not L.dir then L.dir = ((top + bot) / 2 > H / 2) and 1 or -1 end
    L.x0 = L.x0 or x0
    L.dy = (L.dy or 0) + L.dir * H * (0.05 + 0.25 * L.t) * dt     -- slowly, then faster
    if (L.dir > 0 and top + L.dy > H) or (L.dir < 0 and bot + L.dy < 0) then return false end
    local dx = L.x0 - x0                                           -- standing still
    if a.ids then
        local out = {}
        for k = 1, #a.ids do
            local l = x[k]
            if l then
                out[k] = { spr = l.spr, frame = l.frame, variant = l.variant, x = l.x + dx, y = l.y + L.dy }
            end
        end
        return true, out
    end
    return true, x + dx, y + L.dy
end

-- tombstones: a creep walking past one now and then drops into the grave (once per tombstone)
local GRAVE_TYPES = { walker = true, crawler = true, performer = true }
local function grave_check(a, x, y)
    if a.leaving or not GRAVE_TYPES[a.el.type] or a.el.graves == false or a.ids then return end
    local cx, bot = x + a.spr.w / 2, y + a.spr.h
    if bot < H * 0.97 then return end
    for _, d in ipairs(decor) do
        if not d.leaving and not d.anim and (d.spr.name or ""):find("tombstone")
                and cx > d.x + d.spr.w * 0.25 and cx < d.x + d.spr.w * 0.75 then
            a.graves = a.graves or {}
            if not a.graves[d] then
                a.graves[d] = true
                if math.random() < (a.el.grave_chance or 0.35) then
                    msg.verbose("grave: " .. tostring(a.spr.name) .. " drops in")
                    leave(a, "grave")
                end
            end
        end
    end
end

local function try_spawn(el, now)
    if holding() then return end        -- (the first-spawn timers start once the room is heard)
    local st = elements[el]
    if not st then
        -- first spawn soon after load (or after el.delay), slightly staggered
        st = { next = now + (el.delay and rnd(range(el.delay)) or rnd(1, 4)), active = 0 }
        elements[el] = st
    end
    if el.type == "particles" then
        local want = math.floor(scaled(el, el.count, 5) + 0.5)
        if mode == "video" and level() < PRIME then want = math.ceil(want * (el.video_share or 0.4)) end
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
    if group_busy(groups_of(el)) then
        st.next = now + rnd(2, 6)
        return
    end
    local unique = el.room_unique ~= false and not NOT_UNIQUE[el.type]
    local spr = el.cast and {} or (unique and free_sprite_of(el) or sprite_of(el))   -- visitors pick their own sprite
    if not spr then st.next = now + rnd(5, 15) return end
    if not spawn[el.type] then return end
    local a = spawn[el.type](el, spr)
    if a and unique and a.spr and taken(a.spr) then
        if a.release then a.release() end
        a = nil                         -- another screen in the room shows it now
    end
    if not a or #free_ids < (a.layers or 1) then st.next = now + 5 return end
    a.unique, a.born = unique, now
    if unique then room.claim_t = 0 end    -- claim it right away: less chance of a twin elsewhere
    a.groups = a.groups or groups_of(el)
    a.id = take_id(); st.active = st.active + 1
    if a.layers then
        -- several sprites, drawn bottom to top in id order
        a.ids = { a.id }
        for k = 2, a.layers do a.ids[k] = take_id() end
        table.sort(a.ids)
    end
    actors[#actors + 1] = a
    local lo, hi = range(el.every, 30)
    -- higher level → shorter pauses (down to a third at the element's full level)
    local f = 1 - 0.66 * growth(el)
    st.next = now + rnd(lo, hi) * f
end

-- ── orb weavers (weaver.lua): webs built over minutes, kept across refreshes ──

local function load_module(name)
    local dir = (debug.getinfo(1, "S").source or ""):match("^@(.*)/[^/]*$") or "."
    local ok, mod = pcall(dofile, dir .. "/" .. name)
    if ok then return mod end
    msg.error(name .. ": " .. tostring(mod))
end
local weaver = load_module("weaver.lua")
local web_next = {}  -- element name -> time the next web may start

local function tick_webs(dt, now)
    if not weaver then return end
    local on = {}
    for _, el in ipairs(M.elements) do
        if el.type == "weaver" and element_on(el) then on[el.name or "weaver"] = el end
    end
    local keep, count = {}, {}
    for _, w in ipairs(webs) do
        local el = on[w.name]
        if el and w.W == W and w.H == H and w:update(dt * (preview.fast and 8 or 1)) then
            keep[#keep + 1] = w
            count[w.name] = (count[w.name] or 0) + 1
        elseif el then
            web_next[w.name] = now + rnd(range(el.every, 120))
        end
    end
    webs = keep
    for name, el in pairs(on) do
        web_next[name] = web_next[name] or now + rnd(range(el.delay, 3))
        local want = math.floor(scaled(el, el.max_active, 1) + 0.5)
        if group_busy(groups_of(el)) then
            if now >= web_next[name] then web_next[name] = now + rnd(5, 15) end
        elseif (count[name] or 0) < want and now >= web_next[name] then
            local used, free = {}, {}
            for _, w in ipairs(webs) do used[w.corner] = true end
            if wm and wm.position then used[wm.position] = true end   -- keep the logo corner clear
            for _, c in ipairs(el.corners or { "top-left", "top-right" }) do
                if not used[c] then free[#free + 1] = c end
            end
            if #free > 0 then
                webs[#webs + 1] = weaver.new({ name = name, W = W, H = H, corner = free[math.random(#free)],
                    speed = el.speed, size = el.size, stay = rnd(range(el.stay, 900)) })
                webs[#webs].groups = groups_of(el)
            end
            web_next[name] = now + rnd(range(el.every, 120))
        end
    end
end

-- ── prowlers (prowler.lua): a cat strolling along the bottom edge ────────────

local prowler = load_module("prowler.lua")
local cats = {}
local cat_next = {}  -- element name -> time the next cat may come

-- things standing on the bottom edge (decor and visitors): the cat doesn't stop behind them,
-- and sharpens its claws on the pumpkins
local function bottom_things()
    local list = {}
    local function add(spr, x, y, mirror)
        if spr and y + spr.h >= H - 2 then
            list[#list + 1] = { x1 = x + spr.w * 0.1, x2 = x + spr.w * 0.9,
                                pumpkin = (spr.name or ""):find("pumpkin") ~= nil,
                                -- solid things: the cat climbs onto them (top edge per column)
                                x = x, y = y, w = spr.w, h = spr.h, profile = spr.profile, mirror = mirror }
        end
    end
    for _, d in ipairs(standing_decor()) do add(d.spr, d.x, d.y + (d.dy or 0), d.mirror) end
    for _, a in ipairs(actors) do
        if a.el.type == "visitor" and a.sx then add(a.spr, a.sx, a.sy, a.mirror) end
        if a.solid then add(a.solid.spr, a.solid.x, a.solid.y, a.solid.variant == true) end
    end
    return list
end

local function tick_cats(dt, now)
    if not prowler then return end
    local on = {}
    for _, el in ipairs(M.elements) do
        if el.type == "prowler" and element_on(el) then on[el.name or "prowler"] = el end
    end
    local keep, count = {}, {}
    for _, c in ipairs(cats) do
        local el = on[c.name]
        if el and c.W == W and c.H == H and c:update(dt) then
            keep[#keep + 1] = c
            count[c.name] = (count[c.name] or 0) + 1
        elseif el then
            cat_next[c.name] = now + rnd(range(el.every, 300)) * (1 - 0.66 * growth(el))
        end
    end
    cats = keep
    for name, el in pairs(on) do
        cat_next[name] = cat_next[name] or now + rnd(range(el.delay, 10))
        if (count[name] or 0) < 1 and now >= cat_next[name] and not holding() and not room.taken["spr:cat"] then
            local c = prowler.new({ W = W, H = H, size = el.size, obstacles = bottom_things })
            c.name = name
            cats[#cats + 1] = c
            room.claim_t = 0
            cat_next[name] = math.huge
        end
    end
end

-- ── ASS layer: spider threads, speech bubbles, banner jokes ─────────────────

-- Level 9: every sprite of the theme in a grid, animating through all its frames, with names.
demo = {}
local function build_demo()
    local names = {}
    for name in pairs(M.sprites) do names[#names + 1] = name end
    table.sort(names)
    local n = #names
    if n == 0 then return end
    local cols = math.max(1, math.ceil(math.sqrt(n * W / H)))
    local rows = math.ceil(n / cols)
    local cw, ch = W / cols, H / rows
    for k, name in ipairs(names) do
        local spr = M.sprites[name]
        local c, r = (k - 1) % cols, math.floor((k - 1) / cols)
        demo[#demo + 1] = {
            id = ACTOR_IDS.first + k - 1, spr = spr, name = name,
            x = c * cw + (cw - spr.w) / 2, y = r * ch + (ch * 0.85 - spr.h) / 2,
            lx = c * cw + cw / 2, ly = r * ch + ch * 0.92,
        }
    end
end

local function tick_demo(t)
    for _, d in ipairs(demo) do
        local spr = d.spr
        local fps = spr.fps > 0 and spr.fps or 8
        if spr.clips then for _, c in pairs(spr.clips) do fps = c.fps break end end
        draw(d.id, spr, math.floor(t * fps) % spr.frames, false, d.x, d.y)
    end
end

local function wrap(text, n)
    local lines, cur = {}, ""
    for word in text:gmatch("%S+") do
        if cur ~= "" and #cur + 1 + #word > n then lines[#lines + 1] = cur; cur = word
        else cur = (cur == "") and word or (cur .. " " .. word) end
    end
    if cur ~= "" then lines[#lines + 1] = cur end
    return lines
end

-- Speech balloon above (cx, tip_y): rounded box with a tail, outline and text in one ASS event pair.
local function balloon(out, cx, tip_y, text)
    local fs = math.floor(H * 0.03)
    local lines = wrap(text, 22)
    local longest = 0
    for _, l in ipairs(lines) do longest = math.max(longest, #l) end
    local pad, r, tail = fs * 0.7, fs * 0.8, fs * 1.1
    local bw = longest * fs * 0.56 + 2 * pad
    local bh = #lines * fs * 1.2 + 2 * pad
    local x1 = clamp(cx - bw / 2, 8, W - bw - 8)
    local y1 = math.max(8, tip_y - tail - bh)
    local x2, y2 = x1 + bw, y1 + bh
    local tx = clamp(cx, x1 + r + fs, x2 - r - fs)          -- where the tail leaves the box
    local k = r * 0.45                                       -- bezier handle for the corners
    local path = string.format(
        "m %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d " ..
        "l %d %d l %d %d l %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d",
        x1 + r, y1, x2 - r, y1, x2 - k, y1, x2, y1 + k, x2, y1 + r,
        x2, y2 - r, x2, y2 - k, x2 - k, y2, x2 - r, y2,
        tx + fs * 0.5, y2, cx, math.min(tip_y, y2 + tail), tx - fs * 0.5, y2,
        x1 + r, y2, x1 + k, y2, x1, y2 - k, x1, y2 - r,
        x1, y1 + r, x1, y1 + k, x1 + k, y1, x1 + r, y1)
    out[#out + 1] = string.format("{\\an7\\pos(0,0)\\bord%d\\shad0\\1c&HFFFFFF&\\3c&H202020&\\p1}%s{\\p0}",
        math.max(2, math.floor(fs * 0.12)), path)
    for i = 1, #lines do lines[i] = ass_escape(lines[i]) end
    out[#out + 1] = string.format("{\\an5\\pos(%d,%d)\\fs%d\\b1\\bord0\\shad0\\1c&H202020&\\fnDejaVu Sans}%s",
        (x1 + x2) / 2, (y1 + y2) / 2, fs, table.concat(lines, "\\N"))
end

local function render_ass(now)
    local out = {}
    local t = now - t0
    local said = false
    if level() < DEMO then
        for _, w in ipairs(webs) do w:render(now, out, DRAW_HZ) end
        for _, c in ipairs(cats) do c:render(now, out, DRAW_HZ) end
    end
    for _, d in ipairs(demo) do
        out[#out + 1] = string.format("{\\an5\\pos(%d,%d)\\fs%d\\bord2\\shad0\\1c&HFFFFFF&\\3c&H202020&\\fnDejaVu Sans}%s",
            d.lx, d.ly, math.floor(H * 0.022), ass_escape(d.name))
    end
    for _, a in ipairs(actors) do
        if a.thread and a.sx then
            local tx, ty = a.sx + a.spr.w / 2, a.sy
            out[#out + 1] = string.format(
                "{\\an7\\pos(0,0)\\bord0\\shad0\\1c&HDDDDDD&\\1a&H60&\\p1}m %d 0 l %d 0 l %d %d l %d %d{\\p0}",
                tx - 1, tx + 1, tx + 1, ty + 4, tx - 1, ty + 4)
        end
        if a.talking and a.line and a.sx and text_on() and not said then
            said = true  -- one balloon at a time keeps it readable
            local text = a.line.text
            if a.line.punch and a.say_t and t - a.say_t > (a.el.punchline or 3.5) then text = a.line.punch end
            balloon(out, a.sx + a.spr.w * 0.5, a.sy + a.spr.h * (a.el.say_y or 0.05), text)
        end
    end
    local data = table.concat(out, "\n")
    if OX ~= 0 or OY ~= 0 then  -- every event is placed with \pos: shift them into the visible area
        data = data:gsub("\\pos%((%-?[%d.]+),(%-?[%d.]+)%)", function(x, y)
            return string.format("\\pos(%s,%s)", tonumber(x) + OX, tonumber(y) + OY)
        end)
    end
    if data == ass.data and ass.res_x == FW and ass.res_y == FH then return end  -- unchanged: skip OSD redraw
    ass.res_x, ass.res_y, ass.z = FW, FH, 5
    ass.data = data
    ass:update()
end

-- ── main loop ───────────────────────────────────────────────────────────────

local last = mp.get_time()

local function tick()
    local now = mp.get_time()
    local dt = math.min(0.2, now - last)
    last = now
    local t = now - t0
    if not M or mode == "hidden" then
        if room.active and mine_sent ~= "" then     -- nothing on screen: nothing claimed
            mine_sent = ""
            room_send("theme-room-claims-out", { claims = {} })
        end
        return
    end

    if level() >= DEMO then
        tick_demo(t)
        render_ass(now)
        return
    end
    tick_decor(t, dt)
    tick_webs(dt, now)
    tick_cats(dt, now)

    for _, el in ipairs(M.elements) do
        if el.type ~= "decor" and spawn[el.type] and element_on(el) then try_spawn(el, now) end
    end
    -- actors coming over from a neighbour
    local wait = {}
    for _, w in ipairs(handed_in) do
        if now - w.at > 2 then          -- stale (hidden meanwhile)
        else
            local h = w.h
            h.late = (tonumber(h.late) or 0) + (now - w.at)
            local el = M.elements[h.el or 0]
            local spr = M.sprites[h.sprite or ""]
            if el and spr and spawn[h.kind] and el.type == h.kind and #free_ids > 0 then
                local a = spawn[h.kind](el, spr, h)
                if a then
                    a.uncounted, a.handed = true, true
                    a.groups = groups_of(el)
                    a.id = take_id()
                    actors[#actors + 1] = a
                end
            end
        end
    end
    handed_in = wait

    local keep = {}
    for _, a in ipairs(actors) do
        local alive, x, y, frame, mirror = a.update(dt, t)
        if alive and not a.leaving then
            if not a.handed and not element_on(a.el) then leave(a) else grave_check(a, x, y) end
        end
        if alive and a.leaving and a.leaving.generic then alive, x, y = leaving_step(a, dt, x, y) end
        if alive then
            -- every overlay-add costs an OSD redraw, so slow actors (particles) redraw less often
            local hz = a.el.hz or (a.el.type == "particles" and 12 or DRAW_HZ)
            if not a.next_draw or now >= a.next_draw then
                a.next_draw = (a.next_draw or now + rnd(0, 1 / hz)) + 1 / hz
                if a.next_draw < now then a.next_draw = now + 1 / hz end
                if a.ids then   -- x = the layers
                    for k, id in ipairs(a.ids) do
                        local l = x[k]
                        if l then draw(id, l.spr, l.frame, l.variant, l.x, l.y) else hide(id) end
                    end
                else
                    draw(a.id, a.spr, frame, mirror, x, y)
                    a.sx, a.sy = x, y
                end
            end
            keep[#keep + 1] = a
        else
            if a.release then a.release() end
            for _, id in ipairs(a.ids or { a.id }) do give_id(id) end
            local st = elements[a.el]
            if st and not a.uncounted then st.active = st.active - 1 end
        end
    end
    actors = keep

    -- tell the room what this screen shows (the player passes it on when it changed)
    if room.active then
        room.claim_t = (room.claim_t or 0) - dt
        if room.claim_t <= 0 then
            room.claim_t = 1
            local set, keys = {}, {}
            for _, d in ipairs(standing_decor()) do set[claim_key(d.spr)] = true end
            for _, a in ipairs(actors) do if a.unique and a.spr then set[claim_key(a.spr)] = true end end
            if #cats > 0 then set["spr:cat"] = true end
            for k in pairs(set) do keys[#keys + 1] = k end
            table.sort(keys)
            local sig = table.concat(keys, ",")
            if sig ~= mine_sent then
                mine_sent = sig
                room_send("theme-room-claims-out", { claims = keys })
            end
        end
    end

    render_ass(now)
end

local function clear_actors()
    for _, a in ipairs(actors) do for _, id in ipairs(a.ids or { a.id }) do hide(id) end end
    for _, d in ipairs(demo) do hide(d.id) end
    actors, demo = {}, {}
    busy_places = {}
    elements = {}
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
    if w > 0 and h > 0 then
        FW, FH = w, h
        local l, t, r, b = overscan[1], overscan[2], overscan[3], overscan[4]
        OX, OY = math.floor(w * l + 0.5), math.floor(h * t + 0.5)
        W, H = w - OX - math.floor(w * r + 0.5), h - OY - math.floor(h * b + 0.5)
    end
end

-- Subtitles are always drawn below overlay-add bitmaps (mpv's fixed order), so while a video
-- plays with decorations standing on the bottom edge, lift the subtitles just above them.
-- Only static decorations count (decor, visitors, the cat's lane), so the subtitles don't jump around.
local sub_pos0 = mp.get_property_number("sub-pos", 100)
local function update_sub_pos()
    local lift = 0
    if M and mode == "video" and level() < DEMO and H > 0 then
        for _, d in ipairs(standing_decor()) do
            if d.el.lift_subs ~= false and d.y + d.spr.h > H * 0.8 then lift = math.max(lift, H - d.y) end
        end
        -- visitors come and go; reserve their room for as long as the element is on
        for _, el in ipairs(M.elements or {}) do
            if el.type == "prowler" and element_on(el) and el.lift_subs ~= false then
                lift = math.max(lift, H * 0.125 * (el.size or 1))
            end
            if el.type == "visitor" and element_on(el) and el.lift_subs ~= false then
                for _, c in ipairs(el.cast or {}) do
                    for _, name in ipairs(c.sprites or { c.sprite }) do
                        local spr = M.sprites[name]
                        if spr and (c.anchor or "bottom-right"):find("bottom") and c.lift_subs ~= false then
                            for _, pl in ipairs(c.places or { { 0, 0 } }) do
                                lift = math.max(lift, spr.h + (pl[2] or 0) * H)
                            end
                        end
                    end
                end
            end
        end
    end
    local cut = FH - OY - H     -- TV overscan at the bottom
    local pos = sub_pos0
    if lift > 0 or cut > 0 then pos = math.max(50, sub_pos0 - (lift + cut) / math.max(FH, 1) * 100 - (lift > 0 and 1 or 0)) end
    if mp.get_property_number("sub-pos", 100) ~= pos then mp.set_property_number("sub-pos", pos) end
end

local function refresh()
    update_dims()
    clear_actors()
    build_decor()
    if M and mode ~= "hidden" and level() >= DEMO then build_demo() end
    update_sub_pos()
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

-- idle <-> video: nothing is wiped; what may not show now leaves (see leave), decor that changes
-- sinks and rises
local function soft_refresh()
    if not M or level() >= DEMO then return refresh() end
    build_decor(true)
    update_sub_pos()
    draw_watermark()
    -- over a video, flyers keep to the top strip below the full level: the others climb away
    if mode == "video" and level() < PRIME then
        for _, a in ipairs(actors) do if a.el.type == "flyer" then leave(a) end end
    end
end

local function set_mode(new)
    local old = mode
    mode = new
    if old == "hidden" or new == "hidden" then refresh() else soft_refresh() end
end

mp.register_script_message("theme-load", function(path)
    local f = io.open(path, "r")
    if not f then msg.error("theme-load: cannot open " .. tostring(path)) return end
    local data = utils.parse_json(f:read("*a"))
    f:close()
    if not data then msg.error("theme-load: bad json " .. path) return end
    for name, s in pairs(data.sprites or {}) do
        s.name = name
        s.fps = s.fps or 0
        s.spin = s.spin or 0
    end
    M = data
    for i, el in ipairs(M.elements or {}) do el.index = i end   -- the same on every screen: hand-overs name it
    msg.info(string.format("theme %s level %d, %d elements", M.theme, M.level or 0, #(M.elements or {})))
    refresh()
end)

-- theme-overscan <json>: a number (all sides) or [left, top, right, bottom], fractions of the
-- screen a TV cuts off; everything moves into the part that is left
mp.register_script_message("theme-overscan", function(js)
    local v = (js and js ~= "") and utils.parse_json(js) or 0
    if type(v) == "number" then v = { v, v, v, v } end
    if type(v) ~= "table" then v = {} end
    local o = {}
    for k = 1, 4 do o[k] = clamp(tonumber(v[k]) or 0, 0, 0.2) end
    overscan = o
    refresh()
end)

-- theme-room <json>: {"left": bool, "right": bool, "gap": s} — are there screens beside this one
mp.register_script_message("theme-room", function(js)
    local v = js and js ~= "" and utils.parse_json(js) or {}
    room.active = v.active ~= false
    room.left, room.right = v.left == true, v.right == true
    room.gap_px = tonumber(v.gap_px) or 0
    room.ready = v.ready ~= false
    room.gap = room.gap_px * H / 1080
    msg.verbose(string.format("room: left %s, right %s, gap %d px", tostring(room.left), tostring(room.right), room.gap_px))
end)

-- theme-room-claims <json>: {"ready": bool, "taken": [keys]} — what other screens in the room show
-- (for keys we show too: they had it first, give it up)
mp.register_script_message("theme-room-claims", function(js)
    local v = js and utils.parse_json(js)
    if type(v) ~= "table" then return end
    local was_holding = holding()
    room.taken = {}
    for _, k in ipairs(v.taken or {}) do room.taken[k] = true end
    room.ready = v.ready ~= false
    local lost = false
    for _, d in ipairs(standing_decor()) do if room.taken[claim_key(d.spr)] then lost = true end end
    -- an actor that started at the same moment as the same one on another screen: it goes again
    for _, a in ipairs(actors) do
        if a.unique and a.spr and room.taken[claim_key(a.spr)] and not a.leaving then
            leave(a)
            msg.verbose("room: " .. tostring(a.spr.name) .. " is on another screen, leaving")
        end
    end
    if was_holding and not holding() then
        msg.verbose("room: heard the room, starting")
        build_decor()
        update_sub_pos()
    elseif lost then
        msg.verbose("room: another screen shows our decor, picking again")
        build_decor(true)
        update_sub_pos()
    end
end)

-- theme-room-in <json>: an actor a neighbour handed over; it comes in from that neighbour's side
-- after the gap
mp.register_script_message("theme-room-in", function(js)
    local h = js and utils.parse_json(js)
    if not h or not M or mode == "hidden" then return end
    handed_in[#handed_in + 1] = { at = mp.get_time(), h = h }
end)

mp.register_script_message("theme-off", function()
    M = nil
    webs, web_next = {}, {}
    cats, cat_next = {}, {}
    refresh()
end)

mp.register_script_message("theme-mode", function(m)
    real_mode = m
    local new = (m ~= "hidden" and preview.mode) or m
    if new == mode then return end
    set_mode(new)
end)

-- Preview keys (only reach mpv where keyboard input is enabled, i.e. test setups):
--   1..9 = level (9 = demo grid), 0 = back to the calendar, v = idle/video, t = speech balloons,
--   f = web building ×8, w = start a new web, c = send a cat now, d = the vampire next
local LEVEL_NAMES = { "now and then one decoration", "mostly one decoration, sometimes two",
    "a few decorations, a rare creepy-crawly", "decorations, some movement", "busier, crawling spiders",
    "busy, bats and ghosts", "nearly there (the day before)", "full blown (the day itself)", "demo: all artwork" }
local function preview_osd()
    local lv = level()
    mp.osd_message(string.format("Theme level %d%s: %s · %s · balloons %s", lv,
        preview.level and "" or " (calendar)", LEVEL_NAMES[lv] or "off", mode, text_on() and "on" or "off"), 3)
end
for k = 1, 9 do
    mp.add_forced_key_binding(tostring(k), "theme-preview-" .. k, function()
        preview.level = k
        refresh(); preview_osd()
    end)
end
mp.add_forced_key_binding("0", "theme-preview-auto", function()
    preview.level, preview.text, preview.mode = nil, nil, nil
    mode = real_mode
    refresh(); preview_osd()
end)
mp.add_forced_key_binding("v", "theme-preview-mode", function()
    preview.mode = (mode == "video") and "idle" or "video"
    set_mode(preview.mode)
    preview_osd()
end)
mp.add_forced_key_binding("f", "theme-preview-fast", function()
    preview.fast = not preview.fast
    mp.osd_message("Web building " .. (preview.fast and "×8" or "normal speed"), 2)
end)
mp.add_forced_key_binding("w", "theme-preview-web", function()
    webs, web_next = {}, {}   -- start over with a fresh web
end)
mp.add_forced_key_binding("c", "theme-preview-cat", function()
    cats = {}
    for name in pairs(cat_next) do cat_next[name] = 0 end
end)
mp.add_forced_key_binding("d", "theme-preview-vampire", function()
    for _, el in ipairs(M and M.elements or {}) do
        if el.type == "vampire" and elements[el] then elements[el].next = 0 end
    end
end)
mp.add_forced_key_binding("b", "theme-preview-flyer", function()
    local fl = {}
    for _, el in ipairs(M and M.elements or {}) do
        if el.type == "flyer" and element_on(el) then fl[#fl + 1] = el end
    end
    if #fl > 0 then
        local el = fl[math.random(#fl)]
        elements[el] = elements[el] or { active = 0 }
        elements[el].next = 0
    end
end)
mp.add_forced_key_binding("t", "theme-preview-text", function()
    preview.text = not text_on()
    preview_osd()
end)

mp.register_script_message("watermark", function(js)
    hide(WM_ID)
    wm = (js and js ~= "") and utils.parse_json(js) or nil
    draw_watermark()
end)

-- the sprites are made for one screen height: on a new size ask the player for new ones (once
-- the resizing settles)
local resize_timer
mp.observe_property("osd-dimensions", "native", function()
    local ow, oh = W, H
    update_dims()
    if W ~= ow or H ~= oh then
        refresh()
        if resize_timer then resize_timer:kill() end
        resize_timer = mp.add_timeout(0.7, function()
            resize_timer = nil
            if M then mp.commandv("script-message", "theme-resized", tostring(FW) .. "x" .. tostring(FH)) end
        end)
    end
end)

reset_ids()
