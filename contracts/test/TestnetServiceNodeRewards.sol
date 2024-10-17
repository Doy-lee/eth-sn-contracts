// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import "../ServiceNodeRewards.sol";

contract TestnetServiceNodeRewards is ServiceNodeRewards {
    // NOTE: Admin function to remove node by ID for stagenet debugging
    function requestRemoveNodeBySNID(uint64[] calldata ids) external onlyOwner {
        uint256 idsLength = ids.length;
        for (uint256 i = 0; i < idsLength; ) {
            uint64 serviceNodeID                          = ids[i];
            IServiceNodeRewards.ServiceNodeV1 memory node = this.serviceNodes(serviceNodeID);
            require(node.operator != address(0));
            _initiateRemoveBLSPublicKey(serviceNodeID, node.operator);
            unchecked { i += 1; }
        }
    }

    function removeNodeBySNID(uint64[] calldata ids) external onlyOwner {
        uint256 idsLength = ids.length;
        for (uint256 i = 0; i < idsLength; ) {
            uint64 serviceNodeID                          = ids[i];
            IServiceNodeRewards.ServiceNodeV1 memory node = this.serviceNodes(serviceNodeID);
            require(node.operator != address(0));
            _removeBLSPublicKey(serviceNodeID, node.deposit);
            unchecked { i += 1; }
        }
    }

    // Convert a contract with `ServiceNodesV0` nodes to `ServiceNodesV1`. It
    // does not delete the old SNv0 nodes after migration for reversability
    // purposes. This should only be called once.
    //
    // Pass in a pair of arrays of the same size where each BLS pubkey has an
    // equivalent Ed25519 pubkey assigned to it in the opposing array.
    //
    // V1 introduces a beneficiary on each contributor which defaults to the
    // same address as the staker for V0 nodes. Additionally, each node also
    // stores their Ed25519 key on registration hence that must be seeded
    // initially on migration from V0 to V1.
    function migrateToSNv1Beneficiary(BN256G1.G1Point[] calldata blsPubkeys, uint256[] calldata ed25519Pubkeys) external onlyOwner {
        require(blsPubkeys.length == ed25519Pubkeys.length);

        // NOTE: Heuristic to approximately assume if the contract has been
        // migrated before or not. This check essentially asks if the list is
        // pointing to itself (i.e. has not been populated) so it's _probably_
        // the first time this function has been called.
        require(_serviceNodesV1[LIST_SENTINEL].next == LIST_SENTINEL);

        // NOTE: Setup the sentinel-delimited, doubly-linked-list for V1
        _serviceNodesV1[LIST_SENTINEL].prev = _serviceNodes[LIST_SENTINEL].prev;
        _serviceNodesV1[LIST_SENTINEL].next = _serviceNodes[LIST_SENTINEL].next;

        // NOTE: Walk the SN list and upgrade from V0 to V1 structures
        for (uint64 it = _serviceNodes[LIST_SENTINEL].next; it != LIST_SENTINEL; it = _serviceNodes[it].next) {
            ServiceNodeV0 storage v0 = _serviceNodes[it];

            // NOTE: Assign V0 fields to V1
            ServiceNodeV1 storage v1 = _serviceNodesV1[it];
            v1.next                  = v0.next;
            v1.prev                  = v0.prev;
            v1.operator              = v0.operator;
            v1.blsPubkey             = v0.pubkey;
            v1.addedTimestamp        = v0.addedTimestamp;
            v1.leaveRequestTimestamp = v0.leaveRequestTimestamp;
            v1.deposit               = v0.deposit;

            // NOTE: Convert V0 contributors to V1
            uint256 v0ContribLength = v0.contributors.length;
            for (uint256 contribIndex = 0; contribIndex < v0ContribLength; ) {
                // NOTE: Add contributor to v1
                ContributorV0 storage contribV0 = v0.contributors[contribIndex];
                ContributorV1 memory contribV1  = ContributorV1({
                    staker: Staker({
                        addr:        contribV0.addr,
                        beneficiary: contribV0.addr
                    }),
                    stakedAmount: contribV0.stakedAmount
                });

                v1.contributors.push(contribV1);
                unchecked { contribIndex++; }
            }
        }

        // NOTE: Patch in the Ed25519 keys for the nodes we have
        for (uint256 i = 0; i < blsPubkeys.length; ) {
            BN256G1.G1Point calldata key = blsPubkeys[i];
            bytes memory keyBytes        = BN256G1.getKeyForG1Point(key);
            uint64 snID                  = serviceNodeIDs[keyBytes];
            require(snID != LIST_SENTINEL);

            uint256 ed25519Pubkey                 = ed25519Pubkeys[i];
            ed25519ToServiceNodeID[ed25519Pubkey] = snID;

            _serviceNodesV1[snID].ed25519Pubkey = ed25519Pubkey;
            unchecked { i++; }
        }
    }
}
