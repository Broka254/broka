// A legal document, from the Markdown the app ships (lib/legal-text.ts):
// the little of it these documents use - headings, paragraphs, "- " lists,
// **bold** and _italic_ - turned into React elements. Never HTML: the text
// is escaped like any other on the page.
import type { ReactNode } from 'react'

type Block =
  | { kind: 'h'; level: 1 | 2 | 3; text: string }
  | { kind: 'p'; text: string }
  | { kind: 'ul'; items: string[] }

export function parseLegal(markdown: string): Block[] {
  const blocks: Block[] = []
  const open: { para: string[]; list: string[] | null } = { para: [], list: null }
  const endParagraph = () => {
    if (open.para.length) blocks.push({ kind: 'p', text: open.para.join(' ') })
    open.para = []
  }
  const endList = () => {
    if (open.list) blocks.push({ kind: 'ul', items: open.list })
    open.list = null
  }
  for (const raw of markdown.split('\n')) {
    const line = raw.trimEnd()
    const heading = /^(#{1,3})\s+(.*)$/.exec(line)
    if (heading) {
      endParagraph()
      endList()
      blocks.push({ kind: 'h', level: (heading[1] ?? '#').length as 1 | 2 | 3, text: heading[2] ?? '' })
    } else if (/^\s*-\s+/.test(line)) {
      endParagraph()
      if (!open.list) open.list = []
      open.list.push(line.replace(/^\s*-\s+/, ''))
    } else if (!line.trim()) {
      endParagraph()
      endList()
    } else if (open.list && /^\s+/.test(raw)) {
      // A list item's wrapped continuation line.
      const last = open.list.length - 1
      open.list[last] = `${open.list[last] ?? ''} ${line.trim()}`
    } else {
      endList()
      open.para.push(line.trim())
    }
  }
  endParagraph()
  endList()
  return blocks
}

function inline(text: string): ReactNode[] {
  return text.split(/(\*\*[^*]+\*\*|_[^_]+_)/g).map((part, i) => {
    if (/^\*\*[^*]+\*\*$/.test(part)) return <strong key={i}>{part.slice(2, -2)}</strong>
    if (/^_[^_]+_$/.test(part)) return <em key={i}>{part.slice(1, -1)}</em>
    return part
  })
}

export function LegalText({ markdown, className }: { markdown: string; className?: string }) {
  return (
    <article className={className}>
      {parseLegal(markdown).map((b, i) => {
        if (b.kind === 'h') {
          const Tag = (`h${b.level}` as 'h1' | 'h2' | 'h3')
          return <Tag key={i}>{inline(b.text)}</Tag>
        }
        if (b.kind === 'ul') {
          return (
            <ul key={i}>
              {b.items.map((item, j) => (
                <li key={j}>{inline(item)}</li>
              ))}
            </ul>
          )
        }
        return <p key={i}>{inline(b.text)}</p>
      })}
    </article>
  )
}
