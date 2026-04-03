-- game/main.lua
-- Multiple cubes with lighting and fog, driven by ECS.

local ecs = require("ecs")
local world = ecs.world()

function init()
  -- Sky/clear color
  gammo.set_clear_color(0.55, 0.7, 0.85)

  -- Camera
  gammo.set_camera(0, 8, 12, 0, 0, 0)

  -- Lighting
  gammo.set_light(0.3, 0.8, 0.5)
  gammo.set_ambient(0.15, 0.15, 0.25)

  -- Fog — fades to sky color
  gammo.set_fog(8, 25, 0.55, 0.7, 0.85)

  -- Spawn a bigger grid of cubes
  for x = -4, 4 do
    for z = -4, 4 do
      world:spawn({
        position = { x = x * 2, y = 0, z = z * 2 },
        rotation = { x = 0, y = math.random() * 360, z = 0 },
        spin = { speed = 30 + math.random() * 60 },
        mesh = "cube",
      })
    end
  end

  -- Player cube
  player = world:spawn({
    position = { x = 0, y = 0.5, z = 0 },
    rotation = { x = 0, y = 0, z = 0 },
    spin = { speed = 120 },
    mesh = "cube",
    player = true,
  })

  print("gammo is alive! Cubes with lighting and fog.")
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
