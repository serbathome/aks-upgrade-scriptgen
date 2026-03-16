// aks-upgrade-scripts — Generate numbered AKS upgrade shell scripts for every
// cluster in the current Azure subscription, with a VM quota pre-flight check.
//
// Authentication: DefaultAzureCredential (environment variables, workload
// identity, managed identity, Azure CLI token, …)
//
// Usage:
//
//	go run . [--subscription <subscription-id>]
//
// If --subscription is not supplied the program falls back to the
// AZURE_SUBSCRIPTION_ID environment variable, and if that is also absent it
// picks the first enabled subscription visible to the credential.
package main

import (
	"bytes"
	"cmp"
	"context"
	_ "embed"
	"errors"
	"flag"
	"fmt"
	"log"
	"maps"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"text/template"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/arm"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/compute/armcompute/v6"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/containerservice/armcontainerservice/v6"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/resources/armsubscriptions"
)

// ---------------------------------------------------------------------------
// Shell script templates — embedded from templates/*.sh.tmpl at compile time.
// ---------------------------------------------------------------------------

//go:embed templates/control_plane.sh.tmpl
var cpScriptTmpl string

//go:embed templates/nodepool.sh.tmpl
var npScriptTmpl string

// loadTemplates parses both embedded templates and returns them ready to use.
func loadTemplates() (cpTpl, npTpl *template.Template) {
	cpTpl = template.Must(template.New("control_plane").Parse(cpScriptTmpl))
	npTpl = template.Must(template.New("nodepool").Parse(npScriptTmpl))
	return
}

// ---------------------------------------------------------------------------
// Semver helpers
// ---------------------------------------------------------------------------

var versionRe = regexp.MustCompile(`^1\.(\d+)\.(\d+)$`)

type k8sVersion struct {
	minor int
	patch int
	raw   string
}

func parseVersion(v string) (k8sVersion, error) {
	m := versionRe.FindStringSubmatch(strings.TrimSpace(v))
	if m == nil {
		return k8sVersion{}, fmt.Errorf("cannot parse kubernetes version %q", v)
	}
	minor, _ := strconv.Atoi(m[1])
	patch, _ := strconv.Atoi(m[2])
	return k8sVersion{minor: minor, patch: patch, raw: strings.TrimSpace(v)}, nil
}

