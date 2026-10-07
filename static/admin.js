'use strict';
const $ = id => document.getElementById(id);
function toast(t){ const e=$('toast'); e.textContent=t; e.classList.add('show'); setTimeout(()=>e.classList.remove('show'),2400); }
function esc(s){ const d=document.createElement('div'); d.textContent=String(s); return d.innerHTML; }

// Every admin POST carries this header: the server refuses admin POSTs without
// it, which a cross-site page cannot add (CSRF protection). The explicit '{}'
// body guarantees a Content-Length header, which the server also requires.
function adminPost(url, body) {
  return fetch(url, { method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'att-admin' },
    body: JSON.stringify(body || {}) });
}

const KIND_PILL = {
  'same student': 'ok', 'ID corrected': 'ok', 'name corrected': 'ok',
  'different student': 'warn', 'refused: ID in use': 'err',
};

function fmtDist(m) {
  if (m == null) return '—';
  return m >= 1000 ? (m / 1000).toFixed(2) + ' km' : m + ' m';
}

let refreshing = false;
async function refresh() {
  if (refreshing) return;
  refreshing = true;
  try {
    const r = await fetch('/admin/state');
    if (r.status === 401 || r.status === 403) { location.href = '/admin'; return; }
    if (!r.ok) { return; }
    const d = await r.json();
    $('count').textContent = d.count;
    $('devices').textContent = d.devices;
    $('mergeN').textContent = d.merges.length;
    $('sharedIp').textContent = d.shared_ip;
    $('session').textContent = 'Session: ' + d.session_id + '  ·  Course: ' + d.course
      + '  ·  ' + d.submissions + ' submissions logged';
    if (d.geofence) {
      $('geoPanel').style.display = 'block'; $('rad').textContent = d.audit_radius_km;
      $('oobStat').style.display = ''; $('dlAudit').style.display = '';
      $('oob').textContent = d.out_of_bounds;
      $('oobStat').classList.toggle('alert', d.out_of_bounds > 0);
      $('lowStat').style.display = ''; $('low').textContent = d.low_accuracy;
      $('hallSrc').textContent = d.hall
        ? 'pinned at ' + d.hall[0].toFixed(5) + ', ' + d.hall[1].toFixed(5)
        : "median of students' precise fixes";
      $('unpinHall').style.display = d.hall ? '' : 'none';
    }

    $('rows').innerHTML = d.recent.map(x =>
      `<tr><td class="ar">${esc(x.name)}${x.edited?' <span style="color:#ffb020">✎</span>':''}${x.gps?' 📍':''}`
      + `${x.shared_ip?' <span class="pill warn">shared IP</span>':''}</td>`
      + `<td>${esc(x.id)}</td><td>${esc(x.timestamp).replace('T',' ')}</td>`
      + `<td class="${x.out?'out':x.low?'low':''}">${esc(fmtDist(x.dist_m))}`
      + `${x.acc!=null?' <small>±'+esc(x.acc)+' m</small>':''}`
      + `${x.out?' ⚠ out':x.low?' ⚠ low accuracy':''}</td></tr>`).join('')
      || '<tr><td colspan="4" class="empty">No submissions yet.</td></tr>';

    const m = d.merges;
    $('merges').innerHTML = m.length ? m.map(e => {
      const kind = String(e.kind || '');
      const pill = `<span class="pill ${KIND_PILL[kind] || 'warn'}">${esc(kind)}</span>`;
      return `<tr><td>${esc(e.time).replace('T',' ')}</td>`
        + `<td class="ar">${esc(e.old_id)} · ${esc(e.old_name)}</td>`
        + `<td class="ar">${esc(e.new_id)} · ${esc(e.new_name)}</td>`
        + `<td>${esc(e.ip)}</td><td>${esc(fmtDist(e.dist_m))}</td><td>${pill}</td></tr>`;
    }).join('') : '<tr><td colspan="6" class="empty">No edits or conflicts yet.</td></tr>';
  } catch (e) {}
  finally { refreshing = false; }
}

