# Tile attribution

The PNGs under `static/tiles/` are tiles from Dungeon Crawl Stone Soup, copied
from `crawl-ref/source/rltiles/` at upstream commit
`62b9a60c63fd696ecaa48d33a2f1fddb932b05a2` (2026-05-25).

Upstream: https://github.com/crawl/crawl

Crawl's tiles derive from the public domain roguelike tileset **RLTiles**
(http://rltiles.sf.net), with many modifications and additions by Crawl
contributors. Crawl's own statement is in
`crawl-ref/source/rltiles/license.txt`:

> Part of the graphic tiles used in this program are from the public domain
> roguelike tileset "RLTiles". Some of the tiles have been modified.

Artists who signed their work over to CC0 are listed at
https://github.com/crawl/tiles (`ARTISTS.md`).

## What is vendored here

584 files, 3.8 MB, covering the three vocabularies the app illustrates:

| directory | source | files | covers |
|---|---|---|---|
| `altars/` | `dngn/altars/` | 82 | all 27 god altars, including the faded altar (`ecumenical`) |
| `gateways/` | `dngn/gateways/` | 127 | branch entrances and exits, portal vaults, every stair and hatch variant |
| `shops/` | `dngn/shops/` | 12 | the eight shop types, plus `enter_shop` and `abandoned_shop` |
| `misc/` | `dngn/` | 3 | the transporter pair |
| `uniques/` | `mon/unique/` | 94 | every unique monster in the game carrying tile art |
| `items/` | `item/*/` | 266 | 192 item types — the artefact-bearing classes (weapon, armour, jewellery, staff, talisman, book), the evokables (wand, miscellaneous), and the 16 potions and 18 scrolls — plus crawl's separate randart art for 71 of them, plus three parchment tiles that are ours, not crawl's (below) |

Files are flattened into these directories, keeping their upstream basenames.

`gateways/enter_zot_open.png` is additionally the source of the site favicon:
`static/favicon.ico` (16 and 32px frames), `static/favicon-16.png`,
`static/favicon-32.png` and `static/apple-touch-icon.png` are nearest-neighbour
resamples of it, under the same terms as the tile. The touch icon is flattened
onto the dark theme's `--paper` because iOS composites transparency onto black,
which would erase the gate's own black interior.

Nothing else from `rltiles/` is vendored: no walls, floors, ordinary monsters,
player dolls, or UI chrome. This project renders no map, so those tiles have no
use here.

### The potion and scroll tiles are composited, not copied

Every other file here is a byte-for-byte copy of an upstream PNG. The 34
`potion_*.png` and `scroll_*.png` are not: crawl draws an identified consumable
as two layers, a `%back` and an `i-*.png` overlay glyph, and the glyph alone is
unreadable. Each vendored file is the two flattened together —

```sh
magick item/potion/unknown.png item/potion/i-haste.png -composite potion_haste.png
```

— over a fixed back (`item/scroll/scroll.png`, `item/potion/unknown.png`) rather
than the per-seed appearance colour crawl would pick. Both layers are upstream
art under the same terms; only the flattening is ours.

### The three parchment tiles are original work

`parchment_low.png`, `parchment_mid.png` and `parchment_high.png` contain **no
upstream art**. They are drawn for this project (`tools/draw-parchments.py`),
because crawl's own parchment art keys on spell *school* over three level tiers
and, at the size this page sets a tile, the school is a few pixels of tint —
79 distinct files that read as one beige blob in a list. Ours encode only the
tier, using height, rule count, a wax seal and a gilt band so the band survives
being drawn at 22px. They borrow crawl's parchment *palette* so they sit in the
same visual family, which is a colour choice rather than copied pixels.

Being ours, they carry no attribution obligation. They are noted here so the
line between vendored and original art stays legible.

## A note on the CC0 export

`github.com/crawl/tiles` republishes a subset of these tiles under CC0, limited
to artists who could be contacted and who signed off. Its most recent release
(Nov-2015) predates Hepliaklqana, Uskayaw, Wu Jian and Ignis, and omits stone
stairs, `enter_shop`, 11 of 12 shop tiles, and 28 altars, along with every
unique and item type added since — so it cannot cover this slice. These files
therefore come from crawl's own tree under the license above, not from that
export.
