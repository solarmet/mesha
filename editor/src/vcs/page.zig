//! A page of a version-control panel: a document (`editor/src/document/`) one of the panel's
//! views shows, which its system's kernels lay out and move through and its draw draws. vcs-git
//! owns three (its status, its log and its rebase list) and vcs-p4 two (its changelists and its
//! history); each is named by a `Page`, and the helpers here take one, a kernel's over its pass
//! and the draw's over the tables it reads, so every panel lays out, settles and draws its pages
//! the one way.

const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const plugin = mesha.plugin;
const resources = mesha.resources;
const roop = mesha.roop;
const sequencer = mesha.sequencer;
const ui = mesha.ui;
const text_editor = plugin.text_editor_api;
const style = @import("../ui/style.zig");
const document = @import("../document/document.zig");
const document_view = @import("../document/view.zig");
const org = @import("../document/org.zig");

/// A page of a panel's: a document one of its views shows. Several pages share a system, each
/// with state of its own, so a page names everything that is its own. What a new page supplies:
/// - its text, an `.org` asset compiled in, read by `parsePage` as the editor is compiled;
/// - the singleton that holds its cursor, scroll and view (`document.addStateFields` in that
///   table's schema, `document.initial_state` among its defaults), and a `u8` field
///   `cursor_moved_under` (`MovedUnder`), 0 at the start: 1 from an answer that rewrote the
///   page's table and took the row under its cursor away, to the end of that run, which the
///   page's own keys on a row read (`changedUnderCursor`);
/// - its own table of folds (`document.addFoldFields`): `document.pruneFolds` frees the folds
///   of every heading its text lacks, so two pages never share one;
/// - the name its messages carry and its tags, each a `Msg` of the system's own;
/// - the name of its reader of the panels' events, which follows the panel's size for it.
/// Its names go among the system's `names` (`Page.names`), its tables among its access
/// (`Page.declareAccess`), its size is followed as the panel is resized (`followSize`) and its
/// cursor settled at the end of the run that took the messages (`settle`), its messages are
/// routed to it while its view is shown (`document.take`), and `record` draws it.
pub const Page = struct {
    /// The text read, `parsePage`'s.
    document: document.Document,
    /// The name its messages carry (`document.Click.document`), which its grids' instances are
    /// made from: told apart from another page's.
    name: []const u8,
    /// The singleton holding its `document.StateRow` fields.
    state_table: Atom,
    /// Its table of folds (`document.FoldRow`), its own.
    folds_table: Atom,
    /// The tags of its clicks, fold marks and wheel, the system's own.
    tags: document.Tags,
    /// The name it reads the panels' events under, for its size.
    resize_reader_name: []const u8,
    /// What is told when a key acts on its cursor's row in the run of an answer that took that
    /// row away (`changedUnderCursor`): `The status changed under the cursor`.
    moved_under_sentence: []const u8,

    /// The page as `document.take` and `document_view.record` name it.
    pub fn input(page: Page) document.Input {
        return .{ .document = Atom.from(page.name), .tags = page.tags };
    }

    /// Its reader of the panels' events.
    pub fn resizeReader(page: Page) Atom {
        return Atom.from(page.resize_reader_name);
    }

    /// The names it adds to the system's `names`.
    pub fn names(comptime page: Page) [2][]const u8 {
        return .{ page.name, page.resize_reader_name };
    }

    /// Declares what it reads and writes: its state and its folds written, and what its text
    /// reads (`document.declareAccess`).
    pub fn declareAccess(page: Page, result: *sequencer.Access, tables: *Table.Registry) void {
        result.writeAll(&.{ page.state_table, page.folds_table });
        document.declareAccess(result, tables, page.document);
    }
};

