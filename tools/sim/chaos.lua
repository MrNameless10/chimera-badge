local APP = arg[1] or "chimera"
local STORE = arg[2] == "store"
local ONLY = arg[3] ~= "" and arg[3] or nil
local SEED = tonumber(arg[4]) or 0

local HOME = "SELECT scan   LEFT swarm   RIGHT lineage"
local SCAN = "SELECT splice   RIGHT battle   CANCEL back"
local ASK = "SELECT accept   CANCEL decline"
local PICK = "D-PAD choose   SELECT lock"
local DONE = "SELECT continue"
local KEYS = {"up", "down", "left", "right", "select", "back"}

local results, rng = {}, 1

local function rand(n)
  rng = (rng * 1103515245 + 12345) & 0x7FFFFFFF
  return rng % n + 1
end

local function lines(i) return table.concat(sim.screen(i).lines, "\n") end
local function hint(i) return sim.screen(i).hint end
local function has(i, s) return lines(i):find(s, 1, true) ~= nil end

local function check(ok, msg) if not ok then error(msg, 2) end end

local function wait(pred, ms, what)
  for _ = 1, (ms or 10000) // 50 do
    if pred() then return true end
    sim.run(50)
  end
  check(pred(), "timed out waiting for " .. (what or "condition"))
end

local function on(i, h, ms) wait(function() return hint(i) == h end, ms, "'" .. h .. "' on " .. i) end

local function badges(n, extra)
  local ids = {}
  for k = 1, n do
    local spec = {app = APP, id = string.format("b%05d", k), owner = "player" .. k, store = STORE}
    for key, v in pairs(extra and extra[k] or {}) do spec[key] = v end
    ids[k] = sim.badge(spec)
  end
  return ids
end

local function alive(ids)
  for _, i in ipairs(ids) do
    local st = sim.state(i)
    check(not st.error, "badge " .. i .. ": " .. tostring(st.error))
  end
end

