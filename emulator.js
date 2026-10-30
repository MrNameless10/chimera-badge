const FILES = ["app.json", "data/sprites.bin", "lib/arena.lua", "lib/battle.lua", "lib/draw.lua", "lib/fight.lua", "lib/genome.lua", "lib/hand.lua", "lib/heart.lua", "lib/hull.lua", "lib/light.lua", "lib/pulse.lua", "main.lua", "screens/battle.lua", "screens/colossus.lua", "screens/duel.lua", "screens/home.lua", "screens/lineage.lua", "screens/result.lua", "screens/scan.lua", "screens/splice.lua", "screens/swarm.lua"];
const CHUNK = 128;
const root = new URL("chimera/", import.meta.url);
const input = document.querySelector("#emu-cmd");
const assign = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
const pause = ms => new Promise(done => setTimeout(done, ms));

const run = command => {
  assign.call(input, command);
  input.dispatchEvent(new Event("input", { bubbles: true }));
  input.form.requestSubmit();
};

const base64 = bytes => {
  let text = "";
  for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(text);
};

const fetchFile = async path => {
  const response = await fetch(new URL(path, root));
  if (!response.ok) throw new Error(`${path}: HTTP ${response.status}`);
  return base64(new Uint8Array(await response.arrayBuffer()));
};

if (!input) throw new Error("Run this on https://solana.com/breakpoint/badge/emulator with the console open");
const blobs = await Promise.all(FILES.map(fetchFile));
run("open home");
await pause(600);
for (let f = 0; f < FILES.length; f++) {
  const path = FILES[f], data = blobs[f];
  run(`lua put chimera ${path} begin`);
  for (let k = 0; k < data.length; k += CHUNK) {
    run(`lua put chimera ${path} ${data.slice(k, k + CHUNK)}`);
    if ((k / CHUNK) % 20 === 0) await pause(0);
  }
  run(`lua put chimera ${path} end`);
  await pause(5);
}
await pause(1500);
run("lua run chimera");
