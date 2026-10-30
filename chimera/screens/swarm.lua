local BEACON_MS <const>, TTL_MS <const>, MIN <const>, MAX <const>, LOBBY_MAX <const> = 1000, 3500, 3, 6, 12
local ORDINALS = {"1st", "2nd", "3rd", "4th", "5th", "6th"}

local function colossus(gs, n)
  local out, count = {}, {}
  for i = 1, 9 do
    for j = 1, n do count[gs[j]:byte(i)] = 0 end
    local best, top = 0, 0
    for j = 1, n do
      local b = gs[j]:byte(i)
      local c = count[b] + 1
      count[b] = c
      if c > top or c == top and b > best then best, top = b, c end
    end
    out[i] = best
  end
  return string.char(table.unpack(out))
end

return function(app)
  local G, L = app.load("lib/genome"), app.load("lib/light")
  local palette, valid, ROLES = L.of(app.me.g), app.valid, G.ROLES
  local members = {[app.id] = {g = app.me.g}}
  local ids, n, next_beacon = {}, 0, 0

  ui.label(10, 4, "SWARM", {size = 14, color = "green"})
  local info = ui.label(70, 6, "", {size = 12, w = 244, align = "right", color = "dim"})
  local you = ui.label(10, 24, "", {size = 14, w = 300})
  local list = ui.list(0, 46, ui.W, ui.H - 62, {}, {})

  local function rebuild()
    n = 0
    ids = {}
    for id in pairs(members) do
      n = n + 1
      ids[n] = id
    end
    table.sort(ids)
    local rows, me = {}, 0
    for i = 1, n do
      local id = ids[i]
      if id == app.id then me = i end
      rows[i] = {title = i .. "  " .. (ROLES[i] or "RESERVE") .. "  " .. G.name(members[id].g),
                 sub = id == app.id and "you" or id, right = i == 1 and "starts the pulse" or ""}
    end
    list:items(rows)
    you:text(me > MAX and "Reserve: wait for the next colossus"
      or ("You are " .. ROLES[me] .. ": stand " .. ORDINALS[me] .. " from the left"))
    if n < MIN then
      info:text(n .. "/" .. MIN .. " badges")
      ui.hint("Need " .. MIN .. " badges   CANCEL back")
    elseif me == 1 then
      info:text(n .. " ready")
      ui.hint("Line up, then SELECT ignite   CANCEL back")
    else
      info:text(n .. " ready")
      ui.hint("Line up, HEART ignites   CANCEL back")
    end
  end
  rebuild()

  local function ignite()
    local k = n < MAX and n or MAX
    local roster, gs = {}, {}
    for i = 1, k do
      roster[i] = ids[i]
      gs[i] = members[ids[i]].g
    end
    app.go("colossus", {sid = tostring(math.random(100000, 999999)), roster = roster, x = colossus(gs, k)})
  end

  return {
    busy = true,
    mesh = function(from, msg)
      if msg.t ~= "w" then return end
      if msg.c == "j" and valid(msg.g) then
        local m = members[from]
        if not m then
          if n >= LOBBY_MAX then return end
          members[from] = {g = msg.g, seen = app.now()}
          rebuild()
        else
          m.seen = app.now()
          if m.g ~= msg.g then
            m.g = msg.g
            rebuild()
          end
        end
      elseif msg.c == "g" and type(msg.s) == "string" and valid(msg.x) and type(msg.m) == "table" then
        local r = msg.m
        if #r < MIN or #r > MAX or r[1] ~= from then return end
        for i = 1, #r do
          if r[i] == app.id then
            return app.go("colossus", {sid = msg.s, roster = r, x = msg.x})
          end
        end
      end
    end,
    tick = function(t)
      if t >= next_beacon then
        next_beacon = t + BEACON_MS
        app.send("*", {t = "w", c = "j", g = app.me.g})
        local gone = false
        for id, m in pairs(members) do
          if m.seen and t - m.seen > TTL_MS then
            members[id] = nil
            gone = true
          end
        end
        if gone then rebuild() end
      end
      L.play(palette, t, app)
    end,
    key = function(k)
      if k == "back" then app.go("home")
      elseif k == "select" and n >= MIN and ids[1] == app.id then ignite() end
    end,
  }
end
