# App Store Submission Readiness Assessment

Assessed: 2026-02-16 | App: ClipKitty (com.eviljuliette.clipkitty) | Version: 1.7.1

---

## Summary

All identified blockers and high-priority issues have been resolved. ClipKitty is ready for App Store submission.

---

## Resolved Issues

### 1. Privacy policy page — DONE
- Published at https://jul-sh.github.io/clipkitty/privacy (gh-pages branch)
- Covers: no data collection, local-only storage, clipboard handling, network access for link previews, data deletion, children's privacy
- Updated `distribution/metadata/en-US/privacy_url.txt` → `https://jul-sh.github.io/clipkitty/privacy`

### 2. Landing page — DONE
- Published at https://jul-sh.github.io/clipkitty/ (gh-pages branch)
- Includes: app description, hero with App Store badge, marketing screenshot, 6 feature cards, Homebrew install, footer with privacy policy and contact links
- Updated `distribution/metadata/en-US/marketing_url.txt` → `https://jul-sh.github.io/clipkitty/`

### 3. Contact email — DONE
- Created `distribution/metadata/review_information/email_address.txt` → `apple@jul.sh`
- Created `distribution/metadata/review_information/first_name.txt` → `Juliette`
- Created `distribution/metadata/review_information/last_name.txt` → `Pluto`
- Email also shown on landing page and privacy policy page

### 4. Reviewer walkthrough — DONE
- Expanded `distribution/metadata/review_information/notes.txt` from 1 line to a full 10-step walkthrough
- Covers: menu bar icon, copying content, hotkey activation, navigation, search, filtering, settings
- Documents sandbox paste limitation explicitly
- References attached screen recording (to be recorded manually before submission)

### 5. Source image licenses — DONE
- Created `distribution/source-images/LICENSES.md` documenting all 13 images
- All images sourced from the Public Domain Image Archive (https://pdimagearchive.org)
- Each image listed with description and confirmed public domain status

### 6. Screenshot resolutions — VERIFIED (already passing)
- Marketing screenshots generated at 2880x1800 (Retina)
- Exceeds Mac App Store minimum (1280x800) and matches recommended Retina resolution
- CI pipeline already adds captions and compositing via `generate-marketing-screenshots.sh`

### 7. Copyright year — DONE
- Updated `distribution/metadata/copyright.txt` → `2025–2026 Juliette Pluto`

### 8. Sandbox paste limitation documented — DONE
- Added note to App Store description (`distribution/metadata/en-US/description.txt`)
- Also documented in reviewer notes

### 9. Dual license setup (vvterm model) — DONE
- Created `LICENSE-APPSTORE.md` — App Store binary terms (Apple EULA + ClipKitty privacy policy)
- Created `THIRD_PARTY_NOTICES.md` — all Swift, Rust, and font dependencies with licenses
- Original `LICENSE` (GPL-3.0) unchanged for source code

---

## Remaining Manual Step

**Record a screen recording** for App Store reviewer attachment. The review notes reference it, but the actual recording must be captured manually (15–30 seconds showing: launch → menu bar icon → Option+Space → search → paste). Attach in App Store Connect under "App Review Information > Attachments."

---

## Passing Checks (No Action Needed)

| Check | Status |
|-------|--------|
| No "beta" or "coming soon" text | PASS |
| No Android/platform references | PASS |
| No competitor names in App Store listing | PASS |
| No LLM/AI content safety issues | PASS |
| No account system (no deletion needed) | PASS |
| No hidden functionality | PASS |
| No subscriptions/pricing complexity | PASS |
| App sandbox properly configured | PASS |
| Privacy manifest (PrivacyInfo.xcprivacy) | PASS |
| Age ratings configured | PASS |
| App category set (UTILITIES / PRODUCTIVITY) | PASS |
| Code signing & notarization | PASS |
| No hardcoded developer paths | PASS |
| Proper bundle identifier | PASS |
| Version numbering | PASS |
| Dark mode support | PASS |
| Keyboard shortcuts | PASS |
| Menu bar behavior | PASS |
| Window management | PASS |
| Concealed clipboard respect | PASS |
| Hardened runtime | PASS |
| App description quality | PASS |
| Keywords configured | PASS |
| Subtitle configured | PASS |
| Promotional text configured | PASS |
| Dual license (GPL-3.0 + App Store) | PASS |
| Bundled fonts licensed (SIL OFL) | PASS |
| Source images licensed (public domain) | PASS |

---

## Files Changed

**On `appstore` branch:**
- `distribution/metadata/en-US/privacy_url.txt` — updated URL
- `distribution/metadata/en-US/marketing_url.txt` — updated URL
- `distribution/metadata/en-US/description.txt` — added sandbox paste note
- `distribution/metadata/copyright.txt` — updated year
- `distribution/metadata/review_information/notes.txt` — expanded walkthrough
- `distribution/metadata/review_information/email_address.txt` — new
- `distribution/metadata/review_information/first_name.txt` — new
- `distribution/metadata/review_information/last_name.txt` — new
- `distribution/source-images/LICENSES.md` — new
- `LICENSE-APPSTORE.md` — new
- `THIRD_PARTY_NOTICES.md` — new
- `APPSTORE_READINESS.md` — this file

**On `gh-pages` branch (pushed to remote):**
- `index.html` — landing page
- `privacy.html` — privacy policy
