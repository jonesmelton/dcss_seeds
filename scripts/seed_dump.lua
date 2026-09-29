-- Structured (JSONL) seed catalog, for downstream tooling.
--
-- Unlike seed_explorer.lua, which formats a human-readable digest, this emits
-- one JSON object per line describing each notable item, feature and vault,
-- tagged with the level and generation depth it was found at. Portals
-- (Volcano, Bazaar, ...) are included, flagged with "portal":true and a
-- negative gendepth.
--
-- Requires a debug/profile build plus fake_pty; see seed_explorer.lua.
--   util/fake_pty ./crawl -script seed_dump.lua -seed 1234 > seed.jsonl 2>&1
--
-- All script output under fake_pty goes to stderr, hence the 2>&1 above. Lines
-- that are not JSON objects (crawl banners, vault warnings) may be interleaved,
-- so the reader skips any line not beginning with '{'.
--
-- Usage: seed_dump.lua -seed <seed> [<seed> ...] [-count <n>] [-depth <depth>]
--                      [-all-items] [-artefacts]
--   <seed>:      a number, or 'random'.
--   <n>:         iterate n seeds from <seed>.
--   <depth>:     level/branch short form (default D:8).
--   -all-items:  include items the stock filter discards (plain gear,
--                missiles, gold). Off by default.
--   -artefacts:  restrict to artefacts only.

crawl_require('dlua/explorer.lua')

local basic_usage = [=[
Usage: seed_dump.lua -seed <seed> ([<seed> ...]|[-count <n>]) [-depth <depth>]
                     [-all-items] [-artefacts]
    <seed>:   a number, or 'random'.
    <n>:      number of seeds to iterate from <seed>.
    <depth>:  a level or branch in short form, e.g. `Lair:5`, `D`, a number,
              or 'all'. Defaults to D:8 (early game, before Lair).
    -all-items: include items the default notability filter discards.
    -artefacts: restrict items to artefacts only.
    -mon-items:    also collect items carried by monsters.
    -unique-items: also collect items carried by uniques only.]=]

local function usage_error(extra)
    local err = basic_usage
    if extra ~= nil then err = err .. "\n" .. extra end
    script.usage(err)
end

------------------------------------------------------------------
-- JSON encoding. Crawl bundles Lua 5.4 with no JSON library.

local escapes = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b',
    ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function json_quote(s)
    s = string.gsub(s, '[%c"\\]', function (c)
        return escapes[c] or string.format('\\u%04x', string.byte(c))
    end)
    return '"' .. s .. '"'
end

