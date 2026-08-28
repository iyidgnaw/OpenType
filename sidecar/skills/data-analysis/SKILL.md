---
name: data-analysis
description: Use when the user asks to compute, summarize, or analyze data in a spreadsheet or CSV -- "这个表格帮我算一下", "统计一下这个 csv", "算一下这个月的总支出", "what's the average in this column", "analyze this data file"
---

The user wants a real computed answer from actual data, not a guess based on skimming a few rows. Your job is to locate the file, load it properly, compute the specific thing they asked for (or a sensible summary if they didn't specify), and report the actual numbers.

## Procedure

1. **Locate the file if it wasn't given directly.** If the task doesn't name an exact path, use `opentype__glob` to find it (check `~/Desktop` and `~/Downloads` first, per the usual voice-request convention) -- match on extension (`*.csv`, `*.xlsx`) and whatever keyword the user gave.

2. **Never eyeball a table by reading raw text and guessing at the math.** Use `opentype__python` to actually load and compute -- this is the whole point of the skill. Read the first several lines first (`opentype__read_file` with a line limit, or a quick `head`-style Python snippet) to understand the shape: what are the columns, is there a header row, what's the delimiter, are there obviously bad/missing values.

3. **Load with the right tool for the format:**
   - CSV / TSV: `pandas.read_csv(path)` if pandas is available in the environment; otherwise Python's builtin `csv` module. Try pandas first since it handles type inference and missing values far more robustly than hand-rolled parsing.
   - Excel (`.xlsx`): `pandas.read_excel(path)` (needs `openpyxl` — if the import fails, fall back to reporting that and asking whether a CSV export exists instead of hand-parsing XML).
   - If pandas genuinely isn't available and the file is simple (few columns, no merged cells), a manual `csv.DictReader` pass is an acceptable fallback -- don't give up just because pandas is missing.

4. **Compute exactly what was asked.** If the user named a specific column or operation ("总支出" / "average of column X" / "how many rows have status = 完成"), compute exactly that -- don't substitute a different, easier metric. If the request is vague ("算一下" / "summarize this"), give a short, useful default summary: row count, column names, and basic stats (sum/mean/min/max) for numeric columns, plus value counts for any obviously categorical column.

5. **Handle messy data explicitly, don't silently drop it.** If some rows have missing or malformed values in the column you're computing over, say how many were excluded and why, rather than quietly computing over a smaller set the user doesn't know about.

6. **Report numbers, not just a description of what you did.** "总支出是 ¥12,450.30，来自 87 笔有效记录（3 笔缺失金额已排除）" is the answer; "I calculated the total expenses" is not. Include the actual figure(s) in your final response every time.

7. **Offer a next step only if it's clearly useful and doesn't require guessing intent** -- e.g. if you found several plausible interpretations of an ambiguous column, mention it, but don't build out a full secondary analysis nobody asked for.

## Notes

- Keep the Python snippet itself simple and single-purpose per call -- load, compute, print the result -- so a failure (missing library, bad path, malformed file) is easy to diagnose from the tool's own error output rather than buried inside a long script.
- If the file is large, printing the whole loaded dataframe is wasteful and gets clamped uselessly -- print only the specific numbers/aggregates you computed, plus `.head()` if a shape sanity-check is useful.
