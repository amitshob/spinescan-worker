FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

# ---- System deps ----
RUN apt-get update && apt-get install -y \
  ca-certificates curl \
  cmake build-essential \
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
  tar gzip xz-utils \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# ---- Versions ----
ARG COLMAP_TAG=3.13.0
ARG OPENMVS_BRANCH=develop
ARG VCG_BRANCH=master
ARG EIGEN_TAG=3.2



# --- Download COLMAP source tarball (more reliable endpoint) ---
RUN set -eux; \
  mkdir -p /tmp/src && cd /tmp/src; \
  curl -fL \
    --retry 10 --retry-delay 5 --retry-all-errors \
    --connect-timeout 30 --max-time 600 \
    -H "User-Agent: render-build" \
    "https://codeload.github.com/colmap/colmap/tar.gz/refs/tags/${COLMAP_TAG}" \
    -o colmap.tar.gz; \
  ls -lh colmap.tar.gz; \
  tar -xzf colmap.tar.gz; \
  mv "colmap-${COLMAP_TAG}" colmap

# --- Build COLMAP ---
RUN set -eux; \
  mkdir -p /tmp/build/colmap && cd /tmp/build/colmap; \
  cmake /tmp/src/colmap -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="/opt"; \
  make -j2; \
  make install; \
  rm -rf /tmp/build/colmap


# ---- Build Eigen 3.2 into a dedicated include prefix ----
RUN set -eux; \
  mkdir -p /tmp/src && cd /tmp/src; \
  curl -fL --retry 5 --retry-delay 5 \
    "https://gitlab.com/libeigen/eigen/-/archive/${EIGEN_TAG}/eigen-${EIGEN_TAG}.tar.gz" \
    -o eigen.tar.gz; \
  tar -xzf eigen.tar.gz; \
  mv "eigen-${EIGEN_TAG}" eigen; \
  mkdir -p /tmp/build/eigen && cd /tmp/build/eigen; \
  cmake /tmp/src/eigen -DCMAKE_BUILD_TYPE=RELEASE -DCMAKE_INSTALL_PREFIX="/usr/local/include/eigen32"; \
  make -j2; \
  make install; \
  rm -rf /tmp/src/eigen /tmp/src/eigen.tar.gz /tmp/build/eigen

# ---- Fetch VCG library ----
RUN set -eux; \
  mkdir -p /vcglib; \
  cd /tmp; \
  curl -fL --retry 5 --retry-delay 5 \
    "https://github.com/cdcseacave/VCG/archive/refs/heads/${VCG_BRANCH}.tar.gz" \
    -o vcg.tar.gz; \
  tar -xzf vcg.tar.gz; \
  mv "VCG-${VCG_BRANCH}"/* /vcglib/; \
  rm -rf /tmp/vcg.tar.gz "/tmp/VCG-${VCG_BRANCH}"

# ---- Build OpenMVS ----
RUN set -eux; \
  mkdir -p /tmp/src && cd /tmp/src; \
  curl -fL --retry 5 --retry-delay 5 \
    "https://github.com/cdcseacave/openMVS/archive/refs/heads/${OPENMVS_BRANCH}.tar.gz" \
    -o openmvs.tar.gz; \
  tar -xzf openmvs.tar.gz; \
  mv "openMVS-${OPENMVS_BRANCH}" openmvs; \
  mkdir -p /tmp/build/openmvs && cd /tmp/build/openmvs; \
  cmake /tmp/src/openmvs -DCMAKE_BUILD_TYPE=Release \
    -DVCG_ROOT=/vcglib \
    -DEIGEN3_INCLUDE_DIR=/usr/local/include/eigen32/include/eigen3 \
    -DCMAKE_INSTALL_PREFIX="/opt"; \
  make -j2; \
  make install; \
  rm -rf /tmp/src/openmvs /tmp/src/openmvs.tar.gz /tmp/build/openmvs

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
