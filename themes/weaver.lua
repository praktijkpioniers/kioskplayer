-- Orb weaver: a tiny spider builds a web in a top corner of the screen, the way a garden spider
-- does, over several minutes. Threads and spider are ASS vector drawings (no bitmaps), so they
-- stay hairline-thin at any resolution. Loaded by engine.lua.
--
-- Construction, in corner coordinates (corner at 0,0, u along the top edge, v downwards):
--   1. drop from the ceiling on a dragline, pump a swing until it catches the side wall: the bridge;
--      then sink from it and swing to the wall lower down, once or twice, so the edge is no straight line
--   2. crawl along the walls, often trailing a line across the corner (inner frame)
--   3. drop from the ceiling straight through the future hub onto the bridge: the first two spokes
--   4. spokes: out along a built spoke, along the frame trailing silk, fasten, back along the new one
--   5. a few tight turns round the hub, then a wide temporary spiral outwards
--   6. the fine capture spiral from the outside in, eating the temporary spiral on the way
--   7. sit head down in the hub; much later climb away and let the web fade
-- Every web is different: frame, hub, number and angles of the spokes, spiral spacing, small faults.

local W_ = {}
W_.__index = W_

local pi = math.pi
local floor = math.floor
local function rnd(a, b) return a + math.random() * (b - a) end
local function hypot(x, y) return math.sqrt(x * x + y * y) end
local function lerp(a, b, t) return a + (b - a) * t end

-- thread styles: outline width (px at 1080p, the drawn line is twice that) and alpha (hex, 00 = opaque)
local STYLE = {
    frame   = { bord = 0.5,  alpha = 0x60 },
    hub     = { bord = 0.42, alpha = 0x78 },
    aux     = { bord = 0.36, alpha = 0x90 },
    capture = { bord = 0.4,  alpha = 0x80 },
}
local KINDS = { "aux", "capture", "hub", "frame" }

-- ── geometry ───────────────────────────────────────────────────────────────

