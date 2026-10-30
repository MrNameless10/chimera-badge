local G = {}

G.LABELS = {"HUE", "ACC", "PLS", "PAT", "HED", "BOD", "ATK", "DEF", "MUT"}
local ABILITIES = {"REGEN", "PIERCE", "SURGE", "DRAIN"}
G.ABILITIES = ABILITIES
G.STAGES = {"Cub", "Young", "Adult"}
G.ROLES = {"HEART", "WINGS", "BRAIN", "TAIL", "ARMOR", "CLAWS"}

local FAMILIES = {"cat", "bunny", "owl", "frog", "dragon", "slime", "beetle", "bear"}
local FORMS = {"Round", "Winged", "Tailed", "Finned", "Shelled", "Leggy", "Ghostly", "Robotic"}

local LOG_MAX <const> = 16
local B32 <const> = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
local PREFIX <const> = "EMBRBLAZFAWNZESTSOLALIMAMOSSJADETIDEMISTSKYEAZULNOVALILAVEXAROSA"

local function get(g, i)
  local b = g:byte(i)
  return b < 65 and b - 48 or b - 55
end

G.get = get

function G.name(g)
  local x = 0
  for i = 2, 6 do x = x << 4 | get(g, i) end
  x = (x * 0x9E3B5 + 0x5A5A5) & 0xFFFFF
  local p = get(g, 1) * 4
  return PREFIX:sub(p + 1, p + 4) .. "-" .. string.char(B32:byte((x >> 15) + 1), B32:byte((x >> 10 & 31) + 1),
                                                        B32:byte((x >> 5 & 31) + 1), B32:byte((x & 31) + 1))
end

function G.stat(g, i) return get(g, i) * 9 // 15 + 1 end

function G.ability(g) return ABILITIES[(get(g, 4) & 3) + 1] end

function G.kind(g, stage)
  local family = FAMILIES[(get(g, 5) & 7) + 1]
  if stage == 0 then return family:upper():sub(1, 1) .. family:sub(2) .. " cub" end
  return FORMS[(get(g, 6) & 7) + 1] .. " " .. family
end

function G.remember(gen, parent, partner, child)
  local log = storage.get("log")
  log = type(log) == "table" and log or {}
  table.insert(log, 1, string.format("%s %s %d %d %s", parent, child, gen, sys.time() or 0, partner))
  for i = #log, LOG_MAX + 1, -1 do log[i] = nil end
  storage.set("log", log)
end

return G
