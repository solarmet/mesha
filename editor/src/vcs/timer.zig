//! What a version-control panel's refresh timer reads, the same for vcs-git and vcs-p4: the
//! awake clock a wake is counted on, whether a wake asked was lost, whether the engine's window
//! has the focus, and the tables the timer declares. Each panel keeps its own wake, interval and
//! setting in its own row.

const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const sequencer = mesha.sequencer;
const keybinds = mesha.keybinds;
const workspaces = @import("../workspaces.zig");

const os_window_table = Atom.from(mesha.os.window_table_name);
const settings_table = Atom.from(keybinds.editor_settings_name);
const shown_panels_table = Atom.from(workspaces.shown_panels_table_name);
const time_commands = Atom.from(mesha.time.commands_table_name);
const time_state = Atom.from(mesha.time.state_table_name);

/// Whether the awake clock is more than twice `seconds` past `asked_at`, when the wake was
/// asked, in nanoseconds: counted while the host slept too, so the first run after it wakes
/// asks again; never without the clock.
pub fn wakeOverdue(pass: *const sequencer.Pass, asked_at: i64, seconds: u32) bool {
    const now = awakeNanoseconds(pass) orelse return false;
    const interval: i64 = @as(i64, seconds) * std.time.ns_per_s;
    return now - asked_at > 2 * interval;
}

/// The awake clock's instant as the time system last read it (`mesha.time.AwakeView`), in
/// nanoseconds; null without the clock.
pub fn awakeNanoseconds(pass: *const sequencer.Pass) ?i64 {
    if (!pass.declares(time_state)) return null;
    const clock = pass.readSingleton(time_state, mesha.time.AwakeView) catch return null;
    return std.math.cast(i64, clock.prev_time.nanoseconds);
}

/// Declares read what a timer reads beside its panel's row: whether a panel is shown, the
/// window's focus, the settings and the clock; and the time system's requests written, for its
/// wake.
pub fn declareTimerAccess(access_now: *sequencer.Access, tables: *Table.Registry) void {
    const read = [_]Atom{ os_window_table, settings_table, shown_panels_table, time_state };
    for (read) |name| {
        if (tables.findByName(name) != null) access_now.read(name);
    }
    access_now.writeIfPresent(tables, time_commands);
}

/// Whether the engine's window has the focus, as `os_window` says; a window that says nothing
/// of it, as a test's, has.
pub fn windowFocused(pass: *const sequencer.Pass) bool {
    if (!pass.declares(os_window_table)) return true;
    const window = pass.table(os_window_table) catch return true;
    if (window.getSchema().fieldIndex(mesha.os.window_focused_field) == null) return true;
    const focus = pass.readSingleton(os_window_table, mesha.os.WindowFocusView) catch return true;
    return focus.focused.* != 0;
}
