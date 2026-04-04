-- game/main.lua
-- Systems registered via lunatic.system(). Queries via lunatic.query().
-- Component refs via lunatic.ref() for natural field access.

-- Setup
lunatic.set_clear_color(0.55, 0.7, 0.85)
lunatic.set_ambient(0.15, 0.15, 0.25)
lunatic.set_fog(8, 50, 0.55, 0.7, 0.85)

-- Directional light
local light = lunatic.spawn()
lunatic.add(light, "directional_light", 0.3, 0.8, 0.5, 1, 1, 1)

-- Materials
local red    = lunatic.create_material({ albedo = { 0.9, 0.2, 0.2 } })
local green  = lunatic.create_material({ albedo = { 0.2, 0.8, 0.3 } })
local blue   = lunatic.create_material({ albedo = { 0.2, 0.3, 0.9 } })
local yellow = lunatic.create_material({ albedo = { 0.9, 0.8, 0.2 } })

local materials = { lunatic.material.default, red, green, blue, yellow }
local meshes = { lunatic.mesh.cube, lunatic.mesh.sphere }

-- Player sphere
local player = lunatic.spawn()
lunatic.add(player, "position", 0, 0.5, 0)
lunatic.add(player, "rotation", 0, 0, 0)
lunatic.add(player, "spin", 120)
lunatic.add(player, "mesh", lunatic.mesh.sphere)
lunatic.add(player, "material", yellow)
lunatic.add(player, "player")

-- Main camera (follows player with offset, looks at player)
local cam1 = lunatic.spawn()
lunatic.add(cam1, "position", 0, 8, 12)
lunatic.add(cam1, "camera", 60, 0.1, 100, 0, 0, 1, 1)
lunatic.add(cam1, "look_at", player)

-- Minimap camera (top-down, looks at player)
local cam2 = lunatic.spawn()
lunatic.add(cam2, "position", 0, 25, 0.1)
lunatic.add(cam2, "camera", 50, 0.1, 100, 0.73, 0.02, 0.25, 0.25)
lunatic.add(cam2, "look_at", player)

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

-- Spin system
lunatic.system("spin", function(dt)
  for _, e in ipairs(lunatic.query("rotation", "spin")) do
    local rot = lunatic.ref(e, "rotation")
    local spin = lunatic.ref(e, "spin")
    rot.y = rot.y + spin.speed * dt
  end
end)

-- Camera follow system
lunatic.system("camera_follow", function(dt)
  local p = lunatic.ref(player, "position")

  -- Main camera: offset behind and above
  local c1 = lunatic.ref(cam1, "position")
  c1.x = p.x
  c1.y = p.y + 8
  c1.z = p.z + 12

  -- Minimap: directly above
  local c2 = lunatic.ref(cam2, "position")
  c2.x = p.x
  c2.y = p.y + 25
  c2.z = p.z + 0.1
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
