# zig-mc-server

This is a Minecraft server written in the programming language Zig.

The goal of this project is not necessarily to make a Minecraft server, but rather to develop the protocol library and other important parts of a Minecraft server for future projects.

At the moment, a player can join the server, see other players move around, and type in chat.

## building

i use git submodules, sorry

`git clone --recurse-submodules https://github.com/regenerativep/zig-mc-server`

you need to get a `blocks.json` report from a Minecraft server jar. grab a server jar and run

`java -DbundlerMainClass=net.minecraft.data.Main -jar server.jar --reports`

take the `generated/reports/block.json` and put it into a new `data/` folder in your cloned repo

run `zig build-exe generate_blocks.zig && ./generate_blocks`

finally `zig build run`



