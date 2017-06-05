pragma solidity ^0.4.8;

import "./ERC20.sol";

//Desicion made.
// 1 - Provider is solely responsible to consider failed sub charge as an error and stop Service,
//    therefore there is no separate error state or counter for that in Token Contract

//ToDo:
// 4 - check: all functions for access modifiers: _from, _to, _others
// 5 - check: all function for re-entrancy
// 6 - check: all _paymentData

//Ask:
// Given: subscription one year:

contract ExtERC20 is ERC20, SubscriptionBase {
    function paymentTo(PaymentListener _to, uint _value, bytes _paymentData) returns (bool success);
    function paymentFrom(address _from, PaymentListener _to, uint _value, bytes _paymentData) returns (bool success);

    function createSubscriptionOffer(uint _price, uint _chargePeriod, uint _expireOn, uint _offerLimit, uint _depositValue, uint _startOn, bytes _descriptor) returns (uint subId);
    function acceptSubscriptionOffer(uint _offerId, uint _expireOn, uint _startOn) returns (uint newSubId);
    function cancelSubscription(uint subId);
    function cancelSubscription(uint subId, uint gasReserve);
    function holdSubscription (uint subId) returns (bool success);
    function unholdSubscription(uint subId) returns (bool success);
    function executeSubscription(uint subId) returns (bool success);
    function postponeDueDate(uint subId, uint newDueDate);
    function currentStatus(uint subId) constant returns(Status status);

    function paybackSubscriptionDeposit(uint subId);
    function createDeposit(uint _value, bytes _descriptor) returns (uint subId);
    function claimDeposit(uint depositId);

    enum PaymentStatus {OK, BALANCE_ERROR, APPROVAL_ERROR}

    event Payment(address _from, address _to, uint _value, uint _fee, address caller, PaymentStatus status, uint subId);

}

