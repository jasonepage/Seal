#!/usr/bin/env python3
"""Builds site/index.html, get.html and give.html for the 2026-11-26 redo.
Shared pieces (nav, kit picker, footer) are written once here."""
import pathlib, sys

OUT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "site")
APP = "https://apps.apple.com/app/id6779471126"
USBC = "https://buy.stripe.com/28EcMY5aT4aBfpi5Xs0Fi01"
LIGHT = "https://buy.stripe.com/aFaaEQ46PePfelebhM0Fi00"

def head(path, title, desc, og_title, og_desc, og_image):
    url = "https://sealmessenger.com" + path
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{desc}">
<link rel="canonical" href="{url}">
<meta name="theme-color" content="#16120d">
<link rel="icon" href="/favicon.ico?v=3" sizes="any">
<link rel="icon" type="image/png" href="/favicon.png?v=3">
<link rel="apple-touch-icon" href="/apple-touch-icon.png?v=3">
<link rel="stylesheet" href="/site.css?v=2">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Seal">
<meta property="og:url" content="{url}">
<meta property="og:title" content="{og_title}">
<meta property="og:description" content="{og_desc}">
<meta property="og:image" content="https://sealmessenger.com/{og_image}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{og_title}">
<meta name="twitter:description" content="{og_desc}">
<meta name="twitter:image" content="https://sealmessenger.com/{og_image}">
</head>
"""

def nav(current):
    links = [("/#how", "How it works", "home"), ("/get", "Get a kit", "get"), ("/give", "Give one", "give"), ("/open/", "Open a letter", "open")]
    cur = ' aria-current="page"'
    items = "".join('<a href="%s"%s>%s</a>' % (h, cur if k == current else "", t) for h, t, k in links)
    return f"""<a class="skip" href="#main">Skip to the page</a>
<nav class="nav" aria-label="Main">
  <div class="wrap nav-inner">
    <a class="brand" href="/" aria-label="Seal home"><img src="/img/kit/seal-icon-192.webp" alt="" width="42" height="42">Seal</a>
    <div class="nav-links">{items}<a class="nav-button" href="{APP}">Get the app</a></div>
  </div>
