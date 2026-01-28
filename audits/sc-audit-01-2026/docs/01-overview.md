---
layout: default
title: Overview Audit 2026 Jan
---

## Introduction

This documents provides an overview of the HOPR smart contracts as the basis for
the smart contracts audit in 01/2026. It describes the relevant threat model,
sets the scope, gives a high-level description of the relevant smart contracts
and their relation and ABIs. Moreover, it provides pointers to the source code
and steps on how to run tests and other operations on it.

## Scope

All HOPR smart contracts can be found in the hoprnet/contracts repository, of branch `main`:

```
https://github.com/hoprnet/contracts/tree/main
```

The Git commit hash under audit is:

```
d6e2b0c5f9ff543fa1533656376ade05047363c6
```

All smart contracts can be found within the folder:

```
ethereum/contracts/src
```

For convenience, the following link points to the source folder using the
correct version:

```
https://github.com/hoprnet/contracts/tree/d6e2b0c5f9ff543fa1533656376ade05047363c6/ethereum/contracts/src
```

Specifically, the following contracts are within the scope of the audit:

```bash
├── Announcements.sol # Announce nodes' multiaddress and key-bindings
├── Channels.sol # payment channels between nodes in the HOPR network
├── Crypto.sol # crypto primitives
├── Ledger.sol # snapshot-based indexing of Hopr Channels
├── MultiSig.sol # abstraction of interaction between nodes and Safes in the HOPR network
├── TicketPriceOracle.sol # oracle for network ticket price
├── WinningProbabilityOracle.sol # oracle for network minimum winning probability
├── node-stake
│   ├── migration
│       ├── NodeSafeMigration.sol # registry for nodes and Safes in the HOPR network
│   ├── NodeSafeRegistry.sol # ledger to register the association of nodes and safes
│   ├── NodeStakeFactory.sol # factory contract to deploy Safe and node management Module for node runners
│   └── permissioned-module
│       ├── CapabilityPermissions.sol # library for capability management of node management Module
│       └── NodeManagementModule.sol # implementation logics for node management Module
└── utils
    └── EnumerableKeyBindingSet.sol # enumerable sets for types related to key-bindings
```

