//! Tests of vcs-git's rebases (`git_rebase.zig`), the rebase menu and the rebase list's page, run
//! on the panel's bench (`git_status_test.zig`): the menu's answer is given as the menu gives
//! it, the list's keys as their actions deliver them, and each job's answer as the runner gives
//! it. One test swaps two commits and rewords one through the panel's own path in a real git
//! repository, git's editors a stand-in that does what the host's `--stdin-to-file` and
//! `--file-to-stdout` do (skipped on Windows and where `git` is not on `PATH`).

const std = @import("std");
const builtin = @import("builtin");
const mesha = @import("mesha");
const mesha_runtime = @import("mesha_runtime");
const Atom = mesha.Atom;
const Table = mesha.Table;
const sequencer = mesha.sequencer;
const git = @import("git.zig");
const runner = @import("runner.zig");
const vcs_page = @import("page.zig");
const git_status = @import("git_status.zig");
const git_rebase = @import("git_rebase.zig");
const git_branch = @import("git_branch.zig");
const git_commit = @import("git_commit.zig");
const view = @import("git_status_view.zig");
const document = @import("../document/document.zig");
const status_test = @import("git_status_test.zig");
const log_test = @import("git_log_test.zig");
const commit_test = @import("git_commit_test.zig");
const Bench = status_test.Bench;
const testing = std.testing;

/// The recent commit the tests rebase after: the oldest of `status_test.recent_commits`.
const base_hash = "72f25b65411d1f8a0a15a3f577334b3e0e3a4cc0";
/// HEAD as `status_test.changed_status` says.
const head_hash = "5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f";
const first_hash = "1111111111111111111111111111111111111111";
const second_hash = "2222222222222222222222222222222222222222";
/// The commits after the base, oldest first, as `rebase_commits` lists them.
const two_commits = first_hash ++ "\x1f1111111\x1fAna\x1f2026-11-21\x1f\x1fAdd bees\x00" ++
    second_hash ++ "\x1f2222222\x1fAna\x1f2026-11-22\x1fHEAD -> main\x1fShout two\x00";

/// `r`, then `keys` typed in the rebase menu.
fn rebaseMenu(bench: *Bench, keys: []const u8) !void {
    try log_test.chooseIn(bench, Atom.from(git_rebase.Msg.vcs_git_rebase_menu), &git_rebase.menu, &.{}, keys);
}

/// A key of the rebase view, delivered as its action delivers it, and the panel's run.
fn press(bench: *Bench, tag: git_rebase.Msg) !void {
    try log_test.deliver(bench, Atom.from(tag));
}

/// The panel opened on a repository, the cursor on the base's recent commit, `r i` run and its
/// list answered with `two_commits`.
fn openList(bench: *Bench) !void {
    try status_test.openAnswered(bench);
    try bench.placeCursor(try bench.spotOf(.recent, "72f25b6"));
    try rebaseMenu(bench, "i");
    const listing = try log_test.onlyJob(bench, .rebase_list);
    // Of HEAD where the status says it is, both by full hash.
    try status_test.expectArgv(listing, .{ .rebase_commits = .{ .base = base_hash, .head = head_hash } });
    try log_test.answer(bench, listing, 0, two_commits);
}

/// The rebase page as its draw lays it out.
fn rebasePage(bench: *Bench) !document.Layout {
    return vcs_page.laidOutIn(bench.arena.allocator(), &bench.tables, &bench.atoms, git_rebase.page);
}

/// The list's rows, in the page's order: each `action hash subject`, in `allocator`.
fn rowsShown(bench: *Bench, allocator: std.mem.Allocator) ![]const []const u8 {
    const rows = bench.tables.findByName(Atom.from(git_rebase.list_table_name)).?;
    const lines = try allocator.alloc([]const u8, rows.count());
    for (lines, 0..) |*line, position| {
        const handle = document.rowAt(rows, @intCast(position)).?;
        const row = rows.getRow(handle, git_rebase.RebaseRow).?;
        line.* = try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ row.action, row.hash, row.subject });
    }
    return lines;
}

/// The subject of the row the rebase page's cursor is on.
fn cursorSubject(bench: *Bench) ![]const u8 {
    const page = try rebasePage(bench);
    const cells = bench.tables.findByName(Atom.from(git_rebase.view_table_name)).?;
    const state = cells.getRow(.{ .row = 0, .generation = cells.rowGeneration(0) }, document.StateRow).?;
    const row = switch (document.at(page, document.cursorOf(state))) {
        .row => |row| row,
        .heading, .group, .text, .none => return error.NotOnARow,
    };
    return row.table.getRow(row.row, git_rebase.RebaseRow).?.subject;
}

fn expectRows(bench: *Bench, expected: []const []const u8) !void {
    const shown = try rowsShown(bench, bench.arena.allocator());
    try testing.expectEqual(expected.len, shown.len);
    for (expected, shown) |wanted, line| try testing.expectEqualStrings(wanted, line);
}

test "vcs git rebase: r i lists the commits oldest first in the table, and C-c C-c runs the rebase with the list on the input" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openList(&bench);
    try testing.expectEqual(git_status.View.rebase, log_test.viewShown(&bench));
    try expectRows(&bench, &.{ "pick 1111111 Add bees", "pick 2222222 Shout two" });
    try testing.expectEqualStrings("Add bees", try cursorSubject(&bench));
    try testing.expectEqualStrings("2 commits", bench.value("vcs-git.rebase-count").?);
    try testing.expectEqualStrings("72f25b6", bench.value("vcs-git.rebase-onto").?);
    // The page shows the line of what is rebased, the line of keys and the table's columns.
    const page = try rebasePage(&bench);
    var columns: usize = 0;
    for (page.shown) |index| {
        const block = page.blocks[index];
        if (block.table) |table| columns = table.columns.len;
    }
    try testing.expectEqual(@as(usize, 3), columns);

    try beginVerified(&bench);
    _ = try status_test.expectCommand(&bench, .{ .rebase = .{ .base = base_hash } }, "pick " ++ first_hash ++ " Add bees\npick " ++ second_hash ++ " Shout two\n");
    try testing.expectEqual(git_status.View.status, log_test.viewShown(&bench));
}

