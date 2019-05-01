//  
//  Created by Sam Westrich
//  Copyright © 2019 Dash Core Group. All rights reserved.
//
//  Licensed under the MIT License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  https://opensource.org/licenses/MIT
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "DSIncomingFundsDerivationPath.h"
#import "DSDerivationPath+Protected.h"
#import "DSBlockchainUser.h"
#import "DSContactEntity+CoreDataClass.h"
#import "DSAccount.h"

@interface DSIncomingFundsDerivationPath()

@property (nonatomic, strong) NSMutableArray *externalAddresses;

@property (nonatomic,assign) UInt256 contactBlockchainUserRegistrationTransactionHash;

@end

@implementation DSIncomingFundsDerivationPath

+ (instancetype)contactBasedDerivationPathForBlockchainUserRegistrationTransactionHash:(UInt256)blockchainUserRegistrationTransactionHash forAccountNumber:(uint32_t)accountNumber onChain:(DSChain*)chain {
    NSUInteger coinType = (chain.chainType == DSChainType_MainNet)?5:1;
    UInt256 indexes[] = {uint256_from_long(FEATURE_PURPOSE), uint256_from_long(coinType), uint256_from_long(5), uint256_from_long(1), uint256_from_long(accountNumber), blockchainUserRegistrationTransactionHash};
    BOOL hardenedIndexes[] = {YES,YES,YES,YES,YES,NO};
    //todo full uint256 derivation
    DSIncomingFundsDerivationPath * derivationPath = [self derivationPathWithIndexes:indexes hardened:hardenedIndexes length:6 type:DSDerivationPathType_ClearFunds signingAlgorithm:DSDerivationPathSigningAlgorith_ECDSA reference:DSDerivationPathReference_ContactBasedFunds onChain:chain];
    
    derivationPath.contactBlockchainUserRegistrationTransactionHash = blockchainUserRegistrationTransactionHash;
    
    return derivationPath;
}

- (instancetype)initWithIndexes:(const UInt256 [])indexes hardened:(const BOOL [])hardenedIndexes length:(NSUInteger)length type:(DSDerivationPathType)type signingAlgorithm:(DSDerivationPathSigningAlgorith)signingAlgorithm reference:(DSDerivationPathReference)reference onChain:(DSChain *)chain {
    
    if (! (self = [super initWithIndexes:indexes hardened:hardenedIndexes length:length type:type signingAlgorithm:signingAlgorithm reference:reference onChain:chain])) return nil;
    
    self.externalAddresses = [NSMutableArray array];
    
    return self;
}

-(void)reloadAddresses {
    self.externalAddresses = [NSMutableArray array];
    [self.mUsedAddresses removeAllObjects];
    self.addressesLoaded = NO;
    [self loadAddresses];
}

-(void)loadAddresses {
    if (!self.addressesLoaded) {
        [self.moc performBlockAndWait:^{
            [DSAddressEntity setContext:self.moc];
            [DSTransactionEntity setContext:self.moc];
            DSDerivationPathEntity * derivationPathEntity = [DSDerivationPathEntity derivationPathEntityMatchingDerivationPath:self];
            self.syncBlockHeight = derivationPathEntity.syncBlockHeight;
            for (DSAddressEntity *e in derivationPathEntity.addresses) {
                @autoreleasepool {
                    NSMutableArray *a = self.externalAddresses;
                    
                    while (e.index >= a.count) [a addObject:[NSNull null]];
                    if (![e.address isValidDashAddressOnChain:self.account.wallet.chain]) {
                        DSDLog(@"address %@ loaded but was not valid on chain %@",e.address,self.account.wallet.chain.name);
                        continue;
                    }
                    a[e.index] = e.address;
                    [self.mAllAddresses addObject:e.address];
                    if ([e.usedInInputs count] || [e.usedInOutputs count]) {
                        [self.mUsedAddresses addObject:e.address];
                    }
                }
            }
        }];
        self.addressesLoaded = TRUE;
        [self registerAddressesWithGapLimit:SEQUENCE_GAP_LIMIT_EXTERNAL];
        
    }
}

// MARK: - Derivation Path Addresses

- (void)registerTransactionAddress:(NSString * _Nonnull)address {
    if ([self containsAddress:address]) {
        if (![self.mUsedAddresses containsObject:address]) {
            [self.mUsedAddresses addObject:address];
            [self registerAddressesWithGapLimit:SEQUENCE_GAP_LIMIT_EXTERNAL];
        }
    }
}

