// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ERC6909} from "@uniswap/v4-core/src/ERC6909.sol";

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title MandateBook — custody, capability tokens, and policy state
///
/// @notice A "mandate" is a revocable, transferable ERC-6909 capability token
/// that lets its holder (an AI agent, a service, a person) trade the owner's
/// vault balance inside a hard policy envelope: one pool, optional direction
/// restriction, a per-epoch spend budget, and an expiry. The owner keeps
/// custody at all times and can revoke instantly.
///
/// Design lineage: Cadence's capabilities + entitlements. On Flow, a Vault
/// only responds to a capability carrying the right entitlement, and the
/// issuer can revoke it via its controller. Here the capability is a 6909
/// token, the entitlement is the Policy struct, and revocation is one call.
///
/// Enforcement is two-layer:
///  1. Custody-side (this contract): executors can only move vault balances
///     through `execute`, which debits the owner and swaps via PoolManager.
///  2. Venue-side (MandateHook): the pool's hook re-validates every mandate
///     swap in `beforeSwap` — calling back into `enforceAndDebit` here — so
///     budget accounting and revocation hold on the only path liquidity can
///     move through, and forged mandate hookData from third-party routers
///     is rejected at the pool itself.
contract MandateBook is ERC6909, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------
    error NotPoolManager();
    error NotHook();
    error HookAlreadySet();
    error UnknownMandate();
    error NotOwner();
    error Revoked();
    error NotStarted();
    error Expired();
    error WrongPool();
    error DirectionForbidden();
    error NotCapabilityHolder();
    error BudgetExceeded();
    error ExactInputOnly();
    error InsufficientVaultBalance();
    error TooLittleReceived();
    error InvalidPolicy();

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------
    event Deposit(address indexed owner, Currency indexed currency, uint256 amount);
    event Withdraw(address indexed owner, Currency indexed currency, uint256 amount);
    event MandateCreated(
        uint256 indexed mandateId,
        address indexed owner,
        address indexed executor,
        PoolId poolId,
        uint128 budgetPerEpoch,
        uint32 epochLength,
        uint40 expiry,
        Direction direction
    );
    event MandateRevoked(uint256 indexed mandateId);
    event MandateExecuted(
        uint256 indexed mandateId,
        address indexed executor,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut
    );

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------
    enum Direction {
        Both,
        OnlyZeroForOne,
        OnlyOneForZero
    }

    struct Policy {
        address owner; // funded the mandate; may revoke; receives output
        PoolId poolId; // the only pool this mandate may trade
        uint128 budgetPerEpoch; // in units of the token being spent
        uint32 epochLength; // seconds per budget epoch
        uint40 start;
        uint40 expiry;
        Direction direction;
        bool revoked;
    }

    struct CallbackData {
        uint256 mandateId;
        address executor;
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint256 minAmountOut;
    }

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    IPoolManager public immutable poolManager;
    /// The venue-side enforcer. Set once at deployment wiring.
    address public hook;

    uint256 public nextMandateId = 1;
    mapping(uint256 mandateId => Policy) public policies;
    /// PoolId is a hash; keep the full key for execution.
    mapping(uint256 mandateId => PoolKey) internal poolKeys;
    mapping(uint256 mandateId => mapping(uint256 epoch => uint256 spent)) public spentInEpoch;

    /// Owner vault balances. Only the owner can ever withdraw.
    mapping(address owner => mapping(Currency => uint256)) public vaultBalance;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// One-time wiring; the hook address embeds its permission flags, so it
    /// cannot be deployed before the book it points at.
    function setHook(address _hook) external {
        if (hook != address(0)) revert HookAlreadySet();
        hook = _hook;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ------------------------------------------------------------------
    // Vault: owner custody
    // ------------------------------------------------------------------
    function deposit(Currency currency, uint256 amount) external {
        IERC20Minimal(Currency.unwrap(currency)).transferFrom(msg.sender, address(this), amount);
        vaultBalance[msg.sender][currency] += amount;
        emit Deposit(msg.sender, currency, amount);
    }

    function withdraw(Currency currency, uint256 amount) external {
        // No mandate, no executor, no admin can ever move this — owner only.
        uint256 bal = vaultBalance[msg.sender][currency];
        if (bal < amount) revert InsufficientVaultBalance();
        vaultBalance[msg.sender][currency] = bal - amount;
        IERC20Minimal(Currency.unwrap(currency)).transfer(msg.sender, amount);
        emit Withdraw(msg.sender, currency, amount);
    }

    // ------------------------------------------------------------------
    // Mandate lifecycle
    // ------------------------------------------------------------------
    function createMandate(
        PoolKey calldata key,
        address executor,
        uint128 budgetPerEpoch,
        uint32 epochLength,
        uint40 start,
        uint40 expiry,
        Direction direction
    ) external returns (uint256 mandateId) {
        // The pool must be guarded by the mandate hook, or venue-side
        // enforcement (and budget accounting) could be bypassed.
        if (address(key.hooks) != hook || hook == address(0)) revert InvalidPolicy();
        if (epochLength == 0 || budgetPerEpoch == 0) revert InvalidPolicy();
        if (expiry <= block.timestamp || expiry <= start) revert InvalidPolicy();

        mandateId = nextMandateId++;
        policies[mandateId] = Policy({
            owner: msg.sender,
            poolId: key.toId(),
            budgetPerEpoch: budgetPerEpoch,
            epochLength: epochLength,
            start: start,
            expiry: expiry,
            direction: direction,
            revoked: false
        });
        poolKeys[mandateId] = key;

        // The capability itself: one 6909 token. Transferable — holders can
        // delegate onward (like handing a Cadence capability to a sub-agent);
        // the owner's revoke always dominates.
        _mint(executor, mandateId, 1);

        emit MandateCreated(
            mandateId, msg.sender, executor, key.toId(), budgetPerEpoch, epochLength, expiry, direction
        );
    }

    function revoke(uint256 mandateId) external {
        Policy storage p = policies[mandateId];
        if (p.owner == address(0)) revert UnknownMandate();
        if (p.owner != msg.sender) revert NotOwner();
        p.revoked = true;
        emit MandateRevoked(mandateId);
    }

    function currentEpoch(uint256 mandateId) public view returns (uint256) {
        Policy storage p = policies[mandateId];
        if (block.timestamp < p.start) return 0;
        return (block.timestamp - p.start) / p.epochLength;
    }

    function remainingBudget(uint256 mandateId) external view returns (uint256) {
        Policy storage p = policies[mandateId];
        uint256 spent = spentInEpoch[mandateId][currentEpoch(mandateId)];
        return spent >= p.budgetPerEpoch ? 0 : p.budgetPerEpoch - spent;
    }

    // ------------------------------------------------------------------
    // Venue-side enforcement entry point (called by MandateHook only)
    // ------------------------------------------------------------------
    /// @notice Re-validates the full policy and debits the epoch budget.
    /// Runs inside the pool's beforeSwap — on the only path through which
    /// pool liquidity can move — regardless of what code initiated the swap.
    function enforceAndDebit(
        uint256 mandateId,
        address executor,
        PoolId poolId,
        bool zeroForOne,
        int256 amountSpecified
    ) external {
        if (msg.sender != hook) revert NotHook();

        Policy storage p = policies[mandateId];
        if (p.owner == address(0)) revert UnknownMandate();
        if (p.revoked) revert Revoked();
        if (block.timestamp < p.start) revert NotStarted();
        if (block.timestamp >= p.expiry) revert Expired();
        if (PoolId.unwrap(poolId) != PoolId.unwrap(p.poolId)) revert WrongPool();
        if (p.direction == Direction.OnlyZeroForOne && !zeroForOne) revert DirectionForbidden();
        if (p.direction == Direction.OnlyOneForZero && zeroForOne) revert DirectionForbidden();
        if (balanceOf[executor][mandateId] == 0) revert NotCapabilityHolder();
        if (amountSpecified >= 0) revert ExactInputOnly();

        uint256 amountIn = uint256(-amountSpecified);
        uint256 epoch = currentEpoch(mandateId);
        uint256 spent = spentInEpoch[mandateId][epoch] + amountIn;
        if (spent > p.budgetPerEpoch) revert BudgetExceeded();
        spentInEpoch[mandateId][epoch] = spent;
    }

    // ------------------------------------------------------------------
    // Execution (called by the capability holder)
    // ------------------------------------------------------------------
    function execute(uint256 mandateId, bool zeroForOne, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        Policy storage p = policies[mandateId];
        if (p.owner == address(0)) revert UnknownMandate();
        if (balanceOf[msg.sender][mandateId] == 0) revert NotCapabilityHolder();

        PoolKey memory key = poolKeys[mandateId];
        Currency spendCurrency = zeroForOne ? key.currency0 : key.currency1;

        // Custody-side check: the executor spends only the owner's vault
        // balance, debited up front. (Policy checks re-run in the hook.)
        uint256 bal = vaultBalance[p.owner][spendCurrency];
        if (bal < amountIn) revert InsufficientVaultBalance();
        vaultBalance[p.owner][spendCurrency] = bal - amountIn;

        bytes memory result = poolManager.unlock(
            abi.encode(
                CallbackData({
                    mandateId: mandateId,
                    executor: msg.sender,
                    key: key,
                    zeroForOne: zeroForOne,
                    amountIn: amountIn,
                    minAmountOut: minAmountOut
                })
            )
        );
        uint256 consumed;
        (amountOut, consumed) = abi.decode(result, (uint256, uint256));

        // Partial fill (price limit reached): refund the unconsumed input.
        if (consumed < amountIn) {
            vaultBalance[p.owner][spendCurrency] += amountIn - consumed;
        }

        Currency outCurrency = zeroForOne ? key.currency1 : key.currency0;
        vaultBalance[p.owner][outCurrency] += amountOut;

        emit MandateExecuted(mandateId, msg.sender, zeroForOne, amountIn, amountOut);
    }

    function unlockCallback(bytes calldata rawData) external onlyPoolManager returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta = poolManager.swap(
            data.key,
            IPoolManager.SwapParams({
                zeroForOne: data.zeroForOne,
                amountSpecified: -int256(data.amountIn), // exact input
                sqrtPriceLimitX96: data.zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            abi.encode(data.mandateId, data.executor)
        );

        Currency spendCurrency = data.zeroForOne ? data.key.currency0 : data.key.currency1;
        Currency outCurrency = data.zeroForOne ? data.key.currency1 : data.key.currency0;

        // Pay exactly what the pool consumed (partial fills stop at the
        // price limit); the rest is refunded to the owner in execute().
        int128 inSigned = data.zeroForOne ? delta.amount0() : delta.amount1();
        uint256 consumed = uint256(uint128(-inSigned));
        poolManager.sync(spendCurrency);
        IERC20Minimal(Currency.unwrap(spendCurrency)).transfer(address(poolManager), consumed);
        poolManager.settle();

        // Take the output back into the vault.
        int128 outSigned = data.zeroForOne ? delta.amount1() : delta.amount0();
        uint256 amountOut = uint256(uint128(outSigned));
        if (amountOut < data.minAmountOut) revert TooLittleReceived();
        poolManager.take(outCurrency, address(this), amountOut);

        return abi.encode(amountOut, consumed);
    }
}
