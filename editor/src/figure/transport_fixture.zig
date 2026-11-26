//! Headless production transport used by editor tool tests, never a wire cast.
const std = @import("std");
const mesha = @import("mesha");
const mesha_runtime = @import("mesha_runtime");
const figure_runtime = mesha_runtime.figure;
const figure = mesha.figure;
const adapter = @import("commands.zig");
const plugin = mesha.plugin;
const panels_mod = mesha.panels;
const editor_sequencer = @import("../editor_sequencer.zig");
const workspace = @import("workspace.zig");
const session = @import("session.zig");
const watches = @import("watches.zig");
const asks = @import("asks.zig");
const gesture = @import("gesture.zig");
const drawing = @import("drawing.zig");
const sequencer = mesha.sequencer;
const Table = mesha.Table;

/// The document system's inbox, which the host's results go to, made for a test.
pub fn ensureResultInbox(memory: *mesha.memory.Memory, atoms: *mesha.Atom.Registry, tables: *Table.Registry) !void {
    const results: sequencer.Sequencer = .{ .name = "figure_document_results", .steps = &.{.{ .system = adapter.system() }} };
    try sequencer.ensureInboxes(try memory.tableScratchAllocator(), atoms, tables, &results);
}

/// The oldest result in the document system's inbox not yet taken, which it marks taken; a
/// test takes them in place of the system. Rows are only cleared together, so the inbox
/// keeps arrival order.
pub fn nextResult(tables: *Table.Registry) error{MessageShape}!?figure.Result {
    const inbox = tables.findByName(sequencer.inboxOf(adapter.system())) orelse return null;
    const received = sequencer.takeOldest(inbox) orelse return null;
    const result = try received.payloadAs(figure.Result);
    return result.*;
}

pub fn noResults(tables: *Table.Registry) bool {
    const inbox = tables.findByName(sequencer.inboxOf(adapter.system())) orelse return true;
    return !sequencer.hasUntakenMessage(inbox);
}

/// Forgets the results taken, so the document system never sees them.
pub fn clearResults(tables: *Table.Registry) void {
    const inbox = tables.findByName(sequencer.inboxOf(adapter.system())) orelse return;
    inbox.clear();
}

/// What the figure host does after it applies a frame's commands, for a fixture with no
/// `Transport`: makes the tables it publishes to, as it does when it starts, has the editor
/// declare its watches (`declareWatches`), then publishes what it holds there and answers the
/// watches, which the editor reads the catalog and the open definition from. A revision that does
/// not compile is still published, and its error returned. A fixture that calls it tears the figure
/// runtime down (`figure_runtime.deinit`), which frees what the answers lie in.
pub fn synchronize(memory: *mesha.memory.Memory, atoms: *mesha.Atom.Registry, tables: *Table.Registry) !void {
    var host: figure_runtime.HostTransport.Host = .{ .context = .{ .memory = memory, .atoms = atoms, .tables = tables } };
    try figure_runtime.HostTransport.prepareCommands(&host);
    // The watches system's tables, which it subscribes through.
    const watching: sequencer.Built(1) = .{ .name = "figure_watches_test", .steps = .{.{ .system = watches.system() }} };
    try sequencer.ensureInboxes(try memory.tableScratchAllocator(), atoms, tables, &watching.sequencer());
    declareWatches(memory, atoms, tables);
    try figure_runtime.HostTransport.synchronize(&host);
}

/// The end of a frame of the editor's run and what the host runs between it and the frame's
/// drawing: the editor declares its watches (`declareWatches`), then the host applies
/// `commands.figure` and synchronizes, which publishes what it holds and answers every watch in
/// `figure_published`. A revision that does not compile is published from its last good
/// generation, as the host does, and its error is the result's to report.
pub fn pumpHost(transport: *Transport) !void {
    const context = transport.host.context;
    declareWatches(context.memory, context.atoms, context.tables);
    var commands: figure_runtime.HostTransport.HostContext = .{ .host = &transport.host };
    figure_runtime.HostTransport.applyCommands(&commands);
    figure_runtime.HostTransport.synchronize(&transport.host) catch |err| switch (err) {
        error.CompileFailed => {},
        else => return err,
    };
}

