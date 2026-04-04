// math3d.zig — minimal 3D math for the engine (column-major mat4, vec3/vec4)

const std = @import("std");
const math = std.math;

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn new(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn normalize(v: Vec3) Vec3 {
        const len = @sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
        if (len == 0) return v;
        return .{ .x = v.x / len, .y = v.y / len, .z = v.z / len };
    }

    pub fn negate(v: Vec3) Vec3 {
        return .{ .x = -v.x, .y = -v.y, .z = -v.z };
    }
};

/// Column-major 4x4 matrix. m[col][row] — matches GPU layout directly.
pub const Mat4 = struct {
    m: [4][4]f32,

    pub fn identity() Mat4 {
        return .{ .m = .{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 0, 0, 0, 1 },
        } };
    }

    pub fn perspective(fov_deg: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const fov_rad = fov_deg * (math.pi / 180.0);
        const f = 1.0 / @tan(fov_rad / 2.0);
        const range_inv = 1.0 / (near - far);

        var result = Mat4{ .m = .{
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 0 },
        } };
        result.m[0][0] = f / aspect;
        result.m[1][1] = f;
        result.m[2][2] = far * range_inv;
        result.m[2][3] = -1.0;
        result.m[3][2] = near * far * range_inv;
        return result;
    }

    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
        const f = Vec3.normalize(Vec3.sub(target, eye));
        const s = Vec3.normalize(Vec3.cross(f, up));
        const u = Vec3.cross(s, f);

        var result = Mat4.identity();
        result.m[0][0] = s.x;
        result.m[1][0] = s.y;
        result.m[2][0] = s.z;
        result.m[0][1] = u.x;
        result.m[1][1] = u.y;
        result.m[2][1] = u.z;
        result.m[0][2] = -f.x;
        result.m[1][2] = -f.y;
        result.m[2][2] = -f.z;
        result.m[3][0] = -Vec3.dot(s, eye);
        result.m[3][1] = -Vec3.dot(u, eye);
        result.m[3][2] = Vec3.dot(f, eye);
        return result;
    }

    pub fn rotateY(angle_deg: f32) Mat4 {
        const a = angle_deg * (math.pi / 180.0);
        const cos_a = @cos(a);
        const sin_a = @sin(a);
        var result = Mat4.identity();
        result.m[0][0] = cos_a;
        result.m[0][2] = sin_a;
        result.m[2][0] = -sin_a;
        result.m[2][2] = cos_a;
        return result;
    }

    pub fn rotateX(angle_deg: f32) Mat4 {
        const a = angle_deg * (math.pi / 180.0);
        const cos_a = @cos(a);
        const sin_a = @sin(a);
        var result = Mat4.identity();
        result.m[1][1] = cos_a;
        result.m[1][2] = -sin_a;
        result.m[2][1] = sin_a;
        result.m[2][2] = cos_a;
        return result;
    }

    pub fn rotateZ(angle_deg: f32) Mat4 {
        const a = angle_deg * (math.pi / 180.0);
        const cos_a = @cos(a);
        const sin_a = @sin(a);
        var result = Mat4.identity();
        result.m[0][0] = cos_a;
        result.m[0][1] = sin_a;
        result.m[1][0] = -sin_a;
        result.m[1][1] = cos_a;
        return result;
    }

    pub fn translate(tx: f32, ty: f32, tz: f32) Mat4 {
        var result = Mat4.identity();
        result.m[3][0] = tx;
        result.m[3][1] = ty;
        result.m[3][2] = tz;
        return result;
    }

    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var result: Mat4 = undefined;
        for (0..4) |col| {
            for (0..4) |row| {
                var sum: f32 = 0;
                for (0..4) |k| {
                    sum += a.m[k][row] * b.m[col][k];
                }
                result.m[col][row] = sum;
            }
        }
        return result;
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const eps = 1e-6;

fn expectMat4Approx(actual: Mat4, expected: Mat4) !void {
    for (0..4) |col| {
        for (0..4) |row| {
            try testing.expectApproxEqAbs(expected.m[col][row], actual.m[col][row], eps);
        }
    }
}

// ---- Vec3 ----

test "Vec3.sub" {
    const a = Vec3.new(3, 5, 7);
    const b = Vec3.new(1, 2, 3);
    const r = Vec3.sub(a, b);
    try testing.expectApproxEqAbs(@as(f32, 2), r.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 3), r.y, eps);
    try testing.expectApproxEqAbs(@as(f32, 4), r.z, eps);
}

test "Vec3.dot" {
    const a = Vec3.new(1, 0, 0);
    const b = Vec3.new(0, 1, 0);
    try testing.expectApproxEqAbs(@as(f32, 0), Vec3.dot(a, b), eps);
    try testing.expectApproxEqAbs(@as(f32, 1), Vec3.dot(a, a), eps);
}

