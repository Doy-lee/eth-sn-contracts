// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "./interfaces/IServiceNodeRewards.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "./libraries/Pairing.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title Service Node Rewards Contract
/// @notice This contract manages the rewards and public keys for service nodes.
contract ServiceNodeRewards is Initializable, Ownable2StepUpgradeable, PausableUpgradeable, IServiceNodeRewards {
    using SafeERC20 for IERC20;

    bool                            public          started;

    IERC20                          public          designatedToken;
    IERC20                          public          foundationPool;

    uint64                          public constant LIST_SENTINEL                      = 0;
    uint256                         public constant MAX_SERVICE_NODE_REMOVAL_WAIT_TIME = 30 days;

    uint64                          public          nextServiceNodeID;
    uint256                         public          totalNodes;
    uint256                         public          blsNonSignerThreshold;
    uint256                         public          blsNonSignerThresholdMax;

    bytes32                         public          proofOfPossessionTag;
    bytes32                         public          rewardTag;
    bytes32                         public          removalTag;
    bytes32                         public          liquidateTag;

    uint256                         private         _stakingRequirement;
    uint256                                         _liquidatorRewardRatio;
    uint256                                         _poolShareOfLiquidationRatio;
    uint256                                         _recipientRatio;

    mapping(uint64  => ServiceNode) private         _serviceNodes;
    mapping(address => Recipient  ) public          recipients;
    mapping(bytes   => uint64     ) public          serviceNodeIDs; // Maps a bls public key (G1Point) to a serviceNodeID

    BN256G1.G1Point                 public          _aggregatePubkey;

    // MODIFIERS
    modifier whenStarted() {
        if (!started) {
            revert ContractNotStarted();
        }
        _;
    }

    // EVENTS
    event NewSeededServiceNode           (uint64 indexed serviceNodeID, BN256G1.G1Point pubkey);
    event NewServiceNode                 (uint64 indexed serviceNodeID, address recipient, BN256G1.G1Point pubkey, ServiceNodeParams serviceNode, Contributor[] contributors);
    event RewardsBalanceUpdated          (address indexed recipientAddress, uint256 amount, uint256 previousBalance);
    event RewardsClaimed                 (address indexed recipientAddress, uint256 amount);
    event BLSNonSignerThresholdMaxUpdated(uint256 newMax);
    event ServiceNodeLiquidated          (uint64 indexed serviceNodeID, address recipient, BN256G1.G1Point pubkey);
    event ServiceNodeRemoval             (uint64 indexed serviceNodeID, address recipient, uint256 returnedAmount, BN256G1.G1Point pubkey);
    event ServiceNodeRemovalRequest      (uint64 indexed serviceNodeID, address recipient, BN256G1.G1Point pubkey);
    event StakingRequirementUpdated      (uint256 newRequirement);

    // ERRORS
    error ArrayLengthMismatch         ();
    error DeleteSentinelNodeNotAllowed();
    error BLSPubkeyAlreadyExists      (uint64 serviceNodeID);
    error BLSPubkeyDoesNotMatch       (uint64 serviceNodeID, BN256G1.G1Point pubkey);
    error ContractAlreadyStarted      ();
    error ContractNotStarted          ();
    error ContributionTotalMismatch   (uint256 required, uint256 provided);
    error EarlierLeaveRequestMade     (uint64 serviceNodeID, address recipient);
    error FirstContributorMismatch    (address operator, address contributor);
    error InsufficientBLSSignatures   (uint256 numSigners, uint256 requiredSigners);
    error InvalidBLSSignature         ();
    error InvalidBLSProofOfPossession ();
    error LeaveRequestTooEarly        (uint64 serviceNodeID, uint256 timestamp, uint256 currenttime);
    error NullRecipient               ();
    error RecipientAddressDoesNotMatch(address expectedRecipient, address providedRecipient, uint256 serviceNodeID);
    error RecipientRewardsTooLow      ();
    error ServiceNodeDoesntExist      (uint64 serviceNodeID);

    /// @notice Create a service node rewards contract responsible for managing
    /// the service node list and rewards of participants.
    ///
    /// @dev Variables of the contract are deferred and initialised in the
    /// constructor to permit contract upgradability.
    ///
    /// @param token_ The token used for rewards
    /// @param foundationPool_ The foundation pool for the token
    /// @param stakingRequirement_ The staking requirement for service nodes
    /// @param liquidatorRewardRatio_ The reward ratio for liquidators
    /// @param poolShareOfLiquidationRatio_ The pool share ratio during liquidation
    /// @param recipientRatio_ The recipient ratio for rewards
    function initialize(address token_, address foundationPool_, uint256 stakingRequirement_, uint256 liquidatorRewardRatio_, uint256 poolShareOfLiquidationRatio_, uint256 recipientRatio_) initializer()  public {
        if (recipientRatio_ < 1) revert RecipientRewardsTooLow();
        started                      = false;
        nextServiceNodeID            = 1;
        totalNodes                   = 0;
        blsNonSignerThreshold        = 0;
        blsNonSignerThresholdMax     = 300;
        proofOfPossessionTag         = buildTag("BLS_SIG_TRYANDINCREMENT_POP");
        rewardTag                    = buildTag("BLS_SIG_TRYANDINCREMENT_REWARD");
        removalTag                   = buildTag("BLS_SIG_TRYANDINCREMENT_REMOVE");
        liquidateTag                 = buildTag("BLS_SIG_TRYANDINCREMENT_LIQUIDATE");

        designatedToken              = IERC20(token_);
        foundationPool               = IERC20(foundationPool_);
        _stakingRequirement          = stakingRequirement_;
        _liquidatorRewardRatio       = liquidatorRewardRatio_;
        _poolShareOfLiquidationRatio = poolShareOfLiquidationRatio_;
        _recipientRatio              = recipientRatio_;
        nextServiceNodeID            = LIST_SENTINEL + 1;

        // Doubly-linked list with sentinel that points to itself.
        //
        // +-<prev- [Sentinel] -next->-+
        // |                           |
        // +----------------------------

        _serviceNodes[LIST_SENTINEL].prev = LIST_SENTINEL;
        _serviceNodes[LIST_SENTINEL].next = LIST_SENTINEL;
        __Ownable_init(msg.sender);
    }

    //////////////////////////////////////////////////////////////
    //                                                          //
    //                  State-changing functions                //
    //                                                          //
    //////////////////////////////////////////////////////////////

    /// CLAIMING REWARDS
    /// This section contains all the functions necessary for a user to receive
    /// tokens from the service node network as follows. The user will:
    ///
    /// 1) Go to service node network and request they sign an amount that they
    ///    are allowed to claim. Each node will individually sign the user's
    ///    details into an aggregate signature.
    /// 2) Call `updateRewardsBalance` with their details and the produced
    ///    signature. This signature is verified and the user's rewards balance
    ///    is updated.
    /// 3) Call `claimRewards` which will pay out the unclaimed rewards to the
    ///    user.

    /// @notice Updates the rewards balance for a given recipient. Calling this
    /// requires a BLS signature from the network.
    ///
    /// @param recipientAddress Address of the recipient to update.
    /// @param recipientRewards Amount of rewards the recipient is allowed to
    /// claim.
    /// @param blsSignature 128 byte BLS proof of possession signature, signed
    /// over the tag, `recipientAddress` and `recipientRewards`.
    /// @param ids Array of service node IDs that were non-signers and are to be
    /// excluded from the `aggregatePubkey`.
    function updateRewardsBalance(address recipientAddress, uint256 recipientRewards, BLSSignatureParams calldata blsSignature, uint64[] memory ids) external
        whenNotPaused
        whenStarted
    {
        if (recipientAddress == address(0)) {
            revert NullRecipient();
        }

        if (ids.length > blsNonSignerThreshold) {
            revert InsufficientBLSSignatures(serviceNodesLength() - ids.length,
                                             serviceNodesLength() - blsNonSignerThreshold);
        }

        uint256 previousRewards = recipients[receipientAddress].rewards;
        if (previousRewards >= recipientRewards) {
            revert RecipientRewardsTooLow();
        }

        // NOTE: Generate the non-signer pubkey
        BN256G1.G1Point memory pubkey;
        for(uint256 i = 0; i < ids.length; i++) {
                pubkey = BN256G1.add(pubkey, _serviceNodes[ids[i]].pubkey);
        }

        // NOTE: Remove non-signer keys from the aggregate key
        pubkey = BN256G1.add(_aggregatePubkey, BN256G1.negate(pubkey));

        // NOTE: Create signature and verify
        BN256G2.G2Point memory signature      = BN256G2.G2Point([blsSignature.sigs1,blsSignature.sigs0],[blsSignature.sigs3,blsSignature.sigs2]);
        bytes           memory encodedMessage = abi.encodePacked(rewardTag, recipientAddress, recipientRewards);
        BN256G2.G2Point memory Hm             = BN256G2.hashToG2(BN256G2.hashToField(string(encodedMessage)));

        if (!Pairing.pairing2(BN256G1.P1(), signature, BN256G1.negate(pubkey), Hm)) {
            revert InvalidBLSSignature();
        }

        // NOTE: Update rewards amount
        recipients[recipientAddress].rewards = recipientRewards;
        emit RewardsBalanceUpdated(recipientAddress, recipientRewards, previousRewards);
    }

    /// @notice Claim the rewards due for the active wallet invoking the claim.
    function claimRewards() public {
        uint256 claimedRewards         = recipients[msg.sender].claimed;
        uint256 totalRewards           = recipients[msg.sender].rewards;
        uint256 amountToRedeem         = totalRewards - claimedRewards;
        recipients[msg.sender].claimed = totalRewards;
        SafeERC20.safeTransfer(designatedToken, msg.sender, amountToRedeem);
        emit RewardsClaimed(msg.sender, amountToRedeem);
    }

    /// MANAGING BLS PUBLIC KEY LIST
    /// This section contains all the functions necessary to add and remove
    /// service nodes from the service nodes linked list. The regular process
    /// for a new user is to call `addBLSPublicKey` with the details of their
    /// service node. The smart contract will do some verification over the bls
    /// key, take a staked amount of SENT tokens, and then add this node to
    /// its internal public key list. Keys that are in this list will be able to
    /// participate in BLS signing events going forward (such as allowing the
    /// withdrawal of funds and removal of other BLS keys)
    ///
    /// To leave the network and get the staked amount back the user should
    /// first initate the removal of their key by calling
    /// `initiateRemoveBLSPublicKey` this function simply notifys the network
    /// and begins a timer of 15 days which the user must wait before they can
    /// exit. Once the 15 days has passed the network will then provide a bls
    /// signature so the user can call `removeBLSPublicKeyWithSignature` which
    /// will remove their public key from the linked list. Once this occurs the
    /// network will then allow the user to claim their stake back via the
    /// `updateRewards` and `claimRewards` functions.

    /// @notice Adds a BLS public key to the list of service nodes. Requires
    /// a proof of possession BLS signature to prove user controls the public
    /// key being added.
    ///
    /// @param blsPubkey 64 byte BLS public key.
    /// @param blsSignature 128 byte BLS signature that proves ownership of the
    /// private component of the public key (proof-of-possession signature).
    /// @param serviceNodeParams The service node to add including the x25519
    /// public key and signature that proves ownership of the private component
    /// of the public key and the desired fee the operator is charging.
    /// @param contributors An optional list of contributors for
    /// multi-contribution service nodes. The first contributor's information
    /// must be set to the operator (the current interacting wallet).
    ///
    /// If this list of empty, it is assumed that the service node is ran in
    /// a solo configuration under the current interacting wallet.
    function addBLSPublicKey(BN256G1.G1Point calldata blsPubkey, BLSSignatureParams calldata blsSignature, ServiceNodeParams calldata serviceNodeParams, Contributor[] calldata contributors) external whenNotPaused {
        _addBLSPublicKey(blsPubkey, blsSignature, msg.sender, serviceNodeParams, contributors);
    }

    /// @dev Internal function to add a BLS public key.
    /// @param blsPubkey - 64 bytes of the bls public key
    /// @param blsSignature - 128 byte bls proof of possession signature
    /// @param operator - The address of the operator running the service node
    /// @param serviceNodeParams - Service node public key, signature proving ownership of public key and fee that operator is charging
    /// @param contributors - optional list of contributors to the service node, first is always the operator.
    function _addBLSPublicKey(BN256G1.G1Point calldata blsPubkey, BLSSignatureParams calldata blsSignature, address operator, ServiceNodeParams calldata serviceNodeParams, Contributor[] memory contributors) internal whenStarted {
        if (contributors.length > 0) {
            if (contributors[0].addr != operator) revert FirstContributorMismatch(operator, contributors[0].addr);
            uint256 totalAmount = 0;
            for (uint256 i = 0; i < contributors.length; i++) {
                totalAmount += contributors[i].stakedAmount;
            }
            if (totalAmount != _stakingRequirement)  revert ContributionTotalMismatch(_stakingRequirement, totalAmount);
        } else {
            contributors = new Contributor[](1);
            contributors[0] = Contributor(operator, _stakingRequirement);
        }
        uint64 serviceNodeID = serviceNodeIDs[BN256G1.getKeyForG1Point(blsPubkey)];
        if (serviceNodeID != 0) revert BLSPubkeyAlreadyExists(serviceNodeID);
        validateProofOfPossession(blsPubkey, blsSignature, operator, serviceNodeParams.serviceNodePubkey);

        uint64 allocID                  = serviceNodeAdd(blsPubkey);
        // TODO sean only operator can exit atm need to make any contributor
        _serviceNodes[allocID].operator = operator;
        _serviceNodes[allocID].deposit  = _stakingRequirement;

        updateBLSNonSignerThreshold();
        emit NewServiceNode(allocID, operator, blsPubkey, serviceNodeParams, contributors);
        SafeERC20.safeTransferFrom(designatedToken, operator, address(this), _stakingRequirement);
    }

    /// @notice Validates the proof of possession for a given BLS public key.
    /// @param pubkey - The BLS public key.
    /// @param blsSignature - 128 byte signature
    /// @param operator - The address of the operator running the service node
    /// @param serviceNodePubkey - Service Nodes 32 Byte public key
    function validateProofOfPossession(BN256G1.G1Point memory pubkey, BLSSignatureParams calldata blsSignature, address operator, uint256 serviceNodePubkey) internal {
        BN256G2.G2Point memory Hm = BN256G2.hashToG2(BN256G2.hashToField(string(abi.encodePacked(proofOfPossessionTag, pubkey.X, pubkey.Y, operator, serviceNodePubkey))));
        BN256G2.G2Point memory signature = BN256G2.G2Point([blsSignature.sigs1,blsSignature.sigs0],[blsSignature.sigs3,blsSignature.sigs2]);
        if (!Pairing.pairing2(BN256G1.P1(), signature, BN256G1.negate(pubkey), Hm)) revert InvalidBLSProofOfPossession();
    }

    /// @notice Initiates the removal of a BLS public key. This simply notifies the network that the node wishes to leave the network. There will be a delay before the network allows this node to exit gracefully. Should be called first and later once the network is happy for node to exis the user should call `removeBLSPublicKeyWithSignature` with a valid BLS signature returned by the network
    /// @param serviceNodeID The ID of the service node to be removed.
    function initiateRemoveBLSPublicKey(uint64 serviceNodeID) public whenNotPaused {
        _initiateRemoveBLSPublicKey(serviceNodeID, msg.sender);
    }
        
    /// @notice Initiates the removal of a BLS public key.
    /// @param serviceNodeID The ID of the service node.
    /// @param recipient The address of the recipient associated with the service node.
    function _initiateRemoveBLSPublicKey(uint64 serviceNodeID, address recipient) internal whenStarted {
        //TODO sean this needs to be any of the contributors
        address serviceNodeRecipient = _serviceNodes[serviceNodeID].operator;
        if(serviceNodeRecipient != recipient) revert RecipientAddressDoesNotMatch(serviceNodeRecipient, recipient, serviceNodeID);
        if(_serviceNodes[serviceNodeID].leaveRequestTimestamp != 0) revert EarlierLeaveRequestMade(serviceNodeID, recipient);
        _serviceNodes[serviceNodeID].leaveRequestTimestamp = block.timestamp;
        emit ServiceNodeRemovalRequest(serviceNodeID, recipient, _serviceNodes[serviceNodeID].pubkey);
    }

    /// @notice Removes a BLS public key using an aggregated BLS signature from the network. This is the usual path for a node to exit the network. Anyone can call this function but only the user being removed will benefit from calling this. Once removed from the smart contracts list the network will release the staked amount.
    /// @param serviceNodeID The ID of the service node to be removed.
    /// @param blsPubkey - 64 bytes of the bls public key
    /// @param blsSignature - 128 byte bls proof of possession signature
    /// @param ids An array of service node IDs that did not sign and to be excluded from aggregation.
    function removeBLSPublicKeyWithSignature(uint64 serviceNodeID, BN256G1.G1Point calldata blsPubkey, BLSSignatureParams calldata blsSignature, uint64[] memory ids) external whenNotPaused whenStarted {
        if (ids.length > blsNonSignerThreshold) revert InsufficientBLSSignatures(serviceNodesLength() - ids.length, serviceNodesLength() - blsNonSignerThreshold);
        if (blsPubkey.X != _serviceNodes[serviceNodeID].pubkey.X || blsPubkey.Y != _serviceNodes[serviceNodeID].pubkey.Y) revert BLSPubkeyDoesNotMatch(serviceNodeID, blsPubkey);
        //Validating signature
        BN256G2.G2Point memory Hm = BN256G2.hashToG2(BN256G2.hashToField(string(abi.encodePacked(removalTag, blsPubkey.X, blsPubkey.Y))));
        BN256G1.G1Point memory pubkey;
        for(uint256 i = 0; i < ids.length; i++) {
            pubkey = BN256G1.add(pubkey, _serviceNodes[ids[i]].pubkey);
        }
        pubkey = BN256G1.add(_aggregatePubkey, BN256G1.negate(pubkey));
        BN256G2.G2Point memory signature = BN256G2.G2Point([blsSignature.sigs1,blsSignature.sigs0],[blsSignature.sigs3,blsSignature.sigs2]);
        if (!Pairing.pairing2(BN256G1.P1(), signature, BN256G1.negate(pubkey), Hm)) revert InvalidBLSSignature();

        _removeBLSPublicKey(serviceNodeID, _serviceNodes[serviceNodeID].deposit);
    }

    /// @notice Removes a BLS public key after a specified wait time, this can be called without the BLS signature because the node has waited significantly longer than the required wait time.
    /// @param serviceNodeID The ID of the service node to be removed.
    function removeBLSPublicKeyAfterWaitTime(uint64 serviceNodeID) external whenNotPaused whenStarted {
        uint256 leaveRequestTimestamp = _serviceNodes[serviceNodeID].leaveRequestTimestamp;
        if(leaveRequestTimestamp == 0) revert LeaveRequestTooEarly(serviceNodeID, leaveRequestTimestamp, block.timestamp);
        uint256 timestamp = leaveRequestTimestamp + MAX_SERVICE_NODE_REMOVAL_WAIT_TIME;
        if(block.timestamp <= timestamp) revert LeaveRequestTooEarly(serviceNodeID, timestamp, block.timestamp);
        _removeBLSPublicKey(serviceNodeID, _serviceNodes[serviceNodeID].deposit);
    }

    /// @dev Internal function to remove a BLS public key. Updates the linked list to remove the node
    /// @param serviceNodeID The ID of the service node to be removed.
    function _removeBLSPublicKey(uint64 serviceNodeID, uint256 returnedAmount) internal {
        address         operator      = _serviceNodes[serviceNodeID].operator;
        BN256G1.G1Point memory pubkey = _serviceNodes[serviceNodeID].pubkey;
        serviceNodeDelete(serviceNodeID);

        updateBLSNonSignerThreshold();
        emit ServiceNodeRemoval(serviceNodeID, operator, returnedAmount, pubkey);
    }

    /// @notice Removes a BLS public key using a bls signature and rewards the caller for doing so. This function can be called by anyone, but requires the network to provide a valid signature to do so. The nodes will only provides this signature if the network wishes for the node to be forcably removed (ie from a dereg) without relying on the user to remove themselves.
    /// @param serviceNodeID The ID of the service node to be liquidated.
    /// @param blsPubkey - 64 bytes of the bls public key
    /// @param blsSignature - 128 byte bls proof of possession signature
    function liquidateBLSPublicKeyWithSignature(uint64 serviceNodeID, BN256G1.G1Point calldata blsPubkey, BLSSignatureParams calldata blsSignature, uint64[] memory ids) external whenNotPaused whenStarted {
        if (ids.length > blsNonSignerThreshold) revert InsufficientBLSSignatures(serviceNodesLength() - ids.length, serviceNodesLength() - blsNonSignerThreshold);
        ServiceNode memory node = _serviceNodes[serviceNodeID];
        if (blsPubkey.X != node.pubkey.X || blsPubkey.Y != node.pubkey.Y) revert BLSPubkeyDoesNotMatch(serviceNodeID, blsPubkey);
        //Validating signature
        {
            BN256G2.G2Point memory Hm = BN256G2.hashToG2(BN256G2.hashToField(string(abi.encodePacked(liquidateTag, blsPubkey.X, blsPubkey.Y))));
            BN256G1.G1Point memory pubkey;
            for(uint256 i = 0; i < ids.length; i++) {
                pubkey = BN256G1.add(pubkey, _serviceNodes[ids[i]].pubkey);
            }
            pubkey = BN256G1.add(_aggregatePubkey, BN256G1.negate(pubkey));
            BN256G2.G2Point memory signature = BN256G2.G2Point([blsSignature.sigs1,blsSignature.sigs0],[blsSignature.sigs3,blsSignature.sigs2]);
            if (!Pairing.pairing2(BN256G1.P1(), signature, BN256G1.negate(pubkey), Hm)) revert InvalidBLSSignature();
        }


        // Calculating how much liquidator is paid out
        uint256 ratioSum = _poolShareOfLiquidationRatio + _liquidatorRewardRatio + _recipientRatio;
        emit ServiceNodeLiquidated(serviceNodeID, node.operator, node.pubkey);
        uint256 deposit = node.deposit;

        uint256 liquidatorAmount = deposit * _liquidatorRewardRatio / ratioSum;
        /*uint256 poolAmount = deposit * ceilDiv(_poolShareOfLiquidationRatio, ratioSum;*/
        uint256 poolAmount = deposit * _poolShareOfLiquidationRatio == 0 ? 0 : (_poolShareOfLiquidationRatio - 1) / ratioSum + 1;

        _removeBLSPublicKey(serviceNodeID, deposit - liquidatorAmount - poolAmount);


        // Transfer funds to pool and liquidator
        if (_liquidatorRewardRatio > 0)
            SafeERC20.safeTransfer(designatedToken, msg.sender, liquidatorAmount);
        if (_poolShareOfLiquidationRatio > 0)
            SafeERC20.safeTransfer(designatedToken, address(foundationPool), poolAmount);
    }

    /// @notice Seeds the public key list with an initial set of keys. Only should be called before the hardfork by the foundation to ensure the public key list is ready to operate.
    /// @param pkX Array of X-coordinates for the public keys.
    /// @param pkY Array of Y-coordinates for the public keys.
    /// @param amounts Array of amounts that the service node has staked, associated with each public key.
    function seedPublicKeyList(uint256[] calldata pkX, uint256[] calldata pkY, uint256[] calldata amounts) external onlyOwner {
        if (pkX.length != pkY.length || pkX.length != amounts.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < pkX.length; i++) {
            BN256G1.G1Point memory pubkey  = BN256G1.G1Point(pkX[i], pkY[i]);
            uint64 allocID                 = serviceNodeAdd(pubkey);
            _serviceNodes[allocID].deposit = amounts[i];
            emit NewSeededServiceNode(allocID, pubkey);
        }

        updateBLSNonSignerThreshold();
    }

    /// @notice Add the service node with the specified BLS public key to
    /// the service node list. EVM revert if the service node already exists.
    /// @return result The ID allocated for the service node. The service node can then
    /// be accessed by `_serviceNodes[result]`
    function serviceNodeAdd(BN256G1.G1Point memory pubkey) internal returns (uint64 result) {
        // NOTE: Check if the service node already exists
        // (e.g. <BLS Key> -> <SN> mapping)
        bytes memory pubkeyBytes = BN256G1.getKeyForG1Point(pubkey);
        if (serviceNodeIDs[pubkeyBytes] != LIST_SENTINEL)
            revert BLSPubkeyAlreadyExists(serviceNodeIDs[pubkeyBytes]);

        result             = nextServiceNodeID;
        nextServiceNodeID += 1;
        totalNodes        += 1;

        // NOTE: Create service node slot and patch up the slot links.
        //
        // The following is the insertion pattern in a doubly-linked list
        // with sentinel at index 0
        //
        // ```c
        // node->next       = sentinel;
        // node->prev       = sentinel->prev;
        // node->next->prev = node;
        // node->prev->next = node;
        // ```
        _serviceNodes[result].next                     = LIST_SENTINEL;
        _serviceNodes[result].prev                     = _serviceNodes[LIST_SENTINEL].prev;
        _serviceNodes[_serviceNodes[result].next].prev = result;
        _serviceNodes[_serviceNodes[result].prev].next = result;

        // NOTE: Assign BLS pubkey
        _serviceNodes[result].pubkey                   = pubkey;

        // NOTE: Create mapping from <BLS Key> -> <SN Linked List Index>
        serviceNodeIDs[pubkeyBytes] = result;

        if (totalNodes == 1) {
            _aggregatePubkey = pubkey;
        } else {
            _aggregatePubkey = BN256G1.add(_aggregatePubkey, pubkey);
        }
        return result;
    }

    /// @notice Delete the service node with `nodeID`
    /// @param nodeID The ID of the service node to delete
    function serviceNodeDelete(uint64 nodeID) internal {
        require(totalNodes > 0);
        if (nodeID == LIST_SENTINEL)
            revert DeleteSentinelNodeNotAllowed();

        ServiceNode memory node = _serviceNodes[nodeID];

        // The following is the deletion pattern in a doubly-linked list
        // with sentinel at index 0
        //
        // ```c
        // node->next->prev = node->prev;
        // node->prev->next = node->next;
        // ```
        _serviceNodes[node.next].prev = node.prev;
        _serviceNodes[node.prev].next = node.next;

        // NOTE: Update aggregate BLS key
        _aggregatePubkey = BN256G1.add(_aggregatePubkey, BN256G1.negate(node.pubkey));

        // NOTE: Delete service node from EVM storage
        bytes memory pubkeyBytes = BN256G1.getKeyForG1Point(node.pubkey);
        delete _serviceNodes[nodeID];
        delete serviceNodeIDs[pubkeyBytes]; // Delete mapping

        totalNodes -= 1;
    }

    //////////////////////////////////////////////////////////////
    //                                                          //
    //                        Governance                        //
    //                                                          //
    //////////////////////////////////////////////////////////////

    /// @notice allows anyone to update the service nodes length variable
    function updateServiceNodesLength() public {
        totalNodes = serviceNodesLength();
    }

    /// @notice Update the threshold for how many non-signers an aggregate
    /// signature can contain before being considered invalid.
    function updateBLSNonSignerThreshold() internal {
        uint256 oneThirdOfNodes = totalNodes / 3;
        blsNonSignerThreshold   = oneThirdOfNodes > blsNonSignerThresholdMax ? blsNonSignerThresholdMax : oneThirdOfNodes;
    }

    /// @notice Start the contract and allow decentralised operation to the
    /// service node list.
    ///
    /// @dev The contract begins locked and can be started by the owner after
    /// nodes have been populated and the hard fork has begun.
    function start() public onlyOwner {
        started = true;
    }

    /// @notice Pause will prevent new keys from being added and removed, and
    /// also the claiming of rewards
    function pause() public onlyOwner {
        _pause();
    }

    /// @notice Unpause will allow all functions to work as usual
    function unpause() public onlyOwner {
        _unpause();
    }

    /// @notice Update the staking requirement for the contract
    /// @param newRequirement the value being changed to
    function setStakingRequirement(uint256 newRequirement) public onlyOwner {
        require(newRequirement > 0, "Staking requirement must be positive");
        _stakingRequirement = newRequirement;
        emit StakingRequirementUpdated(newRequirement);
    }

    /// @notice Max number of permitted non-signers during signature aggregation
    /// applied when one third of the nodes exceeds this value. Only callable by
    /// the owner.
    /// @param newMax The new maximum non-signer threshold
    function setBLSNonSignerThresholdMax(uint256 newMax) public onlyOwner {
        require(newMax > 0, "The new BLS non-signer threshold must be non-zero");
        blsNonSignerThresholdMax = newMax;
        emit BLSNonSignerThresholdMaxUpdated(newMax);
    }

    //////////////////////////////////////////////////////////////
    //                                                          //
    //                Non-state-changing functions              //
    //                                                          //
    //////////////////////////////////////////////////////////////

    /// @notice Counts the number of service nodes in the linked list.
    /// @return count The total number of service nodes in the list.
    function serviceNodesLength() public view returns (uint256 count) {
        uint64 currentNode = _serviceNodes[LIST_SENTINEL].next;
        count = 0;

        while (currentNode != LIST_SENTINEL) {
            count++;
            currentNode = _serviceNodes[currentNode].next;
        }

        return count;
    }

    /// @notice Getter for a single service node given their service node ID
    /// @param serviceNodeID the unique identifier of the service node
    /// @return Service Node Struct from the linked list of all nodes
    function serviceNodes(uint64 serviceNodeID) external view returns (ServiceNode memory) {
        return _serviceNodes[serviceNodeID];
    }

    /// @notice Getter function for liquidatorRewardRatio
    function liquidatorRewardRatio() external view returns (uint256) {
        return _liquidatorRewardRatio;
    }

    /// @notice Getter function for poolShareofLiquidationRatio
    function poolShareOfLiquidationRatio() external view returns (uint256) {
        return _poolShareOfLiquidationRatio;
    }

    /// @notice Getter function for recipientRatio
    function recipientRatio() external view returns (uint256) {
        return _recipientRatio;
    }

    /// @notice Getter function for stakingRequirement
    function stakingRequirement() external view returns (uint256) {
        return _stakingRequirement;
    }

    /// @notice Getter function for the aggregatePubkey
    function aggregatePubkey() external view returns (BN256G1.G1Point memory) {
        return _aggregatePubkey;
    }

    /// @dev Builds a tag string using a base tag and contract-specific information. This is used when signing messages to prevent reuse of signatures across different domains (chains/functions/contracts)
    /// @param baseTag The base string for the tag.
    /// @return The constructed tag string.
    function buildTag(string memory baseTag) private view returns (bytes32) {
        return keccak256(bytes(abi.encodePacked(baseTag, block.chainid, address(this))));
    }
}
