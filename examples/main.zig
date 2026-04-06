const std = @import("std");
const Engine = @import("engine").Engine;

pub fn main() !void {
    // Check for --debug flag
    var debug = false;
    var args = std.process.args();
    _ = args.next(); // skip executable
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) debug = true;
    }

    var engine: Engine = undefined;
    try engine.init(.{ .debug_stats = debug });
    defer engine.deinit();

    try engine.loadScript("examples/main.lua");
    try engine.run();
}
