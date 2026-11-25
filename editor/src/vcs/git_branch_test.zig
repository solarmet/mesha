//! Tests of vcs-git's branches, merges and remotes (`git_branch.zig`, `git_remote.zig`), run on
//! the panel's bench (`git_status_test.zig`): a menu's answer is given as the menu gives it, a
//! prompt or a dialog answered as the palette answers, and each job's answer as the runner gives
//! it. One test makes, switches to, merges and deletes a branch, pushes, pulls and is refused a
//! push, through the panel's own path, in real git repositories, a bare one as the remote
//! (skipped on Windows and where `git` is not on `PATH`).

const std = @import("std");
const builtin = @import("builtin");
const mesha = @import("mesha");
const mesha_runtime = @import("mesha_runtime");
const Atom = mesha.Atom;
const sequencer = mesha.sequencer;
const runner = @import("runner.zig");
const git_status = @import("git_status.zig");
const git_branch = @import("git_branch.zig");
const git_remote = @import("git_remote.zig");
const git_commit = @import("git_commit.zig");
const git_log = @import("git_log.zig");
const git_rebase = @import("git_rebase.zig");
const transient = @import("../transient.zig");
const status_test = @import("git_status_test.zig");
const log_test = @import("git_log_test.zig");
const Bench = status_test.Bench;
const testing = std.testing;

/// Every branch as `for-each-ref` lists them: `main`, the current, tracking `origin/main`; a
/// local `feature`; and `origin/main`.
const listed_refs = "refs/heads/main\x1fmain\x1forigin/main\x1f*\nrefs/heads/feature\x1ffeature\x1f\x1f \nrefs/remotes/origin/main\x1forigin/main\x1f\x1f \n";

/// The menu `menu` opened by `opener`, then `keys` typed, the last choosing a command.
fn chooseIn(bench: *Bench, opener: Atom, menu: *const mesha.ui.transient.Menu, keys: []const u8) !void {
    try log_test.chooseIn(bench, opener, menu, &.{}, keys);
}

/// The prompt opened since the requests were last forgotten, its entries' labels as listed.
fn promptLabels(bench: *Bench, into: [][]const u8) ![][]const u8 {
    const prompt = bench.dialog() orelse return error.NoPrompt;
    for (prompt.completions.entries, 0..) |entry, index| into[index] = entry.label;
    return into[0..prompt.completions.entries.len];
}

/// Expects `job`'s environment to make git ask no password and take the host as its editors.
fn expectQuietEnvironment(job: runner.Job) !void {
    try testing.expect(std.mem.startsWith(u8, job.environment, "GIT_TERMINAL_PROMPT=0\x1f"));
    try testing.expect(std.mem.indexOf(u8, job.environment, "GIT_EDITOR=\"/opt/mesha/mesha\" --stdin-to-file") != null);
}

test "vcs git branch: b k on an unmerged branch offers to force" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_branch_menu), &git_branch.branch_menu, "k");
    const refs = try log_test.onlyJob(&bench, .refs);
    try status_test.expectArgv(refs, .refs);
    _ = try bench.finish(refs, 0, listed_refs, "");
    bench.run();
    // A delete lists the local branches alone.
    var labels: [4][]const u8 = undefined;
    const listed = try promptLabels(&bench, &labels);
    try testing.expectEqual(@as(usize, 2), listed.len);
    try testing.expectEqualStrings("main", listed[0]);
    try testing.expectEqualStrings("feature", listed[1]);
    const prompt = bench.dialog().?;
    bench.forgetRequests();
    try bench.choose(prompt, "feature");
    const delete = try status_test.expectCommand(&bench, .{ .delete_branch = .{ .name = "feature" } }, "");

    // git refuses `-d`: the dialog offers `-D`.
    bench.forgetRequests();
    _ = try bench.finish(delete, 1, "", "error: the branch 'feature' is not fully merged\n");
    bench.run();
    const asked = bench.dialog() orelse return error.NoDialog;
    try testing.expectEqualStrings("Delete feature anyway?", asked.completions.title);
    try testing.expectEqualStrings("Delete with -D", asked.completions.entries[0].label);
    var said: [8][]const u8 = undefined;
    try testing.expectEqualStrings("git branch failed; $ shows why", bench.told(&said)[0]);
    bench.forgetRequests();
    try bench.choose(asked, "Delete with -D");
    _ = try status_test.expectCommand(&bench, .{ .delete_branch = .{ .name = "feature", .how = .force } }, "");

    // The branch HEAD is on is refused before anything runs.
    bench.forgetRequests();
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_branch_menu), &git_branch.branch_menu, "k");
    _ = try bench.finish(try log_test.onlyJob(&bench, .refs), 0, listed_refs, "");
    bench.run();
    const again = bench.dialog().?;
    bench.forgetRequests();
    try bench.choose(again, "main");
    try status_test.expectNoCommand(&bench);
    try testing.expectEqualStrings("That is the branch HEAD is on: switch to another first", bench.told(&said)[0]);
}

