#!/bin/bash

# the name of this script is ...
SCRIPT=$(basename "${0}")

# discover the real user of the parent process
REAL_USER=$(ps -p ${PPID} -o ruser=)

# need to become root with 'sudo -s` to run this script
[ "${EUID}" -ne 0 -o "${REAL_USER}" != "root" ] \
	&& echo "You need to run 'sudo -s' before running this script" \
	&& exit 1

# check usage
if [ $# -ne 0 ] ; then
   echo ""
   echo "Usage: ${SCRIPT}"
   echo ""
   exit 1
fi

# does this look like a proxmox host?
if [ -n "$(which systemctl)" ] ; then
	if [ "$(systemctl is-active pveproxy)" != "active" ] ; then
		echo "Error: pveproxy daemon is not active - is this a Proxmox-VE server?"
		exit 1
	fi
else
	echo "Error: systemctl is not installed - is this a Proxmox-VE server?"
	exit 1
fi

# the installation directory for certificates is...
INSTALL_DIR="/etc/pve/nodes/${HOSTNAME}"

# does that directory exist?
if [ ! -d "${INSTALL_DIR}" ] ; then
	echo "Error: ${INSTALL_DIR} does not exist - can't install certificate files"
	exit 1
fi

# the two expected files are
PROXMOX_SERVER_KEY="pveproxy-ssl.key"
PROXMOX_SERVER_CRT="pveproxy-ssl.pem"

# the combination of the two is:
INSTALL_FILES="${PROXMOX_SERVER_KEY} ${PROXMOX_SERVER_CRT}"

# check existence of incoming files in the working directory and
for F in ${INSTALL_FILES} ; do
	if [ ! -f "${F}" ] ; then
		echo "Error: ${F} not found in working directory"
		exit 1
	fi
done

# check whether the certificate matches this host
MATCH=$(openssl x509 -noout -in "${PROXMOX_SERVER_CRT}" -checkhost "${HOSTNAME}")

# does the certificate match?
if [[ "${MATCH}" == *"does NOT match certificate" ]] ; then 
	# no! abort
	echo "${MATCH}"
	exit 1
fi

# new files exist and are ready - install
for F in ${INSTALL_FILES} ; do
	echo "  installing ${F}"
	chown root:www-data "${F}"
	chmod 640 "${F}"
	rm -f "${INSTALL_DIR}/${F}"
	mv "${F}" "${INSTALL_DIR}/."
done

# signal restart
echo "  restarting pveproxy"
systemctl restart pveproxy

echo "  completed!"
