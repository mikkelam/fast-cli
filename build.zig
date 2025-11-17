const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_zli = b.dependency("zli", .{ .target = target });
    const dep_mvzr = b.dependency("mvzr", .{ .target = target, .optimize = optimize });

    const build_options = b.addOptions();
    const build_zon_content = @embedFile("build.zig.zon");
    const version = blk: {
        const start = std.mem.indexOf(u8, build_zon_content, ".version = \"") orelse unreachable;
        const version_start = start + ".version = \"".len;
        const end = std.mem.indexOfPos(u8, build_zon_content, version_start, "\"") orelse unreachable;
        break :blk build_zon_content[version_start..end];
    };
    build_options.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = "fast-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("zli", dep_zli.module("zli"));
    exe.root_module.addImport("mvzr", dep_mvzr.module("mvzr"));
    exe.root_module.addImport("build_options", build_options.createModule());

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("mvzr", dep_mvzr.module("mvzr"));

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
