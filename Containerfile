FROM docker.io/library/debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        adb bash ca-certificates curl e2fsprogs fastboot python3 usbutils \
    && rm -rf /var/lib/apt/lists/*

# Pin the bootstrap wrapper; it verifies the selected release's installer.
RUN curl -fL --retry 3 -o /usr/local/bin/run-one-shot.sh \
        https://raw.githubusercontent.com/aslater3/LibreEcho/56ee88642510139bcf763f176ed0a18ac78a1170/tools/run-one-shot.sh \
    && chmod +x /usr/local/bin/run-one-shot.sh

ENV HOME=/work/.installer-home
WORKDIR /work
CMD ["bash"]