test "vcs git rebase: M-n moves a row down and the list follows" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openList(&bench);
    try press(&bench, .vcs_rebase_move_down);
    try expectRows(&bench, &.{ "pick 2222222 Shout two", "pick 1111111 Add bees" });
    // The cursor followed the commit it was on.
    try testing.expectEqualStrings("Add bees", try cursorSubject(&bench));
    // At the end of the list nothing moves; M-p takes it back.
    try press(&bench, .vcs_rebase_move_down);
    try expectRows(&bench, &.{ "pick 2222222 Shout two", "pick 1111111 Add bees" });
    try press(&bench, .vcs_rebase_move_up);
    try expectRows(&bench, &.{ "pick 1111111 Add bees", "pick 2222222 Shout two" });
    try press(&bench, .vcs_rebase_move_down);
    try beginVerified(&bench);
    _ = try status_test.expectCommand(&bench, .{ .rebase = .{ .base = base_hash } }, "pick " ++ second_hash ++ " Shout two\npick " ++ first_hash ++ " Add bees\n");
}

test "vcs git rebase: reword is written as pick and break" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openList(&bench);
    try press(&bench, .vcs_rebase_reword);
    try expectRows(&bench, &.{ "reword 1111111 Add bees", "pick 2222222 Shout two" });
    try bench.act(.vcs_git_next);
    try press(&bench, .vcs_rebase_drop);
    try beginVerified(&bench);
    _ = try status_test.expectCommand(&bench, .{ .rebase = .{ .base = base_hash } }, "pick " ++ first_hash ++ " Add bees\nbreak\ndrop " ++ second_hash ++ " Shout two\n");
}

test "vcs git rebase: a first commit squashed is refused before anything runs, and C-c C-k leaves running nothing" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openList(&bench);
    try press(&bench, .vcs_rebase_squash);
    try press(&bench, .vcs_rebase_begin);
    try log_test.expectNoJob(&bench);
    var said: [8][]const u8 = undefined;
    try testing.expectEqualStrings("The first commit kept cannot be squashed or fixed up: there is none before it to fold it into", bench.told(&said)[0]);
    try testing.expectEqual(git_status.View.rebase, log_test.viewShown(&bench));
    bench.forgetRequests();
    try press(&bench, .vcs_rebase_leave);
    try log_test.expectNoJob(&bench);
    try testing.expectEqual(git_status.View.status, log_test.viewShown(&bench));
    try expectRows(&bench, &.{});
}

/// The refresh queued since the requests were last forgotten, answered: the status `status`,
/// the recent commits, and `operation` for the operation in progress; the refresh's jobs it asks
/// after, answered alike. What it queues that is no refresh's (a command its end runs) is left,
/// the only request since they were last forgotten.
fn answerRefresh(bench: *Bench, status: []const u8, operation: []const u8) !void {
    return answerRefreshChecked(bench, status, operation, 0);
}

/// As `answerRefresh`, `rebase_check` ending with `check_code`, as the runner reports it.
fn answerRefreshChecked(bench: *Bench, status: []const u8, operation: []const u8, check_code: i32) !void {
    for (0..3) |_| {
        var storage: [8]runner.Job = undefined;
        const queued = bench.queued(&storage);
        var jobs: [8]runner.Job = undefined;
        var count: usize = 0;
        for (queued) |job| switch (Bench.purposeOf(job)) {
            .status, .recent, .operation, .root, .rebase_check => {
                jobs[count] = job;
                count += 1;
            },
            else => {},
        };
        if (count == 0) return;
        bench.forgetRequests();
        for (jobs[0..count]) |job| {
            const said: []const u8 = switch (Bench.purposeOf(job)) {
                .status => status,
                .recent => status_test.recent_commits,
                .operation => operation,
                else => "",
            };
            const code: i32 = if (Bench.purposeOf(job) == .rebase_check) check_code else 0;
            _ = try bench.finish(job, code, said, "");
        }
        bench.run();
    }
}

/// `C-c C-c`, and the refresh it asks first answered with HEAD where `openList` listed it: the
/// list is then given to git.
fn beginVerified(bench: *Bench) !void {
    bench.forgetRequests();
    try press(bench, .vcs_rebase_begin);
    try answerRefresh(bench, status_test.changed_status, "");
}

/// `g`, the refresh answered as `answerRefresh` answers.
fn refreshWith(bench: *Bench, status: []const u8, operation: []const u8) !void {
    bench.forgetRequests();
    try bench.act(.vcs_git_refresh);
    try answerRefresh(bench, status, operation);
}

/// What is told when git did not run a list of the panel's, and what the status's line says while
/// that rebase lasts.
const not_run_told = "git did not run the list; $ shows why: r a aborts and leaves the branch as it was, then r i lists again";
const not_run_line = "Rebasing, but git did not run the list ($ shows why): r a aborts and leaves the branch as it was, then r i lists again";

/// HEAD detached at the first commit of the list.
const detached = "# branch.oid " ++ first_hash ++ "\x00# branch.head (detached)\x00";

/// The list begun, the rebase's command answered with `code`, and the requests forgotten.
fn beginAndAnswer(bench: *Bench, code: i32) !void {
    try beginVerified(bench);
    var storage: [8]runner.Job = undefined;
    const rebase = try Bench.jobFor(bench.queued(&storage), .command);
    bench.forgetRequests();
    _ = try bench.finish(rebase, code, "", if (code == 0) "" else "error: could not apply\n");
    bench.run();
}

test "vcs git rebase: c f from the menu of menus in the rebase view acts on no hidden status cursor" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    // The status's cursor, hidden behind the list, is on a commit.
    try openList(&bench);
    try testing.expectEqual(git_status.View.rebase, log_test.viewShown(&bench));
    bench.forgetRequests();
    try log_test.chooseIn(&bench, Atom.from(git_commit.Msg.vcs_git_commit_menu), &git_commit.menu, &.{}, "f");
    try status_test.expectNoCommand(&bench);
    var said: [8][]const u8 = undefined;
    try testing.expectEqualStrings("Put the cursor on a commit to fix up", bench.told(&said)[0]);
}