/// A run of the editor's watches system alone, which ends each frame of the figure editor's
/// systems: it declares what the editor watches of the figure in the state the test left it in.
/// Nothing without the editor's session, or without the figure host's tables.
pub fn declareWatches(memory: *mesha.memory.Memory, atoms: *mesha.Atom.Registry, tables: *Table.Registry) void {
    if (tables.findByName(mesha.Atom.from(session.name)) == null) return;
    const watching: sequencer.Built(1) = .{ .name = "figure_watches_test", .steps = .{.{ .system = watches.system() }} };
    editor_sequencer.run(memory, atoms, tables, &watching.sequencer(), null);
}

/// One frame of the figure editor's systems with no messages sent: what the editor does each
/// frame on its own, from following the document to tracking the view.
pub fn runSystems(memory: *mesha.memory.Memory, atoms: *mesha.Atom.Registry, tables: *mesha.Table.Registry) void {
    const figure_authoring = workspace.figureAuthoring();
    editor_sequencer.run(memory, atoms, tables, &figure_authoring.sequencer(), null);
}
pub const Transport = struct {
    layout_commands: enum { ignore, apply } = .ignore,
    host: figure_runtime.HostTransport.Host = undefined,
    pub fn init(self: *@This(), memory: *mesha.memory.Memory, atoms: *mesha.Atom.Registry, tables: *mesha.Table.Registry) !void {
        self.layout_commands = .ignore;
        try figure_runtime.init(.{ .memory = memory, .atoms = atoms, .tables = tables });
        try ensureResultInbox(memory, atoms, tables);
        self.host = .{ .context = .{ .memory = memory, .atoms = atoms, .tables = tables } };
        try figure_runtime.HostTransport.prepareCommands(&self.host);
        try plugin.panels.Requests.ensure(try memory.tableScratchAllocator(), atoms, tables, plugin.panels.commands_table_name);
        try mesha.panels.ensure(try memory.tableScratchAllocator(), atoms, tables);
        // The tables the host's time system reads, which the editor's systems append to.
        try mesha.time.ensureTables(try memory.tableScratchAllocator(), atoms, tables);
        try mesha.input.ensureTables(try memory.tableScratchAllocator(), atoms, tables);
        try @import("workspace.zig").ensure(memory, atoms, tables);
        // The inboxes of the editor's systems, which the host answers their questions in.
        const authoring = workspace.figureAuthoring();
        try sequencer.ensureInboxes(try memory.tableScratchAllocator(), atoms, tables, &authoring.sequencer());
    }
    /// Ends what `init` began in the figure runtime; the tables stay the caller's.
    pub fn deinit(self: *@This()) void {
        const context = self.host.context;
        figure_runtime.deinit(.{ .memory = context.memory, .tables = context.tables, .atoms = context.atoms }) catch {};
    }
    /// Applies the editor's requests to the panels, or drops them while layout is ignored.
    fn takeLayout(self: *@This()) void {
        const context = self.host.context;
        const requests = plugin.panels.Requests.of(context.memory, context.tables, plugin.panels.commands_table_name);
        if (self.layout_commands == .apply) {
            var rows = requests.iterate();
            while (rows.next()) |command| panels_mod.applyCmd(context.tables, context.atoms, command);
        }
        requests.reset();
    }
    /// The pose the canvas shows once the editor's update has run, answered as the frame's
    /// drawing reads it: the host publishes, the preview follows the catalog, then the editor
    /// declares its watches of that pose and the host answers them. It queues nothing, so the
    /// caller's buffers stay as they were.
    pub fn preparePreview(self: *@This()) !mesha.figure.PosedFigure {
        const context = self.host.context;
        try figure_runtime.HostTransport.synchronize(&self.host);
        try @import("preview.zig").sync(context.tables, context.atoms);
        declareWatches(context.memory, context.atoms, context.tables);
        try figure_runtime.HostTransport.synchronize(&self.host);
        return @import("preview.zig").current(context.tables, context.atoms);
    }
    /// The end of a frame's run and what the host does after it applies the frame's commands:
    /// the editor declares its watches, and the host publishes what it holds and answers them.
    /// For a test that changed documents without commands.
    pub fn synchronize(self: *@This()) !void {
        const context = self.host.context;
        declareWatches(context.memory, context.atoms, context.tables);
        try figure_runtime.HostTransport.synchronize(&self.host);
    }
    /// The end of the frame a press, release or eraser sample asked the host in, and the start
    /// of the next: the host answers the canvas's questions, then the canvas takes the answers
    /// and the pointer's messages held behind them, alone of the editor's systems.
    pub fn answerCanvas(self: *@This()) !void {
        try self.synchronize();
        self.runCanvas();
    }

    /// A frame of the canvas system alone, with what its inbox holds.
    pub fn runCanvas(self: *@This()) void {
        const context = self.host.context;
        const canvas: sequencer.Built(1) = .{ .name = "figure_canvas_test", .steps = .{.{ .system = workspace.system() }} };
        editor_sequencer.run(context.memory, context.atoms, context.tables, &canvas.sequencer(), null);
    }
    /// A frame of the gesture system alone: it takes the answers to an Auto IK drag's solves,
    /// then flushes the drag.
    pub fn runGesture(self: *@This()) void {
        const context = self.host.context;
        const drag: sequencer.Built(1) = .{ .name = "figure_gesture_test", .steps = .{.{ .system = gesture.system() }} };
        editor_sequencer.run(context.memory, context.atoms, context.tables, &drag.sequencer(), null);
    }

    /// The end of the frame an Auto IK press or flush asked its solve in, and the start of the
    /// next: the host answers, then the gesture system takes the answers and flushes the drag.
    /// Nothing while no solve is in flight.
    pub fn answerSolves(self: *@This()) !void {
        const asked = asks.rows(self.host.context.tables);
        if (!asks.awaited(asked)) return;
        try self.synchronize();
        self.runGesture();
    }

    /// A frame of the drawing system alone: it takes the answers to its questions, its actions,
    /// and asks where the gradient tools' paint lies.
    pub fn runDrawing(self: *@This()) void {
        const context = self.host.context;
        const drawing_solo: sequencer.Built(1) = .{ .name = "figure_drawing_test", .steps = .{.{ .system = drawing.system() }} };
        editor_sequencer.run(context.memory, context.atoms, context.tables, &drawing_solo.sequencer(), null);
    }

    /// The host answers what the drawing system asked, and the drawing system takes the answers
    /// the next frame.
    pub fn answerDrawing(self: *@This()) !void {
        try self.synchronize();
        self.runDrawing();
    }

    pub fn tickPreview(self: *@This(), dt: f64) !void {
        const context = self.host.context;
        @import("filmstrip.zig").config(context.tables).preview.* = 1;
        _ = try self.preparePreview();
        @import("filmstrip.zig").tick(context.tables, context.atoms, dt);
        _ = try self.preparePreview();
    }
    pub fn drain(self: *@This(), allow_failure: bool) !void {
        try pumpHost(self);
        self.takeLayout();
        const context = self.host.context;
        var failed: ?mesha.figure.Error = null;
        while (try nextResult(context.tables)) |result| {
            if (result.outcome == .failure) failed = result.outcome.failure;
            try std.testing.expect(adapter.consume(.{ .memory = context.memory, .atoms = context.atoms, .tables = context.tables }, result));
        }
        clearResults(context.tables);
        if (!allow_failure) if (failed) |err| return err;
    }
};