There are some known issues that have been discovered and documented [here](https://github.com/hoprnet/hoprnet/issues/5501).
However, not all of these were addressed prior to the time of the audit.

### Out of Scope

The following contracts are out of scope:

```bash
├── static # existing contracts which will not be updated
│   ├── stake
│       ├── mocks
│           ├── ERC777Mock.sol
│           └── ERC677Mock.sol
│       ├── HoprStakeSeason8.sol
│       ├── HoprStake2.sol
│       ├── HoprWhitehat.sol
│       ├── HoprBoost.sol
│       ├── IHoprBoost.sol
│       ├── HoprStakeBase.sol
│       ├── HoprStake.sol
│       ├── HoprStakeSeason3.sol
│       ├── HoprStakeSeason7.sol
│       ├── HoprStakeSeason6.sol
│       ├── HoprStakeSeason4.sol
│       └── HoprStakeSeason5.sol
│   ├── proxy
│       ├── StakingProxyForNetworkRegistry.sol
│       ├── SafeProxyForNetworkRegistry.sol
│       └── DummyProxyForNetworkRegistry.sol
│   ├── HoprWrapperProxy.sol
│   ├── HoprToken.sol
│   ├── HoprWrapper.sol
│   ├── ERC777
│       └── ERC777Snapshot.sol
│   ├── HoprDistributor.sol
│   ├── HoprForwarder.sol
│   ├── NetworkRegistry.sol
│   ├── openzeppelin-contracts
│       ├── README.md
│       └── ERC777.sol
```

## Concepts

The HOPR protocol uses smart contracts for different concepts. The 2 relevant
concepts for this audit are the `Incentivization Mechanism` and `Staking`. Other
concepts, while using smart contracts, don't touch funds or have limited impact
on the operation of the protocol which is why they are not in the scope of the
audit.

#### Safe

At the center each user has a `Safe`, also called `NodeSafe`, which is configured to use the custom `NodeManagementModule` module. `AdminKey`s are registered in the `NodeSafe` as owners, while `ChainKey`s are delegates. The `NodeManagementModule` implements capability permission checking for transactions which are to be executed by a `Chain Key` directly. To allow for those checks to work a `Chain Key` must be registered within the `NodeManagementModule` beforehand.

![NodeSafe Overview](./images/safe-keys-overview.png)

#### Deployment

The deployment of the entire initial setup is done through the `NodeStakeFactory`. It takes care of deploying and configuring the respective contracts and handing over ownership to the user at the end. The result of a complete deployment is a new `NodeSafe` which is configured to use a newly deployed `NodeManagementModule` and has the user's account set as owner.

![Deployment flow of a new NodeSafe](./images/node-stake-factory.png)

#### Operations

As described earlier operations on payment channels can have different flow
depending on the sender of the transaction and the target of the transaction. We
distinguish between 3 flows:

1. `Admin Key`s perform operation directly through `NodeSafe`.
1. Node (`Chain Key`) can perform an operation directly via the `NodeManagementModule`.
1. Node submits transaction to `NodeSafe` as delegate, transaction is then
   signed and executed by `Admin Key`(s).

Option 1 will always work and is the fallback mechanism to recover from
compromised or lost `Chain Keys`. Its a manual interaction by the user

Option 2 is the automated flow where a node may operate autonomous and perform
on-chain operations regarding the payment channels as needed.

Option 3 is the co-signing flow, where the proposal of a transaction by a node
(a delegate of the `NodeSafe`) is considered the first signature and the `Admin
Keys` can perform the final signatures and execute the transaction. This option
can be used for high-value channels or critical operations which a user would
like to manually sign off on.

Options which involve `Chain Keys` are implemented through so called `GranularPermission` which can
be `ALLOW` to enable option 2 (however option 3 is possible too at this point) and `BLOCK` to force option 3.

The call targets for which the `NodeManagementModule` checks these permissions
are a small list of actions a node might want to perform:

- `HoprChannels.redeemTicketSafe`
- `HoprChannels.closeIncomingChannelSafe`
- `HoprChannels.initiateOutgoingChannelClosureSafe`
- `HoprChannels.finalizeOutgoingChannelClosureSafe`
- `HoprChannels.fundChannelSafe`
- `HoprToken.approve`
- `HoprToken.send`

![Decision flow within NodeManagementModule for Option 2](./images/tx-flow-nodesafe.png)

### Incentivization Mechanism

The HOPR protocol relies on node's being paid for relaying packets. This
payment, the incentiviation, ensures nodes perform their service as best as
they can. Its realized through the novel `Proof of Relay` scheme, whereby its
cryptograhically ensured that a node has performed the relay service and may try
to get paid for it. The payment is encapsulated as a so called `Ticket` which
has a `Winning Probability`. The implementation of this uses unidirectional
payment channels between two nodes where the source node locks funds into the
channel, assuring the destination node that it can get paid out of those locked
funds when performing the relaying service. In order to get paid the destination
node presents a received ticket via the `redeemTicket` function, which may lead
to a payout of funds.

The on-chain parts of this concept are implemented in the `Channels.sol` file as
the `HoprChannels` contract.

### Proof-Of-Relay

Messages in the HOPR network are sent as packets along paths. When sending a packet, the source samples a random path and encodes it into the packet. By using the SPHINX packet format, the creator of the packet derives a shared key with each node along the path. This allows the sender to create secret sharings for adjacent nodes along the path. Once a node processes a mixnet packet, it is able to derive the first part of the secret share. The second part can be derived by the next downstream node and gets sent as an acknowledgement.

In order to claim incentives on-chain for relaying packets, nodes need to reveal the reconstructed secret which we call `porSecret`. This proves to the smart contract that a node has processed a mixnet packet and that the next downstream node has received it and considered it valid.

### Probabilistic Payments

To decouple packet processing from observable on-chain state changes when claiming the incentive for relaying a packet, the HOPR protocol makes use of probabilistic payments. This is not only beneficial for privacy reasons, it also minimizes the number of on-chain state changes.

Incentives for relaying packets are embedded in a data structure that we call "ticket". Once issued, each ticket has a winning probability, which compiles some tickets into an actual payout whereas other do not have any added value. Note that at the time a ticket is issued, it is unclear whether the ticket is a win or not. The HOPR protocol hides this information until the relayer has received the acknowledgement from the next downstream node.

The relayer then combines both key shares and derives a deterministic but pseudo-random secret using a verifiable random function (VRF) that takes the node's private key and the serial number of the ticket. The decision whether a ticket is a win thus depends on entropy from the relayer and from the creator of the packet.

In case ticket issuer and packet creator are not the same party, which applies to all relayers, the ticket issuer has no control on the conditions which turn a ticket into a win or not. To prevent the ticket issuer collusion attacks of packet creator and next downstream node, the decision whether a ticket is a win also depends on the signature of the ticket issuer over the ticket data.

### Payment Channels

By default, probabilisitic payments come with no guarantee that there are any funds to cover for a winning ticket. To still secure payments, nodes create a deposit from which the payout of a ticket gets deducted.

Within the HOPR protocol, creating such a deposit is implemented using unidirectional payment channels. The node who creates the deposit is referred to as source of the payment channel whereas the the node who claim incentives for relaying packets is called destination of the payment channel.

Each payment channel is modeled by a finite state machine with three states: `OPEN`, `CLOSED` and `PENDING_TO_CLOSE`. A payment channel with state `CLOSED` does not include any funds and thus cannot be used for claiming incentives. Once a node deposits funds in a payment channel, the channel has state `OPEN`. As long as the payment channel has state or `OPEN` or `PENDING_TO_CLOSE`, the destination of the payment channel is allowed to claim incentives for relaying packets, which we call "redeem tickets". Payment channels can be torn down in order to pull out locked funds. This can be initiated by the source and the destination of the payment channel. In case of the latter, this can happen immediately and results in the deposited fund being transferred to the source of the payment channel. On the other hand, if the source attempts to close the channel, it must be possible for the destination to redeem all their tickets as they lose their validity once the channel gets closed. For that reason, the protocol foresees a notice period in which the destination of a payment channel has the opportunity to redeem all their tickets. This state is called `PENDING_TO_CLOSE`. Once the notice period is due, the source or the destination of the payment channel can finally close the channel.

```
                                  redeemTicket()
                                     ┌──────┐
 finalizeOutgoingChannelClosure()         v      │
  (after notice period), or  ┌──────────────────────┐
  closeIncomingChannel()     │                      │ initiateOutgoingChannelClosure()
            ┌────────────────│   Pending To Close   │<─────────────────┐
            │                │                      │                  │
            │                └──────────────────────┘                  │
            v                                                          │
     ┌────────────┐      tokensReceived() / fundChannel()         ┌──────────┐
     │            │──────────────────────────────────────────────>│          │
     │   Closed   │           closeIncomingChannel()              │   Open   │
     │            │<──────────────────────────────────────────────│          │
     └────────────┘                                               └──────────┘
                                                                    │      ^
                                                                    └──────┘
                                                                  redeemTicket()
```

### Aggregatable tickets

Tickets encode a winning probability which is chosen when issuing the ticket. As not all tickets lead to an actual payout, the value of a ticket is given by the expected value, the product of winning probability and the embedded amount. Winning probability and amount should be chosen according to the usage of the data channel link between source and destination such that there is high chance to have a winning probability in a defined time interval that can be one hour.

Although the node has received a winning ticket, that ticket needs to be submitted to the smart contract and thus leads to a potentially costly state change.

To mitigate this, winning tickets can get aggregated off-chain by the ticket issuer. To do so, the ticket redeemer proves to the ticket issuer that it has received a winning ticket. Since the decision whether a ticket is a win is deterministic and only depends on the ticket, this does not reveal sensitive information to the ticket issuer. Therefore, the ticket issuer can issue a ticket with 100% winning probabilitiy worth the sum of all presented tickets.

## Threat Model

In our design we consider the following actors:

1. Node Runner: A user who is running one or many HOPR nodes and therefore
   participates in the network. A node runner is expected to be honest, but
   greedy to the extend where the HOPR protocol allows it ROI is maximized.
2. Malicious Node Runner: A user who is running one or many HOPR nodes and therefore
   participates in the network. With ill intend the user may try to cheat the
   network to (a) earn more rewards, (b) deny other users their rewards or
   (c) circumvent privacy assurances given by the protocol.
3. Attacker: A user who is not running any nodes but exploits weaknesses in a
   node runner's setup both on- and off-chain.

To that extend access to various parts of the HOPR protocol has been separated
into 3 private keys as previously explained.

1. Packet Key
2. Chain Key
3. Admin Key

Moreover, the 2 main concepts cover different functionality:

1. `Node Safe` is responsible for authorization.
2. `Hopr Channels` are responsible for runtime procotol execution.

The following assumptions are made to define the scope of efforts made to secure
authorization and runtime protocol execution:

- An admin key is safe against exploitation. Thus, our measures don't concern
  themselves with compromised admin keys and rely on general account safety
  measures performed by the user.
- The system a node is running on may be exploited, giving the attacker access
  to the packet key and/or chain key of that node. Such access may result in the
  attacker deleting these keys.

Based on that these scenarios were considered in the design of the staking and
incentiviation mechanism:

1. A node's chain key is compromised. The attacker gains the ability to perform
   on-chain operations using that key.
   1. The attacker may drain the xDai balance of the account. We advise users to
      store a minimal amount of funds needed to pay for on-chain operations but don't
      overfund the account or use it to store xDai for a longer period of time.
   2. The attacker may close payment channels. Funds (wxHOPR) from those payment
      channels would flow back into the staking account.
   3. The attacker may delete the chain key. The node would become inoperable.
      The user could recover funds by initiating payment channel closures with the
      admin key.
2. A node's packet key is compromised. The attacker gains no funds-related
   capabilities.
3. An admin key is compromised, giving the attacker access to the user's `Node
Safe` and therefore full access to funds and authorization. In this case the
   attack is limited to the user's `Node Safe`.

## Contracts v4 vs v3

Compared with the last audit conducted in 2024, the current version of HOPR smart contracts
(i.e. version 4, noted as "v4" for short) has done the following high-level changes:

1. Introduced token burning mechanism in key-binding process.
2. Merged the creation and setup process for safe and node-stake module when onboarding new node runners.
3. Introduced migration contract for upgrading Safe implementation, and deploy new v4 module.
4. Bumped dependencies version and solc version in all the contracts

### Key-binding and announcement

`HoprAnnouncements` is an Ownable and UUPS-upgradeable contract that publishes transport-layer metadata for HOPR nodes.
It maintains:

1. an append-only key-binding registry (`_keyBindings`) that maps an ed25519 public key (offchain key) to a tuple `{ed25519_sig_0, ed25519_sig_1, ed25519_pub_key, chain_key(address)}` with a monotonically increasing key id (bounded to `uint32` / `[0, 2^32-1]` via the library)
2. a mapping from a secp256k1 chain-key (node address) to an optional base multiaddress (`multiaddrOf`).
   Key bindings are idempotent re-binding an existing off-chain pubkey returns the existing id and does not overwrite/reuse ids.
   Announcement is also idempotent: re-announcing the same multiaddr is a no-op.

Key binding is primarily performed through the ERC777 `tokensReceived` hook:
Each new key binding burns some wxHOPR tokens, which is charged as "key-binding fee".
The contract only accepts the configured `TOKEN` (wxHOPR). `userData` must ABI-decode to `(nodeAddress, ed25519_sig_0, ed25519_sig_1, ed25519_pub_key, baseMultiaddr)`;
the sender must be either the node itself (if no Safe exists) or the node’s associated Safe from `HoprNodeSafeRegistry` (enforced via `HoprMultiSig`/`registry.nodeToSafe`).
If the binding is new, `amount` must equal `keyBindingFee`; if the key already exists, `amount` must be zero (otherwise revert).
After optional announcement (if `baseMultiaddr` non-empty), any positive `amount` is burned via `TOKEN.burn(amount, "")`.
The contract explicitly does NOT verify EdDSA signatures on-chain (noted as off-chain verification).

Announcements/revocations can be done separately via:

- `announce()`/`revoke()` (only when no Safe is set), or
- `announceSafe(selfAddress, ...)`/`revokeSafe(selfAddress)` (only callable by the associated Safe).

`updateKeyBindingFee()` is owner-only; upgrades follow the UUPS pattern and are authorized via the `_authorizeUpgrade` hook, which enforces UUPS upgrade authorization by the owner.
The contract emits indexed events for key bindings, address announcements, revocations, and fee updates.
It exposes view helpers to enumerate key bindings, query by pubkey, and fetch bindings by key id (with `getAllKeyBindings()` marked as gas-expensive).

### Channels

The main logic of Channels contract remains the same as in the previous version (v3).
The main changes are:

- The storage layout has been re-ordered.
- All the events emit the updated state of channels with `_channelState(channelId)`.
- `EfficientHashLib.hash` replaces `keccak256(abi.encode(...))`
- Replaced `indexOffset` parameter with `BASE_INDEX_OFFSET` constant. Removal of `indexOffset` disables the aggregated ticket redemption.
- Changed public immutable from `token` to `TOKEN`

### Crypto

The main logic of Channels contract remains the same as in the previous version (v3).
The main changes are:

- Free memory space used by the pointer in `expandMessageXMDKeccak256()` to address https://github.com/hoprnet/hoprnet/issues/6461
- Use `INDEX_SNAPSHOT_INTERVAL = 1 days` as default `SNAPSHOT_INTERVAL` in inherited contracts

### Ledger

The main logic of Channels contract remains the same as in the previous version (v3).
The main changes are:

- Added view function for `latestRoot()`
- `EfficientHashLib.hash` replaces `keccak256(abi.encode(...))`
- Updated default `SNAPSHOT_INTERVAL`

### NodeSafeMigration

`HoprNodeSafeMigration` is a migration helper meant to be delegatecalled from a Gnosis Safe.
It targets migrating:

- a HOPR “Node Safe” from an older Safe implementation to a newer L2-compatible singleton, and/or
- upgrading/replacing the Safe’s enabled HOPR module.
  The contract stores two immutables: `MODULE_SINGLETON` (new module implementation/singleton address) and `FACTORY_ADDRESS` (HoprNodeStakeFactory used to deploy new module proxies).
  Each NodeSafeMigration contract will upgrade safe and modules to their dedicated implementations.

All externally callable actions are gated by `onlyDelegateCall` and, when operating on an existing module, `onlyEnabledModule(moduleProxy)` which checks (a) the Safe has the module enabled via `IAvatar(address(this)).isModuleEnabled` and (b) the module proxy’s `owner()` is the Safe (`IOwner(moduleProxy).owner() == address(this)`), otherwise reverting with `ModuleNotEnabledInSafe`.
`migrateModuleSingleton` upgrades an existing upgradeable module proxy by having the Safe (as owner) call `upgradeToAndCall(MODULE_SINGLETON, data)` on the module, emitting `ChangedModuleImplementation`.

`migrateSafeV141ToL2AndMigrateToUpgradeableModule` performs a combined migration: it calls `migrateL2Singleton()` (Safe impl migration) then sets the Safe fallback handler to `SAFE_FALLBACK_HANDLER`.
It also best-effort sets the Safe as the ERC1820 implementer for `ERC777TokensRecipient` by calling the known ERC1820 registry via `execute(...)` and explicitly ignores failure.
It then deploys a new module proxy via `IHoprNodeStakeFactory(FACTORY_ADDRESS).deployModule(safe, defaultTarget, nonce)`, bulk-includes `nodes`, enables the new module on the Safe, and disables the old module (passing `(newModuleProxy, oldModuleProxy)` to `disableModule`).
`deployNewV4Module` is a lighter path that just deploys, then includes nodes, and then enables the new module without disabling the old one, emitting `DeployedNewV4Module`.

### NodeSafeRegistry

- Removed `ensureNodeIsSafeModuleMember(address safeAddress, address nodeChainKeyAddress)` function and all the checks invoking this function.

### NodeStakeFactory

`HoprNodeStakeFactory` is an Ownable2Step factory that deploys:

- 1-of-n Gnosis Safe proxy (Safe v1.4.1 tooling) and
- a UUPS-style module proxy (`ERC1967Proxy` deployed via `CREATE2`) used for HOPR node management.

It tracks deployments in an enumerable set (`_safeModule`) keyed by Safe proxy address, exposing `getAllDeployments`, `isSafeDeployedByFactory`, and lookup-by-index/address helpers.
The owner can update the module singleton address, Safe library addresses (Safe singleton, proxy factory, fallback handler, multisend), default HOPR network params (token, default allowance, default announcement target), and can reclaim arbitrary ERC20 balances held by the factory.

The factory is also an ERC777 recipient registered in ERC1820.
Upon receiving wxHOPR tokens with adequate `userData`, it deploys safe and module with optional inclusion of nodes.
The `userData` must decode to `(functionIdentifier, nonce, defaultTarget, admins)` where `functionIdentifier` selects between two internal flows: `_deploySafeAndModule` or `_deploySafeAndModuleAndIncludeNodes`, any other identifier reverts.
After deploying, the received ERC20 tokens are forwarded to the newly created Safe.
Admin validation enforces at least one admin and forbids using the factory address as an admin.
Internally, the factory temporarily appends itself as an additional Safe owner (via inline assembly) so it can execute initial Safe transactions, and later removes itself.

Deployment flow: `_deploySafe` creates a Safe proxy via `SafeProxyFactory.createProxyWithNonce` and initializes it with `setup(admins, threshold=1, fallbackHandler, ...)`.
`_deployModule` deterministically deploys an `ERC1967Proxy` using `Create2.deploy` with salt `keccak256(caller, nonce)`, initializing the module with `(safeProxy, multisend, defaultAnnouncementTarget, defaultTarget)` via `initialize(bytes)`.
The factory then uses `Safe.execTransaction` with an EIP-1271-style precomputed signature (`approvalHashSig`) to queue/configure the Safe:

- set ERC1820 `ERC777TokensRecipient` implementer to the Safe itself
- enable the module
- approve the “channels”/target contract (derived from `defaultTarget`) to spend tokens up to `defaultTokenAllowance`
- optionally call `includeNodes(admins)` on the module (second flow)
- remove the factory from the Safe owners.

The contract also provides `predictSafeAddress` and `predictModuleAddress` helpers to precompute deterministic deployment addresses.

### CapabilityPermissions

- Reordered storage layout

### NodeManagementModule

- Reordered storage layout
- Added `_defaultAnnouncementTarget` in `initialize()` to configure Announcement contract as target in modules.
- Make `addNode`, `addNodes`, and `includeNodes` functions payable to allow funding nodes with native tokens while being included in the module

### EnumerableKeyBindingSet.sol

Helper functions for operations on `KeyBindingWithSignature`s, `KeyBindingWithSignatureTimestamp`s, and `KeyBindingSet`.

### Other contracts

The following changes have been applied:

- Bump solc version to `0.8.30`
- Some contracts include `Ownable`, or `Ownable2Step` (for two-step ownership transfer).
- `EfficientHashLib.hash` replaces `keccak256(abi.encode(...))`

## Testing

All smart contracts in scope have test coverage using unit tests and fuzzy
tests. These tests use `forge` and may be executed by running the following
commands:

```bash
cd ethereum/contracts
just smart-contract-test
```
