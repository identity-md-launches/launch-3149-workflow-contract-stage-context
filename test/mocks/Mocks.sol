// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketTypes as T} from "../../src/libraries/MarketTypes.sol";
import {IOracleIntake} from "../../src/interfaces/IOracleIntake.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {IBoundaryProofVerifier} from "../../src/interfaces/IBoundaryProofVerifier.sol";

/// @dev Minimal ERC-20 with a mint hook; etched at the fixed mainnet token addresses in tests.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    /// @dev When nonzero, transfers deliver amount minus this many basis points (fee-on-transfer mock).
    uint256 public feeBps;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function init(string memory n, string memory s, uint8 d) external {
        name = n;
        symbol = s;
        decimals = d;
    }

    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        uint256 fee = amount * feeBps / 10000;
        balanceOf[to] += amount - fee;
        if (fee != 0) totalSupply -= fee;
        emit Transfer(from, to, amount - fee);
    }
}

/// @dev Stands in for the fixed BoundaryProofVerifier: returns a configured price or reverts.
contract MockVerifier {
    uint256 public answer;
    bool public shouldRevert;

    function set(uint256 a, bool r) external {
        answer = a;
        shouldRevert = r;
    }

    function verify(uint64, T.Asset calldata, IBoundaryProofVerifier.BlockProof[3] calldata)
        external
        view
        returns (uint256)
    {
        require(!shouldRevert, "bad proof");
        return answer;
    }
}

/// @dev Stands in for the IMD oracle INTAKE: quotes a price per question, records requests, pulls the fee.
contract MockIntake {
    uint256 public quoted;
    bool public refuse;
    uint256 public count;
    bytes32[] public ids;
    bytes[] public bodies;
    address public lastAsset;
    uint256 public lastAmount;
    uint256 public pulled;

    function configure(uint256 q, bool r) external {
        quoted = q;
        refuse = r;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return quoted;
    }

    function requestWithFailure(
        bytes32,
        bytes calldata body,
        IOracleIntake.Callback calldata,
        bytes4,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 id) {
        require(!refuse, "intake refused");
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        pulled += amount;
        lastAsset = asset;
        lastAmount = amount;
        id = keccak256(abi.encode(address(this), ++count, body));
        ids.push(id);
        bodies.push(body);
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }
}

/// @dev Etched at the fixed SIGNER address: an ERC-1271 wallet that accepts a configured digest set.
contract MockSigner {
    mapping(bytes32 => bool) public accepted;

    function accept(bytes32 digest) external {
        accepted[digest] = true;
    }

    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return accepted[hash] ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @dev Stands in for the Uniswap v4 PoolManager: constant-rate exact-output swaps per pool, settled
/// through sync/settle/take with real token movements and optional liquidity caps.
contract MockPoolManager {
    // currency0 units per 1e18 currency1 units for each pool id (a price, not a curve).
    mapping(bytes32 => uint256) public rate0Per1;
    mapping(bytes32 => uint256) public maxOut;
    address private synced;
    uint256 private syncedBalance;
    mapping(address => int256) public owed; // positive: manager owes caller

    function setPool(T.PoolKey memory k, uint256 r, uint256 cap) external {
        rate0Per1[T.poolId(k)] = r;
        maxOut[T.poolId(k)] = cap;
    }

    function unlock(bytes calldata data) external returns (bytes memory r) {
        r = IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(T.PoolKey calldata k, IPoolManager.SwapParams calldata p, bytes calldata) external returns (int256) {
        bytes32 id = T.poolId(k);
        uint256 r = rate0Per1[id];
        require(r != 0, "no pool");
        require(p.amountSpecified > 0, "exact output only");
        uint256 out = uint256(p.amountSpecified);
        require(maxOut[id] == 0 || out <= maxOut[id], "pool short");
        uint256 inAmt;
        if (p.zeroForOne) {
            // out is currency1; in is currency0 = out * r / 1e18 (rounded up)
            inAmt = (out * r + 1e18 - 1) / 1e18;
        } else {
            inAmt = (out * 1e18 + r - 1) / r;
        }
        int128 d0 = p.zeroForOne ? -int128(int256(inAmt)) : int128(int256(out));
        int128 d1 = p.zeroForOne ? int128(int256(out)) : -int128(int256(inAmt));
        return (int256(d0) << 128) | int256(uint256(uint128(d1)));
    }

    function sync(address currency) external {
        synced = currency;
        syncedBalance = MockERC20(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        paid = MockERC20(synced).balanceOf(address(this)) - syncedBalance;
    }

    function take(address currency, address to, uint256 amount) external {
        MockERC20(currency).transfer(to, amount);
    }
}
