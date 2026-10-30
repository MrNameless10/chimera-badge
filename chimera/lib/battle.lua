local B = {ROUNDS = 3}
local LABELS = {"ATK", "DEF", "MUT"}

local function gene(g, i)
  local b = g:byte(i)
  return b < 65 and b - 48 or b - 55
end

local function stat(g, i)
  return gene(g, i) * 9 // 15 + 1
end

local function mix(x)
  x = (x ~ (x >> 16)) * 0x45D9F3B
  x = (x ~ (x >> 16)) * 0x45D9F3B
  return x ~ (x >> 16)
end

function B.commit(sid, r, m, v)
  return string.format("%08x", mix(mix(v ~ mix(sid + r)) + m))
end

function B.opens(sid, r, m, n, h)
  m = math.tointeger(m)
  if not m or m < 1 or m > 3 or type(n) ~= "string" or #n == 0 or #n > 7 or n:find("[^0-9a-f]") then return end
  local v = tonumber(n, 16)
  if B.commit(sid, r, m, v) == h then return m, v end
end

local function rng(seed)
  local x = seed ~= 0 and seed or 0x2545F491
  return function(n)
    x = x ~ (x << 13)
    x = x ~ (x >> 17)
    x = x ~ (x << 5)
    return (x >> 1) % n
  end
end

function B.fighter(g)
  local def = stat(g, 8)
  local hp = 8 + 2 * def
  return {atk = stat(g, 7), def = def, mut = stat(g, 9), ab = gene(g, 4) & 3, hp = hp, max = hp}
end

local function act(f, mf, mo, roll)
  if mf == 1 then
    if mo == 2 then return 0, 0 end
    return f.atk + roll(4), 0
  elseif mf == 2 then
    if mo == 1 then return f.def + roll(3), 0 end
    return 0, 0
  elseif mo == 1 then
    return 0, 0
  end
  local m, ab = f.mut, f.ab
  if ab == 0 then return m >> 2, 3 + (m >> 1)
  elseif ab == 1 then return ((f.atk + m) >> 1) + roll(4), 0
  elseif ab == 2 then return (m >> 1) + 1 + roll(m + 2), 0
  end
  local d = 1 + (m >> 1)
  return d, (d + 3) >> 1
end

local function clamp(f, v)
  f.hp = v < 0 and 0 or v > f.max and f.max or v
end

function B.round(a, b, ma, mb, seed)
  local roll = rng(seed)
  local da, ha = act(a, ma, mb, roll)
  local db, hb = act(b, mb, ma, roll)
  clamp(a, a.hp - db + ha)
  clamp(b, b.hp - da + hb)
end

function B.over(a, b, r)
  return a.hp == 0 or b.hp == 0 or r > B.ROUNDS
end

function B.winner(a, b)
  local d = a.hp * b.max - b.hp * a.max
  return d > 0 and 1 or d < 0 and -1 or 0
end

function B.reward(g)
  local pick, seen = nil, 0
  for i = 7, 9 do
    if stat(g, i) < 10 then
      seen = seen + 1
      if math.random(seen) == 1 then pick = i end
    end
  end
  if not pick then return end
  local k = stat(g, pick)
  return g:sub(1, pick - 1) .. string.format("%X", (k * 15 + 8) // 9) .. g:sub(pick + 1), LABELS[pick - 6], k
end

return B
