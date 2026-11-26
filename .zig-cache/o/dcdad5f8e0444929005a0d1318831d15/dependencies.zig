pub const packages = struct {
    pub const editor = struct {
        pub const build_root = "/home/kiran/Downloads/dist/editor";
        pub const build_zig = @import("editor");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "mesha", "sdk/mesha" },
        };
    };
    pub const @"sdk/mesha" = struct {
        pub const build_root = "/home/kiran/Downloads/dist/sdk/mesha";
        pub const build_zig = @import("sdk/mesha");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const user = struct {
        pub const available = true;
        pub const build_root = "/home/kiran/Downloads/dist/user";
        pub const build_zig = @import("user");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "mesha", "sdk/mesha" },
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "editor", "editor" },
    .{ "user", "user" },
};
