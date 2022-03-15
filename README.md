# zig-mc-server

This is a Minecraft server written in the programming language Zig.

The goal of this project is not necessarily to make a Minecraft server, but rather to develop the protocol library and other important parts of a Minecraft server for future projects.

At the moment, a player can join the server, see other players move around, and type in chat.

Your server IP localhost:25400

## building

I use git submodules, sorry

`git clone --recurse-submodules https://github.com/regenerativep/zig-mc-server`

You need to get a `blocks.json` report from a Minecraft server jar. Grab a server jar and run:

`java -DbundlerMainClass=net.minecraft.data.Main -jar server.jar --reports --output data`

Make a `src/gen/` folder

Run `zig run scripts/generate_blocks.zig`

Finally `zig build run`



