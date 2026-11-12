const $ = (sel) => document.querySelector(sel);

const state = {
  noise: false,
  likedOnly: false,
  running: false,
  busy: false,
  linkBase: "http://localhost:8080",
  batch: null, // null = latest batch
  currentBatch: null,
  _lastActive: null,
  view: "topics",
  nounTweets: {}, // noun -> tweets cache for the current snapshot
};

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

async function api(path, opts) {
  console.log(`[app:api] → ${opts?.method || "GET"} ${path}`, opts?.body ? `body=${opts.body}` : "");
  const res = await fetch(path, opts);
  const body = await res.json().catch(() => ({}));
  console.log(`[app:api] ← ${res.status} ${path}`, JSON.stringify(body).slice(0, 800));
  if (!res.ok) {
    console.error(`[app:api] error ${path}:`, body);
    throw new Error(body.error || `HTTP ${res.status}`);
  }
  return body;
}

function toast(message, type = "info", ms = 4000) {
  const el = $("#toast");
  el.textContent = message;
  el.className = `toast ${type}`;
  el.hidden = false;
  clearTimeout(el._t);
  el._t = setTimeout(() => (el.hidden = true), ms);
}

function fmtTime(iso) {
  if (!iso) return "";
  return new Date(iso).toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
}

async function likeToggle(btn, t) {
  const liked = !btn.classList.contains("liked");
  btn.classList.toggle("liked", liked);
  try {
    await api("/api/like", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ tweetId: t.id, unlike: !liked }),
    });
    toast(liked ? "Liked" : "Unliked", "success", 1500);
    if (state.likedOnly && !liked) {
      render().catch((err) => toast(err.message, "error"));
    }
  } catch (err) {
    btn.classList.toggle("liked", !liked);
    toast(`Like failed: ${err.message}`, "error", 5000);
  }
}

function tweetEl(t) {
  const div = document.createElement("div");
  div.className = t.noise ? "tweet noise" : "tweet";

  const avatar = document.createElement("div");
  avatar.className = "tweet-avatar";
  avatar.title = t.author_username ? `@${t.author_username}` : "unknown";
  div.appendChild(avatar);

  const body = document.createElement("div");
  body.className = "tweet-body";

  const meta = document.createElement("div");
  meta.className = "tweet-meta";
  const author = document.createElement("b");
  author.textContent = t.author_username ? `@${t.author_username}` : "unknown";
  meta.appendChild(author);
  meta.appendChild(document.createTextNode(` · ${fmtTime(t.created_at)}`));
  if (t.confidence != null) {
    meta.appendChild(document.createTextNode(` · conf ${Math.round(t.confidence * 100)}%`));
  }
  if (t.lang && t.lang !== "en") {
    const lang = document.createElement("span");
    lang.className = "badge lang";
    lang.textContent = `${t.lang.toUpperCase()} → EN`;
    meta.appendChild(lang);
  }
  if (t.noise) {
    const badge = document.createElement("span");
    badge.className = "badge";
    badge.textContent = "NOISE";
    meta.appendChild(badge);
  }
  body.appendChild(meta);

  const text = document.createElement("p");
  text.className = "tweet-text";
  const translation = t.translation || null;
  let showingTranslation = Boolean(translation);
  const renderText = () => {
    text.textContent = showingTranslation ? translation : (t.text ?? "");
  };
  renderText();
  text.title = "Click to expand";
  text.addEventListener("click", () => {
    const expanded = text.classList.toggle("expanded");
    text.title = expanded ? "Click to collapse" : "Click to expand";
  });
  body.appendChild(text);

  if (translation) {
    const toggle = document.createElement("button");
    toggle.className = "orig-toggle";
    toggle.textContent = "original";
    toggle.type = "button";
    toggle.addEventListener("click", (e) => {
      e.stopPropagation();
      showingTranslation = !showingTranslation;
      renderText();
      toggle.textContent = showingTranslation ? "original" : "translated";
    });
    body.appendChild(toggle);
  }

  if ((t.links ?? []).length || (t.author_username && t.id)) {
    const links = document.createElement("div");
    links.className = "tweet-links";
    for (const link of t.links ?? []) {
      const a = document.createElement("a");
      a.className = "tweet-link";
      a.href = link;
      a.target = "_blank";
      a.rel = "noopener noreferrer";
      a.textContent = stripUrl(link);
      links.appendChild(a);
    }
    if (t.author_username && t.id) {
      const a = document.createElement("a");
      a.className = "tweet-link view-link";
      a.href = `${state.linkBase}/${t.author_username}/status/${t.id}`;
      a.target = "_blank";
      a.rel = "noopener noreferrer";
      a.textContent = "view ↗";
      links.appendChild(a);
    }
    body.appendChild(links);
  }
  div.appendChild(body);

  const actions = document.createElement("div");
  actions.className = "tweet-actions";
  const likeBtn = document.createElement("button");
  likeBtn.className = `like-btn${t.liked ? " liked" : ""}`;
  likeBtn.textContent = "+";
  likeBtn.title = t.liked ? "Unlike" : "Like";
  likeBtn.addEventListener("click", () => likeToggle(likeBtn, t));
  actions.appendChild(likeBtn);
  div.appendChild(actions);

  return div;
}

