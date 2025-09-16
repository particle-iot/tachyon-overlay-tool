tachyon-overlay

A Dockerized toolchain for applying overlay stacks to Linux system images (raw or zipped). It mounts the image, applies overlays in a controlled, repeatable way, and optionally repackages outputs. It is powered by:

 - A Makefile interface (your single entry point)
 - A containerized helper run-overlay.sh that mounts/binds and invokes…
 - A minimal overlay.py engine that reads stacks and overlays and performs actions in a chroot.

This README documents the end‑to‑end workflow, the expected repo structure, how to run it, and how to author overlays/stacks.

⸻

TL;DR (Quick Start)

# 1) Prepare your overlay search paths (each path contains /overlays and /stacks)
# Example layout:
#   overlays_common/
#     overlays/<overlayA>/overlay.json
#     stacks/<some_stack>.json
#   overlays_project/
#     overlays/<overlayB>/overlay.json
#     stacks/<project_stack>.json

# 2) Apply a stack to an image (local or URL). Multiple overlay paths allowed.

make apply \
  INPUT_OVERLAY_PATH="overlays_common overlays_project" \
  INPUT_STACK_NAME=my_stack \
  INPUT_SYSTEM_IMAGE=./images/ubuntu.img.zip \
  OUTPUT_SYSTEM_IMAGE=./out/my_overlayed_bundle.zip \
  DEBUG=false

 - INPUT_SYSTEM_IMAGE can be a .zip. It’s auto‑unzipped in .tmp/.
 - Images that are Android sparse are transparently unsparsed → modified → re-sparsified.
 - Overlays are resolved from your overlay paths in order; the first match wins.
 - DEBUG=chroot drops you into the image’s chroot after overlays are applied.

⸻

Contents
 - What this does
 - Terminology
 - Project layout
 - Make targets
 - Inputs & their behavior
 - How it works (flow)
 - Overlay & Stack format
 - Examples
 - Debugging & troubleshooting
 - Known limitations
 - FAQ

⸻

What this does

 - Accepts one or more overlay search paths (INPUT_OVERLAY_PATH) and a stack name (INPUT_STACK_NAME).
 - Accepts a system image (INPUT_SYSTEM_IMAGE) that is either:
 - a raw image (.img, .bin), possibly an Android sparse image; or
 - a bundle (.zip) containing one (or more) images.
 - Unpacks compressed inputs (zip/xz) into .tmp/.
 - Mounts the image (creates loop devices, mounts rootfs, binds /dev, /proc, /sys, /run, /dev/pts, and mounts EFI if available).
 - Applies your stack via overlay.py:
 - Copy files into/out of the image.
 - Run shell commands/scripts inside the chroot.
 - Install packages.
 - Remove files, etc.
 - Optionally repackages the output:
 - If input was .zip, output can be .zip again.
 - You can also write a raw output image or .xz compressed image.

Everything runs inside a Docker container built from your Dockerfile and only rebuilds if the Dockerfile version changes.

⸻

Terminology
 - Overlay: A set of commands (copy, chroot commands, scripts, etc.) described by an overlay.json.
 - Stack: An ordered list of steps that can reference other stacks or overlays by name.
 - Overlay search paths: Directories you provide that each contain an overlays/ and stacks/ subfolder. Resolution is first match wins by path order.

⸻

Project layout

A typical repo looks like:

tachyon-overlay/
├─ Makefile
├─ Dockerfile
├─ run-overlay.sh
├─ overlay.py
├─ overlays_common/
│  ├─ overlays/
│  │  └─ set-hostname/
│  │     ├─ overlay.json
│  │     └─ scripts/...
│  └─ stacks/
│     └─ base.json
├─ overlays_project/
│  ├─ overlays/
│  │  └─ install-tools/
│  │     └─ overlay.json
│  └─ stacks/
│     └─ my_stack.json
└─ .tmp/                 # ephemeral working area (auto-created)
   ├─ input/
   └─ output/

.tmp/ is recreated as needed. Don’t put anything you care about inside it.

⸻

Make targets

