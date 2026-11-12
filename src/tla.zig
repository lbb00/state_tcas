//! TLA+ specification interoperability: declaration generation, specification lock (anti-drift),
//! and JSON/ITF trace replay with state divergence and action enabling checks.
//!
//! Pure Zig `std` only — zero external tools, no Java/TLC runtime requirements.
//!
//! Designed for two core workflows:
//! 1. Single Source of Truth: generate and lock TLA+ action/state vocabulary and bounded constants
//!    from Zig types, preventing semantic and configuration drift (`st.tla.lock`).
//! 2. Counterexample Replay: parse action sequences or ITF (Informal Trace Format) traces and replay
//!    them against Zig harness contexts (`st.tla.replayJsonTrace`), checking enabling guards
//!    (`error.ActionNotEnabled`) and state projection alignment (`error.TraceDiverged`).

const std = @import("std");
const picture = @import("picture.zig");

fn Unwrap(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
}

pub const TlaError = error{
    TlaDrift,
    ModuleNameMismatch,
    InvalidFilePath,
    InvalidTlaIdentifier,
    ActionNotEnabled,
    TraceDiverged,
    ActUncovered,
    UnknownAction,
    ActionMissing,
    ActionPayloadMissing,
    ActionPayloadUnsupported,
    ProjectionUnavailable,
    ProjectionFieldMissing,
    InvalidTraceFormat,
    NestingTooDeep,
    TraceVariablesUnverified,
    MissingModuleHeader,
    MissingModuleFooter,
    UnclosedComment,
    UnclosedStringLiteral,
    UnbalancedDelimiter,
    UnexpectedDelimiter,
};

pub const ReplayStats = struct {
    steps: usize = 0,
    actions_replayed: usize = 0,
    states_verified: usize = 0,

    /// Verify that every defined variant of `Act` was recorded by `pic`.
    pub fn verifyCoverage(self: *const ReplayStats, comptime Act: type, pic: *const picture.Picture) error{ActUncovered}!void {
        _ = self;
        return pic.verifyCoverage(Act);
    }
};

fn getFieldNames(comptime T: type) []const [:0]const u8 {
    return switch (@typeInfo(T)) {
        .@"enum" => |e| e.field_names,
        .@"union" => |u| u.field_names,
        .@"struct" => |s| s.field_names,
        else => @compileError("expected enum, union, or struct, got " ++ @typeName(T)),
    };
}

fn appendPrint(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    var buf: [256]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch {
        const heap_slice = try std.fmt.allocPrint(allocator, fmt, args);
        defer allocator.free(heap_slice);
        return out.appendSlice(allocator, heap_slice);
    };
    return out.appendSlice(allocator, slice);
}

fn appendEscapedTlaString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, str: []const u8) !void {
    try out.append(allocator, '"');
    for (str) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            '\x0c' => try out.appendSlice(allocator, "\\f"),
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

/// Checks whether an identifier conforms to TLA+ / SANY lexical syntax rules:
/// - Must begin with a letter or underscore (not a digit).
/// - Must consist exclusively of ASCII letters, digits, and underscores.
/// - Must contain at least one ASCII letter.
/// - Must not begin with temporal operator prefixes `WF_` or `SF_`.
/// - Must not collide with TLA+ reserved keywords (case-sensitive matching).
pub fn isValidTlaIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.startsWith(u8, name, "WF_") or std.mem.startsWith(u8, name, "SF_")) return false;

    const first = name[0];
    if (!((first >= 'a' and first <= 'z') or (first >= 'A' and first <= 'Z') or first == '_')) return false;

    var has_letter = false;
    for (name) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
            has_letter = true;
        } else if ((c >= '0' and c <= '9') or c == '_') {
            // valid continuation
        } else {
            return false;
        }
    }
    if (!has_letter) return false;

    // TLA+ is case-sensitive: only exact-case reserved words are rejected
    const reserved = [_][]const u8{
        "ACTION",
        "ASSUME",
        "ASSUMPTION",
        "AXIOM",
        "BOOLEAN",
        "BY",
        "CASE",
        "CHOOSE",
        "CONSTANT",
        "CONSTANTS",
        "COROLLARY",
        "DEF",
        "DEFINE",
        "DEFS",
        "DOMAIN",
        "ELSE",
        "ENABLED",
        "EXCEPT",
        "EXTENDS",
        "FALSE",
        "HAVE",
        "HIDE",
        "IF",
        "IN",
        "INSTANCE",
        "LAMBDA",
        "LEMMA",
        "LET",
        "LOCAL",
        "MODULE",
        "NEW",
        "OBVIOUS",
        "OMITTED",
        "ONLY",
        "OTHER",
        "PICK",
        "PROOF",
        "PROPOSITION",
        "PROVE",
        "QED",
        "RECURSIVE",
        "STATE",
        "STRING",
        "SUBSET",
        "SUFFICES",
        "TAKE",
        "TEMPORAL",
        "THEN",
        "THEOREM",
        "TRUE",
        "UNCHANGED",
        "UNION",
        "USE",
        "VARIABLE",
        "VARIABLES",
        "WITH",
        "WITNESS",
    };
    for (reserved) |kw| {
        if (std.mem.eql(u8, name, kw)) return false;
    }
    return true;
}

/// Checks whether an identifier collides with definitions exported by standard prelude
/// modules (Integers, Sequences, FiniteSets) or state_tcas generated definitions.
pub fn isTlaPreludeCollision(name: []const u8) bool {
    const prelude_symbols = [_][]const u8{
        // Symbols exported by Integers / Naturals
        "Nat",
        "Int",
        "Integers",
        "Naturals",
        // Symbols exported by Sequences
        "Seq",
        "Len",
        "Append",
        "Head",
        "Tail",
        "SubSeq",
        "SelectSeq",
        "Sequences",
        // Symbols exported by FiniteSets
        "IsFiniteSet",
        "Cardinality",
        "FiniteSets",
        // Generated module vocabulary
        "Actions",
        "States",
        "Init",
        "Next",
    };
    for (prelude_symbols) |sym| {
        if (std.mem.eql(u8, name, sym)) return true;
    }
    return false;
}

/// Format TLA+ module declarations containing constants and action/state sets from Zig types.
///
/// Compile-time safety:
/// - Validates that `module_name`, `Act`, `State`, and `Config` declarations conform to SANY TLA+ syntax.
/// - Rejects floating point, pointer, and unsupported complex types in `Config` via `@compileError`.
/// - Rejects Config declarations colliding with prelude module exports (`Nat`, `Int`, `Seq`, etc.) or generated vocabulary.
/// - `Act` must be an enum or union(enum).
/// - Action and state names are formatted as string sets to avoid keyword collisions in TLA+.
pub fn formatDeclarations(
    allocator: std.mem.Allocator,
    module_name: []const u8,
    comptime Act: type,
    comptime State: ?type,
    comptime Config: ?type,
) ![]u8 {
    if (!isValidTlaIdentifier(module_name) or isTlaPreludeCollision(module_name)) {
        return error.InvalidTlaIdentifier;
    }

    switch (@typeInfo(Act)) {
        .@"enum", .@"union" => {},
        else => @compileError("Act must be an enum or union(enum)"),
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendPrint(&out, allocator, "---- MODULE {s} ----\n", .{module_name});
    try out.appendSlice(allocator, "\\* Auto-generated by state_tcas.tla. Do not edit manually.\n");
    try out.appendSlice(allocator, "EXTENDS Integers, Sequences, FiniteSets\n\n");

    if (Config) |Cfg| {
        try out.appendSlice(allocator, "\\* System Configuration Constants\n");
        const cfg_info = @typeInfo(Cfg).@"struct";
        inline for (cfg_info.decl_names) |d_name| {
            const val = @field(Cfg, d_name);
            const ValType = @TypeOf(val);
            if (@typeInfo(ValType) != .type and @typeInfo(ValType) != .@"fn") {
                if (comptime !isValidTlaIdentifier(d_name)) {
                    @compileError("Config declaration is not a valid TLA+ identifier: " ++ d_name);
                }
                if (comptime isTlaPreludeCollision(d_name)) {
                    @compileError("Config declaration collides with generated TLA+ vocabulary or standard prelude (Integers, Sequences, FiniteSets): " ++ d_name);
                }
                validateConfigField(d_name, ValType);
                switch (@typeInfo(ValType)) {
                    .int, .comptime_int => try appendPrint(&out, allocator, "{s} == {d}\n", .{ d_name, val }),
                    .bool => try appendPrint(&out, allocator, "{s} == {s}\n", .{ d_name, if (val) "TRUE" else "FALSE" }),
                    .@"enum" => {
                        try appendPrint(&out, allocator, "{s} == ", .{d_name});
                        try appendEscapedTlaString(&out, allocator, @tagName(val));
                        try out.append(allocator, '\n');
                    },
                    else => unreachable,
                }
            }
        }
        try out.append(allocator, '\n');
    }

    // Actions vocabulary
    try out.appendSlice(allocator, "\\* Action Vocabulary\nActions == {");
    const act_names = comptime getFieldNames(Act);
    inline for (act_names, 0..) |name, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try appendEscapedTlaString(&out, allocator, name);
    }
    try out.appendSlice(allocator, "}\n\n");

    // States vocabulary
    if (State) |St| {
        try out.appendSlice(allocator, "\\* State Vocabulary\nStates == {");
        const st_names = comptime getFieldNames(St);
        inline for (st_names, 0..) |name, i| {
            if (i > 0) try out.appendSlice(allocator, ", ");
            try appendEscapedTlaString(&out, allocator, name);
        }
        try out.appendSlice(allocator, "}\n\n");
    }

    try out.appendSlice(allocator, "====\n");
    return out.toOwnedSlice(allocator);
}

fn validateConfigField(comptime name: []const u8, comptime T: type) void {
    switch (@typeInfo(T)) {
        .float => @compileError("TLA+ configuration does not support floating point types (field: " ++ name ++ ")"),
        .pointer => @compileError("TLA+ configuration does not support pointer types (field: " ++ name ++ ")"),
        .int, .comptime_int, .bool, .@"enum" => {},
        else => @compileError("TLA+ configuration unsupported type: " ++ @typeName(T) ++ " for field " ++ name),
    }
}

pub const LockOptions = struct {
    allow_update: bool = true,
    /// When specified or detected in the target file, locks and updates only the section
    /// enclosed by begin_marker and end_marker.
    section: ?struct {
        begin_marker: []const u8 = "\\* BEGIN DECLARATIONS",
        end_marker: []const u8 = "\\* END DECLARATIONS",
    } = null,
};

/// Format only the declaration block enclosed by begin and end markers.
pub fn formatDeclarationSectionWithMarkers(
    allocator: std.mem.Allocator,
    begin_marker: []const u8,
    end_marker: []const u8,
    comptime Act: type,
    comptime State: ?type,
    comptime Config: ?type,
) ![]u8 {
    switch (@typeInfo(Act)) {
        .@"enum", .@"union" => {},
        else => @compileError("Act must be an enum or union(enum)"),
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendPrint(&out, allocator, "{s}\n", .{begin_marker});
    try out.appendSlice(allocator, "\\* Auto-generated by state_tcas.tla. Do not edit manually.\n\n");

    if (Config) |Cfg| {
        try out.appendSlice(allocator, "\\* System Configuration Constants\n");
        const cfg_info = @typeInfo(Cfg).@"struct";
        inline for (cfg_info.decl_names) |d_name| {
            const val = @field(Cfg, d_name);
            const ValType = @TypeOf(val);
            if (@typeInfo(ValType) != .type and @typeInfo(ValType) != .@"fn") {
                if (comptime !isValidTlaIdentifier(d_name)) {
                    @compileError("Config declaration is not a valid TLA+ identifier: " ++ d_name);
                }
                if (comptime isTlaPreludeCollision(d_name)) {
                    @compileError("Config declaration collides with generated TLA+ vocabulary or standard prelude (Integers, Sequences, FiniteSets): " ++ d_name);
                }
                validateConfigField(d_name, ValType);
                switch (@typeInfo(ValType)) {
                    .int, .comptime_int => try appendPrint(&out, allocator, "{s} == {d}\n", .{ d_name, val }),
                    .bool => try appendPrint(&out, allocator, "{s} == {s}\n", .{ d_name, if (val) "TRUE" else "FALSE" }),
                    .@"enum" => {
                        try appendPrint(&out, allocator, "{s} == ", .{d_name});
                        try appendEscapedTlaString(&out, allocator, @tagName(val));
                        try out.append(allocator, '\n');
                    },
                    else => unreachable,
                }
            }
        }
        try out.append(allocator, '\n');
    }

    // Actions vocabulary
    try out.appendSlice(allocator, "\\* Action Vocabulary\nActions == {");
    const act_names = comptime getFieldNames(Act);
    inline for (act_names, 0..) |name, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try appendEscapedTlaString(&out, allocator, name);
    }
    try out.appendSlice(allocator, "}\n\n");

    // States vocabulary
    if (State) |St| {
        try out.appendSlice(allocator, "\\* State Vocabulary\nStates == {");
        const st_names = comptime getFieldNames(St);
        inline for (st_names, 0..) |name, i| {
            if (i > 0) try out.appendSlice(allocator, ", ");
            try appendEscapedTlaString(&out, allocator, name);
        }
        try out.appendSlice(allocator, "}\n\n");
    }

    try appendPrint(&out, allocator, "{s}\n", .{end_marker});
    return out.toOwnedSlice(allocator);
}

/// Format declaration block using standard default markers (`\* BEGIN DECLARATIONS` and `\* END DECLARATIONS`).
pub fn formatDeclarationSection(
    allocator: std.mem.Allocator,
    comptime Act: type,
    comptime State: ?type,
    comptime Config: ?type,
) ![]u8 {
    return formatDeclarationSectionWithMarkers(
        allocator,
        "\\* BEGIN DECLARATIONS",
        "\\* END DECLARATIONS",
        Act,
        State,
        Config,
    );
}

/// Verify generated TLA+ declarations against an on-disk lock file, preventing model drift.
///
/// Follows SANY and byte-level golden lock contracts:
/// - Enforces that `path` ends with `.tla` (`error.InvalidFilePath`).
/// - Enforces that `module_name` exactly matches the basename stem of `path` (`error.ModuleNameMismatch`).
/// - Enforces that `module_name` conforms to TLA+ identifier rules (`error.InvalidTlaIdentifier`).
/// - When cwd contains `.state_tcas-update-tla` AND `options.allow_update` is true, updates the on-disk file.
/// - Performs in-memory CRLF normalization (`\r\n` to `\n`) to prevent false drifts across Windows/Unix checkouts.
/// - Supports sectional locking when `\* BEGIN DECLARATIONS` ... `\* END DECLARATIONS` or
///   `\* BEGIN TRANSLATION` ... `\* END TRANSLATION` markers are present in the target file.
pub fn lockWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    module_name: []const u8,
    comptime Act: type,
    comptime State: ?type,
    comptime Config: ?type,
    options: LockOptions,
) !void {
    if (!isValidTlaIdentifier(module_name) or isTlaPreludeCollision(module_name)) {
        return error.InvalidTlaIdentifier;
    }
    const base = std.fs.path.basename(path);
    if (!std.mem.endsWith(u8, base, ".tla")) {
        return error.InvalidFilePath;
    }
    const stem = base[0 .. base.len - 4];
    if (!std.mem.eql(u8, stem, module_name)) {
        return error.ModuleNameMismatch;
    }

    const actual = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => {
            if (options.allow_update) {
                if (std.Io.Dir.cwd().access(io, ".state_tcas-update-tla", .{})) |_| {
                    const whole_expected = try formatDeclarations(allocator, module_name, Act, State, Config);
                    defer allocator.free(whole_expected);
                    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = whole_expected });
                    return;
                } else |_| {}
            }
            return error.TlaDrift;
        },
        else => return err,
    };
    defer allocator.free(actual);

    // Detect sectional locking markers
    var detected_begin: ?[]const u8 = null;
    var detected_end: ?[]const u8 = null;
    if (options.section) |sec| {
        detected_begin = sec.begin_marker;
        detected_end = sec.end_marker;
    } else {
        if (std.mem.indexOf(u8, actual, "\\* BEGIN DECLARATIONS") != null and
            std.mem.indexOf(u8, actual, "\\* END DECLARATIONS") != null)
        {
            detected_begin = "\\* BEGIN DECLARATIONS";
            detected_end = "\\* END DECLARATIONS";
        } else if (std.mem.indexOf(u8, actual, "\\* BEGIN TRANSLATION") != null and
            std.mem.indexOf(u8, actual, "\\* END TRANSLATION") != null)
        {
            detected_begin = "\\* BEGIN TRANSLATION";
            detected_end = "\\* END TRANSLATION";
        }
    }

    if (detected_begin != null and detected_end != null) {
        const b_marker = detected_begin.?;
        const e_marker = detected_end.?;
        const begin_idx = std.mem.indexOf(u8, actual, b_marker) orelse return error.TlaDrift;
        const end_idx = std.mem.indexOf(u8, actual, e_marker) orelse return error.TlaDrift;
        if (end_idx < begin_idx) return error.TlaDrift;

        var end_pos = end_idx + e_marker.len;
        if (end_pos < actual.len and actual[end_pos] == '\r') end_pos += 1;
        if (end_pos < actual.len and actual[end_pos] == '\n') end_pos += 1;

        const actual_section = actual[begin_idx..end_pos];
        const expected_section = try formatDeclarationSectionWithMarkers(allocator, b_marker, e_marker, Act, State, Config);
        defer allocator.free(expected_section);

        if (options.allow_update) {
            if (std.Io.Dir.cwd().access(io, ".state_tcas-update-tla", .{})) |_| {
                var updated: std.ArrayList(u8) = .empty;
                defer updated.deinit(allocator);
                try updated.appendSlice(allocator, actual[0..begin_idx]);
                try updated.appendSlice(allocator, expected_section);
                try updated.appendSlice(allocator, actual[end_pos..]);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = updated.items });
                return;
            } else |_| {}
        }

        if (std.mem.eql(u8, expected_section, actual_section)) return;
        if (picture.matchesNormalizingCRLF(expected_section, actual_section)) return;
        return error.TlaDrift;
    }

    const expected = try formatDeclarations(allocator, module_name, Act, State, Config);
    defer allocator.free(expected);

    // Update locked file only if explicitly allowed AND update flag exists in cwd
    if (options.allow_update) {
        if (std.Io.Dir.cwd().access(io, ".state_tcas-update-tla", .{})) |_| {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = expected });
            return;
        } else |_| {}
    }

    if (std.mem.eql(u8, expected, actual)) return;
    if (picture.matchesNormalizingCRLF(expected, actual)) return;
    return error.TlaDrift;
}

