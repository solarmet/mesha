//! Sketches in the figure editor. A sketch is a named collection of figures, its members
//! (`runtime/figure/sketch.zig`); the editor edits one member's figure at a time, as it
//! edits any figure. While the open figure is a member of an open sketch, the header shows the
//! sketch's members, and choosing one opens its figure. The palette makes sketches and adds,
//! copies, renames, removes and reorders members; saving a member's figure also saves its
//! sketch's membership when that has changed.
const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const modes = @import("../modes.zig");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory = mesha.memory;
const sequencer = mesha.sequencer;
const plugin = mesha.plugin;
const resources = mesha.resources;
const zon = mesha.zon;
const api = plugin.figure_api;
const figure = mesha.figure;
const session = @import("session.zig");
const prompts = @import("prompts.zig");
const transport = @import("commands.zig");
const workspace = @import("workspace.zig");
const button = @import("../ui/button.zig");
const style = @import("../ui/style.zig");

/// The tags of the sketch actions, and of a member chosen in the header.
pub const Msg = enum(u64) {
    figure_sketch_new = Atom.from("figure_sketch_new").value(),
    figure_sketch_add_member = Atom.from("figure_sketch_add_member").value(),
    figure_sketch_copy_member = Atom.from("figure_sketch_copy_member").value(),
    figure_sketch_rename_member = Atom.from("figure_sketch_rename_member").value(),
    figure_sketch_remove_member = Atom.from("figure_sketch_remove_member").value(),
    figure_sketch_member_earlier = Atom.from("figure_sketch_member_earlier").value(),
    figure_sketch_member_later = Atom.from("figure_sketch_member_later").value(),
    figure_sketch_save = Atom.from("figure_sketch_save").value(),
    figure_sketch_member = Atom.from("figure_sketch_member").value(),
    _,
};

pub const actions = blk: {
    const defs = .{
        .{ Msg.figure_sketch_new, "Create a sketch: a collection of figures, its first member new" },
        .{ Msg.figure_sketch_add_member, "Add a new, empty member to the open figure's sketch" },
        .{ Msg.figure_sketch_copy_member, "Add a member to the sketch, a copy of the open member" },
        .{ Msg.figure_sketch_rename_member, "Rename the open member of its sketch" },
        .{ Msg.figure_sketch_remove_member, "Remove the open member from its sketch; its file stays" },
        .{ Msg.figure_sketch_member_earlier, "Move the open member one place earlier in its sketch" },
        .{ Msg.figure_sketch_member_later, "Move the open member one place later in its sketch" },
        .{ Msg.figure_sketch_save, "Save the open figure's sketch and its unsaved members" },
    };
    var result: [defs.len]plugin.action_api.Def = undefined;
    for (defs, 0..) |entry, i| result[i] = .{ .name = modes.shortName("figure", @tagName(entry[0])), .tag = @tagName(entry[0]), .doc = entry[1] };
    break :blk result;
};

/// What the sketch prompts ask for, as the prompt's kind.
pub const PromptKind = enum(u64) {
    sketch_new = Atom.from("sketch_new").value(),
    sketch_member_new = Atom.from("sketch_member_new").value(),
    sketch_member_copy = Atom.from("sketch_member_copy").value(),
    sketch_member_rename = Atom.from("sketch_member_rename").value(),
    _,
};

/// The member every new sketch starts with.
pub const first_member = "front";

/// A member of a sketch, in its order.
pub const Member = struct { member: Atom, figure: Atom };
/// Most members the header shows; a sketch holds no more (`sketch.max_members`).
const max_members = 32;

/// The sketch `figure` is a member of, and which member it is.
pub const Membership = struct { sketch: Atom, member: Atom };

/// The open sketch whose member the figure `doc` is, if any.
pub fn membershipOf(tables: *Table.Registry, doc: Atom) ?Membership {
    const members = tables.findByName(Atom.from(api.sketch_members_table_name)) orelse return null;
    var rows = members.readQuery(api.SketchMemberView);
    while (rows.next()) |row| {
        if (row.view.figure.* == doc) return .{ .sketch = row.view.sketch.*, .member = row.view.member.* };
    }
    return null;
}