local function scenario(name, fn)
  if ONLY and not name:find(ONLY, 1, true) then return end
  rng = SEED * 7919 + #results + 1
  sim.reset(SEED * 1000 + #results + 1)
  local ok, err = pcall(fn)
  local peak = 0
  for i = 1, 12 do
    local good, st = pcall(sim.state, i)
    if not good then break end
    peak = math.max(peak, st.peak)
    if ok and st.error then ok, err = false, "badge " .. i .. " " .. st.error end
  end
  results[#results + 1] = ok
  print(string.format("%-4s %-60s peak %5d%s", ok and "PASS" or "FAIL", name, peak, ok and "" or "\n      " .. tostring(err)))
  if not ok then
    for i = 1, 12 do
      local good, l = pcall(sim.logs, i)
      if not good then break end
      for k = math.max(1, #l - 5), #l do print("      [" .. i .. "] " .. l[k]) end
    end
  end
end

local function value()
  local pick = rand(14)
  if pick == 1 then return "1" end
  if pick == 2 then return "-7" end
  if pick == 3 then return "2147483647" end
  if pick == 4 then return "-2147483648" end
  if pick == 5 then return "3.75" end
  if pick == 6 then return "1e300" end
  if pick == 7 then return '""' end
  if pick == 8 then return '"' .. string.rep("Z", rand(120)) .. '"' end
  if pick == 9 then return "true" end
  if pick == 10 then return "null" end
  if pick == 11 then return "[1,2,3]" end
  if pick == 12 then return '{"a":{"b":{"c":1}}}' end
  if pick == 13 then return '"ABCDEF012"' end
  return '"' .. ({"s", "b", "h", "o", "a", "go", "x", "w", "j", "g", "e", "d"})[rand(12)] .. '"'
end

local FIELDS = {"t", "s", "g", "gen", "st", "o", "k", "r", "h", "m", "n", "pm", "pn", "c", "i", "ch", "hm", "x"}
local TYPES = {"h", "o", "a", "go", "x", "b", "w"}
local SWARM = {"j", "g", "b", "h", "s", "e", "d"}

local function junk(sid)
  local parts = {}
  local t = TYPES[rand(#TYPES)]
  if rand(5) > 1 then parts[#parts + 1] = '"t":"' .. t .. '"' end
  if t == "w" and rand(4) > 1 then parts[#parts + 1] = '"c":"' .. SWARM[rand(#SWARM)] .. '"' end
  if sid and rand(2) == 1 then parts[#parts + 1] = '"s":"' .. sid .. '"' end
  for _ = 1, rand(6) do
    parts[#parts + 1] = '"' .. FIELDS[rand(#FIELDS)] .. '":' .. value()
  end
  if rand(6) == 1 then parts[#parts + 1] = '"m":["b00001","b00002","b00003"]' end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function fuzz(i, n, from, sid)
  for _ = 1, n do
    sim.inject(i, from or ("z" .. string.format("%05d", rand(99999))), junk(sid), rand(40))
    if rand(4) == 1 then sim.run(20) end
  end
  sim.run(300)
end

local function offer(a, b, kind)
  sim.key(a, "select") sim.run(1200)
  on(a, SCAN)
  wait(function() return not has(a, "Searching") end, 6000, "peer listed")
  sim.key(a, kind == "b" and "right" or "select")
  wait(function() return hint(b) == ASK end, 8000, "incoming offer")
end

scenario("fuzz: 4000 malformed messages on home and scan", function()
  local ids = badges(2)
  sim.run(3500)
  fuzz(ids[1], 2000)
  fuzz(ids[1], 500, "b00002")
  sim.key(ids[1], "select") sim.run(800)
  fuzz(ids[1], 1500)
  alive(ids)
end)

scenario("fuzz: malformed messages during the duel handshake", function()
  local ids = badges(2)
  sim.run(3500)
  offer(ids[1], ids[2], "b")
  fuzz(ids[1], 600, "b00002")
  fuzz(ids[2], 600, "b00001")
  fuzz(ids[1], 300)
  alive(ids)
end)

scenario("fuzz: malformed and forged battle messages from the rival", function()
  local ids = badges(2)
  sim.run(3500)
  offer(ids[1], ids[2], "b")
  sim.key(ids[2], "select")
  on(ids[1], PICK, 10000)
  for _ = 1, 6 do
    fuzz(ids[1], 200, "b00002")
    sim.inject(ids[1], "b00002", '{"t":"b","r":1,"h":"deadbeef","m":3,"n":"7"}')
    sim.inject(ids[1], "b00002", '{"t":"b","r":2,"pm":1,"pn":"zz"}')
    sim.run(2000)
  end
  on(ids[1], DONE, 60000)
  on(ids[2], DONE, 60000)
  alive(ids)
end)

scenario("fuzz: malformed swarm and colossus messages", function()
  local ids = badges(3)
  sim.run(4000)
  for _, i in ipairs(ids) do sim.key(i, "left") sim.run(60) end
  sim.run(3000)
  fuzz(ids[2], 800, "b00001")
  fuzz(ids[2], 400)
  wait(function() return hint(ids[1]):find("SELECT ignite", 1, true) ~= nil end, 8000, "heart ready")
  sim.key(ids[1], "select")
  sim.run(3000)
  fuzz(ids[1], 600, "b00002")
  fuzz(ids[2], 600, "b00001")
  fuzz(ids[3], 600)
  alive(ids)
end)

scenario("forged ignite from a stranger pulls nobody into a colossus", function()
  local ids = badges(1)
  sim.run(2000)
  sim.key(ids[1], "left") sim.run(500)
  sim.inject(ids[1], "zzzzzz", '{"t":"w","c":"g","s":"1","x":"AAAAAAAAA","m":["b00009","b00001","b00008"]}')
  sim.run(1500)
  check(has(ids[1], "SWARM"), "still in the lobby: " .. lines(ids[1]))
end)

scenario("flood: 60 badges in range at a conference", function()
  local ids = badges(2)
  sim.run(3000)
  for k = 1, 60 do
    local g = string.format("%X%08X", k % 16, (k * 40503 + 12345) & 0xFFFFFFF):sub(1, 9)
    sim.inject(ids[1], string.format("f%05d", k), '{"t":"h","g":"' .. g .. '","gen":' .. k .. ',"st":' .. (k % 3) .. ',"o":"visitor ' .. k .. '"}', k * 20)
  end
  sim.run(2000)
  sim.key(ids[1], "select") sim.run(1200)
  for _ = 1, 70 do sim.key(ids[1], "down") sim.run(20) end
  sim.key(ids[1], "right")
  sim.run(25000)
  alive(ids)
  check(sim.live(ids[1]) < 40000, "heap with 60 peers: " .. tostring(sim.live(ids[1])))
end)

scenario("flood: 60 badges keep sending hellos for a minute", function()
  local ids = badges(1)
  sim.run(2000)
  for round = 0, 20 do
    for k = 1, 60 do
      local g = string.format("%X%08X", k % 16, (k * 40503 + 12345) & 0xFFFFFFF):sub(1, 9)
      sim.inject(ids[1], string.format("f%05d", k), '{"t":"h","g":"' .. g .. '","gen":1,"st":0,"o":"v' .. k .. '"}', rand(3000))
    end
    sim.run(3000)
  end
  alive(ids)
  check(sim.live(ids[1]) < 40000, "heap with 60 peers: " .. tostring(sim.live(ids[1])))
end)

local CORRUPT = {
  '{"c":"not a table"}',
  '{"c":{"g":123}}',
  '{"c":{"g":"ZZZZZZZZZ","gen":1}}',
  '{"c":{"g":"A3020690A","gen":"x","xp":"lots","w":[],"l":{},"splices":-3,"muts":1e300}}',
  '{"c":{"g":"A3020690A","gen":2,"xp":12,"met":[1,2],"mates":["a"],"foes":"b00002"}}',
  '{"c":{"g":"A3020690A","gen":2,"xp":12,"met":{"a":1},"mates":{"b00002":"soon"},"foes":[1,true]}}',
  '{"c":{"g":"A3020690A","gen":2,"xp":-50},"log":"oops"}',
  '{"c":{"g":"A3020690A","gen":2,"xp":40},"log":[1,{"n":"old"},"one two",true,"A B 3 4 partner"]}',
  '[1,2,3]',
  '"just a string"',
  '{}',
}

for k, blob in ipairs(CORRUPT) do
  scenario("corrupt storage " .. k .. ": " .. blob:sub(1, 40), function()
    local ids = badges(2, {{data = blob}, {}})
    sim.run(3500)
    on(ids[1], HOME, 5000)
    sim.key(ids[1], "right") sim.run(800)
    sim.key(ids[1], "back") sim.run(800)
    offer(ids[1], ids[2], "b")
    sim.key(ids[2], "select")
    on(ids[1], DONE, 60000)
    sim.key(ids[1], "select") sim.key(ids[2], "select") sim.run(2500)
    offer(ids[1], ids[2], "s")
    sim.key(ids[2], "select")
    on(ids[1], DONE, 15000)
    sim.key(ids[1], "select") sim.run(1500)
    sim.key(ids[1], "right") sim.run(800)
    alive(ids)
  end)
end

local function invariants(ids, before)
  for k, i in ipairs(ids) do
    local st = sim.state(i)
    if st.running then
      local c = sim.data(i).c or {}
      local b = before[k]
      if b then
        check((c.xp or 0) >= (b.xp or 0), "xp went down on " .. i)
        check((c.gen or 1) >= (b.gen or 1), "gen went down on " .. i)
      end
      before[k] = {xp = c.xp, gen = c.gen}
      check(st.data_bytes < 16384, "storage full on " .. i)
      check(sim.screen(i).objects <= 64, "UI objects on " .. i)
    end
  end
end

for _, n in ipairs{2, 3, 4} do
  scenario("monkey: " .. n .. " badges, random keys for 15 min, lossy mesh", function()
    local ids = badges(n)
    sim.chaos{loss = 0.15, dup = 0.1, jitter = 120}
    sim.run(3000)
    local before = {}
    for step = 1, 4500 do
      local i = ids[rand(n)]
      sim.key(i, KEYS[rand(#KEYS)])
      sim.run(rand(8) * 25)
      local st = sim.state(i)
      if not st.running and not st.error then sim.restart(i) end
      if step % 100 == 0 then invariants(ids, before) end
      alive(ids)
    end
  end)
end

scenario("monkey: 6 badges with swarm-heavy keys", function()
  local ids = badges(6)
  sim.chaos{loss = 0.05, jitter = 60}
  sim.run(4000)
  local before = {}
  for step = 1, 4000 do
    local i = ids[rand(6)]
    local r = rand(10)
    sim.key(i, r <= 4 and "select" or r <= 6 and "left" or KEYS[rand(#KEYS)])
    sim.run(rand(6) * 25)
    local st = sim.state(i)
    if not st.running and not st.error then sim.restart(i) end
    if step % 100 == 0 then invariants(ids, before) end
    alive(ids)
  end
end)

local function interrupt(stage_name, setup, victim, recover_ms)
  scenario("leave mid-" .. stage_name, function()
    local ids = badges(2)
    sim.run(3500)
    setup(ids)
    sim.quit(ids[victim])
    local other = ids[3 - victim]
    wait(function() return hint(other) == HOME or hint(other) == DONE end, recover_ms, "other badge home or finished")
    sim.restart(ids[victim])
    sim.run(2000)
    on(ids[victim], HOME, 5000)
    alive(ids)
  end)
end

interrupt("offer (challenger leaves)", function(ids) offer(ids[1], ids[2], "b") end, 1, 30000)
interrupt("offer (target leaves)", function(ids) offer(ids[1], ids[2], "b") end, 2, 30000)
interrupt("battle", function(ids)
  offer(ids[1], ids[2], "b") sim.key(ids[2], "select") on(ids[1], PICK, 10000) sim.run(3000)
end, 1, 30000)
interrupt("splice accept", function(ids)
  offer(ids[1], ids[2], "s") sim.key(ids[2], "select") sim.run(150)
end, 2, 30000)

scenario("splice: restart right after accepting keeps one child, no double XP", function()
  local ids = badges(2)
  sim.run(3500)
  offer(ids[1], ids[2], "s")
  sim.key(ids[2], "select")
  on(ids[2], DONE, 10000)
  local c = sim.data(ids[2]).c
  sim.restart(ids[2])
  sim.run(3000)
  local d = sim.data(ids[2]).c
  check(d.g == c.g and d.xp == c.xp and d.gen == c.gen, "state changed across restart")
end)

scenario("swarm of 10: four reserves, HEART leaves mid-colossus", function()
  local ids = badges(10)
  sim.run(5000)
  for _, i in ipairs(ids) do sim.key(i, "left") sim.run(30) end
  sim.run(4000)
  check(has(ids[10], "Reserve"), "10th badge is a reserve: " .. lines(ids[10]))
  sim.key(ids[1], "select")
  sim.run(3000)
  for k = 2, 6 do check(has(ids[k], "COLOSSUS"), "member " .. k .. " joined") end
  check(has(ids[8], "SWARM"), "reserve stays in the lobby")
  sim.quit(ids[1])
  for k = 2, 6 do
    wait(function() return has(ids[k], "dissolved") end, 45000, "colossus dissolves on " .. k)
  end
  alive(ids)
end)

scenario("swarm: a member leaves mid-colossus, the rest carry on", function()
  local ids = badges(4)
  sim.run(5000)
  for _, i in ipairs(ids) do sim.key(i, "left") sim.run(30) end
  sim.run(4000)
  sim.key(ids[1], "select")
  sim.run(2500)
  sim.quit(ids[3])
  for _ = 1, 6 do
    sim.key(ids[1], "select")
    sim.run(4000)
  end
  for _, k in ipairs{1, 2, 4} do
    wait(function() return has(ids[k], "dissolved") or has(ids[k], "EVOLVED") or hint(ids[k]) == DONE end, 60000, "ends on " .. k)
  end
  alive({ids[1], ids[2], ids[4]})
end)

scenario("clock jumps back a day: cooldown does not lock forever", function()
  local ids = badges(2)
  sim.run(3500)
  offer(ids[1], ids[2], "s") sim.key(ids[2], "select")
  on(ids[1], DONE, 10000)
  sim.key(ids[1], "select") sim.key(ids[2], "select") sim.run(2500)
  sim.clock(true, 1793000000 - 86400)
  offer(ids[1], ids[2], "b")
  sim.key(ids[2], "select")
  on(ids[1], DONE, 60000)
  alive(ids)
end)

scenario("very slow mesh (800 ms latency, 40% loss) still finishes or gives up cleanly", function()
  local ids = badges(2)
  sim.run(3500)
  sim.chaos{loss = 0.4, latency = 800, jitter = 400, dup = 0.2}
  sim.key(ids[1], "select") sim.run(1500)
  sim.key(ids[1], "right")
  for _ = 1, 40 do
    if hint(ids[2]) == ASK then sim.key(ids[2], "select") end
    sim.run(500)
  end
  wait(function() return (hint(ids[1]) == DONE or hint(ids[1]) == HOME) and (hint(ids[2]) == DONE or hint(ids[2]) == HOME) end, 90000, "both settle")
  local a, b = sim.data(ids[1]).c, sim.data(ids[2]).c
  check((a.w or 0) + (a.l or 0) == (b.w or 0) + (b.l or 0), "both counted the same battles")
  alive(ids)
end)

local function splice_pair(a, b)
  offer(a, b, "s")
  sim.key(b, "select")
  on(a, DONE, 15000)
  on(b, DONE, 15000)
  sim.key(a, "select") sim.key(b, "select")
  sim.run(2500)
end

scenario("utf-8: long accented and emoji owner names are clipped on a character", function()
  local name = "Zé Ñandú Café Açaí Pão 🐉🐉🐉 ünïcödé"
  local ids = badges(2, {{}, {owner = name}})
  sim.run(3500)
  splice_pair(ids[1], ids[2])
  local log = sim.data(ids[1]).log
  check(type(log) == "table" and #log == 1, "lineage entry written")
  local partner = log[1]:match("^%S+ %S+ %d+ %d+ (.*)$")
  check(partner and #partner <= 24, "partner clipped to 24 bytes: " .. tostring(partner))
  check(utf8.len(partner) ~= nil, "partner is valid UTF-8: " .. partner)
  check(name:sub(1, #partner) == partner, "clipped on a character boundary")
end)

scenario("cooldowns stay bounded: 10 splice partners in 30 minutes", function()
  local ids = badges(11)
  sim.run(5000)
  for k = 2, 11 do
    for _, other in ipairs(ids) do
      if other ~= ids[1] and other ~= ids[k] then sim.link(ids[1], other, false) end
    end
    sim.link(ids[1], ids[k], true)
    sim.run(11000)
    splice_pair(ids[1], ids[k])
  end
  local n = 0
  for _ in pairs(sim.data(ids[1]).c.mates or {}) do n = n + 1 end
  check(n <= 8, "cooldowns kept: " .. n)
  check(sim.data(ids[1]).c.gen <= 9999, "generation bounded")
  check(#sim.data(ids[1]).log <= 16, "lineage bounded")
end)

scenario("600 different badges walk past: XP from meeting stays bounded", function()
  local ids = badges(1)
  sim.run(2000)
  for k = 1, 600 do
    local g = string.format("%X%08X", k % 16, (k * 40503 + 12345) & 0xFFFFFFF):sub(1, 9)
    sim.inject(ids[1], string.format("m%05d", k), '{"t":"h","g":"' .. g .. '","gen":1,"st":0,"o":"walker"}')
    if k % 20 == 0 then sim.run(1100) end
  end
  sim.run(12000)
  local xp = sim.data(ids[1]).c.xp
  check(xp >= 300 and xp <= 512, "XP from 600 badges with a 512-bucket set: " .. xp)
  alive(ids)
end)

scenario("worst-case stored data: generation at the cap, oversized lists", function()
  local log, foes = {}, {}
  for k = 1, 40 do log[k] = string.format('"ROSA-%04d MIST-%04d %d 1793000000 someone %02d"', k, k, k, k) end
  for k = 1, 30 do foes[k] = string.format('"f%05d"', k) end
  local blob = '{"c":{"g":"53020693A","gen":9999,"xp":5,"foes":[' .. table.concat(foes, ",") .. ']},"log":[' .. table.concat(log, ",") .. ']}'
  local ids = badges(2, {{data = blob}, {}})
  sim.run(3500)
  splice_pair(ids[1], ids[2])
  local d = sim.data(ids[1])
  check(d.c.gen == 9999, "generation stays at the cap: " .. tostring(d.c.gen))
  check(#d.log == 16, "lineage trimmed to 16: " .. #d.log)
  offer(ids[1], ids[2], "b")
  sim.key(ids[2], "select")
  on(ids[1], DONE, 60000)
  check(#sim.data(ids[1]).c.foes <= 8, "rivals trimmed to 8 at boot: " .. #sim.data(ids[1]).c.foes)
  alive(ids)
end)

local failed = 0
for _, ok in ipairs(results) do if not ok then failed = failed + 1 end end
print(string.format("\n%d chaos scenarios, %d failed (%s)", #results, failed, STORE and "store code" or "compiled on the badge"))
return failed == 0 and 0 or 1
