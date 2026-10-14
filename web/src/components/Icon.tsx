// The storefront's icons, as inline SVG: emoji and text glyphs (⌕, ✉, ⓘ)
// render differently on every phone and looked unfinished next to the
// app's Material icons (STORES_UI_REVIEW.md L6). Emoji stay where they
// carry meaning - the category rail.
import type { SVGProps } from 'react'

const PATHS = {
  search: 'M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM20.5 20.5 16 16',
  tune: 'M4 6h9M17 6h3M15 4v4M4 12h3M11 12h9M9 10v4M4 18h11M19 18h1M17 16v4',
  cart: 'M3 4h2.2l2.3 10.4a1.6 1.6 0 0 0 1.6 1.2h8.3a1.6 1.6 0 0 0 1.5-1.1L21 8H6.1M9.5 20.2h.01M17 20.2h.01',
  info: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 11v5M12 7.5h.01',
  share: 'M12 15V3M7.5 7.5 12 3l4.5 4.5M5 12v7a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-7',
  shield: 'M12 3 5 6v5.5c0 4.4 3 7.9 7 9.5 4-1.6 7-5.1 7-9.5V6l-7-3zM9 12l2 2 4-4',
  phone: 'M8 2.5h8a1.5 1.5 0 0 1 1.5 1.5v16a1.5 1.5 0 0 1-1.5 1.5H8A1.5 1.5 0 0 1 6.5 20V4A1.5 1.5 0 0 1 8 2.5zM11 18h2',
  truck: 'M2.5 6.5h11v9h-11zM13.5 10h4l3 3v2.5h-7M6.5 18.5a1.8 1.8 0 1 0 0-.01M17 18.5a1.8 1.8 0 1 0 0-.01',
  handshake: 'M7 7h11l-3-3M17 17H6l3 3',
  check: 'M5 12.5 10 17.5 19 7',
  close: 'M6 6l12 12M18 6 6 18',
  plus: 'M12 5v14M5 12h14',
  minus: 'M5 12h14',
  trash: 'M4 7h16M9.5 7V4.5h5V7M6.5 7l1 13h9l1-13M10 11v6M14 11v6',
  chevron: 'M9 5.5 15.5 12 9 18.5',
  back: 'M19 12H5M11 5.5 4.5 12l6.5 6.5',
  grid: 'M4 4h6.5v6.5H4zM13.5 4H20v6.5h-6.5zM4 13.5h6.5V20H4zM13.5 13.5H20V20h-6.5z',
  lock: 'M6.5 11h11a1.5 1.5 0 0 1 1.5 1.5v7a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 5 19.5v-7A1.5 1.5 0 0 1 6.5 11zM8 11V8a4 4 0 0 1 8 0v3',
  store: 'M4 9.5 5.5 4h13L20 9.5M4.5 10v10h15V10M4 9.5a2.7 2.7 0 0 0 5.3 0 2.7 2.7 0 0 0 5.4 0 2.7 2.7 0 0 0 5.3 0M10 20v-5h4v5',
  pin: 'M12 21s-6.5-5.7-6.5-11a6.5 6.5 0 0 1 13 0c0 5.3-6.5 11-6.5 11zM12 7.8a2.2 2.2 0 1 0 0 4.4 2.2 2.2 0 0 0 0-4.4z',
  bag: 'M5 8h14l-1 12.5H6L5 8zM9 8V6.5a3 3 0 0 1 6 0V8',
  mail: 'M3.5 6h17v12h-17zM3.5 6.5 12 13l8.5-6.5',
} as const

export type IconName = keyof typeof PATHS | 'star' | 'verified'

export function Icon({ name, size = 20, ...rest }: { name: IconName; size?: number } & SVGProps<SVGSVGElement>) {
  const common = {
    width: size,
    height: size,
    viewBox: '0 0 24 24',
    'aria-hidden': true,
    focusable: false,
    ...rest,
  } as const
  if (name === 'star') {
    return (
      <svg {...common} fill="currentColor">
        <path d="m12 3 2.7 5.6 6.1.8-4.5 4.2 1.1 6.1L12 16.8l-5.4 2.9 1.1-6.1-4.5-4.2 6.1-.8z" />
      </svg>
    )
  }
  if (name === 'verified') {
    return (
      <svg {...common}>
        <path
          fill="currentColor"
          d="m12 2 2.4 1.8 3-.2 1 2.8 2.5 1.7-.9 2.9.9 2.9-2.5 1.7-1 2.8-3-.2L12 22l-2.4-1.8-3 .2-1-2.8-2.5-1.7.9-2.9-.9-2.9 2.5-1.7 1-2.8 3 .2z"
        />
        <path d="m8.3 12.2 2.5 2.5 4.9-5" fill="none" stroke="#03040a" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    )
  }
  return (
    <svg {...common} fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
      <path d={PATHS[name]} />
    </svg>
  )
}
