// x-time: the profile's ✦ button toggles a section above the bio with an LLM
// summary of the user's last two weeks of posts, polling /api/summary while
// it is written.
(() => {
  const POLL_MS = 1500;
  const STAGES = ["Fetching posts", "Summarizing"];

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  };

  let token = 0;

  const render = (section, btn, data, load) => {
    section.replaceChildren();
    const running = data.status === "running";
    btn.classList.toggle("summary-busy", running);
    if (running) {
      const label = STAGES[data.stage] || STAGES[0];
      const extra = data.stage === 0 && data.fetched ? ` (${data.fetched} so far)` : "";
      section.appendChild(el("div", "summary-status",
        `${label}${extra}\u2026 ${Math.round((data.elapsedMs || 0) / 1000)}s`));
      return;
    }
    if (data.status === "error") {
      section.appendChild(el("div", "summary-error", data.error || "Summary failed"));
    }
    const s = data.summary;
    if (s) {
      if (s.overview) section.appendChild(el("p", "summary-overview", s.overview));
      const list = el("ul", "summary-topics");
      for (const t of s.topics || []) {
        const li = el("li");
        li.appendChild(el("b", null, `${t.name}: `));
        li.appendChild(document.createTextNode(t.line || t.stance || ""));
        list.appendChild(li);
      }
      section.appendChild(list);
    }
    const foot = el("div", "summary-foot");
    if (s) foot.appendChild(el("span", null, `${s.tweets} posts, ${s.from} to ${s.to}`));
    const refresh = el("a", "summary-refresh", "Refresh");
    refresh.href = "#";
    refresh.title = "Fetch the latest posts and summarize again";
    refresh.addEventListener("click", (ev) => {
      ev.preventDefault();
      load(true);
    });
    foot.appendChild(refresh);
    section.appendChild(foot);
  };

  const show = (btn, section) => {
    const username = btn.dataset.username;
    const load = async (refresh) => {
      const mine = ++token;
      const qs = `username=${encodeURIComponent(username)}${refresh ? "&refresh=1" : ""}`;
      try {
        const res = await fetch(`/api/summary?${qs}`);
        const data = await res.json().catch(() => ({}));
        if (mine !== token || section.hidden) return;
        if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
        render(section, btn, data, load);
        if (data.status === "running") {
          setTimeout(() => {
            if (mine === token && !section.hidden) load(false);
          }, POLL_MS);
        }
      } catch (err) {
        if (mine !== token || section.hidden) return;
        render(section, btn, { status: "error", error: err.message }, load);
      }
    };
    section.replaceChildren(el("div", "summary-status", "Loading\u2026"));
    load(false);
  };

  document.addEventListener("click", (ev) => {
    const btn = ev.target.closest(".profile-summarize");
    if (!btn) return;
    ev.preventDefault();
    const card = btn.closest(".profile-card");
    if (!card) return;
    let section = card.querySelector(".profile-summary");
    if (section && !section.hidden) {
      section.hidden = true;
      token++;
      btn.classList.remove("summary-busy", "summary-open");
      return;
    }
    if (!section) {
      section = el("div", "profile-summary");
      const extra = card.querySelector(".profile-card-extra");
      card.insertBefore(section, extra);
    }
    section.hidden = false;
    btn.classList.add("summary-open");
    show(btn, section);
  });
})();
