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
            vault.CLAIM_REQUEST_TYPEHASH(),
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
        // 准备 3 个影子地址
        address stealth1 = makeAddr("stealth1");
        address stealth2 = makeAddr("stealth2");
        address stealth3 = makeAddr("stealth3");

        uint256 amount1 = 1_000 * 1e6;  // 1000 USDT → stealth1
        uint256 amount2 = 2_500 * 1e6;  // 2500 USDT → stealth2
        uint256 amount3 = 0.5 ether;    // 0.5 ETH   → stealth3

        address[] memory stealthAddrs = new address[](3);
        stealthAddrs[0] = stealth1;
        stealthAddrs[1] = stealth2;
        stealthAddrs[2] = stealth3;

        address[] memory tokens = new address[](3);
        tokens[0] = address(usdt);
        tokens[1] = address(usdt);
        tokens[2] = address(0); // 原生 ETH

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = amount1;
        amounts[1] = amount2;
        amounts[2] = amount3;

        // 给 owner 充值 ETH
        vm.deal(owner, 1 ether);

        // Owner 批准 Vault 拉取 USDT，并附带 ETH 调用
        vm.startPrank(owner);
        usdt.approve(address(vault), amount1 + amount2);
        vault.batchAllocate{value: amount3}(stealthAddrs, tokens, amounts);
        vm.stopPrank();

        // 断言余额映射正确更新
        assertEq(vault.balances(address(usdt), stealth1), amount1, "stealth1 USDT balance mismatch");
        assertEq(vault.balances(address(usdt), stealth2), amount2, "stealth2 USDT balance mismatch");
        assertEq(vault.balances(address(0),    stealth3), amount3, "stealth3 ETH balance mismatch");

        // 非 Owner 调用必须回滚
        vm.prank(relayer);
        vm.expectRevert();
        vault.batchAllocate{value: 0}(stealthAddrs, tokens, amounts);
    }

    /// @notice 完整 EIP-712 提款流程：余额变化完全准确
    function test_ClaimWithValidSignature() public {
        uint256 salary  = 5_000 * 1e6; // 5000 USDT 总额
        uint256 fee     = 10 * 1e6;    // 10 USDT 给 Relayer

        // 1. 给影子地址分配 USDT
        _allocateUSDT(stealthAddr, salary);

        // 2. 构造 ClaimRequest
        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddr,
            token:          address(usdt),
            amount:         salary,
            recipient:      employee,
            feeAmount:      fee,
            nonce:          vault.nonces(stealthAddr), // 应为 0
            deadline:       block.timestamp + 1 hours
        });

        // 3. 用影子私钥签名
        bytes memory sig = _signClaimRequest(req, stealthPrivKey);

        // 4. Relayer 代发提款
        uint256 employeeBefore = usdt.balanceOf(employee);
        uint256 relayerBefore  = usdt.balanceOf(relayer);

        vm.prank(relayer);
        vault.claim(req, sig);

        // 5. 断言：资金精确到账
        assertEq(usdt.balanceOf(employee), employeeBefore + salary - fee, "employee net pay mismatch");
        assertEq(usdt.balanceOf(relayer),  relayerBefore  + fee,          "relayer fee mismatch");

        // 6. 断言：nonce 自增，防重放
        assertEq(vault.nonces(stealthAddr), 1, "nonce should increment");

        // 7. 断言：Vault 内余额清零
        assertEq(vault.balances(address(usdt), stealthAddr), 0, "vault balance should be 0");
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
        vm.expectRevert(bytes("Invalid nonce"));
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
        vm.expectRevert(bytes("Signature expired"));
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
        vm.expectRevert(bytes("Invalid signature"));
        vault.claim(req, sig);
    }

    // -----------------------------------------------------------------------
    // 模糊测试 & Gas 测试
    // -----------------------------------------------------------------------

    /// @notice 随机金额输入下的溢出与边界测试
    function testFuzz_AllocationAndClaim(uint96 amount, uint96 fee) public {
        // TODO
    }

    /// @notice 记录 batchAllocate 的 Gas 消耗
    function test_GasCost_BatchAllocate() public {
        // TODO
    }

    /// @notice 记录 claim 的 Gas 消耗
    function test_GasCost_Claim() public {
        // TODO
    }
}
