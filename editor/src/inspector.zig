//! The widgets the editor opens as panels, and the actions that arrange panels. The host owns
//! every panel's header and the dividers between them. `perf` and `memory` are charts; any
//! other widget is a table window.
const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const Atom = mesha.Atom;
const Table = mesha.Table;
const plugin = mesha.plugin;
const panels_mod = mesha.panels;
const panel_frame = @import("panel_frame.zig");
const roop = mesha.roop;
const math = mesha.math;
const memory_mod = mesha.memory;
const tracker = mesha.tracker;
const time = mesha.time;
const action_palette = @import("action_palette.zig");
const windows = @import("windows.zig");
const style = @import("ui/style.zig");
const vsync = @import("ui/vsync.zig");
const state = @import("state.zig");
const workspaces = @import("workspaces.zig");
const sequencer = mesha.sequencer;

/// The inspector's root, its table windows' too: their panels draw again when its systems
/// change a table.
pub const inspector_root = Atom.from("inspector");
pub const widget_owner = Atom.from("editor.inspector.add_widget");
const widget_reply_tag = Atom.from("inspector_widget_reply");
const perf_widget = "perf";
const memory_widget = "memory";
const perf_title = "Frame times";
const memory_title = "Memory by system";
const frame_tracker = "tracker_frame";
const memory_table = "memory";
const process_memory_table = "process_memory";
const kMaxMemoryBars: usize = 16;

pub const actions = [_]plugin.action_api.Def{
    .{ .name = "inspector_add_widget", .tag = "inspector_add_widget", .doc = "Open a widget panel beside the focused panel" },
    .{ .name = "focus_next_view", .tag = "focus_next_view", .doc = "Focus the next panel" },
    .{ .name = "maximize_toggle", .tag = "maximize_toggle", .doc = "Fill the window with the focused panel, or restore the arrangement" },
    .{ .name = "panel_dock_left", .tag = "panel_dock_left", .doc = "Dock the focused panel along the window's left edge" },
    .{ .name = "panel_dock_right", .tag = "panel_dock_right", .doc = "Dock the focused panel along the window's right edge" },
    .{ .name = "panel_dock_top", .tag = "panel_dock_top", .doc = "Dock the focused panel along the window's top edge" },
    .{ .name = "panel_dock_bottom", .tag = "panel_dock_bottom", .doc = "Dock the focused panel along the window's bottom edge" },
};

/// The keys of `actions`, of the mode `global`.
pub const global_keys = [_]mesha.keybinds.KeyDef{
    .{ .chord = "C-x 1", .action = .{ "global", "maximize_toggle" } },
    .{ .chord = "C-tab", .action = .{ "global", "focus_next_view" } },
    .{ .chord = "f11", .action = .{ "global", "maximize_toggle" } },
    .{ .chord = "C-backslash", .action = .{ "global", "inspector_add_widget" } },
};

const dock_actions = [_]struct { name: []const u8, side: panels_mod.Side }{
    .{ .name = "panel_dock_left", .side = .left },
    .{ .name = "panel_dock_right", .side = .right },
    .{ .name = "panel_dock_top", .side = .top },
    .{ .name = "panel_dock_bottom", .side = .bottom },
};

/// Where a widget opens: beside the panel that asked for it, taking a third of the space.
fn widgetPanel(id: Atom, title: []const u8) plugin.panels.Open {
    return .{ .id = id, .title = title, .root = inspector_root, .side = .right, .share = 0.34 };
}

/// The frame times widget's panel, a fixed panel the workspaces system declares while it is
/// shown.
pub const perf_panel = widgetPanel(Atom.from(perf_widget), perf_title);
/// The memory widget's panel, likewise.
pub const memory_panel = widgetPanel(Atom.from(memory_widget), memory_title);

const WidgetChoice = enum(u8) { perf, memory, table };

/// Widgets this file draws, which exist without a table window behind them.
pub fn isBuiltinWidget(atoms: *Atom.Registry, id: Atom) bool {
    return id == atoms.intern(perf_widget) or id == atoms.intern(memory_widget);
}

