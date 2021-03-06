//
//  SafeDetailsView.m
//  StrongBox
//
//  Created by Mark on 09/09/2017.
//  Copyright © 2017 Mark McGuill. All rights reserved.
//

#import "SafeDetailsView.h"
#import "IOsUtils.h"
#import <MessageUI/MessageUI.h>
#import "Alerts.h"
#import "CHCSVParser.h"
#import "Settings.h"
#import "ISMessages.h"
#import "Utils.h"
#import "Csv.h"
#import <MobileCoreServices/MobileCoreServices.h>
#import "KeyFileParser.h"
#import "PinsConfigurationController.h"

@interface Delegate : NSObject <CHCSVParserDelegate>

@property (readonly) NSArray *lines;

@end

@interface SafeDetailsView () <MFMailComposeViewControllerDelegate, UIDocumentPickerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>

@end

@implementation SafeDetailsView

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    [self updateTouchIdButtonText];
    [self updateOfflineCacheButtonText];
    [self updateAutoFillCacheButtonText];
    [self bindReadOnly];

    self.labelChangeMasterPassword.enabled = [self canChangeMasterPassword];
    self.labelChangeKeyFile.enabled = [self canChangeKeyFile];
    self.labelToggleTouchId.enabled = [self canToggleTouchId];
    self.labelToggleOfflineCache.enabled = [self canToggleOfflineCache];

    self.labelMostPopularUsername.text = self.viewModel.database.mostPopularUsername ? self.viewModel.database.mostPopularUsername : @"<None>";
    self.labelMostPopularEmail.text = self.viewModel.database.mostPopularEmail ? self.viewModel.database.mostPopularEmail : @"<None>";
    self.labelNumberOfUniqueUsernames.text = [NSString stringWithFormat:@"%lu", (unsigned long)[self.viewModel.database.usernameSet count]];
    self.labelNumberOfUniqueEmails.text = [NSString stringWithFormat:@"%lu", (unsigned long)[self.viewModel.database.emailSet count]];
    self.labelNumberOfUniquePasswords.text = [NSString stringWithFormat:@"%lu", (unsigned long)[self.viewModel.database.passwordSet count]];
    self.labelNumberOfGroups.text =  [NSString stringWithFormat:@"%lu", (unsigned long)self.viewModel.database.numberOfGroups];
    self.labelNumberOfRecords.text =  [NSString stringWithFormat:@"%lu", (unsigned long)self.viewModel.database.numberOfRecords];
    
    self.navigationController.toolbarHidden = YES;
    self.navigationController.toolbar.hidden = YES;
    [self.navigationController setNavigationBarHidden:NO];
}

