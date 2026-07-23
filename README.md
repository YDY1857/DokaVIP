# DokaVip

Doka 相机（Follow.app，Bundle ID `com.ydgn.dokacamera`）v1.8.22 的 Theos 越狱插件。

> ⚠️ 仅供技术学习交流，请勿用于商业用途。

## 功能

| 功能 | 实现方式 | 说明 |
|------|----------|------|
| **VIP 解锁（第 1 层）** | Hook `NSJSONSerialization +JSONObjectWithData:options:error:` | 把服务器返回里的 `is_vip` 改成 true、`expire_time` 改成 `2099-12-31 23:59:59`、`remaining_count` 改成 9999 |
| **VIP 解锁（第 2 层）** | Hook `NSUserDefaults` 的 `objectForKey:` / `stringForKey:` / `integerForKey:` | 覆写本地缓存 `VipManager.expiryDate`、`VipManager.originalTransactionId`、`VipManager.freeUseCount`。App 在本地也缓存 VIP 状态，两层必须都改 |
| **设备身份随机化** | Hook `NSMutableURLRequest -setAllHTTPHeaderFields:` | 每次请求把 `User-Agent-Follow` 头里的 `deviceUUID` / `Device-ID` / `device_model` / `os_version` 换成随机设备，绕过单一设备校验与次数限制 |
| **Anti-Debug** | `MSHookFunction` 钩 `ptrace` / `sysctl` / `getppid` | 屏蔽 `PT_DENY_ATTACH`、清除 `P_TRACED` 标志、伪装父进程为 launchd |

> 原教程里的「Frida 反检测绕过（异常处理器 + 帧指针回溯）」是 Frida 独有手段，在 Substrate/Substitute 注入模式下不需要——tweak 直接注入，不存在 Frida 进程特征。

## 目录结构

```
DokaVip/
├── Makefile                    # Theos 构建配置
├── control                     # Debian 包信息（需改 Package/Maintainer/Author）
├── DokaVip.plist               # 注入过滤：只对 com.ydgn.dokacamera 生效
├── Tweak.x                     # 核心代码（Logos 语法）
├── .gitignore
├── README.md
└── .github/workflows/build.yml # 在 GitHub macOS runner 上编译并产出 .deb
```

## 你（Windows 用户）如何"跑出"这个插件

你本地是 Windows，没法直接跑 Theos（它需要 macOS / iOS 工具链）。所以我们把**编译放到 GitHub 上**：
把仓库推到 GitHub → GitHub Actions 用 macOS 虚拟机自动编译 → 你下载编译好的 `.deb`。

### 第 1 步：改一下 control 信息（可选）

打开 `control`，把下面几项改成你自己的：

```
Package: com.你的名字.dokavip
Maintainer: 你的名字 <you@example.com>
Author: 你的名字 <you@example.com>
```

### 第 2 步：在 GitHub 上建仓库并推送

**方式 A：用 GitHub 网页**
1. 打开 https://github.com/new ，仓库名填 `DokaVip`，选 **Public**（私有仓库 Actions 也免费，但公开更省额度），不要勾选自动生成 README/.gitignore（我们已经有了）。
2. 在本机 `DokaVip` 目录打开 Git Bash，执行：

```bash
cd DokaVip
git init
git add .
git commit -m "Add DokaVip Theos tweak"
git branch -M main
git remote add origin https://github.com/<你的用户名>/DokaVip.git
git push -u origin main
```

**方式 B：已装 GitHub CLI (`gh`)**
```bash
cd DokaVip
git init && git add . && git commit -m "Add DokaVip Theos tweak"
gh repo create DokaVip --public --source=. --push
```

### 第 3 步：运行 GitHub Actions 构建

1. 进入仓库 → **Actions** 标签 → 左边选 **Build DokaVip**。
2. 点 **Run workflow**（如果是 push 触发，推送后已自动开始）。
3. 等个几分钟，看到绿色 ✓ 即成功。

### 第 4 步：下载 .deb

- 进 **Actions → 对应那次运行 → 底部 "Artifacts"** 里下载 `DokaVip-<运行号>.zip`，解压得到 `.deb`。
- 如果是打 **Release** 触发的，`.deb` 会直接挂在 Release 资源里。

### 第 5 步：安装到手机

- **TrollStore（巨魔）**：把 `.deb` 用 TrollStore 注入到 Doka 相机 App 即可（教程原话"安装直接通过巨魔注入对应 app 即可"）。
- **越狱环境（Sileo / Zebra / Cydia）**：把 `.deb` 传到手机，`dpkg -i DokaVip_*.deb` 安装，重启 App（或在 Makefile 里 `make install` 让 `INSTALL_TARGET_PROCESSES=Follow` 自动重启）。

## 在本地 macOS / Linux 编译（可选）

如果你有 Mac 或 Linux + Theos 环境，也可本地编译：

```bash
export THEOS=/path/to/theos
make package FINALPACKAGE=1
# 产物在 ./packages/DokaVip_1.8.22_iphoneos-arm.deb
```

## 技术备注 / 已验证点

针对 v1.8.22 主二进制 `Follow` 校验过以下关键字符串仍存在，故 hook 点有效：
`VipManager.expiryDate`、`VipManager.originalTransactionId`、`VipManager.freeUseCount`、
`User-Agent-Follow`、`deviceUUID`、`Device-ID`、`device_model`、`os_version`、`is_vip`、`expire_time`、`remaining_count`。

相比 v1.6.5，v1.8.22 的请求头 JSON 已不含 `os_type` / `doka_version`，Tweak.x 里针对此做了兼容
（只替换存在的设备字段，缺失字段忽略）。

若安装后 VIP 没生效，优先排查：`VipManager` 是否新增了别的本地校验 key（如 `purchaseParams` /
`freeAIComposeCount`），按需照葫芦画瓢在 `NSUserDefaults` 里再加 hook 即可。
