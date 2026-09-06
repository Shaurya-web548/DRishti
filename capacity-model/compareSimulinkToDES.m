%COMPARESIMULINKTODES  Validate the Simulink flow model against the DES.
%
%   Run this on a machine that has Simulink. It builds the flow model,
%   simulates it, and checks its annual throughput and utilisation against
%   drishtiCapacityDES, which is the reference implementation.
%
%   The two models answer different questions and will NOT agree exactly:
%
%     drishtiCapacityDES   entity-level, stochastic. Gives waiting-time
%                          distributions and percentiles. This is the one
%                          the reported numbers come from.
%     Simulink flow model  deterministic rates and backlogs. Gives the
%                          daily burst-and-drain shape and where backlog
%                          accumulates. Cannot produce percentiles.
%
%   Expect annual throughput within a few percent and utilisation within
%   a few points. Larger gaps mean a parameter was mistranslated between
%   the two - that is exactly what this script is for.

p = drishtiParams();

fprintf('Building Simulink model...\n');
mdl = buildDRishtiSimulinkModel(p);

fprintf('Simulating %d days...\n', p.workingDays);
simOut = sim(mdl);

fprintf('Running the discrete-event reference...\n');
des = drishtiCapacityDES(p);

%% ------------------------------------------------------------- compare
dt = p.simStepH;

rows = {
    'Patients screened',   totalOf(simOut, 'Acquire_flow',  dt), des.demand.patientsScreened
    'Images uploaded',     totalOf(simOut, 'Uplink_flow',   dt), des.demand.imagesUploaded
    'Images processed',    totalOf(simOut, 'Compute_flow',  dt), des.demand.imagesUploaded
    'Human review cases',  totalOf(simOut, 'Review_flow',   dt), des.review.casesToHuman
    'Referrals',           totalOf(simOut, 'Referral_flow', dt), des.referral.referableCases
};

fprintf('\n%-22s %14s %14s %10s\n', 'Quantity', 'Simulink', 'DES', 'diff %');
fprintf('%s\n', repmat('-', 1, 64));
for k = 1:size(rows, 1)
    a = rows{k, 2}; b = rows{k, 3};
    d = 100 * (a - b) / max(1, b);
    fprintf('%-22s %14.0f %14.0f %9.1f%%\n', rows{k, 1}, a, b, d);
end

peaks = {
    'Uplink',   'Uplink_util',   des.bandwidth.sessionLinkUtilPct
    'Compute',  'Compute_util',  des.compute.sessionUtilPct
    'Review',   'Review_util',   des.review.utilPct
    'Referral', 'Referral_util', des.referral.utilPct
};

fprintf('\n%-22s %14s %14s\n', 'Peak utilisation %', 'Simulink', 'DES (session)');
fprintf('%s\n', repmat('-', 1, 54));
for k = 1:size(peaks, 1)
    u = peakOf(simOut, peaks{k, 2});
    fprintf('%-22s %14.1f %14.1f\n', peaks{k, 1}, 100 * u, peaks{k, 3});
end

fprintf('\nBacklog peaks (units waiting):\n');
for nm = {'Acquire', 'Uplink', 'Compute', 'Review', 'Referral'}
    fprintf('  %-12s %10.0f\n', nm{1}, peakOf(simOut, [nm{1} '_backlog']));
end

%% ------------------------------------------------------------ helpers
function v = totalOf(simOut, name, dt)
ts = getLog(simOut, name);
if isempty(ts), v = NaN; return; end
v = sum(ts.Data) * dt;      % rate per hour x hours per step
end

function v = peakOf(simOut, name)
ts = getLog(simOut, name);
if isempty(ts), v = NaN; return; end
v = max(ts.Data);
end

function ts = getLog(simOut, name)
ts = [];
try
    if isprop(simOut, name) || isfield(simOut, name)
        ts = simOut.(name);
    elseif ismethod(simOut, 'get')
        ts = simOut.get(name);
    end
catch
    ts = [];
end
if ~isempty(ts) && ~isa(ts, 'timeseries') && isprop(ts, 'Data')
    % already usable
elseif isempty(ts)
    warning('compareSimulinkToDES:missingLog', ...
        'No logged signal named "%s" - check the To Workspace block.', name);
end
end
