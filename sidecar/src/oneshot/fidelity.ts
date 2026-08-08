/**
 * Ported from `Sources/OpenType/EnglishOutputPolicy.swift`'s `EnglishOutputPolicy`
 * and `SpeechActGuard` enums: the fidelity validation for the `/oneshot/translate`
 * endpoint. This is a port of the *logic*, not the Swift API shape — heuristics
 * are reproduced as closely as practical in TypeScript.
 *
 * `needsTranslationCorrection` rejects a translation candidate when:
 *  - it still contains Han (Chinese/CJK ideograph) characters,
 *  - it expanded far beyond a reasonable bound for a bounded rewrite
 *    (a reliable signal the model answered/invented rather than translated),
 *  - the source was clearly a question but the candidate is no longer one, or
 *  - the source was clearly a request/command but the candidate no longer
 *    preserves that request/command shape (a fluent model turning
 *    "帮我写一封邮件" into the email itself, rather than "write me an email").
 */

const HAN_RANGES: ReadonlyArray<readonly [number, number]> = [
  [0x3400, 0x4dbf],
  [0x4e00, 0x9fff],
  [0xf900, 0xfaff],
  [0x20000, 0x2fa1f],
];

export function containsUnexpectedHanCharacters(text: string): boolean {
  for (const char of text) {
    const codePoint = char.codePointAt(0);
    if (codePoint === undefined) continue;
    if (HAN_RANGES.some(([lo, hi]) => codePoint >= lo && codePoint <= hi)) {
      return true;
    }
  }
  return false;
}

const DIRECT_QUESTION_PREFIXES = [
  "为什么", "为啥", "怎么", "如何", "是不是", "是否", "能不能",
  "可不可以", "什么", "谁", "哪里", "哪儿", "什么时候", "多少", "几点",
  "why ", "how ", "what ", "when ", "where ", "who ", "which ",
  "can ", "could ", "would ", "should ", "is ", "are ", "do ",
  "does ", "did ",
];

function trimChars(text: string, chars: string): string {
  const set = new Set(chars);
  let start = 0;
  let end = text.length;
  while (start < end && set.has(text[start])) start++;
  while (end > start && set.has(text[end - 1])) end--;
  return text.slice(start, end);
}

export function sourceIsClearlyAQuestion(text: string): boolean {
  const trimmed = text.trim();
  if (trimmed.includes("?") || trimmed.includes("？")) return true;

  const normalized = trimChars(trimmed, "。.!！").toLowerCase();
  if (normalized.endsWith("吗") || normalized.endsWith("嘛")) return true;

  return DIRECT_QUESTION_PREFIXES.some((prefix) => normalized.startsWith(prefix));
}

const TRAILING_DECORATION = " \t\n\r\"'”’）)]}》】";

export function candidateIsAQuestion(text: string): boolean {
  const normalized = trimChars(text, TRAILING_DECORATION);
  return normalized.endsWith("?") || normalized.endsWith("？");
}

interface ActionFamily {
  sourceSignals: string[];
  candidateSignals: string[];
}

const ACTION_FAMILIES: ActionFamily[] = [
  { sourceSignals: ["总结", "概括", "归纳", "summarize", "sum up"], candidateSignals: ["总结", "概括", "归纳", "summarize", "sum up"] },
  { sourceSignals: ["翻译", "翻成", "译成", "translate", "render into"], candidateSignals: ["翻译", "翻成", "译成", "translate", "render"] },
  { sourceSignals: ["写", "生成", "起草", "创作", "撰写", "write", "draft", "generate", "compose"], candidateSignals: ["写", "生成", "起草", "创作", "撰写", "write", "draft", "generate", "compose", "create"] },
  { sourceSignals: ["发送", "发一", "发布", "寄给", "send", "post", "publish", "tweet", "email"], candidateSignals: ["发送", "发一", "发布", "寄给", "send", "post", "publish", "tweet", "email"] },
  { sourceSignals: ["告诉", "提醒", "通知", "tell", "remind", "notify"], candidateSignals: ["告诉", "提醒", "通知", "tell", "remind", "notify"] },
  { sourceSignals: ["列出", "列一下", "列个", "列一份", "list"], candidateSignals: ["列出", "列一下", "list"] },
  { sourceSignals: ["搜索", "查一下", "查找", "找一下", "检索", "search", "look up", "find"], candidateSignals: ["搜索", "查一下", "查找", "找一下", "检索", "search", "look up", "find"] },
  { sourceSignals: ["保存", "存到", "save"], candidateSignals: ["保存", "存到", "save"] },
  { sourceSignals: ["打开", "启动", "open", "launch"], candidateSignals: ["打开", "启动", "open", "launch"] },
  { sourceSignals: ["删除", "删掉", "去掉", "remove", "delete"], candidateSignals: ["删除", "删掉", "去掉", "remove", "delete"] },
  { sourceSignals: ["修改", "改写", "润色", "优化", "edit", "revise", "rewrite", "polish"], candidateSignals: ["修改", "改写", "润色", "优化", "edit", "revise", "rewrite", "polish"] },
  { sourceSignals: ["解释", "说明一下", "explain"], candidateSignals: ["解释", "说明一下", "explain"] },
];

