//
//  OpenSafeView.m
//  StrongBox
//
//  Created by Mark McGuill on 06/06/2014.
//  Copyright (c) 2014 Mark McGuill. All rights reserved.
//

#import "BrowseSafeView.h"
#import "PwSafeSerialization.h"
#import "SelectDestinationGroupController.h"
#import <MessageUI/MessageUI.h>
#import "RecordView.h"
#import "Alerts.h"
#import <ISMessages/ISMessages.h>
#import "Settings.h"
#import "SafeDetailsView.h"
#import "NSArray+Extensions.h"
#import "Utils.h"
#import "NodeIconHelper.h"
#import "BrowseSafeEntryTableViewCell.h"
#import "BrowseGroupTableViewCell.h"
#import "Node+OTPToken.h"
#import "OTPToken+Generation.h"
#import "SetNodeIconUiHelper.h"

@interface BrowseSafeView () <MFMailComposeViewControllerDelegate, UISearchBarDelegate, UISearchResultsUpdating>

@property (strong, nonatomic) NSArray<Node*> *searchResults;
@property (strong, nonatomic) NSArray<Node*> *items;
@property (strong, nonatomic) UISearchController *searchController;
@property (strong, nonatomic) UIBarButtonItem *savedOriginalNavButton;
@property (strong, nonatomic) UILongPressGestureRecognizer *longPressRecognizer;

@property (nonatomic) NSInteger tapCount;
@property (nonatomic) NSIndexPath *tappedIndexPath;
@property (strong, nonatomic) NSTimer *tapTimer;

@property NSTimer* timerRefreshOtp;
@property (strong) SetNodeIconUiHelper* sni; // Required: Or Delegate does not work!

@property NSMutableArray<NSArray<NSNumber*>*>* reorderItemOperations;
@property BOOL sortOrderDescending;

@end

@implementation BrowseSafeView

static NSComparator searchResultsComparator = ^(id obj1, id obj2) {
    Node* n1 = (Node*)obj1;
    Node* n2 = (Node*)obj2;
    
    if(n1.isGroup && !n2.isGroup) {
        return NSOrderedDescending;
    }
    else if(!n1.isGroup && n2.isGroup) {
        return NSOrderedAscending;
    }
    
    NSComparisonResult result = [n1.title compare:n2.title options:NSCaseInsensitiveSearch];
    
    if(result == NSOrderedSame) {
        return [n1.title compare:n2.title];
    }
    
    return result;
};

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    [self refresh];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    
    if(self.timerRefreshOtp) {
        [self.timerRefreshOtp invalidate];
        self.timerRefreshOtp = nil;
    }
}

