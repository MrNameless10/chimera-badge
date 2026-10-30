return function(app, foe)
  app.forget()
  local view = app.load("lib/arena")(app, foe)
  return app.load("lib/fight")(app, foe, view)
end
