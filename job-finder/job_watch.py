#!/usr/bin/env python3
"""Universal Job & Lead Watcher for Station.
Drives Station (127.0.0.1:19826) in background tabs to extract job postings and leads from
LinkedIn, Hacker News Jobs, Welcome to the Jungle, Wellfound, Greenhouse, Lever, or any board,
scores each role 0-100 against config.json, and saves to ~/.flossi/agent_home/memory/findings.db
for Station Studio's native Findings, CRM & Swift Charts view.

  python3 job_watch.py                one pass across configured job boards
  python3 job_watch.py --url URL      scan a single job board or career page URL
  python3 job_watch.py --test         self-check, needs nothing running
"""
import hashlib, json, os, re, sqlite3, sys, time, urllib.parse, urllib.request
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
STATION = os.environ.get("STATION_URL", "http://127.0.0.1:19826")
DEFAULT_DB = os.path.expanduser("~/.flossi/agent_home/memory/findings.db")

# Universal multi-board JS extractor executed inside Chrome over CDP.
EXTRACT_JOBS_JS = r"""(() => {
  const host = location.hostname.toLowerCase();
  const clean = (s, n = 220) => (s || '').replace(/\s+/g, ' ').trim().slice(0, n);
  const items = [];

  // 1. LinkedIn Jobs cards
  if (host.includes('linkedin.com')) {
    const cards = document.querySelectorAll('.job-card-container, .jobs-search-results__list-item, .base-card');
    for (const c of cards) {
      const a = c.querySelector('a[href*="/jobs/view/"], a.base-card__full-link');
      const title = clean(c.querySelector('.job-card-list__title, .base-search-card__title, strong')?.innerText || a?.innerText);
      const company = clean(c.querySelector('.job-card-container__primary-description, .base-search-card__subtitle, .artdeco-entity-lockup__subtitle')?.innerText, 90);
      const loc = clean(c.querySelector('.job-card-container__metadata-item, .job-search-card__location, .artdeco-entity-lockup__caption')?.innerText, 90);
      const snippet = clean(c.innerText, 400);
      if (title && a?.href) {
        const url = a.href.split('?')[0];
        items.push({ id: url, title, subtitle: [company, loc].filter(Boolean).join(' · '), url, text: snippet });
      }
    }
    if (items.length) return { items };
  }

  // 2. Hacker News Jobs (news.ycombinator.com/jobs)
  if (host.includes('ycombinator.com')) {
    for (const row of document.querySelectorAll('tr.athing')) {
      const a = row.querySelector('.titleline > a');
      if (!a) continue;
      const title = clean(a.innerText, 180);
      const href = a.href;
      const company = title.split(/\s+(?:is hiring|hiring|\(|—|-)/i)[0]?.slice(0, 60) || 'YC Startup';
      items.push({ id: row.id || href, title, subtitle: company, url: href, text: title });
    }
    if (items.length) return { items };
  }

  // 3. Generic ATS & Career Boards (Greenhouse, Lever, Ashby, Welcome to the Jungle, Wellfound, Indeed)
  const seenHref = new Set();
  for (const a of document.querySelectorAll('a[href]')) {
    const href = a.href || '';
    if (!href.startsWith('http') || seenHref.has(href)) continue;
    const looksLikeJob = /\/(jobs?|careers?|positions?|roles?|openings?|view)\b/i.test(href)
      || a.closest('[class*="job" i], [class*="posting" i], [data-testid*="job" i]');
    if (!looksLikeJob) continue;
    const card = a.closest('li, article, tr, [class*="card" i], [class*="job" i]') || a;
    const title = clean(a.innerText || card.querySelector('h2, h3, h4')?.innerText, 140);
    if (title.length < 6 || /^(apply|learn more|read more|jobs|careers|sign in)$/i.test(title)) continue;
    seenHref.add(href);
    const snippet = clean(card.innerText, 360);
    items.push({ id: href.split('?')[0], title, subtitle: host.replace(/^www\./, ''), url: href, text: snippet });
    if (items.length >= 60) break;
  }

  return { items };
})()"""

