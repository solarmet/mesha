//! The window's panels. A binary tree of splits divides the window; each leaf is a panel, whose
//! whole frame is its plugin's to draw, header and all. A panel opens to any side of the panel that
//! asked for it, or along an edge of the window, splitting that space between them; a closed
//! panel's sibling takes its parent's place. The boundary of each split drags to resize, and
//! maximizing fills the window with the focused panel until it is restored or the focus leaves
//! it.
//!
//! One panel is focused at a time. Its owner, the system it belongs to, is the one whose local
//! input subscriptions fire. The panels that had the focus before are kept, newest last
//! (`panels_focus_history`): when the focused panel closes or is hidden the newest still open
//! takes the focus, and `focus_previous` gives it to that one while the focused panel stays.
//! Workspaces are arrangements their owner opens after activation, which closes every panel.
//!
//! What the panels system tells (`events.panels`, `plugin.panels.Event`): the focus moving
//! (`dispatchFocusChanges`) and a panel's laid-out size changing (`dispatchResizes`).
//!
//! The tree lives in the `panels` table, one row per node, and the rest in the one row of
//! `panels_state`, so tools can inspect both; a command loads them into a `Tree`, changes it and
//! stores it back (`applyCmd`).
//!
//! A plugin's systems say which panels are open by declaring them every frame
//! (`plugin.panels.declare`, rows of `subscribed.panels`): the host's panels system opens a
//! declared panel that is not open, by the placement its declaration gives, and closes one
//! its system no longer declares (`reconcile`). Where a panel then is, how the space is
//! shared and which has the focus stay the tree's, across frames, as does which panels are
//! hidden (`hide`, `show`): closed whatever declares them. A plugin changes those with
//! rows of `commands.panels` (`plugin.panels.request`), which the panels system applies after
//! each dispatch, and reads the arrangement with the functions here: `panels`, `panelFor`, `hasFocus`. The functions that
//! write the stored arrangement (`ensure`, `relayout`, `applyCmd`, `store`, `onMousePress`,
//! `applyFrame`, `reconcile`, `openNow`, `closeNow`, `dispatchFocusChanges`, `dispatchResizes`,
//! `clearRedrawRequests`) are the host's
//! to call. Positions and sizes are
//! window pixels, from the window's top left.
//!
//! Each panel names its root, the `sequencer.System.root` of the systems it shows. The host draws
//! a panel again only when something says it looks different: its place, size, title
//! or focus changed, or a row of `panels_redraw` asks for it (`requestRedraw`), as the editor's
//! sequencer asks for the panels of a root when a run of one of its systems changed a table. A
//! panel the game owns draws every frame. Any other shows what it drew last.
const std = @import("std");
const Log = @import("../core/log.zig").scope("panels");
const plugin = @import("plugin.zig");
const Atom = @import("../core/atom.zig").Atom;
const memory_mod = @import("../core/memory.zig");
const Table = @import("../core/table.zig");
const contract = @import("../core/contract.zig");
const sequencer = @import("../core/sequencer.zig");

const no_atom: Atom = @enumFromInt(0);

/// The side of a panel, or of the window, that a panel opens or docks to; `plugin.panels.Side`.
pub const Side = plugin.panels.Side;
/// The system a panel belongs to, whose local input subscriptions fire while it is focused;
/// `plugin.panels.Owner`.
pub const Owner = plugin.panels.Owner;

/// `panels`, the tree: `kMaxNodes` rows, a node each, a row's index being its node's. A zeroed
/// row is a free node.
pub const nodes_table_name = "panels";
/// `panels_state`, one row: what `State` views.
pub const state_table_name = "panels_state";
/// The panels asked to draw again this frame, a row each; see `requestRedraw`.
pub const redraw_table_name = "panels_redraw";
/// The hidden panels, a row each: a panel a `hide` request named stays closed, whatever
/// declares it, until a `show` request names it. At most `kMaxPanels`.
pub const hidden_table_name = "panels_hidden";
/// The panels that had the focus before the focused one, a row each, oldest first and newest
/// last; a panel at most once, never the focused one, and none that closed. When the focused
/// panel closes or is hidden, the newest still open takes the focus (`focusHistory`). At most
/// `kMaxPanels`.
pub const focus_history_table_name = "panels_focus_history";
/// The size each open panel was last told it has (`dispatchResizes`), a row each, so a size is
/// told once. At most `kMaxPanels`.
pub const told_sizes_table_name = "panels_told_sizes";
/// `app_hit_regions`, the table the editor plugin records every panel's hit regions in. The host
/// finds it by this name.
pub const hit_regions_name = "app_hit_regions";

/// Above every panel's hit regions, so the action palette takes the pointer wherever it is
/// drawn: the window's top layer.
pub const kActionPaletteHitDepth: u32 = 200;
/// Where a panel's content takes the pointer. Panels never overlap, so one depth serves them
/// all; the content's own layers go above it.
pub const kPanelHitDepth: u32 = 102;
/// Where a panel's header and the host's dividers take the pointer: above any panel's
/// content, below the action palette. A plugin commits its header's tree at this depth.
pub const kChromeHitDepth: u32 = 104;

/// The most panels open at once; opening another is refused with `TooManyPanels`.
pub const kMaxPanels: usize = 32;
/// The tree's node slots: `kMaxPanels` leaves and the splits between them.
pub const kMaxNodes: usize = 2 * kMaxPanels - 1;
/// The widest and tallest window `relayout` takes, in pixels.
pub const kMaxWindowExtent: f32 = @floatFromInt(std.math.maxInt(i32));
/// The width of the space between panels, and around them when there are several, in pixels. The
/// window's clear color shows through, and the focus glow fits inside it.
pub const kGap: f32 = 8;
/// The least a split leaves either side, in pixels, while the space allows it.
pub const kMinExtent: f32 = 120;
/// No node of the tree. The runtime's, which this file uses too; not part of what a plugin
/// relies on.
pub const no_node: u8 = std.math.maxInt(u8);

/// A rectangle in window pixels: `x` grows to the right and `y` downwards from the window's top
/// left.
pub const Rect = struct {
    /// The left edge.
    x: f32 = 0,
    /// The top edge.
    y: f32 = 0,
    /// The width. Zero or less makes the rectangle empty.
    w: f32 = 0,
    /// The height. Zero or less makes the rectangle empty.
    h: f32 = 0,

    /// Whether the point (`x`, `y`) is inside, counting the left and top edges but not the right
    /// and bottom ones.
    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return x >= self.x and y >= self.y and x < self.x + self.w and y < self.y + self.h;
    }

    /// Whether it covers nothing: a width or a height of zero or less.
    pub fn empty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    /// The area both cover. Where they do not meet, the result has a width or a height of zero.
    pub fn intersect(self: Rect, other: Rect) Rect {
        const x0 = @max(self.x, other.x);
        const y0 = @max(self.y, other.y);
        const x1 = @min(self.x + self.w, other.x + other.w);
        const y1 = @min(self.y + self.h, other.y + other.h);
        return .{ .x = x0, .y = y0, .w = @max(x1 - x0, 0), .h = @max(y1 - y0, 0) };
    }
};

/// How a split divides its space: `horizontal` puts its children side by side.
pub const Axis = enum(u8) { horizontal, vertical };
const NodeKind = enum(u8) { free, leaf, split };

/// What a panel's header says, held inline so a node stays a plain value: UTF-8 padded with
/// zeros. Text is for people to read, so it is never an atom.
pub const Title = extern struct {
    /// The most bytes a title holds.
    pub const capacity = 64;

    /// The text, then zeros to the end. A title of `capacity` bytes has no zero.
    bytes: [capacity]u8 = @splat(0),

    /// `text`, cut at a character's start when it is longer than a title holds.
    pub fn from(text: []const u8) Title {
        var kept = @min(text.len, capacity);
        // A continuation byte at the cut belongs to a character that did not fit.
        while (kept < text.len and kept > 0 and text[kept] & 0xC0 == 0x80) kept -= 1;
        var title: Title = .{};
        @memcpy(title.bytes[0..kept], text[0..kept]);
        return title;
    }

    /// The text, up to the first zero byte: the title's own bytes, valid while the title is.
    pub fn slice(title: *const Title) []const u8 {
        const len = std.mem.indexOfScalar(u8, &title.bytes, 0) orelse capacity;
        return title.bytes[0..len];
    }

    /// Whether both hold the same text.
    pub fn eql(title: Title, other: Title) bool {
        return std.mem.eql(u8, &title.bytes, &other.bytes);
    }
};

/// One node of the tree: a panel, or a split of the space between two subtrees.
pub const Node = struct {
    /// `free` for an unused slot, `leaf` for a panel, `split` for two subtrees side by side or
    /// one above the other. The fields below `kind` mean something only for the kind they name.
    kind: NodeKind = .free,
    /// A leaf's panel id; none for a split.
    id: Atom = no_atom,
    /// A leaf's header text.
    title: Title = .{},
    /// A leaf's root; see `plugin.panels.Open.root`.
    root: Atom = no_atom,
    /// A leaf's owner.
    owner: Owner = .plugin,
    /// The system whose declaration opened a leaf, a `sequencer.System`'s name; none for one
    /// the host opened itself (`openNow`), which no declaration closes.
    declared_by: Atom = no_atom,
    /// A split's direction.
    axis: Axis = .horizontal,
    /// The first child's share of a split's space, gap excluded.
    share: f32 = 0.5,
    /// A split's first child, the left or the top one, as a node index.
    first: u8 = no_node,
    /// A split's second child, the right or the bottom one, as a node index.
    second: u8 = no_node,
    /// Where the layout last put the node; zero for a panel a maximized one hides.
    frame: Rect = .{},
};

/// A panel as laid out.
pub const Panel = struct {
    /// The panel's id.
    id: Atom,
    /// The panel's title, for whatever draws a header for it; empty says nothing.
    title: Title,
    /// The system it shows; see `plugin.panels.Open.root`.
    root: Atom,
    /// The system whose local input subscriptions fire while the panel is focused.
    owner: Owner,
    /// The whole panel, which its plugin draws, header and all. Empty while a maximized
    /// panel hides it.
    frame: Rect,
};

/// The boundary between a split's two children, which drags to change their shares.
pub const Divider = struct {
    /// The split's node index, which `Tree.resize` takes.
    node: u8,
    /// The split's axis: the divider of a `horizontal` split is an upright bar.
    axis: Axis,
    /// The gap between the split's two children, `kGap` thick.
    rect: Rect,
};

/// Why a change to the arrangement is refused. `TooManyPanels`: `kMaxPanels` are open.
/// `MissingPanel`: the panel to close, move or open beside is not open. `InvalidShare`: a share
/// that is not above 0 and below 1. `InvalidPanel`: a panel opened with no id or no root.
/// `InvalidReserve`: a reserved height that is negative or not finite.
pub const Error = error{ TooManyPanels, MissingPanel, InvalidShare, InvalidPanel, InvalidReserve };

