// components.zig — Game-specific components (extends core).

const core = @import("core_components");

pub const Spin = struct {
    speed: f32 = 0,
    pub const lua = .{ .name = "spin" };
};

pub const Player = struct {
    pub const lua = .{ .name = "player" };
};

pub const all = core.withExtra(.{ Spin, Player });
