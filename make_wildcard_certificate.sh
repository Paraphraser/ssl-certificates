#!/bin/bash

# the name of this script is ...
SCRIPT=$(basename "${0}")

# certificate-lifetime parameters (in case of moving goal-posts)
DEFDAYS=730
MAXDAYS=825

# check parameters
if [ $# -ne 1 ] ; then

	cat <<-USAGE

	Usage: {DAYS=n} ${SCRIPT} domain

	Examples: ${SCRIPT} your.home.arpa
	          DAYS=${DEFDAYS} ${SCRIPT} your.home.arpa

	USAGE

	exit 1

fi

# the first argument is the domain
DOMAIN="${1}"

# we can infer the server's fully-qualified domain name
WILDCARD_FQDN="*.${DOMAIN}"

# a folder for the domain should exist in the working directoru
DOMAIN_DIR="${PWD}/${DOMAIN}"

# check that the folder exists
if [ ! -d "${DOMAIN_DIR}" ] ; then

	cat <<-DOMAINDIRCHECK

	Error: Required domain directory does not exist:
	  ${DOMAIN_DIR}
	Try running:
	  ./make_domain_certificate.sh ${DOMAIN}

	DOMAINDIRCHECK

	exit 1

fi

# expected directory exists - make it the working directory
cd "${DOMAIN_DIR}"

# the following files should be discoverable
CA_DIR="${DOMAIN_DIR}/CA"
CA_PRIVATE_KEY_PEM="${DOMAIN}.key"
CA_CERTIFICATE_PEM="${DOMAIN}.crt"

# check that required files are present
if ! [ -f "${CA_DIR}/${CA_PRIVATE_KEY_PEM}" -a -f "${CA_DIR}/${CA_CERTIFICATE_PEM}" ] ; then

	cat <<-CAFILESCHECK

	Error: either/both required certificate files do not exist:
	  ${CA_DIR}/${CA_PRIVATE_KEY_PEM}
	  ${CA_DIR}/${CA_CERTIFICATE_PEM}
	Try running:
	  ./make_domain_certificate.sh ${DOMAIN}

	CAFILESCHECK

	exit 1

fi

# server files will be generated here
WILDCARD_DIR="wildcard"

# create WILDCARD_DIR if it does not exist
mkdir -p "${WILDCARD_DIR}"

# make it the working directory
cd "${WILDCARD_DIR}"

# WILDCARD_DIR may contain the following files
WILDCARD_PRIVATE_KEY_PEM="wildcard.key"
WILDCARD_SIGNING_REQUEST="wildcard.csr"
WILDCARD_CERTIFICATE_PEM="wildcard.crt"
WILDCARD_DAYS_CACHE=".days"

# DAYS can be set from (1) environment (2) cache (3) default
DAYS=${DAYS:-$(cat "${WILDCARD_DAYS_CACHE}" 2>/dev/null)}
DAYS=${DAYS:-$DEFDAYS}

# validate days
DAYS=$((DAYS*1))
if [ ${DAYS} -lt 1 -o ${DAYS} -gt ${MAXDAYS} ] ; then

	cat <<-DAYSRANGECHECK

	Warning: Wildcard certificate duration evaluates as ${DAYS} days.
	         Durations outside the range [1..${MAXDAYS}] days are not standards compliant.
	         The certificate will be generated as requested but it may not work.

	DAYSRANGECHECK

fi

# cache result
echo "${DAYS}" >"${WILDCARD_DAYS_CACHE}"

# does the server private key exist?
if [ -f "${WILDCARD_PRIVATE_KEY_PEM}" ] ; then

	# yes! use it
	echo "Using existing private key for the wildcard domain: ${WILDCARD_FQDN}"

else

	# no! generate one
	echo "Generating private key for the wildcard domain: ${WILDCARD_FQDN}"
	openssl genrsa -out "${WILDCARD_PRIVATE_KEY_PEM}" 4096

fi

# does a CSR exist?
if [ -f "${WILDCARD_SIGNING_REQUEST}" ] ; then

	echo "Using existing Certificate Signing Request (CSR)"

else

	echo "Generating Certificate Signing Request (CSR)"
	openssl req -new \
		-subj "/CN=${WILDCARD_FQDN}" \
		-addext "subjectAltName=DNS:${WILDCARD_FQDN},DNS:*.local" \
		-key "${WILDCARD_PRIVATE_KEY_PEM}" \
		-out "${WILDCARD_SIGNING_REQUEST}"

fi

# report what is happening depending on whether certificate already exists
[ -f "${WILDCARD_CERTIFICATE_PEM}" ] && echo -n "Updating" || echo -n "Generating"
echo " certificate for the wildcard domain: ${WILDCARD_FQDN}"

# create or update the server certificate, as appropriate
openssl x509 -req -sha256 \
	-CA "${CA_DIR}/${CA_CERTIFICATE_PEM}" \
	-CAkey "${CA_DIR}/${CA_PRIVATE_KEY_PEM}" \
	-CAcreateserial \
	-extensions a \
	-extfile <(echo "[a]
		basicConstraints=CA:FALSE
		subjectAltName=DNS:${WILDCARD_FQDN}
		keyUsage=digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment
		extendedKeyUsage=critical,serverAuth
	") \
	-days ${DAYS} \
	-in  "${WILDCARD_SIGNING_REQUEST}" \
	-out "${WILDCARD_CERTIFICATE_PEM}"

# debugging
if [ -n "${SSL_DEBUG}" ] ; then

	echo -e "\nDebug: Certificate Signing Request (lines with hex strings suppressed)\n"
	openssl req -noout -text -in "${WILDCARD_SIGNING_REQUEST}" | \
	egrep -v "[0-9A-Fa-f]{2,2}:[0-9A-Fa-f]{2,2}:" | \
	sed -e "s/^/  /"

	echo -e "\nDebug: Certificate (lines with hex strings suppressed)\n"
	openssl x509 -noout -text -in "${WILDCARD_CERTIFICATE_PEM}" | \
	egrep -v "[0-9A-Fa-f]{2,2}:[0-9A-Fa-f]{2,2}:" | \
	sed -e "s/^/  /"

fi
