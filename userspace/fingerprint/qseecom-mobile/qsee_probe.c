/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Minimal probe for the qcom-qseecom-mobile transport.
 *
 * Opens /dev/qseecom_mobile and issues QSEECOM_MOBILE_IOC_LOAD_APP for a named
 * Trusted Application in /lib/firmware/ (default: the Xiaomi FPC fingerprint
 * TA, "fpctzappfingerprint"). A successful load means mainline Linux reached
 * Qualcomm QSEE over SMCCC and TrustZone accepted and started the signed TA.
 *
 * Build (host, aarch64):
 *   aarch64-linux-gnu-gcc -static -O2 -o qsee_probe qsee_probe.c
 * Run (device, as root, after insmod qcom_qseecom_mobile.ko):
 *   ./qsee_probe [app_name]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <stdint.h>

#define QSEECOM_MOBILE_IOC_MAGIC 'Q'
struct qseecom_mobile_load_app {
	char   app_name[64];
	uint32_t app_id;
};
#define QSEECOM_MOBILE_IOC_LOAD_APP \
	_IOWR(QSEECOM_MOBILE_IOC_MAGIC, 1, struct qseecom_mobile_load_app)

int main(int argc, char **argv)
{
	const char *name = argc > 1 ? argv[1] : "fpctzappfingerprint";
	int fd = open("/dev/qseecom_mobile", O_RDWR);
	struct qseecom_mobile_load_app app;
	int ret;

	if (fd < 0) {
		fprintf(stderr, "open /dev/qseecom_mobile: %s\n", strerror(errno));
		return 1;
	}

	memset(&app, 0, sizeof(app));
	snprintf(app.app_name, sizeof(app.app_name), "%s", name);

	ret = ioctl(fd, QSEECOM_MOBILE_IOC_LOAD_APP, &app);
	printf("LOAD_APP('%s'): ret=%d errno=%d (%s) app_id=%u\n",
	       name, ret, errno, strerror(errno), app.app_id);
	close(fd);
	return ret < 0 ? 2 : 0;
}
