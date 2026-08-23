//! The family handshake — announce and discover, zero configuration.
//!
//! Phase 12 (docs/PLAN.md): two RingServ processes on the same host or
//! LAN find each other with NO config file. One boring transport: a UDP
//! beacon on port 47474, sent every two seconds and on boot, received by
//! everyone who shares the port (SO_REUSEADDR — N processes on one
//! machine all hear it). The roster this builds is advisory; the TRUTH
//! about any sibling is its own /topology endpoint, fetched over plain
//! HTTP when it matters.
//!
//! The datagram. The shape was routed for review as PLAN-HANDSHAKE-12
//! because the identity half is co-owned with zing; zing answered on
//! 2026-08-23 asking for NO field added, removed or renamed. It is a
//! reviewed shape now, not a provisional one:
//!
//!   { "v": 1, "family": "ringserv", "app": "comptoir", "port": 8110,
//!     "contracts": { "c2": "1.1", "c3": "1.0" },
//!     "identity": { "custody": "L0", "alg": "none" } }
//!
//! Custody is the axis, not tier (microring's identity.md §9, relayed
//! 2026-08-22): L0 = software key (every PC), L1 = removable hardware,
//! L2 = fused secret behind secure boot. `alg` is present even when
//! "none", because a host that hardcodes one algorithm has silently
//! excluded hardware custody — the column is not decorative.
//!
//! THREE RULES FROM ZING'S REVIEW, and the second is the one a consumer
//! must obey (docs/FAMILY.md states them for readers):
//!
//!   1. `alg: "none"` is a FACT, not a gap. A consumer cannot tell an
//!      empty value from an absent one after the fact: "none" says this
//!      host was asked and has none; a missing `alg` says nobody thought
//!      about algorithms.
//!   2. `custody` IS NOT ORDINAL. L0/L1/L2 invites `custody >= "L1"`,
//!      which would silently accept an unrecognised "L3" AS BETTER. The
//!      set is CLOSED at v1: an unrecognised value is UNRECOGNISED, not
//!      higher, and a host wanting new custody vocabulary raises `v`.
//!   3. `identity` describes the HOST'S KEY CUSTODY, not this datagram's
//!      authentication. At v1 the beacon carries no signature, so `alg`
//!      names a CAPABILITY — a consumer hunting for a `sig` will not
//!      find one, and the beacon is not malformed for lacking it.
//!
//! Considered and DECLINED at v1, recorded because declined is a
//! different fact from never-raised: a key fingerprint or key id. That
//! would turn zero-configuration discovery into an identity system by
//! accident; identity-of-instance is C3's declared business.
//!
//! What this deliberately is NOT: cross-network discovery (C3's
//! declared, explicit business), a health check (last-seen is not
//! liveness), or a trust statement (hearing a beacon proves someone can
//! send UDP, nothing more — placement and actors still govern calls).
//!
//! `:announce = false` refuses ENTIRELY: no socket is bound, nothing is
//! sent, nothing is heard. Refusal means absence, not silence with the
//! radio still warm.

const std = @import("std");
const builtin = @import("builtin");

pub const PORT: u16 = 47474;
/// The family's multicast group. Multicast, NOT unicast-to-loopback,
/// because N sockets sharing a port with SO_REUSEADDR all receive a
/// multicast datagram but only ONE of them receives a unicast — the
/// first gate run proved it: the test's capture socket ate the beacons
/// and discovery went blind. Broadcast to the LAN stays as best effort
/// beside it.
pub const GROUP = [4]u8{ 239, 255, 71, 74 };
const BEACON_EVERY_MS: u64 = 2000;
/// A sibling not heard for this long is dropped from the roster — late,
/// on purpose: the roster is a phone book, not a monitor.
const FORGET_AFTER_MS: i64 = 15_000;

const alloc = std.heap.c_allocator;

const Sibling = struct {
    app: []const u8,
    host: [46]u8,
    host_len: usize,
    port: u16,
    custody: [8]u8,
    custody_len: usize,
    alg: [16]u8,
    alg_len: usize,
    last_seen_ms: i64,
};

var g_mu: std.Thread.Mutex = .{};
var g_roster: std.ArrayList(Sibling) = .empty;
var g_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var g_sock: ?std.posix.socket_t = null;

var g_app: []const u8 = "app";
var g_port: u16 = 8080;
var g_host: []const u8 = "127.0.0.1";
var g_custody: []const u8 = "L0";
var g_alg: []const u8 = "none";

