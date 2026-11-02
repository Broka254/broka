'use client'

import { useEffect, useRef, useState } from 'react'

import { asset } from '@/lib/links'

export function BrandBackground() {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const [reducedMotion, setReducedMotion] = useState(false)

  useEffect(() => {
    const query = window.matchMedia('(prefers-reduced-motion: reduce)')
    const update = () => setReducedMotion(query.matches)
    update()
    query.addEventListener('change', update)
    return () => query.removeEventListener('change', update)
  }, [])

  useEffect(() => {
    if (reducedMotion) return
    const canvas = canvasRef.current
    const context = canvas?.getContext('2d')
    if (!canvas || !context) return

    type Particle = { x: number; y: number; vx: number; vy: number; radius: number; alpha: number; hue: number; phase: number }
    let particles: Particle[] = []
    let width = 0
    let height = 0
    let dpr = 1
    let frame = 0
    let last = performance.now()
    const random = (min: number, max: number) => min + Math.random() * (max - min)
    const resize = () => {
      const rect = canvas.getBoundingClientRect()
      dpr = Math.min(window.devicePixelRatio || 1, window.innerWidth < 760 ? 1.35 : 1.6)
      width = Math.max(1, rect.width)
      height = Math.max(1, rect.height)
      canvas.width = Math.round(width * dpr)
      canvas.height = Math.round(height * dpr)
      context.setTransform(dpr, 0, 0, dpr, 0, 0)
      const count = Math.round(Math.min(105, Math.max(34, (width * height) / 18500)))
      particles = Array.from({ length: count }, () => ({
        x: random(0, width), y: random(0, height), vx: random(-0.08, 0.08), vy: random(-0.07, 0.07),
        radius: random(0.7, 1.8), alpha: random(0.18, 0.55), hue: Math.random() > 0.62 ? 205 : 260, phase: random(0, Math.PI * 2),
      }))
    }
    const draw = (now: number) => {
      const delta = Math.min(32, now - last)
      last = now
      const seconds = now / 1000
      context.clearRect(0, 0, width, height)
      for (const particle of particles) {
        particle.vx *= 0.985
        particle.vy *= 0.985
        particle.x += particle.vx * delta
        particle.y += particle.vy * delta
        if (particle.x < -8) particle.x = width + 8
        if (particle.x > width + 8) particle.x = -8
        if (particle.y < -8) particle.y = height + 8
        if (particle.y > height + 8) particle.y = -8
        const alpha = particle.alpha * (0.82 + Math.sin(seconds * 0.55 + particle.phase) * 0.18)
        const gradient = context.createRadialGradient(particle.x, particle.y, 0, particle.x, particle.y, particle.radius * 5.5)
        gradient.addColorStop(0, `hsla(${particle.hue}, 88%, 78%, ${alpha})`)
        gradient.addColorStop(0.28, `hsla(${particle.hue}, 88%, 62%, ${alpha * 0.42})`)
        gradient.addColorStop(1, `hsla(${particle.hue}, 88%, 60%, 0)`)
        context.fillStyle = gradient
        context.beginPath()
        context.arc(particle.x, particle.y, particle.radius * 5.5, 0, Math.PI * 2)
        context.fill()
      }
      for (let i = 0; i < particles.length; i += 1) {
        for (let j = i + 1; j < particles.length; j += 1) {
          const a = particles[i]!
          const b = particles[j]!
          const distance = Math.hypot(a.x - b.x, a.y - b.y)
          if (distance > 145) continue
          context.strokeStyle = `rgba(129, 117, 255, ${(1 - distance / 145) * 0.075})`
          context.lineWidth = 0.7
          context.beginPath()
          context.moveTo(a.x, a.y)
          context.lineTo(b.x, b.y)
          context.stroke()
        }
      }
      frame = requestAnimationFrame(draw)
    }
    resize()
    frame = requestAnimationFrame(draw)
    window.addEventListener('resize', resize)
    return () => {
      cancelAnimationFrame(frame)
      window.removeEventListener('resize', resize)
    }
  }, [reducedMotion])

  return (
    <div className="brand-background" aria-hidden="true">
      <video
        className="brand-background-video"
        autoPlay={!reducedMotion}
        loop
        muted
        playsInline
        preload="none"
        poster={asset('/broka-bg-mobile-poster.webp')}
      >
        <source media="(min-width: 760px)" src={asset('/broka-bg-desktop.mp4')} type="video/mp4" />
        <source src={asset('/broka-bg-mobile.mp4')} type="video/mp4" />
      </video>
      {!reducedMotion && <canvas ref={canvasRef} className="brand-background-particles" />}
      {reducedMotion && (
        <picture className="brand-background-poster">
          <source media="(min-width: 760px)" srcSet={asset('/broka-bg-desktop-poster.webp')} />
          <img src={asset('/broka-bg-mobile-poster.webp')} alt="" />
        </picture>
      )}
    </div>
  )
}
