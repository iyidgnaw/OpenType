# Reference implementations

Standing design references for OpenType's redesign. Before re-deriving a
design decision in either area below, read the relevant file here first —
it's a navigational index into the source repo/docs, not a copy of them.

| Area | Reference project | Notes |
| --- | --- | --- |
| Speech-to-text | [OpenTypeless](opentypeless-stt.md) | `/Users/diywang/hackathon/opentypeless` (Tauri/Rust + React). Has a manual dictionary + correction-rule store, but no ASR-level biasing and no automatic/phonetic correction — that part is a genuine gap, not prior art to copy. |
| Context/memory management | [OpenClaw](openclaw-context-memory.md) | `/Users/diywang/hackathon/openclaw` (large pnpm monorepo, also published at https://docs.openclaw.ai/). Markdown-file memory tiers + SQLite index, a nightly "dreaming" consolidation pass, and provenance-based trust (not a simple confirmed/learned split). No entity/vocabulary-correction feature — that's also on OpenType to build. |

Both notes were produced by reading the source repos' own documentation
first and spot-checking a handful of claims against code, per the project's
research policy: don't re-read a large reference repo from scratch when a
question comes up again — check here first, and only go back to the source
repo/docs site if this index doesn't answer it.
