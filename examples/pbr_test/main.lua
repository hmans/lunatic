-- game/main.lua — PBR test with MetalRoughSpheres
-- Swap to DamagedHelmet.glb or your own model to test

-- Setup
lunatic.set_clear_color(0.15, 0.15, 0.18)
lunatic.set_ambient(0.1, 0.1, 0.12)
lunatic.set_fog(false)

-- Directional light
local light = lunatic.spawn()
lunatic.add(light, "directional_light", 0.3, 0.8, 0.5, 1, 1, 1)

-- Load test model
local model = lunatic.load_gltf("assets/MetalRoughSpheres.glb")

for i, mesh_id in ipairs(model.meshes) do
  local e = lunatic.spawn()
  lunatic.add(e, "position", 0, 0, 0)
  lunatic.add(e, "rotation", 0, 0, 0)
  lunatic.add(e, "mesh", mesh_id)
  local mat_id = model.materials[i] or model.materials[1]
  if mat_id then
    lunatic.add(e, "material", mat_id)
  end
end

-- Free-fly camera
local cam = lunatic.spawn()
lunatic.add(cam, "position", 0, 0, 25)
lunatic.add(cam, "rotation", 0, 0, 0)
lunatic.add(cam, "camera", 60, 0.1, 200, 0, 0, 1, 1)

-- Grab mouse for FPS-style look
lunatic.set_mouse_grab(true)

lunatic.system("fly_camera", function(dt)
  local pos = lunatic.ref(cam, "position")
  local rot = lunatic.ref(cam, "rotation")
  local move_speed = lunatic.key_down("Left Shift") and 30 or 10
  local mouse_sensitivity = 0.15

  -- Mouse look
  local dx, dy = lunatic.mouse_delta()
  rot.y = rot.y + dx * mouse_sensitivity
  rot.x = rot.x + dy * mouse_sensitivity
  -- Clamp pitch
  if rot.x > 89 then rot.x = 89 end
  if rot.x < -89 then rot.x = -89 end

  -- Get actual camera axes from the rotation matrix
  local fx, fy, fz, rx, ry, rz = lunatic.camera_axes(rot.x, rot.y, rot.z)

  -- WASD + Q/E
  if lunatic.key_down("W") then
    pos.x = pos.x + fx * move_speed * dt
    pos.y = pos.y + fy * move_speed * dt
    pos.z = pos.z + fz * move_speed * dt
  end
  if lunatic.key_down("S") then
    pos.x = pos.x - fx * move_speed * dt
    pos.y = pos.y - fy * move_speed * dt
    pos.z = pos.z - fz * move_speed * dt
  end
  if lunatic.key_down("A") then
    pos.x = pos.x - rx * move_speed * dt
    pos.y = pos.y - ry * move_speed * dt
    pos.z = pos.z - rz * move_speed * dt
  end
  if lunatic.key_down("D") then
    pos.x = pos.x + rx * move_speed * dt
    pos.y = pos.y + ry * move_speed * dt
    pos.z = pos.z + rz * move_speed * dt
  end
  if lunatic.key_down("Space")          then pos.y = pos.y + move_speed * dt end
  if lunatic.key_down("Left Ctrl") then pos.y = pos.y - move_speed * dt end
end)
