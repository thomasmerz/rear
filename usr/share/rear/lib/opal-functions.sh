#
# TCG Opal 2 functions to manage self-encrypting disks
#
# These functions are meant to be used within ReaR as well as independently. Functions do not rely on any external
# code unless otherwise stated. Return codes must be checked by the caller.
#
# References:
# - TCG Storage Opal SSC Specification Version 2.01 [Opal 2 spec]
#   https://trustedcomputinggroup.org/wp-content/uploads/TCG_Storage-Opal_SSC_v2.01_rev1.00.pdf
# - DTA sedutil Self encrypting drive software
#   https://github.com/Drive-Trust-Alliance/sedutil
#
# Notes:
# - In Opal, different authorities with different passwords are responsible for device administration and locking.
#   To avoid confusion we always use (and expect) identical passwords for
#     1. the SID (Security ID) as the authority of the Administrative Security Provider, and
#     2. the Admin1 user as the authority of the Locking Security Provider.
# - sedutil-cli outputs messages geared towards developers on failure. Use redirection to hide such messages
#   from users and display meaningful user-tailored messages after checking return codes.


function opal_devices() {
    # prints a list of TCG Opal 2-compliant devices.

    sedutil-cli --scan | awk '$1 ~ /\/dev\// && $2 ~ /2/ { print $1; }'
}

