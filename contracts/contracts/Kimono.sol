pragma solidity ^0.4.23;

import "openzeppelin-solidity/contracts/ReentrancyGuard.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "./AddressArrayUtils.sol";
import "./IPFSWrapper.sol";
import "./KimonoCoin.sol";


contract Kimono is IPFSWrapper, ReentrancyGuard {
  using SafeMath for uint256;
  using AddressArrayUtils for address[];

  enum RevealStatus { NoShow, Late, OnTime }

  struct Message {
    address creator; // Address of the creator of the message
    uint8 minFragments; // K-number of fragments needed to construct the secret
    uint8 totalFragments; // Total number of fragments that will be distributed
    uint40 revealBlock; // Block number for the start of the reveal period
    uint40 revealPeriod; // Length of the period when it's okay to reveal secret fragments
    address secretConstructor; // Address of the constructor of the secret
    bool creatorWithdrewStake; // True if creator withdrew their stake (and punished no-showers)
    bool secretConstructorWithdrewStake; // True if secret constructor withdrew their stake
    uint8 onTimeRevealerCount; // Count of revealers who submitted their fragment before secret construction
    uint256 revealSecret; // Secret that'll be used to decrypt the message
    uint256 hashOfRevealSecret; // Hash of the revealSecret, submitted by the user and used for verification
    uint256 timeLockReward; // Time lock reward staked by the creator of the message
    IPFSMultiHash encryptedMessage; // IPFS multi-hash of the encrypted message
    IPFSMultiHash encryptedFragments; // IPFS multi-hash of the fragments
  }

  struct Revealer {
    bytes32 publicKey;
    uint256 minReward;
    uint256 stakePerMessage;
  }

  struct Fragment {
    bytes32 piece1;
    bytes18 piece2;
  }

  uint40 constant MINIMUM_REVEAL_PERIOD_LENGTH = 10; // in blocks

  mapping (uint256 => Message) public nonceToMessage;
  mapping (address => uint256[]) public revealerToMessages;
  mapping (uint256 => address[]) public messageToRevealers;
  mapping (uint256 => uint256) public messageToCreatedAt;
  mapping (uint256 => mapping(address => Fragment)) public messageToRevealerToFragments;
  mapping (uint256 => mapping(address => uint256)) public messageToRevealerToHashOfFragments;
  mapping (uint256 => mapping(address => RevealStatus)) public messageToRevealerToRevealStatus;
  mapping(address => Revealer) public revealerTable;
  mapping(address => uint256) public totalStakes;
  mapping(uint256 => mapping(address => uint256)) public messageToRevealerToStake;

  address[] public eligibleRevealers;
  address public kimonoCoinAddress;

  // EVENTS

  event MessageCreation(
    uint256 nonce,
    address creator,
    bytes encryptedFragmentsIPFSHash,
    address[] revealerAddresses
  );
  event FragmentReveal(
    uint256 nonce,
    address revealer,
    uint8 minFragments,
    uint8 onTimeRevealerCount,
    bytes fragment
  );
  event SecretReveal(uint256 nonce, address revealer, uint256 secret);
  event StakeWithdrawal(address withdrawer, uint256 amount);
  event TattleTale(uint256 nonce, address tattler, address tattlee, bytes fragment);

  // nonce => revealerAddress => balance

  // CONSTRUCTOR
  constructor (address _kimonoCoinAddress) public {
    kimonoCoinAddress = _kimonoCoinAddress;
  }

  // FALLBACK FUNCTION

  // Do nothing. Intentionally not payable.
  function() public {

  }

  // MODIFIERS

  modifier afterRevealPeriodStarts(uint256 _nonce) {
    require(uint40(block.number) > nonceToMessage[_nonce].revealBlock, "Reveal period did not start.");
    _;
  }

  modifier afterRevealPeriodEnds(uint256 _nonce) {
    require(
      uint40(block.number) > nonceToMessage[_nonce].revealBlock + nonceToMessage[_nonce].revealPeriod,
      "Reveal period is not over."
    );
    _;
  }

  modifier beforeRevealPeriodStarts(uint256 _nonce) {
    require(uint40(block.number) < nonceToMessage[_nonce].revealBlock, "Reveal period already started.");
    _;
  }

  modifier beforeRevealPeriodEnds(uint256 _nonce) {
    require(
      uint40(block.number) < nonceToMessage[_nonce].revealBlock + nonceToMessage[_nonce].revealPeriod,
      "Reveal period is over."
    );
    _;
  }

  modifier messageExists(uint256 _nonce) {
    require(nonceToMessage[_nonce].creator != address(0), "Message does not exist.");
    _;
  }

  modifier noDuplicates(address[] addresses) {
    require(!addresses.hasDuplicate());
    _;
  }

  modifier withValidFragment(uint256 _nonce, bytes _fragment, address revealer) {
    Fragment memory fragment = splitBytesToFragment(_fragment);
    require(
      bytes32(messageToRevealerToHashOfFragments[_nonce][revealer]) == keccak256(fragment.piece1, fragment.piece2),
      "Revealer submitted an invalid fragment."
    );
    _;
  }

  // PUBLIC FUNCTIONS

  function registerRevealer(
    bytes32 _publicKey,
    uint256 _minReward,
    uint256 _stakePerMessage,
    uint256 _totalStake
  ) public nonReentrant {
    // TODO: Can revealer update every single param they have?
    // If not, add a check to make sure msg.sender doesn't exist.

    Revealer memory revealer = Revealer({
      publicKey: _publicKey,
      minReward: _minReward,
      stakePerMessage: _stakePerMessage
    });
    uint256 reservedAmount = getReservedAmount(msg.sender);
    require(_totalStake >= reservedAmount);

    uint256 oldTotalStake = totalStakes[msg.sender];
    if (_totalStake == oldTotalStake) {
    } else if (_totalStake > oldTotalStake) {
      uint256 additionalStakeAmount = _totalStake.sub(oldTotalStake);
      require(KimonoCoin(kimonoCoinAddress).transferFrom(msg.sender, address(this), additionalStakeAmount));
    } else {
      uint256 refundAmount = oldTotalStake.sub(_totalStake);
      require(KimonoCoin(kimonoCoinAddress).transfer(msg.sender, refundAmount));
    }
    totalStakes[msg.sender] = _totalStake;
    revealerTable[msg.sender] = revealer;

    updateEligibleRevealer(msg.sender, reservedAmount, _stakePerMessage);
  }

  function updateEligibleRevealer(address _revealerAddress, uint256 _reservedAmount, uint256 _stakePerMessage)
    internal
  {
    uint256 index;
    bool isIn;
    (index, isIn) = eligibleRevealers.indexOf(_revealerAddress);
    if (totalStakes[_revealerAddress].sub(_reservedAmount) >= _stakePerMessage) {
      if (!isIn) {
        eligibleRevealers.push(_revealerAddress);
      }
    } else {
      if (isIn) {
        eligibleRevealers.remove(index);
      }
    }
  }

  function getReservedAmount(address _revealer) public view returns (uint256) {
    uint256 reservedAmount = 0;
    for(uint256 i = 0; i < revealerToMessages[_revealer].length; i++) {
      uint256 nonce = revealerToMessages[_revealer][i];
      reservedAmount = reservedAmount.add(messageToRevealerToStake[nonce][_revealer]);
    }
    return reservedAmount;
  }

  function createMessage(
    uint256 _nonce,
    uint8 _minFragments,
    uint8 _totalFragments,
    uint40 _revealBlock,
    uint40 _revealPeriod,
    uint256 _hashOfRevealSecret,
    uint256 _timeLockReward,
    address[] _revealerAddresses,
    uint256[] _revealerHashOfFragments,
    bytes _encryptedMessageIPFSHash,
    bytes _encryptedFragmentsIPFSHash
  )
    public
    noDuplicates(_revealerAddresses)
  {
    require(nonceToMessage[_nonce].creator == address(0), "Message exists already.");
    require(_revealBlock > uint40(block.number), "Reveal block is not in the future.");
    require(_revealPeriod >= MINIMUM_REVEAL_PERIOD_LENGTH, "Reveal period is not long enough.");
    require(_minFragments >= 2, "The minimum number of fragments is 2");
    require(_totalFragments == _revealerAddresses.length, "Incorrect number of fragments");
    require(_totalFragments == _revealerHashOfFragments.length, "Incorrect number of fragments");

    reserveStakes(_revealerAddresses, _nonce);

    nonceToMessage[_nonce] = Message({
      creator: msg.sender,
      secretConstructor: address(0),
      creatorWithdrewStake: false,
      secretConstructorWithdrewStake: false,
      minFragments: _minFragments,
      totalFragments: _totalFragments,
      onTimeRevealerCount: 0,
      revealBlock: _revealBlock,
      revealPeriod: _revealPeriod,
      revealSecret: uint256(0),
      hashOfRevealSecret: _hashOfRevealSecret,
      timeLockReward: _timeLockReward,
      encryptedMessage: splitIPFSHash(_encryptedMessageIPFSHash),
      encryptedFragments: splitIPFSHash(_encryptedFragmentsIPFSHash)
    });

    for (uint256 i = 0; i < _revealerAddresses.length; i++) {
      messageToRevealerToHashOfFragments[_nonce][_revealerAddresses[i]] = _revealerHashOfFragments[i];
      revealerToMessages[_revealerAddresses[i]].push(_nonce);
    }
    messageToRevealers[_nonce] = _revealerAddresses;
    messageToCreatedAt[_nonce] = block.timestamp;

    // Transfer the _timeLockReward KimonoCoins to the contract from the creator.
    // This will revert if the allowed amount in the KimonoCoin contract is insufficient.
    require(KimonoCoin(kimonoCoinAddress).transferFrom(msg.sender, address(this), _timeLockReward));

    emit MessageCreation(_nonce, msg.sender, _encryptedFragmentsIPFSHash, _revealerAddresses);
  }

  function reserveStakes(address[] _revealerAddresses, uint256 _nonce) internal {
    for(uint256 i = 0; i < _revealerAddresses.length; i++) {
      address revealerAddress = _revealerAddresses[i];
      Revealer memory revealer = revealerTable[revealerAddress];

      uint256 reservedAmount = getReservedAmount(msg.sender);
      require(totalStakes[revealerAddress].sub(reservedAmount) > revealer.stakePerMessage);

      revealerToMessages[revealerAddress].push(_nonce);
      messageToRevealerToStake[_nonce][revealerAddress] = revealer.stakePerMessage;

      updateEligibleRevealer(revealerAddress, reservedAmount, revealer.stakePerMessage);
    }
  }

  function splitBytesToFragment(bytes _fragment) internal view returns (Fragment) {
    bytes32 piece1 = bytes32(0);
    bytes18 piece2 = bytes18(0);
    uint256 i;

    for (i = 0; i < 32; i++) {
      piece1 |= bytes32(_fragment[i] & 0xFF) >> (i * 8);
    }

    for (i = 0; i < 18; i++) {
      piece2 |= bytes18(_fragment[i + 32] & 0xFF) >> (i * 8);
    }

    return Fragment({
      piece1: piece1,
      piece2: piece2
    });
  }

  function reconstructFragmentToBytes(Fragment _fragment) internal view returns (bytes) {
    bytes memory result = new bytes(50);
    uint256 i;
    for (i = 0; i < 32; i++) {
      result[i] = _fragment.piece1[i];
    }

    for (i = 32; i < 50; i++) {
      result[i] = _fragment.piece2[i];
    }

    return result;
  }

  function revealFragment(uint256 _nonce, bytes _fragment)
    public
    messageExists(_nonce)
    afterRevealPeriodStarts(_nonce)
    beforeRevealPeriodEnds(_nonce)
    withValidFragment(_nonce, _fragment, msg.sender)
  {
    require(
      messageToRevealerToHashOfFragments[_nonce][msg.sender] != uint256(0),
      "Message sender is not part of the revealers."
    );

    messageToRevealerToHashOfFragments[_nonce][msg.sender] = uint256(0);
    messageToRevealerToFragments[_nonce][msg.sender] = splitBytesToFragment(_fragment);

    // Message is not revealed
    if (nonceToMessage[_nonce].secretConstructor == address(0)) {
      messageToRevealerToRevealStatus[_nonce][msg.sender] = RevealStatus.OnTime;
      Message storage message = nonceToMessage[_nonce];
      message.onTimeRevealerCount += 1;
    } else {
      messageToRevealerToRevealStatus[_nonce][msg.sender] = RevealStatus.Late;
    }

    emit FragmentReveal(_nonce, msg.sender, message.minFragments, message.onTimeRevealerCount, _fragment);
  }

  function submitRevealSecret(uint256 _nonce, uint256 _secret)
    public
    messageExists(_nonce)
    afterRevealPeriodStarts(_nonce)
  {
    require(nonceToMessage[_nonce].secretConstructor == address(0), "Message secret is already revealed.");
    require(
      bytes32(nonceToMessage[_nonce].hashOfRevealSecret) == keccak256(_secret),
      "Revealer submitted an invalid secret."
    );

    // TODO: Remove fragments + hashes upon withdrawal to free space and get gas refund
    Message storage message = nonceToMessage[_nonce];
    message.revealSecret = _secret;
    message.secretConstructor = msg.sender;

    emit SecretReveal(_nonce, msg.sender, _secret);
  }

  function tattle(uint256 _nonce, bytes _fragment, address _tattlee)
    public
    messageExists(_nonce)
    withValidFragment(_nonce, _fragment, _tattlee)
    beforeRevealPeriodStarts(_nonce)
  {
    uint256 balance = messageToRevealerToStake[_nonce][_tattlee];
    messageToRevealerToStake[_nonce][_tattlee] = 0;

    messageToRevealerToHashOfFragments[_nonce][_tattlee] = uint256(0);
    messageToRevealerToFragments[_nonce][_tattlee] = splitBytesToFragment(_fragment);

    require(KimonoCoin(kimonoCoinAddress).transferFrom(address(this), msg.sender, balance));
    emit TattleTale(_nonce, msg.sender, _tattlee, _fragment);
  }

  function withdrawStake(uint256 _nonce)
    public
    messageExists(_nonce)
    afterRevealPeriodEnds(_nonce)
  {
    Message storage message = nonceToMessage[_nonce];
    uint256 amount = 0;

    // TODO: Remove fragments + hashes upon withdrawal to free space and get gas refund

    // Creator punishes no-shows
    if (msg.sender == message.creator && !message.creatorWithdrewStake) {
      message.creatorWithdrewStake = true;
      amount = amount.add(adjustTotalNoShowStake(_nonce));
    }

    // Reward secret constructor
    if (msg.sender == message.secretConstructor && !message.secretConstructorWithdrewStake) {
      message.secretConstructorWithdrewStake = true;
      amount = amount.add(message.timeLockReward.div(uint256(message.onTimeRevealerCount + 1)));
    }

    // Revealer showed up, so return stake
    if (messageToRevealerToRevealStatus[_nonce][msg.sender] != RevealStatus.NoShow) {
      amount = amount.add(adjustRevealerStake(_nonce));
    }

    if (amount > 0) {
      require(KimonoCoin(kimonoCoinAddress).transfer(msg.sender, amount));
      emit StakeWithdrawal(msg.sender, amount);
    }
  }

  function adjustRevealerStake(uint256 _nonce) internal returns (uint256) {
    Message memory message = nonceToMessage[_nonce];
    uint256 amount = 0;
    uint256 oldBalance = messageToRevealerToStake[_nonce][msg.sender];

    // No need to see if msg.sender is part of the revealers. If they aren't, the balance will be 0
    if (oldBalance > 0) {
      messageToRevealerToStake[_nonce][msg.sender] = 0;
      totalStakes[msg.sender] = totalStakes[msg.sender].sub(oldBalance);
      amount = amount.add(oldBalance);

      // Revealer was on time, so also give the reward
      if (messageToRevealerToRevealStatus[_nonce][msg.sender] == RevealStatus.OnTime) {
        amount = amount.add(message.timeLockReward.div(uint256(message.onTimeRevealerCount + 1)));
      }
    }

    return amount;
  }

  function adjustTotalNoShowStake(uint256 _nonce) internal returns (uint256) {
    uint256 amount = 0;
    for (uint256 i = 0; i < messageToRevealers[_nonce].length; i++) {
      address revealer = messageToRevealers[_nonce][i];
      if (messageToRevealerToRevealStatus[_nonce][revealer] == RevealStatus.NoShow) {
        uint256 oldBalance = messageToRevealerToStake[_nonce][revealer];
        messageToRevealerToStake[_nonce][revealer] = 0;
        totalStakes[revealer] = totalStakes[revealer].sub(oldBalance);
        amount = amount.add(oldBalance);
      }
    }
    return amount;
  }

  function getMessage(uint256 _nonce)
    external
    view
    returns (
      uint256 nonce,
      address creator,
      address secretConstructor,
      uint8 minFragments,
      uint8 totalFragments,
      uint40 revealBlock,
      uint40 revealPeriod,
      uint256 revealSecret,
      uint256 hashOfRevealSecret,
      uint256 timeLockReward,
      bytes encryptedMessage,
      bytes encryptedFragments
    )
  {
    Message memory message = nonceToMessage[_nonce];
    return (
      _nonce,
      message.creator,
      message.secretConstructor,
      message.minFragments,
      message.totalFragments,
      message.revealBlock,
      message.revealPeriod,
      message.revealSecret,
      message.hashOfRevealSecret,
      message.timeLockReward,
      combineIPFSHash(message.encryptedMessage),
      combineIPFSHash(message.encryptedFragments)
    );
  }

  function getMessageCreatedAt(uint256 _nonce) external view returns (uint256) {
    return messageToCreatedAt[_nonce];
  }

  function getMessageNoncesForRevealer(address _revealer) external view returns (uint256[] nonces) {
    return revealerToMessages[_revealer];
  }

  function getEligibleRevealersCount() external view returns(uint256 count) {
    return eligibleRevealers.length;
  }

  function getFragmentByMessageAndRevealer(uint256 _nonce, address _revealer)
    external
    view
    returns(bytes32 piece1, bytes18 piece2)
  {
    Fragment memory fragment = messageToRevealerToFragments[_nonce][_revealer];
    return (fragment.piece1, fragment.piece2);
  }

  function test_getFragmentHash(bytes _fragment) external view returns (bytes32 hash) {
    Fragment memory fragment = splitBytesToFragment(_fragment);
    return keccak256(fragment.piece1, fragment.piece2);
  }

  function test_compareFragmentHash(uint256 fragmentHash, bytes _fragment) external view returns (bytes32 hash, bytes32 realHash, bool isEqual) {
    Fragment memory fragment = splitBytesToFragment(_fragment);
    return (
      bytes32(fragmentHash),
      keccak256(fragment.piece1, fragment.piece2),
      bytes32(fragmentHash) == keccak256(fragment.piece1, fragment.piece2)
    );
  }
}
