//! A dialog a version-control panel asks before a command that throws work away, in the
//! action palette (`.dialog`): its words, a yes and `Cancel`, `Cancel` the default. vcs-git's
//! discard and its branch, push, merge and rebase dialogs, and vcs-p4's revert, delete and
//! shelf dialogs, are presented and read here, each panel keeping what it asked about itself,
//! with a serial or a fingerprint in the dialog's user data, so a yes runs exactly what was
//! asked.

const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const sequencer = mesha.sequencer;
const action_palette = @import("../action_palette.zig");

/// A dialog's words.
pub const Question = struct {
    /// Its title: what is asked (`Discard changes?`).
    title: []const u8 = "",
    /// Under it: what it acts on, and what follows.
    body: []const u8 = "",
    /// The yes's label (`Discard`).
    confirm: []const u8 = "",
};

/// A dialog's answers, as its entries' first data byte.
const Answer = enum(u8) { cancel, confirm };

/// Presents `question` as a dialog owned by `owner`, its answer, a palette event, coming to
/// `reply`, whose user data says what it asks about. The words are copied into the palette's
/// arena for the vcs panels, which this resets: one dialog of theirs at a time.
pub fn presentDialog(memory: *memory_mod.Memory, tables: *Table.Registry, owner: Atom, question: Question, reply: sequencer.ReplyTo) !void {
    const allocator = try action_palette.completionAllocator(memory, .vcs);
    action_palette.resetCompletionArena(memory, .vcs);
    const entries = try allocator.alloc(action_palette.Completion, 2);
    const labels = [2][]const u8{ question.confirm, "Cancel" };
    const answers = [2]Answer{ .confirm, .cancel };
    for (entries, labels, answers) |*entry, label, answer| {
        var data = std.mem.zeroes([action_palette.kCompletionDataSize]u8);
        data[0] = @intFromEnum(answer);
        entry.* = .{ .label = label, .data = data };
    }
    const completions = try allocator.create(action_palette.Completions);
    completions.* = .{ .owner = owner, .presentation = .dialog, .title = question.title, .body = question.body, .default_entry = 1, .entries = entries };
    try action_palette.ownRequestText(allocator, completions);
    action_palette.request(memory, tables, .{ .present = .{ .completions = completions, .reply = reply } });
}

/// Whether `completion`, what the dialog's event chose, is its yes: false for `Cancel` and for
/// a dialog closed with nothing chosen.
pub fn confirmed(completion: ?action_palette.Completion) bool {
    const chosen = completion orelse return false;
    const answer = std.enums.fromInt(Answer, chosen.data[0]) orelse return false;
    return answer == .confirm;
}
