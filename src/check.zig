//! check.zig — `ringserv check` and `ringserv docs`.
//!
//! Two passes, deliberately from two different sources of truth:
//!
//!   SYNTAX comes from tree-sitter. A vendored Ring grammar parses every
//!   .ring file and reports ERROR/MISSING nodes with real line:column,
//!   before anything runs. This is a linter with Ring-shaped eyes.
//!
//!   STRUCTURE comes from the VM. The application's declaration is data
//!   the runtime already holds — services, actions, contracts — so
//!   asking it beats reconstructing the same facts from an AST, and it
//!   stays correct for a language where declarations can be computed.
//!   (architecture.md §6: runtime truth stays with the VM.)
//!
//! The grammar is young and pinned. A grammar that cannot load must
//! never block work: the syntax pass degrades to "skipped" and `check`
//! still runs its semantic pass. `dev` and `run` never call this at all.

const std = @import("std");
const bridge = @import("bridge");

const ts = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_ring() ?*const ts.TSLanguage;

/// A refusal, in the family's shape.
///
/// C2 — the Diagnostic Contract — fixes one envelope for every court in the
/// family: `{code, severity, message, span{file,line,col}, cites[],
/// language}`. A programmer who learns one refusal format has learned them
/// all. `check` speaks it from `--json`; the plain output stays human,
/// because a person reading a terminal is not a court.
pub const Finding = struct {
    file: []const u8,
    line: usize,
    col: usize,
    message: []const u8,
    /// C2 `code` — stable, greppable, and never renamed once shipped.
    code: []const u8,
    /// C2 `cites` — citations into a **pinned instrument of law**, by stable
    /// identifier, in the form `rule:` / `article:` / `right:` / `pattern:`.
    ///
    /// **Empty today, and honestly so.** RingServ pins no instrument: its
    /// rules live in prose (`docs/services.md`) with no stable identifiers,
    /// and C2 §2.5 forbids citing prose — a section number renumbers, so it
    /// is exactly the kind of reference the rule exists to prevent. Where no
    /// law applies, `[]` is the conforming answer; the reader's pointer
    /// travels in `message`, where wording is free. If RingServ's rules are
    /// ever numbered, this field fills in without an envelope change.
    cites: []const []const u8 = &.{},
    /// Findings that must fail the command; notes that merely inform.
    /// Maps to C2 `severity`: error / warning.
    hard: bool = true,
};

// ------------------------------------------------------------- syntax

/// Parse one file and append a finding per ERROR / MISSING node.
/// Returns false when the grammar itself is unavailable.
fn syntaxOfFile(
    arena: std.mem.Allocator,
    path: []const u8,
    src: []const u8,
    out: *std.ArrayList(Finding),
) !bool {
    const lang = tree_sitter_ring() orelse return false;
    const parser = ts.ts_parser_new() orelse return false;
    defer ts.ts_parser_delete(parser);
    if (!ts.ts_parser_set_language(parser, lang)) return false;

    const tree = ts.ts_parser_parse_string(parser, null, src.ptr, @intCast(src.len)) orelse return false;
    defer ts.ts_tree_delete(tree);

    const root = ts.ts_tree_root_node(tree);
    if (!ts.ts_node_has_error(root)) return true;

    // Walk to the smallest nodes that carry the error, so the report
    // points at the offending token rather than the whole file.
    var stack: std.ArrayList(ts.TSNode) = .empty;
    try stack.append(arena, root);
    while (stack.pop()) |node| {
        const is_error = ts.ts_node_is_error(node);
        const is_missing = ts.ts_node_is_missing(node);
        if (is_error or is_missing) {
            const start = ts.ts_node_start_point(node);
            const kind = if (is_missing) "missing syntax" else "syntax error";
            const sb = ts.ts_node_start_byte(node);
            const eb = ts.ts_node_end_byte(node);
            const text = if (eb > sb and eb <= src.len) src[sb..@min(eb, sb + 40)] else "";
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            const msg = if (trimmed.len > 0)
                try std.fmt.allocPrint(arena, "{s} near `{s}`", .{ kind, trimmed })
            else
                try std.fmt.allocPrint(arena, "{s}", .{kind});
            try out.append(arena, .{
                .file = path,
                .line = start.row + 1,
                .col = start.column + 1,
                .message = msg,
                .code = if (is_missing) "RS_SYNTAX_MISSING" else "RS_SYNTAX_ERROR",
            });
            continue; // do not descend further into a reported error
        }
        if (!ts.ts_node_has_error(node)) continue;
        var i: u32 = 0;
        const n = ts.ts_node_child_count(node);
        while (i < n) : (i += 1) try stack.append(arena, ts.ts_node_child(node, i));
    }
    return true;
}

