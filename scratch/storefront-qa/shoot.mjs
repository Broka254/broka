// TEMPORARY - scratch branch only (storefront 3.0 QA). Drives the
// storefront's production build (next start, against mock-api.mjs) in
// Chromium at phone, tablet and desktop widths: screenshots of every page,
// and measured checks - horizontal overflow, which navigation item is
// marked current, tap target sizes, content clear of the bottom bar, class
// names that came out undefined, the fonts that loaded, console errors -
// plus the flows the redesign added (the cart drawer, the filter panel, the
// gallery's arrows and swipe, the phone's buy bar) and the messaging flows
// the 2.0 harness covered.
import fs from 'node:fs'
import path from 'node:path'

import { chromium } from 'playwright'

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:3000'
const MOCK = process.env.MOCK_URL ?? 'http://127.0.0.1:4010'
const OUT = process.env.OUT_DIR ?? 'qa-out'
fs.mkdirSync(path.join(OUT, 'screenshots'), { recursive: true })

const IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1'
const ANDROID = 'Mozilla/5.0 (Linux; Android 14; SM-A155F) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36'
const IPAD = 'Mozilla/5.0 (iPad; CPU OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1'

const DEVICES = {
  'mobile-360': { viewport: { width: 360, height: 740 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true, userAgent: ANDROID },
  'mobile-390': { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true, userAgent: IPHONE },
  'tablet-768': { viewport: { width: 768, height: 1024 }, deviceScaleFactor: 1, isMobile: true, hasTouch: true, userAgent: IPAD },
  'desktop-1280': { viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 },
  'desktop-1440': { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 },
}

const PAGES = {
  home: '/store/clanix',
  shop: '/store/clanix/shop',
  product: '/store/clanix/p/l1',
  about: '/store/clanix/about',
  cart: '/store/clanix/cart',
  messages: '/store/clanix/messages?product=l1',
  inbox: '/store/account/messages',
  orders: '/store/orders',
  order: '/store/orders/o1',
  'home-small': '/store/java-home',
  'home-new': '/store/mama-mboga',
  'shop-filtered': '/store/clanix/shop?subcategory_id=phones&sort=price_low',
  'product-out': '/store/clanix/p/l6',
}

/** What each page is done loading looks like (client-read pages fill in after load). */
const READY = {
  messages: 'text=Your order is confirmed on our side',
  inbox: '[data-testid="conversation"]',
  orders: 'text=BK-7Q2M9XKD',
  order: '[data-testid="order-store"]',
  cart: '[data-testid="web-checkout"]',
}

const CART = [
  { id: 'l1', name: 'Samsung Galaxy A15 · 128 GB', price: 18500, unit: null, image: `${BASE}/store-assets/category-art/electronics/phones.webp`, emoji: '📱', href: '/store/clanix/p/l1', max: 5, qty: 1 },
  { id: 'l7', name: 'Anker 20,000 mAh power bank', price: 3800, unit: null, image: `${BASE}/store-assets/category-art/electronics/power-charging.webp`, emoji: '🔋', href: '/store/clanix/p/l7', max: 9, qty: 2 },
]

const results = { base: BASE, startedAt: new Date().toISOString(), checks: [], flows: [], shots: [], errors: [], console: [] }

const browser = await chromium.launch()

async function context(device, { signedIn = true, reduceMotion = true, cart = CART } = {}) {
  const ctx = await browser.newContext({ ...DEVICES[device], reducedMotion: reduceMotion ? 'reduce' : 'no-preference', locale: 'en-KE', timezoneId: 'Africa/Nairobi' })
  if (signedIn) {
    await ctx.addCookies([{ name: 'broka_at', value: 'qa-token', domain: '127.0.0.1', path: '/api/stores', httpOnly: true, sameSite: 'Lax' }])
  }
  await ctx.addInitScript((lines) => {
    try {
      if (!localStorage.getItem('broka_qa_seeded')) {
        if (lines.length) localStorage.setItem('broka_cart_v1_s1', JSON.stringify(lines))
        localStorage.setItem('broka_qa_seeded', '1')
      }
    } catch {
      // ignore
    }
  }, cart)
  return ctx
}

function watchConsole(page, label) {
  page.on('console', (msg) => {
    if (msg.type() === 'error' || msg.type() === 'warning') results.console.push(`${label} [${msg.type()}] ${msg.text().slice(0, 300)}`)
  })
  page.on('pageerror', (err) => results.console.push(`${label} [pageerror] ${String(err?.message ?? err).slice(0, 300)}`))
}

async function open(page, name) {
  await page.goto(BASE + PAGES[name], { waitUntil: 'networkidle' })
  if (READY[name]) await page.waitForSelector(READY[name], { timeout: 15_000 })
  await page.evaluate(() => document.fonts.ready)
  // Images and the sticky header settle.
  await page.waitForTimeout(450)
}

async function shot(page, file, opts = {}) {
  const target = path.join(OUT, 'screenshots', file)
  await page.screenshot({ path: target, ...opts })
  results.shots.push(file)
}

/** Measured on the page as the browser laid it out. */
function measure() {
  const doc = document.documentElement
  const visible = (el) => {
    if (!el) return false
    const s = getComputedStyle(el)
    const r = el.getBoundingClientRect()
    return s.display !== 'none' && s.visibility !== 'hidden' && r.width > 0 && r.height > 0
  }
  const marks = (sel) =>
    [...document.querySelectorAll(sel)].filter(visible).map((a) => `${(a.getAttribute('aria-label') || a.textContent || '').trim()}=${a.getAttribute('aria-current')}`)
  const sections = document.querySelector('nav[aria-label="Store sections"]')
  const bar = document.querySelector('nav[aria-label="Store menu"]')
  const tabs = bar ? [...bar.querySelectorAll('a, button')].filter(visible) : []
  const small = tabs
    .map((t) => ({ label: (t.getAttribute('aria-label') || t.textContent || '').trim(), ...t.getBoundingClientRect().toJSON() }))
    .filter((r) => r.width < 44 || r.height < 44)
  // Anything wider than the window, by element, for the report (inside a
  // scroller that is fine - overflowX is what counts).
  const wide = [...document.querySelectorAll('body *')]
    .filter((el) => {
      const r = el.getBoundingClientRect()
      return r.width > 0 && r.right > window.innerWidth + 1 && getComputedStyle(el).position !== 'fixed'
    })
    .slice(0, 5)
    .map((el) => `${el.tagName.toLowerCase()}.${String(el.className).slice(0, 60)} right=${Math.round(el.getBoundingClientRect().right)}`)
  return {
    overflowX: doc.scrollWidth - window.innerWidth,
    wide,
    undefinedClasses: [...document.querySelectorAll('[class]')].filter((el) => /\bundefined\b/.test(el.getAttribute('class'))).length,
    sectionsShown: visible(sections),
    bottomBarShown: visible(bar),
    sectionsCurrent: marks('nav[aria-label="Store sections"] [aria-current]'),
    bottomBarCurrent: marks('nav[aria-label="Store menu"] [aria-current]'),
    accountCurrent: marks('nav[aria-label="Your account"] [aria-current]'),
    smallTapTargets: small,
    fontsLoaded: [...document.fonts].filter((f) => f.status === 'loaded').map((f) => f.family),
    bodyFont: getComputedStyle(document.body).fontFamily.slice(0, 80),
    h1Font: document.querySelector('h1') ? getComputedStyle(document.querySelector('h1')).fontFamily.slice(0, 80) : null,
    firstProductTop: (() => {
      const card = document.querySelector('main article, main [class*="spotlight"]')
      return card ? Math.round(card.getBoundingClientRect().top + window.scrollY) : null
    })(),
  }
}

/** With the page scrolled to the end, is its last line clear of the bottom bar? */
async function endClearOfBar(page) {
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight))
  await page.waitForTimeout(300)
  return page.evaluate(() => {
    const bar = document.querySelector('nav[aria-label="Store menu"]')
    const lines = [...document.querySelectorAll('footer p, footer a, footer li')]
    const last = lines.sort((a, b) => b.getBoundingClientRect().bottom - a.getBoundingClientRect().bottom)[0]
    if (!bar || getComputedStyle(bar).display === 'none' || !last) return null
    const barTop = bar.getBoundingClientRect().top
    const lastBottom = last.getBoundingClientRect().bottom
    return { barTop: Math.round(barTop), lastBottom: Math.round(lastBottom), clear: lastBottom <= barTop + 0.5 }
  })
}

