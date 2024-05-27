#############################################################
#
# tlinks
#
#############################################################

TLINKS_VERSION = 2.26
TLINKS_SOURCE = links-$(TLINKS_VERSION).tar.bz2
TLINKS_SITE = http://links.twibright.com/download
TLINKS_DEPENDENCIES = host-pkgconf
TLINKS_LICENSE = GPL-2.0+
TLINKS_LICENSE_FILES = COPYING
TLINKS_CPE_ID_VENDOR = twibright

TLINKS_CONF_OPTS += --without-x --without-ssl --without-libevent --disable-graphics --without-directfb

$(eval $(autotools-package))

