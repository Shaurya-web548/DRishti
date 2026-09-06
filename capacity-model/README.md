# District screening capacity model

Simulation of the telemedicine programme DRishti sits inside: image
acquisition rates, bandwidth, processing throughput and human review
capacity, for a district screening 100,000+ patients a year.

Two models, because they answer different questions:

| File | What it is | What it gives you |
|------|------------|-------------------|
| `drishtiCapacityDES.m` | Entity-level discrete-event simulation, base MATLAB only | Per-patient waiting times, percentiles, SLA attainment |
| `buildDRishtiSimulinkModel.m` | Simulink discrete-time flow model | Daily burst-and-drain shape, where backlog accumulates |

**All numbers below come from the discrete-event model, which was run.**
The Simulink builder was written on a machine with base MATLAB only and
has *not* been executed — verify it with `compareSimulinkToDES.m` before
trusting its output.

## Running it

```matlab
cd capacity-model
runCapacityStudy          % baseline + all sweeps, writes capacity_results.json
```

Takes about 30 seconds. `baseline_run.txt` is the captured transcript.

On a machine with Simulink:

```matlab
mdl = buildDRishtiSimulinkModel();
compareSimulinkToDES      % validates the flow model against the DES
```

## Pipeline modelled

```
patient arrival
  -> technician capture (2 eyes, recapture on quality-gate reject)
  -> edge quality gate            assessImageQuality.m
  -> uplink transfer              store-and-forward, per site
  -> central MATLAB worker pool   segmentRetina + CNN + Grad-CAM
  -> automated decision           combineGrades.m
  -> human adjudication           disagreements + QA sample
  -> ophthalmologist referral     fixed appointment slots per day
```

Queues form at the uplink, the worker pool, the grader pool and the
referral clinic. Technicians and graders only work inside their shift;
uplink and compute run around the clock.

## Headline results — 100,000 patients/year

Baseline: 8 sites, 2 compute workers, 2 grader FTE, 1 ophthalmologist FTE,
4 Mbps per site.

| Resource | Utilisation | Verdict |
|----------|-------------|---------|
| Ophthalmologist slots | **74.9%** | Binding constraint |
| Technician (session hours) | 61.3% | Comfortable |
| Grader (shift hours) | 26.9% | Over-provisioned |
| Compute worker (24 h) | 4.9% | Massively over-provisioned |
| Uplink (session hours) | 3.1% | Not a constraint |

- 96,879 patients screened, 190,180 images uploaded, **650 GB/year** total
- 0.95% of patients ungradable in both eyes after retries
- Automated result ready a **median of 0.4 minutes** after capture
- 100% of patients get a result before they leave the camp
- 29.7% of cases reach a human (22% CNN/rule disagreement + 10% QA sample)

## The three findings that matter

**1. Compute is not the bottleneck, and average utilisation hides why.**
At 11 s/image one worker sits at 9.8% of a 24-hour day — but 39.3% of
*session* hours, because every site captures inside the same six-hour
window. Session utilisation is the number that governs queueing:

| sec/image | 1 worker session util | p95 wait | same-session results |
|-----------|----------------------|----------|----------------------|
| 11 | 39.3% | 0.6 min | 100% |
| 24 | 84.9% | 7.5 min | 100% |
| 40 | 141.2% | 153 min | **22%** |
| 60 | 211.7% | 391 min | 8% |

One worker holds up to ~24 s/image; two workers to ~48 s/image. Past that
the queue no longer drains inside the session and same-session delivery
collapses. Benchmark `segmentRetina` on the actual deployment hardware
before sizing this — it is the single parameter the compute answer turns on.

**2. The ophthalmologist is what breaks first as the programme grows.**

| Patients/yr | Tech | Compute | Grader | Ophthalmologist | p95 referral wait |
|-------------|------|---------|--------|-----------------|-------------------|
| 50,000 | 31% | 2.5% | 14% | 38% | 0 d |
| 100,000 | 61% | 4.9% | 27% | **75%** | 0 d |
| 150,000 | 86% | 6.9% | 38% | **108%** | 19 d |
| 200,000 | 97% | 7.7% | 42% | **118%** | 42 d |

At 1 FTE the clinic saturates between 100k and 150k patients. Beyond that
the backlog grows without bound — at 0.5 FTE the model produces a 2,242-case
backlog and a 119-day p95 wait. Referral capacity, not AI throughput,
determines how large this programme can get.

**3. Bandwidth is a non-issue above ~0.5 Mbps.**

| Uplink | Session util | p95 upload wait |
|--------|--------------|-----------------|
| 0.25 Mbps | 49.3% | 8.2 min |
| 0.5 Mbps | 24.7% | 2.4 min |
| 4 Mbps | 3.1% | 0.1 min |

Even a quarter-megabit link delivers same-session results, because
store-and-forward lets the backlog drain after the session and the edge
quality gate means rejected images never travel. Do not spend on
connectivity here; spend it on specialist time.

## Minimum feasible configuration

Criteria: unmet demand < 2%, every resource under 85% utilisation, ≥95% of
reports inside the SLA, specialist p95 wait ≤ 14 days.

| Resource | Baseline | Minimum feasible |
|----------|----------|------------------|
| Screening sites/day | 8 | **10** |
| Compute workers | 2 | **1** |
| Grader FTE | 2 | **1** |
| Ophthalmologist FTE | 1 | **1** |

Verified as a combined configuration: 97,450 screened (1.3% unmet), all
utilisations under 76%, p95 report turnaround 0.25 h.

The baseline over-buys compute and graders and under-buys screening sites.
Eight sites leaves 2.1% of demand unseated; ten brings it to 1.3%.

## Assumptions

`drishtiParams.m` tags every parameter:

- `[CODE]` — derived from the DRishti source (per-image compute time,
  retry behaviour, disagreement rate, CLAHE path)
- `[OPS]` — deployment assumption you should replace with district numbers
- `[LIT]` — typical published value for community DR screening

The conclusions are most sensitive to `procMeanSec` (compute sizing),
`pDisagree` (grader load) and `pReferable` (specialist load). The first is
measurable on your hardware today; the second and third need programme data.

Per-image compute time of 11 s is an estimate from reading the algorithms —
24 matched-filter convolutions at 1024 px, a ~51×51 `medfilt2`, a
large-sigma `imgaussfilt`, and `bwskel` with a per-segment tortuosity loop.
It has not been measured. Treat it as the least reliable `[CODE]` value.

## Known limitations

- Weekends are not modelled; 250 consecutive working days are simulated and
  turnaround is reported in working hours.
- Patients who cannot be seated in a session are counted as unmet demand
  rather than rescheduled, so the model understates achievable throughput
  where appointment booking exists.
- The referral stage models appointment slots, not attendance — loss to
  follow-up is a large real-world effect and is out of scope here.
- The Simulink flow model is deterministic and cannot produce percentiles;
  use the DES for anything involving a service-level target.
