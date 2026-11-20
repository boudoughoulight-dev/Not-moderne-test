export TARGET := iphone:clang:10.3:7.0
export ARCHS = armv7

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NotificationCenterLite

NotificationCenterLite_FILES = Tweak.xm
NotificationCenterLite_FRAMEWORKS = UIKit QuartzCore MediaPlayer
NotificationCenterLite_USE_MODULES = 0
NotificationCenterLite_CFLAGS = -fno-modules -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable

include $(THEOS_MAKE_PATH)/tweak.mk