// ------------------------------------------------------------ catalog

pub const Catalog = struct {
    json: []const u8,
    parsed: std.json.Parsed(std.json.Value),
};

/// Evaluate the app in a scratch VM (memory database, never served) and
/// ask servlib for its catalog.
pub fn catalogOf(arena: std.mem.Allocator, app_path: []const u8) !?Catalog {
    const f = std.fs.cwd().openFile(app_path, .{}) catch return null;
    defer f.close();
    const src = try f.readToEndAlloc(arena, 64 * 1024 * 1024);
    const src_z = try @import("cli.zig").normalizeZ(arena, src);

    try bridge.db.configure(":memory:");
    bridge.db.setDisplayPath(":memory:");
    bridge.rs_set_echo(0);
    if (bridge.rs_init() != 0) return null;
    if (bridge.rs_eval(src_z) != 0) return null;

    const raw = std.mem.span(bridge.rs_call("__rs_catalog", "0"));
    if (std.mem.span(bridge.rs_last_error()).len != 0 or raw.len == 0) return null;
    const owned = try arena.dupe(u8, raw);
    const parsed = std.json.parseFromSlice(std.json.Value, arena, owned, .{}) catch return null;
    return .{ .json = owned, .parsed = parsed };
}

fn str(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    return switch (val) {
        .string => |s| s,
        else => "",
    };
}

fn arr(v: ?std.json.Value) []std.json.Value {
    const val = v orelse return &.{};
    return switch (val) {
        .array => |a| a.items,
        else => &.{},
    };
}

// -------------------------------------------------------------- check

pub fn check(arena: std.mem.Allocator, app_path: []const u8) !u8 {
    return checkMode(arena, app_path, false);
}

/// Emit the findings as C2 v1.0 envelopes:
/// `{code, severity, message, span{file,line,col}, cites[], language}`.
///
/// One per finding, so any court in the family can read a RingServ refusal
/// without knowing anything about RingServ. The plain output stays human —
/// a person reading a terminal is not a court.
///
/// Pinned at **C2 v1.0** (`stzzui/doc/diagnostic-contract.schema.json`,
/// vendored at `vendor/c2/`). Two details the schema decides, not us:
/// `line = 0` means the finding indicts the whole file, and `col` is
/// **omitted** rather than zeroed when no column is known — the schema
/// requires `col >= 1` where present, so a zero is not a missing column,
/// it is an invalid one.
fn reportC2(items: []const Finding) u8 {
    var buf: [8192]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;
    var hard: usize = 0;

    out.print("[", .{}) catch {};
    for (items, 0..) |f, i| {
        if (f.hard) hard += 1;
        if (i > 0) out.print(",", .{}) catch {};
        out.print("\n  {{\"code\":\"{s}\",\"severity\":\"{s}\",\"message\":", .{
            f.code,
            if (f.hard) "error" else "warning",
        }) catch {};
        writeJsonString(out, f.message);
        out.print(",\"span\":{{\"file\":", .{}) catch {};
        writeJsonString(out, f.file);
        out.print(",\"line\":{d}", .{f.line}) catch {};
        if (f.col > 0) out.print(",\"col\":{d}", .{f.col}) catch {};
        out.print("}},\"cites\":[", .{}) catch {};
        for (f.cites, 0..) |c, j| {
            if (j > 0) out.print(",", .{}) catch {};
            writeJsonString(out, c);
        }
        out.print("],\"language\":\"ringserv\"}}", .{}) catch {};
    }
    out.print("\n]\n", .{}) catch {};
    out.flush() catch {};
    return if (hard == 0) 0 else 1;
}

fn writeJsonString(out: anytype, s: []const u8) void {
    out.print("\"", .{}) catch return;
    for (s) |ch| switch (ch) {
        '"' => out.print("\\\"", .{}) catch return,
        '\\' => out.print("\\\\", .{}) catch return,
        '\n' => out.print("\\n", .{}) catch return,
        '\r' => out.print("\\r", .{}) catch return,
        '\t' => out.print("\\t", .{}) catch return,
        else => {
            if (ch < 0x20) {
                out.print("\\u{x:0>4}", .{ch}) catch return;
            } else {
                out.print("{c}", .{ch}) catch return;
            }
        },
    };
    out.print("\"", .{}) catch return;
}


