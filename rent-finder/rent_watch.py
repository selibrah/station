#!/usr/bin/env python3
"""Rent watcher. Reads Avito, Mubawab and Facebook group pages through station, remembers what it
has seen in SQLite, and sends new matches to Telegram with a tap-to-WhatsApp link when a phone
number is known. Python standard library only.

  python3 rent_watch.py                  one pass (launchd runs this every few minutes)
  python3 rent_watch.py --config FILE    one pass with another config
  python3 rent_watch.py --test           self-check, needs nothing running
"""
import hashlib, html, json, os, re, sqlite3, subprocess, sys, time, unicodedata, urllib.parse, urllib.request, uuid
from datetime import datetime, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
STATION = "http://127.0.0.1:19826"

# Each reader runs inside the page and returns {ads: [...]} when listings are there,
# {wait: why} while the page is still loading, or {error: why} when waiting will not help.

# Avito ships its results as JSON inside the page, so no fragile CSS selectors are needed.
AVITO_JS = """(() => {
  const n = document.getElementById("__NEXT_DATA__");
  const ads = n && JSON.parse(n.textContent).props?.pageProps?.componentProps?.ads?.ads;
  if (!ads) return {wait: document.title};
  return {ads: ads.map(a => {
    const p = k => (a.params?.secondary?.find(x => x.key === k) || {}).value ?? null;
    return {id: String(a.listId || a.id), title: a.subject || a.title || "", price: a.price?.value ?? null,
            area: a.location || "", rooms: p("rooms"), size: p("size"), phone: a.seller?.phone?.number || "",
            seller: a.seller?.type || "", url: a.href || "", text: a.description || ""};
  })};
})()"""

# Mubawab has no phone number on its result cards, so its alerts carry no WhatsApp link.
MUBAWAB_JS = """(() => {
  const cards = [...document.querySelectorAll(".listingBox[linkref]")];
  if (!cards.length) return {wait: document.title};
  const t = (c, s) => (c.querySelector(s)?.innerText || "").replace(/\\s+/g, " ").trim();
  return {ads: cards.map(c => {
    const feats = [...c.querySelectorAll(".adDetailFeature")].map(f => f.innerText.trim()).join(" | ");
    const num = re => (feats.match(re) || [])[1] || null;
    return {id: c.querySelector(".adId")?.value || c.getAttribute("linkref"), title: t(c, ".listingTit"),
            price: parseInt(t(c, ".priceTag").replace(/\\D/g, "")) || null, area: t(c, ".listingH3"),
            rooms: num(/(\\d+)\\s*Ch/i), size: num(/(\\d+)\\s*m²/), phone: "", seller: "",
            url: c.getAttribute("linkref"), text: t(c, ".adFeatures") + " " + t(c, ".listingP")};
  })};
})()"""

