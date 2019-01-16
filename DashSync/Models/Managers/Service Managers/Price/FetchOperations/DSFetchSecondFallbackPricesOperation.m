//
//  Created by Andrew Podkovyrin
//  Copyright © 2018 Dash Core Group. All rights reserved.
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

#import "DSFetchSecondFallbackPricesOperation.h"

#import "DSChainedOperation.h"
#import "DSCurrencyPriceObject.h"
#import "DSHTTPOperation.h"
#import "DSOperationQueue.h"
#import "DSParseBitPayResponseOperation.h"
#import "DSParseDashCasaResponseOperation.h"
#import "DSParseDashCentralResponseOperation.h"
#import "DSParsePoloniexResponseOperation.h"

NS_ASSUME_NONNULL_BEGIN

#define BITPAY_TICKER_URL @"https://bitpay.com/rates"
#define POLONIEX_TICKER_URL @"https://poloniex.com/public?command=returnOrderBook&currencyPair=BTC_DASH&depth=1"
#define DASHCENTRAL_TICKER_URL @"https://www.dashcentral.org/api/v1/public"
#define DASHCASA_TICKER_URL @"http://dash.casa/api/?cur=VES"

@interface DSFetchSecondFallbackPricesOperation ()

@property (strong, nonatomic) DSParseBitPayResponseOperation *parseBitPayOperation;
@property (strong, nonatomic) DSParsePoloniexResponseOperation *parsePoloniexOperation;
@property (strong, nonatomic) DSParseDashCentralResponseOperation *parseDashcentralOperation;
@property (strong, nonatomic) DSParseDashCasaResponseOperation *parseDashCasaOperation;
@property (strong, nonatomic) DSChainedOperation *chainBitPayOperation;
@property (strong, nonatomic) DSChainedOperation *chainPoloniexOperation;
@property (strong, nonatomic) DSChainedOperation *chainDashcentralOperation;
@property (strong, nonatomic) DSChainedOperation *chainDashCasaOperation;

@property (copy, nonatomic) void (^fetchCompletion)(NSArray<DSCurrencyPriceObject *> *_Nullable);

@end

@implementation DSFetchSecondFallbackPricesOperation

- (DSOperation *)initOperationWithCompletion:(void (^)(NSArray<DSCurrencyPriceObject *> *_Nullable))completion {
    self = [super initWithOperations:nil];
    if (self) {
        {
            NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:BITPAY_TICKER_URL]
                                                     cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                 timeoutInterval:10.0];
            DSHTTPOperation *getOperation = [[DSHTTPOperation alloc] initWithRequest:request];
            DSParseBitPayResponseOperation *parseOperation = [[DSParseBitPayResponseOperation alloc] init];
            DSChainedOperation *chainOperation = [DSChainedOperation operationWithOperations:@[ getOperation, parseOperation ]];
            _parseBitPayOperation = parseOperation;
            _chainBitPayOperation = chainOperation;
            [self addOperation:chainOperation];
        }
        {
            NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:POLONIEX_TICKER_URL]
                                                     cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                 timeoutInterval:30.0];
            DSHTTPOperation *getOperation = [[DSHTTPOperation alloc] initWithRequest:request];
            DSParsePoloniexResponseOperation *parseOperation = [[DSParsePoloniexResponseOperation alloc] init];
            DSChainedOperation *chainOperation = [DSChainedOperation operationWithOperations:@[ getOperation, parseOperation ]];
            _parsePoloniexOperation = parseOperation;
            _chainPoloniexOperation = chainOperation;
            [self addOperation:chainOperation];
        }
        {
            NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:DASHCENTRAL_TICKER_URL]
                                                     cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                 timeoutInterval:30.0];
            DSHTTPOperation *getOperation = [[DSHTTPOperation alloc] initWithRequest:request];
            DSParseDashCentralResponseOperation *parseOperation = [[DSParseDashCentralResponseOperation alloc] init];
            DSChainedOperation *chainOperation = [DSChainedOperation operationWithOperations:@[ getOperation, parseOperation ]];
            _parseDashcentralOperation = parseOperation;
            _chainDashcentralOperation = chainOperation;
            [self addOperation:chainOperation];
        }
        {
            NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:DASHCASA_TICKER_URL]
                                                     cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                 timeoutInterval:30.0];
            DSHTTPOperation *getOperation = [[DSHTTPOperation alloc] initWithRequest:request];
            DSParseDashCasaResponseOperation *parseOperation = [[DSParseDashCasaResponseOperation alloc] init];
            DSChainedOperation *chainOperation = [DSChainedOperation operationWithOperations:@[ getOperation, parseOperation ]];
            _parseDashCasaOperation = parseOperation;
            _chainDashCasaOperation = chainOperation;
            [self addOperation:chainOperation];
        }

        _fetchCompletion = [completion copy];
    }
    return self;
}

- (void)operationDidFinish:(NSOperation *)operation withErrors:(nullable NSArray<NSError *> *)errors {
    if (self.cancelled) {
        return;
    }

    if (errors.count > 0) {
        [self.chainDashBtcCCOperation cancel];
        [self.chainDashVesCCOperation cancel];
        [self.chainBitcoinAvgOperation cancel];
    }
}

- (void)finishedWithErrors:(NSArray<NSError *> *)errors {
    if (self.cancelled) {
        return;
    }

    if (errors.count > 0) {
        self.fetchCompletion(nil);

        return;
    }

    NSArray *currencyCodes = self.parseBitPayOperation.currencyCodes;
    NSArray *currencyPrices = self.parseBitPayOperation.currencyPrices;
    NSNumber *poloniexPriceNumber = self.parsePoloniexOperation.lastTradePriceNumber;
    NSNumber *dashcentralPriceNumber = self.parseDashcentralOperation.btcDashPrice;
    NSNumber *dashcasaPrice = self.parseDashCasaOperation.dashrate;

    // not enough data to build prices
    if (!currencyCodes ||
        !currencyPrices ||
        !(poloniexPriceNumber || dashcentralPriceNumber) ||
        currencyCodes.count != currencyPrices.count) {

        self.fetchCompletion(nil);

        return;
    }

    double poloniexPrice = poloniexPriceNumber.doubleValue;
    double dashcentralPrice = dashcentralPriceNumber.doubleValue;
    double btcDashPrice = 0.0;
    if (poloniexPrice > 0.0) {
        if (dashcentralPrice > 0.0) {
            btcDashPrice = (poloniexPrice + dashcentralPrice) / 2.0;
        }
        else {
            btcDashPrice = poloniexPrice;
        }
    }
    else if (dashcentralPrice > 0.0) {
        btcDashPrice = dashcentralPrice;
    }

    if (btcDashPrice < DBL_EPSILON) {
        self.fetchCompletion(nil);

        return;
    }

    NSMutableArray<DSCurrencyPriceObject *> *prices = [NSMutableArray array];
    for (NSString *code in currencyCodes) {
        NSUInteger index = [currencyCodes indexOfObject:code];
        NSNumber *btcPrice = currencyPrices[index];
        NSNumber *price = @(btcPrice.doubleValue * btcDashPrice);
        if ([code isEqualToString:@"VES"] && dashcasaPrice) {
            price = dashcasaPrice;
        }
        DSCurrencyPriceObject *priceObject = [[DSCurrencyPriceObject alloc] initWithCode:code price:price];
        if (priceObject) {
            [prices addObject:priceObject];
        }
    }

    self.fetchCompletion([prices copy]);
}

@end

NS_ASSUME_NONNULL_END
