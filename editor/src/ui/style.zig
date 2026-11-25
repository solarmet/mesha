const mesha = @import("mesha");
const ui = mesha.ui;
const Table = mesha.Table;
const resources = mesha.resources;
const text_panel = @import("../text_panel.zig");
const document_view = @import("../document/view.zig");

/// Editor UI text, 17 pixels tall.
pub const ui_font = resources.kFont24Name;

pub const col = struct {
    pub const canvas = ui.rgb(30, 30, 30);
    pub const sidebar = ui.rgb(44, 44, 44);
    pub const card = ui.rgb(56, 56, 56);
    pub const card_hover = ui.rgb(68, 68, 68);
    pub const inset = ui.rgb(30, 30, 30);
    pub const text = ui.rgb(240, 240, 240);
    pub const text_dim = ui.rgb(190, 190, 190);
    pub const accent_bright = ui.rgb(120, 195, 255);
    pub const accent_deep = ui.rgb(13, 110, 190);
    pub const accent_wash = ui.rgba(13, 153, 255, 40);
    pub const accent_border = ui.rgba(13, 153, 255, 200);
    pub const border = ui.rgb(68, 68, 68);
    pub const divider = ui.rgb(62, 62, 62);
    pub const danger = ui.rgb(255, 84, 112);
    pub const danger_wash = ui.rgba(255, 84, 112, 44);
    /// Behind danger-red text that is selected: dark enough that the red reads on it.
    pub const danger_selection = ui.rgb(84, 28, 40);
    pub const warning = ui.rgb(240, 195, 110);
    /// Behind text a search found, other than the match the search is at.
    pub const match_wash = ui.rgba(240, 195, 110, 56);
    /// Something running as it should: a status light, never a fill.
    pub const success = ui.rgb(110, 200, 130);
    /// Behind text shown where it would be put, as a replacement beside what it replaces.
    pub const success_wash = ui.rgba(110, 200, 130, 44);
    pub const overlay = ui.rgba(0, 0, 0, 70);
    /// Text on a control that cannot be used now, dimmer than any label.
    pub const text_disabled = ui.rgb(125, 125, 125);
    /// A button is a flat fill lighter than the panel, with no outline.
    pub const button = ui.rgb(66, 66, 66);
    pub const button_hover = ui.rgb(84, 84, 84);
    pub const button_disabled = ui.rgb(52, 52, 52);
    /// Under the pointer, an unselected tab only lightens a little: it has no fill of its own.
    pub const tab_hover = ui.rgba(255, 255, 255, 14);
    /// A text field reads as sunken: darker than the panel, so it is never taken for a button.
    pub const field = ui.rgb(26, 26, 26);
    pub const field_border = ui.rgb(82, 82, 82);
    pub const field_active = ui.rgb(12, 34, 56);
    /// A field that would open or scrub under the pointer: a little lighter, still sunken.
    pub const field_hover = ui.rgb(40, 40, 40);
    /// The line between regions of the window: brighter than `divider`, which sits within one.
    pub const region_border = ui.rgb(82, 82, 82);
};

pub const FieldState = enum { idle, active };

/// The frame every editable value sits in. Text inside stays left-aligned, unlike a button's.
pub fn fieldFrame(field_state: FieldState, size: ui.Size) ui.RectParams {
    return .{
        .axis = .horizontal,
        .cross_align = .center,
        .size = size,
        .padding = 6,
        .gap = 6,
        .bg = if (field_state == .active) col.field_active else col.field,
        .border = if (field_state == .active) col.accent_bright else col.field_border,
        // A ring outside the line: an active field must stand out at a glance.
        .border_size = if (field_state == .active) 1 else 0,
        .corner_radius = metric.field_radius,
        .clip_content = true,
    };
}

/// The editor's theme for `ui.filter_field`: its field colours, ui font and field radius.
pub fn filterFieldStyle() ui.filter_field.Style {
    return .{
        .font = ui_font,
        .text = col.text,
        .dim = col.text_disabled,
        .accent = col.accent_bright,
        .background = col.field,
        .background_active = col.field_active,
        .border = col.field_border,
        .clear_hover = col.button_hover,
        .clear_mark = col.text_dim,
        .corner_radius = metric.field_radius,
    };
}

/// The editor's theme for `ui.vector_field`: its field colours, ui font and field radius, as
/// `fieldFrame` draws every editable value.
pub fn vectorFieldStyle() ui.vector_field.Style {
    return .{
        .font = ui_font,
        .text = col.text,
        .axis_letter = col.text_disabled,
        .background = col.field,
        .background_hover = col.field_hover,
        .background_active = col.field_active,
        .border = col.field_border,
        .border_active = col.accent_bright,
        .corner_radius = metric.field_radius,
    };
}

