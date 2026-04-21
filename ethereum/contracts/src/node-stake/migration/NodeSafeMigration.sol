// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { Executor } from "safe-contracts-1.4.1/base/Executor.sol";
import { ISafe, SafeMigration } from "safe-contracts-1.5.0/libraries/SafeMigration.sol";
import { SafeSuiteLibV141 } from "../../utils/SafeSuiteLibV141.sol";
import { SafeSuiteLibV150 } from "../../utils/SafeSuiteLibV150.sol";
import { IAvatar, Enum } from "../../interfaces/IAvatar.sol";
import { IHoprNodeStakeFactory } from "../NodeStakeFactory.sol";
import { IHoprNodeManagementModule } from "../../interfaces/INodeManagementModule.sol";

interface IOwner {
    function owner() external view returns (address);
}

interface IUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes memory data) external;
}

abstract contract HoprNodeSafeMigrationEvents {
    /**
     * @notice Emitted when the migration of the Safe is completed
     * @param safeProxy Address of the migrated Safe proxy
     * @param oldModuleProxy Address of the old module proxy
     * @param newModuleProxy Address of the new module proxy
     */
    event SafeAndModuleMigrationCompleted(address safeProxy, address oldModuleProxy, address newModuleProxy);
    event ChangedModuleImplementation(address moduleProxy);
    event DeployedNewV4Module(address newModuleProxy);
}

/**
 *    &&&&
 *    &&&&
 *    &&&&
 *    &&&&  &&&&&&&&&       &&&&&&&&&&&&          &&&&&&&&&&/   &&&&.&&&&&&&&&
 *    &&&&&&&&&   &&&&&   &&&&&&     &&&&&,     &&&&&    &&&&&  &&&&&&&&   &&&&
 *     &&&&&&      &&&&  &&&&#         &&&&   &&&&&       &&&&& &&&&&&     &&&&&
 *     &&&&&       &&&&/ &&&&           &&&& #&&&&        &&&&  &&&&&
 *     &&&&         &&&& &&&&&         &&&&  &&&&        &&&&&  &&&&&
 *     %%%%        /%%%%   %%%%%%   %%%%%%   %%%%  %%%%%%%%%    %%%%%
 *    %%%%%        %%%%      %%%%%%%%%%%    %%%%   %%%%%%       %%%%
 *                                          %%%%
 *                                          %%%%
 *                                          %%%%
 *
 * @title Migration Contract for Hopr Node Safe and Module Upgrade
 * @notice This is a contract that facilitates HOPR Node Safe and Hopr module upgrades.
 * HOPR Node Safe version 1.0.0 is the first version of the Hopr Node Safe, which uses Safe.sol
 * as its implementation. This contract allows for the migration of Safe implementations of
 * different versions, as long as the new version shares the same storage layout, as defined in
 * the SafeStorage.sol library. E.g. from Safe.sol version 1.4.1 to SafeL2.sol version 1.5.0
 *
 * The contract also supports migration of the module singleton address to a newer version.
 *
 * Migration process:
 * 1. Before on-chain migration, node operation should redeem all the tickets and close all
 * the channels. Then stop the node. This is to ensure that there are no pending operations
 * that could be affected by the migration, as well as to retrieve all the stakes/claim all
 * the tokens from open channels. Take a snapshot of the current state of the node, including:
 *   - Node address
 *   - Safe address
 *   - Module address
 * 2. Use the Safe address to delegate call the migrateSafeV141ToL2AndMigrateToUpgradeableModule
 *    function, passing in the old module address, default target, nonce and list of node addresses.
 *    This will migrate the Safe to the new implementation, set the fallback handler, deploy
 *    a new module, enable the new module and disable the old module.
 * 3. Verify that the migration was successful by checking:
 *   - The Safe implementation address is updated to the new version
 *   - The fallback handler is set to the new handler
 *   - The new module is enabled in the Safe
 *   - The old module is disabled in the Safe
 *   - The new module has the correct list of node addresses
 *   - Safe is the owner of the new module
 * 4. Restart the node with the new Safe and module contracts.
 */
