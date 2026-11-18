// A price as the storefront prints it: "KES" set small beside the amount,
// and a unit ("/ bag") quieter after it - the way a shop's price tag reads,
// with the amount the eye lands on. The text is the same as the label's
// ("KES 3,500 / bag"), so copying it, or a screen reader, gets it whole.
import styles from './ui.module.css'

const CURRENCY = /^(KES)\s+(.+)$/

export function Price({ label, className }: { label: string; className?: string }) {
  const classes = className ? `${styles.price} ${className}` : styles.price
  const match = CURRENCY.exec(label)
  const currency = match?.[1]
  const rest = match?.[2]
  if (!currency || !rest) return <span className={classes}>{label}</span>
  const [amount, ...unit] = rest.split(' / ')
  return (
    <span className={classes}>
      <span className={styles.currency}>{currency}</span> <span className={styles.amount}>{amount}</span>
      {unit.length > 0 && <span className={styles.unit}> / {unit.join(' / ')}</span>}
    </span>
  )
}
