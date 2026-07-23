/*
 * DokaVip — Theos tweak for Doka Camera (Follow.app / com.ydgn.dokacamera)
 *
 * 功能（基于吾爱破解教程整理，适配 v1.8.22）：
 *   1. VIP 解锁 —— 两层覆写：
 *        a) 服务器 JSON 响应里把 is_vip / expire_time / remaining_count 改掉
 *        b) NSUserDefaults 本地缓存里把 VipManager.expiryDate / originalTransactionId / freeUseCount 改掉
 *   2. 设备身份随机化 —— 每次请求把 User-Agent-Follow 头里的 deviceUUID / Device-ID /
 *      device_model / os_version 换成随机设备，绕过"单一设备校验/次数限制"
 *   3. Anti-Debug —— Hook ptrace / sysctl / getppid，隐藏调试痕迹
 *
 * 说明：原教程里的"Frida 反检测绕过（异常处理器 + 帧指针回溯）"是 Frida 独有的，
 *       在 Substrate/Substitute 注入模式下不需要——tweak 直接注入，不存在 Frida 进程特征。
 *
 * 仅供技术学习交流，请勿用于商业用途。
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>   // MSHookFunction
#import <dlfcn.h>       // dlsym / RTLD_DEFAULT
#import <sys/sysctl.h>  // struct kinfo_proc, CTL_KERN, KERN_PROC, KERN_PROC_PID
#import <sys/types.h>

// P_TRACED 来自内核私有头 <sys/proc.h>，公开 SDK 里没有，这里手动定义
#ifndef P_TRACED
#define P_TRACED 0x00000800
#endif

// ====================================================================
#pragma mark - 首次启动欢迎弹窗
// ====================================================================

static NSString *const DokaWelcomeShownKey = @"com.ydy1857.dokavip.welcome-shown.v1";

static UIImage *DokaWelcomeIcon(void) {
    Dl_info info;
    if (!dladdr((const void *)&DokaWelcomeIcon, &info) || !info.dli_fname) return nil;
    NSString *directory = [[[NSString alloc] initWithUTF8String:info.dli_fname] stringByDeletingLastPathComponent];
    return [UIImage imageWithContentsOfFile:[directory stringByAppendingPathComponent:@"DokaVipAvatar.jpg"]];
}

static void DokaShowWelcomeOnce(UIViewController *host) {
    static BOOL scheduled = NO;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (scheduled || [defaults boolForKey:DokaWelcomeShownKey] || !host.view.window) return;
    scheduled = YES;
    [defaults setBool:YES forKey:DokaWelcomeShownKey];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    NSAttributedString *title = [[NSAttributedString alloc]
        initWithString:@"恭喜您成功安装本应用"
        attributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:18.0]}];
    [alert setValue:title forKey:@"attributedTitle"];

    NSMutableAttributedString *message = [[NSMutableAttributedString alloc]
        initWithString:@"IOS果物集"
        attributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:17.0],
                     NSForegroundColorAttributeName: [UIColor systemRedColor]}];
    UIImage *icon = DokaWelcomeIcon();
    if (icon) {
        NSTextAttachment *attachment = [NSTextAttachment new];
        attachment.image = icon;
        attachment.bounds = CGRectMake(4.0, -8.0, 32.0, 32.0);
        [message appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
    }
    [message appendAttributedString:[[NSAttributedString alloc]
        initWithString:@"\n欢迎使用\n\n严禁任何贩卖本插件/软件的盈利行为\n本插件仅供学习研究使用\n请在24小时内自觉删除本插件/软件"
        attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:14.0],
                     NSForegroundColorAttributeName: [UIColor labelColor]}]];
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineSpacing = 5.0;
    [message addAttribute:NSParagraphStyleAttributeName value:paragraph range:NSMakeRange(0, message.length)];
    [alert setValue:message forKey:@"attributedMessage"];

    UIAlertAction *enter = [UIAlertAction actionWithTitle:@"进入应用（10秒）"
                                                    style:UIAlertActionStyleDefault
                                                  handler:nil];
    enter.enabled = NO;
    [alert addAction:enter];
    [host presentViewController:alert animated:YES completion:nil];

    __block NSInteger remaining = 10;
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        remaining--;
        if (remaining == 0) {
            [enter setValue:@"进入应用" forKey:@"title"];
            enter.enabled = YES;
            [timer invalidate];
        } else {
            [enter setValue:[NSString stringWithFormat:@"进入应用（%ld秒）", (long)remaining] forKey:@"title"];
        }
    }];
}

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    DokaShowWelcomeOnce(self);
}

%end

// ====================================================================
#pragma mark - 随机设备池
// ====================================================================

static NSDictionary *newRandomDevice(void) {
    // 15 款 iPhone 机型 + 各自匹配的 iOS 版本
    static NSArray *devices = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        devices = @[
            @{@"id":@"iPhone15,2", @"model":@"iPhone 14 Pro",     @"versions":@[@"16.0",@"16.1",@"16.2",@"16.3",@"16.4",@"16.5",@"16.6"]},
            @{@"id":@"iPhone15,3", @"model":@"iPhone 14 Pro Max", @"versions":@[@"16.0",@"16.1",@"16.2",@"16.3",@"16.4",@"16.5",@"16.6"]},
            @{@"id":@"iPhone14,2", @"model":@"iPhone 13 Pro",     @"versions":@[@"15.0",@"15.1",@"15.2",@"15.3",@"15.4",@"15.5",@"15.6",@"16.0",@"16.1"]},
            @{@"id":@"iPhone14,3", @"model":@"iPhone 13 Pro Max", @"versions":@[@"15.0",@"15.1",@"15.2",@"15.3",@"15.4",@"15.5",@"15.6",@"16.0",@"16.1"]},
            @{@"id":@"iPhone14,4", @"model":@"iPhone 13 mini",    @"versions":@[@"15.0",@"15.1",@"15.2",@"15.3",@"15.4",@"15.5",@"15.6",@"16.0",@"16.1"]},
            @{@"id":@"iPhone14,5", @"model":@"iPhone 13",         @"versions":@[@"15.0",@"15.1",@"15.2",@"15.3",@"15.4",@"15.5",@"15.6",@"16.0",@"16.1"]},
            @{@"id":@"iPhone13,3", @"model":@"iPhone 12 Pro",     @"versions":@[@"14.0",@"14.1",@"14.2",@"14.3",@"14.4",@"14.5",@"14.6",@"14.7",@"14.8",@"15.0",@"15.1"]},
            @{@"id":@"iPhone13,4", @"model":@"iPhone 12 Pro Max", @"versions":@[@"14.0",@"14.1",@"14.2",@"14.3",@"14.4",@"14.5",@"14.6",@"14.7",@"14.8",@"15.0",@"15.1"]},
            @{@"id":@"iPhone12,3", @"model":@"iPhone 11 Pro",     @"versions":@[@"13.0",@"13.1",@"13.2",@"13.3",@"13.4",@"13.5",@"13.6",@"14.0",@"14.1"]},
            @{@"id":@"iPhone12,5", @"model":@"iPhone 11 Pro Max", @"versions":@[@"13.0",@"13.1",@"13.2",@"13.3",@"13.4",@"13.5",@"13.6",@"14.0",@"14.1"]},
            @{@"id":@"iPhone15,4", @"model":@"iPhone 15",          @"versions":@[@"17.0",@"17.1",@"17.2",@"17.3",@"17.4",@"17.5",@"17.6"]},
            @{@"id":@"iPhone15,5", @"model":@"iPhone 15 Plus",     @"versions":@[@"17.0",@"17.1",@"17.2",@"17.3",@"17.4",@"17.5",@"17.6"]},
            @{@"id":@"iPhone16,1", @"model":@"iPhone 15 Pro",      @"versions":@[@"17.0",@"17.1",@"17.2",@"17.3",@"17.4",@"17.5",@"17.6"]},
            @{@"id":@"iPhone16,2", @"model":@"iPhone 15 Pro Max",  @"versions":@[@"17.0",@"17.1",@"17.2",@"17.3",@"17.4",@"17.5",@"17.6"]},
            @{@"id":@"iPhone16,3", @"model":@"iPhone 15 Pro",      @"versions":@[@"17.0",@"17.1",@"17.2",@"17.3",@"17.4",@"17.5",@"17.6"]},
        ];
    });

    NSDictionary *d = devices[arc4random_uniform((uint32_t)devices.count)];
    NSArray *versions = d[@"versions"];
    NSString *ver = versions[arc4random_uniform((uint32_t)versions.count)];
    NSString *uuid = [[[NSUUID UUID] UUIDString] lowercaseString];

    return @{
        @"deviceUUID":   uuid,
        @"Device-ID":    d[@"id"],
        @"device_model": d[@"model"],
        @"os_version":   ver,
    };
}

// ====================================================================
#pragma mark - VIP 解锁（第 1 层）：JSON 响应
// ====================================================================

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id result = %orig;

    if (![result isKindOfClass:[NSDictionary class]]) return result;

    NSDictionary *dataDict = result[@"data"];
    if (![dataDict isKindOfClass:[NSDictionary class]]) return result;
    if (!dataDict[@"is_vip"]) return result;   // 只处理含 is_vip 的响应

    NSMutableDictionary *mData = [dataDict mutableCopy];
    NSMutableDictionary *mRoot = [result mutableCopy];

    mData[@"is_vip"]         = @YES;
    mData[@"expire_time"]    = @"2099-12-31 23:59:59";
    mData[@"remaining_count"] = @9999;

    mRoot[@"data"] = mData;
    return mRoot;
}

%end

// ====================================================================
#pragma mark - VIP 解锁（第 2 层）：NSUserDefaults 本地缓存
//   App 在本地也用 NSUserDefaults 缓存 VIP 状态，两层都要改才行
//   精准匹配 key，不无差别 Hook，避免 App 崩溃
// ====================================================================

%hook NSUserDefaults

- (id)objectForKey:(NSString *)key {
    if ([key isEqualToString:@"VipManager.expiryDate"]) {
        // 2099-12-31 23:59:59 UTC ≈ 4102444799 秒
        return [NSDate dateWithTimeIntervalSince1970:4102444799.0];
    }
    if ([key isEqualToString:@"VipManager.originalTransactionId"]) {
        return @"530000123456789";
    }
    return %orig;
}

- (NSString *)stringForKey:(NSString *)key {
    if ([key isEqualToString:@"VipManager.originalTransactionId"]) {
        return @"530000123456789";
    }
    return %orig;
}

- (NSInteger)integerForKey:(NSString *)key {
    if ([key isEqualToString:@"VipManager.freeUseCount"]) {
        return 9999;
    }
    return %orig;
}

%end

// ====================================================================
#pragma mark - 设备身份随机化：HTTP 请求头
//   解析 User-Agent-Follow(JSON) → 替换设备字段 → 序列化回去
// ====================================================================

// 把 User-Agent-Follow 的 JSON 字符串里的设备字段随机化，返回新字符串（失败则原样返回）
static NSString *randomizedUserAgentFollow(NSString *ua) {
    if (![ua isKindOfClass:[NSString class]] || ua.length == 0) return ua;

    NSData *jsonData = [ua dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err = nil;
    NSMutableDictionary *parsed = [NSJSONSerialization JSONObjectWithData:jsonData
                                                                  options:NSJSONReadingMutableContainers
                                                                    error:&err];
    if (err || ![parsed isKindOfClass:[NSMutableDictionary class]]) return ua;

    NSDictionary *dev = newRandomDevice();
    // 只替换存在的设备字段（兼容不同版本字段差异，如 1.8.22 已无 os_type / doka_version）
    if (dev[@"deviceUUID"])    parsed[@"deviceUUID"]    = dev[@"deviceUUID"];
    if (dev[@"Device-ID"])     parsed[@"Device-ID"]     = dev[@"Device-ID"];
    if (dev[@"device_model"])  parsed[@"device_model"]  = dev[@"device_model"];
    if (dev[@"os_version"])    parsed[@"os_version"]    = dev[@"os_version"];

    NSData *outData = [NSJSONSerialization dataWithJSONObject:parsed options:0 error:&err];
    if (err || !outData) return ua;

    NSString *res = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
    return res ? res : ua;
}

%hook NSMutableURLRequest

- (void)setAllHTTPHeaderFields:(NSDictionary *)fields {
    if (![fields isKindOfClass:[NSDictionary class]] || !fields[@"User-Agent-Follow"]) {
        %orig;
        return;
    }
    NSMutableDictionary *newFields = [fields mutableCopy];
    newFields[@"User-Agent-Follow"] = randomizedUserAgentFollow(fields[@"User-Agent-Follow"]);
    %orig(newFields);
}

// 备份入口：部分网络栈会用 setValue:forHTTPHeaderField: 单独设置头
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if ([field isEqualToString:@"User-Agent-Follow"]) {
        %orig(randomizedUserAgentFollow(value), field);
    } else {
        %orig;
    }
}

%end

// ====================================================================
#pragma mark - Anti-Debug：ptrace / sysctl / getppid
// ====================================================================

static int (*orig_ptrace)(int request, pid_t pid, caddr_t addr, int data);
static int hook_ptrace(int request, pid_t pid, caddr_t addr, int data) {
    if (request == 31) request = 0;   // PT_DENY_ATTACH = 31，置 0 绕过
    return orig_ptrace(request, pid, addr, data);
}

static int (*orig_sysctl)(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
static int hook_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    // 清除 P_TRACED 调试标志位（仅处理 KERN_PROC_PID 查询）
    if (ret == 0 && namelen >= 4 && oldp != NULL &&
        name[0] == CTL_KERN && name[1] == KERN_PROC && name[2] == KERN_PROC_PID) {
        struct kinfo_proc *info = (struct kinfo_proc *)oldp;
        info->kp_proc.p_flag &= ~P_TRACED;
    }
    return ret;
}

static pid_t (*orig_getppid)(void);
static pid_t hook_getppid(void) {
    return 1;   // 伪装成 launchd 的子进程，隐藏调试器父进程
}

%ctor {
    MSHookFunction(dlsym(RTLD_DEFAULT, "ptrace"),  (void *)hook_ptrace,  (void **)&orig_ptrace);
    MSHookFunction(dlsym(RTLD_DEFAULT, "sysctl"),  (void *)hook_sysctl,  (void **)&orig_sysctl);
    MSHookFunction(dlsym(RTLD_DEFAULT, "getppid"), (void *)hook_getppid, (void **)&orig_getppid);
}
