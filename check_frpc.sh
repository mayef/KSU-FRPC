#!/system/bin/sh
set -u

#MODDIR=${0%/*}
MODDIR="$(dirname $(readlink -f "$0"))"
. ${MODDIR}/files/status.conf
F_ARCH="${F_ARCH:=arm64}"
DATADIR="${DATADIR:=/sdcard/Android}"
. ${MODDIR}/functions.sh
export PATH=${MODDIR}/files/bin/busybox:$PATH
frpc_bin="frpc-${F_ARCH}"

if [ -z "$(cat ${MODDIR}/module.prop)" ]; then
  cp -af "${MODDIR}/files/module.prop.bak" "${MODDIR}/module.prop"
fi

running_start() {
  local _frpc_admin_port _running_num _check_file_status
  battery_electricity_check
  [ "$?" -ne 0 ] && return

  # 检查配置文件
  if [ ! -f "${DATADIR}/frpc/frpc.ini" ]; then
    sed -i -e "/^CHECK_FILE_STATUS=/c CHECK_FILE_STATUS=Android\/frpc目录下未找到frpc\.ini文件！" \
      -e "/^RUNNING_STATUS=/c RUNNING_STATUS=FRPC未运行！" "${MODDIR}/files/status.conf"
      return 8
  fi
  _check_file_status="$(stat -c %Y ${DATADIR}/frpc/frpc.ini)"
  sed -i "/^FILE_STATUS=/c FILE_STATUS=${_check_file_status}" "${MODDIR}/files/status.conf"

  # 检索配置文件是否正确
  sh ${MODDIR}/run_frpc.sh verify
  if [ "$?" -eq 0 ]; then
    sed -i "/^CHECK_FILE_STATUS=/c CHECK_FILE_STATUS=配置文件检测正确！" "${MODDIR}/files/status.conf"
  else
    sed -i -e "/^CHECK_FILE_STATUS=/c CHECK_FILE_STATUS=配置文件检测错误，请自查配置文件！" \
      -e "/^RUNNING_STATUS=/c RUNNING_STATUS=FRPC未运行！" "${MODDIR}/files/status.conf"
      return 9
  fi

  # 启动FRPC程序
  sh ${MODDIR}/run_frpc.sh start
  sleep 3
  if [ -n "$(get_frpc_running_pid ${frpc_bin})" ]; then
    sed -i -e "/^RUNNING_STATUS=/c RUNNING_STATUS=FRPC正在运行中！" \
      -e "/^RELOAD_NUM=/c RELOAD_NUM=0" "${MODDIR}/files/status.conf"
  else
    sed -i "/^RUNNING_STATUS=/c RUNNING_STATUS=FRPC启动失败！若您配置了FRPC日志，请根据日志排查错误！" "${MODDIR}/files/status.conf"
    return 10
  fi

  # 检查FRPC穿透了多少服务（不完全正确，例如xtcp方式无记录）
  _frpc_admin_port=$(get_parameters admin_port "${DATADIR}/frpc/frpc.ini")
  if [ "${_frpc_admin_port}" -ge 1 ] && [ "${_frpc_admin_port}" -le 65535 ]; then
    _running_num=$(sh ${MODDIR}/run_frpc.sh status)
    sleep 1
    sed -i "/^RUNNING_NUM=/c RUNNING_NUM=${_running_num}" "${MODDIR}/files/status.conf"
  elif [ -z "${_frpc_admin_port}" ]; then
    sed -i "/^RUNNING_NUM=/c RUNNING_NUM=未定义端口！" "${MODDIR}/files/status.conf"
    return 11
  else
    sed -i "/^RUNNING_NUM=/c RUNNING_NUM=端口定义可能错误！" "${MODDIR}/files/status.conf"
    return 12
  fi
}

