# CLAUDE.md — Boxer3D agent schema

This repo ships with an LLM-maintained wiki under `wiki/`. The wiki is the
project's handoff document. A new collaborator (human or agent) should be able
to open `wiki/index.md`, skim the entries, and drill in.

Pattern: [Karpathy, "LLM Wiki"](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f).
Three layers:

- **Raw sources** (`raw/`) — immutable reference docs the wiki is built from.
  Read-only. Never rewritten.
- **Wiki** (`wiki/`) — LLM-owned markdown. Cross-referenced pages. This is
  what the user reads.
- **Schema** (this file) — how the wiki is organised and maintained.

The code under `boxer/` and `convert/` is the implementation; the wiki is the
story about *why it is the way it is*. Read both.

## Directory layout

```
Boxer3D/
├── CLAUDE.md                    ← this file (schema)
├── README.md                    ← public-facing GitHub readme
├── raw/                         ← immutable reference docs
│   ├── README.md
│   └── karpathy-llm-wiki.md     ← the gist this pattern comes from
├── wiki/
│   ├── index.md                 ← catalog — start here
│   ├── log.md                   ← chronological event log
│   ├── overview.md              ← 1-page project summary
│   ├── architecture.md          ← end-to-end data flow
│   ├── components/              ← one page per Swift file
│   ├── concepts/                ← non-obvious mechanisms
│   ├── workflows/               ← build, convert, mesh authoring
│   ├── decisions.md             ← ADR-style choices with rationale
│   ├── gotchas.md               ← foot-guns to avoid
│   ├── todos.md                 ← backlog
│   └── glossary.md              ← terminology
├── boxer/                       ← iOS app (Xcode target)
└── convert/                     ← offline BoxerNet → CoreML pipeline
```

## Conventions

- Every wiki page has YAML frontmatter:
  ```yaml
  ---
  title: <page title>
  updated: <YYYY-MM-DD>
  source: <which files or memories this came from, optional>
  ---
  ```
- Link to other wiki pages with relative markdown links: `[fsd-mode](../concepts/fsd-palette.md)`.
- Reference code with `file:line` — e.g. `boxer/FSDMode.swift:174` — so the
  reader can jump. Re-verify line numbers when you edit the page.
- Keep pages short. If a page grows past ~250 lines, split it.
- Facts that will go stale fast (who's on call, ticket numbers, dates of
  in-flight work) belong in `wiki/log.md`, not in topic pages.

## Operations

**Ingest.** When the user drops a new reference (paper, gist, screenshot) into
`raw/`, or lands a significant code change, the LLM:
1. Reads the new source.
2. Writes a summary page if the source is a doc, or updates affected
   component / concept / decision pages if it's a code change.
3. Updates `wiki/index.md` and appends an entry to `wiki/log.md`.

**Query.** When answering a project question, the LLM reads `wiki/index.md`
first, then drills into relevant pages. Cite pages inline. If the answer
creates new insight worth keeping, file it back as a wiki page and log the
ingest.

**Lint.** Periodically (or on request) scan for:
- Stale code references (`file:line` that no longer resolves).
- Duplicated content — fold into one page, link from the other.
- Orphans — pages not linked from `index.md`.
- Contradictions — newer pages that supersede old claims; mark the old
  claim, link forward.
- Dates — pages with `updated:` older than six months should be
  re-validated against current code.

## Log format

`wiki/log.md` is append-only, newest at the top. Each entry:

```markdown
## [YYYY-MM-DD] <kind> | <short title>

<1-3 sentence body>

Touched: <wiki pages / code files>
```

`<kind>` ∈ { `ingest`, `decision`, `ship`, `bug`, `lint`, `handoff`, `note` }.
Grep-friendly: `grep "^## \[" wiki/log.md | head -10`.

## Style rules

- Traditional Chinese (繁體中文) is fine and preferred for internal notes if
  the user writes in it. Code / identifiers / API names stay in English.
- Never edit anything under `raw/` — it's the source of truth.
- Never write secrets (API keys, signing certs, bundle IDs tied to accounts)
  into wiki pages. `Signing.xcconfig` is gitignored for a reason.
- The BoxerNet weights are **CC-BY-NC-4.0** (Meta). Any doc that talks about
  redistribution or commercial use must flag this.

## Related project-wide facts

- Device: iPhone 15 Pro Max (LiDAR). Simulator won't work — no `ARWorldTrackingConfiguration` there.
- Xcode 16+ uses `PBXFileSystemSynchronizedRootGroup` for `boxer/` — drop a
  new `.swift` or `.usdz` into that folder and it's auto-included. No
  `project.pbxproj` surgery required.
- The full wiki plus this file should onboard a new iOS / ML engineer in
  ~30 minutes.
