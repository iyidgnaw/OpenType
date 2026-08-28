---
name: draft-message
description: Use when the user asks you to write or draft a reply, email, or message -- "帮我写个回复", "起草一封邮件", "help me draft a message to my landlord", "write a reply saying I'll be late", "帮我回复一下这条消息"
---

The user wants a ready-to-send piece of writing, not an outline or a description of what the message should contain. Your job is to produce the actual message text, matched to the right tone and format, as the final deliverable.

## Procedure

1. **Gather what you actually have.** The task itself carries the core instruction (what to say, who it's to, the situation). `CONTEXT` often carries the message being replied to (selected text from an email/chat thread) -- read it if present, since a reply written without seeing what it's replying to is guessing at context that's right there.

2. **Identify the three things that shape tone and structure, in order of how much they change the output:**
   - **Audience/relationship**: a landlord, a boss, a colleague, a friend, a customer. This decides formality more than anything else the user says explicitly.
   - **Medium**: email (needs a subject line and a greeting/sign-off), chat/IM message (short, no greeting/sign-off needed, can be more casual), a formal letter (fullest formality). Infer this from context (an email thread selected vs. a casual chat request) when not stated.
   - **Purpose**: informing, apologizing, requesting, declining, confirming. Get this right first -- a reply that's beautifully written but answers the wrong purpose (e.g. sounds like a confirmation when the user wanted to decline) is a worse failure than clumsy phrasing.

3. **Match the language to the request, and match formality conventions to that language.** If the user spoke/wrote in Chinese, draft in Chinese (with the appropriate register -- 您 vs 你, formal closings for business contexts); English requests get English drafts with the analogous formality conventions (a business email still opens with a greeting and closes with a sign-off placeholder like "Best," or "Best regards,"). Don't default to English just because these instructions are in English.

4. **Write the complete message, not a summary of it.** Include a subject line when the medium is email and one wasn't given (infer a short, accurate one from the content). Use a placeholder like `[Your name]` / `[你的名字]` for a sign-off if the user's name isn't known from context -- don't invent a name.

5. **Keep it as long as the purpose actually needs, not as long as sounds thorough.** A "我今天要晚到" message is two sentences; a decline that needs to preserve a relationship might genuinely need a short paragraph of context. Padding a short, simple message with unnecessary formality reads worse than the short version.

6. **If the user gave conflicting or missing critical information** (e.g. "写封邮件" with no recipient, topic, or context available anywhere), ask a single clarifying question via `opentype__ask_user` rather than drafting a generic placeholder message that will just need to be rewritten anyway. Don't ask if you can reasonably infer the missing piece from context (a selected email thread already tells you who the recipient is).

7. **Deliver the drafted message as the final answer, ready to copy.** This is draft-only by design (matches how Agent/Ask results are always delivered -- clipboard, never auto-sent) -- do not attempt to actually send anything even if a tool theoretically could. Present the message clearly separated from any of your own commentary (e.g. in a quoted block) so it's obvious exactly what text is the deliverable versus what's your explanation.

## Notes

- If replying to a message that was rude, upset, or emotionally charged, keep your draft professional and de-escalating unless the user explicitly asked for a sharper tone -- don't mirror hostility into the draft by default.
