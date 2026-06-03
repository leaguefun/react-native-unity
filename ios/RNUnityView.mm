#import "RNUnityView.h"
#ifdef DEBUG
#include <mach-o/ldsyms.h>
#endif
#ifdef RCT_NEW_ARCH_ENABLED
using namespace facebook::react;
#endif

NSString *bundlePathStr = @"/Frameworks/UnityFramework.framework";
int gArgc = 1;

UnityFramework* UnityFrameworkLoad() {
    NSString* bundlePath = nil;
    bundlePath = [[NSBundle mainBundle] bundlePath];
    bundlePath = [bundlePath stringByAppendingString: bundlePathStr];

    NSBundle* bundle = [NSBundle bundleWithPath: bundlePath];
    if ([bundle isLoaded] == false) [bundle load];

    UnityFramework* ufw = [bundle.principalClass getInstance];
    if (![ufw appController])
    {
#ifdef DEBUG
      [ufw setExecuteHeader: &_mh_dylib_header];
#else
      [ufw setExecuteHeader: &_mh_execute_header];
#endif
    }

    [ufw setDataBundleId: [bundle.bundleIdentifier cStringUsingEncoding:NSUTF8StringEncoding]];

    return ufw;
}

@implementation RNUnityView

NSDictionary* appLaunchOpts;

static RNUnityView *sharedInstance;

- (bool)unityIsInitialized {
    return [self ufw] && [[self ufw] appController];
}

- (void)initUnityModule {
    @try {
        if([self unityIsInitialized]) {
            return;
        }

        [self setUfw: UnityFrameworkLoad()];

        if (![self ufw]) {
            NSLog(@"[RNUnity] ERROR: UnityFrameworkLoad returned nil");
            return;
        }

        [[self ufw] registerFrameworkListener: self];

        unsigned count = (int) [[[NSProcessInfo processInfo] arguments] count];
        char **array = (char **)malloc((count + 1) * sizeof(char*));

        for (unsigned i = 0; i < count; i++)
        {
             array[i] = strdup([[[[NSProcessInfo processInfo] arguments] objectAtIndex:i] UTF8String]);
        }
        array[count] = NULL;

        [[self ufw] runEmbeddedWithArgc: gArgc argv: array appLaunchOpts: appLaunchOpts];

        if (![[self ufw] appController]) {
            NSLog(@"[RNUnity] ERROR: appController nil after runEmbedded");
            return;
        }

        [[self ufw] appController].quitHandler = ^(){ NSLog(@"AppController.quitHandler called"); };

        // Remove Unity's rootView from Unity's own view hierarchy
        UIView *unityRootView = self.ufw.appController.rootView;
        [unityRootView removeFromSuperview];

        // Hide Unity's window so it doesn't cover React Native's UI
        UIWindow *unityWindow = [[[self ufw] appController] window];
        unityWindow.hidden = YES;

        // Restore React Native's window as key window
        UIWindow *rnWindow = [[[UIApplication sharedApplication] delegate] window];
        if (!rnWindow) {
            // iOS 13+ scene-based: find the first connected scene's window
            if (@available(iOS 13.0, *)) {
                for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if ([scene isKindOfClass:[UIWindowScene class]]) {
                        UIWindowScene *windowScene = (UIWindowScene *)scene;
                        for (UIWindow *w in windowScene.windows) {
                            if (w != unityWindow) {
                                rnWindow = w;
                                break;
                            }
                        }
                        if (rnWindow) break;
                    }
                }
            }
        }
        if (rnWindow) {
            [rnWindow makeKeyAndVisible];
        }

        // Add Unity's rendering view to self (the RN component view)
        unityRootView.frame = self.bounds;
        [self addSubview:unityRootView];

        [NSClassFromString(@"FrameworkLibAPI") registerAPIforNativeCalls:self];
    }
    @catch (NSException *e) {
        NSLog(@"[RNUnity] EXCEPTION: %@", e.reason);
    }
}

- (void)layoutSubviews {
   [super layoutSubviews];

   if([self unityIsInitialized]) {
      self.ufw.appController.rootView.frame = self.bounds;
      [self addSubview:self.ufw.appController.rootView];
   }


}

- (void)pauseUnity:(BOOL * _Nonnull)pause {
    if([self unityIsInitialized]) {
        [[self ufw] pause:pause];
    }
}

- (void)unloadUnity {
    UIWindow * main = [[[UIApplication sharedApplication] delegate] window];
    if(main != nil) {
        [main makeKeyAndVisible];

        if([self unityIsInitialized]) {
            [[self ufw] unloadApplication];
        }
    }
}

- (void)sendMessageToMobileApp:(NSString *)message {
    if (self.onUnityMessage) {
        NSDictionary* data = @{
            @"message": message
        };

        self.onUnityMessage(data);
    }
}

- (void)unityDidUnload:(NSNotification*)notification {
    if([self unityIsInitialized]) {
        [[self ufw] unregisterFrameworkListener:self];
        [self setUfw: nil];

        if (self.onPlayerUnload) {
            self.onPlayerUnload(nil);
        }
    }
}

- (void)unityDidQuit:(NSNotification*)notification {
    if([self unityIsInitialized]) {
        [[self ufw] unregisterFrameworkListener:self];
        [self setUfw: nil];

        if (self.onPlayerQuit) {
            self.onPlayerQuit(nil);
        }
    }
}

- (dispatch_queue_t)methodQueue {
    return dispatch_get_main_queue();
}

- (NSArray<NSString *> *)supportedEvents {
    return @[@"onUnityMessage", @"onPlayerUnload", @"onPlayerQuit"];
}

- (void)postMessage:(NSString *)gameObject methodName:(NSString*)methodName message:(NSString*) message {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[self ufw] sendMessageToGOWithName:[gameObject UTF8String] functionName:[methodName UTF8String] message:[message UTF8String]];
    });
}

#ifdef RCT_NEW_ARCH_ENABLED
- (void)prepareForRecycle {
    [super prepareForRecycle];

    if ([self unityIsInitialized]) {
      [[self ufw] unloadApplication];

      NSArray *viewsToRemove = self.subviews;
      for (UIView *v in viewsToRemove) {
          [v removeFromSuperview];
      }

      [self setUfw:nil];
    }
}

+ (ComponentDescriptorProvider)componentDescriptorProvider {
    return concreteComponentDescriptorProvider<RNUnityViewComponentDescriptor>();
}

- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps = std::make_shared<const RNUnityViewProps>();
    _props = defaultProps;

    self.onUnityMessage = [self](NSDictionary* data) {
      if (_eventEmitter != nil) {
        auto gridViewEventEmitter = std::static_pointer_cast<RNUnityViewEventEmitter const>(_eventEmitter);
        facebook::react::RNUnityViewEventEmitter::OnUnityMessage event = {
          .message=[[data valueForKey:@"message"] UTF8String]
        };
        gridViewEventEmitter->onUnityMessage(event);
      }
    };
  }

  return self;
}

- (void)updateEventEmitter:(EventEmitter::Shared const &)eventEmitter {
    [super updateEventEmitter:eventEmitter];
}

- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps {
    if (![self unityIsInitialized]) {
      [self initUnityModule];
    }

    [super updateProps:props oldProps:oldProps];
}

- (void)handleCommand:(nonnull const NSString *)commandName args:(nonnull const NSArray *)args {
    RCTRNUnityViewHandleCommand(self, commandName, args);
}

Class<RCTComponentViewProtocol> RNUnityViewCls(void) {
    return RNUnityView.class;
}

#else

-(id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self) {
        [self initUnityModule];
    }

    return self;
}

#endif

@end
