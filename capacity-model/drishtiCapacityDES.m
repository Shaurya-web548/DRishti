function out = drishtiCapacityDES(p)
%DRISHTICAPACITYDES  Discrete-event simulation of a district DR screening programme.
%
%   out = drishtiCapacityDES(p)
%
%   Models the full telemedicine pipeline that DRishti sits inside:
%
%     patient arrival -> technician capture (2 eyes, retries on reject)
%       -> edge quality gate (assessImageQuality) -> uplink transfer
%       -> central MATLAB worker pool (segmentRetina + CNN + Grad-CAM)
%       -> automated decision (combineGrades) -> human adjudication of
%          disagreements + QA sample -> ophthalmologist referral slots
%
%   Every queue is FIFO. Multi-server queues are simulated exactly by
%   sorting arrivals and assigning each to the earliest-free server.
%   Shift-limited resources (technicians, graders) consume work only
%   inside their working window and roll over to the next day.
%
%   Requires base MATLAB only - no toolboxes.
%
%   See drishtiParams for the parameter struct and runCapacityStudy for
%   the baseline run and resource sweeps.

rng(p.seed);

HRS_PER_DAY = 24;

%% ------------------------------------------------------------------ demand
patientsPerSiteDay = p.annualPatients / (p.workingDays * p.sites);
nDays  = p.workingDays;
nSites = p.sites;

% Pre-allocate for the worst case: every patient, both eyes.
maxPat = ceil(nDays * nSites * patientsPerSiteDay) + nSites * nDays;
maxImg = 2 * maxPat;

patCaptureEnd = zeros(maxPat, 1);   % when the patient leaves the camera
patDay        = zeros(maxPat, 1);
patUngradable = false(maxPat, 1);
patNimg       = zeros(maxPat, 1);
nPat = 0;

imgPat        = zeros(maxImg, 1);
imgSite       = zeros(maxImg, 1);
imgReadyTime  = zeros(maxImg, 1);   % capture finished, queued for uplink
imgEnhanced   = false(maxImg, 1);
nImg = 0;

techBusyMin = zeros(nSites, 1);     % technician minutes consumed per site
turnedAway  = 0;                    % demand that could not be seated in a session

%% -------------------------------------------- stage 1+2: capture & quality
% Technician is a single server per site, working the session window.
% Arrivals are Poisson over the session; the queue is FIFO.
for d = 1:nDays
    dayStart = (d - 1) * HRS_PER_DAY + p.sessionStartH;
    dayEnd   = (d - 1) * HRS_PER_DAY + p.sessionStartH + p.sessionHours;

    for s = 1:nSites
        nToday = poissrndLocal(patientsPerSiteDay);
        if nToday == 0, continue; end

        % Arrival instants, uniform across the session, served in order.
        arr = sort(dayStart + p.sessionHours * rand(nToday, 1));
        techFree = dayStart;

        for k = 1:nToday
            tStart = max(arr(k), techFree);

            % Demand the session cannot absorb. Counted as a capacity
            % shortfall, not as a screened patient.
            if tStart >= dayEnd
                turnedAway = turnedAway + (nToday - k + 1);
                break;
            end

            isDifficult = rand < p.pDifficultPatient;
            if isDifficult
                pRej = p.pRejectDifficult;
            else
                pRej = p.pRejectNormal;
            end

            capMin = expRnd(p.captureMin);   % base workflow time
            gradableEyes = 0;
            eyeEnh   = false(2, 1);

            for eye = 1:2
                attempts = 0;
                accepted = false;
                while attempts <= p.maxRetries
                    attempts = attempts + 1;
                    if rand >= pRej
                        accepted = true;
                        break;
                    end
                    capMin = capMin + expRnd(p.retryMin);   % recapture cost
                end
                if accepted
                    gradableEyes = gradableEyes + 1;
                    eyeEnh(gradableEyes)   = rand < p.pEnhanced;
                end
            end

            tEnd = tStart + capMin / 60;
            techFree = tEnd;
            techBusyMin(s) = techBusyMin(s) + capMin;

            nPat = nPat + 1;
            patCaptureEnd(nPat) = tEnd;
            patDay(nPat)  = d;
            patNimg(nPat) = gradableEyes;
            patUngradable(nPat) = (gradableEyes == 0);

            for j = 1:gradableEyes
                nImg = nImg + 1;
                imgPat(nImg)       = nPat;
                imgSite(nImg)      = s;
                imgReadyTime(nImg) = tEnd;
                imgEnhanced(nImg)  = eyeEnh(j);
            end
        end
    end