/// The members of `sketch` in order, in `buffer`.
pub fn membersOf(tables: *Table.Registry, sketch: Atom, buffer: *[max_members]Member) []Member {
    const members = tables.findByName(Atom.from(api.sketch_members_table_name)) orelse return buffer[0..0];
    var count: usize = 0;
    var rows = members.readQuery(api.SketchMemberView);
    while (rows.next()) |row| {
        if (row.view.sketch.* != sketch) continue;
        const order = row.view.order.*;
        if (order >= buffer.len) continue;
        buffer[order] = .{ .member = row.view.member.*, .figure = row.view.figure.* };
        count = @max(count, order + 1);
    }
    return buffer[0..count];
}

/// Whether the open sketch `sketch` has membership edits not yet saved.
fn sketchDirty(tables: *Table.Registry, sketch: Atom) bool {
    const sketches = tables.findByName(Atom.from(api.sketches_table_name)) orelse return false;
    var rows = sketches.readQuery(api.SketchView);
    while (rows.next()) |row| {
        if (row.view.sketch.* == sketch) return row.view.dirty.* != 0;
    }
    return false;
}

/// The membership of the open figure, or `NotSketchMember`.
fn openMembership(tables: *Table.Registry) !Membership {
    const editor = session.get(tables);
    return membershipOf(tables, editor.doc.*) orelse error.NotSketchMember;
}

/// Runs a sketch action or opens the member chosen in the header; false for a message that is
/// none of these.
pub fn handleAction(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, received: sequencer.Message) !bool {
    const message = received.tag.to(Msg);
    switch (message) {
        _ => return false,
        .figure_sketch_new => try prompts.show(mem, tables, atoms, Atom.from(PromptKind.sketch_new), ""),
        .figure_sketch_add_member => {
            _ = try openMembership(tables);
            try prompts.show(mem, tables, atoms, Atom.from(PromptKind.sketch_member_new), "");
        },
        .figure_sketch_copy_member => {
            _ = try openMembership(tables);
            try prompts.show(mem, tables, atoms, Atom.from(PromptKind.sketch_member_copy), "");
        },
        .figure_sketch_rename_member => {
            const membership = try openMembership(tables);
            try prompts.show(mem, tables, atoms, Atom.from(PromptKind.sketch_member_rename), atoms.lookup(membership.member) orelse "");
        },
        .figure_sketch_remove_member => try removeOpenMember(tables, atoms),
        .figure_sketch_member_earlier, .figure_sketch_member_later => {
            const membership = try openMembership(tables);
            const direction: i32 = if (message == .figure_sketch_member_earlier) -1 else 1;
            try transport.send(tables, atoms, .{ .move_sketch_member = .{ .doc = membership.sketch, .member = membership.member, .direction = direction } });
        },
        .figure_sketch_save => {
            const membership = try openMembership(tables);
            try saveSketch(tables, atoms, membership.sketch);
        },
        .figure_sketch_member => {
            const chosen = (try received.userDataAs(Atom)).*;
            if (chosen == session.get(tables).doc.*) return true;
            if (membershipOf(tables, chosen)) |membership| {
                loadMember(tables, atoms, membership.sketch, chosen);
            } else prompts.load(tables, atoms, chosen, false, null);
        },
    }
    return true;
}

/// Removes the open member, after opening the member before it (or after it, for the first),
/// since removing a member closes its figure.
fn removeOpenMember(tables: *Table.Registry, atoms: *Atom.Registry) !void {
    const membership = try openMembership(tables);
    var buffer: [max_members]Member = undefined;
    const members = membersOf(tables, membership.sketch, &buffer);
    if (members.len < 2) return error.LastMember;
    const index = for (members, 0..) |entry, at| {
        if (entry.member == membership.member) break at;
    } else return error.NotSketchMember;
    const next = if (index == 0) members[1] else members[index - 1];
    loadMember(tables, atoms, membership.sketch, next.figure);
    try transport.send(tables, atoms, .{ .remove_sketch_member = .{ .doc = membership.sketch, .member = membership.member } });
}

