//
//  DSDerivationPath.m
//  DashSync
//
//  Created by Sam Westrich on 5/20/18.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#import "DSDerivationPath.h"
#import "DSAccount.h"
#import "DSWallet.h"
#import "DSKey.h"
#import "DSAddressEntity+CoreDataClass.h"
#import "DSChain.h"
#import "DSTransaction.h"
#import "DSTransactionEntity+CoreDataClass.h"
#import "DSTxInputEntity+CoreDataClass.h"
#import "DSTxOutputEntity+CoreDataClass.h"
#import "DSDerivationPathEntity+CoreDataClass.h"
#import "DSChainPeerManager.h"
#import "DSKeySequence.h"
#import "NSData+Bitcoin.h"
#import "NSMutableData+Dash.h"
#import "NSManagedObject+Sugar.h"
#import "DSWalletManager.h"
#import "NSString+Bitcoin.h"
#import "NSString+Dash.h"

#define useDarkCoinSeed 0

#if useDarkCoinSeed

#define BIP32_SEED_KEY "Darkcoin seed"
#define BIP32_XPRV     "\x02\xFE\x52\xCC" //// Dash BIP32 prvkeys start with 'drkp'
#define BIP32_XPUB     "\x02\xFE\x52\xF8" //// Dash BIP32 pubkeys start with 'drkv'

#else

#define BIP32_SEED_KEY "Bitcoin seed"
#if DASH_TESTNET
#define BIP32_XPRV     "\x04\x35\x83\x94"
#define BIP32_XPUB     "\x04\x35\x87\xCF"
#else
#define BIP32_XPRV     "\x04\x88\xAD\xE4"
#define BIP32_XPUB     "\x04\x88\xB2\x1E"
#endif

#endif

// BIP32 is a scheme for deriving chains of addresses from a seed value
// https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki

// Private parent key -> private child key
//
// CKDpriv((kpar, cpar), i) -> (ki, ci) computes a child extended private key from the parent extended private key:
//
// - Check whether i >= 2^31 (whether the child is a hardened key).
//     - If so (hardened child): let I = HMAC-SHA512(Key = cpar, Data = 0x00 || ser256(kpar) || ser32(i)).
//       (Note: The 0x00 pads the private key to make it 33 bytes long.)
//     - If not (normal child): let I = HMAC-SHA512(Key = cpar, Data = serP(point(kpar)) || ser32(i)).
// - Split I into two 32-byte sequences, IL and IR.
// - The returned child key ki is parse256(IL) + kpar (mod n).
// - The returned chain code ci is IR.
// - In case parse256(IL) >= n or ki = 0, the resulting key is invalid, and one should proceed with the next value for i
//   (Note: this has probability lower than 1 in 2^127.)
//
static void CKDpriv(UInt256 *k, UInt256 *c, uint32_t i)
{
    uint8_t buf[sizeof(DSECPoint) + sizeof(i)];
    UInt512 I;
    
    if (i & BIP32_HARD) {
        buf[0] = 0;
        *(UInt256 *)&buf[1] = *k;
    }
    else DSSecp256k1PointGen((DSECPoint *)buf, k);
    
    *(uint32_t *)&buf[sizeof(DSECPoint)] = CFSwapInt32HostToBig(i);
    
    HMAC(&I, SHA512, sizeof(UInt512), c, sizeof(*c), buf, sizeof(buf)); // I = HMAC-SHA512(c, k|P(k) || i)
    
    DSSecp256k1ModAdd(k, (UInt256 *)&I); // k = IL + k (mod n)
    *c = *(UInt256 *)&I.u8[sizeof(UInt256)]; // c = IR
    
    memset(buf, 0, sizeof(buf));
    memset(&I, 0, sizeof(I));
}

