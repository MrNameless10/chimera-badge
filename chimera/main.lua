local HELLO_MS <const>, REPLY_MS <const>, PEER_TTL <const>, PEERS_MAX <const>, NAME_MAX <const> = 3000, 250, 10000, 8, 24
local GEN_MAX <const>, FOES_MAX <const>, MATES_MAX <const> = 9999, 8, 8
local SWEEP_MS <const>, SWEEP_SLOTS <const>, HIGH_KB <const>, MET_WORDS <const>, BOB_MS <const>, BOB_PX <const> = 1000, 0x4000, 40, 16, 450, 2
local RSSI_NEAR <const>, RSSI_FAR <const>, RSSI_UNHEARD <const>, BLINK_MS <const>, BLINK_PER_DB <const> = -40, -90, -100, 150, 17
local IDLE = {busy = true}
local STAGE_XP = {10, 30}
local GROWN = {"Your creature grew up!", "Your creature is fully grown!"}

local app = {peers = {}, np = 0, pv = 0, body = {}}
local modules = setmetatable({}, {__mode = "v"})
local function clip(s, n)
  if #s <= n then return s end
  while n > 0 and s:byte(n + 1) & 0xC0 == 0x80 do n = n - 1 end
  return s:sub(1, n)
end

app.id = badge.id() or ""
app.owner = clip(badge.owner() or app.id, NAME_MAX)
app.GEN_MAX, app.FOES_MAX, app.MATES_MAX, app.STAGE_XP = GEN_MAX, FOES_MAX, MATES_MAX, STAGE_XP
app.social, app.blink = sys.millis(), SWEEP_MS

local function valid(g)
  return type(g) == "string" and #g == 9 and not g:find("[^0-9A-F]")
end

app.valid = valid

local function count(v, low)
  v = math.tointeger(v)
  return v and v >= low and v or low
end

local function list(t)
  return type(t) == "table" and t or {}
end

local me = storage.get("c")
app.fresh = not (type(me) == "table" and valid(me.g))
if app.fresh then
  me = {g = string.format("%04X%05X", math.random(0, 0xFFFF), math.random(0, 0xFFFFF))}
end
me.gen, me.xp, me.w, me.l = count(me.gen, 1), count(me.xp, 0), count(me.w, 0), count(me.l, 0)
me.splices, me.muts = count(me.splices, 0), count(me.muts, 0)
me.gen = me.gen > GEN_MAX and GEN_MAX or me.gen
me.foes, me.mates, me.met = list(me.foes), list(me.mates), list(me.met)
for i = #me.foes, FOES_MAX + 1, -1 do me.foes[i] = nil end
for id, t in pairs(me.mates) do
  if not math.tointeger(t) then me.mates[id] = nil end
end
for i = 1, MET_WORDS do me.met[i] = math.tointeger(me.met[i]) or 0 end

local screen, queued = IDLE, nil
local next_hello, next_sweep, bob, shown_pv = 0, 0, 0, 0
local heard = {}

function app.now() return sys.millis() end

function app.save(m)
  app.me = m
  storage.set("c", m)
end

app.save(me)

local function stage_of(xp)
  return xp >= STAGE_XP[2] and 2 or xp >= STAGE_XP[1] and 1 or 0
end

function app.stage() return stage_of(app.me.xp) end

function app.gain(n, cheer)
  local m = app.me
  local before = stage_of(m.xp)
  m.xp = m.xp + n
  if cheer then app.cheered = app.now() end
  app.save(m)
  local after = stage_of(m.xp)
  if after > before then ui.toast(GROWN[after]) end
end

local function meet(id)
  local h = 0x811C9DC5
  for i = 1, #id do h = (h ~ id:byte(i)) * 0x01000193 end
  local met, word, bit = app.me.met, (h >> 5 & MET_WORDS - 1) + 1, 1 << (h & 31)
  app.social = app.now()
  if met[word] & bit ~= 0 then return end
  met[word] = met[word] | bit
  app.gain(1)
end

local function radar()
  local ok, nearby = pcall(mesh.nearby)
  app.near = nil
  for id in pairs(heard) do heard[id] = nil end
  if not ok or type(nearby) ~= "table" then return end
  local best = RSSI_UNHEARD
  for _, n in ipairs(nearby) do
    local p, r = app.peers[n.id], math.tointeger(n.rssi) or RSSI_FAR
    heard[n.id] = r
    if p then
      p.r = r
      if r > best then best, app.near = r, p.g end
    end
  end
  best = best > RSSI_NEAR and RSSI_NEAR or best < RSSI_FAR and RSSI_FAR or best
  app.blink = BLINK_MS + (RSSI_NEAR - best) * BLINK_PER_DB
