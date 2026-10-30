local APP = arg[1] or "chimera"
local STORE = arg[2] == "store"
local ONLY = arg[3] ~= "" and arg[3] or nil
local SEED = tonumber(arg[4]) or 0

local HOME = "SELECT scan   LEFT swarm   RIGHT lineage"
local SCAN = "SELECT splice   RIGHT battle   CANCEL back"
local WAIT = "CANCEL abort"
local ASK = "SELECT accept   CANCEL decline"
local PICK = "D-PAD choose   SELECT lock"
local DONE = "SELECT continue"

local results, current = {}, nil

local function screen(i) return sim.screen(i) end
local function lines(i) return table.concat(screen(i).lines, "\n") end
local function hint(i) return screen(i).hint end
local function has(i, s) return lines(i):find(s, 1, true) ~= nil end
local function data(i) return sim.data(i).c or {} end

local function check(ok, msg)
  if not ok then error(msg, 2) end
end

local function wait(pred, ms, what)
  for _ = 1, (ms or 10000) // 50 do
    if pred() then return true end
    sim.run(50)
  end
  check(pred(), "timed out waiting for " .. (what or "condition"))
  return true
end

local function on(i, h, ms) wait(function() return hint(i) == h end, ms, "screen '" .. h .. "' on badge " .. i) end
local function press(i, k) sim.key(i, k) sim.run(60) end

local function badges(n, extra)
  local ids = {}
  for k = 1, n do
    local spec = {app = APP, id = string.format("b%05d", k), owner = "player" .. k, store = STORE}
    for key, v in pairs(extra and extra[k] or {}) do spec[key] = v end
    ids[k] = sim.badge(spec)
  end
  return ids
end

local function settle(ids, ms)
  sim.run(ms or 3500)
  for _, i in ipairs(ids) do on(i, HOME) end
end

