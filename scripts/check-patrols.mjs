// Quick patrol presence check - run with: node scripts/check-patrols.mjs
import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = 'https://wmlcnmtnvjndlzahmocc.supabase.co';
const SUPABASE_KEY = process.env.SUPABASE_SECRET_KEY;
if (!SUPABASE_KEY) {
  console.error('SUPABASE_SECRET_KEY environment variable is required.');
  process.exit(1);
}

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

async function check() {
    console.log('ðŸ” Checking SafeSight Dispatch System Status...\n');

    // 1. Patrol presence
    const { data: presence, error: pErr } = await supabase
        .from('patrol_presence')
        .select('*')
        .order('last_seen', { ascending: false });

    if (pErr) {
        console.log('âŒ Error reading patrol_presence:', pErr.message);
        return;
    }

    const now = Date.now();
    const staleCutoff = new Date(now - 180 * 1000).toISOString();

    console.log('ðŸš” PATROL PRESENCE:');
    console.log(`   Total records: ${presence?.length || 0}`);

    const onlineWithGPS = presence?.filter(p =>
        p.is_online &&
        p.last_seen && p.last_seen >= staleCutoff &&
        p.latitude && p.longitude
    ) || [];

    console.log(`   âœ… Eligible for dispatch (online + fresh GPS): ${onlineWithGPS.length}`);

    for (const p of presence || []) {
        const isFresh = p.last_seen && p.last_seen >= staleCutoff;
        const hasGPS = p.latitude && p.longitude;
        const isEligible = p.is_online && isFresh && hasGPS;
        const status = isEligible ? 'ðŸŸ¢ ELIGIBLE' :
                      p.is_online && !isFresh ? 'ðŸŸ¡ STALE' :
                      p.is_online && !hasGPS ? 'ðŸ”´ NO GPS' : 'âšª OFFLINE';
        console.log(`   ${p.patrol_id}: ${status} (status: ${p.status}, last: ${p.last_seen?.slice(11,19) || 'never'})`);
        if (hasGPS) {
            console.log(`         GPS: ${p.latitude.toFixed(6)}, ${p.longitude.toFixed(6)}`);
        }
    }

    // 2. Active SOS incidents
    console.log('\nðŸš¨ SOS INCIDENTS:');
    const { data: incidents, error: iErr } = await supabase
        .from('incidents')
        .select('*')
        .eq('source', 'SOS')
        .in('status', ['ACTIVE', 'PENDING', 'NEW']);

    if (iErr) {
        console.log('   âŒ Error:', iErr.message);
    } else if (!incidents || incidents.length === 0) {
        console.log('   â„¹ï¸  No active SOS incidents');
    } else {
        console.log(`   Found ${incidents.length} incident(s):`);
        for (const inc of incidents) {
            console.log(`   - ${inc.id}: status=${inc.status}, risk=${inc.risk_level || '?'}`);
            console.log(`     Location: ${inc.latitude}, ${inc.longitude}`);
        }
    }

    // 3. Recent dispatches
    console.log('\nðŸ“¦ RECENT DISPATCHES:');
    const { data: dispatches, error: dErr } = await supabase
        .from('dispatches')
        .select('*')
        .order('created_at', { ascending: false })
        .limit(5);

    if (dErr) {
        console.log('   âŒ Error:', dErr.message);
    } else if (!dispatches || dispatches.length === 0) {
        console.log('   â„¹ï¸  No dispatches yet');
    } else {
        for (const d of dispatches) {
            const auto = d.data?.autoDispatched ? 'AUTO' : 'MANUAL';
            const symbol = d.status === 'SENT' ? 'ðŸ“¤' :
                           d.status === 'ACCEPTED' ? 'âœ…' :
                           d.status === 'DECLINED' ? 'âŒ' : 'â€¢';
            console.log(`   ${symbol} ${d.dispatch_id}: ${d.status} | ${d.patrol_team_name || d.patrol_id} | ${auto}`);
        }
    }

    // Summary
    console.log('\nðŸ“‹ SUMMARY:');
    if (onlineWithGPS.length === 0) {
        console.log('   âš ï¸  No eligible patrols! Patrol app must send GPS location.');
    } else if (!incidents || incidents.length === 0) {
        console.log('   â³ Patrols ready, waiting for SOS incidents...');
    } else {
        console.log('   âœ“ System ready to auto-dispatch!');
    }
    console.log('');
}

check().catch(console.error);
