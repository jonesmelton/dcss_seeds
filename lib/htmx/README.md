# tyxml-htmx

Typed [TyXML](https://ocsigen.org/tyxml/) attribute wrappers for the
[htmx](https://htmx.org/) hypermedia attributes (`hx-get`, `hx-target`,
`hx-swap`, …).

Freestanding: depends only on `tyxml`. Kept on the **plain stdlib prelude**, unlike the rest of this
tree, because it is a portable library rather than app code — do not convert it
to Core.

## Target: htmx 4 (beta)

Targets **htmx 4**, in beta. The attribute set, the `hx-swap` vocabulary, and
the per-attribute `:inherited` modifier follow htmx 4 semantics, not htmx 2.
In particular the morphing swap tokens are `innerMorph`/`outerMorph` — there is
no bare `morph`. `static/htmx.min.js` is the matching vendored runtime; the two
move together.

If you are on htmx 2, this is the wrong package.

## Usage

```ocaml
open Tyxml_htmx
open Tyxml.Html

let seed_link seed =
  a ~a:[ hx_get ("/seed/" ^ seed); hx_target "#results"; hx_swap Swap.InnerHTML ]
    [ txt seed ]
```

Every wrapper is a `Tyxml.Html.Unsafe.string_attrib`: "unsafe" is TyXML's term
for an attribute outside its typed element model. The value is still escaped on
output, so the XSS invariant holds.

Prefer the typed `hx_swap` over `hx_swap_raw`, and `hx_headers_inherited` over
hand-built JSON in an `Unsafe.string_attrib` — the escaping there is audited in
one place.
