#!/bin/bash

# the name of this script is ...
SCRIPT=$(basename "${0}")

# certificate-lifetime parameters (in case of moving goal-posts)
DEFDAYS=3650
# MAXDAYS=not used in this script - there does not seem to be a maximum

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

# the domain directory is
DOMAIN_DIR="${PWD}/${DOMAIN}"
GIT_IGNORE="${DOMAIN_DIR}/.gitignore"

# and the CA dir is
CA_DIR="${DOMAIN_DIR}/CA"

# create any CA_DIR components if they do not exist
mkdir -p "${CA_DIR}"

# it's a good idea to the domain directory from git (but never overwrite
# because the user may comment-out the wildcard)
[ -f "${GIT_IGNORE}" ] || echo "*" >"${GIT_IGNORE}"

# make the CA directory the working directory
cd "${CA_DIR}"

# CA_DIR may contain the following files
CA_PRIVATE_KEY_PEM="${DOMAIN}.key"
CA_CERTIFICATE_PEM="${DOMAIN}.crt"
CA_CERTIFICATE_DER="${DOMAIN}.der"
CA_DAYS_CACHE=".days"

# DAYS can be set from (1) environment (2) cache (3) default
DAYS=${DAYS:-$(cat "${CA_DIR}/${CA_DAYS_CACHE}" 2>/dev/null)}
DAYS=${DAYS:-$DEFDAYS}

# validate days
DAYS=$((DAYS*1))
if [ ${DAYS} -lt 1 ] ; then
	echo "Error: requested CA certificate duration should be at least 1 day."
	exit 1
fi

# cache result
echo "${DAYS}" >"${CA_DIR}/${CA_DAYS_CACHE}"

# does the CA private key exist?
if [ -f "${CA_PRIVATE_KEY_PEM}" ] ; then

	# yes! use it
	echo "Using existing private key for your Certificate Authority"

else

	# no! generate one
	echo "Generating a private key for your Certificate Authority"
	openssl genrsa -out "${CA_PRIVATE_KEY_PEM}" 4096

fi

# construct a serial number for the certificate (needed on the CA
# certificate to help check for macOS keychain duplicates)
SERIAL=$(date "+%Y%m%d%H%M%S")

# report what is happening depending on whether a certificate already exists
[ -f "${CA_CERTIFICATE_PEM}" ] && echo -n "Updating" || echo -n "Generating"
echo " self-signed root certificate for the domain: ${DOMAIN}"

# create or update the CA certificate, as appropriate
openssl req -new -x509 -sha256 \
	-subj "/CN=${DOMAIN}" \
	-set_serial ${SERIAL} \
	-config <(echo "[req]
		x509_extensions = v3_ca
		[v3_ca]
		subjectKeyIdentifier=hash
		authorityKeyIdentifier=keyid:always,issuer
		basicConstraints=critical,CA:TRUE
		keyUsage=critical,digitalSignature,cRLSign,keyCertSign
	") \
	-days ${DAYS} \
	-key "${CA_PRIVATE_KEY_PEM}" \
	-out "${CA_CERTIFICATE_PEM}"

# exit pn certificate failure
[ $? -ne 0 ] && exit 1

# convert PEM-format certificate to DER-format as a convenience
openssl x509 \
	-inform pem \
	-in "${CA_CERTIFICATE_PEM}" \
	-outform der \
	-out "${CA_CERTIFICATE_DER}" 

# debugging
if [ -n "${SSL_DEBUG}" ] ; then

	echo -e "\nDebug: Certificate (lines with hex strings suppressed)\n"
	openssl x509 -noout -text -in "${CA_CERTIFICATE_PEM}" | \
	egrep -v "[0-9A-Fa-f]{2,2}:[0-9A-Fa-f]{2,2}:" | \
	sed -e "s/^/  /"

fi
