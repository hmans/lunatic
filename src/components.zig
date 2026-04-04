// components.zig — ECS component types.

const lua = @import("lua.zig");

pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    pub const Lua = lua.Component("position", @This());
};

pub const Rotation = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    pub const Lua = lua.Component("rotation", @This());
};

pub const Spin = struct {
    speed: f32 = 0,
    pub const Lua = lua.Component("spin", @This());
};

pub const Player = struct {
    pub const lua_name = "player";
};

pub const MeshHandle = struct {
    id: u32 = 0,
    pub const lua_name = "mesh";
};

pub const MaterialHandle = struct {
    id: u32 = 0,
    pub const lua_name = "material";
};

/// Single source of truth: all component types exposed to Lua.
pub const all = .{ Position, Rotation, Spin, Player, MeshHandle, MaterialHandle };
