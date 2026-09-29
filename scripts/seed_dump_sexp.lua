-- Structured seed dump for bulk ingestion.
--
-- Emits one s-expression per level to stderr, each on a single line prefixed
-- with "#SEED#". Everything crawl writes that is not so prefixed is noise and
-- should be discarded by the consumer.
--
-- The lua sandbox has no io or os library, so writing files directly is not
-- possible; the caller is expected to redirect and filter, e.g.
--   util/fake_pty ./crawl -script seed_dump_sexp.lua -seed 1 -count 100 2>&1 \
--     | grep '^#SEED#'
--
-- usage: seed_dump_sexp.lua -seed <seed> [<seed> ...] [-count <n>]
--                           [-depth <depth>] [-all-items] [-artefacts]
--                           [-mon-items]
--
-- Crawl's own explorer.catalog_dungeon returns formatted display strings, not
-- structured entries, so this runs the same cell scan seed_dump.lua does and
-- groups the records per level. See docs/extraction.md.

crawl_require('dlua/explorer.lua')

local FORMAT = 4
local PREFIX = "#SEED#"

local function parse_args(args)
    local params = { }
    local cur = nil
    for _, a in ipairs(args) do
        if string.find(a, '-') == 1 then
            cur = a
            params[a] = { }
        elseif cur ~= nil then
            table.insert(params[cur], a)
        end
    end
    return params
end

local function one_arg(args, a)
    if args[a] == nil or #(args[a]) ~= 1 then return nil end
    return args[a][1]
end

-- s-expression escaping: strings are the only thing needing care, and item
-- names contain quotes, braces and backslashes.
local function quote(s)
    s = string.gsub(tostring(s), '([\\"])', '\\%1')
    s = string.gsub(s, '\n', '\\n')
    return '"' .. s .. '"'
end

local function atom(v)
    local t = type(v)
    if v == nil then return "nil" end
    if t == "boolean" then return v and "t" or "nil" end
    if t == "number" then
        -- avoid lua's %g rendering integers as 1e+09
        if v == math.floor(v) then return string.format("%d", v) end
        return tostring(v)
    end
    return quote(v)
end

local sexp

local function field(k, v)
    if v == nil then return nil end
    return "(" .. k .. " " .. sexp(v) .. ")"
end

sexp = function(v)
    if type(v) ~= "table" then return atom(v) end
    -- array of records
    if #v > 0 or next(v) == nil then
        local parts = { }
        for _, e in ipairs(v) do table.insert(parts, sexp(e)) end
        return "(" .. table.concat(parts, " ") .. ")"
    end
    -- record: emit keys in a stable order so output diffs cleanly
    local keys = { }
    for k in pairs(v) do table.insert(keys, k) end
    table.sort(keys)
    local parts = { }
    for _, k in ipairs(keys) do
        local f = field(k, v[k])
        if f then table.insert(parts, f) end
    end
    return "(" .. table.concat(parts, " ") .. ")"
end

-- Categories in Record.Cat order; a category with no entries is omitted.
local CATS = { "features", "items", "monsters", "vaults" }

local function emit(seed, version, lvl, parent, cats, totals)
    local parts = { }
    for _, cat in ipairs(CATS) do
        local entries = cats[cat]
        if entries ~= nil and #entries > 0 then
            table.insert(parts, "(" .. cat .. " " .. sexp(entries) .. ")")
        end
    end
    crawl.stderr(PREFIX ..
        "((format " .. FORMAT .. ")" ..
        "(version " .. quote(version) .. ")" ..
        "(seed " .. quote(seed) .. ")" ..
        "(level " .. quote(lvl) .. ")" ..
        (parent and ("(parent_level " .. quote(parent) .. ")") or "") ..
        "(gold " .. totals.gold .. ")" ..
        "(cats " .. table.concat(parts, "") .. "))\n")
end

local args = parse_args(crawl.script_args())

if args["-seed"] == nil or #(args["-seed"]) < 1 then
    script.usage("seed_dump_sexp.lua -seed <seed> [<seed> ...] [-count <n>] [-depth <depth>]")
end

