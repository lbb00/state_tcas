//! Roles for harness pictures (Scribble / MPST-style).
//! Enum is only initiator / responder / harness — not a full actor taxonomy.
//! Put `Role.participant()` into `Observation.from` / `.to` for sequence arrows,
//! or pass any custom string (engine / host / timer / …) the same way.
//! `tag()` returns ASCII labels for Trace JSON.
//! Strings you pass as from/to/actor/target become picture-lock bytes.

const std = @import("std");

pub const Role = enum {
    initiator,
    responder,
    harness,

    /// Mermaid participant label used in locks. ASCII; treat as lock surface.
    pub fn participant(self: Role) []const u8 {
        return switch (self) {
            .initiator => "Initiator",
            .responder => "Responder",
            .harness => "Harness",
        };
    }

    /// Optional zh labels for human-facing docs. Prefer not to freeze these
    /// into picture locks unless the golden intentionally uses them.
    pub fn participantZh(self: Role) []const u8 {
        return switch (self) {
            .initiator => "发起端",
            .responder => "应答端",
            .harness => "测试",
        };
    }

    /// Stable ASCII tag for Trace export / docs.
    pub fn tag(self: Role) []const u8 {
        return switch (self) {
            .initiator => "initiator",
            .responder => "responder",
            .harness => "harness",
        };
    }
};

test "role participant and tag are stable" {
    try std.testing.expectEqualStrings("Initiator", Role.initiator.participant());
    try std.testing.expectEqualStrings("Responder", Role.responder.participant());
    try std.testing.expectEqualStrings("Harness", Role.harness.participant());
    try std.testing.expectEqualStrings("发起端", Role.initiator.participantZh());
    try std.testing.expectEqualStrings("应答端", Role.responder.participantZh());
    try std.testing.expectEqualStrings("测试", Role.harness.participantZh());
    try std.testing.expectEqualStrings("initiator", Role.initiator.tag());
}