test "vcs git remote: P p with no upstream asks for a remote and pushes with -u" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const no_upstream = "# branch.oid 5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\x00# branch.head side\x00";
    try status_test.openAnsweredWith(&bench, no_upstream);
    try chooseIn(&bench, Atom.from(git_remote.Msg.vcs_git_push_menu), &git_remote.push_menu, "p");
    // One `git remote` fills the prompt as it opens.
    const remotes = try log_test.onlyJob(&bench, .remotes);
    try status_test.expectArgv(remotes, .remotes);
    _ = try bench.finish(remotes, 0, "backup\norigin\n", "");
    bench.run();
    var labels: [4][]const u8 = undefined;
    const listed = try promptLabels(&bench, &labels);
    try testing.expectEqual(@as(usize, 2), listed.len);
    const prompt = bench.dialog().?;
    bench.forgetRequests();
    try bench.choose(prompt, "origin");
    const push = try status_test.expectCommand(&bench, .{ .push = .{ .arguments = "--set-upstream\x1f", .remote = "origin", .branch = "side" } }, "");
    try expectQuietEnvironment(push);
}

test "vcs git remote: F p -r pulls with --rebase" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try chooseIn(&bench, Atom.from(git_remote.Msg.vcs_git_pull_menu), &git_remote.pull_menu, "-rp");
    const pull = try status_test.expectCommand(&bench, .{ .pull = "--rebase\x1f" }, "");
    try expectQuietEnvironment(pull);
    // Its end asks for the operation in progress: a pull may stop on conflicts.
    bench.forgetRequests();
    _ = try bench.finish(pull, 0, "", "");
    bench.run();
    var storage: [8]runner.Job = undefined;
    _ = try Bench.jobFor(bench.queued(&storage), .operation);
}

test "vcs git remote: g while a pull runs keeps the pull's ask for the operation in progress in the refresh that follows" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try chooseIn(&bench, Atom.from(git_remote.Msg.vcs_git_pull_menu), &git_remote.pull_menu, "p");
    var storage: [8]runner.Job = undefined;
    _ = try status_test.expectCommand(&bench, .{ .pull = "" }, "");
    // `g` while the pull runs: a refresh by rule, no operation asked.
    try bench.act(.vcs_git_refresh);
    const asked = bench.queued(&storage);
    try testing.expectError(error.NotQueued, Bench.jobFor(asked, .operation));
    // The pull ends while the refresh runs, which notes the refresh its end asks; then the
    // refresh ends, and the one noted runs asking for the operation, as the pull's end did.
    bench.forgetRequests();
    _ = try bench.finish(try Bench.jobFor(asked, .command), 0, "", "");
    _ = try bench.finish(try Bench.jobFor(asked, .status), 0, status_test.changed_status, "");
    _ = try bench.finish(try Bench.jobFor(asked, .recent), 0, status_test.recent_commits, "");
    bench.run();
    _ = try Bench.jobFor(bench.queued(&storage), .status);
    _ = try Bench.jobFor(bench.queued(&storage), .operation);
}

