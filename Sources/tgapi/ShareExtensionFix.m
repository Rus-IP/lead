// Share extension memory fixes. iOS gives the extension 120 MB. Preparing a photo
// for sending briefly takes 50–75 MB more, because Swiftgram decodes the whole
// frame before scaling it down. iOS also reuses the extension process for the next
// share, and that process still holds 60–70 MB from the previous one, so every
// second share went over the limit and was killed without a word.
//
// 1. Once the share is complete, the process exits, so the next share starts fresh.
// 2. The photo is decoded at a reduced size (ImageIO subsampling) instead of in
//    full. The result has the same size and JPEG quality as before; any failure
//    falls back to Swiftgram's own code.

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

extern void LeadShareMemLog(NSString *event);

// MtProtoKit's signal classes, reached at runtime: Lead doesn't link MtProtoKit.
@protocol LeadMTSignal <NSObject>
- (id)initWithGenerator:(id (^)(id subscriber))generator;
- (id)startWithNext:(void (^)(id next))next error:(void (^)(id error))error completed:(void (^)(void))completed;
@end

@protocol LeadMTSubscriber <NSObject>
- (void)putNext:(id)next;
- (void)putError:(id)error;
- (void)putCompletion;
@end

static NSString *const kLeadImageType = @"public.image";

#pragma mark - Exit once the share is done

static void LeadScheduleExit(NSString *why) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    LeadShareMemLog([NSString stringWithFormat:@"exit-scheduled (%@)", why]);
    // Long enough for the host to finish its side; far too short for a new share.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      LeadShareMemLog(@"exit");
      exit(0);
    });
  });
}

static void (*sOrigComplete)(id, SEL, NSArray *, void (^)(BOOL));
static void LeadComplete(id self, SEL _cmd, NSArray *items, void (^handler)(BOOL)) {
  sOrigComplete(self, _cmd, items, ^(BOOL expired) {
    if (handler) handler(expired);
    LeadScheduleExit(@"completed");
  });
  // In case the host never calls back.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    LeadScheduleExit(@"completed, no callback");
  });
}

static void (*sOrigCancel)(id, SEL, NSError *);
static void LeadCancel(id self, SEL _cmd, NSError *error) {
  sOrigCancel(self, _cmd, error);
  LeadScheduleExit(@"cancelled");
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

  LeadShareMemLog([NSString stringWithFormat:@"photo-decode %.0fx%.0f factor=%d max=%.0f", width, height, factor, maxDimension]);
  CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
  CFRelease(source);
  if (!image) return nil;
  LeadShareMemLog([NSString stringWithFormat:@"photo-decoded %zux%zu", CGImageGetWidth(image), CGImageGetHeight(image)]);

  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"img%u", arc4random()]];
  CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                                                      CFSTR("public.jpeg"), 1, NULL);
  if (!destination) {
    CGImageRelease(image);
    return nil;
  }
  NSDictionary *properties = @{(id)kCGImageDestinationLossyCompressionQuality : @(quality)};
  CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)properties);
  CGImageDestinationAddImage(destination, image, NULL);
  BOOL written = CGImageDestinationFinalize(destination);
  CFRelease(destination);
  CGSize size = CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image));
  CGImageRelease(image);
  if (!written) return nil;

  NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
  if (!data) return nil;
  LeadShareMemLog(@"photo-ready");
  return @{@"scaledImageData" : data, @"scaledImageDimensions" : [NSValue valueWithCGSize:size]};
}

static id LeadPhotoSignal(id self, SEL _cmd, NSItemProvider *provider, CGFloat maxDimension, CGFloat quality) {
  Class signalClass = NSClassFromString(@"MTSignal");
  if (!signalClass || ![provider hasItemConformingToTypeIdentifier:kLeadImageType]) {
    return sOrigPhotoSignal(self, _cmd, provider, maxDimension, quality);
  }
  id original = sOrigPhotoSignal(self, _cmd, provider, maxDimension, quality);
  return [(id<LeadMTSignal>)[signalClass alloc] initWithGenerator:^id(id subscriberObject) {
    id<LeadMTSubscriber> subscriber = subscriberObject;
    void (^fallBack)(NSString *) = ^(NSString *why) {
      LeadShareMemLog([NSString stringWithFormat:@"photo-fallback (%@)", why]);
      [(id<LeadMTSignal>)original startWithNext:^(id next) { [subscriber putNext:next]; }
                                          error:^(id error) { [subscriber putError:error]; }
                                      completed:^{ [subscriber putCompletion]; }];
    };
    [provider loadFileRepresentationForTypeIdentifier:kLeadImageType completionHandler:^(NSURL *url, NSError *error) {
      // The file only lives until this handler returns, so everything happens here.
      NSDictionary *result = nil;
      if (url) {
        @autoreleasepool {
          result = LeadScaledPhoto(url, maxDimension, quality);
        }
      }
      if (result) {
        [subscriber putNext:result];
        [subscriber putCompletion];
      } else {
        fallBack(url ? @"imageio" : (error.localizedDescription ?: @"no file"));
      }
    }];
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

  Class context = [NSExtensionContext class];
  LeadSwapInstance(context, @selector(completeRequestReturningItems:completionHandler:), (IMP)LeadComplete, (IMP *)&sOrigComplete);
  LeadSwapInstance(context, @selector(cancelRequestWithError:), (IMP)LeadCancel, (IMP *)&sOrigCancel);

  LeadInstallPhotoHook();
  // In case the class's framework registers after Lead's constructor.
  dispatch_async(dispatch_get_main_queue(), ^{
    LeadInstallPhotoHook();
  });
}