make help           # Show help/usage
make apply          # Apply a stack to an image (main entry point)
make docker         # Build the Docker image if missing (cached)
make docker/shell   # Drop into the builder container shell
make doctor         # Check host prerequisites
make clean          # Remove .tmp/
make version        # Print tool version (from the latest git tag x.y.z)

Docker image caching / rebuild
 - The image tag is derived from a version hint in the Dockerfile (comment key particle-dockerfile-version) or defaults to dev.
 - If the tag already exists locally, the build is skipped.
 - To force a rebuild, bump the version hint or run make docker/rebuild.

⸻

Inputs & their behavior

All inputs are provided as environment variables to make apply.

Variable	Required	Example	Notes
INPUT_OVERLAY_PATH	yes	overlays_common overlays_project or a:b:c	One or more paths; space or : separated. Each path must contain overlays/ and stacks/. Paths are searched left→right.
INPUT_STACK_NAME	yes	my_stack	The stack to apply (resolved within your search paths).
INPUT_SYSTEM_IMAGE	yes	./images/base.img.zip or https://.../image.zip	Local path or HTTP(S) URL. .zip/.xz are unpacked in .tmp/.
OUTPUT_SYSTEM_IMAGE	no	./out/output.zip or ./out/output.img or out.img.xz	Optional. If omitted, the modified image remains in .tmp/input/. If .zip, a bundle is created. If .xz, the image is compressed. Otherwise the image file is moved.
INPUT_RESOURCES_DIR	no	./resources	Copied into .tmp/input/resources. Overlays can reference it via $RESOURCES placeholder.
DEBUG	no	false | true | chroot	true starts a shell before applying overlays. chroot drops you into the image after applying.

Environment variables for overlays: There’s a placeholder support for passing a comma‑separated list via INPUT_ENV_VARS, but these are not automatically exported inside the chroot. See Known limitations.

⸻

How it works (flow)

make apply
  └─► Builds (or reuses) Docker image
      └─► Stages inputs under .tmp/input:
          • Downloads / copies INPUT_SYSTEM_IMAGE
          • Unpacks .zip / .xz
          • Copies INPUT_RESOURCES_DIR → .tmp/input/resources
          • Verifies requested stack exists across your overlay paths
          • (Merges overlay metadata so first match wins)

          Main image is selected (largest *.img|*.bin) as the target.

          └─► run-overlay.sh (inside container)
              • Detects image type:
                - Android sparse → unsparse → mount → apply → resparse
                - Disk image with partitions → loop+mount root (and EFI if present)
                - Plain ext4 file → wraps into GPT temporarily, mounts p1
              • Bind-mounts /dev, /proc, /sys, /run, /dev/pts
              • Calls overlay.py to apply the requested stack
              • Cleans up all mounts & loop devices (trap on EXIT)

If OUTPUT_SYSTEM_IMAGE is provided:
 - .zip → bundles modified image(s) back into a zip under ./out/.
 - .xz → compresses the main image to .xz.
 - else → moves the image file to your target path.

⸻

Overlay & Stack format

Overlay

Each overlay lives under:
<overlay-path>/overlays/<overlay-name>/overlay.json

Required keys:
 - name (string)
 - description (string)
 - commands (array)

Supported command types:
 - local – run a host script (outside chroot).
Keys: script
 - copy-into-chroot – copy file/dir into image.
Keys: source, destination, permissions (required)
 - copy-from-chroot – copy file/dir out of image.
Keys: source, destination
 - chroot-cmd – run a shell command inside chroot.
Keys: cmd, optional ignore-errors (bool)
 - chroot-script – run a script (bundled in the overlay) inside chroot.
Keys: script
 - chroot-rm – remove files inside chroot.
Keys: destination
 - chroot-install-package – apt-get install a package inside chroot.
Keys: package

Resource substitution:

You can reference the resources dir with the literal $RESOURCES token; it is replaced with the absolute path to .tmp/input/resources:

{
  "type": "copy-into-chroot",
  "source": "$RESOURCES/certs/ca.pem",
  "destination": "/usr/local/share/ca-certificates/extra-ca.crt",
  "permissions": "644"
}

Example overlay.json

