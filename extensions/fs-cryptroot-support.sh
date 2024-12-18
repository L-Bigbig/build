# `cryptroot` / LUKS support is no longer included by default in prepare-host.sh.
# Enable this extension to include the required dependencies for building.
# This is automatically enabled if CRYPTROOT_ENABLE is set to yes in main-config.sh.

function add_host_dependencies__add_cryptroot_tooling() {
	display_alert "Extension: ${EXTENSION}: Adding packages to host dependencies" "cryptsetup openssh-client" "info"
	EXTRA_BUILD_DEPS="${EXTRA_BUILD_DEPS} cryptsetup openssh-client" # @TODO: convert to array later
}

function extension_prepare_config__prepare_cryptroot() {
	display_alert "Extension: ${EXTENSION}: Adding extra packages to image" "cryptsetup cryptsetup-initramfs" "info"
	add_packages_to_image cryptsetup cryptsetup-initramfs

	# Config for cryptroot, a boot partition is required.
	declare -g BOOTPART_REQUIRED=yes
	EXTRA_IMAGE_SUFFIXES+=("-crypt")

	if [[ $CRYPTROOT_SSH_UNLOCK == yes ]]; then
		display_alert "Extension: ${EXTENSION}: Adding extra packages to image" "dropbear-initramfs" "info"
		add_packages_to_image dropbear-initramfs
	fi
}

function prepare_root_device__250_encrypt_root_device() {
	# We encrypt the rootdevice (currently a loop device) and return the new mapped rootdevice
	check_loop_device "$rootdevice"
	display_alert "Extension: ${EXTENSION}: Encrypting root partition with LUKS..." "cryptsetup luksFormat $rootdevice" ""
	echo -n $CRYPTROOT_PASSPHRASE | cryptsetup luksFormat $CRYPTROOT_PARAMETERS $rootdevice -
	echo -n $CRYPTROOT_PASSPHRASE | cryptsetup luksOpen $rootdevice $CRYPTROOT_MAPPER -
	add_cleanup_handler cleanup_cryptroot
	display_alert "Extension: ${EXTENSION}: Root partition encryption complete." "" "ext"
	# TODO: pass /dev/mapper to Docker
	rootdevice=/dev/mapper/$CRYPTROOT_MAPPER # used by `mkfs` and `mount` commands
}

function pre_install_kernel_debs__adjust_dropbear_configuration() {
	# Adjust initramfs dropbear configuration
	# Needs to be done before kernel installation, else it won't be in the initrd image
	if [[ $CRYPTROOT_SSH_UNLOCK == yes ]]; then
		declare dropbear_dir="${SDCARD}/etc/dropbear-initramfs"
		declare dropbear_config="config"

		if [[ -d "${SDCARD}/etc/dropbear/initramfs" ]]; then
			dropbear_dir="${SDCARD}/etc/dropbear/initramfs"
			dropbear_config="dropbear.conf"
		fi

		# Set the port of the dropbear ssh daemon in the initramfs to a different one if configured
		# this avoids the typical 'host key changed warning' - `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`
		[[ -f "${dropbear_dir}/${dropbear_config}" ]] &&
			sed -i "s/^#DROPBEAR_OPTIONS=.*/DROPBEAR_OPTIONS=\"-I 100 -j -k -p "${CRYPTROOT_SSH_UNLOCK_PORT}" -s -c cryptroot-unlock\"/" \
				"${dropbear_dir}/${dropbear_config}"

		# setup dropbear authorized_keys, either provided by userpatches or generated
		if [[ -f $USERPATCHES_PATH/dropbear_authorized_keys ]]; then
			cp "$USERPATCHES_PATH"/dropbear_authorized_keys "${dropbear_dir}"/authorized_keys
		else
			# generate a default ssh key for login on dropbear in initramfs
			# this key should be changed by the user on first login
			display_alert "Extension: ${EXTENSION}: Generating a new SSH key pair for dropbear (initramfs)" "" ""

			# Generate the SSH keys
			ssh-keygen -t ecdsa -f "${dropbear_dir}"/id_ecdsa \
				-N '' -O force-command=cryptroot-unlock -C 'AUTOGENERATED_BY_ARMBIAN_BUILD' 2>&1

			# /usr/share/initramfs-tools/hooks/dropbear will automatically add 'id_ecdsa.pub' to authorized_keys file
			# during mkinitramfs of update-initramfs
			#cat "${dropbear_dir}"/id_ecdsa.pub > "${SDCARD}"/etc/dropbear-initramfs/authorized_keys


			# copy it a) later via hook to make use of a proper naming / structural equal -> "${DESTIMG}/${version}.img"
			CRYPTROOT_SSH_UNLOCK_KEY_NAME="${VENDOR}_${REVISION}_${BOARD^}_${RELEASE}_${BRANCH}_${DESKTOP_ENVIRONMENT}".key
			# copy dropbear ssh key to image output dir for convenience
			cp "${dropbear_dir}"/id_ecdsa "${DEST}/images/${CRYPTROOT_SSH_UNLOCK_KEY_NAME}"
			display_alert "Extension: ${EXTENSION}: SSH private key for dropbear (initramfs) has been copied to:" \
				"$DEST/images/$CRYPTROOT_SSH_UNLOCK_KEY_NAME" "info"
		fi
	fi
}

function post_umount_final_image__750_cryptroot_cleanup(){
	execute_and_remove_cleanup_handler cleanup_cryptroot
}

function cleanup_cryptroot(){
	cryptsetup luksClose "${CRYPTROOT_MAPPER}" 2>&1
	display_alert "Cryptroot closed ${CRYPTROOT_MAPPER}" "${EXTENSION}" "info"
}