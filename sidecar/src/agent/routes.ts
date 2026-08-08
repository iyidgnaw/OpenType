import type { MemoryStore } from "../memory/MemoryStore";
import type { Route } from "../router";
import type { AgentChatFn } from "./loop";
import { runAgentLoop } from "./loop";
import type { McpToolSet } from "./mcpClient";

interface AgentRunRequestBody {
  task?: string;
  context?: string;
}

async function readJsonBody<T>(req: Request): Promise<T> {
  return (await req.json()) as T;
}

async function handleAgentRun(
  req: Request,
  store: MemoryStore,
  chat: AgentChatFn,
  tools: McpToolSet
): Promise<Response> {
  const body = await readJsonBody<AgentRunRequestBody>(req);
  const task = body.task ?? "";
  const context = body.context;

  const loopResult = await runAgentLoop({ task, context }, { chat, tools });

  // Per design spec §4: the first real write with origin "agent" (distinct
  // from the owner's own dictation), so agent-produced content can be told
  // apart from the owner's words once it flows through consolidation.
  store.recordEpisodicEvent({
    mode: "agent",
    rawTranscript: task,
    correctedTranscript: task,
    effectiveInput: task,
    selectedContext: context ?? null,
    result: loopResult.result,
    applicationName: "OpenType Agent",
    origin: "agent",
  });

  return Response.json({ result: loopResult.result, steps: loopResult.steps });
}

/**
 * A single blocking call for tonight: `/agent/run` runs the whole loop and
 * returns the full progress log at once. There's no real-time progress
 * streaming to a UI yet (a Task List panel is a separate future task).
 */
export function buildAgentRoutes(
  store: MemoryStore,
  chat: AgentChatFn,
  tools: McpToolSet
): Route[] {
  return [
    {
      method: "POST",
      path: "/agent/run",
      handler: (req) => handleAgentRun(req, store, chat, tools),
    },
  ];
}
