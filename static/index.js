'use strict';
const ID_RE = /^\d{1,20}$/;
// Arabic-Indic (٠-٩) and Persian (۰-۹) digits -> ASCII, as the server does.
function normDigits(v) {
  return v.replace(/[\u0660-\u0669]/g, d => String(d.charCodeAt(0) - 0x0660))
          .replace(/[\u06F0-\u06F9]/g, d => String(d.charCodeAt(0) - 0x06F0));
}
const ARABIC_WORD = /^[\u0600-\u06FF]+$/;
const MIN_PARTS = 4;

let deviceId = localStorage.getItem('att_device_id');
if (!deviceId) {
  deviceId = (crypto.randomUUID ? crypto.randomUUID()
              : Date.now() + '-' + Math.random().toString(36).slice(2));
  localStorage.setItem('att_device_id', deviceId);
}

const idEl = document.getElementById('id'), nameEl = document.getElementById('name');
const btn = document.getElementById('go'), editBtn = document.getElementById('editBtn');
const msg = document.getElementById('msg'), banner = document.getElementById('banner');
const geo = document.getElementById('geo'), help = document.getElementById('help');
let editing = false, needGeo = false;
let coords = null;                       // {lat,lng,acc} once granted
let pageToken = '';                      // proves submit came from a real page load

function nameOk(v) {
  const parts = v.trim().split(/\s+/).filter(Boolean);
  return parts.length >= MIN_PARTS && parts.every(p => ARABIC_WORD.test(p));
}
function locOk() { return !needGeo || coords !== null; }
function liveCheck() {
  const idGood = ID_RE.test(normDigits(idEl.value.trim()));
  const nameGood = nameOk(nameEl.value);
  document.getElementById('idHint').textContent = idEl.value && !idGood ? 'أرقام فقط' : '';
  document.getElementById('idHint').className = 'hint' + (idEl.value && !idGood ? ' bad' : '');
  document.getElementById('nameHint').textContent =
    nameEl.value && !nameGood ? 'الاسم الرباعي بالعربية (٤ مقاطع على الأقل)' : '';
  document.getElementById('nameHint').className = 'hint' + (nameEl.value && !nameGood ? ' bad' : '');
  btn.disabled = !(idGood && nameGood && locOk()) || editing;
}
idEl.addEventListener('input', liveCheck);
nameEl.addEventListener('input', liveCheck);

function lockInputs(locked) { idEl.disabled = nameEl.disabled = locked; }

function requestLocation() {
  geo.style.display = 'block'; geo.className = 'geo loading';
  geo.textContent = '📍 جارٍ تحديد الموقع… يرجى الموافقة على الإذن.';
  help.style.display = 'none';
  if (!navigator.geolocation) {
    geo.className = 'geo bad'; geo.textContent = 'متصفحك لا يدعم تحديد الموقع.';
    help.style.display = 'block'; return;
  }
  navigator.geolocation.getCurrentPosition(
    p => {
      coords = { lat: p.coords.latitude, lng: p.coords.longitude, acc: p.coords.accuracy };
      geo.className = 'geo ok';
      geo.textContent = '✅ تم تأكيد الموقع — يمكنك التسجيل الآن.';
      liveCheck();
    },
    err => {
      coords = null;
      geo.className = 'geo bad';
      if (err.code === 1) {
        geo.textContent = '❌ تم رفض إذن الموقع — يرجى تفعيله من الإعدادات.';
      } else if (err.code === 3) {
        geo.textContent = '⏱ انتهت مهلة تحديد الموقع — اضغط "المحاولة مرة أخرى".';
      } else {
        geo.textContent = '❌ تعذّر تحديد الموقع — اضغط "المحاولة مرة أخرى".';
      }
      help.style.display = 'block'; liveCheck();
    },
    { enableHighAccuracy: true, timeout: 15000, maximumAge: 0 }
  );
}
document.getElementById('retry').addEventListener('click', requestLocation);

