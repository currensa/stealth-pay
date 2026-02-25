// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StealthPayVault.sol";

// ---------------------------------------------------------------------------
// Mock ERC-20（模拟 USDT / USDC）
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

    address internal hrAdmin;      // 默认 HR（Owner 语义已废弃，仅作默认发薪方）
    address internal relayerNode;  // 中继器节点：代发 Gas，调用 claim，无初始 USDT
    address internal employeeDest; // 员工最终真实收款地址（纯白板）

    uint256 internal stealthPrivKey; // 通用影子私钥（供辅助测试使用）
    address internal stealthAddr;    // 对应影子地址

    // -----------------------------------------------------------------------
    // 被测合约与 Mock 代币
    // -----------------------------------------------------------------------

    StealthPayVault internal vault;
    MockUSDT        internal usdt;

    // -----------------------------------------------------------------------
    // setUp — Foundry 在每个测试前自动调用
    // -----------------------------------------------------------------------

    function setUp() public {
        hrAdmin      = makeAddr("hrAdmin");
        relayerNode  = makeAddr("relayerNode");
        employeeDest = makeAddr("employeeDest");

        stealthPrivKey = uint256(keccak256("shadow-payroll-2026"));
        stealthAddr    = vm.addr(stealthPrivKey);

        // 无主合约：无需传入 owner 参数
        vault = new StealthPayVault();

        // 铸造充足 USDT 给 hrAdmin（覆盖 fuzz 上界 1e36），并给予 Vault 最大授权
        usdt = new MockUSDT();
        usdt.mint(hrAdmin, 1e36);

        vm.prank(hrAdmin);
        usdt.approve(address(vault), type(uint256).max);
    }

    // -----------------------------------------------------------------------
    // 测试辅助函数
    // -----------------------------------------------------------------------

    /// @dev 标准叶子哈希：keccak256(keccak256(abi.encode(stealth, token, amount)))
    ///      与 openzeppelin merkle-tree StandardMerkleTree 格式兼容（双重哈希）
    function _leaf(address stealth, address token, uint256 amount)
        internal pure returns (bytes32)
    {
        return keccak256(bytes.concat(keccak256(abi.encode(stealth, token, amount))));
    }

    /// @dev 2-叶 Merkle Root（OZ 排序方式：小哈希在左）
    function _merkleRoot2(bytes32 a, bytes32 b)
        internal pure returns (bytes32)
    {
        return a < b
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }

    /// @dev EIP-712 签名（ClaimRequest，无 nonce）
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

    /// @dev 便捷：hrAdmin 发起 depositForPayroll（setUp 已完成铸币与最大授权）
    function _depositUSDT(bytes32 root, uint256 totalAmount) internal {
        vm.prank(hrAdmin);
        vault.depositForPayroll(root, address(usdt), totalAmount);
    }

    // -----------------------------------------------------------------------
    // Happy Path
    // -----------------------------------------------------------------------

    /// @notice 任何人都可以调用 depositForPayroll，payrolls 记录正确
    function test_DepositForPayroll() public {
        bytes32 root  = bytes32(uint256(1));
        uint256 total = 3_000 ether;

        _depositUSDT(root, total);

        // payrolls 映射应记录正确的 employer 与 token
        (address emp, address tok,) = vault.payrolls(root);
        assertEq(emp, hrAdmin,       "employer should be hrAdmin");
        assertEq(tok, address(usdt), "token should be usdt");
        assertEq(usdt.balanceOf(address(vault)), total, "vault should hold total");
    }

    /// @notice 完整 Merkle 发薪流程 + AlreadyClaimed 防双花
    function test_ClaimWithValidSignature() public {
        // ── 定义两个影子地址 ──────────────────────────────────────────────────
        uint256 stealthPk1   = 0xA11CE;
        address stealthAddr1 = vm.addr(stealthPk1);
        address stealthAddr2 = makeAddr("stealthAddr2");
        address recipient    = makeAddr("recipient");

        uint256 amount1 = 1_000 ether;
        uint256 amount2 = 2_000 ether;
        uint256 fee     =    10 ether;

        // ── 构造 2-叶 Merkle Tree ─────────────────────────────────────────────
        bytes32 leaf1 = _leaf(stealthAddr1, address(usdt), amount1);
        bytes32 leaf2 = _leaf(stealthAddr2, address(usdt), amount2);
        bytes32 root  = _merkleRoot2(leaf1, leaf2);

        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = leaf2;

        _depositUSDT(root, amount1 + amount2);

        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddr1,
            token:          address(usdt),
            amount:         amount1,
            recipient:      recipient,
            feeAmount:      fee,
            deadline:       block.timestamp + 1 hours
        });
        bytes memory sig = _signClaimRequest(req, stealthPk1);

        vm.prank(relayerNode);
        vault.claim(req, sig, proof1, root);

        assertEq(usdt.balanceOf(recipient),      amount1 - fee, "recipient should receive 990 ether");
        assertEq(usdt.balanceOf(relayerNode),    fee,           "relayerNode should receive 10 ether");
        assertTrue(vault.isClaimed(stealthAddr1),               "isClaimed should be true");

        // 防双花
        vm.prank(relayerNode);
        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed()"));
        vault.claim(req, sig, proof1, root);
    }

    /// @notice 原生 ETH 完整发薪流程
    function test_NativeETH_Flow() public {
        uint256 stealthPk      = 0xA11CE;
        address stealthAddress = vm.addr(stealthPk);
        address recipient      = makeAddr("ethRecipient");

        uint256 amount = 1 ether;
        uint256 fee    = 0.01 ether;

        bytes32 leaf           = _leaf(stealthAddress, address(0), amount);
        bytes32 root           = leaf;
        bytes32[] memory proof = new bytes32[](0);

        vm.deal(hrAdmin, amount);
        vm.prank(hrAdmin);
        vault.depositForPayroll{value: amount}(root, address(0), amount);

        // payrolls 应记录 ETH 存款
        (address ethEmp, address ethTok,) = vault.payrolls(root);
        assertEq(ethEmp, hrAdmin,    "employer should be hrAdmin");
        assertEq(ethTok, address(0), "token should be ETH");
        assertEq(address(vault).balance, amount, "vault should hold ETH");

        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddress,
            token:          address(0),
            amount:         amount,
            recipient:      recipient,
            feeAmount:      fee,
            deadline:       block.timestamp + 1 hours
        });
        bytes memory sig = _signClaimRequest(req, stealthPk);

        vm.prank(relayerNode);
        vault.claim(req, sig, proof, root);

        assertEq(address(recipient).balance,   amount - fee, "recipient should receive amount-fee ETH");
        assertEq(address(relayerNode).balance, fee,          "relayerNode should receive fee ETH");
        assertEq(address(vault).balance,       0,            "vault should be empty");
        assertTrue(vault.isClaimed(stealthAddress),          "isClaimed should be true");
    }

    // -----------------------------------------------------------------------
    // 多租户测试
    // -----------------------------------------------------------------------

    /// @notice 两个 HR 各自存入不同代币，员工互不干扰，各自成功提款
    function test_MultiTenant_Isolation() public {
        address hrA = makeAddr("hrA");
        address hrB = makeAddr("hrB");
        MockUSDT usdc = new MockUSDT(); // 第二种代币（模拟 USDC）

        uint256 amountA = 1_000 ether;
        uint256 amountB = 2_000 ether;

        // hrA 持有 USDT
        usdt.mint(hrA, amountA);
        vm.prank(hrA);
        usdt.approve(address(vault), amountA);

        // hrB 持有 USDC
        usdc.mint(hrB, amountB);
        vm.prank(hrB);
        usdc.approve(address(vault), amountB);

        uint256 stealthPkA   = 0xAAAA;
        address stealthAddrA = vm.addr(stealthPkA);
        uint256 stealthPkB   = 0xBBBB;
        address stealthAddrB = vm.addr(stealthPkB);

        // 构建各自单叶 Merkle 树
        bytes32 rootA  = _leaf(stealthAddrA, address(usdt), amountA);
        bytes32 rootB  = _leaf(stealthAddrB, address(usdc), amountB);
        bytes32[] memory emptyProof = new bytes32[](0);

        // hrA 存入 USDT，hrB 存入 USDC
        vm.prank(hrA);
        vault.depositForPayroll(rootA, address(usdt), amountA);
        vm.prank(hrB);
        vault.depositForPayroll(rootB, address(usdc), amountB);

        // payrolls 隔离验证
        (address empA, address tokA,) = vault.payrolls(rootA);
        (address empB, address tokB,) = vault.payrolls(rootB);
        assertEq(empA, hrA,           "rootA employer = hrA");
        assertEq(tokA, address(usdt), "rootA token = USDT");
        assertEq(empB, hrB,           "rootB employer = hrB");
        assertEq(tokB, address(usdc), "rootB token = USDC");

        address recipientA = makeAddr("recipientA");
        address recipientB = makeAddr("recipientB");

        // 员工 A 提取 USDT
        StealthPayVault.ClaimRequest memory reqA = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddrA,
            token:          address(usdt),
            amount:         amountA,
            recipient:      recipientA,
            feeAmount:      0,
            deadline:       block.timestamp + 1 hours
        });
        vm.prank(relayerNode);
        vault.claim(reqA, _signClaimRequest(reqA, stealthPkA), emptyProof, rootA);
        assertEq(usdt.balanceOf(recipientA), amountA, "A should receive USDT");

        // 员工 B 提取 USDC
        StealthPayVault.ClaimRequest memory reqB = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddrB,
            token:          address(usdc),
            amount:         amountB,
            recipient:      recipientB,
            feeAmount:      0,
            deadline:       block.timestamp + 1 hours
        });
        vm.prank(relayerNode);
        vault.claim(reqB, _signClaimRequest(reqB, stealthPkB), emptyProof, rootB);
        assertEq(usdc.balanceOf(recipientB), amountB, "B should receive USDC");
    }

    /// @notice 拿 USDT root 的 Proof 却请求提取 USDC → TokenMismatch
    function test_RevertIf_CrossTenantTokenAttack() public {
        address hrA = makeAddr("hrA");
        MockUSDT usdc = new MockUSDT(); // 另一个 HR 的代币

        uint256 amountA = 1_000 ether;
        usdt.mint(hrA, amountA);
        vm.prank(hrA);
        usdt.approve(address(vault), amountA);

        uint256 stealthPkA   = 0xAAAA;
        address stealthAddrA = vm.addr(stealthPkA);

        bytes32 rootA  = _leaf(stealthAddrA, address(usdt), amountA);
        bytes32[] memory proofA = new bytes32[](0);

        vm.prank(hrA);
        vault.depositForPayroll(rootA, address(usdt), amountA);

        // 攻击：拿 rootA（USDT root）但篡改 req.token 为 USDC
        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddrA,
            token:          address(usdc), // 企图提取 USDC
            amount:         amountA,
            recipient:      makeAddr("attacker"),
            feeAmount:      0,
            deadline:       block.timestamp + 1 hours
        });
        // 签名必须在 vm.expectRevert 之前计算，否则内部的 vault.CLAIM_TYPEHASH() staticcall
        // 会被 vm.expectRevert 拦截，导致误判
        bytes memory attackSig = _signClaimRequest(req, stealthPkA);

        vm.prank(relayerNode);
        vm.expectRevert(abi.encodeWithSignature("TokenMismatch()"));
        vault.claim(req, attackSig, proofA, rootA);
    }

    // -----------------------------------------------------------------------
    // 密码学与边界安全测试
    // -----------------------------------------------------------------------

    /// @notice 过期 deadline 被拒绝
    function test_RevertIf_ExpiredDeadline() public {
        uint256 stealthPk      = 0xA11CE;
        address stealthAddress = vm.addr(stealthPk);

        bytes32 leaf           = _leaf(stealthAddress, address(usdt), 500 ether);
        bytes32 root           = leaf;
        bytes32[] memory proof = new bytes32[](0);

        _depositUSDT(root, 500 ether);

        vm.warp(block.timestamp + 2 hours);

        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddress,
            token:          address(usdt),
            amount:         500 ether,
            recipient:      employeeDest,
            feeAmount:      0,
            deadline:       block.timestamp - 1
        });
        bytes memory sig = _signClaimRequest(req, stealthPk);

        vm.prank(relayerNode);
        vm.expectRevert(abi.encodeWithSignature("SignatureExpired()"));
        vault.claim(req, sig, proof, root);
    }

    /// @notice 篡改 amount 触发 InvalidMerkleProof；篡改 recipient 触发 InvalidSignature
    function test_RevertIf_TamperedPayload() public {
        uint256 stealthPk      = 0xA11CE;
        address stealthAddress = vm.addr(stealthPk);
        address hacker         = makeAddr("hacker");

        uint256 legitimateAmount = 100 ether;
        bytes32 leaf             = _leaf(stealthAddress, address(usdt), legitimateAmount);
        bytes32 root             = leaf;
        bytes32[] memory proof   = new bytes32[](0);

        _depositUSDT(root, legitimateAmount);

        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddress,
            token:          address(usdt),
            amount:         legitimateAmount,
            recipient:      employeeDest,
            feeAmount:      0,
            deadline:       block.timestamp + 1 hours
        });
        bytes memory sig = _signClaimRequest(req, stealthPk);

        // 场景 A：篡改 amount → InvalidMerkleProof
        req.amount = 9_999 ether;
        vm.prank(relayerNode);
        vm.expectRevert(abi.encodeWithSignature("InvalidMerkleProof()"));
        vault.claim(req, sig, proof, root);

        // 场景 B：恢复 amount，篡改 recipient → InvalidSignature
        req.amount    = legitimateAmount;
        req.recipient = hacker;
        vm.prank(relayerNode);
        vm.expectRevert(abi.encodeWithSignature("InvalidSignature()"));
        vault.claim(req, sig, proof, root);
    }

    /// @notice 签名后篡改 feeAmount → EIP-712 恢复地址不匹配
    function test_RevertIf_WrongSigner() public {
        uint256 stealthPk      = 0xA11CE;
        address stealthAddress = vm.addr(stealthPk);

        uint256 amount         = 2_000 ether;
        bytes32 leaf           = _leaf(stealthAddress, address(usdt), amount);
        bytes32 root           = leaf;
        bytes32[] memory proof = new bytes32[](0);

        _depositUSDT(root, amount);

        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddress,
            token:          address(usdt),
            amount:         amount,
            recipient:      employeeDest,
            feeAmount:      10 ether,
            deadline:       block.timestamp + 1 hours
        });
        bytes memory sig = _signClaimRequest(req, stealthPk);

        req.feeAmount = 1_000 ether;
        vm.prank(relayerNode);
        vm.expectRevert(abi.encodeWithSignature("InvalidSignature()"));
        vault.claim(req, sig, proof, root);
    }

    /// @notice 提交不在 payrolls 中的 root → InvalidRoot
    function test_RevertIf_InvalidRoot() public {
        bytes32 unknownRoot    = bytes32(uint256(0xDEADBEEF));
        bytes32[] memory proof = new bytes32[](0);

        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddr,
            token:          address(usdt),
            amount:         100 ether,
            recipient:      employeeDest,
            feeAmount:      0,
            deadline:       block.timestamp + 1 hours
        });
        bytes memory sig = _signClaimRequest(req, stealthPrivKey);

        vm.prank(relayerNode);
        vm.expectRevert(abi.encodeWithSignature("InvalidRoot()"));
        vault.claim(req, sig, proof, unknownRoot);
    }

    /// @notice 错误的 Merkle Proof → InvalidMerkleProof
    function test_RevertIf_InvalidMerkleProof() public {
        uint256 stealthPk      = 0xA11CE;
        address stealthAddress = vm.addr(stealthPk);
        address stealthAddr2   = makeAddr("stealthAddr2");

        uint256 amount = 1_000 ether;
        bytes32 leaf1  = _leaf(stealthAddress, address(usdt), amount);
        bytes32 leaf2  = _leaf(stealthAddr2,   address(usdt), amount);
        bytes32 root   = _merkleRoot2(leaf1, leaf2);

        _depositUSDT(root, 2 * amount);

        bytes32[] memory emptyProof = new bytes32[](0);

        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddress,
            token:          address(usdt),
            amount:         amount,
            recipient:      employeeDest,
            feeAmount:      0,
            deadline:       block.timestamp + 1 hours
        });
        bytes memory sig = _signClaimRequest(req, stealthPk);

        vm.prank(relayerNode);
        vm.expectRevert(abi.encodeWithSignature("InvalidMerkleProof()"));
        vault.claim(req, sig, emptyProof, root);
    }

    /// @notice high-s 签名被 OZ ECDSA 库拦截
    function test_RevertIf_SignatureMalleability() public {
        uint256 stealthPk      = 0xA11CE;
        address stealthAddress = vm.addr(stealthPk);

        uint256 amount         = 500 ether;
        bytes32 leaf           = _leaf(stealthAddress, address(usdt), amount);
        bytes32 root           = leaf;
        bytes32[] memory proof = new bytes32[](0);

        _depositUSDT(root, amount);

        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddress,
            token:          address(usdt),
            amount:         amount,
            recipient:      employeeDest,
            feeAmount:      0,
            deadline:       block.timestamp + 1 hours
        });

        bytes memory malleatedSig;
        {
            bytes32 structHash = keccak256(abi.encode(
                vault.CLAIM_TYPEHASH(),
                req.stealthAddress,
                req.token,
                req.amount,
                req.recipient,
                req.feeAmount,
                req.deadline
            ));
            bytes32 digest = keccak256(abi.encodePacked(
                "\x19\x01",
                vault.DOMAIN_SEPARATOR(),
                structHash
            ));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(stealthPk, digest);
            uint256 N  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
            bytes32 s2 = bytes32(N - uint256(s));
            uint8   v2 = v == 27 ? 28 : 27;
            malleatedSig = abi.encodePacked(r, s2, v2);
        }

        vm.prank(relayerNode);
        vm.expectRevert();
        vault.claim(req, malleatedSig, proof, root);
    }

    // -----------------------------------------------------------------------
    // 模糊测试 & Gas 测试
    // -----------------------------------------------------------------------

    function testFuzz_AllocationAndClaim(uint256 amount, uint256 feeAmount) public {
        vm.assume(amount > 0 && amount < 1e36);
        vm.assume(feeAmount <= amount);

        uint256 stealthPk      = 0xA11CE;
        address stealthAddress = vm.addr(stealthPk);
        address recip          = makeAddr("fuzz_recipient");

        bytes32 leaf           = _leaf(stealthAddress, address(usdt), amount);
        bytes32 root           = leaf;
        bytes32[] memory proof = new bytes32[](0);

        _depositUSDT(root, amount);

        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddress,
            token:          address(usdt),
            amount:         amount,
            recipient:      recip,
            feeAmount:      feeAmount,
            deadline:       block.timestamp + 1 hours
        });
        bytes memory sig = _signClaimRequest(req, stealthPk);

        vm.prank(relayerNode);
        vault.claim(req, sig, proof, root);

        assertEq(usdt.balanceOf(recip),        amount - feeAmount, "recipient amount mismatch");
        assertEq(usdt.balanceOf(relayerNode),  feeAmount,          "relayerNode fee mismatch");
    }

    function test_GasCost_Claim() public {
        uint256 stealthPk      = 0xA11CE;
        address stealthAddress = vm.addr(stealthPk);
        uint256 salary         = 1_000 ether;

        bytes32 leaf           = _leaf(stealthAddress, address(usdt), salary);
        bytes32 root           = leaf;
        bytes32[] memory proof = new bytes32[](0);

        _depositUSDT(root, salary);

        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddress,
            token:          address(usdt),
            amount:         salary,
            recipient:      employeeDest,
            feeAmount:      10 ether,
            deadline:       block.timestamp + 1 hours
        });
        bytes memory sig = _signClaimRequest(req, stealthPk);

        uint256 gasBefore = gasleft();
        vm.prank(relayerNode);
        vault.claim(req, sig, proof, root);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("claim gas (Merkle)", gasUsed);
    }
}
