#!/bin/bash

check_required_tools() {
    local missing=0
    local tools=("az" "kubectl" "kubent")

    for tool in "${tools[@]}"; do
        if command -v "$tool" &>/dev/null; then
            echo "[OK] $tool is installed ($(command -v "$tool"))"
        else
            echo "[MISSING] $tool is not installed or not in PATH"
            missing=$((missing + 1))
        fi
    done

    if [[ $missing -gt 0 ]]; then
        echo "Error: $missing required tool(s) missing. Please install them before proceeding."
        exit 1
    fi
}

check_az_auth() {
    local out
    if ! out=$(az account show --query "[name,id,tenantId,user.name]" -o tsv 2>/dev/null); then
        echo "Error: Azure CLI is not authenticated. Please run 'az login' before proceeding."
        exit 1
    fi
    local sub_name sub_id tenant_id user
    { read -r sub_name; read -r sub_id; read -r tenant_id; read -r user; } <<< "$out"
    echo "[OK] Azure CLI is authenticated"
    echo "     Subscription : $sub_name"
    echo "     Subscription ID: $sub_id"
    echo "     Tenant ID    : $tenant_id"
    echo "     Signed in as : $user"
}

list_aks_clusters() {
    echo ""
    echo "Listing AKS clusters in current subscription..."

    local clusters
    if ! clusters=$(az aks list --query "[].{Name:name, ResourceGroup:resourceGroup, Version:kubernetesVersion}" -o tsv 2>/dev/null); then
        echo "Error: Failed to retrieve AKS clusters."
        exit 1
    fi

    if [[ -z "$clusters" ]]; then
        echo "No AKS clusters found in the current subscription."
        return
    fi

    printf "\n%-40s %-30s %-10s\n" "NAME" "RESOURCE GROUP" "K8S VERSION"
    printf "%-40s %-30s %-10s\n" "----------------------------------------" "------------------------------" "----------"
    while IFS=$'\t' read -r name rg version; do
        printf "%-40s %-30s %-10s\n" "$name" "$rg" "$version"
    done <<< "$clusters"
    echo ""
}