- (IBAction)updateOtpCodes:(id)sender {
    if(![self.tableView isEditing]) { // DO not update during edit, cancels left swipe menu and edit selections!
        [self.tableView reloadData]; // FUTURE: Only update OTP rows
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    //self.customIconsCache = [NSMutableDictionary dictionary];
    
    self.longPressRecognizer = [[UILongPressGestureRecognizer alloc]
                                initWithTarget:self
                                action:@selector(handleLongPress:)];
    self.longPressRecognizer.minimumPressDuration = 1;
    self.longPressRecognizer.cancelsTouchesInView = YES;
    
    [self.tableView addGestureRecognizer:self.longPressRecognizer];
    
    self.tableView.allowsMultipleSelection = NO;
    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    self.tableView.allowsSelectionDuringEditing = YES;
    
    if(Settings.sharedInstance.hideTips) {
        self.navigationItem.prompt = nil;
    }
    if (!Settings.sharedInstance.hideTips && (!self.currentGroup || self.currentGroup.parent == nil)) {
        if(arc4random_uniform(100) < 50) {
            [ISMessages showCardAlertWithTitle:@"Fast Password Copy"
                                       message:@"Tap and hold entry for fast password copy"
                                      duration:2.5f
                                   hideOnSwipe:YES
                                     hideOnTap:YES
                                     alertType:ISAlertTypeSuccess
                                 alertPosition:ISAlertPositionBottom
                                       didHide:nil];
        }
        else {
            [ISMessages showCardAlertWithTitle:@"Fast Username Copy"
                                       message:@"Double Tap for fast username copy"
                                      duration:2.5f
                                   hideOnSwipe:YES
                                     hideOnTap:YES
                                     alertType:ISAlertTypeSuccess
                                 alertPosition:ISAlertPositionBottom
                                       didHide:nil];
        }
    }
    
    self.extendedLayoutIncludesOpaqueBars = YES;
    self.definesPresentationContext = YES;
    
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.dimsBackgroundDuringPresentation = NO;
    self.searchController.searchBar.delegate = self;
    self.searchController.searchBar.scopeButtonTitles = @[@"Title", @"Username", @"Password", @"All Fields"];
    self.searchController.searchBar.selectedScopeButtonIndex = 3;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return !self.viewModel.isUsingOfflineCache && !self.viewModel.isReadOnly;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
    return self.viewModel.database.format != kPasswordSafe && Settings.sharedInstance.uiDoNotSortKeePassNodesInBrowseView;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath
{
    if(![sourceIndexPath isEqual:destinationIndexPath]) {
        NSLog(@"Move Row at %@ to %@", sourceIndexPath, destinationIndexPath);
        
        if(self.reorderItemOperations == nil) {
            self.reorderItemOperations = [NSMutableArray array];
        }
        [self.reorderItemOperations addObject:@[@(sourceIndexPath.row), @(destinationIndexPath.row)]];

        [self enableDisableToolbarButtons]; // Disable moving/deletion if there's been a move
    }
}

- (IBAction)onSortItems:(id)sender {
    self.reorderItemOperations = nil; // Discard existing reordering ops...
    
    self.sortOrderDescending = !self.sortOrderDescending;
    [self.currentGroup sortChildren:self.sortOrderDescending];
    
    [self saveChangesToSafeAndRefreshView];
}

- (void)addHistoricalNode:(Node*)item originalNodeForHistory:(Node*)originalNodeForHistory {
    BOOL shouldAddHistory = YES; // FUTURE: Config on/off? only valid for KeePass 2+ also...
    if(shouldAddHistory && originalNodeForHistory != nil) {
        [item.fields.keePassHistory addObject:originalNodeForHistory];
    }
}

- (void)onRenameItem:(NSIndexPath * _Nonnull)indexPath {
    Node *item = [[self getDataSource] objectAtIndex:indexPath.row];
    
    [Alerts OkCancelWithTextField:self
                    textFieldText:item.title
                            title:@"Rename Item"
                          message:@"Please enter a new title for this item"
                       completion:^(NSString *text, BOOL response) {
                           if(response && [text length]) {
                               if(!item.isGroup) {
                                   Node* originalNodeForHistory = [item cloneForHistory];
                                   [self addHistoricalNode:item originalNodeForHistory:originalNodeForHistory];
                               }
                               
                               item.fields.accessed = [NSDate date];
                               item.fields.modified = [NSDate date];
                               
                               item.title = text;
                               
                               [self saveChangesToSafeAndRefreshView];
                           }
                       }];
}

- (void)onDeleteSingleItem:(NSIndexPath * _Nonnull)indexPath {
    [Alerts yesNo:self.searchController.isActive ? self.searchController : self
            title:@"Are you sure?"
          message:@"Are you sure you want to delete this item?"
           action:^(BOOL response) {
               if (response) {
                    Node *item = [[self getDataSource] objectAtIndex:indexPath.row];

                    [self.viewModel deleteItem:item];

                    [self saveChangesToSafeAndRefreshView];
               }
           }];
}

- (void)onSetIconForItem:(NSIndexPath * _Nonnull)indexPath {
    Node *item = [[self getDataSource] objectAtIndex:indexPath.row];

    self.sni = [[SetNodeIconUiHelper alloc] init];
    
    NSString* urlHint;
    if(!item.isGroup) {
        urlHint = item.fields.url;
        if(!urlHint.length) {
            urlHint = item.title;
        }
    }    
    
    [self.sni changeIcon:self urlHint:urlHint format:self.viewModel.database.format completion:^(BOOL goNoGo, NSNumber* userSelectedNewIconIndex, UIImage* userSelectedNewCustomIcon) {
        NSLog(@"completion: %d - %@-%@", goNoGo, userSelectedNewIconIndex, userSelectedNewCustomIcon);
        if(goNoGo) {
            if(!item.isGroup) {
                Node* originalNodeForHistory = [item cloneForHistory];
                [self addHistoricalNode:item originalNodeForHistory:originalNodeForHistory];
            }
            
            item.fields.accessed = [NSDate date];
            item.fields.modified = [NSDate date];
            
            if(userSelectedNewCustomIcon) {
                NSData *data = UIImagePNGRepresentation(userSelectedNewCustomIcon);
                [self.viewModel.database setNodeCustomIcon:item data:data];
            }
            else if(userSelectedNewIconIndex) {
                if(userSelectedNewIconIndex.intValue == -1) {
                    item.iconId = !item.isGroup ? @(0) : @(48); // Default
                }
                else {
                    item.iconId = userSelectedNewIconIndex;
                }
                item.customIconUuid = nil;
            }
            
            [self saveChangesToSafeAndRefreshView];
        }
    }];
}

- (nullable NSArray<UITableViewRowAction *> *)tableView:(UITableView *)tableView editActionsForRowAtIndexPath:(nonnull NSIndexPath *)indexPath {
    UITableViewRowAction *removeAction = [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleDestructive title:@"Delete" handler:^(UITableViewRowAction * _Nonnull action, NSIndexPath * _Nonnull indexPath) {
        [self onDeleteSingleItem:indexPath];
    }];
    
    UITableViewRowAction *renameAction = [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleNormal title:@"Rename" handler:^(UITableViewRowAction * _Nonnull action, NSIndexPath * _Nonnull indexPath) {
        [self onRenameItem:indexPath];
    }];
    renameAction.backgroundColor = UIColor.blueColor;
    
    UITableViewRowAction *setIconAction = [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleNormal title:@"Set Icon" handler:^(UITableViewRowAction * _Nonnull action, NSIndexPath * _Nonnull indexPath) {
        [self onSetIconForItem:indexPath];
    }];
    
    setIconAction.backgroundColor = UIColor.purpleColor;

    return self.viewModel.database.format != kPasswordSafe ? @[removeAction, renameAction, setIconAction] : @[removeAction, renameAction];
}

- (BOOL)shouldPerformSegueWithIdentifier:(NSString *)identifier sender:(id)sender {
    //ignore segue from cell since we we are calling manually in didSelectRowAtIndexPath
    return !self.isEditing && (sender == self || [identifier isEqualToString:@"segueToSafeSettings"]);
}

- (NSArray<Node *> *)getDataSource {
    return (self.searchController.isActive ? self.searchResults : self.items);
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *searchString = searchController.searchBar.text;
    
    [self filterContentForSearchText:searchString scope:searchController.searchBar.selectedScopeButtonIndex];
    [self.tableView reloadData];
}

- (void)filterContentForSearchText:(NSString *)searchText scope:(NSInteger)scope {
    NSPredicate *predicate;
    BOOL searchAll = NO;
    
    if (scope == 0) {
        predicate = [NSPredicate predicateWithFormat:@"title contains[c] %@", searchText];
    }
    else if (scope == 1)
    {
        predicate = [NSPredicate predicateWithFormat:@"fields.username contains[c] %@", searchText];
    }
    else if (scope == 2)
    {
        predicate = [NSPredicate predicateWithFormat:@"fields.password contains[c] %@", searchText];
    }
    else {
        searchAll = YES;
        predicate = [NSPredicate predicateWithFormat:@"title contains[c] %@ "
                     @"OR fields.password contains[c] %@  "
                     @"OR fields.username contains[c] %@  "
                     @"OR fields.email contains[c] %@  "
                     @"OR fields.url contains[c] %@ "
                     @"OR fields.notes contains[c] %@",
                     searchText, searchText, searchText, searchText, searchText, searchText];
    }
    
    NSArray<Node*> *foo = [self.viewModel.database.rootGroup filterChildren:YES predicate:^BOOL(Node * _Nonnull node) {
        if([predicate evaluateWithObject:node]) {
            return YES;
        }
        else if(searchAll && (self.viewModel.database.format == kKeePass4 || self.viewModel.database.format == kKeePass)) {
            // Search inside custom fields... can't find easy way to do this by predicate!
            
            for (NSString* key in node.fields.customFields.allKeys) {
                NSString* value = node.fields.customFields[key];
                
                if([key rangeOfString:searchText options:NSCaseInsensitiveSearch].location != NSNotFound ||
                   [value rangeOfString:searchText options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    return YES;
                }
            }
        }
        
        return NO;
    }];
    
    // Filter out any results from the KDB root 'Backup' group/folder if configured so...
    
    if(!Settings.sharedInstance.showKeePass1BackupGroup) {
        if (self.viewModel.database.format == kKeePass1) {
            Node* backupGroup = [self.viewModel.database.rootGroup findFirstChild:NO predicate:^BOOL(Node * _Nonnull node) {
                return [node.title isEqualToString:@"Backup"];
            }];
            
            if(backupGroup) {
                foo = [foo filter:^BOOL(Node * _Nonnull obj) {
                    return (obj != backupGroup && ![backupGroup contains:obj]);
                }];
            }
        }
    }
    
    self.searchResults = [foo sortedArrayUsingComparator:searchResultsComparator];
}

- (void)searchBar:(UISearchBar *)searchBar selectedScopeButtonIndexDidChange:(NSInteger)selectedScope {
    [self updateSearchResultsForSearchController:self.searchController];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self getDataSource].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    Node *node = [self getDataSource][indexPath.row];
    if(node.isGroup) {
        BrowseGroupTableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"GroupCell" forIndexPath:indexPath];
        cell.title.text = node.title;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.icon.image = [NodeIconHelper getIconForNode:node database:self.viewModel.database];
        
        return cell;
    }
    else {
        BrowseSafeEntryTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"OpenSafeViewCell" forIndexPath:indexPath];

        NSString *groupLocation = self.searchController.isActive ? [self getGroupPathDisplayString:node] : @"";
        
        cell.title.text = node.title;
        cell.username.text = node.fields.username;
        cell.path.text = groupLocation;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.icon.image = [NodeIconHelper getIconForNode:node database:self.viewModel.database];
        cell.flags.text = node.fields.attachments.count > 0 ? @"📎" : @"";

        [self setOtpCellProperties:cell node:node];
        
        return cell;
    }
}

