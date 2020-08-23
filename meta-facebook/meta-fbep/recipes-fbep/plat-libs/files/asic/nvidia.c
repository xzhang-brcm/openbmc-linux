/*
 *
 * Copyright 2020-present Facebook. All Rights Reserved.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 *
 */

#include <stdio.h>
#include <stdint.h>
#include <syslog.h>
#include <openbmc/obmc-i2c.h>
#include "asic.h"

#define SMBPBI_MAX_RETRY 5

#define SMBPBI_STATUS_ACCEPTED  0x1C
#define SMBPBI_STATUS_INACTIVE  0x1D
#define SMBPBI_STATUS_READY     0x1E
#define SMBPBI_STATUS_SUCCESS   0x1F

#define NV_GPU_ADDR             0x4E
#define NV_COMMAND_STATUS_REG   0x5C
#define NV_DATA_REG             0x5D

/*
 * Opcodes and arguments
 */
#define SMBPBI_GET_CAPABILITY   0x01
#define SMBPBI_CAP_GPU0_TEMP    (1 << 0)
#define SMBPBI_CAP_BOARD_TEMP   (1 << 4)
#define SMBPBI_CAP_MEM_TEMP     (1 << 5)
#define SMBPBI_CAP_PWCS	        (1 << 16)

#define SMBPBI_GET_TEMPERATURE  0x03
#define SMBPBI_GPU0_TEMP        0x00
#define SMBPBI_BOARD_TEMP       0x04
#define SMBPBI_MEM_TEMP         0x05

#define SMBPBI_GET_POWER        0x04
#define SMBPBI_TOTAL_PWCS       0x00

#define SMBPBI_READ_SCRMEM      0x0D
#define SMBPBI_WRITE_SCRMEM     0x0E

#define SMBPBI_ASYNC_REQUEST    0x10
#define ASYNC_STATUS_SUCCESS    0x00

static int nv_open_slot(uint8_t slot)
{
  return i2c_cdev_slave_open((int)slot + 20, NV_GPU_ADDR, 0);
}

static int nv_msgbox_write_reg(int fd, uint8_t opcode, uint8_t arg1, uint8_t arg2)
{
  int ret;
  uint8_t tbuf[4] = {0};

  tbuf[0] = opcode;
  tbuf[1] = arg1;
  tbuf[2] = arg2;
  tbuf[3] = 0x80;

  ret = i2c_smbus_write_block_data(fd, NV_COMMAND_STATUS_REG, 4, tbuf);

  return ret < 0? -1: 0;
}

static int nv_msgbox_read_reg(int fd, uint8_t *buf)
{
  int ret;
  uint8_t rbuf[4] = {0};

  ret = i2c_smbus_read_block_data(fd, NV_COMMAND_STATUS_REG, rbuf);
  if (ret < 0)
    return -1;

  memcpy(buf, rbuf, 4);
  return 0;
}

static int nv_msgbox_read_data(int fd, uint8_t *buf)
{
  int ret;
  uint8_t rbuf[4] = {0};

  ret = i2c_smbus_read_block_data(fd, NV_DATA_REG, rbuf);
  if (ret < 0)
    return -1;

  memcpy(buf, rbuf, 4);
  return 0;
}

static int nv_msgbox_write_data(int fd, uint8_t *buf)
{
  return i2c_smbus_write_block_data(fd, NV_DATA_REG, 4, buf);
}

static uint8_t nv_get_status(int fd)
{
  uint8_t buf[4] = {0};

  if (nv_msgbox_read_reg(fd, buf) < 0)
    return SMBPBI_STATUS_INACTIVE;

  return buf[3] & 0x1f; // reg[28:24]
}

static int nv_msgbox_cmd(int fd, uint8_t opcode, uint8_t arg1, uint8_t arg2,
                         uint8_t* data_in, uint8_t* data_out)
{
  int i;
  uint8_t status;

  if (data_in && nv_msgbox_write_data(fd, data_in) < 0)
    return -1;

  if (nv_msgbox_write_reg(fd, opcode, arg1, arg2) < 0)
    return -1;

  for (i = 0; i < SMBPBI_MAX_RETRY; i++) {
    status = nv_get_status(fd);
    if (status == SMBPBI_STATUS_SUCCESS)
      break;
    if (opcode == SMBPBI_ASYNC_REQUEST && status == SMBPBI_STATUS_ACCEPTED)
      break;

    usleep(100);
  }
  if (i == SMBPBI_MAX_RETRY)
    return -1;

  if (nv_msgbox_read_data(fd, data_out) < 0)
    return -1;

  return 0;
}

static uint32_t nv_get_cap(int fd, uint8_t page)
{
  uint8_t buf[4] = {0};
  uint32_t cap;

  if (nv_msgbox_cmd(fd, SMBPBI_GET_CAPABILITY, page, 0x0, NULL, buf) < 0)
    return 0x0;

  memcpy(&cap, buf, 4);
  return cap;
}

