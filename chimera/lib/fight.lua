local PICK_MS <const>, LOST_MS <const>, RETRY_MS <const>, GAP_MS <const>, FLASH_MS <const>, LINGER_MS <const> = 10000, 15000, 1000, 260, 400, 10000
local KEYS = {up = 1, left = 2, right = 3}

return function(app, foe, view)
  local B = app.load("lib/battle")
  local now, me, palette = app.now, app.me, view.palette
  local mine, theirs = B.fighter(me.g), B.fighter(foe.g)
  local first, sid = app.id < foe.id, tonumber(foe.sid) or 0
  local my, their = {}, {}
  local round, pick, done = 1, 1, nil
  local deadline, seen, next_send, sent, flash, left = 0, now(), 0, -GAP_MS, 0, -1

  local function bars()
    view.bar_me:set(mine.hp * 100 // mine.max)
    view.bar_foe:set(theirs.hp * 100 // theirs.max)
    view.me:text(view.my_name .. "  " .. mine.hp .. "/" .. mine.max)
    view.foe:text(theirs.hp .. "/" .. theirs.max .. "  " .. view.foe_name)
    local lit = (mine.hp * 6 + mine.max - 1) // mine.max
    for i = 1, 6 do
      if i <= lit then led.set(i, palette[3], palette[4], palette[5]) else led.set(i, 0, 0, 0) end
    end
    led.set(7, palette[6] >> 2, palette[7] >> 2, palette[8] >> 2)
    led.set(8, palette[6] >> 2, palette[7] >> 2, palette[8] >> 2)
  end

  local function highlight()
    for i = 1, 3 do view.opts[i]:color(i == pick and "green" or "dim") end
  end

  local function heading(s)
    view.title:text("ROUND " .. round .. "/" .. B.ROUNDS .. (s and "   " .. s or ""))
  end

  local function start_round()
    heading()
    deadline, left = now() + PICK_MS, -1
    view.status:text("")
    highlight()
    ui.hint("D-PAD choose   SELECT lock")
  end

  local function send()
    local p = {t = "b", s = foe.sid, r = round}
    local c, th = my[round], their[round]
    if c then
      p.h = c.h
      if th and th.h then p.m, p.n = c.m, c.n end
    end
    local prev = my[round - 1]
    if prev then p.pm, p.pn = prev.m, prev.n end
    if app.send(foe.id, p) then
      sent = now()
      next_send = sent + RETRY_MS
    else
      next_send = now() + GAP_MS
    end
  end

  local function soon()
    next_send = math.max(now(), sent + GAP_MS)
  end

  local function learn(r, h, m, n)
    if r < round or r > round + 1 then return false end
    local th = their[r]
    if not th then
      th = {}
      their[r] = th
    end
    local changed = false
    if not th.h and type(h) == "string" and #h == 8 then th.h, changed = h, true end
    if th.h and not th.m and m ~= nil then
      local mv, val = B.opens(sid, r, m, n, th.h)
      if mv then th.m, th.v, changed = mv, val, true end
    end
    return changed
  end

  local function finish()
    local w = B.winner(mine, theirs)
    done = now()
    view.status:text("")
    ui.hint("SELECT continue")
    if w < 0 then
      me.l = me.l + 1
      view.title:text("DEFEAT")
      view.title:color("pink")
    elseif w == 0 then
      view.title:text("DRAW")
      view.title:color("text")
    else
      me.w = me.w + 1
      view.title:text("VICTORY")
      local foes, known = me.foes, false
      for i = 1, #foes do
        if foes[i] == foe.id then
          known = true
          break
        end
      end
      local g, label, k
      if not known then g, label, k = B.reward(me.g) end
      if g then
        me.g = g
        table.insert(foes, 1, foe.id)
        for i = #foes, app.FOES_MAX + 1, -1 do foes[i] = nil end
        view.status:text("Mutation: " .. label .. " " .. k .. " -> " .. k + 1)
        view.status:color("green")
      else
        view.status:text(known and "Already mutated from this rival" or "Stats maxed out")
      end
    end
    app.gain(w > 0 and 3 or 2, w > 0)
  end

  local function settle()
    while not done do
      local c, th = my[round], their[round]
      if not (c and th and th.m) then return end
      local hm, hf = mine.hp, theirs.hp
      if first then
        B.round(mine, theirs, c.m, th.m, c.v ~ th.v)
      else
        B.round(theirs, mine, th.m, c.m, th.v ~ c.v)
      end
      view.line:text(string.format("%s vs %s   you %+d  foe %+d",
        view.names[c.m], view.foe_names[th.m], mine.hp - hm, theirs.hp - hf))
      bars()
      if mine.hp ~= hm then
        if mine.hp < hm then led.fill(255, 0, 0) else led.fill(0, 255, 0) end
        flash = now() + FLASH_MS
      end
      round = round + 1
      if B.over(mine, theirs, round) then finish() else start_round() end
    end
  end

  local function lock()
    local x = math.random(0, 0xFFFFFFF)
    my[round] = {m = pick, v = x, n = string.format("%x", x), h = B.commit(sid, round, pick, x)}
    highlight()
    heading()
    view.status:text("Locked. Waiting for " .. view.foe_name .. "...")
    ui.hint("")
    soon()
    settle()
  end

  bars()
  start_round()
  send()

  return {
    busy = true,
    mesh = function(from, msg)
      local r = math.tointeger(msg.r)
      if from ~= foe.id or msg.s ~= foe.sid or not r then return end
      seen = now()
      local a = learn(r, msg.h, msg.m, msg.n)
      local b = learn(r - 1, nil, msg.pm, msg.pn)
      if a or b then
        settle()
        soon()
      end
    end,
    key = function(k)
      if done then
        if k == "select" or k == "back" then app.go("home") end
        return
      end
      if my[round] then return end
      local m = KEYS[k]
      if m then
        pick = m
        highlight()
      elseif k == "select" then
        lock()
      end
    end,
    tick = function(t)
      if done then
        if t - done > LINGER_MS then return end
      elseif t - seen > LOST_MS then
        ui.toast("Signal lost")
        return app.go("home")
      elseif not my[round] then
        local s = (deadline - t + 999) // 1000
        if s <= 0 then
          lock()
        elseif s ~= left then
          left = s
          heading(s)
        end
      end
      if t >= next_send then send() end
      if flash ~= 0 and t >= flash then
        flash = 0
        bars()
      end
    end,
  }
end
