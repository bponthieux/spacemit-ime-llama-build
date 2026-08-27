# Scope

This repo has one job: **produce IME-enabled RISC-V llama.cpp builds for SpacemiT K3
hardware.** Please keep contributions inside that boundary.

## In scope

- The cross-build itself: Dockerfile, toolchain setup, CMake configuration
- Source patches required to make upstream llama.cpp work on this hardware
- Hardware, toolchain, and ISA reference material needed to interpret results
- Benchmark numbers that characterize what the build achieves

## Out of scope

- Host names, IP addresses, usernames, SSH details, network topology
- Anything specific to one person's lab, homelab, or private infrastructure
- Project planning, architecture decisions, or needs evaluation for a
  particular deployment

Target-host configuration belongs in `spacemit-ime-build/.env`, which is
git-ignored and must never be committed. Copy `.env.example` to `.env` and fill
in your own values.

## The test

Before adding something, ask: **would this be useful to a stranger who does not
own the machine you are testing on?**

If not, it belongs in a private repo. This project deliberately stays narrow so
that people looking for working RISC-V builds find exactly that and nothing else.
