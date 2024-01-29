const std = @import("std");
const mem = std.mem;
const meta = std.meta;

const mcp = @import("mcp");
const mcv = mcp.vlatest;

const lib = @import("lib.zig");
const Server = lib.Server;
const Client = lib.Client;

index_id: usize,
id: usize,
uuid: mcv.Uuid.UT = mem.zeroes(mcv.Uuid.UT),
cleanup: Server.Message = undefined,

position: lib.Position,
on_ground: bool = false,
yaw: f32 = 0,
pitch: f32 = 0,

last_position: ?lib.Position = null,
last_on_ground: ?bool = null,
last_yaw: ?f32 = null,
last_pitch: ?f32 = null,

const Self = @This();

pub fn tick(self: *Self, server: *Server) !void {
    defer {
        self.last_on_ground = self.on_ground;
        self.last_pitch = self.pitch;
        self.last_yaw = self.yaw;
        self.last_position = self.position;
    }

    const on_ground = self.last_on_ground == null or
        self.last_on_ground.? != self.on_ground;
    const pos = self.last_position == null or
        !meta.eql(self.last_position.?, self.position);
    var diff: lib.Position = undefined;
    const pos_delta = blk: { // if distance moved is small enough for delta packets
        if (self.last_position != null) {
            diff = .{
                .x = self.position.x - self.last_position.?.x,
                .y = self.position.y - self.last_position.?.y,
                .z = self.position.z - self.last_position.?.z,
            };
            break :blk diff.x >= -8 and diff.x < 8 and
                diff.y >= -8 and diff.y < 8 and
                diff.z >= -8 and diff.z < 8;
        } else {
            break :blk false;
        }
    };

    const rot = (self.last_yaw == null or self.last_yaw.? != self.yaw) or
        (self.last_pitch == null or self.last_pitch.? != self.pitch);

    if (!rot and !pos and !on_ground) return;

    // TODO: we can determine max packet size at comptime, and we can throw it in
    //     a local buffer before sending to all clients rather than serialize again for
    //     each client
    const packet: mcv.P.CB.UT =
        if (!pos_delta)
        .{ .teleport_entity = .{
            .entity_id = @intCast(self.id),
            .position = .{
                .x = self.position.x,
                .y = self.position.y,
                .z = self.position.z,
            },
            .yaw = mcv.Angle.fromF32(self.yaw),
            .pitch = mcv.Angle.fromF32(self.pitch),
            .on_ground = self.on_ground,
        } }
    else if (pos and rot)
        .{ .update_entity_position_and_rotation = .{
            .entity_id = @intCast(self.id),
            .delta = .{
                .x = @intFromFloat(diff.x * 4096),
                .y = @intFromFloat(diff.y * 4096),
                .z = @intFromFloat(diff.z * 4096),
            },
            .yaw = mcv.Angle.fromF32(self.yaw),
            .pitch = mcv.Angle.fromF32(self.pitch),
            .on_ground = self.on_ground,
        } }
    else if (pos)
        .{ .update_entity_position = .{
            .entity_id = @intCast(self.id),
            .delta = .{
                .x = @intFromFloat(diff.x * 4096),
                .y = @intFromFloat(diff.y * 4096),
                .z = @intFromFloat(diff.z * 4096),
            },
            .on_ground = self.on_ground,
        } }
    else
        // this is also used for on_ground update
        .{ .update_entity_rotation = .{
            .entity_id = @intCast(self.id),
            .yaw = mcv.Angle.fromF32(self.yaw),
            .pitch = mcv.Angle.fromF32(self.pitch),
            .on_ground = self.on_ground,
        } };
    const head_packet: ?mcv.P.CB.UT = if (rot) .{ .set_head_rotation = .{
        .entity_id = @intCast(self.id),
        .head_yaw = mcv.Angle.fromF32(self.yaw),
    } } else null;
    //std.debug.print("sending {s}\n", .{@tagName(packet)});

    var iter = server.clients.iterator(0);
    while (iter.next()) |cl| {
        if (cl.canSendPlay() and cl.entity != null and cl.entity != self) {
            try cl.sendPacket(mcv.P.CB, packet);
            if (head_packet) |p| try cl.sendPacket(mcv.P.CB, p);
        }
    }
}

pub fn sendSpawn(self: *Self, cl: *Client) !void {
    try cl.sendPacket(mcv.P.CB, .{
        .spawn_entity = .{
            .entity_id = @intCast(self.id),
            .entity_uuid = self.uuid,
            .type = .player,
            .position = .{
                .x = self.position.x,
                .y = self.position.y,
                .z = self.position.z,
            },
            .yaw = mcv.Angle.fromF32(self.yaw),
            .pitch = mcv.Angle.fromF32(self.pitch),
            // TODO: head yaw
            .head_yaw = mcv.Angle.fromF32(self.yaw),
            .data = 0,
            .velocity = .{ .x = 0, .y = 0, .z = 0 },
        },
    });
}

pub fn deinit(self: *Self, _: std.mem.Allocator) void {
    self.* = undefined;
}
