const std = @import("std");
const mem = std.mem;

const cfg_mod = @import("config.zig");
const Config = cfg_mod.Config;
const loadConfig = cfg_mod.loadConfig;

const app_mod = @import("app.zig");
const App = app_mod.App;
const channels_mod = @import("channels.zig");
const Channels = channels_mod.Channels;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tsa = std.heap.ThreadSafeAllocator{
        .child_allocator = gpa.allocator(),
    };
    const allocator = tsa.allocator();

    var cfg = try loadConfig(allocator);

    var http_client = std.http.Client{ .allocator = allocator };
    defer http_client.deinit();

    var app = App{
        .allocator = allocator,
        .cfg = cfg,
        .channels = Channels{
            .ntfy = .{
                .allocator = allocator,
                .cfg = &cfg,
                .client = &http_client,
            },
            .ding = .{
                .allocator = allocator,
                .cfg = &cfg,
                .client = &http_client,
            },
            .tg = .{
                .allocator = allocator,
                .cfg = &cfg,
                .client = &http_client,
            },
        },
    };

    std.log.info("===========================================", .{});
    std.log.info("Email Notification Service Started", .{});
    std.log.info("===========================================", .{});
    if (cfg.auth_token.len > 0) {
        std.log.info("Authentication: Enabled (header: x-notify-auth)", .{});
    } else {
        std.log.warn("Authentication: Disabled (Recommended for production)", .{});
    }

    std.log.info("Notification Channels: \"{s}\"", .{cfg.enabled_channels});

    if (mem.trim(u8, cfg.allowed_rcpts, " \t\r\n").len > 0) {
        std.log.info("Recipient Whitelist: configured via ALLOWED_RCPTS", .{});
    } else {
        std.log.info("Recipient Whitelist: All emails", .{});
    }
    std.log.info("Listen Address: {s}", .{cfg.bind_addr});
    std.log.info("===========================================", .{});

    try app.run();
}
