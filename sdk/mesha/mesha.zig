//! The mesha SDK: everything a plugin imports from the engine, as one module.
//! `const mesha = @import("mesha");` is a plugin's only engine import, its UI library
//! (`ui`) included. The module is pure Zig: it imports nothing but `std`, and links no libc.
//!
//! ## What is here
//!
//! **Foundations** (`core/`):
//! - `Atom`: an id code refers to by name, the hash of the name. `Atom.Registry` keeps the
//!   names so tools can print them.
//! - `memory`: the host's `Memory`, its named scopes and arenas, and each frame's scratch.
//!   State that must survive a plugin reload lives in tables or in labeled host memory, never
//!   in the plugin's own globals.
//! - `Table`: the engine's state. Columnar rows with a schema, read through views;
//!   `Table.Registry` holds every table. `table_document` names the tables saved as files.
//! - `sequencer`: how a frame is organized. A kernel is a function over tables; a system
//!   declares the tables its kernels read and write and runs them in order; a sequencer runs
//!   systems. Systems talk through tables: `commands.<system>` rows are requests,
//!   `events.<system>` rows are what happened, `inbox.<system>` rows are messages.
//! - `journal`: the frame journal, which holds a run's writes apart from the tables until the
//!   run has succeeded, so a kernel that fails leaves no half-made state.
//! - `log`: structured logging and profile zones.
//! - `math`, `color`, `camera`: vectors and matrices, sRGB colors, a 2D camera.
//! - `zon`, `value`, `config`: ZON text read into dynamic values and written back.
//! - `gap_buffer`, `contract`, `boundary`, `table_journal`: a gap buffer, invariant checks,
//!   the layout check between host and plugin, and row-image history for undo.
//!
//! **System contracts** (`systems/`): for each host system, what a plugin and the host share:
//! its command and message types, its views, its table names, and the functions that append
//! a request. `input`, `time`, `actions`, `keybinds`, `panels`, `os`, `resources`, `gfx`,
//! `font`, `figure`, `text_editor`, `process`, `lsp`, `watch`, `profiler`, `tracker`, and
//! `plugin`, which holds what belongs to no single system. `roop` is the 2D renderer's
//! recording side: a `roop.Context` that draw calls are recorded into.
//!
//! **UI** (`ui/`): `ui`, the immediate-mode UI library a plugin draws its panels with, which
//! lays out a `ui.Tree` of rects and text, paints it through a `roop.Context` and writes the hit
//! regions input routes presses through; `ui.panel_header`, the usual header of a panel;
//! `ui.chart`, line, bar and scatter charts of a table's columns; `ui.transient`, keyed
//! menus of commands, switches and options as Emacs's transient shows them; `ui.marks`, small
//! marks drawn as paths; `ui.filter_field`, a one-line filter over a caller's text cell;
//! `ui.vector_field`, a vector's components side by side; `ui.grid`, a grid of a table's
//! rows over state its caller keeps; `ui.outline`, lines in sections that nest and fold; and
//! `ui.diff`, a unified diff's hunks drawn as an outline.
//!
//! The systems themselves, the code that owns the window, the device, files and threads, are
//! the host's: the `runtime/` package, module `mesha_runtime`, which a plugin does not
//! import. Systems draw nothing; a plugin draws.
//!
//! ## How a plugin uses it
//!
//! A plugin is a shared library the host loads, and reloads when it is rebuilt. It exports
//! C-ABI entry points that the host calls with its `Memory`, `Atom.Registry` and
//! `Table.Registry`:
//!
//! - `plugin_bind_log` points the plugin's logger at the host's (`log.bindSharedState`).
//! - `plugin_abi` returns `plugin.abi_fingerprint`; the loader refuses a plugin whose layout
//!   of the shared types differs from the host's.
//! - `plugin_tag` returns the plugin's name as an atom.
//! - `plugin_init` interns the plugin's names, registers its schemas and makes its tables
//!   unless they are there already, as after a reload.
//! - `plugin_update` runs the plugin's sequencer for the frame, as a child of the host's run,
//!   inside the journal layer it is given.
//! - `plugin_render_panel` draws a panel's whole frame, its header if it wears one included
//!   (`ui.panel_header` is the usual header): it reads tables and records into the
//!   `roop.Context` it is given, usually through `ui`. It is not a kernel and writes no table.
//! - `plugin_deinit`, optional, drops what the plugin made when it is unloaded.
//!
//! Between those calls the plugin's code is kernels. A kernel reads and writes rows of the
//! tables its system declared, through views; asks a host system for work by appending a row
//! to that system's command table (a figure to load, a font, an input subscription); and
//! hears the answer as a message in its system's inbox on a later frame. Names are interned
//! at init, never in a kernel.
//!
//! The host and each plugin are separate images with their own copy of this module's code,
//! sharing memory. What that requires of shared types is in `boundary`.

