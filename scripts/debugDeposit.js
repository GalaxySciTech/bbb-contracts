const { ethers } = require("hardhat");

async function debugDeposit() {
    console.log("=== Debug Deposit Issues ===\n");
    
    // Replace these with your actual addresses
    const SUSDB_ADDRESS = "YOUR_SUSDB_CONTRACT_ADDRESS"; // Replace this
    const USDB_ADDRESS = "0xA23885c8E0743C734Bd6Da0df66e2631Ee9Bc6D8";

    const [user] = await ethers.getSigners();
    
    console.log("User address:", user.address);
    console.log("sUSDB address:", SUSDB_ADDRESS);
    console.log("USDB address:", USDB_ADDRESS);
    
    try {
        // Get contract instances
        const sUSDB = await ethers.getContractAt("sUSDB", SUSDB_ADDRESS);
        const USDB = await ethers.getContractAt("IERC20", USDB_ADDRESS);

        console.log("\n=== Contract Information ===");
        const underlyingAddr = await sUSDB.underlying();
        console.log("sUSDB underlying token:", underlyingAddr);
        console.log("Expected USDB address:", USDB_ADDRESS);
        console.log("Addresses match:", underlyingAddr.toLowerCase() === USDB_ADDRESS.toLowerCase());

        console.log("\n=== Balance Checks ===");
        const usdbBalance = await USDB.balanceOf(user.address);
        const sUsdbBalance = await sUSDB.balanceOf(user.address);
        
        console.log("User USDB balance:", ethers.formatUnits(usdbBalance, 6));
        console.log("User sUSDB balance:", ethers.formatUnits(sUsdbBalance, 6));

        // Test with small amount
        const testAmount = ethers.parseUnits("1", 6); // 1 USDB
        
        console.log("\n=== Allowance Checks ===");
        const currentAllowance = await USDB.allowance(user.address, SUSDB_ADDRESS);
        console.log("Current allowance:", ethers.formatUnits(currentAllowance, 6));
        console.log("Test amount:", ethers.formatUnits(testAmount, 6));
        console.log("Sufficient allowance:", currentAllowance >= testAmount);

        if (usdbBalance < testAmount) {
            console.log("\n❌ ERROR: Insufficient USDB balance for test");
            return;
        }

        if (currentAllowance < testAmount) {
            console.log("\n=== Approving USDB ===");
            try {
                const approveTx = await USDB.approve(SUSDB_ADDRESS, testAmount);
                console.log("Approve transaction hash:", approveTx.hash);
                await approveTx.wait();
                console.log("✅ Approval successful");
                
                const newAllowance = await USDB.allowance(user.address, SUSDB_ADDRESS);
                console.log("New allowance:", ethers.formatUnits(newAllowance, 6));
            } catch (error) {
                console.log("❌ Approval failed:", error.message);
                return;
            }
        }

        console.log("\n=== Testing Deposit ===");
        
        // Check contract state before deposit
        console.log("Contract USDB balance before:", ethers.formatUnits(await USDB.balanceOf(SUSDB_ADDRESS), 6));
        console.log("Total sUSDB supply before:", ethers.formatUnits(await sUSDB.totalSupply(), 6));
        
        try {
            // Estimate gas first
            const gasEstimate = await sUSDB.deposit.estimateGas(testAmount);
            console.log("Estimated gas:", gasEstimate.toString());
            
            // Try the deposit
            const depositTx = await sUSDB.deposit(testAmount);
            console.log("Deposit transaction hash:", depositTx.hash);
            
            const receipt = await depositTx.wait();
            console.log("✅ Deposit successful!");
            console.log("Gas used:", receipt.gasUsed.toString());
            
            // Check balances after
            const newUsdbBalance = await USDB.balanceOf(user.address);
            const newSUsdbBalance = await sUSDB.balanceOf(user.address);
            
            console.log("\n=== Results ===");
            console.log("New USDB balance:", ethers.formatUnits(newUsdbBalance, 6));
            console.log("New sUSDB balance:", ethers.formatUnits(newSUsdbBalance, 6));
            console.log("Contract USDB balance:", ethers.formatUnits(await USDB.balanceOf(SUSDB_ADDRESS), 6));
            console.log("Total sUSDB supply:", ethers.formatUnits(await sUSDB.totalSupply(), 6));
            
        } catch (error) {
            console.log("❌ Deposit failed:", error.message);
            
            // Try to get more detailed error information
            if (error.data) {
                console.log("Error data:", error.data);
            }
            
            // Check if it's a revert with reason
            if (error.reason) {
                console.log("Revert reason:", error.reason);
            }
            
            // Additional debugging
            console.log("\n=== Debug Information ===");
            console.log("Is contract deployed?", await ethers.provider.getCode(SUSDB_ADDRESS) !== "0x");
            console.log("User USDB balance:", ethers.formatUnits(await USDB.balanceOf(user.address), 6));
            console.log("Allowance:", ethers.formatUnits(await USDB.allowance(user.address, SUSDB_ADDRESS), 6));
            
            // Check if USDB contract is working
            try {
                const usdbName = await USDB.name();
                console.log("USDB contract name:", usdbName);
            } catch (e) {
                console.log("❌ USDB contract not accessible:", e.message);
            }
        }

    } catch (error) {
        console.log("❌ Setup failed:", error.message);
    }
}

// Quick contract verification
async function verifyContract() {
    const SUSDB_ADDRESS = "YOUR_SUSDB_CONTRACT_ADDRESS"; // Replace this
    
    try {
        const sUSDB = await ethers.getContractAt("sUSDB", SUSDB_ADDRESS);
        
        console.log("=== Contract Verification ===");
        console.log("Name:", await sUSDB.name());
        console.log("Symbol:", await sUSDB.symbol());
        console.log("Decimals:", await sUSDB.decimals());
        console.log("Underlying:", await sUSDB.underlying());
        console.log("Owner:", await sUSDB.owner());
        console.log("Withdrawal delay:", await sUSDB.WITHDRAWAL_DELAY());
        
        console.log("✅ Contract verification successful");
        
    } catch (error) {
        console.log("❌ Contract verification failed:", error.message);
    }
}

async function main() {
    console.log("Choose debug option:");
    console.log("1. Verify contract");
    console.log("2. Debug deposit");
    
    // For now, run both
    await verifyContract();
    console.log("\n" + "=".repeat(50) + "\n");
    await debugDeposit();
}

module.exports = { debugDeposit, verifyContract };

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    }); 