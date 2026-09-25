# hannoknatz.com

Personal website of Hanno Knatz.

Static. Deterministic. No nonsense.

## Infrastructure

- **Repo:** `Level-Zero-Context/hannoknatz.com` (GitHub)
- **Hosting:** Cloudflare Pages, git-connected to this repo
- **Deploy:** every push to `main` triggers an automatic production build (git sync)
- **Domain:** `hannoknatz.com` (Cloudflare zone, custom domain on the Pages project)

## Local preview

Static files only — open `index.html` in a browser or run any static server:

```bash
python3 -m http.server 8000
```
