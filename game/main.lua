-- game/main.lua
-- Multiple cubes driven by ECS.

local ecs = require("ecs")
local world = ecs.world()

function init()
  gammo.set_clear_color(0.08, 0.08, 0.12)
  gammo.set_camera(0, 8, 12, 0, 0, 0)

  -- Spawn a grid of cubes
  for x = -2, 2 do
    for z = -2, 2 do
      world:spawn({
        position = { x = x * 2, y = 0, z = z * 2 },
        rotation = { x = 0, y = math.random() * 360, z = 0 },
        spin = { speed = 30 + math.random() * 60 },
        mesh = "cube",
      })
    end
  end

  -- Spawn a player cube (bigger spin, starts at origin)
  player = world:spawn({
    position = { x = 0, y = 0.5, z = 0 },
    rotation = { x = 0, y = 0, z = 0 },
    spin = { speed = 120 },
    mesh = "cube",
    player = true,
  })

  print("gammo ECS is alive! " .. 26 .. " entities spawned.")
end

-- Systems

local function spin_system(dt)
  for e, rot, spin in world:query("rotation", "spin") do
    rot.y = rot.y + spin.speed * dt
  end
end

local function player_system(dt)
  local speed = 5
  for e, pos in world:query("position", "player") do
    if gammo.key_down("Left")  then pos.x = pos.x - speed * dt end
    if gammo.key_down("Right") then pos.x = pos.x + speed * dt end
    if gammo.key_down("Up")    then pos.z = pos.z - speed * dt end
    if gammo.key_down("Down")  then pos.z = pos.z + speed * dt end
  end
end

function update(dt)
  spin_system(dt)
  player_system(dt)
end

function draw()
  for e, pos, rot, mesh in world:query("position", "rotation", "mesh") do
    gammo.draw_mesh(mesh, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z)
  end
end
