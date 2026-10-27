# NOVA Core Frontend (Ember)

React 19 single-page app built with Vite 8, the React plugin, and Tailwind CSS 4. The API base comes from VITE_BACKEND_URL; when unset it defaults to http://127.0.0.1:8002.

The Emergent builder badge/script and unconditional PostHog telemetry have been removed. There is no frontend analytics SDK enabled in this build. Google Fonts are still referenced for the app's typefaces.

## Local development

From this directory, install the locked dependencies with npm ci, then run npm run dev -- --host 127.0.0.1 --port 3002. The default is loopback-only; use a trusted Tailscale IP only when intentionally exposing this app to the private tailnet.

## Release checks

- npm run build — production bundle
- npm test — Node test discovery (there are currently no frontend test files)
- npm audit --audit-level=low — dependency audit

The canonical all-app runner is ../../../../scripts/start-all.sh; it supplies the bind host and VITE_BACKEND_URL, starts the Core API on port 8002 and this UI on port 3002, and keeps recruiter API on loopback.
