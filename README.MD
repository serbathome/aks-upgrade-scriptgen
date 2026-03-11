# AKS Upgrade Script Generator

Automates the generation of numbered, sequential shell scripts that safely upgrade every AKS cluster in the active Azure subscription from its current Kubernetes version to the latest stable version available in its region.

---

## Dependencies

| Tool | Minimum Version | Purpose |
|------|----------------|---------|
| `az` (Azure CLI) | 2.50+ | Query AKS clusters, node-pool details, VM SKU info, quota, and Kubernetes version catalogue |
| `kubectl` | 1.26+ | Required by the generated `0_check_deprecated_apis.sh` script to connect to a cluster |
| `kubent` (kube-no-trouble) | 0.7+ | Scans the cluster for removed/deprecated Kubernetes API usage before upgrading |

All three tools must be present in `PATH` before the script is run. The script checks for them at startup and exits immediately if any are missing.

Install links:
- Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli
- kubectl: https://kubernetes.io/docs/tasks/tools/
- kubent: https://github.com/doitintl/kube-no-trouble

---

## Files

```
create-upgrade-scripts.sh   — main script (run this)
README.MD                   — this file
```

Generated output is written to a timestamped directory in the working directory:

```
upgrade-scripts-YYYYMMDD_HHMMSS/
└── <cluster-name>/
    ├── 0_check_deprecated_apis.sh
    ├── 1_upgrade_control_plane_1.28.14_to_1.29.12.sh
    ├── 2_upgrade_control_plane_1.29.12_to_1.30.10.sh
    ├── 3_upgrade_agentpool_1.28.14_to_1.29.12.sh
    ├── 4_upgrade_agentpool_1.29.12_to_1.30.10.sh
    └── ...
```

---

## Usage

```bash
# 1. Log in to Azure and set the target subscription
az login
az account set --subscription "<subscription-id-or-name>"

# 2. Run the generator
bash create-upgrade-scripts.sh

# 3. Review output directory, then execute the numbered scripts in order
cd upgrade-scripts-YYYYMMDD_HHMMSS/<cluster-name>/
bash 0_check_deprecated_apis.sh
bash 1_upgrade_control_plane_...sh
bash 2_upgrade_...sh
# ... continue in numeric order
```

---

## Flow of Execution

```
main
├── create output directory   ./upgrade-scripts-YYYYMMDD_HHMMSS/
├── check_required_tools      verify az / kubectl / kubent are in PATH
├── check_az_auth             confirm az account show returns valid session
├── list_aks_clusters         print table of every cluster in the subscription
└── generate_all_upgrade_scripts
    └── for each cluster in subscription
        └── generate_cluster_upgrade_scripts <name> <resource-group>
            ├── az aks show                    fetch location + current CP version
            ├── check_quota_for_cluster        pre-flight vCPU quota check
            │   ├── az aks nodepool list        get node counts + maxSurge settings
            │   ├── az vm list-skus             resolve vCPU count + VM family per SKU
            │   └── az vm list-usage            fetch current quota usage in region
            ├── az aks get-versions             build full catalog of stable versions
            ├── gen_kubent_script              emit  0_check_deprecated_apis.sh
            └── upgrade sequence loop
                ├── Phase 1 — gen_cp_script    emit control-plane hop scripts
                │   └── get_patch_version       resolve minor → latest patch string
                └── Phase 2 — gen_np_script    emit nodepool hop scripts (one per pool per minor)
                    └── get_patch_version
```

---

## Function Reference

### `check_required_tools()`
Iterates over `("az" "kubectl" "kubent")` and calls `command -v` for each. Exits with code 1 if any tool is absent. Prints an `[OK]` / `[MISSING]` line per tool.

---

### `check_az_auth()`
Runs `az account show` and extracts the subscription name, subscription ID, tenant ID, and signed-in user. Exits with code 1 if the command fails (i.e. not logged in). Prints the session details for confirmation.

---

### `list_aks_clusters()`
Calls `az aks list` with a JMESPath query to extract `name`, `resourceGroup`, and `kubernetesVersion` for every cluster in the active subscription. Renders them as a padded table.

---

### `check_quota_for_cluster(cluster_name, resource_group, location)`
Performs a vCPU quota pre-flight check so that upgrade-related VM surge will not hit a quota limit.

1. **Fetch node-pool details** — `az aks nodepool list` returns each pool's VM size, node count, and `maxSurge` setting.
2. **Resolve surge count per pool** — `maxSurge` may be an integer, a percentage, or absent (defaults to 1). For percentages the surge count is ceiling-divided: `ceil(nodeCount × pct / 100)`, minimum 1.
3. **Resolve vCPUs and VM family** (cached per unique SKU) — two `az vm list-skus` calls with JMESPath guards fetch the `family` and `vCPUs` capability for the exact SKU name.
4. **Fetch regional quota** (single call) — `az vm list-usage` returns all quota entries (used / limit) for the location.
5. **Compare** per-family headroom and total regional `cores` headroom against calculated extra vCPUs. Prints a result table with `[OK]` or `[INSUFFICIENT]` per row.