async function step(name, fn) {
  try {
    await fn()
  } catch (err) {
    results.errors.push(`${name}: ${err?.message ?? err}`)
    console.error(`FAILED ${name}:`, err)
  }
}

// ── Every page at every width: measured, and a screenshot of each ─────────
const FULL = ['home', 'shop', 'product', 'about', 'cart', 'home-small', 'home-new', 'order']
for (const device of Object.keys(DEVICES)) {
  const ctx = await context(device)
  const page = await ctx.newPage()
  watchConsole(page, device)
  for (const name of Object.keys(PAGES)) {
    await step(`${device} ${name}`, async () => {
      await open(page, name)
      const m = await page.evaluate(measure)
      const check = { device, page: name, ...m }
      await shot(page, `${name}-${device}.png`)
      // Up to 860px the store's sections are the bar along the bottom.
      if (DEVICES[device].viewport.width <= 860 && name !== 'messages') {
        check.endClearOfBottomBar = await endClearOfBar(page)
      }
      results.checks.push(check)
    })
  }
  // Whole pages, top to bottom, for the layout as a whole.
  if (device === 'desktop-1280' || device === 'mobile-390' || device === 'tablet-768') {
    for (const name of FULL) {
      await step(`${device} ${name} full`, async () => {
        await open(page, name)
        await shot(page, `${name}-${device}-full.jpg`, { fullPage: true, type: 'jpeg', quality: 70 })
      })
    }
  }
  await ctx.close()
}

