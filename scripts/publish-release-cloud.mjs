// ============================================================================
// publish-release-cloud.mjs â€” publish an app release to the CLOUD update path.
//
// Uploads the release binary AND a small release.json manifest into the
// project's Supabase Storage `releases` (public) bucket so that in-app
// updates work from ANY network (mobile data, other Wi-Fi) without the LAN
// backend being reachable:
//
//   releases/<platform>/<fileName>    the binary (APK / zip)
//   releases/<platform>/release.json  { platform, version, versionCode, ...,
//                                       downloadUrl }
//
// The Flutter apps / desktop app read release.json first (cloud, always
// reachable) and fall back to the LAN backend (fast on-premise path).
//
// Usage (same args as publish-release.mjs):
//   node scripts/publish-release-cloud.mjs --platform android-patrol --file <apk> --version 1.1.2 --code 4 --notes "..."
//   node scripts/publish-release-cloud.mjs --platform web-controlroom --file <zip> --version 1.0.1 --code 2 --notes "..."
// ============================================================================
import { createRequire } from 'module';
import { pathToFileURL } from 'url';
import crypto from 'crypto';
import fs from 'fs';
import path from 'path';

function arg(name, def = undefined) {
  const i = process.argv.indexOf('--' + name);
  return i > -1 && process.argv[i + 1] ? process.argv[i + 1] : def;
}
const platform = arg('platform');
const file = arg('file');
const version = arg('version');
const code = parseInt(arg('code', '0'), 10);
const notes = arg('notes', '');
const mandatory = process.argv.includes('--mandatory');

if (!platform || !file || !version || !code) {
  console.error('Usage: node scripts/publish-release-cloud.mjs --platform <android-patrol|android-public|win32|web-controlroom> --file <path> --version <x.y.z> --code <int> [--notes "..."] [--mandatory]');
  process.exit(1);
}
const absFile = path.resolve(file);
if (!fs.existsSync(absFile)) {
  console.error('File not found: ' + absFile);
  process.exit(1);
}

// ---- Supabase credentials from backend/.env (service role â€” server side only)
const envText = fs.readFileSync(path.resolve(process.cwd(), 'backend', '.env'), 'utf8');
function env(name) {
  const m = envText.match(new RegExp('^' + name + '=(.*)$', 'm'));
  return m ? m[1].trim() : '';
}
const SUPABASE_URL = env('SUPABASE_URL').replace(/\/$/, '');
const SERVICE_KEY = env('SUPABASE_SECRET_KEY');
if (!SUPABASE_URL || !SERVICE_KEY) {
  console.error('SUPABASE_URL / SUPABASE_SECRET_KEY missing from backend/.env');
  process.exit(1);
}
const BUCKET = 'releases';

async function sbFetch(pathName, opts = {}) {
  const res = await fetch(`${SUPABASE_URL}/storage/v1/${pathName}`, {
    ...opts,
    headers: {
      // Storage requires BOTH headers with the new-style secret keys.
      Authorization: `Bearer ${SERVICE_KEY}`,
      apikey: SERVICE_KEY,
      ...(opts.headers || {}),
    },
  });
  return res;
}

// ---- 1. ensure the public bucket exists -------------------------------------
{
  const res = await sbFetch('bucket', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: BUCKET, public: true }),
  });
  if (res.ok) {
    console.log('storage: created public bucket "releases"');
  } else {
    const t = await res.text();
    if (/already exists|duplicate/i.test(t)) {
      console.log('storage: bucket "releases" already exists');
    } else {
      console.error('storage: bucket create failed:', res.status, t);
      process.exit(1);
    }
  }
}

// ---- 2. upload the binary in <=48MB parts -----------------------------------
// The Storage plan caps single objects at 50MB, so every binary is split
// into parts (<platform>/<fileName>.partNN) and the manifest lists them.
// Clients download the parts, concatenate, and verify the overall sha256.
const fileName = path.basename(absFile).replace(/\s+/g, '-');
const buf = fs.readFileSync(absFile);
const size = buf.length;
const sha256 = crypto.createHash('sha256').update(buf).digest('hex');
const PART_SIZE = 48 * 1024 * 1024; // 48MB < 50MB plan cap
const partCount = Math.ceil(size / PART_SIZE);
const parts = [];
console.log(`upload: ${platform}/${fileName} (${(size / 1048576).toFixed(1)} MB) in ${partCount} part(s) â€¦`);
for (let i = 0; i < partCount; i++) {
  const chunk = buf.subarray(i * PART_SIZE, Math.min((i + 1) * PART_SIZE, size));
  const partName = `${fileName}.part${String(i).padStart(2, '0')}`;
  const partSha = crypto.createHash('sha256').update(chunk).digest('hex');
  const res = await sbFetch(`object/${BUCKET}/${platform}/${partName}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/octet-stream', 'x-upsert': 'true' },
    body: chunk,
  });
  if (!res.ok) {
    console.error(`upload failed (${partName}):`, res.status, (await res.text()).slice(0, 300));
    process.exit(1);
  }
  parts.push({ path: partName, size: chunk.length, sha256: partSha });
  console.log(`upload: ${partName} (${(chunk.length / 1048576).toFixed(1)} MB) done`);
}

// ---- 3. upload the release manifest ------------------------------------------
const manifest = {
  platform,
  version,
  versionCode: code,
  fileName,
  size,
  sha256,
  parts,
  notes: String(notes || ''),
  mandatory: !!mandatory,
  publishedAt: new Date().toISOString(),
};
{
  const res = await sbFetch(`object/${BUCKET}/${platform}/release.json`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-upsert': 'true' },
    body: JSON.stringify(manifest),
  });
  if (!res.ok) {
    console.error('manifest upload failed:', res.status, (await res.text()).slice(0, 300));
    process.exit(1);
  }
}

const manifestUrl = `${SUPABASE_URL}/storage/v1/object/public/${BUCKET}/${platform}/release.json`;
console.log('manifest: ' + manifestUrl);
console.log(`PUBLISHED â˜ â€” clients on ANY network will see v${version} (code ${code}).`);
