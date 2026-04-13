# Clicky-Web SDK

> Forked from [farzaa/clicky](https://github.com/farzaa/clicky) — an AI buddy that lives on your Mac. This fork transforms it into an embeddable web SDK for step-by-step UI navigation.

An embeddable JavaScript SDK that adds step-by-step UI navigation guidance to any web app. Users press **Cmd+K** (or **Ctrl+K**), type what they want to do, and a blue cursor guides them through the interface — pointing at each element to click, waiting for them to click it, then showing the next step.

Powered by Claude's vision API. The SDK captures a screenshot of the page, sends it to Claude, and Claude responds with exactly where the user should click next.

## How it works

1. User presses **Cmd/Ctrl+K** → a text input appears
2. User types: *"How do I create a PostgreSQL service?"*
3. SDK screenshots the page and sends it to Claude
4. Claude analyzes the screenshot and responds: *"step 1 of ~4: click on the services tab in the left sidebar"*
5. The blue cursor flies to the element with a bezier arc animation
6. User clicks where the cursor points
7. SDK re-screenshots, sends to Claude, gets the next step
8. Repeat until done

## Quick start

### 1. Deploy the Cloudflare Worker

The Worker proxies requests to Claude's API so your keys never ship in the browser.

```bash
cd worker
npm install
npx wrangler secret put ANTHROPIC_API_KEY   # Your Anthropic API key
npx wrangler secret put SDK_API_KEY          # Any string — used to authenticate SDK requests
npx wrangler deploy
```

Copy the deployed Worker URL (e.g., `https://your-worker.workers.dev`).

### 2. Add the SDK to your site

**Script tag:**

```html
<script
  src="https://your-cdn.com/clicky-sdk.js"
  data-api-key="your-sdk-api-key"
  data-worker-url="https://your-worker.workers.dev">
</script>
```

**Or programmatically:**

```js
import Clicky from '@clicky/sdk';

Clicky.init({
  apiKey: 'your-sdk-api-key',
  workerUrl: 'https://your-worker.workers.dev',
});
```

### 3. Build the SDK from source

```bash
cd sdk
npm install
npm run build
# Outputs: dist/clicky-sdk.js (IIFE) and dist/clicky-sdk.esm.js (ESM)
```

## Configuration

```js
Clicky.init({
  apiKey: 'your-sdk-api-key',        // Required
  workerUrl: 'https://...',           // Required — your Worker URL
  model: 'claude-sonnet-4-6',        // Claude model (default: claude-sonnet-4-6)
  cursorColor: '#3380FF',             // Cursor color (default: blue)
  shortcut: 'mod+k',                 // Keyboard shortcut (default: Cmd/Ctrl+K)
  screenshotMaxDimension: 1280,       // Max screenshot size in px (default: 1280)
  systemPromptContext: '...',         // Additional context for Claude (e.g., product docs)
  onStateChange: (state) => {},       // Navigation state change callback
  onStepComplete: (step) => {},       // Step completion callback
  onError: (error) => {},             // Error callback
});
```

## API

```js
Clicky.init(config)                  // Initialize the SDK
Clicky.destroy()                     // Remove SDK from page
Clicky.startNavigation('query')      // Start navigation programmatically
Clicky.cancelNavigation()            // Cancel active navigation
Clicky.isActive()                    // Check if navigation is in progress
Clicky.getState()                    // Get current navigation state
```

## Architecture

```
Browser (your web app)                 Cloudflare Worker
┌──────────────────────────┐           ┌──────────────────────┐
│  <script src="sdk.js">   │           │  POST /chat          │
│                          │  fetch()  │    → forward to Claude│
│  Cmd+K → text input      │──────────→│    → stream response  │
│  html2canvas screenshot   │           │                      │
│  Blue cursor overlay      │  SSE     │                      │
│  Click detection          │←─────────│                      │
│  Bezier arc animation     │           └──────────────────────┘
└──────────────────────────┘
```

**SDK** (`sdk/`): TypeScript, bundled with esbuild. Uses Shadow DOM to isolate overlay styles from the host page. Screenshots via html2canvas (excludes SDK overlay). ~54KB gzipped.

**Worker** (`worker/`): Cloudflare Worker that proxies requests to Claude's API. Handles CORS, SDK API key auth, and SSE streaming.

## Project structure

```
sdk/                         # JavaScript SDK
  src/
    index.ts                   # Public API + auto-init
    ClickySDK.ts               # Main orchestrator (navigation loop)
    ApiClient.ts               # SSE streaming client
    PointTagParser.ts           # [POINT:x,y:label] regex parser
    ScreenshotCapture.ts        # html2canvas wrapper
    CoordinateMapper.ts         # Screenshot → viewport coordinate mapping
    overlay/                   # Shadow DOM UI components
    animation/                 # Bezier flight + character streaming
    events/                    # Keyboard + click listeners
  test.html                    # Demo page for testing
worker/                      # Cloudflare Worker proxy
  src/index.ts                 # Routes: POST /chat
```

## Local development

```bash
# Terminal 1: Run the worker locally
cd worker
echo "ANTHROPIC_API_KEY=sk-ant-..." > .dev.vars
echo "SDK_API_KEY=test-key" >> .dev.vars
npx wrangler dev

# Terminal 2: Build SDK and serve test page
cd sdk
npm run build
npx serve .
# Open http://localhost:3000/test.html
```

Update `test.html` to point `workerUrl` at `http://localhost:8787`.

## License

MIT
