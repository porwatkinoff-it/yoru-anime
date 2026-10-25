// Собирает JASSUB (рендерер субтитров) в src/ui/vendor: страница грузит его без сборщика.
import { build } from 'esbuild';
import { copyFileSync } from 'fs';
const out = 'src/ui/vendor';
const jassub = 'node_modules/jassub/dist';
await build({ entryPoints: ['subs/entry.js'], bundle: true, format: 'esm', outfile: `${out}/jassub.js`, minify: true, logLevel: 'warning' });
await build({ entryPoints: [`${jassub}/worker/worker.js`], bundle: true, format: 'esm', outfile: `${out}/jassub-worker.js`, minify: true, logLevel: 'warning' });
for (const f of ['wasm/jassub-worker.wasm', 'wasm/jassub-worker-modern.wasm', 'default.woff2']) copyFileSync(`${jassub}/${f}`, `${out}/${f.split('/').pop()}`);
console.log('vendor ready');
