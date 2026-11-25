// Diagnostics for the share extension: iOS kills it, without a saved report, when a
// caption is typed and the photo is sent. This logs how much memory the extension
// uses and how much it has left, so a device syslog shows what pushes it over.
// Output lines start with "[LeadMem]".

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <os/proc.h>

static double LeadMemFootprintMB(void) {
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
  return info.phys_footprint / 1048576.0;
}

static double LeadMemAvailableMB(void) {
  if (@available(iOS 13.0, *)) return os_proc_available_memory() / 1048576.0;
  return -1;
}

static double sLeadMemPeak = 0;

static void LeadMemLog(NSString *event) {
  double used = LeadMemFootprintMB();
  if (used > sLeadMemPeak) sLeadMemPeak = used;
  NSLog(@"[LeadMem] %@ used=%.1fMB left=%.1fMB peak=%.1fMB", event, used, LeadMemAvailableMB(), sLeadMemPeak);
}

__attribute__((constructor))
static void LeadShareMemoryDiagInit(void) {
  NSBundle *bundle = [NSBundle mainBundle];
  NSString *point = bundle.infoDictionary[@"NSExtension"][@"NSExtensionPointIdentifier"] ?: @"";
  if (![point isEqualToString:@"com.apple.share-services"]) return;

  LeadMemLog(@"start");

  // Every 100 ms; between samples only a change of 1 MB or more is logged, plus a
  // heartbeat each second, so the log stays readable.
  static dispatch_source_t timer;
  static double last = 0;
  static int ticks = 0;
  timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 100 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
  dispatch_source_set_event_handler(timer, ^{
    double used = LeadMemFootprintMB();
    ticks++;
    if (fabs(used - last) >= 1.0 || ticks % 10 == 0) {
      last = used;
      LeadMemLog(@"tick");
    }
  });
  dispatch_resume(timer);

  NSDictionary<NSString *, NSString *> *events = @{
    UIKeyboardWillShowNotification : @"keyboard-will-show",
    UIKeyboardDidShowNotification : @"keyboard-did-show",
    UIKeyboardWillHideNotification : @"keyboard-will-hide",
    UIKeyboardDidHideNotification : @"keyboard-did-hide",
    UIApplicationDidReceiveMemoryWarningNotification : @"MEMORY-WARNING",
    NSExtensionHostWillResignActiveNotification : @"host-will-resign",
    NSExtensionHostDidEnterBackgroundNotification : @"host-background",
  };
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  for (NSString *name in events) {
    NSString *label = events[name];
    [center addObserverForName:name object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
      LeadMemLog(label);
    }];
  }

  // Memory pressure as the kernel reports it, which can come before UIKit's warning.
  static dispatch_source_t pressure;
  pressure = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
                                    DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
                                    dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
  dispatch_source_set_event_handler(pressure, ^{
    unsigned long level = dispatch_source_get_data(pressure);
    LeadMemLog(level & DISPATCH_MEMORYPRESSURE_CRITICAL ? @"PRESSURE-CRITICAL" : @"PRESSURE-WARN");
  });
  dispatch_resume(pressure);
}
