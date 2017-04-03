#import "MSAnalytics.h"
#import "MSAnalyticsCategory.h"
#import "MSAnalyticsInternal.h"
#import "MSAnalyticsPrivate.h"
#import "MSEventLog.h"
#import "MSPageLog.h"
#import "MSServiceAbstractProtected.h"

// Service name for initialization.
static NSString *const kMSServiceName = @"Analytics";

// The group ID for storage.
static NSString *const kMSGroupID = @"Analytics";

// Singleton
static MSAnalytics *sharedInstance = nil;
static dispatch_once_t onceToken;

@implementation MSAnalytics

@synthesize autoPageTrackingEnabled = _autoPageTrackingEnabled;
@synthesize channelConfiguration = _channelConfiguration;

#pragma mark - Service initialization

- (instancetype)init {
  if ((self = [super init])) {

    // Set defaults.
    _autoPageTrackingEnabled = NO;

    // Init session tracker.
    _sessionTracker = [[MSSessionTracker alloc] init];
    _sessionTracker.delegate = self;

    // Init channel configuration.
    _channelConfiguration = [[MSChannelConfiguration alloc] initDefaultChannelWithGroupID:[self groupID]];
  }
  return self;
}

#pragma mark - MSServiceInternal

+ (instancetype)sharedInstance {
  dispatch_once(&onceToken, ^{
    if (sharedInstance == nil) {
      sharedInstance = [[self alloc] init];
    }
  });
  return sharedInstance;
}

+ (NSString *)serviceName {
  return kMSServiceName;
}

- (void)startWithLogManager:(id<MSLogManager>)logManager appSecret:(NSString *)appSecret {
  [super startWithLogManager:logManager appSecret:appSecret];

  // Set up swizzling for auto page tracking.
  [MSAnalyticsCategory activateCategory];
  MSLogVerbose([MSAnalytics logTag], @"Started Analytics service.");
}

+ (NSString *)logTag {
  return @"MobileCenterAnalytics";
}

- (NSString *)groupID {
  return kMSGroupID;
}

#pragma mark - MSServiceAbstract

- (void)applyEnabledState:(BOOL)isEnabled {
  [super applyEnabledState:isEnabled];
  if (isEnabled) {

    // Start session tracker.
    [self.sessionTracker start];

    // Add delegate to log manager.
    [self.logManager addDelegate:self.sessionTracker];

    // Set self as delegate of analytics channel.
    [self.logManager addChannelDelegate:self forGroupID:self.groupID];

    // Report current page while auto page tracking is on.
    if (self.autoPageTrackingEnabled) {

      // Track on the main queue to avoid race condition with page swizzling.
      dispatch_async(dispatch_get_main_queue(), ^{
        if ([[MSAnalyticsCategory missedPageViewName] length] > 0) {
          [[self class] trackPage:(NSString * _Nonnull)[MSAnalyticsCategory missedPageViewName]];
        }
      });
    }

    MSLogInfo([MSAnalytics logTag], @"Analytics service has been enabled.");
  } else {
    [self.logManager removeDelegate:self.sessionTracker];
    [self.logManager removeChannelDelegate:self forGroupID:self.groupID];
    [self.sessionTracker stop];
    [self.sessionTracker clearSessions];
    MSLogInfo([MSAnalytics logTag], @"Analytics service has been disabled.");
  }
}

#pragma mark - Service methods

+ (void)trackEvent:(NSString *)eventName {
  [self trackEvent:eventName withProperties:nil];
}

+ (void)trackEvent:(NSString *)eventName withProperties:(nullable NSDictionary<NSString *, NSString *> *)properties {
  @synchronized(self) {
    if ([[self sharedInstance] canBeUsed]) {
      [[self sharedInstance] trackEvent:eventName withProperties:properties];
    }
  }
}

+ (void)trackPage:(NSString *)pageName {
  [self trackPage:pageName withProperties:nil];
}

+ (void)trackPage:(NSString *)pageName withProperties:(nullable NSDictionary<NSString *, NSString *> *)properties {
  @synchronized(self) {
    if ([[self sharedInstance] canBeUsed]) {
      [[self sharedInstance] trackPage:pageName withProperties:properties];
    }
  }
}

+ (void)setAutoPageTrackingEnabled:(BOOL)isEnabled {
  @synchronized(self) {
    [[self sharedInstance] setAutoPageTrackingEnabled:isEnabled];
  }
}

+ (BOOL)isAutoPageTrackingEnabled {
  @synchronized(self) {
    return [[self sharedInstance] isAutoPageTrackingEnabled];
  }
}

#pragma mark - Private methods

- (BOOL)validateProperties:(NSDictionary<NSString *, NSString *> *)properties {
  for (id key in properties) {
    if (![key isKindOfClass:[NSString class]] || ![properties[key] isKindOfClass:[NSString class]]) {
      return NO;
    }
  }
  return YES;
}

