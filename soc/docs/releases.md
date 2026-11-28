# Making a release

A release is a GitHub release of a tag, with every board's bitstreams,
their card files and checksums. Machdyne's `fertig` takes Kakao from
these (by the tag), so nothing else needs to be built anywhere.

What goes into one, for each board:

| File | What it is |
|---|---|
| `kakao-linux-<board>.bit` | Kakao Linux (Buildroot) on kakao32: the bitstream |
| `kakao-linux-<board>-card.zip` | Its card files: `sys/linux/` (OpenSBI, the kernel, the root file system, the board's device tree, `boot.json`) and `docs/kakao/` |
| `kakao-plan9-<board>.bit` | Kakao Plan 9 on kakao64, with rio on the monitor (Sergei ML2, Mozart ML2) |
| `kakao-plan9-<board>-card.zip` | Its card files: `sys/plan9/` and `sys/linux/boot64.json` (below) |

and `SUMMARY.md` (each board's speed, seed, and whether it has been run
on a board), `MANIFEST.json` (the same for programs), `THIRD-PARTY.txt`
(the licences, and the offer of the GPL programs' sources) and
`SHA256SUMS`.

The names never change from one release to the next; the tag is the
version. Any tag will do (`v0.1`, `2026.12`, ...).

**One card, both systems.** kboot in a kakao64 bitstream reads
`/sys/linux/boot64.json` before `/sys/linux/boot.json`; kakao32's reads
only `boot.json`. So the Plan 9 card files add a `boot64.json` that
names `/sys/plan9`'s files, and a card holds Kakao Linux and Kakao
Plan 9 side by side: which one starts is which bitstream is loaded.

Kakao Linux (Debian) is left out unless asked for (`-D`): Machdyne
doesn't ship it for now.

There are two ways to make a release. Both give the same files.

## A: GitHub builds it

1. Commit and push everything that should be in the release.
2. Make the tag and push it:
   ```
   git tag -a v0.1 -m "Kakao v0.1"
   git push origin v0.1
   ```
3. Watch it under **Actions → release** on GitHub: first the Plan 9
   kernel, then each board as a job of its own, up to a few hours each;
   when all are done, the last job publishes the release.
4. If a board's job fails or runs out of time (GitHub stops a job after
   six hours), nothing is published. Delete the half-made release if
   there is one, and make this tag the other way (B).

## B: a computer of your own builds it

**Once**, install the tools (Debian or Ubuntu):

```
sudo apt install gcc-riscv64-unknown-elf device-tree-compiler zip cpio python3 git \
    gcc-multilib bubblewrap
sudo apt install gh && gh auth login             # the GitHub CLI, logged in
git submodule update --init --recursive          # soc/ext/zeitlos
```

and Yosys, nextpnr-ecp5 and ecppack: the OSS CAD Suite release GitHub's
build uses (the `OSS_CAD` line in `.github/workflows/release.yml`),
unpacked somewhere and put first in the path:

```
curl -LO https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-10-01/oss-cad-suite-linux-x64-20261001.tgz
tar -C ~/tools -xzf oss-cad-suite-linux-x64-20261001.tgz
export PATH=~/tools/oss-cad-suite/bin:$PATH      # in each shell that builds
```

(The pip packages, `yowasp-yosys` and the like, don't do here: they can
write only below the directory they start in, and the build's logs are
elsewhere.)

**Each release:**

1. Get the commit to release, with nothing uncommitted:
   ```
   git pull
   git submodule update --init --recursive
   git status          # should say "nothing to commit"
   ```
2. Build it. This takes some hours: every board, each tried with up to
   eight seeds until it meets 48 MHz, and the Plan 9 kernel the first
   time (`plan9/`, which fetches its sources).
   ```
   make -C soc/boards release RELEASE="-t v0.1"
   ```
3. Read what it printed at the end, or
   `soc/boards/build/release/SUMMARY.md`: one line per board and system,
   with its speed. If it ends with `not built: ...`, that board's log is
   in the same directory, and it has to be fixed before releasing.
4. Publish it. This makes the tag (if it doesn't exist yet), pushes it,
   and uploads the files:
   ```
   sh soc/tools/gh-release.sh v0.1 --draft     # a draft first, to look at on GitHub
   sh soc/tools/gh-release.sh v0.1             # or straight away
   ```
   A draft is made public with the **Publish release** button on its
   page on GitHub.

To build only some boards (to try a change, say):
`make -C soc/boards release RELEASE="-t test lakritz"`. Don't publish
that one: a release needs every board.

## Which boards have been run

`TESTED` in `soc/boards/Makefile` (now: Sergei ML2). The others are
built and meet timing; `SUMMARY.md` and `MANIFEST.json` say which is
which.
