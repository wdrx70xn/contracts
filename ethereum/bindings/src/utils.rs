//! Utility helpers for contract deployment, interaction, and testing in this crate.

use std::sync::Arc;

use hopr_crypto_types::{keypairs::ChainKeypair, prelude::Keypair};
use tracing::debug;

use crate::{
    constants::*,
    errors::HelperErrors,
    exports::alloy::{
        self,
        network::{EthereumWallet, TransactionBuilder},
        node_bindings::{Anvil, AnvilInstance},
        primitives::{self, Address, keccak256},
        providers::{Identity, MULTICALL3_ADDRESS, RootProvider, fillers::*},
        rpc::types::TransactionRequest,
        sol_types::{SolCall, SolValue},
    },
    hopr_announcements::HoprAnnouncements::{self, HoprAnnouncementsInstance},
    hopr_announcements_proxy::HoprAnnouncementsProxy,
    hopr_channels::HoprChannels::{self, HoprChannelsInstance},
    hopr_node_management_module::HoprNodeManagementModule::{self, HoprNodeManagementModuleInstance},
    hopr_node_safe_migration::HoprNodeSafeMigration::{self, HoprNodeSafeMigrationInstance},
    hopr_node_safe_registry::HoprNodeSafeRegistry::{self, HoprNodeSafeRegistryInstance},
    hopr_node_stake_factory::HoprNodeStakeFactory::{self, HoprNodeStakeFactoryInstance},
    hopr_ticket_price_oracle::HoprTicketPriceOracle::{self, HoprTicketPriceOracleInstance},
    hopr_token::HoprToken::{self, HoprTokenInstance},
    hopr_winning_probability_oracle::HoprWinningProbabilityOracle::{self, HoprWinningProbabilityOracleInstance},
};

// Used instead of From implementation to avoid alloy being a dependency of the primitive crates
/// Converts [`alloy::primitives::Address`] into [`hopr_primitive_types::prelude::Address`]
pub fn a2h(h: alloy::primitives::Address) -> hopr_primitive_types::prelude::Address {
    hopr_primitive_types::prelude::Address::from(h.0.0)
}

/// Converts [`hopr_primitive_types::prelude::Address`] into [`alloy::primitives::Address`]
pub fn h2a(a: hopr_primitive_types::prelude::Address) -> alloy::primitives::Address {
    alloy::primitives::Address::from_slice(a.as_ref())
}

/// Holds instances to contracts.
#[derive(Debug, Clone)]
pub struct ContractInstances<P> {
    pub token: HoprTokenInstance<P>,
    pub channels: HoprChannelsInstance<P>,
    pub announcements: HoprAnnouncementsInstance<P>,
    pub safe_registry: HoprNodeSafeRegistryInstance<P>,
    pub price_oracle: HoprTicketPriceOracleInstance<P>,
    pub win_prob_oracle: HoprWinningProbabilityOracleInstance<P>,
    pub stake_factory: HoprNodeStakeFactoryInstance<P>,
    pub module_implementation: HoprNodeManagementModuleInstance<P>,
    pub node_safe_migration: HoprNodeSafeMigrationInstance<P>,
}

