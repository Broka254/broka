// Display formatting shared by the storefront's pages and components.

const kes = new Intl.NumberFormat('en-KE', { maximumFractionDigits: 0 })

/** "KES 18,000" */
export function formatPrice(price: number): string {
  return `KES ${kes.format(Math.round(price))}`
}

/** "KES 3,500 / bag" when the price is for one unit (a listing's
 *  price_unit), else the price alone - a per-bag price shown bare reads as
 *  the price of the whole lot. */
export function formatUnitPrice(price: number, unit: string | null | undefined): string {
  return unit ? `${formatPrice(price)} / ${unit}` : formatPrice(price)
}

/** "Starehe, Nairobi" from whichever parts exist, or null. */
export function placeLine(...parts: Array<string | null | undefined>): string | null {
  const seen = new Set<string>()
  const kept: string[] = []
  for (const p of parts) {
    const v = p?.trim()
    if (v && !seen.has(v.toLowerCase())) {
      seen.add(v.toLowerCase())
      kept.push(v)
    }
  }
  return kept.length ? kept.join(', ') : null
}

/** The year from an ISO timestamp, or null. */
export function yearOf(iso: string | null | undefined): number | null {
  if (!iso) return null
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? null : d.getUTCFullYear()
}

/** "1 product" / "3 products" */
export function plural(n: number, word: string): string {
  return `${n} ${word}${n === 1 ? '' : 's'}`
}

/** Shortened text for meta descriptions: whole words, at most [max] characters. */
export function clip(text: string, max = 160): string {
  const flat = text.replace(/\s+/g, ' ').trim()
  if (flat.length <= max) return flat
  const cut = flat.slice(0, max - 1)
  const lastSpace = cut.lastIndexOf(' ')
  return `${(lastSpace > max * 0.6 ? cut.slice(0, lastSpace) : cut).trimEnd()}…`
}

/** "New", "Used", "Refurbished" */
export function conditionLabel(condition: string | null | undefined): string | null {
  if (!condition) return null
  const c = condition.trim().toLowerCase()
  return c ? c[0]!.toUpperCase() + c.slice(1) : null
}
