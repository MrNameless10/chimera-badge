local RULES = {[3] = {3, 4}, [4] = {4, 3}, [5] = {4, 6}, [6] = {5, 5}}

return function(app, s)
  local roster, n, idx = s.roster, #s.roster, 0
  for i = 1, n do
    if roster[i] == app.id then idx = i end
  end
  if idx == 0 or not RULES[n] then
    app.go("home")
    return {}
  end
  app.forget()
  local need, goal = RULES[n][1], RULES[n][2]
  local v = app.load("lib/hull")(app, s.x, idx, n, goal)
  return app.load("lib/pulse")(app, s, v, idx, need, goal)
end