impl<P> ContractInstances<P>
where
    P: alloy::providers::Provider + Clone,
{
    pub fn new(contract_addresses: &crate::ContractAddresses, provider: P) -> Self {
        Self {
            token: HoprTokenInstance::new(contract_addresses.token, provider.clone()),
            channels: HoprChannelsInstance::new(contract_addresses.channels, provider.clone()),
            announcements: HoprAnnouncementsInstance::new(contract_addresses.announcements, provider.clone()),
            safe_registry: HoprNodeSafeRegistryInstance::new(contract_addresses.node_safe_registry, provider.clone()),
            price_oracle: HoprTicketPriceOracleInstance::new(contract_addresses.ticket_price_oracle, provider.clone()),
            win_prob_oracle: HoprWinningProbabilityOracleInstance::new(
                contract_addresses.winning_probability_oracle,
                provider.clone(),
            ),
            stake_factory: HoprNodeStakeFactoryInstance::new(contract_addresses.node_stake_factory, provider.clone()),
            module_implementation: HoprNodeManagementModuleInstance::new(
                contract_addresses.module_implementation,
                provider.clone(),
            ),
            node_safe_migration: HoprNodeSafeMigrationInstance::new(
                contract_addresses.node_safe_migration,
                provider.clone(),
            ),
        }
    }

    pub async fn deploy_erc1820_registry(provider: P) -> Result<(), HelperErrors> {
        debug!("deploying ERC1820 registry...");
        // Fund 1820 deployer and deploy ERC1820Registry
        let tx = TransactionRequest::default()
            .with_to(ERC_1820_DEPLOYER)
            .with_value(ETH_VALUE_FOR_ERC1820_DEPLOYER);

        // Sequentially executing the following transactions:
        // 1. Fund the deployer wallet
        provider.send_transaction(tx.clone()).await?.watch().await?;
        // 2. Use the funded deployer wallet to deploy ERC1820Registry with a signed txn
        provider
            .send_raw_transaction(&ERC_1820_REGISTRY_DEPLOY_CODE)
            .await?
            .watch()
            .await?;

        Ok(())
    }

    pub async fn deploy_multicall3(provider: P) -> Result<(), HelperErrors> {
        debug!("deploying Multicall3...");
        // Fund Multicall3 deployer and deploy Multicall3
        let multicall3_code = provider.get_code_at(MULTICALL3_ADDRESS).await?;
        if multicall3_code.is_empty() {
            // Fund Multicall3 deployer and deploy ERC1820Registry
            let tx = TransactionRequest::default()
                .with_to(crate::constants::MULTICALL3_DEPLOYER)
                .with_value(crate::constants::ETH_VALUE_FOR_MULTICALL3_DEPLOYER);
            // Sequentially executing the following transactions:
            // 1. Fund the deployer wallet
            provider.send_transaction(tx.clone()).await?.watch().await?;
            // 2. Use the funded deployer wallet to deploy Multicall3 with a signed txn
            provider
                .send_raw_transaction(MULTICALL3_DEPLOY_CODE)
                .await?
                .watch()
                .await?;
        }
        Ok(())
    }

    pub async fn deploy_safe_suites(provider: P) -> Result<(), HelperErrors> {
        debug!("deploying Safe contracts...");

        // Check if safe suite has been deployed. If so, skip this step
        let code = provider.get_code_at(SAFE_SINGLETON_ADDRESS).await?;

        // only deploy contracts when needed
        if code.is_empty() {
            debug!("deploying safe code");
            // Deploy Safe diamond deployment proxy singleton
            let safe_diamond_proxy_address = {
                // Fund Safe singleton deployer 0.01 anvil-eth and deploy Safe singleton
                let tx = TransactionRequest::default()
                    .with_to(SAFE_DEPLOYER_ADDRESS)
                    .with_value(SAFE_DEPLOYER_BALANCE);

                provider.send_transaction(tx).await?.watch().await?;

                let tx = provider
                    .send_raw_transaction(&SAFE_DIAMOND_PROXY_SINGLETON_DEPLOY_CODE)
                    .await?
                    .get_receipt()
                    .await?;
                tx.contract_address.ok_or_else(|| {
                    HelperErrors::UnableToParseAddress("Failed to get contract address from receipt".to_string())
                })?
            };
            debug!("Safe diamond proxy singleton {:?}", safe_diamond_proxy_address);

            // Deploy minimum Safe suite
            // 1. Safe proxy factory deploySafeProxyFactory();
            let _tx_safe_proxy_factory = TransactionRequest::default()
                .with_to(safe_diamond_proxy_address)
                .with_input(SAFE_PROXY_FACTORY_DEPLOY_CODE);
            // 2. Handler: only CompatibilityFallbackHandler and omit TokenCallbackHandler as it's not used now
            // 2. Handler: deploy Safe ExtensibleFallbackHandler, v1.5.0
            let _tx_safe_compatibility_fallback_handler = TransactionRequest::default()
                .with_to(safe_diamond_proxy_address)
                .with_input(SAFE_COMPATIBILITY_FALLBACK_HANDLER_DEPLOY_CODE_V150);
            // 3. Library: only MultiSendCallOnly and omit MultiSendCall
            let _tx_safe_multisend_call_only = TransactionRequest::default()
                .with_to(safe_diamond_proxy_address)
                .with_input(SAFE_MULTISEND_CALL_ONLY_DEPLOY_CODE);
            // 4. Safe singleton v1.4.1 deploySafe();
            let _tx_safe_singleton_v141 = TransactionRequest::default()
                .with_to(safe_diamond_proxy_address)
                .with_input(SAFE_SINGLETON_DEPLOY_CODE_V141);
            // 5. Safe L2 singleton v1.4.1 deploySafe();
            let _tx_safe_l2_singleton_v141 = TransactionRequest::default()
                .with_to(safe_diamond_proxy_address)
                .with_input(SAFE_SINGLETON_L2_DEPLOY_CODE_V141);
            // 6. Safe multisend:
            let _tx_safe_multisend = TransactionRequest::default()
                .with_to(safe_diamond_proxy_address)
                .with_input(SAFE_MULTISEND_DEPLOY_CODE);
            // 7. Safe L2 singleton v1.5.0 deploySafe();
            let _tx_safe_l2_singleton_v150 = TransactionRequest::default()
                .with_to(safe_diamond_proxy_address)
                .with_input(SAFE_SINGLETON_L2_DEPLOY_CODE_V150);
            // other omitted libs: SimulateTxAccessor, CreateCall, and SignMessageLib
            // broadcast those transactions
            provider.send_transaction(_tx_safe_proxy_factory).await?.watch().await?;
            provider
                .send_transaction(_tx_safe_compatibility_fallback_handler)
                .await?
                .watch()
                .await?;
            provider
                .send_transaction(_tx_safe_multisend_call_only)
                .await?
                .watch()
                .await?;
            provider
                .send_transaction(_tx_safe_singleton_v141)
                .await?
                .watch()
                .await?;
            provider
                .send_transaction(_tx_safe_l2_singleton_v141)
                .await?
                .watch()
                .await?;
            provider.send_transaction(_tx_safe_multisend).await?.watch().await?;
            provider
                .send_transaction(_tx_safe_l2_singleton_v150)
                .await?
                .watch()
                .await?;
        }

        let code_safe_singleton_v141 = provider.get_code_at(SAFE_SINGLETON_L2_ADDRESS_V141).await?;
        let code_safe_singleton_v150 = provider.get_code_at(SAFE_SINGLETON_L2_ADDRESS_V150).await?;
        let code_compatibility_handler_v150 = provider
            .get_code_at(SAFE_COMPATIBILITY_FALLBACK_HANDLER_ADRESS_V150)
            .await?;
        assert!(
            !code_safe_singleton_v141.is_empty(),
            "Safe singleton v1.4.1 not deployed"
        );
        assert!(
            !code_safe_singleton_v150.is_empty(),
            "Safe singleton v1.5.0 not deployed"
        );
        assert!(
            !code_compatibility_handler_v150.is_empty(),
            "Safe compatibility handler v1.5.0 not deployed"
        );
        Ok(())
    }

    /// Deploys testing environment (with dummy network registry proxy) via the given provider.
    async fn inner_deploy_common_contracts_for_testing(
        provider: P,
        deployer: &ChainKeypair,
    ) -> Result<Self, HelperErrors> {
        // Pre-deploy common contracts
        ContractInstances::deploy_erc1820_registry(provider.clone()).await?;
        ContractInstances::deploy_multicall3(provider.clone()).await?;
        ContractInstances::deploy_safe_suites(provider.clone()).await?;

        debug!("deploying contracts...");
        // Get deployer address
        let self_address = h2a(deployer.public().to_address());

        let module_implementation = HoprNodeManagementModule::deploy(provider.clone()).await?;
        let safe_registry = HoprNodeSafeRegistry::deploy(provider.clone()).await?;
        let price_oracle = HoprTicketPriceOracle::deploy(
            provider.clone(),
            self_address,
            primitives::U256::from(100000000000000000_u128), // U256::from(100000000000000000_u128),
        )
        .await?;
        let win_prob_oracle = HoprWinningProbabilityOracle::deploy(
            provider.clone(),
            self_address,
            primitives::aliases::U56::from(0xFFFFFFFFFFFFFF_u64), /* 0xFFFFFFFFFFFFFF in hex or 72057594037927935 in
                                                                   * decimal values */
        )
        .await?;
        let token = HoprToken::deploy(provider.clone()).await?;
        let channels = HoprChannels::deploy(
            provider.clone(),
            primitives::Address::from(token.address().as_ref()),
            1_u32,
            primitives::Address::from(safe_registry.address().as_ref()),
        )
        .await?;
        let announcements_implementation = HoprAnnouncements::deploy(provider.clone()).await?;
        let announcement_initialize_parameters = (
            *token.address(),
            *safe_registry.address(),
            INIT_KEY_BINDING_FEE,
            self_address,
        )
            .abi_encode();
        let encode_initialization = HoprAnnouncements::initializeCall {
            initParams: announcement_initialize_parameters.into(),
        }
        .abi_encode();

        let announcements_proxy = HoprAnnouncementsProxy::deploy(
            provider.clone(),
            primitives::Address::from(announcements_implementation.address().as_ref()),
            encode_initialization.into(),
        )
        .await?;

        let stake_factory = HoprNodeStakeFactory::deploy(
            provider.clone(),
            primitives::Address::from(module_implementation.address().as_ref()),
            primitives::Address::from(announcements_proxy.address().as_ref()),
            self_address,
        )
        .await?;

        let node_safe_migration = HoprNodeSafeMigration::deploy(
            provider.clone(),
            primitives::Address::from(module_implementation.address().as_ref()),
            primitives::Address::from(stake_factory.address().as_ref()),
        )
        .await?;

        // get the defaultHoprNetwork from the stake factory
        let default_hopr_network = stake_factory.defaultHoprNetwork().call().await?;
        let new_default_hopr_network = HoprNodeStakeFactory::HoprNetwork {
            tokenAddress: *token.address(),
            defaultTokenAllowance: default_hopr_network.defaultTokenAllowance,
            defaultAnnouncementTarget: default_hopr_network.defaultAnnouncementTarget,
        };
        // Update the `defaultHoprNetwork` in the factory contract, to update the token address
        stake_factory
            .updateHoprNetwork(new_default_hopr_network)
            .send()
            .await?
            .watch()
            .await?;

        Ok(Self {
            token,
            channels,
            announcements: HoprAnnouncementsInstance::new(*announcements_proxy.address(), provider.clone()),
            safe_registry,
            price_oracle,
            win_prob_oracle,
            stake_factory,
            module_implementation,
            node_safe_migration,
        })
    }

    /// Deploys testing environment (with dummy network registry proxy) via the given provider.
    pub async fn deploy_for_testing(provider: P, deployer: &ChainKeypair) -> Result<Self, HelperErrors> {
        let instances = Self::inner_deploy_common_contracts_for_testing(provider.clone(), deployer).await?;

        Ok(Self { ..instances })
    }

    pub fn get_contract_addresses(&self) -> crate::ContractAddresses {
        crate::ContractAddresses {
            token: *self.token.address(),
            channels: *self.channels.address(),
            announcements: *self.announcements.address(),
            node_safe_registry: *self.safe_registry.address(),
            ticket_price_oracle: *self.price_oracle.address(),
            winning_probability_oracle: *self.win_prob_oracle.address(),
            node_stake_factory: *self.stake_factory.address(),
            module_implementation: *self.module_implementation.address(),
            node_safe_migration: *self.node_safe_migration.address(),
        }
    }
}

