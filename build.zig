const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const entt = b.dependency("entt", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "lunatic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zig-ecs", .module = entt.module("zig-ecs") },
            },
        }),
    });

    // SDL3
    exe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    exe.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    exe.linkSystemLibrary("SDL3");

    // LuaJIT (installs as libluajit-5.1)
    exe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/luajit-2.1" });
    exe.linkSystemLibrary("luajit-5.1");

    b.installArtifact(exe);

    // Run step: `zig build run`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.setCwd(b.path("."));
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the engine");
    run_step.dependOn(&run_cmd.step);

    // Test step: `zig build test`
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zig-ecs", .module = entt.module("zig-ecs") },
            },
        }),
    });

    tests.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    tests.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    tests.linkSystemLibrary("SDL3");
    tests.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/luajit-2.1" });
    tests.linkSystemLibrary("luajit-5.1");

    // Also run math3d unit tests
    const math_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/math3d.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const run_math_tests = b.addRunArtifact(math_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_math_tests.step);
}
