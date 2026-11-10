//! Finite exhaustive orders, enabling-set explore, DES-lite calendar,
//! attachable Safety/Liveness monitors, and a Mermaid picture from the same run.
//!
//! Imports only `std` and this package's modules. Drive any Zig SUT from
//! harness closures in your repo. See `README.md` for install and limits.
//!
//! Canonical imports are module-qualified:
//!   const st = @import("state_tcas");
//!   try st.explore.dfs(...);
//!   try st.exhaust.orders(...);
//! Optional flat type aliases: `Picture`, `Role` only.

const picture_mod = @import("picture.zig");
const exhaust_mod = @import("exhaust.zig");
const role_mod = @import("role.zig");
const trace_mod = @import("trace.zig");
const calendar_mod = @import("calendar.zig");
const monitor_mod = @import("monitor.zig");
const explore_mod = @import("explore.zig");

pub const picture = picture_mod;
pub const exhaust = exhaust_mod;
pub const role = role_mod;
pub const trace = trace_mod;
pub const calendar = calendar_mod;
pub const monitor = monitor_mod;
pub const explore = explore_mod;

pub const Picture = picture_mod.Picture;
pub const Role = role_mod.Role;
pub const Monitored = monitor_mod.Monitored;
pub const MonitoredKeyed = monitor_mod.MonitoredKeyed;
pub const KeyedOnly = monitor_mod.KeyedOnly;

test {
    // Imported file tests are part of this package's own test run.
    _ = picture_mod;
    _ = exhaust_mod;
    _ = role_mod;
    _ = trace_mod;
    _ = calendar_mod;
    _ = monitor_mod;
    _ = explore_mod;
    _ = @import("gate_check.zig");
}
