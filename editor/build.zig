const std = @import("std");

/// The editor plugin: the `editor` module, and `libeditor.so` built from it into this
/// directory's `zig-out`, as the host's watch and the root build's `plugins` step run it.
/// The editor builds on the SDK alone, the `mesha` module: its tests, which also drive the
/// runtime as the host does, are the root build's.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // As the root build's default: the self-hosted backend for a Debug build on x86_64 other
    // than Windows, LLVM otherwise. The host's watch always passes it.
    const self_hosted_target = target.result.os.tag != .windows and target.result.cpu.arch == .x86_64;
    const default_llvm = !self_hosted_target or optimize != .Debug;
    const use_llvm = b.option(bool, "llvm", "Build the plugin with the LLVM backend instead of the self-hosted x86_64 backend") orelse default_llvm;

    const enable_profile = b.option(bool, "profile-enabled", "Record profile zones") orelse true;
    const mesha_dep = b.dependency("mesha", .{ .target = target, .optimize = optimize, .@"profile-enabled" = enable_profile });

    const editor_mod = b.addModule("editor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const root_init_options = b.addOptions();
    root_init_options.addOption([]const u8, "fail_stage", b.option([]const u8, "root-init-fail-stage", "Test-only rejection after a real root preparation checkpoint (empty disables)") orelse "");
    editor_mod.addOptions("root_init_options", root_init_options);
    editor_mod.addImport("mesha", mesha_dep.module("mesha"));
    // The documents compiled into the editor (`@embedFile("vcs_git_document")`,
    // `@embedFile("vcs_git_log_document")`, `@embedFile("vcs_git_rebase_document")`, and vcs-p4's
    // `@embedFile("vcs_p4_document")` and `@embedFile("vcs_p4_history_document")`): an `.org` edited and saved rebuilds and reloads the
    // editor, which reads none at run time.
    editor_mod.addAnonymousImport("vcs_git_document", .{ .root_source_file = b.path("assets/documents/vcs-git.org") });
    editor_mod.addAnonymousImport("vcs_git_log_document", .{ .root_source_file = b.path("assets/documents/vcs-git-log.org") });
    editor_mod.addAnonymousImport("vcs_git_rebase_document", .{ .root_source_file = b.path("assets/documents/vcs-git-rebase.org") });
    editor_mod.addAnonymousImport("vcs_p4_document", .{ .root_source_file = b.path("assets/documents/vcs-p4.org") });
    editor_mod.addAnonymousImport("vcs_p4_history_document", .{ .root_source_file = b.path("assets/documents/vcs-p4-history.org") });

    const editor_lib = b.addLibrary(.{
        .name = "editor",
        .linkage = .dynamic,
        .root_module = editor_mod,
        .use_llvm = use_llvm,
    });
    b.installArtifact(editor_lib);
}
