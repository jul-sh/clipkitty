# Public website

This directory contains the source assets deployed to the `gh-pages` branch.

- `public/` holds files copied to the published site unchanged.
- `templates/index.html` wraps the rendered repository README. The site generator replaces the single `<!-- README_CONTENT -->` marker.
- `build/site/icon.png` is generated from `AppIcon.icon` by `make site-icon` and is intentionally ignored by Git.

Render the landing page with `make site-landing-page` and generate the icon with `make site-icon`.