fn queueAddWidgetPrompt(memory: *memory_mod.Memory, tables: *Table.Registry) void {
    const allocator = action_palette.completionAllocator(memory, .widget) catch return;
    action_palette.resetCompletionArena(memory, .widget);
    const completions = allocator.create(action_palette.Completions) catch return;
    const choices = [_]struct { label: []const u8, detail: []const u8, choice: WidgetChoice }{
        .{ .label = perf_title, .detail = perf_widget, .choice = .perf },
        .{ .label = memory_title, .detail = memory_widget, .choice = .memory },
        .{ .label = "Table...", .detail = "Pick a table", .choice = .table },
    };
    const entries = allocator.alloc(action_palette.Completion, choices.len) catch return;
    for (choices, entries) |choice, *entry| {
        var data = std.mem.zeroes([action_palette.kCompletionDataSize]u8);
        data[0] = @intFromEnum(choice.choice);
        entry.* = .{ .label = choice.label, .detail = choice.detail, .data = data };
    }
    completions.* = .{
        .owner = widget_owner,
        .presentation = .prompt,
        .title = "Add inspector widget",
        // The choices are what to add, not names to type.
        .tab = .nothing,
        .entries = entries,
    };
    action_palette.ownRequestText(allocator, completions) catch return;
    const reply = sequencer.ReplyTo.of(system(), widget_reply_tag);
    action_palette.request(tables.memory, tables, .{ .present = .{ .completions = completions, .reply = reply } });
}

fn handleWidgetReply(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, received: sequencer.Message) void {
    const event = action_palette.eventOf(received) catch |err| return received.unreadable(err);
    if (event.kind != .completed) return;
    if (event.completion) |completion| {
        const choice = std.enums.fromInt(WidgetChoice, completion.data[0]) orelse return;
        switch (choice) {
            .perf => workspaces.showPanel(tables, atoms, perf_panel.id, .beside_focused, .take),
            .memory => workspaces.showPanel(tables, atoms, memory_panel.id, .beside_focused, .take),
            .table => plugin.action_api.requestInvoke(tables, .{ plugin.action_api.global_mode, atoms.intern("picker_toggle") }),
        }
    }
    if (action_palette.currentOwner(tables, atoms) != widget_owner) action_palette.resetCompletionArena(memory, .widget);
    action_palette.request(memory, tables, .{ .acknowledge = .{ .owner = widget_owner } });
}

/// The inspector's panel actions and the answer to its add-widget prompt: a system under the
/// inspector's root, beside the table windows. It writes no table of its own: a widget opens
/// as a panel, through the panels' commands, and the prompt is the action palette's.
pub fn system() sequencer.System {
    return .{
        .name = "inspector_widgets",
        .root = inspector_root,
        .claims = claims,
        .access = access,
        .kernels = &.{.{ .name = "inspector_widgets.take_messages", .run = takeMessages }},
    };
}

const action_tags = plugin.action_api.tags(&actions);

fn claims(tag: Atom) bool {
    if (tag == widget_reply_tag) return true;
    return std.mem.indexOfScalar(Atom, &action_tags, tag) != null;
}

fn access(frame: *const sequencer.Frame) sequencer.Access {
    var result: sequencer.Access = .{};
    result.read(Atom.from(action_palette.table_name));
    result.write(Atom.from(action_palette.requests_table_name));
    // Choosing a table widget invokes the picker's action.
    result.writeIfPresent(frame.tables, Atom.from(plugin.action_api.commands_table_name));
    // Focusing, docking and maximizing ask the panels; a widget chosen is a fixed panel shown.
    result.writeIfPresent(frame.tables, Atom.from(plugin.panels.commands_table_name));
    result.writeIfPresent(frame.tables, Atom.from(workspaces.shown_panels_table_name));
    return result;
}

fn takeMessages(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    // Its decoration's buttons, its actions and the palette's reply.
    for (frame.messages) |received| {
        if (received.tag == widget_reply_tag) {
            handleWidgetReply(frame.memory, frame.tables, frame.atoms, received);
        } else {
            takeAction(frame.memory, frame.tables, frame.atoms, received.tag);
        }
    }
}

