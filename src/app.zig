const std = @import("std");
const mem = std.mem;
const json = std.json;
const httpz = @import("httpz");

const models = @import("models.zig");
const Header = models.Header;
const Envelope = models.Envelope;
const MTARequest = models.MTARequest;

const mime = @import("mime.zig");
const decodeMimeHeader = mime.decodeMimeHeader;

const Config = @import("config.zig").Config;
const Channels = @import("channels.zig").Channels;

pub const App = struct {
    allocator: mem.Allocator,
    cfg: Config,
    channels: Channels,

    pub fn run(self: *App) !void {
        var server = try httpz.Server(*App).init(
            self.allocator,
            .{ .port = self.cfg.port() },
            self,
        );
        defer {
            server.stop();
            server.deinit();
        }

        var router = try server.router(.{});
        router.post("/", handleRoot, .{});
        router.get("/health", handleHealth, .{});

        try server.listen();
    }
};

fn extractHeader(headers: []const Header, key: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h[0], key)) {
            return h[1];
        }
    }
    return null;
}

fn isAllowedRcpt(cfg: *const Config, env: *const Envelope) bool {
    const allowed_raw = mem.trim(u8, cfg.allowed_rcpts, " \t\r\n");
    if (allowed_raw.len == 0) return true;

    for (env.to) |addr_obj| {
        const addr_trim = mem.trim(u8, addr_obj.address, " \t\r\n");

        var it = mem.splitScalar(u8, allowed_raw, ',');
        while (it.next()) |part| {
            const allow_trim = mem.trim(u8, part, " \t\r\n");
            if (allow_trim.len == 0) continue;

            if (std.ascii.eqlIgnoreCase(addr_trim, allow_trim)) {
                return true;
            }
        }
    }
    return false;
}

pub fn processPayload(app: *App, body: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();

    const parsed = json.parseFromSlice(MTARequest, arena.allocator(), body, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.err("JSON parse error: {}", .{err});
        return;
    };

    const payload = parsed.value;
    const env = &payload.envelope;
    const msg = &payload.message;

    // --- From ---
    const raw_from = extractHeader(msg.headers, "from") orelse env.from.address;
    const full_from = decodeMimeHeader(raw_from, arena.allocator()) catch raw_from;

    // --- Subject ---
    const raw_subject = extractHeader(msg.headers, "subject") orelse "(no subject)";
    const subject = decodeMimeHeader(raw_subject, arena.allocator()) catch raw_subject;

    // --- To ---
    const full_to = blk: {
        if (extractHeader(msg.headers, "to")) |raw_to| {
            const decoded_to = decodeMimeHeader(raw_to, arena.allocator()) catch raw_to;
            break :blk decoded_to;
        } else {
            if (env.to.len == 0) break :blk "";

            var buf = std.array_list.Managed(u8).init(arena.allocator());
            defer buf.deinit();

            for (env.to, 0..) |addr_obj, idx| {
                if (idx > 0) {
                    buf.appendSlice(", ") catch {};
                }
                buf.appendSlice(addr_obj.address) catch {};
            }

            const joined = buf.toOwnedSlice() catch "";
            break :blk joined;
        }
    };

    if (!isAllowedRcpt(&app.cfg, env)) {
        std.log.info("Skipped email for non-whitelisted recipient", .{});
        return;
    }

    const text_for_im = std.fmt.allocPrint(
        arena.allocator(),
        "📧 New Email Received\nFrom: {s}\nTo: {s}\nSubject: {s}",
        .{ full_from, full_to, subject },
    ) catch "from/to/subject";

    const max_retries: u8 = 3;
    app.channels.sendAll(full_from, full_to, subject, text_for_im, max_retries);
}

pub fn processPayloadThread(app: *App, body: []u8) void {
    defer app.allocator.free(body);
    processPayload(app, body);
}

pub fn handleRoot(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (req.method != .POST) {
        res.status = 405;
        res.body = "method not allowed";
        return;
    }

    if (app.cfg.auth_token.len > 0) {
        const maybe_auth = req.header("X-Notify-Auth");
        if (maybe_auth) |auth_val| {
            if (!mem.eql(u8, auth_val, app.cfg.auth_token)) {
                try res.json(.{ .action = "accept" }, .{});
                return;
            }
        } else {
            try res.json(.{ .action = "accept" }, .{});
            return;
        }
    }

    const maybe_body = req.body();

    try res.json(.{ .action = "accept" }, .{});

    if (maybe_body) |body| {
        const body_copy = try app.allocator.dupe(u8, body);
        var t = try std.Thread.spawn(.{}, processPayloadThread, .{ app, body_copy });
        t.detach();
    } else {
        std.log.warn("empty body", .{});
    }
}

pub fn handleHealth(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = app;
    _ = req;

    try res.json(.{
        .status = "online",
    }, .{});
}