contract HoprNodeSafeMigration is HoprNodeSafeMigrationEvents, SafeMigration, Executor {
    // The address of the ERC1820 registry contract
    address internal constant ERC1820_ADDRESS = 0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24;
    /**
     * @notice Address of this contract
     */
    address public immutable MODULE_SINGLETON;
    /**
     * @notice Address of the Factory contract
     */
    address public immutable FACTORY_ADDRESS;

    // Error when the module is not enabled in the Safe or the Safe is not the owner of the module
    error ModuleNotEnabledInSafe();
    // Error when the contract to be used is not deployed
    error UndeployedContract(string contractName);

    /**
     * @notice Checks if a module is enabled in the Safe.
     * @param moduleProxy Address of the module to be checked.
     */
    modifier onlyEnabledModule(address moduleProxy) {
        // verify that this function wants to upgrade a proxy that is enabled in the Safe
        if (!IAvatar(address(this)).isModuleEnabled(moduleProxy) || IOwner(moduleProxy).owner() != address(this)) {
            revert ModuleNotEnabledInSafe();
        }
        _;
    }

    /**
     * @notice Constructor for the HoprNodeSafeMigration contract.
     * @param moduleSingleton Address of the Module Singleton
     * @param nodeStakeFactory Address of the HoprNodeStakeFactory contract
     */
    constructor(
        address moduleSingleton,
        address nodeStakeFactory
    )
        SafeMigration(
            SafeSuiteLibV150.SAFE_SafeL2_ADDRESS,
            SafeSuiteLibV141.SAFE_SafeL2_ADDRESS,
            SafeSuiteLibV150.SAFE_CompatibilityFallbackHandler_ADDRESS
        )
    {
        require(hasCode(moduleSingleton), UndeployedContract("Module Singleton"));
        MODULE_SINGLETON = moduleSingleton;
        require(hasCode(nodeStakeFactory), UndeployedContract("Node Stake Factory"));
        FACTORY_ADDRESS = nodeStakeFactory;
    }

    /**
     * @notice Internal function to migrate the Module to a new singleton.
     * @dev This function is
     * @param moduleProxy Address of the module proxy
     */
    function migrateModuleSingleton(
        address moduleProxy,
        bytes memory data
    )
        public
        onlyDelegateCall
        onlyEnabledModule(moduleProxy)
    {
        // as a Safe, which is the owner of the module contract, upgradeToAndCall the
        // module contract to the new singleton
        IUpgradeable(moduleProxy).upgradeToAndCall(MODULE_SINGLETON, data);
        emit ChangedModuleImplementation(moduleProxy);
    }

    /**
     * @notice Migrate the Safe from v1.4.1 to v1.4.1 SafeL2 and migrate to a new upgradeable module.
     * Also update the fallback handler and optionally set the ERC777 interface implementer in the ERC1820 registry.
     * @param oldModuleProxy Address of the old module proxy
     * @param defaultTarget Default target address for the new module
     * @param nonce Nonce for the new module deployment
     * @param nodes List of node addresses to be included in the new module
     */
    function migrateSafeV141ToL2AndMigrateToUpgradeableModule(
        address oldModuleProxy,
        bytes32 defaultTarget,
        uint256 nonce,
        address[] memory nodes
    )
        public
        onlyDelegateCall
        onlyEnabledModule(oldModuleProxy)
    {
        // migrate the safe from v1.4.1 to v1.4.1 SafeL2, and set the fallback handler
        migrateL2Singleton();
        ISafe(payable(address(this))).setFallbackHandler(SAFE_FALLBACK_HANDLER);

        // set the interface implementer for ERC777
        bytes memory setInterfaceData = abi.encodeWithSignature(
            "setInterfaceImplementer(address,bytes32,address)",
            address(this),
            keccak256("ERC777TokensRecipient"),
            address(this)
        );
        // ignore return value as the failed call indicates does not affect the migration
        execute(ERC1820_ADDRESS, 0, setInterfaceData, Enum.Operation.Call, gasleft() - 2500);

        // deploy a new module contract
        address newModuleProxy =
            IHoprNodeStakeFactory(FACTORY_ADDRESS).deployModule(address(this), defaultTarget, nonce);
        // add all the nodes to the new module
        IHoprNodeManagementModule(newModuleProxy).includeNodes(nodes);
        // enable the newly deployed module
        IAvatar(address(this)).enableModule(newModuleProxy);
        // disable the old module
        IAvatar(address(this)).disableModule(newModuleProxy, oldModuleProxy);

        emit SafeAndModuleMigrationCompleted(address(this), oldModuleProxy, newModuleProxy);
    }

    /**
     * @notice Deploy a new v4 module and enable it in the Safe, without removing the old module.
     * @param defaultTarget Default target address for the new module
     * @param nonce Nonce for the new module deployment
     * @param nodes List of node addresses to be included in the new module
     * @return newModuleProxy Address of the newly deployed module proxy
     */
    function deployNewV4Module(
        bytes32 defaultTarget,
        uint256 nonce,
        address[] memory nodes
    )
        public
        onlyDelegateCall
        returns (address newModuleProxy)
    {
        // deploy a new module contract
        newModuleProxy = IHoprNodeStakeFactory(FACTORY_ADDRESS).deployModule(address(this), defaultTarget, nonce);
        // add all the nodes to the new module
        IHoprNodeManagementModule(newModuleProxy).includeNodes(nodes);
        // enable the newly deployed module
        IAvatar(address(this)).enableModule(newModuleProxy);
        emit DeployedNewV4Module(newModuleProxy);
    }
}
