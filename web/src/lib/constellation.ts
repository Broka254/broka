// The layout of the connected-dots background: the same sky the app draws
// behind its home and sign-up screens (flutter_app/lib/widgets/
// constellation_background.dart), laid out for a web page.
//
// Seeded, so every visit sees the same sky and nothing jumps on resize.

export interface StarNode {
  /** Position as a fraction of the page's width and height. */
  x: number
  y: number
  /** Radius in CSS pixels. */
  size: number
  /** Phase of the node's pulse, 0..1. */
  phase: number
  /** Nodes that belong to the connected mesh (the rest are loose stars). */
  mesh: boolean
}

export interface ConstellationField {
  nodes: StarNode[]
  edges: Array<[number, number]>
}

export const MESH_COUNT = 46
export const STAR_COUNT = 54
const MAX_EDGE_DIST_SQ = 0.028

/** A small, fast seeded PRNG (mulberry32): the same sequence every time. */
export function seededRandom(seed: number): () => number {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

/**
 * The nodes and the mesh's edges. [aspect] is height / width of the area
 * it's drawn on: distances are compared as they'll look on screen, so a
 * tall phone doesn't get long vertical streaks and a wide monitor doesn't
 * get long horizontal ones.
 */
export function buildConstellation(aspect: number, seed = 20260917): ConstellationField {
  const rnd = seededRandom(seed)
  const nodes: StarNode[] = []
  for (let i = 0; i < MESH_COUNT; i++) {
    const x = rnd()
    const raw = rnd()
    // Keep the middle band (where text sits) a little quieter.
    const y = raw < 0.5 ? raw * 0.82 : 1 - (1 - raw) * 0.82
    nodes.push({ x, y, size: 1.8 + rnd() * 2.6, phase: rnd(), mesh: true })
  }
  for (let i = 0; i < STAR_COUNT; i++) {
    nodes.push({ x: rnd(), y: rnd(), size: 0.8 + rnd() * 1.5, phase: rnd(), mesh: false })
  }

  const edges: Array<[number, number]> = []
  const seen = new Set<string>()
  const yScale = Math.max(0.3, Math.min(aspect, 4))
  for (let i = 0; i < MESH_COUNT; i++) {
    const a = nodes[i]!
    const near = []
    for (let j = 0; j < MESH_COUNT; j++) {
      if (i === j) continue
      const b = nodes[j]!
      const dx = a.x - b.x
      const dy = (a.y - b.y) * yScale
      near.push({ j, d: dx * dx + dy * dy })
    }
    near.sort((p, q) => p.d - q.d)
    for (const { j, d } of near.slice(0, 2)) {
      if (d > MAX_EDGE_DIST_SQ) continue
      const lo = Math.min(i, j)
      const hi = Math.max(i, j)
      const key = `${lo}:${hi}`
      if (!seen.has(key)) {
        seen.add(key)
        edges.push([lo, hi])
      }
    }
  }
  return { nodes, edges }
}
