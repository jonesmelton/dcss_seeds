# Contributing

Contributions are welcome. One thing about this repository is unusual and worth
reading before you spend time on a change, because it affects what happens to
your pull request.

## This repository is a snapshot, not the development history

Development happens in a [Fossil](https://fossil-scm.org) repository. What you
see here is a periodic export of a subset of that tree, published as one commit
per release. So:

- **The history is not the real history.** Each commit is a squashed snapshot
  with a message naming the source revision. `git log` will not show you how or
  why anything changed, and `git blame` points at the snapshot that introduced a
  line, not at the change that wrote it.
- **Some paths are missing** — a few directories are deliberately not exported.
  Nothing you need to build, test, or run the project is among them, but if a
  file seems to be referenced from nowhere, that may be why.
- **Snapshots are append-only.** `main` moves forward and is never force-pushed,
  so a fork or a branch stays valid across releases. Pull requests work
  normally.

## What happens to your pull request

Your change gets applied to the Fossil tree and committed there, with you named
in the commit message. It then reaches GitHub in the next snapshot, as content
rather than as your commits.

Concretely, that means **your PR gets closed rather than merged**, with a note
saying which revision it landed as. This is not a rejection.

If that arrangement doesn't work for you, say so in the PR before doing the
work and we'll figure something out.

## Before you send it

Build and test instructions are in `README.md`; `AGENTS.md` has the deeper map
of how the pieces fit together and the domain facts that produce
plausible-looking wrong answers when forgotten. Read that second one if you're
touching the pipeline or the corpus — seeds are meaningless without a version,
and most of the subtle bugs here come from forgetting it.

```sh
just ci        # fmt-check, build, test
```

Formatting is enforced (`.ocamlformat`, checked by `dune build @fmt`); run
`just fmt` and commit the result rather than arguing with it.

## Issues

Bug reports are useful even without a fix, especially "this seed shows X but
the game generates Y" — include the seed, the version, and the depth, since a
report without all three can't be reproduced.
