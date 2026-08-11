const picker = document.getElementById("log-picker");
const statusEl = document.getElementById("status");
const summaryEl = document.getElementById("summary");
const activeBody = document.querySelector("#active-table tbody");
const recentEl = document.getElementById("recent");
const warningsEl = document.getElementById("warnings");

let currentSource = null;

function fmtBytes(n) {
  if (!n) return "0 B";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let i = 0;
  let v = n;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return v.toFixed(v < 10 && i > 0 ? 1 : 0) + " " + units[i];
}

function fmtElapsed(ms) {
  const s = Math.floor(ms / 1000);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  if (h) return `${h}h${String(m).padStart(2, "0")}m`;
  if (m) return `${m}m${String(sec).padStart(2, "0")}s`;
  return `${sec}s`;
}

function renderSummary(snap) {
  summaryEl.innerHTML = "";
  const title = document.createElement("div");
  title.className = "item";
  title.innerHTML = `<span class="label">${snap.title || "run"}</span><span class="value">${fmtElapsed(snap.elapsedMs)}</span>`;
  summaryEl.appendChild(title);

  for (const s of snap.summary) {
    if (!s.done && !s.expected && !s.running && !s.failed) continue;
    const el = document.createElement("div");
    el.className = "item";
    const fmt = s.bytes ? fmtBytes : (n) => n;
    let value = fmt(s.done);
    if (s.expected && s.expected !== s.done) value += " / " + fmt(s.expected);
    el.innerHTML = `<span class="label">${s.label}</span><span class="value">${value}</span>`;
    if (s.failed) el.innerHTML += `<span class="failed">${s.failed} failed</span>`;
    summaryEl.appendChild(el);
  }

  if (snap.corrupted || snap.untrusted) {
    const el = document.createElement("div");
    el.className = "item";
    el.innerHTML = `<span class="failed">${snap.corrupted} corrupted, ${snap.untrusted} untrusted</span>`;
    summaryEl.appendChild(el);
  }
}

function renderActive(items) {
  activeBody.innerHTML = "";
  for (const a of items || []) {
    const tr = document.createElement("tr");
    const progress = a.expected ? `${a.done}/${a.expected}` : (a.done || "");
    tr.innerHTML = `
      <td class="kind-${a.kind}">${a.kind}</td>
      <td title="${a.name}">${a.name}${a.machine ? " @ " + a.machine : ""}</td>
      <td>${a.phase || ""}</td>
      <td>${progress}</td>
      <td>${fmtElapsed(a.elapsedMs)}</td>
      <td title="${a.lastLine || ""}">${a.lastLine || ""}</td>`;
    activeBody.appendChild(tr);
  }
}

function applySnapshot(snap) {
  renderSummary(snap);
  renderActive(snap.active);
  recentEl.textContent = (snap.recent || []).join("\n");
  recentEl.scrollTop = recentEl.scrollHeight;
  warningsEl.textContent = (snap.warnings || []).join("\n");
  statusEl.textContent = snap.finished ? "finished" : "live";
  statusEl.className = "status " + (snap.finished ? "finished" : "connected");
}

function watch(name) {
  if (currentSource) currentSource.close();
  statusEl.textContent = "connecting…";
  statusEl.className = "status";
  currentSource = new EventSource(`/api/logs/${encodeURIComponent(name)}/stream`);
  currentSource.onmessage = (ev) => applySnapshot(JSON.parse(ev.data));
  currentSource.onerror = () => {
    statusEl.textContent = "disconnected";
    statusEl.className = "status";
  };
}

async function loadList() {
  const res = await fetch("/api/logs");
  const logs = await res.json();
  const prev = picker.value;
  picker.innerHTML = "";
  for (const l of logs) {
    const opt = document.createElement("option");
    opt.value = l.name;
    opt.textContent = `${l.live ? "● LIVE  " : ""}${l.name}  (${fmtBytes(l.size)})`;
    picker.appendChild(opt);
  }
  if (logs.length === 0) return;
  const toSelect = prev && logs.some((l) => l.name === prev) ? prev : (logs.find((l) => l.live) || logs[0]).name;
  if (toSelect !== prev || !currentSource) {
    picker.value = toSelect;
    watch(toSelect);
  }
}

picker.addEventListener("change", () => watch(picker.value));

loadList();
setInterval(loadList, 10000);
