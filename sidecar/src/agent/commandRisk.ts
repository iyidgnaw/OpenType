/**
 * Reads one agent tool call and says whether it names a destructive operation
 * (P1-6, `docs/superpowers/specs/2026-08-14-product-batch-plan.md`,
 * "P1-6 下发前确认 + 破坏性命令审批").
 *
 * THE STANCE THIS SERVES. YOLO is still the default: no sandbox, no
 * confirmation for ordinary tool calls (`agent/approval.ts`). This function
 * exists so that exactly one narrow class -- named destructive shell/python
 * operations -- can be routed through a card before it runs. That narrowness
 * is the feature, not a limitation waiting to be lifted: a guard that fires
 * often trains the user to approve without reading, and an approval nobody
 * reads is worse than no approval, because it manufactures both the
 * interruption and the complacency. So false positives are treated as bugs of
 * the same severity as misses, and the classifier is judged on both edges.
 *
 * WHAT IT PROMISES, EXACTLY. "This call names an operation that deletes,
 * overwrites, or hands bytes to another interpreter." Not "this call is
 * dangerous", and not "anything that writes". In particular the asymmetry
 * between the two executing tools is deliberate:
 *
 *   - bash: a truncating `>` redirect IS classified, because the shell has one
 *     small, readable set of ways to spell "write over this path".
 *   - python: `shutil.rmtree` / `os.remove` / `os.rename` / `subprocess.*` are
 *     classified, but a general file write is NOT. Python's write surface is
 *     unbounded -- `open(p, "w")`, `Path.write_text`, `json.dump`,
 *     `df.to_csv`, `np.save`, a C extension -- so a rule catching `open(p,"w")`
 *     and nothing else would prompt on the single most common legitimate thing
 *     an agent script does while missing every other way to do the same thing.
 *     A guard that is arbitrary about which writes it notices is exactly the
 *     guard people learn to click through. Named operations can be recognised
 *     honestly; general writes cannot, and pretending otherwise buys nothing.
 *
 * WHAT IT DOES NOT PROMISE. It is a pure function of one call's arguments, so
 * it cannot see a script written in one call and run in the next, a command
 * name spliced together from variables, or the contents of a local file passed
 * to `bash setup.sh`. Those gaps are enumerated in `test/agent/commandRisk.test.ts`
 * and are real; the threat this is actually built for is a misheard or
 * over-eager task destroying the user's files, not an adversary who controls
 * the command line. Do not read this module as a security boundary.
 *
 * Two more, found by attacking this file during review and left open rather
 * than left silent. `source ~/x.sh` and `. ~/x.sh` are the test file's gap 4
 * ("a local script's contents") wearing a name that does not look like one --
 * they run a file nobody read, in the current shell. And python indirection
 * beyond one alias hop -- a module name assembled at runtime, `getattr` on
 * something other than the three modules named below -- is bash's gap 2 in
 * python's spelling: unreadable without running the program.
 *
 * FAIL-CLOSED, BUT ONLY INSIDE THE EXECUTING TOOLS. For bash and python we
 * know arbitrary code is about to run, so a payload we cannot read (missing,
 * wrong-typed, empty, unbalanced quotes) classifies destructive -- guessing
 * "safe" about something unreadable is how the guard gets bypassed, since the
 * model need not defeat the classifier, only confuse it. Outside that boundary
 * the guard abstains: an unrecognised tool name is an MCP tool the user
 * configured, we have no args grammar for it, and classifying it destructive
 * would tax every MCP call with a card that carries no signal.
 */

export type CommandRisk = "safe" | "destructive";

const BASH_TOOL = "opentype__bash";
const PYTHON_TOOL = "opentype__python";

// ---------------------------------------------------------------------------
// Python
// ---------------------------------------------------------------------------

/**
 * Named python operations that delete, move, overwrite, or escape to a shell.
 *
 * Matching is textual rather than syntactic: tokenising python would be a
 * parser this feature does not need, and the cost of not having one is one
 * extra card on the rare script that merely *mentions* `os.remove` in a
 * docstring.
 */