-- Either an explicit list of seeds, or one seed plus -count for a contiguous
-- run. A caller resuming a partial fill has holes in its range, so the list
-- form is what makes that expressible.
local seeds = args["-seed"]
local count = tonumber(one_arg(args, "-count")) or 1
if count > 1 then
    if #seeds ~= 1 then
        script.usage("-count takes a single -seed")
    end
    local n = tonumber(seeds[1])
    if n == nil then
        script.usage("-count requires a numeric -seed")
    end
    for i = n + 1, n + count - 1 do table.insert(seeds, i) end
end

local max_depth = explorer.level_to_gendepth("D:8")
if args["-depth"] ~= nil then
    max_depth = explorer.to_gendepth(one_arg(args, "-depth"))
    if max_depth == nil then
        script.usage("<depth> must be a level name, branch, number, or 'all'")
    end
end

local version = crawl.version()

explorer.reset_to_defaults()
explorer.quiet = true

-- item_ignore_boring judges gear by plus and brand alone, and an unrand is
-- gear: the 11 unrands that are +0 or lower and unbranded (fencer's gloves,
-- the skull of Zonguldrok, every ego-less orb) could never reach the corpus,
-- along with ~9% of randart armour, which rolls +0 far more often than a
-- reader expects. An artefact is notable because it is an artefact.
--
-- The same filter also drops anything useless to the scanning character, which
-- is a fact about this script's wizard and not about the seed. Bardings are the
-- case that costs a reader something real: they are rare, they decide a naga or
-- armataur game, and every one of them was being discarded.
local function item_notable_default(item)
    return item.artefact
        or item.sub_type == "barding"
        or explorer.item_ignore_boring(item)
end

local item_notable = item_notable_default
if args["-all-items"] ~= nil then item_notable = function (_) return true end end
if args["-artefacts"] ~= nil then item_notable = explorer.arts_only end
local all_monsters = args["-mon-items"] ~= nil

-- artprops carries ARTP_BRAND as an entry named "Brand" whose value is a
-- brand_type ordinal, not a usable integer; item.ego already carries that fact
-- in its own vocabulary, so drop the key rather than emit a second encoding.
local function artprops_of(item)
    local props = item.artprops
    if props == nil then return nil end
    local out = { }
    local any = false
    for k, v in pairs(props) do
        if k ~= "Brand" then
            out[k] = v
            any = true
        end
    end
    if not any then return nil end
    return out
end

local function item_record(item, p, cost, carried_by)
    local ok, plus = pcall(function () return item.pluses() end)
    if type(plus) ~= "number" then plus = nil end
    local spells = item.spells
    if spells ~= nil and #spells == 0 then spells = nil end
    return {
        kind = "item",
        x = p.x,
        y = p.y,
        name = item.name(),
        text = item.name(),
        base_type = item.base_type,
        sub_type = item.sub_type,
        quantity = item.quantity,
        artefact = item.artefact and true or false,
        branded = item.branded and true or false,
        plus = plus,
        ego = item.ego(true),
        spells = spells,
        artprops = artprops_of(item),
        cost = cost,
        carried_by = carried_by,
    }
end

-- Timed portal entrances carry a marker whose "turns" property is rolled at
-- generation time and so is seed-determined. The marker is userdata: indexing
-- it (m.dur) errors, and most cells have no marker at all, so the whole lookup
-- goes inside the pcall. property() returns a string, empty for an absent key.
local function timeout_at(p)
    local ok, turns = pcall(function ()
        return dgn.marker_at_pos(p.x, p.y):property("turns")
    end)
    if not ok then return nil end
    return tonumber(turns)
end

-- A vault may give a shop an arbitrary name ("Sanarr's Fire Supplies"), so the
-- type is not recoverable from the shop's own name; dgn.shop_type_at reads the
-- enum. Older builds lack the binding and leave the field nil.
local function shop_type_at(p)
    if dgn.shop_type_at == nil then return nil end
    return dgn.shop_type_at(p.x, p.y)
end

-- A trove's toll is the only thing distinguishing one trove from another, and
-- the structured props.toll table is not reachable through property(): only the
-- rendered string TroveMarker:overview_note builds. Same userdata lookup as
-- timeout_at, and an empty string is an absent key rather than a toll of
-- nothing.
local function toll_at(p)
    local ok, note = pcall(function ()
        return dgn.marker_at_pos(p.x, p.y):property("overview_note")
    end)
    if not ok or note == nil or note == "" then return nil end
    return note
