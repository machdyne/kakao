#############################################################
#
# netkit-telnet
#
#############################################################

NETKIT_TELNET_VERSION = main
NETKIT_TELNET_SITE = https://github.com/machdyne/netkit-telnet.git
NETKIT_TELNET_SITE_METHOD = git

define NETKIT_TELNET_BUILD_CMDS
   # build tcc for riscv32
   cd $(@D) && ./configure --prefix=$(TARGET_DIR)/usr/local --with-c-compiler=$(TARGET_CC) --with-c++-compiler=$(TARGET_CXX)
   cd $(@D)/telnet && $(MAKE)
endef

define NETKIT_TELNET_INSTALL_TARGET_CMDS
	$(TARGET_STRIP) $(@D)/telnet/telnet
	$(INSTALL) -m 0755 -D $(@D)/telnet/telnet $(TARGET_DIR)/usr/local/bin/telnet
endef

define NETKIT_TELNET_UNINSTALL_TARGET_CMDS
	rm -f $(TARGET_DIR)/usr/local/bin/telnet
endef

$(eval $(generic-package))

