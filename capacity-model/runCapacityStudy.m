%RUNCAPACITYSTUDY  Baseline run + resource sweeps for the district model.
%
%   Prints a report to stdout and writes capacity_results.json.
%   Base MATLAB only.

clear; clc;
p = drishtiParams();

fprintf('==========================================================\n');
fprintf(' DRishti district capacity model\n');
fprintf(' %d patients/yr, %d sites, %d worker(s), %.1f grader FTE\n', ...
        p.annualPatients, p.sites, p.workers, p.graderFTE);
fprintf('==========================================================\n\n');

t0 = tic;
base = drishtiCapacityDES(p);
fprintf('(simulated %d patients in %.1f s of wall clock)\n\n', ...
        base.demand.patientsPresented, toc(t0));

printRun(base);

%% ----------------------------------------------------- bottleneck ranking
fprintf('\n---------------- RESOURCE UTILISATION (ranked) -----------\n');
names = {'Technician (session hours)', 'Uplink (session hours)', ...
         'Compute worker (24h)', 'Grader (shift hours)', 'Ophthalmologist (slots)'};
utils = [base.technician.utilPct, base.bandwidth.sessionLinkUtilPct, ...
         base.compute.utilPct, base.review.utilPct, base.referral.utilPct];
[su, si] = sort(utils, 'descend');
for k = 1:numel(su)
    bar = repmat('#', 1, max(0, round(su(k) / 2)));
    fprintf('  %-28s %6.1f%%  %s\n', names{si(k)}, su(k), bar);
end

%% ------------------------------------------------------------- sweeps
fprintf('\n---------------- SWEEP: compute workers ------------------\n');
fprintf('  %-8s %-12s %-14s %-14s %-12s\n', 'workers', 'util %', 'meanWait min', 'p95Wait min', 'sameSess %');
sweepW = [1 2 3 4 6];
resW = cell(numel(sweepW), 1);
for k = 1:numel(sweepW)
    q = p; q.workers = sweepW(k);
    r = drishtiCapacityDES(q); resW{k} = r;
    fprintf('  %-8d %-12.1f %-14.2f %-14.2f %-12.1f\n', sweepW(k), ...
        r.compute.utilPct, r.compute.meanWaitMin, r.compute.p95WaitMin, ...
        r.turnaround.sameSessionPct);
end

fprintf('\n---------------- SWEEP: uplink bandwidth -----------------\n');
fprintf('  %-10s %-14s %-14s %-14s %-12s\n', 'Mbps', 'sessUtil %', 'meanWait min', 'p95Wait min', 'sameSess %');
sweepB = [0.25 0.5 1 2 4 8];
resB = cell(numel(sweepB), 1);
for k = 1:numel(sweepB)
    q = p; q.uplinkMbps = sweepB(k);
    r = drishtiCapacityDES(q); resB{k} = r;
    fprintf('  %-10.2f %-14.1f %-14.2f %-14.2f %-12.1f\n', sweepB(k), ...
        r.bandwidth.sessionLinkUtilPct, r.bandwidth.meanWaitMin, ...
        r.bandwidth.p95WaitMin, r.turnaround.sameSessionPct);
end

fprintf('\n---------------- SWEEP: screening sites ------------------\n');
fprintf('  %-8s %-12s %-14s %-14s %-14s\n', 'sites', 'pat/site/d', 'techUtil %', 'screened', 'unmet %');
sweepS = [4 5 6 8 10 12];
resS = cell(numel(sweepS), 1);
for k = 1:numel(sweepS)
    q = p; q.sites = sweepS(k);
    r = drishtiCapacityDES(q); resS{k} = r;
    fprintf('  %-8d %-12.1f %-14.1f %-14d %-14.1f\n', sweepS(k), ...
        r.technician.patientsPerSiteDay, r.technician.utilPct, ...
        r.demand.patientsScreened, r.demand.unmetDemandPct);
end

fprintf('\n---------------- SWEEP: grader FTE -----------------------\n');
fprintf('  %-8s %-12s %-14s %-14s %-12s\n', 'FTE', 'util %', 'meanWait h', 'p95Wait h', 'SLA24 %');
sweepG = [1 2 3 4];
resG = cell(numel(sweepG), 1);
for k = 1:numel(sweepG)
    q = p; q.graderFTE = sweepG(k);
    r = drishtiCapacityDES(q); resG{k} = r;
    fprintf('  %-8d %-12.1f %-14.2f %-14.2f %-12.1f\n', sweepG(k), ...
        r.review.utilPct, r.review.meanWaitH, r.review.p95WaitH, ...
        r.turnaround.withinSlaPct);
end

fprintf('\n---------------- SWEEP: ophthalmologist FTE --------------\n');
fprintf('  %-8s %-12s %-14s %-14s %-12s\n', 'FTE', 'util %', 'meanWait d', 'p95Wait d', 'maxBacklog');
sweepO = [0.5 1 1.5 2];
resO = cell(numel(sweepO), 1);
for k = 1:numel(sweepO)
    q = p; q.ophthFTE = sweepO(k);
    r = drishtiCapacityDES(q); resO{k} = r;
    fprintf('  %-8.1f %-12.1f %-14.2f %-14.2f %-12d\n', sweepO(k), ...
        r.referral.utilPct, r.referral.meanWaitDays, r.referral.p95WaitDays, ...
        r.referral.maxBacklog);
