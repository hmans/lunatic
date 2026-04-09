// physics.zig — Jolt Physics integration.
// Wraps zphysics (Jolt via JoltC) and provides a physics system that
// syncs Jolt body transforms to ECS Position/Rotation components.

const std = @import("std");
const zp = @import("zphysics");
const ecs = @import("zflecs");
const engine_mod = @import("engine");
const Engine = engine_mod.Engine;
const core = engine_mod.core_components;
const queryInit = engine_mod.queryInit;

// ============================================================
// Object layers (Jolt requires at least 2 for broad phase)
// ============================================================

pub const object_layers = struct {
    pub const non_moving: zp.ObjectLayer = 0;
    pub const moving: zp.ObjectLayer = 1;
    pub const len: u32 = 2;
};

pub const broad_phase_layers = struct {
    pub const non_moving: zp.BroadPhaseLayer = 0;
    pub const moving: zp.BroadPhaseLayer = 1;
};

// ============================================================
// Layer interfaces (required Jolt boilerplate)
// ============================================================

const BPLayerInterface = extern struct {
    interface: zp.BroadPhaseLayerInterface = .init(@This()),
    map: [object_layers.len]zp.BroadPhaseLayer = .{
        broad_phase_layers.non_moving,
        broad_phase_layers.moving,
    },

    pub fn getNumBroadPhaseLayers(iface: *const zp.BroadPhaseLayerInterface) callconv(.c) u32 {
        const self: *const BPLayerInterface = @alignCast(@fieldParentPtr("interface", iface));
        return @intCast(self.map.len);
    }

    pub fn getBroadPhaseLayer(iface: *const zp.BroadPhaseLayerInterface, layer: zp.ObjectLayer) callconv(.c) zp.BroadPhaseLayer {
        const self: *const BPLayerInterface = @alignCast(@fieldParentPtr("interface", iface));
        return self.map[@intCast(layer)];
    }
};

const ObjVsBPFilter = extern struct {
    filter: zp.ObjectVsBroadPhaseLayerFilter = .init(@This()),

    pub fn shouldCollide(_: *const zp.ObjectVsBroadPhaseLayerFilter, layer1: zp.ObjectLayer, layer2: zp.BroadPhaseLayer) callconv(.c) bool {
        return switch (layer1) {
            object_layers.non_moving => layer2 == broad_phase_layers.moving,
            object_layers.moving => true,
            else => false,
        };
    }
};

const ObjPairFilter = extern struct {
    filter: zp.ObjectLayerPairFilter = .init(@This()),

    pub fn shouldCollide(_: *const zp.ObjectLayerPairFilter, layer1: zp.ObjectLayer, layer2: zp.ObjectLayer) callconv(.c) bool {
        return switch (layer1) {
            object_layers.non_moving => layer2 == object_layers.moving,
            object_layers.moving => true,
            else => false,
        };
    }
};

// ============================================================
// Physics state — stored on Engine
// ============================================================

pub const PhysicsState = struct {
    system: ?*zp.PhysicsSystem = null,
    bp_layer_iface: BPLayerInterface = .{},
    obj_vs_bp_filter: ObjVsBPFilter = .{},
    obj_pair_filter: ObjPairFilter = .{},
    /// Persistent query for entities with Position + Rotation + RigidBody.
    /// Created once at init, reused every physics step for transform sync.
    sync_query: ?*ecs.query_t = null,
    initialized: bool = false,
};

// ============================================================
// Init / Deinit
// ============================================================

pub fn initPhysics(self: *Engine) !void {
    try zp.init(std.heap.c_allocator, .{
        .temp_allocator_size = 64 * 1024 * 1024, // 64MB scratch (default 16MB)
        .num_threads = -1,
    });

    self.physics = .{};

    self.physics.system = try zp.PhysicsSystem.create(
        &self.physics.bp_layer_iface.interface,
        &self.physics.obj_vs_bp_filter.filter,
        &self.physics.obj_pair_filter.filter,
        .{
            .max_bodies = 16384,
            .max_body_pairs = 16384 * 4,
            .max_contact_constraints = 16384 * 4,
        },
    );
    self.physics.initialized = true;

    // Create persistent query for transform sync (Position + Rotation + RigidBody).
    const ids = physicsQueryIds();
    self.physics.sync_query = queryInit(self.world, &ids, &.{});
}

