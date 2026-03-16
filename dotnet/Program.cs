using Azure.Identity;
using Azure.ResourceManager;
using Azure.ResourceManager.Compute;
using Azure.ResourceManager.ContainerService;
using Azure.ResourceManager.ContainerService.Models;
using Azure.ResourceManager.Resources;
using System.Text;
using System.Text.RegularExpressions;

int subIdx = Array.IndexOf(args, "--subscription");
string? subscriptionId = subIdx >= 0 ? args[subIdx + 1] : Environment.GetEnvironmentVariable("AZURE_SUBSCRIPTION_ID");

var armClient = new ArmClient(new DefaultAzureCredential());

if (subscriptionId == null)
{
    await foreach (var sub in armClient.GetSubscriptions().GetAllAsync())
        if (sub.Data.State?.ToString() == "Enabled") { subscriptionId = sub.Data.SubscriptionId; break; }
}
if (subscriptionId == null)
{
    Console.Error.WriteLine("ERROR: No subscription found. Use --subscription <id> or set AZURE_SUBSCRIPTION_ID.");
    return 1;
}

var subscription = armClient.GetSubscriptionResource(SubscriptionResource.CreateResourceIdentifier(subscriptionId));
var outRoot = $"upgrade-scripts-{DateTime.Now:yyyyMMdd_HHmmss}";
Directory.CreateDirectory(outRoot);

var cpTemplate = LoadTemplate("control_plane.sh.tmpl");
var npTemplate = LoadTemplate("nodepool.sh.tmpl");

