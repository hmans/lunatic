-- game/main.lua
-- Systems registered via lunatic.system(). Queries via lunatic.query().
-- Component refs via lunatic.ref() for natural field access.

-- Setup
lunatic.set_clear_color(0.55, 0.7, 0.85)
lunatic.set_ambient(0.15, 0.15, 0.25)
lunatic.set_fog(8, 50, 0.55, 0.7, 0.85)

-- Main camera (fullscreen)
local cam1 = lunatic.spawn()
lunatic.add(cam1, "position", 0, 8, 12)
lunatic.add(cam1, "rotation", 34, 0, 0)
lunatic.add(cam1, "camera", 60, 0.1, 100, 0, 0, 1, 1)

-- Minimap camera (top-right corner, top-down)
local cam2 = lunatic.spawn()
lunatic.add(cam2, "position", 0, 25, 0.1)
lunatic.add(cam2, "rotation", 89, 0, 0)
lunatic.add(cam2, "camera", 50, 0.1, 100, 0.73, 0.02, 0.25, 0.25)

-- Directional light
local light = lunatic.spawn()
lunatic.add(light, "directional_light", 0.3, 0.8, 0.5, 1, 1, 1)

-- Materials (create_material returns a numeric handle)
local red    = lunatic.create_material({ albedo = { 0.9, 0.2, 0.2 } })
local green  = lunatic.create_material({ albedo = { 0.2, 0.8, 0.3 } })
local blue   = lunatic.create_material({ albedo = { 0.2, 0.3, 0.9 } })
local yellow = lunatic.create_material({ albedo = { 0.9, 0.8, 0.2 } })

local materials = { lunatic.material.default, red, green, blue, yellow }
local meshes = { lunatic.mesh.cube, lunatic.mesh.sphere }

-- Spawn a grid of shapes
for x = -4, 4 do
  for z = -4, 4 do
    local e = lunatic.spawn()
    lunatic.add(e, "position", x * 2, 0, z * 2)
    lunatic.add(e, "rotation", 0, math.random() * 360, 0)
    lunatic.add(e, "spin", 30 + math.random() * 60)
    lunatic.add(e, "mesh", meshes[math.random(#meshes)])
    lunatic.add(e, "material", materials[math.random(#materials)])
  end
end

-- Player sphere
local e = lunatic.spawn()
lunatic.add(e, "position", 0, 0.5, 0)
lunatic.add(e, "rotation", 0, 0, 0)
lunatic.add(e, "spin", 120)
lunatic.add(e, "mesh", lunatic.mesh.sphere)
lunatic.add(e, "material", yellow)
lunatic.add(e, "player")

-- Spin system
lunatic.system("spin", function(dt)
  for _, e in ipairs(lunatic.query("rotation", "spin")) do
    local rot = lunatic.ref(e, "rotation")
    local spin = lunatic.ref(e, "spin")
    rot.y = rot.y + spin.speed * dt
  end
end)

-- Player movement system
lunatic.system("player_movement", function(dt)
  local speed = 5
  for _, e in ipairs(lunatic.query("player", "position")) do
    local pos = lunatic.ref(e, "position")
    if lunatic.key_down("Left")  then pos.x = pos.x - speed * dt end
    if lunatic.key_down("Right") then pos.x = pos.x + speed * dt end
    if lunatic.key_down("Up")    then pos.z = pos.z - speed * dt end
    if lunatic.key_down("Down")  then pos.z = pos.z + speed * dt end
  end
end)
