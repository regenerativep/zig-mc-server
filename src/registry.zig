const std = @import("std");

const mcp = @import("mcp");
const mcio = mcp.packetio;
const mcv = mcp.vlatest;

// damage type js gen
//for(let i = 0; i < data.length; i += 1) {
//    let item = data[i];
//    console.log(".{");
//    console.log(".name = \"" + item.name + "\",");
//    console.log(".id = " + item.id + ",");
//    console.log(".element = .{");
//    console.log(".message_id = \"" + item.element.message_id + "\",");
//    console.log(".scaling = ." + item.element.scaling + ",");
//    console.log(".exhaustion = " + item.element.exhaustion + ",");
//    if(typeof item.effects !== "undefined") {
//        console.log(".effects = ." + item.element.effects + ",");
//    }
//    if(typeof item.death_message_type !== "undefined") {
//        console.log(".death_message_type = ." + item.element.death_message_type + ",");
//    }
//    console.log("},");
//    console.log("},");
//}
pub const DefaultRegistry = mcv.RegistryData.UT{
    .trim_material = .{ .value = &.{} },
    .trim_pattern = .{ .value = &.{} },
    .damage_type = .{ .value = &.{
        .{
            .name = "minecraft:arrow",
            .id = 0,
            .element = .{
                .message_id = "arrow",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:bad_respawn_point",
            .id = 1,
            .element = .{
                .message_id = "badRespawnPoint",
                .scaling = .always,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:cactus",
            .id = 2,
            .element = .{
                .message_id = "cactus",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:cramming",
            .id = 3,
            .element = .{
                .message_id = "cramming",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0,
            },
        },
        .{
            .name = "minecraft:dragon_breath",
            .id = 4,
            .element = .{
                .message_id = "dragonBreath",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0,
            },
        },
        .{
            .name = "minecraft:drown",
            .id = 5,
            .element = .{
                .message_id = "drown",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0,
            },
        },
        .{
            .name = "minecraft:dry_out",
            .id = 6,
            .element = .{
                .message_id = "dryout",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:explosion",
            .id = 7,
            .element = .{
                .message_id = "explosion",
                .scaling = .always,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:fall",
            .id = 8,
            .element = .{
                .message_id = "fall",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0,
            },
        },
        .{
            .name = "minecraft:falling_anvil",
            .id = 9,
            .element = .{
                .message_id = "anvil",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:falling_block",
            .id = 10,
            .element = .{
                .message_id = "fallingBlock",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:falling_stalactite",
            .id = 11,
            .element = .{
                .message_id = "fallingStalactite",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:fireball",
            .id = 12,
            .element = .{
                .message_id = "fireball",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:fireworks",
            .id = 13,
            .element = .{
                .message_id = "fireworks",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:fly_into_wall",
            .id = 14,
            .element = .{
                .message_id = "flyIntoWall",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0,
            },
        },
        .{
            .name = "minecraft:freeze",
            .id = 15,
            .element = .{
                .message_id = "freeze",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0,
            },
        },
        .{
            .name = "minecraft:generic",
            .id = 16,
            .element = .{
                .message_id = "generic",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0,
            },
        },
        .{
            .name = "minecraft:generic_kill",
            .id = 17,
            .element = .{
                .message_id = "genericKill",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0,
            },
        },
        .{
            .name = "minecraft:hot_floor",
            .id = 18,
            .element = .{
                .message_id = "hotFloor",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:in_fire",
            .id = 19,
            .element = .{
                .message_id = "inFire",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:in_wall",
            .id = 20,
            .element = .{
                .message_id = "inWall",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0,
            },
        },
        .{
            .name = "minecraft:indirect_magic",
            .id = 21,
            .element = .{
                .message_id = "indirectMagic",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0,
            },
        },
        .{
            .name = "minecraft:lava",
            .id = 22,
            .element = .{
                .message_id = "lava",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:lightning_bolt",
            .id = 23,
            .element = .{
                .message_id = "lightningBolt",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:magic",
            .id = 24,
            .element = .{
                .message_id = "magic",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0,
            },
        },
        .{
            .name = "minecraft:mob_attack",
            .id = 25,
            .element = .{
                .message_id = "mob",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:mob_attack_no_aggro",
            .id = 26,
            .element = .{
                .message_id = "mob",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:mob_projectile",
            .id = 27,
            .element = .{
                .message_id = "mob",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:on_fire",
            .id = 28,
            .element = .{
                .message_id = "onFire",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0,
            },
        },
        .{
            .name = "minecraft:out_of_world",
            .id = 29,
            .element = .{
                .message_id = "outOfWorld",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0,
            },
        },
        .{
            .name = "minecraft:outside_border",
            .id = 30,
            .element = .{
                .message_id = "outsideBorder",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0,
            },
        },
        .{
            .name = "minecraft:player_attack",
            .id = 31,
            .element = .{
                .message_id = "player",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:player_explosion",
            .id = 32,
            .element = .{
                .message_id = "explosion.player",
                .scaling = .always,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:sonic_boom",
            .id = 33,
            .element = .{
                .message_id = "sonic_boom",
                .scaling = .always,
                .exhaustion = 0,
            },
        },
        .{
            .name = "minecraft:stalagmite",
            .id = 34,
            .element = .{
                .message_id = "stalagmite",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0,
            },
        },
        .{
            .name = "minecraft:starve",
            .id = 35,
            .element = .{
                .message_id = "starve",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0,
            },
        },
        .{
            .name = "minecraft:sting",
            .id = 36,
            .element = .{
                .message_id = "sting",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:sweet_berry_bush",
            .id = 37,
            .element = .{
                .message_id = "sweetBerryBush",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:thorns",
            .id = 38,
            .element = .{
                .message_id = "thorns",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:thrown",
            .id = 39,
            .element = .{
                .message_id = "thrown",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:trident",
            .id = 40,
            .element = .{
                .message_id = "trident",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:unattributed_fireball",
            .id = 41,
            .element = .{
                .message_id = "onFire",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
        .{
            .name = "minecraft:wither",
            .id = 42,
            .element = .{
                .message_id = "wither",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0,
            },
        },
        .{
            .name = "minecraft:wither_skull",
            .id = 43,
            .element = .{
                .message_id = "witherSkull",
                .scaling = .when_caused_by_living_non_player,
                .exhaustion = 0.1,
            },
        },
    } },
    .biome = .{ .value = &.{.{
        .name = "minecraft:plains",
        .id = 0,
        .element = .{
            .has_precipitation = true,
            .temperature = 0.8,
            .downfall = 0.4,
            .effects = .{
                .sky_color = 0x78A7FF,
                .water_fog_color = 0x050533,
                .fog_color = 0xC0D8FF,
                .water_color = 0x3F76E4,
                .mood_sound = .{
                    .tick_delay = 6000,
                    .offset = 2.0,
                    .sound = "minecraft:ambient.cave",
                    .block_search_extent = 8,
                },
            },
        },
    }} },
    .chat_type = .{
        .value = &.{.{
            .name = "minecraft:chat",
            .id = 0,
            .element = .{
                .chat = .{
                    .translation_key = "chat.type.text",
                    .parameters = &.{ .sender, .content },
                },
                .narration = .{
                    .translation_key = "chat.type.text.narrate",
                    .parameters = &.{ .sender, .content },
                },
            },
        }},
    },
    .dimension_type = .{ .value = &.{.{
        .name = "minecraft:overworld",
        .id = 0,
        .element = .{
            .piglin_safe = false,
            .natural = true,
            .ambient_light = 0.0,
            .monster_spawn_block_light_limit = 0,
            .infiniburn = "#minecraft:infiniburn_overworld",
            .respawn_anchor_works = false,
            .has_skylight = true,
            .bed_works = true,
            .effects = .overworld,
            .has_raids = true,
            .logical_height = mcp.chunk.HEIGHT,
            .coordinate_scale = 1.0,
            .monster_spawn_light_level = .{ .compound = .{
                .type = .uniform,
                .value = .{ .min_inclusive = 0, .max_inclusive = 7 },
            } },
            .min_y = mcp.chunk.MIN_Y,
            .ultrawarm = false,
            .has_ceiling = false,
            .height = mcp.chunk.HEIGHT,
        },
    }} },
};

test "default registry" {
    @setEvalBranchQuota(10_000);
    try mcp.nbt.doDynamicTestOnValue(mcv.RegistryData, DefaultRegistry, true, false);
}