/// The arrangement itself, apart from where it is stored.
pub const Tree = struct {
    /// The node slots. A node's index names it in `root`, `first` and `second`.
    nodes: [kMaxNodes]Node = @splat(.{}),
    /// The root's node index; `no_node` for a window with no panel.
    root: u8 = no_node,
    /// The panel filling the window, if any.
    maximized: Atom = no_atom,

    /// The node index of the open panel `id`, or null when it is not open.
    pub fn find(tree: *const Tree, id: Atom) ?u8 {
        for (tree.nodes, 0..) |node, index| {
            if (node.kind == .leaf and node.id == id) return @intCast(index);
        }
        return null;
    }

    fn parentOf(tree: *const Tree, child: u8) ?u8 {
        for (tree.nodes, 0..) |node, index| {
            if (node.kind == .split and (node.first == child or node.second == child)) return @intCast(index);
        }
        return null;
    }

    fn allocate(tree: *Tree) Error!u8 {
        for (&tree.nodes, 0..) |*node, index| {
            if (node.kind == .free) return @intCast(index);
        }
        return error.TooManyPanels;
    }

    /// How many panels are open, those a maximized panel hides among them.
    pub fn panelCount(tree: *const Tree) usize {
        var count: usize = 0;
        for (tree.nodes) |node| count += @intFromBool(node.kind == .leaf);
        return count;
    }

    /// Opens a panel as `request` says (`plugin.panels.Open`). One already open keeps its place
    /// and nothing changes; the first panel takes the whole window. Fails with `InvalidPanel` for
    /// no id or no root, `InvalidShare` for a share not above 0 and below 1, `MissingPanel` when
    /// `beside` is not open and `TooManyPanels` when `kMaxPanels` are. The request's `focus` is
    /// for the caller to act on; the tree has no focus.
    pub fn open(tree: *Tree, request: plugin.panels.Open) Error!void {
        if (request.id == no_atom or request.root == no_atom) return error.InvalidPanel;
        if (tree.find(request.id) != null) return;
        if (!std.math.isFinite(request.share) or request.share <= 0 or request.share >= 1) return error.InvalidShare;
        const leaf: Node = .{ .kind = .leaf, .id = request.id, .title = .from(request.title), .root = request.root, .owner = request.owner };
        if (tree.root == no_node) {
            const index = try tree.allocate();
            tree.nodes[index] = leaf;
            tree.root = index;
            return;
        }
        // Beside a panel, or along the window's edge: beside the whole tree.
        const target = if (request.beside == no_atom) tree.root else tree.find(request.beside) orelse return error.MissingPanel;
        if (tree.panelCount() >= kMaxPanels) return error.TooManyPanels;
        // The target's slot becomes the split, so whatever pointed at it now points at both.
        const moved = try tree.allocate();
        tree.nodes[moved] = tree.nodes[target];
        const added = try tree.allocate();
        tree.nodes[added] = leaf;
        const before = request.side == .left or request.side == .top;
        tree.nodes[target] = .{
            .kind = .split,
            .axis = if (request.side == .left or request.side == .right) .horizontal else .vertical,
            .share = if (before) request.share else 1 - request.share,
            .first = if (before) added else moved,
            .second = if (before) moved else added,
        };
    }

    /// Closes a panel; its sibling takes the split's place. Fails with `MissingPanel` when it is
    /// not open. Closing the maximized panel leaves none maximized.
    pub fn close(tree: *Tree, id: Atom) Error!void {
        const leaf = tree.find(id) orelse return error.MissingPanel;
        if (tree.maximized == id) tree.maximized = no_atom;
        const parent = tree.parentOf(leaf) orelse {
            tree.nodes[leaf] = .{};
            tree.root = no_node;
            return;
        };
        const sibling = if (tree.nodes[parent].first == leaf) tree.nodes[parent].second else tree.nodes[parent].first;
        tree.nodes[parent] = tree.nodes[sibling];
        tree.nodes[sibling] = .{};
        tree.nodes[leaf] = .{};
    }

    /// Docks an open panel to `side` of `beside`, or of the window with `beside` none, keeping
    /// what it is and giving it half of the space it then splits. Fails with `MissingPanel` when
    /// either is not open; a panel moved beside itself stays where it is.
    pub fn move(tree: *Tree, id: Atom, beside: Atom, side: Side) Error!void {
        if (id == beside) return;
        const index = tree.find(id) orelse return error.MissingPanel;
        if (beside != no_atom and tree.find(beside) == null) return error.MissingPanel;
        const node = tree.nodes[index];
        try tree.close(id);
        try tree.open(.{ .id = id, .title = node.title.slice(), .root = node.root, .owner = node.owner, .beside = beside, .side = side });
    }

    /// The panel after `id` in reading order, wrapping; the first with `id` none or closed.
    pub fn next(tree: *const Tree, id: Atom) ?Atom {
        var order: [kMaxPanels]Atom = undefined;
        const ids = tree.panelIds(&order);
        if (ids.len == 0) return null;
        for (ids, 0..) |candidate, index| {
            if (candidate == id) return ids[(index + 1) % ids.len];
        }
        return ids[0];
    }

    /// The open panels, first to last as the tree reads: left to right, top to bottom. They are
    /// written to `out`, and the result is the part of it written.
    pub fn panelIds(tree: *const Tree, out: *[kMaxPanels]Atom) []Atom {
        var count: usize = 0;
        if (tree.root != no_node) tree.collect(tree.root, out, &count);
        return out[0..count];
    }

    fn collect(tree: *const Tree, index: u8, out: *[kMaxPanels]Atom, count: *usize) void {
        const node = tree.nodes[index];
        if (node.kind == .leaf) {
            out[count.*] = node.id;
            count.* += 1;
            return;
        }
        tree.collect(node.first, out, count);
        tree.collect(node.second, out, count);
    }

    /// How many panels the window shows: one while a panel is maximized.
    pub fn visibleCount(tree: *const Tree) usize {
        if (tree.maximized != no_atom and tree.find(tree.maximized) != null) return 1;
        return tree.panelCount();
    }

    /// Lays the tree out in `window`, writing every node's `frame`, with a gap around and between
    /// panels when there are several. A maximized panel takes the window and the others none; a
    /// maximized panel that is no longer open is forgotten.
    pub fn layout(tree: *Tree, window: Rect) void {
        for (&tree.nodes) |*node| node.frame = .{};
        if (tree.root == no_node) return;
        if (tree.maximized != no_atom) {
            if (tree.find(tree.maximized)) |index| {
                tree.nodes[index].frame = window;
                return;
            }
            tree.maximized = no_atom;
        }
        const area = if (tree.panelCount() > 1) inset(window, kGap) else window;
        tree.place(tree.root, area);
    }

    fn place(tree: *Tree, index: u8, area: Rect) void {
        tree.nodes[index].frame = area;
        const node = tree.nodes[index];
        if (node.kind != .split) return;
        const extent = (if (node.axis == .horizontal) area.w else area.h) - kGap;
        const first_extent = splitExtent(@max(extent, 0), node.share);
        var first = area;
        var second = area;
        if (node.axis == .horizontal) {
            first.w = first_extent;
            second.x = area.x + first_extent + kGap;
            second.w = @max(area.w - first_extent - kGap, 0);
        } else {
            first.h = first_extent;
            second.y = area.y + first_extent + kGap;
            second.h = @max(area.h - first_extent - kGap, 0);
        }
        tree.place(node.first, first);
        tree.place(node.second, second);
    }

    /// The boundaries between split children, as last laid out, written to `out`; none while a
    /// panel is maximized.
    pub fn dividers(tree: *const Tree, out: *[kMaxNodes]Divider) []Divider {
        var count: usize = 0;
        if (tree.maximized != no_atom) return out[0..0];
        for (tree.nodes, 0..) |node, index| {
            if (node.kind != .split or node.frame.empty()) continue;
            const first = tree.nodes[node.first].frame;
            const rect: Rect = if (node.axis == .horizontal)
                .{ .x = first.x + first.w, .y = node.frame.y, .w = kGap, .h = node.frame.h }
            else
                .{ .x = node.frame.x, .y = first.y + first.h, .w = node.frame.w, .h = kGap };
            out[count] = .{ .node = @intCast(index), .axis = node.axis, .rect = rect };
            count += 1;
        }
        return out[0..count];
    }

    /// Moves a split's boundary to `position`, a window coordinate along its axis (x for a
    /// `horizontal` split), keeping both sides usable. Only the share changes: lay the tree out
    /// again to move the frames. Nothing happens for a node that is not a split, a position that
    /// is not finite, or a split with no room.
    pub fn resize(tree: *Tree, split: u8, position: f32) void {
        const node = &tree.nodes[split];
        if (node.kind != .split or !std.math.isFinite(position)) return;
        const start = if (node.axis == .horizontal) node.frame.x else node.frame.y;
        const extent = (if (node.axis == .horizontal) node.frame.w else node.frame.h) - kGap;
        if (extent <= 0) return;
        // The boundary's middle follows the pointer.
        const first_extent = std.math.clamp(position - start - kGap * 0.5, 0, extent);
        node.share = std.math.clamp(first_extent / extent, 0.01, 0.99);
    }

    /// The leaf at node `index` as laid out; `find` gives a panel's index.
    pub fn panel(tree: *const Tree, index: u8) Panel {
        const node = tree.nodes[index];
        return .{ .id = node.id, .title = node.title, .root = node.root, .owner = node.owner, .frame = node.frame };
    }

    /// The node index of the panel shown under a point, if any.
    pub fn panelAt(tree: *const Tree, x: f32, y: f32) ?u8 {
        for (tree.nodes, 0..) |node, index| {
            if (node.kind == .leaf and node.frame.contains(x, y)) return @intCast(index);
        }
        return null;
    }
};

fn inset(rect: Rect, by: f32) Rect {
    return .{ .x = rect.x + by, .y = rect.y + by, .w = @max(rect.w - 2 * by, 0), .h = @max(rect.h - 2 * by, 0) };
}

/// The first child's extent: its share, but at least `kMinExtent` either side while the space
/// allows both, and an even split when it does not.
fn splitExtent(extent: f32, share: f32) f32 {
    if (extent < 2 * kMinExtent) return @floor(extent * 0.5);
    return @round(std.math.clamp(extent * share, kMinExtent, extent - kMinExtent));
}

// ---- storage --------------------------------------------------------------------------------

const NodeRow = struct {
    kind: *u8,
    id: *Atom,
    title: *Title,
    root: *Atom,
    owner: *u8,
    declared_by: *Atom,
    axis: *u8,
    share: *f32,
    first: *u8,
    second: *u8,
    x: *f32,
    y: *f32,
    w: *f32,
    h: *f32,
};

/// A view of the one row of `panels_state`.
pub const State = struct {
    /// The tree's root node index; `no_node` for a window with no panel.
    root: *u8,
    /// The focused panel; none while no panel is open.
    focused: *Atom,
    /// The panel filling the window; none while the arrangement shows.
    maximized: *Atom,
    /// 1 while a press focuses the panel under it and the focused panel is reported; 0 while a
    /// `disable_focus_clicks` request holds.
    focus_clicks_enabled: *u8,
    /// The window's width in pixels, as `relayout` last had it.
    window_w: *f32,
    /// The window's height in pixels, as `relayout` last had it.
    window_h: *f32,
    /// How much of the window's bottom the panels leave free, as for the editor's minibuffer.
    reserved_bottom: *f32,
    /// The split whose boundary a drag holds, `no_node` without one.
    resize_node: *u8,
    /// The split whose boundary the pointer is over, `no_node` without one.
    hover_node: *u8,
};