/// While a prompt or a form has the keyboard, the panels stay as they are.
fn takeAction(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, tag: Atom) void {
    if (action_palette.requestOpen(tables, atoms) or windows.isFormEditing(tables, atoms)) return;
    if (tag == Atom.from("inspector_add_widget")) {
        queueAddWidgetPrompt(memory, tables);
    } else if (tag == Atom.from("focus_next_view")) {
        plugin.panels.request(memory, tables, .focus_next);
    } else if (tag == Atom.from("maximize_toggle")) {
        plugin.panels.request(memory, tables, .toggle_maximize);
    } else {
        const focused = panels_mod.focusedTarget(tables, atoms).id;
        for (dock_actions) |entry| {
            if (tag != Atom.from(entry.name)) continue;
            plugin.panels.request(memory, tables, .{ .move = .{ .id = focused, .side = entry.side } });
        }
    }
}

/// A series of the frame tracker: what it is called, its samples oldest first, and the color its
/// tracker draws it in.
const FrameSeries = struct {
    label: []const u8,
    samples: []const f32,
    color: ui.Color,

    fn latest(series: FrameSeries) f32 {
        if (series.samples.len == 0) return 0;
        return series.samples[series.samples.len - 1];
    }

    fn average(series: FrameSeries) f32 {
        if (series.samples.len == 0) return 0;
        var total: f32 = 0;
        for (series.samples) |sample| total += sample;
        return total / @as(f32, @floatFromInt(series.samples.len));
    }

    fn worst(series: FrameSeries) f32 {
        var most: f32 = 0;
        for (series.samples) |sample| most = @max(most, sample);
        return most;
    }
};

/// The frame tracker's series, copied at build time because the tree outlives this call only
/// until commit: each drawn as a line in its color, over the display's refresh bands.
const FrameTimePlot = struct {
    series: []const FrameSeries,
    maximum_ms: f32,
    /// One display refresh; the plot is drawn over a band per refresh.
    vsync_ms: f32,

    pub fn draw(self: *const FrameTimePlot, size: math.Vec2f, ctx: *roop.Context) void {
        if (size.x <= 0 or size.y <= 0) return;
        ctx.beginPath();
        ctx.rect(0, 0, size.x, size.y);
        ctx.fillColor(style.col.canvas);
        ctx.fill();
        // A band per display refresh a frame can take, which a reader compares against.
        vsync.drawBands(ctx, size.x, size.y, self.maximum_ms, self.vsync_ms, style.ui_font);
        for (self.series) |series| self.drawLine(series, size, ctx);
        self.drawLegend(ctx);
    }

    fn drawLine(self: *const FrameTimePlot, series: FrameSeries, size: math.Vec2f, ctx: *roop.Context) void {
        const samples = series.samples;
        if (samples.len < 2) return;
        const last: f32 = @floatFromInt(samples.len - 1);
        ctx.beginPath();
        for (samples, 0..) |sample, index| {
            const x = size.x * @as(f32, @floatFromInt(index)) / last;
            const y = size.y * (1 - std.math.clamp(sample / self.maximum_ms, 0, 1));
            if (index == 0) ctx.moveTo(x, y) else ctx.lineTo(x, y);
        }
        ctx.strokeColor(series.color);
        ctx.strokeWidth(1.5);
        ctx.stroke();
        // A spike past the top is cut off there; a red mark says how far it went.
        for (samples, 0..) |sample, index| {
            if (sample <= self.maximum_ms) continue;
            const x = size.x * @as(f32, @floatFromInt(index)) / last;
            ctx.beginPath();
            ctx.rect(@round(x) - 1, 0, 3, 4);
            ctx.fillColor(style.col.danger);
            ctx.fill();
        }
    }

    /// Each series' name in its color, along the top left.
    fn drawLegend(self: *const FrameTimePlot, ctx: *roop.Context) void {
        ctx.fontFace(style.ui_font);
        ctx.textAlign(.{ .left = true, .baseline = true });
        var x: f32 = 6;
        for (self.series) |series| {
            ctx.beginPath();
            ctx.rect(x, 7, 10, 3);
            ctx.fillColor(series.color);
            ctx.fill();
            ctx.fillColor(series.color);
            x = ctx.text(x + 14, 13, series.label) + 12;
        }
    }
};

