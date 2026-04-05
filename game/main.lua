-- Lunatic game — spinning shapes with bloom and fly camera
--
-- This file is the game entry point. The engine loads it at startup and
-- executes it once; any lunatic.system() calls register per-frame callbacks
-- that run every tick after that.
--
-- Right-click + drag to look around, WASD to move, Space/Ctrl for up/down.
-- Shift for fast movement. The Debug window lets you tweak post-processing.

--------------------------------------------------------------------------------
-- Scene settings
--------------------------------------------------------------------------------

-- Dark background to make emissive bloom pop
lunatic.set_clear_color(0.08, 0.08, 0.12)
lunatic.set_ambient(0.15, 0.15, 0.25)

-- Fog fades distant objects into the background color
-- Args: start distance, end distance, r, g, b
lunatic.set_fog(15, 60, 0.08, 0.08, 0.12)

--------------------------------------------------------------------------------
-- Light
--------------------------------------------------------------------------------

-- A single directional light (sun). Args: direction x, y, z
local light = lunatic.spawn()
lunatic.add(light, "directional_light", 0.3, 0.8, 0.5)

--------------------------------------------------------------------------------
-- Materials
--------------------------------------------------------------------------------

-- Basic colored materials (PBR with default metallic=0, roughness=0.5)
local red    = lunatic.create_material({ albedo = { 0.9, 0.2, 0.2 } })
local green  = lunatic.create_material({ albedo = { 0.2, 0.8, 0.3 } })
local blue   = lunatic.create_material({ albedo = { 0.2, 0.3, 0.9 } })
local yellow = lunatic.create_material({ albedo = { 0.9, 0.8, 0.2 } })

-- Emissive materials glow beyond 1.0 in the HDR buffer, which triggers bloom.
-- The emissive values (3, 1.5, 0.3) etc. are in linear HDR — values > 1 bloom.
local hot    = lunatic.create_material({ albedo = { 1, 1, 1 }, emissive = { 3, 1.5, 0.3 } })
local cool   = lunatic.create_material({ albedo = { 1, 1, 1 }, emissive = { 0.3, 0.8, 3 } })

local materials = { lunatic.material.default, red, green, blue, yellow, hot, cool }
local meshes = { lunatic.mesh.cube, lunatic.mesh.sphere }

--------------------------------------------------------------------------------
-- Camera
--------------------------------------------------------------------------------

-- Trailing camera args use struct defaults if omitted (see core_components.zig).
local cam = lunatic.spawn()
lunatic.add(cam, "position", 0, 8, 12)
lunatic.add(cam, "rotation", 34, 0, 0)
lunatic.add(cam, "camera", 60, 0.1, 100, 0, 0, 1, 1,
  1.2,   -- exposure
  0.15,  -- bloom_intensity
  15,    -- dof_focus_dist
  8,     -- dof_focus_range
  8,     -- dof_blur_radius
  0.4,   -- vignette
  0.5,   -- vignette_smoothness
  0.3,   -- chromatic_aberration
  0.03,  -- grain
  0.0    -- color_temp
)

-- Adding a fly_camera component enables the built-in FPS camera controller.
-- Optional args: speed, fast_speed, sensitivity (defaults: 10, 30, 0.15)
lunatic.add(cam, "fly_camera")

--------------------------------------------------------------------------------
-- Physics
--------------------------------------------------------------------------------

-- Visible floor (scale and physics half-extents must match:
-- unit cube is ±0.5, so scale=S gives size S, half-extent = S/2)
local floor = lunatic.spawn()
lunatic.add(floor, "position", 0, -0.25, 0)
lunatic.add(floor, "mesh", "cube")
lunatic.add(floor, "scale", 20, 0.5, 20)
lunatic.add(floor, "rotation", 0, 0, 0)
lunatic.physics_add_box(floor, 10, 0.25, 10, "static")
lunatic.physics_optimize()

-- Spawner state
local spawn_timer = 0
local spawn_interval = 0.08 -- seconds between spawns
local max_bodies = 5000
local body_queue = {}        -- ring buffer of entity IDs

