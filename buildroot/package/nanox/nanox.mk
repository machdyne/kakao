#############################################################
#
# nanox
#
#############################################################

NANOX_VERSION = main
NANOX_SITE = https://github.com/machdyne/nanox.git
NANOX_SITE_METHOD = git

define NANOX_BUILD_CMDS
	cd $(@D)/src && $(TARGET_CONFIGURE_OPTS) $(MAKE) RVTOOLSPREFIX=$(TARGET_CROSS)
	cd $(@D)/src/9menu && $(TARGET_CONFIGURE_OPTS) $(MAKE)
endef

define NANOX_INSTALL_TARGET_CMDS
	$(INSTALL) -m 0755 -d $(TARGET_DIR)/usr/local/nx
	$(INSTALL) -m 0755 -d $(TARGET_DIR)/usr/local/nx/bin
	$(INSTALL) -m 0755 $(@D)/src/bin/* $(TARGET_DIR)/usr/local/nx/bin
	#$(INSTALL) -m 0755 $(@D)/src/9menu/9menu -t $(TARGET_DIR)/usr/local/nx/bin
	rm -f $(TARGET_DIR)/usr/local/nx/bin/conv*
	rm -f $(TARGET_DIR)/usr/local/nx/bin/makebmp
endef

$(eval $(generic-package))
