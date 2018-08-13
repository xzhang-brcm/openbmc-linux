#!/bin/bash
#
# Copyright 2018-present Facebook. All Rights Reserved.
#
# This program file is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# for more details.

# You should have received a copy of the GNU General Public License
# along with this program in a file named COPYING; if not, write to the
# Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor,
# Boston, MA 02110-1301 USA
#

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
source /usr/local/bin/openbmc-utils.sh

board_rev=$(wedge_board_rev)

is_sys_upgrade=0
is_psu_upgrade=0
is_fan_upgrade=0
is_smb_upgrade=0

function set_led_color
{
  local component=$1 color=$2
  sh /usr/local/bin/set_sled.sh $component $color $board_rev
}
# System led:
# If atleast 1 card is not present = yellow (red+green)
# otherwise = blue
# note presence util reads peer cmm =0
function set_sys_led
{
  scm_nprsnt_cnt=`/usr/local/bin/presence_util.sh scm | grep "scm.*: 0" | wc -l`
  pim_nprsnt_cnt=`/usr/local/bin/presence_util.sh pim | grep "pim.*: 0" | wc -l`
  if [[ $scm_nprsnt_cnt -ge 1 ]]; then
    set_led_color 'sys' 'red'
  elif [[ $pim_nprsnt_cnt -ge 1 ]]; then
    set_led_color 'sys' 'red'
  else
    set_led_color 'sys' 'blue'
  fi
}

function check_psu_alarm
{
  local sensor=$1
  local vin=0 vout_12=0 vout_3_3=0
  local vin_high_th=259 # threshold = 240, error ratio = 0.08
  local vin_low_th=92 # threshold = 100, error ratio = 0.08
  local vout_12V_high_th=13 # threshold = 12, error ratio = 0.08
  local vout_12V_low_th=11 # threshold = 12, error ratio = 0.08
  
  readarray psu < <(/usr/bin/sensors $sensor | grep -e "Input Voltage" -e "12V Output" -e "3.3V Output Voltage")
  vin=$(echo "${psu}" | sed -e 's/PSU.* Input Voltage:\s*+\(.*\)[.].*$/\1/')
  vout_12=$(echo "${psu[1]}" | sed -e 's/PSU.* 12V Output Voltage:\s*+\(.*\)[.].*$/\1/')
  vout_3_3=$(echo "${psu[2]}" | sed -e 's/PSU.*3V Output Voltage:\s*+\(.*\)[.].*$/\1/')
  #monitor vin
  if [ $vin -lt $vin_low_th ] || [ $vin -gt $vin_high_th ] ; then
    return 0
  fi
  #monitor vout 12V
  if [ $vout_12 -lt $vout_12V_low_th ] || [ $vout_12 -gt $vout_12V_high_th ]; then
    return 0
  fi
  #monitor vout 3.3V
  if [ $vout_3_3 -ne 3 ]; then
    return 0
  fi
  return 1
}

function set_psu_led
{
  sensors=( "psu_driver-i2c-49-59" "psu_driver-i2c-48-58" "psu_driver-i2c-57-59" "psu_driver-i2c-56-58" )
  for i in "${sensors[@]}"
  do
    if check_psu_alarm $i; then
      set_led_color 'psu' 'red'
      return
    fi
  done
  psu_nprsnt_cnt=`/usr/local/bin/presence_util.sh psu | grep "psu.*: 0" | wc -l`
  if [[ $psu_nprsnt_cnt -ge 1 ]]; then
    set_led_color 'psu' 'red'
  else
    set_led_color 'psu' 'blue'
  fi
}

function set_fan_led
{
  ret=$(/usr/bin/sensors fcmcpld-* | sed -n "/^Fan.*:.* 0 RPM/p" | wc -l)
  if [ $ret -gt 0 ]; then
    set_led_color 'fan' 'red'
    return
  fi
  fan_nprsnt_cnt=`/usr/local/bin/presence_util.sh fan | grep "fan.*: 0" | wc -l`
  if [[ $fan_nprsnt_cnt -ge 1 ]]; then
    set_led_color 'fan' 'red'
  else
    set_led_color 'fan' 'blue'
  fi
}

