// geometry.zig — Mesh generators. Return indexed vertex + index arrays.

const std = @import("std");
const math = std.math;

pub const Vertex = extern struct {
    px: f32,
    py: f32,
    pz: f32,
    nx: f32,
    ny: f32,
    nz: f32,
    u: f32 = 0,
    v: f32 = 0,
    tx: f32 = 1, // tangent
    ty: f32 = 0,
    tz: f32 = 0,
    tw: f32 = 1, // handedness
};

pub const Mesh = struct {
    vertices: []Vertex,
    indices: []u16,
};

// ============================================================
// Cube
// ============================================================

/// Unit cube centered at the origin (side length 1). 24 vertices (4 per face), 36 indices.
pub fn cube(allocator: std.mem.Allocator) !Mesh {
    const s = 0.5;

    const faces = [6][4]f32{
        .{ 0, 0, 1, s },  // +Z
        .{ 0, 0, -1, s },  // -Z
        .{ 0, 1, 0, s },  // +Y
        .{ 0, -1, 0, s }, // -Y
        .{ 1, 0, 0, s },  // +X
        .{ -1, 0, 0, s }, // -X
    };

    var verts = try allocator.alloc(Vertex, 24); // 4 per face
    var indices = try allocator.alloc(u16, 36); // 6 per face

    for (faces, 0..) |face, fi| {
        const nx = face[0];
        const ny = face[1];
        const nz = face[2];

        var tx: f32 = 0;
        const ty: f32 = 0;
        var tz: f32 = 0;
        const bx: f32 = 0;
        var by: f32 = 0;
        var bz: f32 = 0;

        if (ny != 0) {
            tx = 1;
            bz = ny;
        } else if (nz != 0) {
            tx = -nz;
            by = 1;
        } else {
            tz = nx;
            by = 1;
        }

        const cx = nx * s;
        const cy = ny * s;
        const cz = nz * s;

        const vbase = fi * 4;
        verts[vbase + 0] = .{ .px = cx - s * tx - s * bx, .py = cy - s * ty - s * by, .pz = cz - s * tz - s * bz, .nx = nx, .ny = ny, .nz = nz, .u = 0, .v = 1 };
        verts[vbase + 1] = .{ .px = cx + s * tx - s * bx, .py = cy + s * ty - s * by, .pz = cz + s * tz - s * bz, .nx = nx, .ny = ny, .nz = nz, .u = 1, .v = 1 };
        verts[vbase + 2] = .{ .px = cx + s * tx + s * bx, .py = cy + s * ty + s * by, .pz = cz + s * tz + s * bz, .nx = nx, .ny = ny, .nz = nz, .u = 1, .v = 0 };
        verts[vbase + 3] = .{ .px = cx - s * tx + s * bx, .py = cy - s * ty + s * by, .pz = cz - s * tz + s * bz, .nx = nx, .ny = ny, .nz = nz, .u = 0, .v = 0 };

        // CCW winding (matching the old verified order: 1,0,3 + 1,3,2)
        const ibase = fi * 6;
        const b: u16 = @intCast(vbase);
        indices[ibase + 0] = b + 1;
        indices[ibase + 1] = b + 0;
        indices[ibase + 2] = b + 3;
        indices[ibase + 3] = b + 1;
        indices[ibase + 4] = b + 3;
        indices[ibase + 5] = b + 2;
    }

    return .{ .vertices = verts, .indices = indices };
}

// ============================================================
// Sphere (UV sphere)
// ============================================================

