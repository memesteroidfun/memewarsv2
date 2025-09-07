// memewarsv2.0.4 
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import { IPyth, PythStructs } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";

interface IMemewarsSettlerAdapter {
    function validateCreate(
        bytes calldata adapterData,
        bytes32 priceId,
        address stakeToken
    ) external view returns (bool ok);

    function finalPriceX18(
        bytes calldata adapterData,
        bytes32 priceId,
        uint48 startTs,
        uint48 endTs
    ) external view returns (uint256 pxX18, uint64 publishTime);
}

contract MemewarsV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ===== Errors =====
    error InvalidDuration();
    error PriceIdNotAllowed();
    error ComparatorNotAllowed(); // kept for compatibility (unused runtime)
    error StakeTokenNotAllowed();
    error CreatorStakeTooLow();
    error CreatorStakeTooHigh();
    error CreateRateLimit();
    error TransferInMismatch();
    error FeeTooHigh();
    error BadReceiver();
    error BadWindow();
    error BadMax();
    error BadPct();
    error BadRange();
    error BadWin();
    error BadBps();
    error BadAdapter();
    error DecTooLarge();
    error DecMismatch();
    error BadDurationIdx();

    // ===== Events =====
    event DurationsSet(uint48 minSec, uint48 maxSec);
    event AllowedDurationsSet(uint256[] durations);
    event PriceIdAllowedSet(bytes32 indexed id, bool allowed);

    event StakeTokenSet(
        address indexed token,
        uint8 decimals,
        bool allowCreate,
        bool allowJoin,
        uint256 minX18,
        uint256 maxX18
    );
    event StakeTokenFlagsSet(address indexed token, bool allowCreate, bool allowJoin);
    event StakeTokenBoundsSet(address indexed token, uint256 minX18, uint256 maxX18);

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        bytes32 indexed priceId,
        uint48 startTs,
        uint48 endTs,
        uint256 strikeX18,
        uint8 comparator,        // will always be 3 (Yes wins if final >= strike)
        uint8 settleType,
        address stakeToken,
        uint256 creatorStake,
        address adapter
    );

    event CreateRateLimitsSet(uint48 windowSec, uint16 maxPerWindow);
    event CloseBufferSet(uint16 pctBps, uint32 minSec, uint32 maxSec);

    event Joined(
        uint256 indexed marketId,
        address indexed user,
        uint8 side,
        uint256 amount,
        uint16 weightBps,
        uint256 poolYesAfter,
        uint256 poolNoAfter,
        uint256 yesNum,
        uint256 totalDen
    );

    event MarketSettled(
        uint256 indexed marketId,
        uint8 winnerSide,
        uint256 finalPriceX18,
        uint256 finalPublishTime,
        uint256 loserPool,
        uint256 winnerWeight
    );

    event MarketVoided(uint256 indexed marketId);
    event Claimed(uint256 indexed positionId, address indexed owner, uint256 amount);
    event FeeSet(uint16 feeBps, address feeReceiver);
    event FeeCollected(uint256 indexed positionId, uint256 feeAmount);
    event ShutdownSet(bool enabled);
    event AdapterAllowedSet(address indexed adapter, bool allowed);
    event OneSidedFinalized(uint256 indexed marketId, address indexed caller);
    event AdminCreatorSet(address indexed admin, bool allowed);

    // Adapter timeout
    uint32 public adapterTimeoutSec = 1 days;
    event AdapterTimeoutSet(uint32 seconds_);

    // Guardian + halt
    mapping(address => bool) public guardian;
    event GuardianSet(address indexed addr, bool allowed);
    mapping(bytes32 => bool) public priceIdHalted;
    event PriceIdHaltedSet(bytes32 indexed id, bool halted);

    // Config - duration guardrails
    uint48 public minDurSec = 1 hours;
    uint48 public maxDurSec = 30 days;

    // Preset durations (in seconds) - admin controlled
    uint256[] public allowedDurations; // e.g., [7200, 21600, 86400] for 2h, 6h, 24h

    mapping(bytes32 => bool) public allowedPriceId;

    struct StakeTokenCfg {
        uint8 decimals;    // for ERC20; ignored for native
        bool allowCreate;
        bool allowJoin;
        uint256 minX18;
        uint256 maxX18;
    }
    mapping(address => StakeTokenCfg) public stakeCfg;

    uint48 public createWindowSec = 24 hours;
    uint16 public createMaxPerWindow = 3;

    struct CreateRate { uint64 windowStart; uint16 count; }
    mapping(address => CreateRate) public createRate;

    struct CloseBufferCfg { uint16 pctBps; uint32 minSec; uint32 maxSec; }
    CloseBufferCfg public closeBuf = CloseBufferCfg({ pctBps: 1000, minSec: 15 minutes, maxSec: 24 hours });

    // Admin creator allowlist (can create neutral markets)
    mapping(address => bool) public isAdminCreator;

    // Markets & Positions
    struct Market {
        address creator;
        bytes32 priceId;
        uint256 strikeX18;
        uint8 comparator;     // kept for ABI stability; always 3
        uint8 settleType;     // 2 = Pyth, otherwise adapter
        uint48 startTs;
        uint48 endTs;
        address stakeToken;   // address(0) = native
        address adapter;      // required if settleType != 2
        bytes adapterData;
        uint256 poolYes;
        uint256 poolNo;
        uint256 weightYes;
        uint256 weightNo;
        uint32 yesUserCount;
        uint32 noUserCount;
    }
    mapping(uint256 => Market) public markets;
    uint256 public nextMarketId;

    struct Position {
        uint256 marketId;
        address owner;
        uint8 side;           // 1 = Yes, 0 = No
        uint256 amount;       // raw stake (native wei or ERC20 units)
        uint16 weightBps;     // always 10000 now
        bool claimed;
    }
    mapping(uint256 => Position) public positions;
    uint256 public nextPositionId;

    mapping(uint256 => mapping(address => bool)) public joinedYes;
    mapping(uint256 => mapping(address => bool)) public joinedNo;
    mapping(address => uint256[]) public userPositions;

    enum MarketStatus { Open, Settled, Voided }

    struct Settlement {
        bool settled;
        uint8 winnerSide;
        uint256 loserPoolSnapshot;
        uint256 winnerWeightSnapshot;
        uint256 finalPriceX18;
        uint64 publishTime;
        uint256 loserPoolOrig;
        uint256 surplusSnapshot;
        uint256 surplusRefunded;
    }
    mapping(uint256 => MarketStatus) public marketStatus;
    mapping(uint256 => Settlement) public settlement;

    uint16 public feeBps;
    address public feeReceiver;
    bool public shutdown;

    IPyth public immutable pyth;

    uint256 public constant MAX_SETTLE_DRIFT = 600;

    mapping(address => bool) public allowedAdapter;

    // Cap config
    bool public capEnabled = true;
    uint256 public capMinE18 = 3e18;
    uint256 public capMaxE18 = 10e18;
    uint256 public capKE18 = 15e18;
    uint256 public capFullAtRE18 = 300e18;

    uint8 public surplusPolicy = 0; // 0 = refund losers, 1 = send surplus to feeReceiver
    uint32 public surplusSweepDelay = 30 days;

    event CapConfigSet(bool enabled, uint256 minE18, uint256 maxE18, uint256 kE18, uint256 fullAtRE18, uint8 surplusPolicy);
    event SurplusSweepDelaySet(uint32 delaySec);
    event SurplusSwept(uint256 indexed marketId, address indexed to, uint256 amount);

    // NOTE: OZ v5+ Ownable requires initial owner
    constructor(address pythContract, address treasury) Ownable(msg.sender) {
        require(pythContract != address(0), "badPyth");
        require(treasury != address(0), "badTreasury");
        pyth = IPyth(pythContract);
        feeBps = 2;
        feeReceiver = treasury;

        // Default presets: 2h, 6h, 24h
        allowedDurations.push(2 hours);
        allowedDurations.push(6 hours);
        allowedDurations.push(24 hours);
    }

    // ===== Admin Setters =====
    function setFee(uint16 bps, address recv) external onlyOwner {
        if (bps > 400) revert FeeTooHigh();
        if (recv == address(0) && bps != 0) revert BadReceiver();
        feeBps = bps; feeReceiver = recv; emit FeeSet(bps, recv);
    }
    function setDurations(uint48 minSec, uint48 maxSec) external onlyOwner {
        if (minSec == 0 || maxSec < minSec) revert InvalidDuration();
        minDurSec = minSec; maxDurSec = maxSec; emit DurationsSet(minSec, maxSec);
    }
    function setAllowedDurations(uint256[] calldata newDurations) external onlyOwner {
        require(newDurations.length > 0, "emptyDurations");
        for (uint256 i = 0; i < newDurations.length; i++) {
            uint256 d = newDurations[i];
            require(d >= minDurSec && d <= maxDurSec, "presetOutOfBounds");
        }
        delete allowedDurations;
        for (uint256 i = 0; i < newDurations.length; i++) {
            allowedDurations.push(newDurations[i]);
        }
        emit AllowedDurationsSet(newDurations);
    }
    function setPriceIdAllowed(bytes32 id, bool allowed) external onlyOwner {
        allowedPriceId[id] = allowed; emit PriceIdAllowedSet(id, allowed);
    }
    function setPriceIdsAllowed(bytes32[] calldata ids, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < ids.length; i++) { allowedPriceId[ids[i]] = allowed; emit PriceIdAllowedSet(ids[i], allowed); }
    }
    function setStakeToken(address token, uint8 decimals_, bool allowCreate_, bool allowJoin_, uint256 minX18_, uint256 maxX18_) external onlyOwner {
        if (decimals_ > 36) revert DecTooLarge();
        if (maxX18_ != 0 && maxX18_ < minX18_) revert CreatorStakeTooHigh();
        // For native (address(0)), decimals_ is ignored; skip check
        if (token != address(0)) {
            try IERC20Metadata(token).decimals() returns (uint8 chainDec) { if (chainDec != decimals_) revert DecMismatch(); } catch {}
        }
        stakeCfg[token] = StakeTokenCfg({ decimals: decimals_, allowCreate: allowCreate_, allowJoin: allowJoin_, minX18: minX18_, maxX18: maxX18_ });
        emit StakeTokenSet(token, decimals_, allowCreate_, allowJoin_, minX18_, maxX18_);
    }
    function setStakeTokenFlags(address token, bool allowCreate_, bool allowJoin_) external onlyOwner {
        StakeTokenCfg storage cfg = stakeCfg[token];
        if (cfg.decimals == 0 && cfg.minX18 == 0 && cfg.maxX18 == 0 && token != address(0)) revert StakeTokenNotAllowed();
        cfg.allowCreate = allowCreate_; cfg.allowJoin = allowJoin_; emit StakeTokenFlagsSet(token, allowCreate_, allowJoin_);
    }
    function setStakeTokenBounds(address token, uint256 minX18_, uint256 maxX18_) external onlyOwner {
        StakeTokenCfg storage cfg = stakeCfg[token];
        if (!cfg.allowCreate && !cfg.allowJoin) revert StakeTokenNotAllowed();
        if (maxX18_ != 0 && maxX18_ < minX18_) revert CreatorStakeTooHigh();
        cfg.minX18 = minX18_; cfg.maxX18 = maxX18_; emit StakeTokenBoundsSet(token, minX18_, maxX18_);
    }
    function setCreateRateLimits(uint48 windowSec, uint16 maxPerWindow) external onlyOwner {
        if (windowSec < 1 hours || windowSec > 14 days) revert BadWindow();
        if (maxPerWindow == 0 || maxPerWindow > 1000) revert BadMax();
        createWindowSec = windowSec; createMaxPerWindow = maxPerWindow; emit CreateRateLimitsSet(windowSec, maxPerWindow);
    }
    function setCloseBuffer(uint16 pctBps, uint32 minSec, uint32 maxSec) external onlyOwner {
        if (pctBps > 10_000) revert BadPct();
        if (minSec > maxSec || maxSec > 30 days) revert BadRange();
        closeBuf = CloseBufferCfg({ pctBps: pctBps, minSec: minSec, maxSec: maxSec }); emit CloseBufferSet(pctBps, minSec, maxSec);
    }
    function setAdapterAllowed(address adapter, bool allowed) external onlyOwner {
        if (adapter == address(0)) revert BadAdapter(); allowedAdapter[adapter] = allowed; emit AdapterAllowedSet(adapter, allowed);
    }
    function setCapConfig(bool enabled, uint256 minE18, uint256 maxE18, uint256 kE18, uint256 fullAtRE18, uint8 policy) external onlyOwner {
        require(minE18 >= 3e18, "min<3x"); require(maxE18 <= 10e18 && maxE18 >= minE18, "badMax");
        require(kE18 >= 1e18 && kE18 <= 10_000e18, "badK"); require(fullAtRE18 >= 1e18, "badFullAt"); require(policy <= 1, "badPolicy");
        capEnabled = enabled; capMinE18 = minE18; capMaxE18 = maxE18; capKE18 = kE18; capFullAtRE18 = fullAtRE18; surplusPolicy = policy;
        emit CapConfigSet(enabled, minE18, maxE18, kE18, fullAtRE18, policy);
    }
    function setSurplusSweepDelay(uint32 delaySec) external onlyOwner {
        require(delaySec >= 1 days && delaySec <= 365 days, "badDelay");
        surplusSweepDelay = delaySec; emit SurplusSweepDelaySet(delaySec);
    }
    function setAdapterTimeout(uint32 seconds_) external onlyOwner {
        require(seconds_ >= 5 minutes && seconds_ <= 14 days, "badAdapterTimeout");
        adapterTimeoutSec = seconds_; emit AdapterTimeoutSet(seconds_);
    }
    function setGuardian(address addr, bool allowed) external onlyOwner {
        require(addr != address(0), "badGuardian"); guardian[addr] = allowed; emit GuardianSet(addr, allowed);
    }
    modifier onlyOwnerOrGuardian() { require(owner() == msg.sender || guardian[msg.sender], "notAuth"); _; }
    function setPriceIdHalted(bytes32 id, bool halted) external onlyOwnerOrGuardian {
        priceIdHalted[id] = halted; emit PriceIdHaltedSet(id, halted);
    }
    function setAdminCreator(address admin, bool allowed) external onlyOwner {
        isAdminCreator[admin] = allowed; emit AdminCreatorSet(admin, allowed);
    }

    // Shutdown / Void
    function emergencyShutdown() external onlyOwner { if (!shutdown) { shutdown = true; emit ShutdownSet(true); } }
    function clearShutdown() external onlyOwner { shutdown = false; emit ShutdownSet(false); }
    function adminVoid(uint256 marketId) external onlyOwner { if (marketStatus[marketId] == MarketStatus.Open) { marketStatus[marketId] = MarketStatus.Voided; emit MarketVoided(marketId); } }
    function adminVoidBatch(uint256[] calldata ids) external onlyOwner {
        for (uint256 i = 0; i < ids.length; i++) { uint256 mid = ids[i]; if (marketStatus[mid] == MarketStatus.Open) { marketStatus[mid] = MarketStatus.Voided; emit MarketVoided(mid); } }
    }

    // Helpers
    // _compare kept but unused; winner side is hard-coded as final >= strike
    function _compare(uint256 finalX18, uint256 strikeX18, uint8 comparator) internal pure returns (bool) {
        if (comparator == 1) return finalX18 <= strikeX18;
        if (comparator == 3) return finalX18 >= strikeX18;
        revert ComparatorNotAllowed();
    }
    function _checkAndBumpCreateLimits(address user) internal {
        CreateRate storage r = createRate[user]; uint64 nowTs = uint64(block.timestamp);
        if (nowTs - r.windowStart >= createWindowSec) { r.windowStart = nowTs; r.count = 0; }
        if (r.count >= createMaxPerWindow) revert CreateRateLimit(); unchecked { r.count += 1; }
    }
    function _closeBufferFor(uint48 dur) internal view returns (uint48) {
        uint256 pct = uint256(dur) * closeBuf.pctBps / 10_000;
        if (pct < closeBuf.minSec) pct = closeBuf.minSec;
        if (pct > closeBuf.maxSec) pct = closeBuf.maxSec;
        return uint48(pct);
    }
    function _gapE18(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 && b == 0) return 1e18; if (a == 0) a = 1; if (b == 0) b = 1;
        return a >= b ? Math.mulDiv(a, 1e18, b) : Math.mulDiv(b, 1e18, a);
    }
    function _capFromGapSmooth(uint256 gapE18) internal view returns (uint256) {
        if (!capEnabled) return type(uint256).max;
        if (gapE18 >= capFullAtRE18) return capMaxE18;
        uint256 delta = capMaxE18 - capMinE18;
        uint256 inc = Math.mulDiv(delta, gapE18, gapE18 + capKE18);
        uint256 c = capMinE18 + inc;
        return c > capMaxE18 ? capMaxE18 : c;
    }
    function joinCloseTime(uint256 marketId) public view returns (uint48) {
        Market storage m = markets[marketId]; uint48 dur = m.endTs - m.startTs; return m.endTs - _closeBufferFor(dur);
    }

    // Create / Join
    modifier whenJoinOpen(uint256 marketId) { require(block.timestamp < joinCloseTime(marketId), "joinClosed"); _; }

    /**
     * @dev comparator is fixed to 3 (Yes wins if final >= strike).
     * Admin creators may create neutral markets by passing creatorStakeInput == 0.
     */
    function createMarket(
        bytes32 priceId,
        uint256 strikeX18,
        uint8 settleType,
        address stakeToken,
        address adapter,
        bytes calldata adapterData,
        uint256 durationIdx,
        uint8 creatorSide,
        uint256 creatorStakeInput
    ) external payable nonReentrant returns (uint256 marketId) {
        require(!shutdown, "shutdown");
        if (!allowedPriceId[priceId]) revert PriceIdNotAllowed();
        if (priceIdHalted[priceId]) revert PriceIdNotAllowed();

        if (settleType != 2) {
            if (adapter == address(0)) revert BadAdapter();
            if (!allowedAdapter[adapter]) revert BadAdapter();
            bool ok = IMemewarsSettlerAdapter(adapter).validateCreate(adapterData, priceId, stakeToken);
            require(ok, "adapterDenied");
        }

        if (durationIdx >= allowedDurations.length) revert BadDurationIdx();
        uint256 durU = allowedDurations[durationIdx];
        if (durU < minDurSec || durU > maxDurSec) revert InvalidDuration();
        uint48 start = uint48(block.timestamp);
        uint48 endTs = uint48(start + uint48(durU));

        StakeTokenCfg memory cfg = stakeCfg[stakeToken];
        if (!cfg.allowCreate) revert StakeTokenNotAllowed();

        bool adminNeutral = isAdminCreator[msg.sender] && creatorStakeInput == 0;

        if (!adminNeutral) {
            require(creatorSide <= 1, "badSide");
            _checkAndBumpCreateLimits(msg.sender);

            // bounds check on creator stake (X18)
            uint256 intendedX18;
            if (stakeToken == address(0)) {
                intendedX18 = creatorStakeInput; // native assumed 18 decimals
            } else {
                uint256 denom = 10 ** cfg.decimals;
                intendedX18 = creatorStakeInput.mulDiv(1e18, denom);
            }
            if (intendedX18 < cfg.minX18) revert CreatorStakeTooLow();
            if (cfg.maxX18 != 0 && intendedX18 > cfg.maxX18) revert CreatorStakeTooHigh();

            // pull funds
            uint256 received;
            if (stakeToken == address(0)) {
                require(msg.value == creatorStakeInput, "badMsgValue");
                received = msg.value;
            } else {
                require(msg.value == 0, "noETHWithERC20");
                uint256 balBefore = IERC20(stakeToken).balanceOf(address(this));
                IERC20(stakeToken).safeTransferFrom(msg.sender, address(this), creatorStakeInput);
                received = IERC20(stakeToken).balanceOf(address(this)) - balBefore;
                if (received != creatorStakeInput) revert TransferInMismatch();
            }

            marketId = ++nextMarketId;
            Market storage m = markets[marketId];
            m.creator = msg.sender; m.priceId = priceId; m.strikeX18 = strikeX18; m.comparator = 3; m.settleType = settleType;
            m.startTs = start; m.endTs = endTs; m.stakeToken = stakeToken; m.adapter = adapter; m.adapterData = adapterData;

            uint16 wBps = 10_000; // full weight
            if (creatorSide == 1) {
                m.poolYes += received; m.weightYes += received;
                if (!joinedYes[marketId][msg.sender]) { joinedYes[marketId][msg.sender] = true; m.yesUserCount += 1; }
            } else {
                m.poolNo += received; m.weightNo += received;
                if (!joinedNo[marketId][msg.sender]) { joinedNo[marketId][msg.sender] = true; m.noUserCount += 1; }
            }

            uint256 pid = ++nextPositionId;
            positions[pid] = Position({ marketId: marketId, owner: msg.sender, side: creatorSide, amount: received, weightBps: wBps, claimed: false });
            userPositions[msg.sender].push(pid);

            emit MarketCreated(marketId, msg.sender, priceId, start, endTs, strikeX18, 3, settleType, stakeToken, received, adapter);
        } else {
            require(msg.value == 0, "noValueForNeutral");
            marketId = ++nextMarketId;
            Market storage m = markets[marketId];
            m.creator = msg.sender; m.priceId = priceId; m.strikeX18 = strikeX18; m.comparator = 3; m.settleType = settleType;
            m.startTs = start; m.endTs = endTs; m.stakeToken = stakeToken; m.adapter = adapter; m.adapterData = adapterData;

            emit MarketCreated(marketId, msg.sender, priceId, start, endTs, strikeX18, 3, settleType, stakeToken, 0, adapter);
        }
    }

    function join(uint256 marketId, uint8 side, uint256 amount) external payable nonReentrant whenJoinOpen(marketId) {
        require(!shutdown, "shutdown");
        require(side <= 1, "badSide"); require(amount > 0, "zeroAmount");
        Market storage m = markets[marketId]; StakeTokenCfg memory cfg = stakeCfg[m.stakeToken]; require(cfg.allowJoin, "joinDisabled");

        uint256 received;
        if (m.stakeToken == address(0)) {
            require(msg.value == amount, "badMsgValue");
            received = msg.value;
        } else {
            require(msg.value == 0, "noETHWithERC20");
            uint256 balBefore = IERC20(m.stakeToken).balanceOf(address(this));
            IERC20(m.stakeToken).safeTransferFrom(msg.sender, address(this), amount);
            received = IERC20(m.stakeToken).balanceOf(address(this)) - balBefore;
            if (received != amount) revert TransferInMismatch();
        }

        uint16 wBps = 10_000;
        uint256 eff = received; // full weight

        if (side == 1) { m.poolYes += received; m.weightYes += eff; if (!joinedYes[marketId][msg.sender]) { joinedYes[marketId][msg.sender] = true; m.yesUserCount += 1; } }
        else { m.poolNo += received; m.weightNo += eff; if (!joinedNo[marketId][msg.sender]) { joinedNo[marketId][msg.sender] = true; m.noUserCount += 1; } }

        uint256 pid = ++nextPositionId;
        positions[pid] = Position({ marketId: marketId, owner: msg.sender, side: side, amount: received, weightBps: wBps, claimed: false });
        userPositions[msg.sender].push(pid);

        uint256 Y = m.poolYes; uint256 N = m.poolNo; uint256 totalDen = Y + N; uint256 yesNum; if (totalDen == 0) { yesNum = 1; totalDen = 2; } else { yesNum = Y; }
        emit Joined(marketId, msg.sender, side, received, wBps, Y, N, yesNum, totalDen);
    }

    // Settlement / Finalization
    function _winnerSide(uint256 marketId, uint256 finalX18) internal view returns (uint8) {
        // FIXED RULE: Yes (1) wins if final >= strike
        Market storage m = markets[marketId];
        return finalX18 >= m.strikeX18 ? 1 : 0;
    }
    function _isOneSided(uint256 marketId) internal view returns (bool) { Market storage m = markets[marketId]; return (m.poolYes == 0 || m.poolNo == 0); }
    function _isAdapterTimeout(uint256 marketId) internal view returns (bool) { Market storage m = markets[marketId]; if (m.settleType == 2) return false; return block.timestamp >= (uint256(m.endTs) + uint256(adapterTimeoutSec)); }

    function finalizeTimeout(uint256 marketId) external nonReentrant {
        require(marketStatus[marketId] == MarketStatus.Open, "notOpen"); Market storage m = markets[marketId];
        require(m.settleType != 2, "notAdapter"); require(_isAdapterTimeout(marketId), "timeoutNotReached");
        marketStatus[marketId] = MarketStatus.Voided; emit MarketVoided(marketId);
    }
    function finalizeHazard(uint256 marketId) external nonReentrant {
        require(marketStatus[marketId] == MarketStatus.Open, "notOpen"); Market storage m = markets[marketId];
        require(priceIdHalted[m.priceId], "notHalted"); marketStatus[marketId] = MarketStatus.Voided; emit MarketVoided(marketId);
    }

    function settle(uint256 marketId, bytes[] calldata priceUpdateData) external payable nonReentrant {
        require(marketStatus[marketId] == MarketStatus.Open, "notOpen");
        Market storage m = markets[marketId];
        require(block.timestamp >= m.endTs, "tooEarly");
        require(!shutdown, "shutdown");

        if (priceIdHalted[m.priceId]) { marketStatus[marketId] = MarketStatus.Voided; emit MarketVoided(marketId); return; }
        if (m.poolYes == 0 || m.poolNo == 0) { marketStatus[marketId] = MarketStatus.Voided; emit MarketVoided(marketId); return; }

        uint256 finalX18; uint64 pubTime;

        if (m.settleType == 2) {
            uint256 fee = pyth.getUpdateFee(priceUpdateData);
            require(msg.value >= fee, "feeTooLow");

            bytes32[] memory priceIds = new bytes32[](1);
            priceIds[0] = m.priceId;

            uint64 minT = uint64(m.endTs);
            uint64 maxT = uint64(m.endTs) + uint64(MAX_SETTLE_DRIFT);

            PythStructs.PriceFeed[] memory feeds =
                pyth.parsePriceFeedUpdates{ value: fee }(priceUpdateData, priceIds, minT, maxT);

            require(feeds.length > 0, "noFeed");
            PythStructs.Price memory pr = feeds[0].price; require(pr.price > 0, "badPrice");
            pubTime = uint64(pr.publishTime);

            uint256 refund = msg.value - fee;
            if (refund > 0) {
                (bool ok, ) = msg.sender.call{value: refund}("");
                require(ok, "refundFail");
            }

            if (pr.expo < 0) {
                uint32 k = uint32(-pr.expo); require(k <= 36, "expoTooLarge");
                uint256 scaleDiv = 10 ** k; finalX18 = Math.mulDiv(uint64(pr.price), 1e18, scaleDiv);
            } else if (pr.expo > 0) {
                uint32 k2 = uint32(pr.expo); require(k2 <= 36, "expoTooLarge");
                uint256 scaleMul = 10 ** k2; uint256 base = Math.mulDiv(uint64(pr.price), 1e18, 1);
                require(base <= type(uint256).max / scaleMul, "priceOverflow"); finalX18 = base * scaleMul;
            } else { finalX18 = uint64(pr.price) * 1e18; }
        } else {
            require(msg.value == 0, "noETHNeeded");
            if (m.adapter == address(0) || !allowedAdapter[m.adapter]) revert BadAdapter();
            (finalX18, pubTime) = IMemewarsSettlerAdapter(m.adapter).finalPriceX18(m.adapterData, m.priceId, m.startTs, m.endTs);
            require(pubTime >= m.endTs && pubTime <= m.endTs + uint64(MAX_SETTLE_DRIFT), "priceWindow");
        }

        uint8 w = _winnerSide(marketId, finalX18);
        uint256 loserPool = (w == 1) ? m.poolNo : m.poolYes;
        uint256 winnerWeight = (w == 1) ? m.weightYes : m.weightNo;

        uint256 effYes = m.weightYes; uint256 effNo = m.weightNo;
        uint256 gapE18 = _gapE18(effYes, effNo); uint256 capE18 = _capFromGapSmooth(gapE18);

        uint256 rE18 = Math.mulDiv(loserPool, 1e18, winnerWeight);
        uint256 paidLoserPool = loserPool; uint256 surplus = 0;
        if (capE18 < type(uint256).max && rE18 > capE18) {
            paidLoserPool = Math.mulDiv(winnerWeight, capE18, 1e18);
            surplus = loserPool - paidLoserPool;
            if (surplus > 0 && surplusPolicy == 1) {
                if (m.stakeToken == address(0)) {
                    (bool ok, ) = feeReceiver.call{value: surplus}("");
                    require(ok, "surplusPayFail");
                } else {
                    IERC20(m.stakeToken).safeTransfer(feeReceiver, surplus);
                }
            }
        }

        settlement[marketId] = Settlement({
            settled: true, winnerSide: w, loserPoolSnapshot: paidLoserPool, winnerWeightSnapshot: winnerWeight,
            finalPriceX18: finalX18, publishTime: pubTime, loserPoolOrig: loserPool, surplusSnapshot: surplus, surplusRefunded: 0
        });
        marketStatus[marketId] = MarketStatus.Settled;
        emit MarketSettled(marketId, w, finalX18, uint256(pubTime), paidLoserPool, winnerWeight);
    }

    // Claims / Sweep
    function _claimOne(uint256 positionId, address to) private returns (uint256 paidOut) {
        Position storage p = positions[positionId]; require(!p.claimed, "claimed"); require(p.owner == to, "notOwner");
        MarketStatus st = marketStatus[p.marketId];

        if (st == MarketStatus.Open && block.timestamp >= joinCloseTime(p.marketId) && _isOneSided(p.marketId)) {
            marketStatus[p.marketId] = MarketStatus.Voided; emit MarketVoided(p.marketId); st = MarketStatus.Voided;
        }
        if (st == MarketStatus.Open) {
            Market storage m_ = markets[p.marketId];
            if (m_.settleType != 2 && _isAdapterTimeout(p.marketId)) { marketStatus[p.marketId] = MarketStatus.Voided; emit MarketVoided(p.marketId); st = MarketStatus.Voided; }
        }
        if (st == MarketStatus.Open && priceIdHalted[markets[p.marketId].priceId]) {
            marketStatus[p.marketId] = MarketStatus.Voided; emit MarketVoided(p.marketId); st = MarketStatus.Voided;
        }
        if (st == MarketStatus.Open && shutdown) {
            p.claimed = true;
            if (markets[p.marketId].stakeToken == address(0)) {
                (bool ok, ) = to.call{value: p.amount}("");
                require(ok, "payFail");
            } else {
                IERC20(markets[p.marketId].stakeToken).safeTransfer(to, p.amount);
            }
            emit Claimed(positionId, to, p.amount); return p.amount;
        }

        Settlement storage s = settlement[p.marketId];
        if (st == MarketStatus.Voided) {
            p.claimed = true;
            if (markets[p.marketId].stakeToken == address(0)) {
                (bool ok2, ) = to.call{value: p.amount}("");
                require(ok2, "payFail");
            } else {
                IERC20(markets[p.marketId].stakeToken).safeTransfer(to, p.amount);
            }
            emit Claimed(positionId, to, p.amount); return p.amount;
        }

        require(st == MarketStatus.Settled && s.settled, "notSettled");
        if (p.side != s.winnerSide) {
            uint256 refund = 0;
            if (surplusPolicy == 0 && s.surplusSnapshot != 0 && s.loserPoolOrig != 0) {
                refund = Math.mulDiv(s.surplusSnapshot, p.amount, s.loserPoolOrig);
                if (refund != 0) {
                    if (markets[p.marketId].stakeToken == address(0)) {
                        (bool ok3, ) = to.call{value: refund}("");
                        require(ok3, "refundFail");
                    } else {
                        IERC20(markets[p.marketId].stakeToken).safeTransfer(to, refund);
                    }
                    s.surplusRefunded += refund;
                }
            }
            p.claimed = true; emit Claimed(positionId, to, refund); return refund;
        }

        uint256 posWeight = Math.mulDiv(p.amount, p.weightBps, 10_000);
        uint256 profitGross = Math.mulDiv(s.loserPoolSnapshot, posWeight, s.winnerWeightSnapshot);
        uint256 profitNet = profitGross;
        if (feeBps != 0 && feeReceiver != address(0)) {
            uint256 feeAmt = Math.mulDiv(profitGross, feeBps, 10_000);
            profitNet = profitGross - feeAmt;
            if (markets[p.marketId].stakeToken == address(0)) {
                (bool ok4, ) = feeReceiver.call{value: feeAmt}("");
                require(ok4, "feePayFail");
            } else {
                IERC20(markets[p.marketId].stakeToken).safeTransfer(feeReceiver, feeAmt);
            }
            emit FeeCollected(positionId, feeAmt);
        }
        uint256 payout = p.amount + profitNet; p.claimed = true;
        if (markets[p.marketId].stakeToken == address(0)) {
            (bool ok5, ) = to.call{value: payout}("");
            require(ok5, "payoutFail");
        } else {
            IERC20(markets[p.marketId].stakeToken).safeTransfer(to, payout);
        }
        emit Claimed(positionId, to, payout); return payout;
    }
    function claim(uint256 positionId) external nonReentrant { _claimOne(positionId, msg.sender); }
    function claimMany(uint256[] calldata positionIds) external nonReentrant { for (uint256 i = 0; i < positionIds.length; i++) { _claimOne(positionIds[i], msg.sender); } }

    function finalizeOneSided(uint256 marketId) external nonReentrant {
        require(marketStatus[marketId] == MarketStatus.Open, "notOpen"); require(block.timestamp >= joinCloseTime(marketId), "joinOpen");
        require(_isOneSided(marketId), "twoSided"); marketStatus[marketId] = MarketStatus.Voided; emit MarketVoided(marketId); emit OneSidedFinalized(marketId, msg.sender);
    }

    function sweepUnclaimedSurplus(uint256 marketId, address to) external onlyOwner nonReentrant {
        require(to != address(0), "badTo"); require(marketStatus[marketId] == MarketStatus.Settled, "notSettled");
        Settlement storage s = settlement[marketId]; require(s.surplusSnapshot > 0, "noSurplus"); require(surplusPolicy == 0, "policyNotRefund");
        require(block.timestamp >= uint256(s.publishTime) + surplusSweepDelay, "delay");
        uint256 remaining = s.surplusSnapshot - s.surplusRefunded; require(remaining > 0, "noneLeft");
        s.surplusRefunded += remaining;
        address stk = markets[marketId].stakeToken;
        if (stk == address(0)) {
            (bool ok, ) = to.call{value: remaining}("");
            require(ok, "sweepFail");
        } else {
            IERC20(stk).safeTransfer(to, remaining);
        }
        emit SurplusSwept(marketId, to, remaining);
    }

    // Views
    function getMarket(uint256 marketId) external view returns (Market memory) { return markets[marketId]; }
    function isPriceIdAllowed(bytes32 id) external view returns (bool) { return allowedPriceId[id]; }
    function sideUserCounts(uint256 marketId) external view returns (uint256 yesCount, uint256 noCount) { Market storage m = markets[marketId]; return (m.yesUserCount, m.noUserCount); }
    function userSides(uint256 marketId, address user) external view returns (bool joinedYesSide, bool joinedNoSide) { return (joinedYes[marketId][user], joinedNo[marketId][user]); }

    function previewOdds(uint256 marketId) external view returns (uint256 yesNum, uint256 totalDen) {
        Market storage m = markets[marketId]; uint256 Y = m.poolYes; uint256 N = m.poolNo; uint256 den = Y + N; if (den == 0) return (1, 2); return (Y, den);
    }
    function previewOddsAfterJoin(uint256 marketId, uint8 side, uint256 amount) external view returns (uint256 yesNum, uint256 totalDen) {
        require(side <= 1, "badSide"); Market storage m = markets[marketId]; uint256 Y = m.poolYes; uint256 N = m.poolNo; if (amount != 0) { if (side == 1) { Y += amount; } else { N += amount; } }
        uint256 den = Y + N; if (den == 0) return (1, 2); return (Y, den);
    }

    function previewJoinImpact(uint256 marketId, uint8 side, uint256 amount, uint256 ts)
        external view returns (uint256 yesNum, uint256 totalDen, uint16 weightBps, uint256 estimatedPosWeight)
    {
        require(side <= 1, "badSide"); Market storage m = markets[marketId];
        uint48 dur = m.endTs - m.startTs; uint48 closeAt = m.endTs - _closeBufferFor(dur);
        bool joinAllowed = (ts >= m.startTs) && (ts < closeAt);

        if (!joinAllowed) { weightBps = 0; estimatedPosWeight = 0; }
        else { weightBps = 10_000; estimatedPosWeight = amount; }

        uint256 Y = m.poolYes; uint256 N = m.poolNo; if (amount != 0) { if (side == 1) { Y += amount; } else { N += amount; } }
        uint256 den = Y + N; if (den == 0) return (1, 2, weightBps, estimatedPosWeight); return (Y, den, weightBps, estimatedPosWeight);
    }

    /// @notice Off-chain helper only. Do not use on-chain.
    function exposureOf(address user, uint256 marketId) external view returns (uint256 yesAmount, uint256 noAmount, uint256 yesWeight, uint256 noWeight) {
        uint256[] storage arr = userPositions[user];
        for (uint256 i = 0; i < arr.length; i++) {
            Position storage p = positions[arr[i]];
            if (p.marketId != marketId || p.claimed) continue;
            uint256 eff = Math.mulDiv(p.amount, p.weightBps, 10_000);
            if (p.side == 1) { yesAmount += p.amount; yesWeight += eff; } else { noAmount += p.amount; noWeight += eff; }
        }
    }

    /// @notice Off-chain helper only. Do not use on-chain.
    function getUserPositions(address user, uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256[] storage arr = userPositions[user];
        if (offset >= arr.length) return new uint256[](0);
        uint256 end = arr.length; if (limit != 0 && offset + limit < end) end = offset + limit;
        uint256 len = end - offset; ids = new uint256[](len);
        for (uint256 i = 0; i < len; i++) { ids[i] = arr[offset + i]; }
    }

    /// @notice Off-chain helper only. Do not use on-chain.
    function getUserPositionsInMarket(address user, uint256 marketId, uint256 offset, uint256 limit, bool includeClaimed)
        external view returns (uint256[] memory ids)
    {
        uint256[] storage arr = userPositions[user];
        if (offset > arr.length) return new uint256[](0);
        uint256 end = arr.length; if (limit != 0 && offset + limit < end) end = offset + limit;

        uint256 count = 0;
        for (uint256 i = offset; i < end; i++) {
            Position storage p = positions[arr[i]];
            if (p.marketId != marketId) continue;
            if (!includeClaimed && p.claimed) continue;
            count++;
        }

        ids = new uint256[](count);
        uint256 j = 0;
        for (uint256 i = offset; i < end; i++) {
            Position storage p = positions[arr[i]];
            if (p.marketId != marketId) continue;
            if (!includeClaimed && p.claimed) continue;
            ids[j++] = arr[i];
        }
    }

    // Block direct ETH sends; only payable paths are join/create (native) and settle (pyth fee)
    receive() external payable { revert("directETHDisabled"); }
}
