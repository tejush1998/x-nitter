(() => {
  const API = "http://localhost:4310";

  const resetToDefault = (btn) => {
    btn.classList.remove("follow-pending", "follow-failed");
    btn.textContent = "+";
    btn.title = "Follow";
  };

  const setPending = (btn, msg) => {
    btn.classList.add("follow-pending");
    btn.textContent = "\u2026";
    btn.title = msg;
  };

  const setLabel = (btn, following) => {
    resetToDefault(btn);
    btn.classList.toggle("following", following);
    btn.title = following ? "Following \u2014 click to unfollow" : "Follow";
  };

  const checkFollowing = async (btn) => {
    const username = btn.dataset.username;
    if (!username) return;
    setPending(btn, "Checking\u2026");
    try {
      const res = await fetch(`${API}/api/following?username=${encodeURIComponent(username)}`);
      const data = res.ok ? await res.json() : null;
      if (data?.ok) setLabel(btn, Boolean(data.following));
      else resetToDefault(btn);
    } catch {
      resetToDefault(btn);
    }
  };

  document.addEventListener("click", async (ev) => {
    const btn = ev.target.closest(".profile-follow");
    if (!btn || btn.disabled) return;
    ev.preventDefault();
    const username = btn.dataset.username;
    const unfollow = btn.classList.contains("following");
    btn.disabled = true;
    setPending(btn, "Working\u2026");
    try {
      const res = await fetch(`${API}/api/follow`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username, unfollow }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
      setLabel(btn, Boolean(data.following));
    } catch (err) {
      resetToDefault(btn);
      btn.classList.add("follow-failed");
      btn.textContent = "\u00d7";
      btn.title = "Failed \u2014 click to retry";
      console.error("Follow action failed:", err);
    } finally {
      btn.disabled = false;
    }
  });

  const init = () => document.querySelectorAll(".profile-follow").forEach(checkFollowing);

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