- (void)trackEvent:(NSString *)eventName withProperties:(NSDictionary<NSString *, NSString *> *)properties {
  if (![self isEnabled])
    return;

  // Create and set properties of the event log.
  MSEventLog *log = [[MSEventLog alloc] init];
  log.name = eventName;
  log.eventId = MS_UUID_STRING;
  if (properties && properties.count > 0) {

    // Check if property dictionary contains non-string values.
    if (![self validateProperties:properties]) {
      MSLogError([MSAnalytics logTag],
                 @"The event contains unsupported value type(s). Values should be NSString type.");
      return;
    }
    log.properties = properties;
  }

  // Send log to log manager.
  [self sendLog:log];
}

- (void)trackPage:(NSString *)pageName withProperties:(NSDictionary<NSString *, NSString *> *)properties {
  if (![super isEnabled])
    return;

  // Create and set properties of the event log.
  MSPageLog *log = [[MSPageLog alloc] init];
  log.name = pageName;
  if (properties && properties.count > 0) {

    // Check if property dictionary contains non-string values.
    if (![self validateProperties:properties]) {
      MSLogError([MSAnalytics logTag], @"The page contains unsupported value type(s). Values should be NSString type.");
      return;
    }
    log.properties = properties;
  }

  // Send log to log manager.
  [self sendLog:log];
}

- (void)setAutoPageTrackingEnabled:(BOOL)isEnabled {
  _autoPageTrackingEnabled = isEnabled;
}

- (BOOL)isAutoPageTrackingEnabled {
  return self.autoPageTrackingEnabled;
}

- (void)sendLog:(id<MSLog>)log {

  // Send log to log manager.
  [self.logManager processLog:log forGroupID:self.groupID];
}

+ (void)resetSharedInstance {

  // resets the once_token so dispatch_once will run again
  onceToken = 0;
  sharedInstance = nil;
}

#pragma mark - MSSessionTracker

- (void)sessionTracker:(id)sessionTracker processLog:(id<MSLog>)log {
  (void)sessionTracker;
  [self sendLog:log];
}

+ (void)setDelegate:(nullable id<MSAnalyticsDelegate>)delegate {
  [[self sharedInstance] setDelegate:delegate];
}

#pragma mark - MSChannelDelegate

- (void)channel:(id<MSChannel>)channel willSendLog:(id<MSLog>)log {
  (void)channel;
  if (!self.delegate) {
    return;
  }
  NSObject *logObject = (NSObject *)log;
  if ([logObject isKindOfClass:[MSEventLog class]] &&
      [self.delegate respondsToSelector:@selector(analytics:willSendEventLog:)]) {
    MSEventLog *eventLog = (MSEventLog *)log;
    [self.delegate analytics:self willSendEventLog:eventLog];
  } else if ([logObject isKindOfClass:[MSPageLog class]] &&
             [self.delegate respondsToSelector:@selector(analytics:willSendPageLog:)]) {
    MSPageLog *pageLog = (MSPageLog *)log;
    [self.delegate analytics:self willSendPageLog:pageLog];
  }
}

- (void)channel:(id<MSChannel>)channel didSucceedSendingLog:(id<MSLog>)log {
  (void)channel;
  if (!self.delegate) {
    return;
  }
  NSObject *logObject = (NSObject *)log;
  if ([logObject isKindOfClass:[MSEventLog class]] &&
      [self.delegate respondsToSelector:@selector(analytics:didSucceedSendingEventLog:)]) {
    MSEventLog *eventLog = (MSEventLog *)log;
    [self.delegate analytics:self didSucceedSendingEventLog:eventLog];
  } else if ([logObject isKindOfClass:[MSPageLog class]] &&
             [self.delegate respondsToSelector:@selector(analytics:didSucceedSendingPageLog:)]) {
    MSPageLog *pageLog = (MSPageLog *)log;
    [self.delegate analytics:self didSucceedSendingPageLog:pageLog];
  }
}

- (void)channel:(id<MSChannel>)channel didFailSendingLog:(id<MSLog>)log withError:(NSError *)error {
  (void)channel;
  if (!self.delegate) {
    return;
  }
  NSObject *logObject = (NSObject *)log;
  if ([logObject isKindOfClass:[MSEventLog class]] &&
      [self.delegate respondsToSelector:@selector(analytics:didFailSendingEventLog:withError:)]) {
    MSEventLog *eventLog = (MSEventLog *)log;
    [self.delegate analytics:self didFailSendingEventLog:eventLog withError:error];
  } else if ([logObject isKindOfClass:[MSPageLog class]] &&
             [self.delegate respondsToSelector:@selector(analytics:didFailSendingPageLog:withError:)]) {
    MSPageLog *pageLog = (MSPageLog *)log;
    [self.delegate analytics:self didFailSendingPageLog:pageLog withError:error];
  }
}

@end
