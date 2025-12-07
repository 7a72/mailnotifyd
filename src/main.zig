const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const builtin = @import("builtin");
const httpz = @import("httpz");

const cfg_mod = @import("config.zig");
const Config = cfg_mod.Config;
const loadConfig = cfg_mod.loadConfig;

const server_mod = @import("server.zig");
const Server = server_mod.Server;
const channels_mod = @import("channels.zig");
const Channels = channels_mod.Channels;

fn validateAndLogConfig(cfg: *const Config) !void {
    var enabled_count: u8 = 0;

    std.log.info("===========================================", .{});
    std.log.info("Email Notification Service Started", .{});
    std.log.info("===========================================", .{});

    std.log.info("Notification Channels:", .{});

    if (channels_mod.NtfyNotifier.enabled(cfg)) {
        std.log.info("  Ntfy:     {s}/{s}", .{ cfg.ntfy_server, cfg.ntfy_topic });
        enabled_count += 1;
    } else {
        std.log.info("  Ntfy:     Disabled", .{});
    }

    if (channels_mod.DingTalkNotifier.enabled(cfg)) {
        std.log.info("  DingTalk: Webhook configured", .{});
        enabled_count += 1;
    } else {
        std.log.info("  DingTalk: Disabled", .{});
    }

    if (channels_mod.TelegramNotifier.enabled(cfg)) {
        std.log.info("  Telegram: Chat ID {s}", .{cfg.telegram_chat_id});
        enabled_count += 1;
    } else {
        std.log.info("  Telegram: Disabled", .{});
    }

    if (enabled_count == 0) {
        std.log.err("No notification channels enabled!", .{});
        std.log.err("  Please configure at least one channel via ENABLED_CHANNELS", .{});
        return error.NoChannelsEnabled;
    }

    std.log.info("-------------------------------------------", .{});

    if (cfg.auth_token.len > 0) {
        std.log.info("Authentication: Enabled (X-Notify-Auth)", .{});
    } else {
        std.log.warn("Authentication: Disabled", .{});
        std.log.warn("  Recommendation: Set AUTH_TOKEN for production", .{});
    }

    if (cfg.allowed_rcpts.len > 0) {
        std.log.info("Recipient Filter: Whitelist active", .{});
        for (cfg.allowed_rcpts) |rcpt| {
            std.log.debug("  Allowed: {s}", .{rcpt});
        }
    } else {
        std.log.info("Recipient Filter: All", .{});
    }

    std.log.info("Listen Address: {s}", .{cfg.bind_addr});
    std.log.info("===========================================", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leak detected!", .{});
        }
    }

    var tsa = std.heap.ThreadSafeAllocator{
        .child_allocator = gpa.allocator(),
    };
    const allocator = tsa.allocator();

    var sigset = posix.sigemptyset();

    posix.sigaddset(&sigset, posix.SIG.INT);
    posix.sigaddset(&sigset, posix.SIG.TERM);

    posix.sigprocmask(posix.SIG.BLOCK, &sigset, null);

    var cfg = try loadConfig(allocator);
    defer cfg.deinit(allocator);

    var server = Server{
        .allocator = allocator,
        .cfg = &cfg,
        .channels = Channels.init(allocator, &cfg),
    };

    try validateAndLogConfig(&cfg);

    try server_mod.run(&server, sigset);

    std.log.info("Cleanup done.", .{});
}
