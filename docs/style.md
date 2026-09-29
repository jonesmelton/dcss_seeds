# Typography and color

A type-led visual system for semantic HTML: a reading instrument styled after the
printed page. Concrete values — tokens, font faces, exact sizes — live in
`static/style.css`. This document is the reasoning behind them: the conventions
to follow when building a new page, so the result stays coherent.

The governing idea is restraint, but not austerity. One serif family for
everything, real typographic detailing (oldstyle figures, small-caps, hairline
rules) instead of boxes and shadows — and a small, deliberate palette that marks
what is *unusual* in a catalog otherwise set in ink.

There is a tension particular to this project: the subject matter is a *terminal
roguelike*, and the content is dense tabular data — coordinates, depths, prices,
enchantments. The resolution is not to ape a terminal. It is to treat the dump as
what it is: a **catalog**, and catalogs are a printed form with centuries of
typographic convention behind them. Set it like an auction catalog, not like a
console.

---

## Audience

Readers of this app are DCSS players. That is a real constraint and it licenses
some things a general-audience site could not assume:

- They know the vocabulary. `D:5`, `Lair`, unrand names, and `rCorr` need no
  gloss. Do not pad the interface with explanations of the game.
- They are reading to **compare and scan**, not to read prose. Density is a
  feature.
- They are overwhelmingly on a desktop browser with a real keyboard.

It also sets the scope of assistive-technology support. **Screen-reader
support is calibrated against upstream crawl**: DCSS is not playable by a screen
reader today, so this app does not attempt to exceed the game's own
accessibility. That keeps ARIA choreography, live regions, visually-hidden
labels duplicating visible ones, and `scope` on every `<th>` out of scope —
they would describe an experience a reader cannot have here. Where semantic HTML
gives correct structure for free, use it — `<th>`, `<label>`, `<button>` —
because it is also the simplest correct markup. If crawl gains screen-reader
support, this calibration is the thing to revisit.

What we *do* keep, because it is ordinary web competence and benefits everyone:

- **Keyboard operability** with a visible focus state, everywhere.
- **Legible contrast** in both themes.
- **Reduced-motion** honored.
- **Real form semantics**: a `<label>` bound to its input, a submit button that
  submits.

