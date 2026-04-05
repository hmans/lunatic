const Engine = @import("engine").Engine;

pub fn main() !void {
    var engine: Engine = undefined;
    try engine.init(.{});
    defer engine.deinit();

    try engine.loadScript("game/main.lua");
    try engine.run();
}
