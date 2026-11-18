// A store's sign wherever the store appears beside something else - a
// conversation, an order, a product's seller: its logo, or its initial on
// BROKA's colours when it uploaded none (never a stock picture).
import styles from './ui.module.css'

export function StoreAvatar({
  name,
  logo,
  size = 40,
  className,
}: {
  name: string
  logo: string | null
  size?: number
  className?: string
}) {
  const initial = (Array.from(name.trim())[0] ?? '?').toUpperCase()
  return (
    <span
      className={`${styles.avatar}${className ? ` ${className}` : ''}`}
      style={{ width: size, height: size, fontSize: Math.round(size * 0.42) }}
      aria-hidden="true"
    >
      {logo ? (
        // Plain <img>: the API already serves exactly-sized WebP images.
        // eslint-disable-next-line @next/next/no-img-element
        <img src={logo} alt="" loading="lazy" decoding="async" />
      ) : (
        initial
      )}
    </span>
  )
}