/// Makes the panels' tables unless they are there: `panels` with its `kMaxNodes` rows,
/// `panels_state`, `panels_redraw`, `panels_hidden`, `panels_focus_history`,
/// `panels_told_sizes`, `commands.panels`, `subscribed.panels` and `events.panels`. The host calls it
/// once, before any other function here; `scratch` allocates the schemas for the call.
pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const allocator = scratch.allocator;
    var node_schema: Table.Schema = undefined;
    try node_schema.init(allocator, atoms, 14);
    defer node_schema.deinit();
    node_schema.addField("kind", u8, .int);
    node_schema.addField("id", Atom, .atom);
    node_schema.addField("title", Title, .text_field);
    node_schema.addField("root", Atom, .atom);
    node_schema.addField("owner", u8, .int);
    node_schema.addField("declared_by", Atom, .atom);
    node_schema.addField("axis", u8, .int);
    node_schema.addField("share", f32, .int);
    node_schema.addField("first", u8, .int);
    node_schema.addField("second", u8, .int);
    node_schema.addField("x", f32, .int);
    node_schema.addField("y", f32, .int);
    node_schema.addField("w", f32, .int);
    node_schema.addField("h", f32, .int);
    const nodes = (try tables.ensure(&node_schema, kMaxNodes, atoms.intern(nodes_table_name), .durable)).table;
    // One row per node slot, so a node's index is its row; a zeroed row is a free node.
    while (nodes.count() < kMaxNodes) {
        const handle = try nodes.alloc();
        nodes.setRowMask(handle, nodes.getRow(handle, NodeRow).?);
    }

    var state_schema: Table.Schema = undefined;
    try state_schema.init(allocator, atoms, 9);
    defer state_schema.deinit();
    state_schema.addField("root", u8, .int);
    state_schema.addField("focused", Atom, .atom);
    state_schema.addField("maximized", Atom, .atom);
    state_schema.addField("focus_clicks_enabled", u8, .int);
    state_schema.addField("window_w", f32, .int);
    state_schema.addField("window_h", f32, .int);
    state_schema.addField("reserved_bottom", f32, .int);
    state_schema.addField("resize_node", u8, .int);
    state_schema.addField("hover_node", u8, .int);
    _ = try tables.ensureSingleton(&state_schema, atoms.intern(state_table_name), .{
        .root = no_node,
        .focused = no_atom,
        .maximized = no_atom,
        .focus_clicks_enabled = @as(u8, 1),
        .window_w = @as(f32, 0),
        .window_h = @as(f32, 0),
        .reserved_bottom = @as(f32, 0),
        .resize_node = no_node,
        .hover_node = no_node,
    }, .durable);

    var redraw_schema: Table.Schema = undefined;
    try redraw_schema.init(allocator, atoms, 1);
    defer redraw_schema.deinit();
    redraw_schema.addField("panel", Atom, .atom);
    _ = try tables.ensure(&redraw_schema, kMaxPanels, atoms.intern(redraw_table_name), .durable);

    var hidden_schema: Table.Schema = undefined;
    try hidden_schema.init(allocator, atoms, 1);
    defer hidden_schema.deinit();
    hidden_schema.addField("panel", Atom, .atom);
    _ = try tables.ensure(&hidden_schema, kMaxPanels, atoms.intern(hidden_table_name), .durable);

    var history_schema: Table.Schema = undefined;
    try history_schema.init(allocator, atoms, 1);
    defer history_schema.deinit();
    history_schema.addField("panel", Atom, .atom);
    _ = try tables.ensure(&history_schema, kMaxPanels, atoms.intern(focus_history_table_name), .durable);

    var told_schema: Table.Schema = undefined;
    try told_schema.init(allocator, atoms, 3);
    defer told_schema.deinit();
    told_schema.addField("panel", Atom, .atom);
    told_schema.addField("frame_width", f32, .int);
    told_schema.addField("frame_height", f32, .int);
    _ = try tables.ensure(&told_schema, kMaxPanels, atoms.intern(told_sizes_table_name), .durable);

    try Requests.ensure(.{ .allocator = allocator }, atoms, tables, plugin.panels.commands_table_name);
    try plugin.panels.Declared.ensure(.{ .allocator = allocator }, atoms, tables, plugin.panels.declared_table_name);

    try plugin.panels.Events.ensure(.{ .allocator = allocator }, atoms, tables, plugin.panels.events_table_name);
}

/// Whether the panel `id` is hidden: a `hide` request named it and no `show` has since.
pub fn isHidden(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) bool {
    const table = tables.findByName(atoms.intern(hidden_table_name)) orelse return false;
    return hiddenRow(table, id) != null;
}

/// The hidden panels, written to `out`, in the order they were hidden.
pub fn hiddenPanels(tables: *Table.Registry, atoms: *Atom.Registry, out: *[kMaxPanels]Atom) []Atom {
    const table = tables.findByName(atoms.intern(hidden_table_name)) orelse return out[0..0];
    var count: usize = 0;
    var rows = table.rows();
    while (rows.next()) |row| {
        if (count == out.len) break;
        out[count] = table.getField(Atom, row, "panel").?.*;
        count += 1;
    }
    return out[0..count];
}

fn hiddenRow(table: *Table, id: Atom) ?Table.RowHandle {
    var rows = table.rows();
    while (rows.next()) |row| {
        if (table.getField(Atom, row, "panel").?.* == id) return row;
    }
    return null;
}

/// Marks the panel `id` hidden or shown; `reconcile` then closes or opens it. Hiding more
/// than `kMaxPanels` panels is refused and logged.
fn setHidden(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom, hidden: enum { hidden, shown }) void {
    const table = tables.findByName(atoms.intern(hidden_table_name)) orelse return;
    const found = hiddenRow(table, id);
    if (hidden == .shown) {
        if (found) |row| table.free(row);
        return;
    }
    if (found != null or id == no_atom) return;
    const handle = table.alloc() catch {
        Log.warn("panel {s} not hidden: too many hidden", .{atoms.lookup(id) orelse ""});
        return;
    };
    table.getField(Atom, handle, "panel").?.* = id;
    table.setFieldPresent(handle, @intCast(table.getSchema().fieldIndex("panel").?));
}

/// Asks for the panel `id` to be drawn again this frame: for a panel whose look changed in a way
/// the host cannot see, such as one showing a table that changed. Nothing happens before
/// `ensure`, or when the table has no room for the request.
pub fn requestRedraw(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) void {
    const table = tables.findByName(atoms.intern(redraw_table_name)) orelse return;
    if (redrawRequested(tables, atoms, id)) return;
    const handle = table.alloc() catch return;
    table.getField(Atom, handle, "panel").?.* = id;
    table.setFieldPresent(handle, @intCast(table.getSchema().fieldIndex("panel").?));
}

/// Asks for every panel to draw again this frame: for a change all of them show, such as
/// another plugin loading.
pub fn requestRedrawAll(tables: *Table.Registry, atoms: *Atom.Registry) void {
    requestRedraw(tables, atoms, no_atom);
}

/// Whether `id` was asked to draw again since the host last drew the panels.
pub fn redrawRequested(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) bool {
    const table = tables.findByName(atoms.intern(redraw_table_name)) orelse return false;
    var rows = table.rows();
    while (rows.next()) |row| {
        const asked = table.getField(Atom, row, "panel").?.*;
        if (asked == id or asked == no_atom) return true;
    }
    return false;
}

/// Forgets the requests, once the host has drawn the panels they asked for.
pub fn clearRedrawRequests(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const table = tables.findByName(atoms.intern(redraw_table_name)) orelse return;
    table.clear();
}

/// The one row of `panels_state`, to read and write. Breaks the invariant `panels.state.present`
/// before `ensure`.
pub fn state(tables: *Table.Registry, atoms: *Atom.Registry) State {
    const t = tables.findByName(atoms.intern(state_table_name)) orelse {
        contract.invariant(false, "panels.state.present");
        unreachable;
    };
    return t.getRow(.{ .row = 0, .generation = t.rowGeneration(0) }, State) orelse {
        contract.invariant(false, "panels.state.row_valid");
        unreachable;
    };
}

fn nodesTable(tables: *Table.Registry, atoms: *Atom.Registry) *Table {
    return tables.findByName(atoms.intern(nodes_table_name)) orelse {
        contract.invariant(false, "panels.nodes.present");
        unreachable;
    };
}

fn nodeRow(table: *Table, index: usize) NodeRow {
    const row: u32 = @intCast(index);
    return table.getRow(.{ .row = row, .generation = table.rowGeneration(row) }, NodeRow) orelse {
        contract.invariant(false, "panels.nodes.row_valid");
        unreachable;
    };
}

/// The stored arrangement as a `Tree`: a copy, which `store` writes back.
pub fn load(tables: *Table.Registry, atoms: *Atom.Registry) Tree {
    const table = nodesTable(tables, atoms);
    const s = state(tables, atoms);
    var tree: Tree = .{ .root = s.root.*, .maximized = s.maximized.* };
    for (&tree.nodes, 0..) |*node, index| {
        const row = nodeRow(table, index);
        node.* = .{
            .kind = std.enums.fromInt(NodeKind, row.kind.*) orelse .free,
            .id = row.id.*,
            .title = row.title.*,
            .root = row.root.*,
            .owner = std.enums.fromInt(Owner, row.owner.*) orelse .plugin,
            .declared_by = row.declared_by.*,
            .axis = std.enums.fromInt(Axis, row.axis.*) orelse .horizontal,
            .share = row.share.*,
            .first = row.first.*,
            .second = row.second.*,
            .frame = .{ .x = row.x.*, .y = row.y.*, .w = row.w.*, .h = row.h.* },
        };
    }
    return tree;
}

/// Writes `tree` over the stored arrangement: every node's row, and the root and the maximized
/// panel of `panels_state`. Frames are stored as the tree has them; `relayoutStored` lays the
/// stored tree out.
pub fn store(tables: *Table.Registry, atoms: *Atom.Registry, tree: *const Tree) void {
    const table = nodesTable(tables, atoms);
    const s = state(tables, atoms);
    s.root.* = tree.root;
    s.maximized.* = tree.maximized;
    for (tree.nodes, 0..) |node, index| {
        const row = nodeRow(table, index);
        row.kind.* = @intFromEnum(node.kind);
        row.id.* = node.id;
        row.title.* = node.title;
        row.root.* = node.root;
        row.owner.* = @intFromEnum(node.owner);
        row.declared_by.* = node.declared_by;
        row.axis.* = @intFromEnum(node.axis);
        row.share.* = node.share;
        row.first.* = node.first;
        row.second.* = node.second;
        row.x.* = node.frame.x;
        row.y.* = node.frame.y;
        row.w.* = node.frame.w;
        row.h.* = node.frame.h;
    }
}