pub fn lock(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    module_name: []const u8,
    comptime Act: type,
    comptime State: ?type,
    comptime Config: ?type,
) !void {
    return lockWithOptions(io, allocator, path, module_name, Act, State, Config, .{});
}

fn isValidIntegerString(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[0] == '-' or s[0] == '+') {
        if (s.len == 1) return false;
        i = 1;
    }
    while (i < s.len) : (i += 1) {
        if (s[i] < '0' or s[i] > '9') return false;
    }
    return true;
}

/// Recursively decodes Apalache ITF (Informal Trace Format) wrappers within a JSON value:
/// - Unwraps integer objects `{"#bigint": "123"}` into standard JSON integer or number_string values.
/// - Unwraps tuple objects `{"#tup": [...]}` into standard JSON array values.
/// - Unwraps set objects `{"#set": [...]}` into standard JSON array values.
/// - Unwraps map objects `{"#map": [[k, v], ...]}` into standard JSON objects (for string keys) or pair arrays.
/// - Rejects malformed wrappers and `#unserializable` payloads (`error.InvalidTraceFormat`).
/// - Enforces a recursion depth limit (64 levels) against stack overflow (`error.NestingTooDeep`).
pub fn decodeItfValue(allocator: std.mem.Allocator, val: std.json.Value) !std.json.Value {
    return decodeItfValueWithDepth(allocator, val, 0);
}

fn decodeItfValueWithDepth(allocator: std.mem.Allocator, val: std.json.Value, depth: usize) !std.json.Value {
    if (depth > 64) return error.NestingTooDeep;

    switch (val) {
        .object => |obj| {
            if (obj.get("#unserializable") != null) {
                return error.InvalidTraceFormat;
            }

            // Check for #bigint: {"#bigint": "..."}
            if (obj.get("#bigint")) |bigint_val| {
                if (obj.count() != 1 or bigint_val != .string) return error.InvalidTraceFormat;
                const str = bigint_val.string;
                if (!isValidIntegerString(str)) return error.InvalidTraceFormat;
                if (std.fmt.parseInt(i64, str, 10)) |int_val| {
                    return .{ .integer = int_val };
                } else |_| {
                    return .{ .number_string = str };
                }
            }

            // Check for #tup: {"#tup": [...]}
            if (obj.get("#tup")) |tup_val| {
                if (obj.count() != 1 or tup_val != .array) return error.InvalidTraceFormat;
                return decodeItfValueWithDepth(allocator, tup_val, depth + 1);
            }

            // Check for #set: {"#set": [...]}
            if (obj.get("#set")) |set_val| {
                if (obj.count() != 1 or set_val != .array) return error.InvalidTraceFormat;
                return decodeItfValueWithDepth(allocator, set_val, depth + 1);
            }

            // Check for #map: {"#map": [ [k, v], ... ]}
            if (obj.get("#map")) |map_val| {
                if (obj.count() != 1 or map_val != .array) return error.InvalidTraceFormat;
                var all_keys_string = (map_val.array.items.len > 0);
                for (map_val.array.items) |entry| {
                    if (entry != .array or entry.array.items.len != 2) return error.InvalidTraceFormat;
                    if (entry.array.items[0] != .string) {
                        all_keys_string = false;
                    }
                }
                if (all_keys_string) {
                    var new_obj: std.json.ObjectMap = .empty;
                    for (map_val.array.items) |entry| {
                        const k = entry.array.items[0].string;
                        if (new_obj.contains(k)) return error.InvalidTraceFormat;
                        const v = try decodeItfValueWithDepth(allocator, entry.array.items[1], depth + 1);
                        try new_obj.put(allocator, k, v);
                    }
                    return .{ .object = new_obj };
                } else {
                    var new_arr = std.json.Array.init(allocator);
                    try new_arr.ensureTotalCapacity(map_val.array.items.len);
                    for (map_val.array.items) |entry| {
                        const unwrapped_k = try decodeItfValueWithDepth(allocator, entry.array.items[0], depth + 1);
                        const unwrapped_v = try decodeItfValueWithDepth(allocator, entry.array.items[1], depth + 1);
                        var pair = std.json.Array.init(allocator);
                        try pair.append(unwrapped_k);
                        try pair.append(unwrapped_v);
                        try new_arr.append(.{ .array = pair });
                    }
                    return .{ .array = new_arr };
                }
            }

            // Reject any unrecognized # wrapper keys
            for (obj.keys()) |k| {
                if (std.mem.startsWith(u8, k, "#")) {
                    return error.InvalidTraceFormat;
                }
            }

            // Otherwise, recursively decode all fields in this object
            var new_obj: std.json.ObjectMap = .empty;
            for (obj.keys(), obj.values()) |k, v| {
                const unwrapped_v = try decodeItfValueWithDepth(allocator, v, depth + 1);
                try new_obj.put(allocator, k, unwrapped_v);
            }
            return .{ .object = new_obj };
        },
        .array => |arr| {
            var new_arr = std.json.Array.init(allocator);
            try new_arr.ensureTotalCapacity(arr.items.len);
            for (arr.items) |elem| {
                const unwrapped_elem = try decodeItfValueWithDepth(allocator, elem, depth + 1);
                try new_arr.append(unwrapped_elem);
            }
            return .{ .array = new_arr };
        },
        else => return val,
    }
}

/// Recursively compares two `std.json.Value` instances for deep structural equality.
pub fn jsonValueEql(a: std.json.Value, b: std.json.Value) bool {
    switch (a) {
        .null => return b == .null,
        .bool => |av| return b == .bool and av == b.bool,
        .integer => |av| return b == .integer and av == b.integer,
        .float => |av| return b == .float and av == b.float,
        .number_string => |av| return b == .number_string and std.mem.eql(u8, av, b.number_string),
        .string => |av| return b == .string and std.mem.eql(u8, av, b.string),
        .array => |av| {
            if (b != .array or av.items.len != b.array.items.len) return false;
            for (av.items, b.array.items) |ai, bi| {
                if (!jsonValueEql(ai, bi)) return false;
            }
            return true;
        },
        .object => |av| {
            if (b != .object or av.count() != b.object.count()) return false;
            for (av.keys(), av.values()) |k, v| {
                const bv = b.object.get(k) orelse return false;
                if (!jsonValueEql(v, bv)) return false;
            }
            return true;
        },
    }
}

fn isEmptyTupleOrNull(v: std.json.Value) bool {
    switch (v) {
        .null => return true,
        .array => |arr| return arr.items.len == 0,
        .object => |obj| {
            if (obj.count() == 0) return true;
            if (obj.get("#tup")) |tup| {
                return tup == .array and tup.array.items.len == 0;
            }
            return false;
        },
        else => return false,
    }
}

fn adaptVariantForType(comptime Target: type, allocator: std.mem.Allocator, val: std.json.Value) anyerror!std.json.Value {
    return adaptVariantForTypeWithDepth(Target, allocator, val, 0);
}

fn adaptVariantForTypeWithDepth(comptime Target: type, allocator: std.mem.Allocator, val: std.json.Value, depth: usize) anyerror!std.json.Value {
    if (depth > 64) return error.NestingTooDeep;

    switch (@typeInfo(Target)) {
        .@"union" => |u| {
            if (val == .object) {
                // 1. Apalache ADT variant wrapper: {"tag": "VariantName", "value": ...}
                if (val.object.count() == 2) {
                    if (val.object.get("tag")) |t_val| {
                        if (t_val == .string) {
                            if (val.object.get("value")) |v_val| {
                                inline for (u.field_names, u.field_types) |uf_name, uf_type| {
                                    if (std.mem.eql(u8, uf_name, t_val.string)) {
                                        var new_obj: std.json.ObjectMap = .empty;
                                        if (uf_type == void and isEmptyTupleOrNull(v_val)) {
                                            try new_obj.put(allocator, t_val.string, .{ .object = .empty });
                                            return .{ .object = new_obj };
                                        }
                                        const inner = try adaptVariantForTypeWithDepth(uf_type, allocator, v_val, depth + 1);
                                        try new_obj.put(allocator, t_val.string, inner);
                                        return .{ .object = new_obj };
                                    }
                                }
                            }
                        }
                    }
                }

                // 2. Standard JSON union representation: {"VariantName": ...}
                var new_obj: std.json.ObjectMap = .empty;
                for (val.object.keys(), val.object.values()) |k, v| {
                    var adapted_v = v;
                    inline for (u.field_names, u.field_types) |uf_name, uf_type| {
                        if (std.mem.eql(u8, uf_name, k)) {
                            adapted_v = try adaptVariantForTypeWithDepth(uf_type, allocator, v, depth + 1);
                        }
                    }
                    try new_obj.put(allocator, k, adapted_v);
                }
                return .{ .object = new_obj };
            }
            return val;
        },
        .@"struct" => |s| {
            if (val == .object) {
                var new_obj: std.json.ObjectMap = .empty;
                for (val.object.keys(), val.object.values()) |k, v| {
                    var adapted_v = v;
                    inline for (s.field_names, s.field_types) |sf_name, sf_type| {
                        if (std.mem.eql(u8, sf_name, k)) {
                            adapted_v = try adaptVariantForTypeWithDepth(sf_type, allocator, v, depth + 1);
                        }
                    }
                    try new_obj.put(allocator, k, adapted_v);
                }
                return .{ .object = new_obj };
            }
            return val;
        },
        .optional => |opt| {
            if (val == .null) return val;
            // Support Apalache / Quint Option variant: {"tag": "Some", "value": ...} or {"tag": "None", ...}
            if (val == .object and val.object.count() == 2) {
                if (val.object.get("tag")) |t_val| {
                    if (t_val == .string) {
                        if (std.mem.eql(u8, t_val.string, "None")) {
                            return .null;
                        } else if (std.mem.eql(u8, t_val.string, "Some")) {
                            if (val.object.get("value")) |v_val| {
                                return adaptVariantForTypeWithDepth(opt.child, allocator, v_val, depth + 1);
                            }
                        }
                    }
                }
            }
            return adaptVariantForTypeWithDepth(opt.child, allocator, val, depth + 1);
        },
        .array => |arr| {
            if (val == .array) {
                var new_arr = std.json.Array.init(allocator);
                try new_arr.ensureTotalCapacity(val.array.items.len);
                for (val.array.items) |elem| {
                    const adapted = try adaptVariantForTypeWithDepth(arr.child, allocator, elem, depth + 1);
                    try new_arr.append(adapted);
                }
                return .{ .array = new_arr };
            }
            return val;
        },
        .pointer => |p| {
            switch (p.size) {
                .slice => {
                    if (val == .array) {
                        var new_arr = std.json.Array.init(allocator);
                        try new_arr.ensureTotalCapacity(val.array.items.len);
                        for (val.array.items) |elem| {
                            const adapted = try adaptVariantForTypeWithDepth(p.child, allocator, elem, depth + 1);
                            try new_arr.append(adapted);
                        }
                        return .{ .array = new_arr };
                    }
                    return val;
                },
                .one => {
                    return adaptVariantForTypeWithDepth(p.child, allocator, val, depth + 1);
                },
                else => return val,
            }
        },
        else => return val,
    }
}

/// Parse an action identifier and optional payload value into the `Act` type (enum or tagged union).
///
/// Note: For non-void payloads containing pointers or slices, memory is allocated from `allocator`
/// (which is typically an arena allocator during trace replay).
/// Apalache ITF wrappers (e.g. `{"#bigint": "10"}`) are decoded recursively before parsing.
pub fn parseActFromValue(
    comptime Act: type,
    allocator: std.mem.Allocator,
    name: []const u8,
    payload_val: ?std.json.Value,
) !?Act {
    switch (@typeInfo(Act)) {
        .@"enum" => |e| {
            if (payload_val) |pv| {
                if (!isEmptyTupleOrNull(pv)) return error.ActionPayloadUnsupported;
            }
            inline for (e.field_names, e.field_values) |f_name, f_val| {
                if (std.mem.eql(u8, f_name, name)) return @fromBackingInt(@intCast(f_val));
            }
            return null;
        },
        .@"union" => |u| {
            inline for (u.field_names, u.field_types) |f_name, f_type| {
                if (std.mem.eql(u8, f_name, name)) {
                    if (f_type == void) {
                        if (payload_val) |pv| {
                            if (isEmptyTupleOrNull(pv)) {
                                return @unionInit(Act, f_name, {});
                            }
                            return error.ActionPayloadUnsupported;
                        }
                        return @unionInit(Act, f_name, {});
                    } else {
                        if (payload_val) |pv| {
                            const decoded_pv = try decodeItfValue(allocator, pv);
                            const adapted_pv = try adaptVariantForType(f_type, allocator, decoded_pv);
                            const val = std.json.parseFromValueLeaky(f_type, allocator, adapted_pv, .{}) catch |err| {
                                switch (err) {
                                    error.OutOfMemory => return error.OutOfMemory,
                                    else => return error.ActionPayloadUnsupported,
                                }
                            };
                            return @unionInit(Act, f_name, val);
                        } else {
                            return error.ActionPayloadMissing;
                        }
                    }
                }
            }
            return null;
        },
        else => @compileError("Act must be enum or tagged union"),
    }
}

/// Parse a simple action identifier without payload into `Act`.
///
/// NOTE: This function is only intended for enum actions or tagged union variants with void payload.
/// If the variant requires a non-void payload, this function returns `null`.
pub fn parseAct(comptime Act: type, name: []const u8) ?Act {
    switch (@typeInfo(Act)) {
        .@"enum" => return std.meta.stringToEnum(Act, name),
        .@"union" => |u| {
            inline for (u.field_names, u.field_types) |f_name, f_type| {
                if (std.mem.eql(u8, f_name, name)) {
                    if (f_type == void) {
                        return @unionInit(Act, f_name, {});
                    } else {
                        return null;
                    }
                }
            }
            return null;
        },
        else => @compileError("Act must be enum or tagged union"),
    }
}