function stripUrl(url) {
  try {
    const u = new URL(url);
    return (u.hostname.replace(/^www\./, "") + (u.pathname === "/" ? "" : u.pathname)).slice(0, 40);
  } catch {
    return url.slice(0, 40);
  }
}

function topicEl(t) {
  const box = document.createElement("section");
  box.className = "topic";

  const head = document.createElement("div");
  head.className = "topic-head";

  const chevron = document.createElement("span");
  chevron.className = "chevron";
  const name = document.createElement("span");
  name.className = "topic-name";
  name.textContent = t.topic;
  const count = document.createElement("span");
  count.className = "topic-count";
  count.textContent = `${t.count} tweets`;

  head.append(chevron, name, count);

  const body = document.createElement("div");
  body.className = "topic-body";
  for (const tw of t.tweets) body.appendChild(tweetEl(tw));

  head.addEventListener("click", () => {
    box.classList.toggle("open");
    localStorage.setItem(`open:${t.topic}`, box.classList.contains("open") ? "1" : "0");
  });
  if (localStorage.getItem(`open:${t.topic}`) === "1") box.classList.add("open");

  box.append(head, body);
  return box;
}

function nounEl(n, maxCount) {
  const box = document.createElement("section");
  box.className = "noun";
  const ratio = maxCount > 0 ? n.count / maxCount : 0;
  box.dataset.w = ratio >= 0.5 ? "3" : ratio >= 0.2 ? "2" : "1";

  const head = document.createElement("div");
  head.className = "noun-head";

  const chevron = document.createElement("span");
  chevron.className = "chevron";
  const name = document.createElement("span");
  name.className = "noun-name";
  name.textContent = n.noun;
  const count = document.createElement("span");
  count.className = "noun-count";
  count.textContent = `${n.count} ${n.count === 1 ? "tweet" : "tweets"}`;

  head.append(chevron, name, count);

  const body = document.createElement("div");
  body.className = "noun-body";

  const loadTweets = async () => {
    body.innerHTML = "";
    body.appendChild(el("div", "empty", "Loading…"));
    try {
      const q = [`noun=${encodeURIComponent(n.noun)}`, `noise=${state.noise ? 1 : 0}`];
      if (state.batch) q.push(`batch=${encodeURIComponent(state.batch)}`);
      if (state.likedOnly) q.push("liked=1");
      const res = await api(`/api/nouns?${q.join("&")}`);
      body.innerHTML = "";
      if (!res.tweets.length) {
        body.appendChild(el("div", "empty", "No tweets for this noun."));
      }
      for (const tw of res.tweets) body.appendChild(tweetEl(tw));
      state.nounTweets[n.noun] = res.tweets;
    } catch (err) {
      body.innerHTML = "";
      body.appendChild(el("div", "empty", `Failed to load: ${err.message}`));
      toast(`Failed to load tweets for "${n.noun}": ${err.message}`, "error", 5000);
    }
  };

  head.addEventListener("click", async () => {
    if (box.classList.contains("open")) {
      box.classList.remove("open");
      localStorage.setItem(`nounOpen:${n.noun}`, "0");
      return;
    }
    if (!body.childNodes.length) await loadTweets();
    box.classList.add("open");
    localStorage.setItem(`nounOpen:${n.noun}`, "1");
  });
  if (localStorage.getItem(`nounOpen:${n.noun}`) === "1") {
    loadTweets();
    box.classList.add("open");
  }

  box.append(head, body);
  return box;
}