</nav>
"""

BADGE = f"""<a class="badge" href="{APP}" aria-label="Download Seal on the App Store"><svg viewBox="0 0 120 40" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><rect width="120" height="40" rx="6" fill="#000"/><rect x=".5" y=".5" width="119" height="39" rx="5.5" fill="none" stroke="#a6a6a6"/><g fill="#fff"><path d="M24.77 20.3a4.95 4.95 0 0 1 2.36-4.15 5.07 5.07 0 0 0-3.99-2.16c-1.68-.18-3.31 1-4.16 1-.87 0-2.19-.98-3.61-.95a5.32 5.32 0 0 0-4.47 2.73c-1.93 3.35-.49 8.27 1.36 10.98.93 1.33 2.01 2.81 3.43 2.75 1.39-.06 1.9-.88 3.58-.88 1.66 0 2.14.88 3.59.85 1.49-.02 2.43-1.33 3.32-2.67a11 11 0 0 0 1.52-3.09 4.78 4.78 0 0 1-2.93-4.41z"/><path d="M22.04 12.21a4.87 4.87 0 0 0 1.11-3.49 4.96 4.96 0 0 0-3.21 1.66 4.64 4.64 0 0 0-1.14 3.36 4.1 4.1 0 0 0 3.24-1.53z"/><text x="35" y="15.5" font-family="-apple-system,Helvetica,Arial,sans-serif" font-size="7.2" letter-spacing=".1">Download on the</text><text x="35" y="30" font-family="-apple-system,Helvetica,Arial,sans-serif" font-size="15.5" font-weight="600" letter-spacing="-.2">App Store</text></g></svg></a>"""

ORDERED = """<div id="ordered" class="ordered" role="status" hidden><strong>Order received. Thank you.</strong>Your kit ships within 3 business days to your US address, and we email you when it is on the way. Questions? Write to <a href="mailto:support@sealmessenger.com">support@sealmessenger.com</a>.<button type="button" aria-label="Close">&times;</button></div>
"""

def kits(title, sub):
    return f"""  <section id="kits" class="kits" aria-labelledby="kits-title">
    <div class="wrap">
      <div class="kits-head">
        <div><p class="label">Kits</p><h2 id="kits-title">{title}</h2></div>
        <p>{sub}</p>
      </div>
      <div class="picker"><label for="phone-model">Pick their iPhone</label><select id="phone-model"><option value="">Choose a model</option>
        <optgroup label="USB-C kit"><option value="usbc">iPhone Duo</option><option value="usbc">iPhone 18 Pro</option><option value="usbc">iPhone 18 Pro Max</option><option value="usbc">iPhone 17e</option><option value="usbc">iPhone 17</option><option value="usbc">iPhone 17 Pro</option><option value="usbc">iPhone 17 Pro Max</option><option value="usbc">iPhone Air</option><option value="usbc">iPhone 16e</option><option value="usbc">iPhone 16</option><option value="usbc">iPhone 16 Plus</option><option value="usbc">iPhone 16 Pro</option><option value="usbc">iPhone 16 Pro Max</option><option value="usbc">iPhone 15</option><option value="usbc">iPhone 15 Plus</option><option value="usbc">iPhone 15 Pro</option><option value="usbc">iPhone 15 Pro Max</option><option value="usbc">Newer than these</option></optgroup>
        <optgroup label="Lightning kit"><option value="lightning">iPhone 14</option><option value="lightning">iPhone 14 Plus</option><option value="lightning">iPhone 14 Pro</option><option value="lightning">iPhone 14 Pro Max</option><option value="lightning">iPhone SE (3rd generation)</option><option value="lightning">iPhone 13</option><option value="lightning">iPhone 13 mini</option><option value="lightning">iPhone 13 Pro</option><option value="lightning">iPhone 13 Pro Max</option><option value="lightning">iPhone 12</option><option value="lightning">iPhone 12 mini</option><option value="lightning">iPhone 12 Pro</option><option value="lightning">iPhone 12 Pro Max</option><option value="lightning">iPhone SE (2nd generation)</option><option value="lightning">iPhone 11</option><option value="lightning">iPhone 11 Pro</option><option value="lightning">iPhone 11 Pro Max</option><option value="lightning">iPhone XS</option><option value="lightning">iPhone XS Max</option><option value="lightning">iPhone XR</option></optgroup>
        <option value="old">Older than iPhone XR</option></select><p id="phone-result" class="picker-result" aria-live="polite"></p></div>
      <div class="products">
        <article id="usb-c-kit" class="product featured">
          <div class="product-badge">Most iPhones today</div>
          <img src="/img/connector-usbc-seal.svg?v=1" alt="USB-C is a small rounded oval plug." width="640" height="260">
          <div class="product-copy"><p class="fit">USB-C kit</p><h3>iPhone 15 or newer</h3><div class="price"><strong>$49</strong><span>+ $7.95 shipping</span></div><a class="buy" href="{USBC}">Buy the USB-C kit</a></div>
        </article>
        <article id="lightning-kit" class="product">
          <img src="/img/connector-lightning-seal.svg?v=1" alt="Lightning is a narrow flat plug with gold contacts." width="640" height="260">
          <div class="product-copy"><p class="fit">Lightning kit</p><h3>iPhone 14 or earlier</h3><div class="price"><strong>$119</strong><span>+ $7.95 shipping</span></div><a class="buy" href="{LIGHT}">Buy the Lightning kit</a></div>
        </article>
      </div>
      <p class="kits-note">Not sure which iPhone? Open Settings, then General, then About. US shipping only. One shipping charge per order.</p>
      <details class="why"><summary>Why does the Lightning kit cost more?</summary><p>The Lightning key has two plugs, Lightning and USB-C, so it fits every iPhone and most computers. That key costs much more to buy. The rest of the kit is the same.</p></details>
    </div>
  </section>
"""

def facts(label, title, rows, links):
    body = "".join(f"<div><strong>{q}</strong><p>{a}</p></div>" for q, a in rows)
    lk = "".join(f'<a href="{h}">{t}</a>' for h, t in links)
    return f"""  <section class="section" aria-label="{label}">
    <div class="wrap facts">
      <p class="label">{label}</p>
      <div class="fact-list">{body}</div>
      <div class="fact-links">{lk}</div>
    </div>
  </section>