test "vcs git rebase: a rebase that stops shows what to press in the status" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openList(&bench);
    try press(&bench, .vcs_rebase_reword);
    // Stopped at the reword's break: HEAD detached, `rebase-merge/onto` the one ref of it.
    try beginAndAnswer(&bench, 0);
    try answerRefresh(&bench, detached, "rebase-merge/onto\x1f" ++ base_hash ++ "\n");
    try testing.expectEqualStrings("Rebasing, stopped at a break; c w rewords HEAD, then r r continues; r a aborts, r e edits the rest", bench.value("vcs-git.operation").?);
    // A stop on a commit marked edit (git's `rebase-merge/amend`) names its own keys.
    try refreshWith(&bench, detached, "REBASE_HEAD\x1f" ++ second_hash ++ "\nrebase-merge/onto\x1f" ++ base_hash ++ "\nrebase-merge/amend\x1f" ++ first_hash ++ "\n");
    try testing.expectEqualStrings("Rebasing, stopped on a commit; change it (c a amends, c w rewords), then r r continues; r s skips it, r a aborts, r e edits the rest", bench.value("vcs-git.operation").?);
    // An `edit` in place: REBASE_HEAD is the commit amend names, which git prints once, under
    // amend, listed first.
    try refreshWith(&bench, detached, "rebase-merge/amend\x1f" ++ first_hash ++ "\nrebase-merge/onto\x1f" ++ base_hash ++ "\n");
    try testing.expectEqualStrings("Rebasing, stopped on a commit; change it (c a amends, c w rewords), then r r continues; r s skips it, r a aborts, r e edits the rest", bench.value("vcs-git.operation").?);
    // A commit made since the edit stopped: HEAD is no longer amend's, and `--continue` amends
    // nothing.
    const after_commit = "# branch.oid " ++ second_hash ++ "\x00# branch.head (detached)\x00";
    try refreshWith(&bench, after_commit, "rebase-merge/amend\x1f" ++ first_hash ++ "\nrebase-merge/onto\x1f" ++ base_hash ++ "\n");
    try testing.expectEqualStrings("Rebasing, stopped on a commit, and HEAD moved since it stopped: r r goes on from where it is; r s skips, r a aborts, r e edits the rest", bench.value("vcs-git.operation").?);
}

test "vcs git rebase: a conflict resolved and staged is told as one, not as a commit to amend" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openList(&bench);
    try beginAndAnswer(&bench, 1);
    // REBASE_HEAD is the commit that conflicted, HEAD the one before it: an amend would fold
    // the wrong one.
    const conflicted = detached ++ "u UU N... 100644 100644 100644 100644 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b a.txt\x00";
    const stopped = "REBASE_HEAD\x1f" ++ second_hash ++ "\nrebase-merge/onto\x1f" ++ base_hash ++ "\n";
    try answerRefresh(&bench, conflicted, stopped);
    try testing.expectEqualStrings("Rebasing, stopped on a conflict; resolve it and stage it, then r r continues; r s skips the commit, r a aborts, r e edits the rest", bench.value("vcs-git.operation").?);
    // Begun, though git exited failing: the list's rows are let go.
    try expectRows(&bench, &.{});
    try refreshWith(&bench, detached, stopped);
    try testing.expectEqualStrings("Rebasing, stopped on a resolved conflict; r r commits it and goes on, r s skips it, r a aborts, r e edits the rest", bench.value("vcs-git.operation").?);
}

test "vcs git rebase: a list made where HEAD no longer is is refused before anything runs" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openList(&bench);
    try press(&bench, .vcs_rebase_move_down);
    // A commit made since, outside: the status now says HEAD is elsewhere.
    const moved = "# branch.oid 9999999999999999999999999999999999999999\x00# branch.head main\x00";
    try refreshWith(&bench, moved, "");
    bench.forgetRequests();
    try press(&bench, .vcs_rebase_begin);
    try log_test.expectNoJob(&bench);
    var said: [8][]const u8 = undefined;
    try testing.expectEqualStrings("HEAD moved since the list was made; r i lists again", bench.told(&said)[0]);
    try testing.expectEqual(git_status.View.rebase, log_test.viewShown(&bench));
    try expectRows(&bench, &.{ "pick 2222222 Shout two", "pick 1111111 Add bees" });
}

test "vcs git rebase: C-c C-c reads the status first, and a HEAD that moved meanwhile refuses the list" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openList(&bench);
    bench.forgetRequests();
    try press(&bench, .vcs_rebase_begin);
    // The status held is stale: the refresh asked shows HEAD moved to a commit with nothing
    // beyond the base, where git would replay the list and say it rebased.
    var storage: [8]runner.Job = undefined;
    _ = try Bench.jobFor(bench.queued(&storage), .status);
    try answerRefresh(&bench, "# branch.oid " ++ base_hash ++ "\x00# branch.head main\x00", "");
    try status_test.expectNoCommand(&bench);
    var said: [8][]const u8 = undefined;
    var found = false;
    for (bench.told(&said)) |line| found = found or std.mem.eql(u8, line, "HEAD moved since the list was made; r i lists again");
    try testing.expect(found);
    try testing.expectEqual(git_status.View.rebase, log_test.viewShown(&bench));
    try expectRows(&bench, &.{ "pick 1111111 Add bees", "pick 2222222 Shout two" });
}

test "vcs git rebase: a start git refuses keeps the list and its cursor, shown again" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openList(&bench);
    try press(&bench, .vcs_rebase_move_down);
    try press(&bench, .vcs_rebase_drop);
    try beginAndAnswer(&bench, 1);
    // Unstaged changes, say: no rebase began.
    try answerRefresh(&bench, status_test.changed_status, "");
    try testing.expectEqual(git_status.View.rebase, log_test.viewShown(&bench));
    try expectRows(&bench, &.{ "pick 2222222 Shout two", "drop 1111111 Add bees" });
    try testing.expectEqualStrings("Add bees", try cursorSubject(&bench));
    var said: [8][]const u8 = undefined;
    var found = false;
    for (bench.told(&said)) |line| found = found or std.mem.eql(u8, line, "git did not begin the rebase; $ shows why; the list is as you left it");
    try testing.expect(found);
    // And it begins again from there.
    bench.forgetRequests();
    try beginVerified(&bench);
    _ = try status_test.expectCommand(&bench, .{ .rebase = .{ .base = base_hash } }, "pick " ++ second_hash ++ " Shout two\ndrop " ++ first_hash ++ " Add bees\n");
}

