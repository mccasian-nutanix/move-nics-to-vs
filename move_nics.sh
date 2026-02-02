#!/bin/bash

: ' # Description
    File Name   : move_nics.sh
    Author      : Casian Merce
    Version     : 1.0
    Requires    :
    Created     : 23.01.2026
    LastEdited  : 02.02.2026
'

# --- 1. Handle Cluster Argument ---
CLUSTER=""
while getopts "c:" opt; do
  case $opt in
    c) CLUSTER="$OPTARG" ;;
    *) echo "Usage: $0 -c <cluster_fqdn>"; exit 1 ;;
  esac
done

if [ -z "$CLUSTER" ]; then
    read -p "Enter Cluster FQDN or IP: " CLUSTER
fi

# Added -n to SSH_CMD to prevent stdin hijacking globally
SSH_CMD="ssh -n -q -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null nutanix@$CLUSTER"
ACLI_PATH="/usr/local/nutanix/bin/acli"

echo "Connecting to $CLUSTER..."

# --- 2. Fetch Virtual Switches and Interactive Selection ---
echo "Fetching virtual switches..."
vs_output=$($SSH_CMD "$ACLI_PATH net.list_virtual_switch")

if [ -z "$vs_output" ]; then
    echo "Error: Could not retrieve virtual switch list. Check connectivity/permissions."
    exit 1
fi

# Parse virtual switch names (skip header) - compatible method
vs_names=()
while IFS= read -r line; do
    vs_names+=("$line")
done < <(echo "$vs_output" | awk 'NR>1 {print $1}' | sort)

