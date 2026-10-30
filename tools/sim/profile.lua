local APP, MODE, LOG = arg[1] or "chimera", arg[2], tonumber(arg[3]) or 0
local store = MODE == "store"

local function blob(n)
  local log = {}
  for k = 1, n do
    log[k] = string.format('"ROSA-%04d MIST-%04d %d 1793000000 someone %02d"', k, k, k, k)
  end
  return '{"c":{"g":"53020693A","gen":' .. (n + 1) .. ',"splices":' .. n .. ',"muts":0,"xp":40,"w":0,"l":0},"log":[' .. table.concat(log, ",") .. ']}'
end

local rows = {}
local function hint(i) return sim.screen(i).hint end
local function wait(f, ms) for _ = 1, ms // 50 do if f() then return true end sim.run(50) end return f() end
local function measure(name, i)
  local st = sim.state(i)
  rows[#rows + 1] = string.format("%-10s live %6s  objects %2d  text %4d", name, tostring(sim.live(i) or st.error), sim.screen(i).objects, sim.screen(i).text)
end

sim.reset(3)
local a = sim.badge{app = APP, id = "b00001", owner = "player1", store = store, data = LOG > 0 and blob(LOG) or nil}
local b = sim.badge{app = APP, id = "b00002", owner = "player2", store = store}
local c = sim.badge{app = APP, id = "b00003", owner = "player3", store = store}
sim.run(4000)
measure("home", a)
sim.key(a, "select") sim.run(1500) measure("scan", a)
sim.key(a, "back") sim.run(1500)
sim.key(a, "right") sim.run(1500) measure("lineage", a)
sim.key(a, "back") sim.run(1500)
sim.key(a, "select") sim.run(1500)
sim.key(a, "right") sim.run(800) measure("duel", a)
wait(function() return hint(b) == "SELECT accept   CANCEL decline" end, 5000)
sim.key(b, "select")
wait(function() return hint(a) == "D-PAD choose   SELECT lock" end, 8000) measure("battle", a)
wait(function() return hint(a) == "SELECT continue" end, 45000) measure("battle end", a)
sim.key(a, "select") sim.key(b, "select") sim.run(2500)
sim.key(a, "select") sim.run(1500) sim.key(a, "down") sim.key(a, "select") sim.run(800)
wait(function() return hint(b) == "SELECT accept   CANCEL decline" or hint(c) == "SELECT accept   CANCEL decline" end, 5000)
sim.key(b, "select") sim.key(c, "select")
sim.run(1200) measure("splice", a)
wait(function() return hint(a) == "SELECT continue" end, 10000) measure("result", a)
sim.key(a, "select") sim.key(b, "select") sim.key(c, "select") sim.run(2500)
for _, i in ipairs{a, b, c} do sim.key(i, "left") sim.run(100) end
sim.run(4000) measure("swarm", a)
sim.key(a, "select")
sim.run(2500) measure("colossus", a)
print(string.format("%s, %d lineage entries", store and "store code" or "compiled on the badge", LOG))
for _, r in ipairs(rows) do print("  " .. r) end
for _, i in ipairs{a, b, c} do if sim.state(i).error then print("  badge " .. i .. ": " .. sim.state(i).error) end end
return 0
