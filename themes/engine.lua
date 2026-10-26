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
local cats = {}          -- the cats (prowler.lua), see tick_cats
local webs = {}          -- orb weavers (weaver.lua): not cleared by refresh, a video starting must not wipe a half-built web
local elements = {}      -- element state (next spawn time, active count)
local plan = { queue = {}, recent = {}, noise = {}, fail = {} }   -- the gag planner (see plan_tick)
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
local room = { active = false, left = false, right = false, gap = 0, ready = true, taken = {},
               wait = {}, here = {},    -- room groups: wait till (s), going on here
               screens = 1, chars = 0, near = {} }   -- characters on the other screens, next door
local handed_in = {}       -- handed-over actors, spawned on the next tick
local mine_sent = nil      -- the claims last told to the player
local NOT_UNIQUE = { flyer = true, particles = true }   -- travel from screen to screen / just leaves

local function claim_key(spr) return "spr:" .. tostring(spr and spr.name) end
-- groups that are one at a time in the whole room, not just on a screen (claimed as "grp:<name>")
local ROOM_GROUPS = { flying = true }
local function taken(spr) return room.taken[claim_key(spr)] == true end
local function holding() return room.active and not room.ready end

-- a sprite of the element that no other screen shows, nor this one (one come over from next
-- door); nil when all are
local function free_sprite_of(el)
    local here = {}
    for _, a in ipairs(actors) do if a.spr and not a.leaving then here[a.spr] = true end end
    for _ = 1, 8 do
        local spr = sprite_of(el)
        if not spr or not (taken(spr) or here[spr]) then return spr end
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