/// `text`, the org asset `file_name`, read (`document.parse`'s form) as the editor is compiled:
/// its text never changes while the editor runs, so no run or draw parses it again. A text that
/// does not parse whole is a compile error.
pub fn parsePage(comptime text: []const u8, comptime file_name: []const u8) document.Document {
    @setEvalBranchQuota(10_000_000);
    const sized = org.parse(text, &.{}, &.{});
    var blocks: [sized.blocks_seen]org.Block = undefined;
    var spans: [sized.spans_seen]org.Span = undefined;
    const parsed = org.parse(text, &blocks, &spans);
    if (!parsed.complete()) @compileError(file_name ++ " did not parse whole");
    const kept_blocks = blocks;
    const kept_spans = spans;
    return .{ .blocks = &kept_blocks, .spans = &kept_spans };
}

/// The field every page's state singleton has beside its `document.StateRow` (`Page`): 1 from
/// an answer that took the row under the page's cursor away to the end of that run.
pub const MovedUnder = struct { cursor_moved_under: *u8 };

/// Which of a page's folds `tab` and `S-tab` turn.
pub const Fold = enum { at_cursor, every };

/// The page's measures, for its lines in the outline's fonts, from `font_metrics`.
pub fn metrics(font_metrics: ?*Table) document.Metrics {
    const fonts = style.outlineStyle();
    return document.metricsOf(font_metrics, fonts.text_font, fonts.code_font);
}

const font_metrics_table = Atom.from(resources.font_metrics_table_name);

// ---- in a kernel ---------------------------------------------------------------------------------

/// The frame's scratch, which a run's layouts are made in: good for the frame.
fn scratchOf(pass: *sequencer.Pass) !std.mem.Allocator {
    const frame_scratch = try pass.frame.memory.frameScratchAllocator();
    return frame_scratch.allocator;
}

/// `page` as the run sees the tables: its text laid out over what is published, its folds
/// applied, in the frame's memory. The run's system declares `page` (`Page.declareAccess`).
pub fn laidOut(pass: *sequencer.Pass, page: Page) !document.Layout {
    const allocator = try scratchOf(pass);
    const published = try document.publishedIn(allocator, pass, page.document);
    const folds = try foldRows(pass, page);
    const folded = try document.foldedKeys(allocator, folds.read());
    const font_metrics: ?*Table = if (pass.declares(font_metrics_table)) pass.table(font_metrics_table) catch null else null;
    return document.layout(allocator, page.document, published, folded, metrics(font_metrics));
}

/// `page`'s cursor, scroll and view, in its state's row.
pub fn stateOf(pass: *sequencer.Pass, page: Page) !document.StateRow {
    return pass.writeSingleton(page.state_table, document.StateRow);
}

/// `page`'s folds.
pub fn foldRows(pass: *sequencer.Pass, page: Page) !sequencer.Rows(document.FoldRow) {
    return pass.writeRows(page.folds_table, document.FoldRow);
}

/// `page`'s cursor settled against the page as it is now, the view following it as `follow`
/// says, and the folds of headings its text no longer has let go.
pub fn settle(pass: *sequencer.Pass, page: Page, follow: document.Follow) !void {
    const laid_out = try laidOut(pass, page);
    document.settleView(laid_out, try stateOf(pass, page), follow);
    try document.pruneFolds(laid_out, try foldRows(pass, page));
}

/// What `page`'s cursor is on.
pub fn atCursor(pass: *sequencer.Pass, page: Page) !document.At {
    const laid_out = try laidOut(pass, page);
    const state = try stateOf(pass, page);
    return document.at(laid_out, document.cursorOf(state));
}

/// `page`'s cursor put on the row `handle` of its table block `block`, whose table its
/// publisher wrote again, the scroll as it was: the cursor kept on what it was on.
pub fn putCursorOnRow(pass: *sequencer.Pass, page: Page, block: u64, handle: Table.RowHandle) !void {
    const laid_out = try laidOut(pass, page);
    const state = try stateOf(pass, page);
    var placed = document.cursorOnRow(laid_out, block, handle);
    placed.scroll = document.cursorOf(state).scroll;
    document.setCursor(state, placed);
}

