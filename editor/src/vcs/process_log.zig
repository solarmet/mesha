//! The runner's log as a version-control panel shows it (`$`), and the measures of a panel
//! drawn as a list of lines (`mesha.ui.outline`), which the diff panels share. The log view is
//! each job of the panel's that the runner logged (`runner.log_table_name`), oldest first, `$`
//! and its command line with how it ended, which opens to what it said and its errors. A line's
//! key names it across runs: a job's is its place in the log's. A job is folded unless opened,
//! the keys opened kept in a table of the owner's (`FoldRow`).
//!
//! A kernel moves the view's cursor through a `View` over the owner's cells; the draw builds the
//! same lines (`build`) and records them (`render`), writing nothing.

const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const plugin = mesha.plugin;
const panels_mod = mesha.panels;
const resources = mesha.resources;
const roop = mesha.roop;
const sequencer = mesha.sequencer;
const ui = mesha.ui;
const outline = mesha.ui.outline;
const panel_frame = @import("../panel_frame.zig");
const editor_state = @import("../state.zig");
const style = @import("../ui/style.zig");

// ---- measures --------------------------------------------------------------------------------------

/// A list's measures: how tall a line is and how wide and tall the view of the list, in
/// pixels.
pub const Layout = struct {
    line_height: f32,
    view_width: f32 = 0,
    view_height: f32,

    /// How many whole lines the view holds, at least one: what a page moves.
    pub fn pageLines(layout: Layout) u32 {
        if (layout.line_height <= 0) return 1;
        const whole = @floor(layout.view_height / layout.line_height);
        return @max(@as(u32, @intFromFloat(@max(whole, 0))), 1);
    }
};

/// Space between lines, in pixels, beside the taller of the two fonts.
const line_spacing: f32 = 6;
/// The height of a line before its fonts are loaded.
const fallback_line_height: f32 = 21;

/// How many lines a notch of the wheel scrolls, in any list.
pub const wheel_lines: f32 = 3;

const font_metrics_table = Atom.from(resources.font_metrics_table_name);
const panel_state_table = Atom.from(panels_mod.state_table_name);

/// The height of a list's lines, from the fonts' metrics in `metrics`, the table
/// `resources_font_metrics`, or `fallback_line_height` while they are not loaded.
pub fn lineHeight(metrics: ?*Table) f32 {
    const found = metrics orelse return fallback_line_height;
    const outline_style = style.outlineStyle();
    const text_font = resources.fontMetrics(found, resources.kApplicationScope, outline_style.text_font) orelse return fallback_line_height;
    const code_font = resources.fontMetrics(found, resources.kApplicationScope, outline_style.code_font) orelse return fallback_line_height;
    const tallest = @max(text_font.pixel_height, code_font.pixel_height);
    return @round(tallest + line_spacing);
}

/// The measures of the list of `panel_id` as laid out now: zero while it is not open.
pub fn layoutOf(pass: *const sequencer.Pass, panel_id: Atom) Layout {
    const metrics: ?*Table = if (pass.declares(font_metrics_table)) pass.table(font_metrics_table) catch null else null;
    const line_height = lineHeight(metrics);
    if (!pass.declares(panel_state_table)) return .{ .line_height = line_height, .view_height = 0 };
    const content = panel_frame.contentRect(pass.frame.tables, pass.frame.atoms, panel_id) orelse return .{ .line_height = line_height, .view_height = 0 };
    return .{ .line_height = line_height, .view_width = content.w, .view_height = content.h };
}

// ---- folds -----------------------------------------------------------------------------------------

/// A row of a table of a list's keys: the jobs opened, or a diff panel's lines turned from how
/// they show by default.
pub const FoldRow = struct { key: *u64 };

/// The row of `folds`, a table of `FoldRow`s, that holds `key`; null for none.
pub fn findFold(folds: *Table, key: u64) ?Table.RowHandle {
    var rows = folds.readQuery(FoldRow);
    while (rows.next()) |row| {
        if (row.view.key.* == key) return row.handle;
    }
    return null;
}

