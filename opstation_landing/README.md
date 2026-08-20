# Opstation Landing Page

Static HTML + Tailwind. Single file. Editorial design — warm paper, deep ink, single rust accent. Distinctive serif (Instrument Serif) + technical sans (IBM Plex).

## Files

- `index.html` — the whole site (hero, features, two surfaces, day-in-the-life, pricing, notes, demo form, footer)
- `firebase.json` — hosting config, cache headers tuned for static
- `.firebaserc` — created by `firebase use` (not committed yet)

## Deploy — pick one of two paths

### Path A: Separate Firebase project (recommended, isolated from the app)

```bash
cd ~/development/opstation_landing

# 1) Create a new project in the Firebase Console
#    https://console.firebase.google.com/  →  Add project  →  name it e.g. "opstation-landing"
#    Disable Google Analytics if you don't need it for marketing.

# 2) Point the local directory at the new project
firebase use --add
# pick the new project from the list, give it the alias "default"

# 3) Deploy
firebase deploy --only hosting
```

You'll get a URL like `https://opstation-landing.web.app`. Custom domain (opstation.app, etc.) can be added later under Hosting → Custom domains in the console.

### Path B: Multi-site under the existing `opstation-f06c7` project

Keeps both sites in one Firebase project (one billing, one console).

```bash
cd ~/development/opstation_landing

# 1) Create a second hosting site under the existing project
firebase hosting:sites:create opstation-landing --project opstation-f06c7

# 2) Point local "default" target at it
firebase target:apply hosting landing opstation-landing --project opstation-f06c7

# 3) Update firebase.json to use the target (replace the existing "hosting": { ... } block):
```

Replace `firebase.json` `hosting` with:
```json
"hosting": {
  "target": "landing",
  "public": ".",
  "ignore": ["firebase.json", ".firebaserc", "**/.*", "README.md"],
  "cleanUrls": true
}
```

```bash
# 4) Set the project and deploy
echo '{"projects":{"default":"opstation-f06c7"}}' > .firebaserc
firebase deploy --only hosting:landing
```

URL will be `https://opstation-landing.web.app`.

## Local preview

```bash
cd ~/development/opstation_landing
python3 -m http.server 8080
# open http://localhost:8080
```

Or use `firebase serve --only hosting` to preview with the cache headers applied.

## Editing notes

- All sections are in `index.html` — labelled with `<!-- ============== SECTION ============== -->` comments.
- Colors are CSS variables + Tailwind config near the top of the file. Change `--paper`, `--ink`, and the `rust` color to retheme.
- Fonts swap by changing the Google Fonts `<link>` and the `tailwind.config.fontFamily` block.
- The demo form currently just shows a confirmation message client-side. Wire it up to Formspree, your own endpoint, or Calendly when you're ready.

## When you're ready to harden for production

- Replace Tailwind Play CDN with a built CSS file (`tailwindcss -i in.css -o out.css --minify`). Drops ~70KB and removes the dev-console warning.
- Add `privacy.html` and `terms.html` (linked from the footer; Play Store will require privacy).
- Replace the rust dot favicon with a real `favicon.ico` and Apple touch icon.
- Add OG image at `/og.png` (1200×630) referenced from the OG meta tags.
- Add `robots.txt` and `sitemap.xml`.
