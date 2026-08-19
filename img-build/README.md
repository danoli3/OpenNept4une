# Building a flashable OpenNept4une image

This repo does not *contain* the `.img`. These scripts bake one:

1. Compile the Armbian ZNP-K1 base ([Armbian-ZNP-K1-build](https://github.com/OpenNeptune3D/Armbian-ZNP-K1-build))
2. Install Klipper / Moonraker / Fluidd / Mainsail / display_connector without interactive KIAUH
3. Sanitize the image
4. Shrink the `.img` so it fits stock 8 GB eMMC (~7.2 GiB usable)

v0.1.7 uncompressed is **7456 MiB**. That is a full-chip dump and overflows some modules. `shrink` caps the published image at **7000 MiB**. First boot (or Advanced → Resize) grows the filesystem to the device.

All of this needs **Linux**. macOS cannot run `compile.sh`, `losetup`, or the chroot. Use a Linux box or an aarch64 VM with ≥8 GB RAM and ~50 GB disk.

## On-printer bake (most reliable)

Closest to how previous releases were made.

1. Build or download a **base** Armbian ZNP-K1 image (not a finished OpenNept4une release).
2. Flash it, boot, SSH in as `mks` / `makerbase`.
3. Put this checkout on the board (the branch you want in the release):

   ```bash
   git clone -b dev-upgrades https://github.com/OpenNeptune3D/OpenNept4une.git ~/OpenNept4une
   ```

4. Install image contents, then sanitize **without expanding the partition**:

   ```bash
   sudo ~/OpenNept4une/img-config/image-bake-install.sh
   sudo ~/OpenNept4une/img-config/dev-image-cleanup.sh --bake
   sudo poweroff
   ```

5. Move the eMMC to a Linux machine and shrink:

   ```bash
   sudo ./img-build/build.sh shrink /dev/sdX
   ```

   That dumps the device (it never shrinks the eMMC in place), caps the `.img` at 7000 MiB, and writes `.img.xz`.

6. For Plus/Max, set the V2.0 DTB on a copy of the same image:

   ```bash
   sudo ./img-build/build.sh dtb OpenNept4une-….img v20
   ```

After flash, first boot still runs `opennept4une` to pick the printer model and flash MCU firmware. The bake does **not** ship a `printer.cfg`.

## Host bake

On Linux (aarch64 is easiest — no qemu):

```bash
./img-build/build.sh armbian
sudo ./img-build/build.sh nspawn ~/src/Armbian-ZNP-K1-build/output/images/*.img
sudo ./img-build/build.sh shrink ~/opennept4une-img-build/OpenNept4une-customized-*.img
```

`nspawn` is best-effort. If apt or systemd units fail in the chroot, use the on-printer path.

## Commands

| Command | What it does |
|---|---|
| `./img-build/build.sh armbian` | Clone Armbian-ZNP-K1-build and `compile.sh` |
| `sudo ./img-build/build.sh install` | Run the unattended installer on this machine |
| `sudo ./img-build/build.sh nspawn <img>` | Mount a base image and install into it |
| `sudo ./img-build/build.sh shrink <img\|/dev/sdX>` | Dump if needed, shrink, xz |
| `sudo ./img-build/build.sh dtb <img> v1x\|v20` | Default board DTB |

Defaults live in `config.env`. Useful overrides:

```bash
MAX_IMAGE_MIB=7000          # uncompressed cap
SLACK_MIB=384               # free space left in the fs
INSTALL_HEADERS=no          # kernel headers are large
INSTALL_MAINSAIL=1          # 0 to drop Mainsail and save space
FIXED_IMAGE_SIZE=7000       # optional Armbian-side cap
OPENNEPT4UNE_BRANCH=dev     # branch copied/cloned onto the image
```

## Why `--bake` matters

`dev-image-cleanup.sh` used to expand `/dev/mmcblk1p2` and then power off. A `dd` of that eMMC is the whole chip (7456 MiB on the last release). `--bake` / `IMAGE_BAKE=1` skips expand, skips poweroff, and leaves SSH host keys missing so first boot generates unique ones.

Do not expand before the dump. Let the printer grow the filesystem after flash.

## Size check

`shrink` prints uncompressed and xz sizes and whether the `.img` is under the cap. Compare with v0.1.7: 879 MB xz / 7456 MiB raw.

There is no way to know the *new* used size from git. Run `image-bake-install.sh` and read the `du` report at the end, then `shrink`.
