ARCHS = armv7
TARGET = iphone:clang:10.3:9.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NotificationCenterLite

NotificationCenterLite_FILES = Tweak.xm
NotificationCenterLite_FRAMEWORKS = UIKit Foundation QuartzCore MediaPlayer
NotificationCenterLite_USE_MODULES = 0
NotificationCenterLite_CFLAGS = -fno-modules
NotificationCenterLite_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
