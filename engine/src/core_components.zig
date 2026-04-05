// core_components.zig — Engine-provided component types.
// These are always available regardless of which example is running.

pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    pub const lua = .{ .name = "position" };
};

pub const Rotation = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    pub const lua = .{ .name = "rotation" };
};

pub const Scale = struct {
    x: f32 = 1,
    y: f32 = 1,
    z: f32 = 1,
    pub const lua = .{ .name = "scale" };
};

pub const MeshHandle = struct {
    id: u32 = 0,
    pub const lua = .{ .name = "mesh", .resolve = .mesh };
};

pub const MaterialHandle = struct {
    id: u32 = 0,
    pub const lua = .{ .name = "material", .resolve = .material };
};

pub const Camera = struct {
    fov: f32 = 60,
    near: f32 = 0.1,
    far: f32 = 100.0,
    viewport_x: f32 = 0.0,
    viewport_y: f32 = 0.0,
    viewport_w: f32 = 1.0,
    viewport_h: f32 = 1.0,
    // Post-processing (per-camera lens settings)
    exposure: f32 = 1.0,
    bloom_intensity: f32 = 0.0, // 0 = no bloom, just tonemap
    dof_focus_dist: f32 = 0.0, // 0 = DoF disabled. World-space focal distance.
    dof_focus_range: f32 = 5.0, // Width of in-focus band (smaller = shallower DoF)
    dof_blur_radius: f32 = 8.0, // Max blur radius in pixels (at half res)
    vignette: f32 = 0.0, // 0 = off, 0.3-0.8 = subtle to strong
    vignette_smoothness: f32 = 0.5, // How gradual the falloff is (higher = larger bright center)
    chromatic_aberration: f32 = 0.0, // 0 = off, 0.5-2.0 = subtle to strong RGB fringing
    grain: f32 = 0.0, // 0 = off, 0.02-0.1 = subtle film grain
    color_temp: f32 = 0.0, // negative = cool/blue, positive = warm/orange
    pub const lua = .{ .name = "camera" };
};

pub const DirectionalLight = struct {
    dir_x: f32 = 0.4,
    dir_y: f32 = 0.8,
    dir_z: f32 = 0.4,
    r: f32 = 1.0,
    g: f32 = 1.0,
    b: f32 = 1.0,
    pub const lua = .{ .name = "directional_light" };
};

pub const LookAt = struct {
    target: u32 = 0,
    pub const lua = .{ .name = "look_at" };
};

/// FPS-style fly camera controller. Attach to a camera entity with Position + Rotation.
/// Right-click to activate (hides cursor), WASD + Space/Ctrl to move.
pub const FlyCamera = struct {
    speed: f32 = 10,
    fast_speed: f32 = 30,
    sensitivity: f32 = 0.15,
    pub const lua = .{ .name = "fly_camera" };
};

/// Tracks entity lifetime in seconds. Incremented automatically by the engine.
pub const Age = struct {
    seconds: f32 = 0,
    pub const lua = .{ .name = "age" };
};

/// Rigid body physics (Jolt). body_id is managed by the physics system.
pub const RigidBody = struct {
    body_id: u32 = 0,
    pub const lua = .{ .name = "rigid_body" };
};

/// Core component tuple — engine modules reference these directly.
pub const all = .{ Position, Rotation, Scale, MeshHandle, MaterialHandle, Camera, DirectionalLight, LookAt, FlyCamera, Age, RigidBody };

/// Concatenate core components with example-specific ones.
/// Usage: `pub const all = core.withExtra(.{ Spin, Player });`
pub fn withExtra(extra: anytype) @TypeOf(all ++ extra) {
    return all ++ extra;
}