fn isActionInAct(comptime Act: type, name: []const u8) bool {
    switch (@typeInfo(Act)) {
        .@"enum" => |e| {
            inline for (e.field_names) |f| {
                if (std.ascii.eqlIgnoreCase(f, name)) return true;
            }
            return false;
        },
        .@"union" => |u| {
            inline for (u.field_names) |f| {
                if (std.ascii.eqlIgnoreCase(f, name)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn actionEql(comptime Act: type, a: Act, b: Act) bool {
    return deepEql(Act, a, b);
}

/// Recursively compares two values for structural equality.
///
/// Handles:
/// - Slices: recursively compares elements by value (not by pointer identity)
/// - Pointers: dereferences single-item pointers (`*T`) and recursively compares target;
///   for opaque pointers (`*anyopaque`) or function pointers, falls back to pointer address comparison
/// - Structs, Arrays, Optionals, Unions: recursively compares all constituent fields
/// - Primitives and enums: standard equality
///
/// NOTE: Circular references (e.g. self-referencing pointers) will cause infinite recursion.
pub fn deepEql(comptime T: type, a: T, b: T) bool {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            switch (p.size) {
                .slice => {
                    if (a.len != b.len) return false;
                    for (a, b) |elem_a, elem_b| {
                        if (!deepEql(p.child, elem_a, elem_b)) return false;
                    }
                    return true;
                },
                .one => {
                    switch (@typeInfo(p.child)) {
                        .@"opaque", .@"fn" => return a == b,
                        else => return deepEql(p.child, a.*, b.*),
                    }
                },
                .many, .c => return a == b,
            }
        },
        .@"struct" => |s| {
            inline for (s.field_names) |f_name| {
                if (!deepEql(@TypeOf(@field(a, f_name)), @field(a, f_name), @field(b, f_name))) {
                    return false;
                }
            }
            return true;
        },
        .optional => {
            if (a == null and b == null) return true;
            if (a == null or b == null) return false;
            return deepEql(@typeInfo(T).optional.child, a.?, b.?);
        },
        .array => |arr| {
            for (a, b) |elem_a, elem_b| {
                if (!deepEql(arr.child, elem_a, elem_b)) return false;
            }
            return true;
        },
        .@"union" => |u| {
            const tag_a = std.meta.activeTag(a);
            const tag_b = std.meta.activeTag(b);
            if (tag_a != tag_b) return false;
            inline for (u.field_names, u.field_types) |f_name, f_type| {
                if (std.mem.eql(u8, f_name, @tagName(tag_a))) {
                    if (f_type == void) return true;
                    return deepEql(f_type, @field(a, f_name), @field(b, f_name));
                }
            }
            return false;
        },
        else => return std.meta.eql(a, b),
    }
}

pub const ReplayOptions = struct {
    /// Expected rejection specification for negative counterexample regression testing.
    /// When specified, replay expects a failure at `at_step` with `err`.
    /// If the failure matches, replayJsonTraceWithOptions returns normally with stats up to that step.
    /// If the replay succeeds without rejection, it returns error.RejectionExpected.
    expect_rejection: ?struct {
        at_step: usize,
        err: anyerror,
    } = null,
    /// When false (default), returns error.TraceVariablesUnverified if a step object
    /// contains custom state variables not verified by a scalar/enum projection.
    /// Set to true to allow unverified trace variables to be silently ignored.
    allow_unverified_variables: bool = false,
};

fn tryCloneCtx(ctx: anytype) !Unwrap(@TypeOf(ctx)) {
    const CtxType = Unwrap(@TypeOf(ctx));
    if (@hasDecl(CtxType, "clone")) {
        const clone_fn = CtxType.clone;
        const fn_info = @typeInfo(@TypeOf(clone_fn)).@"fn";
        if (fn_info.param_types.len >= 1) {
            const P0 = fn_info.param_types[0] orelse CtxType;
            const receiver = if (@typeInfo(P0) == .pointer)
                (if (@typeInfo(@TypeOf(ctx)) == .pointer) ctx else &ctx)
            else
                (if (@typeInfo(@TypeOf(ctx)) == .pointer) ctx.* else ctx);
            const res = receiver.clone();
            return switch (@typeInfo(@TypeOf(res))) {
                .error_union => try res,
                else => res,
            };
        }
    }
    return error.CloneUnsupported;
}

fn deinitCtx(trial: anytype, allocator: std.mem.Allocator) void {
    const T = Unwrap(@TypeOf(trial));
    if (@hasDecl(T, "deinit")) {
        const deinit_fn = T.deinit;
        const fn_info = @typeInfo(@TypeOf(deinit_fn)).@"fn";
        if (fn_info.param_types.len == 1) {
            trial.deinit();
        } else if (fn_info.param_types.len == 2) {
            trial.deinit(allocator);
        }
    }
}

fn checkStateMatches(
    cur_st: anytype,
    item: std.json.Value,
    exp_state_name: ?[]const u8,
    arena_allocator: std.mem.Allocator,
) bool {
    const ST = @TypeOf(cur_st);
    switch (@typeInfo(ST)) {
        .@"struct" => |s| {
            if (item != .object) return false;
            var verified_count: usize = 0;
            var matched_exp_state = false;

            inline for (s.field_names, s.field_types) |sf_name, sf_type| {
                const maybe_exp_v = if (item.object.get(sf_name)) |v|
                    v
                else if (comptime std.mem.eql(u8, sf_name, "state"))
                    item.object.get("after")
                else if (comptime std.mem.eql(u8, sf_name, "after"))
                    item.object.get("state")
                else
                    null;

                if (maybe_exp_v) |exp_v| {
                    const decoded_v = decodeItfValue(arena_allocator, exp_v) catch return false;
                    const adapted_v = adaptVariantForType(sf_type, arena_allocator, decoded_v) catch return false;
                    const parsed_exp = std.json.parseFromValueLeaky(sf_type, arena_allocator, adapted_v, .{}) catch return false;
                    if (!deepEql(sf_type, @field(cur_st, sf_name), parsed_exp)) {
                        return false;
                    }
                    verified_count += 1;
                    if (comptime (std.mem.eql(u8, sf_name, "state") or std.mem.eql(u8, sf_name, "after"))) {
                        matched_exp_state = true;
                    }
                } else if (comptime (std.mem.eql(u8, sf_name, "state") or std.mem.eql(u8, sf_name, "after"))) {
                    if (exp_state_name) |exp_st| {
                        const sub_val = @field(cur_st, sf_name);
                        const sub_val_str: ?[]const u8 = switch (@typeInfo(@TypeOf(sub_val))) {
                            .@"enum" => @tagName(sub_val),
                            .pointer => |p| if (p.size == .slice and p.child == u8) sub_val else null,
                            else => null,
                        };
                        if (sub_val_str) |s_str| {
                            if (!std.mem.eql(u8, s_str, exp_st)) return false;
                            verified_count += 1;
                            matched_exp_state = true;
                        } else return false;
                    } else if (@typeInfo(sf_type) != .optional) {
                        return false;
                    }
                } else if (@typeInfo(sf_type) != .optional) {
                    return false;
                }
            }

            const has_explicit_state_in_trace = (exp_state_name != null or item.object.get("state") != null or item.object.get("after") != null);
            if (has_explicit_state_in_trace and !matched_exp_state) {
                return false;
            }
            return verified_count > 0;
        },
        .@"enum" => {
            const exp_st = exp_state_name orelse blk: {
                if (item == .object) {
                    if (item.object.get("state")) |v| {
                        if (v == .string) break :blk v.string;
                    }
                    if (item.object.get("after")) |v| {
                        if (v == .string) break :blk v.string;
                    }
                }
                break :blk null;
            };
            if (exp_st) |s| {
                return std.mem.eql(u8, @tagName(cur_st), s);
            }
            return false;
        },
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) {
                const exp_st = exp_state_name orelse blk: {
                    if (item == .object) {
                        if (item.object.get("state")) |v| {
                            if (v == .string) break :blk v.string;
                        }
                        if (item.object.get("after")) |v| {
                            if (v == .string) break :blk v.string;
                        }
                    }
                    break :blk null;
                };
                if (exp_st) |s| {
                    return std.mem.eql(u8, cur_st, s);
                }
                return false;
            } else false,
            .one => switch (@typeInfo(p.child)) {
                .array => |arr| if (arr.child == u8) {
                    const exp_st = exp_state_name orelse blk: {
                        if (item == .object) {
                            if (item.object.get("state")) |v| {
                                if (v == .string) break :blk v.string;
                            }
                            if (item.object.get("after")) |v| {
                                if (v == .string) break :blk v.string;
                            }
                        }
                        break :blk null;
                    };
                    if (exp_st) |s| {
                        return std.mem.eql(u8, cur_st[0..arr.len], s);
                    }
                    return false;
                } else false,
                else => false,
            },
            else => false,
        },
        else => false,
    }
}

fn inferTransitionAction(
    comptime Act: type,
    ctx: anytype,
    item: std.json.Value,
    exp_state_name: ?[]const u8,
    arena_allocator: std.mem.Allocator,
) !?Act {
    const CtxType = Unwrap(@TypeOf(ctx));
    if (@hasDecl(CtxType, "inferAction")) {
        return ctx.inferAction(item);
    }
    if (!@hasDecl(CtxType, "enabled") or !@hasDecl(CtxType, "project") or !@hasDecl(CtxType, "clone")) {
        return null;
    }
    const en = ctx.enabled();
    if (en.len == 0) return null;

    for (en) |cand| {
        var trial = tryCloneCtx(ctx) catch continue;
        defer deinitCtx(&trial, arena_allocator);

        dispatchStep(&trial, cand, null) catch continue;
        if (checkStateMatches(trial.project(), item, exp_state_name, arena_allocator)) {
            return cand;
        }
    }
    return null;
}

/// Result of executing a domain replay step.
/// Strongly distinguishes between successful transitions and domain-level rejections
/// (e.g., enabling guard rejections, step error rejections, or trace divergence).
pub const StepOutcome = union(enum) {
    success,
    domain_rejection: anyerror,
};

fn StructExpectation(comptime S: type) type {
    const s_info = @typeInfo(S).@"struct";
    return struct {
        specified: [s_info.field_names.len]bool = @splat(false),
        values: S = undefined,
        string_alias: ?[]const u8 = null,
        string_alias_field_idx: ?usize = null,
    };
}

fn StepPlan(comptime Act: type, comptime ProjType: type) type {
    const is_struct_proj = (@typeInfo(ProjType) == .@"struct");
    return struct {
        action: ?Act = null,
        expected_scalar_state: ?[]const u8 = null,
        struct_expectation: if (is_struct_proj) StructExpectation(ProjType) else void =
            if (is_struct_proj) .{} else {},
    };
}

fn isKnownStepField(name: []const u8) bool {
    return std.mem.eql(u8, name, "action") or
        std.mem.eql(u8, name, "actionTaken") or
        std.mem.eql(u8, name, "mbt::actionTaken") or
        std.mem.eql(u8, name, "payload") or
        std.mem.eql(u8, name, "mbt::nondetPicks") or
        std.mem.eql(u8, name, "state") or
        std.mem.eql(u8, name, "after") or
        std.mem.eql(u8, name, "#meta") or
        std.mem.eql(u8, name, "step") or
        std.mem.eql(u8, name, "note");
}

/// Phase 1: Ingestion & Validation
/// Parses a single step from the JSON trace, validates syntax and schema,
/// decodes action payloads / ITF wrappers, infers state-only transitions,
/// and pre-parses expected projection states.
/// Any failure in this phase is a fatal test infrastructure/format error.
fn ingestStepPlan(
    comptime Act: type,
    comptime ProjType: type,
    ctx: anytype,
    item: std.json.Value,
    step_index: usize,
    trace_info: TraceInfo,
    options: ReplayOptions,
    arena_allocator: std.mem.Allocator,
) !StepPlan(Act, ProjType) {
    const CtxType = Unwrap(@TypeOf(ctx));
    const has_enabled = @hasDecl(CtxType, "enabled");
    const has_project = @hasDecl(CtxType, "project");
    const is_struct_proj = (has_project and @typeInfo(ProjType) == .@"struct");

    var act_name: ?[]const u8 = null;
    var exp_state_name: ?[]const u8 = null;
    var payload_val: ?std.json.Value = null;
    var has_state_assertion = false;

    switch (item) {
        .string => |s| {
            act_name = s;
        },
        .object => |obj| {
            if (obj.get("action")) |v| {
                if (v != .string) return error.InvalidTraceFormat;
                act_name = v.string;
            }
            if (obj.get("actionTaken")) |v| {
                if (v != .string) return error.InvalidTraceFormat;
                if (act_name != null and !std.mem.eql(u8, act_name.?, v.string)) return error.InvalidTraceFormat;
                act_name = v.string;
            }
            if (obj.get("mbt::actionTaken")) |v| {
                if (v != .string) return error.InvalidTraceFormat;
                if (act_name != null and !std.mem.eql(u8, act_name.?, v.string)) return error.InvalidTraceFormat;
                act_name = v.string;
            }

            if (obj.get("payload")) |v| {
                payload_val = v;
            }
            if (obj.get("mbt::nondetPicks")) |v| {
                if (payload_val != null and !jsonValueEql(payload_val.?, v)) return error.InvalidTraceFormat;
                payload_val = v;
            }

            if (obj.get("state")) |v| {
                if (v == .string) {
                    exp_state_name = v.string;
                } else if (!is_struct_proj) {
                    return error.InvalidTraceFormat;
                } else if (!@hasField(ProjType, "state") and !@hasField(ProjType, "after")) {
                    return error.ProjectionUnavailable;
                }
            }
            if (obj.get("after")) |v| {
                if (obj.get("state")) |st_v| {
                    if (!jsonValueEql(st_v, v)) return error.InvalidTraceFormat;
                }
                if (v == .string) {
                    if (exp_state_name != null and !std.mem.eql(u8, exp_state_name.?, v.string)) return error.InvalidTraceFormat;
                    exp_state_name = v.string;
                } else if (!is_struct_proj) {
                    return error.InvalidTraceFormat;
                } else if (!@hasField(ProjType, "after") and !@hasField(ProjType, "state")) {
                    return error.ProjectionUnavailable;
                }
            }

            if (exp_state_name != null) {
                has_state_assertion = true;
            } else if (is_struct_proj) {
                switch (@typeInfo(ProjType)) {
                    .@"struct" => |s| {
                        inline for (s.field_names) |sf_name| {
                            const is_st_field = comptime std.mem.eql(u8, sf_name, "state");
                            const is_aft_field = comptime std.mem.eql(u8, sf_name, "after");
                            if (obj.get(sf_name) != null or
                                (is_st_field and obj.get("after") != null) or
                                (is_aft_field and obj.get("state") != null))
                            {
                                has_state_assertion = true;
                                break;
                            }
                        }
                    },
                    else => {},
                }
            }

            // In ITF format, step 0 is pure initial state and does not require action
            if (act_name == null and step_index > 0 and !trace_info.is_itf) {
                return error.InvalidTraceFormat;
            }
            if (act_name == null and step_index == 0 and !has_state_assertion) {
                return error.InvalidTraceFormat;
            }

            if (has_project and !is_struct_proj and !options.allow_unverified_variables) {
                var it = obj.iterator();
                while (it.next()) |entry| {
                    if (!isKnownStepField(entry.key_ptr.*)) {
                        return error.TraceVariablesUnverified;
                    }
                }
            }
        },
        else => return error.InvalidTraceFormat,
    }

    // Handle ITF initial state:
    // In Apalache ITF, step 0 represents the initialization predicate (typically named "init" or "Init").
    // When step 0 has action "init", if "init" is not declared in Act and lacks state assertion, reject.
    // If it is an ITF trace (states array), treat as initial state predicate without executing as a transition.
    var should_dispatch = true;
    if (step_index == 0 and act_name != null and std.ascii.eqlIgnoreCase(act_name.?, "init")) {
        if (!isActionInAct(Act, act_name.?)) {
            if (!has_state_assertion and !trace_info.is_itf) {
                return error.InvalidTraceFormat;
            }
            should_dispatch = false;
        } else if (trace_info.is_itf) {
            should_dispatch = false;
        }
    }

    var act_to_dispatch: ?Act = null;
    if (act_name != null) {
        if (should_dispatch) {
            const name = act_name.?;
            const maybe_act = try parseActFromValue(Act, arena_allocator, name, payload_val);
            act_to_dispatch = maybe_act orelse return error.UnknownAction;
        }
    } else if (step_index > 0) {
        // Standard ITF state-only trace: infer transition action from adjacent states
        if (has_enabled and has_project) {
            act_to_dispatch = try inferTransitionAction(Act, ctx, item, exp_state_name, arena_allocator);
        }
        if (act_to_dispatch == null) {
            return error.ActionMissing;
        }
    }

    var plan = StepPlan(Act, ProjType){
        .action = act_to_dispatch,
        .expected_scalar_state = exp_state_name,
    };

    // State projection validation & pre-parsing
    if (has_project) {
        if (is_struct_proj) {
            if (item != .object) return error.InvalidTraceFormat;
            const s = @typeInfo(ProjType).@"struct";
            var matched_exp_state = false;

            inline for (s.field_names, s.field_types, 0..) |sf_name, sf_type, idx| {
                const maybe_exp_v = if (item.object.get(sf_name)) |v|
                    v
                else if (comptime std.mem.eql(u8, sf_name, "state"))
                    item.object.get("after")
                else if (comptime std.mem.eql(u8, sf_name, "after"))
                    item.object.get("state")
                else
                    null;

                if (maybe_exp_v) |exp_v| {
                    const decoded_v = try decodeItfValue(arena_allocator, exp_v);
                    const adapted_v = try adaptVariantForType(sf_type, arena_allocator, decoded_v);
                    const parsed_exp = std.json.parseFromValueLeaky(sf_type, arena_allocator, adapted_v, .{}) catch |err| {
                        switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => return error.InvalidTraceFormat,
                        }
                    };
                    @field(plan.struct_expectation.values, sf_name) = parsed_exp;
                    plan.struct_expectation.specified[idx] = true;
                    if (comptime (std.mem.eql(u8, sf_name, "state") or std.mem.eql(u8, sf_name, "after"))) {
                        matched_exp_state = true;
                    }
                } else if (comptime (std.mem.eql(u8, sf_name, "state") or std.mem.eql(u8, sf_name, "after"))) {
                    if (exp_state_name) |exp_st| {
                        plan.struct_expectation.specified[idx] = true;
                        plan.struct_expectation.string_alias = exp_st;
                        plan.struct_expectation.string_alias_field_idx = idx;
                        matched_exp_state = true;
                    } else {
                        if (@typeInfo(sf_type) != .optional) {
                            return error.ProjectionFieldMissing;
                        }
                    }
                } else {
                    if (@typeInfo(sf_type) != .optional) {
                        return error.ProjectionFieldMissing;
                    }
                }
            }

            // If trace had explicit state label/alias but struct didn't verify it:
            const has_explicit_state_in_trace = (exp_state_name != null or item.object.get("state") != null or item.object.get("after") != null);
            if (has_explicit_state_in_trace and !matched_exp_state) {
                return error.ProjectionUnavailable;
            }
        }
    } else if (exp_state_name != null) {
        return error.ProjectionUnavailable;
    }

    return plan;
}