- (void)setOtpCellProperties:(BrowseSafeEntryTableViewCell*)cell node:(Node*)node {
    if(!Settings.sharedInstance.hideTotpInBrowse && node.otpToken) {
        uint64_t remainingSeconds = node.otpToken.period - ((uint64_t)([NSDate date].timeIntervalSince1970) % (uint64_t)node.otpToken.period);
        
        cell.otpCode.text = [NSString stringWithFormat:@"%@", node.otpToken.password];
        cell.otpCode.textColor = (remainingSeconds < 5) ? [UIColor redColor] : (remainingSeconds < 9) ? [UIColor orangeColor] : [UIColor blueColor];
        
        cell.otpCode.alpha = 1;
        
        if(remainingSeconds < 16) {
            [UIView animateWithDuration:0.45 delay:0.0 options:UIViewAnimationOptionRepeat | UIViewAnimationOptionAutoreverse animations:^{
                cell.otpCode.alpha = 0.5;
            } completion:nil];
        }
    }
    else {
        cell.otpCode.text = @"";
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if(self.tapCount == 1 && self.tapTimer != nil && [self.tappedIndexPath isEqual:indexPath]){
        [self.tapTimer invalidate];

        self.tapTimer = nil;
        self.tapCount = 0;
        self.tappedIndexPath = nil;

        [self handleDoubleTap:indexPath];
    }
    else if(self.tapCount == 0){
        //This is the first tap. If there is no tap till tapTimer is fired, it is a single tap
        self.tapCount = self.tapCount + 1;
        self.tappedIndexPath = indexPath;
        self.tapTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(tapTimerFired:) userInfo:nil repeats:NO];
    }
    else if(![self.tappedIndexPath isEqual:indexPath]){
        //tap on new row
        self.tapCount = 0;
        self.tappedIndexPath = indexPath;
        if(self.tapTimer != nil){
            [self.tapTimer invalidate];
            self.tapTimer = nil;
        }
    }
}