function fmtBatch(id, latest) {
  if (!id) return "—";
  const batchDate = latest || Number(id);
  const d = new Date(batchDate);
  if (isNaN(d.getTime())) return `batch ${id}`;
  return `${d.toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })}`;
}

function renderBatchSelect(snap) {
  const sel = $("#batch");
  sel.innerHTML = "";
  const latestId = snap.batches.length ? String(snap.batches[0].id) : null;
  const selectedId = state.batch ? String(state.batch) : null;

  const latest = document.createElement("option");
  latest.value = "";
  latest.textContent = `Latest batch (${fmtBatch(latestId, snap.batches[0]?.latest)})`;
  latest.selected = !selectedId || selectedId === latestId;
  sel.appendChild(latest);

  for (const b of snap.batches) {
    if (String(b.id) === latestId) continue;
    const o = document.createElement("option");
    o.value = String(b.id);
    o.textContent = `Batch ${fmtBatch(b.id, b.latest)} (${b.count})`;
    o.selected = selectedId === String(b.id);
    sel.appendChild(o);
  }
}

async function render() {
  const batchQ = state.batch ? `&batch=${encodeURIComponent(state.batch)}` : "";
  const likedQ = state.likedOnly ? "&liked=1" : "";
  const snap = await api(`/api/snapshot?noise=${state.noise ? 1 : 0}${batchQ}${likedQ}`);
  const { stats, rows } = snap;
  if (snap.linkBase) state.linkBase = snap.linkBase;
  state.currentBatch = snap.currentBatch;
  renderBatchSelect(snap);

  $("#stats").innerHTML = "";
  const parts = [
    ["tweets", stats.totalTweets],
    ["classified", stats.assigned],
    ["noise", stats.noise],
  ];
  for (const [label, val] of parts) {
    const span = document.createElement("span");
    span.innerHTML = `${label}: <b>${val}</b>`;
    $("#stats").appendChild(span);
  }
  const likedSpan = document.createElement("span");
  likedSpan.className = `stat-liked${state.likedOnly ? " active" : ""}`;
  likedSpan.innerHTML = `liked: <b>${stats.liked}</b>`;
  likedSpan.title = state.likedOnly ? "Click to show all tweets" : "Click to show only liked tweets";
  likedSpan.addEventListener("click", () => {
    state.likedOnly = !state.likedOnly;
    render().catch((err) => toast(err.message, "error"));
  });
  $("#stats").appendChild(likedSpan);
  const last = stats.lastPollAt ? new Date(Number(stats.lastPollAt)).toLocaleString() : "never";
  const lastSpan = document.createElement("span");
  lastSpan.innerHTML = `last poll: <b>${last}</b>`;
  $("#stats").appendChild(lastSpan);

  $("#topicList").innerHTML = "";
  $("#nounList").innerHTML = "";
  const showTopics = state.view === "topics";
  $("#topicList").hidden = !showTopics;
  $("#nounList").hidden = showTopics;
  const emptyMsg = showTopics
    ? (state.likedOnly
      ? "No liked tweets in this batch."
      : "No topics yet. Run a scrape or reclassify to populate.")
    : "No nouns yet. Nouns are extracted when tweets are classified — run a scrape or reclassify.";
  if (!showTopics) {
    state.nounTweets = {};
    const nouns = snap.nouns ?? [];
    if (!nouns.length) {
      const empty = document.createElement("div");
      empty.className = "empty";
      empty.textContent = emptyMsg;
      $("#nounList").appendChild(empty);
      return;
    }
    const maxCount = nouns.length ? nouns[0].count : 0;
    for (const n of nouns) $("#nounList").appendChild(nounEl(n, maxCount));
    return;
  }
  if (!rows.length) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = emptyMsg;
    $("#topicList").appendChild(empty);
    return;
  }
  for (const t of rows) $("#topicList").appendChild(topicEl(t));
}

