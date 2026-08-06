# Base image for max-bot sandboxes (built by build.sh as
# max-sandbox:latest).  Max.Sandbox.Docker starts containers from
# this image with the shared "max-nix" volume mounted at /nix, so
# every sandbox reuses one store: a package downloaded once by any
# sandbox is instant for all later ones.
#
# NOTE: on the very first `docker run`, docker seeds the empty
# max-nix volume from this image's /nix (nix itself, the base
# toolchain below, the pinned nixpkgs source, the eval cache).  The
# root profile lives *in* that volume, so rebuilding this image with a
# different pin or a different package set changes nothing for
# existing sandboxes: run `docker volume rm max-nix` (with no
# sandboxes alive) to re-seed, or the volume keeps serving the old
# store.
FROM nixos/nix:2.34.8

# The stock image symlinks /etc/{passwd,group,shadow} into
# /nix/store; Docker >= 29 refuses to follow such absolute symlinks
# when resolving the exec user ("path escapes from parent"), which
# breaks every `docker exec`.  Materialise them as regular files.
RUN for f in passwd group shadow; do \
      cp -L /etc/$f /etc/$f.real && mv /etc/$f.real /etc/$f; \
    done

COPY nix.conf /etc/nix/nix.conf

# Pin nixpkgs to the tip of nixos-26.05 *at image build time*:
# `registry pin` resolves the branch to an exact rev, so containers
# never re-fetch a moving branch.  nix 2.34 dropped --registry-path,
# so pin via the user registry and move it into place as the system
# registry (which nix.conf also points flake-registry at).
RUN nix registry add nixpkgs github:NixOS/nixpkgs/nixos-26.05 \
 && nix registry pin nixpkgs \
 && mv /root/.config/nix/registry.json /etc/nix/registry.json

# Base toolchain — roughly Ubuntu's default userland, because that is
# what a model assumes is already on PATH.  The stock nixos/nix image
# ships coreutils, curl, wget, git, tar/gzip, less, man and openssh,
# but no sed, no awk, no diff, no ps, no python3: without these a
# one-liner fails on a missing binary instead of on the actual task,
# burning a round-trip.  jq is also what formats nix_search output.
# Anything past this set still goes through sandbox_exec's `packages`
# (see skills/sandbox.md) — this is a floor, not a toolbox.
#
# One `nix profile install` per package with a descending priority:
# collisions then resolve silently in list order (the stock profile
# sits at the default priority 5 and wins everything), whereas a
# single batch install aborts on the first equal-priority conflict —
# util-linux's `kill` against coreutils', say.
RUN set -eu; p=6; for a in \
      gnused gawk diffutils patch file tree bc \
      xz bzip2 zstd zip unzip \
      procps psmisc lsof util-linux hostname \
      iproute2 iputils dnsutils netcat-gnu socat openssl rsync \
      vim nano \
      python3 perl \
      jq ripgrep gnumake; \
    do \
      nix profile install --priority "$p" "nixpkgs#$a"; \
      p=$((p + 1)); \
    done

# The throwaway search pre-builds the full nixpkgs eval cache into the
# image so the first in-chat search doesn't pay the cold-eval cost
# (~30s + ~2 GiB RAM).
RUN nix search nixpkgs hello > /dev/null

WORKDIR /work
CMD ["sleep", "infinity"]
