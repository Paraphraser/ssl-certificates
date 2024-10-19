#!/bin/bash

# the name of this script is ...
SCRIPT=$(basename "${0}")

# check parameters
if [ $# -lt 1 -o $# -gt 2 ] ; then
   echo ""
   echo "Usage: ${SCRIPT} domain {days}"
   echo ""
   echo "       Examples: ${SCRIPT} my.domain.com"
   echo "                 ${SCRIPT} my.domain.com 825"
   echo ""
   exit 1
fi

# the first argument is the domain
PROMOX_DOMAIN="${1}"

# the optional second argument is the CA certificate lifetime in days
DAYS=${2:-3650}

# there is some possibility of a non-numeric number of days so force the issue
DAYS=$((DAYS*1))

# validate days
if [ ${DAYS} -lt 1 ] ; then

	echo "Error: requested CA certificate duration should be at least 1 day."
	exit 1

fi

# and a folder should exist in the working directoru
CA_DIR="${PWD}/${PROMOX_DOMAIN}/CA"

# create CA_DIR if it does not exist
mkdir -p "${CA_DIR}"

# make it the working directory
cd "${CA_DIR}"

# CA_DIR may contain the following files
CA_PRIVATE_KEY_PEM="${PROMOX_DOMAIN}.key"
CA_CERTIFICATE_PEM="${PROMOX_DOMAIN}.crt"
CA_CERTIFICATE_DER="${PROMOX_DOMAIN}.der"

# does the CA private key exist?
if [ -f "${CA_PRIVATE_KEY_PEM}" ] ; then

	# yes! use it
	echo "Using existing private key for ${PROMOX_DOMAIN} Certificate Authority"

else

	# no! generate one
	echo "Generating private key for ${PROMOX_DOMAIN} Certificate Authority"
	openssl genrsa -out "${CA_PRIVATE_KEY_PEM}" 4096

fi

# report what is happening depending on whether certificate already exists
if [ -f "${CA_CERTIFICATE_PEM}" ] ; then
	echo "Updating existing self-signed certificate for the ${PROMOX_DOMAIN} domain"
else
	echo "Creating self-signed certificate for the ${PROMOX_DOMAIN} domain"
fi

# create or update the CA certificate, as appropriate
openssl req -new -x509 -sha256 \
	-subj "/CN=${PROMOX_DOMAIN}" \
	-days ${DAYS} \
	-key "${CA_PRIVATE_KEY_PEM}" \
	-out "${CA_CERTIFICATE_PEM}"

# convert PEM-format certificate to DER-format as a convenience
openssl x509 \
	-inform pem \
	-in "${CA_CERTIFICATE_PEM}" \
	-outform der \
	-out "${CA_CERTIFICATE_DER}" 