{
  "name": "set-hostname",
  "description": "Set system hostname and install basics",
  "commands": [
    { "type": "copy-into-chroot",
      "source": "files/hostname",
      "destination": "/etc/hostname",
      "permissions": "644"
    },
    { "type": "chroot-cmd",
      "cmd": "hostnamectl set-hostname $(cat /etc/hostname)"
    },
    { "type": "chroot-install-package", "package": "curl" },
    { "type": "chroot-script", "script": "scripts/post.sh" }
  ]
}

Note: permissions is required for copy-into-chroot and enforced by the engine.

Stack

Each stack lives under:
<overlay-path>/stacks/<stack-name>.json

Required keys:
 - name (string)
 - description (string)
 - steps (array of objects)

Each step has:
 - type: "overlay" or "stack"
 - name: overlay or stack name to include
 - Optional: enabled (bool) — if present and false, the step is skipped.

Example stack:

{
  "name": "my_stack",
  "description": "Base system setup for Tachyon",
  "steps": [
    { "type": "overlay", "name": "set-hostname" },
    { "type": "stack",   "name": "base" }
  ]
}

Multiple overlay paths & precedence

You can provide multiple search paths:

INPUT_OVERLAY_PATH="overlays_common overlays_project"
# or colon-separated: "overlays_common:overlays_project"

Resolution is first match wins:
 - If set-hostname exists in both, the version from overlays_common is used.
 - Duplicate stacks by name are resolved the same way.

⸻

Examples

1) Local image (.zip → apply → .zip)

make apply \
  INPUT_OVERLAY_PATH="overlays_common overlays_project" \
  INPUT_STACK_NAME=my_stack \
  INPUT_SYSTEM_IMAGE=./images/ubuntu-22.04-amd64.img.zip \
  OUTPUT_SYSTEM_IMAGE=./out/ubuntu-22.04-amd64.my_stack.zip \
  DEBUG=false

2) Remote image (URL), chroot after apply

make apply \
  INPUT_OVERLAY_PATH="overlays_common:overlays_project" \
  INPUT_STACK_NAME=my_stack \
  INPUT_SYSTEM_IMAGE="https://example.com/images/base.img.zip" \
  OUTPUT_SYSTEM_IMAGE=./out/base_overlayed.zip \
  DEBUG=chroot

3) Produce a compressed raw image (.xz)

make apply \
  INPUT_OVERLAY_PATH="overlays_common" \
  INPUT_STACK_NAME=init_min \
  INPUT_SYSTEM_IMAGE=./images/qcm6490.img \
  OUTPUT_SYSTEM_IMAGE=./out/qcm6490_overlayed.img.xz \
  DEBUG=false

4) Developer shell inside the container

make docker/shell
# Within the container, you can poke around, or run:
#   bash ./run-overlay.sh -f /tmp/work/input/<main.img> -r /tmp/work/input/resources -s <stack> -d true


⸻

Debugging & troubleshooting
 - See what’s going on
Use DEBUG=true to drop into a container shell with the image mounted before overlays are applied.
Use DEBUG=chroot to drop into a chroot shell inside the image after overlays run.
 - Prereqs
make doctor checks Docker and git availability.
 - Common errors
 - “Overlay path not found” → Double‑check INPUT_OVERLAY_PATH values.
 - “Stack X not found” → Ensure stacks/X.json exists in at least one path.
 - Image download/unzip issues → Confirm URL/file and free space under .tmp/.
 - Mount failures → If a previous run crashed, you may need to unmount:

sudo umount /mnt/tachyon/boot/efi 2>/dev/null || true
sudo umount /mnt/tachyon/dev/pts /mnt/tachyon/run /mnt/tachyon/sys /mnt/tachyon/proc /mnt/tachyon/dev 2>/dev/null || true
sudo umount /mnt/tachyon 2>/dev/null || true
sudo losetup -a   # list loop devices
# Detach stale loop devices if needed:
# sudo losetup -d /dev/loopX


 - Sparse image handling → Android sparse images are auto “unsparsed” (to raw), modified, then re‑sparsified.

 - EFI partition not found
That’s fine; the process continues without /boot/efi if it isn’t present.

⸻