static float nv_read_temp(uint8_t slot, uint8_t sensor, float *temp)
{
  int fd;
  uint32_t cap_mask;
  uint8_t buf[4] = {0};
  char value[16] = {0};

  switch (sensor) {
    case SMBPBI_GPU0_TEMP:
      cap_mask = SMBPBI_CAP_GPU0_TEMP;
      break;
    case SMBPBI_BOARD_TEMP:
      cap_mask = SMBPBI_CAP_BOARD_TEMP;
      break;
    case SMBPBI_MEM_TEMP:
      cap_mask = SMBPBI_CAP_MEM_TEMP;
      break;
    default:
      return ASIC_ERROR;
  };

  fd = nv_open_slot(slot);
  if (fd < 0)
    return ASIC_ERROR;

  if (!(nv_get_cap(fd, 0) & cap_mask))
    goto err;

  if (nv_msgbox_cmd(fd, SMBPBI_GET_TEMPERATURE, sensor, 0x0, NULL, buf) < 0)
    goto err;

  close(fd);
  snprintf(value, sizeof(value), "%d.%d", buf[1], buf[0]);
  *temp = atof(value);
  if (buf[3] & 0x80)
    *temp = -(*temp);
  return ASIC_SUCCESS;

err:
  close(fd);
  return ASIC_ERROR;
}

int nv_read_gpu_temp(uint8_t slot, float *value)
{
  return nv_read_temp(slot, SMBPBI_GPU0_TEMP, value);
}

int nv_read_board_temp(uint8_t slot, float *value)
{
  return nv_read_temp(slot, SMBPBI_BOARD_TEMP, value);
}

int nv_read_mem_temp(uint8_t slot, float *value)
{
  return nv_read_temp(slot, SMBPBI_MEM_TEMP, value);
}

int nv_read_pwcs(uint8_t slot, float *pwcs)
{
  int fd = nv_open_slot(slot);
  uint8_t buf[4] = {0};
  uint32_t value;

  if (fd < 0)
    return ASIC_ERROR;

  if (!(nv_get_cap(fd, 0) & SMBPBI_CAP_PWCS))
    goto err;

  if (nv_msgbox_cmd(fd, SMBPBI_GET_POWER, SMBPBI_TOTAL_PWCS, 0x0, NULL, buf) < 0)
    goto err;

  close(fd);
  memcpy(&value, buf, 4);

  *pwcs = (float)value / 1000; // mW -> W
  return ASIC_SUCCESS;

err:
  close(fd);
  return ASIC_ERROR;
}

int nv_set_power_limit(uint8_t slot, unsigned int watt)
{
  int fd, i;
  unsigned int mwatt = watt * 1000;
  uint8_t tbuf[4], rbuf[4];
  uint8_t async_id;

  fd = nv_open_slot(slot);
  if (fd < 0)
    return ASIC_ERROR;

  tbuf[0] = 0x01; // Set presistence flag
  tbuf[1] = 0x00;
  tbuf[2] = 0x00;
  tbuf[3] = 0x00;
  if (nv_msgbox_cmd(fd, SMBPBI_WRITE_SCRMEM, 0x0, 0x0, tbuf, rbuf) < 0)
    goto err;
  if (nv_msgbox_cmd(fd, SMBPBI_READ_SCRMEM, 0x0, 0x0, NULL, rbuf) < 0)
    goto err;
  if (rbuf[0] != 0x01 || rbuf[1] != 0x00 || rbuf[2] != 0x00 || rbuf[3] != 0x00)
    goto err;

  tbuf[0] = (uint8_t)(mwatt & 0xff);
  tbuf[1] = (uint8_t)((mwatt >> 8) & 0xff);
  tbuf[2] = (uint8_t)((mwatt >> 16) & 0xff);
  tbuf[3] = (uint8_t)((mwatt >> 24) & 0xff);
  if (nv_msgbox_cmd(fd, SMBPBI_WRITE_SCRMEM, 0x1, 0x0, tbuf, rbuf) < 0)
    goto err;
  if (nv_msgbox_cmd(fd, SMBPBI_ASYNC_REQUEST, 0x1, 0x0, NULL, rbuf) < 0)
    goto err;

  usleep(1000);
  async_id = rbuf[0];
  // Retry until ASYNC_STATUS_SUCCESS
  for (i = 0; i < SMBPBI_MAX_RETRY; i++) {
    if (nv_msgbox_cmd(fd, SMBPBI_ASYNC_REQUEST, 0xff, async_id, NULL, rbuf) == 0 &&
	rbuf[0] == ASYNC_STATUS_SUCCESS) {
      break;
    }
  }
  if (i == SMBPBI_MAX_RETRY)
    goto err;

  close(fd);
  syslog(LOG_CRIT, "Set power limit of GPU on slot %d to %d Watts", (int)slot, watt);
  return ASIC_SUCCESS;
err:
  close(fd);
  return ASIC_ERROR;
}
