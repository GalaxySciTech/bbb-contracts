const { expect } = require("chai");
const { ethers } = require("hardhat");

const XDC_VALIDATOR_ADDRESS = "0x0000000000000000000000000000000000000088";

describe("XDC Liquidity Staking", function () {
    let stakingPool;
    let bxdc;
    let withdrawalNFT;
    let mockValidator;
    let owner;
    let user1;
    let user2;

    beforeEach(async function () {
        [owner, user1, user2] = await ethers.getSigners();

        const MockXDCValidator = await ethers.getContractFactory("MockXDCValidator");
        mockValidator = await MockXDCValidator.deploy();
        await mockValidator.deployed();

        const WXDC = await ethers.getContractFactory("WXDC");
        const wxdc = await WXDC.deploy();
        await wxdc.deployed();

        const XDCLiquidityStaking = await ethers.getContractFactory("XDCLiquidityStaking");
        stakingPool = await XDCLiquidityStaking.deploy(mockValidator.address, wxdc.address);
        await stakingPool.deployed();

        bxdc = await ethers.getContractAt("bXDC", await stakingPool.bxdcToken());
        withdrawalNFT = await ethers.getContractAt("WithdrawalRequestNFT", await stakingPool.withdrawalNFT());
    });

    describe("部署", function () {
        it("应该正确设置初始状态", async function () {
            expect(await stakingPool.totalPooledXDC()).to.equal(0);
            expect(await bxdc.totalSupply()).to.equal(0);
            expect(await stakingPool.minStakeAmount()).to.equal(ethers.utils.parseEther("1"));
            expect(await stakingPool.minWithdrawAmount()).to.equal(ethers.utils.parseEther("0.1"));
            expect(await stakingPool.maxWithdrawablePercentage()).to.equal(80);
        });

        it("应该正确设置 bXDC 的质押池地址", async function () {
            expect(await bxdc.stakingPool()).to.equal(stakingPool.address);
        });
    });

    describe("质押功能", function () {
        it("应该允许用户质押 XDC 并获得 bXDC", async function () {
            const stakeAmount = ethers.utils.parseEther("100");

            await stakingPool.connect(user1).stake({ value: stakeAmount });

            expect(await bxdc.balanceOf(user1.address)).to.equal(stakeAmount);
            expect(await stakingPool.totalPooledXDC()).to.equal(stakeAmount);
        });

        it("初始兑换比例应该是 1:1", async function () {
            const exchangeRate = await stakingPool.getExchangeRate();
            expect(exchangeRate).to.equal(ethers.utils.parseEther("1"));
        });

        it("应该拒绝低于最小数量的质押", async function () {
            const smallAmount = ethers.utils.parseEther("0.5");

            await expect(
                stakingPool.connect(user1).stake({ value: smallAmount })
            ).to.be.revertedWith("Amount below minimum");
        });

        it("多个用户应该能够质押", async function () {
            await stakingPool.connect(user1).stake({ value: ethers.utils.parseEther("100") });
            await stakingPool.connect(user2).stake({ value: ethers.utils.parseEther("50") });

            expect(await bxdc.balanceOf(user1.address)).to.equal(ethers.utils.parseEther("100"));
            expect(await bxdc.balanceOf(user2.address)).to.equal(ethers.utils.parseEther("50"));
            expect(await stakingPool.totalPooledXDC()).to.equal(ethers.utils.parseEther("150"));
        });
    });

    describe("兑换比例", function () {
        beforeEach(async function () {
            await stakingPool.connect(user1).stake({ value: ethers.utils.parseEther("100") });
        });

        it("存入奖励后应该更新兑换比例", async function () {
            const rewardAmount = ethers.utils.parseEther("10");

            await stakingPool.connect(owner).depositRewards({ value: rewardAmount });

            const newRate = await stakingPool.getExchangeRate();
            expect(newRate).to.equal(ethers.utils.parseEther("1.1"));
        });

        it("新用户应该按新比例获得 bXDC", async function () {
            await stakingPool.connect(owner).depositRewards({ value: ethers.utils.parseEther("10") });

            await stakingPool.connect(user2).stake({ value: ethers.utils.parseEther("110") });

            const balance = await bxdc.balanceOf(user2.address);
            expect(balance).to.be.closeTo(ethers.utils.parseEther("100"), ethers.utils.parseEther("0.001"));
        });
    });

    describe("赎回功能 - 即时退出", function () {
        beforeEach(async function () {
            await stakingPool.connect(user1).stake({ value: ethers.utils.parseEther("100") });
        });

        it("有即时缓冲时应立即赎回", async function () {
            await stakingPool.connect(owner).addToInstantExitBuffer({ value: ethers.utils.parseEther("50") });

            const withdrawAmount = ethers.utils.parseEther("10");
            const balanceBefore = await ethers.provider.getBalance(user1.address);

            const tx = await stakingPool.connect(user1).withdraw(withdrawAmount);
            await tx.wait();

            const balanceAfter = await ethers.provider.getBalance(user1.address);
            const received = balanceAfter.sub(balanceBefore);
            expect(received).to.be.closeTo(ethers.utils.parseEther("10"), ethers.utils.parseEther("0.01"));
            expect(await bxdc.balanceOf(user1.address)).to.equal(ethers.utils.parseEther("90"));
        });

        it("应该正确计算赎回的 XDC 数量", async function () {
            await stakingPool.connect(owner).depositRewards({ value: ethers.utils.parseEther("10") });

            const withdrawbXDC = ethers.utils.parseEther("10");
            const expectedXDC = await stakingPool.getXDCBybXDC(withdrawbXDC);

            expect(expectedXDC).to.be.closeTo(ethers.utils.parseEther("11"), ethers.utils.parseEther("0.01"));
        });
    });

    describe("赎回功能 - NFT 退出", function () {
        beforeEach(async function () {
            await stakingPool.connect(user1).stake({ value: ethers.utils.parseEther("100") });
        });

        it("无即时缓冲时应铸造 NFT", async function () {
            const withdrawAmount = ethers.utils.parseEther("10");

            await stakingPool.connect(user1).withdraw(withdrawAmount);

            const batchId = await stakingPool.userWithdrawalBatches(user1.address, 0);
            expect(batchId).to.equal(0);
            const batch = await stakingPool.withdrawalBatches(0);
            expect(batch.xdcAmount).to.equal(ethers.utils.parseEther("10"));
            expect(await stakingPool.totalInUnbonding()).to.equal(ethers.utils.parseEther("10"));
        });

        it("解锁后应能赎回 NFT 获得 XDC", async function () {
            await stakingPool.connect(owner).setWithdrawDelayBlocks(5);

            await stakingPool.connect(user1).withdraw(ethers.utils.parseEther("10"));

            const unlockBlock = (await stakingPool.withdrawalBatches(0)).unlockBlock;
            const currentBlock = await ethers.provider.getBlockNumber();
            const blocksToMine = Number(unlockBlock) - currentBlock;
            for (let i = 0; i < blocksToMine; i++) {
                await ethers.provider.send("evm_mine", []);
            }

            const balanceBefore = await ethers.provider.getBalance(user1.address);
            await stakingPool.connect(user1).redeemWithdrawal(0);
            const balanceAfter = await ethers.provider.getBalance(user1.address);
            const received = balanceAfter.sub(balanceBefore);
            expect(received).to.be.closeTo(ethers.utils.parseEther("10"), ethers.utils.parseEther("0.01"));
        });
    });

    describe("Validator 资金管理", function () {
        beforeEach(async function () {
            await stakingPool.connect(user1).stake({ value: ethers.utils.parseEther("1000") });
        });

        it("管理员应该能够提取资金运行 validator", async function () {
            const withdrawAmount = ethers.utils.parseEther("800");
            const balanceBefore = await ethers.provider.getBalance(owner.address);

            const tx = await stakingPool.connect(owner).withdrawForValidator(withdrawAmount);
            const receipt = await tx.wait();
            const gasCost = receipt.gasUsed.mul(receipt.effectiveGasPrice);

            const balanceAfter = await ethers.provider.getBalance(owner.address);
            expect(balanceAfter.sub(balanceBefore).add(gasCost)).to.equal(withdrawAmount);
        });

        it("不应该允许提取超过最大比例", async function () {
            const withdrawAmount = ethers.utils.parseEther("850");

            await expect(
                stakingPool.connect(owner).withdrawForValidator(withdrawAmount)
            ).to.be.revertedWith("Exceeds max");
        });

        it("管理员应该能够存入奖励", async function () {
            const rewardAmount = ethers.utils.parseEther("50");
            const totalBefore = await stakingPool.totalPooledXDC();

            await stakingPool.connect(owner).depositRewards({ value: rewardAmount });

            const totalAfter = await stakingPool.totalPooledXDC();
            expect(totalAfter.sub(totalBefore)).to.equal(rewardAmount);
        });
    });

    describe("Operator 管理", function () {
        it("管理员应能添加 operator", async function () {
            await stakingPool.connect(owner).addOperator(user1.address);
            expect(await stakingPool.operators(user1.address)).to.equal(true);
        });

        it("管理员应能移除 operator", async function () {
            await stakingPool.connect(owner).addOperator(user1.address);
            await stakingPool.connect(owner).removeOperator(user1.address);
            expect(await stakingPool.operators(user1.address)).to.equal(false);
        });
    });

    describe("KYC", function () {
        it("LSP 应能提交 KYC", async function () {
            await stakingPool.connect(owner).submitKYC("ipfs://kyc-hash");
            expect(await stakingPool.lspKYCSubmitted()).to.equal(true);
        });
    });

    describe("参数管理", function () {
        it("管理员应该能够更新最小质押数量", async function () {
            await stakingPool.connect(owner).setMinStakeAmount(ethers.utils.parseEther("5"));
            expect(await stakingPool.minStakeAmount()).to.equal(ethers.utils.parseEther("5"));
        });

        it("管理员应该能够更新最小赎回数量", async function () {
            await stakingPool.connect(owner).setMinWithdrawAmount(ethers.utils.parseEther("1"));
            expect(await stakingPool.minWithdrawAmount()).to.equal(ethers.utils.parseEther("1"));
        });

        it("管理员应该能够更新最大可提取比例", async function () {
            await stakingPool.connect(owner).setMaxWithdrawablePercentage(70);
            expect(await stakingPool.maxWithdrawablePercentage()).to.equal(70);
        });

        it("非管理员不应该能够更新参数", async function () {
            await expect(
                stakingPool.connect(user1).setMinStakeAmount(ethers.utils.parseEther("5"))
            ).to.be.reverted;
        });
    });

    describe("暂停功能", function () {
        it("管理员应该能够暂停合约", async function () {
            await stakingPool.connect(owner).pause();
            expect(await stakingPool.paused()).to.equal(true);
        });

        it("暂停时不应该能够质押", async function () {
            await stakingPool.connect(owner).pause();

            await expect(
                stakingPool.connect(user1).stake({ value: ethers.utils.parseEther("100") })
            ).to.be.reverted;
        });

        it("管理员应该能够恢复合约", async function () {
            await stakingPool.connect(owner).pause();
            await stakingPool.connect(owner).unpause();

            expect(await stakingPool.paused()).to.equal(false);

            await stakingPool.connect(user1).stake({ value: ethers.utils.parseEther("100") });
        });
    });

    describe("完整流程测试", function () {
        it("应该正确处理完整的质押-奖励-赎回流程", async function () {
            await stakingPool.connect(user1).stake({ value: ethers.utils.parseEther("100") });
            await stakingPool.connect(user2).stake({ value: ethers.utils.parseEther("50") });

            expect(await stakingPool.totalPooledXDC()).to.equal(ethers.utils.parseEther("150"));
            expect(await bxdc.balanceOf(user1.address)).to.equal(ethers.utils.parseEther("100"));
            expect(await bxdc.balanceOf(user2.address)).to.equal(ethers.utils.parseEther("50"));

            await stakingPool.connect(owner).withdrawForValidator(ethers.utils.parseEther("120"));

            await owner.sendTransaction({
                to: stakingPool.address,
                value: ethers.utils.parseEther("120")
            });

            await stakingPool.connect(owner).depositRewards({ value: ethers.utils.parseEther("15") });

            expect(await stakingPool.totalPooledXDC()).to.equal(ethers.utils.parseEther("165"));

            const newRate = await stakingPool.getExchangeRate();
            expect(newRate).to.equal(ethers.utils.parseEther("1.1"));

            await stakingPool.connect(owner).addToInstantExitBuffer({ value: ethers.utils.parseEther("60") });

            await stakingPool.connect(user1).withdraw(ethers.utils.parseEther("50"));

            expect(await stakingPool.totalPooledXDC()).to.be.closeTo(ethers.utils.parseEther("110"), ethers.utils.parseEther("0.01"));
            expect(await bxdc.totalSupply()).to.equal(ethers.utils.parseEther("100"));

            const finalRate = await stakingPool.getExchangeRate();
            expect(finalRate).to.equal(ethers.utils.parseEther("1.1"));
        });
    });
});