- (void)tapTimerFired:(NSTimer *)aTimer{
    //timer fired, there was a single tap on indexPath.row = tappedRow
    [self tapOnCell:self.tappedIndexPath];
    
    self.tapCount = 0;
    self.tappedIndexPath = nil;
    self.tapTimer = nil;
}

- (void)tapOnCell:(NSIndexPath *)indexPath  {
    if (!self.editing) {
        NSArray* arr = [self getDataSource];
        
        if(indexPath.row >= arr.count) {
            return;
        }
        
        Node *item = arr[indexPath.row];

        if (!item.isGroup) {
            [self performSegueWithIdentifier:@"segueToRecord" sender:item];
        }
        else {
            [self performSegueWithIdentifier:@"sequeToSubgroup" sender:item];
        }
    }
    else {
        [self enableDisableToolbarButtons];
    }
}

- (void)enableDisableToolbarButtons {
    BOOL ro = self.viewModel.isUsingOfflineCache || self.viewModel.isReadOnly;
    
    (self.buttonAddRecord).enabled = !ro && !self.isEditing && self.currentGroup.childRecordsAllowed;
    (self.buttonSafeSettings).enabled = !self.isEditing;
    (self.buttonMove).enabled = !ro && self.isEditing && self.tableView.indexPathsForSelectedRows.count > 0 && self.reorderItemOperations.count == 0;
    (self.buttonDelete).enabled = !ro && self.isEditing && self.tableView.indexPathsForSelectedRows.count > 0 && self.reorderItemOperations.count == 0;
    
    (self.buttonSortItems).enabled = !ro && self.isEditing && self.viewModel.database.format != kPasswordSafe && Settings.sharedInstance.uiDoNotSortKeePassNodesInBrowseView;
    [self.buttonSortItems setImage:self.sortOrderDescending ? [UIImage imageNamed:@"sort-32-descending"] : [UIImage imageNamed:@"sort-32"]];
        
    (self.buttonAddGroup).enabled = !ro && !self.isEditing;
}