function renderStatusBar(bar, active, cls) {
  bar.hidden = false;
  bar.className = "statusbar running";
  bar.innerHTML = "";
  bar.appendChild(el("span", "sb-dot"));
  const main = el("span", "sb-main");
  const kindLabel = active.kind === "auto" ? "automatic scrape" : active.kind;
  const phase = cls?.running ? (cls.phase ?? "working") : "starting";
  let txt = `${kindLabel} — ${phase}`;
  if (cls?.current) {
    const cur = cls.current;
    txt += ` · ${cur.label} ${cur.model}`;
    if (cur.chunks > 1) txt += ` (chunk ${cur.chunk}/${cur.chunks})`;
    if (cur.timeoutMs) txt += ` · timeout ${Math.round(cur.timeoutMs / 1000)}s`;
    if (cls.total) txt += ` · ${Math.min(cls.done, cls.total)}/${cls.total}`;
  } else if (cls?.total && (cls?.phase === "translating" || cls?.phase === "classifying")) {
    txt += ` · ${Math.min(cls.done, cls.total)}/${cls.total}`;
  }
  if (active.elapsedMs) txt += ` · ${Math.round(active.elapsedMs / 1000)}s`;
  main.textContent = txt;
  bar.appendChild(main);
  if (cls?.attempts?.length > 1) {
    bar.appendChild(el("span", "sb-chain", cls.attempts.map((a) => `${a.label} ${a.model}`).join(" → ")));
  }
  if (cls?.error) {
    bar.appendChild(el("span", "sb-error", `errored: ${cls.error}`));
  }
}

function renderStatusIdle(bar, st) {
  bar.hidden = false;
  bar.className = "statusbar idle";
  bar.innerHTML = "";
  const hist = (st.history ?? []).slice(0, 5);
  if (!hist.length) {
    bar.hidden = true;
    return;
  }
  bar.appendChild(el("span", "sb-label", "recent:"));
  for (const j of hist) {
    const mark = j.status === "done" ? "✓" : j.status === "error" ? "✗" : "…";
    const chip = el("span", `sb-chip ${j.status}`, `${j.kind} ${mark}`);
    chip.title = `${j.kind} · ${new Date(j.startedAt).toLocaleString()} · ${j.status}${j.message ? ` · ${j.message}` : ""}${j.total ? ` · ${j.total} tweets, ${j.assignments ?? 0} classified` : ""}`;
    bar.appendChild(chip);
  }
}

async function refreshStatus() {
  let st;
  try {
    st = await api("/api/status");
  } catch (err) {
    console.warn("[app:status] poll failed:", err.message);
    return;
  }
  const bar = $("#statusBar");
  const active = st.active;
  state.busy = Boolean(active);
  $("#scrape").disabled = state.busy;
  $("#reclassify").disabled = state.busy;

  if (!active) {
    const hadActive = state._lastActive;
    state._lastActive = null;
    renderStatusIdle(bar, st);
    if (hadActive) {
      console.log(`[app:status] job ${hadActive.id} (${hadActive.kind}) finished — refreshing`);
      render().catch((err) => toast(err.message, "error"));
    }
    return;
  }
  state._lastActive = { id: active.id, kind: active.kind, source: active.source };
  renderStatusBar(bar, active, st.classify);
}

async function pollJob(jobId) {
  console.log(`[app:pollJob] start polling ${jobId}`);
  for (;;) {
    await new Promise((r) => setTimeout(r, 800));
    let st;
    try {
      st = await api("/api/status");
    } catch (err) {
      console.error(`[app:pollJob] status poll failed for ${jobId}:`, err);
      toast(`Poll failed: ${err.message}`, "error", 7000);
      return;
    }
    if (!st.active || st.active.id !== jobId) break;
  }
  let job;
  try {
    job = await api(`/api/jobs/${jobId}`);
  } catch (err) {
    console.error(`[app:pollJob] final fetch failed for ${jobId}:`, err);
    return;
  }
  console.log(`[app:pollJob] job ${jobId} finished:`, job.status, job.message ?? "");
  if (job.status === "done") {
    if (job.fallback || job.result?.fallbackUsed) {
      const msg = job.fallback ?? job.result?.fallbackMessage ?? "Completed via fallback";
      toast(`${msg} — ${job.result?.total ?? 0} tweets, ${job.result?.assignments?.length ?? 0} classified.`, "info", 7000);
    } else {
      toast(`Done: ${job.result?.total ?? 0} tweets, ${job.result?.assignments?.length ?? 0} classified.`, "success");
    }
  } else if (job.status === "error") {
    toast(`Failed: ${job.message ?? "unknown error"}`, "error", 7000);
  }
}