end

patCaptureEnd = patCaptureEnd(1:nPat);
patUngradable = patUngradable(1:nPat);
patNimg       = patNimg(1:nPat);

imgPat       = imgPat(1:nImg);
imgSite      = imgSite(1:nImg);
imgReadyTime = imgReadyTime(1:nImg);
imgEnhanced  = imgEnhanced(1:nImg);

%% ----------------------------------------------------- stage 3: uplink
% One uplink per site, store-and-forward (runs 24/7, so a backlog built
% during the session drains after it). Transfer time = size / bandwidth.
uploadSec = (p.imageMB * 8) / p.uplinkMbps;          % seconds per image
imgUploadEnd = zeros(nImg, 1);
uplinkBusyH  = zeros(nSites, 1);

for s = 1:nSites
    idx = find(imgSite == s);
    if isempty(idx), continue; end
    [~, ord] = sort(imgReadyTime(idx));
    idx = idx(ord);
    free = 0;
    for k = 1:numel(idx)
        i = idx(k);
        st = max(imgReadyTime(i), free);
        en = st + uploadSec / 3600;
        imgUploadEnd(i) = en;
        free = en;
    end
    uplinkBusyH(s) = numel(idx) * uploadSec / 3600;
end

imgUploadWaitMin = (imgUploadEnd - imgReadyTime) * 60 - uploadSec / 60;

%% ------------------------------------------- stage 4: central processing
% W identical MATLAB Engine workers, each strictly serial (the engine is a
% locked singleton in matlab_bridge.py, so one worker = one process).
procSec = lognRnd(p.procMeanSec, p.procCV, nImg);
procSec(imgEnhanced) = procSec(imgEnhanced) + p.enhanceExtraSec;

[~, ord] = sort(imgUploadEnd);
workerFree = zeros(p.workers, 1);
imgProcEnd = zeros(nImg, 1);
imgProcWaitMin = zeros(nImg, 1);

for k = 1:nImg
    i = ord(k);
    [tFree, w] = min(workerFree);
    st = max(imgUploadEnd(i), tFree);
    en = st + procSec(i) / 3600;
    workerFree(w) = en;
    imgProcEnd(i) = en;
    imgProcWaitMin(i) = (st - imgUploadEnd(i)) * 60;
end

%% ------------------------------------------- stage 5: automated decision
% A patient's automated result is ready when both eyes are through.
patAutoReady = zeros(nPat, 1);
patAutoReady(patUngradable) = patCaptureEnd(patUngradable);
for i = 1:nImg
    pi = imgPat(i);
    if imgProcEnd(i) > patAutoReady(pi)
        patAutoReady(pi) = imgProcEnd(i);
    end
end

screened = ~patUngradable;
u = rand(nPat, 1);
needsReview = screened & (u < p.pDisagree);                       % combineGrades -> 'review'
needsQA     = screened & ~needsReview & (rand(nPat,1) < p.qaSampleRate);
humanCase   = needsReview | needsQA;

reviewMin = zeros(nPat, 1);
reviewMin(needsReview) = expRnd2(p.reviewMin, sum(needsReview));
reviewMin(needsQA)     = expRnd2(p.qaMin,     sum(needsQA));

%% ------------------------------------------- stage 6: human adjudication
% G graders, each working graderHoursPerDay inside a daily window.
gIdx = find(humanCase);
[~, ord] = sort(patAutoReady(gIdx));
gIdx = gIdx(ord);

nG = max(1, round(p.graderFTE));
graderFree = zeros(nG, 1);
patReportTime = patAutoReady;
graderWaitH = zeros(nPat, 1);
graderBusyMin = 0;

wStart = p.graderStartH;
wEnd   = p.graderStartH + p.graderHoursPerDay;

