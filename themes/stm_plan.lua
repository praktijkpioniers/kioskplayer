-- St Maarten: what makes sense to put on next (the engine's gag planner asks: hooks.gag_use).
-- theme.json "planner": {group: "act"} - one act at a time on each screen, a few lined up; this
-- weighs them by what's about here: St Martin wants a beggar sitting in the cold, the church
-- beggars to take in, the houses and the bonfire children to come by, a procession or the school
-- few children about. The big floor acts (the island, the border walk) and the buildings are
-- rarer over a video. Returns nil for anything else (the engine's own sense then).

local P = {}
local E

local function count(stm, test)
    local n = 0
    for _, b in ipairs(E.actors()) do
        if b.stm == stm and not b.dead and not b.leaving and not b.gone and (not test or test(b)) then n = n + 1 end
    end
    return n
end
local function cold(b) return b.sitting and not b.warm and not b.claimed end

local USE = {
    martin = function()
        if E.room().taken["chr:martin"] or count("martin") > 0 then return 0, "St Martin elsewhere" end
        if count("beggar", cold) > 0 then return 2.5, "a beggar in the cold" end
        return 0.8
    end,
    church = function(video)
        local u, why = 1, nil
        if count("beggar", cold) > 0 then u, why = 2, "beggars to take in" end
        return u * (video and 0.4 or 1), why
    end,
    school = function(video)
        local k = count("kid")
        local u = k <= 1 and 1.5 or (k >= 4 and 0.4 or 1)
        return u * (video and 0.4 or 1), k <= 1 and "few children about" or nil
    end,
    kid = function()            -- (the procession: the casual kids are no act)
        local k = count("kid")
        return k <= 1 and 1.5 or (k >= 4 and 0.4 or 1), k <= 1 and "few children about" or nil
    end,
    stm_house = function(video)
        local u = count("kid") > 0 and 1.8 or 0.7
        return u * (video and 0.6 or 1), u > 1 and "children about" or nil
    end,
    stm_bonfire = function(video)
        return (count("kid") > 0 and 1.3 or 0.8) * (video and 0.6 or 1)
    end,
    stm_cow = function() return count("kid") > 0 and 1.4 or 0.9 end,
    stm_geese = function()
        if count("martin", function(b) return (b.stage or 0) <= 2 end) > 0 then return 1.5, "St Martin about" end
        return 1
    end,
    stm_teens = function(video) return video and 0.5 or 1 end,
    stm_border = function(video)
        local busy = count("church") + count("school") + count("house") > 0
        return (busy and 0.3 or 1) * (video and 0.3 or 1), busy and "the floor taken" or nil
    end,
    stm_island = function(video)
        local busy = count("church") + count("school") + count("house") > 0
        return (busy and 0.3 or 1) * (video and 0.3 or 1), busy and "the floor taken" or nil
    end,
}

function P.install(api)
    E = api
    return function(el, mode)
        local f = USE[el.type]
        if not f or not (E.M() and E.M().planner and E.M().planner.group == "act") then return nil end
        return f(mode == "video")
    end
end

return P