// ── The cart drawer, from the header and from the bottom bar ──────────────
await step('drawer desktop', async () => {
  const ctx = await context('desktop-1280')
  const page = await ctx.newPage()
  watchConsole(page, 'drawer desktop')
  await open(page, 'product')
  await page.locator('header').getByRole('button', { name: /^Cart/ }).click()
  await page.getByRole('dialog').waitFor({ timeout: 5_000 })
  await page.waitForTimeout(500)
  await shot(page, 'drawer-desktop-1280.png')
  results.flows.push({ name: 'drawer desktop', opened: await page.getByRole('dialog').isVisible() })
  await ctx.close()
})

await step('drawer phone', async () => {
  const ctx = await context('mobile-390')
  const page = await ctx.newPage()
  watchConsole(page, 'drawer phone')
  await open(page, 'home')
  await page.getByRole('navigation', { name: 'Store menu' }).getByRole('button', { name: /^Cart/ }).click()
  await page.getByRole('dialog').waitFor({ timeout: 5_000 })
  await page.waitForTimeout(500)
  await shot(page, 'drawer-mobile-390.png')
  await ctx.close()
})

// ── The filter panel, open ─────────────────────────────────────────────────
await step('filters desktop', async () => {
  const ctx = await context('desktop-1280')
  const page = await ctx.newPage()
  await open(page, 'shop')
  await page.locator('summary[aria-label="Filters"]').click()
  await page.waitForTimeout(400)
  await shot(page, 'filters-desktop-1280.png')
  await ctx.close()
})

// ── A product card under the pointer ───────────────────────────────────────
await step('card hover', async () => {
  const ctx = await context('desktop-1280', { reduceMotion: false })
  const page = await ctx.newPage()
  await open(page, 'shop')
  const card = page.locator('main article').nth(1)
  await card.scrollIntoViewIfNeeded()
  await page.waitForTimeout(900)
  await card.hover()
  await page.waitForTimeout(900)
  const box = await card.boundingBox()
  await shot(page, 'card-hover-desktop-1280.png', { clip: { x: 0, y: Math.max(0, box.y - 60), width: 1280, height: Math.min(560, box.height + 120) } })
  await ctx.close()
})

// ── The store's home with motion on (the first screen) ────────────────────
await step('motion home', async () => {
  for (const device of ['desktop-1440', 'mobile-390']) {
    const ctx = await context(device, { reduceMotion: false })
    const page = await ctx.newPage()
    watchConsole(page, `motion ${device}`)
    await open(page, 'home')
    await page.waitForTimeout(1600)
    await shot(page, `home-${device}-motion.png`)
    await page.evaluate(() => window.scrollTo(0, 700))
    await page.waitForTimeout(900)
    await shot(page, `home-${device}-motion-scrolled.png`)
    await ctx.close()
  }
})

