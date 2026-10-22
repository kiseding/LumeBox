import { readFile } from 'node:fs/promises';
import { basename } from 'node:path';
import vm from 'node:vm';

// Syntax validation only. Full network/playback still needs an iOS device.
if (process.argv.length < 3) {
  throw new Error('Usage: node tool/verify_web_home_html.mjs path/to/home.html');
}
for (const path of process.argv.slice(2)) {
  const bytes = await readFile(path);
  if (bytes.length > 2 * 1024 * 1024) throw new Error(`${basename(path)} exceeds 2 MB`);
  const html = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  if (!/<(?:!doctype\s+html|html|head|body)(?:\s|>)/i.test(html)) throw new Error(`${basename(path)} is not HTML`);
  let scripts = 0;
  for (const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi)) {
    if (/\bsrc\s*=/i.test(match[1]) || /\btype\s*=\s*['"](?:application\/ld\+json|application\/json|module)/i.test(match[1])) continue;
    new vm.Script(match[2], { filename: `${basename(path)}#script${++scripts}` });
  }
  console.log(`${basename(path)}: ${bytes.length} bytes, ${scripts} inline scripts parsed`);
}