// latestPatchForMinor returns the highest patch release string for a given
// minor version from the sorted list, or "" if none found.
// Iterates from the end because the list is already sorted ascending.
func latestPatchForMinor(versions []k8sVersion, minor int) string {
	for i := len(versions) - 1; i >= 0; i-- {
		if versions[i].minor == minor {
			return versions[i].raw
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// nodepool descriptor
// ---------------------------------------------------------------------------

type nodepoolInfo struct {
	name      string
	vmSize    string
	nodeCount int32
	maxSurge  string // raw: "", "1", "33%", etc.
	curMinor  int
}

// surgeCount resolves the integer number of extra (surge) nodes for an upgrade.
func (np *nodepoolInfo) surgeCount() int32 {
	s := strings.TrimSpace(np.maxSurge)
	if s == "" || s == "null" {
		return 1
	}
	if strings.HasSuffix(s, "%") {
		pct, err := strconv.ParseFloat(strings.TrimSuffix(s, "%"), 64)
		if err != nil {
			return 1
		}
		return max(int32(math.Ceil(float64(np.nodeCount)*pct/100.0)), 1)
	}
	n, err := strconv.ParseInt(s, 10, 32)
	if err != nil || n < 0 {
		return 1
	}
	return int32(n)
}

// ---------------------------------------------------------------------------
// Script template data — typed structs for compile-time key checking.
// ---------------------------------------------------------------------------

type cpScriptData struct {
	Step          int
	ClusterName   string
	ResourceGroup string
	FromVersion   string
	ToVersion     string
}

type npScriptData struct {
	Step          int
	ClusterName   string
	ResourceGroup string
	NodepoolName  string
	FromVersion   string
	ToVersion     string
}

type clusterRef struct {
	name     string
	rg       string
	location string
	version  string
}

// ---------------------------------------------------------------------------
// Azure clients holder
// ---------------------------------------------------------------------------

type clients struct {
	aks   *armcontainerservice.ManagedClustersClient
	pools *armcontainerservice.AgentPoolsClient
	skus  *armcompute.ResourceSKUsClient
	usage *armcompute.UsageClient
}

func newClients(subID string, cred azcore.TokenCredential) (*clients, error) {
	opts := &arm.ClientOptions{}
	aks, err := armcontainerservice.NewManagedClustersClient(subID, cred, opts)
	if err != nil {
		return nil, fmt.Errorf("AKS client: %w", err)
	}
	pools, err := armcontainerservice.NewAgentPoolsClient(subID, cred, opts)
	if err != nil {
		return nil, fmt.Errorf("agent pools client: %w", err)
	}
	skus, err := armcompute.NewResourceSKUsClient(subID, cred, opts)
	if err != nil {
		return nil, fmt.Errorf("SKU client: %w", err)
	}
	usage, err := armcompute.NewUsageClient(subID, cred, opts)
	if err != nil {
		return nil, fmt.Errorf("usage client: %w", err)
	}
	return &clients{aks: aks, pools: pools, skus: skus, usage: usage}, nil
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

func main() {
	log.SetFlags(0)
	log.SetPrefix("Error: ")

	subID := flag.String("subscription", os.Getenv("AZURE_SUBSCRIPTION_ID"),
		"Azure subscription ID (defaults to AZURE_SUBSCRIPTION_ID env var)")
	flag.Parse()

	ctx := context.Background()

	cred, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		log.Fatalf("cannot create Azure credential: %v", err)
	}

	// Resolve subscription ID when not provided.
	if *subID == "" {
		*subID, err = resolveFirstEnabledSubscription(ctx, cred)
		if err != nil {
			log.Fatalf("cannot determine subscription: %v\n"+
				"Set AZURE_SUBSCRIPTION_ID or pass --subscription <id>", err)
		}
	}
	fmt.Printf("[OK] Using subscription: %s\n", *subID)

	c, err := newClients(*subID, cred)
	if err != nil {
		log.Fatalf("cannot create Azure clients: %v", err)
	}

	// List all AKS clusters.
	fmt.Println("\nListing AKS clusters in subscription...")
	var clusters []clusterRef
	pager := c.aks.NewListPager(nil)
	for pager.More() {
		page, pageErr := pager.NextPage(ctx)
		if pageErr != nil {
			log.Fatalf("failed to list AKS clusters: %v", pageErr)
		}
		for _, cl := range page.Value {
			clusters = append(clusters, clusterRef{
				name:     ptrStr(cl.Name),
				rg:       resourceGroupFromID(ptrStr(cl.ID)),
				location: ptrStr(cl.Location),
				version:  ptrStr(cl.Properties.KubernetesVersion),
			})
		}
	}

	if len(clusters) == 0 {
		fmt.Println("No AKS clusters found in the current subscription.")
		return
	}

	fmt.Printf("\n%-40s %-30s %-10s\n", "NAME", "RESOURCE GROUP", "K8S VERSION")
	fmt.Printf("%-40s %-30s %-10s\n",
		strings.Repeat("-", 40), strings.Repeat("-", 30), strings.Repeat("-", 10))
	for _, cl := range clusters {
		fmt.Printf("%-40s %-30s %-10s\n", cl.name, cl.rg, cl.version)
	}
	fmt.Println()

	rootDir := fmt.Sprintf("./upgrade-scripts-%s", time.Now().Format("20060102_150405"))
	if mkdirErr := os.MkdirAll(rootDir, 0755); mkdirErr != nil {
		log.Fatalf("cannot create output directory: %v", mkdirErr)
	}
	fmt.Printf("Output directory: %s\n", rootDir)

	cpTpl, npTpl := loadTemplates()

	for _, cl := range clusters {
		generateClusterScripts(ctx, cl.name, cl.rg, cl.location, cl.version, c, rootDir, cpTpl, npTpl)
	}

	fmt.Printf("\nAll scripts written to: %s\n", rootDir)
}

// ---------------------------------------------------------------------------
// generateClusterScripts
// ---------------------------------------------------------------------------

func generateClusterScripts(
	ctx context.Context,
	clusterName, rg, location, cpVersionStr string,
	c *clients,
	rootDir string,
	cpTpl, npTpl *template.Template,
) {
	sep := strings.Repeat("═", 62)
	fmt.Printf("\n%s\n Generating upgrade scripts: %s  (%s)\n%s\n", sep, clusterName, rg, sep)

	cpVersion, err := parseVersion(cpVersionStr)
	if err != nil {
		fmt.Printf("  [ERROR] Cannot parse CP version %q: %v\n", cpVersionStr, err)
		return
	}

	// ----- K8s versions available in this region -------------------------
	allVersions, err := listRegionK8sVersions(ctx, c.aks, location)
	if err != nil || len(allVersions) == 0 {
		fmt.Printf("  [ERROR] Could not retrieve K8s versions for region %s: %v\n", location, err)
		return
	}
	targetVersion := allVersions[len(allVersions)-1]

	if cpVersion.minor >= targetVersion.minor {
		fmt.Printf("  [INFO] Cluster is already at or above the latest stable version (%s). Nothing to do.\n",
			cpVersionStr)
		return
	}
	fmt.Printf("  Control plane : %s  →  %s\n", cpVersionStr, targetVersion.raw)

	// ----- Nodepools -----------------------------------------------------
	var nodepools []nodepoolInfo
	npPager := c.pools.NewListPager(rg, clusterName, nil)
	for npPager.More() {
		page, pageErr := npPager.NextPage(ctx)
		if pageErr != nil {
			fmt.Printf("  [ERROR] Could not list nodepools: %v\n", pageErr)
			return
		}
		for _, np := range page.Value {
			ver := ptrStr(np.Properties.OrchestratorVersion)
			parsed, parseErr := parseVersion(ver)
			if parseErr != nil {
				fmt.Printf("  [WARN] Cannot parse nodepool %s version %q: %v\n",
					ptrStr(np.Name), ver, parseErr)
				continue
			}
			surge := ""
			if np.Properties.UpgradeSettings != nil && np.Properties.UpgradeSettings.MaxSurge != nil {
				surge = *np.Properties.UpgradeSettings.MaxSurge
			}
			count := int32(0)
			if np.Properties.Count != nil {
				count = *np.Properties.Count
			}
			nodepools = append(nodepools, nodepoolInfo{
				name:      ptrStr(np.Name),
				vmSize:    ptrStr(np.Properties.VMSize),
				nodeCount: count,
				maxSurge:  surge,
				curMinor:  parsed.minor,
			})
			fmt.Printf("  Nodepool      : %s @ %s\n", ptrStr(np.Name), ver)
		}
	}

	// ----- Quota pre-flight ----------------------------------------------
	if !checkQuota(ctx, clusterName, rg, location, nodepools, c.skus, c.usage) {
		fmt.Printf("  [SKIP] Upgrade scripts NOT generated for %s due to insufficient VM quota.\n",
			clusterName)
		return
	}

	// ----- Output directory ----------------------------------------------
	outDir := filepath.Join(rootDir, clusterName)
	if mkdirErr := os.MkdirAll(outDir, 0755); mkdirErr != nil {
		fmt.Printf("  [ERROR] Cannot create directory %s: %v\n", outDir, mkdirErr)
		return
	}

	// ----- Script-generation helpers -------------------------------------
	getLatestPatch := func(minor int) string {
		return latestPatchForMinor(allVersions, minor)
	}

	emit := func(fname string, tpl *template.Template, data any, from, to, who string) bool {
		if err := writeScript(fname, tpl, data); err != nil {
			fmt.Printf("  [ERROR] %v\n", err)
			return false
		}
		fmt.Printf("  [+] Created: %s  (%s %s → %s)\n", filepath.Base(fname), who, from, to)
		return true
	}

	genCPScript := func(step, fromMinor, toMinor int) bool {
		from, to := getLatestPatch(fromMinor), getLatestPatch(toMinor)
		if to == "" {
			fmt.Printf("  [WARN] No published version for 1.%d in %s. Stopping CP chain.\n", toMinor, location)
			return false
		}
		f := filepath.Join(outDir, fmt.Sprintf("%d_upgrade_control_plane_%s_to_%s.sh", step, from, to))
		return emit(f, cpTpl, cpScriptData{step, clusterName, rg, from, to}, from, to, "CP")
	}

	genNPScript := func(step int, np *nodepoolInfo, fromMinor, toMinor int) bool {
		from, to := getLatestPatch(fromMinor), getLatestPatch(toMinor)
		if to == "" {
			fmt.Printf("  [WARN] No published version for 1.%d in %s. Skipping NP %s.\n", toMinor, location, np.name)
			return false
		}
		f := filepath.Join(outDir, fmt.Sprintf("%d_upgrade_%s_%s_to_%s.sh", step, np.name, from, to))
		return emit(f, npTpl, npScriptData{step, clusterName, rg, np.name, from, to}, from, to, "NP "+np.name)
	}

	getMinNPMinor := func() int {
		if len(nodepools) == 0 {
			return targetVersion.minor
		}
		return slices.MinFunc(nodepools, func(a, b nodepoolInfo) int {
			return cmp.Compare(a.curMinor, b.curMinor)
		}).curMinor
	}

	// ----- Upgrade sequence ----------------------------------------------
	//
	// AKS constraint: every nodepool must stay within 2 minor versions of
	// the control plane at all times.
	//
	// Algorithm:
	//   Phase 1 — advance CP one minor at a time up to min(minNP+2, target).
	//   Phase 2 — advance every lagging nodepool one minor at a time up to
	//             the current CP level (one script per nodepool per hop).
	//   Repeat until both CP and all nodepools reach the target minor.
	fmt.Printf("  Generating upgrade sequence (CP minor: %d → %d)...\n",
		cpVersion.minor, targetVersion.minor)

	step := 1
	currentCP := cpVersion.minor
	minNP := getMinNPMinor()

upradeLoop:
	for currentCP < targetVersion.minor || minNP < targetVersion.minor {
		// Phase 1: advance CP up to min(minNP+2, target)
		for currentCP < min(minNP+2, targetVersion.minor) {
			if !genCPScript(step, currentCP, currentCP+1) {
				break upradeLoop
			}
			step++
			currentCP++
		}

		// Phase 2: bring all lagging nodepools one hop at a time
		for moved := true; moved; {
			moved = false
			for i := range nodepools {
				if np := &nodepools[i]; np.curMinor < currentCP {
					if genNPScript(step, np, np.curMinor, np.curMinor+1) {
						step++
						np.curMinor++
						moved = true
					}
				}
			}
		}

		minNP = getMinNPMinor()
	}

	fmt.Printf("\n  Scripts created: %d   |   Directory: %s\n", step-1, outDir)
}

// ---------------------------------------------------------------------------
// checkQuota — validates that surge VMs fit within regional and per-family quota
// ---------------------------------------------------------------------------

func checkQuota(
	ctx context.Context,
	clusterName, rg, location string,
	nodepools []nodepoolInfo,
	skuClient *armcompute.ResourceSKUsClient,
	usageClient *armcompute.UsageClient,
) bool {
	sep := strings.Repeat("═", 62)
	fmt.Printf("\n%s\n Quota check: %s  (%s)  —  %s\n%s\n", sep, clusterName, rg, location, sep)

	if len(nodepools) == 0 {
		fmt.Println("  [INFO] No nodepools found; skipping quota check.")
		return true
	}

	// ----- Build SKU cache (vCPUs + family) for unique VM sizes ----------
	type skuInfo struct {
		vcpus  int64
		family string
	}
	skuCache := make(map[string]skuInfo) // vmSize → info

	// Collect unique VM sizes, then fill the entire cache in a single pager pass.
	needed := make(map[string]bool, len(nodepools))
	for _, np := range nodepools {
		needed[np.vmSize] = true
	}
	if len(needed) > 0 {
		filter := fmt.Sprintf("location eq '%s'", location)
		skuPager := skuClient.NewListPager(&armcompute.ResourceSKUsClientListOptions{
			Filter: &filter,
		})
		func() {
			for skuPager.More() {
				page, err := skuPager.NextPage(ctx)
				if err != nil {
					return
				}
				for _, sku := range page.Value {
					if ptrStr(sku.ResourceType) != "virtualMachines" {
						continue
					}
					name := ptrStr(sku.Name)
					if !needed[name] {
						continue
					}
					if _, cached := skuCache[name]; cached {
						continue
					}
					info := skuInfo{family: ptrStr(sku.Family)}
					for _, cap := range sku.Capabilities {
						if ptrStr(cap.Name) == "vCPUs" {
							v, _ := strconv.ParseInt(ptrStr(cap.Value), 10, 64)
							info.vcpus = v
						}
					}
					skuCache[name] = info
					if len(skuCache) == len(needed) {
						return
					}
				}
			}
		}()
		for size := range needed {
			if _, ok := skuCache[size]; !ok {
				skuCache[size] = skuInfo{family: "UNKNOWN"}
			}
		}
	}

	// ----- Print nodepool table ------------------------------------------
	fmt.Printf("\n  %-20s %-22s %6s %6s %6s %10s\n",
		"NODEPOOL", "VM SIZE", "NODES", "SURGE", "CPU/VM", "EXTRA CPUs")
	fmt.Printf("  %s\n", strings.Repeat("─", 71))

	type familyExtra struct {
		extra   int64
		display string
	}
	familyExtras := make(map[string]*familyExtra)
	totalExtra := int64(0)

	for _, np := range nodepools {
		surge := int64(np.surgeCount())
		info := skuCache[np.vmSize]
		extra := surge * info.vcpus
		totalExtra += extra

		fe := familyExtras[info.family]
		if fe == nil {
			fe = &familyExtra{display: info.family}
			familyExtras[info.family] = fe
		}
		fe.extra += extra

		fmt.Printf("  %-20s %-22s %6d %6d %6d %10d\n",
			np.name, np.vmSize, np.nodeCount, surge, info.vcpus, extra)
	}

	// ----- Fetch regional usage ------------------------------------------
	type usageEntry struct {
		used    int64
		limit   int64
		display string
	}
	quotaMap := make(map[string]*usageEntry) // key = Name.Value

	usagePager := usageClient.NewListPager(location, nil)
	for usagePager.More() {
		page, err := usagePager.NextPage(ctx)
		if err != nil {
			fmt.Printf("\n  [WARN] Could not retrieve VM quota for %s: %v. Skipping quota validation.\n",
				location, err)
			return true // non-fatal: don't block script generation
		}
		for _, u := range page.Value {
			if u.Name == nil {
				continue
			}
			key := ptrStr(u.Name.Value)
			cur := int64(0)
			if u.CurrentValue != nil {
				cur = int64(*u.CurrentValue)
			}
			lim := int64(0)
			if u.Limit != nil {
				lim = *u.Limit
			}
			quotaMap[key] = &usageEntry{
				used:    cur,
				limit:   lim,
				display: ptrStr(u.Name.LocalizedValue),
			}
		}
	}

	// ----- Check per-family and regional totals --------------------------
	fmt.Printf("\n  VM FAMILY / REGIONAL QUOTA:\n")
	fmt.Printf("  %-38s %7s %7s %7s %9s  %s\n",
		"FAMILY", "EXTRA", "USED", "LIMIT", "HEADROOM", "STATUS")
	fmt.Printf("  %s\n", strings.Repeat("─", 80))

	allOK := true

	families := slices.Sorted(maps.Keys(familyExtras))

	for _, family := range families {
		fe := familyExtras[family]
		q := quotaMap[family]
		if q == nil {
			fmt.Printf("  %-38s %7d %7s %7s %9s  [WARN: quota not found]\n",
				family, fe.extra, "?", "?", "?")
			continue
		}
		headroom := q.limit - q.used
		status := "[OK]"
		if fe.extra > headroom {
			status = "[INSUFFICIENT]"
			allOK = false
		}
		label := q.display
		if label == "" {
			label = family
		}
		fmt.Printf("  %-38s %7d %7d %7d %9d  %s\n",
			label, fe.extra, q.used, q.limit, headroom, status)
	}

	// Regional total (key "cores")
	if reg := quotaMap["cores"]; reg != nil {
		headroom := reg.limit - reg.used
		status := "[OK]"
		if totalExtra > headroom {
			status = "[INSUFFICIENT]"
			allOK = false
		}
		fmt.Printf("  %-38s %7d %7d %7d %9d  %s\n",
			"Total Regional vCPUs", totalExtra, reg.used, reg.limit, headroom, status)
	}

	fmt.Println()
	return allOK
}

// ---------------------------------------------------------------------------
// listRegionK8sVersions — all stable patch versions in region, sorted asc
// ---------------------------------------------------------------------------

func listRegionK8sVersions(
	ctx context.Context,
	client *armcontainerservice.ManagedClustersClient,
	location string,
) ([]k8sVersion, error) {
	resp, err := client.ListKubernetesVersions(ctx, location, nil)
	if err != nil {
		return nil, err
	}

	var versions []k8sVersion
	for _, kv := range resp.Values {
		if kv == nil {
			continue
		}
		if kv.IsPreview != nil && *kv.IsPreview {
			continue
		}
		for vStr := range kv.PatchVersions {
			parsed, parseErr := parseVersion(vStr)
			if parseErr == nil {
				versions = append(versions, parsed)
			}
		}
	}
	slices.SortFunc(versions, func(a, b k8sVersion) int {
		if a.minor != b.minor {
			return cmp.Compare(a.minor, b.minor)
		}
		return cmp.Compare(a.patch, b.patch)
	})
	return versions, nil
}

// ---------------------------------------------------------------------------
// resolveFirstEnabledSubscription — pick first enabled subscription
// ---------------------------------------------------------------------------

func resolveFirstEnabledSubscription(
	ctx context.Context,
	cred azcore.TokenCredential,
) (string, error) {
	client, err := armsubscriptions.NewClient(cred, nil)
	if err != nil {
		return "", err
	}
	pager := client.NewListPager(nil)
	for pager.More() {
		page, pageErr := pager.NextPage(ctx)
		if pageErr != nil {
			return "", pageErr
		}
		for _, sub := range page.Value {
			if sub.State != nil && *sub.State == armsubscriptions.SubscriptionStateEnabled {
				return ptrStr(sub.SubscriptionID), nil
			}
		}
	}
	return "", errors.New("no enabled subscriptions found for the current credential")
}

// ---------------------------------------------------------------------------
// writeScript — render a template and write it to path with +x permissions
// ---------------------------------------------------------------------------

func writeScript(path string, tpl *template.Template, data any) error {
	var buf bytes.Buffer
	if err := tpl.Execute(&buf, data); err != nil {
		return fmt.Errorf("template error for %s: %w", path, err)
	}
	if err := os.WriteFile(path, buf.Bytes(), 0755); err != nil {
		return fmt.Errorf("cannot write %s: %w", path, err)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

func ptrStr(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func resourceGroupFromID(id string) string {
	parts := strings.Split(id, "/")
	for i, p := range parts {
		if strings.EqualFold(p, "resourceGroups") && i+1 < len(parts) {
			return parts[i+1]
		}
	}
	return ""
}