const CHINESE_REQUEST_SIGNALS = [
  "帮我", "请你", "请帮", "麻烦你", "麻烦帮", "替我", "给我",
  "我要你", "我希望你", "你帮我", "你帮忙", "你来", "你把",
  "你可以", "你能", "能不能", "可不可以",
];

const ENGLISH_REQUEST_SIGNALS = [
  "please ", "could you", "can you", "would you", "will you",
  "help me", "i need you to", "i want you to", "i'd like you to",
  "let's ",
];

const DIRECT_CHINESE_COMMAND_PREFIXES = [
  "总结一下", "概括一下", "翻译一下", "翻成", "写一", "写个", "写份",
  "写封", "写条", "生成一", "起草一", "列出", "列一下", "发一",
  "发送", "发布", "告诉", "提醒", "通知", "搜索", "查一下", "找一下",
  "保存", "打开", "删除", "删掉", "去掉", "修改", "改写", "润色",
  "优化", "解释一下", "说明一下",
];

const DIRECT_ENGLISH_COMMAND_PREFIXES = [
  "summarize ", "translate ", "write ", "draft ", "generate ",
  "create ", "make ", "build ", "design ", "list ", "send ",
  "post ", "publish ", "tweet ", "email ", "tell ", "remind ",
  "notify ", "search ", "look up ", "find ", "save ", "open ",
  "delete ", "remove ", "edit ", "revise ", "rewrite ", "polish ",
  "explain ",
];

const SPOKEN_LEAD_IN_PREFIXES = [
  "嗯", "呃", "额", "然后", "那", "那么", "好", "ok", "okay",
  "请", "please",
];

function normalize(text: string): string {
  return text.trim().toLowerCase();
}

function stripSpokenLeadIn(text: string): string {
  let result = text.trim();
  let stripped = true;
  while (stripped) {
    stripped = false;
    for (const prefix of SPOKEN_LEAD_IN_PREFIXES) {
      if (result.startsWith(prefix)) {
        result = result.slice(prefix.length).trim();
        stripped = true;
        break;
      }
    }
  }
  return result;
}

export function sourceRequestsAction(text: string): boolean {
  const normalized = normalize(text);
  if (!normalized) return false;

  if (
    CHINESE_REQUEST_SIGNALS.some((s) => normalized.includes(s)) ||
    ENGLISH_REQUEST_SIGNALS.some((s) => normalized.includes(s))
  ) {
    return true;
  }

  const stripped = stripSpokenLeadIn(normalized);
  if (
    (stripped.startsWith("把") || stripped.startsWith("将")) &&
    ACTION_FAMILIES.some((family) => family.sourceSignals.some((s) => stripped.includes(s)))
  ) {
    return true;
  }

  return (
    DIRECT_CHINESE_COMMAND_PREFIXES.some((p) => stripped.startsWith(p)) ||
    DIRECT_ENGLISH_COMMAND_PREFIXES.some((p) => stripped.startsWith(p))
  );
}

function candidateLooksLikeRequestOrCommand(candidate: string): boolean {
  if (sourceRequestsAction(candidate)) return true;
  const stripped = stripSpokenLeadIn(candidate);
  return (
    DIRECT_CHINESE_COMMAND_PREFIXES.some((p) => stripped.startsWith(p)) ||
    DIRECT_ENGLISH_COMMAND_PREFIXES.some((p) => stripped.startsWith(p))
  );
}

export function candidatePreservesRequestedAction(source: string, candidate: string): boolean {
  const normalizedSource = normalize(source);
  const normalizedCandidate = normalize(candidate);
  if (!candidateLooksLikeRequestOrCommand(normalizedCandidate)) {
    return false;
  }

  const requiredFamilies = ACTION_FAMILIES.filter((family) =>
    family.sourceSignals.some((s) => normalizedSource.includes(s))
  );
  return requiredFamilies.every((family) =>
    family.candidateSignals.some((s) => normalizedCandidate.includes(s))
  );
}

/**
 * Port of `EnglishOutputPolicy.needsCorrection` (mode is implicitly always
 * "english" here since this endpoint has no other modes).
 */
export function needsTranslationCorrection(source: string, output: string): boolean {
  if (containsUnexpectedHanCharacters(output)) return true;

  const trimmedSource = source.trim();
  const trimmedOutput = output.trim();
  if (!trimmedSource) return false;

  const maximumReasonableLength = Math.max(96, trimmedSource.length * 6);
  if (trimmedOutput.length > maximumReasonableLength) return true;

  if (sourceIsClearlyAQuestion(trimmedSource) && !candidateIsAQuestion(trimmedOutput)) {
    return true;
  }

  if (
    sourceRequestsAction(trimmedSource) &&
    !candidatePreservesRequestedAction(trimmedSource, trimmedOutput)
  ) {
    return true;
  }

  return false;
}
