%% demoExplainGrading - smoke test of explainGrading with fake data
% Runs with nothing but the toolboxes installed: if there is no trained model it
% uses a 5-class SqueezeNet with an untrained head (ships with the toolbox), and
% if there is no fundus image it draws a synthetic one. Predictions are then
% meaningless, but every part of the chain is exercised.

%% Model
if isfile('drClassifier.mat')
    model = load('drClassifier.mat');
else
    model.net       = imagePretrainedNetwork('squeezenet', NumClasses=5);
    model.inputSize = model.net.Layers(1).InputSize;
    model.grades    = 0:4;
end

%% Calibrator from a fake validation set: an over-confident CNN
n       = 800;
rawConf = 0.4 + 0.6 * rand(n, 1);                              % raw confidence 0.4 - 1
correct = rand(n, 1) < 0.35 + 0.55 * (rawConf - 0.4) / 0.6;     % true accuracy 35 - 90 %, below the raw value
model.calibration = calibrateConfidence(rawConf, correct, Plot=true);
% With a trained model use its real validation results instead:
%   [rawVal, i] = max(model.valScores, [], 2);
%   model.calibration = calibrateConfidence(rawVal, model.grades(i)' == model.valGrades, Plot=true);

%% Image: your own fundus photo, or a synthetic stand-in
if isfile('fundus.jpg')
    img = imread('fundus.jpg');
else
    [X, Y] = meshgrid(1:640, 1:480);
    fov = (X - 320).^2 + (Y - 240).^2 <= 230^2;
    img = imnoise(uint8(cat(3, 200 * fov, 100 * fov, 40 * fov)), 'gaussian', 0, 0.002);
end
[H, W, ~] = size(img);

%% Fake lesion bundle
[X, Y] = meshgrid(1:W, 1:H);
disk = @(cx, cy, r) (X - cx).^2 + (Y - cy).^2 <= r^2;
lesions.microaneurysms = [W H] .* (0.25 + 0.5 * rand(12, 2));                      % 12 [x y] points
lesions.exudateMask    = disk(0.62 * W, 0.42 * H, 0.03 * W) | disk(0.66 * W, 0.50 * H, 0.02 * W);
lesions.hemorrhageMask = disk(0.35 * W, 0.60 * H, 0.04 * W);
lesions.opticDisc      = struct('center', [0.30 * W, 0.48 * H], 'radius', 0.07 * W);

%% Explain
[heat, overlay, conf, info] = explainGrading(model, img, [], lesions);
figure, montage({img, overlay, heat}, 'Size', [1 3])
title(sprintf('grade %d   raw confidence %.2f  ->  calibrated %.2f', info.grade, info.rawConfidence, conf))
disp(info)