/// The keys `folds`, a table of `FoldRow`s, holds, sorted, in `allocator`.
pub fn sortedKeys(allocator: std.mem.Allocator, folds: *Table) ![]u64 {
    const keys = try allocator.alloc(u64, folds.count());
    var count: usize = 0;
    var rows = folds.readQuery(FoldRow);
    while (rows.next()) |row| {
        if (count == keys.len) break;
        keys[count] = row.view.key.*;
        count += 1;
    }
    std.mem.sort(u64, keys[0..count], {}, std.sort.asc(u64));
    return keys[0..count];
}

/// Whether `sorted`, as `sortedKeys` gives them, holds `key`.
pub fn holds(sorted: []const u64, key: u64) bool {
    return std.sort.binarySearch(u64, sorted, key, orderKeys) != null;
}

fn orderKeys(key: u64, item: u64) std.math.Order {
    return std.math.order(key, item);
}

// ---- the lines -------------------------------------------------------------------------------------

/// What a line of the log view is, as `outline.Line.kind` keeps it.
pub const LineKind = enum(u8) {
    /// What the view says in place of jobs: none ran yet.
    notice,
    /// A job.
    job,
    /// A line a job wrote to its output.
    job_said,
    /// A line a job wrote to its errors.
    job_error,
};

/// What the log view's lines are built from, as a kernel's run or the draw reads the tables.
pub const Sources = struct {
    /// The jobs opened, the owner's table of `FoldRow`s.
    expanded: *Table,
    /// The runner's `editor_vcs_log`; null without it.
    log: ?*Table,
    /// The owner's inbox, which names its jobs in the log.
    owner: Atom,
};

/// The lines of the log view and the keys of those folded, as `outline.visible` and
/// `outline.record` take them. All in the allocator `build` was given; the text is it or the
/// tables', good for the frame.
pub const Built = struct {
    lines: []outline.Line,
    collapsed: []u64,
};

/// The log view's lines, in `allocator`, which is an arena's.
pub fn build(allocator: std.mem.Allocator, sources: Sources) !Built {
    var list: LineList = .{ .allocator = allocator };
    try logLines(&list, sources);
    const lines = list.lines.items;
    const collapsed = try foldedKeys(allocator, lines, sources.expanded);
    return .{ .lines = lines, .collapsed = collapsed };
}

/// Lines as they are built.
const LineList = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList(outline.Line) = .empty,

    fn add(list: *LineList, line: outline.Line) !void {
        try list.lines.append(list.allocator, line);
    }

    /// A line of `kind` at the top, of one colour.
    fn plain(list: *LineList, kind: LineKind, text: []const u8, colour: ui.Color) !void {
        const key = keyOf(kind, "");
        try list.add(.{ .depth = 0, .kind = @intFromEnum(kind), .key = key, .text = text, .colour = colour });
    }
};

/// A line's key: its kind, and the bytes that name it among them. Never 0.
fn keyOf(kind: LineKind, text: []const u8) u64 {
    const key = std.hash.Wyhash.hash(@as(u64, @intFromEnum(kind)) << 8, text);
    return if (key == 0) 1 else key;
}

/// A job of the log, as its row says.
const Logged = struct {
    sequence: u32,
    shown: []const u8,
    outcome: []const u8,
    said: []const u8,
    errors: []const u8,
    said_cut: bool,
    errors_cut: bool,

    fn before(_: void, a: Logged, b: Logged) bool {
        return a.sequence < b.sequence;
    }
};

const LogView = struct {
    sequence: *u32,
    owner: *Atom,
    shown: []const u8,
    outcome: []const u8,
    said: []const u8,
    errors: []const u8,
    said_cut: *u8,
    errors_cut: *u8,
};

