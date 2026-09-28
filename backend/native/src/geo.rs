//! Great-circle distance, for "near me" filters and "3.2 km away" labels.
//!
//! The backend used to carry six copies of the haversine formula, in two
//! variants (atan2 and asin) that disagree in the last digit and fail
//! differently on bad input. This is the one implementation; the Python
//! reference in `api/core/geo.py` computes it step for step the same way,
//! so on the same platform the two agree to the bit.

/// Mean Earth radius, as every former copy used.
pub const EARTH_RADIUS_KM: f64 = 6371.0;

/// Distance in km between two points in degrees. NaN when any coordinate is
/// not a finite number, rather than a panic or a wrong zero.
pub fn haversine_km(lat1: f64, lng1: f64, lat2: f64, lng2: f64) -> f64 {
    if !(lat1.is_finite() && lng1.is_finite() && lat2.is_finite() && lng2.is_finite()) {
        return f64::NAN;
    }
    let phi1 = lat1.to_radians();
    let phi2 = lat2.to_radians();
    let s_phi = ((lat2 - lat1).to_radians() / 2.0).sin();
    let s_lambda = ((lng2 - lng1).to_radians() / 2.0).sin();
    let a = s_phi * s_phi + phi1.cos() * phi2.cos() * s_lambda * s_lambda;
    // Rounding can push `a` a hair past 1 for antipodal points, and asin of
    // anything above 1 is NaN.
    let a = a.clamp(0.0, 1.0);
    2.0 * EARTH_RADIUS_KM * a.sqrt().asin()
}

/// [`haversine_km`] from one origin to many points; `None` where a point has
/// no coordinates.
pub fn distances_km(lat: f64, lng: f64, points: &[(Option<f64>, Option<f64>)]) -> Vec<Option<f64>> {
    points
        .iter()
        .map(|&(p_lat, p_lng)| match (p_lat, p_lng) {
            (Some(p_lat), Some(p_lng)) => Some(haversine_km(lat, lng, p_lat, p_lng)),
            _ => None,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const NAIROBI: (f64, f64) = (-1.2864, 36.8172);
    const MOMBASA: (f64, f64) = (-4.0435, 39.6682);

    #[test]
    fn known_distance() {
        let d = haversine_km(NAIROBI.0, NAIROBI.1, MOMBASA.0, MOMBASA.1);
        assert!(
            (d - 440.0).abs() < 5.0,
            "Nairobi-Mombasa is ~440 km, got {d}"
        );
    }

    #[test]
    fn same_point_is_zero_and_symmetric() {
        assert_eq!(
            haversine_km(NAIROBI.0, NAIROBI.1, NAIROBI.0, NAIROBI.1),
            0.0
        );
        let there = haversine_km(NAIROBI.0, NAIROBI.1, MOMBASA.0, MOMBASA.1);
        let back = haversine_km(MOMBASA.0, MOMBASA.1, NAIROBI.0, NAIROBI.1);
        assert!((there - back).abs() < 1e-9);
    }

    #[test]
    fn antipodes_do_not_produce_nan() {
        let d = haversine_km(0.0, 0.0, 0.0, 180.0);
        assert!((d - std::f64::consts::PI * EARTH_RADIUS_KM).abs() < 1e-6);
    }

    #[test]
    fn non_finite_input_is_nan() {
        assert!(haversine_km(f64::NAN, 0.0, 0.0, 0.0).is_nan());
        assert!(haversine_km(0.0, f64::INFINITY, 0.0, 0.0).is_nan());
    }

    #[test]
    fn batch_skips_missing_points() {
        let out = distances_km(
            NAIROBI.0,
            NAIROBI.1,
            &[
                (Some(MOMBASA.0), Some(MOMBASA.1)),
                (None, Some(1.0)),
                (Some(1.0), None),
            ],
        );
        assert!(out[0].is_some());
        assert_eq!(out[1], None);
        assert_eq!(out[2], None);
    }
}
