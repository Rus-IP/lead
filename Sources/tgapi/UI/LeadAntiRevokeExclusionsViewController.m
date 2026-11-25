#import "LeadMenu.h"
#import "Headers.h"

NSArray<NSDictionary *> *LeadMessageLogEntries(void);

NSString *LeadTitleForLogEntry(NSDictionary *entry) {
  NSString *name = entry[@"name"];
  if ([name isKindOfClass:[NSString class]] && name.length) return name;
  NSString *username = entry[@"username"];
  if ([username isKindOfClass:[NSString class]] && username.length) return [@"@" stringByAppendingString:username];
  NSString *peer = entry[@"peer"];
  return [peer isKindOfClass:[NSString class]] && peer.length > 1 ? [NSString stringWithFormat:@"ID %@", [peer substringFromIndex:1]] : @"Telegram";
}

NSArray<NSString *> *LeadAntiRevokeExcludedIds(void) {
  NSArray *list = [[NSUserDefaults standardUserDefaults] arrayForKey:kAntiRevokeExcludedChannels];
  return [list isKindOfClass:[NSArray class]] ? list : @[];
}

BOOL LeadIsAntiRevokeExcluded(NSString *channelId) {
  return [LeadAntiRevokeExcludedIds() containsObject:channelId];
}

void LeadSetAntiRevokeExcluded(NSString *channelId, BOOL excluded, NSString *name) {
  if (!channelId.length) return;
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSMutableArray *list = [LeadAntiRevokeExcludedIds() mutableCopy];
  NSMutableDictionary *names = [[defaults dictionaryForKey:kAntiRevokeExcludedNames] mutableCopy] ?: [NSMutableDictionary dictionary];
  [list removeObject:channelId];
  [names removeObjectForKey:channelId];
  if (excluded) {
    [list addObject:channelId];
    if (name.length) names[channelId] = name;
  }
  [defaults setObject:list forKey:kAntiRevokeExcludedChannels];
  [defaults setObject:names forKey:kAntiRevokeExcludedNames];
}

// Section 0: excluded chats (swipe or tap to remove).
// Section 1: channels/supergroups seen in the deleted-messages log (tap to exclude).
@interface LeadAntiRevokeExclusionsViewController ()
@property (nonatomic, strong) NSArray<NSString *> *excluded;
@property (nonatomic, strong) NSArray<NSDictionary *> *candidates; // @{id, name}
@end

@implementation LeadAntiRevokeExclusionsViewController

- (instancetype)init {
  return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = LeadL(@"UI_EXCLUSIONS_TITLE");
  self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
  [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"Cell"];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload) name:@"LeadMessageLogChanged" object:nil];
  [self reload];
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reload {
  self.excluded = LeadAntiRevokeExcludedIds();
  NSMutableArray *candidates = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet setWithArray:self.excluded];
  for (NSDictionary *entry in LeadMessageLogEntries()) {
    if (![entry isKindOfClass:[NSDictionary class]] || ![entry[@"kind"] isEqualToString:@"deleted"]) continue;
    NSString *peer = entry[@"peer"];
    if (![peer isKindOfClass:[NSString class]] || ![peer hasPrefix:@"c"] || peer.length < 2) continue;
    NSString *channelId = [peer substringFromIndex:1];
    if ([seen containsObject:channelId]) continue;
    [seen addObject:channelId];
    [candidates addObject:@{ @"id" : channelId, @"name" : LeadTitleForLogEntry(entry) }];
  }
  self.candidates = candidates;
  [self.tableView reloadData];
}

- (NSString *)nameForExcluded:(NSString *)channelId {
  NSString *name = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kAntiRevokeExcludedNames][channelId];
  return [name isKindOfClass:[NSString class]] && name.length ? name : [@"ID " stringByAppendingString:channelId];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  NSUInteger count = section == 0 ? self.excluded.count : self.candidates.count;
  return MAX(1, (NSInteger)count); // one placeholder row when empty
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  return LeadL(section == 0 ? @"UI_EXCLUSIONS_CURRENT" : @"UI_EXCLUSIONS_ADD");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  return section == 1 ? LeadL(@"UI_EXCLUSIONS_FOOTER") : nil;
}

- (BOOL)isPlaceholder:(NSIndexPath *)indexPath {
  return (indexPath.section == 0 ? self.excluded.count : self.candidates.count) == 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
  UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
  if ([self isPlaceholder:indexPath]) {
    content.text = LeadL(indexPath.section == 0 ? @"UI_EXCLUSIONS_EMPTY" : @"UI_EXCLUSIONS_NO_CANDIDATES");
    content.textProperties.color = UIColor.secondaryLabelColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  } else if (indexPath.section == 0) {
    content.text = [self nameForExcluded:self.excluded[indexPath.row]];
    content.image = [UIImage systemImageNamed:@"trash"];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
  } else {
    content.text = self.candidates[indexPath.row][@"name"];
    content.image = [UIImage systemImageNamed:@"plus.circle"];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
  }
  cell.contentConfiguration = content;
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if ([self isPlaceholder:indexPath]) return;
  if (indexPath.section == 0) {
    [self removeAt:indexPath.row];
  } else {
    NSDictionary *candidate = self.candidates[indexPath.row];
    LeadSetAntiRevokeExcluded(candidate[@"id"], YES, candidate[@"name"]);
    [LeadToast showText:LeadL(@"UI_LOG_EXCLUDED") symbol:@"checkmark" inView:self.view];
    [self reload];
  }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.section != 0 || [self isPlaceholder:indexPath]) return nil;
  __weak typeof(self) weakSelf = self;
  UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                       title:LeadL(@"UI_EXCLUSIONS_REMOVE")
                                                                     handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^done)(BOOL)) {
    [weakSelf removeAt:indexPath.row];
    done(YES);
  }];
  return [UISwipeActionsConfiguration configurationWithActions:@[ remove ]];
}

- (void)removeAt:(NSInteger)row {
  if (row < 0 || row >= (NSInteger)self.excluded.count) return;
  LeadSetAntiRevokeExcluded(self.excluded[row], NO, nil);
  [LeadToast showText:LeadL(@"UI_LOG_INCLUDED") symbol:@"checkmark" inView:self.view];
  [self reload];
}

@end