end

%% -------------------------------------------------- volume scaling
fprintf('\n---------------- SCALING: annual volume ------------------\n');
fprintf('  %-9s %-10s %-9s %-10s %-9s %-8s %-11s\n', ...
        'patients', 'techUtil%', 'cpuUtil%', 'gradUtil%', 'ophUtil%', 'unmet%', 'ophWaitP95d');
sweepV = [50000 100000 150000 200000 300000];
resV = cell(numel(sweepV), 1);
for k = 1:numel(sweepV)
    q = p; q.annualPatients = sweepV(k);
    r = drishtiCapacityDES(q); resV{k} = r;
    fprintf('  %-9d %-10.1f %-9.1f %-10.1f %-9.1f %-8.1f %-11.1f\n', sweepV(k), ...
        r.technician.utilPct, r.compute.utilPct, r.review.utilPct, ...
        r.referral.utilPct, r.demand.unmetDemandPct, r.referral.p95WaitDays);
end

%% ------------------------------------------- compute breakeven analysis
% The compute conclusion rests entirely on the per-image service time
% estimate. Find the value at which one worker saturates.
% Average (24h) utilisation badly understates the requirement: every site
% captures inside the same 6-hour window, so the queue is driven by
% utilisation DURING THE SESSION. Both are reported.
fprintf('\n---------------- SENSITIVITY: per-image compute time ------\n');
sweepP = [11 20 24 40 60 90 120];
for w = [1 2]
    fprintf('  -- %d worker(s) --\n', w);
    fprintf('  %-12s %-12s %-14s %-14s %-12s\n', ...
            'sec/image', 'util24h %', 'sessionUtil %', 'p95Wait min', 'sameSess %');
    for k = 1:numel(sweepP)
        q = p; q.procMeanSec = sweepP(k); q.workers = w;
        r = drishtiCapacityDES(q);
        fprintf('  %-12.0f %-12.1f %-14.1f %-14.2f %-12.1f\n', sweepP(k), ...
            r.compute.utilPct, r.compute.sessionUtilPct, ...
            r.compute.p95WaitMin, r.turnaround.sameSessionPct);
    end
end

%% -------------------------------------- minimum feasible configuration
% Criteria: unmet demand < 2%, every resource under 85% utilisation,
% >= 95% of reports inside the SLA, specialist p95 wait <= 14 days.
fprintf('\n---------------- MINIMUM FEASIBLE CONFIGURATION ----------\n');
best = p;
best.sites     = pickMin(sweepS, resS, @(r) r.demand.unmetDemandPct < 2 && r.technician.utilPct < 85);
best.workers   = pickMin(sweepW, resW, @(r) r.compute.utilPct < 85 && r.compute.p95WaitMin < 5);
best.graderFTE = pickMin(sweepG, resG, @(r) r.review.utilPct < 85 && r.review.p95WaitH < 8);
best.ophthFTE  = pickMin(sweepO, resO, @(r) r.referral.utilPct < 85 && r.referral.p95WaitDays <= 14);

fprintf('  screening sites/day       %d\n', best.sites);
fprintf('  MATLAB compute workers    %d\n', best.workers);
fprintf('  grader FTE                %g\n', best.graderFTE);
fprintf('  ophthalmologist FTE       %g\n', best.ophthFTE);

fprintf('\n  Verifying the combined configuration...\n\n');
ver = drishtiCapacityDES(best);
printRun(ver);

%% ---------------------------------------------------------- export
res = struct();
res.baseline = base;
res.sweepWorkers   = packSweep(sweepW, resW);
res.sweepBandwidth = packSweep(sweepB, resB);
res.sweepSites     = packSweep(sweepS, resS);
res.sweepGraders   = packSweep(sweepG, resG);
res.sweepOphth     = packSweep(sweepO, resO);
res.sweepVolume    = packSweep(sweepV, resV);
res.minimumConfig  = struct('sites', best.sites, 'workers', best.workers, ...
                            'graderFTE', best.graderFTE, 'ophthFTE', best.ophthFTE);
res.verified       = ver;

fid = fopen('capacity_results.json', 'w');
fwrite(fid, jsonencode(res, 'PrettyPrint', true));
fclose(fid);
fprintf('\nWrote capacity_results.json\n');

%% ------------------------------------------------------- local funcs
function printRun(r)
fprintf('---------------- DEMAND ----------------------------------\n');
fprintf('  annual target             %d\n', r.demand.targetPatients);
fprintf('  patients presented        %d\n', r.demand.patientsPresented);
fprintf('  unmet (no session slot)   %d  (%.1f%%)\n', r.demand.turnedAway, r.demand.unmetDemandPct);
fprintf('  patients screened         %d\n', r.demand.patientsScreened);
fprintf('  ungradable (both eyes)    %d  (%.2f%%)\n', r.demand.patientsUngradable, r.demand.ungradableRatePct);
fprintf('  single-eye-only patients  %.2f%%\n', r.demand.singleEyeOnlyPct);
fprintf('  images uploaded           %d  (%.2f per screened patient)\n', r.demand.imagesUploaded, r.demand.imagesPerPatient);

