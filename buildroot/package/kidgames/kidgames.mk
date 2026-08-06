################################################################################
#
# kidgames
#
################################################################################

KIDGAMES_VERSION = main
KIDGAMES_SITE = $(call github,machdyne,kidgames,$(KIDGAMES_VERSION))

KIDGAMES_DEPENDENCIES = ncurses

define KIDGAMES_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) \
		CC="$(TARGET_CC)"
endef

define KIDGAMES_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/kidgames \
		$(TARGET_DIR)/usr/bin/kidgames
endef

$(eval $(generic-package))
