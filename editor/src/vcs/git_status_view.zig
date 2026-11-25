//! What vcs-git shows, built anew from the panel's tables (`git_status.zig`), and the panel's
//! drawing, which writes nothing. The status is a page, `editor/assets/documents/vcs-git.org`,
//! laid out and drawn by the editor's documents (`editor/src/document/`) over the tables and
//! values vcs-git publishes; a working directory in no repository, or a git that is not there,
//! is one line in its place. The log view is a page too, `editor/assets/documents/vcs-git-log.org`
//! (`git_log.page`): the query and a table of what git answered; so is the rebase list,
//! `editor/assets/documents/vcs-git-rebase.org` (`git_rebase.page`); a file's or a commit's
//! changes are the diff panel's (`git_diff.zig`).
//!
//! The runner's log view (`$`) is a list of lines, `process_log.zig`'s.

const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const plugin = mesha.plugin;
const panels_mod = mesha.panels;
const roop = mesha.roop;
const sequencer = mesha.sequencer;
const ui = mesha.ui;
const outline = mesha.ui.outline;
const runner = @import("runner.zig");
const vcs_page = @import("page.zig");
const process_log = @import("process_log.zig");
const model = @import("git_status.zig");
const git_log = @import("git_log.zig");
const git_rebase = @import("git_rebase.zig");
const open = @import("../open.zig");
const panel_frame = @import("../panel_frame.zig");
const editor_state = @import("../state.zig");
const style = @import("../ui/style.zig");
const document = @import("../document/document.zig");
const document_view = @import("../document/view.zig");

/// The panel's row as the draw reads it; null without it.
pub fn stateOf(tables: *Table.Registry) ?model.StateRead {
    const state_table = tables.findByName(Atom.from(model.state_table_name)) orelse return null;
    return state_table.getRow(.{ .row = 0, .generation = state_table.rowGeneration(0) }, model.StateRead);
}

/// What the status says in place of its page, in `allocator`: that the working directory is in
/// no repository (named from the home directory when under it), or that git is not there; null
/// while it shows its page.
pub fn noticeText(allocator: std.mem.Allocator, state: model.StateRead) !?[]const u8 {
    const notice: model.Notice = std.enums.fromInt(model.Notice, state.notice.*) orelse .none;
    switch (notice) {
        .none => return null,
        .git_missing => return "git was not found on PATH",
        .not_repository => {
            const from_home = try open.shownFromHome(allocator, state.working_directory, state.home_directory);
            const directory = try ui.displayText(allocator, from_home);
            return try std.fmt.allocPrint(allocator, "Not a git repository: {s}", .{directory});
        },
    }
}

// ---- drawing -----------------------------------------------------------------------------------

/// How many elements the panel's tree has room for besides the page's or the list's.
const own_elements = 4;

/// Draws the panel: its header, with the spinner and the command that runs while a job of the
/// panel's runs, then the view it shows, scrolled as its kernels left it: the status's page, the
/// runner's log's lines, the log's page or the rebase list's. `frame` is the panel's frame in the window and `ctx`
/// begins at its corner. Writes no table.
pub fn render(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, frame: plugin.Viewport, ctx: *roop.Context) void {
    var header: panel_frame.Header = undefined;
    if (header.begin(memory, tables, atoms, model.panel)) {
        if (header.open) renderHeader(&header.tree, tables);
        header.finish(tables, atoms, frame, ctx);
    }
    const viewport = panel_frame.beginContent(tables, atoms, model.panel, frame, ctx) orelse return;
    defer panel_frame.endContent(ctx);
    const scratch = memory.frameScratchAllocator() catch return;
    const state = stateOf(tables) orelse return;
    switch (model.viewOf(state.view.*)) {
        .log => renderPage(scratch, tables, atoms, git_log.page, viewport, ctx),
        .rebase => renderPage(scratch, tables, atoms, git_rebase.page, viewport, ctx),
        .process_log => renderProcessLog(scratch, tables, atoms, state, viewport, ctx),
        .status => renderStatus(scratch, tables, atoms, state, viewport, ctx),
    }
}