/// Implement ethers-rs `get_create2_address` function
/// Returns the CREATE2 address of a smart contract as specified in
/// [EIP1014](https://github.com/ethereum/EIPs/blob/master/EIPS/eip-1014.md)
///
/// keccak256( 0xff ++ senderAddress ++ salt ++ keccak256(init_code))[12..]
pub fn get_create2_address(from: Address, salt: impl AsRef<[u8]>, init_code: impl AsRef<[u8]>) -> Address {
    let salt = salt.as_ref();
    let init_code_hash = keccak256(init_code.as_ref());

    let mut bytes = Vec::with_capacity(1 + 20 + salt.len() + init_code_hash.len());
    bytes.push(0xff);
    bytes.extend_from_slice(from.as_slice());
    bytes.extend_from_slice(salt);
    bytes.extend_from_slice(&init_code_hash.0);

    let hash = keccak256(bytes);

    let mut bytes = [0u8; 20];
    bytes.copy_from_slice(&hash[12..]);
    Address::from(bytes)
}

/// Creates local Anvil instance.
///
/// Used for testing. When block time is given, new blocks are mined periodically.
/// Otherwise, a new block is mined per transaction.
///
/// Uses a fixed mnemonic to make generated accounts deterministic.
pub fn create_anvil(block_time: Option<std::time::Duration>) -> alloy::node_bindings::AnvilInstance {
    let mut anvil = alloy::node_bindings::Anvil::new()
        .mnemonic("gentle wisdom move brush express similar canal dune emotion series because parrot");

    if let Some(bt) = block_time {
        anvil = anvil.block_time(bt.as_secs());
    }

    anvil.spawn()
}

