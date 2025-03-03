#!/bin/bash

# Check if running as root or with sudo
if [[ $EUID -ne 0 ]]; then
    echo "Please run this script as root or use sudo."
    exit 1
fi

# Check for prerequisites
if ! command -v lsblk &> /dev/null; then
    echo "lsblk is required. Install using apt install util-linux"
    exit 1
fi
if ! command -v hdparm &> /dev/null; then
    echo "hdparm is required. Install using apt install hdparm"
    exit 1
fi
if ! command -v nvme &> /dev/null; then
    echo "nvme-cli is required. Install using apt install nvme-cli"
    exit 1
fi
if ! command -v badblocks &> /dev/null; then
    echo "badblocks is required. Install using apt install e2fsprogs"
    exit 1
fi

# Get list of drives
drive_list=($(lsblk -d -o NAME | tail -n +2))
nvme_list=($(nvme list | awk '/^\/dev/ { print $1 }'))

# Initialize variables
drive_num=1
choice=0

# Main menu
while true; do
    clear

    # List available drives
    echo "Available drives:"
    for i in "${!drive_list[@]}"; do 
        echo "$((i+1)). /dev/${drive_list[$i]} $(cat /sys/block/${drive_list[$i]}/device/model)"
    done
    echo
    echo "NVMe drives:"
    for i in "${!nvme_list[@]}"; do 
        echo "$((i+1)). ${nvme_list[$i]}"
    done
    echo
    echo "Enter the number of the drive you want to erase:"

    read -r drive_num
    if [ "$drive_num" == 0 ]; then
	echo "Invalid choice. Please try again."
	sleep 1
	continue
    fi
    if [ -z "${drive_list[$((drive_num-1))]}" ]; then
	echo "Invalid choice. Please try again."
	sleep 1
	continue
    fi

    # Check if drive is frozen and unfreeze
    frozen_state=$(hdparm -I "/dev/${drive_list[$((drive_num-1))]}" 2>/dev/null | awk '/frozen/ { print $1,$2 }')
    if [ "${frozen_state}" == "frozen " ]; then
        echo "The selected drive appears to be frozen."
        echo "How would you like to unfreeze the drive?"
        echo "1. Run 'rtcwake -m mem -s 5' to unfreeze"
        echo "2. Physically disconnect and reconnect the drive"
        read -r choice
        if [ "$choice" -eq 1 ]; then
            sh -c "rtcwake -m mem -s 5"
        elif [ "$choice" -eq 2 ]; then
            echo "Please physically disconnect and reconnect the drive."
            read -rp "Hit enter key to continue..."
        fi
    fi

# Special verification routine for secure erase choices 1 and 2

