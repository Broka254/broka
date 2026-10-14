// Renders each screen in screens.html to pitch/out/<id>.png at 2x, with a
// transparent background, for the investor deck. Needs Playwright and network
// access for Google Fonts:
//   NODE_PATH=$(npm root -g) node pitch/render-screens.js [id ...]
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const ALL = ['home', 'neg-buyer', 'neg-seller', 'listing', 'zeno', 'voice', 'pay', 'deal', 'mystore', 'dash', 'web'];

(async () => {
  // CHROMIUM points at a browser Playwright didn't download itself. The page
  // loads its fonts from Google Fonts: without them the icons render as
  // their ligature names ("arrow_forward"), so render with network access.
  const browser = await chromium.launch(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {});
  const page = await browser.newPage({ viewport: { width: 1800, height: 1200 }, deviceScaleFactor: 2 });
  await page.goto('file://' + path.join(__dirname, 'screens.html'));
  await page.evaluate(() => document.fonts.ready);
  // The constellation is drawn once on load; give it a frame.
  await page.waitForTimeout(500);
  fs.mkdirSync(path.join(__dirname, 'out'), { recursive: true });
  const ids = process.argv.slice(2).length ? process.argv.slice(2) : ALL;
  for (const id of ids) {
    const el = await page.$('#' + id);
    await el.screenshot({ path: path.join(__dirname, 'out', `${id}.png`), omitBackground: true });
    console.log('rendered', id);
  }
  await browser.close();
})();
