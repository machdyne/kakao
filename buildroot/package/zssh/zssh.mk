#############################################################
#
# zssh
#
#############################################################

ZSSH_VERSION = 1.5c
ZSSH_SITE = http://prdownloads.sf.net/zssh
ZSSH_SOURCE = zssh-$(ZSSH_VERSION).tgz
ZSSH_CONF_OPTS = --disable-readline --prefix=$(TARGET_DIR)/usr/local --exec-prefix=$(TARGET_DIR)/usr/local
ZSSH_CONF_ENV += CFLAGS="$(TARGET_CFLAGS) -Wno-error=implicit-int"

$(eval $(autotools-package))

