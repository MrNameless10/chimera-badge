local RETRY_MS <const>, OFFER_MS <const>, ACCEPT_MS <const>, GRACE_MS <const> = 1000, 20000, 8000, 4000

return function(app)
  local H, p = {}, nil

  local function set(v) p, H.pending = v, v end

  local function close(to, ...)
    set(nil)
    app.hs = nil
    if to then app.go(to, ...) end
  end

  local function begin(q)
    close(q.k == "b" and "battle" or "splice", q)
  end

  local function cooling(id, k)
    local t, expiry = sys.time(), app.me.mates[id]
    return k == "s" and t and expiry and expiry > t and (expiry - t + 59) // 60
  end

  function H.offer(id, k)
    local peer = app.peers[id]
    if not peer then return close() end
    local wait = cooling(id, k)
    if wait then
      ui.toast("Splice with them again in " .. wait .. " min")
      return close()
    end
    set({role = "out", k = k, id = id, sid = tostring(math.random(100000, 999999)),
         g = peer.g, gen = peer.gen, st = peer.st, o = peer.o, ends = app.now() + OFFER_MS, next = 0})
  end

  function H.accept()
    p.accepted, p.ends, p.next = true, app.now() + ACCEPT_MS, 0
  end

  function H.leave()
    app.send(p.id, {t = "x", s = p.sid})
  end

  function H.drop()
    H.leave()
    close("home")
  end

  local function incoming(from, msg)
    if p and p.sid == msg.s then
      p.ends = math.max(p.ends, app.now() + GRACE_MS)
      return
    end
    if (p and p.role == "in") or (p and p.id ~= from) or cooling(from, msg.k == "b" and "b" or "s") then
      app.send(from, {t = "x", s = msg.s})
      return
    end
    local peer = app.peers[from]
    if not peer then
      app.send(from, {t = "x", s = msg.s})
      return
    end
    local k = msg.k == "b" and "b" or "s"
    local q = {role = "in", k = k, id = from, sid = msg.s, g = peer.g, gen = peer.gen, st = peer.st, o = peer.o,
               ends = app.now() + GRACE_MS, next = 0}
    if p then
      if app.id > from then return end
      set(q)
      H.accept()
      local s = app.screen()
      if s.status then s.status("Starting...") end
      return
    end
    set(q)
  end

  local function accepted(from, msg)
    if not (p and p.role == "out" and p.sid == msg.s and p.id == from) then return end
    app.last_go = msg.s
    app.send(from, {t = "go", s = msg.s})
    begin({k = p.k, id = from, sid = msg.s, g = p.g, gen = p.gen, st = p.st, o = p.o})
  end

  local function go(from, msg)
    if p and p.role == "in" and p.accepted and p.sid == msg.s and p.id == from then begin(p) end
  end

  local function cancelled(from, msg)
    if not (p and p.sid == msg.s and p.id == from) then return end
    ui.toast(p.o .. (p.role == "out" and " declined" or " cancelled"))
    close("home")
  end

  local handlers = {o = incoming, a = accepted, go = go, x = cancelled}

  function H.mesh(from, k, msg)
    local handle = handlers[k]
    if handle then handle(from, msg) end
    if not p and app.hs == H then close() end
  end

  function H.tick(t)
    if t > p.ends then
      ui.toast(p.role == "out" and ("No answer from " .. p.o) or "Signal lost")
      return close("home")
    end
    if t < p.next then return end
    p.next = t + RETRY_MS
    local me, st = app.me, app.stage()
    if p.role == "out" then
      app.send(p.id, {t = "o", k = p.k, s = p.sid, g = me.g, gen = me.gen, st = st, o = app.owner})
    elseif p.accepted then
      app.send(p.id, {t = "a", s = p.sid, g = me.g, gen = me.gen, st = st, o = app.owner})
    end
  end

  return H
end
