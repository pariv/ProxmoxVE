#!/usr/bin/env bash

# Copyright (c) 2024 chmistry
# License: MIT
# Source: https://github.com/immich-app/immich

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

set -euo pipefail

# === Переменные ===
IMMICH_USER="immich"
IMMICH_DIR="/home/$IMMICH_USER"
UPLOAD_DIR="$IMMICH_DIR/upload"
LOG_DIR="/var/log/immich"
IMMICH_REPO_TAG="v1.132.3"
DB_PASSWORD="$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9')"
REPO_URL="https://github.com/immich-app/immich"
INSTALL_DIR_src="$IMMICH_DIR/source"
INSTALL_DIR_app="$IMMICH_DIR/app"
INSTALL_DIR_ml="$INSTALL_DIR_app/machine-learning"
INSTALL_DIR_geo="$INSTALL_DIR_app/geodata"

# temp
msg_warn() {
  echo "$1"
  }
# === Проверка ОС ===
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
    msg_ok "Обнаружена ОС: $OS $VERSION"
else
    msg_error "Невозможно определить версию ОС"
fi

if [ "$OS" = "ubuntu" ]; then
    if [ "$VERSION" != "24.04" ]; then
        msg_warn "Рекомендуется использовать Ubuntu 24.04, текущая версия: $VERSION"
    fi
elif [ "$OS" = "debian" ]; then
    if [ "$VERSION" != "12" ]; then
        msg_warn "Рекомендуется использовать Debian 12, текущая версия: $VERSION"
    fi
else
    msg_error "Неподдерживаемая ОС: $OS"
fi

# Установка базовых зависимостей
msg_info "Установка базовых зависимостей..."
$STD apt install --no-install-recommends -y \
         automake \
         autoconf \
         build-essential \
         ca-certificates \
         cmake \
         cpanminus \
         curl \
         git \
         jq \
         libbrotli-dev \
         libde265-0 \
         libde265-dev \
         libexif-dev \
         libexif12 \
         libexpat1 \
         libexpat1-dev \
         libgcc-s1 \
         libgdk-pixbuf-2.0-dev \
         libgif-dev \
         libglib2.0-0 \
         libglib2.0-dev \
         libgomp1 \
         libgsf-1-114 \
         libgsf-1-dev \
         libjpeg-dev \
         liblcms2-2 \
         liblqr-1-0 \
         libltdl7 \
         libmimalloc2.0 \
         libopenexr-3-1-30 \
         libopenexr-dev \
         libopenjp2-7 \
         libpng-dev \
         libpython3-dev \
         librsvg2-2 \
         librsvg2-dev \
         libspng-dev \
         libspng0 \
         libtool \
         mesa-utils \
         mesa-va-drivers \
         mesa-vulkan-drivers \
         meson \
         ninja-build \
         ocl-icd-libopencl1 \
         pkg-config \
         python3-dev \
         python3-venv \
         tini \
         unzip \
         wget \
         zlib1g

msg_ok "Базовые зависимости установлены"