test "vcs git remote: a push with --force asks first, and --force-with-lease does not" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try chooseIn(&bench, Atom.from(git_remote.Msg.vcs_git_push_menu), &git_remote.push_menu, "-Fp");
    try status_test.expectNoCommand(&bench);
    const asked = bench.dialog() orelse return error.NoDialog;
    try testing.expectEqualStrings("Push main with --force?", asked.completions.title);
    bench.forgetRequests();
    try bench.choose(asked, "Force push");
    _ = try status_test.expectCommand(&bench, .{ .push = .{ .arguments = "--force\x1f" } }, "");

    bench.forgetRequests();
    try chooseIn(&bench, Atom.from(git_remote.Msg.vcs_git_push_menu), &git_remote.push_menu, "-fp");
    try testing.expect(bench.dialog() == null);
    _ = try status_test.expectCommand(&bench, .{ .push = .{ .arguments = "--force-with-lease\x1f" } }, "");
}

test "vcs git branch: m a asks first, and a merge chosen runs with the menu's switches and no input" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    var said: [8][]const u8 = undefined;
    // No merge in progress: told, nothing asked.
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_merge_menu), &git_branch.merge_menu, "a");
    try testing.expect(bench.dialog() == null);
    try testing.expectEqualStrings("No merge is in progress", bench.told(&said)[0]);

    bench.forgetRequests();
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_merge_menu), &git_branch.merge_menu, "-nm");
    _ = try bench.finish(try log_test.onlyJob(&bench, .refs), 0, listed_refs, "");
    bench.run();
    const prompt = bench.dialog().?;
    bench.forgetRequests();
    try bench.choose(prompt, "feature");
    _ = try status_test.expectCommand(&bench, .{ .merge = .{ .arguments = "--no-ff\x1f", .revision = "feature" } }, "");

    // A merge stopped on conflicts: `m a` asks, and its yes aborts.
    const merging = "# branch.oid 5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\x00# branch.head main\x00" ++
        "u UU N... 100644 100644 100644 100644 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b both.txt\x00";
    bench.forgetRequests();
    try bench.act(.vcs_git_refresh);
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    var refresh: [4]runner.Job = undefined;
    @memcpy(refresh[0..jobs.len], jobs);
    bench.forgetRequests();
    for (refresh[0..jobs.len]) |job| {
        const said_now: []const u8 = switch (Bench.purposeOf(job)) {
            .status => merging,
            .recent => status_test.recent_commits,
            .operation => "MERGE_HEAD\x1f72f25b65411d1f8a0a15a3f577334b3e0e3a4cc0\n",
            else => "",
        };
        _ = try bench.finish(job, 0, said_now, "");
    }
    bench.run();
    // The status asks for the operation once it sees the conflict.
    const later = bench.queued(&storage);
    if (later.len != 0) {
        const operation = try Bench.jobFor(later, .operation);
        bench.forgetRequests();
        _ = try bench.finish(operation, 0, "MERGE_HEAD\x1f72f25b65411d1f8a0a15a3f577334b3e0e3a4cc0\n", "");
        bench.run();
    }
    try testing.expectEqualStrings("Merging; resolve the conflicts, stage them, then c c to commit, or m a to abort", bench.value("vcs-git.operation").?);
    bench.forgetRequests();
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_merge_menu), &git_branch.merge_menu, "a");
    const asked = bench.dialog() orelse return error.NoDialog;
    try testing.expectEqualStrings("Abort the merge?", asked.completions.title);
    try status_test.expectNoCommand(&bench);
    bench.forgetRequests();
    try bench.choose(asked, "Abort");
    _ = try status_test.expectCommand(&bench, .merge_abort, "");
}

test "vcs git branch: b c while b b's listing is awaited opens the name prompt alone, the listing's answer dropped" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_branch_menu), &git_branch.branch_menu, "b");
    var storage: [8]runner.Job = undefined;
    const refs = try Bench.jobFor(bench.queued(&storage), .refs);
    const remotes = try Bench.jobFor(bench.queued(&storage), .remotes);
    // The menu's request is let go, as the menu takes it; the jobs' stay queued.
    transient.Requests.of(&bench.memory, &bench.tables, transient.requests_table_name).reset();
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_branch_menu), &git_branch.branch_menu, "c");
    try testing.expect(bench.dialog() != null);
    bench.forgetRequests();
    _ = try bench.finish(refs, 0, listed_refs, "");
    _ = try bench.finish(remotes, 0, "origin\n", "");
    bench.run();
    try testing.expect(bench.dialog() == null);
}