if [ ${#vs_names[@]} -lt 2 ]; then
    echo "Error: At least 2 virtual switches are required."
    exit 1
fi

# Function for interactive menu using arrow keys
select_vswitch() {
    local prompt="$1"
    local type="$2"
    local selected=0
    local key=""
    
    # Hide cursor
    tput civis > /dev/tty
    
    while true; do
        # Clear screen and show menu (output to tty so it's visible during command substitution)
        clear > /dev/tty
        echo "$prompt" > /dev/tty
        echo "Use ↑/↓ arrow keys to navigate, Enter to select" > /dev/tty
        echo "================================================" > /dev/tty
        echo "" > /dev/tty
        
        # Display options
        for i in "${!vs_names[@]}"; do
            if [ $i -eq $selected ]; then
                echo "→ ${vs_names[$i]}" > /dev/tty
            else
                echo "  ${vs_names[$i]}" > /dev/tty
            fi
        done
        
        # Read input
        IFS= read -rsn1 key 2>/dev/null < /dev/tty
        
        # Check for escape sequence (arrow keys)
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key 2>/dev/null < /dev/tty
            case $key in
                '[A') # Up arrow
                    ((selected--))
                    if [ $selected -lt 0 ]; then
                        selected=$((${#vs_names[@]} - 1))
                    fi
                    ;;
                '[B') # Down arrow
                    ((selected++))
                    if [ $selected -ge ${#vs_names[@]} ]; then
                        selected=0
                    fi
                    ;;
            esac
        elif [[ $key == "" ]]; then
            # Enter key pressed
            tput cnorm > /dev/tty # Show cursor again
            echo "${vs_names[$selected]}"
            return
        fi
    done
}

# Select source and destination virtual switches
SOURCE_VS=$(select_vswitch "Select SOURCE virtual switch:" "SOURCE")
DEST_VS=$(select_vswitch "Select DESTINATION virtual switch:" "DESTINATION")

clear
echo "Selected Configuration:"
echo "  Source:      $SOURCE_VS"
echo "  Destination: $DEST_VS"
echo ""

if [ "$SOURCE_VS" == "$DEST_VS" ]; then
    echo "Error: Source and destination cannot be the same."
    exit 1
fi

# Capture the two lists using selected switch names
source_list=$($SSH_CMD "$ACLI_PATH net.list" | grep "$SOURCE_VS")
destination_list=$($SSH_CMD "$ACLI_PATH net.list" | grep "$DEST_VS")

if [ -z "$source_list" ]; then
    echo "Error: Could not retrieve source list. Check connectivity/permissions."
    exit 1
fi

# --- 3. SUMMARY TABLE ---
echo "========================================================================================================================"
echo "                                 REMOTE NETWORK MAPPING SUMMARY ($CLUSTER)"
echo "========================================================================================================================"
printf "%-40s %-38s %-38s\n" "SUBNET NAME" "UUID ON $SOURCE_VS" "UUID ON $DEST_VS"
echo "------------------------------------------------------------------------------------------------------------------------"

while read -r line; do
    [ -z "$line" ] && continue
    s_name=$(echo "$line" | awk '{print $1}')
    s_source_uuid=$(echo "$line" | awk '{print $2}')
    s_dest_uuid=$(echo "$destination_list" | grep "^$s_name " | awk '{print $2}')
    [ -z "$s_dest_uuid" ] && s_dest_uuid="NOT_FOUND"
    printf "%-40s %-38s %-38s\n" "$s_name" "$s_source_uuid" "$s_dest_uuid"
done <<< "$source_list"

echo "========================================================================================================================"
read -p "Summary complete. Press [Enter] to begin detailed NIC parsing..." < /dev/tty
echo ""

# --- 4. DETAILED PARSING & MIGRATION ---
# Use File Descriptor 3 to read the subnet list
while read -r line <&3; do
    [ -z "$line" ] && continue
    
    subnet_name=$(echo "$line" | awk '{print $1}')
    source_uuid=$(echo "$line" | awk '{print $2}')
    destination_uuid=$(echo "$destination_list" | grep "^$subnet_name " | awk '{print $2}')

    if [[ -z "$destination_uuid" || "$destination_uuid" == "NOT_FOUND" ]]; then
        destination_uuid="N/A"
        echo "Subnet named '$subnet_name' not found on the destination virtual switch($DEST_VS). Skipping... Please use the clone_subnets.py script(read Readme)"
        continue
    else
        raw_nics=$($SSH_CMD "$ACLI_PATH net.list_vms $source_uuid")
        nic_count=$(echo "$raw_nics" | awk 'NR>1' | wc -l)
    fi

    echo "================================================================================================================================================================"
    echo "DETAILED VIEW: $subnet_name"
    echo "Total NICs: $nic_count"
    echo "----------------------------------------------------------------------------------------------------------------------------------------------------------------"
    
    if [ "$nic_count" -gt 0 ]; then
        printf "%-25s %-18s %-15s %-38s %-38s\n" "VM NAME" "MAC ADDRESS" "IP ADDRESS" "CURRENT ($SOURCE_VS)" "DESTINATION ($DEST_VS)"
        echo "----------------------------------------------------------------------------------------------------------------------------------------------------------------"
        echo "$raw_nics" | awk -v src="$source_uuid" -v dst="$destination_uuid" 'NR>1 {printf "%-25s %-18s %-15s %-38s %-38s\n", $2, $3, $4, src, dst}'
        echo "================================================================================================================================================================"
        
        while true; do
            echo -n "Migrate the above NICs(one-by-one)? (y/n): "
            read -n 1 subnet_choice < /dev/tty
            echo ""
            if [[ "$subnet_choice" =~ ^[YyNn]$ ]]; then break; fi
            echo "Invalid input. Please press 'y' or 'n'."
        done

        if [[ "$subnet_choice" =~ ^[Yy]$ ]]; then
            migrated_count=0
            total_to_migrate=$nic_count
            
            # Use File Descriptor 4 to read the NIC list for this subnet
            while read -r nic_line <&4; do
                vm_name=$(echo "$nic_line" | awk '{print $2}')
                mac_addr=$(echo "$nic_line" | awk '{print $3}')
                ip_addr=$(echo "$nic_line" | awk '{print $4}')
                
                echo ""
                echo "--> Target: $vm_name"
                
                # Pre-check ping test
                pre_check_ok=false
                if [[ -n "$ip_addr" && "$ip_addr" != "-" ]]; then
                    echo "[PRE-CHECK] Testing connectivity to $ip_addr (2 packets)..."
                    if ping -c 2 -W 2 "$ip_addr" > /dev/null 2>&1; then
                        echo "[PRE-CHECK] ✓ Ping successful"
                        pre_check_ok=true
                    else
                        echo -e "\033[0;33m[PRE-CHECK] ✗ Ping failed (host may be down or unreachable)\033[0m"
                    fi
                else
                    echo "[INFO] No IP address assigned, skipping ping tests"
                fi
                
                while true; do
                    echo -n "Do you want to move this one NIC to the destination vSwitch? (y/n): "
                    read -n 1 nic_choice < /dev/tty
                    echo ""
                    if [[ "$nic_choice" =~ ^[YyNn]$ ]]; then break; fi
                    echo "Invalid input. Please press 'y' or 'n'."
                done

                if [[ "$nic_choice" =~ ^[Yy]$ ]]; then
                    # Build command with conditional IP argument
                    if [[ -n "$ip_addr" && "$ip_addr" != "-" ]]; then
                        cmd="$ACLI_PATH vm.nic_update $vm_name $mac_addr network=$destination_uuid ip=$ip_addr"
                    else
                        cmd="$ACLI_PATH vm.nic_update $vm_name $mac_addr network=$destination_uuid"
                    fi
                    
                    echo "[ACTION] Executing remote update...($cmd)"
                    $SSH_CMD "$cmd"
                    
                    # Post-check ping test
                    if [[ -n "$ip_addr" && "$ip_addr" != "-" ]]; then
                        echo "[POST-CHECK] Testing connectivity to $ip_addr..."
                        sleep 2  # Brief pause to allow network to stabilize
                        
                        if ping -c 2 -W 2 "$ip_addr" > /dev/null 2>&1; then
                            if [ "$pre_check_ok" = true ]; then
                                echo -e "\033[0;32m[POST-CHECK] ✓ Migration successful - host is reachable\033[0m"
                            else
                                echo "[POST-CHECK] ✓ Ping successful (though pre-check failed)"
                            fi
                        else
                            # Only retry if pre-check was successful
                            if [ "$pre_check_ok" = true ]; then
                                echo "[POST-CHECK] First attempt failed, retrying with 5 packets..."
                                sleep 3
                                if ping -c 5 -W 2 "$ip_addr" > /dev/null 2>&1; then
                                    echo -e "\033[0;32m[POST-CHECK] ✓ Migration successful - host is reachable (after retry)\033[0m"
                                else
                                    echo -e "\033[0;31m[POST-CHECK] ✗ WARNING: Host not reachable after migration! Check VM and network configuration.\033[0m"
                                fi
                            else
                                echo -e "\033[0;33m[POST-CHECK] ✗ Ping failed (pre-check also failed)\033[0m"
                            fi
                        fi
                    fi
                    
                    ((migrated_count++))
                else
                    echo "Result: Skipped $vm_name."
                fi
            done 4<<< "$(echo "$raw_nics" | tail -n +2)"
            
            # Offer to delete the source subnet if all NICs were migrated
            if [ "$migrated_count" -eq "$total_to_migrate" ] && [ "$total_to_migrate" -gt 0 ]; then
                echo ""
                echo "================================================================================================================================================================"
                echo "All $migrated_count NIC(s) from subnet '$subnet_name' have been migrated."
                
                # Validation Loop for Subnet Deletion
                while true; do
                    echo -n "Do you want to delete the source subnet ($SOURCE_VS '$subnet_name': $source_uuid)? (y/n): "
                    read -n 1 delete_choice < /dev/tty
                    echo ""
                    if [[ "$delete_choice" =~ ^[YyNn]$ ]]; then break; fi
                    echo "Invalid input. Please press 'y' for Yes or 'n' for No."
                done

                if [[ "$delete_choice" =~ ^[Yy]$ ]]; then
                    echo "[ACTION] Deleting source subnet ($SOURCE_VS)..."
                    echo "Command: acli net.delete $source_uuid"
                    $SSH_CMD "$ACLI_PATH net.delete $source_uuid"
                    echo "Result: Subnet '$subnet_name' deleted."
                else
                    echo "Result: Subnet '$subnet_name' kept."
                fi
            fi
        else
            echo "Result: Skipping subnet $subnet_name."
        fi
    else
        echo "No VMs found in $subnet_name."
    fi
    echo ""
done 3<<< "$source_list" # Input for FD 3