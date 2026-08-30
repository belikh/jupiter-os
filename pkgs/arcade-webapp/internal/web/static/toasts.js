// jupiterOS Arcade — toast handler (extracted from the per-page inline
// <script> blocks by remediation W4a so the app's Content-Security-Policy
// can be strict: script-src 'self', no 'unsafe-inline'. This file is the
// ONE copy; the five page layouts that each carried it inline (and
// collections.html, which carried it twice — every toast double-fired)
// now load it by src.)
//
// Toasts are pure progressive enhancement: with scripts blocked the app
// still polls, swaps and navigates — only the transient notifications
// disappear.
(function () {
  function showToast(msg, kind) {
    var c = document.getElementById('toast');
    if (!c) return;
    var d = document.createElement('div');
    d.className = 'toast ' + (kind || 'info');
    d.setAttribute('role', 'status');
    d.textContent = msg;
    c.appendChild(d);
    setTimeout(function () {
      d.style.opacity = '0';
      d.style.transition = 'opacity 400ms';
      setTimeout(function () { d.remove(); }, 420);
    }, 4000);
  }

  document.body.addEventListener('htmx:responseError', function (e) {
    var xhr = e.detail.xhr;
    var msg = (xhr && xhr.responseText || '').trim();
    if (!msg) msg = 'request failed (' + (xhr ? xhr.status : '?') + ')';
    // truncate
    if (msg.length > 220) msg = msg.slice(0, 219) + '\u2026';
    showToast(msg, xhr && xhr.status === 409 ? 'warn' : 'error');
  });

  document.body.addEventListener('htmx:afterRequest', function (e) {
    if (e.detail.failed) return;
    var xhr = e.detail.xhr;
    // success toasts via HX-Trigger header
    var hdr = xhr && xhr.getResponseHeader('HX-Trigger');
    if (hdr) {
      try {
        var o = JSON.parse(hdr);
        if (o.toast) showToast(o.toast, o.toastKind || 'ok');
      } catch (_) { /* not JSON — ignore */ }
    }
  });
})();
