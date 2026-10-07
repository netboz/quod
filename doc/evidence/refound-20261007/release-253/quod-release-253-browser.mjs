import { chromium } from '/home/yan/src/quod/_build/lobby-toolkit-20260925/browser/node_modules/playwright/index.mjs';
import { cp, mkdir, writeFile } from 'node:fs/promises';
import assert from 'node:assert/strict';

const mode = process.argv[2];
assert.ok(['built', 'deployed'].includes(mode));
const dir = `/tmp/quod-release-253-20261007/browser-${mode}`;
await mkdir(dir, { mode: 0o700 });
await cp('/tmp/quod-lobby-release-20261005-01/browser-after-02/profile', `${dir}/profile`, { recursive: true });
const origin = 'https://192.168.1.10:31609';
const context = await chromium.launchPersistentContext(`${dir}/profile`, {
  executablePath: '/home/yan/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',
  headless: true, ignoreHTTPSErrors: true, viewport: { width: 1440, height: 1000 },
  args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
});
if (mode === 'built') await context.route(`${origin}/**`, async route => {
  const path = new URL(route.request().url()).pathname;
  if (path === '/' || path.startsWith('/assets/')) {
    await route.fulfill({ path: `/home/yan/src/quod/priv/explorer/${path === '/' ? 'world.html' : path.slice(1)}` });
  } else await route.continue();
});
const page = await context.newPage();
const errors = [];
page.on('pageerror', error => errors.push(error.message));
page.setDefaultTimeout(60000);
try {
  await page.goto(`${origin}/`);
  await page.getByRole('button', { name: 'Create account', exact: true }).waitFor();
  assert.equal(await page.getByRole('button', { name: 'Create account', exact: true }).isEnabled(), true);
  assert.equal(await page.getByText('Your lobby is ready.', { exact: true }).count(), 0);
  assert.equal(await page.evaluate(() => localStorage.getItem('quod.agent-references.v1')), null);
  await page.screenshot({ path: `${dir}/create-account.png` });
  await page.reload();
  await page.getByRole('button', { name: 'Create account', exact: true }).waitFor();
  assert.equal(await page.getByRole('button', { name: 'Create account', exact: true }).isEnabled(), true);
  assert.equal(await page.getByText('Your lobby is ready.', { exact: true }).count(), 0);
  assert.deepEqual(errors, []);
  await writeFile(`${dir}/RESULT.json`, JSON.stringify({
    passed: true, mode,
    checks: ['old browser profile authenticates to fresh root', 'Create account enabled',
      'old personal lobby never selected', 'global v1 key removed', 'reload remains on Create account'],
    account_created: false,
  }, null, 2));
  console.log(`PASS ${mode}: old profile reaches Create account after refresh`);
} catch (error) {
  await page.screenshot({ path: `${dir}/failure.png` });
  await writeFile(`${dir}/failure.txt`, String(error));
  throw error;
} finally { await context.close(); }