local function spawn_physics_object()
  -- Kill oldest if at capacity
  if #body_queue >= max_bodies then
    lunatic.destroy(table.remove(body_queue, 1))
  end

  local e = lunatic.spawn()
  local x = (math.random() - 0.5) * 6
  local z = (math.random() - 0.5) * 6
  local y = 12 + math.random() * 8
  lunatic.add(e, "position", x, y, z)
  lunatic.add(e, "rotation", math.random() * 360, math.random() * 360, 0)

  local scale = 0.2 + math.random() * 0.6
  lunatic.add(e, "scale", scale, scale, scale)
  lunatic.add(e, "mesh", "sphere")
  lunatic.add(e, "material", materials[math.random(#materials)])
  lunatic.physics_add_sphere(e, scale * 0.5, "dynamic", 0.1, 1.5)

  body_queue[#body_queue + 1] = e
end

--------------------------------------------------------------------------------
-- Systems
--------------------------------------------------------------------------------

-- Spawn new objects and kill fallen ones
lunatic.system("spawner", function(dt)
  spawn_timer = spawn_timer + dt
  while spawn_timer >= spawn_interval do
    spawn_physics_object()
    spawn_timer = spawn_timer - spawn_interval
  end

  -- Kill bodies that fell off the world
  local i = 1
  while i <= #body_queue do
    local pos = lunatic.ref(body_queue[i], "position")
    if pos.y < -20 then
      lunatic.destroy(body_queue[i])
      table.remove(body_queue, i)
    else
      i = i + 1
    end
  end
end)

-- Debug UI using the ImGui bindings exposed via the `ui` global table.
-- ui.slider_float() takes the current value and returns the (possibly modified)
-- value — a functional style that works naturally with Lua.
lunatic.system("debug_ui", function(dt)
  ui.set_next_window_pos(16, 16, "first_use")
  ui.set_next_window_size(280, 0, "first_use")
  ui.begin_window("Debug")

  if ui.collapsing_header("Post-Processing") then
    local cam_ref = lunatic.ref(cam, "camera")
    cam_ref.exposure = ui.slider_float("Exposure", cam_ref.exposure, 0.1, 5.0)
    cam_ref.bloom_intensity = ui.slider_float("Bloom Intensity", cam_ref.bloom_intensity, 0.0, 1.0)
  end

  if ui.collapsing_header("Depth of Field") then
    local cam_ref = lunatic.ref(cam, "camera")
    cam_ref.dof_focus_dist = ui.slider_float("Focus Distance", cam_ref.dof_focus_dist, 0, 50)
    cam_ref.dof_focus_range = ui.slider_float("Focus Range", cam_ref.dof_focus_range, 0.5, 30)
    cam_ref.dof_blur_radius = ui.slider_float("Blur Radius", cam_ref.dof_blur_radius, 1, 20)
  end

  if ui.collapsing_header("Lens Effects") then
    local cam_ref = lunatic.ref(cam, "camera")
    cam_ref.vignette = ui.slider_float("Vignette", cam_ref.vignette, 0, 1)
    cam_ref.vignette_smoothness = ui.slider_float("Vignette Smoothness", cam_ref.vignette_smoothness, 0.2, 0.8)
    cam_ref.chromatic_aberration = ui.slider_float("Chromatic Aberration", cam_ref.chromatic_aberration, 0, 3)
    cam_ref.grain = ui.slider_float("Film Grain", cam_ref.grain, 0, 0.2)
    cam_ref.color_temp = ui.slider_float("Color Temperature", cam_ref.color_temp, -3, 3)
  end

  if ui.collapsing_header("Bloom Shape") then
    local r = lunatic.get_bloom_radius()
    lunatic.set_bloom_radius(ui.slider_float("Radius", r, 0.5, 3.0))

    local t1, t2, t3, t4, t5, t6 = lunatic.get_bloom_tints()
    t1 = ui.slider_float("1/2 (core)", t1, 0, 1)
    t2 = ui.slider_float("1/4", t2, 0, 1)
    t3 = ui.slider_float("1/8", t3, 0, 1)
    t4 = ui.slider_float("1/16", t4, 0, 1)
    t5 = ui.slider_float("1/32", t5, 0, 1)
    t6 = ui.slider_float("1/64 (haze)", t6, 0, 1)
    lunatic.set_bloom_tints(t1, t2, t3, t4, t5, t6)
  end

  ui.end_window()
end)
