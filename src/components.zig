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

pub const Camera = struct {
    fov: f32 = 60,
    near: f32 = 0.1,
    far: f32 = 100.0,
    viewport_x: f32 = 0.0,
    viewport_y: f32 = 0.0,
    viewport_w: f32 = 1.0,
    viewport_h: f32 = 1.0,
    pub const Lua = lua.Component("camera", @This());
};

pub const DirectionalLight = struct {
    dir_x: f32 = 0.4,
    dir_y: f32 = 0.8,
    dir_z: f32 = 0.4,
    r: f32 = 1.0,
    g: f32 = 1.0,
    b: f32 = 1.0,
    pub const Lua = lua.Component("directional_light", @This());
};

/// Single source of truth: all component types exposed to Lua.
pub const all = .{ Position, Rotation, Spin, Player, MeshHandle, MaterialHandle, Camera, DirectionalLight };
