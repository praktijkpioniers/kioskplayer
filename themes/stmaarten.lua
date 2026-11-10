-- St Maarten (11-11): lantern children, St Martin sharing his cloak, beggars. Loaded by engine.lua
-- (hooks.stm), which hands over a small API (install); the actors it makes are ordinary engine actors.
--
--   kid (element type "kid"): children with lanterns on sticks walking across, alone, in twos and
--     threes, or as a procession (el.procession, n = [3, 8]) in a line with spacing; handed on to the
--     screen next door (h.grp keeps the group together). The lantern is drawn on the tracked hand
--     ("hand.l" in the kid's clips), its colour and shape picked at random (el.lanterns).
--     Meetings (S.meet below, one entry each): a group meeting St Martin or a beggar stops and sings
--     (notes rising, a bob); St Martin then hands each child a sweet; a beggar gets something from
--     one child: a sweet, a mandarin, an apple, a present or the child's lantern, left by him.
--     A group walking up to one singing joins in.
--   martin: St Martin on foot, cloak stages el.stages (full, half, quarter, none). He finds a beggar
--     sitting in the cold, stops, cuts a piece off his cloak with his sword and hands it over (the
--     beggar is wrapped in it, warms up, gets up and walks off). On to the next one, here or next door
--     (h.stage). With no cloak left he sits down in the cold himself: one of the beggars now, and a new
--     St Martin with a full cloak comes along and finds him. One St Martin in the room (chr:martin).
--   beggar: walks in slowly, sits down and huddles (shivers); a while, then gets up and goes.
-- Preview keys: F5 St Martin now (and a beggar here), F6 children (they meet whoever's here),
-- F7 a procession, F8 a beggar.

local S = {}
local E                         -- the engine API (see install)
local groups = {}               -- kid groups on this screen, by id
local sure_until = 0            -- (preview) meetings certain till then
local martin_hint = nil         -- where the last St Martin sat down: the next one comes that way

local function rnd(a, b) return a + math.random() * (b - a) end
local function range(v, d)
    if type(v) == "table" then return v[1], v[2] end
    if v == nil then return d, d end
    return v, v
end
local function now() return mp.get_time() end

-- ── baked characters: clips, layers ─────────────────────────────────────────

local function clip_frame(spr, name, tc, reverse, rate)
    local C = spr.clips or {}
    local c = C[name] or C.idle or C.walk
    if not c then return 0, true, 0, nil end
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
    if not c or c.count == 0 then return 0.05 * E.H() end
    return math.max(1, c.stride_px * c.fps / c.count)
end
-- a layer for the sprite with its baked origin (world x = 0 on the ground) at screen cx, ground
local function layer(spr, frame, mirror, cx, ground, dx, dy)
    local o = spr.origin or { spr.w / 2, spr.h }
    local x = mirror and (cx - (spr.w - o[1])) or (cx - o[1])
    return { spr = spr, frame = frame, variant = mirror and true or false, x = x + (dx or 0), y = ground - o[2] + (dy or 0) }
end
local function unit(spr) return (spr.unit or 0.1) * E.H() end

-- steps: {clip, dur | walk_to (x) | wait (fn) | (till the clip ends), reverse, rate, face, on_start, on_end}
local function run_steps(a, dt)
    local s = a.steps[1]
    if not s then return nil end
    if not s.started then
        s.started, a.tc = true, 0
        if s.face then a.dir = s.face end
        if s.on_start then s.on_start() end
    end
    a.tc = a.tc + dt
    local done = false
    if s.walk_to then
        local d = s.walk_to - a.x
        local dir = d >= 0 and 1 or -1
        a.dir = dir
        local mv = (s.v or a.v) * dt
        if math.abs(d) <= mv then a.x, done = s.walk_to, true else a.x = a.x + dir * mv end
    end
    local frame, cdone, k, c = clip_frame(a.spr, s.clip, a.tc, s.reverse, s.rate)
    if s.dur then done = done or a.tc >= s.dur
    elseif s.wait then done = s.wait()
    elseif not s.walk_to then done = cdone end
    a.clip, a.k, a.c = s.clip, k, c
    if done then
        table.remove(a.steps, 1)
        if s.on_end then s.on_end() end
    end
    return frame
end

-- a little thing flying from (x0, y0) to (x1, y1) in an arc (a sweet, a piece of cloak); done() at the end
local function fly(spr, x0, y0, x1, y1, dur, done)
    if not spr or E.free_ids() < 1 then if done then done() end return end
    local a = { el = { type = "stm_fly", hz = 30, video_min = 0 }, spr = spr, uncounted = true }
    local t = 0
    function a.update(dt)
        t = t + dt
        local p = math.min(1, t / dur)
        local x = x0 + (x1 - x0) * p
        local y = y0 + (y1 - y0) * p - math.sin(math.pi * p) * 0.08 * E.H()
        if p >= 1 then
            if done then done() end
            return false
        end
        return true, x - spr.w / 2, y - spr.h / 2, 0, false
    end
    E.add(a)
end

-- a thing left lying by someone (a gift by a beggar): stays while its owner is about, then sinks
local function relic(spr, x, owner)
    if not spr or E.free_ids() < 1 then return end
    local a = { el = { type = "stm_relic", hz = 8, video_min = 0 }, spr = spr, uncounted = true }
    local t, gone_t = 0, nil
    function a.update(dt, tt)
        t = t + dt
        if owner.dead and not gone_t then gone_t = t + rnd(3, 8) end
        if gone_t and t > gone_t then E.leave(a) end
        local fr = spr.frames > 1 and math.floor(tt * math.max(spr.fps or 8, 1)) or 0
        return true, x - spr.w / 2, E.H() - spr.h, fr, false
    end
    E.add(a)
    owner.gifts = owner.gifts or {}
    owner.gifts[#owner.gifts + 1] = a
end

local function others(stm)
    local list = {}
    for _, b in ipairs(E.actors()) do
        if b.stm == stm and not b.dead and not b.leaving then list[#list + 1] = b end
    end
    return list
end

-- ── beggars ─────────────────────────────────────────────────────────────────

local function beggar_el()
    for _, e in ipairs(E.M().elements) do if e.type == "beggar" then return e end end
end

function S.beggar(el, spr, h)
    local C = spr.clips
    if not (C and C.sit and C.sit_down and spr.origin) then return nil end
    local W, H = E.W(), E.H()
    local u = unit(spr)
    local a = { el = el, spr = spr, stm = "beggar", steps = {}, tc = 0, ex = h and h.ex }
    a.v = walk_v(spr) * 0.8
    a.dir = (h and h.dir) or (math.random() < 0.5 and 1 or -1)
    a.ttl = rnd(range(el.stay, 150))
    local function go_off(warm)
        local side = a.x < W / 2 and -1 or 1
        local edge = side < 0 and -u * 1.5 or W + u * 1.5
        a.steps[#a.steps + 1] = { clip = warm and "walk_w" or "walk", walk_to = edge, v = a.v * (warm and 1.4 or 1),
                                  on_end = function() a.dead = true end }
    end
    local function sit_here()
        a.sitting = true
        a.sat_t = now()
    end
    if h and h.seated then
        a.x = tonumber(h.x) or W / 2
        sit_here()
    else
        local sit_x = tonumber(h and h.sit_x) or E.free_x(0.2 * W, 0.8 * W)
        a.x = sit_x < W / 2 and -u or W + u            -- (in from the nearer side)
        a.dir = sit_x > a.x and 1 or -1
        a.steps = { { clip = "walk", walk_to = sit_x },
                    { clip = "sit_down", on_end = sit_here } }
    end
    function a.can_hear() return a.sitting and not a.warm and not a.claimed and not a.listening end
    function a.listen(g) a.listening = g end
    function a.react(g)         -- the children sang: one of them brings something
        local kid = g.pick_child(a)
        if not kid then g.resume() return end
        local gifts = { "sweet", "mandarin", "apple", "present" }
        if kid.lantern and math.random() < 0.3 then gifts = { "lantern" } end
        local gift = gifts[math.random(#gifts)]
        kid.errand(a, gift, function()
            a.listening = nil
            g.resume()
        end)
    end
    function a.thank()          -- (a gift put down by him)
        if a.sitting and not a.warm and not a.steps[1] then
            a.steps = { { clip = "reach", on_end = nil }, { clip = "reach", reverse = true } }
        end
    end
    function a.receive()        -- the piece of cloak: wrapped in it, warm, up and away
        a.warm = true
        a.steps = { { clip = "reach" }, { clip = "sit_w", dur = rnd(3, 5) },
                    { clip = "stand_w", on_start = function() a.sitting = false end },
                    { clip = "idle_w" } }
        go_off(true)
    end
    function a.update(dt, t)
        local frame = run_steps(a, dt)
        local mirror = a.dir < 0
        local dx = 0
        if not frame then
            if a.sitting then
                frame = clip_frame(spr, a.warm and "sit_w" or "sit", t)
                if not a.warm then dx = (math.floor(t * 14) % 2) * 2 - 1 end      -- shivering
                if now() - a.sat_t > a.ttl and not a.claimed and not a.listening then
                    a.sitting = false
                    a.steps = { { clip = "stand" } }
                    go_off(false)
                end
            else
                frame = clip_frame(spr, "idle", t)
            end
        end
        if a.dead then return false end
        local l = layer(spr, frame, mirror, a.x, H, dx)
        a.cx = a.x
        return true, l.x, l.y, l.frame, l.variant
    end
    a.leave = function() a.ttl = 0 end
    return a
end

-- ── St Martin ───────────────────────────────────────────────────────────────

local function stage_sprite(el, s)
    local names = el.stages or {}
    return E.M().sprites[names[s + 1] or ""]
end

function S.martin(el, spr, h)
    local W, H = E.W(), E.H()
    local room = E.room()
    if not h and (room.taken["chr:martin"] or #others("martin") > 0) then return nil end
    local stage = h and tonumber(h.stage) or 0
    spr = stage_sprite(el, stage) or spr
    if not (spr and spr.clips and spr.clips.walk and spr.origin) then return nil end
    local u = unit(spr)
    local a = { el = el, spr = spr, stm = "martin", family = "martin", steps = {}, tc = 0, stage = stage, unique = false }
    a.v = walk_v(spr)
    local front = 0.5 * u
    if h then
        a.dir = h.dir == 1 and 1 or -1
        a.x = E.walk_in_x(h, a.v, front)
    else
        if martin_hint then
            a.dir = martin_hint.x > W / 2 and 1 or -1      -- (from the far side: he passes the one sitting there)
            martin_hint = nil
        else
            a.dir = math.random() < 0.5 and 1 or -1
        end
        a.x = a.dir > 0 and -u or W + u
    end
    a.hops = h and tonumber(h.hops) or 0
    local function set_stage(s)
        a.stage = s
        local sp = stage_sprite(el, s)
        if sp then a.spr = sp end
    end
    local function sit_down_cold()
        local sx = math.max(0.15 * W, math.min(0.85 * W, a.x + a.dir * rnd(0.12, 0.25) * W))
        a.cold = true
        a.steps[#a.steps + 1] = { clip = "walk", walk_to = sx, v = a.v * 0.7 }
        a.steps[#a.steps + 1] = { clip = "sit_down", on_end = function()
            -- one of the beggars now: the next St Martin will find him
            local bel = beggar_el()
            if bel then
                local b = S.beggar(bel, a.spr, { seated = true, x = a.x, dir = a.dir, ex = true })
                if b then b.layers = nil; E.add(b, bel) end
            end
            martin_hint = { x = a.x }
            local st = E.elements()[el]
            if st then st.next, st.force = now() + rnd(6, 12), true end
            a.dead = true
        end }
    end
    local function share(b)           -- the act: stop by him, cut, hand over
        b.claimed = a
        local side = b.x > a.x and 1 or -1
        local stand = b.x - side * 1.05 * u
        a.steps = {
            { clip = "walk", walk_to = stand },
            { clip = "turn_front", face = side },
            { clip = "idle", dur = 0.6 },
            { clip = "cut", on_end = function() set_stage(math.min(3, a.stage + 1)) end },
            { clip = "give", on_start = function()
                local cl = E.M().sprites[el.cloth or "cloth"]
                local hx = a.x + side * 0.45 * u
                fly(cl, hx, H - 1.1 * u, b.x, H - 0.7 * u, 0.9, function() b.receive() end)
            end },
            { clip = "idle", dur = 1.2 },
            { clip = "turn_side", face = a.dir },
        }
        if a.stage >= 2 then        -- (this was the last piece)
            a.steps[#a.steps].on_end = function() sit_down_cold() end
        end
    end
    a.sit_down_cold = sit_down_cold     -- (stm_extra.lua: after it took his last piece of cloak)
    function a.can_hear() return not a.cold and not a.steps[1] and not a.listening end
    function a.listen(g)
        a.listening = g
        local side = g.x0 > a.x and 1 or -1
        a.steps = { { clip = "turn_front", face = side }, { clip = "idle", wait = function() return not a.listening or a.listening.mode ~= "sing" end } }
    end
    function a.react(g)               -- the children sang: a sweet for each of them
        local side = g.x0 > a.x and 1 or -1
        a.steps = {
            { clip = "give", face = side, on_start = function()
                local sw = E.M().sprites.sweet
                local d = 0
                for _, k in ipairs(g.singers()) do
                    d = d + 0.25
                    local kk = k
                    fly(sw, a.x + side * 0.45 * u, H - 1.2 * u, kk.x, H - 0.9 * unit(kk.spr), 0.8 + d, function() kk.cheer() end)
                end
            end },
            { clip = "idle", dur = 1.5, on_end = function() a.listening = nil; g.resume() end },
            { clip = "turn_side", face = a.dir },
        }
    end
    function a.update(dt, t)
        local frame = run_steps(a, dt)
        if a.dead then return false end
        if not frame then
            if a.listening then a.listening = nil end
            -- on his way: a beggar ahead, sitting in the cold?
            if a.stage < 3 and not a.cold then
                local best, bd
                for _, b in ipairs(others("beggar")) do
                    local d = (b.x - a.x) * a.dir
                    if b.sitting and not b.warm and not b.claimed and d > 0.6 * u and (not bd or d < bd) then best, bd = b, d end
                end
                if best then share(best) end
            end
            if not a.steps[1] then
                a.x = a.x + a.dir * a.v * dt
                if not a.cold then
                    E.walk_out(a, a.x, a.dir, front, { stage = a.stage, sprite = a.spr.name })
                end
                if a.x < -u * 2 or a.x > W + u * 2 then return false end
                frame = clip_frame(a.spr, "walk", t)
            else
                frame = run_steps(a, 0)
            end
        end
        local l = layer(a.spr, frame or 0, a.dir < 0, a.x, H)
        a.cx = a.x
        return true, l.x, l.y, l.frame, l.variant
    end
    a.leave = function() a.cold = true end
    if not h then
        -- a beggar here for him to find (not always: he may walk on to the next screen)
        if #others("beggar") == 0 and math.random() < (el.beggar_chance or 0.7) then
            local bel = beggar_el()
            local bs = bel and E.free_sprite(bel)
            if bs then
                -- he walks in ahead of him and sits down, somewhere along his way
                local b = S.beggar(bel, bs, { sit_x = E.free_x(0.35 * W, 0.75 * W) })
                if b then E.add(b, bel) end
            end
        end
    end
    return a
end

-- ── children ────────────────────────────────────────────────────────────────

local function new_group(id, dir, el)
    local g = { id = id, dir = dir, mode = "walk", met = {}, members = {}, el = el, x0 = 0 }
    function g.alive()
        local out = {}
        for _, k in ipairs(g.members) do if not k.dead and not k.leaving then out[#out + 1] = k end end
        g.members = out
        return out
    end
    function g.singers()
        local out = {}
        for _, k in ipairs(g.alive()) do if k.singing then out[#out + 1] = k end end
        if #out == 0 then out = g.alive() end
        return out
    end
    function g.pick_child(target)
        local best, bd
        for _, k in ipairs(g.alive()) do
            local d = math.abs(k.x - target.x)
            if not k.steps[1] and (not bd or d < bd) then best, bd = k, d end
        end
        return best
    end
    function g.resume()
        if g.mode == "walk" then return end
        g.mode, g.target, g.join = "walk", nil, nil
        for _, k in ipairs(g.alive()) do k.singing = false end
        for _, o in pairs(groups) do           -- (those who joined in)
            if o.join == g then o.resume() end
        end
    end
    function g.start(target, stop_x, join)
        g.mode, g.target, g.stop_x, g.join = "sing", target, stop_x, join
        g.sing_end = join and join.sing_end or nil
        g.x0 = stop_x
        if not join and target.listen then target.listen(g) end
    end
    function g.tick(t)
        if g.last == t then return end
        g.last = t
        local n = now()
        if g.mode == "sing" and g.sing_end and n >= g.sing_end and not g.join then
            g.mode, g.react_t = "react", n
            if g.target and g.target.react and not g.target.dead then g.target.react(g) else g.resume() end
        elseif g.mode == "react" and n - g.react_t > 25 then
            g.resume()
        elseif g.join and (g.join.mode == "walk" or not groups[g.join.id]) then
            g.resume()
        elseif g.mode ~= "walk" and g.target and g.target.dead then
            g.resume()
        end
    end
    groups[id] = g
    return g
end

-- the meetings of a group of children walking along (lead: its first child here): one entry each
S.meet = {
    { who = "martin", chance = 0.5, near = 3.2, stand = 1.5 },     -- St Martin: they sing, he gives sweets
    { who = "beggar", chance = 0.5, near = 3.2, stand = 1.5 },     -- a beggar: they sing, he gets a gift
}

local function lantern_sprite(el, name)
    local M = E.M()
    if name and name ~= "" then return M.sprites[name] end
    local list = el.lanterns or {}
    for _ = 1, 4 do
        local n = list[math.random(math.max(1, #list))]
        if n and M.sprites[n] then return M.sprites[n], n end
    end
end
local GRIP = { 8 / 120, 146 / 150 }      -- the stick's lower end in a carried lantern's frame (lanterns.py)

local function new_kid(el, spr, g, x, lantern)
    local W, H = E.W(), E.H()
    local u = unit(spr)
    local a = { el = el, spr = spr, stm = "kid", steps = {}, tc = 0, g = g, x = x, dir = g.dir, layers = 3, unique = true }
    a.v_own = walk_v(spr)
    a.v = g.v or a.v_own
    a.lantern = lantern
    a.ph = rnd(0, 6.28)
    a.note = E.M().sprites[(el.notes or {})[math.random(math.max(1, #(el.notes or {})))] or ""]
    g.members[#g.members + 1] = a
    function a.cheer() if not a.steps[1] then a.steps = { { clip = "cheer" } } end end
    function a.errand(target, gift, done)      -- walk up to him, put the gift down, skip back
        local back, side = a.x, target.x > a.x and 1 or -1
        a.singing = false
        a.steps = {
            { clip = "walk", walk_to = target.x - side * 0.9 * u, v = a.v_own },
            { clip = "give", face = side, on_end = function()
                local M = E.M()
                local spr_g
                if gift == "lantern" and a.lantern then
                    spr_g = M.sprites[(a.lantern.name or ""):gsub("^carry_", "stand_")]
                    a.lantern = nil
                else
                    spr_g = M.sprites[gift]
                end
                relic(spr_g, target.x - side * 0.55 * u, target)
                if target.thank then target.thank() end
            end },
            { clip = "skip", walk_to = back, v = a.v_own * 1.3 },
            { clip = "turn_side", face = g.dir, on_end = done },
        }
    end
    function a.update(dt, t)
        g.tick(t)
        local W_ = E.W()
        local frame = run_steps(a, dt)
        local clip, k = a.clip, a.k
        if a.dead then return false end
        local ahead, gap
        for _, b in ipairs(g.alive()) do
            local d = (b.x - a.x) * g.dir
            if b ~= a and d > 0 and (not gap or d < gap) then ahead, gap = b, d end
        end
        local spacing = g.spacing or 1.1 * u
        if not frame then
            a.dir = g.dir
            local moving = false
            if g.mode == "walk" then
                moving = not (ahead and gap < spacing and not ahead.leaving)
                if not ahead then         -- the first here: whom does it meet?
                    for _, m in ipairs(S.meet) do
                        for _, b in ipairs(others(m.who)) do
                            local d = (b.x - a.x) * g.dir
                            if not g.met[b] and d > 0 and d < m.near * u and b.can_hear and b.can_hear() then
                                g.met[b] = true
                                if now() < sure_until or math.random() < m.chance then
                                    g.start(b, b.x - g.dir * m.stand * u)
                                end
                            end
                        end
                    end
                    -- others singing just ahead: join in
                    if g.mode == "walk" then
                        for _, o in pairs(groups) do
                            if o ~= g and o.mode == "sing" and not o.join and not g.met[o] then
                                local last
                                for _, kk in ipairs(o.alive()) do
                                    if not last or (kk.x - last.x) * g.dir < 0 then last = kk end
                                end
                                local d = last and (last.x - a.x) * g.dir
                                if d and d > 0 and d < 2.5 * u and o.dir == g.dir then
                                    g.met[o] = true
                                    g.start(o.target, last.x - g.dir * spacing, o)
                                end
                            end
                        end
                    end
                end
            else
                -- sing / react: the first walks to its place, the others close up behind
                if not ahead then
                    local d = (g.stop_x - a.x) * g.dir
                    moving = d > 2
                    if not moving and g.mode == "sing" and not g.sing_end then
                        g.sing_end = now() + rnd(6, 9)
                    end
                else
                    moving = gap > spacing * 1.02 and not ahead.leaving and (ahead.x - a.x) * g.dir > 0
                end
                a.singing = (g.mode == "sing") and not moving and g.sing_end ~= nil
            end
            if moving then
                a.x = a.x + g.dir * a.v * dt
                frame, _, k = clip_frame(spr, "walk", t, false, a.v / a.v_own)
                clip = "walk"
                E.walk_out(a, a.x, g.dir, 0.4 * u, { grp = g.id, lantern = a.lantern and a.lantern.name or "",
                                                       proc = g.proc and 1 or nil, gv = a.v })
                if a.x < -6 * u or a.x > W_ + 6 * u then
                    if (a.x - W_ / 2) * g.dir > 0 then return false end
                end
            elseif a.singing then
                frame, _, k = clip_frame(spr, "sing", t)
                clip = "sing"
            else
                frame, _, k = clip_frame(spr, "idle", t)
                clip = "idle"
            end
        end
        local mirror = a.dir < 0
        local bob = a.singing and math.sin(t * 5 + a.ph) * 0.03 * u or 0
        local L = { layer(spr, frame, mirror, a.x, H, 0, -math.abs(bob)) }
        -- the lantern on its stick, held in the tracked hand
        local c = spr.clips[clip or "idle"]
        local tr = c and c.track and c.track["hand.l"]
        local p = tr and tr[(k or 0) + 1]
        if a.lantern and p then
            local ls = a.lantern
            local hx = mirror and (a.x - p[1]) or (a.x + p[1])
            local hy = H - spr.origin[2] + spr.origin[2] + p[2] - math.abs(bob)
            local gx = GRIP[1] * ls.w
            local lx = mirror and (hx - (ls.w - gx)) or (hx - gx)
            local fr = math.floor(t * 8 + a.ph * 3)
            L[2] = { spr = ls, frame = fr, variant = mirror, x = lx, y = hy - GRIP[2] * ls.h }
        end
        -- a note rising while it sings
        if a.singing and a.note then
            local q = (t * 0.45 + a.ph) % 1
            if q < 0.8 then
                L[3] = { spr = a.note, frame = 0, variant = false,
                         x = a.x + math.sin(t * 2 + a.ph) * 0.15 * u - a.note.w / 2,
                         y = H - 2.2 * u - q * 1.2 * u }
            end
        end
        a.cx = a.x
        return true, L
    end
    return a
end

function S.kid(el, spr, h)
    local W, H = E.W(), E.H()
    local M = E.M()
    if h then           -- come over from next door: its group, here
        local g = groups[h.grp] or new_group(h.grp, h.dir == 1 and 1 or -1, el)
        g.proc = h.proc and true or g.proc
        g.v = tonumber(h.gv) or g.v or walk_v(spr) * 0.85
        local a = new_kid(el, spr, g, 0, lantern_sprite(el, h.lantern))
        a.x = E.walk_in_x(h, a.v, 0.4 * unit(spr))
        a.hops = tonumber(h.hops) or 1
        return a
    end
    local lo, hi = range(el.n, 1)
    local n = math.floor(rnd(lo, hi + 0.999))
    local dir = math.random() < 0.5 and 1 or -1
    local g = new_group(tostring(math.random(1, 1e9)), dir, el)
    g.proc = el.procession
    g.v = walk_v(spr) * (el.speed or 0.85)
    local u = unit(spr)
    g.spacing = (el.spacing or 1.7) * u
    local x = dir > 0 and -0.6 * u or W + 0.6 * u
    local lead = new_kid(el, spr, g, x, lantern_sprite(el))
    local used = { [spr] = true }
    for i = 2, n do
        if E.free_ids() < 3 + 6 then break end
        local s2
        for _ = 1, 10 do
            local s = E.free_sprite(el)
            if s and not used[s] then s2 = s break end
        end
        if not s2 then break end
        used[s2] = true
        local k = new_kid(el, s2, g, x - dir * (i - 1) * g.spacing * rnd(1.0, 1.15), lantern_sprite(el))
        E.add(k, el)
    end
    return lead
end

-- ── preview keys ────────────────────────────────────────────────────────────

local function force(t)
    for _, el in ipairs(E.M() and E.M().elements or {}) do
        if el.type == t and E.elements()[el] then
            E.elements()[el].next, E.elements()[el].force = 0, true
            return el
        end
    end
end

function S.install(api)
    E = api
    S.api = api
    mp.add_forced_key_binding("F5", "stm-martin", function()
        martin_hint = nil
        local bel = beggar_el()
        if bel and #others("beggar") == 0 then
            local bs = E.free_sprite(bel)
            local b = bs and S.beggar(bel, bs, nil)
            if b then E.add(b, bel) end
        end
        force("martin")
    end)
    mp.add_forced_key_binding("F6", "stm-kids", function()
        sure_until = now() + 90
        for _, el in ipairs(E.M() and E.M().elements or {}) do
            if el.type == "kid" and not el.procession and E.elements()[el] then
                E.elements()[el].next, E.elements()[el].force = 0, true
            end
        end
    end)
    mp.add_forced_key_binding("F7", "stm-procession", function()
        sure_until = now() + 90
        for _, el in ipairs(E.M() and E.M().elements or {}) do
            if el.type == "kid" and el.procession and E.elements()[el] then
                E.elements()[el].next, E.elements()[el].force = 0, true
            end
        end
    end)
    mp.add_forced_key_binding("F8", "stm-beggar", function() force("beggar") end)
    E.spawn.kid, E.spawn.martin, E.spawn.beggar = S.kid, S.martin, S.beggar
end

function S.reset() groups = {} end

return S