pub fn deinitPhysics(self: *Engine) void {
    if (!self.physics.initialized) return;
    if (self.physics.sync_query) |q| ecs.query_fini(q);
    if (self.physics.system) |sys| sys.destroy();
    zp.deinit();
    self.physics.initialized = false;
}

// ============================================================
// Public API — re-export zphysics types for game code
// ============================================================

pub const BodyId = zp.BodyId;
pub const BodyCreationSettings = zp.BodyCreationSettings;
pub const MotionType = zp.MotionType;
pub const Activation = zp.Activation;
pub const Shape = zp.Shape;
pub const ShapeSettings = zp.ShapeSettings;
pub const BoxShapeSettings = zp.BoxShapeSettings;
pub const SphereShapeSettings = zp.SphereShapeSettings;

/// Get the mutable body interface for creating/manipulating bodies.
pub fn getBodyInterface(self: *Engine) *zp.BodyInterface {
    return self.physics.system.?.getBodyInterfaceMut();
}

/// Optimize the broad phase after bulk-adding static bodies.
pub fn optimizeBroadPhase(self: *Engine) void {
    if (self.physics.system) |sys| sys.optimizeBroadPhase();
}

/// Add a box-shaped physics body to an entity. Reads Position from ECS.
/// Half-extents (hx, hy, hz) define the box size. Sets RigidBody component.
pub fn addPhysicsBox(self: *Engine, entity: ecs.entity_t, hx: f32, hy: f32, hz: f32, motion: MotionType, restitution: f32, friction: f32) void {
    const pos = ecs.get(self.world, entity, core.Position) orelse return;
    const shape_settings = BoxShapeSettings.create(.{ hx, hy, hz }) catch return;
    const shape = shape_settings.asShapeSettings().createShape() catch return;
    defer shape.release();

    const body_iface = getBodyInterface(self);
    const body_id = body_iface.createAndAddBody(.{
        .position = .{ pos.x, pos.y, pos.z, 0 },
        .shape = shape,
        .motion_type = motion,
        .object_layer = if (motion == .static) object_layers.non_moving else object_layers.moving,
        .restitution = restitution,
        .friction = friction,
        .linear_damping = 0.2,
        .angular_damping = 0.4,
    }, .activate) catch return;

    _ = ecs.set(self.world, entity, core.RigidBody, core.RigidBody{ .body_id = @intFromEnum(body_id) });
}

/// Add a sphere-shaped physics body to an entity. Reads Position from ECS.
/// Sets RigidBody component.
pub fn addPhysicsSphere(self: *Engine, entity: ecs.entity_t, radius: f32, motion: MotionType, restitution: f32, friction: f32) void {
    const pos = ecs.get(self.world, entity, core.Position) orelse return;
    const shape_settings = SphereShapeSettings.create(radius) catch return;
    const shape = shape_settings.asShapeSettings().createShape() catch return;
    defer shape.release();

    const body_iface = getBodyInterface(self);
    const body_id = body_iface.createAndAddBody(.{
        .position = .{ pos.x, pos.y, pos.z, 0 },
        .shape = shape,
        .motion_type = motion,
        .object_layer = if (motion == .static) object_layers.non_moving else object_layers.moving,
        .restitution = restitution,
        .friction = friction,
        .linear_damping = 0.2,
        .angular_damping = 0.4,
    }, .activate) catch return;

    _ = ecs.set(self.world, entity, core.RigidBody, core.RigidBody{ .body_id = @intFromEnum(body_id) });
}

/// Register a flecs OnRemove observer for RigidBody so that Jolt bodies
/// are automatically cleaned up when entities are deleted or lose their
/// RigidBody component. Call once after initPhysics + component registration.
pub fn registerPhysicsObserver(self: *Engine) void {
    var desc = std.mem.zeroes(ecs.observer_desc_t);
    desc.callback = &onRigidBodyRemove;
    desc.ctx = self;
    desc.events[0] = ecs.OnRemove;
    desc.query.terms[0].id = ecs.id(core.RigidBody);
    _ = ecs.OBSERVER(self.world, "physics_cleanup", &desc);
}

