-- Prowler: a black cat strolls along the bottom edge of the screen. It stops now and then to
-- look around, sits down halfway to lick a paw and wash, sharpens its claws on a pumpkin that
-- stands in its way, and walks off (sometimes back the way it came). Solid things (pumpkins,
-- tombstones, the coffin: sprites with a "profile") it walks over: small steps it just takes,
-- higher ones it jumps up onto and down from; if the thing under it goes away, it drops down. Drawn as ASS vectors from
-- a small skeleton (body line, two-bone legs, tail chain), so every pose is computed, not baked.
-- Loaded by engine.lua.
--
-- Units: u = a hundredth of the screen height (× size). Local frame: x forward (the way the cat
-- faces), y down, 0 = the ground, hip at x = 0. Note: ASS draws below overlay bitmaps, so the cat
-- passes behind pumpkins (and its claws disappear into them while scratching).

local C = {}
C.__index = C

local pi, sin, cos, sqrt, floor = math.pi, math.sin, math.cos, math.sqrt, math.floor
local atan2 = math.atan2 or math.atan
local function rnd(a, b) return a + math.random() * (b - a) end
local function ease(p) return p * p * (3 - 2 * p) end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

-- colours (&HBBGGRR&)
local FUR, FUR_FAR = "&H261C17&", "&H3A322D&"           -- blue-black, the far legs a shade lighter
local RIM, SHEEN = "&H6E6058&", "&HC8B4A4&"             -- thin cool outline; moonlight along the top
local EYE, PUPIL, PINK, WHISKER = "&H3CE8BE&", "&H0A0A0A&", "&H9C8CE6&", "&HC8C8C8&"
local EAR_IN, GLINT, FANG = "&H5C4A66&", "&HFFFFFF&", "&HF0F0F0&"
local RED_EYE = "&H1010F0&"

-- body measures (u)
local FL1, FL2 = 2.9, 3.2            -- front leg: upper arm, forearm (to the wrist)
local HL1, HL2, HL3 = 2.8, 2.8, 1.9  -- hind leg: thigh, shin, foot (hock to toes)
local TAIL_N, TAIL_SEG = 15, 0.8
local STRIDE, DUTY = 4.4, 0.62
local CLIMB, MAX_UP = 3, 22          -- steps up to this it walks; jumps no higher than that

-- poses: only the keys a pose sets are tweened
local STAND = { hh = 6.8, ba = 0.03, bl = 8.0, nx = 2.5, ny = -2.5, hp = 0, fold = 0 }
local SIT   = { hh = 2.6, ba = 1.0, bl = 6.0, nx = 0.9, ny = -2.6, hp = 0, fold = 1,
                ta = 1.75, tk = -0.1, tc = -0.02, tw = 0.04 }
-- a fright (the werewolf): up on its toes, the back arched high, the tail up and bristling, red
-- eyes, hissing
local ARCH = { hh = 8.0, ba = -0.08, bl = 7.4, nx = 2.5, ny = -1.0, hp = 0.15, fold = 0, arch = 1, red = 1, hiss = 1,
               ta = -1.75, tk = 0.012, tc = 0.002, tw = 0.03, bristle = 1 }
local SCRATCH = { hh = 6.9, ba = 0.95, bl = 7.8, nx = 1.5, ny = -2.4, hp = -0.1, fold = 0,
                  ta = -1.75, tk = -0.06, tc = 0.03, tw = 0.25 }
local TAILS = {
    { ta = -2.5, tk = 0.11, tc = 0.03, tw = 0.14 },     -- up, an S, the tip curled like a question mark
    { ta = 2.65, tk = 0.06, tc = 0.012, tw = 0.12 },    -- low swoop, rising at the end
}

local function shoulder(p)
    return p.bl * cos(p.ba), -p.hh - p.bl * sin(p.ba)
end

-- two-bone IK: joint between root a and target t; side +1 bends the joint forward (+x)
local function ik(ax, ay, tx, ty, l1, l2, side)
    local dx, dy = tx - ax, ty - ay
    local d = clamp(sqrt(dx * dx + dy * dy), 0.01, l1 + l2 - 1e-3)
    local a = atan2(dy, dx)
    local c = clamp((l1 * l1 + d * d - l2 * l2) / (2 * l1 * d), -1, 1)
    local al = math.acos(c)
    local j1x, j1y = ax + l1 * cos(a + al), ay + l1 * sin(a + al)
    local j2x, j2y = ax + l1 * cos(a - al), ay + l1 * sin(a - al)
    if (j1x - j2x) * side >= 0 then return j1x, j1y end
    return j2x, j2y
end

-- ── shapes (flat point lists in local units) ───────────────────────────────