// ── The gallery: arrows on a computer, a drag across the photo ────────────
await step('gallery', async () => {
  const ctx = await context('desktop-1280')
  const page = await ctx.newPage()
  watchConsole(page, 'gallery')
  await open(page, 'product')
  const main = page.locator('main img[fetchpriority="high"]')
  const flow = { name: 'gallery', first: await main.getAttribute('alt') }
  await page.locator('main').getByRole('button', { name: 'Next photo' }).click({ force: true })
  await page.waitForTimeout(500)
  flow.afterNext = await main.getAttribute('alt')
  await shot(page, 'gallery-desktop-1280.png')
  const box = await main.boundingBox()
  await page.mouse.move(box.x + box.width * 0.7, box.y + box.height / 2)
  await page.mouse.down()
  await page.mouse.move(box.x + box.width * 0.25, box.y + box.height / 2 + 8, { steps: 6 })
  await page.mouse.up()
  await page.waitForTimeout(500)
  flow.afterSwipeLeft = await main.getAttribute('alt')
  await page.locator('main').getByRole('button', { name: 'Previous photo' }).click({ force: true })
  await page.waitForTimeout(300)
  flow.afterPrevious = await main.getAttribute('alt')
  results.flows.push(flow)
  await ctx.close()
})

// ── A phone's buy bar on the product page ──────────────────────────────────
await step('buy bar phone', async () => {
  const ctx = await context('mobile-390', { cart: [] })
  const page = await ctx.newPage()
  watchConsole(page, 'buy bar')
  await open(page, 'product')
  const bar = page.getByTestId('sticky-buy')
  const flow = { name: 'phone: buy bar', atTop: await bar.count() }
  const boxBottom = await page.evaluate(() => {
    const r = document.getElementById('buy-box').getBoundingClientRect()
    return r.bottom + window.scrollY
  })
  await page.evaluate((y) => window.scrollTo(0, y + 260), boxBottom)
  await page.waitForTimeout(700)
  flow.pastBuyBox = await bar.count()
  flow.layout = await page.evaluate(() => {
    const b = document.querySelector('[data-testid="sticky-buy"]')?.getBoundingClientRect()
    const nav = document.querySelector('nav[aria-label="Store menu"]')?.getBoundingClientRect()
    return b && nav ? { barBottom: Math.round(b.bottom), navTop: Math.round(nav.top), clear: b.bottom <= nav.top + 0.5, height: Math.round(b.height) } : null
  })
  await shot(page, 'product-mobile-390-buybar.png')
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight))
  await page.waitForTimeout(700)
  flow.atFooter = await bar.count()
  await page.evaluate((y) => window.scrollTo(0, y + 260), boxBottom)
  await page.waitForTimeout(700)
  await bar.getByRole('button', { name: 'Buy now' }).click()
  await page.waitForURL('**/store/clanix/cart', { timeout: 10_000 })
  flow.buyNowWentTo = new URL(page.url()).pathname
  flow.cartAfter = await page.evaluate(() => JSON.parse(localStorage.getItem('broka_cart_v1_s1') ?? '[]').map((l) => `${l.id}:${l.qty}`))
  results.flows.push(flow)
  await ctx.close()
})

// ── Messaging on a computer: opens at the newest, holds while reading back ──
await step('messaging desktop flows', async () => {
  const ctx = await context('desktop-1280')
  const page = await ctx.newPage()
  await open(page, 'messages')
  const log = page.getByRole('log')
  const atBottom = () => log.evaluate((el) => el.scrollHeight - el.scrollTop - el.clientHeight <= 4)
  const flow = { name: 'desktop: conversation scroll', openedAtNewest: await atBottom() }

  await log.evaluate((el) => {
    el.scrollTop = 0
    el.dispatchEvent(new Event('scroll'))
  })
  await fetch(`${MOCK}/__qa/reply`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ thread: 'product:l1', content: 'We also have the light blue one in stock, if you prefer it.' }),
  })
  await page.waitForTimeout(5_600)
  await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')))
  const thread = page.getByTestId('enquiry-thread')
  await thread.getByText('We also have the light blue one in stock').waitFor({ timeout: 10_000 })
  await page.getByRole('button', { name: 'New messages' }).waitFor({ timeout: 5_000 })
  flow.heldWhileReadingBack = await log.evaluate((el) => el.scrollTop < 40)
  await page.getByRole('button', { name: 'New messages' }).click()
  await page.waitForTimeout(800)
  flow.newMessagesButtonGoesToNewest = await atBottom()

  const box = page.getByLabel('Your message')
  await box.fill('Is it the same price for the light blue one?')
  await box.press('Enter')
  await page.getByText('Sending…').waitFor({ timeout: 3_000 })
  flow.sendingShownAtOnce = true
  await page.getByText('Sending…').waitFor({ state: 'detached', timeout: 10_000 })
  await page.waitForTimeout(1_500)
  flow.sentOnce = (await thread.getByText('Is it the same price for the light blue one?').count()) === 1
  flow.followedAfterSending = await atBottom()
  await shot(page, 'messages-desktop-1280-after-send.png')
  results.flows.push(flow)
  await ctx.close()
})

