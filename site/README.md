# Sovereign Homelab site

VitePress source for the **Sovereign Homelab** course. Secure your homelab, secure your node.

The course markdown lives in the repo's [`../docs/`](../docs) folder. This project only holds
the VitePress config and build tooling. The site config sets `srcDir` to `../docs`, so it renders
those modules directly.

## Run locally

```sh
cd site
npm install
npm run docs:dev
```

That serves the site at `http://localhost:5173/sovereign-homelab/` with hot reload.

Other scripts:

- `npm run docs:build` builds the static site to `site/.vitepress/dist`.
- `npm run docs:preview` serves the built output for a final local check.

## Publishing

CI publishes to GitHub Pages. On every push to `main`, the workflow at
[`../.github/workflows/deploy.yml`](../.github/workflows/deploy.yml) builds this site and deploys
`site/.vitepress/dist` to Pages. The published course is at
<https://twentyonelife.github.io/sovereign-homelab/>.

One-time setup: in the repo **Settings > Pages**, set **Source** to **GitHub Actions**. Without that,
the workflow builds successfully but deploys nowhere.
