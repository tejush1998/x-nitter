// x-time: fills the tweet page's #recommend sidebar by polling /api/recommend.
(() => {
  const STEPS = [
    "Reading the tweet and its replies",
    "Writing three searches",
    "Searching X",
    "Picking the best",
  ];

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  };

  const init = () => {
    // links that jump to the replies (#r) need the fold open to land
    if (location.hash === "#r") document.querySelector(".replies-fold")?.setAttribute("open", "");
    const panel = document.getElementById("recommend");
    if (!panel) return;
    const id = panel.dataset.tweetid;
    let pollToken = 0;
    let lastStage = 0;
    let searchesOpen = false; // closed by default; remembers the user's toggle across re-renders

    const head = el("div", "recommend-head");
    head.appendChild(el("span", "recommend-title", "Recommended"));
    const refresh = el("button", "recommend-refresh", "Refresh");
    refresh.type = "button";
    refresh.title = "Search again and re-pick";
    head.appendChild(refresh);
    const body = el("div", "recommend-body");
    panel.append(head, body);

    const renderSteps = (data) => {
      const list = el("div", "recommend-steps");
      STEPS.forEach((label, i) => {
        const state = i < data.stage ? "done"
          : i > data.stage ? "pending"
          : data.status === "error" ? "error" : "running";
        const row = el("div", `recommend-step ${state}`);
        row.append(el("span", "recommend-dot"), el("span", null, label));
        let note = "";
        if (i === 0 && data.stage > 0) note = `${data.replies} replies`;
        if (i === 2 && data.stage > 2) note = `${data.poolSize} candidates`;
        if (state === "running") note = `${Math.round((data.elapsedMs ?? 0) / 1000)}s`;
        if (note) row.appendChild(el("span", "recommend-step-note", note));
        list.appendChild(row);
      });
      return list;
    };

    const renderSearches = (data) => {
      const box = el("details", "recommend-searches");
      box.open = searchesOpen;
      box.addEventListener("toggle", () => { searchesOpen = box.open; });
      box.appendChild(el("summary", null, "How these were found"));
      for (const s of data.searches) {
        const row = el("div", "recommend-search");
        const top = el("div", "recommend-search-head");
        top.append(el("span", "recommend-tag", s.name), el("span", "recommend-search-label", s.label));
        const query = el("a", "recommend-search-query", s.keywords);
        query.href = s.url;
        query.title = s.query;
        const meta = s.error ? `failed: ${s.error}`
          : s.done ? `${s.count} found · ${s.product}`
          : `searching ${s.product}…`;
        row.append(top, query, el("div", `recommend-search-meta${s.error ? " error" : ""}`, meta));
        box.appendChild(row);
      }
      if (data.status === "done") {
        const ranked = data.ranker === "likes" ? "most-liked" : "LLM";
        box.appendChild(el("div", "recommend-meta",
          `${data.replies} replies read · ${data.poolSize} candidates · ${ranked} picks · ${Math.round(data.elapsedMs / 1000)}s`));
      }
      return box;
    };

    const renderPicks = (data) => {
      const frag = document.createDocumentFragment();
      if (data.ranker === "likes") {
        frag.appendChild(el("div", "recommend-note", `Ranked by likes — the LLM ranking failed: ${data.rankError}`));
      }
      if (!data.picks.length) {
        const allFailed = data.searches.length && data.searches.every((s) => s.error);
        frag.appendChild(el("div", "recommend-empty", allFailed
          ? "All searches failed — see below."
          : data.poolSize
            ? `None of the ${data.poolSize} search results was worth recommending.`
            : "The searches found no other tweets."));
        return frag;
      }
      for (const p of data.picks) {
        const pick = el("div", "recommend-pick");
        pick.innerHTML = p.html; // rendered server-side by nitter's renderTweet
        frag.appendChild(pick);
      }
      return frag;
    };

    const render = (data) => {
      lastStage = data.stage ?? lastStage;
      body.innerHTML = "";
      refresh.disabled = data.status === "running";
      if (data.status === "done") {
        body.appendChild(renderPicks(data));
      } else {
        body.appendChild(renderSteps(data));
        if (data.status === "error") body.appendChild(el("div", "recommend-error", data.error));
      }
      if (data.searches?.length) body.appendChild(renderSearches(data));
    };

    const poll = async (refreshRun) => {
      const token = ++pollToken;
      try {
        const q = new URLSearchParams({ id, path: location.pathname });
        if (refreshRun) q.set("refresh", "1");
        const res = await fetch(`/api/recommend?${q}`);
        const data = await res.json().catch(() => ({}));
        if (token !== pollToken) return;
        if (data.disabled) {
          // switched off from the dashboard's Labs menu after this page loaded
          refresh.hidden = true;
          body.innerHTML = "";
          body.appendChild(el("div", "recommend-empty", "Recommendations are turned off. Turn them on from the dashboard's Labs menu."));
          return;
        }
        if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
        render(data);
        if (data.status === "running") {
          setTimeout(() => { if (token === pollToken) poll(false); }, 1000);
        }
      } catch (err) {
        if (token !== pollToken) return;
        render({ status: "error", stage: lastStage, error: err.message, searches: [], picks: [] });
      }
    };

    refresh.addEventListener("click", () => poll(true));
    render({ status: "running", stage: 0, elapsedMs: 0, searches: [], picks: [] });
    poll(false);
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
