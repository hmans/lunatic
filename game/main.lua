-- game/main.lua
-- A simple bouncing square to prove the engine works.

local x, y = 100, 100
local vx, vy = 200, 150
local size = 40

function init()
  print("gammo is alive!")
end

function update(dt)
  -- Move
  x = x + vx * dt
  y = y + vy * dt

  -- Bounce off edges (800x600 window)
  if x < 0 then x = 0; vx = -vx end
  if x + size > 800 then x = 800 - size; vx = -vx end
  if y < 0 then y = 0; vy = -vy end
  if y + size > 600 then y = 600 - size; vy = -vy end

  -- Arrow key input
  if gammo.key_down("Left") then vx = vx - 400 * dt end
  if gammo.key_down("Right") then vx = vx + 400 * dt end
  if gammo.key_down("Up") then vy = vy - 400 * dt end
  if gammo.key_down("Down") then vy = vy + 400 * dt end
end

function draw()
  gammo.clear(20, 20, 30)
  gammo.rect(x, y, size, size, 220, 80, 60)
end