/// The status: its page, or the line said in its place, or nothing before git first answered.
fn renderStatus(scratch: memory_mod.Scratch, tables: *Table.Registry, atoms: *Atom.Registry, state: model.StateRead, viewport: plugin.Viewport, ctx: *roop.Context) void {
    const allocator = scratch.allocator;
    const notice = noticeText(allocator, state) catch return;
    const page = model.status_page;
    const laid_out = vcs_page.laidOutIn(allocator, tables, atoms, page) catch return;
    const elements = document_view.elementCount(viewport.height, .{ .line_height = laid_out.line_height }) + own_elements;
    var tree = ui.Tree.init(scratch, atoms, elements) catch return;
    if (tree.beginRect("vcs_git", .{ .axis = .vertical, .size = .{ .w = .fill, .h = .fill }, .bg = style.col.canvas, .clip_content = true })) {
        defer tree.endRect();
        if (notice) |said| {
            noticeLine(&tree, said, laid_out.line_height);
        } else if (state.answered.* != 0) {
            vcs_page.record(&tree, tables, page, laid_out, sequencer.inboxOf(model.system()), scratch, viewport, ctx);
        }
    }
    commitTree(&tree, tables, atoms, viewport, ctx);
}

/// A page shown whole: the log's, its query and the table of what git answered, or the rebase
/// list's.
fn renderPage(scratch: memory_mod.Scratch, tables: *Table.Registry, atoms: *Atom.Registry, page: vcs_page.Page, viewport: plugin.Viewport, ctx: *roop.Context) void {
    const laid_out = vcs_page.laidOutIn(scratch.allocator, tables, atoms, page) catch return;
    const elements = document_view.elementCount(viewport.height, .{ .line_height = laid_out.line_height }) + own_elements;
    var tree = ui.Tree.init(scratch, atoms, elements) catch return;
    if (tree.beginRect("vcs_git", .{ .axis = .vertical, .size = .{ .w = .fill, .h = .fill }, .bg = style.col.canvas, .clip_content = true })) {
        defer tree.endRect();
        vcs_page.record(&tree, tables, page, laid_out, sequencer.inboxOf(model.system()), scratch, viewport, ctx);
    }
    commitTree(&tree, tables, atoms, viewport, ctx);
}

/// The line said in place of the page, dimmed.
fn noticeLine(tree: *ui.Tree, said: []const u8, line_height: f32) void {
    if (!tree.beginRect("vcs_git.notice", .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .fill, .h = .{ .fixed = line_height } }, .padding = 8 })) return;
    defer tree.endRect();
    tree.text("vcs_git.notice.text", said, .{ .font = style.outlineStyle().text_font, .color = style.col.text_dim });
}

/// The runner's log view's lines, as an outline.
fn renderProcessLog(scratch: memory_mod.Scratch, tables: *Table.Registry, atoms: *Atom.Registry, state: model.StateRead, viewport: plugin.Viewport, ctx: *roop.Context) void {
    const sources: process_log.Sources = .{
        .expanded = tables.findByName(Atom.from(model.expanded_table_name)) orelse return,
        .log = tables.findByName(Atom.from(runner.log_table_name)),
        .owner = sequencer.inboxOf(model.system()),
    };
    const tags: process_log.Tags = .{ .click = .from(model.Msg.vcs_git_click), .chevron = .from(model.Msg.vcs_git_chevron), .wheel = .from(model.Msg.vcs_git_wheel) };
    process_log.render(scratch, tables, atoms, sources, state.cursor(), tags, "vcs_git", viewport, ctx);
}

fn commitTree(tree: *ui.Tree, tables: *Table.Registry, atoms: *Atom.Registry, viewport: plugin.Viewport, ctx: *roop.Context) void {
    tree.commit(.{
        .root_size = .{ .x = viewport.width, .y = viewport.height },
        .offset = .{ .x = viewport.x, .y = viewport.y },
        .hovered = editor_state.hoveredElementId(tables),
        .depth = panels_mod.kPanelHitDepth,
    }, ctx, editor_state.hitRegions(tables, atoms));
}

/// What the header adds after the title: while a job of the panel's runs, at its right, the
/// spinner as the panel's kernel last turned it and the command that runs, cut where the header
/// ends.
fn renderHeader(tree: *ui.Tree, tables: *Table.Registry) void {
    const inbox = sequencer.inboxOf(model.system());
    if (!runner.busy(tables, inbox)) return;
    const state = stateOf(tables) orelse return;
    const spinner = runner.spinner(state.phase.*);
    tree.rect("vcs_git.header.space", .{ .size = .{ .w = .fill, .h = .fill } });
    tree.text("vcs_git.header.spinner", spinner, .{ .font = style.ui_font, .color = style.col.accent_bright });
    tree.text("vcs_git.header.running", runner.running(tables, inbox), .{ .font = style.ui_font, .color = style.col.text_dim });
}