for k = 1:numel(gIdx)
    i = gIdx(k);
    [tFree, g] = min(graderFree);
    st = max(patAutoReady(i), tFree);
    st = nextWorkTime(st, wStart, wEnd);
    en = serveInShift(st, reviewMin(i) / 60, wStart, wEnd);
    graderFree(g) = en;
    patReportTime(i) = en;
    graderWaitH(i) = st - patAutoReady(i);
    graderBusyMin = graderBusyMin + reviewMin(i);
end

%% --------------------------------------- stage 7: ophthalmologist referral
% Referable patients need a specialist slot. Slots are a fixed daily
% capacity; the backlog carries from one working day to the next.
isReferable = screened & (rand(nPat, 1) < p.pReferable);
refIdx = find(isReferable);
[~, ord] = sort(patReportTime(refIdx));
refIdx = refIdx(ord);

slotsPerDay = floor(p.ophthFTE * p.ophthHoursPerDay * 60 / p.ophthMinPerCase);
nRef = numel(refIdx);
apptWaitDays = zeros(nRef, 1);
apptDay      = zeros(nRef, 1);
readyDayAll  = zeros(nRef, 1);

% FIFO queue against a fixed number of appointment slots per working day.
% A case can only be booked on or after the day its report is signed off,
% and only if that day still has a free slot; otherwise it rolls forward.
cursor    = 0;
usedToday = 0;

for k = 1:nRef
    i = refIdx(k);
    readyDay = floor(patReportTime(i) / HRS_PER_DAY) + 1;
    readyDayAll(k) = readyDay;

    if readyDay > cursor
        cursor = readyDay;
        usedToday = 0;
    end
    while usedToday >= slotsPerDay
        cursor = cursor + 1;
        usedToday = 0;
    end
    usedToday = usedToday + 1;

    apptDay(k) = cursor;
    apptWaitDays(k) = cursor - readyDay;
end

% Peak backlog: the largest number of patients waiting on any single day.
maxBacklog = 0;
if nRef > 0
    lastDay = max(apptDay);
    for d = 1:lastDay
        waiting = sum(readyDayAll <= d & apptDay > d);
        if waiting > maxBacklog, maxBacklog = waiting; end
    end
end

%% ----------------------------------------------------------- metrics
turnaroundH = patReportTime(screened) - patCaptureEnd(screened);
autoOnlyH   = patAutoReady(screened) - patCaptureEnd(screened);

simHours = nDays * HRS_PER_DAY;

out = struct();
out.params = p;

out.demand.targetPatients      = p.annualPatients;
out.demand.patientsPresented   = nPat;
out.demand.turnedAway          = turnedAway;
out.demand.unmetDemandPct      = 100 * turnedAway / max(1, nPat + turnedAway);
out.demand.patientsScreened    = sum(screened);
out.demand.patientsUngradable  = sum(patUngradable);
out.demand.ungradableRatePct   = 100 * sum(patUngradable) / nPat;
out.demand.imagesUploaded      = nImg;
out.demand.imagesPerPatient    = nImg / max(1, sum(screened));
out.demand.singleEyeOnlyPct    = 100 * sum(patNimg == 1) / max(1, nPat);

out.bandwidth.gbPerYear        = nImg * p.imageMB / 1024;
out.bandwidth.gbPerSitePerDay  = nImg * p.imageMB / 1024 / (nSites * nDays);
out.bandwidth.uploadSecPerImg  = uploadSec;
out.bandwidth.linkUtilPct      = 100 * mean(uplinkBusyH) / simHours;
out.bandwidth.sessionLinkUtilPct = 100 * mean(uplinkBusyH) / (nDays * p.sessionHours);
out.bandwidth.meanWaitMin      = mean(imgUploadWaitMin);
out.bandwidth.p95WaitMin       = pctl(imgUploadWaitMin, 95);

out.compute.workers            = p.workers;
out.compute.meanServiceSec     = mean(procSec);
out.compute.utilPct            = 100 * sum(procSec) / 3600 / (p.workers * simHours);
out.compute.sessionUtilPct     = 100 * sum(procSec) / 3600 / (p.workers * nDays * p.sessionHours);
out.compute.meanWaitMin        = mean(imgProcWaitMin);
out.compute.p95WaitMin         = pctl(imgProcWaitMin, 95);
out.compute.maxWaitMin         = max(imgProcWaitMin);

