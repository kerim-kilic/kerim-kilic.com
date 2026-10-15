---
title: "EKS IPv4 lab: running a cluster out of addresses"
description: "A small, short-lived EKS lab that runs out of IPv4 on purpose, then measures the fixes: warm pool tuning, prefix delegation and a 100.64 range for pods."
stack: ["Amazon EKS", "Amazon VPC CNI", "Terraform", "Bash", "Python", "GitHub Actions"]
weight: 2
draft: true
---

## Overview

A lab I built to check the numbers in the article [Your EKS cluster has CPU to spare and no IP addresses left]({{< relref "articles/eks-ipv4-exhaustion" >}}). It builds an EKS cluster in a VPC that's deliberately too small, fills the nodes with `pause` pods until addresses run out, and then tries the fixes one at a time. The code and the full output of my run are in the [`eks-ipv4-lab`](https://github.com/kerim-kilic/eks-ipv4-lab) repository.

## How it's set up

- Terraform builds the VPC, the cluster and a managed node group of four `t3.medium` nodes in two `/27` subnets. Each step is a small file of settings, and each step gets a new node group, so nothing carries over.
- The VPC CNI, CoreDNS and kube-proxy are EKS add-ons, and every CNI setting is in Terraform rather than in a `kubectl set env`.
- A Bash script scales the pods up in rounds and records, after each one, the free addresses in each subnet and what the CNI holds against what it hands out. At the first failure and at the end it saves the events, the CNI's metrics and logs, and the ENIs and route tables.
- A Python script replaces account IDs, resource IDs and public addresses before anything is published, and refuses to finish if something that looks like an account ID is left.
- GitHub Actions checks the Terraform, the scripts and the workflow on every push, without AWS credentials.

## What it showed

With the default settings the cluster stopped at 38 pods, with the nodes allowed 58. Tuning the warm pool gained two. Prefix delegation in the same small subnets placed none at all, and moving pods to a `100.64.0.0/16` range ran all 58. A run costs about a dollar, and everything is destroyed at the end.
