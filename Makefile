export ARCHS = armv7
export TARGET := iphone:clang:10.3:7.0

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NotificationCenterLite

NotificationCenterLite_FILES = Tweak.xm
NotificationCenterLite_FRAMEWORKS = UIKit QuartzCore Foundation CoreGraphics
NotificationCenterLite_LIBRARIES = substrate
NotificationCenterLite_LDFLAGS = -lobjc
NotificationCenterLite_USE_MODULES = 0
NotificationCenterLite_CFLAGS = -fno-modules -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk