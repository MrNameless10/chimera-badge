local TITLES = {
  wait = {s = "GENETIC SPLICE", b = "BATTLE CHALLENGE"},
  incoming = {s = "GENETIC SIGNAL DETECTED", b = "CHALLENGE RECEIVED"},
}

return function(app, mode, from, arg)
  local hs = app.hand()
  if mode == "wait" then hs.offer(from, arg) else hs.mesh(from, "o", arg) end
  local p = hs.pending
  if not p then
    app.go("home")
    return {}
  end
  local L, mine, theirs = app.load("lib/light"), app.me.g, p.g
  local pair, lm, lt = L.pair, L.of(mine), L.of(theirs)
  L = nil

  ui.label(0, 4, TITLES[mode][p.k], {size = 14, w = ui.W, align = "center", color = "green"})
  local ms, ts, G = app.stage(), p.st or 0, app.load("lib/genome")
  ui.label(0, 52, G.name(mine), {size = 14, w = 160, align = "center"})
  ui.label(150, 52, "vs", {size = 14, w = 20, align = "center", color = "dim"})
  ui.label(160, 52, G.name(theirs), {size = 14, w = 160, align = "center"})
  ui.label(0, 74, G.kind(mine, ms), {size = 12, w = 160, align = "center", color = "dim"})
  ui.label(160, 74, G.kind(theirs, ts), {size = 12, w = 160, align = "center", color = "dim"})
  local text = mode == "wait" and ("Waiting for " .. G.name(theirs) .. " to accept...")
    or ((p.k == "b" and "Battle " or "Splice with ") .. G.name(theirs) .. " (" .. p.o .. ")?")
  local line = ui.label(0, 120, text, {size = 14, w = ui.W, align = "center"})
  ui.hint(mode == "wait" and "CANCEL abort" or "SELECT accept   CANCEL decline")

  local function status(s)
    line:text(s)
    ui.hint("")
  end

  return {
    status = status,
    tick = function(t) pair(lm, lt, t, 500) end,
    key = function(k)
      local hs = app.hs
      if not (hs and hs.pending) or hs.pending.accepted then return end
      if k == "back" then hs.drop()
      elseif k == "select" and mode == "incoming" then
        hs.accept()
        status("Starting...")
      end
    end,
  }
end
