# Kata node initialization slowdown: containerd stamp loop

**Date:** 2026-08-13  
**Status:** Root cause reproduced on both 6.6 and 6.18 images. Kernel exclusivity is refuted.

## Summary

AKS node pools made from custom image `AzureLinuxV3gen2:1.1785945779.14409`
(kernel `6.18.34.mshv1-1.azl3`) took about 8.5 minutes to become Ready. An initial run of
`1.1785886971.3925` (kernel `6.6.137.mshv2-1.azl3`) was much faster, but a repeated 6.6 run
reproduced the full delay:

| Image | Kernel | Intel `Standard_L8s_v3` | AMD `Standard_L8as_v3` |
|---|---|---:|---:|
| `1.1785886971.3925` | 6.6 | 196 s, then **491 s** | 226 s |
| `1.1785945779.14409` | 6.18 | 498-516 s | 538 s |

The extra delay is not spent discovering NVMe storage. NVMe initialization completed at
approximately 2.2 seconds, nodes registered, and Kubernetes reported `container runtime is
down`. The blocking interval is a systemd restart loop in the Kata containerd configuration
stamping mechanism present in **both** images.

The old-image reproduction refutes the claim that the slowdown is unique to kernel 6.18. Pool
readiness depends on whether any node loses a race against systemd's 10-second start-limit window.

## Root cause

Both tested images contain the same units and script:

- [`stamp-kata-containerd-config.path`](../parts/linux/cloud-init/artifacts/stamp-kata-containerd-config.path)
  watches for `/opt/azure/containers/provision.complete`.
- [`stamp-kata-containerd-config.service`](../parts/linux/cloud-init/artifacts/stamp-kata-containerd-config.service)
  declared both `After=containerd.service` and `Requires=containerd.service`.
- [`stamp-kata-containerd-config.sh`](../parts/linux/cloud-init/artifacts/stamp-kata-containerd-config.sh)
  copies the desired configuration, calls `systemctl restart containerd`, and only then creates
  `.kata-containerd-config-stamped`.

This creates a deterministic dependency loop:

1. Node provisioning creates `provision.complete`.
2. The path unit starts the stamp service.
3. The stamp service restarts containerd.
4. Stopping the required `containerd.service` causes systemd to stop the stamp service.
5. The script receives SIGTERM before creating its success marker.
6. `PathExists=provision.complete` remains true, so the path unit starts the service again.
7. The cycle reaches the systemd start and path-trigger limits.

The first attempt was captured as:

```text
Starting stamp-kata-containerd-config.service...
stamping /etc/containerd/config.toml ...
restarting containerd to apply new config
stamp-kata-containerd-config.service: Failed with result 'signal'.
Stopped stamp-kata-containerd-config.service...
```

The script's marker was still absent after the node recovered. The path unit reported
`Result=trigger-limit-hit`, while the stamp service reported `Result=signal`.

## Timeline from an affected node

| UTC time | Event |
|---|---|
| `22:32:52.984` | CSE creates `provision.complete` |
| `22:32:53` | Stamp path fires; stamp/containerd restart loop begins |
| `22:32:53.242` | Kata containerd configuration written |
| `22:32:53` | Containerd reaches its five-start limit; runtime remains down |
| `22:39:22` | Kubelet hits its 60-second watchdog and is restarted |
| `22:39:24` | Kubelet's `Wants=containerd.service` pulls containerd back up |
| `22:39:25` | Containerd serves its sockets using the Kata configuration |
| approximately `22:39:46` | Node becomes Ready |

Containerd did not recover because its own retry delay expired. Its service has
`RestartSec=100ms`, `StartLimitIntervalSec=10s`, and `StartLimitBurst=5`. Recovery was an
incidental consequence of the later kubelet watchdog restart.

## Why earlier runs looked 6.18-specific

The old-image experiment on 2026-08-13 refuted the original image-content hypothesis:

