//! ringserv deploy / redeploy / ls — putting an application up, and
//! putting a change up, without ceremony.
//!
//! A DEPLOYMENT IS A NAMED DIRECTORY, laid out so that the dangerous
//! operation is safe by construction rather than by care:
//!
//!     <root>/<name>/
//!         app.ring, public/, services/…    the CODE — replaced wholesale
//!         .ringserv/
//!             deployment.yaml              name, port, source, when
//!             data/                        the database, and everything
//!                                          the application writes
//!             logs/
//!
//! **Redeploy replaces everything except `.ringserv/`.** That single rule
//! is the whole safety story: a code change CANNOT reach the record,
//! because the record does not live where the code lives. No flag to
//! forget, no ordering to get right at 2 a.m.
//!
//! The layout is also exactly what `ringserv panel <root>` already scans —
//! `<name>/app.ring` — so a deployed application shows up in the panel with
//! Start, Stop and Reload, with nothing taught to the panel at all.
//!
//! What this is NOT (docs/PLAN.md phase 20 refuses these by name): a
//! process supervisor, a clustering story, a service-manager integration,
//! or a remote deploy. It puts an application up ON THIS MACHINE.

const std = @import("std");
const panel = @import("panel.zig");

pub const MANIFEST = "deployment.yaml";
pub const PRIVATE = ".ringserv";

pub const Manifest = struct {
    name: []const u8 = "",
    port: u16 = 0,
    source: []const u8 = "",
    entry: []const u8 = "app.ring",
    deployed: []const u8 = "",
};

// ------------------------------------------------------------- helpers

/// Is this a directory? Answered by OPENING it, because Windows'
/// `statFile` returns `error.IsDir` for one and therefore never reports a
/// kind — so the obvious reading ("stat it, look at .kind") fails on the
/// most ordinary thing anyone will deploy. Measured while deploying.
fn isDirectory(p: []const u8) bool {
    var d = std.fs.cwd().openDir(p, .{}) catch return false;
    d.close();
    return true;
}

fn isPrivate(name: []const u8) bool {
    return std.mem.eql(u8, name, PRIVATE);
}

/// Copy a tree, skipping `.ringserv` at the top level and anything a
/// developer would be surprised to see deployed.
///
/// The skips are NAMED rather than clever: a deployment that silently
/// carried a .git directory or a node_modules would be a deployment whose
/// size nobody could explain.
fn copyTree(
    a: std.mem.Allocator,
    src_dir: []const u8,
    dst_dir: []const u8,
    depth: u32,
    copied: *usize,
) !void {
    if (depth > 16) return;
    var src = try std.fs.cwd().openDir(src_dir, .{ .iterate = true });
    defer src.close();
    std.fs.cwd().makePath(dst_dir) catch {};

    var it = src.iterate();
    while (try it.next()) |entry| {
        if (isPrivate(entry.name)) continue;
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;
        if (std.mem.eql(u8, entry.name, "zig-out")) continue;
        if (std.mem.eql(u8, entry.name, ".zig-cache")) continue;
        // A database sitting beside the source is the developer's scratch
        // copy. Carrying it into a deployment would install test data as
        // production data, which is a mistake nobody recovers from quickly.
        if (std.mem.endsWith(u8, entry.name, ".db")) continue;
        if (std.mem.endsWith(u8, entry.name, ".db-wal")) continue;
        if (std.mem.endsWith(u8, entry.name, ".db-shm")) continue;

        const s = try std.fs.path.join(a, &.{ src_dir, entry.name });
        const d = try std.fs.path.join(a, &.{ dst_dir, entry.name });
        switch (entry.kind) {
            .directory => try copyTree(a, s, d, depth + 1, copied),
            .file => {
                std.fs.cwd().copyFile(s, std.fs.cwd(), d, .{}) catch continue;
                copied.* += 1;
            },
            else => {},
        }
    }
}

/// Delete a deployment's CODE, leaving `.ringserv` untouched.
fn clearCode(a: std.mem.Allocator, dir_path: []const u8) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (isPrivate(entry.name)) continue;
        const p = try std.fs.path.join(a, &.{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => std.fs.cwd().deleteTree(p) catch {},
            else => std.fs.cwd().deleteFile(p) catch {},
        }
    }
}

