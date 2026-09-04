#!/usr/bin/env node
/**
 * publish-release-now.mjs - Direct publish (credentials from SUPABASE_SECRET_KEY env var) + multi-part upload
 */
import { createClient } from '@supabase/supabase-js';
import { readFileSync, statSync } from 'fs';
import { resolve } from 'path';
import crypto from 'crypto';

const supabaseUrl = 'https://wmlcnmtnvjndlzahmocc.supabase.co';
const supabaseKey = process.env.SUPABASE_SECRET_KEY;
const PART_SIZE = 50 * 1024 * 1024; // 50MB parts

if (!supabaseKey) {
  console.error('SUPABASE_SECRET_KEY environment variable is required (service-role key).');
  process.exit(1);
}
const supabase = createClient(supabaseUrl, supabaseKey);

async function uploadPart(buffer, partPath) {
  const { error } = await supabase
    .storage
    .from('releases')
    .upload(partPath, buffer, {
      contentType: 'application/octet-stream',
      upsert: true,
    });
  if (error) throw error;
  const { data: { publicUrl } } = supabase.storage.from('releases').getPublicUrl(partPath);
  return publicUrl;
}

async function publishApp(app, filePath, version, code, notes) {
  const platformKey = app === 'patrol' ? 'android-patrol' : 'android-public';

  try {
    const fullPath = resolve(filePath);
    const stats = statSync(fullPath);
    const sizeBytes = stats.size;
    const sizeMB = (sizeBytes / 1024 / 1024).toFixed(2);

    console.log(`Ã°Å¸â€œÂ± Publishing ${app.toUpperCase()} v${version} (code ${code})`);
    console.log(`   Size: ${sizeMB} MB`);

    // Read APK and calculate checksum
    const apkBuffer = readFileSync(fullPath);
    const checksum = crypto.createHash('sha256').update(apkBuffer).digest('hex');

    // Split into parts (50MB max each)
    const parts = [];
    const numParts = Math.ceil(sizeBytes / PART_SIZE);
    console.log(`   Splitting into ${numParts} parts...`);

    for (let i = 0; i < numParts; i++) {
      const start = i * PART_SIZE;
      const end = Math.min(start + PART_SIZE, sizeBytes);
      const partBuffer = apkBuffer.slice(start, end);
      const partNum = i.toString().padStart(2, '0');
      const partPath = `${platformKey}/app-release.apk.part${partNum}`;

      console.log(`Ã¢ËœÂÃ¯Â¸Â  Uploading part ${i + 1}/${numParts}: ${partPath}`);
      const partUrl = await uploadPart(partBuffer, partPath);

      parts.push({
        path: `app-release.apk.part${partNum}`,
        size: partBuffer.length,
        sha256: crypto.createHash('sha256').update(partBuffer).digest('hex')
      });
    }

    // Create release manifest with parts
    const releaseData = {
      platform: platformKey,
      version: version,
      versionCode: code,
      fileName: 'app-release.apk',
      size: sizeBytes,
      sha256: checksum,
      parts: parts,
      notes: notes || `${app} v${version}`,
      mandatory: false,
      publishedAt: new Date().toISOString()
    };

    // Upload release.json
    const manifestPath = `${platformKey}/release.json`;
    console.log(`Ã°Å¸â€œÂ Uploading manifest: ${manifestPath}`);

    const { error: manifestError } = await supabase
      .storage
      .from('releases')
      .upload(manifestPath, Buffer.from(JSON.stringify(releaseData, null, 2)), {
        contentType: 'application/json',
        upsert: true,
      });

    if (manifestError) {
      console.error('Ã¢ÂÅ’ Manifest error:', manifestError.message);
      return;
    }

    console.log(`\nÃ¢Å“â€¦ ${app.toUpperCase()} v${version} published successfully!`);
    console.log(`   Ã°Å¸â€œÂ¦ ${parts.length} parts uploaded`);
    console.log(`   Ã°Å¸â€œÂ ${manifestPath}`);
    console.log(`   Ã°Å¸â€â€” ${supabaseUrl}/storage/v1/object/public/releases/${manifestPath}`);

  } catch (err) {
    console.error('Ã¢ÂÅ’ Error:', err.message);
  }
}

// Publish both apps
await publishApp('patrol', 'SafeSight-Patrol-v1.2.5.apk', '1.2.5', 10, 'SafeSight Patrol v1.2.5 - Latest version with bug fixes and improvements');
await publishApp('public', 'SafeSight-Public-v1.2.5.apk', '1.2.5', 10, 'SafeSight Public v1.2.5 - Latest version with bug fixes and improvements');

console.log('\nÃ°Å¸Å½â€° All releases published!');