pub fn checkMode(arena: std.mem.Allocator, app_path: []const u8, as_json: bool) !u8 {
    var findings: std.ArrayList(Finding) = .empty;
    var grammar_ok = true;

    // --- syntax, over every .ring in the app folder and its tests/
    const dir_path = std.fs.path.dirname(app_path) orelse ".";
    for ([_][]const u8{ dir_path, try std.fs.path.join(arena, &.{ dir_path, "tests" }) }) |folder| {
        var d = std.fs.cwd().openDir(folder, .{ .iterate = true }) catch continue;
        defer d.close();
        var it = d.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".ring")) continue;
            const full = try std.fs.path.join(arena, &.{ folder, entry.name });
            const file = std.fs.cwd().openFile(full, .{}) catch continue;
            defer file.close();
            const src = file.readToEndAlloc(arena, 64 * 1024 * 1024) catch continue;
            grammar_ok = try syntaxOfFile(arena, full, src, &findings) and grammar_ok;
        }
    }

    // --- structure, from the VM. Skipped when syntax already failed:
    // evaluating a file with a syntax error only produces noise.
    var services_seen: usize = 0;
    if (findings.items.len == 0) {
        if (try catalogOf(arena, app_path)) |cat| {
            const obj = switch (cat.parsed.value) {
                .object => |o| o,
                else => return if (as_json) reportC2(findings.items) else reportFindings(findings.items, grammar_ok),
            };
            const services = arr(obj.get("services"));
            services_seen = services.len;
            const contracts = arr(obj.get("contracts"));

            // Every contract must name a service and an action that exist.
            for (contracts) |c| {
                const co = switch (c) {
                    .object => |o| o,
                    else => continue,
                };
                const cs = str(co.get("service"));
                const ca = str(co.get("action"));
                var svc_found = false;
                var act_found = false;
                for (services) |s| {
                    const so = switch (s) {
                        .object => |o| o,
                        else => continue,
                    };
                    if (!std.ascii.eqlIgnoreCase(str(so.get("name")), cs)) continue;
                    svc_found = true;
                    for (arr(so.get("actions"))) |a| {
                        if (std.ascii.eqlIgnoreCase(str(a), ca)) act_found = true;
                    }
                    // A declared table answers the generic actions, so a
                    // contract on one of those is legitimate too.
                    if (str(so.get("table")).len > 0) {
                        for ([_][]const u8{ "list", "get", "create", "update", "delete" }) |g| {
                            if (std.ascii.eqlIgnoreCase(g, ca)) act_found = true;
                        }
                    }
                }
                if (!svc_found) {
                    try findings.append(arena, .{
                        .file = app_path,
                        .line = 0,
                        .col = 0,
                        .message = try std.fmt.allocPrint(arena,
                            "Contract(:{s}) names a service that is not declared (docs/services.md §5)", .{cs}),
                        .code = "RS_CONTRACT_UNKNOWN_SERVICE",
                    });
                } else if (!act_found) {
                    try findings.append(arena, .{
                        .file = app_path,
                        .line = 0,
                        .col = 0,
                        .message = try std.fmt.allocPrint(arena,
                            "Contract(:{s}) declares action `{s}`, which the service does not answer (docs/services.md §5)",
                            .{ cs, ca }),
                        .code = "RS_CONTRACT_UNKNOWN_ACTION",
                    });
                }
            }

            // Services that answer nothing at all are almost certainly a
            // mistake; services without contracts are merely worth noting.
            for (services) |s| {
                const so = switch (s) {
                    .object => |o| o,
                    else => continue,
                };
                const name = str(so.get("name"));
                const actions = arr(so.get("actions"));
                const table = str(so.get("table"));
                if (actions.len == 0 and table.len == 0) {
                    try findings.append(arena, .{
                        .file = app_path,
                        .line = 0,
                        .col = 0,
                        .message = try std.fmt.allocPrint(arena,
                            "service `{s}` declares no actions and no table — it can never answer (docs/services.md §2)", .{name}),
                        .code = "RS_SERVICE_UNANSWERABLE",
                    });
                }
                for (actions) |a| {
                    const act = str(a);
                    var has_contract = false;
                    for (contracts) |c| {
                        const co = switch (c) {
                            .object => |o| o,
                            else => continue,
                        };
                        if (std.ascii.eqlIgnoreCase(str(co.get("service")), name) and
                            std.ascii.eqlIgnoreCase(str(co.get("action")), act)) has_contract = true;
                    }
                    if (!has_contract) {
                        try findings.append(arena, .{
                            .file = app_path,
                            .line = 0,
                            .col = 0,
                            .hard = false,
                            .message = try std.fmt.allocPrint(arena,
                                "note: {s}.{s} has no Contract — its payload is unchecked", .{ name, act }),
                            .code = "RS_ACTION_UNCONTRACTED",
                        });
                    }
                }
            }
        } else {
            try findings.append(arena, .{
                .file = app_path,
                .line = 0,
                .col = 0,
                .message = "the application could not be evaluated (see `ringserv run`)",
                .code = "RS_APP_UNEVALUABLE",
            });
        }
    }

    if (as_json) return reportC2(findings.items);
    return reportFindings(findings.items, grammar_ok);
}

