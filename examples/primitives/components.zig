// components.zig — Primitives example. Adds Spin and Player to core components.

const core = @import("core_components");
const lua = @import("lua");

pub const Spin = struct {
    speed: f32 = 0,
    pub const Lua = lua.Component("spin", @This());
};

pub const Player = struct {
    pub const lua_name = "player";
};

pub const all = core.withExtra(.{ Spin, Player });