test "vcs git branch: b c names a branch at the commit under the cursor, and a name git refuses opens the prompt again" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try bench.placeCursor(try bench.spotOf(.recent, "72f25b6"));
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_branch_menu), &git_branch.branch_menu, "c");
    // No program runs to ask a name.
    try log_test.expectNoJob(&bench);
    const prompt = bench.dialog() orelse return error.NoPrompt;
    try testing.expectEqualStrings("Create and switch to (at 72f25b6)", prompt.completions.title);
    bench.forgetRequests();
    try log_test.submit(&bench, prompt, "two words");
    try log_test.expectNoJob(&bench);
    const again = bench.dialog() orelse return error.NoPrompt;
    try testing.expectEqualStrings("two words", again.completions.initial_query);
    bench.forgetRequests();
    try log_test.submit(&bench, again, "topic");
    _ = try status_test.expectCommand(&bench, .{ .create_branch = .{ .name = "topic", .start = "72f25b65411d1f8a0a15a3f577334b3e0e3a4cc0" } }, "");
}

/// Branches as `for-each-ref` lists them with their commits and worktrees: `main` current,
/// `feature` with no upstream, `topic` tracking `team/x/topic` (a remote whose name holds a `/`),
/// `side` checked out in another worktree, and the remotes' `origin/main`, `origin/feature`,
/// `origin/fresh` and `team/x/topic`.
const worktree_refs = "refs/heads/main\x1fmain\x1forigin/main\x1f*\x1f" ++ hash_a ++ "\x1f/work/repo\n" ++
    "refs/heads/feature\x1ffeature\x1f\x1f \x1f" ++ hash_a ++ "\x1f\n" ++
    "refs/heads/topic\x1ftopic\x1fteam/x/topic\x1f \x1f" ++ hash_a ++ "\x1f\n" ++
    "refs/heads/side\x1fside\x1f\x1f \x1f" ++ hash_a ++ "\x1f/work/side\n" ++
    "refs/remotes/origin/main\x1forigin/main\x1f\x1f \x1f" ++ hash_a ++ "\x1f\n" ++
    "refs/remotes/origin/feature\x1forigin/feature\x1f\x1f \x1f" ++ hash_a ++ "\x1f\n" ++
    "refs/remotes/origin/fresh\x1forigin/fresh\x1f\x1f \x1f" ++ hash_a ++ "\x1f\n" ++
    "refs/remotes/team/x/topic\x1fteam/x/topic\x1f\x1f \x1f" ++ hash_a ++ "\x1f\n" ++
    "refs/remotes/team/x/feat\x1fteam/x/feat\x1f\x1f \x1f" ++ hash_a ++ "\x1f\n";
const hash_a = "72f25b65411d1f8a0a15a3f577334b3e0e3a4cc0";

/// The listings a prompt waits on, answered: the branches with `worktree_refs`, the remotes
/// `origin` and `team/x`; the prompt they open.
fn answerListings(bench: *Bench) !Bench.Presented {
    var storage: [8]runner.Job = undefined;
    const queued = bench.queued(&storage);
    var jobs: [4]runner.Job = undefined;
    @memcpy(jobs[0..queued.len], queued);
    bench.forgetRequests();
    for (jobs[0..queued.len]) |job| {
        const said: []const u8 = switch (Bench.purposeOf(job)) {
            .refs => worktree_refs,
            .remotes => "origin\nteam/x\n",
            else => return error.NotAListing,
        };
        _ = try bench.finish(job, 0, said, "");
    }
    bench.run();
    return bench.dialog() orelse error.NoPrompt;
}

