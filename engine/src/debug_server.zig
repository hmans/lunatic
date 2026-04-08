// debug_server.zig — Embedded HTTP debug server for engine inspection.
//
// Runs on a background thread, accepts HTTP requests on localhost:19840.
// Requests that need main-thread access (screenshots) are queued
// and processed once per frame. The HTTP handler blocks until the main thread
// signals completion.

const std = @import("std");
const http = std.http;
const net = std.net;
const Engine = @import("engine").Engine;

const port: u16 = 19840;
const max_pending_requests = 4;

// ============================================================
// Request/response protocol between HTTP thread and main thread
// ============================================================

pub const RequestKind = enum {
    screenshot,
    stats,
};

pub const Request = struct {
    kind: RequestKind,
    /// Response data written by the main thread
    response: Response = .{},
    /// Signaled by the main thread when the response is ready
    done: std.Thread.ResetEvent = .{},
};

pub const Response = struct {
    status: http.Status = .ok,
    content_type: []const u8 = "application/json",
    /// Response body. Allocated with c_allocator; caller must free.
    body: ?[]const u8 = null,
    /// For screenshot: raw PNG bytes
    png_data: ?[]u8 = null,
    png_len: usize = 0,
};

// ============================================================
// Thread-safe request queue (fixed-size, mutex-protected)
// ============================================================

pub const RequestQueue = struct {
    mutex: std.Thread.Mutex = .{},
    items: [max_pending_requests]?*Request = .{null} ** max_pending_requests,

    /// Enqueue a request. Returns false if the queue is full.
    pub fn push(self: *RequestQueue, req: *Request) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.items) |*slot| {
            if (slot.* == null) {
                slot.* = req;
                return true;
            }
        }
        return false;
    }

    /// Drain all pending requests into the provided buffer. Returns count.
    pub fn drain(self: *RequestQueue, out: *[max_pending_requests]*Request) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: u32 = 0;
        for (&self.items) |*slot| {
            if (slot.*) |req| {
                out[count] = req;
                count += 1;
                slot.* = null;
            }
        }
        return count;
    }
};

// ============================================================
// Server state
// ============================================================

