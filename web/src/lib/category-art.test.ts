import { existsSync } from 'node:fs'
import { join } from 'node:path'

import { describe, expect, it } from 'vitest'

import { categoryArtPath } from './category-art'

describe('store category artwork', () => {
  it('uses the same exact subcategory art as the Flutter store shelf', () => {
    const laptops = categoryArtPath('Electronics', 'Laptops & Computers')
    const networking = categoryArtPath('Electronics', 'Networking')

    expect(laptops).toBe('/store-assets/category-art/electronics/laptops-tablets.webp')
    expect(networking).toBe('/store-assets/category-art/electronics/networking.webp')
    expect(existsSync(join(process.cwd(), 'public', laptops!.slice(1)))).toBe(true)
    expect(existsSync(join(process.cwd(), 'public', networking!.slice(1)))).toBe(true)
  })

  it('falls back to the parent art for unfiled or newly added subcategories', () => {
    expect(categoryArtPath('Fashion', 'A new category')).toBe('/store-assets/category-art/fashion.webp')
    expect(categoryArtPath('Other')).toBe('/store-assets/category-art/services.webp')
    expect(categoryArtPath(null)).toBeNull()
  })
})
