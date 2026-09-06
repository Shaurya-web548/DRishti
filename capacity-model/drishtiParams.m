function p = drishtiParams()
%DRISHTIPARAMS  Baseline parameters for the district screening capacity model.
%
%   Every value carries a confidence tag:
%     [CODE]  derived from the DRishti source in this repository
%     [OPS]   deployment assumption - change to match your district
%     [LIT]   typical published value for community DR screening
%
%   The [OPS] and [LIT] values are the ones to challenge first: the
%   conclusions are far more sensitive to them than to the [CODE] ones.

%% ---------------------------------------------------------- programme
p.annualPatients   = 100000;  % [OPS] district screening target per year
p.workingDays      = 250;     % [OPS] screening days per year
p.sites            = 8;       % [OPS] camps/PHCs screening in parallel each day
p.sessionHours     = 6;       % [OPS] hours of screening per site per day
p.sessionStartH    = 9;       % [OPS] session starts 09:00

%% ------------------------------------------------------- acquisition
p.captureMin       = 4.0;     % [OPS] mean min/patient: consent, seating, 2 captures
p.retryMin         = 1.5;     % [OPS] extra min per recapture attempt
p.maxRetries       = 2;       % [CODE] assessImageQuality reject -> recapture, 2 retries

% Quality-gate outcomes. assessImageQuality returns pass/enhanced/reject;
% rejection is dominated by media opacity, which is patient-level, not random
% per image - hence the two-population split.
p.pDifficultPatient = 0.08;   % [LIT] cataract/small pupil/media opacity
p.pRejectNormal     = 0.06;   % [LIT] reject rate, ordinary patient
p.pRejectDifficult  = 0.70;   % [LIT] reject rate, difficult patient
p.pEnhanced         = 0.25;   % [CODE] borderline -> CLAHE + denoise path

%% ------------------------------------------------------------ uplink
p.imageMB          = 3.5;     % [OPS] JPEG from an 8-12 MP non-mydriatic camera
p.uplinkMbps       = 4.0;     % [OPS] effective rural 4G uplink per site

%% ------------------------------------------------- central processing
% Per-image service time is dominated by the CLASSICAL stage, not the CNN:
% segmentRetina runs 24 matched-filter convolutions (2 sigmas x 12
% orientations) at 1024 px, a ~51x51 medfilt2 background estimate, a
% large-sigma imgaussfilt for the fovea map, and bwskel + a per-segment
% tortuosity loop. CNN inference at 224x224 is a rounding error next to it.
p.workers          = 2;       % [OPS] MATLAB Engine worker processes
p.procMeanSec      = 11.0;    % [CODE] mean s/image across the whole pipeline
p.procCV           = 0.35;    % [CODE] spread - lesion count drives regionprops cost
p.enhanceExtraSec  = 0.4;     % [CODE] extra cost of the CLAHE path

%% ---------------------------------------------------- human decisions
p.pDisagree        = 0.22;    % [CODE] combineGrades -> 'review' when CNN != rules
p.qaSampleRate     = 0.10;    % [OPS] QA audit fraction of auto-agreed cases
p.reviewMin        = 2.5;     % [OPS] min/case to adjudicate with overlay + Grad-CAM
p.qaMin            = 1.5;     % [OPS] min/case for a QA spot-check
p.graderFTE        = 2;       % [OPS] trained non-physician graders
p.graderHoursPerDay = 8;      % [OPS]
p.graderStartH     = 9;       % [OPS]

%% -------------------------------------------------------- referral
p.pReferable       = 0.07;    % [LIT] grade >= 2 in a screened diabetic cohort
p.ophthFTE         = 1;       % [OPS] ophthalmologist sessions available
p.ophthHoursPerDay = 6;       % [OPS]
p.ophthMinPerCase  = 10;      % [OPS] slit-lamp exam + decision

%% ----------------------------------------------------- service levels
p.slaHours         = 24;      % [OPS] report turnaround target (working hours)
p.sameSessionMin   = 30;      % [OPS] stretch goal: result before patient leaves

%% ------------------------------------------- Simulink flow model only
p.simStepH         = 0.25;    % [OPS] fixed step, hours (15 min)

p.seed             = 42;
end
