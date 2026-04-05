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

-- Camera args: fov, near, far, viewport_x, viewport_y, viewport_w, viewport_h,
--              exposure, bloom_intensity
-- Trailing args use struct defaults if omitted (see core_components.zig).
local cam = lunatic.spawn()
lunatic.add(cam, "position", 0, 8, 12)
lunatic.add(cam, "rotation", 34, 0, 0)
-- Camera args: fov, near, far, vp_x, vp_y, vp_w, vp_h, exposure, bloom_intensity,
--              dof_focus_dist, dof_focus_range, dof_blur_radius
lunatic.add(cam, "camera", 60, 0.1, 100, 0, 0, 1, 1, 1.2, 0.15, 15, 8, 8)

-- Adding a fly_camera component enables the built-in FPS camera controller.
-- Optional args: speed, fast_speed, sensitivity (defaults: 10, 30, 0.15)
lunatic.add(cam, "fly_camera")

--------------------------------------------------------------------------------
-- Entities
--------------------------------------------------------------------------------

-- Spawn a 9x9 grid of randomly shaped, colored, spinning objects
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

--------------------------------------------------------------------------------
-- Systems
--------------------------------------------------------------------------------

-- A persistent query caches the entity set; the engine maintains it
-- automatically as entities gain/lose the queried components.
local spinners = lunatic.create_query("rotation", "spin")

-- Systems run every frame. lunatic.ref() returns a mutable reference to a
-- component — writes to it update the ECS directly (no setter needed).
lunatic.system("spin", function(dt)
  lunatic.each_query(spinners, function(e)
    local rot = lunatic.ref(e, "rotation")
    local spin = lunatic.ref(e, "spin")
    rot.y = rot.y + spin.speed * dt
  end)
end)

-- Debug UI using the ImGui bindings exposed via the `ui` global table.
-- ui.slider_float() takes the current value and returns the (possibly modified)
-- value — a functional style that works naturally with Lua.
lunatic.system("debug_ui", function(dt)
  ui.set_next_window_pos(16, 16, "first_use")
  ui.set_next_window_size(280, 0, "first_use")
  ui.begin_window("Debug")

  ui.text(string.format("%.0f fps", ui.fps()))

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
