#############################################################
#
# llamac
#
#############################################################

LLAMAC_VERSION = $(shell git ls-remote https://github.com/karpathy/llama2.c master | awk '{ print $$1 }')
LLAMAC_SITE = https://github.com/karpathy/llama2.c
LLAMAC_SITE_METHOD = git

define LLAMAC_BUILD_CMDS
   cd $(@D) && $(MAKE) CC=$(TARGET_CC)
endef

define LLAMAC_INSTALL_TARGET_CMDS
	$(TARGET_STRIP) $(@D)/run
	$(INSTALL) -m 0755 -D $(@D)/run $(TARGET_DIR)/usr/local/bin/llamac-run
endef

define LLAMAC_UNINSTALL_TARGET_CMDS
	rm -f $(TARGET_DIR)/usr/local/bin/llamac-run
endef

$(eval $(generic-package))

