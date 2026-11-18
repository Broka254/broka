'use client'

// A product's photos: one large image on a stage lit by the photo itself
// (a blurred copy behind it fills the frame, so a tall or wide photo isn't
// boxed in black), a strip of thumbnails, and with more than one photo the
// arrows, a count, and a swipe on a phone (STORES_UI_REVIEW.md L3).
import { type PointerEvent, useRef, useState } from 'react'

import { Icon } from './Icon'
import styles from './store.module.css'

export interface GalleryImage {
  src: string
  srcSet?: string
  thumb: string
}

/** How far a finger moves sideways, in pixels, before it is a swipe. */
const SWIPE = 40

export function Gallery({ images, alt, emoji }: { images: GalleryImage[]; alt: string; emoji: string }) {
  const [index, setIndex] = useState(0)
  const start = useRef<{ x: number; y: number } | null>(null)
  const current = images[index]
  if (!current) {
    return (
      <div className={styles.galleryMain}>
        <span className={styles.productEmoji} aria-hidden="true">
          {emoji}
        </span>
      </div>
    )
  }
  const many = images.length > 1
  const go = (step: number) => setIndex((i) => (i + step + images.length) % images.length)
  const onPointerDown = (e: PointerEvent<HTMLDivElement>) => {
    start.current = { x: e.clientX, y: e.clientY }
  }
  const onPointerUp = (e: PointerEvent<HTMLDivElement>) => {
    const from = start.current
    start.current = null
    if (!from) return
    const dx = e.clientX - from.x
    const dy = e.clientY - from.y
    // Mostly sideways: a swipe. Mostly down: the page scrolling.
    if (Math.abs(dx) > SWIPE && Math.abs(dx) > Math.abs(dy) * 1.5) go(dx < 0 ? 1 : -1)
  }
  return (
    <div className={styles.gallery}>
      <div
        className={styles.galleryMain}
        onPointerDown={many ? onPointerDown : undefined}
        onPointerUp={many ? onPointerUp : undefined}
        onPointerCancel={() => {
          start.current = null
        }}
      >
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img className={styles.galleryGlow} src={current.thumb} alt="" aria-hidden="true" />
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          key={current.src}
          className={styles.galleryImage}
          src={current.src}
          srcSet={current.srcSet}
          sizes="(max-width: 860px) 100vw, 640px"
          alt={many ? `${alt}, photo ${index + 1} of ${images.length}` : alt}
          fetchPriority="high"
          draggable={false}
        />
        {many && (
          <>
            <button type="button" className={`${styles.galleryNav} ${styles.galleryPrev}`} onClick={() => go(-1)} aria-label="Previous photo">
              <Icon name="chevronLeft" size={20} />
            </button>
            <button type="button" className={`${styles.galleryNav} ${styles.galleryNext}`} onClick={() => go(1)} aria-label="Next photo">
              <Icon name="chevron" size={20} />
            </button>
            <span className={styles.galleryCount} aria-hidden="true">
              {index + 1} / {images.length}
            </span>
          </>
        )}
      </div>
      {many && (
        <div className={styles.thumbs} role="tablist" aria-label="Photos">
          {images.map((img, i) => (
            <button
              key={img.thumb + i}
              type="button"
              role="tab"
              aria-selected={i === index}
              aria-label={`Photo ${i + 1}`}
              className={`${styles.thumb} ${i === index ? styles.thumbSelected : ''}`}
              onClick={() => setIndex(i)}
            >
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={img.thumb} alt="" loading="lazy" />
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
