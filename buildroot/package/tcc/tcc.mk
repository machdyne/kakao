#############################################################
#
# tcc
#
#############################################################

TCC_VERSION = main
TCC_SITE = https://github.com/machdyne/tcc-riscv32.git
TCC_SITE_METHOD = git

define TCC_BUILD_CMDS
	# build tcc for riscv32
	cd $(@D) && ./configure --prefix=$(TARGET_DIR)/usr/local --cpu=riscv32 --cc=$(TARGET_CC) --ar=$(TARGET_AR)
	cd $(@D) && $(MAKE) tcc
	# build tcc cross compiler for riscv32 and build riscv32 library
	cd $(@D) && ./configure --prefix=$(TARGET_DIR)/usr/local --enable-cross --cpu=riscv32
	cd $(@D) && $(MAKE) cross-riscv32
endef

define TCC_INSTALL_TARGET_CMDS
	cd $(@D) && $(MAKE) install
	cp $(@D)/../../host/riscv32-buildroot-linux-gnu/sysroot/usr/lib/*crt* $(TARGET_DIR)/usr/lib
	rm -f $(TARGET_DIR)/usr/local/bin/riscv32-tcc
endef

$(eval $(generic-package))

