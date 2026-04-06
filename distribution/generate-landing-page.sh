#!/bin/bash
# Generates the landing page (index.html) from README.md
# Requires: cmark-gfm (brew install cmark-gfm)
# Input:  README.md (project root)
# Output: stdout (pipe to index.html)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
README="$PROJECT_ROOT/README.md"

if ! command -v cmark-gfm &>/dev/null; then
    echo "Error: cmark-gfm is required. Install with: brew install cmark-gfm" >&2
    exit 1
fi

# Convert README markdown → HTML fragment, with GFM extensions (tables)
BODY=$(cmark-gfm --unsafe -e table "$README")

# Rewrite absolute gh-pages image URLs to relative paths
BODY=$(echo "$BODY" | sed 's|https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/||g')

cat <<'TEMPLATE_HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ClipKitty — Clipboard Manager for macOS</title>
<meta name="description" content="Unlimited clipboard history with instant fuzzy search and multi-line previews. Private, fast, keyboard-driven. Free and open source for macOS.">
<meta property="og:title" content="ClipKitty — Clipboard Manager for macOS">
<meta property="og:description" content="Unlimited clipboard history with instant fuzzy search and multi-line previews. Private, fast, keyboard-driven. Free and open source for macOS.">
<meta property="og:image" content="icon.png">
<meta property="og:type" content="website">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
<noscript><style>body { opacity: 1 !important; }</style></noscript>
<style>
  /* ── Custom Properties ───────────────────────────────────── */
  :root {
    color-scheme: light dark;
    --bg: #fafafa;
    --bg-secondary: #f0f0f2;
    --text: #1d1d1f;
    --text-secondary: #6e6e73;
    --accent: #7c5cfc;
    --accent-hover: #6344e0;
    --border: #e5e5ea;
    --card-bg: #ffffff;
    --card-shadow: rgba(0,0,0,0.06);
    --hero-from: #1a0533;
    --hero-to: #0c1a3a;
    --hero-text: #f5f5f7;
    --nav-bg: rgba(250,250,250,0.72);
    --nav-border: rgba(0,0,0,0.08);
    --code-bg: #1c1c1e;
    --code-text: #e0e0e4;
    --key-bg: #f0f0f2;
    --key-border: #c8c8cc;
    --key-shadow: #b0b0b4;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0a0a0b;
      --bg-secondary: #141416;
      --text: #f5f5f7;
      --text-secondary: #86868b;
      --accent: #9d7fff;
      --accent-hover: #b49aff;
      --border: #2d2d30;
      --card-bg: #1c1c1e;
      --card-shadow: rgba(0,0,0,0.3);
      --nav-bg: rgba(10,10,11,0.72);
      --nav-border: rgba(255,255,255,0.08);
      --key-bg: #2d2d30;
      --key-border: #3a3a3d;
      --key-shadow: #1a1a1c;
    }
  }

  /* ── Reset & Base ────────────────────────────────────────── */
  *, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }
  html { scroll-behavior: smooth; }

  body {
    font-family: 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    line-height: 1.7;
    color: var(--text);
    background: var(--bg);
    opacity: 0;
    transition: opacity 0.3s ease;
    -webkit-font-smoothing: antialiased;
    -moz-osx-font-smoothing: grayscale;
  }

  /* ── No-JS fallback: style bare elements ─────────────────── */
  body > h1:first-of-type { font-size: clamp(2rem, 5vw, 3.5rem); margin: 2rem auto; max-width: 760px; padding: 0 1.5rem; }
  body > p { max-width: 760px; margin: 0 auto 1rem; padding: 0 1.5rem; }
  body > img { display: block; max-width: 760px; margin: 1rem auto; padding: 0 1.5rem; }

  /* ── Typography ──────────────────────────────────────────── */
  h1 { font-size: clamp(2.25rem, 5vw, 3.5rem); font-weight: 700; letter-spacing: -0.03em; line-height: 1.15; }
  h2 { font-size: clamp(1.5rem, 3vw, 2rem); font-weight: 700; letter-spacing: -0.02em; margin-bottom: 1rem; }
  h3 { font-size: 1.15rem; font-weight: 600; margin-top: 1.5rem; margin-bottom: 0.5rem; }
  p { margin-bottom: 1rem; }
  a { color: var(--accent); text-decoration: none; transition: color 0.15s ease; }
  a:hover { color: var(--accent-hover); }

  ul, ol { margin-bottom: 1rem; padding-left: 1.5rem; }
  li { margin-bottom: 0.35rem; }

  /* ── Inline code & code blocks ───────────────────────────── */
  code {
    font-family: "SF Mono", Menlo, monospace;
    font-size: 0.88em;
    background: var(--bg-secondary);
    padding: 0.15em 0.45em;
    border-radius: 5px;
  }
  pre {
    background: var(--code-bg) !important;
    color: var(--code-text);
    padding: 1.25rem 1.5rem;
    border-radius: 12px;
    overflow-x: auto;
    margin-bottom: 1.25rem;
    font-size: 0.9rem;
    line-height: 1.6;
  }
  pre code { background: none; padding: 0; color: inherit; }

  /* ── Images ──────────────────────────────────────────────── */
  img { max-width: 100%; height: auto; border-radius: 10px; }

  /* ── Content wrapper ─────────────────────────────────────── */
  .content-section {
    max-width: 760px;
    margin: 0 auto;
    padding: 3.5rem 1.5rem 0;
  }

  /* ── Hero ─────────────────────────────────────────────────── */
  .hero {
    background: linear-gradient(165deg, var(--hero-from) 0%, var(--hero-to) 100%);
    color: var(--hero-text);
    text-align: center;
    padding: 5rem 1.5rem 4rem;
    position: relative;
    overflow: hidden;
  }
  .hero::before {
    content: '';
    position: absolute;
    inset: 0;
    background: radial-gradient(ellipse 60% 50% at 50% 20%, rgba(124,92,252,0.18) 0%, transparent 70%);
    pointer-events: none;
  }
  .hero h1 {
    background: linear-gradient(135deg, #c4b5fd 0%, #7c5cfc 40%, #38bdf8 100%);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    background-clip: text;
    margin-bottom: 0.5rem;
    position: relative;
  }
  .hero img[width="60"] {
    width: 72px;
    border-radius: 16px;
    margin-bottom: 1.25rem;
    filter: drop-shadow(0 4px 24px rgba(124,92,252,0.3));
  }
  .hero > p {
    color: rgba(245,245,247,0.7);
    font-size: clamp(1rem, 2vw, 1.2rem);
    max-width: 540px;
    margin: 0 auto 1rem;
    position: relative;
  }
  .hero a { color: #c4b5fd; }
  .hero a:hover { color: #e0d4ff; }

  /* ── Screenshot Gallery ──────────────────────────────────── */
  .screenshot-gallery {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 2rem;
    padding: 0 1.5rem 3rem;
    max-width: 900px;
    margin: -1.5rem auto 0;
    position: relative;
  }
  .screenshot-gallery img {
    width: 100%;
    max-width: 820px;
    border-radius: 14px;
    box-shadow: 0 8px 40px rgba(0,0,0,0.15), 0 2px 12px rgba(0,0,0,0.08);
    transition: transform 0.35s cubic-bezier(0.25,0.46,0.45,0.94), box-shadow 0.35s ease;
  }
  .screenshot-gallery img:hover {
    transform: translateY(-4px);
    box-shadow: 0 16px 56px rgba(0,0,0,0.2), 0 4px 16px rgba(0,0,0,0.1);
  }
  .screenshot-gallery img:nth-child(1) { animation: fadeSlideUp 0.7s 0.1s both; }
  .screenshot-gallery img:nth-child(2) { animation: fadeSlideUp 0.7s 0.3s both; }
  .screenshot-gallery img:nth-child(3) { animation: fadeSlideUp 0.7s 0.5s both; }

  @keyframes fadeSlideUp {
    from { opacity: 0; transform: translateY(32px); }
    to   { opacity: 1; transform: translateY(0); }
  }

  /* ── Feature List (card grid) ────────────────────────────── */
  .feature-list {
    list-style: none;
    padding-left: 0;
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
    gap: 1.25rem;
  }
  .feature-list li {
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: 14px;
    padding: 1.5rem;
    margin-bottom: 0;
    transition: transform 0.25s cubic-bezier(0.25,0.46,0.45,0.94), box-shadow 0.25s ease;
    box-shadow: 0 1px 3px var(--card-shadow);
  }
  .feature-list li:hover {
    transform: translateY(-3px);
    box-shadow: 0 8px 28px var(--card-shadow);
  }
  .feature-list li strong {
    display: block;
    font-size: 1.05rem;
    font-weight: 600;
    color: var(--accent);
    margin-bottom: 0.35rem;
  }

  /* ── Comparison Table ────────────────────────────────────── */
  .comparison-table {
    border-collapse: separate;
    border-spacing: 0;
    border-radius: 14px;
    overflow: hidden;
    border: 1px solid var(--border);
    margin-bottom: 1.5rem;
    font-size: 0.95rem;
  }
  .comparison-table th,
  .comparison-table td {
    padding: 0.85rem 1.1rem;
    border: none;
    border-bottom: 1px solid var(--border);
    text-align: left;
  }
  .comparison-table tr:last-child td { border-bottom: none; }
  .comparison-table th {
    background: var(--accent);
    color: #fff;
    font-weight: 600;
    font-size: 0.9rem;
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
  .comparison-table td:first-child {
    font-weight: 600;
    white-space: nowrap;
    color: var(--text);
    width: 120px;
  }
  .comparison-table tr:nth-child(even) td { background: var(--bg-secondary); }
  .comparison-table tr:nth-child(odd) td { background: var(--card-bg); }

  /* ── Keyboard Shortcuts Table ────────────────────────────── */
  .shortcuts-table {
    border-collapse: separate;
    border-spacing: 0;
    border-radius: 14px;
    overflow: hidden;
    border: 1px solid var(--border);
    margin-bottom: 1.5rem;
    width: 100%;
  }
  .shortcuts-table th,
  .shortcuts-table td {
    padding: 0.75rem 1rem;
    border: none;
    border-bottom: 1px solid var(--border);
    text-align: left;
  }
  .shortcuts-table tr:last-child td { border-bottom: none; }
  .shortcuts-table th {
    background: var(--accent);
    color: #fff;
    font-weight: 600;
    font-size: 0.9rem;
  }
  .shortcuts-table td:first-child strong,
  .shortcuts-table td:first-child code,
  .shortcuts-table td:first-child {
    font-family: "SF Mono", Menlo, monospace;
  }
  .shortcuts-table td:first-child strong {
    display: inline-block;
    background: var(--key-bg);
    color: var(--text);
    border: 1px solid var(--key-border);
    border-bottom: 2px solid var(--key-shadow);
    border-radius: 6px;
    padding: 0.15em 0.55em;
    font-size: 0.88em;
    font-weight: 500;
    box-shadow: 0 1px 0 var(--key-shadow);
    -webkit-text-fill-color: var(--text);
  }
  .shortcuts-table tr:nth-child(even) td { background: var(--bg-secondary); }
  .shortcuts-table tr:nth-child(odd) td { background: var(--card-bg); }

  /* ── Scroll Animations ───────────────────────────────────── */
  [data-animate] {
    opacity: 0;
    transform: translateY(24px);
    transition: opacity 0.6s cubic-bezier(0.25,0.46,0.45,0.94), transform 0.6s cubic-bezier(0.25,0.46,0.45,0.94);
  }
  [data-animate].visible {
    opacity: 1;
    transform: translateY(0);
  }

  /* ── Sticky Nav ──────────────────────────────────────────── */
  .sticky-nav {
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    z-index: 100;
    background: var(--nav-bg);
    backdrop-filter: blur(20px) saturate(180%);
    -webkit-backdrop-filter: blur(20px) saturate(180%);
    border-bottom: 1px solid var(--nav-border);
    transform: translateY(-100%);
    transition: transform 0.3s ease;
    display: flex;
    justify-content: center;
    gap: 2rem;
    padding: 0.75rem 1.5rem;
    font-size: 0.88rem;
    font-weight: 500;
  }
  .sticky-nav.visible { transform: translateY(0); }
  .sticky-nav a {
    color: var(--text-secondary);
    text-decoration: none;
    transition: color 0.15s ease;
  }
  .sticky-nav a:hover { color: var(--accent); }

  /* ── Technical Details Toggle ─────────────────────────────── */
  .tech-details-toggle {
    margin-top: 2rem;
    border: 1px solid var(--border);
    border-radius: 14px;
    overflow: hidden;
  }
  .tech-details-toggle summary {
    cursor: pointer;
    padding: 1rem 1.25rem;
    font-weight: 600;
    font-size: 1rem;
    color: var(--text-secondary);
    background: var(--card-bg);
    list-style: none;
    display: flex;
    align-items: center;
    gap: 0.5rem;
    transition: color 0.15s ease;
    user-select: none;
  }
  .tech-details-toggle summary::-webkit-details-marker { display: none; }
  .tech-details-toggle summary::before {
    content: '\25B6';
    font-size: 0.7em;
    transition: transform 0.2s ease;
  }
  .tech-details-toggle[open] summary::before { transform: rotate(90deg); }
  .tech-details-toggle summary:hover { color: var(--accent); }
  .tech-details-toggle .tech-details-content {
    padding: 0 1.25rem 1.25rem;
  }

  /* ── Footer ──────────────────────────────────────────────── */
  footer {
    max-width: 760px;
    margin: 4rem auto 0;
    padding: 2rem 1.5rem 3rem;
    text-align: center;
    position: relative;
  }
  footer::before {
    content: '';
    display: block;
    width: 48px;
    height: 2px;
    background: var(--border);
    margin: 0 auto 2rem;
    border-radius: 1px;
  }
  footer p { color: var(--text-secondary); font-size: 0.85rem; margin-bottom: 0.5rem; }
  footer .links { margin-top: 0.75rem; }
  footer .links a {
    color: var(--text-secondary);
    margin: 0 0.85rem;
    font-size: 0.85rem;
    font-weight: 500;
    transition: color 0.15s ease;
  }
  footer .links a:hover { color: var(--accent); }

  /* ── Responsive ──────────────────────────────────────────── */
  @media (max-width: 640px) {
    .hero { padding: 3.5rem 1.25rem 2.5rem; }
    .feature-list { grid-template-columns: 1fr; }
    .content-section { padding: 2.5rem 1.25rem 0; }
    .screenshot-gallery { padding: 0 1rem 2rem; }
    .sticky-nav { display: none; }
    .comparison-table td:first-child { white-space: normal; width: auto; }
  }
</style>
</head>
<body>
TEMPLATE_HEAD

echo "$BODY"

cat <<'TEMPLATE_FOOT'

<footer>
  <p>&copy; 2025–2026 Juliette Pluto</p>
  <div class="links">
    <a href="https://github.com/jul-sh/clipkitty">GitHub</a>
    <a href="privacy.html">Privacy Policy</a>
    <a href="mailto:apple@jul.sh">Contact</a>
  </div>
</footer>

<script>
document.addEventListener('DOMContentLoaded', function() {
  var body = document.body;
  var children = Array.from(body.childNodes);

  // 1. Wrap everything before first <h2> into hero section
  var hero = document.createElement('section');
  hero.className = 'hero';
  var firstH2 = body.querySelector('h2');
  var nodesToMove = [];
  for (var i = 0; i < children.length; i++) {
    if (children[i] === firstH2) break;
    nodesToMove.push(children[i]);
  }
  nodesToMove.forEach(function(n) { hero.appendChild(n); });
  body.insertBefore(hero, body.firstChild);

  // 2. Pull marketing screenshots (width="820") into gallery
  var screenshots = hero.querySelectorAll('img[width="820"]');
  if (screenshots.length) {
    var gallery = document.createElement('div');
    gallery.className = 'screenshot-gallery';
    screenshots.forEach(function(img) { gallery.appendChild(img); });
    hero.insertAdjacentElement('afterend', gallery);
  }

  // 3. Wrap each h2 + siblings into content-section
  var h2s = Array.from(body.querySelectorAll(':scope > h2'));
  h2s.forEach(function(h2) {
    var section = document.createElement('section');
    section.className = 'content-section';
    section.setAttribute('data-animate', '');
    var text = h2.textContent.trim();
    section.id = text.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/(^-|-$)/g, '');
    h2.parentNode.insertBefore(section, h2);
    section.appendChild(h2);
    while (section.nextSibling && !(section.nextSibling.tagName === 'H2' || (section.nextSibling.tagName === 'FOOTER'))) {
      section.appendChild(section.nextSibling);
    }
  });

  // 4. Add feature-list class
  var featSec = document.getElementById('features');
  if (featSec) {
    var ul = featSec.querySelector('ul');
    if (ul) ul.classList.add('feature-list');
  }

  // 5. Add comparison-table class
  var whySec = document.getElementById('why-clipkitty');
  if (whySec) {
    var t = whySec.querySelector('table');
    if (t) t.classList.add('comparison-table');
  }

  // 6. Add shortcuts-table class
  var kbSec = document.getElementById('keyboard-shortcuts');
  if (kbSec) {
    var kt = kbSec.querySelector('table');
    if (kt) kt.classList.add('shortcuts-table');
  }

  // 7. Build sticky nav
  var navIds = ['why-clipkitty', 'features', 'installation'];
  var navLabels = {'why-clipkitty': 'Why ClipKitty?', 'features': 'Features', 'installation': 'Installation'};
  var nav = document.createElement('nav');
  nav.className = 'sticky-nav';
  nav.setAttribute('aria-label', 'Page navigation');
  navIds.forEach(function(id) {
    var sec = document.getElementById(id);
    if (sec) {
      var a = document.createElement('a');
      a.href = '#' + id;
      a.textContent = navLabels[id] || id;
      nav.appendChild(a);
    }
  });
  body.insertBefore(nav, body.firstChild);

  // 8. Scroll animations
  if ('IntersectionObserver' in window) {
    var animObs = new IntersectionObserver(function(entries) {
      entries.forEach(function(e) {
        if (e.isIntersecting) { e.target.classList.add('visible'); animObs.unobserve(e.target); }
      });
    }, { threshold: 0.1 });
    document.querySelectorAll('[data-animate]').forEach(function(el) { animObs.observe(el); });

    // 9. Show/hide sticky nav based on hero visibility
    var heroEl = document.querySelector('.hero');
    if (heroEl) {
      var navObs = new IntersectionObserver(function(entries) {
        entries.forEach(function(e) { nav.classList.toggle('visible', !e.isIntersecting); });
      }, { threshold: 0 });
      navObs.observe(heroEl);
    }
  }

  // 10. Collapse technical h3 sections into a details/summary toggle
  var buildSec = document.getElementById('building-from-source');
  if (buildSec) {
    var techH3s = buildSec.querySelectorAll('h3');
    var techNodes = [];
    techH3s.forEach(function(h3) {
      var text = h3.textContent.trim();
      if (text === 'How Search Works' || text === 'Problems This Solves') {
        techNodes.push(h3);
        var sib = h3.nextElementSibling;
        while (sib && sib.tagName !== 'H3' && sib.tagName !== 'H2') {
          techNodes.push(sib);
          sib = sib.nextElementSibling;
        }
      }
    });
    if (techNodes.length) {
      var details = document.createElement('details');
      details.className = 'tech-details-toggle';
      var summary = document.createElement('summary');
      summary.textContent = 'Technical Details';
      details.appendChild(summary);
      var inner = document.createElement('div');
      inner.className = 'tech-details-content';
      techNodes[0].parentNode.insertBefore(details, techNodes[0]);
      techNodes.forEach(function(n) { inner.appendChild(n); });
      details.appendChild(inner);
    }
  }

  // 11. Reveal page
  body.style.opacity = '1';
});
</script>
</body>
</html>
TEMPLATE_FOOT