fn renderPerf(tree: *ui.Tree, tables: *Table.Registry, atoms: *Atom.Registry) void {
    const allocator = tree.frame_allocator.allocator;
    const series = frameSeries(allocator, tables, atoms) catch &[_]FrameSeries{};
    if (!tree.beginRect("inspector.perf", .{ .axis = .vertical, .size = .{ .w = .fill, .h = .fill }, .padding = 6, .gap = 4, .bg = style.col.sidebar, .clip_content = true })) return;
    defer tree.endRect();
    // Scaled to the usual frames, not the worst: one spike, such as loading, would flatten
    // the rest. Spikes past the top are marked where they are cut.
    var typical: f32 = 0;
    var worst: f32 = 0;
    for (series) |line| {
        typical = @max(typical, typicalWorst(allocator, line.samples));
        worst = @max(worst, line.worst());
    }
    const maximum_ms = frameRange(typical);
    var bars: std.ArrayList(Bar) = .empty;
    for (series) |line| {
        bars.append(allocator, .{ .name = line.label, .value = line.latest() }) catch return;
    }
    if (series.len != 0) {
        const average_label = std.fmt.allocPrint(allocator, "{s} average", .{series[0].label}) catch return;
        bars.append(allocator, .{ .name = average_label, .value = series[0].average() }) catch return;
    }
    bars.append(allocator, .{ .name = "Worst", .value = worst }) catch return;
    const times_group = allocator.create(BarGroup) catch return;
    times_group.* = .{ .bars = bars.items, .unit = .milliseconds, .full_scale = maximum_ms };
    tree.custom("inspector.perf.times", times_group, .{ .size = .{ .w = .fill, .h = .{ .fixed = BarGroup.height(bars.items.len) } }, .clip_content = true });
    const plot = allocator.create(FrameTimePlot) catch return;
    plot.* = .{ .series = series, .maximum_ms = maximum_ms, .vsync_ms = vsync.intervalMs(tables, atoms) };
    tree.custom("inspector.perf.plot", plot, .{ .size = .{ .w = .fill, .h = .fill }, .clip_content = true });
}

/// The 95th percentile of `samples`: the longest frame that is not a rare spike.
fn typicalWorst(allocator: std.mem.Allocator, samples: []const f32) f32 {
    if (samples.len == 0) return 0;
    const sorted = allocator.dupe(f32, samples) catch return 0;
    std.mem.sort(f32, sorted, {}, std.sort.asc(f32));
    const index = @min(sorted.len - 1, (sorted.len * 95) / 100);
    return sorted[index];
}

/// The plot's top, on fixed steps. A range that followed the worst sample would rescale the whole
/// line every frame as samples came and went; this one only moves when a spike crosses a step.
fn frameRange(worst_ms: f32) f32 {
    var range_ms: f32 = 1000.0 / 30.0;
    for ([_]f32{ 50, 1000.0 / 15.0, 100 }) |step_ms| {
        if (worst_ms <= range_ms) return range_ms;
        range_ms = step_ms;
    }
    while (worst_ms > range_ms and std.math.isFinite(range_ms)) range_ms *= 2;
    return range_ms;
}

test "the frame plot range ignores small changes in the worst sample" {
    try std.testing.expectEqual(frameRange(20), frameRange(31));
    try std.testing.expectEqual(frameRange(40), frameRange(49));
    try std.testing.expect(frameRange(40) > frameRange(31));
    try std.testing.expectEqual(@as(f32, 400), frameRange(350));
}

/// The frame tracker's series in its order: by default the sim's frame time, then the render
/// thread's.
fn frameSeries(allocator: std.mem.Allocator, tables: *Table.Registry, atoms: *Atom.Registry) ![]const FrameSeries {
    const definition = tables.findByName(atoms.intern(frame_tracker)) orelse return &[_]FrameSeries{};
    const history = (try tracker.history(allocator, atoms, tables, definition)) orelse return &[_]FrameSeries{};
    var series: std.ArrayList(FrameSeries) = .empty;
    var index: usize = 0;
    while (tracker.seriesAt(definition, index)) |tracked| : (index += 1) {
        var name_buffer: [32]u8 = undefined;
        const field = try tracker.seriesFieldName(&name_buffer, index);
        const samples = try allocator.alloc(f32, history.count());
        var count: usize = 0;
        var rows = history.rows();
        while (rows.next()) |row| {
            const value = history.getField(f32, row, field) orelse continue;
            samples[count] = value.*;
            count += 1;
        }
        const color: ui.Color = .{ .r = tracked.color.x, .g = tracked.color.y, .b = tracked.color.z, .a = tracked.color.w };
        try series.append(allocator, .{ .label = seriesLabel(atoms, tracked.field_name), .samples = samples[0..count], .color = color });
    }
    return series.items;
}

