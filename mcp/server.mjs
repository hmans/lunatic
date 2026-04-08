#!/usr/bin/env node

// Lunatic Engine MCP Server
// Bridges Claude Code to the engine's HTTP debug server (localhost:19840).

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const ENGINE_URL = process.env.LUNATIC_ENGINE_URL || "http://127.0.0.1:19840";

async function engineFetch(path, options = {}) {
  const url = `${ENGINE_URL}${path}`;
  try {
    const resp = await fetch(url, { ...options, signal: AbortSignal.timeout(10000) });
    return resp;
  } catch (err) {
    throw new Error(`Engine not reachable at ${url}: ${err.message}`);
  }
}

const server = new McpServer({
  name: "lunatic-engine",
  version: "0.2.0",
});

// --- Tool: screenshot ---
server.tool(
  "screenshot",
  "Capture a screenshot of the current engine frame. Returns the rendered frame as a PNG image. " +
    "The screenshot includes the full rendered scene with post-processing and ImGui overlay.",
  {},
  async () => {
    const resp = await engineFetch("/screenshot", { method: "POST" });
    const contentType = resp.headers.get("content-type") || "";

    if (contentType.includes("image/png")) {
      const buf = Buffer.from(await resp.arrayBuffer());
      return {
        content: [
          {
            type: "image",
            data: buf.toString("base64"),
            mimeType: "image/png",
          },
        ],
      };
    }

    // Fallback: JSON error response
    const json = await resp.json();
    return { content: [{ type: "text", text: JSON.stringify(json, null, 2) }] };
  }
);

// --- Tool: get_stats ---
server.tool(
  "get_stats",
  "Get engine performance statistics: FPS, entity count, draw calls, physics stats, " +
    "and per-phase GPU timing (prepare, instances, scene, postprocess, imgui).",
  {},
  async () => {
    const resp = await engineFetch("/stats");
    const json = await resp.json();
    return { content: [{ type: "text", text: JSON.stringify(json, null, 2) }] };
  }
);

// --- Start ---
const transport = new StdioServerTransport();
await server.connect(transport);
