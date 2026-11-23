TARGET := iphone:clang:latest:8.0
ARCHS = armv7 arm64
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DockiOS12
DockiOS12_FILES = Tweak.x
DockiOS12_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
