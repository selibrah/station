/* Zero-Mock Causal Workspace Controller for Station Landing Page (`#studio`).
 * Connects a sandboxed `<iframe srcdoc>` Target Browser Frame directly to the
 * verbatim Rust kernels in `station-kernels.js` (`daemon/src/dom.rs` & `daemon/src/mcp.rs`)
 * and an in-browser relational store mirroring `FindingsStore.swift` + `job_watch.py`.
 */
(function () {
  "use strict";

  const K = window.StationKernels;
  if (!K) {
    console.error("StationKernels missing — ensure station-kernels.js loads before studio-lab.js");
    return;
  }

  function esc(str) {
    return String(str == null ? "" : str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  const utf8Encoder = new TextEncoder();
  function utf8Len(s) { return utf8Encoder.encode(String(s || "")).length; }
  function estTokens(s) { return Math.max(1, Math.ceil(utf8Len(s) / 4)); }

  // Realistic SSR hydration noise (~22 KB) so Raw HTML vs Clean Markdown / @eN
  // compression is genuinely measured by `dom.rs` on bloated markup (zero fake numbers).
  function buildHydrationNoise(seedLabel, count) {
    const items = [];
    for (let i = 0; i < count; i++) {
      items.push({
        urn: "urn:li:fs_normalized_entity:" + seedLabel + ":" + (10000 + i),
        trackingId: "trk_" + seedLabel + "_" + i + "_a8f91c0492e81b77d2",
        experimentFlags: ["voyager_web_ssr_v4", "artdeco_hydration_chunk_" + (i % 9), "analytics_beacon_enabled"],
        decorativeClasses: "scaffold-layout__detail-overflow artdeco-entity-lockup__badge--muted ember-view"
      });
    }
    return JSON.stringify({ props: { pageProps: { hydrationStream: items } } });
  }

  const ATS_BLOAT_JSON = buildHydrationNoise("linear_ats", 85);
  const RENT_BLOAT_JSON = buildHydrationNoise("avito_casa", 75);

  const RAW_FIXTURES = {
    "ats-job": {
      url: "https://boards.linear.app/jobs/409182-senior-rust-systems",
      html:
        '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
        '<base href="https://boards.linear.app/jobs/409182-senior-rust-systems">' +
        '<title>Senior Rust Systems Engineer — Linear ($210k Remote)</title>' +
        '<meta name="description" content="Remote Senior Rust Systems Engineer role building low-latency local sync and CDP protocol runtimes.">' +
        '<style>' +
          'body{margin:0;padding:14px 16px;background:#0D121D;color:#EDF2F7;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;font-size:13px;line-height:1.5;}' +
          'nav,footer,.cookie-banner{padding:7px 10px;margin-bottom:10px;border-radius:6px;background:#141C2B;border:1px solid #223049;font-size:11px;color:#8496B0;}' +
          'main{padding:14px;border-radius:9px;background:#111826;border:1px solid #24334D;}' +
          'h1{margin:0 0 4px;font-size:17px;color:#F8FAFC;}' +
          '.meta{color:#2DD4BF;font-family:monospace;font-size:12px;margin-bottom:10px;}' +
          'ul{margin:6px 0 12px;padding-left:18px;color:#CBD5E1;}' +
          '.form-box{margin-top:12px;padding:11px;border-radius:8px;background:#0B101A;border:1px solid #263652;display:flex;flex-direction:column;gap:9px;}' +
          'label{font-size:11.5px;font-weight:600;color:#94A3B8;display:block;margin-bottom:3px;}' +
          'input[type="text"],select{width:100%;box-sizing:border-box;padding:6px 8px;border-radius:5px;border:1px solid #334768;background:#131B2B;color:#F8FAFC;font-size:12px;}' +
          '.row-btns{display:flex;gap:8px;flex-wrap:wrap;align-items:center;}' +
          'button{padding:6px 10px;border-radius:5px;border:1px solid #38BDF8;background:rgba(56,189,248,0.14);color:#F8FAFC;font-size:12px;font-weight:600;cursor:pointer;}' +
          'button[data-toggled="true"]{background:#2DD4BF;border-color:#2DD4BF;color:#07090E;}' +
          '.state-pill{font-family:monospace;font-size:11px;padding:3px 7px;border-radius:4px;background:#172234;color:#94A3B8;}' +
          '.state-pill.ok{background:rgba(45,212,191,0.16);color:#2DD4BF;}' +
        '</style></head><body>' +
        '<nav aria-label="Site chrome">Linear Careers · All Departments · Engineering · Security · Blog (stripped by /read)</nav>' +
        '<div id="cookie-banner" class="cookie-banner">Tracking preferences banner — automatically stripped by Station Clean Markdown.</div>' +
        '<div aria-hidden="true" style="display:none;"><button>Hidden Honeypot Trap</button></div>' +
        '<main>' +
          '<h1>Senior Rust Systems Engineer</h1>' +
          '<div class="meta">Linear · Remote (Global) · $210,000 USD · Full-time</div>' +
          '<p>Architect sub-millisecond local daemons, persistent WebSocket pools, and native macOS developer workflows in <strong>Rust</strong> and <strong>Tokio</strong>.</p>' +
          '<ul>' +
            '<li>4+ years shipping production <code>Rust</code>, async I/O, and zero-copy wire protocols</li>' +
            '<li>Experience with Chrome DevTools Protocol (CDP), browser engines, or SQLite</li>' +
            '<li>Read full <a href="/engineering/sync-engine">Architecture Spec</a></li>' +
          '</ul>' +
          '<form class="form-box" onsubmit="event.preventDefault();">' +
            '<div>' +
              '<label for="candidate-name">Candidate headline (React-style controlled input)</label>' +
              '<input id="candidate-name" type="text" value="Systems Engineer (Rust &amp; CDP)" placeholder="Headline &amp; core stack">' +
              '<div id="react-sync-status" class="state-pill" style="margin-top:4px;">Controlled state: Systems Engineer (Rust &amp; CDP)</div>' +
            '</div>' +
            '<div class="row-btns">' +
              '<button type="button" id="btn-remote-tz" data-toggled="false">Confirm Remote UTC±3 Overlap</button>' +
              '<select id="notice-period" aria-label="Availability">' +
                '<option value="immediate">Immediate start</option>' +
                '<option value="2weeks">2 weeks notice</option>' +
                '<option value="1month">1 month notice</option>' +
              '</select>' +
            '</div>' +
            '<div>' +
              '<label for="cv-upload">Resume / CV PDF (gesture-free DataTransfer target)</label>' +
              '<input id="cv-upload" type="file" accept=".pdf,.doc,.docx">' +
              '<div id="file-attach-status" class="state-pill" style="margin-top:4px;">Attached file: none</div>' +
            '</div>' +
          '</form>' +
        '</main>' +
        '<footer>© Linear · Privacy · Terms · Cookie Policy</footer>' +
        '<script id="__NEXT_DATA__" type="application/json">' + ATS_BLOAT_JSON + '</script>' +
        '<script>' +
          '(function(){' +
            'const inp = document.getElementById("candidate-name");' +
            'const badge = document.getElementById("react-sync-status");' +
            'const protoDesc = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value");' +
            'let internalVal = inp.value;' +
            'let setterCalled = false;' +
            'Object.defineProperty(inp, "value", {' +
              'get: function() { return protoDesc.get.call(this); },' +
              'set: function(v) { setterCalled = false; protoDesc.set.call(this, v); }' +
            '});' +
            'inp.addEventListener("input", function(){' +
              'internalVal = inp.value;' +
              'badge.textContent = "✓ React controlled state synced: " + internalVal;' +
              'badge.className = "state-pill ok";' +
            '});' +
            'const btn = document.getElementById("btn-remote-tz");' +
            'btn.addEventListener("click", function(){' +
              'const next = btn.getAttribute("data-toggled") !== "true";' +
              'btn.setAttribute("data-toggled", String(next));' +
              'btn.textContent = next ? "✓ Remote UTC±3 Confirmed" : "Confirm Remote UTC±3 Overlap";' +
            '});' +
            'const fileInp = document.getElementById("cv-upload");' +
            'const fileBadge = document.getElementById("file-attach-status");' +
            'fileInp.addEventListener("change", function(){' +
              'if (fileInp.files && fileInp.files.length > 0) {' +
                'const f = fileInp.files[0];' +
                'fileBadge.textContent = "✓ Attached via DataTransfer: " + f.name + " (" + f.size.toLocaleString() + " B · 0 OS dialogs)";' +
                'fileBadge.className = "state-pill ok";' +
              '}' +
            '});' +
          '})();' +
        '</script></body></html>'
    },

    "rent-casa": {
      url: "https://www.avito.ma/fr/maarif/studio_meuble_91827.htm",
      html:
        '<!doctype html><html lang="fr"><head><meta charset="utf-8">' +
        '<base href="https://www.avito.ma/fr/maarif/studio_meuble_91827.htm">' +
        '<title>Studio meublé Maârif Extension — 1 150 DH/mois (Particulier)</title>' +
        '<meta name="description" content="Studio propre sans vis-à-vis à Maârif Extension proche tramway Abdelmoumen, particulier direct bla samsar.">' +
        '<style>' +
          'body{margin:0;padding:14px 16px;background:#0D121D;color:#EDF2F7;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;font-size:13px;line-height:1.5;}' +
          'nav,footer,.cookie-banner{padding:7px 10px;margin-bottom:10px;border-radius:6px;background:#141C2B;border:1px solid #223049;font-size:11px;color:#8496B0;}' +
          'article{padding:14px;border-radius:9px;background:#111826;border:1px solid #24334D;}' +
          'h1{margin:0 0 4px;font-size:17px;color:#F8FAFC;}' +
          '.price{color:#2DD4BF;font-family:monospace;font-size:13px;font-weight:700;margin-bottom:8px;}' +
          'ul{margin:6px 0 12px;padding-left:18px;color:#CBD5E1;}' +
          '.box{margin-top:10px;padding:10px;border-radius:8px;background:#0B101A;border:1px solid #263652;display:flex;flex-direction:column;gap:8px;}' +
          'textarea,select{width:100%;box-sizing:border-box;padding:6px 8px;border-radius:5px;border:1px solid #334768;background:#131B2B;color:#F8FAFC;font-size:12px;}' +
          'a.wa{display:inline-block;padding:6px 10px;border-radius:5px;background:rgba(45,212,191,0.16);border:1px solid #2DD4BF;color:#2DD4BF;text-decoration:none;font-weight:600;font-size:12px;}' +
        '</style></head><body>' +
        '<nav>Avito Immobilier · Casablanca · Locations · Crédits · Assurance</nav>' +
        '<div id="cookie-banner" class="cookie-banner">Bannière cookies publicitaires — supprimée par Station /read.</div>' +
        '<article>' +
          '<h1>Studio meublé Maârif Extension sans vis-à-vis</h1>' +
          '<div class="price">1 150 DH / mois · Particulier direct (bla samsar) · 0.8 km Tramway</div>' +
          '<p>Salam, studio lumineux refait à neuf quartier <strong>Maârif Extension</strong> à 8 min à pied de la station Tramway Abdelmoumen. Calme, sécurisé, fibre optique 200 Mbps incluse.</p>' +
          '<ul>' +
            '<li>Caution : 1 mois seulement · Eau &amp; syndic inclus</li>' +
            '<li>Équipé : frigo, machine à laver, chauffe-eau électrique, bureau</li>' +
            '<li>Contact direct propriétaire sur <a class="wa" href="https://wa.me/212661482910">WhatsApp +212 6 61 48 29 10</a></li>' +
          '</ul>' +
          '<div class="box">' +
            '<select id="visit-slot" aria-label="Créneau de visite">' +
              '<option value="sam-11h">Visite Samedi 11:00</option>' +
              '<option value="sam-17h">Visite Samedi 17:00</option>' +
              '<option value="dim-11h">Visite Dimanche 11:00</option>' +
            '</select>' +
            '<textarea id="landlord-msg" rows="2" placeholder="Message au propriétaire (Darija / Français)">Salam, dispo pour visiter ce samedi à 11h ? Merci !</textarea>' +
          '</div>' +
        '</article>' +
        '<footer>Annonces similaires Casablanca · Gauthier · Racine · Bourgogne</footer>' +
        '<script type="application/ld+json">{"@context":"https://schema.org","@type":"Apartment","name":"Studio Maarif"}</script>' +
        '<script id="__NEXT_DATA__" type="application/json">' + RENT_BLOAT_JSON + '</script>' +
        '</body></html>'
    }
  };

  const DEFAULT_CUSTOM_HTML =
    '<!doctype html>\n<html>\n<head>\n  <base href="https://news.ycombinator.com/jobs">\n  <title>Staff Rust & AI Browser Engineer — Oxide ($225k Remote)</title>\n</head>\n<body style="background:#0D121D;color:#F2F5FA;font-family:sans-serif;padding:16px;">\n' +
    '  <nav>HN · new · threads · past · comments · jobs</nav>\n' +
    '  <main>\n' +
    '    <h1>Staff Rust &amp; AI Browser Engineer (Remote)</h1>\n' +
    '    <p>Compensation: <strong>$225,000</strong> · Work on low-level Chrome DevTools Protocol, Tokio, and SQLite engines.</p>\n' +
    '    <input type="text" placeholder="GitHub handle" value="@selibrah">\n' +
    '    <input type="file" aria-label="Attach portfolio PDF">\n' +
    '    <button type="button" onclick="this.textContent=\'Bookmarked ✓\'">Bookmark Role</button>\n' +
    '  </main>\n' +
    '</body>\n</html>';

  // ==========================================================================
  // IN-BROWSER RELATIONAL STORE MIRRORING `FindingsStore.swift` + `job_watch.py`
  // ==========================================================================
  const CANONICAL_STAGES = ["new", "contacted", "replied", "visit", "dropped"];

  function stageLabelFor(category, canonicalStatus) {
    if (canonicalStatus === "new") return "New";
    if (canonicalStatus === "contacted") return category === "jobs" ? "Applied" : (category === "leads" ? "Pitched" : "Contacted");
    if (canonicalStatus === "replied") return category === "jobs" ? "Interview" : "Replied";
    if (canonicalStatus === "visit") return category === "jobs" ? "Offer" : (category === "leads" ? "Won" : "Visit");
    if (canonicalStatus === "dropped") return category === "jobs" ? "Archived" : "Dropped";
    return canonicalStatus;
  }

  function scoreExtractedDocument(category, title, markdown) {
    const blob = (title + " " + markdown).toLowerCase();
    let pts = 55;
    const tags = [];
    if (category === "housing") {
      if (/particulier|bla samsar|sans intermédiaire/.test(blob)) { pts += 18; tags.push("Particulier"); }
      if (/maârif|maarif|gauthier|racine|abdelmoumen|tramway/.test(blob)) { pts += 14; tags.push("Tramway <1km"); }
      if (/meublé|fibre|sans vis-à-vis/.test(blob)) { pts += 8; tags.push("Meublé/Fibre"); }
      const dhMatch = blob.match(/(\d[\d\s,.]{2,5})\s*(?:dh|mad)\b/i);
      let amount = null;
      if (dhMatch) {
        const parsed = parseInt(dhMatch[1].replace(/[\s,.]/g, ""), 10);
        if (parsed >= 400 && parsed <= 25000) {
          amount = parsed;
          if (parsed <= 1350) pts += 5;
        }
      }
      return { score: Math.min(99, pts), amount: amount, currency: "DH", tags: tags };
    }

    if (/\b(remote|télétravail|global)\b/.test(blob)) { pts += 15; tags.push("Remote"); }
    const boosts = ["rust", "tokio", "cdp", "websocket", "sqlite", "swift", "macos", "mcp", "ai"];
    let matched = 0;
    for (let i = 0; i < boosts.length; i++) {
      if (blob.indexOf(boosts[i]) !== -1) {
        matched++;
        if (tags.length < 4) tags.push(boosts[i]);
      }
    }
    pts += Math.min(24, matched * 6);
    let salary = null;
    const salFull = (title + " " + markdown).match(/\$\s*(\d{2,3})[, ](\d{3})\b/);
    const salK = (title + " " + markdown).match(/\$\s*(\d{2,3})\s*k\b/i);
    if (salFull) salary = parseInt(salFull[1] + salFull[2], 10);
    else if (salK) salary = parseInt(salK[1], 10) * 1000;
    if (salary) { pts += 5; }
    return { score: Math.min(99, pts), amount: salary, currency: "$", tags: tags };
  }

  const FindingsDB = {
    rows: [
      {
        uid: "jobs:linear.app:senior-rust-systems-engineer", category: "jobs", source: "linear.app", external_id: "senior-rust-systems-engineer",
        title: "Senior Rust Systems Engineer", subtitle: "linear.app · Remote, rust, tokio, cdp",
        amount: 210000, currency: "$", score: 95, tags: ["Remote", "rust", "tokio", "cdp"],
        url: "https://boards.linear.app/jobs/409182-senior-rust-systems",
        snippet: "Architect sub-millisecond local daemons and persistent WebSocket pools.",
        status: "replied", note: "System design interview Thursday 15:00 UTC."
      },
      {
        uid: "jobs:greenhouse.io:410928", category: "jobs", source: "greenhouse.io", external_id: "410928",
        title: "AI Runtime & MCP Tooling Engineer", subtitle: "greenhouse.io · Remote, mcp, rust",
        amount: 235000, currency: "$", score: 93, tags: ["Remote", "mcp", "rust"],
        url: "https://boards.greenhouse.io/anthropic/jobs/410928",
        snippet: "Build deterministic browser & local MCP execution runtimes.",
        status: "contacted", note: "Attached CV via DataTransfer (/upload)."
      },
      {
        uid: "jobs:ycombinator.com:88120", category: "jobs", source: "ycombinator.com", external_id: "88120",
        title: "Staff macOS & Swift 6 Infrastructure", subtitle: "ycombinator.com · Remote, swift, macos",
        amount: 195000, currency: "$", score: 90, tags: ["Remote", "swift", "macos"],
        url: "https://news.ycombinator.com/item?id=42918210",
        snippet: "Zero-idle native macOS productivity systems.",
        status: "new", note: ""
      },
      {
        uid: "jobs:zed.dev:77412", category: "jobs", source: "zed.dev", external_id: "77412",
        title: "Rust & GPU Typography Engineer", subtitle: "zed.dev · Remote, rust",
        amount: 185000, currency: "$", score: 88, tags: ["Remote", "rust"],
        url: "https://zed.dev/jobs/rust-gpu",
        snippet: "Glyph-atlas text rendering and low-latency RPC.",
        status: "new", note: ""
      },
      {
        uid: "housing:avito.ma:studio-meuble-maarif-extensi", category: "housing", source: "avito.ma", external_id: "studio-meuble-maarif-extensi",
        title: "Studio meublé Maârif Extension sans vis-à-vis", subtitle: "avito.ma · Particulier, Tramway <1km",
        amount: 1150, currency: "DH", score: 95, tags: ["Particulier", "Tramway <1km"],
        url: "https://www.avito.ma/fr/maarif/studio_meuble_91827.htm",
        snippet: "Studio lumineux refait à neuf quartier Maârif Extension, fibre incluse.",
        status: "visit", note: "Visite confirmée Samedi 11h00."
      },
      {
        uid: "housing:facebook.com:55102", category: "housing", source: "facebook.com", external_id: "55102",
        title: "Chambre calme Abdelmoumen T1/T2", subtitle: "facebook.com · Price drop 1,300 → 1,050 DH",
        amount: 1050, currency: "DH", score: 91, tags: ["Tramway <1km"],
        url: "https://www.facebook.com/groups/colocation.casablanca",
        snippet: "Colocation calme proche station Abdelmoumen.",
        status: "contacted", note: "Deduplicated across 3 groups."
      },
      {
        uid: "housing:mubawab.ma:66391", category: "housing", source: "mubawab.ma", external_id: "66391",
        title: "Colocation Gauthier lumineuse", subtitle: "mubawab.ma · 1.4 km · Fibre optique",
        amount: 1250, currency: "DH", score: 87, tags: ["Meublé/Fibre"],
        url: "https://www.mubawab.ma/fr/a/7891234",
        snippet: "Appartement partagé Gauthier.",
        status: "new", note: ""
      }
    ],

    upsert: function (record) {
      const t0 = performance.now();
      const idx = this.rows.findIndex(function (r) { return r.uid === record.uid; });
      const isNew = idx === -1;
      if (isNew) {
        this.rows.unshift({
          uid: record.uid,
          category: record.category,
          source: record.source,
          external_id: record.external_id,
          title: record.title,
          subtitle: record.subtitle,
          amount: record.amount,
          currency: record.currency || "$",
          score: record.score,
          tags: record.tags || [],
          url: record.url || "",
          snippet: record.snippet || "",
          status: "new",
          note: record.note || ""
        });
      } else {
        const existing = this.rows[idx];
        existing.score = record.score;
        if (record.amount != null) existing.amount = record.amount;
        if (record.snippet) existing.snippet = record.snippet;
        existing.title = record.title;
      }
      this.rows.sort(function (a, b) { return b.score - a.score; });
      const dt = (performance.now() - t0).toFixed(2);
      const sql = "INSERT INTO findings (uid, category, source, title, amount, score) VALUES ('" +
        record.uid.replace(/'/g, "''") + "', '" + record.category + "', '" + record.source + "', '" +
        record.title.slice(0, 32).replace(/'/g, "''") + "', " + (record.amount || "NULL") + ", " + record.score +
        ") ON CONFLICT(uid) DO UPDATE SET score=excluded.score; -- " + (isNew ? "INSERT 1" : "UPSERT 1") + " (" + dt + " ms)";
      return { isNew: isNew, sql: sql, elapsedMs: Number(dt) };
    },

    updateRow: function (uid, fields) {
      const t0 = performance.now();
      const r = this.rows.find(function (x) { return x.uid === uid; });
      if (!r) return null;
      const sets = [];
      if (fields.status != null) { r.status = fields.status; sets.push("status='" + fields.status + "'"); }
      if (fields.note != null) { r.note = fields.note; sets.push("note='" + fields.note.slice(0, 28).replace(/'/g, "''") + "'"); }
      const dt = (performance.now() - t0).toFixed(2);
      return "UPDATE findings SET " + sets.join(", ") + " WHERE uid='" + uid + "'; -- 1 row (" + dt + " ms)";
    },

    /** Exact port of `FindingsStore.swift` `amountHistogram(for:)` (lines 381-418) */
    amountHistogram: function (subset) {
      const priced = subset.filter(function (i) { return i.amount && i.amount > 0; });
      if (!priced.length) return { bins: [], median: null, currency: "" };
      const curCounts = {};
      priced.forEach(function (i) { curCounts[i.currency] = (curCounts[i.currency] || 0) + 1; });
      const domCur = Object.keys(curCounts).sort(function (a, b) { return curCounts[b] - curCounts[a]; })[0];
      const values = priced.filter(function (i) { return i.currency === domCur; }).map(function (i) { return i.amount; }).sort(function (a, b) { return a - b; });
      if (!values.length) return { bins: [], median: null, currency: domCur };
      const med = values[Math.floor(values.length / 2)];
      const baseStep = values[0] >= 10000 ? 10000 : 100;
      const lo = Math.floor(values[0] / baseStep) * baseStep;
      let step = baseStep;
      while (Math.floor((values[values.length - 1] - lo) / step) >= 10) step *= 2;
      const binCount = Math.max(1, Math.floor((values[values.length - 1] - lo) / step) + 1);
      const counts = new Array(binCount).fill(0);
      values.forEach(function (v) {
        const idx = Math.min(binCount - 1, Math.max(0, Math.floor((v - lo) / step)));
        counts[idx]++;
      });
      const bins = counts.map(function (c, i) {
        const bFrom = lo + i * step;
        const bTo = lo + (i + 1) * step - 1;
        const lbl = bFrom >= 10000 ? Math.floor(bFrom / 1000) + "k" : String(bFrom);
        return { from: bFrom, to: bTo, label: lbl, count: c, containsMedian: med >= bFrom && med <= bTo };
      });
      return { bins: bins, median: med, currency: domCur };
    },

    funnelCounts: function (subset, category) {
      return CANONICAL_STAGES.map(function (k) {
        return {
          key: k,
          label: stageLabelFor(category, k),
          count: subset.filter(function (i) { return i.status === k; }).length
        };
      });
    }
  };

  // ==========================================================================
  // CAUSAL RUNTIME CONTROLLER
  // ==========================================================================
  const targetFrame = document.getElementById("target-browser-frame");
  const studioMount = document.getElementById("studio-mount");
  const sqlLogBar = document.getElementById("studio-sql-log");
  const execMsBadge = document.getElementById("studio-exec-ms");
  const crmCountBadge = document.getElementById("crm-count-badge");
  const mcpCountBadge = document.getElementById("mcp-count-badge");
  const kernelShaBadge = document.getElementById("kernel-sha-badge");
  const customDrawer = document.getElementById("custom-html-drawer");
  const customTextarea = document.getElementById("custom-html-input");

  customTextarea.value = DEFAULT_CUSTOM_HTML;
  if (K && K.META) {
    kernelShaBadge.textContent = "dom.rs#" + K.META.dom_rs_sha256_prefix.slice(0, 8);
    mcpCountBadge.textContent = String(K.META.tool_count);
  }
  crmCountBadge.textContent = String(FindingsDB.rows.length);

  const labState = {
    fixtureKey: "ats-job",
    workspace: "workbench",   // workbench | crm | mcp
    wbTab: "snapshot",        // snapshot | read | eval
    crmCategory: "jobs",      // jobs | housing
    crmView: "pipeline",      // pipeline | charts
    selectedUid: "jobs:linear.app:senior-rust-systems-engineer",
    lastSnapshot: null,
    lastRead: null,
    lastAct: null,
    lastUpload: null,
    lastEvalExpr: "document.title + ' · interactive refs: ' + document.querySelectorAll('[data-station-ref]').length",
    lastEvalOut: "",
    mcpSelectedOp: "station_snapshot",
    mcpWireOutput: "",
    rawHtmlBytes: 0,
    sqlHistory: []
  };

  function recordLog(entry, msVal) {
    if (typeof msVal === "number") {
      execMsBadge.textContent = msVal.toFixed(2) + " ms";
    }
    labState.sqlHistory.unshift(entry);
    if (labState.sqlHistory.length > 25) labState.sqlHistory.pop();
    sqlLogBar.textContent = entry;
    crmCountBadge.textContent = String(FindingsDB.rows.length);
  }

  function renderIframeRefOverlays(highlightRef) {
    const doc = targetFrame.contentDocument;
    if (!doc || !doc.body) return;
    let layer = doc.getElementById("__station_ref_overlay");
    if (!layer) {
      layer = doc.createElement("div");
      layer.id = "__station_ref_overlay";
      layer.setAttribute("aria-hidden", "true");
      layer.style.cssText = "position:absolute;inset:0;pointer-events:none;z-index:2147483647;overflow:hidden;";
      doc.body.style.position = doc.body.style.position || "relative";
      doc.body.appendChild(layer);
    }
    layer.innerHTML = "";
    const win = targetFrame.contentWindow;
    const sx = win ? win.scrollX : 0;
    const sy = win ? win.scrollY : 0;
    const tagged = doc.querySelectorAll("[data-station-ref]");
    tagged.forEach(function (el) {
      const ref = el.getAttribute("data-station-ref");
      const r = el.getBoundingClientRect();
      if (r.width < 2 || r.height < 2) return;
      const isHi = highlightRef === ref;
      const box = doc.createElement("div");
      box.style.cssText =
        "position:absolute;left:" + Math.max(0, r.left + sx) + "px;top:" + Math.max(0, r.top + sy) + "px;" +
        "width:" + r.width + "px;height:" + r.height + "px;" +
        "border:1.5px " + (isHi ? "solid #2DD4BF" : "dashed rgba(56,189,248,0.65)") + ";" +
        "background:" + (isHi ? "rgba(45,212,191,0.14)" : "transparent") + ";border-radius:4px;box-sizing:border-box;";
      const tag = doc.createElement("span");
      tag.textContent = "@" + ref;
      tag.style.cssText =
        "position:absolute;top:-15px;left:-1px;padding:0 4px;border-radius:3px;" +
        "font:700 9.5px monospace;line-height:14px;" +
        "background:" + (isHi ? "#2DD4BF" : "#38BDF8") + ";color:#07090E;";
      box.appendChild(tag);
      layer.appendChild(box);
    });
    document.getElementById("target-overlay-pill").textContent = "@eN Overlay: " + tagged.length + " refs";
  }

  function refreshTargetStatusBar() {
    const doc = targetFrame.contentDocument;
    if (!doc || !doc.documentElement) return;
    const overlay = doc.getElementById("__station_ref_overlay");
    const saved = overlay ? overlay.innerHTML : null;
    if (overlay) overlay.remove();
    const rawHtml = doc.documentElement.outerHTML || "";
    labState.rawHtmlBytes = utf8Len(rawHtml);
    if (overlay && saved != null && doc.body) {
      overlay.innerHTML = saved;
      doc.body.appendChild(overlay);
    }

    document.getElementById("target-win-title").textContent = doc.title || "Target DOM";
    const baseEl = doc.querySelector("base[href]");
    document.getElementById("target-omnibox-url").textContent =
      (baseEl && baseEl.getAttribute("href")) || "about:srcdoc (custom HTML)";
    document.getElementById("target-raw-stats").textContent =
      "Raw HTML: " + labState.rawHtmlBytes.toLocaleString() + " B (~" + estTokens(rawHtml).toLocaleString() + " tok)";

    const fileInput = doc.querySelector('input[type="file"]');
    const fileStatEl = document.getElementById("target-file-stats");
    if (!fileInput) {
      fileStatEl.textContent = "input[type=file]: none on page";
      fileStatEl.style.color = "var(--muted)";
    } else if (fileInput.files && fileInput.files.length > 0) {
      const f = fileInput.files[0];
      fileStatEl.textContent = "input[type=file]: " + f.name + " (" + f.size.toLocaleString() + " B ✓)";
      fileStatEl.style.color = "var(--mint)";
    } else {
      fileStatEl.textContent = "input[type=file]: 0 files";
      fileStatEl.style.color = "var(--slate)";
    }
  }

  function runSnapshot(viewportOnly, maxElements) {
    const win = targetFrame.contentWindow;
    const doc = targetFrame.contentDocument;
    if (!win || !doc) return null;
    const overlay = doc.getElementById("__station_ref_overlay");
    if (overlay) overlay.remove();

    const js = K.buildSnapshotJs(Boolean(viewportOnly), maxElements || 120);
    const t0 = performance.now();
    const snap = win.eval(js);
    const elapsed = performance.now() - t0;

    labState.lastSnapshot = snap;
    refreshTargetStatusBar();
    renderIframeRefOverlays(null);
    const snapBytes = utf8Len(snap.snapshot_text);
    const pct = labState.rawHtmlBytes > 0
      ? Math.max(0, ((1 - snapBytes / labState.rawHtmlBytes) * 100)).toFixed(1)
      : "0.0";
    recordLog(
      "KERNEL dom.rs::build_snapshot_js -> " + snap.element_count + " @eN refs · " +
      labState.rawHtmlBytes.toLocaleString() + " B → " + snapBytes.toLocaleString() + " B (-" + pct + "%)",
      elapsed
    );
    return snap;
  }

  function runRead(maxChars) {
    const win = targetFrame.contentWindow;
    const doc = targetFrame.contentDocument;
    if (!win || !doc) return null;
    const overlay = doc.getElementById("__station_ref_overlay");
    if (overlay) overlay.remove();

    const js = K.buildReadJs(maxChars || 40000);
    const t0 = performance.now();
    const res = win.eval(js);
    const elapsed = performance.now() - t0;

    labState.lastRead = res;
    renderIframeRefOverlays(null);
    recordLog(
      "KERNEL dom.rs::build_read_js -> " + res.markdown_chars.toLocaleString() + " chars (-" +
      res.token_savings_pct + "% vs " + res.raw_html_chars.toLocaleString() + " raw chars)",
      elapsed
    );
    return res;
  }

  async function runAct(params) {
    const win = targetFrame.contentWindow;
    if (!win) return null;
    const js = K.buildActJs(params);
    const t0 = performance.now();
    const res = await win.eval(js);
    const elapsed = performance.now() - t0;
    labState.lastAct = res;
    const snapJs = K.buildSnapshotJs(false, 120);
    const doc = targetFrame.contentDocument;
    const overlay = doc && doc.getElementById("__station_ref_overlay");
    if (overlay) overlay.remove();
    labState.lastSnapshot = win.eval(snapJs);
    refreshTargetStatusBar();
    renderIframeRefOverlays((params.target || "").replace(/^@/, ""));
    recordLog(
      "KERNEL dom.rs::build_act_js(" + params.action + " " + (params.target || "") + ") -> " + JSON.stringify(res),
      elapsed
    );
    return res;
  }

  function runUpload(selectorOrRef, fileName, contentSize) {
    const win = targetFrame.contentWindow;
    if (!win) return null;
    const fname = fileName || "selibrah_cv_2026.pdf";
    const byteLen = contentSize || 18432;
    const stageScript =
      "(() => {" +
      "  const bytes = new Uint8Array(" + Number(byteLen) + ");" +
      "  const hdr = '%PDF-1.7 Station DataTransfer Resume';" +
      "  for (let i = 0; i < hdr.length && i < bytes.length; i++) bytes[i] = hdr.charCodeAt(i);" +
      "  window.__stationUploadFiles = [new File([bytes], " + JSON.stringify(fname) + ", { type: 'application/pdf' })];" +
      "})()";
    const attachJs = K.buildUploadAttachJs(selectorOrRef || "input[type=file]");
    const t0 = performance.now();
    win.eval(stageScript);
    const res = win.eval(attachJs);
    const elapsed = performance.now() - t0;
    labState.lastUpload = res;
    refreshTargetStatusBar();
    renderIframeRefOverlays((selectorOrRef || "").replace(/^@/, ""));
    recordLog(
      "KERNEL dom.rs::build_upload_attach_js(" + (selectorOrRef || "input[type=file]") + ") -> " +
      (res && res.ok ? fname + " attached via DataTransfer (0 OS dialogs)" : JSON.stringify(res)),
      elapsed
    );
    return res;
  }

  function harvestCurrentTab() {
    const readRes = runRead(40000);
    if (!readRes) return null;
    const doc = targetFrame.contentDocument;
    const baseHref = (doc && doc.querySelector("base[href]") && doc.querySelector("base[href]").getAttribute("href")) || readRes.url || "about:srcdoc";
    const rawTitle = (readRes.title || "").split("—")[0].trim() || (doc && doc.querySelector("h1") && doc.querySelector("h1").innerText.trim()) || "Extracted Web Listing";
    const blob = (readRes.title + " " + readRes.markdown).toLowerCase();
    const cat = /\b(dh|mad|studio|chambre|colocation|appartement|maârif|maarif)\b/i.test(blob) ? "housing" : "jobs";
    const scored = scoreExtractedDocument(cat, readRes.title || rawTitle, readRes.markdown);

    let host = "custom-html";
    try {
      const u = new URL(baseHref);
      if (u.hostname) host = u.hostname.replace(/^(www|boards)\./, "");
    } catch (_) {}
    const slug = rawTitle
      .normalize("NFD")
      .replace(/[\u0300-\u036f]/g, "")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-|-$/g, "")
      .slice(0, 28) || "item";
    const uid = cat + ":" + host + ":" + slug;

    const up = FindingsDB.upsert({
      uid: uid,
      category: cat,
      source: host,
      external_id: slug,
      title: rawTitle,
      subtitle: host + (scored.tags.length ? " · " + scored.tags.join(", ") : ""),
      amount: scored.amount,
      currency: scored.currency,
      score: scored.score,
      tags: scored.tags,
      url: baseHref,
      snippet: readRes.markdown.slice(0, 240)
    });

    labState.crmCategory = cat;
    labState.selectedUid = uid;
    labState.workspace = "crm";
    labState.crmView = "pipeline";
    recordLog(up.sql, up.elapsedMs);
    syncWorkspaceButtons();
    renderStudio();
    return { uid: uid, category: cat, score: scored.score, amount: scored.amount, currency: scored.currency, isNew: up.isNew };
  }

  function mountHtmlInTarget(rawHtml) {
    return new Promise(function (resolve) {
      const onLoaded = function () {
        targetFrame.removeEventListener("load", onLoaded);
        const snap = runSnapshot(false, 120);
        const doc = targetFrame.contentDocument;
        const ov = doc && doc.getElementById("__station_ref_overlay");
        if (ov) ov.remove();
        labState.lastRead = targetFrame.contentWindow.eval(K.buildReadJs(40000));
        renderIframeRefOverlays(null);
        renderStudio();
        resolve({ snapshot: snap, read: labState.lastRead });
      };
      targetFrame.addEventListener("load", onLoaded);
      targetFrame.srcdoc = rawHtml;
    });
  }

  function syncWorkspaceButtons() {
    document.querySelectorAll("[data-ws]").forEach(function (btn) {
      btn.setAttribute("aria-pressed", String(btn.getAttribute("data-ws") === labState.workspace));
    });
  }

  function renderWorkbench() {
    const snap = labState.lastSnapshot || runSnapshot(false, 120);
    const snapBytes = snap ? utf8Len(snap.snapshot_text) : 0;
    const snapSavings = labState.rawHtmlBytes > 0
      ? Math.max(0, ((1 - snapBytes / labState.rawHtmlBytes) * 100)).toFixed(1)
      : "0.0";

    let contentHtml = "";
    if (labState.wbTab === "snapshot") {
      const doc = targetFrame.contentDocument;
      const elems = (snap && snap.elements) ? snap.elements : [];
      const rows = elems.map(function (el) {
        let controls = "";
        if (el.type === "file") {
          controls = '<button type="button" class="sim-btn sim-btn-mint" data-do-upload="@' + esc(el.ref) + '">Attach CV PDF (/upload)</button>';
        } else if ((el.tag === "input" && el.type !== "checkbox" && el.type !== "radio" && el.type !== "submit" && el.type !== "button") || el.tag === "textarea") {
          const nextSample = el.value && el.value.indexOf("Principal") === -1
            ? "Principal Rust & CDP Architect"
            : "Salam! Visite Samedi 11h confirmée";
          controls =
            '<input type="text" class="sim-input" aria-label="Fill value for @' + esc(el.ref) + '" data-fill-input="@' + esc(el.ref) + '" value="' + esc(nextSample) + '" style="width:170px;">' +
            '<button type="button" class="sim-btn sim-btn-accent" data-do-fill="@' + esc(el.ref) + '">Fill @' + esc(el.ref) + '</button>';
        } else if (el.tag === "select" && doc) {
          const liveSel = doc.querySelector('[data-station-ref="' + el.ref + '"]');
          const opts = liveSel ? Array.from(liveSel.options).map(function (o) {
            return '<option value="' + esc(o.value) + '"' + (o.value === el.value ? " selected" : "") + '>' + esc(o.text) + '</option>';
          }).join("") : "";
          controls =
            '<select class="sim-select" aria-label="Select option for @' + esc(el.ref) + '" data-select-input="@' + esc(el.ref) + '">' + opts + '</select>' +
            '<button type="button" class="sim-btn" data-do-select="@' + esc(el.ref) + '">Select</button>';
        } else {
          controls = '<button type="button" class="sim-btn" data-do-click="@' + esc(el.ref) + '">Click @' + esc(el.ref) + '</button>';
        }

        return '' +
          '<div class="en-row" data-hover-ref="' + esc(el.ref) + '">' +
            '<div style="display:flex;align-items:center;gap:7px;min-width:0;flex:1;">' +
              '<span class="ref-chip mono">@' + esc(el.ref) + '</span>' +
              '<span class="mono" style="font-size:11px;color:var(--muted);">' + esc(el.role) + '</span>' +
              '<span style="font-size:12.5px;font-weight:500;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">' + esc(el.label || el.tag) + '</span>' +
              (el.value ? '<span class="mono" style="font-size:11px;color:var(--mint);">="' + esc(el.value) + '"</span>' : '') +
            '</div>' +
            '<div style="display:flex;align-items:center;gap:5px;flex-wrap:wrap;">' + controls + '</div>' +
          '</div>';
      }).join("");

      contentHtml = '' +
        '<div class="telemetry-ribbon mono">' +
          '<span>Raw: <strong>' + labState.rawHtmlBytes.toLocaleString() + ' B</strong> (~' + Math.ceil(labState.rawHtmlBytes / 4).toLocaleString() + ' tok) → Snapshot: <strong style="color:var(--mint);">' + snapBytes.toLocaleString() + ' B (~' + estTokens(snap ? snap.snapshot_text : "") + ' tok · -' + snapSavings + '%)</strong></span>' +
          '<button type="button" class="sim-btn" id="btn-rerun-snap">↻ Run build_snapshot_js</button>' +
        '</div>' +
        '<div class="en-list">' +
          (rows || '<div style="padding:20px;color:var(--slate);font-size:12.5px;">No visible interactive elements found in target DOM.</div>') +
        '</div>';
    } else if (labState.wbTab === "read") {
      const rd = runRead(40000);
      contentHtml = '' +
        '<div class="telemetry-ribbon mono">' +
          '<span>Raw HTML: <strong>' + rd.raw_html_chars.toLocaleString() + ' chars</strong> → Clean Markdown: <strong style="color:var(--mint);">' + rd.markdown_chars.toLocaleString() + ' chars (~' + rd.estimated_tokens + ' tok · -' + rd.token_savings_pct + '%)</strong></span>' +
          '<span style="color:var(--prism);">__NEXT_DATA__ stripped: ' + String(rd.structured_data.has_next_data) + '</span>' +
        '</div>' +
        '<div style="padding:12px;flex:1;display:flex;flex-direction:column;gap:8px;">' +
          '<pre class="chart-card mono" id="live-markdown-output" style="margin:0;max-height:360px;overflow:auto;font-size:11.5px;line-height:1.55;white-space:pre-wrap;color:var(--ivory);">' + esc(rd.markdown) + '</pre>' +
        '</div>';
    } else {
      contentHtml = '' +
        '<div style="padding:12px;display:flex;flex-direction:column;gap:10px;">' +
          '<div style="display:flex;gap:6px;flex-wrap:wrap;">' +
            '<label for="live-eval-input" class="skip-link">JavaScript expression to evaluate in target frame</label>' +
            '<input id="live-eval-input" type="text" class="sim-input mono" style="flex:1;min-width:200px;" value="' + esc(labState.lastEvalExpr) + '">' +
            '<button type="button" class="sim-btn sim-btn-accent" id="btn-run-eval">▶ Eval in Target Frame</button>' +
          '</div>' +
          '<pre class="chart-card mono" style="margin:0;min-height:240px;font-size:11.5px;color:var(--mint);white-space:pre-wrap;overflow:auto;">' +
            esc(labState.lastEvalOut || "// Click 'Eval in Target Frame' to execute directly inside iframe.contentWindow") +
          '</pre>' +
        '</div>';
    }

    studioMount.innerHTML = '' +
      '<div class="telemetry-ribbon" style="background:#080C14;">' +
        '<div class="pill-group" role="group" aria-label="Workbench mode">' +
          '<button type="button" class="lab-pill" data-wbtab="snapshot" aria-pressed="' + (labState.wbTab === "snapshot") + '">Snapshot (@eN)</button>' +
          '<button type="button" class="lab-pill" data-wbtab="read" aria-pressed="' + (labState.wbTab === "read") + '">Clean Markdown (/read)</button>' +
          '<button type="button" class="lab-pill" data-wbtab="eval" aria-pressed="' + (labState.wbTab === "eval") + '">JS Eval</button>' +
        '</div>' +
        '<span class="mono" style="font-size:11px;color:var(--muted);">Hover @eN to highlight target DOM</span>' +
      '</div>' +
      contentHtml;

    studioMount.querySelectorAll("[data-wbtab]").forEach(function (b) {
      b.addEventListener("click", function () {
        labState.wbTab = b.getAttribute("data-wbtab");
        renderStudio();
      });
    });

    const rerunBtn = document.getElementById("btn-rerun-snap");
    if (rerunBtn) {
      rerunBtn.addEventListener("click", function () {
        runSnapshot(false, 120);
        renderStudio();
      });
    }

    studioMount.querySelectorAll("[data-hover-ref]").forEach(function (row) {
      row.addEventListener("mouseenter", function () {
        renderIframeRefOverlays(row.getAttribute("data-hover-ref"));
      });
      row.addEventListener("mouseleave", function () {
        renderIframeRefOverlays(null);
      });
    });

    studioMount.querySelectorAll("[data-do-click]").forEach(function (btn) {
      btn.addEventListener("click", async function () {
        await runAct({ action: "click", target: btn.getAttribute("data-do-click"), value: "" });
        renderStudio();
      });
    });

    studioMount.querySelectorAll("[data-do-fill]").forEach(function (btn) {
      btn.addEventListener("click", async function () {
        const ref = btn.getAttribute("data-do-fill");
        const inp = studioMount.querySelector('[data-fill-input="' + ref + '"]');
        const val = inp ? inp.value : "";
        await runAct({ action: "fill", target: ref, value: val });
        renderStudio();
      });
    });

    studioMount.querySelectorAll("[data-do-select]").forEach(function (btn) {
      btn.addEventListener("click", async function () {
        const ref = btn.getAttribute("data-do-select");
        const sel = studioMount.querySelector('[data-select-input="' + ref + '"]');
        const val = sel ? sel.value : "";
        await runAct({ action: "select", target: ref, value: val });
        renderStudio();
      });
    });

    studioMount.querySelectorAll("[data-do-upload]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        runUpload(btn.getAttribute("data-do-upload"), "selibrah_cv_2026.pdf", 18432);
        renderStudio();
      });
    });

    const evalBtn = document.getElementById("btn-run-eval");
    if (evalBtn) {
      evalBtn.addEventListener("click", function () {
        const expr = document.getElementById("live-eval-input").value;
        labState.lastEvalExpr = expr;
        const t0 = performance.now();
        try {
          const out = targetFrame.contentWindow.eval(expr);
          const dt = performance.now() - t0;
          labState.lastEvalOut = JSON.stringify(out, null, 2);
          recordLog("EVAL -> " + String(labState.lastEvalOut).slice(0, 72), dt);
        } catch (err) {
          labState.lastEvalOut = "Error: " + err.message;
        }
        renderStudio();
      });
    }
  }

  function formatAmt(amt, cur) {
    if (!amt) return "—";
    return cur === "$" ? "$" + Number(amt).toLocaleString() : Number(amt).toLocaleString() + " " + cur;
  }

  function renderCrm() {
    const subset = FindingsDB.rows.filter(function (r) { return r.category === labState.crmCategory; });
    let sel = subset.find(function (r) { return r.uid === labState.selectedUid; }) || subset[0] || null;
    if (sel) labState.selectedUid = sel.uid;

    const hist = FindingsDB.amountHistogram(subset);
    const funnel = FindingsDB.funnelCounts(subset, labState.crmCategory);
    const jobsCount = FindingsDB.rows.filter(function (r) { return r.category === "jobs"; }).length;
    const rentCount = FindingsDB.rows.filter(function (r) { return r.category === "housing"; }).length;

    let bodyHtml = "";
    if (labState.crmView === "pipeline") {
      const listHtml = subset.map(function (item) {
        const lbl = stageLabelFor(item.category, item.status);
        const cls = item.status === "visit" || item.status === "replied" ? "stage-badge mint" : (item.status === "new" ? "stage-badge amber" : "stage-badge");
        return '' +
          '<button type="button" class="crm-row-btn" data-crm-uid="' + esc(item.uid) + '" aria-selected="' + (sel && sel.uid === item.uid) + '">' +
            '<div style="display:flex;align-items:center;gap:8px;min-width:0;">' +
              '<span class="score-box mono">' + item.score + '</span>' +
              '<div style="min-width:0;">' +
                '<div style="font-size:12.5px;font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">' + esc(item.title) + '</div>' +
                '<div style="font-size:11px;color:var(--slate);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">' + esc(item.subtitle) + '</div>' +
              '</div>' +
            '</div>' +
            '<div style="text-align:right;flex-shrink:0;">' +
              '<div class="mono" style="font-size:12px;font-weight:600;">' + esc(formatAmt(item.amount, item.currency)) + '</div>' +
              '<span class="' + cls + '">' + esc(lbl) + '</span>' +
            '</div>' +
          '</button>';
      }).join("");

      let detailHtml = "";
      if (sel) {
        const stageBtns = CANONICAL_STAGES.map(function (st) {
          return '<button type="button" class="stage-step-btn" data-set-stage="' + st + '" aria-pressed="' + (sel.status === st) + '">' +
            esc(stageLabelFor(sel.category, st)) + '</button>';
        }).join("");

        detailHtml = '' +
          '<div>' +
            '<div style="font-size:14px;font-weight:700;">' + esc(sel.title) + '</div>' +
            '<div class="mono" style="font-size:11px;color:var(--prism);margin-top:2px;">PK: ' + esc(sel.uid) + '</div>' +
          '</div>' +
          '<div>' +
            '<div style="font-size:11.5px;color:var(--slate);margin-bottom:5px;">Pipeline stage (executes SQLite UPDATE &amp; recalculates Funnel):</div>' +
            '<div class="stage-stepper">' + stageBtns + '</div>' +
          '</div>' +
          '<div style="font-size:11.5px;color:var(--slate);background:#080B12;padding:8px;border-radius:6px;border:1px solid var(--hairline);">' +
            esc(sel.snippet || "No snippet") +
          '</div>' +
          '<div>' +
            '<label for="crm-note-box" style="display:block;font-size:11.5px;color:var(--slate);margin-bottom:4px;">Persistent SQLite note:</label>' +
            '<textarea id="crm-note-box" class="custom-html-textarea" style="height:56px;">' + esc(sel.note) + '</textarea>' +
            '<div style="display:flex;justify-content:space-between;align-items:center;margin-top:5px;">' +
              '<span class="mono" style="font-size:11px;color:var(--mint);">Median: ' + esc(formatAmt(hist.median, hist.currency)) + '</span>' +
              '<button type="button" class="sim-btn" id="btn-save-crm-note">Save Note</button>' +
            '</div>' +
          '</div>';
      }

      bodyHtml = '<div class="crm-split"><div class="crm-master">' + listHtml + '</div><div class="crm-detail">' + detailHtml + '</div></div>';
    } else {
      const maxBin = Math.max.apply(null, hist.bins.map(function (b) { return b.count; }).concat([1]));
      const barsHtml = hist.bins.map(function (b) {
        const hPct = Math.max(8, Math.round((b.count / maxBin) * 92));
        return '' +
          '<div class="hist-col">' +
            '<span class="mono" style="font-size:10px;color:var(--slate);">' + b.count + '</span>' +
            '<div class="hist-bar-fill ' + (b.containsMedian ? "median" : "") + '" style="height:' + (b.count ? hPct : 4) + '%;"></div>' +
            '<span class="mono" style="font-size:10px;color:var(--muted);">' + esc(b.label) + '</span>' +
          '</div>';
      }).join("");

      const funnelHtml = funnel.map(function (f) {
        const pct = subset.length ? Math.round((f.count / subset.length) * 100) : 0;
        return '' +
          '<div class="funnel-row">' +
            '<span style="color:var(--slate);">' + esc(f.label) + '</span>' +
            '<div class="funnel-bar-bg"><div class="funnel-bar-fill" style="width:' + (f.count ? Math.max(10, pct) : 0) + '%;background:' + (f.key === "visit" || f.key === "replied" ? "var(--mint)" : "var(--prism)") + ';"></div></div>' +
            '<span class="mono" style="text-align:right;">' + f.count + '</span>' +
          '</div>';
      }).join("");

      bodyHtml = '' +
        '<div class="charts-2col">' +
          '<div class="chart-card">' +
            '<div style="display:flex;justify-content:space-between;align-items:baseline;">' +
              '<span style="font-size:12.5px;font-weight:600;">Amount Histogram (' + esc(hist.currency) + ')</span>' +
              '<span class="mono" style="font-size:11.5px;color:var(--mint);">Median: ' + esc(formatAmt(hist.median, hist.currency)) + '</span>' +
            '</div>' +
            '<div class="hist-bars">' + barsHtml + '</div>' +
            '<div style="margin-top:7px;font-size:11px;color:var(--slate);">Computed live via <code>FindingsStore.amountHistogram</code> power-of-2 bins.</div>' +
          '</div>' +
          '<div class="chart-card">' +
            '<div style="display:flex;justify-content:space-between;align-items:baseline;margin-bottom:6px;">' +
              '<span style="font-size:12.5px;font-weight:600;">Stage Conversion Funnel</span>' +
              '<span class="mono" style="font-size:11px;color:var(--slate);">' + subset.length + ' rows</span>' +
            '</div>' +
            funnelHtml +
          '</div>' +
        '</div>';
    }

    studioMount.innerHTML = '' +
      '<div class="telemetry-ribbon" style="background:#080C14;">' +
        '<div class="pill-group" role="group" aria-label="CRM category">' +
          '<button type="button" class="lab-pill" data-crmcat="jobs" aria-pressed="' + (labState.crmCategory === "jobs") + '">Jobs (' + jobsCount + ')</button>' +
          '<button type="button" class="lab-pill" data-crmcat="housing" aria-pressed="' + (labState.crmCategory === "housing") + '">Housing (' + rentCount + ')</button>' +
        '</div>' +
        '<div class="pill-group" role="group" aria-label="CRM subview">' +
          '<button type="button" class="lab-pill" data-crmview="pipeline" aria-pressed="' + (labState.crmView === "pipeline") + '">Pipeline &amp; Inspector</button>' +
          '<button type="button" class="lab-pill" data-crmview="charts" aria-pressed="' + (labState.crmView === "charts") + '">Swift Charts</button>' +
        '</div>' +
      '</div>' +
      bodyHtml;

    studioMount.querySelectorAll("[data-crmcat]").forEach(function (b) {
      b.addEventListener("click", function () {
        labState.crmCategory = b.getAttribute("data-crmcat");
        renderStudio();
      });
    });
    studioMount.querySelectorAll("[data-crmview]").forEach(function (b) {
      b.addEventListener("click", function () {
        labState.crmView = b.getAttribute("data-crmview");
        renderStudio();
      });
    });
    studioMount.querySelectorAll("[data-crm-uid]").forEach(function (b) {
      b.addEventListener("click", function () {
        labState.selectedUid = b.getAttribute("data-crm-uid");
        renderStudio();
      });
    });
    studioMount.querySelectorAll("[data-set-stage]").forEach(function (b) {
      b.addEventListener("click", function () {
        if (!sel) return;
        const sql = FindingsDB.updateRow(sel.uid, { status: b.getAttribute("data-set-stage") });
        if (sql) recordLog(sql);
        renderStudio();
      });
    });
    const saveNote = document.getElementById("btn-save-crm-note");
    if (saveNote && sel) {
      saveNote.addEventListener("click", function () {
        const sql = FindingsDB.updateRow(sel.uid, { note: document.getElementById("crm-note-box").value });
        if (sql) recordLog(sql);
      });
    }
  }

  function executeLiveMcpCall(op) {
    const t0 = performance.now();
    let reply = null;
    if (op === "station_snapshot") {
      const snap = runSnapshot(false, 120);
      reply = K.formatMcpToolReply(1, snap ? snap.snapshot_text : "", false);
    } else if (op === "station_read") {
      const rd = runRead(40000);
      const formatted = "# " + rd.title + "\nSource: " + rd.url + "\nToken Reduction: " + rd.token_savings_pct.toFixed(1) + "%\n\n---\n\n" + rd.markdown;
      reply = K.formatMcpToolReply(2, formatted, false);
    } else if (op === "station_upload") {
      const up = runUpload("input[type=file]", "selibrah_cv_2026.pdf", 18432);
      reply = K.formatMcpToolReply(3, JSON.stringify({ ok: Boolean(up && up.ok), data: up }, null, 2), !(up && up.ok));
    } else if (op === "tools/list") {
      reply = { jsonrpc: "2.0", id: 4, result: { tools: K.MCP.tools } };
    } else {
      reply = {
        jsonrpc: "2.0",
        id: 0,
        result: {
          protocolVersion: K.META.mcp_protocol_version,
          serverInfo: { name: "station", version: K.META.version },
          capabilities: { tools: { listChanged: false }, resources: { subscribe: false, listChanged: false }, prompts: { listChanged: false } },
          instructions: K.MCP.instructions
        }
      };
    }
    const dt = performance.now() - t0;
    labState.mcpWireOutput = JSON.stringify(reply, null, 2);
    recordLog("MCP JSON-RPC 2.0 -> " + op + " executed against live Target Frame", dt);
  }

  function renderMcp() {
    if (!labState.mcpWireOutput) executeLiveMcpCall(labState.mcpSelectedOp);
    studioMount.innerHTML = '' +
      '<div class="telemetry-ribbon" style="background:#080C14;">' +
        '<div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap;">' +
          '<label for="mcp-op-select" style="font-size:11.5px;color:var(--slate);">Method:</label>' +
          '<select id="mcp-op-select" class="sim-select mono">' +
            '<option value="station_snapshot"' + (labState.mcpSelectedOp === "station_snapshot" ? " selected" : "") + '>tools/call · station_snapshot</option>' +
            '<option value="station_read"' + (labState.mcpSelectedOp === "station_read" ? " selected" : "") + '>tools/call · station_read</option>' +
            '<option value="station_upload"' + (labState.mcpSelectedOp === "station_upload" ? " selected" : "") + '>tools/call · station_upload</option>' +
            '<option value="tools/list"' + (labState.mcpSelectedOp === "tools/list" ? " selected" : "") + '>tools/list (11 verbatim schemas)</option>' +
            '<option value="initialize"' + (labState.mcpSelectedOp === "initialize" ? " selected" : "") + '>initialize (mcp.rs#' + esc(K.META.mcp_rs_sha256_prefix.slice(0, 8)) + ')</option>' +
          '</select>' +
          '<button type="button" class="sim-btn sim-btn-accent" id="btn-exec-mcp">▶ Execute on Target Tab</button>' +
        '</div>' +
        '<span class="mono" style="font-size:11px;color:var(--mint);">stdio JSON-RPC 2.0</span>' +
      '</div>' +
      '<div style="padding:12px;display:flex;flex-direction:column;gap:8px;flex:1;">' +
        '<pre class="chart-card mono" id="mcp-wire-pre" style="margin:0;max-height:365px;overflow:auto;font-size:11px;line-height:1.5;color:var(--mint);white-space:pre-wrap;">' +
          esc(labState.mcpWireOutput) +
        '</pre>' +
      '</div>';

    document.getElementById("mcp-op-select").addEventListener("change", function () {
      labState.mcpSelectedOp = this.value;
      executeLiveMcpCall(this.value);
      renderStudio();
    });
    document.getElementById("btn-exec-mcp").addEventListener("click", function () {
      executeLiveMcpCall(labState.mcpSelectedOp);
      renderStudio();
    });
  }

  function renderStudio() {
    if (labState.workspace === "workbench") renderWorkbench();
    else if (labState.workspace === "crm") renderCrm();
    else renderMcp();
  }

  document.querySelectorAll("[data-fixture]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      const key = btn.getAttribute("data-fixture");
      labState.fixtureKey = key;
      document.querySelectorAll("[data-fixture]").forEach(function (b) {
        b.setAttribute("aria-pressed", String(b.getAttribute("data-fixture") === key));
      });
      if (key === "custom") {
        customDrawer.removeAttribute("hidden");
        mountHtmlInTarget(customTextarea.value);
      } else {
        customDrawer.setAttribute("hidden", "");
        mountHtmlInTarget(RAW_FIXTURES[key].html);
      }
    });
  });

  document.getElementById("mount-custom-html-btn").addEventListener("click", function () {
    mountHtmlInTarget(customTextarea.value);
  });

  document.getElementById("reset-fixture-btn").addEventListener("click", function () {
    if (labState.fixtureKey === "custom") mountHtmlInTarget(customTextarea.value);
    else mountHtmlInTarget(RAW_FIXTURES[labState.fixtureKey].html);
  });

  document.querySelectorAll("[data-ws]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      labState.workspace = btn.getAttribute("data-ws");
      syncWorkspaceButtons();
      renderStudio();
    });
  });

  document.getElementById("harvest-to-crm-btn").addEventListener("click", function () {
    harvestCurrentTab();
  });

  // Expose deterministic diagnostic & differential-test API for CI verification
  window.__stationLandingLab = {
    kernelsMeta: K.META,
    getState: function () { return labState; },
    getFindingsRows: function () { return FindingsDB.rows.slice(); },
    computeHistogram: function (cat) {
      const sub = FindingsDB.rows.filter(function (r) { return r.category === cat; });
      return FindingsDB.amountHistogram(sub);
    },
    computeFunnel: function (cat) {
      const sub = FindingsDB.rows.filter(function (r) { return r.category === cat; });
      return FindingsDB.funnelCounts(sub, cat);
    },
    mountCustomHtml: async function (html) {
      labState.fixtureKey = "custom";
      customTextarea.value = html;
      customDrawer.removeAttribute("hidden");
      return await mountHtmlInTarget(html);
    },
    runSnapshot: runSnapshot,
    runRead: runRead,
    runAct: runAct,
    runUpload: runUpload,
    harvestCurrentTab: harvestCurrentTab
  };

  mountHtmlInTarget(RAW_FIXTURES["ats-job"].html);
})();
