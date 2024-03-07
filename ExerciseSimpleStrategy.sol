// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.19;

import {BaseStrategy} from "../strategies/BaseStrategy.sol";
import {IRegistry} from "../../contracts/core/interfaces/IRegistry.sol";
import {IAllo} from "../../contracts/core/interfaces/IAllo.sol";


contract ExerciseSimpleStrategy is BaseStrategy {
    /// ================================
    /// ========== Struct ==============
    /// ================================

    /// @notice Stores the details of the recipients.
    struct Recipient {
        // If false, the recipientAddress is the anchor of the profile
        address recipientAddress;
        Status recipientStatus;
    }

    /// @notice Stores the details of the distribution.
    struct Distribution {
        uint256 index;
        address recipientId;
        uint256 amount;
    }

    struct InitializeData {
        address[] allowedTokens;
    }
    
    /// ===============================
    /// ========== Events =============
    /// ===============================

    /// @notice Emitted when a recipient updates their registration
    /// @param recipientId Id of the recipient
    /// @param data The encoded data - (address recipientId, address recipientAddress, Metadata metadata)
    /// @param sender The sender of the transaction
    /// @param status The updated status of the recipient
    event UpdatedRegistration(address indexed recipientId, bytes data, address sender, uint8 status);

    /// ================================
    /// ========== Storage =============
    /// ================================

    /// @notice This is a packed array of booleans, 'statuses[0]' is the first row of the bitmap and allows to
    /// store 256 bits to describe the status of 256 projects. 'statuses[1]' is the second row, and so on
    /// Instead of using 1 bit for each recipient status, we will use 4 bits for each status
    /// to allow 5 statuses:
    /// 0: none
    /// 1: pending
    /// 2: accepted
    /// 3: rejected
    /// 4: appealed
    /// Since it's a mapping the storage it's pre-allocated with zero values, so if we check the
    /// status of an existing recipient, the value is by default 0 (none).
    /// If we want to check the status of an recipient, we take its index from the `recipients` array
    /// and convert it to the 2-bits position in the bitmap.
    mapping(uint256 => uint256) public statusesBitMap;

    /// @notice 'recipientId' => 'statusIndex'
    /// @dev 'statusIndex' is the index of the recipient in the 'statusesBitMap' bitmap.
    mapping(address => uint256) public recipientToStatusIndexes;
    
    /// @notice Whether the distribution started or not
    bool public distributionStarted;

    /// @notice This is a packed array of booleans to keep track of claims distributed.
    /// @dev distributedBitMap[0] is the first row of the bitmap and allows to store 256 bits to describe
    /// the status of 256 claims
    mapping(uint256 => uint256) private distributedBitMap;

    /// @notice 'recipientId' => 'Recipient' struct.
    mapping(address => Recipient) internal _recipients;

    /// @notice The total number of recipients.
    uint256 public recipientsCounter;

    /// @notice Returns whether or not the recipient has been paid out using their ID
    /// @dev recipientId => paid out
    mapping(address => bool) public paidOut;

    /// @notice The registry contract interface.
    IRegistry private _registry;

    /// @notice 'token' address => boolean (allowed = true).
    /// @dev This can be updated by the pool manager.
    mapping(address => bool) public allowedTokens;

    /// ================================
    /// ========== Modifier ============
    /// ================================

    /// @notice Modifier to check if the registration is active
    /// @dev This will revert if the registration has not started or if the registration has ended.
    modifier onlyActiveRegistration() {
        _checkOnlyActiveRegistration();
        _;
    }

    /// ===============================
    /// ======== Constructor ==========
    /// ===============================

    /// @notice Constructor for the Interview Exercise Strategy
    /// @param _allo The 'Allo' contract
    /// @param _name The name of the strategy
    constructor(address _allo, string memory _name)
        BaseStrategy(_allo, _name)
    {}

    /// ===============================
    /// ========= Initialize ==========
    /// ===============================

    /// @notice Initializes the strategy
    /// @dev This will revert if the strategy is already initialized and 'msg.sender' is not the 'Allo' contract.
    /// @param _poolId The 'poolId' to initialize
    /// @param _data The data to be decoded to initialize the strategy
    /// @custom:data InitializeData(address[] memory _allowedTokens)
    function initialize(uint256 _poolId, bytes memory _data) external virtual override {
        (InitializeData memory initializeData) = abi.decode(_data, (InitializeData));
        __ExerciseSimpleStrategy_init(_poolId, initializeData);
        emit Initialized(_poolId, _data);
    }

    /// @notice Initializes this strategy as well as the BaseStrategy.
    /// @dev This will revert if the strategy is already initialized. Emits a 'TimestampsUpdated()' event.
    /// @param _poolId The 'poolId' to initialize
    /// @param _initializeData The data to be decoded to initialize the strategy
    function __ExerciseSimpleStrategy_init(uint256 _poolId, InitializeData memory _initializeData) internal {
        // Initialize the BaseStrategy with the '_poolId'
        __BaseStrategy_init(_poolId);

        // Initialize required values
        _registry = allo.getRegistry();

        recipientsCounter = 1;
        _initializeData.allowedTokens[0] = NATIVE;

    }

    /// ====================================
    /// ============ Internal ==============
    /// ====================================

    /// @notice Checks if the registration is active and reverts if not.
    /// @dev This will revert if the registration has not started or if the registration has ended.
    function _checkOnlyActiveRegistration() internal view {
        if (distributionStarted) {
            revert REGISTRATION_NOT_ACTIVE();
        }
    }

    /// @notice Checks if address is eligible allocator.
    /// @return Always returns true for this strategy
    function _isValidAllocator(address) internal pure override returns (bool) {
        return true;
    }

    /// @notice Submit recipient to pool and set their status.
    /// @param _data The data to be decoded.
    /// @custom:data if 'useRegistryAnchor' is 'true' (address recipientId, address recipientAddress, Metadata metadata)
    /// @param _sender The sender of the transaction
    /// @return recipientId The ID of the recipient
    function _registerRecipient(bytes memory _data, address _sender)
        internal
        override
        onlyActiveRegistration
        returns (address recipientId)
    {
        address recipientAddress;

        // decode data custom to this strategy
        (recipientId, recipientAddress) = abi.decode(_data, (address, address));

        // If the sender is not a profile member this will revert
        if (!_isProfileMember(recipientId, _sender)) {
            revert UNAUTHORIZED();
        }


        // If the recipient address is the zero address this will revert
        if (recipientAddress == address(0)) {
            revert RECIPIENT_ERROR(recipientId);
        }

        // Get the recipient
        Recipient storage recipient = _recipients[recipientId];

        // update the recipients data
        recipient.recipientAddress = recipientAddress;

        if (recipientToStatusIndexes[recipientId] == 0) {
            // recipient registering new application
            recipientToStatusIndexes[recipientId] = recipientsCounter;
            _setRecipientStatus(recipientId, uint8(Status.Pending));

            bytes memory extendedData = abi.encode(_data, recipientsCounter);
            emit Registered(recipientId, extendedData, _sender);

            recipientsCounter++;
        } else {
            uint8 currentStatus = _getUintRecipientStatus(recipientId);
            if (currentStatus == uint8(Status.Accepted)) {
                // recipient updating accepted application
                _setRecipientStatus(recipientId, uint8(Status.Pending));
            } else if (currentStatus == uint8(Status.Rejected)) {
                // recipient updating rejected application
                _setRecipientStatus(recipientId, uint8(Status.Appealed));
            }
            emit UpdatedRegistration(recipientId, _data, _sender, _getUintRecipientStatus(recipientId));
        }
    }

    /// @notice Allocate tokens to recipient.
    /// @dev This can only be called during the allocation period. Emts an 'Allocated()' event.
    /// @param _data The data to be decoded
    /// @custom:data (address recipientId, uint256 amount, address token)
    /// @param _sender The sender of the transaction
    function _allocate(bytes memory _data, address _sender) internal virtual override {
        // Decode the '_data' to get the recipientId, amount and token
        (address recipientId, uint256 amount) = abi.decode(_data, (address, uint256));

        address token = NATIVE;

        // If the recipient status is not 'Accepted' this will revert, the recipient must be accepted through registration
        if (Status(_getUintRecipientStatus(recipientId)) != Status.Accepted) {
            revert RECIPIENT_ERROR(recipientId);
        }

        // If the token is native, the amount must be equal to the value sent, otherwise it reverts
        if (msg.value > 0 && token != NATIVE || token == NATIVE && msg.value != amount) {
            revert INVALID();
        }

        // Emit that the amount has been allocated to the recipient by the sender
        emit Allocated(recipientId, amount, token, _sender);
    }

    /// @notice Distribute the tokens to the recipients
    /// @dev The '_sender' must be a pool manager and the allocation must have ended
    /// @param _recipientIds The recipient ids
    /// @param _sender The sender of the transaction
    function _distribute(address[] memory _recipientIds, bytes memory, address _sender)
        internal
        virtual
        override
        onlyPoolManager(_sender)
        {
        uint256 payoutLength = _recipientIds.length;
        for (uint256 i; i < payoutLength;) {
            address recipientId = _recipientIds[i];
            Recipient storage recipient = _recipients[recipientId];

            PayoutSummary memory payout = _getPayout(recipientId, "");
            uint256 amount = payout.amount;

            if (paidOut[recipientId] || !_isAcceptedRecipient(recipientId) || amount == 0) {
                revert RECIPIENT_ERROR(recipientId);
            }

            IAllo.Pool memory pool = allo.getPool(poolId);
            _transferAmount(pool.token, recipient.recipientAddress, amount);

            paidOut[recipientId] = true;

            emit Distributed(recipientId, recipient.recipientAddress, amount, _sender);
            unchecked {
                ++i;
            }
        }
        if (!distributionStarted) {
            distributionStarted = true;
        }
    }

    /// @notice Returns the payout summary for the accepted recipient.
    /// @param _data The data to be decoded
    /// @custom:data '(Distribution)'
    /// @return 'PayoutSummary' for a recipient
    function _getPayout(address, bytes memory _data) internal view override returns (PayoutSummary memory) {
        // Decode the '_data' to get the distribution
        Distribution memory distribution = abi.decode(_data, (Distribution));

        uint256 index = distribution.index;
        address recipientId = distribution.recipientId;
        uint256 amount = distribution.amount;

        address recipientAddress = _getRecipient(recipientId).recipientAddress;

        // Validate the distribution
        if (_validateDistribution(index, recipientId, recipientAddress, amount)) {
            // Return a 'PayoutSummary' with the 'recipientAddress' and 'amount'
            return PayoutSummary(recipientAddress, amount);
        }

        // If the distribution is not valid, return a payout summary with the amount set to zero
        return PayoutSummary(recipientAddress, 0);
    }

    /// @notice Get recipient status
    /// @dev This will return the 'Status' of the recipient, the 'Status' is used at the strategy
    ///      level and is different from the 'Status' which is used at the protocol level
    /// @param _recipientId ID of the recipient
    /// @return Status of the recipient
    function _getRecipientStatus(address _recipientId) internal view override returns (Status) {
        return Status(_getUintRecipientStatus(_recipientId));
    }

    /// @notice Set the recipient status.
    /// @param _recipientId ID of the recipient
    /// @param _status Status of the recipient
    function _setRecipientStatus(address _recipientId, uint256 _status) internal {
        // Get the row index, column index and current row
        (uint256 rowIndex, uint256 colIndex, uint256 currentRow) = _getStatusRowColumn(_recipientId);

        // Calculate the 'newRow'
        uint256 newRow = currentRow & ~(15 << colIndex);

        // Add the status to the mapping
        statusesBitMap[rowIndex] = newRow | (_status << colIndex);
    }

    /// @notice Get recipient status
    /// @param _recipientId ID of the recipient
    /// @return status The status of the recipient
    function _getUintRecipientStatus(address _recipientId) internal view returns (uint8 status) {
        if (recipientToStatusIndexes[_recipientId] == 0) return 0;
        // Get the column index and current row
        (, uint256 colIndex, uint256 currentRow) = _getStatusRowColumn(_recipientId);

        // Get the status from the 'currentRow' shifting by the 'colIndex'
        status = uint8((currentRow >> colIndex) & 15);

        // Return the status
        return status;
    }

    /// @notice Get recipient status 'rowIndex', 'colIndex' and 'currentRow'.
    /// @param _recipientId ID of the recipient
    /// @return (rowIndex, colIndex, currentRow)
    function _getStatusRowColumn(address _recipientId) internal view returns (uint256, uint256, uint256) {
        uint256 recipientIndex = recipientToStatusIndexes[_recipientId] - 1;

        uint256 rowIndex = recipientIndex / 64; // 256 / 4
        uint256 colIndex = (recipientIndex % 64) * 4;

        return (rowIndex, colIndex, statusesBitMap[rowIndex]);
    }

    /// @notice Check if sender is profile owner or member.
    /// @param _anchor Anchor of the profile
    /// @param _sender The sender of the transaction
    /// @return 'true' if the '_sender' is a profile member, otherwise 'false'
    function _isProfileMember(address _anchor, address _sender) internal view virtual returns (bool) {
        IRegistry.Profile memory profile = _registry.getProfileByAnchor(_anchor);
        return _registry.isOwnerOrMemberOfProfile(profile.id, _sender);
    }

    /// @notice Returns if the recipient is accepted
    /// @param _recipientId The recipient id
    /// @return true if the recipient is accepted
    function _isAcceptedRecipient(address _recipientId) internal view returns (bool) {
        return _recipients[_recipientId].recipientStatus == Status.Accepted;
    }

    /// @notice Check if the distribution has been distributed.
    /// @param _index index of the distribution
    /// @return 'true' if the distribution has been distributed, otherwise 'false'
    function _hasBeenDistributed(uint256 _index) internal view returns (bool) {
        // Get the word index by dividing the '_index' by 256
        uint256 distributedWordIndex = _index / 256;

        // Get the bit index by getting the remainder of the '_index' divided by 256
        uint256 distributedBitIndex = _index % 256;

        // Get the word from the 'distributedBitMap' using the 'distributedWordIndex'
        uint256 distributedWord = distributedBitMap[distributedWordIndex];

        // Get the mask by shifting 1 to the left of the 'distributedBitIndex'
        uint256 mask = (1 << distributedBitIndex);

        // Return 'true' if the 'distributedWord' and 'mask' are equal to the 'mask'
        return distributedWord & mask == mask;
    }
    
    /// @notice Validate the distribution for the payout.
    /// @param _index index of the distribution
    /// @param _recipientId Id of the recipient
    /// @param _recipientAddress Address of the recipient
    /// @param _amount Amount of tokens to be distributed
    /// @return 'true' if the distribution is valid, otherwise 'false'
    function _validateDistribution(
        uint256 _index,
        address _recipientId,
        address _recipientAddress,
        uint256 _amount
    ) internal view returns (bool) {
        // If the '_index' has been distributed this will return 'false'
        if (_hasBeenDistributed(_index)) {
            return false;
        }


        // Return 'true', the distribution is valid at this point
        return true;
    }

    /// @notice Get the recipient details.
    /// @param _recipientId Id of the recipient
    /// @return Recipient details
    function _getRecipient(address _recipientId) internal view returns (Recipient memory) {
        return _recipients[_recipientId];
    }
    
    /// @notice Contract should be able to receive NATIVE
    receive() external payable {}
}