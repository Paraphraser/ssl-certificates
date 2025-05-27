#!/bin/bash

# the name of this script is ...
SCRIPT=$(basename "${0}")

# certificate-lifetime parameters (in case of moving goal-posts)
DEFDAYS=730
MAXDAYS=825

# check parameters
if [ $# -lt 1 ] ; then

	cat <<-USAGE

	Usage: {DAYS=n} ${SCRIPT} hostname domain {name | IP ...}

	Examples: ${SCRIPT} server your.home.arpa
	          DAYS=${DEFDAYS} ${SCRIPT} server your.home.arpa
	          ${SCRIPT} server your.home.arpa othername 192.168.132.10

	USAGE

	exit 1

fi

# the first argument is the server host name
SERVER_HOSTNAME="${1}"

# the second argument is the domain
DOMAIN="${2}"

# we can infer the server's fully-qualified domain name
SERVER_FQDN="${SERVER_HOSTNAME}.${DOMAIN}"

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
SERVER_DIR="servers/${SERVER_HOSTNAME}"

# create SERVER_DIR if it does not exist
mkdir -p "${SERVER_DIR}"

# make it the working directory
cd "${SERVER_DIR}"

# SERVER_DIR may contain the following files
SERVER_PRIVATE_KEY_PEM="${SERVER_HOSTNAME}.key"
SERVER_SIGNING_REQUEST="${SERVER_HOSTNAME}.csr"
SERVER_CERTIFICATE_PEM="${SERVER_HOSTNAME}.crt"
SERVER_DAYS_CACHE=".days"
SUBJECT_ALT_NAMES_CACHE=".subject-alt-names"
SERVER_ARCHIVE="${SERVER_HOSTNAME}_etc-ssl.tar.gz"
ARCHIVE_CONTENTS=".contents"

# DAYS can be set from (1) environment (2) cache (3) default
DAYS=${DAYS:-$(cat "${SERVER_DAYS_CACHE}" 2>/dev/null)}
DAYS=${DAYS:-$DEFDAYS}

# validate days
DAYS=$((DAYS*1))
if [ ${DAYS} -lt 1 -o ${DAYS} -gt ${MAXDAYS} ] ; then

	cat <<-DAYSRANGECHECK

	Warning: Server certificate duration evaluates as ${DAYS} days.
	         Durations outside the range [1..${MAXDAYS}] days are not standards compliant.
	         The certificate will be generated as requested but it may not work.

	DAYSRANGECHECK

fi

# cache result
echo "${DAYS}" >"${SERVER_DAYS_CACHE}"

# assemble a default set of subject alternative names
SUBJECT_ALT_NAMES="DNS:${SERVER_HOSTNAME}"
# the fully-qualified domain name
SUBJECT_ALT_NAMES="${SUBJECT_ALT_NAMES},DNS:${SERVER_FQDN}"
# the multicast domain name
SUBJECT_ALT_NAMES="${SUBJECT_ALT_NAMES},DNS:${SERVER_HOSTNAME}.local"
# localhost for testing and containers
SUBJECT_ALT_NAMES="${SUBJECT_ALT_NAMES},DNS:localhost"

# are there any extra alternate names to be added?
if [ $# -ge 3 ] ; then
	# yes! iterate to append any special cases
	while [ $# -ge 3 ] ; do
		# does the argument look like an IPv4 address?
		if [[ "${3}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ; then
			# yes! treat it as such
			SUBJECT_ALT_NAMES="${SUBJECT_ALT_NAMES},IP:${3}"
		else
			# no! assume it's a hostname or a domain name
			SUBJECT_ALT_NAMES="${SUBJECT_ALT_NAMES},DNS:${3}"
		fi
		shift
	done
	# cache the result
	echo "${SUBJECT_ALT_NAMES}" >"${SUBJECT_ALT_NAMES_CACHE}"
else
	# no! try to load the previous complete set from cache
	CACHED_ALT_NAMES=$(cat "${SUBJECT_ALT_NAMES_CACHE}" 2>/dev/null)
	# accept the cached set if found
	[ -n "${CACHED_ALT_NAMES}" ] && SUBJECT_ALT_NAMES="${CACHED_ALT_NAMES}"
fi

# does the server private key exist?
if [ -f "${SERVER_PRIVATE_KEY_PEM}" ] ; then

	# yes! use it
	echo "Using existing private key for server: ${SERVER_HOSTNAME}"

else

	# no! generate one
	echo "Generating private key for server: ${SERVER_HOSTNAME}"
	openssl genrsa -out "${SERVER_PRIVATE_KEY_PEM}" 4096

fi

# does a CSR exist?
if [ -f "${SERVER_SIGNING_REQUEST}" ] ; then

	echo "Using existing Certificate Signing Request (CSR)"

else

	echo "Generating Certificate Signing Request (CSR)"
	openssl req -new \
		-subj "/CN=${SERVER_FQDN}" \
		-key "${SERVER_PRIVATE_KEY_PEM}" \
		-out "${SERVER_SIGNING_REQUEST}"

fi

# report what is happening depending on whether certificate already exists
[ -f "${SERVER_CERTIFICATE_PEM}" ] && echo -n "Updating" || echo -n "Generating"
echo " server certificate for: ${SERVER_FQDN}"

# create or update the server certificate, as appropriate
openssl x509 -req -sha256 \
	-CA "${CA_DIR}/${CA_CERTIFICATE_PEM}" \
	-CAkey "${CA_DIR}/${CA_PRIVATE_KEY_PEM}" \
	-CAcreateserial \
	-extensions a \
	-extfile <(echo "[a]
		basicConstraints=CA:FALSE
		subjectAltName=${SUBJECT_ALT_NAMES}
		keyUsage=digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment
		extendedKeyUsage=critical,serverAuth
	") \
	-days ${DAYS} \
	-in  "${SERVER_SIGNING_REQUEST}" \
	-out "${SERVER_CERTIFICATE_PEM}"

# above displays signature status and subject but the list of
# alternate names is an important confirmation too
openssl x509 \
	-ext subjectAltName \
	-noout \
	-in "${SERVER_CERTIFICATE_PEM}"

# construct a directory to hold the package
PACKAGE=$(mktemp -d)

# ensure temporary directory cleaned-up
termination_handler() {
	rm -rf "${PACKAGE}"
}
trap termination_handler EXIT

# copy files into place
cp  "${CA_DIR}/${CA_CERTIFICATE_PEM}" \
	"${SERVER_PRIVATE_KEY_PEM}" \
	"${SERVER_CERTIFICATE_PEM}"\
	"${PACKAGE}/."

# add key facts about the package contents
cat <<-FACTS >"${PACKAGE}/${ARCHIVE_CONTENTS}"
DOMAIN="${DOMAIN}"
CA_CERTIFICATE_PEM="${CA_CERTIFICATE_PEM}"
SERVER_CERTIFICATE_PEM="${SERVER_CERTIFICATE_PEM}"
SERVER_PRIVATE_KEY_PEM="${SERVER_PRIVATE_KEY_PEM}"
FACTS

# archive the package
tar -czf "${SERVER_ARCHIVE}" --no-xattrs -C "${PACKAGE}" .

# debugging
if [ -n "${SSL_DEBUG}" ] ; then

	echo -e "\nDebug: Certificate Signing Request (lines with hex strings suppressed)\n"
	openssl req -noout -text -in "${SERVER_SIGNING_REQUEST}" | \
	egrep -v "[0-9A-Fa-f]{2,2}:[0-9A-Fa-f]{2,2}:" | \
	sed -e "s/^/  /"

	echo -e "\nDebug: Certificate (lines with hex strings suppressed)\n"
	openssl x509 -noout -text -in "${SERVER_CERTIFICATE_PEM}" | \
	egrep -v "[0-9A-Fa-f]{2,2}:[0-9A-Fa-f]{2,2}:" | \
	sed -e "s/^/  /"

fi