local function scenario(name, fn)
  if ONLY and not name:find(ONLY, 1, true) then return end
  sim.reset(SEED * 1000 + #results + 1)
  current = {name = name, peak = 0, fast = 0, big = 0, steps = 0}
  local ok, err = pcall(fn)
  for i = 1, 8 do
    local good, st = pcall(sim.state, i)
    if not good then break end
    current.peak = math.max(current.peak, st.peak)
    current.steps = math.max(current.steps, st.steps)
    current.fast = current.fast + st.too_fast
    current.big = current.big + st.too_big
    if ok and st.error then ok, err = false, "badge " .. i .. " " .. st.error end
  end
  current.ok, current.err = ok, err
  results[#results + 1] = current
  print(string.format("%-4s %-52s peak %5d  steps %6d  too_fast %3d%s", ok and "PASS" or "FAIL", name,
    current.peak, current.steps, current.fast, ok and "" or "\n      " .. tostring(err)))
  if not ok then
    for i = 1, 8 do
      local good, l = pcall(sim.logs, i)
      if not good then break end
      for k = math.max(1, #l - 6), #l do print("      [" .. i .. "] " .. l[k]) end
      print("      [" .. i .. "] screen: " .. lines(i):gsub("\n", " / ") .. "  hint: " .. hint(i))
    end
  end
end

local function offer(a, b, kind)
  press(a, "select")
  on(a, SCAN)
  wait(function() return not has(a, "Searching") end, 5000, "peer in scan list")
  press(a, kind == "b" and "right" or "select")
  on(a, WAIT)
  on(b, ASK)
end

local function battle(a, b, moves_a, moves_b)
  offer(a, b, "b")
  press(b, "select")
  for r = 1, 3 do
    for side, i in ipairs{a, b} do
      local mv = (side == 1 and moves_a or moves_b)[r]
      if mv then
        wait(function() return hint(i) == PICK or hint(i) == DONE end, 15000, "pick on " .. i)
        if hint(i) == PICK then
          if mv ~= "up" then press(i, mv) end
          press(i, "select")
        end
      end
    end
    if hint(a) == DONE and hint(b) == DONE then break end
  end
  on(a, DONE, 40000)
  on(b, DONE, 40000)
end

local function home_of(i)
  press(i, "select")
  on(i, HOME)
end

scenario("boot fresh badge shows a cub with 0 XP", function()
  local i = badges(1)[1]
  sim.run(1500)
  on(i, HOME)
  check(has(i, "YOUR FIRST CREATURE"), "fresh banner")
  check(has(i, "Cub  gen 1  0/10 XP"), "cub line: " .. lines(i))
  check(has(i, "No genetic signals nearby"), "no signals")
  check(screen(i).objects <= 64, "UI objects")
end)

scenario("boot without owner and without clock", function()
  sim.clock(false)
  local ids = badges(2, {{owner = false}, {owner = false}})
  settle(ids)
  check(has(ids[1], "1 genetic signal nearby"), "signals")
  battle(ids[1], ids[2], {"up", "up", "up"}, {"left", "left", "left"})
  home_of(ids[1])
  home_of(ids[2])
  offer(ids[1], ids[2], "s")
  press(ids[2], "select")
  on(ids[1], DONE, 10000)
  on(ids[2], DONE, 10000)
end)

scenario("meeting a badge gives 1 XP once", function()
  local ids = badges(2)
  settle(ids)
  check(data(ids[1]).xp == 1 and data(ids[2]).xp == 1, "xp after meeting")
  sim.link(ids[1], ids[2], false)
  sim.run(12000)
  check(has(ids[1], "No genetic signals nearby"), "peer expired")
  sim.link(ids[1], ids[2], true)
  sim.run(4000)
  check(has(ids[1], "1 genetic signal nearby"), "peer back")
  check(data(ids[1]).xp == 1, "same badge again gives no XP")
end)

scenario("scan lists peers with kind, ability and stage", function()
  local ids = badges(3)
  settle(ids)
  press(ids[1], "select")
  on(ids[1], SCAN)
  wait(function() return has(ids[1], "player2") and has(ids[1], "player3") end, 5000, "two peers")
  check(lines(ids[1]):find("cub, %u+") ~= nil, "kind and ability: " .. lines(ids[1]))
  check(has(ids[1], "| Cub"), "stage column")
  press(ids[1], "down")
  press(ids[1], "down")
  press(ids[1], "back")
  on(ids[1], HOME)
end)

scenario("navigation: lineage, swarm lobby, back, exit", function()
  local i = badges(1)[1]
  sim.run(1500)
  press(i, "right")
  wait(function() return has(i, "LINEAGE") end, 5000, "lineage")
  check(has(i, "No splices yet"), "empty lineage")
  press(i, "back")
  on(i, HOME)
  press(i, "left")
  wait(function() return has(i, "SWARM") end, 5000, "swarm")
  check(hint(i):find("Need 3 badges", 1, true) ~= nil, "needs 3")
  press(i, "back")
  on(i, HOME)
  press(i, "back")
  sim.run(200)
  check(not sim.state(i).running, "BACK on home closes the app")
end)

scenario("splice: both get a child, gen 2, +3 XP, stage kept", function()
  local ids = badges(2)
  settle(ids)
  local a0, b0 = data(ids[1]).g, data(ids[2]).g
  offer(ids[1], ids[2], "s")
  press(ids[2], "select")
  for _, i in ipairs(ids) do
    wait(function() return has(i, "NEW GENERATION") end, 10000, "result on " .. i)
    check(has(i, "Cub gen 2") or lines(i):find("cub  gen 2", 1, true), "cub gen 2: " .. lines(i))
  end
  local a, b = data(ids[1]), data(ids[2])
  check(a.gen == 2 and b.gen == 2, "gen")
  check(a.xp == 4 and b.xp == 4, "xp " .. a.xp .. " " .. b.xp)
  check(a.g ~= a0 or b.g ~= b0, "dna changed")
  check(#sim.data(ids[1]).log == 1, "lineage logged")
  home_of(ids[1])
  press(ids[1], "right")
  wait(function() return has(ids[1], "1 splices") end, 5000, "lineage entry")
end)

scenario("splice cooldown: same partner again is refused for 30 min", function()
  local ids = badges(2)
  settle(ids)
  offer(ids[1], ids[2], "s")
  press(ids[2], "select")
  on(ids[1], DONE, 10000)
  on(ids[2], DONE, 10000)
  home_of(ids[1])
  home_of(ids[2])
  press(ids[1], "select")
  on(ids[1], SCAN)
  press(ids[1], "select")
  sim.run(1500)
  local t = screen(ids[1]).toasts
  check(t[#t] and t[#t]:find("again in 30 min", 1, true), "cooldown toast: " .. tostring(t[#t]))
  on(ids[1], HOME, 5000)
end)

scenario("splice declined and offer timeout", function()
  local ids = badges(2)
  settle(ids)
  offer(ids[1], ids[2], "s")
  press(ids[2], "back")
  on(ids[1], HOME, 6000)
  on(ids[2], HOME, 6000)
  local t = screen(ids[1]).toasts
  check(t[#t] and t[#t]:find("declined", 1, true), "declined toast: " .. tostring(t[#t]))
  offer(ids[1], ids[2], "b")
  sim.link(ids[1], ids[2], false)
  on(ids[1], HOME, 25000)
  on(ids[2], HOME, 25000)
end)

scenario("battle: deterministic result on both badges, rewards and XP", function()
  local ids = badges(2)
  settle(ids)
  battle(ids[1], ids[2], {"up", "right", "left"}, {"left", "up", "right"})
  local la, lb = screen(ids[1]).lines, screen(ids[2]).lines
  local ha = {la[1]:match("(%d+)/(%d+)")}
  local hb = {lb[2]:match("(%d+)/(%d+)")}
  check(ha[1] and hb[1] and ha[1] == hb[1], "my HP equals what the foe sees: " .. la[1] .. " vs " .. lb[2])
  local a, b = data(ids[1]), data(ids[2])
  check(a.w + a.l + b.w + b.l <= 2, "one result each")
  check((a.w == 1) == (b.l == 1), "winner and loser agree")
  check(a.xp == 1 + (a.w == 1 and 3 or 2) and b.xp == 1 + (b.w == 1 and 3 or 2), "xp " .. a.xp .. " " .. b.xp)
end)

scenario("battle with 30% packet loss still agrees", function()
  local ids = badges(2)
  settle(ids)
  sim.loss(0.3)
  battle(ids[1], ids[2], {"up", "up", "up"}, {"right", "right", "right"})
  local a, b = data(ids[1]), data(ids[2])
  check((a.w == 1) == (b.l == 1) and (a.l == 1) == (b.w == 1), "results agree under loss")
end)

scenario("battle: nobody presses, rounds auto-lock", function()
  local ids = badges(2)
  settle(ids)
  offer(ids[1], ids[2], "b")
  press(ids[2], "select")
  on(ids[1], DONE, 45000)
  on(ids[2], DONE, 45000)
end)

scenario("battle: link lost mid-fight returns home", function()
  local ids = badges(2)
  settle(ids)
  offer(ids[1], ids[2], "b")
  press(ids[2], "select")
  on(ids[1], PICK, 10000)
  sim.link(ids[1], ids[2], false)
  on(ids[1], HOME, 25000)
  on(ids[2], HOME, 25000)
  local t = screen(ids[1]).toasts
  check(t[#t] == "Signal lost", "toast: " .. tostring(t[#t]))
end)

scenario("second win against the same rival gives no new mutation", function()
  local ids = badges(2)
  settle(ids)
  for _ = 1, 2 do
    battle(ids[1], ids[2], {"up", "up", "up"}, {"right", "right", "right"})
    home_of(ids[1])
    home_of(ids[2])
  end
  local foes = data(ids[1]).foes or {}
  local foes2 = data(ids[2]).foes or {}
  check(#foes <= 1 and #foes2 <= 1, "a rival is listed once")
end)

scenario("offer to a badge that is busy in a battle is declined", function()
  local ids = badges(3)
  settle(ids)
  offer(ids[1], ids[2], "b")
  press(ids[2], "select")
  on(ids[1], PICK, 10000)
  press(ids[3], "select")
  on(ids[3], SCAN)
  wait(function() return has(ids[3], "player1") end, 5000, "peer")
  press(ids[3], "right")
  on(ids[3], HOME, 10000)
  local t = screen(ids[3]).toasts
  check(t[#t] and t[#t]:find("declined", 1, true), "busy toast: " .. tostring(t[#t]))
end)

scenario("mutual offers at the same moment resolve to one battle", function()
  local ids = badges(2)
  settle(ids)
  press(ids[1], "select")
  press(ids[2], "select")
  on(ids[1], SCAN)
  on(ids[2], SCAN)
  sim.key(ids[1], "right")
  sim.key(ids[2], "right")
  sim.run(200)
  wait(function() return hint(ids[1]) == PICK and hint(ids[2]) == PICK end, 15000, "both in the same battle")
end)

scenario("growth: Young at 10 XP, Adult at 30, splice keeps the stage", function()
  local young = '{"c":{"g":"A3020690A","gen":1,"splices":0,"muts":0,"xp":8,"w":0,"l":0}}'
  local adult = '{"c":{"g":"53020693A","gen":3,"splices":2,"muts":0,"xp":28,"w":0,"l":0}}'
  local ids = badges(2, {{data = young}, {data = adult}})
  settle(ids)
  check(has(ids[1], "Cub  gen 1  9/10 XP"), "cub 9: " .. lines(ids[1]))
  battle(ids[1], ids[2], {"up", "up", "up"}, {"right", "right", "right"})
  local t1, t2 = screen(ids[1]).toasts, screen(ids[2]).toasts
  check(t1[#t1] == "Your creature grew up!", "young toast: " .. tostring(t1[#t1]))
  check(t2[#t2] == "Your creature is fully grown!", "adult toast: " .. tostring(t2[#t2]))
  home_of(ids[1])
  home_of(ids[2])
  check(has(ids[1], "Young  gen 1"), "young line: " .. lines(ids[1]))
  check(has(ids[2], "Adult  gen 3"), "adult line: " .. lines(ids[2]))
  check(screen(ids[2]).rects <= 38, "adult sprite rects")
  offer(ids[1], ids[2], "s")
  press(ids[2], "select")
  on(ids[1], DONE, 10000)
  on(ids[2], DONE, 10000)
  home_of(ids[1])
  home_of(ids[2])
  check(has(ids[1], "Young  gen 4"), "young kept after splice: " .. lines(ids[1]))
  check(has(ids[2], "Adult  gen 4"), "adult kept after splice: " .. lines(ids[2]))
end)

scenario("restart keeps the creature, XP and lineage", function()
  local ids = badges(2)
  settle(ids)
  offer(ids[1], ids[2], "s")
  press(ids[2], "select")
  on(ids[1], DONE, 10000)
  local before = data(ids[1])
  sim.restart(ids[1])
  sim.run(1500)
  on(ids[1], HOME)
  local after = data(ids[1])
  check(after.g == before.g and after.xp == before.xp and after.gen == before.gen, "persisted")
  check(not has(ids[1], "YOUR FIRST CREATURE"), "not fresh")
end)

local function swarm(n, hits)
  local ids = badges(n)
  settle(ids, 5000)
  for _, i in ipairs(ids) do press(i, "left") end
  wait(function() return hint(ids[1]):find("SELECT ignite", 1, true) ~= nil end, 10000, "heart ready")
  for _, i in ipairs(ids) do
    wait(function() return has(i, n .. " ready") end, 10000, "lobby full on " .. i)
  end
  press(ids[1], "select")
  for _, i in ipairs(ids) do wait(function() return has(i, "COLOSSUS") end, 10000, "colossus on " .. i) end
  local deadline = sim.now() + 90000
  while sim.now() < deadline do
    if has(ids[1], "EVOLVED") or has(ids[1], "dissolved") then break end
    if has(ids[1], "SELECT to start the heartbeat") or has(ids[1], "SELECT for the next beat") then
      sim.key(ids[1], "select")
      for k = 2, n do
        local pressed = false
        for _ = 1, 120 do
          sim.run(25)
          if hits and not pressed and has(ids[k], "NOW!") then
            sim.key(ids[k], "select")
            pressed = true
          end
          if pressed then break end
        end
      end
    end
    sim.run(50)
  end
  return ids
end

for _, n in ipairs{3, 4, 5, 6} do
  scenario("swarm of " .. n .. ": everyone on the beat evolves (+5 XP)", function()
    local ids = swarm(n, true)
    for _, i in ipairs(ids) do
      wait(function() return has(i, "EVOLVED") end, 20000, "evolved on " .. i)
    end
    for _, i in ipairs(ids) do
      check(data(i).xp == n - 1 + 5, "xp " .. tostring(data(i).xp))
    end
  end)
end

scenario("swarm of 3: nobody follows the beat, the colossus dissolves", function()
  local ids = swarm(3, false)
  for _, i in ipairs(ids) do
    wait(function() return has(i, "dissolved") end, 60000, "dissolved on " .. i)
  end
end)

scenario("radar: LEDs 7-8 blink in the nearest peer's colour", function()
  local ids = badges(2)
  settle(ids)
  sim.rssi(ids[1], ids[2], -45)
  sim.run(1500)
  local seen = {}
  for _ = 1, 30 do
    sim.run(50)
    local l = screen(ids[1]).leds
    seen[l[7]] = true
  end
  local n = 0
  for _ in pairs(seen) do n = n + 1 end
  check(n >= 2, "LED 7 changes")
end)

scenario("lonely for 2 h: glow fades but nothing breaks", function()
  local i = badges(1)[1]
  sim.run(2 * 3600 * 1000 + 60000)
  on(i, HOME)
end)

scenario("long session: 20 battles and splices in a row", function()
  local ids = badges(2)
  settle(ids)
  for _ = 1, 10 do
    battle(ids[1], ids[2], {"up", "left", "right"}, {"right", "up", "left"})
    home_of(ids[1])
    home_of(ids[2])
  end
  sim.clock(true, 1793000000 + 100000)
  for k = 1, 10 do
    sim.clock(true, 1793000000 + 100000 + k * 4000)
    offer(ids[1], ids[2], "s")
    press(ids[2], "select")
    on(ids[1], DONE, 10000)
    on(ids[2], DONE, 10000)
    home_of(ids[1])
    home_of(ids[2])
  end
  check(#sim.data(ids[1]).log == 10, "10 lineage entries")
end)

scenario("full lineage (16 entries) and 8 rivals still fit", function()
  local log = {}
  for k = 1, 16 do
    log[k] = string.format('"ROSA-%04d MIST-%04d %d 1793000000 someone %02d"', k, k, k, k)
  end
  local foes = {}
  for k = 1, 8 do foes[k] = string.format('"f%05d"', k) end
  local blob = '{"c":{"g":"53020693A","gen":30,"splices":30,"muts":9,"xp":200,"w":40,"l":12,"foes":[' ..
    table.concat(foes, ",") .. ']},"log":[' .. table.concat(log, ",") .. ']}'
  local ids = badges(2, {{data = blob}, {}})
  settle(ids)
  press(ids[1], "right")
  wait(function() return has(ids[1], "LINEAGE") end, 5000, "lineage")
  press(ids[1], "back")
  on(ids[1], HOME)
  battle(ids[1], ids[2], {"up", "up", "up"}, {"right", "right", "right"})
  home_of(ids[1])
  home_of(ids[2])
  offer(ids[1], ids[2], "s")
  press(ids[2], "select")
  on(ids[1], DONE, 10000)
  on(ids[2], DONE, 10000)
  check(sim.state(ids[1]).data_bytes < 16384, "storage under 16 KB")
end)

local failed = 0
for _, r in ipairs(results) do
  if not r.ok then failed = failed + 1 end
end
print(string.format("\n%d scenarios, %d failed (%s)", #results, failed, STORE and "store code" or "compiled on the badge"))
return failed == 0 and 0 or 1
