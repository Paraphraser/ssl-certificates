#!/bin/bash

# the name of this script is ...
SCRIPT=$(basename "${0}")

# discover the name of this host
SERVER_HOSTNAME="${SERVER_HOSTNAME:-$(hostname -s)}"

# ----------------------------------------------------------------------
# don't use sudo to launch but sudo needed by the script. For those
# following along at home, the main reason for embedding sudo rather
# than requiring the script to be launched by sudo is because of the
# problem this would create with the macOS keychain.
# ----------------------------------------------------------------------
# sense running as root
[ "${EUID}" -eq 0 ] \
	&& echo "This script can NOT be run using sudo." \
	&& exit 1

echo "Please enter your administrator password if prompted."


# ----------------------------------------------------------------------
# sense OS environment and check critical dependencies
# ----------------------------------------------------------------------
case "$(uname -s)" in

	"Linux" )
		IS_LINUX=true
		STAT_CMD="stat"
		. /etc/os-release
		! [ "$ID" = "debian" -o "$ID" = "ubuntu" ] \
		&& echo "Warning: This script has not been tested on ${ID}."
		if [ -z "$(sudo which update-ca-certificates)" ] ; then
			cat <<-DEPENDENCY

			Problem: this script has a dependency on the "update-ca-certificates"
			         command which is not present on your system. Please install
			         the "ca-certificates" package and try again.

			         See also https://github.com/millermatt/osca for a discussion
			         of which Linux distros support "ca-certificates".

			DEPENDENCY
			exit 1
		fi
	;;

	"Darwin" )
		IS_LINUX=false
		STAT_CMD="gstat"
		if [ -z "$(which "${STAT_CMD}")" ] ; then
			cat <<-DEPENDENCY

			Problem: this script has a dependency on the "${STAT_CMD}" command which is
			         not present on your system. The simplest way to get "${STAT_CMD}"
			         is to install the HomeBrew package "coreutils".

			DEPENDENCY
			exit 1
		fi
	;;

	*)
		echo "Error: $(uname -s) is not supported."
		exit 1
	;;

esac


# ----------------------------------------------------------------------
# usage check (no parameters supported)
# ----------------------------------------------------------------------

