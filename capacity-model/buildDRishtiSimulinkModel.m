function mdl = buildDRishtiSimulinkModel(p, mdl)
%BUILDDRISHTISIMULINKMODEL  Build the district screening flow model in Simulink.
%
%   mdl = buildDRishtiSimulinkModel()            % uses drishtiParams()
%   mdl = buildDRishtiSimulinkModel(p)
%   mdl = buildDRishtiSimulinkModel(p, 'myModel')
%
%   Builds a discrete-time flow ("fluid queue") model of the pipeline:
%
%     acquisition -> uplink -> central processing -> human review -> referral
%
%   Each stage is a backlog integrator fed by an inflow and drained at
%   min(backlog/dt + inflow, capacity). Capacity is gated by a Pulse
%   Generator representing that resource's working window, so the model
%   reproduces the daily burst-and-drain behaviour that drives queueing:
%   every site captures inside the same six-hour session, while compute
%   and uplink run around the clock.
%
%   Time base: hours. Fixed step of p.simStepH over p.workingDays days.
%
%   >>> IMPORTANT <<<
%   This builder was written against a machine that had base MATLAB only,
%   so it has NOT been executed. The block paths and parameter names used
%   here are the long-standing base-Simulink ones, but verify before
%   trusting the output. Run compareSimulinkToDES to check the annual
%   totals against the discrete-event model, which HAS been run.
%
%   Requires Simulink. No SimEvents needed - this is a rate/backlog model,
%   not an entity model. Use drishtiCapacityDES for per-patient waiting
%   time distributions, which a fluid model cannot produce.

if nargin < 1 || isempty(p),   p = drishtiParams(); end
if nargin < 2 || isempty(mdl), mdl = 'drishtiCapacityFlow'; end

dt      = p.simStepH;
stopH   = p.workingDays * 24;

%% ------------------------------------------------ derived rate constants
% Patients per hour arriving while a session is open.
patPerSessionHour = p.annualPatients / (p.workingDays * p.sessionHours);

% Capture capacity across all sites, patients/hour while sessions are open.
captureCapPerH = p.sites * 60 / (p.captureMin + p.retryMin * expectedRetries(p));

% Images actually uploaded per screened patient.
imgPerPatient = 2 * (1 - residualRejectRate(p));

% Uplink capacity, images/hour, all sites, 24h.
uplinkCapPerH = p.sites * (p.uplinkMbps * 3600) / (p.imageMB * 8);

% Compute capacity, images/hour, 24h.
computeCapPerH = p.workers * 3600 / p.procMeanSec;

% Human review, cases/hour while graders are on shift.
reviewCapPerH = p.graderFTE * 60 / p.reviewMin;
humanTouchRate = p.pDisagree + (1 - p.pDisagree) * p.qaSampleRate;

% Referral, cases/hour while the clinic is open.
referralCapPerH = p.ophthFTE * 60 / p.ophthMinPerCase;

%% ----------------------------------------------------------- new model
if bdIsLoaded(mdl), close_system(mdl, 0); end
new_system(mdl);
open_system(mdl);

set_param(mdl, 'Solver', 'FixedStepDiscrete', ...
               'FixedStep', num2str(dt), ...
               'StartTime', '0', ...
               'StopTime',  num2str(stopH), ...
               'SolverType', 'Fixed-step');

x = 40; y = 40; dy = 170;

%% ------------------------------------------------- stage 1: acquisition
% Session window: 6h open in every 24h day.
addPulse(mdl, 'SessionGate', patPerSessionHour, 24, 100 * p.sessionHours / 24, dt, [x y]);
addConst(mdl, 'CaptureCapacity', captureCapPerH, [x y+60]);
addPulse(mdl, 'CaptureGate', 1, 24, 100 * p.sessionHours / 24, dt, [x y+110]);
addProduct(mdl, 'CaptureCapGated', [x+120 y+80]);
connect(mdl, 'CaptureCapacity/1', 'CaptureCapGated/1');
connect(mdl, 'CaptureGate/1',     'CaptureCapGated/2');

stage(mdl, 'Acquire', dt, [x+220 y]);
connect(mdl, 'SessionGate/1',      'Acquire_Inflow/1');
connect(mdl, 'CaptureCapGated/1',  'Acquire_Capacity/1');

%% ----------------------------------------------------- stage 2: uplink
addGain(mdl, 'ImagesPerPatient', imgPerPatient, [x+520 y]);
connect(mdl, 'Acquire_Flow/1', 'ImagesPerPatient/1');
addConst(mdl, 'UplinkCapacity', uplinkCapPerH, [x+520 y+60]);

stage(mdl, 'Uplink', dt, [x+640 y]);
connect(mdl, 'ImagesPerPatient/1', 'Uplink_Inflow/1');
connect(mdl, 'UplinkCapacity/1',   'Uplink_Capacity/1');

