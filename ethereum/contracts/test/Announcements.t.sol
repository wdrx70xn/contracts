// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.6.0 <0.9.0;

import { Test, Vm, stdStorage, StdStorage } from "forge-std/Test.sol";
import { ERC1820RegistryFixtureTest } from "./utils/ERC1820Registry.sol";
import {
    HoprAnnouncements,
    KeyBindingWithSignature,
    KeyBindingWithSignatureTimestamp,
    KeyId,
    HoprAnnouncementsEvents
} from "../src/Announcements.sol";
import { HoprNodeSafeRegistry } from "../src/node-stake/NodeSafeRegistry.sol";
import { HoprToken } from "../src/static/HoprToken.sol";

// Dummy since there is no verification happening on-chain
bytes32 constant ED25519_SIG_0 = 0x000000000000000000000000000000000000000000000000000000000ed25519;
bytes32 constant ED25519_SIG_1 = 0x100000000000000000000000000000000000000000000000000000000ed25519;
bytes32 constant ED25519_PUB_KEY = 0x3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c;

string constant MULTIADDRESS = "/ip6/2604:1380:2000:7a00::1/udp/4001/quic";
uint256 constant DEFAULT_KEY_BINDING_FEE = 10_000_000 gwei; // 0.01 wxHOPR tokens
uint256 constant NEW_KEY_BINDING_FEE = 1_000_000 gwei; // 0.001 wxHOPR tokens

