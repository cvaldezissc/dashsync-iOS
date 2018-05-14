//
//  DSPeerEntity.m
//  DashSync
//
//  Created by Aaron Voisine on 10/6/13.
//  Copyright (c) 2013 Aaron Voisine <voisine@gmail.com>
//  Updated by Quantum Explorer on 05/11/18.
//  Copyright (c) 2018 Quantum Explorer <quantum@dash.org>
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

#import "DSPeerEntity.h"
#import "DSPeer.h"
#import "DSChain.h"
#import "DSChainEntity+CoreDataClass.h"
#import "NSData+Bitcoin.h"
#import "NSManagedObject+Sugar.h"
#import <arpa/inet.h>

@implementation DSPeerEntity

@dynamic address;
@dynamic timestamp;
@dynamic port;
@dynamic services;
@dynamic misbehavin;
@dynamic lowPreferenceTill;
@dynamic priority;
@dynamic chain;

- (instancetype)setAttributesFromPeer:(DSPeer *)peer
{
    //TODO: store IPv6 addresses
    if (peer.address.u64[0] != 0 || peer.address.u32[2] != CFSwapInt32HostToBig(0xffff)) return nil;

    [self.managedObjectContext performBlockAndWait:^{
        self.address = CFSwapInt32BigToHost(peer.address.u32[3]);
        self.port = peer.port;
        self.timestamp = peer.timestamp;
        self.services = peer.services;
        self.misbehavin = peer.misbehavin;
        self.priority = peer.priority;
        self.lowPreferenceTill = peer.lowPreferenceTill;
    }];

    return self;
}

- (DSPeer *)peer
{
    __block DSPeer *peer = nil;
        
    [self.managedObjectContext performBlockAndWait:^{
        UInt128 address = { .u32 = { 0, 0, CFSwapInt32HostToBig(0xffff), CFSwapInt32HostToBig(self.address) } };
        DSChain * chain = [self.chain chain];
        peer = [[DSPeer alloc] initWithAddress:address port:self.port onChain:chain timestamp:self.timestamp services:self.services];
        peer.misbehavin = self.misbehavin;
        peer.priority = self.priority;
        peer.lowPreferenceTill = self.lowPreferenceTill;
    }];

    return peer;
}

@end