test "vcs git rebase: a list git refuses as missing commits is told in a person's words" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openList(&bench);
    try beginAndAnswer(&bench, 1);
    // `rebase.missingCommitsCheck`: the rebase begun and stopped before its first line, HEAD at
    // the base.
    const at_base = "# branch.oid " ++ base_hash ++ "\x00# branch.head (detached)\x00";
    try answerRefresh(&bench, at_base, "rebase-merge/onto\x1f" ++ base_hash ++ "\n");
    var said: [16][]const u8 = undefined;
    var found = false;
    for (bench.told(&said)) |line| found = found or std.mem.eql(u8, line, not_run_told);
    try testing.expect(found);
    try expectRows(&bench, &.{});
    // The status keeps saying so, never r r, for as long as the rebase lasts.
    const refused_line = not_run_line;
    try testing.expectEqualStrings(refused_line, bench.value("vcs-git.operation").?);
    try refreshWith(&bench, at_base, "rebase-merge/onto\x1f" ++ base_hash ++ "\n");
    try testing.expectEqualStrings(refused_line, bench.value("vcs-git.operation").?);
    // `r r`, `r s` and `r e` run nothing, and tell what is true.
    for ([_][]const u8{ "r", "s", "e" }) |key| {
        bench.forgetRequests();
        try rebaseMenu(&bench, key);
        try log_test.expectNoJob(&bench);
        try testing.expectEqualStrings(not_run_told, bench.told(&said)[0]);
    }
    // Aborted: the line is gone with the rebase.
    try refreshWith(&bench, status_test.changed_status, "");
    try testing.expectEqualStrings("", bench.value("vcs-git.operation").?);
}

test "vcs git rebase: an r r git refuses at the base with no conflict is told as a refused list, after a restart too" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    // The rebase stopped at the base, the panel knowing nothing of a refusal (a restart).
    try status_test.openAnswered(&bench);
    const at_base = "# branch.oid " ++ base_hash ++ "\x00# branch.head (detached)\x00";
    try refreshWith(&bench, at_base, "rebase-merge/onto\x1f" ++ base_hash ++ "\n");
    try testing.expectEqualStrings("Rebasing, stopped at a break; c w rewords HEAD, then r r continues; r a aborts, r e edits the rest", bench.value("vcs-git.operation").?);
    bench.forgetRequests();
    try rebaseMenu(&bench, "r");
    const go_on = try status_test.expectCommand(&bench, .rebase_continue, "");
    bench.forgetRequests();
    _ = try bench.finish(go_on, 1, "", "Warning: some commits may have been dropped accidentally.\n");
    bench.run();
    try answerRefresh(&bench, at_base, "rebase-merge/onto\x1f" ++ base_hash ++ "\n");
    var said: [16][]const u8 = undefined;
    var found = false;
    for (bench.told(&said)) |line| found = found or std.mem.eql(u8, line, not_run_told);
    try testing.expect(found);
    try testing.expectEqualStrings(not_run_line, bench.value("vcs-git.operation").?);
}

test "vcs git rebase: an r e whose read git refuses at the base is told as a list not run, after a restart" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    const at_base = "# branch.oid " ++ base_hash ++ "\x00# branch.head (detached)\x00";
    try refreshWith(&bench, at_base, "rebase-merge/onto\x1f" ++ base_hash ++ "\n");
    bench.forgetRequests();
    try rebaseMenu(&bench, "e");
    const read = try log_test.onlyJob(&bench, .rebase_todo);
    // With the check, git refuses to show a list lacking commits, and keeps its record of them.
    try status_test.expectArgv(read, .rebase_todo);
    bench.forgetRequests();
    _ = try bench.finish(read, 1, "", "Warning: some commits may have been dropped accidentally.\n");
    bench.run();
    var said: [8][]const u8 = undefined;
    try testing.expectEqualStrings(not_run_told, bench.told(&said)[0]);
    try testing.expectEqualStrings(not_run_line, bench.value("vcs-git.operation").?);
    try testing.expectEqual(git_status.View.status, log_test.viewShown(&bench));
    // `r i` there says what the line says, never to edit a list git refuses to show.
    bench.forgetRequests();
    try rebaseMenu(&bench, "i");
    try log_test.expectNoJob(&bench);
    try testing.expectEqualStrings(not_run_told, bench.told(&said)[0]);
}

test "vcs git rebase: a REBASE_HEAD git left behind is no rebase" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try refreshWith(&bench, status_test.changed_status, "REBASE_HEAD\x1f" ++ first_hash ++ "\n");
    try testing.expectEqualStrings("", bench.value("vcs-git.operation").?);
}

test "vcs git rebase: a rebase check ended by a signal tells nothing, and the next refresh asks again" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    // HEAD detached and no operation's ref, as at any stop in a reftable repository.
    const at_base = "# branch.oid " ++ base_hash ++ "\x00# branch.head (detached)\x00";
    // `rebase_check` ended by a signal: no rebase is taken for one, nor is the commit taken as
    // checked.
    bench.forgetRequests();
    try bench.act(.vcs_git_refresh);
    try answerRefreshChecked(&bench, at_base, "", -9);
    try testing.expectEqualStrings("", bench.value("vcs-git.operation").?);
    bench.forgetRequests();
    try bench.act(.vcs_git_refresh);
    try answerRefreshChecked(&bench, at_base, "", 0);
    try testing.expect(std.mem.startsWith(u8, bench.value("vcs-git.operation").?, "Rebasing"));
}

test "vcs git rebase: a status that could not be read gives no list to git" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openList(&bench);
    bench.forgetRequests();
    try press(&bench, .vcs_rebase_begin);
    var storage: [8]runner.Job = undefined;
    const queued = bench.queued(&storage);
    var jobs: [8]runner.Job = undefined;
    @memcpy(jobs[0..queued.len], queued);
    bench.forgetRequests();
    for (jobs[0..queued.len]) |job| {
        const failed = Bench.purposeOf(job) == .status;
        const answer: []const u8 = if (Bench.purposeOf(job) == .recent) status_test.recent_commits else "";
        _ = try bench.finish(job, if (failed) 1 else 0, answer, if (failed) "fatal: index locked\n" else "");
    }
    bench.run();
    try status_test.expectNoCommand(&bench);
    var said: [8][]const u8 = undefined;
    var found = false;
    for (bench.told(&said)) |line| found = found or std.mem.eql(u8, line, "The status could not be read ($ shows why); the list was not given to git");
    try testing.expect(found);
    try expectRows(&bench, &.{ "pick 1111111 Add bees", "pick 2222222 Shout two" });
}