$('dl').addEventListener('click', () => { window.location = '/admin/download?file=final'; });
$('dlRaw').addEventListener('click', () => { window.location = '/admin/download?file=raw'; });
$('dlAudit').addEventListener('click', () => { window.location = '/admin/download?file=audited'; });
$('export').addEventListener('click', async () => {
  try {
    const d = await (await adminPost('/admin/export')).json();
    toast('Exported: ' + d.final + ' + ' + d.raw + (d.audited ? ' + ' + d.audited : ''));
  } catch (e) { toast('Export failed — check server'); }
});
$('reset').addEventListener('click', async () => {
  if (!confirm('Clear device/IP locks and reset cookies? Records are kept; everyone can submit again.')) return;
  try {
    await adminPost('/admin/reset-devices');
    toast('Reset done'); refresh();
  } catch (e) { toast('Reset failed — check server'); }
});
$('newsess').addEventListener('click', async () => {
  const name = prompt('New subject name (current data will be exported first):');
  if (name === null) return;
  try {
    const d = await (await adminPost('/admin/new-session', { course: name })).json();
    toast('Saved ' + d.exported + ' · now: ' + d.course); refresh();
  } catch (e) { toast('New session failed — check server'); }
});

$('endsess').addEventListener('click', async () => {
  if (!confirm('End the attendance session now?\n\n'
      + '• Students can no longer submit\n• All CSVs are saved and copied to Downloads\n'
      + '• The server and tunnels stop (the student link stops working)')) return;
  $('endsess').disabled = true;
  try {
    const r = await adminPost('/admin/end-session');
    const d = await r.json();
    if (!d.ok) { toast(d.error || 'End session failed'); $('endsess').disabled = false; return; }
    clearInterval(timer);
    const p = $('endedPanel');
    p.innerHTML = '<h3>Session ended</h3>'
      + '<div>Saved: ' + d.files.map(f => '<code>' + esc(f) + '</code>').join(', ') + '</div>'
      + '<div>In: <code>' + esc(d.exports_dir) + '</code></div>'
      + (d.copied_to
          ? '<div>Copied to: <code>' + esc(d.copied_to) + '</code></div>'
          : '<div>Not copied to Downloads (on Termux, run <code>termux-setup-storage</code> once to enable this).</div>')
      + (d.stopping ? '<div>The server and tunnels are shutting down. You can close this page.</div>' : '');
    p.style.display = 'block';
    document.querySelectorAll('.bar button').forEach(b => { b.disabled = true; });
    window.scrollTo(0, 0);
  } catch (e) { toast('End session failed — check server'); $('endsess').disabled = false; }
});

// Pin the hall to where this device is (open the dashboard on a phone in the
// room). Needs location permission: works on localhost or an https link.
$('pinHall').addEventListener('click', () => {
  if (!navigator.geolocation) { toast('This browser has no location'); return; }
  const b = $('pinHall'); b.disabled = true; b.textContent = '📍 Locating…';
  let best = null, watch = null, finished = false;
  const done = async () => {
    if (finished) return;
    finished = true;
    if (watch !== null) navigator.geolocation.clearWatch(watch);
    watch = null; b.disabled = false; b.textContent = "📍 Pin hall to this device's location";
    if (!best) { toast('Could not get a location'); return; }
    if (best.acc > 100 && !confirm('This location is only accurate to ±' + Math.round(best.acc)
        + ' m. Pin it anyway?')) return;
    try {
      const d = await (await adminPost('/admin/set-hall', { lat: best.lat, lng: best.lng })).json();
      toast(d.ok ? 'Hall pinned (±' + Math.round(best.acc) + ' m)' : (d.error || 'Failed')); refresh();
    } catch (e) { toast('Pin failed — check server'); }
  };
  const stopAt = setTimeout(done, 15000);
  watch = navigator.geolocation.watchPosition(p => {
    if (!best || p.coords.accuracy < best.acc) {
      best = { lat: p.coords.latitude, lng: p.coords.longitude, acc: p.coords.accuracy };
    }
    b.textContent = '📍 Locating… ±' + Math.round(best.acc) + ' m';
    if (best.acc <= 20) { clearTimeout(stopAt); done(); }
  }, err => {
    if (err.code === 1 || !best) { clearTimeout(stopAt); done(); }
  }, { enableHighAccuracy: true, maximumAge: 0, timeout: 15000 });
});
$('unpinHall').addEventListener('click', async () => {
  try { await adminPost('/admin/set-hall', {}); toast('Hall unpinned'); refresh(); }
  catch (e) { toast('Unpin failed — check server'); }
});

refresh();
const timer = setInterval(refresh, 2000);