/// Start announcing and listening. Idempotent; failure is LOUD in the
/// log but never fatal — a machine with a hostile firewall still serves.
pub fn start(app: []const u8, host: []const u8, port: u16, custody: []const u8, alg: []const u8) void {
    if (g_running.load(.monotonic)) return;
    g_app = alloc.dupe(u8, app) catch return;
    g_host = alloc.dupe(u8, host) catch return;
    g_port = port;
    g_custody = alloc.dupe(u8, custody) catch return;
    g_alg = alloc.dupe(u8, alg) catch return;

    const sock = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch |e| {
        std.debug.print("family: no UDP socket ({s}) — announce disabled\n", .{@errorName(e)});
        return;
    };
    // N processes on one machine must all hear the port. REUSEADDR is
    // enough on Linux and the whole story on Windows — but Darwin
    // requires SO_REUSEPORT for a second process to bind at all: without
    // it the bind fails EADDRINUSE, announce silently disabled itself,
    // and CI's macOS runner reported an empty roster while Ubuntu and
    // Windows passed. Found by that exact red, on 2026-08-23.
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1))) catch {};
    if (builtin.os.tag != .windows) {
        std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT,
            &std.mem.toBytes(@as(c_int, 1))) catch {};
    }
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.BROADCAST,
        &std.mem.toBytes(@as(c_int, 1))) catch {};
    // The receive loop doubles as the beacon clock.
    const tv = if (builtin.os.tag == .windows)
        std.mem.toBytes(@as(u32, BEACON_EVERY_MS))
    else
        std.mem.toBytes(std.posix.timeval{ .sec = 2, .usec = 0 });
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &tv) catch {};

    // Join the family group. The option number differs by OS and Zig's
    // std does not paper over it: winsock and darwin say 12, linux 35.
    const IP_ADD_MEMBERSHIP: u32 = switch (builtin.os.tag) {
        .linux => 35,
        else => 12,
    };
    const Mreq = extern struct { maddr: [4]u8, iface: [4]u8 };
    const mreq = Mreq{ .maddr = GROUP, .iface = .{ 0, 0, 0, 0 } };
    std.posix.setsockopt(sock, 0, IP_ADD_MEMBERSHIP, std.mem.asBytes(&mreq)) catch |e| {
        std.debug.print("family: multicast join failed ({s}) - LAN broadcast only\n", .{@errorName(e)});
    };

    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, PORT);
    std.posix.bind(sock, &addr.any, addr.getOsSockLen()) catch |e| {
        std.debug.print("family: cannot bind UDP {d} ({s}) — announce disabled\n", .{ PORT, @errorName(e) });
        std.posix.close(sock);
        return;
    };
    g_sock = sock;
    g_running.store(true, .monotonic);
    const t = std.Thread.spawn(.{}, loop, .{}) catch {
        g_running.store(false, .monotonic);
        return;
    };
    t.detach();
}

pub fn stop() void {
    g_running.store(false, .monotonic);
}

fn beacon(buf: []u8) []const u8 {
    // `host` is the address the server actually BINDS, so reachability
    // mirrors the TLS rule instead of lying about it: a loopback-bound
    // sibling advertises 127.0.0.1 and is honestly only same-host
    // callable; one that bound the network advertises that address.
    return std.fmt.bufPrint(buf,
        "{{\"v\":1,\"family\":\"ringserv\",\"app\":\"{s}\",\"host\":\"{s}\",\"port\":{d}," ++
            "\"contracts\":{{\"c2\":\"1.1\",\"c3\":\"1.0\"}}," ++
            "\"identity\":{{\"custody\":\"{s}\",\"alg\":\"{s}\"}}}}",
        .{ g_app, g_host, g_port, g_custody, g_alg }) catch buf[0..0];
}

fn sendBeacon(sock: std.posix.socket_t) void {
    var buf: [512]u8 = undefined;
    const msg = beacon(&buf);
    if (msg.len == 0) return;
    // Same host first (loopback hears no broadcast on some stacks), then
    // the LAN. Both best-effort: discovery is a convenience, never a
    // dependency.
    const group = std.net.Address.initIp4(GROUP, PORT);
    _ = std.posix.sendto(sock, msg, 0, &group.any, group.getOsSockLen()) catch {};
    const lan = std.net.Address.initIp4(.{ 255, 255, 255, 255 }, PORT);
    _ = std.posix.sendto(sock, msg, 0, &lan.any, lan.getOsSockLen()) catch {};
}

fn loop() void {
    const sock = g_sock orelse return;
    var last_sent: i64 = 0;
    var buf: [2048]u8 = undefined;
    while (g_running.load(.monotonic)) {
        const now = std.time.milliTimestamp();
        if (now - last_sent >= BEACON_EVERY_MS) {
            sendBeacon(sock);
            last_sent = now;
        }
        var from: std.posix.sockaddr align(4) = undefined;
        var from_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        const n = std.posix.recvfrom(sock, &buf, 0, &from, &from_len) catch {
            continue; // timeout is the clock tick
        };
        if (n == 0) continue;
        heard(buf[0..n], from);
    }
    std.posix.close(sock);
    g_sock = null;
}

