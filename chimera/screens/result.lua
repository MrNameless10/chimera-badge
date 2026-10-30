local LAYERS = {{"a", "text"}, {"b", "aqua"}, {"m", "pink"}}

return function(app)
  local G, L, me, s = app.load("lib/genome"), app.load("lib/light"), app.me, app.splice
  local stage = app.stage()
  ui.label(120, 6, "NEW GENERATION", {size = 12, color = "green"})
  app.load("lib/draw")(L, me.g, 18, 28, 7, app.body, stage, false)
  ui.label(120, 22, G.name(me.g), {size = 32})
  ui.label(120, 60, G.kind(me.g, stage) .. "  gen " .. me.gen, {size = 14, color = "dim"})
  ui.label(120, 80, "from " .. G.name(s.b) .. " (" .. s.partner .. ")", {size = 12, color = "dim"})
  local head = {}
  for i = 1, 9 do head[i] = G.LABELS[i]:sub(1, 1) end
  ui.label(120, 104, table.concat(head, " "), {size = 12, color = "dim", mono = true})
  for _, layer in ipairs(LAYERS) do
    local row = {}
    for i = 1, 9 do row[i] = s.src[i] == layer[1] and me.g:sub(i, i) or " " end
    ui.label(120, 120, table.concat(row, " "), {size = 12, color = layer[2], mono = true})
  end
  ui.label(120, 144, "white yours  aqua theirs", {size = 12, color = "dim"})
  ui.label(120, 160, s.muts == 0 and "no mutations" or
    ("pink mutated: " .. s.muts .. (s.muts == 1 and " gene" or " genes")),
    {size = 12, color = s.muts > 0 and "pink" or "dim"})
  ui.hint("SELECT continue")
  local palette = L.of(me.g)

  return {
    busy = true,
    tick = function(t) L.play(palette, t, app) end,
    key = function(k)
      if k == "select" or k == "back" then
        app.splice = nil
        app.go("home")
      end
    end,
  }
end
