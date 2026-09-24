// BROKA's 16 top-level categories with the emoji and colours the app uses
// for them (flutter_app/lib/features/categories/domain/category_visual.dart).
// categories.test.ts checks this list against the backend's own
// (backend/api/domains/categories/seed.py), so they can't drift apart.

export interface CategoryVisual {
  name: string
  emoji: string
  gradient: [string, string, ...string[]]
}

const C = {
  gold: '#8B5CF6',
  neonBlue: '#3B82F6',
  neonGreen: '#10B981',
  neonPurple: '#8B5CF6',
  neonPink: '#F472B6',
  neonCyan: '#22D3EE',
  warning: '#F59E0B',
  zoneAmber: '#FBBF24',
  zoneOrange: '#FF6B4A',
} as const

export const CATEGORIES: CategoryVisual[] = [
  { name: 'Vehicles', emoji: '🚗', gradient: [C.zoneOrange, C.neonPurple] },
  { name: 'Property', emoji: '🏠', gradient: [C.neonBlue, C.neonGreen] },
  { name: 'Electronics', emoji: '📱', gradient: [C.neonCyan, C.neonBlue] },
  { name: 'Gaming', emoji: '🎮', gradient: [C.neonPurple, C.neonPink] },
  { name: 'Home & Furniture', emoji: '🛋️', gradient: [C.zoneAmber, C.gold] },
  { name: 'Fashion', emoji: '👗', gradient: [C.neonPink, C.gold] },
  { name: 'Agriculture', emoji: '🌾', gradient: [C.neonGreen, C.zoneAmber] },
  { name: 'Construction', emoji: '🏗️', gradient: [C.zoneOrange, C.warning] },
  { name: 'Beauty & Personal Care', emoji: '💄', gradient: [C.neonPink, C.zoneAmber] },
  { name: 'Sports & Fitness', emoji: '⚽', gradient: [C.neonGreen, C.neonBlue] },
  { name: 'Books & Education', emoji: '📚', gradient: [C.gold, C.neonBlue] },
  { name: 'Music & Instruments', emoji: '🎸', gradient: [C.neonPink, C.neonPurple] },
  { name: 'Business & Industrial', emoji: '🏭', gradient: [C.neonBlue, C.warning] },
  { name: 'Pets & Animals', emoji: '🐾', gradient: [C.neonGreen, C.neonPink] },
  { name: 'Services', emoji: '🛠️', gradient: [C.neonCyan, C.gold] },
  { name: 'Other', emoji: '🛍️', gradient: ['#8B5CF6', '#3B82F6', '#22D3EE'] },
]

const byKey = new Map(CATEGORIES.map((c) => [c.name.toLowerCase(), c]))

/** The visual for a category name (any case); "Other" for anything unknown. */
export function categoryVisual(name: string | null | undefined): CategoryVisual {
  return byKey.get((name ?? '').trim().toLowerCase()) ?? byKey.get('other')!
}

/** The canonical spelling of a category name, or null if it isn't one. */
export function canonicalCategory(name: string | null | undefined): string | null {
  return byKey.get((name ?? '').trim().toLowerCase())?.name ?? null
}

export function gradientCss(colors: readonly string[], angle = 135): string {
  return `linear-gradient(${angle}deg, ${colors.join(', ')})`
}