fprintf('\n---------------- BANDWIDTH -------------------------------\n');
fprintf('  total uploaded            %.1f GB/yr\n', r.bandwidth.gbPerYear);
fprintf('  per site per day          %.2f GB\n', r.bandwidth.gbPerSitePerDay);
fprintf('  transfer time per image   %.1f s\n', r.bandwidth.uploadSecPerImg);
fprintf('  link utilisation          %.1f%% of session hours (%.1f%% of 24h)\n', ...
        r.bandwidth.sessionLinkUtilPct, r.bandwidth.linkUtilPct);
fprintf('  upload queue wait         mean %.2f min, p95 %.2f min\n', r.bandwidth.meanWaitMin, r.bandwidth.p95WaitMin);

fprintf('\n---------------- COMPUTE ---------------------------------\n');
fprintf('  workers                   %d\n', r.compute.workers);
fprintf('  mean service time         %.2f s/image\n', r.compute.meanServiceSec);
fprintf('  utilisation               %.1f%% of 24h (%.1f%% of session hours)\n', ...
        r.compute.utilPct, r.compute.sessionUtilPct);
fprintf('  processing queue wait     mean %.2f min, p95 %.2f min, max %.1f min\n', ...
        r.compute.meanWaitMin, r.compute.p95WaitMin, r.compute.maxWaitMin);

fprintf('\n---------------- ACQUISITION -----------------------------\n');
fprintf('  patients per site per day %.1f\n', r.technician.patientsPerSiteDay);
fprintf('  technician time/patient   %.2f min\n', r.technician.minPerPatient);
fprintf('  technician utilisation    %.1f%% of session\n', r.technician.utilPct);

fprintf('\n---------------- HUMAN REVIEW ----------------------------\n');
fprintf('  cases to a human          %d  (%.1f%% of screened)\n', r.review.casesToHuman, r.review.humanTouchRatePct);
fprintf('    of which disagreements  %d\n', r.review.disagreementCases);
fprintf('    of which QA sample      %d\n', r.review.qaCases);
fprintf('  grader utilisation        %.1f%%\n', r.review.utilPct);
fprintf('  review queue wait         mean %.2f h, p95 %.2f h\n', r.review.meanWaitH, r.review.p95WaitH);

fprintf('\n---------------- REFERRAL --------------------------------\n');
fprintf('  referable patients        %d  (%.1f%%)\n', r.referral.referableCases, r.referral.referableRatePct);
fprintf('  specialist slots/day      %d  (demand %.1f/day)\n', r.referral.slotsPerDay, r.referral.demandPerDay);
fprintf('  slot utilisation          %.1f%%\n', r.referral.utilPct);
fprintf('  appointment wait          mean %.2f d, p95 %.2f d, peak backlog %d\n', ...
        r.referral.meanWaitDays, r.referral.p95WaitDays, r.referral.maxBacklog);

fprintf('\n---------------- TURNAROUND ------------------------------\n');
fprintf('  automated result only     median %.1f min, p95 %.1f min\n', ...
        r.turnaround.autoMedianMin, r.turnaround.autoP95Min);
fprintf('  result before patient leaves (<=%d min)  %.1f%%\n', ...
        r.params.sameSessionMin, r.turnaround.sameSessionPct);
fprintf('  full report (incl. human) median %.2f h, p90 %.2f h, p95 %.2f h, max %.1f h\n', ...
        r.turnaround.medianH, r.turnaround.p90H, r.turnaround.p95H, r.turnaround.maxH);
fprintf('  within %d h SLA            %.1f%%\n', r.params.slaHours, r.turnaround.withinSlaPct);
end

function v = pickMin(vals, runs, ok)
%PICKMIN  Smallest swept value whose run satisfies the predicate.
v = vals(end);
for k = 1:numel(vals)
    if ok(runs{k}), v = vals(k); return; end
end
end

function s = packSweep(vals, runs)
s = struct('value', {}, 'metrics', {});
for k = 1:numel(vals)
    r = runs{k};
    s(k).value = vals(k);
    s(k).metrics = struct( ...
        'techUtilPct',   r.technician.utilPct, ...
        'linkUtilPct',   r.bandwidth.sessionLinkUtilPct, ...
        'cpuUtilPct',    r.compute.utilPct, ...
        'graderUtilPct', r.review.utilPct, ...
        'ophthUtilPct',  r.referral.utilPct, ...
        'cpuWaitP95Min', r.compute.p95WaitMin, ...
        'linkWaitP95Min',r.bandwidth.p95WaitMin, ...
        'graderWaitP95H',r.review.p95WaitH, ...
        'ophthWaitP95D', r.referral.p95WaitDays, ...
        'sameSessionPct',r.turnaround.sameSessionPct, ...
        'slaPct',        r.turnaround.withinSlaPct, ...
        'patientsPresented', r.demand.patientsPresented);
end
end
