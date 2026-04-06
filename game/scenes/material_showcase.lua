-- Material Showcase — grid of spheres with varying roughness and metallic values

local scene = {
  name = "Material Showcase",
}

-- Pre-create materials once (material registry is finite and never freed)
local rows = 7
local cols = 7
local spacing = 1.4

local floor_mat = lunatic.create_material({ albedo = { 0.2, 0.2, 0.22 }, roughness = 0.95 })

local grid_mats = {}
for row = 0, rows - 1 do
  for col = 0, cols - 1 do
    local roughness = 0.05 + (row / (rows - 1)) * 0.95
    local metallic = col / (cols - 1)
    grid_mats[row * cols + col] = lunatic.create_material({
      albedo = { 0.9, 0.3, 0.2 },
      metallic = metallic,
      roughness = roughness,
    })
  end
end

function scene.setup(cam)
  local entities = {}

  local function track(e)
    entities[#entities + 1] = e
    return e
  end

  -- Neutral lighting
  lunatic.set_clear_color(0.12, 0.12, 0.15)
  lunatic.set_ambient(0.1, 0.1, 0.12)
  lunatic.set_fog(100, 200, 0, 0, 0)

  -- Camera
  lunatic.ref(cam, "position").x = 0
  lunatic.ref(cam, "position").y = 5
  lunatic.ref(cam, "position").z = 10
  lunatic.ref(cam, "rotation").x = 20
  lunatic.ref(cam, "rotation").y = 0

  -- Directional light (strong, slightly warm)
  local light = track(lunatic.spawn())
  lunatic.add(light, "directional_light", 0.5, 0.8, 0.3, 1.0, 0.97, 0.92)

  -- Fill light from below-left (cool)
  local fill = track(lunatic.spawn())
  lunatic.add(fill, "position", -8, 2, 8)
  lunatic.add(fill, "point_light", 20, 0.6, 0.7, 1.0, 3.0)

  -- Warm rim light from right
  local rim = track(lunatic.spawn())
  lunatic.add(rim, "position", 10, 4, -2)
  lunatic.add(rim, "point_light", 20, 1.0, 0.85, 0.6, 2.0)

  -- Floor
  local floor = track(lunatic.spawn())
  lunatic.add(floor, "position", 0, -0.6, 0)
  lunatic.add(floor, "mesh", "cube")
  lunatic.add(floor, "material", floor_mat)
  lunatic.add(floor, "scale", 20, 0.2, 20)
  lunatic.add(floor, "rotation", 0, 0, 0)

  -- Grid of spheres: rows = roughness (0.05 to 1.0), columns = metallic (0 to 1)
  local x_offset = -(cols - 1) * spacing / 2
  local z_offset = -(rows - 1) * spacing / 2

  for row = 0, rows - 1 do
    for col = 0, cols - 1 do
      local e = track(lunatic.spawn())
      lunatic.add(e, "position", x_offset + col * spacing, 0.5, z_offset + row * spacing)
      lunatic.add(e, "mesh", "sphere")
      lunatic.add(e, "material", grid_mats[row * cols + col])
      lunatic.add(e, "scale", 0.5, 0.5, 0.5)
      lunatic.add(e, "rotation", 0, 0, 0)
    end
  end

  return function()
    for _, e in ipairs(entities) do
      pcall(lunatic.destroy, e)
    end
  end
end

return scene
