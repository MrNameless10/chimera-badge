# CHIMERA

By MrNameless10. Creatures that live on the BP26 badge, breed by splicing DNA, battle, and fuse into a
colossus when several badges line up.

## Architecture: resident kernel + overlays

The badge gives an app 48 KB of Lua heap (Solana OS `main/lua/lua_host.c`), collected generationally, and
the data in `storage` lives in that heap too. A store install runs the store's compiled code from flash, so code
barely touches the heap; compiled on the badge (Try in emulator, Run on badge, `lua put`) a file costs about
2.5–3× its source size. The app is built like an overlay system:

| File | Lifetime | Role |
| --- | --- | --- |
| `main.lua` | resident | Kernel: state, storage, peers, routing, XP and stages, transitions, memory |
| `screens/*.lua` | while the screen is open | One overlay per screen |
| `lib/hand.lua` | duel screen | Offer / accept / go / decline handshake, splice cooldown |
| `lib/genome.lua` | while a screen uses it | Names, kinds, abilities, stats, roles, lineage |
| `lib/light.lua` | while a screen uses it | Palette, LED patterns, the light language's mood and radar LEDs |
| `lib/draw.lua` | while drawing | Reads one sprite record from `data/sprites.bin` |
| `lib/arena.lua`, `lib/hull.lua` | while building a screen | Battle and colossus layouts |
| `lib/fight.lua`, `lib/battle.lua` | during a battle | Battle logic; commit-reveal, xorshift32, rounds |
| `lib/pulse.lua` | during a colossus | Pulse display, timing window, evolution |
| `lib/heart.lua` | on the HEART badge | Beats, collected hits, chain, ending the colossus |

- `app.go(screen, ...)` queues a transition for the next tick. The kernel drops the old screen first, so its
  memory is free for the next one, and `app.load` keeps modules in a weak cache: the next screen reuses them
  while memory allows, and the collector frees them when it needs the room.
- The kernel forces a full collection before each screen and once a second (`pcall(table.create, 0x4000)` asks
  for more than the cap, so Lua collects everything before failing). Without it the generational collector lets
  the heap ride at the cap, and Lua cannot collect while it grows a stack (`ldo.c luaD_reallocstack`), so any
  deeper call could stop the app at random.
- Battle and colossus forget the peer list as they start (hellos pause on busy screens, so it would only expire),
  and come back to it with the next hello; the met bitmap keeps XP from repeating.
- Constants are `<const>`, folded into the code instead of living as upvalues.
- Battle and colossus build in stages: the screen lays out its view, drops the layout code, then compiles the logic;
  the HEART compiles its own part separately, so no badge parses more than about 4 KB at once.
- Lineage keeps the last 16 entries, one string each (`"parent child gen time partner"`), a quarter of a table's heap.
- The kernel keeps at most 8 peers: when a new one says hello and the list is full, it replaces the one with the
  weakest signal (RSSI from `mesh.nearby`), so in a crowd the badges in front of you stay listed. A badge that sends
  an offer or an accept always gets in, so nobody at the same signal strength is locked out of challenging you. Each peer costs
  about 260 bytes, 420 on the scan screen; 60 unlimited peers ran the heap out. The swarm lobby holds 12.
- Everything that comes from outside is checked: stored fields are whole, non-negative numbers or tables of the
  right type at boot, lineage entries that do not parse are skipped, peers' generations are clamped and names are
  cut to 24 bytes on a UTF-8 character boundary. The kernel owns the creature's limits (generation 9 999, rivals 8,
  splice cooldowns 8) and trims oversized lists at boot; `lib/genome.lua` keeps the lineage at 16.
- The kernel holds only what every screen needs; the light language's mood lives in `lib/light.lua` and the
  lineage writer in `lib/genome.lua`, so neither costs heap during a battle.
- Battle sprites stand still: the firmware keeps a UI object until `ui.clear`, so the arena drops its handles and
  the 52 rects cost nothing while `lib/fight.lua` compiles. Creatures bob on the other screens.
- Mesh: at most 4 messages a second per app, so `hello` pauses on busy screens, new peers get one coalesced
  broadcast, and the battle paces its sends 260 ms apart, retrying sooner when the badge refuses one.

### Data structures and worst cases

Every collection is bounded, so the worst case is a constant. At these sizes a linear scan over a small array beats
a heap or a binary search tree: no extra tables or prototypes, which on this badge cost more heap than they save.

