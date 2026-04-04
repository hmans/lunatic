-- game/main.lua
-- Systems registered via lunatic.system(). Queries via lunatic.query().
-- Component refs via lunatic.ref() for natural field access.

-- Setup
lunatic.set_clear_color(0.55, 0.7, 0.85)
lunatic.set_camera(0, 8, 12, 0, 0, 0)
lunatic.set_light(0.3, 0.8, 0.5)
lunatic.set_ambient(0.15, 0.15, 0.25)
lunatic.set_fog(8, 25, 0.55, 0.7, 0.85)

-- Spawn a grid of cubes
for x = -4, 4 do
  for z = -4, 4 do
    local e = lunatic.spawn()
    lunatic.add(e, "position", x * 2, 0, z * 2)
    lunatic.add(e, "rotation", 0, math.random() * 360, 0)
    lunatic.add(e, "spin", 30 + math.random() * 60)
    lunatic.add(e, "mesh", "cube")
  end
end

-- Player cube
local e = lunatic.spawn()
lunatic.add(e, "position", 0, 0.5, 0)
lunatic.add(e, "rotation", 0, 0, 0)
lunatic.add(e, "spin", 120)
lunatic.add(e, "mesh", "cube")
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