/// An id that code refers to by name: the hash of the name. `Atom.Registry` keeps the names.
pub const Atom = @import("core/atom.zig").Atom;
/// A table, the engine's state: typed columns of rows with a schema. `Table.Registry` holds
/// every table; the file's declarations are everything about tables.
pub const Table = @import("core/table.zig");
/// The host's memory: the one value every scope, arena and page is accounted to.
pub const Memory = @import("core/memory.zig").Memory;
/// Memory for the host and its plugins: scopes, arenas, labeled records and frame scratch.
pub const memory = @import("core/memory.zig");
/// The frame journal: a run's writes, held apart from the tables until the run succeeds.
pub const journal = @import("core/journal.zig");
/// Row-image history over tables: transactions that can be undone and redone.
pub const table_journal = @import("core/table_journal.zig");
/// Table documents by name and by file: valid ids, where a document's file lies, and a
/// singleton's file as ZON text.
pub const table_document = @import("core/table_document.zig");
/// Sequencers, systems and kernels, and the command, event and inbox tables systems talk
/// through.
pub const sequencer = @import("core/sequencer.zig");
/// A gap buffer: a sequence in one allocation with a hole where the next edit is expected.
pub const gap_buffer = @import("core/gap_buffer.zig");
/// The dynamic value a ZON document is read into.
pub const value = @import("core/value.zig");
/// ZON text parsed into values and written back, and edits to a file's root fields.
pub const zon = @import("core/zon.zig");
/// A ZON document loaded whole, from text or from a file.
pub const config = @import("core/config.zig");
/// Vectors, 2D affine and 4x4 matrices and quaternions of `f32`.
pub const math = @import("core/math.zig");
/// sRGB colors with straight alpha, and conversion to and from linear light.
pub const color = @import("core/color.zig");
/// A 2D camera: the mapping between world coordinates and viewport pixels.
pub const camera = @import("core/camera.zig");
/// Invariant checks that panic in every build mode.
pub const contract = @import("core/contract.zig");
/// Structured logging and profile zones.
pub const log = @import("core/log.zig");
/// The host and plugin image boundary as types see it: layout fingerprints and the stored
/// calls that must not cross.
pub const boundary = @import("core/boundary.zig");

/// The actions contract: what a person asks for by name, by key chord or from the palette.
pub const actions = @import("systems/actions.zig");
/// The figure contract: posed figures, the instance tables a game registers to draw them,
/// and the typed commands that load and edit them.
pub const figure = @import("systems/figure.zig");
/// The font contract: baked glyph layouts and the limits of what a font bake takes.
pub const font = @import("systems/font.zig");
/// The gfx contract: requests to the graphics device, which the render thread owns, and
/// their replies.
pub const gfx = @import("systems/gfx.zig");
/// The input contract: keys, pointer and text events, and the subscriptions that ask for
/// them.
pub const input = @import("systems/input.zig");
/// The keybinds contract: chords as text, how code declares a mode's keys and its actions, and
/// the editor settings that choose among the keys.
pub const keybinds = @import("systems/keybinds.zig");
/// The window's contract: cursors, requests made of the window, and its size.
pub const os = @import("systems/os.zig");
/// The panels contract: the window's tree of panels, their focus and their state tables.
pub const panels = @import("systems/panels.zig");
/// What the host and a plugin share that belongs to no single system: the `plugins` table,
/// plugin load requests, panel requests, the layout fingerprint.
pub const plugin = @import("systems/plugin.zig");
/// The process contract: other programs, run without a frame waiting on them.
pub const process = @import("systems/process.zig");
/// The language server contract: what a file's language server says about it.
pub const lsp = @import("systems/lsp.zig");
/// The watch contract: each plugin's build, run again as its source changes.
pub const watch = @import("systems/watch.zig");
/// The profiler contract: requests for snapshots of the log's zone history.
pub const profiler = @import("systems/profiler.zig");
/// The resources contract: requests to load table documents, textures and fonts, and the
/// tables that say what is loaded.
pub const resources = @import("systems/resources.zig");
/// The 2D renderer's recording: a `Context` that paths, paints, text and layers are
/// recorded into, for the host's backend to draw.
pub const roop = @import("systems/roop.zig");
/// The text editor contract: buffers of UTF-8 text, driven by commands and read from tables.
pub const text_editor = @import("systems/text_editor.zig");
/// The time contract: the clock, frame and fixed-tick subscriptions, and animations of
/// table cells.
pub const time = @import("systems/time.zig");
/// The world contract: which panel the world is drawn under, where, and through what camera.
pub const world = @import("systems/world.zig");
/// The tracker contract: charts of table cells over time.
pub const tracker = @import("systems/tracker.zig");

