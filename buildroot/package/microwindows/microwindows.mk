#############################################################
#
# microwindows
#
#############################################################

MICROWINDOWS_VERSION = v0.0.0
MICROWINDOWS_SITE = $(call github,machdyne,microwindows,$(MICROWINDOWS_VERSION))

define MICROWINDOWS_BUILD_CMDS
    echo test && cd $(@D)/src && $(TARGET_CONFIGURE_OPTS) $(MAKE)
endef

define MICROWINDOWS_INSTALL_TARGET_CMDS
    $(INSTALL) -m 0755 $(@D)/src/bin/* -t $(TARGET_DIR)/usr/local/mw
endef

$(eval $(generic-package))