// Public parent key -> public child key
//
// CKDpub((Kpar, cpar), i) -> (Ki, ci) computes a child extended public key from the parent extended public key.
// It is only defined for non-hardened child keys.
//
// - Check whether i >= 2^31 (whether the child is a hardened key).
//     - If so (hardened child): return failure
//     - If not (normal child): let I = HMAC-SHA512(Key = cpar, Data = serP(Kpar) || ser32(i)).
// - Split I into two 32-byte sequences, IL and IR.
// - The returned child key Ki is point(parse256(IL)) + Kpar.
// - The returned chain code ci is IR.
// - In case parse256(IL) >= n or Ki is the point at infinity, the resulting key is invalid, and one should proceed with
//   the next value for i.
//
static void CKDpub(DSECPoint *K, UInt256 *c, uint32_t i)
{
    if (i & BIP32_HARD) return; // can't derive private child key from public parent key
    
    uint8_t buf[sizeof(*K) + sizeof(i)];
    UInt512 I;
    
    *(DSECPoint *)buf = *K;
    *(uint32_t *)&buf[sizeof(*K)] = CFSwapInt32HostToBig(i);
    
    HMAC(&I, SHA512, sizeof(UInt512), c, sizeof(*c), buf, sizeof(buf)); // I = HMAC-SHA512(c, P(K) || i)
    
    *c = *(UInt256 *)&I.u8[sizeof(UInt256)]; // c = IR
    DSSecp256k1PointAdd(K, (UInt256 *)&I); // K = P(IL) + K
    
    memset(buf, 0, sizeof(buf));
    memset(&I, 0, sizeof(I));
}

// helper function for serializing BIP32 master public/private keys to standard export format
static NSString *serialize(uint8_t depth, uint32_t fingerprint, uint32_t child, UInt256 chain, NSData *key)
{
    NSMutableData *d = [NSMutableData secureDataWithCapacity:14 + key.length + sizeof(chain)];
    
    fingerprint = CFSwapInt32HostToBig(fingerprint);
    child = CFSwapInt32HostToBig(child);
    
    [d appendBytes:key.length < 33 ? BIP32_XPRV : BIP32_XPUB length:4]; //4
    [d appendBytes:&depth length:1]; //5
    [d appendBytes:&fingerprint length:sizeof(fingerprint)]; // 9
    [d appendBytes:&child length:sizeof(child)]; // 13
    [d appendBytes:&chain length:sizeof(chain)]; // 45
    if (key.length < 33) [d appendBytes:"\0" length:1]; //46 (prv) / 45 (pub)
    [d appendData:key]; //78 (prv) / 78 (pub)
    
    return [NSString base58checkWithData:d];
}

// helper function for serializing BIP32 master public/private keys to standard export format
static BOOL deserialize(NSString * string, uint8_t * depth, uint32_t * fingerprint, uint32_t * child, UInt256 * chain, NSData **key)
{
    NSData * allData = [NSData dataWithBase58String:string];
    if (allData.length != 82) return false;
    NSData * data = [allData subdataWithRange:NSMakeRange(0, allData.length - 4)];
    NSData * checkData = [allData subdataWithRange:NSMakeRange(allData.length - 4, 4)];
    if ((*(uint32_t*)data.SHA256_2.u32) != *(uint32_t*)checkData.bytes) return FALSE;
    uint8_t * bytes = (uint8_t *)[data bytes];
    if (memcmp(bytes,BIP32_XPRV,4) != 0 && memcmp(bytes,BIP32_XPUB,4) != 0) {
        return FALSE;
    }
    NSUInteger offset = 4;
    *depth = bytes[4];
    offset++;
    *fingerprint = CFSwapInt32BigToHost(*(uint32_t*)(&bytes[offset]));
    offset += sizeof(uint32_t);
    *child = CFSwapInt32BigToHost(*(uint32_t*)(&bytes[offset]));
    offset += sizeof(uint32_t);
    *chain = *(UInt256*)(&bytes[offset]);
    offset += sizeof(UInt256);
    if (memcmp(bytes,BIP32_XPRV,4) == 0) offset++;
    *key = [data subdataWithRange:NSMakeRange(offset, data.length - offset)];
    return TRUE;
}

@interface DSDerivationPath()

@property (nonatomic,copy) NSString * extendedPubKeyString;
@property (nonatomic, strong) NSData * masterPublicKey;
@property (nonatomic, strong) NSMutableArray *internalAddresses, *externalAddresses;
@property (nonatomic, strong) NSMutableSet *allAddresses, *usedAddresses;
@property (nonatomic, weak) DSAccount * account;
@property (nonatomic, strong) NSManagedObjectContext * moc;
@property (nonatomic, strong) NSData * extendedPublicKey;//master public key used to generate wallet addresses

@end

@implementation DSDerivationPath

-(NSString*)extendedPubKeyString {
    if (_extendedPubKeyString) return _extendedPubKeyString;
    NSMutableString * mutableString = [NSMutableString string];
    for (NSInteger i = 0;i<self.length;i++) {
        [mutableString appendFormat:@"_%lu",(unsigned long)[self indexAtPosition:i]];
    }
    _extendedPubKeyString = [NSString stringWithFormat:@"%@",mutableString];
    return _extendedPubKeyString;
}