end

function app.load(path)
  local m = modules[path]
  if m == nil then
    local f, err = fs.load(path .. ".lua")
    if not f then error(err, 0) end
    m = f()
    modules[path] = m
  end
  return m
end

function app.send(to, msg)
  local ok, sent = pcall(mesh.send, to, msg)
  return ok and sent == true
end

function app.screen() return screen end

function app.forget()
  app.peers, app.np, app.pv = {}, 0, app.pv + 1
  for id in pairs(heard) do heard[id] = nil end
end

function app.go(...)
  queued = table.pack(...)
end

local function collect()
  pcall(table.create, SWEEP_SLOTS)
end

local function show(q)
  screen = IDLE
  ui.clear()
  ui.bg("bg")
  app.body, bob = {}, 0
  collect()
  screen = app.load("screens/" .. q[1])(app, table.unpack(q, 2, q.n))
end

function app.hand()
  if not app.hs then app.hs = app.load("lib/hand")(app) end
  return app.hs
end

local function hello()
  app.send("*", {t = "h", g = app.me.g, gen = app.me.gen, st = app.stage(), o = app.owner})
end

local function room(from, asked)
  if app.np < PEERS_MAX then return true end
  local weakest, low = nil, asked and RSSI_NEAR + 1 or heard[from] or RSSI_UNHEARD
  for id, p in pairs(app.peers) do
    if p.r < low then weakest, low = id, p.r end
  end
  if not weakest then return false end
  app.peers[weakest] = nil
  app.np = app.np - 1
  return true
end

local function touch(from, msg)
  local p = app.peers[from]
  local gen, st = count(msg.gen, 1), math.tointeger(msg.st) or 0
  gen, st = gen > GEN_MAX and GEN_MAX or gen, st < 0 and 0 or st > 2 and 2 or st
  if not p then
    meet(from)
    if not room(from, msg.t ~= "h") then return nil end
    p = {r = heard[from] or RSSI_UNHEARD}
    app.peers[from] = p
    app.np, app.pv = app.np + 1, app.pv + 1
    if msg.t == "h" then next_hello = math.min(next_hello, app.now() + REPLY_MS) end
  elseif p.g ~= msg.g or p.gen ~= gen or p.st ~= st then
    app.pv = app.pv + 1
  end
  p.g, p.gen, p.st, p.o, p.seen = msg.g, gen, st, clip(tostring(msg.o or from), NAME_MAX), app.now()
  return p
end

function on_mesh(from, msg)
  if type(msg) ~= "table" then return end
  local k, s = msg.t, msg.s
  if k == "b" or k == "w" then
    if k == "b" and app.hs then app.hs.mesh(from, "go", msg) end
    if screen.mesh then screen.mesh(from, msg) end
    return
  end
  if k == "h" or k == "o" or k == "a" then
    if not (valid(msg.g) and touch(from, msg)) then return end
  end
  if type(s) ~= "string" then return end
  if k == "a" and s == app.last_go then
    app.send(from, {t = "go", s = s})
  elseif app.hs then
    app.hs.mesh(from, k, msg)
  elseif k == "o" then
    if screen.busy then app.send(from, {t = "x", s = s}) else app.go("duel", "incoming", from, msg) end
  end
end

function on_key(k, rep)
  if rep or not screen.key then return true end
  return screen.key(k) ~= false
end

function on_tick()
  local t = app.now()

  if queued then
    local q = queued
    queued = nil
    show(q)
  end

  if t >= next_hello then
    next_hello = t + HELLO_MS
    if not screen.busy then hello() end
  end

  if t >= next_sweep then
    next_sweep = t + SWEEP_MS
    for id, p in pairs(app.peers) do
      if t - p.seen > PEER_TTL then
        app.peers[id] = nil
        app.np, app.pv = app.np - 1, app.pv + 1
      end
    end
    radar()
    if collectgarbage("count") > HIGH_KB then collect() end
    if shown_pv ~= app.pv then
      shown_pv = app.pv
      if screen.peers then screen.peers() end
    end
  end

  if app.hs then app.hs.tick(t) end
  if screen.tick then screen.tick(t) end

  local off = (t // BOB_MS & 1) * BOB_PX
  if off ~= bob then
    bob = off
    local body = app.body
    for i = 1, #body, 2 do
      local p = body[i + 1]
      body[i]:pos(p >> 16, (p & 0xFFFF) + off)
    end
  end
end

function on_exit()
  if app.hs then app.hs.leave() end
end

app.go("home")
