'use client'

// The glowing connected dots behind every page, as in the app. Drawn on one
// canvas fixed behind the content, at up to 30 frames a second; it stops
// while the tab is hidden, and draws a single still frame for visitors
// whose system asks for reduced motion.
import { useEffect, useRef } from 'react'

import { buildConstellation } from '@/lib/constellation'

const VIOLET = [139, 92, 246] as const
const BLUE = [59, 130, 246] as const
const LOOP_SECONDS = 24
const FRAME_MS = 1000 / 30

function glowSprite(rgb: readonly number[]): HTMLCanvasElement {
  const size = 64
  const c = document.createElement('canvas')
  c.width = c.height = size
  const g = c.getContext('2d')!
  const grad = g.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2)
  grad.addColorStop(0, `rgba(${rgb.join(',')},1)`)
  grad.addColorStop(1, `rgba(${rgb.join(',')},0)`)
  g.fillStyle = grad
  g.fillRect(0, 0, size, size)
  return c
}

export function Constellation() {
  const ref = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = ref.current
    const ctx = canvas?.getContext('2d')
    if (!canvas || !ctx) return

    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)')
    const sprites = { violet: glowSprite(VIOLET), blue: glowSprite(BLUE) }
    let width = 0
    let height = 0
    let field = buildConstellation(1.8)
    let frame = 0
    let lastDraw = 0
    const start = performance.now()

    const resize = () => {
      const dpr = Math.min(window.devicePixelRatio || 1, 2)
      width = window.innerWidth
      height = window.innerHeight
      canvas.width = Math.round(width * dpr)
      canvas.height = Math.round(height * dpr)
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      field = buildConstellation(height / Math.max(width, 1))
    }

    const draw = (seconds: number) => {
      const a = (seconds / LOOP_SECONDS) * Math.PI * 2
      // Layer 1: a violet glow drifting slowly around the upper half.
      const cx = width * (0.5 + Math.sin(a) * 0.175)
      const cy = height * (0.5 + (Math.cos(a) * 0.22 - 0.35) * 0.5)
      const radius = Math.max(width, height) * 0.75
      const bg = ctx.createRadialGradient(cx, cy, 0, cx, cy, radius)
      bg.addColorStop(0, '#140b2e')
      bg.addColorStop(0.45, '#080618')
      bg.addColorStop(1, '#03040a')
      ctx.fillStyle = bg
      ctx.fillRect(0, 0, width, height)

      // Layer 2: the mesh. Edges brighten in a slow wave across the sky.
      const t = seconds
      ctx.lineWidth = 0.8
      for (const [i, j] of field.edges) {
        const p = field.nodes[i]!
        const q = field.nodes[j]!
        const pulse = 0.5 + 0.5 * Math.sin(t * Math.PI * 2 * 0.22 - ((p.x + q.x) / 2) * 3.2)
        ctx.strokeStyle = `rgba(139,92,246,${0.14 + 0.12 * pulse})`
        ctx.beginPath()
        ctx.moveTo(p.x * width, p.y * height)
        ctx.lineTo(q.x * width, q.y * height)
        ctx.stroke()
      }
      field.nodes.forEach((n, i) => {
        const pulse = 0.5 + 0.5 * Math.sin(t * Math.PI * 2 * 0.2 + n.phase * 4)
        const opacity = 0.55 + 0.45 * pulse
        const blue = i % 3 === 0
        const rgb = blue ? BLUE : VIOLET
        const x = n.x * width
        const y = n.y * height
        const glow = n.size * 3.4 * 2
        ctx.globalAlpha = 0.24 * opacity
        ctx.drawImage(blue ? sprites.blue : sprites.violet, x - glow / 2, y - glow / 2, glow, glow)
        ctx.globalAlpha = opacity
        ctx.fillStyle = `rgb(${rgb.join(',')})`
        ctx.beginPath()
        ctx.arc(x, y, n.size, 0, Math.PI * 2)
        ctx.fill()
        ctx.globalAlpha = 0.6 * opacity
        ctx.fillStyle = '#fff'
        ctx.beginPath()
        ctx.arc(x, y, n.size * 0.42, 0, Math.PI * 2)
        ctx.fill()
      })
      ctx.globalAlpha = 1
    }

    const tick = (now: number) => {
      frame = requestAnimationFrame(tick)
      if (now - lastDraw < FRAME_MS) return
      lastDraw = now
      draw((now - start) / 1000)
    }

    const run = () => {
      cancelAnimationFrame(frame)
      if (reduced.matches) {
        draw(0)
      } else if (!document.hidden) {
        frame = requestAnimationFrame(tick)
      }
    }

    const onResize = () => {
      resize()
      draw((performance.now() - start) / 1000)
    }

    resize()
    run()
    window.addEventListener('resize', onResize)
    document.addEventListener('visibilitychange', run)
    reduced.addEventListener('change', run)
    return () => {
      cancelAnimationFrame(frame)
      window.removeEventListener('resize', onResize)
      document.removeEventListener('visibilitychange', run)
      reduced.removeEventListener('change', run)
    }
  }, [])

  return (
    <>
      <canvas ref={ref} aria-hidden="true" className="constellation" />
      <div aria-hidden="true" className="constellation-vignette" />
    </>
  )
}