end

-- Gold is summed rather than emitted: item_ignore_boring drops the piles
-- outright, so the sum is not recoverable from the corpus, but a pile carries
-- neither a position nor a size a reader asks for. The accumulator therefore
-- sits outside the item_notable filter -- the piles must be counted and must
-- never become rows.
local function scan_position(p, cats, totals, prices)
    local stack = dgn.items_at(p.x, p.y)
    if stack then
        for _, item in ipairs(stack) do
            if item.base_type == "gold" then
                totals.gold = totals.gold + item.quantity
            end
            if item_notable(item) then
                table.insert(cats.items, item_record(item, p, nil, nil))
            end
        end
    end

    local shop = dgn.shop_inventory_at(p.x, p.y)
    if shop then
        local costs = assert(prices[p.x .. "," .. p.y])
        for i, entry in ipairs(shop) do
            if item_notable(entry[1]) then
                table.insert(cats.items, item_record(entry[1], p, costs[i], nil))
            end
        end
    end

    local mons = dgn.mons_at(p.x, p.y)
    if mons and explorer.mons_notable(mons) then
        local carried = { }
        for _, item in ipairs(mons.get_inventory()) do
            if item_notable(item) then
                table.insert(carried, item_record(item, p, nil, nil))
            end
        end
        table.insert(cats.monsters, {
            kind = "monster",
            x = p.x,
            y = p.y,
            name = mons.name,
            text = mons.name,
            type_name = mons.type_name,
            unique = mons.unique and true or false,
            native = mons.in_local_population and true or false,
            items = #carried > 0 and carried or nil,
        })
    elseif mons and all_monsters then
        -- an unremarkable monster is not itself worth cataloguing, but its
        -- gear may be; the item rows carry carried_by and stand alone.
        for _, item in ipairs(mons.get_inventory()) do
            if item_notable(item) then
                table.insert(cats.items, item_record(item, p, nil, mons.name))
            end
        end
    end

    local feat = dgn.feature_name(dgn.grid(p.x, p.y))
    if explorer.feat_notable(feat) then
        table.insert(cats.features, {
            kind = "feature",
            x = p.x,
            y = p.y,
            feat = feat,
            timeout_turns = timeout_at(p),
            shop_type = shop_type_at(p),
            toll_note = toll_at(p),
            text = dgn.feature_desc_at(p.x, p.y, "A"),
        })
    end
end

-- The price charged, read before wiz.identify_all_items(): antique shops leave
-- their stock unidentified, and item_value prices an identified item by brand
-- and plus instead of by its glowing/runed appearance. Identification does not
-- reorder stock, so position plus stock index finds the same item again.
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

    local cats = { features = { }, items = { }, monsters = { }, vaults = { } }
    local totals = { gold = 0 }

    for _, vault in ipairs(explorer.catalog_vaults()) do
        table.insert(cats.vaults, {
            kind = "vault",
            name = vault,
            text = vault,
        })
    end

    local gxm, gym = dgn.max_bounds()
    for p in iter.rect_iterator(dgn.point(1, 1), dgn.point(gxm - 2, gym - 2)) do
        scan_position(p, cats, totals, prices)
    end

    return cats, totals
end

local function visit_level(seed, lvl, parent)
    debug.goto_place(lvl)
    debug.generate_level()
    wiz.map_level()
    local cats, totals = scan_level()
    emit(seed, version, lvl, parent, cats, totals)
end

local function dump_seed(seed)
    local seed_used = debug.reset_rng(seed)

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
            visit_level(seed_used, lvl)

            -- portals (Volcano, Bazaar, ...) hang off the level that holds
            -- their entrance, and are not in generation_order
            for _, port in ipairs(explorer.portal_order) do
                if crawl.seen_hups() > 0 then break end
                if you.where() == dgn.level_name(dgn.br_entrance(port)) then
                    visit_level(seed_used, port, lvl)
                    debug.goto_place(lvl)
                end
            end
        end
    end
end

for _, seed in ipairs(seeds) do
    if crawl.seen_hups() > 0 then break end
    dump_seed(seed)
end

if crawl.seen_hups() > 0 then
    crawl.stderr("Aborting! ")
end

explorer.reset_to_defaults()
