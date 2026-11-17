#!/usr/bin/env python3
"""Rent dashboard. A small website on this Mac only, over the watcher's memory (seen.db): the best
offers, who you have contacted, statistics, the search rules and the watcher's health.
Python standard library only. The page itself is dashboard.html, next to this file.

  python3 dashboard.py             serve http://127.0.0.1:8787
  python3 dashboard.py --jobs      what is running in the background
  python3 dashboard.py --stop      stop the watcher and its browser (--start turns them back on)
  python3 dashboard.py --publish   upload a read-only copy to Vercel, if anything changed
  python3 dashboard.py --test      self-check, needs nothing running
"""
import functools, hashlib, json, os, re, shutil, signal, socket, sqlite3, statistics, subprocess, sys, threading, time
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import rent_watch as rw

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = 8787
STATUSES = ("new", "contacted", "replied", "visit", "dropped")
LIVE_HOURS = 72      # a listing the watcher has not matched for this long is shown as "no longer matching"
FOLLOW_UP_HOURS = 24  # contacted this long ago without a reply: the page suggests a follow-up


def district(ad, cfg):
    """The neighbourhood an ad is counted under: a place name from the rules when one is found, so
    'Casablanca, Sidi Bernoussi' (Avito) and 'Bernoussi, Casablanca' (Mubawab) land together."""
    loose = ad["source"] == "facebook"  # a post's area field holds the group's name, so read its text
    where = rw.plain(ad["title"] + " " + ad["text"] if loose else ad["area"])
    # ponytail: place names in the config start with a capital or are Arabic; transit words ("tram",
    # "bus") do not. Split the config into two lists if that convention ever breaks.
    for name in cfg.get("want", {}).get("areas", []):
        if (name[:1].isupper() or not name.isascii()) and rw.plain(name) in where:
            return name
    if loose:  # Facebook posts are mostly Arabic: the same areas under their other spellings
        for other, name in also().items():
            if other in where:
                return name
    return "Not stated" if loose else re.sub(r"(?i)casablanca|,", " ", ad["area"] or "").strip() or "Casablanca"


@functools.lru_cache(None)
def also():
    """Other spellings of a measured area -> its name: 'البرنوصي' -> 'Bernoussi' (places.json, "also")."""
    try:
        return {rw.plain(k): v for k, v in json.load(open(os.path.join(HERE, "places.json"), encoding="utf-8")).get("also", {}).items()}
    except OSError:
        return {}


def load_places():
    """Area -> distance and transport to Abdelmoumen, from places.json (measured once on OpenStreetMap).
    ponytail: one figure per area, taken at its centre, not per address; geocode each ad if that is too coarse."""
    try:
        places = json.load(open(os.path.join(HERE, "places.json"), encoding="utf-8"))["places"]
    except OSError:
        return {}
    return {rw.plain(k): v for k, v in places.items()}


def score(ad, near, wa, cfg, now, km=None):
    """(0-100, reasons), higher is better.
    ponytail: a fixed-weight sum: place 60 near Abdelmoumen, otherwise 10 to 24 by distance; price 25,
    WhatsApp 10, fresh 5. So a room near Abdelmoumen always outranks one that is not, and among the
    rest the closer one leads. Tune the weights here if the ranking feels wrong; it knows nothing
    about photos, furniture or the landlord."""
    want, price, why = cfg.get("want", {}), ad["price"], []
    points = 60 if near else 10 if km is None else 10 + 14 * max(0, 1 - km / 15)
    if near:
        why.append("Near Abdelmoumen")
    lo, hi = want.get("price_min", 0), want.get("price_max")
    if price is None:
        points += 8
    elif not hi or hi <= lo:
        points += 12
    else:
        part = min(1, max(0, (hi - price) / (hi - lo)))
        points += 25 * part
        if part >= 0.6:
            why.append("Low price")
    if wa:
        points += 10
        why.append("WhatsApp ready")
    if now - datetime.fromisoformat(ad["first_seen"]) < timedelta(hours=48):
        points += 5
        why.append("New")
    return round(points), why


