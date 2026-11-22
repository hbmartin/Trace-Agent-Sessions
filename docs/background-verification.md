# Verification without taking over the working desktop

Use the **Background UI verification** workflow for selected native UI tests.
It runs on a GitHub-hosted Apple Silicon Mac with its own desktop. The local
Mac can remain in use; no local desktop-idle confirmation is needed for this
route. A unit-test failure in the separate CI workflow cannot skip this job.

The existing CI workflow put its UI step after unit tests in the same job.
[Run 45046415571](https://github.com/hbmartin/Trace-Agent-Sessions/actions/runs/45046415571)
failed unit tests and skipped UI execution. That is one concrete cause of
missing background verification, separate from local desktop interruptions.

## Run a selection

Once this workflow is available on the default branch:

```sh
gh workflow run background-ui-verification.yml \
  --ref YOUR_REVIEW_BRANCH \
  -f selection=docs/validation/2026-11-22-navigation-source-ownership/selected-ui-tests.json
gh run list --workflow background-ui-verification.yml --limit 5
gh run watch RUN_ID --exit-status
gh run download RUN_ID --dir /tmp/trace-verification-RUN_ID
```

The branch must contain both the workflow and the selected JSON file. The
selection is an explicit nonempty list of exact XCTest identifiers. Builds
and compiled test discovery precede serial execution, one result bundle per
case. Missing selectors, zero executed tests, skipped cases, timeout, and test
failures fail verification. There is no automatic retry that could hide a
failure. Every run records its source revision and selection hash. Logs,
discovery, per-test summaries, and XCResults are downloadable artifacts.
Infrastructure pushes run the two-case smoke selection automatically, allowing
this workflow to be tested before default-branch installation. Other branches
can use manual dispatch after installation; normal source pushes do not start
a second complete UI suite.

This is functional UI evidence. It does not establish physical-Mac performance
acceptance, external-volume permission behavior, or results on a different
macOS version. Historical PR omissions remain historical omissions; a later
hosted run is new evidence against its recorded revision.

## Local virtual desktop alternatives

A separate macOS **guest** supplies its own WindowServer, focus, input, and
permission state. Keep a display device configured and a guest user logged in;
run Xcode inside the guest over SSH. Hide the guest viewer while tests run.
Do not confuse hiding the viewer with deleting the virtual display, which UI
testing still needs.

UTM is already installed on the inspected host, and its CLI offers `start
--hide`. The host has hardware virtualization, ten logical CPUs, and 32 GiB
RAM. An initial guest allocation of four vCPUs and 8–12 GiB is a provisioning
starting point, not measured acceptance. A ready macOS/Xcode guest was not
confirmed or provisioned during this investigation; the read-only UTM guest
listing did not complete. No existing guest was started or altered.

An alternative is Tart's macOS/Xcode image with `tart run --no-graphics`:
the guest retains its graphical desktop while its host viewer is suppressed.
Pin the image/toolchain, provision a guest-only test account, keep fixtures on
the guest's own disk, and collect XCResults over SSH. Restrict guest access;
avoid inheriting published images' default credentials. This requires a large
image download and guest setup. It is an option, not an already-verified local
installation.

Apple also supports a separate logged-in account's virtual desktop through
Remote Desktop. This is an account/session setup task and requires a functional
GUI login, permissions, and an actual XCTest smoke test before treating it as
supported here. A second Space or an extra monitor within the same login is
not equivalent to an independent test session: Trace's tests explicitly
activate the app, click controls, and type through XCTest.

## Performance verification

A VM or another user session on this Mac still competes with foreground work
for CPU, memory, storage, and thermal headroom. Use a dedicated otherwise-idle
physical Mac for the repository's local performance acceptance, queueing one
native measurement job at a time. It can be controlled remotely without
interrupting the daily-use desktop. Keep baseline and candidate on that same
machine, preserve the established pairing protocol, and record its hardware,
OS, toolchain and instrumentation.

GitHub-hosted measurements can run in the background as report-only evidence.
They do not satisfy the current AGENTS.md local 10% acceptance contract. The
existing benchmark workflow already follows that distinction. Do not weaken
the threshold or label busy-host/virtual-machine timing as local acceptance.

## Sources checked November 22, 2026

- [GitHub-hosted runner isolation and public-repository availability](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [UTM CLI and guest provisioning](https://docs.getutm.app/scripting/scripting/)
- [Tart macOS/Xcode images and SSH](https://tart.run/quick-start/)
- [Tart's headless-host/keychain requirements](https://tart.run/faq/)
- [Apple's separate-account virtual desktop](https://support.apple.com/en-az/guide/remote-desktop/apd4f46319e/mac)
