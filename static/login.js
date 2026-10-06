'use strict';
const pw = document.getElementById('pw'), err = document.getElementById('err');
async function login() {
  err.textContent = '';
  try {
    const r = await fetch('/admin/login', { method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'att-admin' },
      body: JSON.stringify({ pw: pw.value }) });
    if (r.ok) { location.href = '/admin'; }   // cookie set; reload into console
    else {
      err.textContent = r.status === 429 ? 'Too many attempts — wait a minute' : 'Wrong password';
      pw.value=''; pw.focus();
    }
  } catch (e) { err.textContent = 'Connection error'; }
}
document.getElementById('go').addEventListener('click', login);
pw.addEventListener('keydown', e => { if (e.key === 'Enter') login(); });
