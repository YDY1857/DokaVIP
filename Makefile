# DokaVip — Theos tweak Makefile
# 目标 App: com.ydgn.dokacamera (Doka Camera / Follow) v1.8.22
# 构建需要 Theos + iOS SDK（由 GitHub Actions 自动准备）

# 平台:工具链:SDK版本:最低部署版本
# latest 会自动选用 $THEOS/sdks 里版本最高的 iOS SDK（我们放的是 16.5）
TARGET := iphone:clang:latest:13.0
ARCHS := arm64

# 安装（make install）后重启的目标进程名（= CFBundleExecutable）
INSTALL_TARGET_PROCESSES = Follow

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DokaVip
DokaVip_FILES = Tweak.x
DokaVip_CFLAGS = -fobjc-arc
DokaVip_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

# 打包完成后打印提示
after-package::
	@echo ">>> DokaVip 构建完成，.deb 位于 ./packages/"
