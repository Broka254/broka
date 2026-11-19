'use client'

// The light that follows the pointer across a card: one listener for the
// whole page, which tells the element under the pointer marked
// [data-spot] where the pointer is, as --mx and --my (its CSS draws the
// light - shop.module.css .product::after, store-landing.module.css). Only
// with a mouse or trackpad and with motion allowed; a phone, or a visitor
// who asked for less motion, gets the cards as they are. At most one style
// write per frame, and none while the pointer is outside every card.
import { useEffect } from 'react'

export function Spotlight() {
  useEffect(() => {
    // A browser that can't say what pointer it has gets no light: the
    // cards are complete without it.
    if (typeof window.matchMedia !== 'function') return
    const fine = window.matchMedia('(hover: hover) and (pointer: fine)')
    const still = window.matchMedia('(prefers-reduced-motion: reduce)')
    if (!fine.matches || still.matches) return
    let frame = 0
    let target: HTMLElement | null = null
    let x = 0
    let y = 0
    const paint = () => {
      frame = 0
      if (!target) return
      const box = target.getBoundingClientRect()
      target.style.setProperty('--mx', `${Math.round(x - box.left)}px`)
      target.style.setProperty('--my', `${Math.round(y - box.top)}px`)
    }
    const onMove = (e: PointerEvent) => {
      const el = e.target instanceof Element ? e.target.closest<HTMLElement>('[data-spot]') : null
      target = el
      if (!el) return
      x = e.clientX
      y = e.clientY
      if (!frame) frame = requestAnimationFrame(paint)
    }
    document.addEventListener('pointermove', onMove, { passive: true })
    return () => {
      document.removeEventListener('pointermove', onMove)
      cancelAnimationFrame(frame)
    }
  }, [])
  return null
}
