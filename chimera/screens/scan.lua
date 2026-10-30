return function(app)
  local G, L = app.load("lib/genome"), app.load("lib/light")
  local palette = L.of(app.me.g)
  local ids = {}
  ui.label(10, 6, "GENETIC SIGNALS", {size = 14, color = "dim"})
  local list = ui.list(0, 28, ui.W, ui.H - 44, {}, {on_select = function(i)
    if ids[i] then app.go("duel", "wait", ids[i], "s") end
  end})
  ui.hint("SELECT splice   RIGHT battle   CANCEL back")

  local function refresh()
    local n = 0
    ids = {}
    for id in pairs(app.peers) do
      n = n + 1
      ids[n] = id
    end
    table.sort(ids)
    local rows = {}
    for i = 1, n do
      local p = app.peers[ids[i]]
      local st = p.st or 0
      rows[i] = {title = G.name(p.g) .. "  " .. p.o, sub = G.kind(p.g, st) .. ", " .. G.ability(p.g), right = G.STAGES[st + 1]}
    end
    if n == 0 then rows[1] = "Searching for genetic signals..." end
    local sel = list:selected() or 1
    list:items(rows)
    list:select(sel < #rows and sel or #rows)
  end
  refresh()

  return {
    peers = refresh,
    tick = function(t) L.play(palette, t, app) end,
    key = function(k)
      if k == "back" then app.go("home")
      elseif k == "right" then
        local id = ids[list:selected() or 0]
        if id then app.go("duel", "wait", id, "b") end
      end
    end,
  }
end