/// One datagram. NOT OURS -> ignored by shape, and the shape test is the
/// whole trust model here: family + version + a valid port, or silence.
fn heard(msg: []const u8, from: std.posix.sockaddr) void {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, msg, .{}) catch return;
    defer parsed.deinit();
    const o = switch (parsed.value) {
        .object => |x| x,
        else => return,
    };
    const fam = o.get("family") orelse return;
    if (fam != .string or !std.mem.eql(u8, fam.string, "ringserv")) return;
    const v = o.get("v") orelse return;
    if (v != .integer or v.integer != 1) return;
    const app = o.get("app") orelse return;
    if (app != .string or app.string.len == 0 or app.string.len > 64) return;
    const port_v = o.get("port") orelse return;
    if (port_v != .integer or port_v.integer < 1 or port_v.integer > 65535) return;

    var custody: []const u8 = "L0";
    var algo: []const u8 = "none";
    if (o.get("identity")) |idv| {
        if (idv == .object) {
            if (idv.object.get("custody")) |cv| {
                if (cv == .string and cv.string.len <= 8) custody = cv.string;
            }
            if (idv.object.get("alg")) |av| {
                if (av == .string and av.string.len <= 16) algo = av.string;
            }
        }
    }

    var host_buf: [46]u8 = undefined;
    const addr = std.net.Address{ .any = from };
    const host = std.fmt.bufPrint(&host_buf, "{f}", .{addr}) catch return;
    // strip the ":port" the formatter appends
    const colon = std.mem.lastIndexOfScalar(u8, host, ':') orelse host.len;
    var host_only = host[0..colon];
    // The sibling's own declared bind address outranks where the packet
    // came from: a multicast datagram carries the sender's LAN address
    // even for a same-host process, while the server may only be
    // listening on loopback. "0.0.0.0" means "everywhere", so there the
    // source address is the useful one.
    var declared_buf: [46]u8 = undefined;
    if (o.get("host")) |hv| {
        if (hv == .string and hv.string.len > 0 and hv.string.len <= 45 and
            !std.mem.eql(u8, hv.string, "0.0.0.0"))
        {
            @memcpy(declared_buf[0..hv.string.len], hv.string);
            host_only = declared_buf[0..hv.string.len];
        }
    }

    g_mu.lock();
    defer g_mu.unlock();
    const now = std.time.milliTimestamp();
    // update-or-insert by (app, advertised port)
    for (g_roster.items) |*s| {
        if (std.mem.eql(u8, s.app, app.string) and s.port == @as(u16, @intCast(port_v.integer))) {
            s.last_seen_ms = now;
            @memcpy(s.host[0..host_only.len], host_only);
            s.host_len = host_only.len;
            return;
        }
    }
    var sib = Sibling{
        .app = alloc.dupe(u8, app.string) catch return,
        .host = undefined,
        .host_len = host_only.len,
        .port = @intCast(port_v.integer),
        .custody = undefined,
        .custody_len = @min(custody.len, 8),
        .alg = undefined,
        .alg_len = @min(algo.len, 16),
        .last_seen_ms = now,
    };
    @memcpy(sib.host[0..host_only.len], host_only);
    @memcpy(sib.custody[0..sib.custody_len], custody[0..sib.custody_len]);
    @memcpy(sib.alg[0..sib.alg_len], algo[0..sib.alg_len]);
    g_roster.append(alloc, sib) catch {};
}

/// The roster as JSON, self excluded, stale entries dropped.
pub fn rosterJson(out: *std.ArrayList(u8)) !void {
    g_mu.lock();
    defer g_mu.unlock();
    const now = std.time.milliTimestamp();
    try out.appendSlice(alloc, "[");
    var first = true;
    var i: usize = 0;
    while (i < g_roster.items.len) {
        const s = g_roster.items[i];
        if (now - s.last_seen_ms > FORGET_AFTER_MS) {
            alloc.free(s.app);
            _ = g_roster.swapRemove(i);
            continue;
        }
        // self: same app name AND same advertised port
        if (std.mem.eql(u8, s.app, g_app) and s.port == g_port) {
            i += 1;
            continue;
        }
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        try out.writer(alloc).print(
            "{{\"app\":\"{s}\",\"host\":\"{s}\",\"port\":{d}," ++
                "\"custody\":\"{s}\",\"alg\":\"{s}\",\"age_ms\":{d}}}",
            .{ s.app, s.host[0..s.host_len], s.port, s.custody[0..s.custody_len], s.alg[0..s.alg_len], now - s.last_seen_ms });
        i += 1;
    }
    try out.appendSlice(alloc, "]");
}