// ── Messaging on a phone: a chat screen, the box in reach ──────────────────
await step('messaging phone flows', async () => {
  const ctx = await context('mobile-390')
  const page = await ctx.newPage()
  await open(page, 'messages')
  const flow = { name: 'phone: chat screen' }
  const layout = () =>
    page.evaluate(() => {
      const box = document.querySelector('textarea')
      const form = box?.closest('form')
      const r = form?.getBoundingClientRect()
      return {
        composerInView: Boolean(r && r.top >= 0 && r.bottom <= window.innerHeight + 1),
        storeHeaderHidden: getComputedStyle(document.querySelector('header[data-section="messages"]')).display === 'none',
        bottomBarAbsent: !document.querySelector('nav[aria-label="Store menu"]'),
        overflowX: document.documentElement.scrollWidth - window.innerWidth,
      }
    })
  flow.onOpen = await layout()
  await fetch(`${MOCK}/__qa/fail-next`, { method: 'POST' })
  const box = page.getByLabel('Your message')
  await box.fill('Can you deliver it this evening?')
  await page.getByRole('button', { name: 'Send' }).click()
  await page.getByRole('button', { name: 'Retry' }).waitFor({ timeout: 5_000 })
  flow.failureExplained = (await page.getByRole('alert').filter({ hasText: 'Not sent' }).textContent())?.trim()
  await shot(page, 'messages-mobile-390-failed.png')
  await page.getByRole('button', { name: 'Retry' }).click()
  await page.getByRole('button', { name: 'Retry' }).waitFor({ state: 'detached', timeout: 10_000 })
  await page.waitForTimeout(1_800)
  flow.retriedOnce = (await page.getByTestId('enquiry-thread').getByText('Can you deliver it this evening?').count()) === 1
  results.flows.push(flow)
  await ctx.close()
})

// ── Android: the "Open in the app" banner over the store's home ───────────
await step('android banner', async () => {
  const ctx = await context('mobile-360')
  const page = await ctx.newPage()
  await open(page, 'home')
  await shot(page, 'home-mobile-360-android.png')
  await ctx.close()
})

// ── Signed out: the cart's checkout asks for the SMS code ─────────────────
await step('signed out', async () => {
  const ctx = await context('mobile-390', { signedIn: false })
  const page = await ctx.newPage()
  await page.goto(BASE + PAGES.cart, { waitUntil: 'networkidle' })
  await page.getByTestId('sign-in').waitFor({ timeout: 10_000 })
  await page.waitForTimeout(400)
  await shot(page, 'cart-mobile-390-signed-out-full.jpg', { fullPage: true, type: 'jpeg', quality: 70 })
  await ctx.close()
})

await browser.close()

// ── Summary ────────────────────────────────────────────────────────────────
const overflow = results.checks.filter((c) => c.overflowX > 0)
const smallTargets = results.checks.filter((c) => c.smallTapTargets?.length)
const covered = results.checks.filter((c) => c.endClearOfBottomBar && !c.endClearOfBottomBar.clear)
const undefinedClasses = results.checks.filter((c) => c.undefinedClasses > 0)
results.summary = {
  pagesChecked: results.checks.length,
  horizontalOverflow: overflow.map((c) => `${c.device} ${c.page}: ${c.overflowX}px ${c.wide.join('; ')}`),
  smallTapTargets: smallTargets.map((c) => `${c.device} ${c.page}: ${JSON.stringify(c.smallTapTargets)}`),
  footerUnderBottomBar: covered.map((c) => `${c.device} ${c.page}: ${JSON.stringify(c.endClearOfBottomBar)}`),
  undefinedClasses: undefinedClasses.map((c) => `${c.device} ${c.page}: ${c.undefinedClasses}`),
  fonts: [...new Set(results.checks.flatMap((c) => c.fontsLoaded ?? []))],
  consoleProblems: results.console.length,
  errors: results.errors.length,
}
results.finishedAt = new Date().toISOString()
fs.writeFileSync(path.join(OUT, 'results.json'), JSON.stringify(results, null, 2))
console.log(JSON.stringify(results.summary, null, 2))
console.log(JSON.stringify(results.flows, null, 2))
console.log(results.console.slice(0, 40).join('\n'))
