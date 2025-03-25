#############################################################
#
# jp2a
#
#############################################################

JP2A_VERSION = main
JP2A_SITE = https://github.com/machdyne/jp2a.git
JP2A_SITE_METHOD = git

JP2A_AUTORECONF = YES
JP2A_DEPENDENCIES = host-pkgconf

#JP2A_CONF_OPTS +=

$(eval $(autotools-package))