test "vcs git branch: b k refuses a name that is no local branch, and a branch checked out in a worktree, each in its own words" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_branch_menu), &git_branch.branch_menu, "k");
    const prompt = try answerListings(&bench);
    try log_test.submit(&bench, prompt, "nothing");
    try status_test.expectNoCommand(&bench);
    var said: [8][]const u8 = undefined;
    try testing.expectEqualStrings("There is no local branch nothing", bench.told(&said)[0]);
    const again = bench.dialog() orelse return error.NoPrompt;
    bench.forgetRequests();
    try bench.choose(again, "side");
    try status_test.expectNoCommand(&bench);
    try testing.expectEqualStrings("side is checked out in the worktree /work/side", bench.told(&said)[0]);
}

test "vcs git branch: b k is refused while a rebase is in progress, and a failed listing is told, not taken for no branch" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    var said: [8][]const u8 = undefined;
    // for-each-ref failed: the name cannot be checked, and that is what is told.
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_branch_menu), &git_branch.branch_menu, "k");
    var storage: [8]runner.Job = undefined;
    const refs = try Bench.jobFor(bench.queued(&storage), .refs);
    bench.forgetRequests();
    _ = try bench.finish(refs, 128, "", "fatal: something\n");
    bench.run();
    const prompt = bench.dialog() orelse return error.NoPrompt;
    bench.forgetRequests();
    try log_test.submit(&bench, prompt, "feature");
    try status_test.expectNoCommand(&bench);
    try testing.expectEqualStrings("git could not list the branches ($ shows why), so that name could not be checked: nothing was run", bench.told(&said)[0]);
    // A rebase in progress: the branch being rebased is not one for-each-ref tells.
    bench.forgetRequests();
    try bench.act(.vcs_git_refresh);
    const refresh = bench.queued(&storage);
    var jobs: [4]runner.Job = undefined;
    @memcpy(jobs[0..refresh.len], refresh);
    bench.forgetRequests();
    for (jobs[0..refresh.len]) |job| {
        const answer: []const u8 = switch (Bench.purposeOf(job)) {
            .status => "# branch.oid " ++ hash_a ++ "\x00# branch.head (detached)\x00",
            .recent => status_test.recent_commits,
            .operation => "rebase-merge/amend\x1f" ++ hash_a ++ "\nrebase-merge/onto\x1f5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\n",
            else => "",
        };
        _ = try bench.finish(job, 0, answer, "");
    }
    bench.run();
    // The detached head the status read asks for the operation.
    const operation = try Bench.jobFor(bench.queued(&storage), .operation);
    bench.forgetRequests();
    _ = try bench.finish(operation, 0, "rebase-merge/amend\x1f" ++ hash_a ++ "\nrebase-merge/onto\x1f5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\n", "");
    bench.run();
    bench.forgetRequests();
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_branch_menu), &git_branch.branch_menu, "k");
    const again = try answerListings(&bench);
    try bench.choose(again, "feature");
    try status_test.expectNoCommand(&bench);
    try testing.expectEqualStrings("A rebase is in progress: b k waits until it ends (r r, r a)", bench.told(&said)[0]);
}

test "vcs git branch: r i onto a revision typed finds its commit with one rev-parse, and one git cannot find opens the prompt again" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try bench.act(.vcs_git_first);
    try chooseIn(&bench, Atom.from(git_rebase.Msg.vcs_git_rebase_menu), &git_rebase.menu, "i");
    const prompt = try answerListings(&bench);
    bench.forgetRequests();
    try log_test.submit(&bench, prompt, "nope~3");
    const resolve = try log_test.onlyJob(&bench, .resolve);
    try status_test.expectArgv(resolve, .{ .resolve = "nope~3" });
    _ = try bench.finish(resolve, 128, "", "fatal: Needed a single revision\n");
    bench.run();
    var said: [8][]const u8 = undefined;
    try testing.expectEqualStrings("git cannot find the revision nope~3", bench.told(&said)[0]);
    const again = bench.dialog() orelse return error.NoPrompt;
    try testing.expectEqualStrings("nope~3", again.completions.initial_query);
    bench.forgetRequests();
    try log_test.submit(&bench, again, "HEAD~1");
    const found = try log_test.onlyJob(&bench, .resolve);
    bench.forgetRequests();
    _ = try bench.finish(found, 0, hash_a ++ "\n", "");
    bench.run();
    const listing = try log_test.onlyJob(&bench, .rebase_list);
    try status_test.expectArgv(listing, .{ .rebase_commits = .{ .base = hash_a, .head = "5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f" } });
}

