FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

# ---- System deps ----
RUN apt-get update && apt-get install -y \
  ca-certificates curl \
  cmake build-essential git \
  coinor-libclp-dev libceres-dev \
  libjpeg-dev libpng-dev libtiff-dev \
  libxi-dev libxinerama-dev libxcursor-dev libxxf86vm-dev \
  libboost-iostreams-dev libboost-program-options-dev libboost-system-dev libboost-serialization-dev \
  libcgal-dev libcgal-qt5-dev \
  freeglut3-dev libglew-dev libglfw3-dev \
  libboost-filesystem-dev libboost-graph-dev libboost-regex-dev libboost-test-dev \
  libeigen3-dev libsuitesparse-dev libfreeimage-dev libgoogle-glog-dev libgflags-dev \
  qtbase5-dev libqt5opengl5-dev \
  libopencv-dev \
  python3 python3-venv python3-pip bash \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# ---- Build COLMAP (CPU) ----
ARG COLMAP_TAG=3.13.0

RUN set -eux; \
  for i in 1 2 3 4 5; do \
    git clone --depth 1 --single-branch --branch "${COLMAP_TAG}" https://github.com/colmap/colmap.git && break; \
    echo "COLMAP clone failed, retrying in 5s..."; sleep 5; \
  done; \
  mkdir colmap_build && cd colmap_build && \
  cmake ../colmap -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="/opt" && \
  make -j2 && make install && \
  cd / && rm -rf colmap_build colmap

# ---- Build OpenMVS (CPU) ----
# Build Eigen 3.2 in a dedicated include prefix (avoid some compatibility issues)
RUN set -eux; \
  for i in 1 2 3 4 5; do \
    git clone --depth 1 --single-branch --branch 3.2 https://gitlab.com/libeigen/eigen && break; \
    echo "Eigen clone failed, retrying in 5s..."; sleep 5; \
  done; \
  mkdir eigen_build && cd eigen_build && \
  cmake -DCMAKE_BUILD_TYPE=RELEASE -DCMAKE_INSTALL_PREFIX="/usr/local/include/eigen32" ../eigen && \
  make -j2 && make install && \
  cd / && rm -rf eigen_build eigen

RUN set -eux; \
  for i in 1 2 3 4 5; do \
    git clone --depth 1 https://github.com/cdcseacave/VCG.git /vcglib && break; \
    echo "VCG clone failed, retrying in 5s..."; sleep 5; \
  done

RUN set -eux; \
  for i in 1 2 3 4 5; do \
    git clone --depth 1 --single-branch --branch develop https://github.com/cdcseacave/openMVS.git && break; \
    echo "OpenMVS clone failed, retrying in 5s..."; sleep 5; \
  done; \
  mkdir openMVS_build && cd openMVS_build && \
  cmake ../openMVS -DCMAKE_BUILD_TYPE=Release \
    -DVCG_ROOT=/vcglib \
    -DEIGEN3_INCLUDE_DIR=/usr/local/include/eigen32/include/eigen3 \
    -DCMAKE_INSTALL_PREFIX="/opt" && \
  make -j2 && make install && \
  cd / && rm -rf openMVS_build openMVS

# ---- PATH for COLMAP + OpenMVS ----
ENV PATH="/opt/bin:/opt/bin/OpenMVS:${PATH}"

# ---- Python venv for worker deps ----
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY worker ./worker
RUN chmod +x worker/pipeline.sh

CMD ["python", "-u", "worker/main.py"]
