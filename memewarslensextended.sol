// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/**
 * @title IMemewarsV2
 * @notice Minimal interface to interact with MemewarsV2 core contract.
 */
interface IMemewarsV2 {
    enum MarketStatus {
        Open,
        Settled,
        Voided
    }

    function marketStatus(uint256 marketId) external view returns (MarketStatus);

    function markets(uint256 marketId)
        external
        view
        returns (
            address creator,
            bytes32 priceId,
            uint256 strikeX18,
            uint8 comparator,
            uint8 settleType,
            uint48 startTs,
            uint48 endTs,
            address stakeToken,
            address adapter,
            bytes memory adapterData,
            uint256 poolYes,
            uint256 poolNo,
            uint256 weightYes,
            uint256 weightNo,
            uint32 yesUserCount,
            uint32 noUserCount
        );

    function stakeCfg(address token)
        external
        view
        returns (
            uint8 decimals,
            bool allowCreate,
            bool allowJoin,
            uint256 minX18,
            uint256 maxX18
        );

    function joinCloseTime(uint256 marketId) external view returns (uint48);

    function nextMarketId() external view returns (uint256);

}

/**
 * @title MemewarsLensExtended
 * @notice Extended lens helper that categorizes markets (open, closed, settled, voided)
 */
contract MemewarsLensExtended {
    IMemewarsV2 public immutable memewars;

    constructor(address _core) {
        require(_core != address(0), "invalid core");
        memewars = IMemewarsV2(_core);
    }

    struct MarketView {
        uint256 marketId;
        address creator;
        bytes32 priceId;
        address stakeToken;
        address adapter;
        uint48 startTs;
        uint48 endTs;
        uint256 strikeX18;
        uint256 poolYes;
        uint256 poolNo;
        uint256 weightYes;
        uint256 weightNo;
        uint32 yesUserCount;
        uint32 noUserCount;
        IMemewarsV2.MarketStatus status;
        uint8 stakeTokenDecimals;
        bool joinable;
        uint256 timeUntilEnd;
        uint256 timeUntilJoinClose;
    }

    // ============================================================
    //                   PUBLIC FILTERED VIEWS
    // ============================================================

    function getOpenMarkets(uint256 fromId, uint256 count)
        external
        view
        returns (MarketView[] memory)
    {
        return _getMarketsByStatus(fromId, count, IMemewarsV2.MarketStatus.Open);
    }

    function getSettledMarkets(uint256 fromId, uint256 count)
        external
        view
        returns (MarketView[] memory)
    {
        return _getMarketsByStatus(fromId, count, IMemewarsV2.MarketStatus.Settled);
    }

    function getVoidedMarkets(uint256 fromId, uint256 count)
        external
        view
        returns (MarketView[] memory)
    {
        return _getMarketsByStatus(fromId, count, IMemewarsV2.MarketStatus.Voided);
    }

    function getClosedMarkets(uint256 fromId, uint256 count)
        external
        view
        returns (MarketView[] memory)
    {
        MarketView[] memory temp = new MarketView[](count);
        uint256 found;

        for (uint256 id = fromId; ; ) {
            (bool ok, MarketView memory mv) = _getMarketView(id);
            if (ok && mv.status == IMemewarsV2.MarketStatus.Open && !mv.joinable) {
                temp[found] = mv;
                found++;
                if (found == count) break;
            }
            if (id == 0) break;
            unchecked {
                id--;
            }
        }

        if (found < count) {
            assembly ("memory-safe") {
                mstore(temp, found)
            }
        }

        return temp;
    }

    // ============================================================
    //                        INTERNAL CORE
    // ============================================================

    function _getMarketsByStatus(
        uint256 fromId,
        uint256 count,
        IMemewarsV2.MarketStatus filterStatus
    ) internal view returns (MarketView[] memory) {
        MarketView[] memory temp = new MarketView[](count);
        uint256 found;

        for (uint256 id = fromId; ; ) {
            (bool ok, MarketView memory mv) = _getMarketView(id);
            if (ok && mv.status == filterStatus) {
                temp[found] = mv;
                found++;
                if (found == count) break;
            }
            if (id == 0) break;
            unchecked {
                id--;
            }
        }

        if (found < count) {
            assembly ("memory-safe") {
                mstore(temp, found)
            }
        }

        return temp;
    }

    function _getMarketView(uint256 id)
        internal
        view
        returns (bool ok, MarketView memory mv)
    {
        IMemewarsV2.MarketStatus status;

        try memewars.marketStatus(id) returns (IMemewarsV2.MarketStatus s) {
            status = s;
        } catch {
            return (false, mv);
        }

        // All placeholders explicitly named to avoid parser error
        try memewars.markets(id) returns (
    address creator,
    bytes32 priceId,
    uint256 strikeX18,
    uint8, // _comparator (ignored)
    uint8, // _settleType (ignored)
    uint48 startTs,
    uint48 endTs,
    address stakeToken,
    address adapter,
    bytes memory, // _adapterData (ignored)
    uint256 poolYes,
    uint256 poolNo,
    uint256 weightYes,
    uint256 weightNo,
    uint32 yesUserCount,
    uint32 noUserCount
) { 
            uint48 joinClose = memewars.joinCloseTime(id);
            bool joinable = block.timestamp < joinClose;

            uint256 timeUntilEnd = block.timestamp < endTs ? endTs - block.timestamp : 0;
            uint256 timeUntilJoinClose =
                block.timestamp < joinClose ? joinClose - block.timestamp : 0;

            (uint8 decimals, , , , ) = memewars.stakeCfg(stakeToken);

            mv = MarketView({
                marketId: id,
                creator: creator,
                priceId: priceId,
                stakeToken: stakeToken,
                adapter: adapter,
                startTs: startTs,
                endTs: endTs,
                strikeX18: strikeX18,
                poolYes: poolYes,
                poolNo: poolNo,
                weightYes: weightYes,
                weightNo: weightNo,
                yesUserCount: yesUserCount,
                noUserCount: noUserCount,
                status: status,
                stakeTokenDecimals: decimals,
                joinable: joinable,
                timeUntilEnd: timeUntilEnd,
                timeUntilJoinClose: timeUntilJoinClose
            });

            return (true, mv);
        } catch {
            return (false, mv);
        }
    }
    function latestMarketId() external view returns (uint256) {
        return memewars.nextMarketId();
    }    
}