// MARK: - Entity

-(DSDerivationPathEntity*)entity {
    NSData * derivationData = [NSKeyedArchiver archivedDataWithRootObject:self];
    NSArray * array = [DSDerivationPathEntity objectsMatching:@"derivationPath == %@",derivationData];
    if ([array count]) {
        return [array objectAtIndex:0];
    } else {
        DSDerivationPathEntity * entity = [DSDerivationPathEntity managedObject];
        entity.derivationPath = derivationData;
        return entity;
    }
}

// MARK: - Account initialization

- (NSData *)extendedPublicKeyForSequence:(id<DSKeySequence>)sequence
{
    return [[DSWalletManager sharedInstance] extendedPublicKeyForStorageKey:sequence.derivationPath.extendedPubKeyString];
}

+ (instancetype _Nonnull)bip32DerivationPathForAccountNumber:(uint32_t)accountNumber {
    NSUInteger indexes[] = {accountNumber};
    return [self derivationPathWithIndexes:indexes length:1 type:DSDerivationPathFundsType_Clear];
}
+ (instancetype _Nonnull)bip44DerivationPathForChainType:(DSChainType)chain forAccountNumber:(uint32_t)accountNumber {
    if (chain == DSChainType_MainNet) {
        NSUInteger indexes[] = {44,5,accountNumber};
        return [self derivationPathWithIndexes:indexes length:3 type:DSDerivationPathFundsType_Clear];
    } else {
        NSUInteger indexes[] = {44,1,accountNumber};
        return [self derivationPathWithIndexes:indexes length:3 type:DSDerivationPathFundsType_Clear];
    }
}

+ (instancetype _Nullable)derivationPathWithIndexes:(NSUInteger *)indexes length:(NSUInteger)length
                                              type:(DSDerivationPathFundsType)type {
    return [[self alloc] initWithIndexes:indexes length:length type:type];
}

- (instancetype)initWithIndexes:(NSUInteger *)indexes length:(NSUInteger)length
                           type:(DSDerivationPathFundsType)type {
    if (length) {
        if (! (self = [super initWithIndexes:indexes length:length])) return nil;
    } else {
        if (! (self = [super init])) return nil;
    }
    
    NSMutableSet *updateTx = [NSMutableSet set];
    _type = type;
    self.allAddresses = [NSMutableSet set];
    self.usedAddresses = [NSMutableSet set];
    self.moc = [NSManagedObject context];
    
    [self.moc performBlockAndWait:^{
        [DSAddressEntity setContext:self.moc];
        [DSTransactionEntity setContext:self.moc];
        DSDerivationPathEntity * accountEntity = [DSDerivationPathEntity accountEntityMatchingDerivationPath:self.derivationPath onChain:self.chain];
        for (DSAddressEntity *e in accountEntity.addresses) {
            @autoreleasepool {
                NSMutableArray *a = (e.internal) ? self.internalAddresses : self.externalAddresses;
                
                while (e.index >= a.count) [a addObject:[NSNull null]];
                a[e.index] = e.address;
                [self.allAddresses addObject:e.address];
            }
        }
        for (DSTxInputEntity *e in self.entity.txInputs) {
            @autoreleasepool {
                
                [self.usedAddresses addObjectsFromArray:transaction.inputAddresses];

            }
        }
        for (DSTxInputEntity *e in self.entity.txInputs) {
            @autoreleasepool {
                [self.usedAddresses addObjectsFromArray:transaction.inputAddresses];
                
            }
        }
       
    }];
    
    return self;
}

- (void)dealloc
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}