pub fn create_anvil_at_port(default: bool) -> AnvilInstance {
    let mut anvil = Anvil::new();

    if !default {
        let listener =
            std::net::TcpListener::bind("127.0.0.1:0").unwrap_or_else(|_| panic!("Failed to bind localhost"));
        let random_port = listener
            .local_addr()
            .unwrap_or_else(|_| panic!("Failed to get local address"))
            .port();
        anvil = anvil.port(random_port);
        anvil = anvil.chain_id(random_port.into());
    } else {
        anvil = anvil.port(8545u16);
    }
    anvil.spawn()
}

pub type AnvilRpcClient = FillProvider<
    JoinFill<
        JoinFill<Identity, JoinFill<GasFiller, JoinFill<BlobGasFiller, JoinFill<NonceFiller, ChainIdFiller>>>>,
        WalletFiller<EthereumWallet>,
    >,
    RootProvider,
>;

/// Used for testing. Creates RPC client to the local Anvil instance.
pub fn create_rpc_client_to_anvil(
    anvil: &alloy::node_bindings::AnvilInstance,
    signer: &hopr_crypto_types::keypairs::ChainKeypair,
) -> Arc<AnvilRpcClient> {
    use alloy::{
        providers::ProviderBuilder, rpc::client::ClientBuilder, signers::local::PrivateKeySigner,
        transports::http::ReqwestTransport,
    };
    use hopr_crypto_types::keypairs::Keypair;

    let wallet = PrivateKeySigner::from_slice(signer.secret().as_ref()).expect("failed to construct wallet");

    let transport_client = ReqwestTransport::new(anvil.endpoint_url());

    let rpc_client = ClientBuilder::default().transport(transport_client.clone(), transport_client.guess_local());

    let provider = ProviderBuilder::new().wallet(wallet).connect_client(rpc_client);

    Arc::new(provider)
}

