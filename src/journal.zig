//! journal.zig — `ringserv journal list | verify | export`.
//!
//! The ambassador docs/COMMONS.md §1 named and phase 9 owed. `Journal()`
//! made the record durable and `RsJournalService()` made it answerable over
//! HTTP; this makes it answerable when **no client is attached** — which is
//! the case the design was written for. The box is in a drawer, the
//! inspector is standing there, and the question is whether the chain holds.
//!
//! Three rules it obeys, and each one is a decision rather than a detail:
//!
//!   IT OPENS THE APPLICATION'S OWN DATABASE, not a scratch one. `check`,
//!   `docs` and `topology` all evaluate an app against `:memory:` because
//!   they read *declarations*. This command reads *records*, so it must
//!   look at the same file the server writes — and it says which file, on
//!   every run, because an export whose provenance is implicit is an export
//!   nobody can hand to an auditor.
//!
//!   IT NEVER CREATES THE JOURNAL TABLE. `__rs_data_apply` would, and is
//!   deliberately not called: pointed at the wrong path, a command that
//!   creates what it cannot find reports an empty record where it should
//!   report a missing one. A missing table is a fact, and it is printed as
//!   one. (SQLite still creates an absent *file* on open; the message says
//!   so rather than pretending otherwise.)
//!
//!   IT DECIDES NOTHING ABOUT WHICH JOURNAL IS MEANT. That rule lives in
//!   `__rs_journal_cli`, beside the identical rule the HTTP service uses.
//!   A second copy here would be a second answer, and the two would drift
//!   on the first application that declares three journals.
//!
//! `verify` exits 1 on ROMPUE. A verification command that always exits 0
//! is one no cron job can use, and this is the check that belongs in a cron
//! job.

const std = @import("std");
const bridge = @import("bridge");

const usage =
    \\ringserv journal — the fiscal record, from the command line
    \\
    \\  ringserv journal list   [app.ring]   the journals this app declares
    \\  ringserv journal verify [app.ring]   INTACTE or ROMPUE, and where
    \\  ringserv journal export [app.ring]   JSONL, one event per line
    \\
    \\  --journal <name>   which journal (required when the app declares > 1)
    \\  --db <path>        read this database instead of the declared one
    \\  --out <file>       write here instead of stdout (export)
    \\  --json             machine-readable verdict (verify)
    \\
;

/// A journal name is an identifier by construction (`RsValidName`), and it
/// is about to be interpolated into JSON. Checking it here means the
/// encoder below never has to escape anything, and a name that could not
/// be a journal's is refused before it reaches the VM.
fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

fn str(v: ?std.json.Value) []const u8 {
    return switch (v orelse return "") {
        .string => |s| s,
        else => "",
    };
}

fn num(v: ?std.json.Value) f64 {
    return switch (v orelse return 0) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => 0,
    };
}

/// The database the app declared, or null for a program that declared no
/// `RingServ()` at all.
fn declaredDb(arena: std.mem.Allocator) ?[]const u8 {
    const raw = std.mem.span(bridge.rs_call("__rs_serv_config", "{}"));
    if (std.mem.span(bridge.rs_last_error()).len != 0 or raw.len == 0) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, raw, .{}) catch return null;
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    if (num(root.get("serv")) != 1) return null;
    const path = str(root.get("database"));
    return if (path.len == 0) null else path;
}

