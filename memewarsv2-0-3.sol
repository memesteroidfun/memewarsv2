// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
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

contract MemewarsV2 is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    error InvalidDuration();
    error PriceIdNotAllowed();
    error ComparatorNotAllowed();
    error StakeTokenNotAllowed();
    error CreatorStakeTooLow();
    error CreatorStakeTooHigh();
    error CreateRateLimit();
    error TransferInMismatch();

    // Micro-trim B: custom errors for selected checks
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

    event DurationsSet(uint48 minSec, uint48 maxSec);
    event PriceIdAllowedSet(bytes32 indexed id, bool allowed);
    event StakeTokenSet(address indexed token, uint8 decimals, bool allowCreate, bool allowJoin, uint256 minX18, uint256 maxX18);
    event StakeTokenFlagsSet(address indexed token, bool allowCreate, bool allowJoin);
    event StakeTokenBoundsSet(address indexed token, uint256 minX18, uint256 maxX18);
    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        bytes32 indexed priceId,
        uint48 startTs,
        uint48 endTs,
        uint256 strikeX18,
        uint8 comparator,
        uint8 settleType,
        address stakeToken,
        uint256 creatorStake,
        address adapter
    );
    event CreateRateLimitsSet(uint48 windowSec, uint16 maxPerWindow);
    event CloseBufferSet(uint16 pctBps, uint32 minSec, uint32 maxSec);
    event LateJoinParamsSet(uint16 windowPctBps, uint16 lateStartBps, uint16 lateEndBps);
    event Joined(
        uint256 indexed marketId,
        address indexed user,
        uint8 side,
        uint256 amount,
        uint16 weightBps,
        uint256 poolYesAfter,
        uint256 poolNoAfter,
        uint256 pYesNum,
        uint256 pDen
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
    event CreditsDeposited(address indexed user, uint256 amount);
    event CreditsWithdrawn(address indexed user, uint256 amount);
    event AdapterAllowedSet(address indexed adapter, bool allowed);
    event OneSidedFinalized(uint256 indexed marketId, address indexed caller);

    uint48 public minDurSec = 1 hours;
    uint48 public maxDurSec = 30 days;

    mapping(bytes32 => bool) public allowedPriceId;

    struct StakeTokenCfg {
        uint8 decimals;
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

    uint16 public lateWindowPctBps = 2000;
    uint16 public lateStartWeightBps = 5000;
    uint16 public lateEndWeightBps   = 1000;

    struct Market {
        address creator;
        bytes32 priceId;
        uint256 strikeX18;
        uint8 comparator;
        uint8 settleType;
        uint48 startTs;
        uint48 endTs;
        address stakeToken;
        address adapter;
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
        uint8 side;
        uint256 amount;
        uint16 weightBps;
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

    mapping(address => uint256) public ethCredits;

    IPyth public immutable pyth;
    uint256 public constant MAX_SETTLE_DRIFT = 600;
    uint256 public constant SETTLE_DRIFT_SEC = 600;

    // Micro-trim A: removed VERSION/SHA + versionInfo() to save bytes

    mapping(address => bool) public allowedAdapter;

    bool    public capEnabled    = false;
    uint256 public capMinE18     = 3e18;
    uint256 public capMaxE18     = 10e18;
    uint256 public capKE18       = 15e18;
    uint256 public capFullAtRE18 = 300e18;

    uint8   public surplusPolicy = 0;

    uint32  public surplusSweepDelay = 30 days;
    event CapConfigSet(bool enabled, uint256 minE18, uint256 maxE18, uint256 kE18, uint256 fullAtRE18, uint8 surplusPolicy);
    event SurplusSweepDelaySet(uint32 delaySec);
    event SurplusSwept(uint256 indexed marketId, address indexed to, uint256 amount);

    constructor(address pythContract, address treasury) Ownable(msg.sender) {
        require(pythContract != address(0), "badPyth");
        require(treasury != address(0), "badTreasury");
        pyth = IPyth(pythContract);
        feeBps = 0;
        feeReceiver = treasury;
    }

    function setFee(uint16 bps, address recv) external onlyOwner {
        // require(bps <= 400, "feeTooHigh");
        // require(recv != address(0) || bps == 0, "badReceiver");
        if (bps > 400) revert FeeTooHigh();
        if (recv == address(0) && bps != 0) revert BadReceiver();
        feeBps = bps;
        feeReceiver = recv;
        emit FeeSet(bps, recv);
    }

    function setDurations(uint48 minSec, uint48 maxSec) external onlyOwner {
        if (minSec == 0 || maxSec < minSec) revert InvalidDuration();
        minDurSec = minSec;
        maxDurSec = maxSec;
        emit DurationsSet(minSec, maxSec);
    }

    function setPriceIdAllowed(bytes32 id, bool allowed) external onlyOwner {
        allowedPriceId[id] = allowed;
        emit PriceIdAllowedSet(id, allowed);
    }

    function setPriceIdsAllowed(bytes32[] calldata ids, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < ids.length; i++) {
            allowedPriceId[ids[i]] = allowed;
            emit PriceIdAllowedSet(ids[i], allowed);
        }
    }

    function setStakeToken(
        address token,
        uint8 decimals_,
        bool allowCreate_,
        bool allowJoin_,
        uint256 minX18_,
        uint256 maxX18_
    ) external onlyOwner {
        // require(decimals_ <= 36, "decTooLarge");
        if (decimals_ > 36) revert DecTooLarge();
        if (maxX18_ != 0 && maxX18_ < minX18_) revert CreatorStakeTooHigh();
        try IERC20Metadata(token).decimals() returns (uint8 chainDec) {
            // require(chainDec == decimals_, "decMismatch");
            if (chainDec != decimals_) revert DecMismatch();
        } catch {}
        stakeCfg[token] = StakeTokenCfg({
            decimals: decimals_,
            allowCreate: allowCreate_,
            allowJoin: allowJoin_,
            minX18: minX18_,
            maxX18: maxX18_
        });
        emit StakeTokenSet(token, decimals_, allowCreate_, allowJoin_, minX18_, maxX18_);
    }

    function setStakeTokenFlags(address token, bool allowCreate_, bool allowJoin_) external onlyOwner {
        StakeTokenCfg storage cfg = stakeCfg[token];
        if (cfg.decimals == 0 && cfg.minX18 == 0 && cfg.maxX18 == 0) revert StakeTokenNotAllowed();
        cfg.allowCreate = allowCreate_;
        cfg.allowJoin = allowJoin_;
        emit StakeTokenFlagsSet(token, allowCreate_, allowJoin_);
    }

    function setStakeTokenBounds(address token, uint256 minX18_, uint256 maxX18_) external onlyOwner {
        StakeTokenCfg storage cfg = stakeCfg[token];
        if (!cfg.allowCreate && !cfg.allowJoin) revert StakeTokenNotAllowed();
        if (maxX18_ != 0 && maxX18_ < minX18_) revert CreatorStakeTooHigh();
        cfg.minX18 = minX18_;
        cfg.maxX18 = maxX18_;
        emit StakeTokenBoundsSet(token, minX18_, maxX18_);
    }

    function setCreateRateLimits(uint48 windowSec, uint16 maxPerWindow) external onlyOwner {
        // require(windowSec >= 1 hours && windowSec <= 14 days, "badWindow");
        // require(maxPerWindow > 0 && maxPerWindow <= 1000, "badMax");
        if (windowSec < 1 hours || windowSec > 14 days) revert BadWindow();
        if (maxPerWindow == 0 || maxPerWindow > 1000) revert BadMax();
        createWindowSec = windowSec;
        createMaxPerWindow = maxPerWindow;
        emit CreateRateLimitsSet(windowSec, maxPerWindow);
    }

    function setCloseBuffer(uint16 pctBps, uint32 minSec, uint32 maxSec) external onlyOwner {
        // require(pctBps <= 10_000, "badPct");
        // require(minSec <= maxSec && maxSec <= 30 days, "badRange");
        if (pctBps > 10_000) revert BadPct();
        if (minSec > maxSec || maxSec > 30 days) revert BadRange();
        closeBuf = CloseBufferCfg({ pctBps: pctBps, minSec: minSec, maxSec: maxSec });
        emit CloseBufferSet(pctBps, minSec, maxSec);
    }

    function setLateJoinParams(uint16 windowPctBps_, uint16 lateStartBps_, uint16 lateEndBps_) external onlyOwner {
        // require(windowPctBps_ <= 10_000, "badWin");
        // require(lateStartBps_ <= 10_000 && lateEndBps_ <= lateStartBps_, "badBps");
        if (windowPctBps_ > 10_000) revert BadWin();
        if (lateStartBps_ > 10_000 || lateEndBps_ > lateStartBps_) revert BadBps();
        lateWindowPctBps = windowPctBps_;
        lateStartWeightBps = lateStartBps_;
        lateEndWeightBps = lateEndBps_;
        emit LateJoinParamsSet(windowPctBps_, lateStartBps_, lateEndBps_);
    }

    function setAdapterAllowed(address adapter, bool allowed) external onlyOwner {
        // require(adapter != address(0), "badAdapter");
        if (adapter == address(0)) revert BadAdapter();
        allowedAdapter[adapter] = allowed;
        emit AdapterAllowedSet(adapter, allowed);
    }

    function setCapConfig(
        bool enabled,
        uint256 minE18,
        uint256 maxE18,
        uint256 kE18,
        uint256 fullAtRE18,
        uint8 policy
    ) external onlyOwner {
        require(minE18 >= 3e18, "min<3x");
        require(maxE18 <= 10e18 && maxE18 >= minE18, "badMax");
        require(kE18 >= 1e18 && kE18 <= 10_000e18, "badK");
        require(fullAtRE18 >= 1e18, "badFullAt");
        require(policy <= 1, "badPolicy");
        capEnabled    = enabled;
        capMinE18     = minE18;
        capMaxE18     = maxE18;
        capKE18       = kE18;
        capFullAtRE18 = fullAtRE18;
        surplusPolicy = policy;
        emit CapConfigSet(enabled, minE18, maxE18, kE18, fullAtRE18, policy);
    }

    function setSurplusSweepDelay(uint32 delaySec) external onlyOwner {
        require(delaySec >= 1 days && delaySec <= 365 days, "badDelay");
        surplusSweepDelay = delaySec;
        emit SurplusSweepDelaySet(delaySec);
    }

    function depositCredits() external payable {
        require(msg.value > 0, "zeroValue");
        ethCredits[msg.sender] += msg.value;
        emit CreditsDeposited(msg.sender, msg.value);
    }

    function withdrawCredits(uint256 amount) external nonReentrant {
        require(ethCredits[msg.sender] >= amount, "insufficient");
        ethCredits[msg.sender] -= amount;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "withdrawFail");
        emit CreditsWithdrawn(msg.sender, amount);
    }

    function emergencyShutdown() external onlyOwner {
        if (!shutdown) {
            shutdown = true;
            _pause();
            emit ShutdownSet(true);
        }
    }

    function clearShutdown() external onlyOwner {
        shutdown = false;
        emit ShutdownSet(false);
    }

    function adminVoid(uint256 marketId) external onlyOwner {
        if (marketStatus[marketId] == MarketStatus.Open) {
            marketStatus[marketId] = MarketStatus.Voided;
            emit MarketVoided(marketId);
        }
    }

    function adminVoidBatch(uint256[] calldata ids) external onlyOwner {
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 mid = ids[i];
            if (marketStatus[mid] == MarketStatus.Open) {
                marketStatus[mid] = MarketStatus.Voided;
                emit MarketVoided(mid);
            }
        }
    }

    function _compare(uint256 finalX18, uint256 strikeX18, uint8 comparator) internal pure returns (bool) {
        if (comparator == 1) return finalX18 <= strikeX18;
        if (comparator == 3) return finalX18 >= strikeX18;
        revert ComparatorNotAllowed();
    }

    function _checkAndBumpCreateLimits(address user) internal {
        CreateRate storage r = createRate[user];
        uint64 nowTs = uint64(block.timestamp);
        if (nowTs - r.windowStart >= createWindowSec) { r.windowStart = nowTs; r.count = 0; }
        if (r.count >= createMaxPerWindow) revert CreateRateLimit();
        unchecked { r.count += 1; }
    }

    function _closeBufferFor(uint48 dur) internal view returns (uint48) {
        uint256 pct = uint256(dur) * closeBuf.pctBps / 10_000;
        if (pct < closeBuf.minSec) pct = closeBuf.minSec;
        if (pct > closeBuf.maxSec) pct = closeBuf.maxSec;
        return uint48(pct);
    }

    function _gapE18(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 && b == 0) return 1e18;
        if (a == 0) a = 1;
        if (b == 0) b = 1;
        return a >= b ? Math.mulDiv(a, 1e18, b) : Math.mulDiv(b, 1e18, a);
    }

    // NOTE: This build uses the hyperbola cap only (no cubic/Hermite). No signed-basis risk here.
    function _capFromGapSmooth(uint256 gapE18) internal view returns (uint256) {
        if (!capEnabled) return type(uint256).max;
        if (gapE18 >= capFullAtRE18) return capMaxE18;
        uint256 delta = capMaxE18 - capMinE18;
        uint256 inc   = Math.mulDiv(delta, gapE18, gapE18 + capKE18);
        uint256 c     = capMinE18 + inc;
        return c > capMaxE18 ? capMaxE18 : c;
    }

    function joinCloseTime(uint256 marketId) public view returns (uint48) {
        Market storage m = markets[marketId];
        uint48 dur = m.endTs - m.startTs;
        return m.endTs - _closeBufferFor(dur);
    }

    function isLateJoin(uint256 marketId) public view returns (bool) {
        Market storage m = markets[marketId];
        uint48 dur = m.endTs - m.startTs;
        uint256 lateStart = uint256(m.startTs) + (uint256(dur) * lateWindowPctBps / 10_000);
        return block.timestamp >= lateStart && block.timestamp < m.endTs;
    }

    function lateJoinWeightBps(uint256 marketId) public view returns (uint16) {
        Market storage m = markets[marketId];
        uint48 dur = m.endTs - m.startTs;
        uint256 lateStart = uint256(m.startTs) + (uint256(dur) * lateWindowPctBps / 10_000);
        if (block.timestamp < lateStart) return 10_000;
        if (block.timestamp >= m.endTs) return 0;
        uint256 lateLen = uint256(m.endTs) - lateStart;
        if (lateLen == 0) return lateEndWeightBps;
        uint256 elapsed = uint256(block.timestamp) - lateStart;
        uint256 startBps = lateStartWeightBps;
        uint256 endBps   = lateEndWeightBps;
        uint256 decay = (startBps - endBps) * elapsed / lateLen;
        uint256 weight = startBps > decay ? (startBps - decay) : endBps;
        if (weight < endBps) weight = endBps;
        return uint16(weight);
    }

    function previewWeightBps(uint256 marketId, uint256 ts) public view returns (uint16) {
        Market storage m = markets[marketId];
        if (ts >= m.endTs) return 0;
        if (ts <= m.startTs) return 10_000;
        uint48 dur = m.endTs - m.startTs;
        uint256 lateStart = uint256(m.startTs) + (uint256(dur) * lateWindowPctBps / 10_000);
        if (ts < lateStart) return 10_000;
        uint256 lateLen = uint256(m.endTs) - lateStart;
        if (lateLen == 0) return lateEndWeightBps;
        uint256 elapsed = ts - lateStart;
        uint256 startBps = lateStartWeightBps;
        uint256 endBps   = lateEndWeightBps;
        uint256 decay = (startBps - endBps) * elapsed / lateLen;
        uint256 weight = startBps > decay ? (startBps - decay) : endBps;
        if (weight < endBps) weight = endBps;
        return uint16(weight);
    }

    modifier whenJoinOpen(uint256 marketId) {
        require(block.timestamp < joinCloseTime(marketId), "joinClosed");
        _;
    }

    function createMarket(
        bytes32 priceId,
        uint256 strikeX18,
        uint8 settleType,
        uint8 comparator,
        address stakeToken,
        address adapter,
        bytes calldata adapterData,
        uint48 endTs,
        uint256 creatorStakeInput
    ) external nonReentrant whenNotPaused returns (uint256 marketId) {
        require(!shutdown, "shutdown");
        if (comparator != 1 && comparator != 3) revert ComparatorNotAllowed();
        if (!allowedPriceId[priceId]) revert PriceIdNotAllowed();

        StakeTokenCfg memory cfg = stakeCfg[stakeToken];
        if (!cfg.allowCreate) revert StakeTokenNotAllowed();

        if (settleType != 2) {
            require(adapter != address(0), "adapterZero");
            require(allowedAdapter[adapter], "adapterNotAllowed");
            bool ok = IMemewarsSettlerAdapter(adapter).validateCreate(adapterData, priceId, stakeToken);
            require(ok, "adapterDenied");
        }

        uint48 start = uint48(block.timestamp);
        require(endTs > start, "badEnd");
        uint48 dur = endTs - start;
        if (dur < minDurSec || dur > maxDurSec) revert InvalidDuration();

        uint256 denom = 10 ** cfg.decimals;
        uint256 intendedX18 = creatorStakeInput.mulDiv(1e18, denom);
        if (intendedX18 < cfg.minX18) revert CreatorStakeTooLow();
        if (cfg.maxX18 != 0 && intendedX18 > cfg.maxX18) revert CreatorStakeTooHigh();

        _checkAndBumpCreateLimits(msg.sender);

        uint256 balBefore = IERC20(stakeToken).balanceOf(address(this));
        IERC20(stakeToken).safeTransferFrom(msg.sender, address(this), creatorStakeInput);
        uint256 received = IERC20(stakeToken).balanceOf(address(this)) - balBefore;
        if (received != creatorStakeInput) revert TransferInMismatch();

        marketId = ++nextMarketId;
        Market storage m = markets[marketId];
        m.creator      = msg.sender;
        m.priceId      = priceId;
        m.strikeX18    = strikeX18;
        m.comparator   = comparator;
        m.settleType   = settleType;
        m.startTs      = start;
        m.endTs        = endTs;
        m.stakeToken   = stakeToken;
        m.adapter      = adapter;
        m.adapterData  = adapterData;

        m.poolYes += received;
        m.weightYes += received;
        if (!joinedYes[marketId][msg.sender]) { joinedYes[marketId][msg.sender] = true; m.yesUserCount += 1; }
        uint256 pid = ++nextPositionId;
        positions[pid] = Position({ marketId: marketId, owner: msg.sender, side: 1, amount: received, weightBps: 10_000, claimed: false });
        userPositions[msg.sender].push(pid);

        emit MarketCreated(marketId, msg.sender, priceId, start, endTs, strikeX18, comparator, settleType, stakeToken, received, adapter);
    }

    function join(
        uint256 marketId,
        uint8 side,
        uint256 amount
    ) external nonReentrant whenNotPaused whenJoinOpen(marketId) {
        require(side <= 1, "badSide");
        require(amount > 0, "zeroAmount");
        Market storage m = markets[marketId];
        StakeTokenCfg memory cfg = stakeCfg[m.stakeToken];
        require(cfg.allowJoin, "joinDisabled");

        uint256 balBefore = IERC20(m.stakeToken).balanceOf(address(this));
        IERC20(m.stakeToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(m.stakeToken).balanceOf(address(this)) - balBefore;
        if (received != amount) revert TransferInMismatch();

        uint16 wBps = isLateJoin(marketId) ? lateJoinWeightBps(marketId) : 10_000;
        uint256 eff = received.mulDiv(wBps, 10_000);

        if (side == 1) {
            m.poolYes += received; m.weightYes += eff;
            if (!joinedYes[marketId][msg.sender]) { joinedYes[marketId][msg.sender] = true; m.yesUserCount += 1; }
        } else {
            m.poolNo  += received; m.weightNo  += eff;
            if (!joinedNo[marketId][msg.sender]) { joinedNo[marketId][msg.sender] = true; m.noUserCount  += 1; }
        }

        uint256 pid = ++nextPositionId;
        positions[pid] = Position({ marketId: marketId, owner: msg.sender, side: side, amount: received, weightBps: wBps, claimed: false });
        userPositions[msg.sender].push(pid);

        uint256 Y = m.poolYes; uint256 N = m.poolNo; uint256 den = Y + N; uint256 pYesNum;
        if (den == 0) { pYesNum = 1; den = 2; } else { pYesNum = Y; }

        emit Joined(marketId, msg.sender, side, received, wBps, Y, N, pYesNum, den);
    }

    function _winnerSide(uint256 marketId, uint256 finalX18) internal view returns (uint8) {
        Market storage m = markets[marketId];
        bool cond = _compare(finalX18, m.strikeX18, m.comparator);
        return cond ? 1 : 0;
    }

    function settle(uint256 marketId, bytes[] calldata priceUpdateData) external payable nonReentrant {
        require(marketStatus[marketId] == MarketStatus.Open, "notOpen");
        Market storage m = markets[marketId];
        require(block.timestamp >= m.endTs, "tooEarly");
        require(!shutdown, "shutdown");

        if (m.poolYes == 0 || m.poolNo == 0) {
            marketStatus[marketId] = MarketStatus.Voided;
            emit MarketVoided(marketId);
            return;
        }

        uint256 finalX18;
        uint64 pubTime;
        if (m.settleType == 2) {
            uint256 fee = pyth.getUpdateFee(priceUpdateData);
            uint256 payFromCredits = ethCredits[msg.sender] >= fee ? fee : ethCredits[msg.sender];
            if (payFromCredits > 0) ethCredits[msg.sender] -= payFromCredits;
            uint256 need = fee - payFromCredits;
            require(msg.value >= need, "feeTooLow");

            bytes32 [] memory priceIds = new bytes32 [] (1);
            priceIds[0] = m.priceId;

            PythStructs.PriceFeed[] memory feeds;
            uint64 minT = uint64(m.endTs);
            uint64 maxT1 = uint64(m.endTs) + uint64(SETTLE_DRIFT_SEC);

            try pyth.parsePriceFeedUpdates{ value: fee }(
                priceUpdateData,
                priceIds,
                minT,
                maxT1
            ) returns (PythStructs.PriceFeed[] memory f1) {
                feeds = f1;
            } catch {
                uint64 maxT2 = uint64(m.endTs) + uint64(SETTLE_DRIFT_SEC);
                feeds = pyth.parsePriceFeedUpdates{ value: fee }(
                    priceUpdateData,
                    priceIds,
                    minT,
                    maxT2
                );
            }

            require(feeds.length > 0, "noFeed");
            PythStructs.Price memory pr = feeds[0].price;
            require(pr.price > 0, "badPrice");
            pubTime = uint64(pr.publishTime);

            uint256 surplusETH = msg.value - need;
            if (surplusETH > 0) {
                ethCredits[msg.sender] += surplusETH;
                emit CreditsDeposited(msg.sender, surplusETH);
            }

            if (pr.expo < 0) {
                uint32 k = uint32(-pr.expo); require(k <= 36, "expoTooLarge");
                uint256 scaleDiv = 10 ** k;
                finalX18 = Math.mulDiv(uint64(pr.price), 1e18, scaleDiv);
            } else if (pr.expo > 0) {
                uint32 k2 = uint32(pr.expo); require(k2 <= 36, "expoTooLarge");
                uint256 scaleMul = 10 ** k2;
                uint256 base = Math.mulDiv(uint64(pr.price), 1e18, 1);
                require(base <= type(uint256).max / scaleMul, "priceOverflow");
                finalX18 = base * scaleMul;
            } else {
                finalX18 = uint64(pr.price) * 1e18;
            }
        } else {
            require(msg.value == 0, "noETHNeeded");
            require(m.adapter != address(0) && allowedAdapter[m.adapter], "adapterNotAllowed");
            (finalX18, pubTime) = IMemewarsSettlerAdapter(m.adapter).finalPriceX18(
                m.adapterData,
                m.priceId,
                m.startTs,
                m.endTs
            );
            require(pubTime >= m.endTs && pubTime <= m.endTs + uint64(MAX_SETTLE_DRIFT), "priceWindow");
        }

        uint8 w = _winnerSide(marketId, finalX18);
        uint256 loserPool = (w == 1) ? m.poolNo : m.poolYes;
        uint256 winnerWeight = (w == 1) ? m.weightYes : m.weightNo;

        uint256 effYes = m.weightYes;
        uint256 effNo  = m.weightNo;
        uint256 gapE18 = _gapE18(effYes, effNo);
        uint256 capE18 = _capFromGapSmooth(gapE18);

        uint256 rE18 = Math.mulDiv(loserPool, 1e18, winnerWeight);

        uint256 paidLoserPool = loserPool;
        uint256 surplus = 0;
        if (capE18 < type(uint256).max && rE18 > capE18) {
            paidLoserPool = Math.mulDiv(winnerWeight, capE18, 1e18);
            surplus = loserPool - paidLoserPool;
            if (surplus > 0 && surplusPolicy == 1) {
                IERC20(m.stakeToken).safeTransfer(feeReceiver, surplus);
            }
        }

        // Check if market can be settled
const marketData = await contract.markets(marketId);
const currentTime = Math.floor(Date.now() / 1000);
const canSettle = currentTime >= marketData.endTs;

// Check settlement state
const settlement = await contract.settlement(marketId);
const isSettled = settlement.settled;[marketId] = Settlement({
            settled: true,
            winnerSide: w,
            loserPoolSnapshot: paidLoserPool,
            winnerWeightSnapshot: winnerWeight,
            finalPriceX18: finalX18,
            publishTime: pubTime,
            loserPoolOrig: loserPool,
            surplusSnapshot: surplus,
            surplusRefunded: 0
        });
        marketStatus[marketId] = MarketStatus.Settled;

        emit MarketSettled(marketId, w, finalX18, uint256(pubTime), paidLoserPool, winnerWeight);
    }

    function _isOneSided(uint256 marketId) internal view returns (bool) {
        Market storage m = markets[marketId];
        return (m.poolYes == 0 || m.poolNo == 0);
    }

    function _claimOne(uint256 positionId, address to) private returns (uint256 paidOut) {
        Position storage p = positions[positionId];
        require(!p.claimed, "claimed");
        require(p.owner == to, "notOwner");

        MarketStatus st = marketStatus[p.marketId];

        if (st == MarketStatus.Open && block.timestamp >= joinCloseTime(p.marketId) && _isOneSided(p.marketId)) {
            marketStatus[p.marketId] = MarketStatus.Voided;
            emit MarketVoided(p.marketId);
            st = MarketStatus.Voided;
        }

        if (st == MarketStatus.Open && shutdown) {
            p.claimed = true;
            IERC20(markets[p.marketId].stakeToken).safeTransfer(to, p.amount);
            emit Claimed(positionId, to, p.amount);
            return p.amount;
        }

        Settlement storage s = settlement[p.marketId];

        if (st == MarketStatus.Voided) {
            p.claimed = true;
            IERC20(markets[p.marketId].stakeToken).safeTransfer(to, p.amount);
            emit Claimed(positionId, to, p.amount);
            return p.amount;
        }

        require(st == MarketStatus.Settled && s.settled, "notSettled");

        if (p.side != s.winnerSide) {
            uint256 refund = 0;
            if (surplusPolicy == 0 && s.surplusSnapshot != 0 && s.loserPoolOrig != 0) {
                refund = Math.mulDiv(s.surplusSnapshot, p.amount, s.loserPoolOrig);
                if (refund != 0) {
                    s.surplusRefunded += refund;
                    IERC20(markets[p.marketId].stakeToken).safeTransfer(to, refund);
                }
            }
            p.claimed = true;
            emit Claimed(positionId, to, refund);
            return refund;
        }

        uint256 posWeight = Math.mulDiv(p.amount, p.weightBps, 10_000);
        uint256 profitGross = Math.mulDiv(s.loserPoolSnapshot, posWeight, s.winnerWeightSnapshot);

        uint256 profitNet = profitGross;
        if (feeBps != 0 && feeReceiver != address(0)) {
            uint256 feeAmt = Math.mulDiv(profitGross, feeBps, 10_000);
            profitNet = profitGross - feeAmt;
            IERC20(markets[p.marketId].stakeToken).safeTransfer(feeReceiver, feeAmt);
            emit FeeCollected(positionId, feeAmt);
        }

        uint256 payout = p.amount + profitNet;
        p.claimed = true;
        IERC20(markets[p.marketId].stakeToken).safeTransfer(to, payout);
        emit Claimed(positionId, to, payout);
        return payout;
    }

    function claim(uint256 positionId) external nonReentrant {
        _claimOne(positionId, msg.sender);
    }

    function claimMany(uint256[] calldata positionIds) external nonReentrant {
        for (uint256 i = 0; i < positionIds.length; i++) {
            _claimOne(positionIds[i], msg.sender);
        }
    }

    function finalizeOneSided(uint256 marketId) external nonReentrant {
        require(marketStatus[marketId] == MarketStatus.Open, "notOpen");
        require(block.timestamp >= joinCloseTime(marketId), "joinOpen");
        require(_isOneSided(marketId), "twoSided");
        marketStatus[marketId] = MarketStatus.Voided;
        emit MarketVoided(marketId);
        emit OneSidedFinalized(marketId, msg.sender);
    }

    function sweepUnclaimedSurplus(uint256 marketId, address to) external onlyOwner nonReentrant {
        require(to != address(0), "badTo");
        require(marketStatus[marketId] == MarketStatus.Settled, "notSettled");
        Settlement storage s = settlement[marketId];
        require(s.surplusSnapshot > 0, "noSurplus");
        require(surplusPolicy == 0, "policyNotRefund");
        require(block.timestamp >= uint256(s.publishTime) + surplusSweepDelay, "delay");
        uint256 remaining = s.surplusSnapshot - s.surplusRefunded;
        require(remaining > 0, "noneLeft");
        s.surplusRefunded += remaining;
        IERC20(markets[marketId].stakeToken).safeTransfer(to, remaining);
        emit SurplusSwept(marketId, to, remaining);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function getMarket(uint256 marketId) external view returns (Market memory) { return markets[marketId]; }
    function isPriceIdAllowed(bytes32 id) external view returns (bool) { return allowedPriceId[id]; }

    function sideUserCounts(uint256 marketId) external view returns (uint256 yesCount, uint256 noCount) {
        Market storage m = markets[marketId];
        return (m.yesUserCount, m.noUserCount);
    }

    function userSides(uint256 marketId, address user) external view returns (bool joinedYesSide, bool joinedNoSide) {
        return (joinedYes[marketId][user], joinedNo[marketId][user]);
    }

    function previewOdds(uint256 marketId) external view returns (uint256 pYesNum, uint256 pDen) {
        Market storage m = markets[marketId];
        uint256 Y = m.poolYes;
        uint256 N = m.poolNo;
        uint256 den = Y + N;
        if (den == 0) { return (1, 2); }
        return (Y, den);
    }

    function previewOddsAfterJoin(uint256 marketId, uint8 side, uint256 amount) external view returns (uint256 pYesNum, uint256 pDen) {
        require(side <= 1, "badSide");
        Market storage m = markets[marketId];
        uint256 Y = m.poolYes;
        uint256 N = m.poolNo;
        if (amount != 0) {
            if (side == 1) { Y += amount; } else { N += amount; }
        }
        uint256 den = Y + N;
        if (den == 0) { return (1, 2); }
        return (Y, den);
    }

    function previewJoinImpact(
        uint256 marketId,
        uint8 side,
        uint256 amount,
        uint256 ts
    ) external view returns (
        uint256 pYesNum,
        uint256 pDen,
        uint16 weightBps,
        uint256 estimatedPosWeight
    ) {
        require(side <= 1, "badSide");
        Market storage m = markets[marketId];

        uint48 dur = m.endTs - m.startTs;
        uint48 closeAt = m.endTs - _closeBufferFor(dur);
        bool joinAllowed = (ts >= m.startTs) && (ts < closeAt);

        if (!joinAllowed) {
            weightBps = 0;
            estimatedPosWeight = 0;
        } else {
            uint256 lateStart = uint256(m.startTs) + (uint256(dur) * lateWindowPctBps / 10_000);
            if (ts < lateStart) {
                weightBps = 10_000;
            } else if (ts >= m.endTs) {
                weightBps = 0;
            } else {
                uint256 lateLen = uint256(m.endTs) - lateStart;
                if (lateLen == 0) {
                    weightBps = lateEndWeightBps;
                } else {
                    uint256 elapsed = ts - lateStart;
                    uint256 startBps = lateStartWeightBps;
                    uint256 endBps   = lateEndWeightBps;
                    uint256 decay = (startBps - endBps) * elapsed / lateLen;
                    uint256 w = startBps > decay ? (startBps - decay) : endBps;
                    if (w < endBps) w = endBps;
                    weightBps = uint16(w);
                }
            }
            estimatedPosWeight = Math.mulDiv(amount, weightBps, 10_000);
        }

        uint256 Y = m.poolYes;
        uint256 N = m.poolNo;
        if (amount != 0) {
            if (side == 1) { Y += amount; } else { N += amount; }
        }
        uint256 den = Y + N;
        if (den == 0) { return (1, 2, weightBps, estimatedPosWeight); }
        return (Y, den, weightBps, estimatedPosWeight);
    }

    function previewPayoutIfWin(
        uint256 marketId,
        uint8 side,
        uint256 amount,
        uint256 ts
    ) external view returns (
        uint256 payout,
        uint256 principal,
        uint256 profitGross,
        uint256 feeOnProfit,
        uint16  weightBps,
        uint256 estimatedPosWeight,
        uint256 winnerWeightAfter,
        uint256 loserPoolAfter
    ) {
        require(side <= 1, "badSide");
        Market storage m = markets[marketId];

        principal = amount;

        uint48 dur = m.endTs - m.startTs;
        uint48 closeAt = m.endTs - _closeBufferFor(dur);
        bool joinAllowed = (ts >= m.startTs) && (ts < closeAt);
        if (!joinAllowed || amount == 0) {
            return (0, principal, 0, 0, 0, 0, 0, 0);
        }

        uint256 lateStart = uint256(m.startTs) + (uint256(dur) * lateWindowPctBps / 10_000);
        if (ts < lateStart) {
            weightBps = 10_000;
        } else if (ts >= m.endTs) {
            weightBps = 0;
            return (0, principal, 0, 0, 0, 0, 0, 0);
        } else {
            uint256 lateLen = uint256(m.endTs) - lateStart;
            if (lateLen == 0) {
                weightBps = lateEndWeightBps;
            } else {
                uint256 elapsed = ts - lateStart;
                if (elapsed > lateLen) elapsed = lateLen;
                uint256 startBps = lateStartWeightBps;
                uint256 endBps   = lateEndWeightBps;
                uint256 decay = (startBps - endBps) * elapsed / lateLen;
                uint256 w = startBps > decay ? (startBps - decay) : endBps;
                if (w < endBps) w = endBps;
                weightBps = uint16(w);
            }
        }

        estimatedPosWeight = Math.mulDiv(amount, weightBps, 10_000);
        if (estimatedPosWeight == 0) {
            return (0, principal, 0, 0, weightBps, 0, 0, 0);
        }

        uint256 effYesAfter = m.weightYes + (side == 1 ? estimatedPosWeight : 0);
        uint256 effNoAfter  = m.weightNo  + (side == 0 ? estimatedPosWeight : 0);

        winnerWeightAfter = (side == 1 ? effYesAfter : effNoAfter);
        uint256 yesRawAfter = m.poolYes + (side == 1 ? amount : 0);
        uint256 noRawAfter  = m.poolNo  + (side == 0 ? amount : 0);
        loserPoolAfter = (side == 1) ? noRawAfter : yesRawAfter;

        if (winnerWeightAfter == 0) {
            return (0, principal, 0, 0, weightBps, estimatedPosWeight, 0, loserPoolAfter);
        }

        uint256 gapE18 = _gapE18(effYesAfter, effNoAfter);
        uint256 capE18 = _capFromGapSmooth(gapE18);

        uint256 rTheorE18 = Math.mulDiv(loserPoolAfter, 1e18, winnerWeightAfter);
        uint256 rUsedE18  = (capE18 < type(uint256).max && rTheorE18 > capE18) ? capE18 : rTheorE18;

        uint256 paidLoserPoolAfter = (rUsedE18 == rTheorE18)
            ? loserPoolAfter
            : Math.mulDiv(winnerWeightAfter, rUsedE18, 1e18);

        profitGross = Math.mulDiv(paidLoserPoolAfter, estimatedPosWeight, winnerWeightAfter);

        if (feeBps != 0 && feeReceiver != address(0)) {
            feeOnProfit = Math.mulDiv(profitGross, feeBps, 10_000);
        }
        payout = principal + (profitGross - feeOnProfit);
    }

    // === PATCH: viewer-parameterized preview for indexers/crawlers ===
    function _previewClaimFor(address viewer, uint256 positionId)
        internal
        view
        returns (bool claimable, uint256 payout, uint8 reasonCode)
    {
        Position storage p = positions[positionId];
        if (p.owner == address(0)) { return (false, 0, 4); }
        if (p.claimed) { return (false, 0, 3); }

        if (p.owner != viewer) { return (false, 0, 2); }

        MarketStatus st = marketStatus[p.marketId];

        bool canLazyVoid = (st == MarketStatus.Open && block.timestamp >= joinCloseTime(p.marketId) && _isOneSided(p.marketId));

        if (st == MarketStatus.Open) {
            if (shutdown) {
                return (true, p.amount, 1);
            }
            if (canLazyVoid) {
                return (true, p.amount, 1);
            }
            return (false, 0, 4);
        }

        if (st == MarketStatus.Voided) {
            return (true, p.amount, 1);
        }

        Settlement storage s = settlement[p.marketId];
        if (!s.settled) return (false, 0, 4);

        if (p.side != s.winnerSide) {
            uint256 refund = 0;
            if (surplusPolicy == 0 && s.surplusSnapshot != 0 && s.loserPoolOrig != 0) {
                refund = Math.mulDiv(s.surplusSnapshot, p.amount, s.loserPoolOrig);
            }
            return (refund != 0, refund, refund != 0 ? uint8(1) : uint8(5));
        }

        uint256 posWeight = Math.mulDiv(p.amount, p.weightBps, 10_000);
        if (s.winnerWeightSnapshot == 0) { return (false, 0, 4); }
        uint256 profitGross = Math.mulDiv(s.loserPoolSnapshot, posWeight, s.winnerWeightSnapshot);

        uint256 feeAmt = 0;
        if (feeBps != 0 && feeReceiver != address(0)) {
            feeAmt = Math.mulDiv(profitGross, feeBps, 10_000);
        }
        uint256 profitNet = profitGross - feeAmt;
        return (true, p.amount + profitNet, 0);
    }

    /// Existing interface preserved; uses msg.sender as viewer
    function previewClaim(uint256 positionId)
        external
        view
        returns (bool claimable, uint256 payout, uint8 reasonCode)
    {
        return _previewClaimFor(msg.sender, positionId);
    }

    /// New: indexers/crawlers can pass a viewer to avoid the msg.sender==owner guard
    function previewClaimFor(address viewer, uint256 positionId)
        external
        view
        returns (bool claimable, uint256 payout, uint8 reasonCode)
    {
        return _previewClaimFor(viewer, positionId);
    }
    // === END PATCH ===

    function exposureOf(address user, uint256 marketId)
        external
        view
        returns (uint256 yesAmount, uint256 noAmount, uint256 yesWeight, uint256 noWeight)
    {
        uint256[] storage arr = userPositions[user];
        for (uint256 i = 0; i < arr.length; i++) {
            Position storage p = positions[arr[i]];
            if (p.marketId != marketId || p.claimed) continue;
            uint256 eff = Math.mulDiv(p.amount, p.weightBps, 10_000);
            if (p.side == 1) { yesAmount += p.amount; yesWeight += eff; }
            else { noAmount += p.amount; noWeight += eff; }
        }
    }

    function getUserPositions(address user, uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256[] storage arr = userPositions[user];
        if (offset >= arr.length) return new uint256[](0);
        uint256 end = arr.length;
        if (limit != 0 && offset + limit < end) end = offset + limit;
        uint256 len = end - offset;
        ids = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            ids[i] = arr[offset + i];
        }
    }

    function getUserPositionsInMarket(
        address user,
        uint256 marketId,
        uint256 offset,
        uint256 limit,
        bool includeClaimed
    ) external view returns (uint256[] memory ids) {
        uint256[] storage arr = userPositions[user];
        if (offset > arr.length) return new uint256[](0);
        uint256 end = arr.length;
        if (limit != 0 && offset + limit < end) end = offset + limit;

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

    function finalSettlement(uint256 marketId) external view returns (bool settled_, uint8 winnerSide_, uint256 finalPriceX18_, uint64 publishTime_) {
        Settlement storage s = settlement[marketId];
        return (s.settled, s.winnerSide, s.finalPriceX18, s.publishTime);
    }

    receive() external payable {}
}