/// Flecs OnRemove callback: destroy the Jolt body when RigidBody is removed.
fn onRigidBodyRemove(it: *ecs.iter_t) callconv(.c) void {
    const engine: *Engine = @ptrCast(@alignCast(it.ctx));
    const phys_sys = engine.physics.system orelse return;
    const body_iface = phys_sys.getBodyInterfaceMut();

    for (it.entities()) |entity| {
        const rb = ecs.get(it.world, entity, core.RigidBody) orelse continue;
        const body_id: zp.BodyId = @enumFromInt(rb.body_id);
        if (body_id == .invalid) continue;
        body_iface.removeAndDestroyBody(body_id);
    }
}

// ============================================================
// Built-in physics system
// ============================================================

pub const physics_timestep: f32 = 1.0 / 60.0;

/// Step the physics simulation once at fixed timestep and sync transforms.
/// Called by flecs at a fixed interval (physics_timestep) — flecs handles
/// the accumulator and calls this multiple times per frame if needed.
pub fn physicsSystem(self: *Engine, _: f32) void {
    const phys = self.physics.system orelse return;
    const body_iface = phys.getBodyInterfaceNoLock();

    phys.update(physics_timestep, .{}) catch return;
    syncCurrentTransforms(self, body_iface);
}

/// Build component IDs for the physics query at runtime.
fn physicsQueryIds() [3]ecs.id_t {
    return .{ ecs.id(core.Position), ecs.id(core.Rotation), ecs.id(core.RigidBody) };
}

/// Sync Jolt transforms into ECS Position/Rotation.
/// Only updates active (non-sleeping) bodies to avoid wasting cycles
/// on the hundreds of bodies that Jolt has deactivated.
fn syncCurrentTransforms(self: *Engine, body_iface: *const zp.BodyInterface) void {
    const q = self.physics.sync_query orelse return;
    var it = ecs.query_iter(self.world, q);

    while (ecs.query_next(&it)) for (it.entities()) |entity| {
        const rb = ecs.get(self.world, entity, core.RigidBody) orelse continue;
        const body_id: zp.BodyId = @enumFromInt(rb.body_id);
        if (body_id == .invalid) continue;

        // Skip sleeping bodies — their transforms haven't changed.
        if (!body_iface.isActive(body_id)) continue;

        const jolt_pos = body_iface.getPosition(body_id);
        const jolt_rot = body_iface.getRotation(body_id);
        const euler = quatToEuler(jolt_rot);

        var ecs_pos = ecs.get_mut(self.world, entity, core.Position) orelse continue;
        ecs_pos.x = jolt_pos[0];
        ecs_pos.y = jolt_pos[1];
        ecs_pos.z = jolt_pos[2];

        var ecs_rot = ecs.get_mut(self.world, entity, core.Rotation) orelse continue;
        ecs_rot.x = euler[0];
        ecs_rot.y = euler[1];
        ecs_rot.z = euler[2];
    };
}

// Note: interpolation (lerp between prev and current transforms) was removed
// when switching to flecs interval-based physics. If visual jitter becomes
// noticeable at low frame rates, re-add interpolation as a separate PreStore
// system that lerps between the last two physics states.

// ============================================================
// Helpers
// ============================================================

/// Convert quaternion [x,y,z,w] to Euler angles [pitch,yaw,roll] in degrees.
fn quatToEuler(q: [4]f32) [3]f32 {
    const x = q[0];
    const y = q[1];
    const z = q[2];
    const w = q[3];

    const sinp = 2.0 * (w * x - z * y);
    const pitch = if (@abs(sinp) >= 1.0)
        std.math.copysign(@as(f32, std.math.pi / 2.0), sinp)
    else
        std.math.asin(sinp);

    const siny_cosp = 2.0 * (w * y + x * z);
    const cosy_cosp = 1.0 - 2.0 * (x * x + y * y);
    const yaw = std.math.atan2(siny_cosp, cosy_cosp);

    const sinr_cosp = 2.0 * (w * z + x * y);
    const cosr_cosp = 1.0 - 2.0 * (z * z + x * x);
    const roll = std.math.atan2(sinr_cosp, cosr_cosp);

    const rad2deg = 180.0 / std.math.pi;
    return .{ pitch * rad2deg, yaw * rad2deg, roll * rad2deg };
}
