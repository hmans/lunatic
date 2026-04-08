const std = @import("std");
const Engine = @import("engine").Engine;

pub fn main() !void {
    var debug = false;
    var args = std.process.args();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) debug = true;
    }

    var engine: Engine = undefined;
    try engine.init(.{ .width = 1280, .height = 720, .debug_stats = debug });

    try engine.run();

    // run() returned normally — the player quit cleanly. Call deinit
    // explicitly then exit(0), because background threads (debug server,
    // flecs REST) can panic during teardown and produce a non-zero exit code.
    engine.deinit();
    std.process.exit(0);
}
