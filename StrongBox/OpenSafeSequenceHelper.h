//
//  OpenSafeSequenceHelper.h
//  Strongbox-iOS
//
//  Created by Mark on 12/10/2018.
//  Copyright © 2018 Mark McGuill. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "SafeMetaData.h"
#import "Model.h"

NS_ASSUME_NONNULL_BEGIN

@interface OpenSafeSequenceHelper : NSObject

- (instancetype)init NS_UNAVAILABLE;

+ (void)beginSequenceWithViewController:(UIViewController*)viewController
                                   safe:(SafeMetaData*)safe
      canConvenienceEnrol:(BOOL)canBiometricEnrol
                             completion:(void (^)(Model* model))completion;

+ (void)beginSequenceWithViewController:(UIViewController*)viewController
                                   safe:(SafeMetaData*)safe
                      openAutoFillCache:(BOOL)openAutoFillCache
      canConvenienceEnrol:(BOOL)canBiometricEnrol
                             completion:(void (^)(Model* model))completion;

+ (NSData*)findAssociatedLocalKeyFile:(NSString*)filename;
+ (NSString*)getExpectedAssociatedLocalKeyFileName:(NSString*)filename;

@end

NS_ASSUME_NONNULL_END