// Wallets are composed of chains of addresses. Each chain is traversed until a gap of a certain number of addresses is
// found that haven't been used in any transactions. This method returns an array of <gapLimit> unused addresses
// following the last used address in the chain. The internal chain is used for change addresses and the external chain
// for receive addresses.
- (NSArray *)registerAddressesWithGapLimit:(NSUInteger)gapLimit internal:(BOOL)internal
{
    NSMutableArray *a = [NSMutableArray arrayWithArray:(internal) ? self.internalAddresses : self.externalAddresses];
    NSUInteger i = a.count;
    
    // keep only the trailing contiguous block of addresses with no transactions
    while (i > 0 && ! [self.usedAddresses containsObject:a[i - 1]]) {
        i--;
    }
    
    if (i > 0) [a removeObjectsInRange:NSMakeRange(0, i)];
    if (a.count >= gapLimit) return [a subarrayWithRange:NSMakeRange(0, gapLimit)];
    
    if (gapLimit > 1) { // get receiveAddress and changeAddress first to avoid blocking
        [self receiveAddress];
        [self changeAddress];
    }
    
    @synchronized(self) {
        [a setArray:(internal) ? self.internalAddresses : self.externalAddresses];
        i = a.count;
        
        unsigned n = (unsigned)i;
        
        // keep only the trailing contiguous block of addresses with no transactions
        while (i > 0 && ! [self.usedAddresses containsObject:a[i - 1]]) {
            i--;
        }
        
        if (i > 0) [a removeObjectsInRange:NSMakeRange(0, i)];
        if (a.count >= gapLimit) return [a subarrayWithRange:NSMakeRange(0, gapLimit)];
        
            while (a.count < gapLimit) { // generate new addresses up to gapLimit
                NSData *pubKey = [self generatePublicKeyAtIndex:n internal:internal];
                NSString *addr = [DSKey keyWithPublicKey:pubKey].address;
                
                if (! addr) {
                    NSLog(@"error generating keys");
                    return nil;
                }
                
                [self.moc performBlock:^{ // store new address in core data
                    DSAddressEntity *e = [DSAddressEntity managedObject];
                    e.derivationPath = self.derivationPathEntity;
                    e.address = addr;
                    e.index = n;
                    e.internal = internal;
                    e.standalone = NO;
                }];
                
                [self.allAddresses addObject:addr];
                [(internal) ? self.internalAddresses : self.externalAddresses addObject:addr];
                [a addObject:addr];
                n++;
            }
        
        return a;
    }
}



// MARK: - Wallet Info

// returns the first unused external address
- (NSString *)receiveAddress
{
    //TODO: limit to 10,000 total addresses and utxos for practical usability with bloom filters
    NSString *addr = [self registerAddressesWithGapLimit:1 internal:NO].lastObject;
    return (addr) ? addr : self.externalAddresses.lastObject;
}

// returns the first unused internal address
- (NSString *)changeAddress
{
    //TODO: limit to 10,000 total addresses and utxos for practical usability with bloom filters
    return [self registerAddressesWithGapLimit:1 internal:YES].lastObject;
}

// all previously generated external addresses
- (NSArray *)allReceiveAddresses
{
    return [self.externalAddresses copy];
}

// all previously generated external addresses
- (NSArray *)allChangeAddresses
{
    return [self.internalAddresses copy];
}

// true if the address is controlled by the wallet
- (BOOL)containsAddress:(NSString *)address
{
    return (address && [self.allAddresses containsObject:address]) ? YES : NO;
}

// true if the address was previously used as an input or output in any wallet transaction
- (BOOL)addressIsUsed:(NSString *)address
{
    return (address && [self.usedAddresses containsObject:address]) ? YES : NO;
}

// MARK: - authentication key

//this is for upgrade purposes only
- (NSData *)deprecatedIncorrectExtendedPublicKeyFromSeed:(NSData *)seed
{
    if (! seed) return nil;
    if (![self length]) return nil; //there needs to be at least 1 length
    NSMutableData *mpk = [NSMutableData secureData];
    UInt512 I;
    
    HMAC(&I, SHA512, sizeof(UInt512), BIP32_SEED_KEY, strlen(BIP32_SEED_KEY), seed.bytes, seed.length);
    
    UInt256 secret = *(UInt256 *)&I, chain = *(UInt256 *)&I.u8[sizeof(UInt256)];
    
    [mpk appendBytes:[DSKey keyWithSecret:secret compressed:YES].hash160.u32 length:4];
    
    for (NSInteger i = 0;i<[self length];i++) {
        uint32_t derivation = (uint32_t)[self indexAtPosition:i];
        CKDpriv(&secret, &chain, derivation | BIP32_HARD);
    }
    
    [mpk appendBytes:&chain length:sizeof(chain)];
    [mpk appendData:[DSKey keyWithSecret:secret compressed:YES].publicKey];
    
    return mpk;
}