"""

FOOT = f"""<footer class="foot">
  <div class="wrap foot-grid">
    <div><a class="brand" href="/"><img src="/img/kit/seal-icon-192.webp" alt="" width="42" height="42">Seal</a><p class="foot-tag">Secret letters, opened on your terms.</p></div>
    <div class="foot-links"><a href="/#how">How it works</a><a href="/get">Get a kit</a><a href="/give">Give one</a><a href="/open/">Open a letter</a><a href="/how-it-works.html">The details</a><a href="/limits.html">Limits</a><a href="/support.html">Support</a><a href="/privacy.html">Privacy</a><a href="https://github.com/jasonepage/Seal">Source</a><a href="mailto:support@sealmessenger.com">support@sealmessenger.com</a></div>
    <small>Seal cannot read your letters. The code is public.</small>
    <small class="copy">&copy; 2026 Jason Page</small>
  </div>
</footer>
"""

SCRIPT = """<script>
(function () {
  var nav = document.querySelector('.nav');
  function onScroll() { nav.classList.toggle('scrolled', window.scrollY > 16); }
  onScroll(); window.addEventListener('scroll', onScroll, { passive: true });
  var sel = document.getElementById('phone-model');
  if (sel) sel.addEventListener('change', function () {
    var v = sel.value, out = document.getElementById('phone-result');
    document.getElementById('usb-c-kit').classList.toggle('dim', v === 'lightning' || v === 'old');
    document.getElementById('lightning-kit').classList.toggle('dim', v === 'usbc' || v === 'old');
    out.textContent = v === 'usbc' ? 'That iPhone takes the USB-C kit.' : v === 'lightning' ? 'That iPhone takes the Lightning kit.' : v === 'old' ? 'That iPhone cannot run Seal. Write to support@sealmessenger.com and we will help.' : '';
  });
  var done = document.getElementById('ordered');
  if (done) {
    if (new URLSearchParams(location.search).get('ordered') === '1') done.hidden = false;
    done.querySelector('button').addEventListener('click', function () { done.hidden = true; });
  }
})();
</script>
</body>
</html>
"""

COST = "The app is free, and letters that open right away are free to seal. One payment of $29.99 in the app unlocks more ways to seal, for good. No subscription. Kits are $49 or $119, plus $7.95 shipping per order."
SHIP = "Kits ship to US addresses within 3 business days. Unopened kits can come back within 30 days for a refund. If a key arrives broken, send a photo and we send a new one free. Email <a href=\"mailto:support@sealmessenger.com\">support@sealmessenger.com</a> first."
PHONES = "No. A key opens letters on any phone or computer at sealmessenger.com/open. Writing a letter needs an iPhone with iOS 18 or newer."

# ---------- Home ----------
home = head("/", "Seal: write a secret letter",
            "Write a secret letter, seal it, and hand them the key. Only they can open it. Free on iPhone. Got a key? Open your letter on any phone or computer.",
            "Write a secret letter.", "Seal it. Hand them the key. Only they can open it.", "social-home-2.png")
home += '<body class="home">\n' + nav("home") + f"""<main id="main">
  <header class="hero">
    <div class="wrap hero-grid">
      <div>
        <p class="eyebrow">A message in a bottle</p>
        <h1>Write a secret letter.</h1>
        <p class="lead">Seal it. Hand them the key. Only they can open it.</p>
        <div class="actions">{BADGE}<a class="text-link" href="/open/">Got a key? Open your letter</a></div>
        <ul class="trust" aria-label="About Seal"><li>Free on iPhone</li><li>No subscription</li><li>Seal cannot read your letters</li></ul>
      </div>
      <div class="art">
        <span class="orbit one" aria-hidden="true"></span><span class="orbit two" aria-hidden="true"></span>
        <img class="scene" src="/img/scenes/sealed.webp" alt="A cream envelope closed with a gold wax seal." width="800" height="800">
        <img class="front key" src="/img/kit/key-390.webp" alt="A black security key with a USB-C plug." width="390" height="349">
      </div>
    </div>
  </header>

  <section id="how" class="section alt" aria-labelledby="how-title">
    <div class="wrap">
      <div class="heading"><p class="label">How it works</p><h2 id="how-title">Three steps.</h2></div>
      <div class="steps">
        <article class="step"><img src="/img/scenes/write.webp" alt="A handwritten letter with a gold wax seal." width="800" height="800" loading="lazy"><div class="step-copy"><span>1</span><h3>Write it</h3><p>Words, photos, or your voice. A few lines is plenty.</p></div></article>
        <article class="step"><img src="/img/scenes/sealed.webp" alt="The letter closed inside an envelope with a gold wax seal." width="800" height="800" loading="lazy"><div class="step-copy"><span>2</span><h3>Seal it</h3><p>Tap Seal. Now nobody else can read it. Not us, and not Apple.</p></div></article>
        <article class="step"><img src="/img/scenes/opened.webp" alt="The envelope open with the letter showing." width="800" height="800" loading="lazy"><div class="step-copy"><span>3</span><h3>Hand them the key</h3><p>They plug it in and the letter opens. Only that key works.</p></div></article>
      </div>
    </div>
  </section>

  <section class="feature" aria-labelledby="key-title">
    <div class="wrap">
      <div class="feature-card">
        <div class="feature-art"><span class="orbit one" aria-hidden="true"></span><span class="orbit two" aria-hidden="true"></span><img src="/img/key-dual.webp" alt="A black security key with a Lightning plug on one end and a USB-C plug on the other." width="1200" height="676" loading="lazy"></div>
        <div class="feature-copy"><p class="label">Got a key?</p><h2 id="key-title">Open your letter on any phone or computer.</h2><p>Plug in the key someone gave you. No app needed.</p><a class="btn btn-brass" href="/open/">Open your letter</a></div>
      </div>
    </div>
  </section>