# Установка PostgreSQL с pgvector
msg_info "Установка PostgreSQL с расширением pgvecto.rs..."
$STD apt install -y postgresql-common
$STD /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
$STD apt install -y postgresql-17 postgresql-17-pgvector
# $STD deb=$(curl -w "%{filename_effective}" -LO https://github.com/tensorchord/pgvecto.rs/releases/download/v0.4.0/vectors-pg17_0.4.0_amd64.deb) && dpkg -i $deb && rm $deb && unset deb
deb=$(basename https://github.com/tensorchord/pgvecto.rs/releases/download/v0.4.0/vectors-pg17_0.4.0_amd64.deb) && \
$STD curl -LO "https://github.com/tensorchord/pgvecto.rs/releases/download/v0.4.0/$deb" && \
$STD dpkg -i "$deb" && \
$STD rm "$deb" && \
unset deb
msg_ok "PostgreSQL установлен"

# Настройка базы данных
msg_info "Настройка базы данных PostgreSQL..."
$STD sudo -u postgres psql -c 'ALTER SYSTEM SET shared_preload_libraries = "vectors.so"'
$STD sudo -u postgres psql -c 'ALTER SYSTEM SET search_path TO "$user", public, vectors'
$STD sudo -u postgres psql -c "CREATE DATABASE immich;"
$STD sudo -u postgres psql -c "CREATE USER immich WITH ENCRYPTED PASSWORD '$DB_PASSWORD';"
$STD sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE immich to immich;"
$STD sudo -u postgres psql -c "ALTER USER immich WITH SUPERUSER;"
systemctl restart postgresql
msg_ok "База данных настроена"

# Установка Redis
msg_info "Установка Redis..."
$STD apt install -y redis
msg_ok "Redis установлен"

# Установка FFmpeg от Jellyfin с поддержкой аппаратного ускорения
msg_info "Установка FFmpeg с поддержкой аппаратного ускорения..."
if [ "$OS" = "ubuntu" ]; then
    $STD apt install -y curl gnupg software-properties-common
    $STD add-apt-repository universe -y
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor -o /etc/apt/keyrings/jellyfin.gpg
    export VERSION_OS="$( awk -F'=' '/^ID=/{ print $NF }' /etc/os-release )"
    export VERSION_CODENAME="$( awk -F'=' '/^VERSION_CODENAME=/{ print $NF }' /etc/os-release )"
    export DPKG_ARCHITECTURE="$( dpkg --print-architecture )"
    cat <<EOF | tee /etc/apt/sources.list.d/jellyfin.sources > /dev/null
Types: deb
URIs: https://repo.jellyfin.org/${VERSION_OS}
Suites: ${VERSION_CODENAME}
Components: main
Architectures: ${DPKG_ARCHITECTURE}
Signed-By: /etc/apt/keyrings/jellyfin.gpg
EOF
elif [ "$OS" = "debian" ]; then
    $STD apt install -y curl gnupg
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor -o /etc/apt/keyrings/jellyfin.gpg
    export DPKG_ARCHITECTURE="$( dpkg --print-architecture )"
    cat <<EOF | tee /etc/apt/sources.list.d/jellyfin.sources > /dev/null
Types: deb
URIs: https://repo.jellyfin.org/debian
Suites: bookworm
Components: main
Architectures: ${DPKG_ARCHITECTURE}
Signed-By: /etc/apt/keyrings/jellyfin.gpg
EOF
fi

$STD apt update
$STD apt install -y jellyfin-ffmpeg7
$STD ln -sf /usr/lib/jellyfin-ffmpeg/ffmpeg /usr/bin/ffmpeg
$STD ln -sf /usr/lib/jellyfin-ffmpeg/ffprobe /usr/bin/ffprobe
msg_ok "FFmpeg установлен"

# Создание пользователя Immich
msg_info "Создание пользователя Immich..."
$STD adduser --shell /bin/bash --disabled-password $IMMICH_USER --comment "Immich Mich" --gecos ""
$STD mkdir -p $UPLOAD_DIR
$STD chown -R $IMMICH_USER:$IMMICH_USER $IMMICH_DIR
msg_ok "Пользователь Immich создан"

run_with_nvm() {
  $STD su - $IMMICH_USER -c "export NVM_DIR=\"\$HOME/.nvm\" && [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\" && nvm use 22 && $1"
}
# Установка Node.js через nvm для пользователя Immich
msg_info "Установка Node.js для пользователя Immich..."
$STD su - $IMMICH_USER -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash'
$STD su - $IMMICH_USER -c 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && nvm install 22'
msg_ok "Node.js установлен"

# Установка зависимостей для сборки библиотек обработки изображений
msg_info "Установка зависимостей для сборки библиотек обработки изображений..."
if [ "$OS" = "ubuntu" ]; then
    $STD apt NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive install --no-install-recommends -y \
        intel-media-va-driver-non-free \
        libdav1d-dev \
        libhwy-dev \
        libhwy1t64 \
        libio-compress-brotli-perl \
        libwebp-dev \
        libwebp7 \
        libwebpdemux2 \
        libltdl-dev \
        libwebpmux3
elif [ "$OS" = "debian" ]; then
    # Добавление источника testing и приоритета, если их ещё нет
    IMMICH_LIST=/etc/apt/sources.list.d/immich.list
    IMMICH_PREF=/etc/apt/preferences.d/immich
    
    [ -f "$IMMICH_LIST" ] || echo "deb http://deb.debian.org/debian testing main contrib" > "$IMMICH_LIST"
    
    [ -f "$IMMICH_PREF" ] || cat > "$IMMICH_PREF" <<EOF
Package: *
Pin: release a=testing
Pin-Priority: -10
EOF
    
    # Обновление индексов
    $STD apt update
    
    # Установка пакетов из testing
    $STD apt install -t testing --no-install-recommends -y \
        libdav1d-dev \
        libhwy-dev \
        libhwy1t64 \
        libio-compress-brotli-perl \
        libwebp-dev \
        libwebp7 \
        libwebpdemux2 \
        libwebpmux3
fi
msg_ok "Зависимости для сборки установлены"

# === Сборка и установка библиотек (libjxl, libheif, libraw, imagemagick, libvips) ===
msg_info "Сборка библиотек для Immich..."
BASE_IMG_REPO_DIR="/root/base-images" # путь к base-images, скорректируйте если нужно
BASE_IMAGES_COMMIT="db6bbc0c73dba2ca5a31f0d942b35025d5eab9c2"  # фиксированный коммит для стабильности

# Клонируем base-images, если его нет
if [ ! -d "$BASE_IMG_REPO_DIR" ]; then
    $STD git clone https://github.com/immich-app/base-images.git "$BASE_IMG_REPO_DIR"
fi
cd "$BASE_IMG_REPO_DIR"
$STD git fetch --all
$STD git checkout "$BASE_IMAGES_COMMIT"
cd -

SOURCE_DIR="/root/image-source"
$STD mkdir -p "$SOURCE_DIR"

LD_LIBRARY_PATH=/usr/local/lib # :$LD_LIBRARY_PATH
LD_RUN_PATH=/usr/local/lib # :$LD_RUN_PATH
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
$STD locale-gen

function git_clone () {
    # $1 is repo URL
    # $2 is clone target folder
    # $3 is branch name
    if [ ! -d "$2" ]; then
        $STD git clone "$1" "$2"
    fi
    cd $2
    # Get updates
    $STD git fetch
    # REMOVE all the change one made to source repo, which is sth not supposed to happen
    $STD git reset FETCH_HEAD --hard
    # In case one is not on the branch
    $STD git reset --hard "$3"
}
function remove_build_folder () {
    cd $1
    if [ -d "build" ]; then
        rm -r build
    fi
}

SOURCE=$SOURCE_DIR/libjxl

set -e

# Monitor these often
JPEGLI_LIBJPEG_LIBRARY_SOVERSION="62"
JPEGLI_LIBJPEG_LIBRARY_VERSION="62.3.0"

# --- libjxl ---
msg_info "Сборка libjxl..."

LIBJXL_REVISION=$(jq -cr '.revision' $BASE_IMG_REPO_DIR/server/sources/libjxl.json)
set +e

git_clone https://github.com/libjxl/libjxl.git $SOURCE $LIBJXL_REVISION
$STD git submodule update --init --recursive --depth 1 --recommend-shallow

$STD git apply $BASE_IMG_REPO_DIR/server/sources/libjxl-patches/jpegli-empty-dht-marker.patch
$STD git apply $BASE_IMG_REPO_DIR/server/sources/libjxl-patches/jpegli-icc-warning.patch

remove_build_folder $SOURCE

mkdir build
cd build
$STD cmake \
-DCMAKE_BUILD_TYPE=Release \
-DBUILD_TESTING=OFF \
-DJPEGXL_ENABLE_DOXYGEN=OFF \
-DJPEGXL_ENABLE_MANPAGES=OFF \
-DJPEGXL_ENABLE_PLUGIN_GIMP210=OFF \
-DJPEGXL_ENABLE_BENCHMARK=OFF \
-DJPEGXL_ENABLE_EXAMPLES=OFF \
-DJPEGXL_FORCE_SYSTEM_BROTLI=ON \
-DJPEGXL_FORCE_SYSTEM_HWY=ON \
-DJPEGXL_ENABLE_JPEGLI=ON \
-DJPEGXL_ENABLE_JPEGLI_LIBJPEG=ON \
-DJPEGXL_INSTALL_JPEGLI_LIBJPEG=ON \
-DJPEGXL_ENABLE_PLUGINS=ON \
-DJPEGLI_LIBJPEG_LIBRARY_SOVERSION="${JPEGLI_LIBJPEG_LIBRARY_SOVERSION}" \
-DJPEGLI_LIBJPEG_LIBRARY_VERSION="${JPEGLI_LIBJPEG_LIBRARY_VERSION}" \
-DLIBJPEG_TURBO_VERSION_NUMBER=2001005 \
..
# Move the following flag to above if one's system support AVX512
# -DJPEGXL_ENABLE_AVX512=ON \
# -DJPEGXL_ENABLE_AVX512_ZEN4=ON \
$STD echo "Building libjxl using $(nproc) threads"
$STD cmake --build . -- -j"$(nproc)"
$STD cmake --install .

$STD ldconfig /usr/local/lib

# Clean up builds
$STD make clean
remove_build_folder $SOURCE
rm -rf $SOURCE/third_party/
msg_ok "libjxl собран"


# --- libheif ---
msg_info "Сборка libheif..."
#cd $SCRIPT_DIR
SOURCE=$SOURCE_DIR/libheif
LIBHEIF_REVISION=$(jq -cr '.revision' $BASE_IMG_REPO_DIR/server/sources/libheif.json)
git_clone https://github.com/strukturag/libheif.git $SOURCE $LIBHEIF_REVISION
cd $SOURCE
remove_build_folder $SOURCE
mkdir build
cd build
$STD cmake --preset=release-noplugins \
    -DWITH_DAV1D=ON \
    -DENABLE_PARALLEL_TILE_DECODING=ON \
    -DWITH_LIBSHARPYUV=ON \
    -DWITH_LIBDE265=ON \
    -DWITH_AOM_DECODER=OFF \
    -DWITH_AOM_ENCODER=OFF \
    -DWITH_X265=OFF \
    -DWITH_EXAMPLES=OFF \
    ..
$STD make install -j "$(nproc)"
ldconfig /usr/local/lib
# Clean up builds
$STD make clean
remove_build_folder $SOURCE
msg_ok "libheif собран"

# --- libraw ---
msg_info "Сборка libraw..."
#cd $SCRIPT_DIR
SOURCE=$SOURCE_DIR/libraw
LIBRAW_REVISION=$(jq -cr '.revision' $BASE_IMG_REPO_DIR/server/sources/libraw.json)
git_clone https://github.com/libraw/libraw.git $SOURCE $LIBRAW_REVISION

cd $SOURCE

$STD autoreconf --install
$STD ./configure
$STD echo "Building libraw using $(nproc) threads"
$STD make -j"$(nproc)"
$STD make install
ldconfig /usr/local/lib

# Clean up builds
$STD make clean
msg_ok "libraw собран"


# --- imagemagick ---
msg_info "Сборка imagemagick..."
#cd $SCRIPT_DIR
SOURCE=$SOURCE_DIR/image-magick
IMAGEMAGICK_REVISION=$(jq -cr '.revision' $BASE_IMG_REPO_DIR/server/sources/imagemagick.json)
git_clone https://github.com/ImageMagick/ImageMagick.git $SOURCE $IMAGEMAGICK_REVISION
cd $SOURCE

$STD ./configure --with-modules
$STD echo "Building ImageMagick using $(nproc) threads"
$STD make -j"$(nproc)"
$STD make install
ldconfig /usr/local/lib

# Clean up builds
$STD make clean
msg_ok "imagemagick собран"

# --- libvips ---
msg_info "Сборка libvips..."
#cd $SCRIPT_DIR
SOURCE=$SOURCE_DIR/libvips
LIBVIPS_REVISION=$(jq -cr '.revision' $BASE_IMG_REPO_DIR/server/sources/libvips.json)
git_clone https://github.com/libvips/libvips.git $SOURCE $LIBVIPS_REVISION
cd $SOURCE
remove_build_folder $SOURCE

# -Djpeg-xl=disabled is added because previous broken install will break libvips
$STD meson setup build --buildtype=release --libdir=lib -Dintrospection=disabled -Dtiff=disabled -Djpeg-xl=disabled
cd build
$STD ninja install
ldconfig /usr/local/lib

# Clean up builds
remove_build_folder $SOURCE
msg_ok "libvips собран"

msg_ok "Библиотеки собраны"

# === Обработка опции ускорения ML ===
ML_ACCEL="${var_ml_accel:-cpu}"
msg_info "Выбран режим ускорения ML: $ML_ACCEL"

if [[ "$ML_ACCEL" == "cuda" ]]; then
  msg_info "Установка CUDA и cuDNN для поддержки NVIDIA..."
  if [ "$OS" = "ubuntu" ]; then
    $STD wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
    $STD dpkg -i cuda-keyring_1.1-1_all.deb
    $STD apt-get update
    $STD apt-get -y install cudnn-cuda-12 libcublaslt12 libcublas12
  elif [ "$OS" = "debian" ]; then
    $STD wget https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb
    $STD dpkg -i cuda-keyring_1.1-1_all.deb
    $STD add-apt-repository contrib
    $STD apt-get update
    $STD apt-get -y install cudnn cuda-toolkit
  fi
  msg_ok "CUDA и cuDNN установлены"
elif [[ "$ML_ACCEL" == "openvino" ]]; then
  msg_info "Установка зависимостей для Intel OpenVINO..."
  # Пример: можно добавить dep-intel.sh или аналогичную установку
  # $STD ./dep-intel.sh
  msg_ok "OpenVINO: проверьте, что все зависимости установлены вручную (см. README)"
else
  msg_info "Используется только CPU (ускорение ML отключено)"
fi

#msg_info "Создание .env файла для установки Immich..."
#SCRIPT_DIR=$PWD
#cat > $REPO_DIR/.env << EOF
## Installation settings
#REPO_TAG=$IMMICH_REPO_TAG
#INSTALL_DIR=$IMMICH_DIR
#UPLOAD_DIR=$UPLOAD_DIR
#isCUDA=false
#PROXY_NPM=
#PROXY_NPM_DIST=
#PROXY_POETRY=
#EOF
#msg_ok ".env файл создан"
msg_info "Checking dependencies"
cat <<'EOF' > /tmp/check_deps.sh
#!/bin/bash

has_error=0

if ! command -v ffmpeg &> /dev/null; then
    echo "ERROR: ffmpeg is not installed."
    has_error=1
fi

if ! command -v node &> /dev/null; then
    echo "ERROR: Node.js is not installed."
    has_error=1
fi

if ! command -v python3 &> /dev/null; then
    echo "ERROR: Python is not installed."
    has_error=1
fi

if ! command -v git &> /dev/null; then
    echo "ERROR: Git is not installed."
    has_error=1
fi

if [[ "$ML_ACCEL" == "cuda" ]]; then
    if ! nvidia-smi &> /dev/null; then
        echo "ERROR: Nvidia driver is not installed, and ML_ACCEL is set to cuda"
        has_error=1
    fi
fi
exit $has_error

EOF

chmod +x /tmp/check_deps.sh
run_with_nvm '/tmp/check_deps.sh'
rm -f "/tmp/check_deps.sh"
msg_ok "Dependencies checked"

msg_info "building Immich"
rm -rf $INSTALL_DIR_app

su - $IMMICH_USER -c "mkdir -p $INSTALL_DIR_app"
su - $IMMICH_USER -c "mkdir -p $INSTALL_DIR_ml"
su - $IMMICH_USER -c "mkdir -p $INSTALL_DIR_geo"

if [ ! -d "$UPLOAD_DIR" ]; then
    $STD echo "$UPLOAD_DIR does not exists, creating one"
    su - $IMMICH_USER -c "mkdir -p $UPLOAD_DIR"
else
    $STD echo "$UPLOAD_DIR already exists, skip creation"
fi

# Клонирование основного репозитория Immich
msg_info "Клонирование репозитория Immich..."
#$STD su - $IMMICH_USER -c "git clone $REPO_URL $INSTALL_DIR_src --single-branch"
#$STD su - $IMMICH_USER -c "cd $INSTALL_DIR_src && git checkout $IMMICH_REPO_TAG"

if [ ! -d "$INSTALL_DIR_src" ]; then
    $STD su - $IMMICH_USER -c "git clone $REPO_URL $INSTALL_DIR_src --single-branch"
else
    $STD su - $IMMICH_USER -c "cd $INSTALL_DIR_src && git reset --hard main && git checkout main && git pull"  
fi
# Set the install version
$STD su - $IMMICH_USER -c "cd $INSTALL_DIR_src && git checkout $IMMICH_REPO_TAG"

msg_ok "Репозиторий Immich клонирован"

msg_info "installing web server"
cat <<'EOF' > /tmp/install_webservice.sh
    cd $INSTALL_DIR_src

    # Set mirror for npm
    if [ ! -z "${PROXY_NPM}" ]; then
        npm config set registry=$PROXY_NPM
    fi
    # Set mirror for npm dist
    if [ ! -z "${PROXY_NPM_DIST}" ]; then
        export npm_config_dist_url=$PROXY_NPM_DIST
    fi

    # This solves fallback-to-build issue with bcrypt and utimes
    npm install -g node-gyp node-pre-gyp
    # Solve audit stuck by skipping it, [Additional info](https://overreacted.io/npm-audit-broken-by-design/)
    # npm config set audit false

    # Add --build-from-source in npm ci is the solution if node-pre-gyp stuck at GET http https://github.com.....
    cd server
    npm ci # --cpu x64 --os linux
    npm run build
    npm prune --omit=dev --omit=optional
    cd ..

    cd open-api/typescript-sdk
    npm ci # --cpu x64 --os linux
    npm run build
    cd ../..

    cd web
    npm ci # --cpu x64 --os linux
    npm run build
    cd ..

    # Unset mirror for npm
    if [ ! -z "${PROXY_NPM}" ]; then
        npm config delete registry
    fi

    cp -a server/node_modules server/dist server/bin $INSTALL_DIR_app/
    cp -a web/build $INSTALL_DIR_app/www
    cp -a server/resources server/package.json server/package-lock.json $INSTALL_DIR_app/
    cp -a server/start*.sh $INSTALL_DIR_app/
    cp -a LICENSE $INSTALL_DIR_app/
    cd ..
EOF
chmod +x /tmp/install_webservice.sh
run_with_nvm "INSTALL_DIR_src='$INSTALL_DIR_src' INSTALL_DIR_app='$INSTALL_DIR_app' /tmp/install_webservice.sh"
rm -f "/tmp/install_webservice.sh"
msg_ok "installed web server"

msg_info "Installing ML service"

cat <<'EOF' > /tmp/install_ml.sh
    cd $INSTALL_DIR_src/machine-learning
    python3 -m venv $INSTALL_DIR_ml/venv
    (
    # Initiate subshell to setup venv
    . $INSTALL_DIR_ml/venv/bin/activate

    # Use pypi if proxy does not present
    if [ -z "${PROXY_POETRY}" ]; then
        PROXY_POETRY=https://pypi.org/simple/
    fi
    export POETRY_PYPI_MIRROR_URL=$PROXY_POETRY
    pip3 install poetry -i $PROXY_POETRY

    # Deal with python 3.12
    python3_version=$(python3 --version 2>&1 | awk -F' ' '{print $2}' | awk -F'.' '{print $2}')
    if [ $python3_version = 12 ]; then
        # Allow Python 3.12 (e.g., Ubuntu 24.04)
        sed -i -e 's/<3.12/<4/g' pyproject.toml
        poetry update
    fi

    poetry_args='--no-root --extras'

    # Install CUDA parts only when necessary
    if [ $ML_ACCEL = "cuda" ]; then
        poetry install $poetry_args cuda
    elif [ $ML_ACCEL = "openvino" ]; then
        poetry install $poetry_args openvino
    else
        poetry install $poetry_args cpu
    fi

    # Work around for bad poetry config
    pip install "numpy<2" -i $PROXY_POETRY
    )

    # Copy results
    cd $INSTALL_DIR_src
    cp -a machine-learning/ann machine-learning/immich_ml $INSTALL_DIR_ml/
EOF
chmod +x /tmp/install_ml.sh
$STD su - $IMMICH_USER -c "INSTALL_DIR_src='$INSTALL_DIR_src' INSTALL_DIR_ml='$INSTALL_DIR_ml' ML_ACCEL='$ML_ACCEL' /tmp/install_ml.sh"
rm -f "/tmp/install_ml.sh"
msg_ok "installed ML service"

msg_info "Setting paths"
cd $INSTALL_DIR_app
$STD su - $IMMICH_USER -c "INSTALL_DIR='$IMMICH_DIR'; INSTALL_DIR_ml='$INSTALL_DIR_ml'; cd \"$INSTALL_DIR_app\" && grep -Rl /usr/src | xargs -n1 sed -i -e \"s@/usr/src@\$INSTALL_DIR@g\" && sed -i -e \"s@\\\"/cache\\\"@\\\"\$INSTALL_DIR/cache\\\"@g\" \"\$INSTALL_DIR_ml/immich_ml/config.py\""
# $STD su - $IMMICH_USER -c "grep -Rl /usr/src | xargs -n1 sed -i -e \"s@/usr/src@$IMMICH_DIR@g\""
$STD su - $IMMICH_USER -c "ln -sf $INSTALL_DIR_app/resources $IMMICH_DIR/"
$STD su - $IMMICH_USER -c "mkdir -p $IMMICH_DIR/cache"
# $STD su - $IMMICH_USER -c "sed -i -e 's@\"/cache\"@\"'"$IMMICH_DIR"'/cache\"@g' $INSTALL_DIR_ml/immich_ml/config.py"
$STD su - $IMMICH_USER -c "INSTALL_DIR_app='$INSTALL_DIR_app'; cd \"\$INSTALL_DIR_app\" && grep -RlE '\"/build\"|'\''/build'\'''"' | xargs -n1 sed -i -e "s@\"/build\"@\"$INSTALL_DIR_app\"@g" -e "s@'\''/build'\''@'\''$INSTALL_DIR_app'\''@g"'
msg_ok "Set paths"

msg_info "Installing sharp and CLI"
run_with_nvm "cd $INSTALL_DIR_app && npm install --build-from-source sharp"
$STD su - $IMMICH_USER -c "rm -rf $INSTALL_DIR_app/node_modules/@img/sharp-libvips*"
$STD su - $IMMICH_USER -c "rm -rf $INSTALL_DIR_app/node_modules/@img/sharp-linuxmusl-x64"
run_with_nvm "cd $INSTALL_DIR_app && npm i -g @immich/cli"
msg_ok "Installed sharp and CLI"

msg_info "Linking upload dir"
$STD su - $IMMICH_USER -c "ln -s $UPLOAD_DIR $INSTALL_DIR_app/upload"
$STD su - $IMMICH_USER -c "ln -s $UPLOAD_DIR $INSTALL_DIR_ml/upload"
msg_ok "Linked upload dir"


msg_info "Downloading GEO names"
$STD su - $IMMICH_USER -c "cd $INSTALL_DIR_geo && wget -q https://download.geonames.org/export/dump/admin1CodesASCII.txt && wget -q https://download.geonames.org/export/dump/admin2Codes.txt && wget -q https://download.geonames.org/export/dump/cities500.zip && wget -q https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_10m_admin_0_countries.geojson && unzip -o cities500.zip && rm cities500.zip && date --iso-8601=seconds | tr -d "\n" > geodata-date.txt && ln -s $INSTALL_DIR_geo $INSTALL_DIR_app/geodata"
msg_ok "Downloaded GEO names"

msg_info "Creating startup scripts"

cat <<EOF > "$INSTALL_DIR_app/start.sh"
#!/bin/bash

export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"

set -a
. $IMMICH_DIR/runtime.env
set +a

cd "$INSTALL_DIR_app"
exec node "$INSTALL_DIR_app/dist/main" "\$@"
EOF
$STD chown -R $IMMICH_USER:$IMMICH_USER $INSTALL_DIR_app/start.sh
chmod +x "$INSTALL_DIR_app/start.sh"

pkg_name=immich_ml
cat <<EOF > $INSTALL_DIR_ml/start.sh
#!/bin/bash

set -a
. $IMMICH_DIR/runtime.env
set +a

cd $INSTALL_DIR_ml
. venv/bin/activate

: "\${MACHINE_LEARNING_HOST:=127.0.0.1}"
: "\${MACHINE_LEARNING_PORT:=3003}"
: "\${MACHINE_LEARNING_WORKERS:=1}"
: "\${MACHINE_LEARNING_WORKER_TIMEOUT:=120}"

exec gunicorn $pkg_name.main:app \
        -k $pkg_name.config.CustomUvicornWorker \
        -w "\$MACHINE_LEARNING_WORKERS" \
        -b "\$MACHINE_LEARNING_HOST":"\$MACHINE_LEARNING_PORT" \
        -t "\$MACHINE_LEARNING_WORKER_TIMEOUT" \
        --log-config-json log_conf.json \
        --graceful-timeout 0
EOF
chown -R $IMMICH_USER:$IMMICH_USER $INSTALL_DIR_ml/start.sh
chmod +x "$INSTALL_DIR_ml/start.sh"

cat <<EOF > $IMMICH_DIR/runtime.env 
# https://immich.app/docs/install/environment-variables/

# Immich
TZ=America/New_York
IMMICH_VERSION=release
IMMICH_ENV=production

# Postgresql
DB_HOSTNAME=localhost
DB_USERNAME=$IMMICH_USER
DB_PASSWORD=$DB_PASSWORD
DB_DATABASE_NAME=immich
DB_VECTOR_EXTENSION=pgvector

# Redis
REDIS_HOSTNAME=localhost

# Machine learning
MACHINE_LEARNING_CACHE_FOLDER=$IMMICH_DIR/ml-models
EOF
chown -R $IMMICH_USER:$IMMICH_USER $IMMICH_DIR/runtime.env 

msg_ok "Created startup scripts"

msg_info "Creating systemd services"

cat << EOF > /etc/systemd/system/immich-web.service
[Unit]
Description=immich web server
Documentation=https://github.com/immich-app/immich
Requires=redis-server.service
Requires=postgresql.service
Requires=immich-ml.service

[Service]
User=$IMMICH_USER
Group=$IMMICH_USER
Type=simple
Restart=on-failure
UMask=0077

ExecStart=/bin/bash $INSTALL_DIR_app/start.sh

SyslogIdentifier=immich-web
StandardOutput=append:$LOG_DIR/web.log
StandardError=append:$LOG_DIR/web.log

[Install]
WantedBy=multi-user.target
EOF

cat << EOF > /etc/systemd/system/immich-ml.service
[Unit]
Description=immich machine-learning
Documentation=https://github.com/immich-app/immich

[Service]
User=$IMMICH_USER
Group=$IMMICH_USER
Type=simple
Restart=on-failure
UMask=0077

WorkingDirectory=$INSTALL_DIR_app
EnvironmentFile=$IMMICH_DIR/runtime.env
ExecStart=$INSTALL_DIR_ml/start.sh

SyslogIdentifier=immich-machine-learning
StandardOutput=append:$LOG_DIR/ml.log
StandardError=append:$LOG_DIR/ml.log

[Install]
WantedBy=multi-user.target
EOF

mkdir -p $LOG_DIR
$STD chown -R $IMMICH_USER:$IMMICH_USER $LOG_DIR

msg_ok "Services created"

msg_info "Starting services"
$STD systemctl daemon-reload
$STD systemctl enable --now immich-web.service
$STD systemctl enable --now immich-ml.service
msg_ok "Services started"

motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean

# Удаляем исходники библиотек
$STD rm -rf /root/image-source
# Удаляем base-images
$STD rm -rf /root/base-images
# (Опционально) Удаляем исходники Immich, если не нужны для обновлений
# $STD rm -rf $INSTALL_DIR_src

msg_ok "Cleaned" 

IP_ADDRESS=$(hostname -I | awk '{print $1}')

echo -e "\n=========================================${CL}"
echo -e "Установка Immich успешно завершена!${CL}"
echo -e "=========================================${CL}\n"

echo -e "Веб-интерфейс: ${BL}http://$IP_ADDRESS:2283${CL}"
echo -e "Пароль для базы данных: ${YW}$DB_PASSWORD${CL}"
echo -e "Файлы журналов: ${BL}$LOG_DIR${CL}"
echo -e "\n${YW}ВАЖНО: После первого входа в веб-интерфейс Immich${CL}"
echo -e "${YW}необходимо изменить URL для машинного обучения:${CL}"
echo -e "Зайдите в: Administration > Settings > Machine Learning Settings"
echo -e "Установите URL: ${BL}http://localhost:3003${CL}"
echo -e "\nДля проверки аппаратного ускорения транскодирования:"
echo -e "Зайдите в: Administration > Settings > Video Transcoding Settings"
echo -e "Выберите ваш метод аппаратного ускорения (NVENC, QuickSync и т.д.)"




