// Test SOS auto-dispatch - creates a test SOS and triggers auto-dispatch
// Usage: node scripts/test-sos-dispatch.mjs
import { initializeApp, cert } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import fs from 'fs';
import path from 'path';

// Initialize Firebase Admin
const sa = JSON.parse(fs.readFileSync(path.resolve(process.cwd(), 'serviceAccountKey.json'), 'utf8'));
const app = initializeApp({ credential: cert(sa), projectId: sa.project_id });
const db = getFirestore(app);

if (!process.env.SUPABASE_SECRET_KEY) {
  console.error('SUPABASE_SECRET_KEY environment variable is required.');
  process.exit(1);
}

async function testSosDispatch() {
    console.log('ðŸ§ª Creating test SOS incident...\n');

    // Get PATROLE-01 location
    const { createClient } = await import('@supabase/supabase-js');
    const supabase = createClient(
        'https://wmlcnmtnvjndlzahmocc.supabase.co',
        process.env.SUPABASE_SECRET_KEY
    );

    const { data: patrol } = await supabase
        .from('patrol_presence')
        .select('*')
        .eq('patrol_id', 'PATROLE-01')
        .maybeSingle();

    if (!patrol || !patrol.latitude) {
        console.log('âŒ PATROLE-01 not found or has no GPS');
        process.exit(1);
    }

    // Create SOS at location NEAR the patrol (500m away)
    const sosLat = patrol.latitude + 0.0045; // ~500m north
    const sosLng = patrol.longitude + 0.0045; // ~500m east

    const sosId = `TEST-SOS-${Date.now()}`;
    const incidentData = {
        id: sosId,
        source: 'SOS',
        eventType: 'MOBILE_SOS',
        riskLevel: 'CRITICAL',
        status: 'ACTIVE',
        title: 'TEST SOS - Auto-Dispatch Verification',
        cameraId: 'SOS-MOBILE',
        latitude: sosLat,
        longitude: sosLng,
        sosId: sosId,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
        reportedBy: 'TEST-SCRIPT',
        location: { latitude: sosLat, longitude: sosLng },
    };

    console.log(`ðŸ“ Creating SOS at: ${sosLat.toFixed(6)}, ${sosLng.toFixed(6)}`);
    console.log(`ðŸ“ Patrol location: ${patrol.latitude.toFixed(6)}, ${patrol.longitude.toFixed(6)}`);

    // Calculate distance
    const R = 6371;
    const dLat = (sosLat - patrol.latitude) * (Math.PI / 180);
    const dLon = (sosLng - patrol.longitude) * (Math.PI / 180);
    const a = Math.sin(dLat / 2) ** 2 + Math.cos(patrol.latitude * (Math.PI / 180)) * Math.cos(sosLat * (Math.PI / 180)) * Math.sin(dLon / 2) ** 2;
    const dist = R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));

    console.log(`ðŸ“ Distance to patrol: ${dist.toFixed(2)} km\n`);

    // Write to Firestore (triggers the bridge)
    await db.collection('incidents').doc(sosId).set(incidentData);
    console.log(`âœ… SOS created: ${sosId}`);
    console.log('â³ Waiting for auto-dispatch (bridge should trigger within 5 seconds)...\n');

    // Check Supabase for the mirrored incident
    await new Promise(r => setTimeout(r, 3000));
    const { data: mirrored } = await supabase
        .from('incidents')
        .select('*')
        .eq('id', sosId)
        .maybeSingle();

    if (mirrored) {
        console.log('âœ… SOS mirrored to Supabase:', mirrored.id);
        console.log('   Status:', mirrored.status);
        console.log('   Risk:', mirrored.risk_level);
    } else {
        console.log('âš ï¸  SOS not yet mirrored (bridge may be offline)');
    }

    // Wait for dispatch
    console.log('\nâ³ Checking for dispatch (waiting 5 seconds)...');
    await new Promise(r => setTimeout(r, 5000));

    const { data: dispatch } = await supabase
        .from('dispatches')
        .select('*')
        .eq('incident_id', sosId)
        .maybeSingle();

    if (dispatch) {
        console.log('\nðŸŽ‰ DISPATCH CREATED!');
        console.log('   Dispatch ID:', dispatch.dispatch_id);
        console.log('   Status:', dispatch.status);
        console.log('   Patrol:', dispatch.patrol_team_name || dispatch.patrol_id);
        console.log('   Distance:', dispatch.distance_km?.toFixed(2) + ' km');
        console.log('   ETA:', dispatch.eta_minutes + ' min');
        console.log('   Auto-dispatched:', dispatch.data?.autoDispatched ? 'YES âœ…' : 'MANUAL');
    } else {
        console.log('\nâš ï¸  No dispatch created yet');
        console.log('   Possible reasons:');
        console.log('   - Bridge service not running');
        console.log('   - Auto-dispatch disabled in config');
        console.log('   - No eligible patrols');
    }

    console.log('\nðŸ“‹ Run this to monitor:');
    console.log('   node scripts/check-patrols.mjs');
    console.log('');
    process.exit(0);
}

testSosDispatch().catch(e => {
    console.error('Error:', e.message);
    process.exit(1);
});