contract ExtERC20Impl is ExtERC20, ERC20Impl {
    address public beneficiary;
    address public admin;  //admin should be a multisig contract implementing advanced sign/recovery strategies
    uint PLATFORM_FEE_PER_10000 = 1; //0,01%

    function ExtERC20Impl() {
        beneficiary = admin = msg.sender;
    }

    function setPlatformFeePer10000(uint newFee) public only(admin) {
        assert (newFee <= 10000); //formally maximum fee is 100% (completely insane but technically possible)
        PLATFORM_FEE_PER_10000 = newFee;
    }

    function setAdmin(address newAdmin) public only(admin) {
        admin = newAdmin;
    }

    function setBeneficiary(address newBeneficiary) public only(admin) {
        beneficiary = newBeneficiary;
    }

    //ToDo: move addresses behind the value (preventing zero-trailing address attack)
    function paymentTo(PaymentListener _to, uint _value, bytes _paymentData) public returns (bool success) {
        if (_fulfillPayment(msg.sender, _to, _value, 0)) {
            // a PaymentListener (a ServiceProvider) has here an opportunity verify and reject the payment
            assert (PaymentListener(_to).onPayment(msg.sender, _value, _paymentData));
            return true;
        } else if (tx.origin==msg.sender) { throw; }
          else { return false; }
    }

    //ToDo: move addresses behind the value (preventing zero-trailing address attack)
    function paymentFrom(address _from, PaymentListener _to, uint _value, bytes _paymentData) public returns (bool success) {
        if (_fulfillPreapprovedPayment(_from, _to, _value)) {
            // a PaymentListener (a ServiceProvider) has here an opportunity verify and reject the payment
            assert (PaymentListener(_to).onPayment(_from, _value, _paymentData));
            return true;
        } else if (tx.origin==msg.sender) { throw; }
          else { return false; }
    }

    function executeSubscription(uint subId) public returns (bool) {
        Subscription storage sub = subscriptions[subId];
        if (_currentStatus(sub)==Status.CHARGEABLE) {
            var _from = sub.transferFrom;
            var _to = sub.transferTo;
            var _value = _amountToCharge(sub);
            if (_fulfillPayment(_from, _to, _value, subId)) {
                sub.paidUntil  = max(sub.paidUntil, sub.startOn) + sub.chargePeriod;
                ++sub.execCounter;
                // a PaymentListener (a ServiceProvider) has here an opportunity verify and reject the payment
                assert (PaymentListener(_to).onSubExecuted(subId));
                return true;
            }
        }
        //ToDo: Possible another solution: throw always, but catch in caller.
        if (tx.origin==msg.sender) { throw; }
        else { return false; }
    }

    function postponeDueDate(uint subId, uint newDueDate) public {
        Subscription storage sub = subscriptions[subId];
        assert (sub.transferTo == msg.sender); //only Service Provider is allowed to postpone the DueDate
        if (sub.paidUntil < newDueDate) sub.paidUntil = newDueDate;
    }

    function _fulfillPreapprovedPayment(address _from, address _to, uint _value) internal returns (bool success) {
        success = _from != msg.sender && allowed[_from][msg.sender] >= _value;
        if (!success) {
            Payment(_from, _to, _value, _fee(_value), msg.sender, PaymentStatus.APPROVAL_ERROR, 0);
        } else {
            success = _fulfillPayment(_from, _to, _value, 0);
            if (success) {
                allowed[_from][msg.sender] -= _value;
            }
        }
        return success;
    }

    function _fulfillPayment(address _from, address _to, uint _value, uint subId) internal returns (bool success) {
        var fee = _fee(_value);
        assert (fee <= _value); //internal sanity check
        if (balances[_from] >= _value && balances[_to] + _value > balances[_to]) {
            balances[_from] -= _value;
            balances[_to] += _value - fee;
            balances[beneficiary] += fee;
            Payment(_from, _to, _value, fee, msg.sender,PaymentStatus.OK, subId);
            return true;
        } else {
            Payment(_from, _to, _value, fee, msg.sender, PaymentStatus.BALANCE_ERROR, subId);
            return false;
        }
    }

    function _fee(uint _value) internal constant returns (uint fee) {
        return _value * PLATFORM_FEE_PER_10000 / 10000;
    }

    function currentStatus(uint subId) public constant returns(Status status) {
        return _currentStatus(subscriptions[subId]);
    }

    function _currentStatus(Subscription storage sub) internal constant returns(Status status) {
        if (sub.onHoldSince>0) {
            return Status.ON_HOLD;
        } else if (sub.transferFrom==0) {
            return Status.OFFER;
        } else if (sub.paidUntil >= sub.expireOn) {
            return now < sub.expireOn
                ? Status.CANCELED
                : Status.EXPIRED;
        } else if (sub.paidUntil <= now) {
            return Status.CHARGEABLE;
        } else {
            return Status.PAID;
        }
    }

    function createSubscriptionOffer(uint _price, uint _chargePeriod, uint _expireOn, uint _offerLimit, uint _depositAmount, uint _startOn, bytes _descriptor) public returns (uint subId) {
        subscriptions[++subscriptionCounter] = Subscription ({
            transferFrom : 0,
            transferTo   : msg.sender,
            pricePerHour : _price,
            paidUntil    : 0,
            chargePeriod : _chargePeriod,
            depositAmount: _depositAmount,
            startOn      : _startOn,
            expireOn     : _expireOn,
            execCounter  : _offerLimit,
            descriptor   : _descriptor,
            onHoldSince  : 0
        });
        return subscriptionCounter;
    }

    function acceptSubscriptionOffer(uint _offerId, uint _expireOn, uint _startOn) public returns (uint newSubId) {
        Subscription storage offer = subscriptions[_offerId];
        assert(offer.startOn == 0  || offer.startOn <= now);
        assert(offer.expireOn == 0 || offer.expireOn > now);
        assert(offer.execCounter-- > 0);

        newSubId = subscriptionCounter + 1;
        //create a clone of the offer...
        Subscription storage newSub = subscriptions[newSubId] = offer;
        //... and adjust some fields specific to subscription
        newSub.transferFrom = msg.sender;
        newSub.execCounter = 0;
        newSub.paidUntil = newSub.startOn = max(_startOn, now);
        newSub.expireOn = _expireOn;

        //depositAmount is stored in the sub: so burn it from customer's account.
        assert (_burn(newSub.depositAmount));
        assert (PaymentListener(newSub.transferTo).onSubNew(newSubId, _offerId));
        NewSubscription(newSub.transferFrom, newSub.transferTo, _offerId, newSubId);
        return (subscriptionCounter = newSubId);
    }

    function cancelSubscription(uint subId) public {
        return cancelSubscription(subId, 0);
    }

    function cancelSubscription(uint subId, uint gasReserve) public {
        Subscription storage sub = subscriptions[subId];
        var _to = sub.transferTo;
        sub.expireOn = max(now, sub.paidUntil);
        if (msg.sender != _to) {
            //supress handler throwing error; reserve enough gas to finish the call
            //don't evaluate .call's return value because it is an event handler (fired and forgot)
            _to.call.gas(msg.gas-max(gasReserve,1000))(bytes4(sha3("onSubCanceled(uint)")), subId);
        }
    }


    function claimSubscriptionDeposit(uint subId) public {
        assert (currentStatus(subId) == Status.EXPIRED);
        assert (subscriptions[subId].transferFrom == msg.sender);
        var depositAmount = subscriptions[subId].depositAmount;
        subscriptions[subId].depositAmount = 0;
        balances[msg.sender]+=depositAmount;
    }

    // a service can allow/disallow a hold/unhold request
    function holdSubscription (uint subId) public returns (bool success) {
        Subscription storage sub = subscriptions[subId];
        if (sub.onHoldSince > 0) { return true; }
        var _to = sub.transferTo;
        if (msg.sender == _to || PaymentListener(_to).onSubUnHold(subId, true)) {
            sub.onHoldSince = now;
            return true;
        } else { return false; }
    }

    // a service can allow/disallow a hold/unhold request
    function unholdSubscription(uint subId) public returns (bool success) {
        Subscription storage sub = subscriptions[subId];
        if (sub.onHoldSince == 0) { return true; }
        var _to = sub.transferTo;
        if (msg.sender == _to || PaymentListener(_to).onSubUnHold(subId, false)) {
            sub.paidUntil += now - sub.onHoldSince;
            sub.onHoldSince = 0;
            return true;
        } else { return false; }
    }

    function createDeposit(uint _value, bytes _descriptor) public returns (uint subId) {
      return _createDeposit(msg.sender, _value, _descriptor);
    }

    function claimDeposit(uint depositId) public {
        return _claimDeposit(depositId, msg.sender);
    }

    function paybackSubscriptionDeposit(uint subId) public {
        assert (currentStatus(subId) == Status.EXPIRED);
        var depositAmount = subscriptions[subId].depositAmount;
        assert (depositAmount > 0);
        balances[subscriptions[subId].transferFrom] += depositAmount;
        subscriptions[subId].depositAmount = 0;
    }

    function _createDeposit(address owner, uint _value, bytes _descriptor) internal returns (uint depositId) {
        if (balances[owner] >= _value) {
            balances[owner] -= _value;
            deposits[++depositCounter] = Deposit ({
                owner : owner,
                value : _value,
                descriptor : _descriptor
            });
            NewDeposit(depositCounter, _value, owner);
            return depositCounter;
        } else { throw; } //ToDo:
    }

    function _claimDeposit(uint depositId, address returnTo) internal {
        if (deposits[depositId].owner == returnTo) {
            balances[returnTo] += deposits[depositId].value;
            delete deposits[depositId];
            DepositClosed(depositId);
        } else { throw; }
    }

    function _amountToCharge(Subscription storage sub) internal returns (uint) {
        return sub.pricePerHour * sub.chargePeriod / 1 hours;
    }

    function _burn(uint amount) internal returns (bool success){
        if (balances[msg.sender] >= amount) {
            balances[msg.sender] -= amount;
            return true;
        } else { return false; }
    }

    mapping (uint => Subscription) public subscriptions;
    mapping (uint => Deposit) public deposits;
    uint public subscriptionCounter = 0;
    uint public depositCounter = 0;

}
