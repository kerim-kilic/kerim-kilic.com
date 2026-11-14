---
title: "Coming from IPv4: where to start with IPv6 on AWS"
date: 2026-12-05
description: "A practical first step for teams that only run IPv4: add IPv6 next to it, then go IPv6-only for new workloads. A lab shows what changes, what breaks, and why the S3 gateway endpoint that keeps S3 and ECR traffic off the NAT gateway stops working in an IPv6-only subnet."
tags: ["aws", "ipv6", "networking", "vpc", "ecr"]
image: "og/ipv6-on-aws-where-to-start.png"
draft: true
---

I built a subnet with no IPv4 range at all, gave it an S3 gateway endpoint and ECR's interface endpoints, and pulled a 42 MB image from ECR. The NAT gateway's byte counter went up by 42 MB, at $0.045 per GB, as if the endpoints weren't there. Nothing failed. The traffic just kept going the old way. In a dual-stack subnet with an ordinary S3 gateway endpoint, the same pull left the NAT gateway alone.

I was in a sandbox account, working out where a team that only runs IPv4 on AWS should start with IPv6: which piece to change first, what breaks, and what it costs. I added one piece at a time and checked what an instance could reach after each change. I ended up with two steps, both about the way out. First, add IPv6 next to the IPv4 you already have, so the subnets are dual-stack. Then, for new workloads, use subnets with no IPv4 range at all. Neither step lets anything new reach your instances. The first is easy to undo, and the second only touches new workloads.

Most of it worked the way the documentation says. The exception is the one I'd most want to know about before starting. The S3 gateway endpoint that keeps S3 and ECR traffic off the NAT gateway in a dual-stack subnet stops doing that once a subnet is IPv6-only, and the fix there is one name. This article covers both steps, what broke in the lab along the way, and that name. The code and the full output are linked at the end.

## What maps from IPv4, and what doesn't

If you know how a private subnet reaches the internet over IPv4, you know the shape of IPv6 on AWS. The pieces have different names:

