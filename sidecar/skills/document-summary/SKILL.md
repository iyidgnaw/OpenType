---
name: document-summary
description: Use when the user asks what a document says or wants it summarized -- "这个 PDF 讲了什么", "总结一下这份文档", "summarize this document", "what does this file say", "帮我看看这份合同大概是什么内容"
---

The user wants to understand a document's content without reading it themselves. Your job is to locate it (if not already given), extract its actual text, and produce a summary that reflects what's really in it -- not a guess based on the filename or a partial skim.

## Procedure

1. **Locate the file if a path wasn't given.** Use `opentype__glob` (check `~/Desktop`/`~/Downloads` first) matched on file type and any keyword from the request, exactly like `find-and-open`'s search step. If more than one plausible file matches, ask which one via `opentype__ask_user` rather than summarizing the wrong document.

2. **Extract real text, don't guess from the filename or extension.**
   - Plain text / Markdown: `opentype__read_file` directly.
   - PDF: use `opentype__python` with a PDF text-extraction library if one is available in the environment (e.g. `pypdf`/`PyPDF2`/`pdfplumber` -- try importing, and if none are installed say so rather than silently failing). Extract text page by page if the library supports it, since a single flat string can lose structure needed to describe the document accurately.
   - Word documents (`.docx`): `opentype__python` with `python-docx` if available; if not, and no conversion path exists, tell the user you can't read this format rather than fabricating a summary from the filename.
   - If the document is genuinely unreadable by any available tool (a scanned image PDF with no text layer, an exotic format), say so plainly -- do not produce a summary from the filename or from partial garbled extraction.

3. **Read the extraction output before summarizing, not just its length.** A failed or partial extraction can still return SOME text (e.g. just headers, or garbled characters from a bad encoding) -- sanity-check that what came back actually reads like prose before treating it as the document's content.

4. **For long documents, extract in sections rather than truncating blindly.** If the raw text is very long, work through it in chunks (e.g. read/extract by page range) and build the summary from all of it rather than only the first N characters that happen to fit -- a summary of only the introduction is not a summary of the document.

5. **Match summary depth to what was asked.** "这个 PDF 讲了什么" wants a short paragraph -- the gist, not a page-by-page recap. "总结一下这份合同的关键条款" wants specific structured points (parties, term, key obligations, dates). Default to a concise paragraph plus 3-5 bullet points of the most important specifics (key facts, numbers, names, dates) when the request doesn't specify depth.

6. **Flag anything that looks important but ambiguous or concerning** (an unusual clause in a contract, a number that seems like it might be a typo, a date that's already passed) as a brief note after the summary -- don't bury it, but don't over-editorialize either.

7. **Deliver the summary as the final answer.** Only call `opentype__open_file` on the source document too if the user's phrasing suggests they also want to look at it themselves ("给我看看" alongside "讲了什么"); a pure "what does this say" question is answered in text alone.

## Notes

- Never summarize a document you have not actually extracted text from -- a summary built from the filename, a partial read, or an assumption about what a document "probably" contains is worse than saying you couldn't read it.
