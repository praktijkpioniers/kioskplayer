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
-- F7 a procession, F8 a beggar, Shift+F7 a class out of the school (see the school below).

local S = {}
local E                         -- the engine API (see install)
local groups = {}               -- kid groups on this screen, by id
local sure_until = 0            -- (preview) meetings certain till then
local chain_now = nil           -- (preview) Alt+F8: the next robed beggar passing one sitting gives for sure
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

-- a one-off effect at (x, y) (its middle): the sprite's frames over dur, growing by grow (a spark,
-- a flare, a puff of smoke); follow() may move it along
local function fx(spr, x, y, dur, follow)
    if not spr or E.free_ids() < 1 then return end
    local a = { el = { type = "stm_fx", hz = 30, video_min = 0 }, spr = spr, uncounted = true }
    local t = 0
    function a.update(dt)
        t = t + dt
        if t >= dur then return false end
        if follow then x, y = follow(x, y, t) end
        local fr = math.min(spr.frames - 1, math.floor(t / dur * spr.frames))
        return true, x - spr.w / 2, y - spr.h / 2, fr, false
    end
    E.add(a)
end

local function others(stm)
    local list = {}
    for _, b in ipairs(E.actors()) do
        if b.stm == stm and not b.dead and not b.leaving then list[#list + 1] = b end
    end
    return list
end

-- a candle in a paper lantern (not the LED one, not the moon): it can burn, be given away, float up
local function candle(k)
    local n = k.lantern and k.lantern.name or ""
    return n:match("^carry_") and n ~= "carry_moon" and n ~= "carry_led" and not k.moonlit
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
    a.hops = h and tonumber(h.hops) or 0
    local chain = {}
    for _, m in ipairs(S.meet or {}) do if m.who == "chain" then chain = m end end
    -- a.robe: what he has on walking off - "w" the whole mantle, "v"/"h" the half left after giving (V: torn
    -- lengthwise, H: across); he walks off towards a.off and over to the screen next door
    local function walk_clip()
        local c = a.robe == "w" and "walk_w" or a.robe and ("walk_" .. a.robe) or "walk"
        return C[c] and c or (a.robe and "walk_w" or "walk")
    end
    local function go_off(warm, side)
        side = side or (a.x < W / 2 and -1 or 1)
        if warm and not a.robe then a.robe = "w" end
        a.off, a.passed = side, a.passed or {}
        local edge = side < 0 and -u * 1.5 or W + u * 1.5
        a.steps[#a.steps + 1] = { clip = walk_clip(), walk_to = edge, v = a.v * (warm and 1.4 or 1), off = true,
                                  on_end = function() a.dead = true end }
    end
    local function sit_here()
        a.sitting = true
        a.sat_t = now()
    end
    if h and h.seated then
        a.x = tonumber(h.x) or W / 2
        sit_here()
    elseif h and h.robe then            -- (robed, from the screen next door: walking on through)
        a.dir, a.warm, a.robe = h.dir == 1 and 1 or -1, true, h.robe
        a.x = E.walk_in_x(h, a.v * 1.4, 0.4 * u)
        go_off(true, a.dir)
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
        if candle(kid) and math.random() < 0.3 then gifts = { "lantern" } end
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
    function a.receive(side)    -- the piece of cloak: wrapped in it, warm, up and away (side: which way)
        a.warm, a.robe = true, "w"
        -- the miracle: the half he's handed doubles on him into a whole mantle - a glow, sparkles round him
        local function miracle()
            local M = E.M()
            fx(M.sprites.flare, a.x, H - 0.9 * u, 0.9)
            for k = 0, 6 do
                local ang = k * 0.9
                fx(M.sprites.spark, a.x + math.cos(ang) * 0.55 * u, H - (0.6 + 0.35 * math.sin(ang) + 0.1 * k) * u,
                   0.5 + 0.12 * k, function(x, y) return x, y - 0.015 * u end)
            end
        end
        a.steps = { { clip = "reach" }, { clip = "sit_w", dur = rnd(3, 5), on_start = miracle },
                    { clip = "stand_w", on_start = function() a.sitting = false end },
                    { clip = "idle_w" } }
        go_off(true, side)
    end
    -- the chain: walking off robed he passes one sitting in the cold - sometimes (S.meet "chain") he stops,
    -- tears the robe in two with his hands and gives half; on the other it doubles into a whole robe (the
    -- miracle again) and they go off different ways. The second time he gives the last piece and sits down
    -- bare where he is: a beggar again
    local function chain_give(b)
        b.claimed = a
        local side = b.x > a.x and 1 or -1
        local stand = b.x - side * (chain.stand or 1.05) * u
        local last = a.robe ~= "w"
        local k = last and a.robe or (math.random() < 0.5 and "v" or "h")
        local function hand()
            local cl = E.M().sprites.cloth
            fly(cl, a.x + side * 0.45 * u, H - 1.0 * u, b.x, H - 0.7 * u, 0.9, function()
                if not b.dead then b.receive(-a.off) end
            end)
        end
        a.steps = { { clip = walk_clip(), walk_to = stand } }
        if not last then
            a.steps[#a.steps + 1] = { clip = C.tear_w and "tear_w" or "idle_w", face = side, on_end = function()
                a.robe = k
                fx(E.M().sprites.spark, a.x + side * 0.3 * u, H - 0.9 * u, 0.4)
            end }
        end
        a.steps[#a.steps + 1] = { clip = C["give_" .. k] and "give_" .. k or "reach", face = side,
                                  on_start = last and hand or nil, on_end = (not last) and hand or nil }
        if last then
            a.steps[#a.steps + 1] = { clip = C.give_0 and "give_0" or "idle", reverse = true, on_start = function() a.robe = nil end }
            a.steps[#a.steps + 1] = { clip = "sit_down", on_end = function()
                a.warm, a.off, a.claimed, a.listening = false, nil, nil, nil
                a.ttl = rnd(range(el.stay, 150))
                sit_here()
            end }
        else
            go_off(true, a.off)
        end
    end
    function a.update(dt, t)
        local s1 = a.steps[1]
        if a.robe and a.off and s1 and s1.off then
            -- walking off robed: one sitting in the cold just ahead?
            for _, b in ipairs(others("beggar")) do
                local d = (b.x - a.x) * a.off
                if b ~= a and not a.passed[b] and b.sitting and not b.warm and not b.claimed and not b.listening
                    and not b.steps[1] and d > 1.2 * u and d < (chain.near or 3) * u then
                    a.passed[b] = true
                    if chain_now or math.random() < (chain.chance or 0.4) then
                        chain_now = nil
                        chain_give(b)
                        break
                    end
                end
            end
            if a.steps[1] == s1 then E.walk_out(a, a.x, a.off, 0.4 * u, { robe = a.robe }) end
        end
        if a.claimed and (a.claimed.dead or (a.sat_t and now() - a.sat_t > a.ttl + 90)) then a.claimed = nil end
        local frame = run_steps(a, dt)
        local mirror = a.dir < 0
        local dx = 0
        if not frame then
            if a.sitting then
                frame = clip_frame(spr, a.warm and "sit_w" or "sit", t)
                if not a.warm then dx = (math.floor(t * 14) % 2) * 2 - 1 end      -- shivering
                if now() - a.sat_t > a.ttl and ((not a.claimed and not a.listening) or now() - a.sat_t > a.ttl + 90) then
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

-- el.looks = { v1 = {stage sprites}, A = {...}, ... } and el.look picks one (theme.json: a one-line switch);
-- without them el.stages
local LOOK_ORDER = { "v1", "A", "B", "C", "D" }
local function stage_sprite(el, s)
    local names = (el.looks and el.looks[el.look or ""]) or el.stages or {}
    return E.M().sprites[names[s + 1] or ""]
end
S.stage_sprite = stage_sprite         -- (stm_extra.lua: the sprite for a stage, in the chosen look)

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
            if not k.steps[1] and not k.teacher and (not bd or d < bd) then best, bd = k, d end
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
        elseif g.mode == "react" and n - g.react_t > 10 then   -- (nobody idles long: walk on)
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
    -- a child with an unlit lantern meets one whose lantern is lit (any child just ahead, going the same
    -- way): they hold the lanterns together and a spark jumps across (usual), or POOF - a flare, smoke,
    -- two sooty faces, a laugh (poof), or the lit one goes out as the other lights (swap: it runs after)
    -- a beggar walking off in his robe passes one sitting in the cold: he tears it and gives half (the chain)
    { who = "chain", chance = 0.4, near = 3.0, stand = 1.05 },
    { who = "light", chance = 0.8, near = 3.8, stand = 2.1, poof = 0.2, swap = 0.1 },
}
local function meet_cfg(who)
    for _, m in ipairs(S.meet) do if m.who == who then return m end end
    return {}
end

local force_unlit = false        -- (preview) the next group: one child with an unlit lantern
local force_bare = false         -- (preview) the next group: one child with a bare stick (the moon comes to it)
local force_fire = false         -- (preview) the next child crossing the middle: its lantern catches fire
local force_led = false          -- (preview) the next group: one child with an LED lantern, and it dies
local function lantern_sprite(el, name, unlit)
    local M = E.M()
    if name and name ~= "" then return M.sprites[name] end
    local list = el.lanterns or {}
    for _ = 1, 4 do
        local n = list[math.random(math.max(1, #list))]
        if unlit and n then
            local un = n:gsub("^carry_", "unlit_")
            if M.sprites[un] then return M.sprites[un], un end
        end
        if n and M.sprites[n] then return M.sprites[n], n end
    end
end
local GRIP = { 8 / 220, 185 / 195 }      -- the stick's lower end in a carried lantern's frame (lanterns.py)
local LC = { 120 / 220, 98 / 195 }       -- the lantern's middle in that frame

local function new_kid(el, spr, g, x, lantern)
    local W, H = E.W(), E.H()
    local u = unit(spr)
    local a = { el = el, spr = spr, stm = "kid", steps = {}, tc = 0, g = g, x = x, dir = g.dir, layers = 3, unique = true }
    a.v_own = walk_v(spr)
    a.v = g.v or a.v_own
    a.lantern = lantern
    a.unlit = lantern and (lantern.name or ""):match("^unlit_") and true or nil
    a.bare = lantern and lantern.name == "stick" or nil
    a.ph = rnd(0, 6.28)
    a.note = E.M().sprites[(el.notes or {})[math.random(math.max(1, #(el.notes or {})))] or ""]
    for _, n in ipairs(el.teachers or {}) do if spr.name == n then a.teacher = true end end     -- (the juf, the meester)
    g.members[#g.members + 1] = a
    function a.cheer() if not a.steps[1] then a.steps = { { clip = "cheer" } } end end
    function a.lightless() return a.unlit or a.bare or a.dead_led or not a.lantern end
    function a.set_lit(on)            -- light the lantern (carry_*) or let it go out (unlit_*)
        local nm = a.lantern and a.lantern.name or ""
        local base = nm:gsub("^carry_", ""):gsub("^unlit_", "")
        local sp = E.M().sprites[(on and "carry_" or "unlit_") .. base]
        if sp then a.lantern, a.unlit = sp, (not on) or nil end
    end
    -- where its lantern is now (the middle of it), from the last frame drawn
    function a.lantern_at() return a.lc_x or a.x + a.dir * 1.1 * u, a.lc_y or E.H() - 1.9 * u end
    -- the lighting: a (unlit) and b (lit) face each other, lanterns together; then one of the three endings
    local function light_from(b)
        local m = meet_cfg("light")
        local ga, gb = g, b.g
        for _, gg in ipairs({ ga, gb }) do if gg.mode == "walk" then gg.mode = "light" end end
        local side = b.x > a.x and 1 or -1
        local stand = (m.stand or 2.1) * u
        local r = math.random()
        local ending = (r < (m.swap or 0.1)) and "swap" or (r < (m.swap or 0.1) + (m.poof or 0.2)) and "poof" or "spark"
        local done_n = 0
        local function done()
            done_n = done_n + 1
            if done_n < 2 then return end
            for _, gg in ipairs({ ga, gb }) do if gg.mode == "light" then gg.mode = "walk" end end
        end
        local M = E.M()
        local function spark_over(from, to, after)
            local x0, y0 = from.lantern_at()
            local x1, y1 = to.lantern_at()
            fly(M.sprites.spark, x0, y0, x1, y1, 0.55, after)
        end
        b.steps = { { clip = "turn_front", face = -side }, { clip = "idle", wait = function() return a.lit_done end } }
        a.steps = {
            { clip = "walk", walk_to = b.x - side * stand, v = a.v_own * 0.8 },
            { clip = "turn_front", face = side },
            { clip = "idle", dur = 0.8 },
        }
        if ending == "spark" then
            a.steps[#a.steps + 1] = { clip = "idle", wait = function() return a.lit_done end, on_start = function()
                spark_over(b, a, function() a.set_lit(true); a.lit_done = true end)
            end }
            a.steps[#a.steps + 1] = { clip = "cheer", on_start = function() b.steps = { { clip = "cheer", on_end = done } } end }
            a.steps[#a.steps + 1] = { clip = "turn_side", face = g.dir, on_end = done }
        elseif ending == "poof" then
            a.steps[#a.steps + 1] = { clip = "idle", dur = 1.6, on_start = function()
                local lx, ly = a.lantern_at()
                fx(M.sprites.flare, lx, ly, 0.5)
                fx(M.sprites.puff, lx, ly - 0.3 * u, 1.6, function(x, y, t) return x, y - 0.02 * u end)
                a.set_lit(true)
                a.soot_until, b.soot_until = now() + 5, now() + 5
                a.lit_done = true
            end }
            a.steps[#a.steps + 1] = { clip = "idle", dur = 0.8 }                -- (blink)
            a.steps[#a.steps + 1] = { clip = "cheer", on_start = function() b.steps = { { clip = "idle", dur = 0.3 }, { clip = "cheer", on_end = done } } end }
            a.steps[#a.steps + 1] = { clip = "turn_side", face = g.dir, on_end = done }
        else    -- swap: b's goes out as a's lights; b looks at it, then runs after a
            a.steps[#a.steps + 1] = { clip = "idle", wait = function() return a.lit_done end, on_start = function()
                spark_over(b, a, function() a.set_lit(true); b.set_lit(false); a.lit_done = true end)
            end }
            a.steps[#a.steps + 1] = { clip = "cheer" }
            a.steps[#a.steps + 1] = { clip = "turn_side", face = g.dir, on_end = function()
                done()
                b.steps = { { clip = "idle", dur = 1.4 }, { clip = "turn_side", face = gb.dir },
                            { clip = "skip", walk_to = a.x + gb.dir * 0.2 * u, v = b.v_own * 1.4, on_end = function() b.tried = nil; done() end } }
            end }
        end
    end
    -- an unlit child walking along: a lit one just ahead (or just behind) going the same way?
    local function look_for_light()
        if a.tried and now() < a.tried then return end
        a.tried = now() + 4
        local m = meet_cfg("light")
        local best, bd
        for _, b in ipairs(others("kid")) do
            local d = math.abs(b.x - a.x)
            if b ~= a and b.lantern and not b.unlit and not b.steps[1] and b.g and b.g.dir == g.dir
               and (b.g.mode == "walk") and d < (m.near or 3.8) * u and d > 0.5 * u and (not bd or d < bd) then
                best, bd = b, d
            end
        end
        if best and (now() < sure_until or math.random() < (m.chance or 0.8)) then
            a.lit_done = nil
            light_from(best)
        end
    end
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
    -- ── a lantern's little disasters: the candle sets the paper on fire; the LED one dies ──
    local function stop_group()
        local was = g.mode
        if was == "walk" then g.mode = "light" end       -- (the group waits, as for a lighting)
        return was
    end
    local function go_on(was) if was == "walk" and g.mode == "light" then g.mode = "walk" end end
    function a.on_fire()
        local M = E.M()
        local burn = M.sprites[el.burn or "burn"]
        if not (burn and M.sprites.stick) then return false end
        local was = stop_group()
        a.steps = {
            { clip = "idle", dur = 0.3, on_start = function() a.lantern, a.lfr0 = burn, now() end },
            { clip = "turn_front", face = a.dir },
            { clip = "idle", dur = burn.frames / 4 + 0.2, on_end = function()
                local lx, ly = a.lantern_at()
                a.lantern, a.lfr0, a.bare = M.sprites.stick, nil, true
                relic(M.sprites.ash, lx, a)
                fx(M.sprites.puff, lx, ly, 1.2)
            end },
            { clip = "idle", dur = 1.6 },                  -- (looks at the bare stick)
        }
        -- the nearest one in the group brings a new lantern
        local giver
        for _, b in ipairs(g.alive()) do
            if b ~= a and not b.steps[1] and b.lantern and not b.lightless() and
               (not giver or math.abs(b.x - a.x) < math.abs(giver.x - a.x)) then giver = b end
        end
        if giver then
            local back, side = giver.x, a.x > giver.x and 1 or -1
            local nm
            for _ = 1, 6 do
                local c = (el.lanterns or {})[math.random(math.max(1, #(el.lanterns or {})))]
                if c and c ~= "carry_led" and M.sprites[c] then nm = c break end
            end
            nm = nm or (a.lantern and a.lantern.name)
            giver.steps = {
                { clip = "idle", wait = function() return a.bare end },
                { clip = "idle", dur = 0.8 },
                { clip = "walk", walk_to = a.x - side * 0.9 * u, v = giver.v_own },
                { clip = "give", face = side, on_start = function()
                    local loose = M.sprites["loose_" .. (nm or ""):gsub("^carry_", "")]
                    local lx, ly = a.lantern_at()
                    fly(loose, giver.x + side * 0.5 * u, H - 1.3 * u, lx, ly, 0.7, function()
                        if M.sprites[nm] then a.lantern, a.bare = M.sprites[nm], nil end
                    end)
                end },
                { clip = "skip", walk_to = back, v = giver.v_own * 1.3 },
                { clip = "turn_side", face = g.dir },
            }
            a.steps[#a.steps + 1] = { clip = "idle", wait = function() return not a.bare or not giver.steps[1] end }
            a.steps[#a.steps + 1] = { clip = "cheer" }
        end
        a.steps[#a.steps + 1] = { clip = "turn_side", face = g.dir, on_end = function() go_on(was) end }
        return true
    end
    function a.led_dies()
        local M = E.M()
        local off = M.sprites[el.led_off or "led_off"]
        if not off then return false end
        local was = stop_group()
        a.led_on = a.lantern
        local back_on = math.random() < (el.led_back or 0.8)
        a.steps = {
            { clip = "idle", dur = 0.25, on_start = function() a.lantern = off end },
            { clip = "turn_front", face = a.dir },
            { clip = "idle", dur = 1.0 },                  -- (looks at it)
            { clip = "cheer", rate = 1.8, on_start = function() a.shake_t = now() end },     -- (shakes it)
            { clip = "cheer", rate = 1.8, on_end = function()
                a.shake_t = nil
                if back_on then a.lantern = a.led_on else a.dead_led = true end
            end },
            { clip = back_on and "cheer" or "idle", dur = back_on and nil or 1.2 },
            { clip = "turn_side", face = g.dir, on_end = function() go_on(was) end },
        }
        return true
    end
    function a.update(dt, t)
        g.tick(t)
        local W_ = E.W()
        local frame = run_steps(a, dt)
        if a.chasing then          -- after the moon that got away: off to the next screen, the moon caught there
            E.walk_out(a, a.x, a.chasing, 0.4 * u, { grp = g.id, lantern = "carry_moon", proc = g.proc and 1 or nil, gv = a.v })
            if a.x < -4 * u or a.x > W_ + 4 * u then return false end
        end
        if not frame and a.unlit and g.mode == "walk" and a.x > 0 and a.x < W_ then
            look_for_light()
            frame = run_steps(a, 0)
        end
        if not frame and not a.gag_done and g.mode == "walk" and a.x > 0.25 * W_ and a.x < 0.75 * W_ then
            a.gag_done = true                             -- (once a screen: the candle may catch fire, the LED die)
            local nm = a.lantern and a.lantern.name or ""
            if nm == "carry_led" then
                if (force_led or math.random() < (el.led_dies or 0.5)) and a.led_dies() then force_led = false end
            elseif candle(a) and (force_fire or math.random() < (el.fire or 0.03)) then
                if a.on_fire() then force_fire = false end
            end
            frame = run_steps(a, 0)
        end
        if a.shake_t then           -- (the LED lantern being shaken: it flickers)
            a.lantern = (math.floor((now() - a.shake_t) * 9) % 3 == 1) and a.led_on or E.M().sprites[el.led_off or "led_off"]
        end
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
            elseif g.mode == "light" then
                moving, a.singing = false, false            -- (two of them lighting a lantern: wait)
            else
                -- sing / react: the first walks to its place, the others close up behind
                if not g.stop_x then
                    g.resume()                              -- (handed over mid-song: no place here, walk on)
                elseif not ahead then
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
                                                       proc = g.proc and 1 or nil, gv = a.v, cls = g.cls and 1 or nil,
                                                       sp = g.spacing and g.spacing / E.H() or nil })
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
            local fr = a.lfr0 and math.min(ls.frames - 1, math.floor((now() - a.lfr0) * 4)) or math.floor(t * 8 + a.ph * 3)
            L[2] = { spr = ls, frame = fr, variant = mirror, x = lx, y = hy - GRIP[2] * ls.h }
            a.lc_x = mirror and (lx + ls.w * (1 - LC[1])) or (lx + ls.w * LC[1])
            a.lc_y = hy - GRIP[2] * ls.h + ls.h * LC[2]
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
        -- soot and frizzy hair (the POOF)
        if a.soot_until and now() < a.soot_until then
            local so = E.M().sprites.soot
            if so then
                local hx = a.x + (mirror and -1 or 1) * 0.12 * u
                L[3] = { spr = so, frame = 0, variant = mirror, x = hx - so.w / 2, y = H - 1.95 * u - so.h / 2 }
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
        g.cls = h.cls and true or g.cls               -- (a class on its lantern walk: goes into a school it passes)
        g.spacing = g.spacing or (tonumber(h.sp) and tonumber(h.sp) * H)
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
    if force_unlit then n = math.max(n, 2) end
    local unl = {}
    for i = 1, n do unl[i] = math.random() < (el.unlit or 1 / 6) end
    if force_unlit then for i = 1, n do unl[i] = (i == 2) end; force_unlit = false end
    local bare_i = force_bare and 2 or nil
    local led_i = force_led and 2 or nil
    if force_led then n = math.max(n, 2) end
    if force_bare then n, force_bare = math.max(n, 2), false end
    local lead = new_kid(el, spr, g, x, lantern_sprite(el, nil, unl[1]))
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
        local k = new_kid(el, s2, g, x - dir * (i - 1) * g.spacing * rnd(1.0, 1.15),
                          i == bare_i and M.sprites.stick or (i == led_i and M.sprites.carry_led) or lantern_sprite(el, nil, unl[i]))
        E.add(k, el)
    end
    return lead
end

-- ── the moon: a lantern up there ────────────────────────────────────────────
-- In the sky (top left) for a while; then, a child without a light about, it comes down to the child's
-- stick: sinking slowly, shrinking and warming, or coming loose and bouncing across the sky - the child
-- runs after it, jumps and catches it (now and then it slips past: off to the next screen after it).
-- The sky is empty a while (el.moonless); then a child's lantern slips off its stick, flies up wobbling,
-- grows and pales and is the moon. One moon in the room (it claims spr:moon). Sprites: moon (the sky),
-- moonfly (8 sizes: 0 lantern-size warm .. 7 the full moon), carry_moon (on a stick), stick, loose_*.

local moon_gone_t, moonless = nil, 45      -- (this screen) when the moon last came down; how long the sky stays empty
local moon_now = nil                        -- (preview) Ctrl+F5: down now; Ctrl+F6: up now

local function moon_spot(el)
    local W, H = E.W(), E.H()
    local sp = E.M().sprites[el.sprite or "moon"]
    local p = (el.places or { { 0.03, 0.04 } })[1]
    return p[1] * W + (sp and sp.w or 0) / 2, p[2] * H + (sp and sp.h or 0) / 2
end
local function ease(s) return s * s * (3 - 2 * s) end

local function kids_where(test)
    local W = E.W()
    local out = {}
    for _, k in ipairs(others("kid")) do
        if k.x > 0.12 * W and k.x < 0.88 * W and not k.steps[1] and not k.chasing and not k.teacher and k.g and k.g.mode == "walk" and test(k) then
            out[#out + 1] = k
        end
    end
    return out
end

function S.moon(el, spr, h)
    local W, H = E.W(), E.H()
    local M = E.M()
    local sky = M.sprites[el.sprite or "moon"]
    local mfly = M.sprites[el.fly or "moonfly"]
    if not sky then return nil end
    if #others("moon") > 0 then return nil end
    local a = { el = el, spr = sky, stm = "moon", layers = 1, unique = true }
    local sx, sy = moon_spot(el)
    local st, t0 = "sky", now()
    local lo, hi = range(el.stay, 150)
    local sky_until = now() + rnd(lo, hi)
    local x, y, show, frame = sx, sy, sky, 0
    local kid, path                -- the child it goes to / comes from; the way it goes
    if moon_gone_t then
        -- the sky's been empty: a child's lantern goes up to be the moon (no child with a light: not yet)
        if moon_now ~= "up" and now() - moon_gone_t < moonless then return nil end
        local ks = kids_where(function(k) return candle(k) and not k.lightless() end)
        if #ks == 0 then return nil end
        kid = ks[math.random(#ks)]
        moon_now = nil
        st = "slip"
        local u = unit(kid.spr)
        kid.steps = { { clip = "idle", dur = 0.35 },
                      { clip = "cheer", rate = 1.6, on_start = function()        -- (swings it too hard)
                          local lx, ly = kid.lantern_at()
                          local base = (kid.lantern.name or ""):gsub("^carry_", "")
                          a.loose = M.sprites["loose_" .. base]
                          path = { x0 = lx, y0 = ly, t0 = now(), dur = rnd(7, 9) }
                          kid.lantern, kid.bare = M.sprites[el.stick or "stick"], true
                          st = "rise"
                      end },
                      { clip = "turn_front", face = kid.dir }, { clip = "idle", dur = 2.5 },     -- (looks up after it)
                      { clip = "turn_side", face = kid.g.dir } }
        x, y = kid.lantern_at()
    end
    moon_gone_t = nil

    local function land_on(k)          -- the moon on the child's stick: its lantern now
        local cm = M.sprites[el.carry or "carry_moon"]
        if cm then k.lantern, k.unlit, k.bare, k.moonlit = cm, nil, nil, true end
        moon_gone_t = now()
        local mlo, mhi = range(el.moonless, 45)
        moonless = rnd(mlo, mhi)
    end
    local function go_down()
        local ks = kids_where(function(k) return k.lightless() end)
        if #ks == 0 then return false end
        kid = ks[math.random(#ks)]
        moon_now = nil
        local u = unit(kid.spr)
        if math.random() < (el.loose or 0.4) then
            -- it comes loose: wobbles, drops, bounces across the sky; the child runs under it and jumps
            st = "loose"
            local miss = math.random() < (el.miss or 0.15)
            local dir = kid.g.dir
            local cx = math.max(0.2 * W, math.min(0.8 * W, kid.x + dir * rnd(2.5, 5) * u))
            path = { x0 = x, y0 = y, t0 = now(), dur = rnd(5, 6.5), cx = cx, miss = miss, dir = dir }
            local lx = cx + dir * 1.1 * u                              -- (where its lantern will be)
            path.lx, path.ly = lx, H - 1.9 * u
            kid.steps = {
                { clip = "turn_front", face = kid.dir }, { clip = "idle", dur = 0.6 },         -- (look! the moon)
                { clip = "skip", walk_to = cx, v = kid.v_own * 1.5, face = dir },
                { clip = "idle", wait = function() return st ~= "loose" or now() - path.t0 > path.dur * 0.86 end },
                { clip = "cheer", rate = 1.3 },                                                -- (the jump, stick up)
            }
            if not miss then
                for _, s2 in ipairs({ { clip = "turn_front", face = -dir }, { clip = "turn_side", face = -dir },
                                      { clip = "turn_front", face = dir }, { clip = "turn_side", face = dir } }) do
                    kid.steps[#kid.steps + 1] = s2                  -- (a happy little spin)
                end
            end
        else
            st = "sink"
            path = { x0 = x, y0 = y, t0 = now(), dur = rnd(8, 11) }
        end
        return true
    end

    function a.update(dt, t)
        local n = now()
        if st == "sky" then
            x, y, show, frame = sx, sy, sky, 0
            if (n > sky_until or moon_now == "down") and n - t0 > 3 then
                if not go_down() then sky_until = n + rnd(10, 20) end
            end
            if moon_now == "up" then           -- (preview: the sky empties at once for the other way round)
                moon_gone_t, moonless, moon_now = n - 999, 0, "up"
                return false
            end
        elseif st == "slip" then               -- (the child about to swing it off)
            if kid.dead or not path and not kid.steps[1] then return false end
            return true, {}
        elseif st == "rise" then
            local s = math.min(1, (n - path.t0) / path.dur)
            local e = 1 - (1 - s) * (1 - s)        -- (quick off the stick, calming)
            local wob = (1 - s) * (1 - s)
            x = path.x0 + (sx - path.x0) * e + math.sin(n * 7.5) * 0.05 * H * wob
            y = path.y0 + (sy - path.y0) * e + math.sin(n * 11) * 0.02 * H * wob
            if s < 0.4 and a.loose then show, frame = a.loose, 0
            else show, frame = mfly, math.min(7, math.floor((s - 0.4) / 0.6 * 8)) end
            if s >= 1 then st, sky_until, t0 = "sky", n + rnd(lo, hi), n end
        elseif st == "sink" then
            if kid.dead or kid.leaving then st, path = "back", { x0 = x, y0 = y, t0 = n, dur = 5 } return true, {} end
            local s = math.min(1, (n - path.t0) / path.dur)
            local e = ease(s)
            local tx, ty = kid.lantern_at()
            x = path.x0 + (tx - path.x0) * e + math.sin(n * 1.3) * 0.02 * H * (1 - s)
            y = path.y0 + (ty - path.y0) * e
            show, frame = mfly, 7 - math.min(7, math.floor(s * 8))
            if s >= 1 then
                land_on(kid)
                kid.steps = { { clip = "cheer" }, { clip = "turn_side", face = kid.g.dir } }
                return false
            end
        elseif st == "back" then
            local s = math.min(1, (n - path.t0) / path.dur)
            x, y = path.x0 + (sx - path.x0) * ease(s), path.y0 + (sy - path.y0) * ease(s)
            show, frame = mfly, math.min(7, math.floor(s * 8))
            if s >= 1 then st, sky_until = "sky", n + rnd(20, 40) end
        elseif st == "loose" then
            local s = (n - path.t0) / path.dur
            if s < 1 then
                local e = s
                local tx, ty = path.lx, path.ly
                x = path.x0 + (tx - path.x0) * e + math.sin(n * 9) * 0.015 * H
                -- dropping, with bounces off nothing (three hops getting lower)
                local base = path.y0 + (ty - path.y0) * (e ^ 1.4)
                y = base - math.abs(math.sin(3 * math.pi * e)) * 0.12 * H * (1 - e)
                show, frame = mfly, 7 - math.min(5, math.floor(s * 6))
            elseif not path.miss then
                land_on(kid)
                return false
            else                               -- it slips past the stick: skimming off, the child after it
                if not path.gone then
                    path.gone = n
                    kid.steps = { { clip = "skip", walk_to = path.dir > 0 and W + 6 * unit(kid.spr) or -6 * unit(kid.spr), v = kid.v_own * 1.6, face = path.dir } }
                    kid.chasing = path.dir
                end
                x = x + path.dir * 0.35 * W * dt
                y = path.ly - math.abs(math.sin((n - path.gone) * 5)) * 0.06 * H
                show, frame = mfly, 2
                if x < -0.1 * W or x > 1.1 * W then
                    moon_gone_t = now()
                    local mlo, mhi = range(el.moonless, 45)
                    moonless = rnd(mlo, mhi)
                    return false
                end
            end
        end
        if not show then return true, {} end
        return true, { { spr = show, frame = frame, variant = false, x = x - show.w / 2, y = y - show.h / 2 } }
    end
    return a
end

-- ── the church ──────────────────────────────────────────────────────────────
-- A village church stands a while (drawn behind the walkers, like stm_extra's houses). Now and then
-- the bell rings and the door opens: the beggars sitting about get up and go in, out of the cold. Then
-- somebody comes out: St Martin (most likely when there's none in the room), a beggar, a child with a
-- lantern, or the rich man (an element "rich", when there is one). A child may also fetch a beggar
-- and take him to church: they go in together; the child comes out again later.
-- Clips (tools/bake/church.py): idle, bell (loop), open (backwards: shut), opened (loop).

local X2                              -- the engine's extras (ids_low_first)
function S.extras(x) X2 = x end
local church_now, church_until = nil, 0    -- (preview) Shift+F8: the service now; Ctrl+F8: a child fetches a beggar

local function el_of(t)
    for _, e in ipairs(E.M().elements) do if e.type == t and E.elements()[e] then return e end end
end

local function free_beggars()
    local out = {}
    for _, b in ipairs(others("beggar")) do
        if b.sitting and not b.warm and not b.claimed and not b.listening and not b.steps[1] then out[#out + 1] = b end
    end
    return out
end

-- somebody coming out of the door at x, walking towards dir
local function come_out(x, dir, kid_back)
    local W = E.W()
    local room = E.room()
    if kid_back then
        local kel = kid_back.el
        local k = S.kid(kel, kid_back.spr, { grp = tostring(math.random(1, 1e9)), dir = dir, at = x,
                                             lantern = kid_back.lantern })
        if k and E.add(k, kel) then mp.msg.info("[church] out: the child again") return end
    end
    local opts = {}
    local mel, bel, kel, rel = el_of("martin"), beggar_el(), el_of("kid"), el_of("rich")
    local no_martin = not room.taken["chr:martin"] and #others("martin") == 0
    if mel and no_martin then opts[#opts + 1] = { "martin", 5 } end
    if bel then opts[#opts + 1] = { "beggar", 1.5 } end
    if kel then opts[#opts + 1] = { "kid", 1.5 } end
    if rel and E.spawn.rich then opts[#opts + 1] = { "rich", 1.5 } end
    local sum = 0
    for _, o in ipairs(opts) do sum = sum + o[2] end
    local r, who = math.random() * sum, nil
    for _, o in ipairs(opts) do r = r - o[2]; if r <= 0 then who = o[1] break end end
    mp.msg.info("[church] out: " .. tostring(who))
    if who == "martin" then
        local m = S.martin(mel, nil, { at = x, dir = dir, stage = 0 })
        if m then E.add(m, mel) end
    elseif who == "beggar" then
        local bs = E.free_sprite(bel)
        local sit_x = math.max(0.12 * W, math.min(0.88 * W, x + dir * rnd(0.15, 0.3) * W))
        local b = bs and S.beggar(bel, bs, { sit_x = sit_x })
        if b then b.x, b.dir = x, dir; E.add(b, bel) end
    elseif who == "kid" then
        local ks = E.free_sprite(kel)
        local k = ks and S.kid(kel, ks, { grp = tostring(math.random(1, 1e9)), dir = dir, at = x })
        if k then E.add(k, kel) end
    elseif who == "rich" then
        local rs = E.free_sprite(rel)
        local a = rs and E.spawn.rich(rel, rs, { at = x, dir = dir })
        if a then E.add(a, rel) end
    end
end

function S.church(el, spr, h)
    local W, H = E.W(), E.H()
    if not (spr and spr.clips and spr.clips.open and spr.origin) then return nil end
    -- (its own schedule: it is added behind the walkers here, so the engine gets nil back)
    local st = E.elements()[el]
    local forced = st and st.force
    if st then st.force = nil end
    if #others("church") > 0 then
        if forced and not church_now then church_now, church_until = "service", now() + 25 end
        return nil
    end
    if not forced then
        if not el._next then el._next = now() + rnd(range(el.delay, 30)) return nil end
        if now() < el._next then return nil end
    end
    el._next = now() + rnd(range(el.every, 400))
    local x
    for _ = 1, 8 do                  -- (not where a house stands: stm_extra's houses keep clear of it too)
        local cx = E.free_x(0.3 * W, 0.7 * W)
        local clear = true
        for _, b in ipairs(E.actors()) do
            if (b.stm == "house" or b.stm == "school") and not b.dead and math.abs(b.x - cx) < 0.2 * W then clear = false end
        end
        if clear then x = cx break end
    end
    if not x then el._next = now() + 20 return nil end
    local a = { el = el, spr = spr, stm = "church", x = x, cx = x, clip = "idle", tc = 0, rise = 0, t0 = now(),
                ttl = rnd(range(el.stay, 240)), unique = false, backdrop = 3 }     -- (behind everyone: engine restack)
    local u = unit(spr)
    local state, st_t = "idle", now()
    local next_service = now() + rnd(range(el.service, 40))
    local queue = {}                 -- who's going in (they wait at the door till it's open)
    local kid_back                   -- a child who brought a beggar: comes out again
    local function play(name, reverse) a.clip, a.rev, a.tc = name, reverse, 0 end
    local function to_state(s) state, st_t = s, now() end
    a.open_now = false
    -- one going in: walks to the door, waits for it, in
    local function go_in(b, clip_walk, v, then_fn)
        queue[#queue + 1] = b
        b.steps[#b.steps + 1] = { clip = clip_walk, walk_to = a.x + (b.x < a.x and -0.15 or 0.15) * u, v = v }
        b.steps[#b.steps + 1] = { clip = "idle", wait = function() return a.open_now end }
        b.steps[#b.steps + 1] = { clip = clip_walk, walk_to = a.x, v = v * 0.6, on_end = function()
            b.dead = true
            if then_fn then then_fn() end
        end }
    end
    local function call_beggars()
        for _, b in ipairs(free_beggars()) do
            b.claimed, b.sitting = a, false
            b.steps = { { clip = "stand" } }
            go_in(b, "walk", b.v)
        end
    end
    -- a child takes a beggar to church
    function a.fetch()
        local bs = free_beggars()
        local ks = kids_where(function(k) return k.lantern ~= nil end)
        if #bs == 0 or #ks == 0 then return false end
        local b = bs[math.random(#bs)]
        local k = ks[1]
        local bd
        for _, kk in ipairs(ks) do
            local d = math.abs(kk.x - b.x)
            if not bd or d < bd then k, bd = kk, d end
        end
        local ku = unit(k.spr)
        local side = b.x > k.x and 1 or -1
        b.claimed = a
        k.g.met[b] = true
        local v = math.min(b.v, k.v_own)
        k.steps = {
            { clip = "walk", walk_to = b.x - side * 0.9 * ku, v = k.v_own },
            { clip = "give", face = side, on_end = function()          -- (holds out a hand: come along)
                b.sitting = false
                b.steps = { { clip = "stand" } }
                go_in(b, "walk", v)
            end },
            { clip = "idle", dur = clip_len(b.spr, "stand") + 0.2 },
        }
        go_in(k, "walk", v, function() kid_back = { el = k.el, spr = k.spr, lantern = k.lantern and k.lantern.name } end)
        -- (the child keeps a step ahead of him on the way)
        k.steps[4].walk_to = a.x + (b.x < a.x and -0.6 or 0.6) * u
        next_service = math.min(next_service, now() + 1)
        mp.msg.info("[church] fetch")
        return true
    end
    a.leave = function() a.going = true end
    function a.update(dt, t)
        if church_now == "service" and (#free_beggars() > 0 or now() > church_until) then
            church_now = nil
            next_service = math.min(next_service, now())
        elseif church_now == "fetch" and state == "idle" and a.rise >= 1 then
            if a.fetch() or now() > church_until then church_now = nil end
        end
        if a.going then
            a.rise = a.rise - dt / 1.5
            if a.rise <= 0 then a.dead = true return false end
        elseif a.rise < 1 then
            a.rise = math.min(1, a.rise + dt / 1.5)
        elseif state == "idle" and now() - a.t0 > a.ttl and #queue == 0 then
            a.going = true
        end
        -- the service: bell, open, in they go, somebody comes out, shut
        if a.rise >= 1 and not a.going then
            if state == "idle" and now() >= next_service then
                to_state("bell"); play("bell")
                if math.random() < (el.fetch or 0.3) then a.fetch() end
            elseif state == "bell" and now() - st_t > 3 then
                call_beggars()
                to_state("opening"); play("open")
            elseif state == "opening" and a.clip == "opened" then
                a.open_now = true
                to_state("open")
            elseif state == "open" then
                local alive = 0
                for _, b in ipairs(queue) do if not b.dead then alive = alive + 1 end end
                if (alive == 0 and now() - st_t > 3) or now() - st_t > 25 then
                    to_state("out")
                end
            elseif state == "out" and now() - st_t > 2 then
                local dir = math.random() < 0.5 and 1 or -1
                if not kid_back and math.random() < (el.come_out or 0.85) then come_out(a.x, dir, nil) end
                if kid_back then
                    local kb = kid_back
                    kid_back = nil
                    a.kid_out = { at = now() + 1.6, kb = kb }
                end
                to_state("closing")
            elseif state == "closing" and now() - st_t > 3 and not a.kid_out then
                a.open_now, queue = false, {}
                play("open", true)
                to_state("shut")
            elseif state == "shut" and now() - st_t > 1 then
                play("idle")
                to_state("idle")
                next_service = now() + rnd(range(el.service, 40))
            end
            if a.kid_out and now() >= a.kid_out.at then
                local kb = a.kid_out.kb
                a.kid_out = nil
                come_out(a.x, math.random() < 0.5 and 1 or -1, kb)
            end
        end
        a.tc = a.tc + dt
        local frame, done = clip_frame(spr, a.clip, a.tc, a.rev)
        if done and a.clip == "open" and not a.rev then play("opened"); frame = clip_frame(spr, "opened", 0) end
        local l = layer(spr, frame, false, a.x, H, 0, (1 - ease(a.rise)) * spr.h)
        a.clock_at = { a.x, H + (1 - ease(a.rise)) * spr.h }
        return true, l.x, l.y, l.frame, l.variant
    end
    if X2 then X2.ids_low_first(true) end
    local ok = E.add(a, el)
    if X2 then X2.ids_low_first(false) end
    if ok and el.hands and S.clock_hands then S.clock_hands(a, el.hands) end      -- (the real time)
    return nil
end

-- ── the school: a class on its lantern walk ────────────────────────────────
-- Stands a while (el.stay) like the church; after el.out seconds its door opens and a class comes out,
-- the juf or meester in front with the big lantern on a pole (pole_*), the children (the procession's
-- element: its sprites, lanterns and n) after, one by one through the door. They walk off as a
-- procession, on over the screens; a class walking towards a school (its own is behind it) goes in
-- there, one after the other behind the teacher, and the door shuts. Clips (tools/bake/school.py):
-- idle, open (backwards: shut), opened.
local school_now = false             -- (preview) Shift+F7: the class comes out now

local function class_el()
    for _, e in ipairs(E.M().elements) do
        if e.type == "kid" and e.procession and e.teachers and E.elements()[e] then return e end
    end
end

function S.school(el, spr, h)
    local W, H = E.W(), E.H()
    if not (spr and spr.clips and spr.clips.open and spr.origin) then return nil end
    local st = E.elements()[el]
    local forced = st and st.force
    if st then st.force = nil end
    if #others("school") > 0 then
        if forced then school_now = true end
        return nil
    end
    if not forced then
        if not el._next then el._next = now() + rnd(range(el.delay, 30)) return nil end
        if now() < el._next then return nil end
    end
    el._next = now() + rnd(range(el.every, 500))
    local x
    for _ = 1, 8 do                  -- (not where a house or the church stands)
        local cx = E.free_x(0.3 * W, 0.7 * W)
        local clear = true
        for _, b in ipairs(E.actors()) do
            if (b.stm == "house" or b.stm == "church") and not b.dead and math.abs(b.x - cx) < 0.25 * W then clear = false end
        end
        if clear then x = cx break end
    end
    if not x then el._next = now() + 20 return nil end
    local a = { el = el, spr = spr, stm = "school", x = x, cx = x, clip = "idle", tc = 0, rise = 0, t0 = now(),
                ttl = rnd(range(el.stay, 300)), unique = false, backdrop = 3 }
    local state, st_t = "idle", now()
    local out_t = now() + (forced and 3 or rnd(range(el.out, 30)))
    local file = nil                 -- the class coming out: { g, el, left = sprites, lanterns }
    local queue = {}                 -- a class going in
    local function play(name, reverse) a.clip, a.rev, a.tc = name, reverse, 0 end
    local function to_state(s) state, st_t = s, now() end
    a.open_now = false
    a.leave = function() a.going = true end

    -- the class: the teacher (and the pole lantern) and the children, to come out one by one
    local function make_class()
        local cel = class_el()
        if not cel then return false end
        local M = E.M()
        local tspr = E.free_sprite({ sprites = cel.teachers })
        local poles = cel.poles or {}
        local pole = M.sprites[poles[math.random(math.max(1, #poles))] or ""]
        if not (tspr and pole) then return false end
        local lo, hi = range(el.n or cel.n, 4)
        local n = math.floor(rnd(lo, hi + 0.999))
        local dir = math.random() < 0.5 and 1 or -1
        local g = new_group(tostring(math.random(1, 1e9)), dir, cel)
        g.proc, g.cls = true, true
        local ku
        local list, used = {}, { [tspr] = true }
        for _ = 1, n do
            for _ = 1, 10 do
                local s = E.free_sprite(cel)
                if s and not used[s] then used[s] = true list[#list + 1] = s break end
            end
        end
        if #list == 0 then groups[g.id] = nil return false end
        ku = unit(list[1])
        g.v = walk_v(list[1]) * (cel.speed or 0.75)
        g.spacing = (cel.spacing or 3.2) * ku
        file = { g = g, el = cel, queue = { { spr = tspr, lantern = pole } } }
        for _, s in ipairs(list) do file.queue[#file.queue + 1] = { spr = s } end
        mp.msg.info("[school] a class out: " .. tspr.name .. " and " .. #list)
        return true
    end
    -- the next one out of the door, when the one before is a step away
    local function file_out()
        if not file then return end
        local g = file.g
        local last = file.last
        if last and not last.dead and math.abs(last.x - a.x) < g.spacing * 0.9 then return end
        if E.free_ids() < 3 + 2 then file.queue = {} end
        local q = table.remove(file.queue, 1)
        if not q then file = nil return end
        local k = new_kid(file.el, q.spr, g, a.x, q.lantern or lantern_sprite(file.el, nil, math.random() < (file.el.unlit or 0) ))
        k.x = a.x
        if E.add(k, file.el) then file.last = k else k.dead = true end
    end

    -- a class from elsewhere coming along: in it goes, the teacher first
    local function class_coming()
        if state ~= "idle" or file then return end
        for _, k in ipairs(others("kid")) do
            local g = k.g
            local d = g and (a.x - k.x) * g.dir
            if k.teacher and g.cls and g.mode == "walk" and not k.steps[1]
               and d and d > 0.5 * unit(k.spr) and d < 0.45 * W and k.x > 0 and k.x < W then
                g.mode = "school"
                local mem = g.alive()
                table.sort(mem, function(p, q) return (p.x - q.x) * g.dir > 0 end)
                for i, b in ipairs(mem) do
                    local prev = mem[i - 1]
                    local bu = unit(b.spr)
                    b.singing = false
                    b.steps = {
                        { clip = "walk", walk_to = a.x - g.dir * (0.25 * bu + (i - 1) * 1.0 * bu), v = g.v },
                        { clip = "idle", wait = function() return a.open_now and (not prev or prev.dead) end },
                        { clip = "walk", walk_to = a.x, v = g.v, on_end = function() b.dead = true end },
                    }
                    queue[#queue + 1] = b
                end
                mp.msg.info("[school] a class goes in: " .. #mem)
                return true
            end
        end
    end

    function a.update(dt, t)
        if a.going then
            a.rise = a.rise - dt / 1.5
            if a.rise <= 0 then a.dead = true return false end
        elseif a.rise < 1 then
            a.rise = math.min(1, a.rise + dt / 1.5)
        elseif state == "idle" and now() - a.t0 > a.ttl and #queue == 0 and not file then
            a.going = true
        end
        if a.rise >= 1 and not a.going then
            if school_now and state == "idle" then school_now, out_t = false, now() end
            if state == "idle" then
                if class_coming() then
                    to_state("wait_in")
                elseif out_t and now() >= out_t then
                    out_t = nil
                    if make_class() then to_state("opening"); play("open") end
                end
            elseif state == "wait_in" then
                local near = queue[1]
                if not near or near.dead or math.abs(near.x - a.x) < 1.2 * unit(near.spr) or now() - st_t > 30 then
                    to_state("opening"); play("open")
                end
            elseif state == "opening" and a.clip == "opened" then
                a.open_now = true
                to_state("open")
            elseif state == "open" then
                file_out()
                local alive = 0
                for _, b in ipairs(queue) do if not b.dead then alive = alive + 1 end end
                if alive == 0 and not file and now() - st_t > 2.5 then
                    queue = {}
                    a.open_now = false
                    play("open", true)
                    to_state("shut")
                elseif now() - st_t > 60 then        -- (stuck: shut anyway)
                    for _, b in ipairs(queue) do b.dead = true end
                    file, queue = nil, {}
                end
            elseif state == "shut" and now() - st_t > 1 then
                play("idle")
                to_state("idle")
                if not out_t and now() - a.t0 < a.ttl * 0.5 then out_t = now() + rnd(range(el.out, 30)) end
            end
        end
        a.tc = a.tc + dt
        local frame, done = clip_frame(spr, a.clip, a.tc, a.rev)
        if done and a.clip == "open" and not a.rev then play("opened"); frame = clip_frame(spr, "opened", 0) end
        local l = layer(spr, frame, false, a.x, H, 0, (1 - ease(a.rise)) * spr.h)
        return true, l.x, l.y, l.frame, l.variant
    end
    if X2 then X2.ids_low_first(true) end
    E.add(a, el)
    if X2 then X2.ids_low_first(false) end
    return nil
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
    mp.add_forced_key_binding("Alt+F8", "stm-chain", function()             -- a robed beggar passes one sitting
        local bel = beggar_el()
        if not bel then return end
        if #free_beggars() == 0 then
            local bs = E.free_sprite(bel)
            local b = bs and S.beggar(bel, bs, { seated = true, x = E.W() * rnd(0.55, 0.75), dir = -1 })
            if b then E.add(b, bel) end
        end
        chain_now = true
        local bs = E.free_sprite(bel)
        local w = bs and S.beggar(bel, bs, { robe = math.random() < 0.3 and "v" or "w", dir = 1, lead = 0 })
        if w then E.add(w, bel) end
    end)
    mp.add_forced_key_binding("Shift+F6", "stm-light", function()          -- the lighting gag
        sure_until = now() + 60
        force_unlit = true
        for _, el in ipairs(E.M() and E.M().elements or {}) do
            if el.type == "kid" and not el.procession and E.elements()[el] then
                E.elements()[el].next, E.elements()[el].force = 0, true
                break
            end
        end
    end)
    mp.add_forced_key_binding("Ctrl+F5", "stm-moon-down", function()       -- the moon comes down to a child
        moon_now = "down"
        force_bare = true
        for _, el in ipairs(E.M() and E.M().elements or {}) do
            if el.type == "kid" and not el.procession and E.elements()[el] then
                E.elements()[el].next, E.elements()[el].force = 0, true
                break
            end
        end
        force("moon")
    end)
    mp.add_forced_key_binding("Ctrl+F6", "stm-moon-up", function()         -- a lantern goes up to be the moon
        moon_now = "up"
        if #others("moon") == 0 then moon_gone_t, moonless = now() - 999, 0 end
        force("kid")
        force("moon")
    end)
    mp.add_forced_key_binding("Shift+F5", "stm-martin-look", function()      -- cycle St Martin's look, live
        for _, el in ipairs(E.M() and E.M().elements or {}) do
            if el.type == "martin" and el.looks then
                local i = 1
                for k, n in ipairs(LOOK_ORDER) do if n == el.look then i = k end end
                for _ = 1, #LOOK_ORDER do
                    i = i % #LOOK_ORDER + 1
                    if el.looks[LOOK_ORDER[i]] then break end
                end
                el.look = LOOK_ORDER[i]
                for _, a in ipairs(others("martin")) do
                    local sp = stage_sprite(el, a.stage or 0)
                    if sp then a.spr = sp end
                end
                mp.osd_message("St Martin look " .. el.look, 2)
            end
        end
    end)
    mp.add_forced_key_binding("Shift+F8", "stm-church", function()          -- the church: the bell, in they go
        local bel = beggar_el()
        if bel and #free_beggars() == 0 then
            local bs = E.free_sprite(bel)
            local b = bs and S.beggar(bel, bs, nil)
            if b then E.add(b, bel) end
        end
        church_now, church_until = "service", now() + 45      -- (as soon as a beggar sits)
        force("church")
    end)
    mp.add_forced_key_binding("Ctrl+F8", "stm-church-fetch", function()     -- a child takes a beggar to church
        local bel = beggar_el()
        if bel and #free_beggars() == 0 then
            local bs = E.free_sprite(bel)
            local b = bs and S.beggar(bel, bs, nil)
            if b then E.add(b, bel) end
        end
        church_now, church_until = "fetch", now() + 60
        force("kid")
        force("church")
    end)
    mp.add_forced_key_binding("Shift+F7", "stm-school", function()         -- a class comes out of the school
        if #others("school") > 0 then school_now = true else force("school") end
    end)
    mp.add_forced_key_binding("Ctrl+F7", "stm-fire", function()             -- a lantern catches fire
        force_fire = true
        force("kid")
    end)
    mp.add_forced_key_binding("Alt+F7", "stm-led", function()               -- an LED lantern dies, is shaken
        force_led = true
        force("kid")
    end)
    E.spawn.kid, E.spawn.martin, E.spawn.beggar, E.spawn.moon = S.kid, S.martin, S.beggar, S.moon
    E.spawn.church = S.church
    E.spawn.school = S.school
end

function S.reset() groups = {} end

return S
