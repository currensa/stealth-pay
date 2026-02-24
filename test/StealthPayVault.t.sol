// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StealthPayVault.sol";

// ---------------------------------------------------------------------------
// Mock ERC-20（模拟 USDT）
// ---------------------------------------------------------------------------

contract MockUSDT {
    string public name     = "Mock USDT";
    string public symbol   = "USDT";
    uint8  public decimals = 6;

    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply    += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        balanceOf[to]               += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ---------------------------------------------------------------------------
// 测试合约
// ---------------------------------------------------------------------------

contract StealthPayVaultTest is Test {
    // -----------------------------------------------------------------------
    // 测试角色
    // -----------------------------------------------------------------------

    address internal owner;    // 企业多签（调用 batchAllocate 的 Owner）
    address internal relayer;  // 中继器（代发 Gas，调用 claim）
    address internal employee; // 员工常用地址（最终收款人）

    uint256 internal stealthPrivKey; // 影子地址私钥（用于签名）
    address internal stealthAddr;    // 对应的影子地址

    // -----------------------------------------------------------------------
    // 被测合约与 Mock 代币
    // -----------------------------------------------------------------------

    StealthPayVault internal vault;
    MockUSDT        internal usdt;

    // -----------------------------------------------------------------------
    // setUp — Foundry 在每个测试前自动调用
    // -----------------------------------------------------------------------

    function setUp() public {
        // 生成测试账户
        owner    = makeAddr("owner");
        relayer  = makeAddr("relayer");
        employee = makeAddr("employee");

        // 生成影子地址密钥对
        stealthPrivKey = uint256(keccak256("shadow-payroll-2026"));
        stealthAddr    = vm.addr(stealthPrivKey);

        // 部署 Vault
        vm.prank(owner);
        vault = new StealthPayVault(owner);

        // 部署 Mock USDT 并为 owner 铸造测试资金
        usdt = new MockUSDT();
        usdt.mint(owner, 1_000_000 * 1e6); // 100 万 USDT
    }

    // -----------------------------------------------------------------------
    // 测试辅助函数
    // -----------------------------------------------------------------------

    /// @dev 根据私钥对 ClaimRequest 生成 EIP-712 签名（返回 packed r,s,v）
    function _signClaimRequest(
        StealthPayVault.ClaimRequest memory req,
        uint256 privateKey
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            vault.CLAIM_TYPEHASH(),
            req.stealthAddress,
            req.token,
            req.amount,
            req.recipient,
            req.feeAmount,
            req.nonce,
            req.deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            vault.DOMAIN_SEPARATOR(),
            structHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev 共享的发薪前置操作：给 stealthAddr 分配 amount USDT
    function _allocateUSDT(address stealth, uint256 amount) internal {
        address[] memory addrs   = new address[](1);
        address[] memory tokens  = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        addrs[0]   = stealth;
        tokens[0]  = address(usdt);
        amounts[0] = amount;

        vm.startPrank(owner);
        usdt.approve(address(vault), amount);
        vault.batchAllocate(addrs, tokens, amounts);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Happy Path
    // -----------------------------------------------------------------------

    /// @notice 验证 batchAllocate 正确记账，且非 Owner 无法调用
    function test_BatchAllocate() public {
        // ── Scenario 1: 数组长度不一致 → 必须 revert ArrayLengthMismatch() ──
        {
            address[] memory a = new address[](2);
            address[] memory t = new address[](1); // 故意不一致
            uint256[] memory m = new uint256[](2);
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSignature("ArrayLengthMismatch()"));
            vault.batchAllocate(a, t, m);
        }

        // ── Scenario 2: 非 Owner 调用 → revert ──
        {
            address[] memory a = new address[](1);
            address[] memory t = new address[](1);
            uint256[] memory m = new uint256[](1);
            vm.prank(relayer);
            vm.expectRevert();
            vault.batchAllocate(a, t, m);
        }

        // ── Scenario 3 & 4: 混合批次：2 个 ETH 地址 + 2 个 USDT 地址 ──
        address ethStealth1  = makeAddr("ethStealth1");
        address ethStealth2  = makeAddr("ethStealth2");
        address usdtStealth1 = makeAddr("usdtStealth1");
        address usdtStealth2 = makeAddr("usdtStealth2");

        uint256 ethAmt1  = 0.3 ether;
        uint256 ethAmt2  = 0.7 ether;
        uint256 usdtAmt1 = 1_000 * 1e6;
        uint256 usdtAmt2 = 2_500 * 1e6;

        address[] memory stealthAddrs = new address[](4);
        stealthAddrs[0] = ethStealth1;
        stealthAddrs[1] = ethStealth2;
        stealthAddrs[2] = usdtStealth1;
        stealthAddrs[3] = usdtStealth2;

        address[] memory tokenArr = new address[](4);
        tokenArr[0] = address(0);       // ETH
        tokenArr[1] = address(0);       // ETH
        tokenArr[2] = address(usdt);
        tokenArr[3] = address(usdt);

        uint256[] memory amtArr = new uint256[](4);
        amtArr[0] = ethAmt1;
        amtArr[1] = ethAmt2;
        amtArr[2] = usdtAmt1;
        amtArr[3] = usdtAmt2;

        vm.deal(owner, ethAmt1 + ethAmt2);
        vm.startPrank(owner);
        usdt.approve(address(vault), usdtAmt1 + usdtAmt2);
        vault.batchAllocate{value: ethAmt1 + ethAmt2}(stealthAddrs, tokenArr, amtArr);
        vm.stopPrank();

        // Scenario 3: 两个原生 ETH 影子地址余额准确
        assertEq(vault.balances(address(0), ethStealth1),    ethAmt1,  "ethStealth1 balance mismatch");
        assertEq(vault.balances(address(0), ethStealth2),    ethAmt2,  "ethStealth2 balance mismatch");

        // Scenario 4: 两个 USDT 影子地址余额准确
        assertEq(vault.balances(address(usdt), usdtStealth1), usdtAmt1, "usdtStealth1 balance mismatch");
        assertEq(vault.balances(address(usdt), usdtStealth2), usdtAmt2, "usdtStealth2 balance mismatch");
    }

    /// @notice 完整 EIP-712 提款流程：余额变化完全准确
    function test_ClaimWithValidSignature() public {
        // 使用规范指定的已知私钥推导影子地址
        uint256 stealthPk      = 0xA11CE;
        address stealthAddress = vm.addr(stealthPk);

        uint256 salary = 1_000 * 1e6; // 1000 USDT
        uint256 fee    = 10   * 1e6;  // 10 USDT → Relayer
        address recip  = makeAddr("recipient");

        // 1. 给影子地址分配 1000 USDT
        _allocateUSDT(stealthAddress, salary);

        // 2. 构造 ClaimRequest
        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddress,
            token:          address(usdt),
            amount:         salary,
            recipient:      recip,
            feeAmount:      fee,
            nonce:          0,
            deadline:       block.timestamp + 1 hours
        });

        // 3. 用 stealthPk 签名
        bytes memory sig = _signClaimRequest(req, stealthPk);

        // 4. Relayer 代发提款
        vm.prank(relayer);
        vault.claim(req, sig);

        // 5. 核心断言
        assertEq(usdt.balanceOf(recip),    salary - fee, "recipient should receive 990 USDT");
        assertEq(usdt.balanceOf(relayer),  fee,          "relayer should receive 10 USDT");
        assertEq(vault.balances(address(usdt), stealthAddress), 0, "vault balance should be zero");
        assertEq(vault.nonces(stealthAddress), 1, "nonce must increment to 1");
    }

    /// @notice 原生 ETH 的分配与提款专项测试
    function test_NativeETH_Flow() public {
        // TODO
    }

    // -----------------------------------------------------------------------
    // 密码学与边界安全测试
    // -----------------------------------------------------------------------

    /// @notice 相同签名二次提交因 Nonce 递增而失败
    function test_RevertIf_ReplayAttack() public {
        uint256 salary = 1_000 * 1e6;
        _allocateUSDT(stealthAddr, salary);

        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddr,
            token:          address(usdt),
            amount:         salary,
            recipient:      employee,
            feeAmount:      0,
            nonce:          vault.nonces(stealthAddr), // nonce = 0
            deadline:       block.timestamp + 1 hours
        });
        bytes memory sig = _signClaimRequest(req, stealthPrivKey);

        // 第一次提款 — 成功
        vm.prank(relayer);
        vault.claim(req, sig);

        // 重放攻击：相同的 req（nonce=0）和签名再次提交
        // 此时链上 nonces[stealthAddr] 已变为 1，必须 revert
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSignature("InvalidNonce()"));
        vault.claim(req, sig);
    }

    /// @notice 超时签名（deadline < block.timestamp）被拒绝
    function test_RevertIf_ExpiredDeadline() public {
        uint256 salary = 500 * 1e6;
        _allocateUSDT(stealthAddr, salary);

        // 将链上时间快进 2 小时
        vm.warp(block.timestamp + 2 hours);

        // 构造一个 deadline 在"过去"的签名
        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddr,
            token:          address(usdt),
            amount:         salary,
            recipient:      employee,
            feeAmount:      0,
            nonce:          vault.nonces(stealthAddr),
            deadline:       block.timestamp - 1  // 已过期
        });
        bytes memory sig = _signClaimRequest(req, stealthPrivKey);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSignature("SignatureExpired()"));
        vault.claim(req, sig);
    }

    /// @notice 篡改 amount 或 recipient 后原签名失效
    function test_RevertIf_TamperedPayload() public {
        uint256 stealthPk      = 0xA11CE;
        address stealthAddress = vm.addr(stealthPk);
        address hacker         = makeAddr("hacker");

        uint256 legit = 100 * 1e6; // 签名时的合法金额
        _allocateUSDT(stealthAddress, legit);

        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddress,
            token:          address(usdt),
            amount:         legit,
            recipient:      employee,
            feeAmount:      0,
            nonce:          0,
            deadline:       block.timestamp + 1 hours
        });
        bytes memory sig = _signClaimRequest(req, stealthPk);

        // 场景 A：篡改 amount（100 USDT → 余额中没有的 9999 USDT）
        req.amount = 9_999 * 1e6;
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSignature("InvalidSignature()"));
        vault.claim(req, sig);

        // 场景 B：恢复 amount，改 recipient 为黑客地址
        req.amount    = legit;
        req.recipient = hacker;
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSignature("InvalidSignature()"));
        vault.claim(req, sig);
    }

    /// @notice 余额不足时 claim 必须 revert
    function test_RevertIf_InsufficientBalance() public {
        uint256 stealthPk      = 0xA11CE;
        address stealthAddress = vm.addr(stealthPk);

        // 只分配 500 USDT
        _allocateUSDT(stealthAddress, 500 * 1e6);

        // 构造试图提取 1000 USDT 的请求（有效签名，但金额超过余额）
        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddress,
            token:          address(usdt),
            amount:         1_000 * 1e6, // 超额
            recipient:      employee,
            feeAmount:      0,
            nonce:          0,
            deadline:       block.timestamp + 1 hours
        });
        bytes memory sig = _signClaimRequest(req, stealthPk);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSignature("InsufficientBalance()"));
        vault.claim(req, sig);
    }

    /// @notice 防范签名延展性攻击（s 值高区间被拒绝）
    function test_RevertIf_SignatureMalleability() public {
        // TODO
    }

    /// @notice 篡改 ClaimRequest 字段后签名恢复地址不匹配
    function test_RevertIf_WrongSigner() public {
        uint256 salary = 2_000 * 1e6;
        _allocateUSDT(stealthAddr, salary);

        // 构造并签署合法 req（feeAmount = 10 USDT）
        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddr,
            token:          address(usdt),
            amount:         salary,
            recipient:      employee,
            feeAmount:      10 * 1e6,
            nonce:          vault.nonces(stealthAddr),
            deadline:       block.timestamp + 1 hours
        });
        bytes memory sig = _signClaimRequest(req, stealthPrivKey);

        // 攻击者提交前偷偷把 feeAmount 改大——签名与新 req 不匹配
        req.feeAmount = 1_000 * 1e6;

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSignature("InvalidSignature()"));
        vault.claim(req, sig);
    }

    // -----------------------------------------------------------------------
    // 模糊测试 & Gas 测试
    // -----------------------------------------------------------------------

    /// @notice 随机金额下完整 allocate→claim 流程，断言资金分配无误
    function testFuzz_AllocationAndClaim(uint256 allocateAmount, uint256 feeAmount) public {
        vm.assume(allocateAmount > 0 && allocateAmount < 100_000_000 ether);
        vm.assume(feeAmount <= allocateAmount);

        uint256 stealthPk      = 0xA11CE;
        address stealthAddress = vm.addr(stealthPk);
        address recip          = makeAddr("fuzz_recipient");

        // 按需铸造，避免依赖 setUp 中的固定余额
        usdt.mint(owner, allocateAmount);

        // Allocate
        address[] memory addrs = new address[](1);
        address[] memory toks  = new address[](1);
        uint256[] memory amts  = new uint256[](1);
        addrs[0] = stealthAddress;
        toks[0]  = address(usdt);
        amts[0]  = allocateAmount;

        vm.startPrank(owner);
        usdt.approve(address(vault), allocateAmount);
        vault.batchAllocate(addrs, toks, amts);
        vm.stopPrank();

        // Claim
        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddress,
            token:          address(usdt),
            amount:         allocateAmount,
            recipient:      recip,
            feeAmount:      feeAmount,
            nonce:          vault.nonces(stealthAddress),
            deadline:       block.timestamp + 1 hours
        });
        bytes memory sig = _signClaimRequest(req, stealthPk);

        vm.prank(relayer);
        vault.claim(req, sig);

        assertEq(usdt.balanceOf(recip),   allocateAmount - feeAmount, "recipient amount mismatch");
        assertEq(usdt.balanceOf(relayer), feeAmount,                  "relayer fee mismatch");
    }

    /// @notice 100 个隐身地址批量分配的 Gas 基准
    function test_GasCost_BatchAllocate_100() public {
        uint256 n = 100;
        address[] memory addrs = new address[](n);
        address[] memory toks  = new address[](n);
        uint256[] memory amts  = new uint256[](n);

        uint256 perAddr = 100 * 1e6; // 100 USDT each
        for (uint256 i = 0; i < n; i++) {
            addrs[i] = address(uint160(uint256(keccak256(abi.encode("s", i)))));
            toks[i]  = address(usdt);
            amts[i]  = perAddr;
        }

        vm.startPrank(owner);
        usdt.approve(address(vault), perAddr * n);
        uint256 gasBefore = gasleft();
        vault.batchAllocate(addrs, toks, amts);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        emit log_named_uint("batchAllocate(100) gas", gasUsed);
    }

    /// @notice 单次 claim 的 Gas 基准
    function test_GasCost_Claim() public {
        uint256 stealthPk      = 0xA11CE;
        address stealthAddress = vm.addr(stealthPk);
        uint256 salary         = 1_000 * 1e6;

        _allocateUSDT(stealthAddress, salary);

        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddress,
            token:          address(usdt),
            amount:         salary,
            recipient:      employee,
            feeAmount:      10 * 1e6,
            nonce:          0,
            deadline:       block.timestamp + 1 hours
        });
        bytes memory sig = _signClaimRequest(req, stealthPk);

        uint256 gasBefore = gasleft();
        vm.prank(relayer);
        vault.claim(req, sig);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("claim gas", gasUsed);
    }
}