- Both images use `systemd-255-33.azl3`.
- The path unit, service unit, and stamp script are byte-identical across the inspected nodes.
- Both images leave the success marker absent and the stamp service failed with `Result=signal`.
- Both images can enter the full runtime-down and kubelet-watchdog recovery path.

Artifact hashes from both images:

| Artifact | SHA-256 |
|---|---|
| `stamp-kata-containerd-config.path` | `b9ba1e8a39af392a21790ebb84ec72831418e6b83aae1f3e900e523e25795f17` |
| `stamp-kata-containerd-config.service` | `6663e05f956c0fa67cba384eaf1e8d94ac1526e955485ada1cf7064a8ccccf04` |
| `stamp-kata-containerd-config.sh` | `eba4dfd7255ee9edf21272006df3018ad6a31b4e9e64058593480e97fbd2fefb` |

The outcome is timing-sensitive because containerd allows five starts per 10 seconds. The stamp
path contributes five rapid containerd restarts. Whether the earlier initial containerd start is
still inside that 10-second accounting window determines the outcome:

| Node | Initial containerd start to stamp | Outcome |
|---|---:|---|
| Fast 6.6 `vmss000000` | approximately 9.9 s | Initial start aged out during the loop; final containerd start survived |
| Delayed 6.6 `vmss000002` | approximately 7.4 s | Initial start remained in-window; containerd hit its limit and stayed down |
| Inspected 6.18 node | Same start-limit collision | Containerd stayed down until kubelet watchdog recovery |

This explains the misleading aggregate results. AKS pool readiness is determined by the slowest
node: the repeated 6.6 pool had three Ready transitions around `23:30`, but one node did not become
Ready until `23:36:30`, making the four-node result 491 seconds. The earlier 196-second 6.6 run
likely had no node lose this race.

The kernel may shift provisioning timing by a few seconds, which could change the probability of
hitting the race, but it is neither necessary nor sufficient for the failure. NVMe discovery is
complete long before the stamp trigger, and the same failure occurs on Intel and AMD pools.

## Minimal reproduction

The exact loop was reproduced on the affected Azure Linux 3 host with systemd
`255-33.azl3`, using only temporary dummy units:

```bash
sudo ./doc/repro-systemd-requires-restart-loop.sh --system
```

The script creates temporary units under `/run`; it does not modify persistent host services. It
uses a dummy `sleep` worker. A oneshot service `Requires` the worker and then restarts it, while a
path unit keeps the oneshot eligible to run. It succeeds only when it observes the same properties
as the node failure:

- the stamp service is terminated while restarting its required worker;
- the post-restart marker is never created;
- the path unit reaches `trigger-limit-hit`.

No AKS, containerd, NVMe device, or kernel 6.18 feature is involved.

For comparison, user mode is available without root:

```bash
./doc/repro-systemd-requires-restart-loop.sh --user
```

The same graph did **not** reproduce under Ubuntu systemd 249: the restart completed and the
marker was created. This points to systemd restart/dependency semantics as part of the exposure
condition and makes the old image's exact `systemd` package version a required A/B datum. It does
not restore a kernel hypothesis; both experiments are independent of the kernel's NVMe path.

## Old-image experiment

Both exact gallery versions were published with `excludeFromLatest=false`, so the experiment used
those immutable versions rather than `latest`.

### Completed 6.6 rerun

The experiment reused `mariner-kata` in the same subscription and region after deleting the
four-node AMD pool. It added:

- Pool: `old66nvme`
- Image: `1.1785886971.3925`
- Kernel: `6.6.137.mshv2-1.azl3`
- VM size: `Standard_L8s_v3`
- Node count: 4
- Result: all nodes Ready after **491 seconds**

The run log is
[`mariner-kata-old66-20260813T232819Z.log`](kata-node-init-containerd-loop/mariner-kata-old66-20260813T232819Z.log).

Ready transitions were:

| Node | Ready transition |
|---|---|
| `vmss000000` | `23:29:59` |
| `vmss000001` | `23:30:43` |
| `vmss000002` | `23:36:30` |
| `vmss000003` | `23:30:39` |