| In IPv4 | In IPv6 |
|---|---|
| A VPC range you choose, such as `10.0.0.0/16` | A `/56` that Amazon gives the VPC, and a `/64` from it for each subnet in this lab |
| Private addresses, and a NAT gateway to get out | Addresses that are globally unique, and an [egress-only internet gateway](https://docs.aws.amazon.com/vpc/latest/userguide/egress-only-internet-gateway.html) to get out: outbound only, like NAT, and free |
| A route for `0.0.0.0/0` | A route for `::/0` |
| A records | AAAA records, which clients usually try first |
| Security group and network ACL rules for `0.0.0.0/0` | Separate rules for `::/0`. Neither covers the other |
| Public IPv4 addresses, charged since February 2024 | IPv6 addresses, with no charge |
| The NAT gateway reaches IPv4-only sites | DNS64 and NAT64 reach them from an IPv6-only subnet, through the same NAT gateway |

The one idea that doesn't map is that the egress-only internet gateway does no translation. An instance's IPv6 address is the one the rest of the internet sees, and the gateway only makes sure that connections start from the inside. That's the same protection your NAT gateway gives you today, without the per-GB charge.

## Step 1: add IPv6 next to IPv4

A dual-stack subnet keeps everything it has and gains an IPv6 range. In a private subnet, that means:

- an IPv6 range on the VPC, and a `/64` from it on the subnet;
- an egress-only internet gateway, and a route for `::/0` to it, next to the existing `0.0.0.0/0` route to the NAT gateway;
- IPv6 addresses for the instances: automatic for new instances once the subnet assigns them, and [assignable to running instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/working-with-ipv6-addresses.html) too;
- outbound rules for `::/0` in the security groups and network ACLs, next to the ones for `0.0.0.0/0`.

What changes is the route traffic takes. A client looks up both kinds of address, and when a name has an AAAA record, it usually tries IPv6 first. That traffic goes out through the egress-only internet gateway, for free. Names with only an A record still go out over IPv4 through the NAT gateway, exactly as before. From the dual-stack instance in the lab, with curl's report of the address it connected to:

```text
pypi.org      200 via 2001:db8:2::223
github.com    200 via 203.0.113.221
```

`pypi.org` has an AAAA record, so it went out over IPv6. `github.com` doesn't, so it went over IPv4, through the NAT gateway.

### Check your security groups first

This is the mistake I'd expect most teams to make, and I made it in the lab without trying. A security group's IPv4 and IPv6 rules are entirely separate. My first dual-stack instance had a security group that allowed `::/0` out and nothing else, so it reached everything over IPv6 and nothing over IPv4.

The usual way round is worse. Many security groups written before a VPC had IPv6 allow `0.0.0.0/0` out and nothing else. Add IPv6 to the subnet, and the instance gets an IPv6 address, finds AAAA records, tries IPv6 first, and the security group drops it. What happens next depends on the client. The lab ran a second dual-stack instance with exactly that kind of security group:

- curl gave IPv6 200 milliseconds, then tried IPv4, and every request worked, 200 ms late.
- The AWS CLI tries each address in turn and waits for the full connection timeout on each one. S3's dual-stack name returned eight IPv6 addresses before its IPv4 ones, so with a 5-second timeout, one S3 call took 40.6 seconds. With the CLI's default timeout of 60 seconds, the same call still hadn't finished when the lab stopped it after five minutes.
- Calls to the default names were as fast as ever, because those names have no AAAA record.

So in the lab, adding IPv6 didn't slow anything down by itself. The delay only appeared on the dual-stack names. In a real account, that means it shows up later, when you switch to those names, which [saves money](#the-first-saving) in step 1 and becomes necessary in step 2. Only names with no IPv4 address at all fail outright, and they're still rare. Everything else just gets slower, which is what makes it hard to spot. I'd update the security groups and network ACLs before giving instances IPv6 addresses, not after.

### Leave DNS64 off in a dual-stack subnet

DNS64, which comes up in step 2, is a setting on the subnet. In a dual-stack subnet you don't need it, because the instances have IPv4 addresses of their own, and switching it on anyway makes things worse. Every IPv4-only name gets a made-up `64:ff9b::` address, and clients try it first. Without a route for `64:ff9b::/96` to a NAT gateway, that traffic follows `::/0` to the egress-only internet gateway and goes nowhere.

It's the same slowdown as the security group trap, only now it hits the default AWS names, which is nearly everything. In the lab, curl lost its 200 ms on every IPv4-only name, AWS CLI calls to the default names took as long as they had behind the IPv4-only security group, and a 20 MB S3 download took 81 seconds instead of under one. The dual-stack names were unaffected, because they have real AAAA records.

### The first saving

Moving to dual-stack doesn't, by itself, take much traffic off the NAT gateway, because most of what an AWS workload talks to is AWS. Most of AWS's default API endpoints have no AAAA record, so a dual-stack instance still reaches S3, ECR and most other services over IPv4. With no endpoints in the lab, pulling the 42 MB test image through ECR's default registry name added 43 to 46 MB to the NAT gateway's `BytesInFromDestination`.

Two things took it off. The first is one you may already have: an S3 gateway endpoint. ECR's image layers come from S3, so it covers both. I added one of type `dualstack` to the subnet's route table, and gave a test bucket a policy that only allowed reads through it. The instance could read that bucket through S3's default name, so the traffic went through the endpoint. During each check run, the NAT gateway's busiest minute dropped to about 4 MB, the traffic of the other checks: neither the 20 MB S3 download nor the 42 MB pull went through it any more.

The second is the dual-stack names, which go out over IPv6 through the egress-only internet gateway. Even without the endpoint, pulling the image through ECR's dual-stack registry name added under 0.1 MB. More on the names [below](#which-way-aws-traffic-goes-depends-on-the-name), and on why the endpoint stops working in step 2.

## Step 2: IPv6-only subnets for new workloads

An IPv6-only subnet has no IPv4 range. It can't run out of IPv4 addresses, and nothing in it needs a public IPv4 address. It's the place to put new workloads once step 1 works, and the place where the rest of the internet's IPv4 starts to matter. Much of it still has no IPv6 address, GitHub included at the time of writing, and so do most of AWS's own default API endpoints. An instance that only speaks IPv6 needs a translator for all of those, and AWS gives you two pieces that work together.

[DNS64](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-nat64-dns64.html) is a setting on the subnet. When a name has no AAAA record, Route 53 Resolver makes one up: it writes the IPv4 address into the last 32 bits of the prefix `64:ff9b::/96`, from [RFC 6052](https://www.rfc-editor.org/rfc/rfc6052). A name with a real AAAA record gets that record, unchanged.

{{< diagram name="ipv6-dns64" caption="DNS64 at work. The name has no AAAA record, so Resolver makes one from the A record. `64:ff9b::cb00:710a` is `203.0.113.10` written in hexadecimal at the end of the prefix." >}}

NAT64 is the other half. Every NAT gateway [does it](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-nat64-dns64.html) as well as ordinary NAT: send it a packet for a `64:ff9b::` address and it takes the IPv4 address back out and sends the traffic on from its own public IPv4 address. All it needs is a route. Everything with a real IPv6 address leaves through the egress-only internet gateway, as in step 1.

{{< diagram name="ipv6-ways-out" caption="The two ways out of an IPv6-only subnet. Traffic to a real IPv6 address goes to the egress-only internet gateway, free. Traffic to a `64:ff9b::` address, which only exists because DNS64 made it up, goes to the NAT gateway, which translates it to IPv4 and charges for every GB." >}}

So on top of what step 1 needs, an IPv6-only subnet needs:

- a Nitro-based instance type, which AWS [requires](https://docs.aws.amazon.com/vpc/latest/userguide/aws-ipv6-support.html);
- DNS64 on the subnet;
- a route for `64:ff9b::/96` to a NAT gateway in a subnet that has IPv4;
- outbound rules for `64:ff9b::/96`, if your security groups or network ACLs limit outbound traffic. It's an IPv6 destination, so a rule for `0.0.0.0/0` doesn't cover it.

### Is it set up right? Read the symptom

In the lab, I added the pieces one at a time, and each half-finished state had its own symptom. They're easy to tell apart once you've seen them:

| What you see | What it means |
|---|---|
| IPv4-only names fail within milliseconds: `Failed to connect ... after 1 ms` | No DNS64. The name resolves to an IPv4 address only, and the instance has no IPv4 route. |
| Names resolve to `64:ff9b::` addresses, then connections hang until they time out | DNS64 is on, but nothing routes `64:ff9b::/96` to a NAT gateway, or a security group or network ACL blocks it. |
| Everything works, and the NAT gateway's `BytesInFromDestination` is high | Your clients use names without an AAAA record. See the next section. |

The hang is the expensive one to debug, for the same reason as the [security group trap](#check-your-security-groups-first) in step 1: the AWS CLI waits for the full connection timeout on each of S3's eight addresses. In the lab, one S3 call took 40 seconds to fail, with my 5-second timeout and retries switched off.

### An IPv6-only instance still has an IPv4 address

I didn't expect this one. It's a link-local address, `169.254.x.x`, and the instance has routes from it to the services AWS runs on link-local addresses: the DNS resolver, the time service and the [instance metadata service](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-retrieval.html). So you don't have to switch on the metadata service's IPv6 endpoint for the SDKs to find the instance's credentials: with it left off, the CLI worked with its default settings. Package updates worked too, because Amazon Linux 2023's repositories are reachable over IPv6.

## Which way AWS traffic goes depends on the name

This is the part that applies to both steps. Most AWS services have two sets of public endpoints: the default ones, under `amazonaws.com`, and [dual-stack ones](https://docs.aws.amazon.com/sdkref/latest/guide/feature-endpoints.html). In `us-east-1`, the default ones the lab used are IPv4 only:

| Service | Default name (IPv4 only) | Dual-stack name |
|---|---|---|
| STS | `sts.us-east-1.amazonaws.com` | `sts.us-east-1.api.aws` |
| Systems Manager | `ssm.us-east-1.amazonaws.com` | `ssm.us-east-1.api.aws` |
| S3 | `s3.us-east-1.amazonaws.com` | `s3.dualstack.us-east-1.amazonaws.com` |
| ECR registry | `<account>.dkr.ecr.us-east-1.amazonaws.com` | `<account>.dkr-ecr.us-east-1.on.aws` |

The SDKs, the CLI and Docker use the default names unless you tell them otherwise, and so does everything that copies them: the repository URI the ECR console shows you, and the `repository_url` that Terraform gives you for an ECR repository, are both the default name. In a dual-stack subnet, a default name goes out over IPv4: through the NAT gateway, or for S3, through a gateway endpoint if you have one. In an IPv6-only subnet with DNS64, it gets a made-up `64:ff9b::` address and goes through the NAT gateway as NAT64, and as the next section shows, the S3 gateway endpoint can't catch it there.

You can see which way a name goes from any instance. Look it up with `dig AAAA <name>` (on Amazon Linux, `dig` is in the `bind-utils` package). In an IPv6-only subnet, an answer in `64:ff9b::` means the traffic goes through the NAT gateway, and a real IPv6 address means it doesn't. The lab's checks did the same lookup; in lab step 3, they printed:

```text
s3.us-east-1.amazonaws.com                   AAAA  64:ff9b::198.51.100.19 ...
s3.dualstack.us-east-1.amazonaws.com         AAAA  2001:db8:8:1::100f:e5b7 ...
<account>.dkr.ecr.us-east-1.amazonaws.com    AAAA  64:ff9b::203.0.113.117
<account>.dkr-ecr.us-east-1.on.aws           AAAA  2001:db8:13:2:ca2f:527d:4816:ad61
```

In a dual-stack subnet, no AAAA answer at all means IPv4: the NAT gateway, unless an endpoint catches it. Check the names your clients actually use: the endpoints your SDKs call and the registry in your image references.

### S3: the gateway endpoint stops working in an IPv6-only subnet

The usual advice for S3 traffic from private subnets is an S3 gateway endpoint: it's free, and it keeps S3 traffic off the NAT gateway. In the dual-stack subnet, it did exactly that, [default name included](#the-first-saving). AWS also supports [gateway endpoints of IP address type `ipv6`](https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html), and the lab used one in the IPv6-only subnet.

A gateway endpoint doesn't change what a name resolves to. It adds a route for S3's prefix list to the route table, and for type `ipv6` that's S3's real IPv6 addresses. The default name has no AAAA record, so DNS64 makes one up, the instance sends the traffic to a `64:ff9b::` address, and that matches the route to the NAT gateway, not the route to the endpoint.

To prove which way requests went, I gave a test bucket a policy that refused the lab instance's reads unless they came through the gateway endpoint, with the `aws:SourceVpce` condition. Through the dual-stack name, the read worked. Through the default name:

```text
An error occurred (AccessDenied) when calling the GetObject operation: ... with an explicit deny in a resource-based policy
```

The NAT gateway agreed. Each 20 MB download through the default name added about 21 MB to its `BytesInFromDestination`, before the gateway endpoint existed and after. The same download through the dual-stack name added nothing.

In the lab, the fix was the dual-stack name. For the SDKs and the CLI that's one setting, `AWS_USE_DUALSTACK_ENDPOINT=true` or `use_dualstack_endpoint = true` in the config file. It applies to every service the client calls, and a request [fails rather than falls back](https://docs.aws.amazon.com/sdkref/latest/guide/feature-endpoints.html) if a service has no dual-stack endpoint in your Region. I tried it with Data Pipeline in `us-east-1`: the CLI sent the call to `datapipeline.us-east-1.api.aws`, a name that doesn't exist, and stopped with `Could not connect to the endpoint URL`. It didn't try the default name. So check the services you use first.

### ECR: the registry name decides where the layers come from

This one moved the most bytes in the lab, and it's the one I'd check first in a real account, because image pulls are often the biggest thing a workload downloads.

When Docker or containerd pulls an image from ECR, the registry doesn't send the layers itself. It answers each layer request with a redirect to S3, and where it points depends on the name you pulled from:

| Pulled from | Layers come from |
|---|---|
| `<account>.dkr.ecr.us-east-1.amazonaws.com` | `prod-us-east-1-starport-layer-bucket.s3.us-east-1.amazonaws.com` |
| `<account>.dkr-ecr.us-east-1.on.aws` | `prod-us-east-1-starport-layer-bucket.s3.dualstack.us-east-1.amazonaws.com` |

So the default registry name sends the client to S3's default name, and the layers come through the NAT gateway. From the IPv6-only subnet, pulling the 42 MB test image that way added 42.4 MB to the NAT gateway's counter, and pulling it through the dual-stack registry name added nothing.

ECR's interface endpoints didn't change that. ECR supports them over IPv6, and with private DNS on, both registry names resolved to the endpoint inside the VPC. But the endpoint only carries the registry's API calls. The redirect still pointed at S3's default name, and the next pull added another 42.4 MB. That's the same reason AWS tells you to [add an S3 gateway endpoint alongside ECR's endpoints](https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html), except that in an IPv6-only subnet the S3 gateway endpoint doesn't catch the default name either.

The fix I used was the dual-stack registry name in the image reference, `<account>.dkr-ecr.<region>.on.aws/<repository>:<tag>`. The lab's instances used the same login for both names.

### Interface endpoints do work, for the services that use them

For STS and Systems Manager, interface endpoints did what you'd hope. In an IPv6-only subnet the endpoints have to be of [IP address type `ipv6`](https://docs.aws.amazon.com/vpc/latest/privatelink/create-interface-endpoint.html), and with private DNS on, the default names answer with the endpoint's IPv6 address and no A record at all, so DNS64 has nothing to make up:

```text
sts.us-east-1.amazonaws.com   A     - (Name or service not known)
sts.us-east-1.amazonaws.com   AAAA  2001:db8:1:10:82b6:a557:cacf:84f2
```

Interface endpoints [cost](https://aws.amazon.com/privatelink/pricing/) $0.01 an hour per Availability Zone and $0.01 per GB, so they make sense for services you call a lot and can't move to dual-stack names. Not every endpoint supports IPv6, and the EC2 API is the place to check, not the documentation:

```sh
aws ec2 describe-vpc-endpoint-services \
  --service-names com.amazonaws.us-east-1.s3 \
                  com.amazonaws.us-east-1.ecr.dkr \
                  com.amazonaws.us-east-1.ec2messages \
  --query 'ServiceDetails[].[ServiceName,
                             ServiceType[0].ServiceType,
                             SupportedIpAddressTypes]'
```

In `us-east-1`, in November 2026, STS, Systems Manager, `ssmmessages`, both ECR endpoints and S3 (gateway and interface) supported IPv6. `ec2messages`, one of the endpoints the Systems Manager agent uses, didn't. And AWS's own [IPv6 support table](https://docs.aws.amazon.com/vpc/latest/userguide/aws-ipv6-support.html) said S3's private endpoints don't support IPv6, which the API and the lab both contradict.

{{< diagram name="ipv6-lab-results" caption="The lab's results for the IPv6-only subnet, lab step by lab step. Amber is through NAT64: it works, and you pay per GB. In lab step 4, the interface endpoints take over both the default and the dual-stack STS and Systems Manager names, but S3's default name and image layers pulled through ECR's default registry name still go through NAT64. Only the dual-stack names stay off the NAT gateway in every step." >}}

## What it costs

In `us-east-1`, at November 2026 prices:

| Route | Per GB | Fixed |
|---|---|---|
| Default names, through the NAT gateway (IPv4 or NAT64) | $0.045 NAT gateway processing | $0.045 an hour per NAT gateway, plus $0.005 for its public IPv4 address |
| Dual-stack names through the egress-only internet gateway, and anything an S3 gateway endpoint catches | nothing | nothing |
| Interface endpoints | $0.01 | $0.01 an hour per endpoint per Availability Zone |

Take a workload that pulls 500 GB of images from ECR and downloads 1 TB from S3 a month. On default names with no endpoints, that's 1.5 TB through the NAT gateway, about $68 a month in processing alone. In a dual-stack subnet, an S3 gateway endpoint takes that to nothing. In an IPv6-only subnet it doesn't, and only the dual-stack names do. You still want the NAT gateway for the IPv4-only internet; you just don't want AWS's own traffic in it.

## A checklist

**Step 1, dual-stack:**

- An IPv6 range on the VPC and a `/64` on each subnet.
- An egress-only internet gateway and a route for `::/0` to it, next to the IPv4 route to the NAT gateway.
- Outbound rules for `::/0` in the security groups and network ACLs, added before the instances get IPv6 addresses.
- DNS64 off.
- An S3 gateway endpoint on the route tables, if you don't have one yet: it keeps S3 traffic and ECR's image layers off the NAT gateway, even on the default names.
- `AWS_USE_DUALSTACK_ENDPOINT=true` for the SDKs and the CLI, once you've checked that every service you call has a dual-stack endpoint in your Region.
- Image references that use `<account>.dkr-ecr.<region>.on.aws`, not the default registry name.

**Step 2, IPv6-only, everything from step 1 plus:**

- A Nitro-based instance type.
- DNS64 on the subnet, and a route for `64:ff9b::/96` to a NAT gateway in a subnet with IPv4.
- Security groups and network ACLs that allow `64:ff9b::/96` outbound, if they limit outbound traffic at all.
- An S3 gateway endpoint of type `ipv6` on its route table. It only catches the dual-stack S3 name, so in this step the dual-stack names stop being optional.
- Interface endpoints of type `ipv6` for services you call a lot on their default names.

**Both:** an alarm on the NAT gateway's `BytesInFromDestination`. Once your own traffic uses the dual-stack names, what's left there is the IPv4-only internet, and what it costs.

## The lab

Everything above that says "in the lab" comes from runs in a sandbox account. The Terraform, the check script that runs on the instances, and the full output (with account IDs, resource IDs and addresses replaced) are in the [`aws-ipv6-lab`](https://github.com/kerim-kilic/aws-ipv6-lab/tree/v1.0) repository. Each step is one small file of settings:

| Step | File |
|---|---|
| 1. Egress-only internet gateway | [`terraform/steps/1-eigw-only.tfvars`](https://github.com/kerim-kilic/aws-ipv6-lab/blob/v1.0/terraform/steps/1-eigw-only.tfvars) |
| 2. DNS64, no route | [`terraform/steps/2-dns64.tfvars`](https://github.com/kerim-kilic/aws-ipv6-lab/blob/v1.0/terraform/steps/2-dns64.tfvars) |
| 3. The route to the NAT gateway, and a dual-stack control instance | [`terraform/steps/3-nat64.tfvars`](https://github.com/kerim-kilic/aws-ipv6-lab/blob/v1.0/terraform/steps/3-nat64.tfvars) |
| 4. VPC endpoints for S3, STS, Systems Manager and ECR | [`terraform/steps/4-endpoints.tfvars`](https://github.com/kerim-kilic/aws-ipv6-lab/blob/v1.0/terraform/steps/4-endpoints.tfvars) |
| 5. Metadata over IPv4 only | [`terraform/steps/5-imds.tfvars`](https://github.com/kerim-kilic/aws-ipv6-lab/blob/v1.0/terraform/steps/5-imds.tfvars) |
| 6. A dual-stack subnet on its own, and a security group with IPv4 rules only | [`terraform/steps/6-dual-stack.tfvars`](https://github.com/kerim-kilic/aws-ipv6-lab/blob/v1.0/terraform/steps/6-dual-stack.tfvars) |
| 7. DNS64 on the dual-stack subnet | [`terraform/steps/7-dual-stack-dns64.tfvars`](https://github.com/kerim-kilic/aws-ipv6-lab/blob/v1.0/terraform/steps/7-dual-stack-dns64.tfvars) |
| 8. An S3 gateway endpoint on the dual-stack subnet | [`terraform/steps/8-dual-stack-s3-endpoint.tfvars`](https://github.com/kerim-kilic/aws-ipv6-lab/blob/v1.0/terraform/steps/8-dual-stack-s3-endpoint.tfvars) |

The lab's steps don't follow the article's order. Lab steps 1 to 5 build the IPv6-only subnet, step 2 of this article; lab steps 6 to 8 test the dual-stack subnet, step 1. The instances run their checks every five minutes and read their step from their own tag, so moving to the next step changes the network, not the instances. The test downloads are spaced more than a minute apart, so the NAT gateway's per-minute metrics show each one on its own.

It costs money while it runs: in `us-east-1`, about $0.06 an hour for the NAT gateway, its public IPv4 address and a `t3.micro`, plus $0.04 an hour for step 4's four interface endpoints, another `t3.micro` in lab steps 6 to 8, and a few cents of NAT processing for the test downloads. All my runs together, lab steps 1 to 8, cost well under a dollar. Set a budget alert anyway, and destroy it when you're done.

## What I'd look at next

- The other direction, getting in: a dual-stack Application Load Balancer in front of instances in IPv6-only subnets, and how many public IPv4 addresses that really saves.
- An IPv6 EKS cluster, the follow-up to [the IPv4 exhaustion article]({{< relref "articles/eks-ipv4-exhaustion" >}}), where image pulls from ECR are exactly the traffic this article is about.

If you've started differently, or you spot a mistake, I'd like to hear about it. You can reach me on [LinkedIn](https://www.linkedin.com/in/kerim-kilic/) or by {{< email "email" >}}.
