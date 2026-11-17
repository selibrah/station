// `node pipeline/opencli_shim.mjs <opencli args>` = opencli, with file upload that works.
// OpenCLI extension v1.0.24 attaches files by opening the file chooser from a script; Chrome refuses without a user
// gesture (jackwener/OpenCLI#2541), so every upload fails with "Page.fileChooserOpened not received".
// Here setFileInput streams the file into the page in base64 chunks (the daemon caps a command at 1 MB) and attaches
// it with DataTransfer instead. ponytail: delete this file once a fixed extension ships.
import {execFileSync} from 'node:child_process';
import {readFileSync, realpathSync} from 'node:fs';
import {basename, dirname, join} from 'node:path';
import {pathToFileURL} from 'node:url';

const ROOT = dirname(dirname(realpathSync(execFileSync('which', ['opencli']).toString().trim())));  // .../opencli/dist
const {Page} = await import(pathToFileURL(join(ROOT, 'src/browser/page.js')));
const CHUNK = 600 * 1024;  // raw bytes per call -> 800 KB base64, under the 1 MB command cap
const TYPES = {mp4: 'video/mp4', mov: 'video/quicktime', png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', webp: 'image/webp'};

Page.prototype.setFileInput = async function (files, selector) {
  await this.evaluate('window.__flossiFiles = []; 1');
  for (const f of files) {
    const buf = readFileSync(f);
    await this.evaluate('window.__flossiParts = []; 1');
    for (let i = 0; i < buf.length; i += CHUNK) {
      const b64 = buf.subarray(i, i + CHUNK).toString('base64');
      await this.evaluate(`window.__flossiParts.push(Uint8Array.from(atob(${JSON.stringify(b64)}), c => c.charCodeAt(0))); 1`);
    }
    const name = basename(f), type = TYPES[name.split('.').pop().toLowerCase()] ?? 'application/octet-stream';
    await this.evaluate(`window.__flossiFiles.push(new File(window.__flossiParts, ${JSON.stringify(name)}, {type: ${JSON.stringify(type)}}));
      window.__flossiParts = null; 1`);
  }
  const n = await this.evaluate(`(() => {
    const input = document.querySelector(${JSON.stringify(selector)});
    if (!(input instanceof HTMLInputElement)) return 0;
    const dt = new DataTransfer();
    for (const f of window.__flossiFiles) dt.items.add(f);
    input.files = dt.files;
    input.dispatchEvent(new Event('input', {bubbles: true}));
    input.dispatchEvent(new Event('change', {bubbles: true}));
    window.__flossiFiles = null;
    return input.files.length;
  })()`);
  if (!n) throw new Error(`setFileInput: no file input matches ${selector}`);
  if (String(await this.evaluate('location.host')).includes('instagram.com')) await igOriginalCrop(this);
};

// Instagram's composer defaults to a 1:1 crop when uploaded as a regular post, which squares our 9:16 reels.
// In the Reel composer, it is natively 9:16. Here we ensure 9:16 native format or select Original.
const IG_CROP = `(() => {
  const d = [...document.querySelectorAll('[role=dialog]')];
  const txt = (e) => (e.innerText || '').trim();
  const fullText = d.map(txt).join(' ').toLowerCase();
  // If the dialog is already in the Reel composer (or Edit stage), it is natively 9:16
  if (/create new reel|new reel|cover photo|trim video/.test(fullText)) {
    return 'original';
  }
  const ok = d.flatMap((x) => [...x.querySelectorAll('button')]).find((b) => txt(b) === 'OK');
  if (ok) { ok.click(); return 'dismissed'; }  // "Video posts are now shared as reels"
  const opt = d.flatMap((x) => [...x.querySelectorAll('span,div')]).find((e) => txt(e) === 'Original' && !e.children.length);
  if (opt) { (opt.closest('[role=button],button') || opt).click(); return 'original'; }
  const svg = document.querySelector('svg[aria-label="Select crop"], svg[aria-label="Select Crop"], [aria-label="Select crop"]');
  if (svg) { (svg.closest('[role=button],button') || svg.parentElement).click(); return 'opened'; }
  return 'wait';
})()`;

async function igOriginalCrop(page) {
  for (let i = 0; i < 40; i++) {
    const res = await page.evaluate(IG_CROP);
    if (res === 'original') return;
    // If Next button is already visible in a Reel composer and video preview is active, proceed
    const isReelReady = await page.evaluate(`(() => {
      const d = [...document.querySelectorAll('[role=dialog]')];
      const text = d.map((x) => (x.innerText || '').toLowerCase()).join(' ');
      const hasNext = d.flatMap((x) => [...x.querySelectorAll('button, div[role=button]')])
        .some((b) => ['next', 'suivant', 'التالي'].includes((b.innerText || '').trim().toLowerCase()));
      const hasVideo = document.querySelectorAll('[role=dialog] video').length > 0;
      return (hasNext && hasVideo) || /new reel|cover photo|trim/i.test(text);
    })()`);
    if (isReelReady) return;
    await new Promise((r) => setTimeout(r, 1000));
  }
  // Fallback: if video exists in dialog, allow proceeding
  const hasVideo = await page.evaluate(`document.querySelectorAll('[role=dialog] video').length > 0`);
  if (!hasVideo) {
    throw new Error('Instagram crop menu not found: refusing to post a square-cropped reel');
  }
}

process.argv.splice(1, 1, join(ROOT, 'src/main.js'));  // look like `opencli <args>` to the CLI parser
await import(pathToFileURL(join(ROOT, 'src/main.js')));
