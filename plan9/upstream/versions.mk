# What plan9/ is built from, pinned.  `make fetch` gets the two trees.

# plan9port: rc, mk, awk, sed, yacc and lib9 for the host
P9P_URL    = https://github.com/9fans/plan9port
P9P_COMMIT = 1f1396913fb5372408f442ed26933f5ae4b399cd

# Plan 9 from Bell Labs, Fourth Edition (the Plan 9 Foundation's tree):
# the libraries and commands the 9k distribution is laid over
P9_URL     = https://github.com/plan9foundation/plan9
P9_COMMIT  = ed1a9c21e3297d7497a48053d33683375c75fbb4

# Geoff Collyer's 9k RISC-V distribution, kept here as it was fetched from
# https://9p.io/sources/contrib/geoff/riscv/dist.9k-rv.tgz on 2026-11-24
# ("a snapshot of my current kernel and supporting sources ... things may
# change").  SHA256SUMS has its checksum.
DIST       = upstream/dist.9k-rv.tgz
