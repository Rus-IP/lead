#import "LeadMenu.h"
#import "Headers.h"
#import <objc/message.h>

NSArray<NSDictionary *> *LeadMessageLogEntries(void);

static id LeadParserCall(NSString *selectorName, id argument) {
  Class parser = NSClassFromString(@"TLParser");
  SEL selector = NSSelectorFromString(selectorName);
  if (![parser respondsToSelector:selector]) return nil;
  if (argument) return ((id (*)(id, SEL, id))objc_msgSend)(parser, selector, argument);
  return ((id (*)(id, SEL))objc_msgSend)(parser, selector);
}

// "name" or "@username" of a chat as Lead knows it now; nil when it doesn't.
static NSString *LeadCurrentPeerTitle(NSString *peer) {
  if (![peer isKindOfClass:[NSString class]] || peer.length < 2) return nil;
  NSDictionary *info = LeadParserCall(@"peerInfoForTag:", peer);
  if (![info isKindOfClass:[NSDictionary class]]) return nil;
  NSString *name = info[@"name"];
  if ([name isKindOfClass:[NSString class]] && name.length) return name;
  NSString *username = info[@"username"];
  if ([username isKindOfClass:[NSString class]] && username.length) return [@"@" stringByAppendingString:username];
  return nil;
}

NSString *LeadTitleForLogEntry(NSDictionary *entry) {
  NSString *name = entry[@"name"];
  if ([name isKindOfClass:[NSString class]] && name.length) return name;
  NSString *username = entry[@"username"];
  if ([username isKindOfClass:[NSString class]] && username.length) return [@"@" stringByAppendingString:username];
  NSString *peer = entry[@"peer"];
  // The entry was written before Lead knew the chat's name; it may know it by now.
  NSString *current = LeadCurrentPeerTitle(peer);
  if (current) return current;
  return [peer isKindOfClass:[NSString class]] && peer.length > 1 ? [NSString stringWithFormat:@"ID %@", [peer substringFromIndex:1]] : @"Telegram";
}

// Exclusion key for a log peer: channels keep the bare id (as the first version
// stored them), basic groups and private chats keep their "g…"/"u…" tag.
NSString *LeadAntiRevokeExclusionKey(NSString *peer) {
  if (![peer isKindOfClass:[NSString class]] || peer.length < 2) return nil;
  if ([peer hasPrefix:@"c"]) return [peer substringFromIndex:1];
  if ([peer hasPrefix:@"g"] || [peer hasPrefix:@"u"]) return peer;
  return nil;
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
// Section 1: chats seen in the deleted-messages log (tap to exclude), or while
// searching, every chat Lead knows a name for.
@interface LeadAntiRevokeExclusionsViewController () <UISearchResultsUpdating>
@property (nonatomic, strong) NSArray<NSString *> *excluded;
@property (nonatomic, strong) NSArray<NSDictionary *> *candidates; // @{id, name}
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, strong) NSArray<NSDictionary *> *knownChats; // loaded on the first search
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
  self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
  self.search.searchResultsUpdater = self;
  self.search.obscuresBackgroundDuringPresentation = NO;
  self.search.searchBar.placeholder = LeadL(@"UI_EXCLUSIONS_SEARCH");
  self.navigationItem.searchController = self.search;
  self.navigationItem.hidesSearchBarWhenScrolling = NO;
  self.definesPresentationContext = YES;
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload) name:@"LeadMessageLogChanged" object:nil];
  [self reload];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
  [self reload];
}

- (NSString *)query {
  return [self.search.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ?: @"";
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reload {
  self.excluded = LeadAntiRevokeExcludedIds();
  NSMutableArray *candidates = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet setWithArray:self.excluded];
  NSString *query = self.query;
  if (query.length) {
    if (!self.knownChats) {
      NSArray *known = LeadParserCall(@"knownChats", nil);
      self.knownChats = [known isKindOfClass:[NSArray class]] ? known : @[];
    }
    NSString *bare = [query hasPrefix:@"@"] ? [query substringFromIndex:1] : query;
    NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    for (NSDictionary *chat in self.knownChats) {
      if (![chat isKindOfClass:[NSDictionary class]]) continue;
      NSString *name = [chat[@"name"] isKindOfClass:[NSString class]] ? chat[@"name"] : @"";
      NSString *username = [chat[@"username"] isKindOfClass:[NSString class]] ? chat[@"username"] : @"";
      BOOL match = (bare.length && [name rangeOfString:query options:options].location != NSNotFound) ||
                   (bare.length && [username rangeOfString:bare options:options].location != NSNotFound);
      if (!match) continue;
      NSString *key = LeadAntiRevokeExclusionKey(chat[@"peer"]);
      if (!key || [seen containsObject:key]) continue;
      [seen addObject:key];
      NSString *title = name.length ? name : [@"@" stringByAppendingString:username];
      [candidates addObject:@{ @"id" : key, @"name" : title }];
    }
    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
      return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    if (candidates.count > 100) [candidates removeObjectsInRange:NSMakeRange(100, candidates.count - 100)];
    self.candidates = candidates;
    [self.tableView reloadData];
    return;
  }
  for (NSDictionary *entry in LeadMessageLogEntries()) {
    if (![entry isKindOfClass:[NSDictionary class]] || ![entry[@"kind"] isEqualToString:@"deleted"]) continue;
    NSString *key = LeadAntiRevokeExclusionKey(entry[@"peer"]);
    if (!key || [seen containsObject:key]) continue;
    [seen addObject:key];
    [candidates addObject:@{ @"id" : key, @"name" : LeadTitleForLogEntry(entry) }];
  }
  self.candidates = candidates;
  [self.tableView reloadData];
}

- (NSString *)nameForExcluded:(NSString *)channelId {
  BOOL tagged = [channelId hasPrefix:@"g"] || [channelId hasPrefix:@"u"];
  NSString *current = LeadCurrentPeerTitle(tagged ? channelId : [@"c" stringByAppendingString:channelId]);
  if (current) return current;
  NSString *name = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kAntiRevokeExcludedNames][channelId];
  if ([name isKindOfClass:[NSString class]] && name.length) return name;
  return [@"ID " stringByAppendingString:tagged ? [channelId substringFromIndex:1] : channelId];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  NSUInteger count = section == 0 ? self.excluded.count : self.candidates.count;
  return MAX(1, (NSInteger)count); // one placeholder row when empty
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  if (section == 1 && self.query.length) return LeadL(@"UI_EXCLUSIONS_FOUND");
  return LeadL(section == 0 ? @"UI_EXCLUSIONS_CURRENT" : @"UI_EXCLUSIONS_ADD");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  return section == 1 && !self.query.length ? LeadL(@"UI_EXCLUSIONS_FOOTER") : nil;
}

- (BOOL)isPlaceholder:(NSIndexPath *)indexPath {
  return (indexPath.section == 0 ? self.excluded.count : self.candidates.count) == 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
  UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
  if ([self isPlaceholder:indexPath]) {
    content.text = LeadL(indexPath.section == 0 ? @"UI_EXCLUSIONS_EMPTY"
                                                 : (self.query.length ? @"UI_SEARCH_EMPTY" : @"UI_EXCLUSIONS_NO_CANDIDATES"));
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
