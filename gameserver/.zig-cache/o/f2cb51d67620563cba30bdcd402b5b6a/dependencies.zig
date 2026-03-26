pub const packages = struct {
    pub const @"../protocol" = struct {
        pub const build_root = "d:\\Projects\\Push\\CastoricePS\\gameserver\\../protocol";
        pub const build_zig = @import("../protocol");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "protobuf", "122052e8e9e4233621ebeba2215df92dbb78387be6193bdc24da3f44532ddeeb25ab" },
        };
    };
    pub const @"122052e8e9e4233621ebeba2215df92dbb78387be6193bdc24da3f44532ddeeb25ab" = struct {
        pub const build_root = "C:\\Users\\Administrator\\AppData\\Local\\zig\\p\\protobuf-2.0.0-0e82asubGwBS6OnkIzYh6-uiIV35Lbt4OHvmGTvcJNo_";
        pub const build_zig = @import("122052e8e9e4233621ebeba2215df92dbb78387be6193bdc24da3f44532ddeeb25ab");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "protocol", "../protocol" },
};
