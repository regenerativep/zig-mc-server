# zig-mc-server

A 1.20.4 Minecraft server in Zig. You can currently join and see other players move
around.

Uses [zigmcp](https://github.com/regenerativep/zigmcp) for the protocol implementation
and [libxev](https://github.com/mitchellh/libxev) for non-blocking networking.

## Building

Running the server should be a simple `zig build run`. Server configuration at the
    moment is very basic. You can modify the `config.txt` to change the ip and the port
    that the server will run on.


