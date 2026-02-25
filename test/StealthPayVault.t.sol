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

    address internal hrAdmin;      // 企业 HR（Owner）：持有海量 USDT，拥有发薪权限
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

        // hrAdmin 作为 Owner 部署 Vault
        vm.prank(hrAdmin);
        vault = new StealthPayVault(hrAdmin);

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

    /// @notice depositForPayroll 将 root 置入 activeRoots，非 Owner 无法调用
    function test_DepositForPayroll() public {
        bytes32 root  = bytes32(uint256(1)); // 任意 root
        uint256 total = 3_000 ether;

        // 非 Owner（relayerNode）→ revert
        vm.prank(relayerNode);
        vm.expectRevert();
        vault.depositForPayroll(root, address(usdt), total);

        // hrAdmin（Owner）→ 成功，activeRoots 置 true，资金进入 Vault
        _depositUSDT(root, total);
        assertTrue(vault.activeRoots(root), "root should be active");
        assertEq(usdt.balanceOf(address(vault)), total,   "vault should hold total");
    }

    /// @notice 完整 Merkle 发薪流程 + AlreadyClaimed 防双花
    function test_ClaimWithValidSignature() public {
        // ── 定义两个影子地址 ──────────────────────────────────────────────────
        uint256 stealthPk1   = 0xA11CE;
        address stealthAddr1 = vm.addr(stealthPk1);
        address stealthAddr2 = makeAddr("stealthAddr2");
        address recipient    = makeAddr("recipient");

        uint256 amount1 = 1_000 ether; // leaf1 金额
        uint256 amount2 = 2_000 ether; // leaf2 金额
        uint256 fee     =    10 ether;

        // ── 构造 2-叶 Merkle Tree ─────────────────────────────────────────────
        bytes32 leaf1 = _leaf(stealthAddr1, address(usdt), amount1);
        bytes32 leaf2 = _leaf(stealthAddr2, address(usdt), amount2);
        bytes32 root  = _merkleRoot2(leaf1, leaf2);

        // leaf1 的 proof = [leaf2]（唯一兄弟节点）
        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = leaf2;

        // ── hrAdmin：存入总额 ─────────────────────────────────────────────────
        _depositUSDT(root, amount1 + amount2);

        // ── 构造 ClaimRequest 并签名（影子私钥 stealthPk1）──────────────────
        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddr1,
            token:          address(usdt),
            amount:         amount1,
            recipient:      recipient,
            feeAmount:      fee,
            deadline:       block.timestamp + 1 hours
        });
        bytes memory sig = _signClaimRequest(req, stealthPk1);

        // ── relayerNode 代发 ──────────────────────────────────────────────────
        vm.prank(relayerNode);
        vault.claim(req, sig, proof1, root);

        // ── 断言余额与 isClaimed ───────────────────────────────────────────────
        assertEq(usdt.balanceOf(recipient),      amount1 - fee, "recipient should receive 990 ether");
        assertEq(usdt.balanceOf(relayerNode),    fee,           "relayerNode should receive 10 ether");
        assertTrue(vault.isClaimed(stealthAddr1),               "isClaimed should be true");

        // ── 防双花：相同参数再次 claim → AlreadyClaimed ───────────────────────
        vm.prank(relayerNode);
        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed()"));
        vault.claim(req, sig, proof1, root);
    }

    /// @notice 原生 ETH 完整发薪流程：depositForPayroll{value} → claim → ETH 余额精准到账
    function test_NativeETH_Flow() public {
        uint256 stealthPk      = 0xA11CE;
        address stealthAddress = vm.addr(stealthPk);
        address recipient      = makeAddr("ethRecipient");

        uint256 amount = 1 ether;
        uint256 fee    = 0.01 ether;

        // 单叶 Merkle，token = address(0) 代表原生 ETH
        bytes32 leaf           = _leaf(stealthAddress, address(0), amount);
        bytes32 root           = leaf;
        bytes32[] memory proof = new bytes32[](0);

        // hrAdmin：vm.deal 补充 ETH，然后 depositForPayroll{value: amount}
        vm.deal(hrAdmin, amount);
        vm.prank(hrAdmin);
        vault.depositForPayroll{value: amount}(root, address(0), amount);

        assertEq(address(vault).balance, amount, "vault should hold ETH");
        assertTrue(vault.activeRoots(root), "root should be active");

        // 员工：构造 ETH ClaimRequest 并签名
        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddress,
            token:          address(0),   // 原生 ETH
            amount:         amount,
            recipient:      recipient,
            feeAmount:      fee,
            deadline:       block.timestamp + 1 hours
        });
        bytes memory sig = _signClaimRequest(req, stealthPk);

        // relayerNode 代发 claim
        vm.prank(relayerNode);
        vault.claim(req, sig, proof, root);

        // 断言：ETH 精准到账
        assertEq(address(recipient).balance,   amount - fee, "recipient should receive amount-fee ETH");
        assertEq(address(relayerNode).balance, fee,          "relayerNode should receive fee ETH");
        assertEq(address(vault).balance,       0,            "vault should be empty after claim");
        assertTrue(vault.isClaimed(stealthAddress),          "isClaimed should be true");
    }

    // -----------------------------------------------------------------------
    // 密码学与边界安全测试
    // -----------------------------------------------------------------------

    /// @notice 过期 deadline 被拒绝
    function test_RevertIf_ExpiredDeadline() public {
        uint256 stealthPk      = 0xA11CE;
        address stealthAddress = vm.addr(stealthPk);

        // 单叶 Merkle（root = leaf，proof = []）
        bytes32 leaf           = _leaf(stealthAddress, address(usdt), 500 ether);
        bytes32 root           = leaf;
        bytes32[] memory proof = new bytes32[](0);

        _depositUSDT(root, 500 ether);

        vm.warp(block.timestamp + 2 hours); // 快进时间

        StealthPayVault.ClaimRequest memory req = StealthPayVault.ClaimRequest({
            stealthAddress: stealthAddress,
            token:          address(usdt),
            amount:         500 ether,
            recipient:      employeeDest,
            feeAmount:      0,
            deadline:       block.timestamp - 1 // 已过期
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

        // 场景 A：篡改 amount → 叶子哈希不匹配 proof → InvalidMerkleProof
        req.amount = 9_999 ether;
        vm.prank(relayerNode);
        vm.expectRevert(abi.encodeWithSignature("InvalidMerkleProof()"));
        vault.claim(req, sig, proof, root);

        // 场景 B：恢复 amount，篡改 recipient → Merkle 通过，EIP-712 不匹配 → InvalidSignature
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

        // Merkle leaf 不含 feeAmount → Merkle 通过；EIP-712 不匹配 → InvalidSignature
        req.feeAmount = 1_000 ether;
        vm.prank(relayerNode);
        vm.expectRevert(abi.encodeWithSignature("InvalidSignature()"));
        vault.claim(req, sig, proof, root);
    }

    /// @notice 提交不在 activeRoots 中的 root → InvalidRoot
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

    /// @notice 错误的 Merkle Proof（2 叶树只提供空 proof）→ InvalidMerkleProof
    function test_RevertIf_InvalidMerkleProof() public {
        uint256 stealthPk      = 0xA11CE;
        address stealthAddress = vm.addr(stealthPk);
        address stealthAddr2   = makeAddr("stealthAddr2");

        uint256 amount = 1_000 ether;
        bytes32 leaf1  = _leaf(stealthAddress, address(usdt), amount);
        bytes32 leaf2  = _leaf(stealthAddr2,   address(usdt), amount);
        bytes32 root   = _merkleRoot2(leaf1, leaf2);

        // 存入 2 倍总额
        _depositUSDT(root, 2 * amount);

        bytes32[] memory emptyProof = new bytes32[](0); // 刻意用错误的空 proof

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

    /// @notice high-s 签名被 OZ ECDSA 库拦截（ECDSAInvalidSignatureS）
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

        // 在块作用域内构造 high-s 签名，避免 stack too deep
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

            // high-s 变体：s2 = N - s（必然 > N/2），v 翻转
            uint256 N  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
            bytes32 s2 = bytes32(N - uint256(s));
            uint8   v2 = v == 27 ? 28 : 27;
            malleatedSig = abi.encodePacked(r, s2, v2);
        }

        // OZ ECDSA.recover 遇到 high-s 会 revert(ECDSAInvalidSignatureS)
        vm.prank(relayerNode);
        vm.expectRevert();
        vault.claim(req, malleatedSig, proof, root);
    }

    // -----------------------------------------------------------------------
    // 模糊测试 & Gas 测试
    // -----------------------------------------------------------------------

    /// @notice 单叶 Merkle（root = leaf，proof = []）的随机金额全流程测试
    function testFuzz_AllocationAndClaim(uint256 amount, uint256 feeAmount) public {
        vm.assume(amount > 0 && amount < 1e36);
        vm.assume(feeAmount <= amount);

        uint256 stealthPk      = 0xA11CE;
        address stealthAddress = vm.addr(stealthPk);
        address recip          = makeAddr("fuzz_recipient");

        // 单叶 Merkle：root = leaf，proof = []
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

    /// @notice Merkle 版 claim 的 Gas 基准
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