/// Saves `sketch`: to its own file, or, with none yet, to `<stem>.mshs` in the working
/// directory, as a new text file saves. Its members' figures save beside it.
fn saveSketch(tables: *Table.Registry, atoms: *Atom.Registry, sketch: Atom) !void {
    const sketches = tables.findByName(Atom.from(api.sketches_table_name)) orelse return error.MissingSketch;
    var saved_path: []const u8 = "";
    var rows = sketches.readQuery(api.SketchView);
    while (rows.next()) |row| {
        if (row.view.sketch.* == sketch) saved_path = row.view.path;
    }
    if (saved_path.len != 0) {
        try transport.send(tables, atoms, .{ .save_sketch = .{ .doc = sketch } });
        return;
    }
    var buffer: [256]u8 = undefined;
    const stem = atoms.lookup(sketch) orelse return error.InvalidName;
    const default_path = std.fmt.bufPrint(&buffer, "{s}{s}", .{ stem, resources.sketch_document_extension }) catch return error.InvalidPath;
    try transport.send(tables, atoms, .{ .save_sketch = .{ .doc = sketch, .path = default_path } });
}

/// The label and hint of a sketch prompt, or null for another kind.
pub const PromptLabel = struct { label: []const u8, hint: []const u8 };

pub fn promptLabel(kind: Atom) ?PromptLabel {
    return switch (kind.to(PromptKind)) {
        .sketch_new => .{ .label = "New sketch: ", .hint = "snake_case name; its first member, front, is a new figure <name>_front" },
        .sketch_member_new => .{ .label = "New member: ", .hint = "snake_case name; its figure is a new, empty <sketch>_<member>" },
        .sketch_member_copy => .{ .label = "Copy member as: ", .hint = "snake_case name; its figure is a copy of the open member's" },
        .sketch_member_rename => .{ .label = "Rename member: ", .hint = "snake_case name; the member's figure keeps its file" },
        _ => null,
    };
}

/// Sends what a sketch prompt asked for; false for another kind of prompt.
pub fn submitPrompt(tables: *Table.Registry, atoms: *Atom.Registry, kind: Atom, text: []const u8) !bool {
    const prompt = kind.to(PromptKind);
    switch (prompt) {
        _ => return false,
        else => {},
    }
    if (!zon.isSnakeCaseAtom(text)) return error.InvalidName;
    try atoms.tryInternAll(&.{text});
    const name = atoms.intern(text);
    switch (prompt) {
        .sketch_new => {
            try atoms.tryInternAll(&.{first_member});
            const scope = resources.editorDocumentsScope(tables.memory);
            try transport.send(tables, atoms, .{ .new_sketch = .{ .scope = scope, .doc = name, .member = atoms.intern(first_member) } });
        },
        .sketch_member_new => {
            const membership = try openMembership(tables);
            try transport.send(tables, atoms, .{ .add_sketch_member = .{ .doc = membership.sketch, .member = name } });
        },
        .sketch_member_copy => {
            const membership = try openMembership(tables);
            try transport.send(tables, atoms, .{ .add_sketch_member = .{ .doc = membership.sketch, .member = name, .copy_of = membership.member } });
        },
        .sketch_member_rename => {
            const membership = try openMembership(tables);
            try transport.send(tables, atoms, .{ .rename_sketch_member = .{ .doc = membership.sketch, .member = membership.member, .name = name } });
        },
        _ => unreachable,
    }
    return true;
}

/// Makes the new sketch `sketch`, with its first member, whose file is `path`, a file not there:
/// nothing is written until its first save, which writes it there and its member's figure
/// beside it. Its first member opens once the host has made it.
pub fn createAt(tables: *Table.Registry, atoms: *Atom.Registry, sketch: Atom, path: []const u8) !void {
    const scope = resources.editorDocumentsScope(tables.memory);
    // Interned at init, with the canvas's names (`workspace.vocabulary`).
    const member = Atom.from(first_member);
    try transport.send(tables, atoms, .{ .new_sketch = .{ .scope = scope, .doc = sketch, .member = member, .path = path } });
}