""" + facts("Questions", "Plain facts.", [
    ("What if they lose the key?", "Set up a new key for them in Seal, then seal the letter again."),
    ("Can Seal read my letter?", "No. Your letter is locked on your phone before it leaves. Only the key you chose can open it."),
    ("Do they need an iPhone?", PHONES),
    ("What does it cost?", COST),
    ("Where do keys come from?", "Buy a kit here, or use a key you already own that can hold a secret, like a current YubiKey 5."),
], [("/how-it-works.html", "The details"), ("/limits.html", "What Seal does not promise"), ("https://github.com/jasonepage/Seal", "Source on GitHub")]) + "</main>\n\n" + FOOT + SCRIPT

# ---------- Get ----------
get = head("/get", "Pick your Seal kit: USB-C or Lightning",
           "Pick the Seal kit that plugs into their iPhone: USB-C for iPhone 15 or newer, or Lightning for iPhone 14 or earlier. The app is free.",
           "Pick a Seal kit.", "Two kits. Pick the plug that matches their iPhone: USB-C or Lightning.", "social-get.png?v=1")
get += '<body class="get">\n' + ORDERED + nav("get") + """<main id="main">
  <header class="hero">
    <div class="wrap hero-grid">
      <div>
        <p class="eyebrow">Seal kits</p>
        <h1>Pick a kit.</h1>
        <p class="lead">Each kit has a real security key, a printed setup card, and the free Seal app. No subscription.</p>
        <div class="actions"><a class="btn btn-brass btn-stack" href="#kits"><small>From $49</small>See the kits</a></div>
      </div>
      <div class="art">
        <span class="orbit one" aria-hidden="true"></span><span class="orbit two" aria-hidden="true"></span>
        <img class="scene" src="/img/inside-key.webp" alt="A black USB-C security key on cream paper." width="600" height="600">
        <img class="front card" src="/img/inside-card.webp" alt="The printed setup card with three steps." width="600" height="600">
      </div>
    </div>
  </header>

""" + kits("Which iPhone do they have?", "Pick the phone the key will plug into, and we send the right one.") + """
  <section class="section" aria-labelledby="box-title">
    <div class="wrap">
      <div class="heading"><p class="label">In the box</p><h2 id="box-title">Three things.</h2></div>
      <div class="box">
        <figure><img src="/img/inside-key.webp" alt="A black USB-C security key." width="600" height="600" loading="lazy"><figcaption><b>A security key</b><span>It opens the letters written to it. Nothing else can.</span></figcaption></figure>
        <figure><img src="/img/inside-app.webp" alt="The Seal app icon, a gold wax seal on an envelope." width="600" height="600" loading="lazy"><figcaption><b>The free Seal app</b><span>Write and seal letters on iPhone.</span></figcaption></figure>
        <figure><img src="/img/inside-card.webp" alt="The printed setup card." width="600" height="600" loading="lazy"><figcaption><b>A printed setup card</b><span>Plain steps you can follow together.</span></figcaption></figure>
      </div>
    </div>
  </section>

