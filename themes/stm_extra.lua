-- St Maarten (11-11), the side cast: houses on the doorbell round, the cow, geese, a bonfire, teenagers
-- without lanterns, the island of Sint Maarten (Columbus, the Frenchman and the Dutchman, St Martin
-- cutting it in two like his cloak), the border walk round the island, and the 11:11 carnival parade.
-- Loaded by engine.lua after stmaarten.lua (hooks.stm_x); it gets the same API (stmaarten.lua's S.api)
-- plus E2: ids_low_first (houses and the bonfire drawn behind the walkers), hand_over.
--
--   stm_house (houses, a few per screen, standing a while): a meeting for stmaarten.lua's children
--     (S.meet "house"): they ring the bell and sing at the door; the door opens, the resident holds out
--     a bowl and each singer gets a sweet. A grumpy house (el.grumpy): the light goes off as they ring,
--     the door stays shut; a curtain twitches when they've sung.
--   stm_bonfire: Sint-Maartensvuur; children walking by gather and sing at it (S.meet "bonfire").
--   stm_cow: a cow wandering across, stopping to swish its tail and moo; children sing at it ("de koeien
--     hebben staarten", S.meet "cow"): it moos back.
--   stm_geese: a few geese waddle in and stay a while, honking now and then. St Martin passing by
--     (or called over) creeps in among them to hide - and they honk at him all at once: found.
--   stm_teens: two teenagers without lanterns, a big carrier bag, at a door: they get a turnip, or the
--     door stays shut (the light goes off); they shrug and slouch off.
--   stm_border: the island border walk (1648): a Frenchman and a Dutchman start back to back and walk
--     round the island in opposite directions (round the room's screens, or off one side and in at the
--     other). The Dutchman drinks his jenever, slows down, sits down and dozes off - St Martin may come
--     by and lay a piece of his cloak over him, so he sleeps on; the Frenchman comes round from the
--     other side, plants the French flag right by him (the bigger half), the Dutchman wakes, shrugs and
--     plants his flag on his other side.
--   stm_island: the island story: a small island; Columbus's caravel bumps into it (a coconut drops),
--     Columbus hops ashore and plants his flag (St Martin's day, 1493); the Frenchman and the Dutchman pop
--     up on either side, Columbus sails off sheepishly, the two squabble - St Martin walks up, cuts the
--     island in two like his cloak and hands each one half (without him: a plain sword slice).
--   stm_parade: at 11:11 (the carnival season opens) a prince carnaval, a jester and two trumpet
--     players cross the room once, confetti flying.
-- Preview keys: F9 a house (and children), Shift+F9 a grumpy house, F10 the cow, F11 geese (and
-- St Martin), F12 the island story, Shift+F10 the border walk, Shift+F11 the parade, Shift+F12
-- teenagers, Ctrl+F9 a bonfire, Ctrl+F10 the geese flying over.
-- Backdrops (a.backdrop = depth, engine restack): the Dom (stm_scenery), houses and the bonfire are
-- drawn behind every walker; stmaarten.lua's church and school too.

local X = {}
local E, S, E2                  -- the engine API, stmaarten.lua, the extras
local parade_day = nil          -- the date the parade came by here
-- test hook: KIOSK_FAKE_CLOCK=HH:MM[:SS] makes the theme's clock start at that time (the 11:11 parade)
local clock_off = 0
do
    local h, m, sec = (os.getenv("KIOSK_FAKE_CLOCK") or ""):match("^(%d+):(%d+):?(%d*)$")
    if h then
        local t = os.date("*t")
        t.hour, t.min, t.sec = tonumber(h), tonumber(m), tonumber(sec) or 0
        clock_off = os.time(t) - os.time()
    end
end
local function clock(fmt) return os.date(fmt, os.time() + clock_off) end

local function rnd(a, b) return a + math.random() * (b - a) end
local function range(v, d1, d2)
    if type(v) == "table" then return v[1], v[2] or v[1] end
    if v == nil then return d1, d2 or d1 end
    return v, v
end
local function now() return mp.get_time() end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function ease(p) p = clamp(p, 0, 1) return p * p * (3 - 2 * p) end
local function sprite(name) local M = E.M() return M and name and M.sprites[name] or nil end
local function unit(spr) return (spr and spr.unit or 0.1) * E.H() end

-- ── clips, layers, steps ─────────────────────────────────────────────────────

local function clip_frame(spr, name, tc, reverse, rate)
    local C = spr.clips or {}
    local c = C[name] or C.idle or C.walk
    if not c then
        local n = math.max(spr.frames or 1, 1)
        return math.floor(tc * math.max(spr.fps or 8, 1)) % n, false, 0, nil
    end
    local k = math.floor(tc * c.fps * (rate or 1))
    local done = (not c.loop) and k >= c.count
    if c.loop then k = k % c.count else k = math.min(k, c.count - 1) end
    if reverse then k = c.count - 1 - k end
    return c.start + k, done, k, c
end
local function clip_len(spr, name)
    local c = spr.clips and spr.clips[name]
    return c and c.count / c.fps or 0
end
local function walk_v(spr)
    local c = spr.clips and spr.clips.walk
    if not c or c.count == 0 or (c.stride_px or 0) <= 0 then return 0.05 * E.H() end
    return math.max(1, c.stride_px * c.fps / c.count)
end
-- a layer: the sprite's baked origin (or its bottom middle) at screen cx, ground
local function layer(spr, frame, mirror, cx, ground, dx, dy, crop)
    local o = spr.origin or { spr.w / 2, spr.h }
    local x = mirror and (cx - (spr.w - o[1])) or (cx - o[1])
    return { spr = spr, frame = frame, variant = mirror and true or false, x = x + (dx or 0),
             y = ground - o[2] + (dy or 0), crop = crop }
end

-- one character's steps: {clip, dur | walk_to | wait (fn) | till the clip ends (a loop: 2 s),
-- face, reverse, rate, v, on_start, on_end}; p = {spr, x, dir, v, steps, tc}
local function run_steps(p, dt)
    local s = p.steps[1]
    if not s then return nil end
    if not s.started then
        s.started, p.tc = true, 0
        if s.face then p.dir = s.face end
        if s.on_start then s.on_start() end
        s = p.steps[1]
        if not s then return nil end
        s.started = true
    end
    p.tc = p.tc + dt
    local done = false
    if s.walk_to then
        local d = s.walk_to - p.x
        local dir = d >= 0 and 1 or -1
        p.dir = dir
        local mv = (s.v or p.v) * dt
        if math.abs(d) <= mv then p.x, done = s.walk_to, true else p.x = p.x + dir * mv end
    end
    local frame, cdone, _, c = clip_frame(p.spr, s.clip, p.tc, s.reverse, s.rate)
    if s.dur then done = done or p.tc >= s.dur
    elseif s.wait then done = s.wait()
    elseif not s.walk_to then done = cdone or (c and c.loop and p.tc >= 2) or (not c and p.tc >= 1) end
    p.clip = s.clip
    if done then
        table.remove(p.steps, 1)
        if s.on_end then s.on_end() end
    end
    return frame
end

local function others(stm)
    local list = {}
    for _, b in ipairs(E.actors()) do
        if b.stm == stm and not b.dead and not b.leaving then list[#list + 1] = b end
    end
    return list
end

-- one more actor (not counted by the element); back: on a low overlay id, drawn behind the walkers
local function add(a, el, back)
    if back then a.backdrop = a.backdrop or 3 end         -- (engine restack: under everyone, always)
    if back then E2.ids_low_first(true) end
    local ok = E.add(a, el)
    if back then E2.ids_low_first(false) end
    return ok
end

local function later(a, dt, fn) a.timers = a.timers or {}; a.timers[#a.timers + 1] = { t = now() + dt, fn = fn } end
local function tick_timers(a)
    if not a.timers then return end
    local n = now()
    for i = #a.timers, 1, -1 do
        local tm = a.timers[i]
        if n >= tm.t then table.remove(a.timers, i); tm.fn() end
    end
end

-- a little thing flying from (x0, y0) to (x1, y1) in an arc (its middle); done() at the end
local function fly(spr, x0, y0, x1, y1, dur, done, lift)
    if not spr or E.free_ids() < 1 then if done then done() end return end
    local a = { el = { type = "stm_fly", hz = 30, video_min = 0 }, spr = spr }
    local t = 0
    function a.update(dt)
        t = t + dt
        local p = math.min(1, t / dur)
        local x = x0 + (x1 - x0) * p
        local y = y0 + (y1 - y0) * p - math.sin(math.pi * p) * (lift or 0.08) * E.H()
        if p >= 1 then
            if done then done() end
            return false
        end
        return true, x - spr.w / 2, y - spr.h / 2, 0, false
    end
    E.add(a)
end

local function el_of(t)
    for _, el in ipairs(E.M() and E.M().elements or {}) do if el.type == t then return el end end
end
local function force(t)
    local el = el_of(t)
    local st = el and E.elements()[el]
    if st then st.next, st.force = 0, true end
    return el
end

-- ── St Martin (stmaarten.lua's martin), borrowed for a gag ──────────────────

local function free_martin(max_stage)
    for _, b in ipairs(others("martin")) do
        if not b.cold and not b.steps[1] and not b.listening and (b.stage or 0) <= (max_stage or 3) then return b end
    end
end
local function call_martin()          -- none about in the room: one comes this way
    local room = E.room()
    if room.taken["chr:martin"] or #others("martin") > 0 then return false end
    return force("martin") ~= nil
end
local function martin_stage(b, s)       -- (set together: his stage, his sprite)
    local names = b.el and b.el.stages or {}
    local sp = sprite(names[s + 1])
    b.stage = s
    if sp then b.spr = sp end
end
-- his cut: a piece off, the stage on; the last piece (stage 3): he sits down in the cold after
local function martin_cut_steps(b, side, give_start, after)
    local s0 = b.stage or 0
    local k, cut_clip = nil, "cut"
    if b.cut_pick then k, cut_clip = b.cut_pick() end     -- (H or V: his own path of cuts)
    local steps = {
        { clip = "turn_front", face = side },
        { clip = "idle", dur = 0.5 },
        { clip = cut_clip, on_end = function()
            if b.set_stage then b.set_stage(math.min(3, s0 + 1), k) else martin_stage(b, math.min(3, s0 + 1)) end
        end },
        { clip = "give", on_start = give_start },
        { clip = "idle", dur = 1.0 },
        { clip = "turn_side", face = b.dir0 or b.dir, on_end = function()
            if after then after() end
            if (b.stage or 0) >= 3 and b.sit_down_cold then b.sit_down_cold() end
        end },
    }
    return steps
end

-- ── houses ──────────────────────────────────────────────────────────────────

function X.house(el, spr, grumpy, at)
    local W, H = E.W(), E.H()
    if not (spr and spr.clips and spr.clips.open) then return nil end
    local u = unit(spr)
    local x = at
    if not x then                                     -- (clear of the Dom and its flag, and of a church or school)
        for _ = 1, 8 do
            local cx = E.free_x(0.22 * W, 0.86 * W)
            local clear = true
            for _, b in ipairs(E.actors()) do
                if (b.stm == "church" or b.stm == "school") and not b.dead and math.abs(b.x - cx) < 0.2 * W then clear = false end
                if b.stm == "beggar" and b.sitting and math.abs(b.x - cx) < 0.08 * W then clear = false end   -- (the door: free)
            end
            if clear then x = cx break end
        end
        if not x then return nil end
    end
    if S and S.clear_door then S.clear_door(x, 0.07 * W) end     -- (one sitting there anyway: he shuffles aside)
    local a = { el = el, spr = spr, stm = "house", x = x, cx = x, dir = 1, clip = "idle", tc = 0, rise = 0,
                grumpy = grumpy, ttl = rnd(range(el.stay, 150, 300)), t0 = now(), unique = false }
    local function play(name, reverse, after) a.clip, a.rev, a.tc, a.after = name, reverse, 0, after end
    a.play = play
    a.door_y = H - 1.05 * u                           -- (the bowl held out)
    function a.can_hear() return a.rise >= 1 and not a.busy and not a.going and not a.dark end
    function a.listen(g)                              -- they ring the bell
        a.busy, a.busy_t = g, now()
        play("ring", false, function()
            if a.grumpy then play("dark", false, function() a.dark = true; play("dark_idle") end)
            else play("idle") end
        end)
    end
    function a.react(g)                               -- they've sung
        if a.grumpy then
            play("peek", false, function() play("dark_idle"); a.busy, a.act_done = nil, true; g.resume() end)
            return
        end
        play("open", false, function()
            play("offer")
            local sw = sprite(el.sweet or "sweet")
            local d = 0
            for _, k in ipairs(g.singers()) do
                d = d + 0.35
                local kk = k
                later(a, d, function()
                    fly(sw, a.x, a.door_y, kk.x, H - 0.9 * unit(kk.spr), 0.8, function() if kk.cheer then kk.cheer() end end)
                end)
            end
            later(a, d + 2.4, function()
                play("open", true, function() play("idle"); a.busy, a.act_done = nil, true; g.resume() end)
            end)
        end)
    end
    a.leave = function() a.going = true end
    function a.update(dt, t)
        tick_timers(a)
        if a.busy and now() - (a.busy_t or 0) > 60 then a.busy = nil end     -- (they never came back)
        if a.going then
            a.rise = a.rise - dt / 1.5
            if a.rise <= 0 then a.dead = true return false end
        elseif a.rise < 1 then
            a.rise = math.min(1, a.rise + dt / 1.5)
        elseif (not a.busy and now() - a.t0 > a.ttl) or (S and S.bld_due and S.bld_due(a, not a.busy)) then
            a.going = true
        end
        a.tc = a.tc + dt
        local frame, done = clip_frame(spr, a.clip, a.tc, a.rev)
        if done and a.after then
            local f = a.after
            a.after = nil
            f()
            frame = clip_frame(spr, a.clip, a.tc, a.rev)
        end
        local l = layer(spr, frame, false, a.x, H, 0, (1 - ease(a.rise)) * spr.h)
        a.sx, a.sy = l.x, l.y
        return true, l.x, l.y, l.frame, l.variant
    end
    return a
end

-- (a scheduler: try_spawn asks every few seconds; the houses are added behind the walkers)
local function scheduled(el, n, maxn)
    local st = E.elements()[el]
    local forced = st and st.force
    if st then st.force = nil end
    if not forced then
        if n >= maxn then return false end
        if not el._next then el._next = now() + rnd(range(el.delay, 5, 30)) return false end
        if now() < el._next then return false end
    end
    el._next = now() + rnd(range(el.every, 60, 120))
    return true
end

function X.spawn_house(el, spr)
    local _, hi = range(el.count, 1, 2)
    if #others("island") > 0 or #others("border") > 0 then return nil end     -- (they need the floor)
    if not scheduled(el, #others("house"), hi) then return nil end
    local grumpy = X.want_grumpy
    if grumpy == nil then grumpy = math.random() < (el.grumpy or 0.25) end
    X.want_grumpy = nil
    local a = X.house(el, E.free_sprite(el) or spr, grumpy)
    if a then add(a, el, true) end
    return nil
end

-- ── the bonfire ─────────────────────────────────────────────────────────────

function X.spawn_bonfire(el, spr)
    if not scheduled(el, #others("bonfire"), 1) then return nil end
    local W, H = E.W(), E.H()
    local x = E.free_x(0.25 * W, 0.75 * W)
    local a = { el = el, spr = spr, stm = "bonfire", x = x, cx = x, rise = 0, t0 = now(),
                ttl = rnd(range(el.stay, 150, 300)) }
    function a.can_hear() return a.rise >= 1 and not a.busy and not a.going end
    function a.listen(g) a.busy, a.busy_t = g, now() end
    function a.react(g) later(a, 1.5, function() a.busy, a.act_done = nil, true; g.resume() end) end   -- (sung at: act done)
    a.leave = function() a.going = true end
    function a.update(dt, t)
        tick_timers(a)
        if a.busy and now() - (a.busy_t or 0) > 60 then a.busy = nil end
        if a.going then
            a.rise = a.rise - dt / 2
            if a.rise <= 0 then a.dead = true return false end
        elseif a.rise < 1 then a.rise = math.min(1, a.rise + dt / 2)
        elseif (not a.busy and now() - a.t0 > a.ttl) or (S and S.bld_due and S.bld_due(a, not a.busy)) then a.going = true end
        local frame = clip_frame(spr, "burn", t)
        local l = layer(spr, frame, false, a.x, E.H(), 0, (1 - ease(a.rise)) * spr.h * 0.8)
        return true, l.x, l.y, l.frame, l.variant
    end
    add(a, el, true)
    return nil
end

-- ── a clock's hands at the real (local) time: two actors just over the building (parent.backdrop +
-- 0.3 / 0.4), the minute hand to the minute, the hour hand in quarter hours; parent.clock_at = {cx,
-- ground} (set as it draws). Sprite: clips min (60) and hour (48), the building's origin.
function X.clock_hands(parent, sname)
    local spr = sprite(sname)
    if not (spr and spr.clips and spr.clips.min and spr.clips.hour) then return end
    for i, which in ipairs({ "hour", "min" }) do
        local a = { el = parent.el, spr = spr, stm = "clock_hand", backdrop = (parent.backdrop or 3) + 0.2 + 0.1 * i,
                    unique = false }
        a.leave = function() a.dead = true end
        function a.update()
            if a.dead or parent.dead then return false end
            local at = parent.clock_at
            if not at then return true, -10 * spr.w, 0, spr.clips[which].start, false end
            local t = os.date("*t", os.time() + clock_off)
            local k = which == "min" and t.min or ((t.hour % 12) * 4 + math.floor(t.min / 15))
            local l = layer(spr, spr.clips[which].start + k, false, at[1], at[2])
            return true, l.x, l.y, l.frame, l.variant
        end
        add(a, parent.el, true)
    end
end

-- ── scenery: the Dom and its flag, standing for good, behind everyone (el.depth) ──

function X.scenery(el, spr)
    if #others("scenery_" .. (el.sprite or "")) > 0 then return nil end
    local W, H = E.W(), E.H()
    local p = el.place or { 0, 0 }
    local a = { el = el, spr = spr, stm = "scenery_" .. (el.sprite or ""), rise = 0, backdrop = el.depth or 1 }
    a.leave = function() a.going = true end
    function a.update(dt, t)
        if a.going then
            a.rise = a.rise - dt / 2
            if a.rise <= 0 then a.dead = true return false end
        elseif a.rise < 1 then a.rise = math.min(1, a.rise + dt / 2) end
        local frame = spr.clips and clip_frame(spr, next(spr.clips), t) or 0
        local x = p[1] * W
        local y = H - spr.h - p[2] * H + (1 - ease(a.rise)) * (spr.h + p[2] * H)
        a.clock_at = { x, y + spr.h }
        return true, x, y, frame, el.mirror and true or false
    end
    add(a, el, true)
    if el.hands then X.clock_hands(a, el.hands) end
    return nil
end

-- ── the cow ─────────────────────────────────────────────────────────────────

function X.cow(el, spr, h)
    local W, H = E.W(), E.H()
    if not (spr and spr.clips and spr.clips.walk) then return nil end
    local a = { el = el, spr = spr, stm = "cow", steps = {}, tc = 0 }
    a.v = walk_v(spr) * (el.speed or 1)
    local front = spr.w * 0.5
    if h then
        a.dir = h.dir == 1 and 1 or -1
        a.x = E.walk_in_x(h, a.v, front)
        a.hops = tonumber(h.hops) or 0
    else
        a.dir = math.random() < 0.5 and 1 or -1
        a.x = a.dir > 0 and -front or W + front
        a.hops = 0
    end
    a.walk_dir = a.dir
    if not h or math.random() < 0.5 then
        a.steps = { { clip = "walk", walk_to = E.free_x(0.3 * W, 0.7 * W) }, { clip = "idle", dur = rnd(1.5, 3) } }
        local acts = { "swish", "idle", "moo", "swish", "idle" }
        for _ = 1, math.random(2, 4) do a.steps[#a.steps + 1] = { clip = acts[math.random(#acts)], dur = nil } end
        a.steps[#a.steps + 1] = { clip = "idle", dur = rnd(1, 3) }
    end
    function a.can_hear()
        local s = a.steps[1]
        return s and s.clip ~= "walk" and not a.listening
    end
    function a.listen(g)
        a.listening = g
        local side = g.x0 > a.x and 1 or -1
        a.steps = { { clip = "idle", face = side, wait = function() return not a.listening or a.listening.mode ~= "sing" end } }
    end
    function a.react(g)
        a.steps = { { clip = "swish" }, { clip = "moo" },
                    { clip = "idle", dur = 1.2, on_end = function() a.listening = nil; g.resume() end },
                    { clip = "swish", face = a.walk_dir } }
    end
    function a.update(dt, t)
        local frame = run_steps(a, dt)
        if not frame then
            a.listening = nil
            a.dir = a.walk_dir
            a.x = a.x + a.dir * a.v * dt
            E.walk_out(a, a.x, a.dir, front, {})
            if a.x < -front * 2 or a.x > W + front * 2 then return false end
            frame = clip_frame(spr, "walk", t)
        end
        a.cx = a.x
        local l = layer(spr, frame, a.dir < 0, a.x, H)
        return true, l.x, l.y, l.frame, l.variant
    end
    return a
end

-- ── geese ───────────────────────────────────────────────────────────────────

function X.geese(el, spr, h)
    local W, H = E.W(), E.H()
    if not (spr and spr.clips and spr.clips.walk) then return nil end
    local u = unit(spr)
    local lo, hi = range(el.n, 3, 5)
    local n = math.random(lo, hi)
    local a = { el = el, spr = spr, stm = "geese", layers = n, t0 = now() }
    local dir = math.random() < 0.5 and 1 or -1
    local v = walk_v(spr) * 0.8
    local cx = E.free_x(0.35 * W, 0.65 * W)
    local G = {}
    for i = 1, n do
        local off = (i - (n + 1) / 2) * 1.1 * u + rnd(-0.2, 0.2) * u
        G[i] = { off = off, x = (dir > 0 and -2 * u or W + 2 * u) + off - dir * (i - 1) * 0.5 * u, dir = dir,
                 clip = "walk", tc = rnd(0, 1), dy = (i % 2) * 0.12 * u, next_honk = now() + rnd(4, 12) }
    end
    local state = "in"
    local stay = rnd(range(el.stay, 25, 45))
    local stood
    local hunt_until = nil         -- (calling St Martin over: till then)
    local caught                   -- the St Martin they found
    local function honk_all(at_x)
        for _, g in ipairs(G) do
            g.dir = at_x > g.x and 1 or -1
            g.clip, g.tc, g.hold = "honk", rnd(0, 0.2), 0
        end
    end
    local function start_martin(b)
        caught = b
        b.listening = a
        b.dir0 = b.dir
        local side = cx > b.x and 1 or -1
        b.steps = {
            { clip = "walk", walk_to = cx - side * 0.3 * u, v = (b.v or walk_v(b.spr)) * 0.45 },   -- creeping in
            { clip = "turn_front", face = side },
            { clip = "idle", dur = 1.2, on_start = function() honk_all(cx) end },
            { clip = "idle", dur = 1.6, on_start = function() honk_all(cx) end },
            { clip = "turn_side", face = b.dir0 },
            { clip = "walk", walk_to = clamp(cx + b.dir0 * 0.3 * W, -0.2 * W, 1.2 * W), v = (b.v or walk_v(b.spr)) * 1.4 },
        }
    end
    local want_martin = X.geese_martin or math.random() < (el.martin or 0.5)
    X.geese_martin = nil
    function a.update(dt, t)
        local all_there, all_gone = true, true
        local n_now = now()
        if state == "stay" then
            if want_martin and not caught then
                local b = free_martin(3)
                if b then start_martin(b)
                elseif not hunt_until then hunt_until = n_now + 20; call_martin() end
                if hunt_until and n_now > hunt_until then want_martin = false end
            end
            if n_now - stood > stay and (not caught or not caught.steps[1] or caught.dead) then state = "out" end
        end
        local layers = {}
        for i, g in ipairs(G) do
            g.tc = g.tc + dt
            if state == "in" then
                local tx = cx + g.off
                if math.abs(tx - g.x) > 2 then
                    g.dir = tx > g.x and 1 or -1
                    g.x = g.x + g.dir * math.min(v * dt, math.abs(tx - g.x))
                    g.clip = "walk"
                    all_there = false
                elseif g.clip == "walk" then g.clip, g.tc = "idle", 0 end
            elseif state == "stay" then
                if g.clip == "honk" then
                    local _, done = clip_frame(spr, "honk", g.tc)
                    if done then g.clip, g.tc = "idle", 0 end
                elseif n_now > g.next_honk then
                    g.clip, g.tc, g.next_honk = "honk", 0, n_now + rnd(6, 16)
                    if math.random() < 0.5 then g.dir = -g.dir end
                end
            else
                g.dir = dir
                g.clip = "walk"
                g.x = g.x + dir * v * dt
            end
            if g.x > -2 * u and g.x < W + 2 * u then all_gone = false end
            local frame = clip_frame(spr, g.clip, g.tc)
            layers[i] = layer(spr, frame, g.dir < 0, g.x, H, 0, g.dy)
        end
        if state == "in" and all_there then state, stood = "stay", n_now end
        if state == "out" and all_gone then return false end
        a.cx = cx
        return true, layers
    end
    a.leave = function() state = "out" end
    return a
end

-- ── teenagers at a door ─────────────────────────────────────────────────────

function X.teens(el, spr, h)
    local W, H = E.W(), E.H()
    local sa, sb = sprite((el.sprites or {})[1] or "teen_a"), sprite((el.sprites or {})[2] or "teen_b")
    if not (sa and sb and sa.clips and sb.clips) then return nil end
    -- a door: a house here that's free, or one comes up for them
    local house
    for _, b in ipairs(others("house")) do if b.can_hear and b.can_hear() then house = b end end
    if not house then
        local hel = el_of("stm_house")
        if not hel then return nil end
        local hs = E.free_sprite(hel)
        house = hs and X.house(hel, hs, math.random() < 0.4)
        if not house or not add(house, hel, true) then return nil end
    end
    house.busy, house.busy_t = true, now() + 30
    local u = unit(sa)
    local dir = house.x > W / 2 and 1 or -1           -- (they come in from the far side, walk to the door)
    local a = { el = el, spr = sa, stm = "teens", layers = 3 }
    local P = {
        { spr = sa, x = dir > 0 and -u or W + u, dir = dir, steps = {}, tc = 0, v = walk_v(sa) },
        { spr = sb, x = dir > 0 and -2.2 * u or W + 2.2 * u, dir = dir, steps = {}, tc = 0, v = walk_v(sa) },
    }
    local door = house.x
    local turnip = nil
    local open = not house.grumpy and math.random() < 0.6
    local function off(p) p.steps[#p.steps + 1] = { clip = "sulk", walk_to = dir > 0 and W + 3 * u or -3 * u, face = dir } end
    P[1].steps = { { clip = "walk", walk_to = door - dir * 0.9 * u }, { clip = "turn_front" },
                   { clip = "ring", on_start = function() house.play("ring", false, function() house.play("idle") end) end },
                   { clip = "idle", wait = function() return a.answered end } }
    P[2].steps = { { clip = "walk", walk_to = door - dir * 2.0 * u }, { clip = "turn_front" },
                   { clip = "idle", wait = function() return a.answered end } }
    local function answer()
        if open then
            house.play("open", false, function()
                house.play("offer")
                local ts = sprite("turnip")
                fly(ts, door, house.door_y, P[1].x, H - 0.8 * u, 0.8, function()
                    turnip = true
                    later(a, 1.6, function()
                        house.play("open", true, function() house.play("idle"); house.busy = nil end)
                    end)
                    a.answered = true
                end)
            end)
        else
            house.play("dark", false, function() house.dark = true; house.play("dark_idle"); house.busy = nil end)
            later(a, 1.5, function() a.answered = true end)
        end
    end
    later(a, 0, function() end)
    a.ring_t = nil
    for _, p in ipairs(P) do
        local pp = p
        local after = function()
            pp.steps[#pp.steps + 1] = { clip = "shrug", face = -dir }
            pp.steps[#pp.steps + 1] = { clip = "turn_side", face = dir }
            off(pp)
        end
        pp.after = after
    end
    function a.update(dt, t)
        tick_timers(a)
        if not a.ring_t and #P[1].steps > 0 and P[1].clip == "ring" then
            a.ring_t = now()
            later(a, 2.0, answer)
        end
        if a.answered and not a.shrugged then
            a.shrugged = true
            for _, p in ipairs(P) do p.steps = {}; p.after() end
        end
        local layers, gone = {}, true
        for i, p in ipairs(P) do
            local frame = run_steps(p, dt)
            if not frame then frame = clip_frame(p.spr, "idle", t) end
            if p.x > -2 * u and p.x < W + 2 * u then gone = false end
            layers[i] = layer(p.spr, frame, p.dir < 0, p.x, H)
        end
        if turnip then                                  -- carried along in the bag hand
            local ts = sprite("turnip")
            if ts then layers[3] = { spr = ts, frame = 0, variant = false, x = P[1].x - ts.w / 2 + P[1].dir * 0.25 * u,
                                     y = H - 0.75 * u - ts.h / 2 } end
        end
        if gone and a.shrugged then
            if house.busy == true then house.busy = nil end
            return false
        end
        a.cx = P[1].x
        return true, layers
    end
    return a
end

-- ── the border walk ─────────────────────────────────────────────────────────

local function flag_layer(spr, x, y_ground, rise)
    if not spr then return nil end
    local crop = nil
    if rise < 1 then crop = { 0, 0, spr.w, math.max(1, spr.h * rise) } end
    local l = layer(spr, 0, false, x, y_ground, 0, (1 - rise) * spr.h * 0)
    l.frame = clip_frame(spr, "wave", now())
    if rise < 1 then l.y = y_ground - spr.h * rise - (spr.origin and (spr.origin[2] - spr.h) or 0); l.crop = crop end
    return l
end

function X.border(el, spr, h)
    local W, H = E.W(), E.H()
    local sf, sd = sprite(el.french or "french"), sprite(el.dutch or "dutch")
    if not (sf and sd and sf.clips and sd.clips) then return nil end
    local u = unit(sf)
    if h then
        -- the Frenchman going round: home again? (the screen where the Dutchman waits)
        for _, b in ipairs(others("border")) do
            if b.wait_fr and (h.home == nil or h.home == b.token) then b.fr_back(h) return nil end
        end
        -- passing through: across this screen and on
        local a = { el = el, spr = sf, stm = "border_pass", hops = tonumber(h.hops) or 1, unique = false }
        local p = { spr = sf, dir = h.dir == 1 and 1 or -1, steps = {}, tc = 0, v = walk_v(sf) }
        local home = h.home
        p.x = E.walk_in_x(h, p.v, 0.5 * u)
        if math.random() < 0.5 then
            p.steps = { { clip = "walk", walk_to = E.free_x(0.3 * W, 0.7 * W) }, { clip = "drink" } }
        end
        function a.update(dt, t)
            local frame = run_steps(p, dt)
            if not frame then
                p.x = p.x + p.dir * p.v * dt
                E.walk_out(a, p.x, p.dir, 0.5 * u, { role = "fr", home = home })
                if p.x < -2 * u or p.x > W + 2 * u then return false end
                frame = clip_frame(sf, "walk", t)
            end
            a.cx = p.x
            local l = layer(sf, frame, p.dir < 0, p.x, H)
            return true, l.x, l.y, l.frame, l.variant
        end
        return a
    end
    local a = { el = el, spr = sd, stm = "border", layers = 5, hops = 0, token = tostring(math.random(1, 1e9)) }
    local x0 = W / 2
    local fdir = math.random() < 0.5 and 1 or -1
    local F = { spr = sf, x = x0 + fdir * 0.2 * u, dir = fdir, steps = {}, tc = 0, v = walk_v(sf) }
    local D = { spr = sd, x = x0 - fdir * 0.2 * u, dir = -fdir, steps = {}, tc = 0, v = walk_v(sd) }
    local sleep_x = x0 - fdir * rnd(0.22, 0.3) * W
    local flags = {}               -- {spr, x, rise}
    local fr_out_t, fr_gone = nil, false
    local wake_at = nil
    local martin_tried = false
    a.wait_fr = false
    local function plant(who, name, x)
        local fs = sprite(name)
        if fs then flags[#flags + 1] = { spr = fs, x = x, rise = 0 } end
    end
    -- back to back, a moment; off they go
    F.steps = { { clip = "idle", dur = 1.2, face = fdir }, { clip = "walk", walk_to = x0 + fdir * 0.25 * W },
                { clip = "drink" }, { clip = "walk", walk_to = fdir > 0 and W + 2 * u or -2 * u } }
    D.steps = { { clip = "idle", dur = 1.2, face = -fdir }, { clip = "walk", walk_to = x0 - fdir * 0.08 * W },
                { clip = "drink" }, { clip = "walk_slow", walk_to = x0 - fdir * 0.16 * W, v = D.v * 0.55 },
                { clip = "drink" }, { clip = "walk_slow", walk_to = sleep_x, v = D.v * 0.45 },
                { clip = "sit_down", on_end = function() a.wait_fr = true; a.asleep_t = now(); wake_at = now() + 60 end },
                { clip = "sleep", wait = function() return wake_at and now() > wake_at end } }
    local function dutch_wakes()
        D.steps = { { clip = "stand" }, { clip = "idle", dur = 0.8, face = fdir },
                    { clip = "shrug" },
                    { clip = "plant", face = fdir, on_end = function() plant("nl", el.flag_nl or "flag_nl", D.x + fdir * 0.7 * u) end },
                    { clip = "idle", dur = 1.5 },
                    { clip = "walk", walk_to = fdir > 0 and W + 2 * u or -2 * u, face = fdir } }   -- (home: back the way he came)
        a.blanket = a.blanket and "off" or nil
    end
    function a.fr_back(hh)          -- round the island: he comes in from the other side
        if not a.wait_fr then return end
        a.wait_fr = false
        fr_gone = false
        F.dir = fdir
        F.x = hh and E.walk_in_x(hh, F.v, 0.5 * u) or (fdir > 0 and -u or W + u)
        F.steps = { { clip = "walk", walk_to = D.x - fdir * 1.6 * u },
                    { clip = "idle", dur = 0.8 },
                    { clip = "plant", on_end = function() plant("fr", el.flag_fr or "flag_fr", D.x - fdir * 1.0 * u) end },
                    { clip = "cheer" },
                    { clip = "walk", walk_to = D.x - fdir * 3 * u, face = -fdir },
                    { clip = "idle", dur = 0.2, on_end = function() wake_at = now() + rnd(1, 2) end },
                    { clip = "walk", walk_to = fdir > 0 and -2 * u or W + 2 * u, face = -fdir } }
    end
    local function martin_blanket(b)
        b.listening = a
        b.dir0 = b.dir
        local side = D.x > b.x and 1 or -1
        b.steps = { { clip = "walk", walk_to = D.x - side * 1.1 * u } }
        for _, s in ipairs(martin_cut_steps(b, side, function()
            local cl = sprite("cloth")
            fly(cl, b.x + side * 0.45 * unit(b.spr), H - 1.1 * unit(b.spr), D.x, H - 0.5 * u, 0.9, function()
                a.blanket = "on"
                if wake_at then wake_at = wake_at + 20 end           -- snug: he sleeps on
            end)
        end)) do b.steps[#b.steps + 1] = s end
    end
    function a.update(dt, t)
        local n = now()
        -- the Frenchman gone round: hand over next door, or (one screen) back in from the other side
        if not fr_gone and not F.steps[1] then
            F.x = F.x + F.dir * F.v * dt
            local proxy = a.proxy or { el = el, hops = 0, unique = false, spr = sf }
            a.proxy = proxy
            E.walk_out(proxy, F.x, F.dir, 0.5 * u, { role = "fr", sprite = sf.name, home = a.token })   -- (his Dutchman's screen)
            if F.x < -1.5 * u or F.x > W + 1.5 * u then
                fr_gone, fr_out_t = true, n
                if proxy.handed_on ~= "yes" then fr_out_t = n - 100 end      -- (no one next door)
            end
        end
        if fr_gone and a.wait_fr and fr_out_t and n - fr_out_t > (fr_out_t < n - 50 and -1 or 0) then
            if fr_out_t < n - 50 then
                -- one screen: round the island takes a while, then in from the other side
                if n - (a.asleep_t or n) > rnd(7, 9) then a.fr_back(nil) end
            elseif n - fr_out_t > 75 then a.fr_back(nil) end              -- (lost on the way: back anyway)
        end
        -- asleep: St Martin may come by with a piece of his cloak
        if a.wait_fr and not martin_tried and (X.border_martin or math.random() < (el.martin or 0.6)) then
            martin_tried = "looking"
            X.border_martin = nil
            a.look_until = n + 15
            if not free_martin(2) then call_martin() end
        end
        if martin_tried == "looking" then
            local b = free_martin(2)
            if b and a.wait_fr then martin_tried = true; martin_blanket(b); if wake_at then wake_at = math.max(wake_at, n + 25) end
            elseif n > (a.look_until or 0) then martin_tried = true end
        end
        if wake_at and n > wake_at and D.clip == "sleep" and not a.woke then a.woke = true; dutch_wakes() end
        -- draw
        local layers = {}
        local fframe = run_steps(F, dt)
        if not fframe and not fr_gone then fframe = clip_frame(sf, "walk", t) end
        if fframe and F.x > -2 * u and F.x < W + 2 * u then layers[2] = layer(sf, fframe, F.dir < 0, F.x, H) end
        local dframe = run_steps(D, dt) or clip_frame(sd, "sleep", t)
        layers[1] = layer(sd, dframe, D.dir < 0, D.x, H)
        if a.blanket == "on" then
            local cl = sprite("cloth")
            if cl then layers[3] = { spr = cl, frame = 0, variant = false, x = D.x - cl.w / 2, y = H - 0.45 * u - cl.h / 2 } end
        end
        for i, f in ipairs(flags) do
            f.rise = math.min(1, f.rise + dt / 0.6)
            if i <= 2 then layers[3 + i] = layer(f.spr, clip_frame(f.spr, "wave", t), false, f.x, H, 0, (1 - f.rise) * f.spr.h) end
        end
        a.cx = D.x
        -- the end: both gone, the flags a while longer
        if a.woke and not D.steps[1] then
            a.end_t = a.end_t or n
            if n - a.end_t > 8 then return false end
        elseif not D.steps[1] and D.x and (D.x < -2 * u or D.x > W + 2 * u) then return false end
        if D.x < -2 * u or D.x > W + 2 * u then layers[1] = nil end
        return true, layers
    end
    a.leave = function() wake_at = now() end
    return a
end

-- ── the island story ────────────────────────────────────────────────────────

function X.island(el, spr, h)
    local W, H = E.W(), E.H()
    local whole, half_fr, half_nl = sprite(el.whole or "island_whole"), sprite(el.fr or "island_fr"), sprite(el.nl or "island_nl")
    local ship, col = sprite(el.ship or "caravel"), sprite(el.columbus or "columbus_s")
    local sf, sd = sprite(el.french or "french_s"), sprite(el.dutch or "dutch_s")
    local fcol, ffr, fnl = sprite(el.flag or "flag_columbus_s"), sprite(el.flag_fr or "flag_fr_s"), sprite(el.flag_nl or "flag_nl_s")
    local coco = sprite(el.coconut or "coconut")
    if not (whole and half_fr and half_nl and ship and col and sf and sd) then return nil end
    local sc = whole.h / 260                   -- island.json: 520 x 260, the cut at 300, the water line 236
    local iw = whole.w
    local ix = clamp(E.free_x(0.3 * W, 0.7 * W) - iw / 2, 0.02 * W, W - iw - 0.02 * W)
    local base = H                             -- (the island's bottom on the screen's)
    local top = base - whole.h
    local function P(bx, by) return ix + bx * sc, top + by * sc end
    local _, ground = P(0, 206)                 -- where the people stand on it
    local a = { el = el, spr = whole, stm = "island", layers = 12, t0 = now() }
    local phase, pt = "rise", 0
    local rise = 0
    local split = 0                            -- 0 whole .. 1 apart
    local jolt = 0
    local shipx = -ship.w
    local ship_clip, ship_tc, ship_dir = "sail", 0, 1
    local bow_x = ix + 30 * sc                  -- where the bow touches
    local C = { spr = col, x = 0, dir = 1, steps = {}, tc = 0, v = walk_v(col), on = false, hop = 0 }
    local Fp = { spr = sf, x = select(1, P(140, 0)), dir = 1, steps = {}, tc = 0, v = walk_v(sf), up = 0 }
    local Dp = { spr = sd, x = select(1, P(420, 0)), dir = -1, steps = {}, tc = 0, v = walk_v(sd), up = 0 }
    local flag_c, flag_f, flag_n = nil, nil, nil          -- planted: {x, rise}
    local coconut = nil                                   -- {x, y, vy, rest}
    local slash = nil                                     -- the sword's slice: time it started
    local martin = nil
    local looked = false
    local function go(p) phase, pt = p, 0 end
    local u = unit(sf)
    function a.update(dt, t)
        pt = pt + dt
        local n = now()
        if phase == "rise" then
            rise = math.min(1, pt / 2)
            if pt > 2.2 then go("sail") end
        elseif phase == "sail" then
            local to = bow_x - ship.w * 0.5 - 0.42 * ship.w + 0.05 * ship.w
            shipx = -ship.w + (to + ship.w) * ease(pt / 5)
            if pt >= 5 then go("bump"); ship_clip, ship_tc = "bump", 0; jolt = 0.5
                coconut = { x = select(1, P(372, 0)), y = select(2, P(0, 96)), vy = 0 }
            end
        elseif phase == "bump" then
            if pt > 0.8 then ship_clip = "sail" end
            if pt > 1.6 then
                go("ashore")
                C.on, C.x, C.dir, C.hop = true, shipx + ship.w * 0.42, 1, 0
                C.steps = { { clip = "walk", walk_to = select(1, P(160, 0)), v = C.v * 1.2, on_start = function() C.hop = 1 end },
                            { clip = "walk", walk_to = select(1, P(255, 0)), on_start = function() C.hop = 0 end },
                            { clip = "turn_front" },
                            { clip = "plant", on_end = function() flag_c = { x = select(1, P(275, 0)), rise = 0 } end },
                            { clip = "cheer" } }
            end
        elseif phase == "ashore" then
            if not C.steps[1] then go("pop") end
        elseif phase == "pop" then
            Fp.up = math.min(1, pt / 1.2)
            Dp.up = math.min(1, math.max(0, (pt - 0.4) / 1.2))
            if pt > 1.8 then
                go("look")
                Fp.steps = { { clip = "idle", dur = 1.0, face = 1 }, { clip = "idle", dur = 1.4, face = 1 } }
                Dp.steps = { { clip = "idle", dur = 1.0, face = -1 }, { clip = "idle", dur = 1.4, face = -1 } }
                C.steps = { { clip = "idle", dur = 1.2 }, { clip = "turn_side", face = -1 },
                            { clip = "walk", walk_to = select(1, P(160, 0)) },
                            { clip = "walk", walk_to = shipx + ship.w * 0.42, on_start = function() C.hop = 1 end,
                              on_end = function() C.on = false; flag_c = flag_c and { x = flag_c.x, rise = flag_c.rise, gone = true } end } }
            end
        elseif phase == "look" then
            if not C.on then
                ship_dir = -1
                shipx = shipx - (0.06 * W) * dt * math.min(1, pt)
                if shipx < -ship.w * 1.2 and not looked then
                    looked = true
                    go("squabble")
                    Fp.steps = { { clip = "plant", face = 1, on_end = function() flag_f = { x = select(1, P(205, 0)), rise = 0 } end },
                                 { clip = "plant" }, { clip = "cheer" }, { clip = "plant" } }
                    Dp.steps = { { clip = "idle", dur = 0.6 }, { clip = "plant", face = -1, on_end = function() flag_n = { x = select(1, P(345, 0)), rise = 0 } end },
                                 { clip = "shrug" }, { clip = "plant" } }
                    -- St Martin: here and free, or called over
                    if not free_martin(2) then call_martin() end
                end
            end
        elseif phase == "squabble" then
            local b = (not martin) and free_martin(2)
            if b then
                martin = b
                b.listening = a
                b.dir0 = b.dir
                local side = (ix + iw / 2) > b.x and 1 or -1
                local stand = side > 0 and (ix - 0.5 * unit(b.spr)) or (ix + iw + 0.5 * unit(b.spr))
                b.steps = { { clip = "walk", walk_to = stand } }
                for _, s in ipairs(martin_cut_steps(b, side, function()
                    -- he hands each one his half: they step onto it
                    Fp.steps = { { clip = "walk", walk_to = select(1, P(150, 0)) - 0.05 * W, face = -1 }, { clip = "cheer", face = 1 } }
                    Dp.steps = { { clip = "walk", walk_to = select(1, P(420, 0)) + 0.05 * W, face = 1 }, { clip = "shrug", face = -1 } }
                end)) do b.steps[#b.steps + 1] = s end
                -- the cut itself: when his sword comes down
                local cut = b.steps[4]
                local old = cut.on_end
                cut.on_start = function() slash = n + 0.25 end
                cut.on_end = function() if old then old() end end
                go("martin")
            elseif pt > 14 then
                slash = n                           -- no St Martin about: a plain sword slice
                go("slice")
            end
        elseif phase == "martin" then
            if slash and n > slash then split = math.min(1, split + dt / 0.8) end
            if split >= 1 and (not martin.steps[1] or martin.dead or martin.listening ~= a) and not Fp.steps[1] and not Dp.steps[1] then go("end") end
            if pt > 40 then go("end") end
        elseif phase == "slice" then
            if n > slash + 0.3 then split = math.min(1, split + dt / 0.8) end
            if split >= 1 and pt > 1.4 and not a.stepped then
                a.stepped = true
                Fp.steps = { { clip = "walk", walk_to = select(1, P(150, 0)) - 0.05 * W, face = -1 }, { clip = "cheer", face = 1 } }
                Dp.steps = { { clip = "walk", walk_to = select(1, P(420, 0)) + 0.05 * W, face = 1 }, { clip = "shrug", face = -1 } }
            end
            if a.stepped and not Fp.steps[1] and not Dp.steps[1] then go("end") end
        elseif phase == "end" then
            if pt > 4 then rise = math.max(0, 1 - (pt - 4) / 2) end
            if pt > 6.2 then return false end
        end
        ship_tc = ship_tc + dt
        jolt = math.max(0, jolt - dt)
        -- coconut falls off the palm
        if coconut and not coconut.rest then
            coconut.vy = coconut.vy + 2.5 * H * dt
            coconut.y = coconut.y + coconut.vy * dt
            if coconut.y >= ground - 0.01 * H then coconut.y, coconut.rest = ground - 0.01 * H, true end
        end
        -- the layers, bottom to top
        local dy = (1 - ease(rise)) * (whole.h + 0.3 * H)
        local jx = jolt > 0 and math.sin(jolt * 60) * 0.006 * W or 0
        local apart = ease(split) * 0.05 * W
        local L = {}
        local sfr = ship_clip == "bump" and clip_frame(ship, "bump", ship_tc) or clip_frame(ship, "sail", t)
        if shipx > -ship.w * 1.1 then
            L[1] = layer(ship, sfr, ship_dir < 0, shipx + ship.w / 2, base - 0.05 * whole.h, 0, dy)
        end
        if split <= 0 then
            L[2] = { spr = whole, frame = 0, variant = false, x = ix + jx, y = top + dy }
        else
            L[2] = { spr = half_fr, frame = 0, variant = false, x = ix - apart, y = top + dy }
            L[3] = { spr = half_nl, frame = 0, variant = false, x = ix + 300 * sc + apart, y = top + dy }
        end
        local function shift(x) if split <= 0 then return x + jx end return x + ((x < ix + 300 * sc) and -apart or apart) end
        if flag_c and not flag_c.gone then
            flag_c.rise = math.min(1, flag_c.rise + dt / 0.5)
            if fcol then L[4] = layer(fcol, clip_frame(fcol, "wave", t), false, shift(flag_c.x), ground, 0, dy + (1 - flag_c.rise) * fcol.h * 0.3) end
        end
        if flag_f and ffr then
            flag_f.rise = math.min(1, flag_f.rise + dt / 0.5)
            L[5] = layer(ffr, clip_frame(ffr, "wave", t), false, shift(flag_f.x), ground, 0, dy)
        end
        if flag_n and fnl then
            flag_n.rise = math.min(1, flag_n.rise + dt / 0.5)
            L[6] = layer(fnl, clip_frame(fnl, "wave", t), false, shift(flag_n.x), ground, 0, dy)
        end
        local function person(p, idx, popping)
            local fr = run_steps(p, dt) or clip_frame(p.spr, p.clip_rest or "idle", t)
            local x = (phase == "martin" or phase == "slice" or phase == "end") and p.x or shift(p.x)
            local l = layer(p.spr, fr, p.dir < 0, x, ground, 0, dy)
            if popping then
                local up = ease(p.up)
                if up <= 0 then return end
                -- rising from behind the island: only the part above the hill line shows
                local hide = (1 - up) * p.spr.h
                l.y = l.y + hide
                l.crop = { 0, 0, p.spr.w, math.max(1, p.spr.h - hide) }
            end
            L[idx] = l
        end
        if phase ~= "rise" and phase ~= "sail" and phase ~= "bump" then
            if Fp.up > 0 then person(Fp, 7, Fp.up < 1) end
            if Dp.up > 0 then person(Dp, 8, Dp.up < 1) end
        end
        if C.on then
            local fr = run_steps(C, dt) or clip_frame(col, "idle", t)
            local hy = C.hop > 0 and -math.abs(math.sin(n * 6)) * 0.03 * H or 0
            L[9] = layer(col, fr, C.dir < 0, shift(C.x), ground, 0, dy + hy)
        end
        if coconut and coco then
            L[10] = { spr = coco, frame = 0, variant = false, x = shift(coconut.x) - coco.w / 2, y = coconut.y - coco.h + dy }
        end
        a.slash_on = slash and n > slash - 0.05 and n < slash + 0.35
        a.cx = ix + iw / 2
        return true, L
    end
    -- the sword's slice: a bright line down through the middle (drawn as ASS)
    function a.ass(out)
        if not a.slash_on then return end
        local x = ix + 300 * sc
        out[#out + 1] = string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&HFFFFFF&\\1a&H20&\\blur3\\p1}m %d %d l %d %d l %d %d l %d %d{\\p0}",
            x - 3, top - 0.1 * H, x + 3, top - 0.1 * H, x + 6, H, x - 6, H)
    end
    a.leave = function() go("end") end
    return a
end

-- ── the 11:11 parade ───────────────────────────────────────────────────────

function X.parade(el, spr, h)
    local W, H = E.W(), E.H()
    local today = clock("%Y-%m-%d")
    if not h then
        local st = E.elements()[el]
        local forced = st and st.force
        local at = el.at or "11:11"
        if not forced and (clock("%H:%M") ~= at or parade_day == today) then return nil end
    end
    parade_day = today
    local names = el.members or { "prince", "jester", "brass", "brass" }
    local M = {}
    for _, nm in ipairs(names) do
        local s = sprite(nm)
        if s and s.clips and s.clips.walk then M[#M + 1] = { spr = s, name = nm } end
    end
    if #M == 0 then return nil end
    local u = unit(M[1].spr)
    local dir = h and (h.dir == 1 and 1 or -1) or (math.random() < 0.5 and 1 or -1)
    local v = walk_v(M[1].spr) * 0.8
    local gap = 1.3 * u
    local head = h and E.walk_in_x(h, v, 0.5 * u) or (dir > 0 and -0.6 * u or W + 0.6 * u)
    local a = { el = el, spr = M[1].spr, stm = "parade", layers = #M, hops = h and tonumber(h.hops) or 0, unique = true }
    local conf = {}
    for i = 1, 40 do conf[i] = { x = rnd(0, 1), y = rnd(0, 1), c = ({ "&H2E40E8&", "&H33CCFF&", "&H50AF4C&", "&HC2577E&", "&H1E8AFF&" })[math.random(5)] } end
    function a.update(dt, t)
        head = head + dir * v * dt
        local last = head - dir * gap * (#M - 1)
        -- across the room once: on to the next screen till each has had it (then off the last one)
        if (a.hops or 0) < (E.room().screens or 1) - 1 then E.walk_out(a, head, dir, 0.5 * u, { members = names }) end
        if (dir > 0 and last > W + 1.5 * u) or (dir < 0 and last < -1.5 * u) then return false end
        local L = {}
        for i, m in ipairs(M) do
            local x = head - dir * gap * (i - 1)
            local clip = "walk"
            if m.name == "jester" and (math.floor(t / 3) % 2 == 0) and m.spr.clips.hop then clip = "hop" end
            if m.name == "prince" and m.spr.clips.wave then clip = "wave" end
            if m.name == "brass" and m.spr.clips.play then clip = "play" end
            local fr = clip_frame(m.spr, clip, t + i * 0.37)
            L[i] = layer(m.spr, fr, dir < 0, x, H)
        end
        a.cx, a.x0, a.x1 = head, math.min(head, last), math.max(head, last)
        return true, L
    end
    function a.ass(out, t)                 -- confetti over them
        if not a.x0 then return end
        local w = a.x1 - a.x0 + 2 * u
        for _, c in ipairs(conf) do
            local y = ((c.y + (t or 0) * 0.15) % 1) * 0.55 * H + 0.35 * H
            local x = a.x0 - u + c.x * w + math.sin((t or 0) * 3 + c.y * 9) * 0.01 * W
            local s = 0.006 * H
            out[#out + 1] = string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c%s\\p1}m %d %d l %d %d l %d %d l %d %d{\\p0}",
                c.c, x, y, x + s, y + s * 0.3, x + s * 0.7, y + s * 1.2, x - s * 0.3, y + s)
        end
    end
    return a
end

-- ── install ─────────────────────────────────────────────────────────────────

function X.install(api, stm, extra)
    E, S, E2 = api, stm, extra
    -- the children's meetings (stmaarten.lua S.meet): they sing at the door, at the cow, by the fire
    if S and S.meet then
        S.meet[#S.meet + 1] = { who = "house", chance = 0.75, near = 3.4, stand = 1.3 }
        S.meet[#S.meet + 1] = { who = "cow", chance = 0.6, near = 3.6, stand = 2.2 }
        S.meet[#S.meet + 1] = { who = "bonfire", chance = 0.6, near = 3.6, stand = 1.8 }
    end
    E.spawn.stm_house, E.spawn.stm_bonfire = X.spawn_house, X.spawn_bonfire
    E.spawn.stm_cow, E.spawn.stm_geese, E.spawn.stm_teens = X.cow, X.geese, X.teens
    E.spawn.stm_border, E.spawn.stm_island, E.spawn.stm_parade = X.border, X.island, X.parade
    E.spawn.stm_scenery = X.scenery
    if S then S.clock_hands = X.clock_hands end       -- (the church's clock)
    local function kids() mp.commandv("keypress", "F6") end
    mp.add_forced_key_binding("F9", "stmx-house", function() X.want_grumpy = false; force("stm_house"); kids() end)
    mp.add_forced_key_binding("Shift+F9", "stmx-house-grumpy", function() X.want_grumpy = true; force("stm_house"); kids() end)
    mp.add_forced_key_binding("Ctrl+F9", "stmx-bonfire", function() force("stm_bonfire"); kids() end)
    mp.add_forced_key_binding("F10", "stmx-cow", function() force("stm_cow"); kids() end)
    mp.add_forced_key_binding("F11", "stmx-geese", function() X.geese_martin = true; force("stm_geese") end)
    mp.add_forced_key_binding("F12", "stmx-island", function() force("stm_island") end)
    mp.add_forced_key_binding("Shift+F10", "stmx-border", function() X.border_martin = true; force("stm_border") end)
    mp.add_forced_key_binding("Shift+F11", "stmx-parade", function() force("stm_parade") end)
    mp.add_forced_key_binding("Shift+F12", "stmx-teens", function() force("stm_teens") end)
    mp.add_forced_key_binding("Ctrl+F10", "stmx-flyers", function()
        for _, el in ipairs(E.M() and E.M().elements or {}) do
            if el.type == "flyer" and el.sprite == "geese_v" and E.elements()[el] then
                E.elements()[el].next, E.elements()[el].force = 0, true
            end
        end
    end)
end

return X
