# MemeWars V2 Smart Contract Documentation

## Version
2.0.3

## Overview

MemeWars V2 is a decentralized prediction market platform built on the Monad blockchain. It allows users to create and participate in markets based on cryptocurrency price movements, with a focus on meme coins. The contract enables binary outcome markets (Yes/No) where users can stake tokens on their predictions and earn rewards based on the final outcome.

## Key Features

- **Binary Prediction Markets**: Create markets with Yes/No outcomes based on price movements
- **Multiple Price Feeds**: Support for various cryptocurrency price feeds via Pyth Network
- **Flexible Settlement Types**: Different ways to determine market winners
- **Stake Token Configuration**: Support for different ERC20 tokens as stake
- **Rate Limiting**: Prevents spam by limiting market creation (configurable window and max markets per window)
- **Late Join Mechanics**: Allows users to join markets after they've started with adjusted weights
- **Fee System**: Configurable fee structure for platform sustainability (up to 4% max)
- **Dynamic Weighting**: Position weights adjust based on when users join a market
- **Surplus Management**: Configurable policies for handling surplus funds
- **ETH Credits**: Users can deposit ETH to cover gas costs for Pyth price updates

## Contract Components

### Market Structure

Markets in MemeWars V2 have the following properties:

- **Creator**: Address that created the market
- **Price ID**: Pyth Network price feed identifier
- **Strike Price**: Target price for the prediction
- **Comparator**: How the final price is compared to the strike (e.g., greater than, less than)
- **Settlement Type**: Method used to determine the winner
- **Time Window**: Start and end timestamps for the market
- **Stake Token**: ERC20 token used for staking in this market
- **Pools**: Separate pools for Yes and No positions

### Position Structure

When users join a market, they receive a position with:

- **Market ID**: Reference to the specific market
- **Owner**: Address of the position holder
- **Side**: Yes (0) or No (1)
- **Amount**: Amount of stake tokens
- **Weight**: Adjusted weight based on when they joined
- **Claimed**: Whether rewards have been claimed

## Key Functions

### For Market Creators

- `createMarket`: Create a new prediction market with specified parameters

### For Market Participants

- `join`: Stake tokens on a prediction (Yes or No)
- `claim`: Claim rewards after market settlement

### For Contract Owner

- `setFee`: Configure platform fee percentage and receiver
- `setDurations`: Set minimum and maximum market durations
- `setPriceIdAllowed`: Whitelist price feeds
- `setStakeToken`: Configure tokens that can be used for staking
- `setCreateRateLimits`: Adjust market creation rate limits
- `pause`/`unpause`: Emergency controls

## Market Lifecycle

1. **Creation**: A user creates a market with specific parameters
2. **Participation**: Users join by staking tokens on Yes or No outcomes
3. **Settlement**: After the end time, the market is settled based on the final price
4. **Claims**: Winners can claim their rewards

## Market Creation Parameters

When creating a market, the following parameters are required:

- **priceId** (bytes32): Pyth Network price feed identifier (must be whitelisted)
- **strikeX18** (uint256): Target price with 18 decimal places
- **comparator** (uint8): How to compare final price to strike
  - 0: Equal to
  - 1: Not equal to
  - 2: Less than
  - 3: Greater than
  - 4: Less than or equal to
  - 5: Greater than or equal to
- **settleType** (uint8): Method to determine settlement price
  - 0: Price at exact end time
  - 1: Time-weighted average price (TWAP)
  - 2: Custom settlement via adapter
- **endTs** (uint48): End timestamp for the market
- **stakeToken** (address): ERC20 token used for staking (must be whitelisted)
- **creatorStake** (uint256): Initial stake amount from creator
- **adapter** (address): Optional adapter for custom settlement logic
- **adapterData** (bytes): Optional data for the adapter

## Usage Examples

### Creating a Market

