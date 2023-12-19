# zig-mc-server

A 1.20.2 Minecraft server in Zig. You can currently join and see other players move
around.

Uses [zigmcp](https://github.com/regenerativep/zigmcp) for the protocol implementation
and [libxev](https://github.com/mitchellh/libxev) for non-blocking networking.

## Building

Running the server should be a simple `zig build run`. No control over server
configuration yet, so the server will just start on `127.0.0.1:25565`.


