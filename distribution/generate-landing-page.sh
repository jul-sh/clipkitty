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
<style>
  :root { color-scheme: light dark; }
  * { margin: 0; padding: 0; box-sizing: border-box; }

  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    line-height: 1.7;
    max-width: 760px;
    margin: 0 auto;
    padding: 3rem 1.5rem;
    color: #1d1d1f;
    background: #fff;
  }
  @media (prefers-color-scheme: dark) {
    body { color: #f5f5f7; background: #1d1d1f; }
    a { color: #6cb4ee; }
    code { background: #2d2d2d; }
    pre { background: #2d2d2d !important; }
    table th { background: #2d2d2d; }
    table td, table th { border-color: #424245; }
  }

  h1 { font-size: 2.25rem; margin-top: 2.5rem; margin-bottom: 0.5rem; }
  h2 { font-size: 1.4rem; margin-top: 2.5rem; margin-bottom: 0.75rem; }
  h3 { font-size: 1.1rem; margin-top: 1.5rem; margin-bottom: 0.5rem; }
  p { margin-bottom: 1rem; }
  ul, ol { margin-bottom: 1rem; padding-left: 1.5rem; }
  li { margin-bottom: 0.3rem; }
  img { max-width: 100%; height: auto; border-radius: 8px; margin: 1rem 0; }
  a { color: #0071e3; text-decoration: none; }
  a:hover { text-decoration: underline; }
  code {
    background: #f5f5f7;
    padding: 0.15em 0.4em;
    border-radius: 4px;
    font-size: 0.9em;
    font-family: "SF Mono", Menlo, monospace;
  }
  pre {
    background: #f5f5f7;
    padding: 1rem;
    border-radius: 8px;
    overflow-x: auto;
    margin-bottom: 1rem;
  }
  pre code { background: none; padding: 0; }

  table {
    width: 100%;
    border-collapse: collapse;
    margin-bottom: 1rem;
    font-size: 0.95rem;
  }
  table th, table td {
    text-align: left;
    padding: 0.5rem 0.75rem;
    border: 1px solid #d2d2d7;
  }
  table th { background: #f5f5f7; font-weight: 600; }

  footer {
    margin-top: 3rem;
    padding-top: 1.5rem;
    border-top: 1px solid #d2d2d7;
    font-size: 0.85rem;
    color: #86868b;
    text-align: center;
  }
  @media (prefers-color-scheme: dark) {
    footer { border-top-color: #424245; }
  }
  footer a { color: inherit; text-decoration: none; }
  footer a:hover { text-decoration: underline; }
  footer .links { margin-top: 0.5rem; }
  footer .links a { margin: 0 0.75rem; }
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

</body>
</html>
TEMPLATE_FOOT