check_reload() {
  local _running_num _check_new_file_status _reload_num
  battery_electricity_check
  [ $? -ne 0 ] && return

  if [ ! -f ${DATADIR}/frpc/frpc.ini ]; then
    sed -i "/^CHECK_FILE_STATUS=/c CHECK_FILE_STATUS=Android\/frpc目录下未找到frpc\.ini文件！（已保持当前运行状态）" "${MODDIR}/files/status.conf"
    return 13
  fi

  # 时间戳若不等，文件被修改，执行重载操作
  _check_new_file_status="$(stat -c %Y ${DATADIR}/frpc/frpc.ini)"
  if [ "${FILE_STATUS}" != "${_check_new_file_status}" ]; then
    sh ${MODDIR}/run_frpc.sh verify
    if [ "$?" -ne 0 ]; then
      sed -i "/^CHECK_FILE_STATUS=/c CHECK_FILE_STATUS=配置文件检测错误，可能修改的参数需重启生效，请自查配置文件或重启frpc程序！（已保持当前运行状态）" "${MODDIR}/files/status.conf"
      return 14
    fi

    sh ${MODDIR}/run_frpc.sh reload
    if [ "$?" -ne 0 ]; then
      sed -i "/^CHECK_FILE_STATUS=/c CHECK_FILE_STATUS=配置文件检测正确但重载失败，可能修改的参数需重启生效，请自查配置文件或重启frpc程序！（已保持当前运行状态）" "${MODDIR}/files/status.conf"
      return 15
    fi

    sleep 3
    _running_num=$(sh ${MODDIR}/run_frpc.sh status)
    _reload_num="$(($RELOAD_NUM + 1))"
    sed -i -e "/^RELOAD_NUM=/c RELOAD_NUM=${_reload_num}" -e "/^FILE_STATUS=/c FILE_STATUS=${_check_new_file_status}" \
      -e "/^CHECK_FILE_STATUS=/c CHECK_FILE_STATUS=配置文件检测正确！" \
      -e "/^RUNNING_NUM=/c RUNNING_NUM=${_running_num}" "${MODDIR}/files/status.conf"
  fi
}

# 电池电量检测
battery_electricity_check() {
  if [ "$(battery_electricity)" -lt 20 ] && [ "$(battery_charge)" -eq 1 ]; then
    if [ -n "${_frpc_pid_num}" ]; then
      kill_frpc ${frpc_bin}
      sed -i -e "/^CHECK_FILE_STATUS=/c CHECK_FILE_STATUS=已自动停止检测！" \
        -e "/^RUNNING_STATUS=/c RUNNING_STATUS=当前电量低于20%且未在充电，自动停止运行！" \
        -e "/^RUNNING_NUM=/c RUNNING_NUM=已自动停止检测！" "${MODDIR}/files/status.conf"
      return 6
    else
      sed -i -e "/^CHECK_FILE_STATUS=/c CHECK_FILE_STATUS=未运行！" \
        -e "/^RUNNING_STATUS=/c RUNNING_STATUS=当前电量低于20%且未在充电，终止运行！" \
        -e "/^RUNNING_NUM=/c RUNNING_NUM=已停止检测！" "${MODDIR}/files/status.conf"
      return 7
    fi
  fi
  return 0
}

main() {
  local _frpc_vmrss
  local _frpc_pid_num="$(get_frpc_running_pid ${frpc_bin})"

  if [ ! -f "${MODDIR}/disable" ]; then
    [ -z "${_frpc_pid_num}" ] && running_start || check_reload
  else
    kill_frpc ${frpc_bin}
    sed -i -e "/^CHECK_FILE_STATUS=/c CHECK_FILE_STATUS=已手动停止检测！" \
      -e "/^RUNNING_STATUS=/c RUNNING_STATUS=已手动停止运行（重新打开则自动重启FRPC，无需设备重启）" \
      -e "/^RUNNING_NUM=/c RUNNING_NUM=已手动停止检测！" "${MODDIR}/files/status.conf"
  fi

  _frpc_vmrss="$(frpc_vmrss_check ${frpc_bin})"
  sleep 1
  . ${MODDIR}/files/status.conf
  if [ ! -f ${MODDIR}/update ]; then
    sed -i "/^description=/c description=使用Magisk挂载运行通用FRPC程序。[状态：${RUNNING_STATUS}；物理内存占用：${_frpc_vmrss:-NuLL}；配置文件状态：${CHECK_FILE_STATUS}；穿透服务数（仅参考）：${RUNNING_NUM}，自动重载配置文件 ${RELOAD_NUM} 次]" "${MODDIR}/module.prop"
  else
    sed -i "/^description=/c description=使用Magisk挂载运行通用FRPC程序。[状态：${RUNNING_STATUS}，物理内存占用：${_frpc_vmrss:-NuLL}；配置文件状态：${CHECK_FILE_STATUS}；穿透服务数（仅参考）：${RUNNING_NUM}，自动重载配置文件 ${RELOAD_NUM} 次]（模块新设定将在设备重启后生效！）" "${MODDIR}/module.prop"
  fi
}

if [ -f "${MODDIR}/screen" ]; then
  main
elif [ "$(screen_status)" -eq 0 ]; then
  main
fi
