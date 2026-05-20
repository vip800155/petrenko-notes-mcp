/**
 * examples/mastra_client.ts
 *
 * Standalone Mastra agent that connects to the petrenko-notes MCP server
 * over Streamable HTTP and exposes its tools to an Anthropic model.
 *
 * This is the same shape as the production "vix" agent that runs on a VM
 * and serves a Telegram bot. Telegram-specific glue is omitted here so the
 * example stays focused on MCP integration.
 *
 * Usage:
 *   PETRENKO_NOTES_MCP_URL=https://your-n8n-host/mcp/<uuid> \
 *   ANTHROPIC_API_KEY=sk-ant-... \
 *   tsx examples/mastra_client.ts
 */

import "dotenv/config";
import { Agent } from "@mastra/core/agent";
import { MCPClient } from "@mastra/mcp";
import { anthropic } from "@ai-sdk/anthropic";

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

const MCP_URL = process.env.PETRENKO_NOTES_MCP_URL;
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY;

if (!MCP_URL) {
  throw new Error("PETRENKO_NOTES_MCP_URL is required");
}
if (!ANTHROPIC_API_KEY) {
  throw new Error("ANTHROPIC_API_KEY is required");
}

// ---------------------------------------------------------------------------
// MCP client
// ---------------------------------------------------------------------------

const mcp = new MCPClient({
  servers: {
    petrenkoNotes: {
      url: new URL(MCP_URL),
    },
  },
});

// MCP tools are fetched once at startup. The MCPClient handles connection,
// schema discovery, and re-connect on transient errors.
const tools = await mcp.getTools();

// ---------------------------------------------------------------------------
// Agent definition
// ---------------------------------------------------------------------------

const instructions = `
You are Vix, a personal assistant agent for Viktor.

You have access to the petrenko_notes MCP server. Use it to:
- recall past decisions, insights, and tasks by calling get_notes with relevant search terms
- log new decisions and insights via add_note whenever a new conclusion is reached
- update task status via update_status when work is started or finished
- summarise activity by project via get_topics

Always search before answering questions about Viktor's history or context.
Always log decisions and important insights to the notes layer, even when not asked.

Project naming convention: \`{namespace}_{topic}\`. Examples:
- personal_career, personal_ai_os, personal_health
- numen, vix
`.trim();

const agent = new Agent({
  name: "vix",
  instructions,
  model: anthropic("claude-opus-4-7"),
  tools,
});

// ---------------------------------------------------------------------------
// Simple invocation
// ---------------------------------------------------------------------------

async function main() {
  const prompt = process.argv.slice(2).join(" ") ||
    "What did I decide about the voice agent POC last week? Summarise in two sentences.";

  console.log(`[vix] prompt: ${prompt}`);

  const result = await agent.generate(prompt, {
    maxSteps: 8,
  });

  console.log(`[vix] response: ${result.text}`);

  // Optional: inspect tool calls the agent made.
  for (const step of result.steps ?? []) {
    for (const call of step.toolCalls ?? []) {
      console.log(`[vix] tool call: ${call.toolName}(${JSON.stringify(call.args)})`);
    }
  }
}

main()
  .catch((err) => {
    console.error("[vix] fatal:", err);
    process.exit(1);
  })
  .finally(async () => {
    // Disconnect so the process can exit cleanly.
    await mcp.disconnect();
  });
