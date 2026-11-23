import {build} from 'esbuild';
import {writeFileSync, readFileSync} from 'node:fs';
const result = await build({entryPoints:['viewer.js'], bundle:true, format:'esm', minify:true, write:false, target:'safari17'});
const src = result.outputFiles[0].text.replace(/<\/script/gi,'<\\/script');
const out = '../../iPhone/Resources/';
writeFileSync(out+'SystemDesktop.html', `<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src blob: data:"><style>html,body,main{height:100%;margin:0;background:#07090d;overflow:hidden}main{position:relative;touch-action:none}</style><main></main><script type=module>${src}</script>`);
const pkg = 'node_modules/@novnc/novnc/';
writeFileSync(out+'SystemDesktop-Licenses.txt', ['noVNC 1.7.0 source: https://github.com/novnc/noVNC/tree/v1.7.0', ...['LICENSE.txt','AUTHORS','docs/LICENSE.MPL-2.0','docs/LICENSE.BSD-2-Clause','docs/LICENSE.BSD-3-Clause','vendor/pako/LICENSE'].map(file => readFileSync(pkg+file,'utf8'))].join('\n\n'));