pub const DebugServer = struct {
    queue: RequestQueue = .{},
    thread: ?std.Thread = null,
    engine: *Engine = undefined,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    tcp_server: ?net.Server = null,
    /// Screenshot request that is deferred until after the frame renders.
    /// Set during drainRequests, signaled after downloadScreenshot completes.
    pending_screenshot: ?*Request = null,

    pub fn start(self: *DebugServer, engine: *Engine) !void {
        self.engine = engine;
        self.shutdown.store(false, .release);

        const address = try net.Address.parseIp("127.0.0.1", port);
        self.tcp_server = try address.listen(.{
            .reuse_address = true,
        });

        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        std.debug.print("[debug-server] listening on http://127.0.0.1:{d}\n", .{port});
    }

    pub fn stop(self: *DebugServer) void {
        self.shutdown.store(true, .release);
        // Close the listening socket to unblock accept()
        if (self.tcp_server) |*srv| {
            srv.deinit();
            self.tcp_server = null;
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        std.debug.print("[debug-server] stopped\n", .{});
    }

    /// Called from the main thread once per frame to process pending requests.
    pub fn drainRequests(self: *DebugServer) void {
        var reqs: [max_pending_requests]*Request = undefined;
        const count = self.queue.drain(&reqs);
        for (reqs[0..count]) |req| {
            self.processOnMainThread(req);
            // Screenshot requests are deferred — don't signal done yet.
            // completeScreenshot() will be called after the frame renders.
            if (req.kind != .screenshot) {
                req.done.set();
            }
        }
    }

    fn processOnMainThread(self: *DebugServer, req: *Request) void {
        switch (req.kind) {
            .stats => self.handleStats(req),
            .screenshot => self.handleScreenshot(req),
        }
    }

    fn handleStats(self: *DebugServer, req: *Request) void {
        const engine = self.engine;
        const s = engine.stats;
        const io = @import("engine").c.igGetIO();
        const fps: f32 = if (io) |i| i.*.Framerate else 0;

        const json = std.fmt.allocPrint(std.heap.c_allocator,
            \\{{"fps":{d:.1},"entities_rendered":{d},"draw_calls":{d},"physics_active":{d},"physics_total":{d},"culling":{{"visible":{d},"frustum_culled":{d},"occlusion_culled":{d}}},"frame":{d},"avg_us":{{"prepare":{d:.0},"instances":{d:.0},"scene":{d:.0},"postprocess":{d:.0},"imgui":{d:.0}}}}}
        , .{
            fps,
            s.entities_rendered,
            s.draw_calls,
            s.physics_active,
            s.physics_total,
            s.visible_after_cull,
            s.frustum_culled,
            s.occlusion_culled,
            engine.current_frame,
            s.avg_prepare,
            s.avg_instances,
            s.avg_scene,
            s.avg_postprocess,
            s.avg_imgui,
        }) catch {
            req.response.status = .internal_server_error;
            req.response.body = "{\"error\":\"alloc failed\"}";
            return;
        };
        req.response.body = json;
    }

    fn handleScreenshot(self: *DebugServer, req: *Request) void {
        // Trigger the existing screenshot mechanism. The request stays pending
        // until the engine finishes rendering and writing the file.
        const engine = self.engine;
        const path = "tmp/_debug_screenshot.png";

        @memcpy(engine.screenshot_path_buf[0..path.len], path);
        engine.screenshot_path_len = path.len;
        engine.screenshot_requested = true;

        // Don't signal done yet — store as pending. The engine will call
        // completeScreenshot() after the file is written.
        self.pending_screenshot = req;
    }

    /// Called by the engine after a debug screenshot has been written to disk.
    /// Reads the PNG file and sends it as the HTTP response body.
    pub fn completeScreenshot(self: *DebugServer) void {
        const req = self.pending_screenshot orelse return;
        self.pending_screenshot = null;

        const engine = self.engine;
        const path = engine.screenshot_path_buf[0..engine.screenshot_path_len];

        // Read the PNG file into memory
        const cwd = std.fs.cwd();
        const file = cwd.openFile(path, .{}) catch {
            req.response.status = .internal_server_error;
            req.response.body = "{\"error\":\"failed to read screenshot file\"}";
            req.done.set();
            return;
        };
        defer file.close();

        const stat = file.stat() catch {
            req.response.status = .internal_server_error;
            req.response.body = "{\"error\":\"failed to stat screenshot file\"}";
            req.done.set();
            return;
        };

        const png_data = std.heap.c_allocator.alloc(u8, stat.size) catch {
            req.response.status = .internal_server_error;
            req.response.body = "{\"error\":\"alloc failed\"}";
            req.done.set();
            return;
        };

        const bytes_read = file.readAll(png_data) catch {
            std.heap.c_allocator.free(png_data);
            req.response.status = .internal_server_error;
            req.response.body = "{\"error\":\"failed to read screenshot\"}";
            req.done.set();
            return;
        };

        req.response.content_type = "image/png";
        req.response.body = png_data[0..bytes_read];
        req.done.set();
    }
};

// ============================================================
// HTTP accept loop (runs on background thread)
// ============================================================

fn acceptLoop(server: *DebugServer) void {
    while (!server.shutdown.load(.acquire)) {
        const tcp = &(server.tcp_server orelse return);
        const conn = tcp.accept() catch |err| {
            if (server.shutdown.load(.acquire)) return;
            std.debug.print("[debug-server] accept error: {}\n", .{err});
            continue;
        };
        handleConnection(server, conn) catch |err| {
            std.debug.print("[debug-server] connection error: {}\n", .{err});
        };
    }
}

fn handleConnection(server: *DebugServer, conn: net.Server.Connection) !void {
    defer conn.stream.close();

    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;

    var reader = conn.stream.reader(&read_buf);
    var writer = conn.stream.writer(&write_buf);

    var http_server = http.Server.init(reader.interface(), &writer.interface);

    while (!server.shutdown.load(.acquire)) {
        var request = http_server.receiveHead() catch |err| {
            if (err == error.HttpConnectionClosing) return;
            return err;
        };

        const target = request.head.target;

        if (std.mem.eql(u8, target, "/stats")) {
            try handleHttpRequest(server, &request, .stats);
        } else if (std.mem.eql(u8, target, "/screenshot")) {
            try handleHttpRequest(server, &request, .screenshot);
        } else {
            // 404
            try request.respond("{\"error\":\"not found\",\"endpoints\":[\"/stats\",\"/screenshot\"]}", .{
                .status = .not_found,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
        }
    }
}

fn handleHttpRequest(
    server: *DebugServer,
    request: *http.Server.Request,
    kind: RequestKind,
) !void {
    // Drain any request body before responding. std.http.Server.respond()
    // calls discardBody() internally, which asserts if the body hasn't been
    // consumed. POST requests (e.g. /screenshot) may arrive with no body
    // and no Content-Length header, so we drain defensively.
    var discard_buf: [4096]u8 = undefined;
    var body_reader = request.readerExpectNone(&discard_buf);
    _ = body_reader.allocRemaining(std.heap.c_allocator, @enumFromInt(4096)) catch {};

    var req = Request{
        .kind = kind,
    };

    if (!server.queue.push(&req)) {
        try request.respond("{\"error\":\"server busy\"}", .{
            .status = .service_unavailable,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
        return;
    }

    // Block until the main thread processes our request
    req.done.wait();

    const resp = req.response;
    const body = resp.body orelse "{\"error\":\"no response\"}";

    try request.respond(body, .{
        .status = resp.status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = resp.content_type },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
    });
}