""" + facts("Questions", "Plain facts.", [
    ("Which kit fits?", "Look at the end of their charging cable. A small oval plug is USB-C, for iPhone 15 or newer. A thin flat plug is Lightning, for iPhone 14 or earlier."),
    ("What does it cost?", COST),
    ("Shipping and returns", SHIP),
    ("Do they need an iPhone?", PHONES),
    ("Privacy", "Stripe handles payment. Your order details are used only to ship it and help you. Keys are made by Yubico."),
], [("/give", "Giving a kit to someone?"), ("/open/#sample", "See a sample letter"), ("/privacy.html", "Privacy policy")]) + "</main>\n\n" + FOOT + SCRIPT

# ---------- Give ----------
give = head("/give", "Give someone a Seal key",
            "Write someone a secret letter and put the key in their hand, or give them a kit so they can write their own. Kits from $49.",
            "Give someone a key.", "Write them a letter and put the key in their hand.", "social-give.png?v=1")
give += '<body class="give">\n' + ORDERED + nav("give") + """<main id="main">
  <header class="hero">
    <div class="wrap hero-grid">
      <div>
        <p class="eyebrow">Give one</p>
        <h1>Give someone a key.</h1>
        <p class="lead">Write them a letter and put the key in their hand. Or give them a kit so they can write their own.</p>
        <div class="actions"><a class="btn btn-brass btn-stack" href="#kits"><small>From $49</small>See the kits</a><a class="text-link" href="/open/#sample">See a letter open</a></div>
      </div>
      <div class="art">
        <span class="orbit one" aria-hidden="true"></span><span class="orbit two" aria-hidden="true"></span>
        <img class="scene" src="/img/scenes/drawer.webp" alt="A wooden drawer holding a brass key and a folded letter." width="800" height="800">
        <img class="front key" src="/img/kit/key-390.webp" alt="A black security key with a USB-C plug." width="390" height="349">
      </div>
    </div>
  </header>

  <section class="section alt" aria-labelledby="how-title">
    <div class="wrap">
      <div class="heading"><p class="label">How to give one</p><h2 id="how-title">Three steps.</h2></div>
      <div class="steps">
        <article class="step"><img src="/img/scenes/spare.webp" alt="Two brass keys side by side." width="800" height="800" loading="lazy"><div class="step-copy"><span>1</span><h3>Pick their kit</h3><p>Match it to the iPhone they use.</p></div></article>
        <article class="step"><img src="/img/scenes/sealed.webp" alt="An envelope closed with a gold wax seal." width="800" height="800" loading="lazy"><div class="step-copy"><span>2</span><h3>Seal a letter to the key</h3><p>Plug the key into your iPhone and add it in Seal under People. Then write to them.</p></div></article>
        <article class="step"><img src="/img/scenes/opened.webp" alt="The envelope open with the letter showing." width="800" height="800" loading="lazy"><div class="step-copy"><span>3</span><h3>Hand it over</h3><p>They plug it in and read it, on any phone or computer.</p></div></article>
      </div>
    </div>
  </section>

""" + kits("Which iPhone do they have?", "Pick the phone the key will plug into, and we send the right one.") + facts("Before you give it", "Plain facts.", [
    ("Ask first", "Seal works best when they want it. It does not let you see their phone or read what they write."),
    ("Do they need an iPhone?", PHONES),
    ("Which kit fits?", "Look at the end of their charging cable. A small oval plug is USB-C, for iPhone 15 or newer. A thin flat plug is Lightning, for iPhone 14 or earlier."),
    ("What does it cost?", COST),
    ("Shipping and returns", SHIP),
], [("/get", "Buying for yourself?"), ("/open/#sample", "See a sample letter"), ("/privacy.html", "Privacy policy")]) + "</main>\n\n" + FOOT + SCRIPT

for name, html in [("index.html", home), ("get.html", get), ("give.html", give)]:
    (OUT / name).write_text(html)
    print("wrote", OUT / name, len(html))