function set_smb_led
{
  set_led_color 'smb' 'blue'
}

function touch_upgrade_file
{
  if [[ $2 = 'touch' ]]; then
  
    ret=`ls /tmp | grep $1_upgrade_mode | wc -l`
    if [[ $ret = 0 ]]; then
      echo 1 > /tmp/$1_upgrade_mode
    fi
  elif [[ $2 = 'rm' ]]; then
    ret=`ls /tmp | grep $1_upgrade_mode | wc -l`
    if [[ $ret -gt 0 ]]; then
      rm -rf /tmp/$1_upgrade_mode
    fi
  fi
}

function sys_upgrade_mode
{
  local spi2_upgrade=`ls /tmp | grep *_spi2_tmp | wc -l`
  local scmcpld_upgrade=`ls /tmp | grep scmcpld_update | wc -l`
  local fw_util_upgrade=`ls /var/run | grep fw-util_* | wc -l`
  
  if [[ spi2_upgrade -gt 0 ]] || [[ scmcpld_upgrade -gt 0 ]] || [[ fw_util_upgrade -gt 0 ]]; then
    is_sys_upgrade=1
    return
  fi
  is_sys_upgrade=0
}

function psu_upgrade_mode
{
  psu_upgrade=`ls /tmp | grep pdbcpld_update | wc -l`
  if [[ psu_upgrade -gt 0 ]]; then
    is_psu_upgrade=1
    return
  fi
  is_psu_upgrade=0
}

function fan_upgrade_mode
{
  fcm_upgrade=`ls /tmp | grep fcmcpld_update | wc -l`
  if [[ fcm_upgrade -gt 0 ]]; then
    is_fan_upgrade=1
    return
  fi
  is_fan_upgrade=0
}

function smb_upgrade_mode
{
  local bmc_upgrade=`ps | grep "flashcp" | wc -l` 
  local spi1_upgrade=`ls /tmp | grep *_spi1_tmp | wc -l`
  local smbcpld_upgrade=`ls /tmp | grep smbcpld_update | wc -l`
  
  if [[ bmc_upgrade -gt 1 ]] || [[ spi1_upgrade -gt 0 ]] || [[ smbcpld_upgrade -gt 0 ]]; then
    is_smb_upgrade=1
    return
  fi
  is_smb_upgrade=0
}

function start_upgrade_led
{
  if [[ $is_sys_upgrade = 1 ]] || [[ $is_psu_upgrade = 1 ]] || [[ $is_fan_upgrade = 1 ]] || [[ $is_smb_upgrade = 1 ]]; then
    ret=`ps | grep led_upgrade_mod | wc -l`
    if [[ $ret -le 1 ]]; then
      /usr/local/bin/led_upgrade_mode.sh >/dev/null 2>&1 &
    fi
  fi
}

while [ 1 ];do
  sys_upgrade_mode
  psu_upgrade_mode
  fan_upgrade_mode
  smb_upgrade_mode
  if [[ $is_sys_upgrade = 1 ]]; then
    touch_upgrade_file 'sys' 'touch'
  else
    touch_upgrade_file 'sys' 'rm'
    set_sys_led
  fi
  if [[ $is_psu_upgrade = 1 ]]; then
    touch_upgrade_file 'psu' 'touch'
  else
    touch_upgrade_file 'psu' 'rm'
    set_psu_led
  fi
  if [[ $is_fan_upgrade = 1 ]]; then
    touch_upgrade_file 'fan' 'touch'
  else
    touch_upgrade_file 'fan' 'rm'
    set_fan_led
  fi
  if [[ $is_smb_upgrade = 1 ]]; then
    touch_upgrade_file 'smb' 'touch'
  else
    touch_upgrade_file 'smb' 'rm'
    set_smb_led
  fi
  start_upgrade_led
  sleep 1s
done