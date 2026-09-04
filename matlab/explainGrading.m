function [heatmapImage, overlayImage, calibratedConfidence, info] = explainGrading(cnnModel, image, predictedGrade, lesionBundle)
%EXPLAINGRADING  Grad-CAM heatmap + lesion overlay + calibrated confidence for one graded image.
%
%   [heatmapImage, overlayImage, calibratedConfidence, info] = ...
%       explainGrading(cnnModel, image, predictedGrade, lesionBundle)
%
%   cnnModel        struct from trainDRClassifier (net, inputSize, grades) - or a bare network.
%                   Confidence is calibrated with cnnModel.calibration (from calibrateConfidence)
%                   if present, else fitted on the fly from cnnModel.valScores / valGrades,
%                   else the raw confidence is returned.
%   image           file path or RGB array
%   predictedGrade  the grade (0-4) to explain; [] = the network's own prediction
%   lesionBundle    struct with microaneurysms ([x y] list), exudateMask, hemorrhageMask,
%                   optionally opticDisc / fovea - e.g. the output of segmentRetina
%
%   calibratedConfidence  P(the predicted grade is correct)
%   info                  grade, classIdx, probs, rawConfidence, scoreMap, calibrator, calibration note
%   Called without output arguments it shows image | overlay | heatmap side by side.

if nargin < 4 || isempty(lesionBundle), lesionBundle = struct(); end
if nargin < 3, predictedGrade = []; end
[net, inputSize, grades, cal] = unpackModel(cnnModel);
img = loadImage(image);

%% ------------------------------------------ CNN probabilities for this image
X = single(imresize(img, inputSize(1:2)));
probs = predict(net, X);
if isa(probs, 'dlarray'), probs = extractdata(probs); end
probs = gather(double(probs(:))');
if isempty(grades), grades = 0:numel(probs) - 1; end
if isempty(predictedGrade)
    [~, classIdx] = max(probs);
else
    classIdx = find(grades == predictedGrade, 1);
    assert(~isempty(classIdx), 'predictedGrade %g is not one of the model grades', predictedGrade);
end
rawConfidence = probs(classIdx);

%% ------------------------------------------ (2) heatmap, (1) overlay
[heatmapImage, scoreMap] = gradCAMHeatmap(cnnModel, img, classIdx);
overlayImage = drawLesionOverlay(img, lesionBundle);

%% ------------------------------------------ (3) calibrated confidence
if ~isempty(cal)
    note = 'Platt scaling from cnnModel.calibration';
elseif isstruct(cnnModel) && all(isfield(cnnModel, {'valScores', 'valGrades'}))
    [rawVal, iv] = max(cnnModel.valScores, [], 2);
    cal  = calibrateConfidence(rawVal, reshape(grades(iv), [], 1) == cnnModel.valGrades(:));
    note = 'Platt scaling fitted on the validation split (store info.calibrator as cnnModel.calibration to skip refitting)';
else
    note = 'none - no calibrator or validation data in cnnModel, raw confidence returned';
end
if isempty(cal), calibratedConfidence = rawConfidence;
else,            calibratedConfidence = calibrateConfidence(cal, rawConfidence); end

info.grade         = grades(classIdx);
info.classIdx      = classIdx;
info.probs         = probs;
info.rawConfidence = rawConfidence;
info.scoreMap      = scoreMap;
info.calibrator    = cal;
info.calibration   = note;

if nargout == 0
    figure, montage({img, overlayImage, heatmapImage}, 'Size', [1 3])
    title(sprintf('grade %d   raw confidence %.2f  ->  calibrated %.2f', ...
                  info.grade, rawConfidence, calibratedConfidence))
end
end

%% ============================================================ LOCAL FUNCTIONS
function [net, inputSize, grades, cal] = unpackModel(m)
if isstruct(m)
    net = m.net;
    inputSize = fieldOr(m, 'inputSize', []);
    grades    = fieldOr(m, 'grades', []);
    cal       = fieldOr(m, 'calibration', []);
else
    net = m;  inputSize = [];  grades = [];  cal = [];
end
if isempty(inputSize), inputSize = net.Layers(1).InputSize; end
end

function v = fieldOr(s, name, default)
if isfield(s, name), v = s.(name); else, v = default; end
end

function img = loadImage(image)
if ischar(image) || isstring(image), img = imread(char(image)); else, img = image; end
if size(img, 3) > 3, img = img(:, :, 1:3); end
img = im2uint8(img);
if size(img, 3) == 1, img = repmat(img, [1 1 3]); end
end
