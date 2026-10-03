(lang dune 3.17)

(name seed_corpus)

(generate_opam_files true)

(license MIT)

(authors "Jones Melton")

(maintainers "Jones Melton <github@jonesmelton.com>")

(source
 (github jonesmelton/dcss_seeds))

(package
 (name seed_corpus)
 (synopsis "Browse and compare DCSS seed catalogs")
 (description
  "Reads the s-expression records emitted by scripts/seed_dump_sexp.lua into the SQLite schema in schema.sql, flattening monster inventories so set-containment queries over a seed corpus are indexed lookups, and serves a read-only web interface over the result.")
 (depends
  (ocaml
   (>= 5.5.0))
  core
  core_unix
  digestif
  ppx_jane
  parsexp
  sexplib
  sqlite3
  sqlite3_utils
  (dream
   (= 1.0.0~alpha8))
  (tyxml
   (= 4.6.0))
  (tyxml-htmx
   (= :version))
  (lwt
   (>= 5.7.0))
  lwt_ppx
  (ocamlformat
   (and
    :with-dev-setup
    (= 0.29.0)))))

(package
 (name tyxml-htmx)
 (synopsis "htmx attributes for TyXML")
 (description
  "Typed TyXML attribute wrappers for the htmx hypermedia attributes (hx-get, hx-target, hx-swap, ...). Freestanding; depends only on tyxml.")
 (depends
  (ocaml
   (>= 5.5.0))
  tyxml))
