import { describe, expect, it } from 'vitest'

import {
  buyerStars,
  buyerRatingMax,
  replyTimeLabel,
  reviewCountLabel,
  reviewDate,
  starFraction,
  starsFromStoreScore,
} from './ratings'

describe('rating scales', () => {
  it('never passes a 0-10 store score straight to five stars', () => {
    expect(starsFromStoreScore(6.5)).toBe(3.25)
    expect(starsFromStoreScore(7.2)).toBeCloseTo(3.6)
    expect(starsFromStoreScore(10)).toBe(buyerRatingMax)
    expect(starsFromStoreScore(0)).toBe(0)
    // A bad payload cannot draw more than five stars or fewer than none.
    expect(starsFromStoreScore(42)).toBe(buyerRatingMax)
    expect(starsFromStoreScore(-1)).toBe(0)
    expect(starsFromStoreScore(Number.NaN)).toBe(0)
    expect(starFraction(3.25)).toBeCloseTo(0.65)
  })

  it('clamps a buyer average to the 1-5 scale it came from', () => {
    expect(buyerStars(4.5)).toBe(4.5)
    expect(buyerStars(9)).toBe(buyerRatingMax)
    expect(buyerStars(-2)).toBe(0)
    expect(buyerStars(Number.NaN)).toBe(0)
  })

  it('counts reviews in words', () => {
    expect(reviewCountLabel(0)).toBe('0 reviews')
    expect(reviewCountLabel(1)).toBe('1 review')
    expect(reviewCountLabel(12)).toBe('12 reviews')
  })

  it('dates a review, treating the API timestamp as UTC', () => {
    expect(reviewDate('2026-09-20T10:00:00')).toBe('20 Sept 2026')
    expect(reviewDate('nonsense')).toBeNull()
    expect(reviewDate(null)).toBeNull()
  })

  it('says a reply time only when one was measured', () => {
    expect(replyTimeLabel(0.5)).toBe('Usually replies straight away')
    expect(replyTimeLabel(25)).toBe('Usually replies in about 25 min')
    expect(replyTimeLabel(90)).toBe('Usually replies in about 1.5 h')
    expect(replyTimeLabel(2880)).toBe('Usually replies in about 2.0 days')
    expect(replyTimeLabel(null)).toBeNull()
    expect(replyTimeLabel(Number.NaN)).toBeNull()
    expect(replyTimeLabel(-1)).toBeNull()
  })
})
