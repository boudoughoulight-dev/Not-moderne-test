TARGET := iphone:clang:10.3:8.0
ARCHS = armv7
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DockiOS12
DockiOS12_FILES = tweak.xm
DockiOS12_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
