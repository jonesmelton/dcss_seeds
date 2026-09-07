#!/usr/bin/env lua
-- Render a seed_dump.lua JSONL catalog as Markdown.
--
-- Runs under a standalone lua interpreter; it does not need crawl. Keeping
-- rendering separate from generation means the report can be reformatted
-- without regenerating the dungeon, which is the slow part.
--
--   util/fake_pty ./crawl -script seed_dump.lua -seed 1234 > seed.jsonl 2>&1
--   lua scripts/render_seed_report.lua seed.jsonl > seed.md
--
-- Reads stdin when no file is given.

------------------------------------------------------------------
-- Minimal JSON reader. Only handles the shapes seed_dump.lua emits:
-- a flat object of string/number/boolean values.

local unescapes = {
    ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b',
    f = '\f', n = '\n', r = '\r', t = '\t',
}

local function parse_string(s, i)
    local buf = {}
    while i <= #s do
        local c = s:sub(i, i)
        if c == '"' then
            return table.concat(buf), i + 1
        elseif c == '\\' then
            local e = s:sub(i + 1, i + 1)
            if e == 'u' then
                local hex = s:sub(i + 2, i + 5)
                local n = tonumber(hex, 16)
                -- dump only emits \u for control characters
                buf[#buf + 1] = n and string.char(n % 256) or ''
                i = i + 6
            else
                buf[#buf + 1] = unescapes[e] or e
                i = i + 2
            end
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end
    error("unterminated string")
end

local function parse_object(line)
    local obj = {}
    local i = line:find("{")
    if not i then return nil end
    i = i + 1
    while i <= #line do
        local c = line:sub(i, i)
        if c == '}' then break end
        if c:match("%s") or c == ',' then
            i = i + 1
        elseif c == '"' then
            local key, ni = parse_string(line, i + 1)
            ni = line:find(":", ni) + 1
            while line:sub(ni, ni):match("%s") do ni = ni + 1 end
            local vc = line:sub(ni, ni)
            local value
            if vc == '"' then
                value, ni = parse_string(line, ni + 1)
            else
                local literal = line:match("[^,}]+", ni)
                local trimmed = literal:match("^%s*(.-)%s*$")
                if trimmed == "true" then value = true
                elseif trimmed == "false" then value = false
                elseif trimmed == "null" then value = nil
                else value = tonumber(trimmed) end
                ni = ni + #literal
            end
            obj[key] = value
            i = ni
        else
            i = i + 1
        end
    end
    return obj
end

------------------------------------------------------------------
-- depth bands

local bands = {
    { name = "Early (D:1-D:4)",      first = "D:1",     last = "D:4" },
    { name = "Mid dungeon (D:5-D:8)",first = "D:5",     last = "D:8" },
    { name = "Late dungeon (D:9+)",  first = "D:9",     last = "D:15" },
    { name = "Lair",                 first = "Lair:1",  last = "Lair:5" },
}

local portals = {
    Sewer = true, Ossuary = true, IceCv = true, Volcano = true,
    Bailey = true, Gauntlet = true, Bazaar = true, WizLab = true,
    Desolation = true,
}

local function band_for(rec)
    -- Temple and portals carry gendepths outside the linear D/Lair run;
    -- group them by name rather than forcing them into a band.
    local lvl = rec.level or ""
    if lvl == "Temple" then return "Temple" end
    if portals[lvl] then return "Portals" end
    for _, b in ipairs(bands) do
        local branch, num = lvl:match("^(%a+):(%d+)$")
        if branch then
            local fb, fn = b.first:match("^(%a+):(%d+)$")
            local _, ln = b.last:match("^(%a+):(%d+)$")
            if branch == fb and tonumber(num) >= tonumber(fn)
               and tonumber(num) <= tonumber(ln) then
                return b.name
            end
        end
    end
    return "Other (" .. (lvl:match("^(%a+)") or "misc") .. ")"
end

------------------------------------------------------------------

local function read_all(path)
    local fh = path and assert(io.open(path, "r")) or io.stdin
    local recs = {}
    for line in fh:lines() do
        -- crawl banners and vault warnings share the stream; skip non-JSON
        if line:match("^%s*{") then
            local ok, rec = pcall(parse_object, line)
            if ok and rec and rec.seed then recs[#recs + 1] = rec end
        end
    end
    if path then fh:close() end
    return recs
end

local function group(recs)
    local seeds, order = {}, {}
    for _, r in ipairs(recs) do
        local s = tostring(r.seed)
        if not seeds[s] then
            seeds[s] = { levels = {}, level_order = {} }
            order[#order + 1] = s
        end
        local sd = seeds[s]
        local lvl = r.level or "?"
        if not sd.levels[lvl] then
            sd.levels[lvl] = { items = {}, features = {}, vaults = {}, monsters = {},
                               gendepth = r.gendepth or 0, from = r.from }
            sd.level_order[#sd.level_order + 1] = lvl
        end
        local ld = sd.levels[lvl]
        if r.cat == "item" then ld.items[#ld.items + 1] = r
        elseif r.cat == "feature" then ld.features[#ld.features + 1] = r
        elseif r.cat == "vault" then ld.vaults[#ld.vaults + 1] = r
        elseif r.cat == "monster" then ld.monsters[#ld.monsters + 1] = r end
    end
    return seeds, order
end

local function fmt_item(r)
    local s = "`" .. (r.name or "?") .. "`"
    if r.price then s = s .. " — shop, **" .. r.price .. "** gold" end
    if r.holder then s = s .. " — carried by **" .. r.holder .. "**" end
    if r.artefact then s = s .. " _(artefact)_" end
    return s
end

-- Group identical lines into "... x3", preserving first-seen order within
-- each sort bucket.
local function collapse(lines)
    local counts, order = {}, {}
    for _, l in ipairs(lines) do
        if counts[l] then
            counts[l] = counts[l] + 1
        else
            counts[l] = 1
            order[#order + 1] = l
        end
    end
    local out_lines = {}
    for _, l in ipairs(order) do
        out_lines[#out_lines + 1] =
            counts[l] > 1 and (l .. " ×" .. counts[l]) or l
    end
    return out_lines
end

-- artefacts, then shop stock, then unique-carried gear, then floor loot
local function item_rank(r)
    if r.artefact then return 1 end
    if r.price then return 2 end
    if r.holder then return 3 end
    return 4
end

local out = io.stdout
local recs = read_all(arg[1])
local seeds, order = group(recs)

out:write("# Seed catalog\n\n")
if #recs == 0 then
    out:write("_No records found._\n")
    os.exit(0)
end

for _, s in ipairs(order) do
    local sd = seeds[s]
    out:write("## Seed `" .. s .. "`\n\n")

    -- portals carry a negative gendepth; sort them after the main dungeon
    -- rather than before it
    table.sort(sd.level_order, function (a, b)
        local ga, gb = sd.levels[a].gendepth, sd.levels[b].gendepth
        if (ga < 0) ~= (gb < 0) then return gb < 0 end
        if ga < 0 then return -ga < -gb end
        return ga < gb
    end)

    local cur_band = nil
    for _, lvl in ipairs(sd.level_order) do
        local ld = sd.levels[lvl]
        local band = band_for({ level = lvl })

        local n = #ld.items + #ld.features + #ld.monsters
        if n > 0 then
            if band ~= cur_band then
                out:write("### " .. band .. "\n\n")
                cur_band = band
            end
            local heading = lvl
            if ld.from then heading = heading .. " _(from " .. ld.from .. ")_" end
            out:write("**" .. heading .. "**\n\n")

            table.sort(ld.items, function (a, b)
                local ra, rb = item_rank(a), item_rank(b)
                if ra ~= rb then return ra < rb end
                return (a.name or "") < (b.name or "")
            end)
            local item_lines = {}
            for _, r in ipairs(ld.items) do
                item_lines[#item_lines + 1] = fmt_item(r)
            end
            for _, l in ipairs(collapse(item_lines)) do
                out:write("- " .. l .. "\n")
            end

            local feat_lines = {}
            for _, r in ipairs(ld.features) do
                feat_lines[#feat_lines + 1] = r.name or r.feat
            end
            table.sort(feat_lines)
            for _, l in ipairs(collapse(feat_lines)) do
                out:write("- " .. l .. "\n")
            end

            local mons_lines = {}
            for _, r in ipairs(ld.monsters) do
                mons_lines[#mons_lines + 1] = "**" .. (r.mons_name or "?") .. "**"
            end
            table.sort(mons_lines)
            for _, l in ipairs(collapse(mons_lines)) do
                out:write("- " .. l .. "\n")
            end
            out:write("\n")
        end
    end
end