-- Walkers across screens: one walking off towards a neighbour goes on there (up to MAX_HOPS
-- screens). Handed over when its front reaches our edge; the neighbour starts it with its front
-- that far in (minus the gap, plus what it walked meanwhile). x: its middle (screen), front: from
-- the middle to its front. h: what it takes along (kind defaults to the element's type).
local MAX_HOPS = 3
local FLY_HOPS = 3        -- (screens may go all round the room: no flying round for ever)
local HANDED_ONLY = { piece = true, passer = true, hopper = true, wanderer = true, carriage = true, bird = true, bat = true }    -- kinds that only come in from a neighbour
local function with_guest(a)          -- a zombie's guest, or the zombie while its guest is about
    if a.guest_of then return true end
    for _, b in ipairs(actors) do if b.guest_of == a and not b.leaving then return true end end
    return false
end
-- two characters on the screen next door already (they meet): a walker doesn't come over too
local function full_next_door(a, side)
    if HANDED_ONLY[a.el.type] then return false end
    for _, g in ipairs(a.groups or {}) do
        if g == "walker" then return #(room.near[side] or {}) >= 2 end
    end
    return false
end
local function walk_out(a, x, dir, front, h)
    if a.handed_on then return a.handed_on == "yes" end
    local lead = dir > 0 and (x + front - W) or (front - x)
    if lead < 0 then return false end
    a.handed_on = "no"
    if (a.hops or 0) >= (a.el.max_hops or MAX_HOPS) or with_guest(a) or full_next_door(a, dir > 0 and "right" or "left") then return false end
    h = h or {}
    h.kind, h.el, h.dir, h.hops, h.lead = h.kind or a.el.type, a.el.index, dir, h.hops or (a.hops or 0) + 1, lead / H
    h.sprite = h.sprite or a.spr.name
    if h.unique == nil then h.unique = a.unique end
    if hand_over(dir > 0 and "right" or "left", h) then
        a.handed_on = "yes"
        -- it's theirs now: no longer ours to claim, and not to be started here again meanwhile
        if a.unique and a.spr and h.unique then
            a.unique = false
            room.taken[claim_key(a.spr)] = true
            room.claim_t = 0
        end
    end
    return a.handed_on == "yes"
end
local function walk_in_x(h, v, front)
    if h.at then return tonumber(h.at) end      -- (one of the cast here, going on as itself: its middle)
    local late = clamp(tonumber(h.late) or 0, 0, 1)
    local f = (tonumber(h.lead) or 0) * H + v * late - room.gap    -- its front this far in
    return (h.dir or 1) > 0 and (f - front) or (W - f + front)
end
-- may one walking towards that side go on to a neighbour there
-- which way a walker crosses: at random; started by a preview key, towards a screen next door
-- Characters (the walkers: skeleton, zombie, vampire...) in a room of screens: at most a few at
-- once (room_max), no two of a kind (all the skeleton acts are "skeleton"), at most two on a
-- screen (meeting: see el.meets); stories go over to the screen next door instead.
local function has_group(groups, g)
    for _, x in ipairs(groups or {}) do if x == g then return true end end
    return false
end
local function family_of(el)
    return el.family or (el.type == "performer" and "skeleton") or el.type
end
local function is_character(a)            -- (a hidden vampire has no groups: asleep, not counted)
    if a.family then return true end                     -- (one of the cast, wandering about)
    if HANDED_ONLY[a.el.type] then return false end      -- (one on its way out still counts)
    for _, g in ipairs(a.groups or {}) do if g == "walker" then return true end end
    return false
end
local function actor_family(a) return a.family or family_of(a.el) end
local function cast_el()                   -- (the element the cast walks about for)
    for _, e in ipairs(M.elements) do if e.type == "frogs" then return e end end
end
local function cast_sprite(fam)            -- (the sprite of the element of fam, fit to wander)
    for _, e in ipairs(M.elements) do
        local sp = family_of(e) == fam and M.sprites[e.sprite or ""]
        if sp and sp.clips and sp.clips.walk and sp.clips.idle and sp.origin and sp.unit then return sp end
    end
end
-- screen real estate: where the others are (characters, scenes, a pile, a pot...) or will be
-- (a.spot: a scene's place, kept for it) - free_x: of a few places between lo and hi (screen x)
-- at random, the one furthest from them (so two don't do their thing on the same spot)
local function others_xs(me)
    local xs = {}
    for _, b in ipairs(actors) do
        if b ~= me and not b.gone and not b.leaving then
            if b.spot then xs[#xs + 1] = b.spot end
            if b.cx and (b.scene or b.pile or b.lying or b.pot or is_character(b)) then xs[#xs + 1] = b.cx end
        end
    end
    return xs
end
local function free_x(lo, hi, me)
    if hi < lo then lo, hi = hi, lo end
    local xs, best, bs = others_xs(me), nil, -1
    for _ = 1, 7 do
        local x = lo + math.random() * (hi - lo)
        local dmin = W
        for _, o in ipairs(xs) do dmin = math.min(dmin, math.abs(o - x)) end
        local sc = dmin * (0.8 + 0.4 * math.random())
        if sc > bs then best, bs = x, sc end
    end
    return best
end
local function free_scene_x(lo, hi, d, me)     -- the same for a scene planned mirrored (d < 0)
    if d > 0 then return free_x(lo, hi, me) end
    return W - free_x(W - hi, W - lo, me)
end
local function room_max()
    local n = room.screens or 1
    if not room.active or n <= 1 then return math.huge end
    return math.max(2, math.min(3, n - 1))    -- 4 screens: 3
end
-- one of the cast of fam (a family, "frog" a frog) about on this screen, free to be taken over
-- by a scene starting here (see el.recruits): its actor
local function cast_here(fam, skip)
    for _, a in ipairs(actors) do
        if fam == "frog" and a.pile and a.list then         -- (frogs sitting on the pile)
            for _, f in ipairs(a.list()) do if f ~= skip then return f end end
        end
        if a ~= skip and (a.family == fam or (fam == "frog" and a.frog)) and not a.scene and not a.gone and not a.leaving
                and not a.busy and a.cx and a.cx > 0.05 * W and a.cx < 0.95 * W then return a end
    end
end
-- the frogs about: here (hopping about, on the pile), each with a token the room hears of
-- ("frog:<token>" claims), and in the whole room (those on other screens too)
local function frogs_here(each)
    local n = 0
    for _, a in ipairs(actors) do
        if a.frog and not a.gone and not a.leaving then
            n = n + 1
            if each then each(a) end
        end
        if a.pile and a.list then
            for _, f in ipairs(a.list()) do
                n = n + 1
                if each then each(f) end
            end
        end
    end
    return n
end
local function room_frogs()
    local n = frogs_here()
    for k in pairs(room.taken) do if k:sub(1, 5) == "frog:" then n = n + 1 end end
    return n
end
local FEW_FROGS = 3                         -- (fewer about: the witch comes sooner, brews more frogs)
local function chars_here(fam, skip)       -- how many characters here (and whether one of fam)
    local n, same = 0, false
    for _, a in ipairs(actors) do
        if is_character(a) and not (skip and skip[a]) then
            n = n + 1
            if actor_family(a) == fam then same = true end
            for _, f in ipairs(a.also or {}) do       -- (someone it plays a scene with)
                n = n + 1
                if f == fam then same = true end
            end
        end
    end
    return n, same
end
-- no room for another character of el's kind (the room's full, one is about already, or two here)
local function no_room_for(el)
    if not room.active or (room.screens or 1) <= 1 then return false end
    local fam = family_of(el)
    local skip = {}                       -- (the cast it would take over don't count: they go)
    for _, f in ipairs(el.recruits or {}) do
        local c = cast_here(f)
        if c then skip[c] = true end
    end
    local here, same = chars_here(fam, skip)
    if same or room.taken["chr:" .. fam] or mp.get_time() < (room.wait.chr or 0) then return true end
    return here >= 2 or here + (room.chars or 0) >= room_max()
end

-- which way a walker crosses: at random; started by a preview key, towards a screen next door;
-- with someone about next door (and room there), mostly over to them: the story moves on
local function walk_dir(el)
    local st = elements[el]
    if st then st.seek = nil end
    if st and st.force and room.right ~= room.left then return room.right and 1 or -1 end
    local l, r = #(room.near.left or {}), #(room.near.right or {})
    if (l > 0) ~= (r > 0) and math.max(l, r) < 2 and math.random() < 0.7 then
        if st then st.seek = true end
        msg.verbose(tostring(el.type) .. ": over to the " .. (r > 0 and "right" or "left") .. ", someone's there")
        return r > 0 and 1 or -1
    end
    return math.random() < 0.5 and 1 or -1
end
local function can_walk_on(a, dir)
    local side = dir > 0 and "right" or "left"
    return room[side] and (a.hops or 0) < (a.el.max_hops or MAX_HOPS) and not with_guest(a) and not full_next_door(a, side)
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

-- decor that stands (not on its way out; maybe away for a while, see tick_decor)
local function standing_decor()
    local list = {}
    for _, d in ipairs(decor) do if not d.leaving then list[#list + 1] = d end end
    return list
end
-- decor that is there right now (not away either)
local function present_decor()
    local list = {}
    for _, d in ipairs(decor) do if not d.leaving and not d.away then list[#list + 1] = d end end
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
    for _, d in ipairs(decor) do if d.leaving or d.el.on_cue then used[d.id] = true end end
    for _, el in ipairs(M.elements) do
        if el.type == "decor" and not el.on_cue then
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

-- what's going on on the floor, for decor that makes way (el.aside): "scenes" - a big act with
-- its props (the witch's cauldron, the coffin, the sarcophagus, the frankenstein); "others" -
-- that, or anyone about who doesn't come out of a grave (the tombstone stays for skeletons and
-- zombies: theirs)
local GRAVE_FAMILIES = { skeleton = true, zombie = true }
local function floor_busy(aside)
    for _, a in ipairs(actors) do
        if a.scene then return true end
        if aside == "others" and (a.floor or (is_character(a) and not GRAVE_FAMILIES[actor_family(a)])) then
            return true
        end
    end
    return false
end

-- decor that comes and goes (el.duty = {on = [s, s], off = [s, s]}) or makes way (el.aside):
-- it sinks away for a while, and rises again a few seconds after the floor is free
local function decor_away(d, t)
    local el = d.el
    if el.on_cue and not d.leaving and t > d.till then       -- (popped up a while: down again)
        d.leaving = true
        decor_move(d, off_screen_dy(d.y, d.spr.h))
        return
    end
    if d.leaving or not (el.duty or el.aside) then return end
    if el.aside and floor_busy(el.aside) then d.busy_t = t end
    if el.duty then
        d.duty_t = d.duty_t or t + rnd(range(el.duty.on, 120))
        if t >= d.duty_t then
            d.off = not d.off
            d.duty_t = t + rnd(range(d.off and el.duty.off or el.duty.on, 60))
        end
    end
    local away = d.off or (d.busy_t ~= nil and t - d.busy_t < 4)
    if away ~= (d.away or false) and not d.anim then
        d.away = away
        decor_move(d, away and off_screen_dy(d.y, d.spr.h) or 0)
        msg.verbose(string.format("decor: %s %s%s", tostring(d.spr.name), away and "away" or "back",
            away and not d.off and " (making way)" or ""))
    end
end

local function tick_decor(t, dt)
    local keep = {}
    for _, d in ipairs(decor) do decor_away(d, t) end
    for _, d in ipairs(decor) do
        local gone = false
        if d.anim then
            local A = d.anim
            A.p = A.p + dt / DECOR_MOVE_S
            local p = clamp(A.p, 0, 1)
            -- sinking speeds up, rising slows down at the end
            local e = (d.leaving or d.away) and p * p or (1 - (1 - p) * (1 - p))
            d.dy = A.from + (A.to - A.from) * e
            if A.p >= 1 then
                d.anim = nil
                gone = d.leaving
            end
        end
        if gone then
            hide(d.id)
        elseif d.away and not d.anim then
            hide(d.id)
            keep[#keep + 1] = d
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

-- one not started by try_spawn (come over from next door, one of the cast going on as itself):
-- in among the actors, holding ids
local function adopt(a, el, h)
    a.uncounted, a.handed = true, true
    a.hops = tonumber(h.hops) or 1
    a.unique = h.unique == true       -- holds its claim here now (no twin elsewhere)
    room.claim_t = 0
    a.groups = a.groups or groups_of(el)
    a.id = take_id()
    if a.layers then
        a.ids = { a.id }
        for k = 2, a.layers do a.ids[k] = take_id() end
        table.sort(a.ids)
    end
    actors[#actors + 1] = a
end

local function group_busy(groups, el, me)
    if #groups == 0 then return false end
    local busy = {}
    for _, a in ipairs(actors) do
        if a ~= me and not (el and a.invites and a.invites[el]) then busy[#busy + 1] = a end   -- (the zombie's guests)
    end
    for _, w in ipairs(webs) do      -- a web counts while its spider builds it (once it sits
        if not w.sp.gone and not w.built then busy[#busy + 1] = w end   -- in it, others may come)
    end
    for _, a in ipairs(busy) do
        for _, g in ipairs(a.groups or {}) do
            for _, want in ipairs(groups) do if g == want then return true end end
        end
    end
    return false
end

-- another screen in the room has one of these room-wide groups going (someone walking about)
local function room_busy(groups)
    local now = mp.get_time()
    for _, g in ipairs(groups) do
        if ROOM_GROUPS[g] then
            if room.taken["grp:" .. g] or now < (room.wait[g] or 0) then return true end
            for _, a in ipairs(actors) do   -- ours, gone on to a screen next door: still about
                if a.handed_on == "yes" then
                    for _, ag in ipairs(a.groups or {}) do if ag == g then return true end end
                end
            end
        end
    end
    return false
end

-- the zombie and its neighbours: a zombie's x (screen) within dist of x, or nil
local hooks = { cats = function() return {} end }   -- (filled in where the cats live)

-- decor on a cue (el.on_cue = "grave": the tombstone): not standing about, it pops up now and then
-- (el.chance) where a zombie or a skeleton comes up out of the ground or goes into it - beside it
-- (x: its middle, side: -1 to the left), drawn over it; it stays a while (el.stay) and sinks again
hooks.grave_at = function(x, side)
    if not M or mode == "hidden" then return end
    for _, el in ipairs(M.elements) do
        local spr = el.on_cue == "grave" and element_on(el) and M.sprites[el.sprite or ""]
        if spr then
            if math.random() >= (el.chance or 0.4) then return end
            local used = {}
            for _, d in ipairs(decor) do
                if d.el == el and not d.leaving then return end            -- (one at a time)
                used[d.id] = true
            end
            local id
            for i = DECOR_IDS.last, DECOR_IDS.first, -1 do if not used[i] then id = i break end end
            if not id then return end
            local cx = clamp(x + (side or 1) * 0.55 * spr.w, spr.w / 2, W - spr.w / 2)
            local d = { id = id, spr = spr, el = el, x = cx - spr.w / 2, y = H - spr.h, mirror = math.random() < 0.5,
                        phase = 0, till = mp.get_time() + rnd(range(el.stay, 8)) }
            d.dy = off_screen_dy(d.y, spr.h)
            decor_move(d, 0)
            decor[#decor + 1] = d
            msg.verbose("decor: a tombstone pops up")
            return
        end
    end
end
local function zombie_near(x, dist)
    for _, a in ipairs(actors) do
        if a.zx and not a.leaving and math.abs(a.zx - x) < dist then return a.zx end
    end
end

-- the werewolf (as a wolf) ahead of a cat at x walking dir: his x, or nil (see prowler.lua standoff)
local function werewolf_near(x, dir)
    for _, a in ipairs(actors) do
        if a.wolf_x and not a.leaving and (a.wolf_x - x) * dir > 0 and math.abs(a.wolf_x - x) < 0.3 * H then
            return a.wolf_x
        end
    end
end

-- something frightful near x (a.fright = {x, r, till}: sparks, a bang): its x, or nil
local function fright_near(x)
    local now = mp.get_time()
    for _, a in ipairs(actors) do
        local f = a.fright
        if f and now < f.till and math.abs(f.x - x) < f.r then return f.x end
    end
end

-- walkers with their arms out push a coffin lying shut in their way (the vampire in it) a few
-- steps (push_budget), then stop by it and turn back (or so), from
-- the near side: true while pushing (and whether it hangs over an edge: then it has to go on
-- till it's off). reach = from their origin to their hands; v = walking speed.
local function push_coffins(x, dir, reach, v)
    for _, b in ipairs(actors) do
        local sp = b.span
        if sp and b.push and not b.leaving then
            local mid = (sp[1] + sp[2]) / 2
            local over = sp[1] < 0 or sp[2] > W
            if dir > 0 and x + reach > sp[1] and x < mid then b.push(x + reach - sp[1], v) return true, over end
            if dir < 0 and x - reach < sp[2] and x > mid then b.push(x - reach - sp[2], v) return true, over end
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
            a.handed_on = "no"
            if (a.hops or 0) < FLY_HOPS and hand_over(a.dir > 0 and "right" or "left", {
                kind = "flyer", el = el.index, sprite = spr.name, dir = a.dir, lead = lead / H, hops = (a.hops or 0) + 1,
                y0 = a.y0 / H, bend = a.bend / H, v = a.v / W, freq = a.freq, ph = t * a.freq + a.ph,
                rate = a.rate, dph = t * a.rate + a.dph }) then a.handed_on = "yes" end
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
    -- (el.clips: its own names for walk / idle / wave, e.g. the creep's {"walk": "crawl", "wave": "peek"})
    local CL, clips = el.clips or {}, {}
    for _, k in ipairs({ "walk", "idle", "wave" }) do clips[k] = spr.clips and spr.clips[CL[k] or k] end
    local walk = clips.walk
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
        local c = clips[a.clip]
        if a.clip == "walk" then
            if wander then steer(dt) end
            a.x = a.x + a.dx * a.v * dt
            a.y = a.y + a.dy * a.v * dt
            a.walk_left = a.walk_left - dt
            if a.walk_left <= 0 and onscreen() then
                if clips.wave and math.random() < (el.wave_chance or 0.4) then
                    start("wave", clips.wave.count / clips.wave.fps)
                elseif clips.idle then
                    start("idle", rnd(range(el.pause, 1.5)))
                end
                a.walk_left = rnd(range(el.walk, 3))
            end
            if a.x < -spr.w - 2 or a.x > W + 2 or a.y < -spr.h - 2 or a.y > H + 2 then return false end
        elseif a.tc >= a.dur then
            start("walk")
            c = clips.walk
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
function spawn.performer(el, spr, h)
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
    local forced = elements[el] and elements[el].force
    local enter = (h or forced and C.walk) and "walk" or pick(el.enter, { "rise", "walk" })
    local exit = pick(el.exit, { "sink", "walk" })
    if not enter or not exit then return nil end

    local standing = present_decor()
    local behind = (enter == "rise" and el.from_decor ~= false and #standing > 0 and math.random() < (el.from_decor or 0.5))
        and standing[math.random(#standing)] or nil
    local ground = H + spr.h * (el.sink or 0.0)  -- feet line (sprite bottom)
    if h then a.mirror = h.dir ~= 1 else a.mirror = walk_dir(el) < 0 end
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
    local front = spr.w * 0.3                -- (its middle is the sprite's)
    if h then a.x = walk_in_x(h, v, front) - spr.w / 2 end
    -- walking off towards a screen next door, half the time it goes on there
    local go_on = forced or (not h and elements[el] and elements[el].seek) or math.random() < (el.walk_on or 0.5)

    function a.update(dt, t)
        local s = steps[si]
        if not s then return false end
        if s.clip == "rise" and not behind and a.graved ~= si then
            a.graved = si
            hooks.grave_at(a.x + spr.w / 2, -dir)
        end
        tc = tc + dt
        local c = C[s.clip]
        local done
        if s.clip == "walk" then
            a.x = a.x + dir * v * dt
            if s.off then
                if go_on then walk_out(a, a.x + spr.w / 2, dir, front) end
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
-- Pushed off the screen in his coffin towards a screen next door, he comes in there (h.coffin):
-- the coffin slides in (the pusher follows), he stays in a while, gets out, looks around - where
-- is he? - and pushes it on.
function spawn.vampire(el, spr, h)
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
    local a = { el = el, spr = spr, layers = 3, brainy = true, scene = true }
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

    local cx = free_scene_x(math.max(W * 0.3, half + 2 * u), math.min(W * 0.7, W - half - 2 * u), d)
    a.spot = d > 0 and cx or W - cx               -- (its place: kept for it)
    local crack = math.min(3, open)
    local stay = rnd(range(el.stay, 40))
    local slide_v
    if h and h.coffin then
        -- in his coffin from next door: in scene space it comes in from the left, sliding on until
        -- its back end is in (by then whoever pushes it is here too)
        d = h.dir == 1 and 1 or -1
        slide_v = clamp(tonumber(h.v) or 0.05, 0.01, 0.5) * H
        local late = clamp(tonumber(h.late) or 0, 0, 1)
        cx = (tonumber(h.lead) or 0) * H + slide_v * late - room.gap - half
        X, Y = cx + rest, sink
        stay = clamp(tonumber(h.stay) or 20, 12, 90)
        add { hide = true, dur = math.max(0.1, (half * 2 - (cx + half)) / slide_v), slide = slide_v }
    else
    -- first a peek round the corner (once or twice): half his face in, a look, back out of sight
    for _ = 1, math.random(1, 2) do
        go(-0.2 * u, C.sneak and "sneak" or "walk")
        stop("idle", rnd(0.8, 1.6))
        go(-1.2 * u, "walk")
        stop("idle", rnd(1.2, 3))           -- (out of sight)
    end
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
    end
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
    if slide_v then
        -- where is this? a look round, both ways, a shrug
        turn(0)
        steps[#steps].lid, steps[#steps].dur, steps[#steps].log = { open, 0 }, 1.0, "vampire: where am I?"
        n = nil
        stop("idle", 1.0)
        turn(-1) turn(0)
        stop("idle", 0.6)
        turn(1) turn(0)
        stop(C.raise and "raise" or "idle", (not C.raise) and 1.2 or nil)
    end
    turn(1)
    if n then steps[n + 1].lid, steps[n + 1].dur = { open, 0 }, 1.0 end
    add { clip = "push", push = true }
    X = W + half
    stop("idle", rnd(1, 2))
    go(-1.5 * u, gait())

    -- play
    local si, tc = 1, 0
    local vx = -1.2 * u                -- his origin (scene space)
    local coffin                       -- coffin middle (scene space), nil until pulled in
    if slide_v then vx, coffin = cx + rest, cx end
    local lf = 0                       -- lid frame
    local shift = 0                    -- how far others pushed the coffin (with him in it), scene space
    a.line = pick_line(el)
    local function place(sp, x, frame, mirror, dy)
        local m = (mirror and true or false) ~= (d < 0)
        local ox = m and (sp.w - sp.origin[1]) or sp.origin[1]
        x = x + shift
        return { spr = sp, frame = frame, variant = m, x = ((d > 0) and x or (W - x)) - ox, y = H - sp.origin[2] + dy }
    end
    local function scr(x) return (d > 0) and (x + shift) or (W - x - shift) end
    function a.push(dx, v)                           -- (screen pixels) see push_coffins
        shift = shift + d * dx
        a.push_dir, a.push_v, a.push_t = dx > 0 and 1 or -1, v, mp.get_time()
    end
    local function stay_left()                       -- hidden in the coffin for this much longer
        local left = -tc
        for k = si, #steps do
            local q = steps[k]
            if not q.hide or q.wake then break end
            left = left + (q.dur or 0)
        end
        return left
    end

    function a.update(dt, t)
        local s = steps[si]
        if not s then return false end
        if s.hide and not a.hiding then   -- hidden in the coffin: the others may come by meanwhile
            a.hiding, a.groups = a.groups, {}
        end
        if si ~= a.logged then a.logged = si msg.verbose(s.log or ("vampire step " .. tostring(s.clip or "hidden"))) end
        if s.wake and a.hiding then
            local st = elements[el]
            local here = chars_here()
            if group_busy({ "walker" }, nil, a) or here + (room.chars or 0) >= room_max() then
                tc = 0 dt = 0                    -- someone else walks about: stay in (and next in turn)
                if st then st.wait_since, st.wait_seen = st.wait_since or mp.get_time(), mp.get_time() end
            else
                a.groups, a.hiding = a.hiding, nil
                if st then st.wait_since = nil end
            end
        end
        tc = tc + dt
        local c = s.clip and (s.lie and L[s.clip] or C[s.clip])
        local rate = s.rate or 1
        local done
        -- a zombie about: no standing around, and walking becomes running
        local scared = not s.hide and zombie_near(scr(vx), 4.5 * u)
        if scared and C.run and s.to and not s.carry and not s.lie then
            c, rate = C.run, 1.5
            if not a.ran then a.ran = true msg.verbose("vampire runs past the zombie") end
        end
        if scared and s.dur and not s.lid and not s.hide and not s.wake then tc = math.max(tc, s.dur) end
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
                done = vx + shift + hands > W + 2
            elseif (dir > 0 and vx >= s.to) or (dir < 0 and vx <= s.to) then
                vx, done = s.to, true
            end
            if s.carry or s.push then coffin = vx + hands + half end
        else
            done = tc >= (s.dur or c.count / c.fps)
        end
        if s.slide then shift = shift + s.slide * dt end
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
            a.cx = scr(vx)
        else
            a.cx = nil
        end
        -- shut in the coffin it may be pushed about (span: where it lies); pushed off the screen,
        -- he is gone with it
        a.span = nil
        if coffin and s.hide and lf == 0 then
            local m = scr(coffin)
            -- pushed over the edge towards a screen next door: he goes on there, coffin and all
            if a.push_t and mp.get_time() - a.push_t < 0.3 then
                walk_out(a, m, a.push_dir, half, { coffin = true, v = (a.push_v or 0.05 * H) / H, stay = stay_left() })
            end
            local off = m - half > W or m + half < 0
            if not off then a.coffin_seen = true end          -- (coming in from next door it starts outside)
            if off and a.coffin_seen then
                msg.verbose("vampire: pushed off in his coffin")
                return false
            end
            a.span = { m - half, m + half }
        end
        a.talking = a.line and s.act and true or false
        if a.talking and not a.say_t then a.say_t = t end
        if done then si, tc = si + 1, 0 end
        if s.push and done then coffin = nil end
        return true, layers
    end
    return a
end

-- mummy: an upright sarcophagus (tools/bake/sarcophagus.py) rises out of the ground, the lid
-- swings open, the mummy walks out, faces the viewer and loses all its bandages (they drop into a
-- heap at its feet). A bare skeleton (the helper) comes in, winds the bandages back on while the
-- mummy spins, they cheer, the helper goes off, the mummy goes back in, the lid shuts and the
-- sarcophagus sinks. Four sprites on four overlay ids, bottom to top: box, mummy, helper, lid
-- (shut, the lid hides the mummy). Planned coming out to the right, mirrored half the time.
-- Each step has a part for the mummy (a) and for the helper (b): a clip, walking to x (to),
-- for dur, mirrored (m); or hide. A step ends when both parts did; a missing part rests.
function spawn.mummy(el, spr, h)
    local S = M.sprites
    local helper, box, lid = S[el.helper or ""], S[el.box or ""], S[el.lid or ""]
    local C, B = spr.clips, helper and helper.clips
    if not (C and C.walk and C.unwrap and C.spin and C.shy and B and B.walk and B.wind
            and box and lid and spr.origin and helper.origin and box.origin and lid.origin and spr.unit) then
        return nil
    end
    local u = spr.unit * H
    -- the sarcophagus, where the mummy unwraps and where the helper stands: not behind decoration
    -- on the ground (decor is drawn over actors); planned in scene space, see place()
    local d, cx, out
    -- h.pickup: called up for one of the cast whose time is up (see hooks.pickup) - the sarcophagus
    -- comes up in its way, opens, and in it goes; no mummy
    local pickup = h and h.pickup
    if pickup then
        d, cx = 1, pickup.cx + (pickup.facing or 1) * 2.4 * u
        if not pickup.cx or cx < 1.2 * u or cx > W - 1.2 * u then return nil end
    end
    local function free(x, half)
        local sx = d > 0 and x or W - x
        for _, dc in ipairs(standing_decor()) do
            if dc.y + dc.spr.h > H * 0.8 and sx + half > dc.x and sx - half < dc.x + dc.spr.w then return false end
        end
        return true
    end
    for _ = 1, pickup and 0 or 16 do
        d = walk_dir(el)                -- (the helper's side: started by a key, the side next door)
        local x = rnd(math.max(1.8 * u, W * 0.1), math.max(1.8 * u, W * 0.35))
        local o = x + rnd(2.2, 3.0) * u
        if o + 3 * u <= W and free(x, box.w / 2 + 0.3 * u) and free(o, 0.7 * u) and free(o + 1.3 * u, 0.6 * u) then
            cx, out = x, o
            break
        end
    end
    if not cx then return nil end
    local a = { el = el, spr = spr, layers = 4, scene = true }
    local open = lid.frames - 1
    -- a skeleton about here (one of the cast, a skeleton's act) joins in: it's the helper, standing
    -- by till it hurries over; after, the helper may go on as a skeleton of the cast (one that
    -- joined in does), now and then the mummy too (the sarcophagus shuts empty and sinks)
    local who
    for _, b in ipairs(pickup and {} or actors) do
        if actor_family(b) == "skeleton" and (b.family or b.el.type == "performer") and not b.gone and not b.leaving
                and not b.swap and not b.called and b.cx and b.cx > 0.05 * W and b.cx < 0.95 * W then who = b break end
    end
    local skel_sp, mummy_sp = cast_sprite("skeleton"), cast_sprite("mummy")
    local helper_on = skel_sp and cast_el() and (who or (math.random() < (el.helper_on or 0.5)
                      and not select(2, chars_here("skeleton")) and not room.taken["chr:skeleton"]))
    local mummy_on = mummy_sp and cast_el() and (el.mummy_force or math.random() < (el.mummy_on or 0.5))
    local test = el.mummy_force                 -- (preview: a skeleton comes by the trap)
    el.mummy_force = nil
    if who then a.recruited = { who } end

    local steps = {}
    local A = { x = cx, face = 0, rest = { clip = "idle", rest = true }, clips = C }
    local Bt = { x = W + 1.2 * u, face = -1, rest = { hide = true, rest = true }, clips = B }
    if who then
        Bt.x = d > 0 and who.cx or W - who.cx
        Bt.face, Bt.rest = 0, { clip = "idle", rest = true }
    end
    local hx0 = Bt.x
    local function add(s)   -- (a missing part rests as planned at this point)
        s.a, s.b = s.a or A.rest, s.b or Bt.rest
        steps[#steps + 1] = s
        return s
    end
    local function turn(t, f, key)
        if f == t.face then return end
        local s = {}
        if t.face ~= 0 and t.clips.turn_front then s[key] = { clip = "turn_front", m = t.face < 0 } add(s) end
        s = {}
        if f ~= 0 and t.clips.turn_side then s[key] = { clip = "turn_side", m = f < 0 } add(s) end
        t.face = f
    end
    local function go(t, key, to, rate)
        turn(t, to > t.x and 1 or -1, key)
        add { [key] = { clip = "walk", to = to, m = t.face < 0, rate = rate } }
        t.x = to
    end

  local side = d > 0 and "right" or "left"
  if pickup then
    A.rest = { hide = true, rest = true }
    add { rise = { 1, 0 }, dur = DECOR_MOVE_S }
    add { lid = { 0, open }, dur = 1.0 }
    add { trap = true, dur = 14 }
  else
    -- up out of the ground, the lid opens, out and to the middle, facing the viewer
    add { a = { hide = true }, rise = { 1, 0 }, dur = DECOR_MOVE_S }
    add { a = { hide = true }, dur = rnd(0.5, 1.5) }
    add { lid = { 0, open }, dur = 1.0 }
    add { dur = rnd(0.4, 0.9) }
    go(A, "a", out)
    turn(A, 0, "a")
    add { dur = rnd(0.8, 1.5) }
    -- off they go; embarrassed (one of the shouts, maybe); the helper comes
    add { a = { clip = "unwrap" } }
    A.rest = { clip = "shy", rest = true }
    add { a = { clip = "shy", dur = rnd(2, 3), act = true } }
    -- with a screen next door on the helper's side, it is seen there first, hurrying over
    local hv = B.walk.stride_px * B.walk.fps / B.walk.count * 2.4 * (el.speed or 1.0)
    if room[side] and not who then
        add { a = { clip = "shy", dur = (W + 1.2 * u) / hv }, summon = true }
    end
    Bt.rest = { clip = "idle", m = true, rest = true }
    go(Bt, "b", out + 1.3 * u, 2.4)
    turn(Bt, 0, "b")
    add { a = C.shy_turn and { clip = "shy_turn" } or nil, b = { clip = "wind", m = true, dur = 0.6 } }
    A.rest = { clip = "idle", rest = true }
    add { a = { clip = "spin" }, b = { clip = "wind", m = true } }
    add { a = { clip = C.cheer and "cheer" or "idle", dur = (not C.cheer) and 1.5 or nil },
          b = { clip = B.cheer and "cheer" or "idle", m = true, dur = (not B.cheer) and 1.5 or nil } }
    -- the helper goes off (back over next door; or on as one of the cast), the mummy back in (or
    -- off too), the lid shuts, down it goes
    if helper_on then
        turn(Bt, 1, "b")
        Bt.rest = { hide = true, rest = true }
        add { b = { hide = true }, free_b = true }
    else
        go(Bt, "b", W + 1.5 * u, 2.4)
        steps[#steps].b.home = true
        Bt.rest = { hide = true, rest = true }
    end
    if mummy_on then
        add { dur = rnd(0.4, 0.8) }
        turn(A, 1, "a")
        A.rest = { hide = true, rest = true }
        add { a = { hide = true }, free_a = true }
        add { dur = rnd(1.0, 2.0) }
        -- the sarcophagus stays open a while, empty: one of the cast passing in front is taken - in
        -- it, the lid slams shut, it rattles and sinks with it inside
        add { trap = true, dur = rnd(range(el.trap_wait, 20)) }
    else
        go(A, "a", cx)
        turn(A, 0, "a")
    end
  end
    local slam = add { lid = { open, 0 }, dur = 1.0 }
    local rattle = add { a = { hide = true }, dur = 0, rattle = true }
    add { a = { hide = true }, dur = rnd(0.5, 1.2) }
    add { a = { hide = true }, rise = { 0, 1 }, dur = DECOR_MOVE_S }

    -- play
    local si, tc = 1, 0
    local lf, rise = 0, 1
    A.x, Bt.x = cx, hx0
    local function go_on(sp, fam, x)                -- (one of the scene on as one of the cast: walking off)
        local ce = cast_el()
        local b = ce and #free_ids > 0 and spawn.wanderer(ce, sp, { fam = fam, dir = d, at = d > 0 and x or W - x, hops = 0,
                                                                  ttl = math.floor(rnd(range(ce.cast_ttl, 120))) })
        if not b then return end
        adopt(b, ce, { hops = 0 })
        msg.verbose("mummy: the " .. fam .. " goes on as one of the cast")
    end
    a.line = pick_line(el)
    local function place(sp, x, frame, mirror, dy)
        local m = (mirror and true or false) ~= (d < 0)
        local ox = m and (sp.w - sp.origin[1]) or sp.origin[1]
        return { spr = sp, frame = frame, variant = m, x = ((d > 0) and x or (W - x)) - ox, y = H - sp.origin[2] + dy }
    end
    -- one actor's part of the step: its layer (or nil) and whether that part is done
    local function part(t, sp, p, dt, dy)
        local rest = p.rest
        if p.hide then return nil, rest or tc >= (p.dur or 0) end
        local c = t.clips[p.clip]
        local rate = p.rate or 1
        local done
        if p.to then
            local v = c.stride_px * c.fps / c.count * rate * (el.speed or 1.0)
            local dir = p.to > t.x and 1 or -1
            t.x = t.x + dir * v * dt
            if (dir > 0 and t.x >= p.to) or (dir < 0 and t.x <= p.to) then t.x, done = p.to, true end
        else
            done = rest or tc >= (p.dur or (c.loop and 0 or c.count / c.fps))
        end
        local k = math.floor(tc * c.fps * rate)
        if c.loop then k = k % c.count else k = math.min(k, c.count - 1) end
        return place(sp, t.x, c.start + k, p.m, dy), done
    end

    function a.update(dt, t)
        local s = steps[si]
        if not s then return false end
        if si ~= a.logged then
            a.logged = si
            msg.verbose("mummy step " .. si)
            if s.free_b then go_on(skel_sp, "skeleton", Bt.x) end
            if s.free_a then go_on(mummy_sp, "mummy", A.x) end
            if s.trap and test and skel_sp and #free_ids > 0 then
                local sx = d > 0 and cx or W - cx
                local from = sx > W / 2 and sx - 3 * u or sx + 3 * u
                local b = spawn.wanderer(cast_el(), skel_sp, { fam = "skeleton", dir = from < sx and 1 or -1, at = from, hops = 0, ttl = 60 })
                if b then adopt(b, cast_el(), { hops = 0 }) end
            end
        end
        tc = tc + dt
        if s.summon and not s.summoned then
            s.summoned = true
            msg.verbose("mummy: the helper hurries over from next door")
            hand_over(side, { kind = "passer", el = el.index, sprite = helper.name, clip = "walk", rate = 2.4,
                              dir = side == "right" and -1 or 1, from_far = true, hops = MAX_HOPS })
        end
        if s.trap and not a.victim and tc > 1 then             -- (one of the cast in front of it: in it goes)
            local sx = d > 0 and cx or W - cx
            for _, b in ipairs(actors) do
                if b ~= a and b.family and not b.scene and not b.gone and (not pickup or b == pickup or b.out_since) and not b.leaving and not b.swap and not b.called
                        and not b.she and b.cx and math.abs(b.cx - sx) < 0.45 * u and b.spr and b.spr.clips
                        and b.spr.clips.idle and b.spr.origin then
                    b.gone, a.victim = true, b.spr
                    slam.dur, rattle.dur, tc = 0.3, 1.6, s.dur
                    msg.verbose("mummy: the " .. actor_family(b) .. " walks past the sarcophagus - it's taken, shut in")
                    break
                end
            end
        end
        local p = s.dur and clamp(tc / s.dur, 0, 1) or 1
        if s.lid then lf = math.floor(s.lid[1] + (s.lid[2] - s.lid[1]) * p + 0.5) end
        if s.rise then rise = s.rise[1] + (s.rise[2] - s.rise[1]) * (s.rise[2] > s.rise[1] and p * p or 1 - (1 - p) ^ 2) end
        local dy = rise * box.h
        local la, da = part(A, spr, s.a, dt, A.x == cx and dy or 0)
        local lb, db = part(Bt, helper, s.b, dt, 0)
        if s.b.home then
            local hx = d > 0 and Bt.x or W - Bt.x
            walk_out(a, hx, d, 0.5 * u, { kind = "passer", sprite = helper.name, clip = "walk", rate = 2.4, unique = false,
                hops = MAX_HOPS })      -- (home is just next door: not all round the room)
        end
        local jx = s.rattle and rnd(-0.04, 0.04) * u or 0               -- (someone shut in it)
        if a.victim and not lb then
            local v = a.victim
            lb = { spr = v, frame = v.clips.idle.start, variant = false, x = ((d > 0) and cx or (W - cx)) - v.origin[1] + jx,
                   y = H - v.origin[2] + dy }
        end
        local layers = { place(box, cx + jx, 0, false, dy), la, lb, place(lid, cx + jx, lf, false, dy) }
        if la then a.sx, a.sy = la.x, la.y end
        a.talking = a.line and s.a and s.a.act and true or false
        if a.talking and not a.say_t then a.say_t = t end
        if da and db and tc >= (s.dur or 0) then si, tc = si + 1, 0 end
        return true, layers
    end
    return a
end

-- one of the cast whose time is up (b): a sarcophagus comes up in its way for it (not too often)
function hooks.pickup(b)
    local now = mp.get_time()
    if now < (hooks.pickup_next or 0) or #free_ids < 4 then return false end
    for _, x in ipairs(actors) do if x.el and x.el.type == "mummy" and not x.gone then return false end end
    for _, e in ipairs(M.elements) do
        local sp = e.type == "mummy" and M.sprites[e.sprite or ""]
        if sp then
            local a = spawn.mummy(e, sp, { pickup = b })
            if not a then return false end
            adopt(a, e, { hops = 0 })
            if b.pause then b.pause(DECOR_MOVE_S + 1.2) end      -- (it watches it come up and open)
            hooks.pickup_next = now + (e.pickup_every or 30)
            msg.verbose("mummy: a sarcophagus comes up for the " .. tostring(actor_family(b)) .. " (its time is up)")
            return true
        end
    end
    return false
end

-- the vampires' bat (the vampire element's el.bat), if it's there
function hooks.bat_sprite()
    for _, e in ipairs(M.elements) do
        local b = e.type == "vampire" and M.sprites[e.bat or ""]
        if b and b.clips and b.clips.fly and b.clips.hang and b.clips.unfold then return b end
    end
end

-- a coffin for the vampire or the princess vampire (ws: one or both of them, walking about here): it
-- slides in from the nearer side and stops by them; the lid opens, in they jump and lie down, the
-- lid shuts - the two of them in it: it wiggles a while, the lid rattling - and it sinks away into
-- the ground. The vampire element's coffin (el.box, el.lid) and lying sprites (el.lie, el.lie_she)
function hooks.coffin_in(ws)
    local S, vel = M.sprites, nil
    for _, e in ipairs(M.elements) do if e.type == "vampire" then vel = e end end
    local box, lid = vel and S[vel.box or ""], vel and S[vel.lid or ""]
    if not (box and lid and box.origin and lid.origin and #free_ids >= 2 + #ws) then return false end
    local lies = {}
    for i, b in ipairs(ws) do
        local L = S[(actor_family(b) == "vampire" and vel.lie or vel.lie_she) or ""]
        if not (L and L.clips and L.clips.lie_down and L.origin and L.unit and b.cx and b.spr and b.pause) then return false end
        lies[i] = L
    end
    local u, half, open = lies[1].unit * H, box.w / 2, lid.frames - 1
    local sink, rest, hop = (vel.sink or 0.45) * u, 0.42 * u, 1.3 * u
    local mid = 0
    for _, b in ipairs(ws) do mid = mid + b.cx / #ws end
    if #ws == 1 then mid = ws[1].cx + (ws[1].facing or 1) * (half + 0.8 * u) end
    mid = clamp(mid, half + u, W - half - u)
    local from = mid < W / 2 and -half or W + half
    local v = math.max(1.5 * u, math.abs(mid - from) / 4)
    local slide = math.abs(mid - from) / v
    local a = { el = vel, spr = box, layers = 2 + #ws, groups = {}, scene = true }
    local x, ph, tc, lf, jx = from, "slide", 0, 0, {}
    for _, b in ipairs(ws) do b.boxed = true b.pause(slide + 2.5) end
    msg.verbose("coffin: a coffin slides in for the " .. (#ws > 1 and "two vampires" or actor_family(ws[1])))
    local function place(sp, px, frame, dy, m)
        local ox = m and (sp.w - sp.origin[1]) or sp.origin[1]
        return { spr = sp, frame = frame, variant = m or false, x = px - ox, y = H - sp.origin[2] + (dy or 0) }
    end
    local function next_ph(p) ph, tc = p, 0 if p ~= "slide" then msg.verbose("coffin: " .. p) end end
    function a.update(dt)
        tc = tc + dt
        local dy, wig = 0, 0
        if ph == "slide" then
            x = from + (mid - from) * clamp(tc / slide, 0, 1)
            if tc >= slide then next_ph("open") end
        elseif ph == "open" then
            lf = math.floor(open * clamp(tc, 0, 1) + 0.5)
            if tc >= 1.2 then
                for i, b in ipairs(ws) do jx[i] = b.gone and mid or b.cx  b.gone = true end
                next_ph("jump in")
            end
        elseif ph == "jump in" then
            if tc >= 0.9 then next_ph("lie down") end
        elseif ph == "lie down" then
            local c = lies[1].clips.lie_down
            if tc >= c.count / c.fps then next_ph("shut") end
        elseif ph == "shut" then
            lf = math.floor(open * (1 - clamp(tc, 0, 1)) + 0.5)
            if tc >= 1.0 then next_ph(#ws > 1 and "wiggle" or "still") end
        elseif ph == "wiggle" then
            wig = math.sin(tc * 31) * 0.05 * u * (0.6 + 0.4 * math.sin(tc * 3))
            lf = (math.sin(tc * 7) > 0.7) and math.min(2, open) or 0
            if tc >= 3.5 then lf = 0 next_ph("still") end
        elseif ph == "still" then
            if tc >= 1.5 then next_ph("sink") end
        else
            dy = box.h * clamp(tc / 3, 0, 1)
            if tc >= 3.2 then msg.verbose("coffin: gone into the ground") return false end
        end
        local ls = { place(lid, x + wig, lf, dy) }
        for i, b in ipairs(ws) do
            local L, lx = lies[i], mid + rest - (i - 1) * 0.12 * u
            if ph == "jump in" then
                local q = clamp(tc / 0.9, 0, 1)
                local idle = b.spr.clips.idle
                local l = place(b.spr, jx[i] + (lx - jx[i]) * ease(q), idle.start, sink * q - hop * math.sin(math.pi * q), lx < jx[i])
                ls[#ls + 1] = l
            elseif ph == "lie down" or ph == "shut" then
                local c = L.clips.lie_down
                local k = ph == "shut" and c.count - 1 or math.min(math.floor(tc * c.fps), c.count - 1)
                ls[#ls + 1] = place(L, lx + wig, c.start + k, sink + dy)
            end
        end
        ls[2 + #ws] = place(box, x + wig, 0, dy)
        a.cx = x
        return true, ls
    end
    adopt(a, vel, { hops = 0 })
    return true
end

-- ASS helpers for the frankenstein: a jagged spark from (x0, y0) to (x1, y1), a puff of smoke
local function spark(out, x0, y0, x1, y1, color, width)
    local pts, n = {}, 5
    local dx, dy = x1 - x0, y1 - y0
    local len = math.sqrt(dx * dx + dy * dy)
    for i = 0, n do
        local q, j = i / n, (i == 0 or i == n) and 0 or rnd(-0.18, 0.18) * len
        pts[#pts + 1] = { x0 + dx * q - dy / len * j, y0 + dy * q + dx / len * j }
    end
    local path = {}
    for i = 1, #pts do path[#path + 1] = string.format("%d %d", pts[i][1], pts[i][2]) end
    for i = #pts - 1, 2, -1 do path[#path + 1] = string.format("%d %d", pts[i][1], pts[i][2]) end
    out[#out + 1] = string.format("{\\an7\\pos(0,0)\\bord%d\\shad0\\blur1\\1c&HFFFFFF&\\3c%s\\p1}m %s l %s{\\p0}",
        width or 2, color or "&HFFF0A0&", path[1], table.concat(path, " l ", 2))
end

local function puff(out, x, y, r, alpha, color)
    local k = 0.5523 * r
    out[#out + 1] = string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\blur%d\\1c" .. (color or "&H9A9A9A&") .. "\\1a&H%02X&\\p1}"
        .. "m %d %d b %d %d %d %d %d %d b %d %d %d %d %d %d b %d %d %d %d %d %d b %d %d %d %d %d %d{\\p0}",
        math.max(1, math.floor(r * 0.06)), math.floor(clamp(alpha, 0, 1) * 255),
        x, y - r, x + k, y - r, x + r, y - k, x + r, y, x + r, y + k, x + k, y + r, x, y + r,
        x - k, y + r, x - r, y + k, x - r, y, x - r, y - k, x - k, y - r, x, y - r)
end

-- a fight in a cloud of dust at x (the two in it gone meanwhile): swirling, stars popping out; dur
-- seconds, then done() - who comes out of it
function hooks.dust_fight(el, x, dur, done)
    local u = 0.115 * H
    local a = { el = el, layers = 1, groups = {}, t = 0 }
    function a.update(dt)
        a.t = a.t + dt
        if a.t >= dur then
            if done then done() end
            return false
        end
        return true, {}
    end
    function a.ass(out)
        local k, cy = a.t, H - 0.85 * u
        local al = 1 - clamp(k / 0.3, 0, 1) * clamp((dur - k) / 0.4, 0, 1)
        puff(out, x, cy, 0.95 * u, 0.15 + 0.6 * al, "&H9AA6B0&")
        for i = 1, 11 do
            local ang = k * 6.5 + i * 2 * math.pi / 11
            local r = (0.6 + 0.15 * math.sin(k * 5 + i)) * u
            puff(out, x + math.cos(ang) * r * 1.35, cy + math.sin(ang) * r * 0.55,
                 (0.36 + 0.1 * math.sin(k * 9 + i * 1.7)) * u, 0.1 + 0.7 * al, i % 2 == 0 and "&HB4BEC6&" or "&H8C98A2&")
        end
        for i = 1, 4 do
            local ph = (k * 1.6 + i / 4) % 1
            local ang = i * 1.9 + math.floor(k * 1.6 + i / 4) * 2.3
            local sx, sy = x + math.cos(ang) * (0.7 + 0.8 * ph) * u, cy + math.sin(ang) * (0.4 + 0.6 * ph) * u - 0.3 * u
            local sa = math.floor(clamp(math.max(al, ph), 0, 1) * 255)
            out[#out + 1] = string.format("{\\an5\\pos(%d,%d)\\fs%d\\b1\\bord2\\shad0\\frz%d\\1c&H30D8FF&\\3c&H202020&\\1a&H%02X&\\3a&H%02X&}*",
                sx, sy, 0.5 * u, k * 400 + i * 90, sa, sa)
        end
    end
    adopt(a, el, { hops = 0 })
    return a
end

-- a piece of zombie brain (the zombie's el.brain, tools/bake/brain.py): now and then one falls off a
-- zombie's head at a stop and lies there for good (BRAINS_MAX on a screen at most), till a zombie
-- finds it - the one it fell off too, after a while - and eats it up: lifted to its mouth, bite by
-- bite smaller. u: the zombie's unit (the piece is drawn at its own, a bit big)
local BRAINS_MAX = 3
local function brains_here()
    local n = 0
    for _, b in ipairs(actors) do if b.brain_piece and not b.gone then n = n + 1 end end
    return n
end
local function free_brain(z, x)              -- the nearest piece lying here that zombie z may eat
    local best, bd
    local now = mp.get_time()
    for _, b in ipairs(actors) do
        if b.brain_piece and b.landed and not b.gone and not b.lifted
                and (not b.eater or now - b.eater_t > 20) and (b.dropper ~= z or now - b.drop_t > 15) then
            local d = math.abs(b.cx - x)
            if not bd or d < bd then best, bd = b, d end
        end
    end
    return best
end
local function brain_sprite()               -- (the zombie element's el.brain)
    for _, el in ipairs(M.elements) do
        local b = el.type == "zombie" and M.sprites[el.brain or ""]
        if b and b.clips and b.clips.lie and b.clips.eat and b.origin then return b, el end
    end
end
local function new_brain(el, spr, x, y, vx, z, u)   -- falling from (x, y: its bottom), off zombie z
    local C = spr.clips
    local a = { el = el, spr = spr, layers = 1, groups = {}, brain_piece = true, cx = x,
                dropper = z, drop_t = mp.get_time() }
    local vy, ground, m = -1.2 * u, H - 0.04 * u, vx < 0
    local lift, frame = nil, C.lie.start
    local up = 0.5
    function a.eat(hx, hy, dur)              -- (taken up to (hx, hy: the mouth) in dur, then eaten there)
        a.lifted, up = true, dur or 0.5
        msg.verbose("brain: picked up, to the mouth")
        lift = { x0 = x, y0 = y, x1 = hx, y1 = hy, t = 0 }
    end
    function a.update(dt)
        if a.gone then return false end
        if lift then
            lift.t = lift.t + dt
            local p = ease(clamp(lift.t / up, 0, 1))
            x, y = lift.x0 + (lift.x1 - lift.x0) * p, lift.y0 + (lift.y1 - lift.y0) * p
            if lift.t > up then
                local k = math.floor((lift.t - up) * C.eat.fps)
                if k >= C.eat.count then return false end
                frame = C.eat.start + k
            end
        elseif not a.landed then
            vy = vy + 9 * u * dt
            x, y = x + vx * dt, y + vy * dt
            if y >= ground then
                y = ground
                if vy > 2 * u then vy, vx = -vy * 0.3, vx * 0.5 else a.landed = true end
            end
        end
        a.cx = x
        local ox = m and (spr.w - spr.origin[1]) or spr.origin[1]
        return true, { { spr = spr, frame = frame, variant = m, x = x - ox, y = y - spr.origin[2] } }
    end
    adopt(a, el, { hops = 0 })
    return a
end

-- zombie: a baked character shuffling across with its arms out, stopping now and then to sniff
-- the air (a thought: puffs and a cloud with a brain in it, el.thought, frames see
-- tools/bake/thought.py). Whoever has a brain and comes close (the vampire, the cat) makes it
-- turn and reach for them, thinking of brains; the vampire and the cat run past (they look
-- for zombie_near). A skeleton gets a crossed-out brain: nothing to eat there. Two sprites on
-- two overlay ids: the zombie and its thought above it. When it comes, it may invite one of
-- el.invite ({type, chance} per entry): that one comes in soon, zombie or not.
function spawn.zombie(el, spr, h)
    local C, th = spr.clips, M.sprites[el.thought or ""]
    if not (C and C.walk and C.idle and C.sniff and C.reach and spr.origin and spr.unit and th) then return nil end
    local u = spr.unit * H
    local a = { el = el, spr = spr, layers = 2 }
    local dir = walk_dir(el)
    local x = dir > 0 and -1.2 * u or W + 1.2 * u
    local v = C.walk.stride_px * C.walk.fps / C.walk.count * (el.speed or 1.0)
    if h then dir = h.dir == 1 and 1 or -1 x = walk_in_x(h, v, 0.6 * u) end   -- from the screen next door
    -- stops along the way, then off the other side (and on to the next screen)
    -- in a room of screens short stays: a stop, and (nothing to eat here) under the ground on to
    -- another screen (relayed under the ones between, see theme-room-in); it comes up there
    local short = room.left or room.right
    local state, dy, clods, under_t = "walk", 0, {}, 0
    if h and h.tunnel then
        x, state = free_x(0.25 * W, 0.75 * W), "under"
        under_t = rnd(1, 2.5) + 1.2 * (tonumber(h.went) or 1)
    end
    local B = M.sprites[el.brain or ""]
    if B and not (B.clips and B.clips.lie and B.clips.eat and B.origin) then B = nil end
    local hurry, meal, meal_stop, drop_at = 1, nil, false, nil
    local stops = {}
    local n_stops = short and 1 or math.random(h and 1 or 2, h and 2 or 3)
    for _ = 1, n_stops do stops[#stops + 1] = free_x(0.12 * W, 0.88 * W) end
    table.sort(stops, function(p, q) return (p - q) * dir < 0 end)
    stops[#stops + 1] = dir > 0 and W + 1.5 * u or -1.5 * u

    local tc, k = 0, 1       -- walk | turn_front | stop | turn_side | react | down | under | up
    local push_left, turn_back = rnd(2, 6) * u, false
    local stop_clip, stop_dur
    local think, think_t, crossed = false, 0, false
    local react_side, react_t, seen, calm = 1, 0, {}, 0
    local face_front = false               -- standing towards the viewer (yaw 15) rather than sideways
    local function brainy()
        -- the nearest one with a brain (vampire, cat) within 3u, and its side; or a skeleton (no brain)
        local best, bd, skel
        for _, b in ipairs(actors) do
            local bx = b.cx
            if bx and b ~= a then
                local dd = math.abs(bx - x)
                if b.brainy and dd < 3 * u and (not bd or dd < bd) then best, bd = bx, dd end
                if b.spr and (b.spr.name or ""):find("skeleton") and dd < 3 * u then skel = b end
            end
        end
        for _, c in ipairs(hooks.cats()) do
            local dd = math.abs(c.p.x - x)
            if dd < 3 * u and (not bd or dd < bd) then best, bd = c.p.x, dd end
        end
        return best, skel
    end
    local function dirt(n)
        for _ = 1, n do
            clods[#clods + 1] = { x = x + rnd(-0.4, 0.4) * u, y = H - rnd(0, 0.1) * u, vx = rnd(-1, 1) * u,
                                  vy = -rnd(1.5, 3) * u, r = rnd(0.04, 0.09) * u, t = 0 }
        end
    end
    local function go_under()                -- off under the ground: to a screen a few along
        local sides = {}
        if room.left then sides[#sides + 1] = "left" end
        if room.right then sides[#sides + 1] = "right" end
        local side = sides[math.random(#sides)]
        local n = math.random(1, math.max(1, (room.screens or 2) - 1))
        if not hand_over(side, { kind = "zombie", el = el.index, sprite = spr.name, dir = side == "right" and 1 or -1,
                                 hops = (a.hops or 0) + 1, lead = 0, unique = a.unique, tunnel = n, went = 1 }) then
            return false
        end
        if a.unique then                     -- (theirs now, as walk_out)
            a.unique = false
            room.taken[claim_key(spr)] = true
            room.claim_t = 0
        end
        msg.verbose("zombie: under the ground (" .. n .. " screens along)")
        return true
    end

    function a.update(dt, t)
        tc = tc + dt
        local c, m, frame
        do
            local keep = {}
            for _, q in ipairs(clods) do
                q.t, q.vy = q.t + dt, q.vy + 6 * u * dt
                q.x, q.y = q.x + q.vx * dt, q.y + q.vy * dt
                if q.y < H + q.r then keep[#keep + 1] = q end
            end
            clods = keep
        end
        if state == "under" then
            under_t = under_t - dt
            if under_t > 0 then return true, {} end
            state, tc = "up", 0
            dirt(10)
            hooks.grave_at(x, -dir)
            msg.verbose("zombie: up out of the ground")
        end
        if state == "up" or state == "down" then      -- (climbing out, or back in, in a spray of dirt)
            local R = C.rise                           -- (its climbing out of the grave, played back to go in)
            local len = R and R.count / R.fps or 1.6
            local p = clamp(tc / len, 0, 1)
            if state == "down" then p = 1 - p end
            dy = R and 0 or (1 - p) * 2.6 * u
            if math.random() < dt * 8 and p < 0.9 then dirt(1) end
            if tc >= len then
                if state == "down" then
                    if go_under() then return false end
                    state, tc = "up", 0          -- (nowhere to go: up again)
                else
                    dy, state, tc, face_front = 0, "walk", 0, false
                end
            end
            c = R or C.sniff
            local f = c.start + math.floor(tc * c.fps) % c.count
            if R then f = c.start + math.min(c.count - 1, math.floor(p * c.count)) end
            local mi = not R and dir < 0
            local ox = mi and (spr.w - spr.origin[1]) or spr.origin[1]
            local layer = { spr = spr, frame = f, variant = mi, x = x - ox, y = H - spr.origin[2] + dy }
            a.zx, a.sx, a.sy = x, layer.x, layer.y
            return true, { layer }
        end
        -- a piece of brain lying here: off to it (in a hurry), to eat it up
        if state == "walk" and not meal and a.handed_on ~= "yes" then
            local b = free_brain(a, x)
            if b then
                meal, b.eater, b.eater_t = b, a, t
                local side = b.cx >= x and 1 or -1
                local to = math.abs(b.cx - x) < 0.7 * u and x or b.cx - side * 0.55 * u
                dir, stops, k, meal_stop, hurry = side, { to, side > 0 and W + 1.5 * u or -1.5 * u }, 1, true, 2
                a.handed_on = nil
                think, think_t, crossed = true, 0, false
                msg.verbose("zombie: a piece of brain, after it")
            end
        end
        local target, skel = brainy()
        if target and t > calm and not meal and state ~= "react" and state ~= "turn_front" and state ~= "turn_side" then
            state, tc, react_t = "react", 0, 0
        end
        if skel and not seen[skel] and not target then
            seen[skel] = true
            think, think_t, crossed = true, 0, true
        end
        if state == "react" then
            if target then react_side, react_t, a.last_tx = target > x and 1 or -1, 0, target else react_t = react_t + dt end
            think, crossed = true, false
            c, m = C.reach, react_side < 0
            if react_t > 1.2 or tc > 6 then        -- gone (or out of reach): walking on
                state, tc, think, calm = "walk", 0, false, t + 6
                face_front = false
                -- it got away over the edge to a screen next door: after it!
                local tx = a.last_tx
                if tx and react_t > 1.2 and (tx < 2 * u or tx > W - 2 * u) and (tx > x) == (react_side > 0)
                        and can_walk_on(a, react_side) then
                    dir, stops, k, hurry = react_side, { react_side > 0 and W + 1.5 * u or -1.5 * u }, 1, 1.8
                    think, think_t, crossed = true, 0, false
                    msg.verbose("zombie: after it, next door")
                end
            end
        elseif state == "walk" then
            local to = stops[k]
            c, m = C.walk, dir < 0
            x = x + dir * v * (a.pushing and 0.7 or hurry) * dt
            local over
            a.pushing, over = push_coffins(x, dir, 0.6 * u, v * 0.7)
            if a.pushing then push_left = push_left - v * 0.7 * dt end
            if k == #stops then walk_out(a, x, dir, 0.6 * u) end
            if over and k < #stops and (to - x) * dir <= 0 then k = k + 1 to = stops[k] end  -- it has to go off first
            local fed_up = a.pushing and not over and push_left <= 0
            if fed_up then       -- enough pushing: a sniff at it (a brain in there!), then back the way it came
                table.insert(stops, k, x)
                to, push_left, turn_back = x, math.huge, true
                msg.verbose("zombie: done pushing, a sniff at the coffin")
            end
            if (to - x) * dir <= 0 then
                x = to
                if k == #stops then return false end
                k = k + 1
                if meal_stop then              -- (at the piece: reaching for it, eating it up)
                    meal_stop, hurry = false, 1
                    state, tc, stop_clip, stop_dur = "stop", 0, "eat", (C.pick and C.pick.count / C.pick.fps or 0) + 2.8
                else
                    state, tc = C.turn_front and "turn_front" or "stop", 0
                    local r = math.random()
                    if r < 0.6 or fed_up then stop_clip, stop_dur = "sniff", rnd(2.5, 4) else stop_clip, stop_dur = "idle", rnd(1.5, 3) end
                    -- a piece of its brain falls off
                    if B and not fed_up and brains_here() < BRAINS_MAX and (el.brain_force or math.random() < (el.brain_chance or 0.3)) then
                        drop_at = rnd(0.6, 1.2)
                        el.brain_force = nil
                    end
                end
            end
        elseif state == "turn_front" then
            c, m = C.turn_front, dir < 0
            if tc >= c.count / c.fps then state, tc, face_front = "stop", 0, true end
        elseif state == "stop" then
            if stop_clip == "eat" then         -- (bending down for it, up to the mouth, eaten bite by bite)
                local pk = C.pick and C.pick.count / C.pick.fps or 0
                c, m = (tc < pk and C.pick or C.reach), dir < 0
                if tc > (pk > 0 and 0.45 * pk or 0.4) and meal and not meal.lifted and not meal.gone then
                    meal.eat(x + dir * 0.38 * u, H - 1.5 * u, pk > 0 and 0.55 * pk or 0.5)
                end
            else
                c, m = C[stop_clip], false
            end
            if stop_clip == "sniff" and tc > 0.6 and not think then think, think_t, crossed = true, 0, false end
            if drop_at and tc >= drop_at then
                drop_at = nil
                if #free_ids > 0 then
                    new_brain(el, B, x + rnd(-0.1, 0.1) * u, H - 2.0 * u, rnd(0.5, 1.1) * u * (math.random() < 0.5 and -1 or 1), a, u)
                    msg.verbose("zombie: a piece of its brain falls off")
                end
            end
            if tc >= stop_dur then
                local ate = stop_clip == "eat"
                state, tc = (C.turn_side and not ate) and "turn_side" or "walk", 0
                if ate then meal, face_front = nil, false end
                if not crossed then think = false end
                -- nothing (more) to do here: under the ground, on to another screen
                if short and not turn_back and not free_brain(a, x) and (a.hops or 0) < (el.max_hops or MAX_HOPS)
                        and not with_guest(a) and math.random() < (el.tunnel_chance or 0.7) then
                    state, tc, think = "down", 0, false
                    dirt(6)
                    hooks.grave_at(x, -dir)
                    msg.verbose("zombie: digs itself into the ground")
                end
                if turn_back then
                    turn_back, dir = false, -dir
                    stops, k = { dir > 0 and W + 1.5 * u or -1.5 * u }, 1
                end
            end
        elseif state == "turn_side" then
            c, m = C.turn_side, dir < 0
            if tc >= c.count / c.fps then state, tc, face_front = "walk", 0, false end
        end
        if state == "down" then return true, {} end
        frame = math.floor(tc * c.fps * (state == "walk" and hurry or 1))
        if c.loop then frame = frame % c.count else frame = math.min(frame, c.count - 1) end

        local mi = m and true or false
        local ox = mi and (spr.w - spr.origin[1]) or spr.origin[1]
        local layers = { { spr = spr, frame = c.start + frame, variant = mi, x = x - ox, y = H - spr.origin[2] } }
        a.zx, a.sx, a.sy = x, layers[1].x, layers[1].y
        -- the thought: up beside the head, on the side it faces (or the side of the one it wants)
        if think then
            think_t = think_t + dt
            if crossed and think_t > 3 then think, crossed = false, false end
        end
        if think then
            local side = state == "react" and react_side or (state == "stop" and 1 or dir)
            local f = think_t < 0.45 and math.floor(think_t / 0.15) or (3 + ({ 0, 1, 2, 1 })[math.floor(think_t * 4) % 4 + 1])
            if crossed and f >= 3 then f = f + 3 end
            local head = H - spr.origin[2] + spr.h - 2.15 * u
            local tx = side > 0 and (x + 0.25 * u - th.w * 0.08) or (x - 0.25 * u - th.w * 0.92)
            layers[2] = { spr = th, frame = f, variant = side < 0, x = tx, y = head - th.h * 0.95 }
        end
        return true, layers
    end

    function a.ass(out)
        for _, q in ipairs(clods) do puff(out, q.x, q.y, q.r, 0.1, "&H1E3A5A&") end
    end
    -- now and then someone with a brain (or a skeleton) is invited along
    function a.on_spawn()
        if h and h.tunnel then return end
        for _, inv in ipairs(el.invite or {}) do
            if math.random() < (inv.chance or 0.5) then
                for _, other in ipairs(M.elements) do
                    if other.type == inv.type and (not inv.sprite or other.sprite == inv.sprite) and element_on(other) then
                        a.invites = a.invites or {}
                        a.invites[other] = true
                        local soon = mp.get_time() + rnd(range(inv.after, 6))
                        local st = elements[other]
                        if st then st.next = math.min(st.next, soon) else elements[other] = { next = soon, active = 0 } end
                        msg.verbose("zombie invites " .. (other.sprite or other.type))
                    end
                end
                if inv.type == "prowler" then hooks.call_cat(rnd(range(inv.after, 6))) end
                break
            end
        end
    end
    return a
end

-- frankenstein: a baked character stomping across with his arms out; at a stop he faces the
-- viewer and shocks himself (sparks crackle from his neck bolt, he jolts, a little smoke). At
-- the last stop one shock too many: he blows apart, the pieces (clips piece_*, spinning) fly
-- up and come down, lie a moment in the smoke and sink into the ground. el.explode = false:
-- he walks off instead. Layers: him, then his six pieces.
local PIECES = { -- clip, flying off (x: outwards, y: up, in u/s), height of its middle on him and lying (u)
    { "piece_head", 0.0, 5.5, 2.3, 0.35 }, { "piece_body", 0.3, 4.5, 1.35, 0.4 },
    { "piece_arm_l", -2.4, 5.5, 1.45, 0.15 }, { "piece_arm_r", 2.4, 5.5, 1.45, 0.15 },
    { "piece_leg_l", -1.6, 3.5, 0.45, 0.2 }, { "piece_leg_r", 1.6, 3.5, 0.45, 0.2 },
}
-- the same for another's pieces (by sprite name): the zombie torn apart in a fight
PIECES.by = { zombie3d = {
    { "piece_head", 0, 0, 1.7, 0.35 }, { "piece_body", 0, 0, 0.86, 0.38 }, { "piece_arm_l", 0, 0, 1.18, 0.15 },
    { "piece_arm_r", 0, 0, 1.2, 0.13 }, { "piece_leg_l", 0, 0, 0.27, 0.15 }, { "piece_leg_r", 0, 0, 0.27, 0.13 } } }
function PIECES.relic(spr, i, frame)        -- (piece i lying about, frame: as it came down; see new_relic)
    local p, u = (PIECES.by[spr.name] or PIECES)[i], spr.unit * H
    return { spr = spr, frame = frame, mx = spr.origin[1], my = spr.origin[2] - p[4] * u, lie = p[5] * u,
             kind = i == 1 and "head" or i == 2 and "body" or "limb", piece = i }
end
function PIECES.from(h)                     -- (a relic handed over from next door: h.relic {sprite, piece, frame})
    local r = type(h) == "table" and h.relic
    local spr = r and M.sprites[r.sprite or ""]
    if not spr then return nil end
    if r.piece then return PIECES[r.piece] and spr.unit and PIECES.relic(spr, r.piece, r.frame) end
    return spr.clips and spr.clips.lie and hooks.bone_relic(spr)
end
function PIECES.pass(r)                     -- (and over: what goes in h.relic)
    return r and { sprite = r.spr.name, piece = r.piece, frame = r.frame } or nil
end
function spawn.frankenstein(el, spr, h)
    local C = spr.clips
    if not (C and C.walk and C.idle and C.shock and spr.origin and spr.unit) then return nil end
    for _, p in ipairs(PIECES) do if not C[p[1]] then return nil end end
    local u = spr.unit * H
    local a = { el = el, spr = spr, layers = 1 + #PIECES, brainy = true, scene = true }
    local dir = walk_dir(el)
    local x = dir > 0 and -1.2 * u or W + 1.2 * u
    local v = C.walk.stride_px * C.walk.fps / C.walk.count * (el.speed or 1.0)
    if h then dir, a.hops = h.dir == 1 and 1 or -1, tonumber(h.hops) x = walk_in_x(h, v, 0.65 * u) end
    local explode = el.explode ~= false
    -- with a screen next door he may first walk over there (and blow up there)
    local here = el.explode_here
    if explode and not here and can_walk_on(a, dir) and math.random() < 0.5 then explode = false end
    el.explode_here = nil
    local stops = {}
    for _ = 1, explode and 2 or math.random(1, 2) do stops[#stops + 1] = free_x(0.15 * W, 0.85 * W) end
    table.sort(stops, function(p, q) return (p - q) * dir < 0 end)
    if math.abs(stops[#stops] - (stops[#stops - 1] or -1e9)) < 3 * u then table.remove(stops, 1) end
    stops[#stops + 1] = dir > 0 and W + 1.5 * u or -1.5 * u
    local state, tc, k, dur = "walk", 0, 1, 0
    local push_left, turn_back = rnd(2, 6) * u, false
    local smoke = {}                        -- {x, y, r, t, life}
    local pieces, bang_t, still_t
    local function last_stop() return k == #stops - 1 and explode end
    local function neck() return x, H - 2.0 * u end

    function a.update(dt, t)
        tc = tc + dt
        local c, m, jx, jy = nil, dir < 0, 0, 0
        if state == "walk" then
            c = C.walk
            local to = stops[k]
            x = x + dir * v * (a.pushing and 0.7 or 1) * dt
            local over
            a.pushing, over = push_coffins(x, dir, 0.65 * u, v * 0.7)
            if a.pushing then push_left = push_left - v * 0.7 * dt end
            if k == #stops then walk_out(a, x, dir, 0.65 * u) end
            if over and k < #stops and (to - x) * dir <= 0 then k = k + 1 to = stops[k] end  -- it has to go off first
            if a.pushing and not over and push_left <= 0 then
                -- enough pushing: it makes him blow his top (here, if he was to), or turn back after
                stops, k, to, push_left = { x, dir > 0 and W + 1.5 * u or -1.5 * u }, 1, x, math.huge
                turn_back = not explode
                msg.verbose("frankenstein: done pushing")
            end
            if (to - x) * dir <= 0 then
                x = to
                if k == #stops then return false end
                state, tc = C.turn_front and "turn_front" or "stand", 0
            end
        elseif state == "turn_front" then
            c = C.turn_front
            if tc >= c.count / c.fps then state, tc, dur = "stand", 0, rnd(0.8, 1.6) end
        elseif state == "stand" then
            c, m = C.idle, false
            if tc >= dur then state, tc, dur = "shock", 0, last_stop() and rnd(2.6, 3.4) or rnd(1.2, 2.2) end
        elseif state == "shock" then
            c, m = C.shock, false
            local big = last_stop()
            a.fright = { x = x, r = (big and 0.45 or 0.3) * H, till = mp.get_time() + 1.5 }   -- cats keep off
            jx, jy = rnd(-1, 1) * u * (big and 0.06 or 0.035), rnd(-1, 1) * u * 0.02
            if math.random() < dt * 6 then
                local nx, ny = neck()
                smoke[#smoke + 1] = { x = nx + rnd(-0.3, 0.3) * u, y = ny - 0.6 * u, r = 0.15 * u, t = 0, life = 1.5 }
            end
            if tc >= dur then
                if big then
                    state, tc, bang_t = "bang", 0, t
                    local nx, ny = neck()
                    for _ = 1, 9 do
                        smoke[#smoke + 1] = { x = nx + rnd(-0.8, 0.8) * u, y = ny + rnd(-0.6, 1.2) * u,
                                              r = rnd(0.3, 0.55) * u, t = 0, life = rnd(1.6, 2.4), grow = 1.0 }
                    end
                    pieces = {}
                    for i, p in ipairs(PIECES) do
                        local pc = C[p[1]]
                        pieces[i] = { c = pc, dx = 0, dy = 0, vx = (p[2] + rnd(-1, 1)) * u, vy = -(p[3] + rnd(-1, 1)) * 1.5 * u,
                                      ground = (p[4] - p[5]) * u, spin = rnd(10, 18) * (math.random() < 0.5 and 1 or -1),
                                      f = math.random(0, pc.count - 1), bounced = false, landed = false }
                    end
                    -- near the side of a screen next door his head may fly over there
                    local side = (x > W / 2) and 1 or -1
                    local far = side > 0 and (W - x) or x
                    if room[side > 0 and "right" or "left"] and far < 0.45 * W and not here and math.random() < 0.75 then
                        local hd = pieces[1]
                        hd.vx, hd.vy, hd.over = side * (far + 4.5 * u) / 1.1, -8.5 * u, side
                    end
                    a.fright = { x = x, r = 0.6 * H, till = mp.get_time() + 5 }
                    msg.verbose("frankenstein: boom")
                else
                    state, tc, dur = "smoking", 0, rnd(1.2, 2.2)
                end
            end
        elseif state == "smoking" then
            c, m = C.idle, false
            if tc >= dur then
                k = k + 1
                if turn_back then turn_back, dir, stops, k = false, -dir, { dir > 0 and -1.5 * u or W + 1.5 * u }, 1 end
                state, tc = C.turn_side and "turn_side" or "walk", 0
            end
        elseif state == "turn_side" then
            c = C.turn_side
            if tc >= c.count / c.fps then state, tc = "walk", 0 end
        end

        -- smoke drifts up, grows and fades
        local keep = {}
        for _, p in ipairs(smoke) do
            p.t = p.t + dt
            p.y = p.y - 0.5 * u * dt
            p.r0 = p.r0 or p.r
            p.r = p.r + p.r0 * (p.grow or 0.8) * dt
            if p.t < p.life then keep[#keep + 1] = p end
        end
        smoke = keep

        local layers = {}
        local y0 = H - spr.origin[2]
        if state ~= "bang" then
            local frame = math.floor(tc * c.fps)
            if c.loop or state == "shock" then frame = frame % c.count else frame = math.min(frame, c.count - 1) end
            local mi = m and true or false
            local ox = mi and (spr.w - spr.origin[1]) or spr.origin[1]
            layers[1] = { spr = spr, frame = c.start + frame, variant = mi, x = x - ox + jx, y = y0 + jy }
            a.sx, a.sy, a.cx = layers[1].x, layers[1].y, x
        else
            a.cx = nil
            -- the pieces: up and out, down again, a bounce, still; then into the ground
            local all_still = true
            for i, p in ipairs(pieces) do
                if not p.landed then
                    all_still = false
                    p.vy = p.vy + 14 * u * dt
                    p.dx, p.dy = p.dx + p.vx * dt, p.dy + p.vy * dt
                    p.f = p.f + p.spin * dt
                    if p.dy >= p.ground and p.vy > 0 then        -- down on the ground: one bounce, then still
                        if not p.bounced then
                            p.bounced, p.vy, p.vx, p.spin = true, -p.vy * 0.35, p.vx * 0.5, p.spin * 0.4
                        else
                            p.landed, p.dy = true, p.ground
                        end
                    end
                end
                local fr = math.floor(p.f) % p.c.count
                if p.over and not p.handed then        -- the head goes over the edge: on next door
                    local px = x + p.dx
                    if (p.over > 0 and px > W) or (p.over < 0 and px < 0) then
                        p.handed = true
                        hand_over(p.over > 0 and "right" or "left", {
                            kind = "piece", el = el.index, sprite = spr.name, clip = PIECES[i][1], dir = p.over,
                            lead = 0, vx = p.vx / u, vy = p.vy / u, dy = p.dy / u, ground = p.ground / u,
                            f = p.f, spin = p.spin, bounced = p.bounced, unit = u / H })
                    end
                end
                local sink = (still_t and t - still_t > 2.5) and (t - still_t - 2.5) * 0.8 * u or 0
                if not p.left then
                    layers[1 + i] = { spr = spr, frame = p.c.start + fr, variant = false,
                                      x = x - spr.origin[1] + p.dx, y = y0 + p.dy + sink }
                end
            end
            if all_still and not still_t then                       -- all down: a moment, then the body into the ground
                still_t = t
                for i, p in ipairs(pieces) do                       -- (the head, the arms and legs left lying about)
                    local px = x + p.dx
                    if i ~= 2 and not p.over and px > 0.03 * W and px < 0.97 * W and el.relics ~= false then
                        p.left = true
                        hooks.new_relic(el, PIECES.relic(spr, i, p.c.start + math.floor(p.f) % p.c.count), px, H - PIECES[i][5] * u, false)
                    end
                end
            end
            if still_t and t - still_t > 5 then return false end
        end
        return true, layers
    end

    function a.ass(out, t)
        for _, p in ipairs(smoke) do puff(out, p.x, p.y, p.r, 0.35 + 0.65 * p.t / p.life) end
        if state == "shock" then
            local nx, ny = neck()
            local n = last_stop() and 4 or 2
            for _ = 1, n do
                local side = math.random() < 0.5 and -1 or 1
                local bx = nx + side * 0.55 * u
                local ang = rnd(0, 2 * math.pi)
                local r = rnd(0.5, 1.1) * u * (last_stop() and 1.4 or 1)
                spark(out, bx, ny, bx + math.cos(ang) * r, ny + math.sin(ang) * r,
                      math.random() < 0.5 and "&HFFE080&" or "&H40F0FF&", last_stop() and 3 or 2)
            end
        elseif state == "bang" and tc < 0.25 then
            local nx, ny = neck()
            for _ = 1, 10 do
                local ang = rnd(0, 2 * math.pi)
                spark(out, nx, ny + 0.6 * u, nx + math.cos(ang) * 2.2 * u, ny + 0.6 * u + math.sin(ang) * 2.2 * u, "&H40F0FF&", 4)
            end
        end
    end
    return a
end

-- The cast: characters stay about a while after their act (h.ttl seconds), wandering from screen
-- to screen. A scene element lists who it can use (el.recruits: families, "frog" for a frog);
-- one of those about on its screen is taken over (recruit) - the stories run on into each other.
-- wanted_here: a scene here that could use one of fam, due before long (or waiting its turn):
-- its start is pulled forward, and the one wanted hangs about.
local function wanted_here(fam, now)
    if M and M.planner then                  -- (the planner: the first two in line; the first comes sooner)
        for i = 1, math.min(2, #plan.queue) do
            local el, st = plan.queue[i].el, elements[plan.queue[i].el]
            for _, f in ipairs(el.recruits or {}) do
                if f == fam and st then
                    if i == 1 then plan.pull = true end
                    return el, st
                end
            end
        end
        return
    end
    for _, el in ipairs(M and M.elements or {}) do
        local st = elements[el]
        if el.recruits and st and element_on(el) and (st.active or 0) < 1 then
            for _, f in ipairs(el.recruits) do
                if f == fam and (st.wait_since or st.next - now < (el.recruit_soon or 120)) then return el, st end
            end
        end
    end
end
-- The director: one of the cast, a while on a screen, goes on to its next act: a scene here that
-- can use it is called (it takes it over: el.recruits), or it goes on as itself - its own act
-- (the lumberjack turns into the werewolf, the zombie sniffs about...). Not while a scene is on.
-- w: the wanderer (or frog); true if something's on next
local SWAPS = { witch = "princess", princess = "witch" }
local MORPH_CHANCE = { witch = 0.85, princess = 0.3, vampire = 0.3, princess_vampire = 0.25 }
local function witch_el()
    for _, el in ipairs(M and M.elements or {}) do if el.type == "witch" then return el end end
end
local function may_be(fam)                 -- one of the cast may turn into fam: none about, room here
    local n, same = chars_here(fam)
    return not same and not room.taken["chr:" .. fam] and n <= 2
end
local TUNNEL = { skeleton = true, zombie = true, princess_zombie = true }     -- (cast that go about under the ground)
-- the princess turned by one she meets (the princess element's el.turns: werewolf, zombie, vampire
-- → a sprite): a she-wolf, a zombie, a vampire - she goes (runs off, digs herself in), see spawn.wanderer
local TURNED = { werewolf = "princess_wolf", zombie = "princess_zombie", vampire = "princess_vampire" }
local DOOMED = { princess_wolf = true, princess_zombie = true, princess_vampire = true }
local function princess_el()
    for _, el in ipairs(M and M.elements or {}) do if el.type == "princess" then return el end end
end
local function turned_sprite(kind)
    local el = princess_el()
    local sp = el and el.turns and M.sprites[el.turns[kind] or ""]
    if sp and sp.clips and sp.clips.walk and sp.clips.idle and sp.origin and sp.unit then return sp end
end
local function frog_sprite()
    local el = princess_el()
    local fr = el and M.sprites[el.frog or ""]
    if fr and fr.clips and fr.clips.hop and fr.clips.sit and fr.origin and fr.unit then return fr end
end
local OWN_ACT = { zombie = true, frankenstein = true, werewolf = true, performer = true }
local function next_act(w)
    if not M or w.busy then return false end
    local fam = w.family or (w.frog and "frog")
    local now = mp.get_time()
    -- (the witch only once she's done something: cooked, or been the princess - or no cooking
    -- came her way a while: she doesn't hang about, keeping the others away)
    local may_go = fam ~= "witch" or w.cooked or w.was_pr or (w.age or 0) > 45
    if w.morph and (w.force_morph or (may_go and math.random() < (MORPH_CHANCE[fam] or 0))) then    -- a spell on herself
        local opts = {}
        local wel = witch_el()
        if fam == "witch" then
            local pr = wel and M.sprites[wel.princess or ""]
            if pr and may_be("princess") then opts[#opts + 1] = { "person", pr, "princess" } end
            local rv = wel and M.sprites[wel.raven or ""]
            if rv and rv.clips and rv.clips.fly and rv.clips.sit and rv.origin then opts[#opts + 1] = { "raven", rv } end
            if hooks.cat_free and hooks.cat_free() then opts[#opts + 1] = { "cat" } end
        elseif fam == "princess" then
            local ws = wel and M.sprites[wel.sprite or ""]
            if ws and may_be("witch") then opts[#opts + 1] = { "person", ws, "witch" } end
            -- (not a frog by her own spell: by a frog's kiss, or the witch's - see hooks.MEETS)
        elseif (fam == "vampire" or fam == "princess_vampire") and hooks.bat_sprite() and #free_ids > 0 then
            opts[#opts + 1] = { "bat", hooks.bat_sprite() }              -- (the vampires: a bat)
        end
        if w.force_morph then                     -- (preview key y)
            local keep = {}
            for _, o in ipairs(opts) do if o[1] == w.force_morph or o[3] == w.force_morph then keep[#keep + 1] = o end end
            opts, w.force_morph = keep, nil
        end
        if #opts > 0 then
            local o = opts[math.random(#opts)]
            w.morph(o[1], o[2], o[3])
            msg.verbose("cast: the " .. fam .. " casts a spell on " .. (fam == "vampire" and "himself" or "herself") .. " (" .. (o[3] or o[1]) .. ")")
            return true
        end
    end
    local other = SWAPS[fam]                  -- the witch and the princess both here: now and then
    if other and w.swap_into and not w.swap and math.random() < 0.5 then     -- they turn into each other
        local o = cast_here(other, w)
        if o and o.swap_into and not o.swap and not o.called then
            local at = now + rnd(1.8, 2.4)
            w.swap_into(o.spr, other, at)
            o.swap_into(w.spr, fam, at)
            msg.verbose("cast: the " .. fam .. " and the " .. other .. " - a spell on each other")
            return true
        end
    end
    if floor_busy() then return false end
    local options = {}
    for _, el in ipairs(M.elements) do
        local st = elements[el]
        if st and element_on(el) and (st.active or 0) < 1
                and (el.type ~= w.from or (w.here_t or 0) > 30) then   -- (not straight back where it came from)
            local calls = false
            for _, f in ipairs(el.recruits or {}) do if f == fam then calls = true end end
            if calls and not (has_group(groups_of(el), "walker") and no_room_for(el)) then
                options[#options + 1] = { el = el, st = st }
            elseif OWN_ACT[el.type] and family_of(el) == fam and el.sprite == w.spr.name then
                options[#options + 1] = { el = el, st = st, own = true }
            end
        end
    end
    if #options == 0 then
        msg.verbose("cast: nothing on for the " .. tostring(fam))
        return false
    end
    local o = options[math.random(#options)]
    if o.own then
        if #free_ids < 2 then return false end
        local b = spawn[o.el.type](o.el, w.spr, { dir = w.facing or 1, at = w.cx, hops = 0 })
        if not b or #free_ids < (b.layers or 1) then
            if b and b.release then b.release() end
            msg.verbose("cast: the " .. fam .. " can't go on as itself (" .. o.el.type .. ")")
            return false
        end
        adopt(b, o.el, { hops = 0 })
        w.gone = true
        msg.verbose("cast: the " .. fam .. " goes on as itself (" .. o.el.type .. ")")
    else
        o.st.next, o.st.force = now, true
        w.called = { st = o.st, t = now }
        msg.verbose("cast: the " .. fam .. " - on to the " .. o.el.type)
    end
    return true
end
-- (in a wanderer's or frog's update) time for its next act? call it
local function cast_cue(w, dt, x)
    local now = mp.get_time()
    w.here_t = (w.here_t or 0) + dt
    w.next_at = w.next_at or rnd(5, 18)
    if w.called then
        if now - w.called.t > 1 then                  -- (it didn't take: not forced later on)
            w.called.st.force, w.called = nil, nil
            w.next_at = w.here_t + rnd(15, 30)
        end
        return
    end
    if w.here_t > w.next_at and x > 0.12 * W and x < 0.88 * W and (w.ttl or 1) > 0 then
        if not next_act(w) then w.next_at = w.here_t + rnd(8, 20) end
    end
end

local new_pumpkin, lying_pumpkin     -- (lying pumpkins, see below)
local function hop_at(p, x0, x1, y0, y1, high)   -- along a hop at p (0..1 of the clip): x, dy
    local q = clamp((p - 0.2) / 0.65, 0, 1)        -- (airborne between crouch and landing)
    return x0 + (x1 - x0) * ease(q), y0 + (y1 - y0) * q - high * math.sin(math.pi * q)
end
-- witch: walks in, faces the viewer and conjures up her cauldron (a puff: it's there, bubbling),
-- stirs it (from behind), cackles, stirs on - and out of the brew a frog jumps. It sits, croaks
-- at her; she zaps it (and misses), it hops off to the screen next door (hopper). A cackle
-- anyway, the cauldron goes in another puff and she walks back off. Or (el.pumpkin, now and
-- then) in a puff a living pumpkin-head stands in the pot: it jumps out, dances, she cackles at
-- her creation and it walks off to the screen next door (a passer there). Layers, bottom to top: the
-- witch (behind the pot), the pot, the frog (in it: hidden by the front), the pot's front.
-- Planned coming in from the left, mirrored half the time.
function spawn.witch(el, spr)
    local S = M.sprites
    local back, front, frog = S[el.back or ""], S[el.front or ""], S[el.frog or ""]
    local C, P, F = spr.clips, back and back.clips, frog and frog.clips
    if not (C and C.walk and C.stir and C.cast and C.cackle and P and P.appear and P.bubble and P.splash
            and P.vanish and front and F and F.sit and F.hop and spr.origin and spr.unit
            and back.origin and front.origin and frog.origin) then
        return nil
    end
    local u = spr.unit * H
    if W < 12 * u then return nil end
    local a = { el = el, spr = spr, layers = 5, scene = true }
    local d = math.random() < 0.5 and 1 or -1
    -- the cast about here taken over: the witch starts where she is; or a princess, who turns
    -- into the witch in a puff. Now and then she turns into the princess at the end (and goes on so).
    local pr = S[el.princess or ""]
    if not (pr and pr.clips and pr.clips.walk and pr.clips.idle and pr.clips.turn_front and pr.clips.turn_side
            and pr.origin) then pr = nil end
    local her = cast_here("witch")
    local was = not her and pr and cast_here("princess") or nil
    local who = her or was
    if who then d = who.facing or 1 end
    local to_pr = false
    if pr and not was and math.random() < (el.princess_chance or 0.25) then
        local _, same = chars_here("princess")
        to_pr = not same and not room.taken["chr:princess"] and not taken(pr)
    end
    if to_pr then a.also = { "princess" } end
    a.recruited = { who }
    local cx = free_scene_x(math.max(W * 0.3, 3.5 * u), math.min(W * 0.55, W - 5 * u), d)
    a.spot = d > 0 and cx or W - cx               -- (its place: kept for it)
    local swap = 0.4                                   -- (where the pot comes/goes in its puff)
    local rim_y = -0.58 * u                            -- the frog's feet in the pot (below the rim)

    -- the plan: the witch's steps (walk to, a clip once or for dur, facing m); on = what starts
    -- with a step (the pot's clip, the frog), wait = it lasts until this is true
    local X0 = who and ((d > 0) and who.cx or (W - who.cx)) or -1.2 * u
    local steps, X, face = {}, X0, 1
    local function add(s) steps[#steps + 1] = s; return s end
    local function turn(f)
        if f == face then return end
        if face ~= 0 and C.turn_front then add { clip = "turn_front", m = face < 0 } end
        if f ~= 0 and C.turn_side then add { clip = "turn_side", m = f < 0 } end
        face = f
    end
    local function go(to)
        turn(to > X and 1 or -1)
        add { clip = "walk", to = to, m = face < 0 }
        X = to
    end
    local function stop(clip, dur, f, s)
        turn(f or 0)
        s = s or {}
        s.clip, s.dur, s.m, s.act = clip, dur, face < 0, true
        return add(s)
    end

    local pk = S[el.pumpkin or ""]
    local K = pk and pk.clips
    if not (K and K.jump and K.walk and K.idle and pk.origin) then pk = nil end
    -- pot: {clip, t}; the frogs' own little plays (one or two), the pumpkin-head's
    local pot = nil
    local frogs = { { state = "hidden", land = 2.2 * u }, { state = "hidden", land = 3.3 * u } }
    local ph = { state = "hidden" }
    local function pot_clip(c) return function() pot = { clip = c, t = 0 } end end
    local zap
    -- a pumpkin lying about here (el.carriage): she beckons it, it rolls over and jumps into the
    -- pot - and in a big puff there stands a carriage, mice and all, that drives off (spawn.carriage)
    local cs = S[el.carriage or ""]
    if not (cs and cs.clips and cs.clips.drive and cs.clips.stand and cs.origin) then cs = nil end
    local lp = cs and pk and lying_pumpkin(pk) or nil
    local few = room_frogs() < FEW_FROGS                -- (frogs wanted: more of them, fewer other brews)
    if lp and (lp.ttl < 30 or math.random() >= (el.carriage_chance or 0.5) * (few and 0.4 or 1)) then lp = nil end
    local car = { state = "hidden" }                 -- roll | jump | in | stand | drive | away | gone
    if lp then lp.taken = true end
    -- no one here to be her: now and then she comes as a raven, flying in fast - down, a puff, the witch
    local rv = S[el.raven or ""]
    if not who and rv and rv.clips and rv.clips.fly and rv.clips.sit and rv.origin
            and (el.raven_force or math.random() < (el.raven_in or 0.4)) then
        X, el.raven_force = cx - 2.4 * u, nil
        add { sp = rv, clip = "fly", to = X, v = 0.45 * W, fly = -2.2 * u, m = false, log = "witch: a raven flies in, fast" }
        add { sp = rv, clip = "sit", dur = rnd(0.5, 0.9), m = false }
        add { clip = "idle", dur = 1.0, puff = true, log = "witch: ...in a puff, the raven is the witch" }
        face = 0
    end
    if was then                                       -- the princess: a look round, a puff, the witch
        add { sp = pr, clip = "turn_front", m = false, log = "witch: the princess..." }
        add { sp = pr, clip = "idle", dur = rnd(0.8, 1.5) }
        add { clip = "idle", dur = 1.0, puff = true, log = "witch: ...in a puff, she's the witch" }
        face = 0
        stop("cackle", nil, 0)
    end
    go(cx - 2.4 * u)
    stop("cast", nil, 0, { on = pot_clip("appear") })
    stop("idle", rnd(0.8, 1.5))
    go(cx - 0.4 * u)                                -- (behind the pot: it hides her skirt)
    stop("stir", rnd(4, 7), 1)
    stop("cackle", nil, 0)
    stop("stir", rnd(2.5, 4), 1)
    -- the brew: a frog or the pumpkin-head - now and then two things (a frog and the pumpkin-head,
    -- or two frogs), one after the other
    local function brew_pumpkin()
        stop("idle", 1.0, 0, { on = function() pot = { clip = "poof", t = 0 } ph.state, ph.t = "pop", 0 end })
        stop("idle", 0.5, 1, { wait = function() return ph.state == "dance" end })
        stop("cackle", nil, 0)
        stop("idle", 0.5, 1, { wait = function() return ph.state == "off" or ph.state == "gone" end })
    end
    local function brew_frog(f)
        stop("idle", 1.0, 0, { on = function() pot = { clip = "splash", t = 0 } f.state, f.t = "peek", 0 end })
        stop("idle", 0.5, 1, { wait = function() return f.state == "sit" or f.state == "croak" end })
        stop("idle", 0.5, 1, { wait = function() return f.state == "sit" and f.croaked end })
        stop("cast", nil, 1, { on = function() zap = { t = 0, f = f } end })
        stop("idle", rnd(1, 2), 1)
    end
    local first = (pk and math.random() < (el.pumpkin_chance or 0.4) * (few and 0.5 or 1)) and "pumpkin" or "frog"
    local second = nil
    if math.random() < (few and 0.55 or el.double_chance or 0.3) then
        second = (first == "pumpkin" or not pk or math.random() < 0.5) and "frog" or "pumpkin"
    end
    if lp then first, second = "carriage", nil end
    if first == "carriage" then
        stop("cast", nil, 0, { on = function() car.state = "roll" end, log = "witch: beckons a pumpkin..." })
        stop("idle", 0.5, 0, { wait = function() return car.state == "in" end })
        stop("stir", rnd(1.5, 2.5), 1)
        stop("cast", nil, 0, { on = function() car.state, car.t, pot = "pop", 0, { clip = "vanish", t = 0 } end,
                               log = "witch: ...and in a big puff, a carriage" })
        stop("cackle", nil, 0)
        stop("idle", 0.5, 0, { wait = function() return car.state == "away" or car.state == "gone" end })
    elseif first == "pumpkin" then brew_pumpkin() else brew_frog(frogs[1]) end
    if second then
        stop("stir", rnd(2, 3.5), 1, { log = "witch: and there's more in the brew" })
        if second == "pumpkin" then brew_pumpkin() else brew_frog(first == "frog" and frogs[2] or frogs[1]) end
    end
    if first ~= "carriage" then
        stop("cackle", nil, 0)
        stop("idle", rnd(0.8, 1.5), 1)
        stop("cast", nil, 0, { on = pot_clip("vanish") })
        stop("idle", 0.6)
    end
    local vanish = not to_pr and math.random() < (el.vanish_chance or 0.45)     -- (she's cooked: may go now)
    if vanish then                                    -- a spell on herself: gone in a puff
        stop("cackle", nil, 0)
        stop("cast", nil, 0, { log = "witch: casts a spell on herself..." })
        add { clip = "idle", dur = 1.4, puff = true, hide = true, log = "witch: ...and she's gone" }
    elseif to_pr then                                     -- a spell on herself: the princess, off she goes
        stop("cast", nil, 0, { log = "witch: casts a spell on herself..." })
        add { sp = pr, clip = "idle", dur = 1.2, puff = true, log = "witch: ...and she's a princess" }
        if pr.clips.cheer then add { sp = pr, clip = "cheer", act = true } end
        add { sp = pr, clip = "turn_side", m = true }
        add { sp = pr, clip = "walk", to = -1.5 * u, m = true, out = "princess" }
    else
        go(-1.5 * u)
        steps[#steps].out = "witch"      -- (and on as one of the cast)
    end

    local si, tc = 1, 0
    local wx = X0
    local puffs = {}
    a.line = pick_line(el)
    for _, f in ipairs(frogs) do f.fa = { el = el, spr = frog, groups = {}, hops = 0 } end   -- (for walk_out)
    local function place(sp, x, frame, mirror, dy)
        local m = (mirror and true or false) ~= (d < 0)
        local ox = m and (sp.w - sp.origin[1]) or sp.origin[1]
        return { spr = sp, frame = frame, variant = m, x = ((d > 0) and x or (W - x)) - ox, y = H - sp.origin[2] + dy }
    end
    local function scr(x) return (d > 0) and x or (W - x) end
    local function frame_of(c, t, rate)
        local k = math.floor(t * c.fps * (rate or 1))
        if c.loop then return c.start + k % c.count end
        return c.start + math.min(k, c.count - 1)
    end

    local function frog_step(f, dt)
        f.t = (f.t or 0) + dt
        local hop = F.hop.count / F.hop.fps
        if f.state == "peek" then                      -- eyes over the rim, a look about
            f.x, f.dy, f.clip = cx, rim_y - 0.14 * u * clamp(f.t / 0.4, 0, 1), "sit"
            if f.t > 1.4 then f.state, f.t, f.x0, f.y0 = "out", 0, cx, f.dy end
        elseif f.state == "out" then                   -- out over the rim, down beside the pot
            f.clip = "hop"
            f.x, f.dy = hop_at(f.t / hop, f.x0, cx + f.land, f.y0, 0, 1.4 * u)
            if f.t >= hop then f.state, f.t = "sit", 0 msg.verbose("witch: a frog out of the brew") end
        elseif f.state == "sit" then
            f.clip, f.dy = "sit", 0
            if not f.croaked and f.t > 1.0 and F.croak then f.state, f.t = "croak", 0 end
        elseif f.state == "croak" then
            f.clip = "croak"
            if f.t >= F.croak.count / F.croak.fps * 2 then f.state, f.t, f.croaked = "sit", 0, true end
        elseif f.state == "away" then                  -- hops off (and over to the screen next door)
            f.clip = "hop"
            f.rate = 1.3
            f.x, f.dy = hop_at(f.t / hop * 1.3, f.x0, f.x0 + 1.3 * u, 0, 0, 0.6 * u)
            if f.t >= hop / 1.3 then f.x0, f.t = f.x0 + 1.3 * u, 0 end
            if f.t < dt then f.x = f.x0 end
            walk_out(f.fa, scr(f.x), d, 0.3 * u, { kind = "hopper", unique = false, hops = 0, from = el.type,
                                                ttl = math.floor(rnd(range(el.cast_ttl, 180))) })
            if f.x > W + 0.6 * u then f.state = "gone" end
        end
    end

    -- the pumpkin-head: there in the puff (at its biggest), standing in the pot; a jump out, a
    -- look at the viewer, a dance, and off (and over to the screen next door)
    local pa = pk and { el = el, spr = pk, groups = {}, hops = 0 }
    local function pumpkin_step(dt)
        local f = ph
        f.t = (f.t or 0) + dt
        local function len(c) return K[c].count / K[c].fps end
        if f.state == "pop" then
            f.x, f.dy, f.clip, f.m = cx, rim_y, "idle", false
            f.show = f.t >= swap * P.poof.count / P.poof.fps
            if f.t > 1.6 then f.state, f.t, f.x0, f.y0 = "out", 0, cx, f.dy end
        elseif f.state == "out" then
            f.clip = "jump"
            f.x, f.dy = hop_at(f.t / len("jump"), f.x0, cx + 2.4 * u, f.y0, 0, 1.2 * u)
            if f.t >= len("jump") then
                f.state, f.t = "look", 0
                msg.verbose("witch: a living pumpkin-head out of the brew")
            end
        elseif f.state == "look" then
            f.clip = K.turn_front and f.t < len("turn_front") and "turn_front" or "idle"
            if f.t > 1.5 then f.state, f.t, f.dance = "dance", 0, (K.taunt and math.random() < 0.5) and "taunt" or "cheer" end
        elseif f.state == "dance" then
            f.clip = K[f.dance] and f.dance or "idle"
            if f.t >= (K[f.dance] and len(f.dance) or 2) then f.state, f.t = "turn", 0 end
        elseif f.state == "turn" then
            -- (off towards a screen next door: on past the witch if there's none ahead)
            if not f.pd then
                local ahead, back = (d > 0) and "right" or "left", (d > 0) and "left" or "right"
                f.pd = (room[ahead] or not room[back]) and 1 or -1
            end
            f.clip, f.m = K.turn_side and "turn_side" or "idle", f.pd < 0
            if f.t >= (K.turn_side and len("turn_side") or 0.3) then f.state, f.t = "off", 0 end
        elseif f.state == "off" then
            f.clip = "walk"
            f.x = f.x + f.pd * K.walk.stride_px * K.walk.fps / K.walk.count * dt
            walk_out(pa, scr(f.x), d * f.pd, 0.5 * u, { kind = "wanderer", fam = "pumpkinhead", unique = false, hops = 0, from = el.type,
                                                       ttl = math.floor(rnd(range(el.cast_ttl, 180))) })
            if f.x > W + 1.5 * u or f.x < -1.5 * u then f.state = "gone" end
        end
    end

    -- the pumpkin rolling over (screen x), jumping in; the carriage (plan x: its door)
    local Hd = pk and pk.clips.head
    local ca = cs and { el = el, spr = cs, groups = {}, hops = 0 }
    local function carriage_step(dt)
        local f = car
        f.t = (f.t or 0) + dt
        if f.state == "roll" then                   -- (bouncing along: little hops)
            if not f.x then
                f.x, f.t = scr(lp.cx), 0
                lp.gone = true
            end
            f.to = f.to or ((f.x > cx) and cx + 1.5 * u or cx - 1.6 * u)    -- (beside the pot, its side)
            local to = f.to
            local step = 0.6 * u
            local dir = to > f.x and 1 or -1
            f.x0 = f.x0 or f.x
            local p = f.t / 0.35
            f.x = f.x0 + dir * step * math.min(p, 1)
            f.dy = -0.18 * u * math.sin(math.pi * math.min(p, 1))
            if p >= 1 then
                f.x0, f.t = f.x, 0
                if math.abs(to - f.x) < step then f.state, f.t, f.x0, f.y0 = "jump", 0, f.x, 0 end
            end
        elseif f.state == "jump" then               -- (up and over the rim, in)
            f.x, f.dy = hop_at(math.min(f.t / 0.9, 1), f.x0, cx, 0, rim_y + 0.3 * u, 1.8 * u)
            if f.t >= 0.9 then
                f.state, f.t = "in", 0
                pot = { clip = "splash", t = 0 }
                msg.verbose("witch: the pumpkin jumps into the pot")
            end
        elseif f.state == "pop" then
            if f.t >= swap * P.vanish.count / P.vanish.fps then
                f.state, f.t, f.x = "stand", 0, cx + 1.3 * u     -- (clear of her, behind the pot)
                for _ = 1, 14 do
                    puffs[#puffs + 1] = { x = scr(f.x + rnd(-1.2, 2.6) * u), y = H - rnd(0.2, 2.0) * u,
                                          r = rnd(0.35, 0.6) * u, vx = rnd(-0.5, 0.5) * u, t = 0 }
                end
            end
        elseif f.state == "stand" then
            if f.t > 1.8 then f.state, f.t = "drive", 0 end
        elseif f.state == "drive" then              -- (off over the screens: a few along)
            local c = cs.clips.drive
            f.x = f.x + c.stride_px * c.fps / c.count * dt
            walk_out(ca, scr(f.x), d, 2.7 * u, { kind = "carriage", unique = false, hops = 0, from = el.type,
                                                legs = math.random(0, 2) })
            if f.x > W + 1.4 * u then f.state = "away" end
        end
    end

    -- one of the cast walking by her pot (while it's there): up in smoke, and out of it someone else
    -- (one not about: the room evens out), or a frog (most likely when frogs are few)
    local function pot_poof(b)
        local fr = frog_sprite()
        local function frog()
            b.morphing = { kind = "frog", at = mp.get_time(), sp = fr }
            msg.verbose("witch: the " .. tostring(b.family) .. " by her pot - up in smoke, a frog")
        end
        if fr and #free_ids > 0 and math.random() < (room_frogs() < FEW_FROGS and 0.5 or 0.2) then return frog() end
        local opts = {}
        for _, r in ipairs(el.riders or {}) do
            local sp = M.sprites[r.sprite or ""]
            if sp and sp.clips and sp.clips.walk and sp.clips.idle and sp.origin and sp.unit and r.family ~= b.family
                    and may_be(r.family) and not taken(sp) then opts[#opts + 1] = { sp, r.family } end
        end
        if #opts == 0 then                 -- (all the others about: a frog then)
            if fr and #free_ids > 0 then frog() end
            return
        end
        local o = opts[math.random(#opts)]
        b.swap = { spr = o[1], fam = o[2], at = mp.get_time() }
        msg.verbose("witch: the " .. tostring(b.family) .. " by her pot - up in smoke, the " .. o[2])
    end
    function a.update(dt, t)
        if pot then
            local px = scr(cx)
            for _, b in ipairs(actors) do
                if b ~= a and b.family and b.swap_into and not b.swap and not b.morphing and not b.doomed and not b.called
                        and not b.potted and b.cx and math.abs(b.cx - px) < 0.9 * u then
                    b.potted = true
                    if math.random() < (el.pot_poof or 0.7) then pot_poof(b) end
                end
            end
        end
        local s = steps[si]
        if not s then                    -- (she's gone; her frog or pumpkin-head still on its way off)
            local busy = ph.state == "off"
            for _, f in ipairs(frogs) do if f.state == "away" then busy = true end end
            if car.state == "drive" then busy = true end
            if not busy then return false end
            s = { clip = "idle", gone = true }
        end
        if si ~= a.logged then
            a.logged, s.x0 = si, wx
            if s.on then s.on() end
            if s.log then msg.verbose(s.log) end
            if s.puff then
                for _ = 1, 8 do
                    puffs[#puffs + 1] = { x = scr(wx) + rnd(-0.5, 0.5) * u, y = H - rnd(0.2, 1.8) * u,
                                          r = rnd(0.25, 0.45) * u, vx = rnd(-0.5, 0.5) * u, t = 0 }
                end
            end
        end
        tc = tc + dt
        local sp = s.sp or spr
        local c = sp.clips[s.clip] or sp.clips.walk
        local done
        if s.to then
            local v = s.v or c.stride_px * c.fps / c.count * (el.speed or 1.0)
            local dir = s.to > wx and 1 or -1
            wx = wx + dir * v * dt
            if (dir > 0 and wx >= s.to) or (dir < 0 and wx <= s.to) then wx, done = s.to, true end
            if s.out then
                walk_out(a, scr(wx), dir * d, 0.5 * u, { kind = "wanderer", fam = s.out, sprite = sp.name, unique = false, from = el.type,
                                                        hops = 0, ttl = math.floor(rnd(range(el.cast_ttl, 180))),
                                                        cooked = s.out == "witch" or nil })
            end
        else
            done = tc >= (s.dur or c.count / c.fps)
        end
        if done and s.wait and not s.wait() then done = false end
        if zap then
            zap.t = zap.t + dt
            local f = zap.f
            if zap.t > 0.35 and f.state == "sit" then
                f.state, f.t, f.x0 = "away", 0, f.x
                msg.verbose("witch: zaps the frog - missed, it hops off")
            end
            if zap.t > 0.8 then zap = nil end
        end
        for _, f in ipairs(frogs) do
            if f.state ~= "hidden" and f.state ~= "gone" then frog_step(f, dt) end
        end
        if ph.state ~= "hidden" and ph.state ~= "gone" then pumpkin_step(dt) end
        if car.state ~= "hidden" and car.state ~= "away" and car.state ~= "gone" then carriage_step(dt) end

        local keep = {}
        for _, q in ipairs(puffs) do
            q.t, q.x, q.y = q.t + dt, q.x + q.vx * dt, q.y - 0.5 * u * dt
            if q.t < 1.2 then keep[#keep + 1] = q end
        end
        puffs = keep
        local layers = {}
        local fy = 0                         -- (flying in: high up at first, down to the ground)
        if s.fly and s.x0 and s.to ~= s.x0 then fy = s.fly * (1 - ease(clamp((wx - s.x0) / (s.to - s.x0), 0, 1))) end
        local l = place(sp, wx, frame_of(c, tc), s.m, fy)
        a.sx, a.sy, a.cx = l.x, l.y, scr(wx)
        if not (s.puff and tc < 0.25) and not s.gone and not s.hide then layers[1] = l end     -- (the change, in the puff)
        if pot then
            pot.t = pot.t + dt
            local pc = P[pot.clip]
            local n = math.floor(pot.t * pc.fps)
            if not pc.loop and n >= pc.count then
                if pot.clip == "vanish" then pot = nil else pot = { clip = "bubble", t = 0 } end
            end
            if pot then
                pc = P[pot.clip]
                layers[2] = place(back, cx, frame_of(pc, pot.t), false, 0)
                local hidden = (pot.clip == "appear" and pot.t * pc.fps < swap * pc.count)
                        or (pot.clip == "vanish" and pot.t * pc.fps >= swap * pc.count)
                if not hidden then layers[5] = place(front, cx, front.clips and front.clips.front and front.clips.front.start or 0, false, 0) end
            end
        end
        -- (in the pot, only while it rises: below the front's top edge the pot's body is in front)
        for i, f in ipairs(frogs) do
            if f.x and f.state ~= "gone" and f.state ~= "hidden" and F[f.clip] then
                layers[2 + i] = place(frog, f.x, frame_of(F[f.clip], f.t, f.rate), false, f.dy)
            end
        end
        if ph.x and ph.state ~= "gone" and (ph.show or ph.state ~= "pop") and K[ph.clip] then
            layers[4] = place(pk, ph.x, frame_of(K[ph.clip], ph.t), ph.m, ph.dy)
        end
        if car.x and (car.state == "roll" or car.state == "jump") then
            local h0 = Hd.track.head[1]
            layers[4] = { spr = pk, frame = Hd.start, variant = false, x = scr(car.x) - h0[1] - pk.origin[1],
                          y = H - pk.origin[2] - 0.34 * u - h0[2] + car.dy }
        elseif car.state == "stand" or car.state == "drive" then
            local cc = cs.clips[car.state]
            layers[3] = place(cs, car.x, frame_of(cc, car.t), false, 0)
        end
        a.talking = a.line and s.act and true or false
        if a.talking and not a.say_t then a.say_t = t end
        if done then si, tc = si + 1, 0 end
        return true, layers
    end
    function a.ass(out)
        for _, q in ipairs(puffs) do puff(out, q.x, q.y, q.r * (1 + 0.6 * q.t), 0.2 + 0.8 * q.t / 1.2) end
        if not (zap and zap.t < 0.5 and zap.f.x) then return end
        local hx, hy = scr(wx + 0.45 * u), H - 1.35 * u
        local fx = scr(zap.f.x + (zap.t > 0.35 and 0.6 or 0) * u)
        spark(out, hx, hy, fx, H - 0.25 * u, "&HFF60E0&", 3)
    end
    return a
end

-- The frogs' pile: a frog of the cast with time to wait raises a pile of pumpkins (el.pile, on
-- the frogs element: its sprites) near a side of the screen and jumps up onto it; up to three sit
-- there (croaking, looking round) till a scene takes one over or their time's up (a hop down and
-- off). Empty a while, it sinks. The sitters are its layers (above it); cast_here finds them.
local PILE_SLOTS = { { 0, 0.84 }, { -0.3, 0.66 }, { 0.3, 0.66 } }    -- (on top: x from the middle, y up, of its size)
local function pile_sprite()
    for _, el in ipairs(M and M.elements or {}) do
        if el.pile then
            local list = type(el.pile) == "table" and el.pile or { el.pile }
            return M.sprites[list[math.random(#list)] or ""], el
        end
    end
end
local function pile_here()
    for _, a in ipairs(actors) do if a.pile and not a.sinking then return a end end
end
local spawn_hopper
local function new_pile(el, near_x)
    local spr, pel = pile_sprite()
    if not spr or #free_ids < 1 + #PILE_SLOTS then return nil end
    local px = (near_x < W / 2) and 0.2 * W or 0.8 * W
    local a = { el = pel or el, spr = spr, layers = 1 + #PILE_SLOTS, groups = {}, pile = true, sitters = {} }
    local rise, empty_t, t0 = 0, 0, 0
    -- a free spot on top: its index (reserved), screen x, height above the ground
    function a.slot()
        for k = 1, #PILE_SLOTS do
            if not a.sitters[k] then
                a.sitters[k] = { reserved = true }
                return k, px + PILE_SLOTS[k][1] * spr.w, PILE_SLOTS[k][2] * spr.h
            end
        end
    end
    function a.unreserve(k) if a.sitters[k] and a.sitters[k].reserved then a.sitters[k] = nil end end
    function a.sit(k, f)          -- f: {spr, ttl, from, facing}
        local sx, sy = px + PILE_SLOTS[k][1] * spr.w, PILE_SLOTS[k][2] * spr.h
        a.sitters[k] = { spr = f.spr, ttl = f.ttl, from = f.from, facing = f.facing, frog = true, cx = sx, dy = -sy,
                         t = 0, croak = rnd(2, 6), look = rnd(4, 10) }
    end
    function a.list()             -- (for cast_here)
        local l = {}
        for k = 1, #PILE_SLOTS do
            local f = a.sitters[k]
            if f and not f.reserved and not f.gone then l[#l + 1] = f end
        end
        return l
    end
    function a.update(dt, t)
        t0 = t0 + dt
        local busy = false
        local layers = {}
        if a.sinking then rise = math.max(0, rise - dt / 1.2) else rise = math.min(1, rise + dt / 1.0) end
        local dy = (1 - ease(rise)) * (spr.h + 4)
        layers[1] = { spr = spr, frame = 0, variant = false, x = px - spr.w / 2, y = H - spr.h + dy }
        for k = 1, #PILE_SLOTS do
            local f = a.sitters[k]
            if f and f.gone then a.sitters[k], f = nil, nil end
            if f then busy = true end
            if f and not f.reserved then
                f.t, f.ttl = f.t + dt, (f.ttl or 0) - dt
                if f.ttl <= 0 and not f.called then              -- (time's up: down and off)
                    local dir = (f.cx < W / 2) and -1 or 1
                    if spawn_hopper and #free_ids > 0 then
                        local b = spawn_hopper(f.el or a.el, f.spr, { dir = dir, at = f.cx, y0 = f.dy, ttl = 0, hops = 0 })
                        if b then adopt(b, a.el, { hops = 0 }) end
                    end
                    a.sitters[k] = nil
                else
                    cast_cue(f, dt, f.cx)
                    local F = f.spr.clips
                    local clip, k2 = "sit", nil
                    if f.t >= f.look then f.facing, f.look = -(f.facing or 1), f.t + rnd(5, 12) end
                    if F.croak and f.t >= f.croak then
                        local len = F.croak.count / F.croak.fps * 2
                        if f.t < f.croak + len then
                            clip, k2 = "croak", math.floor((f.t - f.croak) * F.croak.fps) % F.croak.count
                        else f.croak = f.t + rnd(5, 14) end
                    end
                    local c = F[clip]
                    k2 = k2 or math.floor(f.t * c.fps) % c.count
                    local mi = (f.facing or 1) < 0
                    local ox = mi and (f.spr.w - f.spr.origin[1]) or f.spr.origin[1]
                    layers[1 + k] = { spr = f.spr, frame = c.start + k2, variant = mi, x = f.cx - ox,
                                      y = H - f.spr.origin[2] + f.dy + dy }
                end
            end
        end
        if busy then empty_t = 0 else empty_t = empty_t + dt end
        if not a.sinking and empty_t > 15 then a.sinking = true end
        if a.sinking and rise <= 0 then
            for k = 1, #PILE_SLOTS do if a.sitters[k] and not a.sitters[k].reserved then return true, layers end end
            return false
        end
        a.cx = px
        return true, layers
    end
    adopt(a, a.el, { hops = 0 })
    msg.verbose("frogs: a pile of pumpkins to sit on")
    return a
end

-- hopper: a frog (the witch's, the vampire kissed), hopping over from the screen next door: across
-- (a croak on the way, now and then) and on. With h.ttl it's one of the cast: it stays about that
-- long (turning back where it can't go on), and mostly makes for the pile of pumpkins (see above)
-- to sit and wait. h.y0: it starts up there (off the pile).
function spawn.hopper(el, spr, h)
    local F = spr.clips
    if not (F and F.hop and F.sit and spr.origin and spr.unit) then return nil end
    local u = spr.unit * H
    local dir = h.dir == 1 and 1 or -1
    local hop = F.hop.count / F.hop.fps / 1.3
    local step = 1.3 * u
    local x = walk_in_x(h, step / hop, 0.3 * u)
    local a = { el = el, spr = spr, layers = 1, groups = {}, floor = true, frog = true, from = h.from }
    a.hops = tonumber(h.hops) or 1
    a.ttl = tonumber(h.ttl)
    if a.ttl then a.hops = 0 end
    local x0, tc, rest = x, 0, math.random() < 0.6 and rnd(0.3, 0.7) * W or nil
    local y0 = tonumber(h.y0)                 -- (the first hop: down from there)
    local resting, linger = nil, 0
    local goal                                -- {pile, k, x, y}: making for a spot on the pile
    local decided = false
    function a.update(dt)
        tc = tc + dt
        if a.ttl then a.ttl = a.ttl - dt end
        local clip, dy = "hop", 0
        local wanted = a.ttl and a.ttl > 0 and linger < 60 and wanted_here("frog", mp.get_time())
        if goal and goal.pile.sinking then goal = nil end
        if resting then
            clip = (F.croak and resting > 1 and resting < 1 + F.croak.count / F.croak.fps * 2) and "croak" or "sit"
            resting = resting + dt
            if wanted then
                linger = linger + dt
                if resting > 7 then resting = 0.5 end         -- (sits on, a croak now and then)
            elseif resting > 4 then resting, tc = nil, 0 end
        else
            local to = x0 + dir * step
            local y1 = 0
            if goal and math.abs(goal.x - x0) <= step * 1.05 then to, y1 = goal.x, -goal.y end   -- (up onto it)
            x, dy = hop_at(tc / hop, x0, to, y0 or 0, y1, 0.6 * u + (y1 < 0 and 0.3 * u or 0))
            if tc >= hop then
                x0, tc, y0 = to, 0, nil
                if goal and to == goal.x then          -- (sitting on the pile now: one of its frogs)
                    goal.pile.sit(goal.k, { spr = spr, ttl = a.ttl, from = a.from, facing = -dir })
                    msg.verbose("frogs: a frog sits on the pile")
                    return false
                end
                if not decided and a.ttl and a.ttl > 20 and x0 > 0.1 * W and x0 < 0.9 * W then
                    decided = true
                    if math.random() < 0.75 then
                        local p = pile_here() or new_pile(el, x0)
                        local k, gx, gy
                        if p then k, gx, gy = p.slot() end
                        if k then
                            goal = { pile = p, k = k, x = gx, y = gy }
                            dir = gx > x0 and 1 or -1
                        end
                    end
                end
                if not goal and ((rest and math.abs(x0 - rest) < step) or (wanted and x0 > 0.2 * W and x0 < 0.8 * W)) then
                    rest, resting = nil, 0
                end
            end
        end
        if not a.ttl then
            walk_out(a, x, dir, 0.3 * u, { kind = "hopper", unique = false })
        elseif a.ttl > 0 and not goal and not resting and ((dir > 0 and x0 + 0.3 * u > W) or (dir < 0 and x0 - 0.3 * u < 0)) then
            if not walk_out(a, x, dir, 0.3 * u, { kind = "hopper", unique = false, ttl = math.floor(a.ttl), hops = 0, from = a.from }) then
                dir, a.handed_on, resting = -dir, nil, 3     -- (no way on there: a moment, and back)
            end
        end
        if (dir > 0 and x > W + 0.6 * u) or (dir < 0 and x < -0.6 * u) then
            if goal then goal.pile.unreserve(goal.k) end
            return false
        end
        if not goal and not resting then cast_cue(a, dt, x) end
        local c = F[clip]
        local k = math.floor((clip == "croak" and resting - 1 or resting or tc) * c.fps * (clip == "hop" and 1.3 or 1))
        k = c.loop and k % c.count or math.min(k, c.count - 1)
        local mi = dir < 0
        local ox = mi and (spr.w - spr.origin[1]) or spr.origin[1]
        local layer = { spr = spr, frame = c.start + k, variant = mi, x = x - ox, y = H - spr.origin[2] + dy }
        a.sx, a.sy, a.cx, a.facing = layer.x, layer.y, x, dir
        return true, { layer }
    end
    function a.release() if goal then goal.pile.unreserve(goal.k) end end
    return a
end
spawn_hopper = spawn.hopper

-- werewolf: a man (a lumberjack) comes in, stops, looks about - and spins round, faster and
-- faster, a puff of fur and he's the wolf, spinning out of it; a howl and on he prowls, over to
-- the screen next door (h.form: as what he goes on). Come in as the wolf he may turn back. A cat
-- coming at him (it arches its back, red eyes, hisses: prowler.lua) frightens the wolf: he
-- flinches, backs off and runs back the way he came. Sprites: el.sprite the man, el.wolf the
-- wolf (same rig and frame). Planned coming in from the left, mirrored half the time.
-- relics: things lying about - a bone (the werewolf's el.bone, tools/bake/bone.py: the wolf came off a
-- fight with a skeleton or the mummy with it in his mouth), Frankenstein's head and limbs (left over
-- when he blew apart). r: {spr, frame, mx, my: its middle in the frame (px, facing right), lie: the
-- middle above the ground, kind: bone, head or limb, piece: of PIECES}. A wolf going by on all fours
-- takes up a bone or a limb; a headless pumpkin-head puts the head on. Left long enough
-- (el.bone_rise), a skeleton climbs up out of the ground where a bone lies (none about, room for
-- one) and the bone's gone; the rest after a while sink away.
local function free_bone(x, reach)          -- a bone or a limb lying here, within reach of x
    for _, b in ipairs(actors) do
        if b.relic and b.relic.kind ~= "head" and b.relic.kind ~= "body" and not b.gone and not b.taken and not b.rising
                and math.abs(b.cx - x) < reach then return b end
    end
end
function hooks.relic_layer(r, cx, cy, m)    -- (r drawn with its middle at cx, cy)
    return { spr = r.spr, frame = r.frame, variant = m, x = cx - (m and (r.spr.w - r.mx) or r.mx), y = cy - r.my }
end
function hooks.bone_relic(B)
    return { spr = B, frame = B.clips.lie.start, mx = B.origin[1], my = B.origin[2] * 0.5, lie = 0.45 * B.origin[2],
             kind = "bone" }
end
local function new_bone(el, r, x, y, m)     -- (x, y: its middle, put down from there)
    local spr = r.spr
    local bone = r.kind == "bone"
    local a = { el = el, spr = spr, layers = 1, groups = {}, relic = r, lying = true, cx = x, t = 0 }
    local lo, hi = range(el.bone_rise, 30)
    local rise_at, sink = rnd(lo, hi or lo), 0
    local tl, th = range(el.relic_ttl, 120)
    a.ttl = bone and 240 or rnd(tl, th or tl)
    local ground = H - r.lie
    function a.update(dt)
        if a.gone then return false end
        a.t, a.ttl = a.t + dt, a.ttl - dt
        if y < ground then y = math.min(ground, y + 3 * spr.h * dt) end     -- (dropped: down on the ground)
        if bone and not a.rising and a.t > rise_at then
            local sk, ce = cast_sprite("skeleton"), cast_el()
            if sk and ce and (a.force or may_be("skeleton")) and #free_ids > 0 then
                local b = spawn.wanderer(ce, sk, { fam = "skeleton", dir = math.random() < 0.5 and 1 or -1, tunnel = 1,
                                                    went = 0, at_x = x, ttl = math.floor(rnd(40, 90)), hops = 0 })
                if b then
                    adopt(b, ce, { hops = 0 })
                    a.rising = a.t
                    msg.verbose("bone: a skeleton comes up out of the ground there")
                end
            end
            if not a.rising then rise_at = a.t + 15 end
        end
        if a.rising and a.t - a.rising > 1.2 then return false end     -- (gone into it, under the ground)
        if a.ttl < 0 and not a.taken then
            sink = sink + dt
            if sink > 1.5 then return false end
        end
        local l = hooks.relic_layer(r, x, y, m)
        l.x = l.x + (a.rising and rnd(-0.04, 0.04) * spr.w or 0)    -- (something stirs under it)
        l.y = l.y + sink / 1.5 * 2.5 * r.lie
        return true, { l }
    end
    adopt(a, el, { hops = 0 })
    msg.verbose("relic: a " .. r.kind .. " lies there")
    return a
end
hooks.new_relic = new_bone

-- The she-wolf (h.she): the princess turned by him (see spawn.wanderer), spr the princess and
-- el.she_wolf her as the wolf. She prowls about on all fours a while (takes up a bone, a limb; a
-- skeleton in her way: a fight), may lie down for a nap; then she spins back into the princess
-- and goes on as herself, one of the cast.
function spawn.werewolf(el, spr, h)
    local she = h and h.she and true or nil
    local wolf = M.sprites[(she and (el.she_wolf or "princess_wolf3d")) or el.wolf or ""]
    local C, Wc = spr.clips, wolf and wolf.clips
    if not (C and C.walk and C.spin and Wc and Wc.walk and Wc.spin and Wc.flinch and Wc.back
            and spr.origin and wolf.origin and spr.unit) then
        return nil
    end
    local u = spr.unit * H
    local a = { el = el, spr = spr, layers = 2, she = she, family = she and "princess_wolf" or nil }
    local d
    local form = (she or (h and h.form == "wolf")) and "wolf" or "man"
    -- the wolf on all fours (walk4, idle4; drop: down onto them, rise: up again - a second or so);
    -- upright for the rest (a howl, the change, lying down)
    local quad = Wc.walk4 and Wc.idle4 and Wc.drop and Wc.rise and true or false
    local B = M.sprites[el.bone or ""]
    if not (B and B.clips and B.clips.lie and B.origin) then B = nil end
    -- (come over with one in his mouth: a bone, a limb)
    a.bone = quad and form == "wolf" and (PIECES.from(h) or (B and h and h.bone and hooks.bone_relic(B))) or nil
    local wx
    if h then
        d = h.dir == 1 and 1 or -1
        local c = (form == "wolf" and Wc or C)[(form == "wolf" and quad) and "walk4" or "walk"]
        local v = c.stride_px * c.fps / c.count * (el.speed or 1.0)
        local sx = walk_in_x(h, v, 0.5 * u)
        wx = d > 0 and sx or W - sx
    else
        d = walk_dir(el)
        wx = -1.2 * u
    end
    local function clips(f) return f == "wolf" and Wc or C end
    local function sprite(f) return f == "wolf" and wolf or spr end

    -- the plan: steps (f: man or wolf; walk to, a clip once or for dur, facing m; spin: turns,
    -- rate from..to; puff: the change)
    local steps, X, face, F = {}, wx, 1, form
    local P4, side = form == "wolf" and quad and not (h and h.upright), 1    -- (on all fours; the way he last faced)
    local function add(s) s.f = s.f or F; steps[#steps + 1] = s; return s end
    local function turn(f)
        if f == face then return end
        if f ~= 0 then side = f end
        if P4 then face = f return end             -- (on all fours: just round)
        if face ~= 0 and clips(F).turn_front then add { clip = "turn_front", m = face < 0 } end
        if f ~= 0 and clips(F).turn_side then add { clip = "turn_side", m = f < 0 } end
        face = f
    end
    local function down()                          -- (the wolf, upright: down on all fours)
        if P4 or not quad or F ~= "wolf" then return end
        turn(face ~= 0 and face or side)
        add { clip = "drop", m = side < 0 }
        P4 = true
    end
    local function up()                            -- (up again; a bone in his mouth: put down first)
        if not P4 then return end
        add { clip = "rise", m = side < 0, put = true }
        P4, face = false, side
    end
    local function go(to, clip)
        local f = to > X and 1 or -1
        if F == "wolf" and quad and not clip then
            turn(f)
            down()
            turn(f)
            add { clip = "walk4", to = to, m = f < 0 }
        else
            up()
            turn(f)
            add { clip = clip or "walk", to = to, m = face < 0 }
        end
        X = to
    end
    local function stop(clip, dur)
        if P4 and clip == "idle" then return add { clip = "idle4", dur = dur, act = true, m = side < 0 } end
        up()
        turn(0)
        return add { clip = clip, dur = dur, act = true }
    end
    local function change()                        -- spin up as one, spin down as the other
        up()
        turn(0)
        add { clip = "spin", spin = { 1, 0.9, 3.2 } }
        F = F == "man" and "wolf" or "man"
        add { clip = "spin", spin = { 1, 3.2, 0.9 }, puff = true, log = "werewolf: turns into a " .. (she and F == "man" and "princess" or F) }
    end
    -- the wolf lies down at a spot and sleeps, his one task the princess: she comes by (called in,
    -- see the princess in spawn.wanderer), he wakes - she's turned; no one comes, he sleeps away
    local function sleep()
        local mx = (d > 0 and X or W - X) > W / 2          -- (the head to the middle of the screen)
        local m = mx ~= (d < 0)
        up()
        add { clip = "lie_down", m = m, log = "werewolf: lies down to sleep" }
        add { clip = "lie", m = m, sleep = true, dur = rnd((el.sleep_for or {})[1] or 45, (el.sleep_for or {})[2] or 90) }
        add { clip = "lie", m = m, fade = true, dur = 2.5, log = "werewolf: sleeps away" }
    end
    local sleeps = Wc.lie and Wc.lie_down and Wc.stand_up and (el.sleep_force or math.random() < (el.sleep_chance or 0.4))
    el.sleep_force = nil
    if h and h.cross then                         -- (just across: preview key a)
        go(W + 1.5 * u)
    elseif she then
        for _ = 1, math.random(2, 3) do
            local to = free_scene_x(1.5 * u, W - 1.5 * u, d, a)
            if math.abs(to - X) > 1.0 * u then go(to) end
            if math.random() < 0.3 and Wc.howl then stop("howl") else stop("idle", rnd(1.0, 2.5)) end
        end
        if Wc.lie and Wc.lie_down and Wc.stand_up and math.random() < (el.she_naps or 0.5) then
            local m = side < 0
            up()
            add { clip = "lie_down", m = m, log = "werewolf: the she-wolf lies down for a nap" }
            add { clip = "lie", m = m, sleep = true, dur = rnd(10, 20) }
            add { clip = "stand_up", m = m }
            face = side
            stop("idle", rnd(0.5, 1.0))
        end
        change()
        if C.cheer then stop("cheer") end
        turn(side)
        add { clip = "idle", dur = 0.05, princess = true, log = "werewolf: she's the princess again" }
    else
        local at = free_scene_x(math.max(2 * u, W * 0.25), math.min(W - 2 * u, W * 0.7), d)
        a.spot = d > 0 and at or W - at               -- (its place: kept for it)
        if at < X + 2 * u then at = math.min(W - 2 * u, X + 3 * u) end
        go(at)
        stop("idle", rnd(0.3, 0.7))
        if F == "man" or (math.random() < 0.5 and not sleeps) then
            change()
            if F == "wolf" and clips(F).howl then stop("howl") end
            if not (F == "wolf" and sleeps) then stop("idle", rnd(0.5, 1.0)) end
        elseif clips(F).howl then
            stop("howl")
        end
        if F == "wolf" and sleeps then sleep() else go(W + 1.5 * u) end
    end

    local si, tc, ph = 1, 0, 0
    local puffs = {}
    a.line = pick_line(el)
    a.hops = h and tonumber(h.hops) or 0
    local function scr(x) return (d > 0) and x or (W - x) end
    local fight_t, fight_x
    local function put_bone()                       -- (out of his mouth, down on the ground)
        if not (a.bone and a.mouth_x) then return end
        a.bone_was, a.bone, a.picked = a.bone, nil, true               -- (not taken up again by him)
        new_bone(el, a.bone_was, a.mouth_x, a.mouth_y, a.mouth_m)
    end
    local function flee(cx)                         -- the cat at cx (screen): back off, run back
        local side = ((d > 0 and cx or W - cx) > wx) and 1 or -1    -- (scene space)
        local new = {}
        local off = side > 0 and -1.5 * u or W + 1.5 * u
        put_bone()                                  -- (dropped in the fright)
        if P4 then                                  -- (on all fours: round and off at once)
            steps, X, face, F = new, wx, -side, "wolf"
            add { clip = Wc.run4 and "run4" or "walk4", to = off, m = side > 0, log = "werewolf: frightened by the cat" }
        else
            steps, X, face, F = new, wx, side, "wolf"
            add { clip = "flinch", m = side < 0, log = "werewolf: frightened by the cat" }
            add { clip = "back", to = wx - side * 1.6 * u, m = side < 0, back = true }
            turn(-side)
            add { clip = Wc.run and "run" or "walk", to = off, m = side > 0 }
        end
        si, tc, a.fled, a.logged, fight_t = 1, 0, true, nil, nil
    end
    -- the wolf on all fours meets a skeleton or the mummy (b): a fight in a cloud of dust, it's gone -
    -- he comes out with a bone in his mouth; he puts it down somewhere (see new_bone) or takes it off
    local function fight(b)
        local fam = actor_family(b)
        fight_x = (scr(wx) + b.cx) / 2
        b.gone = true
        wx = d > 0 and fight_x or W - fight_x
        local new = {}
        steps, X, F = new, wx, "wolf"
        add { clip = "idle4", dur = 2.6, fight = true, m = side < 0, log = "werewolf: a fight with the " .. fam .. "!" }
        add { clip = "idle4", dur = rnd(0.6, 1.0), got = true, m = side < 0, log = "werewolf: off with a bone" }
        if math.random() < (el.bone_put or 0.6) then
            local to = free_scene_x(math.max(1.5 * u, 0.15 * W), math.min(W - 1.5 * u, 0.85 * W), d, a)
            if math.abs(to - X) > 0.8 * u then go(to) end
            add { clip = "idle4", dur = 0.9, m = side < 0, drop_it = true }
            stop("idle", rnd(0.5, 1.0))
        end
        go(side > 0 and W + 1.5 * u or -1.5 * u)
        si, tc, a.logged, fight_t = 1, 0, nil, nil
    end
    -- the man meets a zombie: it gets him - in a puff, he's one too (one of the cast; he goes under
    -- the ground in a while)
    local function zombied()
        local zs_, ce = cast_sprite("zombie"), cast_el()
        if not (zs_ and ce and #free_ids > 0) then return false end
        local b = spawn.wanderer(ce, zs_, { fam = "zombie", dir = (side > 0) == (d > 0) and 1 or -1, at = scr(wx),
                                            hops = 0, puff = true, ttl = 30 })
        if not b then return false end
        adopt(b, ce, { hops = 0 })
        b.kin = true
        msg.verbose("werewolf: the zombie gets the werewolf man - he's a zombie too")
        return true
    end
    local zs, slept = {}, 0
    local function wake(s)                          -- the princess near: up, a howl, off
        local new = {}
        a.logged, P4 = nil, false
        steps, X, face, F = new, wx, s.m and 1 or -1, "wolf"
        side = face
        add { clip = "stand_up", m = s.m, log = "werewolf: wakes up - the princess!" }
        if Wc.howl then stop("howl") end
        stop("idle", rnd(0.6, 1.2))
        go(W + 1.5 * u)
        si, tc, a.asleep_x = 1, 0, nil
    end
    local function call_princess(hx)                -- (one of the cast walks in, from the head's side)
        local pe, sp = princess_el(), nil
        sp = pe and M.sprites[pe.sprite or ""]
        if not (sp and may_be("princess")) then return end
        for _, e in ipairs(M.elements) do
            if e.type == "frogs" then
                local side = hx > a.cx and -1 or 1
                local b = spawn.wanderer(e, sp, { fam = "princess", dir = side, at = side > 0 and 0.02 * W or 0.98 * W,
                                                  ttl = 120, hops = 0 })
                if b then
                    adopt(b, e, { hops = 0 })
                    b.next_at, b.turn_sure = 1e9, true
                    msg.verbose("werewolf: the princess called in")
                end
                return
            end
        end
    end

    function a.update(dt, t)
        local s = steps[si]
        if not s then return false end
        if si ~= a.logged then
            a.logged = si
            if s.log then msg.verbose(s.log) end
            if s.puff then
                for _ = 1, 8 do
                    puffs[#puffs + 1] = { x = scr(wx) + rnd(-0.5, 0.5) * u, y = H - rnd(0.3, 2.2) * u,
                                          r = rnd(0.25, 0.45) * u, vx = rnd(-0.8, 0.8) * u, t = 0 }
                end
            end
            if s.put or s.drop_it then put_bone() end
            if s.princess then                      -- (on as herself, one of the cast)
                local ce = cast_el()
                local b = ce and #free_ids > 0 and spawn.wanderer(ce, spr, { fam = "princess", hops = 0, at = scr(wx),
                                    dir = (side > 0) == (d > 0) and 1 or -1, ttl = math.floor(rnd(40, 90)) })
                if b then adopt(b, ce, { hops = 0 }) end
                return false
            end
            if s.got then                           -- (out of the dust, a bone in his mouth)
                a.bone, fight_t = B and hooks.bone_relic(B) or nil, nil
                for _ = 1, 10 do
                    puffs[#puffs + 1] = { x = fight_x + rnd(-0.9, 0.9) * u, y = H - rnd(0.2, 1.4) * u,
                                          r = rnd(0.3, 0.5) * u, vx = rnd(-0.8, 0.8) * u, t = 0 }
                end
            end
        end
        if s.fight then fight_t = tc + dt end
        local CC = clips(s.f)
        local c = CC[s.clip] or CC.walk
        tc = tc + dt
        local done, frame
        if s.sleep or s.fade then                   -- asleep: zzz; the princess near wakes him
            local hd = ((s.m and true or false) ~= (d < 0)) and -1 or 1
            local hx = scr(wx) + hd * 1.0 * u
            a.asleep_x = s.sleep and not she and hx or nil
            slept = slept + dt
            if math.floor((slept - dt) / 1.1) ~= math.floor(slept / 1.1) and s.sleep then
                zs[#zs + 1] = { x = hx, y = H - 0.9 * u, t = 0, r = 0.22 * u }
            end
            if s.sleep and not she then
                if not a.called_in and slept > (a.call_at or 0) then
                    a.call_at = a.call_at or rnd(4, 12)
                    if slept > a.call_at then a.called_in = true call_princess(hx) end
                end
                for _, b in ipairs(actors) do
                    if b ~= a and actor_family(b) == "princess" and b.cx and not b.leaving and math.abs(b.cx - hx) < 4.2 * u then
                        wake(s)
                        return a.update(0, t)
                    end
                end
            elseif tc < dt * 1.5 or math.random() < dt * 6 then
                puffs[#puffs + 1] = { x = scr(wx) + rnd(-1.2, 1.2) * u, y = H - rnd(0.1, 0.9) * u,
                                      r = rnd(0.3, 0.55) * u, vx = rnd(-0.3, 0.3) * u, t = 0 }
            end
        end
        if s.to then
            local v = c.stride_px * c.fps / c.count * (el.speed or 1.0)
            local dir = s.to > wx and 1 or -1
            wx = wx + dir * v * dt
            if (dir > 0 and wx >= s.to) or (dir < 0 and wx <= s.to) then wx, done = s.to, true end
            if not s.back then walk_out(a, scr(wx), dir * d, 0.5 * u, { form = s.f, sprite = spr.name, relic = PIECES.pass(a.bone),
                                                        she = she }) end
            frame = c.start + math.floor(tc * c.fps) % c.count
        elseif s.spin then
            local n, r0, r1 = s.spin[1], s.spin[2], s.spin[3]
            local total = c.count * n
            local q = clamp(ph / total, 0, 1)
            ph = ph + c.fps * (r0 + (r1 - r0) * q) * dt
            frame = c.start + math.floor(ph) % c.count
            if ph >= total then done, ph = true, 0 end
        else
            local k = math.floor(tc * c.fps)
            frame = c.start + (c.loop and k % c.count or math.min(k, c.count - 1))
            done = tc >= (s.dur or c.count / c.fps)
        end
        -- as the wolf, a cat standing up to him (close by) sends him off
        if s.f == "wolf" and not a.fled and not s.fight then
            a.wolf_x = scr(wx)
            for _, cat in ipairs(cats) do
                if cat.arched and math.abs(cat.p.x - a.wolf_x) < 0.32 * H then flee(cat.p.x) return a.update(0, t) end
            end
        else
            a.wolf_x = (s.f == "wolf") and scr(wx) or nil
        end
        local here = scr(wx) > 0.1 * W and scr(wx) < 0.9 * W
        if s.clip == "walk4" and not a.fled and here then
            local ahead = (s.to > wx and 1 or -1) * d       -- (screen)
            for _, b in ipairs(actors) do
                local fam = b ~= a and b.cx and not b.leaving and not b.gone and actor_family(b)
                -- a skeleton or the mummy just ahead (one walking about, not in a scene of its own)
                if (fam == "skeleton" or fam == "mummy") and (b.family or b.el.type == "performer") and not a.bone
                        and not b.swap and not b.called and (b.cx - scr(wx)) * ahead > 0 and math.abs(b.cx - scr(wx)) < 1.8 * u
                        and b.cx > 0.05 * W and b.cx < 0.95 * W then
                    fight(b)
                    return a.update(0, t)
                end
            end
            -- a bone lying here, at his mouth: taken up (a stop for it)
            local bn = not a.bone and a.mouth_x and free_bone(a.mouth_x, 0.3 * u)
            if bn and not a.picked then
                bn.gone, a.bone, a.picked = true, bn.relic, true
                table.insert(steps, si, { f = "wolf", clip = "idle4", dur = 0.7, m = s.m, log = "werewolf: takes up a " .. bn.relic.kind })
                a.logged = nil
                return a.update(0, t)
            end
        end
        -- the man meets a zombie: it gets him
        if s.f == "man" and here and not a.met_zombie and not she then
            for _, b in ipairs(actors) do
                local bx = b ~= a and not b.leaving and not b.gone and actor_family(b) == "zombie" and (b.cx or b.zx)
                if bx and math.abs(bx - scr(wx)) < 1.5 * u then
                    a.met_zombie = true
                    if math.random() < (el.zombie_chance or 0.7) and zombied() then return false end
                end
            end
        end
        local sp = sprite(s.f)
        local mi = (s.m and true or false) ~= (d < 0)
        local ox = mi and (sp.w - sp.origin[1]) or sp.origin[1]
        local l = { spr = sp, frame = frame, variant = mi, x = scr(wx) - ox, y = H - sp.origin[2] }
        a.sx, a.sy, a.cx = l.x, l.y, scr(wx)
        -- the bone in his mouth (the clip's tracked snout)
        local bl
        local tr = c.track and c.track.head and c.track.head[frame - c.start + 1]
        if tr and s.f == "wolf" then
            a.mouth_x, a.mouth_y, a.mouth_m = scr(wx) + (mi and -tr[1] or tr[1]) + (mi and -0.04 or 0.04) * u, H + tr[2] - 0.12 * u, mi
            if a.bone then bl = hooks.relic_layer(a.bone, a.mouth_x, a.mouth_y, mi)
            end
        elseif s.f ~= "wolf" then
            a.mouth_x = nil
        end
        a.talking = a.line and s.act and true or false
        if a.talking and not a.say_t then a.say_t = t end
        local keep = {}
        for _, p in ipairs(puffs) do
            p.t, p.x, p.y = p.t + dt, p.x + p.vx * dt, p.y - 0.5 * u * dt
            if p.t < 1.3 then keep[#keep + 1] = p end
        end
        puffs = keep
        keep = {}
        for _, z in ipairs(zs) do
            z.t, z.y, z.x = z.t + dt, z.y - 0.35 * u * dt, z.x + 0.15 * u * dt
            if z.t < 2.6 then keep[#keep + 1] = z end
        end
        zs = keep
        if done and s.fade then return false end
        if done then si, tc = si + 1, 0 end
        if (wx < -1.4 * u or wx > W + 1.4 * u) and s.to and not s.back then return false end
        if s.fight then return true, {} end          -- (in the dust)
        return true, { l, bl }
    end
    function a.ass(out)
        for _, p in ipairs(puffs) do puff(out, p.x, p.y, p.r * (1 + p.t), 0.3 + 0.7 * p.t / 1.3) end
        if fight_t then                             -- the fight: a cloud of dust swirling, stars, a bone flying
            local k, cy = fight_t, H - 0.85 * u
            local al = 1 - clamp(k / 0.3, 0, 1) * clamp((2.6 - k) / 0.4, 0, 1)
            puff(out, fight_x, cy, 0.95 * u, 0.15 + 0.6 * al, "&H9AA6B0&")
            for i = 1, 11 do
                local ang = k * 6.5 + i * 2 * math.pi / 11
                local r = (0.6 + 0.15 * math.sin(k * 5 + i)) * u
                puff(out, fight_x + math.cos(ang) * r * 1.35, cy + math.sin(ang) * r * 0.55,
                     (0.36 + 0.1 * math.sin(k * 9 + i * 1.7)) * u, 0.1 + 0.7 * al, i % 2 == 0 and "&HB4BEC6&" or "&H8C98A2&")
            end
            for i = 1, 4 do                         -- (stars popping out of it)
                local ph = (k * 1.6 + i / 4) % 1
                local ang = i * 1.9 + math.floor(k * 1.6 + i / 4) * 2.3
                local x, y = fight_x + math.cos(ang) * (0.7 + 0.8 * ph) * u, cy + math.sin(ang) * (0.4 + 0.6 * ph) * u - 0.3 * u
                local sa = math.floor(clamp(math.max(al, ph), 0, 1) * 255)
                out[#out + 1] = string.format("{\\an5\\pos(%d,%d)\\fs%d\\b1\\bord2\\shad0\\frz%d\\1c&H30D8FF&\\3c&H202020&\\1a&H%02X&\\3a&H%02X&}*",
                    x, y, 0.5 * u, k * 400 + i * 90, sa, sa)
            end
        end
        for _, z in ipairs(zs) do
            local al = math.floor(clamp(z.t / 2.6, 0, 1) * 255)
            out[#out + 1] = string.format("{\\an5\\pos(%d,%d)\\fs%d\\b1\\bord2\\shad0\\1c&HF0E8E0&\\3c&H302020&\\1a&H%02X&\\3a&H%02X&}z",
                z.x, z.y, z.r * (1 + 0.6 * z.t / 2.6) * 2, al, al)
        end
    end
    return a
end

-- princess: a scene for two (layers: the other one, her). Either the frog: she comes in, a frog
-- hops in and croaks; she bends down and kisses it - a puff, and the prince is... whoever of
-- el.princes ({sprite, family}) isn't about in the room: the zombie reaches for her, a skeleton
-- or the pumpkin-head dances - a fright, she runs off; he walks off over to the screen next door
-- (a passer there). The lumberjack is a catch: she cheers and goes off with him. Or the vampire
-- (el.vampire, when he isn't about): he sneaks up behind her to bite, she turns round and kisses
-- him - a puff, a frog; it croaks and hops off next door (a hopper), she cheers and goes. Planned
-- like the mummy: each step has a part for her (a) and the other one (b). Coming in from the
-- left, mirrored half the time.
local function heart(out, x, y, r, alpha)
    local al = math.floor(clamp(alpha, 0, 1) * 255)
    out[#out + 1] = string.format("{\\an7\\pos(0,0)\\bord2\\shad0\\1c&H9C5AF0&\\3c&H5A2AB0&\\1a&H%02X&\\3a&H%02X&\\p1}"
        .. "m %d %d b %d %d %d %d %d %d b %d %d %d %d %d %d{\\p0}", al, al,
        x, y + r, x - 1.5 * r, y + 0.1 * r, x - 1.0 * r, y - 0.9 * r, x, y - 0.35 * r,
        x + 1.0 * r, y - 0.9 * r, x + 1.5 * r, y + 0.1 * r, x, y + r)
end
function spawn.princess(el, spr)
    local S = M.sprites
    local C = spr.clips
    local frog = S[el.frog or ""]
    local F = frog and frog.clips
    if not (C and C.walk and C.idle and C.pick and C.kiss and C.shock and C.cheer and C.run and C.turn_side
            and C.turn_front and F and F.sit and F.hop and frog.origin and spr.origin and spr.unit) then
        return nil
    end
    local u = spr.unit * H
    if W < 9 * u then return nil end
    -- who may play the other part: not about in the room, nor here
    local function free(name, fam)
        local sp = S[name or ""]
        if not (sp and sp.clips and sp.clips.walk and sp.clips.idle and sp.origin) then return nil end
        local _, same = chars_here(fam)
        if same or room.taken["chr:" .. fam] or taken(sp) then return nil end
        return sp
    end
    local vamp = free(el.vampire, "vampire")
    if vamp and not (vamp.clips.sneak and vamp.clips.raise) then vamp = nil end
    local princes = {}
    for _, p in ipairs(el.princes or {}) do
        local sp = free(p.sprite, p.family or p.sprite)
        if sp then princes[#princes + 1] = { sp = sp, fam = p.family or p.sprite } end
    end
    local names = {}
    for _, p in ipairs(princes) do names[#names + 1] = p.fam end
    msg.verbose("princess: free to be the prince: " .. (#names > 0 and table.concat(names, " ") or "none")
        .. (vamp and ", the vampire about" or ""))
    local wit = free(el.witch, "witch")             -- (the kiss may turn her into the witch)
    if wit and not wit.clips.cackle then wit = nil end
    local story = "frog"
    if vamp and (#princes == 0 or math.random() < (el.vampire_chance or 0.4)) then story = "vampire" end
    if story == "frog" and wit and (#princes == 0 or math.random() < (el.witch_chance or 0.15)) then story = "witch" end
    if story == "frog" and #princes == 0 then return nil end
    local prince = story == "frog" and princes[math.random(#princes)] or nil
    -- (the other one's family counts from the start: no second one of them comes meanwhile)
    local a = { el = el, spr = spr, layers = 2, scene = true,
                also = { prince and prince.fam or (story == "witch" and "witch") or "vampire" } }
    local d = math.random() < 0.5 and 1 or -1
    -- the cast about here taken over: the princess starts where she is; a frog sits waiting
    local her = cast_here("princess")
    local toad = story ~= "vampire" and cast_here("frog") or nil
    if toad then d = toad.cx > W / 2 and 1 or -1 elseif her then d = her.facing or 1 end
    local function sx(x) return (d > 0) and x or (W - x) end
    a.recruited = {}
    if her then a.recruited[#a.recruited + 1] = her end
    if toad then a.recruited[#a.recruited + 1] = toad end
    local A0 = her and sx(her.cx) or -1.2 * u
    local B0

    local steps = {}
    local A = { x = A0, face = (her and (her.facing or 1) * d < 0) and -1 or 1, rest = { clip = "idle", rest = true }, sp = spr }
    local B = { face = 1, rest = { hide = true, rest = true } }
    local function add(s)   -- (a missing part rests as planned at this point; each part: as whom)
        s.a, s.b = s.a or A.rest, s.b or B.rest
        s.a.sp, s.b.sp = s.a.sp or A.sp, s.b.sp or B.sp
        steps[#steps + 1] = s
        return s
    end
    local function turn(t, f, key)
        local cl = t.sp.clips
        if f == t.face then return end
        if t.face ~= 0 and cl.turn_front then add { [key] = { clip = "turn_front", m = t.face < 0 } } end
        if f ~= 0 and cl.turn_side then add { [key] = { clip = "turn_side", m = f < 0 } } end
        t.face = f
    end
    local function go(t, key, to, clip, out)
        turn(t, to > t.x and 1 or -1, key)
        add { [key] = { clip = clip or "walk", to = to, m = t.face < 0, out = out } }
        t.x = to
    end
    local hold = math.floor(C.pick.count * 0.45)       -- (bent down)
    -- not about: she comes as a frog, hopping in - a puff, and there she is
    if not her and el.frog_in ~= false then
        A.sp, A.x, A.face = frog, -0.6 * u, 1
        A0 = A.x
        A.rest = { clip = "sit", rest = true }
        local at = rnd(0.1, 0.16) * W
        add { a = { clip = "hop", hop = at }, log = "princess: a frog hops in" }
        A.x = at
        add { a = { clip = "sit", dur = rnd(0.5, 1.0) } }
        A.sp, A.face = spr, 0
        A.rest = { clip = "idle", rest = true }
        add { a = { clip = "idle", dur = 1.0 }, puff = "a", log = "princess: in a puff, the frog is the princess" }
        if math.random() < 0.5 then add { a = { clip = "cheer" } } end
    end

    if story ~= "vampire" then
        local fx = free_scene_x(0.5 * W, 0.7 * W, d)
        a.spot = d > 0 and fx or W - fx               -- (its place: kept for it)
        B.sp, B.x, B.face = frog, W + 0.6 * u, -1
        if toad then                                -- (sitting there already)
            B.x = sx(toad.cx)
            B.rest = { clip = "sit", m = true, rest = true }
            fx = math.min(fx, B.x)
            if toad.dy and B.x - fx <= 0.1 * u then fx = B.x - 0.9 * u end    -- (down off the pile)
        end
        B0 = B.x
        go(A, "a", math.min(rnd(0.22, 0.3) * W, fx - 2 * u))
        turn(A, 0, "a")
        B.rest = { clip = "sit", m = true, rest = true }
        if B.x - fx > 0.1 * u then
            add { a = { clip = "idle", dur = 0.4 }, b = { clip = "hop", hop = fx, m = true } }
        else
            add { a = { clip = "idle", dur = 0.4 } }
        end
        B.x = fx
        add { b = F.croak and { clip = "croak", m = true, n = 2 } or { clip = "sit", m = true, dur = 1 }, log = "princess: a frog" }
        add { a = { clip = "idle", dur = rnd(0.6, 1.2), act = true } }
        go(A, "a", fx - 0.75 * u)
        add { a = { clip = "pick", hold = hold, dur = 0.8 } }
        add { a = { clip = "pick", hold = hold, dur = 1.4 }, heart = true, log = "princess: kisses the frog" }
      if story == "witch" then                          -- the kiss: she's the witch; the frog's off
        add { a = { clip = "pick", from = hold } }
        A.sp, A.face = wit, 1
        A.rest = { clip = "idle", rest = true }
        add { a = { clip = "idle", dur = 1.0 }, puff = "a", log = "princess: the kiss - and she is the witch" }
        turn(A, 0, "a")
        add { a = { clip = "cackle", act = true } }
        B.face = 1
        add { b = { clip = "hop", hop = W + 0.8 * u, out = "frog" } }
        B.rest = { hide = true, rest = true }
        go(A, "a", -1.5 * u)
        steps[#steps].a.out = "witch"
      else
        local P = prince.sp.clips
        B.sp, B.face = prince.sp, 0
        B.rest = { clip = "idle", rest = true }
        add { a = { clip = "pick", from = hold }, b = { clip = "idle", dur = 0.8 }, puff = true,
              log = "princess: the frog is the " .. prince.fam }
        A.rest = { clip = "idle", m = false, rest = true }
        turn(A, 0, "a")
        if prince.fam == "werewolf" then                -- a catch: off with him
            add { a = { clip = "cheer", act = true }, b = { clip = "idle", dur = 1.2 } }
            turn(B, 1, "b")
            turn(A, 1, "a")
            add { a = { clip = "walk", to = W + 0.3 * u }, b = { clip = "walk", to = W + 1.5 * u, out = prince.fam } }
            B.rest = { hide = true, rest = true }
            A.x = W + 0.3 * u
            go(A, "a", W + 1.5 * u)
            steps[#steps].a.out = "princess"
        else                                            -- a fright: she runs, he goes on
            local react = (P.reach and { clip = "reach", m = true, dur = 1.8, pre = P.turn_reach and "turn_reach" })
                or (P.taunt and math.random() < 0.5 and { clip = "taunt" })
                or (P.cheer and { clip = "cheer" }) or { clip = "idle", dur = 1.5 }
            if react.pre then add { b = { clip = react.pre, m = true } } end
            if react.clip == "reach" then B.face = -1 end
            add { a = { clip = "shock", act = true }, b = react }
            if react.clip == "reach" then B.rest = { clip = "reach", m = true, rest = true } end
            turn(A, -1, "a")
            turn(B, 1, "b")
            add { a = { clip = "run", to = -1.5 * u, m = true, out = "princess" }, b = { clip = "walk", to = W + 1.5 * u, out = prince.fam } }
            A.rest = { hide = true, rest = true }
        end
      end
    else
        local px = free_scene_x(0.45 * W, 0.7 * W, d)
        a.spot = d > 0 and px or W - px               -- (its place: kept for it)
        local V = vamp.clips
        local up = math.floor(V.raise.count * 0.6)
        B.sp, B.x, B.face = vamp, -1.2 * u, 1
        B0 = B.x
        go(A, "a", px)
        turn(A, 0, "a")
        add { a = { clip = "idle", dur = 0.3 }, b = { clip = "walk", to = px - 3.2 * u } }
        add { b = { clip = "sneak", to = px - 1.15 * u } }
        B.x = px - 1.15 * u
        B.rest = { clip = "raise", hold = up, rest = true }
        add { b = { clip = "raise", hold = up, dur = 1.0 }, log = "princess: the vampire, about to bite" }
        turn(A, -1, "a")
        A.rest = { clip = "idle", m = true, rest = true }
        add { a = { clip = "kiss", dur = 1.6, m = true }, heart = true, log = "princess: kisses the vampire" }
        B.sp, B.face = frog, 1
        B.rest = { clip = "sit", rest = true }
        add { a = { clip = "idle", dur = 0.8, m = true }, b = { clip = "sit", dur = 0.8 }, puff = true,
              gone = true, log = "princess: the vampire is a frog" }
        add { b = F.croak and { clip = "croak", n = 2 } or { clip = "sit", dur = 1 } }
        turn(A, 0, "a")
        add { a = { clip = "cheer", act = true } }
        B.face = -1
        add { b = { clip = "hop", hop = -0.8 * u, m = true, out = "frog" } }
        B.rest = { hide = true, rest = true }
        go(A, "a", W + 1.5 * u)
        steps[#steps].a.out = "princess"
    end

    -- play
    local si, tc = 1, 0
    local puffs, hearts = {}, {}
    a.line = pick_line(el)
    A.x, B.x = A0, B0
    B.y = toad and toad.dy or 0
    local hop = F.hop.count / F.hop.fps
    local function scr(x) return (d > 0) and x or (W - x) end
    local function place(sp, x, frame, mirror, dy)
        local m = (mirror and true or false) ~= (d < 0)
        local ox = m and (sp.w - sp.origin[1]) or sp.origin[1]
        return { spr = sp, frame = frame, variant = m, x = scr(x) - ox, y = H - sp.origin[2] + (dy or 0) }
    end
    -- one going off goes on next door as one of the cast (p.out: its family, "frog" a frog)
    local function hand_on(t, sp, p, dir)
        t.oa = t.oa or { el = el, spr = sp, groups = {}, hops = 0 }
        t.oa.spr = sp
        local ttl = math.floor(rnd(range(el.cast_ttl, 180)))
        if p.out == "frog" then
            walk_out(t.oa, scr(t.x), dir * d, 0.3 * u, { kind = "hopper", unique = false, ttl = ttl, hops = 0 })
        else
            walk_out(t.oa, scr(t.x), dir * d, 0.5 * u, { kind = "wanderer", fam = p.out, ttl = ttl, unique = false, hops = 0, from = el.type })
        end
    end
    -- one part of the step: its layer (or nil) and whether that part is done
    local function part(t, sp, p, dt)
        if p.hide then return nil, p.rest or tc >= (p.dur or 0) end
        local c = sp.clips[p.clip] or sp.clips.idle
        local done, k, dy = false, nil, 0
        if p.to then
            local v = c.stride_px * c.fps / c.count * (el.speed or 1.0)
            local dir = p.to > t.x and 1 or -1
            t.x = t.x + dir * v * dt
            if (dir > 0 and t.x >= p.to) or (dir < 0 and t.x <= p.to) then t.x, done = p.to, true end
            k = math.floor(tc * c.fps) % c.count
            if p.out then hand_on(t, sp, p, dir) end
        elseif p.hop then                               -- hop by hop (1.2 u) to there
            local dir = p.hop > t.x and 1 or -1
            t.h0, t.ht = t.h0 or t.x, (t.ht or 0) + dt
            local to = t.h0 + dir * 1.2 * u
            if (dir > 0) == (to > p.hop) then to = p.hop end
            t.x, dy = hop_at(t.ht / hop, t.h0, to, t.y or 0, 0, 0.6 * u)
            k = math.min(c.count - 1, math.floor(t.ht * c.fps))
            if p.out then hand_on(t, sp, p, dir) end
            if t.ht >= hop then
                t.x, t.h0, t.ht, t.y = to, nil, nil, 0
                done = to == p.hop
            end
        else
            dy = t.y or 0                               -- (up on the pile, still)
            local n = math.floor(tc * c.fps)
            local len = c.count / c.fps * (p.n or 1)
            if p.hold then k = math.min(p.hold, n)
            elseif p.from then k, len = math.min(c.count - 1, p.from + n), (c.count - p.from) / c.fps
            elseif c.loop or p.n then k = n % c.count
            else k = math.min(n, c.count - 1) end
            done = p.rest or tc >= (p.dur or ((c.loop or p.hold) and 0 or len))
        end
        return place(sp, t.x, c.start + k, p.m, dy), done
    end

    function a.update(dt, t)
        local s = steps[si]
        if not s then return false end
        if si ~= a.logged then
            a.logged = si
            if s.log then msg.verbose(s.log) end
            if s.puff then
                local px = s.puff == "a" and A.x or B.x
                for _ = 1, 8 do
                    puffs[#puffs + 1] = { x = scr(px) + rnd(-0.5, 0.5) * u, y = H - rnd(0.2, 1.8) * u,
                                          r = rnd(0.25, 0.45) * u, vx = rnd(-0.5, 0.5) * u, t = 0 }
                end
            end
            if s.gone then a.also = nil end             -- (no vampire now: just a frog)
            if s.heart then hearts[#hearts + 1] = { x = scr((A.x + B.x) / 2), y = H - 2.0 * u, t = 0 } end
        end
        tc = tc + dt
        local la, da = part(A, s.a.sp, s.a, dt)
        local lb, db = part(B, s.b.sp, s.b, dt)
        if s.puff and tc < 0.25 then                    -- (the change, in the puff)
            if s.puff == "a" then la = nil else lb = nil end
        end
        if la then a.sx, a.sy, a.cx = la.x, la.y, scr(A.x) end
        local keep = {}
        for _, q in ipairs(puffs) do
            q.t, q.x, q.y = q.t + dt, q.x + q.vx * dt, q.y - 0.5 * u * dt
            if q.t < 1.2 then keep[#keep + 1] = q end
        end
        puffs, keep = keep, {}
        for _, q in ipairs(hearts) do
            q.t, q.y = q.t + dt, q.y - 0.4 * u * dt
            if q.t < 2 then keep[#keep + 1] = q end
        end
        hearts = keep
        a.talking = a.line and s.a.act and true or false
        if a.talking and not a.say_t then a.say_t = t end
        if da and db then si, tc = si + 1, 0 end
        return true, { lb, la }
    end
    function a.ass(out)
        for _, q in ipairs(puffs) do puff(out, q.x, q.y, q.r * (1 + 0.6 * q.t), 0.2 + 0.8 * q.t / 1.2) end
        for _, q in ipairs(hearts) do heart(out, q.x, q.y, 0.2 * u * (1 + 0.3 * q.t), math.max(0, q.t - 1) / 1) end
    end
    return a
end

-- frogs: two frogs hop in from either side (one may be a frog about already), meet, croak at each
-- other and kiss (a hop to each other, a heart) - a big puff, and there stand a princess (or the
-- witch: el.ladies) and a hero (el.heroes: sprite + family, whoever's not about): a look at the
-- viewer, a cheer, a cackle, a taunt, and off they go - together, or each their own way - on as
-- two of the cast. Planned left to right, mirrored half the time.
function spawn.frogs(el, spr)
    local S = M.sprites
    local F = spr.clips
    if not (F and F.sit and F.hop and spr.origin and spr.unit) then return nil end
    local function free(name, fam)
        local sp = S[name or ""]
        if not (sp and sp.clips and sp.clips.walk and sp.clips.idle and sp.origin and sp.unit) then return nil end
        local _, same = chars_here(fam)
        if same or room.taken["chr:" .. fam] or taken(sp) then return nil end
        return sp
    end
    local function pick(list)
        local ok = {}
        for _, p in ipairs(list or {}) do
            local sp = free(p.sprite, p.family or p.sprite)
            if sp then ok[#ok + 1] = { sp = sp, fam = p.family or p.sprite } end
        end
        return #ok > 0 and ok[math.random(#ok)] or nil
    end
    local lady, hero = pick(el.ladies), pick(el.heroes)
    if not (lady and hero) then return nil end
    local u = spr.unit * H                              -- (the frog's unit: the characters bring their own)
    local cu = lady.sp.unit * H
    if W < 8 * cu then return nil end
    local a = { el = el, spr = spr, layers = 2, scene = true, family = lady.fam, also = { hero.fam } }
    local d = math.random() < 0.5 and 1 or -1
    local toad = cast_here("frog")
    if toad then d = toad.cx < W / 2 and 1 or -1 end    -- (the one on the left)
    local function sx(x) return (d > 0) and x or (W - x) end
    local toad2 = toad and cast_here("frog", toad) or nil
    a.recruited = { toad, toad2 }
    local mx = free_scene_x(0.38 * W, 0.62 * W, d)
    a.spot = d > 0 and mx or W - mx               -- (its place: kept for it)

    local steps = {}
    local A = { x = toad and sx(toad.cx) or -0.6 * u, face = 1, sp = spr, rest = { clip = "sit", rest = true } }
    local B = { x = toad2 and sx(toad2.cx) or W + 0.6 * u, face = -1, sp = spr, rest = { clip = "sit", m = true, rest = true } }
    local A0, B0 = A.x, B.x
    if not toad then A.rest = { hide = true, rest = true } end
    if not toad2 then B.rest = { hide = true, rest = true } end
    local function add(s)
        s.a, s.b = s.a or A.rest, s.b or B.rest
        s.a.sp, s.b.sp = s.a.sp or A.sp, s.b.sp or B.sp
        steps[#steps + 1] = s
        return s
    end
    local function turn(t, f, key)
        local cl = t.sp.clips
        if f == t.face then return end
        if t.face ~= 0 and cl.turn_front then add { [key] = { clip = "turn_front", m = t.face < 0 } } end
        if f ~= 0 and cl.turn_side then add { [key] = { clip = "turn_side", m = f < 0 } } end
        t.face = f
    end
    local function walk(t, to, out)
        return { clip = "walk", to = to, m = to < t.x, out = out }
    end

    -- the frogs: in, a croak each, the kiss
    add { a = { clip = "hop", hop = mx - 0.5 * u, m = A.x > mx - 0.5 * u }, b = { clip = "hop", hop = mx + 0.5 * u, m = B.x > mx + 0.5 * u } }
    A.x, B.x = mx - 0.5 * u, mx + 0.5 * u
    A.rest = { clip = "sit", rest = true }
    B.rest = { clip = "sit", m = true, rest = true }
    add { a = F.croak and { clip = "croak", n = 2 } or { clip = "sit", dur = 1 }, log = "frogs: two frogs meet" }
    add { b = F.croak and { clip = "croak", m = true, n = 2 } or { clip = "sit", m = true, dur = 1 } }
    add { a = { clip = "sit", dur = rnd(0.5, 1.2) } }
    add { a = { clip = "hop", hop = mx - 0.3 * u }, b = { clip = "hop", hop = mx + 0.3 * u, m = true },
          heart = true, log = "frogs: a kiss" }
    A.x, B.x = mx - 0.3 * u, mx + 0.3 * u
    add { a = { clip = "sit", dur = 1.4 } }
    -- the puff: the two of them
    A.sp, B.sp, A.face, B.face = lady.sp, hero.sp, 0, 0
    A.x, B.x = mx - 0.7 * cu, mx + 0.7 * cu
    A.rest, B.rest = { clip = "idle", rest = true }, { clip = "idle", rest = true }
    add { a = { clip = "idle", dur = 1.6 }, puff = true, at = { A.x, B.x },
          log = "frogs: in a big puff - the " .. lady.fam .. " and the " .. hero.fam }
    local L, Hc = lady.sp.clips, hero.sp.clips
    local la = (L.cheer and "cheer") or (L.cackle and "cackle") or nil
    local hb = (Hc.taunt and math.random() < 0.5 and "taunt") or (Hc.cheer and "cheer") or nil
    add { a = la and { clip = la, act = true } or { clip = "idle", dur = 1.5, act = true },
          b = hb and { clip = hb } or { clip = "idle", dur = 1.5 } }
    local ttl = function() return math.floor(rnd(range(el.cast_ttl, 180))) end
    if math.random() < 0.5 then                         -- off together
        local f = math.random() < 0.5 and 1 or -1
        turn(A, f, "a")
        turn(B, f, "b")
        local ea, eb = f > 0 and W + 1.5 * cu or -1.5 * cu, f > 0 and W + 2.7 * cu or -2.7 * cu
        if f < 0 then ea, eb = eb, ea end
        add { a = walk(A, ea, lady.fam), b = walk(B, eb, hero.fam), log = "frogs: off together" }
    else                                                -- each their own way
        turn(A, -1, "a")
        turn(B, 1, "b")
        add { a = walk(A, -1.5 * cu, lady.fam), b = walk(B, W + 1.5 * cu, hero.fam) }
    end
    A.rest, B.rest = { hide = true, rest = true }, { hide = true, rest = true }

    -- play
    local si, tc = 1, 0
    local puffs, hearts = {}, {}
    A.x, B.x = A0, B0
    A.y, B.y = toad and toad.dy or 0, toad2 and toad2.dy or 0
    local hop = F.hop.count / F.hop.fps
    local function scr(x) return (d > 0) and x or (W - x) end
    local function place(sp, x, frame, mirror, dy)
        local m = (mirror and true or false) ~= (d < 0)
        local ox = m and (sp.w - sp.origin[1]) or sp.origin[1]
        return { spr = sp, frame = frame, variant = m, x = scr(x) - ox, y = H - sp.origin[2] + (dy or 0) }
    end
    local function hand_on(t, sp, p, dir)               -- (as one of the cast, next door)
        t.oa = t.oa or { el = el, spr = sp, groups = {}, hops = 0 }
        t.oa.spr = sp
        walk_out(t.oa, scr(t.x), dir * d, 0.5 * sp.unit * H, { kind = "wanderer", fam = p.out, ttl = t.ttl, unique = false, hops = 0, from = el.type })
    end
    A.ttl, B.ttl = ttl(), ttl()
    local function part(t, sp, p, dt)
        if p.hide then return nil, p.rest or tc >= (p.dur or 0) end
        local c = sp.clips[p.clip] or sp.clips.idle or sp.clips.sit
        local done, k, dy = false, nil, 0
        if p.to then
            local v = c.stride_px * c.fps / c.count * (el.speed or 1.0)
            local dir = p.to > t.x and 1 or -1
            t.x = t.x + dir * v * dt
            if (dir > 0 and t.x >= p.to) or (dir < 0 and t.x <= p.to) then t.x, done = p.to, true end
            k = math.floor(tc * c.fps) % c.count
            if p.out then hand_on(t, sp, p, dir) end
        elseif p.hop then
            local dir = p.hop > t.x and 1 or -1
            t.h0, t.ht = t.h0 or t.x, (t.ht or 0) + dt
            local to = t.h0 + dir * 1.2 * u
            if (dir > 0) == (to > p.hop) then to = p.hop end
            t.x, dy = hop_at(t.ht / hop, t.h0, to, t.y or 0, 0, 0.6 * u)
            k = math.min(c.count - 1, math.floor(t.ht * c.fps))
            if t.ht >= hop then
                t.x, t.h0, t.ht, t.y = to, nil, nil, 0
                done = to == p.hop
            end
        else
            dy = t.y or 0                               -- (up on the pile, still)
            local n = math.floor(tc * c.fps)
            local len = c.count / c.fps * (p.n or 1)
            if c.loop or p.n then k = n % c.count else k = math.min(n, c.count - 1) end
            done = p.rest or tc >= (p.dur or (c.loop and 0 or len))
        end
        return place(sp, t.x, c.start + k, p.m, dy), done
    end

    function a.update(dt, t)
        local s = steps[si]
        if not s then return false end
        if si ~= a.logged then
            a.logged = si
            if s.log then msg.verbose(s.log) end
            if s.puff then                              -- (where the frogs were, as big as the two)
                A.x, B.x = s.at[1], s.at[2]
                for _ = 1, 18 do
                    puffs[#puffs + 1] = { x = scr(mx) + rnd(-1.3, 1.3) * cu, y = H - rnd(0.2, 2.0) * cu,
                                          r = rnd(0.3, 0.55) * cu, vx = rnd(-0.6, 0.6) * cu, t = 0 }
                end
            end
            if s.heart then hearts[#hearts + 1] = { x = scr(mx), y = H - 1.0 * u, t = 0 } end
        end
        tc = tc + dt
        local la_, da = part(A, s.a.sp, s.a, dt)
        local lb, db = part(B, s.b.sp, s.b, dt)
        if s.puff and tc < 0.35 then la_, lb = nil, nil end
        if la_ then a.sx, a.sy, a.cx = la_.x, la_.y, scr(A.x) end
        local keep = {}
        for _, q in ipairs(puffs) do
            q.t, q.x, q.y = q.t + dt, q.x + q.vx * dt, q.y - 0.5 * cu * dt
            if q.t < 1.4 then keep[#keep + 1] = q end
        end
        puffs, keep = keep, {}
        for _, q in ipairs(hearts) do
            q.t, q.y = q.t + dt, q.y - 0.4 * u * dt
            if q.t < 2 then keep[#keep + 1] = q end
        end
        hearts = keep
        a.talking = false
        if da and db then si, tc = si + 1, 0 end
        return true, { lb, la_ }
    end
    function a.ass(out)
        for _, q in ipairs(puffs) do puff(out, q.x, q.y, q.r * (1 + 0.6 * q.t), 0.2 + 0.8 * q.t / 1.4) end
        for _, q in ipairs(hearts) do heart(out, q.x, q.y, 0.3 * u * (1 + 0.3 * q.t), math.max(0, q.t - 1) / 1) end
    end
    return a
end

-- scarecrow: a straw man up on a pole, in the background (the theme draws it small and see-
-- through). Up out of the ground, and there it hangs a few minutes (el.stay), stock still - only
-- now and then its head jerks round or tilts (still frames, snapped to), and sometimes to
-- whoever comes by close. Now and then a bird (el.birds: {sprite, perch = {"arm", "hat"}}, baked
-- with clips sit/fly/spread, see tools/bake/bird.py) comes flying down onto its arm or hat, sits
-- a while (a vulture spreads its wings) and flies off again - or when someone comes close, or
-- the scarecrow goes. Down it goes when its time is up, or when a scene wants the floor.
-- Layers: it, the bird.
local SCARECROW_PERCH = { arm = { 0.27, 0.745 }, hat = { 0, 0.98 } }  -- from the foot of the pole, in sprite heights
function spawn.scarecrow(el, spr)
    local C = spr.clips
    if not (C and C.stand and C.look_l and C.look_r and spr.origin) then return nil end
    local u = (spr.unit or 0.115) * H
    local cx
    for _ = 1, 12 do                -- (not on top of a scene, nor another scarecrow)
        local x = rnd(0.12, 0.88) * W
        local ok = true
        for _, b in ipairs(actors) do
            if b.cx and (b.scene or b.el.type == "scarecrow") and math.abs(b.cx - x) < 0.2 * W then ok = false end
        end
        if ok then cx = x break end
    end
    if not cx then return nil end
    local birds = {}
    for _, b in ipairs(el.birds or {}) do
        local sp = M.sprites[b.sprite or ""]
        if sp and sp.clips and sp.clips.sit and sp.clips.fly and sp.origin then birds[#birds + 1] = { sp = sp, perch = b.perch or { "arm" } } end
    end
    local a = { el = el, spr = spr, layers = 2, cx = cx }
    local stay = rnd(range(el.stay, 150))
    local state, ts = "rise", 0            -- rise | stand | sink
    local pose, tp, pose_for = "stand", 0, 0
    local next_tic = rnd(range(el.tics, 20))
    local next_bird = rnd(range(el.bird_after, 20))
    local bd = nil                         -- the bird: {sp, state, t, x, y, side, perch, ...}
    local watching = nil
    local function perch_at(p, side)
        local q = SCARECROW_PERCH[p]
        return cx + side * q[1] * spr.h, H - q[2] * spr.h
    end
    local function set(p, dur) pose, tp, pose_for = p, 0, dur or 0 end
    local function bird_off(why)
        if bd and bd.state ~= "off" then
            bd.state, bd.t, bd.x0, bd.y0 = "off", 0, bd.x, bd.y
            bd.dir = (math.random() < 0.5) and -1 or 1
            msg.verbose("scarecrow: the bird flies off" .. (why and (" (" .. why .. ")") or ""))
        end
    end

    function a.update(dt, t)
        ts = ts + dt
        tp = tp + dt
        local dy = 0
        if state == "rise" then
            local p = clamp(ts / DECOR_MOVE_S, 0, 1)
            dy = (1 - ease(p)) * spr.h
            if p >= 1 then state, ts = "stand", 0 msg.verbose("scarecrow: up") end
        elseif state == "stand" then
            local busy = floor_busy("scenes")
            if ts > stay or busy then
                msg.verbose("scarecrow: down" .. (busy and " (making way)" or ""))
                state, ts = "sink", 0
                bird_off()
                set("stand")
            end
        elseif state == "sink" then
            local p = clamp(ts / DECOR_MOVE_S, 0, 1)
            dy = ease(p) * spr.h
            if p >= 1 and not bd then return false end
        end

        -- someone coming by close: the bird goes; the scarecrow may watch them
        local who
        for _, b in ipairs(actors) do
            if b ~= a and b.cx and is_character(b) and math.abs(b.cx - cx) < 3 * u then who = b end
        end
        if who and bd and bd.state == "sit" then bird_off("someone came by") end

        -- its head, now and then (a still pose held, then back)
        if pose ~= "stand" and tp >= pose_for then set("stand") end
        if state == "stand" and pose == "stand" then
            if who and who ~= watching then
                watching = who
                if math.random() < 0.5 then
                    set(who.cx < cx and "look_r" or "look_l", rnd(1.5, 3))
                    msg.verbose("scarecrow: watches " .. tostring(who.el.type))
                end
            elseif not who then watching = nil end
            if bd and bd.state == "sit" and not bd.seen and bd.t > 2 then
                bd.seen = true
                if math.random() < 0.6 then set(bd.side < 0 and "look_r" or "look_l", rnd(1.5, 2.5)) end
            elseif ts > next_tic and pose == "stand" then
                next_tic = ts + rnd(range(el.tics, 20))
                local r = math.random()
                if r < 0.6 then set(math.random() < 0.5 and "look_l" or "look_r", rnd(1.2, 2.5))
                elseif C.tilt then set("tilt", rnd(2, 4)) end
            end
            -- a bird comes
            if not bd and #birds > 0 and ts > next_bird and ts < stay - 20 then
                next_bird = ts + rnd(range(el.bird_every, 40))
                if math.random() < (el.bird_chance or 0.7) then
                    local b = birds[math.random(#birds)]
                    local perch = b.perch[math.random(#b.perch)]
                    local side = perch == "hat" and 0 or (math.random() < 0.5 and -1 or 1)
                    local from = side ~= 0 and side or (math.random() < 0.5 and -1 or 1)
                    local px, py = perch_at(perch, side)
                    bd = { sp = b.sp, state = "in", t = 0, side = side, perch = perch, sit = rnd(8, 20),
                           x0 = px + from * rnd(0.3, 0.45) * W, y0 = rnd(0.05, 0.25) * H, x = px, y = py,
                           face = math.random() < 0.5 and -1 or 1 }
                    msg.verbose("scarecrow: a " .. tostring(b.sp.name) .. " comes, for its " .. perch)
                end
            end
        end
        local c = C[pose] or C.stand
        local layers = { { spr = spr, frame = c.start, variant = false, x = cx - spr.origin[1], y = H - spr.origin[2] + dy } }
        a.sx, a.sy = layers[1].x, layers[1].y

        -- the bird: down in a glide (flapping), sits, off up and away (flapping)
        if bd then
            local B = bd.sp.clips
            bd.t = bd.t + dt
            local px, py = perch_at(bd.perch, bd.side)
            py = py + dy
            local clip, k, x, y, mirror = "sit", 0, px, py, bd.face < 0
            if bd.state == "in" then
                local p = clamp(bd.t / 3.0, 0, 1)
                x = bd.x0 + (px - bd.x0) * ease(p)
                y = bd.y0 + (py - bd.y0) * math.sin(p * math.pi / 2)
                clip, mirror = "fly", px < bd.x0
                k = math.floor(bd.t * B.fly.fps) % B.fly.count
                if p >= 1 then
                    bd.state, bd.t, bd.face = "sit", 0, px < bd.x0 and -1 or 1
                    msg.verbose("scarecrow: the bird sits on its " .. bd.perch)
                end
            elseif bd.state == "sit" then
                bd.x, bd.y = px, py
                if B.spread and not bd.spread_t and bd.t > bd.sit * 0.4 and bd.sp.name:find("vulture") then bd.spread_t = bd.t end
                local sp_len = B.spread and B.spread.count / B.spread.fps or 0
                if bd.spread_t and bd.t - bd.spread_t < sp_len then
                    clip, k = "spread", math.min(B.spread.count - 1, math.floor((bd.t - bd.spread_t) * B.spread.fps))
                else
                    k = math.floor(bd.t * B.sit.fps) % B.sit.count
                end
                if bd.t > bd.sit then bird_off() end
            else                           -- off, up and away
                local p = bd.t / 2.6
                x = bd.x0 + bd.dir * p * 0.55 * W
                y = bd.y0 - (H * 0.8) * p * p - 0.3 * u * math.sin(math.min(p, 0.25) / 0.25 * math.pi)
                clip, mirror = "fly", bd.dir < 0
                k = math.floor(bd.t * B.fly.fps * 1.2) % B.fly.count
                if p >= 1 or y < -bd.sp.h then bd = nil end
            end
            if bd then
                local sp = bd.sp
                local ox = mirror and (sp.w - sp.origin[1]) or sp.origin[1]
                layers[2] = { spr = sp, frame = B[clip].start + k, variant = mirror, x = x - ox, y = y - sp.origin[2] }
            end
        end
        return true, layers
    end
    return a
end

-- wanderer: one of the cast come over from the screen next door (h: sprite, fam, ttl, dir): walks
-- across, now and then a stop in the middle (faces the viewer, a look round, a cheer or a taunt
-- if it has them), and on; where it can't go on (no screen that side, full there) it turns round.
-- A scene here that wants it: it hangs about (walking to and fro) till taken over. Its time up,
-- it walks off the screen and is gone.
function spawn.wanderer(el, spr, h)
    local C = spr.clips
    local fam = h.fam
    if h.fam == "pumpkinhead" and C and C.lift_nh and spawn.pumpkinhead then return spawn.pumpkinhead(el, spr, h) end
    if not (C and C.walk and C.idle and spr.origin and spr.unit and h.fam) then return nil end
    local u = spr.unit * H
    local c = C.walk
    local v = c.stride_px * c.fps / c.count * (el.speed or 1.0)
    local dir = h.dir == 1 and 1 or -1
    local front = 0.5 * u
    local x = walk_in_x(h, v, front)
    local a = { el = el, spr = spr, layers = 1, groups = { "walker" }, family = h.fam, from = h.from }
    a.hops, a.ttl = 0, tonumber(h.ttl) or 60
    a.cooked, a.was_pr = h.cooked, h.was_pr      -- (a witch: cooked once, been the princess - she may go)
    a.age = tonumber(h.age) or 0                 -- (about as one of the cast this long)
    if h.fam == "zombie" and not h.age then a.ttl = a.ttl * (el.zombie_ttl or 0.5) end   -- (new: zombies about shorter)
    -- a skeleton with the zombie's brain and an eye (it won them in a fight, see hooks.zombie_fight):
    -- on its skull, in its socket - a while, then they fall out (the brain for a zombie to find)
    local BR, EY = brain_sprite(), M.sprites.eye
    if h.brainy and BR and EY and EY.origin then
        a.brainy, a.layers, down_x = tonumber(h.brainy) or rnd(20, 35), 3, nil
    end
    local state, tc = "walk", 0
    -- underground (skeletons, zombies): it sinks into the ground mid-screen and comes up on another
    -- screen, a few along (relayed under the screens between, see theme-room-in): rise | under
    local dy, clods = 0, {}
    local zombie = h.fam == "zombie"
    local down_x = TUNNEL[h.fam] and (room.left or room.right)
                   and math.random() < (zombie and (el.zombie_tunnel or 0.7) or el.tunnel_chance or 0.35)
                   and rnd(0.3, 0.7) * W or nil
    local hurry, meal_x, drop_at = 1, nil, nil
    if h.down_at then down_x = tonumber(h.down_at) end
    if h.tunnel then
        x, state, down_x = tonumber(h.at_x) or free_x(0.25 * W, 0.75 * W), "under", nil
        a.under_t = rnd(1, 2.5) + 1.2 * (tonumber(h.went) or 1)
    end
    local function dirt(n)
        for _ = 1, n do
            clods[#clods + 1] = { x = x + rnd(-0.4, 0.4) * u, y = H - rnd(0, 0.1) * u, vx = rnd(-1, 1) * u,
                                  vy = -rnd(1.5, 3) * u, r = rnd(0.04, 0.09) * u, t = 0 }
        end
    end
    local queue = {}                 -- clips to play (a stop, a turn)
    local met = {}                   -- (the princess: those she met)
    local stopped = math.random() < 0.4         -- (one stop per screen at most, and not always)
    local stop_x = free_x(0.25 * W, 0.75 * W)
    local linger = 0
    local puffs = {}
    local function play(...)          -- (the clips given; a missing one is left out)
        queue = {}
        for i = 1, select("#", ...) do
            local q = select(i, ...)
            if q then queue[#queue + 1] = q end
        end
        state, tc = "act", 0
    end
    local function turn_round()
        dir = -dir
        a.handed_on = nil
        play(C.turn_front and { "turn_front", m = dir > 0 }, { "idle", dur = rnd(0.5, 1.5) },
             C.turn_side and { "turn_side", m = dir < 0 })
    end
    local function spin_item(c, r0, r1)   -- (a spin, queued: twice through the clip, its rate r0..r1)
        return { "spin", spin = { r0, r1 }, dur = 2 * 2 * c.count / (c.fps * (r0 + r1)) }
    end
    local function act_step()
        local q = queue[1]
        if not q then state, tc = "walk", 0 return nil end
        local cc = C[q[1]] or C.idle
        local len = q.dur or (cc.loop and 1 or cc.count / cc.fps)
        if tc >= len then
            if q.after then q.after() end
            table.remove(queue, 1)
            tc = 0
            return act_step()
        end
        return cc, q.m
    end
    -- a spell on each other (the witch and the princess, see next_act): it faces the viewer and at
    -- the time given, in a puff, it's the other (sp, f) - a cackle or a cheer, and on as that
    -- spin: spun into the other one (the princess and the werewolf: faster and faster as herself, in
    -- the puff on as the she-wolf, slowing down - both sprites with a spin clip, see spin_item)
    function a.swap_into(sp, f, at, pre, spin)
        if spin and C.spin and sp.clips.spin then
            a.swap = { spr = sp, fam = f, at = math.huge, spin = true }
            local up = spin_item(C.spin, 0.6, 2.6)
            up.after = function() a.swap.at = mp.get_time() end
            play(C.turn_front and { "turn_front", m = dir < 0 }, pre and C[pre] and { pre }, up, { "idle", dur = 30 })
            return
        end
        a.swap = { spr = sp, fam = f, at = at }
        play(C.turn_front and { "turn_front", m = dir < 0 }, pre and C[pre] and { pre }, { "idle", dur = 30 })
    end
    -- a spell on itself (the witch, see next_act): it faces the viewer, casts, and in a puff it's
    -- someone else of the cast (sp, f) - or a creature: "raven" (flies off), "cat" (strolls on)
    function a.morph(kind, sp, f, pre)          -- (pre: the clip before the puff, "cast" by default)
        pre = C[pre or "cast"] and (pre or "cast")
        local at = mp.get_time() + (pre and C[pre].count / C[pre].fps or 0.8) + (C.turn_front and 0.5 or 0)
        if kind == "person" then return a.swap_into(sp, f, at, pre) end
        a.morphing = { kind = kind, at = at, sp = sp }
        play(C.turn_front and { "turn_front", m = dir < 0 }, pre and { pre }, { "idle", dur = 30 })
    end
    function a.spell()                          -- (it casts a spell on another: faces the viewer, casts, on)
        play(C.turn_front and { "turn_front", m = dir < 0 }, C.cast and { "cast" }, { "idle", dur = 0.6 },
             C.turn_side and { "turn_side", m = dir < 0 })
        return (C.turn_front and 0.5 or 0) + (C.cast and C.cast.count / C.cast.fps or 0.8)
    end
    if h.puff then a.swap = { spr = spr, fam = fam, at = mp.get_time() } end     -- (out of a puff, here)
    -- walking the same way as another (other), close by and nothing to do with it: not that - its
    -- next act now (a spell...), or it turns round, or it stops a while and lets the other go on
    function a.pause(dur)              -- (it stops, faces the viewer a while - a sarcophagus coming up)
        play(C.turn_front and { "turn_front", m = dir < 0 }, { "idle", dur = dur }, C.turn_side and { "turn_side", m = dir < 0 })
    end
    function a.avoid(other)
        if state ~= "walk" or a.meal or a.called or a.doomed or a.boxed or a.swap or a.morphing or a.lured then return false end
        local r, what = math.random(), nil
        a.avoided = (a.avoided or 0) + 1
        if (r < 0.3 or a.avoided > 2) and (a.ttl or 0) > 0 and next_act(a) then
            what = "its next act"
        elseif a.avoided > 1 then                   -- (again: it no longer hangs about here)
            linger = math.huge
            if (dir > 0 and x < 0.3 * W) or (dir < 0 and x > 0.7 * W) then turn_round() end
            what = "walks on, off the screen"
        elseif r < 0.65 and not a.staged then
            turn_round()
            what = "turns round"
        else
            play(C.turn_front and { "turn_front", m = dir < 0 }, { "idle", dur = rnd(2.5, 5) },
                 C.turn_side and { "turn_side", m = dir < 0 })
            what = "stops a while"
        end
        msg.verbose("cast: the " .. fam .. " going the same way as the " .. tostring(actor_family(other)) .. " - " .. what)
        return true
    end
    function a.update(dt, t)
        tc = tc + dt
        a.ttl = a.ttl - dt
        a.age = a.age + dt
        local now = mp.get_time()
        -- the witch's time up: she doesn't walk off, she goes with a spell on herself
        if fam == "witch" and a.ttl <= 0 and not a.ttl_spell and state == "walk" and not a.swap and not a.morphing
                and not a.called and x > 0.15 * W and x < 0.85 * W then
            a.ttl_spell = true
            local opts = { "raven", "cat", "princess" }
            a.force_morph = opts[math.random(#opts)]
            if not next_act(a) then
                a.force_morph = "raven"
                next_act(a)
            end
        end
        -- its time up (ttl): it wants out (a.out_since) - a sarcophagus may come up in its way for it
        -- (hooks.pickup); still here a while after (el.out_force): out by a cheat - in a puff a frog
        -- hopping off (the vampire: a raven flying off), or down into the ground
        if a.ttl <= 0 and fam ~= "witch" then
            a.out_since = a.out_since or now
            if state == "walk" and x > 0.15 * W and x < 0.85 * W
                    and not (a.swap or a.morphing or a.called or a.doomed or a.boxed or a.meal or a.lured) then
                if not a.pickup_tried and now - a.out_since > 2 then
                    a.pickup_tried = true
                    if (fam == "vampire" or fam == "princess_vampire") and math.random() < (el.coffin_chance or 0.8) then
                        hooks.coffin_in({ a })                      -- (a vampire: its own coffin)
                    elseif a.pickup_sure or math.random() < (el.pickup_chance or 0.5) then hooks.pickup(a) end
                elseif not a.forced and now - a.out_since > (el.out_force or 10) then
                    a.forced = true
                    if math.random() < (el.cheat_chance or 0.7) then
                        local wel = witch_el()
                        local rv = wel and M.sprites[wel.raven or ""]
                        if TUNNEL[fam] then
                            a.out, down_x = true, x + dir * 0.4 * u
                        elseif (fam == "vampire" or fam == "princess_vampire") and hooks.bat_sprite() then
                            a.morph("bat", hooks.bat_sprite())
                        elseif fam == "vampire" and rv and rv.clips and rv.clips.fly then
                            a.morph("raven", rv)
                        elseif fam ~= "princess" and frog_sprite() then      -- (she: a frog's kiss, hooks.MEETS)
                            a.morph("frog", frog_sprite())
                        end
                        msg.verbose("cast: the " .. fam .. "'s time is up - out by a cheat")
                    end
                end
            end
        end
        local mo = a.morphing
        if mo and not mo.done and now >= mo.at then
            mo.done = true
            a.family, a.groups = nil, {}                  -- (no longer one of the cast here)
            for _ = 1, 8 do
                puffs[#puffs + 1] = { x = x + rnd(-0.5, 0.5) * u, y = H - rnd(0.2, 1.8) * u,
                                      r = rnd(0.25, 0.45) * u, vx = rnd(-0.5, 0.5) * u, t = 0 }
            end
            if mo.kind == "raven" and mo.sp and spawn.bird and #free_ids > 0 then
                local b = spawn.bird(el, mo.sp, { dir = dir, at = x, y = (H - 1.3 * u) / H, hops = 0, from = h.from,
                                                  ttl = math.floor(rnd(60, 180)) })
                if b then adopt(b, el, { hops = 0 }) end
            elseif mo.kind == "bat" and mo.sp and #free_ids > 0 then
                local b = spawn.bat(el, mo.sp, { dir = dir, at = x, y = (H - 1.6 * u) / H, hops = 0, from = h.from, vamp = fam,
                                                 ttl = math.floor(rnd(40, 90)) })
                if b then adopt(b, el, { hops = 0 }) end
            elseif mo.kind == "cat" and hooks.cat_at then
                hooks.cat_at(x, dir)
            elseif mo.kind == "frog" and mo.sp and #free_ids > 0 then
                local f = spawn.hopper(el, mo.sp, { dir = dir, at = x, hops = 0, from = h.from, ttl = math.floor(rnd(60, 150)) })
                if f then adopt(f, el, { hops = 0 }) end
            end
            msg.verbose("cast: in a puff, the " .. fam .. " is a " .. mo.kind)
        end
        if mo and mo.done then                        -- (gone: only the puff left)
            local keep = {}
            for _, q in ipairs(puffs) do
                q.t, q.x, q.y = q.t + dt, q.x + q.vx * dt, q.y - 0.5 * u * dt
                if q.t < 1.2 then keep[#keep + 1] = q end
            end
            puffs = keep
            if #puffs == 0 then return false end
            return true, {}
        end
        local sw = a.swap
        if sw and not sw.done and now >= sw.at then
            sw.done = true
            if fam == "princess" and sw.fam == "witch" then a.was_pr = true end
            local was = spr
            spr, C, fam = sw.spr, sw.spr.clips, sw.fam
            a.doomed = DOOMED[fam]                     -- (the princess turned: she goes)
            c = a.doomed and C.run or C.walk
            v = c.stride_px * c.fps / c.count * (el.speed or 1.0)
            a.spr, a.family = spr, fam
            if fam == "princess_zombie" then down_x = x + dir * rnd(1.2, 2.2) * u end
            if a.kin and (room.left or room.right) then down_x = x + dir * rnd(2, 4) * u end   -- (a new zombie: off under the ground)
            for _ = 1, 8 do
                puffs[#puffs + 1] = { x = x + rnd(-0.5, 0.5) * u, y = H - rnd(0.2, 1.8) * u,
                                      r = rnd(0.25, 0.45) * u, vx = rnd(-0.5, 0.5) * u, t = 0 }
            end
            local show = (C.cackle and "cackle") or (C.howl and "howl") or (C.cheer and "cheer") or (C.taunt and "taunt") or nil
            -- (the she-wolf: on as the werewolf's act, spinning back into the princess in the end)
            local wel
            for _, e in ipairs(M.elements) do if e.type == "werewolf" then wel = e end end
            local she = fam == "princess_wolf" and sw.spin and wel and spawn.werewolf and {
                "idle", dur = 0.05, after = function()
                    local b = #free_ids > 1 and spawn.werewolf(wel, was, { she = true, upright = true, dir = dir, at = x, hops = 0 })
                    if b then
                        adopt(b, wel, { hops = 0 })
                        a.gone = true
                        msg.verbose("cast: the she-wolf prowls about")
                    end
                end }
            play(sw.spin and C.spin and spin_item(C.spin, 2.6, 0.6) or { "idle", dur = 1.2 }, show and { show },
                 C.turn_side and { "turn_side", m = dir < 0 }, she or nil)
            msg.verbose("cast: in a puff, the " .. fam)
        end
        do
            local keep = {}
            for _, q in ipairs(puffs) do
                q.t, q.x, q.y = q.t + dt, q.x + q.vx * dt, q.y - 0.5 * u * dt
                if q.t < 1.2 then keep[#keep + 1] = q end
            end
            puffs = keep
            keep = {}
            for _, q in ipairs(clods) do
                q.t, q.vy = q.t + dt, q.vy + 6 * u * dt
                q.x, q.y = q.x + q.vx * dt, q.y + q.vy * dt
                if q.y < H + q.r then keep[#keep + 1] = q end
            end
            clods = keep
        end
        local rising = C.rise and TUNNEL[fam]           -- (its climbing out of the grave, played back to go in)
        if state == "under" then                         -- (on its way here, under the screens)
            a.under_t = a.under_t - dt
            if a.under_t > 0 then return true, {} end
            state, tc = "up", 0
            dirt(10)
            hooks.grave_at(x, -dir)
            msg.verbose("cast: up out of the ground, the " .. fam)
        end
        if state == "up" or state == "down" then
            local len = rising and C.rise.count / C.rise.fps or 1.6
            local p = clamp(tc / len, 0, 1)
            if state == "down" then p = 1 - p end
            dy = rising and 0 or (1 - p) * 2.6 * u
            if math.random() < dt * 8 and p < 0.9 then dirt(1) end
            if tc >= len then
                if state == "down" then
                    if a.doomed or a.out then return false end -- (the zombie princess, one whose time is up: gone)
                    -- off under the ground: to a screen a few along (one side or the other)
                    local sides = {}
                    if room.left then sides[#sides + 1] = "left" end
                    if room.right then sides[#sides + 1] = "right" end
                    local side = sides[math.random(#sides)]
                    local n = math.random(1, math.max(1, (room.screens or 2) - 1))
                    hand_over(side, { kind = "wanderer", el = el.index, sprite = spr.name, fam = fam, from = h.from,
                                      dir = side == "right" and 1 or -1, hops = 0, lead = 0, unique = false,
                                      ttl = math.floor(math.max(a.ttl, 15)), tunnel = n, went = 1, age = math.floor(a.age) })
                    msg.verbose("cast: the " .. fam .. " goes under the ground (" .. n .. " screens along)")
                    return false
                end
                dy, state, tc = 0, "act", 0
                play(C.turn_side and { "turn_side", m = dir < 0 })
            end
            local cc = rising and C.rise or C.idle
            local k = math.floor(clamp(state == "down" and (len - tc) or tc, 0, len - 1e-3) * cc.fps)
            k = cc.loop and k % cc.count or math.min(k, cc.count - 1)
            local ox = spr.origin[1]
            local layer = { spr = spr, frame = cc.start + k, variant = false, x = x - ox, y = H - spr.origin[2] + dy }
            a.sx, a.sy, a.cx, a.facing = layer.x, layer.y, x, dir
            return true, { layer }
        end
        local cc, m = c, dir < 0
        if state == "act" then
            local ac, am = act_step()
            if ac then cc, m = ac, am end
        end
        -- a zombie: a piece of brain lying here, off to it (in a hurry) to eat it up; a piece of its own
        -- may fall off at its stop (see new_brain)
        if a.eating and state == "walk" then       -- (eaten: and on, under the ground)
            a.meal, a.eating = nil, nil
            if (room.left or room.right) and not free_brain(a, x) then down_x = x + dir * rnd(0.2, 0.6) * u end
        end
        if zombie and state == "walk" and not a.meal and not a.called and a.handed_on ~= "yes" then
            local b = free_brain(a, x)
            if b then
                a.meal, b.eater, b.eater_t = b, a, now
                local side = b.cx >= x and 1 or -1
                meal_x = math.abs(b.cx - x) < 0.7 * u and x or b.cx - side * 0.55 * u
                if side ~= dir then dir, a.handed_on = side, nil end
                hurry, down_x = 2, nil
                msg.verbose("cast: the zombie is off to a piece of brain")
            end
        end
        if state == "walk" and a.meal and not a.eating and (meal_x - x) * dir <= 0.01 then
            x, hurry, a.eating = meal_x, 1, true
            play(C.pick and { "pick", m = dir < 0 }, { C.reach and "reach" or "idle", dur = 2.8, m = dir < 0 },
                 { "idle", dur = rnd(0.5, 1) })
        end
        if a.eating and state == "act" and not a.meal.lifted and not a.meal.gone then
            local pk = C.pick and C.pick.count / C.pick.fps or 0
            if tc > (pk > 0 and 0.45 * pk or 0.4) then a.meal.eat(x + dir * 0.38 * u, H - 1.5 * u, pk > 0 and 0.55 * pk or 0.5) end
        end
        if drop_at and now >= drop_at then
            drop_at = nil
            local B, zel = brain_sprite()
            if B and #free_ids > 0 then
                new_brain(zel, B, x + rnd(-0.1, 0.1) * u, H - 2.0 * u, rnd(0.5, 1.1) * u * (math.random() < 0.5 and -1 or 1), a, u)
                msg.verbose("cast: a piece of the zombie's brain falls off")
            end
        end
        if state == "walk" and down_x and math.abs(x - down_x) < v * hurry * dt * 2 and (a.ttl > 20 or a.doomed or a.out) and not a.called and not a.meal then
            down_x = nil
            play(C.turn_front and { "turn_front", m = dir < 0 }, { "idle", dur = rnd(0.5, 1.2) })
            a.digging = true
        end
        if state == "walk" and a.digging then
            state, tc, a.digging = "down", 0, nil
            dirt(6)
            hooks.grave_at(x, -dir)
            msg.verbose("cast: the " .. fam .. " digs itself into the ground")
            return true, {}
        end
        if state == "walk" then
            x = x + dir * v * hurry * dt
            if not a.meal and not a.doomed then cast_cue(a, dt, x) end
            -- a wolf asleep here: the princess goes to him
            if fam == "princess" and not a.swap and not a.called and not a.lured then
                for _, b in ipairs(actors) do
                    if b.asleep_x and not b.leaving then
                        a.lured, a.turn_sure, a.next_at = true, true, 1e9
                        if (b.asleep_x - x) * dir < 0 then turn_round() end
                        break
                    end
                end
            end
            -- meeting one close by: a reaction (the table hooks.MEETS)
            if hooks.meet(a, fam, x, u, now, met) == "gone" then return false end
            -- wanted here: hang about (to and fro) a while
            local el2, st = nil, nil
            if a.ttl > 0 and linger < (el.linger_max or 60) then el2, st = wanted_here(fam, now) end
            -- not wanted here, but next door (its gag lined up next): over there
            if not el2 and not a.staged and a.ttl > 0 and not a.meal and not a.doomed then
                local want = nil
                for _, side in ipairs({ "left", "right" }) do
                    for _, f in ipairs((room.wants or {})[side] or {}) do if f == fam then want = side end end
                end
                if want then
                    a.staged = true
                    msg.verbose("cast: the " .. fam .. " is wanted next door (" .. want .. ")")
                    if (want == "right") ~= (dir > 0) then turn_round() end
                end
            end
            if el2 then
                linger = linger + dt
                if st.next > now + 8 and not st.wait_since then st.next = now + rnd(3, 8) end
                -- (the witch walks on, to the screen next door: her cooking may be there)
                if fam ~= "witch" and ((dir > 0 and x > 0.8 * W) or (dir < 0 and x < 0.2 * W)) then turn_round() end
            elseif not stopped and not a.meal and math.abs(x - stop_x) < v * hurry * dt * 2 then
                stopped = true
                local show = (C.cheer and math.random() < 0.3 and "cheer") or (C.taunt and math.random() < 0.3 and "taunt") or nil
                play(C.turn_front and { "turn_front", m = dir < 0 }, { zombie and C.sniff and "sniff" or "idle", dur = rnd(1.5, 3.5) },
                     show and { show }, C.turn_side and { "turn_side", m = dir < 0 })
                if zombie and brains_here() < BRAINS_MAX and math.random() < (a.drop_chance or 0.3) then
                    drop_at = now + rnd(0.8, 1.4)
                end
                if zombie and not down_x and (room.left or room.right) then down_x = x + dir * rnd(0.3, 1.2) * u end
            end
            local lead = dir > 0 and (x + front - W) or (front - x)
            if lead >= 0 and a.ttl > 0 and not a.doomed then
                -- (no screen that way, or full there: back the other way - to the other neighbour)
                if not walk_out(a, x, dir, front, { kind = "wanderer", fam = fam, sprite = spr.name, ttl = math.floor(a.ttl),
                                                    unique = false, hops = 0, from = h.from, cooked = a.cooked,
                                                    was_pr = a.was_pr, age = math.floor(a.age),
                                                    brainy = a.brainy and math.floor(a.brainy) or nil }) then turn_round() end
            end
        end
        if (dir > 0 and x > W + 1.5 * u) or (dir < 0 and x < -1.5 * u) then return false end
        local k = math.floor(tc * cc.fps * (state == "walk" and hurry or 1))
        local q1 = state == "act" and queue[1]
        if q1 and q1.spin then                          -- (a spin, speeding up or slowing down)
            local r0, r1 = q1.spin[1], q1.spin[2]
            k = math.floor(cc.fps * (r0 * tc + (r1 - r0) * tc * tc / (2 * q1.dur))) % cc.count
        else
            k = cc.loop and k % cc.count or math.min(k, cc.count - 1)
        end
        local mi = m and true or false
        local ox = mi and (spr.w - spr.origin[1]) or spr.origin[1]
        local layer = { spr = spr, frame = cc.start + k, variant = mi, x = x - ox, y = H - spr.origin[2] }
        a.sx, a.sy, a.cx, a.facing = layer.x, layer.y, x, dir
        if a.brainy then                                -- (the brain on its skull, the eye in its socket)
            local tr = cc.track and cc.track.head and cc.track.head[k + 1]
            local hx, hy = x + (tr and (mi and -tr[1] or tr[1]) or 0), tr and (H + tr[2]) or (H - 2.0 * u)
            local f = mi and -1 or 1
            local bx, by = hx - f * 0.02 * u, hy - (el.brain_up or 0.86) * u
            local ex, ey = hx + f * (el.eye_x or 0.16) * u, hy - (el.eye_up or 0.34) * u
            a.brainy = a.brainy - dt
            if a.brainy <= 0 and state == "walk" then      -- out they fall
                a.brainy, a.layers = nil, 1
                local _, zel = brain_sprite()
                if zel and #free_ids > 1 then
                    new_brain(zel, BR, bx, by, f * rnd(0.3, 0.7) * u, a, u)
                    hooks.new_relic(el, { spr = EY, frame = EY.clips.lie.start, mx = EY.origin[1], my = EY.origin[2] - EY.h / 2,
                                          lie = EY.h / 2, kind = "eye" }, ex, ey, mi)
                end
                msg.verbose("cast: the skeleton's brain and eye fall out - a skeleton again")
            else
                return true, { layer, { spr = BR, frame = BR.clips.lie.start, variant = mi, x = bx - (mi and BR.w - BR.origin[1] or BR.origin[1]),
                                        y = by - BR.origin[2] },
                               { spr = EY, frame = EY.clips.lie.start, variant = mi, x = ex - (mi and EY.w - EY.origin[1] or EY.origin[1]),
                                 y = ey - EY.origin[2] + EY.h / 2 } }
            end
        end
        if sw and sw.done and not sw.spin and now - sw.at < 0.25 then return true, {} end     -- (the change, in the puff)
        return true, { layer }
    end
    function a.ass(out)
        for _, q in ipairs(puffs) do puff(out, q.x, q.y, q.r * (1 + 0.6 * q.t), 0.2 + 0.8 * q.t / 1.2) end
        for _, q in ipairs(clods) do puff(out, q.x, q.y, q.r, 0.1, "&H1E3A5A&") end
    end
    return a
end

-- Meetings: one of the cast walking about meets another close by -> a reaction. One entry per pair:
--   who, whom   the families (actor_family) of the walker and of the one met
--   near        how close (units, default 2)
--   chance      {el key, default chance} or function(a, b, el) -> chance; sure = the walker's flag that makes it certain (previews;
--               a.meet_sure makes any of its meetings certain)
--   ok(a, b)    extra test (both still free for it); go(a, b, x, now) the reaction: "gone" when the walker
--               is gone with it, true when it's taken (no more meetings this step)
-- Each pair is met once (met[b]), whether it comes off or not.
hooks.MEETS = {
    -- the princess meets the werewolf, a zombie, the vampire: she may be turned
    { who = "princess", whom = { "werewolf", "zombie", "vampire" }, near = 2.5, chance = { "turn_chance", 0.6 }, sure = "turn_sure",
      ok = function(a, b) return b.groups and #b.groups > 0 end,
      go = function(a, b, x, now)
          local kind = actor_family(b)
          local sp = turned_sprite(kind)
          if not sp then return end
          a.swap_into(sp, TURNED[kind], now + 1.6, "shock", kind == "werewolf")
          msg.verbose("cast: the princess meets the " .. kind .. " - she's turned")
          return true
      end },
    -- a zombie meets a skeleton: no brains there - but they fight (hooks.zombie_fight)
    { who = "zombie", whom = "skeleton", near = 1.6, chance = { "zombie_fight", 0.6 }, sure = "fight_sure",
      ok = function(a, b)
          return not a.meal and not a.out_since and (b.family or b.el.type == "performer") and b.cx
              and not b.swap and not b.called and not b.brainy and b.cx > 0.08 * W and b.cx < 0.92 * W
      end,
      go = function(a, b, x) if hooks.zombie_fight(a, b, x) then return "gone" end end },
    -- the princess meets a frog: a kiss - and she's the frog (likelier when her time's up)
    { who = "princess", whom = "frog", near = 0.9, chance = { "frog_kiss", 0.2 }, sure = "out_since",
      ok = function(a, b) return not b.rising and #free_ids > 0 and frog_sprite() end,
      go = function(a, b)
          if (b.cx - a.cx) * (a.facing or 1) < 0 then return end          -- (one ahead of her)
          a.morph("frog", frog_sprite(), nil, "kiss")
          msg.verbose("cast: the princess kisses a frog - and she's a frog herself")
          return true
      end },
    -- the witch meets the princess: a spell - the princess is a frog (likelier when her time's up)
    { who = "witch", whom = "princess", near = 2.2,
      chance = function(a, b, el) return b.out_since and 0.9 or (el.witch_frog or 0.12) end,
      ok = function(a, b)
          return b.morph and b.pause and not b.swap and not b.morphing and not b.called
              and #free_ids > 0 and frog_sprite()
      end,
      go = function(a, b, x, now)
          local dur = a.spell()
          b.pause(dur + 1)
          b.morphing = { kind = "frog", at = now + dur, sp = frog_sprite() }
          msg.verbose("witch: a spell on the princess - she's a frog")
          return true
      end },
    -- the vampire meets the princess vampire: a coffin for two - in they jump, it wiggles, it sinks
    { who = "vampire", whom = "princess_vampire", near = 3, chance = { "coffin_two", 0.5 },
      ok = function(a, b) return b.pause and not b.swap and not b.morphing and not b.called and not b.boxed and not b.doomed end,
      go = function(a, b) if hooks.coffin_in({ a, b }) then return true end end },
    -- the werewolf man meets a zombie: it gets him - he's a zombie too
    { who = "werewolf", whom = "zombie", chance = { "zombie_chance", 0.7 },
      go = function(a, b, x, now)
          local zsp = cast_sprite("zombie")
          if not zsp then return end
          a.kin = true
          a.swap_into(zsp, "zombie", now + 1.6, "shock")
          msg.verbose("cast: the werewolf man meets the zombie - he's a zombie too")
          return true
      end },
}

-- the walker a (family fam, at x; unit u) looks for one to meet (see hooks.MEETS); met: the ones it has met
function hooks.meet(a, fam, x, u, now, met)
    if a.swap or a.morphing or a.called or a.doomed or a.boxed then return end
    local el = a.el
    for _, m in ipairs(hooks.MEETS) do
        if m.who == fam then
            for _, b in ipairs(actors) do
                local bf = b ~= a and not met[b] and not b.gone and not b.leaving and (b.cx or b.zx) and (b.frog and "frog" or actor_family(b))
                local whom = bf and (type(m.whom) == "table" and m.whom or { m.whom })
                local hit = false
                if whom then for _, w in ipairs(whom) do if w == bf then hit = true end end end
                if hit and math.abs((b.cx or b.zx) - x) < (m.near or 2) * u and (not m.ok or m.ok(a, b)) then
                    met[b] = true
                    local c = m.chance or {}
                    local p = type(c) == "function" and c(a, b, el) or (el[c[1]] or c[2] or 1)
                    if a.meet_sure or (m.sure and a[m.sure]) or math.random() < p then
                        local r = m.go(a, b, x, now)
                        if r then return r end
                    end
                end
            end
        end
    end
end

-- a zombie (z, at zx) meets a skeleton (sk): no brains there - but they fight, in a cloud of dust.
-- Out of it the skeleton with the zombie's brain and an eye; the zombie lies about in pieces
function hooks.zombie_fight(z, sk, zx)
    local ce, ssp = cast_el(), cast_sprite("skeleton")
    if not (ce and ssp and #free_ids > 3) then return false end
    local mx, sd, zs = (zx + sk.cx) / 2, sk.facing or 1, z.spr
    sk.gone = true
    msg.verbose("cast: the zombie meets a skeleton - no brains there... a fight!")
    hooks.dust_fight(ce, mx, 2.6, function()
        local b = #free_ids > 2 and spawn.wanderer(ce, ssp, { fam = "skeleton", dir = sd, at = mx, hops = 0, brainy = true,
                                                              ttl = math.floor(rnd(40, 80)) })
        if b then adopt(b, ce, { hops = 0 }) end
        local T = PIECES.by[zs.name]
        for i, p in ipairs(T or {}) do
            local c = zs.clips[p[1]]
            if c and #free_ids > 0 then
                local px = mx + rnd(-1.4, 1.4) * zs.unit * H
                hooks.new_relic(ce, PIECES.relic(zs, i, c.start + math.random(0, c.count - 1)), px, H - 1.4 * zs.unit * H, false)
            end
        end
        msg.verbose("cast: out of the dust, the skeleton - with the zombie's brain and eye")
    end)
    return true
end

-- the witch out of a puff at x (a raven sitting there, the cat): true if she's there now
hooks.witch_from = function(x, dir)
    local el = witch_el()
    local spr = el and M.sprites[el.sprite or ""]
    if not (spr and may_be("witch") and #free_ids > 0 and element_on(el)) then return false end
    local a = spawn.wanderer(el, spr, { fam = "witch", dir = dir, at = x, hops = 0, from = "witch", puff = true,
                                        ttl = math.floor(rnd(range(el.cast_ttl, 180))) })
    if not a then return false end
    adopt(a, el, { hops = 0 })
    return true
end

-- bird: a raven the witch turned into (el.raven, tools/bake/bird.py): it flies across - over to the
-- screen next door - and now and then comes down to sit on the ground a while, looking about; sat
-- there, it may turn back into the witch (none about). Its time up, it flies up and away.
function spawn.bird(el, spr, h)
    local B = spr.clips
    if not (B and B.fly and B.sit and spr.origin and spr.unit) then return nil end
    local u = spr.unit * H
    local dir = h.dir == 1 and 1 or -1
    local v = rnd(0.12, 0.18) * W
    local front = 0.4 * u
    local x = walk_in_x(h, v, front)
    local y = clamp(tonumber(h.y) or 0.3, 0.05, 1) * H
    local a = { el = el, spr = spr, layers = 1, groups = {}, bird = true }
    a.hops, a.ttl = 0, tonumber(h.ttl) or 90
    local ty = rnd(0.15, 0.45) * H                   -- (its height, flying)
    local land = not h.at and math.random() < 0.6 and rnd(0.25, 0.75) * W or nil    -- (not where it was the witch)
    if land and (land - x) * dir < 0.15 * W then land = nil end
    local state, t, x0, y0, sit = "fly", 0, x, y, 0
    function a.update(dt)
        t = t + dt
        a.ttl = a.ttl - dt
        local clip, k, m = "fly", math.floor(t * B.fly.fps) % B.fly.count, dir < 0
        if state == "fly" then
            x = x + dir * v * dt
            local want = ty + 0.03 * H * math.sin(t * 2.1)
            if land and math.abs(land - x) < 0.25 * W then          -- (gliding down to it)
                want = H - (H - ty) * clamp(math.abs(land - x) / (0.25 * W), 0, 1)
                if (land - x) * dir <= 0 then
                    state, t, x, y, sit = "sit", 0, land, H, rnd(6, 14)
                    msg.verbose("bird: the raven comes down to sit")
                end
            end
            y = y + clamp(want - y, -0.25 * H * dt, 0.3 * H * dt)
            if a.ttl <= 0 then state, t, x0, y0 = "away", 0, x, y end
            if state == "fly" and not walk_out(a, x, dir, front, { kind = "bird", unique = false, hops = 0, from = h.from,
                                                                   y = y / H, ttl = math.floor(a.ttl) })
                    and ((dir > 0 and x > W - front) or (dir < 0 and x < front)) then
                state, t, x0, y0 = "away", 0, x, y       -- (nowhere to go on: up and away)
            end
        elseif state == "sit" then
            clip, k = "sit", math.floor(t * B.sit.fps) % B.sit.count
            if t > 3 and not a.asked then
                a.asked = true
                if math.random() < (el.witch_back or 0.15) and hooks.witch_from(x, dir) then
                    msg.verbose("bird: in a puff, the raven is the witch")
                    return false
                end
            end
            if t > sit then
                land, ty = nil, rnd(0.15, 0.45) * H
                if math.random() < 0.3 then dir = -dir end
                state, t, a.handed_on = "fly", 0, nil
            end
        else                                            -- (up and away, off the top)
            x = x0 + dir * v * t
            y = y0 - 0.5 * H * t * t
            if y < -spr.h then return false end
        end
        if (dir > 0 and x > W + spr.w) or (dir < 0 and x < -spr.w) then return false end
        local ox = m and (spr.w - spr.origin[1]) or spr.origin[1]
        a.cx = x
        return true, { { spr = spr, frame = B[clip].start + k, variant = m, x = x - ox, y = y - spr.origin[2] } }
    end
    return a
end

-- the vampire (fam: or the princess vampire) out of a puff at x (a bat come down there): true if so
function hooks.vampire_from(x, dir, fam)
    local ce = cast_el()
    local sp = fam == "princess_vampire" and turned_sprite("vampire") or cast_sprite("vampire")
    if not (ce and sp and may_be(fam) and #free_ids > 0) then return false end
    local a = spawn.wanderer(ce, sp, { fam = fam, dir = dir, at = x, hops = 0, puff = true, ttl = math.floor(rnd(40, 90)) })
    if not a then return false end
    adopt(a, ce, { hops = 0 })
    return true
end

-- bat: the vampire as a bat (the vampire element's el.bat, tools/bake/bat.py; h.vamp: who it is -
-- the vampire or the princess vampire). It flutters across, over to the screen next door; now and
-- then it flies up to hang from the top a while (folding up: its unfold clip backwards) and drops
-- off again, or it comes down to the ground and in a puff is the vampire again (none about). Its
-- time up, it flies up and away. Origin: its feet (hanging); flying, the body is below them.
function spawn.bat(el, spr, h)
    local B = spr.clips
    if not (B and B.fly and B.hang and B.unfold and spr.origin and spr.unit) then return nil end
    local u = spr.unit * H
    local dir = h.dir == 1 and 1 or -1
    local v = rnd(0.14, 0.22) * W
    local front = 0.5 * u
    local x = walk_in_x(h, v, front)
    local y = clamp(tonumber(h.y) or 0.3, 0.02, 1) * H
    local a = { el = el, spr = spr, layers = 1, groups = {}, bird = true }
    a.hops, a.ttl = 0, tonumber(h.ttl) or 60
    local vamp = h.vamp
    local ty = rnd(0.1, 0.35) * H
    local spot, down
    local function plan()           -- (somewhere ahead: hang there, or come down - as the vampire)
        spot = math.random() < 0.6 and x + dir * rnd(0.2, 0.5) * W or nil
        if spot and (spot < 0.1 * W or spot > 0.9 * W) then spot = nil end
        down = spot and vamp and math.random() < (h.down or 0.5)
    end
    plan()
    local state, t, tt, x0, y0, stay = "fly", 0, 0, x, y, 0
    local uc = B.unfold.count / B.unfold.fps
    function a.update(dt)
        t, tt = t + dt, tt + dt
        a.ttl = a.ttl - dt
        local clip, k = "fly", math.floor(tt * B.fly.fps) % B.fly.count
        if state == "fly" then
            x = x + dir * v * dt
            y = y + clamp(ty + 0.04 * H * math.sin(tt * 3.3) - y, -0.3 * H * dt, 0.3 * H * dt)
            if spot and (spot - x) * dir <= 0 then
                state, t = down and "down" or "up", 0
                msg.verbose("bat: " .. (down and "comes down" or "up to hang a while"))
            end
            if a.ttl <= 0 then state, t, x0, y0 = "away", 0, x, y end
            if state == "fly" and not walk_out(a, x, dir, front, { kind = "bat", unique = false, hops = 0, from = h.from,
                                                                   y = y / H, ttl = math.floor(a.ttl), vamp = vamp })
                    and ((dir > 0 and x > W - front) or (dir < 0 and x < front)) then
                state, t, x0, y0 = "away", 0, x, y
            end
        elseif state == "up" then
            x = x + dir * 0.1 * v * dt
            y = y - 0.4 * H * dt
            if y <= 0.005 * H then y, state, t = 0.005 * H, "fold", 0 end
        elseif state == "fold" or state == "unfold" then
            clip = "unfold"
            k = math.min(math.floor(t * B.unfold.fps), B.unfold.count - 1)
            if state == "fold" then k = B.unfold.count - 1 - k end
            if t >= uc then
                if state == "fold" then state, t, stay = "hang", 0, rnd(5, 12)
                else state, t, tt, ty = "fly", 0, 0, rnd(0.15, 0.35) * H plan() end
            end
        elseif state == "hang" then
            clip, k = "hang", math.floor(t * B.hang.fps) % B.hang.count
            if t > stay or a.ttl <= 0 then state, t = "unfold", 0 end
        elseif state == "down" then
            x = x + dir * 0.2 * v * dt
            y = y + 0.4 * H * dt
            if y >= H - 0.75 * u then
                if hooks.vampire_from(x, dir, vamp) then
                    msg.verbose("bat: in a puff, the bat is the " .. tostring(vamp))
                    return false
                end
                state, t, ty, spot = "fly", 0, rnd(0.15, 0.35) * H, nil
            end
        else                                            -- (up and away, off the top)
            x = x0 + dir * v * t
            y = y0 - 0.5 * H * t * t
            if y < -spr.h then return false end
        end
        if (dir > 0 and x > W + spr.w) or (dir < 0 and x < -spr.w) then return false end
        local m = dir < 0
        local ox = m and (spr.w - spr.origin[1]) or spr.origin[1]
        a.cx = x
        return true, { { spr = spr, frame = B[clip].start + k, variant = m, x = x - ox, y = y - spr.origin[2] } }
    end
    return a
end

-- carriage: the witch's pumpkin carriage, mice and all (tools/bake/carriage.py), come over from the
-- screen next door (h.legs: screens still to go). It drives through - or stops, the door opens and
-- someone steps out (el.riders: one of the cast not about), the door shuts and on it drives; on
-- its last screen, after that, in a puff it's a pumpkin again (lying there: see below).
function spawn.carriage(el, spr, h)
    local C = spr.clips
    if not (C and C.drive and C.stand and C.door and spr.origin and spr.unit) then return nil end
    local u = spr.unit * H
    local dir = h.dir == 1 and 1 or -1
    local c = C.drive
    local v = c.stride_px * c.fps / c.count
    local front = 2.7 * u
    local x = walk_in_x(h, v, front)
    local legs = tonumber(h.legs) or 0
    local a = { el = el, spr = spr, layers = 1, groups = {}, scene = true }
    local plan = legs <= 0 and "end" or (math.random() < 0.55 and "through" or "drop")
    local stop_x = rnd(0.4, 0.6) * W
    local state, tc, stopped = "drive", 0, false
    local puffs = {}
    local function rider()                         -- one of the cast not about (sprite, family)
        local ok = {}
        for _, r in ipairs(el.riders or {}) do
            local sp = M.sprites[r.sprite or ""]
            local n, same = chars_here(r.family)
            if sp and r.family and not same and n < 2 and not room.taken["chr:" .. r.family] and not taken(sp) then
                ok[#ok + 1] = { sp, r.family }
            end
        end
        if #ok > 0 then
            local r = ok[math.random(#ok)]
            return r[1], r[2]
        end
    end
    local function len(n) return C[n].count / C[n].fps end
    function a.update(dt)
        tc = tc + dt
        local cc, k = C.stand, nil
        if state == "drive" then
            cc = C.drive
            x = x + dir * v * dt
            if plan ~= "through" and not stopped and (dir > 0 and x >= stop_x or dir < 0 and x <= stop_x) then
                stopped, state, tc = true, "stand", 0
            elseif plan ~= "end" then
                walk_out(a, x, dir, front, { kind = "carriage", unique = false, hops = 0, from = h.from, legs = legs - 1 })
            end
        elseif state == "stand" then
            if tc > 1.0 then
                a.who, a.fam = rider()
                state, tc = a.who and "open" or (plan == "end" and "poof" or "drive"), 0
                if state == "poof" then a.poof() end
            end
        elseif state == "open" then
            cc = C.door
            if tc >= len("door") then
                local b = spawn.wanderer(el, a.who, { fam = a.fam, dir = -dir, at = x, hops = 0, from = h.from,
                                                      ttl = math.floor(rnd(range(el.cast_ttl, 180))) })
                if b and #free_ids >= 1 then
                    adopt(b, el, { hops = 0 })
                    if b.id < a.id then                 -- (in front of the coach, stepping out)
                        a.id, b.id = b.id, a.id
                        a.ids, b.ids = { a.id }, { b.id }
                    end
                    msg.verbose("carriage: out steps the " .. a.fam)
                end
                state, tc = "wait", 0
            end
        elseif state == "wait" then
            cc, k = C.door, C.door.count - 1
            if tc > 1.6 then state, tc = "close", 0 end
        elseif state == "close" then
            cc = C.door
            k = math.max(0, C.door.count - 1 - math.floor(tc * cc.fps))
            if tc >= len("door") then state, tc = "shut", 0 end
        elseif state == "shut" then
            if tc > 0.8 then
                if plan == "end" then a.poof() else state, tc = "drive", 0 end
            end
        elseif state == "poof" then
            if tc > 1.3 then return false end
        end
        local keep = {}
        for _, q in ipairs(puffs) do
            q.t, q.x, q.y = q.t + dt, q.x + q.vx * dt, q.y - 0.5 * u * dt
            if q.t < 1.2 then keep[#keep + 1] = q end
        end
        puffs = keep
        if (dir > 0 and x > W + 1.4 * u) or (dir < 0 and x < -1.4 * u) then return false end
        a.cx = x
        if state == "poof" and tc > 0.25 then return true, {} end
        if not k then
            k = math.floor(tc * cc.fps)
            k = cc.loop and k % cc.count or math.min(k, cc.count - 1)
        end
        local mi = dir < 0
        local ox = mi and (spr.w - spr.origin[1]) or spr.origin[1]
        return true, { { spr = spr, frame = cc.start + k, variant = mi, x = x - ox, y = H - spr.origin[2] } }
    end
    function a.poof()                                -- a pumpkin again, lying there
        state, tc = "poof", 0
        for _ = 1, 14 do
            puffs[#puffs + 1] = { x = x + dir * rnd(-1.2, 2.6) * u, y = H - rnd(0.2, 2.0) * u,
                                  r = rnd(0.35, 0.6) * u, vx = rnd(-0.5, 0.5) * u, t = 0 }
        end
        local pk = M.sprites[el.pumpkin or ""]
        if pk and pk.clips and pk.clips.head and pk.clips.head.track and new_pumpkin then
            new_pumpkin(el, pk, x, dir < 0, rnd(range(el.pumpkin_ttl, 240)))
        end
        msg.verbose("carriage: in a puff, a pumpkin again")
    end
    function a.ass(out)
        for _, q in ipairs(puffs) do puff(out, q.x, q.y, q.r * (1 + 0.6 * q.t), 0.2 + 0.8 * q.t / 1.2) end
    end
    return a
end

-- Lying pumpkins: a pumpkin-head's head, set down (see below). It lies a while (or till a headless
-- one picks it up), then sinks into the ground. x: its middle; m: facing left.
function new_pumpkin(el, spr, x, m, ttl)
    local Hd = spr.clips.head
    local h0 = Hd.track.head[1]
    local u = spr.unit * H
    local a = { el = el, spr = spr, layers = 1, groups = {}, lying = true, cx = x, ttl = ttl or 240 }
    local sink = 0
    function a.update(dt)
        a.ttl = a.ttl - dt
        if a.gone then return false end
        if a.ttl <= 0 and not a.taken then sink = sink + dt * 0.4 end
        if sink >= 1 then return false end
        local sg = m and -1 or 1
        local ox = m and (spr.w - spr.origin[1]) or spr.origin[1]
        return true, { { spr = spr, frame = Hd.start, variant = m, x = x - sg * h0[1] - ox,
                         y = H - spr.origin[2] - 0.34 * u - h0[2] + sink * 0.8 * u } }
    end
    adopt(a, el, { hops = 0 })
    return a
end
function lying_pumpkin(spr, not_this, any)  -- (any: Frankenstein's head lying about will do too)
    for _, a in ipairs(actors) do
        if a.lying and a ~= not_this and not a.taken and not a.gone and (a.ttl or 0) > 5
                and (a.spr == spr and not a.relic or any and a.relic and a.relic.kind == "head") then return a end
    end
end

-- pumpkin-head: one of the cast (the witch's living pumpkin-head, a prince that was a frog), its
-- sprite with headless clips (*_nh) and its head alone ("head", the hands tracked: tools/bake). Near
-- a screen edge or something in its way (a scene, the frogs' pile, a pumpkin) it lifts its head off,
-- carries it down and leaves it lying - and walks on without it (h.headless). Headless, it makes for
-- a pumpkin lying about, picks it up and puts it on: a pumpkin-head again. More pumpkins about, so.
-- Frankenstein's head lying about will do as well: it walks on with that on (worn, h.relic).
function spawn.pumpkinhead(el, spr, h)
    local C = spr.clips
    if not (C.walk and C.walk_nh and C.idle_nh and C.lift_nh and C.pick_nh and C.head and C.head.track
            and C.lift_nh.track and C.pick_nh.track and spr.origin and spr.unit) then return nil end
    local u = spr.unit * H
    local dir = h.dir == 1 and 1 or -1
    local headless = h.headless and true or false
    local worn = PIECES.from(h)                  -- (Frankenstein's head on: see new_relic)
    if worn then headless = false end
    local front = 0.5 * u
    local x = walk_in_x(h, C.walk.stride_px * C.walk.fps / C.walk.count, front)
    local a = { el = el, spr = spr, layers = 2, groups = { "walker" }, family = "pumpkinhead", from = h.from }
    a.hops, a.ttl = 0, tonumber(h.ttl) or 60
    local h0 = C.head.track.head[1]
    local LT, PT = C.lift_nh.track, C.pick_nh.track
    local function mean(k) return { (LT["hand.l"][k + 1][1] + LT["hand.r"][k + 1][1]) / 2,
                                    (LT["hand.l"][k + 1][2] + LT["hand.r"][k + 1][2]) / 2 } end
    local function handr(k) return PT["hand.r"][k + 1] end
    local UP, LOW = 3, 6                         -- (lift_nh: hands at the head; pick_nh: at the ground)
    local lift = -0.12 * u
    local K = { h0[1] - mean(UP)[1], h0[2] + lift - mean(UP)[2] }        -- (the head over the hands)
    local G = { handr(LOW)[1], -0.34 * u }                              -- (lying, at the hand)
    local relC = { mean(0)[1] + K[1] - handr(0)[1], mean(0)[2] + K[2] - handr(0)[2] }
    local relG = { G[1] - handr(LOW)[1], G[2] - handr(LOW)[2] }
    local function lerp2(p, q, t) return { p[1] + (q[1] - p[1]) * t, p[2] + (q[2] - p[2]) * t } end
    local function add2(p, q) return { p[1] + q[1], p[2] + q[2] } end

    local state, tc = "walk", 0
    local seq, si = nil, 0
    local decided, target = false, nil
    local pumpkin                                -- (the one lying it's picking up)
    local down                                   -- (the one just set down: {x, m})
    local function leave_it()
        if not down then return end
        if down.worn then
            a.dropped = hooks.new_relic(el, down.worn, down.x, H - down.worn.lie, down.m)
        else
            a.dropped = new_pumpkin(el, spr, down.x, down.m, rnd(range(el.pumpkin_ttl, 240)))
        end
        down = nil
    end
    -- the head-off and head-on: phases {clip, f0, f1 (frames, either way) or hold+dur, head(k, p):
    -- where its middle is (sprite px from the feet, facing right), nil: on the body / not drawn}
    local function doff()
        return {
            { clip = "lift_nh", f0 = 0, f1 = UP, head = function() return h0 end },
            { clip = "lift_nh", hold = UP, dur = 0.5, head = function(_, p) return { h0[1], h0[2] + lift * p } end },
            { clip = "lift_nh", f0 = UP, f1 = 0, rate = 0.5, head = function(k) return add2(mean(k), K) end },
            { clip = "pick_nh", f0 = 0, f1 = LOW, rate = 0.6, head = function(k) return add2(handr(k), lerp2(relC, relG, k / LOW)) end },
            { clip = "pick_nh", f0 = LOW, f1 = 15, head = false, on = function()
                -- (it lies there: drawn under it while it steps past, then left lying)
                down = { x = x + dir * G[1], m = dir < 0, worn = worn }
                headless, worn = true, nil
                msg.verbose("pumpkin-head: off with its head - a pumpkin lies there")
            end },
        }
    end
    local function don()
        return {
            { clip = "pick_nh", f0 = 0, f1 = LOW, head = false },
            { clip = "pick_nh", f0 = LOW, f1 = 15, on = function()
                if pumpkin then pumpkin.gone, worn = true, pumpkin.relic end
                if worn and worn.spr.clips.piece_head then                      -- (upright on its neck)
                    worn = PIECES.relic(worn.spr, 1, worn.spr.clips.piece_head.start)
                end
                msg.verbose("pumpkin-head: picks up a " .. (worn and "head - Frankenstein's" or "pumpkin"))
            end, head = function(k) return add2(handr(k), lerp2(relG, relC, (k - LOW) / (15 - LOW))) end },
            { clip = "lift_nh", f0 = 0, f1 = UP, head = function(k) return add2(mean(k), K) end },
            { clip = "lift_nh", hold = UP, dur = 0.5, head = function(_, p) return { h0[1], h0[2] + lift * (1 - p) } end },
            pumpkin and pumpkin.relic and { clip = "idle_nh", f0 = 0, f1 = math.min(10, C.idle_nh.count - 1), head = function() return h0 end,
              on = function()
                headless = false
                msg.verbose("pumpkin-head: and it's on - Frankenstein's head")
            end } or { clip = "cheer", f0 = 0, f1 = C.cheer and C.cheer.count - 1 or 0, head = false, on = function()
                headless = false
                msg.verbose("pumpkin-head: and it's on - a pumpkin-head again")
            end },
        }
    end
    local function turn_round()
        dir = -dir
        a.handed_on = nil
    end
    local function in_the_way()
        for _, b in ipairs(actors) do
            if b ~= a and (b.scene or b.pile or b.lying) and b.cx then
                local ahead = (b.cx - x) * dir
                if ahead > 0.8 * u and ahead < 2.2 * u then return true end
            end
        end
        return false
    end

    function a.update(dt, t)
        tc = tc + dt
        a.ttl = a.ttl - dt
        local clip, k, headp = (headless or worn) and "walk_nh" or "walk", nil, nil
        if state == "walk" then
            local c = C[clip]
            local v = c.stride_px * c.fps / c.count * (el.speed or 1.0)
            x = x + dir * v * dt
            k = math.floor(tc * c.fps) % c.count
            if not headless and not decided then
                -- (near the edge: off it comes - not quite there, where the decor stands)
                local edge = (dir > 0 and x > 0.82 * W) or (dir < 0 and x < 0.18 * W)
                if h.doff_at then edge = (x - h.doff_at) * dir > 0 end
                if (edge and x > 0.1 * W and x < 0.9 * W) or in_the_way() then
                    decided = true
                    if h.doff_at or math.random() < (el.doff_chance or 0.7) then
                        state, seq, si, tc = "seq", doff(), 1, 0
                        msg.verbose("pumpkin-head: lifts its head off")
                    end
                end
            elseif headless and a.ttl > 0 then
                target = target and not target.gone and target or lying_pumpkin(spr, a.dropped, true)   -- (not its own)
                if target and not target.taken then
                    local face = target.cx > x and 1 or -1
                    if face ~= dir and math.abs(target.cx - x) > G[1] + 0.2 * u then turn_round() end   -- (the other way)
                    local spot = target.cx - dir * G[1]             -- (where it stands to pick it up)
                    local ahead = (spot - x) * dir
                    if math.abs(ahead) <= v * dt * 1.5 then
                        x, pumpkin, target.taken = spot, target, a
                        state, seq, si, tc = "seq", don(), 1, 0
                        msg.verbose("pumpkin-head: headless, it bends down to a pumpkin")
                    elseif ahead < 0 and ahead > -1.0 * u then x = x - dir * v * dt * 2 end     -- (a step back)
                end
            end
            local lead = dir > 0 and (x + front - W) or (front - x)
            -- (at the edge mostly gone for good: off it walks, not over to the screen next door)
            if state == "walk" and lead >= 0 and a.goes_off == nil then a.goes_off = math.random() < (el.pumpkin_off or 0.85) end
            if state == "walk" and lead >= 0 and a.ttl > 0 and not a.goes_off then
                if not walk_out(a, x, dir, front, { kind = "wanderer", fam = "pumpkinhead", headless = headless or nil,
                                                    ttl = math.floor(a.ttl), unique = false, hops = 0, from = a.from,
                                                    relic = PIECES.pass(worn) }) then
                    turn_round()
                end
            end
            if down and math.abs(x - down.x) > 1.3 * u then leave_it() end
            if (dir > 0 and x > W + 1.5 * u) or (dir < 0 and x < -1.5 * u) then leave_it() return false end
        end
        if state == "seq" then
            local ph = seq[si]
            if not ph then state, tc, decided = "walk", 0, true
            else
                if ph.on and not ph.done_on then ph.done_on = true ph.on() end
                local c = C[ph.clip]
                local p
                if ph.hold then
                    k, p = ph.hold, math.min(1, tc / ph.dur)
                    if tc >= ph.dur then si, tc = si + 1, 0 end
                else
                    local n, fps = math.abs(ph.f1 - ph.f0), c.fps * (ph.rate or 1)
                    local f = math.min(n, math.floor(tc * fps))
                    k = ph.f0 + (ph.f1 > ph.f0 and f or -f)
                    p = n > 0 and f / n or 1
                    if tc >= (n + 1) / fps then si, tc = si + 1, 0 end
                end
                clip = ph.clip
                if ph.head then headp = ph.head(k, p) end
                if ph.head == false then headp = false end
            end
            if state == "walk" then
                clip = (headless or worn) and "walk_nh" or "walk"
                k = 0
            end
        end
        local c = C[clip]
        k = math.max(0, math.min(c.count - 1, k or 0))
        local mi = dir < 0
        local ox = mi and (spr.w - spr.origin[1]) or spr.origin[1]
        local body = { spr = spr, frame = c.start + k, variant = mi, x = x - ox, y = H - spr.origin[2] }
        local head = nil
        if worn and headp == nil and state == "walk" then headp = h0 end
        if headp and worn then
            head = hooks.relic_layer(worn, x + dir * headp[1], H + headp[2], mi)
        elseif headp then                            -- (the head where it's carried)
            local sg = dir
            head = { spr = spr, frame = C.head.start, variant = mi, x = x - ox + sg * (headp[1] - h0[1]),
                     y = H - spr.origin[2] + (headp[2] - h0[2]) }
        end
        a.sx, a.sy, a.cx, a.facing = body.x, body.y, x, dir
        if down and down.worn then
            return true, { hooks.relic_layer(down.worn, down.x, H - down.worn.lie, down.m), body, head }
        elseif down then                             -- (the head it set down, under it)
            local sg, dm = down.m and -1 or 1, down.m
            local dox = dm and (spr.w - spr.origin[1]) or spr.origin[1]
            return true, { { spr = spr, frame = C.head.start, variant = dm, x = down.x - sg * h0[1] - dox,
                             y = H - spr.origin[2] - 0.34 * u - h0[2] }, body }
        end
        return true, { body, head }
    end
    function a.release() leave_it() end
    return a
end

-- passer: someone just passing through, come over from the screen next door (or, from_far,
-- coming in at the far side, hurrying towards it): walks (clip, rate) across and off, and on to
-- the next screen, if any.
function spawn.passer(el, spr, h)
    local c = spr.clips and spr.clips[h.clip or "walk"]
    if not (c and spr.origin and spr.unit) then return nil end
    local u = spr.unit * H
    local rate = tonumber(h.rate) or 1
    local v = c.stride_px * c.fps / c.count * rate * (el.speed or 1.0)
    local dir = h.dir == 1 and 1 or -1
    local front = 0.5 * u
    local late = clamp(tonumber(h.late) or 0, 0, 1)
    local x = walk_in_x(h, v, front)
    if h.from_far then x = dir > 0 and (-1.2 * u + v * late) or (W + 1.2 * u - v * late) end
    local a = { el = el, spr = spr, layers = 1, groups = { "walker" } }
    a.hops = tonumber(h.hops) or 1
    local tc = 0
    function a.update(dt, t)
        tc = tc + dt
        x = x + dir * v * dt
        walk_out(a, x, dir, front, { kind = "passer", clip = h.clip, rate = rate, unique = false })
        if (dir > 0 and x > W + 1.5 * u) or (dir < 0 and x < -1.5 * u) then return false end
        local k = math.floor(tc * c.fps * rate) % c.count
        local mi = dir < 0
        local ox = mi and (spr.w - spr.origin[1]) or spr.origin[1]
        local layer = { spr = spr, frame = c.start + k, variant = mi, x = x - ox, y = H - spr.origin[2] }
        a.sx, a.sy, a.cx = layer.x, layer.y, x
        return true, { layer }
    end
    return a
end

-- piece: one of the frankenstein's pieces (his head) come flying over from the screen next door:
-- down, a bounce, a while on the ground (still smoking; it has a brain: zombies want it), then
-- into the ground.
function spawn.piece(el, spr, h)
    local C = spr.clips
    local c = C and C[h.clip or ""]
    if not (c and spr.origin and spr.unit) then return nil end
    local u = spr.unit * H
    local a = { el = el, spr = spr, brainy = true, groups = {}, layers = 1 }
    local late = clamp(tonumber(h.late) or 0, 0, 1)
    local dir = h.dir == 1 and 1 or -1
    local vx, vy = (tonumber(h.vx) or 3) * u, (tonumber(h.vy) or 0) * u
    local dy, ground = (tonumber(h.dy) or 0) * u, (tonumber(h.ground) or 2) * u
    local f, spin, bounced = tonumber(h.f) or 0, tonumber(h.spin) or 10, h.bounced == true
    local x = (dir > 0 and 0 or W) + vx * late - dir * room.gap        -- its middle
    vy = vy + 14 * u * late
    dy = dy + vy * late
    local still_t, puff_t, smoke = nil, 0, {}
    local y0 = H - spr.origin[2]
    function a.update(dt, t)
        if not still_t then
            vy = vy + 14 * u * dt
            x, dy = x + vx * dt, dy + vy * dt
            f = f + spin * dt
            if dy >= ground and vy > 0 then
                if not bounced then bounced, vy, vx, spin = true, -vy * 0.35, vx * 0.5, spin * 0.4
                else
                    dy, still_t = ground, t
                    a.fright = { x = x, r = 0.25 * H, till = mp.get_time() + 3 }
                end
            end
            if x < -u * 2 or x > W + u * 2 then return false end
        end
        if still_t and t - still_t > 7 then return false end
        -- still smoking a little
        if still_t and t > puff_t then
            puff_t = t + rnd(0.6, 1.4)
            smoke[#smoke + 1] = { x = x + rnd(-0.1, 0.1) * u, y = y0 + dy + spr.origin[2] - (2.3 - 0.0) * u, r = 0.12 * u, t = 0 }
        end
        local keep = {}
        for _, p in ipairs(smoke) do
            p.t, p.y = p.t + dt, p.y - 0.4 * u * dt
            if p.t < 1.4 then keep[#keep + 1] = p end
        end
        smoke = keep
        local sink = (still_t and t - still_t > 4.5) and (t - still_t - 4.5) * 0.8 * u or 0
        a.cx = still_t and t - still_t < 4.5 and x or nil
        local layer = { spr = spr, frame = c.start + math.floor(f) % c.count, variant = false,
                        x = x - spr.origin[1], y = y0 + dy + sink }
        a.sx, a.sy = layer.x, layer.y
        return true, { layer }
    end
    function a.ass(out)
        for _, p in ipairs(smoke) do puff(out, p.x, p.y, p.r * (1 + p.t), 0.5 + 0.5 * p.t / 1.4) end
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
    local standing = present_decor()
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
        if not d.leaving and not d.away and not d.anim and (d.spr.name or ""):find("tombstone")
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

-- another element sharing a group with el waited for it longer (and still waits)
-- someone here this element may meet (el.meets = [types]: they react to each other), or nil
local function met_here(el)
    if not el.meets then return end
    for _, a in ipairs(actors) do
        if not a.leaving and not a.handed_on and a.el and not a.guest_of then
            for _, t in ipairs(el.meets) do if a.el.type == t then return a end end
        end
    end
end

local function queued_before(el, now)
    for _, a in ipairs(actors) do if a.invites and a.invites[el] then return false end end   -- a guest
    local mine = elements[el] and elements[el].wait_since or now
    local groups = groups_of(el)
    for other, st in pairs(elements) do
        if other ~= el and st.wait_since and st.wait_since < mine and now - (st.wait_seen or 0) < 10
                and element_on(other) then
            for _, g in ipairs(groups_of(other)) do
                for _, want in ipairs(groups) do if g == want then return true end end
            end
        end
    end
    return false
end

-- two characters walking the same way close together, nothing to do with each other (a whole screen
-- of two walking along): after a few seconds one of the cast (a.avoid) does something else
local paths_t = 0
local function tick_paths(now)
    if now < paths_t then return end
    local step = 0.5
    paths_t = now + step
    local walkers = {}
    for _, a in ipairs(actors) do
        if a.cx and not a.gone and not a.leaving and not a.scene and is_character(a) then
            local v = a.last_cx and (a.cx - a.last_cx) / step or 0
            a.last_cx = a.cx
            local m = math.abs(v) > 0.01 * W and (v > 0 and 1 or -1) or nil
            if m then walkers[#walkers + 1] = a end
            a.mdir = m
        end
    end
    for _, p in ipairs(walkers) do
        local near = nil
        for _, q in ipairs(walkers) do
            if q ~= p and q.mdir == p.mdir and math.abs(q.cx - p.cx) < 0.4 * W
                    and p.guest_of ~= q and q.guest_of ~= p then near = q end
        end
        p.same_t, p.same_with = near and (p.same_t or 0) + step or math.min(p.same_t or 0, 0), near
    end
    local k = #walkers > 0 and math.random(#walkers) or 0          -- (which of two goes: by chance)
    for i = 1, #walkers do
        local p = walkers[(k + i - 2) % #walkers + 1]
        local q = p.same_with
        if q and (p.same_t or 0) > 3 and p.avoid and p.avoid(q) then
            p.same_t, q.same_t = -6, -6                             -- (a while before it counts again)
        end
    end
end

-- ── the gag planner (theme.json "planner": {group, queue, gap}) ──
-- One gag at a time on a screen - a character of the planner's group (the witch, the princess, the
-- zombie...) - and a few lined up next, chosen by what's about (frogs few: the witch; a piece of
-- brain lying here: a zombie; a werewolf about: the princess; frogs enough: no witch), how long
-- since each had its turn (el.every: before that it's unlikely), what was on just now (not the
-- same again), what a screen next door has lined up (pln: claims) and a bit of chance. Thought
-- over every few seconds: the line changes as the screen does. Once the screen is free (the last
-- gag gone, a short pause: planner.gap), the first in line is called; the cast it can use
-- (el.recruits) is wanted here - it hangs about, and on the screens next door walks over (want:
-- claims). Gag elements start only when called this way, by the cast (a recruit) or forced
-- (preview keys). The cast passing through doesn't count as a gag.
local function is_gag(el)
    return M and M.planner and has_group(groups_of(el), M.planner.group or "monster") or false
end
local function gag_on()                         -- the gag on here: its actor, or nil
    local g = M.planner.group or "monster"
    for _, a in ipairs(actors) do
        if a.scene or (a.el and not HANDED_ONLY[a.el.type] and not a.gone and has_group(a.groups or {}, g)) then return a end
    end
end
local function about(fam)                       -- one of fam about, here or on another screen
    local _, same = chars_here(fam)
    return same or room.taken["chr:" .. fam]
end
local function gag_use(el)                      -- how much sense it makes now (×), and why
    local t = el.type
    if t == "witch" then
        local n = room_frogs()
        if n < FEW_FROGS then return 2.5, "frogs wanted" end
        if n >= 2 * FEW_FROGS then return 0.25, "frogs enough" end
    elseif t == "frogs" then
        if about("princess") then return 1.6, "the princess about" end
        if room_frogs() >= 2 * FEW_FROGS then return 0.3, "frogs enough" end
    elseif t == "princess" then
        for _, a in ipairs(actors) do if a.asleep_x then return 3, "a wolf asleep" end end
        if cast_here("frog") then return 2, "a frog here" end
        if about("werewolf") or about("vampire") or about("zombie") then return 1.5, "one to meet" end
    elseif t == "zombie" then
        if brains_here() > 0 then return 2.5, "brains lying here" end
    elseif t == "werewolf" then
        if about("princess") then return 1.8, "the princess about" end
    end
    return 1
end
local function gag_score(el, now, queued)
    local st = elements[el]
    if not (st and element_on(el)) or (st.active or 0) > 0 or now < (plan.fail[el] or 0) then return 0 end
    local use, why = gag_use(el)
    local w = (el.gag_weight or 1) * use
    if now < st.next then w = w * 0.15 end                     -- (its turn not come round yet)
    if has_group(groups_of(el), "walker") and no_room_for(el) then w = w * 0.1 end
    if room.taken["pln:" .. el.type] then w = w * 0.3 end      -- (next door has it lined up)
    for i, t in ipairs(plan.recent) do if t == el.type then w = w * (i == 1 and 0.15 or 0.5) end end
    if queued then w = w * 1.4 end                             -- (the line holds, mostly)
    plan.noise[el] = plan.noise[el] or rnd(0.6, 1.4)
    return w * plan.noise[el], why
end
local function replan(now)
    local q, was = {}, {}
    for _, g in ipairs(plan.queue) do was[g.el] = true end
    for _, el in ipairs(M.elements) do
        if is_gag(el) then
            local sc, why = gag_score(el, now, was[el])
            if sc > 0.02 then q[#q + 1] = { el = el, s = sc, why = why } end
        end
    end
    table.sort(q, function(a, b) return a.s > b.s end)
    for i = #q, (M.planner.queue or 3) + 1, -1 do q[i] = nil end
    local sig = {}
    for _, g in ipairs(q) do sig[#sig + 1] = g.el.type .. (g.why and (" (" .. g.why .. ")") or "") end
    sig = table.concat(sig, ", ")
    if sig ~= plan.sig then
        plan.sig = sig
        msg.verbose("plan: next " .. (sig ~= "" and sig or "nothing"))
    end
    plan.queue = q
end
local function gag_started(el, how)
    table.insert(plan.recent, 1, el.type)
    plan.recent[4] = nil
    plan.noise[el], plan.replan_t = nil, 0
    if plan.go == el then plan.go = nil end
    msg.verbose("plan: on now: the " .. el.type .. (how and (" (" .. how .. ")") or ""))
end
local function plan_tick(now)
    if not (M and M.planner) or holding() then return end
    if now >= (plan.replan_t or 0) then
        plan.replan_t = now + 3
        replan(now)
    end
    if plan.go then                              -- called, and it didn't come: not now
        if now - plan.go_t > 1.5 then
            msg.verbose("plan: the " .. plan.go.type .. " can't come now")
            plan.fail[plan.go], plan.go, plan.free_t, plan.replan_t = now + 30, nil, now + 1, 0
        end
        return
    end
    if gag_on() then plan.free_t, plan.pull = nil, nil return end
    if not plan.free_t then
        local lo, hi = range(M.planner.gap, 12)
        plan.free_t = now + rnd(lo, hi)
    end
    if plan.pull then plan.free_t, plan.pull = math.min(plan.free_t, now + 2), nil end
    local g = plan.queue[1]
    if now < plan.free_t or not g then return end
    if has_group(groups_of(g.el), "walker") and no_room_for(g.el) then     -- (the room full: wait)
        if not plan.full then msg.verbose("plan: the " .. g.el.type .. " waits, no room for it now") end
        plan.full = true
        return
    end
    plan.full = nil
    plan.go, plan.go_t = g.el, now
    if elements[g.el] then elements[g.el].next = math.min(elements[g.el].next, now) end
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
    local planned = plan.go == el
    if is_gag(el) and not planned and not st.force and not met_here(el) then  -- (only when the planner calls it -
        local guest = false                                                 -- or a zombie's guest, come to meet)
        for _, a in ipairs(actors) do if a.invites and a.invites[el] then guest = true end end
        if not guest then return end
    end
    if now < st.next then return end
    local max_active = math.floor(scaled(el, el.max_active, 1) + 0.5)
    if st.active >= max_active or #free_ids == 0 then
        st.next = now + 1
        return
    end
    -- a group takes turns: who waited for it first goes first (else the frequent skeletons and
    -- peekers would keep the rare acts out for good)
    local met = met_here(el)
    local character = not HANDED_ONLY[el.type] and has_group(groups_of(el), "walker")
    if not st.force and ((character and no_room_for(el))
            or (not met and not planned and (group_busy(groups_of(el), el) or room_busy(groups_of(el)) or queued_before(el, now)))) then
        st.wait_since, st.wait_seen = st.wait_since or now, now
        st.next = now + rnd(2, 6)
        return
    end
    st.wait_since = nil
    local unique = el.room_unique ~= false and not NOT_UNIQUE[el.type]
    local spr = el.cast and {} or (unique and free_sprite_of(el) or sprite_of(el))   -- visitors pick their own sprite
    if not spr then st.next = now + rnd(5, 15) return end
    if not spawn[el.type] then return end
    local a = spawn[el.type](el, spr)
    if a and unique and a.spr and taken(a.spr) then
        if a.release then a.release() end
        a = nil                         -- another screen in the room shows it now
    end
    if not a or #free_ids < (a.layers or 1) then
        if a then msg.verbose(string.format("no room for %s: %d ids free, %d wanted", tostring(el.type), #free_ids, a.layers or 1)) end
        if a and a.release then a.release() end
        st.next = now + 5
        return
    end
    a.unique, a.born, a.forced = unique, now, st.force
    for _, b in ipairs(actors) do      -- a zombie's guest: one, it came
        if b.invites and b.invites[el] then a.guest_of, b.invites[el] = b, nil end
    end
    if met then                        -- come to meet someone: the two stay on this screen
        a.guest_of = a.guest_of or met
        msg.verbose(tostring(el.type) .. " comes to meet the " .. tostring(met.el.type))
    end
    for _, b in ipairs(a.recruited or {}) do     -- the cast it took over: in the scene now
        b.gone = true
        msg.verbose("cast: the " .. tostring(b.family or "frog") .. " joins the " .. tostring(el.type))
    end
    if is_gag(el) then gag_started(el, not planned and (st.force and "called" or nil)) end
    st.force = nil
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
    if unique then
        local tk = {}
        for k in pairs(room.taken) do if k:sub(1, 4) == "chr:" then tk[#tk + 1] = k:sub(5) end end
        msg.verbose(string.format("start %s %s (room: %d elsewhere: %s%s)", tostring(el.type), tostring(a.spr and a.spr.name),
            room.chars or 0, table.concat(tk, " "), a.guest_of and ", a guest" or ""))
    end
    if a.on_spawn then a.on_spawn() end
    local lo, hi = range(el.every, 30)
    -- higher level → shorter pauses (down to a third at the element's full level)
    local f = 1 - 0.66 * growth(el)
    if el.type == "witch" and room_frogs() < FEW_FROGS then f = f * 0.6 end     -- (frogs wanted)
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
local cat_next = {}  -- element name -> time the next cat may come
local cat_dir        -- (preview key) the next cat walks this way

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
    for _, d in ipairs(present_decor()) do add(d.spr, d.x, d.y + (d.dy or 0), d.mirror) end
    for _, a in ipairs(actors) do
        if a.el.type == "visitor" and a.sx then add(a.spr, a.sx, a.sy, a.mirror) end
        if a.solid then add(a.solid.spr, a.solid.x, a.solid.y, a.solid.variant == true) end
    end
    return list
end

hooks.cats = function() return cats end
hooks.cat_in = function(el, h)          -- a cat come over from next door (see theme-room-in)
    if not prowler or #cats > 0 then return end
    local late = clamp(tonumber(h.late) or 0, 0, 1)
    local u0 = H * 0.0088 * (el.size or 1)
    local speed = clamp(tonumber(h.speed) or 6, 2, 10)
    local c = prowler.new({ W = W, H = H, size = el.size, obstacles = bottom_things, dir = h.dir == 1 and 1 or -1,
        speed = speed, lead = (tonumber(h.lead) or 0) + speed * late - room.gap / u0,
        scare = function(x) return zombie_near(x, 0.46 * H) or fright_near(x) end, threat = werewolf_near })
    c.name, c.hops = el.name or "prowler", tonumber(h.hops) or 1
    cats[#cats + 1] = c
    room.claim_t = 0
    cat_next[c.name] = math.huge
    msg.verbose("room: a cat in from next door")
end
hooks.cat_free = function()             -- no cat here nor anywhere in the room
    return prowler ~= nil and #cats == 0 and not room.taken["spr:cat"]
end
hooks.cat_at = function(x, dir)         -- the black cat (the witch was): there, strolling on
    if not hooks.cat_free() then return false end
    local el
    for _, e in ipairs(M.elements) do if e.type == "prowler" and element_on(e) then el = e end end
    if not el then return false end
    local c = prowler.new({ W = W, H = H, size = el.size, obstacles = bottom_things, dir = dir, at = x,
        scare = function(x) return zombie_near(x, 0.46 * H) or fright_near(x) end, threat = werewolf_near })
    c.name, c.witch = el.name or "prowler", true
    cats[#cats + 1] = c
    room.claim_t = 0
    cat_next[c.name] = math.huge
    return true
end
hooks.call_cat = function(after)        -- (a zombie's guest) the next cat soon
    for name, t in pairs(cat_next) do cat_next[name] = math.min(t, mp.get_time() + after) end
end

local function tick_cats(dt, now)
    if not prowler then return end
    local on = {}
    for _, el in ipairs(M.elements) do
        if el.type == "prowler" and element_on(el) then on[el.name or "prowler"] = el end
    end
    local keep, count = {}, {}
    for _, c in ipairs(cats) do
        -- now and then, strolling by, the cat is the witch (in a puff; none about)
        if not c.asked and c.T > 6 and c.p.x > 0.2 * W and c.p.x < 0.8 * W and not c.air and c.elev < 1 then
            c.asked = true
            local el = on[c.name]
            if math.random() < ((el and el.witch_chance) or (c.witch and 0.5 or 0.25)) and hooks.witch_from
                    and hooks.witch_from(c.p.x, c.dir) then
                c.gone = true
                msg.verbose("cat: in a puff, the cat is the witch")
            end
        end
        local el = on[c.name]
        if el and c.W == W and c.H == H and not c.gone and c:update(dt) then
            keep[#keep + 1] = c
            count[c.name] = (count[c.name] or 0) + 1
        elseif el then
            cat_next[c.name] = now + rnd(range(el.every, 300)) * (1 - 0.66 * growth(el))
        end
    end
    cats = keep
    -- a cat walking off towards a screen next door goes on there (its nose at our edge)
    for _, c in ipairs(cats) do
        if not c.handed_on and c.u then
            local nose = c.p.x + c.dir * prowler.NOSE * c.u
            if (c.dir > 0 and nose > W) or (c.dir < 0 and nose < 0) then
                c.handed_on = true
                local el = on[c.name]
                if el and (c.hops or 0) < MAX_HOPS then
                    hand_over(c.dir > 0 and "right" or "left", { kind = "cat", el = el.index, dir = c.dir, speed = c.speed,
                        lead = (c.dir > 0 and nose - W or -nose) / c.u, hops = (c.hops or 0) + 1 })
                end
            end
        end
    end
    for name, el in pairs(on) do
        cat_next[name] = cat_next[name] or now + rnd(range(el.delay, 10))
        if (count[name] or 0) < 1 and now >= cat_next[name] and not holding() and not room.taken["spr:cat"] then
            local c = prowler.new({ W = W, H = H, size = el.size, obstacles = bottom_things, dir = cat_dir,
                scare = function(x) return zombie_near(x, 0.46 * H) or fright_near(x) end, threat = werewolf_near })
            c.name, cat_dir = name, nil
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
        if a.ass and not a.leaving then a.ass(out, t) end   -- (its own drawing: sparks, smoke)
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

    plan_tick(now)
    tick_paths(now)
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
            if h.kind == "cat" and el and el.type == "prowler" and hooks.cat_in then hooks.cat_in(el, h) end
            local spr = M.sprites[h.sprite or ""]
            local n = tonumber(h.tunnel)
            local on = h.dir == 1 and "right" or "left"
            if n and n > 1 and room[on] then          -- (under the ground: on under this screen)
                h.tunnel, h.went, h.late = n - 1, (tonumber(h.went) or 1) + 1, 0
                hand_over(on, h)
                el = nil
            end
            if el and spr and spawn[h.kind] and (el.type == h.kind or HANDED_ONLY[h.kind]) and #free_ids > 0 then
                local a = spawn[h.kind](el, spr, h)
                if a and #free_ids >= (a.layers or 1) then
                    adopt(a, el, h)
                    msg.verbose("room: in from the " .. (h.dir == 1 and "left" or "right") .. ": " .. tostring(h.kind) .. " " .. tostring(h.sprite))
                elseif a and a.release then a.release() end
            end
        end
    end
    handed_in = wait

    local keep = {}
    for _, a in ipairs(actors) do
        local ok, alive, x, y, frame, mirror = pcall(a.update, dt, t)
        if a.gone then ok, alive = true, false end      -- (taken over by a scene, see recruit)
        if ok and alive and a.ids and type(x) ~= "table" then ok, alive = false, "no layers" end
        if not ok then          -- (one broken actor must not take the whole theme down with it)
            msg.error(string.format("%s dropped: %s", tostring(a.el and a.el.type), tostring(alive)))
            alive = false
        end
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
                    a.sx, a.sy, a.cx = x, y, x + a.spr.w / 2
                end
            end
            keep[#keep + 1] = a
        else
            if a.release then a.release() end
            for _, id in ipairs(a.ids or { a.id }) do give_id(id) end
            if a.handed_on == "yes" then                -- (till the room tells where it is)
                for _, g in ipairs(a.groups or {}) do if ROOM_GROUPS[g] then room.wait[g] = now + 3 end end
                if is_character(a) then room.wait.chr = now + 3 end
            end
            local st = elements[a.el]
            if st and not a.uncounted then st.active = st.active - 1 end
        end
    end
    actors = keep

    -- zombies one at a time (the element, the cast; coming over, up from under the ground): a second
    -- one here, or one here while another screen had one first (a while: one walking over is on
    -- both for a moment), sinks back into the ground
    do
        local first
        for _, a in ipairs(actors) do
            if not a.leaving and not a.gone and not a.kin and a.handed_on ~= "yes" and is_character(a)
                    and actor_family(a) == "zombie" then
                local dup = first or room.taken["chr:zombie"]
                a.dup_t = dup and (a.dup_t or 0) + dt or 0
                if a.dup_t > (first and 0.5 or 10) then
                    leave(a, "grave")
                    msg.verbose("room: one zombie at a time, this one sinks into the ground")
                end
                first = first or a
            end
        end
    end

    -- tell the room what this screen shows (the player passes it on when it changed)
    if room.active then
        room.claim_t = (room.claim_t or 0) - dt
        if room.claim_t <= 0 then
            room.claim_t = 1
            local set, keys = {}, {}
            for _, d in ipairs(standing_decor()) do set[claim_key(d.spr)] = true end
            for _, a in ipairs(actors) do
                if a.unique and a.spr then set[claim_key(a.spr)] = true end
                for _, g in ipairs(a.groups or {}) do if ROOM_GROUPS[g] then set["grp:" .. g] = true end end
                if a.handed_on ~= "yes" then          -- (one walking off to next door: theirs to claim now)
                    if is_character(a) then set["chr:" .. actor_family(a)] = true end
                    for _, f in ipairs(a.also or {}) do set["chr:" .. f] = true end   -- (a duet: the other one)
                end
            end
            if #cats > 0 then set["spr:cat"] = true end
            local next_up = plan.queue[1]              -- (lined up here: next door picks another; its cast walks over)
            if next_up then
                set["pln:" .. next_up.el.type] = true
                for _, f in ipairs(next_up.el.recruits or {}) do set["want:" .. f] = true end
            end
            frogs_here(function(f)
                f.token = f.token or tostring(math.random(1, 1e9))
                set["frog:" .. f.token] = true
            end)
            for g in pairs(ROOM_GROUPS) do
                local on = set["grp:" .. g] or false
                if on ~= (room.here[g] or false) then
                    room.here[g] = on
                    -- (gone over to a screen next door, maybe: the room tells us in a moment)
                    if not on then room.wait[g] = mp.get_time() + 3 end
                    msg.verbose("room: " .. g .. (on and " here" or " gone from here"))
                end
            end
            local chr = {}
            for k in pairs(set) do if k:sub(1, 4) == "chr:" then chr[#chr + 1] = k:sub(5) end end
            table.sort(chr)
            chr = table.concat(chr, " ")
            if chr ~= (room.chr_here or "") then
                room.chr_here = chr
                msg.verbose("room: characters here: " .. (chr ~= "" and chr or "none"))
            end
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
local sub_extra = 0         -- (sub-pos %) half a line more while a character walks about
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
    if lift > 0 or cut > 0 or sub_extra > 0 then pos = math.max(50, pos - sub_extra) end
    if mp.get_property_number("sub-pos", 100) ~= pos then mp.set_property_number("sub-pos", pos) end
end

-- the characters (skeleton, zombie...) stand taller than the decor: while one is on screen the
-- subtitles go half a line higher; back down only between two subtitles (no jumping text)
mp.add_periodic_timer(0.5, function()
    local want = 0
    if M and mode == "video" and level() < DEMO then
        for _, a in ipairs(actors) do
            if not a.leaving and a.handed_on ~= "yes" and a.groups then
                for _, g in ipairs(a.groups) do if g == "walker" then want = 1 end end
            end
        end
    end
    if want > 0 then want = 0.5 * mp.get_property_number("sub-font-size", 55) / 720 * 100 end
    if want == sub_extra then return end
    if want > sub_extra or (mp.get_property("sub-text") or "") == "" then
        sub_extra = want
        update_sub_pos()
    end
end)

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
    room.screens = tonumber(v.screens) or 1
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
    room.chars = tonumber(v.chars) or 0
    room.near = type(v.near) == "table" and v.near or {}
    room.wants = type(v.wants) == "table" and v.wants or {}
    room.ready = v.ready ~= false
    local lost = false
    for _, d in ipairs(standing_decor()) do if room.taken[claim_key(d.spr)] then lost = true end end
    -- an actor that started at the same moment as the same one on another screen: it goes again
    for _, a in ipairs(actors) do
        if a.unique and a.spr and room.taken[claim_key(a.spr)] and not a.leaving and not a.handed then
            leave(a)
            msg.verbose("room: " .. tostring(a.spr.name) .. " is on another screen, leaving")
        end
    end
    -- someone just started here while another screen had one going first (a flyer, a character of
    -- the same kind): it goes again
    local now = mp.get_time()
    for _, a in ipairs(actors) do
        if not a.leaving and not a.handed and not a.forced and not a.guest_of and a.born and now - a.born < 4
                and (room_busy(a.groups or {}) or (is_character(a) and room.taken["chr:" .. actor_family(a)])) then
            leave(a)
            msg.verbose("room: one about on another screen first, " .. tostring(a.spr and a.spr.name) .. " goes again")
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
--   f = web building ×8, w = start a new web, c = send a cat now, d = the vampire next,
--   m = the mummy next (it goes on, the empty sarcophagus a trap: x then), z = the zombie next, k = the frankenstein next, s = a skeleton next,
--   h = the witch (and her cauldron) next, l = the werewolf next (o: he lies down to sleep, the princess called), p = the princess next,
--   S = a zombie and a skeleton meet (a fight: brain and eye), K = the princess meets a frog (a kiss: she's a frog),
--   W = the witch meets the princess (a spell: she's a frog), C = the window creep, V = the vampire meets the
--   princess vampire (a coffin for two), B = the vampire a bat (it hangs a while, comes down: him again),
--   H = the witch comes as a raven, Z = time's up for the cast here (a sarcophagus for one, a cheat), r = the she-wolf (the princess turned: she prowls, naps, spins back), g = the two frogs next, j = a pumpkin-head (off with its head),
--   y = a witch casting a spell on herself (the princess, the cat, a raven in turn),
--   x = a witch and a princess (they turn into each other), u = a skeleton / a zombie that goes
--   under the ground (and comes up on another screen), e = a piece of brain lying here and a
--   zombie (of the cast) after it (one here already: that one, and its next stop drops a piece),
--   q = the princess meeting the werewolf, a zombie, the vampire in turn (she's turned); the witch
--   cooking here: the princess alone, past her pot; a = the wolf (on all fours) and a skeleton in
--   his way (a fight, a bone), i = a bone lying here (a skeleton comes up there soon), n = a zombie and
--   the werewolf man (of the cast; then the werewolf himself, as the man) - it gets him
--   (walkers started so go towards a screen next door, if there is one)
local under_k, morph_k, turn_k
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
    if room.right ~= room.left then cat_dir = room.right and 1 or -1 end
    for name in pairs(cat_next) do cat_next[name] = 0 end
end)
mp.add_forced_key_binding("d", "theme-preview-vampire", function()
    for _, el in ipairs(M and M.elements or {}) do
        if el.type == "vampire" and elements[el] then elements[el].next, elements[el].force = 0, true end
    end
end)
mp.add_forced_key_binding("m", "theme-preview-mummy", function()
    for _, el in ipairs(M and M.elements or {}) do
        if el.type == "mummy" and elements[el] then           -- (it goes on as one of the cast: the trap)
            elements[el].next, elements[el].force, el.mummy_force = 0, true, true
        end
    end
end)
mp.add_forced_key_binding("z", "theme-preview-zombie", function()
    for _, el in ipairs(M and M.elements or {}) do
        if el.type == "zombie" and elements[el] then elements[el].next, elements[el].force = 0, true end
    end
end)
mp.add_forced_key_binding("s", "theme-preview-skeleton", function()
    for _, el in ipairs(M and M.elements or {}) do
        if el.type == "performer" and elements[el] then elements[el].next, elements[el].force = 0, true end
    end
end)
mp.add_forced_key_binding("k", "theme-preview-frankenstein", function()
    for _, el in ipairs(M and M.elements or {}) do
        if el.type == "frankenstein" and elements[el] then
            elements[el].next, elements[el].force, el.explode_here = 0, true, true      -- (blows up here)
        end
    end
end)
mp.add_forced_key_binding("h", "theme-preview-witch", function()
    for _, el in ipairs(M and M.elements or {}) do
        if el.type == "witch" and elements[el] then elements[el].next, elements[el].force = 0, true end
    end
end)
mp.add_forced_key_binding("l", "theme-preview-werewolf", function()
    for _, el in ipairs(M and M.elements or {}) do
        if el.type == "werewolf" and elements[el] then elements[el].next, elements[el].force = 0, true end
    end
end)
mp.add_forced_key_binding("o", "theme-preview-werewolf-sleeps", function()
    for _, el in ipairs(M and M.elements or {}) do
        if el.type == "werewolf" and elements[el] then elements[el].next, elements[el].force, el.sleep_force = 0, true, true end
    end
end)
mp.add_forced_key_binding("p", "theme-preview-princess", function()
    for _, el in ipairs(M and M.elements or {}) do
        if el.type == "princess" and elements[el] then elements[el].next, elements[el].force = 0, true end
    end
end)
mp.add_forced_key_binding("S", "theme-preview-zombie-skeleton", function()   -- (they meet: a fight)
    local ce, zs, ss = cast_el(), cast_sprite("zombie"), cast_sprite("skeleton")
    if not (ce and zs and ss) then return end
    local z = spawn.wanderer(ce, zs, { fam = "zombie", dir = 1, at = 0.25 * W, hops = 0, ttl = 60, age = 1, down_at = -1e9 })
    local k = spawn.wanderer(ce, ss, { fam = "skeleton", dir = -1, at = 0.75 * W, hops = 0, ttl = 60 })
    if z and k then
        z.fight_sure, z.busy, k.busy = true, true, true      -- (no scene takes them over first)
        adopt(z, ce, { hops = 0 }) adopt(k, ce, { hops = 0 })
    end
end)
mp.add_forced_key_binding("Z", "theme-preview-time-up", function()   -- (the cast here: time's up)
    for _, a in ipairs(actors) do
        if a.family and a.ttl then a.ttl, a.pickup_sure = 0, true msg.verbose("preview: time's up for the " .. a.family) end
    end
end)
mp.add_forced_key_binding("r", "theme-preview-shewolf", function()
    local ps = M and M.sprites.princess3d
    for _, el in ipairs(M and M.elements or {}) do
        if el.type == "werewolf" and ps and #free_ids > 1 then
            local a = spawn.werewolf(el, ps, { she = true, upright = true, dir = 1, at = 0.3 * W, hops = 0 })
            if a then adopt(a, el, { hops = 0 }) end
            return
        end
    end
end)
mp.add_forced_key_binding("g", "theme-preview-frogs", function()
    for _, el in ipairs(M and M.elements or {}) do
        if el.type == "frogs" and elements[el] then elements[el].next, elements[el].force = 0, true end
    end
end)
mp.add_forced_key_binding("j", "theme-preview-pumpkinhead", function()
    local spr = M and M.sprites.pumpkinhead3d
    for _, el in ipairs(M and M.elements or {}) do
        if el.type == "witch" and spr and spawn.pumpkinhead then
            local lying = false                  -- (one lying here: a headless one comes for it)
            for _, b in ipairs(actors) do if b.lying and not b.taken then lying = true end end
            local a = spawn.pumpkinhead(el, spr, { dir = 1, at = 0.1 * W, ttl = 120, hops = 0, headless = lying or nil,
                                                    doff_at = not lying and 0.5 * W or nil })
            if a then adopt(a, el, { hops = 0 }) end
            return
        end
    end
end)
mp.add_forced_key_binding("x", "theme-preview-swap", function()
    local ws, ps = M and M.sprites.witch3d, M and M.sprites.princess3d
    for _, el in ipairs(M and M.elements or {}) do
        if el.type == "witch" and ws and ps then
            local a = spawn.wanderer(el, ws, { fam = "witch", dir = 1, at = 0.3 * W, ttl = 120, hops = 0 })
            local b = spawn.wanderer(el, ps, { fam = "princess", dir = -1, at = 0.7 * W, ttl = 120, hops = 0 })
            if not (a and b) then return end
            adopt(a, el, { hops = 0 }) adopt(b, el, { hops = 0 })
            a.next_at, b.next_at = 2, 1e9
            return
        end
    end
end)
local MORPH_KEYS = { "princess", "cat", "raven" }
mp.add_forced_key_binding("y", "theme-preview-morph", function()
    local el = witch_el()
    local ws = el and M.sprites[el.sprite or ""]
    if not ws then return end
    morph_k = (morph_k or 0) % #MORPH_KEYS + 1
    local a = spawn.wanderer(el, ws, { fam = "witch", dir = 1, at = 0.25 * W, ttl = 120, hops = 0 })
    if not a then return end
    adopt(a, el, { hops = 0 })
    a.next_at, a.force_morph = 2.5, MORPH_KEYS[morph_k]
end)
mp.add_forced_key_binding("u", "theme-preview-under", function()
    under_k = (under_k or 0) + 1
    local name = (under_k % 2 == 1) and "skeleton" or "zombie"
    local spr = M and M.sprites[name .. "3d"]
    for _, el in ipairs(M and M.elements or {}) do
        if el.type == "frogs" and spr then
            local a = spawn.wanderer(el, spr, { fam = name, dir = 1, at = 0.1 * W, ttl = 120, hops = 0, down_at = 0.45 * W })
            if a then adopt(a, el, { hops = 0 }) a.next_at = 1e9 end
            return
        end
    end
end)
mp.add_forced_key_binding("e", "theme-preview-brain", function()
    local B, zel = brain_sprite()
    local spr = M and M.sprites.zombie3d
    if not (B and spr) then return end
    local z = { gone = false }
    local b = new_brain(zel, B, 0.6 * W, H - 2 * spr.unit * H, 0.5 * spr.unit * H, z, spr.unit * H)
    b.drop_t = 0
    for _, a in ipairs(actors) do
        if actor_family(a) == "zombie" and is_character(a) then zel.brain_force = true return end
    end
    for _, el in ipairs(M.elements) do
        if el.type == "frogs" then
            local a = spawn.wanderer(el, spr, { fam = "zombie", dir = 1, at = 0.1 * W, ttl = 120, hops = 0 })
            if a then adopt(a, el, { hops = 0 }) a.next_at = 1e9 end
        end
    end
end)
mp.add_forced_key_binding("q", "theme-preview-turned", function()
    turn_k = (turn_k or 0) + 1
    local who = ({ { "werewolf_man3d", "werewolf" }, { "zombie3d", "zombie" }, { "vampire3d", "vampire" } })[(turn_k - 1) % 3 + 1]
    local pr, mo = M and M.sprites.princess3d, M and M.sprites[who[1]]
    for _, el in ipairs(M and M.elements or {}) do
        if el.type == "frogs" and pr and mo then
            local a = spawn.wanderer(el, pr, { fam = "princess", dir = 1, at = 0.15 * W, ttl = 120, hops = 0 })
            if a then adopt(a, el, { hops = 0 }) a.next_at, a.turn_sure = 1e9, true end
            for _, w in ipairs(actors) do if w.el.type == "witch" and w.scene then return end end   -- (by her pot, alone)
            local b = spawn.wanderer(el, mo, { fam = who[2], dir = -1, at = 0.85 * W, ttl = 120, hops = 0 })
            if b then adopt(b, el, { hops = 0 }) b.next_at = 1e9 end
            return
        end
    end
end)
local function preview_werewolf(h)
    for _, el in ipairs(M and M.elements or {}) do
        local spr = el.type == "werewolf" and M.sprites[el.sprite or ""]
        if spr then
            local a = spawn.werewolf(el, spr, h)
            if a then adopt(a, el, { hops = 0 }) end
            return a
        end
    end
end
local function preview_cast(sp, h)
    local ce = M and cast_el()
    local a = ce and sp and spawn.wanderer(ce, sp, h)
    if a then adopt(a, ce, { hops = 0 }) a.next_at = 1e9 end
    return a
end
mp.add_forced_key_binding("a", "theme-preview-wolf-fight", function()
    local sk = M and cast_sprite("skeleton")
    preview_werewolf({ form = "wolf", dir = 1, at = 0.05 * W, hops = 0, cross = true })
    preview_cast(sk, { fam = "skeleton", dir = -1, at = 0.9 * W, ttl = 120, hops = 0 })
end)
mp.add_forced_key_binding("i", "theme-preview-bone", function()
    for _, el in ipairs(M and M.elements or {}) do
        local B = el.type == "werewolf" and M.sprites[el.bone or ""]
        if B and B.clips and B.clips.lie then
            local old = el.bone_rise
            el.bone_rise = { 6, 10 }
            new_bone(el, hooks.bone_relic(B), 0.5 * W, H - B.h, false).force = true
            el.bone_rise = old
            return
        end
    end
end)
local zman_k
mp.add_forced_key_binding("n", "theme-preview-zombie-man", function()
    zman_k = (zman_k or 0) + 1
    local zs = M and cast_sprite("zombie")
    local z = preview_cast(zs, { fam = "zombie", dir = -1, at = 0.75 * W, ttl = 120, hops = 0 })
    if z then z.busy = true end
    if zman_k % 2 == 1 then
        local wm = preview_cast(M.sprites.werewolf_man3d, { fam = "werewolf", dir = 1, at = 0.15 * W, ttl = 120, hops = 0 })
        if wm then wm.meet_sure, wm.busy = true, true end
    else
        preview_werewolf({ form = "man", dir = 1, at = 0.05 * W, hops = 0 })
    end
end)
mp.add_forced_key_binding("K", "theme-preview-frog-kiss", function()     -- (the princess meets a frog)
    local ce, fr = M and cast_el(), M and frog_sprite()
    local f = ce and fr and spawn.hopper(ce, fr, { dir = -1, at = 0.4 * W, hops = 0, ttl = 120 })
    if f then adopt(f, ce, { hops = 0 }) end
    local p = preview_cast(M and M.sprites.princess3d, { fam = "princess", dir = 1, at = 0.15 * W, ttl = 120, hops = 0 })
    if p then p.meet_sure, p.busy, p.staged = true, true, true end
end)
mp.add_forced_key_binding("W", "theme-preview-witch-frog", function()    -- (the witch meets the princess)
    local wel = M and witch_el()
    local p = preview_cast(M and M.sprites.princess3d, { fam = "princess", dir = -1, at = 0.8 * W, ttl = 120, hops = 0 })
    local w = wel and preview_cast(M.sprites[wel.sprite or ""], { fam = "witch", dir = 1, at = 0.15 * W, ttl = 120, hops = 0 })
    if p then p.busy, p.staged = true, true end
    if w then w.meet_sure, w.busy, w.staged = true, true, true end
end)
mp.add_forced_key_binding("C", "theme-preview-creep", function()        -- (the window creep, now)
    for _, el in ipairs(M and M.elements or {}) do
        if el.type == "crawler" and el.sprite == "creep" and elements[el] then elements[el].next, elements[el].force = 0, true end
    end
end)
mp.add_forced_key_binding("V", "theme-preview-coffin-two", function()  -- (the vampire meets the princess vampire)
    local pv = preview_cast(M and turned_sprite("vampire"), { fam = "princess_vampire", dir = -1, at = 0.7 * W, ttl = 120, hops = 0 })
    local v = preview_cast(M and cast_sprite("vampire"), { fam = "vampire", dir = 1, at = 0.2 * W, ttl = 120, hops = 0 })
    if pv then pv.busy, pv.staged = true, true end
    if v then v.meet_sure, v.busy, v.staged = true, true, true end
end)
mp.add_forced_key_binding("B", "theme-preview-bat", function()          -- (the vampire: a bat, and back)
    local v = preview_cast(M and cast_sprite("vampire"), { fam = "vampire", dir = 1, at = 0.3 * W, ttl = 120, hops = 0 })
    if v then v.next_at, v.force_morph = 1.5, "bat" end
end)
mp.add_forced_key_binding("H", "theme-preview-witch-raven", function()  -- (the witch comes as a raven)
    for _, el in ipairs(M and M.elements or {}) do
        if el.type == "witch" and elements[el] then elements[el].next, elements[el].force, el.raven_force = 0, true, true end
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