| Structure | Bound | Operation | Cost |
| --- | --- | --- | --- |
| Peers (hash map id → peer) | 8 | hello, offer, accept | O(1); O(8) scan for the weakest when full |
| Signal map (id → RSSI) | 16, the firmware's `mesh.nearby` cap | refreshed once a second | O(16), table reused |
| Badges met (512-bit set, 16 words) | 512 buckets, 128 bytes | meet | O(len id) FNV-1a, O(1) test and set |
| Rivals (array, newest first) | 8 | battle won | O(8) search and insert |
| Splice cooldowns (hash map id → expiry) | 8, soonest expiry evicted | splice | O(8) |
| Lineage (array of strings) | 16 | splice, colossus | O(16) insert and trim |
| Sprite atlas index | 384 records | draw | O(1) direct addressing (2-byte offsets), then O(rects) |
| Names | 2^20 per family | name, inverse in the Bestiary | O(1) bijection `x·0x9E3B5 + 0x5A5A5 mod 2^20` |
| Colossus genome | 3–6 members × 9 genes | ignite | O(9n) per-gene mode with one counting table |
| Swarm lobby | 12 | join, leave | O(1); O(n log n) sort only when the roster changes |
| Battle round | 3 rounds | settle | O(1): commit-reveal hash, xorshift32 |

Integers are 32-bit on the badge. The LED and HP arithmetic peaks below 2^24; the name bijection and FNV-1a overflow
on purpose and keep only low bits, which modular arithmetic leaves exact; `sys.time()` cooldowns hold until 2038;
`sys.millis()` counts from app launch and wraps after 24.8 days open.

Live heap per screen, measured with the simulator (bytes, after a full collection):

| Screen | Store code | Compiled on the badge | Compiled, full lineage |
| --- | --- | --- | --- |
| Home | 23 000 | 32 200 | 33 500 |
| Scan | 25 500 | 36 400 | 37 500 |
| Duel | 24 700 | 33 000 | 34 200 |
| Battle | 30 800 | 43 100 | 44 300 |
| Splice | 21 700 | 27 400 | 28 600 |
| Result | 22 800 | 31 600 | 32 900 |
| Swarm | 25 400 | 33 700 | 34 700 |
| Colossus | 22 400 | 28 000 | 29 200 |

## Creatures

9 hex digits: HUE, ACCENT, PULSE, PATTERN, HEAD, BODY, ATTACK, DEFENCE, MUTATION.

- Name: HUE picks the family (EMBR, BLAZ … ROSA); genes 2–6 (20 bits) go through `x·0x9E3B5 + 0x5A5A5 mod 2^20`,
  a bijection, and are written as 4 Crockford base-32 characters. Different appearances never share a name.
  Stat mutations from battles never change it.
- Look: HEAD picks one of 8 heads (cat, bunny, owl, frog, dragon, slime, beetle, bear), BODY one of 8 bodies
  (round, winged, tailed, finned, shelled, leggy, ghostly, robotic). 5 colours from 2 genes: base = HUE,
  light = (HUE + white) / 2, accent = ACCENT (a darker HUE when both match), white, black.
- PATTERN sets both the LED animation and the battle ability, so you can read a rival's power from its lights:
  breathe = REGEN, chase = PIERCE, sparkle = SURGE, flicker = DRAIN.

### Sprites

`tools/sprites.py` draws every head × body × stage on a 12×13 grid and packs it as rectangles into
`data/sprites.bin` (25 KB, 384 records): a 2-byte big-endian offset per record, then per record a count and
3 bytes per rect (`x<<4|y`, `(w−1)<<4|(h−1)`, colour). Record id = `((stage·2 + lod)·8 + head)·8 + body`.
Each sprite takes the smallest of three covers (row scan, column scan, largest first): ≤ 38 rects at full
detail, ≤ 26 at combat detail, which merges head and body shading so two creatures fit the battle screen.
`lib/draw.lua` reads one record with two `fs.read` calls. Regenerate with:

```
python3 tools/sprites.py chimera/data/sprites.bin
```

### Stages

| Stage | XP | Sprite |
| --- | --- | --- |
| Cub | 0–9 | Head and feet |
| Young | 10–29 | Body without accents |
| Adult | 30+ | Full body |

XP: a new badge met +1 (a 512-bit set indexed by FNV-1a of the badge id, so each badge counts once, even when the
peer list is full), battle +2 (win +3), splice +3,
evolved colossus +5. A splice keeps your stage; the new DNA changes the look, never the growth.

### Light language

- The pattern is the temperament and the ability.
- For 10 minutes after a win, a splice or an evolution, the pattern runs twice as fast.
- After an hour without meeting anyone the glow fades from full to about a third over the next hour.
- LEDs 7–8 are a radar: the colour of the strongest CHIMERA nearby, blinking faster as it gets closer
  (150–1000 ms over −40…−90 dBm).

## Splice

Each gene comes from either parent; the MUTATION genes of both set the mutation odds (≤ 1/8 per gene).
Each badge splices independently. The same pair can splice again only after 30 minutes.
The result screen shows each gene coloured by origin: white yours, aqua theirs, pink mutated.

## Battle

