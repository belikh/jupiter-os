const picker = document.getElementById("log-picker");
const statusEl = document.getElementById("status");
const summaryEl = document.getElementById("summary");
const activeBody = document.querySelector("#active-table tbody");
const recentEl = document.getElementById("recent");
const warningsEl = document.getElementById("warnings");
const treeEl = document.getElementById("tree");
const legendEl = document.getElementById("tree-legend");
const activeOnlyEl = document.getElementById("active-only");

let currentSource = null;
let currentName = null;
// The forest is fetched separately from the stream and only re-fetched when
// it grows; snapshots carry nothing but a byte of state per node.
let tree = null;
let treeSize = -1;
let treeNodeEls = [];
let treeFetching = false;
let lastStates = [];
let lastActiveKey = null;
let treeParents = [];
let activeOnly = true;

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

const STATE_CLASS = ["planned", "running", "done", "transferring"];
const ACTIVE_STATES = new Set([1, 3]); // building, and uploading/downloading
const MAX_TREE_ROWS = 3000;

// parentOf[i] is the dependent node i was first reached from, breadth-first
// from the roots, or -1 for a root. Breadth-first means that single parent
// lies on a shortest path back to a root, which is what makes the active
// view small: computed once per forest, not per snapshot.
function computeParents(t) {
  const parent = new Array(t.nodes.length).fill(-2);
  const queue = [];
  for (const r of t.roots) {
    parent[r] = -1;
    queue.push(r);
  }
  for (let head = 0; head < queue.length; head++) {
    const i = queue[head];
    for (const c of t.nodes[i].children || []) {
      if (parent[c] === -2) {
        parent[c] = i;
        queue.push(c);
      }
    }
  }
  return parent;
}

// The active view is the union of one path per active derivation: from the
// thing being built or copied, up to the root that ultimately wants it.
// Keeping EVERY path instead would show almost the whole forest — deep
// shared dependencies like openssl sit under nearly every root, so "has an
// active descendant" is true of nearly everything.
function visibleSet(t, states) {
  if (!activeOnly) return null;
  const visible = new Array(t.nodes.length).fill(false);
  for (let i = 0; i < t.nodes.length; i++) {
    if (!ACTIVE_STATES.has(states[i] || 0)) continue;
    for (let n = i; n >= 0 && !visible[n]; n = treeParents[n]) visible[n] = true;
  }
  return visible;
}

// The run's derivations form a DAG, not a tree: one derivation is commonly
// needed by several others. Each is expanded under the first dependent that
// reaches it and shown as a back-reference (↗) everywhere else, which keeps
// the rendering finite without hiding the relationship.
function renderTree(t, states) {
  treeEl.innerHTML = "";
  treeNodeEls = [];
  if (!t || !t.nodes.length) {
    treeEl.textContent = "no derivations listed for this run yet";
    legendEl.textContent = "";
    return;
  }

  const visible = visibleSet(t, states || []);
  const expanded = new Set();
  let rows = 0;

  const emit = (i, depth, from) => {
    if (rows >= MAX_TREE_ROWS) return;
    // In the active view a node is drawn under the one parent its path came
    // through, so each active derivation shows up once, in context.
    if (visible && (!visible[i] || treeParents[i] !== from)) return;
    rows++;
    const node = t.nodes[i];
    const dup = expanded.has(i);
    const row = document.createElement("div");
    row.className = "tree-row";
    row.style.paddingLeft = depth * 1.2 + "em";
    row.title = node.drv;
    row.innerHTML = `<span class="dot"></span><span class="tree-name">${node.name}</span>${dup ? '<span class="dup">↗</span>' : ""}`;
    treeEl.appendChild(row);
    (treeNodeEls[i] = treeNodeEls[i] || []).push(row.firstChild);
    if (dup) return;
    expanded.add(i);
    for (const c of node.children || []) emit(c, depth + 1, i);
  };

  for (const r of t.roots) emit(r, 0, -1);

  const scope = activeOnly ? `${rows} shown of ${t.nodes.length}` : `${t.nodes.length} derivations, ${t.roots.length} roots`;
  legendEl.textContent = t.hasDeps ? scope : `${scope} — no deps-<run>.txt for this run, so no edges`;
  if (activeOnly && rows === 0) {
    treeEl.textContent = "nothing building or copying right now";
  }
  if (rows >= MAX_TREE_ROWS) {
    const more = document.createElement("div");
    more.className = "tree-row muted";
    more.textContent = `… truncated at ${MAX_TREE_ROWS} rows`;
    treeEl.appendChild(more);
  }
}

function decodeStates(b64) {
  if (!b64) return [];
  const bin = atob(b64);
  const out = new Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// In "active only" mode the visible set moves as builds start and finish, so
// the forest is re-rendered whenever it changes; otherwise only the dots'
// classes are swapped, which is far cheaper than rebuilding 1000+ rows at
// the broadcast rate.
function applyStates(states) {
  if (!tree) return;
  if (activeOnly) {
    const key = states.map((s, i) => (ACTIVE_STATES.has(s) ? i : "")).join(",");
    if (key !== lastActiveKey) {
      lastActiveKey = key;
      renderTree(tree, states);
    }
  }
  for (let i = 0; i < states.length && i < treeNodeEls.length; i++) {
    const cls = "dot " + (STATE_CLASS[states[i]] || "planned");
    for (const el of treeNodeEls[i] || []) {
      if (el.className !== cls) el.className = cls;
    }
  }
}

async function refreshTree(name, size) {
  if (treeFetching) return;
  treeFetching = true;
  try {
    const res = await fetch(`/api/logs/${encodeURIComponent(name)}/tree`);
    tree = await res.json();
    treeParents = computeParents(tree);
    treeSize = size;
    lastActiveKey = null;
    if (name === currentName) renderTree(tree, lastStates);
  } catch (e) {
    // A failed fetch just leaves the previous forest up; the next snapshot
    // with a changed treeSize retries.
  } finally {
    treeFetching = false;
  }
}

function applySnapshot(snap) {
  renderSummary(snap);
  renderActive(snap.active);
  if (snap.treeSize !== treeSize) refreshTree(currentName, snap.treeSize);
  lastStates = decodeStates(snap.drvStates);
  applyStates(lastStates);
  recentEl.textContent = (snap.recent || []).join("\n");
  recentEl.scrollTop = recentEl.scrollHeight;
  warningsEl.textContent = (snap.warnings || []).join("\n");
  statusEl.textContent = snap.finished ? "finished" : "live";
  statusEl.className = "status " + (snap.finished ? "finished" : "connected");
}

function watch(name) {
  if (currentSource) currentSource.close();
  currentName = name;
  tree = null;
  treeSize = -1;
  treeNodeEls = [];
  treeParents = [];
  lastStates = [];
  lastActiveKey = null;
  treeEl.innerHTML = "";
  statusEl.textContent = "connecting…";
  statusEl.className = "status";
  currentSource = new EventSource(`/api/logs/${encodeURIComponent(name)}/stream`);
  currentSource.onmessage = (ev) => {
    const snap = JSON.parse(ev.data);
    applySnapshot(snap);
    // The server closes the stream after the final snapshot of a finished
    // run. Closing from this side too keeps EventSource from reconnecting
    // and overwriting "finished" with "disconnected".
    if (snap.finished) currentSource.close();
  };
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

activeOnlyEl.addEventListener("change", () => {
  activeOnly = activeOnlyEl.checked;
  lastActiveKey = null;
  renderTree(tree, lastStates);
  applyStates(lastStates);
});

loadList();
setInterval(loadList, 10000);