- (void)refresh {
    self.navigationItem.title = [NSString stringWithFormat:@"%@%@%@",
                                 (self.currentGroup.parent == nil) ?
                                 self.viewModel.metadata.nickName : self.currentGroup.title,
                                 self.viewModel.isUsingOfflineCache ? @" [Offline]" : @"",
                                 self.viewModel.isReadOnly ? @" [Read Only]" : @""];

    NSMutableArray* unsorted = [[NSMutableArray alloc] initWithArray:self.currentGroup.children];
    BOOL sortNodes = self.viewModel.database.format == kPasswordSafe || !Settings.sharedInstance.uiDoNotSortKeePassNodesInBrowseView;
    if(sortNodes) {
        [unsorted sortUsingComparator:finderStyleNodeComparator];
    }
    self.items = unsorted;
    
    // Filter KeePass1 Backup Group if so configured...
    
    if(!Settings.sharedInstance.showKeePass1BackupGroup) {
        if (self.viewModel.database.format == kKeePass1) {
            Node* backupGroup = [self.viewModel.database.rootGroup findFirstChild:NO predicate:^BOOL(Node * _Nonnull node) {
                return [node.title isEqualToString:@"Backup"];
            }];
            
            if(backupGroup) {
                if([self.currentGroup contains:backupGroup]) {
                    self.items = [self.currentGroup.children filter:^BOOL(Node * _Nonnull obj) {
                        return obj != backupGroup;
                    }];
                }
            }
        }
    }
    
    // Display
    
    [self updateSearchResultsForSearchController:self.searchController];
    
    [self.tableView reloadData];
    
    self.navigationItem.rightBarButtonItem = (!self.viewModel.isUsingOfflineCache &&
                                              !self.viewModel.isReadOnly &&
                                              [self getDataSource].count > 0) ? self.editButtonItem : nil;
    
    [self enableDisableToolbarButtons];

    if ([[Settings sharedInstance] isProOrFreeTrial]) {
        if (@available(iOS 11.0, *)) {
            self.navigationController.navigationBar.prefersLargeTitles = YES;
            
            self.navigationItem.searchController = self.searchController;
            
            // We want the search bar visible all the time.
            self.navigationItem.hidesSearchBarWhenScrolling = NO;
        } else {
            self.tableView.tableHeaderView = self.searchController.searchBar;
            [self.searchController.searchBar sizeToFit];
        }
    }
    
    self.navigationController.toolbarHidden = NO;
    self.navigationController.toolbar.hidden = NO;
    
    [self.navigationController setNavigationBarHidden:NO];
    self.navigationController.navigationBar.hidden = NO;
    self.navigationController.navigationBarHidden = NO;
    
    // Any OTPs we should start a refresh timer if so...
    
    [self startOtpRefreshTimerIfAppropriate];
}

- (void)startOtpRefreshTimerIfAppropriate {
    if(self.timerRefreshOtp) {
        [self.timerRefreshOtp invalidate];
        self.timerRefreshOtp = nil;
    }
    
    if(!Settings.sharedInstance.hideTotpInBrowse) {
        self.timerRefreshOtp = [NSTimer timerWithTimeInterval:1.0f target:self selector:@selector(updateOtpCodes:) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.timerRefreshOtp forMode:NSRunLoopCommonModes];
    }
}

