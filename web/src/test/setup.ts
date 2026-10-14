import { cleanup } from '@testing-library/react'
import { afterEach, vi } from 'vitest'

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.unstubAllEnvs()
  try {
    localStorage.clear()
    sessionStorage.clear()
  } catch {
    // Not every test has a DOM.
  }
})