// master public key format is: 4 byte parent fingerprint || 32 byte chain code || 33 byte compressed public key
// the values are taken from BIP32 account m/44H/5H/0H
- (NSData *)extendedPublicKeyForDerivationPath:(DSDerivationPath*)derivationPath fromSeed:(NSData *)seed
{
    if (! seed) return nil;
    if (![derivationPath length]) return nil; //there needs to be at least 1 length
    NSMutableData *mpk = [NSMutableData secureData];
    UInt512 I;
    
    HMAC(&I, SHA512, sizeof(UInt512), BIP32_SEED_KEY, strlen(BIP32_SEED_KEY), seed.bytes, seed.length);
    
    UInt256 secret = *(UInt256 *)&I, chain = *(UInt256 *)&I.u8[sizeof(UInt256)];
    
    for (NSInteger i = 0;i<[derivationPath length] - 1;i++) {
        uint32_t derivation = (uint32_t)[derivationPath indexAtPosition:i];
        CKDpriv(&secret, &chain, derivation | BIP32_HARD);
    }
    [mpk appendBytes:[DSKey keyWithSecret:secret compressed:YES].hash160.u32 length:4];
    CKDpriv(&secret, &chain, (uint32_t)[derivationPath indexAtPosition:[derivationPath length] - 1] | BIP32_HARD); // account 0H
    
    [mpk appendBytes:&chain length:sizeof(chain)];
    [mpk appendData:[DSKey keyWithSecret:secret compressed:YES].publicKey];
    
    return mpk;
}

- (NSData *)generatePublicKeyAtIndex:(uint32_t)n internal:(BOOL)internal
{
    if (self.masterPublicKey.length < 4 + sizeof(UInt256) + sizeof(DSECPoint)) return nil;
    
    UInt256 chain = *(const UInt256 *)((const uint8_t *)self.masterPublicKey.bytes + 4);
    DSECPoint pubKey = *(const DSECPoint *)((const uint8_t *)self.masterPublicKey.bytes + 36);
    
    CKDpub(&pubKey, &chain, internal ? 1 : 0); // internal or external chain
    CKDpub(&pubKey, &chain, n); // nth key in chain
    
    return [NSData dataWithBytes:&pubKey length:sizeof(pubKey)];
}

- (NSString *)privateKey:(uint32_t)n internal:(BOOL)internal fromSeed:(NSData *)seed
{
    return seed ? [self privateKeys:@[@(n)] internal:internal fromSeed:seed].lastObject : nil;
}

- (NSArray *)privateKeys:(NSArray *)n internal:(BOOL)internal fromSeed:(NSData *)seed
{
    if (! seed || ! n) return nil;
    if (n.count == 0) return @[];
    
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:n.count];
    UInt512 I;
    
    HMAC(&I, SHA512, sizeof(UInt512), BIP32_SEED_KEY, strlen(BIP32_SEED_KEY), seed.bytes, seed.length);
    
    UInt256 secret = *(UInt256 *)&I, chain = *(UInt256 *)&I.u8[sizeof(UInt256)];
    uint8_t version = DASH_PRIVKEY;
    
#if DASH_TESTNET
    version = DASH_PRIVKEY_TEST;
#endif
    
    for (NSInteger i = 0;i<[self length] - 1;i++) {
        uint32_t derivation = (uint32_t)[self indexAtPosition:i];
        CKDpriv(&secret, &chain, derivation | BIP32_HARD);
    }
    
    CKDpriv(&secret, &chain, internal ? 1 : 0); // internal or external chain
    
    for (NSNumber *i in n) {
        NSMutableData *privKey = [NSMutableData secureDataWithCapacity:34];
        UInt256 s = secret, c = chain;
        
        CKDpriv(&s, &c, i.unsignedIntValue); // nth key in chain
        
        [privKey appendBytes:&version length:1];
        [privKey appendBytes:&s length:sizeof(s)];
        [privKey appendBytes:"\x01" length:1]; // specifies compressed pubkey format
        [a addObject:[NSString base58checkWithData:privKey]];
    }
    
    return a;
}

// MARK: - authentication key

+ (NSString *)authPrivateKeyFromSeed:(NSData *)seed
{
    if (! seed) return nil;
    
    UInt512 I;
    
    HMAC(&I, SHA512, sizeof(UInt512), BIP32_SEED_KEY, strlen(BIP32_SEED_KEY), seed.bytes, seed.length);
    
    UInt256 secret = *(UInt256 *)&I, chain = *(UInt256 *)&I.u8[sizeof(UInt256)];
    uint8_t version = DASH_PRIVKEY;
    
#if DASH_TESTNET
    version = DASH_PRIVKEY_TEST;
#endif
    
    // path m/1H/0 (same as copay uses for bitauth)
    CKDpriv(&secret, &chain, 1 | BIP32_HARD);
    CKDpriv(&secret, &chain, 0);
    
    NSMutableData *privKey = [NSMutableData secureDataWithCapacity:34];
    
    [privKey appendBytes:&version length:1];
    [privKey appendBytes:&secret length:sizeof(secret)];
    [privKey appendBytes:"\x01" length:1]; // specifies compressed pubkey format
    return [NSString base58checkWithData:privKey];
}