/// `InvalidOwnerState`: the stored tables hold no well-formed arrangement.
pub const ValidationError = error{InvalidOwnerState};

/// Whether the stored tables hold a well-formed arrangement, as tools writing them must leave
/// it: every node slot present, each live node reached once from the root, splits with two
/// children, distinct panel ids, enumerations and shares in range, the focus and the
/// maximized panel open or none, and the focus history distinct and open, without the focused
/// panel.
pub fn validateOwnerState(tables: *Table.Registry, atoms: *Atom.Registry) ValidationError!void {
    const nodes = nodesTable(tables, atoms);
    if (nodes.count() != kMaxNodes) return error.InvalidOwnerState;
    for (0..kMaxNodes) |index| {
        if (!nodes.valid(.{ .row = @intCast(index), .generation = nodes.rowGeneration(@intCast(index)) })) return error.InvalidOwnerState;
        const row = nodeRow(nodes, index);
        if (std.enums.fromInt(NodeKind, row.kind.*) == null) return error.InvalidOwnerState;
        if (std.enums.fromInt(Owner, row.owner.*) == null) return error.InvalidOwnerState;
        if (std.enums.fromInt(Axis, row.axis.*) == null) return error.InvalidOwnerState;
    }
    const s = state(tables, atoms);
    if (s.resize_node.* != no_node and s.resize_node.* >= kMaxNodes) return error.InvalidOwnerState;
    const tree = load(tables, atoms);
    var reached: [kMaxNodes]bool = @splat(false);
    if (tree.root != no_node) {
        if (tree.root >= kMaxNodes) return error.InvalidOwnerState;
        try reach(&tree, tree.root, &reached);
    }
    for (tree.nodes, reached) |node, was_reached| {
        if ((node.kind != .free) != was_reached) return error.InvalidOwnerState;
    }
    var ids: [kMaxPanels]Atom = undefined;
    const open = tree.panelIds(&ids);
    for (open, 0..) |id, index| {
        if (id == no_atom) return error.InvalidOwnerState;
        for (open[index + 1 ..]) |other| {
            if (other == id) return error.InvalidOwnerState;
        }
    }
    if (s.focused.* != no_atom and tree.find(s.focused.*) == null) return error.InvalidOwnerState;
    if (tree.maximized != no_atom and tree.find(tree.maximized) == null) return error.InvalidOwnerState;
    const history = loadHistory(tables, atoms);
    const kept = history.slice();
    for (kept, 0..) |id, index| {
        if (id == no_atom or id == s.focused.* or tree.find(id) == null) return error.InvalidOwnerState;
        if (std.mem.indexOfScalar(Atom, kept[index + 1 ..], id) != null) return error.InvalidOwnerState;
    }
}

fn reach(tree: *const Tree, index: u8, reached: *[kMaxNodes]bool) ValidationError!void {
    if (index >= kMaxNodes or reached[index]) return error.InvalidOwnerState;
    reached[index] = true;
    const node = tree.nodes[index];
    switch (node.kind) {
        .free => return error.InvalidOwnerState,
        .leaf => {},
        .split => {
            if (!std.math.isFinite(node.share) or node.share <= 0 or node.share >= 1) return error.InvalidOwnerState;
            try reach(tree, node.first, reached);
            try reach(tree, node.second, reached);
        },
    }
}

// ---- the host's view ------------------------------------------------------------------------

/// Lays the stored panels out in `window`. The host calls it each frame with the drawable size.
/// It records the size in `panels_state`, leaves `reserved_bottom` of the window's bottom free of
/// panels, and restores the arrangement when the maximized panel is not the focused one. A size
/// that is negative, not finite or past `kMaxWindowExtent` is ignored.
pub fn relayout(tables: *Table.Registry, atoms: *Atom.Registry, window: Rect) void {
    if (!std.math.isFinite(window.w) or !std.math.isFinite(window.h) or window.w < 0 or window.h < 0 or window.w > kMaxWindowExtent or window.h > kMaxWindowExtent) {
        Log.debug("ignoring invalid window size", .{});
        return;
    }
    const s = state(tables, atoms);
    s.window_w.* = window.w;
    s.window_h.* = window.h;
    // The panels have the window less what is reserved along its bottom.
    var area = window;
    area.h = @max(window.h - s.reserved_bottom.*, 0);
    var tree = load(tables, atoms);
    tree.layout(area);
    // A maximized panel stays so only while it keeps the focus.
    if (tree.maximized != no_atom and tree.maximized != s.focused.*) {
        tree.maximized = no_atom;
        tree.layout(area);
    }
    store(tables, atoms, &tree);
}

/// Lays the stored tree out again in the window it last had. The runtime's, which this file
/// uses too; not part of what a plugin relies on.
pub fn relayoutStored(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const s = state(tables, atoms);
    relayout(tables, atoms, .{ .w = s.window_w.*, .h = s.window_h.* });
}

/// The shown panels, first to last as the tree reads. Hidden panels behind a maximized one are
/// left out.
pub fn panels(tables: *Table.Registry, atoms: *Atom.Registry, out: *[kMaxPanels]Panel) []Panel {
    const tree = load(tables, atoms);
    var ids: [kMaxPanels]Atom = undefined;
    var count: usize = 0;
    for (tree.panelIds(&ids)) |id| {
        const index = tree.find(id).?;
        const shown = tree.panel(index);
        if (shown.frame.empty()) continue;
        out[count] = shown;
        count += 1;
    }
    return out[0..count];
}

/// The open panel `id` as laid out, or null when it is not open. One a maximized panel hides has
/// an empty frame.
pub fn panelFor(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) ?Panel {
    const tree = load(tables, atoms);
    const index = tree.find(id) orelse return null;
    return tree.panel(index);
}

/// Whether the panel `id` is open, shown or hidden behind a maximized one.
pub fn isOpen(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) bool {
    return load(tables, atoms).find(id) != null;
}

/// Whether `id` has the focus, and so the keyboard.
pub fn hasFocus(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) bool {
    return id != no_atom and focusedTarget(tables, atoms).id == id;
}

/// Whether the panel `id` fills the window.
pub fn isMaximized(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) bool {
    return state(tables, atoms).maximized.* == id and id != no_atom;
}

/// The focused panel and its owner, as `focusedTarget` reports them and `dispatchFocusChanges`
/// remembers them between calls.
pub const FocusTarget = struct {
    /// The focused panel; none when nothing is focused or focus clicks are suspended.
    id: Atom = no_atom,
    /// The focused panel's owner; null without a focused panel.
    owner: ?Owner = null,
    /// Whether `dispatchFocusChanges` has published this target. `focusedTarget` leaves it false.
    notified: bool = false,
};

/// The focused panel, or none while focus clicks are suspended, as a modal prompt does.
pub fn focusedTarget(tables: *Table.Registry, atoms: *Atom.Registry) FocusTarget {
    const s = state(tables, atoms);
    if (s.focus_clicks_enabled.* != 1) return .{};
    const tree = load(tables, atoms);
    const index = tree.find(s.focused.*) orelse return .{};
    return .{ .id = s.focused.*, .owner = tree.nodes[index].owner };
}

/// The owner of the focused panel, whose local input subscriptions fire.
pub fn focusedOwner(tables: *Table.Registry, atoms: *Atom.Registry) ?Owner {
    return focusedTarget(tables, atoms).owner;
}

/// The focus history as a value, oldest first: what `panels_focus_history` holds, loaded to be
/// changed and stored back whole (`loadHistory`, `storeHistory`).
const History = struct {
    ids: [kMaxPanels]Atom = undefined,
    len: usize = 0,

    fn slice(history: *const History) []const Atom {
        return history.ids[0..history.len];
    }

    fn remove(history: *History, id: Atom) void {
        const index = std.mem.indexOfScalar(Atom, history.ids[0..history.len], id) orelse return;
        std.mem.copyForwards(Atom, history.ids[index .. history.len - 1], history.ids[index + 1 .. history.len]);
        history.len -= 1;
    }

    /// Makes `id` the newest entry, moving it there when it is in already; with the history
    /// full, the oldest goes.
    fn push(history: *History, id: Atom) void {
        history.remove(id);
        if (history.len == history.ids.len) history.remove(history.ids[0]);
        history.ids[history.len] = id;
        history.len += 1;
    }

    /// Drops the entries of panels not open in `tree`, as a panel's id may be used again by
    /// another that opens later. Returns whether any went.
    fn dropClosed(history: *History, tree: *const Tree) bool {
        var kept: usize = 0;
        for (history.ids[0..history.len]) |id| {
            if (tree.find(id) == null) continue;
            history.ids[kept] = id;
            kept += 1;
        }
        const dropped = kept != history.len;
        history.len = kept;
        return dropped;
    }

    /// The newest entry open in `tree` and not hidden, which stays in; the newer entries of
    /// panels closed or hidden are dropped on the way. Null, the history then empty, with none.
    fn newestOpen(history: *History, tables: *Table.Registry, atoms: *Atom.Registry, tree: *const Tree) ?Atom {
        while (history.len > 0) {
            const newest = history.ids[history.len - 1];
            const open = tree.find(newest) != null and !isHidden(tables, atoms, newest);
            if (open) return newest;
            history.len -= 1;
        }
        return null;
    }
};

/// The stored focus history; empty before `ensure`.
fn loadHistory(tables: *Table.Registry, atoms: *Atom.Registry) History {
    var history: History = .{};
    const table = tables.findByName(atoms.intern(focus_history_table_name)) orelse return history;
    var rows = table.rows();
    while (rows.next()) |row| {
        if (history.len == history.ids.len) break;
        history.ids[history.len] = table.getField(Atom, row, "panel").?.*;
        history.len += 1;
    }
    return history;
}

/// Writes `history` over the stored one. The table is emptied and filled again in order, since
/// freeing one row would move the last into its place.
fn storeHistory(tables: *Table.Registry, atoms: *Atom.Registry, history: *const History) void {
    const table = tables.findByName(atoms.intern(focus_history_table_name)) orelse return;
    table.clear();
    for (history.slice()) |id| {
        _ = table.tryInsert(.{ .panel = id }) catch |err| {
            Log.warn("focus history not kept: {s}", .{@errorName(err)});
            return;
        };
    }
}

/// The focus history (`panels_focus_history`), oldest first, written to `out`.
pub fn focusHistory(tables: *Table.Registry, atoms: *Atom.Registry, out: *[kMaxPanels]Atom) []Atom {
    const history = loadHistory(tables, atoms);
    @memcpy(out[0..history.len], history.slice());
    return out[0..history.len];
}

/// Gives the focus to `id`, open in `tree`, and makes the panel that had it, while it is open
/// there, the newest of the history. Every change of the focus from one panel to another goes
/// through here: a request, a press, a panel opening with the focus. Only `repairFocus` sets it
/// otherwise, for a focused panel that is gone. Nothing happens for a panel not open in `tree`,
/// or the focused one.
fn moveFocus(tables: *Table.Registry, atoms: *Atom.Registry, tree: *const Tree, id: Atom) void {
    if (tree.find(id) == null) return;
    const s = state(tables, atoms);
    const previous = s.focused.*;
    if (previous == id) return;
    var history = loadHistory(tables, atoms);
    history.remove(id);
    const previous_open = previous != no_atom and tree.find(previous) != null;
    if (previous_open) history.push(previous);
    storeHistory(tables, atoms, &history);
    s.focused.* = id;
}

