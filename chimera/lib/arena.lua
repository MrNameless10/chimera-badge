return function(app, foe)
  local L, mine, theirs = app.load("lib/light"), app.me.g, foe.g
  local draw = app.load("lib/draw")
  draw(L, mine, 24, 48, 4, {}, app.stage(), true)
  draw(L, theirs, 248, 48, 4, {}, foe.st or 0, true)
  draw = nil
  local G = app.load("lib/genome")
  local names = {"ATTACK", "DEFEND", G.ability(mine)}
  local view = {
    names = names,
    foe_names = {"ATTACK", "DEFEND", G.ability(theirs)},
    my_name = G.name(mine),
    foe_name = G.name(theirs),
    palette = L.of(mine),
  }
  view.me = ui.label(8, 4, view.my_name, {size = 14})
  view.foe = ui.label(160, 4, view.foe_name, {size = 14, w = 152, align = "right"})
  view.bar_me = ui.bar(8, 26, 140, 8, 100)
  view.bar_foe = ui.bar(172, 26, 140, 8, 100)
  view.title = ui.label(80, 66, "", {size = 14, w = 160, align = "center", color = "green"})
  view.line = ui.label(0, 118, "", {size = 12, w = ui.W, align = "center", color = "dim"})
  view.opts = {
    ui.label(8, 140, "UP " .. names[1], {size = 12}),
    ui.label(110, 140, "LEFT " .. names[2], {size = 12}),
    ui.label(214, 140, "RIGHT " .. names[3], {size = 12}),
  }
  view.status = ui.label(0, 166, "", {size = 14, w = ui.W, align = "center"})
  return view
end