# ---------------------------------------------------------------------------
# check_quota_for_cluster <cluster_name> <resource_group> <location>
#
# For every nodepool in the cluster, calculates the number of extra (surge)
# VMs required during an AKS upgrade, maps each to its Azure VM family, and
# checks available vCPU quota in the region.
#
# Returns 0 if all quota checks pass, 1 if any family or the regional total
# would be exceeded.
# ---------------------------------------------------------------------------
check_quota_for_cluster() {
    local cluster_name="$1"
    local resource_group="$2"
    local location="$3"

    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo " Quota check: $cluster_name  ($resource_group)  —  $location"
    echo "══════════════════════════════════════════════════════════════"

    # ── 1. Fetch nodepool details ────────────────────────────────────────
    local nodepools_raw
    nodepools_raw=$(az aks nodepool list \
        --cluster-name "$cluster_name" --resource-group "$resource_group" \
        --query "[].{name:name, vmSize:vmSize, count:count, maxSurge:upgradeSettings.maxSurge}" \
        -o tsv 2>/dev/null)

    if [[ -z "$nodepools_raw" ]]; then
        echo "  [WARN] Could not retrieve nodepools for quota check. Skipping quota validation."
        return 0
    fi

    # ── 2. Per-SKU caches (avoid repeated az calls for the same size) ────
    declare -A sku_vcpus=()
    declare -A sku_family=()

    # ── 3. Fetch all quota entries for this location (one call) ──────────
    local quota_raw
    quota_raw=$(az vm list-usage --location "$location" \
        --query "[].{key:name.value, used:currentValue, limit:limit, display:name.localizedValue}" \
        -o tsv 2>/dev/null)

    if [[ -z "$quota_raw" ]]; then
        echo "  [WARN] Could not retrieve VM quota for location '$location'. Skipping quota validation."
        return 0
    fi

    declare -A quota_used=()
    declare -A quota_limit=()
    declare -A quota_display=()
    while IFS=$'\t' read -r q_key q_used q_limit q_display; do
        [[ -z "$q_key" ]] && continue
        quota_used["$q_key"]=$q_used
        quota_limit["$q_key"]=$q_limit
        quota_display["$q_key"]=$q_display
    done <<< "$quota_raw"

    # ── 4. Parse nodepools, resolve SKU info, accumulate extra vCPUs ─────
    declare -A extra_vcpus_per_family=()
    local total_extra_vcpus=0
    local np_rows=()    # for the formatted table
    local quota_ok=0

    # Table header
    printf "\n  %-20s %-22s %6s %6s %6s %10s\n" \
        "NODEPOOL" "VM SIZE" "NODES" "SURGE" "CPU/VM" "EXTRA CPUs"
    printf "  %s\n" "─────────────────────────────────────────────────────────────────────"

    while IFS=$'\t' read -r np_name vm_size node_count max_surge; do
        [[ -z "$np_name" ]] && continue

        # Resolve surge count
        local surge_count
        if [[ -z "$max_surge" || "$max_surge" == "null" ]]; then
            surge_count=1
        elif [[ "$max_surge" =~ ^([0-9]+)%$ ]]; then
            local pct="${BASH_REMATCH[1]}"
            surge_count=$(( (node_count * pct + 99) / 100 ))
            [[ $surge_count -lt 1 ]] && surge_count=1
        elif [[ "$max_surge" =~ ^[0-9]+$ ]]; then
            surge_count=$max_surge
            [[ $surge_count -lt 0 ]] && surge_count=0
        else
            surge_count=1
        fi

        # Resolve vCPUs and family (cached)
        if [[ -z "${sku_vcpus[$vm_size]+x}" ]]; then
            # Two separate scalar queries avoid TSV multi-value line-order ambiguity.
            # --size does prefix filtering; the JMESPath [?name==…] guard ensures
            # an exact match so we don't pick up e.g. Standard_D8s_v32.
            local s_family s_vcpus
            s_family=$(az vm list-skus \
                --location "$location" \
                --resource-type virtualMachines \
                --size "$vm_size" \
                --query "[?name=='$vm_size'] | [0].family" \
                -o tsv 2>/dev/null)
            s_vcpus=$(az vm list-skus \
                --location "$location" \
                --resource-type virtualMachines \
                --size "$vm_size" \
                --query "[?name=='$vm_size'] | [0].capabilities | [?name=='vCPUs'] | [0].value" \
                -o tsv 2>/dev/null)
            if [[ -n "$s_family" && "$s_family" != "None" && -n "$s_vcpus" && "$s_vcpus" != "None" ]]; then
                sku_family["$vm_size"]="$s_family"
                sku_vcpus["$vm_size"]="$s_vcpus"
            else
                sku_family["$vm_size"]="UNKNOWN"
                sku_vcpus["$vm_size"]="0"
            fi
        fi

        local vcpus_per_vm="${sku_vcpus[$vm_size]}"
        local vm_family="${sku_family[$vm_size]}"
        local extra_vcpus=$(( surge_count * vcpus_per_vm ))

        # Accumulate
        extra_vcpus_per_family["$vm_family"]=$(( ${extra_vcpus_per_family["$vm_family"]:-0} + extra_vcpus ))
        total_extra_vcpus=$(( total_extra_vcpus + extra_vcpus ))

        printf "  %-20s %-22s %6s %6s %6s %10s\n" \
            "$np_name" "$vm_size" "$node_count" "$surge_count" "$vcpus_per_vm" "$extra_vcpus"

    done <<< "$nodepools_raw"

    # ── 5. Check per-family and regional quota ────────────────────────────
    echo ""
    echo "  VM FAMILY / REGIONAL QUOTA:"
    printf "  %-38s %7s %7s %7s %9s  %s\n" \
        "FAMILY" "EXTRA" "USED" "LIMIT" "HEADROOM" "STATUS"
    printf "  %s\n" "──────────────────────────────────────────────────────────────────────────────"

    for family in "${!extra_vcpus_per_family[@]}"; do
        local extra="${extra_vcpus_per_family[$family]}"
        local used="${quota_used[$family]:-}"
        local limit="${quota_limit[$family]:-}"
        local display="${quota_display[$family]:-$family}"

        if [[ -z "$used" || -z "$limit" ]]; then
            printf "  %-38s %7s %7s %7s %9s  %s\n" \
                "$display" "$extra" "?" "?" "?" "[WARN: quota not found]"
            continue
        fi

        local headroom=$(( limit - used ))
        local status
        if [[ $extra -le $headroom ]]; then
            status="[OK]"
        else
            status="[INSUFFICIENT]"
            quota_ok=1
        fi

        printf "  %-38s %7s %7s %7s %9s  %s\n" \
            "$display" "$extra" "$used" "$limit" "$headroom" "$status"
    done

    # Regional total vCPUs
    local reg_used="${quota_used[cores]:-}"
    local reg_limit="${quota_limit[cores]:-}"
    if [[ -n "$reg_used" && -n "$reg_limit" ]]; then
        local reg_headroom=$(( reg_limit - reg_used ))
        local reg_status
        if [[ $total_extra_vcpus -le $reg_headroom ]]; then
            reg_status="[OK]"
        else
            reg_status="[INSUFFICIENT]"
            quota_ok=1
        fi
        printf "  %-38s %7s %7s %7s %9s  %s\n" \
            "Total Regional vCPUs" "$total_extra_vcpus" "$reg_used" "$reg_limit" "$reg_headroom" "$reg_status"
    fi

    echo ""
    return $quota_ok
}

