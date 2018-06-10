//
//  DSStandaloneDerivationPathController.m
//  DashSync_Example
//
//  Created by Sam Westrich on 6/10/18.
//  Copyright © 2018 Andrew Podkovyrin. All rights reserved.
//

#import "DSStandaloneDerivationPathController.h"
#import "DSStandaloneDerivationPathTableViewCell.h"
#import "DSStandaloneDerivationPathKeyInputViewController.h"
#import "DSDerivationPathsAddressesViewController.h"

@interface DSStandaloneDerivationPathController ()

@end

@implementation DSStandaloneDerivationPathController

- (void)viewDidLoad {
    [super viewDidLoad];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

#pragma mark - Table view data source

-(NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.chain.standaloneDerivationPaths count];
}

-(NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

-(UITableViewCell*)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"StandaloneDerivationPathCellIdentifier"];
    
    // Set up the cell...
    [self configureCell:cell atIndexPath:indexPath];
    return cell;
}

-(void)configureCell:(UITableViewCell*)cell atIndexPath:(NSIndexPath *)indexPath {

        DSStandaloneDerivationPathTableViewCell * walletCell = (DSStandaloneDerivationPathTableViewCell*)cell;
        DSDerivationPath * derivationPath = [[self.chain standaloneDerivationPaths] objectAtIndex:indexPath.row];
        walletCell.xPublicKeyLabel.text = [derivationPath serializedExtendedPublicKey];
}

-(CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return 200;
    return 50;
}

-(BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return TRUE;
}

-(void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        
        [self.tableView beginUpdates];
        [self.chain unregisterStandaloneDerivationPath:[self.chain.standaloneDerivationPaths objectAtIndex:indexPath.row]];
        [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
        [self.tableView endUpdates];
    }
}

-(void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.identifier isEqualToString:@"AddStandaloneDerivationPathSegue"]) {
        DSStandaloneDerivationPathKeyInputViewController * standaloneDerivationPathKeyInputViewController = (DSStandaloneDerivationPathKeyInputViewController*)segue.destinationViewController;
        standaloneDerivationPathKeyInputViewController.chain = self.chain;
    } else if ([segue.identifier isEqualToString:@"ViewStandaloneDerivationPathSegue"]) {
        NSIndexPath *indexPath = [self.tableView indexPathForCell:sender];
        DSDerivationPathsAddressesViewController * addresses = (DSDerivationPathsAddressesViewController*)segue.destinationViewController;
        addresses.derivationPath = [self.chain.standaloneDerivationPaths objectAtIndex:indexPath.row];
    }
}

@end
