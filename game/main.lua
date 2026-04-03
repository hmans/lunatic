-- game/main.lua
-- Rotating cube with camera orbit.

local angle_y = 0
local angle_x = 15
local cam_distance = 4
local cam_height = 1.5

function init()
  gammo.set_clear_color(0.08, 0.08, 0.12)
  print("gammo 3D is alive!")
end

function update(dt)
  -- Auto-rotate
  angle_y = angle_y + 45 * dt

  -- Arrow keys orbit the camera
  if gammo.key_down("Left")  then angle_y = angle_y - 90 * dt end
  if gammo.key_down("Right") then angle_y = angle_y + 90 * dt end
  if gammo.key_down("Up")    then angle_x = angle_x + 60 * dt end
  if gammo.key_down("Down")  then angle_x = angle_x - 60 * dt end

  -- Clamp pitch
  if angle_x > 89 then angle_x = 89 end
  if angle_x < -89 then angle_x = -89 end

  -- Compute camera position on a sphere
  local rad_y = math.rad(angle_y)
  local rad_x = math.rad(angle_x)
  local cx = cam_distance * math.cos(rad_x) * math.sin(rad_y)
  local cy = cam_height + cam_distance * math.sin(rad_x)
  local cz = cam_distance * math.cos(rad_x) * math.cos(rad_y)

  gammo.set_camera(cx, cy, cz, 0, 0, 0)
  gammo.set_rotation(0, 0) -- no model rotation, camera does the work
end