fn writeManifest(a: std.mem.Allocator, dir_path: []const u8, m: Manifest) !void {
    const p = try std.fs.path.join(a, &.{ dir_path, PRIVATE, MANIFEST });
    const text = try std.fmt.allocPrint(a,
        \\# Written by `ringserv deploy`. Edit `port` freely; the rest is a record.
        \\name: {s}
        \\port: {d}
        \\entry: {s}
        \\source: {s}
        \\deployed: {s}
        \\
    , .{ m.name, m.port, m.entry, m.source, m.deployed });
    var f = try std.fs.cwd().createFile(p, .{ .truncate = true });
    defer f.close();
    try f.writeAll(text);
}

pub fn readManifest(a: std.mem.Allocator, dir_path: []const u8) ?Manifest {
    const p = std.fs.path.join(a, &.{ dir_path, PRIVATE, MANIFEST }) catch return null;
    const text = std.fs.cwd().readFileAlloc(a, p, 64 * 1024) catch return null;
    var m = Manifest{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse continue;
        const key = std.mem.trim(u8, t[0..colon], " \t");
        const val = std.mem.trim(u8, t[colon + 1 ..], " \t");
        if (std.mem.eql(u8, key, "name")) m.name = val;
        if (std.mem.eql(u8, key, "entry")) m.entry = val;
        if (std.mem.eql(u8, key, "source")) m.source = val;
        if (std.mem.eql(u8, key, "deployed")) m.deployed = val;
        if (std.mem.eql(u8, key, "port")) m.port = std.fmt.parseInt(u16, val, 10) catch 0;
    }
    return m;
}

/// Is something serving on this port, right now? A GET to /health, and
/// SILENT — `ls` is a listing, and a listing that prints a diagnostic per
/// row is a listing nobody can read.
///
/// `panel.probe` is deliberately not used here: it is a debugging helper
/// and prints what it saw, which is exactly right for a probe and exactly
/// wrong for a column in a table.
fn isServing(a: std.mem.Allocator, port: u16) bool {
    const stream = std.net.tcpConnectToHost(a, "127.0.0.1", port) catch return false;
    defer stream.close();
    var wbuf: [256]u8 = undefined;
    var sw = stream.writer(&wbuf);
    const req = std.fmt.allocPrint(a, "GET /health HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{port}) catch return false;
    sw.interface.writeAll(req) catch return false;
    sw.interface.flush() catch return false;

    var rbuf: [512]u8 = undefined;
    var sr = stream.reader(&rbuf);
    const r = sr.interface();
    const chunk = r.peekGreedy(1) catch return false;
    return std.mem.indexOf(u8, chunk, " 200 ") != null;
}

/// The current time, in UTC, LABELLED as UTC.
///
/// Zig's epoch helpers know nothing about the machine's timezone, so this
/// is UTC whether or not it says so — and a bare "2026-08-25 21:12" beside
/// a local clock reading 14:12 is a number a reader will spend real time
/// disbelieving. Say which clock it is.
fn stamp(a: std.mem.Allocator) []const u8 {
    const secs = std.time.timestamp();
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{
        yd.year, md.month.numeric(), md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(),
    }) catch "";
}

/// The last path component, with any extension removed — the default name
/// for a deployment, so `ringserv deploy examples/comptoir` is enough.
fn nameFrom(source: []const u8) []const u8 {
    var s = std.mem.trimRight(u8, source, "/\\");
    if (std.fs.path.basename(s).len > 0) s = std.fs.path.basename(s);
    if (std.mem.lastIndexOfScalar(u8, s, '.')) |dot| {
        if (dot > 0) return s[0..dot];
    }
    return s;
}

fn defaultRoot(a: std.mem.Allocator) []const u8 {
    return std.process.getEnvVarOwned(a, "RINGSERV_DEPLOYMENTS") catch
        a.dupe(u8, "deployments") catch "deployments";
}

// -------------------------------------------------------------- verbs

