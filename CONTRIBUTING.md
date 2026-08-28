# Contributing

Contributions must preserve the distinction between application performance,
transport proof, and aggregate correlation evidence.

## Before submitting a change

1. Keep templates generic. Do not add account IDs, cluster ARNs, private IPs,
   concrete subnet or security-group IDs, personal email addresses, or
   credentials.
2. Pin mutable software dependencies, container images, and external scripts.
3. Put sanitized, dated measurements under `results/` and record the hardware,
   software versions, workload, and pass/fail gates.
4. Describe `gdsio` as checkpoint-like I/O unless the test uses an
   application's complete checkpoint stack.
5. Require positive `AWS Libfabric` and `GDRDMA` evidence and reject NCCL
   `NET/Socket` fallback for an EFA transport claim.
6. Require `XferType: GPUD` with cuFile compatibility fallback disabled for a GDS claim.
7. Treat EFA hardware counters as per-NIC correlation evidence, not
   per-process accounting.
8. Run the repository checks before opening a pull request.

```bash
npm ci
terraform -chdir=terraform init -backend=false -input=false
npm run check
```

## Visuals

The checked-in SVG and PNG files are publication artifacts from the validated
experiment. Update both formats together and visually inspect them.

The animated explainer is self-contained. On macOS with Google Chrome
installed, verify its controls, phase state, responsive layout, and
reduced-motion behavior with:

```bash
npm run verify:animation
```