async function postWithRetry(url, body, onWait, tries = 10) {
  let delay = 500;
  for (let i = 0; i < tries; i++) {
    try {
      const res = await fetch(url, { method: 'POST',
        headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
      if (res.status === 403 && !body._tokenRetried) {
        // Page token expired (phone slept, page left open): fetch a fresh one
        // and resend once instead of telling the student to reload.
        try {
          const peek = await res.clone().json();
          if (peek && peek.code === 'token') {
            const tr = await (await fetch('/api/init', { method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ deviceId: body.deviceId }) })).json();
            if (tr.page_token) {
              pageToken = tr.page_token; body.page_token = tr.page_token;
              body._tokenRetried = true; i--; continue;
            }
          }
        } catch (_) {}
        return res;
      }
      if (res.status === 429 || res.status >= 500) {
        // A throttle 429 carries {retry:false} — treat as terminal so we don't
        // pile on more hits. Capacity/overload 429s have no such flag -> retry.
        try {
          const peek = await res.clone().json();
          if (peek && peek.retry === false) return res;
        } catch (e) {}
        if (onWait) onWait(i + 1);
        await new Promise(r => setTimeout(r, delay + Math.random() * 400));
        delay = Math.min(delay * 1.8, 6000);
        // Refresh page token so a long retry loop doesn't expire it (~90s window).
        try {
          const tr = await (await fetch('/api/init', { method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ deviceId: body.deviceId }) })).json();
          if (tr.page_token) { pageToken = tr.page_token; body.page_token = tr.page_token; }
        } catch (_) {}
        continue;
      }
      return res;
    } catch (e) {
      if (onWait) onWait(i + 1);
      await new Promise(r => setTimeout(r, delay + Math.random() * 400));
      delay = Math.min(delay * 1.8, 6000);
    }
  }
  throw new Error('busy');
}

function showSuccess(text) {
  msg.className = 'ok'; msg.style.background = ''; msg.style.color = '';
  msg.textContent = text; editing = true; btn.disabled = true; btn.textContent = 'تم ✓';
  lockInputs(true); editBtn.style.display = 'block';
}
function enterEdit() {
  editing = false; lockInputs(false); editBtn.style.display = 'none';
  btn.textContent = 'حفظ التعديل — Save changes'; msg.className = ''; msg.textContent = '';
  // A returning student never got the location prompt (it is skipped when the
  // page opens on an existing record), so Save would stay disabled forever.
  if (needGeo && !coords) requestLocation();
  liveCheck(); nameEl.focus();
}
editBtn.addEventListener('click', enterEdit);

(async () => {
  try {
    const r = await (await fetch('/api/init', { method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ deviceId }) })).json();
    document.getElementById('course').textContent = r.course;
    needGeo = !!r.geofence;
    pageToken = r.page_token || '';
    if (r.record) {
      idEl.value = r.record.id; nameEl.value = r.record.name;
      banner.style.display = 'block';
      showSuccess('بياناتك مسجّلة / Your entry is on record'); btn.textContent = 'مسجَّل';
    }
  } catch (e) {
    document.getElementById('course').textContent = 'تعذّر الاتصال بالخادم / Failed to connect';
    banner.textContent = 'جارٍ إعادة المحاولة… / Retrying…';
    banner.style.display = 'block';
    setTimeout(() => location.reload(), 4000);
  }
  if (needGeo && !editing) requestLocation();   // ask for location on load
  liveCheck();
})();

// Page tokens expire (~90s); refresh quietly so a page left open still submits.
setInterval(async () => {
  try {
    const r = await (await fetch('/api/init', { method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ deviceId }) })).json();
    if (r.page_token) pageToken = r.page_token;
  } catch (e) {}
}, 25000);

let sending = false;
btn.addEventListener('click', async () => {
  if (sending || btn.disabled) return;
  sending = true; btn.disabled = true;
  const prevLabel = btn.textContent; btn.textContent = 'جارٍ الإرسال…';
  msg.className = ''; msg.textContent = '';
  const body = { id: normDigits(idEl.value.trim()), name: nameEl.value.trim().replace(/\s+/g, ' '),
                 deviceId, page_token: pageToken };
  if (needGeo && coords) { body.lat = coords.lat; body.lng = coords.lng; body.accuracy = coords.acc; }
  try {
    const res = await postWithRetry('/submit', body, (attempt) => {
      msg.className = 'err'; msg.style.background = 'rgba(255,176,32,.15)'; msg.style.color = '#ffb020';
      msg.textContent = 'ازدحام مؤقت — مكانك محفوظ، جارٍ المحاولة… (High traffic — holding your spot… ' + attempt + ')';
    });
    const data = await res.json();
    if (data.ok) { showSuccess(data.message); }
    else {
      msg.className = 'err'; msg.style.background = ''; msg.style.color = '';
      msg.textContent = data.error || 'خطأ'; btn.textContent = prevLabel; btn.disabled = false;
    }
  } catch (e) {
    msg.className = 'err'; msg.style.background = ''; msg.style.color = '';
    msg.textContent = 'ازدحام شديد — أعد المحاولة بعد قليل'; btn.textContent = prevLabel; btn.disabled = false;
  } finally { sending = false; }
});