fn logLines(list: *LineList, sources: Sources) !void {
    const allocator = list.allocator;
    const log = sources.log orelse return list.plain(.notice, "No command has run yet", style.col.text_dim);
    const logged = try allocator.alloc(Logged, log.count());
    var count: usize = 0;
    var rows = log.readQuery(LogView);
    while (rows.next()) |row| {
        const found = row.view;
        if (found.owner.* != sources.owner or count == logged.len) continue;
        logged[count] = .{
            .sequence = found.sequence.*,
            .shown = found.shown,
            .outcome = found.outcome,
            .said = found.said,
            .errors = found.errors,
            .said_cut = found.said_cut.* != 0,
            .errors_cut = found.errors_cut.* != 0,
        };
        count += 1;
    }
    if (count == 0) return list.plain(.notice, "No command has run yet", style.col.text_dim);
    const jobs = logged[0..count];
    std.mem.sort(Logged, jobs, {}, Logged.before);
    const opened = try sortedKeys(allocator, sources.expanded);
    for (jobs) |job| {
        const key = keyOf(.job, std.mem.asBytes(&job.sequence));
        const text = try std.fmt.allocPrint(allocator, "$ {s}", .{try ui.displayText(allocator, job.shown)});
        const line: outline.Line = .{ .depth = 0, .kind = @intFromEnum(LineKind.job), .key = key, .text = text, .detail = job.outcome, .colour = style.col.text, .expandable = true };
        try list.add(line);
        if (!holds(opened, key)) continue;
        var said_count: u32 = 0;
        try outputLines(list, job, .job_said, job.said, job.said_cut, &said_count);
        try outputLines(list, job, .job_error, job.errors, job.errors_cut, &said_count);
        if (said_count == 0) {
            const quiet_key = keyOf(.job_said, std.mem.asBytes(&[2]u32{ job.sequence, 0 }));
            try list.add(.{ .depth = 1, .kind = @intFromEnum(LineKind.job_said), .key = quiet_key, .text = "(said nothing)", .colour = style.col.text_dim });
        }
    }
}

/// The lines of what a job wrote to one stream, under its line, each a line of the log: a NUL,
/// which git separates records by, ends a line as a line break does.
fn outputLines(list: *LineList, job: Logged, kind: LineKind, bytes: []const u8, cut: bool, count: *u32) !void {
    const allocator = list.allocator;
    const colour = if (kind == .job_error) style.col.danger else style.col.text;
    const shown = try ui.displayText(allocator, bytes);
    const trimmed = std.mem.trimEnd(u8, shown, "\n\x00");
    if (trimmed.len == 0) return;
    var parts = std.mem.tokenizeAny(u8, trimmed, "\n\x00");
    while (parts.next()) |part| {
        count.* += 1;
        const key = keyOf(kind, std.mem.asBytes(&[2]u32{ job.sequence, count.* }));
        const text = std.mem.trimEnd(u8, part, "\r");
        try list.add(.{ .depth = 1, .kind = @intFromEnum(kind), .key = key, .text = text, .colour = colour, .font = .code });
    }
    if (!cut) return;
    count.* += 1;
    const key = keyOf(kind, std.mem.asBytes(&[2]u32{ job.sequence, count.* }));
    try list.add(.{ .depth = 1, .kind = @intFromEnum(kind), .key = key, .text = "(cut: the log keeps the first 64 KiB)", .colour = style.col.text_dim });
}

/// The keys of the jobs of `lines` that are folded: those `expanded` does not hold.
fn foldedKeys(allocator: std.mem.Allocator, lines: []const outline.Line, expanded: *Table) ![]u64 {
    const opened = try sortedKeys(allocator, expanded);
    var keys: std.ArrayList(u64) = .empty;
    for (lines) |line| {
        if (!line.expandable) continue;
        if (!holds(opened, line.key)) try keys.append(allocator, line.key);
    }
    return keys.items;
}

// ---- in a kernel -------------------------------------------------------------------------------