/// Phase 2: Domain Execution & Invariant Verification
/// Executes enabling guards, advances state machine transition, and verifies state projections.
/// Returns a typed StepOutcome (.success or .domain_rejection = anyerror).
/// Ingestion/infrastructure errors cannot be produced here by construction.
fn executeStepPlan(
    comptime Act: type,
    comptime ProjType: type,
    ctx: anytype,
    plan: StepPlan(Act, ProjType),
    pic: ?*picture.Picture,
    stats: *ReplayStats,
) StepOutcome {
    const CtxType = Unwrap(@TypeOf(ctx));
    const has_enabled = @hasDecl(CtxType, "enabled");
    const has_project = @hasDecl(CtxType, "project");
    const is_struct_proj = (has_project and @typeInfo(ProjType) == .@"struct");

    if (plan.action) |act| {
        // 1. Enabling guard check with deep equality for slice payloads
        if (has_enabled) {
            const en = ctx.enabled();
            var is_en = false;
            for (en) |cand| {
                if (actionEql(Act, cand, act)) {
                    is_en = true;
                    break;
                }
            }
            if (!is_en) return .{ .domain_rejection = error.ActionNotEnabled };
        }

        // 2. Dispatch step
        dispatchStep(ctx, act, pic) catch |err| {
            return .{ .domain_rejection = err };
        };
        stats.actions_replayed += 1;
    }

    // 3. State projection check
    if (has_project) {
        const cur_st = ctx.project();
        if (is_struct_proj) {
            const s = @typeInfo(ProjType).@"struct";
            var verified_count: usize = 0;

            inline for (s.field_names, s.field_types, 0..) |sf_name, sf_type, idx| {
                if (plan.struct_expectation.specified[idx]) {
                    if (plan.struct_expectation.string_alias != null and
                        plan.struct_expectation.string_alias_field_idx.? == idx)
                    {
                        const sub_val = @field(cur_st, sf_name);
                        const sub_val_str: ?[]const u8 = switch (@typeInfo(@TypeOf(sub_val))) {
                            .@"enum" => @tagName(sub_val),
                            .pointer => |p| if (p.size == .slice and p.child == u8) sub_val else null,
                            else => null,
                        };
                        if (sub_val_str) |s_str| {
                            if (!std.mem.eql(u8, s_str, plan.struct_expectation.string_alias.?)) {
                                return .{ .domain_rejection = error.TraceDiverged };
                            }
                            verified_count += 1;
                        } else {
                            return .{ .domain_rejection = error.TraceDiverged };
                        }
                    } else {
                        if (!deepEql(sf_type, @field(cur_st, sf_name), @field(plan.struct_expectation.values, sf_name))) {
                            return .{ .domain_rejection = error.TraceDiverged };
                        }
                        verified_count += 1;
                    }
                }
            }

            if (verified_count > 0) {
                stats.states_verified += 1;
            }
        } else {
            if (plan.expected_scalar_state) |exp_st| {
                switch (@typeInfo(ProjType)) {
                    .@"enum" => {
                        if (!std.mem.eql(u8, @tagName(cur_st), exp_st)) {
                            return .{ .domain_rejection = error.TraceDiverged };
                        }
                        stats.states_verified += 1;
                    },
                    .pointer => |p| switch (p.size) {
                        .slice => if (p.child == u8) {
                            if (!std.mem.eql(u8, cur_st, exp_st)) {
                                return .{ .domain_rejection = error.TraceDiverged };
                            }
                            stats.states_verified += 1;
                        } else @compileError("project() pointer must be []const u8"),
                        .one => switch (@typeInfo(p.child)) {
                            .array => |arr| if (arr.child == u8) {
                                if (!std.mem.eql(u8, cur_st[0..arr.len], exp_st)) {
                                    return .{ .domain_rejection = error.TraceDiverged };
                                }
                                stats.states_verified += 1;
                            } else @compileError("project() array pointer must be string"),
                            else => @compileError("project() must return enum, string slice, or struct"),
                        },
                        else => @compileError("project() pointer size unsupported"),
                    },
                    else => @compileError("project() must return enum, string slice, or struct"),
                }
            }
        }
    }

    stats.steps += 1;
    return .success;
}

/// Replay a JSON action trace or ITF (Informal Trace Format) execution against a context.
///
/// Supported trace formats:
/// - Standard Apalache ITF (ADR-015): `{"states": [{"state": "idle", "count": 0}, ...]}`
///   (Apalache standard state-only trace format; transition actions between adjacent states
///   are inferred using `ctx.enabled()` and `ctx.project()`).
/// - Action-annotated ITF: `{"states": [{"action": "a", "state": "idle"}, ...]}` (or with `actionTaken` / `mbt::actionTaken`)
/// - Action string array: `["a", "b"]`
/// - Action object array: `[{"action": "a", "state": "idle"}]`
/// - Tagged union actions with payload: `[{"action": "push", "payload": 10}]`
/// - Quint MBT nondeterministic pick format: `[{"action": "push", "mbt::nondetPicks": 10}]`
/// - Structured object with `"trace"` or `"events"` array
///
/// Guard, projection, and rejection checks:
/// - If `ctx` implements `enabled() []const Act`: ensures each action is enabled before step,
///   returning `error.ActionNotEnabled` on illegal transitions.
/// - If `ctx` implements `project() ...`: verifies expected state enum, string, or multi-variable
///   struct against the trace, returning `error.TraceDiverged` on discrepancy.
/// - If an action is missing at step > 0 and cannot be inferred from adjacent states, returns `error.ActionMissing`.
/// - If `options.expect_rejection` is configured: verifies that a counterexample is rejected at
///   the exact specified step with the exact expected domain error code (e.g., `ActionNotEnabled`,
///   `TraceDiverged`, or user contract errors). Non-contract parser/setup errors are strictly disallowed.
fn isDisallowedRejectionError(err: anyerror) bool {
    switch (err) {
        error.InvalidTraceFormat,
        error.UnknownAction,
        error.ActionMissing,
        error.ActionPayloadMissing,
        error.ActionPayloadUnsupported,
        error.ProjectionFieldMissing,
        error.ProjectionUnavailable,
        error.OutOfMemory,
        error.NestingTooDeep,
        error.UnexpectedToken,
        error.InvalidCharacter,
        error.UnknownField,
        error.DuplicateField,
        error.MissingField,
        error.LengthMismatch,
        error.InvalidEnumTag,
        error.TraceVariablesUnverified,
        => return true,
        else => return false,
    }
}

pub fn replayJsonTraceWithOptions(
    comptime Act: type,
    ctx: anytype,
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
    pic: ?*picture.Picture,
    options: ReplayOptions,
) !ReplayStats {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var stats: ReplayStats = .{};

    const CtxType = Unwrap(@TypeOf(ctx));
    const has_prepare = @hasDecl(CtxType, "prepare");
    const has_release = @hasDecl(CtxType, "release");
    const has_project = @hasDecl(CtxType, "project");
    const ProjType = if (has_project) @TypeOf(ctx.project()) else void;

    const trace_info = getTraceInfo(parsed.value) orelse return error.InvalidTraceFormat;
    const items = trace_info.items;
    if (items.len == 0) return error.InvalidTraceFormat;

    if (has_prepare) try ctx.prepare();
    defer {
        if (has_release) ctx.release();
    }

    if (options.expect_rejection) |exp| {
        if (exp.at_step >= items.len) return error.RejectionStepOutOfBounds;
        if (isDisallowedRejectionError(exp.err)) {
            return error.InvalidExpectedRejection;
        }
    }

    for (items, 0..) |item, step_index| {
        const plan = try ingestStepPlan(Act, ProjType, ctx, item, step_index, trace_info, options, arena_allocator);
        const outcome = executeStepPlan(Act, ProjType, ctx, plan, pic, &stats);
        switch (outcome) {
            .success => {
                if (options.expect_rejection) |exp| {
                    if (step_index == exp.at_step) {
                        return error.RejectionExpected;
                    }
                }
            },
            .domain_rejection => |rej_err| {
                if (options.expect_rejection) |exp| {
                    if (step_index == exp.at_step and rej_err == exp.err) {
                        return stats;
                    }
                }
                return rej_err;
            },
        }
    }

    if (options.expect_rejection != null) {
        return error.RejectionExpected;
    }

    if (stats.actions_replayed == 0 and stats.states_verified == 0) {
        return error.InvalidTraceFormat;
    }

    return stats;
}

pub fn replayJsonTrace(
    comptime Act: type,
    ctx: anytype,
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
    pic: ?*picture.Picture,
) !ReplayStats {
    return replayJsonTraceWithOptions(Act, ctx, allocator, json_bytes, pic, .{});
}

const TraceInfo = struct {
    items: []const std.json.Value,
    is_itf: bool,
};

fn getTraceInfo(val: std.json.Value) ?TraceInfo {
    switch (val) {
        .array => |arr| return .{ .items = arr.items, .is_itf = false },
        .object => |obj| {
            if (obj.get("states")) |v| {
                if (v == .array) return .{ .items = v.array.items, .is_itf = true };
            }
            if (obj.get("trace")) |v| {
                if (v == .array) return .{ .items = v.array.items, .is_itf = false };
            }
            if (obj.get("events")) |v| {
                if (v == .array) return .{ .items = v.array.items, .is_itf = false };
            }
            return null;
        },
        else => return null,
    }
}

fn dispatchStep(ctx: anytype, act: anytype, pic: ?*picture.Picture) !void {
    const CtxType = Unwrap(@TypeOf(ctx));
    const step_fn = CtxType.step;
    const fn_info = @typeInfo(@TypeOf(step_fn)).@"fn";
    if (fn_info.param_types.len == 2) {
        try ctx.step(act);
    } else {
        try ctx.step(act, pic);
    }
}

/// Verify that every defined variant of `Act` was exercised in the executed actions.
pub fn verifyCoverage(comptime Act: type, executed: []const Act) error{ActUncovered}!void {
    const names = comptime getFieldNames(Act);
    inline for (names) |f_name| {
        var covered = false;
        for (executed) |item| {
            if (std.mem.eql(u8, @tagName(item), f_name)) {
                covered = true;
                break;
            }
        }
        if (!covered) return error.ActUncovered;
    }
}

/// Minimal lexical scanner for TLA+ specifications.
/// Correctly tokenizes identifiers and punctuation while handling:
/// - Whitespace (spaces, tabs, newlines, carriage returns)
/// - Single-line comments (`\* ... \n`)
/// - Nested multi-line block comments (`(* ... (* ... *) ... *)`)
/// - String literals (`"..."`, including escaped quotes `\"` and backslashes `\\`)
pub const TlaLexer = struct {
    source: []const u8,
    cursor: usize = 0,

    pub const Token = struct {
        tag: Tag,
        slice: []const u8,

        pub const Tag = enum {
            ident,
            comma,
            other,
            eof,
        };
    };

    pub fn init(source: []const u8) TlaLexer {
        return .{ .source = source, .cursor = 0 };
    }

    pub fn next(self: *TlaLexer) Token {
        while (self.cursor < self.source.len) {
            const c = self.source[self.cursor];

            // 1. Whitespace
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.cursor += 1;
                continue;
            }

            // 2. Nested block comments: (* ... *)
            if (self.cursor + 1 < self.source.len and c == '(' and self.source[self.cursor + 1] == '*') {
                self.cursor += 2;
                var depth: usize = 1;
                while (self.cursor < self.source.len and depth > 0) {
                    if (self.cursor + 1 < self.source.len and self.source[self.cursor] == '(' and self.source[self.cursor + 1] == '*') {
                        depth += 1;
                        self.cursor += 2;
                    } else if (self.cursor + 1 < self.source.len and self.source[self.cursor] == '*' and self.source[self.cursor + 1] == ')') {
                        depth -= 1;
                        self.cursor += 2;
                    } else {
                        self.cursor += 1;
                    }
                }
                continue;
            }

            // 3. Single-line comments: \* ... \n
            if (self.cursor + 1 < self.source.len and c == '\\' and self.source[self.cursor + 1] == '*') {
                self.cursor += 2;
                while (self.cursor < self.source.len and self.source[self.cursor] != '\n') {
                    self.cursor += 1;
                }
                continue;
            }

            // 4. String literals: "..."
            if (c == '"') {
                self.cursor += 1;
                while (self.cursor < self.source.len) {
                    if (self.source[self.cursor] == '\\' and self.cursor + 1 < self.source.len) {
                        self.cursor += 2;
                        continue;
                    }
                    if (self.source[self.cursor] == '"') {
                        self.cursor += 1;
                        break;
                    }
                    self.cursor += 1;
                }
                continue;
            }

            // 5. Identifiers: [a-zA-Z_][a-zA-Z0-9_]*
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_') {
                const start = self.cursor;
                while (self.cursor < self.source.len) {
                    const ch = self.source[self.cursor];
                    if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_') {
                        self.cursor += 1;
                    } else {
                        break;
                    }
                }
                return .{ .tag = .ident, .slice = self.source[start..self.cursor] };
            }

            // 6. Comma delimiter
            if (c == ',') {
                self.cursor += 1;
                return .{ .tag = .comma, .slice = self.source[self.cursor - 1 .. self.cursor] };
            }

            // 7. Other tokens (e.g. operators, delimiters)
            self.cursor += 1;
            return .{ .tag = .other, .slice = self.source[self.cursor - 1 .. self.cursor] };
        }

        return .{ .tag = .eof, .slice = self.source[self.cursor..self.cursor] };
    }
};

/// Verifies that a TLA+ specification contains an `EXTENDS` clause referencing `module_name`.
/// Correctly ignores line comments (`\* ...`) and block comments (`(* ... *)`), supports multi-line `EXTENDS`,
/// and strictly terminates scanning at the boundary of the `EXTENDS` comma-separated list before operator declarations.
pub fn checkExtends(spec_content: []const u8, module_name: []const u8) bool {
    var lexer = TlaLexer.init(spec_content);
    while (true) {
        const tok = lexer.next();
        if (tok.tag == .eof) break;
        if (tok.tag == .ident and std.mem.eql(u8, tok.slice, "EXTENDS")) {
            while (true) {
                const mod_tok = lexer.next();
                if (mod_tok.tag != .ident) break;
                if (std.mem.eql(u8, mod_tok.slice, module_name)) return true;
                const sep_tok = lexer.next();
                if (sep_tok.tag != .comma) break;
            }
        }
    }
    return false;
}

/// Validates basic structural syntax of a TLA+ specification without external tools (pure Zig):
/// - Enforces module header `---- MODULE <Name> ----` with a valid identifier.
/// - Enforces module footer `====`.
/// - Checks balanced delimiters: `()`, `[]`, `{}`, `<<>>`.
/// - Checks unclosed string literals and unclosed nested block comments `(* ... *)`.
pub fn validateSpecSyntax(allocator: std.mem.Allocator, spec_content: []const u8) !void {
    // 1. Module header validation
    const header_idx = std.mem.indexOf(u8, spec_content, "MODULE ") orelse return error.MissingModuleHeader;
    var dash_before: usize = 0;
    var i: usize = header_idx;
    while (i > 0) {
        i -= 1;
        const c = spec_content[i];
        if (c == '-') {
            dash_before += 1;
        } else if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            if (dash_before > 0) break;
        } else {
            break;
        }
    }
    if (dash_before < 4) return error.MissingModuleHeader;

    var name_start: usize = header_idx + 7;
    while (name_start < spec_content.len and (spec_content[name_start] == ' ' or spec_content[name_start] == '\t')) {
        name_start += 1;
    }
    var name_end: usize = name_start;
    while (name_end < spec_content.len and spec_content[name_end] != ' ' and spec_content[name_end] != '\t' and spec_content[name_end] != '-' and spec_content[name_end] != '\r' and spec_content[name_end] != '\n') {
        name_end += 1;
    }
    const mod_name = spec_content[name_start..name_end];
    if (mod_name.len == 0 or !isValidTlaIdentifier(mod_name)) return error.InvalidTlaIdentifier;

    var dash_after: usize = 0;
    var j: usize = name_end;
    while (j < spec_content.len and spec_content[j] != '\n') : (j += 1) {
        if (spec_content[j] == '-') dash_after += 1;
    }
    if (dash_after < 4) return error.MissingModuleHeader;

    // 2. Module footer validation
    const footer_idx = std.mem.lastIndexOf(u8, spec_content, "====") orelse return error.MissingModuleFooter;
    if (footer_idx < header_idx) return error.MissingModuleFooter;

    // 3. Balanced delimiter and comment/string scanner
    var stack: std.ArrayList(u8) = .empty;
    defer stack.deinit(allocator);

    var cursor: usize = 0;
    while (cursor < spec_content.len) {
        const c = spec_content[cursor];

        // Block comments: (* ... *)
        if (cursor + 1 < spec_content.len and c == '(' and spec_content[cursor + 1] == '*') {
            cursor += 2;
            var depth: usize = 1;
            while (cursor < spec_content.len and depth > 0) {
                if (cursor + 1 < spec_content.len and spec_content[cursor] == '(' and spec_content[cursor + 1] == '*') {
                    depth += 1;
                    cursor += 2;
                } else if (cursor + 1 < spec_content.len and spec_content[cursor] == '*' and spec_content[cursor + 1] == ')') {
                    depth -= 1;
                    cursor += 2;
                } else {
                    cursor += 1;
                }
            }
            if (depth > 0) return error.UnclosedComment;
            continue;
        }

        // Single-line comments: \* ... \n
        if (cursor + 1 < spec_content.len and c == '\\' and spec_content[cursor + 1] == '*') {
            cursor += 2;
            while (cursor < spec_content.len and spec_content[cursor] != '\n') {
                cursor += 1;
            }
            continue;
        }

        // String literals: "..."
        if (c == '"') {
            cursor += 1;
            var closed = false;
            while (cursor < spec_content.len) {
                if (spec_content[cursor] == '\\' and cursor + 1 < spec_content.len) {
                    cursor += 2;
                    continue;
                }
                if (spec_content[cursor] == '"') {
                    cursor += 1;
                    closed = true;
                    break;
                }
                if (spec_content[cursor] == '\n') {
                    return error.UnclosedStringLiteral;
                }
                cursor += 1;
            }
            if (!closed) return error.UnclosedStringLiteral;
            continue;
        }

        // Sequence / tuple brackets: << and >>
        if (cursor + 1 < spec_content.len and c == '<' and spec_content[cursor + 1] == '<') {
            try stack.append(allocator, '<');
            cursor += 2;
            continue;
        }
        if (cursor + 1 < spec_content.len and c == '>' and spec_content[cursor + 1] == '>') {
            if (stack.items.len == 0) return error.UnexpectedDelimiter;
            const top = stack.pop();
            if (top != '<') return error.UnbalancedDelimiter;
            cursor += 2;
            continue;
        }

        // Delimiters: (, ), [, ], {, }
        switch (c) {
            '(', '[', '{' => {
                try stack.append(allocator, c);
                cursor += 1;
            },
            ')' => {
                if (stack.items.len == 0) return error.UnexpectedDelimiter;
                const top = stack.pop();
                if (top != '(') return error.UnbalancedDelimiter;
                cursor += 1;
            },
            ']' => {
                if (stack.items.len == 0) return error.UnexpectedDelimiter;
                const top = stack.pop();
                if (top != '[') return error.UnbalancedDelimiter;
                cursor += 1;
            },
            '}' => {
                if (stack.items.len == 0) return error.UnexpectedDelimiter;
                const top = stack.pop();
                if (top != '{') return error.UnbalancedDelimiter;
                cursor += 1;
            },
            else => {
                cursor += 1;
            },
        }
    }

    if (stack.items.len > 0) return error.UnbalancedDelimiter;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "formatDeclarations generates valid TLA+ definitions" {
    const Act = enum { propose, commit, abort };
    const State = enum { idle, preparing, committed };
    const Config = struct {
        pub const max_retries: usize = 3;
        pub const enable_fast_path: bool = true;
        pub const min_backoff: i32 = -1;
    };

    const out = try formatDeclarations(std.testing.allocator, "TestModel", Act, State, Config);
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "---- MODULE TestModel ----") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "EXTENDS Integers, Sequences, FiniteSets") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "max_retries == 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "min_backoff == -1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "enable_fast_path == TRUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Actions == {\"propose\", \"commit\", \"abort\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "States == {\"idle\", \"preparing\", \"committed\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "====") != null);
}

