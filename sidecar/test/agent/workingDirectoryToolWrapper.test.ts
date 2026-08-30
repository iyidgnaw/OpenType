import { afterAll, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { ConversationStore } from "../../src/memory/conversations";
import type { AgentChatFn } from "../../src/agent/loop";
import type { McpToolSet } from "../../src/agent/mcpClient";
import { buildAgentRoutes } from "../../src/agent/routes";
import { createRouter } from "../../src/router";

const tempDirs: string[] = [];

afterAll(() => {
  for (const dir of tempDirs) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

function makeConversations(): ConversationStore {
  return new ConversationStore(openDatabase(":memory:"));
}

function makeTempHome(): string {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "opentype-run-cwd-")));
  tempDirs.push(dir);
  return dir;
}

function captureContextLog(): { writer: (line: string) => void; lines: string[] } {
  const lines: string[] = [];
  return { writer: (line) => lines.push(line), lines };
}

function post(body: unknown): Request {
  return new Request("http://sidecar/agent/run", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

interface PlannedToolCall {
  name: string;
  args: unknown;
}

function deferred<T>(): {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (reason?: unknown) => void;
} {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function scriptedChat(runs: PlannedToolCall[][]): AgentChatFn {
  const pendingRuns = [...runs];
  let toolPhase = false;
  return async () => {
    if (!toolPhase) {
      const planned = pendingRuns.shift();
      if (!planned) {
        throw new Error("no scripted run left for chat");
      }
      toolPhase = true;
      return {
        content: null,
        toolCalls: planned.map((call, index) => ({
          id: `call_${index + 1}`,
          type: "function" as const,
          function: {
            name: call.name,
            arguments: JSON.stringify(call.args),
          },
        })),
      };
    }
    toolPhase = false;
    return { content: "done" };
  };
}

function descriptor(name: string): { type: "function"; function: { name: string } } {
  return { type: "function", function: { name } };
}

function makeRecordingTools(toolNames: string[]): {
  tools: McpToolSet;
  calls: Array<{ name: string; args: unknown }>;
} {
  const calls: Array<{ name: string; args: unknown }> = [];
  return {
    tools: {
      openAiTools: toolNames.map(descriptor),
      callTool: async (name, args) => {
        calls.push({ name, args });
        return { content: `called ${name}` };
      },
    },
    calls,
  };
}

describe("POST /agent/run workingDirectory tool defaults", () => {
  test("glob without path, open_file with a relative path, and bash without cwd all resolve against this run's workingDirectory", async () => {
    const homeDir = makeTempHome();
    const workingDirectory = path.join(homeDir, "repo", "pkg");
    fs.mkdirSync(path.join(workingDirectory, "notes"), { recursive: true });

    const { tools, calls } = makeRecordingTools([
      "opentype__glob",
      "opentype__open_file",
      "opentype__bash",
    ]);
    const router = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        scriptedChat([
          [
            { name: "opentype__glob", args: { pattern: "*.md" } },
            { name: "opentype__open_file", args: { path: "notes/today.md" } },
            { name: "opentype__bash", args: { command: "pwd" } },
          ],
        ]),
        tools,
        captureContextLog().writer,
        undefined,
        undefined,
        { homeDir }
      )
    );

    const response = await router(post({ task: "inspect this package", workingDirectory }));

    expect(response.status).toBe(200);
    expect(calls).toEqual([
      {
        name: "opentype__glob",
        args: { pattern: "*.md", path: workingDirectory },
      },
      {
        name: "opentype__open_file",
        args: { path: path.join(workingDirectory, "notes", "today.md") },
      },
      {
        name: "opentype__bash",
        args: { command: "pwd", cwd: workingDirectory },
      },
    ]);
  });

  test("grep without path, list_dir without path, and python without cwd all default to this run's workingDirectory", async () => {
    const homeDir = makeTempHome();
    const workingDirectory = path.join(homeDir, "repo", "pkg");
    fs.mkdirSync(workingDirectory, { recursive: true });

    const { tools, calls } = makeRecordingTools([
      "opentype__grep",
      "opentype__list_dir",
      "opentype__python",
    ]);
    const router = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        scriptedChat([
          [
            { name: "opentype__grep", args: { pattern: "needle" } },
            { name: "opentype__list_dir", args: {} },
            { name: "opentype__python", args: { code: "print('hi')" } },
          ],
        ]),
        tools,
        captureContextLog().writer,
        undefined,
        undefined,
        { homeDir }
      )
    );

    const response = await router(post({ task: "inspect this package", workingDirectory }));

    expect(response.status).toBe(200);
    expect(calls).toEqual([
      {
        name: "opentype__grep",
        args: { pattern: "needle", path: workingDirectory },
      },
      {
        name: "opentype__list_dir",
        args: { path: workingDirectory },
      },
      {
        name: "opentype__python",
        args: { code: "print('hi')", cwd: workingDirectory },
      },
    ]);
  });

  test("explicit absolute paths and ~-prefixed args stay unchanged instead of being rebound to workingDirectory", async () => {
    const homeDir = makeTempHome();
    const workingDirectory = path.join(homeDir, "repo");
    const explicitSearchRoot = path.join(homeDir, "elsewhere");
    const explicitFilePath = path.join(homeDir, "report.pdf");
    const explicitCwd = path.join(homeDir, "scripts");
    fs.mkdirSync(workingDirectory, { recursive: true });

    const { tools, calls } = makeRecordingTools([
      "opentype__glob",
      "opentype__open_file",
      "opentype__bash",
    ]);
    const router = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        scriptedChat([
          [
            {
              name: "opentype__glob",
              args: { pattern: "*.md", path: explicitSearchRoot },
            },
            {
              name: "opentype__open_file",
              args: { path: explicitFilePath },
            },
            {
              name: "opentype__open_file",
              args: { path: "~/Desktop/today.md" },
            },
            {
              name: "opentype__bash",
              args: { command: "pwd", cwd: explicitCwd },
            },
            {
              name: "opentype__bash",
              args: { command: "pwd", cwd: "~/repo" },
            },
          ],
        ]),
        tools,
        captureContextLog().writer,
        undefined,
        undefined,
        { homeDir }
      )
    );

    await router(post({ task: "inspect paths", workingDirectory }));

    expect(calls).toEqual([
      {
        name: "opentype__glob",
        args: { pattern: "*.md", path: explicitSearchRoot },
      },
      {
        name: "opentype__open_file",
        args: { path: explicitFilePath },
      },
      {
        name: "opentype__open_file",
        args: { path: "~/Desktop/today.md" },
      },
      {
        name: "opentype__bash",
        args: { command: "pwd", cwd: explicitCwd },
      },
      {
        name: "opentype__bash",
        args: { command: "pwd", cwd: "~/repo" },
      },
    ]);
  });

  test("different runs keep separate workingDirectory defaults and non-OpenType tools pass through unchanged", async () => {
    const homeDir = makeTempHome();
    const runOneDirectory = path.join(homeDir, "repo-one");
    const runTwoDirectory = path.join(homeDir, "repo-two");
    fs.mkdirSync(runOneDirectory, { recursive: true });
    fs.mkdirSync(runTwoDirectory, { recursive: true });

    const { tools, calls } = makeRecordingTools(["opentype__bash", "server__tool"]);
    const router = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        scriptedChat([
          [{ name: "opentype__bash", args: { command: "pwd" } }],
          [{ name: "opentype__bash", args: { command: "pwd" } }],
          [
            {
              name: "server__tool",
              args: {
                path: "notes/today.md",
                cwd: "./relative-dir",
                metadata: { untouched: true },
              },
            },
          ],
        ]),
        tools,
        captureContextLog().writer,
        undefined,
        undefined,
        { homeDir }
      )
    );

    await router(post({ task: "run one", workingDirectory: runOneDirectory }));
    await router(post({ task: "run two", workingDirectory: runTwoDirectory }));
    await router(post({ task: "mcp passthrough", workingDirectory: runOneDirectory }));

    expect(calls).toEqual([
      {
        name: "opentype__bash",
        args: { command: "pwd", cwd: runOneDirectory },
      },
      {
        name: "opentype__bash",
        args: { command: "pwd", cwd: runTwoDirectory },
      },
      {
        name: "server__tool",
        args: {
          path: "notes/today.md",
          cwd: "./relative-dir",
          metadata: { untouched: true },
        },
      },
    ]);
  });

  test("two overlapping runs sharing one ToolSet still rewrite bash cwd per run without leaking across runs", async () => {
    const homeDir = makeTempHome();
    const runOneDirectory = path.join(homeDir, "repo-one");
    const runTwoDirectory = path.join(homeDir, "repo-two");
    fs.mkdirSync(runOneDirectory, { recursive: true });
    fs.mkdirSync(runTwoDirectory, { recursive: true });

    const firstCallStarted = deferred<void>();
    const releaseCalls = deferred<void>();
    const calls: Array<{ name: string; args: unknown }> = [];
    let callCount = 0;
    const tools: McpToolSet = {
      openAiTools: [descriptor("opentype__bash")],
      callTool: async (name, args) => {
        calls.push({ name, args });
        callCount += 1;
        if (callCount === 1) {
          firstCallStarted.resolve();
        }
        if (callCount < 2) {
          await releaseCalls.promise;
        }
        return { content: `called ${name}` };
      },
    };
    const chat: AgentChatFn = async (messages) => {
      const toolResultSeen = messages.some((message) => message.role === "tool");
      if (!toolResultSeen) {
        return {
          content: null,
          toolCalls: [
            {
              id: "call_1",
              type: "function",
              function: {
                name: "opentype__bash",
                arguments: JSON.stringify({ command: "pwd" }),
              },
            },
          ],
        };
      }
      return { content: "done" };
    };
    const router = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        chat,
        tools,
        captureContextLog().writer,
        undefined,
        undefined,
        { homeDir }
      )
    );

    const firstRun = router(post({ task: "run one", workingDirectory: runOneDirectory }));
    await firstCallStarted.promise;
    const secondRun = router(post({ task: "run two", workingDirectory: runTwoDirectory }));
    while (callCount < 2) {
      await Promise.resolve();
    }
    releaseCalls.resolve();

    const [firstResponse, secondResponse] = await Promise.all([firstRun, secondRun]);

    expect(firstResponse.status).toBe(200);
    expect(secondResponse.status).toBe(200);
    expect(calls).toEqual([
      {
        name: "opentype__bash",
        args: { command: "pwd", cwd: runOneDirectory },
      },
      {
        name: "opentype__bash",
        args: { command: "pwd", cwd: runTwoDirectory },
      },
    ]);
  });

  test("a relative first-party path into a child project under this run's workingDirectory reaches projectContext only after the tool call", async () => {
    const homeDir = makeTempHome();
    const workingDirectory = path.join(homeDir, "workspace");
    const childProjectRoot = path.join(workingDirectory, "child-project");
    const childProjectFile = path.join(childProjectRoot, "src", "file.md");
    fs.mkdirSync(path.dirname(childProjectFile), { recursive: true });
    fs.writeFileSync(childProjectFile, "# note\n");
    fs.writeFileSync(path.join(childProjectRoot, "AGENTS.md"), "FOLLOW CHILD PROJECT RULE");

    const capturedMessages: Array<Array<{ role: string; content?: string | null }>> = [];
    const chat: AgentChatFn = async (messages) => {
      capturedMessages.push(
        messages.map((message) => ({
          role: message.role,
          content: "content" in message ? (message.content as string | null | undefined) : undefined,
        }))
      );
      const sawToolResult = messages.some((message) => message.role === "tool");
      if (!sawToolResult) {
        return {
          content: null,
          toolCalls: [
            {
              id: "call_1",
              type: "function",
              function: {
                name: "opentype__open_file",
                arguments: JSON.stringify({ path: "child-project/src/file.md" }),
              },
            },
          ],
        };
      }
      return { content: "done" };
    };
    const { tools } = makeRecordingTools(["opentype__open_file"]);
    const router = createRouter(
      buildAgentRoutes(
        makeStore(),
        makeConversations(),
        chat,
        tools,
        captureContextLog().writer,
        undefined,
        undefined,
        { homeDir }
      )
    );

    const response = await router(post({ task: "open the note", workingDirectory }));

    expect(response.status).toBe(200);
    const firstMessages = capturedMessages[0] ?? [];
    expect(
      firstMessages.some((message) =>
        String(message.content ?? "").includes("FOLLOW CHILD PROJECT RULE")
      )
    ).toBe(false);
    const finalMessages = capturedMessages.at(-1) ?? [];
    const projectMessages = finalMessages.filter(
      (message) =>
        message.role === "user" &&
        String(message.content ?? "").includes("FOLLOW CHILD PROJECT RULE")
    );
    expect(projectMessages).toHaveLength(1);
    expect(projectMessages[0]?.content).toContain(path.join(childProjectRoot, "AGENTS.md"));
    const toolMessageIndex = finalMessages.findIndex((message) => message.role === "tool");
    const projectMessageIndex = finalMessages.findIndex(
      (message) =>
        message.role === "user" &&
        String(message.content ?? "").includes("FOLLOW CHILD PROJECT RULE")
    );
    expect(toolMessageIndex).toBeGreaterThanOrEqual(0);
    expect(projectMessageIndex).toBeGreaterThan(toolMessageIndex);
  });
});