async function runJob(kind) {
  console.log(`[app:runJob] clicked ${kind} busy=${state.busy} batch=${state.batch} currentBatch=${state.currentBatch}`);
  if (state.busy) {
    console.warn(`[app:runJob] busy, ignoring ${kind} click`);
    return;
  }
  try {
    const body = kind === "reclassify" ? { batch: state.batch ?? state.currentBatch } : {};
    console.log(`[app:runJob] POST /api/${kind} body=`, body);
    const { jobId } = await api(`/api/${kind}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    console.log(`[app:runJob] received jobId=${jobId} for ${kind}`);
    toast(`${kind} running…`);
    await pollJob(jobId);
    if (kind === "scrape") state.batch = null; // jump to the fresh latest batch
    console.log(`[app:runJob] ${kind} finished, re-rendering`);
    await render();
    await refreshStatus();
  } catch (err) {
    console.error(`[app:runJob] ${kind} failed:`, err);
    toast(err.message, "error", 7000);
    await refreshStatus();
  }
}

console.log("[app] listeners attaching...");
for (const tab of document.querySelectorAll("#viewToggle .view-tab")) {
  tab.addEventListener("click", () => {
    state.view = tab.dataset.view;
    for (const t of document.querySelectorAll("#viewToggle .view-tab")) {
      t.classList.toggle("active", t === tab);
      t.setAttribute("aria-selected", t === tab ? "true" : "false");
    }
    render().catch((err) => toast(err.message, "error"));
  });
}
$("#scrape").addEventListener("click", () => {
  console.log("[app] scrape button clicked");
  runJob("scrape");
});
$("#reclassify").addEventListener("click", () => {
  console.log("[app] reclassify button clicked, state=", JSON.stringify(state));
  runJob("reclassify");
});
console.log("[app] listeners attached, reclassify el=", $("#reclassify"));
$("#batch").addEventListener("change", (e) => {
  state.batch = e.target.value ? String(e.target.value) : null;
  render().catch((err) => toast(err.message, "error"));
});
$("#noise").addEventListener("change", (e) => {
  state.noise = e.target.checked;
  render().catch((err) => toast(err.message, "error"));
});

// People search: X's People results in a dropdown. People you open are
// remembered server-side (meta "people.recent") and listed when the box is
// empty.
const OLD_PEOPLE_KEY = "people:recent"; // where the list lived before it moved to the server
const people = {
  query: "",
  results: [],
  recent: [],
  cache: new Map(), // query -> Promise of results
  loading: false,
  error: null,
  active: 0,
  picked: false, // moved with the arrow keys since the last keystroke
  timer: null,
  seq: 0,
};

const recentPeople = () => people.recent;

async function postPeople(path, body) {
  const res = await api(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  people.recent = res.people;
}

function rememberPerson(p) {
  const same = (r) => r.username.toLowerCase() === p.username.toLowerCase();
  const { username, fullname, pic, verified } = p;
  people.recent = [{ username, fullname, pic, verified }, ...people.recent.filter((r) => !same(r))];
  postPeople("/api/people/recent", { username, fullname, pic, verified }).catch((err) =>
    console.warn("[app:people] remember failed:", err.message));
}

function forgetPerson(username) {
  people.recent = people.recent.filter((r) => r.username !== username);
  postPeople("/api/people/forget", { username }).catch((err) => toast(`Couldn't forget @${username}: ${err.message}`, "error"));
}

async function loadRecentPeople() {
  try {
    let old = [];
    try {
      old = JSON.parse(localStorage.getItem(OLD_PEOPLE_KEY)) || [];
    } catch {}
    // Oldest first, so the newest ends up on top.
    for (const p of old.reverse()) await postPeople("/api/people/recent", p);
    localStorage.removeItem(OLD_PEOPLE_KEY);
    if (!old.length) people.recent = (await api("/api/people/recent")).people;
  } catch (err) {
    console.warn("[app:people] load failed:", err.message);
  }
}

const fmtCount = (n) => new Intl.NumberFormat(undefined, { notation: "compact" }).format(n);

function personEl(p, recent) {
  const row = el("div", "person");
  row.setAttribute("role", "option");
  if (recent) row.dataset.recent = "1";

  const link = el("a", "person-link");
  link.href = `${state.linkBase}/${p.username}`;
  link.target = "_blank";
  link.addEventListener("click", () => {
    rememberPerson(p);
    closePeople();
  });

  const pic = el("img", "person-pic");
  pic.alt = "";
  pic.loading = "lazy";
  if (p.pic) pic.src = p.pic;
  link.appendChild(pic);

  const names = el("div", "person-names");
  const name = el("b", null, p.fullname || p.username);
  if (p.verified) name.appendChild(el("span", "person-tick", "✓"));
  names.appendChild(name);
  let handle = `@${p.username}`;
  if (p.protected) handle += " · 🔒";
  if (p.followers != null) handle += ` · ${fmtCount(p.followers)} followers`;
  names.appendChild(el("span", "person-handle", handle));
  if (p.bio) names.appendChild(el("div", "person-bio", p.bio));
  link.appendChild(names);
  row.appendChild(link);

  if (recent) {
    const forget = el("button", "person-forget", "×");
    forget.type = "button";
    forget.title = `Forget @${p.username}`;
    forget.setAttribute("aria-label", forget.title);
    forget.addEventListener("click", (e) => {
      e.stopPropagation(); // the row is gone after the re-render, so the outside-click check would close the menu
      forgetPerson(p.username);
      renderPeople();
      $("#peopleInput").focus();
    });
    row.appendChild(forget);
  }
  return row;
}

function renderPeople() {
  const menu = $("#peopleMenu");
  const q = people.query.toLowerCase();
  const matches = (p) => p.username.toLowerCase().includes(q) || (p.fullname || "").toLowerCase().includes(q);
  const recent = recentPeople().filter((p) => !q || matches(p));
  const shown = new Set(recent.map((p) => p.username.toLowerCase()));
  const found = q ? people.results.filter((p) => !shown.has(p.username.toLowerCase())) : [];

  menu.innerHTML = "";
  if (recent.length) {
    menu.appendChild(el("div", "people-title", "Recent"));
    for (const p of recent) menu.appendChild(personEl(p, true));
  }
  if (q) {
    if (found.length) {
      menu.appendChild(el("div", "people-title", "People"));
      for (const p of found) menu.appendChild(personEl(p, false));
    } else if (people.loading) {
      menu.appendChild(el("div", "people-note", "Searching…"));
    } else if (people.error) {
      menu.appendChild(el("div", "people-note error", `Search failed: ${people.error}`));
    } else if (!recent.length) {
      menu.appendChild(el("div", "people-note", "No people found"));
    }
    const all = el("a", "people-all", `All results for “${people.query}” →`);
    all.href = `${state.linkBase}/search?f=users&q=${encodeURIComponent(people.query)}`;
    all.target = "_blank";
    menu.appendChild(all);
  }

  const rows = menu.querySelectorAll(".person");
  people.active = Math.min(people.active, Math.max(rows.length - 1, 0));
  rows.forEach((r, i) => r.classList.toggle("active", i === people.active));
  menu.hidden = !menu.children.length;
  $("#peopleInput").setAttribute("aria-expanded", String(!menu.hidden));
}

function closePeople() {
  $("#peopleMenu").hidden = true;
  $("#peopleInput").setAttribute("aria-expanded", "false");
}

async function searchPeople(q) {
  clearTimeout(people.timer);
  const seq = ++people.seq;
  if (!people.cache.has(q)) {
    people.cache.set(q, api(`/api/people?q=${encodeURIComponent(q)}`).then((res) => res.people));
  }
  try {
    const results = await people.cache.get(q);
    if (seq !== people.seq) return;
    Object.assign(people, { results, loading: false, error: null });
  } catch (err) {
    people.cache.delete(q);
    if (seq !== people.seq) return;
    Object.assign(people, { results: [], loading: false, error: err.message });
  }
  renderPeople();
}

$("#peopleInput").addEventListener("input", (e) => {
  people.query = e.target.value.trim();
  people.active = 0;
  people.picked = false;
  clearTimeout(people.timer);
  if (people.query) {
    // keep the previous results on screen until the new ones arrive
    people.loading = true;
    people.error = null;
    if (people.cache.has(people.query)) searchPeople(people.query);
    else people.timer = setTimeout(() => searchPeople(people.query), 300);
  } else {
    people.seq++;
    Object.assign(people, { results: [], loading: false, error: null });
  }
  renderPeople();
});
$("#peopleInput").addEventListener("focus", () => {
  renderPeople();
  // Another tab may have added someone since the page loaded.
  api("/api/people/recent")
    .then((res) => {
      people.recent = res.people;
      if (document.activeElement === $("#peopleInput")) renderPeople();
    })
    .catch(() => {});
});
$("#peopleInput").addEventListener("keydown", (e) => {
  const rows = $("#peopleMenu").querySelectorAll(".person");
  if (e.key === "Escape") {
    closePeople();
    e.target.blur();
  } else if ((e.key === "ArrowDown" || e.key === "ArrowUp") && rows.length) {
    e.preventDefault();
    if ($("#peopleMenu").hidden) return renderPeople();
    const step = e.key === "ArrowDown" ? 1 : -1;
    people.active = (people.active + step + rows.length) % rows.length;
    people.picked = true;
    rows.forEach((r, i) => r.classList.toggle("active", i === people.active));
    rows[people.active].scrollIntoView({ block: "nearest" });
  }
});
$("#peopleSearch").addEventListener("submit", (e) => {
  e.preventDefault();
  const row = !$("#peopleMenu").hidden && $("#peopleMenu").querySelectorAll(".person")[people.active];
  // While a search is in flight the result rows belong to an older query, so
  // Enter searches now instead of opening one (unless it was chosen with the arrows).
  if (row && (!people.loading || row.dataset.recent || people.picked)) row.querySelector(".person-link").click();
  else if (people.loading) searchPeople(people.query);
  else if (people.query) $(".people-all")?.click();
});
document.addEventListener("click", (e) => {
  if (!$("#peopleSearch").contains(e.target)) closePeople();
});
$("#peopleSearch").addEventListener("focusout", (e) => {
  if (e.relatedTarget && !$("#peopleSearch").contains(e.relatedTarget)) closePeople();
});

// Labs: experimental toggles, stored server-side so tweet pages honour them
async function loadExperiments() {
  try {
    const exp = await api("/api/experiments");
    $("#labRecommend").checked = Boolean(exp.recommend);
    $("#labRecommend").disabled = false;
  } catch (err) {
    console.warn("[app:labs] load failed:", err.message);
  }
}
$("#labRecommend").addEventListener("change", async (e) => {
  const on = e.target.checked;
  e.target.disabled = true;
  try {
    const exp = await api("/api/experiments", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ recommend: on }),
    });
    e.target.checked = Boolean(exp.recommend);
    toast(`Tweet recommendations ${exp.recommend ? "on" : "off"}`, "success", 1500);
  } catch (err) {
    e.target.checked = !on;
    toast(`Couldn't change Labs setting: ${err.message}`, "error", 5000);
  } finally {
    e.target.disabled = false;
  }
});
document.addEventListener("click", (e) => {
  if (!$("#labs").contains(e.target)) $("#labs").open = false;
});
loadExperiments();
loadRecentPeople();

render().catch((err) => {
  $("#topicList").innerHTML = "";
  const empty = document.createElement("div");
  empty.className = "empty";
  empty.textContent = `Failed to load: ${err.message}`;
  $("#topicList").appendChild(empty);
});

let scrapePromptShown = false;
async function maybePromptScrape() {
  if (scrapePromptShown || state.busy) return;
  try {
    const snap = await api(`/api/snapshot?noise=${state.noise ? 1 : 0}`);
    if (snap.hasBatchToday === false) {
      scrapePromptShown = true;
      $("#scrapeModal").showModal();
    }
  } catch (err) {
    console.warn("[app:prompt] snapshot check failed:", err.message);
  }
}
$("#scrapeModal").addEventListener("close", (e) => {
  if (e.target.returnValue === "scrape") runJob("scrape");
});

maybePromptScrape();

refreshStatus().catch(() => {});
setInterval(refreshStatus, 2000);