Known limitations
 - Environment variables for overlays
There’s a placeholder CLI arg (INPUT_ENV_VARS → -e) that passes a comma‑separated list into the container run. Currently these are not automatically exported into the chroot.
Workarounds:
 - Put your constants into resource files and copy them in.
 - Add a chroot-cmd step that writes to /etc/environment or creates /etc/profile.d/overlay_env.sh:

{ "type": "chroot-cmd", "cmd": "printf 'FOO=bar\nBAZ=qux\n' >> /etc/environment" }


 - File system variants
This workflow targets ext4 images and Android sparse images. Other filesystems (e.g. squashfs or overlayfs semantics) are not handled here.
 - Overlay engine
overlay.py performs a predictable set of actions. If you need templating, pre‑render templates in a local script and then copy the results into the image.

⸻

FAQ

Q: How are duplicates across multiple overlay paths resolved?
A: The first path wins. Once a given overlay/stack name is found, later matches are ignored.

Q: How do I add a new overlay?
A: Create a directory overlays/<name>/overlay.json under one of your overlay paths and reference it from a stack (or apply it directly if you extend the CLI).

Q: Can I apply multiple stacks at once?
A: Create a meta‑stack that lists the other stacks in steps (type "stack").

Q: How do I force the Docker image to rebuild?
A: Bump the # particle-dockerfile-version = <x.y.z> comment in Dockerfile or run make docker/rebuild.

Q: Will the output always be zipped if the input was zipped?
A: If you set OUTPUT_SYSTEM_IMAGE to end in .zip, yes—it will re‑bundle. Otherwise you can output a raw image (.img) or .xz.

⸻

Reference: command types (overlay.json)

type	What it does	Keys
local	Runs a host script (outside the chroot)	script
copy-into-chroot	Copies files/dirs into chroot	source, destination, permissions
copy-from-chroot	Copies files/dirs out of chroot	source, destination
chroot-cmd	Executes a shell command in chroot	cmd, optional ignore-errors
chroot-script	Copies and executes a script in chroot	script
chroot-rm	Removes paths inside chroot	destination
chroot-install-package	Installs a package in chroot via APT	package

Placeholders
The literal $RESOURCES in source/destination is replaced with the absolute path to .tmp/input/resources.

⸻

CI/CD (example)

# .github/workflows/overlay.yml
name: Apply overlay
on:
  workflow_dispatch:
jobs:
  run:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build & Apply
        run: |
          make apply \
            INPUT_OVERLAY_PATH="overlays_common overlays_project" \
            INPUT_STACK_NAME=my_stack \
            INPUT_SYSTEM_IMAGE=./images/base.img.zip \
            OUTPUT_SYSTEM_IMAGE=./out/output.zip \
            DEBUG=false
      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: overlay-output
          path: out/output.zip


⸻

Safety notes
 - Mounting and modifying images requires root inside the container. The container runs with --privileged and bind‑mounts /dev.
 - Be cautious with overlay commands—they run as root inside the chroot.
 - The tooling traps and attempts to clean up mounts even on failures; if something goes wrong, see the troubleshooting unmount steps.

⸻

License

TBD.

⸻

Contributing
 - Prefer small, reviewable PRs.
 - Keep changes to overlay.py surgical and backward‑compatible.
 - Add a minimal test overlay/stack when introducing a new command or behavior.

⸻

Appendix: ASCII flow diagram

┌───────────────┐
│   Makefile    │
│  make apply   │
└──────┬────────┘
       │
       ▼
┌───────────────┐   Build if needed
│   Docker      │───────────────────────┐
│  (builder)    │                       │
└──────┬────────┘                       │
       │ run-overlay.sh                 │
       ▼                                │
┌───────────────────────────────────────▼──────────────┐
│                  run-overlay.sh (container)          │
│  - Detects image type (sparse/raw/disk/ext)          │
│  - Mounts root and EFI (if present)                  │
│  - Bind-mounts /dev, /proc, /sys, /run, /dev/pts     │
│  - Calls overlay.py apply (stack)                    │
│  - Cleans up mounts & loop devices                   │
└──────────────────────────────────────────────────────┘