/// forge-lint:disable-next-item(mixed-case-variable)
contract AnnouncementsTest is Test, ERC1820RegistryFixtureTest, HoprAnnouncementsEvents {
    using stdStorage for StdStorage;

    HoprNodeSafeRegistry safeRegistry;
    HoprAnnouncements announcements;
    HoprToken hoprToken;
    address public deployer;
    address public callerSafe;

    modifier respectCurveRange(bytes32[] memory keys) {
        // Seckp256k1 curve order
        for (uint256 i = 0; i < keys.length; i++) {
            // private keys do not exceed the curve order
            vm.assume(uint256(keys[i]) < SECP256K1_ORDER);
            // private key cannot be zero
            vm.assume(uint256(keys[i]) != 0);
            // private keys are not leading to the same address
            for (uint256 j = 0; j < i; j++) {
                vm.assume(keys[i] != keys[j]);
            }
        }
        _;
    }

    modifier callerNodeIsUnused(address callerNode) {
        assumeUnusedAddress(callerNode);
        _;
    }

    modifier mockNodeToSafe(address nodeAddress, address safeAddress) {
        vm.mockCall(
            address(safeRegistry),
            abi.encodeWithSignature("nodeToSafe(address)", nodeAddress),
            abi.encode(safeAddress)
        );
        _;
    }

    modifier mockMintBalance(address to, uint256 amount) {
        // manipulate the caller's token balance
        vm.prank(deployer);
        hoprToken.mint(to, amount, '', '');
        _;
    }

    function setUp() public override {
        super.setUp();

        deployer = vm.addr(98765);
        callerSafe = vm.addr(56789);

        vm.startPrank(deployer);
        safeRegistry = new HoprNodeSafeRegistry();
        hoprToken = new HoprToken();
        announcements = new HoprAnnouncements(address(hoprToken), safeRegistry, DEFAULT_KEY_BINDING_FEE);
        // grant deployer minter role to mint tokens for testing
        hoprToken.grantRole(hoprToken.MINTER_ROLE(), deployer);
        vm.stopPrank();
    }

    function testRevert_ZeroAddressOnDeployment() public {
        vm.expectRevert(abi.encodeWithSelector(HoprAnnouncements.ZeroAddress.selector, "_token must not be empty"));
        announcements = new HoprAnnouncements(address(0), safeRegistry, DEFAULT_KEY_BINDING_FEE);

        vm.expectRevert(abi.encodeWithSelector(HoprAnnouncements.ZeroAddress.selector, "_safeRegistry must not be empty"));
        announcements = new HoprAnnouncements(address(hoprToken), HoprNodeSafeRegistry(address(0)), DEFAULT_KEY_BINDING_FEE);
    }

    function testFuzz_KeyBinding(address callerNode) public
        callerNodeIsUnused(callerNode)
        mockNodeToSafe(callerNode, address(0))
        mockMintBalance(callerNode, DEFAULT_KEY_BINDING_FEE)
    {
        assertEq(hoprToken.balanceOf(callerNode), DEFAULT_KEY_BINDING_FEE);
        assertEq(hoprToken.totalSupply(), DEFAULT_KEY_BINDING_FEE);

        // prepare the key-binding payload, without announcing multiaddr
        bytes memory keyBindPayload = abi.encode(
            callerNode, ED25519_SIG_0, ED25519_SIG_1, ED25519_PUB_KEY, ''
        );

        vm.prank(callerNode);
        // expect KeyBinding event emitted
        vm.expectEmit(true, false, false, false, address(announcements));
        emit KeyBinding(ED25519_SIG_0, ED25519_SIG_1, ED25519_PUB_KEY, callerNode);
        hoprToken.send(address(announcements), DEFAULT_KEY_BINDING_FEE, keyBindPayload);
        // tokens are burned
        assertEq(hoprToken.balanceOf(callerNode), 0);
        assertEq(hoprToken.totalSupply(), 0);
        // no multiaddr announced
        string memory registeredMultiAddress = announcements.multiaddrOf(callerNode);
        assertEq(registeredMultiAddress, '');

        vm.clearMockedCalls();
    }

    function testFuzz_Announcements(address caller)
        public
        callerNodeIsUnused(caller)
        mockNodeToSafe(caller, address(0))
    {
        vm.expectEmit(true, false, false, false, address(announcements));
        emit AddressAnnouncement(caller, MULTIADDRESS);

        vm.prank(caller);
        announcements.announce(MULTIADDRESS);

        vm.clearMockedCalls();
    }

    function testFuzz_AddressRevocation(address caller)
        public
        callerNodeIsUnused(caller)
        mockNodeToSafe(caller, address(0))
    {
        vm.expectEmit(true, false, false, false, address(announcements));
        emit RevokeAnnouncement(caller);

        vm.prank(caller);
        announcements.revoke();

        vm.clearMockedCalls();
    }

    function testFuzz_BindKeyAndAnnouncementFromNodeForTheFirstTime(address callerNode)
    public 
        callerNodeIsUnused(callerNode)
        mockNodeToSafe(callerNode, address(0))
        mockMintBalance(callerNode, DEFAULT_KEY_BINDING_FEE)
    {
        vm.expectEmit(true, false, false, false, address(announcements));
        emit AddressAnnouncement(callerNode, MULTIADDRESS);

        vm.expectEmit(true, false, false, false, address(announcements));
        emit KeyBinding(ED25519_SIG_0, ED25519_SIG_1, ED25519_PUB_KEY, callerNode);

        // prepare the key-binding payload, with announcing multiaddr
        bytes memory keyBindPayload = abi.encode(
            callerNode, ED25519_SIG_0, ED25519_SIG_1, ED25519_PUB_KEY, MULTIADDRESS
        );

        vm.prank(callerNode);
        hoprToken.send(address(announcements), DEFAULT_KEY_BINDING_FEE, keyBindPayload);

        // tokens are burned
        assertEq(hoprToken.balanceOf(callerNode), 0);
        assertEq(hoprToken.totalSupply(), 0);
        // no multiaddr announced
        string memory registeredMultiAddress = announcements.multiaddrOf(callerNode);
        assertEq(registeredMultiAddress, MULTIADDRESS);

        vm.clearMockedCalls();
    }

    function testFuzz_BindKeyWithoutAnnouncementFromNodeForTheFirstTime(address callerNode)
        public
        callerNodeIsUnused(callerNode)
        mockNodeToSafe(callerNode, address(0))
        mockMintBalance(callerNode, DEFAULT_KEY_BINDING_FEE)
    {
        vm.expectEmit(true, false, false, false, address(announcements));
        emit KeyBinding(ED25519_SIG_0, ED25519_SIG_1, ED25519_PUB_KEY, callerNode);

        // prepare the key-binding payload, without announcing multiaddr
        bytes memory keyBindPayload = abi.encode(
            callerNode, ED25519_SIG_0, ED25519_SIG_1, ED25519_PUB_KEY, ''
        );

        vm.prank(callerNode);
        hoprToken.send(address(announcements), DEFAULT_KEY_BINDING_FEE, keyBindPayload);

        // tokens are burned
        assertEq(hoprToken.balanceOf(callerNode), 0);
        assertEq(hoprToken.totalSupply(), 0);
        // no multiaddr announced
        string memory registeredMultiAddress = announcements.multiaddrOf(callerNode);
        assertEq(registeredMultiAddress, '');

        vm.clearMockedCalls();
    }

    function testFuzz_BindKeyAndAnnouncementFromSafeForTheFirstTime(address callerNode)
        public 
        callerNodeIsUnused(callerNode)
        mockNodeToSafe(callerNode, callerSafe)
        mockMintBalance(callerSafe, DEFAULT_KEY_BINDING_FEE)
    {
        vm.expectEmit(true, false, false, false, address(announcements));
        emit AddressAnnouncement(callerNode, MULTIADDRESS);

        vm.expectEmit(true, false, false, false, address(announcements));
        emit KeyBinding(ED25519_SIG_0, ED25519_SIG_1, ED25519_PUB_KEY, callerNode);

        // prepare the key-binding payload, with announcing multiaddr
        bytes memory keyBindPayload = abi.encode(
            callerNode, ED25519_SIG_0, ED25519_SIG_1, ED25519_PUB_KEY, MULTIADDRESS
        );

        vm.prank(callerSafe);
        hoprToken.send(address(announcements), DEFAULT_KEY_BINDING_FEE, keyBindPayload);

        // tokens are burned
        assertEq(hoprToken.balanceOf(callerSafe), 0);
        assertEq(hoprToken.totalSupply(), 0);
        // no multiaddr announced
        string memory registeredMultiAddress = announcements.multiaddrOf(callerNode);
        assertEq(registeredMultiAddress, MULTIADDRESS);

        vm.clearMockedCalls();
    }

    function testFuzz_BindKeyWithoutAnnouncementFromSafeForTheFirstTime(address callerNode)
        public 
        callerNodeIsUnused(callerNode)
        mockNodeToSafe(callerNode, callerSafe)
        mockMintBalance(callerSafe, DEFAULT_KEY_BINDING_FEE)
    {
        vm.expectEmit(true, false, false, false, address(announcements));
        emit KeyBinding(ED25519_SIG_0, ED25519_SIG_1, ED25519_PUB_KEY, callerNode);

        // prepare the key-binding payload, with announcing multiaddr
        bytes memory keyBindPayload = abi.encode(
            callerNode, ED25519_SIG_0, ED25519_SIG_1, ED25519_PUB_KEY, ''
        );

        vm.prank(callerSafe);
        hoprToken.send(address(announcements), DEFAULT_KEY_BINDING_FEE, keyBindPayload);

        // tokens are burned
        assertEq(hoprToken.balanceOf(callerSafe), 0);
        assertEq(hoprToken.totalSupply(), 0);
        // no multiaddr announced
        string memory registeredMultiAddress = announcements.multiaddrOf(callerNode);
        assertEq(registeredMultiAddress, '');

        vm.clearMockedCalls();
    }

    function testFuzz_BindKeyAndAnnouncementFromNodeAgain(address callerNode)
        public 
        callerNodeIsUnused(callerNode)
        mockNodeToSafe(callerNode, address(0))
        mockMintBalance(callerNode, DEFAULT_KEY_BINDING_FEE * 2)
    {
        // First time binding
        bytes memory keyBindPayload = abi.encode(
            callerNode, ED25519_SIG_0, ED25519_SIG_1, ED25519_PUB_KEY, MULTIADDRESS
        );

        vm.expectEmit(true, false, false, false, address(announcements));
        emit AddressAnnouncement(callerNode, MULTIADDRESS);

        vm.expectEmit(true, false, false, false, address(announcements));
        emit KeyBinding(ED25519_SIG_0, ED25519_SIG_1, ED25519_PUB_KEY, callerNode);

        vm.prank(callerNode);
        hoprToken.send(address(announcements), DEFAULT_KEY_BINDING_FEE, keyBindPayload);

        uint256 balanceAfterFirstBinding = hoprToken.balanceOf(callerNode);
        uint256 totalSupplyAfterFirstBinding = hoprToken.totalSupply();

        // Second time key binding is idempotent, no KeyBinding nor announcement event is expected
        vm.recordLogs();
        vm.prank(callerNode);
        hoprToken.send(address(announcements), 0, keyBindPayload);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        // there is no AddressAnnouncement nor KeyBinding event in the logs
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].topics[0], keccak256("AddressAnnouncement(address,string)"));
            assertNotEq(logs[i].topics[0], keccak256("KeyBindingFeeUpdate(uint256)"));
        }
    
        // tokens are burned
        assertEq(hoprToken.balanceOf(callerNode), balanceAfterFirstBinding);
        assertEq(hoprToken.totalSupply(), totalSupplyAfterFirstBinding);
        // multiaddr announced
        string memory registeredMultiAddress = announcements.multiaddrOf(callerNode);
        assertEq(registeredMultiAddress, MULTIADDRESS);

        vm.clearMockedCalls();
    }

    function testFuzz_AnnounceSafe(address callerNode)
        public
        callerNodeIsUnused(callerNode)
        mockNodeToSafe(callerNode, callerSafe)
    {
        vm.expectEmit(true, false, false, false, address(announcements));
        emit AddressAnnouncement(callerNode, MULTIADDRESS);

        vm.prank(callerSafe);
        announcements.announceSafe(callerNode, MULTIADDRESS);

        vm.clearMockedCalls();
    }

    function testFuzz_AnnounceSafeAgain(address callerNode)
        public
        callerNodeIsUnused(callerNode)
        mockNodeToSafe(callerNode, callerSafe)
    {
        vm.expectEmit(true, false, false, false, address(announcements));
        emit AddressAnnouncement(callerNode, MULTIADDRESS);

        vm.prank(callerSafe);
        announcements.announceSafe(callerNode, MULTIADDRESS);

        // announcing again with the same multiaddr is a no-op
        vm.recordLogs();
        vm.prank(callerSafe);
        announcements.announceSafe(callerNode, MULTIADDRESS);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
        // there is no AddressAnnouncement event in the logs
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].topics[0], keccak256("AddressAnnouncement(address,string)"));
        }

        vm.clearMockedCalls();
    }

    function testFuzz_RevokeSafe(address callerNode)
    public
        callerNodeIsUnused(callerNode)
        mockNodeToSafe(callerNode, callerSafe)
    {
        vm.expectEmit(true, false, false, false, address(announcements));
        emit RevokeAnnouncement(callerNode);
        vm.prank(callerSafe);
        announcements.revokeSafe(callerNode);
        vm.clearMockedCalls();
    }

    function testRevert_EmptyMultiAddr() public {
        vm.expectRevert(HoprAnnouncements.EmptyMultiaddr.selector);
        announcements.announce('');
    }

    function testFuzz_GetKeyBinding(bytes32[] memory bytes32Vals) public respectCurveRange(bytes32Vals) {
        uint256 createdCount = _helperCreateKeyBindingSet(bytes32Vals);

        KeyBindingWithSignatureTimestamp[] memory results = announcements.getAllKeyBindings();

        assertEq(results.length, createdCount);
        assertEq(results.length, announcements.getKeyBindingCount());

        for (uint256 i = 0; i < createdCount; i++) {
            KeyBindingWithSignatureTimestamp memory result_i = announcements.getKeyBindingWithKeyId(KeyId.wrap(uint32(i)));
            assertTrue(announcements.isOffchainKeyBound(result_i.ed25519_pub_key));

            (bool success, KeyId index, KeyBindingWithSignatureTimestamp memory tryBinding_i) =
                announcements.tryGetKeyBinding(result_i.ed25519_pub_key);
            assertTrue(success);
            assertEq(KeyId.unwrap(index), uint32(i));
            assertTrue(_compareKeyBinding(tryBinding_i, result_i));

            (bool success2, KeyId keyId) = announcements.getKeyIdWithOffchainKey(result_i.ed25519_pub_key);
            assertTrue(success2);
            assertEq(uint32(KeyId.unwrap(keyId)), i);

            KeyBindingWithSignatureTimestamp memory at_i = announcements.getKeyBindingWithKeyId(KeyId.wrap(uint32(i)));
            assertTrue(_compareKeyBinding(at_i, result_i));

            bytes32 pubkey_i = announcements.getOffchainKeyWithKeyId(KeyId.wrap(uint32(i)));
            assertEq(pubkey_i, result_i.ed25519_pub_key);
        }

        vm.clearMockedCalls();
    }

    function test_GetKeyIdRange() public view {
        (uint32 minKeyId, uint32 maxKeyId) = announcements.getKeyIdRange();
        assertEq(minKeyId, 0);
        assertEq(maxKeyId, type(uint32).max);
    }

    /**
     * @dev helper function to create a set for fuzz testing
     */
    function _helperCreateKeyBindingSet(bytes32[] memory bytes32Vals) private returns (uint256) {
        uint256 counter = 0;
        for (uint256 i = 0; i < bytes32Vals.length; i++) {
            // only add unique non-existing ed25519_pub_key
            if (!announcements.isOffchainKeyBound(bytes32Vals[i])) {
                address caller = vm.addr(uint256(bytes32Vals[i]));
                // ensure the caller address is not used
                assumeUnusedAddress(caller);
                // mock no safe is associated with the caller node
                vm.mockCall(
                    address(safeRegistry), abi.encodeWithSignature("nodeToSafe(address)", caller), abi.encode(address(0))
                );
                // mock mint balance for key binding fee
                vm.prank(deployer);
                hoprToken.mint(caller, DEFAULT_KEY_BINDING_FEE, '', '');

                // prepare the key-binding payload, without announcing multiaddr
                bytes memory keyBindPayload = abi.encode(
                    caller, bytes32Vals[i], bytes32Vals[i], bytes32Vals[i], ''
                );

                vm.prank(caller);
                hoprToken.send(address(announcements), DEFAULT_KEY_BINDING_FEE, keyBindPayload);
                counter++;
            }
        }
        return counter;
    }

    function _compareKeyBinding(KeyBindingWithSignatureTimestamp memory a, KeyBindingWithSignatureTimestamp memory b)
        private
        pure
        returns (bool)
    {
        return (a.ed25519_sig_0 == b.ed25519_sig_0 && a.ed25519_sig_1 == b.ed25519_sig_1
                && a.ed25519_pub_key == b.ed25519_pub_key && a.chain_key == b.chain_key && a.boundTimestamp == b.boundTimestamp);
    }
}