# Facebook drops posts from the page as you scroll past them and only loads more in a tab that is
# on screen, so this reader is called repeatedly in station's first tab: each call keeps what is
# visible, scrolls down once, and after ROUNDS calls hands back everything it kept.
# RW_MARK and RW_PATH are filled in by read_page.
FACEBOOK_JS = """(async () => {
  const ROUNDS = 6;
  if (document.querySelector('input[name="pass"]')) return {error: "Facebook is signed out in station's browser"};
  if (!location.pathname.startsWith(RW_PATH)) return {wait: "still opening the group"};
  const feed = document.querySelector('[role="feed"]');
  if (!feed) return {wait: document.title};
  const st = (window["RW_MARK"] = window["RW_MARK"] || {posts: {}, rounds: 0});
  const more = /…?\\s*(See more|See less|Voir plus|En voir plus|Voir moins|عرض المزيد|عرض أقل)$/;  // the label left at the end of a post's text
  // The only thing this reader ever clicks: a button that says exactly "See more", inside a post's own
  // text. Every other button on the page acts on the account (like, comment, share), so never widen this.
  const expand = () => feed.querySelectorAll('[data-ad-rendering-role="story_message"] [role="button"]').forEach(b => { if (/^(See more|Voir plus|En voir plus|عرض المزيد)$/.test(b.innerText.trim())) b.click(); });
  expand();
  // A post's date link only holds a placeholder until the pointer passes over it or it takes focus.
  feed.querySelectorAll('a[role="link"][href^="?"], a[role="link"]:not([href])').forEach(a => {
    const r = a.getBoundingClientRect(), o = {bubbles: true, cancelable: true, clientX: r.x + 2, clientY: r.y + 2, view: window};
    ["pointerover", "pointerenter", "pointermove"].forEach(e => a.dispatchEvent(new PointerEvent(e, o)));
    ["mouseover", "mouseenter", "mousemove"].forEach(e => a.dispatchEvent(new MouseEvent(e, o)));
    a.focus();
  });
  await new Promise(r => setTimeout(r, 1200));
  expand();  // again, for posts that appeared during the wait
  await new Promise(r => setTimeout(r, 400));
  const group = document.title.replace(/\\s*\\|\\s*Facebook.*$/, "").replace(/^\\(\\d+\\+?\\)\\s*/, "");
  for (const m of feed.querySelectorAll('[data-ad-rendering-role="story_message"]')) {
    let unit = m;
    while (unit.parentElement && unit.parentElement !== feed) unit = unit.parentElement;
    const link = unit.querySelector('a[href*="/groups/"][href*="/posts/"], a[href*="/permalink/"]');
    const text = m.innerText.trim().replace(more, "").trim();
    // The cut and the expanded form of a post share a key: same opening, or one opens the other.
    // ponytail: a post kept cut in one pass and expanded in the next can alert twice; store the link id if that bites.
    const head = text.replace(/\\s+/g, "").slice(0, 80);
    const key = Object.keys(st.posts).find(k => k.startsWith(head) || head.startsWith(k)) || head;
    const old = st.posts[key];
    const url = link ? link.href.split("?")[0] : (old && old.url) || location.origin + location.pathname;
    if (text) st.posts[key] = {text: old && old.text.length > text.length ? old.text : text, area: group, url};
  }
  window.scrollTo(0, document.body.scrollHeight);
  if (++st.rounds < ROUNDS) return {wait: "read " + Object.keys(st.posts).length + " posts so far"};
  const ads = Object.values(st.posts);
  return ads.length ? {ads} : {error: "the group feed showed no posts (is the first tab of station's window still the selected one?)"};
})()"""

# (source, config key, reader, read in station's first tab instead of a background tab)
SOURCES = (("avito", "avito_searches", AVITO_JS, False),
           ("mubawab", "mubawab_searches", MUBAWAB_JS, False),
           ("facebook", "facebook_groups", FACEBOOK_JS, True))


# ---- station -------------------------------------------------------------------------------

