#!/bin/bash

# the name of this script is ...
SCRIPT=$(basename "${0}")

# check parameters
if [ $# -lt 1 -o $# -gt 4 ] ; then
   echo ""
   echo "Usage: ${SCRIPT} hostname domain ipAddr {days}"
   echo ""
   echo "       Examples: ${SCRIPT} server my.domain.com 192.168.1.100"
   echo "                 ${SCRIPT} server my.domain.com 192.168.1.100 825"
   echo ""
   exit 1
fi

# the first argument is the server host name
PROXMOX_HOST="${1}"

# the second argument is the domain
PROMOX_DOMAIN="${2}"

# the third argument is the IP address of the server
PROXMOX_HOST_IPADDR="${3}"

# the optional fourth argument is the number of days
# limit of 825 days (Apple restriction)
DAYS=${4:-730}

# there is some possibility of a non-numeric number of days so force the issue
# (DAYS output will be zero if DAYS input was non-numeric)
DAYS=$((DAYS*1))

# validate days
if [ ${DAYS} -lt 1 -o ${DAYS} -gt 825 ] ; then

	echo "Warning: Server certificate duration evaluates as ${DAYS} days."
	echo "         Durations outside the range [1..825] days are not standards compliant."
	echo "         The certificate will be generated as requested but it may not work."

fi

# we can infer the server's fully-qualified domain name
PROXMOX_HOST_FQDN="${PROXMOX_HOST}.${PROMOX_DOMAIN}"

# a folder for the domain should exist in the working directoru
PROMOX_DOMAIN_DIR="${PWD}/${PROMOX_DOMAIN}"

# check that the folder exists
if [ ! -d "${PROMOX_DOMAIN_DIR}" ] ; then

	echo "Error: Required domain directory does not exist:"
	echo "   ${PROMOX_DOMAIN_DIR}"
	exit 1

fi

# expected directory exists - make it the working directory
cd "${PROMOX_DOMAIN_DIR}"

# the following files should be discoverable
CA_DIR="${PROMOX_DOMAIN_DIR}/CA"
CA_PRIVATE_KEY_PEM="${CA_DIR}/${PROMOX_DOMAIN}.key"
CA_CERTIFICATE_PEM="${CA_DIR}/${PROMOX_DOMAIN}.crt"

# check that required files are present
if ! [ -f "${CA_PRIVATE_KEY_PEM}" -a -f "${CA_CERTIFICATE_PEM}" ] ; then

	echo "Error: either/both required certificate files do not exist:"
	echo "   ${CA_PRIVATE_KEY_PEM}"
	echo "   ${CA_CERTIFICATE_PEM}"
	echo "Try running:"
	echo "   ./create_certificate_for_domain.sh ${PROMOX_DOMAIN}"
	exit 1

fi

# server files will be generated here
SERVER_DIR="servers/${PROXMOX_HOST}"

# create SERVER_DIR if it does not exist
mkdir -p "${SERVER_DIR}"

# make it the working directory
cd "${SERVER_DIR}"

# SERVER_DIR may contain the following files
HOST_PRIVATE_KEY_PEM="pveproxy-ssl.key"
HOST_SIGNING_REQUEST="${PROXMOX_HOST}.csr"
HOST_CERTIFICATE_PEM="pveproxy-ssl.pem"

# does the server private key exist?
if [ -f "${HOST_PRIVATE_KEY_PEM}" ] ; then

	# yes! use it
	echo "Using existing host private key for ${PROXMOX_HOST_FQDN}"

else

	# no! generate one
	echo "Generating private host key for ${PROXMOX_HOST_FQDN}"
	openssl genrsa -out "${HOST_PRIVATE_KEY_PEM}" 4096

fi

# does a CSR exist?
if [ -f "${HOST_SIGNING_REQUEST}" ] ; then

	echo "Using exiting Certificate Signing Request (CSR) for ${PROXMOX_HOST_FQDN}"

else

	echo "Generate Certificate Signing Request (CSR) for ${PROXMOX_HOST_FQDN}"
	openssl req -new \
		-subj "/CN=${PROXMOX_HOST_FQDN}" \
		-key "${HOST_PRIVATE_KEY_PEM}" \
		-out "${HOST_SIGNING_REQUEST}"

fi

# construct the alternate names. First, the IP address
SUBJECT_ALT_NAME="IP:${PROXMOX_HOST_IPADDR}"
# then the host name
SUBJECT_ALT_NAME="${SUBJECT_ALT_NAME},DNS:${PROXMOX_HOST}"
# then the fully-qualified domain name
SUBJECT_ALT_NAME="${SUBJECT_ALT_NAME},DNS:${PROXMOX_HOST_FQDN}"
# then the multicase domain name
SUBJECT_ALT_NAME="${SUBJECT_ALT_NAME},DNS:${PROXMOX_HOST}.local"

# report what is happening depending on whether certificate already exists
if [ -f "${HOST_CERTIFICATE_PEM}" ] ; then
	echo "Updating existing server certificate for ${PROXMOX_HOST_FQDN}"
else
	echo "Generating server certificate for ${PROXMOX_HOST_FQDN}"
fi

# create or update the server certificate, as appropriate
openssl x509 -req -sha256 \
	-CA "${CA_CERTIFICATE_PEM}" \
	-CAkey "${CA_PRIVATE_KEY_PEM}" \
	-CAcreateserial \
	-extensions a \
	-extfile <(echo "[a]
		basicConstraints=CA:FALSE
		nsComment=OpenSSL Proxmox Server Certificate
		subjectAltName=${SUBJECT_ALT_NAME}
		extendedKeyUsage=critical,serverAuth
	") \
	-days ${DAYS} \
	-in  "${HOST_SIGNING_REQUEST}" \
	-out "${HOST_CERTIFICATE_PEM}"
