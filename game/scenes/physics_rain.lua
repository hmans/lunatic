-- Physics Rain — spheres raining down with physics, point lights, and a spot light

local scene = {
  name = "Physics Rain",
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

  -- Scene settings
  lunatic.set_clear_color(0.08, 0.08, 0.12)
  lunatic.set_ambient(0.15, 0.15, 0.25)
  lunatic.set_fog(15, 60, 0.08, 0.08, 0.12)

  -- Camera position
  lunatic.ref(cam, "position").x = 0
  lunatic.ref(cam, "position").y = 8
  lunatic.ref(cam, "position").z = 12
  lunatic.ref(cam, "rotation").x = 34
  lunatic.ref(cam, "rotation").y = 0

  -- Directional light
  local light = track(lunatic.spawn())
  lunatic.add(light, "directional_light", 0.3, 0.8, 0.5, 1.0, 0.95, 0.9)

  -- Point lights in a ring
  local light_colors = {
    {1.0, 0.3, 0.1},
    {0.1, 0.5, 1.0},
    {0.1, 1.0, 0.3},
    {1.0, 0.1, 0.8},
  }
  for i = 1, 8 do
    local angle = (i - 1) * math.pi * 2 / 8
    local x = math.cos(angle) * 8
    local z = math.sin(angle) * 8
    local col = light_colors[((i - 1) % #light_colors) + 1]
    local pl = track(lunatic.spawn())
    lunatic.add(pl, "position", x, 3, z)
    lunatic.add(pl, "point_light", 12, col[1], col[2], col[3], 3.0)
  end

  -- Spot light
  local spot = track(lunatic.spawn())
  lunatic.add(spot, "position", 0, 12, 0)
  lunatic.add(spot, "spot_light", 18, 1.0, 0.9, 0.7, 5.0, 0, -1, 0, 20, 35)

  -- Materials
  local white  = track_mat(lunatic.create_material({ albedo = { 0.85, 0.85, 0.85 } }))
  local ember  = track_mat(lunatic.create_material({ albedo = { 1, 0.4, 0.05 }, emissive = { 40, 12, 1 } }))
  local matte  = track_mat(lunatic.create_material({ albedo = { 0.05, 0.05, 0.05 }, roughness = 1.0 }))
  local silver = track_mat(lunatic.create_material({ albedo = { 0.9, 0.9, 0.92 }, metallic = 1.0, roughness = 0.15 }))
  local floor_mat = track_mat(lunatic.create_material({ albedo = { 0.25, 0.25, 0.28 }, roughness = 0.9 }))

  -- Floor
  local floor = track(lunatic.spawn())
  lunatic.add(floor, "position", 0, -0.25, 0)
  lunatic.add(floor, "mesh", "cube")
  lunatic.add(floor, "material", floor_mat)
  lunatic.add(floor, "scale", 20, 0.5, 20)
  lunatic.add(floor, "rotation", 0, 0, 0)
  lunatic.add(floor, "shadow_caster")
  lunatic.add(floor, "shadow_receiver")
  lunatic.physics_add_box(floor, 10, 0.25, 10, "static")
  lunatic.physics_optimize()

  -- Spawner state
  local spawn_timer = 0
  local spawn_interval = 0.05
  local max_bodies = 500
  local body_ring = {}
  local ring_head = 1
  local ring_count = 0

  local function spawn_physics_object()
    if ring_count >= max_bodies then
      local oldest_idx = ((ring_head - ring_count - 1) % max_bodies) + 1
      local oldest = body_ring[oldest_idx]
      if oldest then
        lunatic.destroy(oldest)
        body_ring[oldest_idx] = nil
      end
      ring_count = ring_count - 1
    end

    local e = lunatic.spawn()
    local x = (math.random() - 0.5) * 2
    local z = (math.random() - 0.5) * 2
    local y = 12 + math.random() * 8
    lunatic.add(e, "position", x, y, z)
    lunatic.add(e, "rotation", math.random() * 360, math.random() * 360, 0)

    local scale = 0.2 + math.random() * 0.6
    lunatic.add(e, "scale", scale, scale, scale)
    lunatic.add(e, "mesh", "sphere")
    local mat
    if math.random() < 0.1 then
      mat = ember
    else
      local common = { white, matte, silver }
      mat = common[math.random(#common)]
    end
    lunatic.add(e, "material", mat)
    lunatic.add(e, "shadow_caster")
    lunatic.add(e, "shadow_receiver")
    lunatic.physics_add_sphere(e, scale * 0.5, "dynamic", 0.1, 1.5)

    body_ring[ring_head] = e
    ring_head = (ring_head % max_bodies) + 1
    ring_count = ring_count + 1
  end

  -- Spawner system (guarded — keeps creating entities so needs an off switch)
  local spawner_active = true
  lunatic.system("physics_rain_spawner", function(dt)
    if not spawner_active then return end
    spawn_timer = spawn_timer + dt
    while spawn_timer >= spawn_interval do
      spawn_physics_object()
      spawn_timer = spawn_timer - spawn_interval
    end

    for i = 1, max_bodies do
      local e = body_ring[i]
      if e then
        local ok, pos = pcall(lunatic.ref, e, "position")
        if ok and pos.y < -20 then
          lunatic.destroy(e)
          body_ring[i] = nil
          ring_count = ring_count - 1
        end
      end
    end
  end)

  -- Cleanup
  return function()
    spawner_active = false
    for _, e in ipairs(entities) do
      pcall(lunatic.destroy, e)
    end
    for i = 1, #body_ring do
      if body_ring[i] then
        pcall(lunatic.destroy, body_ring[i])
      end
    end
    for _, m in ipairs(materials) do
      lunatic.destroy_material(m)
    end
  end
end

return scene