test "vcs git rebase: the rest of a list read before the rebase moved on is not written back" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try rebaseMenu(&bench, "e");
    try log_test.answer(&bench, try log_test.onlyJob(&bench, .rebase_todo), 0, "pick 1111111 Add bees\npick 2222222 Shout two\n");
    // `r r` ran meanwhile (from `$`, say): HEAD moved on.
    try refreshWith(&bench, detached, "rebase-merge/onto\x1f" ++ base_hash ++ "\n");
    bench.forgetRequests();
    try press(&bench, .vcs_rebase_begin);
    try log_test.expectNoJob(&bench);
    var said: [8][]const u8 = undefined;
    try testing.expectEqualStrings("The rebase moved on since its list was read; r e reads it again", bench.told(&said)[0]);
}

test "vcs git rebase: continue is given no input" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try rebaseMenu(&bench, "r");
    const job = try status_test.expectCommand(&bench, .rebase_continue, "");
    // git's editor is the host writing an empty input over nothing: git keeps its message.
    try testing.expect(std.mem.indexOf(u8, job.environment, "GIT_EDITOR=\"/opt/mesha/mesha\" --stdin-to-file") != null);
    bench.forgetRequests();
    try rebaseMenu(&bench, "s");
    _ = try status_test.expectCommand(&bench, .rebase_skip, "");
}

test "vcs git rebase: r e shows what is left of the list, git's own lines kept, and C-c C-c writes it back" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try rebaseMenu(&bench, "e");
    const read = try log_test.onlyJob(&bench, .rebase_todo);
    try status_test.expectArgv(read, .rebase_todo);
    try testing.expect(std.mem.endsWith(u8, read.environment, "GIT_SEQUENCE_EDITOR=\"/opt/mesha/mesha\" --file-to-stdout"));
    try testing.expectEqualStrings("", read.input);
    try log_test.answer(&bench, read, 0, "pick 1111111 Add bees\nbreak\npick 2222222 Shout two\n#\n# Commands:\n");
    try testing.expectEqual(git_status.View.rebase, log_test.viewShown(&bench));
    try expectRows(&bench, &.{ "pick 1111111 Add bees", "break  ", "pick 2222222 Shout two" });
    try testing.expectEqualStrings("the 3 lines left", bench.value("vcs-git.rebase-count").?);
    // A line of git's own takes no action.
    try bench.act(.vcs_git_next);
    try press(&bench, .vcs_rebase_drop);
    var said: [8][]const u8 = undefined;
    try testing.expectEqualStrings("A line of git's own: it is kept as it is", bench.told(&said)[0]);
    try press(&bench, .vcs_rebase_move_down);
    bench.forgetRequests();
    try beginVerified(&bench);
    _ = try status_test.expectCommand(&bench, .rebase_edit_todo, "pick 1111111 Add bees\npick 2222222 Shout two\nbreak\n");
}

test "vcs git rebase: with --autosquash a fixup is put after the commit it names" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try bench.placeCursor(try bench.spotOf(.recent, "72f25b6"));
    try rebaseMenu(&bench, "-ai");
    const listing = try log_test.onlyJob(&bench, .rebase_list);
    const third_hash = "3333333333333333333333333333333333333333";
    const with_fixup = first_hash ++ "\x1f1111111\x1fAna\x1f2026-11-21\x1f\x1fAdd bees\x00" ++
        second_hash ++ "\x1f2222222\x1fAna\x1f2026-11-22\x1f\x1fShout two\x00" ++
        third_hash ++ "\x1f3333333\x1fAna\x1f2026-11-23\x1fHEAD -> main\x1ffixup! Add bees\x00";
    try log_test.answer(&bench, listing, 0, with_fixup);
    try expectRows(&bench, &.{ "pick 1111111 Add bees", "fixup 3333333 fixup! Add bees", "pick 2222222 Shout two" });
    try beginVerified(&bench);
    _ = try status_test.expectCommand(&bench, .{ .rebase = .{ .arguments = "--autosquash\x1f", .base = base_hash } }, "pick " ++ first_hash ++ " Add bees\nfixup " ++ third_hash ++ " fixup! Add bees\npick " ++ second_hash ++ " Shout two\n");
}

test "vcs git rebase: a list longer than the table holds is refused, never begun" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try bench.placeCursor(try bench.spotOf(.recent, "72f25b6"));
    try rebaseMenu(&bench, "i");
    const listing = try log_test.onlyJob(&bench, .rebase_list);
    var many: std.Io.Writer.Allocating = .init(bench.arena.allocator());
    for (0..git_rebase.max_commits + 1) |index| {
        try many.writer.print("{x:0>40}\x1f{x:0>7}\x1fAna\x1f2026-11-21\x1f\x1fCommit {d}\x00", .{ index + 1, index + 1, index });
    }
    try log_test.answer(&bench, listing, 0, many.written());
    try testing.expectEqual(git_status.View.status, log_test.viewShown(&bench));
    try expectRows(&bench, &.{});
}

// ---- against a real git ------------------------------------------------------------------------

/// What the host does as git's editor, for the real-git test: `--stdin-to-file FILE` writes its
/// input over `FILE` unless the input is empty, `--file-to-stdout FILE` prints `FILE`.
const stand_in_editor =
    \\#!/bin/sh
    \\case "$1" in
    \\--stdin-to-file) cat > "$2.input"; if [ -s "$2.input" ]; then cat "$2.input" > "$2"; fi; rm -f "$2.input" ;;
    \\--file-to-stdout) cat "$2" ;;
    \\*) exit 2 ;;
    \\esac
    \\
;

/// Runs frames until the panel has nothing queued or running; fails after a few seconds.
fn settle(desk: *commit_test.Desk) !void {
    try settleShowing(desk, null);
}