/// The log view's cursor, in cells of its owner's row.
pub const Cursor = struct {
    key: *u64,
    index: *u32,
    scroll: *f32,

    fn read(cursor: Cursor) outline.Cursor {
        return .{ .key = cursor.key.*, .index = cursor.index.*, .scroll = cursor.scroll.* };
    }

    fn write(cursor: Cursor, value: outline.Cursor) void {
        cursor.key.* = value.key;
        cursor.index.* = value.index;
        cursor.scroll.* = value.scroll;
    }
};

/// The log view as a kernel's run moves through it: its lines from `sources`, its cursor in
/// the owner's cells, its measures `panel`'s.
pub const View = struct {
    pass: *sequencer.Pass,
    sources: Sources,
    cursor: Cursor,
    /// The owner's panel, whose size the view is.
    panel: Atom,

    fn scratch(log_view: View) !std.mem.Allocator {
        const frame_scratch = try log_view.pass.frame.memory.frameScratchAllocator();
        return frame_scratch.allocator;
    }

    /// The lines and those shown, as the draw builds them.
    fn shownLines(log_view: View) !struct { built: Built, shown: []u32 } {
        const allocator = try log_view.scratch();
        const built = try build(allocator, log_view.sources);
        const out = try allocator.alloc(u32, built.lines.len);
        const shown = outline.visible(built.lines, built.collapsed, out);
        return .{ .built = built, .shown = shown };
    }

    /// The cursor on the newest job, the view scrolled to it: as `$` shows the view.
    pub fn showNewest(log_view: View) !void {
        const lines = try log_view.shownLines();
        const layout = layoutOf(log_view.pass, log_view.panel);
        var newest = outline.move(lines.built.lines, lines.shown, log_view.cursor.read(), .last, layout.pageLines());
        newest.scroll = outline.scrollTo(lines.shown, newest, layout.line_height, layout.view_height);
        log_view.cursor.write(newest);
    }

    /// The cursor settled against the lines as they are, and the view scrolled to show it.
    pub fn settle(log_view: View) !void {
        const lines = try log_view.shownLines();
        const layout = layoutOf(log_view.pass, log_view.panel);
        var settled = outline.settle(lines.built.lines, lines.shown, log_view.cursor.read());
        settled.scroll = outline.scrollTo(lines.shown, settled, layout.line_height, layout.view_height);
        log_view.cursor.write(settled);
    }

    /// The cursor moved `step`.
    pub fn move(log_view: View, step: outline.Step) !void {
        const lines = try log_view.shownLines();
        const layout = layoutOf(log_view.pass, log_view.panel);
        const moved = outline.move(lines.built.lines, lines.shown, log_view.cursor.read(), step, layout.pageLines());
        log_view.cursor.write(moved);
    }

    /// A click on the line `key`: the cursor goes there.
    pub fn putCursorOn(log_view: View, key: u64) !void {
        const lines = try log_view.shownLines();
        for (lines.shown, 0..) |line_index, position| {
            if (lines.built.lines[line_index].key != key) continue;
            var placed = log_view.cursor.read();
            placed.key = key;
            placed.index = @intCast(position);
            log_view.cursor.write(placed);
            return;
        }
    }

    /// The wheel moved `notches` (up positive): the view scrolls three lines a notch, and the
    /// cursor follows into it.
    pub fn wheel(log_view: View, notches: f32) !void {
        const lines = try log_view.shownLines();
        const layout = layoutOf(log_view.pass, log_view.panel);
        var scrolled = outline.settle(lines.built.lines, lines.shown, log_view.cursor.read());
        const wanted = scrolled.scroll - notches * wheel_lines * layout.line_height;
        scrolled.scroll = outline.clampScroll(lines.shown, wanted, layout.line_height, layout.view_height);
        const followed = outline.cursorInView(lines.built.lines, lines.shown, scrolled, layout.line_height, layout.view_height);
        log_view.cursor.write(followed);
    }

    /// `tab`: opens or folds the job the cursor is on, or the one its line is under.
    pub fn toggleAtCursor(log_view: View) !void {
        const lines = try log_view.shownLines();
        if (lines.shown.len == 0) return;
        const settled = outline.settle(lines.built.lines, lines.shown, log_view.cursor.read());
        var line_index = lines.shown[settled.index];
        while (!lines.built.lines[line_index].expandable) {
            line_index = outline.parentOf(lines.built.lines, line_index) orelse return;
        }
        try log_view.toggleKey(lines.built.lines[line_index].key);
    }

    /// A chevron's click, or `tab`: opens or folds the job `key`.
    pub fn toggleKey(log_view: View, key: u64) !void {
        const expanded = log_view.sources.expanded;
        if (findFold(expanded, key)) |handle| {
            expanded.free(handle);
            return;
        }
        if (expanded.count() >= expanded.rowCapacity()) return;
        _ = try expanded.tryInsert(.{ .key = key });
    }

    /// `S-tab`: opens every job, or, while any is open, folds them all.
    pub fn toggleAll(log_view: View) !void {
        const expanded = log_view.sources.expanded;
        const lines = try log_view.shownLines();
        var any_open = false;
        for (lines.built.lines) |line| {
            if (!line.expandable) continue;
            if (findFold(expanded, line.key) != null) any_open = true;
        }
        for (lines.built.lines) |line| {
            if (!line.expandable) continue;
            const found = findFold(expanded, line.key);
            if (any_open) {
                if (found) |handle| expanded.free(handle);
                continue;
            }
            if (found != null or expanded.count() >= expanded.rowCapacity()) continue;
            _ = try expanded.tryInsert(.{ .key = line.key });
        }
    }
};

