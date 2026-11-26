//! What vcs-p4 shows, drawn from the panel's tables (`p4_status.zig`), writing nothing: the
//! changelists' page, `editor/assets/documents/vcs-p4.org`, laid out and drawn by the editor's
//! documents over what vcs-p4 publishes, its note saying why when there is no workspace, no
//! `p4` or no server; the history's page (`p4_history.zig`); or the runner's log view
//! (`process_log.zig`). The diff panel draws itself (`p4_diff.zig`).

const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const plugin = mesha.plugin;
const panels_mod = mesha.panels;
const roop = mesha.roop;
const sequencer = mesha.sequencer;
const ui = mesha.ui;
const runner = @import("runner.zig");
const vcs_page = @import("page.zig");
const process_log = @import("process_log.zig");
const model = @import("p4_status.zig");
const p4_history = @import("p4_history.zig");
const panel_frame = @import("../panel_frame.zig");
const editor_state = @import("../state.zig");
const style = @import("../ui/style.zig");
const document_view = @import("../document/view.zig");
const editor_sequencer = @import("../editor_sequencer.zig");

/// The panel's row as the draw reads it; null without it.
pub fn stateOf(tables: *Table.Registry) ?model.StateRead {
    const state_table = tables.findByName(Atom.from(model.state_table_name)) orelse return null;
    return state_table.getRow(.{ .row = 0, .generation = state_table.rowGeneration(0) }, model.StateRead);
}

/// How many elements the panel's tree has room for besides the page's.
const own_elements = 4;

/// Draws the panel: its header, with the spinner and the command that runs while a job of the
/// panel's runs, then the view it shows, scrolled as its kernels left it. `frame` is the panel's
/// frame in the window and `ctx` begins at its corner. Writes no table.
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
        .status => renderPage(scratch, tables, atoms, model.status_page, viewport, ctx),
        .history => renderPage(scratch, tables, atoms, p4_history.page, viewport, ctx),
        .process_log => renderProcessLog(scratch, tables, atoms, state, viewport, ctx),
    }
}

/// A page shown whole: the changelists' or the history's.
fn renderPage(scratch: memory_mod.Scratch, tables: *Table.Registry, atoms: *Atom.Registry, page: vcs_page.Page, viewport: plugin.Viewport, ctx: *roop.Context) void {
    const laid_out = vcs_page.laidOutIn(scratch.allocator, tables, atoms, page) catch return;
    const elements = document_view.elementCount(viewport.height, .{ .line_height = laid_out.line_height }) + own_elements;
    var tree = ui.Tree.init(scratch, atoms, elements) catch return;
    if (tree.beginRect("vcs_p4", .{ .axis = .vertical, .size = .{ .w = .fill, .h = .fill }, .bg = style.col.canvas, .clip_content = true })) {
        defer tree.endRect();
        vcs_page.record(&tree, tables, page, laid_out, sequencer.inboxOf(model.system()), scratch, viewport, ctx);
    }
    tree.commit(.{
        .root_size = .{ .x = viewport.width, .y = viewport.height },
        .offset = .{ .x = viewport.x, .y = viewport.y },
        .hovered = editor_state.hoveredElementId(tables),
        .depth = panels_mod.kPanelHitDepth,
    }, ctx, editor_state.hitRegions(tables, atoms), editor_sequencer.redrawInbox());
}

/// The runner's log view's lines.
fn renderProcessLog(scratch: memory_mod.Scratch, tables: *Table.Registry, atoms: *Atom.Registry, state: model.StateRead, viewport: plugin.Viewport, ctx: *roop.Context) void {
    const sources: process_log.Sources = .{
        .expanded = tables.findByName(Atom.from(model.expanded_table_name)) orelse return,
        .log = tables.findByName(Atom.from(runner.log_table_name)),
        .owner = sequencer.inboxOf(model.system()),
    };
    const tags: process_log.Tags = .{ .click = .from(model.Msg.vcs_p4_click), .chevron = .from(model.Msg.vcs_p4_chevron), .wheel = .from(model.Msg.vcs_p4_wheel) };
    process_log.render(scratch, tables, atoms, sources, state.cursor(), tags, "vcs_p4", viewport, ctx);
}

/// What the header adds after the title: while a job of the panel's runs, the spinner and the
/// command that runs.
fn renderHeader(tree: *ui.Tree, tables: *Table.Registry) void {
    const inbox = sequencer.inboxOf(model.system());
    if (!runner.busy(tables, inbox)) return;
    const state = stateOf(tables) orelse return;
    const spinner = runner.spinner(state.spinner.*);
    tree.rect("vcs_p4.header.space", .{ .size = .{ .w = .fill, .h = .fill } });
    tree.text("vcs_p4.header.spinner", spinner, .{ .font = style.ui_font, .color = style.col.accent_bright });
    tree.text("vcs_p4.header.running", runner.running(tables, inbox), .{ .font = style.ui_font, .color = style.col.text_dim });
}