/// `tab` folds or opens the heading the cursor is on or under, `S-tab` every heading; the
/// page is laid out again and the cursor settled in it, onto the heading that hides it.
pub fn fold(pass: *sequencer.Pass, page: Page, which: Fold) !void {
    const before = try laidOut(pass, page);
    const state = try stateOf(pass, page);
    const folds = try foldRows(pass, page);
    switch (which) {
        .at_cursor => _ = try document.toggle(before, document.cursorOf(state), folds),
        .every => try document.toggleAll(before, folds),
    }
    const after = try laidOut(pass, page);
    document.settleView(after, state, .cursor);
}

/// `page`'s `MovedUnder` flag, in its state's row.
pub fn movedUnder(pass: *sequencer.Pass, page: Page) !*u8 {
    const flags = try pass.writeSingleton(page.state_table, MovedUnder);
    return flags.cursor_moved_under;
}

/// Whether an answer earlier in this run took the row under `page`'s cursor away, another thing
/// in its place that nobody has seen there: that is told, in the page's words, and the key acts
/// on nothing. Each page keeps its own flag, so an answer that rewrote one page refuses no key
/// of another's. The run's system declares the text editor's requests written.
pub fn changedUnderCursor(pass: *sequencer.Pass, page: Page) !bool {
    const moved_under = try movedUnder(pass, page);
    if (moved_under.* == 0) return false;
    text_editor.message(pass.frame.memory, pass.frame.tables, page.moved_under_sentence);
    return true;
}

/// Keeps the size of `panel`'s content `page` is laid out in as the panels system told it,
/// settling its cursor in view when it changed.
pub fn followSize(pass: *sequencer.Pass, page: Page, panel: Atom) !void {
    const page_state = try stateOf(pass, page);
    const resized = try document.followResizes(pass, page.resizeReader(), panel, page_state);
    if (!resized) return;
    try settle(pass, page, .cursor);
}

// ---- in a draw -----------------------------------------------------------------------------------

/// `page` as the draw reads the tables, its atom cells named by `atoms`, in `allocator`.
pub fn laidOutIn(allocator: std.mem.Allocator, tables: *Table.Registry, atoms: *const Atom.Registry, page: Page) !document.Layout {
    const published = try document.publishedIn(allocator, document.DrawTables{ .tables = tables, .atoms = atoms }, page.document);
    const folds = tables.findByName(page.folds_table) orelse return error.MissingTable;
    const folded = try document.foldedKeys(allocator, folds.readQuery(document.FoldRow));
    const page_metrics = metrics(tables.findByName(font_metrics_table));
    return document.layout(allocator, page.document, published, folded, page_metrics);
}

/// `page`'s cursor as its kernels left it, settled against `laid_out`, as the draw reads it; at
/// the page's top without its state's row.
pub fn cursorIn(tables: *Table.Registry, page: Page, laid_out: document.Layout) document.Cursor {
    const state_table = tables.findByName(page.state_table) orelse return .{};
    const row = state_table.getRow(.{ .row = 0, .generation = state_table.rowGeneration(0) }, document.StateRow) orelse return .{};
    return document.settle(laid_out, document.cursorOf(row));
}

/// `page`, laid out as `laid_out`, recorded into `tree` over the whole of `viewport`, its
/// cursor as its kernels left it, its tables' columns fit to what they hold; its messages go to
/// `inbox`, its system's. Writes no table.
pub fn record(tree: *ui.Tree, tables: *Table.Registry, page: Page, laid_out: document.Layout, inbox: Atom, scratch: memory_mod.Scratch, viewport: plugin.Viewport, ctx: *roop.Context) void {
    const cursor = cursorIn(tables, page, laid_out);
    const page_input = page.input();
    document_view.record(tree, laid_out, cursor, .{
        .inbox = inbox,
        .document = page_input.document,
        .tags = page_input.tags,
        .view_width = viewport.width,
        .view_height = viewport.height,
        .scratch = scratch,
        .style = style.documentStyle(),
        .measure = ui.grid.TextMeasure.ofContext(ctx),
    });
}
