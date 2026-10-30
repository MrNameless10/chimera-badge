local COL_W <const>, ROW_H <const>, MID <const> = 48, 22, 96

local function hash(x)
  x = (x ~ (x >> 16)) * 0x45D9F3B
  return x ~ (x >> 16)
end

return function(app, x, idx, n, goal)
  local G, L = app.load("lib/genome"), app.load("lib/light")
  local rgb, roles = L.rgb, G.ROLES
  local hue, acc = G.get(x, 1), G.get(x, 2)
  local r, g, b = rgb(hue)
  local body = r << 16 | g << 8 | b
  r, g, b = rgb(acc)
  local accent = r << 16 | g << 8 | b
  local seed, last = 0, 5 * n - 1
  for i = 1, 9 do seed = seed * 31 + x:byte(i) end

  for j = 0, 4 do
    local c = (idx - 1) * 5 + j
    local h = hash(seed ~ c * 0x9E37)
    local rows = 2 + (h >> 3) % 4 + (c < 5 and 1 or 0) - (c > last - 5 and c - last + 5 or 0)
    rows = rows < 1 and 1 or rows
    local px, py = 40 + j * COL_W, MID - rows * ROW_H // 2
    local into, k = app.body, #app.body
    into[k + 1], into[k + 2] = ui.rect(px, py, COL_W - 4, rows * ROW_H,
      {color = (h >> 9) & 3 == 0 and accent or body}), px << 16 | py
    if c == 1 or c == 2 then
      local ex, ey = px + 17, py + 8
      into[k + 3], into[k + 4] = ui.rect(ex, ey, 10, 10, {color = acc == hue and 0x101010 or accent}), ex << 16 | ey
    end
  end

  local name = G.name(x)
  ui.label(8, 4, "COLOSSUS " .. name, {size = 12, color = "green"})
  ui.label(160, 4, roles[idx] .. "  " .. idx .. "/" .. n, {size = 12, w = 152, align = "right"})
  local view = {
    name = name,
    rename = G.name,
    remember = G.remember,
    labels = G.LABELS,
    rgb = rgb,
    palette = L.of(x),
    bar = ui.bar(8, 172, 120, 8, 0),
    count = ui.label(134, 168, "chain 0/" .. goal, {size = 12, color = "dim"}),
    parts = {},
    status = ui.label(0, 184, "", {size = 14, w = ui.W, align = "center"}),
  }
  for i = 1, n do
    view.parts[i] = ui.label(222 + (i - 1) * 15, 168, roles[i]:sub(1, 1), {size = 12, color = i == idx and "text" or "dim"})
  end
  ui.hint("")
  return view
end