local json_value
json_value = function (v)
    local t = type(v)
    if v == nil then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        -- avoid locale-dependent and float-formatted integers
        if v == math.floor(v) then return string.format("%d", v) end
        return string.format("%.14g", v)
    end
    if t == "table" then
        if #v > 0 then
            local parts = {}
            for _, e in ipairs(v) do parts[#parts + 1] = json_quote(tostring(e)) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        -- string-keyed map (artprops); sort so output is stable across runs
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        if #keys == 0 then return "null" end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = json_quote(k) .. ":" .. json_value(v[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return json_quote(tostring(v))
end

-- Emit keys in a stable order so the output diffs cleanly between runs.
local function json_object(keys, tbl)
    local parts = {}
    for _, k in ipairs(keys) do
        local v = tbl[k]
        if v ~= nil then
            parts[#parts + 1] = json_quote(k) .. ":" .. json_value(v)
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local record_keys = {
    "seed", "cat", "level", "gendepth", "branch", "portal", "from", "x", "y",
    "name", "base", "sub", "ego", "plus", "quantity",
    "artefact", "branded", "useless", "shop", "price", "holder", "holder_unique",
    "spells", "artprops", "weap_skill", "evoker",
    "unique", "mons_name",
    "feat", "vault",
}

local function emit(rec)
    crawl.stderr(json_object(record_keys, rec))
end

------------------------------------------------------------------
-- argument parsing (mirrors seed_explorer.lua)

local function parse_args(args)
    local accum_init, accum_params, cur = {}, {}, nil
    for _, a in ipairs(args) do
        if string.find(a, '-') == 1 then
            cur = a
            if accum_params[a] ~= nil then
                usage_error("Repeated argument '" .. a .. "'")
            end
            accum_params[a] = {}
        elseif cur == nil then
            accum_init[#accum_init + 1] = a
        else
            accum_params[cur][#accum_params[cur] + 1] = a
        end
    end
    return accum_init, accum_params
end

local function one_arg(args, a)
    if args[a] == nil or #(args[a]) ~= 1 then return nil end
    return args[a][1]
end

local arg_list = crawl.script_args()
local args_init, args = parse_args(arg_list)

if #arg_list == 0 or #args_init ~= 0 or args["-seed"] == nil
   or #(args["-seed"]) < 1 then
    usage_error("\nNo seed(s) supplied!")
end

local seed_seq = args["-seed"]

local count = 1
if args["-count"] ~= nil then
    count = tonumber(one_arg(args, "-count"))
    if count == nil then usage_error("\nInvalid argument to -count") end
end

if count > 1 then
    if seed_seq[1] == "random" then
        for _ = 2, count do seed_seq[#seed_seq + 1] = "random" end
    else
        local n = tonumber(seed_seq[1])
        for i = n + 1, n + count - 1 do seed_seq[#seed_seq + 1] = i end
    end
end

math.randomseed(crawl.millis())
for i, seed in ipairs(seed_seq) do
    if seed == "random" then seed_seq[i] = math.random(0x7FFFFFFF) end
end

local max_depth = explorer.level_to_gendepth("D:8")
if args["-depth"] ~= nil then
    max_depth = explorer.to_gendepth(one_arg(args, "-depth"))
    if max_depth == nil then
        usage_error("\n<depth> must be a level name/branch, a number, or 'all'!")
    end
end

local all_items = (args["-all-items"] ~= nil)
local arts_only = (args["-artefacts"] ~= nil)
if all_items and arts_only then
    usage_error("\n-all-items and -artefacts are not compatible.")
end

local mons_mode = nil
if args["-mon-items"] ~= nil then mons_mode = "all" end
if args["-unique-items"] ~= nil then mons_mode = "unique" end
if args["-mon-items"] ~= nil and args["-unique-items"] ~= nil then
    usage_error("\n-mon-items and -unique-items are not compatible.")
end

------------------------------------------------------------------
-- collection

explorer.reset_to_defaults()

-- Same wrapper as seed_dump_sexp.lua, for the same reason: item_ignore_boring
-- calls an unbranded +0 artefact plain gear and calls a barding useless.
local function item_notable_default(item)
    return item.artefact
        or item.sub_type == "barding"
        or explorer.item_ignore_boring(item)
end

local item_notable = item_notable_default
if all_items then item_notable = function (_) return true end end
if arts_only then item_notable = explorer.arts_only end

local cur_seed = nil
local cur_level = nil
local cur_gendepth = nil
local cur_from = nil

local function item_record(item, price)
    local ok, plus = pcall(function () return item.pluses() end)
    if type(plus) ~= "number" then plus = nil end
    return {
        seed = cur_seed, cat = "item",
        level = cur_level, gendepth = cur_gendepth, branch = you.branch(),
        portal = cur_gendepth < 0 or nil, from = cur_from,
        name = item.name(),
        base = item.base_type, sub = item.sub_type,
        ego = item.ego_type, plus = ok and plus or nil,
        quantity = item.quantity,
        artefact = item.artefact and true or false,
        branded = item.branded and true or false,
        useless = item.is_useless and true or false,
        shop = price ~= nil or nil, price = price,
        -- randart book contents are generated per seed, so the title alone
        -- says nothing about what is learnable
        spells = item.spells,
        artprops = item.artprops,
        weap_skill = item.weap_skill,
        evoker = item.is_xp_evoker and true or nil,
    }
end

-- dgn.items_at reads player map knowledge, so the level must be mapped first
-- or the floor comes back empty; shops read shop->stock directly and don't.
local function scan_position(p, prices)
    local stack = dgn.items_at(p.x, p.y)
    if stack then
        for _, item in ipairs(stack) do
            if item_notable(item) then
                local rec = item_record(item, nil)
                rec.x, rec.y = p.x, p.y
                emit(rec)
            end
        end
    end

    local shop = dgn.shop_inventory_at(p.x, p.y)
    if shop then
        local costs = assert(prices[p.x .. "," .. p.y])
        for i, entry in ipairs(shop) do
            if item_notable(entry[1]) then
                local rec = item_record(entry[1], costs[i])
                rec.x, rec.y = p.x, p.y
                emit(rec)
            end
        end
    end

    if mons_mode then
        local mons = dgn.mons_at(p.x, p.y)
        if mons and (mons_mode == "all" or mons.unique) then
            if mons.unique then
                emit({
                    seed = cur_seed, cat = "monster",
                    level = cur_level, gendepth = cur_gendepth,
                    branch = you.branch(),
                    portal = cur_gendepth < 0 or nil, from = cur_from,
                    x = p.x, y = p.y,
                    mons_name = mons.name, unique = true,
                })
            end
            for _, item in ipairs(mons.get_inventory()) do
                if item_notable(item) then
                    local rec = item_record(item, nil)
                    rec.x, rec.y = p.x, p.y
                    rec.holder = mons.name
                    rec.holder_unique = mons.unique and true or nil
                    emit(rec)
                end
            end
        end
    end

    local feat = dgn.feature_name(dgn.grid(p.x, p.y))
    if explorer.feat_notable(feat) then
        emit({
            seed = cur_seed, cat = "feature",
            level = cur_level, gendepth = cur_gendepth, branch = you.branch(),
        portal = cur_gendepth < 0 or nil, from = cur_from,
            x = p.x, y = p.y,
            feat = feat,
            name = dgn.feature_desc_at(p.x, p.y, "A"),
        })
    end
end

-- The price charged, read before wiz.identify_all_items(); see
-- seed_dump_sexp.lua, which has the same pass.
local function shop_prices()
    local prices = { }
    local gxm, gym = dgn.max_bounds()
    for p in iter.rect_iterator(dgn.point(1, 1), dgn.point(gxm - 2, gym - 2)) do
        local shop = dgn.shop_inventory_at(p.x, p.y)
        if shop then
            local costs = { }
            for i, entry in ipairs(shop) do costs[i] = entry[2] end
            prices[p.x .. "," .. p.y] = costs
        end
    end
    return prices
end

local function scan_level()
    local prices = shop_prices()

    -- must run per level: item.pluses() returns false, not a number, for
    -- unidentified items, and identification does not persist across levels.
    wiz.identify_all_items()

    for _, vault in ipairs(explorer.catalog_vaults()) do
        emit({
            seed = cur_seed, cat = "vault",
            level = cur_level, gendepth = cur_gendepth, branch = you.branch(),
        portal = cur_gendepth < 0 or nil, from = cur_from,
            vault = vault,
        })
    end

    local gxm, gym = dgn.max_bounds()
    for p in iter.rect_iterator(dgn.point(1, 1), dgn.point(gxm - 2, gym - 2)) do
        scan_position(p, prices)
    end
end

local function visit_level(lvl, gendepth, from)
    debug.goto_place(lvl)
    debug.generate_level()
    wiz.map_level()
    cur_level, cur_gendepth, cur_from = lvl, gendepth, from
    scan_level()
end

local function dump_seed(seed)
    cur_seed = debug.reset_rng(seed)

    dgn.reset_level()
    -- renamed from flush_map_memory after 0.32; support both so one script
    -- can run against version-specific builds
    ;(debug.reset_player_data or debug.flush_map_memory)()
    debug.dungeon_setup()

    you.enter_wizard_mode()

    for i, lvl in ipairs(explorer.generation_order) do
        if i > max_depth then break end
        if crawl.seen_hups() > 0 then break end
        if dgn.br_exists(string.match(lvl, "[^:]+")) then
            visit_level(lvl, i)

            -- portals (Volcano, Bazaar, ...) hang off the level that holds
            -- their entrance, and are not in generation_order
            for j, port in ipairs(explorer.portal_order) do
                if crawl.seen_hups() > 0 then break end
                if you.where() == dgn.level_name(dgn.br_entrance(port)) then
                    visit_level(port, -j, lvl)
                    debug.goto_place(lvl)
                end
            end
        end
    end
end

for _, seed in ipairs(seed_seq) do
    if crawl.seen_hups() > 0 then break end
    dump_seed(seed)
end

if crawl.seen_hups() > 0 then
    crawl.stderr("Aborting! ")
end

explorer.reset_to_defaults()
