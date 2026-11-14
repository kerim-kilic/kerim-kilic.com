---
title: "IPv6 lab: from dual-stack to IPv6-only on AWS"
description: "A small, short-lived lab that adds IPv6 to a VPC one piece at a time, dual-stack and IPv6-only, and measures what each change does to the traffic, including which AWS traffic still goes through the NAT gateway."
stack: ["Amazon VPC", "NAT gateway", "DNS64 and NAT64", "VPC endpoints", "Terraform", "Bash", "Python", "GitHub Actions"]
weight: 3
date: 2026-12-05
draft: false
---

## Overview

A lab I built to check the claims in the article [Coming from IPv4: where to start with IPv6 on AWS]({{< relref "articles/ipv6-on-aws-where-to-start" >}}). It builds a VPC with an IPv6-only subnet and a dual-stack one, adds the pieces one at a time, and after each change records what an instance can resolve and reach, and how many bytes go through the NAT gateway. The code and the full output of my runs are in the [`aws-ipv6-lab`](https://github.com/kerim-kilic/aws-ipv6-lab) repository.

## How it's set up

- Terraform builds the VPC, a NAT gateway, an egress-only internet gateway and `t3.micro` instances running Amazon Linux 2023. Each of the eight steps is a small file of settings: an egress-only gateway, DNS64, the `64:ff9b::/96` route for NAT64, VPC endpoints and the metadata service for the IPv6-only subnet; then a security group with IPv4 rules only, DNS64 and an S3 gateway endpoint for the dual-stack one.
- The instances read their step from their own tag and run a Bash script every five minutes: DNS lookups, the order a client tries addresses in, HTTPS to IPv4-only and dual-stack sites, AWS CLI calls through the default and the dual-stack endpoints, a 20 MB S3 download and a 42 MB image pull from ECR through each name. A test bucket that only allows reads through the S3 gateway endpoint shows which way S3 requests went.
- Collection scripts save each step's network settings, the instances' reports and the NAT gateway's per-minute byte counts.
- A Python script replaces account IDs, resource IDs and addresses before anything is published, moving every global IPv6 address into the documentation range, and refuses to finish if something that looks like an account ID or a real IPv6 address is left.
- GitHub Actions checks the Terraform, the scripts, the scrubber and the workflow on every push, without AWS credentials.

## What it showed

In the IPv6-only subnet, DNS64 and NAT64 worked once all three pieces were in place, but S3 and ECR traffic on their default names still went through the NAT gateway, with an S3 gateway endpoint and ECR's interface endpoints in place. Only the dual-stack names kept it off. In the dual-stack subnet, an ordinary S3 gateway endpoint did keep that traffic off the NAT gateway. A security group with IPv4 rules only, or DNS64 switched on, didn't break anything there, but made some AWS CLI calls take 40 seconds instead of half a second. All my runs together cost well under a dollar, and everything is destroyed at the end.
