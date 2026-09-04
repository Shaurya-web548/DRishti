function reportPaths = compileReportData(image, cnnModel, lesionBundle, patientInfo, outDir, predictedGrade, referableOverride)
%COMPILEREPORTDATA  Package one CNN-graded image (real_full mode) into files a report
%   generator (Python/Gemini, website backend, whatever comes later) can read.
%
%   reportPaths = compileReportData(image, cnnModel, lesionBundle, patientInfo, outDir)
%   reportPaths = compileReportData(image, cnnModel, lesionBundle, patientInfo, outDir, predictedGrade, referableOverride)
%
%   image             file path or RGB array - the original fundus image
%   cnnModel          struct from trainDRClassifier (net, inputSize, grades, calibration, ...)
%                      - REQUIRED, must be trained. This function only supports real_full.
%   lesionBundle      struct from segmentRetina (microaneurysms, exudateMask, hemorrhageMask,
%                      opticDisc, fovea, ...) - passed straight into explainGrading
%   patientInfo       struct, all fields optional: .patientId, .imageId, .eye ('OD'/'OS'),
%                      .captureDate, .facility, .operatorName - missing fields default to 'UNKNOWN'
%   outDir            folder to write images + JSON into (created if missing)
%   predictedGrade    optional; grade (0-4) to explain. [] or omitted = let the CNN pick
%                      its own top class (explainGrading's default behaviour).
%   referableOverride optional logical. If you already have a proper referable decision
%                      from combineGrades / tuneReferableThreshold, pass it here. If omitted,
%                      this function falls back to grade >= 2 and flags that in the JSON
%                      so nobody mistakes it for the tuned threshold.
%
%   reportPaths       struct: .jsonPath, .originalPath, .overlayPath, .heatmapPath, .outDir
%
%   Writes 3 PNGs (original, lesion overlay, Grad-CAM heatmap) and 1 JSON file per image.
%   To inspect: jsondecode(fileread(reportPaths.jsonPath)) in MATLAB, or json.load() in Python.

if nargin < 4 || isempty(patientInfo), patientInfo = struct(); end
if nargin < 5 || isempty(outDir), outDir = fullfile(pwd, 'report_out'); end
if nargin < 6, predictedGrade = []; end
if nargin < 7, referableOverride = []; end

assert(isstruct(cnnModel) && isfield(cnnModel, 'net'), ...
    'compileReportData:noCnn', ...
    'cnnModel must be a trained model struct from trainDRClassifier (needs a .net field). This function is real_full only.');

if ~exist(outDir, 'dir'), mkdir(outDir); end
img = loadImage(image);
stamp = datestr(now, 'yyyymmdd_HHMMSS');
baseName = sprintf('report_%s', stamp);

%% ------------------------------------------ (1) run the actual explanation pipeline
[heatmapImage, overlayImage, calibratedConfidence, info] = ...
    explainGrading(cnnModel, img, predictedGrade, lesionBundle);

%% ------------------------------------------ (2) quadrant-wise lesion counts (for the evidence table)
quadCounts = computeQuadrantLesionCounts(img, lesionBundle);

%% ------------------------------------------ (3) referable flag
if isempty(referableOverride)
    referable = info.grade >= 2;
    referableNote = 'FALLBACK: grade >= 2 (Moderate NPDR or worse). Not the tuned threshold - pass referableOverride once tuneReferableThreshold is wired in.';
else
    referable = logical(referableOverride);
    referableNote = 'from tuneReferableThreshold / combineGrades';
end

%% ------------------------------------------ (4) write images
origPath    = fullfile(outDir, [baseName '_original.png']);
overlayPath = fullfile(outDir, [baseName '_overlay.png']);
heatmapPath = fullfile(outDir, [baseName '_heatmap.png']);
imwrite(img, origPath);
imwrite(overlayImage, overlayPath);
imwrite(heatmapImage, heatmapPath);

%% ------------------------------------------ (5) assemble the JSON payload
payload = struct();
payload.mode = 'real_full';
payload.generatedAt = datestr(now, 'yyyy-mm-dd HH:MM:SS');
payload.patient = fillDefaults(patientInfo, struct( ...
    'patientId', 'UNKNOWN', 'imageId', baseName, 'eye', 'UNK', ...
    'captureDate', datestr(now, 'yyyy-mm-dd'), 'facility', 'UNKNOWN', 'operatorName', 'UNKNOWN'));

payload.grading.grade            = info.grade;
payload.grading.gradeLabel       = gradeLabel(info.grade);
payload.grading.referable        = referable;
payload.grading.referableNote    = referableNote;
payload.grading.rawConfidence    = info.rawConfidence;
payload.grading.calibratedConfidence = calibratedConfidence;
payload.grading.calibrationNote  = info.calibration;
payload.grading.classProbabilities = info.probs;   % one value per grade, in cnnModel.grades order

payload.lesions.quadrants = quadCounts;   % 4-entry struct array: name, microaneurysms, exudates, hemorrhages
payload.lesions.totals = struct( ...
    'microaneurysms', sum([quadCounts.microaneurysms]), ...
    'exudates',        sum([quadCounts.exudates]), ...
    'hemorrhages',      sum([quadCounts.hemorrhages]));

payload.images.original = origPath;
payload.images.overlay  = overlayPath;
payload.images.heatmap  = heatmapPath;

jsonPath = fullfile(outDir, [baseName '.json']);
fid = fopen(jsonPath, 'w');
fwrite(fid, jsonencode(payload, 'PrettyPrint', true));
fclose(fid);

reportPaths = struct('jsonPath', jsonPath, 'originalPath', origPath, ...
                      'overlayPath', overlayPath, 'heatmapPath', heatmapPath, 'outDir', outDir);
fprintf('Report data written to %s\n', jsonPath);
end

%% ============================================================ LOCAL FUNCTIONS
function quadCounts = computeQuadrantLesionCounts(img, lesionBundle)
% Split the image into 4 quadrants about its center; count microaneurysm points
% and connected exudate/hemorrhage lesions in each. Mirrors the 4-quadrant logic
% ICDR/ETDRS severity rules (e.g. the 4:2:1 rule) are based on.
[H, W, ~] = size(img);
cx = W / 2; cy = H / 2;
names = {'superior_temporal', 'superior_nasal', 'inferior_nasal', 'inferior_temporal'};

maCount = zeros(1, 4);
ma = pick(lesionBundle, {'microaneurysms', 'microaneurysmCentroids'});
if ~isempty(ma) && ~isstruct(ma)
    for k = 1:size(ma, 1)
        q = quadrantOf(ma(k, 1), ma(k, 2), cx, cy);
        maCount(q) = maCount(q) + 1;
    end
end

exMask = pick(lesionBundle, {'exudateMask', 'exudates', 'hardExudates'});
exCount = countMaskByQuadrant(exMask, [H W], cx, cy);

heMask = pick(lesionBundle, {'hemorrhageMask', 'hemorrhages'});
heCount = countMaskByQuadrant(heMask, [H W], cx, cy);

quadCounts = struct('name', names, ...
    'microaneurysms', num2cell(maCount), ...
    'exudates',        num2cell(exCount), ...
    'hemorrhages',      num2cell(heCount));
end

function counts = countMaskByQuadrant(mask, sz, cx, cy)
counts = zeros(1, 4);
if isempty(mask) || isstruct(mask), return; end
mask = logical(mask);
if ~isequal(size(mask), sz), mask = imresize(mask, sz, 'nearest'); end
cc = bwconncomp(mask);
stats = regionprops(cc, 'Centroid');
for k = 1:numel(stats)
    c = stats(k).Centroid;
    q = quadrantOf(c(1), c(2), cx, cy);
    counts(q) = counts(q) + 1;
end
end

function q = quadrantOf(x, y, cx, cy)
if x >= cx && y < cy,  q = 1;
elseif x < cx && y < cy,  q = 2;
elseif x < cx && y >= cy, q = 3;
else, q = 4;
end
end

function v = pick(s, names)
v = [];
for k = 1:numel(names)
    if isfield(s, names{k}), v = s.(names{k}); return; end
end
end

function s = fillDefaults(s, defaults)
f = fieldnames(defaults);
for k = 1:numel(f)
    if ~isfield(s, f{k}) || isempty(s.(f{k})), s.(f{k}) = defaults.(f{k}); end
end
end

function lbl = gradeLabel(g)
labels = {'No DR', 'Mild NPDR', 'Moderate NPDR', 'Severe NPDR', 'Proliferative DR'};
if g >= 0 && g <= 4, lbl = labels{g + 1}; else, lbl = 'Unknown'; end
end

function img = loadImage(image)
if ischar(image) || isstring(image), img = imread(char(image)); else, img = image; end
if size(img, 3) > 3, img = img(:, :, 1:3); end
img = im2uint8(img);
if size(img, 3) == 1, img = repmat(img, [1 1 3]); end
end
