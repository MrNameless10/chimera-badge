local STEP <const>, TOL <const>, REST <const>, IDLE_MS <const>, GO_MS <const>, FLASH_MS <const> = 600, 200, 500, 30000, 1500, 250

return function(app, s, v, idx, need, goal)
  local roster, n = s.roster, #s.roster
  local rgb, pal, status = v.rgb, v.palette, v.status
  local wave = n * STEP
  local open, close_at = (idx - 1) * STEP - TOL, idx * STEP + TOL
  local set, now = led.set, app.now
  local c = {beat = 0, chain = 0, evaluated = 0, t0 = nil, done = nil, note = nil}
  local pressed, won, seen, shown = false, false, now(), nil
  local flash_until, fr, fg, fb = 0, 0, 0, 0

  local function say(text, colour)
    if text == shown then return end
    shown = text
    status:text(text)
    status:color(colour or "text")
  end

  local function broadcast(msg)
    msg.t, msg.s = "w", s.sid
    app.send("*", msg)
  end

  local function score(k, ch, mask)
    c.chain = ch
    v.bar:set(ch * 100 // goal)
    v.count:text("chain " .. ch .. "/" .. goal)
    for i = 1, n do v.parts[i]:color(mask & (1 << (i - 1)) ~= 0 and "green" or "pink") end
    c.note = k == 0 and "The heart stalled" or nil
  end

  local function pulse(k, t)
    if k <= c.beat then return end
    c.beat, c.t0, pressed, seen = k, t, false, t
  end

  local function finish(ok)
    if c.done then return end
    c.done, won = now(), ok
    ui.hint("SELECT continue")
    if not ok then return say("The colossus dissolved", "pink") end
    app.gain(5, true)
    v.bar:set(100)
    v.count:text("chain " .. goal .. "/" .. goal)
    local me, x = app.me, s.x
    local pick, diff = nil, 0
    for i = 1, 9 do
      if me.g:byte(i) ~= x:byte(i) then
        diff = diff + 1
        if math.random(diff) == 1 then pick = i end
      end
    end
    if not pick then return say("EVOLVED! You already carry its DNA", "green") end
    me.g = me.g:sub(1, pick - 1) .. x:sub(pick, pick) .. me.g:sub(pick + 1)
    v.remember(me.gen, v.name, "swarm of " .. n, v.rename(me.g))
    app.save(me)
    say("EVOLVED! Gained " .. v.labels[pick] .. " from " .. v.name, "green")
  end

  local heart = idx == 1 and app.load("lib/heart")(app, s, c, broadcast, score, pulse, finish, need, goal, wave)

  local function prompt(t)
    if c.done then return end
    local e = c.t0 and t - c.t0
    if heart then
      if c.evaluated < c.beat or e and e < wave + REST then return say("Pulse running...", "dim") end
      return say(c.note or (c.beat == 0 and "SELECT to start the heartbeat" or "SELECT for the next beat"))
    end
    if not e or e > close_at then return say(c.note or (c.beat == 0 and "Waiting for HEART" or "Watch the pulse"), "dim") end
    if e < open then return say(tostring((open - e) // STEP + 1), "dim") end
    say("NOW!", "green")
  end

  local function light(t)
    if flash_until > t then
      for i = 1, 8 do set(i, fr, fg, fb) end
      return
    end
    if c.done then
      for i = 1, 8 do
        if won then set(i, rgb((t // 90 + i + idx * 8) & 15)) else set(i, 0, 0, 0) end
      end
      return
    end
    local r, g, b = pal[3], pal[4], pal[5]
    local e = c.t0 and t - c.t0 - (idx - 1) * STEP or -1
    if e >= 0 and e < STEP then
      local pos = e * 6 // STEP + 1
      for i = 1, 6 do
        if i <= pos then set(i, r, g, b) else set(i, r >> 4, g >> 4, b >> 4) end
      end
      local k = 2 * e >= STEP and 255 or 0
      set(7, pal[6] * k >> 8, pal[7] * k >> 8, pal[8] * k >> 8)
      set(8, pal[6] * k >> 8, pal[7] * k >> 8, pal[8] * k >> 8)
    else
      for i = 1, 8 do set(i, r >> 4, g >> 4, b >> 4) end
    end
  end

  return {
    busy = true,
    mesh = function(from, msg)
      if msg.t ~= "w" or msg.s ~= s.sid then return end
      if heart then return heart.mesh(from, msg) end
      if from ~= roster[1] then return end
      local k = math.tointeger(msg.k)
      seen = now()
      if msg.c == "b" and k then
        pulse(k, seen)
      elseif msg.c == "s" and k then
        local ch, hm = math.tointeger(msg.ch), math.tointeger(msg.hm)
        if ch and hm then score(k, ch, hm) end
      elseif msg.c == "e" or msg.c == "d" then
        finish(msg.c == "e")
      end
    end,
    key = function(k)
      if c.done then
        if k == "select" or k == "back" then app.go("home") end
        return
      end
      if k == "back" then return app.go("home") end
      if k ~= "select" then return end
      local t = now()
      if heart then return heart.key(t) end
      if not c.t0 or pressed then return end
      pressed = true
      local e = t - c.t0
      if e >= open and e <= close_at then
        flash_until, fr, fg, fb = t + FLASH_MS, 0, 255, 0
        broadcast({c = "h", k = c.beat, i = idx})
      else
        flash_until, fr, fg, fb = t + FLASH_MS, 255, 0, 0
      end
    end,
    tick = function(t)
      if heart then
        heart.tick(t)
      elseif not c.done and t - seen > IDLE_MS + GO_MS then
        finish(false)
      end
      prompt(t)
      light(t)
    end,
  }
end
