const std = @import("std");
const mem = std.mem;
const json = std.json;

const Config = @import("config.zig").Config;
const Metadata = @import("models.zig").Metadata;

fn httpPost(
    allocator: mem.Allocator,
    endpoint: []const u8,
    body: []const u8,
    headers: []const std.http.Header,
) !std.http.Status {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const result = try client.fetch(.{
        .method = .POST,
        .location = .{ .url = endpoint },
        .extra_headers = headers,
        .payload = body,
        .keep_alive = false,
    });

    return result.status;
}

pub const NtfyNotifier = struct {
    pub fn enabled(cfg: *const Config) bool {
        return cfg.channels.ntfy and cfg.ntfy_topic.len > 0;
    }

    pub fn send(
        self: *NtfyNotifier,
        allocator: mem.Allocator,
        cfg: *const Config,
        metadata: Metadata,
    ) !void {
        _ = self;

        if (!enabled(cfg)) return;

        const server_trimmed = mem.trimRight(u8, cfg.ntfy_server, "/");
        const url_str = try std.fmt.allocPrint(allocator, "{s}/{s}", .{
            server_trimmed,
            cfg.ntfy_topic,
        });
        defer allocator.free(url_str);

        const body = try std.fmt.allocPrint(
            allocator,
            "From: {s}\nTo: {s}",
            .{ metadata.from, metadata.to },
        );
        defer allocator.free(body);

        var hdrs: [4]std.http.Header = undefined;
        var hdr_count: usize = 0;

        hdrs[hdr_count] = .{ .name = "Title", .value = metadata.subject };
        hdr_count += 1;

        hdrs[hdr_count] = .{ .name = "Priority", .value = "default" };
        hdr_count += 1;

        hdrs[hdr_count] = .{ .name = "Tags", .value = "email" };
        hdr_count += 1;

        var auth_buf: ?[]u8 = null;
        if (cfg.ntfy_token.len > 0) {
            auth_buf = try std.fmt.allocPrint(allocator, "Bearer {s}", .{cfg.ntfy_token});
            hdrs[hdr_count] = .{ .name = "Authorization", .value = auth_buf.? };
            hdr_count += 1;
        }
        defer if (auth_buf) |b| allocator.free(b);

        const status = try httpPost(allocator, url_str, body, hdrs[0..hdr_count]);
        if (status != .ok) {
            std.log.err("Ntfy notification failed: {}", .{status});
            return error.NotificationFailed;
        }
    }
};

pub const DingTalkNotifier = struct {
    const TextContent = struct {
        content: []const u8,
    };

    const DingTalkPayload = struct {
        msgtype: []const u8,
        text: TextContent,
    };

    pub fn enabled(cfg: *const Config) bool {
        return cfg.channels.ding and cfg.ding_webhook.len > 0;
    }

    pub fn send(
        self: *DingTalkNotifier,
        allocator: mem.Allocator,
        cfg: *const Config,
        metadata: Metadata,
    ) !void {
        _ = self;

        if (!enabled(cfg)) return;

        const text = try std.fmt.allocPrint(
            allocator,
            "📧 New Email Received\nFrom: {s}\nTo: {s}\nSubject: {s}",
            .{ metadata.from, metadata.to, metadata.subject },
        );
        defer allocator.free(text);

        const payload = DingTalkPayload{
            .msgtype = "text",
            .text = .{ .content = text },
        };

        const body = try json.Stringify.valueAlloc(allocator, payload, .{});
        defer allocator.free(body);

        var headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        const status = try httpPost(allocator, cfg.ding_webhook, body, headers[0..]);
        if (status != .ok) {
            std.log.err("DingTalk notification failed: {}", .{status});
            return error.NotificationFailed;
        }
    }
};

pub const TelegramNotifier = struct {
    const TelegramPayload = struct {
        chat_id: []const u8,
        text: []const u8,
    };

    pub fn enabled(cfg: *const Config) bool {
        return cfg.channels.tg and cfg.telegram_bot_token.len > 0 and cfg.telegram_chat_id.len > 0;
    }

    pub fn send(
        self: *TelegramNotifier,
        allocator: mem.Allocator,
        cfg: *const Config,
        metadata: Metadata,
    ) !void {
        _ = self;

        if (!enabled(cfg)) return;

        const url = try std.fmt.allocPrint(
            allocator,
            "https://api.telegram.org/bot{s}/sendMessage",
            .{cfg.telegram_bot_token},
        );
        defer allocator.free(url);

        const text = try std.fmt.allocPrint(
            allocator,
            "📧 New Email Received\nFrom: {s}\nTo: {s}\nSubject: {s}",
            .{ metadata.from, metadata.to, metadata.subject },
        );
        defer allocator.free(text);

        const payload = TelegramPayload{
            .chat_id = cfg.telegram_chat_id,
            .text = text,
        };

        const body = try json.Stringify.valueAlloc(allocator, payload, .{});
        defer allocator.free(body);

        var headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        const status = try httpPost(allocator, url, body, headers[0..]);
        if (status != .ok) {
            std.log.err("Telegram notification failed: {}", .{status});
            return error.NotificationFailed;
        }
    }
};

fn sendWithRetry(
    name: []const u8,
    max_retries: u8,
    comptime F: anytype,
    args: anytype,
) void {
    var attempt: u8 = 0;

    while (attempt < max_retries) : (attempt += 1) {
        if (@call(.auto, F, args)) |_| {
            std.log.info("{s} notification sent (attempt {d})", .{ name, attempt + 1 });
            return;
        } else |err| {
            std.log.err(
                "{s} failed (attempt {d}/{d}): {}",
                .{ name, attempt + 1, max_retries, err },
            );

            if (attempt + 1 == max_retries) {
                std.log.err("{s} giving up after {d} attempts", .{ name, max_retries });
                return;
            }

            const delay_ms: u64 = 500 * @as(u64, attempt + 1);
            const delay_ns: u64 = delay_ms * std.time.ns_per_ms;

            std.log.info("{s} retrying in {d} ms…", .{ name, delay_ms });

            std.posix.nanosleep(0, delay_ns);
        }
    }
}

pub const Channels = struct {
    allocator: mem.Allocator,
    cfg: *Config,

    ntfy: NtfyNotifier = .{},
    ding: DingTalkNotifier = .{},
    tg: TelegramNotifier = .{},

    pub fn init(allocator: mem.Allocator, cfg: *Config) Channels {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .ntfy = .{},
            .ding = .{},
            .tg = .{},
        };
    }

    pub fn sendAll(
        self: *Channels,
        metadata: Metadata,
        max_retries: u8,
    ) void {
        const allocator = self.allocator;
        const cfg = self.cfg;

        if (NtfyNotifier.enabled(cfg)) {
            sendWithRetry(
                "ntfy",
                max_retries,
                NtfyNotifier.send,
                .{ &self.ntfy, allocator, cfg, metadata },
            );
        }

        if (DingTalkNotifier.enabled(cfg)) {
            sendWithRetry(
                "dingtalk",
                max_retries,
                DingTalkNotifier.send,
                .{ &self.ding, allocator, cfg, metadata },
            );
        }

        if (TelegramNotifier.enabled(cfg)) {
            sendWithRetry(
                "telegram",
                max_retries,
                TelegramNotifier.send,
                .{ &self.tg, allocator, cfg, metadata },
            );
        }
    }
};