pub fn deploy(a: std.mem.Allocator, args: []const []const u8) !u8 {
    var source: []const u8 = "";
    var name: []const u8 = "";
    var root: []const u8 = "";
    var port: u16 = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--as") or std.mem.eql(u8, arg, "--root") or
            std.mem.eql(u8, arg, "--port"))
        {
            i += 1;
            if (i >= args.len) {
                std.debug.print("ringserv deploy: {s} needs a value\n", .{arg});
                return 2;
            }
            if (std.mem.eql(u8, arg, "--as")) name = args[i];
            if (std.mem.eql(u8, arg, "--root")) root = args[i];
            if (std.mem.eql(u8, arg, "--port")) {
                port = std.fmt.parseInt(u16, args[i], 10) catch {
                    std.debug.print("ringserv deploy: --port needs a number, got {s}\n", .{args[i]});
                    return 2;
                };
            }
        } else source = arg;
    }

    if (source.len == 0) {
        std.debug.print(
            \\ringserv deploy: what should be deployed?
            \\
            \\  ringserv deploy <folder-or-file.ring> [--as name] [--port N] [--root dir]
            \\
            \\The folder is copied; its data lives outside it, so a redeploy
            \\can never reach the record.
            \\
        , .{});
        return 2;
    }
    if (root.len == 0) root = defaultRoot(a);
    if (name.len == 0) name = nameFrom(source);

    // A file or a folder — both are ordinary things to deploy, and the
    // difference is one line rather than a second command.
    const is_dir = isDirectory(source);
    if (!is_dir) {
        std.fs.cwd().access(source, .{}) catch |e| {
            std.debug.print("ringserv deploy: cannot read {s}: {s}\n", .{ source, @errorName(e) });
            return 1;
        };
    }

    const dir_path = try std.fs.path.join(a, &.{ root, name });
    if (std.fs.cwd().access(dir_path, .{})) |_| {
        // REFUSE rather than overwrite. `deploy` and `redeploy` are
        // different words because they are different risks, and a deploy
        // that quietly replaced a live one would make them the same word.
        std.debug.print(
            \\ringserv deploy: `{s}` is already deployed at {s}
            \\
            \\  ringserv redeploy {s}        replace its code, keep its data
            \\  ringserv deploy … --as <other-name>
            \\
        , .{ name, dir_path, name });
        return 1;
    } else |_| {}

    try std.fs.cwd().makePath(dir_path);
    const priv = try std.fs.path.join(a, &.{ dir_path, PRIVATE });
    try std.fs.cwd().makePath(try std.fs.path.join(a, &.{ priv, "data" }));
    try std.fs.cwd().makePath(try std.fs.path.join(a, &.{ priv, "logs" }));

    var copied: usize = 0;
    var entry: []const u8 = "app.ring";
    if (is_dir) {
        try copyTree(a, source, dir_path, 0, &copied);
    } else {
        entry = std.fs.path.basename(source);
        const dst = try std.fs.path.join(a, &.{ dir_path, entry });
        try std.fs.cwd().copyFile(source, std.fs.cwd(), dst, .{});
        copied = 1;
    }

    const entry_path = try std.fs.path.join(a, &.{ dir_path, entry });
    std.fs.cwd().access(entry_path, .{}) catch {
        std.debug.print(
            \\ringserv deploy: copied {d} file(s), but there is no `{s}` in {s}
            \\
            \\An application folder needs an app.ring. Deploy a single file
            \\instead, or name the folder that holds one.
            \\
        , .{ copied, entry, dir_path });
        return 1;
    };

    try writeManifest(a, dir_path, .{
        .name = name,
        .port = port,
        .source = source,
        .entry = entry,
        .deployed = stamp(a),
    });

    // The next command is printed READY TO RUN, port and all. A hint that
    // still needs filling in is a hint that gets retyped wrongly once.
    const port_arg = if (port != 0)
        try std.fmt.allocPrint(a, " --port {d}", .{port})
    else
        "";
    const data_dir = try std.fs.path.join(a, &.{ priv, "data" });
    std.debug.print(
        \\deployed `{s}` — {d} file(s)
        \\
        \\  code : {s}
        \\  data : {s}      (a redeploy never touches this)
        \\
        \\  ringserv run {s}{s} --data {s}
        \\  ringserv panel {s}     every deployment, with Start / Stop / Reload
        \\
    , .{
        name,       copied,
        dir_path,   data_dir,
        entry_path, port_arg,
        data_dir,   root,
    });
    return 0;
}