pub fn journal(arena: std.mem.Allocator, args: []const [:0]u8) !u8 {
    var buf: [8192]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;

    if (args.len == 0) {
        try out.print("{s}", .{usage});
        try out.flush();
        return 2;
    }
    const op = args[0];
    if (!std.mem.eql(u8, op, "list") and
        !std.mem.eql(u8, op, "verify") and
        !std.mem.eql(u8, op, "export"))
    {
        try out.print("ringserv journal: no such subcommand `{s}`\n\n{s}", .{ op, usage });
        try out.flush();
        return 2;
    }

    var app_path: []const u8 = "app.ring";
    var name: []const u8 = "";
    var db_override: []const u8 = "";
    var out_path: []const u8 = "";
    var as_json = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json")) {
            as_json = true;
        } else if (std.mem.eql(u8, a, "--journal") or std.mem.eql(u8, a, "--db") or
            std.mem.eql(u8, a, "--out"))
        {
            if (i + 1 >= args.len) {
                try out.print("ringserv journal: {s} needs a value\n", .{a});
                try out.flush();
                return 2;
            }
            i += 1;
            if (std.mem.eql(u8, a, "--journal")) name = args[i];
            if (std.mem.eql(u8, a, "--db")) db_override = args[i];
            if (std.mem.eql(u8, a, "--out")) out_path = args[i];
        } else if (std.mem.startsWith(u8, a, "--")) {
            try out.print("ringserv journal: unknown option `{s}`\n\n{s}", .{ a, usage });
            try out.flush();
            return 2;
        } else {
            app_path = a;
        }
    }

    if (name.len != 0 and !validName(name)) {
        try out.print(
            "ringserv journal: `{s}` is not a journal name — letters, digits or _\n",
            .{name},
        );
        try out.flush();
        return 2;
    }

    // ------------------------------------------------ evaluate the app
    const src = @import("cli.zig").readSourceZ(arena, app_path) catch {
        try out.print("ringserv journal: cannot read {s}\n", .{app_path});
        try out.flush();
        return 1;
    };
    bridge.setAppDir(std.fs.path.dirname(app_path) orelse ".");
    // Silent: the application's own boot chatter would land in the middle
    // of an export whose whole value is that it is machine-readable.
    bridge.rs_set_echo(0);
    if (bridge.rs_init() != 0) {
        try out.print("ringserv journal: runtime init failed: {s}\n", .{bridge.rs_init_error()});
        try out.flush();
        return 1;
    }
    if (bridge.rs_eval(src) != 0) {
        try out.print("ringserv journal: {s}\n", .{bridge.rs_last_error()});
        try out.flush();
        return 1;
    }

    // `list` reads a declaration and needs no database at all — answered
    // before anything is opened, so it works on a machine that has never
    // seen the data file.
    var db_shown: []const u8 = "";
    if (!std.mem.eql(u8, op, "list")) {
        const db_path = if (db_override.len != 0)
            db_override
        else
            declaredDb(arena) orelse {
                try out.print(
                    \\ringserv journal: {s} declares no database, so there is no
                    \\journal on disk to read. Name one with --db <path>.
                    \\
                , .{app_path});
                try out.flush();
                return 1;
            };
        bridge.db.setDisplayPath(db_path);
        try bridge.db.configure(db_path);
        db_shown = db_path;
    }

    // ---------------------------------------------------- ask the VM
    const arg = try std.fmt.allocPrintSentinel(
        arena,
        "{{\"op\":\"{s}\",\"journal\":\"{s}\"}}",
        .{ op, name },
        0,
    );
    const raw = std.mem.span(bridge.rs_call("__rs_journal_cli", arg));
    const call_err = std.mem.span(bridge.rs_last_error());
    if (call_err.len != 0 or raw.len == 0) {
        try out.print("ringserv journal: {s}\n", .{if (call_err.len != 0) call_err else "no answer from the application"});
        try out.flush();
        return 1;
    }
    const parsed = std.json.parseFromSlice(std.json.Value, arena, raw, .{}) catch {
        try out.print("ringserv journal: unreadable answer\n", .{});
        try out.flush();
        return 1;
    };
    const res = switch (parsed.value) {
        .object => |o| o,
        else => {
            try out.print("ringserv journal: unreadable answer\n", .{});
            try out.flush();
            return 1;
        },
    };

    if (num(res.get("ok")) != 1) {
        const why = str(res.get("error"));
        try out.print("ringserv journal: {s}\n", .{why});
        if (res.get("names")) |n| {
            if (n == .array and n.array.items.len != 0) {
                try out.print("  declared here:", .{});
                for (n.array.items) |item| try out.print(" {s}", .{str(item)});
                try out.print("\n", .{});
            }
        }
        // The database is named only on THIS path, and deliberately: a
        // missing table almost always means the wrong file was opened, and
        // the wrong file is the one fact the message otherwise withholds.
        // SQLite creates an absent file on open, so an empty database here
        // is not evidence that the journal was emptied - say that, because
        // the alternative is an operator concluding the record is gone.
        if (db_shown.len != 0 and std.mem.indexOf(u8, why, "no such table") != null) {
            try out.print(
                \\  read from {s}
                \\  nothing has been appended there, or that is not the database
                \\  the server writes. SQLite creates an absent file on open, so
                \\  an empty one proves nothing was lost.
                \\
            , .{db_shown});
        }
        try out.flush();
        return 1;
    }

    // ------------------------------------------------------------ list
    if (std.mem.eql(u8, op, "list")) {
        const names = res.get("names");
        if (names == null or names.? != .array or names.?.array.items.len == 0) {
            try out.print("{s} declares no journal.\n", .{app_path});
            try out.flush();
            return 0;
        }
        for (names.?.array.items) |item| try out.print("{s}\n", .{str(item)});
        try out.flush();
        return 0;
    }

    const which = str(res.get("journal"));

    // ---------------------------------------------------------- verify
    if (std.mem.eql(u8, op, "verify")) {
        const events: u64 = @intFromFloat(@max(0, num(res.get("events"))));
        const chain = str(res.get("chain"));
        const at: u64 = @intFromFloat(@max(0, num(res.get("at"))));
        const why = str(res.get("why"));
        const intact = std.mem.eql(u8, chain, "INTACTE");

        if (as_json) {
            try out.print("{s}\n", .{raw});
        } else if (intact) {
            try out.print("{s} — {s}: {d} event(s), chain INTACTE\n", .{ db_shown, which, events });
        } else {
            try out.print(
                \\{s} — {s}: chain ROMPUE
                \\  {d} event(s) read, broken at seq {d}
                \\  {s}
                \\
            , .{ db_shown, which, events, at, why });
        }
        try out.flush();
        return if (intact) 0 else 1;
    }

    // ---------------------------------------------------------- export
    const text = str(res.get("text"));
    if (out_path.len != 0) {
        const file = std.fs.cwd().createFile(out_path, .{ .truncate = true }) catch |e| {
            try out.print("ringserv journal: cannot write {s}: {s}\n", .{ out_path, @errorName(e) });
            try out.flush();
            return 1;
        };
        defer file.close();
        try file.writeAll(text);
        // Counted from the text rather than asked of the journal a second
        // time: the number a reader is given must describe the bytes that
        // were actually written, not a second read that could disagree.
        try out.print("wrote {s} — {d} line(s) from {s}:{s}\n", .{
            out_path, std.mem.count(u8, text, "\n"), db_shown, which,
        });
        try out.flush();
        return 0;
    }
    try out.flush();
    try std.fs.File.stdout().writeAll(text);
    return 0;
}
