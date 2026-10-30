import { readFile } from 'node:fs/promises';
import { WASI } from 'node:wasi';
import { argv, env, cwd } from 'node:process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
const here = dirname(fileURLToPath(import.meta.url));
const wasi = new WASI({ version: 'preview1', args: ['badgesim', ...argv.slice(2)], env: { ...env, SIM_CWD: cwd() }, preopens: { '/': '/' }, returnOnExit: true });
const mod = await WebAssembly.compile(await readFile(join(here, '.build', 'badgesim.wasm')));
process.exitCode = wasi.start(await WebAssembly.instantiate(mod, wasi.getImportObject()));