// ---- drawing -----------------------------------------------------------------------------------

/// The tags the log view's draw sends its messages with, its owner's.
pub const Tags = struct {
    /// A click on a line, its key (`u64`) the user data.
    click: Atom,
    /// A click on a line's chevron, its key the user data.
    chevron: Atom,
    /// The wheel over the view, an `input.MouseScrollMsg`.
    wheel: Atom,
};

/// The log view's lines recorded over `viewport`, its cursor `cursor` as the owner's kernels
/// left it, its messages going to `sources.owner` as `tags`; `name` names its root element.
/// Writes no table.
pub fn render(scratch: memory_mod.Scratch, tables: *Table.Registry, atoms: *Atom.Registry, sources: Sources, cursor: outline.Cursor, tags: Tags, name: []const u8, viewport: plugin.Viewport, ctx: *roop.Context) void {
    const allocator = scratch.allocator;
    const built = build(allocator, sources) catch return;
    const out = allocator.alloc(u32, built.lines.len) catch return;
    const shown = outline.visible(built.lines, built.collapsed, out);
    const settled = outline.settle(built.lines, shown, cursor);
    const line_height = lineHeight(tables.findByName(font_metrics_table));
    const view_lines: u32 = @intFromFloat(@ceil(@max(viewport.height, 0) / line_height));
    var tree = ui.Tree.init(scratch, atoms, outline.elementCount(view_lines) + 2) catch return;
    if (tree.beginRect(name, .{ .axis = .vertical, .size = .{ .w = .fill, .h = .fill }, .bg = style.col.canvas, .clip_content = true })) {
        defer tree.endRect();
        outline.record(&tree, built.lines, shown, settled, .{
            .inbox = sources.owner,
            .click_tag = tags.click,
            .toggle_tag = tags.chevron,
            .scroll_tag = tags.wheel,
            .collapsed = built.collapsed,
            .view_height = viewport.height,
            .line_height = line_height,
            .style = style.outlineStyle(),
        });
    }
    tree.commit(.{
        .root_size = .{ .x = viewport.width, .y = viewport.height },
        .offset = .{ .x = viewport.x, .y = viewport.y },
        .hovered = editor_state.hoveredElementId(tables),
        .depth = panels_mod.kPanelHitDepth,
    }, ctx, editor_state.hitRegions(tables, atoms));
}