/// What the plot calls a series: the frame times by whose they are, any other by its field.
fn seriesLabel(atoms: *Atom.Registry, field: Atom) []const u8 {
    if (field == Atom.from(time.frame_time_field)) return "Sim";
    if (field == Atom.from(time.render_frame_time_field)) return "Render";
    return atoms.lookup(field) orelse "?";
}

const Bar = struct { name: []const u8, value: f64, peak: f64 = 0 };
const BarUnit = enum { megabytes, milliseconds };
const bar_row_height: f32 = 17;

/// A group of labeled bars on one scale, each with a tick at its peak when it has one. Rows keep
/// their height, so a short pane shows fewer bars rather than overlapping labels.
const BarGroup = struct {
    bars: []const Bar,
    unit: BarUnit,
    /// The value a full bar stands for; zero scales to the group's largest.
    full_scale: f64 = 0,

    fn height(count: usize) f32 {
        return bar_row_height * @as(f32, @floatFromInt(count));
    }

    pub fn draw(self: *const BarGroup, size: math.Vec2f, ctx: *roop.Context) void {
        if (self.bars.len == 0 or size.x <= 0 or size.y <= 0) return;
        var maximum = self.full_scale;
        if (maximum <= 0) {
            for (self.bars) |bar| maximum = @max(maximum, @max(bar.value, bar.peak));
        }
        if (maximum <= 0) maximum = 1;
        const label_width = @min(150, size.x * 0.4);
        const plot_width = @max(0, size.x - label_width - 70);
        const row_capacity: usize = @intFromFloat(@floor(size.y / bar_row_height));
        ctx.fontFace(style.ui_font);
        for (self.bars[0..@min(self.bars.len, row_capacity)], 0..) |bar, index| {
            const y = bar_row_height * @as(f32, @floatFromInt(index));
            const track_height = bar_row_height - 3;
            const value_share: f32 = @floatCast(@min(bar.value / maximum, 1));
            ctx.beginPath();
            ctx.rect(label_width, y, plot_width, track_height);
            ctx.fillColor(style.col.canvas);
            ctx.fill();
            ctx.beginPath();
            ctx.rect(label_width, y, plot_width * value_share, track_height);
            ctx.fillColor(style.col.accent_deep);
            ctx.fill();
            if (bar.peak > 0) {
                const peak_share: f32 = @floatCast(@min(bar.peak / maximum, 1));
                ctx.beginPath();
                ctx.rect(label_width + @max(0, plot_width * peak_share - 1), y, 1, track_height);
                ctx.fillColor(style.col.accent_bright);
                ctx.fill();
            }
            ctx.fillColor(style.col.text);
            ctx.textAlign(.{ .left = true, .baseline = true });
            const baseline = y + track_height - 3;
            _ = ctx.text(0, baseline, bar.name);
            var buffer: [24]u8 = undefined;
            const amount = switch (self.unit) {
                .megabytes => std.fmt.bufPrint(&buffer, "{d:.1} MB", .{bar.value}),
                .milliseconds => std.fmt.bufPrint(&buffer, "{d:.1} ms", .{bar.value}),
            } catch "";
            _ = ctx.text(label_width + plot_width + 6, baseline, amount);
        }
    }
};

fn bytesToMegabytes(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024 * 1024);
}

fn renderGroupDivider(tree: *ui.Tree, id: []const u8) void {
    tree.rect(id, .{ .size = .{ .w = .fill, .h = .{ .fixed = 1 } }, .bg = style.col.divider });
}