test "formatDeclarations escapes quotes, backslashes, and special characters in vocabulary" {
    const Act = union(enum) {
        @"read\"value",
        @"path\\name",
        @"line\nfeed",
    };
    const State = enum {
        @"idle\"quote",
        @"state\\slash",
    };
    const Mode = enum {
        @"fast\"mode",
    };
    const Config = struct {
        pub const mode: Mode = .@"fast\"mode";
    };

    const decls = try formatDeclarations(std.testing.allocator, "escaped_spec", Act, State, Config);
    defer std.testing.allocator.free(decls);

    try std.testing.expect(std.mem.indexOf(u8, decls, "Actions == {\"read\\\"value\", \"path\\\\name\", \"line\\nfeed\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, decls, "States == {\"idle\\\"quote\", \"state\\\\slash\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, decls, "mode == \"fast\\\"mode\"") != null);
}

test "lock normalizes CRLF and checks module name" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const Act = enum { start, stop };
    const State = enum { off, on };
    const Config = struct {
        pub const limit: u32 = 10;
    };

    // Direct CRLF normalization tests
    try std.testing.expect(picture.matchesNormalizingCRLF("a\nb\n", "a\r\nb\r\n"));
    try std.testing.expect(!picture.matchesNormalizingCRLF("ab", "a\rb"));

    const path = ".zig-cache/tmp_tla_lock_test.tla";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const expected = try formatDeclarations(allocator, "tmp_tla_lock_test", Act, State, Config);
    defer allocator.free(expected);

    // 0. InvalidFilePath: path does not end with .tla
    try std.testing.expectError(error.InvalidFilePath, lock(io, allocator, "tmp_tla_lock_test.txt", "tmp_tla_lock_test", Act, State, Config));

    // 1. ModuleNameMismatch: file name is tmp_tla_lock_test.tla but module name is mismatch
    try std.testing.expectError(error.ModuleNameMismatch, lock(io, allocator, path, "mismatch", Act, State, Config));

    // 2. Missing file returns TlaDrift
    try std.testing.expectError(error.TlaDrift, lock(io, allocator, path, "tmp_tla_lock_test", Act, State, Config));

    // 3. Write matching file with CRLF endings into path -> lock passes via normalization
    const crlf_expected = try std.mem.replaceOwned(u8, allocator, expected, "\n", "\r\n");
    defer allocator.free(crlf_expected);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = crlf_expected });
    try lock(io, allocator, path, "tmp_tla_lock_test", Act, State, Config);

    // 4. Mismatched content returns TlaDrift
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "---- MODULE tmp_tla_lock_test ----\n====" });
    try std.testing.expectError(error.TlaDrift, lock(io, allocator, path, "tmp_tla_lock_test", Act, State, Config));
}

test "replayJsonTrace replays string array and verifies enabled guards and states" {
    const Act = enum { a, b };
    const State = enum { s0, s1, s2 };

    const Harness = struct {
        state: State = .s0,
        executed: std.ArrayList(Act) = .empty,

        pub fn enabled(self: *const @This()) []const Act {
            return switch (self.state) {
                .s0 => &.{.a},
                .s1 => &.{.b},
                .s2 => &.{},
            };
        }

        pub fn step(self: *@This(), act: Act) !void {
            switch (act) {
                .a => self.state = .s1,
                .b => self.state = .s2,
            }
            try self.executed.append(std.testing.allocator, act);
        }

        pub fn project(self: *const @This()) State {
            return self.state;
        }
    };

    var h = Harness{};
    defer h.executed.deinit(std.testing.allocator);

    const json =
        \\[
        \\  {"action": "a", "state": "s1"},
        \\  {"action": "b", "state": "s2"}
        \\]
    ;

    const stats = try replayJsonTrace(Act, &h, std.testing.allocator, json, null);
    try std.testing.expectEqual(@as(usize, 2), stats.actions_replayed);
    try std.testing.expectEqual(@as(usize, 2), stats.states_verified);
    try std.testing.expectEqual(State.s2, h.state);

    // Check coverage
    try verifyCoverage(Act, h.executed.items);
}

test "replayJsonTrace detects ActionNotEnabled, TraceDiverged, and InvalidTraceFormat" {
    const Act = enum { a, b };
    const State = enum { s0, s1 };

    const Harness = struct {
        state: State = .s0,
        pub fn enabled(self: *const @This()) []const Act {
            return if (self.state == .s0) &.{.a} else &.{};
        }
        pub fn step(self: *@This(), act: Act) !void {
            if (act == .a) self.state = .s1;
        }
        pub fn project(self: *const @This()) State {
            return self.state;
        }
    };

    // 1. ActionNotEnabled: action 'b' is not enabled at state s0
    var h1 = Harness{};
    const json_illegal = "[{\"action\": \"b\"}]";
    try std.testing.expectError(error.ActionNotEnabled, replayJsonTrace(Act, &h1, std.testing.allocator, json_illegal, null));

    // 2. TraceDiverged: expected state mismatch
    var h2 = Harness{};
    const json_diverged = "[{\"action\": \"a\", \"state\": \"s0\"}]"; // actual after 'a' is s1
    try std.testing.expectError(error.TraceDiverged, replayJsonTrace(Act, &h2, std.testing.allocator, json_diverged, null));

    // 3. InvalidTraceFormat: empty array
    var h3 = Harness{};
    try std.testing.expectError(error.InvalidTraceFormat, replayJsonTrace(Act, &h3, std.testing.allocator, "[]", null));

    // 4. InvalidTraceFormat: typo in action key with no state
    var h4 = Harness{};
    try std.testing.expectError(error.InvalidTraceFormat, replayJsonTrace(Act, &h4, std.testing.allocator, "[{\"acton\": \"a\"}]", null));

    // 5. InvalidTraceFormat: action is not a string
    var h5 = Harness{};
    try std.testing.expectError(error.InvalidTraceFormat, replayJsonTrace(Act, &h5, std.testing.allocator, "[{\"action\": 123}]", null));

    // 6. ProjectionUnavailable: trace specifies state but harness does not implement project()
    const NoProjectHarness = struct {
        pub fn step(_: *@This(), _: Act) !void {}
    };
    var h6 = NoProjectHarness{};
    try std.testing.expectError(error.ProjectionUnavailable, replayJsonTrace(Act, &h6, std.testing.allocator, "[{\"action\": \"a\", \"state\": \"s1\"}]", null));

    // 7. UnknownAction: "init" at step_index > 0
    var h7 = Harness{};
    const json_init_middle = "[{\"action\": \"a\", \"state\": \"s1\"}, {\"action\": \"init\"}]";
    try std.testing.expectError(error.UnknownAction, replayJsonTrace(Act, &h7, std.testing.allocator, json_init_middle, null));

    // 8. InvalidTraceFormat: non-string state
    var h8 = Harness{};
    try std.testing.expectError(error.InvalidTraceFormat, replayJsonTrace(Act, &h8, std.testing.allocator, "[{\"action\": \"a\", \"state\": 123}]", null));

    // 9. InvalidTraceFormat: step > 0 missing action
    var h9 = Harness{};
    try std.testing.expectError(error.InvalidTraceFormat, replayJsonTrace(Act, &h9, std.testing.allocator, "[{\"action\": \"a\"}, {\"state\": \"s1\"}]", null));

    // 10. ActUncovered
    const executed = [_]Act{.a};
    try std.testing.expectError(error.ActUncovered, verifyCoverage(Act, &executed));

    // 11. InvalidTraceFormat: ["init"] or [{"action": "init"}] without state assertion when init is not an action
    var h10 = Harness{};
    try std.testing.expectError(error.InvalidTraceFormat, replayJsonTrace(Act, &h10, std.testing.allocator, "[\"init\"]", null));
    var h11 = Harness{};
    try std.testing.expectError(error.InvalidTraceFormat, replayJsonTrace(Act, &h11, std.testing.allocator, "[{\"action\": \"init\"}]", null));

    // 12. Valid initial state assertion when init is not in Act
    var h12 = Harness{};
    const stats_init = try replayJsonTrace(Act, &h12, std.testing.allocator, "[{\"action\": \"init\", \"state\": \"s0\"}]", null);
    try std.testing.expectEqual(@as(usize, 0), stats_init.actions_replayed);
    try std.testing.expectEqual(@as(usize, 1), stats_init.states_verified);
}

test "replayJsonTrace supports tagged union with slice payload, safe lifetime, and enabled guard" {
    const Act = union(enum) {
        say: []const u8,
        pop,
    };
    const Harness = struct {
        received: []const u8 = "",

        pub fn enabled(self: *const @This()) []const Act {
            _ = self;
            // Test that enabling guard deep-compares slice content instead of pointer addresses
            return &.{
                .{ .say = "hello world" },
                .pop,
            };
        }

        pub fn step(self: *@This(), act: Act) !void {
            switch (act) {
                .say => |msg| {
                    // Assert payload content within step while the session arena is valid
                    try std.testing.expectEqualStrings("hello world", msg);
                    self.received = "received_say";
                },
                .pop => self.received = "popped",
            }
        }
    };

    var h = Harness{};
    const json =
        \\[
        \\  {"action": "say", "payload": "hello world"},
        \\  {"action": "pop"}
        \\]
    ;

    const stats = try replayJsonTrace(Act, &h, std.testing.allocator, json, null);
    try std.testing.expectEqual(@as(usize, 2), stats.actions_replayed);
    try std.testing.expectEqualStrings("popped", h.received);

    // Payload unsupported on enum
    const EnumAct = enum { push, pop };
    const EnumHarness = struct {
        pub fn step(_: *@This(), _: EnumAct) !void {}
    };
    var eh = EnumHarness{};
    try std.testing.expectError(error.ActionPayloadUnsupported, replayJsonTrace(EnumAct, &eh, std.testing.allocator, "[{\"action\": \"push\", \"payload\": 10}]", null));
}

test "replayJsonTrace supports ITF states array format with initial state" {
    const Act = enum { push, pop };
    const State = enum { idle, active };
    const Harness = struct {
        state: State = .idle,
        count: usize = 0,

        pub fn step(self: *@This(), act: Act) !void {
            self.state = .active;
            switch (act) {
                .push => self.count += 1,
                .pop => self.count -= 1,
            }
        }

        pub fn project(self: *const @This()) State {
            return self.state;
        }
    };

    var h = Harness{};
    // ITF states[0] is initial state with "init" action not in Act
    const itf_json =
        \\{
        \\  "#meta": {"format": "ITF"},
        \\  "states": [
        \\    {"#meta": {"index": 0}, "action": "init", "state": "idle"},
        \\    {"#meta": {"index": 1}, "action": "push", "state": "active"},
        \\    {"#meta": {"index": 2}, "action": "push", "state": "active"},
        \\    {"#meta": {"index": 3}, "action": "pop", "state": "active"}
        \\  ]
        \\}
    ;

    const stats = try replayJsonTrace(Act, &h, std.testing.allocator, itf_json, null);
    try std.testing.expectEqual(@as(usize, 3), stats.actions_replayed);
    try std.testing.expectEqual(@as(usize, 4), stats.states_verified);
    try std.testing.expectEqual(@as(usize, 1), h.count);
}

test "replayJsonTrace deepEql supports struct with nested slice payload" {
    const Message = struct {
        to: []const u8,
        code: u32,
    };
    const Act = union(enum) {
        send: Message,
        noop,
    };
    const Harness = struct {
        received_code: u32 = 0,
        pub fn enabled(self: *const @This()) []const Act {
            _ = self;
            return &.{
                .{ .send = .{ .to = "alice", .code = 42 } },
                .noop,
            };
        }
        pub fn step(self: *@This(), act: Act) !void {
            switch (act) {
                .send => |msg| {
                    try std.testing.expectEqualStrings("alice", msg.to);
                    self.received_code = msg.code;
                },
                .noop => {},
            }
        }
    };

    var h = Harness{};
    const json =
        \\[
        \\  {"action": "send", "payload": {"to": "alice", "code": 42}},
        \\  {"action": "noop"}
        \\]
    ;

    const stats = try replayJsonTrace(Act, &h, std.testing.allocator, json, null);
    try std.testing.expectEqual(@as(usize, 2), stats.actions_replayed);
    try std.testing.expectEqual(@as(u32, 42), h.received_code);

    // S1 Counter-example verification: differing payload content must be rejected with ActionNotEnabled
    var h2 = Harness{};
    try std.testing.expectError(error.ActionNotEnabled, replayJsonTrace(Act, &h2, std.testing.allocator, "[{\"action\": \"send\", \"payload\": {\"to\": \"bob\", \"code\": 42}}]", null));
    var h3 = Harness{};
    try std.testing.expectError(error.ActionNotEnabled, replayJsonTrace(Act, &h3, std.testing.allocator, "[{\"action\": \"send\", \"payload\": {\"to\": \"alice\", \"code\": 43}}]", null));
}

test "replayJsonTrace supports Apalache ITF #bigint integer wrappers in payloads" {
    const Act = union(enum) {
        push: u32,
        add: i32,
        send: struct { to: []const u8, code: u32 },
        noop,
    };
    const Harness = struct {
        pushed: u32 = 0,
        added: i32 = 0,
        sent_code: u32 = 0,
        received_send: bool = false,

        pub fn enabled(self: *const @This()) []const Act {
            _ = self;
            return &.{
                .{ .push = 10 },
                .{ .add = -42 },
                .{ .send = .{ .to = "alice", .code = 100 } },
                .noop,
            };
        }

        pub fn step(self: *@This(), act: Act) !void {
            switch (act) {
                .push => |val| self.pushed = val,
                .add => |val| self.added = val,
                .send => |msg| {
                    try std.testing.expectEqualStrings("alice", msg.to);
                    self.sent_code = msg.code;
                    self.received_send = true;
                },
                .noop => {},
            }
        }
    };

    var h = Harness{};
    const json =
        \\[
        \\  {"action": "push", "payload": {"#bigint": "10"}},
        \\  {"action": "add", "payload": {"#bigint": "-42"}},
        \\  {"action": "send", "payload": {"to": "alice", "code": {"#bigint": "100"}}},
        \\  {"action": "noop"}
        \\]
    ;

    const stats = try replayJsonTrace(Act, &h, std.testing.allocator, json, null);
    try std.testing.expectEqual(@as(usize, 4), stats.actions_replayed);
    try std.testing.expectEqual(@as(u32, 10), h.pushed);
    try std.testing.expectEqual(@as(i32, -42), h.added);
    try std.testing.expectEqual(@as(u32, 100), h.sent_code);
    try std.testing.expect(h.received_send);
}

test "tla identifier validation adheres to SANY and TLA+ reserved keywords" {
    try std.testing.expect(isValidTlaIdentifier("valid_name_1"));
    try std.testing.expect(isValidTlaIdentifier("_my_ident"));
    try std.testing.expect(isValidTlaIdentifier("CalendarState"));

    // Case-sensitivity: TLA+ keywords are uppercase; mixed/lowercase words are legal identifiers
    try std.testing.expect(isValidTlaIdentifier("module"));
    try std.testing.expect(isValidTlaIdentifier("State"));
    try std.testing.expect(isValidTlaIdentifier("Proof"));
    try std.testing.expect(isValidTlaIdentifier("Next"));
    try std.testing.expect(isValidTlaIdentifier("Other"));
    try std.testing.expect(isValidTlaIdentifier("With"));

    // Digits at beginning
    try std.testing.expect(!isValidTlaIdentifier("123invalid"));
    // Temporal operator prefixes
    try std.testing.expect(!isValidTlaIdentifier("WF_vars"));
    try std.testing.expect(!isValidTlaIdentifier("SF_vars"));
    // Empty or non-letters
    try std.testing.expect(!isValidTlaIdentifier(""));
    try std.testing.expect(!isValidTlaIdentifier("___"));
    try std.testing.expect(!isValidTlaIdentifier("bad-ident"));
    try std.testing.expect(!isValidTlaIdentifier("bad ident"));
    // TLA+ reserved words (exact case)
    try std.testing.expect(!isValidTlaIdentifier("MODULE"));
    try std.testing.expect(!isValidTlaIdentifier("EXTENDS"));
    try std.testing.expect(!isValidTlaIdentifier("IF"));
    try std.testing.expect(!isValidTlaIdentifier("THEN"));
    try std.testing.expect(!isValidTlaIdentifier("ELSE"));
    try std.testing.expect(!isValidTlaIdentifier("SUBSET"));
    try std.testing.expect(!isValidTlaIdentifier("UNION"));
    try std.testing.expect(!isValidTlaIdentifier("DOMAIN"));
    try std.testing.expect(!isValidTlaIdentifier("BOOLEAN"));
    try std.testing.expect(!isValidTlaIdentifier("STRING"));
}

test "formatDeclarations and lock reject invalid TLA+ module names" {
    const Act = enum { a, b };
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidTlaIdentifier, formatDeclarations(allocator, "bad-module-name", Act, null, null));
    try std.testing.expectError(error.InvalidTlaIdentifier, formatDeclarations(allocator, "MODULE", Act, null, null));
    try std.testing.expectError(error.InvalidTlaIdentifier, formatDeclarations(allocator, "Nat", Act, null, null));
    try std.testing.expectError(error.InvalidTlaIdentifier, formatDeclarations(allocator, "Integers", Act, null, null));
    try std.testing.expectError(error.InvalidTlaIdentifier, formatDeclarations(allocator, "Seq", Act, null, null));
    try std.testing.expectError(error.InvalidTlaIdentifier, formatDeclarations(allocator, "Actions", Act, null, null));
}

