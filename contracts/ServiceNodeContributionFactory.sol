// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import "./ServiceNodeContribution.sol";
import "./interfaces/IServiceNodeRewards.sol";
import "./interfaces/IServiceNodeContributionFactory.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract ServiceNodeContributionFactory is Initializable, Ownable2StepUpgradeable, PausableUpgradeable, IServiceNodeContributionFactory {
    IServiceNodeRewards public stakingRewardsContract;

    /// Tracks the contribution contracts that have been deployed from this
    /// factory
    mapping(address => bool) public deployedContracts;
    address[]                public deployedContractsArray;

    // Events
    event NewServiceNodeContributionContract(address indexed contributorContract, uint256 serviceNodePubkey);

    function initialize(address _stakingRewardsContract) public initializer {
        stakingRewardsContract = IServiceNodeRewards(_stakingRewardsContract);
        __Ownable_init(msg.sender);
        __Pausable_init();
    }

    /// @notice Create a new multi-contrib contract, tracked by this factory.
    /// @return result The address of the new multi-contrib contract
    function deploy(BN256G1.G1Point calldata key,
                    IServiceNodeRewards.BLSSignatureParams calldata sig,
                    IServiceNodeRewards.ServiceNodeParams calldata params,
                    IServiceNodeRewards.ReservedContributor[] calldata reserved,
                    bool manualFinalize
    ) external whenNotPaused returns (address result) {
        ServiceNodeContribution newContract = new ServiceNodeContribution(
            address(stakingRewardsContract),
            stakingRewardsContract.maxContributors(),
            key,
            sig,
            params,
            reserved,
            manualFinalize
        );

        result = address(newContract);
        deployedContracts[result] = true;
        deployedContractsArray.push(result);
        emit NewServiceNodeContributionContract(result, params.serviceNodePubkey);
        return result;
    }

    function getDeployedContracts(uint256 offset, uint256 chunkSize) public view returns (address[] memory result) {
        offset            = offset > deployedContractsArray.length ? deployedContractsArray.length : offset;
        uint256 remainder = deployedContractsArray.length - offset;
        chunkSize         = remainder > chunkSize ? chunkSize : remainder;
        result            = new address[](chunkSize);
        for (uint256 i = 0; i < chunkSize; ) {
            result[i] = deployedContractsArray[offset + i];
            unchecked { i += 1; }
        }
    }

    /// @notice Pause to prevent new multi-contrib contracts being deployed
    function pause() public onlyOwner {
        _pause();
    }

    /// @notice Unpause allows new multi-contrib contracts to be deployed
    function unpause() public onlyOwner {
        _unpause();
    }
}