3 rounds, 10 s per pick. UP attack, LEFT defend, RIGHT ability, SELECT lock.
ATTACK beats ABILITY, ABILITY beats DEFEND, DEFEND beats ATTACK. HP = 8 + 2·DEF.

Tuned with a simulator over random creatures: the optimal mix is 34/34/32 (a fair rock-paper-scissors), the four
abilities are worth 6.2–6.4 on average, 29% of battles end in a knock-out, and the higher-stat creature wins 66%.

Commit-reveal per round, seed = `nonce_a xor nonce_b`, inputs in badge-id order, so both badges compute the same
HP without sending it. A win raises ATK, DEF or MUT by one point, once per rival among the last 8.

## Chain reaction (swarm)

Home → LEFT. The lobby tells each player their role and where to stand ("WINGS: stand 2nd from the left").
The lowest badge id is HEART and ignites with SELECT once 3–6 badges are in.

- The colossus genome is the per-gene mode of the members (O(9n), ties to the higher value).
- Each badge shows its segment of one long body: the head on HEART, the tapering tail on the last badge.
- HEART presses SELECT to beat. The pulse lights badge `i` at `(i−1)·600 ms`; everyone else presses SELECT
  when the screen says NOW (±200 ms). If HEART waits too long the chain resets ("The heart stalled").
- A pulse counts when enough badges hit. Quorum and chain length per group size keep the odds steady
  (≈ 80% success at 80% accuracy for any size):

| Badges | Must hit | Chain to evolve |
| --- | --- | --- |
| 3 | 3 | 4 |
| 4 | 4 | 3 |
| 5 | 4 | 6 |
| 6 | 5 | 5 |

On evolution every member inherits one gene where it differs from the colossus, logged in the lineage.

## Mesh

`h` hello · `o` offer (`k`: `s` splice, `b` battle) · `a` accept · `go` (a partner's first battle round counts as
`go` too, so a lost `go` cannot strand an accepted battle) · `x` decline/busy · `b` battle round ·
`w` swarm (`j` join, `g` ignite, `b` beat, `h` hit, `s` score, `e` evolved, `d` dissolved).

## Test

### Simulator

`tools/sim` runs the app on simulated badges without a browser. It compiles Solana OS's own Lua 5.5 and its
JSON code to 32-bit WebAssembly, like the badge and the emulator, and copies the host: the 48 KB allocator,
generational collection, 200 000 instructions per callback, 50 ms ticks, list key routing, 64 UI objects, 6 KB of
label text, `storage` in the heap, mesh at 4 messages a second and 200 bytes, `fs.load` from the card in 256-byte
pieces, and store code loaded in place. Boot heap matches the emulator within 2 %.

```
brew install zig
tools/sim/build.sh
tools/sim/badgesim tools/sim/scenarios.lua chimera dev
tools/sim/badgesim tools/sim/scenarios.lua chimera store
tools/sim/badgesim tools/sim/profile.lua chimera store 30
```

`scenarios.lua` plays 26 scenarios with 1–6 badges: boot (fresh, no owner, no clock), meeting XP, scan, navigation
and exit, splice (result, cooldown, decline, timeout, restart), battle (determinism, 30 % packet loss, auto-lock,
lost link, repeat rival, busy target, mutual offers), growth to Young and Adult, swarms of 3–6 (evolve and
dissolve), radar, two lonely hours, 20 games in a row and a full lineage. Arguments: app folder, `dev` or `store`,
a name filter, a seed.

`chaos.lua` tries to break it: 4 000 malformed or forged messages per screen (wrong types, huge numbers, long
strings, spoofed rival ids, forged battle reveals and colossus ignitions), 60 badges in range, 11 corrupted
`data.json` files, monkey tests of random keys for 15 simulated minutes on 2–6 badges over a lossy, duplicating,
reordering mesh (checking that XP and generation never go down and storage stays under 16 KB), leaving at every
stage of an offer, battle and splice, a 10-badge swarm whose HEART walks away, a member leaving mid-colossus, the
clock jumping back a day, and an 800 ms, 40 % loss mesh.

Also: names with accents and emoji cut at 24 bytes, 10 splice partners in 30 minutes, 600 different badges walking
past, a stored generation at the cap and oversized stored lists.

Both suites pass 2 928 runs (24 seeds × 2 modes × 61 scenarios); the busiest callback runs 13 131 of the 200 000
instructions a callback may use.

### Emulator

Drop the folder on https://solana.com/breakpoint/badge/apps/submit → **Try in emulator**.
More badges: `/breakpoint/badge/emulator?badge=2`, `?badge=3`; each must join "Solana Demo" Wi-Fi once (any
password) to get a mesh id. Background tabs throttle timers to about once a second, so play the swarm's
600 ms windows on real badges or in a foreground tab.