test "isTlaPreludeCollision identifies standard prelude operators and generated vocabulary" {
    // Standard module exports
    try std.testing.expect(isTlaPreludeCollision("Nat"));
    try std.testing.expect(isTlaPreludeCollision("Int"));
    try std.testing.expect(isTlaPreludeCollision("Seq"));
    try std.testing.expect(isTlaPreludeCollision("Len"));
    try std.testing.expect(isTlaPreludeCollision("Append"));
    try std.testing.expect(isTlaPreludeCollision("Head"));
    try std.testing.expect(isTlaPreludeCollision("Tail"));
    try std.testing.expect(isTlaPreludeCollision("SubSeq"));
    try std.testing.expect(isTlaPreludeCollision("SelectSeq"));
    try std.testing.expect(isTlaPreludeCollision("IsFiniteSet"));
    try std.testing.expect(isTlaPreludeCollision("Cardinality"));

    // Standard module names
    try std.testing.expect(isTlaPreludeCollision("Integers"));
    try std.testing.expect(isTlaPreludeCollision("Sequences"));
    try std.testing.expect(isTlaPreludeCollision("FiniteSets"));
    try std.testing.expect(isTlaPreludeCollision("Naturals"));

    // Generated vocabulary
    try std.testing.expect(isTlaPreludeCollision("Actions"));
    try std.testing.expect(isTlaPreludeCollision("States"));
    try std.testing.expect(isTlaPreludeCollision("Init"));
    try std.testing.expect(isTlaPreludeCollision("Next"));

    // Non-colliding user names
    try std.testing.expect(!isTlaPreludeCollision("timeout_ms"));
    try std.testing.expect(!isTlaPreludeCollision("MaxRetries"));
    try std.testing.expect(!isTlaPreludeCollision("nat"));
    try std.testing.expect(!isTlaPreludeCollision("seq"));
}

test "decodeItfValue decodes #map and strictly validates wrappers" {
    const allocator = std.testing.allocator;

    // 1. #map decoding to object
    const map_json =
        \\{"#map": [["a", {"#bigint": "1"}], ["b", {"#bigint": "2"}]]}
    ;
    var parsed_map = try std.json.parseFromSlice(std.json.Value, allocator, map_json, .{});
    defer parsed_map.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const decoded_map = try decodeItfValue(arena.allocator(), parsed_map.value);
    try std.testing.expect(decoded_map == .object);
    try std.testing.expectEqual(@as(i64, 1), decoded_map.object.get("a").?.integer);
    try std.testing.expectEqual(@as(i64, 2), decoded_map.object.get("b").?.integer);

    // 2. Malformed #bigint returns InvalidTraceFormat
    var bad_bigint = try std.json.parseFromSlice(std.json.Value, allocator, "{\"#bigint\": 123}", .{});
    defer bad_bigint.deinit();
    try std.testing.expectError(error.InvalidTraceFormat, decodeItfValue(arena.allocator(), bad_bigint.value));

    var nonnum_bigint = try std.json.parseFromSlice(std.json.Value, allocator, "{\"#bigint\": \"abc\"}", .{});
    defer nonnum_bigint.deinit();
    try std.testing.expectError(error.InvalidTraceFormat, decodeItfValue(arena.allocator(), nonnum_bigint.value));

    // 3. Extraneous keys in wrappers are rejected
    var extra_bigint = try std.json.parseFromSlice(std.json.Value, allocator, "{\"#bigint\": \"1\", \"junk\": 2}", .{});
    defer extra_bigint.deinit();
    try std.testing.expectError(error.InvalidTraceFormat, decodeItfValue(arena.allocator(), extra_bigint.value));

    // 4. Malformed #map elements or duplicate keys are rejected
    var malformed_map = try std.json.parseFromSlice(std.json.Value, allocator, "{\"#map\": [[{\"#bigint\":\"1\"}, 2], 5]}", .{});
    defer malformed_map.deinit();
    try std.testing.expectError(error.InvalidTraceFormat, decodeItfValue(arena.allocator(), malformed_map.value));

    var dup_map = try std.json.parseFromSlice(std.json.Value, allocator, "{\"#map\": [[\"k\", 1], [\"k\", 2]]}", .{});
    defer dup_map.deinit();
    try std.testing.expectError(error.InvalidTraceFormat, decodeItfValue(arena.allocator(), dup_map.value));
}