await foreach (var cluster in subscription.GetContainerServiceManagedClustersAsync())
{
    var clusterName = cluster.Data.Name;
    var resourceGroup = cluster.Id.ResourceGroupName!;
    var location = cluster.Data.Location.ToString().ToLowerInvariant().Replace(" ", "");
    var currentVersion = cluster.Data.CurrentKubernetesVersion ?? cluster.Data.KubernetesVersion ?? "";

    if (!TryParseVersion(currentVersion, out _, out int curMinor, out _))
    {
        Console.WriteLine($"WARN [{clusterName}]: Cannot parse version '{currentVersion}', skipping.");
        continue;
    }

    KubernetesVersionListResult versionsResult;
    try { versionsResult = (await subscription.GetKubernetesVersionsManagedClusterAsync(location)).Value; }
    catch (Exception ex) { Console.WriteLine($"WARN [{clusterName}]: Failed to list versions in {location}: {ex.Message}, skipping."); continue; }

    var bestPatch = new Dictionary<int, (int patch, string full)>();
    foreach (var kv in versionsResult.Values)
    {
        if (kv.IsPreview == true || kv.PatchVersions == null) continue;
        foreach (var p in kv.PatchVersions.Keys)
            if (TryParseVersion(p, out int maj, out int min, out int pat) && maj == 1)
                if (!bestPatch.TryGetValue(min, out var cur) || pat > cur.patch)
                    bestPatch[min] = (pat, p);
    }

    if (bestPatch.Count == 0) { Console.WriteLine($"WARN [{clusterName}]: No stable versions in {location}."); continue; }
    int targetMinor = bestPatch.Keys.Max();

    if (curMinor >= targetMinor)
    {
        Console.WriteLine($"INFO [{clusterName}]: Already at {currentVersion} (target minor {targetMinor}), skipping.");
        continue;
    }

    var pools = new List<PoolInfo>();
    try
    {
        await foreach (var pool in cluster.GetContainerServiceAgentPools().GetAllAsync())
        {
            var pv = pool.Data.CurrentOrchestratorVersion ?? pool.Data.OrchestratorVersion ?? "";
            if (!TryParseVersion(pv, out _, out int pMin, out _))
            {
                Console.WriteLine($"WARN [{clusterName}/{pool.Data.Name}]: Cannot parse pool version '{pv}', using CP version.");
                pMin = curMinor; pv = currentVersion;
            }
            pools.Add(new PoolInfo(pool.Data.Name!, pv, pMin,
                pool.Data.Count ?? 1, pool.Data.VmSize ?? "", pool.Data.UpgradeSettings?.MaxSurge));
        }
    }
    catch (Exception ex) { Console.WriteLine($"WARN [{clusterName}]: Failed to list node pools: {ex.Message}, skipping."); continue; }

    if (!await CheckQuota(subscription, location, pools, clusterName, bestPatch, targetMinor))
        continue;

    var clusterDir = Path.Combine(outRoot, clusterName);
    Directory.CreateDirectory(clusterDir);

    int step = 1, cpMinor = curMinor;
    var cpVersion = currentVersion;
    bool stop = false;

    while (!stop && (cpMinor < targetMinor || pools.Any(p => p.MinorVersion < targetMinor)))
    {
        int minPool = pools.Count > 0 ? pools.Min(p => p.MinorVersion) : cpMinor;
        int cpCeil = Math.Min(minPool + 2, targetMinor);
        while (!stop && cpMinor < cpCeil)
        {
            int next = cpMinor + 1;
            if (!bestPatch.TryGetValue(next, out var v)) { Console.WriteLine($"WARN [{clusterName}]: No patch for 1.{next}.x, stopping."); stop = true; break; }
            WriteScript(clusterDir, step, Render(cpTemplate, new() {
                ["Step"] = step.ToString(), ["ClusterName"] = clusterName, ["ResourceGroup"] = resourceGroup,
                ["FromVersion"] = cpVersion, ["ToVersion"] = v.full
            }));
            step++; cpVersion = v.full; cpMinor = next;
        }

        bool anyAdvanced = false;
        for (int i = 0; i < pools.Count && !stop; i++)
        {
            while (!stop && pools[i].MinorVersion < cpMinor)
            {
                int next = pools[i].MinorVersion + 1;
                if (!bestPatch.TryGetValue(next, out var v)) { Console.WriteLine($"WARN [{clusterName}/{pools[i].Name}]: No patch for 1.{next}.x, stopping."); stop = true; break; }
                WriteScript(clusterDir, step, Render(npTemplate, new() {
                    ["Step"] = step.ToString(), ["ClusterName"] = clusterName, ["ResourceGroup"] = resourceGroup,
                    ["NodepoolName"] = pools[i].Name, ["FromVersion"] = pools[i].Version, ["ToVersion"] = v.full
                }));
                step++;
                pools[i] = pools[i] with { Version = v.full, MinorVersion = next };
                anyAdvanced = true;
            }
        }
        if (!stop && !anyAdvanced && cpMinor == targetMinor) break;
    }
    Console.WriteLine($"INFO [{clusterName}]: Generated {step - 1} script(s) in {clusterDir}/");
}

Console.WriteLine("Done.");
return 0;

static bool TryParseVersion(string v, out int major, out int minor, out int patch)
{
    major = minor = patch = 0;
    var m = Regex.Match(v, @"^(\d+)\.(\d+)\.(\d+)$");
    if (!m.Success) return false;
    major = int.Parse(m.Groups[1].Value); minor = int.Parse(m.Groups[2].Value); patch = int.Parse(m.Groups[3].Value);
    return true;
}

static void WriteScript(string dir, int step, string content)
{
    var nameLine = content.Split('\n').FirstOrDefault(l => l.StartsWith("# Script:")) ?? "";
    var filename = nameLine.Length > 9 ? nameLine[9..].Trim() : $"{step}_script.sh";
    var path = Path.Combine(dir, filename);
    File.WriteAllText(path, content, new UTF8Encoding(false));
    if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS())
        File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute |
            UnixFileMode.GroupRead | UnixFileMode.GroupExecute | UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
}

static string LoadTemplate(string name) =>
    File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "templates", name), new UTF8Encoding(false));

