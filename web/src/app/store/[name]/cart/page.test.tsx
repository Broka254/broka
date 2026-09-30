import { beforeEach, describe, expect, it, vi } from 'vitest'

import type { Store } from '@/lib/types'

class Navigated extends Error {
  constructor(readonly kind: string, readonly to?: string) {
    super(`${kind} ${to ?? ''}`)
  }
}
vi.mock('next/navigation', () => ({
  notFound: () => {
    throw new Navigated('notFound')
  },
  redirect: (to: string) => {
    throw new Navigated('redirect', to)
  },
  permanentRedirect: (to: string) => {
    throw new Navigated('permanentRedirect', to)
  },
  useRouter: () => ({ push: vi.fn() }),
}))

const api = vi.hoisted(() => ({ getStore: vi.fn() }))
vi.mock('@/lib/api', () => api)

const { default: CartPage, generateMetadata } = await import('./page')

const store = (over: Partial<Store> = {}) =>
  ({ id: 's1', name: 'Clanix', slug: 'clanix', is_active: true, photo_images: [], photos: [], ...over }) as Store

async function whereTo(name: string): Promise<Navigated | null> {
  try {
    await CartPage({ params: Promise.resolve({ name }) })
    return null
  } catch (e) {
    if (e instanceof Navigated) return e
    throw e
  }
}

describe('cart page', () => {
  beforeEach(() => api.getStore.mockReset())

  it('renders for an open store, and is never indexed', async () => {
    api.getStore.mockResolvedValue(store())
    expect(await whereTo('clanix')).toBeNull()
    expect((await generateMetadata({ params: Promise.resolve({ name: 'clanix' }) })).robots).toEqual({ index: false })
  })

  it('one address per store, and a paused store sends visitors to its page', async () => {
    api.getStore.mockResolvedValue(store())
    expect(await whereTo('Clanix')).toMatchObject({ kind: 'permanentRedirect', to: '/store/clanix/cart' })
    api.getStore.mockResolvedValue(store({ is_active: false }))
    expect(await whereTo('clanix')).toMatchObject({ kind: 'redirect', to: '/store/clanix' })
    api.getStore.mockResolvedValue(null)
    expect((await whereTo('nope'))?.kind).toBe('notFound')
  })
})