local function ellipse(cx, cy, rx, ry, rot, n)
    n = n or 16
    local pts, cr, sr = {}, cos(rot or 0), sin(rot or 0)
    for i = 0, n - 1 do
        local a = 2 * pi * i / n
        local x, y = rx * cos(a), ry * sin(a)
        pts[#pts + 1] = cx + x * cr - y * sr
        pts[#pts + 1] = cy + x * sr + y * cr
    end
    return pts
end

local function capsule(ax, ay, ra, bx, by, rb)
    local th, pts, n = atan2(by - ay, bx - ax), {}, 7
    for i = 0, n do
        local a = th - pi / 2 + pi * i / n
        pts[#pts + 1] = bx + rb * cos(a); pts[#pts + 1] = by + rb * sin(a)
    end
    for i = 0, n do
        local a = th + pi / 2 + pi * i / n
        pts[#pts + 1] = ax + ra * cos(a); pts[#pts + 1] = ay + ra * sin(a)
    end
    return pts
end

-- tapered strip through a chain of points, round at the tip; jag > 0: ragged edges (fur on end)
local function strip(chain, r0, r1, jag, bulge)
    local left, right, n = {}, {}, #chain / 2
    for i = 1, n do
        local j0, j1 = math.max(1, i - 1), math.min(n, i + 1)
        local dx = chain[2 * j1 - 1] - chain[2 * j0 - 1]
        local dy = chain[2 * j1] - chain[2 * j0]
        local l = sqrt(dx * dx + dy * dy) + 1e-9
        local r = r0 + (r1 - r0) * (i - 1) / (n - 1)
        if bulge then r = r * (1 + bulge * sin(pi * (i - 1) / (n - 1))) end
        if jag and jag > 0 and i > 1 and i < n then r = r * (1 + jag * ((i % 2 == 0) and 0.5 or -0.12)) end
        local x, y = chain[2 * i - 1], chain[2 * i]
        left[#left + 1] = { x - dy / l * r, y + dx / l * r }
        right[#right + 1] = { x + dy / l * r, y - dx / l * r }
    end
    local pts = {}
    for _, q in ipairs(left) do pts[#pts + 1] = q[1]; pts[#pts + 1] = q[2] end
    local tx, ty = chain[2 * n - 1], chain[2 * n]
    local th = atan2(left[n][2] - ty, left[n][1] - tx)
    for k = 1, 5 do      -- round tip from the left edge to the right edge
        local a = th - pi * k / 6
        pts[#pts + 1] = tx + r1 * cos(a); pts[#pts + 1] = ty + r1 * sin(a)
    end
    for i = n, 1, -1 do pts[#pts + 1] = right[i][1]; pts[#pts + 1] = right[i][2] end
    return pts
end

-- ── the cat ─────────────────────────────────────────────────────────────────

local NOSE = 12            -- hip to the tip of the nose, walking (u)

local function new_cat(o)
    local self = setmetatable({}, C)
    self.W, self.H = o.W, o.H
    self.u = o.H * 0.0088 * (o.size or 1)
    self.ground = o.H * 0.988
    self.dir = o.dir or ((math.random() < 0.5) and 1 or -1)
    self.speed = o.speed or rnd(5.5, 7.0) -- u/s
    self.obstacles = o.obstacles or function() return {} end   -- {x1, x2, pumpkin, x, y, w, h, profile, mirror}
    self.scare = o.scare or function() end                        -- (x) → x of a zombie near x, or nil
    self.threat = o.threat or function() end                      -- (x, dir) → x of a werewolf ahead, or nil
    self.elev, self.air = 0, false        -- u above the ground: standing on something / in a jump
    self.phase, self.bob = 0, 0
    self.T = 0
    self.blink_at, self.blink = rnd(1, 4), 1
    self.face_want, self.back = 1, 0
    local p = { x = 0, sx = 1, hs = 1, face = 1, eye = 1, gx = 0, tongue = 0, arch = 0, red = 0, hiss = 0, bristle = 0 }
    for k, v in pairs(STAND) do p[k] = v end
    for k, v in pairs(TAILS[math.random(#TAILS)]) do p[k] = v end
    self.tail = { ta = p.ta, tk = p.tk, tc = p.tc, tw = p.tw }
    self.p = p
    self:neutral_feet(p)
    p.x = (self.dir == 1) and -14 * self.u or (self.W + 14 * self.u)
    if o.lead then          -- come over from the screen next door: its nose this far (u) in already
        p.x = (self.dir == 1) and (o.lead - NOSE) * self.u or (self.W - (o.lead - NOSE) * self.u)
    end
    if o.at then            -- there already (out of a puff: the witch was): its stops ahead only
        p.x = o.at
        self.start_f = (self.dir == 1) and o.at / self.W or 1 - o.at / self.W
    end
    self:plan()
    self.co = coroutine.create(function() self:program() end)
    return self
end

-- where the feet stand when the cat stands still (local x, ground)
function C:neutral_feet(t, pose)
    local sx = shoulder(pose or self.p)
    t.nfx, t.nfy, t.ffx, t.ffy = sx + 0.4, 0, sx - 0.2, 0
    t.nhx, t.nhy, t.fhx, t.fhy = -0.1, 0, -0.6, 0
    return t
end

-- height (u above the ground) of the solid things between screen x a and b
function C:surface(a, b)
    if a > b then a, b = b, a end
    local top = 0
    for _, ob in ipairs(self.obstacles()) do
        local pr = ob.profile
        if pr and ob.x + ob.w > a and ob.x < b then
            local n = #pr
            for i = 1, n do
                local cx = ob.x + (i - 0.5) / n * ob.w
                local j = ob.mirror and (n + 1 - i) or i
                -- the lowest of five columns: no standing on a pumpkin stem
                local f = pr[j]
                for m = math.max(1, j - 2), math.min(n, j + 2) do f = math.max(f, pr[m]) end
                if cx >= a and cx <= b and f < 1 then
                    local e = (self.ground - (ob.y + f * ob.h)) / self.u - 0.35   -- paws a bit into the edge
                    if e > top and e <= MAX_UP then top = e end
                end
            end
        end
    end
    return top
end

-- what the cat stands on, with the hip at screen x: the higher of under its hind and front paws
-- (the body may hang over an edge, the paws may not)
function C:support(x)
    local d = self.dir * self.u
    return math.max(self:surface(x - 1.5 * d, x + 1.5 * d), self:surface(x + 7.5 * d, x + 10.5 * d))
end

-- stops along the way, in screen x of the hip
function C:plan()
    local W, u, dir = self.W, self.u, self.dir
    local function X(f) return dir == 1 and f * W or (1 - f) * W end
    local function F(x) return dir == 1 and x / W or 1 - x / W end
    local stops = { { f = rnd(0.4, 0.6), kind = "sit" } }
    for _ = 1, math.random(1, 3) do stops[#stops + 1] = { f = rnd(0.12, 0.9), kind = "pause" } end

    -- a pumpkin ahead (its near side, not one the cat starts behind): sharpen the claws on it
    local best
    for _, ob in ipairs(self.obstacles()) do
        local edge = dir == 1 and ob.x1 or ob.x2
        local fe = F(edge)
        if ob.pumpkin and fe > 0.06 and (not best or fe < best.fe) then best = { fe = fe, ob = ob, edge = edge } end
    end
    if best and math.random() < 0.85 then
        local hx = best.edge - dir * 8.6 * u          -- hip, so the front paws reach the pumpkin
        local fs = F(hx)
        local far = dir == 1 and (W - best.ob.x2) or best.ob.x1
        local turn = far < 0.22 * W or math.random() < 0.3
        local keep = {}
        for _, s in ipairs(stops) do
            if s.f < fs - 0.08 or (not turn and s.f > F(dir == 1 and best.ob.x2 or best.ob.x1) + 0.1) then
                keep[#keep + 1] = s
            end
        end
        stops = keep
        stops[#stops + 1] = { f = fs, kind = "scratch", edge = best.edge, turn = turn }
    elseif math.random() < 0.15 then
        local ft = rnd(0.3, 0.75)
        local keep = {}
        for _, s in ipairs(stops) do if s.f < ft - 0.08 then keep[#keep + 1] = s end end
        stops = keep
        stops[#stops + 1] = { f = ft, kind = "pause", turn = true }
    end
    -- no stopping behind something (the cat would vanish): move such a stop to a free spot
    local function hidden(x)
        local lo, hi = math.min(x - dir * 4 * u, x + dir * 13 * u), math.max(x - dir * 4 * u, x + dir * 13 * u)
        for _, ob in ipairs(self.obstacles()) do
            if not ob.profile and ob.x2 > lo and ob.x1 < hi then return true end
        end
        -- astride an edge (half on something, half not) is no place to sit either
        local back = self:surface(x - dir * u, x + dir * 4 * u)
        local front = self:surface(x + dir * 5 * u, x + dir * 10 * u)
        return math.abs(back - front) > CLIMB
    end
    local function free(x)
        for k = 0, 60 do
            for _, sg in ipairs({ -1, 1 }) do
                local y = x + sg * k * 2 * u
                if y > 0.05 * W and y < 0.95 * W and not hidden(y) then return y end
            end
        end
    end
    local moved = {}
    for _, s in ipairs(stops) do
        if s.kind == "scratch" then
            s.x = X(s.f)
        else
            s.x = free(X(s.f))
            if s.x then s.f = F(s.x) end
        end
        if s.x then moved[#moved + 1] = s end
    end
    table.sort(moved, function(a, b) return a.f < b.f end)
    if self.start_f then
        local ahead = {}
        for _, s in ipairs(moved) do if s.f > self.start_f + 0.05 then ahead[#ahead + 1] = s end end
        moved = ahead
    end

    -- no two stops close together
    local plan, lastf = {}, -1
    for _, s in ipairs(moved) do
        if (s.kind == "scratch" or s.turn or s.f - lastf > 0.1) and s.f > 0.05 then
            plan[#plan + 1] = s
            lastf = s.f
            if s.turn then break end
        end
    end
    self.stops = plan
end

-- ── coroutine helpers ───────────────────────────────────────────────────────

function C:yield()
    return coroutine.yield() or 0
end

function C:wait(d)
    local t = 0
    while t < d do t = t + self:yield() end
end

function C:tween(target, dur, fn)
    local p, from, t = self.p, {}, 0
    for k in pairs(target) do from[k] = p[k] end
    while t < dur do
        t = t + self:yield()
        local q = (fn or ease)(math.min(1, t / dur))
        for k, v in pairs(target) do p[k] = from[k] + (v - from[k]) * q end
    end
end

-- head turns: 1 = profile forward, 0 = towards the viewer, -1 = looking back over the shoulder
function C:look(f, hold)
    self.face_want = f
    while self.p.face ~= f or self.p.hs < 1 do self:yield() end
    if hold then self:wait(hold) end
end

function C:gait()
    local p, sx = self.p, shoulder(self.p)
    local function foot(off, nx, lift)
        local q = (self.phase + off) % 1
        if q < DUTY then return nx + STRIDE * (0.5 - q / DUTY), 0 end
        q = (q - DUTY) / (1 - DUTY)
        return nx - STRIDE * 0.5 + STRIDE * ease(q), -sin(pi * q) * lift
    end
    p.nhx, p.nhy = foot(0.0, -0.1, 1.1)
    p.nfx, p.nfy = foot(0.25, sx + 0.4, 1.0)
    p.fhx, p.fhy = foot(0.5, -0.6, 1.1)
    p.ffx, p.ffy = foot(0.75, sx - 0.2, 1.0)
    self.bob = 0.16 * cos(4 * pi * self.phase)
    self.hbob = 0.22 * cos(4 * pi * self.phase + 1.3)    -- the head nods a beat behind the body
    self.walk_seen = self.T                               -- (tail sway, head bob: while walking)
end

function C:settle(dur)
    self.bob, self.hbob = 0, 0
    self:tween(self:neutral_feet({}), dur or 0.3)
end

-- a jump of dist u forward, up or down to whatever is there
function C:leap(dist)
    local p, u = self.p, self.u
    self.face_want = 1
    local crouch = self:neutral_feet({}, STAND)
    crouch.hh, crouch.ba = STAND.hh - 1.5, 0
    self.bob = 0
    self:tween(crouch, 0.22)
    local x0, e0 = p.x, self.elev
    local x1 = x0 + self.dir * dist * u
    local e1 = self:support(x1)
    require("mp.msg").verbose(string.format("cat: leap %.1f u, %.1f → %.1f", dist, e0, e1))
    local bump = 2.5 + math.abs(e1 - e0) * 0.45
    local T = clamp(0.3 + dist * 0.02 + math.abs(e1 - e0) * 0.012, 0.35, 0.7)
    local sx = shoulder(STAND)
    self.air = true
    local t = 0
    while t < T do
        t = t + self:yield()
        local q = math.min(1, t / T)
        p.x = x0 + (x1 - x0) * q
        self.elev = e0 + (e1 - e0) * q + bump * 4 * q * (1 - q)
        -- stretched out: front paws reaching, hind legs pushing off behind
        p.hh = STAND.hh
        p.ba = (q < 0.5) and 0.22 * (1 - 2 * q) + (e1 - e0) * 0.01 or -0.18 * (2 * q - 1)
        p.nfx, p.nfy, p.ffx, p.ffy = sx + 2.4, -1.2, sx + 1.8, -0.7
        p.nhx, p.nhy, p.fhx, p.fhy = -2.4, -0.7, -2.9, -0.4
    end
    self.elev, self.air = e1, false
    local land = self:neutral_feet({}, STAND)
    land.hh, land.ba = STAND.hh - 1.2, 0.02
    self:tween(land, 0.12)
    self:tween({ hh = STAND.hh }, 0.2)
end

-- where the ground ahead steps up or down more than the cat can walk: distance from the hip (u)
function C:edge_ahead()
    local p, u, dir = self.p, self.u, self.dir
    for k = 9, 12, 0.5 do
        local e = self:surface(p.x + dir * k * u, p.x + dir * (k + 3) * u)     -- bridges gaps between pumpkins
        if e > self.elev + CLIMB then return k, e end
        if e < self.elev - CLIMB then
            -- down: to the bottom of the slope, not onto the rounded shoulder of a tombstone
            for j = k + 0.5, k + 6, 0.5 do
                e = math.min(e, self:surface(p.x + dir * j * u, p.x + dir * (j + 3) * u))
            end
            return k, e
        end
    end
end

function C:walk_to(tx, noleap)
    local p, u = self.p, self.u
    local v, acc = self.v or 0, self.speed / 0.6
    local glance = rnd(4, 12)
    while true do
        local dt = self:yield()
        local rem = (tx - p.x) * self.dir / u
        if rem <= 0.05 then break end
        local k, e = self:edge_ahead()
        if k and not (noleap and rem < 6) then
            -- land with the hind paws past the edge, and clear of it on the way down
            local d = k + 1.5
            while e < self.elev and d < k + 8 and self:support(p.x + self.dir * d * u) > e + CLIMB do d = d + 0.5 end
            self:leap(d)
            v = self.speed * 0.6
            rem = (tx - p.x) * self.dir / u
            if rem <= 0.05 then break end
        end
        -- a werewolf ahead: it stops and stands up to him, until he's gone
        if self.threat(p.x, self.dir) then
            self:standoff()
            v = 0
        end
        -- a zombie near: dash past it (no slowing down for the stop), looking back at it once past
        local zx = self.scare(p.x)
        local want = zx and self.speed * 2.4 or math.min(self.speed, sqrt(2 * acc * rem) + 0.3)
        v = (v < want) and math.min(want, v + acc * 3 * dt) or want
        if zx then self.face_want = ((zx - p.x) * self.dir < 0) and -1 or 1 glance = rnd(4, 8) end
        if self.scared and not zx then self.face_want = 1 end
        self.scared = zx
        local step = math.min(v * dt, rem)
        p.x = p.x + self.dir * step * u
        self.phase = (self.phase + step * DUTY / STRIDE) % 1
        self:gait()
        glance = glance - dt
        if glance < 0 then          -- a glance at the audience while walking
            self.face_want = (self.face_want == 1) and 0 or 1
            glance = self.face_want == 0 and rnd(1.2, 2.2) or rnd(6, 16)
        end
    end
    self.face_want = 1
    self.v = 0
    self:settle()
end

function C:turn()
    self:tween({ sx = -1 }, 0.55)
    self.dir, self.p.sx = -self.dir, 1
end

-- ── behaviours ──────────────────────────────────────────────────────────────

function C:sit_down()
    local feet = self:neutral_feet({}, SIT)
    feet.nhx, feet.fhx = 1.4, 1.0
    local t = {}
    for k, v in pairs(SIT) do t[k] = v end
    for k, v in pairs(feet) do t[k] = v end
    self:tween(t, rnd(1.0, 1.4))
end

function C:stand_up()
    local t = self:neutral_feet({}, STAND)
    for k, v in pairs(STAND) do t[k] = v end
    for k, v in pairs(self.tail) do t[k] = v end
    self:tween(t, 0.8)
end

-- head centre (local), for paws that go to the mouth
function C:head_at()
    local sx, sy = shoulder(self.p)
    return sx + self.p.nx, sy + self.p.ny
end

function C:groom()
    local p = self.p
    self:look(1)
    local ny0, nx0 = p.ny, p.nx
    local hx, hy = self:head_at()
    self:tween({ nfx = hx + 1.7, nfy = hy + 2.6, hp = 0.35, eye = 0.3 }, 0.5)
    for _ = 1, math.random(3, 7) do
        self:tween({ hp = 0.6, ny = ny0 + 0.45, tongue = 1 }, rnd(0.18, 0.26))
        self:tween({ hp = 0.3, ny = ny0, tongue = 0 }, rnd(0.2, 0.3))
    end
    if math.random() < 0.6 then    -- wash: the wet paw over the ear and down the face
        for _ = 1, math.random(2, 4) do
            self:tween({ nfx = hx + 0.6, nfy = hy + 0.2, hp = 0.55, nx = nx0 + 0.3 }, 0.32)
            self:tween({ nfx = hx + 1.8, nfy = hy + 2.4, hp = 0.25, nx = nx0 }, 0.32)
        end
    end
    self:tween({ nfx = shoulder(p) + 0.4, nfy = 0, hp = 0, ny = ny0, nx = nx0, eye = 1, tongue = 0 }, 0.45)
end

function C:look_around()
    self:look(0, rnd(1.5, 3))
    if math.random() < 0.6 then
        self:tween({ gx = (math.random() < 0.5) and -1 or 1 }, 0.2)
        self:wait(rnd(0.6, 1.4))
        self:tween({ gx = 0 }, 0.2)
    end
    self:look(-1, rnd(1, 2))
    self:look(1, rnd(0.6, 1.2))
    if math.random() < 0.5 then self:look(0, rnd(1, 2)) end
    self:look(1)
end

function C:pause_here()
    local r = math.random()
    if r < 0.35 then
        self:look(0, rnd(1.5, 3))
        self:look(1)
    elseif r < 0.6 then
        self:look(-1, rnd(1, 1.8))
        self:look(1, 0.3)
    else
        self:sit_down()
        self:look_around()
        self:stand_up()
    end
end

-- face up to the werewolf: arch, hiss (a lunge or two at him) until he's backed off
function C:standoff()
    local p = self.p
    self.v = 0
    self:settle(0.15)
    self:look(1)
    local t = {}
    for k, v in pairs(ARCH) do t[k] = v end
    for k, v in pairs(self:neutral_feet({}, ARCH)) do t[k] = v end
    self.arched = true
    require("mp.msg").verbose("cat: arches its back at the werewolf")
    self:tween(t, 0.35)
    local held = 0
    while self.threat(p.x, self.dir) and held < 8 do
        local x0 = p.x
        self:tween({ x = x0 + self.dir * 1.2 * self.u, hp = 0.3 }, 0.15)     -- a lunge
        self:tween({ x = x0, hp = 0.15 }, 0.3)
        local w = rnd(0.6, 1.4)
        self:wait(w)
        held = held + 0.45 + w
    end
    self:wait(rnd(0.5, 1))
    self.arched = false
    local b = self:neutral_feet({}, STAND)
    for k, v in pairs(STAND) do b[k] = v end
    for k, v in pairs(self.tail) do b[k] = v end
    b.arch, b.red, b.hiss, b.bristle = 0, 0, 0, 0
    self:tween(b, 0.6)
    self:look(-1, 0.6)           -- a look back: and stay away
    self:look(1)
end

function C:pumpkin_there(edge)
    for _, ob in ipairs(self.obstacles()) do
        if ob.pumpkin and math.abs((self.dir == 1 and ob.x1 or ob.x2) - edge) < 4 * self.u then return true end
    end
    return false
end

function C:scratch()
    local p = self.p
    local sx = SCRATCH.bl * cos(SCRATCH.ba)
    local reach = sx + 3.9
    local t = { nfx = reach, nfy = -10.4, ffx = reach - 0.3, ffy = -8.6 }
    for k, v in pairs(SCRATCH) do t[k] = v end
    self:tween(t, 0.8)
    local stop = self.T + rnd(3, 5)
    local up = true
    while self.T < stop do
        if up then
            self:tween({ nfy = -8.4, nfx = reach - 0.5, ffy = -10.6, ffx = reach - 0.2 }, rnd(0.28, 0.36))
        else
            self:tween({ nfy = -10.6, nfx = reach, ffy = -8.4, ffx = reach - 0.7 }, rnd(0.28, 0.36))
        end
        up = not up
    end
    self:stand_up()
    self:look(0, rnd(1, 2))
    self:look(1)
end

function C:program()
    local log = require("mp.msg")
    local plan = {}
    for _, s in ipairs(self.stops) do plan[#plan + 1] = string.format("%s@%d%s", s.kind, s.x, s.turn and "+turn" or "") end
    log.verbose(string.format("cat from the %s: %s", self.dir == 1 and "left" or "right", table.concat(plan, " ")))
    self:wait(0.01)
    for _, s in ipairs(self.stops) do
        local zombie = self.scare(s.x)               -- no stopping by a zombie
        if not zombie then
            self:walk_to(s.x, s.kind == "scratch")
            zombie = self.scare(self.p.x)
        end
        if not zombie then
            log.verbose(string.format("cat: %s at %d (%.0f s)", s.kind, s.x, self.T))
            if s.kind == "sit" then
                self:sit_down()
                self:wait(rnd(0.5, 1.5))
                if math.random() < 0.5 then self:groom(); self:look_around()
                else self:look_around(); self:groom() end
                if math.random() < 0.4 then self:groom() end
                self:wait(rnd(0.5, 2))
                self:stand_up()
            elseif s.kind == "scratch" then
                if self.elev < 1 and self:pumpkin_there(s.edge) then self:scratch() end   -- (then up it goes, unless it turns)
            else
                self:pause_here()
            end
            if s.turn then self:turn() end
        end
    end
    self:walk_to(self.dir == 1 and self.W + 14 * self.u or -14 * self.u)
end

function C:update(dt)
    self.T = self.T + dt
    local p = self.p
    -- blinking
    self.blink_at = self.blink_at - dt
    if self.blink_at < 0 then
        self.blink = 0.08
        if self.blink_at < -0.14 then self.blink, self.blink_at = 1, rnd(2, 6) end
    end
    -- head turns: squash the head to nothing, swap the view, unfold it again
    if p.face ~= self.face_want then
        p.hs = p.hs - dt / 0.09
        if p.hs <= 0.1 then p.face, p.hs = self.face_want, 0.1 end
    elseif p.hs < 1 then
        p.hs = math.min(1, p.hs + dt / 0.09)
    end
    -- looking back: the head swings back over the shoulder
    local want = (self.face_want == -1) and 1 or 0
    self.back = self.back + clamp(want - self.back, -dt * 5, dt * 5)
    if coroutine.status(self.co) == "dead" then return false end
    local ok, err = coroutine.resume(self.co, dt)
    if not ok then
        require("mp.msg").error("prowler: " .. tostring(err))
        return false
    end
    -- follow what it stands on: small steps, or a drop when the thing goes away
    if not self.air then
        local e = self:support(p.x)
        self.elev = self.elev + clamp(e - self.elev, -dt * 30, dt * 12)
    end
    return coroutine.status(self.co) ~= "dead"
end

-- ── drawing ────────────────────────────────────────────────────────────────

-- shapes (local units) → one ASS drawing; (ox, oy): shifted that many u on screen
function C:path(shapes, ox, oy)
    local p, u = self.p, self.u
    local m = self.dir * p.sx * u
    local x0, y0 = p.x + (ox or 0) * u, self.ground - (self.bob + self.elev - (oy or 0)) * u
    local out = {}
    for _, s in ipairs(shapes) do
        local n = #s / 2
        local xs, ys, area = {}, {}, 0
        for i = 1, n do
            xs[i] = floor((x0 + s[2 * i - 1] * m) * 4 + 0.5)
            ys[i] = floor((y0 + s[2 * i] * u) * 4 + 0.5)
        end
        for i = 1, n do
            local j = i % n + 1
            area = area + xs[i] * ys[j] - xs[j] * ys[i]
        end
        local a, b, st = 1, n, 1
        if area < 0 then a, b, st = n, 1, -1 end     -- same winding everywhere: overlaps add up
        local parts = { string.format("m %d %d", xs[a], ys[a]), "l" }
        for i = a + st, b, st do parts[#parts + 1] = string.format("%d %d", xs[i], ys[i]) end
        out[#out + 1] = table.concat(parts, " ")
    end
    return table.concat(out, " ")
end

function C:event(shapes, fill, rim, extra, ox, oy)
    local bord = rim and math.max(0.7, self.u * 0.075) or 0
    return string.format("{\\an7\\pos(0,0)\\bord%.2f\\shad0\\1c%s\\3c%s\\3a&H60&%s\\p3}%s{\\p0}",
        bord, fill, rim or fill, extra or "", self:path(shapes, ox, oy))
end

-- head point: offset (ox, oy) from the head centre, turned by face/squash and tilted by pitch
function C:head_pt(hx, hy, ox, oy, view)
    local p = self.p
    local c, s = cos(p.hp), sin(p.hp)
    local fx = (view == 0) and 1 or view
    local x, y = ox * c - oy * s, ox * s + oy * c
    return hx + x * fx * p.hs, hy + y
end

-- a paw: small and round, the toes curling down as the foot comes off the ground
local function paw(x, y, lift)
    local curl = clamp(lift, 0, 1.2) * 0.55
    return ellipse(x + 0.22, y - 0.36, 0.6, 0.37, curl, 12)
end

function C:legs(far)
    local p = self.p
    local shx, shy = shoulder(p)
    local fx, fy = p[far and "ffx" or "nfx"], p[far and "ffy" or "nfy"]
    local hx, hy = p[far and "fhx" or "nhx"], p[far and "fhy" or "nhy"]
    local out = {}
    -- front: shoulder → elbow (bends back) → wrist, a slim forearm and a small paw
    local rx, ry = shx + 0.2, shy + 1.1
    local wx, wy = fx - 0.02, fy - 0.5
    local ex, ey = ik(rx, ry, wx, wy, FL1, FL2, -1)
    out[#out + 1] = capsule(rx, ry, 1.2, ex, ey, 0.62)
    out[#out + 1] = capsule(ex, ey, 0.58, wx, wy, 0.4)
    out[#out + 1] = paw(fx, fy, -fy)
    -- hind: a round thigh (the haunch) → knee (bends forward) → hock → a long slim foot
    local stx, sty = hx - 0.5, hy - 1.9
    local sitx, sity = hx - HL3, -0.42
    local kx, ky = stx + (sitx - stx) * p.fold, sty + (sity - sty) * p.fold
    local hrx, hry = 0.3, -p.hh + 0.8
    local nx, ny = ik(hrx, hry, kx, ky, HL1, HL2, 1)
    ny = math.min(ny, math.max(ky, hy) - 0.75)        -- (sitting: the knee stays above the ground)
    out[#out + 1] = capsule(hrx, hry, 1.75 + 0.5 * p.fold, nx, ny, 0.85 + 0.3 * p.fold)
    out[#out + 1] = capsule(nx, ny, 0.6, kx, ky, 0.38)
    out[#out + 1] = capsule(kx, ky, 0.38, hx + 0.05, hy - 0.4, 0.34)
    out[#out + 1] = paw(hx, hy, -hy)
    return out
end

function C:frame()
    local p, ev, t = self.p, {}, self.T
    local shx, shy = shoulder(p)
    local hpx, hpy = 0, -p.hh
    local wa = clamp(1 - (t - (self.walk_seen or -9)) * 4, 0, 1)      -- 1 while walking
    local hx = shx + p.nx - 1.4 * self.back
    local hy = shy + p.ny - 0.3 * self.back + (self.hbob or 0) * wa
    local view = p.face
    local cb, sb = cos(p.ba), sin(p.ba)
    local function B(x0, y0, ox, oy) return x0 + ox * cb + oy * sb, y0 - ox * sb + oy * cb end

    -- shadow on the ground (not in the air)
    local fxs = (p.nfx + p.ffx + p.nhx + p.fhx) / 4
    if not self.air then
        ev[#ev + 1] = string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\blur%.1f\\1c&H000000&\\1a&HA0&\\p3}%s{\\p0}",
            self.u * 0.4, self:path({ ellipse(fxs, 0.1, math.abs(shx) * 0.5 + 3, 0.55) }))
    end

    -- far legs, a shade lighter so they read behind the body
    ev[#ev + 1] = self:event(self:legs(true), FUR_FAR, RIM)

    local body = {}
    -- tail: a long chain from the rump, an S that sways as it walks; never below the ground;
    -- bristling: thick, the fur on end
    local tx, ty = B(hpx, hpy, -1.9, -1.15)
    local chain = { tx, ty }
    local sway = wa * 0.2 * sin(2 * pi * (self.phase or 0))
    local sub = (p.bristle > 0.3) and 2 or 1              -- (bristling: finer, for the spikes)
    for j = 1, TAIL_N * sub do
        local i = j / sub
        local q = i / TAIL_N
        local a = p.ta + p.tk * i + p.tc * math.max(0, i - 8) ^ 2
            + p.tw * sin(t * 1.6 - i * 0.45) * q + sway * sin(pi * q) * (1 - p.bristle)
        tx, ty = tx + TAIL_SEG / sub * cos(a), math.min(-0.75, ty + TAIL_SEG / sub * sin(a))
        chain[#chain + 1] = tx; chain[#chain + 1] = ty
    end
    body[#body + 1] = strip(chain, 0.78 + 0.4 * p.bristle, 0.46 + 0.45 * p.bristle, 0.7 * p.bristle, 0.5 * p.bristle)

    -- torso: lofted along the spine - full chest, slim tucked-up waist, a level back with the
    -- withers just showing; arched: the spine bows up high, the belly drawn up under it, the fur
    -- on the back standing up in spikes
    local N, top, bot = 16, {}, {}
    for i = 0, N do
        local q = i / N
        local s = sin(pi * q)
        local sy = -p.arch * 4.2 * s ^ 0.65 - (0.1 + 1.2 * p.fold) * s     -- (sitting: a rounded back)
        local up = (1.75 - 0.25 * s + 0.35 * q * q) * (1 - 0.15 * p.arch)
        if i % 2 == 1 and p.bristle > 0 then up = up + 0.75 * p.bristle * sqrt(s) end
        local dn = (1.5 + 1.15 * q * q - 0.55 * s) * (1 - 0.3 * p.arch)
        local ax, ay = B(hpx, hpy, q * p.bl, sy - up)
        local bx, by = B(hpx, hpy, q * p.bl, sy + dn)
        top[#top + 1] = { ax, ay }; bot[#bot + 1] = { bx, by }
    end
    local torso = {}
    for i = 1, #top do torso[#torso + 1] = top[i][1]; torso[#torso + 1] = top[i][2] end
    for i = #bot, 1, -1 do torso[#torso + 1] = bot[i][1]; torso[#torso + 1] = bot[i][2] end
    body[#body + 1] = torso
    local cx, cy = B(hpx, hpy, -0.3, 0.05)                 -- the haunch, round
    body[#body + 1] = ellipse(cx, cy, 2.4 + 0.25 * p.fold, 2.5 - 0.35 * p.arch, -p.ba, 18)
    cx, cy = B(shx, shy, 0.4 - 0.3 * p.fold, 0.75)         -- the chest, deep
    body[#body + 1] = ellipse(cx, cy, 2.05 - 0.35 * p.fold, 2.5 - 0.3 * p.arch - 0.5 * p.fold, -p.ba, 18)
    cx, cy = B(shx, shy, -0.6, -0.9)                       -- the shoulder blade, at the withers
    if p.arch < 0.9 then body[#body + 1] = ellipse(cx, cy, 1.5 * (1 - p.arch), 0.9 * (1 - p.arch), -p.ba, 12) end
    -- the neck: up and forward out of the chest, narrower than both
    local nax, nay = B(shx, shy, 0.5, -0.1)
    body[#body + 1] = capsule(nax, nay, 1.75, hx - 0.35, hy + 0.45, 1.3)

    -- head: a round skull, full cheeks, a short muzzle and big ears
    local function H(ox, oy) return self:head_pt(hx, hy, ox * 1.1, oy * 1.1, view) end      -- (a big head)
    local function poly(list)
        local pts = {}
        for i = 1, #list, 2 do
            local a, b = H(list[i], list[i + 1])
            pts[#pts + 1] = a; pts[#pts + 1] = b
        end
        return pts
    end
    local function oval(ox, oy, rx, ry, rot, n)
        return poly(ellipse(ox, oy, rx, ry, rot or 0, n or 14))
    end
    local inner = {}
    if view == 0 then
        body[#body + 1] = oval(0, -0.1, 2.35, 2.1, 0, 18)
        body[#body + 1] = oval(0, 0.6, 2.6, 1.5, 0, 18)
        for _, k in ipairs({ -1, 1 }) do
            body[#body + 1] = poly({ k * 2.3, -0.3, k * 2.45, -2.1, k * 2.2, -4.25, k * 1.4, -3.05, k * 0.4, -1.95 })
            inner[#inner + 1] = poly({ k * 2.0, -1.0, k * 2.05, -3.65, k * 1.0, -2.1 })
        end
    else
        body[#body + 1] = oval(0, 0, 2.15, 2.05, 0, 18)           -- skull
        body[#body + 1] = oval(0.25, 0.6, 2.05, 1.55, 0, 16)      -- cheeks
        body[#body + 1] = oval(1.6, 0.65, 1.05, 0.78, 0.1)        -- muzzle
        body[#body + 1] = oval(1.35, 1.2, 0.7, 0.45)              -- chin
        body[#body + 1] = poly({ 0.1, -1.95, 0.75, -3.0, 1.15, -3.95, 1.55, -2.5, 1.7, -1.1 })        -- far ear
        body[#body + 1] = poly({ -1.85, -0.6, -1.85, -2.5, -1.15, -4.45, -0.4, -3.1, 0.4, -1.85 })    -- near ear
        inner[#inner + 1] = poly({ -1.45, -1.15, -1.3, -3.7, -0.35, -2.05 })
    end
    for _, s in ipairs(self:legs(false)) do body[#body + 1] = s end
    -- moonlight along the top edges (the body shifted up, mostly covered by the body itself)
    ev[#ev + 1] = self:event(body, SHEEN, nil, string.format("\\1a&H38&\\blur%.1f", self.u * 0.1), 0, -0.24)
    ev[#ev + 1] = self:event(body, FUR, RIM)
    ev[#ev + 1] = self:event(inner, EAR_IN)

    -- face: eyes (slit pupils, a glint), nose, tongue, whiskers
    local open = math.max(0.1, p.eye * self.blink)
    local eyes, pupils, pink, glints, fangs = {}, {}, {}, {}, {}
    local whisk = {}
    local function line(ax, ay, bx2, by2)
        local x1, y1 = H(ax, ay)
        local x2, y2 = H(bx2, by2)
        whisk[#whisk + 1] = { x1, y1, x2, y2, x1, y1 }
    end
    local wide = 1 - 0.35 * p.red              -- (in a fright: narrowed, glaring)
    if view == 0 then
        for _, sx in ipairs({ -0.95, 0.95 }) do
            eyes[#eyes + 1] = oval(sx, -0.2, 0.66, 0.56 * open * wide, sx * 0.12)
            if open > 0.3 then
                pupils[#pupils + 1] = oval(sx + p.gx * 0.25, -0.2, 0.14, 0.5 * open * wide)
                glints[#glints + 1] = oval(sx + p.gx * 0.25 - 0.22, -0.4, 0.1, 0.1, 0, 8)
            end
            for k = -1, 1 do line(sx * 1.1, 0.85, sx * 3.5, 0.65 + k * 0.5) end
        end
        pink[#pink + 1] = poly({ -0.32, 0.5, 0.32, 0.5, 0, 0.82 })
        line(0, 0.82, 0, 1.05); line(0, 1.05, -0.4, 1.25); line(0, 1.05, 0.4, 1.25)
    else
        eyes[#eyes + 1] = oval(1.15, -0.3, 0.52, 0.43 * open * wide, 0.15)
        if open > 0.3 then
            pupils[#pupils + 1] = oval(1.3, -0.28, 0.12, 0.37 * open * wide)
            glints[#glints + 1] = oval(1.08, -0.47, 0.09, 0.09, 0, 8)
        end
        pink[#pink + 1] = oval(2.6, 0.22, 0.2, 0.15)
        if p.tongue > 0.5 then pink[#pink + 1] = oval(2.3, 1.2, 0.4, 0.26) end
        if p.hiss > 0.5 then       -- hissing: the mouth wide open, fangs
            pink[#pink + 1] = poly({ 1.3, 0.95, 2.65, 0.72, 2.45, 1.75 })
            fangs[#fangs + 1] = poly({ 2.2, 0.82, 2.42, 0.78, 2.33, 1.15 })
            fangs[#fangs + 1] = poly({ 2.05, 1.62, 2.28, 1.66, 2.2, 1.32 })
        end
        for k = -1, 1 do line(2.0, 0.8, 4.4, 0.55 + k * 0.55) end
    end
    ev[#ev + 1] = self:event(eyes, p.red > 0.5 and RED_EYE or EYE, nil, string.format("\\bord%.2f\\3c%s\\3a&HB0&\\blur%.1f",
        self.u * 0.12, p.red > 0.5 and RED_EYE or EYE, self.u * 0.1))
    if #pupils > 0 then ev[#ev + 1] = self:event(pupils, PUPIL) end
    if #glints > 0 then ev[#ev + 1] = self:event(glints, GLINT, nil, "\\1a&H40&") end
    ev[#ev + 1] = self:event(pink, PINK)
    if #fangs > 0 then ev[#ev + 1] = self:event(fangs, FANG) end
    -- whiskers: hairlines (degenerate paths drawn by their outline)
    ev[#ev + 1] = string.format("{\\an7\\pos(0,0)\\bord%.2f\\shad0\\1a&HFF&\\3c%s\\3a&H90&\\p3}%s{\\p0}",
        math.max(0.4, self.u * 0.045), WHISKER, self:path(whisk))
    return ev
end

function C:render(now, out, hz)
    if not self.drawn or now >= (self.next_draw or 0) then
        self.next_draw = now + 1 / (hz or 15)
        self.drawn = self:frame()
    end
    for _, e in ipairs(self.drawn) do out[#out + 1] = e end
end

return { new = new_cat, NOSE = NOSE, poses = { STAND = STAND, SIT = SIT, SCRATCH = SCRATCH, ARCH = ARCH, TAILS = TAILS } }
