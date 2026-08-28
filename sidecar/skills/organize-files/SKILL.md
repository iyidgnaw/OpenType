---
name: organize-files
description: Use when the user asks to tidy up, sort, organize, or archive a folder -- "把下载文件夹整理一下", "桌面太乱了", "整理一下这些文件", "clean up my downloads", "sort these files by type"
---

The user wants a messy folder to become a tidy one, without having to specify the rules themselves. Your job is to infer a sensible organization scheme, apply it, and report what moved where -- in a way they could undo by reading your summary.

## Procedure

1. **Survey before you act.** Use `opentype__list_dir` (or `opentype__glob` with `pattern: "*"` if you need it recursively) on the target folder to see what's actually there -- file names, extensions, and roughly how many of each. Never start moving files based on a guess about what's in the folder.

2. **Pick an organization scheme from what you see, in this order of preference:**
   - **By file type** is the default and usually what "整理一下" means with no further detail: images into `Images/`, PDFs and docs into `Documents/`, spreadsheets into `Spreadsheets/`, archives (.zip, .dmg) into `Archives/`, installers into `Installers/`, everything else stays or goes into `Other/`.
   - **By date** (e.g. `2026-08/`) when the folder is dominated by one file type already (e.g. it's all screenshots or all PDFs) -- type-based folders would just recreate the one folder you started with.
   - **By a topic the user named** ("把发票整理到一个文件夹" -- invoices) when the request itself specifies the grouping. A named grouping always overrides the type/date defaults above.

3. **Create destination folders and move files, one type/group at a time.** `opentype__move_file` creates parent directories automatically, so you don't need a separate mkdir step -- just move each file to `<target>/<Category>/<filename>`. Work through the survey list systematically rather than one-off; skip files already inside a folder that matches the scheme (don't re-move something already sorted).

4. **Never overwrite.** `opentype__move_file` refuses by design when the destination already exists -- this is deliberate, not a bug to work around. If it errors because a same-named file is already in the destination folder, leave the source file where it is and note the conflict in your final summary rather than renaming around it silently.

5. **Leave folders alone.** Don't recurse into subfolders the user didn't ask about, and don't move other folders (e.g. an existing `Work/` folder) into your new category folders -- "整理一下下载文件夹" means the loose files sitting directly in it, not a full filesystem reorganization.

6. **Report what happened.** Summarize the categories you created and roughly how many files went into each ("12 张图片 -> Images/, 5 份 PDF -> Documents/, 3 个安装包 -> Installers/"), and call out anything you skipped (conflicts, folders you left untouched) so the user can go check if something looks off.

## Notes

- If the user wants something removed rather than filed away (old installers, duplicate screenshots), use `opentype__trash` -- never a real delete. Trash is always recoverable; that's the whole reason it's the tool for this, not `opentype__bash rm`.
- If the folder is small (a handful of files) and clearly already organized, say so rather than inventing busywork.
