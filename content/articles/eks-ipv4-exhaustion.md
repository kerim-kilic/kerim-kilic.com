---
title: "Your EKS cluster has CPU to spare and no IP addresses left"
date: 2026-11-07
description: "Running out of IPv4 in EKS: why the VPC CNI uses so many addresses, how to measure it, and the options, cheapest first."
tags: ["aws", "eks", "kubernetes", "networking", "vpc"]
image: "og/eks-ipv4-exhaustion.png"
draft: true
---

Pods are stuck in `ContainerCreating`, the events say the CNI failed to assign an IP address, and the nodes have plenty of CPU and memory free. The cluster autoscaler (or Karpenter) adds a node, which doesn't help and can make things worse, because the new node needs addresses of its own. The subnet is full.

On EKS, every pod gets an address from your VPC subnet by default. That's a good default, but in a modest address range a cluster can run out of IPv4 long before it runs out of CPU or memory. I wanted to see this happen, so I read the AWS documentation and ran a small lab in a sandbox account. Below is where the addresses go, how to see how close you are, and the fixes I tried, cheapest first. The lab code is linked at the end.

## Why EKS uses so many addresses

EKS uses the [Amazon VPC CNI](https://docs.aws.amazon.com/eks/latest/userguide/managing-vpc-cni.html) for pod networking by default. Instead of building an overlay network, it gives each pod a secondary IP address on one of the node's elastic network interfaces (ENIs). Pods become ordinary members of the VPC. They show up in VPC flow logs, anything in the network can reach them without translation, and with [security groups for pods](https://docs.aws.amazon.com/eks/latest/userguide/security-groups-for-pods.html) they can have security groups of their own.

The downside is that pod addresses come out of the same subnets as everything else, and the CNI takes them in batches.

### The warm pool

A daemon on each node, `ipamd`, keeps spare addresses attached so that new pods start quickly, without waiting for an EC2 API call. With the default setting, [`WARM_ENI_TARGET=1`](https://github.com/aws/amazon-vpc-cni-k8s/blob/master/README.md#warm_eni_target), it tries to keep one whole ENI's worth of free addresses on every node, on top of the ones in use.

And the count goes up sooner than you'd think. On a node with no pods, the free addresses on its first ENI already count as the spare. As soon as one pod uses one of them, that ENI is no longer completely free, so the CNI attaches another. The [CNI's own examples](https://github.com/aws/amazon-vpc-cni-k8s/blob/master/docs/eni-and-ip-target.md) show it: a `t3.small` holds one ENI with no pods and three ENIs with five.

### A worked example

Take a `t3.medium`. It supports 3 ENIs with 6 IPv4 addresses each. One address on each ENI belongs to the ENI itself, so the maximum number of pods is:

```text
ENIs x (IPs per ENI - 1) + 2  =  3 x (6 - 1) + 2  =  17
```

The `+ 2` is for the VPC CNI and `kube-proxy`, which run on the node's own address. This is the same formula the [EKS user guide](https://docs.aws.amazon.com/eks/latest/userguide/choosing-instance-type.html#max-pods-precedence) gives, and the [published table](https://github.com/aws/amazon-vpc-cni-k8s/blob/master/misc/eni-max-pods.txt) agrees: 17 pods.

As pods arrive, the count goes up in steps. With no pods, the node holds one ENI: 6 addresses. The first pod brings a second ENI, so anywhere from one to five pods holds 12 addresses. The sixth pod brings the third: 18 addresses for six pods.

Two of those nodes with six pods each need 36 addresses. A `/27` subnet has 27.

### What that looks like in a real cluster

To check the numbers, I built a deliberately small cluster in a sandbox account: four `t3.medium` nodes in two `/27` subnets, carved out of a `10.20.0.0/24` VPC in `us-east-1`, on Kubernetes 1.36 with VPC CNI `v1.23.2`. Then I scaled up a deployment of `pause` pods, five at a time, and measured after each round. Kubernetes allows 17 pods per node, which leaves room for 58 `pause` pods next to the system pods.

The warm pool showed up before a single `pause` pod existed. With only CoreDNS running, the CNI already held 30 addresses for 2 pods. After the first five `pause` pods, it held 40 addresses for 7 pods, and the two subnets had 4 free addresses between them.

The first pod failed at 40 `pause` pods, and the cluster never got past 38 running. At that moment, one `/27` looked like this:

| In the subnet | Addresses |
|---|---|
| Reserved by AWS | 5 |
| A network interface of the EKS control plane | 1 |
| Node A: two ENIs of 6 addresses, all in use | 12 |
| Node B: the same | 12 |
| **Free** | **2** |

Each node had 10 pods and wanted a third ENI, which needs 6 addresses. The subnet had 2. So each node stopped at 10 pods, against 15 its ENIs could hold and 17 Kubernetes allows, with CPU and memory almost untouched.

### The addresses people forget

The subnet also holds:

- every node's primary address;
- the 2 to 4 network interfaces the EKS control plane [creates in the subnets you give the cluster](https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html#network-requirements-subnets). AWS asks for at least 6 free addresses in each of those subnets and recommends 16, because a version upgrade deletes those interfaces and creates new ones. A subnet that pods have filled can block an upgrade. They don't sit still between upgrades either: in the lab, the control plane went from one interface per subnet to two and back again in a single afternoon, and I never touched the cluster's own configuration;
- load balancers and VPC interface endpoints;
- Fargate, which [runs one pod per node](https://docs.aws.amazon.com/eks/latest/userguide/fargate-pod-configuration.html) and [doesn't share a network interface](https://docs.aws.amazon.com/eks/latest/userguide/fargate.html#fargate-considerations) between pods, so every Fargate pod takes an address of its own.

And AWS [reserves five addresses in every subnet](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html#subnet-sizing-ipv4): the first four and the last. A `/24` has 251 usable addresses, not 256, and a `/27` has 27, not 32.

{{< diagram name="eks-addresses" caption="Two `t3.medium` nodes with six pods each, on the default settings. Each holds 18 addresses: three for the ENIs themselves, six for pods, and nine kept free, including a whole spare ENI. A `/27` has 27 usable addresses, so the second node runs out with CPU to spare. The numbers follow the CNI's documented behaviour; the lab above shows the same squeeze with ten pods per node." >}}

## Measure before you fix

Before changing anything, find out whether you're short of addresses or just holding too many.

How many addresses each subnet has left:

```sh
aws ec2 describe-subnets \
  --query 'Subnets[].[SubnetId,AvailableIpAddressCount]' \
  --output table
```

How many the CNI holds against how many it has given to pods: `ipamd` publishes Prometheus metrics on port `61678` of every node, including `awscni_total_ip_addresses` and `awscni_assigned_ip_addresses`. If you don't run Prometheus, the [CNI metrics helper](https://github.com/aws/amazon-vpc-cni-k8s/blob/master/cmd/cni-metrics-helper/README.md) sends the same numbers to CloudWatch as `totalIPAddresses` and `assignIPAddresses`.

[VPC IP Address Manager](https://aws.amazon.com/vpc/pricing/) (IPAM) gives you a wider view. Its free tier covers a single Region and account. Across several Regions or accounts you need the Advanced Tier, which costs $0.00027 per active IP address per hour (as of October 2026).

If the CNI holds far more addresses than it has handed out, tuning (the first option below) may be all you need. If the two are close, you need more address space.

Check this before pods start failing. By the time they do, the two numbers are equal. In the lab, every node reported this at the first failure:

```text
awscni_eni_allocated 2
awscni_eni_max 3
awscni_total_ip_addresses 10
awscni_assigned_ip_addresses 10
```

The warm pool hadn't gone away. Pods had used it up, and the CNI couldn't get a new one. You could see the waste earlier, at 7 pods and 40 addresses held. Two other metrics are better for alerting: `awscni_no_available_ip_addresses`, which counts the times a pod asked for an address and the node had none (it reached 7 on the first two nodes to fill up), and `awscni_aws_api_error_count`, which counts refusals from EC2 by API call and error code.

### What the failure looks like

The scheduler doesn't know about IP addresses, so it places the pod without complaint. The pod then sits in `ContainerCreating`, and `kubectl describe pod` shows the kubelet retrying:

```text
Normal   Scheduled               default-scheduler  Successfully assigned default/pause-68d5b89fc-zqq88 to ip-10-20-0-11.ec2.internal
Warning  FailedCreatePodSandBox  kubelet            Failed to create pod sandbox: rpc error: code = Unknown desc = failed to setup network
  for sandbox "…": plugin type="aws-cni" name="aws-cni" failed (add): add cmd: failed to assign an IP address to container
```

The reason is one level down, in `ipamd`'s own log on the node, `/var/log/aws-routed-eni/ipamd.log`. First the node tries to add an ENI, and EC2 says no:

```text
Failed to allocate 5 IP addresses on an ENI: AllocENI: failed to create ENI: failed to create network interface:
operation error EC2: CreateNetworkInterface, https response error StatusCode: 400, ... api error
InsufficientFreeAddressesInSubnet: The specified subnet does not have enough free addresses to satisfy the request.
```

Then every retry of every waiting pod gets this, every 12 to 15 seconds:

```text
Failed to assign IPs from network card 0: AssignPodIPAddress: no available IP/Prefix addresses
```

`InsufficientFreeAddressesInSubnet` in this log means the subnet is full, and a bigger or extra node won't help.

## The options, cheapest first

### 1. Tune the warm pool

Instead of a whole spare ENI, tell the CNI how many spare *addresses* you want. [`WARM_IP_TARGET`](https://github.com/aws/amazon-vpc-cni-k8s/blob/master/README.md#warm_ip_target) sets the number of free addresses to keep ready, and [`MINIMUM_IP_TARGET`](https://github.com/aws/amazon-vpc-cni-k8s/blob/master/README.md#minimum_ip_target-v160) sets a floor for the total a node holds. Setting either one makes the CNI ignore `WARM_ENI_TARGET`.

Set both. With only `MINIMUM_IP_TARGET`, the node stops at that number and never asks for more. AWS's [own suggestion](https://github.com/aws/amazon-vpc-cni-k8s/blob/master/docs/eni-and-ip-target.md) for a node that runs about ten pods is `MINIMUM_IP_TARGET=12` and `WARM_IP_TARGET=2`.

The catch is more EC2 API calls, because the CNI attaches and releases addresses more often. The CNI documentation warns against it for large clusters or clusters with a lot of pod churn, because the calls can be throttled, and then no node in the cluster can get new addresses. Pods also start more slowly during a burst, because less is ready: attaching a new ENI can take up to 10 seconds.

In the lab I used `WARM_IP_TARGET=2` and `MINIMUM_IP_TARGET=5`. The CNI held 20 addresses for the two CoreDNS pods instead of 30, and the subnets started with 28 free addresses instead of 16. In the end it got me two more pods, 40 running instead of 38, which is as many as two `/27`s can take: each has 26 addresses after the control plane, the ENIs take 5 of them for themselves, and that leaves 21 for pods. Tuning used every last address, but it can't add any. The extra API calls showed up too. Once the subnets were full, the CNI kept asking EC2 for one more address and kept being refused, 350 times in about fifteen minutes, against 26 times with the default settings.

### 2. Prefix delegation

With [`ENABLE_PREFIX_DELEGATION=true`](https://docs.aws.amazon.com/eks/latest/userguide/cni-increase-ip-addresses.html), the CNI assigns a `/28` prefix (16 addresses) to each ENI slot instead of a single address. A node can run many more pods, and the CNI makes far fewer API calls: [adding a prefix to an existing ENI](https://docs.aws.amazon.com/eks/latest/best-practices/prefix-mode-linux.html#_prefer_allocating_new_prefixes_over_attaching_a_new_eni) usually takes under a second. It needs Nitro-based instances and VPC CNI 1.9.0 or later.

Each prefix has to be a free, contiguous `/28` in the subnet. A fragmented subnet can have plenty of addresses free and still not have one, and the CNI logs this:

```text
InsufficientCidrBlocks: The specified subnet does not have enough free cidr blocks to satisfy the request.
```

In the lab I switched prefix delegation on in the same two `/27` subnets, and not a single pod got an address, CoreDNS included. The console showed about 24 free addresses in each subnet. But a `/27` is only two `/28`s, and AWS reserves addresses in both halves: the first four in one, the last in the other. With the nodes' own interfaces scattered over the rest, there was never a free `/28` to give. The nodes logged `InsufficientCidrBlocks` (717 times in the CNI's error count) and, when they tried to create an ENI with a prefix, a second error worth searching your logs for:

```text
InvalidParameterValue: There aren't sufficient free Ipv4 addresses or prefixes
```

With room for prefixes, it works. With the `100.64` pod subnets from the next section added and max pods set to 60, four nodes of the same size ran 230 `pause` pods, all of them running, each node holding four `/28` prefixes (64 addresses) on a single ENI in the pod subnet.

AWS's [best practices guide](https://docs.aws.amazon.com/eks/latest/best-practices/prefix-mode-linux.html) recommends a new subnet with a [subnet CIDR reservation](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-cidr-reservation.html) for prefixes. And because it takes a whole `/28` at a time, prefix delegation can hold *more* addresses per node, not fewer: AWS puts the worst case at 15 unused addresses per node. A `WARM_IP_TARGET` below 16 stops the CNI from holding a whole spare prefix. On its own, it lets each node run more pods, but the cluster doesn't use fewer addresses.

Max pods doesn't follow on its own. With [managed node groups](https://docs.aws.amazon.com/eks/latest/userguide/choosing-instance-type.html#max-pods-precedence) on the EKS AMIs, EKS puts a cap on max pods in the node's user data: 110 for instances with fewer than 30 vCPUs, 250 above that. The documentation says this cap takes precedence over your own settings, including a `maxPodsExpression`, and that you need a custom AMI to go beyond it. Below the cap, my own value got through: I set `maxPods: 60` in a `NodeConfig` in the launch template's user data, on the standard Amazon Linux 2023 EKS AMI, and the nodes reported 60. Check what the kubelet actually got rather than what you think you configured.

```sh
kubectl get nodes -o custom-columns=NAME:.metadata.name,MAX_PODS:.status.allocatable.pods
```

On self-managed nodes, you set it yourself. Either way, AWS recommends moving to prefix delegation with new node groups rather than a rolling replacement.

### 3. More address space without more routable space

Once a VPC is part of a larger network, every routable range has to be unique, and there's rarely any to spare. The pods still need addresses from somewhere.

One way out is a secondary VPC CIDR from the shared address space, `100.64.0.0/10` (RFC 6598), which the rest of your internal network usually doesn't route. AWS [allows it as a secondary range](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html#add-cidr-block-restrictions) on a VPC in `10.0.0.0/8`, in blocks from `/16` to `/28`. Nodes and load balancers stay in the routable range, and pods move to the new one. Give the control plane time: it can take [up to an hour](https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html#network-requirements-vpc) to recognise a new CIDR, and until then `kubectl exec` and `kubectl logs` don't work for pods in it, and neither do webhooks served from it.

There are two ways to make the CNI use it.

- **Enhanced subnet discovery.** Tag the pod subnets with `kubernetes.io/role/cni=1`. On by default since VPC CNI 1.18.0, it [picks the subnet with the most free addresses](https://github.com/aws/amazon-vpc-cni-k8s/blob/master/README.md#enable_subnet_discovery-v1180) each time the CNI creates a new ENI, from the node's own subnet and the tagged subnets in the same Availability Zone. It doesn't wait for the node's subnet to run out. The node's subnet needs no tag, and pods on the node's first ENI keep using it. AWS [recommends this method](https://docs.aws.amazon.com/eks/latest/userguide/cni-subnet-selection.html) for most use cases.
- **Custom networking.** Set `AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true` and create one `ENIConfig` per Availability Zone that points at the pod subnet. With [custom networking](https://docs.aws.amazon.com/eks/latest/userguide/cni-custom-network.html), no addresses on the node's primary ENI go to pods, so max pods per node goes down, and there are more moving parts to manage. It takes precedence if both are switched on.

Pods on a non-routable range can't talk to the rest of the network directly in either direction, so their traffic goes another way:

- **Outbound** traffic to anything outside the VPC's own ranges, other private networks included, [leaves with the node's primary address](https://docs.aws.amazon.com/eks/latest/userguide/external-snat.html). That's the default (`AWS_VPC_K8S_CNI_EXTERNALSNAT=false`), and the node's address is routable. If you set it to `true`, pods keep their own address when they leave the node, and a [NAT gateway does the translation instead](https://docs.aws.amazon.com/eks/latest/userguide/external-snat.html). For pods in a non-routable range talking to other private networks, that means a private NAT gateway in a routable subnet, the pattern AWS describes for [overlapping networks](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-scenarios.html#private-nat-overlapping-networks).
- **Inbound** traffic arrives through load balancers in the routable subnets.

In the lab, I added `100.64.0.0/16` to the VPC, created a `/19` pod subnet per Availability Zone tagged `kubernetes.io/role/cni=1`, and went back to the default CNI settings. All 58 `pause` pods ran, on the same nodes and the same `/27`s that had stopped at 38. The node subnets didn't give up a single address to pods: they had 28 free before the first `pause` pod and still 28 at fifty. Even the first warm ENIs, created after five pods, went into the `100.64` subnets. That matches the README: subnet discovery doesn't wait for the node's subnet to fill up.

Pods on a node's first ENI keep addresses from the node's subnet: five per `t3.medium`, so 20 of the 60 pods in the cluster stayed in `10.20`. So if you were counting on the routable range staying empty, it won't.

To check the outbound path, I started a few pods that ask an external service which address they come from. A pod at `100.64.20.136` was seen as the public address of the NAT gateway in its Availability Zone. The CNI's SNAT rule on each node shows why. This one is from the node at `10.20.0.12`:

```text
-A AWS-SNAT-CHAIN-0 -d 100.64.0.0/16 -m comment --comment "AWS SNAT CHAIN" -j RETURN
-A AWS-SNAT-CHAIN-0 -d 10.20.0.0/24 -m comment --comment "AWS SNAT CHAIN" -j RETURN
-A AWS-SNAT-CHAIN-0 ! -o vlan+ -m comment --comment "AWS, SNAT" -m addrtype ! --dst-type LOCAL -j SNAT --to-source 10.20.0.12 --random-fully
```

Traffic to either of the VPC's ranges keeps the pod's address. Anything else leaves as the node's primary address, `10.20.0.12`, which the rest of the network can route.

{{< diagram name="eks-routable" caption="Pods live in the `100.64` range, which nothing outside the VPC routes to. Their outbound traffic leaves with the node's routable address, straight to other private networks or through the NAT gateway to the internet. Inbound traffic arrives through a load balancer in the routable range." >}}

The route tables show where the line is drawn. Inside the VPC both ranges are local, because AWS adds [a local route for every IPv4 range](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-route-tables.html#route-table-routes) associated with the VPC. Only the routable subnets get routes that lead out of it.

The node subnets, `10.20.0.0/27` and `10.20.0.32/27`, shown as they'd look in a VPC attached to a transit gateway. The lab had none, so its table had only the two local routes and the NAT gateway:

| Destination | Target | |
|---|---|---|
| `10.20.0.0/24` | `local` | |
| `100.64.0.0/16` | `local` | |
| `10.0.0.0/8` | transit gateway | other private networks: VPCs, on-premises |
| `0.0.0.0/0` | NAT gateway | the internet |

The pod subnets, `100.64.0.0/19` and `100.64.32.0/19`:

| Destination | Target |
|---|---|
| `10.20.0.0/24` | `local` |
| `100.64.0.0/16` | `local` |

The pod subnets don't need a way out, because pod traffic to anything outside the VPC doesn't leave through them. The CNI translates it to the node's address and sends it out of the node's primary network interface, in the node subnet. I checked this in the lab: with the pod subnets on a route table that has only the two local routes, pods with `100.64` addresses still reached the internet, through the NAT gateway in their Availability Zone.

The transit gateway only gets a route for `10.20.0.0/24`. Nothing outside the VPC knows how to reach `100.64.0.0/16`, which is also why every VPC can use the same `100.64` range.

### 4. IPv6

In an [IPv6 EKS cluster](https://docs.aws.amazon.com/eks/latest/userguide/cni-ipv6.html), the CNI uses prefix delegation to give pods IPv6 addresses, and pod addresses stop being a constraint. Pods can still reach IPv4 destinations: each pod also gets a host-local IPv4 address that the node translates to its own. AWS points out that this built-in NAT removes the need for DNS64 and NAT64. It needs Nitro-based instances.

You choose the IP family when you create the cluster and can't change it, so this means a new cluster and a migration. Every dependency has to cope with IPv6: images, registries, third-party endpoints, internal services and your own tooling. AWS's own advice is to evaluate your applications, EKS add-ons and the AWS services you use before you move. It makes most sense for a new cluster, where you can test those dependencies before anything runs on it.

### What I didn't choose: an overlay CNI

Cilium or Calico in overlay mode give pods addresses that don't come from the VPC at all, so the problem goes away. In return, pods are no longer native to the VPC: no security groups for pods, no flow logs at pod level, no direct reachability. The EKS control plane can't reach pods on the overlay either, so admission webhooks have to run with `hostNetwork: true`, as [Calico's EKS guide](https://docs.tigera.io/calico/latest/getting-started/kubernetes/managed-public-cloud/eks) points out. And the VPC CNI is [the only CNI that EKS supports](https://docs.aws.amazon.com/eks/latest/userguide/alternate-cni-plugins.html) on EC2 nodes: for anything else, AWS recommends commercial support or in-house expertise.

## Choosing

{{< diagram name="eks-lab-results" caption="The four lab runs side by side: the same four `t3.medium` nodes, the same two `/27` subnets. Tuning the warm pool gained two pods. Prefix delegation in subnets with no free `/28` placed none, so I stopped asking at 40. Moving pods to a `100.64` range ran all 58, the most the nodes allow." >}}

| Your situation | Start with |
|---|---|
| Holding far more addresses than pods use | Tune the warm pool |
| Nodes hit max pods before CPU or memory | Prefix delegation, on subnets with room for `/28`s |
| No more routable space available | A secondary `100.64.0.0/10` range, with enhanced subnet discovery |
| Building a new cluster and able to test dependencies | IPv6 |

## Plan for it on day one

- Ask for the secondary range when the VPC is created, not when pods are already failing.
- Size subnets for pods, not for nodes. Keep node subnets and pod subnets separate where you can.
- Leave room for the control plane: at least 16 free addresses in each subnet you give the cluster, or subnets of its own.
- Put the CNI settings in code, in the EKS add-on configuration in Terraform, not in a `kubectl set env` that someone ran once.
- Alert on subnet free addresses well before they reach zero, and on `awscni_no_available_ip_addresses` going up at all.

## The lab

Everything above that says "in the lab" comes from one afternoon in a sandbox account. The Terraform, the scripts that scale the pods and take the measurements, and the full output of my run (with account and resource IDs replaced) are in the [`eks-ipv4-lab`](https://github.com/kerim-kilic/eks-ipv4-lab/tree/v1.0) repository. Each step is one small file of settings:

| Step | File |
|---|---|
| 1. Default settings | [`terraform/steps/1-default.tfvars`](https://github.com/kerim-kilic/eks-ipv4-lab/blob/v1.0/terraform/steps/1-default.tfvars) |
| 2. Warm IP targets | [`terraform/steps/2-warm-ip.tfvars`](https://github.com/kerim-kilic/eks-ipv4-lab/blob/v1.0/terraform/steps/2-warm-ip.tfvars) |
| 3. Prefix delegation | [`terraform/steps/3-prefix.tfvars`](https://github.com/kerim-kilic/eks-ipv4-lab/blob/v1.0/terraform/steps/3-prefix.tfvars) |
| 4. Pod subnets in `100.64.0.0/16` | [`terraform/steps/4-pod-subnets.tfvars`](https://github.com/kerim-kilic/eks-ipv4-lab/blob/v1.0/terraform/steps/4-pod-subnets.tfvars) |
| 3b. Prefix delegation with the pod subnets | [`terraform/steps/3b-prefix-pod-subnets.tfvars`](https://github.com/kerim-kilic/eks-ipv4-lab/blob/v1.0/terraform/steps/3b-prefix-pod-subnets.tfvars) |

The CNI settings live in the EKS add-on configuration, in [`terraform/eks.tf`](https://github.com/kerim-kilic/eks-ipv4-lab/blob/v1.0/terraform/eks.tf), with the defaults every step starts from in [`terraform/locals.tf`](https://github.com/kerim-kilic/eks-ipv4-lab/blob/v1.0/terraform/locals.tf), and every step sets all of them, so nothing carries over from the step before. Each step also gets a new node group.

It costs money while it runs. In `us-east-1`, at [October 2026 prices](https://aws.amazon.com/eks/pricing/), it comes to about $0.37 an hour: $0.10 for the EKS control plane, $0.0416 for each `t3.medium`, and $0.045 for each of the two [NAT gateways](https://aws.amazon.com/vpc/pricing/) plus $0.005 for its public IPv4 address. My run took about two and a half hours and cost around a dollar. Set a budget alert anyway, and destroy it when you're done.

## What I'd look at next

- An IPv6 cluster in the same lab, to see how much of the "every dependency has to cope" warning shows up in practice.
- What the cluster autoscaler and Karpenter do when nodes are short of addresses rather than CPU. Adding a node into a full subnet doesn't help, and I'd like to see how each one handles it.
- [EKS Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/auto-networking.html), which uses prefix delegation by default, falls back to single addresses when a subnet is fragmented, and has no warm pool settings at all.

If you've solved this differently, or you spot a mistake, I'd like to hear about it. You can reach me on [LinkedIn](https://www.linkedin.com/in/kerim-kilic/) or by {{< email "email" >}}.
