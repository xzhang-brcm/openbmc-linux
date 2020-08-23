/**
 * Copyright 2020-present Facebook. All Rights Reserved.
 *
 * This program file is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation; version 2 of the License.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program in a file named COPYING; if not, write to the
 * Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301 USA
 */

package common

import (
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/facebook/openbmc/tools/flashy/lib/flash/flashutils/devices"
	"github.com/facebook/openbmc/tools/flashy/lib/logger"
	"github.com/facebook/openbmc/tools/flashy/lib/step"
	"github.com/facebook/openbmc/tools/flashy/lib/utils"
	"github.com/pkg/errors"
)

func TestFuserKMountRo(t *testing.T) {
	getWritableMountedMTDsOrig := devices.GetWritableMountedMTDs
	runCommandOrig := utils.RunCommand
	runCommandWithRetries := utils.RunCommandWithRetries
	startSyslogOrig := logger.StartSyslog
	defer func() {
		devices.GetWritableMountedMTDs = getWritableMountedMTDsOrig
		utils.RunCommand = runCommandOrig
		utils.RunCommandWithRetries = runCommandWithRetries
		logger.StartSyslog = startSyslogOrig
	}()
	cases := []struct {
		name                   string
		writableMountedMTDs    []devices.WritableMountedMTD
		writableMountedMTDsErr error
		fuserCmdErr            error
		remountCmdErr          error
		want                   step.StepExitError
		wantCmds               []string
	}{
		{
			name:                   "No writable mounted MTDs",
			writableMountedMTDs:    []devices.WritableMountedMTD{},
			writableMountedMTDsErr: nil,
			fuserCmdErr:            nil,
			remountCmdErr:          nil,
			want:                   nil,
			wantCmds:               []string{},
		},
		{
			name: "Wedge100 example writable mounted MTDs",
			writableMountedMTDs: []devices.WritableMountedMTD{
				devices.WritableMountedMTD{
					"/dev/mtdblock4",
					"/mnt/data",
				},
			},
			writableMountedMTDsErr: nil,
			fuserCmdErr:            nil,
			remountCmdErr:          nil,
			want:                   nil,
			wantCmds: []string{
				"fuser -km /mnt/data",
				"mount -o remount,ro /dev/mtdblock4 /mnt/data",
			},
		},
		{
			name: "Mulitple example writable mounted MTDs",
			writableMountedMTDs: []devices.WritableMountedMTD{
				devices.WritableMountedMTD{
					"/dev/mtdblock4",
					"/mnt/data",
				},
				devices.WritableMountedMTD{
					"/dev/mtdblock5",
					"/mnt/data1",
				},
			},
			writableMountedMTDsErr: nil,
			fuserCmdErr:            nil,
			remountCmdErr:          nil,
			want:                   nil,
			wantCmds: []string{
				"fuser -km /mnt/data",
				"mount -o remount,ro /dev/mtdblock4 /mnt/data",
				"fuser -km /mnt/data1",
				"mount -o remount,ro /dev/mtdblock5 /mnt/data1",
			},
		},
		{
			name:                   "GetWritableMountedMTDs error",
			writableMountedMTDs:    []devices.WritableMountedMTD{},
			writableMountedMTDsErr: errors.Errorf("GetWritableMountedMTDs error"),
			fuserCmdErr:            nil,
			remountCmdErr:          nil,
			want:                   step.ExitSafeToReboot{errors.Errorf("GetWritableMountedMTDs error")},
			wantCmds:               []string{},
		},
		{
			name: "Ignore fuser failed",
			writableMountedMTDs: []devices.WritableMountedMTD{
				devices.WritableMountedMTD{
					"/dev/mtdblock4",
					"/mnt/data",
				},
			},
			writableMountedMTDsErr: nil,
			fuserCmdErr:            errors.Errorf("fuser failed"),
			remountCmdErr:          nil,
			want:                   nil,
			wantCmds: []string{
				"fuser -km /mnt/data",
				"mount -o remount,ro /dev/mtdblock4 /mnt/data",
			},
		},
		{
			name: "Remount error",
			writableMountedMTDs: []devices.WritableMountedMTD{
				devices.WritableMountedMTD{
					"/dev/mtdblock4",
					"/mnt/data",
				},
			},
			writableMountedMTDsErr: nil,
			fuserCmdErr:            nil,
			remountCmdErr:          errors.Errorf("remount failed"),
			want: step.ExitSafeToReboot{
				errors.Errorf("Remount command [mount -o remount,ro /dev/mtdblock4 /mnt/data] failed: remount failed"),
			},
			wantCmds: []string{
				"fuser -km /mnt/data",
				"mount -o remount,ro /dev/mtdblock4 /mnt/data",
			},
		},
	}
	logger.StartSyslog = func() {}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gotCmds := []string{}
			devices.GetWritableMountedMTDs = func() ([]devices.WritableMountedMTD, error) {
				return tc.writableMountedMTDs, tc.writableMountedMTDsErr
			}
			// fuser
			utils.RunCommand = func(cmdArr []string, timeout time.Duration) (int, error, string, string) {
				gotCmds = append(gotCmds, strings.Join(cmdArr[:], " "))
				// only err is checked
				return 0, tc.fuserCmdErr, "", ""
			}

			// remount
			utils.RunCommandWithRetries = func(cmdArr []string, timeout time.Duration, maxAttempts int, interval time.Duration) (int, error, string, string) {
				gotCmds = append(gotCmds, strings.Join(cmdArr[:], " "))
				// only err is checked
				return 0, tc.remountCmdErr, "", ""
			}

			got := fuserKMountRo(step.StepParams{})

			step.CompareTestExitErrors(tc.want, got, t)

			if !reflect.DeepEqual(gotCmds, tc.wantCmds) {
				t.Errorf("commands: want '%#v' got '%#v'", tc.wantCmds, gotCmds)
			}
		})
	}
}
