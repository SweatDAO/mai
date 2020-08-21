/// EnglishCollateralAuctionHouse.sol

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.6.7;

abstract contract SAFEEngineLike {
    function transferInternalCoins(address,address,uint) virtual external;
    function transferCollateral(bytes32,address,address,uint) virtual external;
}
abstract contract OracleRelayerLike {
    function redemptionPrice() virtual public returns (uint256);
}
abstract contract OracleLike {
    function getResultWithValidity() virtual public returns (uint256, bool);
}

/*
   This thing lets you (English) auction some collateral for a given amount of system coins
*/

contract EnglishCollateralAuctionHouse {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "EnglishCollateralAuctionHouse/account-not-authorized");
        _;
    }

    // --- Data ---
    struct Bid {
        // Bid size (how many coins are offered per collateral sold)
        uint256 bidAmount;                                                                                            // [rad]
        // How much collateral is sold in an auction
        uint256 amountToSell;                                                                                         // [wad]
        // Who the high bidder is
        address highBidder;
        // When the latest bid expires and the auction can be settled
        uint48  bidExpiry;                                                                                            // [unix epoch time]
        // Hard deadline for the auction after which no more bids can be placed
        uint48  auctionDeadline;                                                                                      // [unix epoch time]
        // Who (which SAFE) receives leftover collateral that is not sold in the auction; usually the liquidated SAFE
        address forgoneCollateralReceiver;
        // Who receives the coins raised from the auction; usually the accounting engine
        address auctionIncomeRecipient;
        // Total/max amount of coins to raise
        uint256 amountToRaise;                                                                                        // [rad]
    }

    // Bid data for each separate auction
    mapping (uint => Bid) public bids;

    // SAFE database
    SAFEEngineLike public safeEngine;
    // Collateral type name
    bytes32       public collateralType;

    uint256  constant ONE = 1.00E18;                                                                                  // [wad]
    // Minimum bid increase compared to the last bid in order to take the new one in consideration
    uint256  public   bidIncrease = 1.05E18;                                                                          // [wad]
    // How long the auction lasts after a new bid is submitted
    uint48   public   bidDuration = 3 hours;                                                                          // [seconds]
    // Total length of the auction
    uint48   public   totalAuctionLength = 2 days;                                                                    // [seconds]
    // Number of auctions started up until now
    uint256  public   auctionsStarted = 0;
    // Minimum mandatory size of the first bid compared to collateral price coming from the oracle
      uint256  public bidToMarketPriceRatio;                                                                          // [ray]

    OracleRelayerLike public oracleRelayer;
    OracleLike        public osm;

    bytes32 public constant AUCTION_HOUSE_TYPE = bytes32("COLLATERAL");
    bytes32 public constant AUCTION_TYPE       = bytes32("ENGLISH");

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event StartAuction(
        uint256 id,
        uint256 auctionsStarted,
        uint256 amountToSell,
        uint256 initialBid,
        uint256 amountToRaise,
        address indexed forgoneCollateralReceiver,
        address indexed auctionIncomeRecipient,
        uint256 auctionDeadline
    );
    event ModifyParameters(bytes32 parameter, uint data);
    event ModifyParameters(bytes32 parameter, address data);
    event RestartAuction(uint id, uint256 auctionDeadline);
    event IncreaseBidSize(uint id, address highBidder, uint amountToBuy, uint rad, uint bidExpiry);
    event DecreaseSoldAmount(uint id, address highBidder, uint amountToBuy, uint rad, uint bidExpiry);
    event SettleAuction(uint id);
    event TerminateAuctionPrematurely(uint id, address sender, uint bidAmount, uint collateralAmount);

    // --- Init ---
    constructor(address safeEngine_, bytes32 collateralType_) public {
        safeEngine = SAFEEngineLike(safeEngine_);
        collateralType = collateralType_;
        authorizedAccounts[msg.sender] = 1;
        emit AddAuthorization(msg.sender);
    }

    // --- Math ---
    function addUint48(uint48 x, uint48 y) internal pure returns (uint48 z) {
        require((z = x + y) >= x);
    }
    function multiply(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    uint256 constant WAD = 10 ** 18;
    function wmultiply(uint x, uint y) internal pure returns (uint z) {
        z = multiply(x, y) / WAD;
    }
    uint256 constant RAY = 10 ** 27;
    function rdivide(uint x, uint y) internal pure returns (uint z) {
      z = multiply(x, RAY) / y;
    }

    // --- Admin ---
    /**
     * @notice Modify auction parameters
     * @param parameter The name of the parameter modified
     * @param data New value for the parameter
     */
    function modifyParameters(bytes32 parameter, uint data) external isAuthorized {
        if (parameter == "bidIncrease") bidIncrease = data;
        else if (parameter == "bidDuration") bidDuration = uint48(data);
        else if (parameter == "totalAuctionLength") totalAuctionLength = uint48(data);
        else if (parameter == "bidToMarketPriceRatio") bidToMarketPriceRatio = data;
        else revert("EnglishCollateralAuctionHouse/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }
    /**
     * @notice Modify oracle related integrations
     * @param parameter The name of the oracle contract modified
     * @param data New address for the oracle contract
     */
    function modifyParameters(bytes32 parameter, address data) external isAuthorized {
        if (parameter == "oracleRelayer") oracleRelayer = OracleRelayerLike(data);
        else if (parameter == "osm") osm = OracleLike(data);
        else revert("EnglishCollateralAuctionHouse/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }

    // --- Auction ---
    /**
     * @notice Start a new collateral auction
     * @param forgoneCollateralReceiver Who receives leftover collateral that is not auctioned
     * @param auctionIncomeRecipient Who receives the amount raised in the auction
     * @param amountToRaise Total amount of coins to raise (rad)
     * @param amountToSell Total amount of collateral available to sell (wad)
     * @param initialBid Initial bid size (usually zero in this implementation) (rad)
     */
    function startAuction(
        address forgoneCollateralReceiver,
        address auctionIncomeRecipient,
        uint amountToRaise,
        uint amountToSell,
        uint initialBid
    ) public isAuthorized returns (uint id)
    {
        require(auctionsStarted < uint(-1), "EnglishCollateralAuctionHouse/overflow");
        id = ++auctionsStarted;

        bids[id].bidAmount = initialBid;
        bids[id].amountToSell = amountToSell;
        bids[id].highBidder = msg.sender;
        bids[id].auctionDeadline = addUint48(uint48(now), totalAuctionLength);
        bids[id].forgoneCollateralReceiver = forgoneCollateralReceiver;
        bids[id].auctionIncomeRecipient = auctionIncomeRecipient;
        bids[id].amountToRaise = amountToRaise;

        safeEngine.transferCollateral(collateralType, msg.sender, address(this), amountToSell);

        emit StartAuction(
          id,
          auctionsStarted,
          amountToSell,
          initialBid,
          amountToRaise,
          forgoneCollateralReceiver,
          auctionIncomeRecipient,
          bids[id].auctionDeadline
        );
    }
    /**
     * @notice Restart an auction if no bids were submitted for it
     * @param id ID of the auction to restart
     */
    function restartAuction(uint id) external {
        require(bids[id].auctionDeadline < now, "EnglishCollateralAuctionHouse/not-finished");
        require(bids[id].bidExpiry == 0, "EnglishCollateralAuctionHouse/bid-already-placed");
        bids[id].auctionDeadline = addUint48(uint48(now), totalAuctionLength);
        emit RestartAuction(id, bids[id].auctionDeadline);
    }
    /**
     * @notice First auction phase: submit a higher bid for the same amount of collateral
     * @param id ID of the auction you want to submit the bid for
     * @param amountToBuy Amount of collateral to buy (wad)
     * @param rad New bid submitted (rad)
     */
    function increaseBidSize(uint id, uint amountToBuy, uint rad) external {
        require(bids[id].highBidder != address(0), "EnglishCollateralAuctionHouse/high-bidder-not-set");
        require(bids[id].bidExpiry > now || bids[id].bidExpiry == 0, "EnglishCollateralAuctionHouse/bid-already-expired");
        require(bids[id].auctionDeadline > now, "EnglishCollateralAuctionHouse/auction-already-expired");

        require(amountToBuy == bids[id].amountToSell, "EnglishCollateralAuctionHouse/amounts-not-matching");
        require(rad <= bids[id].amountToRaise, "EnglishCollateralAuctionHouse/higher-than-amount-to-raise");
        require(rad >  bids[id].bidAmount, "EnglishCollateralAuctionHouse/new-bid-not-higher");
        require(multiply(rad, ONE) >= multiply(bidIncrease, bids[id].bidAmount) || rad == bids[id].amountToRaise, "EnglishCollateralAuctionHouse/insufficient-increase");

        // check for first bid only
        if (bids[id].bidAmount == 0) {
            (uint256 priceFeedValue, bool hasValidValue) = osm.getResultWithValidity();
            if (hasValidValue) {
                uint256 redemptionPrice = oracleRelayer.redemptionPrice();
                require(rad >= multiply(wmultiply(rdivide(uint256(priceFeedValue), redemptionPrice), amountToBuy), bidToMarketPriceRatio), "EnglishCollateralAuctionHouse/first-bid-too-low");
            }
        }

        if (msg.sender != bids[id].highBidder) {
            safeEngine.transferInternalCoins(msg.sender, bids[id].highBidder, bids[id].bidAmount);
            bids[id].highBidder = msg.sender;
        }
        safeEngine.transferInternalCoins(msg.sender, bids[id].auctionIncomeRecipient, rad - bids[id].bidAmount);

        bids[id].bidAmount = rad;
        bids[id].bidExpiry = addUint48(uint48(now), bidDuration);

        emit IncreaseBidSize(id, msg.sender, amountToBuy, rad, bids[id].bidExpiry);
    }
    /**
     * @notice Second auction phase: decrease the collateral amount you're willing to receive in
     *         exchange for providing the same amount of coins as the winning bid
     * @param id ID of the auction for which you want to submit a new amount of collateral to buy
     * @param amountToBuy Amount of collateral to buy (must be smaller than the previous proposed amount) (wad)
     * @param rad New bid submitted; must be equal to the winning bid from the increaseBidSize phase (rad)
     */
    function decreaseSoldAmount(uint id, uint amountToBuy, uint rad) external {
        require(bids[id].highBidder != address(0), "EnglishCollateralAuctionHouse/high-bidder-not-set");
        require(bids[id].bidExpiry > now || bids[id].bidExpiry == 0, "EnglishCollateralAuctionHouse/bid-already-expired");
        require(bids[id].auctionDeadline > now, "EnglishCollateralAuctionHouse/auction-already-expired");

        require(rad == bids[id].bidAmount, "EnglishCollateralAuctionHouse/not-matching-bid");
        require(rad == bids[id].amountToRaise, "EnglishCollateralAuctionHouse/bid-increase-not-finished");
        require(amountToBuy < bids[id].amountToSell, "EnglishCollateralAuctionHouse/amount-bought-not-lower");
        require(multiply(bidIncrease, amountToBuy) <= multiply(bids[id].amountToSell, ONE), "EnglishCollateralAuctionHouse/insufficient-decrease");

        if (msg.sender != bids[id].highBidder) {
            safeEngine.transferInternalCoins(msg.sender, bids[id].highBidder, rad);
            bids[id].highBidder = msg.sender;
        }
        safeEngine.transferCollateral(
          collateralType,
          address(this),
          bids[id].forgoneCollateralReceiver,
          bids[id].amountToSell - amountToBuy
        );

        bids[id].amountToSell = amountToBuy;
        bids[id].bidExpiry    = addUint48(uint48(now), bidDuration);

        emit DecreaseSoldAmount(id, msg.sender, amountToBuy, rad, bids[id].bidExpiry);
    }
    /**
     * @notice Settle/finish an auction
     * @param id ID of the auction to settle
     */
    function settleAuction(uint id) external {
        require(bids[id].bidExpiry != 0 && (bids[id].bidExpiry < now || bids[id].auctionDeadline < now), "EnglishCollateralAuctionHouse/not-finished");
        safeEngine.transferCollateral(collateralType, address(this), bids[id].highBidder, bids[id].amountToSell);
        delete bids[id];
        emit SettleAuction(id);
    }
    /**
     * @notice Terminate an auction prematurely (if it's still in the first phase).
     *         Usually called by Global Settlement.
     * @param id ID of the auction to settle
     */
    function terminateAuctionPrematurely(uint id) external isAuthorized {
        require(bids[id].highBidder != address(0), "EnglishCollateralAuctionHouse/high-bidder-not-set");
        require(bids[id].bidAmount < bids[id].amountToRaise, "EnglishCollateralAuctionHouse/already-decreasing-sold-amount");
        safeEngine.transferCollateral(collateralType, address(this), msg.sender, bids[id].amountToSell);
        safeEngine.transferInternalCoins(msg.sender, bids[id].highBidder, bids[id].bidAmount);
        emit TerminateAuctionPrematurely(id, msg.sender, bids[id].bidAmount, bids[id].amountToSell);
        delete bids[id];
    }

    // --- Getters ---
    function bidAmount(uint id) public view returns (uint256) {
        return bids[id].bidAmount;
    }
    function remainingAmountToSell(uint id) public view returns (uint256) {
        return bids[id].amountToSell;
    }
    function forgoneCollateralReceiver(uint id) public view returns (address) {
        return bids[id].forgoneCollateralReceiver;
    }
    function amountToRaise(uint id) public view returns (uint256) {
        return bids[id].amountToRaise;
    }
}

/// FixedDiscountCollateralAuctionHouse.sol

// Copyright (C) 2020 Reflexer Labs, INC
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

/*
   This thing lets you sell some collateral at a fixed discount in order to instantly recapitalize the system
*/

contract FixedDiscountCollateralAuctionHouse {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "FixedDiscountCollateralAuctionHouse/account-not-authorized");
        _;
    }

    // --- Data ---
    struct Bid {
        // System coins raised up until now
        uint256 raisedAmount;                                                                                         // [rad]
        // Amount of collateral that has been sold up until now
        uint256 soldAmount;                                                                                           // [wad]
        // How much collateral is sold in an auction
        uint256 amountToSell;                                                                                         // [wad]
        // Total/max amount of coins to raise
        uint256 amountToRaise;                                                                                        // [rad]
        // Hard deadline for the auction after which no more bids can be placed
        uint48  auctionDeadline;                                                                                      // [unix epoch time]
        // Who (which SAFE) receives leftover collateral that is not sold in the auction; usually the liquidated SAFE
        address forgoneCollateralReceiver;
        // Who receives the coins raised from the auction; usually the accounting engine
        address auctionIncomeRecipient;
    }

    // Bid data for each separate auction
    mapping (uint => Bid) public bids;

    // SAFE database
    SAFEEngineLike public safeEngine;
    // Collateral type name
    bytes32       public collateralType;

    // Minimum acceptable bid
    uint256  public   minimumBid = 5 * WAD;                                                                           // [wad]
    // Total length of the auction
    uint48   public   totalAuctionLength = 7 days;                                                                    // [seconds]
    // Number of auctions started up until now
    uint256  public   auctionsStarted = 0;
    // Discount (compared to the system coin's current redemption price) at which collateral is being sold
    uint256  public   discount = 0.95E18;                         // 5% discount                                      // [wad]
    // Max lower bound deviation that the collateral median can have compared to the OSM price
    uint256  public   lowerCollateralMedianDeviation = 0.90E18;   // 10% deviation                                    // [wad]
    // Max upper bound deviation that the collateral median can have compared to the OSM price
    uint256  public   upperCollateralMedianDeviation = 0.95E18;   // 5% deviation                                     // [wad]
    // Max lower bound deviation that the system coin oracle price feed can have compared to the OSM price
    uint256  public   lowerSystemCoinMedianDeviation = WAD;       // 0% deviation                                     // [wad]
    // Max upper bound deviation that the collateral median can have compared to the OSM price
    uint256  public   upperSystemCoinMedianDeviation = WAD;       // 0% deviation                                     // [wad]
    // Min deviation for the system coin median result compared to the redemption price in order to take the median into account
    uint256  public   minSystemCoinMedianDeviation   = 0.999E18;                                                      // [wad]

    OracleRelayerLike public oracleRelayer;
    OracleLike        public collateralOSM;
    OracleLike        public collateralMedian;
    OracleLike        public systemCoinOracle;

    bytes32 public constant AUCTION_HOUSE_TYPE = bytes32("COLLATERAL");
    bytes32 public constant AUCTION_TYPE       = bytes32("FIXED_DISCOUNT");

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event StartAuction(
        uint256 id,
        uint256 auctionsStarted,
        uint256 amountToSell,
        uint256 initialBid,
        uint256 amountToRaise,
        address indexed forgoneCollateralReceiver,
        address indexed auctionIncomeRecipient,
        uint256 auctionDeadline
    );
    event ModifyParameters(bytes32 parameter, uint data);
    event ModifyParameters(bytes32 parameter, address data);
    event BuyCollateral(uint id, uint wad, uint boughtCollateral);
    event SettleAuction(uint id, uint leftoverCollateral);
    event TerminateAuctionPrematurely(uint id, address sender, uint collateralAmount);

    // --- Init ---
    constructor(address safeEngine_, bytes32 collateralType_) public {
        safeEngine = SAFEEngineLike(safeEngine_);
        collateralType = collateralType_;
        authorizedAccounts[msg.sender] = 1;
        emit AddAuthorization(msg.sender);
    }

    // --- Math ---
    uint256 constant RAD = 10 ** 45;
    function addUint48(uint48 x, uint48 y) internal pure returns (uint48 z) {
        require((z = x + y) >= x);
    }
    function addUint256(uint256 x, uint256 y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }
    function subtract(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function multiply(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    uint256 constant WAD = 10 ** 18;
    function wmultiply(uint x, uint y) internal pure returns (uint z) {
        z = multiply(x, y) / WAD;
    }
    uint256 constant RAY = 10 ** 27;
    function rdivide(uint x, uint y) internal pure returns (uint z) {
        z = multiply(x, RAY) / y;
    }
    function wdivide(uint x, uint y) internal pure returns (uint z) {
        z = multiply(x, WAD) / y;
    }
    function minimum(uint x, uint y) internal pure returns (uint z) {
        z = (x <= y) ? x : y;
    }
    function maximum(uint x, uint y) internal pure returns (uint z) {
        z = (x >= y) ? x : y;
    }

    // --- General Utils ---
    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- Admin ---
    /**
     * @notice Modify auction parameters
     * @param parameter The name of the parameter modified
     * @param data New value for the parameter
     */
    function modifyParameters(bytes32 parameter, uint data) external isAuthorized {
        if (parameter == "discount") {
            require(data < WAD, "FixedDiscountCollateralAuctionHouse/no-discount-offered");
            discount = data;
        }
        else if (parameter == "lowerCollateralMedianDeviation") {
            require(data <= WAD, "FixedDiscountCollateralAuctionHouse/invalid-lower-collateral-median-deviation");
            lowerCollateralMedianDeviation = data;
        }
        else if (parameter == "upperCollateralMedianDeviation") {
            require(data <= WAD, "FixedDiscountCollateralAuctionHouse/invalid-upper-collateral-median-deviation");
            upperCollateralMedianDeviation = data;
        }
        else if (parameter == "lowerSystemCoinMedianDeviation") {
            require(data <= WAD, "FixedDiscountCollateralAuctionHouse/invalid-lower-system-coin-median-deviation");
            lowerSystemCoinMedianDeviation = data;
        }
        else if (parameter == "upperSystemCoinMedianDeviation") {
            require(data <= WAD, "FixedDiscountCollateralAuctionHouse/invalid-upper-system-coin-median-deviation");
            upperSystemCoinMedianDeviation = data;
        }
        else if (parameter == "minSystemCoinMedianDeviation") {
            minSystemCoinMedianDeviation = data;
        }
        else if (parameter == "minimumBid") {
            minimumBid = data;
        }
        else if (parameter == "totalAuctionLength") {
            totalAuctionLength = uint48(data);
        }
        else revert("FixedDiscountCollateralAuctionHouse/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }
    /**
     * @notice Modify oracle related integrations
     * @param parameter The name of the contract address being updated
     * @param data New address for the oracle contract
     */
    function modifyParameters(bytes32 parameter, address data) external isAuthorized {
        if (parameter == "oracleRelayer") oracleRelayer = OracleRelayerLike(data);
        else if (parameter == "collateralOSM") collateralOSM = OracleLike(data);
        else if (parameter == "collateralMedian") collateralMedian = OracleLike(data);
        else if (parameter == "systemCoinOracle") systemCoinOracle = OracleLike(data);
        else revert("FixedDiscountCollateralAuctionHouse/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }

    // --- Auction Utils ---
    function getCollateralMedianPrice() private returns (uint256 priceFeed) {
        if (address(collateralMedian) == address(0)) return 0;

        // wrapped call toward the collateral median
        try collateralMedian.getResultWithValidity()
          returns (uint256 price, bool valid) {
          if (valid) {
            priceFeed = uint(price);
          }
        } catch (bytes memory revertReason) {}
    }
    function getSystemCoinPrice() private returns (uint256 priceFeed) {
        if (address(systemCoinOracle) == address(0)) return 0;

        // wrapped call toward the system coin oracle
        try systemCoinOracle.getResultWithValidity()
          returns (uint256 price, bool valid) {
          if (valid) {
            priceFeed = uint(price) * 10 ** 9; // scale to RAY
          }
        } catch (bytes memory revertReason) {}
    }
    function getSystemCoinFloorDeviatedPrice(uint256 redemptionPrice) private returns (uint256 floorPrice) {
        uint256 minFloorDeviatedPrice = wmultiply(redemptionPrice, minSystemCoinMedianDeviation);
        floorPrice = wmultiply(redemptionPrice, lowerSystemCoinMedianDeviation);
        floorPrice = (floorPrice <= minFloorDeviatedPrice) ? floorPrice : redemptionPrice;
    }
    function getSystemCoinCeilingDeviatedPrice(uint256 redemptionPrice) private returns (uint256 ceilingPrice) {
        uint256 minCeilingDeviatedPrice = wmultiply(redemptionPrice, subtract(2 * WAD, minSystemCoinMedianDeviation));
        ceilingPrice = wmultiply(redemptionPrice, subtract(2 * WAD, upperSystemCoinMedianDeviation));
        ceilingPrice = (ceilingPrice >= minCeilingDeviatedPrice) ? ceilingPrice : redemptionPrice;
    }
    function getTokenPrices() private returns (uint256, uint256) {
        (uint256 collateralOsmPriceFeedValue, bool collateralOsmHasValidValue) = collateralOSM.getResultWithValidity();
        if (!collateralOsmHasValidValue) {
          return (0, 0);
        }

        uint256 systemCoinAdjustedPrice = oracleRelayer.redemptionPrice();

        uint256 systemCoinPriceFeedValue = getSystemCoinPrice();
        if (systemCoinPriceFeedValue > 0) {
          uint256 floorPrice   = getSystemCoinFloorDeviatedPrice(systemCoinAdjustedPrice);
          uint256 ceilingPrice = getSystemCoinCeilingDeviatedPrice(systemCoinAdjustedPrice);

          if (uint(systemCoinPriceFeedValue) < systemCoinAdjustedPrice) {
            systemCoinAdjustedPrice = maximum(uint(systemCoinPriceFeedValue), floorPrice);
          } else {
            systemCoinAdjustedPrice = minimum(uint(systemCoinPriceFeedValue), ceilingPrice);
          }
        }

        return (uint(collateralOsmPriceFeedValue), systemCoinAdjustedPrice);
    }
    function getFinalBaseCollateralPrice(
        uint256 collateralOSMPriceFeedValue,
        uint256 collateralMedianPriceFeedValue
    ) private view returns (uint256) {
        uint256 floorPrice   = wmultiply(collateralOSMPriceFeedValue, lowerCollateralMedianDeviation);
        uint256 ceilingPrice = wmultiply(collateralOSMPriceFeedValue, subtract(2 * WAD, upperCollateralMedianDeviation));

        uint256 adjustedMedianPrice = (collateralMedianPriceFeedValue == 0) ?
          collateralOSMPriceFeedValue : collateralMedianPriceFeedValue;

        if (adjustedMedianPrice < collateralOSMPriceFeedValue) {
          return maximum(adjustedMedianPrice, floorPrice);
        } else {
          return minimum(adjustedMedianPrice, ceilingPrice);
        }
    }
    function getDiscountedCollateralPrice(
        uint256 collateralOSMPriceFeedValue,
        uint256 collateralMedianPriceFeedValue,
        uint256 systemCoinPriceFeedValue,
        uint256 customDiscount
    ) public returns (uint256) {
        // calculate the collateral price in relation to the latest system coin redemption price and apply the discount
        return wmultiply(
          rdivide(getFinalBaseCollateralPrice(collateralOSMPriceFeedValue, collateralMedianPriceFeedValue), systemCoinPriceFeedValue),
          customDiscount
        );
    }
    function getBoughtCollateral(
        uint id,
        uint256 collateralOSMPriceFeedValue,
        uint256 collateralMedianPriceFeedValue,
        uint256 systemCoinPriceFeedValue,
        uint256 adjustedBid
    ) private returns (uint256) {
        // calculate the collateral price in relation to the latest system coin redemption price and apply the discount
        uint256 discountedRedemptionCollateralPrice =
          getDiscountedCollateralPrice(
            collateralOSMPriceFeedValue,
            collateralMedianPriceFeedValue,
            systemCoinPriceFeedValue,
            discount
          );
        // calculate the amount of collateral bought
        uint256 boughtCollateral = wdivide(adjustedBid, discountedRedemptionCollateralPrice);
        // if the calculated collateral amount exceeds the amount still up for sale, adjust it to the remaining amount
        boughtCollateral = (boughtCollateral > subtract(bids[id].amountToSell, bids[id].soldAmount)) ?
                           subtract(bids[id].amountToSell, bids[id].soldAmount) : boughtCollateral;

        return boughtCollateral;
    }

    // --- Core Auction Logic ---
    /**
     * @notice Start a new collateral auction
     * @param forgoneCollateralReceiver Who receives leftover collateral that is not auctioned
     * @param auctionIncomeRecipient Who receives the amount raised in the auction
     * @param amountToRaise Total amount of coins to raise (rad)
     * @param amountToSell Total amount of collateral available to sell (wad)
     * @param initialBid Unused
     */
    function startAuction(
        address forgoneCollateralReceiver,
        address auctionIncomeRecipient,
        uint256 amountToRaise,
        uint256 amountToSell,
        uint256 initialBid
    ) public isAuthorized returns (uint id) {
        require(auctionsStarted < uint(-1), "FixedDiscountCollateralAuctionHouse/overflow");
        require(amountToSell > 0, "FixedDiscountCollateralAuctionHouse/no-collateral-for-sale");
        require(amountToRaise > 0, "FixedDiscountCollateralAuctionHouse/nothing-to-raise");
        require(amountToRaise >= RAY, "FixedDiscountCollateralAuctionHouse/dusty-auction");
        id = ++auctionsStarted;

        bids[id].auctionDeadline = addUint48(uint48(now), uint48(totalAuctionLength));
        bids[id].amountToSell = amountToSell;
        bids[id].forgoneCollateralReceiver = forgoneCollateralReceiver;
        bids[id].auctionIncomeRecipient = auctionIncomeRecipient;
        bids[id].amountToRaise = amountToRaise;

        safeEngine.transferCollateral(collateralType, msg.sender, address(this), amountToSell);

        emit StartAuction(
          id,
          auctionsStarted,
          amountToSell,
          initialBid,
          amountToRaise,
          forgoneCollateralReceiver,
          auctionIncomeRecipient,
          bids[id].auctionDeadline
        );
    }
    /**
     * @notice Calculate how much collateral someone would buy from an auction
     * @param id ID of the auction to buy collateral from
     * @param wad New bid submitted
     */
    function getCollateralBought(uint id, uint wad) external returns (uint256) {
        if (either(
          either(bids[id].amountToSell == 0, bids[id].amountToRaise == 0),
          wad == 0
        )) {
          return 0;
        }

	      uint256 remainingToRaise = subtract(bids[id].amountToRaise, bids[id].raisedAmount);

        // bound max amount offered in exchange for collateral
        uint256 adjustedBid = wad;
        if (multiply(adjustedBid, RAY) > remainingToRaise) {
            adjustedBid = remainingToRaise / RAY;
        }

      	uint256 totalRaised = addUint256(bids[id].raisedAmount, multiply(adjustedBid, RAY));
      	remainingToRaise    = subtract(bids[id].amountToRaise, bids[id].raisedAmount);
      	if (both(remainingToRaise > 0, remainingToRaise < RAY)) {
      	    return 0;
      	}

        // check that the oracle doesn't return an invalid value
        (uint256 collateralOsmPriceFeedValue, uint256 systemCoinPriceFeedValue) = getTokenPrices();
        if (collateralOsmPriceFeedValue == 0) {
          return 0;
        }

        return getBoughtCollateral(
          id,
          collateralOsmPriceFeedValue,
          getCollateralMedianPrice(),
          systemCoinPriceFeedValue,
          adjustedBid
        );
    }
    /**
     * @notice Buy collateral from an auction at a fixed discount
     * @param id ID of the auction to buy collateral from
     * @param wad New bid submitted
     */
    function buyCollateral(uint id, uint wad) external {
        require(both(bids[id].amountToSell > 0, bids[id].amountToRaise > 0), "FixedDiscountCollateralAuctionHouse/inexistent-auction");
        require(both(wad > 0, wad >= minimumBid), "FixedDiscountCollateralAuctionHouse/invalid-bid");

        uint256 remainingToRaise = subtract(bids[id].amountToRaise, bids[id].raisedAmount);

        // bound max amount offered in exchange for collateral
        uint256 adjustedBid = wad;
        if (multiply(adjustedBid, RAY) > remainingToRaise) {
            adjustedBid = addUint256(remainingToRaise / RAY, WAD);
        }

        // update amount raised
        bids[id].raisedAmount = addUint256(bids[id].raisedAmount, multiply(adjustedBid, RAY));

        // check that the collateral osm doesn't return an invalid value
        (uint256 collateralOsmPriceFeedValue, uint256 systemCoinPriceFeedValue) = getTokenPrices();
        require(collateralOsmPriceFeedValue > 0, "FixedDiscountCollateralAuctionHouse/collateral-osm-invalid-value");

        // get the amount of collateral bought
        uint256 boughtCollateral = getBoughtCollateral(
          id, collateralOsmPriceFeedValue, getCollateralMedianPrice(), systemCoinPriceFeedValue, adjustedBid
        );
        // check that the calculated amount is greater than zero
        require(boughtCollateral > 0, "FixedDiscountCollateralAuctionHouse/null-bought-amount");
        // update the amount of collateral already sold
        bids[id].soldAmount = addUint256(bids[id].soldAmount, boughtCollateral);

        // transfer the bid to the income recipient and the collateral to the bidder
        safeEngine.transferInternalCoins(msg.sender, bids[id].auctionIncomeRecipient, multiply(adjustedBid, RAY));
        safeEngine.transferCollateral(collateralType, address(this), msg.sender, boughtCollateral);

        // if the auction raised the whole amount, all collateral was sold or the auction expired,
        // send remaining collateral back to the forgone receiver
        bool deadlinePassed = bids[id].auctionDeadline < now;
        bool soldAll        = either(bids[id].amountToRaise <= bids[id].raisedAmount, bids[id].amountToSell == bids[id].soldAmount);
        if (either(deadlinePassed, soldAll)) {
            uint256 leftoverCollateral = subtract(bids[id].amountToSell, bids[id].soldAmount);
            safeEngine.transferCollateral(collateralType, address(this), bids[id].forgoneCollateralReceiver, leftoverCollateral);
            delete bids[id];
            emit SettleAuction(id, leftoverCollateral);
        }

        emit BuyCollateral(id, wad, boughtCollateral);
    }
    /**
     * @notice Settle/finish an auction
     * @param id ID of the auction to settle
     */
    function settleAuction(uint id) external {
        require(both(
          both(bids[id].amountToSell > 0, bids[id].amountToRaise > 0),
          bids[id].auctionDeadline < now
        ), "FixedDiscountCollateralAuctionHouse/not-finished");
        uint256 leftoverCollateral = subtract(bids[id].amountToSell, bids[id].soldAmount);
        safeEngine.transferCollateral(collateralType, address(this), bids[id].forgoneCollateralReceiver, leftoverCollateral);
        delete bids[id];
        emit SettleAuction(id, leftoverCollateral);
    }
    /**
     * @notice Terminate an auction prematurely. Usually called by Global Settlement.
     * @param id ID of the auction to settle
     */
    function terminateAuctionPrematurely(uint id) external isAuthorized {
        require(both(bids[id].amountToSell > 0, bids[id].amountToRaise > 0), "FixedDiscountCollateralAuctionHouse/inexistent-auction");
        uint256 leftoverCollateral = subtract(bids[id].amountToSell, bids[id].soldAmount);
        safeEngine.transferCollateral(collateralType, address(this), msg.sender, subtract(bids[id].amountToSell, bids[id].soldAmount));
        delete bids[id];
        emit TerminateAuctionPrematurely(id, msg.sender, leftoverCollateral);
    }

    // --- Getters ---
    function bidAmount(uint id) public view returns (uint256) {
        return 0;
    }
    function remainingAmountToSell(uint id) public view returns (uint256) {
        return subtract(bids[id].amountToSell, bids[id].soldAmount);
    }
    function forgoneCollateralReceiver(uint id) public view returns (address) {
        return bids[id].forgoneCollateralReceiver;
    }
    function amountToRaise(uint id) public view returns (uint256) {
        return bids[id].amountToRaise;
    }
}