/// Totals for the whole process, then what each owner holds. Their scales differ, so each group
/// has its own and the line between them says not to compare across it.
fn renderMemory(tree: *ui.Tree, tables: *Table.Registry, atoms: *Atom.Registry) void {
    const allocator = tree.frame_allocator.allocator;
    const report = memoryReport(allocator, tables, atoms) catch MemoryReport{};
    if (!tree.beginRect("inspector.memory", .{ .axis = .vertical, .size = .{ .w = .fill, .h = .fill }, .padding = 6, .gap = 4, .bg = style.col.sidebar, .clip_content = true })) return;
    defer tree.endRect();
    const tracked_bar = Bar{ .name = "Tracked", .value = bytesToMegabytes(report.tracked_bytes) };
    const totals = if (processMemory(tables, atoms)) |process|
        allocator.dupe(Bar, &[_]Bar{
            .{ .name = "Process", .value = bytesToMegabytes(process.resident_bytes) },
            .{ .name = "GPU", .value = bytesToMegabytes(process.gpu_block_bytes) },
            tracked_bar,
        }) catch return
    else
        allocator.dupe(Bar, &[_]Bar{tracked_bar}) catch return;
    const totals_group = allocator.create(BarGroup) catch return;
    totals_group.* = .{ .bars = totals, .unit = .megabytes };
    tree.custom("inspector.memory.totals", totals_group, .{ .size = .{ .w = .fill, .h = .{ .fixed = BarGroup.height(totals.len) } }, .clip_content = true });
    renderGroupDivider(tree, "inspector.memory.divider");
    tree.text("inspector.memory.owners.title", "Largest owners, peak marked", .{ .font = style.ui_font, .color = style.col.text_dim });
    const owners_group = allocator.create(BarGroup) catch return;
    owners_group.* = .{ .bars = report.bars, .unit = .megabytes };
    tree.custom("inspector.memory.plot", owners_group, .{ .size = .{ .w = .fill, .h = .fill }, .clip_content = true });
}

const ProcessMemory = struct { resident_bytes: u64, gpu_block_bytes: u64 };

/// Null until the host publishes it, as in a build that has no process table.
fn processMemory(tables: *Table.Registry, atoms: *Atom.Registry) ?ProcessMemory {
    const process_table = tables.findByName(atoms.intern(process_memory_table)) orelse return null;
    var rows = process_table.query(struct { resident_bytes: *u64, gpu_block_bytes: *u64 });
    const row = rows.next() orelse return null;
    return .{ .resident_bytes = row.view.resident_bytes.*, .gpu_block_bytes = row.view.gpu_block_bytes.* };
}

const MemoryReport = struct {
    bars: []const Bar = &[_]Bar{},
    /// Every row of the report, not only the bars.
    tracked_bytes: u64 = 0,
};

/// Zero when the row left this cell empty: table arena rows have no peak, and the singleton arena
/// has no page count.
fn reportCell(rows_table: *Table, row: Table.RowHandle, comptime name: []const u8) u64 {
    const schema = rows_table.getSchema();
    const field = schema.fields[schema.fieldIndex(name).?];
    const present = rows_table.rowHas(row.row, field.bit);
    if (!present) return 0;
    return rows_table.getField(u64, row, name).?.*;
}

fn memoryReport(allocator: std.mem.Allocator, tables: *Table.Registry, atoms: *Atom.Registry) !MemoryReport {
    const rows_table = tables.findByName(atoms.intern(memory_table)) orelse return .{};
    var bars: std.ArrayList(Bar) = .empty;
    var tracked_bytes: u64 = 0;
    // Asks only for what every row has: a query skips any row missing a field it names.
    var query = rows_table.query(struct { owner: *Atom, capacity: *u64 });
    while (query.next()) |row| {
        const backing_bytes = reportCell(rows_table, row.handle, "backing_bytes");
        const bytes = if (backing_bytes != 0) backing_bytes else row.view.capacity.*;
        const peak = reportCell(rows_table, row.handle, "peak_bytes");
        tracked_bytes += bytes;
        if (bytes == 0 and peak == 0) continue;
        try bars.append(allocator, .{ .name = atoms.lookup(row.view.owner.*) orelse "(unnamed)", .value = bytesToMegabytes(bytes), .peak = bytesToMegabytes(peak) });
    }
    std.mem.sort(Bar, bars.items, {}, struct {
        fn heavier(_: void, a: Bar, b: Bar) bool {
            return a.value > b.value;
        }
    }.heavier);
    return .{ .bars = bars.items[0..@min(bars.items.len, kMaxMemoryBars)], .tracked_bytes = tracked_bytes };
}