```solidity
// Example: Create a market for DOGE/USD > $0.35 in 48 hours
bytes32 priceId = 0x41f3625971ca2ed2263e78573fe5ce23e13d2558ed3f2e47ab0f84fb9e7ae722; // DOGE/USD
uint256 strikeX18 = 0.35 * 10**18; // $0.35 with 18 decimals
uint8 comparator = 3; // Greater than
uint8 settleType = 0; // Price at exact end time
uint48 endTs = uint48(block.timestamp + 48 hours);
address stakeToken = 0x0000000000000000000000000000000000000000; // Native MON token
uint256 creatorStake = 150 * 10**18; // 150 MON
address adapter = address(0); // No custom adapter
bytes memory adapterData = ""; // No adapter data

// Approve token spending first
IERC20(stakeToken).approve(memewarsAddress, creatorStake);

// Create the market
MemewarsV2(memewarsAddress).createMarket(
    priceId,
    strikeX18,
    comparator,
    settleType,
    endTs,
    stakeToken,
    creatorStake,
    adapter,
    adapterData
);
```

### Joining a Market

```solidity
// Example: Join market #11 on the YES side with 100 MON
uint256 marketId = 11;
uint8 side = 0; // 0 for YES, 1 for NO
uint256 amount = 100 * 10**18; // 100 MON

// Get market info to determine stake token
MemewarsV2.Market memory market = MemewarsV2(memewarsAddress).markets(marketId);

// Approve token spending first
IERC20(market.stakeToken).approve(memewarsAddress, amount);

// Join the market
MemewarsV2(memewarsAddress).join(marketId, side, amount);
```

### Settling a Market

```solidity
// Example: Settle market #11 with Pyth price update data
uint256 marketId = 11;
bytes[] memory priceUpdateData = getPythPriceUpdateData(); // Get from Pyth API

// Settle the market
MemewarsV2(memewarsAddress).settle(marketId, priceUpdateData);
```

### Claiming Rewards

```solidity
// Example: Claim rewards for position #42
uint256 positionId = 42;

// Claim rewards
MemewarsV2(memewarsAddress).claim(positionId);
```

### Checking Market Status

```solidity
// Example: Check if market #11 is settled and who won
uint256 marketId = 11;

// Get market status
MemewarsV2.MarketStatus status = MemewarsV2(memewarsAddress).marketStatus(marketId);

if (status == MemewarsV2.MarketStatus.Settled) {
    // Get settlement details
    MemewarsV2.Settlement memory s = MemewarsV2(memewarsAddress).settlement(marketId);
    
    // s.winnerSide will be 0 for YES or 1 for NO
    string memory winner = s.winnerSide == 0 ? "YES" : "NO";
    console.log("Market %s was won by %s side", marketId, winner);
    console.log("Final price: %s", s.finalPriceX18);
}
```

## Error Handling

The contract uses custom errors for better gas efficiency and clearer error messages:

- `PriceIdNotAllowed`: Attempted to use an unsupported price feed
- `StakeTokenNotAllowed`: Attempted to use an unsupported stake token
- `CreatorStakeTooLow`/`CreatorStakeTooHigh`: Creator stake outside allowed range
- `CreateRateLimit`: Too many markets created in the time window
- And many others for specific validation failures

## Integration with External Systems

- **Pyth Network**: Used for reliable price feed data
- **Settlement Adapters**: Optional external contracts for custom settlement logic

## Security Features

- **ReentrancyGuard**: Prevents reentrant attacks
- **Pausable**: Emergency pause functionality
- **Ownable**: Access control for administrative functions
- **SafeERC20**: Safe token transfer handling

## Contract Deployment

**Contract Address**: `0xb1433b662669f59de53f96c2959b542a57bbb204`

The MemeWars V2 contract requires two parameters during deployment:

```solidity
constructor(address pythContract, address treasury) Ownable(msg.sender) {
    require(pythContract != address(0), "badPyth");
    require(treasury != address(0), "badTreasury");
    pyth = IPyth(pythContract);
    feeBps = 0;
    feeReceiver = treasury;
}
```

- **pythContract**: Address of the Pyth Network contract on the target chain
- **treasury**: Address that will receive platform fees

## Frontend Integration

When integrating with a frontend application:

1. **Contract ABI**: Use the provided `contract_ABI.json` file for interface definitions
2. **Price IDs**: Reference the Pyth Network documentation for available price feeds
3. **Error Handling**: Implement proper error handling for all custom errors
4. **Gas Considerations**: 
   - Market creation and settlement may require significant gas
   - Consider using ETH credits for Pyth price updates

## Rate Limits

Be aware of the following rate limits when interacting with the contract:

- Market creation is limited to `createMaxPerWindow` markets per `createWindowSec` time window per address
- Default values: 3 markets per 24 hours

## License

MIT License