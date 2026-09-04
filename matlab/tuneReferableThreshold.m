function result = tuneReferableThreshold(pReferable, isReferable, targetSensitivity, minSpecificity)
%TUNEREFERABLETHRESHOLD  Pick the P(referable) cut-off that reaches the target sensitivity.
%
%   result = tuneReferableThreshold(pReferable, isReferable)             % 90 % sens, > 85 % spec
%   result = tuneReferableThreshold(pReferable, isReferable, 0.90, 0.85)
%
%   pReferable   CNN probability of referable DR (grade >= 2), one per image:
%                sum(model.valScores(:, model.grades >= 2), 2)
%   isReferable  true grade >= 2, one per image (logical)
%
%   Among all cut-offs whose sensitivity is >= targetSensitivity, the one with the
%   highest specificity is chosen. result.meetsTarget says whether it also
%   clears minSpecificity. The ROC / AUC come from perfcurve (Statistics and
%   Machine Learning Toolbox); without that toolbox they are computed directly.
%
%   result fields: threshold, sensitivity, specificity, AUC, meetsTarget, X, Y (ROC)

if nargin < 3 || isempty(targetSensitivity), targetSensitivity = 0.90; end
if nargin < 4 || isempty(minSpecificity),    minSpecificity    = 0.85; end
p   = double(pReferable(:));
pos = logical(isReferable(:));
assert(numel(p) == numel(pos), 'pReferable and isReferable must have one entry per image');
assert(any(pos) && any(~pos), 'Need both referable and non-referable images to tune a threshold');

%% ------------ sensitivity / specificity at every cut-off (referable if p >= t)
cand = unique(p);
sens = arrayfun(@(t) mean(p(pos)  >= t), cand);
spec = arrayfun(@(t) mean(p(~pos) <  t), cand);

ok = find(sens >= targetSensitivity);                    % cut-offs that reach the sensitivity target
if isempty(ok), ok = 1; end                              % (only if the target is > 100 %)
[~, j] = max(spec(ok));                                  % ... take the one with the best specificity
best = ok(j);

result.threshold   = cand(best);
result.sensitivity = sens(best);
result.specificity = spec(best);
result.meetsTarget = sens(best) >= targetSensitivity && spec(best) > minSpecificity;

%% ---------------------------------------------------------- ROC + AUC
if exist('perfcurve', 'file') == 2
    [X, Y, ~, AUC] = perfcurve(pos, p, true);
else
    X = [1 - spec; 0];  Y = [sens; 0];                   % (1,1) at the lowest cut-off ... (0,0)
    AUC = abs(trapz(X, Y));
end
result.AUC = AUC;  result.X = X;  result.Y = Y;

figure, plot(X, Y, 'LineWidth', 1.5), hold on
plot([0 1], [0 1], 'k:')
plot(1 - result.specificity, result.sensitivity, 'ro', 'MarkerFaceColor', 'r')
hold off, axis square, grid on
xlabel('1 - specificity'), ylabel('sensitivity')
title(sprintf('Referable DR   AUC %.3f   cut-off %.3f: sens %.1f%%, spec %.1f%%', ...
              AUC, result.threshold, 100 * result.sensitivity, 100 * result.specificity))

fprintf('Threshold %.3f -> sensitivity %.1f%%, specificity %.1f%% (AUC %.3f)\n', ...
        result.threshold, 100 * result.sensitivity, 100 * result.specificity, AUC);
if ~result.meetsTarget
    warning('tuneReferableThreshold:target', ...
        'Specificity %.1f%% is below the %.0f%% target at %.0f%% sensitivity - the CNN needs more data / epochs.', ...
        100 * result.specificity, 100 * minSpecificity, 100 * targetSensitivity);
end
end