// Canvas controls sit on artwork or white paper, rather than the dark UI panels.
// Keep essential marks opaque; translucent colors are only interior washes.
pub const canvas_controls = struct {
    /// Screen pixels. A thinner line varies visibly in weight as it crosses the pixel grid.
    pub const line_width: f32 = 1.5;
    pub const ink = ui.rgb(28, 40, 64);
    pub const paper = ui.rgb(255, 255, 255);
    pub const selection = ui.rgb(13, 120, 215);
    pub const edit = ui.rgb(88, 48, 160);
    pub const target = ui.rgb(0, 105, 105);
    pub const caution = ui.rgb(160, 80, 0);
    pub const joint = ui.rgb(176, 42, 55);
    pub const muted = ui.rgb(100, 112, 132);
    pub const frame = ui.rgb(200, 204, 212);
    pub const selection_wash = ui.rgba(13, 153, 255, 30);
    pub const bone_wash = ui.rgba(28, 40, 64, 50);
    pub const selected_bone_wash = ui.rgba(160, 80, 0, 65);
};

pub const TableAccent = struct {
    bright: ui.Color,
    deep: ui.Color,
    wash: ui.Color,
    border: ui.Color,
};

pub fn tableAccent(lifetime: Table.Lifetime) TableAccent {
    return switch (lifetime) {
        .persistent => .{
            .bright = col.accent_bright,
            .deep = col.accent_deep,
            .wash = col.accent_wash,
            .border = col.accent_border,
        },
        .durable => .{
            .bright = ui.rgb(255, 198, 92),
            .deep = ui.rgb(94, 61, 22),
            .wash = ui.rgba(255, 184, 64, 36),
            .border = ui.rgba(255, 184, 64, 160),
        },
        .transient => .{
            .bright = col.text_dim,
            .deep = col.sidebar,
            .wash = col.card,
            .border = col.border,
        },
    };
}

/// The editor's theme for `ui.grid`, a table window's grid over a table of `lifetime`: the
/// table's accent for its column names, its selection and its active cell, the editor's
/// colours, ui font and field and vector styles for the rest.
pub fn gridStyle(lifetime: Table.Lifetime) ui.grid.Style {
    const accent = tableAccent(lifetime);
    return .{
        .font = ui_font,
        .text = col.text,
        .dim_text = col.text_dim,
        .header_bg = col.sidebar,
        .header_text = accent.bright,
        .row_bg_a = col.card,
        .row_bg_b = ui.rgb(50, 50, 50),
        .selected_bg = accent.deep,
        .active_bg = accent.wash,
        .active_border = accent.border,
        .invalid_bg = col.danger_wash,
        .invalid_border = col.danger,
        .edit_bg = col.field_active,
        .grid_border = col.border,
        .button_hover = col.button_hover,
        .header_hover = col.tab_hover,
        .filter = filterFieldStyle(),
        .vector = vectorFieldStyle(),
    };
}

/// The monospace font a `.code` line of the editor's outlines is drawn in: the text panels' 16
/// pixels tall, their size nearest below the ui font's 17.
pub const outline_code_font = codeFontOf(16);

/// The text panels' font that is `pixels` tall.
fn codeFontOf(comptime pixels: comptime_int) mesha.Atom {
    for (text_panel.text_sizes) |size| {
        if (size.pixel_height == pixels) return size.font;
    }
    @compileError("the text panels have no font of that height");
}

/// The editor's theme for `ui.outline`: the ui font, the text panels' code font, the accent's
/// deep fill on the cursor's line, a card's hover, and dimmed text for details and chevrons.
pub fn outlineStyle() ui.outline.Style {
    return .{
        .text_font = ui_font,
        .code_font = outline_code_font,
        .highlight = col.accent_deep,
        .hover = col.card_hover,
        .dimmed = col.text_dim,
    };
}

/// The editor's theme for a document's page (`document/view.zig`): the outline's lines and the
/// grid's tables, as `outlineStyle` and `gridStyle` give them, headings in the bright accent,
/// terms and tables not published dimmed, and a table its publisher could not read in danger red,
/// its selected row on a dark red fill.
pub fn documentStyle() document_view.Style {
    return .{
        .outline = outlineStyle(),
        .grid = gridStyle(.persistent),
        .heading = col.accent_bright,
        .text = col.text,
        .dimmed = col.text_dim,
        .error_text = col.danger,
        .error_selection = col.danger_selection,
    };
}

/// The editor's theme for `ui.diff`: a file's label in text colour and its note dimmed, a hunk's
/// `@@` line in the bright accent, added lines in success green, removed in danger red, context
/// in text colour and the no-newline mark dimmed.
pub fn diffStyle() ui.diff.Style {
    return .{
        .file = col.text,
        .note = col.text_dim,
        .hunk_header = col.accent_bright,
        .added = col.success,
        .removed = col.danger,
        .context = col.text,
        .no_newline = col.text_dim,
    };
}

pub const playhead = ui.rgb(245, 200, 75);

pub const metric = struct {
    pub const outer: f32 = 8;
    pub const inner: f32 = 8;
    pub const control: f32 = 32;
    pub const radius: f32 = 8;
    pub const glow: f32 = 1;
    pub const button_radius: f32 = 4;
    pub const field_radius: f32 = 2;
    pub const button_height: f32 = 28;
    pub const field_height: f32 = 26;
};