/// UV sphere centered at origin with radius 0.5.
/// `segments` = longitude slices, `rings` = latitude rings (excluding poles).
pub fn sphere(allocator: std.mem.Allocator, segments: u32, rings: u32) !Mesh {
    const rows = rings + 1; // number of latitude divisions (rings + 1 = edges)
    const vert_count = (segments + 1) * (rows + 1);
    const index_count = segments * rows * 6;

    var verts = try allocator.alloc(Vertex, vert_count);
    var indices = try allocator.alloc(u16, index_count);

    const segs_f: f32 = @floatFromInt(segments);
    const rows_f: f32 = @floatFromInt(rows);
    const r: f32 = 0.5;

    // Generate vertices in a grid: (segments+1) columns x (rows+1) rows
    var vi: usize = 0;
    for (0..rows + 1) |ri| {
        const phi = @as(f32, @floatFromInt(ri)) / rows_f * math.pi;
        const sp = @sin(phi);
        const cp = @cos(phi);

        for (0..segments + 1) |si| {
            const theta = @as(f32, @floatFromInt(si)) / segs_f * 2.0 * math.pi;
            const st = @sin(theta);
            const ct = @cos(theta);

            const nx = sp * ct;
            const ny = cp;
            const nz = sp * st;

            verts[vi] = .{
                .px = r * nx,
                .py = r * ny,
                .pz = r * nz,
                .nx = nx,
                .ny = ny,
                .nz = nz,
                .u = @as(f32, @floatFromInt(si)) / segs_f,
                .v = @as(f32, @floatFromInt(ri)) / rows_f,
            };
            vi += 1;
        }
    }

    // Generate indices
    const cols: u16 = @intCast(segments + 1);
    var ii: usize = 0;
    for (0..rows) |ri| {
        for (0..segments) |si| {
            const row: u16 = @intCast(ri);
            const col: u16 = @intCast(si);
            const tl = row * cols + col;
            const tr = tl + 1;
            const bl = tl + cols;
            const br = bl + 1;

            // CCW winding (viewed from outside)
            indices[ii + 0] = tl;
            indices[ii + 1] = tr;
            indices[ii + 2] = bl;
            indices[ii + 3] = tr;
            indices[ii + 4] = br;
            indices[ii + 5] = bl;
            ii += 6;
        }
    }

    return .{ .vertices = verts, .indices = indices };
}

// ============================================================
// Tests
// ============================================================

test "cube generates 24 vertices and 36 indices" {
    const mesh = try cube(std.testing.allocator);
    defer std.testing.allocator.free(mesh.vertices);
    defer std.testing.allocator.free(mesh.indices);
    try std.testing.expectEqual(@as(usize, 24), mesh.vertices.len);
    try std.testing.expectEqual(@as(usize, 36), mesh.indices.len);
}

test "cube normals are unit length" {
    const mesh = try cube(std.testing.allocator);
    defer std.testing.allocator.free(mesh.vertices);
    defer std.testing.allocator.free(mesh.indices);
    for (mesh.vertices) |v| {
        const len = @sqrt(v.nx * v.nx + v.ny * v.ny + v.nz * v.nz);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), len, 0.001);
    }
}

test "cube indices are in range" {
    const mesh = try cube(std.testing.allocator);
    defer std.testing.allocator.free(mesh.vertices);
    defer std.testing.allocator.free(mesh.indices);
    for (mesh.indices) |idx| {
        try std.testing.expect(idx < mesh.vertices.len);
    }
}

test "sphere generates expected counts" {
    const mesh = try sphere(std.testing.allocator, 16, 8);
    defer std.testing.allocator.free(mesh.vertices);
    defer std.testing.allocator.free(mesh.indices);
    // (16+1) * (8+1+1) = 17 * 10 = 170 vertices
    try std.testing.expectEqual(@as(usize, 170), mesh.vertices.len);
    // 16 * 9 * 6 = 864 indices
    try std.testing.expectEqual(@as(usize, 864), mesh.indices.len);
}

test "sphere normals are unit length" {
    const mesh = try sphere(std.testing.allocator, 16, 8);
    defer std.testing.allocator.free(mesh.vertices);
    defer std.testing.allocator.free(mesh.indices);
    for (mesh.vertices) |v| {
        const len = @sqrt(v.nx * v.nx + v.ny * v.ny + v.nz * v.nz);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), len, 0.001);
    }
}

test "sphere indices are in range" {
    const mesh = try sphere(std.testing.allocator, 16, 8);
    defer std.testing.allocator.free(mesh.vertices);
    defer std.testing.allocator.free(mesh.indices);
    for (mesh.indices) |idx| {
        try std.testing.expect(idx < mesh.vertices.len);
    }
}
