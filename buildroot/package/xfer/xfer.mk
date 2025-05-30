#############################################################
#
# xfer
#
#############################################################

XFER_VERSION = main
XFER_SITE = https://github.com/machdyne/xfer.git
XFER_SITE_METHOD = git

define XFER_BUILD_CMDS
	cd $(@D) && $(MAKE) CC=$(TARGET_CC)
endef

define XFER_INSTALL_TARGET_CMDS
	$(INSTALL) -m 0755 $(@D)/xfer $(TARGET_DIR)/usr/local/bin/xfer
endef

$(eval $(generic-package))