# ---------------------------------------------------------------------------
# check_subnet_ips_for_cluster <cluster_name> <resource_group>
#
# For every nodepool that is integrated with a custom VNet subnet, calculates
# the number of additional IPs consumed in that subnet by the surge nodes
# created during an AKS upgrade and compares it against the subnet's current
# available address space.
#
# IP-per-surge-node accounting by network plugin:
#   Azure CNI (legacy/flat): 1 (node) + maxPods (pre-allocated pod IPs)
#   Azure CNI Overlay / kubenet: 1 (node only; pods use an overlay CIDR)
#
# Returns 0 if all subnets have sufficient IPs, 1 if any would be exceeded.
# ---------------------------------------------------------------------------
check_subnet_ips_for_cluster() {
    local cluster_name="$1"
    local resource_group="$2"

    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo " Subnet IP check: $cluster_name  ($resource_group)"
    echo "══════════════════════════════════════════════════════════════"

    # ── 1. Detect network plugin to determine IPs consumed per surge node ──
    local net_plugin net_plugin_mode
    local net_info
    net_info=$(az aks show \
        --name "$cluster_name" --resource-group "$resource_group" \
        --query "networkProfile.{plugin:networkPlugin, pluginMode:networkPluginMode}" \
        -o tsv 2>/dev/null)

    if [[ -z "$net_info" ]]; then
        echo "  [WARN] Could not retrieve network profile. Skipping subnet IP check."
        return 0
    fi
    { read -r net_plugin; read -r net_plugin_mode; } <<< "$net_info"

    # flat CNI: each surge node consumes 1 + maxPods IPs from the subnet
    # overlay / kubenet: each surge node consumes only 1 IP
    local flat_cni=0
    if [[ "$net_plugin" == "azure" && "$net_plugin_mode" != "overlay" ]]; then
        flat_cni=1
    fi

    # ── 2. Fetch nodepool data ───────────────────────────────────────────
    local nodepools_raw
    nodepools_raw=$(az aks nodepool list \
        --cluster-name "$cluster_name" --resource-group "$resource_group" \
        --query "[].{name:name, subnetId:vnetSubnetId, count:count, maxPods:maxPods, maxSurge:upgradeSettings.maxSurge}" \
        -o tsv 2>/dev/null)

    if [[ -z "$nodepools_raw" ]]; then
        echo "  [WARN] Could not retrieve nodepools for subnet IP check. Skipping."
        return 0
    fi

    # ── 3. Accumulate required IPs per unique subnet ─────────────────────
    declare -A subnet_required=()   # subnet_id -> total IPs needed across pools
    declare -A subnet_short_name=() # subnet_id -> human-readable name

    while IFS=$'\t' read -r np_name subnet_id node_count max_pods max_surge; do
        [[ -z "$np_name" ]] && continue

        # Nodepools without a custom subnet ID are in AKS-managed networking;
        # not bounded by a user subnet so we skip them.
        if [[ -z "$subnet_id" || "$subnet_id" == "None" || "$subnet_id" == "null" ]]; then
            echo "  [INFO] Nodepool '$np_name': no custom subnet — skipping."
            continue
        fi

        # Resolve surge count (same logic as quota check)
        local surge_count
        if [[ -z "$max_surge" || "$max_surge" == "null" || "$max_surge" == "None" ]]; then
            surge_count=1
        elif [[ "$max_surge" =~ ^([0-9]+)%$ ]]; then
            local pct="${BASH_REMATCH[1]}"
            surge_count=$(( (node_count * pct + 99) / 100 ))
            [[ $surge_count -lt 1 ]] && surge_count=1
        elif [[ "$max_surge" =~ ^[0-9]+$ ]]; then
            surge_count=$max_surge
            [[ $surge_count -lt 0 ]] && surge_count=0
        else
            surge_count=1
        fi

        # IPs required per surge node
        local ips_per_surge
        if [[ $flat_cni -eq 1 ]]; then
            local mp=${max_pods:-30}
            [[ "$mp" == "None" || "$mp" == "null" ]] && mp=30
            ips_per_surge=$(( 1 + mp ))
        else
            ips_per_surge=1
        fi

        local np_required=$(( surge_count * ips_per_surge ))
        subnet_required["$subnet_id"]=$(( ${subnet_required["$subnet_id"]:-0} + np_required ))
        # Derive a short name from the last two path segments (vnet/subnet)
        local short
        short=$(echo "$subnet_id" | rev | cut -d'/' -f1-3 | rev)
        subnet_short_name["$subnet_id"]="$short"

    done <<< "$nodepools_raw"

    if [[ ${#subnet_required[@]} -eq 0 ]]; then
        echo "  [INFO] No custom-VNet nodepools found. Skipping subnet IP check."
        return 0
    fi

    # ── 4. Check each unique subnet ──────────────────────────────────────
    printf "\n  %-50s %8s %6s %7s %6s  %s\n" \
        "SUBNET" "REQUIRED" "USED" "USABLE" "AVAIL" "STATUS"
    printf "  %s\n" "────────────────────────────────────────────────────────────────────────────────"

    local subnet_ok=0

    for subnet_id in "${!subnet_required[@]}"; do
        local required="${subnet_required[$subnet_id]}"
        local display="${subnet_short_name[$subnet_id]}"

        # Fetch subnet details in one call
        local subnet_json
        subnet_json=$(az network vnet subnet show --ids "$subnet_id" \
            --query "{prefix:addressPrefix, prefixes:addressPrefixes, usedCount:length(ipConfigurations)}" \
            -o json 2>/dev/null)

        if [[ -z "$subnet_json" ]]; then
            printf "  %-50s %8s %6s %7s %6s  %s\n" \
                "$display" "$required" "?" "?" "?" "[WARN: subnet not found]"
            continue
        fi

        # Parse CIDR prefix — prefer addressPrefix, fall back to addressPrefixes[0]
        local cidr
        cidr=$(echo "$subnet_json" | grep -oP '"prefix"\s*:\s*"\K[^"]+' | head -1)
        if [[ -z "$cidr" || "$cidr" == "null" ]]; then
            cidr=$(echo "$subnet_json" | grep -oP '"prefixes"\s*:\s*\[\s*"\K[^"]+' | head -1)
        fi

        if [[ -z "$cidr" || "$cidr" == "null" ]]; then
            printf "  %-50s %8s %6s %7s %6s  %s\n" \
                "$display" "$required" "?" "?" "?" "[WARN: CIDR not found]"
            continue
        fi

        # Calculate usable addresses: 2^(32-prefixlen) - 5 (Azure reserves 5 per subnet)
        local prefix_len
        prefix_len=$(echo "$cidr" | cut -d'/' -f2)
        local total_ips=$(( 1 << (32 - prefix_len) ))
        local usable=$(( total_ips - 5 ))
        [[ $usable -lt 0 ]] && usable=0

        # Parse currently used IP count from ipConfigurations length
        local used
        used=$(echo "$subnet_json" | grep -oP '"usedCount"\s*:\s*\K[0-9]+')
        [[ -z "$used" ]] && used=0

        local available=$(( usable - used ))
        local status
        if [[ $required -le $available ]]; then
            status="[OK]"
        else
            status="[INSUFFICIENT]"
            subnet_ok=1
        fi

        printf "  %-50s %8s %6s %7s %6s  %s\n" \
            "$display" "$required" "$used" "$usable" "$available" "$status"
    done

    echo ""
    return $subnet_ok
}

# ---------------------------------------------------------------------------
# generate_cluster_upgrade_scripts <cluster_name> <resource_group>
#
# Builds numbered shell scripts in ./<cluster_name>/ that upgrade the AKS
# control plane and every nodepool following Microsoft best practices:
#   - Control plane upgrades one minor version at a time
#   - Nodepools may lag the CP by at most 2 minor versions
#   - When the gap would be exceeded, nodepools are upgraded first, then
#     the CP continues — interleaving as many rounds as needed
# ---------------------------------------------------------------------------
generate_cluster_upgrade_scripts() {
    local cluster_name="$1"
    local resource_group="$2"

    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo " Generating upgrade scripts: $cluster_name  ($resource_group)"
    echo "══════════════════════════════════════════════════════════════"

    # ── Cluster info ────────────────────────────────────────────────────
    local location cp_version info
    if ! info=$(az aks show -n "$cluster_name" -g "$resource_group" \
            --query "[location, kubernetesVersion]" -o tsv 2>/dev/null); then
        echo "  [ERROR] Could not retrieve cluster info. Skipping."
        return 1
    fi
    { read -r location; read -r cp_version; } <<< "$info"

    if [[ -z "$location" || -z "$cp_version" ]]; then
        echo "  [ERROR] Could not retrieve cluster info. Skipping."
        return 1
    fi

    # ── Quota pre-flight check ───────────────────────────────────────────
    if ! check_quota_for_cluster "$cluster_name" "$resource_group" "$location"; then
        echo "  [SKIP] Upgrade scripts NOT generated for $cluster_name due to insufficient VM quota."
        return 1
    fi

    # ── VNet subnet IP pre-flight check ─────────────────────────────────
    if ! check_subnet_ips_for_cluster "$cluster_name" "$resource_group"; then
        echo "  [SKIP] Upgrade scripts NOT generated for $cluster_name due to insufficient subnet IPs."
        return 1
    fi

    # ── All stable K8s versions in region (used to resolve patch numbers) ──
    local all_region_versions
    all_region_versions=$(az aks get-versions -l "$location" \
        --query "values[?!isPreview].patchVersions" -o json 2>/dev/null \
        | grep -oE '"1\.[0-9]+\.[0-9]+"' | tr -d '"' | sort -V)

    if [[ -z "$all_region_versions" ]]; then
        echo "  [ERROR] Could not retrieve Kubernetes versions for region $location. Skipping."
        return 1
    fi

    # Latest stable version available in this region — this is our upgrade target.
    # NOTE: az aks get-upgrades only returns 1-2 directly reachable versions from
    # the current cluster; we deliberately do NOT use it to determine the target.
    local target_version
    target_version=$(echo "$all_region_versions" | tail -1)

    # ── Nodepools ───────────────────────────────────────────────────────
    local nodepools_raw
    nodepools_raw=$(az aks nodepool list \
        --cluster-name "$cluster_name" --resource-group "$resource_group" \
        --query "[].{name:name, version:orchestratorVersion}" \
        -o tsv 2>/dev/null)

    local cp_minor target_minor
    cp_minor=$(echo "$cp_version"    | cut -d. -f2)
    target_minor=$(echo "$target_version" | cut -d. -f2)

    if [[ $cp_minor -ge $target_minor ]]; then
        echo "  [INFO] Cluster is already at or above the latest stable version ($cp_version). Nothing to do."
        return 0
    fi

    echo "  Control plane : $cp_version  →  $target_version"

    # Build parallel arrays for nodepool names and their current minor versions
    local np_names=() np_cur_minors=()
    while IFS=$'\t' read -r np_name np_version; do
        [[ -z "$np_name" ]] && continue
        np_names+=("$np_name")
        np_cur_minors+=("$(echo "$np_version" | cut -d. -f2)")
        echo "  Nodepool      : $np_name @ $np_version"
    done <<< "$nodepools_raw"

    local out_dir="${ROOT_DIR}/${cluster_name}"
    mkdir -p "$out_dir"

    # ── Inner helpers (see bash dynamic scoping — they inherit local vars) ──

    # Return the latest stable patch version string for a given minor (e.g. 28 → 1.28.14)
    # Source: az aks get-versions for the cluster's region — covers all minor versions,
    # not just the 1-2 hops returned by az aks get-upgrades.
    get_patch_version() {
        local minor="$1"
        echo "$all_region_versions" | grep -E "^1\.${minor}\." | sort -V | tail -1
    }

    # Return the lowest minor version across all nodepools
    get_min_np_minor() {
        [[ ${#np_cur_minors[@]} -eq 0 ]] && echo "$target_minor" && return
        printf '%s\n' "${np_cur_minors[@]}" | sort -n | head -1
    }

    # Write a control-plane upgrade script
    gen_cp_script() {
        local step_num="$1" from_minor="$2" to_minor="$3"
        local from_version to_version
        from_version=$(get_patch_version "$from_minor")
        to_version=$(get_patch_version "$to_minor")
        if [[ -z "$to_version" ]]; then
            echo "  [WARN] No published version found for 1.${to_minor} in region. Stopping CP chain."
            return 1
        fi
        local fname="${out_dir}/${step_num}_upgrade_control_plane_${from_version}_to_${to_version}.sh"
        cat > "$fname" <<SCRIPT
#!/bin/bash
# Step ${step_num} — Upgrade AKS control plane: ${from_version}  →  ${to_version}
#
# Cluster       : ${cluster_name}
# Resource Group: ${resource_group}
#
# Microsoft best-practice notes:
#   * The control plane is upgraded independently of node pools (--control-plane-only).
#   * Only one minor version is crossed per script.
#   * Verify cluster health before running the next step.
#
# Reference: https://learn.microsoft.com/azure/aks/upgrade-aks-cluster
set -euo pipefail

CLUSTER_NAME="${cluster_name}"
RESOURCE_GROUP="${resource_group}"
FROM_VERSION="${from_version}"
TARGET_VERSION="${to_version}"

echo "==> [Step ${step_num}] Upgrading control plane of \${CLUSTER_NAME}: \${FROM_VERSION}  →  \${TARGET_VERSION}"

echo "--- Pre-upgrade cluster state:"
az aks show \\
    --name "\${CLUSTER_NAME}" \\
    --resource-group "\${RESOURCE_GROUP}" \\
    --query "{provisioningState:provisioningState,currentVersion:kubernetesVersion}" \\
    -o table

echo "--- Starting control plane upgrade (node pools are NOT touched)..."
az aks upgrade \\
    --name "\${CLUSTER_NAME}" \\
    --resource-group "\${RESOURCE_GROUP}" \\
    --kubernetes-version "\${TARGET_VERSION}" \\
    --control-plane-only \\
    --yes

echo "==> Control plane successfully upgraded: \${FROM_VERSION}  →  \${TARGET_VERSION}."
SCRIPT
        chmod +x "$fname"
        echo "  [+] Created: ${fname##*/}  (CP ${from_version} → ${to_version})"
    }

    # Write a nodepool upgrade script
    gen_np_script() {
        local step_num="$1" np_name="$2" from_minor="$3" to_minor="$4"
        local from_version to_version
        from_version=$(get_patch_version "$from_minor")
        to_version=$(get_patch_version "$to_minor")
        if [[ -z "$to_version" ]]; then
            echo "  [WARN] No published version found for 1.${to_minor} in region. Skipping NP ${np_name}."
            return 1
        fi
        local fname="${out_dir}/${step_num}_upgrade_${np_name}_${from_version}_to_${to_version}.sh"
        cat > "$fname" <<SCRIPT
#!/bin/bash
# Step ${step_num} — Upgrade nodepool '${np_name}': ${from_version}  →  ${to_version}
#
# Cluster       : ${cluster_name}
# Resource Group: ${resource_group}
#
# Microsoft best-practice notes:
#   * The control plane must already be at ${to_version} or higher before running this.
#   * Tune MAX_SURGE, MAX_UNAVAILABLE, DRAIN_TIMEOUT below before executing.
#   * Verify workload health after each node pool upgrade.
#
# Reference: https://learn.microsoft.com/azure/aks/upgrade-aks-cluster#upgrade-node-pools
set -euo pipefail

CLUSTER_NAME="${cluster_name}"
RESOURCE_GROUP="${resource_group}"
NODEPOOL_NAME="${np_name}"
FROM_VERSION="${from_version}"
TARGET_VERSION="${to_version}"

# Tune these before running:
MAX_SURGE="1"          # extra nodes during upgrade: integer or % (e.g. "1" or "33%")
MAX_UNAVAILABLE="0"    # must be "0" when MAX_SURGE > 0 (AKS requirement)
DRAIN_TIMEOUT=30       # minutes to wait for pod drain before forcing

echo "==> [Step ${step_num}] Upgrading nodepool '\${NODEPOOL_NAME}' of \${CLUSTER_NAME}: \${FROM_VERSION}  →  \${TARGET_VERSION}"
echo "    max-surge=\${MAX_SURGE}  max-unavailable=\${MAX_UNAVAILABLE}  drain-timeout=\${DRAIN_TIMEOUT}m"

echo "--- Pre-upgrade nodepool state:"
az aks nodepool show \\
    --cluster-name "\${CLUSTER_NAME}" \\
    --resource-group "\${RESOURCE_GROUP}" \\
    --name "\${NODEPOOL_NAME}" \\
    --query "{provisioningState:provisioningState,currentVersion:orchestratorVersion,count:count}" \\
    -o table

echo "--- Starting nodepool upgrade..."
az aks nodepool upgrade \\
    --cluster-name "\${CLUSTER_NAME}" \\
    --resource-group "\${RESOURCE_GROUP}" \\
    --name "\${NODEPOOL_NAME}" \\
    --kubernetes-version "\${TARGET_VERSION}" \\
    --max-surge "\${MAX_SURGE}" \\
    --max-unavailable "\${MAX_UNAVAILABLE}" \\
    --drain-timeout "\${DRAIN_TIMEOUT}" \\
    --yes

echo "==> Nodepool '\${NODEPOOL_NAME}' successfully upgraded: \${FROM_VERSION}  →  \${TARGET_VERSION}."
SCRIPT
        chmod +x "$fname"
        echo "  [+] Created: ${fname##*/}  (NP ${np_name}: ${from_version} → ${to_version})"
    }

    # Write a pre-upgrade deprecated-API check script using kubent
    gen_kubent_script() {
        local fname="${out_dir}/0_check_deprecated_apis.sh"
        cat > "$fname" <<SCRIPT
#!/bin/bash
# Step 0 — Check for deprecated Kubernetes APIs using kubent (kube-no-trouble)
#
# Cluster       : ${cluster_name}
# Resource Group: ${resource_group}
#
# Scans for deprecated/removed Kubernetes APIs. Fix any findings BEFORE upgrading.
# Prerequisites: kubent (https://github.com/doitintl/kube-no-trouble) and kubectl
#   configured to point at this cluster.
#
# Reference: https://learn.microsoft.com/azure/aks/upgrade-aks-cluster#check-for-removed-apis
set -euo pipefail

CLUSTER_NAME="${cluster_name}"
RESOURCE_GROUP="${resource_group}"

echo "==> [Step 0] Checking for deprecated/removed APIs in \${CLUSTER_NAME}"

if ! command -v kubent &>/dev/null; then
    echo "[ERROR] kubent is not installed or not in PATH."
    echo "        Install it from: https://github.com/doitintl/kube-no-trouble"
    exit 1
fi

echo "--- Switching kubectl context to \${CLUSTER_NAME}..."
az aks get-credentials \\
    --name "\${CLUSTER_NAME}" \\
    --resource-group "\${RESOURCE_GROUP}" \\
    --overwrite-existing

echo "--- Running kubent..."
kubent

echo ""
echo "==> If kubent reported issues, resolve them before proceeding with upgrade scripts."
echo "    No output (or only header) means no deprecated APIs were detected."
SCRIPT
        chmod +x "$fname"
        echo "  [+] Created: ${fname##*/}  (deprecated API check via kubent)"
    }

    # ── Upgrade sequence generation ─────────────────────────────────────
    #
    # AKS constraint: node pools must be within 2 minor versions of the CP.
    # Both the control plane AND node pools advance one minor version at a time.
    #
    # Algorithm:
    #   Phase 1 — advance CP one minor at a time up to (min_NP + 2) or target.
    #   Phase 2 — advance every lagging node pool one minor at a time up to
    #             the current CP, each hop generating its own script.
    #   Repeat   until CP and all node pools reach target.
    # ────────────────────────────────────────────────────────────────────
    echo "  Generating upgrade sequence (CP minor: $cp_minor → $target_minor)..."

    gen_kubent_script

    local step=1 current_cp=$cp_minor abort=0
    local min_np
    min_np=$(get_min_np_minor)

    while [[ $current_cp -lt $target_minor ]] || [[ $min_np -lt $target_minor ]]; do

        # Phase 1 — advance CP one minor at a time up to (min_np + 2) or target
        local max_cp=$(( min_np + 2 ))
        [[ $max_cp -gt $target_minor ]] && max_cp=$target_minor

        while [[ $current_cp -lt $max_cp ]]; do
            local next=$(( current_cp + 1 ))
            if ! gen_cp_script "$step" "$current_cp" "$next"; then
                abort=1; break
            fi
            step=$(( step + 1 ))
            current_cp=$next
        done
        [[ $abort -eq 1 ]] && break

        # Phase 2 — advance each lagging node pool one minor version at a time
        # up to the current CP version. One script per nodepool per minor hop.
        local made_progress=1
        while [[ $made_progress -eq 1 ]]; do
            made_progress=0
            for i in "${!np_names[@]}"; do
                local np_minor="${np_cur_minors[$i]}"
                if [[ $np_minor -lt $current_cp ]]; then
                    local np_next=$(( np_minor + 1 ))
                    if gen_np_script "$step" "${np_names[$i]}" "$np_minor" "$np_next"; then
                        step=$(( step + 1 ))
                        np_cur_minors[$i]=$np_next
                        made_progress=1
                    fi
                fi
            done
        done

        min_np=$(get_min_np_minor)

        # All done?
        [[ $current_cp -ge $target_minor && $min_np -ge $target_minor ]] && break
    done

    echo ""
    echo "  Scripts: $(( step - 1 ))   |   Directory: $(realpath "$out_dir" 2>/dev/null || echo "$out_dir")"
}

# ---------------------------------------------------------------------------
# Iterate over every AKS cluster in the subscription and generate scripts
# ---------------------------------------------------------------------------
generate_all_upgrade_scripts() {
    echo ""
    echo "Building upgrade scripts for all clusters in subscription..."

    local clusters
    clusters=$(az aks list \
        --query "[].{name:name, rg:resourceGroup}" \
        -o tsv 2>/dev/null)

    if [[ -z "$clusters" ]]; then
        echo "No AKS clusters found in the current subscription."
        return
    fi

    while IFS=$'\t' read -r cluster_name resource_group; do
        [[ -z "$cluster_name" ]] && continue
        generate_cluster_upgrade_scripts "$cluster_name" "$resource_group"
    done <<< "$clusters"
}

ROOT_DIR="./upgrade-scripts-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$ROOT_DIR"
echo "Output directory: $(realpath "$ROOT_DIR")"

echo "Start AKS upgrade analysis"
check_required_tools
check_az_auth
list_aks_clusters
generate_all_upgrade_scripts

echo ""
echo "All scripts written to: $(realpath "$ROOT_DIR")"

