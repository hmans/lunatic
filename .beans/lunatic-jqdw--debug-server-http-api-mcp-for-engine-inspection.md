---
# lunatic-jqdw
title: 'Debug server: HTTP API + MCP for engine inspection'
status: completed
type: feature
priority: normal
created_at: 2026-04-06T10:17:47Z
updated_at: 2026-04-06T10:39:58Z
---

Add a background HTTP server to the engine (localhost:19840) with endpoints for Lua eval, screenshots, and stats. Build a TypeScript MCP server wrapper so Claude Code can inspect/control the running engine.

## Summary of Changes

### Engine side (`engine/src/debug_server.zig`)
- Background HTTP server on `localhost:19840` using `std.http.Server` + `std.Thread`
- Thread-safe request queue (mutex-protected, drained once per frame)
- Three endpoints: `GET /stats`, `POST /lua`, `POST /screenshot`
- Lua eval with full JSON serialization of return values (tables, arrays, primitives)
- Screenshot returns PNG bytes directly over HTTP (deferred response pattern)
- Stats returns JSON with FPS, entity count, draw calls, physics, per-phase GPU timing

### Integration (`engine/src/engine.zig`, `build.zig`)
- Server starts at beginning of `run()`, stops on exit and in `deinit()`
- Request queue drained after `runAllSystems()`, before rendering
- Screenshot completion signaled after `downloadScreenshot()` writes the file

### MCP server (`mcp/server.mjs`)
- TypeScript MCP server wrapping HTTP calls to the engine
- Tools: `eval_lua`, `screenshot`, `get_stats`
- Auto-discovered via `.mcp.json` in project root
