# images/soc

What an SD card for the Kakao SOC ([soc/](../../soc/README.md)) holds
beside the files a board's own build makes, prebuilt, so that a card or
a release can be made without building a kernel:

```
rv32/fw_jump.bin   OpenSBI 1.9 for RV32                       Kakao Linux (Buildroot), kakao32
rv32/Image         Linux 6.6.18, buildroot/board/kakao_soc/linux.config
rv64/fw_jump.bin   OpenSBI 1.9 for RV64, with soc/fw/opensbi's patch    Kakao Linux (Debian), kakao64
rv64/Image         Linux 6.6.18, buildroot/board/kakao_soc/linux64.config
rv64/busybox       busybox 1.36.1, static: Debian's fast way to boot
```

These are the files that have been run on the Sergei ML2.
`soc/tools/mkimages.sh` builds them again from source, and its first
lines say from which. The two root file systems are not here:
kakao32's is `../rootfs.cpio`, which `soc/tools/release.sh` changes for
the SOC as it packs, and Debian's it fetches.
