#!/bin/bash
#
# Copyright 2020-present Facebook. All Rights Reserved.
#
# This program file is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program in a file named COPYING; if not, write to the
# Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor,
# Boston, MA 02110-1301 USA
#

# shellcheck disable=SC1091
. /usr/local/bin/openbmc-utils.sh

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin

prog="$0"

usage() {
    echo "Usage: $prog <command> [command options]"
    echo
    echo "Commands:"
    echo "  status: Get the current microserver power status"
    echo
    echo "  on: Power on microserver if not powered on already"
    echo "    options:"
    echo "      -f: Re-do power on sequence no matter if microserver has "
    echo "          been powered on or not."
    echo
    echo "  off: Power off microserver ungracefully"
    echo
    echo "  reset: Power reset microserver ungracefully"
    echo "    options:"
    echo "      -s: Power reset whole elbert system ungracefully"
    echo
    echo "  pimreset: Power-cycle one or all PIM(s)"
    echo "    options:"
    echo "      -a  : Reset all PIMs or "
    echo "      -2 , -3 , ... , -9 : Reset a single PIM (2, 3 ... 9) "
    echo
}

do_status() {
    echo -n "Microserver power is "
    return_code=0

    if wedge_is_us_on; then
        echo "on"
    else
        echo "off"
        return_code=1
    fi

    return $return_code
}

do_on() {
    local force opt ret
    force=0
    while getopts "f" opt; do
        case $opt in
            f)
                force=1
                ;;
            *)
                usage
                exit 1
                ;;
        esac
    done
    echo -n "Power on microserver ..."
    if [ $force -eq 0 ]; then
        # need to check if uS is on or not
        if wedge_is_us_on; then
            echo " Already on. Skip!"
            return 1
        fi
    fi

    wedge_power_on_board
    ret=$?
    if [ $ret -eq 0 ]; then
        echo " Done"
        logger "Successfully power on micro-server"
    else
        echo " Failed"
        logger "Failed to power on micro-server"
    fi
    return $ret
}

do_off() {
    local ret
    echo -n "Power off microserver ..."
    wedge_power_off_board
    ret=$?
    if [ $ret -eq 0 ]; then
        echo " Done"
        logger "Successfully power off micro-server"
    else
        echo " Failed"
        logger "Failed to power off micro-server"
    fi
    return $ret
}

do_reset() {
    local system opt
    system=0
    while getopts "s" opt; do
        case $opt in
            s)
                system=1
                ;;
            *)
                usage
                exit 1
                ;;
        esac
    done
    if [ $system -eq 1 ]; then
        logger "Power reset the whole system ..."
        echo -n "Power reset the whole system ..."
        sleep 1
        echo 0xde > "$PWR_SYSTEM_SYSFS"
        sleep 8
        # The chassis shall be reset now... if not, we are in trouble
        echo " Failed"
        return 254
    else
        do_off
        sleep 1
        do_on
    fi

}

toggle_pim_reset() {
    pim=$1
    # Set the selected PIM to powercycle
    for slot in 2 3 4 5 6 7 8 9; do
        if [ "$pim" -eq 0 ] || [ "$slot" -eq "$pim" ]; then
            echo "Reset PIM${slot}..."
            echo '1' > "$SMBCPLD_SYSFS_DIR"/pim"$slot"_reset
        fi
    done
    echo 'Waiting for PIMs to be re-enabled...'

    i=0
    while true; do
        i=$((i+1))
        # Wait for all cards to be be re-enabled
        if [ "$(head -n 1 "$SMBCPLD_SYSFS_DIR"/pim_reset)" == '0x0' ]; then
            echo 'All cards enabled!'
            break;
        fi

        if [ $i -gt 60 ]; then
            echo 'Timed out waiting for cards to be re-enabled...'
            exit 1
        fi
        sleep 1
     done

    # Re-initialize reset pims
    for slot in 2 3 4 5 6 7 8 9; do
        if [ "$pim" -eq 0 ] || [ "$slot" -eq "$pim" ]; then
            pim_prsnt="$(head -n 1 "$SMBCPLD_SYSFS_DIR"/pim"$slot"_present)"
            if [ "$pim_prsnt" == '0x1' ]; then
                power_on_pim "$slot"
            fi
        fi
    done
}

do_pimreset() {
    local pim opt retval
    retval=0
    pim=-1
    while getopts "23456789a" opt; do
        case $opt in
            a)
                pim=0
                ;;
            2)
                pim=2
                ;;
            3)
                pim=3
                ;;
            4)
                pim=4
                ;;
            5)
                pim=5
                ;;
            6)
                pim=6
                ;;
            7)
                pim=7
                ;;
            8)
                pim=8
                ;;
            9)
                pim=9
                ;;
            *)
                usage
                exit 1
                ;;
        esac
    done
    if [ $pim -eq -1 ]; then
      usage
      exit 1
    fi

    toggle_pim_reset $pim

    return $retval
}

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

command="$1"
shift

case "$command" in
    status)
        do_status "$@"
        ;;
    on)
        do_on "$@"
        ;;
    off)
        do_off "$@"
        ;;
    reset)
        do_reset "$@"
        ;;
    pimreset)
        do_pimreset "$@"
        ;;
    *)
        usage
        exit 1
        ;;
esac

exit $?