// key used for BitID: https://github.com/bitid/bitid/blob/master/BIP_draft.md
+ (NSString *)bitIdPrivateKey:(uint32_t)n forURI:(NSString *)uri fromSeed:(NSData *)seed
{
    NSUInteger len = [uri lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *data = [NSMutableData dataWithCapacity:sizeof(n) + len];
    
    [data appendUInt32:n];
    [data appendBytes:uri.UTF8String length:len];
    
    UInt256 hash = data.SHA256;
    UInt512 I;
    
    HMAC(&I, SHA512, sizeof(UInt512), BIP32_SEED_KEY, strlen(BIP32_SEED_KEY), seed.bytes, seed.length);
    
    UInt256 secret = *(UInt256 *)&I, chain = *(UInt256 *)&I.u8[sizeof(UInt256)];
    uint8_t version = DASH_PRIVKEY;
    
#if DASH_TESTNET
    version = DASH_PRIVKEY_TEST;
#endif
    
    CKDpriv(&secret, &chain, 13 | BIP32_HARD); // m/13H
    CKDpriv(&secret, &chain, CFSwapInt32LittleToHost(hash.u32[0]) | BIP32_HARD); // m/13H/aH
    CKDpriv(&secret, &chain, CFSwapInt32LittleToHost(hash.u32[1]) | BIP32_HARD); // m/13H/aH/bH
    CKDpriv(&secret, &chain, CFSwapInt32LittleToHost(hash.u32[2]) | BIP32_HARD); // m/13H/aH/bH/cH
    CKDpriv(&secret, &chain, CFSwapInt32LittleToHost(hash.u32[3]) | BIP32_HARD); // m/13H/aH/bH/cH/dH
    
    NSMutableData *privKey = [NSMutableData secureDataWithCapacity:34];
    
    [privKey appendBytes:&version length:1];
    [privKey appendBytes:&secret length:sizeof(secret)];
    [privKey appendBytes:"\x01" length:1]; // specifies compressed pubkey format
    return [NSString base58checkWithData:privKey];
}

// MARK: - serializations

- (NSString *)serializedPrivateMasterFromSeed:(NSData *)seed
{
    if (! seed) return nil;
    
    UInt512 I;
    
    HMAC(&I, SHA512, sizeof(UInt512), BIP32_SEED_KEY, strlen(BIP32_SEED_KEY), seed.bytes, seed.length);
    
    UInt256 secret = *(UInt256 *)&I, chain = *(UInt256 *)&I.u8[sizeof(UInt256)];
    
    return serialize(0, 0, 0, chain, [NSData dataWithBytes:&secret length:sizeof(secret)]);
}

- (NSString *)serializedMasterPublicKey:(NSData *)masterPublicKey depth:(NSUInteger)depth
{
    if (masterPublicKey.length < 36) return nil;
    
    uint32_t fingerprint = CFSwapInt32BigToHost(*(const uint32_t *)masterPublicKey.bytes);
    UInt256 chain = *(UInt256 *)((const uint8_t *)masterPublicKey.bytes + 4);
    DSECPoint pubKey = *(DSECPoint *)((const uint8_t *)masterPublicKey.bytes + 36);
    
    return serialize(depth, fingerprint, 0 | BIP32_HARD, chain, [NSData dataWithBytes:&pubKey length:sizeof(pubKey)]);
}

- (NSData *)deserializedMasterPublicKey:(NSString *)masterPublicKeyString
{
    uint8_t depth;
    uint32_t fingerprint;
    uint32_t child;
    UInt256 chain;
    NSData * pubkey = nil;
    NSMutableData * masterPublicKey = [NSMutableData secureData];
    BOOL valid = deserialize(masterPublicKeyString, &depth, &fingerprint, &child, &chain, &pubkey);
    if (!valid) return nil;
    [masterPublicKey appendUInt32:CFSwapInt32HostToBig(fingerprint)];
    [masterPublicKey appendBytes:&chain length:32];
    [masterPublicKey appendData:pubkey];
    return [masterPublicKey copy];
}

@end