/// Keeps the focus on an open panel: when the focused one closed or was hidden, the newest of
/// the history still open takes it, and with none the first in reading order. The entries of
/// panels that closed are dropped.
fn repairFocus(tables: *Table.Registry, atoms: *Atom.Registry, tree: *const Tree) void {
    const s = state(tables, atoms);
    var history = loadHistory(tables, atoms);
    const dropped = history.dropClosed(tree);
    if (tree.find(s.focused.*) != null) {
        if (dropped) storeHistory(tables, atoms, &history);
        return;
    }
    const restored = history.newestOpen(tables, atoms, tree);
    if (restored) |id| history.remove(id);
    storeHistory(tables, atoms, &history);
    s.focused.* = restored orelse tree.next(no_atom) orelse no_atom;
}

/// Focuses the panel under a press at (`x`, `y`). Returns whether one was there; a press on a
/// divider, or any press while focus clicks are suspended, changes nothing.
pub fn onMousePress(tables: *Table.Registry, atoms: *Atom.Registry, x: f32, y: f32) bool {
    const s = state(tables, atoms);
    if (s.focus_clicks_enabled.* != 1) return false;
    if (dividerAt(tables, atoms, x, y) != null) return false;
    const tree = load(tables, atoms);
    const index = tree.panelAt(x, y) orelse return false;
    moveFocus(tables, atoms, &tree, tree.nodes[index].id);
    return true;
}

/// The requests to the panels system, `commands.panels`.
pub const Requests = plugin.panels.Requests;

/// Applies one request to the stored arrangement and lays it out again; the host's panels system
/// calls it for each row of `commands.panels`. A request that fails (see `Error`) changes nothing
/// and is logged as a warning. After a request the focus is on an open panel: when the focused
/// one closed, the newest of the focus history still open, else the first.
pub fn applyCmd(tables: *Table.Registry, atoms: *Atom.Registry, cmd: plugin.panels.CmdPayload) void {
    apply(tables, atoms, cmd) catch |err| Log.warn("panels command {s} failed: {s}", .{ @tagName(cmd), @errorName(err) });
}

fn apply(tables: *Table.Registry, atoms: *Atom.Registry, cmd: plugin.panels.CmdPayload) Error!void {
    const s = state(tables, atoms);
    var tree = load(tables, atoms);
    switch (cmd) {
        .close_all => {
            tree = .{};
            s.focused.* = no_atom;
            s.resize_node.* = no_node;
            s.hover_node.* = no_node;
            storeHistory(tables, atoms, &.{});
        },
        .move => |request| try tree.move(request.id, request.beside, request.side),
        .focus => |request| moveFocus(tables, atoms, &tree, request.id),
        .focus_previous => |request| {
            // The person may have moved the focus on since the request was made.
            if (request.from != s.focused.*) return;
            var history = loadHistory(tables, atoms);
            const previous = history.newestOpen(tables, atoms, &tree);
            storeHistory(tables, atoms, &history);
            if (previous) |id| moveFocus(tables, atoms, &tree, id);
        },
        .focus_next => {
            if (tree.maximized == no_atom) {
                if (tree.next(s.focused.*)) |id| moveFocus(tables, atoms, &tree, id);
            }
        },
        .toggle_maximize => {
            tree.maximized = if (tree.maximized != no_atom) no_atom else s.focused.*;
        },
        .enable_focus_clicks => s.focus_clicks_enabled.* = 1,
        .disable_focus_clicks => s.focus_clicks_enabled.* = 0,
        .reserve_bottom => |request| {
            const height_valid = std.math.isFinite(request.height) and request.height >= 0;
            if (!height_valid) return error.InvalidReserve;
            s.reserved_bottom.* = request.height;
        },
        // Only the mark changes here: `reconcile` closes and opens by it.
        .hide => |request| return setHidden(tables, atoms, request.id, .hidden),
        .show => |request| return setHidden(tables, atoms, request.id, .shown),
    }
    settle(tables, atoms, &tree);
}

/// Stores a changed `tree` and lays it out, with the focus on an open panel (`repairFocus`),
/// the told sizes of closed panels forgotten, and no drag left holding a split that is gone.
fn settle(tables: *Table.Registry, atoms: *Atom.Registry, tree: *const Tree) void {
    const s = state(tables, atoms);
    repairFocus(tables, atoms, tree);
    // A panel closed here and opened again before the sizes are told is told afresh.
    if (tables.findByName(atoms.intern(told_sizes_table_name))) |told| forgetClosedSizes(told, tree);
    if (s.resize_node.* != no_node and tree.nodes[s.resize_node.*].kind != .split) s.resize_node.* = no_node;
    store(tables, atoms, tree);
    relayoutStored(tables, atoms);
}

/// Opens `panel` at once and lays the arrangement out, taking the focus when its placement
/// says so or when it is the only panel: for a panel the host opens of itself, and for a test
/// that arranges a window with no system to declare it. It is no system's, so no declaration
/// closes it; `closeNow` does. One already open stays as it is. A panel that cannot open (see
/// `Error`) changes nothing and is logged as a warning.
pub fn openNow(tables: *Table.Registry, atoms: *Atom.Registry, panel: plugin.panels.Open) void {
    var tree = load(tables, atoms);
    tree.open(panel) catch |err| {
        Log.warn("panel {s} did not open: {s}", .{ atoms.lookup(panel.id) orelse "", @errorName(err) });
        return;
    };
    if (panel.focus == .take or tree.panelCount() == 1) moveFocus(tables, atoms, &tree, panel.id);
    settle(tables, atoms, &tree);
}

/// Closes the panel `id` at once and lays the arrangement out; when it had the focus, the
/// focus goes to the newest of the focus history still open, else the first open panel.
/// Nothing happens for one that is not open. A panel a system still declares opens again with
/// the frame.
pub fn closeNow(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) void {
    var tree = load(tables, atoms);
    tree.close(id) catch return;
    settle(tables, atoms, &tree);
}

/// What `applyFrame` did that its caller acts on.
pub const Applied = struct {
    /// Whether every panel was closed (`close_all`): a pointer captured in one is to be let
    /// go.
    closed_all: bool = false,
};

/// The panels system's part of a frame, after the systems have run: every panel closes if a
/// request says so (`close_all`) and the panels asked hidden or shown are marked (`hide`,
/// `show`), then the panels the systems declare open and close (`reconcile`), then the other
/// requests are applied in order, and all of them are forgotten. So an arrangement asked for
/// afresh is laid out in the frame that asks, from what is declared in it and not hidden,
/// and a request may name a panel declared in the same frame. The host's panels system calls
/// it after each dispatch.
pub fn applyFrame(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry) Applied {
    var applied: Applied = .{};
    const requests = Requests.of(memory, tables, plugin.panels.commands_table_name);
    var asked = requests.iterate();
    while (asked.next()) |request| {
        if (request == .close_all) applied.closed_all = true;
    }
    if (applied.closed_all) applyCmd(tables, atoms, .close_all);
    var marks = requests.iterate();
    while (marks.next()) |request| {
        if (request == .hide or request == .show) applyCmd(tables, atoms, request);
    }
    reconcile(memory, tables, atoms);
    var rows = requests.iterate();
    while (rows.next()) |request| {
        const applied_already = request == .close_all or request == .hide or request == .show;
        if (!applied_already) applyCmd(tables, atoms, request);
    }
    requests.reset();
    return applied;
}

/// Brings the arrangement in step with `subscribed.panels`, the panels the systems declare
/// (`plugin.panels.declare`); `applyFrame` calls it before it applies the requests.
///
/// A hidden panel (`isHidden`) is closed and stays closed, whatever declares it. Any other
/// declared panel that is not open opens by its declaration's placement, along the window's
/// edge when the panel it names to open beside is not open, taking the focus when its
/// declaration says so or when it is the only panel. One that is open keeps its place and takes
/// its declaration's title, root and owner. A panel a declaration opened closes once no
/// row declares it and the system that declared it has run since the subscriptions were last
/// reset: until then, as while its plugin is being loaded again, its rows are only missing,
/// and it stays where it is. A panel the host opened itself (`openNow`) is left alone.
///
/// The first row for an id is followed and a later one logged; a panel that cannot open (see
/// `Error`) is logged each frame it is declared.
pub fn reconcile(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry) void {
    var tree = load(tables, atoms);
    var changed = false;
    var declared_ids: [kMaxPanels]Atom = undefined;
    var declared_count: usize = 0;
    var rows = plugin.panels.Declared.of(memory, tables, plugin.panels.declared_table_name).iterate();
    while (rows.next()) |declared| {
        const already_declared = std.mem.indexOfScalar(Atom, declared_ids[0..declared_count], declared.id) != null;
        if (already_declared) {
            Log.warn("panel declared twice: {s}", .{atoms.lookup(declared.id) orelse ""});
            continue;
        }
        const declarer = rows.subscriber();
        if (isHidden(tables, atoms, declared.id)) {
            if (tree.find(declared.id) != null) {
                tree.close(declared.id) catch {};
                changed = true;
            }
            continue;
        }
        if (tree.find(declared.id)) |index| {
            const node = &tree.nodes[index];
            const title = Title.from(declared.title);
            const same = node.title.eql(title) and node.root == declared.root and node.owner == declared.owner and node.declared_by == declarer;
            if (!same) {
                node.title = title;
                node.root = declared.root;
                node.owner = declared.owner;
                node.declared_by = declarer;
                changed = true;
            }
        } else {
            // What it would open beside may have closed since its system chose it.
            var placed = declared;
            if (placed.beside != no_atom and tree.find(placed.beside) == null) placed.beside = no_atom;
            tree.open(placed) catch |err| {
                Log.warn("declared panel {s} did not open: {s}", .{ atoms.lookup(declared.id) orelse "", @errorName(err) });
                continue;
            };
            tree.nodes[tree.find(declared.id).?].declared_by = declarer;
            if (declared.focus == .take or tree.panelCount() == 1) moveFocus(tables, atoms, &tree, declared.id);
            changed = true;
        }
        if (declared_count < declared_ids.len) {
            declared_ids[declared_count] = declared.id;
            declared_count += 1;
        }
    }
    var open_ids: [kMaxPanels]Atom = undefined;
    for (tree.panelIds(&open_ids)) |id| {
        const declarer = tree.nodes[tree.find(id).?].declared_by;
        if (declarer == no_atom) continue;
        const still_declared = std.mem.indexOfScalar(Atom, declared_ids[0..declared_count], id) != null;
        if (still_declared) continue;
        // Its system has not said what it shows since the reset: the row is only missing.
        if (!sequencer.subscribedSinceReset(tables, declarer)) continue;
        tree.close(id) catch continue;
        changed = true;
    }
    if (changed) settle(tables, atoms, &tree);
}

