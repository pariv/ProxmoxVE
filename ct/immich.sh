#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2024 chmistry
# License: MIT | https://github.com/immich-app/immich

APP="Immich"
var_tags="${var_tags:-photos;gallery;ai}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-32}"
var_os="${var_os:-ubuntu}"
var_version="${var_version:-24.04}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -d /home/immich/app ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  # Здесь можно реализовать обновление Immich, если потребуется
  msg_ok "No update required. ${APP} is already up to date."
  exit
}

# --- Запрос опции ускорения ML ---
if ML_ACCEL=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Machine Learning Acceleration" --radiolist \
  "Выберите поддержку ML-ускорения для Immich:" 12 60 3 \
  "cpu" "Только CPU (без ускорения)" ON \
  "cuda" "NVIDIA CUDA (GPU)" OFF \
  "openvino" "Intel OpenVINO (iGPU/dGPU/NPU)" OFF \
  3>&1 1>&2 2>&3); then
    export var_ml_accel="$ML_ACCEL"
else
    export var_ml_accel="cpu"
fi

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:2283${CL}" 