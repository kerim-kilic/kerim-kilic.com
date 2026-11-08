---
title: "IPv6-only on AWS: why S3 and ECR still go through the NAT gateway"
date: 2026-12-05
description: "In an IPv6-only subnet, S3 downloads and ECR image pulls go through NAT64 by default, VPC endpoints or not. A lab shows why, what it costs, and how the dual-stack names fix it."
tags: ["aws", "ipv6", "networking", "vpc", "ecr"]
image: "og/ipv6-only-subnets-nat-costs.png"
draft: true
---

I put an EC2 instance in a subnet with no IPv4 range at all. I gave it the usual way out to the IPv4 internet, DNS64 and NAT64, and added an S3 gateway endpoint and ECR interface endpoints so AWS traffic would stay off the NAT gateway. Then I pulled a 42 MB image from ECR and downloaded a 20 MB file from S3, and watched the NAT gateway's byte counter. It went up by 42 MB and then by 21 MB. Every byte went through the NAT gateway, at $0.045 per GB, endpoints or not.

The fix turned out to be a name: the dual-stack one. Through the dual-stack names, the same pull and the same download added 0 bytes to the NAT gateway. This article is about why that happens, how to see it in your own subnets, and what else an IPv6-only instance does that I didn't expect. I ran everything in a small lab in a sandbox account; the code and the full output are linked at the end.

## How an IPv6-only instance reaches IPv4 at all

An IPv6-only subnet has no IPv4 range, so it can't run out of IPv4 addresses, and nothing in it needs a public IPv4 address, which AWS has charged for since 2024. But much of the internet still has no IPv6 address, GitHub included at the time of writing, and so do most of AWS's own default API endpoints. An instance that only speaks IPv6 needs a translator for all of those, and AWS gives you two pieces that work together.

