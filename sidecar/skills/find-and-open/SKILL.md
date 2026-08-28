---
name: find-and-open
description: Use when the user asks to find, locate, or open a file or document they don't give a full path for -- "找一下那个文件", "那个 PDF 在哪", "打开我昨天那个文档", "find my resume", "where's that spreadsheet I made last week"
---

The user spoke a vague, human description of a file, not a path. Your job is to turn that description into the actual file, opened on screen -- not a list of candidate paths read back to them.

## Procedure

1. **Extract the search signal from the task.** Pull out whatever you can: a filename fragment, a file type (PDF, image, spreadsheet, doc, audio, video), a rough time ("昨天", "last week", "上个月"), or a topic that might appear in the filename. If the user gave you almost nothing to go on ("找一下那个文件"), that is still a signal -- it means "recent" and "somewhere obvious", not "everywhere".

2. **Search the obvious places first.** Voice users almost always mean `~/Desktop` or `~/Downloads` when they don't say where a file is -- check those before searching more broadly. Use `opentype__glob` with a pattern built from whatever signal you extracted (e.g. `*.pdf`, `*报告*`, `*resume*`). Start narrow:
   - `opentype__glob({ pattern: "*<keyword>*", path: "~/Desktop" })`
   - `opentype__glob({ pattern: "*<keyword>*", path: "~/Downloads" })`

3. **Widen only if the narrow search comes up empty.** Retry with a broader pattern (drop the keyword, just match the extension) or a broader root (`~/Documents`, then `~` itself). `opentype__glob`'s default root is already `~` and it already skips `.git`, `node_modules`, `Library`, and other dot-directories, so a home-directory search is still bounded -- use it rather than falling back to `opentype__bash find`.

4. **If a time signal was given, prefer the most recently modified match.** `opentype__glob` returns paths; if you need modification times to break a tie, `opentype__bash` with `ls -lt` or `opentype__python` with `os.path.getmtime` on the small candidate set is fine -- don't shell out for the search itself, only for sorting a handful of already-found candidates.

5. **Decide, don't ask, when there's one clear match.** If exactly one file plausibly matches, that's the answer -- proceed to step 6.

6. **Multiple plausible matches: ask, don't guess and don't open all of them.** If several files could be what the user meant, call `opentype__ask_user` with the candidate list (name + rough date is usually enough context) and open the one they pick. Never open every candidate "just in case" -- that scatters windows across their screen for a request that expects exactly one file to appear.

7. **No match found: say so plainly.** Report what you searched (which folders, which pattern) so the user can redirect you ("try Documents instead") rather than getting a bare "not found".

8. **Open it.** Once you have the one right file, call `opentype__open_file` on it -- this is the deliverable. A path read back in text is not the same as the file actually appearing on screen; the whole point of this skill is closing that gap. Still name the file and its path in your final answer, but the opening is the result, not the sentence describing it.

## Notes

- "Find" and "open" are the same request here, not two separate ones -- someone asking you to locate a file wants it in front of them, which is why the last step is never optional when exactly one match exists.
- If the request is actually a question a sentence can answer ("有没有一个叫成本核算的表格" / "is there a file named X") rather than a request to see the file, answer in text and skip opening anything.