static string Render(string template, Dictionary<string, string> vars) =>
    vars.Aggregate(template, (s, kv) => s.Replace("{{" + kv.Key + "}}", kv.Value));

static int CalcSurge(string? maxSurge, int count)
{
    if (string.IsNullOrEmpty(maxSurge) || maxSurge == "null") return 1;
    if (maxSurge.EndsWith('%') && int.TryParse(maxSurge.TrimEnd('%'), out int pct))
        return Math.Max(1, (int)Math.Ceiling(count * pct / 100.0));
    return int.TryParse(maxSurge, out int abs) ? Math.Max(1, abs) : 1;
}

static async Task<bool> CheckQuota(SubscriptionResource subscription, string location,
    List<PoolInfo> pools, string clusterName,
    Dictionary<int, (int patch, string full)> bestPatch, int targetMinor)
{
    var skuMap = new Dictionary<string, (string family, int vcpus)>(StringComparer.OrdinalIgnoreCase);
    try
    {
        await foreach (var sku in subscription.GetComputeResourceSkusAsync($"location eq '{location}'"))
        {
            if (sku.ResourceType != "virtualMachines") continue;
            int.TryParse(sku.Capabilities?.FirstOrDefault(c => c.Name == "vCPUs")?.Value, out int vcpus);
            skuMap[sku.Name!] = (sku.Family ?? "UNKNOWN", vcpus);
        }
    }
    catch (Exception ex) { Console.WriteLine($"WARN [{clusterName}]: SKU lookup failed ({ex.Message}), skipping quota check."); return true; }

    var usageByName = new Dictionary<string, (long current, long limit)>(StringComparer.OrdinalIgnoreCase);
    try
    {
        await foreach (var u in subscription.GetUsagesAsync(location))
            usageByName[u.Name.Value!] = (u.CurrentValue, u.Limit);
    }
    catch (Exception ex) { Console.WriteLine($"WARN [{clusterName}]: Usage lookup failed ({ex.Message}), skipping quota check."); return true; }

    var extraByFamily = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
    int totalExtra = 0;
    foreach (var pool in pools)
    {
        int surge = CalcSurge(pool.MaxSurge, pool.Count);
        if (!skuMap.TryGetValue(pool.VmSize, out var sku))
        {
            Console.WriteLine($"WARN [{clusterName}/{pool.Name}]: VM size '{pool.VmSize}' not found in SKUs.");
            sku = ("UNKNOWN", 0);
        }
        int extra = surge * sku.vcpus;
        extraByFamily[sku.family] = extraByFamily.GetValueOrDefault(sku.family) + extra;
        totalExtra += extra;
    }

    Console.WriteLine($"\nQuota check for [{clusterName}] in {location}:");
    Console.WriteLine($"  {"VM Family",-40} {"Extra vCPUs",11} {"Used",8} {"Limit",8} {"Headroom",9}");
    bool ok = true;
    foreach (var (family, extra) in extraByFamily)
    {
        usageByName.TryGetValue(family, out var usage);
        long headroom = usage.limit - usage.current;
        bool pass = extra <= headroom;
        Console.WriteLine($"  {family,-40} {extra,11} {usage.current,8} {usage.limit,8} {headroom,9}  {(pass ? "OK" : "INSUFFICIENT")}");
        if (!pass) ok = false;
    }
    if (usageByName.TryGetValue("cores", out var cores))
    {
        long headroom = cores.limit - cores.current;
        bool pass = totalExtra <= headroom;
        Console.WriteLine($"  {"Regional cores (total)",-40} {totalExtra,11} {cores.current,8} {cores.limit,8} {headroom,9}  {(pass ? "OK" : "INSUFFICIENT")}");
        if (!pass) ok = false;
    }
    Console.WriteLine();

    if (!ok) Console.WriteLine($"SKIP [{clusterName}]: Insufficient vCPU quota in {location}.");
    return ok;
}

record PoolInfo(string Name, string Version, int MinorVersion, int Count, string VmSize, string? MaxSurge);