/// Publishes to `events.panels` that the focus moved since `previous`, which it then records; the
/// first call publishes the focused panel regardless. The host calls it each frame.
pub fn dispatchFocusChanges(tables: *Table.Registry, atoms: *Atom.Registry, previous: *FocusTarget) void {
    const current = focusedTarget(tables, atoms);
    if (previous.notified and previous.id == current.id) return;
    defer {
        previous.* = current;
        previous.notified = true;
    }
    const events = plugin.panels.Events.of(tables, plugin.panels.events_table_name);
    if (previous.notified and previous.id != no_atom) events.publish(.{ .unfocused = previous.id });
    if (current.id != no_atom) events.publish(.{ .focused = current.id });
}

const ToldRow = struct { panel: *Atom, frame_width: *f32, frame_height: *f32 };

/// Publishes to `events.panels` a `resized` for each open panel whose frame, as last laid out,
/// is not the size it was last told (`panels_told_sizes`), which it then records: a panel newly
/// open is told its first size, and nothing is published when nothing changed. A closed
/// panel's record is forgotten. Every change of layout passes by here, whatever made it, so
/// the host calls it once in each pump after the frame's requests are applied and the
/// dividers dragged, before the plugins' systems run, which hear it in that run.
pub fn dispatchResizes(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const told = tables.findByName(atoms.intern(told_sizes_table_name)) orelse return;
    const tree = load(tables, atoms);
    forgetClosedSizes(told, &tree);

    const events = plugin.panels.Events.of(tables, plugin.panels.events_table_name);
    var ids: [kMaxPanels]Atom = undefined;
    for (tree.panelIds(&ids)) |id| {
        const frame = tree.nodes[tree.find(id).?].frame;
        const record = toldRecord(told, id);
        if (record) |kept| {
            const same = kept.frame_width.* == frame.w and kept.frame_height.* == frame.h;
            if (same) continue;
            kept.frame_width.* = frame.w;
            kept.frame_height.* = frame.h;
        } else {
            _ = told.tryInsert(.{ .panel = id, .frame_width = frame.w, .frame_height = frame.h }) catch |err| {
                Log.warn("panel {s} size not kept: {s}", .{ atoms.lookup(id) orelse "", @errorName(err) });
                continue;
            };
        }
        events.publish(.{ .resized = .{ .panel = id, .frame_width = frame.w, .frame_height = frame.h } });
    }
}

/// Frees the records of `panels_told_sizes` of panels not open in `tree`: a panel that opens
/// again, even under the same id in the same place, is told its first size.
fn forgetClosedSizes(told: *Table, tree: *const Tree) void {
    var closed: [kMaxPanels]Table.RowHandle = undefined;
    var closed_count: usize = 0;
    var records = told.query(ToldRow);
    while (records.next()) |found| {
        if (tree.find(found.view.panel.*) != null or closed_count == closed.len) continue;
        closed[closed_count] = found.handle;
        closed_count += 1;
    }
    for (closed[0..closed_count]) |handle| told.free(handle);
}

/// The size `id` was last told, from `panels_told_sizes`; null for a panel never told.
fn toldRecord(told: *Table, id: Atom) ?ToldRow {
    var records = told.query(ToldRow);
    while (records.next()) |found| {
        if (found.view.panel.* == id) return found.view;
    }
    return null;
}

// ---- resizing -------------------------------------------------------------------------------

/// The boundaries between split children of the stored arrangement, as last laid out, written to
/// `out`; none while a panel is maximized.
pub fn dividers(tables: *Table.Registry, atoms: *Atom.Registry, out: *[kMaxNodes]Divider) []Divider {
    const tree = load(tables, atoms);
    var found: [kMaxNodes]Divider = undefined;
    const list = tree.dividers(&found);
    @memcpy(out[0..list.len], list);
    return out[0..list.len];
}

