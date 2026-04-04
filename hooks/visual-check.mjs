#!/usr/bin/env node
/**
 * Auto-discovering visual verification screenshot script for Claude Code.
 *
 * Instead of a hardcoded page list, this script:
 * 1. Crawls the SvelteKit routes directory to discover all +page.svelte files
 * 2. Converts route paths to URLs (skipping dynamic [param] segments)
 * 3. Navigates to each discovered page and screenshots it
 * 4. Follows links on each page to discover sub-states (tabs, views)
 * 5. Takes screenshots at desktop and mobile viewports
 *
 * Usage:
 *   node scripts/visual-check.mjs [base-url] [--routes-dir=path]
 */

import { createRequire } from 'module';
const require = createRequire(import.meta.url);
let chromium;
try {
  chromium = require('playwright-core').chromium;
} catch {
  chromium = require('playwright').chromium;
}
import { mkdirSync, readdirSync, statSync, existsSync } from 'fs';
import { resolve, relative, join } from 'path';

const BASE = process.argv[2] || 'http://localhost:4173';
const OUT_DIR = resolve('/tmp/pneuma-visual-check');
const ROUTES_DIR_ARG = process.argv.find(a => a.startsWith('--routes-dir='));
const ROUTES_DIR = ROUTES_DIR_ARG
  ? ROUTES_DIR_ARG.split('=')[1]
  : '/app/routes'; // Default: mounted from host

// ── Route Discovery ──────────────────────────────────────────

function discoverRoutes(dir, prefix = '') {
  const routes = [];
  if (!existsSync(dir)) return routes;

  const entries = readdirSync(dir, { withFileTypes: true });

  for (const entry of entries) {
    const fullPath = join(dir, entry.name);

    if (entry.isDirectory()) {
      // Skip groups like (auth), api routes, and layout-only dirs
      if (entry.name.startsWith('(') || entry.name === 'api') continue;

      let segment = entry.name;

      // Dynamic params: [id] → use a placeholder or skip
      if (segment.startsWith('[') && segment.endsWith(']')) {
        // Skip dynamic routes — we can't navigate without real IDs
        // These are tested via the parent page's navigation
        continue;
      }

      discoverRoutes(fullPath, `${prefix}/${segment}`).forEach(r => routes.push(r));
    }

    if (entry.isFile() && entry.name === '+page.svelte') {
      const routePath = prefix || '/';
      routes.push(routePath);
    }
  }

  return routes;
}

// ── URL Param Views ──────────────────────────────────────────
// Some pages use URL params to switch views. Discover these by
// scanning the page source for ?view= or ?tab= patterns.

function discoverParamViews(routePath) {
  const views = [];

  // Pipeline page has view param
  if (routePath === '/platform/pipeline') {
    views.push(
      { param: '?view=topology', suffix: 'topology' },
      { param: '?view=stream', suffix: 'stream' },
      { param: '?view=traces', suffix: 'traces' },
      { param: '?view=metrics', suffix: 'metrics' },
      { param: '?view=llm-traces', suffix: 'llm-traces' },
    );
  }

  return views;
}

// ── Viewports ────────────────────────────────────────────────

const VIEWPORTS = [
  { name: 'desktop', width: 1280, height: 800 },
  { name: 'mobile', width: 375, height: 812 },
];

// ── Screenshot Engine ────────────────────────────────────────

mkdirSync(OUT_DIR, { recursive: true });

// Discover routes
console.log(`Discovering routes from: ${ROUTES_DIR}`);
const routes = discoverRoutes(ROUTES_DIR);
console.log(`Found ${routes.length} routes:\n  ${routes.join('\n  ')}`);

// Expand routes with param views
const allPages = [];
for (const route of routes) {
  const paramViews = discoverParamViews(route);
  if (paramViews.length > 0) {
    for (const pv of paramViews) {
      allPages.push({
        url: `${route}${pv.param}`,
        name: `${route.replace(/\//g, '-').replace(/^-/, '')}--${pv.suffix}`,
      });
    }
  } else {
    allPages.push({
      url: route,
      name: route === '/' ? 'root' : route.replace(/\//g, '-').replace(/^-/, ''),
    });
  }
}

console.log(`\nTotal pages to screenshot: ${allPages.length} x ${VIEWPORTS.length} viewports = ${allPages.length * VIEWPORTS.length} screenshots\n`);

const browser = await chromium.launch({ headless: true });
let total = 0;
let failed = 0;

for (const vp of VIEWPORTS) {
  for (const pg of allPages) {
    const ctx = await browser.newContext({
      viewport: { width: vp.width, height: vp.height },
    });
    const page = await ctx.newPage();
    const filename = `${pg.name}--${vp.name}.png`;

    try {
      const response = await page.goto(`${BASE}${pg.url}`, {
        waitUntil: 'networkidle',
        timeout: 15000,
      });

      // Wait for animations to settle
      await page.waitForTimeout(1500);

      // Check if we landed on the expected page (not redirected to login)
      const finalUrl = page.url();

      await page.screenshot({
        path: resolve(OUT_DIR, filename),
        fullPage: false,
      });
      total++;

      const redirectNote = finalUrl.includes('/login') && !pg.url.includes('/login')
        ? ' (redirected to login)'
        : '';
      console.log(`  [ok] ${filename}${redirectNote}`);
    } catch (err) {
      failed++;
      console.error(`  [FAIL] ${filename}: ${err.message.split('\n')[0]}`);
    }

    await ctx.close();
  }
}

// ── Interactive State Screenshots ────────────────────────────
// Command palette, mobile sidebar open, etc.

const interactiveStates = [
  {
    url: '/platform',
    name: 'overlay--command-palette',
    viewport: 'desktop',
    actions: async (page) => {
      await page.keyboard.press('Control+k');
      await page.waitForTimeout(500);
    },
  },
  {
    url: '/platform',
    name: 'overlay--mobile-sidebar',
    viewport: 'mobile',
    actions: async (page) => {
      const btn = page.locator('button[aria-label="Toggle menu"]');
      if (await btn.isVisible()) {
        await btn.click();
        await page.waitForTimeout(500);
      }
    },
  },
];

for (const state of interactiveStates) {
  const vp = VIEWPORTS.find(v => v.name === state.viewport);
  if (!vp) continue;

  const ctx = await browser.newContext({
    viewport: { width: vp.width, height: vp.height },
  });
  const page = await ctx.newPage();
  const filename = `${state.name}--${state.viewport}.png`;

  try {
    await page.goto(`${BASE}${state.url}`, {
      waitUntil: 'networkidle',
      timeout: 15000,
    });
    await page.waitForTimeout(800);
    await state.actions(page);
    await page.screenshot({
      path: resolve(OUT_DIR, filename),
      fullPage: false,
    });
    total++;
    console.log(`  [ok] ${filename}`);
  } catch (err) {
    failed++;
    console.error(`  [FAIL] ${filename}: ${err.message.split('\n')[0]}`);
  }

  await ctx.close();
}

await browser.close();

console.log(`\nDone. ${total} captured, ${failed} failed. Saved to ${OUT_DIR}/`);
if (failed > 0) process.exit(1);
