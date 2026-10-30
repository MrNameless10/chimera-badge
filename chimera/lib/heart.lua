local TOL <const>, LATENCY <const>, REST <const>, STALL_MS <const>, IDLE_MS <const>, GO_MS <const>, MAX_BEATS <const>, RESEND_MS <const> = 200, 250, 500, 4000, 30000, 1500, 24, 500

return function(app, s, c, broadcast, score, pulse, finish, need, goal, wave)
  local roster, n, now = s.roster, #s.roster, app.now
  local t_start, hits, next_go, last_word = now(), {}, 0, nil

  local function close(word)
    last_word, next_go = word, 0
    finish(word == "e")
  end

  local function evaluate()
    local beat = c.beat
    c.evaluated = beat
    local mask, got = hits[beat] or 0, 0
    for i = 0, n - 1 do got = got + (mask >> i & 1) end
    local ch = got >= need and c.chain + 1 or 0
    hits[beat - 1] = nil
    broadcast({c = "s", k = beat, ch = ch, hm = mask})
    score(beat, ch, mask)
    if ch >= goal then close("e")
    elseif beat >= MAX_BEATS then close("d") end
  end

  return {
    mesh = function(from, msg)
      local k, i = math.tointeger(msg.k), math.tointeger(msg.i)
      if msg.c == "h" and k and i and i >= 2 and i <= n and roster[i] == from then
        hits[k] = (hits[k] or 0) | (1 << (i - 1))
      end
    end,
    key = function(t)
      if c.evaluated ~= c.beat or c.t0 and t - c.t0 < wave + REST then return end
      local k = c.beat + 1
      hits[k] = 1
      broadcast({c = "b", k = k})
      pulse(k, t)
    end,
    tick = function(t)
      if last_word then
        if t - c.done < GO_MS and t >= next_go then
          next_go = t + RESEND_MS
          broadcast({c = last_word})
        end
        return
      end
      if t - t_start < GO_MS and t >= next_go then
        next_go = t + RESEND_MS
        broadcast({c = "g", m = roster, x = s.x})
      end
      if c.evaluated < c.beat and t - c.t0 >= wave + TOL + LATENCY then evaluate() end
      if last_word then return end
      local idle = t - (c.t0 or t_start)
      if c.chain > 0 and c.evaluated == c.beat and idle > wave + STALL_MS then
        broadcast({c = "s", k = 0, ch = 0, hm = 0})
        score(0, 0, 0)
      end
      if idle > IDLE_MS then close("d") end
    end,
  }
end
