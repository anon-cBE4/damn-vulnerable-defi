// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {SafeProxy} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxy.sol";
import {Safe} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {
    SAFE_SINGLETON_FACTORY_DEPLOYMENT_SIGNER,
    SAFE_SINGLETON_FACTORY_DEPLOYMENT_TX,
    SAFE_SINGLETON_FACTORY_ADDRESS,
    SAFE_SINGLETON_FACTORY_CODE
} from "./SafeSingletonFactory.sol";

contract NonceFinder is Test {
    SafeProxyFactory proxyFactory;
    Safe singletonCopy;
    address user;
    address constant TARGET_ADDRESS = 0xCe07CF30B540Bb84ceC5dA5547e1cb4722F9E496;

    function setUp() public {
        (user, ) = makeAddrAndKey("user");
        
        // 1. Deploy Safe Singleton Factory (Simulated)
        // In a real environment we'd broadcast the tx, but here we can just etch code or deploy
        vm.etch(SAFE_SINGLETON_FACTORY_ADDRESS, SAFE_SINGLETON_FACTORY_CODE);
        
        // 2. Deploy Safe Proxy Factory
        (bool success, bytes memory returndata) =
            address(SAFE_SINGLETON_FACTORY_ADDRESS).call(bytes.concat(bytes32(""), type(SafeProxyFactory).creationCode));
        proxyFactory = SafeProxyFactory(address(uint160(bytes20(returndata))));
        
        // 3. Deploy Safe Singleton
        (success, returndata) =
            address(SAFE_SINGLETON_FACTORY_ADDRESS).call(bytes.concat(bytes32(""), type(Safe).creationCode));
        singletonCopy = Safe(payable(address(uint160(bytes20(returndata)))));
    }

    function test_findNonce() public {
        address[] memory owners = new address[](1);
        owners[0] = user;
        
        bytes memory initializer = abi.encodeWithSelector(
            Safe.setup.selector,
            owners,
            1,          // threshold
            address(0), // to
            "",         // data
            address(0), // fallbackHandler
            address(0), // paymentToken
            0,          // payment
            address(0)  // paymentReceiver
        );

        // Loop to find nonce
        for (uint256 i = 0; i < 100; i++) {
            // Calculate salt as done in SafeProxyFactory.createProxyWithNonce
            bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), i));
            
            // Calculate CREATE2 address
            address predicted = address(uint160(uint256(keccak256(abi.encodePacked(
                bytes1(0xff),
                address(proxyFactory),
                salt,
                keccak256(abi.encodePacked(type(SafeProxy).creationCode, uint256(uint160(address(singletonCopy)))))
            )))));

            if (predicted == TARGET_ADDRESS) {
                console.log("FOUND NONCE:", i);
                return;
            }
        }
        console.log("Nonce not found in first 100");
    }
}
