-- Primitives example — spinning cubes and spheres with materials

lunatic.set_clear_color(0.55, 0.7, 0.85)
lunatic.set_ambient(0.15, 0.15, 0.25)
lunatic.set_fog(8, 50, 0.55, 0.7, 0.85)

-- Light
local light = lunatic.spawn()
lunatic.add(light, "directional_light", 0.3, 0.8, 0.5, 1, 1, 1)

-- Materials
local red    = lunatic.create_material({ albedo = { 0.9, 0.2, 0.2 } })
local green  = lunatic.create_material({ albedo = { 0.2, 0.8, 0.3 } })
local blue   = lunatic.create_material({ albedo = { 0.2, 0.3, 0.9 } })
local yellow = lunatic.create_material({ albedo = { 0.9, 0.8, 0.2 } })

local materials = { lunatic.material.default, red, green, blue, yellow }
local meshes = { lunatic.mesh.cube, lunatic.mesh.sphere }

-- Camera
local cam = lunatic.spawn()
lunatic.add(cam, "position", 0, 8, 12)
lunatic.add(cam, "rotation", 34, 0, 0)
lunatic.add(cam, "camera", 60, 0.1, 100, 0, 0, 1, 1)

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

-- Spin system (uses a persistent query — entity set maintained automatically)
local spinners = lunatic.create_query("rotation", "spin")

lunatic.system("spin", function(dt)
  lunatic.each_query(spinners, function(e)
    local rot = lunatic.ref(e, "rotation")
    local spin = lunatic.ref(e, "spin")
    rot.y = rot.y + spin.speed * dt
  end)
end)
