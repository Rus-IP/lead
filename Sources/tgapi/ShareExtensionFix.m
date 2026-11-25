// Share extension memory fixes. iOS gives the extension 120 MB. Preparing a photo
// for sending briefly takes 50–75 MB more, because Swiftgram decodes the whole
// frame before scaling it down. iOS also reuses the extension process for the next
// share, and that process still holds 60–70 MB from the previous one, so every
// second share went over the limit and was killed without a word.
//
// 1. Once the share is complete or cancelled, the process exits cleanly before iOS
//    suspends it, so the next share starts fresh — while cancelling any pending exit
//    if a new share starts or if the process was suspended before exiting.
// 2. The photo is decoded at a reduced size (ImageIO subsampling) instead of in
//    full. The result has the same size and JPEG quality as before; temp files are
//    unlinked immediately, cancellation propagates, and any failure falls back to
//    Swiftgram's own code.

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/lock.h>

// MtProtoKit's signal classes, reached at runtime: Lead doesn't link MtProtoKit.
@protocol LeadMTDisposable <NSObject>
- (void)dispose;
@end

@protocol LeadMTBlockDisposable <LeadMTDisposable>
- (instancetype)initWithBlock:(void (^)(void))block;
@end

@protocol LeadMTSignal <NSObject>
- (id)initWithGenerator:(id (^)(id subscriber))generator;
- (id)startWithNext:(void (^)(id next))next error:(void (^)(id error))error completed:(void (^)(void))completed;
@end

@protocol LeadMTSubscriber <NSObject>
- (void)putNext:(id)next;
- (void)putError:(id)error;
- (void)putCompletion;
@end

// Heap-allocated cancellation state for one photo signal (keeps os_unfair_lock at a
// fixed address rather than inside a __block variable that moves when copied).
@interface LeadPhotoCancelState : NSObject
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, strong) NSProgress *progress;
@property (nonatomic, strong) id fallbackDisposable;
- (void)withLock:(void (^)(LeadPhotoCancelState *state))block;
@end

@implementation LeadPhotoCancelState {
  os_unfair_lock _lock;
}

- (instancetype)init {
  self = [super init];
  if (self) _lock = OS_UNFAIR_LOCK_INIT;
  return self;
}

- (void)withLock:(void (^)(LeadPhotoCancelState *state))block {
  os_unfair_lock_lock(&_lock);
  block(self);
  os_unfair_lock_unlock(&_lock);
}

@end

static NSString *const kLeadImageType = @"public.image";

#pragma mark - Exit once the share is done

static os_unfair_lock sExitLock = OS_UNFAIR_LOCK_INIT;
static uint64_t sShareGeneration = 0;
static BOOL sShareActive = YES;
static BOOL sExitPending = NO;
static BOOL sCompletionDelivered = NO;
static dispatch_block_t sExitBlock = nil;

static void LeadMarkShareActive(void) {
  os_unfair_lock_lock(&sExitLock);
  sShareActive = YES;
  sCompletionDelivered = NO;
  sExitPending = NO;
  sShareGeneration++;
  dispatch_block_t pending = sExitBlock;
  sExitBlock = nil;
  os_unfair_lock_unlock(&sExitLock);
  if (pending) dispatch_block_cancel(pending);
}

static uint64_t LeadBeginFinish(BOOL delivered) {
  os_unfair_lock_lock(&sExitLock);
  sShareActive = NO;
  sCompletionDelivered = delivered;
  sShareGeneration++;
  uint64_t gen = sShareGeneration;
  os_unfair_lock_unlock(&sExitLock);
  return gen;
}