See [Accessibility](#accessibility-what-we-keep) at the foot for the short list.

---

## Color

The palette is ink and paper plus a **semantic accent set**, in light and dark.
Color here has one job: **mark what is unusual**, so a reader scanning a
hundred-row catalog can find the three rows worth looking at.

### The principle: color marks significance, not category

The tempting move is to tint by item category — potions one hue, scrolls another.
Resist it. `items` is 83% of every row in the corpus; coloring by category paints
almost the whole page and marks nothing. Category is already carried by the
`category` column and by the item's own name.

What a player actually scans for is **significance**: is there an artefact here,
is something out of depth, did a unique drop something. Those are rare — a
handful of rows per seed — so color spent on them is color that reads.

### The accent set

Six roles, each with a defined meaning. Every one is *also* carried by a word,
per the rule below.

| Role | Meaning | Used for |
| --- | --- | --- |
| `--accent` | Navigation and interaction | Links, focus rings, the current page |
| `--gold` | Exceptional | Artefacts and unrands — the rarest thing on a level |
| `--ember` | Notable | Enchantments and brands; a real but ordinary find |
| `--verdant` | Positive / resolved | Confirmations, match counts, "found" states |
| `--arcane` | Structural | Portals and branch entrances — a way *elsewhere* |
| `--danger` | Danger and error | Destructive actions, failed input, out-of-depth threats |

Hold to these principles:

- **Every color is also a word.** Anything distinguished by color is also
  distinguished by text, weight, or an underline. This is not a screen-reader
  concession — it is what keeps the page legible in grayscale, in print, to the
  ~8% of players with a color vision deficiency, and at a glance when the color
  is a 6px swatch.
- **Red means danger, nothing else.** It never appears as decoration, emphasis,
  or branding.
- **Six is the ceiling.** A seventh hue means one of these is doing two jobs;
  fix that instead.
- **Earn contrast.** Body text meets WCAG AA against paper. Before reaching for
  a fainter ink, check it still clears the bar for anything readers must read.

Light and dark are equal citizens; neither is the "real" one with the other
bolted on.

### Do not reuse crawl's item colors

This was investigated and rejected on the evidence, not on taste. Three reasons:

- **Item colors are not canonical.** A potion's in-game color is
  `PCOLOUR(subtype_rnd)` — a *per-seed shuffle* over "blue, black, silvery,
  cyan…" applied to the item's *unidentified* description. There is no stable
  color for "potion of haste"; the color belongs to the appearance, not the type.
  (Surfacing that appearance is a real
  planned feature, and it is the one place a crawl color word will legitimately
  appear.)
- **God colors are canonical but collided.** `god_colour()` maps 27 gods onto 6
  terminal colors: five gods share `CYAN`, eight share `LIGHTRED`. As a way to
  tell one altar from another it is strictly worse than reading the name.
- **What crawl actually tints by is item class**, in a sixteen-color terminal
  carrying a dozen orthogonal meanings. It does not survive being moved to a
  page with a different background and a full-color gamut.

### Crawl's tiles are usable

Not blocked. The tiles are packaged for reuse by other projects: per the crawl
developers, every piece is either taken from an open source project under terms
that permit it or released to Creative Commons by its artist, and the hedging in
`LICENSE` is there to cover a piece they might have missed, not a known problem.
Our obligation is the ordinary one — honor the terms and attribute — not an
audit before first use.

**The bridge is mechanical.** `rltiles/` ships every tile as an individual 32x32
PNG in a directory tree, alongside `dc-*.txt` files that map filename to enum in
two plain text columns. The compiled atlas (`main.png` plus `tiledef-*.h`
offsets) is one consumer of that tree, not the only way in; reading the PNGs
directly never touches the enum numbering. First measurement, deriving a
filename straight from the display name, against the 0.34.1 corpus:

- Uniques, `lower(name)` with spaces to underscores: 25 of 26 hit a file.
  `Blorkula the orcula` is the miss (crawl's tile drops the epithet).
- Potions, `POT_` + upcased `sub_type`: 15 of 16. `lignification` is the miss,
  against `POT_LIGNIFY` — a rename never propagated to the tile enum.
- Scrolls, `SCR_` + upcased `sub_type`: 17 of 18. `summoning` is the miss,
  against `SCR_UNHOLY_CREATION`, which crawl's own source annotates `# aka
  scroll of summoning`.

Those near-miss rates are what a *name*-keyed derivation buys, and every miss in
them is the same shape: a rename crawl applied to the item but not to the tile.
Keying on the enum instead removes the whole class — see "What ships" below,
which supersedes this as the way the bridge is actually built.

That is a transform plus a three-entry exception table.

Parchments were called the best fit of all here, on the grounds that
`item/parchment/` is keyed by spell *school* and level tier
(`parchment_single_fire`, `parchment_multi_left_necro_high`) and that this is
"the granularity the corpus already stores". **That last part is wrong**, and
the conclusion was wrong twice over.

The corpus stores a spell's *name* and nothing else — there is no school column
on `entry_spells`, on `book_spells`, or anywhere else. That is recoverable:
joining `book-data.h` against `spl-data.h` resolves schools *and* level for all
132 player-book spells with no misses, which is better coverage than any other
tile vocabulary here gets.

The reason crawl's parchment art still does not ship is that **it was built and
measured, and it does not survive being drawn small.** 132 spells collapse to 79
distinct composites, and at the ~22px this page sets a tile they are one beige
blob: the school is a handful of pixels of glyph plus a border tint. Crawl gets
away with it because a player hovers one item on a map; a catalog prints forty
in a column.

So parchments carry **our own art instead of crawl's** — three tiles, one per
level tier, drawn by `tools/draw-parchments.py`. They keep crawl's tier
thresholds (8+/5+/rest, falling 71/45/16 over the 132 spells) and crawl's
parchment palette, and drop school entirely. Tier is encoded in silhouette
height, rule count, a wax seal and a gilt band — features that survive the
downscale where a tint does not. This is the one place we draw rather than
vendor, and the reason is legibility at our size, not licensing.

The per-seed appearance shuffle is not an obstacle here either. `PCOLOUR(subtype_rnd)`
governs the *unidentified* tiles (`scroll-blue`, `scroll-grey`); identified tiles
are named by effect (`i-identify`, `i-haste`) and are stable within a version.
The corpus stores identified types, so it would read only the stable half.

**Attribution is settled for the slice that ships.** `LICENSE` says *most* tiles
are CC0 and hedges that "the licensing situation may be complex, especially for
older pieces"; `rltiles/license.txt` adds that some derive from the
public-domain RLTiles set, modified. `static/tiles/ATTRIBUTION.md` records the
provenance commit and what is vendored.

The CC0 export at `github.com/crawl/tiles` was evaluated as the source and
rejected on coverage: its most recent release is **Nov-2015**, which predates
Hepliaklqana, Uskayaw, Wu Jian and Ignis, and omits stone stairs, `enter_shop`,
11 of 12 shop tiles and 28 altars. It cannot dress a seed page. The tiles come
from `rltiles/` instead, under the terms above.

Size is not a factor either way: the whole shipped slice — features, all 94
uniques, and 192 item types with their randart variants — is 3.8 MB, against a
65 MB `rltiles/` tree.

Whatever ships, ship the credits with it.

### What ships, and why every bridge is a table

`static/tiles/` holds **584 PNGs, 3.8 MB** — `altars/` (82), `gateways/` (127),
`items/` (266), `uniques/` (94), `shops/` (12), and three loose transporter
tiles. All but three are crawl's; the parchment trio is ours. Features, unique monsters, and the item types worth illustrating. This
project renders no map, so walls, floors, player dolls and UI chrome stay out.

The measurements higher up this page proposed deriving a filename from a display
name, and reported that working for items and uniques where it fails for
features. **That was measured on the wrong side of the join.** Deriving from the
*display name* fails on all three vocabularies; what actually works is going
through crawl's own enum, which every one of its tile tables is keyed by:

- `mon-data.h` binds `MONS_*` to a display name and flags the uniques;
  `rltiles/dc-mon.txt` binds `MONS_*` to a file.
- `item-prop.cc` and `item-name.cc` bind `WPN_*`/`ARM_*`/`RING_*`/… to a display
  name; `rltiles/dc-item.txt` binds those enums to files.

Joining the two halves resolves **97 of 99 uniques** and **192 of 192** in-scope
item types, against the 26-of-27 and near-miss rates a name-derivation gets. The
one documented unique miss disappears: `Blorkula the orcula` is `blorkula.png`
because the *tile* drops the epithet, which the enum knows and the name does not.

Against the corpus's 36 distinct feats, derivation resolves 26 and misses 10,
because the art was named by artists over two decades rather than by a scheme:

| feat | tile | what breaks |
|---|---|---|
| `altar_hepliaklqana` | `hep0.png` | abbreviated |
| `altar_jiyva` | `jiyva01.png` | zero-padded — a `jiyva1` probe misses |
| `altar_makhleb` | `makhleb_flame1.png` | suffixed |
| `altar_the_shining_one` | `shining_one.png` | article dropped |
| `enter_sewer` | `sewer_portal.png` | **affix inverted** |
| `transporter` | `dngn/transporter.png` | not in a subdirectory |

The portal case is the trap: all 15 portals move `enter_` from prefix to
`_portal` suffix, so a rule that looks right on `enter_lair` is wrong on every
portal in the game. A near-miss derivation is worse than none — a wrong filename
renders as a broken image, where a missing entry renders as text.

So `Tile.of_feat` is an explicit table (`lib/corpus/tile.ml`), returning
`option`. It carries **82 feats**: the 36 the corpus holds plus the branches and
portals no `D:8` seed reaches, so deep fills need no tile work.

`Tile.of_unique` and `Tile.of_item` are tables for the same reason, generated by
the enum join above rather than written out by hand. They are equally wide:
**94 uniques** and **192 item types**, against the 27 and 148 a `D:8` corpus
actually holds, so a deeper fill needs no tile work there either.

Even through the enums, crawl's two halves disagree in fifteen places, and those
are an explicit exception table. They are renames that never reached the tile
files — an item's `TALISMAN_SERPENT` is a tile's `TALISMAN_SNAKE`, `STAFF_ALCHEMY`
is `i-staff_poison`, `AMU_CHEMISTRY` is `i-alchemy` — plus one redirect crawl
performs in `tilepick.cc` rather than in data (`WPN_EUDEMON_BLADE` draws as
`WPN_BLESSED_BLADE`). A rename is exactly the case a derivation gets *wrong*
rather than merely misses, which is why it is a table.

**An artefact is not the base item with a flag.** Crawl draws a second piece of
art for the randart form of many base types — `sling3.png` beside `sling1.png`,
`fire_dragon_armour_art.png` beside `fire_dragon_armour.png` — so `of_item`
takes `~artefact` and returns it where it exists. 71 of 158 types have one; the
rest fall back to the base tile, because the `artefact` word beside the name is
what carries the distinction and a tile never carries meaning alone.

Coverage on the 0.34.1 corpus, over floor rows (`carried_by is null`): **98.4%**
now draw a tile, against 82.6% before parchments, 55.4% before potions and
scrolls, and 12.4% when features were the whole slice. What is left is ordinary
monsters and a handful of item classes nobody illustrates.

Potions and scrolls were previously excluded on the grounds that "they are the
two most common things in the dungeon and tiling them would paint the page."
That reasoning confused two different things. **Tinting by category paints the
page; illustrating a type does not** — a tile is one 32px glyph per row, not a
wash of colour, and the six-role accent set is untouched by any of this. Being
the most common thing in the dungeon is the argument *for* tiling them: at
436,497 of 990,452 floor rows they are 44% of what a seed page prints.

**A tile carries the class; the name carries the rest.** This is a change: the
rule used to be that a tile never carries meaning alone. It does now, for
potions, scrolls and parchments. Crawl names a potion or scroll
"[N ]<base>s of <sub_type>" and a parchment "parchment of <Spell>", so every
such row opened with a word the icon already said, and `Floor.display_name`
drops it — "scroll of butterflies" is a tile plus "butterflies". Quantity always
survives, being the one part no other column repeats.

The trim is narrow on purpose, because a tile that fails to load degrades to a
bare "butterflies" with no indication it is a scroll. For potions and scrolls it
applies only where the stored `base_type`/`sub_type` rebuild the name *exactly*
(436,497 of 436,497 rows in the corpus, no exceptions); for a parchment, only
where the spell is one the `Spell` table knows (131 of 131 corpus types). In
both cases only where a tile is known to exist — an expect test asserts that
rather than trusting it. Everything else prints its full name.

Otherwise a tile sits beside the name it illustrates, at 1.4rem with an empty
`alt`. `image-rendering: pixelated`, because these are 32px pixel art drawn
smaller and smooth scaling turns them to mud.

### Dark mode

Dark mode is a first-class theme, not an inversion. It follows the reader's OS
preference by default and can be overridden by a toggle that persists in
`localStorage`.

The mechanism: `:root` carries the light tokens; a
`@media (prefers-color-scheme: dark)` block redefines them; and
`:root[data-theme="dark"]` / `:root[data-theme="light"]` redefine them again so
an explicit choice wins in *both* directions. A tiny script in `/static` sets
`data-theme` before first paint — inline scripts are forbidden by the CSP, and a
theme applied after paint flashes.

Accent hues need more lightness and less chroma against a dark ground to hold the
same apparent contrast. They are defined per theme, not derived.

---

## Type

Self-hosted **Alegreya**, in three roles. **There is no mono role.**

- **Serif** (Alegreya) — the body, and nearly everything. Long-form text, most
  headings, table data. This is the voice of the page.
- **Small-caps** (Alegreya SC) — a distinct cut, not a synthesized variant, for
  labels, metadata keys, section markers, and the larger headings. Small-caps do
  the work that bold and uppercase do elsewhere: they signal "this is a label,
  not prose" without shouting.
- **Sans** (Alegreya Sans) — seed numbers, search-term inputs, and UI chrome
  where a sans is genuinely wanted. A companion cut, not a foreign face.

### Why no mono

The previous system sent seed numbers and coordinates to `ui-monospace`, because
"Alegreya has no mono cut." That was solving the wrong problem. **What tabular
data needs is tabular figures, not a monospaced font** — and every Alegreya face
we ship has `tnum`. A system mono next to Alegreya is a visible seam in exchange
for nothing.

Verified in the shipped `woff2` subsets:

| Face | `tnum` | `lnum` | `onum` |
| --- | --- | --- | --- |
| Alegreya roman | ✅ | ✅ | ✅ |
| Alegreya italic | ✅ | ✅ | ❌ |
| Alegreya Sans (all cuts) | ✅ | ✅ | ❌ |
| Alegreya SC | ✅ | ✅ | ❌ |

Two consequences worth knowing. **Lining is the default** in every face — `onum`
is a substitution *to* oldstyle — so a face without `onum` renders lining figures
whatever `font-variant-numeric` asks for. And **oldstyle is only available in the
serif roman**, so italic prose gets lining figures and that is simply the
constraint. Do not add a fourth family to work around it.

### Numerals carry meaning

This is the rule most easily gotten wrong, and the one that most distinguishes a
considered page from a careless one. It matters more here than in most projects,
because this app is *mostly numbers*.

- **Prose uses oldstyle, proportional figures** — numerals with ascenders and
  descenders, sitting in the line like lowercase letters. This is the body
  default. A version number or a count inside a sentence should not jump out as
  if set in a different font. "a dagger of venom +1" reads as a sentence.
- **Data uses lining, tabular figures** — uniform-height numerals on a fixed
  width, so columns align. Use them for **every** numeric table column, and for
  depths, coordinates, prices, enchantments, and quantities.

Decide which you mean every time a number appears.

**Seed numbers** are a special case: ten-digit identifiers nobody reads as a
quantity, frequently copied, and needing to be told apart at a glance. Set them
**sans, lining, tabular**, slightly tightened, and never let one break across a
line. The sans is what distinguishes a seed from the serif data around it — the
job the mono used to do, done without leaving the family.

---

## The reading measure

Prose sits in a single narrow column, centered, around a 65-character measure —
the width at which prose is most comfortably read. Resist widening it to fill the
viewport; whitespace on either side is correct, not wasted.

**Tables are the exception, and here they are the main event.** A catalog of a
level's contents is not prose and must not be crammed into the reading measure.
Structured material may break out to a wider column, set tighter and smaller. The
reading measure governs anything meant to be *read*; the catalog governs itself.

---

## Headings

The heading scale is shallow on purpose. Three block levels, then run-in heads:

- **H1 and H2** are small-caps serif, light weight, lightly tracked — quiet
  authority rather than size-and-bold loudness.
- **H3** is italic and bold — a clear shift in voice without another size step.
- **Below H3**, do not invent smaller titles. Following the Tufte convention, a
  fourth-level heading becomes a **run-in side head**: bold, inline at the start
  of the paragraph it introduces.

A subtitle under a title is italic secondary ink. A section may open with a
small-caps lead-in on its first words to mark the beginning without a heading.

Level names (`D:3`, `Lair:2`) are structural, not headings — they read as
small-caps labels or as a table's grouping column, depending on the layout.

---

## Body text and quotation

Emphasis is italic; strong emphasis is bold; both are real cuts of the serif, not
synthesized. Blockquotes are set off by a hairline rule on the left and quieted
to secondary ink, with an italic attribution — indentation and color, not a
tinted box. Code blocks sit on the faint panel fill rather than in a bordered
card, set in the sans at a reduced size.

---

## Rules, dividers, and tables

Hairlines do the structural work that borders and boxes do in heavier designs.
They are deliberately fine — the thinnest believable line — and tinted, never
black. Use them under table headers, between sections, and to separate columns;
avoid full boxes and drop shadows entirely.

A section may be introduced by a centered small-caps label flanked by hairline
rules — a printer's break, not a heavy header bar.

Tables are spare: collapsed borders, a single hairline beneath small-caps column
headings, generous baseline-aligned rows, and **tabular figures in every numeric
column** so the digits line up. No zebra striping, no cell borders, no
surrounding frame. The alignment and the type do the organizing.

For catalog tables specifically:

- **Numeric columns right-align**; text columns left-align. Nothing centers.
- **Repeated grouping values are elided**, printed once at the head of their run
  rather than on every row. A column of identical `D:3`s is noise.
- **Sort order is stated, not implied.** A table that is sorted says so — and the
  seed listing, which is *not* sorted, says that too.
- **A row's significance is marked at its left edge**, not by tinting the whole
  row. A hairline rule in the significance color, flush left, is enough to find a
  row while scanning; a tinted row background makes the text harder to read for
  the sake of the one row that mattered.
- **Never spend a column on what the name already says.** Crawl's item names
  carry quantity (`2 potions of haste`), enchantment (`+4 flail`), and a
  parchment's spell. A column for any of those prints the fact twice and leaves a
  blank on every row that lacks it.
- **A column holding a set wraps; it does not widen the table.** The listing's
  "others" column carries a seed's rare altars and portal entrances, and a seed
  filled to `Swamp:4` carries *seven* of them where a `D:8` seed carries one. If
  that column sizes to its content the table outgrows the page and the reader
  gets a horizontal scrollbar to read one column. So the cell is a wrapping flex
  row: the tags are an unordered set, so a second line loses nothing, and the
  table stays inside its breakout at every depth.

  The mechanism matters, because the obvious version does not work. Adjacent
  `<span>`s emitted with no whitespace between them give the line breaker **no
  break opportunity**, so an inline run overflows the cell instead of wrapping —
  it looks like a width bug and is a markup one. `flex-wrap` with a `column-gap`
  breaks between items regardless of whitespace, and `align-items: baseline`
  keeps the row on the baseline the numeric columns align to.

  The general rule: **size a table for the deepest fill, not the default one.**
  A column whose cardinality scales with fill depth is a column that will
  overflow the first time someone deepens a seed.

- **A tag leads with crawl's own art for the thing it names**, not with one
  glyph standing for a whole kind. The sewer's grate, the ossuary's sand-covered
  stair, the god's own altar, the scroll — these are shapes a reader already
  knows by sight, so the tile is the fastest way into the row and the word
  beside it is confirmation. A single `◊` for every portal alike costs a reader
  the one thing they wanted from the tag.

  This is why the mapping is a table and not a derivation. A portal's level name
  is crawl's abbreviation and its entrance feature is the full spelling, so
  `IceCv` and `WizLab` do not lowercase into `enter_ice_cave` and
  `enter_wizlab`. Three of ten portals would resolve to a broken image rather
  than a caught error — see `Depth.feat_of_portal`, and the same argument in
  `tile.mli`.

  Boons lead the cell for the same reason they take the flag on the seed page:
  they are the one tag in an unordered set that is worth the same to every
  reader.

---

## The masthead: the build outranks the product name

The largest thing on every page is **the crawl version**, set at display size in
the sans, directly under a small-caps product name and the theme toggle. It is a
link home for that build.

This inverts the usual masthead because the usual reason for a masthead does not
apply. The product name does not determine whether an answer on this page is
right; the build does. The same seed number describes two unrelated dungeons on
0.33 and 0.35, and quoting a seed without its build is the commonest way a
shared seed turns into someone else's different game — a friction the seed-
sharing part of the community already lives with, and one this site would
otherwise amplify by making a version-scoped fact look version-free.

Under the version sits **one italic sentence**, at the small size, saying that
everything on the site is true of this build only. Not a banner, not a panel,
not a color: it is a standing condition, not a warning, and a warning that fires
on every page stops being read by the second visit. A rule closes the block, so
the version reads as the page's frame rather than as its first heading.

The consequence is that no page repeats the build in its own subtitle. It is
stated once, at the top, larger than anything it qualifies.

---

## A note you read once

Some prose on this site is true every visit and worth reading exactly one time:
how the listing is ordered, what an exclusive draw is. Left inline it is a
paragraph the reader scrolls past forever; deleted it takes an honest caveat
with it.

So it folds. A native `<details>` with a small-caps summary — "How to read this
table", "What is an exclusive draw?" — and the prose in the open panel, set
italic behind the same left rule the depth note uses. `<details>` and not a
scripted disclosure: it is keyboard operable and focusable with no script, and
an htmx swap cannot leave it out of step with a handler that never ran. The
summary draws its own triangle, since `display: inline-block` drops the UA
marker and a bare line of small caps does not read as openable.

The test for folding a note is whether it is *learned*. A caveat that changes
per seed — how deep this seed was searched — stays inline; a caveat that is a
property of the site does not.

---

## The seed page

One seed's contents are **not one table**. A floor is a **ruled sheet with a
fixed rail down its left** — see `docs/architecture.md` for the split itself.

The governing move is that **the part label lives in the margin, not above the
content**. Six stacked headings restart the eye six times; a rail lets it run
down a single column of contents with the labels beside it. This is the Tufte
marginal note applied to structure: the labels and the qualifications go in the
margin, the material stays in the block.

A floor opens with its **standing facts** — a sentence of what is rare here,
what it commits you to, what it costs — set right, on the heading's baseline,
above a full rule. An unremarkable floor prints nothing there, which is itself
the answer.

The parts run in the order a player meets a floor — what can kill you, then
where you can go, then what you can pick up, then what you can buy:

- **Uniques** are one line each, naming what they carry. Everything the corpus
  keeps is a unique, so "unique" is the rail label, not a mark on every line.
- **Stairs and portals** and **notable** are lines on a common three-column
  grid: the thing, its flag, its coordinate. The flags and coordinates stand on
  fixed axes, so a reader can run down either or ignore both. A stair or portal
  also names **where it goes**, in `--ink-2` after crawl's own name: crawl names a portal
  entrance for how it looks, not for its destination — "a sand-covered
  staircase" is an Ossuary — so the destination is a fact the name withholds and
  a reader is otherwise expected to have memorised. A stair whose name already
  says the branch ("a staircase to the Lair") is left alone; the same word twice
  on one line is noise.
- **Altars** are a field of names — a set, not positioned things. A god outside
  crawl's temple pool takes `--gold` *and* bold, since every other god stands in
  every seed's Temple.
- **Also here** is a sentence, not rows. Fourteen consumables are a sentence;
  their coordinates stay reachable on the `title` rather than taking a column.
- **Shops** are bills: stock, a rule, and the total ruled off at the foot. A
  shop is the one thing on the page read as a column of numbers. The total is
  what tells a treasury from a general store — twenty artefacts and twenty
  potions are both "20 items". A bill's caption carries the shop's **type**
  after its name, in the same `--ink-2` parenthesis a stair or portal uses for
  its destination and under the same rule: a vault may name a jewellery shop
  "Sanarr's Fire Supplies", so the type is a fact the name withholds — but on
  the ~89% whose name already says it, printing it would set the word twice.
  The shop's coordinate sits on the bill's own right edge, on the axis its
  prices use, which means overriding the base `caption` prose measure.

Three rules the page depends on:

- **A floor takes the breakout once**, as a whole, rather than each part inside
  it taking its own. Per-element breakout leaves the rail and labels at the
  prose measure and the content outside it, which reads as two columns rather
  than one block.
- **A coordinate is printed only for what stays put.** A monster's `x,y` is
  where it *spawned*; it wanders the moment the level is entered, so the number
  is stale before a reader sees it — and a carried item is recorded on its
  carrier's square, stale for the same reason. Uniques and their loot get no
  coordinate; floor items, altars, stairs and shops do. The column is held open
  on the rows without one so the axis survives the gap.
- **One flag per line**, naming the rarest thing about it. Two flags say nothing
  the rarer of them did not, and the word carries the meaning — the color only
  finds it.
- **A book prints its spells**, quieted like a property clause and on its own
  line under the title: six spell names are longer than the item name they
  belong to, so keeping them inline would push the flag and coordinate columns
  off the sheet. This is also why a book carrying a spell set its name does not
  state is *notable* rather than a sundry (`Floor.significance`) — the set is
  the whole reason to take it, exactly as an artefact's properties are, and
  "Fen Folio" says nothing about what is in it. A parchment states its own
  single spell in its name and stays ordinary.

A floor's **heading takes the width it needs**, rather than sitting in a column
matched to the rail. A portal is catalogued under its own name with the level
its entrance sat on set after it — "Ossuary from D:6" — and a fixed column
breaks that onto a second line at a width nothing else on the sheet needs. The
standing facts still sit against the right edge, so the rule below reads as one;
below the rail's measure the two stack.

Above the floors sits the **branch index**: every branch stair and portal
entrance in the seed, with the depth it stands on. Branch names take `--arcane`,
because a branch entrance is a way *elsewhere*, and the depths sit on a fixed
axis so the column can be read straight down.

Below it sit the **exclusive draws**, in the same shape and for the same reason:
an axis name leading, its value on a fixed column, read straight down. Seven
groups, one line each, the drawn member in `--gold` and bold; the members it
rules out trail at the right edge in `--ink-3`, since they are what the seed
*cannot* hold rather than anything it has. An unseen group keeps its row and
takes the listing's em dash — the same "not this shallow, which is not the same
as absent" the listing means by it. A folded note says so outright, because
absence at this depth is not evidence of exclusion and the page must not imply
it is — folded, because it is a fact about the model rather than about this
seed, and a reader needs it once.

**The floors run in reach order, not name order.** Storage returns levels sorted
by name, which strands every portal and the Temple after D:8 — a Sewer off D:3
read eight floors from the drain leading to it, and the page reading as two
lists rather than one route. Each level that is entered from another follows
immediately after the floor holding its entrance, and says so in its heading
("Sewer from D:3"). A level the corpus cannot place keeps its storage position;
it is not moved on a guess.

---

### How deep the search went

The seed page opens with a sentence saying how far this seed was extracted,
before any of its floors. It is **prose about the page**, not part of the
catalog, so it keeps the reading measure the paragraphs around it have and is
set apart by a left rule rather than a box. A panel would read as a warning, and
the shallow case — the common one — is not a warning.

The shallow sentence is the one that earns the feature. Without it the absence
of a Lair reads as a fact about the seed rather than about how far anyone
looked, which is precisely the ambiguity `seed_fills` exists to remove.

Five states, all carried by **text**:

| State | What it says | What it offers |
| --- | --- | --- |
| shallow | searched to `D:8`, and that the dungeon goes further | the button |
| queued | what is happening, and how many requests are ahead of it | nothing; it polls |
| running | what is happening, and that it takes seconds | nothing; it polls |
| deep | searched past the cap, so the branches shown are all of them | nothing |
| failed | the reason the search did not finish | the button again |

**No progress bar in the waiting states.** Crawl emits nothing incremental, so a
bar would be an animation pretending to be a measurement. A sentence and a poll
are the honest version.

Queue position is the exception that proves it. It is a *measurement* — the
count of requests the generator will work through before this one — so it can be
stated as a number without pretending. It goes in the queued sentence rather
than beside it, and it names the build: a generator claims per version, so a
request on another build is not ahead of this one, and an unqualified "3 ahead"
would describe a queue nothing works through. Position zero is **"next in
line"**, never "0 ahead" — a count of nothing is the one case where the number
reads worse than the word. The five-second poll already re-renders from storage,
so the number falls on its own with nothing added to carry it.

Colour appears in exactly one of the five — `--danger` on a failed job — and
only ever reinforcing a sentence that already says it went wrong.

## Lists

Lists are plain and tightly led. Description lists set the term in small-caps to
read as a label against its prose definition. Reserve ordered lists for genuine
sequence.

---

## Marginal notes

Following Tufte, asides, citations, and glosses belong in the margin beside the
text they annotate — not collected as footnotes at the foot of the page. On
screens too narrow for a margin, they fold gracefully back into the flow.

This is a good home for the qualifications this data constantly needs — that
items come from map knowledge, that a depth cap truncates what was generated,
that a version pin makes a seed non-comparable.

---

## Interactive elements

Interactivity is marked by an underline and a visible focus ring, never by color
alone. A control that behaves like a link should read like one — inheriting the
surrounding type — even when it is technically a button. Every interactive
element must be reachable and operable by keyboard, with a focus state plainly
visible against the page. Hover is an enhancement, never the only affordance.

Filters and sorts are **links or form controls**, not JS-only widgets. htmx
removes the round-trip flash; it does not carry the feature.

### Waiting is said in words

A search is answered by the server and a cold conjunction is not instant, so the
window between the press and the swap has to say something — otherwise the
previous results sit there reading as current, which is the same failure the
depth note exists to prevent one page over.

It says **"searching…"**, in the small-caps of the other labels, fading in beside
the button while the request is out. Not a spinner: the reduced-motion rule
strips every animation on this site, so an indicator carried by motion alone
says nothing to the reader who asked for none, and a word survives that intact.
It is also not a progress bar, for the reason given under [How deep the search
went](#how-deep-the-search-went) — nothing here reports incremental progress, so
a bar would be an animation pretending to be a measurement.

The Search button is disabled while the request is out. That is the same claim
the word makes, in the control rather than beside it.

### One icon, and the case for it

The copy-seed button is a clipboard glyph rather than the word "copy", and it is
the only icon-only control on the site. Three things justify the exception. The
clipboard is one of a handful of glyphs with a settled meaning a reader already
holds. The control repeats on every row of the listing, and a column of the same
word is a column of noise. And the glyph is not the only signal: the button
carries an accessible name and a tooltip naming the seed, and its confirmation
is a *check* — a different shape, not merely a different hue.

It is set deliberately low-contrast, at `--ink-3` and reduced opacity, coming up
to full ink on hover and focus. It sits beneath the data rather than beside it,
because it is chrome that happens on every row. Adding a second icon-only
control is a decision to be argued, not a precedent this one sets.

---

## Status and state

Default to ink. Express state first through words and weight, then layer color on
top of that — never in place of it.

This app's vocabulary, and how each is set:

| State | Type | Color |
| --- | --- | --- |
| boon (xp / acquirement) | small-caps, bold | `--verdant` |
| artefact | small-caps, bold | `--gold` |
| enchantment / brand | italic, with the ego named | `--ember` |
| unique-carried | small-caps | `--ember` |
| portal / branch entrance | small-caps | `--arcane` |
| shop stock | small-caps, with the price | ink |
| useless | struck through, quieted | `--ink-3` |
| out-of-depth | small-caps | `--danger` |

A boon leads that table because it is the only state that is not a claim about
rarity. Acquirement stands on 31% of seeds, so it would be nowhere near the top
of a list ordered by scarcity — but a potion of experience and a scroll of
acquirement are worth the same to *every* character, where a `--gold` artefact
is a reason to detour for one build and dead weight for the next. That is the
rarer claim, so the boon takes the flag on its line and sorts ahead of the
artefact in "notable". It gets `--verdant`, the "positive / found" hue, rather
than `--gold`: gold means "the rarest thing here", which a boon is not.

The line itself is *not* set bold, though an earlier draft did set it. Sorting
to the head of "notable" is already the emphasis; bolding the name on top of
that spends weight the flag column is using to draw a finer distinction, and a
section where the first row is always bold stops reading as a ranking at all.
The general form: **when position already says it, type should not say it
again.**

Note that shop stock is deliberately *uncolored*: a price is already a number
that stands out, and a shop is common enough that tinting it would spend the
palette on the ordinary.

---

## Accessibility: what we keep {#accessibility-what-we-keep}

Calibrated, per [Audience](#audience), against what upstream crawl supports:
screen-reader affordances are out of scope while the game is not playable that
way. We are still writing competent HTML.

- Meet **WCAG AA contrast** for all text in both themes, including secondary ink.
- **Never let color be the sole carrier of meaning** — for grayscale, print, and
  color vision deficiency, not for assistive technology.
- Make **every interactive element keyboard-operable** with a visible focus
  state. This is the one we care most about: a keyboard-only power user is a
  plausible reader here.
- **Honor reduced-motion.** Motion is always optional.
- Use **semantic elements** — `<th>`, `<label>`, `<button>`, `<nav>` — because
  correct markup is the simplest markup and it gets browser behavior for free.

Explicitly *not* required: ARIA live regions, `scope` attributes, visually-hidden
label duplication, skip links, or `aria-*` annotation of decorative marks. If one
of these is present it should be because it earns its place some other way.
