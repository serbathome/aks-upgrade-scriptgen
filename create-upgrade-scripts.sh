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
    local sub_name sub_id tenant_id user
    if ! IFS=$'\t' read -r sub_name sub_id tenant_id user < <(
            az account show --query "[name,id,tenantId,user.name]" -o tsv 2>/dev/null); then
        echo "Error: Azure CLI is not authenticated. Please run 'az login' before proceeding."
        exit 1
    fi
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
    local location cp_version
    IFS=$'\t' read -r location cp_version < <(
        az aks show -n "$cluster_name" -g "$resource_group" \
            --query "[location, kubernetesVersion]" -o tsv 2>/dev/null)

    if [[ -z "$location" || -z "$cp_version" ]]; then
        echo "  [ERROR] Could not retrieve cluster info. Skipping."
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