- (NSString *)getGroupPathDisplayString:(Node *)vm {
    NSArray<NSString*> *hierarchy = [vm getTitleHierarchy];
    
    NSString *path = [[hierarchy subarrayWithRange:NSMakeRange(0, hierarchy.count - 1)] componentsJoinedByString:@"/"];
    
    return hierarchy.count == 1 ? @"(in /)" : [NSString stringWithFormat:@"(in /%@)", path];
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.identifier isEqualToString:@"segueToRecord"]) {
        Node *record = (Node *)sender;
        RecordView *vc = segue.destinationViewController;
        vc.record = record;
        vc.parentGroup = self.currentGroup;
        vc.viewModel = self.viewModel;
    }
    else if ([segue.identifier isEqualToString:@"sequeToSubgroup"])
    {
        BrowseSafeView *vc = segue.destinationViewController;
        
        vc.currentGroup = (Node *)sender;
        vc.viewModel = self.viewModel;
    }
    else if ([segue.identifier isEqualToString:@"segueToSelectDestination"])
    {
        NSArray *itemsToMove = (NSArray *)sender;
        
        UINavigationController *nav = segue.destinationViewController;
        SelectDestinationGroupController *vc = nav.viewControllers.firstObject;
        
        vc.currentGroup = self.viewModel.database.rootGroup;
        vc.viewModel = self.viewModel;
        vc.itemsToMove = itemsToMove;
    }
    else if ([segue.identifier isEqualToString:@"segueToSafeSettings"])
    {
        SafeDetailsView *vc = segue.destinationViewController;
        vc.viewModel = self.viewModel;
    }
}

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (IBAction)onAddGroup:(id)sender {
    [Alerts OkCancelWithTextField:self
             textFieldPlaceHolder:@"Group Name"
                            title:@"Enter Group Name"
                          message:@"Please Enter the New Group Name:"
                       completion:^(NSString *text, BOOL response) {
                           if (response) {
                               if ([self.viewModel addNewGroup:self.currentGroup title:text] != nil) {
                                   [self saveChangesToSafeAndRefreshView];
                               }
                               else {
                                   [Alerts warn:self title:@"Cannot create group" message:@"Could not create a group with this name here, possibly because one with this name already exists."];
                               }
                           }
                       }];
}

- (IBAction)onAddRecord:(id)sender {
    [self performSegueWithIdentifier:@"segueToRecord" sender:nil];
}

- (IBAction)onMove:(id)sender {
    NSArray *selectedRows = (self.tableView).indexPathsForSelectedRows;
    
    if (selectedRows.count > 0) {
        NSArray<Node *> *itemsToMove = [self getSelectedItems:selectedRows];
        
        [self performSegueWithIdentifier:@"segueToSelectDestination" sender:itemsToMove];
        
        [self setEditing:NO animated:YES];
    }
}

- (IBAction)onDeleteToolbarButton:(id)sender {
    NSArray *selectedRows = (self.tableView).indexPathsForSelectedRows;
    
    if (selectedRows.count > 0) {
        [Alerts yesNo:self.searchController.isActive ? self.searchController : self
                title:@"Are you sure?"
              message:@"Are you sure you want to delete these item(s)?"
               action:^(BOOL response) {
                   if (response) {
                       NSArray<Node *> *items = [self getSelectedItems:selectedRows];
                       
                       for (Node* item in items) {
                           [self.viewModel deleteItem:item];
                       }
                       
                       [self saveChangesToSafeAndRefreshView];
                   }
               }];
    }
}

- (NSArray<Node*> *)getSelectedItems:(NSArray<NSIndexPath *> *)selectedRows {
    NSMutableIndexSet *indicesOfItems = [NSMutableIndexSet new];
    
    for (NSIndexPath *selectionIndex in selectedRows) {
        [indicesOfItems addIndex:selectionIndex.row];
    }
    
    NSArray *items = [[self getDataSource] objectsAtIndexes:indicesOfItems];
    return items;
}