def snapshot(cfg, db, now=None, log="", places=None):
    """Everything the page shows, as one JSON-ready dict. Never includes the Telegram token."""
    now = now or datetime.now()
    places = load_places() if places is None else places
    want = cfg.get("want", {})
    db.row_factory = sqlite3.Row
    listings = []
    for row in db.execute("SELECT * FROM listings"):
        ad = dict(row, loose=row["source"] == "facebook", text=row["text"] or "")
        near = bool(cfg.get("urgent")) and rw.matches(ad, cfg["urgent"])
        wa = rw.whatsapp(cfg, ad) if cfg.get("message") else None
        area = district(ad, cfg)
        trip = places.get(rw.plain(area), {})
        points, why = score(ad, near, wa, cfg, now, trip.get("km"))
        status = ad["status"] or "new"
        listings.append({
            "source": ad["source"], "id": ad["id"], "title": ad["title"], "price": ad["price"],
            "district": area, "km": trip.get("km"), "way": trip.get("way"), "minutes": trip.get("minutes"), "direct": trip.get("direct"), "rooms": ad["rooms"], "size": ad["size"], "phone": ad["phone"],
            # Scraped text: only a real web address may become a link on the page.
            "url": ad["url"] if re.match(r"https?://", ad["url"] or "") else "",
            "snippet": ad["text"][:300], "seller": ad["seller"] or "",
            "first_seen": ad["first_seen"], "last_seen": ad["last_seen"],
            # Still matching: stamped by a recent pass, and passing the rules as they are now, so a rule
            # you tighten hides its listings at once instead of when the stamp runs out.
            "live": bool(ad["last_seen"]) and now - datetime.fromisoformat(ad["last_seen"]) < timedelta(hours=LIVE_HOURS)
                    and rw.matches(ad, want) and rw.matches(ad, cfg.get(ad["source"] + "_want", {})),
            "near": near, "wa": wa, "score": points, "why": why,
            "status": status, "status_at": ad["status_at"], "note": ad["note"] or "",
            "follow_up": status == "contacted" and bool(ad["status_at"])
                         and now - datetime.fromisoformat(ad["status_at"]) > timedelta(hours=FOLLOW_UP_HOURS),
        })
    listings.sort(key=lambda a: (-a["score"], a["price"] or 10 ** 9))

    live = [a for a in listings if a["live"]]
    prices = sorted(a["price"] for a in live if a["price"] is not None)
    areas = {}
    for a in live:
        areas.setdefault(a["district"], []).append(a["price"])
    by_area = [{"name": k, "count": len(v), "median": median([p for p in v if p is not None]),
                "km": places.get(rw.plain(k), {}).get("km")} for k, v in areas.items()]
    days = [(now - timedelta(days=d)).strftime("%Y-%m-%d") for d in range(13, -1, -1)]
    stats = {
        "live": len(live), "gone": len(listings) - len(live),
        "new_24h": sum(1 for a in live if now - datetime.fromisoformat(a["first_seen"]) < timedelta(hours=24)),
        "near": sum(1 for a in live if a["near"]),
        "median": median(prices), "lowest": prices[0] if prices else None,
        "by_area": sorted(by_area, key=lambda x: (-x["count"], x["name"])),
        "by_source": [{"name": s, "count": sum(1 for a in live if a["source"] == s)} for s, *_ in rw.SOURCES],
        "by_day": [{"day": d, "count": sum(1 for a in listings if a["first_seen"][:10] == d)} for d in days],
        "prices": bins(prices),
        "funnel": {s: sum(1 for a in listings if a["status"] == s) for s in STATUSES},
        "follow_up": sum(1 for a in listings if a["follow_up"]),
    }

    def stamp(source):
        at = rw.meta(db, "last:" + source)
        return datetime.fromtimestamp(float(at)).isoformat(timespec="seconds") if at else None

    passes = [m.groups() for m in re.finditer(r"(?m)^(\d{4}-\d\d-\d\d \d\d:\d\d)  (ok|FAILED)(.*)$", log)]
    day_ago = (now - timedelta(days=1)).strftime("%Y-%m-%d %H:%M")
    health = {
        "sources": [{"name": s, "searches": len(cfg[key]), "last": stamp(s), "fails": int(rw.meta(db, "fails:" + s) or 0),
                     "every": cfg.get(s + "_every_minutes") or 15} for s, key, *_ in rw.SOURCES if cfg.get(key)],
        "last_pass": {"at": passes[-1][0].replace(" ", "T"), "ok": passes[-1][1] == "ok"} if passes else None,
        "passes_24h": sum(1 for at, *_ in passes if at >= day_ago),
        "failed_24h": sum(1 for at, state, _ in passes if at >= day_ago and state == "FAILED"),
        "problems": [("%s %s%s" % p).replace(cfg.get("telegram_token") or "\0", "•••")[:300] for p in passes if p[1] == "FAILED"][-5:],
    }
    near_names = cfg.get("urgent", {}).get("areas", [])
    rules = {
        "price_min": want.get("price_min"), "price_max": want.get("price_max"),
        "near": near_names, "areas": [a for a in want.get("areas", []) if a not in near_names],
        "exclude_words": want.get("exclude_words", []), "must_words": want.get("must_words", []),
        "facebook_want": cfg.get("facebook_want", {}),
        "searches": {s: cfg[key] for s, key, *_ in rw.SOURCES if cfg.get(key)},
        "report_hour": cfg.get("report_hour", 20), "message": cfg.get("message", ""),
        "telegram": bool(cfg.get("telegram_token") and cfg.get("telegram_chat_id")),
    }
    # Every timestamp here is this Mac's wall-clock time; utc_offset (minutes) lets a phone in another time zone read them right.
    # ponytail: today's offset for all of them, so times from before a clock change are an hour off; store UTC if that matters.
    return {"now": now.isoformat(timespec="seconds"), "utc_offset": int(now.astimezone().utcoffset().total_seconds() // 60), "statuses": STATUSES, "listings": listings,
            "stats": stats, "health": health, "rules": rules}


def median(values):
    return round(statistics.median(values)) if values else None


def bins(prices):
    """Price histogram: 100 DH steps, doubled until at most 12 bars remain."""
    if not prices:
        return []
    lo, step = prices[0] // 100 * 100, 100
    while (prices[-1] - lo) // step >= 12:
        step *= 2
    out = [{"from": lo + i * step, "to": lo + (i + 1) * step - 1, "count": 0} for i in range((prices[-1] - lo) // step + 1)]
    for p in prices:
        out[(p - lo) // step]["count"] += 1
    return out


def set_status(db, source, id, status=None, note=None, now=None):
    """Records where you stand with one listing. Returns False when the listing or the status is unknown."""
    if status is not None and status not in STATUSES:
        return False
    sets, args = [], []
    if status is not None:
        sets += ["status=?", "status_at=?"]
        args += [status, (now or datetime.now()).isoformat(timespec="seconds")]
    if note is not None:
        sets.append("note=?")
        args.append(str(note)[:500])
    if not sets:
        return False
    done = db.execute("UPDATE listings SET %s WHERE source=? AND id=?" % ", ".join(sets), args + [source, id]).rowcount
    db.commit()
    return done == 1


# ---- background jobs -----------------------------------------------------------------------

AGENT = "com.flossi.rent-watch"
PLIST = os.path.expanduser("~/Library/LaunchAgents/%s.plist" % AGENT)


def browser_pids(cfg, run=subprocess.run):
    """station and the Chrome window it drives, found by the exact command the watcher starts them
    with. Chrome has to carry this profile's folder and port, so your own Chrome can never match."""
    cmd = cfg.get("start_station") or []
    if "--profile-name" not in cmd or "--cdp-port" not in cmd:
        return []
    lit = lambda t: re.sub(r"[.^$*+?()\[\]{}|\\]", r"\\\g<0>", t)
    name, port = cmd[cmd.index("--profile-name") + 1], cmd[cmd.index("--cdp-port") + 1]
    patterns = ["^" + lit(" ".join(cmd)) + "( |$)",
                r"MacOS/Google Chrome --.*user-data-dir=[^ ]*/\.flossi/profiles/%s .*remote-debugging-port=%s( |$)" % (lit(name), lit(port))]
    return [int(p) for pat in patterns for p in run(["pgrep", "-f", pat], capture_output=True, text=True).stdout.split()]


def jobs(cfg, run=subprocess.run):
    """Everything the rent finder keeps running, for the Jobs tab and `--jobs`."""
    agent = run(["launchctl", "print", "gui/%d/%s" % (os.getuid(), AGENT)], capture_output=True, text=True)
    watching, browser = agent.returncode == 0, bool(browser_pids(cfg, run))
    try:
        socket.create_connection(("127.0.0.1", PORT), 0.5).close()
        page = True
    except OSError:
        page = False
    return [
        {"id": "watcher", "name": "Watcher", "on": watching, "can": True,
         "state": "Reading the sites right now" if "state = running" in agent.stdout else "On, every 15 minutes" if watching else "Stopped",
         "what": "Reads Avito, Mubawab and Facebook, sends the Telegram alerts and the daily report, updates the hosted copy."},
        {"id": "browser", "name": "Watcher's browser", "on": browser, "can": True,
         "state": "Running" if browser else "Stopped until the next pass" if watching else "Stopped",
         "what": "station and its own Chrome window, signed in to Facebook. While the watcher is on, it starts this again on its next pass."},
        {"id": "dashboard", "name": "Dashboard", "on": page, "can": page,
         "state": "Running at 127.0.0.1:%d" % PORT if page else "Stopped",
         "what": "This page on the Mac. Stopping it changes nothing for the watcher or the alerts."},
        {"id": "hosted", "name": "Hosted copy", "on": bool(cfg.get("publish")), "can": False,
         "state": "Not set up" if not cfg.get("publish") else "Online, updated by the watcher" if watching else "Online, no longer updated",
         "what": "The read-only copy on the web. It stays online when everything else is stopped; it just stops changing."},
    ]


def job(cfg, id, do, run=subprocess.run, kill=os.kill):
    """Stops or starts one job, or the watcher and its browser together ("all"). Nothing is deleted:
    the listings, the rules and the Facebook sign-in stay where they are."""
    gui = "gui/%d" % os.getuid()
    if id in ("watcher", "all"):
        if do == "stop":  # "disable" keeps it off after a restart of the Mac too, until Start
            run(["launchctl", "bootout", gui + "/" + AGENT], capture_output=True)
            run(["launchctl", "disable", gui + "/" + AGENT], capture_output=True)
        else:
            run(["launchctl", "enable", gui + "/" + AGENT], capture_output=True)
            if run(["launchctl", "print", gui + "/" + AGENT], capture_output=True).returncode:  # not loaded yet
                done = run(["launchctl", "bootstrap", gui, PLIST], capture_output=True, text=True)
                if done.returncode:
                    raise RuntimeError("could not start the watcher: " + (done.stderr or "").strip()[-200:])
    if id in ("browser", "all"):
        if do == "stop":
            for pid in browser_pids(cfg, run):
                try:
                    kill(pid, signal.SIGTERM)  # a normal quit: Chrome saves its session first
                except ProcessLookupError:
                    pass
        elif id == "browser":  # with "all" the watcher's first pass starts it
            rw.ensure_station(cfg)
    if id == "dashboard" and do == "stop":
        threading.Timer(0.5, os._exit, [0]).start()  # after the answer has gone out


# ---- hosted copy ---------------------------------------------------------------------------

VERCEL_JSON = {"headers": [{"source": "/(.*)", "headers": [
    {"key": "X-Robots-Tag", "value": "noindex, nofollow"},
    {"key": "Referrer-Policy", "value": "no-referrer"},
    {"key": "Cache-Control", "value": "no-store"},
    {"key": "Content-Security-Policy", "value": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'"}]}]}


def publish(cfg, db, log="", site=None, run=subprocess.run, now=None):
    """Uploads a read-only copy of the dashboard to Vercel. Returns "published" or "unchanged".
    Only the site/ folder is ever uploaded: the page, and the data under a name nobody can guess
    (config "publish.key"), so the address alone shows nothing. Never this folder, which holds the
    bot token. Uploads when the listings, statuses or rules changed, or after "every_hours" as a
    sign of life, so a day costs a handful of deployments, not one per pass."""
    pub, now = cfg["publish"], now or datetime.now()
    # "jobs" is the state at this pass; it is not part of what counts as a change.
    data = dict(snapshot(cfg, db, now, log), readonly=True, refresh_hours=pub.get("every_hours", 3), jobs=jobs(cfg))
    # last_seen moves on every pass, so it is left out of what counts as a change.
    core = json.dumps([[{k: v for k, v in a.items() if k != "last_seen"} for a in data["listings"]], data["rules"],
                       [s["fails"] for s in data["health"]["sources"]]], sort_keys=True)
    page = open(os.path.join(HERE, "dashboard.html"), encoding="utf-8").read()  # a changed page counts as a change too
    mark = hashlib.sha256((core + page + pub["key"]).encode()).hexdigest()
    last = float(rw.meta(db, "published:at") or 0)
    if mark == rw.meta(db, "published:mark") and now.timestamp() - last < pub.get("every_hours", 3) * 3600:
        return "unchanged"
    site = site or os.path.join(HERE, "site")
    shutil.rmtree(os.path.join(site, "d"), ignore_errors=True)  # a changed key must not leave the old file behind
    os.makedirs(os.path.join(site, "d"))
    shutil.copy(os.path.join(HERE, "dashboard.html"), os.path.join(site, "index.html"))
    json.dump(data, open(os.path.join(site, "d", pub["key"] + ".json"), "w", encoding="utf-8"), ensure_ascii=False)
    json.dump(VERCEL_JSON, open(os.path.join(site, "vercel.json"), "w"))
    open(os.path.join(site, "robots.txt"), "w").write("User-agent: *\nDisallow: /\n")
    # launchd starts jobs with a bare PATH, and vercel is a node script: "path" is where node lives.
    env = dict(os.environ, PATH=pub.get("path", "") + os.pathsep + os.environ.get("PATH", ""))
    done = run([pub.get("vercel", "vercel"), "deploy", "--prod", "--yes"], cwd=site, env=env, capture_output=True, text=True, timeout=300)
    if done.returncode:
        raise RuntimeError("vercel deploy failed: " + (done.stderr or done.stdout or "").strip()[-300:])
    rw.meta(db, "published:mark", mark)
    rw.meta(db, "published:at", now.timestamp())
    return "published"


def read_log():
    try:
        return open(os.path.join(HERE, "watch.log"), encoding="utf-8", errors="replace").read()[-200000:]
    except OSError:
        return ""


# ---- web server ----------------------------------------------------------------------------

def load():
    cfg = json.load(open(os.path.join(HERE, "config.json"), encoding="utf-8"))  # re-read, so rule edits show at once
    return cfg, rw.open_db(os.path.expanduser(cfg.get("db") or os.path.join(HERE, "seen.db")))


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body, kind="application/json"):
        body = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", kind + "; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        # The page shows text scraped from the web: it may load nothing from, and send nothing to, anywhere else.
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'")
        self.end_headers()
        self.wfile.write(body)

    def local(self):
        # Refuses requests that reach this port under another site's name (DNS rebinding).
        return self.headers.get("Host") in ("127.0.0.1:%d" % PORT, "localhost:%d" % PORT)

    def do_GET(self):
        if not self.local():
            return self.reply(403, {"error": "local only"})
        if self.path == "/":
            return self.reply(200, open(os.path.join(HERE, "dashboard.html"), "rb").read(), "text/html")
        if self.path == "/api/data":
            cfg, db = load()
            return self.reply(200, dict(snapshot(cfg, db, log=read_log()), jobs=jobs(cfg)))
        self.reply(404, {"error": "not found"})

    def do_POST(self):
        # Asking for JSON keeps other websites from posting here: a browser will not send it cross-site unasked.
        if not self.local() or self.headers.get("Content-Type") != "application/json" or self.path not in ("/api/status", "/api/job"):
            return self.reply(403, {"error": "not allowed"})
        try:
            body = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length") or 0), 10000)))
            if self.path == "/api/job":
                if body["id"] not in ("watcher", "browser", "dashboard", "all") or body["do"] not in ("stop", "start"):
                    raise ValueError
                try:
                    job(load()[0], body["id"], body["do"])
                except (RuntimeError, OSError) as e:
                    return self.reply(500, {"ok": False, "error": str(e)})
                time.sleep(1.5)  # so the reload that follows shows the new state
                return self.reply(200, {"ok": True})
            ok = set_status(load()[1], str(body["source"]), str(body["id"]), body.get("status"), body.get("note"))
        except (ValueError, KeyError, TypeError):
            ok = False
        self.reply(200 if ok else 400, {"ok": ok})

    def log_message(self, *args):
        pass


def test():
    cfg = {"want": {"price_min": 900, "price_max": 1400, "areas": ["Maarif", "Bernoussi", "tram"]},
           "urgent": {"areas": ["Maarif"]}, "message": "Bonjour {title}", "telegram_token": "SECRET", "telegram_chat_id": "1",
           "avito_searches": ["https://a.ma/s"]}
    now = datetime(2026, 11, 12, 12, 0)
    db = rw.open_db(":memory:")
    base = {"rooms": "1", "size": None, "seller": "PRIVATE", "text": ""}
    rw.remember(db, dict(base, source="avito", id="1", title="Chambre", price=900, area="Casablanca, Sidi Bernoussi", phone="0655338580", url="https://a.ma/1"))
    rw.remember(db, dict(base, source="avito", id="2", title="Chambre Maarif", price=1400, area="Casablanca, Maarif", phone="", url="javascript:alert(1)"))
    rw.remember(db, dict(base, source="mubawab", id="3", title="Chambre tram", price=1000, area="Bernoussi, Casablanca", phone="", url="https://m.ma/3"))
    rw.remember(db, dict(base, source="facebook", id="4", title="Coloc à Maârif 1200 dh", price=1200, area="Groupe Coloc", phone="", url="https://f.b/4", text="Coloc à Maârif 1200 dh"))
    db.execute("UPDATE listings SET first_seen=?, last_seen=?", ("2026-11-12T07:00:00",) * 2)
    db.execute("UPDATE listings SET last_seen=NULL WHERE id='3'")  # never matched again: no longer live
    rw.meta(db, "last:avito", now.timestamp())
    log = "2026-11-12 11:37  ok, 0 to report\n2026-11-12 11:52  FAILED avito (1 in a row): boom SECRET\n2026-11-12 11:52  ok, 1 to report\n"

    s = snapshot(cfg, db, now, log, places={})
    by_id = {a["id"]: a for a in s["listings"]}
    assert [a["id"] for a in s["listings"]] == ["4", "2", "1", "3"]          # near Abdelmoumen beats cheaper but far
    assert by_id["1"]["score"] == 10 + 25 + 10 + 5 and by_id["2"]["score"] == 60 + 0 + 0 + 5
    assert by_id["1"]["district"] == by_id["3"]["district"] == "Bernoussi" and by_id["4"]["district"] == "Maarif"
    assert by_id["1"]["wa"].startswith("https://wa.me/212655338580?") and by_id["2"]["wa"] is None
    assert by_id["2"]["url"] == "" and by_id["1"]["url"] == "https://a.ma/1"  # a scripted link never reaches the page
    assert by_id["4"]["near"] and not by_id["1"]["near"] and not by_id["3"]["live"]
    stricter = snapshot(dict(cfg, want=dict(cfg["want"], exclude_words=["chambre maarif"])), db, now)
    assert [a["id"] for a in stricter["listings"] if not a["live"]] == ["2", "3"]  # a tightened rule hides its listings at once
    st = s["stats"]
    assert (st["live"], st["gone"], st["near"], st["new_24h"], st["median"], st["lowest"]) == (3, 1, 2, 3, 1200, 900)
    assert st["by_area"][0] == {"name": "Maarif", "count": 2, "median": 1300, "km": None}
    trip = {"km": 12.8, "way": "Tram T2 direct", "minutes": 65, "direct": True}
    far = next(a for a in snapshot(cfg, db, now, places={"bernoussi": trip})["listings"] if a["id"] == "1")
    assert (far["km"], far["way"], far["minutes"]) == (12.8, "Tram T2 direct", 65) and far["score"] == round(10 + 14 * (1 - 12.8 / 15) + 25 + 10 + 5)
    post = {"source": "facebook", "title": "", "text": "بيت الزوفري البرنوصي 900 dh", "area": "a group"}
    assert district(post, {}) == "Bernoussi" and all(rw.plain(v) in load_places() for v in also().values())
    assert load_places()["sidi bernoussi"]["km"] > load_places()["al fida"]["km"] > load_places()["maarif"]["km"]  # the shipped table is sane
    assert [b["count"] for b in st["prices"]] == [1, 0, 0, 1, 0, 1] and st["by_day"][-1] == {"day": "2026-11-12", "count": 4}
    assert bins([900, 5000])[-1]["to"] >= 5000 and len(bins([900, 5000])) <= 12 and bins([]) == []
    h = s["health"]
    assert h["last_pass"] == {"at": "2026-11-12T11:52", "ok": True} and (h["passes_24h"], h["failed_24h"]) == (3, 1)
    assert h["sources"] == [{"name": "avito", "searches": 1, "last": "2026-11-12T12:00:00", "fails": 0, "every": 15}]
    assert "SECRET" not in json.dumps(s) and "•••" in h["problems"][0]      # the bot token never leaves the server

    assert set_status(db, "avito", "1", "contacted", now=now - timedelta(hours=30)) and set_status(db, "avito", "1", note="rappeler lundi")
    assert not set_status(db, "avito", "1", "bogus") and not set_status(db, "avito", "nope", "replied") and not set_status(db, "avito", "1")
    s = snapshot(cfg, db, now)
    a = next(a for a in s["listings"] if a["id"] == "1")
    assert (a["status"], a["note"], a["follow_up"]) == ("contacted", "rappeler lundi", True)
    assert s["stats"]["funnel"] == {"new": 3, "contacted": 1, "replied": 0, "visit": 0, "dropped": 0} and s["stats"]["follow_up"] == 1

    import tempfile, types
    calls, site = [], tempfile.mkdtemp()
    run = lambda cmd, **kw: calls.append((cmd, kw["cwd"])) or types.SimpleNamespace(returncode=0, stdout="", stderr="")
    cfg["publish"] = {"key": "k" * 32, "vercel": "/bin/vercel"}
    assert publish(cfg, db, site=site, run=run, now=now) == "published" and calls == [(["/bin/vercel", "deploy", "--prod", "--yes"], site)]
    assert sorted(os.listdir(site)) == ["d", "index.html", "robots.txt", "vercel.json"] and os.listdir(os.path.join(site, "d")) == ["k" * 32 + ".json"]
    held = json.load(open(os.path.join(site, "d", "k" * 32 + ".json"), encoding="utf-8"))
    assert held["readonly"] and len(held["listings"]) == 4
    everything = "".join(open(os.path.join(root, f), encoding="utf-8").read() for root, _, files in os.walk(site) for f in files)
    assert "SECRET" not in everything and "Chambre Maarif" not in open(os.path.join(site, "index.html"), encoding="utf-8").read()
    assert publish(cfg, db, site=site, run=run, now=now + timedelta(minutes=15)) == "unchanged" and len(calls) == 1
    assert set_status(db, "avito", "2", "replied") and publish(cfg, db, site=site, run=run, now=now + timedelta(minutes=30)) == "published"
    assert publish(cfg, db, site=site, run=run, now=now + timedelta(hours=4)) == "published" and len(calls) == 3  # the sign of life
    failing = lambda cmd, **kw: types.SimpleNamespace(returncode=1, stdout="", stderr="no network")
    try:
        publish(cfg, db, site=site, run=failing, now=now + timedelta(hours=9))
        raise AssertionError("a failed upload must not pass silently")
    except RuntimeError as e:
        assert "no network" in str(e)
    assert publish(cfg, db, site=site, run=run, now=now + timedelta(hours=9)) == "published"  # and is retried
    shutil.rmtree(site)
    calls, killed = [], []

    def fake(cmd, **kw):
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 0, "111\n" if cmd[0] == "pgrep" else "", "")
    mine = {"start_station": ["/x/station", "--profile-name", "rent", "--cdp-port", "9223"]}
    job(mine, "all", "stop", run=fake, kill=lambda pid, sig: killed.append(pid))
    assert [c[1] for c in calls if c[0] == "launchctl"] == ["bootout", "disable"] and killed == [111, 111]
    assert all("rent" in c[2] and "9223" in c[2] for c in calls if c[0] == "pgrep")  # only this profile's processes
    assert browser_pids({}, fake) == [] and re.search(calls[-1][2], "/A/Google Chrome.app/Contents/MacOS/Google Chrome --app=x --user-data-dir=/U/.flossi/profiles/rent --remote-debugging-port=9223 --no-first-run")
    assert not re.search(calls[-1][2], "/A/Google Chrome.app/Contents/MacOS/Google Chrome --remote-debugging-port=9222")  # your own Chrome
    print("self-check passed")


if __name__ == "__main__":
    if "--test" in sys.argv:
        test()
    elif {"--jobs", "--stop", "--start"} & set(sys.argv):  # the Jobs tab without the page
        cfg = load()[0]
        if "--jobs" not in sys.argv:
            job(cfg, "all", "stop" if "--stop" in sys.argv else "start")
            time.sleep(2)
        for j in jobs(cfg):
            print("%-18s %s" % (j["name"], j["state"]))
    elif "--publish" in sys.argv:
        cfg, db = load()
        print(publish(cfg, db, read_log()))
    else:
        print("Rent dashboard: http://127.0.0.1:%d" % PORT, flush=True)
        ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