/// The divider of the stored arrangement under a point, if any.
pub fn dividerAt(tables: *Table.Registry, atoms: *Atom.Registry, x: f32, y: f32) ?Divider {
    var found: [kMaxNodes]Divider = undefined;
    for (dividers(tables, atoms, &found)) |divider| {
        if (divider.rect.contains(x, y)) return divider;
    }
    return null;
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const test_window: Rect = .{ .w = 1000, .h = 600 };

fn openTest(tree: *Tree, id: []const u8, beside: []const u8, side: Side) !void {
    try tree.open(.{ .id = Atom.from(id), .root = Atom.from(id), .beside = if (beside.len == 0) no_atom else Atom.from(beside), .side = side });
}

fn frameOf(tree: *const Tree, id: []const u8) Rect {
    return tree.nodes[tree.find(Atom.from(id)).?].frame;
}

test "a title too long is cut at a character's start" {
    const short = Title.from("Layers");
    try std.testing.expectEqualStrings("Layers", short.slice());
    // 63 bytes, then a two-byte character that would straddle the end.
    const long = Title.from("a" ** 63 ++ "\u{e9}" ++ "tail");
    try std.testing.expectEqualStrings("a" ** 63, long.slice());
}

test "a panel opens to any side of the one asking, splitting its space" {
    var tree: Tree = .{};
    try openTest(&tree, "stage", "", .right);
    tree.layout(test_window);
    // Alone, the stage takes the test_window.
    try testing.expectEqual(test_window, frameOf(&tree, "stage"));
    try openTest(&tree, "layers", "stage", .left);
    try openTest(&tree, "timeline", "stage", .bottom);
    tree.layout(test_window);
    const layers = frameOf(&tree, "layers");
    const stage = frameOf(&tree, "stage");
    const timeline = frameOf(&tree, "timeline");
    try testing.expect(layers.x + layers.w <= stage.x);
    try testing.expect(stage.y + stage.h <= timeline.y);
    try testing.expectEqual(stage.x, timeline.x);
    try testing.expectEqual(stage.w, timeline.w);
    var ids: [kMaxPanels]Atom = undefined;
    try testing.expectEqualSlices(Atom, &.{ Atom.from("layers"), Atom.from("stage"), Atom.from("timeline") }, tree.panelIds(&ids));
}

test "opening along the window's edge spans the whole arrangement" {
    var tree: Tree = .{};
    try openTest(&tree, "stage", "", .right);
    try openTest(&tree, "properties", "stage", .right);
    try openTest(&tree, "status", "", .bottom);
    tree.layout(test_window);
    const status = frameOf(&tree, "status");
    try testing.expectEqual(kGap, status.x);
    try testing.expectEqual(test_window.w - 2 * kGap, status.w);
}

test "closing a panel gives its space back to its sibling" {
    var tree: Tree = .{};
    try openTest(&tree, "stage", "", .right);
    try openTest(&tree, "layers", "stage", .left);
    try openTest(&tree, "properties", "stage", .right);
    try tree.close(Atom.from("stage"));
    tree.layout(test_window);
    try testing.expectEqual(@as(usize, 2), tree.panelCount());
    const layers = frameOf(&tree, "layers");
    const properties = frameOf(&tree, "properties");
    try testing.expectApproxEqAbs(test_window.w - 3 * kGap, layers.w + properties.w, 1);
    try tree.close(Atom.from("layers"));
    try tree.close(Atom.from("properties"));
    try testing.expectEqual(@as(u8, no_node), tree.root);
    try testing.expectError(error.MissingPanel, tree.close(Atom.from("layers")));
}

test "moving a panel docks it to another side, and maximizing hides the rest" {
    var tree: Tree = .{};
    try openTest(&tree, "stage", "", .right);
    try openTest(&tree, "layers", "stage", .left);
    try tree.move(Atom.from("layers"), Atom.from("stage"), .bottom);
    tree.layout(test_window);
    try testing.expect(frameOf(&tree, "layers").y > frameOf(&tree, "stage").y);
    tree.maximized = Atom.from("layers");
    tree.layout(test_window);
    try testing.expectEqual(test_window, frameOf(&tree, "layers"));
    try testing.expect(frameOf(&tree, "stage").empty());
    var found: [kMaxNodes]Divider = undefined;
    try testing.expectEqual(@as(usize, 0), tree.dividers(&found).len);
}

test "a divider drags within the least either side may take" {
    var tree: Tree = .{};
    try openTest(&tree, "stage", "", .right);
    try openTest(&tree, "properties", "stage", .right);
    tree.layout(test_window);
    var found: [kMaxNodes]Divider = undefined;
    const divider = tree.dividers(&found)[0];
    tree.resize(divider.node, 300);
    tree.layout(test_window);
    try testing.expectApproxEqAbs(@as(f32, 300 - kGap * 0.5 - kGap), frameOf(&tree, "stage").w, 1);
    tree.resize(divider.node, 5);
    tree.layout(test_window);
    try testing.expectEqual(kMinExtent, frameOf(&tree, "stage").w);
}

test "focus moves through panels in reading order and opening an open panel keeps it" {
    var tree: Tree = .{};
    try openTest(&tree, "stage", "", .right);
    try openTest(&tree, "layers", "stage", .left);
    try testing.expectEqual(Atom.from("stage"), tree.next(Atom.from("layers")).?);
    try testing.expectEqual(Atom.from("layers"), tree.next(Atom.from("stage")).?);
    try openTest(&tree, "layers", "stage", .bottom);
    try testing.expectEqual(@as(usize, 2), tree.panelCount());
    try testing.expectError(error.MissingPanel, openTest(&tree, "other", "missing", .left));
    try testing.expectError(error.InvalidShare, tree.open(.{ .id = Atom.from("x"), .root = Atom.from("x"), .beside = Atom.from("stage"), .share = 1 }));
}

/// Panels over tables of their own, for tests here, the editor's and the runtime's. It
/// exists only in a test build: it is built on `std.testing.allocator`, and is no part of
/// what a plugin builds on.
pub const Fixture = if (@import("builtin").is_test) TestFixture else void;

const TestFixture = struct {
    /// The memory the registries below are made in.
    mem: memory_mod.Memory = undefined,
    /// The fixture's atoms.
    atoms: Atom.Registry = undefined,
    /// The fixture's tables: the panels' own, laid out in a 1000 by 600 window.
    tables: Table.Registry = undefined,

    /// Makes the registries and the panels' tables on `std.testing.allocator`. Call `deinit`
    /// after.
    pub fn init(self: *TestFixture) !void {
        self.mem.init(std.testing.allocator);
        errdefer self.mem.deinit();
        try self.atoms.init(&self.mem);
        errdefer self.atoms.deinit();
        try self.tables.init(&self.mem, 8);
        errdefer self.tables.deinit();
        try ensure(try self.mem.tableScratchAllocator(), &self.atoms, &self.tables);
        relayout(&self.tables, &self.atoms, test_window);
    }

    /// Frees everything `init` made.
    pub fn deinit(self: *TestFixture) void {
        self.tables.deinit();
        self.atoms.deinit();
        self.mem.deinit();
    }

    /// Applies `payload` at once, as the panels system applies a row of `commands.panels`.
    pub fn command(self: *TestFixture, payload: plugin.panels.CmdPayload) void {
        applyCmd(&self.tables, &self.atoms, payload);
    }
};

test "commands keep the stored tree, its focus and its owners" {
    var fx: Fixture = .{};
    try fx.init();
    defer fx.deinit();
    const stage = Atom.from("stage");
    const editor = Atom.from("profiler");
    openNow(&fx.tables, &fx.atoms, .{ .id = stage, .root = stage, .owner = .game });
    openNow(&fx.tables, &fx.atoms, .{ .id = editor, .root = editor, .beside = stage, .side = .left, .share = 0.4 });
    try testing.expectEqual(editor, focusedTarget(&fx.tables, &fx.atoms).id);
    try testing.expectEqual(Owner.plugin, focusedOwner(&fx.tables, &fx.atoms).?);
    var shown: [kMaxPanels]Panel = undefined;
    const list = panels(&fx.tables, &fx.atoms, &shown);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqual(editor, list[0].id);
    try testing.expectApproxEqAbs(@as(f32, (test_window.w - 3 * kGap) * 0.4), list[0].frame.w, 1);
    // A press focuses the panel under it; the stage belongs to the game.
    const stage_frame = panelFor(&fx.tables, &fx.atoms, stage).?.frame;
    try testing.expect(onMousePress(&fx.tables, &fx.atoms, stage_frame.x + 10, stage_frame.y + 10));
    try testing.expectEqual(Owner.game, focusedOwner(&fx.tables, &fx.atoms).?);
    // Suspended focus clicks leave nothing focused for input.
    fx.command(.disable_focus_clicks);
    try testing.expectEqual(@as(?Owner, null), focusedOwner(&fx.tables, &fx.atoms));
    fx.command(.enable_focus_clicks);
    // Closing the focused panel moves the focus to one still open.
    closeNow(&fx.tables, &fx.atoms, stage);
    try testing.expectEqual(editor, focusedTarget(&fx.tables, &fx.atoms).id);
    // Closing every panel leaves the window empty, for its owner to lay out afresh.
    fx.command(.close_all);
    try testing.expect(!isOpen(&fx.tables, &fx.atoms, editor));
    try testing.expectEqual(no_atom, focusedTarget(&fx.tables, &fx.atoms).id);
}

/// Declares `declared` as the system `declarer`'s panels of this frame, as its run would: its
/// rows replace the ones it had, each names it, and it has subscribed since the last reset.
fn declareAs(fx: *Fixture, declarer: Atom, declared: []const plugin.panels.Open) !void {
    const rows = plugin.panels.Declared.of(&fx.mem, &fx.tables, plugin.panels.declared_table_name);
    rows.reset();
    for (declared) |panel| try rows.tryPush(panel);
    const table = fx.tables.findByName(Atom.from(plugin.panels.declared_table_name)).?;
    var handles = table.rows();
    while (handles.next()) |row| try table.writeFieldSingle(Atom, row, sequencer.subscriber_field, declarer);
    try noteSubscribed(fx, declarer);
}

/// Records that `declarer` has run since the subscriptions were last reset, as the sequencer
/// does when a system's run finishes.
fn noteSubscribed(fx: *Fixture, declarer: Atom) !void {
    const Subscriber = struct { system: *Atom, epoch: *u64 };
    const known = fx.tables.findByName(Atom.from(sequencer.subscribers_table_name)).?;
    var latest: u64 = 0;
    var own: ?Subscriber = null;
    var rows = known.query(Subscriber);
    while (rows.next()) |found| {
        if (found.view.system.* == no_atom) latest = found.view.epoch.*;
        if (found.view.system.* == declarer) own = found.view;
    }
    if (own) |row| {
        row.epoch.* = latest;
        return;
    }
    _ = try known.tryInsert(.{ .system = declarer, .epoch = latest });
}

test "a declared panel opens where it says, follows its row, and closes once its system stops declaring it" {
    var fx: Fixture = .{};
    try fx.init();
    defer fx.deinit();
    const owner = Atom.from("test_panels_owner");
    const stage = Atom.from("stage");
    const layers = Atom.from("layers");
    const profiler = Atom.from("profiler");
    const stage_panel: plugin.panels.Open = .{ .id = stage, .root = stage, .owner = .game };
    const layers_panel: plugin.panels.Open = .{ .id = layers, .root = layers, .title = "Layers", .beside = stage, .side = .left, .share = 0.3, .focus = .keep };

    // Declared, both open: the second where its row says, without the focus.
    try declareAs(&fx, owner, &.{ stage_panel, layers_panel });
    reconcile(&fx.mem, &fx.tables, &fx.atoms);
    const layers_frame = panelFor(&fx.tables, &fx.atoms, layers).?.frame;
    const stage_frame = panelFor(&fx.tables, &fx.atoms, stage).?.frame;
    try testing.expect(layers_frame.x + layers_frame.w <= stage_frame.x);
    try testing.expectApproxEqAbs(@as(f32, (test_window.w - 3 * kGap) * 0.3), layers_frame.w, 1);
    try testing.expectEqual(stage, focusedTarget(&fx.tables, &fx.atoms).id);
    try testing.expectEqual(Owner.game, focusedOwner(&fx.tables, &fx.atoms).?);

    // A person docks it elsewhere; declared again, with another title, it stays there.
    fx.command(.{ .move = .{ .id = layers, .beside = stage, .side = .bottom } });
    var renamed = layers_panel;
    renamed.title = "Layers of blue";
    try declareAs(&fx, owner, &.{ stage_panel, renamed, renamed });
    reconcile(&fx.mem, &fx.tables, &fx.atoms);
    const docked = panelFor(&fx.tables, &fx.atoms, layers).?;
    try testing.expect(docked.frame.y > panelFor(&fx.tables, &fx.atoms, stage).?.frame.y);
    try testing.expectEqualStrings("Layers of blue", docked.title.slice());
    // The row declared twice opened one panel.
    try testing.expectEqual(@as(usize, 2), load(&fx.tables, &fx.atoms).panelCount());

    // A panel the host opened itself is not the declarations' to close.
    openNow(&fx.tables, &fx.atoms, .{ .id = profiler, .root = profiler, .focus = .keep });

    // The subscriptions are reset, as when a plugin loads: the rows are only missing.
    sequencer.resetSubscriptions(&fx.tables);
    reconcile(&fx.mem, &fx.tables, &fx.atoms);
    try testing.expect(isOpen(&fx.tables, &fx.atoms, layers));
    try testing.expect(isOpen(&fx.tables, &fx.atoms, stage));

    // Its system runs again and declares the stage alone: the other closes, and the focus
    // it never had stays on the stage.
    try declareAs(&fx, owner, &.{stage_panel});
    reconcile(&fx.mem, &fx.tables, &fx.atoms);
    try testing.expect(!isOpen(&fx.tables, &fx.atoms, layers));
    try testing.expect(isOpen(&fx.tables, &fx.atoms, stage));
    try testing.expect(isOpen(&fx.tables, &fx.atoms, profiler));
    try validateOwnerState(&fx.tables, &fx.atoms);

    // Declaring nothing closes the last of its panels; the request's panel takes the focus.
    try declareAs(&fx, owner, &.{});
    reconcile(&fx.mem, &fx.tables, &fx.atoms);
    try testing.expect(!isOpen(&fx.tables, &fx.atoms, stage));
    try testing.expectEqual(profiler, focusedTarget(&fx.tables, &fx.atoms).id);
}

test "the stored tree validates, and a broken one does not" {
    var fx: Fixture = .{};
    try fx.init();
    defer fx.deinit();
    try validateOwnerState(&fx.tables, &fx.atoms);
    const stage = Atom.from("stage");
    openNow(&fx.tables, &fx.atoms, .{ .id = stage, .root = stage });
    openNow(&fx.tables, &fx.atoms, .{ .id = Atom.from("layers"), .root = Atom.from("layers"), .beside = stage, .side = .left });
    try validateOwnerState(&fx.tables, &fx.atoms);
    // A split pointing at itself is a cycle.
    const nodes = nodesTable(&fx.tables, &fx.atoms);
    const root = state(&fx.tables, &fx.atoms).root.*;
    const row = nodeRow(nodes, root);
    const first = row.first.*;
    row.first.* = root;
    try testing.expectError(error.InvalidOwnerState, validateOwnerState(&fx.tables, &fx.atoms));
    row.first.* = first;
    state(&fx.tables, &fx.atoms).focused.* = Atom.from("missing");
    try testing.expectError(error.InvalidOwnerState, validateOwnerState(&fx.tables, &fx.atoms));
}

test "a hidden panel closes and stays closed while it is declared, until it is shown" {
    var fx: Fixture = .{};
    try fx.init();
    defer fx.deinit();
    const owner = Atom.from("hide_test_owner");
    const stage = Atom.from("stage");
    const layers = Atom.from("layers");
    const stage_panel: plugin.panels.Open = .{ .id = stage, .root = stage };
    const layers_panel: plugin.panels.Open = .{ .id = layers, .root = layers, .beside = stage, .side = .left };
    try declareAs(&fx, owner, &.{ stage_panel, layers_panel });
    reconcile(&fx.mem, &fx.tables, &fx.atoms);
    try testing.expect(isOpen(&fx.tables, &fx.atoms, layers));

    applyCmd(&fx.tables, &fx.atoms, .{ .hide = .{ .id = layers } });
    try testing.expect(isHidden(&fx.tables, &fx.atoms, layers));
    reconcile(&fx.mem, &fx.tables, &fx.atoms);
    try testing.expect(!isOpen(&fx.tables, &fx.atoms, layers));
    try testing.expect(isOpen(&fx.tables, &fx.atoms, stage));
    // Still declared, and every panel closed and laid out afresh: it stays closed.
    applyCmd(&fx.tables, &fx.atoms, .close_all);
    reconcile(&fx.mem, &fx.tables, &fx.atoms);
    try testing.expect(!isOpen(&fx.tables, &fx.atoms, layers));
    var hidden: [kMaxPanels]Atom = undefined;
    try testing.expectEqualSlices(Atom, &.{layers}, hiddenPanels(&fx.tables, &fx.atoms, &hidden));

    applyCmd(&fx.tables, &fx.atoms, .{ .show = .{ .id = layers } });
    reconcile(&fx.mem, &fx.tables, &fx.atoms);
    try testing.expect(isOpen(&fx.tables, &fx.atoms, layers));
    try testing.expectEqual(@as(usize, 0), hiddenPanels(&fx.tables, &fx.atoms, &hidden).len);
}

/// Opens `ids` in a row, left to right, each taking the focus as it opens.
fn openRow(fx: *Fixture, ids: []const Atom) void {
    var beside: Atom = no_atom;
    for (ids) |id| {
        openNow(&fx.tables, &fx.atoms, .{ .id = id, .root = id, .beside = beside, .side = .right });
        beside = id;
    }
}

test "closing the focused panel gives the focus to the one that had it before, not the first" {
    var fx: Fixture = .{};
    try fx.init();
    defer fx.deinit();
    const a = Atom.from("a");
    const b = Atom.from("b");
    const c = Atom.from("c");
    openRow(&fx, &.{ a, b, c });
    fx.command(.{ .focus = .{ .id = a } });
    fx.command(.{ .focus = .{ .id = c } });
    closeNow(&fx.tables, &fx.atoms, c);
    try testing.expectEqual(a, focusedTarget(&fx.tables, &fx.atoms).id);
    closeNow(&fx.tables, &fx.atoms, a);
    try testing.expectEqual(b, focusedTarget(&fx.tables, &fx.atoms).id);
}

test "a panel focused twice is in the focus history once, and close_all empties it" {
    var fx: Fixture = .{};
    try fx.init();
    defer fx.deinit();
    const a = Atom.from("a");
    const b = Atom.from("b");
    const c = Atom.from("c");
    openRow(&fx, &.{ a, b, c });
    fx.command(.{ .focus = .{ .id = a } });
    fx.command(.{ .focus = .{ .id = b } });
    fx.command(.{ .focus = .{ .id = a } });
    fx.command(.{ .focus = .{ .id = c } });
    var history: [kMaxPanels]Atom = undefined;
    try testing.expectEqualSlices(Atom, &.{ b, a }, focusHistory(&fx.tables, &fx.atoms, &history));
    try validateOwnerState(&fx.tables, &fx.atoms);
    fx.command(.close_all);
    try testing.expectEqual(@as(usize, 0), focusHistory(&fx.tables, &fx.atoms, &history).len);
}

test "focus_previous gives the focus to the panel before the focused one, and does nothing alone or from another" {
    var fx: Fixture = .{};
    try fx.init();
    defer fx.deinit();
    const a = Atom.from("a");
    const b = Atom.from("b");
    const c = Atom.from("c");
    openRow(&fx, &.{ a, b, c });
    fx.command(.{ .focus = .{ .id = a } });
    fx.command(.{ .focus = .{ .id = c } });
    fx.command(.{ .focus_previous = .{ .from = c } });
    try testing.expectEqual(a, focusedTarget(&fx.tables, &fx.atoms).id);
    try testing.expect(isOpen(&fx.tables, &fx.atoms, c));
    // C had the focus before A: asked again, it goes back.
    fx.command(.{ .focus_previous = .{ .from = a } });
    try testing.expectEqual(c, focusedTarget(&fx.tables, &fx.atoms).id);
    // Asked from a panel that no longer has the focus, nothing moves.
    fx.command(.{ .focus_previous = .{ .from = b } });
    try testing.expectEqual(c, focusedTarget(&fx.tables, &fx.atoms).id);

    var lone: Fixture = .{};
    try lone.init();
    defer lone.deinit();
    openRow(&lone, &.{a});
    lone.command(.{ .focus_previous = .{ .from = a } });
    try testing.expectEqual(a, focusedTarget(&lone.tables, &lone.atoms).id);
}

test "a panel that asks for the focus in the frame another closes keeps it" {
    var fx: Fixture = .{};
    try fx.init();
    defer fx.deinit();
    const owner = Atom.from("focus_stack_owner");
    const a = Atom.from("a");
    const b = Atom.from("b");
    const c = Atom.from("c");
    const a_panel: plugin.panels.Open = .{ .id = a, .root = a };
    const b_panel: plugin.panels.Open = .{ .id = b, .root = b, .beside = a, .side = .right };
    const c_panel: plugin.panels.Open = .{ .id = c, .root = c, .beside = a, .side = .bottom };
    try declareAs(&fx, owner, &.{ a_panel, b_panel });
    _ = applyFrame(&fx.mem, &fx.tables, &fx.atoms);
    try testing.expectEqual(b, focusedTarget(&fx.tables, &fx.atoms).id);

    // B, focused, is no longer declared as C opens with the focus: C has it, not A below it.
    try declareAs(&fx, owner, &.{ a_panel, c_panel });
    _ = applyFrame(&fx.mem, &fx.tables, &fx.atoms);
    try testing.expect(!isOpen(&fx.tables, &fx.atoms, b));
    try testing.expectEqual(c, focusedTarget(&fx.tables, &fx.atoms).id);

    // C, focused, is hidden by a request after one that focuses B, open again: B has it.
    var b_again = b_panel;
    b_again.focus = .keep;
    try declareAs(&fx, owner, &.{ a_panel, b_again, c_panel });
    _ = applyFrame(&fx.mem, &fx.tables, &fx.atoms);
    try testing.expectEqual(c, focusedTarget(&fx.tables, &fx.atoms).id);
    const requests = Requests.of(&fx.mem, &fx.tables, plugin.panels.commands_table_name);
    try requests.tryPush(.{ .focus = .{ .id = b } });
    try requests.tryPush(.{ .hide = .{ .id = c } });
    _ = applyFrame(&fx.mem, &fx.tables, &fx.atoms);
    try testing.expect(!isOpen(&fx.tables, &fx.atoms, c));
    try testing.expectEqual(b, focusedTarget(&fx.tables, &fx.atoms).id);

    // C shown again takes the focus; then B, focused after A, is hidden by a request before
    // one that focuses C: C has it, not A, the newest before B.
    try requests.tryPush(.{ .show = .{ .id = c } });
    _ = applyFrame(&fx.mem, &fx.tables, &fx.atoms);
    try testing.expectEqual(c, focusedTarget(&fx.tables, &fx.atoms).id);
    fx.command(.{ .focus = .{ .id = a } });
    fx.command(.{ .focus = .{ .id = b } });
    try requests.tryPush(.{ .hide = .{ .id = b } });
    try requests.tryPush(.{ .focus = .{ .id = c } });
    _ = applyFrame(&fx.mem, &fx.tables, &fx.atoms);
    try testing.expect(!isOpen(&fx.tables, &fx.atoms, b));
    try testing.expectEqual(c, focusedTarget(&fx.tables, &fx.atoms).id);
}

/// The events of `events.panels` published since `seen` of them were, which it then counts.
fn eventsSince(fx: *Fixture, seen: *usize, into: *[plugin.panels.Events.retained]plugin.panels.Event) []plugin.panels.Event {
    const all = plugin.panels.Events.of(&fx.tables, plugin.panels.events_table_name).peek(into);
    const since = all[seen.*..];
    seen.* = all.len;
    return since;
}

/// Whether `events` tell `panel`'s frame size, as it is laid out now.
fn toldSize(fx: *Fixture, events: []const plugin.panels.Event, panel: Atom) bool {
    const frame = panelFor(&fx.tables, &fx.atoms, panel).?.frame;
    for (events) |event| switch (event) {
        .resized => |resized| {
            if (resized.panel != panel) continue;
            return resized.frame_width == frame.w and resized.frame_height == frame.h;
        },
        .focused, .unfocused => {},
    };
    return false;
}

test "a divider moved tells the two panels beside it of their sizes, and no other" {
    var fx: Fixture = .{};
    try fx.init();
    defer fx.deinit();
    const a = Atom.from("a");
    const b = Atom.from("b");
    const c = Atom.from("c");
    openRow(&fx, &.{ a, b, c });
    var seen: usize = 0;
    var events: [plugin.panels.Events.retained]plugin.panels.Event = undefined;
    // Newly open, each is told its first size, once.
    dispatchResizes(&fx.tables, &fx.atoms);
    const first = eventsSince(&fx, &seen, &events);
    try testing.expectEqual(@as(usize, 3), first.len);
    for ([_]Atom{ a, b, c }) |panel| try testing.expect(toldSize(&fx, first, panel));
    dispatchResizes(&fx.tables, &fx.atoms);
    try testing.expectEqual(@as(usize, 0), eventsSince(&fx, &seen, &events).len);

    // The divider between B and C moves.
    var tree = load(&fx.tables, &fx.atoms);
    const c_frame = frameOf(&tree, "c");
    var found: [kMaxNodes]Divider = undefined;
    const between = for (tree.dividers(&found)) |divider| {
        if (divider.rect.x + divider.rect.w == c_frame.x) break divider;
    } else return error.NoDivider;
    tree.resize(between.node, c_frame.x + 40);
    store(&fx.tables, &fx.atoms, &tree);
    relayoutStored(&fx.tables, &fx.atoms);
    dispatchResizes(&fx.tables, &fx.atoms);
    const moved = eventsSince(&fx, &seen, &events);
    try testing.expectEqual(@as(usize, 2), moved.len);
    try testing.expect(toldSize(&fx, moved, b));
    try testing.expect(toldSize(&fx, moved, c));
}

test "a panel closed and opened again in one place under its id is told its first size again" {
    var fx: Fixture = .{};
    try fx.init();
    defer fx.deinit();
    const a = Atom.from("a");
    const window = Atom.from("text_panel_1");
    openRow(&fx, &.{ a, window });
    var seen: usize = 0;
    var events: [plugin.panels.Events.retained]plugin.panels.Event = undefined;
    dispatchResizes(&fx.tables, &fx.atoms);
    _ = eventsSince(&fx, &seen, &events);

    // Within one pump the window closes and its id opens again where it was, the same size.
    closeNow(&fx.tables, &fx.atoms, window);
    openNow(&fx.tables, &fx.atoms, .{ .id = window, .root = window, .beside = a, .side = .right });
    dispatchResizes(&fx.tables, &fx.atoms);
    const reopened = eventsSince(&fx, &seen, &events);
    try testing.expect(toldSize(&fx, reopened, window));
}

test "a window resized tells every open panel its size, and nothing changed tells nothing" {
    var fx: Fixture = .{};
    try fx.init();
    defer fx.deinit();
    const a = Atom.from("a");
    const b = Atom.from("b");
    const c = Atom.from("c");
    openRow(&fx, &.{ a, b, c });
    var seen: usize = 0;
    var events: [plugin.panels.Events.retained]plugin.panels.Event = undefined;
    dispatchResizes(&fx.tables, &fx.atoms);
    _ = eventsSince(&fx, &seen, &events);

    relayout(&fx.tables, &fx.atoms, .{ .w = 1200, .h = 700 });
    dispatchResizes(&fx.tables, &fx.atoms);
    const resized = eventsSince(&fx, &seen, &events);
    try testing.expectEqual(@as(usize, 3), resized.len);
    for ([_]Atom{ a, b, c }) |panel| try testing.expect(toldSize(&fx, resized, panel));

    relayout(&fx.tables, &fx.atoms, .{ .w = 1200, .h = 700 });
    dispatchResizes(&fx.tables, &fx.atoms);
    try testing.expectEqual(@as(usize, 0), eventsSince(&fx, &seen, &events).len);
}

test "a maximized panel gives the focus back when it leaves" {
    var fx: Fixture = .{};
    try fx.init();
    defer fx.deinit();
    const stage = Atom.from("stage");
    const layers = Atom.from("layers");
    openNow(&fx.tables, &fx.atoms, .{ .id = stage, .root = stage });
    openNow(&fx.tables, &fx.atoms, .{ .id = layers, .root = layers, .beside = stage, .side = .left });
    fx.command(.toggle_maximize);
    try testing.expect(isMaximized(&fx.tables, &fx.atoms, layers));
    try testing.expect(panelFor(&fx.tables, &fx.atoms, stage).?.frame.empty());
    fx.command(.{ .focus = .{ .id = stage } });
    relayout(&fx.tables, &fx.atoms, test_window);
    try testing.expect(!isMaximized(&fx.tables, &fx.atoms, layers));
    try testing.expect(!panelFor(&fx.tables, &fx.atoms, stage).?.frame.empty());
}
