# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A **source-code comparison study** of two open-source query engines: Trino and StarRocks. It is a research/documentation repository, not an application — there is no build, no test suite, and no package manifest. The deliverables are analysis documents, not shipped code.

Upstream sources under comparison:
- Trino — https://github.com/trinodb/trino.git
- StarRocks — https://github.com/StarRocks/starrocks.git

As of the initial commit the repo contains only `README.md` and `.gitignore`; the directory layout below is the intended structure and must be created as work proceeds.

## Directory layout (per README.md)

| Directory | Purpose |
|---|---|
| `works/` | Cloned Trino / StarRocks source trees used for analysis. Working area — do not commit upstream source. |
| `plan/` | Comparison plan documents (what to compare, in what order, with what criteria). |
| `scripts/` | Code that performs the comparison / extraction work. |
| `docs/` | Comparison results — the primary output of this repo. |

Because `works/` holds full upstream clones, keep it out of commits (`.gitignore` currently only covers Jekyll/GitHub-Pages artifacts — add an entry before cloning into it).

## Conventions

- **Documents are written in Korean.** `README.md` and the author's related work (see `/home/ubuntu/work/trino/trino-k8s/docs`) use Korean prose with English technical terms kept as-is. Match that when writing into `plan/` or `docs/`.
- Docs are numbered-prefix Markdown (`01-...md`, `03-02-...md`) in the sibling Trino docs repo; follow the same ordering convention here so a reading order is implied by filename.
- `.gitignore` is configured for a Jekyll / GitHub Pages build, so `docs/` output is expected to be publishable Markdown rather than generated HTML.

## Working on comparisons

A comparison task normally spans two large unfamiliar codebases at once. Prefer:
1. Read or write the relevant `plan/` document first — it defines the comparison axis (e.g. optimizer, connector, memory management) and prevents unbounded exploration.
2. Analyze under `works/<engine>/` with search-first tooling; both trees are far too large to read exhaustively.
3. Write the result to `docs/` with concrete file/line citations into the upstream trees so claims are checkable.

## Related context outside this repo

`/home/ubuntu/work/trino/trino-k8s/docs` (an additional working directory in this session) holds the author's Trino operations, tuning, and architecture notes — useful background on which Trino behaviors matter in practice when choosing comparison axes.