def station(path, body=None):
    token = open(os.path.expanduser("~/.flossi/station.token")).read().strip()
    req = urllib.request.Request(STATION + path, data=None if body is None else json.dumps(body).encode(),
                                 headers={"X-Station-Token": token, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def station_up():
    try:
        return station("/ping").get("ok", False)
    except OSError:
        return False


def ensure_station(cfg):
    if station_up():
        return
    cmd = cfg.get("start_station")
    if not cmd:
        raise RuntimeError("station is not running")
    # Detached, so it outlives this run. The launchd job sets AbandonProcessGroup for the same reason.
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    for _ in range(90):  # a cold start opens Chrome first; right after a stop that took over 30 s
        time.sleep(1)
        if station_up():
            return
    raise RuntimeError("station did not start within 90 s")


def ensure_tab(cfg, get=urllib.request.urlopen):
    """station hangs on every command once its browser has no tab left (someone closed the blank
    window), so every source "timed out" until a tab existed again. Opens one; True if it had to."""
    cmd = cfg.get("start_station") or []
    port = cmd[cmd.index("--cdp-port") + 1] if "--cdp-port" in cmd else "9223"
    base = "http://127.0.0.1:%s/json/" % port
    try:
        if any(t.get("type") == "page" for t in json.load(get(base + "list", timeout=5))):
            return False
        get(urllib.request.Request(base + "new?about:blank", method="PUT"), timeout=10)
        return True
    except OSError:
        return False  # ponytail: best effort; with the browser itself gone the pass fails and reports as before


def read_page(url, js, main_tab=False):
    # ponytail: station picks a tab by address substring, so a throwaway marker in the fragment
    # names ours. Give /command a target_id option if two tools ever fight over tabs.
    mark = "rw-" + uuid.uuid4().hex[:10]
    js = js.replace("RW_MARK", mark).replace("RW_PATH", json.dumps(urllib.parse.urlparse(url).path.rstrip("/")))
    command, tab_id = {"code": js}, None
    if main_tab:
        # Tells the page it has focus, which keeps Facebook loading while you work in another app.
        station("/command", {"action": "raw", "method": "Emulation.setFocusEmulationEnabled", "params": {"enabled": True}})
        station("/navigate", {"url": url})
    else:
        # A background tab, because /tabs/new pulls the browser in front of whatever you are doing.
        made = station("/command", {"action": "raw", "method": "Target.createTarget",
                                    "params": {"url": url + "#" + mark, "background": True}})
        if not made.get("ok"):
            raise RuntimeError("could not open a tab: %s" % made.get("error"))
        tab_id = made["data"]["result"]["targetId"]
        command["session"] = mark
    try:
        last = "no answer"
        for _ in range(30):
            time.sleep(1)
            r = station("/command", command)
            data = r.get("data") or {}
            if data.get("ads"):
                return data["ads"]
            if data.get("error"):
                raise RuntimeError(data["error"])
            last = r.get("error") or data.get("wait") or last
        # An empty page is treated as a failure: searches this broad never have zero results,
        # so it means a block, a CAPTCHA or a changed layout.
        raise RuntimeError("no listings after 30 s (%s)" % last)
    finally:
        if tab_id:
            station("/tabs/close", {"target_id": tab_id})


def search_url(source, url, want):
    if source == "mubawab" and ":prm" not in url:
        # Mubawab filters by price in the address; fill it from the rules so there is one place to edit.
        if "price_min" in want:
            url += ":prmn:%d" % want["price_min"]
        if "price_max" in want:
            url += ":prmx:%d" % want["price_max"]
    if source == "facebook" and "?" not in url:
        url = url.rstrip("/") + "/?sorting_setting=CHRONOLOGICAL"  # newest posts first
    return url


# "7500Dhwtsp": Facebook glues lines together, so only "mad" (madame) has to end the word.
PRICE = re.compile(r"(\d[\d .,]{2,8})\s*(?:dhs?|درهم|mad(?![a-z]))")
FLAT = re.compile(r"\b[2-9] ?(?:chambres|غرف)|\b\d{2,3} ?m[2²]")  # several bedrooms or a floor area: a whole flat
PHONE = re.compile(r"(?:(?:\+|00)212[\s.-]*|0)[67](?:[\s.-]*\d){8}")


def finish(source, ad):
    """Fills in what a reader could not: the source, a safe link, and for Facebook posts the
    fields that have to be dug out of free text."""
    ad["source"] = source
    ad["url"] = urllib.parse.quote(ad["url"], safe=":/?&=#%")  # raw accents break Telegram buttons
    if source == "facebook":
        text = ad["text"]
        price = PRICE.search(text.lower())
        price = int(re.sub(r"\D", "", price.group(1))) if price else None
        phone = PHONE.search(text)
        # The id is a hash of the opening words, so the same post copied into several groups alerts once.
        ad.update(id=hashlib.sha1(re.sub(r"\s+", "", plain(text))[:80].encode()).hexdigest()[:16],
                  title=(text.splitlines() or [""])[0][:80], rooms=None, size=None, seller="",
                  price=price if price and 500 <= price <= 100000 else None,
                  phone=phone.group(0) if phone else "", loose=True)
    return ad


# ---- rules ---------------------------------------------------------------------------------

def plain(s):
    """Lower case, accents removed: 'Maârif' -> 'maarif'."""
    s = (s or "").lower().replace("\u2019", "'")  # phones type a curly apostrophe: d\u2019une -> d'une
    return "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c))


def matches(ad, want):
    """True when the ad passes every rule that is set. Rules left out (or empty) are ignored.
    A "loose" ad is free text (a Facebook post): a price or room count it does not state is not
    held against it, and neither is an area: most room offers on Facebook name none, so far-away
    places are kept out with exclude words instead. Area words are looked for in the ad's area and text."""
    loose = ad.get("loose", False)
    price, text = ad.get("price"), plain(ad.get("title", "") + " " + ad.get("text", ""))
    if ("price_min" in want or "price_max" in want) and price is None and not loose:
        return False
    if price is not None and not (want.get("price_min", 0) <= price <= want.get("price_max", float("inf"))):
        return False
    if loose and price is None and FLAT.search(text):
        return False  # ponytail: a whole flat that hides its price; with a price in budget it is a room in a shared flat
    if "rooms_min" in want and not (loose and ad.get("rooms") is None):
        try:
            if int(ad.get("rooms")) < want["rooms_min"]:
                return False
        except (TypeError, ValueError):
            return False
    where = plain(ad.get("area")) + " " + text  # "near the tram" is in the description, not the area field
    # "posts_any_area" is set on the main rules only, never on "urgent": near Abdelmoumen has to be said.
    if want.get("areas") and not (loose and want.get("posts_any_area")) and not any(plain(a) in where for a in want["areas"]):
        return False
    if want.get("must_words") and not any(plain(w) in text for w in want["must_words"]):
        return False
    if any(plain(w) in text for w in want.get("exclude_words", [])):
        return False
    if want.get("private_only") and ad.get("seller") != "PRIVATE":
        return False
    return True


def wa_link(phone, text):
    """wa.me link for a Moroccan mobile number, or None for anything else (landlines have no WhatsApp)."""
    d = "".join(c for c in phone or "" if c.isdigit())
    if d.startswith("00"):
        d = d[2:]
    elif d.startswith("0"):
        d = "212" + d[1:]
    if len(d) != 12 or d[:4] not in ("2126", "2127"):
        return None
    return "https://wa.me/%s?text=%s" % (d, urllib.parse.quote(text))


def whatsapp(cfg, ad):
    """The tap-to-send link for an ad, with the config's message filled in. You press send, not the tool."""
    return wa_link(ad.get("phone"), cfg["message"].format(title=ad["title"], price=ad["price"] or "?",
                                                         area=ad.get("area", ""), source=ad["source"].capitalize()))


# ---- messages ------------------------------------------------------------------------------

def money(n):
    return "%s DH" % format(n, ",").replace(",", " ") if n is not None else "prix non indiqué"


def facts(ad):
    bits = [money(ad["price"])]
    if ad.get("rooms"):
        bits.append("%s ch" % ad["rooms"])
    if ad.get("size"):
        bits.append("%s m²" % ad["size"])
    bits.append(ad.get("area") or "?")
    return " · ".join(bits)


def alert(cfg, ad, old_price):
    urgent = bool(cfg.get("urgent")) and matches(ad, cfg["urgent"])
    head = "📉 Price drop: %s → %s" % (money(old_price), money(ad["price"])) if old_price else "🏠 New on %s" % ad["source"].capitalize()
    lines = ["%s%s" % ("🚨 URGENT · " if urgent else "", head), "<b>%s</b>" % html.escape(ad["title"]), html.escape(facts(ad))]
    who = {"PRIVATE": "Particulier", "STORE": "Agence"}.get(ad.get("seller"), "")
    if who or ad.get("phone"):
        lines.append(" · ".join(x for x in (who, html.escape(ad.get("phone") or "")) if x))
    if ad.get("loose"):  # a Facebook post has no real title, so show the start of what it says
        lines.append(html.escape(ad["text"][:500]))
    buttons = [("Open listing", ad["url"])]
    link = whatsapp(cfg, ad)
    if link:
        buttons.append(("WhatsApp", link))
    notify(cfg, "\n".join(lines), buttons, quiet=not urgent)


def digest(title, ads):
    """One message listing many ads, cut to fit Telegram's 4096-character limit."""
    lines = [title]
    for i, ad in enumerate(ads):
        line = '• %s — <a href="%s">%s</a>' % (html.escape(facts(ad)), html.escape(ad["url"], quote=True), html.escape(ad["title"]))
        if sum(len(l) + 1 for l in lines) + len(line) > 3900:
            lines.append("… and %d more" % (len(ads) - i))
            break
        lines.append(line)
    return "\n".join(lines)


def notify(cfg, text, buttons=(), quiet=False):
    token, chat = cfg.get("telegram_token"), cfg.get("telegram_chat_id")
    if not (token and chat):
        print(text, *("  [%s] %s" % b for b in buttons), "", sep="\n")  # no Telegram set up: print instead
        return
    body = {"chat_id": chat, "text": text, "parse_mode": "HTML", "disable_web_page_preview": True,
            "disable_notification": quiet}
    if buttons:
        body["reply_markup"] = {"inline_keyboard": [[{"text": t, "url": u} for t, u in buttons]]}
    req = urllib.request.Request("https://api.telegram.org/bot%s/sendMessage" % token,
                                 data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=20).close()


# ---- memory --------------------------------------------------------------------------------

def open_db(path):
    db = sqlite3.connect(path)
    db.executescript("""
        CREATE TABLE IF NOT EXISTS listings(
            source TEXT, id TEXT, title TEXT, price INTEGER, area TEXT, rooms TEXT, size TEXT,
            phone TEXT, url TEXT, first_seen TEXT, PRIMARY KEY(source, id));
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);""")
    # Added later, so older memories gain them here. last_seen is the last pass in which the ad still
    # matched the rules; status, note and status_at belong to the dashboard (who was contacted, when).
    have = {r[1] for r in db.execute("PRAGMA table_info(listings)")}
    for col in ("text", "seller", "last_seen", "status", "note", "status_at"):
        if col not in have:
            db.execute("ALTER TABLE listings ADD COLUMN %s TEXT" % col)
    return db


def meta(db, key, value=None):
    if value is None:
        row = db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return row[0] if row else None
    db.execute("INSERT OR REPLACE INTO meta VALUES(?,?)", (key, str(value)))
    db.commit()


def remember(db, ad):
    now = datetime.now().isoformat(timespec="seconds")
    db.execute("""INSERT INTO listings(source, id, title, price, area, rooms, size, phone, url, first_seen, text, seller, last_seen)
                  VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                  ON CONFLICT(source, id) DO UPDATE SET price=excluded.price, last_seen=excluded.last_seen""",
               (ad["source"], ad["id"], ad["title"], ad["price"], ad["area"], ad["rooms"], ad["size"], ad["phone"],
                ad["url"], now, ad.get("text", ""), ad.get("seller", ""), now))
    db.commit()


# ---- one pass ------------------------------------------------------------------------------

def this_pass(urls, per, start):
    """The searches to read now and where the next pass starts. With "<source>_per_pass" set, each
    pass reads that many and carries on where the last one stopped, so a long list of Facebook
    groups does not mean loading all of them on a signed-in account every time."""
    if not per or per >= len(urls):
        return urls, 0
    start %= len(urls)
    return (urls + urls)[start:start + per], (start + per) % len(urls)


def run(cfg, db):
    """Reads every source, alerts on what is new. Returns (number reported, list of source errors).
    One source failing never holds back the others."""
    ensure_station(cfg)
    if ensure_tab(cfg):
        time.sleep(2)  # let station notice the new tab
    news, errors = {}, []  # (source, id) -> (ad, old price or None); a dict so an ad found twice alerts once
    seeding = set()        # sources seen for the first time: one summary instead of dozens of alerts
    for source, key, js, main_tab in SOURCES:
        if not cfg.get(key):
            continue
        # ponytail: one pace per source ("facebook_every_minutes"), not per search. Facebook is read
        # on a signed-in account, so it goes slower. The 2 minutes of slack absorb a late launchd start.
        every = cfg.get(source + "_every_minutes", 0)
        if every and time.time() - float(meta(db, "last:" + source) or 0) < every * 60 - 120:
            continue
        if db.execute("SELECT COUNT(*) FROM listings WHERE source=?", (source,)).fetchone()[0] == 0:
            seeding.add(source)
        try:
            urls, nxt = this_pass(cfg[key], cfg.get(source + "_per_pass"), int(meta(db, "next:" + source) or 0))
            meta(db, "next:" + source, nxt)
            failed = []
            for url in urls:
                try:
                    ads = read_page(search_url(source, url, cfg["want"]), js, main_tab)
                except Exception as e:  # one slow or closed group must not cost the others
                    failed.append("%s: %s" % (url.rstrip("/").rsplit("/", 1)[-1], e))
                    continue
                for ad in ads:
                    ad = finish(source, ad)
                    if not (matches(ad, cfg["want"]) and matches(ad, cfg.get(source + "_want", {}))):
                        continue
                    row = db.execute("SELECT price FROM listings WHERE source=? AND id=?", (source, ad["id"])).fetchone()
                    if row is None:
                        news[(source, ad["id"])] = (ad, None)
                        continue
                    if ad["price"] and row[0] and ad["price"] < row[0]:
                        news[(source, ad["id"])] = (ad, row[0])
                    # Still there and still matching: the dashboard hides listings that stop being stamped.
                    db.execute("UPDATE listings SET last_seen=?, text=?, seller=? WHERE source=? AND id=?",
                               (datetime.now().isoformat(timespec="seconds"), ad.get("text", ""), ad.get("seller", ""), source, ad["id"]))
            if failed and len(failed) == len(urls):
                raise RuntimeError(failed[-1])
            for f in failed:
                print("%s  skipped %s %s" % (datetime.now().strftime("%Y-%m-%d %H:%M"), source, f), file=sys.stderr)
            meta(db, "fails:" + source, 0)
            meta(db, "last:" + source, time.time())
        except Exception as e:  # blocked, signed out, changed layout: note it and carry on with the rest
            fails = int(meta(db, "fails:" + source) or 0) + 1
            meta(db, "fails:" + source, fails)
            errors.append("%s (%d in a row): %s" % (source, fails, e))
            if fails == 3:
                try:
                    notify(cfg, "⚠️ %s has failed 3 passes in a row.\n%s" % (source.capitalize(), html.escape(str(e))))
                except Exception:
                    pass

    for source in sorted(seeding):
        ads = [ad for (s, _), (ad, _) in news.items() if s == source]
        if ads:
            notify(cfg, digest("👀 Now watching %s. %d listings match right now:" % (source.capitalize(), len(ads)), ads))
        for ad in ads:
            remember(db, ad)
    for (source, _), (ad, old_price) in news.items():
        if source not in seeding:
            alert(cfg, ad, old_price)
            remember(db, ad)  # only after the alert went out, so a failed send is retried next pass

    today = datetime.now().strftime("%Y-%m-%d")
    if meta(db, "last_report") != today and datetime.now().hour >= cfg.get("report_hour", 20):
        since = (datetime.now() - timedelta(days=1)).isoformat(timespec="seconds")
        rows = db.execute("SELECT title, price, area, rooms, size, url FROM listings WHERE first_seen>=? ORDER BY price", (since,))
        ads = [dict(zip(("title", "price", "area", "rooms", "size", "url"), r)) for r in rows]
        notify(cfg, digest("🗓 Daily report: %d new matching listings in the last 24 h" % len(ads), ads), quiet=True)
        meta(db, "last_report", today)
    return len(news), errors


def main():
    path = sys.argv[sys.argv.index("--config") + 1] if "--config" in sys.argv else os.path.join(HERE, "config.json")
    cfg = json.load(open(path, encoding="utf-8"))
    db = open_db(os.path.expanduser(cfg.get("db") or os.path.join(HERE, "seen.db")))
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M")
    try:
        count, errors = run(cfg, db)
        meta(db, "fails", 0)
    except Exception as e:  # nothing could run at all: station down, Telegram unreachable
        fails = int(meta(db, "fails") or 0) + 1
        meta(db, "fails", fails)
        print("%s  FAILED (%d in a row): %s" % (stamp, fails, e), file=sys.stderr)
        if fails == 3:
            try:
                notify(cfg, "⚠️ Rent watcher has failed 3 passes in a row.\n%s" % html.escape(str(e)))
            except Exception:
                pass
        sys.exit(1)
    for e in errors:
        print("%s  FAILED %s" % (stamp, e), file=sys.stderr)
    print("%s  ok, %d to report" % (stamp, count), flush=True)
    if cfg.get("publish"):  # hosted copy of the dashboard; remove "publish" from config.json to stop it
        try:
            import dashboard
            dashboard.publish(cfg, db, dashboard.read_log())
        except Exception as e:  # a failed upload never fails the pass; the next pass tries again
            print("%s  hosted dashboard not updated: %s" % (stamp, e), file=sys.stderr)
    sys.exit(1 if errors else 0)


def test():
    ad = {"id": "1", "source": "avito", "title": "Appartement meublé", "text": "Maârif, sans vis-à-vis", "price": 5200,
          "area": "Casablanca, Maârif Extension", "rooms": "2", "size": 80, "phone": "06 55-33 85 80", "seller": "PRIVATE",
          "url": "https://a.ma/x?a=1&b=2"}
    assert PRICE.search("parking7500dhwtsp 0600").group(1) == "7500" and not PRICE.search("0612345678 madame")
    flat = {"title": "", "text": "Appartement 3 chambres meublé", "loose": True, "price": None}
    assert not matches(flat, {}) and matches(dict(flat, price=1200), {}) and matches(dict(flat, text="Chambre meublée"), {})
    assert this_pass(list("abcde"), 2, 4) == (["e", "a"], 1) and this_pass(["a", "b"], None, 5) == (["a", "b"], 0)
    assert plain("Maârif") == "maarif" and plain("d\u2019une") == "d'une"
    offer = {"title": "Chambre meublée disponible", "text": "Chambre meublée disponible maintenant", "price": None, "area": "Colocation Casa"}
    assert matches(dict(offer, loose=True), {"areas": ["Maarif"], "posts_any_area": True}) and not matches(offer, {"areas": ["Maarif"], "posts_any_area": True})
    assert not matches(dict(offer, loose=True), {"areas": ["Maarif"]})  # the "urgent" rule: a post that names no area is not near  # only free text may skip the area
    assert not matches(dict(offer, loose=True, text="Chambre à Sidi Maarouf"), {"areas": ["Maarif"], "posts_any_area": True, "exclude_words": ["Sidi Maarouf"]})

    import io  # a browser with no tab left gets one opened on its own port; one with a tab is left alone
    for tabs, opened in (([{"type": "service_worker"}], True), ([{"type": "page"}], False)):
        asked = []
        fake = lambda r, timeout: (asked.append(r if isinstance(r, str) else r.get_method() + " " + r.full_url), io.StringIO(json.dumps(tabs)))[1]
        assert ensure_tab({"start_station": ["station", "--cdp-port", "9"]}, fake) is opened
        assert asked[0] == "http://127.0.0.1:9/json/list" and (asked[1:] == ["PUT http://127.0.0.1:9/json/new?about:blank"]) is opened
    assert matches(ad, {})
    assert matches(ad, {"price_max": 6000, "rooms_min": 2, "areas": ["maarif"], "must_words": ["meuble"], "private_only": True})
    assert not matches(ad, {"price_max": 5000})
    assert not matches(ad, {"price_min": 6000})
    assert not matches(ad, {"rooms_min": 3})
    assert not matches(ad, {"areas": ["Bourgogne"]})
    assert matches(dict(ad, text="Chambre proche tramway"), {"areas": ["Bourgogne", "tram"]})  # area words match the text too
    assert not matches(ad, {"exclude_words": ["vis-a-vis"]})
    assert not matches(dict(ad, seller="STORE"), {"private_only": True})
    assert not matches(dict(ad, price=None), {"price_max": 9000})
    assert not matches(dict(ad, rooms=None), {"rooms_min": 1})
    assert wa_link(ad["phone"], "Bonjour à vous") == "https://wa.me/212655338580?text=Bonjour%20%C3%A0%20vous"
    assert wa_link("+212 7 00 00 00 00", "x").startswith("https://wa.me/212700000000?")
    assert wa_link("0522123456", "x") is None and wa_link("", "x") is None
    assert money(12500) == "12 500 DH"
    big = digest("t", [ad] * 200)
    assert len(big) < 4096 and "more" in big and "a=1&amp;b=2" in big

    assert search_url("mubawab", "https://m.ma/x:o:n", {"price_min": 2500, "price_max": 7000}) == "https://m.ma/x:o:n:prmn:2500:prmx:7000"
    assert search_url("mubawab", "https://m.ma/x:prmx:9000", {"price_max": 7000}) == "https://m.ma/x:prmx:9000"
    assert search_url("facebook", "https://www.facebook.com/groups/123/", {}) == "https://www.facebook.com/groups/123/?sorting_setting=CHRONOLOGICAL"
    assert search_url("avito", "https://a.ma/x", {"price_max": 1}) == "https://a.ma/x"

    post = finish("facebook", {"text": "Studio à louer Maârif\nPrix 4 500 dh/mois, tél +212 6 61-22.33 44", "area": "Location Casa", "url": "https://www.facebook.com/groups/1/posts/2/"})
    assert (post["price"], post["phone"], post["title"]) == (4500, "+212 6 61-22.33 44", "Studio à louer Maârif")
    assert wa_link(post["phone"], "x").startswith("https://wa.me/212661223344?")
    long_post = finish("facebook", dict(post, text=post["text"] * 3))
    assert finish("facebook", dict(post, text=post["text"] * 3 + " ...suite"))["id"] == long_post["id"]  # same opening, same post
    assert long_post["id"] != post["id"]
    assert matches(post, {"price_max": 7000, "rooms_min": 2, "areas": ["maarif"]})   # rooms unknown is tolerated
    assert not matches(post, {"price_max": 4000})
    vague = finish("facebook", {"text": "Je cherche un appartement à Oulfa, budget 3000dh", "area": "g", "url": "https://f.b/x"})
    assert vague["price"] == 3000 and not matches(vague, {"exclude_words": ["je cherche"]})
    assert finish("facebook", {"text": "Bel appart, appelez 0522123456", "area": "g", "url": "https://f.b/x"})["phone"] == ""
    assert finish("facebook", {"text": "2 chambres salon", "area": "g", "url": "https://f.b/x"})["price"] is None
    assert matches(finish("facebook", {"text": "chambre meublée", "area": "g", "url": "https://f.b/x"}), {"price_max": 7000})

    db = open_db(":memory:")
    remember(db, ad)
    remember(db, dict(ad, price=4900))
    remember(db, dict(ad, source="mubawab"))
    assert db.execute("SELECT COUNT(*), MIN(price) FROM listings").fetchone() == (2, 4900)
    assert db.execute("SELECT text, seller, last_seen IS NOT NULL, status FROM listings WHERE source='avito'").fetchone() == (ad["text"], "PRIVATE", 1, None)
    assert whatsapp({"message": "{title} {price} {source}"}, ad).endswith("?text=Appartement%20meubl%C3%A9%205200%20Avito")
    assert meta(db, "fails") is None
    meta(db, "last:facebook", time.time())  # read a moment ago: an hourly source is skipped, so nothing is fetched
    globals()["ensure_station"] = lambda cfg: None  # the self-check must pass with station off
    assert run({"facebook_groups": ["https://f.b/g"], "facebook_every_minutes": 60, "want": {}, "report_hour": 99}, db) == (0, [])
    meta(db, "fails", 2)
    assert meta(db, "fails") == "2"
    print("self-check passed")


if __name__ == "__main__":
    test() if "--test" in sys.argv else main()