%% ------------------------------------------------ stage 3: computation
y = y + dy;
addConst(mdl, 'ComputeCapacity', computeCapPerH, [x y+60]);
stage(mdl, 'Compute', dt, [x+220 y]);
connect(mdl, 'Uplink_Flow/1',      'Compute_Inflow/1');
connect(mdl, 'ComputeCapacity/1',  'Compute_Capacity/1');

%% ---------------------------------------------- stage 4: human review
% Back to patient units, then the fraction a human must look at.
addGain(mdl, 'ToPatients', 1 / imgPerPatient, [x+520 y]);
connect(mdl, 'Compute_Flow/1', 'ToPatients/1');
addGain(mdl, 'HumanTouchRate', humanTouchRate, [x+620 y]);
connect(mdl, 'ToPatients/1', 'HumanTouchRate/1');

addConst(mdl, 'ReviewCapacity', reviewCapPerH, [x+520 y+60]);
addPulse(mdl, 'GraderGate', 1, 24, 100 * p.graderHoursPerDay / 24, dt, [x+520 y+110]);
addProduct(mdl, 'ReviewCapGated', [x+640 y+80]);
connect(mdl, 'ReviewCapacity/1', 'ReviewCapGated/1');
connect(mdl, 'GraderGate/1',     'ReviewCapGated/2');

stage(mdl, 'Review', dt, [x+760 y]);
connect(mdl, 'HumanTouchRate/1', 'Review_Inflow/1');
connect(mdl, 'ReviewCapGated/1', 'Review_Capacity/1');

%% -------------------------------------------------- stage 5: referral
y = y + dy;
addGain(mdl, 'ReferableRate', p.pReferable / humanTouchRate, [x y]);
connect(mdl, 'Review_Flow/1', 'ReferableRate/1');

addConst(mdl, 'ReferralCapacity', referralCapPerH, [x y+60]);
addPulse(mdl, 'OphthGate', 1, 24, 100 * p.ophthHoursPerDay / 24, dt, [x y+110]);
addProduct(mdl, 'ReferralCapGated', [x+120 y+80]);
connect(mdl, 'ReferralCapacity/1', 'ReferralCapGated/1');
connect(mdl, 'OphthGate/1',        'ReferralCapGated/2');

stage(mdl, 'Referral', dt, [x+220 y]);
connect(mdl, 'ReferableRate/1',     'Referral_Inflow/1');
connect(mdl, 'ReferralCapGated/1',  'Referral_Capacity/1');

Simulink.BlockDiagram.arrangeSystem(mdl);
save_system(mdl);

fprintf('Built %s.slx  (%d days at %g h steps)\n', mdl, p.workingDays, dt);
fprintf('Run with:  out = sim(''%s'');\n', mdl);
end

%% ===================================================== builder helpers

function stage(mdl, name, dt, pos)
%STAGE  One backlog stage: inflow and capacity in, served flow out.
%
%   flow    = min(backlog/dt + inflow, capacity)
%   backlog = backlog + (inflow - flow) * dt      (never negative)
%
%   Creates <name>_Inflow and <name>_Capacity as Inport-like entry points
%   (Sum blocks acting as pass-through junctions), and logs <name>_Flow,
%   <name>_Backlog and <name>_Util to the workspace.

x = pos(1); y = pos(2);

addJunction(mdl, [name '_Inflow'],   [x        y]);
addJunction(mdl, [name '_Capacity'], [x        y+60]);

% backlog/dt + inflow  -> the most that could be served this step
addGain(mdl, [name '_BacklogRate'], 1/dt, [x+80  y+120]);
addSum(mdl,  [name '_Offered'], '++', [x+160 y]);
connect(mdl, [name '_Inflow/1'],      [name '_Offered/1']);
connect(mdl, [name '_BacklogRate/1'], [name '_Offered/2']);

% flow = min(offered, capacity)
addMinMax(mdl, [name '_Flow'], 'min', 2, [x+240 y]);
connect(mdl, [name '_Offered/1'],  [name '_Flow/1']);
connect(mdl, [name '_Capacity/1'], [name '_Flow/2']);

% backlog integrates (inflow - flow), clamped at zero
addSum(mdl, [name '_Net'], '+-', [x+240 y+120]);
connect(mdl, [name '_Inflow/1'], [name '_Net/1']);
connect(mdl, [name '_Flow/1'],   [name '_Net/2']);

blk = sprintf('%s/%s_Backlog', mdl, name);
% Forward Euler has no direct feedthrough, which is what breaks the
% backlog -> flow -> backlog algebraic loop. Do not change it to
% Backward Euler or Trapezoidal without adding an explicit unit delay.
add_block('simulink/Discrete/Discrete-Time Integrator', blk, ...
    'IntegratorMethod', 'Integration: Forward Euler', ...
    'SampleTime', num2str(dt), 'InitialCondition', '0', ...
    'LimitOutput', 'on', 'UpperSaturationLimit', 'inf', ...
    'LowerSaturationLimit', '0', 'Position', boxAt([x+320 y+120]));
