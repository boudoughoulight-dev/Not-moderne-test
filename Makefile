
ARCHS = armv7
TARGET = iphone:clang:9.3:9.0

THEOS_PACKAGE_SCHEME = rootless
PACKAGE_FORMAT = deb

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NotificationCenterLite

NotificationCenterLite_FILES = Tweak.xm
NotificationCenterLite_FRAMEWORKS = UIKit Foundation QuartzCore
NotificationCenterLite_CFLAGS = -fobjc-arc
NotificationCenterLite_LDFLAGS =

include $(THEOS_MAKE_PATH)/tweak.mk
