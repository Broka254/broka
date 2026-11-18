// A conversation with a store as bubbles: the buyer's on the right in
// BROKA's violet, the store's on the left beside its sign, in days, with
// consecutive messages from one side drawn as one turn under one time
// (lib/messages.ts daysOf). A message the browser is still sending, or
// could not send, says so under it - with Retry when sending again is safe.
import { daysOf, mention, type ThreadMessage, timeLabel } from '@/lib/messages'

import { Icon } from './Icon'
import styles from './messaging.module.css'
import { StoreAvatar } from './StoreAvatar'

export interface ShownMessage extends ThreadMessage {
  /** The browser's own copy of a message, until the thread has the stored one. */
  local?: { status: 'sending' | 'sent' | 'failed'; error?: string; retryable?: boolean }
}

export function MessageHistory({
  messages,
  storeName,
  storeLogo,
  onRetry,
  onEdit,
}: {
  messages: ShownMessage[]
  storeName: string
  storeLogo: string | null
  onRetry: (clientId: string) => void
  onEdit: (clientId: string) => void
}) {
  const days = daysOf(messages)
  return (
    <ol className={styles.days}>
      {days.map((day) => (
        <li key={day.key} className={styles.day}>
          <p className={styles.dayLabel}>
            <span>{day.label}</span>
          </p>
          <ol className={styles.turns}>
            {day.turns.map((turn) => {
              const mine = turn.role === 'buyer'
              const last = turn.messages.at(-1)
              const status = last?.local?.status
              return (
                <li key={turn.key} className={`${styles.turn} ${mine ? styles.mine : styles.theirs}`}>
                  {!mine && <StoreAvatar name={storeName} logo={storeLogo} size={30} className={styles.turnAvatar} />}
                  <div className={styles.turnBody}>
                    {turn.messages.map((m, i) => (
                      <div key={m.client_msg_id ?? m.id ?? i} className={styles.message}>
                        <p
                          className={`${styles.bubble} ${m.local?.status === 'sending' ? styles.bubbleSending : ''} ${
                            m.local?.status === 'failed' ? styles.bubbleFailed : ''
                          }`}
                        >
                          {mention(m.kind) ?? m.content}
                        </p>
                        {m.local?.status === 'failed' && m.client_msg_id && (
                          <div className={styles.failed}>
                            <p role="alert">
                              <Icon name="alert" size={15} /> {m.local.error}
                            </p>
                            <span className={styles.failedActions}>
                              {m.local.retryable && (
                                <button type="button" onClick={() => onRetry(m.client_msg_id!)}>
                                  Retry
                                </button>
                              )}
                              <button type="button" onClick={() => onEdit(m.client_msg_id!)}>
                                Edit
                              </button>
                            </span>
                          </div>
                        )}
                      </div>
                    ))}
                    {status !== 'failed' && (
                      <p className={styles.meta}>
                        <span>{mine ? 'You' : storeName}</span>
                        {' · '}
                        {status === 'sending' ? (
                          <span className={styles.sendingNote}>
                            <span className={styles.spinner} aria-hidden="true" />
                            Sending…
                          </span>
                        ) : status === 'sent' ? (
                          <span>
                            <Icon name="check" size={13} /> Sent
                          </span>
                        ) : (
                          <time dateTime={turn.at ?? undefined}>{timeLabel(turn.at)}</time>
                        )}
                      </p>
                    )}
                  </div>
                </li>
              )
            })}
          </ol>
        </li>
      ))}
    </ol>
  )
}
