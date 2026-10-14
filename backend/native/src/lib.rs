//! Rust acceleration for the BROKA backend.
//!
//! The backend is Python (FastAPI) and stays Python. This crate takes the
//! few jobs where Python is the wrong tool - see `native/README.md` for how
//! each was chosen - and every one of them has a Python reference
//! implementation that the backend falls back to when the extension isn't
//! installed, held to identical output by `tests/test_native_parity.py`.
//!
//! - [`text_guard`]: scanning chat messages for off-platform contact
//!   details, in time linear in the message whatever its content.
//! - [`geo`]: great-circle distances, one at a time or in bulk.
//!
//! The Python bindings are behind the `python` feature (maturin enables it),
//! so `cargo test` runs the core without an interpreter.

#![forbid(unsafe_code)]

pub mod geo;
pub mod text_guard;

#[cfg(feature = "python")]
mod python;
