function out = calibrateConfidence(a, b, opts)
%CALIBRATECONFIDENCE  Platt scaling: turn a CNN's raw confidence into P(prediction is correct).
%
%   Fit:    cal = calibrateConfidence(rawConfidence, isCorrect)     % validation set, one entry per image
%   Apply:  p   = calibrateConfidence(cal, rawConfidence)           % any number of new scores
%
%   rawConfidence  the network's softmax probability for its predicted class (0-1)
%   isCorrect      logical, was that prediction right?
%
%   A logistic regression (fitglm, binomial) of isCorrect on logit(rawConfidence)
%   is fitted: cal.beta = [intercept slope]. Applying it returns the calibrated
%   probability that a prediction with that raw confidence is correct.
%   cal also holds eceBefore / eceAfter (expected calibration error) and, with
%   Plot=true, a reliability diagram is drawn. Needs Statistics and ML Toolbox.

arguments
    a
    b
    opts.Plot (1,1) logical = false
    opts.NumBins (1,1) double = 10
end

if isstruct(a)                                                     % ---------------- APPLY
    out = applyCal(a, b);
    return
end

%% ---------------------------------------------------------------- FIT
raw = double(a(:));
y   = double(logical(b(:)));
assert(numel(raw) == numel(y), 'rawConfidence and isCorrect must have the same length');
if numel(y) < 30
    warning('calibrateConfidence:fewSamples', ...
        'Only %d validation predictions - the calibration will be unreliable.', numel(y));
end

cal.type = 'Platt scaling: logistic regression of correctness on logit(raw confidence)';
if all(y == 1) || all(y == 0)                                      % nothing to fit: constant
    if y(1) == 1, what = 'correct'; else, what = 'wrong'; end
    warning('calibrateConfidence:degenerate', ...
        'All validation predictions are %s - returning a constant calibrator.', what);
    cal.beta = [logit(mean(y)) 0];
else
    mdl = fitglm(logit(raw), y, 'Distribution', 'binomial');       % logistic regression
    cal.beta = mdl.Coefficients.Estimate';                          % [intercept slope]
end
cal.nValidation = numel(y);
cal.accuracy    = mean(y);

pCal = applyCal(cal, raw);
[cRaw, aRaw, wRaw] = binStats(raw,  y, opts.NumBins);
[cCal, aCal, wCal] = binStats(pCal, y, opts.NumBins);
cal.eceBefore = sum(wRaw .* abs(cRaw - aRaw), 'omitnan');
cal.eceAfter  = sum(wCal .* abs(cCal - aCal), 'omitnan');
fprintf('Calibrated on %d predictions (accuracy %.1f%%): expected calibration error %.3f -> %.3f\n', ...
        cal.nValidation, 100 * cal.accuracy, cal.eceBefore, cal.eceAfter);

if opts.Plot
    figure, plot([0 1], [0 1], 'k:', 'DisplayName', 'perfect'), hold on
    plot(cRaw, aRaw, 'o-', 'LineWidth', 1.5, 'DisplayName', sprintf('raw (ECE %.3f)', cal.eceBefore))
    plot(cCal, aCal, 's-', 'LineWidth', 1.5, 'DisplayName', sprintf('calibrated (ECE %.3f)', cal.eceAfter))
    hold off, axis([0 1 0 1]), axis square, grid on, legend('Location', 'northwest')
    xlabel('confidence'), ylabel('fraction actually correct'), title('Reliability diagram')
end
out = cal;
end

%% ============================================================ LOCAL FUNCTIONS
function p = applyCal(cal, raw)
z = cal.beta(1) + cal.beta(2) * logit(double(raw));
p = 1 ./ (1 + exp(-z));
end

function z = logit(p)
p = min(max(p, 1e-6), 1 - 1e-6);
z = log(p ./ (1 - p));
end

function [meanConf, acc, w] = binStats(conf, y, nBins)
%BINSTATS  Mean confidence, observed accuracy and weight of each confidence bin.
bin = discretize(conf, linspace(0, 1, nBins + 1));
meanConf = nan(nBins, 1);  acc = nan(nBins, 1);  w = zeros(nBins, 1);
for k = 1:nBins
    m = bin == k;
    if any(m), meanConf(k) = mean(conf(m));  acc(k) = mean(y(m));  w(k) = mean(m); end
end
end
