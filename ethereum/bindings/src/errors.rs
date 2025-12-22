use thiserror::Error;
use alloy::{
    contract::Error as ContractError, 
    hex::FromHexError,
    providers::{MulticallError, PendingTransactionError},
    transports::TransportErrorKind,
};
use hopr_crypto_keypair::errors::KeyPairError;

/// Enumerates different errors produced by this crate.
#[derive(Error, Debug)]
pub enum HelperErrors {
    /// Error of contract error
    #[error(transparent)]
    FromHexError(#[from] FromHexError),

    /// Error of contract error
    #[error(transparent)]
    ContractError(#[from] ContractError),

    /// Error propagated by pending transactions
    #[error(transparent)]
    PendingTransactionError(#[from] PendingTransactionError),

    /// Error propagated by IO operations
    #[error(transparent)]
    UnableToReadFromPath(#[from] std::io::Error),

    /// Error in parsing provided comma-separated addresses
    #[error("error parsing address: {0:?}")]
    UnableToParseAddress(String),

    /// System time error
    #[error(transparent)]
    SystemTime(#[from] std::time::SystemTimeError),

    /// Error when identity cannot be created
    #[error("unable to create identity")]
    UnableToCreateIdentity,

    #[error("unable to update identity password")]
    UnableToUpdateIdentityPassword,

    /// Error due to supplying a non-existing file name
    #[error("incorrect filename: {0}")]
    IncorrectFilename(String),

    /// Error when identity existed
    #[error("identity file exists: {0}")]
    IdentityFileExists(String),

    /// Fail to read identity
    #[error("unable to read identity")]
    UnableToReadIdentity,

    /// Fail to find the identity directory
    #[error("unable to read identity directory")]
    MissingIdentityDirectory,

    /// Fail to delete an identity
    #[error("unable to delete identity")]
    UnableToDeleteIdentity,

    /// Provided environment does not match with that in the `ethereum/contracts/contracts-addresses.json`
    #[error("environment info mismatch")]
    EnvironmentInfoMismatch,

    /// Wrong foundry contract root is provided
    #[error("unable to set foundry root")]
    UnableToSetFoundryRoot,

    /// Fail to run foundry
    #[error("unable to run foundry")]
    ErrorInRunningFoundry,

    /// Fail to read password
    #[error("unable to read password")]
    UnableToReadPassword,

    /// Fail to read private key
    #[error("cannot read private key error: {0}")]
    UnableToReadPrivateKey(String),

    /// Parameters are missing
    #[error("missing parameter: {0}")]
    MissingParameter(String),

    /// Error with the keystore file
    #[error(transparent)]
    KeyStoreError(#[from] KeyPairError),

    #[error("deserialization Error: {0}")]
    /// Serde JSON Error
    SerdeJson(#[from] serde_json::Error),

    /// Cannot find network details from the given network name
    #[error("unable to find network details from the given network name ")]
    UnknownNetwork,

    /// Error with HTTP Json RPC provider
    #[error(transparent)]
    RpcTransportError(#[from] alloy::rpc::json_rpc::RpcError<TransportErrorKind>),

    /// Fail to make a multicall
    #[error(transparent)]
    MulticallError(#[from] MulticallError),

    /// Fail to make a multisend call
    #[error("internal transaction failure in multisend")]
    MultiSendError,

    /// Txn caller does not have the minter role
    #[error("caller does not have the privilege to mint tokens")]
    NotAMinter,

    /// Error with middleware
    #[error("middleware Error: {0}")]
    MiddlewareError(String),

    /// A required smart contract (Safe or module proxy instance) is not deployed
    #[error("contract not deployed: {0}")]
    ContractNotDeployed(String),

    // error of parsing addresses
    #[error("Cannot parse address: {0}")]
    InvalidAddress(String),

    // general error of parsing
    #[error("Cannot parse: {0}")]
    ParseError(String),
}