verify_secure(){
while [[ $choice -ne 3 ]]; do
    # Select verification method
    echo
    echo "Select a verification method:"
    echo "1. Quick Erasure Verification"
    echo "2. Full Erasure Verification"
    echo "3. No verification"
    read -r choice
    if [ "$choice" -eq 1 ]; then
        badblocks -b 1048576 -sv -t 0x00 /dev/$new_drive 10 0
	exit
    elif [ "$choice" -eq 2 ]; then
        badblocks -b 1048576 -sv -t 0x00 /dev/$new_drive
	exit
    elif [ "$choice" -eq 3 ]; then
        echo "No verification selected."
	exit
    else
        echo "Invalid choice. Please try again."
	sleep 1
	continue
    fi
done
}

    # Display erase methods
    hdparm -I "/dev/${drive_list[$((drive_num-1))]}" | grep -i "security erase"
    echo
    echo "Select an erase method:"
    echo "1. Secure Erase (for PATA and SATA drives)"
    echo "2. Secure Erase Enhanced (for PATA and SATA drives)"
    echo "3. NVMe Sanitize (for NVMe drives)"
    echo "4. NVMe Format (for NVMe drives)"
    echo "5. blkdiscard (for any SSD device supporting TRIM)"
    echo "6. nwipe (must be installed separately)"
    echo "7. Exit"
    read -r choice

    # Perform selected erase method
    if [ "$choice" -eq 1 ]; then
	echo
	echo "Please wait, drive is erasing."
	echo
	drive_inquiry=$(tr -d '\0' < "/sys/block/${drive_list[$((drive_num-1))]}/device/inquiry")
        hdparm --user-master u --security-set-pass "p" "/dev/${drive_list[$((drive_num-1))]}"
        hdparm --user-master u --security-erase "p" "/dev/${drive_list[$((drive_num-1))]}"
        new_drive=""
        while [ -z "$new_drive" ]; do
            for check_drive in /sys/block/sd*/device/inquiry; do
                if [ "$(tr -d '\0' < "$check_drive")" == "$drive_inquiry" ]; then
                    new_drive=$(echo $check_drive|awk -F / '{print $4}')
                    break
                fi
            done
            sleep 1
        done
	verify_secure
    elif [ "$choice" -eq 2 ]; then
	echo
	echo "Please wait, drive is erasing."
	echo
	drive_inquiry=$(tr -d '\0' < "/sys/block/${drive_list[$((drive_num-1))]}/device/inquiry")
        hdparm --user-master u --security-set-pass "p" "/dev/${drive_list[$((drive_num-1))]}"
        hdparm --user-master u --security-erase-enhanced "p" "/dev/${drive_list[$((drive_num-1))]}"
        new_drive=""
        while [ -z "$new_drive" ]; do
            for check_drive in /sys/block/sd*/device/inquiry; do
                if [ "$(tr -d '\0' < "$check_drive")" == "$drive_inquiry" ]; then
                    new_drive=$(echo $check_drive|awk -F / '{print $4}')
                    break
                fi
            done
            sleep 1
        done
	verify_secure
    elif [ "$choice" -eq 3 ]; then
        nvme sanitize -a 2 "/dev/${drive_list[$((drive_num-1))]}"
        errorlevel=$?
        if [ ${errorlevel} -eq 0 ]; then
            echo "Watch SPROG and SSTAT, once it is finished SPROG should be 65535 and SSTAT should be 0x101"
            echo "Hit ctrl-c when this is the case"
            read -rp "Hit enter key to continue..."
            watch -n 1 nvme sanitize-log "/dev/${drive_list[$((drive_num-1))]}" -H
        fi
    elif [ "$choice" -eq 4 ]; then
        nvme format "/dev/${drive_list[$((drive_num-1))]}" -s 1
    elif [ "$choice" -eq 5 ]; then
        echo "Trying secure blkdiscard first"
        blkdiscard -s -f "/dev/${drive_list[$((drive_num-1))]}"
        errorlevel=$?
        if [ ${errorlevel} -ne 0 ]; then
            blkdiscard -f "/dev/${drive_list[$((drive_num-1))]}"
        fi
    elif [ "$choice" -eq 6 ]; then
        nwipe --autonuke --noblank --nowait --verify=off -m zero "/dev/${drive_list[$((drive_num-1))]}"
        # dd if=/dev/zero of="/dev/${drive_list[$((drive_num-1))]}" bs=1M status=progress oflag=direct
    elif [ "$choice" -eq 7 ]; then
        echo "Exiting..."
        exit 0
    else
        echo "Invalid choice. Please try again."
	sleep 1
        continue
    fi

while [[ $choice -ne 3 ]]; do
    # Select verification method
    echo
    echo "Select a verification method:"
    echo "1. Quick Erasure Verification"
    echo "2. Full Erasure Verification"
    echo "3. No verification"
    read -r choice
    if [ "$choice" -eq 1 ]; then
        badblocks -b 1048576 -sv -t 0x00 "/dev/${drive_list[$((drive_num-1))]}" 10 0
	exit
    elif [ "$choice" -eq 2 ]; then
        badblocks -b 1048576 -sv -t 0x00 "/dev/${drive_list[$((drive_num-1))]}"
	exit
    elif [ "$choice" -eq 3 ]; then
        echo "No verification selected."
	exit
    else
        echo "Invalid choice. Please try again."
	sleep 1
	continue
    fi
done
done