fn reportFindings(items: []const Finding, grammar_ok: bool) u8 {
    var stderr_buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&stderr_buf);
    const out = &w.interface;

    var hard: usize = 0;
    var soft: usize = 0;
    for (items) |f| {
        if (f.hard) hard += 1 else soft += 1;
        if (f.line > 0) {
            out.print("{s}:{d}:{d}: {s}\n", .{ f.file, f.line, f.col, f.message }) catch {};
        } else {
            out.print("{s}: {s}\n", .{ f.file, f.message }) catch {};
        }
    }
    if (!grammar_ok) {
        out.print("note: the Ring grammar could not be loaded — syntax checking was skipped\n", .{}) catch {};
    }
    if (hard == 0) {
        if (soft == 0) {
            out.print("check: nothing to report.\n", .{}) catch {};
        } else {
            out.print("check: {d} note(s), no problems.\n", .{soft}) catch {};
        }
    } else {
        out.print("check: {d} problem(s), {d} note(s).\n", .{ hard, soft }) catch {};
    }
    out.flush() catch {};
    return if (hard == 0) 0 else 1;
}

// --------------------------------------------------------------- docs

pub fn docs(arena: std.mem.Allocator, app_path: []const u8, as_json: bool) !u8 {
    const cat = try catalogOf(arena, app_path) orelse {
        std.debug.print("ringserv docs: the application could not be evaluated\n", .{});
        return 1;
    };
    var buf: [8192]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;

    if (as_json) {
        try out.print("{s}\n", .{cat.json});
        try out.flush();
        return 0;
    }

    const obj = switch (cat.parsed.value) {
        .object => |o| o,
        else => return 1,
    };
    const services = arr(obj.get("services"));
    const contracts = arr(obj.get("contracts"));

    try out.print("# API\n\nOne endpoint answers everything:\n\n", .{});
    try out.print("```\nPOST /api/v1\n{{ \"service\": …, \"action\": …, \"payload\": {{ … }} }}\n```\n\n", .{});
    try out.print("Every reply is `{{ code, message, data }}` — `code` 0 is success.\n\n", .{});

    for (services) |s| {
        const so = switch (s) {
            .object => |o| o,
            else => continue,
        };
        const name = str(so.get("name"));
        const table = str(so.get("table"));
        try out.print("## {s}\n\n", .{name});
        if (table.len > 0) {
            try out.print("Generic table service over `{s}` — answers `list`, `get`, " ++
                "`create`, `update`, `delete` unless restricted.\n\n", .{table});
        }

        // The documented surface is the explicit actions plus, for a
        // table service, the generic five — otherwise a contract on
        // `create` would be invisible exactly where it matters most.
        var acts: std.ArrayList([]const u8) = .empty;
        for (arr(so.get("actions"))) |a| try acts.append(arena, str(a));
        if (table.len > 0) {
            for ([_][]const u8{ "list", "get", "create", "update", "delete" }) |g| {
                var already = false;
                for (acts.items) |x| {
                    if (std.ascii.eqlIgnoreCase(x, g)) already = true;
                }
                if (!already) try acts.append(arena, g);
            }
        }

        for (acts.items) |act| {
            try out.print("### {s}.{s}\n\n", .{ name, act });
            var documented = false;
            for (contracts) |c| {
                const co = switch (c) {
                    .object => |o| o,
                    else => continue,
                };
                if (!std.ascii.eqlIgnoreCase(str(co.get("service")), name)) continue;
                if (!std.ascii.eqlIgnoreCase(str(co.get("action")), act)) continue;
                documented = true;
                const fields = arr(co.get("in"));
                if (fields.len == 0) {
                    try out.print("Takes no declared payload fields.\n\n", .{});
                    continue;
                }
                try out.print("| field | type | required | limits |\n|---|---|---|---|\n", .{});
                for (fields) |fv| {
                    const fo = switch (fv) {
                        .object => |o| o,
                        else => continue,
                    };
                    try out.print("| `{s}` | {s} | {s} | {s} |\n", .{
                        str(fo.get("name")),
                        if (str(fo.get("type")).len > 0) str(fo.get("type")) else "any",
                        if (std.mem.eql(u8, str(fo.get("required")), "1")) "yes" else "no",
                        str(fo.get("limits")),
                    });
                }
                try out.print("\n", .{});
            }
            if (!documented) try out.print("_No contract declared — the payload is unchecked._\n\n", .{});
        }
    }
    try out.flush();
    return 0;
}
