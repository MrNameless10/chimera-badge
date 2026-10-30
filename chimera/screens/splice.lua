local SPLICE_MS <const>, COOL_S <const> = 3200, 1800
local HEX <const> = "0123456789ABCDEF"

local function splice(get, a, b)
  local rate = get(a, 9) + get(b, 9)
  local out, src, muts = {}, {}, 0
  for i = 1, 9 do
    local mine = math.random(2) == 1
    local v, s = get(mine and a or b, i), mine and "a" or "b"
    if math.random(240) <= rate then
      v = (v + (math.random(2) * 2 - 3) * math.random(3)) & 15
      s, muts = "m", muts + 1
    end
    out[i], src[i] = HEX:byte(v + 1), s
  end
  return string.char(table.unpack(out)), src, muts
end

return function(app, p)
  local G, L, draw = app.load("lib/genome"), app.load("lib/light"), app.load("lib/draw")
  local me, before = app.me, app.me.g
  local child, src, muts = splice(G.get, before, p.g)
  app.splice = {b = p.g, partner = p.o, src = src, muts = muts}
  me.g, me.gen, me.splices, me.muts = child, math.min(math.max(me.gen, p.gen) + 1, app.GEN_MAX), me.splices + 1, me.muts + muts
  G.remember(me.gen, G.name(p.g), p.o, G.name(child))
  local t = sys.time()
  if t then
    local mates, n, soonest = me.mates, 0, nil
    for id, expiry in pairs(mates) do
      if expiry <= t then
        mates[id] = nil
      else
        n = n + 1
        if not soonest or expiry < mates[soonest] then soonest = id end
      end
    end
    if n >= app.MATES_MAX then mates[soonest] = nil end
    mates[p.id] = t + COOL_S
  end
  local ms = app.stage()
  app.fresh = false
  app.gain(3, true)

  ui.label(0, 4, "SPLICING DNA", {size = 14, w = ui.W, align = "center", color = "green"})
  draw(L, before, 50, 30, 5, app.body, ms, true)
  draw(L, p.g, 210, 30, 5, app.body, p.st or 0, true)
  ui.label(0, 108, G.name(before), {size = 14, w = 160, align = "center"})
  ui.label(160, 108, G.name(p.g), {size = 14, w = 160, align = "center"})
  local bar, t0 = ui.bar(40, 150, 240, 10, 0), app.now()
  local pair, la, lb = L.pair, L.of(before), L.of(p.g)
  ui.hint("")

  return {
    busy = true,
    tick = function(t)
      local e = t - t0
      if e >= SPLICE_MS then
        led.fill(255, 255, 255)
        return app.go("result")
      end
      bar:set(e * 100 // SPLICE_MS)
      pair(la, lb, t, 320 - 270 * e // SPLICE_MS)
    end,
  }
end
