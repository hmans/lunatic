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
