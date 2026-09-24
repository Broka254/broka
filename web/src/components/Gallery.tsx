'use client'

// A product's photos: one large image and a strip of thumbnails.
import { useState } from 'react'

import styles from './store.module.css'

export interface GalleryImage {
  src: string
  srcSet?: string
  thumb: string
}

export function Gallery({ images, alt, emoji }: { images: GalleryImage[]; alt: string; emoji: string }) {
  const [index, setIndex] = useState(0)
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
  return (
    <div className={styles.gallery}>
      <div className={styles.galleryMain}>
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src={current.src}
          srcSet={current.srcSet}
          sizes="(max-width: 860px) 100vw, 560px"
          alt={images.length > 1 ? `${alt}, photo ${index + 1} of ${images.length}` : alt}
          fetchPriority="high"
        />
      </div>
      {images.length > 1 && (
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
