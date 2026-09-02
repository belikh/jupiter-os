{
  lib,
  buildGoModule,
  # rev stamps the version from git (the arcade-webapp W4a pattern: the
  # binary identifies what is live). Empty = dev checkout.
  rev ? "",
}:

# model-router — the fleet's free-tier LLM pooling gateway: one
# OpenAI-compatible endpoint (loopback :8080 on callisto, proxied publicly
# at router.jupiter.au via the host's Cloudflare tunnel) round-robining
# every free inference tier (41 providers in the signed seed: OpenRouter
# :free pool, Groq, NVIDIA NIM, Cloudflare Workers AI, Z.ai, Ollama Cloud,
# HuggingFace router, ModelScope, SiliconFlow, Kilo, LLM7, ...), with a
# learned quota ledger + reset scheduling, per-endpoint health states
# carrying reasons (the dashboard renders why anything is down), an
# AES-256-GCM credential vault with a sign-up/key-page onboarding UI, and
# catalogue-rotation discovery with reversible tombstones.
#
# Source: github.com/belikh/model-router (private) — vendored in-tree per
# ADR-0002 D2 (no new flake input; the private repo's ssh fetcher is not
# reachable from the builders). Sync this tree from the origin repo; the
# origin's flake.lock is NOT used here.
#
# Consumers: modules/services/model-router.nix via pkgs.callPackage; the
# flake package `.#model-router` exists so the vendorHash can be
# recomputed standalone.
let
  version = if rev == "" then "0.1.0-dev" else "0.1.0-g${lib.strings.substring 0 7 rev}";
in
buildGoModule {
  pname = "model-router";
  inherit version;

  src = ./.;

  subPackages = [ "cmd/router" ];

  # Pure-Go sqlite driver (modernc.org/sqlite): the CGO-free static
  # single-binary property is load-bearing (no runtime deps).
  env.CGO_ENABLED = 0;

  # The module tree is vendored in-repo (140MB — the fleet's build hosts
  # have a pathological hang fetching proxy.golang.org over IPv6 inside
  # the build sandbox; the vendor dir sidesteps the network entirely and
  # the go-modules FOD collapses to a no-op). Sync via `go mod vendor`
  # in the origin repo when go.mod changes.
  vendorHash = null;

  ldflags = [
    "-s"
    "-w"
  ];

  meta = with lib; {
    description = "Self-hosted OpenAI-compatible router pooling free LLM inference endpoints";
    homepage = "https://github.com/belikh/model-router";
    license = licenses.mit;
    mainProgram = "router";
  };
}