/// The immediate-mode UI library a plugin draws its panels with: a `ui.Tree` of rects and text
/// laid out, painted through a `roop.Context` and given hit regions, with `ui.panel_header`,
/// `ui.chart`, `ui.transient`, `ui.marks`, `ui.filter_field`, `ui.vector_field`, `ui.grid`,
/// `ui.outline` and `ui.diff`.
pub const ui = @import("ui/ui.zig");

test {
    _ = @import("core/atom.zig");
    _ = @import("core/boundary.zig");
    _ = @import("core/camera.zig");
    _ = @import("core/color.zig");
    _ = @import("core/config.zig");
    _ = @import("core/contract.zig");
    _ = @import("core/journal.zig");
    _ = @import("core/log/buffer.zig");
    _ = @import("core/log/decoder.zig");
    _ = @import("core/log/writer.zig");
    _ = @import("core/log.zig");
    _ = @import("core/math.zig");
    _ = @import("core/memory.zig");
    _ = @import("core/sequencer.zig");
    _ = @import("core/table_document.zig");
    _ = @import("core/table_journal.zig");
    _ = @import("core/table.zig");
    _ = @import("core/value.zig");
    _ = @import("core/zon.zig");
    _ = @import("systems/actions.zig");
    _ = @import("systems/keybinds.zig");
    _ = @import("systems/process.zig");
    _ = @import("systems/lsp.zig");
    _ = @import("systems/watch.zig");
    _ = @import("systems/world.zig");
    _ = @import("systems/figure.zig");
    _ = @import("systems/font.zig");
    _ = @import("systems/gfx/types.zig");
    _ = @import("systems/gfx.zig");
    _ = @import("systems/input.zig");
    _ = @import("systems/os.zig");
    _ = @import("systems/panels.zig");
    _ = @import("systems/plugin.zig");
    _ = @import("systems/profiler.zig");
    _ = @import("systems/resources.zig");
    _ = @import("systems/roop/context.zig");
    _ = @import("systems/roop/draw_list.zig");
    _ = @import("systems/roop/geometry_test.zig");
    _ = @import("systems/roop/geometry.zig");
    _ = @import("systems/roop/layer_stream.zig");
    _ = @import("systems/roop/layer_admission.zig");
    _ = @import("systems/roop/path.zig");
    _ = @import("systems/roop/renderer.zig");
    _ = @import("systems/roop/transform.zig");
    _ = @import("systems/roop.zig");
    _ = @import("core/gap_buffer.zig");
    _ = @import("systems/text_editor/buffer.zig");
    _ = @import("systems/text_editor/encoding.zig");
    _ = @import("systems/text_editor.zig");
    _ = @import("systems/time.zig");
    _ = @import("systems/tracker.zig");
    _ = @import("ui/chart.zig");
    _ = @import("ui/diff.zig");
    _ = @import("ui/filter_field.zig");
    _ = @import("ui/grid.zig");
    _ = @import("ui/grid/values.zig");
    _ = @import("ui/marks.zig");
    _ = @import("ui/outline.zig");
    _ = @import("ui/panel_header.zig");
    _ = @import("ui/transient.zig");
    _ = @import("ui/ui.zig");
    _ = @import("ui/vector_field.zig");
}