test "parseActFromValue handles Apalache variants without corrupting normal structs" {
    const OptionUnion = union(enum) {
        None: void,
        Some: u32,
    };
    const Act = union(enum) {
        opt: OptionUnion,
        tagged_struct: struct { tag: []const u8, value: u32 },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 1. Apalache void variant {"tag": "None", "value": {"#tup": []}}
    var void_var_val = try std.json.parseFromSlice(std.json.Value, alloc, "{\"tag\": \"None\", \"value\": {\"#tup\": []}}", .{});
    defer void_var_val.deinit();
    const act_void = (try parseActFromValue(Act, alloc, "opt", void_var_val.value)).?;
    try std.testing.expectEqual(OptionUnion.None, act_void.opt);

    // 2. Apalache value variant {"tag": "Some", "value": {"#bigint": "42"}}
    var some_var_val = try std.json.parseFromSlice(std.json.Value, alloc, "{\"tag\": \"Some\", \"value\": {\"#bigint\": \"42\"}}", .{});
    defer some_var_val.deinit();
    const act_some = (try parseActFromValue(Act, alloc, "opt", some_var_val.value)).?;
    try std.testing.expectEqual(@as(u32, 42), act_some.opt.Some);

    // 3. Normal struct with tag and value fields is preserved
    var struct_val = try std.json.parseFromSlice(std.json.Value, alloc, "{\"tag\": \"normal_tag\", \"value\": 100}", .{});
    defer struct_val.deinit();
    const act_struct = (try parseActFromValue(Act, alloc, "tagged_struct", struct_val.value)).?;
    try std.testing.expectEqualStrings("normal_tag", act_struct.tagged_struct.tag);
    try std.testing.expectEqual(@as(u32, 100), act_struct.tagged_struct.value);
}

test "replayJsonTrace dispatches init on plain JSON object traces but skips on ITF format" {
    const Act = enum { init, go };
    const Harness = struct {
        inited: bool = false,
        went: bool = false,

        pub fn step(self: *@This(), act: Act) !void {
            switch (act) {
                .init => self.inited = true,
                .go => self.went = true,
            }
        }
    };

    // 1. Plain JSON array of objects: step 0 init MUST be dispatched
    var h1 = Harness{};
    const plain_json = "[{\"action\": \"init\"}, {\"action\": \"go\"}]";
    const stats1 = try replayJsonTrace(Act, &h1, std.testing.allocator, plain_json, null);
    try std.testing.expectEqual(@as(usize, 2), stats1.actions_replayed);
    try std.testing.expect(h1.inited);
    try std.testing.expect(h1.went);

    // 2. Apalache ITF format (states array): step 0 init is the initial predicate
    const State = enum { s0, s1 };
    const ItfHarness = struct {
        state: State = .s0,
        inited: bool = false,

        pub fn step(self: *@This(), act: Act) !void {
            switch (act) {
                .init => self.inited = true,
                .go => self.state = .s1,
            }
        }
        pub fn project(self: *const @This()) State {
            return self.state;
        }
    };
    var h2 = ItfHarness{};
    const itf_json = "{\"states\": [{\"action\": \"init\", \"state\": \"s0\"}, {\"action\": \"go\", \"state\": \"s1\"}]}";
    const stats2 = try replayJsonTrace(Act, &h2, std.testing.allocator, itf_json, null);
    try std.testing.expectEqual(@as(usize, 1), stats2.actions_replayed);
    try std.testing.expectEqual(@as(usize, 2), stats2.states_verified);
    try std.testing.expect(!h2.inited); // Not dispatched as transition
    try std.testing.expectEqual(State.s1, h2.state);
}

test "deepEql supports opaque and function pointers without compilation errors" {
    const dummy_fn1 = struct {
        fn f() void {}
    }.f;
    const dummy_fn2 = struct {
        fn g() void {}
    }.g;

    try std.testing.expect(deepEql(*const fn () void, &dummy_fn1, &dummy_fn1));
    try std.testing.expect(!deepEql(*const fn () void, &dummy_fn1, &dummy_fn2));

    var x: u32 = 1;
    var y: u32 = 1;
    const op1: *anyopaque = @ptrCast(&x);
    const op2: *anyopaque = @ptrCast(&y);
    try std.testing.expect(deepEql(*anyopaque, op1, op1));
    try std.testing.expect(!deepEql(*anyopaque, op1, op2));
}

test "replayJsonTrace catches conflicting synonym keys in step objects" {
    const Act = enum { noop };
    const Harness = struct {
        pub fn step(_: *@This(), _: Act) !void {}
    };
    var h = Harness{};
    const conflict_action = "[{\"action\": \"noop\", \"actionTaken\": \"other\"}]";
    try std.testing.expectError(error.InvalidTraceFormat, replayJsonTrace(Act, &h, std.testing.allocator, conflict_action, null));

    const conflict_state = "[{\"action\": \"noop\", \"state\": \"s1\", \"after\": \"s2\"}]";
    try std.testing.expectError(error.InvalidTraceFormat, replayJsonTrace(Act, &h, std.testing.allocator, conflict_state, null));
}

test "parseActFromValue adapts nested Apalache variants within structs and slices" {
    const OptionUnion = union(enum) {
        None: void,
        Some: u32,
    };
    const NestedPayload = struct {
        result: OptionUnion,
        items: []const OptionUnion,
    };
    const Act = union(enum) {
        process: NestedPayload,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const nested_json =
        \\{
        \\  "result": {"tag": "Some", "value": {"#bigint": "42"}},
        \\  "items": [
        \\    {"tag": "Some", "value": {"#bigint": "100"}},
        \\    {"tag": "None", "value": {"#tup": []}}
        \\  ]
        \\}
    ;
    var parsed_nested = try std.json.parseFromSlice(std.json.Value, alloc, nested_json, .{});
    defer parsed_nested.deinit();

    const act = (try parseActFromValue(Act, alloc, "process", parsed_nested.value)).?;
    try std.testing.expectEqual(@as(u32, 42), act.process.result.Some);
    try std.testing.expectEqual(@as(usize, 2), act.process.items.len);
    try std.testing.expectEqual(@as(u32, 100), act.process.items[0].Some);
    try std.testing.expectEqual(OptionUnion.None, act.process.items[1]);
}

test "replayJsonTrace supports Quint mbt::nondetPicks and multi-variable state projection" {
    const Act = union(enum) {
        push: u32,
        pop,
    };
    const FullState = struct {
        state: enum { empty, filled },
        count: u32,
    };
    const Harness = struct {
        st: FullState = .{ .state = .empty, .count = 0 },

        pub fn step(self: *@This(), act: Act) !void {
            switch (act) {
                .push => |val| {
                    self.st.count += val;
                    self.st.state = .filled;
                },
                .pop => {
                    self.st.count = 0;
                    self.st.state = .empty;
                },
            }
        }

        pub fn project(self: *const @This()) FullState {
            return self.st;
        }
    };

    var h = Harness{};
    const mbt_trace =
        \\[
        \\  {"action": "push", "mbt::nondetPicks": 5, "state": "filled", "count": 5},
        \\  {"action": "pop", "state": "empty", "count": 0}
        \\]
    ;
    const stats = try replayJsonTrace(Act, &h, std.testing.allocator, mbt_trace, null);
    try std.testing.expectEqual(@as(usize, 2), stats.actions_replayed);
    try std.testing.expectEqual(@as(usize, 2), stats.states_verified);
    try std.testing.expectEqual(@as(u32, 0), h.st.count);
    try std.testing.expectEqual(FullState{ .state = .empty, .count = 0 }, h.st);
}

test "replayJsonTraceWithOptions verifies counterexample expected rejection" {
    const Act = enum { inc, reset };
    const Harness = struct {
        val: u32 = 0,
        pub fn enabled(self: *const @This()) []const Act {
            if (self.val == 0) return &.{.inc};
            return &.{ .inc, .reset };
        }
        pub fn step(self: *@This(), act: Act) !void {
            switch (act) {
                .inc => self.val += 1,
                .reset => self.val = 0,
            }
        }
    };

    var h = Harness{};
    // Step 0 does illegal "reset" when val == 0
    const bad_trace = "[{\"action\": \"reset\"}]";

    // 1. Without expect_rejection, returns ActionNotEnabled
    try std.testing.expectError(error.ActionNotEnabled, replayJsonTrace(Act, &h, std.testing.allocator, bad_trace, null));

    // 2. With expect_rejection at step 0, succeeds and verifies rejection
    const stats = try replayJsonTraceWithOptions(Act, &h, std.testing.allocator, bad_trace, null, .{
        .expect_rejection = .{ .at_step = 0, .err = error.ActionNotEnabled },
    });
    try std.testing.expectEqual(@as(usize, 0), stats.actions_replayed);

    // 3. If trace unexpectedly succeeds, returns RejectionExpected
    const ok_trace = "[{\"action\": \"inc\"}]";
    try std.testing.expectError(error.RejectionExpected, replayJsonTraceWithOptions(Act, &h, std.testing.allocator, ok_trace, null, .{
        .expect_rejection = .{ .at_step = 0, .err = error.ActionNotEnabled },
    }));
}

test "checkExtends detects module extension in specification" {
    const spec =
        \\---- MODULE MySpec ----
        \\EXTENDS Integers, Sequences, MyDecls
        \\====
    ;
    try std.testing.expect(checkExtends(spec, "MyDecls"));
    try std.testing.expect(checkExtends(spec, "Integers"));
    try std.testing.expect(!checkExtends(spec, "NonExistent"));

    // Multi-line and comment handling
    const complex_spec =
        \\---- MODULE ComplexSpec ----
        \\(* Block comment mentions EXTENDS FakeModule *)
        \\EXTENDS Integers,
        \\        \* Line comment mentions Fake2
        \\        Sequences,
        \\        CalendarDecls
        \\VARIABLES x, y
        \\====
    ;
    try std.testing.expect(checkExtends(complex_spec, "CalendarDecls"));
    try std.testing.expect(checkExtends(complex_spec, "Sequences"));
    try std.testing.expect(!checkExtends(complex_spec, "FakeModule"));
    try std.testing.expect(!checkExtends(complex_spec, "Fake2"));

    // Operator defined after EXTENDS without comma must not match as extended module
    const op_spec =
        \\---- MODULE OpSpec ----
        \\EXTENDS Integers
        \\Foo == TRUE
        \\Bar(x) == x + 1
        \\====
    ;
    try std.testing.expect(checkExtends(op_spec, "Integers"));
    try std.testing.expect(!checkExtends(op_spec, "Foo"));
    try std.testing.expect(!checkExtends(op_spec, "Bar"));

    // String literals containing EXTENDS or module names must be ignored
    const str_spec =
        \\---- MODULE StrSpec ----
        \\Example == "EXTENDS FakeModule"
        \\Other == "Some string with \"EXTENDS Fake2\" inside"
        \\====
    ;
    try std.testing.expect(!checkExtends(str_spec, "FakeModule"));
    try std.testing.expect(!checkExtends(str_spec, "Fake2"));

    // Nested block comments inside EXTENDS clause
    const nested_comment_spec =
        \\EXTENDS ModA, (* outer (* inner *) still outer *) ModB
    ;
    try std.testing.expect(checkExtends(nested_comment_spec, "ModA"));
    try std.testing.expect(checkExtends(nested_comment_spec, "ModB"));
}

test "TlaLexer tokenizes identifiers, commas, and handles nested comments and strings" {
    const src =
        \\EXTENDS A, (* nested (* level 2 *) comment *) B
        \\Lit == "string with \"escaped\" and (* not a comment *)"
        \\(* comment with "quotes" inside *)
        \\Final == 42
    ;
    var lexer = TlaLexer.init(src);

    const t1 = lexer.next();
    try std.testing.expectEqual(TlaLexer.Token.Tag.ident, t1.tag);
    try std.testing.expectEqualStrings("EXTENDS", t1.slice);

    const t2 = lexer.next();
    try std.testing.expectEqual(TlaLexer.Token.Tag.ident, t2.tag);
    try std.testing.expectEqualStrings("A", t2.slice);

    const t3 = lexer.next();
    try std.testing.expectEqual(TlaLexer.Token.Tag.comma, t3.tag);

    const t4 = lexer.next();
    try std.testing.expectEqual(TlaLexer.Token.Tag.ident, t4.tag);
    try std.testing.expectEqualStrings("B", t4.slice);

    const t5 = lexer.next();
    try std.testing.expectEqual(TlaLexer.Token.Tag.ident, t5.tag);
    try std.testing.expectEqualStrings("Lit", t5.slice);

    const t6 = lexer.next();
    try std.testing.expectEqual(TlaLexer.Token.Tag.other, t6.tag); // '='
    const t7 = lexer.next();
    try std.testing.expectEqual(TlaLexer.Token.Tag.other, t7.tag); // '='

    const t8 = lexer.next();
    try std.testing.expectEqual(TlaLexer.Token.Tag.ident, t8.tag);
    try std.testing.expectEqualStrings("Final", t8.slice);

    const t9 = lexer.next();
    try std.testing.expectEqual(TlaLexer.Token.Tag.other, t9.tag); // '='
    const t10 = lexer.next();
    try std.testing.expectEqual(TlaLexer.Token.Tag.other, t10.tag); // '='

    const t11 = lexer.next();
    try std.testing.expectEqual(TlaLexer.Token.Tag.other, t11.tag); // '4'
    const t12 = lexer.next();
    try std.testing.expectEqual(TlaLexer.Token.Tag.other, t12.tag); // '2'

    const t13 = lexer.next();
    try std.testing.expectEqual(TlaLexer.Token.Tag.eof, t13.tag);
}

test "jsonValueEql correctly compares nested objects and arrays" {
    const allocator = std.testing.allocator;
    const json1 = "{\"a\": [1, {\"b\": \"hello\"}], \"c\": true}";
    const json2 = "{\"a\": [1, {\"b\": \"hello\"}], \"c\": true}";
    const json3 = "{\"a\": [1, {\"b\": \"world\"}], \"c\": true}";

    var p1 = try std.json.parseFromSlice(std.json.Value, allocator, json1, .{});
    defer p1.deinit();
    var p2 = try std.json.parseFromSlice(std.json.Value, allocator, json2, .{});
    defer p2.deinit();
    var p3 = try std.json.parseFromSlice(std.json.Value, allocator, json3, .{});
    defer p3.deinit();

    try std.testing.expect(jsonValueEql(p1.value, p2.value));
    try std.testing.expect(!jsonValueEql(p1.value, p3.value));
}

test "struct state projection catches missing fields and unhandled state labels" {
    const Act = enum { a };
    const Harness = struct {
        count: u32 = 1,
        pub fn step(_: *@This(), _: Act) !void {}
        pub fn project(self: *const @This()) struct { count: u32 } {
            return .{ .count = self.count };
        }
    };

    var h = Harness{};

    // 1. Trace has unhandled "state": "WRONG" while struct only handles "count" -> ProjectionUnavailable
    const trace_wrong_label = "[{\"action\": \"a\", \"count\": 1, \"state\": \"WRONG\"}]";
    try std.testing.expectError(error.ProjectionUnavailable, replayJsonTrace(Act, &h, std.testing.allocator, trace_wrong_label, null));

    // 2. Struct has field "count", but trace step lacks "count" -> ProjectionFieldMissing
    const trace_missing_field = "[{\"action\": \"a\"}]";
    try std.testing.expectError(error.ProjectionFieldMissing, replayJsonTrace(Act, &h, std.testing.allocator, trace_missing_field, null));

    // 3. Trace provides "count": 1 -> succeeds with 1 verified state
    const trace_ok = "[{\"action\": \"a\", \"count\": 1}]";
    const stats = try replayJsonTrace(Act, &h, std.testing.allocator, trace_ok, null);
    try std.testing.expectEqual(@as(usize, 1), stats.states_verified);
}

test "adaptVariantForType maps Option variants to Zig optional and empty map to empty slice" {
    const Payload = struct {
        opt_val: ?u32,
        opt_none: ?u32,
        items: []const u32,
    };
    const Act = union(enum) {
        test_act: Payload,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const json =
        \\{
        \\  "opt_val": {"tag": "Some", "value": {"#bigint": "42"}},
        \\  "opt_none": {"tag": "None", "value": {"#tup": []}},
        \\  "items": {"#map": []}
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    const act = (try parseActFromValue(Act, alloc, "test_act", parsed.value)).?;
    try std.testing.expectEqual(@as(?u32, 42), act.test_act.opt_val);
    try std.testing.expectEqual(@as(?u32, null), act.test_act.opt_none);
    try std.testing.expectEqual(@as(usize, 0), act.test_act.items.len);

    // Ordinary unwrapped JSON object {} for a slice is strictly rejected
    const bad_json =
        \\{
        \\  "opt_val": null,
        \\  "opt_none": null,
        \\  "items": {}
        \\}
    ;
    var bad_parsed = try std.json.parseFromSlice(std.json.Value, alloc, bad_json, .{});
    defer bad_parsed.deinit();
    try std.testing.expectError(error.ActionPayloadUnsupported, parseActFromValue(Act, alloc, "test_act", bad_parsed.value));
}

test "replayJsonTraceWithOptions validates rejection step bounds and error whitelist" {
    const Act = enum { a };
    const Harness = struct {
        pub fn step(_: *@This(), _: Act) !void {}
    };
    var h = Harness{};
    const trace = "[{\"action\": \"a\"}]";

    // 1. Step out of bounds
    try std.testing.expectError(error.RejectionStepOutOfBounds, replayJsonTraceWithOptions(Act, &h, std.testing.allocator, trace, null, .{
        .expect_rejection = .{ .at_step = 5, .err = error.ActionNotEnabled },
    }));

    // 2. Disallowed non-contract errors (trace malformation / payload / projection schema setup errors)
    try std.testing.expectError(error.InvalidExpectedRejection, replayJsonTraceWithOptions(Act, &h, std.testing.allocator, trace, null, .{
        .expect_rejection = .{ .at_step = 0, .err = error.InvalidTraceFormat },
    }));
    try std.testing.expectError(error.InvalidExpectedRejection, replayJsonTraceWithOptions(Act, &h, std.testing.allocator, trace, null, .{
        .expect_rejection = .{ .at_step = 0, .err = error.UnknownAction },
    }));
    try std.testing.expectError(error.InvalidExpectedRejection, replayJsonTraceWithOptions(Act, &h, std.testing.allocator, trace, null, .{
        .expect_rejection = .{ .at_step = 0, .err = error.ActionPayloadMissing },
    }));
    try std.testing.expectError(error.InvalidExpectedRejection, replayJsonTraceWithOptions(Act, &h, std.testing.allocator, trace, null, .{
        .expect_rejection = .{ .at_step = 0, .err = error.ActionPayloadUnsupported },
    }));
    try std.testing.expectError(error.InvalidExpectedRejection, replayJsonTraceWithOptions(Act, &h, std.testing.allocator, trace, null, .{
        .expect_rejection = .{ .at_step = 0, .err = error.ProjectionFieldMissing },
    }));
    try std.testing.expectError(error.InvalidExpectedRejection, replayJsonTraceWithOptions(Act, &h, std.testing.allocator, trace, null, .{
        .expect_rejection = .{ .at_step = 0, .err = error.ProjectionUnavailable },
    }));
    try std.testing.expectError(error.InvalidExpectedRejection, replayJsonTraceWithOptions(Act, &h, std.testing.allocator, trace, null, .{
        .expect_rejection = .{ .at_step = 0, .err = error.ActionMissing },
    }));
}

test "enum action accepts empty object payload without error" {
    const Act = enum { noop };
    const Harness = struct {
        pub fn step(_: *@This(), _: Act) !void {}
    };
    var h = Harness{};
    const trace = "[{\"action\": \"noop\", \"payload\": {}}]";
    const stats = try replayJsonTrace(Act, &h, std.testing.allocator, trace, null);
    try std.testing.expectEqual(@as(usize, 1), stats.actions_replayed);
}

test "replayJsonTrace accepts initial step assertions against struct projection fields" {
    const Act = enum { inc };
    const CounterHarness = struct {
        count: u32 = 0,
        pub fn step(self: *@This(), act: Act) !void {
            switch (act) {
                .inc => self.count += 1,
            }
        }
        pub fn project(self: *const @This()) struct { count: u32 } {
            return .{ .count = self.count };
        }
    };

    var h = CounterHarness{};

    // 1. Apalache ITF format with step 0 pure initial state assertion against struct field
    const itf_trace =
        \\{
        \\  "states": [
        \\    {"count": 0},
        \\    {"action": "inc", "count": 1}
        \\  ]
        \\}
    ;
    h.count = 0;
    const stats_itf = try replayJsonTrace(Act, &h, std.testing.allocator, itf_trace, null);
    try std.testing.expectEqual(@as(usize, 1), stats_itf.actions_replayed);
    try std.testing.expectEqual(@as(usize, 2), stats_itf.states_verified);

    // 2. Plain array format with step 0 initial struct assertion
    const plain_trace = "[{\"count\": 0}, {\"action\": \"inc\", \"count\": 1}]";
    h.count = 0;
    const stats_plain = try replayJsonTrace(Act, &h, std.testing.allocator, plain_trace, null);
    try std.testing.expectEqual(@as(usize, 1), stats_plain.actions_replayed);
    try std.testing.expectEqual(@as(usize, 2), stats_plain.states_verified);

    // 3. Plain array with undeclared "init" action containing struct assertion
    const init_trace = "[{\"action\": \"init\", \"count\": 0}, {\"action\": \"inc\", \"count\": 1}]";
    h.count = 0;
    const stats_init = try replayJsonTrace(Act, &h, std.testing.allocator, init_trace, null);
    try std.testing.expectEqual(@as(usize, 1), stats_init.actions_replayed);
    try std.testing.expectEqual(@as(usize, 2), stats_init.states_verified);

    // 4. Initial state projection divergence
    const diverged_trace = "[{\"count\": 99}, {\"action\": \"inc\", \"count\": 1}]";
    h.count = 0;
    try std.testing.expectError(error.TraceDiverged, replayJsonTrace(Act, &h, std.testing.allocator, diverged_trace, null));

    // 5. Undeclared "init" with no state assertion is rejected
    const no_assert_init = "[{\"action\": \"init\"}]";
    h.count = 0;
    try std.testing.expectError(error.InvalidTraceFormat, replayJsonTrace(Act, &h, std.testing.allocator, no_assert_init, null));

    // 6. Step 0 empty object with no assertion is rejected
    const empty_step = "[{}]";
    h.count = 0;
    try std.testing.expectError(error.InvalidTraceFormat, replayJsonTrace(Act, &h, std.testing.allocator, empty_step, null));
}

test "replayJsonTrace strictly validates non-string state assertions across scalar and struct projections" {
    const Act = enum { step };

    // 1. Scalar enum projection rejects non-string state in ITF traces
    const EnumHarness = struct {
        st: enum { a, b } = .a,
        pub fn step(_: *@This(), _: Act) !void {}
        pub fn project(self: *const @This()) @TypeOf(self.st) {
            return self.st;
        }
    };
    var enum_h = EnumHarness{};
    const itf_scalar_invalid = "{\"states\": [{\"action\": \"step\", \"state\": 123}]}";
    try std.testing.expectError(error.InvalidTraceFormat, replayJsonTrace(Act, &enum_h, std.testing.allocator, itf_scalar_invalid, null));

    // 2. Struct projection lacking state field rejects non-string state with ProjectionUnavailable
    const StructNoStateHarness = struct {
        count: u32 = 0,
        pub fn step(_: *@This(), _: Act) !void {}
        pub fn project(self: *const @This()) struct { count: u32 } {
            return .{ .count = self.count };
        }
    };
    var no_st_h = StructNoStateHarness{};
    const itf_struct_no_st = "{\"states\": [{\"action\": \"step\", \"count\": 0, \"state\": 123}]}";
    try std.testing.expectError(error.ProjectionUnavailable, replayJsonTrace(Act, &no_st_h, std.testing.allocator, itf_struct_no_st, null));

    // 3. Struct projection with integer state field accepts and verifies non-string state
    const StructWithStateHarness = struct {
        count: u32 = 0,
        state: u32 = 42,
        pub fn step(self: *@This(), _: Act) !void {
            self.state += 1;
        }
        pub fn project(self: *const @This()) struct { count: u32, state: u32 } {
            return .{ .count = self.count, .state = self.state };
        }
    };
    var with_st_h = StructWithStateHarness{};
    const itf_struct_ok = "{\"states\": [{\"action\": \"step\", \"count\": 0, \"state\": 43}]}";
    const stats = try replayJsonTrace(Act, &with_st_h, std.testing.allocator, itf_struct_ok, null);
    try std.testing.expectEqual(@as(usize, 1), stats.actions_replayed);
    try std.testing.expectEqual(@as(usize, 1), stats.states_verified);

    // 4. Struct projection with optional state field maps and verifies non-string `after` alias
    const StructWithOptStateHarness = struct {
        count: u32 = 0,
        state: ?u32 = 42,
        pub fn step(self: *@This(), _: Act) !void {
            self.state = 43;
        }
        pub fn project(self: *const @This()) struct { count: u32, state: ?u32 } {
            return .{ .count = self.count, .state = self.state };
        }
    };
    var with_opt_st_h = StructWithOptStateHarness{};

    // 4a. Divergent non-string `after` alias is caught and rejected with TraceDiverged
    const itf_after_mismatch = "{\"states\": [{\"action\": \"step\", \"count\": 0, \"after\": 999}]}";
    try std.testing.expectError(error.TraceDiverged, replayJsonTrace(Act, &with_opt_st_h, std.testing.allocator, itf_after_mismatch, null));

    // 4b. Matching non-string `after` alias is successfully verified
    with_opt_st_h.state = 42;
    const itf_after_ok = "{\"states\": [{\"action\": \"step\", \"count\": 0, \"after\": 43}]}";
    const stats_after = try replayJsonTrace(Act, &with_opt_st_h, std.testing.allocator, itf_after_ok, null);
    try std.testing.expectEqual(@as(usize, 1), stats_after.actions_replayed);
    try std.testing.expectEqual(@as(usize, 1), stats_after.states_verified);

    // 5. Struct projection with `after` field (no `state` field) accepts and verifies non-string `state` alias
    const StructWithAfterFieldHarness = struct {
        count: u32 = 0,
        after: u32 = 42,
        pub fn step(self: *@This(), _: Act) !void {
            self.after = 43;
        }
        pub fn project(self: *const @This()) struct { count: u32, after: u32 } {
            return .{ .count = self.count, .after = self.after };
        }
    };
    var with_aft_h = StructWithAfterFieldHarness{};

    // 5a. Matching non-string `state` alias verified against struct `after` field
    const itf_state_ok = "{\"states\": [{\"action\": \"step\", \"count\": 0, \"state\": 43}]}";
    const stats_state = try replayJsonTrace(Act, &with_aft_h, std.testing.allocator, itf_state_ok, null);
    try std.testing.expectEqual(@as(usize, 1), stats_state.actions_replayed);
    try std.testing.expectEqual(@as(usize, 1), stats_state.states_verified);

    // 5b. Divergent non-string `state` alias caught with TraceDiverged
    with_aft_h.after = 42;
    const itf_state_mismatch = "{\"states\": [{\"action\": \"step\", \"count\": 0, \"state\": 999}]}";
    try std.testing.expectError(error.TraceDiverged, replayJsonTrace(Act, &with_aft_h, std.testing.allocator, itf_state_mismatch, null));
}

test "replayJsonTrace supports standard Apalache ADR-015 state-only ITF traces without action fields" {
    const Act = enum { inc, dec };
    const State = enum { low, high };
    const Harness = struct {
        state: State = .low,
        count: u32 = 0,

        pub fn clone(self: *const @This()) @This() {
            return self.*;
        }

        pub fn enabled(self: *const @This()) []const Act {
            if (self.count == 0) return &.{.inc};
            if (self.count >= 2) return &.{.dec};
            return &.{ .inc, .dec };
        }

        pub fn step(self: *@This(), act: Act) !void {
            switch (act) {
                .inc => {
                    self.count += 1;
                    if (self.count >= 2) self.state = .high;
                },
                .dec => {
                    self.count -= 1;
                    if (self.count < 2) self.state = .low;
                },
            }
        }

        pub fn project(self: *const @This()) struct { state: State, count: u32 } {
            return .{ .state = self.state, .count = self.count };
        }
    };

    var h = Harness{};
    // Standard Apalache ADR-015 state-only ITF trace: states have NO "action" field!
    const standard_itf_json =
        \\{
        \\  "#meta": {
        \\    "source": "Counter.tla",
        \\    "format": "ITF",
        \\    "version": "1.0"
        \\  },
        \\  "vars": ["state", "count"],
        \\  "states": [
        \\    {"#meta": {"index": 0}, "state": "low", "count": 0},
        \\    {"#meta": {"index": 1}, "state": "low", "count": 1},
        \\    {"#meta": {"index": 2}, "state": "high", "count": 2},
        \\    {"#meta": {"index": 3}, "state": "low", "count": 1}
        \\  ]
        \\}
    ;

    const stats = try replayJsonTrace(Act, &h, std.testing.allocator, standard_itf_json, null);
    try std.testing.expectEqual(@as(usize, 3), stats.actions_replayed);
    try std.testing.expectEqual(@as(usize, 4), stats.states_verified);
    try std.testing.expectEqual(@as(u32, 1), h.count);
    try std.testing.expectEqual(State.low, h.state);

    // If an intermediate state in a standard ITF trace cannot be reached by any enabled transition,
    // replay strictly returns error.ActionMissing instead of silently skipping dispatch.
    var h_unreachable = Harness{};
    const unreachable_itf_json =
        \\{
        \\  "#meta": {"format": "ITF"},
        \\  "states": [
        \\    {"#meta": {"index": 0}, "state": "low", "count": 0},
        \\    {"#meta": {"index": 1}, "state": "high", "count": 99}
        \\  ]
        \\}
    ;
    try std.testing.expectError(error.ActionMissing, replayJsonTrace(Act, &h_unreachable, std.testing.allocator, unreachable_itf_json, null));

    // Harness without an independent clone method strictly refuses inference to protect state behind pointers
    const NoCloneHarness = struct {
        state: State = .low,
        count: u32 = 0,
        pub fn enabled(_: *const @This()) []const Act {
            return &.{.inc};
        }
        pub fn step(self: *@This(), act: Act) !void {
            if (act == .inc) self.count += 1;
        }
        pub fn project(self: *const @This()) struct { state: State, count: u32 } {
            return .{ .state = self.state, .count = self.count };
        }
    };
    var h_no_clone = NoCloneHarness{};
    try std.testing.expectError(error.ActionMissing, replayJsonTrace(Act, &h_no_clone, std.testing.allocator, standard_itf_json, null));
}

test "replayJsonTrace rejects payload overflow at parser boundary while allowing transition overflow in expect_rejection" {
    const Act = union(enum) {
        push: u8,
        pop: void,
    };
    const Harness = struct {
        val: u8 = 0,
        pub fn step(self: *@This(), act: Act) !void {
            switch (act) {
                .push => |v| self.val = v,
                .pop => self.val = 0,
            }
        }
    };
    var h = Harness{};

    // 1. Trace with payload 256 which overflows u8: rejected as ActionPayloadUnsupported at parsing boundary
    const overflow_trace = "[{\"action\": \"push\", \"payload\": {\"#bigint\": \"256\"}}]";
    try std.testing.expectError(error.ActionPayloadUnsupported, replayJsonTrace(Act, &h, std.testing.allocator, overflow_trace, null));

    // 2. Reject parser-originated ActionPayloadUnsupported upfront with error.InvalidExpectedRejection
    try std.testing.expectError(error.InvalidExpectedRejection, replayJsonTraceWithOptions(Act, &h, std.testing.allocator, overflow_trace, null, .{
        .expect_rejection = .{ .at_step = 0, .err = error.ActionPayloadUnsupported },
    }));

    // 3. Reject error.ActionMissing as expected rejection upfront with error.InvalidExpectedRejection
    try std.testing.expectError(error.InvalidExpectedRejection, replayJsonTraceWithOptions(Act, &h, std.testing.allocator, "[{\"action\": \"pop\"}]", null, .{
        .expect_rejection = .{ .at_step = 0, .err = error.ActionMissing },
    }));

    // 4. Trace whose harness step transition returns error.Overflow: allowed and verified as expected rejection!
    const OverflowStepHarness = struct {
        val: u8 = 200,
        pub fn step(self: *@This(), act: Act) !void {
            switch (act) {
                .push => |v| self.val = std.math.add(u8, self.val, v) catch return error.Overflow,
                .pop => self.val = 0,
            }
        }
    };
    var oh = OverflowStepHarness{};
    const step_overflow_trace = "[{\"action\": \"push\", \"payload\": {\"#bigint\": \"100\"}}]";
    const stats_overflow = try replayJsonTraceWithOptions(Act, &oh, std.testing.allocator, step_overflow_trace, null, .{
        .expect_rejection = .{ .at_step = 0, .err = error.Overflow },
    });
    try std.testing.expectEqual(@as(usize, 0), stats_overflow.actions_replayed);

    // 5. Trace asserting an overflowing projection value (e.g. count: 256 for count: u8) is rejected as InvalidTraceFormat
    const ProjOverflowHarness = struct {
        count: u8 = 0,
        pub fn step(self: *@This(), _: Act) !void {
            self.count = 1;
        }
        pub fn project(self: *const @This()) struct { count: u8 } {
            return .{ .count = self.count };
        }
    };
    var proj_h = ProjOverflowHarness{};
    const proj_overflow_trace = "[{\"action\": \"pop\", \"count\": {\"#bigint\": \"256\"}}]";
    try std.testing.expectError(error.InvalidTraceFormat, replayJsonTrace(Act, &proj_h, std.testing.allocator, proj_overflow_trace, null));

    // And cannot be accepted as expected rejection when expecting error.Overflow
    try std.testing.expectError(error.InvalidTraceFormat, replayJsonTraceWithOptions(Act, &proj_h, std.testing.allocator, proj_overflow_trace, null, .{
        .expect_rejection = .{ .at_step = 0, .err = error.Overflow },
    }));

    // 6. Trace asserting an invalid enum tag in projection is rejected as InvalidTraceFormat
    // and cannot be accepted as expected rejection when expecting error.InvalidEnumTag
    const Status = enum { idle, running };
    const ProjEnumHarness = struct {
        status: Status = .idle,
        pub fn step(_: *@This(), _: Act) !void {}
        pub fn project(self: *const @This()) struct { status: Status } {
            return .{ .status = self.status };
        }
    };
    var enum_h = ProjEnumHarness{};
    const proj_invalid_enum_trace = "[{\"action\": \"pop\", \"status\": \"bogus\"}]";
    try std.testing.expectError(error.InvalidTraceFormat, replayJsonTrace(Act, &enum_h, std.testing.allocator, proj_invalid_enum_trace, null));
    try std.testing.expectError(error.InvalidExpectedRejection, replayJsonTraceWithOptions(Act, &enum_h, std.testing.allocator, proj_invalid_enum_trace, null, .{
        .expect_rejection = .{ .at_step = 0, .err = error.InvalidEnumTag },
    }));

    // 7. Unwrapped empty object {} for a slice action payload or projection field is rejected as ActionPayloadUnsupported / InvalidTraceFormat
    const SliceAct = union(enum) {
        push: []const u32,
    };
    const SliceHarness = struct {
        items: []const u32 = &.{},
        pub fn step(self: *@This(), act: SliceAct) !void {
            self.items = act.push;
        }
        pub fn project(self: *const @This()) struct { items: []const u32 } {
            return .{ .items = self.items };
        }
    };
    var slice_h = SliceHarness{};
    // Ordinary {} payload is rejected as ActionPayloadUnsupported
    const bad_slice_payload_trace = "[{\"action\": \"push\", \"payload\": {}, \"items\": []}]";
    try std.testing.expectError(error.ActionPayloadUnsupported, replayJsonTrace(SliceAct, &slice_h, std.testing.allocator, bad_slice_payload_trace, null));

    // ITF {"#map": []} payload is accepted as empty slice (both in action payload and projection assertion)
    const itf_slice_payload_trace = "[{\"action\": \"push\", \"payload\": {\"#map\": []}, \"items\": {\"#map\": []}}]";
    const slice_stats = try replayJsonTrace(SliceAct, &slice_h, std.testing.allocator, itf_slice_payload_trace, null);
    try std.testing.expectEqual(@as(usize, 1), slice_stats.actions_replayed);
    try std.testing.expectEqual(@as(usize, 1), slice_stats.states_verified);
    try std.testing.expectEqual(@as(usize, 0), slice_h.items.len);

    // Ordinary {} in struct projection slice assertion is rejected as InvalidTraceFormat
    const bad_slice_proj_trace = "[{\"action\": \"push\", \"payload\": [], \"items\": {}}]";
    try std.testing.expectError(error.InvalidTraceFormat, replayJsonTrace(SliceAct, &slice_h, std.testing.allocator, bad_slice_proj_trace, null));
}

test "parseAct parses enum and void union variants without allocation" {
    const EnumAct = enum { start, stop };
    try std.testing.expectEqual(EnumAct.start, parseAct(EnumAct, "start").?);
    try std.testing.expectEqual(EnumAct.stop, parseAct(EnumAct, "stop").?);
    try std.testing.expect(parseAct(EnumAct, "unknown") == null);

    const UnionAct = union(enum) {
        tick: void,
        push: u32,
    };
    const act_tick = parseAct(UnionAct, "tick");
    try std.testing.expect(act_tick != null);
    try std.testing.expectEqual(UnionAct{ .tick = {} }, act_tick.?);

    // Non-void payload variant cannot be parsed without payload: returns null
    try std.testing.expect(parseAct(UnionAct, "push") == null);
    try std.testing.expect(parseAct(UnionAct, "unknown") == null);
}

test "replayJsonTraceWithOptions detects unverified trace variables on scalar projections" {
    const Act = enum { step_a };
    const State = enum { idle, active };

    const ScalarHarness = struct {
        state: State = .idle,
        pub fn step(self: *@This(), _: Act) !void {
            self.state = .active;
        }
        pub fn project(self: *const @This()) State {
            return self.state;
        }
    };

    var h = ScalarHarness{};
    // Trace has extra custom variable 'macro_q' that scalar projection does not verify
    const unverified_trace =
        \\{
        \\  "states": [
        \\    {"#meta": {"index": 0}, "action": "init", "state": "idle", "macro_q": 10},
        \\    {"#meta": {"index": 1}, "action": "step_a", "state": "active", "macro_q": 10}
        \\  ]
        \\}
    ;

    // 1. By default, returns error.TraceVariablesUnverified
    try std.testing.expectError(error.TraceVariablesUnverified, replayJsonTrace(Act, &h, std.testing.allocator, unverified_trace, null));

    // 2. Disallowed as expected rejection
    try std.testing.expectError(error.InvalidExpectedRejection, replayJsonTraceWithOptions(Act, &h, std.testing.allocator, unverified_trace, null, .{
        .expect_rejection = .{ .at_step = 0, .err = error.TraceVariablesUnverified },
    }));

    // 3. Allowed when allow_unverified_variables is explicitly true
    var h2 = ScalarHarness{};
    const stats = try replayJsonTraceWithOptions(Act, &h2, std.testing.allocator, unverified_trace, null, .{
        .allow_unverified_variables = true,
    });
    try std.testing.expectEqual(@as(usize, 1), stats.actions_replayed);
    try std.testing.expectEqual(@as(usize, 2), stats.states_verified);
}

test "lockWithOptions supports sectional declaration locking and in-place update" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const Act = enum { ping, pong };
    const State = enum { s0, s1 };

    const full_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path, "SectionalModel.tla" });
    defer alloc.free(full_path);

    // Initial spec on disk with section markers, hand-written variables, init, next, and invariant
    const initial_spec =
        \\---- MODULE SectionalModel ----
        \\EXTENDS Integers, Sequences, FiniteSets
        \\
        \\VARIABLES counter
        \\
        \\\* BEGIN DECLARATIONS
        \\\* Auto-generated by state_tcas.tla. Do not edit manually.
        \\
        \\\* Action Vocabulary
        \\Actions == {"old_act"}
        \\
        \\\* State Vocabulary
        \\States == {"s0", "s1"}
        \\\* END DECLARATIONS
        \\
        \\Init == counter = 0
        \\Next == counter' = counter + 1
        \\Inv == counter >= 0
        \\====
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "SectionalModel.tla", .data = initial_spec });

    // 1. Verification detects drift in sectional declarations
    try std.testing.expectError(error.TlaDrift, lockWithOptions(io, alloc, full_path, "SectionalModel", Act, State, null, .{
        .allow_update = false,
    }));

    // 2. Updating with update flag updates ONLY the declaration section, preserving custom variables & formulas
    const flag_path = ".state_tcas-update-tla";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = flag_path, .data = "update" });
    defer std.Io.Dir.cwd().deleteFile(io, flag_path) catch {};

    try lockWithOptions(io, alloc, full_path, "SectionalModel", Act, State, null, .{
        .allow_update = true,
    });

    // 3. Read updated file: custom formula and header/footer must be intact!
    const updated = try tmp.dir.readFileAlloc(io, "SectionalModel.tla", alloc, .limited(1 << 20));
    defer alloc.free(updated);

    try std.testing.expect(std.mem.indexOf(u8, updated, "---- MODULE SectionalModel ----") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "VARIABLES counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "Actions == {\"ping\", \"pong\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "Init == counter = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "Inv == counter >= 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "====") != null);

    // 4. Verification now passes cleanly
    try lockWithOptions(io, alloc, full_path, "SectionalModel", Act, State, null, .{
        .allow_update = false,
    });

    // 5. Test with standard PlusCal translation markers (\* BEGIN TRANSLATION ... \* END TRANSLATION)
    const translation_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path, "TranslationModel.tla" });
    defer alloc.free(translation_path);

    const translation_spec =
        \\---- MODULE TranslationModel ----
        \\EXTENDS Integers, Sequences, FiniteSets
        \\
        \\VARIABLES val
        \\
        \\\* BEGIN TRANSLATION
        \\\* Auto-generated by state_tcas.tla. Do not edit manually.
        \\
        \\\* Action Vocabulary
        \\Actions == {"ping", "pong"}
        \\
        \\\* State Vocabulary
        \\States == {"s0", "s1"}
        \\
        \\\* END TRANSLATION
        \\
        \\Init == val = 0
        \\Next == val' = val
        \\====
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "TranslationModel.tla", .data = translation_spec });
    try lockWithOptions(io, alloc, translation_path, "TranslationModel", Act, State, null, .{
        .allow_update = false,
    });
}

