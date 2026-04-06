-- Lighting Gallery — dark room showcasing clustered point and spot lights

local scene = {
  name = "Lighting Gallery",
}

function scene.setup(cam)
  local entities = {}
  local materials = {}

  local function track(e)
    entities[#entities + 1] = e
    return e
  end

  local function track_mat(id)
    materials[#materials + 1] = id
    return id
  end

  -- Dark scene, no fog
  lunatic.set_clear_color(0.02, 0.02, 0.04)
  lunatic.set_ambient(0.02, 0.02, 0.03)
  lunatic.set_fog(100, 200, 0, 0, 0) -- effectively disabled

  -- Camera
  lunatic.ref(cam, "position").x = 0
  lunatic.ref(cam, "position").y = 6
  lunatic.ref(cam, "position").z = 14
  lunatic.ref(cam, "rotation").x = 20
  lunatic.ref(cam, "rotation").y = 0

  -- Dim directional (moonlight)
  local light = track(lunatic.spawn())
  lunatic.add(light, "directional_light", 0.2, 0.8, 0.3, 0.15, 0.15, 0.2)

  -- Floor
  local floor_mat = track_mat(lunatic.create_material({ albedo = { 0.4, 0.4, 0.42 }, roughness = 0.7 }))
  local floor = track(lunatic.spawn())
  lunatic.add(floor, "position", 0, -0.25, 0)
  lunatic.add(floor, "mesh", "cube")
  lunatic.add(floor, "material", floor_mat)
  lunatic.add(floor, "scale", 30, 0.5, 30)
  lunatic.add(floor, "rotation", 0, 0, 0)
  lunatic.add(floor, "shadow_caster")
  lunatic.add(floor, "shadow_receiver")

  -- Some columns/cubes as geometry to catch light
  local pillar_mat = track_mat(lunatic.create_material({ albedo = { 0.6, 0.6, 0.65 }, roughness = 0.3, metallic = 0.1 }))
  for i = 1, 6 do
    local angle = (i - 1) * math.pi * 2 / 6
    local x = math.cos(angle) * 6
    local z = math.sin(angle) * 6
    local pillar = track(lunatic.spawn())
    lunatic.add(pillar, "position", x, 1.5, z)
    lunatic.add(pillar, "mesh", "cube")
    lunatic.add(pillar, "material", pillar_mat)
    lunatic.add(pillar, "scale", 0.6, 3, 0.6)
    lunatic.add(pillar, "rotation", 0, 0, 0)
    lunatic.add(pillar, "shadow_caster")
    lunatic.add(pillar, "shadow_receiver")
  end

  -- Center sphere (reflective)
  local chrome = track_mat(lunatic.create_material({ albedo = { 0.95, 0.95, 0.97 }, metallic = 1.0, roughness = 0.05 }))
  local center = track(lunatic.spawn())
  lunatic.add(center, "position", 0, 1.5, 0)
  lunatic.add(center, "mesh", "sphere")
  lunatic.add(center, "material", chrome)
  lunatic.add(center, "scale", 2, 2, 2)
  lunatic.add(center, "rotation", 0, 0, 0)
  lunatic.add(center, "shadow_caster")
  lunatic.add(center, "shadow_receiver")

  -- Ring of colored point lights at ground level
  local colors = {
    {1.0, 0.2, 0.05}, -- red-orange
    {1.0, 0.6, 0.0},  -- amber
    {0.2, 1.0, 0.1},  -- green
    {0.0, 0.8, 1.0},  -- cyan
    {0.2, 0.3, 1.0},  -- blue
    {0.8, 0.1, 1.0},  -- purple
    {1.0, 0.1, 0.5},  -- magenta
    {1.0, 0.9, 0.3},  -- warm yellow
  }
  local orbit_lights = {}
  for i = 1, #colors do
    local angle = (i - 1) * math.pi * 2 / #colors
    local x = math.cos(angle) * 9
    local z = math.sin(angle) * 9
    local pl = track(lunatic.spawn())
    lunatic.add(pl, "position", x, 1.5, z)
    lunatic.add(pl, "point_light", 10, colors[i][1], colors[i][2], colors[i][3], 4.0)
    orbit_lights[i] = { entity = pl, base_angle = angle }
  end

  -- Overhead spot lights (warm and cool)
  local spots = {
    { x = -5, z = -5, r = 1.0, g = 0.8, b = 0.5 }, -- warm
    { x =  5, z =  5, r = 0.5, g = 0.7, b = 1.0 }, -- cool
  }
  for _, s in ipairs(spots) do
    local e = track(lunatic.spawn())
    lunatic.add(e, "position", s.x, 8, s.z)
    lunatic.add(e, "spot_light", 14, s.r, s.g, s.b, 6.0, 0, -1, 0, 25, 40)
  end

  -- Animate the orbit lights
  local time = 0
  local orbit_active = true
  lunatic.system("lighting_gallery_orbit", function(dt)
    if not orbit_active then return end
    time = time + dt * 0.3
    for i, light_info in ipairs(orbit_lights) do
      local angle = light_info.base_angle + time
      local x = math.cos(angle) * 9
      local z = math.sin(angle) * 9
      local y = 1.5 + math.sin(time * 2 + i) * 1.0
      local pos = lunatic.ref(light_info.entity, "position")
      pos.x = x
      pos.y = y
      pos.z = z
    end
  end)

  return function()
    orbit_active = false
    for _, e in ipairs(entities) do
      pcall(lunatic.destroy, e)
    end
    for _, m in ipairs(materials) do
      lunatic.destroy_material(m)
    end
  end
end

return scene