// Wallets are composed of chains of addresses. Each chain is traversed until a gap of a certain number of addresses is
// found that haven't been used in any transactions. This method returns an array of <gapLimit> unused addresses
// following the last used address in the chain. The internal chain is used for change addresses and the external chain
// for receive addresses.
- (NSArray *)registerAddressesWithGapLimit:(NSUInteger)gapLimit
{
    if (!self.account.wallet.isTransient) {
        NSAssert(self.addressesLoaded, @"addresses must be loaded before calling this function");
    }
    
    NSMutableArray *a = [NSMutableArray arrayWithArray:self.externalAddresses];
    NSUInteger i = a.count;
    
    // keep only the trailing contiguous block of addresses with no transactions
    while (i > 0 && ! [self.usedAddresses containsObject:a[i - 1]]) {
        i--;
    }
    
    if (i > 0) [a removeObjectsInRange:NSMakeRange(0, i)];
    if (a.count >= gapLimit) return [a subarrayWithRange:NSMakeRange(0, gapLimit)];
    
    if (gapLimit > 1) { // get receiveAddress and changeAddress first to avoid blocking
        [self receiveAddress];
    }
    
    @synchronized(self) {
        //It seems weird to repeat this, but it's correct because of the original call receive address and change address
        [a setArray:self.externalAddresses];
        i = a.count;
        
        unsigned n = (unsigned)i;
        
        // keep only the trailing contiguous block of addresses with no transactions
        while (i > 0 && ! [self.usedAddresses containsObject:a[i - 1]]) {
            i--;
        }
        
        if (i > 0) [a removeObjectsInRange:NSMakeRange(0, i)];
        if (a.count >= gapLimit) return [a subarrayWithRange:NSMakeRange(0, gapLimit)];
        
        while (a.count < gapLimit) { // generate new addresses up to gapLimit
            NSData *pubKey = [self publicKeyDataAtIndex:n];
            NSString *addr = [[DSECDSAKey keyWithPublicKey:pubKey] addressForChain:self.chain];
            
            if (! addr) {
                DSDLog(@"error generating keys");
                return nil;
            }
            
            if (!self.account.wallet.isTransient) {
                [self.moc performBlock:^{ // store new address in core data
                    [DSDerivationPathEntity setContext:self.moc];
                    DSDerivationPathEntity * derivationPathEntity = [DSDerivationPathEntity derivationPathEntityMatchingDerivationPath:self];
                    DSAddressEntity *e = [DSAddressEntity managedObject];
                    e.derivationPath = derivationPathEntity;
                    NSAssert([addr isValidDashAddressOnChain:self.chain], @"the address is being saved to the wrong derivation path");
                    e.address = addr;
                    e.index = n;
                    e.internal = NO;
                    e.standalone = NO;
                }];
            }
            
            [self.mAllAddresses addObject:addr];
            [self.externalAddresses addObject:addr];
            [a addObject:addr];
            n++;
        }
        
        return a;
    }
}

// gets an address at an index path
- (NSString *)addressAtIndex:(uint32_t)index
{
    NSData *pubKey = [self publicKeyDataAtIndex:index];
    return [[DSECDSAKey keyWithPublicKey:pubKey] addressForChain:self.chain];
}

// returns the first unused external address
- (NSString *)receiveAddress
{
    //TODO: limit to 10,000 total addresses and utxos for practical usability with bloom filters
    NSString *addr = [self registerAddressesWithGapLimit:1].lastObject;
    return (addr) ? addr : self.externalAddresses.lastObject;
}

- (NSString *)receiveAddressAtOffset:(NSUInteger)offset
{
    //TODO: limit to 10,000 total addresses and utxos for practical usability with bloom filters
    NSString *addr = [self registerAddressesWithGapLimit:offset + 1].lastObject;
    return (addr) ? addr : self.externalAddresses.lastObject;
}

// all previously generated external addresses
- (NSArray *)allReceiveAddresses
{
    return [self.externalAddresses copy];
}

-(NSArray *)usedReceiveAddresses {
    NSMutableSet *intersection = [NSMutableSet setWithArray:self.externalAddresses];
    [intersection intersectSet:self.mUsedAddresses];
    return [intersection allObjects];
}

- (NSData *)publicKeyDataAtIndex:(uint32_t)n
{
    NSUInteger indexes[] = {n};
    return [self publicKeyDataAtIndexPath:[NSIndexPath indexPathWithIndexes:indexes length:1]];
}

- (NSString *)privateKeyStringAtIndex:(uint32_t)n fromSeed:(NSData *)seed
{
    return seed ? [self serializedPrivateKeys:@[@(n)] fromSeed:seed].lastObject : nil;
}

- (NSArray *)serializedPrivateKeys:(NSArray *)n fromSeed:(NSData *)seed
{
    NSMutableArray * mArray = [NSMutableArray array];
    for (NSNumber * index in n) {
        NSUInteger indexes[] = {index.unsignedIntValue};
        [mArray addObject:[NSIndexPath indexPathWithIndexes:indexes length:1]];
    }
    
    return [self serializedPrivateKeysAtIndexPaths:mArray fromSeed:seed];
}

- (NSIndexPath*)indexPathForKnownAddress:(NSString*)address {
    if ([self.allReceiveAddresses containsObject:address]) {
        NSUInteger indexes[] = {[self.allReceiveAddresses indexOfObject:address]};
        return [NSIndexPath indexPathWithIndexes:indexes length:1];
    }
    return nil;
}


@end