test "Vec3.cross produces orthogonal vector" {
    const x = Vec3.new(1, 0, 0);
    const y = Vec3.new(0, 1, 0);
    const z = Vec3.cross(x, y);
    try testing.expectApproxEqAbs(@as(f32, 0), z.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 0), z.y, eps);
    try testing.expectApproxEqAbs(@as(f32, 1), z.z, eps);
}

test "Vec3.normalize unit length" {
    const v = Vec3.new(3, 4, 0);
    const n = Vec3.normalize(v);
    const len = @sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    try testing.expectApproxEqAbs(@as(f32, 1), len, eps);
    try testing.expectApproxEqAbs(@as(f32, 0.6), n.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 0.8), n.y, eps);
}

test "Vec3.normalize zero vector returns zero" {
    const v = Vec3.new(0, 0, 0);
    const n = Vec3.normalize(v);
    try testing.expectApproxEqAbs(@as(f32, 0), n.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 0), n.y, eps);
    try testing.expectApproxEqAbs(@as(f32, 0), n.z, eps);
}

test "Vec3.negate" {
    const v = Vec3.new(1, -2, 3);
    const n = Vec3.negate(v);
    try testing.expectApproxEqAbs(@as(f32, -1), n.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 2), n.y, eps);
    try testing.expectApproxEqAbs(@as(f32, -3), n.z, eps);
}

// ---- Mat4 ----

test "Mat4.identity * identity = identity" {
    const i = Mat4.identity();
    try expectMat4Approx(Mat4.mul(i, i), i);
}

test "Mat4.translate moves a point" {
    const t = Mat4.translate(1, 2, 3);
    // column-major: t * [0,0,0,1] should give [1,2,3,1]
    // Column 3 holds the translation
    try testing.expectApproxEqAbs(@as(f32, 1), t.m[3][0], eps);
    try testing.expectApproxEqAbs(@as(f32, 2), t.m[3][1], eps);
    try testing.expectApproxEqAbs(@as(f32, 3), t.m[3][2], eps);
}

test "Mat4.rotateY 90 degrees" {
    const r = Mat4.rotateY(90);
    // m[col][row], column 0 = rotated X axis = [cos, 0, -sin, 0]
    // At 90°: cos=0, sin=1 → column 0 = [0, 0, -1, 0]
    try testing.expectApproxEqAbs(@as(f32, 0), r.m[0][0], eps);
    try testing.expectApproxEqAbs(@as(f32, 1), r.m[0][2], eps); // sin(90)
    try testing.expectApproxEqAbs(@as(f32, -1), r.m[2][0], eps); // -sin(90)
}

test "Mat4.rotateX 90 degrees" {
    const r = Mat4.rotateX(90);
    // Column 1 = rotated Y axis: [0, cos, -sin, 0]
    // At 90°: cos=0, sin=1 → [0, 0, -1, 0]
    try testing.expectApproxEqAbs(@as(f32, 0), r.m[1][1], eps);
    try testing.expectApproxEqAbs(@as(f32, -1), r.m[1][2], eps); // -sin(90)
    try testing.expectApproxEqAbs(@as(f32, 1), r.m[2][1], eps); // sin(90)
}

test "Mat4.rotateZ 90 degrees maps +X to +Y" {
    const r = Mat4.rotateZ(90);
    // Rotating (1,0,0) by 90° around Z should give (0,1,0)
    // Result = r * [1,0,0,0] = column 0
    try testing.expectApproxEqAbs(@as(f32, 0), r.m[0][0], eps); // cos(90)
    try testing.expectApproxEqAbs(@as(f32, 1), r.m[0][1], eps); // sin(90)
}

test "Mat4.rotateZ 0 degrees is identity" {
    try expectMat4Approx(Mat4.rotateZ(0), Mat4.identity());
}

test "Mat4.perspective produces correct clip planes" {
    const p = Mat4.perspective(90, 1.0, 0.1, 100.0);
    // For 90° FOV with aspect 1: f = 1/tan(45°) = 1
    try testing.expectApproxEqAbs(@as(f32, 1), p.m[0][0], eps); // f/aspect
    try testing.expectApproxEqAbs(@as(f32, 1), p.m[1][1], eps); // f
    try testing.expectApproxEqAbs(@as(f32, -1), p.m[2][3], eps); // perspective divide
}

test "Mat4.mul is associative" {
    const a = Mat4.rotateX(30);
    const b = Mat4.rotateY(45);
    const c = Mat4.translate(1, 2, 3);
    const ab_c = Mat4.mul(Mat4.mul(a, b), c);
    const a_bc = Mat4.mul(a, Mat4.mul(b, c));
    try expectMat4Approx(ab_c, a_bc);
}