out.technician.utilPct         = 100 * mean(techBusyMin) / (nDays * p.sessionHours * 60);
out.technician.minPerPatient   = mean(techBusyMin) * nSites / nPat;
out.technician.patientsPerSiteDay = nPat / (nSites * nDays);

out.review.casesToHuman        = sum(humanCase);
out.review.disagreementCases   = sum(needsReview);
out.review.qaCases             = sum(needsQA);
out.review.humanTouchRatePct   = 100 * sum(humanCase) / max(1, sum(screened));
out.review.graderFTE           = p.graderFTE;
out.review.utilPct             = 100 * graderBusyMin / 60 / (nG * p.graderHoursPerDay * nDays);
out.review.meanWaitH           = mean(graderWaitH(humanCase));
out.review.p95WaitH            = pctl(graderWaitH(humanCase), 95);

out.referral.referableCases    = numel(refIdx);
out.referral.referableRatePct  = 100 * numel(refIdx) / max(1, sum(screened));
out.referral.slotsPerDay       = slotsPerDay;
out.referral.demandPerDay      = numel(refIdx) / nDays;
out.referral.utilPct           = 100 * (numel(refIdx) / nDays) / max(1, slotsPerDay);
out.referral.meanWaitDays      = mean(apptWaitDays);
out.referral.p95WaitDays       = pctl(apptWaitDays, 95);
out.referral.maxBacklog        = maxBacklog;

out.turnaround.medianH         = pctl(turnaroundH, 50);
out.turnaround.p90H            = pctl(turnaroundH, 90);
out.turnaround.p95H            = pctl(turnaroundH, 95);
out.turnaround.maxH            = max(turnaroundH);
out.turnaround.autoMedianMin   = pctl(autoOnlyH, 50) * 60;
out.turnaround.autoP95Min      = pctl(autoOnlyH, 95) * 60;
out.turnaround.sameSessionPct  = 100 * mean(autoOnlyH * 60 <= p.sameSessionMin);
out.turnaround.withinSlaPct    = 100 * mean(turnaroundH <= p.slaHours);

end

%% ===================================================== local helpers

function v = pctl(x, q)
%PCTL  Percentile without the Statistics Toolbox (linear interpolation).
x = sort(x(:));
n = numel(x);
if n == 0, v = NaN; return; end
if n == 1, v = x; return; end
pos = (q / 100) * (n - 1) + 1;
lo = floor(pos); hi = ceil(pos);
v = x(lo) + (pos - lo) * (x(hi) - x(lo));
end

function n = poissrndLocal(lambda)
%POISSRNDLOCAL  Poisson draw by Knuth's method (no Statistics Toolbox).
L = exp(-lambda);
k = 0; pr = 1;
while true
    pr = pr * rand;
    if pr <= L, break; end
    k = k + 1;
    if k > 20 * lambda + 100, break; end
end
n = k;
end

function v = expRnd(mu)
v = -mu * log(rand);
end

function v = expRnd2(mu, n)
if n == 0, v = zeros(0,1); return; end
v = -mu * log(rand(n, 1));
end

function v = lognRnd(meanVal, cv, n)
%LOGNRND  Lognormal draws with the requested mean and coefficient of variation.
sigma = sqrt(log(1 + cv^2));
mu    = log(meanVal) - 0.5 * sigma^2;
v = exp(mu + sigma * randn(n, 1));
end

function t = nextWorkTime(t, startH, endH)
%NEXTWORKTIME  Advance t to the next instant inside a daily working window.
d = floor(t / 24);
h = t - 24 * d;
if h < startH
    t = 24 * d + startH;
elseif h >= endH
    t = 24 * (d + 1) + startH;
end
end

function t = serveInShift(tStart, durH, startH, endH)
%SERVEINSHIFT  Consume durH hours of work inside the daily window only.
t = nextWorkTime(tStart, startH, endH);
remaining = durH;
guard = 0;
while remaining > 1e-12
    guard = guard + 1;
    if guard > 100000, break; end
    d = floor(t / 24);
    h = t - 24 * d;
    avail = endH - h;
    if remaining <= avail
        t = t + remaining;
        remaining = 0;
    else
        remaining = remaining - avail;
        t = 24 * (d + 1) + startH;
    end
end
end