static NSString *getLastCachedDate(NSDate *modDate) {
    if(!modDate) { return @""; }
    
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.timeStyle = NSDateFormatterShortStyle;
    df.dateStyle = NSDateFormatterShortStyle;
    df.doesRelativeDateFormatting = YES;
    df.locale = NSLocale.currentLocale;
    
    NSString *modDateStr = [df stringFromDate:modDate];
    return [NSString stringWithFormat:@"Last Cached: %@", modDateStr];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if(indexPath.section == 0) {
        if(indexPath.row == 0 && [self canChangeMasterPassword]) { // Change Master Password {
            [self onChangeMasterPassword];
        }
        if(indexPath.row == 1 && [self canChangeKeyFile]) { // Change Master Password {
            [self onChangeKeyFile];
        }
        else if (indexPath.row == 2 && [self canToggleOfflineCache]) { // Offline Cache
            [self onToggleOfflineCache];
        }
        else if (indexPath.row == 3) { // Export Safe
            [self onExport];
        }
        else if (indexPath.row == 4  && [self canToggleTouchId]) { // Toggle Touch ID
            [self onToggleTouchId];
        }
        else if (indexPath.row == 5) { // Autofill Cache
            [self onToggleAutoFillCache];
        }
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    
    if(indexPath.section == 2) {
        BasicOrderedDictionary<NSString*, NSString*> *metadataKvps = [self.viewModel.database.metadata kvpForUi];

        if(indexPath.row < metadataKvps.allKeys.count) // Hide extra metadata pairs beyond actual metadata
        {
            NSString* key = [metadataKvps.allKeys objectAtIndex:indexPath.row];
            cell.textLabel.text = key;
            cell.detailTextLabel.text = [metadataKvps objectForKey:key];
        }
    }
    
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    BasicOrderedDictionary<NSString*, NSString*> *metadataKvps = [self.viewModel.database.metadata kvpForUi];
    if(indexPath.section == 2 && indexPath.row >= metadataKvps.allKeys.count) // Hide extra metadata pairs beyond actual metadata
    {
        return 0;
    }
    
    return [super tableView:tableView heightForRowAtIndexPath:indexPath];
}

- (BOOL)canChangeKeyFile {
    return !(self.viewModel.isReadOnly || self.viewModel.isUsingOfflineCache || self.viewModel.database.format == kPasswordSafe);
}

- (BOOL)canChangeMasterPassword {
    return !(self.viewModel.isReadOnly || self.viewModel.isUsingOfflineCache);
}

- (BOOL)canToggleTouchId {
    return Settings.isBiometricIdAvailable && !self.viewModel.isReadOnly;
}

- (BOOL)canToggleOfflineCache {
    return !(self.viewModel.isUsingOfflineCache || !self.viewModel.isCloudBasedStorage);
}

- (void)onChangeKeyFile {
    BOOL using = self.viewModel.database.keyFileDigest != nil;
    
    if(using) {
        [Alerts threeOptions:self title:@"Change Key File"
                     message:nil
           defaultButtonText:using ? @"Select a new Key File" : @"Start using a Key File"
            secondButtonText:@"Stop using the Key File"
             thirdButtonText:@"Cancel" action:^(int response) {
                 if(response == 0) {
                     [self onSelectNewKeyFile];
                 }
                 else if(response == 1) {
                     dispatch_async(dispatch_get_main_queue(), ^{
                         [Alerts yesNo:self title:@"Are you sure?" message:@"Are you sure you want to stop using a Key File?" action:^(BOOL response) {
                             if(response) {
                                 [self changeKeyFile:nil];
                             }
                         }];
                     });
                 }
             }];
    }
    else {
        [self onSelectNewKeyFile];
    }
}

- (void)onSelectNewKeyFile {
    [Alerts threeOptions:self
                   title:@"Key File Source"
                 message:@"Select where you would like to choose your Key File from"
       defaultButtonText:@"Files..."
        secondButtonText:@"Photo Library..."
         thirdButtonText:@"Cancel"
                  action:^(int response) {
                      if(response == 0) {
                          UIDocumentPickerViewController *vc = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[(NSString*)kUTTypeItem] inMode:UIDocumentPickerModeImport];
                          vc.delegate = self;
                          [self presentViewController:vc animated:YES completion:nil];
                      }
                      else if (response == 1) {
                          UIImagePickerController *vc = [[UIImagePickerController alloc] init];
                          vc.videoQuality = UIImagePickerControllerQualityTypeHigh;
                          vc.delegate = self;
                          BOOL available = [UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeSavedPhotosAlbum];
                          
                          if(!available) {
                              [Alerts info:self title:@"Photo Library Unavailable" message:@"Could not access Photo Library. Does Strongbox have Permission?"];
                              return;
                          }
                          
                          vc.mediaTypes = @[(NSString*)kUTTypeImage];
                          vc.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
                          
                          [self presentViewController:vc animated:YES completion:nil];
                      }
                  }];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    [picker dismissViewControllerAnimated:YES completion:^
     {
         NSError* error;
         NSData* data = [Utils getImageDataFromPickedImage:info error:&error];
   
         if(!data) {
             NSLog(@"Error: %@", error);
             [Alerts error:self title:@"There was an error reading the Key File" error:error completion:nil];
         }
         else {
             NSData* keyFileDigest = [KeyFileParser getKeyFileDigestFromFileData:data];
             [self changeKeyFile:keyFileDigest];
         }
     }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    //NSLog(@"didPickDocumentsAtURLs: %@", urls);

    NSURL* url = [urls objectAtIndex:0];
    // NSString *filename = [url.absoluteString lastPathComponent];

    NSError* error;
    NSData* data = [NSData dataWithContentsOfURL:url options:kNilOptions error:&error];

    if(!data) {
        NSLog(@"Error: %@", error);
        [Alerts error:self title:@"There was an error reading the Key File" error:error completion:nil];
    }
    else {
        NSData* keyFileDigest = [KeyFileParser getKeyFileDigestFromFileData:data];
        [self changeKeyFile:keyFileDigest];
    }
}

- (void)changeKeyFile:(NSData *)keyFileDigest {
    self.viewModel.database.keyFileDigest = keyFileDigest;
    
    [self.viewModel update:^(NSError *error) {
        if (error == nil) {
            if (self.viewModel.metadata.isTouchIdEnabled && self.viewModel.metadata.isEnrolledForConvenience) {
                self.viewModel.metadata.convenenienceKeyFileDigest = self.viewModel.database.keyFileDigest;
                NSLog(@"Keychain updated on Key File changed for touch id enabled and enrolled safe.");
            }
            
            [ISMessages             showCardAlertWithTitle:@"Key File Changed"
                                                   message:nil
                                                  duration:3.f
                                               hideOnSwipe:YES
                                                 hideOnTap:YES
                                                 alertType:ISAlertTypeSuccess
                                             alertPosition:ISAlertPositionTop
                                                   didHide:nil];
        }
        else {
            [Alerts             error:self
                                title:@"Key File NOT Changed!"
                                error:error];
        }
    }];
}

- (void)changeMasterPassword:(NSString *)password {
    self.viewModel.database.masterPassword = password;
    
    [self.viewModel update:^(NSError *error) {
        if (error == nil) {
            if (self.viewModel.metadata.isTouchIdEnabled && self.viewModel.metadata.isEnrolledForConvenience) {
                self.viewModel.metadata.convenienceMasterPassword = self.viewModel.database.masterPassword;
                NSLog(@"Keychain updated on Master password changed for touch id enabled and enrolled safe.");
            }
            
            [ISMessages             showCardAlertWithTitle:@"Master Password Changed"
                                                   message:nil
                                                  duration:3.f
                                               hideOnSwipe:YES
                                                 hideOnTap:YES
                                                 alertType:ISAlertTypeSuccess
                                             alertPosition:ISAlertPositionTop
                                                   didHide:nil];
        }
        else {
            [Alerts             error:self
                                title:@"Master Password NOT Changed!"
                                error:error];
        }
    }];
}

- (void)onChangeMasterPassword {
    Alerts *alerts = [[Alerts alloc] initWithTitle:@"Change Master Password"
                                           message:@"Enter the new password:"];
    
    [alerts OkCancelWithPasswordAndConfirm:self
                                allowEmpty:!(self.viewModel.database.format == kKeePass1 || self.viewModel.database.format == kPasswordSafe)
                                completion:^(NSString *password, BOOL response) {
                                    if (response) {
                                        [self changeMasterPassword:password];
                                    }
                                }];
}

- (void)updateTouchIdButtonText {
    NSString *biometricIdName = [[Settings sharedInstance] getBiometricIdName];
    self.labelToggleTouchId.text = [NSString stringWithFormat:@"%@ %@", self.viewModel.metadata.isTouchIdEnabled ? @"Disable" : @"Enable", biometricIdName];
}

- (void)updateOfflineCacheButtonText {
    self.labelToggleOfflineCache.text = self.viewModel.metadata.offlineCacheEnabled ? @"Disable Offline Cache" : @"Enable Offline Cache";

    NSDate *modDate = [[LocalDeviceStorageProvider sharedInstance] getOfflineCacheFileModificationDate:self.viewModel.metadata];
    self.labelOfflineCacheTime.text = self.viewModel.metadata.offlineCacheEnabled ? getLastCachedDate(modDate) : @"";
}

- (void)updateAutoFillCacheButtonText {
    self.labelToggleAutoFillCache.text = self.viewModel.metadata.autoFillCacheEnabled ? @"Disable Auto Fill Cache" : @"Enable Auto Fill Cache";

    NSDate* modDate = [[LocalDeviceStorageProvider sharedInstance] getAutoFillCacheModificationDate:self.viewModel.metadata];
    self.labelAutoFillCacheTime.text = self.viewModel.metadata.autoFillCacheEnabled ? getLastCachedDate(modDate) : @"";
}

- (void)onToggleTouchId {
    NSString* bIdName = [[Settings sharedInstance] getBiometricIdName];
    
    if (self.viewModel.metadata.isTouchIdEnabled) {
        NSString *message = self.viewModel.metadata.isEnrolledForConvenience && self.viewModel.metadata.conveniencePin == nil ?
            @"Disabling %@ for this database will remove the securely stored password and you will have to enter it again. Are you sure you want to do this?" :
            @"Are you sure you want to disable %@ for this database?";
        
        [Alerts yesNo:self
                title:[NSString stringWithFormat:@"Disable %@?", bIdName]
              message:[NSString stringWithFormat:message, bIdName]
               action:^(BOOL response) {
                   if (response) {
                       self.viewModel.metadata.isTouchIdEnabled = NO;

                       if(self.viewModel.metadata.conveniencePin == nil) {
                           self.viewModel.metadata.isEnrolledForConvenience = NO;
                           self.viewModel.metadata.convenienceMasterPassword = nil;
                           self.viewModel.metadata.convenenienceKeyFileDigest = nil;
                       }
                       
                       [[SafesList sharedInstance] update:self.viewModel.metadata];
                       [self updateTouchIdButtonText];
                       
                       [ISMessages showCardAlertWithTitle:[NSString stringWithFormat:@"%@ Disabled", bIdName]
                                                  message:[NSString stringWithFormat:@"%@ for this database has been disabled.", bIdName]
                                                 duration:3.f
                                              hideOnSwipe:YES
                                                hideOnTap:YES
                                                alertType:ISAlertTypeSuccess
                                            alertPosition:ISAlertPositionTop
                                                  didHide:nil];
                   }
               }];
    }
    else {
        self.viewModel.metadata.isTouchIdEnabled = YES;
        self.viewModel.metadata.isEnrolledForConvenience = YES;
        self.viewModel.metadata.convenienceMasterPassword = self.viewModel.database.masterPassword;
        self.viewModel.metadata.convenenienceKeyFileDigest = self.viewModel.database.keyFileDigest;

        [ISMessages showCardAlertWithTitle:[NSString stringWithFormat:@"%@ Enabled", bIdName]
                                   message:[NSString stringWithFormat:@"%@ has been enabled for this database.", bIdName]
                                  duration:3.f
                               hideOnSwipe:YES
                                 hideOnTap:YES
                                 alertType:ISAlertTypeSuccess
                             alertPosition:ISAlertPositionTop
                                   didHide:nil];
    }
    
    [self updateTouchIdButtonText];
    [[SafesList sharedInstance] update:self.viewModel.metadata];
}

- (void)onToggleOfflineCache {
    if (self.viewModel.metadata.offlineCacheEnabled) {
        [Alerts yesNo:self
                title:@"Disable Offline Cache?"
              message:@"Disabling Offline Cache for this database will remove the offline cache and you will not be able to access the database when offline. Are you sure you want to do this?"
               action:^(BOOL response) {
                   if (response) {
                       [self.viewModel disableAndClearOfflineCache];
                       [self updateOfflineCacheButtonText];
                       
                       [ISMessages showCardAlertWithTitle:@"Offline Cache Disabled"
                                                  message:nil
                                                 duration:3.f
                                              hideOnSwipe:YES
                                                hideOnTap:YES
                                                alertType:ISAlertTypeSuccess
                                            alertPosition:ISAlertPositionTop
                                                  didHide:nil];
                   }
               }];
    }
    else {
        [self.viewModel enableOfflineCache];
        [self.viewModel updateOfflineCache:^{
            [self updateOfflineCacheButtonText];
            
            [ISMessages                 showCardAlertWithTitle:@"Offline Cache Enabled"
                                                       message:nil
                                                      duration:3.f
                                                   hideOnSwipe:YES
                                                     hideOnTap:YES
                                                     alertType:ISAlertTypeSuccess
                                                 alertPosition:ISAlertPositionTop
                                                       didHide:nil];
        }];
    }
}

- (void)onToggleAutoFillCache {
    if (self.viewModel.metadata.autoFillCacheEnabled) {
        [Alerts yesNo:self
                title:@"Disable Autofill Cache?"
              message:@"Disabling the Autofill Cache will remove the autofill cache and you will not be able to access the database for use during autofill. Are you sure you want to do this?"
               action:^(BOOL response) {
                   if (response) {
                       [self.viewModel disableAndClearAutoFillCache];
                       [self updateAutoFillCacheButtonText];

                       [ISMessages showCardAlertWithTitle:@"Autofill Cache Disabled"
                                                  message:nil
                                                 duration:3.f
                                              hideOnSwipe:YES
                                                hideOnTap:YES
                                                alertType:ISAlertTypeSuccess
                                            alertPosition:ISAlertPositionTop
                                                  didHide:nil];
                   }
               }];
    }
    else {
        [self.viewModel enableAutoFillCache];
        [self.viewModel updateAutoFillCache:^{
            [self updateAutoFillCacheButtonText];
            
            [ISMessages                 showCardAlertWithTitle:@"Autofill Cache Enabled"
                                                       message:nil
                                                      duration:3.f
                                                   hideOnSwipe:YES
                                                     hideOnTap:YES
                                                     alertType:ISAlertTypeSuccess
                                                 alertPosition:ISAlertPositionTop
                                                       didHide:nil];
        }];
    }
}

- (void)onExport {
    [Alerts threeOptionsWithCancel:self title:@"How would you like to export your database?"
                           message:@"You can export your encrypted database by email, or you can copy your database in plaintext format (CSV) to the clipboard."
                 defaultButtonText:@"Export (Encrypted) by Email"
                  secondButtonText:@"Export as CSV by Email"
                   thirdButtonText:@"Copy CSV to Clipboard"
                            action:^(int response) {
        if(response == 0) {
            [self exportEncryptedSafeByEmail];
        }
        else if(response == 1){
            NSData *newStr = [Csv getSafeAsCsv:self.viewModel.database.rootGroup];

            NSString* attachmentName = [NSString stringWithFormat:@"%@.csv", self.viewModel.metadata.nickName];
            [self composeEmail:attachmentName mimeType:@"text/csv" data:newStr];
        }
        else if(response == 2){
            NSString *newStr = [[NSString alloc] initWithData:[Csv getSafeAsCsv:self.viewModel.database.rootGroup] encoding:NSUTF8StringEncoding];

            UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
            pasteboard.string = newStr;
            
            [ISMessages showCardAlertWithTitle:@"Database Copied to Clipboard"
                                       message:nil
                                      duration:3.f
                                   hideOnSwipe:YES
                                     hideOnTap:YES
                                     alertType:ISAlertTypeSuccess
                                 alertPosition:ISAlertPositionTop
                                       didHide:nil];
        }
    }];
}

- (void)exportEncryptedSafeByEmail {
    [self.viewModel encrypt:^(NSData * _Nullable safeData, NSError * _Nullable error) {
        if(!safeData) {
            [Alerts error:self title:@"Could not get database data" error:error];
            return;
        }
      
        NSString *attachmentName = [NSString stringWithFormat:@"%@%@", self.viewModel.metadata.fileName,
                                    ([self.viewModel.metadata.fileName hasSuffix:@".dat"] || [self.viewModel.metadata.fileName hasSuffix:@"psafe3"]) ? @"" : @".dat"];
        
        [self composeEmail:attachmentName mimeType:@"application/octet-stream" data:safeData];
    }];
}

- (void)composeEmail:(NSString*)attachmentName mimeType:(NSString*)mimeType data:(NSData*)data {
    if(![MFMailComposeViewController canSendMail]) {
        [Alerts info:self
               title:@"Email Not Available"
             message:@"It looks like email is not setup on this device and so the database cannot be exported by email."];
        
        return;
    }
    
    MFMailComposeViewController *picker = [[MFMailComposeViewController alloc] init];
    
    [picker setSubject:[NSString stringWithFormat:@"Strongbox Database: '%@'", self.viewModel.metadata.nickName]];
    
    [picker addAttachmentData:data mimeType:mimeType fileName:attachmentName];
    
    [picker setToRecipients:[NSArray array]];
    [picker setMessageBody:[NSString stringWithFormat:@"Here's a copy of my '%@' Strongbox Database.", self.viewModel.metadata.nickName] isHTML:NO];
    picker.mailComposeDelegate = self;
    
    [self presentViewController:picker animated:YES completion:^{ }];
}

- (void)mailComposeController:(MFMailComposeViewController *)controller
          didFinishWithResult:(MFMailComposeResult)result
                        error:(NSError *)error {
    [self dismissViewControllerAnimated:YES completion:^{ }];
}

- (void)bindReadOnly {
    self.switchReadOnly.on = self.viewModel.metadata.readOnly;
}

- (IBAction)onReadOnly:(id)sender {
    self.viewModel.metadata.readOnly = self.switchReadOnly.on;
    
    [[SafesList sharedInstance] update:self.viewModel.metadata];

    [self bindReadOnly];
    
    [Alerts info:self title:@"Re-Open Required" message:@"Please re open this database for this read only change to take effect."];
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if([segue.identifier isEqualToString:@"segueToPinsConfiguration"]) {
        PinsConfigurationController* vc = (PinsConfigurationController*)segue.destinationViewController;
        vc.viewModel = self.viewModel;
    }
}

@end