function opal_device_attributes() {
    local device="${1:?}"
    local result_variable_name="${2:?}"
    # returns a script assigning the Opal device's attributes to a local array variable:
    #   model=..., firmware=..., serial=..., interface=...
    #   setup=[yn], locked=[yn], encrypted=[yn], mbr={visible,hidden,disabled},
    #
    # Usage example:
    #   source "$(opal_device_attributes "$device")" attributes
    #   if [[ "${attributes[setup]}" == "y" ]]; then ...

    local result_script="$(mktemp)"

    {
        echo -n "local -A $result_variable_name=( "
        sedutil-cli --query "$device" | awk '
            /^\/dev\// {
                gsub(/[$"]/, "*");  # strip characters interpreted by bash if part of a double-quoted string
                sub(/^\/dev\/[^ ]+ +/, "");  # strip device field from $0
                printf("[serial]=\"%s\" ", $(NF));
                printf("[firmware]=\"%s\" ", $(NF-1));
                sub(/ +[^ ]+ +[^ ]+ *$/, "");  # strip serial and firmware fields from $0
                printf("[interface]=\"%s\" ", $1);
                sub(/^[^ ]+ +/, "");  # strip type field from $0
                printf("[model]=\"%s\" ", $0);
            }
            /^Locking function \(0x0002\)/ {
                getline;
                gsub(/ /, "");
                split($0, field_assignments, ",");
                for (field_assignment_index in field_assignments) {
                    split(field_assignments[field_assignment_index], assignment_parts, "=");
                    raw_fields[assignment_parts[1]] = assignment_parts[2];
                }
                printf("[setup]=\"%s\" ", tolower(raw_fields["LockingEnabled"]));
                printf("[locked]=\"%s\" ", tolower(raw_fields["Locked"]));
                printf("[encrypted]=\"%s\" ", tolower(raw_fields["MediaEncrypt"]));
                printf("[mbr]=\"%s\" ", (raw_fields["MBREnabled"] == "Y" ? (raw_fields["MBRDone"] == "Y" ? "hidden" : "visible") : "disabled"));
            }
        '
        echo -e ")\nrm \"$result_script\""
    } > "$result_script"
    echo "$result_script"
}

function opal_device_attribute() {
    local device="${1:?}"
    local attribute_name="${2:?}"
    # prints the value of an Opal device attribute

    source "$(opal_device_attributes "$device" attributes)"
    echo "${attributes[$attribute_name]}"
}

function opal_device_identification() {
    local device="${1:?}"
    # prints identification information for an Opal device

    source "$(opal_device_attributes "$device" attributes)"
    echo "${attributes["model"]:-?}, interface: ${attributes["interface"]:-?}"
}

function opal_device_max_authentications() {
    local device="${1:?}"
    # prints the maximum number of authentication attempts for the device.
    # When the maximum number of authentication attempts has been reached, an Opal device needs to be power-cycled
    # before accepting any further authentications.

    sedutil-cli --query "$device" | sed -r -e '/MaxAuthentications/ { s/.*MaxAuthentications *= *([0-9]+).*/\1/; p }' -e 'd'
}

function opal_device_setup() {
    local device="${1:?}"
    local password="${2:?}"
    # enables Opal locking, sets an Admin1 and SID password, disables the MBR.
    # Returns 0 on success.

    sedutil-cli --initialSetup "$password" "$device" && opal_device_disable_mbr "$device" "$password"
}

function opal_device_change_password() {
    local device="${1:?}"
    local old_password="${2:?}"
    local new_password="${3:?}"
    # sets a new Admin1 and SID password, returns 0 on success

    sedutil-cli --setSIDPassword "$old_password" "$new_password" "$device" &&
    sedutil-cli --setAdmin1Pwd "$old_password" "$new_password" "$device"
}

function opal_device_regenerate_dek_ERASING_ALL_DATA() {
    local device="${1:?}"
    local password="${2:?}"
    # re-generates the manufacturer-assigned data encryption key (DEK), ERASING ALL DATA ON THE DRIVE.
    # This is recommended initially to ensure that the data encryption key is not known by any third party.
    # Returns 0 on success.

    sedutil-cli --rekeyLockingRange 0 "$password" "$device" && partprobe "$device"
}

function opal_device_factory_reset_ERASING_ALL_DATA() {
    local device="${1:?}"
    local password="${2:?}"
    # factory-resets the device, ERASING ALL DATA ON THE DRIVE, returns 0 on success

    sedutil-cli --reverttper "$password" "$device" && partprobe "$device"
}

function opal_device_load_pba_image() {
    local device="${1:?}"
    local password="${2:?}"
    local pba_image_file="${3:?}"
    # loads a PBA image into the device's shadow MBR, returns 0 on success.

    sedutil-cli --loadPBAimage "$password" "$pba_image_file" "$device" >&7  # show progress
}

function opal_device_mbr_is_enabled() {
    local device="${1:?}"
    # returns 0 if the device's shadow MBR has been enabled.

    [[ "$(opal_device_attribute "$device" "mbr")" != "disabled" ]]
}

function opal_device_disable_mbr() {
    local device="${1:?}"
    local password="${2:?}"
    # disables the device's shadow MBR, returns 0 on success

    sedutil-cli --setMBREnable off "$password" "$device" && partprobe "$device"
}

function opal_device_enable_mbr() {
    local device="${1:?}"
    local password="${2:?}"
    # enables the device's shadow MBR in hidden mode, returns 0 on success

    sedutil-cli --setMBREnable on "$password" "$device" && opal_device_hide_mbr "$device" "$password"
}

function opal_device_hide_mbr() {
    local device="${1:?}"
    local password="${2:?}"
    # hides the device's shadow MBR if one has been enabled, does nothing otherwise.
    # Returns 0 on success.

    sedutil-cli --setMBRDone on "$password" "$device" && partprobe "$device"
}

function opal_device_unlock() {
    local device="${1:?}"
    local password="${2:?}"
    # attempts to unlock the device (locking range 0 spanning the entire disk) and hide the MBR, if any.
    # Returns 0 on success.

    sedutil-cli --setLockingRange 0 RW "$password" "$device" && opal_device_hide_mbr "$device" "$password"
}

function opal_bytes_to_mib() {
    local bytes="${1:?}"
    # prints bytes converted to MiB with two decimal digits.

    bc <<< "scale=2; $bytes / (1024 * 1024)"
}

function opal_local_pba_image_file() {
    # prints the path of a local TCG Opal 2 PBA image file, if available, else nothing

    if [[ -n "$OPALPBA_URL" ]]; then
        local image_base_scheme="$(url_scheme "$OPALPBA_URL")"
        local image_base="$(url_path "$OPALPBA_URL")"
        local image_file_path="$image_base/$HOSTNAME/TCG-Opal-PBA-$HOSTNAME.raw"

        if [[ "$image_base_scheme" == "file" && -f "$image_file_path" ]]; then
            # If a local image file exists, use it
            opal_check_pba_image "$image_file_path"
            echo "$image_file_path"
        fi
    fi
}

function opal_check_pba_image() {
    local pba_image_file="${1:?}"
    # generates an error if the PBA image is larger than the guaranteed MBR capacity.
    # REQUIRES ReaR function 'Error'

    [[ -f "$pba_image_file" ]] || Error "\"$pba_image_file\" is not a regular file, thus cannot be used as TCG Opal 2 PBA image"

    local -i file_size=$(stat --printf="%s\n" "$pba_image_file")
    local -i mbr_size_limit=$((128 * 1024 * 1024))  # guaranteed minimum MBR size: 128 MiB (Opal 2 spec, section 4.3.5.4)

    if (( file_size > mbr_size_limit )); then
        Error "TCG Opal 2 PBA image file \"$pba_image_file\" is $(opal_bytes_to_mib $file_size) MiB in size, allowed maximum is $(opal_bytes_to_mib $mbr_size_limit) MiB"
    fi
}

function opal_disk_partition_information() {
    local device="${1:?}"
    # prints disk and partition information.

    lsblk --fs --output NAME,MOUNTPOINT,FSTYPE,SIZE "$device"
}

function opal_disk_has_partitions() {
    local device="${1:?}"
    # returns 0 if the disk has one or more partitions.

    blkid "$device" | grep --quiet .
}

function opal_disk_has_mounted_partitions() {
    local device="${1:?}"
    # returns 0 if the disk has one or more mounted partitions.

    lsblk -l --fs --output MOUNTPOINT --noheadings "$device" | grep --quiet .
}
