//! This lib re-exports abigen! generated bindings for solidity contracts.

#![allow(clippy::all)]

#[allow(warnings)]
#[cfg_attr(rustfmt, rustfmt_skip)]
mod codegen;

pub mod config;
pub mod constants;

#[cfg_attr(rustfmt, rustfmt_skip)]
pub use codegen::*;

pub mod errors;
pub mod exports {
    pub use alloy;
}

pub mod methods;
pub mod utils;

pub use config::{CONTRACTS_ADDRESSES_FILE_CONTENT, ContractAddresses};