-- first hit of the ray o + t·d on the closed polygon: t, edge index, position along the edge
local function ray_hit(ox, oy, dx, dy, poly)
    local best, bi, bs = math.huge, nil, nil
    for i = 1, #poly do
        local a, b = poly[i], poly[i % #poly + 1]
        local ex, ey = b[1] - a[1], b[2] - a[2]
        local den = dx * ey - dy * ex
        if math.abs(den) > 1e-9 then
            local qx, qy = a[1] - ox, a[2] - oy
            local t = (qx * ey - qy * ex) / den
            local s = (qx * dy - qy * dx) / den
            if t > 1e-6 and s >= -1e-6 and s <= 1 + 1e-6 and t < best then best, bi, bs = t, i, s end
        end
    end
    return best, bi, bs
end

-- distance from (x, y) to the nearest polygon edge; negative when outside (polygon is convex)
local function edge_dist(x, y, poly)
    local d = math.huge
    local inside = true
    for i = 1, #poly do
        local a, b = poly[i], poly[i % #poly + 1]
        local ex, ey = b[1] - a[1], b[2] - a[2]
        local l2 = ex * ex + ey * ey
        local t = l2 > 0 and math.max(0, math.min(1, ((x - a[1]) * ex + (y - a[2]) * ey) / l2)) or 0
        d = math.min(d, hypot(x - a[1] - ex * t, y - a[2] - ey * t))
        local cr = ex * (y - a[2]) - ey * (x - a[1])
        if cr < 0 then inside = false end
    end
    return inside and d or -d
end

local function new_web(o)
    local self = setmetatable({}, W_)
    self.name, self.corner = o.name, o.corner
    self.W, self.H = o.W, o.H
    self.flip = o.corner:find("right") ~= nil
    local H = o.H
    local size = o.size or 1
    self.L = H * 0.011 * size                       -- spider body length
    self.speed = H * 0.05 * (o.speed or 1)          -- walking speed, px/s
    self.stay = o.stay or 900

    -- frame: ceiling, side wall and the bridge between them. The bridge gets kinked outwards by
    -- one or two moorings (the spider sinks from the outer line and swings to the wall lower
    -- down), and often there is a short line across the corner itself.
    local S = H * rnd(0.24, 0.36) * size
    local T, Lv = S * rnd(0.95, 1.35), S * rnd(0.75, 1.0)
    self.T1, self.L1 = { T, 0 }, { 0, Lv }
    local chain = { self.T1, self.L1 }      -- the outer edge, ceiling to wall
    self.moor = {}
    for _ = 1, math.random(1, 2) do
        local a, b = chain[#chain - 1], chain[#chain]
        local f = rnd(0.35, 0.65)
        local B = { lerp(a[1], b[1], f), lerp(a[2], b[2], f) }
        local G = { 0, b[2] + S * rnd(0.08, 0.2) }
        chain[#chain], chain[#chain + 1] = B, G
        self.moor[#self.moor + 1] = { B = B, G = G }
    end
    if math.random() < 0.6 then
        self.cut = { T * rnd(0.1, 0.22), Lv * rnd(0.1, 0.22) }
        self.poly = { { self.cut[1], 0 } }
    else
        self.poly = { { 0, 0 } }
    end
    for _, p in ipairs(chain) do self.poly[#self.poly + 1] = p end
    if self.cut then self.poly[#self.poly + 1] = { 0, self.cut[2] } end

    -- hub: the roomiest spot inside the frame (farthest from every edge), nudged upwards a bit
    local best, bx, by = -1, 0, 0
    for i = 1, 39 do
        for j = 1, 39 do
            local x, y = T * i / 40, (chain[#chain][2]) * j / 40
            local d = edge_dist(x, y, self.poly)
            if d > best then best, bx, by = d, x, y end
        end
    end
    self.rin = best
    self.hub = { bx * rnd(0.95, 1.08), by - best * rnd(0.05, 0.3) }
    self.drop = self.hub[1]
    self.D = { self.hub[1], self.hub[2] + ray_hit(self.hub[1], self.hub[2], 0, 1, self.poly) }

    -- perimeter coordinates, so the spider can walk the frame between two anchors
    self.cum, self.per = {}, 0
    for i = 1, #self.poly do
        local a, b = self.poly[i], self.poly[i % #self.poly + 1]
        self.cum[i] = self.per
        self.per = self.per + hypot(b[1] - a[1], b[2] - a[2])
    end

    -- spokes: straight up and straight down exist after the drop; the rest jittered around
    local n = 2 * math.random(7, 10)
    local gap = 2 * pi / n
    self.spokes = {}
    for j = 0, n - 1 do
        local a = -pi / 2 + j * gap
        if j ~= 0 and j ~= n / 2 then a = a + rnd(-0.28, 0.28) * gap end
        local dx, dy = math.cos(a), math.sin(a)
        local t, ei, s = ray_hit(self.hub[1], self.hub[2], dx, dy, self.poly)
        local e0, e1 = self.poly[ei], self.poly[ei % #self.poly + 1]
        self.spokes[j + 1] = {
            a = a, dx = dx, dy = dy, len = t,
            x = self.hub[1] + dx * t, y = self.hub[2] + dy * t,
            per = self.cum[ei] + s * hypot(e1[1] - e0[1], e1[2] - e0[2]),
        }
    end
    self.k_up, self.k_down = 1, n / 2 + 1

    self.threads = { frame = {}, hub = {}, aux = {}, capture = {} }
    self.tight = {}           -- freshly fastened threads still pulling taut (drawn as curves)
    self.dirty = { frame = true, hub = true, aux = true, capture = true }
    self.static = {}
    self.fade, self.drawn_fade = 1, 1
    self.T = 0
    self.sp = { x = self.T1[1], y = -self.L * 1.5, h = pi / 2, gait = 0, hang = true, ph = rnd(0, 6) }
    self.co = coroutine.create(function() self:program() end)
    return self
end

-- point at perimeter coordinate p
function W_:per_point(p)
    p = p % self.per
    for i = #self.poly, 1, -1 do
        if p >= self.cum[i] then
            local a, b = self.poly[i], self.poly[i % #self.poly + 1]
            local len = hypot(b[1] - a[1], b[2] - a[2])
            local t = len > 0 and (p - self.cum[i]) / len or 0
            return { lerp(a[1], b[1], t), lerp(a[2], b[2], t) }
        end
    end
end

-- waypoints along the frame from perimeter coordinate p1 to p2, the short way round
function W_:per_path(p1, p2)
    local P = self.per
    local fwd = (p2 - p1) % P
    local pts = {}
    if fwd <= P / 2 then
        for i = 1, #self.poly do
            local d = (self.cum[i] - p1) % P
            if d > 1e-6 and d < fwd then pts[#pts + 1] = { d, self.poly[i] } end
        end
    else
        local back = P - fwd
        for i = 1, #self.poly do
            local d = (p1 - self.cum[i]) % P
            if d > 1e-6 and d < back then pts[#pts + 1] = { d, self.poly[i] } end
        end
    end
    table.sort(pts, function(a, b) return a[1] < b[1] end)
    local out = {}
    for _, p in ipairs(pts) do out[#out + 1] = p[2] end
    out[#out + 1] = self:per_point(p2)
    return out
end

function W_:add_thread(kind, x1, y1, x2, y2, sag)
    local t = { x1, y1, x2, y2, kind = kind, sag = sag or 0 }
    if t.sag > 0.5 then self.tight[#self.tight + 1] = t
    else
        local list = self.threads[kind]
        list[#list + 1] = t
        self.dirty[kind] = true
    end
    return t
end

-- ── the building program (runs as a coroutine, resumed with dt every tick) ──

function W_:program()
    local sp, L, H = self.sp, self.L, self.H
    local hub = self.hub

    local function step() return coroutine.yield() end
    local function pause(t) local e = 0 t = t * 1.4 while e < t do e = e + step() end end
    local function turn(target, dt, rate)
        local d = (target - sp.h + pi) % (2 * pi) - pi
        local m = (rate or 7) * dt
        sp.h = sp.h + math.max(-m, math.min(m, d))
        return math.abs(d) < 0.02
    end
    local function move(tx, ty, o)
        o = o or {}
        while true do
            local dx, dy = tx - sp.x, ty - sp.y
            local d = hypot(dx, dy)
            if d < 0.01 then sp.x, sp.y = tx, ty break end
            local dt = step()
            if not o.steady and math.random() < dt * 0.06 then pause(rnd(0.3, 1.3)) end
            -- spiders go in bursts: speed swells and drops
            local v = self.speed * (o.v or 1) * (0.5 + (0.5 + 0.5 * math.sin(self.T * 1.7 + sp.ph)))
            local s = math.min(d, v * dt)
            sp.x, sp.y = sp.x + dx / d * s, sp.y + dy / d * s
            turn(o.heading or math.atan2(dy, dx), dt)
            sp.gait = sp.gait + s / (L * 0.45)
            if o.each then o.each() end
        end
    end
    local function walk(pts, o) for _, p in ipairs(pts) do move(p[1], p[2], o) end end
    local function bob(t)   -- dangling after a stop: a little spring bounce, a slow twist
        local y0, h0, e = sp.y, sp.h, 0
        local spin = rnd(-0.35, 0.35)
        while e < t do
            e = e + step()
            sp.y = y0 + H * 0.006 * math.exp(-3 * e) * math.sin(13 * e)
            sp.h = h0 + spin * math.sin(e * 0.8)
        end
        sp.y, sp.h = y0, h0
    end
    local function face(target)
        while not turn(target, step(), 3) do end
    end

    -- hang from (px, py), lower in stages to the length that reaches the wall at height gy,
    -- pump a swing until the wall is in reach and catch it: a new frame line
    local function swing_to(px, py, gy)
        local ell = hypot(px, gy - py)
        sp.drag, sp.hang = { px, py }, true
        face(pi / 2)
        while sp.y < py + ell - 0.5 do
            move(px, math.min(py + ell, sp.y + H * rnd(0.04, 0.12)), { heading = pi / 2, v = 0.4, steady = true })
            bob(rnd(0.8, 2.5))
        end
        pause(rnd(1.5, 4))
        local reach = math.atan2(px, gy - py)
        local period = 2.1 * math.sqrt(ell / (0.4 * H))
        local amp, tt = 0.03, 0
        while true do
            local dt = step()
            tt = tt + dt
            amp = amp + dt * reach / (4 * period)
            local phi = amp * math.sin(2 * pi * tt / period)
            sp.x, sp.y = px - ell * math.sin(phi), py + ell * math.cos(phi)
            sp.h = math.atan2(math.cos(phi), -math.sin(phi))      -- head away from the pivot
            sp.gait = sp.gait + dt * 0.8                          -- legs paddling
            if phi >= reach then break end
        end
        sp.x, sp.y, sp.drag, sp.hang = 0, gy, nil, false
        return self:add_thread("frame", px, py, 0, gy, ell * 0.05)
    end

    -- walk thread t from its wall end (t[3], t[4]) to (x, y), reeling it in behind
    local function reel(t, x, y)
        local frame = self.threads.frame
        for i = #frame, 1, -1 do
            if frame[i] == t then table.remove(frame, i); self.dirty.frame = true end
        end
        local listed = false
        for _, u in ipairs(self.tight) do listed = listed or u == t end
        if not listed then self.tight[#self.tight + 1] = t end
        t.live, t.sag = true, 0
        move(x, y, { each = function() t[3], t[4] = sp.x, sp.y end })
        t[3], t[4], t.live = x, y, false
    end

    -- 1. down from the ceiling on a dragline, swing to the side wall: the bridge.
    --    Then sink from the outer line and swing to the wall lower down, once or twice.
    local edge = swing_to(self.T1[1], 0, self.L1[2])
    pause(rnd(2, 4))
    for _, m in ipairs(self.moor) do
        reel(edge, m.B[1], m.B[2])
        pause(rnd(1, 2.5))
        edge = swing_to(m.B[1], m.B[2], m.G[2])
        pause(rnd(2, 4))
    end

    -- 2. up the wall; often a line across the corner, then along the ceiling to the drop point
    if self.cut then
        local k1, k2 = self.cut[1], self.cut[2]
        move(0, k2)
        pause(rnd(0.5, 1.5))
        sp.drag = { 0, k2, slack = true }
        walk({ { 0, 0 }, { k1, 0 } })
        sp.drag = nil
        self:add_thread("frame", 0, k2, k1, 0, hypot(k1, k2) * 0.15)
        pause(rnd(0.5, 1.5))
    else
        move(0, 0)
    end
    move(self.drop, 0)
    pause(rnd(1, 2.5))

    -- 3. drop through the hub onto the bridge, climb back to the hub
    sp.drag, sp.hang = { self.drop, 0 }, true
    face(pi / 2)
    move(self.drop, self.D[2], { heading = pi / 2, v = 0.45, steady = true })
    sp.drag, sp.hang = nil, false
    self:add_thread("frame", self.drop, 0, self.D[1], self.D[2], 0)
    pause(rnd(0.6, 1.5))
    move(hub[1], hub[2], { heading = -pi / 2 })
    pause(rnd(1, 2))

    -- 4. spokes, filling the widest gap first (real spiders balance the pull that way)
    local spokes = self.spokes
    local built = { [self.k_up] = true, [self.k_down] = true }
    while true do
        local best, bestg = nil, -1
        for k, s in ipairs(spokes) do
            if not built[k] then
                local g = math.huge
                for b in pairs(built) do
                    g = math.min(g, math.abs((s.a - spokes[b].a + pi) % (2 * pi) - pi))
                end
                g = g * rnd(0.85, 1.15)
                if g > bestg then best, bestg = k, g end
            end
        end
        if not best then break end
        local to = spokes[best]
        local from, fd = nil, math.huge
        for b in pairs(built) do
            local d = (to.per - spokes[b].per) % self.per
            d = math.min(d, self.per - d)
            if d < fd then from, fd = b, d end
        end
        sp.drag = { hub[1], hub[2], slack = true }
        move(spokes[from].x, spokes[from].y)
        walk(self:per_path(spokes[from].per, to.per))
        sp.drag = nil
        self:add_thread("frame", hub[1], hub[2], to.x, to.y, to.len * 0.08)
        built[best] = true
        pause(rnd(0.3, 1))
        move(hub[1], hub[2])
        pause(rnd(0.3, 1.5))
    end

    -- spirals: a point on spoke k at radius r, a little irregular
    local n = #spokes
    local function at(k, r, jit)
        local s = spokes[(k - 1) % n + 1]
        r = math.min(r, s.len * 0.96) + (jit or 0)
        return hub[1] + s.dx * r, hub[2] + s.dy * r
    end
    local function spiral(kind, steps, radius, k0, on_point, faults, v)
        local px, py
        for i = 0, steps do
            local k = (k0 + i - 1) % n + 1
            local r, jit = radius(i, k)
            local x, y = at(k, r, jit)
            if px then
                sp.drag = { px, py }
                move(x, y, { v = v or 1.3 })
                if math.random() >= (faults or 0) then self:add_thread(kind, px, py, x, y) end
            else
                move(x, y)
            end
            if on_point then on_point(k, r) end
            px, py = x, y
            pause(rnd(0.05, 0.22))   -- fastening at the crossing
        end
        sp.drag = nil
    end

    -- 5. hub turns, then the temporary spiral outwards
    -- every spiral uses the same rule: a fixed fraction of each spoke's length per turn
    local function turns(fa, df, dir)
        return function(i, k)
            local len = math.min(spokes[k].len, self.rin * 1.7)
            return len * (fa + dir * df * i / n), len * df * rnd(-0.12, 0.12)
        end
    end
    local h0, h1, dh = rnd(0.04, 0.06), rnd(0.12, 0.16), rnd(0.025, 0.035)
    spiral("hub", floor((h1 - h0) / dh * n), turns(h0, dh, 1), math.random(n), nil, 0, 0.8)
    pause(rnd(1, 3))
    local aux_turns = rnd(3.5, 5)
    local aux_by = {}
    local fa0, fa1 = rnd(0.2, 0.26), rnd(0.8, 0.86)
    spiral("aux", floor(aux_turns * n), turns(fa0, (fa1 - fa0) / aux_turns, 1), math.random(n), function(k, r)
            local list = self.threads.aux
            if #list > 0 then
                local seg = list[#list]
                seg.r = seg.r or r
                aux_by[k] = aux_by[k] or {}
                table.insert(aux_by[k], seg)
            end
        end)
    pause(rnd(2, 4))

    -- 6. capture spiral from the outside in; the temporary spiral is eaten where it is passed
    local f0, f1 = rnd(0.86, 0.93), rnd(0.2, 0.3)
    local df = rnd(0.032, 0.05)
    local cap_steps = floor((f0 - f1) / df * n)
    local k0 = math.random(n)
    spiral("capture", cap_steps, turns(f0, df, -1), k0, function(k, r)
        for _, seg in ipairs(aux_by[k] or {}) do
            if not seg.dead and seg.r and seg.r > r then seg.dead = true; self.dirty.aux = true end
        end
    end, 0.02)
    for _, seg in ipairs(self.threads.aux) do seg.dead = true end   -- the last bits of the temporary spiral
    self.dirty.aux = true

    -- 7. into the hub, head down, and wait
    move(hub[1], hub[2])
    face(pi / 2)
    self.built = true
    require("mp.msg").verbose(string.format("web in the %s corner built in %d s", self.corner, self.T))
    local waited = 0
    while waited < self.stay do
        local t = rnd(4, 20)
        pause(t)
        waited = waited + t
        local g0 = sp.gait                      -- a twitch of the legs now and then
        local e = 0
        while e < 0.4 do e = e + step(); sp.gait = g0 + e * 3 end
    end

    -- leave by the top spoke, then the web fades
    local up = spokes[self.k_up]
    move(up.x, up.y)
    move(up.x, -L * 2)
    sp.gone = true
    local e = 0
    while e < 12 do e = e + step(); self.fade = 1 - e / 12 end
end

-- advance by dt; false when the web is gone
function W_:update(dt)
    self.T = self.T + dt
    for i = #self.tight, 1, -1 do
        local t = self.tight[i]
        t.sag = t.sag * math.exp(-dt * 2.5)
        if t.sag < 0.5 and not t.live then
            table.remove(self.tight, i)
            t.sag = 0
            local list = self.threads[t.kind]
            list[#list + 1] = t
            self.dirty[t.kind] = true
        end
    end
    if coroutine.status(self.co) == "dead" then return false end
    local ok, err = coroutine.resume(self.co, dt)
    if not ok then
        require("mp.msg").error("weaver: " .. tostring(err))
        return false
    end
    return coroutine.status(self.co) ~= "dead"
end

-- ── drawing ────────────────────────────────────────────────────────────────

-- corner coordinates → ASS drawing coordinates (\p3: quarter pixels)
function W_:pt(u, v)
    local x = self.flip and (self.W - u) or u
    return string.format("%d %d", floor(x * 4 + 0.5), floor(v * 4 + 0.5))
end

function W_:line(t)
    if (t.sag or 0) < 0.5 then
        return "m " .. self:pt(t[1], t[2]) .. " l " .. self:pt(t[3], t[4]) .. " "
    end
    -- sagging: a curve there and back again (a drawing closes itself, a curve must not)
    local x1, y1, x2, y2, s = t[1], t[2], t[3], t[4], t.sag * 1.33
    local c1 = self:pt(lerp(x1, x2, 1 / 3), lerp(y1, y2, 1 / 3) + s)
    local c2 = self:pt(lerp(x1, x2, 2 / 3), lerp(y1, y2, 2 / 3) + s)
    local a, b = self:pt(x1, y1), self:pt(x2, y2)
    return "m " .. a .. " b " .. c1 .. " " .. c2 .. " " .. b .. " b " .. c2 .. " " .. c1 .. " " .. a .. " "
end

function W_:event(kind, path)
    local st, sc = STYLE[kind], self.H / 1080
    local alpha = 255 - floor((255 - st.alpha) * self.fade)
    return string.format("{\\an7\\pos(0,0)\\bord%.2f\\shad%.2f\\1a&HFF&\\3c&HF2F2F2&\\3a&H%02X&" ..
        "\\4c&H000000&\\4a&H%02X&\\p3}%s{\\p0}", st.bord * sc, 0.7 * sc, alpha,
        math.min(255, alpha + 0x60), path)
end

-- the spider, seen from above: two body parts and eight jointed legs in a tetrapod gait
function W_:spider()
    local sp, L = self.sp, self.L
    local x, y = sp.x, sp.y
    if not sp.hang then  -- on a wall the body stays on screen
        x, y = math.max(x, L * 0.45), math.max(y, L * 0.45)
    end
    local fx, fy = math.cos(sp.h), math.sin(sp.h)
    local function P(a, b) return self:pt(x + fx * a - fy * b, y + fy * a + fx * b) end
    local legs = {}
    local cx = 0.15 * L
    local base = { 0.55, 1.2, 1.95, 2.55 }
    for _, side in ipairs({ 1, -1 }) do
        for i = 1, 4 do
            local grp = (i + (side == 1 and 0 or 1)) % 2
            local a = base[i] + 0.22 * math.sin(sp.gait * pi + grp * pi)
            local len = L * 0.8
            if sp.hang then a = a * 0.82 + 0.15; len = L * 0.68 end
            local bend = i <= 2 and -0.5 or 0.5
            local kx, ky = cx + math.cos(a) * len, side * math.sin(a) * len
            local ex, ey = kx + math.cos(a + bend) * len * 1.1, ky + side * math.sin(a + bend) * len * 1.1
            local b0, k, e = P(cx, 0), P(kx, ky), P(ex, ey)
            legs[#legs + 1] = "m " .. b0 .. " l " .. k .. " l " .. e .. " l " .. k
        end
    end
    local function oval(ox, rx, ry)
        local p = {}
        for j = 0, 11 do
            local t = j / 12 * 2 * pi
            p[#p + 1] = P(ox + math.cos(t) * rx, math.sin(t) * ry)
        end
        return "m " .. p[1] .. " l " .. table.concat(p, " ", 2)
    end
    local sc = self.H / 1080
    return {
        string.format("{\\an7\\pos(0,0)\\bord%.2f\\shad%.2f\\4c&HB0B8C0&\\4a&HB0&\\1a&HFF&\\3c&H1C2228&\\p3}%s{\\p0}",
            math.max(0.45 * sc, L * 0.045), 0.8 * sc, table.concat(legs, " ")),
        string.format("{\\an7\\pos(0,0)\\bord%.2f\\shad0\\1c&H2A4E72&\\3c&H8090A0&\\3a&H90&\\p3}%s{\\p0}",
            0.7 * sc, oval(-0.3 * L, 0.36 * L, 0.29 * L)),
        string.format("{\\an7\\pos(0,0)\\bord%.2f\\shad0\\1c&H1E2A36&\\3c&H8090A0&\\3a&H90&\\p3}%s{\\p0}",
            0.7 * sc, oval(0.17 * L, 0.24 * L, 0.19 * L)),
    }
end

-- append this web's ASS events to out; the moving parts are redrawn at most hz times a second
function W_:render(now, out, hz)
    local fade = floor(self.fade * 20 + 0.5) / 20
    for _, kind in ipairs(KINDS) do
        if self.dirty[kind] or fade ~= self.drawn_fade then
            local parts = {}
            for _, t in ipairs(self.threads[kind]) do
                if not t.dead then parts[#parts + 1] = self:line(t) end
            end
            self.static[kind] = #parts > 0 and self:event(kind, table.concat(parts)) or nil
            self.dirty[kind] = false
        end
    end
    self.drawn_fade = fade
    for _, kind in ipairs(KINDS) do
        if self.static[kind] then out[#out + 1] = self.static[kind] end
    end

    if not self.dyn or now >= (self.next_dyn or 0) then
        self.next_dyn = now + 1 / (hz or 15)
        local dyn, parts = {}, {}
        for _, t in ipairs(self.tight) do parts[#parts + 1] = self:line(t) end
        local sp = self.sp
        if sp.drag then   -- the thread coming out of the spinnerets
            local rx, ry = sp.x - math.cos(sp.h) * self.L * 0.62, sp.y - math.sin(sp.h) * self.L * 0.62
            local sag = sp.drag.slack and hypot(rx - sp.drag[1], ry - sp.drag[2]) * 0.06 or 0
            parts[#parts + 1] = self:line({ sp.drag[1], sp.drag[2], rx, ry, sag = sag })
        end
        if #parts > 0 then dyn[#dyn + 1] = self:event("frame", table.concat(parts)) end
        if not sp.gone then
            for _, e in ipairs(self:spider()) do dyn[#dyn + 1] = e end
        end
        self.dyn = dyn
    end
    for _, e in ipairs(self.dyn) do out[#out + 1] = e end
end

return { new = new_web }