const PYTHON_DESTRUCTIVE: readonly RegExp[] = [
  // Deletion.
  /\bos\s*\.\s*(?:remove|removedirs|rmdir|truncate|ftruncate)\s*\(/,
  /\bshutil\s*\.\s*rmtree\s*\(/,
  // Covers both `os.unlink(p)` and `Path("x").unlink()`.
  /\.\s*unlink\s*\(/,
  /\.\s*rmdir\s*\(/,
  // Bare names with no benign second meaning, which is what catches the
  // module-alias spellings the dotted rules above miss: `from shutil import
  // rmtree` and `import shutil as sh; sh.rmtree(...)` both end up here.
  /\brmtree\s*\(/,
  /\bcopytree\s*\(/,
  /\bremovedirs\s*\(/,
  // The import line, for the names that DO have a benign second meaning as a
  // bare call -- `remove`, `move`, `copy`, `run`. `list.remove(x)` is far too
  // common to match at the call site, but `from os import remove` states the
  // intent unambiguously and is what a model writes naturally, not only
  // evasively.
  /\bfrom\s+os\s+import\b[^\n]*\b(?:remove|removedirs|rmdir|unlink|rename|renames|replace|system|popen|truncate|exec\w*|spawn\w*)\b/,
  /\bfrom\s+shutil\s+import\b[^\n]*\b(?:rmtree|move|copy|copy2|copyfile|copyfileobj|copytree)\b/,
  /\bfrom\s+subprocess\s+import\b/,
  // Moves and overwriting copies -- `mv` and `cp` in python's spelling. Left
  // in for the same reason `cp` is destructive in bash: a model told to
  // overwrite a file must not discover that the python tool is the quiet way
  // to do what the bash tool asks about.
  /\bshutil\s*\.\s*(?:move|copy|copy2|copyfile|copyfileobj|copytree)\s*\(/,
  /\bos\s*\.\s*(?:rename|renames|replace)\s*\(/,
  // Escapes to a shell. Unclassifiable by anything above, therefore
  // destructive -- including `subprocess.run(["ls"])`, which is harmless today
  // and one edit away from not being. Refusing to guess is the point.
  /\bos\s*\.\s*(?:system|popen|exec\w*|spawn\w*)\s*\(/,
  /\bsubprocess\s*\./,
  /\bpty\s*\.\s*spawn\s*\(/,
  // Python assembling its own bytes after we stopped looking -- bash's `eval`
  // rule in python's spelling, and destructive for the same reason: what runs
  // is not what is written. `ast.literal_eval(` and `cursor.execute(` do not
  // match (`_` is a word character, and `execute` is not `exec`).
  /\b(?:exec|eval)\s*\(/,
  /\b__import__\s*\(/,
  /\bimport_module\s*\(/,
  /\brunpy\s*\./,
  // Reaching a module's attributes by string. Scoped to the three modules
  // whose attributes this file has rules about, so `getattr(obj, "name")` --
  // ordinary python -- is untouched.
  /\bgetattr\s*\(\s*(?:os|shutil|subprocess)\b/,
];

/**
 * `import shutil as sh` + `sh.rmtree(...)`, rewritten back to `shutil.rmtree`
 * so the dotted rules above see the name they were written for.
 *
 * Aliasing is the one indirection worth undoing here because it costs three
 * lines and because the alternative -- matching `.remove(` or `.copy(` at any
 * call site -- would fire on `list.remove(x)` and `dict.copy()`, i.e. on
 * ordinary python. Deeper indirection (`getattr`, `importlib`) is caught on
 * the indirection itself rather than by resolving it.
 */
const MODULE_ALIAS = /\bimport\s+(os|shutil|subprocess|pty|runpy)\s+as\s+([A-Za-z_]\w*)/g;

function resolveModuleAliases(code: string): string {
  let resolved = code;
  for (const [, module, alias] of code.matchAll(MODULE_ALIAS)) {
    if (!module || !alias || alias === module) continue;
    resolved = resolved.replace(new RegExp(`\\b${alias}\\s*\\.`, "g"), `${module}.`);
  }
  return resolved;
}

function classifyPythonSource(code: string): CommandRisk {
  const resolved = resolveModuleAliases(code);
  return PYTHON_DESTRUCTIVE.some((pattern) => pattern.test(resolved)) ? "destructive" : "safe";
}

// ---------------------------------------------------------------------------
// Bash: tokenising
// ---------------------------------------------------------------------------

/** One word of a command line, plus whether quoting produced it. */
interface Word {
  /** The token's value with quotes removed. */
  text: string;
  /** True when any part of it came from `'...'` or `"..."`. */
  quoted: boolean;
}

/** One redirection, with its operator (fd prefix included) and its target. */
interface Redirect {
  op: string;
  target: string | undefined;
}

/**
 * One command in a chain. Segments are split on `;`, `&&`, `||`, `|`, `&` and
 * newline, and every rule below is scoped to a single segment -- that scoping
 * is what keeps `ls -R && chmod 644 x` from reading as a recursive chmod.
 */
interface Segment {
  words: Word[];
  redirects: Redirect[];
  /** `$(...)` / backtick bodies found here; each is classified on its own. */
  substitutions: string[];
  /** True when this segment is the right-hand side of a `|`. */
  pipedInto: boolean;
}

function newSegment(pipedInto: boolean): Segment {
  return { words: [], redirects: [], substitutions: [], pipedInto };
}

/** `$IFS` / `${IFS}`, anchored at the start of the remaining line. */
const IFS_EXPANSION = /^\$(?:IFS(?![A-Za-z0-9_])|\{IFS\})/;

/** Index of the `)` closing the `(` at `open`, or -1. Skips quoted regions. */
function matchClosingParen(line: string, open: number): number {
  let depth = 0;
  for (let i = open; i < line.length; i += 1) {
    const c = line[i];
    if (c === "\\") {
      i += 1;
      continue;
    }
    if (c === "'") {
      const end = line.indexOf("'", i + 1);
      if (end < 0) return -1;
      i = end;
      continue;
    }
    if (c === '"') {
      let j = i + 1;
      while (j < line.length && line[j] !== '"') {
        if (line[j] === "\\") j += 1;
        j += 1;
      }
      if (j >= line.length) return -1;
      i = j;
      continue;
    }
    if (c === "(") depth += 1;
    else if (c === ")") {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

/** Reads a `"..."` region, collecting the substitutions that run inside it. */
function readDoubleQuoted(
  line: string,
  start: number,
  substitutions: string[]
): { text: string; next: number } | null {
  let text = "";
  let i = start + 1;
  while (i < line.length) {
    const c = line[i];
    if (c === '"') {
      return { text, next: i + 1 };
    }
    if (c === "\\") {
      // Inside double quotes a backslash only escapes these; elsewhere it is
      // a literal backslash.
      const next = line[i + 1];
      if (next === '"' || next === "\\" || next === "$" || next === "`" || next === "\n") {
        if (next !== "\n") text += next;
        i += 2;
        continue;
      }
      text += c;
      i += 1;
      continue;
    }
    if (c === "$" && line[i + 1] === "(") {
      const end = matchClosingParen(line, i + 1);
      if (end < 0) return null;
      // Substitution bodies run; they are judged separately rather than
      // becoming part of this word's text.
      substitutions.push(line.slice(i + 2, end));
      i = end + 1;
      continue;
    }
    if (c === "`") {
      const end = line.indexOf("`", i + 1);
      if (end < 0) return null;
      substitutions.push(line.slice(i + 1, end));
      i = end + 1;
      continue;
    }
    text += c;
    i += 1;
  }
  return null;
}

// `(` and `)` stop a target for the same reason they separate words: they are
// shell metacharacters, so `cat <(rm -rf ~)` is a redirect with NO target
// followed by a subshell, not a redirect to a file called `(rm`.
const REDIRECT_STOP = new Set([" ", "\t", "\r", "\n", ";", "&", "|", "<", ">", "(", ")"]);

/**
 * Reads the word a redirection points at, starting after its operator.
 *
 * `substitutions` is the segment's list, not a throwaway: a `$(...)` in a
 * redirect target runs exactly as it does anywhere else (`cat < "$(…)"`), so
 * dropping it here would be a hole with no upside.
 */
function readRedirectTarget(
  line: string,
  start: number,
  substitutions: string[]
): { target: string | undefined; next: number } | null {
  let i = start;
  while (i < line.length && (line[i] === " " || line[i] === "\t")) i += 1;
  let target = "";
  let sawAny = false;
  while (i < line.length && !REDIRECT_STOP.has(line[i] as string)) {
    const c = line[i];
    if (c === "\\") {
      if (i + 1 >= line.length) return null;
      target += line[i + 1];
      i += 2;
      sawAny = true;
      continue;
    }
    if (c === "'") {
      const end = line.indexOf("'", i + 1);
      if (end < 0) return null;
      target += line.slice(i + 1, end);
      i = end + 1;
      sawAny = true;
      continue;
    }
    if (c === '"') {
      const read = readDoubleQuoted(line, i, substitutions);
      if (!read) return null;
      target += read.text;
      i = read.next;
      sawAny = true;
      continue;
    }
    target += c;
    i += 1;
    sawAny = true;
  }
  return { target: sawAny ? target : undefined, next: i };
}

/**
 * Splits a command line into segments. Returns `null` when it cannot be read
 * at all -- an unbalanced quote means we cannot say where the string ends, so
 * we cannot say that what follows it is not a command.
 *
 * A heredoc body is deliberately *not* special-cased: because newline is a
 * separator, `bash <<'EOF'\nrm -rf ~/build\nEOF` splits into segments and the
 * body is judged as the commands it is. That reads a heredoc of prose as
 * commands too, which errs toward one extra card rather than a miss.
 */
function tokenize(line: string): Segment[] | null {
  const segments: Segment[] = [];
  let current = newSegment(false);
  let word = "";
  let quoted = false;

  /** True while nothing of the current segment has been read yet. */
  const segmentIsEmpty = (): boolean =>
    current.words.length === 0 &&
    current.redirects.length === 0 &&
    word.length === 0 &&
    !quoted;

  const endWord = (): void => {
    // An unquoted empty word is an expansion that produced nothing (`$(...)`
    // on its own); a quoted one is a real, empty argument.
    if (word.length > 0 || quoted) current.words.push({ text: word, quoted });
    word = "";
    quoted = false;
  };
  const endSegment = (pipe: boolean): void => {
    endWord();
    segments.push(current);
    current = newSegment(pipe);
  };

  let i = 0;
  while (i < line.length) {
    const c = line[i];

    if (c === " " || c === "\t" || c === "\r") {
      endWord();
      i += 1;
      continue;
    }
    if (c === "\n") {
      endSegment(false);
      i += 1;
      continue;
    }
    if (c === "#" && word.length === 0 && !quoted) {
      // Bash's rule exactly: `#` starts a comment only at the start of a word,
      // which is why `https://example.com/#anchor` is not one. Skipping the
      // rest of the line is a false-positive fix rather than a hole -- a
      // comment runs nothing, so nothing can hide in it, while `ls ~/Desktop
      // # 别删 rm 掉的那些` would otherwise put a card in front of a listing.
      const end = line.indexOf("\n", i);
      i = end < 0 ? line.length : end;
      continue;
    }
    if (c === "(" || c === ")") {
      // A subshell is a segment boundary. `(` is a metacharacter, so it needs
      // no space around it -- `(rm -rf ~)` is an ordinary command line, and
      // one that reads as a single unrecognisable word without this.
      //
      // A paren opening where the command itself would go inherits the pipe
      // status, so `curl … | (sh)` stays the `curl … | sh` it is.
      endSegment(segmentIsEmpty() ? current.pipedInto : false);
      i += 1;
      continue;
    }
    if (c === "\\") {
      const next = line[i + 1];
      if (next === undefined) {
        i += 1;
        continue;
      }
      if (next === "\n") {
        i += 2;
        continue;
      }
      // `\rm` is the standard way to bypass an alias, so the escape has to
      // survive into the token's text as the command name it is.
      word += next;
      i += 2;
      continue;
    }
    if (c === "'") {
      const end = line.indexOf("'", i + 1);
      if (end < 0) return null;
      // Single quotes suppress everything, substitutions included.
      word += line.slice(i + 1, end);
      quoted = true;
      i = end + 1;
      continue;
    }
    if (c === '"') {
      const read = readDoubleQuoted(line, i, current.substitutions);
      if (!read) return null;
      word += read.text;
      quoted = true;
      i = read.next;
      continue;
    }
    if (c === "`") {
      const end = line.indexOf("`", i + 1);
      if (end < 0) return null;
      current.substitutions.push(line.slice(i + 1, end));
      i = end + 1;
      continue;
    }
    if (c === "$" && line[i + 1] === "(") {
      const end = matchClosingParen(line, i + 1);
      if (end < 0) return null;
      current.substitutions.push(line.slice(i + 2, end));
      i = end + 1;
      continue;
    }
    if (c === "$") {
      // `$IFS` unquoted IS the word separator, so `rm${IFS}-rf${IFS}~/build`
      // runs rm while reading as one meaningless token. Splitting on it is the
      // whole trick, and it only applies unquoted -- `"$IFS"` does not split in
      // bash either, and `readDoubleQuoted` keeps it as text.
      const ifs = IFS_EXPANSION.exec(line.slice(i));
      if (ifs) {
        endWord();
        i += ifs[0].length;
        continue;
      }
    }
    if (c === ";") {
      endSegment(false);
      i += 1;
      continue;
    }
    if (c === "|") {
      if (line[i + 1] === "|") {
        endSegment(false);
        i += 2;
        continue;
      }
      endSegment(true);
      i += 1;
      continue;
    }
    if (c === "&") {
      if (line[i + 1] === "&") {
        endSegment(false);
        i += 2;
        continue;
      }
      if (line[i + 1] === ">") {
        // `&>` / `&>>`: both streams to one file, not a background job.
        let op = "&>";
        let j = i + 2;
        if (line[j] === ">") {
          op = "&>>";
          j += 1;
        }
        const read = readRedirectTarget(line, j, current.substitutions);
        if (!read) return null;
        endWord();
        current.redirects.push({ op, target: read.target });
        i = read.next;
        continue;
      }
      endSegment(false);
      i += 1;
      continue;
    }
    if (c === ">" || c === "<") {
      // A bare-digit word immediately before the operator is an fd prefix
      // (`2> log`), not an argument.
      let fd = "";
      if (!quoted && word.length > 0 && /^\d+$/.test(word)) {
        fd = word;
        word = "";
      }
      endWord();
      let op = c;
      let j = i + 1;
      if (c === "<") {
        if (line[j] === "<") {
          op = "<<";
          j += 1;
          if (line[j] === "<") {
            op = "<<<";
            j += 1;
          }
        }
      } else if (line[j] === ">") {
        op = ">>";
        j += 1;
      } else if (line[j] === "|") {
        // `>|` is `>` with noclobber explicitly switched off.
        op = ">|";
        j += 1;
      } else if (line[j] === "&") {
        // `>&` duplicates a descriptor; it writes to no path of its own.
        op = ">&";
        j += 1;
      }
      const read = readRedirectTarget(line, j, current.substitutions);
      if (!read) return null;
      current.redirects.push({ op: fd + op, target: read.target });
      i = read.next;
      continue;
    }

    word += c;
    i += 1;
  }

  endWord();
  segments.push(current);
  return segments;
}

// ---------------------------------------------------------------------------
// Bash: the rules
// ---------------------------------------------------------------------------

/**
 * Names with no benign reading as an argument, matched ANYWHERE in a segment.
 * Position does not matter for these, which is what catches `find … -exec rm`
 * and `… | xargs rm` without a special case for either.
 */
const DESTRUCTIVE_ANYWHERE = new Set([
  "rm",
  "rmdir",
  "shred",
  "dd",
  "truncate",
  "sudo",
  "doas",
  // A shell assembling its own bytes after we stopped looking. One rule for a
  // whole family of tricks -- decoding, concatenation, variables -- instead of
  // chasing each spelling.
  "eval",
]);

/**
 * The overwriting family, matched at a segment's HEAD only.
 *
 * Head-only because `install` and `cp` are ordinary words in an argument list:
 * `npm install` / `pip install` are among the most common things an agent
 * runs, and matching them anywhere would put a card in front of half of all
 * runs. The price is that `find . -exec cp {} /tmp \;` slips past where
 * `-exec rm` does not, which is the cheaper trade.
 *
 * They are here at all for `mv`'s reason: a pure classifier cannot know
 * whether the destination exists, so it classifies by what the command CAN do.
 * Leaving the rest out would not make the guard quieter, it would make it
 * routable -- a model told to overwrite a file and given a card for `mv` but
 * none for `cp` has been taught which verb to use.
 */
const OVERWRITING_HEADS = new Set(["mv", "cp", "install", "tee", "ln", "rsync"]);

/** Prefixes whose whole job is to run something else. Not hiding places. */
const WRAPPERS = new Set([
  "env",
  "nohup",
  "time",
  "nice",
  "sudo",
  "doas",
  "command",
  "builtin",
  "exec",
  "xargs",
  "stdbuf",
  "timeout",
  "ionice",
]);

/** Wrapper options that consume the following word. */
const WRAPPER_OPTIONS_WITH_VALUE = /^-(?:n|u|I|L|P|s|a|E|i)$/;

/**
 * `timeout`'s duration is positional, not a flag, so without this `timeout 5
 * cp a b` finds `5` where the command should be and the head rules see
 * nothing. The other wrappers spell their values as options.
 */
const TIMEOUT_DURATION = /^\d+(?:\.\d+)?[smhd]?$/;

const SHELLS = new Set([
  "sh",
  "bash",
  "zsh",
  "dash",
  "ash",
  "ksh",
  "mksh",
  "fish",
  "csh",
  "tcsh",
]);

const PYTHON_INTERPRETER = /^python[\d.]*$/;

/**
 * Interpreters that are not shells but run a program handed to them, so that
 * `curl … | python3` is the same mechanism as `curl … | sh`. Their code is not
 * classified (we have no perl/js rules) -- only the fact that bytes nobody
 * read are about to be executed.
 */
const OTHER_INTERPRETERS = new Set(["perl", "ruby", "node", "php", "osascript"]);

/**
 * A short-option cluster carrying the interpreter's inline program: `-c`, and
 * also `-lc` / `-xc` / `-cx`, which bash accepts and which read as an ordinary
 * unrelated flag to anything matching `-c` exactly.
 */
const INLINE_CODE_FLAG = /^-[A-Za-z]*c[A-Za-z]*$/;

/** Perl/ruby/node's spelling of the same thing. */
const INLINE_SCRIPT_FLAG = /^-[A-Za-z]*e[A-Za-z]*$/;

/** Redirect targets that discard output rather than writing a file. */
const DISCARDING_TARGETS = new Set([
  "/dev/null",
  "/dev/stdout",
  "/dev/stderr",
  "/dev/tty",
]);

const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/;

/** Last path component, so spelling out `/bin/rm` is not a way around this. */
function basename(token: string): string {
  const slash = token.lastIndexOf("/");
  return slash < 0 ? token : token.slice(slash + 1);
}

function isMkfs(name: string): boolean {
  return /^mkfs(\..+)?$/.test(name);
}

/** True for `-fdx`-style clusters containing `letter` (never for `--long`). */
function hasShortFlagLetter(words: readonly Word[], letter: string): boolean {
  return words.some(
    (word) => /^-[A-Za-z0-9]+$/.test(word.text) && word.text.slice(1).includes(letter)
  );
}

function hasWord(words: readonly Word[], text: string): boolean {
  return words.some((word) => word.text === text);
}

/** One word's text, or `""` past the end. Keeps the scanners index-safe. */
function textAt(words: readonly Word[], i: number): string {
  return words[i]?.text ?? "";
}

/**
 * Index of the segment's real command, with wrapper prefixes and leading
 * `VAR=value` assignments stripped.
 */
function headIndex(words: readonly Word[]): number {
  let i = 0;
  while (i < words.length) {
    const token = textAt(words, i);
    if (ASSIGNMENT.test(token)) {
      i += 1;
      continue;
    }
    const wrapper = basename(token);
    if (!WRAPPERS.has(wrapper)) break;
    i += 1;
    while (i < words.length && textAt(words, i).startsWith("-")) {
      const flag = textAt(words, i);
      i += 1;
      if (WRAPPER_OPTIONS_WITH_VALUE.test(flag) && i < words.length) i += 1;
    }
    if (wrapper === "timeout" && TIMEOUT_DURATION.test(textAt(words, i))) i += 1;
    // `env FOO=1 cmd`
    while (i < words.length && ASSIGNMENT.test(textAt(words, i))) i += 1;
  }
  return i;
}

/** The first non-flag word after `from` -- a subcommand, for `git` etc. */
function subcommandAfter(words: readonly Word[], from: number): string | undefined {
  for (let i = from + 1; i < words.length; i += 1) {
    const text = textAt(words, i);
    if (!text.startsWith("-")) return text;
  }
  return undefined;
}

/** A redirection that writes over a real path (as opposed to appending or discarding). */
function truncatesAFile(redirect: Redirect): boolean {
  const op = redirect.op.replace(/^\d+/, "");
  if (op !== ">" && op !== ">|" && op !== "&>") return false;
  // A `>` with nothing after it is a command line we cannot read.
  if (redirect.target === undefined) return true;
  if (DISCARDING_TARGETS.has(redirect.target)) return false;
  if (redirect.target.startsWith("/dev/fd/")) return false;
  return true;
}

/**
 * `-c` turns its argument into CODE, which is the one place quoting does not
 * neutralise a destructive name: the very quote-stripping that keeps
 * `echo "rm -rf /"` quiet is what would make `bash -c "rm -rf /"` invisible.
 *
 * Scanned across the whole segment rather than at the head, because
 * `find … -exec sh -c '…'` is the idiomatic way to run a shell construct per
 * match. The payload is judged, never condemned on sight -- `bash -c` is how a
 * model runs anything needing a shell construct, so a blanket rule here would
 * prompt constantly.
 */
function interpreterPayloadIsDestructive(words: readonly Word[], depth: number): boolean {
  for (let i = 0; i + 1 < words.length; i += 1) {
    if (!INLINE_CODE_FLAG.test(textAt(words, i))) continue;
    let interpreter: string | undefined;
    for (let j = i - 1; j >= 0; j -= 1) {
      const name = basename(textAt(words, j));
      if (SHELLS.has(name) || PYTHON_INTERPRETER.test(name)) {
        interpreter = name;
        break;
      }
    }
    if (!interpreter) continue;
    if (payloadIsDestructive(interpreter, textAt(words, i + 1), depth)) return true;
  }
  return false;
}

/** One interpreter plus the program text it was handed, judged in its own language. */
function payloadIsDestructive(interpreter: string, payload: string, depth: number): boolean {
  return SHELLS.has(interpreter)
    ? classifyBashCommand(payload, depth + 1) === "destructive"
    : classifyPythonSource(payload) === "destructive";
}

/**
 * True when a piped-into interpreter would take its PROGRAM from that pipe:
 * no inline `-c`/`-e` code, no script path, or an explicit `-`.
 *
 * The distinction is what keeps the rule off ordinary work: `cat data.json |
 * python3 -c '…'` pipes *data* into a program that is right there to be read
 * (and is read, by the `-c` rule above), while `curl … | python3` pipes the
 * program itself.
 */
function readsProgramFromStdin(words: readonly Word[], head: number): boolean {
  for (let i = head + 1; i < words.length; i += 1) {
    const text = textAt(words, i);
    if (text === "-") return true;
    if (!text.startsWith("-")) return false;
    if (INLINE_CODE_FLAG.test(text) || INLINE_SCRIPT_FLAG.test(text)) return false;
  }
  return true;
}

function segmentIsDestructive(segment: Segment, depth: number): boolean {
  // `$(...)` and backticks run their contents, so a classifier that treats
  // them as opaque text is trivially bypassed -- and one that condemns them on
  // sight prompts on `$(date)`. Both halves mean: judge what is inside.
  for (const substitution of segment.substitutions) {
    if (classifyBashCommand(substitution, depth + 1) === "destructive") return true;
  }

  for (const redirect of segment.redirects) {
    if (truncatesAFile(redirect)) return true;
  }

  const words = segment.words;
  if (words.length === 0) return false;

  const head = headIndex(words);
  const headName = head < words.length ? basename(textAt(words, head)) : undefined;

  // A quoted token is text -- `echo "rm -rf /"` shows the user a command, it
  // does not run one -- EXCEPT in head position, where `"rm" -rf x` still runs
  // rm. Position is the only thing separating the two.
  for (const [i, word] of words.entries()) {
    if (word.quoted && i !== head) continue;
    const name = basename(word.text);
    if (DESTRUCTIVE_ANYWHERE.has(name) || isMkfs(name)) return true;
  }

  if (interpreterPayloadIsDestructive(words, depth)) return true;

  if (headName === undefined) return false;

  // `curl … | sh`: a shell interprets bytes nobody read. The mechanism is the
  // pipe into an interpreter, not the downloader -- and deliberately not
  // `bash setup.sh`, whose contents would need a file read this function has
  // no business doing (see the module comment's gaps).
  if (segment.pipedInto && SHELLS.has(headName)) return true;
  // Same mechanism, non-shell spelling: `curl … | python3` runs the download.
  // Narrower than the shell rule above only because these interpreters are
  // also ordinary data sinks -- `cat data.json | python3 -c '…'` is routine,
  // and the flag is what tells the two apart.
  if (
    segment.pipedInto &&
    (PYTHON_INTERPRETER.test(headName) || OTHER_INTERPRETERS.has(headName)) &&
    readsProgramFromStdin(words, head)
  ) {
    return true;
  }

  // `trap 'rm -rf "$TMPDIR"' EXIT`: the first argument is code the shell runs
  // later, so it is `-c`'s rule under another name -- and unlike `-c` it is
  // something a model writes unprompted, as a cleanup handler. `trap - EXIT`
  // and `trap '' INT` classify safe on their own contents, as they should.
  if (headName === "trap") {
    if (classifyBashCommand(textAt(words, head + 1), depth + 1) === "destructive") return true;
  }

  // `sh <<< 'rm -rf ~'`: a here-string is an inline payload spelled as a
  // redirect. Unlike `sh script.sh`, its bytes are right here to be read, so
  // the reason `bash setup.sh` goes unclassified does not apply. Shells and
  // python only -- those are the two languages this file has rules for.
  if (SHELLS.has(headName) || PYTHON_INTERPRETER.test(headName)) {
    for (const redirect of segment.redirects) {
      if (redirect.op.replace(/^\d+/, "") !== "<<<") continue;
      if (redirect.target === undefined) continue;
      if (payloadIsDestructive(headName, redirect.target, depth)) return true;
    }
  }

  if (OVERWRITING_HEADS.has(headName)) {
    if (headName === "tee") {
      // `-a` appends; that is the whole difference.
      if (!hasShortFlagLetter(words, "a") && !hasWord(words, "--append")) return true;
    } else if (headName === "ln") {
      // Without `-f`, `ln` fails rather than replacing an existing path.
      if (hasShortFlagLetter(words, "f") || hasWord(words, "--force")) return true;
    } else {
      return true;
    }
  }

  // Below: names that are only destructive paired with a particular flag,
  // scoped to this segment. The scoping is what keeps `ls -R && chmod 644 x`
  // and `git clean -n` out of it.
  if (headName === "chmod" || headName === "chown") {
    // Uppercase R only: `chmod -r` removes the read bit, it does not recurse.
    if (hasShortFlagLetter(words, "R") || hasWord(words, "--recursive")) return true;
  }

  if (headName === "find") {
    // The single most likely miss in the whole feature: what a model reaches
    // for when told 「把三十天前的下载清掉」, deleting recursively while
    // containing no token from the spec's list.
    if (words.some((word) => !word.quoted && word.text === "-delete")) return true;
  }

  if (headName === "git") {
    const subcommand = subcommandAfter(words, head);
    const forced =
      hasShortFlagLetter(words, "f") ||
      words.some(
        (word) => word.text === "--force" || word.text.startsWith("--force-with-lease")
      );
    if (subcommand === "push" && forced) return true;
    if (subcommand === "reset" && hasWord(words, "--hard")) return true;
    // `git clean` deletes untracked files; `-x` adds the ignored ones, i.e.
    // exactly the local artefacts git is not holding a copy of. `-n` is the
    // "show me what you would delete" dry run and must stay quiet.
    if (subcommand === "clean" && forced) return true;
  }

  return false;
}

/** Recursion cap: a command line nested this deep is not one we can read. */
const MAX_DEPTH = 6;

function classifyBashCommand(command: string, depth: number): CommandRisk {
  if (depth > MAX_DEPTH) return "destructive";
  const segments = tokenize(command);
  if (segments === null) return "destructive";
  for (const segment of segments) {
    if (segmentIsDestructive(segment, depth)) return "destructive";
  }
  return "safe";
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

function readStringField(args: unknown, field: string): string | undefined {
  if (typeof args !== "object" || args === null) return undefined;
  const value = (args as Record<string, unknown>)[field];
  return typeof value === "string" ? value : undefined;
}

/**
 * Classify one tool call.
 *
 * @param toolName - the tool about to run, namespace prefix included.
 * @param args - that tool's arguments, exactly as the model produced them.
 */
export function classifyCommandRisk(toolName: string, args: unknown): CommandRisk {
  if (toolName === BASH_TOOL) {
    const command = readStringField(args, "command");
    if (command === undefined || command.trim() === "") return "destructive";
    try {
      return classifyBashCommand(command, 0);
    } catch {
      // A classifier that threw read nothing, which is the unreadable case.
      return "destructive";
    }
  }

  if (toolName === PYTHON_TOOL) {
    const code = readStringField(args, "code");
    if (code === undefined || code.trim() === "") return "destructive";
    return classifyPythonSource(code);
  }

  // Everything else -- the read-only core tools, the memory tools, ask_user,
  // and every MCP tool the user configured. See the module comment for why
  // abstaining here is the deliberate choice rather than the fail-safe one.
  return "safe";
}