test "vcs git branch: b b on a remote's branch switches to the local branch tracking it, refuses one that tracks another, and makes one" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    var said: [8][]const u8 = undefined;
    // `feature` is there and tracks nothing: told, nothing run.
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_branch_menu), &git_branch.branch_menu, "b");
    var prompt = try answerListings(&bench);
    try bench.choose(prompt, "origin/feature");
    try status_test.expectNoCommand(&bench);
    try testing.expectEqualStrings("A local branch feature already exists and does not track origin/feature", bench.told(&said)[0]);
    // `topic` tracks `team/x/topic`, the remote's name holding a `/`: switched to.
    bench.forgetRequests();
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_branch_menu), &git_branch.branch_menu, "b");
    prompt = try answerListings(&bench);
    try bench.choose(prompt, "team/x/topic");
    _ = try status_test.expectCommand(&bench, .{ .switch_to = "topic" }, "");
    // No local `fresh`: one made tracking it.
    bench.forgetRequests();
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_branch_menu), &git_branch.branch_menu, "b");
    prompt = try answerListings(&bench);
    try bench.choose(prompt, "origin/fresh");
    _ = try status_test.expectCommand(&bench, .{ .switch_track = .{ .name = "fresh", .remote_branch = "origin/fresh" } }, "");
    // A remote whose name holds a `/`: the local name is the one checked, `feat`, not the
    // `x/feat` git would derive.
    bench.forgetRequests();
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_branch_menu), &git_branch.branch_menu, "b");
    prompt = try answerListings(&bench);
    try bench.choose(prompt, "team/x/feat");
    _ = try status_test.expectCommand(&bench, .{ .switch_track = .{ .name = "feat", .remote_branch = "team/x/feat" } }, "");
}

test "vcs git remote: F e tells a remote's name from its branch's by the remotes listed" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try chooseIn(&bench, Atom.from(git_remote.Msg.vcs_git_pull_menu), &git_remote.pull_menu, "e");
    // Two programs, run together: the branches and the remotes.
    var storage: [8]runner.Job = undefined;
    try testing.expectEqual(@as(usize, 2), bench.queued(&storage).len);
    const prompt = try answerListings(&bench);
    try bench.choose(prompt, "team/x/topic");
    _ = try status_test.expectCommand(&bench, .{ .pull_from = .{ .remote = "team/x", .branch = "topic" } }, "");
}

test "vcs git branch: b m renames the branch chosen to the name read in a second prompt" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_branch_menu), &git_branch.branch_menu, "m");
    _ = try bench.finish(try log_test.onlyJob(&bench, .refs), 0, listed_refs, "");
    bench.run();
    const from = bench.dialog().?;
    bench.forgetRequests();
    try bench.choose(from, "feature");
    // The second prompt holds the name, and no program has run for it.
    try log_test.expectNoJob(&bench);
    const to = bench.dialog() orelse return error.NoPrompt;
    try testing.expectEqualStrings("Rename feature to", to.completions.title);
    try testing.expectEqualStrings("feature", to.completions.initial_query);
    bench.forgetRequests();
    try log_test.submit(&bench, to, "feature-2");
    _ = try status_test.expectCommand(&bench, .{ .rename_branch = .{ .name = "feature", .new_name = "feature-2" } }, "");
}

