local ATLAS <const>, RECTS_MAX <const> = "data/sprites.bin", 38

local function pack(r, g, b)
  return r << 16 | g << 8 | b
end

return function(L, g, x, y, cell, into, stage, combat)
  local rgb, gene = L.rgb, L.gene
  local hue, acc = gene(g, 1), gene(g, 2)
  local r, gg, b = rgb(hue)
  local ar, ag, ab = rgb(acc)
  if acc == hue then ar, ag, ab = ar * 5 >> 3, ag * 5 >> 3, ab * 5 >> 3 end
  local pal = {pack(r, gg, b), pack((r + 255) >> 1, (gg + 255) >> 1, (b + 255) >> 1), pack(ar, ag, ab), 0xF2F2F2, 0x101010}
  local id = ((stage * 2 + (combat and 1 or 0)) * 8 + (gene(g, 5) & 7)) * 8 + (gene(g, 6) & 7)
  local ix = fs.read(ATLAS, id * 2, 2)
  local data = fs.read(ATLAS, ix:byte(1) << 8 | ix:byte(2), 1 + RECTS_MAX * 3)
  local n = #into
  for i = 2, data:byte(1) * 3, 3 do
    local p, s = data:byte(i), data:byte(i + 1)
    local rx, ry = x + (p >> 4) * cell, y + (p & 15) * cell
    into[n + 1], into[n + 2] = ui.rect(rx, ry, ((s >> 4) + 1) * cell, ((s & 15) + 1) * cell, {color = pal[data:byte(i + 2)]}), rx << 16 | ry
    n = n + 2
  end
  return into
end
