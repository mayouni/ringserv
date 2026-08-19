//! topology.zig — `ringserv topology` and `ringserv topology --emit`.
//!
//! The two-surface doctrine (C3 §6, ratified 2026-08-12): `Topology()` is
//! the **authoring** surface — Ring, written by hand — and `zing.json` is
//! the **artifact**: what ships, and what a court or a Zen frontend reads,
//! neither of which can parse Ring. This file is the bridge between them,
//! and it is a *build* step, never a runtime derivation.
//!
//! Two rules it obeys, both from the contract rather than from taste:
//!
//!   IT EMITS ONLY WHAT IT OWNS. `placement` is RingServ's section.
//!   `solution`, `governance` and `targets` are Zing's — a build decision
//!   and a deployment decision are different fields (§4.1), and a tool
//!   that rewrites a section it does not own turns a merge into a loss.
//!   So an existing `zing.json` is *edited*, not replaced.
//!
//!   IT REFUSES WHEN THE APP IS NOT IN A SOLUTION. The ratified
//!   jurisdiction sentence binds an application that is part of a Zing
//!   solution and reaches no further. A standalone Ring application
//!   server owes no manifest, so `--emit` says so and writes nothing
//!   rather than helpfully inventing membership.

const std = @import("std");
const bridge = @import("bridge");
const check = @import("check.zig");

/// Ask the app's VM for its placement section. Same scratch-VM discipline
/// as `check`: an in-memory database, never served, so evaluating an
/// application to read its declaration cannot touch real data.
fn manifestOf(arena: std.mem.Allocator, app_path: []const u8) !?std.json.Parsed(std.json.Value) {
    const f = std.fs.cwd().openFile(app_path, .{}) catch return null;
    defer f.close();
    const src = try f.readToEndAlloc(arena, 64 * 1024 * 1024);
    const src_z = try @import("cli.zig").normalizeZ(arena, src);

    bridge.setAppDir(std.fs.path.dirname(app_path) orelse ".");
    try bridge.db.configure(":memory:");
    bridge.db.setDisplayPath(":memory:");
    bridge.rs_set_echo(0);
    if (bridge.rs_init() != 0) return null;
    if (bridge.rs_eval(src_z) != 0) return null;

    const raw = std.mem.span(bridge.rs_call("__rs_manifest_placement", "0"));
    if (std.mem.span(bridge.rs_last_error()).len != 0 or raw.len == 0) return null;
    const owned = try arena.dupe(u8, raw);
    return std.json.parseFromSlice(std.json.Value, arena, owned, .{}) catch null;
}

fn obj(v: ?std.json.Value) ?std.json.ObjectMap {
    const val = v orelse return null;
    return switch (val) {
        .object => |o| o,
        else => null,
    };
}

fn str(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    return switch (val) {
        .string => |s| s,
        else => "",
    };
}

fn num(v: ?std.json.Value) i64 {
    const val = v orelse return 0;
    return switch (val) {
        .integer => |i| i,
        .float => |fl| @intFromFloat(fl),
        else => 0,
    };
}

/// How many entries a `placement` section names. Ring's JsonEncode renders
/// a list of `[key, value]` pairs as a JSON **object** — which is exactly
/// the shape the contract's manifest wants — so this counts either form
/// rather than assuming one.
fn countOf(placement: std.json.Value, key: []const u8) usize {
    const p = obj(placement) orelse return 0;
    const v = p.get(key) orelse return 0;
    return switch (v) {
        .object => |o| o.count(),
        .array => |a| a.items.len,
        else => 0,
    };
}

/// `ringserv topology [app.ring] [--emit] [--json]`
pub fn topology(
    arena: std.mem.Allocator,
    app_path: []const u8,
    do_emit: bool,
    as_json: bool,
) !u8 {
    var buf: [8192]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;

    // The full map, for reading and for `--json`.
    const cat = check.catalogOf(arena, app_path) catch null;
    _ = cat;

    const parsed = (try manifestOf(arena, app_path)) orelse {
        try out.print("ringserv topology: {s} could not be evaluated\n", .{app_path});
        try out.flush();
        return 1;
    };
    const root = obj(parsed.value) orelse return 1;

    const emit = num(root.get("emit")) != 0;
    const reason = str(root.get("reason"));
    const solution = str(root.get("solution"));

    if (as_json) {
        try out.print("{f}\n", .{std.json.fmt(parsed.value, .{ .whitespace = .indent_2 })});
        try out.flush();
        return 0;
    }

    if (!emit) {
        try out.print("no manifest: {s}\n", .{reason});
        if (do_emit) {
            // Not an error. An app that is not in a solution is exactly
            // the case the contract carved out, and reporting it as a
            // failure would push people to declare membership they do
            // not have just to make a build quiet.
            try out.print(
                "\nNothing was written. `zing.json` is owed by an application that is part\n" ++
                    "of a Zing solution; declare `:solution = \"name\"` in Topology() if this\n" ++
                    "one is. A standalone RingServ app keeps the Ring surface alone.\n",
                .{},
            );
        }
        try out.flush();
        return 0;
    }

    const placement = root.get("placement") orelse return 1;

    if (!do_emit) {
        try out.print("solution: {s}\n\nplacement (what --emit would write into zing.json):\n{f}\n", .{
            solution,
            std.json.fmt(placement, .{ .whitespace = .indent_2 }),
        });
        try out.flush();
        return 0;
    }

    // --- the emit itself: edit an existing manifest, never replace it.
    const dir = std.fs.path.dirname(app_path) orelse ".";
    const manifest_path = try std.fs.path.join(arena, &.{ dir, "zing.json" });

    var merged = std.json.ObjectMap.init(arena);
    var existed = false;
    if (std.fs.cwd().openFile(manifest_path, .{})) |mf| {
        defer mf.close();
        existed = true;
        const bytes = try mf.readToEndAlloc(arena, 16 * 1024 * 1024);
        const old = std.json.parseFromSlice(std.json.Value, arena, bytes, .{}) catch {
            try out.print(
                "ringserv topology: {s} exists but is not valid JSON — refusing to overwrite it\n",
                .{manifest_path},
            );
            try out.flush();
            return 1;
        };
        if (obj(old.value)) |o| {
            var it = o.iterator();
            while (it.next()) |e| try merged.put(e.key_ptr.*, e.value_ptr.*);
        }
    } else |_| {}

    // `solution` is Zing's field, so it is written only when the file is
    // being created — an existing manifest already knows its own name and
    // must not be renamed by a server's build step.
    if (!existed) try merged.put("solution", .{ .string = solution });
    try merged.put("placement", placement);

    const text = try std.fmt.allocPrint(arena, "{f}\n", .{
        std.json.fmt(std.json.Value{ .object = merged }, .{ .whitespace = .indent_2 }),
    });

    const file = try std.fs.cwd().createFile(manifest_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(text);

    try out.print("{s} {s}: placement for {d} service(s), {d} data entr(ies)\n", .{
        if (existed) "updated" else "wrote",
        manifest_path,
        countOf(placement, "services"),
        countOf(placement, "data"),
    });
    try out.flush();
    return 0;
}