// Schedules exit(0) for `generation` after `delay`. If iOS suspends the extension
// before the block runs and resumes the same process later for another share, either
// the foreground notification cancels it or the elapsed-uptime guard skips exiting.
static void LeadScheduleExit(uint64_t generation, BOOL markDelivered, NSTimeInterval delay, NSTimeInterval maxElapsed) {
  os_unfair_lock_lock(&sExitLock);
  if (sShareActive || generation != sShareGeneration) {
    os_unfair_lock_unlock(&sExitLock);
    return;
  }
  if (!markDelivered && sCompletionDelivered) {
    // Already rescheduled with the shorter post-callback delay.
    os_unfair_lock_unlock(&sExitLock);
    return;
  }
  if (markDelivered) sCompletionDelivered = YES;
  dispatch_block_t previous = sExitBlock;
  sExitPending = YES;
  NSTimeInterval scheduledAt = [NSProcessInfo processInfo].systemUptime;
  dispatch_block_t block = dispatch_block_create(0, ^{
    os_unfair_lock_lock(&sExitLock);
    BOOL shouldExit = sExitPending && !sShareActive && generation == sShareGeneration;
    if (shouldExit) {
      NSTimeInterval elapsed = [NSProcessInfo processInfo].systemUptime - scheduledAt;
      if (elapsed > maxElapsed) {
        shouldExit = NO;
        sExitPending = NO;
        sExitBlock = nil;
      }
    }
    os_unfair_lock_unlock(&sExitLock);
    if (shouldExit) exit(0);
  });
  sExitBlock = block;
  os_unfair_lock_unlock(&sExitLock);

  if (previous) dispatch_block_cancel(previous);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

static void (*sOrigComplete)(id, SEL, NSArray *, void (^)(BOOL));
static void LeadComplete(id self, SEL _cmd, NSArray *items, void (^handler)(BOOL)) {
  uint64_t gen = LeadBeginFinish(NO);
  sOrigComplete(self, _cmd, items, ^(BOOL expired) {
    if (handler) handler(expired);
    LeadScheduleExit(gen, YES, 0.2, 2.0);
  });
  // Fallback in case the host never invokes the completion callback.
  LeadScheduleExit(gen, NO, 2.5, 4.0);
}

static void (*sOrigCancel)(id, SEL, NSError *);
static void LeadCancel(id self, SEL _cmd, NSError *error) {
  uint64_t gen = LeadBeginFinish(YES);
  sOrigCancel(self, _cmd, error);
  LeadScheduleExit(gen, YES, 0.2, 2.0);
}

#pragma mark - Photo preparation

typedef id (*LeadPhotoSignalIMP)(id, SEL, NSItemProvider *, CGFloat, CGFloat);
static LeadPhotoSignalIMP sOrigPhotoSignal;

// Same output as Swiftgram's URL path: a JPEG no larger than maxDimension on its long
// side. Returns nil when ImageIO can't do it, so the caller falls back.
static NSDictionary *LeadScaledPhoto(NSURL *url, CGFloat maxDimension, CGFloat quality) {
  NSDictionary *sourceOptions = @{(id)kCGImageSourceShouldCache : @NO};
  CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, (__bridge CFDictionaryRef)sourceOptions);
  if (!source) return nil;

  NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
  double width = [props[(id)kCGImagePropertyPixelWidth] doubleValue];
  double height = [props[(id)kCGImagePropertyPixelHeight] doubleValue];
  double longSide = MAX(width, height);

  // The largest power of two that still leaves the decoded frame at least as big as
  // the result, so nothing is lost before the final scaling.
  int factor = 1;
  while (factor < 8 && longSide > 0 && longSide / (factor * 2) >= maxDimension) factor *= 2;

  NSMutableDictionary *options = [@{
    (id)kCGImageSourceCreateThumbnailWithTransform : @YES,
    (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
    (id)kCGImageSourceThumbnailMaxPixelSize : @(maxDimension),
    (id)kCGImageSourceShouldCacheImmediately : @YES,
  } mutableCopy];
  if (factor > 1) options[(id)kCGImageSourceSubsampleFactor] = @(factor);

  CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
  CFRelease(source);
  if (!image) return nil;

  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"lead-share-%@.jpg", [NSUUID UUID].UUIDString]];
  CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                                                      CFSTR("public.jpeg"), 1, NULL);
  if (!destination) {
    CGImageRelease(image);
    return nil;
  }
  NSDictionary *imageProperties = (quality > 0.0 && quality <= 1.0)
                                      ? @{(id)kCGImageDestinationLossyCompressionQuality : @(quality)}
                                      : nil;
  CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)imageProperties);
  BOOL written = CGImageDestinationFinalize(destination);
  CFRelease(destination);
  CGSize size = CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image));
  CGImageRelease(image);
  if (!written) {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    return nil;
  }

  // Mapped read keeps the JPEG out of dirty RAM; unlinking right after avoids leaking
  // files in tmp while the open mmap stays valid until NSData is released.
  NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  if (!data) return nil;
  return @{@"scaledImageData" : data, @"scaledImageDimensions" : [NSValue valueWithCGSize:size]};
}

