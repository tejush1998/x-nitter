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