Returns 0 (pass) or 1 (fail). If quota check fails, `generate_cluster_upgrade_scripts` skips that cluster.

---

### `generate_cluster_upgrade_scripts(cluster_name, resource_group)`
Orchestrates script generation for one cluster.

1. Calls `az aks show` to retrieve `location` and `kubernetesVersion` (current control-plane version).
2. Calls `check_quota_for_cluster` — skips cluster if it returns non-zero.
3. Calls `az aks get-versions` to build the full sorted list of stable patch versions available in the region. The **latest entry is the upgrade target** (not constrained to the 1–2 direct hops reported by `az aks get-upgrades`).
4. Calls `az aks nodepool list` to collect each pool's name and current minor version.
5. Creates the output subdirectory `<ROOT_DIR>/<cluster_name>/`.
6. Calls `gen_kubent_script` to emit `0_check_deprecated_apis.sh`.
7. Runs the **upgrade sequence loop** (see below).

#### Inner helper functions (defined inside `generate_cluster_upgrade_scripts`)

| Function | Signature | Description |
|----------|-----------|-------------|
| `get_patch_version` | `(minor)` | Greps `all_region_versions` for lines matching `1.<minor>.*` and returns the last (highest) patch version. |
| `get_min_np_minor` | `()` | Returns the smallest current minor version across all node pools (drives the loop termination). |
| `gen_cp_script` | `(step, from_minor, to_minor)` | Resolves patch strings via `get_patch_version`, writes a numbered `az aks upgrade --control-plane-only` script at `<step>_upgrade_control_plane_<from>_to_<to>.sh`, marks it executable. |
| `gen_np_script` | `(step, np_name, from_minor, to_minor)` | Same as above but writes an `az aks nodepool upgrade` script with configurable `MAX_SURGE`, `MAX_UNAVAILABLE`, and `DRAIN_TIMEOUT` placeholders. |
| `gen_kubent_script` | `()` | Writes `0_check_deprecated_apis.sh` — gets cluster credentials via `az aks get-credentials` then runs `kubent` to surface removed-API usage before any upgrade. |

---

### `generate_all_upgrade_scripts()`
Calls `az aks list` to enumerate every cluster (`name`, `resourceGroup`) in the active subscription, then calls `generate_cluster_upgrade_scripts` for each one.

---

## Upgrade Sequence Algorithm

AKS enforces that node pools must stay within **2 minor versions** of the control plane. Both the control plane and node pools advance **one minor version at a time**. The algorithm interleaves control-plane and node-pool hops to respect this constraint:

```
while CP or any NP has not reached target_minor:

  Phase 1 — Advance CP
    max_cp = min(min_NP_minor + 2, target_minor)
    while CP_minor < max_cp:
        emit gen_cp_script(step, CP_minor, CP_minor + 1)
        CP_minor++

  Phase 2 — Advance lagging node pools
    repeat until no progress:
        for each NP where NP_minor < CP_minor:
            emit gen_np_script(step, NP_name, NP_minor, NP_minor + 1)
            NP_minor++
```

This guarantees that the gap between any node pool and the control plane never exceeds 2 minor versions at any point in the generated sequence.

---

## Generated Script Details

### `0_check_deprecated_apis.sh`
- Switches `kubectl` context to the cluster using `az aks get-credentials --overwrite-existing`.
- Runs `kubent` to list any workloads using Kubernetes APIs removed or deprecated in upcoming versions.
- Must be reviewed and all findings resolved **before** running upgrade steps 1+.

### `N_upgrade_control_plane_<from>_to_<to>.sh`
- Runs `az aks upgrade --kubernetes-version <to> --control-plane-only --yes`.
- Prints pre-upgrade cluster state (provisioningState, currentVersion) for verification.
- Uses `set -euo pipefail` — exits immediately on any error.

### `N_upgrade_<nodepool>_<from>_to_<to>.sh`
- Runs `az aks nodepool upgrade --kubernetes-version <to> --yes` with configurable surge parameters.
- Three variables at the top of each script should be tuned before execution:
  - `MAX_SURGE` — extra nodes to provision during rolling upgrade (default `"1"`).
  - `MAX_UNAVAILABLE` — must be `"0"` when `MAX_SURGE > 0` (AKS requirement).
  - `DRAIN_TIMEOUT` — minutes to wait for graceful pod eviction before forcing (default `30`).
- Prints pre-upgrade node-pool state (provisioningState, orchestratorVersion, count).