[DNS64](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-nat64-dns64.html) is a setting on the subnet. When a name has no AAAA record, Route 53 Resolver makes one up: it writes the IPv4 address into the last 32 bits of the prefix `64:ff9b::/96`, from [RFC 6052](https://www.rfc-editor.org/rfc/rfc6052). A name with a real AAAA record gets that record, unchanged.

{{< diagram name="ipv6-dns64" caption="DNS64 at work. The name has no AAAA record, so Resolver makes one from the A record. `64:ff9b::cb00:710a` is `203.0.113.10` written in hexadecimal at the end of the prefix." >}}

NAT64 is the other half. Every NAT gateway [does it](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-nat64-dns64.html) as well as ordinary NAT: send it a packet for a `64:ff9b::` address and it takes the IPv4 address back out and sends the traffic on from its own public IPv4 address. All it needs is a route. Everything with a real IPv6 address leaves through an [egress-only internet gateway](https://docs.aws.amazon.com/vpc/latest/userguide/egress-only-internet-gateway.html) instead, which has no hourly charge and no per-GB processing charge.

{{< diagram name="ipv6-ways-out" caption="The two ways out of an IPv6-only subnet. Traffic to a real IPv6 address goes to the egress-only internet gateway, free. Traffic to a `64:ff9b::` address, which only exists because DNS64 made it up, goes to the NAT gateway, which translates it to IPv4 and charges for every GB." >}}

That's the whole mechanism, and it's also the whole problem. Whether a byte goes through the NAT gateway depends on one thing only: whether the name your client looked up has a real AAAA record.

## Is it set up right? Read the symptom

The lab added the pieces one at a time and checked, after each one, what the instance could reach. Each half-finished state has its own symptom, and they're easy to tell apart once you've seen them:

| What you see | What it means |
|---|---|
| IPv4-only names fail within milliseconds: `Failed to connect ... after 1 ms` | No DNS64. The name resolves to an IPv4 address only, and the instance has no IPv4 route. |
| Names resolve to `64:ff9b::` addresses, then connections hang until they time out | DNS64 is on, but nothing routes `64:ff9b::/96` to a NAT gateway, or a security group or network ACL blocks it. |
| Everything works, and the NAT gateway's `BytesInFromDestination` is high | Your clients use names without an AAAA record. The rest of this article. |

The hang is the expensive one to debug, because tools wait a long time before they give up. In the lab, the AWS CLI took 40 seconds to fail one S3 call: S3's default name returns eight addresses, and the CLI tried each in turn, 5 seconds each, and that was with my 5-second timeout and retries switched off. The CLI's own default connection timeout is 60 seconds.

If your security groups limit outbound traffic, remember that `64:ff9b::/96` is an IPv6 destination: an outbound rule for `0.0.0.0/0` doesn't cover it. IPv4 and IPv6 rules are entirely separate, which I managed to prove to myself in the lab. My control instance, the only one with an IPv4 address, reached everything over IPv6 and nothing over IPv4, because its security group allowed `::/0` out and nothing else.

## Why AWS traffic goes through the NAT gateway

Most AWS services have two sets of public endpoints: the default ones, under `amazonaws.com`, and [dual-stack ones](https://docs.aws.amazon.com/sdkref/latest/guide/feature-endpoints.html). In `us-east-1`, the default ones the lab used are IPv4 only:

| Service | Default name (IPv4 only) | Dual-stack name |
|---|---|---|
| STS | `sts.us-east-1.amazonaws.com` | `sts.us-east-1.api.aws` |
| Systems Manager | `ssm.us-east-1.amazonaws.com` | `ssm.us-east-1.api.aws` |
| S3 | `s3.us-east-1.amazonaws.com` | `s3.dualstack.us-east-1.amazonaws.com` |
| ECR registry | `<account>.dkr.ecr.us-east-1.amazonaws.com` | `<account>.dkr-ecr.us-east-1.on.aws` |

The SDKs, the CLI and Docker use the default names unless you tell them otherwise, and so does everything that copies them: the repository URI the ECR console shows you, and the `repository_url` that Terraform gives you for an ECR repository, are both the default name. In an IPv6-only subnet with DNS64, every default name gets a made-up `64:ff9b::` address, and every byte to it goes through the NAT gateway.

You can see which way a name goes from any instance in the subnet. Look it up with `dig AAAA <name>` (on Amazon Linux, `dig` is in the `bind-utils` package): an answer in `64:ff9b::` means the traffic goes through the NAT gateway, and a real IPv6 address means it doesn't. In step 3 of the lab, before any endpoints:

```text
s3.us-east-1.amazonaws.com                   AAAA  64:ff9b::198.51.100.19 ...
s3.dualstack.us-east-1.amazonaws.com         AAAA  2001:db8:8:1::100f:e5b7 ...
<account>.dkr.ecr.us-east-1.amazonaws.com    AAAA  64:ff9b::203.0.113.117
<account>.dkr-ecr.us-east-1.on.aws           AAAA  2001:db8:13:2:ca2f:527d:4816:ad61
```

Check the names your clients actually use: the endpoints your SDKs call and the registry in your image references.

### S3: the gateway endpoint you added isn't used

The usual advice for S3 traffic from private subnets is an S3 gateway endpoint: it's free, and it keeps S3 traffic off the NAT gateway. In an IPv6-only subnet it can be IPv6 too: AWS supports [gateway endpoints of IP address type `ipv6`](https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html), and the lab used one.

A gateway endpoint doesn't change what a name resolves to. It adds a route for S3's prefix list to the route table, and for type `ipv6` that's S3's real IPv6 addresses. The default name `s3.us-east-1.amazonaws.com` has no AAAA record, so DNS64 makes one up, the instance sends the traffic to a `64:ff9b::` address, and that matches the route to the NAT gateway, not the route to the endpoint.

To prove which way requests went, I gave a test bucket a policy that refused the lab instance's reads unless they came through the gateway endpoint, with the `aws:SourceVpce` condition. Through the dual-stack name, the read worked. Through the default name:

```text
An error occurred (AccessDenied) when calling the GetObject operation: ... with an explicit deny in a resource-based policy
```

The NAT gateway agreed. Each 20 MB download through the default name added about 21 MB to its `BytesInFromDestination`, before the gateway endpoint existed and after. The same download through the dual-stack name added nothing.

The fix is to make clients use the dual-stack name. For the SDKs and the CLI that's one setting, `AWS_USE_DUALSTACK_ENDPOINT=true` or `use_dualstack_endpoint = true` in the config file. It applies to every service the client calls, and a request [fails rather than falls back](https://docs.aws.amazon.com/sdkref/latest/guide/feature-endpoints.html) if a service has no dual-stack endpoint in your Region, so check the services you use first. With the setting on, S3 traffic goes to S3's real IPv6 addresses, and the gateway endpoint, if there is one, carries it.

### ECR: the registry name decides where the layers come from

This one moved the most bytes in the lab, and it's the one I'd check first in a real account, because image pulls are often the biggest thing a workload downloads.

When Docker or containerd pulls an image from ECR, the registry doesn't send the layers itself. It answers each layer request with a redirect to S3. The lab looked at where that redirect pointed, and the answer depends on the name you pulled from:

| Pulled from | Layers come from |
|---|---|
| `<account>.dkr.ecr.us-east-1.amazonaws.com` | `prod-us-east-1-starport-layer-bucket.s3.us-east-1.amazonaws.com` |
| `<account>.dkr-ecr.us-east-1.on.aws` | `prod-us-east-1-starport-layer-bucket.s3.dualstack.us-east-1.amazonaws.com` |

So the default registry name sends the client to S3's default name, which has no AAAA record, and the layers come through NAT64. Pulling the 42 MB test image that way added 42.4 MB to the NAT gateway's counter. Pulling it through the dual-stack registry name added nothing: the registry and the layers were both reached over IPv6.

The ECR interface endpoints didn't change that. ECR supports them over IPv6, and with private DNS on, both registry names resolved to the endpoint inside the VPC. But the endpoint only carries the registry's API calls. The redirect still pointed at S3's default name for a pull through the default registry name, and the next pull added another 42.4 MB to the NAT gateway. That's the same reason AWS tells you to [add an S3 gateway endpoint alongside ECR's endpoints](https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html), except that in an IPv6-only subnet the S3 gateway endpoint doesn't catch the default name either.

The fix is the dual-stack registry name in your image references, `<account>.dkr-ecr.<region>.on.aws/<repository>:<tag>`. The same login works for both names. The dual-stack pull worked from the first step of the lab, with nothing but the egress-only internet gateway: no DNS64, and no route to the NAT gateway.

### Interface endpoints do work, for the services that use them

For STS and Systems Manager, interface endpoints did what you'd hope. The endpoints have to be of [IP address type `ipv6`](https://docs.aws.amazon.com/vpc/latest/privatelink/create-interface-endpoint.html) to live in an IPv6-only subnet, and with private DNS on, the default names answer with the endpoint's IPv6 address and no A record at all, so DNS64 has nothing to make up:

```text
sts.us-east-1.amazonaws.com   A     - (Name or service not known)
sts.us-east-1.amazonaws.com   AAAA  2001:db8:1:10:82b6:a557:cacf:84f2
```

The CLI's default settings then reached both services through the endpoints, over IPv6. Interface endpoints [cost](https://aws.amazon.com/privatelink/pricing/) $0.01 an hour per Availability Zone and $0.01 per GB, so they make sense for services you call a lot and can't move to dual-stack names.

Not every endpoint supports IPv6, and AWS's documentation isn't the place to check. The EC2 API is:

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

{{< diagram name="ipv6-lab-results" caption="The lab's results, step by step. Amber is through NAT64: it works, and you pay per GB. In step 4, the interface endpoints take over both the default and the dual-stack STS and Systems Manager names, but S3's default name and image layers pulled through ECR's default registry name still go through NAT64. Only the dual-stack names stay off the NAT gateway in every step." >}}

## What it costs

In `us-east-1`, at November 2026 prices:

| Route | Per GB | Fixed |
|---|---|---|
| Default names, through NAT64 | $0.045 NAT gateway processing | $0.045 an hour per NAT gateway, plus $0.005 for its public IPv4 address |
| Dual-stack names, through the egress-only internet gateway or the S3 gateway endpoint | nothing | nothing |
| Interface endpoints | $0.01 | $0.01 an hour per endpoint per Availability Zone |

Take a workload that pulls 500 GB of images from ECR and downloads 1 TB from S3 a month, from IPv6-only subnets. On default names, that's 1.5 TB through NAT64, about $68 a month in processing alone. On dual-stack names, it's nothing. You still want the NAT gateway for the IPv4-only internet; you just don't want AWS's own traffic in it.

## An IPv6-only instance has an IPv4 address

I didn't expect this one. It's a link-local address, from the instance itself:

```text
ens5   UP   169.254.164.83/32 metric 512 2001:db8:20:10:9635:6d55:6dcd:dc6a/128 fe80::10ff:d7ff:fe71:494d/64
```

and the instance has routes from it to the services AWS runs on link-local addresses: the DNS resolver at `169.254.169.253`, the [instance metadata service](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-retrieval.html) at `169.254.169.254` and the time service at `169.254.169.123`. I expected to have to switch on the metadata service's IPv6 endpoint, which is off by default, for the SDK to find the instance's credentials. I didn't. On an instance with the IPv6 endpoint left off, the metadata service answered on `169.254.169.254` and the CLI worked with its default settings. The only calls that failed were the ones I'd told to use the IPv6 endpoint (`AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE=IPv6`). Package updates worked too: Amazon Linux 2023's repositories are reachable over IPv6.

## A checklist for an IPv6-only subnet

- A Nitro-based instance type: AWS [requires one](https://docs.aws.amazon.com/vpc/latest/userguide/aws-ipv6-support.html) in an IPv6-only subnet.
- A route for `::/0` to an egress-only internet gateway, DNS64 on the subnet, and a route for `64:ff9b::/96` to a NAT gateway in a subnet with IPv4.
- Security groups and network ACLs that allow `64:ff9b::/96` outbound, if they limit outbound traffic at all.
- `AWS_USE_DUALSTACK_ENDPOINT=true` for the SDKs and the CLI, once you've checked that every service you call has a dual-stack endpoint in your Region.
- Image references that use `<account>.dkr-ecr.<region>.on.aws`, not the default registry name.
- An S3 gateway endpoint of type `ipv6`, for the S3 traffic that uses the dual-stack name.
- Interface endpoints of type `ipv6` for services you call a lot on their default names.
- An alarm on the NAT gateway's `BytesInFromDestination`. In an IPv6-only subnet, that's your IPv4-only traffic and what it costs.

## The lab

Everything above that says "in the lab" comes from three runs on one day in a sandbox account. The Terraform, the check script that runs on the instances, and the full output (with account IDs, resource IDs and addresses replaced) are in the [`aws-ipv6-lab`](https://github.com/kerim-kilic/aws-ipv6-lab/tree/v1.0) repository. Each step is one small file of settings:

| Step | File |
|---|---|
| 1. Egress-only internet gateway | [`terraform/steps/1-eigw-only.tfvars`](https://github.com/kerim-kilic/aws-ipv6-lab/blob/v1.0/terraform/steps/1-eigw-only.tfvars) |
| 2. DNS64, no route | [`terraform/steps/2-dns64.tfvars`](https://github.com/kerim-kilic/aws-ipv6-lab/blob/v1.0/terraform/steps/2-dns64.tfvars) |
| 3. The route to the NAT gateway, and a dual-stack control instance | [`terraform/steps/3-nat64.tfvars`](https://github.com/kerim-kilic/aws-ipv6-lab/blob/v1.0/terraform/steps/3-nat64.tfvars) |
| 4. VPC endpoints for S3, STS, Systems Manager and ECR | [`terraform/steps/4-endpoints.tfvars`](https://github.com/kerim-kilic/aws-ipv6-lab/blob/v1.0/terraform/steps/4-endpoints.tfvars) |
| 5. Metadata over IPv4 only | [`terraform/steps/5-imds.tfvars`](https://github.com/kerim-kilic/aws-ipv6-lab/blob/v1.0/terraform/steps/5-imds.tfvars) |

The instances run their checks every five minutes and read their step from their own tag, so moving to the next step changes the network, not the instances. The test downloads are spaced more than a minute apart, so the NAT gateway's per-minute metrics show each one on its own.

It costs money while it runs: in `us-east-1`, about $0.06 an hour for the NAT gateway, its public IPv4 address and a `t3.micro`, plus $0.04 an hour for step 4's four interface endpoints and a few cents of NAT processing for the test downloads. All three of my runs together cost well under a dollar. Set a budget alert anyway, and destroy it when you're done.

## What I'd look at next

- The other direction, getting in: an Application Load Balancer in front of instances in IPv6-only subnets, and how many public IPv4 addresses that really saves.
- An IPv6 EKS cluster, the follow-up to [the IPv4 exhaustion article]({{< relref "articles/eks-ipv4-exhaustion" >}}), where image pulls from ECR are exactly the traffic this article is about.

If you've solved this differently, or you spot a mistake, I'd like to hear about it. You can reach me on [LinkedIn](https://www.linkedin.com/in/kerim-kilic/) or by {{< email "email" >}}.
