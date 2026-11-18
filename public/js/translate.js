// x-time: translates the page's non-English tweets, quoted tweets and profile
// bio in place through /api/translate, which caches every answer. X's language
// code on each tweet (data-lang) decides what to send; a small indicator in the
// top-right corner shows progress and offers Retry when a request fails.
(() => {
  // Small batches in parallel: astorias answers 5 posts in ~6s but 20 in ~22s,
  // so a 20-tweet page plus its bio goes out as one round of 5 requests.
  const BATCH = 5;
  const BATCH_CHARS = 2000;
  const CONCURRENCY = 5;
  // X's codes for posts with nothing to translate: only mentions/emoji/links,
  // media, hashtags, cashtags, GIFs/stickers.
  const NO_TEXT = new Set(["qme", "zxx", "qht", "qam", "qct", "qst", "art"]);
  // A letter outside the Latin script; Common/Inherited are symbols and marks
  // shared by every script, and NFKC turns styled letters (𝐁𝐨𝐥𝐝) into plain ones.
  const NON_LATIN = /[\p{L}--[\p{Script=Latin}\p{Script=Common}\p{Script=Inherited}]]/v;
  const auto = document.body.dataset.translate !== "manual";

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  };

  const hasNonLatin = (text) => NON_LATIN.test(text.normalize("NFKC"));
  const isForeign = (lang) => !!lang && lang !== "en" && lang !== "und" && !NO_TEXT.has(lang);

  // The node's text with each link (URL, @mention, #hashtag) swapped for ⟦n⟧;
  // the original links go back into the translation in their new places.
  const extract = (node) => {
    const links = [];
    let text = "";
    let geo = null;
    for (const child of node.childNodes) {
      if (child.nodeType === Node.TEXT_NODE) text += child.data;
      else if (child.nodeType !== Node.ELEMENT_NODE) continue;
      else if (child.nodeName === "A") text += `⟦${links.push(child)}⟧`;
      else if (child.nodeName === "BR") text += "\n";
      else if (child.classList.contains("tweet-geo")) geo = child;
      else text += child.textContent;
    }
    return { text: text.trim(), links, geo };
  };

  const fill = (target, translation, src) => {
    const used = new Set();
    translation.split(/⟦(\d+)⟧/).forEach((part, i) => {
      if (i % 2 === 0) {
        if (part) target.append(part);
        return;
      }
      const link = src.links[part - 1];
      if (link && !used.has(link)) {
        used.add(link);
        target.append(link.cloneNode(true));
      }
    });
    // links the model dropped go at the end so none are lost
    for (const link of src.links) {
      if (!used.has(link)) target.append(" ", link.cloneNode(true));
    }
    if (src.geo) target.append(src.geo.cloneNode(true));
  };

  // ------------------------------------------------------------ what to send

  const items = new Map(); // key → { key, text, targets: [{ node, src, label }] }

  const add = (key, node, wanted) => {
    const src = extract(node);
    if (!src.text || !wanted(src.text)) return;
    let item = items.get(key);
    if (!item) items.set(key, (item = { key, text: src.text, targets: [], pending: false }));
    item.targets.push({ node, src, label: null });
  };

  const tweetLangs = [];
  for (const node of document.querySelectorAll(".tweet-content[data-tid], .quote-text[data-tid]")) {
    if (!node.getClientRects().length) continue; // hidden by the current view
    const lang = node.dataset.lang;
    tweetLangs.push(lang);
    // X labels English well; "und" or no code at all gets the script check
    add(node.dataset.tid, node, (text) =>
      lang && lang !== "und" ? isForeign(lang) : hasNonLatin(text));
  }

  // Bios carry no language code: send one written in another script, or one
  // on a profile whose tweets are mostly not English.
  const bio = document.querySelector(".profile-bio[data-uid] > p");
  if (bio) {
    const known = tweetLangs.filter((l) => l === "en" || isForeign(l));
    const foreign = known.filter(isForeign).length;
    const mostlyForeign = known.length > 0 && foreign / known.length > 0.5;
    add(`bio:${bio.parentElement.dataset.uid}`, bio, (text) => mostlyForeign || hasNonLatin(text));
  }

  // ------------------------------------------------------------ progress box

  let queue = null;

  const progress = (() => {
    const box = el("div", "translate-progress");
    const text = el("div", "translate-progress-text");
    const track = el("div", "translate-progress-bar");
    const bar = el("i");
    const retry = el("a", null, "Retry");
    retry.href = "#";
    track.append(bar);
    box.append(text, track);

    let total = 0;
    let done = 0;
    let failed = [];
    let lastError = "";
    let showTimer = 0;
    let hideTimer = 0;

    const setVisible = (on) => {
      if (on && !box.isConnected) document.body.append(box);
      box.classList.toggle("visible", on);
    };

    const render = () => {
      const settled = done + failed.length;
      const stuck = settled === total && failed.length > 0;
      if (stuck) text.replaceChildren(`${failed.length} failed · `, retry);
      else text.textContent = `Translating ${done} / ${total}`;
      box.title = stuck ? lastError : "";
      box.classList.toggle("failed", stuck);
      bar.style.width = `${total ? Math.round((settled / total) * 100) : 0}%`;
    };

    retry.addEventListener("click", (ev) => {
      ev.preventDefault();
      const again = failed;
      failed = [];
      total -= again.length; // queue() counts them again
      queue(again);
    });

    return {
      add(n) {
        clearTimeout(hideTimer);
        total += n;
        render();
        // cached pages finish within a few ms; don't flash the box for those
        if (!box.classList.contains("visible")) {
          clearTimeout(showTimer);
          showTimer = setTimeout(() => setVisible(true), 300);
        }
      },
      settle(ok, missed, error) {
        done += ok;
        failed.push(...missed);
        if (error) lastError = error;
        render();
        if (done + failed.length < total) return;
        clearTimeout(showTimer);
        if (failed.length) {
          setVisible(true);
          return;
        }
        const wait = box.classList.contains("visible") ? 1000 : 0;
        hideTimer = setTimeout(() => {
          setVisible(false);
          total = done = 0;
        }, wait);
      },
    };
  })();

  // ------------------------------------------------------------ requests

  const show = (target, r) => {
    const { node, src } = target;
    target.label?.remove();
    const translated = node.cloneNode(false);
    translated.removeAttribute("data-tid");
    fill(translated, r.text, src);
    node.after(translated);
    node.hidden = true;

    const label = el("div", "translate-label", `Translated from ${r.lang || "another language"} · `);
    const toggle = el("a", null, "Show original");
    toggle.href = "#";
    toggle.addEventListener("click", (ev) => {
      ev.preventDefault();
      translated.hidden = !translated.hidden;
      node.hidden = !translated.hidden;
      toggle.textContent = translated.hidden ? "Show translation" : "Show original";
    });
    label.append(toggle);
    translated.after(label);
    target.label = label;
  };

  const send = async (batch) => {
    let results = {};
    let error = "";
    try {
      const res = await fetch("/api/translate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ items: batch.map((it) => ({ id: it.key, text: it.text })) }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
      results = data.results || {};
    } catch (err) {
      error = err.message;
      console.warn("[translate]", error);
    }
    const missed = [];
    for (const item of batch) {
      item.pending = false;
      const r = results[item.key];
      if (!r) missed.push(item);
      else if (r.same) item.targets.forEach((t) => t.label?.replaceChildren("No translation needed"));
      else item.targets.forEach((t) => show(t, r));
    }
    if (missed.length && !error) error = "The model left some posts out";
    progress.settle(batch.length - missed.length, missed, error);
  };

  const waiting = [];
  let active = 0;

  const pump = () => {
    while (active < CONCURRENCY && waiting.length) {
      active++;
      send(waiting.shift()).finally(() => {
        active--;
        pump();
      });
    }
  };

  queue = (list) => {
    if (!list.length) return;
    progress.add(list.length);
    let batch = [];
    let chars = 0;
    for (const item of list) {
      item.pending = true;
      if (batch.length && (batch.length >= BATCH || chars + item.text.length > BATCH_CHARS)) {
        waiting.push(batch);
        batch = [];
        chars = 0;
      }
      batch.push(item);
      chars += item.text.length;
    }
    waiting.push(batch);
    pump();
  };

  // With auto-translate off (Preferences), each candidate gets a Translate link.
  const offer = (item) => {
    for (const target of item.targets) {
      const label = el("div", "translate-label");
      const link = el("a", null, "Translate");
      link.href = "#";
      link.addEventListener("click", (ev) => {
        ev.preventDefault();
        if (!item.pending) queue([item]);
      });
      label.append(link);
      target.node.after(label);
      target.label = label;
    }
  };

  const list = [...items.values()];
  if (auto) queue(list);
  else list.forEach(offer);
})();