/// Runs frames until the panel has nothing queued or running and, when `wanted` is given, shows
/// that view: a list asked is in no count the panel keeps, and shows once it answers.
fn settleShowing(desk: *commit_test.Desk, wanted: ?git_status.View) !void {
    for (0..1000) |_| {
        try commit_test.stepReal(desk);
        const state = desk.bench.tables.findByName(Atom.from(git_status.state_table_name)).?;
        var rows = state.readQuery(struct { refresh_jobs: *u8, commands_running: *u8, answered: *u8 });
        const row = rows.next().?.view;
        const busy = runner.busy(&desk.bench.tables, sequencer.inboxOf(git_status.system()));
        const shown = if (wanted) |view_wanted| log_test.viewShown(&desk.bench) == view_wanted else true;
        if (row.answered.* == 1 and row.refresh_jobs.* == 0 and row.commands_running.* == 0 and !busy and shown) return;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.Timeout;
}

/// The panel's knowledge of a list git did not run forgotten, as a restart of the editor forgets
/// it.
fn forgetRefused(bench: *Bench) void {
    const state = bench.tables.findByName(Atom.from(git_status.state_table_name)).?;
    const row = state.getRow(.{ .row = 0, .generation = state.rowGeneration(0) }, struct { rebase_refused: *u8 }).?;
    row.rebase_refused.* = 0;
}

/// `r i` from the recent commit `short_hash`, settled: the list shown.
fn rebaseFrom(desk: *commit_test.Desk, short_hash: []const u8) !void {
    try desk.bench.placeCursor(try desk.bench.spotOf(.recent, short_hash));
    try rebaseMenu(&desk.bench, "i");
    try settleShowing(desk, .rebase);
}

test "vcs git rebase: two commits swapped, and a reword that stops, is amended and continues, in a real repository" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var folder = try status_test.repositoryFolder();
    defer folder.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_length = try folder.dir.realPath(testing.io, &path_buffer);
    const top = path_buffer[0..path_length];
    try folder.dir.writeFile(testing.io, .{ .sub_path = "gitconfig", .data = "" });
    try folder.dir.writeFile(testing.io, .{ .sub_path = "editor", .data = stand_in_editor, .flags = .{ .permissions = .executable_file } });
    try folder.dir.createDirPath(testing.io, "repo");
    const repository = try std.fs.path.join(allocator, &.{ top, "repo" });
    const editor = try std.fs.path.join(allocator, &.{ top, "editor" });
    const global_config = try std.fs.path.join(allocator, &.{ top, "gitconfig" });
    var environment = try status_test.gitEnvironment();
    defer environment.deinit();
    try environment.put("GIT_CONFIG_GLOBAL", global_config);
    try environment.put("GIT_CONFIG_NOSYSTEM", "1");
    try environment.put("GIT_AUTHOR_NAME", "Test");
    try environment.put("GIT_AUTHOR_EMAIL", "test@example.com");
    try environment.put("GIT_COMMITTER_NAME", "Test");
    try environment.put("GIT_COMMITTER_EMAIL", "test@example.com");
    var repository_dir = try folder.dir.openDir(testing.io, "repo", .{});
    defer repository_dir.close(testing.io);
    _ = status_test.runGit(allocator, &environment, repository, &.{ "init", "-q", "-b", "main" }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    const files = [_][]const u8{ "a.txt", "b.txt", "c.txt" };
    const subjects = [_][]const u8{ "First", "Second", "Third" };
    for (files, subjects) |file, subject| {
        try repository_dir.writeFile(testing.io, .{ .sub_path = file, .data = subject });
        _ = try status_test.runGit(allocator, &environment, repository, &.{ "add", file });
        _ = try status_test.runGit(allocator, &environment, repository, &.{ "commit", "-q", "-m", subject });
    }
    const first_full = try status_test.runGit(allocator, &environment, repository, &.{ "rev-parse", "--short=7", "HEAD~2" });
    const first_short = std.mem.trimEnd(u8, first_full, "\n");

    var desk: commit_test.Desk = .{ .bench = .{ .working_directory = repository, .executable = editor } };
    try desk.init();
    defer desk.deinit();
    var processes: mesha_runtime.process.Processes = undefined;
    try status_test.startProcesses(&desk.bench, &processes, &environment);
    defer processes.deinit(&desk.bench.tables);
    try desk.bench.act(.vcs_git_status);
    try settle(&desk);

    // `r i` after First: Second and Third listed, oldest first; M-n swaps them; C-c C-c.
    try rebaseFrom(&desk, first_short);
    try expectRows(&desk.bench, &.{ try rowLine(allocator, &environment, repository, "HEAD~1", "Second"), try rowLine(allocator, &environment, repository, "HEAD", "Third") });
    try press(&desk.bench, .vcs_rebase_move_down);
    try press(&desk.bench, .vcs_rebase_begin);
    try settle(&desk);
    try testing.expectEqualStrings("Second\nThird\nFirst\n", try status_test.runGit(allocator, &environment, repository, &.{ "log", "--format=%s" }));
    try testing.expectEqualStrings("", desk.bench.value("vcs-git.operation").?);

    // `r i` again, the oldest of the two reworded: the rebase stops after it, at its break.
    try rebaseFrom(&desk, first_short);
    try press(&desk.bench, .vcs_rebase_reword);
    try press(&desk.bench, .vcs_rebase_begin);
    try settle(&desk);
    try testing.expectEqualStrings("Rebasing, stopped at a break; c w rewords HEAD, then r r continues; r a aborts, r e edits the rest", desk.bench.value("vcs-git.operation").?);

    // `c w`: HEAD's message in the buffer, reworded, committed.
    try desk.commit("w");
    try commit_test.settleReal(&desk, .editing);
    try testing.expectEqualStrings("Third", (try desk.message()).?);
    desk.write("Third, reworded\n");
    try desk.act(.vcs_message_finish);
    try commit_test.settleReal(&desk, .none);

    // `r r`: the rebase goes on, given no input, and ends.
    try rebaseMenu(&desk.bench, "r");
    try settle(&desk);
    try testing.expectEqualStrings("Second\nThird, reworded\nFirst\n", try status_test.runGit(allocator, &environment, repository, &.{ "log", "--format=%s" }));
    try testing.expectEqualStrings("", desk.bench.value("vcs-git.operation").?);
    try testing.expectEqualStrings("main\n", try status_test.runGit(allocator, &environment, repository, &.{ "branch", "--show-current" }));

    // A list made, then a commit made outside and the status read again: C-c C-c refuses, and
    // HEAD is where the commit left it.
    try rebaseFrom(&desk, first_short);
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "commit", "-q", "--allow-empty", "-m", "Outside" });
    const outside = try status_test.runGit(allocator, &environment, repository, &.{ "rev-parse", "HEAD" });
    try desk.bench.act(.vcs_git_refresh);
    try settleShowing(&desk, .rebase);
    try press(&desk.bench, .vcs_rebase_begin);
    try settleShowing(&desk, .rebase);
    try testing.expect(desk.told("HEAD moved since the list was made; r i lists again"));
    try testing.expectEqualStrings(outside, try status_test.runGit(allocator, &environment, repository, &.{ "rev-parse", "HEAD" }));
    try press(&desk.bench, .vcs_rebase_leave);
    try settle(&desk);

    // A list made, then a commit made outside with the status not read since: C-c C-c reads
    // the status first, and refuses all the same.
    try rebaseFrom(&desk, first_short);
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "commit", "-q", "--allow-empty", "-m", "Outside again" });
    const outside_again = try status_test.runGit(allocator, &environment, repository, &.{ "rev-parse", "HEAD" });
    desk.said.clearRetainingCapacity();
    try press(&desk.bench, .vcs_rebase_begin);
    try settleShowing(&desk, .rebase);
    try testing.expect(desk.told("HEAD moved since the list was made; r i lists again"));
    try testing.expectEqualStrings(outside_again, try status_test.runGit(allocator, &environment, repository, &.{ "rev-parse", "HEAD" }));
    try press(&desk.bench, .vcs_rebase_leave);
    try settle(&desk);

    // A rebase begun outside with a list git refuses as missing commits (its sequence editor
    // keeps the first line alone), the panel knowing nothing of it, as after a restart: `r r`
    // runs and git refuses it again, by the check it runs with, told; then, forgotten again,
    // `r e`'s read is refused too (git keeps its record of the commits left out), told; now known,
    // `r e` and `r r` run nothing; `r a` aborts, and every commit is on the branch.
    try environment.put("GIT_SEQUENCE_EDITOR", "sed -i -e 2,\\$d");
    const outcome = try status_test.runGitFailing(allocator, &environment, repository, &.{ "-c", "rebase.missingCommitsCheck=error", "rebase", "-i", "HEAD~2" });
    try testing.expectEqual(status_test.GitOutcome.failed, outcome);
    _ = environment.swapRemove("GIT_SEQUENCE_EDITOR");
    try desk.bench.act(.vcs_git_refresh);
    try settle(&desk);
    desk.said.clearRetainingCapacity();
    try rebaseMenu(&desk.bench, "r");
    try settle(&desk);
    try testing.expect(desk.told(not_run_told));
    try testing.expectEqualStrings(not_run_line, desk.bench.value("vcs-git.operation").?);
    forgetRefused(&desk.bench);
    desk.said.clearRetainingCapacity();
    try rebaseMenu(&desk.bench, "e");
    // The read is counted in no refresh or command: frames run until its answer is told.
    for (0..1000) |_| {
        try commit_test.stepReal(&desk);
        if (desk.told(not_run_told)) break;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    try testing.expect(desk.told(not_run_told));
    try testing.expectEqual(git_status.View.status, log_test.viewShown(&desk.bench));
    desk.bench.forgetRequests();
    try rebaseMenu(&desk.bench, "e");
    try rebaseMenu(&desk.bench, "r");
    try status_test.expectNoCommand(&desk.bench);
    try settle(&desk);
    try testing.expectEqualStrings("Outside again\n", try status_test.runGit(allocator, &environment, repository, &.{ "log", "-1", "--format=%s", "main" }));
    desk.bench.forgetRequests();
    try rebaseMenu(&desk.bench, "a");
    const abort = desk.bench.dialog() orelse return error.NoDialog;
    desk.bench.forgetRequests();
    try desk.bench.choose(abort, "Abort");
    try settle(&desk);
    try testing.expectEqualStrings("Outside again\nOutside\nSecond\n", try status_test.runGit(allocator, &environment, repository, &.{ "log", "-3", "--format=%s" }));
    try testing.expectEqualStrings("", desk.bench.value("vcs-git.operation").?);

    // An `edit` in place: the line offers `c a` and `c w`; amended, `r r` finishes with the
    // amended commit where it was.
    try rebaseFrom(&desk, first_short);
    try press(&desk.bench, .vcs_rebase_edit);
    try press(&desk.bench, .vcs_rebase_begin);
    try settle(&desk);
    try testing.expectEqualStrings("Rebasing, stopped on a commit; change it (c a amends, c w rewords), then r r continues; r s skips it, r a aborts, r e edits the rest", desk.bench.value("vcs-git.operation").?);
    try desk.commit("a");
    try commit_test.settleReal(&desk, .editing);
    desk.write("Third, amended\n");
    try desk.act(.vcs_message_finish);
    try commit_test.settleReal(&desk, .none);
    try rebaseMenu(&desk.bench, "r");
    try settle(&desk);
    try testing.expectEqualStrings("", desk.bench.value("vcs-git.operation").?);
    try testing.expectEqualStrings("Outside again\nOutside\nSecond\nThird, amended\nFirst\n", try status_test.runGit(allocator, &environment, repository, &.{ "log", "--format=%s" }));
    try testing.expectEqualStrings("main\n", try status_test.runGit(allocator, &environment, repository, &.{ "branch", "--show-current" }));
}