test "vcs git branch: ? opens each command's menu" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    const requests = transient.Requests.of(&bench.memory, &bench.tables, transient.requests_table_name);
    const opened = [_]struct { key: []const u8, menu: *const mesha.ui.transient.Menu }{
        .{ .key = "c", .menu = &git_commit.menu },
        .{ .key = "b", .menu = &git_branch.branch_menu },
        .{ .key = "l", .menu = &git_log.menu },
        .{ .key = "m", .menu = &git_branch.merge_menu },
        .{ .key = "r", .menu = &git_rebase.menu },
        .{ .key = "P", .menu = &git_remote.push_menu },
        .{ .key = "F", .menu = &git_remote.pull_menu },
        .{ .key = "f", .menu = &git_remote.fetch_menu },
    };
    for (opened) |each| {
        try bench.act(.vcs_git_menu);
        var sent: [4]transient.Request = undefined;
        const presenting = requests.peek(&sent)[0].present;
        try testing.expect(presenting.menu == &git_status.menu);
        var state = presenting.state;
        const outcome = mesha.ui.transient.press(&git_status.menu, &state, each.key);
        const id = switch (outcome) {
            .menu => |id| id,
            else => return error.NotAMenu,
        };
        requests.reset();
        const chosen: transient.Chosen = .{ .id = id, .cancelled = 0, .state = state };
        try sequencer.deliverMessage(&bench.tables, presenting.reply.inbox, presenting.reply.tag, presenting.reply.user_data.bytes, std.mem.asBytes(&chosen));
        bench.run();
        const shown = requests.peek(&sent);
        try testing.expectEqual(@as(usize, 1), shown.len);
        try testing.expect(shown[0].present.menu == each.menu);
        requests.reset();
    }
}

// ---- against a real git ------------------------------------------------------------------------

