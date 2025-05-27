#!/bin/bash

# the name of this script is ...
SCRIPT=$(basename "${0}")

# discover the domain associated with this host
DOMAIN="${DOMAIN:-$(hostname -d)}"

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

	Usage: {DOMAIN=«domain»} ${SCRIPT}

	USAGE
	exit 1
fi


# ----------------------------------------------------------------------
# discover, unpack and assess the integrity of the installation package
# ----------------------------------------------------------------------

# the domain certificate is expected to be at
CA_CERTIFICATE_PEM="${DOMAIN}.crt"

# sense certificate file not present
if [ ! -f "${CA_CERTIFICATE_PEM}" ] ; then
	cat <<-CERTFILE

	Error: ${CA_CERTIFICATE_PEM} not found in working directory.
	       Consider passing DOMAIN= to override.

	CERTFILE
	exit 1
fi

# check whether the certificate matches the expected domain
MATCH=$(openssl x509 -noout -in "${CA_CERTIFICATE_PEM}" -checkhost "${DOMAIN}")

# does the certificate match?
if [[ "${MATCH}" == *"does NOT match certificate" ]] ; then 
	# no! abort
	echo "${MATCH}"
	exit 1
fi


# ----------------------------------------------------------------------
# update anything in /opt/local/etc/openssl
# ----------------------------------------------------------------------

# expected installation directory
LOCAL_CERTS_DIR="/opt/local/etc/openssl/certs"

# is there a pre-existing domain certificate
if [ -f "${LOCAL_CERTS_DIR}/${CA_CERTIFICATE_PEM}" ] ; then

	# yes! replace it
	sudo cp "${CA_CERTIFICATE_PEM}" "${LOCAL_CERTS_DIR}/${CA_CERTIFICATE_PEM}"
	sudo chmod 644 "${LOCAL_CERTS_DIR}/${CA_CERTIFICATE_PEM}"
	echo "Domain certificate ${CA_CERTIFICATE_PEM} replaced in ${LOCAL_CERTS_DIR}."

fi

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

	# populate with CA certificate
	sudo cp	"${CA_CERTIFICATE_PEM}" "${SSL_CA_CERTS_DIR}"

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
		echo "Added \"${2}\" to ${1}."
	fi
}

configure_cli_tool "${HOME}/.wgetrc" "ca-certificate=${LOCAL_CERTS_DIR}/domain.crt"
configure_cli_tool "${HOME}/.curlrc" "--cacert ${LOCAL_CERTS_DIR}/domain.crt"

# ----------------------------------------------------------------------
# install domain certificate (macOS)
# ----------------------------------------------------------------------

# is this certificate in the keychain already?
if $(isDomainCertificateInKeychain "${CA_CERTIFICATE_PEM}") ; then

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
security add-trusted-cert -k "${DEFAULT_KEYCHAIN}" "${CA_CERTIFICATE_PEM}"

# did the add-trusted-cert operation succeed?
if [ $? -eq 0 ] ; then

	# yes! count the certificates matching the domain
	COUNT=$(domainCertificatesInKeychain "${CA_CERTIFICATE_PEM}")

	# does it look like there are now potential duplicate domain certificates?
	if [ $COUNT -gt 1 ] ; then

		# yes! fetch expiry date of certificate just added
		CERT_EXPIRES="$(openssl x509 -enddate -noout -in "${CA_CERTIFICATE_PEM}")"
		
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
