---
name: meeting-notes-to-todos
description: Use when the user asks to turn meeting notes, a transcript, or a rambling recap into a todo list or action items -- "把这段会议记录整理成待办", "帮我提取一下会议里的行动项", "turn these notes into a task list", "what are the action items from this"
---

The user handed you (via CONTEXT, a selected file, or the task text itself) raw meeting notes -- often unstructured, spoken-style, with action items buried among discussion. Your job is to extract a clean, actionable todo list, not to summarize the meeting.

## Procedure

1. **Locate the source material.** It usually arrives as `CONTEXT` (selected text) on the task itself. If the user instead refers to a file ("那份会议记录" / "the notes I saved earlier"), use `opentype__glob`/`opentype__read_file` to find and read it first -- don't proceed on a task description alone if there's a real document to read.

2. **Read the whole thing before extracting anything.** An action item is often stated once, briefly, in the middle of a longer discussion of *why* it matters -- reading only the first pass risks missing items buried later, and reading in fragments risks manufacturing items that were only discussed, not decided.

3. **Extract only real action items, not discussion.** An item belongs on the list if the notes show intent to DO something -- "张三会跟进合同", "we need to send the proposal by Friday", "I'll check with finance". A topic that was merely discussed, debated, or noted as a concern without a stated next step does NOT become a todo -- inventing action items that weren't actually assigned is worse than leaving a gap, since it puts words in someone's mouth.

4. **Capture owner and deadline whenever the notes state them.** Format each item as `[Owner] Action (by Deadline)` when both are present, `[Owner] Action` when only an owner is stated, or just `Action` when neither is -- don't invent an owner or a date that isn't in the source. "TBD" or leaving it out is honest; guessing "next week" because the meeting felt urgent is not.

5. **Group related items if there are many.** For a long meeting with items from multiple topics/workstreams, group under short headers (the topic name) rather than presenting one flat list of 20 items -- but don't over-engineer this for a short set of 3-5 items, a flat list is clearer there.

6. **Deliver the list as the final answer, in Markdown** (checkboxes `- [ ] item` read well and are directly usable). Don't call `opentype__write_file` to save it unless the user explicitly asked you to save/file it somewhere -- the default expectation for this skill is a draft answer they can copy, per how Ask/Agent results are always delivered (clipboard + optional auto-insert), not a new file appearing on disk.

7. **If you genuinely found no action items** (the notes were pure discussion/FYI with nothing anyone committed to), say that plainly rather than padding the list with discussion points reframed as tasks.

## Notes

- Chinese and English notes are handled identically -- extract the same way regardless of source language, and reply in whichever language the user's task was phrased in.
- If the notes are long enough that you're unsure you've seen everything, re-read rather than extract from a partial view -- a missed but real action item is a bigger failure here than taking one more read pass.
