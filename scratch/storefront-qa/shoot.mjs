// TEMPORARY - scratch branch only. Drives the storefront's production build
// (next start, against mock-api.mjs) in Chromium at phone, tablet and
// desktop widths: screenshots of the key pages, and measured checks -
// horizontal overflow, which navigation item is marked current, tap target
// sizes, content clear of the bottom bar, the message box in view with a
// (simulated) keyboard up, and how the conversation scrolls.
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

const results = { base: BASE, startedAt: new Date().toISOString(), checks: [], flows: [], shots: [], errors: [] }

const browser = await chromium.launch()

async function context(device, { signedIn = true, reduceMotion = true } = {}) {
  const ctx = await browser.newContext({ ...DEVICES[device], reducedMotion: reduceMotion ? 'reduce' : 'no-preference', locale: 'en-KE', timezoneId: 'Africa/Nairobi' })
  if (signedIn) {
    await ctx.addCookies([{ name: 'broka_at', value: 'qa-token', domain: '127.0.0.1', path: '/api/stores', httpOnly: true, sameSite: 'Lax' }])
  }
  await ctx.addInitScript((cart) => {
    try {
      if (!localStorage.getItem('broka_qa_seeded')) {
        localStorage.setItem('broka_cart_v1_s1', JSON.stringify(cart))
        localStorage.setItem('broka_qa_seeded', '1')
      }
    } catch {
      // ignore
    }
  }, CART)
  return ctx
}

async function open(page, name) {
  await page.goto(BASE + PAGES[name], { waitUntil: 'networkidle' })
  if (READY[name]) await page.waitForSelector(READY[name], { timeout: 15_000 })
  // Images and the sticky header settle.
  await page.waitForTimeout(400)
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
  // Anything wider than the window, by element, for the report.
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
    sectionsShown: visible(sections),
    bottomBarShown: visible(bar),
    sectionsCurrent: marks('nav[aria-label="Store sections"] [aria-current]'),
    bottomBarCurrent: marks('nav[aria-label="Store menu"] [aria-current]'),
    accountCurrent: marks('nav[aria-label="Your account"] [aria-current]'),
    smallTapTargets: small,
  }
}

/** With the page scrolled to the end, is its last line clear of the bottom bar? */
async function endClearOfBar(page) {
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight))
  await page.waitForTimeout(250)
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
const KEY_SHOTS = new Set(['home', 'shop', 'product', 'messages', 'orders', 'order', 'inbox', 'cart', 'about'])
for (const device of Object.keys(DEVICES)) {
  const ctx = await context(device)
  const page = await ctx.newPage()
  for (const name of Object.keys(PAGES)) {
    await step(`${device} ${name}`, async () => {
      await open(page, name)
      const m = await page.evaluate(measure)
      const check = { device, page: name, ...m }
      if (KEY_SHOTS.has(name)) await shot(page, `${name}-${device}.png`)
      // Up to 860px the store's sections are the bar along the bottom.
      if (DEVICES[device].viewport.width <= 860 && name !== 'messages') {
        check.endClearOfBottomBar = await endClearOfBar(page)
      }
      results.checks.push(check)
    })
  }
  // Whole pages, top to bottom, for the layout as a whole.
  if (device === 'desktop-1280' || device === 'mobile-390') {
    for (const name of ['home', 'product', 'order']) {
      await step(`${device} ${name} full`, async () => {
        await open(page, name)
        await shot(page, `${name}-${device}-full.jpg`, { fullPage: true, type: 'jpeg', quality: 72 })
      })
    }
  }
  await ctx.close()
}