#[cfg(test)]
mod tests {
    use std::{ffi::OsStr, path::PathBuf};

    use super::*;
    use crate::{config::NetworksWithContractAddresses, errors::HelperErrors};

    /// test the deploy_for_testing method returns the correct contract addresses as in contracts-addresses.json file
    #[tokio::test]
    async fn test_deploy_for_testing() -> anyhow::Result<()> {
        let _ = env_logger::builder().is_test(true).try_init();
        // launch local anvil instance
        let anvil = create_anvil(None);
        let contract_deployer = ChainKeypair::from_secret(anvil.keys()[0].to_bytes().as_ref())?;
        let client = create_rpc_client_to_anvil(&anvil, &contract_deployer);
        // deploy hopr contracts
        let instances = ContractInstances::deploy_for_testing(client.clone(), &contract_deployer)
            .await
            .expect("failed to deploy");
        println!("deployed hopr contracts {:?}", instances);

        // get contract addresses from contracts-addresses.json in the parent directory
        let binding_dir = std::env::current_dir()?;
        let contract_root = binding_dir.to_str().ok_or_else(|| {
            HelperErrors::UnableToParseAddress("Failed to convert binding directory to string".to_string())
        })?;
        let contract_environment_config_path =
            PathBuf::from(OsStr::new(contract_root)).join("contracts-addresses.json");
        debug!(
            "contract_environment_config_path {:?}",
            contract_environment_config_path
        );
        let file_read =
            std::fs::read_to_string(contract_environment_config_path).map_err(HelperErrors::UnableToReadFromPath)?;

        let networks_with_contract_addresses =
            serde_json::from_str::<NetworksWithContractAddresses>(&file_read).map_err(HelperErrors::SerdeJson)?;
        let expected_addresses = networks_with_contract_addresses
            .networks
            .get("anvil-localhost")
            .ok_or_else(|| HelperErrors::UnableToParseAddress("anvil-localhost network not found".to_string()))?
            .addresses
            .clone();
        println!("expected_addresses {:?}", expected_addresses);

        // compare the addresses
        assert_eq!(expected_addresses.token, *instances.token.address());
        assert_eq!(expected_addresses.channels, *instances.channels.address());
        assert_eq!(expected_addresses.announcements, *instances.announcements.address());
        assert_eq!(
            expected_addresses.node_safe_registry,
            *instances.safe_registry.address()
        );
        assert_eq!(
            expected_addresses.ticket_price_oracle,
            *instances.price_oracle.address()
        );
        assert_eq!(
            expected_addresses.winning_probability_oracle,
            *instances.win_prob_oracle.address()
        );
        assert_eq!(
            expected_addresses.node_stake_factory,
            *instances.stake_factory.address()
        );
        assert_eq!(
            expected_addresses.module_implementation,
            *instances.module_implementation.address()
        );
        assert_eq!(
            expected_addresses.node_safe_migration,
            *instances.node_safe_migration.address()
        );
        Ok(())
    }
}