/// Opens the sketch `sketch` with the editor's hold, from the file at `path` when given, else
/// from the file the catalog has for it; its first member opens once it is read.
pub fn open(tables: *Table.Registry, atoms: *Atom.Registry, sketch: Atom, path: ?[]const u8) !void {
    const scope = resources.editorDocumentsScope(tables.memory);
    try transport.send(tables, atoms, .{ .load_sketch = .{ .scope = scope, .doc = sketch, .path = path } });
}

/// Opens the member figure `figure_id` of `sketch` from beside the sketch's file, or from the
/// catalog's file for a sketch without one.
fn loadMember(tables: *Table.Registry, atoms: *Atom.Registry, sketch: Atom, figure_id: Atom) void {
    var path_buffer: [resources.max_path]u8 = undefined;
    const path = memberPath(tables, atoms, sketch, figure_id, &path_buffer);
    prompts.load(tables, atoms, figure_id, false, path);
}

fn memberPath(tables: *Table.Registry, atoms: *Atom.Registry, sketch: Atom, figure_id: Atom, buffer: []u8) ?[]const u8 {
    const sketches = tables.findByName(Atom.from(api.sketches_table_name)) orelse return null;
    const figure_name = atoms.lookup(figure_id) orelse return null;
    var rows = sketches.readQuery(api.SketchView);
    while (rows.next()) |row| {
        if (row.view.sketch.* != sketch) continue;
        return api.sketchMemberPath(buffer, row.view.path, figure_name) catch null;
    }
    return null;
}

/// What follows a sketch request the host completed: a sketch opened or made opens its first
/// member, and a member added opens it. A member's figure saved saves its sketch's membership
/// too, when that has changed.
pub fn followResult(context: figure.Context, result: api.Result) void {
    if (result.outcome != .success) return;
    var buffer: [max_members]Member = undefined;
    switch (result.operation) {
        .load_sketch, .new_sketch => {
            const members = membersOf(context.tables, result.definition, &buffer);
            if (members.len != 0) loadMember(context.tables, context.atoms, result.definition, members[0].figure);
        },
        .add_sketch_member => {
            const members = membersOf(context.tables, result.definition, &buffer);
            if (members.len != 0) loadMember(context.tables, context.atoms, result.definition, members[members.len - 1].figure);
        },
        .save_doc => {
            const membership = membershipOf(context.tables, result.current_definition) orelse return;
            if (!sketchDirty(context.tables, membership.sketch)) return;
            saveSketch(context.tables, context.atoms, membership.sketch) catch |err| {
                prompts.status(session.table(context.tables), session.get(context.tables), session.feedback(context.tables), @errorName(err));
            };
        },
        else => {},
    }
}

const member_button_width: f32 = 72;

/// The open figure's sketch and its members, in the header: the open member marked, choosing
/// another opens it. Nothing while the open figure is no member.
pub fn renderMembers(tree: *ui.Tree, tables: *Table.Registry) void {
    const editor = session.get(tables);
    const membership = membershipOf(tables, editor.doc.*) orelse return;
    var buffer: [max_members]Member = undefined;
    const members = membersOf(tables, membership.sketch, &buffer);
    const sketch_name = tree.atoms.lookup(membership.sketch) orelse "sketch";
    const dirty = sketchDirty(tables, membership.sketch);
    const label = if (dirty) std.fmt.allocPrint(tree.frame_allocator.allocator, "{s}*", .{sketch_name}) catch sketch_name else sketch_name;
    tree.text("figure.header.sketch", label, .{ .font = style.ui_font, .color = style.col.text_dim });
    for (members, 0..) |entry, index| {
        const name = tree.atoms.lookup(entry.member) orelse "member";
        const id = ui.ElementId{ .atom = Atom.from("figure.header.sketch_member"), .extra = @intCast(index) };
        const click = workspace.to(tree, Atom.from(Msg.figure_sketch_member), entry.figure);
        button.render(tree, id, click, .{
            .label = name,
            .tooltip = "Open this member of the sketch",
            .variant = .tab,
            .selected = entry.figure == editor.doc.*,
            .size = .{ .w = .{ .fixed = member_button_width }, .h = .fill },
        });
    }
}
