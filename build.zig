const std = @import("std");
const CrossTarget = std.zig.CrossTarget;
const Step = std.build.Step;
const Build = std.build;

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.

pub const Raylib = struct {
    target: CrossTarget,
    optimize: std.builtin.Mode,
    b: *std.Build,

    pub fn artifact(self: Raylib) *Step.Compile {
        const raylib = self.b.dependency("raylib-zig", .{
            .target = self.target,
            .optimize = self.optimize,
        });
        return raylib.artifact("raylib");
    }

    pub fn module(self: Raylib) *Build.Module {
        const raylib = self.b.dependency("raylib-zig", .{
            .target = self.target,
            .optimize = self.optimize,
        });
        return raylib.module("raylib");
    }
};

pub const ExecutableOptions = struct {
    name: []const u8,
    main_path: []const u8,
    artifacts: []const *Step.Compile,
    description: []const u8,
    run: bool = false,
};

pub const Executable = struct {
    target: CrossTarget,
    optimize: std.builtin.Mode,
    b: *std.Build,

    pub fn register(self: Executable, options: ExecutableOptions) *Step.Compile {
        const exe = self.b.addExecutable(.{
            .name = options.name,
            .root_source_file = .{ .path = options.main_path },
            .target = self.target,
            .optimize = self.optimize,
        });

        for (options.artifacts) |artifact| {
            exe.linkLibrary(artifact);
        }

        const raylib = self.b.dependency("raylib", .{ .target = self.target, .optimize = self.optimize });
        const raylib_zig = self.b.dependency("raylib-zig", .{ .target = self.target, .optimize = self.optimize });

        exe.linkLibrary(raylib.artifact("raylib"));
        exe.addModule("raylib", raylib_zig.module("raylib"));
        exe.addModule("raylib-math", raylib_zig.module("raylib-math"));

        exe.linkLibC();

        self.b.installArtifact(exe);

        const run_cmd = self.b.addRunArtifact(exe);
        run_cmd.step.dependOn(self.b.getInstallStep());
        if (self.b.args) |args| {
            run_cmd.addArgs(args);
        }

        if (options.run) {
            const run_step = self.b.step(options.name, options.description);
            run_step.dependOn(&run_cmd.step);
        }

        return exe;
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const rl = Raylib{
        .target = target,
        .optimize = optimize,
        .b = b,
    };
    _ = rl;

    const executable = Executable{
        .target = target,
        .optimize = optimize,
        .b = b,
    };

    const server_only = b.option(bool, "server-only", "") orelse false;

    if (!server_only) {
        _ = executable.register(ExecutableOptions{
            .name = "run",
            .main_path = "src/main.zig",
            .artifacts = &[_]*Step.Compile{},
            .description = "Run the game and server",
            .run = true,
        });

        _ = executable.register(ExecutableOptions{
            .name = "game",
            .main_path = "src/game.zig",
            .artifacts = &[_]*Step.Compile{},
            .description = "Run the game",
        });
    }

    {
        const server = executable.register(ExecutableOptions{
            .name = "server",
            .main_path = "src/server.zig",
            .artifacts = &[_]*Step.Compile{},
            .description = "Run the server",
        });

        server.addIncludePath(.{ .path = "include" });
    }

    {
        const unit_tests = b.addTest(.{
            .root_source_file = .{ .path = "src/main.zig" },
            .target = target,
            .optimize = optimize,
        });

        const raylib = b.dependency("raylib", .{ .target = target, .optimize = optimize });
        const raylib_zig = b.dependency("raylib-zig", .{ .target = target, .optimize = optimize });

        unit_tests.linkLibrary(raylib.artifact("raylib"));
        unit_tests.addModule("raylib", raylib_zig.module("raylib"));

        unit_tests.linkLibC();

        const run_unit_tests = b.addRunArtifact(unit_tests);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_unit_tests.step);
    }
}
