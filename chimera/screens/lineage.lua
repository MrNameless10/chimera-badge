local function date(ts)
  if ts == 0 then return "" end
  local z = ts // 86400 + 719468
  local era = z // 146097
  local doe = z - era * 146097
  local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
  local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
  local mp = (5 * doy + 2) // 153
  local d = doy - (153 * mp + 2) // 5 + 1
  local m = mp < 10 and mp + 3 or mp - 9
  return string.format("%04d-%02d-%02d", yoe + era * 400 + (m <= 2 and 1 or 0), m, d)
end

return function(app)
  local me = app.me
  ui.label(10, 6, "LINEAGE  " .. me.splices .. " splices, " .. me.muts .. " mutations",
           {size = 14, color = "dim"})
  local rows, log = {}, storage.get("log")
  for _, e in ipairs(type(log) == "table" and log or {}) do
    local parent, child, gen, t, partner = tostring(e):match("^(%S+) (%S+) (%d+) (%d+) (.*)$")
    if parent then
      rows[#rows + 1] = {title = parent .. "  " .. partner, sub = "-> " .. child .. ", gen " .. gen, right = date(tonumber(t))}
    end
  end
  if #rows == 0 then rows[1] = "No splices yet. Find another badge!" end
  ui.list(0, 28, ui.W, ui.H - 44, rows, {})
  ui.hint("CANCEL back")

  return {
    key = function(k) if k == "back" then app.go("home") end end,
  }
end
