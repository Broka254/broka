//! The Python face of the crate: `import broka_native`.
//!
//! Thin on purpose. Each function converts its arguments, releases the GIL
//! for the Rust work and converts the result back; the behaviour lives in
//! `text_guard` and `geo`, where `cargo test` reaches it without Python.
//! `api/core/native.py` is the only Python module that imports this one,
//! and the shape of what it returns is written down in `broka_native.pyi`.

use std::borrow::Cow;

use pyo3::prelude::*;
use pyo3::types::PyString;

use crate::{geo, text_guard};

/// Bumped whenever a function below changes its signature or meaning.
/// `api/core/native.py` refuses a build whose number it doesn't expect, so a
/// stale extension left in site-packages is never called the wrong way.
pub const API_VERSION: u32 = 1;

/// A Python str as Rust text. A str can hold lone surrogates ("\ud800" is
/// valid JSON), which UTF-8 can't; those become U+FFFD instead of raising,
/// exactly as the Python engine does (normalization turns them into
/// spaces either way).
fn text_of<'a>(text: &'a Bound<'_, PyString>) -> Cow<'a, str> {
    match text.to_str() {
        Ok(s) => Cow::Borrowed(s),
        Err(_) => text.to_string_lossy(),
    }
}

/// The normalized form of `text` that contact-leak rules are matched on.
#[pyfunction]
fn normalize_text(py: Python<'_>, text: &Bound<'_, PyString>) -> String {
    let text = text_of(text);
    py.detach(|| text_guard::normalize(&text))
}

/// Off-platform contact details in `text`, as `(kind, start, end, text)`
/// tuples sorted by position; offsets index the normalized text.
#[pyfunction]
fn scan_contact_leaks(
    py: Python<'_>,
    text: &Bound<'_, PyString>,
) -> Vec<(String, usize, usize, String)> {
    let text = text_of(text);
    py.detach(|| text_guard::scan(&text))
        .into_iter()
        .map(|f| (f.kind, f.start, f.end, f.text))
        .collect()
}

/// Great-circle distance in km; NaN if any coordinate isn't finite.
#[pyfunction]
fn haversine_km(lat1: f64, lng1: f64, lat2: f64, lng2: f64) -> f64 {
    geo::haversine_km(lat1, lng1, lat2, lng2)
}

/// Distances from one origin to a sequence of `(lat, lng)` tuples, `None`
/// for a point missing either coordinate.
#[pyfunction]
fn distances_km(
    py: Python<'_>,
    lat: f64,
    lng: f64,
    points: Vec<(Option<f64>, Option<f64>)>,
) -> Vec<Option<f64>> {
    py.detach(|| geo::distances_km(lat, lng, &points))
}

#[pymodule]
fn broka_native(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add("__version__", env!("CARGO_PKG_VERSION"))?;
    m.add("API_VERSION", API_VERSION)?;
    m.add("CONTACT_RULES_JSON", text_guard::RULES_JSON)?;
    m.add("MAX_FINDINGS", text_guard::MAX_FINDINGS)?;
    m.add("EARTH_RADIUS_KM", geo::EARTH_RADIUS_KM)?;
    m.add_function(wrap_pyfunction!(normalize_text, m)?)?;
    m.add_function(wrap_pyfunction!(scan_contact_leaks, m)?)?;
    m.add_function(wrap_pyfunction!(haversine_km, m)?)?;
    m.add_function(wrap_pyfunction!(distances_km, m)?)?;
    Ok(())
}