if [ $# -ne 0 ] ; then
	cat <<-USAGE

	Usage: {SERVER_HOSTNAME=«hostname»} ${SCRIPT}

	USAGE
	exit 1
fi


# ----------------------------------------------------------------------
# discover, unpack and assess the integrity of the installation package
# ----------------------------------------------------------------------

# the server package is expected to be at
SERVER_ARCHIVE="${SERVER_HOSTNAME}_etc-ssl.tar.gz"

# sense server package not present
if [ ! -f "${SERVER_ARCHIVE}" ] ; then
	cat <<-ARCHIVE

	Error: ${SERVER_ARCHIVE} not found in working directory.
	       Consider passing SERVER_HOSTNAME= to override.

	ARCHIVE
	exit 1
fi

# make a temporary directory to unpack into
SERVER_PACKAGE=$(mktemp -d)

# ensure temporary directory cleaned-up
termination_handler() {
	rm -rf "${SERVER_PACKAGE}"
}
trap termination_handler EXIT

# unpack
echo "Found ${SERVER_ARCHIVE} - unpacking..."
tar -xzf "${SERVER_ARCHIVE}" -C "${SERVER_PACKAGE}"

# the package is expected to contain a .contents file
SERVER_CONTENTS="${SERVER_PACKAGE}/.contents"

# sense contents file not present
[ ! -f "${SERVER_CONTENTS}" ] \
	&& echo "Error: ${SERVER_CONTENTS} not found in ${SERVER_ARCHIVE}." \
	&& exit 1

# contents present - source it
. "${SERVER_CONTENTS}"

# contents file is assumed to define
#	DOMAIN=					domain for host
#	CA_CERTIFICATE_PEM=		filename of domain certificate
#	SERVER_CERTIFICATE_PEM=	filename of server certificate
#	SERVER_PRIVATE_KEY_PEM=	filename of server private key

# check remaining expected contents of package
for F in "${CA_CERTIFICATE_PEM}" "${SERVER_CERTIFICATE_PEM}" "${SERVER_PRIVATE_KEY_PEM}" ; do
	[ ! -f "${SERVER_PACKAGE}/${F}" ] \
		&& echo "Error: ${SERVER_PACKAGE}/${F} not found in ${SERVER_ARCHIVE}." \
		&& exit 1
done

# check whether the certificate matches this host
MATCH=$(openssl x509 -noout -in "${SERVER_PACKAGE}/${SERVER_CERTIFICATE_PEM}" -checkhost "${SERVER_HOSTNAME}")

# does the certificate match?
if [[ "${MATCH}" == *"does NOT match certificate" ]] ; then 
	# no! abort
	echo "${MATCH}"
	exit 1
fi


# ----------------------------------------------------------------------
# install components
# ----------------------------------------------------------------------

# $1 path to reference directory (retreats along path to reference dir
# until it finds something that exists which, ultimately, might be "/")
copy_ownership_from() {
	local P="${1:-/}"
	while [ -n "${P}" ] ; do
		if [ -d "${P}" ] ; then
			echo "$(${STAT_CMD} -c "%u:%g" "${P}")"
			return 0
		fi
		P=$(dirname "${P}")
	done
	return 1
}

# $1 path to reference directory
# $2 default permissions if $1 does not exist
copy_mode_from() {
	if [ -d "${1}" ] ; then
		echo "$(${STAT_CMD} -c "%a" "${1}")"
	else
		echo "${2}"
	fi
}

# expected installation directory and sub-directories
LOCAL_SSL_DIR="/opt/local/etc/openssl"
LOCAL_CERTS_DIR="${LOCAL_SSL_DIR}/certs"
LOCAL_KEYS_DIR="${LOCAL_SSL_DIR}/private"

# ensure directories exist, create them if they don't, and make a best-
# efforts attempt to set correct ownership and permissions
if [ ! -d "${LOCAL_CERTS_DIR}" ] ; then
	sudo mkdir -p "${LOCAL_CERTS_DIR}"
	sudo chown "$(copy_ownership_from /etc/ssl/certs)" "${LOCAL_CERTS_DIR}"
	sudo chmod "$(copy_mode_from /etc/ssl/certs 755)" "${LOCAL_CERTS_DIR}"
fi

if [ ! -d "${LOCAL_KEYS_DIR}" ] ; then
	sudo mkdir -p "${LOCAL_KEYS_DIR}"
	sudo chown "$(copy_ownership_from /etc/ssl/private)" "${LOCAL_KEYS_DIR}"
	sudo chmod "$(copy_mode_from /etc/ssl/private 710)" "${LOCAL_KEYS_DIR}"
fi

# populate certs dir from package
sudo cp	"${SERVER_PACKAGE}/${CA_CERTIFICATE_PEM}" \
		"${SERVER_PACKAGE}/${SERVER_CERTIFICATE_PEM}" \
		"${LOCAL_CERTS_DIR}"

# set recommended permissions on files
sudo chmod 644 "${LOCAL_CERTS_DIR}/${CA_CERTIFICATE_PEM}"
sudo chmod 644 "${LOCAL_CERTS_DIR}/${SERVER_CERTIFICATE_PEM}"

# special-handling for the private key - try to fetch existing permissions
MODE=$(sudo gstat -c "%a" "${LOCAL_KEYS_DIR}/${SERVER_PRIVATE_KEY_PEM}" 2>/dev/null)

# set a default if the file does not exist
MODE=${MODE:-600}

# copy the private key into place
sudo cp	"${SERVER_PACKAGE}/${SERVER_PRIVATE_KEY_PEM}" "${LOCAL_KEYS_DIR}"

# set permissions
sudo chmod "${MODE}" "${LOCAL_KEYS_DIR}/${SERVER_PRIVATE_KEY_PEM}"

# generate symlinking commands. This is a bit of a hack. Writing the
# commands to a file means we get variable substitution (which won't
# happen on Linux if sudo is involved). Once the file has been created,
# we can pipe to a sudo-invoked shell. On exit, the working directory
# will be unchanged. Later, if this is macOS and we have to manipulate
# the user keychain, we won't be root.
cat <<-SUSHELL >"${SERVER_PACKAGE}/create_symlinks"
	cd "${LOCAL_CERTS_DIR}"
	ln -fs "${CA_CERTIFICATE_PEM}" "domain.crt"
	ln -fs "${SERVER_CERTIFICATE_PEM}" "localhost.crt"
	cd "${LOCAL_KEYS_DIR}"
	ln -fs "${SERVER_PRIVATE_KEY_PEM}" "localhost.key"
SUSHELL

# execute the symlinking commands
cat "${SERVER_PACKAGE}/create_symlinks" | sudo bash

cat <<-DOCKERSUPPORT
	The following files have been installed:
	   ${LOCAL_CERTS_DIR}
	     Domain certificate ${CA_CERTIFICATE_PEM}, symlinked as domain.crt
	     Server certificate ${SERVER_CERTIFICATE_PEM}, symlinked as localhost.crt
	   ${LOCAL_KEYS_DIR}
	     Server private key ${SERVER_PRIVATE_KEY_PEM}, symlinked as localhost.key
DOCKERSUPPORT


# ======================================================================
# Linux-specific domain certificate installation
# ======================================================================

if [ "$IS_LINUX" = "true" ] ; then

	# installation location
	SSL_CA_CERTS_DIR="/usr/local/share/ca-certificates"

	# check existence
	[ ! -d "${SSL_CA_CERTS_DIR}" ] \
	&& echo "Error: ${SSL_CA_CERTS_DIR} does not exist on this host." \
	&& exit 1

	# populate with CA certificate from package
	sudo cp	"${SERVER_PACKAGE}/${CA_CERTIFICATE_PEM}" \
			"${SSL_CA_CERTS_DIR}"

	echo "Domain certificate ${CA_CERTIFICATE_PEM} installed in ${SSL_CA_CERTS_DIR}."

	# CA certificates in place - get the system to take notice
	# (system already checked for the presence of update-ca-certificates)
	sudo update-ca-certificates --fresh

	echo "Installation of domain certificate ${CA_CERTIFICATE_PEM} is complete."

	# linux tasks end here
	exit 0

fi


# ======================================================================
# the script now falls through to macOS-specific installation steps
# ======================================================================

# ----------------------------------------------------------------------
# useful functions
# ----------------------------------------------------------------------

# Is **this** certificate already in the keychain?
# Matching occurs on the subject and serial number.
#
# $1 = domain certificate
isDomainCertificateInKeychain() {

	# fetch data from certificate
	local SUBJECT=$(openssl x509 -subject -noout -in "$1")
	local SERIAL=$(openssl x509 -serial -noout -in "$1")

	# reformat as search criteria
	local DOMAIN=${SUBJECT#subject=CN=}
	local SERIAL_MATCH="Serial Number: $((0x${SERIAL#serial=}))"

	# search keychain
	local COUNT=$( \
		security find-certificate -a -c "$DOMAIN" -p | \
		openssl storeutl -noout -text -certs /dev/stdin | \
		grep -c "$SERIAL_MATCH" \
	)

	# return true if non-zero count
	[ $COUNT -gt 0 ] && return 0

	# false otherwise
	return 1

}

# Count the number of certificates for this domain that are present in
# the keychain. The "security" utility performs a substring match (ie
# "your.home.arpa" will also match "host.your.home.arpa" so we export
# the certificates, convert to text, and go hunting for exact matches on
# the domain. Matching occurs on subject (eg "CN=your.home.arpa").
# 
# $1 = domain certificate
domainCertificatesInKeychain() {

	# fetch data from certificate
	local SUBJECT=$(openssl x509 -subject -noout -in "$1")

	# reformat as search criteria
	local DOMAIN=${SUBJECT#subject=CN=}
	local SUBJECT_MATCH="Subject: ${SUBJECT#subject=}"

	# search keychain
	local COUNT=$( \
		security find-certificate -a -c "$DOMAIN" -p | \
		openssl storeutl -noout -text -certs /dev/stdin | \
		grep -c "$SUBJECT_MATCH" \
	)

	# return the count
	echo $COUNT

}


# ----------------------------------------------------------------------
# set certificate linkages for command-line tools
# ----------------------------------------------------------------------

# $1 path to config file
# $2 directive to add
configure_cli_tool() {
	# ensure config file exists
	touch "${1}"
	if [ $(grep -c "^${2}" "${1}") -eq 0 ] ; then
		echo "${2}" >>"${1}"
		echo "Added \"${2}\" to ${1}"
	fi
}

configure_cli_tool "${HOME}/.wgetrc" "ca-certificate=${LOCAL_CERTS_DIR}/domain.crt"
configure_cli_tool "${HOME}/.curlrc" "--cacert ${LOCAL_CERTS_DIR}/domain.crt"

# ----------------------------------------------------------------------
# install domain certificate (macOS)
# ----------------------------------------------------------------------

# is this certificate in the keychain already?
if $(isDomainCertificateInKeychain "${SERVER_PACKAGE}/${CA_CERTIFICATE_PEM}") ; then

	# yes! explain that
	echo "Domain certificate ${CA_CERTIFICATE_PEM} already present in keychain."
	exit 0

fi

# find default keychain and de-quote the unhelpfully-quoted
# string. This always finds the default keychain for the actual
# user (ie not root even if this command is invoked via sudo).
# In most cases this will be the login keychain.
DEFAULT_KEYCHAIN=$(security default-keychain)
DEFAULT_KEYCHAIN=$(echo "${DEFAULT_KEYCHAIN}" | xargs)

# alert user
echo "Please respond to the security dialog on the Desktop..."

# add the certificate and mark it trusted (note: NOT with sudo)
security add-trusted-cert -k "${DEFAULT_KEYCHAIN}" "${SERVER_PACKAGE}/${CA_CERTIFICATE_PEM}"

# did the add-trusted-cert operation succeed?
if [ $? -eq 0 ] ; then

	# yes! count the certificates matching the domain
	COUNT=$(domainCertificatesInKeychain "${SERVER_PACKAGE}/${CA_CERTIFICATE_PEM}")

	# does it look like there are now potential duplicate domain certificates?
	if [ $COUNT -gt 1 ] ; then

		# yes! fetch expiry date of certificate just added
		CERT_EXPIRES="$(openssl x509 -enddate -noout -in "${SERVER_PACKAGE}/${CA_CERTIFICATE_PEM}")"
		
		# remove prefix
		CERT_EXPIRES=${CERT_EXPIRES#notAfter=}

		# convert to local time if possible (gdate from brew install coreutils)
		[ -n "$(which gdate)" ] && CERT_EXPIRES=$(gdate --date="${CERT_EXPIRES}")

		# emit a note
		cat <<-REVIEWCERTS

		Note: your default keychain now contains ${COUNT} certificates matching "${DOMAIN}".
		      It is not safe for scripts to automate removal of duplicate, obsolete
		      or expired certificates. This is something you will need to do by hand using
		      the "Keychain Access" application. The certificate just installed expires:

				 ${CERT_EXPIRES}

		REVIEWCERTS

	fi

else

	# no! probably a user cancellation
	echo "Installation of domain certificate ${CA_CERTIFICATE_PEM} could not be completed."
	exit 1

fi

echo "Installation of domain certificate ${CA_CERTIFICATE_PEM} is complete."
