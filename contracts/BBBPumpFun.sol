pragma solidity =0.8.23;

import {PointToken, Ownable} from "./extensions/PointToken.sol";
import {MegadropBBB} from "./MegadropBBB.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IWETH} from "./extensions/IWETH.sol";

contract BBBPumpFun is Ownable, ReentrancyGuard {
    struct DropToken {
        uint256 index;
        address token;
        string name;
        string symbol;
        uint256 deployFee;
        address deployer;
        uint256 snapshotId;
        uint256 maxXdc;
        uint256 removed;
        uint256 xdcAmount;
        uint256 createTime;
        uint256 dropAmt;
        string imageUrl;
        string description;
        string website;
        string telegram;
        string twitter;
    }

    struct Kline {
        uint256 time;
        uint256 open;
        uint256 close;
        uint256 tradeAmt;
    }

    DropToken[] public dropTokens;

    mapping(uint256 => Kline[]) public klineMap;

    mapping(address => mapping(uint256 => bool)) public claimed;

    address public megadropBBBV1;

    address public uniswapV2Factory;

    uint256 public deployFee;

    uint256 public deployMaxXdc;

    address public weth;

    uint256 public swapFee;

    address public foundation;

    uint256 public constant k = 2e25;

    mapping(address => mapping(address => bool)) public delegateAllowance;

    mapping(address => uint256) public tokenMapping;

    event Drop(
        uint256 index,
        address token,
        string name,
        string symbol,
        uint256 deployFee,
        address deployer,
        uint256 maxXdc,
        uint256 createTime
    );

    event Trade(
        uint256 indexed index,
        address indexed token,
        string tradeType,
        uint256 time,
        uint256 open,
        uint256 close,
        uint256 xdcAmount,
        uint256 tokenAmount
    );

    constructor() Ownable(msg.sender) {
        foundation = 0x2475Dcd4Fe333bE814Ef7C8f8CE8A1E9B5FcDEA0;
        //mainnet
        // deployFee = 0 ether;
        // megadropBBBV1 = 0x37c00AE5C4b49Ab0F5fD2FFB1033588e9bC33B08;
        // uniswapV2Factory = 0x347D14b13a68457186b2450bb2a6c2Fd7B38352f;
        // deployMaxXdc = 1e7 ether;
        // weth = 0x951857744785e80e2de051c32ee7b25f9c458c42;
        // swapFee = 100;

        //devnet
        deployFee = 0 ether;
        megadropBBBV1 = 0xb89D5cb86f2403ca602Ee45a687437a9F0Ce1C9c;
        uniswapV2Factory = 0x295CE027f21D45bc08386d8c59f51bE5f38a01C1;
        deployMaxXdc = 10000 ether;
        weth = 0x7025d0a3AC01AE31469a9eC018D54A0fe3A30dE9;
        swapFee = 100;
    }

    function getKlineLength(uint256 index) external view returns (uint256) {
        return klineMap[index].length;
    }

    function uploadToken(
        uint256 index,
        string calldata imageUrl,
        string calldata description,
        string calldata website,
        string calldata telegram,
        string calldata twitter
    ) external {
        DropToken storage dropTokenStorage = dropTokens[index - 1];
        require(
            dropTokenStorage.deployer == msg.sender,
            "MegadropBBBV2: must deployer"
        );
        dropTokenStorage.imageUrl = imageUrl;
        dropTokenStorage.description = description;
        dropTokenStorage.website = website;
        dropTokenStorage.telegram = telegram;
        dropTokenStorage.twitter = twitter;
    }

    function drop(
        string calldata name,
        string calldata symbol,
        string calldata imageUrl,
        string calldata description,
        string calldata website,
        string calldata telegram,
        string calldata twitter
    ) external payable nonReentrant {
        require(msg.value >= deployFee, "MegadropBBBV2: incorrect value");
        require(
            bytes(name).length <= 20 && bytes(name).length > 0,
            "MegadropBBBV2: name need less 20 bytes and gt 0 bytes"
        );
        require(
            bytes(symbol).length <= 10 && bytes(symbol).length > 0,
            "MegadropBBBV2: symbol need less 10 bytes and gt 0 bytes"
        );
        require(
            bytes(imageUrl).length <= 256 && bytes(imageUrl).length > 0,
            "MegadropBBBV2: imageUrl need less 256 bytes and gt 0 bytes"
        );
        require(
            bytes(description).length <= 256 && bytes(description).length > 0,
            "MegadropBBBV2: description need less 256 bytes and gt 0 bytes"
        );
        require(
            bytes(website).length <= 256,
            "MegadropBBBV2: website need less 256 bytes"
        );
        require(
            bytes(telegram).length <= 256,
            "MegadropBBBV2: telegram need less 256 bytes"
        );
        require(
            bytes(twitter).length <= 256,
            "MegadropBBBV2: twitter need less 256 bytes"
        );
        payable(foundation).transfer(msg.value);
        PointToken dropToken = new PointToken(name, symbol);

        uint256 index = dropTokens.length + 1;
        dropTokens.push(
            DropToken(
                index,
                address(dropToken),
                name,
                symbol,
                deployFee,
                msg.sender,
                0,
                deployMaxXdc,
                0,
                0,
                block.timestamp,
                0,
                imageUrl,
                description,
                website,
                telegram,
                twitter
            )
        );
        tokenMapping[address(dropToken)] = index;

        emit Drop(
            index,
            address(dropToken),
            name,
            symbol,
            deployFee,
            msg.sender,
            deployMaxXdc,
            block.timestamp
        );
    }

    function getBuyAmount(
        uint256 index,
        uint256 amount
    ) public view returns (uint256) {
        DropToken memory dropToken = getDropToken(index);
        uint256 totalSupply = PointToken(dropToken.token).totalSupply();
        uint256 buyAmount = Math.sqrt(totalSupply ** 2 + k * amount) -
            totalSupply;
        return buyAmount;
    }

    function getSellAmount(
        uint256 index,
        uint256 amount
    ) public view returns (uint256) {
        DropToken memory dropToken = getDropToken(index);
        uint256 totalSupply = PointToken(dropToken.token).totalSupply();
        uint256 newTotalSupply = totalSupply - amount;
        uint256 refund = (totalSupply ** 2 - newTotalSupply ** 2) / k;
        return refund;
    }

    function price(uint256 index) public view returns (uint256) {
        DropToken memory dropToken = getDropToken(index);

        return Math.sqrt((dropToken.xdcAmount * 1e36) / k);
    }

    function buy(uint256 index) external payable nonReentrant {
        require(msg.value > 0, "MegadropBBBV2: value must greater than 0");
        DropToken memory dropToken = getDropToken(index);
        require(
            dropToken.removed == 0,
            "MegadropBBBV2: liquilty already removed"
        );
        DropToken storage dropTokenStorage = dropTokens[index - 1];
        uint256 xdcAmount = dropToken.xdcAmount;
        uint256 xdcSwapFee = (msg.value * swapFee) / 10000;
        uint256 newBuyXdcAmount = msg.value - xdcSwapFee;
        if (xdcSwapFee > 0) {
            payable(foundation).transfer(xdcSwapFee);
        }
        uint256 open = price(index);
        uint256 moveLiq = 0;

        if (xdcAmount + newBuyXdcAmount >= dropToken.maxXdc) {
            uint256 maxBuyXdcAmount = dropToken.maxXdc - xdcAmount;
            payable(msg.sender).transfer(newBuyXdcAmount - maxBuyXdcAmount);
            newBuyXdcAmount = maxBuyXdcAmount;
            moveLiq = 1;
            dropTokenStorage.xdcAmount = dropToken.maxXdc;
        } else {
            dropTokenStorage.xdcAmount += newBuyXdcAmount;
        }
        uint256 buyAmount = getBuyAmount(index, newBuyXdcAmount);

        PointToken(dropToken.token).mint(msg.sender, buyAmount);
        uint256 close = price(index);
        if (moveLiq == 1) {
            moveLiquidity(index);
        }

        klineMap[index].push(Kline(block.timestamp, open, close, buyAmount));
        emit Trade(
            index,
            dropToken.token,
            "buy",
            block.timestamp,
            open,
            close,
            newBuyXdcAmount,
            buyAmount
        );
    }

    function moveLiquidity(uint256 index) private {
        DropToken storage dropToken = dropTokens[index - 1];

        address pair = IUniswapV2Factory(uniswapV2Factory).getPair(
            weth,
            dropToken.token
        );

        if (pair == address(0)) {
            pair = IUniswapV2Factory(uniswapV2Factory).createPair(
                weth,
                dropToken.token
            );
        }

        uint256 xdcAmount = dropToken.xdcAmount;
        uint256 totalSupply = PointToken(dropToken.token).totalSupply();
        uint256 newMint = totalSupply;
        dropToken.dropAmt = (totalSupply * 2) / 100;
        IWETH(weth).deposit{value: xdcAmount}();
        PointToken(dropToken.token).mint(address(this), newMint);

        PointToken(dropToken.token).transfer(pair, newMint);
        IWETH(weth).transfer(pair, xdcAmount);

        IUniswapV2Pair(pair).mint(address(this));

        dropToken.removed = 1;

        uint256 snapshotId = MegadropBBB(megadropBBBV1).clock();
        dropToken.snapshotId = snapshotId;
        MegadropBBB(megadropBBBV1)._snapshot();
    }

    function sell(uint256 index, uint256 amount) external nonReentrant {
        require(amount > 0, "MegadropBBBV2: amount must greater than 0");
        DropToken memory dropToken = getDropToken(index);
        require(
            dropToken.removed == 0,
            "MegadropBBBV2: liquilty already removed"
        );
        uint256 open = price(index);
        uint256 refund = getSellAmount(index, amount);
        DropToken storage dropTokenStorage = dropTokens[index - 1];
        dropTokenStorage.xdcAmount -= refund;

        PointToken(dropToken.token).burnFrom(msg.sender, amount);

        uint256 refundSwapFee = (refund * swapFee) / 10000;
        refund -= refundSwapFee;
        payable(msg.sender).transfer(refund);

        if (refundSwapFee > 0) {
            payable(foundation).transfer(refundSwapFee);
        }

        if (dropTokenStorage.xdcAmount <= 10) {
            payable(foundation).transfer(dropTokenStorage.xdcAmount);
            dropTokenStorage.xdcAmount = 0;
        }

        uint256 close = price(index);

        klineMap[index].push(Kline(block.timestamp, open, close, amount));

        emit Trade(
            index,
            dropToken.token,
            "sell",
            block.timestamp,
            open,
            close,
            refund,
            amount
        );
    }

    function claim(uint256 index, address account) external {
        if (!claimed[msg.sender][index]) {
            DropToken memory dropToken = getDropToken(index);
            uint256 claimAmt = getClaimAmt(index, account);
            PointToken(dropToken.token).mint(msg.sender, claimAmt);
            claimed[account][index] = true;
        }
    }

    function getClaimAmt(
        uint256 index,
        address account
    ) public view returns (uint256) {
        DropToken memory dropToken = getDropToken(index);
        if (dropToken.snapshotId == 0) return 0;
        uint256 snapshotTotalSupply = MegadropBBB(megadropBBBV1)
            .getPastTotalSupply(dropToken.snapshotId);
        if (snapshotTotalSupply == 0) {
            return 0;
        }
        uint256 snapshotAmt = MegadropBBB(megadropBBBV1).getPastVotes(
            account,
            dropToken.snapshotId
        );
        uint256 airdropAmt = dropToken.dropAmt;
        uint256 claimAmt = (airdropAmt * snapshotAmt) / snapshotTotalSupply;
        return claimAmt;
    }

    function getDropToken(
        uint256 index
    ) public view returns (DropToken memory) {
        require(
            index > 0 && index <= dropTokens.length,
            "MegadropBBBV2: Invalid index"
        );
        DropToken memory dropToken = dropTokens[index - 1];
        require(
            dropToken.token != address(0),
            "MegadropBBBV2: invalid drop token"
        );
        return dropToken;
    }

    function getDropTokenByAddress(
        address token
    ) public view returns (DropToken memory) {
        uint256 index = tokenMapping[token];
        return getDropToken(index);
    }

    function getDropTokenLength() external view returns (uint256) {
        return dropTokens.length;
    }

    function setDeployFee(uint256 _deployFee) external onlyOwner {
        deployFee = _deployFee;
    }

    function setDeployMaxXdc(uint256 _deployMaxXdc) external onlyOwner {
        deployMaxXdc = _deployMaxXdc;
    }

    function setSwapFee(uint256 _swapFee) external onlyOwner {
        swapFee = _swapFee;
    }
}
