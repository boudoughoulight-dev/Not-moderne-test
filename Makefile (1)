TARGET := iphone:clang:10.3:9.0
ARCHS = armv7
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MeteoWidget
MeteoWidget_FILES = Tweak.xm
MeteoWidget_FRAMEWORKS = UIKit QuartzCore
MeteoWidget_USE_MODULES = 0
MeteoWidget_CFLAGS = -fobjc-arc -fno-modules
MeteoWidget_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
