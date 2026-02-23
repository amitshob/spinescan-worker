# =========================
# SpineScan Worker Dockerfile (STABLE + DEBUGGABLE)
# Build COLMAP (CPU) + OpenMVS from source on Ubuntu 22.04
# =========================

# ---------- Stage 1: Build COLMAP + OpenMVS ----------
FROM ubuntu:22.04 AS builder
ARG DEBIAN_FRONTEND=noninteractive

# Use bash so we can reliably capture logs and exit codes
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Core build tools + deps (COLMAP + OpenMVS)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git \
    build-essential cmake ninja-build pkg-config \
    \
    # Python dev (OpenMVS CMake often requires Python3 development headers)
    python3 python3-dev python3.10-dev \
    \
    # COLMAP deps
    libboost-filesystem-dev libboost-graph-dev libboost-program-options-dev libboost-system-dev \
    libeigen3-dev libflann-dev libfreeimage-dev libmetis-dev \
    libgflags-dev libgoogle-glog-dev libsqlite3-dev \
    libglew-dev \
    qtbase5-dev libqt5opengl5-dev \
    libceres-dev \
    \
    # OpenMVS deps
    libopencv-dev \
    libpng-dev libjpeg-dev libtiff-dev \
    libtbb-dev \
    libgl1-mesa-dev libglu1-mesa-dev \
    libcgal-dev libgmp-dev \
    \
    # Common OpenMVS missing deps (frequent CMake failures)
    libvtk9-dev \
    libboost-iostreams-dev libboost-serialization-dev \
    libatlas-base-dev \
    \
    && rm -rf /var/lib/apt/lists/*

# --- Build COLMAP (CPU-only, no GUI, no CUDA) ---
ARG COLMAP_TAG=3.9
RUN git clone --depth 1 --branch ${COLMAP_TAG} https://github.com/colmap/colmap.git /tmp/colmap
RUN cmake -S /tmp/colmap -B /tmp/colmap/build -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/opt/colmap \
    -DGUI_ENABLED=OFF \
    -DCUDA_ENABLED=OFF
RUN cmake --build /tmp/colmap/build --target install -- -j2

# --- Build OpenMVS ---
ARG OPENMVS_TAG=v2.3.0

# IMPORTANT: fetch submodules so build/Utils.cmake exists
RUN git clone --recurse-submodules --branch ${OPENMVS_TAG} https://github.com/cdcseacave/openMVS.git /tmp/openmvs
RUN cd /tmp/openmvs && git submodule update --init --recursive

# Configure OpenMVS; capture output so Render shows the real error
RUN set -eux; \
    rm -rf /tmp/openmvs/build_out; \
    mkdir -p /tmp/openmvs/build_out; \
    ( cmake -S /tmp/openmvs -B /tmp/openmvs/build_out -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/openmvs \
        -DOpenMVS_USE_CUDA=OFF \
        -DOpenMVS_USE_OPENMP=ON \
      2>&1 | tee /tmp/openmvs_configure.log ); \
    ec=${PIPESTATUS[0]}; \
    if [ "$ec" -ne 0 ]; then \
      echo "==== OpenMVS CMake configure FAILED (exit=$ec) ===="; \
      echo "==== /tmp/openmvs_configure.log (last 200 lines) ===="; \
      tail -n 200 /tmp/openmvs_configure.log || true; \
      echo "==== CMakeFiles directory listing ===="; \
      ls -lah /tmp/openmvs/build_out/CMakeFiles || true; \
      echo "==== OpenMVS CMakeError.log ===="; \
      cat /tmp/openmvs/build_out/CMakeFiles/CMakeError.log || true; \
      echo "==== OpenMVS CMakeOutput.log ===="; \
      cat /tmp/openmvs/build_out/CMakeFiles/CMakeOutput.log || true; \
      exit "$ec"; \
    fi

# Build/install OpenMVS (limit parallelism)
RUN cmake --build /tmp/openmvs/build_out --target install -- -j2

# ---------- Stage 2: Runtime ----------
FROM ubuntu:22.04 AS runtime
ARG DEBIAN_FRONTEND=noninteractive

# Runtime deps + Python tooling
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates bash \
    python3 python3-venv python3-pip \
    \
    # COLMAP/OpenMVS runtime libs (broad but safe)
    libboost-filesystem1.74.0 libboost-graph1.74.0 libboost-program-options1.74.0 libboost-system1.74.0 \
    libboost-iostreams1.74.0 libboost-serialization1.74.0 \
    libceres2 libgflags2.2 libgoogle-glog0v5 \
    libfreeimage3 libglew2.2 \
    libsqlite3-0 \
    libopencv-core4.5d libopencv-imgproc4.5d libopencv-imgcodecs4.5d \
    libqt5core5a libqt5gui5 libqt5widgets5 libqt5opengl5 \
    libtbb2 \
    libgl1-mesa-glx libglu1-mesa \
    \
    # OpenMVS sometimes links against VTK at runtime (depending on build)
    libvtk9.1 \
    \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV QT_QPA_PLATFORM=offscreen

# Copy built tools
COPY --from=builder /opt/colmap /opt/colmap
COPY --from=builder /opt/openmvs /opt/openmvs

ENV PATH="/opt/colmap/bin:/opt/openmvs/bin:${PATH}"

RUN echo "/opt/colmap/lib" > /etc/ld.so.conf.d/colmap.conf && \
    echo "/opt/openmvs/lib" > /etc/ld.so.conf.d/openmvs.conf && \
    ldconfig

RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY worker ./worker
RUN chmod +x /app/worker/pipeline.sh

RUN colmap -h >/dev/null 2>&1
RUN InterfaceCOLMAP -h >/dev/null 2>&1

CMD ["python", "-u", "worker/main.py"]