SALARY_RE = re.compile(r"\$\s*(\d{2,3})(?:[, ]?000|k\b)", re.I)
MODE_RE = re.compile(r"\b(remote|hybrid|on-?site|télétravail|hybride)\b", re.I)


def open_findings_db(path=DEFAULT_DB):
    if path != ":memory:" and os.path.dirname(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
    db = sqlite3.connect(path)
    db.executescript("""
        CREATE TABLE IF NOT EXISTS findings (
            uid TEXT PRIMARY KEY,
            category TEXT NOT NULL,
            job_id TEXT DEFAULT '',
            source TEXT NOT NULL,
            external_id TEXT NOT NULL,
            title TEXT NOT NULL,
            subtitle TEXT DEFAULT '',
            amount INTEGER,
            currency TEXT DEFAULT '$',
            score INTEGER DEFAULT 50,
            tags_json TEXT DEFAULT '[]',
            url TEXT DEFAULT '',
            contact_url TEXT DEFAULT '',
            contact_label TEXT DEFAULT '',
            snippet TEXT DEFAULT '',
            status TEXT DEFAULT 'new',
            note TEXT DEFAULT '',
            first_seen TEXT NOT NULL,
            last_seen TEXT NOT NULL,
            status_at TEXT DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS idx_findings_cat ON findings(category);
    """)
    return db


def parse_salary_usd(text):
    m = SALARY_RE.search(text or "")
    if not m:
        return None
    val = int(m.group(1))
    return val * 1000 if val < 1000 else val


def score_job(item, want):
    blob = ((item.get("title") or "") + " " + (item.get("subtitle") or "") + " " + (item.get("text") or "")).lower()
    for bad in want.get("exclude_words", []):
        if bad.lower() in blob:
            return -1, []
    must = want.get("must_words", [])
    if must and not any(w.lower() in blob for w in must):
        return -1, []

    pts = 50
    tags = []
    mode_m = MODE_RE.search(blob)
    if mode_m:
        mode = mode_m.group(1).capitalize()
        tags.append(mode)
        if "remote" in mode.lower() or "télétravail" in mode.lower():
            pts += 15

    matched_skills = []
    for kw in want.get("boost_words", []):
        if kw.lower() in blob:
            matched_skills.append(kw)
    pts += min(30, len(matched_skills) * 8)
    tags.extend(matched_skills[:4])

    sal = parse_salary_usd(blob)
    if sal:
        pts += 5
        tags.append(f"${sal // 1000}k+")

    return min(100, pts), tags


def upsert_finding(db, row):
    now = datetime.now().isoformat(timespec="seconds")
    cur = db.execute("SELECT uid FROM findings WHERE uid=?", (row["uid"],)).fetchone()
    is_new = cur is None
    db.execute(
        """INSERT INTO findings (
               uid, category, job_id, source, external_id, title, subtitle,
               amount, currency, score, tags_json, url, contact_url, contact_label,
               snippet, status, note, first_seen, last_seen, status_at
           ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'new','',?,?, '')
           ON CONFLICT(uid) DO UPDATE SET
               score=excluded.score,
               amount=COALESCE(excluded.amount, findings.amount),
               tags_json=excluded.tags_json,
               snippet=excluded.snippet,
               last_seen=excluded.last_seen""",
        (
            row["uid"], row["category"], row.get("job_id", ""), row["source"], row["external_id"],
            row["title"], row.get("subtitle", ""), row.get("amount"), row.get("currency", "$"),
            row["score"], json.dumps(row.get("tags", [])), row.get("url", ""),
            row.get("contact_url", ""), row.get("contact_label", ""), row.get("snippet", ""),
            now, now,
        ),
    )
    db.commit()
    return is_new


def station_post(path, body):
    tok_path = os.environ.get("STATION_TOKEN_FILE", os.path.expanduser("~/.flossi/station.token"))
    token = open(tok_path).read().strip()
    req = urllib.request.Request(
        STATION + path,
        data=json.dumps(body).encode(),
        headers={"X-Station-Token": token, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=35) as r:
        return json.load(r)


def scan_board(source, category, url, want, db):
    created = station_post("/tabs/new", {"url": url, "background": True})
    if not created.get("ok"):
        raise RuntimeError(created.get("error") or "Failed to open background tab")
    tab_id = created["tab"]["id"]
    added = 0
    kept = 0
    try:
        for _ in range(14):
            time.sleep(1.0)
            res = station_post("/command", {"action": "exec", "target_id": tab_id, "code": EXTRACT_JOBS_JS})
            items = (res.get("data") or {}).get("items") or []
            if items:
                for raw in items:
                    pts, tags = score_job(raw, want)
                    if pts < 0:
                        continue
                    ext_id = hashlib.sha1(str(raw["id"]).encode()).hexdigest()[:16]
                    uid = f"{category}:{source}:{ext_id}"
                    sal = parse_salary_usd((raw.get("title") or "") + " " + (raw.get("text") or ""))
                    row = {
                        "uid": uid,
                        "category": category,
                        "source": source,
                        "external_id": ext_id,
                        "title": raw["title"],
                        "subtitle": raw.get("subtitle", ""),
                        "amount": sal,
                        "currency": "$",
                        "score": pts,
                        "tags": tags,
                        "url": raw.get("url", ""),
                        "contact_url": raw.get("url", ""),
                        "contact_label": "Apply",
                        "snippet": raw.get("text", ""),
                    }
                    if upsert_finding(db, row):
                        added += 1
                    kept += 1
                break
        return added, kept
    finally:
        station_post("/tabs/close", {"target_id": tab_id})


def main():
    cfg_path = os.path.join(HERE, "config.json")
    cfg = json.load(open(cfg_path, encoding="utf-8")) if os.path.exists(cfg_path) else {"searches": [], "want": {}}
    if "--url" in sys.argv:
        u = sys.argv[sys.argv.index("--url") + 1]
        host = urllib.parse.urlparse(u).hostname or "web"
        searches = [{"source": host.replace("www.", "").split(".")[0], "category": "jobs", "url": u}]
    else:
        searches = cfg.get("searches", [])

    db = open_findings_db()
    total_new = 0
    total_seen = 0
    for s in searches:
        try:
            n_new, n_kept = scan_board(s["source"], s.get("category", "jobs"), s["url"], cfg.get("want", {}), db)
            total_new += n_new
            total_seen += n_kept
        except Exception as e:
            print(f"skipped {s['source']}: {e}", file=sys.stderr)
    print(f"ok, {total_new} new ({total_seen} matched) saved to findings.db")


def test():
    db = open_findings_db(":memory:")
    want = {"boost_words": ["rust", "remote", "ai"], "exclude_words": ["unpaid"]}
    pts, tags = score_job({"title": "Senior Rust AI Engineer (Remote)", "subtitle": "Acme", "text": "$185k - $220k"}, want)
    assert pts >= 80 and "Remote" in tags and "$185k+" in tags
    bad_pts, _ = score_job({"title": "Unpaid Intern", "text": ""}, want)
    assert bad_pts == -1
    assert parse_salary_usd("Comp: $160k base") == 160000
    is_new1 = upsert_finding(db, {
        "uid": "jobs:hn:1", "category": "jobs", "source": "hn", "external_id": "1",
        "title": "Rust Systems Engineer", "subtitle": "Acme · Remote", "amount": 180000,
        "currency": "$", "score": 92, "tags": ["Remote", "rust"], "url": "https://example.com/1",
        "snippet": "Build fast tools"
    })
    is_new2 = upsert_finding(db, {
        "uid": "jobs:hn:1", "category": "jobs", "source": "hn", "external_id": "1",
        "title": "Rust Systems Engineer", "subtitle": "Acme · Remote", "amount": 180000,
        "currency": "$", "score": 95, "tags": ["Remote", "rust"], "url": "https://example.com/1",
        "snippet": "Build fast tools"
    })
    assert is_new1 and not is_new2
    row = db.execute("SELECT score, status FROM findings WHERE uid='jobs:hn:1'").fetchone()
    assert row == (95, "new")
    print("job_watch self-check passed")


if __name__ == "__main__":
    test() if "--test" in sys.argv else main()