pub fn redeploy(a: std.mem.Allocator, args: []const []const u8) !u8 {
    var name: []const u8 = "";
    var root: []const u8 = "";
    var from: []const u8 = "";
    var no_reload = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--no-reload")) {
            no_reload = true;
        } else if (std.mem.eql(u8, arg, "--root") or std.mem.eql(u8, arg, "--from")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("ringserv redeploy: {s} needs a value\n", .{arg});
                return 2;
            }
            if (std.mem.eql(u8, arg, "--root")) root = args[i];
            if (std.mem.eql(u8, arg, "--from")) from = args[i];
        } else name = arg;
    }

    if (name.len == 0) {
        std.debug.print("ringserv redeploy: which deployment? — ringserv redeploy <name>\n", .{});
        return 2;
    }
    if (root.len == 0) root = defaultRoot(a);

    const dir_path = try std.fs.path.join(a, &.{ root, name });
    const m = readManifest(a, dir_path) orelse {
        std.debug.print(
            \\ringserv redeploy: `{s}` is not a deployment ({s} has no {s}/{s})
            \\
            \\  ringserv deploy <folder> --as {s}     to create it
            \\
        , .{ name, dir_path, PRIVATE, MANIFEST, name });
        return 1;
    };

    const source = if (from.len != 0) from else m.source;
    if (source.len == 0) {
        std.debug.print("ringserv redeploy: `{s}` records no source — pass --from <folder>\n", .{name});
        return 1;
    }
    std.fs.cwd().access(source, .{}) catch |e| {
        std.debug.print("ringserv redeploy: cannot read the source {s}: {s}\n", .{ source, @errorName(e) });
        return 1;
    };

    // THE ORDER MATTERS, and it is the whole reason this is a verb rather
    // than a paragraph of instructions: clear the CODE, copy the new code,
    // and never at any point look at `.ringserv`.
    try clearCode(a, dir_path);
    var copied: usize = 0;
    if (isDirectory(source)) {
        try copyTree(a, source, dir_path, 0, &copied);
    } else {
        const dst = try std.fs.path.join(a, &.{ dir_path, std.fs.path.basename(source) });
        try std.fs.cwd().copyFile(source, std.fs.cwd(), dst, .{});
        copied = 1;
    }
    try writeManifest(a, dir_path, .{
        .name = m.name,
        .port = m.port,
        .source = source,
        .entry = m.entry,
        .deployed = stamp(a),
    });

    std.debug.print("redeployed `{s}` — {d} file(s) replaced, data untouched\n", .{ name, copied });

    // AND IF IT IS RUNNING, MAKE IT LIVE. This is the join between the two
    // halves of phase 20: replacing files that a running server never
    // re-reads is a change nobody can see, and asking a person to remember
    // a second command is the ceremony this phase exists to delete.
    if (no_reload or m.port == 0) {
        if (m.port == 0 and !no_reload) {
            std.debug.print("  (no port recorded, so nothing was reloaded — `ringserv reload --port N` when it runs)\n", .{});
        }
        return 0;
    }
    const r = panel.proxyPost(a, m.port, "/admin/reload", "{}") catch {
        std.debug.print("  it is not running on port {d}, so there was nothing to reload\n", .{m.port});
        return 0;
    };
    if (r.status == 200) {
        std.debug.print("  and reloaded it live on port {d} — no restart, no dropped connection\n", .{m.port});
        return 0;
    }
    // The new code is on disk and the server refused it. Say both halves:
    // the deployment DID change, and the running server did NOT.
    std.debug.print(
        \\  the running server on port {d} REFUSED the new code and kept what it had:
        \\  {s}
        \\  The files are deployed; the server is unchanged. Fix and `ringserv reload --port {d}`.
        \\
    , .{ m.port, r.body, m.port });
    return 1;
}

pub fn list(a: std.mem.Allocator, args: []const []const u8) !u8 {
    var root: []const u8 = "";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--root")) {
            i += 1;
            if (i < args.len) root = args[i];
        } else root = args[i];
    }
    if (root.len == 0) root = defaultRoot(a);

    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch {
        std.debug.print("no deployments in {s} — ringserv deploy <folder>\n", .{root});
        return 0;
    };
    defer dir.close();

    std.debug.print("deployments in {s}\n\n", .{root});
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const p = try std.fs.path.join(a, &.{ root, entry.name });
        const m = readManifest(a, p) orelse continue;
        n += 1;
        // Running or not is ASKED, never assumed from a pid file — a live
        // process is not a serving port (docs/DEPLOY.md).
        var state: []const u8 = "stopped";
        if (m.port != 0 and isServing(a, m.port)) state = "running";
        std.debug.print("  {s: <18} port {d: <6} {s: <9} {s}\n", .{
            m.name,
            m.port,
            state,
            m.deployed,
        });
    }
    if (n == 0) std.debug.print("  (none yet)\n", .{});
    std.debug.print("\n", .{});
    return 0;
}