// ── Messaging on a computer: opens at the newest, holds while reading back ──
await step('messaging desktop flows', async () => {
  const ctx = await context('desktop-1280')
  const page = await ctx.newPage()
  await open(page, 'messages')
  const log = page.getByRole('log')
  const atBottom = () => log.evaluate((el) => el.scrollHeight - el.scrollTop - el.clientHeight <= 4)
  const flow = { name: 'desktop: conversation scroll', openedAtNewest: await atBottom() }

  // Reading back, the store answers: the view stays put; a button says so.
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
  await page.getByText('We also have the light blue one in stock').waitFor({ timeout: 10_000 })
  await page.getByRole('button', { name: 'New messages' }).waitFor({ timeout: 5_000 })
  flow.heldWhileReadingBack = await log.evaluate((el) => el.scrollTop < 40)
  await shot(page, 'messages-desktop-1280-new-messages.png')
  await page.getByRole('button', { name: 'New messages' }).click()
  await page.waitForTimeout(800)
  flow.newMessagesButtonGoesToNewest = await atBottom()

  // Sending: shown at once as "Sending…", then the stored copy, once.
  const box = page.getByLabel('Your message')
  await box.fill('Is it the same price for the light blue one?')
  await box.press('Enter')
  await page.getByText('Sending…').waitFor({ timeout: 3_000 })
  flow.sendingShownAtOnce = true
  await shot(page, 'messages-desktop-1280-sending.png')
  await page.getByText('Sending…').waitFor({ state: 'detached', timeout: 10_000 })
  await page.waitForTimeout(1_500)
  flow.sentOnce = (await page.getByText('Is it the same price for the light blue one?').count()) === 1
  flow.followedAfterSending = await atBottom()
  await shot(page, 'messages-desktop-1280.png')
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
      const bubbles = [...document.querySelectorAll('[role="log"] p')].filter((p) => p.textContent?.trim())
      const last = bubbles.at(-1)
      const r = form?.getBoundingClientRect()
      return {
        composerInView: Boolean(r && r.top >= 0 && r.bottom <= window.innerHeight + 1),
        composerBottom: r ? Math.round(r.bottom) : null,
        viewportHeight: window.innerHeight,
        newestAboveComposer: Boolean(r && last && last.getBoundingClientRect().bottom <= r.top + 1),
        storeHeaderHidden: getComputedStyle(document.querySelector('header[data-section="messages"]')).display === 'none',
        bottomBarAbsent: !document.querySelector('nav[aria-label="Store menu"]'),
        overflowX: document.documentElement.scrollWidth - window.innerWidth,
      }
    })
  flow.onOpen = await layout()

  // The keyboard: the box focused and the window shortened by its height
  // (what Chrome on Android does with interactive-widget=resizes-content).
  await page.getByLabel('Your message').focus()
  await page.setViewportSize({ width: 390, height: 844 - 336 })
  await page.waitForTimeout(600)
  flow.withKeyboard = await layout()
  await shot(page, 'messages-mobile-390-keyboard.png')
  await page.setViewportSize({ width: 390, height: 844 })
  await page.waitForTimeout(400)

  // A message the limit refuses: it stays, says why, offers Retry.
  await fetch(`${MOCK}/__qa/fail-next`, { method: 'POST' })
  const box = page.getByLabel('Your message')
  await box.fill('Can you deliver it this evening?')
  await page.getByRole('button', { name: 'Send' }).click()
  await page.getByRole('button', { name: 'Retry' }).waitFor({ timeout: 5_000 })
  flow.failureExplained = (await page.getByRole('alert').textContent())?.trim()
  await shot(page, 'messages-mobile-390-failed.png')
  await page.getByRole('button', { name: 'Retry' }).click()
  await page.getByRole('button', { name: 'Retry' }).waitFor({ state: 'detached', timeout: 10_000 })
  await page.waitForTimeout(1_800)
  flow.retriedOnce = (await page.getByText('Can you deliver it this evening?').count()) === 1
  await shot(page, 'messages-mobile-390.png')
  results.flows.push(flow)
  await ctx.close()
})

// ── Android: the "Open in the app" banner over the chat screen ────────────
await step('messaging android banner', async () => {
  const ctx = await context('mobile-360')
  const page = await ctx.newPage()
  await open(page, 'messages')
  await shot(page, 'messages-mobile-360-android.png')
  await ctx.close()
})

// ── Signed out: messages and orders ask for the SMS code, nothing else ─────
await step('signed out', async () => {
  const ctx = await context('mobile-390', { signedIn: false })
  const page = await ctx.newPage()
  await page.goto(BASE + PAGES.messages, { waitUntil: 'networkidle' })
  await page.getByText('Sign in to message Clanix').waitFor({ timeout: 10_000 })
  await shot(page, 'messages-mobile-390-signed-out.png')
  await ctx.close()
})

// ── The tablet in landscape: between the phone and the computer layouts ────
await step('tablet landscape messages', async () => {
  const ctx = await browser.newContext({ viewport: { width: 1024, height: 768 }, reducedMotion: 'reduce', userAgent: IPAD, isMobile: true, hasTouch: true })
  await ctx.addCookies([{ name: 'broka_at', value: 'qa-token', domain: '127.0.0.1', path: '/api/stores', httpOnly: true, sameSite: 'Lax' }])
  const page = await ctx.newPage()
  await open(page, 'messages')
  results.checks.push({ device: 'tablet-1024-landscape', page: 'messages', ...(await page.evaluate(measure)) })
  await shot(page, 'messages-tablet-1024.png')
  await ctx.close()
})

await browser.close()

// ── Summary ────────────────────────────────────────────────────────────────
const overflow = results.checks.filter((c) => c.overflowX > 0)
const smallTargets = results.checks.filter((c) => c.smallTapTargets?.length)
const covered = results.checks.filter((c) => c.endClearOfBottomBar && !c.endClearOfBottomBar.clear)
results.summary = {
  pagesChecked: results.checks.length,
  horizontalOverflow: overflow.map((c) => `${c.device} ${c.page}: ${c.overflowX}px ${c.wide.join('; ')}`),
  smallTapTargets: smallTargets.map((c) => `${c.device} ${c.page}: ${JSON.stringify(c.smallTapTargets)}`),
  footerUnderBottomBar: covered.map((c) => `${c.device} ${c.page}: ${JSON.stringify(c.endClearOfBottomBar)}`),
  errors: results.errors.length,
}
results.finishedAt = new Date().toISOString()
fs.writeFileSync(path.join(OUT, 'results.json'), JSON.stringify(results, null, 2))
console.log(JSON.stringify(results.summary, null, 2))
console.log(JSON.stringify(results.flows, null, 2))
