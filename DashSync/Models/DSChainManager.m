//
//  DSChainManager.m
//  DashSync
//
//  Created by Sam Westrich on 5/6/18.
//

#import "DSChainManager.h"
#import "DSChainEntity+CoreDataClass.h"
#import "NSManagedObject+Sugar.h"
#import "Reachability.h"
#import "DSWalletManager.h"

#define FEE_PER_KB_URL       0 //not supported @"https://api.breadwallet.com/fee-per-kb"

@interface DSChainManager()

@property (nonatomic,strong) NSMutableArray * knownChains;
@property (nonatomic,strong) NSMutableArray * knownDevnetChains;
@property (nonatomic,strong) Reachability *reachability;

@end

@implementation DSChainManager

+ (instancetype)sharedInstance
{
    static id singleton = nil;
    static dispatch_once_t onceToken = 0;
    
    dispatch_once(&onceToken, ^{
        singleton = [self new];
    });
    
    return singleton;
}

-(id)init {
    if ([super init] == self) {
        self.knownChains = [NSMutableArray array];
        self.knownDevnetChains = [NSMutableArray array];
        self.reachability = [Reachability reachabilityForInternetConnection];
    }
    return self;
}

-(DSChainPeerManager*)mainnetManager {
    static id _mainnetManager = nil;
    static dispatch_once_t mainnetToken = 0;
    
    dispatch_once(&mainnetToken, ^{
        DSChain * mainnet = [DSChain mainnet];
        _mainnetManager = [[DSChainPeerManager alloc] initWithChain:mainnet];
        mainnet.peerManagerDelegate = _mainnetManager;

        [self.knownChains addObject:[DSChain mainnet]];
    });
    return _mainnetManager;
}

-(DSChainPeerManager*)testnetManager {
    static id _testnetManager = nil;
    static dispatch_once_t testnetToken = 0;
    
    dispatch_once(&testnetToken, ^{
        DSChain * testnet = [DSChain testnet];
        _testnetManager = [[DSChainPeerManager alloc] initWithChain:testnet];
        testnet.peerManagerDelegate = _testnetManager;
        [self.knownChains addObject:[DSChain testnet]];
    });
    return _testnetManager;
}


-(DSChainPeerManager*)devnetManagerForChain:(DSChain*)chain {
    static NSMutableDictionary * _devnetDictionary = nil;
    static dispatch_once_t devnetToken = 0;
    dispatch_once(&devnetToken, ^{
        _devnetDictionary = [NSMutableDictionary dictionary];
    });
    NSValue * genesisValue = uint256_obj(chain.genesisHash);
    DSChainPeerManager * devnetChainPeerManager = nil;
    @synchronized(self) {
        if (![_devnetDictionary objectForKey:genesisValue]) {
            devnetChainPeerManager = [[DSChainPeerManager alloc] initWithChain:chain];
            chain.peerManagerDelegate = devnetChainPeerManager;
            [self.knownChains addObject:chain];
            [self.knownDevnetChains addObject:chain];
            [_devnetDictionary setObject:devnetChainPeerManager forKey:genesisValue];
        } else {
            devnetChainPeerManager = [_devnetDictionary objectForKey:genesisValue];
        }
    }
    return devnetChainPeerManager;
}

-(DSChainPeerManager*)peerManagerForChain:(DSChain*)chain {
    if ([chain isMainnet]) {
        return [self mainnetManager];
    } else if ([chain isTestnet]) {
        return [self testnetManager];
    } else if ([chain isDevnetAny]) {
        return [self devnetManagerForChain:chain];
    }
    return nil;
}

-(NSArray*)devnetChains {
    return [self.knownDevnetChains copy];
}

-(NSArray*)chains {
    return [self.knownChains copy];
}

// MARK: - floating fees

- (void)updateFeePerKb
{
    if (self.reachability.currentReachabilityStatus == NotReachable) return;
    
#if (!!FEE_PER_KB_URL)
    
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:FEE_PER_KB_URL]
                                                       cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:10.0];
    
    //    NSLog(@"%@", req.URL.absoluteString);
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                         if (error != nil) {
                                             NSLog(@"unable to fetch fee-per-kb: %@", error);
                                             return;
                                         }
                                         
                                         NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
                                         
                                         if (error || ! [json isKindOfClass:[NSDictionary class]] ||
                                             ! [json[@"fee_per_kb"] isKindOfClass:[NSNumber class]]) {
                                             NSLog(@"unexpected response from %@:\n%@", req.URL.host,
                                                   [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
                                             return;
                                         }
                                         
                                         uint64_t newFee = [json[@"fee_per_kb"] unsignedLongLongValue];
                                         NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
                                         
                                         if (newFee >= MIN_FEE_PER_KB && newFee <= MAX_FEE_PER_KB && newFee != [defs doubleForKey:FEE_PER_KB_KEY]) {
                                             NSLog(@"setting new fee-per-kb %lld", newFee);
                                             [defs setDouble:newFee forKey:FEE_PER_KB_KEY]; // use setDouble since setInteger won't hold a uint64_t
                                             _wallet.feePerKb = newFee;
                                         }
                                     }] resume];
    
#else
    return;
#endif
}

@end