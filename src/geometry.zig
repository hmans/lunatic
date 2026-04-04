// geometry.zig — Mesh generators. Pure functions that return vertex arrays.

const std = @import("std");
const math = std.math;

pub const Vertex = extern struct {
    px: f32,
    py: f32,
    pz: f32,
    nx: f32,
    ny: f32,
    nz: f32,
};

// ============================================================
// Cube
// ============================================================

/// Unit cube centered at the origin (side length 1).
pub fn cube(allocator: std.mem.Allocator) ![]Vertex {
    const s = 0.5;

    // Each face: 2 triangles, 6 vertices, shared normal.
    const faces = [6][4]f32{
        .{ 0, 0, 1, s },  // +Z
        .{ 0, 0, -1, s },  // -Z
        .{ 0, 1, 0, s },  // +Y
        .{ 0, -1, 0, s }, // -Y
        .{ 1, 0, 0, s },  // +X
        .{ -1, 0, 0, s }, // -X
    };

    var verts = try allocator.alloc(Vertex, 36);

    for (faces, 0..) |face, fi| {
        const nx = face[0];
        const ny = face[1];
        const nz = face[2];

        // Build a local coordinate frame from the normal.
        // tangent and bitangent span the face plane.
        var tx: f32 = 0;
        const ty: f32 = 0;
        var tz: f32 = 0;
        const bx: f32 = 0;
        var by: f32 = 0;
        var bz: f32 = 0;

        if (ny != 0) {
            // Up/down face: tangent = +X, bitangent = +Z (or -Z)
            tx = 1;
            bz = ny;
        } else if (nz != 0) {
            // Front/back face: tangent = +X (or -X), bitangent = +Y
            tx = -nz;
            by = 1;
        } else {
            // Left/right face: tangent = +Z (or -Z), bitangent = +Y
            tz = nx;
            by = 1;
        }

        // 4 corners: center + s*(±tangent ± bitangent) + s*normal
        const cx = nx * s;
        const cy = ny * s;
        const cz = nz * s;

        const corners = [4]Vertex{
            .{ .px = cx - s * tx - s * bx, .py = cy - s * ty - s * by, .pz = cz - s * tz - s * bz, .nx = nx, .ny = ny, .nz = nz },
            .{ .px = cx + s * tx - s * bx, .py = cy + s * ty - s * by, .pz = cz + s * tz - s * bz, .nx = nx, .ny = ny, .nz = nz },
            .{ .px = cx + s * tx + s * bx, .py = cy + s * ty + s * by, .pz = cz + s * tz + s * bz, .nx = nx, .ny = ny, .nz = nz },
            .{ .px = cx - s * tx + s * bx, .py = cy - s * ty + s * by, .pz = cz - s * tz + s * bz, .nx = nx, .ny = ny, .nz = nz },
        };

        const base = fi * 6;
        verts[base + 0] = corners[1];
        verts[base + 1] = corners[0];
        verts[base + 2] = corners[3];
        verts[base + 3] = corners[1];
        verts[base + 4] = corners[3];
        verts[base + 5] = corners[2];
    }

    return verts;
}

// ============================================================
// Sphere (UV sphere)
// ============================================================

/// UV sphere centered at origin with radius 0.5.
/// `segments` = longitude slices, `rings` = latitude rings (excluding poles).
pub fn sphere(allocator: std.mem.Allocator, segments: u32, rings: u32) ![]Vertex {
    const tri_count = segments * rings * 2;
    var verts = try allocator.alloc(Vertex, tri_count * 3);
    var vi: usize = 0;

    const segs_f: f32 = @floatFromInt(segments);
    const rings_total: f32 = @floatFromInt(rings + 1);
    const r: f32 = 0.5;

    for (0..segments) |si| {
        const s0: f32 = @floatFromInt(si);
        const s1: f32 = s0 + 1.0;
        const theta0 = s0 / segs_f * 2.0 * math.pi;
        const theta1 = s1 / segs_f * 2.0 * math.pi;

        for (0..rings) |ri| {
            const r0: f32 = @floatFromInt(ri);
            const r1: f32 = r0 + 1.0;
            const phi0 = r0 / rings_total * math.pi;
            const phi1 = r1 / rings_total * math.pi;

            // 4 corners of this quad
            const p00 = spherePoint(r, theta0, phi0);
            const p10 = spherePoint(r, theta1, phi0);
            const p01 = spherePoint(r, theta0, phi1);
            const p11 = spherePoint(r, theta1, phi1);

            // Triangle 1 (CCW when viewed from outside)
            verts[vi] = p00;
            verts[vi + 1] = p10;
            verts[vi + 2] = p11;
            // Triangle 2
            verts[vi + 3] = p00;
            verts[vi + 4] = p11;
            verts[vi + 5] = p01;
            vi += 6;
        }
    }

    return verts;
}

fn spherePoint(r: f32, theta: f32, phi: f32) Vertex {
    const sp = @sin(phi);
    const cp = @cos(phi);
    const st = @sin(theta);
    const ct = @cos(theta);

    const nx = sp * ct;
    const ny = cp;
    const nz = sp * st;

    return .{
        .px = r * nx,
        .py = r * ny,
        .pz = r * nz,
        .nx = nx,
        .ny = ny,
        .nz = nz,
    };
}

// ============================================================
// Tests
// ============================================================

test "cube generates 36 vertices" {
    const verts = try cube(std.testing.allocator);
    defer std.testing.allocator.free(verts);
    try std.testing.expectEqual(@as(usize, 36), verts.len);
}

test "cube normals are unit length" {
    const verts = try cube(std.testing.allocator);
    defer std.testing.allocator.free(verts);
    for (verts) |v| {
        const len = @sqrt(v.nx * v.nx + v.ny * v.ny + v.nz * v.nz);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), len, 0.001);
    }
}

test "sphere generates expected vertex count" {
    const verts = try sphere(std.testing.allocator, 16, 8);
    defer std.testing.allocator.free(verts);
    // 16 segments * 8 rings * 2 triangles * 3 verts = 768
    try std.testing.expectEqual(@as(usize, 768), verts.len);
}

test "sphere normals are unit length" {
    const verts = try sphere(std.testing.allocator, 16, 8);
    defer std.testing.allocator.free(verts);
    for (verts) |v| {
        const len = @sqrt(v.nx * v.nx + v.ny * v.ny + v.nz * v.nz);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), len, 0.001);
    }
}