On delayed node `vmss000002`:

- Node registered at `23:29:34`.
- The containerd socket was still absent at `23:35:29`.
- Kubelet hit its watchdog and restarted at approximately `23:36:02`.
- Kubelet's dependency pulled containerd back up.
- Node became Ready at `23:36:30`.

This is the same recovery sequence observed on the inspected 6.18 node.

### Remaining statistical experiment

The causal defect no longer needs a kernel A/B, but quantifying how often each image loses the
race requires repeated one-node trials. Alternate immutable images (`6.6, 6.18, 6.18, 6.6`) and
record the interval from first successful containerd activation to `provision.complete`.

Classify each trial as:

- **escaped:** final stamp-loop restart survives and no kubelet watchdog recovery is needed;
- **hit:** containerd reaches `start-limit-hit` and recovery waits for kubelet restart.

This can determine whether 6.18 changes the probability of exposure, but not whether the broken
unit relationship exists; that is already confirmed on both images.

### Evidence commands

Collect the following from one node in future trials:

```bash
uname -r
rpm -q systemd containerd
systemctl cat stamp-kata-containerd-config.path
systemctl cat stamp-kata-containerd-config.service
systemctl show stamp-kata-containerd-config.path \
  -p LoadState -p UnitFileState -p ActiveState -p Result
systemctl show stamp-kata-containerd-config.service \
  -p LoadState -p UnitFileState -p ActiveState -p Result
systemctl show containerd.service \
  -p RestartUSec -p StartLimitIntervalUSec -p StartLimitBurst
stat /opt/azure/containers/provision.complete \
  /opt/azure/containers/.kata-containerd-config-stamped \
  /opt/azure/containers/stamp-kata-containerd-config.sh \
  /etc/containerd/config.toml
sha256sum /etc/systemd/system/stamp-kata-containerd-config.{path,service} \
  /opt/azure/containers/stamp-kata-containerd-config.sh
journalctl -b -u containerd.service \
  -u stamp-kata-containerd-config.path \
  -u stamp-kata-containerd-config.service \
  -u kubelet.service -o short-monotonic --no-pager
```

## Fix

The fix belongs in AgentBaker, not CBL-Mariner. The affected image was built from
`upstream/cameronbaird/kata-erofs` at AgentBaker commit `d0c2b84054`. That commit added the stamp
artifacts under `parts/linux/cloud-init/artifacts/` and wired them into
[`vhd-image-builder-mariner.json`](../vhdbuilder/packer/vhd-image-builder-mariner.json).

This change removes the following relationships from the stamp service:

```ini
After=containerd.service
Requires=containerd.service
```

The script itself starts or restarts containerd and checks the command's result. The oneshot must
not require a service that it intentionally stops.

## Validation criteria

Build an otherwise identical image from this change and validate all of the following:

- stamp service exits successfully exactly once;
- `.kata-containerd-config-stamped` exists;
- containerd has one intentional restart and remains active;
- path and service results are `success`, not `signal` or `trigger-limit-hit`;
- kubelet does not recover containerd through its watchdog;
- repeated Intel and AMD trials show no containerd start-limit or watchdog recovery outliers;
- a reboot does not restamp or restart containerd unnecessarily.

The change is confirmed if the fixed image returns to approximately 3-4 minute readiness, the
marker is created, and neither unit reaches a start or trigger limit. If the fixed image still
spends several minutes with containerd down, inspect the new first failure before returning to
kernel or storage hypotheses.

## Scope and ruled-out items

- Required NVMe and Hyper-V kernel options are enabled in the 6.18 `kernel-mshv` config.
- `CONFIG_HYPERV_ROOT_PVIOMMU` is not a missing requirement; it was removed upstream.
- NVMe enumeration completes near the beginning of boot.
- The approximately two-hour PIS interval in `systemd-analyze` is not nodepool readiness time;
  the bake and real-node provisioning phases are separate boots/runs.
- `NetworkPluginNotReady` is downstream of the missing containerd socket, not the initiating
  failure.