test "vcs git rebase: a rebase that conflicts, resolved and staged, is told as a conflict and r r finishes with every commit, in a real repository" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var folder = try status_test.repositoryFolder();
    defer folder.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_length = try folder.dir.realPath(testing.io, &path_buffer);
    const top = path_buffer[0..path_length];
    try folder.dir.writeFile(testing.io, .{ .sub_path = "gitconfig", .data = "" });
    try folder.dir.writeFile(testing.io, .{ .sub_path = "editor", .data = stand_in_editor, .flags = .{ .permissions = .executable_file } });
    try folder.dir.createDirPath(testing.io, "repo");
    const repository = try std.fs.path.join(allocator, &.{ top, "repo" });
    const editor = try std.fs.path.join(allocator, &.{ top, "editor" });
    const global_config = try std.fs.path.join(allocator, &.{ top, "gitconfig" });
    var environment = try status_test.gitEnvironment();
    defer environment.deinit();
    try environment.put("GIT_CONFIG_GLOBAL", global_config);
    try environment.put("GIT_CONFIG_NOSYSTEM", "1");
    try environment.put("GIT_AUTHOR_NAME", "Test");
    try environment.put("GIT_AUTHOR_EMAIL", "test@example.com");
    try environment.put("GIT_COMMITTER_NAME", "Test");
    try environment.put("GIT_COMMITTER_EMAIL", "test@example.com");
    var repository_dir = try folder.dir.openDir(testing.io, "repo", .{});
    defer repository_dir.close(testing.io);
    _ = status_test.runGit(allocator, &environment, repository, &.{ "init", "-q", "-b", "main" }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    // `other` and `main` change x.txt each their own way after `Start`; main adds y.txt after.
    try repository_dir.writeFile(testing.io, .{ .sub_path = "x.txt", .data = "one\n" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "add", "x.txt" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "commit", "-q", "-m", "Start" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "switch", "-q", "-c", "other" });
    try repository_dir.writeFile(testing.io, .{ .sub_path = "x.txt", .data = "other\n" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "commit", "-q", "-am", "Other's x" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "switch", "-q", "main" });
    try repository_dir.writeFile(testing.io, .{ .sub_path = "x.txt", .data = "main\n" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "commit", "-q", "-am", "Main's x" });
    try repository_dir.writeFile(testing.io, .{ .sub_path = "y.txt", .data = "why\n" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "add", "y.txt" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "commit", "-q", "-m", "Add y" });

    var desk: commit_test.Desk = .{ .bench = .{ .working_directory = repository, .executable = editor } };
    try desk.init();
    defer desk.deinit();
    var processes: mesha_runtime.process.Processes = undefined;
    try status_test.startProcesses(&desk.bench, &processes, &environment);
    defer processes.deinit(&desk.bench.tables);
    try desk.bench.act(.vcs_git_status);
    try settle(&desk);

    // `r i` off a commit: onto `other`, read in the prompt of the branches.
    try desk.bench.act(.vcs_git_first);
    desk.bench.forgetRequests();
    try rebaseMenu(&desk.bench, "i");
    var prompt: ?Bench.Presented = null;
    for (0..1000) |_| {
        try commit_test.stepReal(&desk);
        prompt = desk.bench.dialog();
        if (prompt != null) break;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    desk.bench.forgetRequests();
    try desk.bench.choose(prompt orelse return error.NoPrompt, "other");
    try settleShowing(&desk, .rebase);
    try expectRows(&desk.bench, &.{ try rowLine(allocator, &environment, repository, "HEAD~1", "Main's x"), try rowLine(allocator, &environment, repository, "HEAD", "Add y") });

    // The first pick conflicts: git exits failing, yet the rebase began; the list goes.
    try press(&desk.bench, .vcs_rebase_begin);
    try settle(&desk);
    try testing.expectEqualStrings("Rebasing, stopped on a conflict; resolve it and stage it, then r r continues; r s skips the commit, r a aborts, r e edits the rest", desk.bench.value("vcs-git.operation").?);
    try expectRows(&desk.bench, &.{});

    // Resolved and staged: told as the conflict it was, not as a commit to amend.
    try repository_dir.writeFile(testing.io, .{ .sub_path = "x.txt", .data = "both\n" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "add", "x.txt" });
    try desk.bench.act(.vcs_git_refresh);
    try settle(&desk);
    try testing.expectEqualStrings("Rebasing, stopped on a resolved conflict; r r commits it and goes on, r s skips it, r a aborts, r e edits the rest", desk.bench.value("vcs-git.operation").?);

    // `r r`: the resolved commit made with its own message, the rest picked; every commit there.
    try rebaseMenu(&desk.bench, "r");
    try settle(&desk);
    try testing.expectEqualStrings("", desk.bench.value("vcs-git.operation").?);
    try testing.expectEqualStrings("Add y\nMain's x\nOther's x\nStart\n", try status_test.runGit(allocator, &environment, repository, &.{ "log", "--format=%s" }));
    try testing.expectEqualStrings("both\n", try status_test.runGit(allocator, &environment, repository, &.{ "show", "HEAD:x.txt" }));

    // A rebase whose last step conflicts, resolved and continued: git leaves REBASE_HEAD behind,
    // which is no rebase: the status shows none, and `b k` deletes a branch.
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "switch", "-q", "-c", "late", "HEAD~1" });
    try repository_dir.writeFile(testing.io, .{ .sub_path = "y.txt", .data = "late\n" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "add", "y.txt" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "commit", "-q", "-m", "Late y" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "switch", "-q", "main" });
    try desk.bench.act(.vcs_git_refresh);
    try settle(&desk);
    try desk.bench.act(.vcs_git_first);
    desk.bench.forgetRequests();
    try rebaseMenu(&desk.bench, "i");
    var late_prompt: ?Bench.Presented = null;
    for (0..1000) |_| {
        try commit_test.stepReal(&desk);
        late_prompt = desk.bench.dialog();
        if (late_prompt != null) break;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    desk.bench.forgetRequests();
    try desk.bench.choose(late_prompt orelse return error.NoPrompt, "late");
    try settleShowing(&desk, .rebase);
    try press(&desk.bench, .vcs_rebase_begin);
    try settle(&desk);
    try repository_dir.writeFile(testing.io, .{ .sub_path = "y.txt", .data = "why late\n" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "add", "y.txt" });
    try rebaseMenu(&desk.bench, "r");
    try settle(&desk);
    try testing.expectEqualStrings("main\n", try status_test.runGit(allocator, &environment, repository, &.{ "branch", "--show-current" }));
    try testing.expectEqualStrings("", desk.bench.value("vcs-git.operation").?);
    desk.bench.forgetRequests();
    try log_test.chooseIn(&desk.bench, Atom.from(git_branch.Msg.vcs_git_branch_menu), &git_branch.branch_menu, &.{}, "k");
    var delete_prompt: ?Bench.Presented = null;
    for (0..1000) |_| {
        try commit_test.stepReal(&desk);
        delete_prompt = desk.bench.dialog();
        if (delete_prompt != null) break;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    desk.bench.forgetRequests();
    try desk.bench.choose(delete_prompt orelse return error.NoPrompt, "late");
    try settle(&desk);
    try testing.expectEqualStrings("", try status_test.runGit(allocator, &environment, repository, &.{ "branch", "--list", "late" }));
}

/// The row the list shows for `revision`, whose subject is `subject`: `pick`, its short hash and
/// its subject.
fn rowLine(allocator: std.mem.Allocator, environment: *std.process.Environ.Map, repository: []const u8, revision: []const u8, subject: []const u8) ![]const u8 {
    const short = try status_test.runGit(allocator, environment, repository, &.{ "rev-parse", "--short", revision });
    return std.fmt.allocPrint(allocator, "pick {s} {s}", .{ std.mem.trimEnd(u8, short, "\n"), subject });
}