/// The prompt that opened since the requests were last forgotten, waiting frames for it.
fn awaitPrompt(bench: *Bench) !Bench.Presented {
    for (0..1000) |_| {
        status_test.stepReal(bench);
        if (bench.dialog()) |presented| return presented;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.Timeout;
}

/// Whether the panel told `prefix` at the start of a line since the requests were forgotten.
fn toldBeginning(bench: *Bench, prefix: []const u8) bool {
    var said: [32][]const u8 = undefined;
    for (bench.told(&said)) |line| {
        if (std.mem.startsWith(u8, line, prefix)) return true;
    }
    return false;
}

test "vcs git branch: a branch made, switched to, merged and deleted, and a push, a pull and a refused push, in real repositories" {
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
    try folder.dir.createDirPath(testing.io, "repo");
    const repository = try std.fs.path.join(allocator, &.{ top, "repo" });
    const remote = try std.fs.path.join(allocator, &.{ top, "remote.git" });
    const other = try std.fs.path.join(allocator, &.{ top, "other" });
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
    try repository_dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "one\n" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "add", "a.txt" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "commit", "-q", "-m", "First" });

    var bench: Bench = .{ .working_directory = repository };
    try bench.init();
    defer bench.deinit();
    var processes: mesha_runtime.process.Processes = undefined;
    try status_test.startProcesses(&bench, &processes, &environment);
    defer processes.deinit(&bench.tables);
    try bench.act(.vcs_git_status);
    try status_test.settleReal(&bench, null);

    // `b c topic`: made at HEAD and switched to; a commit on it.
    bench.forgetRequests();
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_branch_menu), &git_branch.branch_menu, "c");
    const name_prompt = bench.dialog() orelse return error.NoPrompt;
    bench.forgetRequests();
    try log_test.submit(&bench, name_prompt, "topic");
    try status_test.settleReal(&bench, null);
    try testing.expectEqualStrings("topic\n", try status_test.runGit(allocator, &environment, repository, &.{ "branch", "--show-current" }));
    try repository_dir.writeFile(testing.io, .{ .sub_path = "b.txt", .data = "bee\n" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "add", "b.txt" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "commit", "-q", "-m", "Add bees" });

    // `b b main`, then `m -n m topic`: a merge commit, git's own message kept.
    bench.forgetRequests();
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_branch_menu), &git_branch.branch_menu, "b");
    const switch_prompt = try awaitPrompt(&bench);
    bench.forgetRequests();
    try bench.choose(switch_prompt, "main");
    try status_test.settleReal(&bench, null);
    try testing.expectEqualStrings("main\n", try status_test.runGit(allocator, &environment, repository, &.{ "branch", "--show-current" }));
    bench.forgetRequests();
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_merge_menu), &git_branch.merge_menu, "-nm");
    const merge_prompt = try awaitPrompt(&bench);
    bench.forgetRequests();
    try bench.choose(merge_prompt, "topic");
    try status_test.settleReal(&bench, null);
    try testing.expectEqualStrings("Merge branch 'topic'\n", try status_test.runGit(allocator, &environment, repository, &.{ "log", "-1", "--format=%s" }));
    const parents = try status_test.runGit(allocator, &environment, repository, &.{ "log", "-1", "--format=%P" });
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, parents, " "));

    // `b k topic`: merged, so `-d` deletes it.
    bench.forgetRequests();
    try chooseIn(&bench, Atom.from(git_branch.Msg.vcs_git_branch_menu), &git_branch.branch_menu, "k");
    const delete_prompt = try awaitPrompt(&bench);
    bench.forgetRequests();
    try bench.choose(delete_prompt, "topic");
    try status_test.settleReal(&bench, null);
    try testing.expect(bench.dialog() == null);
    try testing.expectEqualStrings("", try status_test.runGit(allocator, &environment, repository, &.{ "branch", "--list", "topic" }));

    // A bare repository as the remote, no upstream: `P p` asks for the remote and pushes with -u.
    _ = try status_test.runGit(allocator, &environment, top, &.{ "init", "-q", "--bare", "-b", "main", "remote.git" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "remote", "add", "origin", remote });
    bench.forgetRequests();
    try chooseIn(&bench, Atom.from(git_remote.Msg.vcs_git_push_menu), &git_remote.push_menu, "p");
    const remote_prompt = try awaitPrompt(&bench);
    bench.forgetRequests();
    try bench.choose(remote_prompt, "origin");
    try status_test.settleReal(&bench, null);
    try testing.expectEqualStrings("origin/main\n", try status_test.runGit(allocator, &environment, repository, &.{ "rev-parse", "--abbrev-ref", "main@{upstream}" }));

    // A second clone commits and pushes; this one commits and pulls with --rebase.
    _ = try status_test.runGit(allocator, &environment, top, &.{ "clone", "-q", remote, "other" });
    var other_dir = try folder.dir.openDir(testing.io, "other", .{});
    defer other_dir.close(testing.io);
    try other_dir.writeFile(testing.io, .{ .sub_path = "c.txt", .data = "sea\n" });
    _ = try status_test.runGit(allocator, &environment, other, &.{ "add", "c.txt" });
    _ = try status_test.runGit(allocator, &environment, other, &.{ "commit", "-q", "-m", "From the other clone" });
    _ = try status_test.runGit(allocator, &environment, other, &.{ "push", "-q" });
    try repository_dir.writeFile(testing.io, .{ .sub_path = "d.txt", .data = "dee\n" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "add", "d.txt" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "commit", "-q", "-m", "Local" });
    bench.forgetRequests();
    try chooseIn(&bench, Atom.from(git_remote.Msg.vcs_git_pull_menu), &git_remote.pull_menu, "-rp");
    try status_test.settleReal(&bench, null);
    const order = try status_test.runGit(allocator, &environment, repository, &.{ "log", "-2", "--format=%s" });
    try testing.expectEqualStrings("Local\nFrom the other clone\n", order);
    try testing.expectEqualStrings("1\n", try status_test.runGit(allocator, &environment, repository, &.{ "rev-list", "--count", "HEAD", "^origin/main" }));

    // The other clone pushes again; this one's push is refused, told, and nothing waits.
    try other_dir.writeFile(testing.io, .{ .sub_path = "e.txt", .data = "ee\n" });
    _ = try status_test.runGit(allocator, &environment, other, &.{ "add", "e.txt" });
    _ = try status_test.runGit(allocator, &environment, other, &.{ "commit", "-q", "-m", "Again" });
    _ = try status_test.runGit(allocator, &environment, other, &.{ "push", "-q" });
    bench.forgetRequests();
    try chooseIn(&bench, Atom.from(git_remote.Msg.vcs_git_push_menu), &git_remote.push_menu, "p");
    try status_test.settleReal(&bench, null);
    try testing.expect(toldBeginning(&bench, "git push failed; $ shows why"));
    try testing.expect(!runner.busy(&bench.tables, sequencer.inboxOf(git_status.system())));
}
