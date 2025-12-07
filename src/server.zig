const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const json = std.json;
const httpz = @import("httpz");

const models = @import("models.zig");
const Header = models.Header;
const Envelope = models.Envelope;
const MTARequest = models.MTARequest;
const Metadata = models.Metadata;

const mime = @import("mime.zig");
const decodeMimeHeader = mime.decodeMimeHeader;

const Config = @import("config.zig").Config;
const Channels = @import("channels.zig").Channels;

const MAX_NOTIFICATION_RETRIES: u8 = 3;
const DEFAULT_SUBJECT: []const u8 = "(no subject)";
const DEFAULT_TO: []const u8 = "";

pub const Server = struct {
    allocator: mem.Allocator,
    cfg: *Config,
    channels: Channels,
};

fn signalWatcher(http_server: *httpz.Server(*Server), sigset: posix.sigset_t) void {
    const sfd = posix.signalfd(-1, &sigset, 0) catch |err| {
        std.log.err("signalfd failed: {}", .{err});
        return;
    };
    defer posix.close(sfd);

    var buf: [128]u8 = undefined;

    while (true) {
        const n = posix.read(sfd, buf[0..]) catch |err| {
            std.log.err("signalfd read failed: {}", .{err});
            return;
        };
        if (n == 0) continue;

        std.log.debug("signal received, stopping server…", .{});
        http_server.stop();
        return;
    }
}

fn extractHeader(headers: []const Header, key: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h[0], key)) {
            return h[1];
        }
    }
    return null;
}

fn isAllowedRcpt(cfg: *const Config, env: *const Envelope) bool {
    if (cfg.allowed_rcpts.len == 0) {
        std.log.debug("Recipient filter disabled: ALLOW all", .{});
        return true;
    }

    for (env.to) |addr_obj| {
        const raw_addr = addr_obj.address;
        const addr_trim = mem.trim(u8, raw_addr, " \t\r\n");

        if (addr_trim.len == 0) continue;

        std.log.debug("Check rcpt: '{s}'", .{addr_trim});

        for (cfg.allowed_rcpts) |allowed| {
            if (std.ascii.eqlIgnoreCase(addr_trim, allowed)) {
                std.log.debug("  -> MATCH found: '{s}' allowed", .{addr_trim});
                return true;
            }
        }

        std.log.debug("  -> '{s}' NOT found in whitelist", .{addr_trim});
    }

    std.log.debug("Recipient rejected: NONE matched whitelist", .{});
    return false;
}

fn extractFrom(msg: *const models.Message, env: *const Envelope, allocator: mem.Allocator) ![]const u8 {
    const raw_from = extractHeader(msg.headers, "from") orelse env.from.address;
    return decodeMimeHeader(raw_from, allocator) catch raw_from;
}

fn extractSubject(msg: *const models.Message, allocator: mem.Allocator) ![]const u8 {
    const raw_subject = extractHeader(msg.headers, "subject") orelse DEFAULT_SUBJECT;
    return decodeMimeHeader(raw_subject, allocator) catch raw_subject;
}

fn extractTo(msg: *const models.Message, env: *const Envelope, allocator: mem.Allocator) ![]const u8 {
    if (extractHeader(msg.headers, "to")) |raw_to| {
        return decodeMimeHeader(raw_to, allocator) catch raw_to;
    }

    if (env.to.len == 0) {
        return DEFAULT_TO;
    }

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    for (env.to, 0..) |addr_obj, idx| {
        if (idx > 0) {
            try buf.appendSlice(allocator, ", ");
        }
        try buf.appendSlice(allocator, addr_obj.address);
    }

    return try buf.toOwnedSlice(allocator);
}

fn extractMetadata(msg: *const models.Message, env: *const Envelope, allocator: mem.Allocator) !Metadata {
    const from = try extractFrom(msg, env, allocator);
    const subject = try extractSubject(msg, allocator);
    const to = try extractTo(msg, env, allocator);

    return Metadata{
        .from = from,
        .to = to,
        .subject = subject,
    };
}

fn sendNotifications(server: *Server, metadata: Metadata) void {
    server.channels.sendAll(metadata, MAX_NOTIFICATION_RETRIES);
}

pub fn processPayload(server: *Server, body: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(server.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const parsed = json.parseFromSlice(MTARequest, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.err("JSON parse error: {}", .{err});
        return;
    };

    const payload = parsed.value;
    const env = &payload.envelope;
    const msg = &payload.message;

    if (!isAllowedRcpt(server.cfg, env)) {
        std.log.info("Skipped email for non-whitelisted recipient", .{});
        return;
    }

    const metadata = extractMetadata(msg, env, allocator) catch |err| {
        std.log.err("Failed to extract email metadata: {}", .{err});
        return;
    };

    std.log.debug("Processing email - From: {s}, To: {s}, Subject: {s}", .{ metadata.from, metadata.to, metadata.subject });

    sendNotifications(server, metadata);
}

pub fn processPayloadThread(server: *Server, body: []u8) void {
    defer server.allocator.free(body);
    processPayload(server, body);
}

pub fn handleRoot(server: *Server, req: *httpz.Request, res: *httpz.Response) !void {
    _ = server;
    _ = req;

    res.status = 200;
    res.body = "/";
}

pub fn handleNotify(server: *Server, req: *httpz.Request, res: *httpz.Response) !void {
    if (req.method != .POST) {
        res.status = 405;
        res.body = "method not allowed";
        return;
    }

    if (server.cfg.auth_token.len > 0) {
        const maybe_auth = req.header("x-notify-auth");

        if (maybe_auth) |auth_val| {
            const trimmed = mem.trim(u8, auth_val, " \t\r\n");
            if (!mem.eql(u8, trimmed, server.cfg.auth_token)) {
                std.log.warn("auth failed: invalid token '{s}'", .{trimmed});
                res.status = 200;
                try res.json(.{ .action = "accept" }, .{});
                return;
            }
        } else {
            std.log.warn("auth failed: missing X-Notify-Auth header", .{});
            res.status = 200;
            try res.json(.{ .action = "accept" }, .{});
            return;
        }

        std.log.debug("auth success for request", .{});
    }

    const maybe_body = req.body();

    try res.json(.{ .action = "accept" }, .{});

    if (maybe_body) |body| {
        const body_copy = server.allocator.dupe(u8, body) catch |err| {
            std.log.err("Failed to allocate memory for body copy: {}", .{err});
            return;
        };

        var t = std.Thread.spawn(.{}, processPayloadThread, .{ server, body_copy }) catch |err| {
            std.log.err("Failed to spawn processing thread: {}", .{err});
            server.allocator.free(body_copy);
            return;
        };

        t.detach();
    } else {
        std.log.warn("empty body", .{});
    }
}

pub fn handleHealth(server: *Server, req: *httpz.Request, res: *httpz.Response) !void {
    _ = server;
    _ = req;
    try res.json(.{ .status = "online" }, .{});
}

pub fn run(server: *Server, sigset: posix.sigset_t) !void {
    const addr = server.cfg.addr();
    var http_server = try httpz.Server(*Server).init(
        server.allocator,
        .{ .address = addr.host, .port = addr.port },
        server,
    );
    defer {
        http_server.deinit();
    }

    var router = try http_server.router(.{});
    router.get("/", handleRoot, .{});
    router.post("/notify", handleNotify, .{});
    router.get("/health", handleHealth, .{});

    var sig_thread = try std.Thread.spawn(.{}, signalWatcher, .{ &http_server, sigset });
    defer sig_thread.join();

    try http_server.listen();
}
