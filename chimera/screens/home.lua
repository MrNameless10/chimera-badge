local COLOURS = {"Red", "Ember", "Orange", "Amber", "Yellow", "Lime", "Green", "Jade",
                 "Teal", "Cyan", "Azure", "Blue", "Indigo", "Violet", "Magenta", "Rose"}
local PATTERNS = {"breathe", "chase", "sparkle", "flicker"}
local KEYS = {select = "scan", right = "lineage", left = "swarm"}

local function signals(n)
  if n == 0 then return "No genetic signals nearby" end
  return n .. (n == 1 and " genetic signal nearby" or " genetic signals nearby")
end

return function(app)
  local G, L, me = app.load("lib/genome"), app.load("lib/light"), app.me
  local stage, STAGES = app.stage(), G.STAGES
  if app.fresh then
    ui.label(120, 6, "YOUR FIRST CREATURE", {size = 12, color = "green"})
  end
  app.load("lib/draw")(L, me.g, 18, 28, 7, app.body, stage, false)
  ui.label(120, 22, G.name(me.g), {size = 32})
  local function progress()
    local goal = app.STAGE_XP[app.stage() + 1]
    return STAGES[app.stage() + 1] .. "  gen " .. me.gen .. "  " .. me.xp .. (goal and "/" .. goal or "") .. " XP"
  end
  local xp, shown = ui.label(120, 60, progress(), {size = 14, color = "dim"}), me.xp
  local get, p = G.get, (G.get(me.g, 4) & 3) + 1
  ui.label(120, 80, COLOURS[get(me.g, 1) + 1] .. "/" .. COLOURS[get(me.g, 2) + 1] .. ", " .. PATTERNS[p] .. " = " .. G.ABILITIES[p],
           {size = 12, color = "dim"})
  for i = 7, 9 do
    local v, y = G.stat(me.g, i), 104 + (i - 7) * 22
    ui.label(120, y, G.LABELS[i], {size = 12, color = "dim"})
    ui.bar(154, y + 3, 120, 8, v * 10)
    ui.label(282, y, tostring(v), {size = 12})
  end
  ui.label(18, 126, G.kind(me.g, stage), {size = 12})
  ui.label(18, 142, "DNA " .. me.g, {size = 12, color = "dim"})
  ui.label(18, 158, "W " .. me.w .. "  L " .. me.l .. "  " .. G.ability(me.g), {size = 12, color = "dim"})
  local line = ui.label(18, 178, signals(app.np), {size = 14, color = "green"})
  ui.hint("SELECT scan   LEFT swarm   RIGHT lineage")
  local palette = L.of(me.g)

  return {
    peers = function()
      line:text(signals(app.np))
      if me.xp == shown then return end
      if stage ~= app.stage() then return app.go("home") end
      shown = me.xp
      xp:text(progress())
    end,
    tick = function(t) L.play(palette, t, app) end,
    key = function(k)
      if k == "back" then return false end
      if KEYS[k] then app.go(KEYS[k]) end
    end,
  }
end