static id LeadPhotoSignal(id self, SEL _cmd, NSItemProvider *provider, CGFloat maxDimension, CGFloat quality) {
  Class signalClass = NSClassFromString(@"MTSignal");
  if (!signalClass || ![provider hasItemConformingToTypeIdentifier:kLeadImageType]) {
    return sOrigPhotoSignal(self, _cmd, provider, maxDimension, quality);
  }
  return [(id<LeadMTSignal>)[signalClass alloc] initWithGenerator:^id(id subscriberObject) {
    id<LeadMTSubscriber> subscriber = subscriberObject;
    LeadPhotoCancelState *cancelState = [LeadPhotoCancelState new];

    void (^fallBack)(void) = ^{
      __block BOOL isCancelled = NO;
      [cancelState withLock:^(LeadPhotoCancelState *s) { isCancelled = s.cancelled; }];
      if (isCancelled) return;

      id original = sOrigPhotoSignal(self, _cmd, provider, maxDimension, quality);
      id disposable = [(id<LeadMTSignal>)original startWithNext:^(id next) { [subscriber putNext:next]; }
                                                          error:^(id error) { [subscriber putError:error]; }
                                                      completed:^{ [subscriber putCompletion]; }];
      __block BOOL disposeNow = NO;
      [cancelState withLock:^(LeadPhotoCancelState *s) {
        if (s.cancelled) {
          disposeNow = YES;
        } else {
          s.fallbackDisposable = disposable;
        }
      }];
      if (disposeNow && [disposable respondsToSelector:@selector(dispose)]) {
        [(id<LeadMTDisposable>)disposable dispose];
      }
    };

    NSProgress *progress = [provider loadFileRepresentationForTypeIdentifier:kLeadImageType completionHandler:^(NSURL *url, NSError *error) {
      __block BOOL isCancelled = NO;
      [cancelState withLock:^(LeadPhotoCancelState *s) { isCancelled = s.cancelled; }];
      if (isCancelled) return;

      // The file only lives until this handler returns, so everything happens here.
      NSDictionary *result = nil;
      if (url) {
        @autoreleasepool {
          result = LeadScaledPhoto(url, maxDimension, quality);
        }
      }
      [cancelState withLock:^(LeadPhotoCancelState *s) { isCancelled = s.cancelled; }];
      if (isCancelled) return;

      if (result) {
        [subscriber putNext:result];
        [subscriber putCompletion];
      } else {
        fallBack();
      }
    }];

    [cancelState withLock:^(LeadPhotoCancelState *s) {
      if (s.cancelled) {
        [progress cancel];
      } else {
        s.progress = progress;
      }
    }];

    Class blockDisposableClass = NSClassFromString(@"MTBlockDisposable");
    if (blockDisposableClass && [blockDisposableClass instancesRespondToSelector:@selector(initWithBlock:)]) {
      return [(id<LeadMTBlockDisposable>)[blockDisposableClass alloc] initWithBlock:^{
        __block NSProgress *p = nil;
        __block id d = nil;
        [cancelState withLock:^(LeadPhotoCancelState *s) {
          s.cancelled = YES;
          p = s.progress;
          d = s.fallbackDisposable;
          s.progress = nil;
          s.fallbackDisposable = nil;
        }];
        [p cancel];
        if ([d respondsToSelector:@selector(dispose)]) [(id<LeadMTDisposable>)d dispose];
      }];
    }
    return nil;
  }];
}

#pragma mark -

static BOOL LeadSwapInstance(Class cls, SEL sel, IMP replacement, IMP *original) {
  Method method = class_getInstanceMethod(cls, sel);
  if (!method) return NO;
  *original = method_setImplementation(method, replacement);
  return YES;
}

static void LeadInstallPhotoHook(void) {
  static BOOL done = NO;
  if (done) return;
  Class cls = NSClassFromString(@"TGItemProviderSignals");
  SEL sel = NSSelectorFromString(@"sgSignalForImageItemProvider:imageMaxDimension:imageQuality:");
  Method method = cls ? class_getClassMethod(cls, sel) : NULL;
  if (!method) return;
  // Only a signature we know: (NSItemProvider *, CGFloat, CGFloat) -> MTSignal *.
  char ret[8] = {0}, a2[8] = {0}, a3[8] = {0}, a4[8] = {0};
  method_getReturnType(method, ret, sizeof(ret));
  method_getArgumentType(method, 2, a2, sizeof(a2));
  method_getArgumentType(method, 3, a3, sizeof(a3));
  method_getArgumentType(method, 4, a4, sizeof(a4));
  if (method_getNumberOfArguments(method) != 5 || ret[0] != '@' || a2[0] != '@' || a3[0] != 'd' || a4[0] != 'd') {
    NSLog(@"[Lead] Share photo hook skipped: unexpected signature %s", method_getTypeEncoding(method) ?: "?");
    return;
  }
  sOrigPhotoSignal = (LeadPhotoSignalIMP)method_setImplementation(method, (IMP)LeadPhotoSignal);
  done = YES;
  NSLog(@"[Lead] Share photo hook installed");
}

__attribute__((constructor))
static void LeadShareExtensionFixInit(void) {
  NSString *point = [NSBundle mainBundle].infoDictionary[@"NSExtension"][@"NSExtensionPointIdentifier"] ?: @"";
  if (![point isEqualToString:@"com.apple.share-services"]) return;

  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  for (NSNotificationName name in @[ NSExtensionHostWillEnterForegroundNotification, NSExtensionHostDidBecomeActiveNotification ]) {
    [center addObserverForName:name object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
      LeadMarkShareActive();
    }];
  }
  [center addObserverForName:NSExtensionHostDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
    os_unfair_lock_lock(&sExitLock);
    BOOL shouldExit = sExitPending && !sShareActive && sCompletionDelivered;
    os_unfair_lock_unlock(&sExitLock);
    if (shouldExit) exit(0);
  }];

  Class context = [NSExtensionContext class];
  LeadSwapInstance(context, @selector(completeRequestReturningItems:completionHandler:), (IMP)LeadComplete, (IMP *)&sOrigComplete);
  LeadSwapInstance(context, @selector(cancelRequestWithError:), (IMP)LeadCancel, (IMP *)&sOrigCancel);

  LeadInstallPhotoHook();
  // In case the class's framework registers after Lead's constructor.
  dispatch_async(dispatch_get_main_queue(), ^{
    LeadInstallPhotoHook();
  });
}
