const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // // library tests
    // const library_tests = b.addTest(.{
    //     .root_source_file = b.path("src/test.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const run_library_tests = b.addRunArtifact(library_tests);

    // const test_step = b.step("test", "Run all tests");
    // test_step.dependOn(&run_library_tests.step);

    const dep_zli = b.dependency("zli", .{
        .target = target,
    });
    const mod_zli = dep_zli.module("zli");

    const dep_mvzr = b.dependency("mvzr", .{
        .target = target,
        .optimize = optimize,
    });
    const mod_mvzr = dep_mvzr.module("mvzr");

    // Create build options for version info
    const build_options = b.addOptions();

    // Read version from build.zig.zon at compile time
    const build_zon_content = @embedFile("build.zig.zon");
    const version = blk: {
        // Simple parsing to extract version string
        const start = std.mem.indexOf(u8, build_zon_content, ".version = \"") orelse unreachable;
        const version_start = start + ".version = \"".len;
        const end = std.mem.indexOfPos(u8, build_zon_content, version_start, "\"") orelse unreachable;
        break :blk build_zon_content[version_start..end];
    };

    build_options.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = "fast-cli",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("zli", mod_zli);
    exe.root_module.addImport("mvzr", mod_mvzr);
    exe.root_module.addImport("build_options", build_options.createModule());
    // library_tests.root_module.addImport("mvzr", mod_mvzr);

    // Link against the static library instead

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // b.default_step.dependOn(test_step); // Disabled for cross-compilation
}
