#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block, catching any Objective-C exception (which Swift cannot
/// catch) and returning it instead of letting it terminate the process.
/// Returns nil when the block completes normally.
NSException *_Nullable VKCatchObjCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