- (void)saveChangesToSafeAndRefreshView {
    [self refresh];
    
    [self.viewModel update:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^(void) {
            [self setEditing:NO animated:YES];
            
            [self refresh];
            
            if (error) {
                [Alerts error:self title:@"Error Saving" error:error];
            }
        });
    }];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animate {
    [super setEditing:editing animated:animate];
    
    NSLog(@"setEditing: %d", editing);
    
    [self enableDisableToolbarButtons];
    
    //NSLog(@"setEditing: %hhd", editing);
    
    if (!editing) {
        self.navigationItem.leftBarButtonItem = self.savedOriginalNavButton;
        if(self.reorderItemOperations) {
            // Do the reordering
            NSLog(@"Reordering");
            
            for (NSArray<NSNumber*>* moveOp in self.reorderItemOperations) {
                NSUInteger src = moveOp[0].unsignedIntegerValue;
                NSUInteger dest = moveOp[1].unsignedIntegerValue;
                NSLog(@"Move: %lu -> %lu", (unsigned long)src, (unsigned long)dest);
                [self.currentGroup moveChild:src to:dest];
            }
            
            self.reorderItemOperations = nil;
            [self saveChangesToSafeAndRefreshView];
        }
    }
    else {
        self.reorderItemOperations = nil;
        
        UIBarButtonItem *cancelButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                      target:self
                                                                                      action:@selector(cancelEditing)];
        
        self.savedOriginalNavButton = self.navigationItem.leftBarButtonItem;
        self.navigationItem.leftBarButtonItem = cancelButton;
    }
}

- (void)cancelEditing {
    self.reorderItemOperations = nil;
    [self setEditing:false];
}

- (void)handleDoubleTap:(NSIndexPath *)indexPath {
    Node *item = [self getDataSource][indexPath.row];
    
    if (item.isGroup) {
        NSLog(@"Item is group, cannot Fast Username Copy...");
        
        [self performSegueWithIdentifier:@"sequeToSubgroup" sender:item];
        
        return;
    }
    
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    
    pasteboard.string = item.fields.username;
    
    [ISMessages showCardAlertWithTitle:[NSString stringWithFormat:@"%@ Username Copied", item.title]
                               message:nil
                              duration:3.f
                           hideOnSwipe:YES
                             hideOnTap:YES
                             alertType:ISAlertTypeSuccess
                         alertPosition:ISAlertPositionTop
                               didHide:nil];
    
    NSLog(@"Fast Username Copy on %@", item.title);

    if(!self.isEditing) {
        [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
    }
}

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Long Press

- (void)handleLongPress:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan) {
        return;
    }
    
    CGPoint tapLocation = [self.longPressRecognizer locationInView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:tapLocation];
    
    if (!indexPath || indexPath.row >= [self getDataSource].count) {
        NSLog(@"Not on a cell");
        return;
    }
    
    Node *item = [self getDataSource][indexPath.row];
    
    if (item.isGroup) {
        NSLog(@"Item is group, cannot Fast PW Copy...");
        return;
    }
    
    NSLog(@"Fast Password Copy on %@", item.title);
    
    BOOL promptedForCopyPw = [[Settings sharedInstance] isHasPromptedForCopyPasswordGesture];
    BOOL copyPw = [[Settings sharedInstance] isCopyPasswordOnLongPress];
    
    NSLog(@"Long press detected on Record. Copy Featured is [%@]", copyPw ? @"Enabled" : @"Disabled");
    
    if (!copyPw && !promptedForCopyPw) { // If feature is turned off (or never set) and we haven't prompted user about it... prompt
        [Alerts yesNo:self
                title:@"Copy Password?"
              message:@"By Touching and Holding an entry for 2 seconds you can quickly copy the password to the clipboard. Would you like to enable this feature?"
               action:^(BOOL response) {
                   [[Settings sharedInstance] setCopyPasswordOnLongPress:response];
                   
                   if (response) {
                       [self copyPasswordOnLongPress:item withTapLocation:tapLocation];
                   }
               }];
        
        [[Settings sharedInstance] setHasPromptedForCopyPasswordGesture:YES];
    }
    else if (copyPw)
    {
        [self copyPasswordOnLongPress:item withTapLocation:tapLocation];
    }
}

- (void)copyPasswordOnLongPress:(Node *)item withTapLocation:(CGPoint)tapLocation {
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    
    pasteboard.string = item.fields.password;
    
    [ISMessages showCardAlertWithTitle:[NSString stringWithFormat:@"%@ Password Copied", item.title]
                               message:nil
                              duration:3.f
                           hideOnSwipe:YES
                             hideOnTap:YES
                             alertType:ISAlertTypeSuccess
                         alertPosition:ISAlertPositionTop
                               didHide:nil];
}

@end
