# ---- Stage 1: OpenMVS donor ----
FROM openmvs/openmvs-ubuntu:latest AS openmvs

# Export only the OpenMVS tools we need + their NON-glibc deps.
RUN set -eux; \
    mkdir -p /export/bin /export/lib; \
    \
    # Grab required binaries wherever they are installed
    for b in InterfaceCOLMAP DensifyPointCloud ReconstructMesh RefineMesh TextureMesh; do \
      p="$(command -v "$b" 2>/dev/null || true)"; \
      if [ -z "$p" ]; then p="$(find / -type f -name "$b" -perm -111 2>/dev/null | head -n 1 || true)"; fi; \
      echo "[openmvs] $b -> $p"; \
      test -n "$p"; \
      cp "$p" /export/bin/; \
    done; \
    \
    # Copy dependent shared libs BUT EXCLUDE glibc/loader/system core libs
    (for f in /export/bin/*; do \
        ldd "$f" | awk '/=>/ {print $3} /^[[:space:]]*\/.*\.so/ {print $1}'; \
     done) | sort -u | while read -r so; do \
        [ -f "$so" ] || continue; \
        base="$(basename "$so")"; \
        case "$base" in \
          libc.so.6|ld-linux-x86-64.so.2|libm.so.6|libpthread.so.0|libdl.so.2|librt.so.1|libresolv.so.2) \
            echo "[openmvs] skip core lib: $so"; \
            ;; \
          *) \
            cp -L "$so" /export/lib/ || true; \
            ;; \
        esac; \
     done; \
    \
    echo "[openmvs] exported bins:"; ls -la /export/bin; \
    echo "[openmvs] exported libs:"; ls -la /export/lib | head -n 200

# ---- Stage 2: COLMAP donor (CPU-only) ----
FROM graffitytech/colmap:3.8-cpu-ubuntu22.04 AS colmap

# ---- Stage 3: Final runtime ----
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    ca-certificates bash \
    python3-full python3-venv python3-pip \
    locales \
    libceres2 libgoogle-glog0v5 libgflags2.2 \
    libfreeimage3 \
    libopencv-core4.5 libopencv-imgcodecs4.5 libopencv-imgproc4.5 \
    libqt5core5a libqt5gui5 libqt5widgets5 libqt5opengl5 \
    libglew2.2 libglfw3 \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV QT_QPA_PLATFORM=offscreen

# COLMAP
RUN mkdir -p /opt/colmap/bin /opt/colmap/lib
COPY --from=colmap /usr/local/bin/ /opt/colmap/bin/
COPY --from=colmap /usr/local/lib/ /opt/colmap/lib/

# OpenMVS
RUN mkdir -p /opt/openmvs/bin /opt/openmvs/lib
COPY --from=openmvs /export/bin/ /opt/openmvs/bin/
COPY --from=openmvs /export/lib/ /opt/openmvs/lib/

# Put tools on PATH (safe)
ENV PATH="/opt/colmap/bin:/opt/openmvs/bin:${PATH}"

# Register our private libs with the dynamic linker (safe; doesn't break /bin/sh)
RUN echo "/opt/colmap/lib" > /etc/ld.so.conf.d/colmap.conf && \
    echo "/opt/openmvs/lib" > /etc/ld.so.conf.d/openmvs.conf && \
    ldconfig

# Sanity checks: OpenMVS must exist and run
RUN ls -la /opt/openmvs/bin && \
    test -x /opt/openmvs/bin/InterfaceCOLMAP && \
    /opt/openmvs/bin/InterfaceCOLMAP -h | head -n 5

# Python venv
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY worker ./worker
RUN chmod +x worker/pipeline.sh

CMD ["python", "-u", "worker/main.py"]
