//
//  DSSimpleIndexedDerivationPath.m
//  DashSync
//
//  Created by Sam Westrich on 2/20/19.
//

#import "DSSimpleIndexedDerivationPath+Protected.h"
#import "DSDerivationPath+Protected.h"


@implementation DSSimpleIndexedDerivationPath

- (instancetype)initWithIndexes:(NSUInteger *)indexes length:(NSUInteger)length
                           type:(DSDerivationPathType)type signingAlgorithm:(DSDerivationPathSigningAlgorith)signingAlgorithm reference:(DSDerivationPathReference)reference onChain:(DSChain*)chain {
    
    if (! (self = [super initWithIndexes:indexes length:length type:type signingAlgorithm:signingAlgorithm reference:reference onChain:chain])) return nil;
    
    self.mOrderedAddresses = [NSMutableArray array];
    
    return self;
}

-(void)loadAddresses {
    @synchronized (self) {
        if (!self.addressesLoaded) {
            [self.moc performBlockAndWait:^{
                [DSAddressEntity setContext:self.moc];
                [DSTransactionEntity setContext:self.moc];
                DSDerivationPathEntity * derivationPathEntity = [DSDerivationPathEntity derivationPathEntityMatchingDerivationPath:self];
                self.syncBlockHeight = derivationPathEntity.syncBlockHeight;
                NSArray<DSAddressEntity *> *addresses = [derivationPathEntity.addresses sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"index" ascending:YES]]];
                for (DSAddressEntity *e in addresses) {
                    @autoreleasepool {
                        while (e.index >= self.mOrderedAddresses.count) [self.mOrderedAddresses addObject:[NSNull null]];
                        if (![e.address isValidDashAddressOnChain:self.wallet.chain]) {
                            DSDLog(@"address %@ loaded but was not valid on chain %@",e.address,self.wallet.chain.name);
                            continue;
                        }
                        self.mOrderedAddresses[e.index] = e.address;
                        [self.mAllAddresses addObject:e.address];
                        if ([e.usedInInputs count] || [e.usedInOutputs count]) {
                            [self.mUsedAddresses addObject:e.address];
                        }
                    }
                }
            }];
            self.addressesLoaded = TRUE;
            [self registerAddressesWithGapLimit:10];
        }
    }
}

// MARK: - Derivation Path Addresses

// Wallets are composed of chains of addresses. Each chain is traversed until a gap of a certain number of addresses is
// found that haven't been used in any transactions. This method returns an array of <gapLimit> unused addresses
// following the last used address in the chain.
- (NSArray *)registerAddressesWithGapLimit:(NSUInteger)gapLimit
{
    
    NSMutableArray * rArray = [self.mOrderedAddresses copy];
    
    if (!self.wallet.isTransient) {
        NSAssert(self.addressesLoaded, @"addresses must be loaded before calling this function");
    }
    NSUInteger i = rArray.count;
    
    // keep only the trailing contiguous block of addresses with no transactions
    while (i > 0 && ! [self.usedAddresses containsObject:rArray[i - 1]]) {
        i--;
    }
    
    if (i > 0) [rArray removeObjectsInRange:NSMakeRange(0, i)];
    if (rArray.count >= gapLimit) return [rArray subarrayWithRange:NSMakeRange(0, gapLimit)];
    
    @synchronized(self) {
        i = rArray.count;
        
        unsigned n = (unsigned)i;
        
        // keep only the trailing contiguous block of addresses with no transactions
        while (i > 0 && ! [self.usedAddresses containsObject:rArray[i - 1]]) {
            i--;
        }
        
        if (i > 0) [rArray removeObjectsInRange:NSMakeRange(0, i)];
        if (rArray.count >= gapLimit) return [rArray subarrayWithRange:NSMakeRange(0, gapLimit)];
        
        while (rArray.count < gapLimit) { // generate new addresses up to gapLimit
            NSData *pubKey = [self generatePublicKeyAtIndex:n];
            NSString *addr = nil;
            if (self.signingAlgorithm == DSDerivationPathSigningAlgorith_ECDSA) {
                addr = [[DSECDSAKey keyWithPublicKey:pubKey] addressForChain:self.chain];
            } else if (self.signingAlgorithm == DSDerivationPathSigningAlgorith_BLS) {
                addr = [[DSBLSKey blsKeyWithPublicKey:pubKey.UInt384 onChain:self.chain] addressForChain:self.chain];
            }
            
            if (! addr) {
                DSDLog(@"error generating keys");
                return nil;
            }
            
            if (!self.wallet.isTransient) {
                [self.moc performBlock:^{ // store new address in core data
                    [DSDerivationPathEntity setContext:self.moc];
                    DSDerivationPathEntity * derivationPathEntity = [DSDerivationPathEntity derivationPathEntityMatchingDerivationPath:self];
                    DSAddressEntity *e = [DSAddressEntity managedObject];
                    e.derivationPath = derivationPathEntity;
                    NSAssert([addr isValidDashAddressOnChain:self.chain], @"the address is being saved to the wrong derivation path");
                    e.address = addr;
                    e.index = n;
                    e.standalone = NO;
                }];
            }
            
            [self.mAllAddresses addObject:addr];
            [rArray addObject:addr];
            [self.mOrderedAddresses addObject:addr];
            n++;
        }
        
        return rArray;
    }
}

-(uint32_t)unusedIndex {
    return 0;
}

- (NSUInteger)indexOfAddress:(NSString*)address {
    return [self.mOrderedAddresses indexOfObject:address];
}

@end
