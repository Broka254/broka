'use client'

// Writing to a store: a box that grows with the message (up to a few
// lines, then scrolls), and Send. On a computer Enter sends and Shift+Enter
// starts a new line, as in every chat; on a phone Enter is a new line and
// the button sends, as phone keyboards expect. Send waits while a message
// is on its way, so a double tap cannot send it twice.
import { type KeyboardEvent, type RefObject, useEffect, useId } from 'react'

import { MAX_MESSAGE_LENGTH, MIN_MESSAGE_LENGTH } from '@/lib/messages'

import { Icon } from './Icon'
import styles from './messaging.module.css'

/** Where Enter sends: a keyboard and a mouse, not a touch screen's keyboard. */
function enterSends(): boolean {
  return typeof window.matchMedia !== 'function' || window.matchMedia('(hover: hover) and (pointer: fine)').matches
}

const MAX_HEIGHT_PX = 168

export function MessageComposer({
  value,
  onChange,
  onSend,
  sending,
  storeName,
  inputRef,
  onFocusChange,
}: {
  value: string
  onChange: (value: string) => void
  onSend: () => void
  /** A message is on its way: Send waits for it. */
  sending: boolean
  storeName: string
  inputRef: RefObject<HTMLTextAreaElement | null>
  onFocusChange?: (focused: boolean) => void
}) {
  const id = useId()
  const ready = value.trim().length >= MIN_MESSAGE_LENGTH
  const nearLimit = value.length > MAX_MESSAGE_LENGTH - 200

  // The box grows with what is in it, to a few lines. scrollHeight leaves
  // out the border, which the box's height includes (border-box): without
  // it the last line sat under a scrollbar. A box that isn't laid out yet
  // measures 0 - it keeps the CSS height rather than collapsing.
  useEffect(() => {
    const box = inputRef.current
    if (!box) return
    box.style.height = 'auto'
    const content = box.scrollHeight
    const border = box.offsetHeight - box.clientHeight
    box.style.height = content ? `${Math.min(content + border, MAX_HEIGHT_PX)}px` : ''
  }, [value, inputRef])

  const onKeyDown = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key !== 'Enter' || e.shiftKey || e.nativeEvent.isComposing || !enterSends()) return
    e.preventDefault()
    if (ready && !sending) onSend()
  }

  return (
    <form
      className={styles.composer}
      onSubmit={(e) => {
        e.preventDefault()
        if (ready && !sending) onSend()
      }}
    >
      <p className={styles.composerNote} id={`${id}-note`}>
        <Icon name="shield" size={14} /> Keep the conversation here: never pay to a number or link sent in a chat - agree
        the order on BROKA first.
      </p>
      <div className={styles.composerRow}>
        <label htmlFor={id} className="visually-hidden">
          Your message
        </label>
        <textarea
          id={id}
          ref={inputRef}
          className={styles.input}
          rows={1}
          maxLength={MAX_MESSAGE_LENGTH}
          placeholder={`Message ${storeName}`}
          value={value}
          aria-describedby={`${id}-note`}
          onChange={(e) => onChange(e.target.value)}
          onKeyDown={onKeyDown}
          onFocus={() => onFocusChange?.(true)}
          onBlur={() => onFocusChange?.(false)}
        />
        <button type="submit" className={styles.send} disabled={!ready || sending} aria-label="Send">
          {sending ? <span className={styles.spinner} aria-hidden="true" /> : <Icon name="send" size={19} />}
          <span className={styles.sendText} aria-hidden="true">
            Send
          </span>
        </button>
      </div>
      {nearLimit && (
        <p className={styles.counter} aria-live="polite">
          {value.length} / {MAX_MESSAGE_LENGTH}
        </p>
      )}
    </form>
  )
}
