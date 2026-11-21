// Loaded into every page of the app window (never on the website): what only the app can do.
//  - an "App tools" link in the site's top bar
//  - Ctrl + mouse wheel zoom (same steps as Ctrl + / Ctrl -, remembered)
//  - in the .zon editor: "Pack into game" - writes the editor's file into a player's save
(function () {
  "use strict";
  const post = (p, b) => fetch("/api" + p, { method: "POST", body: JSON.stringify(b || {}) }).then(r => r.json());

  // ---- App tools link
  const nav = document.querySelector(".pnav");
  if (nav && !nav.querySelector('a[href="app.html"]')) {
    const a = document.createElement("a");
    a.href = "app.html"; a.textContent = "App tools"; a.dataset.p = "app";
    nav.appendChild(a);
  }

  // ---- no "For Windows only" banner in the app (it only runs on Windows); the website keeps it
  const wb = document.querySelector(".warnbar");
  if (wb) wb.remove();

  // ---- Ctrl + mouse wheel zoom
  let acc = 0, last = 0;
  window.addEventListener("wheel", e => {
    if (!e.ctrlKey) return;
    e.preventDefault();
    acc += e.deltaY;
    const now = Date.now();
    if (Math.abs(acc) < 50 || now - last < 90) return;
    last = now;
    const d = acc < 0 ? 1 : -1;
    acc = 0;
    post("/zoom", { d }).catch(() => {});
  }, { passive: false });

  // ---- .zon editor: locked until remielle.exe is picked (its names are what files are checked
  // against). The Builder stays open; the website itself has no lock.
  const dl = document.getElementById("zonDl");
  if (!dl || document.getElementById("zonGamePack")) return;
  post("/game/state").then(st => {
    if (st.exe) return;
    const css = document.createElement("style");
    css.textContent = "html body.zzz-locked.view-zon .zon-wide,html body.zzz-locked.view-zon .card.zonchk,html body.zzz-locked.view-zon .card.zonfile,html body.zzz-locked.view-zon .card.zonfile.zfile-row{display:none!important}" +
      "#zzzLock{display:none}body.zzz-locked.view-zon #zzzLock{display:block}";
    document.head.appendChild(css);
    const card = document.createElement("div");
    card.className = "card"; card.id = "zzzLock";
    card.innerHTML = '<h2>The .zon tabs are locked</h2><p class="sub" style="margin:6px 0 12px">Pick your Remielle server\'s <b>remielle.exe</b> first. The app checks every .zon against the names and data in your own remielle.exe, so the file always matches your server.</p><button type="button" class="primary" id="zzzLockPick">Pick remielle.exe&hellip;</button> <span class="qsearch-status" id="zzzLockMsg"></span>';
    const tabs = document.querySelector("main > .tabs");
    if (tabs) tabs.insertAdjacentElement("afterend", card);
    document.body.classList.add("zzz-locked");
    document.getElementById("zzzLockPick").onclick = async () => {
      const r = await post("/game/pick-exe");
      if (r.exe) { document.body.classList.remove("zzz-locked"); location.reload(); }
      else document.getElementById("zzzLockMsg").textContent = r.message || "No remielle.exe picked.";
    };
  }).catch(() => {});
  // just read from the game (App tools > Read into .zon editor): open the .zon editor tab
  try {
    if (sessionStorage.getItem("zzz_app_open_zon")) {
      sessionStorage.removeItem("zzz_app_open_zon");
      const t = document.getElementById("tabZon"); if (t) t.click();
    }
  } catch (e) {}
  const st = () => document.getElementById("zonStatus");
  const say = (t, ok) => { const s = st(); if (s) { s.textContent = t; s.className = "qsearch-status" + (ok ? " ok" : " bad"); } };

  const wrap = document.createElement("span");
  wrap.style.cssText = "display:inline-flex;gap:6px;align-items:center";
  const sel = document.createElement("select");
  sel.id = "zonGamePlayer"; sel.title = "Which player's save to replace";
  sel.style.cssText = "width:auto;padding:6px 8px";
  const btn = document.createElement("button");
  btn.id = "zonGamePack"; btn.type = "button"; btn.textContent = "Pack into game";
  btn.title = "Checks the file the way Remielle's server does, backs up the save, then packs this file into it (Remielle's own pack-player).";
  wrap.append(sel, btn);
  dl.insertAdjacentElement("afterend", wrap);

  let S = null, arm = 0, busy = false;
  function render(s) {
    S = s;
    if (!s.exe) {
      sel.innerHTML = '<option value="">remielle.exe not picked</option>'; sel.disabled = true;
      btn.disabled = true; btn.title = "Pick remielle.exe in App tools > Game save first.";
      return;
    }
    sel.innerHTML = s.players.length ? s.players.map(id => `<option value="${id}"${id === s.player ? " selected" : ""}>Player ${id}</option>`).join("") : '<option value="">no saves found</option>';
    sel.disabled = !s.players.length;
    btn.disabled = !s.players.length;
  }
  post("/game/state").then(render).catch(() => { btn.disabled = true; });
  sel.onchange = () => post("/game/player", { id: +sel.value }).then(render);

  const reset = () => { arm = 0; btn.textContent = "Pack into game"; btn.classList.remove("primary"); };
  btn.onclick = async () => {
    if (busy || !S) return;
    let file = null, crlf = false, fname = "player.zon";
    try { file = ZON_FILE; crlf = ZON_CRLF; fname = ZON_FNAME; } catch (e) {}
    if (!file) { say("No .zon file is loaded in the editor.", false); return; }
    // typed into the block but not applied: that text isn't in the file yet
    const ed = document.getElementById("zonEditT");
    if (ed && ed.checked) { say("You're editing the .zon block: click \"Apply edits to file\" first (and turn Edit block off), or what you typed won't be packed.", false); return; }
    if (!arm) {
      // the current build isn't equipped yet: it won't be in the pack
      let warn = "";
      try { const r = zonBuild(); if (r && r.patched && r.patched !== file) warn = `${r.name}'s current build isn't equipped yet, so it won't be packed - click Equip first. `; } catch (e) {}
      if (warn) say(warn + "Click Pack into game again to pack without it.", false);
      arm = 1; btn.textContent = `Click again: replace player ${S.player}'s save`; btn.classList.add("primary");
      setTimeout(() => { if (arm) reset(); }, warn ? 8000 : 4000);
      return;
    }
    reset(); busy = true; btn.disabled = true; btn.textContent = "Packing…";
    try {
      const r = await post("/game/pack-text", { text: crlf ? file.replace(/\n/g, "\r\n") : file, name: fname });
      render(r);
      say(r.message || (r.ok ? "Packed." : "Not packed."), r.ok);
      try { if (r.ok && typeof zonLog === "function") zonLog("Packed into game", "", [`${fname} → player ${r.player}'s save`, r.message || ""]); } catch (e) {}
    } catch (e) {
      say("Couldn't reach the app: " + e, false);
    }
    busy = false; btn.disabled = false; btn.textContent = "Pack into game";
  };
})();