test "ReplayStats.verifyCoverage verifies action coverage using Picture" {
    const Act = enum { a, b };
    const Harness = struct {
        pub fn step(_: *@This(), act: Act, pic: ?*picture.Picture) !void {
            if (pic) |p| {
                try p.observe(std.testing.allocator, .{
                    .before = "st",
                    .after = "st",
                    .label = @tagName(act),
                    .rejected = false,
                    .mutated = true,
                    .note = "",
                    .keep_unchanged = true,
                });
            }
        }
    };
    var h = Harness{};
    var pic_partial = picture.Picture{};
    defer pic_partial.deinit(std.testing.allocator);

    const partial_trace = "[{\"action\": \"a\"}]";
    const stats_partial = try replayJsonTrace(Act, &h, std.testing.allocator, partial_trace, &pic_partial);
    try std.testing.expectError(error.ActUncovered, stats_partial.verifyCoverage(Act, &pic_partial));

    var pic_full = picture.Picture{};
    defer pic_full.deinit(std.testing.allocator);

    const full_trace = "[{\"action\": \"a\"}, {\"action\": \"b\"}]";
    const stats_full = try replayJsonTrace(Act, &h, std.testing.allocator, full_trace, &pic_full);
    try stats_full.verifyCoverage(Act, &pic_full);
}

test "validateSpecSyntax verifies balanced delimiters, headers, footers, and comments" {
    const alloc = std.testing.allocator;

    // 1. Valid TLA+ spec
    const valid_spec =
        \\---- MODULE MySpec ----
        \\EXTENDS Integers, Sequences
        \\(* Block comment (* nested *) *)
        \\VARIABLES x, y
        \\Init == x = 0 /\ y = <<1, 2>>
        \\Next == x' = (x + 1) /\ y' = Append(y, [a |-> {x}])
        \\====
    ;
    try validateSpecSyntax(alloc, valid_spec);

    // 2. Generated declarations pass validation
    const Act = enum { inc, dec };
    const decls = try formatDeclarations(alloc, "ValidDecls", Act, null, null);
    defer alloc.free(decls);
    try validateSpecSyntax(alloc, decls);

    // 3. Missing header
    try std.testing.expectError(error.MissingModuleHeader, validateSpecSyntax(alloc, "EXTENDS Integers\n===="));

    // 4. Missing footer
    try std.testing.expectError(error.MissingModuleFooter, validateSpecSyntax(alloc, "---- MODULE Foo ----\nEXTENDS Integers"));

    // 5. Unclosed block comment
    const unclosed_comment = "---- MODULE Foo ----\n(* unclosed comment\n====";
    try std.testing.expectError(error.UnclosedComment, validateSpecSyntax(alloc, unclosed_comment));

    // 6. Unclosed string literal
    const unclosed_str = "---- MODULE Foo ----\nMsg == \"unclosed\n====\n";
    try std.testing.expectError(error.UnclosedStringLiteral, validateSpecSyntax(alloc, unclosed_str));

    // 7. Unbalanced parentheses
    const unbalanced_paren = "---- MODULE Foo ----\nOp == (x + 1\n====\n";
    try std.testing.expectError(error.UnbalancedDelimiter, validateSpecSyntax(alloc, unbalanced_paren));

    // 8. Unbalanced brackets
    const unbalanced_bracket = "---- MODULE Foo ----\nOp == [x |-> 1\n====\n";
    try std.testing.expectError(error.UnbalancedDelimiter, validateSpecSyntax(alloc, unbalanced_bracket));

    // 9. Unbalanced curly braces
    const unbalanced_brace = "---- MODULE Foo ----\nOp == {1, 2\n====\n";
    try std.testing.expectError(error.UnbalancedDelimiter, validateSpecSyntax(alloc, unbalanced_brace));

    // 10. Unbalanced tuple brackets << >>
    const unbalanced_tuple = "---- MODULE Foo ----\nOp == <<1, 2\n====\n";
    try std.testing.expectError(error.UnbalancedDelimiter, validateSpecSyntax(alloc, unbalanced_tuple));

    // 11. Unexpected closing delimiter
    const unexpected_close = "---- MODULE Foo ----\nOp == x + 1)\n====\n";
    try std.testing.expectError(error.UnexpectedDelimiter, validateSpecSyntax(alloc, unexpected_close));
}

test "Picture.renderItfJson round-trips through replayJsonTrace with full fidelity" {
    const Act = enum { inc, dec };
    const State = enum { zero, one, two };

    const Harness = struct {
        state: State = .zero,
        count: u32 = 0,

        pub fn step(self: *@This(), act: Act, pic: ?*picture.Picture) !void {
            const before_str = @tagName(self.state);
            switch (act) {
                .inc => {
                    self.count += 1;
                    if (self.count == 1) self.state = .one else if (self.count == 2) self.state = .two;
                },
                .dec => {
                    self.count -= 1;
                    if (self.count == 1) self.state = .one else if (self.count == 0) self.state = .zero;
                },
            }
            if (pic) |p| {
                try p.observe(std.testing.allocator, .{
                    .before = before_str,
                    .after = @tagName(self.state),
                    .label = @tagName(act),
                    .rejected = false,
                    .mutated = true,
                    .note = "",
                });
            }
        }

        pub fn project(self: *const @This()) State {
            return self.state;
        }
    };

    // 1. Simulate state exploration recording into picture
    var h = Harness{};
    var pic = picture.Picture{};
    defer pic.deinit(std.testing.allocator);

    try h.step(.inc, &pic);
    try h.step(.inc, &pic);
    try h.step(.dec, &pic);

    // 2. Export exploration steps as Apalache ADR-015 ITF trace
    const itf_trace = try pic.renderItfJson(std.testing.allocator, .{
        .description = "Exploration counterexample",
        .source = "state_tcas explorer",
        .state_var_name = "state",
        .include_actions = true,
    });
    defer std.testing.allocator.free(itf_trace);

    // 3. Replay the exported ITF trace in fresh harness
    var replay_h = Harness{};
    var replay_pic = picture.Picture{};
    defer replay_pic.deinit(std.testing.allocator);

    const stats = try replayJsonTrace(Act, &replay_h, std.testing.allocator, itf_trace, &replay_pic);
    try std.testing.expectEqual(@as(usize, 3), stats.actions_replayed);
    try std.testing.expectEqual(@as(usize, 4), stats.states_verified);
    try std.testing.expectEqual(State.one, replay_h.state);
    try std.testing.expectEqual(@as(u32, 1), replay_h.count);

    // 4. Verify 100% action coverage on the replayed run
    try stats.verifyCoverage(Act, &replay_pic);
}
