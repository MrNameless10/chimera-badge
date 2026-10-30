local CHEER_MS <const>, LONELY_MS <const>, FADE_MS <const> = 600000, 3600000, 3600000
local L = {}
local set = led.set
local glow = 256

local function gene(g, i)
  local b = g:byte(i)
  return b < 65 and b - 48 or b - 55
end

local function rgb(h)
  local x = h * 96
  local s, up = x >> 8, x & 255
  local down = 255 - up
  if s == 0 then return 255, up, 0
  elseif s == 1 then return down, 255, 0
  elseif s == 2 then return 0, 255, up
  elseif s == 3 then return 0, down, 255
  elseif s == 4 then return up, 0, 255
  end
  return 255, 0, down
end

L.rgb, L.gene = rgb, gene

function L.of(g)
  local r, gg, b = rgb(gene(g, 1))
  local r2, g2, b2 = rgb(gene(g, 2))
  return {gene(g, 4) & 3, 3000 - gene(g, 3) * 160, r, gg, b, r2, g2, b2}
end

local function put(i, r, g, b, k)
  k = k * glow
  set(i, r * k >> 16, g * k >> 16, b * k >> 16)
end

function L.play(p, t, app)
  local idle, cheered = t - app.social - LONELY_MS, app.cheered
  glow = idle <= 0 and 256 or idle >= FADE_MS and 96 or 256 - idle * 160 // FADE_MS
  local fast = cheered and t - cheered < CHEER_MS
  local pat, period, r, g, b, r2, g2, b2 = p[1], fast and p[2] >> 1 or p[2], p[3], p[4], p[5], p[6], p[7], p[8]
  local ph = t % period
  if pat == 0 then
    local k = 16 + (2 * ph < period and ph or period - ph) * 480 // period
    for i = 1, 6 do put(i, r, g, b, k) end
    put(7, r2, g2, b2, k)
    put(8, r2, g2, b2, k)
  elseif pat == 1 then
    local head = ph * 6 // period + 1
    local tail = head == 1 and 6 or head - 1
    for i = 1, 6 do put(i, r, g, b, i == head and 256 or i == tail and 64 or 8) end
    local k = head & 1 == 0 and 154 or 38
    put(7, r2, g2, b2, k)
    put(8, r2, g2, b2, 192 - k)
  elseif pat == 2 then
    local slot = t // (period // 6)
    for i = 1, 8 do
      if (slot * 7 + i * 13) * 75 % 97 < 28 then put(i, r2, g2, b2, 256) else put(i, r, g, b, 31) end
    end
  else
    local a = 2 * ph < period
    for i = 1, 8 do
      if (i <= 3 or i == 7) == a then put(i, r, g, b, 230) else put(i, r2, g2, b2, 230) end
    end
  end
  local near = app.near
  if near then
    local nr, ng, nb = rgb(gene(near, 1))
    local on = t // app.blink & 1 == 0
    set(7, on and nr or 0, on and ng or 0, on and nb or 0)
    set(8, on and 0 or nr, on and 0 or ng, on and 0 or nb)
  end
end

function L.pair(p, q, t, step)
  local f = t // step & 1
  for i = 1, 8 do
    local s = (i + f) & 1 == 0 and p or q
    set(i, s[3], s[4], s[5])
  end
end

return L
