const std = @import("std");
const mem = std.mem;
const json = std.json;

const Config = @import("config.zig").Config;

pub fn channelEnabled(list: []const u8, name: []const u8) bool {
    if (list.len == 0) return false;
    var it = mem.splitScalar(u8, list, ',');
    while (it.next()) |part| {
        const trimmed = mem.trim(u8, part, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(trimmed, name)) return true;
    }
    return false;
}

fn httpPost(
    client: *std.http.Client,
    endpoint: []const u8,
    body: []const u8,
    headers: []const std.http.Header,
) !std.http.Status {
    const result = try client.fetch(.{
        .method = .POST,
        .location = .{ .url = endpoint },
        .extra_headers = headers,
        .payload = body,
        .keep_alive = true,
    });
    return result.status;
}

pub const NtfyNotifier = struct {
    allocator: mem.Allocator,
    cfg: *const Config,
    client: *std.http.Client,

    pub fn enabled(self: *const NtfyNotifier) bool {
        return channelEnabled(self.cfg.enabled_channels, "ntfy") and self.cfg.ntfy_topic.len > 0;
    }

    pub fn send(
        self: *NtfyNotifier,
        from: []const u8,
        to: []const u8,
        subject: []const u8,
    ) !void {
        if (!self.enabled()) return;

        const allocator = self.allocator;

        const server_trimmed = mem.trimRight(u8, self.cfg.ntfy_server, "/");
        const url_str = try std.fmt.allocPrint(allocator, "{s}/{s}", .{
            server_trimmed,
            self.cfg.ntfy_topic,
        });
        defer allocator.free(url_str);

        const body = try std.fmt.allocPrint(
            allocator,
            "From: {s}\nTo: {s}",
            .{ from, to },
        );
        defer allocator.free(body);

        var hdrs: [4]std.http.Header = undefined;
        var hdr_count: usize = 0;

        hdrs[hdr_count] = .{ .name = "Title", .value = subject };
        hdr_count += 1;

        hdrs[hdr_count] = .{ .name = "Priority", .value = "default" };
        hdr_count += 1;

        hdrs[hdr_count] = .{ .name = "Tags", .value = "email" };
        hdr_count += 1;

        var auth_buf: ?[]u8 = null;
        if (self.cfg.ntfy_token.len > 0) {
            auth_buf = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.cfg.ntfy_token});
            hdrs[hdr_count] = .{ .name = "Authorization", .value = auth_buf.? };
            hdr_count += 1;
        }
        defer if (auth_buf) |b| allocator.free(b);

        const status = try httpPost(self.client, url_str, body, hdrs[0..hdr_count]);
        if (status != .ok) {
            std.log.err("Ntfy notification failed: {}", .{status});
            return error.NotificationFailed;
        }
    }
};

pub const DingTalkNotifier = struct {
    allocator: mem.Allocator,
    cfg: *const Config,
    client: *std.http.Client,

    const TextContent = struct {
        content: []const u8,
    };

    const DingTalkPayload = struct {
        msgtype: []const u8,
        text: TextContent,
    };

    pub fn enabled(self: *const DingTalkNotifier) bool {
        return channelEnabled(self.cfg.enabled_channels, "ding") and self.cfg.ding_webhook.len > 0;
    }

    pub fn send(self: *DingTalkNotifier, text: []const u8) !void {
        if (!self.enabled()) return;

        const allocator = self.allocator;

        const payload = DingTalkPayload{
            .msgtype = "text",
            .text = .{ .content = text },
        };

        const body = try json.Stringify.valueAlloc(
            allocator,
            payload,
            .{},
        );
        defer allocator.free(body);

        var headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        const status = try httpPost(self.client, self.cfg.ding_webhook, body, headers[0..]);
        if (status != .ok) {
            std.log.err("DingTalk notification failed: {}", .{status});
            return error.NotificationFailed;
        }
    }
};

pub const TelegramNotifier = struct {
    allocator: mem.Allocator,
    cfg: *const Config,
    client: *std.http.Client,

    const TelegramPayload = struct {
        chat_id: []const u8,
        text: []const u8,
    };

    pub fn enabled(self: *const TelegramNotifier) bool {
        return channelEnabled(self.cfg.enabled_channels, "tg") and self.cfg.telegram_bot_token.len > 0 and self.cfg.telegram_chat_id.len > 0;
    }

    pub fn send(self: *TelegramNotifier, text: []const u8) !void {
        if (!self.enabled()) return;

        const allocator = self.allocator;

        const url = try std.fmt.allocPrint(
            allocator,
            "https://api.telegram.org/bot{s}/sendMessage",
            .{self.cfg.telegram_bot_token},
        );
        defer allocator.free(url);

        const payload = TelegramPayload{
            .chat_id = self.cfg.telegram_chat_id,
            .text = text,
        };

        const body = try json.Stringify.valueAlloc(
            allocator,
            payload,
            .{},
        );
        defer allocator.free(body);

        var headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        const status = try httpPost(self.client, url, body, headers[0..]);
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

            std.log.info("{s} retrying in {d} ms …", .{ name, delay_ms });

            std.posix.nanosleep(0, delay_ns);
        }
    }
}

pub const Channels = struct {
    ntfy: NtfyNotifier,
    ding: DingTalkNotifier,
    tg: TelegramNotifier,

    pub fn sendAll(
        self: *Channels,
        full_from: []const u8,
        full_to: []const u8,
        subject: []const u8,
        text_for_im: []const u8,
        max_retries: u8,
    ) void {
        if (self.ntfy.enabled()) {
            sendWithRetry(
                "ntfy",
                max_retries,
                NtfyNotifier.send,
                .{ &self.ntfy, full_from, full_to, subject },
            );
        }

        if (self.ding.enabled()) {
            sendWithRetry(
                "ding",
                max_retries,
                DingTalkNotifier.send,
                .{ &self.ding, text_for_im },
            );
        }

        if (self.tg.enabled()) {
            sendWithRetry(
                "telegram",
                max_retries,
                TelegramNotifier.send,
                .{ &self.tg, text_for_im },
            );
        }
    }
};