connect(mdl, [name '_Net/1'], [name '_Backlog/1']);
connect(mdl, [name '_Backlog/1'], [name '_BacklogRate/1']);

% utilisation = flow / capacity
addDivide(mdl, [name '_Util'], [x+320 y+60]);
connect(mdl, [name '_Flow/1'],     [name '_Util/1']);
connect(mdl, [name '_Capacity/1'], [name '_Util/2']);

addToWorkspace(mdl, [name '_FlowLog'],    [name '_flow'],    dt, [x+400 y]);
addToWorkspace(mdl, [name '_BacklogLog'], [name '_backlog'], dt, [x+400 y+120]);
addToWorkspace(mdl, [name '_UtilLog'],    [name '_util'],    dt, [x+400 y+60]);
connect(mdl, [name '_Flow/1'],    [name '_FlowLog/1']);
connect(mdl, [name '_Backlog/1'], [name '_BacklogLog/1']);
connect(mdl, [name '_Util/1'],    [name '_UtilLog/1']);
end

function addJunction(mdl, name, pos)
add_block('simulink/Math Operations/Sum', sprintf('%s/%s', mdl, name), ...
    'Inputs', '+', 'IconShape', 'rectangular', 'Position', boxAt(pos));
end

function addSum(mdl, name, signs, pos)
add_block('simulink/Math Operations/Sum', sprintf('%s/%s', mdl, name), ...
    'Inputs', signs, 'IconShape', 'rectangular', 'Position', boxAt(pos));
end

function addGain(mdl, name, k, pos)
add_block('simulink/Math Operations/Gain', sprintf('%s/%s', mdl, name), ...
    'Gain', num2str(k, '%.10g'), 'Position', boxAt(pos));
end

function addConst(mdl, name, v, pos)
add_block('simulink/Sources/Constant', sprintf('%s/%s', mdl, name), ...
    'Value', num2str(v, '%.10g'), 'Position', boxAt(pos));
end

function addProduct(mdl, name, pos)
add_block('simulink/Math Operations/Product', sprintf('%s/%s', mdl, name), ...
    'Inputs', '2', 'Position', boxAt(pos));
end

function addDivide(mdl, name, pos)
add_block('simulink/Math Operations/Divide', sprintf('%s/%s', mdl, name), ...
    'Inputs', '*/', 'Position', boxAt(pos));
end

function addMinMax(mdl, name, fcn, n, pos)
add_block('simulink/Math Operations/MinMax', sprintf('%s/%s', mdl, name), ...
    'Function', fcn, 'Inputs', num2str(n), 'Position', boxAt(pos));
end

function addPulse(mdl, name, amp, periodH, dutyPct, dt, pos)
add_block('simulink/Sources/Pulse Generator', sprintf('%s/%s', mdl, name), ...
    'PulseType', 'Sample based', 'Amplitude', num2str(amp, '%.10g'), ...
    'Period', num2str(round(periodH / dt)), ...
    'PulseWidth', num2str(max(1, round(dutyPct / 100 * periodH / dt))), ...
    'PhaseDelay', '0', 'SampleTime', num2str(dt), 'Position', boxAt(pos));
end

function addToWorkspace(mdl, name, varName, dt, pos)
add_block('simulink/Sinks/To Workspace', sprintf('%s/%s', mdl, name), ...
    'VariableName', varName, 'SaveFormat', 'Timeseries', ...
    'SampleTime', num2str(dt), 'Position', boxAt(pos));
end

function connect(mdl, src, dst)
add_line(mdl, src, dst, 'autorouting', 'smart');
end

function pos = boxAt(p)
pos = [p(1) p(2) p(1)+50 p(2)+30];
end

%% ------------------------------------------------- rate-model helpers

function r = expectedRetries(p)
%EXPECTEDRETRIES  Mean recapture attempts per patient across both eyes.
pn = p.pRejectNormal; pd = p.pRejectDifficult; f = p.pDifficultPatient;
en = meanAttempts(pn, p.maxRetries);
ed = meanAttempts(pd, p.maxRetries);
r = 2 * ((1 - f) * en + f * ed);
end

function m = meanAttempts(pRej, maxRetries)
m = 0;
for k = 1:maxRetries
    m = m + pRej^k;
end
end

function r = residualRejectRate(p)
%RESIDUALREJECTRATE  Fraction of eyes still ungradable after all retries.
n = p.maxRetries + 1;
r = (1 - p.pDifficultPatient) * p.pRejectNormal^n + ...
     p.pDifficultPatient      * p.pRejectDifficult^n;
end
