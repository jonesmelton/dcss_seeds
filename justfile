# Recipes run against the local switch in _opam/ whether or not the caller's
# shell has `opam env` applied.
export OPAM_SWITCH_PREFIX := justfile_directory() / "_opam"
export OCAMLPATH := justfile_directory() / "_opam/lib"
export CAML_LD_LIBRARY_PATH := justfile_directory() / "_opam/lib/stublibs"
export PATH := justfile_directory() / "_opam/bin:" + justfile_directory() / "builds/sqlite/bin:" + env_var("PATH")
export PKG_CONFIG_PATH := justfile_directory() / "builds/sqlite/lib/pkgconfig:" + env_var_or_default("PKG_CONFIG_PATH", "")

# list recipes
default:
    @just --list

# build (dev profile: warnings-as-errors)
build:
    dune build --profile dev

# run the web server
run:
    dune exec bin/main.exe

# run the web server, rebuilding and restarting on source changes
# Output is teed so tooling can read watcher build results without the lock.
dev:
    dune exec --watch bin/main.exe 2>&1 | tee /tmp/seed-explorer-dev.log

# Without a generator running, every deepen request is refused -- correctly,
# but a reader cannot tell that from the feature being broken.
# serve the deepen queue: claim seeds one at a time and run crawl for them
deepen db="corpus.db":
    dune exec bin/deepen.exe -- -db {{db}}

# Deliberately separate from `dev`: the generator writes to the real corpus and
# spawns crawl, which is a wider blast radius than an edit-reload loop wants on
# every save. The trap is load-bearing -- without it Ctrl-C leaves a generator
# running against your corpus.
# the web server and a generator together, for working on deepening
dev-all db="corpus.db":
    #!/usr/bin/env sh
    set -eu
    dune build --profile dev
    # The built binary directly, not `dune exec`: dune holds the _build lock for
    # as long as the process it launched lives, so a backgrounded `dune exec`
    # would stop the watcher from ever starting.
    ./_build/default/bin/deepen.exe -db {{db}} &
    generator=$!
    trap 'kill $generator 2>/dev/null || true' EXIT INT TERM
    dune exec --watch bin/main.exe 2>&1 | tee /tmp/seed-explorer-dev.log

# run the ingester over stdin: ... | just ingest -db corpus.db
ingest *args:
    dune exec bin/ingest.exe -- {{args}}

# build the seed-granular search index over a corpus
index db="corpus.db" *args:
    dune exec bin/index.exe -- -db {{db}} {{args}}

# check the search store against the SQL path: just equiv corpus.db 0.34.1
equiv db build *args:
    dune exec bin/search_equiv.exe -- -db {{db}} -build {{build}} {{args}}

# time the search store against the SQL path, first and deep pages
bench db build *args:
    dune exec bin/search_bench.exe -- -db {{db}} -build {{build}} {{args}}

# run the test suite
test:
    dune runtest

# re-run tests even when nothing changed
test-force:
    dune runtest --force

# accept new/changed expect-test output
promote:
    dune runtest --auto-promote

# apply ocamlformat in place
fmt:
    dune build @fmt --auto-promote

# check formatting without modifying (CI gate)
fmt-check:
    dune build @fmt

# create a database from schema.sql
db path="corpus.db":
    sqlite3 -init /dev/null {{path}} < schema.sql

# install the locked dependencies into the local switch, over the pinned sqlite
deps: sqlite
    opam install . --deps-only --with-test --with-dev-setup --locked --yes

# build the pinned sqlite into builds/sqlite (no-op when already built)
sqlite:
    tools/provision-sqlite

# rebuild the sqlite bindings against builds/sqlite, after bumping the pin
sqlite-relink: sqlite
    opam reinstall sqlite3 --yes

# regenerate the *.opam.locked files after changing depends in dune-project
lock:
    opam lock .

# build, format-check, and test — the merge gate
ci: fmt-check build test
