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

# === Проверка ОС ===
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
    msg_info "Обнаружена ОС: $OS $VERSION"
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

# === Установка системных зависимостей ===
msg_info "Установка базовых зависимостей..."
$STD apt install -y curl git python3-venv python3-dev build-essential unzip postgresql-common gnupg software-properties-common jq cmake autoconf pkg-config meson ninja-build libbrotli-dev libde265-dev libexif-dev libexpat1-dev libglib2.0-dev libgsf-1-dev libjpeg-turbo libjpeg-dev liblcms2-2 librsvg2-dev libspng-dev zlib1g cpanminus wget libdav1d-dev libhwy-dev libwebp-dev libio-compress-brotli-perl libtool automake libtool-bin libssl-dev libpng-dev libtiff-dev libxml2-dev liborc-0.4-0 liborc-0.4-dev
msg_ok "Базовые зависимости установлены"

# === Установка PostgreSQL с pgvector ===
msg_info "Установка PostgreSQL с расширением pgvecto.rs..."
$STD /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
$STD apt install -y postgresql-17 postgresql-17-pgvector

deb=$(basename https://github.com/tensorchord/pgvecto.rs/releases/download/v0.4.0/vectors-pg17_0.4.0_amd64.deb) && \
$STD curl -LO "https://github.com/tensorchord/pgvecto.rs/releases/download/v0.4.0/$deb" && \
$STD dpkg -i "$deb" && \
$STD rm "$deb" && \
unset deb
msg_ok "PostgreSQL установлен"

# === Настройка базы данных ===
msg_info "Настройка базы данных PostgreSQL..."
$STD sudo -u postgres psql -c 'ALTER SYSTEM SET shared_preload_libraries = "vectors.so"'
$STD sudo -u postgres psql -c 'ALTER SYSTEM SET search_path TO "$user", public, vectors'
$STD sudo -u postgres psql -c "CREATE DATABASE immich;"
$STD sudo -u postgres psql -c "CREATE USER immich WITH ENCRYPTED PASSWORD '$DB_PASSWORD';"
$STD sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE immich to immich;"
$STD sudo -u postgres psql -c "ALTER USER immich WITH SUPERUSER;"
systemctl restart postgresql
msg_ok "База данных настроена"

# === Установка Redis ===
msg_info "Установка Redis..."
$STD apt install -y redis
msg_ok "Redis установлен"

# === Установка FFmpeg от Jellyfin ===
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

# === Создание пользователя Immich ===
msg_info "Создание пользователя Immich..."
$STD adduser --shell /bin/bash --disabled-password $IMMICH_USER --comment "Immich Mich" --gecos ""
$STD mkdir -p $UPLOAD_DIR
$STD chown -R $IMMICH_USER:$IMMICH_USER $IMMICH_DIR
msg_ok "Пользователь Immich создан"

# === Установка Node.js через nvm для пользователя Immich ===
msg_info "Установка Node.js для пользователя Immich..."
$STD su - $IMMICH_USER -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash'
$STD su - $IMMICH_USER -c 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && nvm install 22'
msg_ok "Node.js установлен"

# === Клонирование основного репозитория Immich ===
msg_info "Клонирование репозитория Immich..."
$STD su - $IMMICH_USER -c "git clone $REPO_URL $INSTALL_DIR_src --single-branch"
$STD su - $IMMICH_USER -c "cd $INSTALL_DIR_src && git checkout $IMMICH_REPO_TAG"
msg_ok "Репозиторий Immich клонирован"

# === Сборка и установка библиотек (libjxl, libheif, libraw, imagemagick, libvips) ===
msg_info "Сборка библиотек для Immich..."
BASE_IMG_REPO_DIR="/root/base-images" # путь к base-images, скорректируйте если нужно
BASE_IMAGES_COMMIT="db6bbc0c73dba2ca5a31f0d942b35025d5eab9c2"  # фиксированный коммит для стабильности

# Клонируем base-images, если его нет
if [ ! -d "$BASE_IMG_REPO_DIR" ]; then
    git clone https://github.com/immich-app/base-images.git "$BASE_IMG_REPO_DIR"
fi
cd "$BASE_IMG_REPO_DIR"
git fetch --all
git checkout "$BASE_IMAGES_COMMIT"
cd -

SOURCE_DIR="/root/image-source"
$STD mkdir -p "$SOURCE_DIR"

# --- libheif ---
LIBHEIF_REVISION=$(jq -cr '.revision' $BASE_IMG_REPO_DIR/server/sources/libheif.json)
$STD git clone https://github.com/strukturag/libheif.git $SOURCE_DIR/libheif
cd $SOURCE_DIR/libheif
$STD git reset --hard "$LIBHEIF_REVISION"

# Определяем версию libjpeg-turbo и преобразуем в формат XYYZZZZ
# if dpkg -s libjpeg-turbo8-dev >/dev/null 2>&1; then
#     LIBJPEG_TURBO_VERSION=$(dpkg-query -W -f='${Version}' libjpeg-turbo8-dev | grep -oE '^[0-9]+\\.[0-9]+\\.[0-9]+')
#     if [ -z "$LIBJPEG_TURBO_VERSION" ]; then
#         echo "Не удалось определить версию libjpeg-turbo8-dev!" >&2
#         exit 1
#     fi
# else
#     echo "Пакет libjpeg-turbo8-dev не установлен!" >&2
#     exit 1
# fi
# IFS='.' read -r MAJOR MINOR PATCH <<< "$LIBJPEG_TURBO_VERSION"
# LIBJPEG_TURBO_VERSION_NUMBER=$((10#$MAJOR * 1000000 + 10#$MINOR * 10000 + 10#$PATCH))

$STD rm -rf build && $STD mkdir build && cd build
$STD cmake --preset=release-noplugins -DWITH_DAV1D=ON -DENABLE_PARALLEL_TILE_DECODING=ON -DWITH_LIBSHARPYUV=ON -DWITH_LIBDE265=ON -DWITH_AOM_DECODER=OFF -DWITH_AOM_ENCODER=OFF -DWITH_X265=OFF -DWITH_EXAMPLES=OFF ..
# $STD cmake --preset=release-noplugins -DWITH_DAV1D=ON -DENABLE_PARALLEL_TILE_DECODING=ON -DWITH_LIBSHARPYUV=ON -DWITH_LIBDE265=ON -DWITH_AOM_DECODER=OFF -DWITH_AOM_ENCODER=OFF -DWITH_X265=OFF -DWITH_EXAMPLES=OFF -DCMAKE_CXX_FLAGS="-DLIBJPEG_TURBO_VERSION_NUMBER=$LIBJPEG_TURBO_VERSION_NUMBER" ..
$STD make install -j "$(nproc)"
$STD ldconfig /usr/local/lib


# --- libjxl ---
LIBJXL_REVISION=$(jq -cr '.revision' $BASE_IMG_REPO_DIR/server/sources/libjxl.json)
$STD git clone https://github.com/libjxl/libjxl.git $SOURCE_DIR/libjxl
cd $SOURCE_DIR/libjxl
$STD git reset --hard "$LIBJXL_REVISION"
$STD git submodule update --init --recursive --depth 1 --recommend-shallow
$STD git apply $BASE_IMG_REPO_DIR/server/sources/libjxl-patches/jpegli-empty-dht-marker.patch
$STD git apply $BASE_IMG_REPO_DIR/server/sources/libjxl-patches/jpegli-icc-warning.patch
$STD rm -rf build && $STD mkdir build && cd build
$STD cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_PLUGIN_GIMP210=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_FORCE_SYSTEM_HWY=ON -DJPEGXL_ENABLE_JPEGLI=ON -DJPEGXL_ENABLE_JPEGLI_LIBJPEG=ON -DJPEGXL_INSTALL_JPEGLI_LIBJPEG=ON -DJPEGXL_ENABLE_PLUGINS=ON ..
$STD cmake --build . -- -j"$(nproc)"
$STD cmake --install .
$STD ldconfig /usr/local/lib

# --- libraw ---
LIBRAW_REVISION=$(jq -cr '.revision' $BASE_IMG_REPO_DIR/server/sources/libraw.json)
$STD git clone https://github.com/libraw/libraw.git $SOURCE_DIR/libraw
cd $SOURCE_DIR/libraw
$STD git reset --hard "$LIBRAW_REVISION"
$STD autoreconf --install
$STD ./configure
$STD make -j"$(nproc)"
$STD make install
$STD ldconfig /usr/local/lib

# --- imagemagick ---
IMAGEMAGICK_REVISION=$(jq -cr '.revision' $BASE_IMG_REPO_DIR/server/sources/imagemagick.json)
$STD git clone https://github.com/ImageMagick/ImageMagick.git $SOURCE_DIR/imagemagick
cd $SOURCE_DIR/imagemagick
$STD git reset --hard "$IMAGEMAGICK_REVISION"
$STD ./configure --with-modules
$STD make -j"$(nproc)"
$STD make install
$STD ldconfig /usr/local/lib

# --- libvips ---
LIBVIPS_REVISION=$(jq -cr '.revision' $BASE_IMG_REPO_DIR/server/sources/libvips.json)
$STD git clone https://github.com/libvips/libvips.git $SOURCE_DIR/libvips
cd $SOURCE_DIR/libvips
$STD git reset --hard "$LIBVIPS_REVISION"
$STD meson setup build --buildtype=release --libdir=lib -Dintrospection=disabled -Dtiff=disabled -Djpeg-xl=disabled
cd build
$STD ninja install
$STD ldconfig /usr/local/lib

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

# === Установка Immich (npm, ML, geodata, poetry и т.д.) ===
msg_info "Установка Immich и зависимостей..."
cd $INSTALL_DIR_src

# npm (web, server, sdk)
$STD su - $IMMICH_USER -c "cd $INSTALL_DIR_src/server && npm ci && npm run build && npm prune --omit=dev --omit=optional"
$STD su - $IMMICH_USER -c "cd $INSTALL_DIR_src/open-api/typescript-sdk && npm ci && npm run build"
$STD su - $IMMICH_USER -c "cd $INSTALL_DIR_src/web && npm ci && npm run build"

# Копирование артефактов
$STD cp -a $INSTALL_DIR_src/server/node_modules $INSTALL_DIR_src/server/dist $INSTALL_DIR_src/server/bin $INSTALL_DIR_app/
$STD cp -a $INSTALL_DIR_src/web/build $INSTALL_DIR_app/www
$STD cp -a $INSTALL_DIR_src/server/resources $INSTALL_DIR_src/server/package.json $INSTALL_DIR_src/server/package-lock.json $INSTALL_DIR_app/
$STD cp -a $INSTALL_DIR_src/server/start*.sh $INSTALL_DIR_app/
$STD cp -a $INSTALL_DIR_src/LICENSE $INSTALL_DIR_app/

# Python ML
cd $INSTALL_DIR_src/machine-learning
$STD python3 -m venv $INSTALL_DIR_ml/venv
. $INSTALL_DIR_ml/venv/bin/activate
$STD pip3 install poetry
if [[ "$ML_ACCEL" == "cuda" ]]; then
  $STD poetry install --no-root --with dev --with cuda
elif [[ "$ML_ACCEL" == "openvino" ]]; then
  $STD poetry install --no-root --with dev --with openvino
else
  $STD poetry install --no-root --with dev --with cpu
fi
$STD pip install "numpy<2"

# Копирование ML
$STD cp -a $INSTALL_DIR_src/machine-learning/ann $INSTALL_DIR_src/machine-learning/start.sh $INSTALL_DIR_src/machine-learning/app $INSTALL_DIR_ml/

# Geodata
$STD mkdir -p $INSTALL_DIR_geo
cd $INSTALL_DIR_geo
$STD wget -q https://download.geonames.org/export/dump/admin1CodesASCII.txt
$STD wget -q https://download.geonames.org/export/dump/admin2Codes.txt
$STD wget -q https://download.geonames.org/export/dump/cities500.zip
$STD wget -q https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_10m_admin_0_countries.geojson
$STD unzip -o cities500.zip
$STD rm cities500.zip
$STD ln -s $INSTALL_DIR_geo $INSTALL_DIR_app/geodata

msg_ok "Immich установлен"

# === Финальные настройки, systemd, логи ===
msg_info "Настройка systemd и логов..."
# runtime.env
cat > $IMMICH_DIR/runtime.env << EOF
DB_PASSWORD=$DB_PASSWORD
UPLOAD_DIR=$UPLOAD_DIR
EOF

# systemd
cat > /etc/systemd/system/immich-web.service << EOF
[Unit]
Description=Immich Web
After=network.target

[Service]
Type=simple
User=$IMMICH_USER
WorkingDirectory=$INSTALL_DIR_app
ExecStart=/usr/bin/node $INSTALL_DIR_app/dist/main
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/immich-ml.service << EOF
[Unit]
Description=Immich Machine Learning
After=network.target

[Service]
Type=simple
User=$IMMICH_USER
WorkingDirectory=$INSTALL_DIR_ml
ExecStart=$INSTALL_DIR_ml/venv/bin/python -m gunicorn app.main:app -k app.config.CustomUvicornWorker -w 1 -b 127.0.0.1:3003 -t 120 --log-config-json log_conf.json --graceful-timeout 0
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

$STD systemctl daemon-reload
$STD systemctl enable --now immich-web.service
$STD systemctl enable --now immich-ml.service

$STD mkdir -p $LOG_DIR
$STD chown -R $IMMICH_USER:$IMMICH_USER $LOG_DIR

msg_ok "Службы Immich настроены и запущены"

motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned" 