test "the memory report charts table arenas and totals every row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 8);
    defer tables.deinit();

    for (0..kMaxMemoryBars + 4) |index| {
        var name_buffer: [32]u8 = undefined;
        const owner = try std.fmt.bufPrint(&name_buffer, "owner.{d}", .{index});
        const id = try memory.openScope(atoms.intern(owner));
        const scope = memory.scopeFor(id).?;
        _ = try scope.fixedAllocator().alloc(u8, 16);
    }
    try memory.syncTable(&tables, &atoms);

    const report = try memoryReport(arena.allocator(), &tables, &atoms);
    try std.testing.expectEqual(kMaxMemoryBars, report.bars.len);

    const rows_table = tables.findByName(atoms.intern(memory_table)).?;
    var expected_bytes: u64 = 0;
    var durable_rows: usize = 0;
    var query = rows_table.query(struct { owner: *Atom, capacity: *u64 });
    while (query.next()) |row| {
        const backing_bytes = reportCell(rows_table, row.handle, "backing_bytes");
        expected_bytes += if (backing_bytes != 0) backing_bytes else row.view.capacity.*;
        if (row.view.owner.* == atoms.intern("tables.durable")) durable_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), durable_rows);
    try std.testing.expectEqual(expected_bytes, report.tracked_bytes);

    // The durable arena holds the report itself, so it outweighs a one-page scope.
    var charted = false;
    for (report.bars) |bar| charted = charted or std.mem.eql(u8, bar.name, "tables.durable");
    try std.testing.expect(charted);
}

/// Whether the panel `id` is one this module draws: a widget or a table's window.
pub fn isPanel(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) bool {
    return isBuiltinWidget(atoms, id) or windows.isWindow(tables, atoms, id);
}

/// Fills the part of a pane's header between its title and its close button.
fn renderDecoration(tree: *ui.Tree, tables: *Table.Registry, atoms: *Atom.Registry, widget: Atom) void {
    if (isBuiltinWidget(atoms, widget)) return;
    tree.hovered = state.hoveredElementId(tables);
    windows.renderDecoration(tree, tables, atoms, widget);
}

/// Draws a widget panel: its header, then its tree, committed into the content under it.
/// `frame` is the panel's frame in the window and `ctx` begins at its corner.
pub fn renderPanel(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, widget: Atom, frame: plugin.Viewport, ctx: *roop.Context) void {
    var header: panel_frame.Header = undefined;
    if (header.begin(memory, tables, atoms, widget)) {
        if (header.open) renderDecoration(&header.tree, tables, atoms, widget);
        header.finish(tables, atoms, frame, ctx);
    }
    const viewport = panel_frame.beginContent(tables, atoms, widget, frame, ctx) orelse return;
    defer panel_frame.endContent(ctx);
    const scratch = memory.frameScratchAllocator() catch return;
    var tree = ui.Tree.init(scratch, atoms, widget_commands) catch return;
    renderWidget(&tree, tables, atoms, widget);
    tree.commit(.{
        .root_size = .{ .x = viewport.width, .y = viewport.height },
        .offset = .{ .x = viewport.x, .y = viewport.y },
        .hovered = state.hoveredElementId(tables),
        .depth = panels_mod.kPanelHitDepth,
    }, ctx, state.hitRegions(tables, atoms));
}

/// Room for the largest widget, a table window, in one frame's tree.
const widget_commands: usize = 16384;

pub fn renderWidget(tree: *ui.Tree, tables: *Table.Registry, atoms: *Atom.Registry, widget: Atom) void {
    tree.hovered = state.hoveredElementId(tables);
    // Everything else waits while a prompt or menu owns input; widgets stay readable behind it.
    tree.hits_enabled = !action_palette.requestOpen(tables, atoms);
    if (widget == atoms.intern(perf_widget)) {
        renderPerf(tree, tables, atoms);
    } else if (widget == atoms.intern(memory_widget)) {
        renderMemory(tree, tables, atoms);
    } else {
        windows.renderWidget(tree, tables, atoms, widget);
    }
}
